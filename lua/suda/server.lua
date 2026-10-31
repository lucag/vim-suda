-- Runs vim-suda's step runner (suda.exec) for the Vimscript layer: in the
-- Terminal Client when the delegation guard allows it (ADR-0002), otherwise
-- in the editor's server process. Converts the result for Vimscript.
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

local function log(msg)
  if vim.o.verbose > 0 then
    vim.api.nvim_echo({ { '[suda] ' .. msg } }, true, {})
  end
end

-- The step runner's source text, sent to the Terminal Client, which does not
-- load vim-suda's runtimepath.
local source
local function runner_source()
  if not source then
    local path = debug.getinfo(exec.step, 'S').source:sub(2)
    local f = assert(io.open(path, 'rb'))
    source = f:read('*a')
    f:close()
  end
  return source
end

-- Lua run by the Terminal Client through nvim_exec_lua. PROBE loads the step
-- runner; STEP loads it and runs one step.
local PROBE = [[
local source = ...
return (loadstring or load)(source, '=suda/exec.lua') ~= nil
]]
local STEP = [[
local source, s = ...
local exec = assert((loadstring or load)(source, '=suda/exec.lua'))()
return exec.step(s.argv, s.input, s.stdout_path, s.opts)
]]

-- The delegation guard. Returns the channel of a Terminal Client that may run
-- sudo steps, or nil, plus the reason in both cases.
--
-- A UI qualifies only if it reports a terminal on both stdin and stdout, its
-- process is the server's parent (the same host, and the process that
-- started this server), and it answers an RPC that loads the step runner.
-- A remote UI must never run sudo on another host.
local function terminal_client()
  local uis = vim.api.nvim_list_uis()
  if #uis == 0 then
    return nil, 'no UI is attached'
  end
  local ppid = vim.uv.os_getppid()
  local reasons = {}
  for _, ui in ipairs(uis) do
    local why
    local pid = vim.tbl_get(vim.api.nvim_get_chan_info(ui.chan), 'client', 'attributes', 'pid')
    if not (ui.stdin_tty and ui.stdout_tty) then
      why = 'has no terminal on stdin and stdout'
    elseif tonumber(pid) ~= ppid then
      why = string.format("is process %s, not the server's parent %d", tostring(pid or 'unknown'), ppid)
    else
      local ok, res = pcall(vim.rpcrequest, ui.chan, 'nvim_exec_lua', PROBE, { runner_source() })
      if ok and res == true then
        return ui.chan, string.format('UI on channel %d, process %d', ui.chan, ppid)
      end
      why = 'failed the RPC call: ' .. tostring(res)
    end
    table.insert(reasons, string.format('UI on channel %d %s', ui.chan, why))
  end
  return nil, table.concat(reasons, '; ')
end

-- A step that runs in the Terminal Client on {chan}. The step sees the
-- server's environment and working directory, as a step in the server would.
-- Only the argv, the input (the password, once, if needed) and paths cross
-- the channel; the client writes a read's output straight into the server's
-- tempfile and returns { code, stdout, stderr } with stdout empty.
local function client_step(chan)
  return function(argv, input, stdout_path)
    local spec = {
      argv = argv,
      input = input,
      stdout_path = stdout_path,
      opts = { env = vim.fn.environ(), clear_env = true, cwd = vim.fn.getcwd() },
    }
    local ok, res = pcall(vim.rpcrequest, chan, 'nvim_exec_lua', STEP, { runner_source(), spec })
    if not ok then
      -- Never retried in the server: the step may already have run.
      return { code = 1, stdout = '', stderr = 'the Terminal Client could not run sudo: ' .. tostring(res) }
    end
    return res
  end
end

-- The step function for an operation on {spec}, with the chosen path logged.
-- A tool that is not sudo-compatible gets no -n or -S and could prompt on
-- the Terminal Client's terminal while the editor waits, so it never leaves
-- the server.
local function choose_step(spec)
  local chan, why
  if spec.sudo then
    chan, why = terminal_client()
  else
    why = 'g:suda#executable is not sudo-compatible'
  end
  if chan then
    log('running sudo from the Terminal Client (' .. why .. ')')
    return client_step(chan)
  end
  log('running sudo from the server: ' .. why)
  return exec.step
end

-- Run one privileged command (see suda.exec.sequence for {spec}).
-- Returns { code, stdout, stderr } with output as lists of lines, or
-- { cancelled = true }.
function M.run(spec)
  local step = choose_step(spec)
  local function logged_step(argv, input, stdout_path)
    log(table.concat(argv, ' '))
    return step(argv, input, stdout_path)
  end
  local r = exec.sequence(spec, logged_step, vim.fn['suda#_read_password'])
  if r.cancelled then
    return { cancelled = true }
  end
  return { code = r.code, stdout = lines(r.stdout), stderr = lines(r.stderr) }
end

return M
