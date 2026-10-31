#!/bin/sh
# Run the vim-suda test suite: every test/*_test.lua in its own headless
# Neovim and again under the TUI harness (test/tui.sh, an interactive Neovim
# on a pseudo-terminal; skipped if script(1) is missing, unless
# SUDA_TEST_REQUIRE_TUI=1), then every test/vim/*_test.vim in its own Vim
# (skipped if Vim is missing, unless SUDA_TEST_REQUIRE_VIM=1).
# Usage: test/run.sh [test/file_test.lua | test/vim/file_test.vim ...]
# Exits non-zero if any test file fails.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
nvim=${NVIM:-nvim}
vim=${VIM_BIN:-vim}

if [ "$(id -u)" = 0 ]; then
  echo "test/run.sh: refusing to run as root (Protected Files would be readable)" >&2
  exit 2
fi

if [ $# -eq 0 ]; then
  set -- "$root"/test/*_test.lua "$root"/test/vim/*_test.vim
  [ -e "$1" ] || { echo "test/run.sh: no test/*_test.lua files" >&2; exit 2; }
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
out="$tmp/out"
# Vim quits when stdin hits EOF; a FIFO opened read-write never does.
mkfifo "$tmp/stdin"

# Runs: each Lua file twice (headless, then "file@tui"), each Vim file once.
runs=
for file in "$@"; do
  case $file in
    *.lua) runs="$runs $file $file@tui" ;;
    *) runs="$runs $file" ;;
  esac
done

status=0
for file in $runs; do
  echo "== $file"
  : >"$out"
  case $file in
    *@tui)
      if ! command -v script >/dev/null 2>&1; then
        if [ "${SUDA_TEST_REQUIRE_TUI:-0}" = 1 ]; then
          echo "  FAIL script(1) not found"
          status=1
        else
          echo "  skipped: script(1) not found"
        fi
        continue
      fi
      # script(1) gives test/tui.sh a pseudo-terminal and a process session.
      # Its stdin is the FIFO: on EOF, script would type ^D into the terminal.
      TERM=xterm-256color timeout 60 script -qec \
        "$(printf '%s %s %s %s' "$root/test/tui.sh" "$nvim" "${file%@tui}" "$out")" \
        /dev/null 0<>"$tmp/stdin" >/dev/null 2>&1
      code=$?
      ;;
    *.vim)
      if ! command -v "$vim" >/dev/null 2>&1; then
        if [ "${SUDA_TEST_REQUIRE_VIM:-0}" = 1 ]; then
          echo "  FAIL vim not found"
          status=1
        else
          echo "  skipped: vim not found"
        fi
        continue
      fi
      SUDA_TEST_OUT="$out" timeout 120 "$vim" -Nu NONE -i NONE --not-a-term \
        -S "$file" 0<>"$tmp/stdin" >/dev/null 2>&1
      code=$?
      ;;
    *)
      "$nvim" --headless --clean -u NONE -i NONE -l "$file" </dev/null >"$out" 2>&1
      code=$?
      ;;
  esac
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
