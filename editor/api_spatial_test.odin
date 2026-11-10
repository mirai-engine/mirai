package editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

@(private="file")
Spatial_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    meshes:core.Table(erender.Mesh_Renderer),
    hierarchy:core.Hierarchy,
}

// A floor whose top is at 0, a crate over it with a lid, a lamp without a
// mesh and a ramp turned 30 degrees about Z far to the side.
@(private="file")
Spatial_Fixture :: struct {
    w:Spatial_World,
    info:core.World_Info,
    tables:[6]core.Table_Info,
    edits:history.Edits,
    selection:history.Selection,
    viewport:Viewport,
    gui:Editor_Ui,
    picker:Picker,
    app:host.App,
    s:Session,
    floor,crate,lid,lamp,ramp,boulder:core.Entity,
}

@(private="file")
spatial_open :: proc(f:^Spatial_Fixture) {
    w:=&f.w
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id");core.table_init(&w.names,"Name")
    core.table_init(&w.transforms,"Transform");core.table_init(&w.parents,"Parent")
    core.table_init(&w.disabled,"Disabled");core.table_init(&w.meshes,"Mesh_Renderer")
    w.ids.base,w.names.base,w.transforms.base,w.parents.base,w.disabled.base=true,true,true,true,true
    f.tables[0]={name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Spatial_World,ids)}
    f.tables[1]={name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Spatial_World,names)}
    f.tables[2]={name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Spatial_World,transforms)}
    f.tables[3]={name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Spatial_World,parents)}
    f.tables[4]={name="Disabled",type=core.Disabled,info=type_info_of(core.Disabled),offset=offset_of(Spatial_World,disabled)}
    f.tables[5]={name="Mesh_Renderer",type=erender.Mesh_Renderer,info=type_info_of(erender.Mesh_Renderer),offset=offset_of(Spatial_World,meshes)}
    f.info={entities=offset_of(Spatial_World,entities),tables=f.tables[:]}
    entity :: proc(w:^Spatial_World,id:u64,name:string,place:core.Transform,cube:bool,parent:=core.NONE) -> core.Entity {
        e:=core.create(&w.entities)
        core.add(&w.ids,e,core.Id{base.Entity_Id(id)})
        core.add(&w.names,e,core.name_make(name))
        core.add(&w.transforms,e,place)
        if cube {core.add(&w.meshes,e,erender.Mesh_Renderer{shape=.Cube})}
        if parent!=core.NONE {core.add(&w.parents,e,core.Parent{entity=parent})}
        return e
    }
    f.floor=entity(w,1,"Floor",{position={0,-0.5,0},rotation=1,scale={10,1,10}},true)
    f.crate=entity(w,2,"Crate",{position={0,3,0},rotation=1,scale={1,1,1}},true)
    f.lid=entity(w,3,"Lid",{position={0,1,0},rotation=1,scale={1,1,1}},true,f.crate)
    f.lamp=entity(w,4,"Lamp",{position={3,2,0},rotation=1,scale={1,1,1}},false)
    f.ramp=entity(w,5,"Ramp",{position={20,0,0},rotation=mm.quat_axis_angle({0,0,1},30*mm.RAD_PER_DEG),scale={6,0.2,6}},true)
    f.boulder=entity(w,6,"Boulder",{position={20,5,0},rotation=1,scale={1,1,1}},true)
    history.edits_reset(&f.edits,{data=w,info=&f.info})
    f.viewport={size={800,600}}
    f.viewport.view_matrix=mm.look_at({0,3,10},{0,3,0},{0,1,0})
    f.viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    f.viewport.view_projection=f.viewport.projection*f.viewport.view_matrix
    f.s=Session{info=&f.info,edit_world=w,edits=&f.edits,selection=&f.selection,viewport=&f.viewport,gui=&f.gui,picker=&f.picker,app=&f.app}
    ref:=edited_world(&f.s)
    core.world_settle(ref)
    history.edits_reset(&f.edits,ref)
}

@(private="file")
spatial_close :: proc(f:^Spatial_Fixture) {
    history.edits_free(&f.edits)
    picker_clear(&f.picker);delete(f.picker.meshes)
    delete(f.selection.entities)
    viewport_free(&f.viewport)
    w:=&f.w
    core.table_destroy(&w.ids);core.table_destroy(&w.names)
    core.table_destroy(&w.transforms);core.table_destroy(&w.parents)
    core.table_destroy(&w.disabled);core.table_destroy(&w.meshes)
    core.value_free(&w.hierarchy,type_info_of(core.Hierarchy))
    core.entities_destroy(&w.entities)
}

@(private="file")
spatial_call :: proc(f:^Spatial_Fixture,run:proc(^Session,^api.Call),method:^api.Method,params,result:rawptr,raw:string) -> api.Call {
    call:=api.Call{method=method,params=params,result=result,raw=raw,allocator=context.temp_allocator}
    run(&f.s,&call)
    return call
}

@(private="file")
near3 :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<1e-3}

@(private="file")
spatial_y :: proc(f:^Spatial_Fixture,e:core.Entity) -> f32 {
    value,_:=core.get(core.read(&f.w.transforms),e)
    return value.position.y
}

@(test)
scene_raycast_meets_the_nearest_mesh_goes_through_what_it_ignores_and_misses :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    spatial_open(f);defer spatial_close(f)
    method:=api.Method{params_id=Api_Raycast_Params,result_id=Api_Raycast_Result}
    params:=Api_Raycast_Params{origin={0,10,0},direction={0,-2,0},reach=PICK_REACH}
    result:Api_Raycast_Result
    raw:=`{"origin":[0,10,0],"direction":[0,-2,0]}`
    call:=spatial_call(f,api_scene_raycast,&method,&params,&result,raw)
    testing.expect(t,!call.failed,call.error.message)
    testing.expect(t,result.hit && result.id==3,"the lid is the first mesh down from above the crate")
    testing.expect_value(t,base.text_get(result.name[:]),"Lid")
    testing.expect(t,abs(result.distance-5.5)<1e-3 && near3(result.point,{0,4.5,0}) && near3(result.normal,{0,1,0}))
    base.text_set(params.ignore[0][:],"Crate")
    result={}
    call=spatial_call(f,api_scene_raycast,&method,&params,&result,raw)
    testing.expect(t,result.hit && result.id==1 && abs(result.distance-10)<1e-3,"ignoring the crate also ignores its lid")
    params.reach=5
    result={}
    call=spatial_call(f,api_scene_raycast,&method,&params,&result,raw)
    testing.expect(t,!call.failed && !result.hit,"the floor is past the reach")
    params={origin={50,10,0},direction={0,-1,0},reach=PICK_REACH}
    result={}
    call=spatial_call(f,api_scene_raycast,&method,&params,&result,raw)
    testing.expect(t,!call.failed && !result.hit && result.id==0 && result.distance==0)
    params={point={400,300},reach=PICK_REACH}
    result={}
    call=spatial_call(f,api_scene_raycast,&method,&params,&result,`{"point":[400,300]}`)
    testing.expect(t,!call.failed && result.hit && result.id==2 && abs(result.distance-9.5)<1e-3,"the middle of the viewport looks at the crate")
}

@(test)
scene_raycast_says_what_is_wrong_with_its_params :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    spatial_open(f);defer spatial_close(f)
    method:=api.Method{params_id=Api_Raycast_Params,result_id=Api_Raycast_Result}
    result:Api_Raycast_Result
    expect_error :: proc(t:^testing.T,f:^Spatial_Fixture,method:^api.Method,params:Api_Raycast_Params,raw,text:string,code:=api.INVALID_PARAMS,loc:=#caller_location) {
        params:=params
        result:Api_Raycast_Result
        call:=spatial_call(f,api_scene_raycast,method,&params,&result,raw)
        testing.expectf(t,call.failed && call.error.code==code && strings.contains(call.error.message,text),"%v %s",call.error.code,call.error.message,loc=loc)
    }
    expect_error(t,f,&method,{origin={0,1,0},reach=PICK_REACH},`{"origin":[0,1,0],"direction":[0,0,0]}`,"direction is zero")
    expect_error(t,f,&method,{origin={0,1,0},reach=PICK_REACH},`{"origin":[0,1,0]}`,"give origin and direction")
    expect_error(t,f,&method,{origin={0,1,0},direction={0,-1,0},point={400,300},reach=PICK_REACH},`{"origin":[0,1,0],"direction":[0,-1,0],"point":[400,300]}`,"give point alone")
    expect_error(t,f,&method,{point={900,300},reach=PICK_REACH},`{"point":[900,300]}`,"is not over the viewport")
    nan:=math.nan_f32()
    expect_error(t,f,&method,{origin={nan,0,0},direction={0,-1,0},reach=PICK_REACH},`{"origin":["nan",0,0],"direction":[0,-1,0]}`,"finite")
    expect_error(t,f,&method,{origin={0,1,0},direction={0,-1,0},reach=0},`{"origin":[0,1,0],"direction":[0,-1,0],"reach":0}`,"reach")
    ignored:=Api_Raycast_Params{origin={0,1,0},direction={0,-1,0},reach=PICK_REACH}
    base.text_set(ignored.ignore[0][:],"99")
    expect_error(t,f,&method,ignored,`{"origin":[0,1,0],"direction":[0,-1,0],"ignore":["99"]}`,`ignore[0]: "99" names no entity of the scene`)
    f.s.mode=.Simulate
    ray:=Api_Raycast_Params{origin={0,1,0},direction={0,-1,0},reach=PICK_REACH}
    played:=spatial_call(f,api_scene_raycast,&method,&ray,&result,`{"origin":[0,1,0],"direction":[0,-1,0]}`)
    testing.expect(t,!played.failed,played.error.message)
}

@(test)
scene_bounds_boxes_each_entity_with_its_children_and_all_together :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    spatial_open(f);defer spatial_close(f)
    method:=api.Method{params_id=Api_Spatial_Entities_Params,result_id=Api_Bounds_Result}
    params:Api_Spatial_Entities_Params
    copy(params.entities[0][:],"Crate")
    copy(params.entities[1][:],"Lamp")
    copy(params.entities[2][:],"Floor")
    result:Api_Bounds_Result
    call:=spatial_call(f,api_scene_bounds,&method,&params,&result,`{"entities":["Crate","Lamp","Floor"]}`)
    testing.expect(t,!call.failed,call.error.message)
    crate,lamp,floor:=result.entities[0],result.entities[1],result.entities[2]
    testing.expect(t,crate.id==2 && crate.meshes && near3(crate.min,{-0.5,2.5,-0.5}) && near3(crate.max,{0.5,4.5,0.5}),"the crate holds its lid")
    testing.expect(t,near3(crate.center,{0,3.5,0}) && near3(crate.size,{1,2,1}))
    testing.expect(t,lamp.id==4 && !lamp.meshes && near3(lamp.min,{3,2,0}) && near3(lamp.size,{}),"an entity without meshes is its point")
    testing.expect(t,floor.id==1 && near3(floor.min,{-5,-1,-5}) && near3(floor.max,{5,0,5}))
    testing.expect(t,result.entities[3].id==0)
    testing.expect(t,result.meshes && near3(result.min,{-5,-1,-5}) && near3(result.max,{5,4.5,5}))
    params={}
    call=spatial_call(f,api_scene_bounds,&method,&params,&result,`{"entities":[]}`)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS && strings.contains(call.error.message,"entities must name 1 to 64"))
    copy(params.entities[0][:],"Crate")
    copy(params.entities[1][:],"Crate")
    call=spatial_call(f,api_scene_bounds,&method,&params,&result,`{"entities":["Crate","Crate"]}`)
    testing.expect(t,call.failed && strings.contains(call.error.message,`entities[1]: "Crate" is listed twice`),call.error.message)
}

@(test)
scene_ground_rests_entities_on_what_is_under_them_as_one_undo :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    spatial_open(f);defer spatial_close(f)
    w:=edited_world(&f.s)
    method:=api.Method{params_id=Api_Ground_Params,result_id=Api_Ground_Result}
    params:Api_Ground_Params
    copy(params.entities[0][:],"Crate")
    copy(params.entities[1][:],"Lamp")
    result:Api_Ground_Result
    undo_before:=history.edits_undo_count(&f.edits)
    call:=spatial_call(f,api_scene_ground,&method,&params,&result,`{"entities":["Crate","Lamp"]}`)
    testing.expect(t,!call.failed,call.error.message)
    testing.expect(t,abs(spatial_y(f,f.crate)-0.5)<1e-3 && abs(spatial_y(f,f.lamp))<1e-3,"the bottom of the crate and the point of the lamp rest on the floor")
    testing.expect(t,abs(spatial_y(f,f.lid)-1)<1e-3,"what hangs from it keeps its local place")
    testing.expect(t,result.entities[0].id==2 && abs(result.entities[0].moved+2.5)<1e-3 && near3(result.entities[0].position,{0,0.5,0}))
    testing.expect(t,result.entities[1].id==4 && abs(result.entities[1].moved+2)<1e-3 && near3(result.entities[1].world_position,{3,0,0}))
    testing.expect_value(t,history.edits_undo_count(&f.edits),undo_before+1)
    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect(t,abs(spatial_y(f,f.crate)-3)<1e-3 && abs(spatial_y(f,f.lamp)-2)<1e-3,"one undo puts both back")
    // Buried: it rises to the surface, with the offset over it.
    core.get(&f.w.transforms,f.crate).position.y=-0.2
    core.world_settle(w);history.edits_reset(&f.edits,w)
    params={offset=0.1}
    copy(params.entities[0][:],"Crate")
    result={}
    call=spatial_call(f,api_scene_ground,&method,&params,&result,`{"entities":["Crate"],"offset":0.1}`)
    testing.expect(t,!call.failed && abs(spatial_y(f,f.crate)-0.6)<1e-3 && abs(result.entities[0].moved-0.8)<1e-3,call.error.message)
    // Turned to the normal of the ramp.
    params={align=true}
    copy(params.entities[0][:],"Boulder")
    result={}
    call=spatial_call(f,api_scene_ground,&method,&params,&result,`{"entities":["Boulder"],"align":true}`)
    testing.expect(t,!call.failed,call.error.message)
    turned,_:=core.get(core.read(&f.w.transforms),f.boulder)
    up:=mm.quat_rotate(turned.rotation,{0,1,0})
    testing.expect(t,linalg.dot(up,[3]f32{-0.5,math.sqrt_f32(3)*0.5,0})>0.999,"its up follows the ramp")
    testing.expect(t,abs(result.entities[0].rotation_deg.z-30)<0.1 && result.entities[0].moved<0)
}

@(test)
scene_ground_fails_whole_and_says_which_entity :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    spatial_open(f);defer spatial_close(f)
    w:=edited_world(&f.s)
    core.get(&f.w.transforms,f.lamp).position={50,2,0}
    core.world_settle(w);history.edits_reset(&f.edits,w)
    method:=api.Method{params_id=Api_Ground_Params,result_id=Api_Ground_Result}
    params:Api_Ground_Params
    copy(params.entities[0][:],"Crate")
    copy(params.entities[1][:],"Lamp")
    result:Api_Ground_Result
    undo_before:=history.edits_undo_count(&f.edits)
    call:=spatial_call(f,api_scene_ground,&method,&params,&result,`{"entities":["Crate","Lamp"]}`)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS && strings.contains(call.error.message,`entities[1]: nothing shown is under 0x0000000000000004 "Lamp"`),call.error.message)
    testing.expect(t,abs(spatial_y(f,f.crate)-3)<1e-3 && history.edits_undo_count(&f.edits)==undo_before,"nothing moves and no step is left")
    params={}
    copy(params.entities[0][:],"Crate")
    copy(params.entities[1][:],"Lid")
    call=spatial_call(f,api_scene_ground,&method,&params,&result,`{"entities":["Crate","Lid"]}`)
    testing.expect(t,call.failed && strings.contains(call.error.message,"entities[1]: 0x0000000000000003 hangs from 0x0000000000000002"),call.error.message)
    params={}
    copy(params.entities[0][:],"Nobody")
    call=spatial_call(f,api_scene_ground,&method,&params,&result,`{"entities":["Nobody"]}`)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS && strings.contains(call.error.message,"names no entity of the scene"),call.error.message)
    f.s.mode=.Play
    params={}
    copy(params.entities[0][:],"Crate")
    call=spatial_call(f,api_scene_ground,&method,&params,&result,`{"entities":["Crate"]}`)
    testing.expect(t,!call.failed,call.error.message)
    testing.expectf(t,abs(spatial_y(f,f.crate)-0.5)<1e-3,"the document moved while a game plays: y %v moved %v",spatial_y(f,f.crate),result.entities[0].moved)
}

@(test)
spatial_methods_read_their_params_and_write_their_results_through_the_server :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    spatial_open(f);defer spatial_close(f)
    Spatial_Editor :: struct {api:Api}
    editor:=new(Spatial_Editor);defer free(editor)
    storages:=[1]core.Storage_Info{{name="Api",type=Api,info=type_info_of(Api),place=.Editor,offset=offset_of(Spatial_Editor,api)}}
    f.info.storages=storages[:]
    f.s.editor_world=editor
    if !testing.expect_value(t,api_open(&f.s,0,true),Api_Open_Error.None) {return}
    defer api_close(&f.s)
    state:=api_state(&f.s)
    state.poll_temp=context.temp_allocator
    out:serial.Writer
    serial.writer_init(&out);defer serial.writer_destroy(&out)
    run :: proc(t:^testing.T,state:^Api_State,out:^serial.Writer,name,params:string) -> (text:string,ok:bool) {
        method:=api.method_find(&state.server,name)
        if !testing.expectf(t,method!=nil,"%s is registered",name) {return}
        out.count=0
        error:api.Error
        error,ok=api.method_execute(&state.server,method,params,out)
        if !ok {return error.message,false}
        return string(serial.writer_bytes(out)),true
    }
    text,ok:=run(t,state,&out,"scene.raycast",`{"origin":[0,10,0],"direction":[0,-1,0],"ignore":["Crate"]}`)
    testing.expect(t,ok && strings.contains(text,`"Floor"`) && strings.contains(text,`"hit": true`),text)
    text,ok=run(t,state,&out,"scene.raycast",`{"origin":[0,10,0],"direction":[0,-1,0],"reach":2}`)
    testing.expect(t,ok && strings.contains(text,`"hit": false`),text)
    text,ok=run(t,state,&out,"scene.bounds",`{"entities":["Crate","Lamp"]}`)
    testing.expect(t,ok && strings.count(text,`"meshes"`)==3,text)
    text,ok=run(t,state,&out,"scene.ground",`{"entities":["Crate"],"offset":0.25}`)
    testing.expect(t,ok && abs(spatial_y(f,f.crate)-0.75)<1e-3,text)
    text,ok=run(t,state,&out,"scene.ground",`{"entities":["Crate"],"offset":"nan"}`)
    testing.expect(t,!ok,text)
}

// One text names an entity everywhere; a name several have fails listing how
// to tell them apart, and never picks one.
@(test)
entities_are_named_by_name_path_id_or_handle :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    spatial_open(f);defer spatial_close(f)
    w:=edited_world(&f.s)
    core.get(&f.w.names,f.lid)^=core.name_make("Crate")
    cases:=[?]struct{text:string,want:core.Entity,says:string}{
        {"Lamp",f.lamp,""},
        {"Crate/Crate",f.lid,""},
        {fmt.tprintf("0x%x",2),f.crate,""},
        {fmt.tprintf("%016x",u64(f.boulder)),f.boulder,""},
        {"Crate",core.NONE,"names 2 entities"},
        {"Nobody",core.NONE,"names no entity"},
    }
    for c in cases {
        e,problem:=api_entity_select(w,c.text)
        testing.expectf(t,e==c.want && strings.contains(problem,c.says),"%s: %v %s",c.text,e,problem)
    }
    _,several:=api_entity_select(w,"Crate")
    testing.expect(t,strings.contains(several,"Crate/Crate") && strings.contains(several,"Parent/"),several)
    ids:=[?]struct{text:string,want:base.Entity_Id,says:string}{
        {"Lamp",4,""},
        {"Crate/Crate",3,""},
        {fmt.tprintf("%016x",u64(2)),2,""},
        {"Crate",0,several[len("entity: "):]},
        {"Nobody",0,`"Nobody" names no entity of the scene`},
        {"",0,"it must be the name of an entity"},
    }
    for c in ids {
        e,problem:=api_entity_select(edited_world(&f.s),c.text)
        id:=api_entity_id(edited_world(&f.s),e)
        testing.expectf(t,id==c.want && strings.contains(problem,c.says),"%s: %v %s",c.text,id,problem)
    }
}
