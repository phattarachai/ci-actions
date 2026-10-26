#!/usr/bin/env bash
# Snapshot-if-pending, then migrate, in the current directory. Bash 3.2 safe (macOS runners).
set -euo pipefail

case "${ON_SNAPSHOT_FAILURE:-stop}" in
  stop|continue) ;;
  *) echo "::error::on-snapshot-failure must be 'stop' or 'continue', got '$ON_SNAPSHOT_FAILURE'"; exit 2 ;;
esac

# `sudo php artisan` → (sudo php artisan): word-split once, on purpose.
read -r -a artisan <<< "${ARTISAN:-php artisan}"

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
