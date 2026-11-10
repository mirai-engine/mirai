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
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

@(storage)
Animation_Api :: struct {provider:editor.Api_Provider}

ANIMATION_API_DEFAULT :: Animation_Api{provider={register=register}}

Describe_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,optional"`,
    handle:core.Entity `mirai:"transient"`,
    asset:base.Asset_Id `mirai:"optional"`,
    mesh:base.Asset_Id `mirai:"optional"`,
    skeleton:base.Asset_Id `mirai:"optional"`,
    offset:u32 `mirai:"optional"`,
    limit:u32 `mirai:"optional,min=1,max=1024,clamp"`,
}

@(private="file")
PATH_CAPACITY :: asset.NODE_PATH_CAPACITY // the field asset hides the package in Play_Params

Play_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    asset:base.Asset_Id `mirai:"optional,label=An .anim; a .match, its locomotion; or an .agraph whose parameters go through animation.request; omitted keeps what it plays"`,
    clip:[64]u8 `mirai:"text,optional,label=A clip of the .anim; on layer 0 only with an .anim asset"`,
    speed:f32 `mirai:"optional"`,
    fade:f32 `mirai:"optional,min=0"`,
    loop:bool `mirai:"optional"`,
    layer:u32 `mirai:"optional,max=3,label=0 is the base; 1 to 3 play a clip over any source"`,
    over:[PATH_CAPACITY]u8 `mirai:"text,optional"`,
    sync:bool `mirai:"optional"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    mode:anim.Layer_Mode `mirai:"optional"`,
    reference:f32 `mirai:"optional,min=0,unit=s,label=Additive layer: the time of reference_clip whose pose its clip is added over"`,
    reference_clip:[64]u8 `mirai:"text,optional,label=Additive layer: a clip of the .anim whose pose at reference it adds the difference of its clip to, as an emote over a stand; empty is its own clip"`,
    curves:anim.Curve_Blend `mirai:"optional"`,
    mesh_space:bool `mirai:"optional,label=Override layer: its rotations blend in the space of the rig, keeping the turn of its clip whatever the base turns above it"`,
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
    parameters:[anim.GRAPH_PARAMETERS]Preview_Parameter `mirai:"optional"`,
    controls:[64]Preview_Control `mirai:"optional"`,
    goals:[64]Preview_Goal `mirai:"optional"`,
    plays:[16]Request_Play `mirai:"optional"`,
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
    describe_defaults:=Describe_Params{limit=256}
    play_defaults:=Play_Params{speed=1,fade=0.2,loop=true,weight=1}
    preview_defaults:=new(Preview_Params,context.temp_allocator);if preview_defaults==nil {return}
    preview_defaults.dt,preview_defaults.limit,preview_defaults.trace_limit=1.0/60,256,16
    request_rows_defaults(preview_defaults)
    editor.api_method_register(s,{name="animation.play",summary="Plays a clip, the motion matching of a .match or a graph on an entity, or a clip on a layer over it. One step of undo in Edit; in Play it changes the running world.",params=Play_Params,params_info=type_info_of(Play_Params),result=Control_Result,result_info=type_info_of(Control_Result),defaults=&play_defaults,run=play})
    authoring_method_register(s,{name="animation.preview",summary="Evaluates an entity on a copy of the world with the fields of animation.request scheduled by tick and returns its poses; the document and the running world stay intact.",params=Preview_Params,params_info=type_info_of(Preview_Params),defaults=preview_defaults,flags={.Read_Only},run=preview},Preview_Result,type_info_of(Preview_Result))
}

@(private)
within :: proc(w:core.World_Ref,entity,root:core.Entity) -> bool {
    entity:=entity
    parents:=core.world_table_of(w,core.Parent)
    if parents==nil {return entity==root}
    for depth:=0;entity!=core.NONE && depth<=len(parents.values);depth+=1 {
        if entity==root {return true}
        parent,found:=core.get(core.read(parents),entity)
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
    if !finite(p.speed) || !finite(p.fade) || p.fade<0 || !finite(p.weight) {authoring_failure(call,"speed","Invalid_Value","finite speed, fade and weight; nonnegative fade",fmt.tprintf("speed=%v fade=%v weight=%v",p.speed,p.fade,p.weight),"Animation playback settings are invalid");return}
    w,e,ok:=subject(s,call,p.entity[:]);if !ok {return}
    table:=core.world_table_of(w,anim.Animation)
    if table==nil {authoring_failure(call,"Animation","Unavailable","the animation runtime table","missing table","Animation runtime is not present",api.SERVER_ERROR);return}
    value,present:=core.get(core.read(table),e)
    if !present {value=anim.ANIMATION_DEFAULT}
    if p.asset!={} {value.asset=p.asset}
    source,loaded:=program_source(s,call,value.asset,value.library);if !loaded {return}
    content:=host.content_animation_wait(s.app,source)
    if content==nil {authoring_failure(call,"asset","Invalid_Asset","a loadable animation source","source load failed","The animation asset could not be loaded");return}
    name:=base.text_get(p.clip[:])
    if source!=value.asset && p.layer==0 && name!="" {authoring_failure(call,"clip","Program_Source","a clip on a layer over a .match or .agraph","base clip supplied","A base clip requires an .anim asset",fix="Pass layer 1 to 3 to play it over, or ask the .match for it with animation.request plays");return}
    if name!="" && lib.clip_find(&content.lib,base.name_hash(name))==0 {authoring_failure(call,"clip","Missing_Clip","a clip name in the source",name,"The clip does not exist in this animation asset");return}
    reference:=base.text_get(p.reference_clip[:])
    if reference!="" && (p.layer==0 || p.mode!=.Additive) {authoring_failure(call,"reference_clip","Not_Additive","an Additive layer from 1 to 3",fmt.tprintf("layer %d in %v mode",p.layer,p.mode),"Only an additive layer adds its clip over a reference clip",fix="Pass mode Additive and layer 1 to 3, or leave reference_clip out");return}
    if reference!="" && lib.clip_find(&content.lib,base.name_hash(reference))==0 {authoring_failure(call,"reference_clip","Missing_Clip","a clip name in the source",reference,"The reference clip does not exist in this animation asset",fix="Name a clip of the .anim (animation.inspect lists them), or leave it out to subtract the clip's own pose");return}
    if !anim.animation_play(&value,name,p.fade,p.loop,int(p.layer),base.text_get(p.over[:]),p.sync,p.weight,p.speed,p.mode,p.reference,p.curves,p.mesh_space,reference) {authoring_failure(call,"layer","Invalid_Value","a valid layer and supported playback policies",fmt.tprintf("%d",p.layer),"The animation layer or its policies are invalid");return}
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

@(private)
describe :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Describe_Params)
    animation_id,mesh_id,skeleton_id:=p.asset,p.mesh,p.skeleton
    if p.entity[0]!=0 || p.handle!=core.NONE {
        w,e,ok:=subject(s,call,p.entity[:],p.handle);if !ok {return}
        if a,has:=editor.entity_get(w,e,anim.Animation);has && animation_id=={} {animation_id=a.library if a.library!={} else a.asset}
        if skeleton_id=={} {skeleton_id=rig_skeleton(s,w,e)}
        if m,has:=editor.entity_get(w,e,erender.Mesh_Renderer);has && mesh_id=={} {mesh_id=m.mesh}
        if mesh_id=={} {
            meshes:=core.world_table_of(w,erender.Mesh_Renderer)
            if meshes!=nil {for m,i in meshes.values {if m.mesh!={} && within(w,meshes.entities[i],e) {mesh_id=m.mesh;break}}}
        }
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
    out:=call.out
    serial.text_write_raw(out,`{"clips":[`)
    for &clip,i in animation.clips {
        if i>0 {serial.text_write_raw(out,",")}
        duration:f32
        for track in animation.tracks[clip.first_track:][:clip.track_count] {
            if track.key_count>0 {duration=max(duration,animation.keys[track.first_key+track.key_count-1].time)}
        }
        for marker in animation.markers[clip.first_marker:][:clip.marker_count] {duration=max(duration,marker.time)}
        serial.text_write_raw(out,"{");api.write_text(out,"name",base.text_get(clip.name[:]),true)
        api.write_key(out,"duration");api.write_number(out,duration)
        api.write_uint(out,"tracks",u64(clip.track_count));api.write_uint(out,"markers",u64(clip.marker_count));serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,"]");api.write_int(out,"bones_total",i64(len(skeleton.bones)));api.write_int(out,"joints",i64(len(mesh.joints)))
    api.write_key(out,"bones");serial.text_write_raw(out,"[")
    start:=min(int(p.offset),len(skeleton.bones));end:=min(start+int(p.limit),len(skeleton.bones))
    pairs,paired:=anim.skeleton_mirror_pairs(skeleton.bones,call.allocator)
    if !paired {authoring_failure(call,"bones","Out_Of_Memory","memory for mirror pairs","allocation failed","The skeleton could not be described",api.SERVER_ERROR);return}
    for &node,i in skeleton.bones[start:end] {
        if i>0 {serial.text_write_raw(out,",")}
        serial.text_write_raw(out,"{");api.write_int(out,"index",i64(start+i),true);api.write_text(out,"name",base.text_get(node.name[:]))
        api.write_text(out,"path",base.text_get(node.path[:]));api.write_int(out,"parent",i64(node.parent));api.write_int(out,"mirror",i64(pairs[start+i]))
        api.write_numbers(out,"position",node.translation);api.write_numbers(out,"scale",node.scale)
        rotation:=[4]f32{node.rotation.x,node.rotation.y,node.rotation.z,node.rotation.w}
        api.write_numbers(out,"rotation",rotation[:]);serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,"]}")
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
    trace:Preview_Trace
    buffer:=make([]u8,PREVIEW_TRACE_BYTES+1,call.allocator);defer delete(buffer,call.allocator)
    if buffer==nil {authoring_failure(call,"trace","Out_Of_Memory","memory for the preview trace","allocation failed","The preview trace could not be allocated",api.SERVER_ERROR);return}
    serial.writer_init_fixed(&trace.writer,buffer)
    animation,_:=editor.entity_get(world,e,anim.Animation)
    source_file,graph_file:Authoring_File;defer asset.asset_close(&source_file.file);defer asset.asset_close(&graph_file.file)
    if animation.asset!={} {
        source_id,valid:=program_source(s,call,animation.asset,animation.library);if !valid {return}
        trace.view,valid=program_animation_open(s,call,source_id,&source_file);if !valid {return}
        if record,found:=asset.registry_find(&s.app.assets.registry,animation.asset);found && record.kind==anim.GRAPH_KIND {trace.graph,valid=program_graph_open(s,call,animation.asset,&graph_file);if !valid {return}}
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
    out:=call.out
    serial.text_write_raw(out,"{");api.write_key(out,"id",true);api.write_id(out,editor.api_entity_id(source,e))
    progress,_,ended,_:=anim.animation_progress(core.world_storage_of(world,anim.Playback),e);api.write_key(out,"time");api.write_number(out,progress);api.write_bool(out,"ended",ended)
    selected:^anim.Playing;for &state in playback.states {if state.entity==e {selected=&state;break}}
    api.write_key(out,"program");preview_program_write(call,world,s.app,selected,animation,trace.graph)
    api.write_key(out,"poses");serial.text_write_raw(out,"[")
    total,written:=0,0
    if skeleton_id!={} {
        cache:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Skeleton_Assets)
        content:=anim.skeleton_content(cache,s.app.assets,s.app.allocator,skeleton_id)
        playback:=core.world_storage_of(world,anim.Playback)
        if content!=nil && playback!=nil {
            for &state in playback.states {
                if state.entity!=e || !state.pose_ready {continue}
                total=len(content.bones)
                start:=min(int(p.offset),total);end:=min(start+int(p.limit),total)
                for &bone,i in content.bones[start:end] {
                    index:=start+i+1
                    if index>=len(state.local) {break}
                    value:=state.local[index]
                    if written>0 {serial.text_write_raw(out,",")};written+=1
                    serial.text_write_raw(out,"{");api.write_key(out,"id",true);api.write_id(out,0);api.write_text(out,"path",base.text_get(bone.path[:]))
                    api.write_text(out,"name",base.text_get(bone.name[:]))
                    api.write_numbers(out,"position",value.position);api.write_numbers(out,"scale",value.scale)
                    rotation:=[4]f32{value.rotation.x,value.rotation.y,value.rotation.z,value.rotation.w}
                    api.write_numbers(out,"rotation",rotation[:]);serial.text_write_raw(out,"}")
                }
                break
            }
        }
        serial.text_write_raw(out,"]");api.write_int(out,"total",i64(total));api.write_int(out,"shown",i64(written));preview_trace_result(call,&trace,p);serial.text_write_raw(out,"}")
        return
    }
    for value,i in transforms.values {
        entity:=transforms.entities[i]
        if !within(world,entity,e) {continue}
        total+=1
        if total<=int(p.offset) || written>=int(p.limit) {continue}
        if written>0 {serial.text_write_raw(out,",")}
        written+=1
        serial.text_write_raw(out,"{");api.write_key(out,"id",true)
        id,_:=core.get(core.read(ids),entity);api.write_id(out,id.value)
        api.write_text(out,"name",core.name_get(core.read(names),entity))
        target,_:=core.get(core.read(targets),entity);api.write_text(out,"path",base.text_get(target.path[:]))
        api.write_numbers(out,"position",value.position);api.write_numbers(out,"scale",value.scale)
        rotation:=[4]f32{value.rotation.x,value.rotation.y,value.rotation.z,value.rotation.w}
        api.write_numbers(out,"rotation",rotation[:]);serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,"]");api.write_int(out,"total",i64(total));api.write_int(out,"shown",i64(written));preview_trace_result(call,&trace,p);serial.text_write_raw(out,"}")
}
