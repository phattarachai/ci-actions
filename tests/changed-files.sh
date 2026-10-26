#!/usr/bin/env bash
# The single-quoted $(…) names are the point: they must stay literal.
# shellcheck disable=SC2016
# Unit tests for changed-files/changed-files.sh against a throwaway git repo. bash tests/changed-files.sh
set -eu
script="$(cd "$(dirname "$0")/.." && pwd)/changed-files/changed-files.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q
git config user.email test@example.com
git config user.name test

mkdir -p app resources/js
echo old > app/Gone.php
echo old > app/Kept.php
git add . && git commit -qm base
base="$(git rev-parse HEAD)"

echo new > app/Kept.php
echo new > 'app/With Space.php'
echo new > 'app/$(touch pwned).php'
echo new > app/รายงาน.php
echo new > _ide_helper_models.php
echo new > resources/js/Page.jsx
echo new > README.md
git rm -q app/Gone.php
git add . && git commit -qm change
head="$(git rev-parse HEAD)"

failures=0

# run <patterns> <exclude> → prints "count|list contents"
run() {
  local output
  output="$(mktemp)"
  env PATTERNS="$1" EXCLUDE="$2" BASE_SHA="$base" HEAD_SHA="$head" RUNNER_TEMP="$work" \
    GITHUB_OUTPUT="$output" bash "$script" > /dev/null
  local count list
  count="$(sed -n 's/^count=//p' "$output")"
  list="$(sed -n 's/^list=//p' "$output")"
  printf '%s|%s' "$count" "$(tr '\n' ',' < "$list")"
}

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: got '$2', want '$3'"
    failures=$((failures + 1))
  fi
}

check "php files, helpers excluded, deleted dropped, Thai name unquoted" \
  "$(run '*.php' '_ide_helper*.php')" \
  '4|app/$(touch pwned).php,app/Kept.php,app/With Space.php,app/รายงาน.php,'
check "several patterns" "$(run $'resources/js/*.jsx\n  *.md  ' '')" '2|README.md,resources/js/Page.jsx,'
check "nothing matches" "$(run '*.vue' '')" '0|'

check "a crafted file name is never executed" "$(ls pwned 2>/dev/null || echo absent)" absent

[ "$failures" = 0 ] || { echo "$failures failure(s)"; exit 1; }
