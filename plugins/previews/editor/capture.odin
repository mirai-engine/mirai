package previews_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import aed "plugins:animation/editor"
import eanim "plugins:animation/runtime"

// Where the camera sees the character from, turned with the way it faces.
Capture_View :: enum u8 {Three_Quarter,Front,Side,Back}
Capture_Views :: bit_set[Capture_View]
CAPTURE_FRAMES :: 16
CAPTURE_RATE :: 60

Animation_Capture_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    frames:u32 `mirai:"optional,min=1,max=16,label=Frames of the strip spread over seconds"`,
    seconds:f32 `mirai:"optional,min=0,max=60,unit=s"`,
    time:f32 `mirai:"optional,min=0,unit=s,label=Where it starts"`,
    views:Capture_Views `mirai:"optional,label=A row each turned with the way the character faces; omitted is Three_Quarter"`,
    size:u32 `mirai:"optional,min=64,max=512,label=Pixels of a side of a frame"`,
    path:[1024]u8 `mirai:"optional,text,label=PNG file to write; one under .mirai/captures when empty. mirai image diff compares two"`,
    parameters:[eanim.GRAPH_PARAMETERS]aed.Preview_Parameter `mirai:"optional"`,
    controls:[64]aed.Preview_Control `mirai:"optional"`,
    goals:[64]aed.Preview_Goal `mirai:"optional"`,
    actions:[64]aed.Preview_Action `mirai:"optional"`,
    plays:[16]aed.Request_Play `mirai:"optional"`,
    motion:[16]aed.Request_Motion `mirai:"optional"`,
    locomotion:aed.Request_Locomotion `mirai:"optional"`,
    distance:aed.Request_Distance `mirai:"optional"`,
    locomote:aed.Intent_Locomote `mirai:"optional"`,
    look:aed.Intent_Look `mirai:"optional"`,
    gesture:aed.Intent_Gesture `mirai:"optional"`,
    reach:[2]aed.Intent_Reach `mirai:"optional"`,
}

@(storage)
Previews_Api :: struct {provider:editor.Api_Provider}
PREVIEWS_API_DEFAULT :: Previews_Api{provider={register=previews_register}}

Animation_Capture_Result :: struct {
    id:base.Entity_Id,
    image:[1024]u8 `mirai:"text,label=The PNG written; MCP also returns the image"`,
    size:int `mirai:"label=Pixels of a side of a frame"`,
    short:bool `mirai:"label=The copy of the character shows only part of what the entity does"`,
    frames:[]f32 `mirai:"unit=s,label=The time of each frame of the strip"`,
    views:[][16]u8 `mirai:"text,label=The view of each row"`,
}

@(private)
previews_register :: proc(s:^editor.Session) {
    defaults:=Animation_Capture_Params{frames=6,seconds=1,size=256,views={.Three_Quarter}}
    aed.request_rows_defaults(&defaults)
    editor.api_method_register(s,{name="animation.capture",summary="Shows how an animated entity moves as a PNG: a strip of frames over seconds with a row per view at one scale, from a copy run with the fields of animation.preview.",params=Animation_Capture_Params,params_info=type_info_of(Animation_Capture_Params),result=Animation_Capture_Result,result_info=type_info_of(Animation_Capture_Result),writes_result=true,defaults=&defaults,flags={.Read_Only},run=capture})
}

@(private)
Capture_State :: struct {
    app:^host.App,
    sub:Subject,
    ticks:[CAPTURE_FRAMES]u32,
    count,taken:int,
    bones:[CAPTURE_FRAMES][]mm.Transform, // of the rig, in the space of its parent
    parts:[CAPTURE_FRAMES][]mm.Transform, // of the parts, in that space
    gathered:bool,
}

// Keeps the pose of the rig and its parts at the ticks of the strip.
@(private)
capture_frame :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity,tick:u32,data:rawptr) -> bool {
    st:=(^Capture_State)(data)
    if st.taken>=st.count || st.ticks[st.taken]!=tick {return true}
    if !st.gathered {
        subject_gather(st.app,world,scene_of(world),&st.sub,entity,1)
        st.gathered=true
        if st.sub.part_count==0 || len(st.sub.locals)==0 {api.call_fail(call,api.INVALID_PARAMS,"The entity shows no mesh to capture");return false}
    }
    parent:=editor.entity_parent_world(world,entity)
    playback:=core.world_storage_of(world,eanim.Playback)
    if playback!=nil {
        for &state in playback.states {
            if state.entity!=entity || len(state.world)<2 {continue}
            st.bones[st.taken]=make([]mm.Transform,len(state.world)-1,call.allocator)
            for value,i in state.world[1:] {st.bones[st.taken][i],_=mm.transform_relative(value,parent)}
            break
        }
    }
    st.parts[st.taken]=make([]mm.Transform,st.sub.part_count,call.allocator)
    for i in 0..<st.sub.part_count {st.parts[st.taken][i],_=mm.transform_relative(editor.entity_world(world,st.sub.parts[i].entity),parent)}
    st.taken+=1
    return true
}

// The vertices of a frame: parts where it put them and skins by its bones.
@(private)
capture_pose :: proc(st:^Capture_State,frame:int) -> bool {
    sub:=&st.sub
    copy(sub.worlds[:sub.part_count],st.parts[frame])
    subject_place(sub)
    bones:=st.bones[frame]
    for &skin in sub.skins {
        if skin.buffers.vertex_count==0 {return false}
        if len(bones)==0 {
            // A rig that did not evaluate stands at rest.
            for rest,i in skin.rest {skin.local[i]=rest}
            skeleton:=anim.Skeleton{parents=skin.parents,names=skin.names,rest=skin.rest}
            if !anim.skeleton_world(skeleton,skin.local,skin.world,sub.worlds[skin.rig_part]) {return false}
        } else {
            for i in 0..<len(skin.world) {skin.world[i]=bones[i] if i<len(bones) else skin.world[i]}
        }
        for joint,i in skin.geometry.joints {skin.palette[i]=mm.transform_matrix(skin.world[joint.node])*joint.inverse_bind}
        if !editor.skin_preview_sample(sub.renderer,&skin.buffers,skin.palette,skin.geometry.posed) {return false}
        part:=sub.parts[skin.part]
        for index,i in skin.geometry.indices {
            placed:=&sub.posed[int(part.first)+i]
            placed^=sub.locals[int(part.first)+i]
            skin_vertex_place(placed,skin.geometry.posed[index])
        }
    }
    return true
}

// The way the character faces: the -Z of its rig.
@(private)
capture_facing :: proc(st:^Capture_State) -> mm.Vec3 {
    facing:=mm.quat_rotate(st.parts[0][0].rotation,mm.FORWARD)
    facing.y=0
    return linalg.normalize0(facing) if linalg.length(facing)>1e-4 else mm.FORWARD
}

@(private)
capture :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Animation_Capture_Params)
    app:=s.app
    if app==nil || app.renderer==nil || app.assets==nil {api.call_fail(call,api.SERVER_ERROR,"Capture needs the renderer of the editor");return}
    frames:=int(clamp(p.frames,1,CAPTURE_FRAMES))
    ticks:=u32(math.round(p.seconds*CAPTURE_RATE))
    st:=new(Capture_State,call.allocator)
    st.app,st.count=app,frames
    for i in 0..<frames {st.ticks[i]=u32(math.round(f32(i)*f32(ticks)/f32(max(frames-1,1)))) if frames>1 else 0}
    context.allocator=app.allocator
    defer {subject_skins_clear(&st.sub);delete(st.sub.skins);delete(st.sub.locals);delete(st.sub.posed);delete(st.sub.materials)}
    captured,_:=editor.api_entity_find(editor.shown_world(s),base.text_get(p.entity[:]))
    captured_id:=editor.api_entity_id(editor.shown_world(s),captured)
    if !aed.preview_run(s,call,p.entity[:],p,p.time,ticks,1.0/CAPTURE_RATE,capture_frame,st) {return}
    if st.taken<frames {api.call_fail(call,api.SERVER_ERROR,"The copy stopped before the last frame");return}
    host.assets_commit(app.assets)
    views:=make([dynamic]Capture_View,call.allocator)
    for view in Capture_View {if view in (p.views if p.views!={} else Capture_Views{.Three_Quarter}) {append(&views,view)}}
    // Every view turns the character about its root so the camera sees that side.
    toward:=linalg.normalize(mm.Vec3{-.55,0,-.75})
    facing:=capture_facing(st)
    pivot:=st.parts[0][0].position
    front:=math.atan2(linalg.cross(facing,toward).y,linalg.dot(facing,toward))
    turns:=[Capture_View]f32{.Three_Quarter=front+35*mm.RAD_PER_DEG,.Front=front,.Side=front+90*mm.RAD_PER_DEG,.Back=front+180*mm.RAD_PER_DEG}
    fits:=make([][2]mm.Vec3,len(views),call.allocator)
    for &fit in fits {fit={{max(f32),max(f32),max(f32)},{-max(f32),-max(f32),-max(f32)}}}
    turn :: proc(posed,out:[]editor.Thumbnail_Vertex,rotation:mm.Quat,pivot:mm.Vec3) {
        for vertex,i in posed {
            out[i]=vertex
            out[i].position=pivot+mm.quat_rotate(rotation,vertex.position-pivot)
            out[i].normal=mm.quat_rotate(rotation,vertex.normal)
            out[i].tangent.xyz=mm.quat_rotate(rotation,vertex.tangent.xyz)
        }
    }
    for frame in 0..<frames {
        if !capture_pose(st,frame) {api.call_fail(call,api.SERVER_ERROR,"The skin of the character could not be posed");return}
        for view,v in views {
            rotation:=mm.quat_axis_angle({0,1,0},turns[view])
            for vertex in st.sub.posed {
                at:=pivot+mm.quat_rotate(rotation,vertex.position-pivot)
                fits[v][0],fits[v][1]=linalg.min(fits[v][0],at),linalg.max(fits[v][1],at)
            }
        }
    }
    side:=int(p.size)
    width,height:=side*frames,side*len(views)
    path,writable:=editor.api_capture_file(s,call,base.text_get(p.path[:]),fmt.tprintf("animation-%x.png",u64(captured_id)),call.allocator)
    if !writable {return}
    // The vertices and images outgrow the scratch of a call.
    turned,turned_error:=make([]editor.Thumbnail_Vertex,len(st.sub.posed),app.allocator)
    defer delete(turned,app.allocator)
    pixels,pixels_error:=make([]u8,side*side*4,app.allocator)
    defer delete(pixels,app.allocator)
    image,allocated:=make([]u8,width*height*4,app.allocator)
    if allocated!=nil || turned_error!=nil || pixels_error!=nil {delete(image,app.allocator);api.call_fail(call,api.SERVER_ERROR,"The image could not be allocated");return}
    for i in 0..<width*height {image[i*4],image[i*4+1],image[i*4+2],image[i*4+3]=38,40,46,255}
    thumbnail:editor.Thumbnail_Targets
    defer editor.thumbnail_targets_destroy(app.renderer,&thumbnail)
    for frame in 0..<frames {
        if !capture_pose(st,frame) {delete(image,app.allocator);api.call_fail(call,api.SERVER_ERROR,"The skin of the character could not be posed");return}
        for view,v in views {
            turn(st.sub.posed[:],turned,mm.quat_axis_angle({0,1,0},turns[view]),pivot)
            if !editor.thumbnail_draw(app.renderer,&thumbnail,turned,st.sub.materials[:],u32(side),u32(side),pixels,fits[v]) {delete(image,app.allocator);api.call_fail(call,api.SERVER_ERROR,"A frame could not be drawn");return}
            for y in 0..<side {
                for x in 0..<side {
                    from:=(y*side+x)*4
                    to:=((v*side+y)*width+frame*side+x)*4
                    alpha:=u32(pixels[from+3])
                    for c in 0..<3 {image[to+c]=u8((u32(pixels[from+c])*alpha+u32(image[to+c])*(255-alpha))/255)}
                }
            }
        }
    }
    write:host.Png_Write
    host.app_png_write_start(app,&write,path,image,width,height)
    if error:=host.app_png_write_wait(app,&write);error!=nil {api.call_failf(call,api.SERVER_ERROR,"%s could not be written: %s",path,os.error_string(error));return}
    report:=call.out
    serial.write_u8(report,'{');api.write_key(report,"id",true);api.write_id(report,captured_id);api.write_text(report,"image",path)
    api.write_int(report,"size",i64(side));api.write_bool(report,"short",st.sub.short)
    api.write_key(report,"frames");serial.write_u8(report,'[')
    for frame in 0..<frames {if frame>0 {serial.write_u8(report,',')};api.write_number(report,p.time+f32(st.ticks[frame])/CAPTURE_RATE)}
    serial.write_u8(report,']')
    api.write_key(report,"views");serial.write_u8(report,'[')
    for view,v in views {if v>0 {serial.write_u8(report,',')};serial.write_u8(report,'"');serial.text_write_raw(report,fmt.tprintf("%v",view));serial.write_u8(report,'"')}
    serial.text_write_raw(report,"]}")
    api.call_image(call,path)
}
