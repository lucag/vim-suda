#!/bin/sh
# Run the vim-suda test suite: every test/*_test.lua in its own headless Neovim.
# Usage: test/run.sh [test/file_test.lua ...]
# Exits non-zero if any test file fails.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
nvim=${NVIM:-nvim}

if [ "$(id -u)" = 0 ]; then
  echo "test/run.sh: refusing to run as root (Protected Files would be readable)" >&2
  exit 2
fi

if [ $# -eq 0 ]; then
  set -- "$root"/test/*_test.lua
  [ -e "$1" ] || { echo "test/run.sh: no test/*_test.lua files" >&2; exit 2; }
fi

out=$(mktemp)
trap 'rm -f "$out"' EXIT

status=0
for file in "$@"; do
  echo "== $file"
  "$nvim" --headless --clean -u NONE -i NONE -l "$file" </dev/null >"$out" 2>&1
  code=$?
  cat "$out"
  # A test that makes Neovim quit early may exit 0 without a summary.
  if ! grep -q ' passed, [0-9]* failed$' "$out"; then
    echo "  FAIL $file exited before reporting results"
    status=1
  elif [ $code -ne 0 ]; then
    status=1
  fi
done
exit $status
