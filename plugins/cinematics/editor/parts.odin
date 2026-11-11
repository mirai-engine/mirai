package cinematics_editor

import "core:mem"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import cam "mirai:engine/camera"
import erender "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import cine "plugins:cinematics/runtime"

// What the tool and the methods write into a timeline: the entity with its Cinematic and its
// Animation, and the actors its clip moves by reference. The keys and the markers (its shots on
// cameras, the actions of its actors) are those of the clip: the animation methods write them.

Part :: enum u8 {Timeline,Actor}

// The timeline an entity belongs to: itself, or the one whose clip moves it.
timeline_of :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    if editor.entity_has(w,e,cine.Cinematic) {return e}
    if target,ok:=editor.entity_get(w,e,anim.Animation_Target);ok && editor.entity_has(w,target.animation,cine.Cinematic) {return target.animation}
    return core.NONE
}

component_write :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity,value:$T) -> bool {
    value:=value
    _,info:=core.world_table(w,T)
    return editor.field_write(s,info,{e},0,mem.ptr_to_bytes(&value))
}

Part_Desc :: struct {
    part:Part,
    timeline:core.Entity,
    target:core.Entity, // the entity of an actor
    clip:base.Asset_Id, // the .anim of a timeline
    playing:bool,       // a timeline: it starts by itself
    name:string,        // of an actor: what the tracks and markers of the clip call it; empty: the name of its entity
}

// Makes a timeline at the root of the document or an actor of an entity of the scene, inside the
// step that is open. e: the timeline, or the entity that became an actor.
part_add :: proc(s:^editor.Session,w:core.World_Ref,desc:Part_Desc) -> (e:core.Entity,problem:string) {
    add :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity,value:$T) {
        value:=value
        _,info:=core.world_table(w,T)
        editor.component_add(s,e,info,&value)
    }
    if desc.part!=.Timeline && !editor.entity_has(w,desc.timeline,cine.Cinematic) {return core.NONE,"the timeline has no Cinematic"}
    switch desc.part {
    case .Timeline:
        e=editor.entity_create(s,{name="Cinematic"})
        if e==core.NONE {return core.NONE,"the entity could not be created"}
        animation:=anim.ANIMATION_DEFAULT
        animation.asset,animation.playing,animation.loop,animation.fade=desc.clip,desc.playing,false,0
        add(s,w,e,animation)
        add(s,w,e,cine.Cinematic{})
    case .Actor:
        if !editor.entity_alive(w,desc.target) {return core.NONE,"the actor is not an entity of the scene"}
        if desc.target==desc.timeline {return core.NONE,"the timeline is the entity its clip moves with the tracks without a target: it needs no actor"}
        name:=desc.name if desc.name!="" else editor.entity_name(w,desc.target)
        target,had:=editor.entity_get(w,desc.target,anim.Animation_Target)
        if name=="" || len(name)>=len(target.path) {return core.NONE,"an actor needs a name, of its entity or given, shorter than a track target"}
        base.text_set(target.path[:],name)
        target.animation=desc.timeline
        if had {component_write(s,w,desc.target,target)} else {add(s,w,desc.target,target)}
        e=desc.target
    }
    return e,""
}

// What the clip of a timeline calls an actor: the target of its tracks and markers.
actor_target :: proc(w:core.World_Ref,e:core.Entity) -> string {
    target,_:=editor.entity_get(w,e,anim.Animation_Target)
    path:=base.text_get(target.path[:])
    return strings.clone(path,context.temp_allocator) if path!="" else editor.entity_name(w,e)
}

// What the seat sees at a time of the clip of a timeline, with the scene as the clip puts it there:
// the camera of the shot in force, blended in from the one before it as engine/camera blends it.
shot_view :: proc(s:^editor.Session,w:core.World_Ref,timeline:core.Entity,time:f32) -> (shot:cine.Shot,pose:erender.View_Pose,ok:bool) {
    camera_pose :: proc(w:core.World_Ref,camera:core.Entity) -> (erender.View_Pose,bool) {
        lens,found:=editor.entity_get(w,camera,erender.Camera)
        if !found || !editor.entity_has(w,camera,core.Transform) {return {},false}
        return erender.camera_pose(lens,editor.entity_world(w,camera)),true
    }
    cameras:=core.world_table_of(w,erender.Camera)
    playback,sources:=core.world_storage_of(w,anim.Playback),core.world_storage_of(w,anim.Source_Assets)
    if cameras==nil || playback==nil || s.app==nil {return}
    previous:cine.Shot
    shot,previous=cine.cinematic_shot(playback,sources,s.app,core.world_entities(w),cameras,timeline,time)
    pose=camera_pose(w,shot.camera) or_return
    since:=time-shot.time
    if from,found:=camera_pose(w,previous.camera);found && shot.blend.seconds>0 && since<shot.blend.seconds {
        pose=cam.pose_mix(from,pose,pose.position+mm.quat_forward(pose.rotation)*10,false,mm.ease_apply(shot.blend.ease,since/shot.blend.seconds))
    }
    return shot,pose,true
}
