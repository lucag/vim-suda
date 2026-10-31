# Research: `sudo-rs` and `sudo.ws` Timestamp Scope Matching for Editor Session and Host Shell

## Question

How do `sudo-rs` (`src/system/timestamp.rs`) and classic `sudo` (`sudo.ws`) construct, store, and match `tty` and `ppid` timestamp records (`tty_device`, `session_pid`, `group_pid`/`parent_pid`, `init_time`), and what exact process attributes (`sid`, `ppid`, `pgrp`, `tty_nr`, `/dev/tty`, stdio fds) must a `sudo` invocation inside Neovim have so its cached credential is shared both across multiple `:SudaRead`/`:SudaWrite` calls in the same **Editor Session** and bidirectionally with the **Host Shell**?

## Primary Sources & Analysis

### 1. How `sudo-rs` Computes and Matches `RecordScope`

In `sudo-rs` (`src/system/timestamp.rs:336-459`, `src/sudo/pipeline.rs:178-189`, and `src/system/mod.rs:680-831`):

- `Process::new()` (`src/system/mod.rs:687-692`) captures:
  - `parent_pid`: `std::os::unix::process::parent_id()` (`getppid()`)
  - `session_id`: `libc::getsid(0)`
- `RecordScope::for_tty(process)` (`src/system/timestamp.rs:424-439`, or `RecordScope::for_process` in `v0.2.13`):
  1. Reads field 7 (`tty_nr`, 0-based index 6) of `/proc/self/stat` via `Process::tty_device_id(WithProcess::Current)` (`src/system/mod.rs:719-732`).
  2. If `tty_nr != 0`, it reads field 22 (`starttime`, 0-based index 21) of `/proc/<session_id>/stat` via `Process::starting_time(WithProcess::Other(process.session_id))` and constructs:
     ```rust
     RecordScope::Tty {
         tty_device,
         session_pid: process.session_id,
         init_time, // start time of session_pid
     }
     ```
  3. If `tty_nr == 0` (`Ok(None)`), `for_tty` **falls back automatically to `RecordScope::for_ppid(process)`** (`src/system/timestamp.rs:425-427`)!
- `RecordScope::for_ppid(process)` (`src/system/timestamp.rs:445-458`):
  1. Takes `parent_pid = process.parent_pid` (`getppid()`).
  2. Reads `/proc/<parent_pid>/stat` for `init_time = Process::starting_time(WithProcess::Other(parent_pid))`.
  3. Constructs:
     ```rust
     RecordScope::Ppid {
         group_pid: parent_pid,
         session_pid: process.session_id,
         init_time, // start time of parent_pid
     }
     ```
- Matching (`SessionRecord::matches` in `src/system/timestamp.rs:509-512`): requires exact equality of `self.scope == scope && self.auth_user == auth_user.uid`.

### 2. How Classic `sudo` (`sudo.ws`) Computes and Matches Timestamp Records

In `sudo.ws` (`plugins/sudoers/timestamp.c` and `sudoers(5)`):
- Default `timestamp_type` is `tty` (`TS_TTY`): records the controlling terminal device number (`ttydev`), the session leader ID (`sid`), and the session leader's start time (`start_time`).
- When `timestamp_type` is `ppid` (`TS_PPID`) or when the process has no controlling terminal (`ttydev == NODEV`), `sudo.ws` scopes the record to the parent process ID (`ppid`), `sid`, and the parent process's start time.

### 3. Tracing Process Attributes Across Host Shell and Neovim Editor Session

In an interactive terminal session where the user launches `nvim`:

| Process | `pid` | `ppid` | `session_id` (`sid`) | `tty_nr` (`/proc/<pid>/stat`) | `RecordScope` computed by `sudo-rs` |
| --- | --- | --- | --- | --- | --- |
| **Host Shell** (`bash`/`zsh`) | $S$ | $T$ | $S$ | $D \neq 0$ | — |
| `sudo` run in **Host Shell** | $P_1$ | $S$ | $S$ | $D \neq 0$ | `Tty { tty_device: D, session_pid: S, init_time: start(S) }` |
| **Neovim TUI client** (`nvim`) | $C$ | $S$ | $S$ | $D \neq 0$ | — |
| **Neovim server** (`nvim --embed`) | $E$ | $C$ | $E$ (`setsid()`) | `0` | — |
| `sudo` via `systemlist()` in `nvim` | $P_2$ | $H$ (`/bin/sh`) | $H$ (`setsid()`) | `0` | `Ppid { group_pid: H, session_pid: H, init_time: start(H) }` (ephemeral!) |
| `sudo` via `vim.system()` in `nvim` | $P_3$ | $E$ (`nvim --embed`) | $E$ | `0` | `Ppid { group_pid: E, session_pid: E, init_time: start(E) }` (persistent across **Editor Session**!) |

### 4. Key Conclusions for `vim-suda` and `sudo-rs`

1. **Intra-Editor Session sharing (`vim-suda` alone)**:
   - Because `RecordScope::for_tty` in `sudo-rs` (and `sudo.ws`) automatically falls back to `RecordScope::Ppid` when `tty_nr == 0`, spawning `sudo` directly from `nvim --embed` via `vim.system(argv)` (without `setsid()` and without `/bin/sh -c`) yields `RecordScope::Ppid { group_pid: E, session_pid: E, init_time: start(E) }` on every invocation.
   - This record persists for the entire lifetime of the `nvim --embed` **Editor Session** $E$, solving repeated password prompts across multiple `:SudaRead` / `:SudaWrite` commands in the same **Editor Session**.

2. **Editor Session ↔ Host Shell sharing**:
   - In the **Host Shell**, `sudo` has `tty_nr = D != 0` and `session_id = S`, so it reads/writes `RecordScope::Tty { tty_device: D, session_pid: S, init_time: start(S) }`.
   - Inside `nvim --embed` ($E$), the server was spawned by the Neovim TUI client ($C$) with `setsid()`, so $E$ and all its descendants have `tty_nr = 0` and `session_id = E`.
   - For a `sudo` invocation triggered from `nvim --embed` to share the **Host Shell**'s `RecordScope::Tty { tty_device: D, session_pid: S, init_time: start(S) }`, one of two things must happen:
     - **Option A (in `sudo-rs`)**: When `Process::tty_device_id(WithProcess::Current)` is `None` (`tty_nr == 0`), `RecordScope::for_tty` can walk up the ancestor chain (`/proc/<ppid>/stat`) to find the nearest ancestor with a controlling terminal (`tty_nr != 0`)—which for `nvim --embed` is its immediate parent, the Neovim TUI client $C$ (`tty_nr = D`, `session_id = S`)—and use that ancestor's `(tty_device, session_pid, init_time)` (potentially gated on same real UID), OR
     - **Option B (in `vim-suda` / Neovim)**: Execute `sudo` in the context of the outer TUI client / **Host Shell** session (for example, Neovim's TUI client or a helper started in the **Host Shell** session before `setsid()`), since no child forked by `nvim --embed` can regain `session_id = S` or `tty_nr = D` under Linux kernel rules.

3. **Additional `sudo-rs` `-S` / `-p ''` findings**:
   - In `sudo-rs` 0.2.13 (`src/pam/rpassword.rs`), `Bullets::drop` wrote `\n` to `stderr` even when `-p ''` suppressed the prompt (fixed in `sudo-rs` commit `ad069855` / PR #1655). Using `vim.system()` separates `stdout` from `stderr`, preventing that `\n` on `stderr` from corrupting file contents read via `sudo cat` on `stdout`.
