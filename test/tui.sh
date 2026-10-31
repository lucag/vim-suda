#!/bin/sh
# Host Shell of the TUI harness. test/run.sh starts it under script(1), which
# makes it a process session leader with a pseudo-terminal as its controlling
# terminal. It then runs Neovim's Terminal Client in that process session; the
# test file runs in the server (nvim --embed) the client starts.
# Usage: test/tui.sh <nvim> <test file> <results file>
set -u

# Fields after "(comm) ": state ppid pgrp session tty_nr ...
SUDA_TEST_HOST_SID=$(sed 's/^.*) //' /proc/$$/stat | awk '{ print $4 }')
SUDA_TEST_FILE=$2
SUDA_TEST_OUT=$3
SUDA_TEST_TUI=1
export SUDA_TEST_HOST_SID SUDA_TEST_FILE SUDA_TEST_OUT SUDA_TEST_TUI

# Not `exec`: this shell stays the session leader, as a real Host Shell does.
"$1" --clean -u NONE -i NONE \
  -c 'lua _G.arg = { [0] = vim.env.SUDA_TEST_FILE }; dofile(vim.env.SUDA_TEST_FILE)'
# A command after nvim keeps a shell from exec'ing it as its last command.
code=$?
exit $code
