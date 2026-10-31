---
status: accepted
---

# Run `sudo` from the Terminal Client instead of patching `sudo`

This supersedes the upstream half of ADR-0001. Interactive Neovim's server (`nvim --embed`) runs in its own session with no controlling TTY, and an unprivileged process can neither join another session nor adopt its TTY. So no amount of Lua inside the server can make `sudo` compute the **Host Shell**'s Credential Scope. The **Terminal Client** is already in the Host Shell's session and on its TTY. We decided that on Neovim (`has('nvim-0.10') && !has('win32')`) vim-suda will ask the Terminal Client to run each `sudo` step via `rpcrequest(ui.chan, 'nvim_exec_lua', ...)`, using `vim.system()` there. `sudo` (both `sudo-rs` and classic `sudo`, on Linux and macOS) then computes the same `Tty` scope as in the Host Shell. No change to `sudo-rs` or `sudo.ws` is needed. The ancestor TTY walk patches proposed in ADR-0001 are dropped.

## Consequences

- Delegation happens only when the UI reports `stdin_tty` and `stdout_tty`, its pid equals the server's `ppid` (so it is the same host and the process that embedded this server), and the RPC succeeds. Otherwise vim-suda falls back to `vim.system()` in the server, which shares `Ppid` scope within the Editor Session only. The guard matters: a remote UI must never run `sudo` on another host.
- The password prompt (`inputsecret()`) stays in the server. File contents never cross the RPC channel: the client writes `:SudaRead` output directly to the server's tempfile, and `:SudaWrite`'s `dd` reads a tempfile. Per step, the server sends the step runner's source, the sudo argv, the command's stdin (the password, once, if needed) and the server's environment and working directory, so the step runs as it would in the server; the client returns `{code, stderr}`. Stdout crosses only for `suda#system()`/`suda#systemlist()`, whose caller asked for it.
- The step runner (`lua/suda/exec.lua`) must be self-contained, because it is sent to the Terminal Client as source text and the client does not load vim-suda's runtimepath.
