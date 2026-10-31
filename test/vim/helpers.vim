" Minimal test helpers for running vim-suda in Vim (the systemlist() path).
" Mirrors test/helpers.lua. A test file looks like:
"   execute 'source' fnameescape(expand('<sfile>:p:h') . '/helpers.vim')
"   let s:tests = {}
"   function! s:tests.something() abort
"     call assert_equal(1, 1)
"   endfunction
"   call SudaTestRun(s:tests)
" Results go to $SUDA_TEST_OUT, ending with "N passed, M failed".

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h:h')
let s:bin = s:root . '/test/bin'
let s:scratch = []

execute 'set runtimepath^=' . fnameescape(s:root)
runtime plugin/suda.vim

function! SudaTestTempdir() abort
  let dir = tempname()
  call mkdir(dir, 'p')
  call add(s:scratch, dir)
  return dir
endfunction

" Create a Protected File, emulated with mode 000 (tests never run as root).
function! SudaTestProtectedFile(content) abort
  let path = SudaTestTempdir() . '/protected'
  call writefile(a:content, path, 'b')
  call setfperm(path, '---------')
  return path
endfunction

" Read a Protected File's bytes as a writefile()-style list.
function! SudaTestReadProtected(path) abort
  call setfperm(a:path, 'rw-------')
  let content = readfile(a:path, 'b')
  call setfperm(a:path, '---------')
  return content
endfunction

" Configure the fake sudo (see test/helpers.lua fake_sudo() for {opts}).
function! SudaTestFakeSudo(opts) abort
  let dir = SudaTestTempdir() . '/fake-sudo'
  call mkdir(dir . '/calls', 'p')
  call writefile([get(a:opts, 'state', 'uncached')], dir . '/state')
  call writefile([get(a:opts, 'password', 'secret')], dir . '/password')
  call writefile(get(a:opts, 'protected', []), dir . '/protected')
  let $FAKE_SUDO_DIR = dir
  if $PATH !~# '^' . escape(s:bin, '.') . ':'
    let $PATH = s:bin . ':' . $PATH
  endif
  " Never let a test reach the real sudo.
  if exepath('sudo') !=# s:bin . '/sudo'
    throw 'sudo does not resolve to the fake: ' . exepath('sudo')
  endif
  return dir
endfunction

" The argv of every call the fake received, in order.
function! SudaTestCalls(dir) abort
  let calls = []
  let n = 1
  while isdirectory(a:dir . '/calls/' . n)
    let raw = readfile(a:dir . '/calls/' . n . '/argv', 'b')
    " NUL-terminated arguments: readfile() shows each NUL as a NL.
    call add(calls, split(join(raw, "\n"), "\n", 1)[: -2])
    let n += 1
  endwhile
  return calls
endfunction

" Queue {text} as the answer to the next prompt. inputsave() discards
" typeahead, so feed it from a timer that fires while the prompt waits.
function! SudaTestAnswerPrompt(text) abort
  call timer_start(50, {-> feedkeys(a:text . "\r", 't')})
endfunction

function! s:reset() abort
  silent! %bwipeout!
  let g:suda#noninteractive = 0
  let g:suda#executable = 'sudo'
  set fixendofline
  for dir in s:scratch
    call system('chmod -R u+rwX ' . shellescape(dir))
    call delete(dir, 'rf')
  endfor
  let s:scratch = []
endfunction

" Run every function in {tests} (in name order), write results to
" $SUDA_TEST_OUT and quit (non-zero on failure).
function! SudaTestRun(tests) abort
  let out = []
  let failed = 0
  let names = sort(keys(a:tests))
  for name in names
    let v:errors = []
    try
      call a:tests[name]()
    catch
      call add(v:errors, v:exception . ' @ ' . v:throwpoint)
    endtry
    if empty(v:errors)
      call add(out, '  ok   ' . name)
    else
      let failed += 1
      call add(out, '  FAIL ' . name)
      call extend(out, map(copy(v:errors), '"    " . v:val'))
    endif
    call s:reset()
  endfor
  call add(out, printf('  %d passed, %d failed', len(names) - failed, failed))
  call writefile(out, $SUDA_TEST_OUT)
  execute failed ? 'cquit' : 'qall!'
endfunction
