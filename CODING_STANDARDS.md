# Coding standards

Judgement calls for review. Mechanical rules live in the test suite (`test/run.sh`), not here.

## Domain language

User-facing text (help, README, error messages) and test names use the terms in `GLOSSARY.md`: **Protected File**, **Editor Session**, **Host Shell**, **Credential Scope**, **Terminal Client**. Unix process sessions are "process sessions", which keeps "Editor Session" for the glossary meaning. Claims about Credential Scope state its reach precisely: within the Editor Session, or shared with the Host Shell.

## One step sequence, two implementations

The sudo step sequence (credential check, then prompt, then exactly one run of the command) exists twice: `lua/suda/exec.lua` (Neovim backend) and `s:run_privileged()` in `autoload/suda.vim` (systemlist backend, needed for Vim). A change to the sequence lands in both, in the same commit. Every plugin behaviour test in `test/*_test.lua` registers through `h.test_each_backend`, so one test covers both copies. A test pinned to one backend says why in a comment.

## Step runner boundaries (ADR-0002)

`lua/suda/exec.lua` runs on whichever process starts sudo, so its results carry only `{code, stderr}`, plus stdout when no stdout file is given. Prompting, logging and Vimscript conversion stay in `lua/suda/server.lua` and `autoload/suda.vim`.

## Backend parity

Behaviour matches across backends, Vim and Neovim. Where it can't (Windows and csh shells keep stderr mixed into stdout), a comment at the branch states the difference and its reason, and the help mentions it if users can notice.
