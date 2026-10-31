-- Runs sudo steps for the Vimscript layer, which owns the step sequence and
-- builds every argv: in the Terminal Client when the delegation guard allows
-- it (ADR-0002), otherwise in the editor's server process, through the step
-- runner (suda.exec). Converts results for Vimscript.
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
-- runner and returns the pid of the process that answers, the one that would
-- start sudo; STEP loads the runner and runs one step.
local PROBE = [[
local source = ...
local loaded = (loadstring or load)(source, '=suda/exec.lua') ~= nil
return { loaded = loaded, pid = vim.uv.os_getpid() }
]]
local STEP = [[
local source, s = ...
local exec = assert((loadstring or load)(source, '=suda/exec.lua'))()
return exec.step(s.argv, s.input, s.stdout_path, s.opts)
]]

-- The delegation guard. Returns the channel of a Terminal Client that may run
-- sudo steps, or nil, plus the reason in both cases.
--
-- A UI qualifies only if it reports a terminal on both stdin and stdout,
-- answers an RPC that loads the step runner, and the answering process is
-- the server's parent (the same host, and the process that started this
-- server). The pid comes from the probe, not from the UI's client info,
-- which older Terminal Clients do not fill in.
-- A remote UI must never run sudo on another host.
local function terminal_client()
  local uis = vim.api.nvim_list_uis()
  if #uis == 0 then
    return nil, 'no UI is attached'
  end
  -- Terminal Clients before Neovim 0.12 never answer the server's requests,
  -- and vim.rpcrequest() has no timeout: the probe would hang the editor.
  -- The server's version is the client's: it is the server's parent.
  if vim.fn.has('nvim-0.12') == 0 then
    return nil, 'Neovim 0.12 is needed to run sudo from the Terminal Client'
  end
  local ppid = vim.uv.os_getppid()
  local reasons = {}
  for _, ui in ipairs(uis) do
    local why
    if not (ui.stdin_tty and ui.stdout_tty) then
      why = 'has no terminal on stdin and stdout'
    else
      local ok, res = pcall(vim.rpcrequest, ui.chan, 'nvim_exec_lua', PROBE, { runner_source() })
      if not ok or type(res) ~= 'table' or res.loaded ~= true then
        why = 'failed the RPC call: ' .. (ok and vim.inspect(res) or tostring(res))
      elseif res.pid ~= ppid then
        why = string.format("is process %s, not the server's parent %d", tostring(res.pid), ppid)
      else
        return ui.chan, string.format('UI on channel %d, process %d', ui.chan, ppid)
      end
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

-- Where the sudo steps of one operation run: the channel of a Terminal
-- Client, or 0 for the server. The chosen path and the reason are logged.
-- {why_not} is empty if the steps may leave the server, or the reason they
-- must not (a tool that is not sudo-compatible gets no -n or -S and could
-- prompt on the Terminal Client's terminal while the editor waits).
function M.choose(why_not)
  local chan, why
  if why_not == '' then
    chan, why = terminal_client()
  else
    why = why_not
  end
  if chan then
    log('running sudo from the Terminal Client (' .. why .. ')')
    return chan
  end
  log('running sudo from the server: ' .. why)
  return 0
end

-- Run one step, {argv} with {input} on stdin, where M.choose() said: on
-- Terminal Client channel {chan}, or in the server if {chan} is 0. With a
-- non-empty {stdout_path}, stdout goes byte for byte into that file.
-- Returns { code, stdout, stderr } with output as lists of lines.
function M.step(chan, argv, input, stdout_path)
  log(table.concat(argv, ' '))
  if stdout_path == '' then
    stdout_path = nil
  end
  local step = chan ~= 0 and client_step(chan) or exec.step
  local r = step(argv, input, stdout_path)
  return { code = r.code, stdout = lines(r.stdout), stderr = lines(r.stderr) }
end

return M
