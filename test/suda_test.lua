-- :SudaRead and :SudaWrite on a Protected File, through the fake `sudo`.
-- These characterise today's behaviour.
local h = dofile(vim.fs.dirname(arg[0]) .. '/helpers.lua')
h.load_plugin()

local test = h.test_each_backend

-- Run an Ex command and return the messages it produced.
local function ex(cmd, path)
  return vim.fn.execute(cmd .. ' ' .. vim.fn.fnameescape(path))
end

-- Assert that vim-suda reported {msg} as an error.
local function reports(out, msg)
  if not out:find('[suda] ' .. msg, 1, true) then
    error(string.format('expected "[suda] %s" in messages:\n%s', msg, out), 2)
  end
end

local function sudaread(path)
  return ex('SudaRead', path)
end

local function argvs(fake)
  return vim.tbl_map(function(c)
    return c.argv
  end, fake.calls())
end

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

test(':SudaRead loads a Protected File into a suda:// buffer', function()
  local path = h.protected_file(h.tempdir(), 'hosts', 'line one\nline two\n')
  local fake = h.fake_sudo({ state = 'cached', protected = { path } })

  sudaread(path)

  h.eq('suda://' .. path, vim.api.nvim_buf_get_name(0))
  h.eq({ 'line one', 'line two' }, lines())
  h.eq(false, vim.bo.modified)
  h.eq('acwrite', vim.bo.buftype)
  h.eq({ { '-n', '-v' }, { '-n', '--', 'cat', path } }, argvs(fake))
  h.eq('', fake.calls()[2].stdin)
end)

-- The privileged `dd` call made by :SudaWrite, with its temporary input file.
local function is_dd_write(argv, opts, path)
  return vim.deep_equal(vim.list_extend(vim.deepcopy(opts), { '--', 'dd' }), vim.list_slice(argv, 1, #opts + 2))
    and vim.startswith(argv[#opts + 3], 'if=')
    and argv[#opts + 4] == 'of=' .. path
    and argv[#opts + 5] == 'bs=1048576'
end

test(':SudaWrite stores the buffer into a Protected File', function()
  local path = h.protected_file(h.tempdir(), 'hosts', 'old\n')
  local fake = h.fake_sudo({ state = 'cached', protected = { path } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'new one', 'new two' })

  ex('SudaWrite', path)

  h.eq('new one\nnew two\n', h.read_protected(path))
  h.eq('---------', vim.fn.getfperm(path))
  local calls = argvs(fake)
  h.eq(2, #calls)
  h.eq({ '-n', '-v' }, calls[1])
  h.ok(is_dd_write(calls[2], { '-n' }, path), vim.inspect(calls[2]))
end)

test(':SudaRead then :SudaWrite round-trips an edited Protected File', function()
  local path = h.protected_file(h.tempdir(), 'fstab', 'a\nb\n')
  local fake = h.fake_sudo({ state = 'cached', protected = { path } })

  sudaread(path)
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'B' })
  h.eq(true, vim.bo.modified)
  vim.fn.execute('write')

  h.eq('a\nB\n', h.read_protected(path))
  h.eq(false, vim.bo.modified)
  local calls = argvs(fake)
  h.eq(4, #calls)
  h.eq({ '-n', '--', 'cat', path }, calls[2])
  h.ok(is_dd_write(calls[4], { '-n' }, path), vim.inspect(calls[4]))
end)

test('cached credential: no prompt, and the command runs once', function()
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({ state = 'cached', protected = { path } })

  -- No answer is queued: a prompt would read EOF and quit Neovim.
  local out = sudaread(path)

  h.eq({ 'x' }, lines())
  h.ok(not out:find('suda%]'), 'no error: ' .. out)
  h.eq({ { '-n', '-v' }, { '-n', '--', 'cat', path } }, argvs(fake))
end)

test('no cached credential: one prompt, then the command runs once with the password on stdin', function()
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({ state = 'uncached', password = 'secret', protected = { path } })

  h.answer_prompt('secret')
  sudaread(path)

  h.eq({ 'x' }, lines())
  h.eq({ { '-n', '-v' }, { '-p', '', '-S', '--', 'cat', path } }, argvs(fake))
  h.eq('secret\n', fake.calls()[2].stdin)
end)

test(':SudaWrite sends the password on stdin when no credential is cached', function()
  local path = h.protected_file(h.tempdir(), 'hosts', 'old\n')
  local fake = h.fake_sudo({ state = 'uncached', password = 'secret', protected = { path } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'new' })

  h.answer_prompt('secret')
  ex('SudaWrite', path)

  h.eq('new\n', h.read_protected(path))
  local calls = fake.calls()
  h.eq(2, #calls)
  h.ok(is_dd_write(calls[2].argv, { '-p', '', '-S' }, path), vim.inspect(calls[2].argv))
  h.eq('secret\n', calls[2].stdin)
end)

test('command failure with a cached credential: runs once and reports its stderr', function()
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({
    state = 'cached',
    protected = { path },
    fail = { cmd = 'cat', stderr = 'cat: read error\n' },
  })

  local out = sudaread(path)

  reports(out, 'cat: read error')
  h.eq({ { '-n', '-v' }, { '-n', '--', 'cat', path } }, argvs(fake))
end)

test('a failing read reports stderr only, never stdout', function()
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  h.fake_sudo({
    state = 'cached',
    protected = { path },
    fail = { cmd = 'cat', stdout = 'partial output\n', stderr = 'cat: read error\n' },
  })

  local out = sudaread(path)

  reports(out, 'cat: read error')
  h.ok(not out:find('partial output', 1, true), 'stdout is not reported: ' .. out)
end)

test('command failure after the prompt: runs once and reports its stderr', function()
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({
    state = 'uncached',
    protected = { path },
    fail = { cmd = 'cat', stderr = 'cat: read error\n' },
  })

  h.answer_prompt('secret')
  local out = sudaread(path)

  reports(out, 'cat: read error')
  h.eq({ { '-n', '-v' }, { '-p', '', '-S', '--', 'cat', path } }, argvs(fake))
end)

test('an empty prompt answer cancels without running the command', function()
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({ state = 'uncached', protected = { path } })

  h.answer_prompt('')
  local out = sudaread(path)

  reports(out, 'cancelled')
  h.eq({ '' }, lines())
  h.eq({ { '-n', '-v' } }, argvs(fake), 'only the credential check ran')
end)

test('<Esc> at the prompt cancels too', function()
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({ state = 'uncached', protected = { path } })

  vim.api.nvim_input('<Esc>')
  local out = sudaread(path)

  reports(out, 'cancelled')
  h.eq({ { '-n', '-v' } }, argvs(fake))
end)

test("a wrong password reports sudo's stderr and does not prompt again", function()
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({ state = 'wrong-password', protected = { path } })

  -- Only one answer is queued: a second prompt would read EOF and quit Neovim.
  h.answer_prompt('nope')
  local out = sudaread(path)

  reports(out, 'sudo: 1 incorrect password attempt')
  h.eq({ { '-n', '-v' }, { '-p', '', '-S', '--', 'cat', path } }, argvs(fake))
end)

test('g:suda#noninteractive runs only the non-interactive command', function()
  vim.g['suda#noninteractive'] = 1
  do
    local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')

    local fake = h.fake_sudo({ state = 'cached', protected = { path } })
    sudaread(path)
    h.eq({ 'x' }, lines())
    h.eq({ { '-n', '--', 'cat', path } }, argvs(fake))

    vim.cmd('silent! %bwipeout!')
    fake = h.fake_sudo({ state = 'uncached', protected = { path } })
    local out = sudaread(path)
    reports(out, 'sudo: a password is required')
    h.eq({ { '-n', '--', 'cat', path } }, argvs(fake), 'no validation, no prompt')
  end
end)

h.test('the system backend starts each sudo step in a new session', function()
  vim.g['suda#_backend'] = 'system'
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({ state = 'cached', protected = { path } })

  sudaread(path)

  local calls = fake.calls()
  h.eq(2, #calls)
  for _, call in ipairs(calls) do
    h.ok(call.sid ~= h.self_stat().sid, 'systemlist() detaches')
  end
  h.ok(calls[1].sid ~= calls[2].sid, 'every step gets its own session')
end)

h.run()
