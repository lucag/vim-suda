" vim-suda in Vim, through the fake sudo: the systemlist() path end to end.
execute 'source' fnameescape(expand('<sfile>:p:h') . '/helpers.vim')

let s:tests = {}

function! s:tests.read_loads_a_protected_file() abort
  let path = SudaTestProtectedFile(['one', 'two', ''])
  let fake = SudaTestFakeSudo({'state': 'cached', 'protected': [path]})
  silent execute 'SudaRead' fnameescape(path)
  call assert_equal('suda://' . path, bufname('%'))
  call assert_equal(['one', 'two'], getline(1, '$'))
  call assert_equal([['-n', '-v'], ['-n', '--', 'cat', path]], SudaTestCalls(fake))
endfunction

function! s:tests.write_stores_the_buffer() abort
  let path = SudaTestProtectedFile(['old', ''])
  call SudaTestFakeSudo({'state': 'cached', 'protected': [path]})
  call setline(1, ['new one', 'new two'])
  silent execute 'SudaWrite' fnameescape(path)
  call assert_equal(['new one', 'new two', ''], SudaTestReadProtected(path))
endfunction

function! s:tests.prompts_once_when_no_credential_is_cached() abort
  let path = SudaTestProtectedFile(['x', ''])
  let fake = SudaTestFakeSudo({'state': 'uncached', 'protected': [path]})
  call SudaTestAnswerPrompt('secret')
  silent execute 'SudaRead' fnameescape(path)
  call assert_equal(['x'], getline(1, '$'))
  call assert_equal([['-n', '-v'], ['-p', '', '-S', '--', 'cat', path]], SudaTestCalls(fake))
endfunction

function! s:tests.round_trips_nul_crlf_and_noeol_bytes() abort
  set nofixendofline
  " writefile() lists: a NL inside an item is a NUL byte; no final '' = noeol
  for content in [["a\nb", ''], ["one\r", "two\r", ''], ['one', 'two']]
    let path = SudaTestProtectedFile(content)
    call SudaTestFakeSudo({'state': 'cached', 'protected': [path]})
    silent execute 'SudaRead' fnameescape(path)
    silent SudaWrite
    call assert_equal(content, SudaTestReadProtected(path), string(content))
    silent! %bwipeout!
  endfor
endfunction

function! s:tests.systemlist_returns_stderr_and_sets_shell_error() abort
  call SudaTestFakeSudo({'state': 'cached'})
  call assert_equal(['out'], suda#systemlist(['sh', '-c', 'echo out']))
  call assert_equal(0, v:shell_error)
  call assert_equal(['err'], suda#systemlist(['sh', '-c', 'echo out; echo err >&2; exit 3']))
  call assert_equal(3, v:shell_error)
endfunction

function! s:tests.list_executable_is_an_argv_prefix() abort
  let fake = SudaTestFakeSudo({'state': 'cached'})
  let g:suda#executable = ['sudo', '-E']
  call suda#systemlist(['true'])
  call assert_equal([['-E', '-n', '-v'], ['-E', '-n', '--', 'true']], SudaTestCalls(fake))
endfunction

call SudaTestRun(s:tests)
