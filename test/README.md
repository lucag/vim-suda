# vim-suda tests

`test/run.sh` runs everything: each `test/*_test.lua` in headless Neovim and again under the TUI harness, then each `test/vim/*_test.vim` in Vim. Pass file paths to run only those. CI sets `SUDA_TEST_REQUIRE_VIM=1` and `SUDA_TEST_REQUIRE_TUI=1`; locally the Vim files are skipped when Vim is missing, and the TUI runs are skipped when `script(1)` is missing.

## Other Neovim versions

CI runs the suite on each Neovim in the matrix in `.github/workflows/test.yml`: the oldest supported, the oldest that delegates to the Terminal Client, and `stable`. Run one locally with `test/nvim-version.sh <tag>`, which downloads the release once into `.cache/nvim/` and prints its `nvim`:

```sh
test/nvim-version.sh v0.12.0
NVIM=<printed path> test/run.sh
```

Run it on its own first: its download needs the network.

## The TUI harness

`test/tui.sh` is a Host Shell: `script(1)` starts it on a pseudo-terminal as a process session leader, and it runs interactive `nvim`. The test file runs in the server (`nvim --embed`), so the Terminal Client delegation path (ADR-0002) is live. `h.tui` is true there, `$SUDA_TEST_HOST_SID` holds the Host Shell's session id, and results go to `$SUDA_TEST_OUT` because the server's stdout is its RPC channel. `test/terminal_client_test.lua` registers some tests only under one harness, and the delegation tests only on Neovim 0.12+ (older Terminal Clients never answer the server; there it checks the fallback instead).

## Manual acceptance with the real sudo

`test/manual/credential-scope.sh [sudo-rs] [sudo.ws]` checks Credential Scope sharing with the real tools: Host Shell → editor, editor → Host Shell, and that the fallback (a remote UI) stays within the Editor Session. Run it yourself from an interactive terminal: it asks for your password in the shell and in the editor, and runs only `sudo -K`, `sudo -v` and `sudo true`. Re-run it after changing the delegation path or the step sequence. Agents never run it.

## The fake sudo

`test/bin/sudo` (also linked as `sudo-rs`, `sudo.ws`, `doas`) stands in for the real tool. Its header documents the full contract: credential states (`cached`, `uncached`, `wrong-password`), a failing command, Protected File privilege emulation, and the per-call log (argv, stdin, ppid, sid, tty). Configure it with `h.fake_sudo{...}` in Lua or `SudaTestFakeSudo({...})` in Vim; both put it first on `$PATH` and assert that `sudo` resolves to it.

Run the plugin through these helpers only. A hand-typed `nvim`/`vim` command loads the plugin with the default `g:suda#executable` and reaches the real sudo. For a one-off check, add a test.

## Writing tests

- Plugin behaviour: `h.test_each_backend(name, fn)` runs the test on the Neovim (`vim.system`) and systemlist backends, via the internal `g:suda#_backend` override.
- Capture messages with `vim.fn.execute(cmd)`; errors appear as `[suda] ...`.
- Answer a password prompt with `h.answer_prompt(text)` (Lua) or `SudaTestAnswerPrompt(text)` (Vim), queued before the command.

## Gotchas

- Under the TUI harness, never write to stdout from a test: it corrupts the server's RPC channel. Messages that scroll past the command line stop at a hit-enter prompt, so capture them with `vim.fn.execute()`.

- Headless runs echo the password prompt (`Password: ******`) into the output, glued to the next result line. That is expected, not a regression.
- `nvim -l` sets `'verbose'` to 1; `helpers.lua` resets it.
- vim-suda calls `inputsave()`, which discards typeahead, so `feedkeys()` never reaches the prompt. Lua uses `nvim_input()`; Vim feeds keys from a timer.
- An unanswered prompt reads EOF: headless Neovim quits with exit 0 mid-test (`run.sh` fails a file that prints no summary), and Vim quits too, which is why `run.sh` gives Vim a FIFO as stdin.
- Run Vim as `vim --not-a-term`; `vim -es` (Ex mode) drops a buffer line on `:SudaRead`.
- A funcref passed through `luaeval()` arrives in Lua as `nil`; Lua calls Vimscript through `vim.fn['suda#...']` instead.
- `vim.system()` keeps the child in nvim's process session; `systemlist()` detaches it into a new one. `sh -c 'cmd'` execs a lone command, so no shell sits between them either way.
- Real sudo dies by its command's signal; the fake re-raises it, and the step runner maps it to exit code 128 + signal.
