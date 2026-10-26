#!/usr/bin/env bash
# Unit tests for laravel-migrate/migrate.sh against a fake artisan. bash tests/laravel-migrate.sh
set -u
script="$(cd "$(dirname "$0")/.." && pwd)/laravel-migrate/migrate.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The fake logs "<pwd> <args>" per call and obeys STATUS_EXIT / PENDING / SNAPSHOT_EXIT / MIGRATE_EXIT.
cat > "$work/artisan" <<'FAKE'
#!/usr/bin/env bash
echo "$(basename "$PWD") $*" >> "$CALLS"
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

# run [VAR=value…] → sets $exit, $calls (one line per artisan call, ' | '-joined) and $outputs.
run() {
  : > "$work/calls"
  : > "$work/output"
  (cd "$work/app" && env -i PATH="$PATH" CALLS="$work/calls" GITHUB_OUTPUT="$work/output" \
    ARTISAN="$work/artisan" "$@" bash "$script" > "$work/log" 2>&1)
  exit=$?
  calls="$(paste -sd'|' "$work/calls" | sed 's/|/ | /g')"
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

[ "$failures" = 0 ] || { echo "$failures failure(s)"; exit 1; }
