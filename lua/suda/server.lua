-- Runs vim-suda's step runner (suda.exec) in the editor's server process and
-- converts its result for the Vimscript layer.
local exec = require('suda.exec')

local M = {}

-- Split output bytes into lines like systemlist(): NULs become NLs and a
-- final newline does not produce an empty last line.
local function lines(bytes)
  if bytes == '' then
    return {}
  end
  local out = vim.split(bytes, '\n', { plain = true })
  if out[#out] == '' then
    table.remove(out)
  end
  for i, line in ipairs(out) do
    out[i] = line:gsub('%z', '\n')
  end
  return out
end

local function logged_step(argv, input, stdout_path)
  if vim.o.verbose > 0 then
    vim.api.nvim_echo({ { '[suda] ' .. table.concat(argv, ' ') } }, true, {})
  end
  return exec.step(argv, input, stdout_path)
end

-- Run one privileged command (see suda.exec.sequence for {spec}).
-- Returns { code, stdout, stderr } with output as lists of lines, or
-- { cancelled = true }.
function M.run(spec)
  local r = exec.sequence(spec, logged_step, vim.fn['suda#_read_password'])
  if r.cancelled then
    return { cancelled = true }
  end
  return { code = r.code, stdout = lines(r.stdout), stderr = lines(r.stderr) }
end

return M
