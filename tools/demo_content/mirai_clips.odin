package main

import "core:math"
import "core:math/linalg"
import "mirai:asset"
import importer "mirai:cook/import"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// The skeleton of the imported Mirai, local and world at rest.
@(private)
Mirai_Rig :: struct {
    parents:[]i32,
    names:[]u64,
    rest,rest_world:[]mm.Transform,
}

@(private)
mirai_rig :: proc(model:^importer.Imported_Model) -> (rig:Mirai_Rig,ok:bool) {
    bones:=model.skeletons[0].bones
    rig={make([]i32,len(bones),context.temp_allocator),make([]u64,len(bones),context.temp_allocator),make([]mm.Transform,len(bones),context.temp_allocator),make([]mm.Transform,len(bones),context.temp_allocator)}
    for &bone,i in bones {rig.parents[i],rig.names[i],rig.rest[i]=bone.parent,bone.target,{bone.translation,bone.rotation,bone.scale}}
    return rig,lib.pose_world(rig.parents,rig.rest,rig.rest_world)
}

@(private)
mirai_bone :: proc(model:^importer.Imported_Model,name:string) -> int {
    for &bone,i in model.skeletons[0].bones {if base.text_get(bone.name[:])==name {return i}}
    return -1
}

// The world poses of a clip, one per frame at `rate`, and their times.
@(private)
mirai_clip_frames :: proc(rig:Mirai_Rig,clip:asset.Animation_Clip_Desc,rate:f32) -> (frames:[][]mm.Transform,times:[]f32,ok:bool) {
    tracks:=make([]lib.Track_Desc,len(clip.tracks),context.temp_allocator)
    key_count:=0
    for track,i in clip.tracks {tracks[i]={target=base.name_hash(track.target),property=track.property,slot=track.slot,keys=track.keys};key_count+=len(track.keys)}
    library:lib.Library
    if !lib.library_init(&library,{max_keys=key_count,max_tracks=len(tracks),max_clips=1}) {return}
    defer lib.library_destroy(&library)
    handle,error:=lib.clip_add(&library,{name=base.name_hash(clip.name),loop=.Loop,tracks=tracks})
    bindings:=make([]lib.Bone_Tracks,len(rig.rest),context.temp_allocator)
    if error!=.None || !lib.skeleton_bind(&library,handle,{rig.parents,rig.names,rig.rest},bindings) {return}
    duration:=lib.clip_duration(&library,handle)
    count:=int(math.ceil(duration*rate))+1
    frames=make([][]mm.Transform,count,context.temp_allocator);times=make([]f32,count,context.temp_allocator)
    local:=make([]mm.Transform,len(rig.rest),context.temp_allocator)
    for frame in 0..<count {
        times[frame]=min(f32(frame)/rate,duration)
        frames[frame]=make([]mm.Transform,len(rig.rest),context.temp_allocator)
        if !lib.skeleton_sample(&library,bindings,rig.rest,times[frame],local) || !lib.pose_world(rig.parents,local,frames[frame]) {return}
    }
    return frames,times,true
}

// Where the feet of a walking clip land: a step is the frame where the other foot stops being
// the lower one. advance: what the body walks in one cycle, the backward slide of the lower foot.
@(private)
mirai_steps :: proc(frames:[][]mm.Transform,times:[]f32,left,right:int) -> (markers:[]asset.Animation_Marker_Desc,advance:f32) {
    list:=make([dynamic]asset.Animation_Marker_Desc,context.temp_allocator)
    lower:=-1
    for pose,frame in frames {
        now:=left if pose[left].position.y<pose[right].position.y else right
        if frame>0 {
            previous:=frames[frame-1][now].position.z
            advance+=max(0,previous-pose[now].position.z)
            if now!=lower {append(&list,asset.Animation_Marker_Desc{times[frame],"left_step" if now==left else "right_step"})}
        }
        lower=now
    }
    return list[:],advance
}

@(private)
mirai_clip_find :: proc(clips:[]asset.Animation_Clip_Desc,name:string) -> (asset.Animation_Clip_Desc,bool) {
    for clip in clips {if clip.name==name {return clip,true}}
    return {},false
}

// A clip slower or faster by `time` whose rotations swing `swing` times as far from their mean.
@(private)
mirai_clip_scaled :: proc(clip:asset.Animation_Clip_Desc,name:string,time,swing:f32) -> asset.Animation_Clip_Desc {
    result:=clip;result.name=name
    tracks:=make([]asset.Animation_Track_Desc,len(clip.tracks),context.temp_allocator)
    for track,i in clip.tracks {
        tracks[i]=track
        keys:=make([]lib.Keyframe,len(track.keys),context.temp_allocator);copy(keys,track.keys)
        mean:mm.Vec4
        if track.property==.Rotation {
            for key in keys {mean+=key.value if linalg.dot(key.value,keys[0].value)>=0 else -key.value}
            mean=linalg.normalize0(mean)
        }
        for &key in keys {
            key.time*=time
            if track.property==.Rotation {key.value=lib.quat_vec4(mm.quat_slerp(lib.vec4_quat(mean),lib.vec4_quat(key.value),swing))}
        }
        tracks[i].keys=keys
    }
    result.tracks=tracks
    markers:=make([]asset.Animation_Marker_Desc,len(clip.markers),context.temp_allocator)
    for marker,i in clip.markers {markers[i]={marker.time*time,marker.name}}
    result.markers=markers
    return result
}

// The idle with the left arm raised to the side and the forearm waving twice a second.
@(private)
mirai_wave :: proc(model:^importer.Imported_Model,rig:Mirai_Rig,idle:asset.Animation_Clip_Desc) -> (clip:asset.Animation_Clip_Desc,ok:bool) {
    arm,fore,hand:=mirai_bone(model,"LeftArm"),mirai_bone(model,"LeftForeArm"),mirai_bone(model,"LeftHand")
    if arm<0 || fore<0 || hand<0 {return}
    world:=rig.rest_world
    upper:=linalg.normalize(world[fore].position-world[arm].position)
    side:=f32(1) if upper.x>=0 else -1
    raise:=mm.quat_between(upper,linalg.normalize(mm.Vec3{side*.55,.82,.12}))
    parent:=world[rig.parents[arm]].rotation
    arm_rotation:=mm.quat_inverse(parent)*raise*parent*rig.rest[arm].rotation
    arm_world:=raise*world[arm].rotation
    lower:=mm.quat_rotate(raise,linalg.normalize(world[hand].position-world[fore].position))
    // A whole number of one-second waves over the idle, which is stretched to them.
    idle_length:f32
    for track in idle.tracks {for key in track.keys {idle_length=max(idle_length,key.time)}}
    waves:=max(2,math.round(idle_length))
    count:=int(waves*8)+1
    arm_keys:=make([]lib.Keyframe,count,context.temp_allocator);fore_keys:=make([]lib.Keyframe,count,context.temp_allocator)
    for i in 0..<count {
        t:=f32(i)*.125
        angle:=.1+.38*math.sin(t*2*math.PI)
        swing:=mm.quat_between(lower,linalg.normalize(mm.Vec3{side*math.sin(angle),math.cos(angle),.15}))
        arm_keys[i]={time=t,value=lib.quat_vec4(arm_rotation),interpolation=.Linear}
        fore_keys[i]={time=t,value=lib.quat_vec4(mm.quat_inverse(arm_world)*swing*arm_world*rig.rest[fore].rotation),interpolation=.Linear}
    }
    arm_path,fore_path:=rig_path(model,"LeftArm"),rig_path(model,"LeftForeArm")
    tracks:=make([dynamic]asset.Animation_Track_Desc,context.temp_allocator)
    for track in idle.tracks {
        if track.property==.Rotation && (track.target==arm_path || track.target==fore_path) {continue}
        keys:=make([]lib.Keyframe,len(track.keys),context.temp_allocator);copy(keys,track.keys)
        if idle_length>0 {for &key in keys {key.time*=waves/idle_length}}
        append(&tracks,asset.Animation_Track_Desc{target=track.target,property=track.property,slot=track.slot,keys=keys})
    }
    append(&tracks,asset.Animation_Track_Desc{target=arm_path,property=.Rotation,keys=arm_keys},asset.Animation_Track_Desc{target=fore_path,property=.Rotation,keys=fore_keys})
    return {name="wave",tracks=tracks[:]},true
}

// The walk with its hips advancing what its feet push them, for root motion.
@(private)
mirai_stride :: proc(model:^importer.Imported_Model,rig:Mirai_Rig,walk:asset.Animation_Clip_Desc,advance:f32) -> (clip:asset.Animation_Clip_Desc,ok:bool) {
    hips:=mirai_bone(model,"Hips");if hips<0 {return}
    path:=rig_path(model,"Hips")
    parent:=rig.rest_world[rig.parents[hips]] if rig.parents[hips]>=0 else mm.TRANSFORM_IDENTITY
    clip=walk;clip.name="stride"
    tracks:=make([]asset.Animation_Track_Desc,len(walk.tracks),context.temp_allocator);copy(tracks,walk.tracks)
    duration:f32
    for track in walk.tracks {for key in track.keys {duration=max(duration,key.time)}}
    if duration<=0 {return}
    found:=false
    for &track in tracks {
        if track.target!=path || track.property!=.Position {continue}
        keys:=make([]lib.Keyframe,len(track.keys),context.temp_allocator);copy(keys,track.keys)
        for &key in keys {
            placed:=mm.transform_point(parent,key.value.xyz)+mm.Vec3{0,0,advance*key.time/duration}
            point:=mm.transform_inverse_point(parent,placed)
            key.value={point.x,point.y,point.z,0}
        }
        track.keys=keys;found=true
    }
    clip.tracks=tracks
    clip.root.translation=true;base.text_set(clip.root.bone[:],path)
    return clip,found
}

// The clips of the gallery's Mirai, made from its idle and walk: the walk with its steps and a
// pulse curve, a faster jog, a wave and the stride that root motion moves.
@(private)
mirai_gallery_animation :: proc(o:^Out,model:^importer.Imported_Model,locomotion:[]asset.Animation_Clip_Desc) -> (id:base.Asset_Id,stride,stride_time:f32) {
    id=asset.content_id(PROJECT,"animation","mirai_gallery")
    rig,valid:=mirai_rig(model)
    idle,has_idle:=mirai_clip_find(locomotion,"idle")
    walk,has_walk:=mirai_clip_find(locomotion,"walk")
    left,right:=mirai_bone(model,"LeftFoot"),mirai_bone(model,"RightFoot")
    if !valid || !has_idle || !has_walk || left<0 || right<0 {o.content.failed=true;return}
    frames,times,sampled:=mirai_clip_frames(rig,walk,60)
    if !sampled {o.content.failed=true;return}
    steps,advance:=mirai_steps(frames,times,left,right)
    duration:=times[len(times)-1]
    walk.markers=steps
    pulse:=[]lib.Keyframe{{time=0,value={0,0,0,0}},{time=duration*.5,value={1,0,0,0},ease=.Sine_In_Out},{time=duration,value={0,0,0,0},ease=.Sine_In_Out}}
    tracks:=make([]asset.Animation_Track_Desc,len(walk.tracks)+1,context.temp_allocator);copy(tracks,walk.tracks)
    tracks[len(walk.tracks)]={target="pulse",property=.Float,keys=pulse}
    walk.tracks=tracks
    wave,waved:=mirai_wave(model,rig,idle)
    stride_clip,strode:=mirai_stride(model,rig,walk,advance)
    if !waved || !strode {o.content.failed=true;return}
    clips:=[]asset.Animation_Clip_Desc{idle,walk,mirai_clip_scaled(walk,"jog",.72,1.2),wave,stride_clip}
    for &clip in clips {clip.skeleton=idle.skeleton}
    file:="assets/animations/mirai_gallery.anim"
    asset.content_check(&o.content,file,asset.animation_save(path(o,file),&o.content.types,{id=id,clips=clips}))
    // What the stride covers and how long it lasts: the window of its warp (mirai_reach.motion).
    return id,advance,duration
}
