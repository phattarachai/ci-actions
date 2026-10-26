#!/usr/bin/env bash
# Writes the PR's changed files matching PATTERNS (minus EXCLUDE) to a temp file, then sets the
# `count` and `list` outputs. Bash 3.2 safe (macOS runners).
set -euo pipefail

if [ -z "${BASE_SHA:-}" ]; then
  echo "::error::changed-files needs a base commit: run it on pull_request, or pass base:"
  exit 1
fi

matches() {
  local file="$1" list="$2" pattern
  while IFS= read -r pattern; do
    pattern="$(printf '%s' "$pattern" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$pattern" ] || continue
    # The pattern is meant to glob.
    # shellcheck disable=SC2254
    case "$file" in
      $pattern) return 0 ;;
    esac
  done <<EOF
$list
EOF
  return 1
}

list="$(mktemp "${RUNNER_TEMP:-/tmp}/changed-files.XXXXXX")"

# Three dots: what the PR changed since it left the base, not what the base gained meanwhile.
# quotePath=false: otherwise git prints a Thai file name as "\340\270…" and it never matches.
git -c core.quotePath=false diff --name-only --diff-filter=ACMR "$BASE_SHA...$HEAD_SHA" |
  while IFS= read -r file; do
    matches "$file" "$PATTERNS" || continue
    if matches "$file" "${EXCLUDE:-}"; then
      continue
    fi
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
    fi
  done > "$list"

count="$(wc -l < "$list" | tr -d ' ')"
echo "$count changed file(s):"
cat "$list"

{
  echo "count=$count"
  echo "list=$list"
} >> "$GITHUB_OUTPUT"
