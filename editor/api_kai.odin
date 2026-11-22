package editor

import "core:strings"
import "core:time"
import "mirai:asset"
import ka "mirai:cook/kai"
import "mirai:editor/api"
import vcs "mirai:kai"

// The kai.* methods: the version control of the project as the Kai tab shows
// it. A change is named by @ (the working copy), @- (its parent), a bookmark
// or a prefix of its id as kai.log gives it.

Api_Kai_File :: struct {
    path:string `mirai:"label=From the folder of the project"`,
    change:string `mirai:"label=A added; D removed; M changed; C in conflict"`,
}

Api_Kai_Status :: struct {
    change:string `mirai:"label=The id of the working copy"`,
    description:string,
    files:[]Api_Kai_File `mirai:"label=What the working copy changed from its parents"`,
    conflicts:[]string `mirai:"label=The files in conflict: kai.conflicts gives their fields, kai.resolve settles them"`,
    operation:string `mirai:"label=The newest operation: what kai.undo takes back; an undo, which kai.undo redoes"`,
}

Api_Kai_Snapshot :: struct {
    change:string,
    files:int `mirai:"label=Files of the working copy"`,
    read:int `mirai:"label=Files read and hashed again: the others had not changed"`,
}

Api_Kai_New_Params :: struct {
    parents:[]string `mirai:"optional,label=The changes it goes on, their trees merged; none: the working copy"`,
    description:string `mirai:"optional"`,
}

Api_Kai_Split_Params :: struct {
    files:[]string `mirai:"label=Project paths of the files the first change takes, as kai.status lists them; a folder takes every file under it"`,
    change:string `mirai:"optional,label=The change to split; none: the working copy"`,
    description:string `mirai:"optional,label=The first change's description; none: the change's own"`,
}
Api_Kai_Split :: struct {
    first:string `mirai:"label=The change with the files picked: it keeps the change's id"`,
    second:string `mirai:"label=A new change on the first with the rest: what pointed at the change, the working copy too, is on it now"`,
}

Api_Kai_Describe_Params :: struct {
    change:string `mirai:"optional,label=The change to describe; none: the working copy"`,
    description:string,
}

Api_Kai_Change :: struct {change:string}

Api_Kai_Log_Params :: struct {
    limit:int `mirai:"optional,min=1,max=4096,label=Changes listed, newest first"`,
    file:string `mirai:"optional,label=A file change changed, from the folder of the project: detail says what it did to it"`,
    change:string `mirai:"optional,label=With file: the change; none: the working copy"`,
}
Api_Kai_Log_Row :: struct {
    change:string,
    description:string,
    working:bool `mirai:"label=The working copy"`,
    bookmarks:[]string,
    conflicts:int `mirai:"label=Files in conflict in its tree"`,
    coauthors:int `mirai:"label=Editors of a session besides its author"`,
    turns:int `mirai:"label=Turns of agents recorded in it"`,
}
Api_Kai_Log :: struct {
    changes:[]Api_Kai_Log_Row,
    detail:Api_Kai_Detail `mirai:"optional,label=Of file: what change did to it"`,
}

Api_Kai_Detail_Row :: struct {
    mark:string `mirai:"label=+ added, - removed, ~ a field of an asset changed, a space kept; empty: a fold of kept lines"`,
    old:int `mirai:"optional,label=Of a text: its line before the change, from 1"`,
    new:int `mirai:"optional,label=Of a text: its line after the change, from 1, as the lines of a comment name it"`,
    skipped:int `mirai:"optional,label=Of a fold: the kept lines it stands for"`,
    text:string `mirai:"label=The line, or the path in the asset and its values"`,
    entity:u64 `mirai:"optional,label=Of an asset: the entity or row it is on, as the entity of a comment names it"`,
    name:string `mirai:"optional,label=Of entity: its name"`,
}
Api_Kai_Detail :: struct {
    file:string,
    change:string,
    status:string `mirai:"label=A added; D removed; M changed; C in conflict"`,
    kind:string `mirai:"label=text, asset, binary or oversized: of the last two only the sizes"`,
    before:int `mirai:"label=Bytes before the change"`,
    after:int `mirai:"label=Bytes after it"`,
    added:int `mirai:"label=Lines added; of an asset, rows and fields"`,
    removed:int,
    changed:int `mirai:"label=Of an asset: fields changed"`,
    rows:[]Api_Kai_Detail_Row,
    cut:int `mirai:"label=Rows past the bound of a detail, not given"`,
}

Api_Kai_Undone :: struct {undone:string `mirai:"label=The operation taken back"`}
Api_Kai_Pruned :: struct {freed:i64 `mirai:"label=Bytes the store's sweep freed"`}

Api_Kai_Restore_Params :: struct {
    from:string `mirai:"label=The change whose files the working copy takes"`,
}
Api_Kai_Done :: struct {ok:bool}

Api_Kai_Field :: struct {
    kind:string `mirai:"label=value: both changed it; removed: one side removed the row the other changed; table: both changed a table matched whole"`,
    path:string `mirai:"label=Where in the asset: what kai.resolve takes in theirs"`,
    entity:string `mirai:"optional,label=The name of the entity"`,
    ours:string `mirai:"optional,label=Of a value: the working copy's parent side, which the file holds"`,
    theirs:string `mirai:"optional,label=Of a value: the other side"`,
    ours_has:bool `mirai:"optional,label=Of a row: whether ours has it"`,
    theirs_has:bool `mirai:"optional,label=Of a row: whether theirs has it"`,
}
Api_Kai_Conflict :: struct {
    path:string,
    asset:bool `mirai:"label=Its fields resolve one by one; else it resolves whole"`,
    fields:[]Api_Kai_Field,
}
Api_Kai_Conflicts :: struct {files:[]Api_Kai_Conflict}

Api_Kai_Resolve_Params :: struct {
    file:string `mirai:"label=A file kai.conflicts lists"`,
    whole:string `mirai:"optional,label=ours or theirs: that side whole; none: field by field"`,
    theirs:[]string `mirai:"optional,label=Field by field: the paths of the conflicts that take theirs; the others keep ours"`,
}

Api_Kai_Bookmarks_Params :: struct {
    set:string `mirai:"optional,label=A bookmark of this workspace to point at change"`,
    change:string `mirai:"optional,label=With set or move: the change; none: the working copy"`,
    remove:string `mirai:"optional,label=A bookmark of this workspace to remove"`,
    move:string `mirai:"optional,label=A bookmark the project's org shares: moves it to change for the whole org, refused with the policy's reason when one guards it"`,
    policy:string `mirai:"optional,label=A shared bookmark to guard: it then moves only by landing a proposal with approvals and checks"`,
    approvals:int `mirai:"optional,label=With policy: the approvals a landing needs"`,
    checks:[]string `mirai:"optional,label=With policy: the checks that must pass on the final revision"`,
}
Api_Kai_Bookmark :: struct {
    name:string `mirai:"label=A device's is <handle>/<device>:<bookmark>"`,
    change:string `mirai:"label=Empty while two operations moved it apart, or while its change is not in the store"`,
    shared:bool `mirai:"optional,label=Of the project's org"`,
    device:string `mirai:"optional,label=The device that published it, <handle>/<device>"`,
    here:bool `mirai:"optional,label=Of a shared one: its change is in the store"`,
}
Api_Kai_Bookmarks :: struct {bookmarks:[]Api_Kai_Bookmark}

@(private)
kai_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="kai.status",summary="The working copy as the Kai tab shows it, snapshot first: its change, what it changed, the files in conflict and the newest operation.",result=type_info_of(Api_Kai_Status),run=api_kai_status})
    api_register(s,st,{name="kai.snapshot",summary="Records the files of the project as they are now as the working copy, with the editors and agent turns that changed them since.",result=type_info_of(Api_Kai_Snapshot),run=api_kai_snapshot})
    api_register(s,st,{name="kai.new",summary="Starts a new change as the working copy, on the working copy or on given changes, whose trees merge; what does not merge is a conflict in its files that never blocks.",params=type_info_of(Api_Kai_New_Params),result=type_info_of(Api_Kai_Change),run=api_kai_new})
    api_register(s,st,{name="kai.split",summary="Splits a change by files: the first keeps its id, parents and description with only the files picked; the second, a new change on it, holds the rest, and what pointed at the change moves onto it. The files on disk stay as they are.",params=type_info_of(Api_Kai_Split_Params),result=type_info_of(Api_Kai_Split),run=api_kai_split})
    api_register(s,st,{name="kai.describe",summary="Gives a change its description.",params=type_info_of(Api_Kai_Describe_Params),result=type_info_of(Api_Kai_Change),run=api_kai_describe})
    api_register(s,st,{name="kai.log",summary="The visible changes, newest first, with their bookmarks, conflicts, coauthors and agent turns; with file, what a change did to that file: its lines, or an asset's rows and fields.",params=type_info_of(Api_Kai_Log_Params),result=type_info_of(Api_Kai_Log),flags={.Read_Only},run=api_kai_log})
    api_register(s,st,{name="kai.undo",summary="Takes back the newest operation of the repository and writes the files as it leaves them; undoing an undo redoes it.",result=type_info_of(Api_Kai_Undone),flags={.Destructive},run=api_kai_undo})
    api_register(s,st,{name="kai.prune",summary="Prunes the operation log of every repository of the machine's store to its last 30 days and what the workspaces stand on, then has the store reclaim what nothing reaches any more. Undo does not go past a prune.",result=type_info_of(Api_Kai_Pruned),flags={.Destructive},run=api_kai_prune})
    api_register(s,st,{name="kai.restore",summary="Gives the working copy the files of another change and writes them.",params=type_info_of(Api_Kai_Restore_Params),result=type_info_of(Api_Kai_Done),flags={.Destructive},run=api_kai_restore})
    api_register(s,st,{name="kai.conflicts",summary="The files of the working copy in conflict; an asset with its fields both sides changed apart, ours and theirs.",result=type_info_of(Api_Kai_Conflicts),flags={.Read_Only},run=api_kai_conflicts})
    api_register(s,st,{name="kai.resolve",summary="Resolves a file in conflict: field by field with the conflicts that take theirs, or one side whole. The file is written and recorded.",params=type_info_of(Api_Kai_Resolve_Params),result=type_info_of(Api_Kai_Done),run=api_kai_resolve})
    api_register(s,st,{name="kai.bookmarks",summary="The bookmarks of the workspace, then those the project's org shares and every device's; sets or removes one of the workspace, moves a shared one or guards it with a policy first when asked.",params=type_info_of(Api_Kai_Bookmarks_Params),result=type_info_of(Api_Kai_Bookmarks),run=api_kai_bookmarks})
    kai_team_api_register(s,st)
}

// The workspace, or the call fails with why there is none.
@(private)
api_kai_workspace :: proc(s:^Session,call:^api.Call) -> ^vcs.Workspace {
    w:=kai_workspace(s)
    if w==nil {api.call_fail(call,api.SERVER_ERROR,kai_missing(s))}
    return w
}

@(private)
api_kai_change :: proc(s:^Session,call:^api.Call,w:^vcs.Workspace,text:string) -> (revision:vcs.Revision,ok:bool) {
    return api_kai_revision(s,call,text)
}

@(private)
api_kai_text :: proc(w:^vcs.Workspace,revision:vcs.Revision,call:^api.Call) -> string {
    c,e:=vcs.change_get(w.repo.s,revision,context.temp_allocator)
    if e!=.None {return ""}
    return ka.change_text(c.id,call.allocator)
}

@(private)
api_kai_ended :: proc(call:^api.Call,message:string) -> bool {
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return false}
    return true
}

@(private)
api_kai_status :: proc(s:^Session,call:^api.Call) {
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    vcs.workspace_touched(w,nil,false)
    if !api_kai_ended(call,kai_snapshot(s)) {return}
    v:=&s.kai.state.view
    r:=api.call_result(call,Api_Kai_Status)
    r.change=strings.clone(v.change,call.allocator)
    r.description=strings.clone(v.description,call.allocator)
    r.files=make([]Api_Kai_File,len(v.files),call.allocator)
    conflicts:=make([dynamic]string,call.allocator)
    for f,i in v.files {
        mark:=[1]u8{f.mark}
        r.files[i]={strings.clone(f.path,call.allocator),strings.clone(string(mark[:]),call.allocator)}
        if f.mark=='C' {append(&conflicts,r.files[i].path)}
    }
    r.conflicts=conflicts[:]
    r.operation=strings.clone(v.operation,call.allocator)
}

@(private)
api_kai_snapshot :: proc(s:^Session,call:^api.Call) {
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    files_flush(s,true)
    vcs.workspace_touched(w,nil,false)
    if !api_kai_ended(call,kai_snapshot(s)) {return}
    r:=api.call_result(call,Api_Kai_Snapshot)
    r.change=api_kai_text(w,vcs.repo_working(&w.repo),call)
    r.files=len(w.index.rows)
}

@(private)
api_kai_new :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_New_Params)
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    parents:=make([dynamic]vcs.Revision,context.temp_allocator)
    for text in p.parents {
        revision,ok:=api_kai_change(s,call,w,text)
        if !ok {return}
        append(&parents,revision)
    }
    if !api_kai_ended(call,kai_new(s,parents[:],p.description)) {return}
    api.call_result(call,Api_Kai_Change).change=api_kai_text(w,vcs.repo_working(&w.repo),call)
}

@(private)
api_kai_split :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Split_Params)
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    first,second,message,invalid:=kai_split(s,p.change!=""?p.change:"@",p.files,p.description)
    if message!="" {
        api.call_fail(call,invalid?api.INVALID_PARAMS:api.SERVER_ERROR,message)
        return
    }
    r:=api.call_result(call,Api_Kai_Split)
    r.first=api_kai_text(w,first,call)
    r.second=api_kai_text(w,second,call)
}

@(private)
api_kai_describe :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Describe_Params)
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    revision,ok:=api_kai_change(s,call,w,p.change!=""?p.change:"@")
    if !ok {return}
    id:vcs.Change_Id
    if c,e:=vcs.change_get(w.repo.s,revision,context.temp_allocator);e==.None {id=c.id}
    if !api_kai_ended(call,kai_describe(s,revision,p.description)) {return}
    api.call_result(call,Api_Kai_Change).change=ka.change_text(id,call.allocator)
}

@(private)
api_kai_log :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Log_Params)
    if p.change!="" && p.file=="" {
        api.call_fail(call,api.INVALID_PARAMS,"change goes with file: name the file whose detail it gives")
        return
    }
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    revision:vcs.Revision
    if p.file!="" {
        if p.change=="" {
            vcs.workspace_touched(w,nil,false)
            if !api_kai_ended(call,kai_snapshot(s)) {return}
        }
        found:bool
        if revision,found=api_kai_revision(s,call,p.change!=""?p.change:"@");!found {return}
    }
    rows:=make([dynamic]ka.Log_Row,context.temp_allocator)
    if e:=ka.log(w,p.limit>0?p.limit:KAI_LOG_ROWS,&rows,call.allocator);e!=.None {api.call_fail(call,api.SERVER_ERROR,vcs.error_text(e));return}
    r:=api.call_result(call,Api_Kai_Log)
    r.changes=make([]Api_Kai_Log_Row,len(rows),call.allocator)
    for row,i in rows {
        r.changes[i]={
            change=ka.change_text(row.change.id,call.allocator),description=row.change.description,working=row.working,
            bookmarks=row.bookmarks,conflicts=int(row.conflicts),coauthors=len(row.change.coauthors),turns=len(row.change.turns),
        }
        if shared:=kai_shared_names(s,row.revision,call.allocator);shared!="" {
            names:=make([dynamic]string,0,len(row.bookmarks)+1,call.allocator)
            append(&names,..row.bookmarks)
            append(&names,shared)
            r.changes[i].bookmarks=names[:]
        }
    }
    if p.file!="" {api_kai_detail(s,call,revision,p.file,&r.detail)}
}

// What the change at revision did to the file at path, into out: false when
// the call failed.
@(private)
api_kai_detail :: proc(s:^Session,call:^api.Call,revision:vcs.Revision,path:string,out:^Api_Kai_Detail) -> bool {
    a:=call.allocator
    d:ka.File_Detail
    if message,_:=kai_detail_read(s,revision,path,&d,a,ka.MESH_WAIT);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return false
    }
    kinds:=[ka.Detail_Kind]string{.Text="text",.Asset="asset",.Binary="binary",.Oversized="oversized"}
    mark:=[1]u8{d.mark}
    out^={file=d.path,change=api_kai_text(kai_workspace(s),revision,call),status=strings.clone(string(mark[:]),a),kind=kinds[d.kind],before=int(d.before),after=int(d.after),added=d.added,removed=d.removed,changed=d.changed,cut=d.cut}
    out.rows=make([]Api_Kai_Detail_Row,len(d.rows),a)
    for row,i in d.rows {
        x:=&out.rows[i]
        x^={old=int(row.old),new=int(row.new),skipped=int(row.skipped),text=row.text,entity=row.key,name=row.name}
        if row.mark!=0 {
            m:=[1]u8{row.mark}
            x.mark=strings.clone(string(m[:]),a)
        }
    }
    return true
}

@(private)
api_kai_undo :: proc(s:^Session,call:^api.Call) {
    if api_kai_workspace(s,call)==nil {return}
    undone,message:=kai_undo(s)
    if !api_kai_ended(call,message) {return}
    api.call_result(call,Api_Kai_Undone).undone=strings.clone(undone,call.allocator)
}

@(private)
api_kai_prune :: proc(s:^Session,call:^api.Call) {
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    result,e:=ka.prune(w.repo.s,time.now()._nsec)
    if e!=.None {
        api.call_fail(call,api.SERVER_ERROR,vcs.error_text(e))
        return
    }
    vcs.repo_refresh(&w.repo)
    kai_read(s)
    api.call_result(call,Api_Kai_Pruned).freed=result.bytes
}

@(private)
api_kai_restore :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Restore_Params)
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    from,ok:=api_kai_change(s,call,w,p.from)
    if !ok || !api_kai_ended(call,kai_restore(s,from)) {return}
    api.call_result(call,Api_Kai_Done).ok=true
}

@(private)
api_kai_conflicts :: proc(s:^Session,call:^api.Call) {
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    types:=kai_types(s)
    kinds:=[asset.Merge_Kind]string{.Value="value",.Removed="removed",.Table="table"}
    r:=api.call_result(call,Api_Kai_Conflicts)
    r.files=make([]Api_Kai_Conflict,len(w.state.conflicts),call.allocator)
    for m,i in w.state.conflicts {
        file:=&r.files[i]
        file.path=strings.clone(m.path,call.allocator)
        if types==nil {continue}
        fields:=make([dynamic]ka.Field_Conflict,context.temp_allocator)
        file.asset,_=ka.conflict_fields(w,types,m.path,&fields,call.allocator)
        file.fields=make([]Api_Kai_Field,len(fields),call.allocator)
        for f,k in fields {
            file.fields[k]={kind=kinds[f.kind],path=f.path,entity=f.name,ours=f.ours,theirs=f.theirs,ours_has=f.ours_has,theirs_has=f.theirs_has}
        }
    }
}

@(private)
api_kai_resolve :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Resolve_Params)
    if api_kai_workspace(s,call)==nil {return}
    whole:ka.Resolve_Whole
    switch p.whole {
    case "": whole=.Fields
    case "ours": whole=.Ours
    case "theirs": whole=.Theirs
    case:
        api.call_failf(call,api.INVALID_PARAMS,"whole is ours or theirs, not %q; leave it out to resolve field by field",p.whole)
        return
    }
    if !api_kai_ended(call,kai_resolve(s,p.file,whole,p.theirs)) {return}
    api.call_result(call,Api_Kai_Done).ok=true
}

@(private)
api_kai_bookmarks :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Bookmarks_Params)
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    if p.set!="" {
        revision,ok:=api_kai_change(s,call,w,p.change!=""?p.change:"@")
        if !ok || !api_kai_ended(call,kai_bookmark(s,p.set,revision)) {return}
    }
    if !api_kai_bookmark_team(s,call,p) {return}
    if p.remove!="" {
        if vcs.view_bookmark(&w.repo.view,p.remove)==nil {
            api.call_failf(call,api.INVALID_PARAMS,"the repository has no bookmark %q: kai.bookmarks lists them",p.remove)
            return
        }
        if !api_kai_ended(call,kai_bookmark(s,p.remove,{})) {return}
    }
    r:=api.call_result(call,Api_Kai_Bookmarks)
    list:=make([dynamic]Api_Kai_Bookmark,0,len(w.repo.view.bookmarks),call.allocator)
    for &b in w.repo.view.bookmarks {
        x:=Api_Kai_Bookmark{name=strings.clone(b.name,call.allocator)}
        if value,resolved:=vcs.terms_resolved(&b.terms);resolved {x.change=api_kai_text(w,value,call)}
        append(&list,x)
    }
    api_kai_shared(s,call,&list)
    r.bookmarks=list[:]
}
