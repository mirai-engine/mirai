package cinematics_editor

import "core:fmt"
import "core:mem"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import cine "plugins:cinematics/runtime"

// What the tool and the methods write into a timeline: its parts as
// entities under it, the keys of its tracks, and the poses the preview puts
// its targets in.

Part :: enum u8 {Timeline,Track,Shot,Marker}

// The timeline an entity belongs to: itself, or the one its track, shot,
// marker or viewer names.
timeline_of :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    if editor.entity_has(w,e,cine.Cinematic) {return e}
    if track,ok:=editor.entity_get(w,e,cine.Cinematic_Track);ok {return track.timeline}
    if shot,ok:=editor.entity_get(w,e,cine.Cinematic_Shot);ok {return shot.timeline}
    if marker,ok:=editor.entity_get(w,e,cine.Cinematic_Marker);ok {return marker.timeline}
    if viewer,ok:=editor.entity_get(w,e,cine.Cinematic_Viewer);ok {return viewer.timeline}
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

// The value a track keys from its target as it is now: its place in the
// world, its own scale, or the lens of its camera.
track_capture :: proc(w:core.World_Ref,track:cine.Cinematic_Track) -> (value:mm.Vec4,ok:bool) {
    target:=track.target
    switch track.property {
    case .Position,.Rotation,.Scale:
        if !editor.entity_has(w,target,core.Transform) {return}
        world:=editor.entity_world(w,target)
        #partial switch track.property {
        case .Position: value.xyz=world.position
        case .Rotation: value=lib.quat_vec4(world.rotation)
        case .Scale: value.xyz=editor.entity_local(w,target).scale
        }
        return value,true
    case .Fov,.Near:
        lens:=editor.entity_get(w,target,erender.Camera) or_return
        value.x=track.property==.Fov?lens.fov:lens.near
        return value,true
    }
    return
}

// Puts a key at a tick, over the one there, or takes that one out; keys stay
// in the order of their ticks. False when the track is full or nothing is
// there to take out.
key_put :: proc(track:^cine.Cinematic_Track,key:lib.Keyframe,remove:=false) -> bool {
    count:=int(min(track.key_count,cine.CINEMATIC_KEYS))
    for &held,i in track.keys[:count] {
        if held.time!=key.time {continue}
        if remove {
            copy(track.keys[i:count-1],track.keys[i+1:count])
            track.keys[count-1]={}
            track.key_count=u32(count-1)
        } else {held=key}
        return true
    }
    if remove || count>=cine.CINEMATIC_KEYS {return false}
    at:=count
    for held,i in track.keys[:count] {if held.time>key.time {at=i;break}}
    copy(track.keys[at+1:count+1],track.keys[at:count])
    track.keys[at]=key
    track.key_count=u32(count+1)
    return true
}

// Moves the key at a tick to another, over the one there.
key_move :: proc(track:^cine.Cinematic_Track,from,to:f32) -> bool {
    count:=int(min(track.key_count,cine.CINEMATIC_KEYS))
    for held in track.keys[:count] {
        if held.time!=from {continue}
        moved:=held
        moved.time=to
        return key_put(track,held,true) && key_put(track,moved)
    }
    return false
}

Part_Desc :: struct {
    part:Part,
    timeline:core.Entity,
    target:core.Entity, // the entity of a track, the camera of a shot
    property:cine.Cinematic_Property,
    tick:u32,
    duration_ticks:u32, // of a timeline
    blend_ticks:u32,
    ease:mm.Ease,
    id:u64,             // of a marker
    values:[4]f32,
}

// Makes a part of a timeline under it, or a timeline at the root of the
// document, inside the step that is open. A track starts with a key at its
// tick, taken from its target.
part_add :: proc(s:^editor.Session,w:core.World_Ref,desc:Part_Desc) -> (e:core.Entity,problem:string) {
    if desc.part!=.Timeline && !editor.entity_has(w,desc.timeline,cine.Cinematic) {return core.NONE,"the timeline has no Cinematic"}
    name:string
    switch desc.part {
    case .Timeline: name="Cinematic"
    case .Track:
        if !editor.entity_alive(w,desc.target) {return core.NONE,"the target of the track is not an entity of the scene"}
        name=fmt.tprintf("%s %v",editor.entity_label(w,desc.target),desc.property)
    case .Shot:
        if !editor.entity_has(w,desc.target,erender.Camera) {return core.NONE,"the camera of the shot has no Camera"}
        name=fmt.tprintf("Shot %s",editor.entity_label(w,desc.target))
    case .Marker: name="Marker"
    }
    track:cine.Cinematic_Track
    if desc.part==.Track {
        track={timeline=desc.timeline,target=desc.target,property=desc.property}
        value,captured:=track_capture(w,track)
        if !captured {return core.NONE,fmt.tprintf("the target has no %s to key",desc.property==.Fov || desc.property==.Near?"Camera":"Transform")}
        key_put(&track,{time=f32(desc.tick),value=value})
    }
    e=editor.entity_create(s,{preset=.Empty,name=name,parent=desc.part==.Timeline?core.NONE:desc.timeline})
    if e==core.NONE {return core.NONE,"the entity could not be created"}
    switch desc.part {
    case .Timeline: add(s,w,e,cine.Cinematic{duration_ticks=max(desc.duration_ticks,1)})
    case .Track: add(s,w,e,track)
    case .Shot: add(s,w,e,cine.Cinematic_Shot{timeline=desc.timeline,camera=desc.target,tick=desc.tick,blend_ticks=desc.blend_ticks,ease=desc.ease})
    case .Marker: add(s,w,e,cine.Cinematic_Marker{timeline=desc.timeline,tick=desc.tick,id=desc.id,values=desc.values})
    }
    return e,""

    add :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity,value:$T) {
        value:=value
        _,info:=core.world_table(w,T)
        editor.component_add(s,e,info,&value)
    }
}

// Puts an entity at the value of a track in a step that is open: a place in
// the world, keeping what the track does not say, or its own scale.
target_place :: proc(s:^editor.Session,w:core.World_Ref,target:core.Entity,property:cine.Cinematic_Property,value:mm.Vec4) {
    local:=editor.entity_local(w,target)
    switch property {
    case .Position,.Rotation:
        world:=editor.entity_world(w,target)
        if property==.Position {world.position=value.xyz} else {world.rotation=lib.vec4_quat(value)}
        relative,ok:=mm.transform_relative(world,editor.entity_parent_world(w,target))
        if !ok {return}
        local.position,local.rotation=relative.position,relative.rotation
    case .Scale: local.scale=value.xyz
    case .Fov,.Near: return
    }
    if local!=editor.entity_local(w,target) {editor.transform_set(s,target,local)}
}

// Puts the targets of a timeline where its tracks say at a position, as the
// game does: a camera of its shots stays, the viewers sample it.
targets_place :: proc(s:^editor.Session,w:core.World_Ref,timeline:core.Entity,position:f32) {
    tracks,shots:=core.world_table_of(w,cine.Cinematic_Track),core.world_table_of(w,cine.Cinematic_Shot)
    if tracks==nil || shots==nil {return}
    for row in 0..<core.count(tracks) {
        track:=core.at(tracks,row)
        if track.timeline!=timeline || !editor.entity_alive(w,track.target) || cine.cinematic_shot_camera(core.read(shots),timeline,track.target) {continue}
        if value,ok:=cine.cinematic_track_value(&track,position);ok {target_place(s,w,track.target,track.property,value)}
    }
}

// The view of a camera of a timeline at a position, with its tracks.
camera_at :: proc(w:core.World_Ref,timeline,camera:core.Entity,position:f32) -> (sample:cine.Camera_Sample,ok:bool) {
    lens:=editor.entity_get(w,camera,erender.Camera) or_return
    tracks:=core.world_table_of(w,cine.Cinematic_Track)
    if tracks==nil || !editor.entity_has(w,camera,core.Transform) {return}
    return cine.cinematic_camera_sample(core.read(tracks),timeline,camera,editor.entity_world(w,camera),lens,position),true
}

// What the viewers of a timeline show at a position: the shot in force,
// blending in from the one before it.
shot_view :: proc(w:core.World_Ref,timeline:core.Entity,position:f32) -> (shot:cine.Cinematic_Shot,sample:cine.Camera_Sample,ok:bool) {
    shots:=core.world_table_of(w,cine.Cinematic_Shot)
    if shots==nil {return}
    previous:cine.Cinematic_Shot
    shot,previous=cine.cinematic_shots_at(core.read(shots),timeline,position) or_return
    sample=camera_at(w,timeline,shot.camera,position) or_return
    if from,found:=camera_at(w,timeline,previous.camera,position);found && previous.camera!=core.NONE {sample=cine.cinematic_shot_blend(shot,from,sample,position)}
    return shot,sample,true
}
