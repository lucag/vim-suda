-- suda#system() and suda#systemlist(): stdout on success, stderr lines on
-- failure, and v:shell_error set to the command's exit code, on both backends.
local h = dofile(vim.fs.dirname(arg[0]) .. '/helpers.lua')
h.load_plugin()

local test = h.test_each_backend

-- Leave v:shell_error at {code} so a test can tell it was really set.
local function preset_shell_error(code)
  vim.fn.system({ 'sh', '-c', 'exit ' .. code })
  assert(vim.v.shell_error == code)
end

local out_err_exit3 = { 'sh', '-c', 'echo out1; echo out2; echo err1 >&2; echo err2 >&2; exit 3' }

test('suda#systemlist() returns stdout lines on success and sets v:shell_error to 0', function()
  h.fake_sudo({ state = 'cached' })
  preset_shell_error(5)
  h.eq({ 'one', 'two' }, vim.fn['suda#systemlist']({ 'printf', 'one\ntwo\n' }))
  h.eq(0, vim.v.shell_error)
end)

test('suda#systemlist() passes {input} on stdin', function()
  h.fake_sudo({ state = 'cached' })
  h.eq({ 'a', 'b' }, vim.fn['suda#systemlist']({ 'cat' }, 'a\nb\n'))
end)

test('suda#systemlist() returns only stderr lines on failure and sets v:shell_error', function()
  h.fake_sudo({ state = 'cached' })
  h.eq({ 'err1', 'err2' }, vim.fn['suda#systemlist'](out_err_exit3))
  h.eq(3, vim.v.shell_error)
end)

test('suda#system() returns stdout joined by newlines on success', function()
  h.fake_sudo({ state = 'cached' })
  preset_shell_error(5)
  h.eq('one\ntwo', vim.fn['suda#system']({ 'printf', 'one\ntwo\n' }))
  h.eq(0, vim.v.shell_error)
end)

test('suda#system() returns stderr joined by newlines on failure and sets v:shell_error', function()
  h.fake_sudo({ state = 'cached' })
  h.eq('err1\nerr2', vim.fn['suda#system'](out_err_exit3))
  h.eq(3, vim.v.shell_error)
end)

test('a command killed by a signal fails with exit code 128 + signal', function()
  h.fake_sudo({ state = 'cached' })
  vim.fn['suda#systemlist']({ 'sh', '-c', 'kill -9 $$' })
  h.eq(137, vim.v.shell_error)
end)

test('a failed authentication returns sudo\'s stderr and its exit code', function()
  h.fake_sudo({ state = 'wrong-password' })
  h.answer_prompt('nope')
  h.eq({ 'sudo: 1 incorrect password attempt' }, vim.fn['suda#systemlist']({ 'true' }))
  h.eq(1, vim.v.shell_error)
end)

h.run()
