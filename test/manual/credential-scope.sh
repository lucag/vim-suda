#!/bin/sh
# Manual acceptance check of Credential Scope sharing with the real sudo
# (issue #14, ADR-0002). Run it from an interactive terminal; it is your Host
# Shell. It asks for your password several times, in the shell and in the
# editor, and runs only `sudo -v`, `sudo -K` and `sudo true`.
#
# Usage: test/manual/credential-scope.sh [sudo-rs] [sudo.ws] [sudo]
# Default: every one of sudo-rs and sudo.ws that is installed.
# Needs Neovim 0.10+ on $PATH (or $NVIM) and setsid(1): Linux. Exits non-zero
# if any check fails. The editors quit by themselves once a check has run.
#
# For each flavour it checks:
#   1. Host Shell -> editor: after `sudo -v` in the Host Shell, the Terminal
#      Client runs sudo without a password.
#   2. editor -> Host Shell: after a password typed in the editor, `sudo -n
#      true` in the Host Shell needs none.
#   3. Fallback (a remote UI, which fails the delegation guard): a password
#      typed in the editor is reused within the Editor Session, but not in the
#      Host Shell, and a Host Shell credential is not used by the editor.
# Each check removes cached credentials first (`sudo -K`).
set -u

root=$(cd "$(dirname "$0")/../.." && pwd)
nvim=${NVIM:-nvim}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "credential-scope.sh: run me from an interactive terminal" >&2
  exit 2
fi

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; failed=1; }

# Run the editor check (check.lua) with {steps} for {exe}, in a TUI editor
# whose Terminal Client is this shell's child. Sets $out to the result lines.
editor() {
  rm -f "$tmp/result"
  SUDA_ROOT=$root SUDA_EXE=$1 SUDA_STEPS=$2 SUDA_RESULT=$tmp/result \
    "$nvim" --clean -u NONE -i NONE --cmd "luafile $root/test/manual/check.lua"
  report
}

# Like editor(), but the server runs detached (its own process session, no
# terminal) and a remote UI attaches to it: the delegation guard fails.
remote_editor() {
  rm -f "$tmp/result" "$tmp/nvim.sock"
  sock=$tmp/nvim.sock
  SUDA_ROOT=$root SUDA_EXE=$1 SUDA_STEPS=$2 SUDA_RESULT=$tmp/result \
    setsid -f "$nvim" --clean -u NONE -i NONE --headless --listen "$sock" \
    --cmd "luafile $root/test/manual/check.lua" </dev/null >/dev/null 2>&1
  wait_for -S "$sock" || { echo "     the editor server did not start"; out=; return; }
  "$nvim" --remote-ui --server "$sock"
  wait_for -s "$tmp/result"
  report
}

# Wait up to 10 seconds for `test {flag} {path}`.
wait_for() {
  i=0
  while [ ! "$1" "$2" ]; do
    i=$((i + 1))
    [ $i -le 100 ] || return 1
    sleep 0.1
  done
}

report() {
  out=$(cat "$tmp/result" 2>/dev/null)
  echo "$out" | sed 's/^/     /'
}

# Exit code of {step} in result lines on stdin.
code_of() { awk -v s="$1" '$1 == s { print $2; exit }'; }

check_flavour() {
  exe=$1
  say "== $exe"

  say "1. Host Shell -> editor. Enter your password for $exe in the shell:"
  "$exe" -K && "$exe" -v || { fail "$exe -v in the Host Shell"; return; }
  editor "$exe" cached
  echo "$out" | grep -q 'running sudo from the Terminal Client' \
    || fail "the editor did not run sudo from the Terminal Client"
  [ "$(echo "$out" | code_of cached)" = 0 ] \
    && pass "the editor used the Host Shell credential" \
    || fail "the editor did not use the Host Shell credential"

  say "2. editor -> Host Shell. Enter your password for $exe in the editor:"
  "$exe" -K
  editor "$exe" prompt,cached
  echo "$out" | grep -q 'running sudo from the Terminal Client' \
    || fail "the editor did not run sudo from the Terminal Client"
  [ "$(echo "$out" | code_of prompt)" = 0 ] || fail "sudo failed in the editor"
  "$exe" -n true 2>/dev/null \
    && pass "the Host Shell used the editor credential" \
    || fail "the Host Shell did not use the editor credential"

  say "3. Fallback (remote UI). Enter your password for $exe in the editor:"
  "$exe" -K
  remote_editor "$exe" prompt,cached
  echo "$out" | grep -q 'running sudo from the server' \
    || fail "the editor did not fall back to the server"
  [ "$(echo "$out" | code_of cached)" = 0 ] \
    && pass "the credential is reused within the Editor Session" \
    || fail "the credential is not reused within the Editor Session"
  "$exe" -n true 2>/dev/null \
    && fail "the Host Shell used the fallback editor's credential" \
    || pass "the fallback editor's credential stays within its Editor Session"

  say "   Enter your password for $exe in the shell:"
  "$exe" -K && "$exe" -v || { fail "$exe -v in the Host Shell"; return; }
  remote_editor "$exe" cached
  [ "$(echo "$out" | code_of cached)" = 0 ] \
    && fail "the fallback editor used the Host Shell credential" \
    || pass "the fallback editor did not use the Host Shell credential"
  "$exe" -K
}

if [ $# -eq 0 ]; then
  for exe in sudo-rs sudo.ws; do
    command -v "$exe" >/dev/null 2>&1 && set -- "$@" "$exe"
  done
  [ $# -gt 0 ] || { echo "credential-scope.sh: neither sudo-rs nor sudo.ws found" >&2; exit 2; }
fi
for exe in "$@"; do
  check_flavour "$exe"
done

say "$([ $failed = 0 ] && echo 'All checks passed.' || echo 'Some checks FAILED.')"
exit $failed
