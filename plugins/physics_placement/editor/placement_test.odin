package physics_placement

import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import destruct "plugins:destruct/runtime"
import phys "plugins:physics/runtime"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

Placement_Test_World :: struct {
    using world:core.Test_World,
    using physics:phys.Test_Physics,
    ids:core.Table(core.Id),
    destructibles:core.Table(destruct.Destructible),
    gameplay_ticks:int,
    time:core.Time,
    id:core.World_Id,
}

Placement_Test_Shared :: struct {
    meshes:phys.Collider_Meshes,
    problems:core.By_World(core.Problems),
}

// physics_step as the editor loop of a generated world calls it: what step_world runs.
placement_test_physics :: proc(data,shared,editor,app:rawptr) {
    w:=cast(^Placement_Test_World)data
    a:=cast(^host.App)app
    phys.physics_step(&w.state,core.ref(&w.settings),&w.requests,&w.events,&(cast(^Placement_Test_Shared)shared).meshes,a,w.time,
        core.read(&w.rigids),core.read(&w.colliders),core.read(&w.characters),core.read(&w.moves),&w.joints,core.read(&w.statics),core.read(&w.parents),core.read(&w.names),
        &w.transforms,&w.bodies,core.read(&w.replicas),&w.character_states,&w.joint_states,{},nil,{},{},nil,nil,host.app_world_storage(a,data,core.Problems),{},{},{},{},{},{})
    core.settle(a.info,data,nil)
}

placement_test_game :: proc(world,shared,editor:rawptr,app:rawptr) {
    (cast(^Placement_Test_World)world).gameplay_ticks+=1
}

Placement_Test :: struct {
    world:Placement_Test_World,
    shared:Placement_Test_Shared,
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
    tool:Physics_Placement,
}

placement_test_open :: proc(t:^testing.T,f:^Placement_Test) -> bool {
    f.info=core.test_info(t,Placement_Test_World,Placement_Test_Shared,core.Test_None,destruct.test_types) or_return
    f.steps={{name="physics_step",library="physics",call=placement_test_physics}}
    f.info.steps=f.steps[:]
    f.info.order[.Editor][.Fixed]=f.order[:]
    f.info.loops[.Game][.Fixed]=placement_test_game
    if !testing.expect(t,core.world_init(&f.info,.World,&f.world,context.allocator)) {
        core.test_info_destroy(&f.info)
        return false
    }
    f.world.settings={bodies=32,shapes=64,contacts=256,joints=8,characters=2}
    f.app={info=&f.info,shared=&f.shared,allocator=context.allocator}
    f.session={
        app=&f.app,info=&f.info,edit_world=&f.world,edits=&f.edits,selection=&f.selection,
        viewport=&f.viewport,gui=&f.gui,document=&f.document,
    }
    return true
}

placement_test_close :: proc(f:^Placement_Test) {
    physics_placement_free(&f.tool)
    history.edits_free(&f.edits)
    delete(f.selection.entities)
    core.world_destroy(&f.info,.World,&f.world)
    core.world_destroy(&f.info,.Shared,&f.shared)
    delete(f.app.worlds)
    core.test_info_destroy(&f.info)
}

placement_test_box :: proc(f:^Placement_Test,name:string,position,scale:[3]f32,collider:bool) -> core.Entity {
    e:=core.create(&f.world.entities)
    core.add(&f.world.ids,e,core.Id{base.Entity_Id(e)})
    core.add(&f.world.names,e,core.name_make(name))
    core.add(&f.world.transforms,e,core.Transform{position,1,scale})
    core.add(&f.world.statics,e,erender.Mesh_Renderer{shape=.Cube})
    if collider {core.add(&f.world.colliders,e,phys.collider_box({0.5,0.5,0.5}))}
    core.settle(&f.info,&f.world,nil)
    return e
}

@(test)
placement_drops_settle_without_gameplay_and_commit_as_one_undo :: proc(t:^testing.T) {
    f:Placement_Test
    if !placement_test_open(t,&f) {return}
    defer placement_test_close(&f)
    floor:=placement_test_box(&f,"Floor",{0,-0.5,0},{20,1,20},true)
    source:=placement_test_box(&f,"Book",{0,2,0},{0.5,0.1,0.7},false)
    core.add(&f.world.rigids,floor,phys.RIGID_BODY_DYNAMIC)
    core.settle(&f.info,&f.world,nil)
    w:=editor.edited_world(&f.session)
    history.edits_reset(&f.edits,w)
    history.selection_set(&f.selection,{source})
    testing.expect(t,placement_start(&f.session,&f.tool,{mesh={shape=.Cube},scale={0.5,0.1,0.7},height=1,point={3,0,0}}))
    for _ in 0..<60 {testing.expect(t,placement_update(&f.tool,PLACEMENT_DT))}
    bounds,_:=placement_box(f.app.assets,erender.Mesh_Renderer{shape=.Cube})
    testing.expect(t,placement_drop(&f.tool,{mesh={shape=.Cube},scale={0.5,0.1,0.7},height=1,point={3,0,0}},bounds))
    testing.expect_value(t,f.tool.count,2)
    first,second:=f.tool.roots[0],f.tool.roots[1]
    for _ in 0..<600 {testing.expect(t,placement_update(&f.tool,PLACEMENT_DT))}
    first_pose:=editor.entity_world(w,first)
    second_pose:=editor.entity_world(w,second)
    testing.expect(t,first_pose.position.y>0.02 && first_pose.position.y<0.08)
    testing.expect(t,second_pose.position.y>0.1 && second_pose.position.y<0.2)
    testing.expect_value(t,editor.entity_world(w,source).position,[3]f32{0,2,0})
    testing.expect_value(t,editor.entity_world(w,floor).position,[3]f32{0,-0.5,0})
    testing.expect_value(t,f.world.gameplay_ticks,0)
    testing.expect_value(t,(cast(^Placement_Test_World)f.tool.preview.data).gameplay_ticks,0)
    testing.expect(t,!core.has(&f.world.rigids,first) && !core.has(&f.world.colliders,first))
    testing.expect_value(t,f.edits.cursor,0)
    testing.expect(t,placement_confirm(&f.tool))
    testing.expect_value(t,f.edits.cursor,1)
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,!core.alive(&f.world.entities,first) && !core.alive(&f.world.entities,second))
    testing.expect_value(t,history.selection_active(&f.selection),source)
    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect_value(t,editor.entity_world(w,first),first_pose)
    testing.expect_value(t,editor.entity_world(w,second),second_pose)
    testing.expect_value(t,host.app_world_count(&f.app),0)
}

@(test)
placement_speed_is_independent_of_frame_rate_and_stops_on_release :: proc(t:^testing.T) {
    for fps in ([4]int{15,30,60,144}) {
        tool:=Physics_Placement{speed=30,held=true,press=true}
        count:=placement_due(&tool,1/f32(fps))
        tool.press=false
        for _ in 0..<fps {count+=placement_due(&tool,1/f32(fps))}
        testing.expect_value(t,count,31)
        tool.held=false
        testing.expect_value(t,placement_due(&tool,1),0)
        tool.held,tool.press=true,true
        testing.expect_value(t,placement_due(&tool,1/f32(fps)),1)
    }
}

@(test)
placement_cancel_and_tool_release_restore_the_document_and_free_the_preview :: proc(t:^testing.T) {
    f:Placement_Test
    if !placement_test_open(t,&f) {return}
    defer placement_test_close(&f)
    _=placement_test_box(&f,"Floor",{0,-0.5,0},{20,1,20},true)
    source:=placement_test_box(&f,"Book",{0,3,0},{1,1,1},true)
    w:=editor.edited_world(&f.session)
    history.edits_reset(&f.edits,w)
    desc:=Placement_Desc{mesh={shape=.Cube},scale={1,1,1},point={3,0,0},height=3}
    testing.expect(t,placement_start(&f.session,&f.tool,desc))
    placed:=f.tool.roots[0]
    for _ in 0..<30 {testing.expect(t,placement_update(&f.tool,PLACEMENT_DT))}
    testing.expect(t,editor.entity_world(w,placed).position.y<3.5)
    placement_cancel(&f.tool)
    testing.expect(t,!core.alive(&f.world.entities,placed))
    testing.expect_value(t,editor.entity_world(w,source).position.y,f32(3))
    testing.expect_value(t,f.edits.cursor,0)
    testing.expect_value(t,host.app_world_count(&f.app),0)
    testing.expect(t,placement_start(&f.session,&f.tool,desc))
    copy:=f.tool.roots[0]
    editor.tool_set(&f.session,"paint",true)
    testing.expect(t,!placement_update(&f.tool,PLACEMENT_DT))
    testing.expect(t,!core.alive(&f.world.entities,copy))
    testing.expect_value(t,host.app_world_count(&f.app),0)
    testing.expect_value(t,f.edits.cursor,0)
    testing.expect_value(t,history.selection_active(&f.selection),core.NONE)
}

@(test)
placement_uses_the_chosen_mesh_and_rejects_invalid_geometry_atomically :: proc(t:^testing.T) {
    f:Placement_Test
    if !placement_test_open(t,&f) {return}
    defer placement_test_close(&f)
    floor:=placement_test_box(&f,"Floor",{0,-0.5,0},{20,1,20},false)
    core.add(&f.world.destructibles,floor,destruct.destructible())
    root:=core.create(&f.world.entities)
    core.add(&f.world.ids,root,core.Id{base.Entity_Id(root)})
    core.add(&f.world.names,root,core.name_make("Books"))
    core.add(&f.world.transforms,root,core.Transform{{0,3,0},1,{1,1,1}})
    child:=placement_test_box(&f,"Book",{0,0,0},{1,1,1},false)
    core.add(&f.world.parents,child,core.Parent{root,0})
    core.settle(&f.info,&f.world,nil)
    w:=editor.edited_world(&f.session)
    history.edits_reset(&f.edits,w)
    history.selection_set(&f.selection,{root,child})
    desc:=Placement_Desc{mesh={shape=.Sphere},scale={1,1,1},point={4,0,0},height=1}
    testing.expect(t,placement_start(&f.session,&f.tool,desc))
    placed:=f.tool.roots[0]
    for _ in 0..<180 {testing.expect(t,placement_update(&f.tool,PLACEMENT_DT))}
    testing.expect(t,abs(editor.entity_world(w,placed).position.y-0.5)<0.02)
    mesh,found:=editor.entity_get(w,placed,erender.Mesh_Renderer)
    testing.expect(t,found && mesh.shape==.Sphere)
    testing.expect_value(t,editor.entity_world(w,root).position.y,f32(3))
    testing.expect_value(t,editor.entity_local(w,child).position,[3]f32{})
    placement_cancel(&f.tool)
    count,cursor:=f.world.entities.alive,f.edits.cursor
    desc.mesh={}
    testing.expect(t,!placement_start(&f.session,&f.tool,desc))
    testing.expect_value(t,f.world.entities.alive,count)
    testing.expect_value(t,f.edits.cursor,cursor)
    testing.expect_value(t,history.selection_active(&f.selection),child)
    testing.expect(t,!f.edits.open)
    testing.expect_value(t,host.app_world_count(&f.app),0)
}

@(test)
placement_api_drops_settle_and_confirm_within_the_call :: proc(t:^testing.T) {
    f:Placement_Test
    if !placement_test_open(t,&f) {return}
    defer placement_test_close(&f)
    floor:=placement_test_box(&f,"Floor",{0,-0.5,0},{20,1,20},true)
    w:=editor.edited_world(&f.session)
    history.edits_reset(&f.edits,w)
    history.selection_set(&f.selection,{floor})
    method:=api.Method{params_id=Drop_Params,result_id=Drop_Result}
    params:=Drop_Params{interval=0.2,time=PLACEMENT_TICKS*PLACEMENT_DT}
    params.drops[0]={shape=.Cube,point={3,0,0},height=1,scale={0.5,0.1,0.7}}
    params.drops[1]=params.drops[0]
    result:Drop_Result
    call:=api.Call{method=&method,params=&params,result=&result,raw=`{"drops":[{"point":[3,0,0]},{"point":[3,0,0]}]}`,allocator=context.temp_allocator}
    placement_api_run(&f.session,&call,&f.tool)
    if !testing.expectf(t,!call.failed,"%s",call.error.message) {return}
    first,second:=result.placed[0],result.placed[1]
    testing.expect(t,first.id!=0 && second.id!=0 && first.id!=second.id && result.placed[2].id==0)
    testing.expectf(t,first.rested && second.rested && result.time<PLACEMENT_TICKS*PLACEMENT_DT,"rested %v %v after %v s",first.rested,second.rested,result.time)
    testing.expect(t,first.position.y>0.02 && first.position.y<0.08)
    testing.expect(t,second.position.y>first.position.y+0.05 && second.position.y<0.2)
    testing.expect_value(t,first.scale,[3]f32{0.5,0.1,0.7})
    testing.expect_value(t,f.edits.cursor,1)
    testing.expect(t,!f.edits.preview && !f.edits.open)
    testing.expect(t,!placement_active(&f.tool) && f.tool.preview.data==nil)
    testing.expect_value(t,host.app_world_count(&f.app),0)
    testing.expect(t,!editor.tool_on(&f.session,PLACEMENT_TOOL))
    placed:=core.entity_of(&f.world.entities,first.id)
    testing.expect_value(t,editor.entity_world(w,placed).position,first.position)
    testing.expect(t,!core.has(&f.world.rigids,placed) && !core.has(&f.world.colliders,placed))
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,!core.alive(&f.world.entities,placed))
    testing.expect_value(t,history.selection_active(&f.selection),floor)

    // A drop without geometry, a call from Play and an empty list change nothing and leave no preview.
    count:=f.world.entities.alive
    params.drops[1].shape=.None
    invalid:=api.Call{method=&method,params=&params,result=&result,raw=call.raw,allocator=context.temp_allocator}
    placement_api_run(&f.session,&invalid,&f.tool)
    testing.expect(t,invalid.failed && invalid.error.code==api.INVALID_PARAMS)
    params.drops[1].shape=.Cube
    f.session.mode=.Play
    playing:=api.Call{method=&method,params=&params,result=&result,raw=call.raw,allocator=context.temp_allocator}
    placement_api_run(&f.session,&playing,&f.tool)
    testing.expect(t,playing.failed && playing.error.code==api.SERVER_ERROR)
    f.session.mode=.Edit
    empty:=api.Call{method=&method,params=&params,result=&result,raw=`{"drops":[]}`,allocator=context.temp_allocator}
    placement_api_run(&f.session,&empty,&f.tool)
    testing.expect(t,empty.failed && empty.error.code==api.INVALID_PARAMS)
    testing.expect_value(t,f.world.entities.alive,count)
    testing.expect_value(t,f.edits.cursor,0)
    testing.expect(t,!f.edits.preview && !f.edits.open)
    testing.expect_value(t,host.app_world_count(&f.app),0)
}

