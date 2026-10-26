#!/usr/bin/env bash
# Reads NEEDS_JSON (toJSON(needs)), sends one Telegram message, then exits with the run's verdict.
# Bash 3.2 and no jq: it runs on GitHub-hosted, macOS self-hosted and bare Linux self-hosted runners.
# TELEGRAM_NOTIFY_DRY_RUN=1 prints the message instead of sending it (used by tests/).
set -u

# toJSON(needs) is pretty-printed with two-space indents: a job id opens at depth 1, its result sits
# at depth 2. Reading by indent keeps a job's `outputs` (depth 3+) from ever being taken for a result.
jobs="$(printf '%s\n' "${NEEDS_JSON:-}" | awk '
  /^  "[^"]+": \{/ { split($0, part, "\""); job = part[2]; next }
  /^    "result": "/ { split($0, part, "\""); print job " " part[4] }
')"

if [ -z "$jobs" ]; then
  echo "::error::telegram-notify got no job results: pass needs: \${{ toJSON(needs) }}"
  exit 1
fi

failed=0
passed=""
state=""
while read -r job result; do
  case "$result" in
    success) passed="${passed:+$passed · }$job" ;;
    skipped) ;;
    *)
      if [ "$failed" = 0 ]; then
        state="$job $result"
      fi
      failed=1
      ;;
  esac
done <<EOF
$jobs
EOF

if [ "$failed" = 1 ]; then
  icon="❌"
else
  icon="✅"
  state="${passed:-nothing ran}${passed:+ passed}"
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "TELEGRAM_* secrets are not set on this repo — skipping the notification ($icon $state)."
  exit 0
fi

# head_commit is null on pull_request / workflow_dispatch runs — fall back to the sha.
subject="$(printf '%s' "${COMMIT_MESSAGE:-}" | head -1)"
[ -n "$subject" ] || subject="${GITHUB_SHA:0:7}"

text="$(printf '%s %s — %s\n%s · %s\n%s/%s/actions/runs/%s' \
  "$icon" "${GITHUB_REPOSITORY##*/}" "$state" \
  "$GITHUB_REF_NAME" "$subject" \
  "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID")"

if [ "${TELEGRAM_NOTIFY_DRY_RUN:-0}" = 1 ]; then
  printf '%s\n' "$text"
  exit "$failed"
fi

response="$(curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${text}" \
  --data-urlencode 'link_preview_options={"is_disabled":true}' 2>&1)"

# Fail-soft but loud: a rejected send is a warning on the run, never a red job by itself.
case "$response" in
  *'"ok":true'*) echo "Sent: $icon $state" ;;
  *) echo "::warning::Telegram did not accept the message: $response" ;;
esac

# Send first, THEN adopt the outcome: a failed run shows an all-red job list, never a green notify
# beside a red deploy. failed=1 is only reachable when a needed job already failed.
exit "$failed"
