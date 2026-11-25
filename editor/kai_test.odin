package editor

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:cook/cache"
import ka "mirai:cook/kai"
import "mirai:core"
import "mirai:editor/api"
import vcs "mirai:kai"
import "mirai:std/base"
import "mirai:store"
import "mirai:ui"

@(private="file") Kai_Transform :: struct {position:[3]f32,rotation:quaternion128,scale:[3]f32}
@(private="file") Kai_Light :: struct {color:[3]f32,intensity:f32,range:f32}
@(private="file") KAI_ROOT :: base.Entity_Id(0x10)
@(private="file") KAI_LAMP :: base.Entity_Id(0x20)

// An editor on a project with a store and the storages of Kai.
@(private="file")
Kai_Fixture :: struct {
    using f:Prefab_Fixture,
    kai:Kai,
    authorship:Kai_Authorship,
}

@(private="file")
kai_fixture_init :: proc(t:^testing.T,k:^Kai_Fixture,name:string) -> bool {
    if !prefab_fixture_init(t,&k.f,name) {return false}
    k.s.project_root,k.s.has_project=k.root,true
    opened,error:=store.open(base.test_folder(t,fmt.tprintf("%s-store",name)))
    if !testing.expect_value(t,error,store.Error.None) {return false}
    k.s.store=opened
    k.s.kai,k.s.kai_authorship=&k.kai,&k.authorship
    return true
}

@(private="file")
kai_fixture_destroy :: proc(k:^Kai_Fixture) {
    kai_close(&k.s)
    delete(k.authorship.items)
    delete(k.authorship.waiting)
    store.close(&k.s.store)
    prefab_fixture_destroy(&k.f)
}

// The scene with a lamp at x and of intensity.
@(private="file")
kai_scene :: proc(t:^testing.T,types:^asset.Types,x,intensity:f32) -> []u8 {
    scene:asset.Scene
    testing.expect_value(t,asset.scene_init(&scene,types,{0x61,0x62}),asset.Error.None)
    defer asset.scene_destroy(&scene)
    asset.scene_entity_add(&scene,KAI_ROOT,0,"Root")
    asset.scene_entity_add(&scene,KAI_LAMP,KAI_ROOT,"Lamp")
    root:=Kai_Transform{rotation=1,scale={1,1,1}}
    asset.scene_set(&scene,KAI_ROOT,"Transform",&root)
    lamp:=Kai_Transform{position={x,0,0},rotation=1,scale={1,1,1}}
    asset.scene_set(&scene,KAI_LAMP,"Transform",&lamp)
    light:=Kai_Light{{1,1,1},intensity,10}
    asset.scene_set(&scene,KAI_LAMP,"Light",&light)
    bytes,e:=asset.scene_bytes(&scene,context.temp_allocator)
    testing.expect_value(t,e,asset.Error.None)
    return bytes
}

// The lamp of the scene file: where it is and how bright.
@(private="file")
kai_lamp :: proc(t:^testing.T,types:^asset.Types,file:string) -> (x,intensity:f32) {
    bytes,read_error:=os.read_entire_file(file,context.temp_allocator)
    if !testing.expect(t,read_error==nil,"the scene is there") {return}
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_read(&scene,types,bytes),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    transform,_:=asset.scene_get(&scene,KAI_LAMP,"Transform",Kai_Transform)
    light,_:=asset.scene_get(&scene,KAI_LAMP,"Light",Kai_Light)
    return transform.position.x,light.intensity
}

@(private="file")
kai_write :: proc(t:^testing.T,s:^Session,file:string,bytes:[]u8) {
    testing.expect(t,os.write_entire_file(file,bytes)==nil)
    kai_touched(s,file)
    testing.expect_value(t,kai_snapshot(s),"")
}

// The editor snapshots what it wrote, shows what a change did, starts changes
// on others whose trees merge, leaves what does not merge as a conflict that
// blocks nothing and resolves it field by field; undo takes the resolution
// back and undoing the undo redoes it.
@(test)
editor_kai_snapshot_diff_conflict_and_undo :: proc(t:^testing.T) {
    k:=new(Kai_Fixture);defer free(k)
    if !kai_fixture_init(t,k,"kai-editor") {return}
    defer kai_fixture_destroy(k)
    s:=&k.s
    types:=&k.assets.types
    file:=fmt.tprintf("%s/level.scene",k.root)
    testing.expect(t,os.write_entire_file(file,kai_scene(t,types,0,3))==nil)

    // A run that ends after a count of frames records no history.
    s.frames=1
    kai_open(s)
    testing.expect(t,kai_workspace(s)==nil && !ka.project_exists(k.root),"a bounded run makes no workspace")
    s.frames=0

    // The project becomes a workspace: its files are the first change.
    testing.expect_value(t,kai_enable(s),"")
    w:=kai_workspace(s)
    if !testing.expectf(t,w!=nil,"the workspace opens: %v",s.kai.error) {return}
    testing.expect(t,ka.project_exists(k.root))
    origin:=vcs.repo_working(&w.repo)
    testing.expect_value(t,kai_describe(s,origin,"origin"),"")
    origin=vcs.repo_working(&w.repo)

    // Ours: the lamp moves. The change shows the scene changed.
    testing.expect_value(t,kai_new(s,nil,""),"")
    kai_write(t,s,file,kai_scene(t,types,5,3))
    v:=&s.kai.state.view
    testing.expectf(t,len(v.files)==1 && v.files[0].path=="level.scene" && v.files[0].mark=='M',"%v",v.files)
    testing.expect_value(t,kai_describe(s,vcs.repo_working(&w.repo),"move the lamp"),"")
    ours:=vcs.repo_working(&w.repo)

    // What the change did to the scene: the lamp's transform changed, by field.
    moved:=Api_Kai_Log_Params{file="level.scene"}
    call,logged:=kai_call(s,api_kai_log,&moved,Api_Kai_Log)
    if !testing.expectf(t,!call.failed,"%s",call.error.message) {return}
    lamp_row:=false
    for row in logged.detail.rows {lamp_row||=row.mark=="~" && row.entity==u64(KAI_LAMP) && row.name=="Lamp" && strings.contains(row.text,"Transform")}
    testing.expectf(t,logged.detail.kind=="asset" && logged.detail.status=="M" && lamp_row,"%v",logged.detail)

    // Theirs, on the origin: the files go back to it; the lamp moves elsewhere and brightens.
    parents:=[1]vcs.Revision{origin}
    testing.expect_value(t,kai_new(s,parents[:],"brighten"),"")
    x,intensity:=kai_lamp(t,types,file)
    testing.expect(t,x==0 && intensity==3,"a new change on the origin writes its files")
    kai_write(t,s,file,kai_scene(t,types,9,7))
    theirs:=vcs.repo_working(&w.repo)

    // Both: the light merges, the move is a conflict the file holds with ours.
    both:=[2]vcs.Revision{ours,theirs}
    testing.expect_value(t,kai_new(s,both[:],"merge"),"")
    testing.expect_value(t,len(w.state.conflicts),1)
    testing.expectf(t,len(v.files)>0 && v.files[0].mark=='C',"the change shows the conflict: %v",v.files)
    x,intensity=kai_lamp(t,types,file)
    testing.expect(t,x==5 && intensity==7,"the conflict is written with ours, and what merged")
    kai_unfold(s,"level.scene")
    if !testing.expectf(t,len(v.fields)==1 && v.fields[0].kind==.Value && strings.contains(v.fields[0].path,"Transform"),"%v",v.fields) {return}

    // Theirs for the move: written, recorded, no conflict left.
    picked:=[1]string{strings.clone(v.fields[0].path,context.temp_allocator)}
    testing.expect_value(t,kai_resolve(s,"level.scene",.Fields,picked[:]),"")
    testing.expect_value(t,len(w.state.conflicts),0)
    x,intensity=kai_lamp(t,types,file)
    testing.expect(t,x==9 && intensity==7,"theirs for the move, the light as merged")
    totals,_:=vcs.tree_totals(w.repo.s,s.kai.state.project.workspace.state.tree)
    testing.expect_value(t,totals.conflicts,0)

    // Undo takes the resolution back, and undoing the undo redoes it.
    _,message:=kai_undo(s)
    testing.expect_value(t,message,"")
    testing.expect_value(t,len(w.state.conflicts),1)
    x,_=kai_lamp(t,types,file)
    testing.expect_value(t,x,5)
    testing.expect(t,v.redo,"the newest operation is an undo")
    _,message=kai_undo(s)
    testing.expect_value(t,message,"")
    testing.expect_value(t,len(w.state.conflicts),0)
    x,_=kai_lamp(t,types,file)
    testing.expect_value(t,x,9)

    // A text by its lines with their numbers, a binary or oversized file by
    // its sizes, a huge diff cut with its count.
    notes:=fmt.tprintf("%s/notes.txt",k.root)
    kai_write(t,s,notes,transmute([]u8)string("one\ntwo\nthree\n"))
    testing.expect_value(t,kai_new(s,nil,""),"")
    kai_write(t,s,notes,transmute([]u8)string("one\n2\nthree\nfour\n"))
    kai_write(t,s,fmt.tprintf("%s/blob.bin",k.root),[]u8{0,1,2,0})
    kai_write(t,s,fmt.tprintf("%s/huge.txt",k.root),transmute([]u8)strings.repeat("line\n",ka.DETAIL_ROWS+500,context.temp_allocator))
    kai_write(t,s,fmt.tprintf("%s/large.txt",k.root),make([]u8,ka.DETAIL_BYTES+1,context.temp_allocator))
    detail :: proc(s:^Session,file:string) -> Api_Kai_Detail {
        p:=Api_Kai_Log_Params{file=file,change="@"}
        _,r:=kai_call(s,api_kai_log,&p,Api_Kai_Log)
        return r.detail
    }
    lines:=detail(s,"notes.txt")
    marks:=make([dynamic]string,context.temp_allocator)
    for row in lines.rows {append(&marks,fmt.tprintf("%s%d/%d %s",row.mark,row.old,row.new,row.text))}
    testing.expectf(t,lines.kind=="text" && lines.added==2 && lines.removed==1 && strings.join(marks[:],"|",context.temp_allocator)==" 1/1 one|-2/0 two|+0/2 2| 3/3 three|+0/4 four","%v",marks[:])
    binary:=detail(s,"blob.bin")
    testing.expectf(t,binary.kind=="binary" && binary.status=="A" && binary.before==0 && binary.after==4 && len(binary.rows)==0,"%v",binary)
    large:=detail(s,"large.txt")
    testing.expectf(t,large.kind=="oversized" && large.after==ka.DETAIL_BYTES+1 && len(large.rows)==0,"%v",large)
    huge:=detail(s,"huge.txt")
    testing.expectf(t,len(huge.rows)==ka.DETAIL_ROWS && huge.cut==500 && huge.added==ka.DETAIL_ROWS+500,"%d rows, %d cut",len(huge.rows),huge.cut)
    wrong:=[?]Api_Kai_Log_Params{{change="@"},{file="nowhere.txt"}}
    for &p in wrong {
        call,_=kai_call(s,api_kai_log,&p,Api_Kai_Log)
        testing.expectf(t,call.failed && call.error.code==api.INVALID_PARAMS,"%v %s",p,call.error.message)
    }
}

@(private="file")
kai_call :: proc(s:^Session,run:proc(s:^Session,call:^api.Call),params:^$P,$R:typeid) -> (call:api.Call,result:^R) {
    method:=new(api.Method,context.temp_allocator)
    method^={params_id=P,result_id=R}
    result=new(R,context.temp_allocator)
    call={method=method,params=params,result=result,allocator=context.temp_allocator}
    run(s,&call)
    return
}

// kai_call with the call's allocator given, and a temporary one of its own
// that is overwritten once the call returns: what a result keeps in
// temporary memory reads garbage then.
@(private="file")
kai_call_apart :: proc(s:^Session,run:proc(s:^Session,call:^api.Call),params:^$P,$R:typeid,allocator:mem.Allocator) -> (call:api.Call,result:^R) {
    scratch:=make([]u8,16<<20)
    defer delete(scratch)
    temporary:mem.Arena
    mem.arena_init(&temporary,scratch)
    {
        context.temp_allocator=mem.arena_allocator(&temporary)
        method:=new(api.Method,allocator)
        method^={params_id=P,result_id=R}
        result=new(R,allocator)
        call={method=method,params=params,result=result,allocator=allocator}
        run(s,&call)
    }
    for &b in scratch {b=0xaa}
    return
}

// The paths a change changed, in order, space-separated.
@(private="file")
kai_paths :: proc(w:^vcs.Workspace,revision:vcs.Revision) -> string {
    diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
    ka.diff(w,revision,&diffs)
    names:=make([dynamic]string,context.temp_allocator)
    for d in diffs {append(&names,d.path)}
    return strings.join(names[:]," ",context.temp_allocator)
}

// kai.split closes a change with the files named and leaves the rest in the
// working copy; New change does the same with the files checked in CHANGES,
// kept by path while the list changes under them, and with every file checked
// starts a new change as before.
@(test)
editor_kai_new_change_takes_only_the_checked_files :: proc(t:^testing.T) {
    k:=new(Kai_Fixture);defer free(k)
    if !kai_fixture_init(t,k,"kai-editor-split") {return}
    defer kai_fixture_destroy(k)
    s:=&k.s
    for name in ([]string{"a.txt","b.txt","c.txt"}) {
        testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s",k.root,name),transmute([]u8)string("one"))==nil)
    }
    testing.expect_value(t,kai_enable(s),"")
    w:=kai_workspace(s)
    if !testing.expectf(t,w!=nil,"the workspace opens: %v",s.kai.error) {return}
    st:=s.kai.state
    testing.expect_value(t,kai_new(s,nil,""),"")
    for name in ([]string{"a.txt","b.txt","c.txt"}) {kai_write(t,s,fmt.tprintf("%s/%s",k.root,name),transmute([]u8)string("two"))}

    // kai.split: a.txt closes, b.txt and c.txt stay in the working copy.
    params:=Api_Kai_Split_Params{files={"a.txt"},description="a only"}
    call,split:=kai_call(s,api_kai_split,&params,Api_Kai_Split)
    if !testing.expectf(t,!call.failed,"%s",call.error.message) {return}
    working:=vcs.repo_working(&w.repo)
    c,_:=vcs.change_get(w.repo.s,working,context.temp_allocator)
    closed,_:=vcs.change_get(w.repo.s,c.parents[0],context.temp_allocator)
    testing.expect(t,split.second==ka.change_text(c.id) && split.first==ka.change_text(closed.id) && closed.description=="a only")
    testing.expect_value(t,kai_paths(w,c.parents[0]),"a.txt")
    testing.expect_value(t,kai_paths(w,working),"b.txt c.txt")
    wrong:=Api_Kai_Split_Params{files={"zzz.txt"}}
    call,_=kai_call(s,api_kai_split,&wrong,Api_Kai_Split)
    testing.expectf(t,call.failed && call.error.code==api.INVALID_PARAMS && strings.contains(call.error.message,"zzz.txt"),"%s",call.error.message)

    // c.txt unchecked; a snapshot then lists 0.txt first, and d.txt is only on disk.
    kai_check(st,"c.txt",false)
    kai_write(t,s,fmt.tprintf("%s/0.txt",k.root),transmute([]u8)string("new"))
    v:=&st.view
    testing.expectf(t,len(v.files)==3 && v.files[0].path=="0.txt" && v.files[2].path=="c.txt","%v",v.files)
    testing.expect(t,kai_checked(st,"0.txt") && kai_checked(st,"b.txt") && !kai_checked(st,"c.txt"),"checks stay with their files")
    d:=fmt.tprintf("%s/d.txt",k.root)
    testing.expect(t,os.write_entire_file(d,transmute([]u8)string("disk"))==nil)
    kai_touched(s,d)
    testing.expect_value(t,kai_new_checked(s,"b and new"),"")
    working=vcs.repo_working(&w.repo)
    c,_=vcs.change_get(w.repo.s,working,context.temp_allocator)
    closed,_=vcs.change_get(w.repo.s,c.parents[0],context.temp_allocator)
    testing.expect_value(t,closed.description,"b and new")
    testing.expect_value(t,kai_paths(w,c.parents[0]),"0.txt b.txt d.txt")
    testing.expect_value(t,kai_paths(w,working),"c.txt")
    testing.expect(t,kai_checked(st,"c.txt"),"after New change every file is checked again")

    // Every file checked: a new empty change; none checked: refused.
    testing.expect_value(t,kai_new_checked(s,""),"")
    testing.expect(t,kai_paths(w,vcs.repo_working(&w.repo))=="" && kai_paths(w,working)=="c.txt")
    kai_write(t,s,fmt.tprintf("%s/e.txt",k.root),transmute([]u8)string("e"))
    kai_checks_reset(st,true)
    testing.expect(t,strings.contains(kai_new_checked(s,""),"No file is checked"))
}

// Both editors' polls, a step of their runners' threads apart: false once
// KAI_TEST_SECONDS passed since started.
@(private="file")
kai_tick :: proc(a,b:^Session,started:time.Tick) -> bool {
    kai_poll(a)
    if b!=nil {kai_poll(b)}
    time.sleep(20*time.Millisecond)
    return time.duration_seconds(time.tick_since(started))<KAI_TEST_SECONDS
}

@(private="file") KAI_TEST_SECONDS :: 30.0

@(private="file")
kai_ok :: proc(t:^testing.T,call:api.Call,what:string,loc:=#caller_location) -> bool {
    return testing.expectf(t,!call.failed,"%s: %s",what,call.error.message,loc=loc)
}

// Two editors, each with its store and its runner on 127.0.0.1: the first
// makes its user and an org with the project in it and offers a ticket, the
// second joins with it, and the first approves with the code both show,
// which names the second by its handle. The second works on the org's
// project from main and opens a proposal with a check; the first comments
// on lines of its file, approves and lands it, and both see main moved. A
// move of main around its policy answers the policy.
@(test)
editor_kai_pairs_and_lands_a_proposal :: proc(t:^testing.T) {
    ka_:=new(Kai_Fixture);defer free(ka_)
    kb:=new(Kai_Fixture);defer free(kb)
    if !kai_fixture_init(t,ka_,"kai-team-a") || !kai_fixture_init(t,kb,"kai-team-b") {return}
    defer kai_fixture_destroy(ka_)
    defer kai_fixture_destroy(kb)
    a,b:=&ka_.s,&kb.s
    for s in ([2]^Session{a,b}) {
        s.kai.mesh_loopback=true
        testing.expect_value(t,kai_enable(s),"")
        if !testing.expectf(t,kai_workspace(s)!=nil,"the workspace opens: %v",s.kai.error) {return}
    }

    // A user each; the recovery key comes once, in a dialog.
    ana:=Api_Kai_Identity_Params{name="ana",device="studio-pc"}
    call,me:=kai_call(a,api_kai_identity,&ana,Api_Kai_Identity)
    if !kai_ok(t,call,"ana") {return}
    testing.expect_value(t,me.device,"studio-pc")
    testing.expect(t,me.handle=="ana" && a.kai.state.team.recovery_length>0 && a.kai.state.team.dialog==.Recovery)
    kai_dialog_close(a)
    bo:=Api_Kai_Identity_Params{name="bo"}
    call,me=kai_call(b,api_kai_identity,&bo,Api_Kai_Identity)
    if !kai_ok(t,call,"bo") {return}
    bo_device:=strings.clone(me.device,context.temp_allocator)
    host:[vcs.NAME_MAX]u8
    testing.expectf(t,bo_device==vcs.device_name_of("",&host) && !strings.contains(bo_device,"."),"a device is named by its host: %s",bo_device)
    kai_dialog_close(b)

    // The org and the project in it; main at the first change, guarded.
    studio:=Api_Kai_Org_Params{new="studio"}
    call,_=kai_call(a,api_kai_org,&studio,Api_Kai_Orgs)
    if !kai_ok(t,call,"new org") {return}
    add:=Api_Kai_Org_Params{add="org"}
    _,orgs:=kai_call(a,api_kai_org,&add,Api_Kai_Orgs)
    if !testing.expectf(t,len(orgs.orgs)==1 && len(orgs.orgs[0].projects)==1 && orgs.orgs[0].projects[0].open,"%v",orgs) {return}
    project:=strings.clone(orgs.orgs[0].projects[0].id,context.temp_allocator)
    kai_write(t,a,fmt.tprintf("%s/a.txt",ka_.root),transmute([]u8)string("a\n"))
    testing.expect_value(t,kai_describe(a,vcs.repo_working(&kai_workspace(a).repo),"first"),"")
    testing.expect_value(t,kai_new(a,nil,""),"")
    main:=Api_Kai_Bookmarks_Params{move="main",change="@-"}
    call,_=kai_call(a,api_kai_bookmarks,&main,Api_Kai_Bookmarks)
    if !kai_ok(t,call,"main") {return}
    guard:=Api_Kai_Bookmarks_Params{policy="main",approvals=1,checks={"unit"}}
    call,_=kai_call(a,api_kai_bookmarks,&guard,Api_Kai_Bookmarks)
    if !kai_ok(t,call,"policy") {return}

    // Pairing: a ticket, joined; the request names bo by handle, and the codes agree.
    offer:=Api_Kai_Pair_Params{offer="member"}
    offered:^Api_Kai_Pair
    call,offered=kai_call(a,api_kai_pair,&offer,Api_Kai_Pair)
    if !kai_ok(t,call,"offer") || !testing.expect(t,offered.ticket!="") {return}
    join:=Api_Kai_Pair_Params{join=strings.clone(offered.ticket,context.temp_allocator)}
    call,_=kai_call(b,api_kai_pair,&join,Api_Kai_Pair)
    if !kai_ok(t,call,"join") {return}
    started:=time.tick_now()
    nothing:=Api_Kai_Pair_Params{}
    asked,joined:^Api_Kai_Pair
    for {
        _,asked=kai_call(a,api_kai_pair,&nothing,Api_Kai_Pair)
        _,joined=kai_call(b,api_kai_pair,&nothing,Api_Kai_Pair)
        if asked.asking && joined.joined_code!="" {break}
        if !testing.expect(t,kai_tick(a,b,started),"the request reaches the first editor") {return}
    }
    testing.expect_value(t,asked.who,fmt.tprintf("bo/%s",bo_device))
    testing.expect_value(t,asked.code,joined.joined_code)
    testing.expect(t,a.kai.state.team.dialog==.Pair,"the request asks in a dialog")
    approve:=Api_Kai_Pair_Params{answer="approve",code=strings.clone(asked.code,context.temp_allocator)}
    call,_=kai_call(a,api_kai_pair,&approve,Api_Kai_Pair)
    if !kai_ok(t,call,"approve") {return}
    for {
        _,joined=kai_call(b,api_kai_pair,&nothing,Api_Kai_Pair)
        if joined.joining=="approved" {break}
        if !testing.expectf(t,kai_tick(a,b,started) && joined.joining!="failed","the pairing ends approved: %s %s",joined.joining,joined.why) {return}
    }

    // The second works on the org's project, from main.
    link:=Api_Kai_Org_Params{link=project}
    for {
        call,_=kai_call(b,api_kai_org,&link,Api_Kai_Orgs)
        if !call.failed {break}
        if !testing.expectf(t,kai_tick(a,b,started),"the org's logs reach the second: %s",call.error.message) {return}
    }
    // The editors' imports share what they build through the mesh: what the
    // first one's import keeps, the second one's takes without building it.
    org:=kai_mesh_org(a)
    testing.expect(t,org!={} && kai_mesh_org(b)==org,"both share the org's derived data")
    put_source,put_close:=ka.peers_open(a.store.root,ka_.root)
    take_source,take_close:=ka.peers_open(b.store.root,kb.root)
    defer {
        if put_close!=nil {put_close(put_source)}
        if take_close!=nil {take_close(take_source)}
    }
    if !testing.expect(t,put_close!=nil && take_close!=nil,"an import opens the mesh's cache") {return}
    KEY,VERSION :: 0x5eed,3
    pixels:=make([]u8,4*4*4,context.temp_allocator)
    for &p,i in pixels {p=u8(i)}
    mips:=[1][]u8{pixels}
    doc:asset.Document
    testing.expect_value(t,asset.texture_document(&doc,&ka_.assets.types,{id=cache.id(KEY,VERSION),width=4,height=4,format=.RGBA8,mips=mips[:]},context.temp_allocator),asset.Error.None)
    texture,_:=asset.document_bytes(&doc,context.temp_allocator)
    asset.document_destroy(&doc)
    // What it is made from decides its scopes: a file of the project, in none.
    swatch:=fmt.tprintf("%s/swatch.png",ka_.root)
    testing.expect(t,os.write_entire_file(swatch,pixels)==nil)
    from:=[1]string{swatch}
    testing.expect(t,cache.put({store=&a.store,source=put_source,from=from[:]},"textures",KEY,VERSION,texture),"the first editor's import keeps and publishes it")
    loaded:asset.Asset
    if testing.expect(t,cache.load({store=&b.store,source=take_source},"textures",KEY,VERSION,&loaded),"the second editor's import takes it") {
        testing.expect(t,loaded.blob.header.id==cache.id(KEY,VERSION))
        asset.asset_close(&loaded)
    }

    on_main:=Api_Kai_New_Params{parents={"main"}}
    started=time.tick_now()
    for {
        call,_=kai_call(b,api_kai_new,&on_main,Api_Kai_Change)
        if !call.failed {break}
        if !testing.expectf(t,kai_tick(a,b,started),"main reaches the second: %s",call.error.message) {return}
    }
    kai_write(t,b,fmt.tprintf("%s/b.txt",kb.root),transmute([]u8)string("one\ntwo\n"))
    testing.expect_value(t,kai_describe(b,vcs.repo_working(&kai_workspace(b).repo),"add b"),"")
    testing.expect_value(t,kai_new(b,nil,""),"")
    wb:=kai_workspace(b)
    parent,_:=vcs.change_get(wb.repo.s,vcs.repo_working(&wb.repo),context.temp_allocator)
    proposed,_:=vcs.change_get(wb.repo.s,parent.parents[0],context.temp_allocator)
    change:=ka.change_text(proposed.id)
    open:=Api_Kai_Proposals_Params{open="main"}
    opened:^Api_Kai_Proposals
    call,opened=kai_call(b,api_kai_proposals,&open,Api_Kai_Proposals)
    if !kai_ok(t,call,"open") {return}
    id:=strings.clone(opened.opened,context.temp_allocator)
    command:=[]string{"true"} when ODIN_OS!=.Windows else []string{"cmd","/c","exit 0"}
    check:=Api_Kai_Proposal_Params{proposal=id,check="unit",command=command}
    checked:^Api_Kai_Proposal
    call,checked=kai_call(b,api_kai_proposal,&check,Api_Kai_Proposal)
    if !kai_ok(t,call,"check") {return}
    testing.expect(t,checked.passed && len(checked.stack)==1 && checked.stack[0].change==change)

    // The first sees it whole: its stack with b.txt, and the check.
    view:=Api_Kai_Proposal_Params{proposal=id}
    seen:^Api_Kai_Proposal
    for {
        call,seen=kai_call(a,api_kai_proposal,&view,Api_Kai_Proposal)
        if !call.failed && len(seen.stack)==1 && len(seen.stack[0].files)==1 && len(seen.checks)==1 {break}
        if !testing.expectf(t,kai_tick(a,b,started),"the proposal reaches the first: %s",call.error.message) {return}
    }
    testing.expect(t,len(seen.stack[0].files)==1 && seen.stack[0].files[0].path=="b.txt" && seen.checks[0].state=="passed")
    testing.expect(t,seen.blocking!="","it waits for an approval")
    comment:=Api_Kai_Proposal_Params{proposal=id,comment="both lines read well",file="b.txt",lines="1-2"}
    call,seen=kai_call(a,api_kai_proposal,&comment,Api_Kai_Proposal)
    if !kai_ok(t,call,"comment") {return}
    testing.expectf(t,len(seen.comments)==1 && seen.comments[0].lines=="1-2" && seen.comments[0].change==change && !seen.comments[0].outdated,"%v",seen.comments)
    // The first reads what the change did to b.txt: its bytes come from the
    // second, asked without waiting, and read on a later call.
    look:=Api_Kai_Proposal_Params{proposal=id,file="b.txt"}
    for {
        call,seen=kai_call(a,api_kai_proposal,&look,Api_Kai_Proposal)
        if !kai_ok(t,call,"detail") {return}
        if !seen.detail.fetching {break}
        if !testing.expect(t,kai_tick(a,b,started),"the bytes of b.txt come from the second") {return}
    }
    rows:=seen.detail.rows
    testing.expectf(t,seen.detail.kind=="text" && seen.detail.change==change && len(rows)==2 && rows[0].mark=="+" && rows[0].new==1 && rows[0].text=="one" && rows[1].text=="two","%v",seen.detail)
    verdict:=Api_Kai_Proposal_Params{proposal=id,verdict="approve"}
    call,seen=kai_call(a,api_kai_proposal,&verdict,Api_Kai_Proposal)
    if !kai_ok(t,call,"approve") {return}
    testing.expectf(t,seen.blocking=="","it may land: %s",seen.blocking)

    // main moves only by landing: a move around the policy answers it.
    around:=Api_Kai_Bookmarks_Params{move="main",change="@"}
    call,_=kai_call(a,api_kai_bookmarks,&around,Api_Kai_Bookmarks)
    testing.expectf(t,call.failed && strings.contains(call.error.message,"policy"),"%s",call.error.message)
    land:=Api_Kai_Proposal_Params{proposal=id,land=true}
    call,seen=kai_call(a,api_kai_proposal,&land,Api_Kai_Proposal)
    if !kai_ok(t,call,"land") {return}
    testing.expect_value(t,seen.status,"landed")
    // What a result holds lives in the call's allocator: the temporary one is overwritten once
    // the call returns.
    owned:=make([]u8,1<<20)
    defer delete(owned)
    own:mem.Arena
    mem.arena_init(&own,owned)
    apart:=Api_Kai_Proposal_Params{proposal=id}
    call,seen=kai_call_apart(a,api_kai_proposal,&apart,Api_Kai_Proposal,mem.arena_allocator(&own))
    if !kai_ok(t,call,"view apart") {return}
    testing.expect_value(t,seen.status,"landed")

    // Both see main moved to the change that landed.
    listed:=Api_Kai_Bookmarks_Params{}
    for s in ([2]^Session{a,b}) {
        for {
            _,marks:=kai_call(s,api_kai_bookmarks,&listed,Api_Kai_Bookmarks)
            moved:=false
            for m in marks.bookmarks {moved||=m.name=="main" && m.shared && m.change==change}
            if moved {break}
            if !testing.expect(t,kai_tick(a,b,started),"main moved for both") {return}
        }
    }
}

// The width of the Kai tab: that of the left panel inside its padding.
@(private="file") KAI_TAB :: LEFT_WIDTH.min-2*PANEL_PADDING

@(private="file")
kai_panel_frame :: proc(s:^Session,input:ui.Input) -> ui.Frame {
    ctx:=s.gui.ctx
    ui.frame_begin(ctx,input)
    if ui.box(ctx,{width=ui.fixed(KAI_TAB),height=ui.fixed(860),direction=.Column,gap=6}) {kai_panel_build(s,KAI_TAB,860)}
    if s.gui.modal==.Kai {kai_dialog_build(s)}
    return ui.frame_end(ctx)
}

@(private="file")
kai_panel_still :: proc(t:^testing.T,s:^Session,input:=ui.Input{size={900,900},pointer_absent=true},loc:=#caller_location) {
    frame:=kai_panel_frame(s,input)
    testing.expect(t,!frame.overflow && s.gui.ctx.stats.layout_errors==0,"the tab lays out",loc=loc)
}

@(private="file")
kai_panel_click :: proc(t:^testing.T,s:^Session,id:ui.Id,loc:=#caller_location) -> bool {
    rect,found:=ui.widget_rect(s.gui.ctx,id)
    if !testing.expect(t,found,"the button is there",loc=loc) {return false}
    for phase in 0..<3 {
        input:=ui.Input{size={900,900},pointer=ui.rect_center(rect)}
        if phase==1 {input.down,input.pressed,input.clicks={.Left},{.Left},1}
        if phase==2 {input.released={.Left}}
        kai_panel_still(t,s,input,loc)
    }
    return true
}

// What the last button asked for: its method and params; the queue empties.
@(private="file")
kai_panel_asked :: proc(s:^Session) -> (method,params:string) {
    c:=&api_state(s).commands
    if c.asked_count==0 {return}
    asked:=&c.asked[c.asked_count-1]
    method,params=strings.clone(asked.method,context.temp_allocator),strings.clone(string(asked.params[:asked.length]),context.temp_allocator)
    return
}

// Whether the controls of ids show their texts whole: a button its label, a
// field its placeholder inside its padding.
@(private="file")
kai_fit :: proc(t:^testing.T,s:^Session,controls:[]struct{id:ui.Id,text:string,field:bool},loc:=#caller_location) {
    ctx:=s.gui.ctx
    for c in controls {
        rect,found:=ui.widget_rect(ctx,c.id)
        if !testing.expectf(t,found,"%q is there",c.text,loc=loc) {continue}
        needed:=ui.text_width(&ctx.font,c.text,ui.metric(ctx,"font"))+(c.field?16:0)
        testing.expectf(t,rect.w+0.5>=needed,"%q fits: %.1f of %.1f",c.text,rect.w,needed,loc=loc)
    }
}

// The id of a row of the tab inside the scopes of names.
@(private="file")
kai_row_id :: proc(ctx:^ui.Context,scopes:[]struct{name:string,index:int},name:string) -> ui.Id {
    for x in scopes {ui.id_push(ctx,ui.id(ctx,x.name,x.index))}
    id:=ui.id(ctx,name)
    for _ in scopes {ui.id_pop(ctx)}
    return id
}

// A frame of the tab that changes nothing allocates nothing, in each view.
@(private="file")
kai_panel_stable :: proc(t:^testing.T,s:^Session,what:string,loc:=#caller_location) {
    kai_panel_still(t,s,loc=loc)
    heap,temp:mem.Tracking_Allocator
    mem.tracking_allocator_init(&heap,context.allocator);defer mem.tracking_allocator_destroy(&heap)
    mem.tracking_allocator_init(&temp,context.temp_allocator);defer mem.tracking_allocator_destroy(&temp)
    {
        context.allocator=mem.tracking_allocator(&heap)
        context.temp_allocator=mem.tracking_allocator(&temp)
        kai_panel_still(t,s,loc=loc)
    }
    testing.expectf(t,heap.total_allocation_count==0 && temp.total_allocation_count==0,"%s: a stable frame allocates nothing (%d, %d)",what,heap.total_allocation_count,temp.total_allocation_count,loc=loc)
}

// The team views draw what was read, and a frame that changes nothing
// allocates nothing in any of them; their buttons ask for kai.* methods,
// which run between frames. The recovery key's dialog goes only by its
// button, and a pairing request's dialog has no default: Enter and Escape
// answer nothing.
@(test)
editor_kai_team_views_ask_their_methods_and_keep_still_frames :: proc(t:^testing.T) {
    k:=new(Kai_Fixture);defer free(k)
    if !kai_fixture_init(t,k,"kai-team-panel") {return}
    defer kai_fixture_destroy(k)
    s:=&k.s
    s.kai.mesh_loopback=true
    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    k.gui.ctx,k.gui.begun=&ctx,true
    if !test_commands_open(t,s,&k.editor.api) {return}
    defer test_commands_close(s)
    testing.expect_value(t,kai_enable(s),"")
    if !testing.expect(t,kai_workspace(s)!=nil) {return}
    st:=s.kai.state
    team:=&st.team

    // Team, with no user: a handle typed and Make user ask kai.identity.
    team.tab=.Team
    kai_team_read(s)
    kai_panel_stable(t,s,"team without a user")
    team.fields.name_length=copy(team.fields.name[:],"ana")
    kai_panel_still(t,s)
    if !kai_panel_click(t,s,ui.id(&ctx,"kai_user_make")) {return}
    method,params:=kai_panel_asked(s)
    testing.expect(t,method=="kai.identity" && strings.contains(params,`"ana"`),params)
    commands_run(s)
    testing.expect(t,team.machine.user!={} && s.gui.modal==.Kai && team.dialog==.Recovery,"the method ran and shows the key")
    kai_panel_still(t,s)
    escape_run(s,s.gui,s.viewport,s.selection)
    testing.expect(t,team.dialog==.Recovery,"Escape leaves the recovery key up")
    if !kai_panel_click(t,s,shell_id(s.gui,"kai_recovery_done")) {return}
    testing.expect(t,team.dialog==.None && s.gui.modal==.None && team.recovery_length==0)

    // An org: Make org asks kai.org; with the project in it, the tab lists it.
    team.fields.org_length=copy(team.fields.org[:],"studio")
    kai_panel_still(t,s)
    if !kai_panel_click(t,s,ui.id(&ctx,"kai_org_make")) {return}
    method,params=kai_panel_asked(s)
    testing.expect(t,method=="kai.org" && strings.contains(params,`"studio"`),params)
    commands_run(s)
    add:=Api_Kai_Org_Params{add="org"}
    call,_:=kai_call(s,api_kai_org,&add,Api_Kai_Orgs)
    if !kai_ok(t,call,"add") {return}
    kai_write(t,s,fmt.tprintf("%s/a.txt",k.root),transmute([]u8)string("a"))
    testing.expect_value(t,kai_new(s,nil,"first"),"")
    main:=Api_Kai_Bookmarks_Params{move="main",change="@-"}
    call,_=kai_call(s,api_kai_bookmarks,&main,Api_Kai_Bookmarks)
    if !kai_ok(t,call,"main") {return}
    kai_write(t,s,fmt.tprintf("%s/b.txt",k.root),transmute([]u8)string("b"))
    testing.expect_value(t,kai_new(s,nil,"second"),"")
    open:=Api_Kai_Proposals_Params{open="main"}
    call,_=kai_call(s,api_kai_proposals,&open,Api_Kai_Proposals)
    if !kai_ok(t,call,"open") {return}
    kai_team_read(s)
    kai_panel_stable(t,s,"team")
    // At the tab's width every control shows its text whole.
    kai_fit(t,s,{
        {ui.id(&ctx,"kai_offer",0),"Member",false},{ui.id(&ctx,"kai_offer",1),"Second device",false},{ui.id(&ctx,"kai_offer",2),"Node",false},
        {ui.id(&ctx,"kai_identity_act",0),"Rotate recovery key",false},{ui.id(&ctx,"kai_identity_act",1),"Copy subject",false},
        {ui.id(&ctx,"kai_ticket"),"Ticket from another machine",true},{kai_row_id(&ctx,{{"org",0}},"kai_policy_approvals"),"Approvals",true},
        {kai_row_id(&ctx,{{"org",0}},"kai_policy_checks"),"Checks, as unit,lint",true},{ui.id(&ctx,"kai_patterns"),"Patterns, as secrets/** .env",true},
    })
    if !kai_panel_click(t,s,ui.id(&ctx,"kai_offer",0)) {return}
    method,params=kai_panel_asked(s)
    testing.expect(t,method=="kai.pair" && strings.contains(params,`"member"`),params)
    api_state(s).commands.asked_count=0

    // Changes: the shared main among the bookmarks; a name typed shares @-.
    team.tab=.Changes
    kai_panel_stable(t,s,"changes")
    team.fields.bookmark_length=copy(team.fields.bookmark[:],"next")
    kai_panel_still(t,s)
    if !kai_panel_click(t,s,ui.id(&ctx,"kai_share")) {return}
    method,params=kai_panel_asked(s)
    testing.expect(t,method=="kai.bookmarks" && strings.contains(params,`"move":"next"`),params)
    api_state(s).commands.asked_count=0
    // A change of the log shows its files; one opens what the change did to it.
    if !kai_panel_click(t,s,kai_row_id(&ctx,{{"change",1}},"row")) {return}
    if !testing.expectf(t,len(st.view.picked)==1 && st.view.picked[0].path=="b.txt","%v",st.view.picked) {return}
    if !kai_panel_click(t,s,kai_row_id(&ctx,{{"change",1},{"file",0}},"row")) {return}
    testing.expect(t,st.detail.open && st.detail.tab==.Changes && st.detail.view.kind==.Text,"the file's detail opens")
    kai_panel_stable(t,s,"a change's file")
    kai_detail_close(st)
    st.picked={}
    kai_read(s)

    // Proposals: the list, then one open; Approve asks for the verdict.
    team.tab=.Proposals
    kai_panel_stable(t,s,"proposals")
    team.proposal=team.view.proposals[0].id
    kai_team_read(s)
    if !testing.expect(t,team.view.shown) {return}
    kai_panel_stable(t,s,"a proposal")
    kai_fit(t,s,{
        {ui.id(&ctx,"kai_verdict",0),"Approve",false},{ui.id(&ctx,"kai_verdict",1),"Request changes",false},{ui.id(&ctx,"kai_verdict",2),"Withdraw",false},
        {ui.id(&ctx,"kai_proposal_act",0),"Revise",false},{ui.id(&ctx,"kai_proposal_act",2),"Land",false},
        {ui.id(&ctx,"kai_check_command"),"Command, as mirai test kai",true},
    })

    // A file of the stack opens what its change did; a click on a line starts
    // a comment there, which then shows under it.
    if !kai_panel_click(t,s,kai_row_id(&ctx,{{"item",0},{"file",0}},"row")) {return}
    d:=&st.detail
    if !testing.expectf(t,d.open && d.view.path=="b.txt" && len(d.view.rows)==1 && d.view.rows[0].mark=='+',"%v",d.view) {return}
    kai_panel_stable(t,s,"a file's detail")
    if !kai_panel_click(t,s,kai_row_id(&ctx,{{"entry",0}},"row")) {return}
    testing.expect(t,team.fields.file==0 && string(team.fields.lines[:team.fields.lines_length])=="1","the line picked is the comment's")
    team.fields.comment_length=copy(team.fields.comment[:],"why b")
    kai_panel_still(t,s)
    if !kai_panel_click(t,s,ui.id(&ctx,"kai_comment_go",0)) {return}
    method,params=kai_panel_asked(s)
    testing.expect(t,method=="kai.proposal" && strings.contains(params,`"file":"b.txt"`) && strings.contains(params,`"lines":"1"`),params)
    commands_run(s)
    testing.expectf(t,len(d.entries)==2 && d.entries[1].note==0,"the comment shows under its line: %v",d.entries[:])
    kai_panel_stable(t,s,"a file's detail with a comment")
    if !kai_panel_click(t,s,ui.id(&ctx,"kai_detail_back")) {return}
    testing.expect(t,!d.open,"back to the proposal")
    if !kai_panel_click(t,s,ui.id(&ctx,"kai_verdict",0)) {return}
    method,params=kai_panel_asked(s)
    testing.expect(t,method=="kai.proposal" && strings.contains(params,`"verdict":"approve"`),params)
    commands_run(s)
    testing.expect(t,len(team.view.proposal.verdicts)==1,"the method ran")

    // A pairing request: neither Enter nor Escape answers it.
    team.request={mode=.Member}
    team.request.who_length=copy(team.request.who[:],"bo/laptop")
    copy(team.request.code[:],"1234-5678")
    kai_dialog_open(s,.Pair)
    kai_panel_still(t,s)
    kai_panel_still(t,s,{size={900,900},pointer_absent=true,keys_down={.Enter},keys_pressed={.Enter}})
    escape_run(s,s.gui,s.viewport,s.selection)
    testing.expect(t,team.dialog==.Pair && api_state(s).commands.asked_count==0,"no answer without a button")
    if !kai_panel_click(t,s,shell_id(s.gui,"kai_pair_deny")) {return}
    method,params=kai_panel_asked(s)
    testing.expect(t,method=="kai.pair" && strings.contains(params,`"deny"`),params)
    api_state(s).commands.asked_count=0
    kai_dialog_close(s)
}

// Every team method refuses params that do not fit, with what to give.
@(test)
editor_kai_team_methods_refuse_hostile_params :: proc(t:^testing.T) {
    k:=new(Kai_Fixture);defer free(k)
    if !kai_fixture_init(t,k,"kai-team-hostile") {return}
    defer kai_fixture_destroy(k)
    s:=&k.s
    testing.expect_value(t,kai_enable(s),"")
    if !testing.expect(t,kai_workspace(s)!=nil) {return}
    refused :: proc(t:^testing.T,call:api.Call,want:string,loc:=#caller_location) {
        testing.expectf(t,call.failed && call.error.code==api.INVALID_PARAMS && strings.contains(call.error.message,want),"wanted %q: %v %s",want,call.failed,call.error.message,loc=loc)
    }
    long:=strings.repeat("x",vcs.NAME_MAX+1,context.temp_allocator)
    identities:=[?]struct{p:Api_Kai_Identity_Params,want:string}{
        {{name="a",revoke="b"},"give one of"},
        {{name=long},"1 to 64 bytes"},
        {{revoke="b",device="pc"},"goes with name"},
        {{name="a",device=long},"1 to 64 bytes"},
        {{recover="ab12cd34"},"recover takes recovery"},
        {{recover="ab12cd34",recovery="x",name="a"},"give one of"},
    }
    for c in identities {
        p:=c.p
        call,_:=kai_call(s,api_kai_identity,&p,Api_Kai_Identity)
        refused(t,call,c.want)
    }
    // With no window to show a recovery key to, neither making a user nor
    // rotating its key makes anything.
    s.headless=true
    for &p in ([]Api_Kai_Identity_Params{{name="ana"},{recovery="ABCD"},{first_recovery=true}}) {
        call,_:=kai_call(s,api_kai_identity,&p,Api_Kai_Identity)
        testing.expectf(t,call.failed && strings.contains(call.error.message,"mirai kai identity"),"%v %s",p,call.error.message)
    }
    testing.expect(t,s.kai.state.team.machine.user=={} && s.kai.state.team.dialog==.None,"nothing was made")
    s.headless=false
    orgs:=[?]struct{p:Api_Kai_Org_Params,want:string}{
        {{add="everyone"},"public or org"},
        {{member="x",role="god"},"reader, writer or admin"},
        {{role="admin"},"goes with member"},
        {{new="a",leave=true},"give one of"},
    }
    for c in orgs {
        p:=c.p
        call,_:=kai_call(s,api_kai_org,&p,Api_Kai_Orgs)
        refused(t,call,c.want)
    }
    pairs:=[?]struct{p:Api_Kai_Pair_Params,want:string}{
        {{offer="cat"},"member, device, node or recover"},
        {{offer="member",role="god"},"reader, writer or admin"},
        {{offer="node",modes="teleport"},"relay, seed and ddc"},
        {{join="not a ticket"},"does not read"},
        {{answer="maybe"},"approve or deny"},
        {{answer="approve"},"1234-5678"},
    }
    for c in pairs {
        p:=c.p
        call,_:=kai_call(s,api_kai_pair,&p,Api_Kai_Pair)
        refused(t,call,c.want)
    }
    lists:=[?]struct{p:Api_Kai_Proposals_Params,want:string}{
        {{title="x"},"go with open"},
        {{open="has space"},"no bookmark name"},
    }
    for c in lists {
        p:=c.p
        call,_:=kai_call(s,api_kai_proposals,&p,Api_Kai_Proposals)
        refused(t,call,c.want)
    }
    proposals:=[?]struct{p:Api_Kai_Proposal_Params,want:string}{
        {{},"name one"},
        {{proposal="ab",lines="1-2"},"go with comment"},
        {{proposal="ab",file="a.txt",verdict="approve"},"file goes with comment"},
        {{proposal="ab",change="@"},"goes with file"},
        {{proposal="ab",comment="x",file="a.txt",lines="9-1"},"A-B"},
        {{proposal="ab",comment="x",entity=5},"hang on a file"},
        {{proposal="ab",verdict="maybe"},"approve, changes or withdraw"},
        {{proposal="ab",check="unit"},"command"},
        {{proposal="ab",land=true,close=true},"give one of"},
    }
    for c in proposals {
        p:=c.p
        call,_:=kai_call(s,api_kai_proposal,&p,Api_Kai_Proposal)
        refused(t,call,c.want)
    }
    scopes:=[?]struct{p:Api_Kai_Scopes_Params,want:string}{
        {{add={"x"},readers="god"},"reader, writer, admin or owner"},
        {{add={"../etc"}},"no pattern"},
        {{public="a.txt:0"},"line from 1"},
        {{remove="a",rotate="b"},"give one of"},
        {{readers="admin"},"go with add"},
    }
    for c in scopes {
        p:=c.p
        call,_:=kai_call(s,api_kai_scopes,&p,Api_Kai_Scopes)
        refused(t,call,c.want)
    }
    marks:=[?]struct{p:Api_Kai_Bookmarks_Params,want:string}{
        {{move="main",policy="main"},"one per call"},
        {{policy="main",approvals=-3},"from 0 to 255"},
        {{move="has space"},"no bookmark name"},
        {{policy="main",checks={""}},"a check's name"},
    }
    for c in marks {
        p:=c.p
        call,_:=kai_call(s,api_kai_bookmarks,&p,Api_Kai_Bookmarks)
        refused(t,call,c.want)
    }
}

@(private="file") Kai_None :: struct {}

// A project without a Kai workspace uses no version control: opening and
// polling it makes none, the editor edits as ever, the Kai tab offers Enable
// Kai, which asks kai.init, and kai.init makes the workspace on demand, once;
// it then opens with the project.
@(test)
editor_kai_is_optional_until_enabled :: proc(t:^testing.T) {
    k:=new(Kai_Fixture);defer free(k)
    if !kai_fixture_init(t,k,"kai-optional") {return}
    defer kai_fixture_destroy(k)
    s:=&k.s
    ctx:ui.Context
    if !testing.expect(t,test_ui_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    k.gui.ctx,k.gui.begun=&ctx,true
    if !test_commands_open(t,s,&k.editor.api) {return}
    defer test_commands_close(s)
    notes:=fmt.tprintf("%s/notes.txt",k.root)
    testing.expect(t,os.write_entire_file(notes,transmute([]u8)string("one"))==nil)

    kai_open(s)
    kai_poll(s)
    testing.expect(t,kai_workspace(s)==nil && !ka.project_exists(k.root),"opening makes no workspace")
    testing.expect_value(t,s.kai.error,vcs.Error.Missing)
    testing.expect(t,strings.contains(kai_missing(s),"does not use version control"),kai_missing(s))

    // The editor edits as ever; what would record history says why it does not.
    made:=entity_create(s,{name="Lamp",named=true})
    prefab_fixture_step(&k.f)
    testing.expect(t,api_entity(edited_world(s),api_entity_id(edited_world(s),made))!=core.NONE,"the edit is made")
    kai_touched(s,notes)
    testing.expect(t,strings.contains(kai_snapshot(s),"does not use version control"))
    none:Kai_None
    call,_:=kai_call(s,api_kai_status,&none,Api_Kai_Status)
    testing.expectf(t,call.failed && strings.contains(call.error.message,"kai.init"),"%s",call.error.message)
    kai_poll(s)
    testing.expect(t,!ka.project_exists(k.root),"nothing made a workspace")

    // The tab offers Enable Kai, which asks kai.init.
    kai_panel_still(t,s)
    if !kai_panel_click(t,s,ui.id(&ctx,"kai_enable")) {return}
    method,params:=kai_panel_asked(s)
    testing.expectf(t,method=="kai.init" && params=="{}","%s %s",method,params)
    api_state(s).commands.asked_count=0
    testing.expect(t,!ka.project_exists(k.root),"the button only asks")

    // Without a store kai.init says where Kai keeps the changes.
    store_root:=s.store.root
    s.store.root=""
    call,_=kai_call(s,api_kai_init,&none,Api_Kai_Init)
    testing.expectf(t,call.failed && strings.contains(call.error.message,"--store"),"%s",call.error.message)
    s.store.root=store_root

    // kai.init makes the workspace whose first change holds the files; once.
    init:^Api_Kai_Init
    call,init=kai_call(s,api_kai_init,&none,Api_Kai_Init)
    if !kai_ok(t,call,"kai.init") {return}
    w:=kai_workspace(s)
    if !testing.expect(t,w!=nil && ka.project_exists(k.root) && init.change!="") {return}
    testing.expect(t,strings.contains(kai_paths(w,vcs.repo_working(&w.repo)),"notes.txt"),"the first change holds the files")
    call,_=kai_call(s,api_kai_init,&none,Api_Kai_Init)
    testing.expectf(t,call.failed && strings.contains(call.error.message,"already"),"%s",call.error.message)
    kai_panel_still(t,s)

    // The next editor on the project opens it.
    kai_close(s)
    s.kai.tried=false
    kai_open(s)
    testing.expect(t,kai_workspace(s)!=nil && s.kai.error==.None,"the workspace opens with the project")
}

// kai.status, kai.snapshot, kai.describe, kai.undo, kai.restore,
// kai.conflicts, kai.resolve, kai.prune and kai.peers through the API; kai.log
// reads and records nothing.
@(test)
editor_kai_methods_record_read_and_settle_the_working_copy :: proc(t:^testing.T) {
    k:=new(Kai_Fixture);defer free(k)
    if !kai_fixture_init(t,k,"kai-methods") {return}
    defer kai_fixture_destroy(k)
    s:=&k.s
    a:=fmt.tprintf("%s/a.txt",k.root)
    testing.expect(t,os.write_entire_file(a,transmute([]u8)string("one\n"))==nil)
    testing.expect_value(t,kai_enable(s),"")
    w:=kai_workspace(s)
    if !testing.expect(t,w!=nil) {return}
    origin:=vcs.repo_working(&w.repo)
    none:Kai_None

    // kai.snapshot records a file written behind the editor's back.
    testing.expect_value(t,kai_new(s,nil,""),"")
    testing.expect(t,os.write_entire_file(a,transmute([]u8)string("two\n"))==nil)
    call,snapshot:=kai_call(s,api_kai_snapshot,&none,Api_Kai_Snapshot)
    if !kai_ok(t,call,"kai.snapshot") {return}
    testing.expect(t,snapshot.change!="" && snapshot.files>=1)
    status:^Api_Kai_Status
    call,status=kai_call(s,api_kai_status,&none,Api_Kai_Status)
    if !kai_ok(t,call,"kai.status") {return}
    testing.expectf(t,status.change==snapshot.change && len(status.files)==1 && status.files[0].path=="a.txt" && status.files[0].change=="M" && len(status.conflicts)==0,"%v",status^)

    // kai.log records nothing: a file written since stays out of the history.
    testing.expect(t,os.write_entire_file(a,transmute([]u8)string("three\n"))==nil)
    kai_touched(s,a)
    op:=w.repo.op
    log_params:=Api_Kai_Log_Params{file="a.txt"}
    call,_=kai_call(s,api_kai_log,&log_params,Api_Kai_Log)
    if !kai_ok(t,call,"kai.log") {return}
    testing.expect(t,w.repo.op==op,"kai.log ran no operation")
    testing.expect(t,os.write_entire_file(a,transmute([]u8)string("two\n"))==nil)

    // kai.describe, and kai.undo takes it back.
    describe:=Api_Kai_Describe_Params{description="edit a"}
    described:^Api_Kai_Change
    call,described=kai_call(s,api_kai_describe,&describe,Api_Kai_Change)
    if !kai_ok(t,call,"kai.describe") {return}
    testing.expect_value(t,described.change,status.change)
    testing.expect_value(t,s.kai.state.view.description,"edit a")
    undone:^Api_Kai_Undone
    call,undone=kai_call(s,api_kai_undo,&none,Api_Kai_Undone)
    if !kai_ok(t,call,"kai.undo") {return}
    testing.expect(t,undone.undone!="" && s.kai.state.view.description=="","the description is taken back")

    // kai.restore gives the working copy the files of its parent.
    restore:=Api_Kai_Restore_Params{from="@-"}
    call,_=kai_call(s,api_kai_restore,&restore,Api_Kai_Done)
    if !kai_ok(t,call,"kai.restore") {return}
    data,_:=os.read_entire_file(a,context.temp_allocator)
    testing.expect_value(t,string(data),"one\n")
    wrong:=Api_Kai_Restore_Params{from="zzzzzz"}
    call,_=kai_call(s,api_kai_restore,&wrong,Api_Kai_Done)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS)

    // Ours and theirs change the same line on the origin: their merge is a conflict.
    kai_write(t,s,a,transmute([]u8)string("ours\n"))
    ours:=vcs.repo_working(&w.repo)
    parents:=[1]vcs.Revision{origin}
    testing.expect_value(t,kai_new(s,parents[:],""),"")
    kai_write(t,s,a,transmute([]u8)string("theirs\n"))
    theirs:=vcs.repo_working(&w.repo)
    both:=[2]vcs.Revision{ours,theirs}
    testing.expect_value(t,kai_new(s,both[:],"merge"),"")
    conflicts:^Api_Kai_Conflicts
    call,conflicts=kai_call(s,api_kai_conflicts,&none,Api_Kai_Conflicts)
    if !kai_ok(t,call,"kai.conflicts") {return}
    if !testing.expectf(t,len(conflicts.files)==1 && conflicts.files[0].path=="a.txt" && !conflicts.files[0].asset,"%v",conflicts.files) {return}
    call,status=kai_call(s,api_kai_status,&none,Api_Kai_Status)
    testing.expectf(t,!call.failed && len(status.conflicts)==1 && status.conflicts[0]=="a.txt","%v",status.conflicts)

    // kai.resolve refuses what is no side, then takes theirs whole.
    bad:=Api_Kai_Resolve_Params{file="a.txt",whole="maybe"}
    call,_=kai_call(s,api_kai_resolve,&bad,Api_Kai_Done)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS)
    nowhere:=Api_Kai_Resolve_Params{file="b.txt",whole="ours"}
    call,_=kai_call(s,api_kai_resolve,&nowhere,Api_Kai_Done)
    testing.expectf(t,call.failed && strings.contains(call.error.message,"not in conflict"),"%s",call.error.message)
    resolve:=Api_Kai_Resolve_Params{file="a.txt",whole="theirs"}
    call,_=kai_call(s,api_kai_resolve,&resolve,Api_Kai_Done)
    if !kai_ok(t,call,"kai.resolve") {return}
    testing.expect_value(t,len(w.state.conflicts),0)
    data,_=os.read_entire_file(a,context.temp_allocator)
    testing.expect_value(t,string(data),"theirs\n")

    // kai.prune sweeps the store and leaves the working copy as it is.
    working:=vcs.repo_working(&w.repo)
    pruned:^Api_Kai_Pruned
    call,pruned=kai_call(s,api_kai_prune,&none,Api_Kai_Pruned)
    if !kai_ok(t,call,"kai.prune") {return}
    testing.expect(t,pruned.freed>=0 && vcs.repo_working(&w.repo)==working)

    // kai.peers: no runner, no peers.
    peers:^Api_Kai_Peers
    call,peers=kai_call(s,api_kai_peers,&none,Api_Kai_Peers)
    if !kai_ok(t,call,"kai.peers") {return}
    testing.expectf(t,peers.mesh!="" && len(peers.peers)==0,"%v",peers^)
}
