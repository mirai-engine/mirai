package anim

import "core:math"
import "core:slice"
import "mirai:core"
import lib "mirai:std/anim"
import "mirai:std/base"
import erender "mirai:engine/render"
import mm "mirai:std/math"

POSE_CURVE_ROWS :: 4096 // rows of curve_poses, and of curve_drives, of a .character

// A pose that a Float curve brings to a bone, as the poses of a face (a blink,
// an open jaw, a phoneme): with the value of curve, from 0 to 1, the bone
// moves by delta over its pose. delta is in the space of the parent of the
// bone, as an additive pose keeps it, and its scale is a factor. A full pose
// is the transform of the bone itself instead: the full poses of a bone blend
// by their weights, normalized when they pass 1, before the additive ones. A
// pose of several bones is a row per bone with one curve.
Curve_Pose :: struct {
    rig:core.Entity `mirai:"transient"`,
    curve:[64]u8 `mirai:"text"`,
    bone:Bone_Ref,
    delta:mm.Transform,
    weight:f32 `mirai:"min=0,max=1"`,
    full:bool,
    enabled:bool,
}
CURVE_POSE_DEFAULT :: Curve_Pose{delta=mm.TRANSFORM_IDENTITY,weight=1,enabled=true}

// What a drive reads of from and with: from alone, or both multiplied (a
// shape that only both curves together bring), their least or their most.
Curve_Combine :: enum u8 {From,Product,Min,Max}
// What a drive does to its curve: adds to it, replaces it or keeps the most.
Curve_Drive_Mode :: enum u8 {Add,Replace,Max}

// A Float curve that drives another: to receives scale times what it reads
// of from (and with), plus offset, clamped to low..high when clamp is on. The
// rows apply in order, so a curve an earlier row drives drives the next: the
// curves of a face capture become those of the poses of a face, two curves
// together give a combination shape, and a curve named as a morph target of
// the mesh moves it. weight blends the curve from before the drive.
Curve_Drive :: struct {
    rig:core.Entity `mirai:"transient"`,
    from,to:[64]u8 `mirai:"text"`,
    with:[64]u8 `mirai:"text,optional"`, // the second curve of Product, Min and Max
    combine:Curve_Combine `mirai:"optional"`,
    mode:Curve_Drive_Mode `mirai:"optional"`,
    scale:f32,
    offset:f32 `mirai:"optional"`,
    clamp:bool `mirai:"optional"`,
    low,high:f32 `mirai:"optional"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    enabled:bool,
}
CURVE_DRIVE_DEFAULT :: Curve_Drive{scale=1,high=1,weight=1,enabled=true}

// A value of the material of the meshes of a rig that a Float curve moves:
// offset plus scale times the curve, which step rounds to its multiples (the
// frames of a flipbook face, a switch) when it is positive. parameter names a
// value of the material (emission, roughness...) or a parameter of its
// program; slot is the material slot of the mesh, or every slot with every.
// It is a value the Material_Values of each mesh of the rig show at run time
// (erender.material_live) while the curve plays, over the one the entity
// authors under that name.
Curve_Material :: struct {
    rig:core.Entity `mirai:"transient"`,
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
    bound,geometry:u64,
    generation:u32,
    ready:bool,
    bone:i32,           // of a pose
    curve,with,to:u64,  // name hashes: of the pose or of the curves a drive reads, and of the one it drives; of a material value, to is its parameter
    slot,with_slot:i32, // where they were found last
    to_slot:i32,        // where the curve a drive writes is in the final curves
}

@(private)
curve_poses_check :: proc(profile:Pose_Profile) -> bool {
    if len(profile.curve_poses)>POSE_CURVE_ROWS || len(profile.curve_drives)>POSE_CURVE_ROWS || len(profile.curve_materials)>POSE_CURVE_ROWS {return false}
    for &value in profile.curve_materials {
        if !blend_text_valid(value.curve[:],false) || !blend_text_valid(value.parameter[:],false) || int(value.slot)>=erender.MATERIAL_SLOTS || !finite(value.step) || value.step<0 {return false}
        for axis in 0..<4 {if !finite(value.scale[axis]) || !finite(value.offset[axis]) {return false}}
    }
    for &value in profile.curve_poses {
        if !blend_text_valid(value.curve[:],false) || !profile_bone(value.bone) || !spatial_transform_valid(value.delta) || !profile_weight(value.weight) {return false}
    }
    for &value in profile.curve_drives {
        paired:=value.combine!=.From
        if !blend_text_valid(value.from[:],false) || !blend_text_valid(value.to[:],false) || !blend_text_valid(value.with[:],!paired) || paired==(value.with[0]==0) || value.from==value.to || paired && value.with==value.to {return false}
        if value.combine>max(Curve_Combine) || value.mode>max(Curve_Drive_Mode) || !finite(value.scale) || !finite(value.offset) || !finite(value.low) || !finite(value.high) || value.clamp && value.low>value.high || !profile_weight(value.weight) {return false}
    }
    return true
}

// The curves a lookup of a rig reads: those of its animation, or with a
// leader or drives, those after them. Both are in curve_order.
playing_curves :: proc "contextless" (state:^Playing) -> []Curve_Output {
    return state.driven[:] if state.driven_ready else state.curves[:]
}

// The order of the curves of a rig: by name hash, property and slot.
curve_order :: proc(a,b:Curve_Output) -> bool {
    if a.target!=b.target {return a.target<b.target}
    if a.property!=b.property {return a.property<b.property}
    return a.slot<b.slot
}

@(private)
curve_compare :: proc(a,b:Curve_Output) -> slice.Ordering {return .Less if curve_order(a,b) else .Greater if curve_order(b,a) else .Equal}

// The Float curve of slot 0 with this name hash among curves; slot keeps where
// it was, so a rig whose curves stay in place finds it at once, and curves in
// curve_order are searched by halves.
@(private)
curve_slot :: proc(curves:[]Curve_Output,target:u64,slot:^i32) -> ^Curve_Output {
    if at:=int(slot^);at>=0 && at<len(curves) && curves[at].target==target && curves[at].property==.Float && curves[at].slot==0 {return &curves[at]}
    key:=Curve_Output{target=target,property=.Float}
    if at,found:=slice.binary_search_by(curves,key,curve_compare);found {slot^=i32(at);return &curves[at]}
    for &curve,at in curves {
        if curve.target==target && curve.property==.Float && curve.slot==0 {slot^=i32(at);return &curve}
    }
    slot^=-1
    return nil
}

@(private)
curve_same :: proc "contextless" (a,b:Curve_Output) -> bool {return a.target==b.target && a.property==b.property && a.slot==b.slot}

// What the final curves of a rig were laid out for: how many curves it and its
// leader have, the rows of its profile, its skeleton and its leader.
@(private)
Driven_Key :: [7]u64

// Lays out the final curves of a rig once: its own curves, its leader's and
// those its drives write, each once in curve_order; where each of its own and
// of its leader's goes; and where the drives of its profile find theirs. It
// runs again only when what it was laid out for changes, so a stable tick
// reserves and searches nothing.
@(private)
curves_layout :: proc(state:^Playing,leader:[]Curve_Output,runtime:^Modifier_Runtime,drive_first,drive_end:int) -> bool {
    if reserve(&state.driven,len(state.curves)+len(leader)+(drive_end-drive_first))!=nil || resize(&state.driven_own,len(state.curves))!=nil || resize(&state.driven_leader,len(leader))!=nil {return false}
    clear(&state.driven)
    for curve in state.curves {append(&state.driven,Curve_Output{target=curve.target,property=curve.property,slot=curve.slot})}
    for curve in leader {append(&state.driven,Curve_Output{target=curve.target,property=curve.property,slot=curve.slot})}
    for row in drive_first..<drive_end {append(&state.driven,Curve_Output{target=base.name_hash(base.text_get(runtime.curve_drives.values[row].to[:])),property=.Float})}
    slice.sort_by(state.driven[:],curve_order)
    kept:=0
    for curve in state.driven {
        if kept>0 && curve_same(curve,state.driven[kept-1]) {continue}
        state.driven[kept]=curve;kept+=1
    }
    base.truncate(&state.driven,kept)
    find :: proc(curves:[]Curve_Output,key:Curve_Output) -> i32 {
        at,found:=slice.binary_search_by(curves,key,curve_compare)
        return i32(at) if found else -1
    }
    for curve,i in state.curves {state.driven_own[i]=find(state.driven[:],curve)}
    for curve,i in leader {state.driven_leader[i]=find(state.driven[:],curve)}
    for row in drive_first..<drive_end {
        config:=&runtime.curve_drives.values[row]
        binding:=&runtime.curve_drive_states[row]
        binding^={rig=state.entity,bound=state.bound,generation=state.generation,geometry=runtime.geometry,ready=true}
        binding.curve,binding.to=base.name_hash(base.text_get(config.from[:])),base.name_hash(base.text_get(config.to[:]))
        binding.with=base.name_hash(base.text_get(config.with[:])) if config.combine!=.From else 0
        binding.slot=find(state.driven[:],{target=binding.curve,property=.Float})
        binding.with_slot=find(state.driven[:],{target=binding.with,property=.Float}) if binding.with!=0 else -1
        binding.to_slot=find(state.driven[:],{target=binding.to,property=.Float})
    }
    layout:u64=0
    for curve in state.driven {layout=base.hash_mix(layout,curve.target)}
    state.curve_layout=base.hash_mix(layout,u64(len(state.driven)))
    return true
}

// The final curves of a rig take the values of this tick: its own, and over
// them those its leader animates. False when its curves or its leader's are not
// those they were laid out for.
@(private)
curves_fill :: proc "contextless" (state:^Playing,leader:[]Curve_Output) -> bool {
    if len(state.driven_own)!=len(state.curves) || len(state.driven_leader)!=len(leader) {return false}
    driven:=state.driven[:]
    for &curve in driven {curve.value,curve.weight={},0}
    for curve,i in state.curves {
        at:=int(state.driven_own[i])
        if at<0 || at>=len(driven) || !curve_same(driven[at],curve) {return false}
        driven[at]=curve
    }
    for curve,i in leader {
        if curve.weight<=0 {continue}
        at:=int(state.driven_leader[i])
        if at<0 || at>=len(driven) || !curve_same(driven[at],curve) {return false}
        driven[at]=curve
    }
    return true
}

// The final curves of a rig with a leader or curve drives: those of its
// animation, where the leader's animated ones replace them, and then the
// drives of its profile in their order. Then the curve poses of its profile
// move its bones: the full ones first, then the additive ones, each summed by
// bone so that the order of the rows does not matter. Its curve materials find
// their curves for animation_skin. Reserving happens only when the curves, the
// profile or the skeleton change.
@(private)
curve_poses_apply :: proc(state:^Playing,playback:^Playback,runtime:^Modifier_Runtime,followed:bool,problems:^core.Problems) -> bool {
    drive_first,drive_end:=0,0
    pose_first,pose_end:=0,0
    material_first,material_end:=0,0
    if runtime!=nil {
        drive_first,drive_end=rig_rows(&runtime.curve_drives,state.entity)
        pose_first,pose_end=rig_rows(&runtime.curve_poses,state.entity)
        material_first,material_end=rig_rows(&runtime.curve_materials,state.entity)
        if drive_first<drive_end && len(runtime.curve_drive_states)!=len(runtime.curve_drives.values) && resize(&runtime.curve_drive_states,len(runtime.curve_drives.values))!=nil ||
           pose_first<pose_end && len(runtime.curve_pose_states)!=len(runtime.curve_poses.values) && resize(&runtime.curve_pose_states,len(runtime.curve_poses.values))!=nil ||
           material_first<material_end && len(runtime.curve_material_states)!=len(runtime.curve_materials.values) && resize(&runtime.curve_material_states,len(runtime.curve_materials.values))!=nil ||
           pose_first<pose_end && len(runtime.curve_full)<len(state.local) && resize(&runtime.curve_full,len(state.local))!=nil {
            memory_problem(problems,state.entity,"the curve poses and drives of its .character");state.driven_ready=false;return false
        }
    }
    leader:=constraint_playing(playback,state.leader) if followed else nil
    state.driven_ready=false
    if leader!=nil || drive_first<drive_end {
        leader_curves:=playing_curves(leader) if leader!=nil else nil
        key:=Driven_Key{1,u64(len(state.curves)),u64(len(leader_curves)),runtime.geometry if runtime!=nil else 0,state.bound,u64(state.generation),u64(state.leader) if leader!=nil else 0}
        if state.driven_key!=key || !curves_fill(state,leader_curves) {
            state.driven_key={}
            if !curves_layout(state,leader_curves,runtime,drive_first,drive_end) {memory_problem(problems,state.entity,"its curves");return false}
            curves_fill(state,leader_curves)
            state.driven_key=key
        }
        driven:=state.driven[:]
        for row in drive_first..<drive_end {
            config:=&runtime.curve_drives.values[row]
            binding:=runtime.curve_drive_states[row]
            if !config.enabled || config.weight<=0 || binding.to_slot<0 || int(binding.to_slot)>=len(driven) {continue}
            a,b:f32;weight:f32
            if at:=int(binding.slot);at>=0 && at<len(driven) {a,weight=driven[at].value.x,driven[at].weight}
            if at:=int(binding.with_slot);config.combine!=.From && at>=0 && at<len(driven) {b=driven[at].value.x;weight=max(weight,driven[at].weight)}
            if weight<=0 {continue}
            read:=a
            switch config.combine {
            case .From:
            case .Product: read=a*b
            case .Min: read=min(a,b)
            case .Max: read=max(a,b)
            }
            value:=read*config.scale+config.offset
            if config.clamp {value=clamp(value,config.low,config.high)}
            to:=&driven[binding.to_slot]
            before:=to.value.x
            switch config.mode {
            case .Add: value+=before
            case .Replace:
            case .Max: value=max(before,value)
            }
            value=mm.lerp(before,value,config.weight)
            if finite(value) {to.value.x=value;to.weight=max(to.weight,weight*config.weight)}
        }
        state.driven_ready=true
    }
    curves:=playing_curves(state)
    for row in material_first..<material_end {
        binding:=&runtime.curve_material_states[row]
        if !binding.ready || binding.rig!=state.entity || binding.geometry!=runtime.geometry {
            config:=&runtime.curve_materials.values[row]
            binding^={rig=state.entity,geometry=runtime.geometry,ready=true,slot=-1}
            binding.curve,binding.to=base.name_hash(base.text_get(config.curve[:])),base.name_hash(base.text_get(config.parameter[:]))
        }
        curve_slot(curves,binding.curve,&binding.slot)
    }
    if pose_first>=pose_end {return true}
    valid:=true
    for row in pose_first..<pose_end {
        config:=&runtime.curve_poses.values[row]
        binding:=&runtime.curve_pose_states[row]
        if !rig_binding_current(binding,state,runtime.geometry) {
            binding.bone=i32(bone_resolve(state,config.bone))
            binding.curve=base.name_hash(base.text_get(config.curve[:]))
            binding.slot=-1
            binding.rig,binding.bound,binding.generation,binding.geometry,binding.ready=state.entity,state.bound,state.generation,runtime.geometry,true
        }
        if binding.bone<=0 || int(binding.bone)>=len(state.local) {
            core.report(problems,state.entity,"animation.curve_pose_bone","a curve pose of the .character of this rig, of curve '%s', names bone '%s', which its skeleton does not have, so it does not move; %s",base.text_get(config.curve[:]),base.text_get(config.bone.path[:]),bone_fix(config.bone))
            valid=false
            continue
        }
        if !config.enabled || config.weight<=0 {continue}
        curve:=curve_slot(curves,binding.curve,&binding.slot)
        if curve==nil || curve.weight<=0 || curve.value.x==0 {continue}
        sum:=&runtime.curve_full[binding.bone]
        applied:=lib.pose_accumulate(sum,config.delta,curve.value.x*config.weight) if config.full else lib.pose_delta_accumulate(sum,config.delta,curve.value.x*config.weight)
        if !applied {
            core.report(problems,state.entity,"animation.curve_pose_value","the curve '%s' that moves a pose of this rig has a value that is not finite, so its pose does not move; check the curves of its animation (animation.inspect)",base.text_get(config.curve[:]))
            valid=false
        }
    }
    // Each bone that poses moved takes them once, and its sum starts over.
    for row in pose_first..<pose_end {
        bone:=runtime.curve_pose_states[row].bone
        if bone<=0 || int(bone)>=len(state.local) {continue}
        sum:=&runtime.curve_full[bone]
        if !(sum.weight>0) && !sum.added {continue}
        if !lib.pose_accumulated_apply(&state.local[bone],sum^) {
            core.report(problems,state.entity,"animation.curve_pose_value","the curve poses of a bone of this rig sum to a pose that is not finite, so they do not move it; check the curves of its animation (animation.inspect)")
            valid=false
        }
        sum^={}
    }
    return valid
}

// Gives the material values that the curves of rig move to the live part of
// the Material_Values of entity, a mesh of it with slots material slots, and
// takes away those of the curves that do not play. playing: the world plays,
// and an entity without the component takes it. False when they do not fit
// in it (the others still apply).
@(private)
curve_materials_apply :: proc(runtime:^Modifier_Runtime,rig:^Playing,slots:int,looks:^core.Table(erender.Material_Values),entity:core.Entity,playing:bool) -> (fits:bool) {
    fits=true
    if runtime==nil || rig==nil {return}
    first,end:=rig_rows(&runtime.curve_materials,rig.entity)
    if first>=end {return}
    live:=erender.material_live(looks,entity,false)
    curves:=playing_curves(rig)
    for row in first..<end {
        config:=&runtime.curve_materials.values[row]
        // The names curve_poses_apply hashed for the rig, and where it found its curve.
        name,parameter,slot:=u64(0),u64(0),i32(-1)
        if row<len(runtime.curve_material_states) && runtime.curve_material_states[row].ready && runtime.curve_material_states[row].rig==rig.entity && runtime.curve_material_states[row].geometry==runtime.geometry {
            binding:=runtime.curve_material_states[row]
            name,parameter,slot=binding.curve,binding.to,binding.slot
        } else {
            name,parameter=base.name_hash(base.text_get(config.curve[:])),base.name_hash(base.text_get(config.parameter[:]))
        }
        curve:=config.enabled?curve_slot(curves,name,&slot):nil
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
            if live==nil {live=erender.material_live(looks,entity,playing)}
            if live!=nil {fits &&=erender.material_value(live,parameter,value,target)}
        }
    }
    return
}

