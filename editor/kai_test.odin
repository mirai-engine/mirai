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

    // Every file checked: the text typed names the change that closes, the new
    // one is empty and has none, and one undo takes both back.
    testing.expect_value(t,kai_new_checked(s,"c alone"),"")
    after:=vcs.repo_working(&w.repo)
    c,_=vcs.change_get(w.repo.s,after,context.temp_allocator)
    closed,_=vcs.change_get(w.repo.s,c.parents[0],context.temp_allocator)
    testing.expect(t,c.description=="" && closed.description=="c alone","the description goes to the change that closes")
    testing.expect(t,kai_paths(w,after)=="" && kai_paths(w,c.parents[0])=="c.txt")
    // A change with no file and no description, and none typed: nothing closes.
    testing.expect(t,strings.contains(kai_new_checked(s,""),"empty"))
    testing.expect(t,vcs.repo_working(&w.repo)==after,"no change is stacked on an empty one")
    _,refused:=kai_undo(s)
    testing.expect_value(t,refused,"")
    c,_=vcs.change_get(w.repo.s,vcs.repo_working(&w.repo),context.temp_allocator)
    testing.expect(t,c.description=="" && kai_paths(w,vcs.repo_working(&w.repo))=="c.txt","one undo opens the change again, undescribed")
    // None checked: refused.
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

@(private="file") KAI_TAB :: LEFT_WIDTH.min-2*PANEL_PADDING
@(private="file") Kai_None :: struct {}

@(private="file")
kai_panel_frame :: proc(s:^Session,input:ui.Input) -> ui.Frame {
    ctx:=s.gui.ctx
    ui.frame_begin(ctx,input)
    if ui.box(ctx,{width=ui.fixed(KAI_TAB),height=ui.fixed(860),direction=.Column,gap=6}) {kai_panel_build(s,KAI_TAB,860)}
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

// Two editors, each with its store and its agent on 127.0.0.1, without a
// terminal: the first names itself, makes an org and publishes the project to
// main into it (one call, Org only); a publish that fails keeps the typed
// description. It makes an invite; the second, a launcher with no project,
// joins with it, sees the repository in its Repositories and pulls it into a
// folder, with how far the pull is in chunks and bytes, until its files are
// there.
@(test)
editor_kai_publishes_to_main_and_a_launcher_pulls_it :: proc(t:^testing.T) {
    ka_:=new(Kai_Fixture);defer free(ka_)
    kb:=new(Kai_Fixture);defer free(kb)
    if !kai_fixture_init(t,ka_,"kai-team-a") || !kai_fixture_init(t,kb,"kai-team-b") {return}
    defer kai_fixture_destroy(ka_)
    defer kai_fixture_destroy(kb)
    a,b:=&ka_.s,&kb.s
    a.kai.mesh_loopback,b.kai.mesh_loopback=true,true
    b.has_project=false
    testing.expect_value(t,kai_enable(a),"")
    if !testing.expectf(t,kai_workspace(a)!=nil,"the workspace opens: %v",a.kai.error) {return}
    for x in ([]struct{s:^Session,name,device:string}{{a,"ana","studio-pc"},{b,"bo","laptop"}}) {
        p:=Api_Kai_Profile_Params{name=x.name,device=x.device}
        call,r:=kai_call(x.s,api_kai_profile,&p,Api_Kai_Orgs)
        if !kai_ok(t,call,x.name) || !testing.expect_value(t,r.device,x.device) {return}
    }
    studio:=Api_Kai_Org_Params{new="studio"}
    call,orgs:=kai_call(a,api_kai_org,&studio,Api_Kai_Orgs)
    if !kai_ok(t,call,"new org") || !testing.expect(t,len(orgs.orgs)==1 && orgs.orgs[0].role=="admin") {return}
    org:=strings.clone(orgs.orgs[0].id,context.temp_allocator)
    // A publish that fails leaves the typed description where it was.
    st:=a.kai.state
    st.description_length=copy(st.description[:],"the first version")
    bad:=Api_Kai_Publish_Params{description="the first version",org="nowhere"}
    call,_=kai_call(a,api_kai_publish,&bad,Api_Kai_Published)
    testing.expect(t,call.failed && st.description_length>0,"a failed publish keeps the description")
    // A first publish that refuses leaves the org's record as it was.
    unnamed:=Api_Kai_Publish_Params{org=org,visibility="org",bookmark="no name\x00"}
    call,_=kai_call(a,api_kai_publish,&unnamed,Api_Kai_Published)
    _,orgs=kai_call(a,api_kai_org,&Api_Kai_Org_Params{},Api_Kai_Orgs)
    testing.expect(t,call.failed && len(orgs.orgs[0].repositories)==0,"a refused first publish adds no repository to the org")
    kai_write(t,a,fmt.tprintf("%s/a.txt",ka_.root),transmute([]u8)string("a\n"))
    publish:=Api_Kai_Publish_Params{description="the first version",org=org,visibility="org"}
    published:^Api_Kai_Published
    call,published=kai_call(a,api_kai_publish,&publish,Api_Kai_Published)
    if !kai_ok(t,call,"publish") {return}
    testing.expect(t,published.bookmark=="main" && published.change!="" && st.description_length==0,"main moved, and the description went into the change")
    _,orgs=kai_call(a,api_kai_org,&Api_Kai_Org_Params{},Api_Kai_Orgs)
    testing.expect(t,len(orgs.orgs[0].repositories)==1 && !orgs.orgs[0].repositories[0].public && orgs.orgs[0].repositories[0].main!="","the project is a repository of the org, org only, on main")
    again:=Api_Kai_Publish_Params{org=org,visibility="public"}
    call,_=kai_call(a,api_kai_publish,&again,Api_Kai_Published)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS,"visibility goes only with the first publish")

    invite:=Api_Kai_Invite_Params{org="studio",role="writer"}
    invited:^Api_Kai_Invite
    call,invited=kai_call(a,api_kai_invite,&invite,Api_Kai_Invite)
    if !kai_ok(t,call,"invite") || !testing.expect(t,strings.has_prefix(invited.invite,"kai2") && len(invited.addresses)>0) {return}
    join:=Api_Kai_Join_Params{invite=strings.clone(invited.invite,context.temp_allocator)}
    joined:^Api_Kai_Joined
    call,joined=kai_call(b,api_kai_join,&join,Api_Kai_Joined)
    if !kai_ok(t,call,"join") {return}
    // The join runs on a thread of the agent: the frames go on.
    joining:=time.tick_now()
    for joined.stage=="waiting" {
        if !testing.expect(t,kai_tick(a,b,joining),"the join ends") {return}
        _,joined=kai_call(b,api_kai_join,&Api_Kai_Join_Params{},Api_Kai_Joined)
    }
    if !testing.expectf(t,joined.stage=="done" && joined.name=="studio","the join is done: %v",joined^) {return}
    testing.expect_value(t,projects_unpulled_count(b),1)
    folder:=fmt.tprintf("%s/pulled",base.test_folder(t,"kai-team-pull"))
    clone:=Api_Kai_Clone_Params{org="studio",repository=orgs.orgs[0].repositories[0].name,folder=folder}
    pulling:^Api_Kai_Clone
    call,pulling=kai_call(b,api_kai_clone,&clone,Api_Kai_Clone)
    if !kai_ok(t,call,"clone") {return}
    started:=time.tick_now()
    for pulling.stage=="waiting" {
        if !testing.expect(t,kai_tick(a,b,started),"the pull ends") {return}
        _,pulling=kai_call(b,api_kai_clone,&Api_Kai_Clone_Params{},Api_Kai_Clone)
    }
    testing.expectf(t,pulling.stage=="done" && pulling.chunks>0 && pulling.bytes>0,"the pull is done and says how much it took: %v",pulling^)
    text,_:=os.read_entire_file(fmt.tprintf("%s/a.txt",folder),context.temp_allocator)
    testing.expect_value(t,string(text),"a\n")
    _,peers:=kai_call(b,api_kai_peers,&Kai_None{},Api_Kai_Peers)
    testing.expect(t,peers.running && len(peers.peers)==1 && peers.peers[0].name=="ana","the launcher's agent is connected to the first editor")
}

// The Team view draws what was read, and reads again only when the agent
// moved: a frame that changes nothing allocates nothing; its buttons ask for
// kai.* methods, which run between frames.
@(test)
editor_kai_team_view_reads_only_when_the_agent_moves :: proc(t:^testing.T) {
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
    s.kai.state.tab=.Team
    kai_team_open(s)
    kai_panel_still(t,s)
    kai_panel_click(t,s,ui.id(&ctx,"kai_profile",0))
    method,params:=kai_panel_asked(s)
    testing.expectf(t,method=="kai.profile" && strings.contains(params,"\"name\""),"Save asks kai.profile: %s %s",method,params)
    p:=Api_Kai_Profile_Params{name="ana",device="mac"}
    kai_call(s,api_kai_profile,&p,Api_Kai_Orgs)
    o:=Api_Kai_Org_Params{new="studio"}
    kai_call(s,api_kai_org,&o,Api_Kai_Orgs)
    team:=s.kai.team
    testing.expect(t,team.running && len(team.view.orgs)==1,"the agent runs once the machine is in an org")
    started:=time.tick_now()
    for team.generation!=vcs.agent_generation(&team.agent) {
        kai_poll(s)
        if time.duration_seconds(time.tick_since(started))>5 {break}
    }
    generation:=team.generation
    kai_poll(s)
    testing.expect_value(t,team.generation,generation)
    kai_panel_stable(t,s,"Team")
    // An admin invites writers and readers, never a server; the invite shows
    // in a read-only field with Copy on its row, and one no other network
    // reaches says so.
    ui.id_push(&ctx,ui.id(&ctx,"org",0))
    make_invite,server,invite_text,invite_copy:=ui.id(&ctx,"kai_invite",0),ui.id(&ctx,"kai_invite_role",2),ui.id(&ctx,"kai_invite_text"),ui.id(&ctx,"kai_invite_copy")
    ui.id_pop(&ctx)
    _,has_server:=ui.widget_rect(&ctx,server)
    testing.expect(t,!has_server,"the Team view invites no server")
    if !kai_panel_click(t,s,make_invite) {return}
    method,params=kai_panel_asked(s)
    testing.expectf(t,method=="kai.invite" && team.invite_asked,"Make invite asks kai.invite: %s %s",method,params)
    x:=Api_Kai_Invite_Params{org="studio",role="writer"}
    call,_:=kai_call(s,api_kai_invite,&x,Api_Kai_Invite)
    if !kai_ok(t,call,"invite") {return}
    testing.expect(t,!team.invite_asked && team.invite_local && team.invite_length>0 && !team.invite_copied,"a loopback agent's invite reaches no other network")
    kai_panel_still(t,s);kai_panel_still(t,s)
    field,has_field:=ui.widget_rect(&ctx,invite_text)
    copied,has_copy:=ui.widget_rect(&ctx,invite_copy)
    testing.expectf(t,has_field && has_copy && abs(field.y-copied.y)<1 && field.x+field.w<=copied.x && copied.x+copied.w<=KAI_TAB+0.5,"the invite and Copy share a row inside the tab: %v %v",field,copied)
    invite:=strings.clone(string(team.invite[:team.invite_length]),context.temp_allocator)
    if !kai_panel_click(t,s,invite_text) {return}
    typing:=ui.Input{size={900,900},pointer_absent=true,keys_pressed={.Backspace},keys_repeated={.Backspace}}
    typing.text[0],typing.text_count='x',1
    kai_panel_still(t,s,typing)
    kai_panel_still(t,s,{size={900,900},pointer_absent=true,keys_pressed={.Enter}})
    testing.expect_value(t,string(team.invite[:team.invite_length]),invite)
    kai_panel_stable(t,s,"Team with an invite")
    s.kai.state.tab=.Changes
    kai_panel_stable(t,s,"Changes")
}

// The team methods refuse what does not fit and say why.
@(test)
editor_kai_team_methods_refuse_hostile_params :: proc(t:^testing.T) {
    k:=new(Kai_Fixture);defer free(k)
    if !kai_fixture_init(t,k,"kai-team-hostile") {return}
    defer kai_fixture_destroy(k)
    s:=&k.s
    s.kai.mesh_loopback=true
    testing.expect_value(t,kai_enable(s),"")
    profiles:=[]Api_Kai_Profile_Params{{name="",device="mac"},{name="ana",device=""},{name=strings.repeat("x",200,context.temp_allocator),device="mac"},{name="a\xff",device="mac"}}
    for &p in profiles {
        call,_:=kai_call(s,api_kai_profile,&p,Api_Kai_Orgs)
        testing.expectf(t,call.failed,"%q %q",p.name,p.device)
    }
    o:=Api_Kai_Org_Params{new="studio"}
    call,_:=kai_call(s,api_kai_org,&o,Api_Kai_Orgs)
    testing.expect(t,call.failed && strings.contains(call.error.message,"name yourself"),"an org needs the profile first")
    p:=Api_Kai_Profile_Params{name="ana",device="mac"}
    kai_call(s,api_kai_profile,&p,Api_Kai_Orgs)
    kai_call(s,api_kai_org,&o,Api_Kai_Orgs)
    orgs:=[]Api_Kai_Org_Params{{new="x",member="y"},{role="admin"},{org="studio",member="nobody",role="admin"},{org="studio",member="mac",role="boss"},{org="nowhere",member="mac",role="admin"}}
    for &x in orgs {
        call,_=kai_call(s,api_kai_org,&x,Api_Kai_Orgs)
        testing.expectf(t,call.failed,"%v",x)
    }
    invites:=[]Api_Kai_Invite_Params{{org="nowhere"},{org="studio",role="boss"}}
    for &x in invites {
        call,_=kai_call(s,api_kai_invite,&x,Api_Kai_Invite)
        testing.expectf(t,call.failed,"%v",x)
    }
    joins:=[]Api_Kai_Join_Params{{invite="kai2!!!"},{invite="kai2aaaa"}}
    for &x in joins {
        call,_=kai_call(s,api_kai_join,&x,Api_Kai_Joined)
        testing.expectf(t,call.failed,"%q",x.invite)
    }
    joined:^Api_Kai_Joined
    call,joined=kai_call(s,api_kai_join,&Api_Kai_Join_Params{},Api_Kai_Joined)
    testing.expect(t,!call.failed && joined.stage=="none","with no invite it says no join ran")
    logins:=[]Api_Kai_Web_Login_Params{{server="127.0.0.1:7350"},{server="127.0.0.1:7350",name="ana",password="short"}}
    for &x in logins {
        call,_=kai_call(s,api_kai_web_login,&x,Api_Kai_Task)
        testing.expectf(t,call.failed,"%v",x.server)
    }
    publishes:=[]Api_Kai_Publish_Params{{},{org="studio",visibility="everyone"},{org="studio",bookmark="no name\x00"}}
    for &x in publishes {
        call,_=kai_call(s,api_kai_publish,&x,Api_Kai_Published)
        testing.expectf(t,call.failed,"%v",x)
    }
    clones:=[]Api_Kai_Clone_Params{{org="studio",repository="nothing"},{org="nowhere",repository="game"}}
    for &x in clones {
        call,_=kai_call(s,api_kai_clone,&x,Api_Kai_Clone)
        testing.expectf(t,call.failed,"%v",x)
    }
}

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
    testing.expect(t,!os.exists(fmt.tprintf("%s/%s",s.store.root,vcs.IDENTITY_FILE)),"nor this machine's identity")
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

    // kai.peers: in no org, no agent and no peers.
    peers:^Api_Kai_Peers
    call,peers=kai_call(s,api_kai_peers,&none,Api_Kai_Peers)
    if !kai_ok(t,call,"kai.peers") {return}
    testing.expectf(t,!peers.running && len(peers.peers)==0,"%v",peers^)
}
