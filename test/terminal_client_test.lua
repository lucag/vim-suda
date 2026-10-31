-- Which process starts sudo on the Neovim backend (ADR-0002): the Terminal
-- Client when the delegation guard passes, otherwise the server.
-- Pinned to the nvim backend: the system backend never delegates.
-- Some tests need a Terminal Client and register only under the TUI harness
-- (test/tui.sh); others need its absence and register only when headless.
local h = dofile(vim.fs.dirname(arg[0]) .. '/helpers.lua')
h.load_plugin()

local function tui_test(name, fn)
  if h.tui then
    h.test('[terminal client] ' .. name, fn)
  end
end

local function headless_test(name, fn)
  if not h.tui then
    h.test('[headless] ' .. name, fn)
  end
end

local function ex(cmd, path)
  return vim.fn.execute(cmd .. ' ' .. vim.fn.fnameescape(path))
end

-- Read and write a Protected File with no cached credential: four sudo steps
-- (validate + read, validate + write) and one password prompt.
local function read_and_write()
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({ state = 'uncached', protected = { path } })
  h.answer_prompt('secret')
  local messages = ex('SudaRead', path)
  h.eq({ 'x' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), messages)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'y' })
  messages = messages .. ex('SudaWrite', path)
  h.eq('y\n', h.read_protected(path), messages)
  local calls = fake.calls()
  h.eq(4, #calls, 'validate + read, validate + write')
  return calls, messages
end

tui_test('every sudo step runs in the Host Shell process session, on its terminal', function()
  local host_sid = tonumber(vim.env.SUDA_TEST_HOST_SID)
  local calls = read_and_write()
  for i, call in ipairs(calls) do
    h.eq(host_sid, call.sid, 'Host Shell process session, call ' .. i)
    h.ok(call.tty ~= 0, 'a controlling terminal, call ' .. i)
  end
end)

-- Each step was started by the server itself (no shell in between), in the
-- server's process session: Credential Scope within the Editor Session only.
local function assert_server_started(calls)
  local server = h.self_stat()
  for i, call in ipairs(calls) do
    h.eq(vim.fn.getpid(), call.ppid, 'started by the server, call ' .. i)
    h.eq(server.sid, call.sid, 'server process session, call ' .. i)
  end
end

local function with_verbose(fn)
  vim.o.verbose = 1
  local ok, err = pcall(fn)
  vim.o.verbose = 0
  assert(ok, err)
end

headless_test('with no UI attached, the server starts every sudo step and says why under verbose', function()
  local calls, messages
  with_verbose(function()
    calls, messages = read_and_write()
  end)
  assert_server_started(calls)
  h.ok(messages:find('[suda] running sudo from the server: no UI is attached', 1, true), messages)
end)

headless_test('without verbose, nothing is logged', function()
  local _, messages = read_and_write()
  h.ok(not messages:find('running sudo', 1, true), messages)
end)

-- Run {fn} with {tbl}[{key}] replaced by {value}, then restore it.
local function stubbed(tbl, key, value, fn)
  local orig = tbl[key]
  tbl[key] = value
  local ok, err = pcall(fn)
  tbl[key] = orig
  assert(ok, err)
end

-- The real UI list with {fields} overridden on every UI.
local function uis_with(fields)
  local real = vim.api.nvim_list_uis
  return function()
    return vim.tbl_map(function(ui)
      return vim.tbl_extend('force', ui, fields)
    end, real())
  end
end

tui_test('with the Terminal Client, verbose says so', function()
  local messages
  with_verbose(function()
    messages = select(2, read_and_write())
  end)
  h.ok(messages:find('[suda] running sudo from the Terminal Client (UI on channel ', 1, true), messages)
end)

tui_test('a UI without a terminal on stdin falls back to the server', function()
  stubbed(vim.api, 'nvim_list_uis', uis_with({ stdin_tty = false }), function()
    local calls, messages
    with_verbose(function()
      calls, messages = read_and_write()
    end)
    assert_server_started(calls)
    h.ok(messages:find('running sudo from the server: UI on channel %d+ has no terminal on stdin and stdout'), messages)
  end)
end)

tui_test('a UI without a terminal on stdout falls back to the server', function()
  stubbed(vim.api, 'nvim_list_uis', uis_with({ stdout_tty = false }), function()
    assert_server_started(read_and_write())
  end)
end)

tui_test("a UI that is not the server's parent process falls back to the server", function()
  stubbed(vim.uv, 'os_getppid', function()
    return 1
  end, function()
    local calls, messages
    with_verbose(function()
      calls, messages = read_and_write()
    end)
    assert_server_started(calls)
    h.ok(messages:find("running sudo from the server: UI on channel %d+ is process %d+, not the server's parent 1"), messages)
  end)
end)

tui_test('a UI whose RPC call fails falls back to the server', function()
  stubbed(vim, 'rpcrequest', function()
    error('channel closed')
  end, function()
    local calls, messages
    with_verbose(function()
      calls, messages = read_and_write()
    end)
    assert_server_started(calls)
    h.ok(messages:find('running sudo from the server: UI on channel %d+ failed the RPC call: .*channel closed'), messages)
  end)
end)

tui_test('a tool that is not sudo-compatible runs from the server: it could prompt on the terminal', function()
  vim.g['suda#executable'] = 'doas'
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({ state = 'cached', protected = { path } })
  local messages
  with_verbose(function()
    messages = ex('SudaRead', path)
  end)
  h.eq({ 'x' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), messages)
  assert_server_started(fake.calls())
  h.ok(messages:find("running sudo from the server: g:suda#executable is not sudo-compatible", 1, true), messages)
end)

tui_test('file contents never cross the RPC channel, and the password crosses once and is never logged', function()
  local old, new = 'old-contents-7f3a', 'new-contents-9c1e'
  local path = h.protected_file(h.tempdir(), 'shadow', old .. '\n')
  h.fake_sudo({ state = 'uncached', password = 'pw-5d2b', protected = { path } })
  local traffic = {}
  local real = vim.rpcrequest
  local function recording(...)
    local res = real(...)
    table.insert(traffic, vim.inspect({ ... }) .. vim.inspect(res))
    return res
  end
  local messages
  stubbed(vim, 'rpcrequest', recording, function()
    with_verbose(function()
      h.answer_prompt('pw-5d2b')
      messages = ex('SudaRead', path)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { new })
      messages = messages .. ex('SudaWrite', path)
    end)
  end)
  h.eq({ new }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  h.eq(new .. '\n', h.read_protected(path))

  local all = table.concat(traffic, '\n')
  h.ok(#traffic > 0, 'the Terminal Client was used')
  h.ok(not all:find(old, 1, true), 'read contents crossed the channel')
  h.ok(not all:find(new, 1, true), 'written contents crossed the channel')
  local _, sent = all:gsub('pw%-5d2b', '')
  h.eq(1, sent, 'the password crosses once')
  h.ok(messages:find('running sudo from the Terminal Client', 1, true), messages)
  h.ok(not messages:find('pw-5d2b', 1, true), 'the password is logged: ' .. messages)
end)

h.run()
