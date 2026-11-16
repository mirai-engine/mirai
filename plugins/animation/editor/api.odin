package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import anim "plugins:animation/runtime"

@(storage)
Animation_Api :: struct {provider:editor.Api_Provider}

ANIMATION_API_DEFAULT :: Animation_Api{provider={register=register}}


@(private="file")
PATH_CAPACITY :: asset.NODE_PATH_CAPACITY // the field asset hides the package in Play_Params

Play_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    asset:base.Asset_Id `mirai:"optional,label=An .anim; or a .character, its locomotion; omitted keeps what it plays"`,
    clip:[64]u8 `mirai:"text,optional,label=A clip of the .anim; only with an .anim asset"`,
    speed:f32 `mirai:"optional"`,
    fade:f32 `mirai:"optional,min=0"`,
    loop:bool `mirai:"optional"`,
}

// handle: the one animation.inspect resolved, which subject takes over entity.
Entity_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    handle:core.Entity `mirai:"transient"`,
}


Preview_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    time:f32 `mirai:"optional,min=0"`,
    ticks:u32 `mirai:"optional,min=0,max=3600,label=Ticks of dt the copy runs; plays and actions go at their tick"`,
    dt:f32 `mirai:"optional,min=0.0001,max=0.25"`,
    offset:u32 `mirai:"optional"`,
    limit:u32 `mirai:"optional,min=1,max=1024,clamp"`,
    parameters:[anim.STACK_PARAMETERS]Preview_Parameter `mirai:"optional"`,
    controls:[64]Preview_Control `mirai:"optional"`,
    goals:[64]Preview_Goal `mirai:"optional"`,
    actions:[64]Preview_Action `mirai:"optional"`,
    motion:[16]Request_Motion `mirai:"optional"`,
    locomotion:Request_Locomotion `mirai:"optional"`,
    distance:Request_Distance `mirai:"optional"`,
    locomote:Intent_Locomote `mirai:"optional"`,
    look:Intent_Look `mirai:"optional"`,
    gesture:Intent_Gesture `mirai:"optional"`,
    reach:[2]Intent_Reach `mirai:"optional"`,
    trace:bool `mirai:"optional,label=A trace per tick: leaf weights clocks and groups; events; Float and Vector curves; root deltas; what matching plays and diagnostics"`,
    trace_offset:u32 `mirai:"optional,max=3600"`,
    trace_limit:u32 `mirai:"optional,min=1,max=64"`,
}

Control_Result :: struct {id:base.Entity_Id,playing:bool,time:f32}

@(private)
register :: proc(s:^editor.Session) {
    authoring_register(s)
    program_register(s)
    morph_register(s)
    history_register(s)
    play_defaults:=Play_Params{speed=1,fade=0.2,loop=true}
    preview_defaults:=new(Preview_Params,context.temp_allocator);if preview_defaults==nil {return}
    preview_defaults.dt,preview_defaults.limit,preview_defaults.trace_limit=1.0/60,256,16
    request_rows_defaults(preview_defaults)
    editor.api_method_register(s,{params=type_info_of(Play_Params),result=type_info_of(Control_Result),name="animation.play",summary="Plays a clip of an .anim or a .character, its locomotion by motion matching, on an entity. What plays over it are the layers and actions of its .character (animation.action.set, animation.request). One step of undo in Edit; in Play it changes the running world.",defaults=&play_defaults,run=play})
    editor.api_method_register(s,{params=type_info_of(Preview_Params),result=type_info_of(Preview_Result),name="animation.preview",summary="Evaluates an entity on a copy of the world with the fields of animation.request scheduled by tick and returns its poses; the document and the running world stay intact.",defaults=preview_defaults,flags={.Read_Only},run=preview})
}

@(private)
within :: proc(w:core.World_Ref,entity,root:core.Entity) -> bool {
    entity:=entity
    parents:=core.world_table_of(w,core.Parent)
    if parents==nil {return entity==root}
    for depth:=0;entity!=core.NONE && depth<=len(parents.values);depth+=1 {
        if entity==root {return true}
        parent,found:=core.get(parents,entity)
        entity=parent.entity if found else core.NONE
    }
    return false
}

// The entity a call names in the world the editor shows, or entity when it is alive there.
@(private)
subject :: proc(s:^editor.Session,call:^api.Call,named:[]u8,entity:=core.NONE) -> (w:core.World_Ref,e:core.Entity,ok:bool) {
    w=editor.shown_world(s)
    if entity!=core.NONE && core.alive(core.world_entities(w),entity) {return w,entity,true}
    problem:string
    if e,problem=editor.api_entity_select(w,base.text_get(named),"entity",s.mode!=.Edit,call.allocator);problem!="" {
        authoring_failure(call,"entity","Missing_Entity","an entity in the shown world",base.text_get(named),"The animation entity does not exist",fix=problem);return
    }
    return w,e,true
}

@(private)
control_result :: proc(s:^editor.Session,call:^api.Call,w:core.World_Ref,e:core.Entity) {
    out:=api.call_result(call,Control_Result)
    out.id=editor.api_entity_id(w,e)
    if value,ok:=editor.entity_get(w,e,anim.Animation);ok {out.playing=value.playing}
    if time,_,_,ok:=anim.animation_progress(core.world_storage_of(w,anim.Playback),e);ok {out.time=time}
}

@(private)
finite :: proc "contextless" (value:f32) -> bool {return abs(value)<=max(f32)}

@(private)
edit_begin :: proc(s:^editor.Session,call:^api.Call,label:string) -> bool {
    if s.mode==.Edit {
        okay:=editor.api_edit_begin(s,call,label)
        if !okay {authoring_failure(call,"mode","Edit_Blocked","an available Edit transaction",call.error.message,call.error.message,call.error.code)}
        return okay
    }
    return true
}

@(private)
edit_end :: proc(s:^editor.Session,call:^api.Call,w:core.World_Ref,ok:bool) -> bool {
    core.world_settle(w)
    if s.mode==.Edit {
        okay:=editor.api_edit_end(s,call,ok)
        if !okay && call.error.data=="" {authoring_failure(call,"edit","Apply_Failed","an applicable edit transaction",call.error.message,call.error.message,call.error.code)}
        return okay
    }
    if !ok {authoring_failure(call,"request","Apply_Failed","an applicable animation request","runtime request failed","The animation request could not be applied",api.SERVER_ERROR)}
    return ok
}

@(private)
play :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Play_Params)
    if !finite(p.speed) || !finite(p.fade) || p.fade<0 {authoring_failure(call,"speed","Invalid_Value","finite speed and fade; nonnegative fade",fmt.tprintf("speed=%v fade=%v",p.speed,p.fade),"Animation playback settings are invalid");return}
    w,e,ok:=subject(s,call,p.entity[:]);if !ok {return}
    table:=core.world_table_of(w,anim.Animation)
    if table==nil {authoring_failure(call,"Animation","Unavailable","the animation runtime table","missing table","Animation runtime is not present",api.SERVER_ERROR);return}
    value,present:=core.get(table,e)
    if !present {value=anim.ANIMATION_DEFAULT}
    if p.asset!={} {value.asset=p.asset}
    source,loaded:=program_source(s,call,value.asset,value.library);if !loaded {return}
    content:=host.content_animation_wait(s.app,source)
    if content==nil {authoring_failure(call,"asset","Invalid_Asset","a loadable animation source","source load failed","The animation asset could not be loaded");return}
    name:=base.text_get(p.clip[:])
    if source!=value.asset && name!="" {authoring_failure(call,"clip","Program_Source","no clip with a .character whose locomotion picks its clips","base clip supplied","The locomotion of a .character picks its clips",fix="Play a clip over it as an action of its .character: animation.action.set, then animation.request actions");return}
    if name!="" && lib.clip_find(&content.lib,base.name_hash(name))==0 {authoring_failure(call,"clip","Missing_Clip","a clip name in the source",name,"The clip does not exist in this animation asset");return}
    if !anim.animation_clip(&value,name,p.fade,p.loop) {authoring_failure(call,"clip","Invalid_Value","a clip name under 64 bytes",name,"The clip could not be set");return}
    value.speed,value.playing=p.speed,true
    if !edit_begin(s,call,"Play animation") {return}
    core.add(table,e,value)
    if !edit_end(s,call,w,true) {return}
    control_result(s,call,w,e)
}

@(private)
asset_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,file:^asset.Asset) -> bool {
    if s.app==nil || s.app.assets==nil {authoring_failure(call,"assets","Unavailable","an asset registry","missing registry","Assets are unavailable",api.SERVER_ERROR);return false}
    a:=s.app.assets
    record,found:=asset.registry_find(&a.registry,id)
    if !found {authoring_failure(call,"asset","Missing_Asset","an asset in the registry",fmt.tprintf("%v",id),"The asset does not exist");return false}
    data,error:=asset.registry_read(&a.registry,record.path,s.app.allocator)
    if error==.None {error=asset.asset_take(file,data,s.app.allocator)}
    if error!=.None {authoring_failure(call,"asset","Read_Failed","a readable asset",fmt.tprintf("%v",error),"The asset could not be read");return false}
    return true
}

// The clips its animation plays and a page of the bones of its skeleton, with their mirror.
@(private)
instance_rig :: proc(s:^editor.Session,call:^api.Call,w:core.World_Ref,e:core.Entity,p:^Instance_Inspect_Params) -> (r:Instance_Rig) {
    animation_id,mesh_id,skeleton_id:base.Asset_Id
    if a,has:=editor.entity_get(w,e,anim.Animation);has {animation_id=a.library if a.library!={} else a.asset}
    skeleton_id=rig_skeleton(s,w,e)
    if m,has:=editor.entity_get(w,e,erender.Mesh_Renderer);has {mesh_id=m.mesh}
    if mesh_id=={} {
        meshes:=core.world_table_of(w,erender.Mesh_Renderer)
        if meshes!=nil {for m,i in meshes.values {if m.mesh!={} && within(w,meshes.entities[i],e) {mesh_id=m.mesh;break}}}
    }
    animation_file,mesh_file,skeleton_file:asset.Asset
    defer asset.asset_close(&animation_file)
    defer asset.asset_close(&mesh_file)
    defer asset.asset_close(&skeleton_file)
    animation:asset.Animation_View
    mesh:asset.Mesh_View
    skeleton:asset.Skeleton_View
    if animation_id!={} {
        source,loaded:=program_source(s,call,animation_id);if !loaded {return}
        animation_id=source
        if !asset_open(s,call,animation_id,&animation_file) {return}
        error:asset.Error
        animation,error=asset.animation_view(&animation_file,&s.app.assets.types)
        if error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .anim asset",fmt.tprintf("%v",error),"The asset is not a valid animation");return}
    }
    if mesh_id!={} {
        if !asset_open(s,call,mesh_id,&mesh_file) {return}
        error:asset.Error
        mesh,error=asset.mesh_view(&mesh_file,&s.app.assets.types)
        if error!=.None {authoring_failure(call,"mesh","Invalid_Asset","a valid .mesh asset",fmt.tprintf("%v",error),"The asset is not a valid mesh");return}
        if skeleton_id=={} && mesh.info!=nil {skeleton_id=mesh.info.skeleton}
    }
    if skeleton_id!={} {
        if !asset_open(s,call,skeleton_id,&skeleton_file) {return}
        error:asset.Error
        skeleton,error=asset.skeleton_view(&skeleton_file,&s.app.assets.types)
        if error!=.None {authoring_failure(call,"skeleton","Invalid_Asset","a valid .skeleton asset",fmt.tprintf("%v",error),"The asset is not a valid skeleton");return}
    }
    r.clips=make([]Instance_Clip,len(animation.clips),call.allocator)
    for &row,i in r.clips {
        clip:=animation.clips[i]
        duration:f32
        for track in animation.tracks[clip.first_track:][:clip.track_count] {
            if track.key_count>0 {duration=max(duration,animation.keys[track.first_key+track.key_count-1].time)}
        }
        for marker in animation.markers[clip.first_marker:][:clip.marker_count] {duration=max(duration,marker.time)}
        row={name=clip.name,duration=duration,tracks=u32(clip.track_count),markers=u32(clip.marker_count)}
    }
    r.bones_total,r.joints=u32(len(skeleton.bones)),u32(len(mesh.joints))
    pairs,paired:=anim.skeleton_mirror_pairs(skeleton.bones,call.allocator)
    if !paired {authoring_failure(call,"bones","Out_Of_Memory","memory for mirror pairs","allocation failed","The skeleton could not be described",api.SERVER_ERROR);return}
    first:=min(int(p.offset),len(skeleton.bones))
    r.bones=make([]Instance_Bone,min(first+int(p.limit),len(skeleton.bones))-first,call.allocator)
    for &row,i in r.bones {
        node:=skeleton.bones[first+i]
        row={index=u32(first+i),name=node.name,path=node.path,parent=i32(node.parent),mirror=i32(pairs[first+i]),position=node.translation,scale=node.scale,rotation={node.rotation.x,node.rotation.y,node.rotation.z,node.rotation.w}}
    }
    return
}

@(private)
preview :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Preview_Params)
    source,e,ok:=subject(s,call,p.entity[:]);if !ok {return}
    skeleton_id:=rig_skeleton(s,source,e)
    e=pose_owner(s,source,e)
    if !editor.entity_has(source,e,anim.Animation) && skeleton_id=={} {authoring_failure(call,"entity","Missing_Component","Animation or a mesh with a skeleton","missing both","The entity has no Animation and shows no mesh with a skeleton");return}
    clone:=preview_world_clone(s,call,source)
    if clone==nil {return}
    defer host.app_world_free(s.app,clone)
    world:=core.world_ref(clone,s.info)
    requests:=core.world_storage_of(world,anim.Animation_Requests)
    trace:=Preview_Trace{frames=make([dynamic]Preview_Trace_Result,call.allocator)}
    animation,_:=editor.entity_get(world,e,anim.Animation)
    source_file:Authoring_File;defer asset.asset_close(&source_file.file)
    if animation.asset!={} {
        source_id,valid:=program_source(s,call,animation.asset,animation.library);if !valid {return}
        trace.view,valid=program_animation_open(s,call,source_id,&source_file);if !valid {return}
    }
    if !request_source_check(s,call,world,e) || !request_apply(s,call,world,e,p,p.ticks,nil) {return}
    animation,_=editor.entity_get(world,e,anim.Animation)
    if requests!=nil {anim.animation_seek(requests,e,p.time)}
    if requests==nil || !anim.animation_evaluate(world,s.app,0) {
        authoring_failure(call,"preview","Evaluation_Failed","a valid animation request and evaluable preview world","initial evaluation failed","The animation preview could not be evaluated",api.SERVER_ERROR);return
    }
    preview_trace_frame(call,&trace,world,e,p,0,s.app)
    for tick in 1..=p.ticks {
        if !request_tick(call,world,e,p,tick) {return}
        if !anim.animation_evaluate(world,s.app,p.dt) {authoring_failure(call,"preview","Evaluation_Failed","an evaluable preview world",fmt.tprintf("tick %d",tick),"The animation preview could not advance",api.SERVER_ERROR);return}
        preview_trace_frame(call,&trace,world,e,p,tick,s.app)
    }
    playback:=core.world_storage_of(world,anim.Playback)
    evaluated:=false
    if playback!=nil {for &state in playback.states {if state.entity==e && state.seen==playback.frame && state.pose_ready {evaluated=true;break}}}
    if !evaluated {authoring_failure(call,"preview","Unbound_Pose","valid source assets and resolved bone bindings","no ready pose","The requested rig or animation could not be evaluated");return}
    transforms:=core.world_table_of(world,core.Transform)
    ids:=core.world_table_of(world,core.Id)
    targets:=core.world_table_of(world,anim.Animation_Target)
    names:=core.world_table_of(world,core.Name)
    r:=api.call_result(call,Preview_Result)
    r.id=editor.api_entity_id(source,e)
    r.time,_,r.ended,_=anim.animation_progress(core.world_storage_of(world,anim.Playback),e)
    selected:^anim.Playing;for &state in playback.states {if state.entity==e {selected=&state;break}}
    r.program=preview_program(call,world,s.app,selected,animation)
    defer preview_trace_result(r,&trace,p)
    poses:=make([dynamic]Preview_Pose_Result,call.allocator)
    defer r.poses,r.shown=poses[:],u32(len(poses))
    if skeleton_id!={} {
        cache:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Skeleton_Assets)
        content:=anim.skeleton_content(cache,s.app.assets,s.app.allocator,skeleton_id)
        if content==nil {return}
        for &state in playback.states {
            if state.entity!=e || !state.pose_ready {continue}
            r.total=u32(len(content.bones))
            start:=min(int(p.offset),len(content.bones));end:=min(start+int(p.limit),len(content.bones))
            for &bone,i in content.bones[start:end] {
                index:=start+i+1
                if index>=len(state.local) {break}
                value:=state.local[index]
                append(&poses,Preview_Pose_Result{path=bone.path,name=bone.name,position=value.position,scale=value.scale,rotation={value.rotation.x,value.rotation.y,value.rotation.z,value.rotation.w}})
            }
            break
        }
        return
    }
    for value,i in transforms.values {
        entity:=transforms.entities[i]
        if !within(world,entity,e) {continue}
        r.total+=1
        if int(r.total)<=int(p.offset) || len(poses)>=int(p.limit) {continue}
        id,_:=core.get(ids,entity)
        target,_:=core.get(targets,entity)
        row:=Preview_Pose_Result{id=id.value,path=target.path,position=value.position,scale=value.scale,rotation={value.rotation.x,value.rotation.y,value.rotation.z,value.rotation.w}}
        base.text_set(row.name[:],core.name_get(names,entity))
        append(&poses,row)
    }
}
