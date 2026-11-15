#!/usr/bin/env bash
# Snapshot-if-pending, then migrate, in the current directory. Bash 3.2 safe (macOS runners).
set -euo pipefail

case "${ON_SNAPSHOT_FAILURE:-stop}" in
  stop|continue) ;;
  *) echo "::error::on-snapshot-failure must be 'stop' or 'continue', got '$ON_SNAPSHOT_FAILURE'"; exit 2 ;;
esac

# `sudo php artisan` → (sudo php artisan): word-split once, on purpose.
read -r -a artisan <<< "${ARTISAN:-php artisan}"

# extra-env: KEY=VALUE per line, value taken literally (no quotes, no expansion, may be empty).
# Blank lines and # comments are skipped. Parsed, never eval'd; only keys are ever printed.
extra_keys=""
line_number=0
while IFS= read -r line || [ -n "$line" ]; do
  line_number=$((line_number + 1))
  line="${line%$'\r'}"
  trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
  case "$trimmed" in
    ''|'#'*) continue ;;
  esac
  key="$(printf '%s' "${trimmed%%=*}" | sed 's/[[:space:]]*$//')"
  if [ "$key" = "$trimmed" ] || ! printf '%s' "$key" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
    echo "::error::extra-env line $line_number is not KEY=VALUE (KEY is letters, digits and _)."
    exit 2
  fi
  export "$key=${trimmed#*=}"
  extra_keys="$extra_keys${extra_keys:+, }$key"
done <<EOF
${MIGRATE_EXTRA_ENV:-}
EOF

# The owner override (db-username, db-host, db-socket, extra-env) is exported into this script's
# env, so it reaches the three artisan calls below and nothing after the step. Laravel's process
# env beats .env, but a cached config reads neither: refuse rather than migrate as the wrong user.
override=false
if [ -n "${MIGRATE_DB_USERNAME:-}${MIGRATE_DB_HOST:-}${MIGRATE_DB_SOCKET:-}$extra_keys" ]; then
  override=true
fi

if [ -f bootstrap/cache/config.php ]; then
  if [ "$override" = true ]; then
    echo "::error::bootstrap/cache/config.php exists, so Laravel ignores env and the db-username/db-host/db-socket/extra-env override would be silently dropped (migrations would run as the app user). Run \`artisan optimize:clear\` before this step and \`artisan optimize\` after it."
    exit 2
  fi
  echo "::warning::bootstrap/cache/config.php exists, so migrations use the cached config and any DB_* env set on this step is ignored. Run \`artisan optimize:clear\` before this step and \`artisan optimize\` after it."
fi

if [ -n "${MIGRATE_DB_USERNAME:-}" ]; then
  # The owner role has no password: it logs in over the unix socket (peer / auth_socket).
  export DB_USERNAME="$MIGRATE_DB_USERNAME" DB_PASSWORD=''
fi
if [ -n "${MIGRATE_DB_HOST:-}" ]; then
  export DB_HOST="$MIGRATE_DB_HOST"
fi
if [ -n "${MIGRATE_DB_SOCKET:-}" ]; then
  export DB_SOCKET="$MIGRATE_DB_SOCKET"
fi

if [ -n "${MIGRATE_DB_USERNAME:-}" ]; then
  echo "Migrating as DB user ${DB_USERNAME} (db-username, no password)."
elif [ -n "${DB_USERNAME:-}" ]; then
  echo "Migrating as DB user ${DB_USERNAME} (DB_USERNAME already in the env)."
else
  echo "Migrating as the app's configured DB user (.env, or the cached config)."
fi
if [ -n "${MIGRATE_DB_HOST:-}" ]; then
  echo "DB_HOST=$DB_HOST"
fi
if [ -n "${MIGRATE_DB_SOCKET:-}" ]; then
  echo "DB_SOCKET=$DB_SOCKET"
fi
if [ -n "$extra_keys" ]; then
  echo "extra-env sets: $extra_keys"
fi
if [ "$override" = true ] && [ "${artisan[0]}" = sudo ]; then
  echo "::warning::artisan starts with sudo, whose env_reset drops the owner override unless sudoers keeps these variables. Run artisan as the deploy user instead."
fi

# snapshot:create (pg_dump) is only a rollback point for schema changes; with nothing pending it is
# pure waste. `migrate:status --pending` exits 0 either way, so read its output, and fail SAFE
# (snapshot anyway) when the command itself errors.
set +e
status="$("${artisan[@]}" migrate:status --pending --no-ansi 2>&1)"
code=$?
set -e

if [ "$code" -ne 0 ]; then
  echo "migrate:status failed (exit $code), taking a snapshot to be safe."
  printf '%s\n' "$status"
  pending=true
elif printf '%s\n' "$status" | grep -qw Pending; then
  printf '%s\n' "$status"
  pending=true
else
  echo "No pending migrations, snapshot skipped."
  pending=false
fi
echo "has-pending=$pending" >> "$GITHUB_OUTPUT"

snapshot=skipped
if [ "$pending" = true ] && [ "${SNAPSHOT:-true}" = true ]; then
  args=(snapshot:create --no-interaction)
  if [ "${COMPRESS:-true}" = true ]; then
    args+=(--compress)
  fi
  if "${artisan[@]}" "${args[@]}"; then
    snapshot=created
  elif [ "${ON_SNAPSHOT_FAILURE:-stop}" = continue ]; then
    echo "::warning::snapshot:create failed; migrating WITHOUT a rollback point (on-snapshot-failure: continue)."
    snapshot=failed
  else
    echo "snapshot=failed" >> "$GITHUB_OUTPUT"
    echo "::error::snapshot:create failed, so migrations did not run and the schema is unchanged."
    exit 1
  fi
fi
echo "snapshot=$snapshot" >> "$GITHUB_OUTPUT"

"${artisan[@]}" migrate --force --no-interaction
