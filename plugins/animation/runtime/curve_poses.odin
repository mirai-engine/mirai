package anim

import "core:slice"
import "mirai:core"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

POSE_CURVE_ROWS :: 4096 // rows of curve_poses of a .character

// A pose that a Float curve brings to a bone, as the poses of a face (a blink,
// an open jaw, a phoneme): with the value of curve, from 0 to 1, the bone
// moves by delta over its pose. delta is in the space of the parent of the
// bone, as an additive pose keeps it, and its scale is a factor. A full pose
// is the transform of the bone itself instead: the full poses of a bone blend
// by their weights, normalized when they pass 1, before the additive ones. A
// pose of several bones is a row per bone with one curve.
Curve_Pose :: struct {
    curve:[64]u8 `mirai:"text"`,
    bone:Bone_Ref,
    delta:mm.Transform,
    weight:f32 `mirai:"min=0,max=1"`,
    full:bool,
    enabled:bool,
}
CURVE_POSE_DEFAULT :: Curve_Pose{delta=mm.TRANSFORM_IDENTITY,weight=1,enabled=true}

Curve_Binding :: struct {
    rig:core.Entity,
    bound:u64,
    generation:u32,
    ready:bool,
    bone:i32,     // of a pose
    curve:u64,    // name hash of its curve
    at:[2]i32,    // where its curve was found last among those of the rig and of its leader
}

@(private)
curve_poses_check :: proc(profile:Pose_Profile) -> bool {
    if len(profile.curve_poses)>POSE_CURVE_ROWS {return false}
    for &value in profile.curve_poses {
        if !blend_text_valid(value.curve[:],false) || !profile_bone(value.bone) || !spatial_transform_valid(value.delta) || !profile_weight(value.weight) {return false}
    }
    return true
}

// The rig whose curves a rig reads over its own: the one it follows, while that animates in this
// tick.
rig_leader :: proc(playback:core.Ref(Playback),state:^Playing) -> ^Playing {
    if state==nil || state.leader==core.NONE {return nil}
    leader:=constraint_playing(playback,state.leader)
    return leader if leader!=nil && leader.seen==playback.frame && leader.curves_ready else nil
}

// The curve of key that a rig reads: that of its leader while the leader animates it, so a modular
// head that follows a body takes the curves of its face, else its own. at keeps where each was.
rig_curve :: proc(state,leader:^Playing,key:Curve_Output,at:^[2]i32) -> ^Curve_Output {
    if leader!=nil {if curve:=curve_find(leader.curves[:],key,&at[1]);curve!=nil && curve.weight>0 {return curve}}
    return curve_find(state.curves[:],key,&at[0])
}

// The order of the curves of a rig: by name hash, property and slot.
curve_order :: proc(a,b:Curve_Output) -> bool {
    if a.target!=b.target {return a.target<b.target}
    if a.property!=b.property {return a.property<b.property}
    return a.slot<b.slot
}

@(private)
curve_compare :: proc(a,b:Curve_Output) -> slice.Ordering {return .Less if curve_order(a,b) else .Greater if curve_order(b,a) else .Equal}

// The curve of the target, property and slot of key among curves; at keeps where it was, so a rig
// whose curves stay in place finds it at once, and curves in curve_order are searched by halves.
@(private)
curve_find :: proc(curves:[]Curve_Output,key:Curve_Output,at:^i32) -> ^Curve_Output {
    if row:=int(at^);row>=0 && row<len(curves) && curve_same(curves[row],key) {return &curves[row]}
    if row,found:=slice.binary_search_by(curves,key,curve_compare);found {at^=i32(row);return &curves[row]}
    for &curve,row in curves {
        if curve_same(curve,key) {at^=i32(row);return &curve}
    }
    at^=-1
    return nil
}

@(private)
curve_same :: proc "contextless" (a,b:Curve_Output) -> bool {return a.target==b.target && a.property==b.property && a.slot==b.slot}

// The curve poses of the profile of a rig move its bones by the curves it reads (rig_curve): the
// full ones first, then the additive ones, each summed by bone so that the order of the rows does
// not matter.
@(private)
curve_poses_apply :: proc(state:^Playing,playback:^Playback,runtime:^Modifier_Runtime,rig:^Modifier_Rig,pose:Pose_Profile,followed:bool,problems:^core.Problems) -> bool {
    if len(pose.curve_poses)>0 && len(runtime.curve_full)<len(playing_pose(state,.Local)) &&
        resize(&runtime.curve_full,len(playing_pose(state,.Local)))!=nil {
        memory_problem(problems,state.entity,"the curve poses of its .character")
        return false
    }
    leader:=rig_leader(core.ref(playback),state) if followed else nil
    valid:=true
    for &config,row in pose.curve_poses {
        binding:=&rig.curve_pose_states[row]
        if !rig_binding_current(binding,state) {
            binding.bone=i32(bone_resolve(state,config.bone))
            binding.curve=base.name_hash(base.text_get(config.curve[:]))
            binding.at=-1
            binding.rig,binding.bound,binding.generation,binding.ready=state.entity,state.bound,state.generation,true
        }
        if binding.bone<=0 || int(binding.bone)>=len(playing_pose(state,.Local)) {
            core.report(problems,state.entity,"animation.curve_pose_bone","a curve pose of the .character of this rig, of curve '%s', names bone '%s', which its skeleton does not have, so it does not move; %s",base.text_get(config.curve[:]),base.text_get(config.bone.path[:]),bone_fix(config.bone))
            valid=false
            continue
        }
        if !config.enabled || config.weight<=0 {continue}
        curve:=rig_curve(state,leader,{target=binding.curve,property=.Float},&binding.at)
        if curve==nil || curve.weight<=0 || curve.value.x==0 {continue}
        sum:=&runtime.curve_full[binding.bone]
        applied:=lib.pose_accumulate(sum,config.delta,curve.value.x*config.weight) if config.full else lib.pose_delta_accumulate(sum,config.delta,curve.value.x*config.weight)
        if !applied {
            core.report(problems,state.entity,"animation.curve_pose_value","the curve '%s' that moves a pose of this rig has a value that is not finite, so its pose does not move; check the curves of its animation (animation.inspect)",base.text_get(config.curve[:]))
            valid=false
        }
    }
    if len(pose.curve_poses)==0 {return true}
    // Each bone that poses moved takes them once, and its sum starts over.
    for &binding in rig.curve_pose_states {
        bone:=binding.bone
        if bone<=0 || int(bone)>=len(playing_pose(state,.Local)) {continue}
        sum:=&runtime.curve_full[bone]
        if !(sum.weight>0) && !sum.added {continue}
        if !lib.pose_accumulated_apply(&playing_pose(state,.Local)[bone],sum^) {
            core.report(problems,state.entity,"animation.curve_pose_value","the curve poses of a bone of this rig sum to a pose that is not finite, so they do not move it; check the curves of its animation (animation.inspect)")
            valid=false
        }
        sum^={}
    }
    return valid
}
