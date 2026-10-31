-- vim-suda's step runner: runs the sudo step sequence for one privileged
-- operation without a shell and without detaching from the editor.
--
-- This file must stay self-contained (no `require`): it is meant to be sent
-- as source text to the Terminal Client, which does not load vim-suda's
-- runtimepath (ADR-0002).

local M = {}

-- Run one step. Returns { code, stdout, stderr } with raw output bytes.
-- A process killed by a signal gets code 128 + signal, like a shell reports.
function M.step(argv, input)
  local ok, obj = pcall(vim.system, argv, { stdin = input or '', text = false })
  if not ok then
    return { code = 127, stdout = '', stderr = tostring(obj) }
  end
  local r = obj:wait()
  local code = (r.signal or 0) ~= 0 and 128 + r.signal or r.code
  return { code = code, stdout = r.stdout or '', stderr = r.stderr or '' }
end

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    for _, v in ipairs(list) do
      out[#out + 1] = v
    end
  end
  return out
end

-- Run the step sequence for one privileged command.
--
-- spec:
--   executable      argv prefix of the privilege tool, e.g. { 'sudo' }
--   sudo            true if the tool takes sudo flags
--   noninteractive  only run the command non-interactively
--   cmd             argv of the privileged command
--   input           stdin for the command (string)
-- step(argv, input)  runs one step, returning { code, stdout, stderr }
-- ask_password()     returns the password, or '' / nil to cancel
--
-- Returns the command's { code, stdout, stderr }, or { cancelled = true }.
-- The command runs at most once.
function M.sequence(spec, step, ask_password)
  local exe, cmd, input = spec.executable, spec.cmd, spec.input or ''
  if not spec.sudo then
    return step(concat(exe, cmd), input)
  end
  if spec.noninteractive then
    return step(concat(exe, { '-n', '--' }, cmd), input)
  end
  if step(concat(exe, { '-n', '-v' }), '').code == 0 then
    return step(concat(exe, { '-n', '--' }, cmd), input)
  end
  local password = ask_password()
  if password == nil or password == '' then
    return { cancelled = true }
  end
  return step(concat(exe, { '-p', '', '-S', '--' }, cmd), password .. '\n' .. input)
end

return M
