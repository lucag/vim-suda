-- g:suda#executable as a String (one program) or a List (argv prefix), with
-- sudo flags only for sudo-compatible names. On both backends.
local h = dofile(vim.fs.dirname(arg[0]) .. '/helpers.lua')
h.load_plugin()

local test = h.test_each_backend

local function argvs(fake)
  return vim.tbl_map(function(c)
    return c.argv
  end, fake.calls())
end

-- :SudaRead a fresh Protected File with g:suda#executable set to {exe}.
-- Returns the fake, the file's path and the messages.
local function read_with(exe, opts)
  opts = opts or {}
  local path = h.protected_file(h.tempdir(), 'shadow', 'x\n')
  local fake = h.fake_sudo({ state = opts.state or 'cached', protected = { path } })
  vim.g['suda#executable'] = exe
  local previous = vim.g['suda#executable']
  local ok, out = pcall(vim.fn.execute, 'SudaRead ' .. vim.fn.fnameescape(path))
  vim.g['suda#executable'] = previous
  assert(ok, out)
  return fake, path, out
end

local function sudo_sequence(path, prefix)
  prefix = prefix or {}
  return {
    vim.list_extend(vim.deepcopy(prefix), { '-n', '-v' }),
    vim.list_extend(vim.deepcopy(prefix), { '-n', '--', 'cat', path }),
  }
end

for _, name in ipairs({ 'sudo', 'sudo-rs', 'sudo.ws' }) do
  test(string.format("'%s' gets the sudo step sequence", name), function()
    local fake, path = read_with(name)
    h.eq({ 'x' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    h.eq(sudo_sequence(path), argvs(fake))
  end)

  test(string.format("'%s' as a full path gets the sudo step sequence", name), function()
    local fake, path = read_with(h.bin .. '/' .. name)
    h.eq(sudo_sequence(path), argvs(fake))
  end)
end

test('a String with a space in its path is one program', function()
  local dir = h.tempdir() .. '/with space'
  vim.fn.mkdir(dir, 'p')
  vim.uv.fs_symlink(h.bin .. '/sudo', dir .. '/sudo')
  local fake, path = read_with(dir .. '/sudo')
  h.eq({ 'x' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  h.eq(sudo_sequence(path), argvs(fake))
end)

test('a List is an argv prefix passed before the sudo flags', function()
  local fake, path = read_with({ 'sudo', '-E' })
  h.eq({ 'x' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  h.eq(sudo_sequence(path, { '-E' }), argvs(fake))
end)

test('a List whose first element is a full sudo path is sudo-compatible', function()
  local fake, path = read_with({ h.bin .. '/sudo-rs', '-E' })
  h.eq(sudo_sequence(path, { '-E' }), argvs(fake))
end)

test('a non-sudo tool runs as executable plus command, with no flags', function()
  local fake, path = read_with('doas')
  h.eq({ 'x' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  h.eq({ { 'cat', path } }, argvs(fake))
end)

test('a non-sudo tool is never prompted for or sent a password', function()
  -- No answer is queued: a prompt would read EOF and quit Neovim.
  local fake, path, out = read_with({ 'doas', '-n' }, { state = 'uncached' })
  h.eq({ { '-n', 'cat', path } }, argvs(fake))
  h.eq('', fake.calls()[1].stdin)
  h.ok(out:find('[suda] sudo: a password is required', 1, true), out)
end)

test("a name that only contains 'sudo' is not sudo-compatible", function()
  local dir = h.tempdir()
  vim.uv.fs_symlink(h.bin .. '/sudo', dir .. '/mysudo')
  local fake, path = read_with(dir .. '/mysudo')
  h.eq({ { 'cat', path } }, argvs(fake))
end)

test('an empty List is an error, and nothing runs', function()
  local fake, _, out = read_with({})
  h.ok(out:find('[suda] g:suda#executable is empty', 1, true), out)
  h.eq({}, fake.calls())
end)

h.run()
