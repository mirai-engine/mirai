package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

FRAMES_MAX_RATE :: 1000

// A clip sampled at a fixed rate: the local pose of every bone at every
// frame, frame after frame from time 0 to the duration, and as many curve
// values per frame. In a loop the last frame is the first of the next pass.
Frames :: struct {
    rate:f32,
    bones,curves:int,
    loop:bool,
    local:[]math.Transform,
    values:[]math.Vec4,
}

// What edits and metrics know of a skeleton: its hierarchy, rest pose and
// body. root is the bone that carries the motion over the ground, -1 to find
// it (frames_root). mirror is what mirror_prepare gives for the rig; only
// mirroring needs it.
Body_Rig :: struct {
    parents:[]i32,
    rest:[]math.Transform,
    body:Body_Map,
    root:i32,
    mirror:Body_Mirror,
}
Body_Mirror :: struct {pairs:[]i32,corrections:[]math.Quat,plane:Mirror_Plane}

frames_count :: proc "contextless" (f:Frames) -> int {
    if f.bones<=0 || len(f.local)%f.bones!=0 {return 0}
    return len(f.local)/f.bones
}
frames_duration :: proc "contextless" (f:Frames) -> f32 {
    count:=frames_count(f)
    if count<2 || !(f.rate>0) {return 0}
    return f32(count-1)/f.rate
}
frames_pose :: #force_inline proc "contextless" (f:Frames,frame:int) -> []math.Transform {return f.local[frame*f.bones:][:f.bones]}
frames_values :: #force_inline proc "contextless" (f:Frames,frame:int) -> []math.Vec4 {return f.values[frame*f.curves:][:f.curves]}

// At least two frames at a finite rate up to FRAMES_MAX_RATE, valid
// transforms and finite curve values.
frames_valid :: proc "contextless" (f:Frames) -> bool {
    count:=frames_count(f)
    if count<2 || !anim_finite(f.rate) || f.rate<=0 || f.rate>FRAMES_MAX_RATE || f.curves<0 || len(f.values)!=count*f.curves {return false}
    if !anim_pose_valid(f.local) {return false}
    for value in f.values {for c in value {if !anim_finite(c) {return false}}}
    return true
}

body_rig_valid :: proc "contextless" (rig:Body_Rig) -> bool {
    n:=len(rig.parents)
    if n==0 || len(rig.rest)!=n || rig.root< -1 || int(rig.root)>=n || len(rig.mirror.pairs)!=0 && (len(rig.mirror.pairs)!=n || len(rig.mirror.corrections)!=n) {return false}
    for parent,i in rig.parents {if parent< -1 || int(parent)>=i {return false}}
    return anim_pose_valid(rig.rest) && body_map_valid(rig.body,n)
}

// How many frames sample a duration at about `rate` per second, and the rate
// that spaces them evenly from 0 to the duration. 0 frames for a duration or
// rate that is not positive and finite, or more than max_count frames.
frames_layout :: proc "contextless" (duration,rate:f32,max_count:int) -> (count:int,exact:f32) {
    if !anim_finite(duration) || !anim_finite(rate) || duration<=0 || rate<=0 || rate>FRAMES_MAX_RATE {return}
    steps:=cmath.ceil(f64(duration)*f64(rate)-1e-3)
    if steps<1 || steps+1>f64(max_count) {return}
    return int(steps)+1,f32(steps/f64(duration))
}

// Samples a clip into out, whose rate, bones, curves and buffers the caller
// sets from frames_layout. bindings come from skeleton_bind; curves are
// tracks of the library sampled into the values.
frames_sample_clip :: proc "contextless" (lib:^Library,clip:Clip,bindings:[]Bone_Tracks,rest:[]math.Transform,curves:[]Track,out:Frames) -> bool {
    count:=frames_count(out)
    if count<2 || !anim_finite(out.rate) || out.rate<=0 || len(bindings)!=out.bones || len(rest)!=out.bones || len(curves)!=out.curves || len(out.values)!=count*out.curves || !clip_valid(lib,clip) {return false}
    duration:=clip_duration(lib,clip)
    for frame in 0..<count {
        time:=min(f32(frame)/out.rate,duration)
        if !skeleton_sample(lib,bindings,rest,time,frames_pose(out,frame)) {return false}
        for track,i in curves {frames_values(out,frame)[i]=clip_evaluate(lib,track,time)}
    }
    return true
}

// The pose and curve values at a time, between the frames around it; the
// first and last frames hold outside.
frames_sample :: proc "contextless" (f:Frames,time:f32,pose:[]math.Transform,values:[]math.Vec4) {
    count:=frames_count(f)
    if count==0 || len(pose)!=f.bones || len(values)!=f.curves {return}
    at:=clamp(time*f.rate,0,f32(count-1)) if anim_finite(time) else 0
    i:=min(int(at),count-2) if count>1 else 0
    fraction:=at-f32(i) if count>1 else 0
    a,b:=frames_pose(f,i),frames_pose(f,min(i+1,count-1))
    for &value,bone in pose {value=math.transform_interpolate(a[bone],b[bone],fraction);value.rotation=linalg.normalize0(value.rotation)}
    if f.curves>0 {
        va,vb:=frames_values(f,i),frames_values(f,min(i+1,count-1))
        for &value,curve in values {value=va[curve]+(vb[curve]-va[curve])*fraction}
    }
}

// The world pose of every frame, from the roots composed with the identity.
frames_world :: proc "contextless" (rig:Body_Rig,f:Frames,world:[]math.Transform) -> bool {
    count:=frames_count(f)
    if count==0 || f.bones!=len(rig.parents) || len(world)<count*f.bones {return false}
    for frame in 0..<count {
        if !pose_world(rig.parents,frames_pose(f,frame),world[frame*f.bones:][:f.bones]) {return false}
    }
    return true
}

// The bone that carries the motion of the clip over the ground: the root of
// the rig when it names one, else the highest bone above the pelvis whose
// position changes, or the pelvis when none does. Without a pelvis, the first
// root that moves, or the first root.
frames_root :: proc "contextless" (rig:Body_Rig,f:Frames) -> i32 {
    if rig.root>=0 {return rig.root}
    count:=frames_count(f)
    moves :: proc "contextless" (f:Frames,count:int,bone:i32) -> bool {
        first:=f.local[bone].position
        for frame in 1..<count {if linalg.length(frames_pose(f,frame)[bone].position-first)>1e-3 {return true}}
        return false
    }
    pelvis:=rig.body.bones[.Pelvis]
    if pelvis>=0 && int(pelvis)<f.bones {
        chain:[64]i32
        depth:=0
        at:=pelvis
        for at>=0 && depth<len(chain) {chain[depth]=at;depth+=1;at=rig.parents[at]}
        for i:=depth-1;i>=0;i-=1 {if moves(f,count,chain[i]) {return chain[i]}}
        return pelvis
    }
    for parent,bone in rig.parents {if parent<0 && moves(f,count,i32(bone)) {return i32(bone)}}
    return 0
}

@(private)
frames_up :: proc "contextless" (rig:Body_Rig) -> math.Vec3 {
    up,ok:=anim_unit(rig.body.up)
    return up if ok else {0,1,0}
}
@(private)
frames_horizontal :: #force_inline proc "contextless" (v,up:math.Vec3) -> math.Vec3 {return v-up*linalg.dot(v,up)}

// The velocity of a point of the world poses at a frame, by central
// differences inside and one-sided ones at the ends.
@(private)
frames_velocity :: proc "contextless" (world:[]math.Transform,bones,count,bone,frame:int,rate:f32) -> math.Vec3 {
    if count<2 {return {}}
    a,b:=max(frame-1,0),min(frame+1,count-1)
    return (world[b*bones+bone].position-world[a*bones+bone].position)*(rate/f32(b-a))
}
