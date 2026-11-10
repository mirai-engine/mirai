package physics_placement

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import destruct "plugins:destruct/runtime"
import phys "plugins:physics/runtime"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

Placement_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    rigids:core.Table(phys.Rigid_Body),
    colliders:core.Table(phys.Collider),
    characters:core.Table(phys.Character),
    moves:core.Table(phys.Character_Move),
    joints:core.Table(phys.Joint),
    statics:core.Table(erender.Mesh_Renderer),
    parents:core.Table(core.Parent),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    bodies:core.Table(core.Motion),replicas:core.Table(core.Pose_Target),
    character_states:core.Table(phys.Character_State),
    joint_states:core.Table(phys.Joint_State),
    destructibles:core.Table(destruct.Destructible),
    physics:phys.Physics_State,
    settings:phys.Physics_Settings,
    requests:phys.Body_Requests,
    events:phys.Physics_Events,
    gameplay_ticks:int,
    time:core.Time,
    problems:core.Problems,
}

// physics_step as the editor loop of a generated world calls it: what step_world runs.
placement_test_physics :: proc(data,shared,editor,app:rawptr) {
    w:=cast(^Placement_Test_World)data
    phys.physics_step(&w.physics,core.ref(&w.settings),&w.requests,&w.events,cast(^phys.Collider_Meshes)shared,cast(^host.App)app,w.time,
        core.read(&w.rigids),core.read(&w.colliders),core.read(&w.characters),core.read(&w.moves),&w.joints,core.read(&w.statics),core.read(&w.parents),core.read(&w.names),
        &w.transforms,&w.bodies,core.read(&w.replicas),&w.character_states,&w.joint_states,{},nil,{},{},nil,nil,&w.problems,{},{},{},{},{},{})
    placement_test_settle(data,shared,editor)
}

placement_test_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^Placement_Test_World)data
    core.entities_init(&w.entities,allocator)
    core.table_init(&w.ids,"Id",allocator)
    core.table_init(&w.rigids,"Rigid_Body",allocator)
    core.table_init(&w.colliders,"Collider",allocator)
    core.table_init(&w.characters,"Character",allocator)
    core.table_init(&w.moves,"Character_Move",allocator)
    core.table_init(&w.joints,"Joint",allocator)
    core.table_init(&w.statics,"Mesh_Renderer",allocator)
    core.table_init(&w.parents,"Parent",allocator)
    core.table_init(&w.names,"Name",allocator)
    core.table_init(&w.transforms,"Transform",allocator)
    core.table_init(&w.bodies,"Motion",allocator)
    core.table_init(&w.character_states,"Character_State",allocator)
    core.table_init(&w.joint_states,"Joint_State",allocator)
    core.table_init(&w.destructibles,"Destructible",allocator)
    w.settings={bodies=32,shapes=64,contacts=256,joints=8,characters=2}
    return len(w.entities.generation)>0
}

placement_test_destroy :: proc(data:rawptr) {
    w:=cast(^Placement_Test_World)data
    phys.state_destroy(&w.physics)
    core.table_destroy(&w.ids)
    core.table_destroy(&w.rigids)
    core.table_destroy(&w.colliders)
    core.table_destroy(&w.characters)
    core.table_destroy(&w.moves)
    core.table_destroy(&w.joints)
    core.table_destroy(&w.statics)
    core.table_destroy(&w.parents)
    core.table_destroy(&w.names)
    core.table_destroy(&w.transforms)
    core.table_destroy(&w.bodies)
    core.table_destroy(&w.character_states)
    core.table_destroy(&w.joint_states)
    core.table_destroy(&w.destructibles)
    core.entities_destroy(&w.entities)
    delete(w.requests.queue.items)
    delete(w.events.contact_begin.items);delete(w.events.contact_end.items)
    delete(w.events.overlap_begin.items);delete(w.events.overlap_end.items)
    delete(w.events.sleep.items);delete(w.events.wake.items);delete(w.events.joint_break.items)
}

placement_test_settle :: proc(data,shared,editor:rawptr) {
    w:=cast(^Placement_Test_World)data
    core.table_settle(&w.ids,&w.entities)
    core.table_settle(&w.rigids,&w.entities)
    core.table_settle(&w.colliders,&w.entities)
    core.table_settle(&w.characters,&w.entities)
    core.table_settle(&w.moves,&w.entities)
    core.table_settle(&w.joints,&w.entities)
    core.table_settle(&w.statics,&w.entities)
    core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.names,&w.entities)
    core.table_settle(&w.transforms,&w.entities)
    core.table_settle(&w.bodies,&w.entities)
    core.table_settle(&w.character_states,&w.entities)
    core.table_settle(&w.joint_states,&w.entities)
    core.table_settle(&w.destructibles,&w.entities)
    core.entities_settle(&w.entities)
}

placement_test_copy :: proc(dst,src:rawptr) -> bool {
    d,s:=cast(^Placement_Test_World)dst,cast(^Placement_Test_World)src
    if !core.entities_copy(&d.entities,&s.entities) || !core.table_copy(&d.ids,&s.ids) || !core.table_copy(&d.rigids,&s.rigids) || !core.table_copy(&d.colliders,&s.colliders) || !core.table_copy(&d.characters,&s.characters) || !core.table_copy(&d.moves,&s.moves) || !core.table_copy(&d.joints,&s.joints) || !core.table_copy(&d.statics,&s.statics) || !core.table_copy(&d.parents,&s.parents) || !core.table_copy(&d.names,&s.names) || !core.table_copy(&d.transforms,&s.transforms) || !core.table_copy(&d.bodies,&s.bodies) || !core.table_copy(&d.character_states,&s.character_states) || !core.table_copy(&d.joint_states,&s.joint_states) || !core.table_copy(&d.destructibles,&s.destructibles) || !phys.state_copy(&d.physics,&s.physics) {return false}
    d.settings=s.settings
    d.gameplay_ticks=s.gameplay_ticks
    return true
}

placement_test_swap :: proc(a,b:rawptr) {
    a,b:=(^Placement_Test_World)(a),(^Placement_Test_World)(b)
    a.entities,b.entities=b.entities,a.entities
    core.table_swap(&a.ids,&b.ids);core.table_swap(&a.rigids,&b.rigids);core.table_swap(&a.colliders,&b.colliders);core.table_swap(&a.characters,&b.characters);core.table_swap(&a.moves,&b.moves);core.table_swap(&a.joints,&b.joints);core.table_swap(&a.statics,&b.statics);core.table_swap(&a.parents,&b.parents);core.table_swap(&a.names,&b.names);core.table_swap(&a.transforms,&b.transforms);core.table_swap(&a.bodies,&b.bodies);core.table_swap(&a.character_states,&b.character_states);core.table_swap(&a.joint_states,&b.joint_states);core.table_swap(&a.destructibles,&b.destructibles)
    phys.state_swap(&a.physics,&b.physics)
    a.settings,b.settings=b.settings,a.settings;a.requests,b.requests=b.requests,a.requests;a.events,b.events=b.events,a.events;a.gameplay_ticks,b.gameplay_ticks=b.gameplay_ticks,a.gameplay_ticks
}

placement_test_game :: proc(world,shared,editor:rawptr,app:rawptr) {
    (cast(^Placement_Test_World)world).gameplay_ticks+=1
}

Placement_Test :: struct {
    world:Placement_Test_World,
    shared:phys.Collider_Meshes,
    app:host.App,
    info:core.World_Info,
    tables:[14]core.Table_Info,
    storages:[7]core.Storage_Info,
    steps:[1]core.Step_Info,
    order:[1]i32,
    session:editor.Session,
    edits:editor.Edits,
    selection:editor.Selection,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    document:editor.Document,
    tool:Physics_Placement,
}

placement_test_open :: proc(f:^Placement_Test) {
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Placement_Test_World,ids)},
        {name="Rigid_Body",type=phys.Rigid_Body,info=type_info_of(phys.Rigid_Body),offset=offset_of(Placement_Test_World,rigids)},
        {name="Collider",type=phys.Collider,info=type_info_of(phys.Collider),offset=offset_of(Placement_Test_World,colliders)},
        {name="Character",type=phys.Character,info=type_info_of(phys.Character),offset=offset_of(Placement_Test_World,characters)},
        {name="Character_Move",type=phys.Character_Move,info=type_info_of(phys.Character_Move),offset=offset_of(Placement_Test_World,moves)},
        {name="Joint",type=phys.Joint,info=type_info_of(phys.Joint),offset=offset_of(Placement_Test_World,joints)},
        {name="Mesh_Renderer",type=erender.Mesh_Renderer,info=type_info_of(erender.Mesh_Renderer),offset=offset_of(Placement_Test_World,statics)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Placement_Test_World,parents)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Placement_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Placement_Test_World,transforms)},
        {name="Motion",type=core.Motion,info=type_info_of(core.Motion),offset=offset_of(Placement_Test_World,bodies)},
        {name="Character_State",type=phys.Character_State,info=type_info_of(phys.Character_State),offset=offset_of(Placement_Test_World,character_states)},
        {name="Joint_State",type=phys.Joint_State,info=type_info_of(phys.Joint_State),offset=offset_of(Placement_Test_World,joint_states)},
        {name="Destructible",type=destruct.Destructible,info=type_info_of(destruct.Destructible),offset=offset_of(Placement_Test_World,destructibles)},
    }
    f.storages={
        {name="Physics_State",type=phys.Physics_State,info=type_info_of(phys.Physics_State),offset=offset_of(Placement_Test_World,physics)},
        {name="Physics_Settings",type=phys.Physics_Settings,info=type_info_of(phys.Physics_Settings),offset=offset_of(Placement_Test_World,settings)},
        {name="Body_Requests",type=phys.Body_Requests,info=type_info_of(phys.Body_Requests),offset=offset_of(Placement_Test_World,requests)},
        {name="Physics_Events",type=phys.Physics_Events,info=type_info_of(phys.Physics_Events),offset=offset_of(Placement_Test_World,events)},
        {name="Collider_Meshes",type=phys.Collider_Meshes,info=type_info_of(phys.Collider_Meshes),place=.Shared},
        {name="Time",type=core.Time,info=type_info_of(core.Time),offset=offset_of(Placement_Test_World,time)},
        {name="Problems",type=core.Problems,info=type_info_of(core.Problems),offset=offset_of(Placement_Test_World,problems)},
    }
    f.steps={{name="physics_step",library="physics",call=placement_test_physics}}
    f.info={
        tables=f.tables[:],storages=f.storages[:],steps=f.steps[:],
        copy=placement_test_copy,swap=placement_test_swap,
    }
    f.info.order[.Editor][.Fixed]=f.order[:]
    f.info.sizes[.World]=size_of(Placement_Test_World)
    f.info.aligns[.World]=align_of(Placement_Test_World)
    f.info.init[.World]=placement_test_init
    f.info.destroy[.World]=placement_test_destroy
    f.info.loops[.Game][.Fixed]=placement_test_game
    placement_test_init(&f.world,context.allocator)
    f.app={info=&f.info,shared=&f.shared,allocator=context.allocator}
    f.session={
        app=&f.app,info=&f.info,edit_world=&f.world,edits=&f.edits,selection=&f.selection,
        viewport=&f.viewport,gui=&f.gui,document=&f.document,
    }
}

placement_test_close :: proc(f:^Placement_Test) {
    physics_placement_free(&f.tool)
    editor.edits_free(&f.edits)
    delete(f.selection.entities)
    placement_test_destroy(&f.world)
    phys.collider_meshes_destroy(&f.shared)
    delete(f.app.worlds)
}

placement_test_box :: proc(f:^Placement_Test,name:string,position,scale:[3]f32,collider:bool) -> core.Entity {
    e:=core.create(&f.world.entities)
    core.add(&f.world.ids,e,core.Id{base.Entity_Id(e)})
    core.add(&f.world.names,e,core.name_make(name))
    core.add(&f.world.transforms,e,core.Transform{position,1,scale})
    core.add(&f.world.statics,e,erender.Mesh_Renderer{shape=.Cube})
    if collider {core.add(&f.world.colliders,e,phys.collider_box({0.5,0.5,0.5}))}
    placement_test_settle(&f.world,nil,nil)
    return e
}

@(test)
placement_drops_settle_without_gameplay_and_commit_as_one_undo :: proc(t:^testing.T) {
    f:Placement_Test
    placement_test_open(&f)
    defer placement_test_close(&f)
    floor:=placement_test_box(&f,"Floor",{0,-0.5,0},{20,1,20},true)
    source:=placement_test_box(&f,"Book",{0,2,0},{0.5,0.1,0.7},false)
    core.add(&f.world.rigids,floor,phys.RIGID_BODY_DYNAMIC)
    placement_test_settle(&f.world,nil,nil)
    w:=editor.edited_world(&f.session)
    editor.edits_reset(&f.edits,w)
    editor.selection_set(&f.selection,{source})
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
    testing.expect(t,editor.undo(&f.edits,w,&f.selection))
    testing.expect(t,!core.alive(&f.world.entities,first) && !core.alive(&f.world.entities,second))
    testing.expect_value(t,editor.selection_active(&f.selection),source)
    testing.expect(t,editor.redo(&f.edits,w,&f.selection))
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
    placement_test_open(&f)
    defer placement_test_close(&f)
    _=placement_test_box(&f,"Floor",{0,-0.5,0},{20,1,20},true)
    source:=placement_test_box(&f,"Book",{0,3,0},{1,1,1},true)
    w:=editor.edited_world(&f.session)
    editor.edits_reset(&f.edits,w)
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
    testing.expect_value(t,editor.selection_active(&f.selection),core.NONE)
}

@(test)
placement_uses_the_chosen_mesh_and_rejects_invalid_geometry_atomically :: proc(t:^testing.T) {
    f:Placement_Test
    placement_test_open(&f)
    defer placement_test_close(&f)
    floor:=placement_test_box(&f,"Floor",{0,-0.5,0},{20,1,20},false)
    core.add(&f.world.destructibles,floor,destruct.destructible())
    root:=core.create(&f.world.entities)
    core.add(&f.world.ids,root,core.Id{base.Entity_Id(root)})
    core.add(&f.world.names,root,core.name_make("Books"))
    core.add(&f.world.transforms,root,core.Transform{{0,3,0},1,{1,1,1}})
    child:=placement_test_box(&f,"Book",{0,0,0},{1,1,1},false)
    core.add(&f.world.parents,child,core.Parent{root,0})
    placement_test_settle(&f.world,nil,nil)
    w:=editor.edited_world(&f.session)
    editor.edits_reset(&f.edits,w)
    editor.selection_set(&f.selection,{root,child})
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
    testing.expect_value(t,editor.selection_active(&f.selection),child)
    testing.expect(t,!f.edits.open)
    testing.expect_value(t,host.app_world_count(&f.app),0)
}

@(test)
placement_api_drops_settle_and_confirm_within_the_call :: proc(t:^testing.T) {
    f:Placement_Test
    placement_test_open(&f)
    defer placement_test_close(&f)
    floor:=placement_test_box(&f,"Floor",{0,-0.5,0},{20,1,20},true)
    w:=editor.edited_world(&f.session)
    editor.edits_reset(&f.edits,w)
    editor.selection_set(&f.selection,{floor})
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
    testing.expect(t,editor.undo(&f.edits,w,&f.selection))
    testing.expect(t,!core.alive(&f.world.entities,placed))
    testing.expect_value(t,editor.selection_active(&f.selection),floor)

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

