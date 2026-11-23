package anim

import "core:math"
import "core:slice"
import "mirai:core"
import lib "mirai:std/anim"
import "mirai:std/base"
import erender "mirai:engine/render"
import mm "mirai:std/math"

POSE_CURVE_ROWS :: 4096 // rows of curve_poses, and of curve_materials, of a .character

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

// A value of the material of the meshes of a rig that a Float curve moves:
// offset plus scale times the curve, which step rounds to its multiples (the
// frames of a flipbook face, a switch) when it is positive. parameter names a
// value of the material (emission, roughness...) or a parameter of its
// program; slot is the material slot of the mesh, or every slot with every.
// It is a value each mesh of the rig shows at run time (erender.Material_Live)
// while the curve plays, over the one the entity authors under that name.
Curve_Material :: struct {
    curve:[64]u8 `mirai:"text"`,
    parameter:[64]u8 `mirai:"text"`,
    slot:u8 `mirai:"optional"`,
    every:bool `mirai:"optional"`,
    scale:[4]f32,
    offset:[4]f32 `mirai:"optional"`,
    step:f32 `mirai:"optional,min=0"`,
    enabled:bool,
}
CURVE_MATERIAL_DEFAULT :: Curve_Material{scale={1,1,1,1},enabled=true}

Curve_Binding :: struct {
    rig:core.Entity,
    bound:u64,
    generation:u32,
    ready:bool,
    bone:i32,     // of a pose
    curve,to:u64, // name hashes: of its curve, and of the parameter of a material value
    at:[2]i32,    // where its curve was found last among those of the rig and of its leader
}

@(private)
curve_poses_check :: proc(profile:Pose_Profile) -> bool {
    if len(profile.curve_poses)>POSE_CURVE_ROWS || len(profile.curve_materials)>POSE_CURVE_ROWS {return false}
    for &value in profile.curve_materials {
        if !blend_text_valid(value.curve[:],false) || !blend_text_valid(value.parameter[:],false) || int(value.slot)>=erender.MATERIAL_SLOTS || !finite(value.step) || value.step<0 {return false}
        for axis in 0..<4 {if !finite(value.scale[axis]) || !finite(value.offset[axis]) {return false}}
    }
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
// not matter. Its curve materials find their curves for animation_skin.
@(private)
curve_poses_apply :: proc(state:^Playing,playback:^Playback,runtime:^Modifier_Runtime,rig:^Modifier_Rig,pose:Pose_Profile,followed:bool,problems:^core.Problems) -> bool {
    if len(pose.curve_poses)>0 && len(runtime.curve_full)<len(playing_pose(state,.Local)) &&
        resize(&runtime.curve_full,len(playing_pose(state,.Local)))!=nil {
        memory_problem(problems,state.entity,"the curve poses of its .character")
        return false
    }
    leader:=rig_leader(core.ref(playback),state) if followed else nil
    for &config,row in pose.curve_materials {
        binding:=&rig.curve_material_states[row]
        if !binding.ready {
            binding^={rig=state.entity,ready=true,at=-1}
            binding.curve,binding.to=base.name_hash(base.text_get(config.curve[:])),base.name_hash(base.text_get(config.parameter[:]))
        }
        rig_curve(state,leader,{target=binding.curve,property=.Float},&binding.at)
    }
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

// Gives the material values that the curves of rig move to the Material_Live
// of entity, a mesh of it with slots material slots, and takes away those of
// the curves that do not play, and the component with the last of them.
// False when they do not fit in it (the others still apply).
@(private)
curve_materials_apply :: proc(runtime:^Modifier_Runtime,characters:^Character_Assets,playback:core.Ref(Playback),playing:^Playing,slots:int,lives:^core.Table(erender.Material_Live),entity:core.Entity) -> (fits:bool) {
    fits=true
    if playing==nil {return}
    rig:=modifier_rig(core.ref(runtime),playing.entity)
    pose:=modifier_pose(rig,characters)
    if pose==nil || len(pose.curve_materials)==0 {return}
    live:=core.staged(lives,entity)
    leader:=rig_leader(playback,playing)
    for &config,row in pose.curve_materials {
        binding:=rig.curve_material_states[row]
        name,parameter,at:=binding.curve,binding.to,binding.at
        if !binding.ready {
            name,parameter=base.name_hash(base.text_get(config.curve[:])),base.name_hash(base.text_get(config.parameter[:]))
            at=-1
        }
        curve:=config.enabled?rig_curve(playing,leader,{target=name,property=.Float},&at):nil
        amount:=curve!=nil?curve.value.x:0
        if config.step>0 {amount=math.floor(amount/config.step+.5)*config.step}
        value:=config.offset+config.scale*amount
        plays:=curve!=nil && curve.weight>0 && finite(value.x) && finite(value.y) && finite(value.z) && finite(value.w)
        for target in 0..<max(slots,1) {
            if !config.every && target!=int(config.slot) {continue}
            if !plays {
                if live!=nil {erender.material_value_drop(live,parameter,target)}
                continue
            }
            if live==nil {live=erender.material_live(lives,entity)}
            if live!=nil {fits &&=erender.material_value(live,parameter,value,target)}
        }
    }
    if live!=nil && live^=={} {core.remove(lives,entity)}
    return
}

