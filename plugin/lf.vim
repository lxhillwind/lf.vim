vim9script

# emulate lf's basic movement function;
# originally, mainly used for directory traveling when lf executable is not available.
# But now it also replaces vim-dirvish plugin in my usecase.
#
# # this shell function is extracted from my zshrc;
# l()
# {
#     local LF_TARGET="$(mktemp)"
#     if [ $? -ne 0 ]; then
#         return 1
#     fi
#     LF_SELECT="$1" LF_TARGET="$LF_TARGET" vim +LfMain
#     local x="$(cat -- "$LF_TARGET")"
#     rm -- "$LF_TARGET"
#     if [ -z "$x" ]; then
#         # if lf.vim gives error, then "$x" will be empty.
#         return 0
#     fi
#     if [ "$x" != "$PWD" ] && [ "$x" != "$PWD"/ ]; then
#         # $PWD may contain final /, if it's in directory root
#         # (also consider busybox-w32 UNC path, where $PWD may contain many /);
#         # $x (from lf.vim) always has final /;
#         # so to check if dir changes, just compare $x with $PWD and "$PWD"/.
#         cd "$x"
#     fi
# }

if !$LF_TARGET->empty()
    # define LfMain command as buffer local, so after calling Lf(),
    # a new buffer will be created, then it will no longer be available,
    # and does not mess up cmdline completion.
    command -buffer LfMain Main()
endif
command -nargs=+ -complete=custom,LfArgComplete Lf Lf(<q-args>)
nnoremap - <Cmd>execute 'Lf' expand('%') ?? '.'<CR>

augroup lf_plugin
    au!
augroup END

def Lf(arg: string, opt: dict<any> = {reuse_buffer: false}): bool
    {
        # check if unc path will hang, in an external job;
        # this help avoid hanging vim's main thread.
        #
        # xcopy will check only cwd's top level entries (not recursively), and
        # '/l' (dry run) option is provided; so it should be safe.
        if has('win32')
            const cwd = arg->substitute('\', '/', 'g')
            if cwd =~ '\v^//.+/.+'
                const job = job_start(['xcopy', cwd->substitute('/', '\\', 'g'), '/l', '/c'])
                sleep 100m
                if job_status(job) == 'run'
                    echohl ErrorMsg | echo $'lf.vim: may hang on: "{cwd}"' | echohl None
                    job_stop(job)
                    return false
                endif
            endif
        endif
    }

    # define highlight here, in case colorscheme change clear them.
    hi link lf_buffer_directory Directory
    hi link lf_buffer_symlink Added
    hi link lf_buffer_file Normal

    # simplify(): handle '..' in path.
    var cwd = arg->fnamemodify(':p')->simplify()
    # assume that cwd is always end with '/'.
    if has('win32')
        # ignore shellslash option; since if we edit a .lnk linking to a
        # directory, then press '-', its path will contain '\' even if
        # shellslash is set.
        cwd = cwd->substitute('\', '/', 'g')
    endif
    var old_name: string = ''
    # if arg is a file, then use its parent directory.
    if !isdirectory(cwd)
        old_name = cwd
        cwd = cwd->substitute('\v[^/]+$', '', '')
    endif
    if !isdirectory(cwd)
        echohl ErrorMsg | echo $'lf.vim: is not directory: "{arg}"' | echohl None
        return false
    endif

    if !opt.reuse_buffer
        noswapfile enew
        # this BufReadCmd action is used for reusing buffer;
        # because props lose after re-edit buffer.
        augroup lf_plugin
            au BufReadCmd <buffer> Lf('.', {reuse_buffer: true})
        augroup END
    endif
    set buftype=nofile
    # this option is required to make <C-6> (switch back to this buffer) work
    # as expected; otherwise props will lose, causing RefreshDir() raise.
    set bufhidden=hide

    b:lf = {cwd: cwd, find_char: '', entries: []}
    const buf = bufnr()
    prop_type_add(prop_dir, {bufnr: buf, highlight: 'lf_buffer_directory'})
    prop_type_add(prop_not_dir, {bufnr: buf, highlight: 'lf_buffer_file'})
    prop_type_add(prop_symlink, {bufnr: buf, highlight: 'lf_buffer_symlink'})

    nnoremap <buffer> q <ScriptCmd>KeyQ()<CR>
    nnoremap <buffer> h <ScriptCmd>Up()<CR>
    nnoremap <buffer> l <ScriptCmd>Down()<CR>
    nnoremap <buffer> f <ScriptCmd>Find('f')<CR>
    nnoremap <buffer> F <ScriptCmd>Find('F')<CR>
    nnoremap <buffer> ; <ScriptCmd>Find(';')<CR>
    nnoremap <buffer> , <ScriptCmd>Find(',')<CR>
    nnoremap <buffer> e <ScriptCmd>Edit()<CR>
    nnoremap <buffer> yy <ScriptCmd>YankFullPath()<CR>
    nnoremap <buffer> K <ScriptCmd>KeyK()<CR>
    # refresh
    nnoremap <buffer> r :e<CR>
    # refresh all lf window
    nnoremap <buffer> R :windo if exists('b:lf') \| silent e \| endif<CR>
    # recover -'s mapping.
    nnoremap <buffer> - -

    RefreshDir()
    if !old_name->empty()
        CursorToLastVisited(old_name)
    endif

    return true
enddef

const prop_dir = 'dir'
const prop_not_dir = 'not_dir'
const prop_symlink = 'symlink'

def KeyQ()
    # remap to quit if there is only one window.
    if tabpagenr('$') == 1 && winnr('$') == 1
        Quit()
    else
        feedkeys('q', 'n')
    endif
enddef

def Quit()
    # always close current buffer
    defer execute('quit')

    if empty($LF_TARGET)
        return
    endif

    var cwd = b:lf.cwd
    # cwd always ends with /;
    # so it is safe to use it from shell like this:
    # cd "$(cat "$LF_TARGET")"
    if has('win32')
        # convert file encoding, so shell can use the content.
        const encoding = 'cp' .. libcallnr('kernel32.dll', 'GetACP', 0)
        cwd = cwd->iconv('utf-8', encoding)
    endif
    # use split("\n") (then join implicitly via writefile()),
    # since cwd may contain "\n".
    cwd->split("\n")->writefile($LF_TARGET)
enddef

def CursorToLastVisited(old_name: string)
    const target_basename = old_name->substitute('/$', '', '')
        ->substitute('\v.*/', '', '')
    for i in range(line('$'))
        const line_no = i + 1
        if getline(line_no)->substitute('/$', '', '') == target_basename
            execute $':{line_no}'
            break
        endif
    endfor
enddef

def Up()
    # '/': unix; '[drive CDE...]:/': win32
    # TODO: detect win32 UNC path root reliably.
    if b:lf.cwd->count('/') <= 1
        echohl Normal | echo $'lf.vim: already at root.' | echohl None
        return
    endif
    const old_cwd = b:lf.cwd
    const new_cwd = b:lf.cwd->substitute('[^/]\+/$', '', '')
    if win_findbuf(bufnr())->len() > 1
        Lf(new_cwd)
        return
    endif
    b:lf.cwd = new_cwd
    if !RefreshDir()
        b:lf.cwd = old_cwd
    else
        CursorToLastVisited(old_cwd)
    endif
enddef

def Down()
    const props = prop_list(line('.'))
    if len(props) == 0
        return
    endif

    const id = props[-1].id
    if id >= b:lf.entries->len()
        return
    endif

    const entry = b:lf.entries[id]
    if !entry.type->TypeIsDir()
        return
    endif
    const old_cwd = b:lf.cwd
    const new_cwd = b:lf.cwd .. entry.name .. '/'
    if win_findbuf(bufnr())->len() > 1
        Lf(new_cwd)
        return
    endif
    b:lf.cwd = new_cwd
    if !RefreshDir()
        b:lf.cwd = old_cwd
    endif
enddef

def Find(key: string)
    if key == 'f' || key == 'F'
        const find_char = getcharstr()
        if find_char == ''
            return
        endif
        b:lf.find_char = find_char
    endif
    if b:lf.find_char->empty()
        return
    endif
    const search = '\V\^' .. escape(b:lf.find_char, '\/')
    const order = (key == 'f' || key == ';') ? '/' : '?'
    # ':' is required in vim9.
    # 'silent!' to avoid not-found pattern causing break.
    silent! execute 'keeppattern' ':' .. order .. search
enddef

def Edit()
    const filename = b:lf.cwd .. getline('.')
    if isdirectory(filename)
        return
    endif
    execute 'edit' fnameescape(filename)
enddef

def YankFullPath()
    const filename = b:lf.cwd .. getline('.')
    const has_newline = filename->count("\n") > 0
    if has_newline
        # when text to copy contains newline character inline:
        # no way to preserve <Nul> (^@) in registers with assignment;
        # so use `yy` like operation.
        setline('.', filename)
        defer execute('silent normal! u')
        normal! yy
    else
        setreg('', filename, 'l')
    endif
enddef

def KeyK()
    const filename = getline('.')->substitute('/$', '', '')
    const info = readdirex('.', (i) => i.name == filename)->get(0)
    if empty(info)
        return
    endif
    var text = []
    for [k, v] in items(info)
        var t: string = $'{v}'
        if k == 'time'
            t = strftime('%Y-%m-%d %H:%M:%S', v)
            t = $'{v} ({t})'
        elseif k == 'size'
            if isdirectory(filename)
                continue
            endif
            const unit = ['', 'K', 'M', 'G']
            var n = v
            var base = 0
            while n > 0 && base <= len(unit)
                t = $'{n}{unit[base]}'
                base += 1
                n = v / float2nr(pow(10, 3 * base))
            endwhile
            if t != $'{v}'
                t = $'{v} ({t})'
            endif
        endif
        text->add($'{k}: {t}')
    endfor
    ShowInfo(text)
enddef

def ShowInfo(text: list<string>)
    popup_create(text, {
        mapping: false,
        filter: (winid, key) => {
            const key_ignore = ['q', "<\Esc>", "\<C-[>", "\<C-c>"]
            winid->popup_close()
            if key_ignore->index(key) < 0
                feedkeys(key, 'm')
            endif
            return true
        },
    })
enddef

def TypeIsDir(ty: string): bool
    const types_dir = ['linkd', 'dir']
    return types_dir->index(ty) >= 0
enddef

def TypeIsSymlink(ty: string): bool
    const types_symlink = ['linkd', 'link', 'junction']
    return types_symlink->index(ty) >= 0
enddef

def RefreshDir(): bool
    const cwd = b:lf.cwd
    if !isdirectory(cwd)
        echohl ErrorMsg | echo $'lf.vim: not directory: "{cwd}"' | echohl None
        return false
    endif
    try
        b:lf.entries = readdirex(cwd)
    catch
        echohl ErrorMsg | echo $'lf.vim: read dir error: "{cwd}"' | echohl None
        return false
    endtry

    normal! gg"_dG
    b:lf.entries->sort((a, b) => {
        const type_a = TypeIsDir(a.type) ? 1 : 0
        const type_b = TypeIsDir(b.type) ? 1 : 0
        if xor(type_a, type_b) > 0
            return type_a > type_b ? -1 : 1
        endif

        return a.name < b.name ? -1 : 1
    })
    const buf = bufnr()
    for i in range(len(b:lf.entries))
        const entry = b:lf.entries[i]
        const is_dir = TypeIsDir(entry.type)
        const is_symlink = TypeIsSymlink(entry.type)
        append(i, entry.name .. (is_dir ? '/' : ''))
        prop_add(i + 1, 1, {
            id: i, length: len(entry.name) + 1,
            type: is_symlink ? prop_symlink : (is_dir ? prop_dir : prop_not_dir),
            bufnr: buf
        })
    endfor
    normal! "_ddgg

    silent execute 'lcd' fnameescape(cwd)
    # use bufnr to make filename unique.
    execute 'file' fnameescape(cwd .. $' [{bufnr()}]')
    return true
enddef

def LfArgComplete(A: string, L: any, P: any): string
    const first = A->empty() ? [expand('%') ?? '.'] : []
    var others = []
    var dir = './'
    if A->match('/') >= 0 || (has('win32') && A->match('\\') >= 0)
        dir = A
        if has('win32')
            dir = dir->substitute('\', '/', 'g')
        endif
        dir = dir->substitute('\v[^/]+$', '', '')
    elseif A == '~'
        dir = '~/'
    endif
    try
        const dir_expand_tidle = dir->match('^\~') >= 0 ? $HOME .. dir[1 :] : dir
        others = dir_expand_tidle
            ->readdirex()
            ->filter((_, i) => i.type->TypeIsDir())
            ->sort((a, b) => {
                # lower hidden dir's priority
                if a.name[0] == '.' && b.name[0] != '.'
                    return 1
                elseif a.name[0] != '.' && b.name[0] == '.'
                    return -1
                else
                    return a.name < b.name ? -1 : 1
                endif
            })
            ->mapnew((_, i) => (dir == './' ? '' : dir) .. i.name .. '/')
            ->map((_, i) => i->simplify())
    catch /^Vim\%((\a\+)\)\=:E484:/
    endtry
    return (first + others)->join("\n")
enddef

def Main()
    const cwd = $LF_SELECT ?? '.'
    if !Lf(cwd)
        echo 'press any key to quit'
        # getchar() cannot catch <C-c>, so map it to quit.
        nnoremap <buffer> <C-c> <Cmd>quit<CR>
        getchar()
        quit
    endif
enddef
