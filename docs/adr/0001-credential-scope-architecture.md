---
status: superseded by ADR-0002
---

# Preserve Credential Scope via `vim.system` and `sudo-rs` Ancestor TTY Resolution

Neovim's `systemlist()` spawns every child with `setsid()` (`UV_PROCESS_DETACHED`) and a `/bin/sh -c` wrapper, giving each `sudo` call a transient `ppid` and `session_pid` and breaking **Credential Scope** even within a single **Editor Session**; furthermore, interactive Neovim splits into a TUI client (in the **Host Shell**'s session and TTY) and an inner `nvim --embed` server spawned with `setsid()` (`tty_nr = 0`). We decided that on Neovim (`has('nvim')`), `vim-suda` will invoke `sudo` directly via `vim.system(argv, { stdin = ... })` (`detached = false`, separate `stdout`/`stderr` pipes) so all commands in an **Editor Session** share `nvim --embed`'s `ppid` and `session_pid` (`Ppid` scope), and we will pair this with a bounded same-user ancestor TTY walk in `sudo-rs`'s `RecordScope::for_tty` so `sudo-rs` resolves the parent Neovim TUI client's `tty_device` and **Host Shell** `session_pid` rather than requiring users to configure a pre-`setsid()` shell wrapper outside Neovim.
