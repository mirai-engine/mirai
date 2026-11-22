package editor

import "core:strings"
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

Api_Kai_Describe_Params :: struct {
    change:string `mirai:"optional,label=The change to describe; none: the working copy"`,
    description:string,
}

Api_Kai_Change :: struct {change:string}

Api_Kai_Log_Params :: struct {
    limit:int `mirai:"optional,min=1,max=4096,label=Changes listed, newest first"`,
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
Api_Kai_Log :: struct {changes:[]Api_Kai_Log_Row}

Api_Kai_Undone :: struct {undone:string `mirai:"label=The operation taken back"`}

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
    set:string `mirai:"optional,label=A bookmark to point at change"`,
    change:string `mirai:"optional,label=With set: the change; none: the working copy"`,
    remove:string `mirai:"optional,label=A bookmark to remove"`,
}
Api_Kai_Bookmark :: struct {
    name:string,
    change:string `mirai:"label=Empty while two operations moved it apart"`,
}
Api_Kai_Bookmarks :: struct {bookmarks:[]Api_Kai_Bookmark}

@(private)
kai_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="kai.status",summary="The working copy as the Kai tab shows it, snapshot first: its change, what it changed, the files in conflict and the newest operation.",result=type_info_of(Api_Kai_Status),run=api_kai_status})
    api_register(s,st,{name="kai.snapshot",summary="Records the files of the project as they are now as the working copy, with the editors and agent turns that changed them since.",result=type_info_of(Api_Kai_Snapshot),run=api_kai_snapshot})
    api_register(s,st,{name="kai.new",summary="Starts a new change as the working copy, on the working copy or on given changes, whose trees merge; what does not merge is a conflict in its files that never blocks.",params=type_info_of(Api_Kai_New_Params),result=type_info_of(Api_Kai_Change),run=api_kai_new})
    api_register(s,st,{name="kai.describe",summary="Gives a change its description.",params=type_info_of(Api_Kai_Describe_Params),result=type_info_of(Api_Kai_Change),run=api_kai_describe})
    api_register(s,st,{name="kai.log",summary="The visible changes, newest first, with their bookmarks, conflicts, coauthors and agent turns.",params=type_info_of(Api_Kai_Log_Params),result=type_info_of(Api_Kai_Log),flags={.Read_Only},run=api_kai_log})
    api_register(s,st,{name="kai.undo",summary="Takes back the newest operation of the repository and writes the files as it leaves them; undoing an undo redoes it.",result=type_info_of(Api_Kai_Undone),flags={.Destructive},run=api_kai_undo})
    api_register(s,st,{name="kai.restore",summary="Gives the working copy the files of another change and writes them.",params=type_info_of(Api_Kai_Restore_Params),result=type_info_of(Api_Kai_Done),flags={.Destructive},run=api_kai_restore})
    api_register(s,st,{name="kai.conflicts",summary="The files of the working copy in conflict; an asset with its fields both sides changed apart, ours and theirs.",result=type_info_of(Api_Kai_Conflicts),flags={.Read_Only},run=api_kai_conflicts})
    api_register(s,st,{name="kai.resolve",summary="Resolves a file in conflict: field by field with the conflicts that take theirs, or one side whole. The file is written and recorded.",params=type_info_of(Api_Kai_Resolve_Params),result=type_info_of(Api_Kai_Done),run=api_kai_resolve})
    api_register(s,st,{name="kai.bookmarks",summary="The bookmarks of the repository; sets one at a change or removes one first when asked.",params=type_info_of(Api_Kai_Bookmarks_Params),result=type_info_of(Api_Kai_Bookmarks),run=api_kai_bookmarks})
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
    e:vcs.Error
    if revision,e=ka.revision_find(w,text);e!=.None {
        api.call_failf(call,api.INVALID_PARAMS,"%q names no single visible change: @, @-, a bookmark or a prefix of at least %d digits of a change kai.log lists",text,ka.CHANGE_TEXT_MIN)
        return
    }
    return revision,true
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
    w:=api_kai_workspace(s,call)
    if w==nil {return}
    rows:=make([dynamic]ka.Log_Row,context.temp_allocator)
    if e:=ka.log(w,p.limit>0?p.limit:KAI_LOG_ROWS,&rows,call.allocator);e!=.None {api.call_fail(call,api.SERVER_ERROR,vcs.error_text(e));return}
    r:=api.call_result(call,Api_Kai_Log)
    r.changes=make([]Api_Kai_Log_Row,len(rows),call.allocator)
    for row,i in rows {
        r.changes[i]={
            change=ka.change_text(row.change.id,call.allocator),description=row.change.description,working=row.working,
            bookmarks=row.bookmarks,conflicts=int(row.conflicts),coauthors=len(row.change.coauthors),turns=len(row.change.turns),
        }
    }
}

@(private)
api_kai_undo :: proc(s:^Session,call:^api.Call) {
    if api_kai_workspace(s,call)==nil {return}
    undone,message:=kai_undo(s)
    if !api_kai_ended(call,message) {return}
    api.call_result(call,Api_Kai_Undone).undone=strings.clone(undone,call.allocator)
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
    if p.remove!="" {
        if vcs.view_bookmark(&w.repo.view,p.remove)==nil {
            api.call_failf(call,api.INVALID_PARAMS,"the repository has no bookmark %q: kai.bookmarks lists them",p.remove)
            return
        }
        if !api_kai_ended(call,kai_bookmark(s,p.remove,{})) {return}
    }
    r:=api.call_result(call,Api_Kai_Bookmarks)
    r.bookmarks=make([]Api_Kai_Bookmark,len(w.repo.view.bookmarks),call.allocator)
    for &b,i in w.repo.view.bookmarks {
        r.bookmarks[i].name=strings.clone(b.name,call.allocator)
        if value,resolved:=vcs.terms_resolved(&b.terms);resolved {r.bookmarks[i].change=api_kai_text(w,value,call)}
    }
}
