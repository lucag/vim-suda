-- vim-suda's step runner: runs one sudo step (one argv) without a shell and
-- without detaching from the editor. The step sequence lives in
-- s:run_privileged() in autoload/suda.vim.
--
-- This file must stay self-contained (no `require`): it is meant to be sent
-- as source text to the Terminal Client, which does not load vim-suda's
-- runtimepath (ADR-0002).

local M = {}

-- Run one step. Returns { code, stdout, stderr } with raw output bytes.
-- A process killed by a signal gets code 128 + signal, like a shell reports.
-- With {stdout_path}, stdout is written there byte for byte on success and
-- never returned, so file contents never leave the process that read them.
-- {opts} (optional) adds `env`, `clear_env` and `cwd` for vim.system().
function M.step(argv, input, stdout_path, opts)
  local system_opts = { stdin = input or '', text = false }
  for _, key in ipairs({ 'env', 'clear_env', 'cwd' }) do
    if opts and opts[key] ~= nil then
      system_opts[key] = opts[key]
    end
  end
  local ok, obj = pcall(vim.system, argv, system_opts)
  if not ok then
    return { code = 127, stdout = '', stderr = tostring(obj) }
  end
  local r = obj:wait()
  local code = (r.signal or 0) ~= 0 and 128 + r.signal or r.code
  local stdout = r.stdout or ''
  if stdout_path then
    if code == 0 then
      local err = M.write_file(stdout_path, stdout)
      if err then
        return { code = 1, stdout = '', stderr = err }
      end
    end
    stdout = ''
  end
  return { code = code, stdout = stdout, stderr = r.stderr or '' }
end

-- Write {data} to {path}. Returns an error message, or nil on success.
function M.write_file(path, data)
  local f, err = io.open(path, 'wb')
  if not f then
    return tostring(err)
  end
  local ok, write_err = f:write(data)
  local closed, close_err = f:close()
  if not ok or not closed then
    return tostring(write_err or close_err)
  end
end

return M
