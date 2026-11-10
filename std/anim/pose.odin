package mirai_anim

import "base:runtime"
import "core:math/linalg"
import "mirai:std/base"
import math "mirai:std/math"

// The result of blending players: one entry per (target, property, slot)
// touched by any of them. An entry accumulates the weighted sum of the values
// it received and their total weight, so players that do not drive the same
// targets mix naturally, and the caller can mix toward a base value by the
// weight (`saturate(weight)`) when the total is below 1. Capacity is fixed;
// an entry that does not fit is refused: the function that adds it returns
// false, and `failed` counts it.
Pose_Entry :: struct {
    target:u64,
    property:Property,
    slot:u8,
    weight:f32,
    sum:math.Vec4,   // weighted sum; use pose_entry_value for the blended value
    added:math.Vec4, // what additive clips put on top: a sum, or for a rotation the product of their turns
    additive:bool,
}
Pose :: struct {
    entries:[]Pose_Entry,
    index:base.Hash_Map(u32),
    using usage:base.Usage,
    owner:runtime.Allocator,
}

pose_init :: proc(pose:^Pose,capacity:int,allocator:=context.allocator) -> bool {
    pose^={}
    if capacity<=0 {return false}
    entries,error:=make([]Pose_Entry,capacity,allocator)
    if error!=nil {return false}
    if !base.hash_map_init(&pose.index,capacity,allocator) {delete(entries,allocator);return false}
    pose.entries=entries
    pose.capacity=capacity;pose.owner=allocator
    return true
}
pose_destroy :: proc(pose:^Pose) {
    if pose.owner.procedure!=nil {delete(pose.entries,pose.owner)}
    base.hash_map_destroy(&pose.index)
    pose^={}
}
pose_clear :: proc(pose:^Pose) {
    base.hash_map_clear(&pose.index)
    pose.count=0
}

@(private)
pose_key :: #force_inline proc "contextless" (target:u64,property:Property,slot:u8) -> u64 {
    return base.hash_combine(target,u64(property)<<8|u64(slot))
}

// Adds one sample with a weight. Rotations are aligned to the hemisphere of
// what the entry already holds, so opposite signs of one rotation agree.
pose_add :: proc(pose:^Pose,target:u64,property:Property,slot:u8,value:math.Vec4,weight:f32) -> bool {
    if weight<=0 {return true}
    entry:=pose_entry(pose,target,property,slot) or_return
    sample:=value
    if property==.Rotation && entry.weight>0 {sample=quat_align(sample,entry.sum)}
    entry.sum+=sample*weight
    entry.weight+=weight
    return true
}
// Puts a change on top of what the entry blends: added to a value, or a turn
// after a rotation, scaled by weight.
pose_add_additive :: proc(pose:^Pose,target:u64,property:Property,slot:u8,change:math.Vec4,weight:f32) -> bool {
    if weight<=0 {return true}
    entry:=pose_entry(pose,target,property,slot) or_return
    if property==.Rotation {
        turn:=math.quat_slerp(1,vec4_quat(change),weight)
        entry.added=quat_vec4((vec4_quat(entry.added) if entry.additive else 1)*turn)
    } else {
        entry.added+=change*weight
    }
    entry.additive=true
    return true
}
@(private)
pose_entry :: proc(pose:^Pose,target:u64,property:Property,slot:u8) -> (entry:^Pose_Entry,ok:bool) {
    key:=pose_key(target,property,slot)
    if found,ok:=base.hash_map_get(&pose.index,key);ok {
        entry=&pose.entries[found]
        if entry.target!=target || entry.property!=property || entry.slot!=slot {pose.failed+=1;return nil,false}
    } else {
        if pose.count>=len(pose.entries) {pose.failed+=1;return nil,false}
        slot_index,_:=base.hash_map_insert(&pose.index,key)
        if slot_index==nil {pose.failed+=1;return nil,false}
        slot_index^=u32(pose.count)
        entry=&pose.entries[pose.count]
        entry^={target=target,property=property,slot=slot}
        pose.count+=1;pose.peak=max(pose.peak,pose.count)
    }
    return entry,true
}
// Adds every track of the player's clip, sampled at its time, with the
// weight of the player times `scale`. False when a value did not fit.
// What a clip blends for a target instead of its tracks, on the channels it keeps: the root of a
// clip moved in place stays at its reference even while the clip fades out.
Pose_Lock :: struct {
    target:u64,
    position,rotation:bool,
    value:math.Transform,
}

pose_blend :: proc(pose:^Pose,lib:^Library,p:Player,scale:f32=1,lock:Pose_Lock={}) -> (ok:bool) {
    if !clip_valid(lib,p.clip) {return true}
    time:=player_time(lib,p)
    weight:=p.weight*scale
    ok=true
    reader:Clip_Reader=---
    clip_reader(&reader,lib,p.clip,time)
    tracks:=clip_tracks(lib,p.clip)
    for {
        i,value,more:=clip_reader_next(&reader)
        if !more {break}
        track:=tracks[i]
        if track.target==lock.target && track.slot==0 {
            if track.property==.Position && lock.position {value.xyz=lock.value.position}
            if track.property==.Rotation && lock.rotation {value=quat_vec4(lock.value.rotation)}
        }
        ok=pose_add(pose,track.target,track.property,track.slot,value,weight) && ok
    }
    return
}

// The blended value of an entry: the weighted average, normalized for a
// rotation, with what additive clips put on top of it.
pose_entry_value :: proc "contextless" (entry:Pose_Entry) -> math.Vec4 {
    if entry.property==.Rotation {
        blended:=linalg.normalize0(vec4_quat(entry.sum)) if entry.weight>0 else 1
        if entry.additive {blended=linalg.normalize0(blended*vec4_quat(entry.added))}
        return quat_vec4(blended)
    }
    blended:=entry.sum/entry.weight if entry.weight>0 else {}
    return blended+entry.added
}

// Adds what an additive clip changes at the player's time from the pose at
// `reference` seconds of `from` (0: of the clip itself, its rest pose), with
// the weight of the player times `scale`, on top of what the other clips
// blend. A target `from` does not move is measured from the clip itself at
// `reference`. False when a value did not fit.
pose_blend_additive :: proc(pose:^Pose,lib:^Library,p:Player,reference:f32=0,scale:f32=1,from:Clip=0) -> (ok:bool) {
    if !clip_valid(lib,p.clip) {return true}
    time:=player_time(lib,p)
    weight:=p.weight*scale
    others:[]Track
    if from!=0 && clip_valid(lib,from) {others=clip_tracks(lib,from)}
    ok=true
    reader:Clip_Reader=---
    clip_reader(&reader,lib,p.clip,time)
    tracks:=clip_tracks(lib,p.clip)
    for {
        i,now,more:=clip_reader_next(&reader)
        if !more {break}
        track:=tracks[i]
        source:=track
        // The clips of a library usually list their targets in one order: the same index first.
        if i<len(others) && others[i].target==track.target && others[i].property==track.property && others[i].slot==track.slot {source=others[i]} else {
            for other in others {if other.target==track.target && other.property==track.property && other.slot==track.slot {source=other;break}}
        }
        rest:=clip_evaluate(lib,source,reference)
        change:=quat_vec4(conj(vec4_quat(rest))*vec4_quat(now)) if track.property==.Rotation else now-rest
        ok=pose_add_additive(pose,track.target,track.property,track.slot,change,weight) && ok
    }
    return
}
// The local transform of a bone from what a pose blends for its target: each channel the pose
// holds goes from rest toward its blended value by the weight that blended it, at most 1; the
// others keep rest. weights: of the position, rotation and scale.
pose_bone :: proc "contextless" (pose:^Pose,target:u64,rest:math.Transform) -> (value:math.Transform,weights:math.Vec3,properties:bit_set[Property;u8]) {
    value=rest
    if v,w,ok:=pose_position(pose,target);ok {share:=math.saturate(w);value.position=v if share==1 else math.lerp(rest.position,v,share);properties+={.Position};weights.x=share}
    if v,w,ok:=pose_rotation(pose,target);ok {share:=math.saturate(w);value.rotation=v if share==1 else math.quat_slerp(rest.rotation,v,share);properties+={.Rotation};weights.y=share}
    if v,w,ok:=pose_scale(pose,target);ok {share:=math.saturate(w);value.scale=v if share==1 else math.lerp(rest.scale,v,share);properties+={.Scale};weights.z=share}
    return
}
pose_find :: proc "contextless" (pose:^Pose,target:u64,property:Property,slot:u8=0) -> (value:math.Vec4,weight:f32,ok:bool) {
    index,found:=base.hash_map_get(&pose.index,pose_key(target,property,slot))
    if !found {return}
    entry:=pose.entries[index]
    if entry.target!=target || entry.property!=property || entry.slot!=slot {return}
    return pose_entry_value(entry),entry.weight,true
}
pose_position :: proc "contextless" (pose:^Pose,target:u64) -> (value:math.Vec3,weight:f32,ok:bool) {
    v:math.Vec4
    v,weight,ok=pose_find(pose,target,.Position)
    return v.xyz,weight,ok
}
pose_scale :: proc "contextless" (pose:^Pose,target:u64) -> (value:math.Vec3,weight:f32,ok:bool) {
    v:math.Vec4
    v,weight,ok=pose_find(pose,target,.Scale)
    return v.xyz,weight,ok
}
pose_rotation :: proc "contextless" (pose:^Pose,target:u64) -> (value:math.Quat,weight:f32,ok:bool) {
    v:math.Vec4
    v,weight,ok=pose_find(pose,target,.Rotation)
    return vec4_quat(v),weight,ok
}
pose_float :: proc "contextless" (pose:^Pose,target:u64,slot:u8=0) -> (value:f32,weight:f32,ok:bool) {
    v:math.Vec4
    v,weight,ok=pose_find(pose,target,.Float,slot)
    return v.x,weight,ok
}

// What the clips of a rig blend for one of its bones, without the search by name of a Pose: the
// caller says once, by track of the library, which bone each track moves. bones_blend keeps the
// weighted sum of each channel and its weight, as a Pose_Entry does; bones_blend_additive keeps
// what additive clips put on top, a sum or for a rotation the product of their turns. A channel
// nothing gave has weight 0.
Bone_Blend :: struct {
    position,scale:math.Vec3,
    rotation:math.Vec4,
    weights:math.Vec3, // of the position, rotation and scale
}

// The bone a track of the library moves, by track_bones: -1 for a track that moves none of `count`.
@(private)
track_bone :: #force_inline proc "contextless" (count:int,track_bones:[]i32,track:int) -> int {
    if track<0 || track>=len(track_bones) {return -1}
    bone:=int(track_bones[track])
    return bone if bone>=0 && bone<count else -1
}

// Adds every track of the player's clip that moves a bone, sampled at its time, with the weight
// of the player times `scale`, as pose_blend does for the targets of a Pose.
bones_blend :: proc "contextless" (bones:[]Bone_Blend,track_bones:[]i32,lib:^Library,p:Player,scale:f32=1,lock:Pose_Lock={}) {
    if !clip_valid(lib,p.clip) {return}
    weight:=p.weight*scale
    if weight<=0 {return}
    first:=int(lib.clips[p.clip-1].first_track)
    reader:Clip_Reader=---
    clip_reader(&reader,lib,p.clip,player_time(lib,p))
    tracks:=clip_tracks(lib,p.clip)
    for {
        i,value,more:=clip_reader_next(&reader)
        if !more {break}
        at:=track_bone(len(bones),track_bones,first+i)
        if at<0 {continue}
        bone:=&bones[at]
        track:=tracks[i]
        locked:=track.target==lock.target && track.slot==0
        #partial switch track.property {
        case .Position:
            if locked && lock.position {value.xyz=lock.value.position}
            bone.position+=value.xyz*weight;bone.weights.x+=weight
        case .Rotation:
            if locked && lock.rotation {value=quat_vec4(lock.value.rotation)}
            if bone.weights.y>0 {value=quat_align(value,bone.rotation)}
            bone.rotation+=value*weight;bone.weights.y+=weight
        case .Scale:
            bone.scale+=value.xyz*weight;bone.weights.z+=weight
        }
    }
}
// The clips of the fader, each with its weight.
bones_fader_blend :: proc "contextless" (bones:[]Bone_Blend,track_bones:[]i32,lib:^Library,f:Fader) {
    f:=f
    bones_blend(bones,track_bones,lib,f.current,fader_current_weight(f))
    for o in f.outgoing[:f.outgoing_count] {bones_blend(bones,track_bones,lib,o.player,fade_out_weight(o))}
}

// Adds what an additive clip changes for each bone at the player's time, as pose_blend_additive
// does for the targets of a Pose. references is the caller's room to pair each bone with its track
// of `from`: three places a bone. False, with nothing added, when `from` is given and it is short.
bones_blend_additive :: proc "contextless" (bones:[]Bone_Blend,track_bones:[]i32,lib:^Library,p:Player,reference:f32=0,scale:f32=1,from:Clip=0,references:[]i32=nil) -> bool {
    if !clip_valid(lib,p.clip) {return true}
    weight:=p.weight*scale
    if weight<=0 {return true}
    others:[]Track
    if from!=0 && clip_valid(lib,from) {
        if len(references)<len(bones)*3 {return false}
        others=clip_tracks(lib,from)
        paired:=references[:len(bones)*3]
        for &place in paired {place=0}
        start:=int(lib.clips[from-1].first_track)
        for other,j in others {
            if u8(other.property)>u8(Property.Scale) {continue}
            at:=track_bone(len(bones),track_bones,start+j)
            if at<0 {continue}
            place:=&paired[at*3+int(other.property)]
            if place^==0 {place^=i32(j+1)}
        }
    }
    first:=int(lib.clips[p.clip-1].first_track)
    reader:Clip_Reader=---
    clip_reader(&reader,lib,p.clip,player_time(lib,p))
    tracks:=clip_tracks(lib,p.clip)
    for {
        i,now,more:=clip_reader_next(&reader)
        if !more {break}
        at:=track_bone(len(bones),track_bones,first+i)
        if at<0 {continue}
        bone:=&bones[at]
        track:=tracks[i]
        if u8(track.property)>u8(Property.Scale) {continue}
        source:=track
        if others!=nil {
            if paired:=int(references[at*3+int(track.property)]);paired>0 {source=others[paired-1]}
        }
        rest:=clip_evaluate(lib,source,reference)
        #partial switch track.property {
        case .Position:
            bone.position+=(now.xyz-rest.xyz)*weight;bone.weights.x+=weight
        case .Rotation:
            turn:=math.quat_slerp(1,conj(vec4_quat(rest))*vec4_quat(now),weight)
            bone.rotation=quat_vec4((vec4_quat(bone.rotation) if bone.weights.y>0 else 1)*turn);bone.weights.y+=weight
        case .Scale:
            bone.scale+=(now.xyz-rest.xyz)*weight;bone.weights.z+=weight
        }
    }
    return true
}

// What bones_blend gave a channel of a bone: its weighted average, normalized for a rotation, and
// the weight that blended it. False for a channel no clip gave.
bone_position :: #force_inline proc "contextless" (bone:Bone_Blend) -> (value:math.Vec3,weight:f32,ok:bool) {
    if !(bone.weights.x>0) {return}
    return bone.position/bone.weights.x,bone.weights.x,true
}
bone_rotation :: #force_inline proc "contextless" (bone:Bone_Blend) -> (value:math.Quat,weight:f32,ok:bool) {
    if !(bone.weights.y>0) {return 1,0,false}
    return linalg.normalize0(vec4_quat(bone.rotation)),bone.weights.y,true
}
bone_scale :: #force_inline proc "contextless" (bone:Bone_Blend) -> (value:math.Vec3,weight:f32,ok:bool) {
    if !(bone.weights.z>0) {return}
    return bone.scale/bone.weights.z,bone.weights.z,true
}
// What bones_blend_additive gave a channel of a bone: the change to put on top.
bone_added_position :: #force_inline proc "contextless" (bone:Bone_Blend) -> (change:math.Vec3,ok:bool) {return bone.position,bone.weights.x>0}
bone_added_rotation :: #force_inline proc "contextless" (bone:Bone_Blend) -> (change:math.Quat,ok:bool) {
    if !(bone.weights.y>0) {return 1,false}
    return linalg.normalize0(vec4_quat(bone.rotation)),true
}
bone_added_scale :: #force_inline proc "contextless" (bone:Bone_Blend) -> (change:math.Vec3,ok:bool) {return bone.scale,bone.weights.z>0}

// The local transform of a bone from what bones_blend gave it, as pose_bone gives it from a Pose.
bone_transform :: proc "contextless" (bone:Bone_Blend,rest:math.Transform) -> (value:math.Transform,weights:math.Vec3,properties:bit_set[Property;u8]) {
    value=rest
    if v,w,ok:=bone_position(bone);ok {share:=math.saturate(w);value.position=v if share==1 else math.lerp(rest.position,v,share);properties+={.Position};weights.x=share}
    if v,w,ok:=bone_rotation(bone);ok {share:=math.saturate(w);value.rotation=v if share==1 else math.quat_slerp(rest.rotation,v,share);properties+={.Rotation};weights.y=share}
    if v,w,ok:=bone_scale(bone);ok {share:=math.saturate(w);value.scale=v if share==1 else math.lerp(rest.scale,v,share);properties+={.Scale};weights.z=share}
    return
}

// Clips that fade out at once besides the one fading in.
FADER_OUTGOING :: 3

// A clip that fades out from the weight it had when it was replaced.
Fade_Out :: struct {
    player:Player,
    weight,duration,elapsed:f32,
    ease:math.Ease,
}

// A clip that fades in while the ones it replaced fade out, each over the fade
// it was given. A fade begun during others keeps them going: the pose does not
// jump when a clip starts, however often. Plain data.
Fader :: struct {
    current:Player,
    duration,elapsed:f32, // of the fade in of current
    ease:math.Ease,
    outgoing:[FADER_OUTGOING]Fade_Out, // newest first
    outgoing_count:int,
}

// Starts a clip. With a fade and a clip already playing, the one playing
// fades out over that time from the weight it has now, and the ones that were
// already fading go on; when they are more than FADER_OUTGOING the faintest
// leaves. Without a fade it cuts.
fader_play :: proc "contextless" (f:^Fader,clip:Clip,speed:f32=1,fade:f32=0,ease:math.Ease=.Linear) {
    if fade>0 && f.current.clip!=0 {
        leaving:=Fade_Out{player=f.current,weight=fader_current_weight(f^),duration=fade,ease=ease}
        if f.outgoing_count==FADER_OUTGOING {
            faintest:=0
            for i in 1..<f.outgoing_count {
                if fade_out_weight(f.outgoing[i])<fade_out_weight(f.outgoing[faintest]) {faintest=i}
            }
            copy(f.outgoing[faintest:],f.outgoing[faintest+1:f.outgoing_count])
            f.outgoing_count-=1
        }
        copy(f.outgoing[1:],f.outgoing[:f.outgoing_count])
        f.outgoing[0]=leaving
        f.outgoing_count+=1
    } else {
        f.outgoing_count=0
    }
    f.current=player_make(clip,speed)
    f.duration=max(fade,0);f.elapsed=0;f.ease=ease
}
fader_fading :: #force_inline proc "contextless" (f:Fader) -> bool {return f.outgoing_count>0}
// The weight of `current`: from 0 to 1 over its fade, 1 without one.
fader_current_weight :: proc "contextless" (f:Fader) -> f32 {
    if f.outgoing_count==0 || f.duration<=0 {return 1}
    return math.ease_apply(f.ease,math.saturate(f.elapsed/f.duration))
}
fade_out_weight :: proc "contextless" (o:Fade_Out) -> f32 {
    if o.duration<=0 {return 0}
    return o.weight*(1-math.ease_apply(o.ease,math.saturate(o.elapsed/o.duration)))
}
fader_advance :: proc "contextless" (lib:^Library,f:^Fader,dt:f32,events:[]Event,current_dt:f32=-1) -> (written,dropped:int) {
    if f==nil || !anim_finite(dt) || !anim_finite(current_dt) || current_dt< -1 {return}
    f.elapsed+=dt
    w,d:=player_advance(lib,&f.current,current_dt if current_dt>=0 else dt,events)
    written,dropped=w,d
    kept:=0
    for &o in f.outgoing[:f.outgoing_count] {
        w,d=player_advance(lib,&o.player,dt,events[written:])
        written+=w;dropped+=d
        o.elapsed+=dt
        if o.elapsed<o.duration {
            f.outgoing[kept]=o
            kept+=1
        }
    }
    f.outgoing_count=kept
    return
}
// The clips of the fader into the pose, each with its weight; the pose
// divides by their sum. False when a value did not fit.
fader_blend :: proc(pose:^Pose,lib:^Library,f:Fader) -> (ok:bool) {
    f:=f
    ok=pose_blend(pose,lib,f.current,fader_current_weight(f))
    for o in f.outgoing[:f.outgoing_count] {ok=pose_blend(pose,lib,o.player,fade_out_weight(o)) && ok}
    return
}
