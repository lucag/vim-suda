-- Editor side of test/manual/credential-scope.sh. Runs in the editor's
-- server once a UI attaches, then quits.
--
-- Environment:
--   SUDA_ROOT    vim-suda checkout to load
--   SUDA_EXE     g:suda#executable (sudo-rs, sudo.ws, ...)
--   SUDA_STEPS   comma-separated steps, each `prompt` (ask for the password
--                if needed) or `cached` (g:suda#noninteractive: succeeds only
--                with a cached credential)
--   SUDA_RESULT  file that receives `<step> <exit code>` per step, then
--                the `running sudo from ...` lines logged by `cached` steps
vim.opt.runtimepath:prepend(vim.env.SUDA_ROOT)
vim.cmd('runtime plugin/suda.vim')
vim.g['suda#executable'] = vim.env.SUDA_EXE

local function check()
  local out, logged = {}, {}
  for _, step in ipairs(vim.split(vim.env.SUDA_STEPS, ',')) do
    local ok = true
    if step == 'cached' then
      -- No prompt here, so the &verbose log can be captured; shown, it would
      -- stop at a hit-enter prompt.
      vim.g['suda#noninteractive'] = 1
      vim.o.verbose = 1
      local messages = vim.fn.execute("call suda#systemlist(['true'])")
      vim.o.verbose = 0
      for _, line in ipairs(vim.split(messages, '\n')) do
        if line:find('[suda] running sudo', 1, true) then
          table.insert(logged, line)
        end
      end
    else
      vim.g['suda#noninteractive'] = 0
      ok = pcall(vim.fn['suda#systemlist'], { 'true' })
    end
    table.insert(out, string.format('%s %d', step, ok and vim.v.shell_error or -1))
  end
  vim.list_extend(out, logged)
  vim.fn.writefile(out, vim.env.SUDA_RESULT)
  vim.cmd('qall!')
end

vim.api.nvim_create_autocmd('UIEnter', {
  once = true,
  callback = function()
    vim.defer_fn(check, 200)
  end,
})
