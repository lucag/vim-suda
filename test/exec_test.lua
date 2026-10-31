-- lua/suda/exec.lua, the step runner, is sent as source text to the Terminal
-- Client (ADR-0002), so it must run with no `require` and keep file contents
-- out of its results.
local h = dofile(vim.fs.dirname(arg[0]) .. '/helpers.lua')

local path = h.root .. '/lua/suda/exec.lua'

-- Load the step runner the way the Terminal Client will: from source, with
-- no access to `require`.
local function load_isolated()
  local chunk = assert(loadstring(h.read_bytes(path), '=exec.lua'))
  local env = setmetatable({
    require = function(name)
      error('exec.lua must not require ' .. tostring(name))
    end,
  }, { __index = _G })
  setfenv(chunk, env)
  return chunk()
end

h.test('has no require in its source', function()
  local source = h.read_bytes(path)
  h.eq(nil, source:match('require%s*[%(\'"]'), 'a require call in exec.lua')
end)

h.test('runs a step when loaded without require', function()
  local exec = load_isolated()
  h.fake_sudo({ state = 'cached' })
  local r = exec.step({ 'sudo', '-n', '--', 'echo', 'hi' }, '')
  h.eq({ 0, 'hi\n' }, { r.code, r.stdout })
end)

h.test('with a stdout file, never returns stdout, even on failure', function()
  local exec = load_isolated()
  h.fake_sudo({ state = 'cached', fail = { cmd = 'cat', stdout = 'secret contents\n', stderr = 'cat: boom\n' } })
  local out = h.tempdir() .. '/out'

  local failed = exec.step({ 'sudo', '-n', '--', 'cat', '/etc/hostname' }, '', out)
  h.eq({ 1, '', 'cat: boom\n' }, { failed.code, failed.stdout, failed.stderr })

  h.fake_sudo({ state = 'cached' })
  local ok = exec.step({ 'sudo', '-n', '--', 'printf', 'file contents' }, '', out)
  h.eq({ 0, '' }, { ok.code, ok.stdout })
  h.eq('file contents', h.read_bytes(out))
end)

h.run()
