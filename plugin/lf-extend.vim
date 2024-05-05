vim9script

# src:
#   if in lf buffer (b:lf var exists), then use b:lf.cwd as src dir;
#   else, use getcwd().
#   use getline(line1, line2) as filename entries.
#
# dest:
#   if provided a number, then use buffer with that id as dest dir;
#   (like src, check if target dir is lf buffer).
#   if no arg provided, then check if exactly ONE another lf buffer exists,
#   and use that buffer's cwd as dest. (like dual pane fm)

command -range -nargs=* LfMoveTo LfMoveTo(<line1>, <line2>, <q-args>)
command -range -nargs=* LfCopyTo LfCopyTo(<line1>, <line2>, <q-args>)
command -range LfDelete LfDelete(<line1>, <line2>)

augroup lf_extend
    au!
augroup END

def LfMoveTo(line1: number, line2: number, dest: string)
    LfActionProxy(action_move, line1, line2, dest)
enddef

def LfCopyTo(line1: number, line2: number, dest: string)
    LfActionProxy(action_copy, line1, line2, dest)
enddef

def LfDelete(line1: number, line2: number)
    LfActionProxy(action_delete, line1, line2, '')
enddef

def LfActionProxy(action: string, line1: number, line2: number, dest: string)
    const src_entries = GetSrcEntries(line1, line2)
    if !src_entries
        return
    endif
    var dst_dir = ''
    if action == action_move || action == action_copy
        dst_dir = GetDestDir(dest)
        # ensure dst dir ends with slash.
        if dst_dir !~ '/$'
            return
        endif
    endif

    echohl String | echo 'Files to operate on:' | echohl None
    EchoEntries(src_entries)

    if action == action_move
        echohl String | echo 'Will be moved to: ' | echohl None
        echohl Directory | echon dst_dir | echohl None
        echo 'Move? [y/N]'
    elseif action == action_copy
        echohl String | echo 'Will be copied to: ' | echohl None
        echohl Directory | echon dst_dir | echohl None
        echo 'Copy? [y/N]'
    elseif action == action_delete
        echohl WarningMsg | echo 'Will be deleted.' | echohl None
        echo 'Delete? [y/N]'
    else
        throw 'panic'
    endif

    if getcharstr()->tolower() != 'y'
        redrawstatus | echo
        return
    endif

    const Fn = {
        [action_move]: ImplMoveTo,
        [action_copy]: ImplCopyTo,
        [action_delete]: ImplDelete,
    }[action]
    Fn(src_entries, dst_dir)
enddef

const action_move = 'MOVE'
const action_copy = 'COPY'
const action_delete = 'DELETE'

def GetSrcEntries(line1: number, line2: number): list<dict<string>>
    const dir = b:->get('lf', {})->get('cwd', '') ?? getcwd()->fnamemodify(':p')->NormPath()
    var result = []
    for i in getline(line1, line2)
        if i->empty()
            continue
        endif
        var path_from_line = i->simplify()
        if has('win32')
            path_from_line = path_from_line->substitute('\', '/', 'g')
        endif
        var [i_dir, i_name] = ['', '']
        i_dir = path_from_line->matchstr('\v.*/\ze[^/]+/?$')
        if !i_dir->empty()
            i_name = path_from_line[i_dir->len() : ]
        else
            [i_dir, i_name] = [dir, i]
        endif
        result->add({dir: i_dir, name: i_name})
    endfor
    return result
enddef

def NormPath(s: string): string
    var res = s
    if has('win32')
        res = res->substitute('\', '/', 'g')
    endif
    res = res .. '/'
    res = res->substitute('//$', '/', '')
    return res
enddef

def GetDestDir(dest: string): string
    var result: string = ''
    if dest == ''
        var lf_buffers: list<number> = []
        const buf_id = bufnr()
        for i in tabpagebuflist()
            if buf_id != i && !!getbufvar(i, 'lf', {})->get('cwd', '')
                lf_buffers->add(i)
            endif
        endfor
        if lf_buffers->len() != 1
            echohl ErrorMsg | echo $'lf-extend: target not specified, and cannot infer target lf buffer!' | echohl None
            return ''
        endif
        return getbufvar(lf_buffers[0], 'lf').cwd
    elseif dest =~ '\v^[0-9]+$'
        const buf_id = dest->str2nr()
        const lf_buffer = bufnr(buf_id)
        if lf_buffer < 0
            echohl ErrorMsg | echo $'lf-extend: buffer not found: {dest}' | echohl None
            return ''
        endif
        result = getbufvar(buf_id, 'lf', {})->get('cwd', '')
        if !result
            echohl ErrorMsg | echo $'lf-extend: is not lf buffer: {dest}' | echohl None
            return ''
        endif

        return result->NormPath()
    endif

    result = dest->simplify()->fnamemodify(':p')
    if !isdirectory(result)
        echohl ErrorMsg | echo $'lf-extend: is not directory: {dest}' | echohl None
        return ''
    endif

    return result->NormPath()
enddef

def EchoEntries(entries: list<dict<string>>)
    for i in entries
        echohl Directory | echo '  ' i.dir | echohl None
        echon i.name
    endfor
enddef

const job_info_success = 'SUCC'
const job_info_fail = 'FAIL'
const job_info_wait = 'WAIT'

def JobProgress(bufnr: number)
    var ctx = getbufvar(bufnr, 'lf_extend_ctx')
    setbufline(ctx.bufnr, 1, $'COPY TO: {ctx.dest}')
    for i in range(len(ctx.entries))
        var entry = ctx.entries[i]
        if !has_key(entry, 'state')
            entry.state = job_info_wait
        endif
        const line = $'[{entry.state}] {entry.dir}{entry.name}'
        # i: 0 based index; line 1: buffer header; entry begins from line no 2.
        setbufline(ctx.bufnr, i + 2, line)
    endfor
    if ctx->has_key('finished_at')
        appendbufline(ctx.bufnr, '$', $'Finished at {ctx.finished_at}.')
        if buflisted(ctx.bufnr)
            setbufvar(ctx.bufnr, '&buflisted', false)
        endif
    endif
enddef

def JobCallback(ctx: dict<any>, job: any, exitcode: number)
    if ctx.current_index >= 0
        ctx.entries[ctx.current_index].state = exitcode == 0 ? job_info_success : job_info_fail
    endif
    ctx.current_index += 1

    const finished = ctx.current_index >= ctx.entries->len()
    if finished
        var [count_ok, count_err] = [0, 0]
        for entry in ctx.entries
            if entry.state == job_info_success
                count_ok += 1
            elseif entry.state == job_info_fail
                count_err += 1
            endif
        endfor
        ctx.finished_at = strftime("%Y-%m-%d %H:%M:%S")
        if count_err > 0
            popup_notification($'lf.vim: copy action failed: ok: {count_ok}; err: {count_err}.', {
                highlight: 'ErrorMsg',
            })
        else
            popup_notification($'lf.vim: copy action success: ok: {count_ok}; err: {count_err}.', {
                highlight: 'Normal',
            })
        endif
    endif

    setbufvar(ctx.bufnr, 'lf_extend_ctx', ctx)
    JobProgress(ctx.bufnr)
    if finished
        return
    endif

    const entry = ctx.entries[ctx.current_index]
    var path_src = entry.dir .. entry.name
    var path_dest = ctx.dest
    if has('win32')
        path_src = path_src->substitute('/', '\\', 'g')
        path_dest = (path_dest .. '/')->substitute('//$', '/', '') .. entry.name
        path_dest = path_dest->substitute('/', '\\', 'g')
        # If path_src is not directory, and path_dest does not exist,
        # xcopy will ask if target is directory or file;
        #
        # If entry name is stripped from path_dest and final backslash
        # (pathsep) is kept (target path's parent directory), xcopy will fail;
        #
        # The final backslash should be removed to make xcopy work in this
        # situation.
        # But it is hard to do so: target path may be filesystem root, then
        # final backslash should not be removed.
        #
        # So we just create a file at destination, then xcopy to it.
        if !isdirectory(path_src) && (!filereadable(path_dest))
            try
                ['tempfile created by lf-extend.vim to make xcopy work']->writefile(path_dest)
            catch /^Vim\%((\a\+)\)\=:E482:/
                timer_start(0, (_) => {
                    JobCallback(ctx, null, -1)
                })
                return
            endtry
        endif
    endif
    const args = has('win32') ? (
        ['xcopy', path_src, path_dest, '/i', '/e', '/h', '/y']
    ) : (
        ['cp', '-R', '-H', path_src, path_dest]
    )
    job_start(args, {
        exit_cb: function('JobCallback', [ctx]),
    })
enddef

def ImplMoveTo(src_entries: list<dict<string>>, dest: string)
    var failed_items = []
    for i in src_entries
        if rename(i.dir .. i.name, dest .. i.name) != 0
            failed_items->add(i)
        endif
    endfor
    if !!failed_items
        echohl ErrorMsg | echo 'failed to move:' | echohl None
        EchoEntries(failed_items)
    endif
enddef

def ImplCopyTo(src_entries: list<dict<string>>, dest: string)
    # time is used to make buffer unique;
    # if multiple copy actions are really created during one second,
    # then... good luck.
    const time = strftime('%Y-%m-%d %H:%M:%S')
    const bufnr = bufadd($'[lf Copy Queue ({time})]')
    setbufvar(bufnr, '&swapfile', false)
    setbufvar(bufnr, '&buftype', 'nofile')
    # avoid closing buffer quit copy process.
    setbufvar(bufnr, '&bufhidden', 'hide')
    setbufvar(bufnr, '&buflisted', true)
    # required before set buf line.
    bufload(bufnr)

    echo
    redrawstatus | echon $'copying files... (execute ":{bufnr}b" for details)'

    var ctx = {entries: src_entries->deepcopy(), dest: dest, current_index: -1, bufnr: bufnr}
    JobCallback(ctx, null, 0)
    execute $'au BufReadCmd <buffer={bufnr}> JobProgress({bufnr})'
enddef

def ImplDelete(src_entries: list<dict<string>>, dest: string)
    var failed_items = []
    for i in src_entries
        if delete(i.dir .. i.name, 'rf') != 0
            failed_items->add(i)
        endif
    endfor
    if !!failed_items
        echohl ErrorMsg | echo 'failed to delete:' | echohl None
        EchoEntries(failed_items)
    endif
enddef
