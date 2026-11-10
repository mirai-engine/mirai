package cinematics_editor

import "core:fmt"
import "core:mem"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import cine "plugins:cinematics/runtime"

// What the tool and the methods write into a timeline: the entity with its
// Cinematic and its Animation, its shots as entities under it, and the actors
// its clip moves by reference. The keys are those of the clip: the animation
// methods write them.

Part :: enum u8 {Timeline,Shot,Actor}

// What the clip of a timeline lasts in the tool before it has one.
EMPTY_SECONDS :: 5

// The timeline an entity belongs to: itself, or the one its shot or viewer
// names, or the one whose clip moves it.
timeline_of :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    if editor.entity_has(w,e,cine.Cinematic) {return e}
    if shot,ok:=editor.entity_get(w,e,cine.Cinematic_Shot);ok {return shot.timeline}
    if viewer,ok:=editor.entity_get(w,e,cine.Cinematic_Viewer);ok {return viewer.timeline}
    if target,ok:=editor.entity_get(w,e,anim.Animation_Target);ok && editor.entity_has(w,target.animation,cine.Cinematic) {return target.animation}
    return core.NONE
}

// Ticks per second of the fixed loop, as the settings of the project have it.
tick_rate :: proc(s:^editor.Session) -> f32 {
    if s.app!=nil && s.app.shared!=nil {
        if settings:=core.world_storage_of(core.world_ref(s.app.shared,s.app.info,.Shared),core.Simulation_Settings);settings!=nil && settings.tick_rate>0 {return f32(settings.tick_rate)}
    }
    return f32(core.SIMULATION_SETTINGS_DEFAULT.tick_rate)
}

component_write :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity,value:$T) -> bool {
    value:=value
    _,info:=core.world_table(w,T)
    return editor.field_write(s,info,{e},0,mem.ptr_to_bytes(&value))
}

// The seconds the clip of a timeline lasts, as the animation of the world plays it; EMPTY_SECONDS
// while it has none.
duration_of :: proc(w:core.World_Ref,timeline:core.Entity) -> f32 {
    if _,duration,_,ok:=anim.animation_progress(core.world_storage_of(w,anim.Playback),timeline);ok && duration>0 {return duration}
    return EMPTY_SECONDS
}

Part_Desc :: struct {
    part:Part,
    timeline:core.Entity,
    target:core.Entity, // the camera of a shot, the entity of an actor
    clip:base.Asset_Id, // the .anim of a timeline
    playing:bool,       // a timeline: it starts by itself
    time,blend:f32,     // of a shot, seconds
    ease:mm.Ease,
    name:string,        // of an actor: what the tracks of the clip call it; empty: the name of its entity
}

// Makes a timeline at the root of the document, a shot under its timeline, or
// an actor of an entity of the scene, inside the step that is open. e: the
// timeline, the shot, or the entity that became an actor.
part_add :: proc(s:^editor.Session,w:core.World_Ref,desc:Part_Desc) -> (e:core.Entity,problem:string) {
    add :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity,value:$T) {
        value:=value
        _,info:=core.world_table(w,T)
        editor.component_add(s,e,info,&value)
    }
    if desc.part!=.Timeline && !editor.entity_has(w,desc.timeline,cine.Cinematic) {return core.NONE,"the timeline has no Cinematic"}
    switch desc.part {
    case .Timeline:
        e=editor.entity_create(s,{preset=.Empty,name="Cinematic"})
        if e==core.NONE {return core.NONE,"the entity could not be created"}
        animation:=anim.ANIMATION_DEFAULT
        animation.asset,animation.playing,animation.loop,animation.fade=desc.clip,desc.playing,false,0
        add(s,w,e,animation)
        add(s,w,e,cine.Cinematic{})
    case .Shot:
        if !editor.entity_has(w,desc.target,erender.Camera) {return core.NONE,"the camera of the shot has no Camera"}
        if !(desc.time>=0) || !(desc.blend>=0) {return core.NONE,"the time and the blend of a shot are seconds, 0 or more"}
        e=editor.entity_create(s,{preset=.Empty,name=fmt.tprintf("Shot %s",editor.entity_label(w,desc.target)),parent=desc.timeline})
        if e==core.NONE {return core.NONE,"the entity could not be created"}
        add(s,w,e,cine.Cinematic_Shot{timeline=desc.timeline,camera=desc.target,time=desc.time,blend=desc.blend,ease=desc.ease})
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

// The view of a camera of the scene as a shot shows it.
camera_at :: proc(w:core.World_Ref,camera:core.Entity) -> (sample:cine.Camera_Sample,ok:bool) {
    lens:=editor.entity_get(w,camera,erender.Camera) or_return
    if !editor.entity_has(w,camera,core.Transform) {return}
    return {editor.entity_world(w,camera),lens.fov,lens.near},true
}

// What the viewers of a timeline show at a time of its clip, with the scene as it is: the shot in
// force, blending in from the one before it.
shot_view :: proc(w:core.World_Ref,timeline:core.Entity,time:f32) -> (shot:cine.Cinematic_Shot,sample:cine.Camera_Sample,ok:bool) {
    shots:=core.world_table_of(w,cine.Cinematic_Shot)
    if shots==nil {return}
    previous:cine.Cinematic_Shot
    shot,previous=cine.cinematic_shots_at(core.read(shots),timeline,time) or_return
    sample=camera_at(w,shot.camera) or_return
    if from,found:=camera_at(w,previous.camera);found && previous.camera!=core.NONE {sample=cine.cinematic_shot_blend(shot,from,sample,time)}
    return shot,sample,true
}
