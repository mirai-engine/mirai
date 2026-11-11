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

@(private)
@(test_world,editor="Spatial_Editor")
Spatial_World :: struct {
    using world:Test_World,
    using scene_tables:Test_Scene,
    meshes:core.Table(erender.Mesh_Renderer),
}

@(private)
Spatial_Editor :: struct {api:Api}

// A floor whose top is at 0, a crate over it with a lid, a lamp without a
// mesh and a ramp turned 30 degrees about Z far to the side.
@(private)
Spatial_Fixture :: struct {
    w:Spatial_World,
    info:core.World_Info,
    using edited:Test_Session,
    editor:Spatial_Editor,
    assets:host.Assets,   // without a renderer: for what needs boxes alone
    device:Pick_Device,   // opened by a test that meets meshes, before spatial_open
    app:host.App,
    floor,crate,lid,lamp,ramp,boulder:core.Entity,
}

@(private)
spatial_open :: proc(t:^testing.T,f:^Spatial_Fixture) -> bool {
    w:=&f.w
    f.info=test_info(t,Spatial_World) or_return
    if !testing.expect(t,core.world_init(&f.info,.World,w,context.allocator)) {return false}
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
    f.viewport={size={800,600}}
    f.viewport.view_matrix=mm.look_at({0,3,10},{0,3,0},{0,1,0})
    f.viewport.projection=mm.perspective(50*mm.RAD_PER_DEG,800.0/600,0.1,100)
    f.viewport.view_projection=f.viewport.projection*f.viewport.view_matrix
    core.settle(&f.info,w,nil)
    test_session_open(&f.edited,core.world_ref(w,&f.info))
    if f.device.open {
        f.app.assets,f.app.renderer=&f.device.assets,&f.device.renderer
    } else {
        if !testing.expect(t,host.assets_init(&f.assets,{root="assets",capacity=8})) {return false}
        f.app.assets=&f.assets
    }
    f.s.app=&f.app
    return true
}

@(private)
spatial_close :: proc(f:^Spatial_Fixture) {
    test_session_close(&f.edited)
    if f.device.open {pick_device_close(&f.device)} else {host.assets_destroy(&f.assets)}
    viewport_free(&f.viewport)
    core.world_destroy(&f.info,.World,&f.w)
    test_info_destroy(&f.info)
}

@(private)
spatial_call :: proc(f:^Spatial_Fixture,run:proc(^Session,^api.Call),method:^api.Method,params,result:rawptr,raw:string) -> api.Call {
    call:=api.Call{method=method,params=params,result=result,raw=raw,allocator=context.temp_allocator}
    run(&f.s,&call)
    return call
}

@(private)
near3 :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<1e-3}

@(private)
spatial_y :: proc(f:^Spatial_Fixture,e:core.Entity) -> f32 {
    value,_:=core.get(&f.w.transforms,e)
    return value.position.y
}

@(test)
scene_raycast_says_what_is_wrong_with_its_params :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    if !spatial_open(t,f) {return}
    defer spatial_close(f)
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
    if !spatial_open(t,f) {return}
    defer spatial_close(f)
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

// One text names an entity everywhere; a name several have fails listing how
// to tell them apart, and never picks one.
@(test)
entities_are_named_by_name_path_id_or_handle :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    if !spatial_open(t,f) {return}
    defer spatial_close(f)
    w:=edited_world(&f.s)
    core.edit(&f.w.names,f.lid)^=core.name_make("Crate")
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
