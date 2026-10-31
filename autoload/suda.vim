" Returns {args} prefixed with g:suda#executable as a string that is safe to
" pass to `system` on both vim and neovim
function! s:command_line(args) abort
  return join([g:suda#executable] + map(copy(a:args), { k, v -> shellescape(v) }), ' ')
endfunction

" {opts} is a list of command line options
" {cmd} is the argv list for the process to run
" {opts} should be *sudo-specific*, while {cmd} is passed to any suda#executable
" Note: {cmd} can not have any sudo flags. Put these into {opts}, as '--' is passed before {cmd}
" Similarly, {opts} should *not* contain '--'
function! s:get_command(opts, cmd) abort
  if s:is_sudo()
    return s:command_line(a:opts + ['--'] + a:cmd)
  endif
  " TODO:
  " Should we pass '--' before cmd when using a custom suda#executable?
  " Should suda#executable be split? Should we allow suda#executable to be a list instead?
  " This behavior is entirely undocumented
  return s:command_line(a:cmd)
endfunction

function! s:is_sudo() abort
  return g:suda#executable ==# 'sudo'
endfunction

function! s:run(cmd, input) abort
  if &verbose
    echomsg '[suda]' a:cmd
  endif
  return systemlist(a:cmd, a:input)
endfunction

" Ask for the sudo password. Throws 'cancelled' on an empty answer.
function! s:ask_password() abort
  try
    call inputsave()
    redraw | let password = inputsecret(g:suda#prompt)
  finally
    call inputrestore()
  endtry
  if empty(password)
    throw 'cancelled'
  endif
  return password
endfunction

" {cmd} is a argv list for the process
" {input} (a:1) is a string to pass as stdin to the command
" Returns a list of the command's output, split by NLs, with NULs replaced with NLs.
"
" The command runs exactly once. With sudo, a cached credential is checked
" first (`sudo -n -v`); the password is asked for only when there is none.
" With g:suda#noninteractive, on Windows, or with a non-sudo executable, the
" command runs without validation or a password prompt.
function! suda#systemlist(cmd, ...) abort
  let input = a:0 ? a:1 : ''
  if has('win32') || !s:is_sudo()
    return s:run(s:get_command([], a:cmd), input)
  elseif g:suda#noninteractive
    return s:run(s:get_command(['-n'], a:cmd), input)
  endif
  call s:run(s:command_line(['-n', '-v']), '')
  if v:shell_error == 0
    return s:run(s:get_command(['-n'], a:cmd), input)
  endif
  let password = s:ask_password()
  return s:run(s:get_command(['-p', '', '-S'], a:cmd), password . "\n" . input)
endfunction
" {cmd} is a argv list for the process
" {input} (a:1) is a string to pass as stdin to the command
" Returns the command's output as a string with NULs replaced with SOH (\u0001)
function! suda#system(cmd, ...) abort
  let output = call("suda#systemlist", [a:cmd] + a:000)
  " Emulate system()'s handling of output - replace NULs (represented by NL), join by NLs
  return join( map(l:output, { k, v -> substitute(v:val, '\n', '', 'g') }), '\n')
endfunction



function! suda#read(expr, ...) abort range
  let path = s:strip_prefix(expand(a:expr))
  let path = fnamemodify(path, ':p')
  let options = extend({
        \ 'cmdarg': v:cmdarg,
        \ 'range': '',
        \}, a:0 ? a:1 : {}
        \)

  if filereadable(path)
    " TODO: (aarondill) can we use readfile() here?
    return substitute(execute(printf(
          \ '%sread %s %s',
          \ options.range,
          \ options.cmdarg,
          \ fnameescape(path),
          \)), '^\r\?\n', '', '')
  endif

  let tempfile = tempname()
  try
    " NOTE: use systemlist to avoid changing newlines. Get the results of the
    " command (as a list) to avoid having to spawn a shell to do a redirection
    let resultlist = suda#systemlist(['cat', fnamemodify(path, ':p')])
    if v:shell_error
      throw join(resultlist, "\n")
    else
      " write with 'b' to ensure contents are the same
      call writefile(resultlist, tempfile, 'b')
      let echo_message = execute(printf(
            \ '%sread %s %s',
            \ options.range,
            \ options.cmdarg,
            \ fnameescape(tempfile),
            \))
      " Rewrite message with a correct file name
      let echo_message = substitute(
            \ echo_message,
            \ s:escape_patterns(tempfile),
            \ fnamemodify(path, ':~'),
            \ 'g',
            \)
      return substitute(echo_message, '^\r\?\n', '', '')
    endif
  finally
    silent call delete(tempfile)
  endtry
endfunction

function! suda#write(expr, ...) abort range
  let path = s:strip_prefix(expand(a:expr))
  let path = fnamemodify(path, ':p')
  let options = extend({
        \ 'cmdarg': v:cmdarg,
        \ 'cmdbang': v:cmdbang,
        \ 'range': '',
        \}, a:0 ? a:1 : {}
        \)
  let tempfile = tempname()
  try
    let path_exists = !empty(getftype(path))
    " TODO: (aarondill) can we use writefile() here?
    let echo_message = execute(printf(
          \ '%swrite%s %s %s',
          \ options.range,
          \ options.cmdbang ? '!' : '',
          \ options.cmdarg,
          \ fnameescape(tempfile),
          \))
    if has('win32')
      " In MS Windows, tee.exe has been placed at $VIMRUNTIME and $VIMRUNTIME
      " is added to $PATH in Vim process so `executable('tee')` returns 1.
      " However, sudo.exe executes a command in a new environment.  The
      " directory $VIMRUNTIME is not added here, so `tee` is not found.
      " Using a full path for tee command to avoid this problem.
      let tee_cmd = exepath('tee')
      let result = suda#system(
            \ [tee_cmd, path],
            \ join(readfile(tempfile, 'b'), "\n") )
    else
      " `bs=1048576` is equivalent to `bs=1M` for GNU dd or `bs=1m` for BSD dd
      " Both `bs=1M` and `bs=1m` are non-POSIX
      let result = suda#system(['dd', 'if='.tempfile, 'of='.path, 'bs=1048576'])
    endif
    if v:shell_error
      throw result
    endif
    " Rewrite message with a correct file name
    let echo_message = substitute(
          \ echo_message,
          \ s:escape_patterns(tempfile),
          \ fnamemodify(path, ':~'),
          \ 'g',
          \)
    if path_exists
      let echo_message = substitute(echo_message, '\[New\] ', '', 'g')
    endif
    return substitute(echo_message, '^\r\?\n', '', '')
  finally
    silent call delete(tempfile)
  endtry
  " Warn that this file has changed
  checktime
endfunction

function! suda#BufReadCmd() abort
  doautocmd <nomodeline> BufReadPre
  let ul = &undolevels
  set undolevels=-1
  try
    setlocal noswapfile noundofile
    let echo_message = suda#read('<afile>', {
          \ 'range': '1',
          \})
    silent lockmarks 0delete _
    setlocal buftype=acwrite
    setlocal nomodified
    filetype detect
    redraw | echo echo_message
  catch
    call s:echomsg_exception()
  finally
    let &undolevels = ul
    doautocmd <nomodeline> BufReadPost
  endtry
endfunction

function! suda#FileReadCmd() abort
  doautocmd <nomodeline> FileReadPre
  try
    " XXX
    " A '[ mark indicates the {range} of the command.
    " However, the mark becomes 1 even user execute ':0read'.
    " So check the last command to find if the {range} was 0 or not.
    let range = histget('cmd', -1) =~# '^0r\%[ead]\>' ? '0' : '''['
    redraw | echo suda#read('<afile>', {
          \ 'range': range,
          \})
  catch
    call s:echomsg_exception()
  finally
    doautocmd <nomodeline> FileReadPost
  endtry
endfunction

function! suda#BufWriteCmd() abort
  doautocmd <nomodeline> BufWritePre
  try
    let echo_message = suda#write('<afile>', {
          \ 'range': '''[,'']',
          \})
    let lhs = expand('%:p')
    let rhs = expand('<afile>')
    if lhs ==# rhs || substitute(rhs, '^suda://', '', '') ==# lhs
      setlocal nomodified
    endif
    redraw | echo echo_message
  catch
    call s:echomsg_exception()
  finally
    doautocmd <nomodeline> BufWritePost
  endtry
endfunction

function! suda#FileWriteCmd() abort
  doautocmd <nomodeline> FileWritePre
  try
    redraw | echo suda#write('<afile>', {
          \ 'range': '''[,'']',
          \})
  catch
    call s:echomsg_exception()
  finally
    doautocmd <nomodeline> FileWritePost
  endtry
endfunction

function! suda#BufEnter() abort
  if exists('b:suda_smart_edit_checked')
    return
  endif
  let b:suda_smart_edit_checked = 1
  let bufname = expand('<afile>')
  if !empty(&buftype)
        \ || empty(bufname)
        \ || match(bufname, '^[a-z]\+://*') isnot# -1
        \ || isdirectory(bufname)
    " Non file buffer
    return
  elseif filereadable(bufname) && filewritable(bufname)
    " File is readable and writeable
    return
  elseif empty(getftype(bufname))
    " if file doesn't exist, we search for a all directories up it's path to
    " see if each one of them is writable, if not, we `return`
    let parent = fnamemodify(bufname, ':p')
    while parent !=# fnamemodify(parent, ':h')
      let parent = fnamemodify(parent, ':h')
      if filewritable(parent) is# 2
        return
      elseif !filereadable(parent) && isdirectory(parent)
        break
      endif
    endwhile
  endif
  let bufnr = str2nr(expand('<abuf>'))
  execute printf(
        \ 'keepalt keepjumps edit suda://%s',
        \ fnameescape(fnamemodify(bufname, ':p')),
        \)
  execute printf('silent! %dbwipeout', bufnr)
endfunction

function! s:escape_patterns(expr) abort
  return escape(a:expr, '^$~.*[]\')
endfunction

function! s:strip_prefix(expr) abort
  return substitute(a:expr, '\v^(suda://)+', '', '')
endfunction

function! s:echomsg_exception() abort
  redraw
  echohl ErrorMsg
  for line in split(v:exception, '\n')
    echomsg printf('[suda] %s', line)
  endfor
  echohl None
endfunction

" Pseudo autocmd to suppress 'No such autocmd' message
augroup suda_internal
  autocmd!
  autocmd BufReadPre,BufReadPost     suda://* :
  autocmd FileReadPre,FileReadPost   suda://* :
  autocmd BufWritePre,BufWritePost   suda://* :
  autocmd FileWritePre,FileWritePost suda://* :
augroup END

" Configure
" Use suda#noninteractive if defined, else suda#nopass for backwards compatability, default to 0
let g:suda#noninteractive = get(g:, 'suda#noninteractive', get(g:, 'suda#nopass', 0))
let g:suda#prompt = get(g:, 'suda#prompt', 'Password: ')
let g:suda#executable = get(g:, 'suda#executable', 'sudo')
