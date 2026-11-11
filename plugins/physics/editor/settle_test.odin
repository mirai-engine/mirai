package physics_editor

import "core:fmt"
import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import phys "plugins:physics/runtime"

@(private)
@(test_world,host="Settle_Test_Shared",editor="Settle_Test_Editor")
Settle_Test_World :: struct {
    using world:Test_World,
    using physics:phys.Test_Physics,
    ids:core.Table(core.Id),
    time:core.Time,
    id:core.World_Id,
}

@(private)
Settle_Test_Shared :: struct {
    meshes:phys.Collider_Meshes,
    problems:core.By_World(core.Problems),
}

@(private) Settle_Test_Editor :: struct {simulation:Physics_Simulation}

// physics_step as the editor loop of a generated world calls it: what step_world runs.
@(private="file")
settle_test_physics :: proc(data,shared,editor,app:rawptr) {
    w:=cast(^Settle_Test_World)data
    a:=cast(^host.App)app
    phys.physics_step(&w.state,core.ref(&w.settings),&w.requests,&w.events,&(cast(^Settle_Test_Shared)shared).meshes,a,w.time,
        core.read(&w.rigids),core.read(&w.colliders),core.read(&w.characters),core.read(&w.moves),&w.joints,core.read(&w.statics),core.read(&w.parents),core.read(&w.names),
        &w.transforms,&w.bodies,core.read(&w.replicas),&w.character_states,&w.joint_states,{},nil,{},{},nil,nil,host.app_world_storage(a,data,core.Problems),{},{},{},{},{},{},{},{},{})
    core.settle(a.info,data,nil)
}

@(private="file")
Settle_Test :: struct {
    world:Settle_Test_World,
    shared:Settle_Test_Shared,
    app:host.App,
    info:core.World_Info,
    steps:[1]core.Step_Info,
    order:[1]i32,
    session:editor.Session,
    edits:history.Edits,
    selection:history.Selection,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    document:editor.Document,
    tool:Drop_Tool,
}

@(private="file")
settle_test_open :: proc(t:^testing.T,f:^Settle_Test) -> bool {
    f.info=test_info(t,Settle_Test_World) or_return
    f.steps={{name="physics_step",library="physics",call=settle_test_physics}}
    f.info.steps=f.steps[:]
    f.info.order[.Editor][.Fixed]=f.order[:]
    if !testing.expect(t,core.world_init(&f.info,.World,&f.world,context.allocator)) {
        test_info_destroy(&f.info)
        return false
    }
    f.world.settings={bodies=32,shapes=64,contacts=256,joints=8,characters=2}
    f.app={info=&f.info,shared=&f.shared,allocator=context.allocator,tick_dt=1.0/60}
    f.session={
        app=&f.app,info=&f.info,edit_world=&f.world,edits=&f.edits,selection=&f.selection,
        viewport=&f.viewport,gui=&f.gui,document=&f.document,
    }
    return true
}

@(private="file")
settle_test_close :: proc(f:^Settle_Test) {
    drop_free(&f.tool)
    history.edits_free(&f.edits)
    delete(f.selection.entities)
    core.world_destroy(&f.info,.World,&f.world)
    core.world_destroy(&f.info,.Shared,&f.shared)
    delete(f.app.worlds)
    test_info_destroy(&f.info)
}

@(private="file")
settle_test_box :: proc(f:^Settle_Test,name:string,position,scale:[3]f32,collider:bool,rigid:Maybe(phys.Rigid_Body)=nil) -> core.Entity {
    e:=core.create(&f.world.entities)
    core.add(&f.world.ids,e,core.Id{base.Entity_Id(e)})
    core.add(&f.world.names,e,core.name_make(name))
    core.add(&f.world.transforms,e,core.Transform{position,1,scale})
    core.add(&f.world.statics,e,erender.Mesh_Renderer{shape=.Cube})
    if collider {core.add(&f.world.colliders,e,phys.collider_box({0.5,0.5,0.5}))}
    if body,given:=rigid.?;given {core.add(&f.world.rigids,e,body)}
    core.settle(&f.info,&f.world,nil)
    return e
}

// Two boxes dropped onto a floor and onto each other come to rest, as one undo step; the floor,
// a dynamic body in the air and the document's components stay as they were.
@(test)
settle_drops_only_the_given_entities_to_rest_as_one_undo_step :: proc(t:^testing.T) {
    f:Settle_Test
    if !settle_test_open(t,&f) {return}
    defer settle_test_close(&f)
    floor:=settle_test_box(&f,"Floor",{0,-0.5,0},{20,1,20},true,phys.RIGID_BODY_DYNAMIC)
    hanging:=settle_test_box(&f,"Hanging",{5,4,0},{1,1,1},true,phys.RIGID_BODY_DYNAMIC)
    low:=settle_test_box(&f,"Low",{0,1,0},{1,1,1},true)
    high:=settle_test_box(&f,"High",{0.1,3,0},{1,1,1},true,phys.RIGID_BODY_STATIC)
    w:=editor.edited_world(&f.session)
    history.edits_reset(&f.edits,w)
    before_low,before_high:=editor.entity_world(w,low),editor.entity_world(w,high)
    rested:[2]bool
    ran,at,problem:=editor.simulate_until_rest(&f.session,{low,high},SETTLE_TICKS,rested[:])
    if !testing.expectf(t,problem=="","%v: %s",at,problem) {return}
    testing.expectf(t,rested==[2]bool{true,true} && ran<SETTLE_TICKS,"rested %v after %d ticks",rested,ran)
    low_pose,high_pose:=editor.entity_world(w,low),editor.entity_world(w,high)
    testing.expectf(t,abs(low_pose.position.y-0.5)<0.03,"low at %v",low_pose.position)
    testing.expectf(t,abs(high_pose.position.y-1.5)<0.05,"high at %v",high_pose.position)
    testing.expect_value(t,editor.entity_world(w,floor).position,[3]f32{0,-0.5,0})
    testing.expect_value(t,editor.entity_world(w,hanging).position,[3]f32{5,4,0})
    testing.expect(t,!core.has(&f.world.rigids,low))
    body,_:=core.get(&f.world.rigids,high)
    testing.expect_value(t,body.type,phys.Body_Type.Static)
    testing.expect_value(t,f.edits.cursor,1)
    testing.expect_value(t,host.app_world_count(&f.app),0)
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,editor.entity_world(w,low),before_low)
    testing.expect_value(t,editor.entity_world(w,high),before_high)
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect_value(t,editor.entity_world(w,low),low_pose)
    testing.expect_value(t,editor.entity_world(w,high),high_pose)
}

// What cannot settle is refused with what failed, with the document and its history as they were;
// a tick limit ends a fall before it rests and says why.
@(test)
settle_refuses_what_cannot_fall_and_says_why_a_fall_did_not_rest :: proc(t:^testing.T) {
    f:Settle_Test
    if !settle_test_open(t,&f) {return}
    defer settle_test_close(&f)
    _=settle_test_box(&f,"Floor",{0,-0.5,0},{20,1,20},true)
    falling:=settle_test_box(&f,"Falling",{0,5,0},{1,1,1},true)
    bare:=settle_test_box(&f,"Bare",{2,5,0},{1,1,1},false)
    flat:=settle_test_box(&f,"Flat",{4,5,0},{1,1,1},false)
    mesh:=phys.COLLIDER_DEFAULT;mesh.kind=.Mesh
    core.add(&f.world.colliders,flat,mesh)
    gone:=settle_test_box(&f,"Gone",{6,5,0},{1,1,1},true)
    core.destroy(&f.world.entities,gone)
    core.settle(&f.info,&f.world,nil)
    w:=editor.edited_world(&f.session)
    history.edits_reset(&f.edits,w)
    Case :: struct {name:string,moving:[]core.Entity,ticks:int,mode:editor.Mode,at:int}
    cases:=[?]Case{
        {"no entities",{},SETTLE_TICKS,.Edit,-1},
        {"a destroyed handle",{falling,gone},SETTLE_TICKS,.Edit,1},
        {"an entity without a body",{bare},SETTLE_TICKS,.Edit,0},
        {"a body without mass",{flat},SETTLE_TICKS,.Edit,0},
        {"given twice",{falling,falling},SETTLE_TICKS,.Edit,1},
        {"no ticks",{falling},0,.Edit,-1},
        {"from Play",{falling},SETTLE_TICKS,.Play,-1},
    }
    count:=f.world.entities.alive
    for c in cases {
        f.session.mode=c.mode
        rested:[2]bool
        _,at,problem:=editor.simulate_until_rest(&f.session,c.moving,c.ticks,rested[:len(c.moving)])
        testing.expectf(t,problem!="" && at==c.at,"%s: at %d, %q",c.name,at,problem)
    }
    f.session.mode=.Edit
    testing.expect_value(t,f.world.entities.alive,count)
    testing.expect_value(t,f.edits.cursor,0)
    testing.expect_value(t,editor.entity_world(w,falling).position,[3]f32{0,5,0})
    testing.expect_value(t,host.app_world_count(&f.app),0)

    method:=api.Method{params_id=Settle_Params,result_id=Settle_Result}
    params:=Settle_Params{ticks=2}
    fmt.bprintf(params.entities[0][:],"%016x",u64(editor.api_entity_id(w,falling)))
    result:Settle_Result
    call:=api.Call{method=&method,params=&params,result=&result,raw=`{"entities":["x"],"ticks":2}`,allocator=context.temp_allocator}
    api_settle(&f.session,&call)
    if !testing.expectf(t,!call.failed,"%s",call.error.message) {return}
    testing.expect(t,result.settled[0].id==editor.api_entity_id(w,falling) && !result.settled[0].rested && result.ticks==2)
    testing.expect(t,base.text_get(result.reason[:])!="")
    testing.expect(t,result.settled[0].position.y<5 && result.settled[0].position.y>4.9)
    testing.expect_value(t,f.edits.cursor,1)

    params.entities[0]={}
    call=api.Call{method=&method,params=&params,result=&result,raw=`{"entities":[]}`,allocator=context.temp_allocator}
    api_settle(&f.session,&call)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS)
}

// Every component row of the World of f, compared byte by byte with snapshot: what Cancel leaves.
@(private="file")
settle_test_same :: proc(t:^testing.T,f:^Settle_Test,snapshot:rawptr) -> bool {
    w,was:=core.world_ref(&f.world,&f.info),core.world_ref(snapshot,&f.info)
    if !testing.expect_value(t,f.world.entities.alive,core.world_entities(was).alive) {return false}
    for &table in f.info.tables {
        if table.place!=.World || !table.flat {continue}
        now,then:=core.world_table_at(w,&table),core.world_table_at(was,&table)
        if !testing.expectf(t,now.on==then.on && len(now.entities)==len(then.entities),"%s has other rows",table.name) {return false}
        for e,row in now.entities {
            same:=e==then.entities[row] && mem.compare_ptrs(core.raw_value(now,table.info,row),core.raw_value(then,table.info,row),table.info.size)==0
            if !testing.expectf(t,same,"%s differs at row %d",table.name,row) {return false}
        }
    }
    return true
}

// The Drop tool: two meshes dropped at once and stepped over frames end where physics.settle puts
// the same meshes, and Confirm keeps them as one undo step; Cancel leaves every row as it was.
@(test)
drop_gesture_settles_live_as_physics_settle_and_cancel_leaves_the_document :: proc(t:^testing.T) {
    live,once:=new(Settle_Test),new(Settle_Test)
    defer {free(live);free(once)}
    poses:[2][2]core.Transform
    for f,run in ([2]^Settle_Test{live,once}) {
        if !settle_test_open(t,f) {return}
        _=settle_test_box(f,"Floor",{0,-0.5,0},{20,1,20},true)
        w:=editor.edited_world(&f.session)
        history.edits_reset(&f.edits,w)
        editor.tool_set(&f.session,DROP_TOOL,true)
        f.tool={ready=true,mesh={shape=.Cube},scale=1,speed=5,height=1,bounds={{-0.5,-0.5,-0.5},{0.5,0.5,0.5}},measured=true}
        if !testing.expect_value(t,drop_one(&f.session,&f.tool,{0,0,0}),"") {return}
        if !testing.expect_value(t,drop_one(&f.session,&f.tool,{0.1,1.5,0}),"") {return}
        moving:=f.tool.moving[:2]
        if run==0 {
            for frame:=0;!f.tool.resting && frame<600;frame+=1 {testing.expect(t,drop_advance(&f.session,&f.tool,1.0/30))}
            testing.expect(t,f.tool.resting && f.tool.ticks<SETTLE_TICKS)
            testing.expect_value(t,f.edits.cursor,0)
            testing.expect(t,drop_end(&f.session,&f.tool,true))
            testing.expect_value(t,f.edits.cursor,1)
        } else {
            testing.expect(t,drop_end(&f.session,&f.tool,true))
            rested:[2]bool
            _,_,problem:=editor.simulate_until_rest(&f.session,moving,SETTLE_TICKS,rested[:])
            testing.expectf(t,problem=="" && rested==[2]bool{true,true},"%s",problem)
        }
        for e,i in moving {poses[run][i]=core.from_math(editor.entity_world(w,e))}
    }
    defer {settle_test_close(live);settle_test_close(once)}
    for i in 0..<2 {
        a,b:=poses[0][i],poses[1][i]
        testing.expectf(t,abs(a.position.x-b.position.x)+abs(a.position.y-b.position.y)+abs(a.position.z-b.position.z)<1e-3,"mesh %d: live %v, settled %v",i,a.position,b.position)
    }
    testing.expectf(t,abs(poses[0][0].position.y-0.5)<0.03 && abs(poses[0][1].position.y-1.5)<0.05,"%v",poses[0])

    f:=live
    w:=editor.edited_world(&f.session)
    snapshot:=host.app_world_create(&f.app)
    defer host.app_world_free(&f.app,snapshot)
    testing.expect(t,core.world_copy(&f.info,snapshot,&f.world))
    testing.expect_value(t,drop_one(&f.session,&f.tool,{3,0,0}),"")
    for _ in 0..<10 {testing.expect(t,drop_advance(&f.session,&f.tool,1.0/30))}
    testing.expect(t,editor.entity_world(w,f.tool.moving[0]).position.y<1.5)
    testing.expect(t,drop_end(&f.session,&f.tool,false))
    core.settle(&f.info,&f.world,nil)
    settle_test_same(t,f,snapshot)
    testing.expect_value(t,f.edits.cursor,1)
    testing.expect_value(t,host.app_world_count(&f.app),1)
}
