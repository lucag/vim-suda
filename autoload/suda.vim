" g:suda#executable as an argv prefix: a String is one program (never split
" on spaces), a List is a program plus extra arguments.
" Throws if it is empty, so nothing ever runs without the privilege tool.
function! s:argv_prefix() abort
  let prefix = type(g:suda#executable) == type([])
        \ ? copy(g:suda#executable)
        \ : [g:suda#executable]
  if empty(prefix) || empty(prefix[0])
    throw 'g:suda#executable is empty'
  endif
  return prefix
endfunction

" True if g:suda#executable takes sudo flags: the basename of its program is
" sudo, sudo-rs or sudo.ws.
function! s:is_sudo() abort
  let program = s:argv_prefix()[0]
  return fnamemodify(program, ':t') =~# '^sudo\%(-rs\|\.ws\)\?$'
endfunction

" Returns {args} prefixed with g:suda#executable as a string that is safe to
" pass to `system` on both vim and neovim
function! s:command_line(args) abort
  return join(map(s:argv_prefix() + a:args, { k, v -> shellescape(v) }), ' ')
endfunction

" {opts} is a list of sudo options, {cmd} the argv list of the command.
" Sudo-compatible executables get {opts} and '--' before {cmd}; any other
" executable gets only {cmd}.
function! s:get_command(opts, cmd) abort
  return s:command_line(s:is_sudo() ? a:opts + ['--'] + a:cmd : a:cmd)
endfunction

" Runs one shell command line of the system backend.
" Returns {'code', 'stdout', 'stderr'} with output as lists of lines, NULs
" replaced with NLs. With {stdout_path} (a:1), stdout is redirected into that
" file byte for byte instead. stderr is captured separately with a
" POSIX-style `2>` redirect; on Windows and with csh-like shells it stays
" mixed into stdout, which is then also returned as stderr.
function! s:run(cmd, input, ...) abort
  let cmd = a:0 && !empty(a:1) ? a:cmd . ' >' . shellescape(a:1) : a:cmd
  if &verbose
    echomsg '[suda]' cmd
  endif
  if has('win32') || &shell =~# 'csh$'
    let output = systemlist(cmd, a:input)
    return {'code': v:shell_error, 'stdout': output, 'stderr': output}
  endif
  let errfile = tempname()
  try
    let stdout = systemlist(cmd . ' 2>' . shellescape(errfile), a:input)
    let code = v:shell_error
    let stderr = filereadable(errfile) ? readfile(errfile) : []
  finally
    call delete(errfile)
  endtry
  return {'code': code, 'stdout': stdout, 'stderr': stderr}
endfunction

" Ask for the sudo password. Returns an empty string if cancelled.
" Internal: also called by lua/suda/server.lua.
function! suda#_read_password() abort
  try
    call inputsave()
    redraw | let password = inputsecret(g:suda#prompt)
  finally
    call inputrestore()
  endtry
  return password
endfunction

" 'nvim': lua/suda/server.lua runs each sudo step via vim.system(), without
" a shell or detaching: in the Terminal Client when the delegation guard
" passes, sharing the Host Shell's Credential Scope (ADR-0002), otherwise in
" the editor's server, sharing it within the Editor Session.
" 'system': sudo runs via systemlist() (Vim, Neovim < 0.10, Windows).
" g:suda#_backend forces one of them (used by the tests).
function! s:backend() abort
  let forced = get(g:, 'suda#_backend', '')
  if !empty(forced)
    return forced
  endif
  return has('nvim-0.10') && !has('win32') ? 'nvim' : 'system'
endfunction

" Runs {cmd} (an argv list) with privileges, with {input} on stdin.
" Returns {'code', 'stdout', 'stderr'} with output as lists of lines.
" With {stdout_path} (a:1), stdout goes byte for byte into that file instead.
" Throws 'cancelled' if the password prompt is answered with nothing.
"
" The command runs exactly once. With sudo, a cached credential is checked
" first (`sudo -n -v`); the password is asked for only when there is none.
" With g:suda#noninteractive, on Windows, or with a non-sudo executable, the
" command runs without validation or a password prompt.
function! s:run_privileged(cmd, input, ...) abort
  let stdout_path = a:0 ? a:1 : ''
  if s:backend() ==# 'nvim'
    let spec = {
          \ 'executable': s:argv_prefix(),
          \ 'sudo': s:is_sudo() ? v:true : v:false,
          \ 'noninteractive': g:suda#noninteractive ? v:true : v:false,
          \ 'cmd': a:cmd,
          \ 'input': a:input,
          \}
    if !empty(stdout_path)
      let spec.stdout_path = stdout_path
    endif
    let result = luaeval('require("suda.server").run(_A)', spec)
    if get(result, 'cancelled')
      throw 'cancelled'
    endif
    return result
  endif

  if has('win32') || !s:is_sudo()
    return s:run(s:get_command([], a:cmd), a:input, stdout_path)
  elseif g:suda#noninteractive
    return s:run(s:get_command(['-n'], a:cmd), a:input, stdout_path)
  endif
  if s:run(s:command_line(['-n', '-v']), '').code == 0
    return s:run(s:get_command(['-n'], a:cmd), a:input, stdout_path)
  endif
  let password = suda#_read_password()
  if empty(password)
    throw 'cancelled'
  endif
  return s:run(s:get_command(['-p', '', '-S'], a:cmd), password . "\n" . a:input, stdout_path)
endfunction

" The error message of a failed {result}.
function! s:error(result) abort
  return empty(a:result.stderr)
        \ ? printf('command failed with exit code %d', a:result.code)
        \ : join(a:result.stderr, "\n")
endfunction

" Sets v:shell_error to {code} by running a trivial non-privileged process.
" Only the nvim backend needs this: the system backend's last systemlist()
" call already set it.
function! s:set_shell_error(code) abort
  if s:backend() ==# 'nvim' && v:shell_error != a:code
    call system(['sh', '-c', 'exit ' . a:code])
  endif
endfunction

" {cmd} is a argv list for the process
" {input} (a:1) is a string to pass as stdin to the command
" Returns the command's stdout as a list of lines (NULs replaced with NLs) on
" success, or its stderr lines on failure. Sets v:shell_error to the exit code.
function! suda#systemlist(cmd, ...) abort
  let result = s:run_privileged(a:cmd, a:0 ? a:1 : '')
  call s:set_shell_error(result.code)
  return result.code == 0 ? result.stdout : result.stderr
endfunction

" {cmd} is a argv list for the process
" {input} (a:1) is a string to pass as stdin to the command
" Like suda#systemlist() but joins the lines with NLs (NULs are removed).
function! suda#system(cmd, ...) abort
  let output = call('suda#systemlist', [a:cmd] + a:000)
  return join(map(output, { k, v -> substitute(v, '\n', '', 'g') }), "\n")
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
    " The privileged `cat` writes the file's bytes unchanged into {tempfile},
    " which is then read like an ordinary file.
    let result = s:run_privileged(['cat', path], '', tempfile)
    if result.code
      throw s:error(result)
    else
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
      let result = s:run_privileged(
            \ [tee_cmd, path],
            \ join(readfile(tempfile, 'b'), "\n") )
    else
      " `bs=1048576` is equivalent to `bs=1M` for GNU dd or `bs=1m` for BSD dd
      " Both `bs=1M` and `bs=1m` are non-POSIX
      let result = s:run_privileged(['dd', 'if='.tempfile, 'of='.path, 'bs=1048576'], '')
    endif
    if result.code
      throw s:error(result)
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
    " ++edit: detect 'fileformat', 'fileencoding' and 'eol' as :edit does
    let echo_message = suda#read('<afile>', {
          \ 'cmdarg': v:cmdarg . ' ++edit',
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
