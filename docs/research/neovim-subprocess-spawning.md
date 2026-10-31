# Research: Neovim Subprocess Spawning, Session IDs, and Controlling TTYs

## Question

When Neovim runs `systemlist()`, `system()`, or `jobstart()`, libuv spawns the child with `UV_PROCESS_DETACHED` (`setsid()`), stripping the controlling terminal (`tty_nr = 0`) and creating a new transient `session_pid`. What mechanisms available to a Neovim plugin on Linux and macOS can execute `sudo` without `setsid()` so the child process inherits Neovim's `session_pid` and controlling `tty_device` while still passing `stdin` and capturing `stdout`/`stderr`?

## Primary Sources & Empirical Findings

### 1. Why `systemlist()`, `system()`, and `jobstart()` break Credential Scope even within the same Editor Session

In Neovim's C process spawning layer (`src/nvim/os/proc.c`, `proc_spawn`), standard Vimscript job/system functions (`system()`, `systemlist()`, `jobstart()`) pass `UV_PROCESS_DETACHED` to `uv_spawn()` unless a PTY is allocated. In libuv (`src/unix/process.c`, `uv__process_child_init`), `UV_PROCESS_DETACHED` invokes `setsid()` in the forked child before `execvp()`.

Additionally, passing a string command to `systemlist(cmd)` invokes `/bin/sh -c cmd`, inserting an ephemeral shell process as the immediate parent (`ppid`) of `sudo`.

Empirical verification (`NVIM v0.12.6` on Linux):

```text
=== Parent Shell ===
pid=15882 ppid=15879 pgrp=15879 session=15879 tty_nr=34818
=== 1. systemlist() ===
['pid=15884 ppid=15883 pgrp=15884 session=15884 tty_nr=0']
```

Every `systemlist()` call creates a brand-new session (`session=15884`) with `tty_nr=0` and a transient `ppid=15883` that exits immediately when `systemlist()` returns. Any `sudo` timestamp record tied to `session_pid` or `parent_pid` is invalidated as soon as the command finishes.

### 2. `vim.system()` and `vim.uv.spawn(..., { detached = false })` preserve the Neovim server's `session_pid` and `ppid`

Neovim's Lua API provides `vim.system(cmd, opts)` (built on `vim.uv.spawn`, where `opts.detach` defaults to `false`). When passed an argv table (`{"sudo", "-p", "", "-S", "--", ...}`) with `detach = false`:

1. Libuv does **not** call `setsid()`, so the child process inherits the spawning Neovim process's `session_pid` (`sid`), process group (`pgrp`), and controlling terminal (`tty_nr`).
2. `sudo` is executed directly via `execvp` without an intermediate `/bin/sh -c` process, so `sudo`'s `ppid` is the persistent Neovim server PID for the entire **Editor Session**.
3. `vim.system()` attaches separate pipes for `stdin`, `stdout`, and `stderr`, allowing `stdin = password .. "\n"` while keeping `stderr` (such as `sudo-rs` 0.2.13's empty-prompt newline or PAM messages) completely separate from `stdout`.

Empirical verification (`nvim --headless`):

```text
=== 2. vim.system() ===
pid=15886 ppid=15885 pgrp=15879 session=15879 tty_nr=34818
=== 3. vim.uv.spawn (detached=false) ===
stdin_ok pid=15890 ppid=15888 pgrp=15879 session=15879 tty_nr=34818
```

### 3. Crucial Architecture Constraint: Interactive TUI Neovim (`nvim --embed` Server Split)

Since Neovim 0.9, launching interactive `nvim` in a terminal runs **two** processes:
1. **Outer TUI Client (`nvim`)**: Direct child of the **Host Shell**. Retains the **Host Shell**'s `session_pid` and controlling terminal (`tty_nr`).
2. **Inner Embedded Server (`nvim --embed`)**: Spawned by the TUI client to run all Vimscript, Lua, buffers, and plugins. The TUI client spawns `nvim --embed` with `UV_PROCESS_DETACHED` (`setsid()`).

Empirical verification inside a live interactive PTY:

```text
HOST_SHELL:  pid=15928 ppid=15927 pgrp=15927 session=15927 tty_nr=34820
NVIM_CLIENT: pid=15929 ppid=15928 pgrp=15929 session=15927 tty_nr=34820
NVIM_SERVER: pid=15930 ppid=15929 pgrp=15930 session=15930 tty_nr=0
VIM_SYSTEM:  pid=15931 ppid=15930 pgrp=15930 session=15930 tty_nr=0
BANG (:!):   pid=15954 ppid=15953 pgrp=15953 session=15953 tty_nr=0
```

Consequences:
- **Within the same Editor Session**: Using `vim.system()` (with an argv list and `detach = false`) ensures every `sudo` invocation inside `nvim --embed` has `ppid = <NVIM_SERVER PID>` (`15930`) and `session_pid = <NVIM_SERVER PID>` (`15930`), which remain constant for the lifetime of the **Editor Session**.
- **Between Editor Session and Host Shell**: Because `nvim --embed` (`15930`) is already in its own POSIX session (`sid = 15930`, `tty_nr = 0`), no subprocess forked from `nvim --embed` (whether via `vim.system()`, `vim.uv.spawn`, `:!`, or LuaJIT FFI `fork`/`exec`) can re-enter the **Host Shell**'s POSIX session (`sid = 15927`) or acquire the **Host Shell**'s controlling terminal (`TIOCSCTTY` returns `EPERM` when the PTY already has an active session leader). Only the parent TUI client (`getppid()` of `nvim --embed`, `pid = 15929`) resides in the **Host Shell**'s session (`sid = 15927`, `tty_nr = 34820`).
