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

@(test)
scene_raycast_meets_the_nearest_mesh_goes_through_what_it_ignores_and_misses :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    if !pick_device_open(t,&f.device) || !spatial_open(t,f) {pick_device_close(&f.device);return}
    defer spatial_close(f)
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
scene_ground_rests_entities_on_what_is_under_them_as_one_undo :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    if !pick_device_open(t,&f.device) || !spatial_open(t,f) {pick_device_close(&f.device);return}
    defer spatial_close(f)
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
    core.edit(&f.w.transforms,f.crate).position.y=-0.2
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
    turned,_:=core.get(&f.w.transforms,f.boulder)
    up:=mm.quat_rotate(turned.rotation,{0,1,0})
    testing.expect(t,linalg.dot(up,[3]f32{-0.5,math.sqrt_f32(3)*0.5,0})>0.999,"its up follows the ramp")
    testing.expect(t,abs(result.entities[0].rotation_deg.z-30)<0.1 && result.entities[0].moved<0)
}

@(test)
scene_ground_fails_whole_and_says_which_entity :: proc(t:^testing.T) {
    f:=new(Spatial_Fixture);defer free(f)
    if !pick_device_open(t,&f.device) || !spatial_open(t,f) {pick_device_close(&f.device);return}
    defer spatial_close(f)
    w:=edited_world(&f.s)
    core.edit(&f.w.transforms,f.lamp).position={50,2,0}
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
    if !pick_device_open(t,&f.device) || !spatial_open(t,f) {pick_device_close(&f.device);return}
    defer spatial_close(f)
    f.s.editor_world=&f.editor
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
