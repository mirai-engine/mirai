package anim

import "mirai:core"
import lib "mirai:std/anim"
import mm "mirai:std/math"

// Where an operation aims: a transform of the world, or one in the space of
// an entity, a bone of a rig or a socket of its skeleton. A profile names the
// kind and the bone or socket; the entity is the instance's and comes with a
// goal.
Spatial_Target_Kind :: enum u8 {World,Entity,Bone,Socket}
// position, rotation and scale: World: in the world; the others: in the
// space of what they name.
Spatial_Target :: struct {
    kind:Spatial_Target_Kind `mirai:"optional"`,
    entity:core.Entity `mirai:"transient"`, // Entity: itself; Bone and Socket: the rig
    bone:Bone_Ref `mirai:"optional"`,
    socket:[64]u8 `mirai:"optional,text"`,
    position:mm.Vec3 `mirai:"optional,unit=m"`,
    rotation:mm.Quat `mirai:"optional"`,
    scale:mm.Vec3 `mirai:"optional"`,
}
SPATIAL_TARGET_DEFAULT :: Spatial_Target{rotation=1,scale={1,1,1}}

spatial_world :: proc(transform:mm.Transform) -> Spatial_Target {
    target:=SPATIAL_TARGET_DEFAULT
    target.position,target.rotation,target.scale=transform.position,transform.rotation,transform.scale
    return target
}
spatial_point :: proc(position:mm.Vec3) -> Spatial_Target {return spatial_world({position=position,rotation=1,scale={1,1,1}})}
spatial_entity :: proc(entity:core.Entity,offset:mm.Transform=mm.TRANSFORM_IDENTITY) -> Spatial_Target {
    target:=spatial_world(offset)
    target.kind,target.entity=.Entity,entity
    return target
}
spatial_bone :: proc(rig:core.Entity,bone:string,offset:mm.Transform=mm.TRANSFORM_IDENTITY) -> Spatial_Target {
    target:=spatial_world(offset)
    target.kind,target.entity=.Bone,rig
    target.bone=bone_ref(bone)
    return target
}
spatial_socket :: proc(rig:core.Entity,socket:string,offset:mm.Transform=mm.TRANSFORM_IDENTITY) -> Spatial_Target {
    target:=spatial_world(offset)
    target.kind,target.entity=.Socket,rig
    copy(target.socket[:len(target.socket)-1],socket)
    return target
}
// Its transform: in the world, or in the space of what it names.
spatial_offset :: proc "contextless" (target:Spatial_Target) -> mm.Transform {return {target.position,target.rotation,target.scale}}

// Its bone or socket is resolved once per rig, skeleton and binding.
Spatial_Target_Binding :: struct {
    target:Spatial_Target,
    revision,skeleton_revision:u64,
    path:[dynamic]i32, // from the bone to the root
    socket:mm.Transform,
    ready:bool,
}

@(private)
spatial_transform_valid :: proc(value:mm.Transform) -> bool {return profile_vector(value.position) && profile_vector(value.scale) && profile_rotation(value.rotation)}

// What a profile may name (instance false: its entity comes with a goal) and
// what an instance can sample (instance true: an entity is named).
spatial_target_valid :: proc(target:Spatial_Target,instance:bool=true) -> bool {
    target:=target
    if target.kind>max(Spatial_Target_Kind) || !spatial_transform_valid(spatial_offset(target)) {return false}
    if target.kind==.World {return true}
    if instance && target.entity==core.NONE {return false}
    if target.kind==.Bone && !profile_bone(target.bone) || target.kind==.Socket && !blend_text_valid(target.socket[:],false) {return false}
    return true
}

@(private)
spatial_same_reference :: proc(a,b:Spatial_Target) -> bool {
    a,b:=a,b
    if a.kind!=b.kind {return false}
    switch a.kind {
    case .World: return true
    case .Entity: return a.entity==b.entity
    case .Bone: return a.entity==b.entity && a.bone==b.bone
    case .Socket: return a.entity==b.entity && a.socket==b.socket
    }
    return false
}

// The world transform a target names now. A bone or socket reads the pose
// its rig sampled in the tick frame (0: this one).
spatial_target_sample :: proc(target:Spatial_Target,binding:^Spatial_Target_Binding,playback:^Playback,skeletons:^Skeleton_Assets,transforms:^core.Table(core.Transform,$A),parents:^core.Table(core.Parent,.Read),worlds:^core.Table(core.World_Transform,$C),frame:u64=0) -> (result:mm.Transform,ok:bool) {
    if binding==nil || !spatial_target_valid(target) {return mm.TRANSFORM_IDENTITY,false}
    switch target.kind {
    case .World,.Entity:
        result=spatial_offset(target)
        if target.kind==.Entity {
            basis,found:=constraint_world(transforms,parents,core.read(worlds),target.entity)
            if !found {return mm.TRANSFORM_IDENTITY,false}
            result=mm.transform_compose(basis,spatial_offset(target))
            if !spatial_transform_valid(result) {return mm.TRANSFORM_IDENTITY,false}
        }
        // What it last named, for an operation that keeps its place when it changes.
        // One store per value until odin-lang/Odin#7937.
        binding.target=target
        binding.ready=true
        return result,true
    case .Bone,.Socket:
    }
    if playback==nil {return mm.TRANSFORM_IDENTITY,false}
    source:=constraint_playing(playback,target.entity)
    if source==nil || source.seen!=(frame if frame!=0 else playback.frame) || len(source.sampled)!=len(source.parents) {return mm.TRANSFORM_IDENTITY,false}
    if !binding.ready || !spatial_same_reference(binding.target,target) || binding.revision!=source.bound || binding.skeleton_revision!=source.skeleton_revision {
        binding.ready=false
        clear(&binding.path)
        binding.socket=mm.TRANSFORM_IDENTITY
        bone:=-1
        if target.kind==.Bone {bone=bone_resolve(source,target.bone)} else if skeletons!=nil {
            for &content in skeletons.contents {
                if content.id!=source.skeleton {continue}
                for socket in content.sockets {if socket.name==target.socket {bone=bone_resolve(source,{socket.bone});binding.socket=socket.offset;break}}
                break
            }
        }
        if bone<0 || reserve(&binding.path,len(source.parents))!=nil {return mm.TRANSFORM_IDENTITY,false}
        for index:=bone;index>=0;index=int(source.parents[index]) {
            if index>=len(source.parents) || source.parents[index]>=i32(index) {return mm.TRANSFORM_IDENTITY,false}
            append(&binding.path,i32(index))
        }
        // One store per value until odin-lang/Odin#7937.
        binding.target=target
        binding.revision,binding.skeleton_revision,binding.ready=source.bound,source.skeleton_revision,true
    }
    result=mm.TRANSFORM_IDENTITY
    #reverse for index in binding.path {
        if index==0 && source.skeleton!={} {
            actor,found:=constraint_world(transforms,parents,core.read(worlds),source.entity)
            if !found {return mm.TRANSFORM_IDENTITY,false}
            result=actor
        } else {result=mm.transform_compose(result,source.sampled[index])}
    }
    result=mm.transform_compose(mm.transform_compose(result,binding.socket),spatial_offset(target))
    return result,spatial_transform_valid(result)
}

// Keeps a bone on a target: its position, rotation or scale. keep_world
// keeps where the bone was when the target changes, as an offset from it.
Follow_Constraint :: struct {
    rig:core.Entity `mirai:"transient"`,
    name:[64]u8 `mirai:"text"`,
    bone:Bone_Ref,
    target:Spatial_Target,
    position,rotation,scale:bool,
    keep_world:bool,
    weight:f32 `mirai:"min=0,max=1"`,
    enabled:bool,
}
FOLLOW_CONSTRAINT_DEFAULT :: Follow_Constraint{target=SPATIAL_TARGET_DEFAULT,position=true,rotation=true,weight=1,enabled=true}
Follow_Binding :: struct {
    using binding:Rig_Binding,
    bone:i32,
    target:Spatial_Target_Binding,
    offset:mm.Transform,
    space_ready:bool,
}

@(private)
follow_apply :: proc(state:^Playing,runtime:^Modifier_Runtime,inputs:Constraint_Inputs,transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,$A),root_transform:mm.Transform,playback:^Playback) -> bool {
    first,end:=rig_rows(&runtime.follow,state.entity)
    if first==end {return true}
    if len(runtime.follow_states)!=len(runtime.follow.values) && resize(&runtime.follow_states,len(runtime.follow.values))!=nil {memory_problem(inputs.problems,state.entity,"the Follow operations of its .character");return false}
    if !lib.pose_world(state.parents[:],state.local[:],state.world[:],root_transform) {pose_problem(inputs.problems,state.entity);return false}
    valid:=true
    for &config,slot in runtime.follow.values[first:end] {
        binding:=&runtime.follow_states[first+slot]
        binding.diagnostic.valid=false
        if !rig_binding_current(binding,state,runtime.geometry) {
            binding.ready=false;binding.space_ready=false
            binding.bone=i32(bone_resolve(state,config.bone))
            if binding.bone<0 {rig_problem(inputs.problems,state.entity,.Follow,&config,.Bind);valid=false;continue}
            rig_binding_publish(binding,state,runtime.geometry,.Follow,u16(slot))
        }
        if !config.enabled || config.weight<=0 {continue}
        changed:=!binding.target.ready || !spatial_same_reference(binding.target.target,config.target)
        kept:=state.world[binding.bone]
        if changed && binding.space_ready && config.keep_world {
            previous,found:=spatial_target_sample(binding.target.target,&binding.target,playback,inputs.skeletons,transforms,parents,inputs.worlds)
            if !found {rig_problem(inputs.problems,state.entity,.Follow,&config,.Target);valid=false;continue}
            kept=mm.transform_compose(previous,binding.offset)
        }
        target,ok:=spatial_target_sample(config.target,&binding.target,playback,inputs.skeletons,transforms,parents,inputs.worlds)
        if !ok {modifier_request_rejected(runtime,state.entity,.Missing_Target);rig_problem(inputs.problems,state.entity,.Follow,&config,.Target);valid=false;continue}
        if !binding.space_ready || changed {
            binding.offset=mm.TRANSFORM_IDENTITY
            if config.keep_world {binding.offset,ok=mm.transform_relative(kept,target);if !ok {rig_problem(inputs.problems,state.entity,.Follow,&config,.Solve);valid=false;continue}}
            binding.space_ready=true
        }
        desired:=mm.transform_compose(target,binding.offset)
        original:=state.world[binding.bone]
        if !config.position {desired.position=original.position}
        if !config.rotation {desired.rotation=original.rotation}
        if !config.scale {desired.scale=original.scale}
        parent:=state.parents[binding.bone]
        local,relative:=mm.transform_relative(mm.transform_interpolate(original,desired,config.weight),state.world[parent] if parent>=0 else root_transform)
        solved:=relative
        if solved {state.local[binding.bone]=local;solved=lib.pose_world(state.parents[:],state.local[:],state.world[:],root_transform)}
        binding.diagnostic.valid,binding.diagnostic.reached=solved,solved
        if !solved {rig_problem(inputs.problems,state.entity,.Follow,&config,.Solve)}
        valid &&=solved
    }
    return valid
}
