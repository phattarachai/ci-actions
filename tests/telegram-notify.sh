#!/usr/bin/env bash
# Unit tests for telegram-notify/notify.sh, run in dry-run mode. bash tests/telegram-notify.sh
set -u
cd "$(dirname "$0")/.." || exit 1

failures=0

# needs_json "test=success" "deploy=skipped" … → the shape toJSON(needs) prints.
needs_json() {
  local first=1 pair
  printf '{\n'
  for pair in "$@"; do
    [ "$first" = 1 ] || printf ',\n'
    first=0
    printf '  "%s": {\n    "result": "%s",\n    "outputs": {}\n  }' "${pair%%=*}" "${pair#*=}"
  done
  printf '\n}\n'
}

# expect <name> <exit> <first line> <needs json> [env…]
expect() {
  local name="$1" want_exit="$2" want_line="$3" json="$4"
  shift 4
  local out got_exit
  out="$(env -i PATH="$PATH" NEEDS_JSON="$json" TELEGRAM_NOTIFY_DRY_RUN=1 \
    TELEGRAM_BOT_TOKEN=token TELEGRAM_CHAT_ID=chat COMMIT_MESSAGE=$'Fix things\n\nbody' \
    GITHUB_SHA=abcdef1234 GITHUB_REPOSITORY=org/app GITHUB_REF_NAME=main \
    GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=42 "$@" bash telegram-notify/notify.sh)"
  got_exit=$?
  if [ "$got_exit" != "$want_exit" ] || [ "$(printf '%s\n' "$out" | head -1)" != "$want_line" ]; then
    echo "FAIL $name: exit $got_exit (want $want_exit)"
    printf '%s\n' "$out" | sed 's/^/  | /'
    echo "  want first line: $want_line"
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

expect "test and deploy pass" 0 "✅ app — test · deploy passed" "$(needs_json test=success deploy=success)"
expect "deploy skipped off main" 0 "✅ app — test passed" "$(needs_json test=success deploy=skipped)"
expect "test fails" 1 "❌ app — test failure" "$(needs_json test=failure deploy=skipped)"
expect "first failing job is named" 1 "❌ app — deploy-mkt cancelled" \
  "$(needs_json test=success deploy-ysrgold=success deploy-mkt=cancelled deploy-mkl-br=failure)"
expect "deploy-only workflow" 0 "✅ app — deploy-linux passed" "$(needs_json deploy-linux=success)"

nested='{
  "test": {
    "result": "failure",
    "outputs": {
      "report": {
        "result": "success"
      }
    }
  }
}'
expect "nested outputs never count as a result" 1 "❌ app — test failure" "$nested"

expect "missing secrets skip and pass even on failure" 0 \
  "TELEGRAM_* secrets are not set on this repo — skipping the notification (❌ test failure)." \
  "$(needs_json test=failure)" TELEGRAM_BOT_TOKEN=

expect "empty needs is a wiring error" 1 \
  "::error::telegram-notify got no job results: pass needs: \${{ toJSON(needs) }}" ""

second_line="$(env -i PATH="$PATH" NEEDS_JSON="$(needs_json test=success)" TELEGRAM_NOTIFY_DRY_RUN=1 \
  TELEGRAM_BOT_TOKEN=t TELEGRAM_CHAT_ID=c GITHUB_SHA=abcdef1234 GITHUB_REPOSITORY=org/app \
  GITHUB_REF_NAME=feature GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=42 \
  bash telegram-notify/notify.sh | sed -n 2p)"
if [ "$second_line" = "feature · abcdef1" ]; then
  echo "ok   no head_commit falls back to the short sha"
else
  echo "FAIL no head_commit falls back to the short sha: got '$second_line'"
  failures=$((failures + 1))
fi

[ "$failures" = 0 ] || { echo "$failures failure(s)"; exit 1; }
