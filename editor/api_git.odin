package editor

import "core:strings"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:editor/git"
import "mirai:editor/history"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"

// returns: git.status says while it runs ("busy") and what it left.

Api_Git_Init_Params :: struct {
    remote:[git.PATH_BYTES]u8 `mirai:"text,optional,label=The url of the remote origin; empty for none"`,
    lfs:bool `mirai:"optional,label=Keep textures and meshes and sounds and their sources in Git LFS"`,
}

Api_Git_Commit_Params :: struct {
    message:[git.MESSAGE_BYTES]u8 `mirai:"text,label=The message of the commit"`,
    push:bool `mirai:"optional,label=Push the commit after"`,
}

Api_Git_Choose_Params :: struct {
    file:[git.PATH_BYTES]u8 `mirai:"text,label=The file as git.conflicts lists it"`,
    path:[git.PATH_BYTES]u8 `mirai:"text,optional,label=A conflict of a value or a row of the file by its path in git.conflicts; a file merged whole takes none"`,
    choice:[16]u8 `mirai:"text,label=ours or theirs; for a file merged whole also folder: as it is in the work tree"`,
}

Api_Git_Accept_Params :: struct {
    file:[git.PATH_BYTES]u8 `mirai:"text,optional,label=The file whose items to accept as git.conflicts lists it; omitted: every item"`,
    path:[git.PATH_BYTES]u8 `mirai:"text,optional,label=With file: only the item that has the conflict of this path"`,
    reject:bool `mirai:"optional,label=Keep ours for every conflict of the item instead"`,
}

API_GIT_SECONDS :: 600

Api_Git_Done :: struct {ok:bool}
Api_Git_Chosen :: struct {chosen:bool}
Api_Git_Accept_Result :: struct {left:int `mirai:"label=Items that still wait to be accepted"`}

Api_Git_Status :: struct {
    available:bool `mirai:"label=Whether git was found"`,
    checked:bool `mirai:"label=Whether the repository was read once"`,
    repository:bool `mirai:"label=Whether the project is in a repository"`,
    busy:string `mirai:"label=The operation that runs (init commit push pull fetch discard abort finish...); empty when none"`,
    error:string `mirai:"label=What the last operation that failed said"`,
    root:string `mirai:"label=The work tree"`,
    branch:string,
    upstream:bool `mirai:"label=Whether the branch has an upstream; ahead and behind count against it"`,
    ahead,behind:int,
    remote:string `mirai:"label=The url of origin"`,
    merging:bool `mirai:"label=A pull left conflicts: git.conflicts lists them"`,
    changes:[]Api_Git_Change `mirai:"label=Every file changed under the project"`,
    history:[]Api_Git_Commit `mirai:"label=The last commits"`,
}
Api_Git_Change :: struct {
    path:string `mirai:"label=From the root of the repository; git.keep, git.unkeep and git.discard take it"`,
    status:string `mirai:"label=M changed; A added; D removed; U in conflict"`,
    pending:bool `mirai:"label=Whether the file has what is not kept yet: git.keep keeps it and git.discard puts back what is kept"`,
    kept:bool `mirai:"label=Whether the next commit takes it as it was kept"`,
}
Api_Git_Commit :: struct {
    hash:string,
    author:string,
    age:string `mirai:"label=How long ago as git says it"`,
    subject:string,
}

Api_Git_Conflicts :: struct {
    merging:bool,
    loaded:bool `mirai:"label=Whether the conflicts of the merge were read"`,
    items:[]Api_Git_Item,
}
Api_Git_Item :: struct {
    file:string `mirai:"label=From the folder of the project; what git.choose and git.accept take as file"`,
    name:string,
    entity:base.Entity_Id `mirai:"optional,label=The entity of a scene the item merges"`,
    accepted:bool,
    whole:string `mirai:"optional,label=Of a file merged whole: the version chosen (ours theirs or folder)"`,
    text:bool `mirai:"optional,label=Of a file merged whole: whether it is text"`,
    conflicts:[]Api_Git_Conflict,
}
Api_Git_Conflict :: struct {
    kind:string `mirai:"label=value: both changed it; removed: one side removed the row; table: both changed a table"`,
    path:string `mirai:"label=Where in the asset; what git.choose and git.accept take as path"`,
    component:string `mirai:"label=The component or the table"`,
    field:string,
    ours:serial.Json `mirai:"optional,label=Of a value: ours as JSON"`,
    theirs:serial.Json `mirai:"optional,label=Of a value: theirs as JSON"`,
    ours_has:bool `mirai:"optional,label=Of a row: whether ours has it"`,
    theirs_has:bool `mirai:"optional,label=Of a row: whether theirs has it"`,
    choice:string `mirai:"label=ours or theirs; theirs until chosen"`,
}

@(private)
git_api_register :: proc(s:^Session,st:^Api_State) {
    init:Api_Git_Init_Params
    commit:Api_Git_Commit_Params
    api_register(s,st,{name="git.status",summary="The repository of the project as the Git tab shows it: branch, remote, changed files, last commits and the operation that runs. Reading it refreshes it.",result=type_info_of(Api_Git_Status),flags={.Read_Only},run=api_git_status})
    api_register(s,st,{name="git.init",summary="Makes the project a repository whose assets merge entity by entity with Mirai, with Git LFS for heavy binaries when asked.",params=type_info_of(Api_Git_Init_Params),result=type_info_of(Api_Git_Done),defaults=&init,run=api_git_init})
    api_register(s,st,{name="git.commit",summary="Commits what is kept of the project, or every change when nothing is kept, and pushes when asked.",params=type_info_of(Api_Git_Commit_Params),result=type_info_of(Api_Git_Done),defaults=&commit,run=api_git_commit})
    api_register(s,st,{name="git.push",summary="Pushes the commits of the branch to origin, setting its upstream the first time.",result=type_info_of(Api_Git_Done),run=api_git_push})
    api_register(s,st,{name="git.pull",summary="Merges origin into the branch, assets entity by entity; what both sides changed leaves a merge with conflicts. Needs every change committed.",result=type_info_of(Api_Git_Done),run=api_git_pull})
    api_register(s,st,{name="git.conflicts",summary="The items of a merge that waits (an entity of a scene or a whole file) with their conflicts. Every conflict takes theirs until chosen.",result=type_info_of(Api_Git_Conflicts),flags={.Read_Only},run=api_git_conflicts})
    api_register(s,st,{name="git.choose",summary="Chooses the side of a conflict or the version of a file merged whole; its item waits to be accepted again.",params=type_info_of(Api_Git_Choose_Params),result=type_info_of(Api_Git_Chosen),run=api_git_choose})
    api_register(s,st,{name="git.accept",summary="Accepts an item as chosen, or every item; with reject, keeps ours for its conflicts.",params=type_info_of(Api_Git_Accept_Params),result=type_info_of(Api_Git_Accept_Result),run=api_git_accept})
    api_register(s,st,{name="git.finish",summary="Once every item is accepted: writes each file as chosen and commits the merge.",result=type_info_of(Api_Git_Done),run=api_git_finish})
    api_register(s,st,{name="git.changes",summary="The entities of a scene that differ from what git keeps of it, by their ids: added, changed and removed, as a tree with those they hang from. The document in front is compared as it is now; another scene, as its file is.",params=type_info_of(Api_Git_Changes_Params),result=type_info_of(Api_Git_Changes),flags={.Read_Only},run=api_git_changes})
    api_register(s,st,{name="git.revert",summary="Puts entities of the document in front back as git keeps them, with what hangs from them unless subtree is false: one step of history. With author, takes back instead what the steps of that author did to them, keeping what others wrote since.",params=type_info_of(Api_Git_Revert_Params),result=type_info_of(Api_Git_Reverted),flags={.Destructive},run=api_git_revert})
    api_register(s,st,{name="git.keep",summary="Keeps the changes of some files, or of every one: the next commit takes them as they are now, and what changes after is pending again.",params=type_info_of(Api_Git_Paths_Params),result=type_info_of(Api_Git_Done),run=api_git_keep})
    api_register(s,st,{name="git.unkeep",summary="Takes the changes of some files, or of every one, out of what is kept: they are pending again, and the files stay as they are.",params=type_info_of(Api_Git_Paths_Params),result=type_info_of(Api_Git_Done),run=api_git_unkeep})
    api_register(s,st,{name="git.discard",summary="Puts some pending files, or every one, back as they were kept (as the last commit has them when nothing of them was kept); a file git does not track goes to the trash. Refused in a merge.",params=type_info_of(Api_Git_Paths_Params),result=type_info_of(Api_Git_Done),flags={.Destructive},run=api_git_discard})
    api_register(s,st,{name="git.abort",summary="Leaves a merge with conflicts: the files go back to the commit before the pull.",result=type_info_of(Api_Git_Done),flags={.Destructive},run=api_git_abort})
}

@(private)
api_git_ended :: proc(s:^Session,call:^api.Call,message:string) {
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    running :: proc(s:^Session,user:rawptr) -> bool {return git.busy(s.git)}
    if !api_wait(s,API_GIT_SECONDS,nil,running,"git") {
        api.call_failf(call,api.SERVER_ERROR,"git still runs after %d s; git.status says when it ends",API_GIT_SECONDS)
        return
    }
    if text:=base.text_get(s.git.error[:]);text!="" {api.call_fail(call,api.SERVER_ERROR,text);return}
    api.call_result(call,Api_Git_Done).ok=true
}

@(private)
api_git_status :: proc(s:^Session,call:^api.Call) {
    g:=s.git
    if !git.busy(g) && (!g.checked || platform.clock_seconds()-g.refreshed>1) {git_refresh(s)}
    operations:=[git.Operation]string{.None="",.Check="check",.Refresh="refresh",.Init="init",.Commit="commit",.Commit_Push="commit",.Push="push",.Pull="pull",.Abort="abort",.Finish="finish",.Load="load",.Fetch="fetch",.Keep="keep",.Unkeep="unkeep",.Discard="discard",.Base="base"}
    r:=api.call_result(call,Api_Git_Status)
    r^={
        available=g.available,checked=g.checked,repository=g.repository,busy=operations[g.operation],
        error=base.text_get(g.error[:]),root=base.text_get(g.root[:]),branch=base.text_get(g.branch[:]),
        upstream=g.upstream,ahead=g.ahead,behind=g.behind,remote=base.text_get(g.remote[:]),merging=g.merging,
        changes=make([]Api_Git_Change,len(g.changes),call.allocator),history=make([]Api_Git_Commit,len(g.history),call.allocator),
    }
    for &change,i in g.changes {
        r.changes[i]={git.change_path(g,&change),strings.clone_from_bytes({change.status},call.allocator),change.pending,change.kept}
    }
    for &commit,i in g.history {
        r.history[i]={base.text_get(commit.hash[:]),base.text_get(commit.author[:]),base.text_get(commit.age[:]),base.text_get(commit.subject[:])}
    }
}

@(private)
api_git_init :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Git_Init_Params)
    g:=s.git
    base.text_set(g.remote_field[:],base.text_get(p.remote[:]))
    g.remote_length=len(base.text_get(g.remote_field[:]))
    g.lfs=p.lfs
    api_git_ended(s,call,git_init(s))
}

@(private)
api_git_commit :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Git_Commit_Params)
    g:=s.git
    base.text_set(g.message[:],base.text_get(p.message[:]))
    g.message_length=len(base.text_get(g.message[:]))
    api_git_ended(s,call,git_commit(s,p.push))
}

@(private)
api_git_push :: proc(s:^Session,call:^api.Call) {api_git_ended(s,call,git.push(s.git,git_roots(s)))}
@(private)
api_git_pull :: proc(s:^Session,call:^api.Call) {api_git_ended(s,call,git_pull(s))}
@(private)
api_git_abort :: proc(s:^Session,call:^api.Call) {api_git_ended(s,call,git.abort(s.git,git_roots(s)))}

Api_Git_Changes_Params :: struct {
    path:string `mirai:"optional,label=A scene from the root of the repository as git.status lists it; none: the document in front"`,
}
Api_Git_Entity :: struct {
    id:base.Entity_Id,
    name:string,
    parent:base.Entity_Id `mirai:"label=The entity it hangs from; 0 for none"`,
    change:Git_Entity_Change `mirai:"label=Against what git keeps of the scene; Same: listed because something that hangs from it differs"`,
    components:string `mirai:"optional,label=Of one that changed: what of it differs, by the names of its components"`,
}
Api_Git_Changes :: struct {
    path:string `mirai:"label=The scene, from the root of the repository"`,
    entities:[]Api_Git_Entity `mirai:"label=The entities that differ and those they hang from, in the order of the tree"`,
}
Api_Git_Revert_Params :: struct {
    path:string `mirai:"optional,label=The scene, which must be the document in front; none: that document"`,
    entities:[]string `mirai:"label=Ids of entities as git.changes gives them"`,
    subtree:bool `mirai:"optional,label=With what hangs from them, as git keeps it and as the scene has it now"`,
    author:string `mirai:"optional,label=Takes back only what the steps of one author did to those entities, from the history of this session: user, api, or the name of the task of an agent; none: back to what git keeps"`,
}
Api_Git_Reverted :: struct {
    reverted:int `mirai:"label=Entities put back as git keeps them; with author, rows of its steps gone through"`,
    kept:int `mirai:"label=With author: fields, components and entities that stayed as others left them"`,
}

Api_Git_Paths_Params :: struct {
    paths:[]string `mirai:"optional,label=Files from the root of the repository as git.status lists them; none: every change under the project"`,
}

// The tree of a scene against what git keeps of it, read for this call when
// it is not the one shown. False, with the call failed, when it could not be.
@(private)
api_git_entities :: proc(s:^Session,call:^api.Call,path:string) -> bool {
    g:=s.git
    path:=path
    if path=="" {path=git_path(s,document_file(s.document))}
    if path=="" {api.call_fail(call,api.INVALID_PARAMS,"The document in front has no file in the repository: pass path");return false}
    if base.text_get(g.entities.path[:])==path && g.entities.read {
        git_entities_update(s)
        return true
    }
    files_flush(s,true)
    if message:=git_entities_show(s,path);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return false}
    running :: proc(s:^Session,user:rawptr) -> bool {return git.busy(s.git) || s.git.entities.reading}
    if !api_wait(s,API_GIT_SECONDS,nil,running,"git") || !g.entities.read {
        api.call_failf(call,api.SERVER_ERROR,"What git keeps of %s could not be read",path)
        return false
    }
    return true
}

@(private)
api_git_changes :: proc(s:^Session,call:^api.Call) {
    if !api_git_entities(s,call,api.call_params(call,Api_Git_Changes_Params).path) {return}
    n:=&s.git.entities
    r:=api.call_result(call,Api_Git_Changes)
    r.path=strings.clone(base.text_get(n.path[:]),call.allocator)
    r.entities=make([]Api_Git_Entity,len(n.rows),call.allocator)
    for &row,i in n.rows {
        r.entities[i]={row.id,strings.clone(base.text_get(row.name[:]),call.allocator),row.parent,row.change,strings.clone(base.text_get(row.components[:]),call.allocator)}
    }
}

@(private)
api_git_revert :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Git_Revert_Params)
    ids:=make([dynamic]base.Entity_Id,context.temp_allocator)
    for text in p.entities {
        id,parsed:=base.entity_id_parse(strings.trim_prefix(strings.trim_space(text),"0x"))
        if !parsed || id==0 {api.call_failf(call,api.INVALID_PARAMS,"%q is not the id of an entity: git.changes gives them",text);return}
        append(&ids,id)
    }
    if len(ids)==0 {api.call_fail(call,api.INVALID_PARAMS,"entities names none: git.changes lists the ids of those that differ");return}
    r:=api.call_result(call,Api_Git_Reverted)
    message:string
    if p.author!="" {
        author:history.Edit_Author
        switch p.author {
        case "user": author=history.EDIT_AUTHOR_USER
        case "api":  author=history.EDIT_AUTHOR_API
        case:
            task:=ai_task_named(s.ai,p.author)
            if task==nil {api.call_failf(call,api.INVALID_PARAMS,"author %q is not user, api or the name of a task of an agent",p.author);return}
            author=history.Edit_Author(task.id)
        }
        r.reverted,r.kept,message=history_revert_author(s,author,ids[:],"Revert")
    } else {
        if !api_git_entities(s,call,p.path) {return}
        subtree:=p.subtree || !api.call_given(call,"subtree")
        r.reverted,message=git_entities_revert(s,ids[:],subtree)
    }
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message)}
}

@(private)
api_git_keep :: proc(s:^Session,call:^api.Call) {api_git_ended(s,call,git_changes_run(s,.Keep,api.call_params(call,Api_Git_Paths_Params).paths))}
@(private)
api_git_unkeep :: proc(s:^Session,call:^api.Call) {api_git_ended(s,call,git_changes_run(s,.Unkeep,api.call_params(call,Api_Git_Paths_Params).paths))}
@(private)
api_git_discard :: proc(s:^Session,call:^api.Call) {api_git_ended(s,call,git_changes_run(s,.Discard,api.call_params(call,Api_Git_Paths_Params).paths))}

@(private)
api_git_conflicts :: proc(s:^Session,call:^api.Call) {
    g:=s.git
    m:=&g.merge
    r:=api.call_result(call,Api_Git_Conflicts)
    r.merging,r.loaded=g.merging,m.loaded
    r.items=make([]Api_Git_Item,len(m.items),call.allocator)
    wholes:=[Git_Whole]string{.Theirs="theirs",.Ours="ours",.Folder="folder"}
    kinds:=[asset.Merge_Kind]string{.Value="value",.Removed="removed",.Table="table"}
    for &item,i in m.items {
        file:=&m.files[item.file]
        out:=&r.items[i]
        out^={file=strings.trim_prefix(base.text_get(file.path[:]),base.text_get(g.prefix[:])),name=base.text_get(item.name[:]),entity=base.Entity_Id(item.key),accepted=item.accepted}
        if file.merged==nil {out.whole,out.text=wholes[file.whole],file.text}
        out.conflicts=make([]Api_Git_Conflict,item.count,call.allocator)
        for &conflict,c in m.conflicts[item.first:][:item.count] {
            row:=&out.conflicts[c]
            row^={kind=kinds[conflict.kind],path=base.text_get(conflict.path[:]),component=base.text_get(conflict.table[:]),field=base.text_get(conflict.field[:]),choice=conflict.take_ours?"ours":"theirs"}
            if conflict.kind==.Value {
                row.ours,row.theirs=serial.Json(base.text_get(conflict.ours[:])),serial.Json(base.text_get(conflict.theirs[:]))
            } else {
                row.ours_has,row.theirs_has=conflict.ours_has,conflict.theirs_has
            }
        }
    }
}

@(private)
api_git_merge_ready :: proc(s:^Session,call:^api.Call) -> bool {
    g:=s.git
    if !g.merging || !g.merge.loaded {api.call_fail(call,api.SERVER_ERROR,"No merge waits for its conflicts");return false}
    return true
}

@(private)
api_git_choose :: proc(s:^Session,call:^api.Call) {
    if !api_git_merge_ready(s,call) {return}
    p:=api.call_params(call,Api_Git_Choose_Params)
    g:=s.git
    choice:=base.text_get(p.choice[:])
    name,at_path:=base.text_get(p.file[:]),base.text_get(p.path[:])
    if !api_git_file_merging(g,name) {api.call_failf(call,api.INVALID_PARAMS,"%q is not a file of the merge; git.conflicts lists them",name);return}
    if at_path!="" {
        conflict:=api_git_conflict_at(g,name,at_path)
        if conflict<0 {api.call_failf(call,api.INVALID_PARAMS,"%s has no conflict at %q; git.conflicts lists them",name,at_path);return}
        if choice!="ours" && choice!="theirs" {api.call_fail(call,api.INVALID_PARAMS,"choice is ours or theirs for a conflict");return}
        git_conflict_choose(s,conflict,choice=="ours")
    } else {
        item:=api_git_item_of(g,name)
        file:=&g.merge.files[item.file]
        if file.merged!=nil {api.call_failf(call,api.INVALID_PARAMS,"%s merges entity by entity: give the path of a conflict of it",name);return}
        switch choice {
        case "ours": file.whole=.Ours
        case "theirs": file.whole=.Theirs
        case "folder": file.whole=.Folder
        case: api.call_fail(call,api.INVALID_PARAMS,"choice is ours, theirs or folder for a file merged whole");return
        }
        item.accepted=false
    }
    api.call_result(call,Api_Git_Chosen).chosen=true
}

@(private)
api_git_accept :: proc(s:^Session,call:^api.Call) {
    if !api_git_merge_ready(s,call) {return}
    p:=api.call_params(call,Api_Git_Accept_Params)
    g:=s.git
    name,at_path:=base.text_get(p.file[:]),base.text_get(p.path[:])
    if name=="" {
        if at_path!="" {api.call_fail(call,api.INVALID_PARAMS,"path is of a conflict of a file: give file too");return}
        git_merge_settle_all(s,p.reject)
    } else {
        if !api_git_file_merging(g,name) {api.call_failf(call,api.INVALID_PARAMS,"%q is not a file of the merge; git.conflicts lists them",name);return}
        conflict:=-1
        if at_path!="" {
            if conflict=api_git_conflict_at(g,name,at_path);conflict<0 {api.call_failf(call,api.INVALID_PARAMS,"%s has no conflict at %q; git.conflicts lists them",name,at_path);return}
        }
        for &item,index in g.merge.items {
            if !git_file_named(g,&g.merge.files[item.file],name) {continue}
            if conflict>=0 && (conflict<item.first || conflict>=item.first+item.count) {continue}
            git_merge_settle(s,index,p.reject)
        }
    }
    r:=api.call_result(call,Api_Git_Accept_Result)
    for item in g.merge.items {if !item.accepted {r.left+=1}}
}

// Whether a file of a merge is the one a call names: from the folder of the
// project, as git.conflicts lists it, or from the root of the repository.
@(private)
git_file_named :: proc(g:^Git,f:^Git_Merge_File,name:string) -> bool {
    path:=base.text_get(f.path[:])
    return path==name || strings.trim_prefix(path,base.text_get(g.prefix[:]))==name
}

@(private)
api_git_file_merging :: proc(g:^Git,name:string) -> bool {
    if name=="" {return false}
    for &file in g.merge.files {
        if git_file_named(g,&file,name) {return true}
    }
    return false
}

// The first item of the file a call names.
@(private)
api_git_item_of :: proc(g:^Git,name:string) -> ^Git_Merge_Item {
    for &item in g.merge.items {
        if git_file_named(g,&g.merge.files[item.file],name) {return &item}
    }
    return nil
}

// The index of the conflict of a file at a path, or -1.
@(private)
api_git_conflict_at :: proc(g:^Git,name,at_path:string) -> int {
    for &item in g.merge.items {
        if !git_file_named(g,&g.merge.files[item.file],name) {continue}
        for &conflict,at in g.merge.conflicts[item.first:][:item.count] {
            if base.text_get(conflict.path[:])==at_path {return item.first+at}
        }
    }
    return -1
}

@(private)
api_git_finish :: proc(s:^Session,call:^api.Call) {api_git_ended(s,call,git_merge_finish(s))}
