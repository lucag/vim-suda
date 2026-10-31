-- :SudaRead and :SudaWrite on a Protected File, through the fake `sudo`.
-- These characterise today's behaviour.
local h = dofile(vim.fs.dirname(arg[0]) .. '/helpers.lua')
h.load_plugin()

local function sudaread(path)
  vim.cmd('silent SudaRead ' .. vim.fn.fnameescape(path))
end

local function argvs(fake)
  return vim.tbl_map(function(c)
    return c.argv
  end, fake.calls())
end

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

h.test(':SudaRead loads a Protected File into a suda:// buffer', function()
  local path = h.protected_file(h.tempdir(), 'hosts', 'line one\nline two\n')
  local fake = h.fake_sudo({ state = 'cached', protected = { path } })

  sudaread(path)

  h.eq('suda://' .. path, vim.api.nvim_buf_get_name(0))
  h.eq({ 'line one', 'line two' }, lines())
  h.eq(false, vim.bo.modified)
  h.eq('acwrite', vim.bo.buftype)
  local calls = fake.calls()
  h.eq(1, #calls)
  h.eq({ '-p', '', '-n', '--', 'cat', path }, calls[1].argv)
  h.eq('', calls[1].stdin)
end)

h.test(':SudaWrite stores the buffer into a Protected File', function()
  local path = h.protected_file(h.tempdir(), 'hosts', 'old\n')
  local fake = h.fake_sudo({ state = 'cached', protected = { path } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'new one', 'new two' })

  vim.cmd('silent SudaWrite ' .. vim.fn.fnameescape(path))

  h.eq('new one\nnew two\n', h.read_protected(path))
  h.eq('---------', vim.fn.getfperm(path))
  local calls = fake.calls()
  h.eq(1, #calls)
  local argv = calls[1].argv
  h.eq({ '-p', '', '-n', '--', 'dd' }, vim.list_slice(argv, 1, 5))
  h.eq({ 'of=' .. path, 'bs=1048576' }, vim.list_slice(argv, 7, 8))
  h.ok(vim.startswith(argv[6], 'if='), 'dd reads from a temporary file')
  h.eq('', calls[1].stdin)
end)

h.test(':SudaRead then :SudaWrite round-trips an edited Protected File', function()
  local path = h.protected_file(h.tempdir(), 'fstab', 'a\nb\n')
  local fake = h.fake_sudo({ state = 'cached', protected = { path } })

  sudaread(path)
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'B' })
  h.eq(true, vim.bo.modified)
  vim.cmd('silent write')

  h.eq('a\nB\n', h.read_protected(path))
  h.eq(false, vim.bo.modified)
  local calls = argvs(fake)
  h.eq(2, #calls)
  h.eq({ '-p', '', '-n', '--', 'cat', path }, calls[1])
  h.eq('dd', calls[2][5])
  h.eq('of=' .. path, calls[2][7])
end)

h.test(':SudaRead prompts for a password when no credential is cached', function()
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({ state = 'uncached', password = 'secret', protected = { path } })

  h.answer_prompt('secret')
  sudaread(path)

  h.eq({ 'x' }, lines())
  h.eq({
    { '-p', '', '-n', '--', 'cat', path },
    { '-n', '--', 'true' },
    { '-p', '', '-S', '--', 'cat', path },
  }, argvs(fake))
  h.eq('secret\n', fake.calls()[3].stdin)
end)

h.run()
