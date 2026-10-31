-- :SudaRead loads a Protected File byte for byte and :SudaWrite writes it
-- back unchanged, on both backends.
local h = dofile(vim.fs.dirname(arg[0]) .. '/helpers.lua')
h.load_plugin()

-- What :edit makes of a file: the buffer and the options detected on read.
local function buffer_state()
  return {
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
    fileformat = vim.bo.fileformat,
    fileencoding = vim.bo.fileencoding,
    eol = vim.bo.eol,
    bomb = vim.bo.bomb,
  }
end

-- :edit a readable copy of {content}, run {fn}, and return its result.
local function with_plain_copy(content, fn)
  local path = h.tempdir() .. '/plain'
  h.write_bytes(path, content)
  vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
  local result = fn(path)
  vim.cmd('silent! %bwipeout!')
  return result
end

-- The buffer state :edit gives a readable copy of {content}.
local function edit_plain(content)
  return with_plain_copy(content, buffer_state)
end

local samples = {
  { name = 'a file ending with a newline', content = 'one\ntwo\n', expect = { eol = true } },
  { name = 'a file without a final newline', content = 'one\ntwo', expect = { eol = false } },
  { name = 'a file with NUL bytes', content = 'a\0b\n\0\nc\0\n' },
  { name = 'a CRLF file', content = 'one\r\ntwo\r\n', expect = { fileformat = 'dos' } },
  { name = 'a CRLF file without a final newline', content = 'one\r\ntwo', expect = { fileformat = 'dos', eol = false } },
  { name = 'a Latin-1 file', content = 'caf\233\n', expect = { fileencoding = 'latin1' } },
  { name = 'a UTF-8 file with a BOM', content = '\239\187\191hello\n', expect = { bomb = true } },
  { name = 'an empty file', content = '' },
}

for _, sample in ipairs(samples) do
  h.test_each_backend(sample.name .. ' reads like :edit and round-trips unchanged', function()
    vim.o.fileencodings = 'ucs-bom,utf-8,latin1'
    -- Keep a missing final newline on write, as for any file in Vim.
    vim.o.fixendofline = false
    local expected = edit_plain(sample.content)
    for k, v in pairs(sample.expect or {}) do
      h.eq(v, expected[k], ':edit detects ' .. k)
    end

    local path = h.protected_file(h.tempdir(), 'protected', sample.content)
    h.fake_sudo({ state = 'cached', protected = { path } })
    vim.fn.execute('SudaRead ' .. vim.fn.fnameescape(path))
    h.eq(expected, buffer_state(), ':SudaRead matches :edit')

    vim.fn.execute('SudaWrite')
    h.eq(sample.content, h.read_protected(path), 'bytes unchanged after :SudaWrite')
  end)
end

-- What a plain :edit + :write does to {content} with default options.
local function edit_write_plain(content)
  return with_plain_copy(content, function(path)
    vim.cmd('silent write!')
    return h.read_bytes(path)
  end)
end

h.test_each_backend(':SudaWrite of a file without a final newline writes what :write would', function()
  vim.o.fixendofline = true
  local content = 'one\ntwo'
  local expected = edit_write_plain(content)
  h.eq('one\ntwo\n', expected, "'fixendofline' adds the newline")

  local path = h.protected_file(h.tempdir(), 'protected', content)
  h.fake_sudo({ state = 'cached', protected = { path } })
  vim.fn.execute('SudaRead ' .. vim.fn.fnameescape(path))
  vim.fn.execute('SudaWrite')
  h.eq(expected, h.read_protected(path))
end)

h.run()
