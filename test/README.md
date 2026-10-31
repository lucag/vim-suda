# vim-suda tests

`test/run.sh` runs everything: each `test/*_test.lua` in headless Neovim, then each `test/vim/*_test.vim` in Vim. Pass file paths to run only those. CI sets `SUDA_TEST_REQUIRE_VIM=1`; locally the Vim files are skipped when Vim is missing.

## The fake sudo

`test/bin/sudo` (also linked as `sudo-rs`, `sudo.ws`, `doas`) stands in for the real tool. Its header documents the full contract: credential states (`cached`, `uncached`, `wrong-password`), a failing command, Protected File privilege emulation, and the per-call log (argv, stdin, ppid, sid, tty). Configure it with `h.fake_sudo{...}` in Lua or `SudaTestFakeSudo({...})` in Vim; both put it first on `$PATH` and assert that `sudo` resolves to it.

Run the plugin through these helpers only. A hand-typed `nvim`/`vim` command loads the plugin with the default `g:suda#executable` and reaches the real sudo. For a one-off check, add a test.

## Writing tests

- Plugin behaviour: `h.test_each_backend(name, fn)` runs the test on the Neovim (`vim.system`) and systemlist backends, via the internal `g:suda#_backend` override.
- Capture messages with `vim.fn.execute(cmd)`; errors appear as `[suda] ...`.
- Answer a password prompt with `h.answer_prompt(text)` (Lua) or `SudaTestAnswerPrompt(text)` (Vim), queued before the command.

## Gotchas

- `nvim -l` sets `'verbose'` to 1; `helpers.lua` resets it.
- vim-suda calls `inputsave()`, which discards typeahead, so `feedkeys()` never reaches the prompt. Lua uses `nvim_input()`; Vim feeds keys from a timer.
- An unanswered prompt reads EOF: headless Neovim quits with exit 0 mid-test (`run.sh` fails a file that prints no summary), and Vim quits too, which is why `run.sh` gives Vim a FIFO as stdin.
- Run Vim as `vim --not-a-term`; `vim -es` (Ex mode) drops a buffer line on `:SudaRead`.
- A funcref passed through `luaeval()` arrives in Lua as `nil`; Lua calls Vimscript through `vim.fn['suda#...']` instead.
- `vim.system()` keeps the child in nvim's process session; `systemlist()` detaches it into a new one. `sh -c 'cmd'` execs a lone command, so no shell sits between them either way.
- Real sudo dies by its command's signal; the fake re-raises it, and the step runner maps it to exit code 128 + signal.
