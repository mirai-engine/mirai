package editor

import "core:encoding/json"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

@(test)
view_viewport_returns_the_requested_message_snapshot_without_recapturing :: proc(t:^testing.T) {
    root:=base.test_folder(t,"view-viewport")
    if root=="" {return}
    saved:=[2]string{"first message image","second message image"}
    requests:=[2]string{"12-0","12-2"}
    for request,index in requests {
        folder:=project.path(root,fmt.tprintf(".mirai/ai/%s",request),allocator=context.temp_allocator)
        testing.expect(t,os.make_directory_all(folder)==nil)
        testing.expect(t,os.write_entire_file(project.path(folder,AI_FILE_IMAGE,allocator=context.temp_allocator),saved[index])==nil)
    }
    s:=Session{project_root=root}
    server:=api.Server{}
    method:=api.Method{params_id=Api_Viewport_Params}
    params:Api_Viewport_Params
    buffer:[1024]u8
    w:serial.Writer
    for request,index in requests {
        base.text_set(params.request[:],request)
        serial.writer_init_fixed(&w,buffer[:])
        call:=api.Call{server=&server,method=&method,params=&params,out=&w,allocator=context.temp_allocator}
        api_view_viewport(&s,&call)
        testing.expect(t,!call.failed && w.overflow==0)
        value:Api_Viewport_Result_Text
        testing.expect(t,json.unmarshal(serial.writer_bytes(&w),&value,allocator=context.temp_allocator)==nil)
        testing.expect_value(t,call.image,value.path)
        shown,read:=os.read_entire_file(call.image,context.temp_allocator)
        testing.expect(t,read==nil)
        testing.expect_value(t,string(shown),saved[index])
    }
    for request in ([]string{"../12-0","12-0/../../secret","12--2","0-0","12-3"}) {
        base.text_set(params.request[:],request)
        serial.writer_init_fixed(&w,buffer[:])
        call:=api.Call{server=&server,method=&method,params=&params,out=&w,allocator=context.temp_allocator}
        api_view_viewport(&s,&call)
        testing.expect(t,call.failed)
        testing.expect_value(t,w.count,0)
    }
    // Without a request it is the turn of the caller; outside a turn it says so.
    base.text_set(params.request[:],"")
    serial.writer_init_fixed(&w,buffer[:])
    outside:=api.Call{server=&server,method=&method,params=&params,out=&w,allocator=context.temp_allocator}
    api_view_viewport(&s,&outside)
    testing.expect(t,outside.failed && outside.error.code==api.INVALID_PARAMS,outside.error.message)
    m:=new(Ai,context.temp_allocator)
    m.task_count=1
    base.text_set(m.tasks[0].name[:],requests[1])
    s.ai=m
    serial.writer_init_fixed(&w,buffer[:])
    turn:=api.Call{server=&server,method=&method,params=&params,out=&w,allocator=context.temp_allocator,client_tag=requests[1]}
    api_view_viewport(&s,&turn)
    testing.expect(t,!turn.failed && w.count>0,turn.error.message)
}

@(private="file")
Api_Viewport_Result_Text :: struct {path:string}

@(private="file")
Camera_World :: struct {
    using world:core.Test_World,
    using scene_tables:Test_Scene,
    cameras:core.Table(erender.Camera),
}
@(private="file") Camera_Editor :: struct {api:Api}

@(test)
camera_set_takes_a_fov_and_looks_through_a_camera_of_the_scene_without_editing_it :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Camera_World,core.Test_None,Camera_Editor,test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Camera_World
    if !testing.expect(t,info.init[.World](&world,context.allocator)) {return}
    defer info.destroy[.World](&world)
    rig,eye,cube,flat:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    forward:=linalg.normalize([3]f32{-1,-0.5,0})
    core.add(&world.ids,rig,{value=1});core.add(&world.ids,eye,{value=2});core.add(&world.ids,cube,{value=3});core.add(&world.ids,flat,{value=4})
    core.add(&world.transforms,rig,core.Transform{position={10,0,0},rotation=1,scale={1,1,1}})
    core.add(&world.transforms,eye,core.Transform{position={0,2,5},rotation=mm.quat_look(forward,{0,1,0}),scale={1,1,1}})
    core.add(&world.transforms,cube,core.Transform{rotation=1,scale={1,1,1}})
    core.add(&world.transforms,flat,core.Transform{rotation=1,scale={1,1,1}})
    core.add(&world.parents,eye,core.Parent{entity=rig})
    core.add(&world.cameras,eye,erender.Camera{fov=40*mm.RAD_PER_DEG,near=0.1,active=true})
    core.add(&world.cameras,flat,erender.Camera{projection=.Orthographic,height=10,active=true})
    core.settle(&info,&world,nil)
    selection:history.Selection;defer delete(selection.entities)
    viewport:Viewport
    viewport_init(&viewport);defer viewport_free(&viewport)
    viewport.size={1280,720}
    gui:Editor_Ui;edits:history.Edits;defer history.edits_free(&edits)
    document:Document
    editor:Camera_Editor
    session:=Session{info=&info,edit_world=&world,editor_world=&editor,selection=&selection,viewport=&viewport,gui=&gui,edits=&edits,document=&document}
    history.edits_reset(&edits,edited_world(&session))
    if !testing.expect(t,api_open(&session,0,true)==.None) {return};defer api_close(&session)
    state:=api_state(&session);state.poll_temp=context.temp_allocator
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    execute :: proc(state:^Api_State,out:^serial.Writer,params:string) -> (error:api.Error,result:Api_Camera_Result) {
        base.arena_reset(&state.server.scratch);serial.writer_reset(out)
        error,_=api.method_execute(&state.server,api.method_find(&state.server,"camera.set"),params,out)
        if error.code==0 {json.unmarshal(serial.writer_bytes(out),&result,allocator=context.temp_allocator)}
        return
    }
    near :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<1e-3}
    scene_state,transforms,cameras:=history.edits_scene_state(&edits),world.transforms.version,world.cameras.version

    error,result:=execute(state,&out,"{}")
    testing.expect_value(t,error.code,0)
    testing.expect_value(t,result.fov_y,VIEW_FOV)
    error,result=execute(state,&out,`{"fov":30}`)
    testing.expect_value(t,error.code,0)
    testing.expect_value(t,result.fov_y,f32(30))
    testing.expect_value(t,viewport.camera.fov_y,f32(30))
    for wrong in ([]string{`{"fov":0.5}`,`{"fov":171}`,`{"fov":"wide"}`}) {
        error,_=execute(state,&out,wrong)
        testing.expect_value(t,error.code,api.INVALID_PARAMS)
    }
    testing.expect_value(t,viewport.orbit.fov,f32(30))

    error,result=execute(state,&out,`{"entity":"0000000000000002"}`)
    testing.expect_value(t,error.code,0)
    testing.expectf(t,near(orbit_position(viewport.orbit),{10,2,5}) && near(result.position,{10,2,5}),"the eye of the camera, under its parent: %v",result.position)
    testing.expectf(t,near(linalg.normalize(viewport.orbit.target-orbit_position(viewport.orbit)),forward),"where the camera looks: %v",viewport.orbit.target)
    testing.expect(t,abs(result.fov_y-40)<1e-3 && abs(viewport.camera.fov_y-40)<1e-3,"the fov of the camera, in degrees")
    error,result=execute(state,&out,`{"entity":"0000000000000002","fov":70,"distance":4}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,near(result.position,{10,2,5}) && result.fov_y==70 && abs(result.distance-4)<1e-4,"fov and distance apply over the camera")
    for wrong in ([]string{`{"entity":"0000000000000002","position":[0,0,0]}`,`{"entity":"0000000000000002","yaw":1}`,`{"entity":"0000000000000003"}`,`{"entity":"0000000000000004"}`,`{"entity":"0000000000000063"}`,`{"entity":null}`}) {
        error,_=execute(state,&out,wrong)
        testing.expectf(t,error.code==api.INVALID_PARAMS,"%s: %v",wrong,error)
    }
    testing.expect_value(t,viewport.orbit.fov,f32(70))
    testing.expect_value(t,history.edits_scene_state(&edits),scene_state)
    testing.expect_value(t,world.transforms.version,transforms)
    testing.expect_value(t,world.cameras.version,cameras)
    testing.expect_value(t,len(edits.steps),0)
}

@(test)
capture_without_ui_draws_the_world_alone_at_the_size_asked_for :: proc(t:^testing.T) {
    Shown_World :: struct {using world:core.Test_World}
    shown:Shown_World
    if !core.test_world_init(t,&shown) {return}
    defer core.test_world_destroy(&shown)
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.reflections,settings.taa=false,false,false
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root="assets",window_desc={size={128,96}},threads=1,render_settings=settings})
    if !testing.expect_value(t,error,host.App_Error.None) || app==nil {return}
    defer host.app_destroy(app)
    app.info=core.test_world_info(&shown)
    session:=Session{app=app,info=app.info,edit_world=&shown}
    cube,made:=erender.mesh_instance(app.assets,{shape=.Cube},mm.transform_matrix({position={0,0.5,0},rotation=1,scale={1,1,1}}),{color={0.2,0.9,0.5,1},emission={0.05,0.3,0.15}})
    if !testing.expect(t,made) {return}
    cube.uniform_color,cube.highlight=true,HIGHLIGHT_SELECTED
    host.assets_commit(app.assets)
    gpu.scene_set(app.renderer,{cube},nil,{},{background={0.02,0.02,0.1},use_background=true})
    // A fixed exposure: metered, the dark backdrop would be made middle gray.
    host.app_camera_set(app,{position={0,1.2,4},forward={0,-0.7,-4},up={0,1,0},fov_y=40,near=0.05,far=100,exposure=gpu.UNIT_EXPOSURE},true)
    red:=[4]f32{1,0,0,1}
    panel:=[6]gpu.Ui_Vertex{{position={0,0,0},color=red},{position={32,0,0},color=red},{position={32,24,0},color=red},{position={0,0,0},color=red},{position={32,24,0},color=red},{position={0,24,0},color=red}}
    for _ in 0..<3 {
        host.app_frame_begin(app)
        host.extras_ui_layer_add(&app.extras,{vertices=panel[:]})
        host.app_frame_end(app)
    }
    at :: proc(pixels:[]u8,width,x,y:int) -> [3]int {i:=(y*width+x)*4;return {int(pixels[i]),int(pixels[i+1]),int(pixels[i+2])}}
    count :: proc(pixels:[]u8,keep:proc(c:[3]int) -> bool) -> int {
        n:=0
        for i in 0..<len(pixels)/4 {if keep({int(pixels[i*4]),int(pixels[i*4+1]),int(pixels[i*4+2])}) {n+=1}}
        return n
    }
    cube_pixel :: proc(c:[3]int) -> bool {return c.g>c.r+20 && c.g>c.b+10}
    outline_pixel :: proc(c:[3]int) -> bool {return c.r>c.g+30 && c.g>c.b+30}
    with_ui,ui_width,ui_height,ui_read:=api_capture_image(&session,true,{})
    defer delete(with_ui,app.allocator)
    alone,width,height,read:=api_capture_image(&session,false,{128,96})
    defer delete(alone,app.allocator)
    sized,sized_width,sized_height,sized_read:=api_capture_image(&session,false,api_capture_size(app.drawable,64,0))
    defer delete(sized,app.allocator)
    if !testing.expect(t,ui_read && read && sized_read,app.renderer.error) {return}
    seen:=api_capture_seen(app)
    testing.expectf(t,seen.instances_drawn>0 && seen.instances_culled==0,"the camera sees the cube: %v",seen)
    testing.expect_value(t,[2]int{ui_width,ui_height},[2]int{128,96})
    testing.expect_value(t,[2]int{width,height},[2]int{128,96})
    testing.expect_value(t,[2]int{sized_width,sized_height},[2]int{64,48})
    testing.expect_value(t,len(sized),64*48*4)
    corner:=at(with_ui,128,4,4)
    testing.expectf(t,corner.r>200 && corner.g<40,"the window has the UI over the world: %v",corner)
    corner=at(alone,128,4,4)
    testing.expectf(t,corner.r<40,"the world alone has no UI: %v",corner)
    testing.expect(t,mem.compare(with_ui,alone)!=0,"the image without the UI differs from the window")
    testing.expect(t,count(with_ui,outline_pixel)>0,"the window outlines the selection")
    testing.expect_value(t,count(alone,outline_pixel),0)
    testing.expectf(t,count(alone,cube_pixel)>200,"the world is drawn through the camera: %d pixels",count(alone,cube_pixel))
    testing.expectf(t,count(sized,cube_pixel)>50,"and at the size asked for: %d pixels",count(sized,cube_pixel))
    host.app_camera_set(app,{position={0,1.2,4},forward={0,0,1},up={0,1,0},fov_y=40,near=0.05,far=100,exposure=gpu.UNIT_EXPOSURE},true)
    away,_,_,away_read:=api_capture_image(&session,false,{64,48})
    defer delete(away,app.allocator)
    seen=api_capture_seen(app)
    testing.expectf(t,away_read && seen.instances_drawn==0 && seen.instances_culled>0,"the camera looks away from what is there: %v",seen)
    testing.expect_value(t,api_capture_size({1280,720},0,360),[2]i32{640,360})
    testing.expect_value(t,api_capture_size({1280,720},0,0),[2]i32{1280,720})
    app.scene={0,24,app.drawable.x,app.drawable.y-24}
    testing.expect_value(t,api_capture_viewport(app),[2]i32{app.drawable.x,app.drawable.y-24})
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}
