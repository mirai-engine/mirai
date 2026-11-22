package editor

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import ka "mirai:cook/kai"
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

    // The project becomes a workspace: its files are the first change.
    kai_open(s)
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
    kai_open(s)
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
        kai_open(s)
        if !testing.expectf(t,kai_workspace(s)!=nil,"the workspace opens: %v",s.kai.error) {return}
    }

    // A user each; the recovery key comes once, in a dialog.
    ana:=Api_Kai_Identity_Params{name="ana"}
    call,me:=kai_call(a,api_kai_identity,&ana,Api_Kai_Identity)
    if !kai_ok(t,call,"ana") {return}
    testing.expect(t,me.handle=="ana" && me.recovery!="" && a.kai.state.team.dialog==.Recovery)
    kai_dialog_close(a)
    bo:=Api_Kai_Identity_Params{name="bo"}
    call,me=kai_call(b,api_kai_identity,&bo,Api_Kai_Identity)
    if !kai_ok(t,call,"bo") {return}
    bo_device:=strings.clone(me.device,context.temp_allocator)
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
    on_main:=Api_Kai_New_Params{parents={"main"}}
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

@(private="file")
kai_panel_frame :: proc(s:^Session,input:ui.Input) -> ui.Frame {
    ctx:=s.gui.ctx
    ui.frame_begin(ctx,input)
    if ui.box(ctx,{width=ui.fixed(320),height=ui.fixed(860),direction=.Column,gap=6}) {kai_panel_build(s,320,860)}
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
    kai_open(s)
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

    // Proposals: the list, then one open; Approve asks for the verdict.
    team.tab=.Proposals
    kai_panel_stable(t,s,"proposals")
    team.proposal=team.view.proposals[0].id
    kai_team_read(s)
    if !testing.expect(t,team.view.shown) {return}
    kai_panel_stable(t,s,"a proposal")
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
    kai_open(s)
    if !testing.expect(t,kai_workspace(s)!=nil) {return}
    refused :: proc(t:^testing.T,call:api.Call,want:string,loc:=#caller_location) {
        testing.expectf(t,call.failed && call.error.code==api.INVALID_PARAMS && strings.contains(call.error.message,want),"wanted %q: %v %s",want,call.failed,call.error.message,loc=loc)
    }
    long:=strings.repeat("x",vcs.NAME_MAX+1,context.temp_allocator)
    identities:=[?]struct{p:Api_Kai_Identity_Params,want:string}{
        {{name="a",revoke="b"},"give one of"},
        {{name=long},"1 to 64 bytes"},
    }
    for c in identities {
        p:=c.p
        call,_:=kai_call(s,api_kai_identity,&p,Api_Kai_Identity)
        refused(t,call,c.want)
    }
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
        {{offer="cat"},"member, device or node"},
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
