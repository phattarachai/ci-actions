#!/usr/bin/env bash
# Unit tests for laravel-migrate/migrate.sh against a fake artisan. bash tests/laravel-migrate.sh
set -u
script="$(cd "$(dirname "$0")/.." && pwd)/laravel-migrate/migrate.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The fake logs "<pwd> <args>" per call (and the DB env it saw, into $CALLS.env) and obeys STATUS_EXIT / PENDING / SNAPSHOT_EXIT / MIGRATE_EXIT.
cat > "$work/artisan" <<'FAKE'
#!/usr/bin/env bash
echo "$(basename "$PWD") $*" >> "$CALLS"
echo "$1 u=${DB_USERNAME-unset} p=${DB_PASSWORD-unset} h=${DB_HOST-unset} s=${DB_SOCKET-unset} lu=${LOG_DB_USERNAME-unset} lp=${LOG_DB_PASSWORD-unset} odd=${ODD-unset}" >> "$CALLS.env"
case "$1" in
  migrate:status)
    [ "${STATUS_EXIT:-0}" = 0 ] || { echo "SQLSTATE[08006] connection refused"; exit "$STATUS_EXIT"; }
    if [ "${PENDING:-0}" = 1 ]; then echo "  2026_10_26_000000_add_column ........ Pending"; else echo "  INFO  No pending migrations."; fi ;;
  snapshot:create) exit "${SNAPSHOT_EXIT:-0}" ;;
  migrate) exit "${MIGRATE_EXIT:-0}" ;;
esac
FAKE
chmod +x "$work/artisan"
mkdir -p "$work/app"

failures=0

# run [VAR=value…] → sets $exit, $calls (one line per artisan call, ' | '-joined), $envs (the DB
# env each call saw, ' | '-joined) and $outputs.
run() {
  : > "$work/calls"
  : > "$work/calls.env"
  : > "$work/output"
  (cd "$work/app" && env -i PATH="$PATH" CALLS="$work/calls" GITHUB_OUTPUT="$work/output" \
    ARTISAN="$work/artisan" "$@" bash "$script" > "$work/log" 2>&1)
  exit=$?
  calls="$(paste -sd'|' "$work/calls" | sed 's/|/ | /g')"
  envs="$(paste -sd'|' "$work/calls.env" | sed 's/|/ | /g')"
  outputs="$(paste -sd' ' "$work/output")"
}

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    echo "  got:  $2"
    echo "  want: $3"
    sed 's/^/  | /' "$work/log"
    failures=$((failures + 1))
  fi
}

run
check "nothing pending: no snapshot, migrate runs" "$exit|$calls|$outputs" \
  "0|app migrate:status --pending --no-ansi | app migrate --force --no-interaction|has-pending=false snapshot=skipped"

run PENDING=1
check "pending: compressed snapshot, then migrate" "$exit|$calls|$outputs" \
  "0|app migrate:status --pending --no-ansi | app snapshot:create --no-interaction --compress | app migrate --force --no-interaction|has-pending=true snapshot=created"

run PENDING=1 COMPRESS=false
check "compress false: plain snapshot" "$calls" \
  "app migrate:status --pending --no-ansi | app snapshot:create --no-interaction | app migrate --force --no-interaction"

run STATUS_EXIT=1
check "migrate:status errors: snapshot anyway (fail safe)" "$exit|$outputs" "0|has-pending=true snapshot=created"

run PENDING=1 SNAPSHOT_EXIT=1
check "snapshot fails, stop: migrate never runs" "$exit|$calls|$outputs" \
  "1|app migrate:status --pending --no-ansi | app snapshot:create --no-interaction --compress|has-pending=true snapshot=failed"

run PENDING=1 SNAPSHOT_EXIT=1 ON_SNAPSHOT_FAILURE=continue
check "snapshot fails, continue: warns and migrates" "$exit|$outputs|$(grep -c '::warning::' "$work/log")" \
  "0|has-pending=true snapshot=failed|1"

run PENDING=1 SNAPSHOT=false
check "snapshot false: migrate only" "$calls|$outputs" \
  "app migrate:status --pending --no-ansi | app migrate --force --no-interaction|has-pending=true snapshot=skipped"

run MIGRATE_EXIT=3
check "a failed migrate fails the step" "$exit" "3"

run ON_SNAPSHOT_FAILURE=maybe
check "an unknown on-snapshot-failure is refused before anything runs" "$exit|$calls" "2|"

run PENDING=1 ARTISAN="env PREFIXED=1 $work/artisan"
check "a prefixed artisan (sudo php artisan) is word-split" "$exit|$outputs" "0|has-pending=true snapshot=created"

unset_env="u=unset p=unset h=unset s=unset lu=unset lp=unset odd=unset"
run
check "no override inputs: the DB env is untouched" "$envs|$(grep -c 'configured DB user' "$work/log")" \
  "migrate:status $unset_env | migrate $unset_env|1"

owner_env="u=myapp_owner p= h=/var/run/postgresql s=unset lu=unset lp=unset odd=unset"
run PENDING=1 MIGRATE_DB_USERNAME=myapp_owner MIGRATE_DB_HOST=/var/run/postgresql
check "db-username + db-host (pgsql): every call runs as the owner, password empty" \
  "$exit|$envs|$outputs|$(grep -c 'Migrating as DB user myapp_owner' "$work/log")" \
  "0|migrate:status $owner_env | snapshot:create $owner_env | migrate $owner_env|has-pending=true snapshot=created|1"

run MIGRATE_DB_USERNAME=myapp_owner MIGRATE_DB_SOCKET=/run/mysqld/mysqld.sock
check "db-socket (MySQL): DB_SOCKET reaches artisan" "$exit|$envs" \
  "0|migrate:status u=myapp_owner p= h=unset s=/run/mysqld/mysqld.sock lu=unset lp=unset odd=unset | migrate u=myapp_owner p= h=unset s=/run/mysqld/mysqld.sock lu=unset lp=unset odd=unset"

# The $( ) must stay literal: it proves the value is never eval'd.
# shellcheck disable=SC2016
extra='# second connection
LOG_DB_USERNAME=myapp_log_owner

  LOG_DB_PASSWORD=
ODD=s3cr3t=$(touch pwned) "q"'
run MIGRATE_EXTRA_ENV="$extra"
check "extra-env: literal values (empty, =, \$( ), quotes), never eval'd" \
  "$exit|$(sed -n 1p "$work/calls.env")|$([ -e "$work/app/pwned" ] && echo ran || echo safe)" \
  "0|migrate:status u=unset p=unset h=unset s=unset lu=myapp_log_owner lp= odd=s3cr3t=\$(touch pwned) \"q\"|safe"
check "extra-env: keys printed, values never" \
  "$(grep -c 'extra-env sets: LOG_DB_USERNAME, LOG_DB_PASSWORD, ODD' "$work/log")|$(grep -c 's3cr3t' "$work/log")" "1|0"

run MIGRATE_EXTRA_ENV='LOG_DB_USERNAME=x
not a pair s3cr3t'
check "extra-env: a line without KEY=VALUE is refused, unprinted, before anything runs" \
  "$exit|$calls|$(grep -c 'extra-env line 2' "$work/log")|$(grep -c 's3cr3t' "$work/log")" "2||1|0"

run MIGRATE_EXTRA_ENV='BAD-KEY=1'
check "extra-env: an invalid key is refused" "$exit|$calls" "2|"

run DB_USERNAME=from_step_env
check "a step-level env: DB_USERNAME passes through and is named" \
  "$exit|$(grep -c 'Migrating as DB user from_step_env' "$work/log")" "0|1"

mkdir -p "$work/app/bootstrap/cache"
touch "$work/app/bootstrap/cache/config.php"

run MIGRATE_DB_USERNAME=myapp_owner MIGRATE_DB_HOST=/var/run/postgresql
check "cached config + db-username: refused before anything runs" \
  "$exit|$calls|$(grep -c '::error::.*optimize:clear' "$work/log")" "2||1"

run MIGRATE_EXTRA_ENV='LOG_DB_USERNAME=myapp_log_owner'
check "cached config + extra-env: refused" "$exit|$calls" "2|"

run
check "cached config, no override: warns and migrates as before" \
  "$exit|$outputs|$(grep -c '::warning::.*cached config' "$work/log")" "0|has-pending=false snapshot=skipped|1"

rm -rf "$work/app/bootstrap"

[ "$failures" = 0 ] || { echo "$failures failure(s)"; exit 1; }
