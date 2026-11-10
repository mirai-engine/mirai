package editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:editor/git"
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
    busy:[16]u8 `mirai:"text,label=The operation that runs (init commit push pull fetch discard abort finish...); empty when none"`,
    error:[512]u8 `mirai:"text,label=What the last operation that failed said"`,
    root:[git.PATH_BYTES]u8 `mirai:"text,label=The work tree"`,
    branch:[96]u8 `mirai:"text"`,
    upstream:bool `mirai:"label=Whether the branch has an upstream; ahead and behind count against it"`,
    ahead,behind:int,
    remote:[git.PATH_BYTES]u8 `mirai:"text,label=The url of origin"`,
    merging:bool `mirai:"label=A pull left conflicts: git.conflicts lists them"`,
    changes:[]Api_Git_Change `mirai:"label=Every file changed under the project"`,
    history:[]Api_Git_Commit `mirai:"label=The last commits"`,
}
Api_Git_Change :: struct {
    path:[git.PATH_BYTES]u8 `mirai:"text,label=From the root of the repository; git.discard takes it"`,
    status:[1]u8 `mirai:"text,label=M changed; A added; D removed; U in conflict"`,
    included:bool `mirai:"label=Whether the next commit takes it"`,
}
Api_Git_Commit :: struct {
    hash:[16]u8 `mirai:"text"`,
    author:[48]u8 `mirai:"text"`,
    age:[32]u8 `mirai:"text,label=How long ago as git says it"`,
    subject:[128]u8 `mirai:"text"`,
}

Api_Git_Conflicts :: struct {
    merging:bool,
    loaded:bool `mirai:"label=Whether the conflicts of the merge were read"`,
    items:[]Api_Git_Item,
}
Api_Git_Item :: struct {
    file:[git.PATH_BYTES]u8 `mirai:"text,label=From the folder of the project; what git.choose and git.accept take as file"`,
    name:[64]u8 `mirai:"text"`,
    entity:base.Entity_Id `mirai:"optional,label=The entity of a scene the item merges"`,
    accepted:bool,
    whole:[8]u8 `mirai:"text,optional,label=Of a file merged whole: the version chosen (ours theirs or folder)"`,
    text:bool `mirai:"optional,label=Of a file merged whole: whether it is text"`,
    conflicts:[]Api_Git_Conflict,
}
Api_Git_Conflict :: struct {
    kind:[8]u8 `mirai:"text,label=value: both changed it; removed: one side removed the row; table: both changed a table"`,
    path:[git.PATH_BYTES]u8 `mirai:"text,label=Where in the asset; what git.choose and git.accept take as path"`,
    component:[64]u8 `mirai:"text,label=The component or the table"`,
    field:[160]u8 `mirai:"text"`,
    ours:serial.Json `mirai:"optional,label=Of a value: ours as JSON"`,
    theirs:serial.Json `mirai:"optional,label=Of a value: theirs as JSON"`,
    ours_has:bool `mirai:"optional,label=Of a row: whether ours has it"`,
    theirs_has:bool `mirai:"optional,label=Of a row: whether theirs has it"`,
    choice:[8]u8 `mirai:"text,label=ours or theirs; theirs until chosen"`,
}

@(private)
git_api_register :: proc(s:^Session,st:^Api_State) {
    init:Api_Git_Init_Params
    commit:Api_Git_Commit_Params
    api_register(s,st,{name="git.status",summary="The repository of the project as the Git tab shows it: branch, remote, changed files, last commits and the operation that runs. Reading it refreshes it.",result=Api_Git_Status,writes_result=true,flags={.Read_Only},run=api_git_status})
    api_register(s,st,{name="git.init",summary="Makes the project a repository whose assets merge entity by entity with Mirai, with Git LFS for heavy binaries when asked.",params=Api_Git_Init_Params,result=Api_Git_Done,defaults=&init,run=api_git_init})
    api_register(s,st,{name="git.commit",summary="Commits the included changes of the project as they are saved and pushes them when asked. Fails with unsaved changes.",params=Api_Git_Commit_Params,result=Api_Git_Done,defaults=&commit,run=api_git_commit})
    api_register(s,st,{name="git.push",summary="Pushes the commits of the branch to origin, setting its upstream the first time.",result=Api_Git_Done,run=api_git_push})
    api_register(s,st,{name="git.pull",summary="Merges origin into the branch, assets entity by entity; what both sides changed leaves a merge with conflicts. Needs every change committed.",result=Api_Git_Done,run=api_git_pull})
    api_register(s,st,{name="git.conflicts",summary="The items of a merge that waits (an entity of a scene or a whole file) with their conflicts. Every conflict takes theirs until chosen.",result=Api_Git_Conflicts,writes_result=true,flags={.Read_Only},run=api_git_conflicts})
    api_register(s,st,{name="git.choose",summary="Chooses the side of a conflict or the version of a file merged whole; its item waits to be accepted again.",params=Api_Git_Choose_Params,result=Api_Git_Chosen,run=api_git_choose})
    api_register(s,st,{name="git.accept",summary="Accepts an item as chosen, or every item; with reject, keeps ours for its conflicts.",params=Api_Git_Accept_Params,result=Api_Git_Accept_Result,run=api_git_accept})
    api_register(s,st,{name="git.finish",summary="Once every item is accepted: writes each file as chosen and commits the merge.",result=Api_Git_Done,run=api_git_finish})
    api_register(s,st,{name="git.discard",summary="Puts a changed file, or every change, back as the last commit has it; an untracked file goes to the trash. Refused with unsaved work or in a merge.",params=Api_Git_Discard_Params,result=Api_Git_Done,flags={.Destructive},run=api_git_discard})
    api_register(s,st,{name="git.abort",summary="Leaves a merge with conflicts: the files go back to the commit before the pull.",result=Api_Git_Done,flags={.Destructive},run=api_git_abort})
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
    out:=call.out
    serial.write_u8(out,'{')
    api.write_bool(out,"available",g.available,true)
    api.write_bool(out,"checked",g.checked)
    api.write_bool(out,"repository",g.repository)
    operations:=[git.Operation]string{.None="",.Check="check",.Refresh="refresh",.Init="init",.Commit="commit",.Commit_Push="commit",.Push="push",.Pull="pull",.Abort="abort",.Finish="finish",.Load="load",.Fetch="fetch",.Discard="discard"}
    api.write_text(out,"busy",operations[g.operation])
    api.write_text(out,"error",base.text_get(g.error[:]))
    api.write_text(out,"root",base.text_get(g.root[:]))
    api.write_text(out,"branch",base.text_get(g.branch[:]))
    api.write_bool(out,"upstream",g.upstream)
    api.write_int(out,"ahead",i64(g.ahead))
    api.write_int(out,"behind",i64(g.behind))
    api.write_text(out,"remote",base.text_get(g.remote[:]))
    api.write_bool(out,"merging",g.merging)
    api.write_key(out,"changes")
    serial.write_u8(out,'[')
    for &change,i in g.changes {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_text(out,"path",git.change_path(g,&change),true)
        status:=[1]u8{change.status}
        api.write_text(out,"status",string(status[:]))
        api.write_bool(out,"included",!change.left_out)
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]")
    api.write_key(out,"history")
    serial.write_u8(out,'[')
    for &commit,i in g.history {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_text(out,"hash",base.text_get(commit.hash[:]),true)
        api.write_text(out,"author",base.text_get(commit.author[:]))
        api.write_text(out,"age",base.text_get(commit.age[:]))
        api.write_text(out,"subject",base.text_get(commit.subject[:]))
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]}")
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
api_git_push :: proc(s:^Session,call:^api.Call) {api_git_ended(s,call,git.push(s.git,s.app.platform,git_roots(s)))}
@(private)
api_git_pull :: proc(s:^Session,call:^api.Call) {api_git_ended(s,call,git_pull(s))}
@(private)
api_git_abort :: proc(s:^Session,call:^api.Call) {api_git_ended(s,call,git.abort(s.git,s.app.platform,git_roots(s)))}

Api_Git_Discard_Params :: struct {
    path:[git.PATH_BYTES]u8 `mirai:"text,optional,label=The file to put back from the root of the repository as git.status lists it; every change without it"`,
}

@(private)
api_git_discard :: proc(s:^Session,call:^api.Call) {
    path:=base.text_get(api.call_params(call,Api_Git_Discard_Params).path[:])
    paths:=[1]string{path}
    api_git_ended(s,call,git_discard(s,path!=""?paths[:]:nil))
}

@(private)
api_git_conflicts :: proc(s:^Session,call:^api.Call) {
    g:=s.git
    m:=&g.merge
    out:=call.out
    serial.write_u8(out,'{')
    api.write_bool(out,"merging",g.merging,true)
    api.write_bool(out,"loaded",m.loaded)
    api.write_key(out,"items")
    serial.write_u8(out,'[')
    for &item,i in m.items {
        if i>0 {serial.write_u8(out,',')}
        file:=&m.files[item.file]
        serial.write_u8(out,'{')
        api.write_text(out,"file",strings.trim_prefix(base.text_get(file.path[:]),base.text_get(g.prefix[:])),true)
        api.write_text(out,"name",base.text_get(item.name[:]))
        if item.key!=0 {api.write_text(out,"entity",fmt.tprintf("0x%016x",u64(item.key)))}
        api.write_bool(out,"accepted",item.accepted)
        if file.merged==nil {
            wholes:=[Git_Whole]string{.Theirs="theirs",.Ours="ours",.Folder="folder"}
            api.write_text(out,"whole",wholes[file.whole])
            api.write_bool(out,"text",file.text)
        }
        api.write_key(out,"conflicts")
        serial.write_u8(out,'[')
        for &conflict,c in m.conflicts[item.first:][:item.count] {
            if c>0 {serial.write_u8(out,',')}
            kinds:=[asset.Merge_Kind]string{.Value="value",.Removed="removed",.Table="table"}
            serial.write_u8(out,'{')
            api.write_text(out,"kind",kinds[conflict.kind],true)
            api.write_text(out,"path",base.text_get(conflict.path[:]))
            api.write_text(out,"component",base.text_get(conflict.table[:]))
            api.write_text(out,"field",base.text_get(conflict.field[:]))
            if conflict.kind==.Value {
                api.write_key(out,"ours");serial.text_write_raw(out,base.text_get(conflict.ours[:]))
                api.write_key(out,"theirs");serial.text_write_raw(out,base.text_get(conflict.theirs[:]))
            } else {
                api.write_bool(out,"ours_has",conflict.ours_has)
                api.write_bool(out,"theirs_has",conflict.theirs_has)
            }
            api.write_text(out,"choice",conflict.take_ours?"ours":"theirs")
            serial.write_u8(out,'}')
        }
        serial.text_write_raw(out,"]}")
    }
    serial.text_write_raw(out,"]}")
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
