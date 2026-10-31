-- Minimal test helpers for vim-suda. No framework dependency.
--
-- A test file looks like:
--   local h = dofile(vim.fs.dirname(arg[0]) .. '/helpers.lua')
--   h.test('does a thing', function() h.eq(1, 1) end)
--   h.run()

local M = {}

-- `nvim -l` sets 'verbose' to 1; run the plugin with the default instead.
vim.o.verbose = 0

M.root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
M.bin = M.root .. '/test/bin'

local tests = {}

function M.test(name, fn)
  table.insert(tests, { name = name, fn = fn })
end

function M.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      string.format(
        '%sexpected: %s\n  actual: %s',
        msg and (msg .. '\n') or '',
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function M.ok(cond, msg)
  if not cond then
    error(msg or 'expected a truthy value', 2)
  end
end

local function reset_editor()
  vim.cmd('silent! %bwipeout!')
  vim.g['suda#noninteractive'] = 0
  vim.g['suda#_backend'] = nil
  vim.v.errmsg = ''
end

-- Run every registered test, print a summary and exit non-zero on failure.
function M.run()
  local failed = 0
  for _, t in ipairs(tests) do
    reset_editor()
    local ok, err = xpcall(t.fn, debug.traceback)
    if ok then
      io.stdout:write('  ok   ' .. t.name .. '\n')
    else
      failed = failed + 1
      io.stdout:write('  FAIL ' .. t.name .. '\n    ' .. tostring(err):gsub('\n', '\n    ') .. '\n')
    end
    M.cleanup()
  end
  io.stdout:write(string.format('  %d passed, %d failed\n', #tests - failed, failed))
  io.stdout:flush()
  os.exit(failed > 0 and 1 or 0)
end

-- Temporary paths created by a test, removed after it.
local scratch = {}

function M.tempdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  table.insert(scratch, dir)
  return dir
end

function M.cleanup()
  for _, dir in ipairs(scratch) do
    -- Protected Files have no permissions; restore them so they can be deleted.
    vim.system({ 'chmod', '-R', 'u+rwX', dir }):wait()
    vim.fn.delete(dir, 'rf')
  end
  scratch = {}
end

function M.read_bytes(path)
  local f = assert(io.open(path, 'rb'))
  local data = f:read('*a')
  f:close()
  return data
end

function M.write_bytes(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end

local function chmod(path, mode)
  assert(vim.uv.fs_chmod(path, tonumber(mode, 8)))
end

-- Create a Protected File, emulated with mode 000 (the tests never run as root).
function M.protected_file(dir, name, content)
  local path = dir .. '/' .. name
  M.write_bytes(path, content)
  chmod(path, '000')
  return path
end

-- Read a Protected File's bytes by briefly granting access.
function M.read_protected(path)
  chmod(path, '600')
  local data = M.read_bytes(path)
  chmod(path, '000')
  return data
end

-- Configure the fake `sudo` (test/bin/sudo) and put it first on $PATH.
--
-- opts:
--   state     'cached' | 'uncached' | 'wrong-password' (default 'uncached')
--   password  the password the fake accepts on -S (default 'secret')
--   fail      { cmd = 'cat', stdout = 'out', stderr = 'message' }: running
--             `cmd` writes `stdout` (optional), then fails with `stderr` on
--             stderr and exit code 1
--   protected list of Protected File paths made accessible while a command runs
--
-- Returns an object with:
--   calls()   list of { argv, stdin, ppid, sid, tty } per invocation, in order
--   state()   the fake's current credential state
--   run(args, stdin) run the fake directly; returns vim.system() result
function M.fake_sudo(opts)
  opts = opts or {}
  local dir = M.tempdir() .. '/fake-sudo'
  vim.fn.mkdir(dir .. '/calls', 'p')
  M.write_bytes(dir .. '/state', (opts.state or 'uncached') .. '\n')
  M.write_bytes(dir .. '/password', (opts.password or 'secret') .. '\n')
  if opts.fail then
    M.write_bytes(dir .. '/fail_cmd', opts.fail.cmd .. '\n')
    M.write_bytes(dir .. '/fail_stderr', opts.fail.stderr)
    if opts.fail.stdout then
      M.write_bytes(dir .. '/fail_stdout', opts.fail.stdout)
    end
  end
  M.write_bytes(dir .. '/protected', table.concat(opts.protected or {}, '\n') .. '\n')

  vim.env.FAKE_SUDO_DIR = dir
  if not vim.startswith(vim.env.PATH, M.bin .. ':') then
    vim.env.PATH = M.bin .. ':' .. vim.env.PATH
  end
  -- Never let a test reach the real sudo.
  assert(vim.fn.exepath('sudo') == M.bin .. '/sudo', 'sudo does not resolve to the fake: ' .. vim.fn.exepath('sudo'))

  local fake = {}

  function fake.state()
    return vim.trim(M.read_bytes(dir .. '/state'))
  end

  function fake.calls()
    local calls = {}
    local n = 1
    while vim.fn.isdirectory(dir .. '/calls/' .. n) == 1 do
      local c = dir .. '/calls/' .. n
      local argv = vim.split(M.read_bytes(c .. '/argv'), '\0', { plain = true })
      table.remove(argv) -- trailing NUL terminator
      table.insert(calls, {
        argv = argv,
        stdin = M.read_bytes(c .. '/stdin'),
        ppid = tonumber(vim.trim(M.read_bytes(c .. '/ppid'))),
        sid = tonumber(vim.trim(M.read_bytes(c .. '/sid'))),
        tty = tonumber(vim.trim(M.read_bytes(c .. '/tty'))),
      })
      n = n + 1
    end
    return calls
  end

  function fake.run(args, stdin)
    return vim.system(vim.list_extend({ 'sudo' }, args), { stdin = stdin, text = true }):wait()
  end

  return fake
end

-- Queue an answer to the next input()/inputsecret() prompt.
-- Uses nvim_input() rather than feedkeys(): vim-suda calls inputsave(), which
-- clears typeahead, and an unanswered prompt in headless Neovim reads EOF from
-- stdin and quits.
function M.answer_prompt(text)
  vim.api.nvim_input(text:gsub('<', '<lt>') .. '<CR>')
end

-- Register {name} once per vim-suda backend, with g:suda#_backend forced.
function M.test_each_backend(name, fn)
  for _, backend in ipairs({ 'nvim', 'system' }) do
    M.test(string.format('[%s] %s', backend, name), function()
      vim.g['suda#_backend'] = backend
      fn()
    end)
  end
end

-- Fields of /proc/self/stat after "(comm) ": state, ppid, pgrp, session,
-- tty_nr, ... as numbers where numeric.
function M.self_stat()
  local fields = vim.split(M.read_bytes('/proc/self/stat'):gsub('^.*%) ', ''), ' ')
  return { ppid = tonumber(fields[2]), sid = tonumber(fields[4]), tty = tonumber(fields[5]) }
end

-- Load vim-suda from this checkout.
function M.load_plugin()
  if vim.g.loaded_suda == nil then
    vim.opt.runtimepath:prepend(M.root)
    vim.cmd('runtime plugin/suda.vim')
  end
end

return M
