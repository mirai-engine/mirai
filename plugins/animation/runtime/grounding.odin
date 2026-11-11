package anim

import "core:math/linalg"
import "mirai:core"
import lib "mirai:std/anim"
import mm "mirai:std/math"

GROUNDING_LEGS :: 16
Grounding_Mode :: enum u8 {Animated,Procedural}

// A leg: bones left empty in the first two legs are those of the left and the right leg of the
// body of the skeleton, the contact its toe; in the others they are needed.
Grounded_Leg :: struct {
    hip,knee,foot,contact_bone:Bone_Ref,
    pole_offset,foot_up:mm.Vec3,
    sole_height,contact_offset,contact_height,plant_speed,max_tilt:f32,
    phase,step_distance,step_height,step_duration,max_distance,contact:f32,
}
GROUNDED_LEG_DEFAULT :: Grounded_Leg{
    foot_up={0,1,0},sole_height=0.05,contact_height=0.08,plant_speed=0.6,max_tilt=mm.PI*.5,
    step_distance=0.2,step_height=0.15,step_duration=0.2,max_distance=0.7,contact=1,
}

// The grounding of the feet of the rig that plays the .character: none while count is 0.
Foot_Grounding :: struct {
    mode:Grounding_Mode,
    legs:[GROUNDING_LEGS]Grounded_Leg `mirai:"hidden"`,
    count:i32 `mirai:"min=0,max=16"`,
    body:Bone_Ref, // empty: the pelvis of the body of the skeleton
    up:mm.Vec3, // in the frame of the rig as it is placed, not as its bones move; the rig of a character plants its feet along the up of its vertical (core.Vertical)
    trace_above,trace_below,minimum_ground_dot:f32,
    collision_mask:u32, // the collision categories the feet stand on, a bit each
    global_contact,weight:f32 `mirai:"min=0,max=1"`,
    blend_time,release_distance,replant_distance:f32,
    cycle_duration,swing_fraction:f32,
    max_swinging:i32,
    body_height,max_drop,max_rise,max_tilt:f32,
    prediction:f32,
    adjust_body,enabled:bool,
}
FOOT_GROUNDING_DEFAULT :: Foot_Grounding{
    up={0,1,0},trace_above=0.5,trace_below=1,minimum_ground_dot=0.3,collision_mask=0xffffffff,
    global_contact=1,weight=1,blend_time=0.1,release_distance=0.6,replant_distance=0.3,
    cycle_duration=0.8,swing_fraction=0.4,max_swinging=4,body_height=0.7,
    max_drop=0.5,max_rise=0.3,max_tilt=0.5,prediction=0.15,adjust_body=true,enabled=true,
}

Grounding_Alignment :: struct {offset:mm.Vec3,turn:mm.Quat,weight:f32}
Grounding_Hierarchy :: struct {bound:u64,first,count:int}

Grounding_Record :: struct {
    rig:core.Entity `mirai:"transient"`,
    bound,version:u64,
    count,body:i32,
    mode:Grounding_Mode,
    bones:[GROUNDING_LEGS][3]int,
    contact_bones:[GROUNDING_LEGS]int,
    gait:lib.Gait_State,
    legs:[GROUNDING_LEGS]lib.Gait_Leg_State,
    placements:[GROUNDING_LEGS]lib.Foot_Placement_State,
    alignment:[GROUNDING_LEGS]Grounding_Alignment,
    previous:[GROUNDING_LEGS]lib.Surface_Anchor,
    root_position:mm.Vec3,
    targets:[GROUNDING_LEGS]lib.Foot_Target,
    rotations:[GROUNDING_LEGS]mm.Quat,
    body_offset:mm.Vec3,
    body_turn:mm.Quat,
    blocked:u16,
    initialized:bool,
}

@(storage,free="grounding_free")
Grounding_Runtime :: struct {
    records:[dynamic]Grounding_Record,
    rows:[dynamic]i32,
    hierarchies:[dynamic]Grounding_Hierarchy,
    links:[dynamic]lib.Pose_Link,
    stamp,layout:u64,
}

// What the rays of a rig skip: the nearest of it and its parents with a body.
ground_ignore :: proc(ground:core.World_Query,parents:^core.Table(core.Parent,$A),rig:core.Entity) -> core.Entity {
    ignore:=rig
    if ground.solid==nil || parents==nil {return ignore}
    for attempts:=0;attempts<256;attempts+=1 {
        if ground.solid(ground.user,ignore) {break}
        parent,ok:=core.get(parents,ignore)
        if !ok || parent.entity==core.NONE {break}
        ignore=parent.entity
    }
    return ignore
}

Grounding_Inputs :: struct {
    configs:^core.Table(Foot_Grounding,.Read),
    ground:core.World_Query, // the feet stand on what it hits; without a library that gives it no foot is grounded
    transforms:^core.Table(core.Transform,.Read),
    parents:^core.Table(core.Parent,.Read),
    geometry:u64,
    problems:^core.Problems,
    verticals:^core.Table(core.Vertical,.Read),
}

grounding_free :: proc(cache:^Grounding_Runtime) {
    delete(cache.records);delete(cache.rows);delete(cache.hierarchies);delete(cache.links);cache^={}
}

grounding_prepare :: proc(cache:^Grounding_Runtime,configs:^core.Table(Foot_Grounding,$A),problems:^core.Problems) -> bool {
    if cache==nil {return false}
    count:=constraint_count(configs)
    stamp:=constraint_stamp(configs)
    if cache.stamp==stamp {return true}
    layout:=core.layout(configs) if configs!=nil else 0
    rebuild:=cache.layout!=layout || len(cache.records)!=count || len(cache.hierarchies)!=count
    if !rebuild {
        for i in 0..<count {if cache.records[i].rig!=core.entity_at(configs,i) {rebuild=true;break}}
    }
    if !rebuild {cache.stamp=stamp;return true}
    records:[dynamic]Grounding_Record;rows:[dynamic]i32
    hierarchies:[dynamic]Grounding_Hierarchy;links:[dynamic]lib.Pose_Link
    defer {delete(records);delete(rows);delete(hierarchies);delete(links)}
    if resize(&records,count)!=nil || resize(&hierarchies,count)!=nil {memory_problem(problems,core.NONE,"the grounding of the rigs, so no foot is grounded");return false}
    for i in 0..<count {
        rig:=core.entity_at(configs,i)
        index:=core.entity_index(rig)
        if index>=len(rows) && resize(&rows,index+1)!=nil {memory_problem(problems,core.NONE,"the grounding of the rigs, so no foot is grounded");return false}
        rows[index]=i32(i+1)
        records[i]={rig=rig}
        for previous,j in cache.records {
            if previous.rig!=rig {continue}
            records[i]=previous
            if j<len(cache.hierarchies) {hierarchies[i]=cache.hierarchies[j]}
            break
        }
    }
    total:=0
    for hierarchy in hierarchies {
        if hierarchy.first<0 || hierarchy.count<0 || hierarchy.first>len(cache.links) || hierarchy.count>len(cache.links)-hierarchy.first || hierarchy.count>max(int)-total {grounding_inconsistent(problems,core.NONE);return false}
        total+=hierarchy.count
    }
    if resize(&links,total)!=nil {memory_problem(problems,core.NONE,"the grounding of the rigs, so no foot is grounded");return false}
    offset:=0
    for &hierarchy in hierarchies {
        copy(links[offset:offset+hierarchy.count],cache.links[hierarchy.first:hierarchy.first+hierarchy.count])
        hierarchy.first=offset;offset+=hierarchy.count
    }
    delete(cache.records);delete(cache.rows);delete(cache.hierarchies);delete(cache.links)
    cache.records,cache.rows=records,rows;records,rows=nil,nil
    cache.hierarchies,cache.links=hierarchies,links;hierarchies,links=nil,nil
    cache.stamp,cache.layout=stamp,layout
    return true
}

// The bone links grounding keeps for its rigs contradict themselves: a bug of the engine.
@(private)
grounding_inconsistent :: proc(problems:^core.Problems,e:core.Entity) {
    core.report(problems,e,"animation.grounding_state","the grounding state lost its bone links, a bug of the engine: no foot is grounded until Foot_Grounding changes; change it to rebuild it, and report the scene")
}

// A step of grounding that could not solve in a tick; false.
@(private)
grounding_unsolved :: proc(problems:^core.Problems,e:core.Entity,step:string,leg:=-1) -> bool {
    if leg>=0 {
        core.report(problems,e,"animation.grounding_solve","the grounding of this rig could not solve %s of leg %d: a value of Foot_Grounding, of that leg or of the pose is not finite, or the leg is folded flat; check them (animation.inspect)",step,leg)
    } else {
        core.report(problems,e,"animation.grounding_solve","the grounding of this rig could not solve %s: a value of Foot_Grounding or of the pose is not finite, or a leg is folded flat; check them (animation.inspect)",step)
    }
    return false
}

@(private)
grounding_config_valid :: proc(config:Foot_Grounding) -> bool {
    if config.count<1 || config.count>GROUNDING_LEGS || config.mode>.Procedural {return false}
    if !finite(linalg.length(config.up)) || linalg.length(config.up)<1e-6 {return false}
    numbers:=[?]f32{config.trace_above,config.trace_below,config.minimum_ground_dot,config.global_contact,config.weight,config.blend_time,config.release_distance,config.replant_distance,config.cycle_duration,config.swing_fraction,config.body_height,config.max_drop,config.max_rise,config.max_tilt,config.prediction}
    for number in numbers {if !finite(number) || number<0 {return false}}
    if config.trace_above+config.trace_below<=0 || !finite(config.trace_above+config.trace_below) || config.minimum_ground_dot>1 || config.global_contact>1 || config.weight>1 || config.replant_distance>config.release_distance || config.cycle_duration<=0 || config.swing_fraction<=0 || config.swing_fraction>1 || config.max_swinging<=0 {return false}
    for i in 0..<int(config.count) {
        leg:=config.legs[i]
        values:=[?]f32{leg.sole_height,leg.contact_offset,leg.contact_height,leg.plant_speed,leg.max_tilt,leg.phase,leg.step_distance,leg.step_height,leg.step_duration,leg.max_distance,leg.contact}
        for value in values {if !finite(value) || value<0 {return false}}
        if leg.phase>=1 || leg.step_duration<=0 || leg.max_distance<leg.step_distance || leg.contact>1 || linalg.length(leg.foot_up)<1e-6 {return false}
        for value in leg.foot_up {if !finite(value) {return false}}
        for value in leg.pole_offset {if !finite(value) {return false}}
    }
    return true
}

@(private)
grounding_hierarchy_prepare :: proc(cache:^Grounding_Runtime,row:int,state:^Playing) -> bool {
    old:=cache.hierarchies[row]
    count:=len(state.parents)
    if old.bound==state.bound && old.count==count {return true}
    if !lib.skeleton_validate(playing_skeleton(state)) || old.first<0 || old.count<0 || old.first>len(cache.links) || old.count>len(cache.links)-old.first {return false}
    remaining:=len(cache.links)-old.count
    if count>max(int)-remaining {return false}
    first:=old.first if old.count>0 else len(cache.links)
    links:[dynamic]lib.Pose_Link
    defer delete(links)
    if resize(&links,remaining+count)!=nil {return false}
    copy(links[:first],cache.links[:first])
    copy(links[first+count:],cache.links[first+old.count:])
    if _,ok:=lib.pose_hierarchy_prepare(state.parents[:],links[first:first+count]);!ok {return false}
    for &hierarchy,i in cache.hierarchies {
        if i!=row && hierarchy.count>0 && hierarchy.first>=first+old.count {hierarchy.first+=count-old.count}
    }
    cache.hierarchies[row]={state.bound,first,count}
    delete(cache.links);cache.links=links;links=nil
    return true
}

@(private)
grounding_bind :: proc(cache:^Grounding_Runtime,row:int,state:^Playing,config:Foot_Grounding,version:u64,problems:^core.Problems) -> bool {
    record:=&cache.records[row]
    hierarchy:=cache.hierarchies[row]
    if record.version==version && record.bound==state.bound && hierarchy.bound==state.bound && hierarchy.count==len(state.parents) {return true}
    if !grounding_config_valid(config) {
        core.report(problems,state.entity,"animation.grounding_config","Foot_Grounding of this rig has a value out of range: count 1 to 16, a nonzero up, distances, times and weights finite and not negative, replant_distance not above release_distance, swing_fraction 0 to 1, and in each leg phase below 1 and max_distance not below step_distance; fix it")
        return false
    }
    bones:[GROUNDING_LEGS][3]int
    contacts:[GROUNDING_LEGS]int
    // A bone a table leaves empty is the part of the body of the skeleton it stands for.
    part :: proc(state:^Playing,ref:Bone_Ref,default:lib.Body_Part) -> int {
        if ref!={} {return bone_resolve(state,ref)}
        return int(state.body[default]) if state.body[default]>0 else -1
    }
    LEGS :: [2][4]lib.Body_Part{{.Hip_L,.Knee_L,.Foot_L,.Toe_L},{.Hip_R,.Knee_R,.Foot_R,.Toe_R}}
    for i in 0..<int(config.count) {
        leg:=config.legs[i]
        sides:=LEGS;side:=sides[min(i,1)]
        if i<2 {bones[i]={part(state,leg.hip,side[0]),part(state,leg.knee,side[1]),part(state,leg.foot,side[2])}} else {bones[i]={bone_resolve(state,leg.hip),bone_resolve(state,leg.knee),bone_resolve(state,leg.foot)}}
        hip,knee,foot:=bones[i][0],bones[i][1],bones[i][2]
        if hip<=0 || knee<=0 || foot<=0 || state.parents[knee]!=i32(hip) || state.parents[foot]!=i32(knee) {
            core.report(problems,state.entity,"animation.grounding_bones","leg %d of Foot_Grounding: its hip, knee and foot are not a chain of bones of this skeleton, each the parent of the next; name such a chain (animation.asset.inspect lists the bones)",i)
            return false
        }
        contacts[i]=foot
        if toe:=int(state.body[side[3]]);leg.contact_bone=={} && i<2 && toe>0 && state.parents[toe]==i32(foot) {contacts[i]=toe}
        if leg.contact_bone!={} {
            contacts[i]=bone_resolve(state,leg.contact_bone)
            ancestor:=contacts[i]
            for ancestor>foot {ancestor=int(state.parents[ancestor])}
            if contacts[i]<0 || ancestor!=foot {
                core.report(problems,state.entity,"animation.grounding_bones","leg %d of Foot_Grounding: its contact_bone is not a bone below its foot; name one, or leave it empty",i)
                return false
            }
        }
    }
    body:=part(state,config.body,.Pelvis)
    if !grounding_hierarchy_prepare(cache,row,state) {
        core.report(problems,state.entity,"animation.grounding_bones","the skeleton of this rig cannot be grounded: its bones are not ordered parents first, or memory ran out; import the skeleton again, or free memory")
        return false
    }
    if record.count!=config.count || record.mode!=config.mode || record.bound!=state.bound || record.bones!=bones || record.contact_bones!=contacts || record.body!=i32(body) {
        record^=Grounding_Record{rig=record.rig}
    }
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    record.bones=bones
    record.count,record.body=config.count,i32(body)
    record.contact_bones=contacts
    record.mode,record.version,record.bound=config.mode,version,state.bound
    return true
}

@(private)
grounding_support :: proc(ground:core.World_Query,id:u64,supports:[]lib.Surface_Support,count:^int) {
    if id==0 || count^>=len(supports) {return}
    for support in supports[:count^] {if support.id==id {return}}
    transform,ok:=ground.support(ground.user,id)
    if !ok {return}
    supports[count^]={id,transform}
    count^+=1
}

@(private)
grounding_clearance :: proc(position,sole:mm.Vec3,up:mm.Vec3,config:Foot_Grounding,inputs:Grounding_Inputs,ignore:core.Entity) -> f32 {
    hit,ok:=inputs.ground.probe(inputs.ground.user,position+up*config.trace_above,-up,config.trace_above+config.trace_below,0,ignore,config.collision_mask)
    if !ok {return 0}
    slope:=linalg.dot(hit.normal,up)
    if slope<config.minimum_ground_dot || slope<1e-5 {return 0}
    return max(0,linalg.dot(hit.point-position+sole,hit.normal)/slope)
}

grounding_limb_hit :: proc(ground:core.World_Query,hip,knee,foot:mm.Vec3,ignore:=core.NONE,mask:=~u32(0)) -> (core.World_Hit,bool) {
    if ground.probe==nil {return {},false}
    for point in ([3]mm.Vec3{hip,knee,foot}) {for value in point {if !finite(value) {return {},false}}}
    for segment in ([2][2]mm.Vec3{{hip,knee},{knee,foot}}) {
        delta:=segment[1]-segment[0]
        length:=linalg.length(delta)
        if !finite(length) || length<=.0001 {continue}
        hit,ok:=ground.probe(ground.user,segment[0],delta,length,0,ignore,mask)
        if ok && hit.distance<length-.0001 {return hit,true}
    }
    return {},false
}

// The up the feet of a rig stand along: that of the vertical of the
// character it is of (core.Vertical, on the rig or above it), or else up in
// the frame of the rig under basis, the world of its parent; never as the
// bones of the rig turn in its animation.
grounding_up :: proc(inputs:Grounding_Inputs,rig:core.Entity,basis:mm.Transform,up:mm.Vec3) -> mm.Vec3 {
    if inputs.verticals!=nil {
        e:=rig
        for _ in 0..<GROUNDING_DEPTH {
            if core.has(inputs.verticals,e) {return mm.quat_rotate(core.vertical_of(inputs.verticals,e),{0,1,0})}
            if inputs.parents==nil {break}
            parent,found:=core.get(inputs.parents,e)
            if !found || parent.entity==core.NONE {break}
            e=parent.entity
        }
    }
    rotation:=basis.rotation
    if inputs.transforms!=nil {
        if local,found:=core.get(inputs.transforms,rig);found {rotation*=local.rotation}
    }
    return linalg.normalize0(mm.quat_rotate(rotation,up))
}

// The most parents above a rig that grounding_up looks through for a character.
GROUNDING_DEPTH :: 16

grounding_apply :: proc(state:^Playing,cache:^Grounding_Runtime,inputs:Grounding_Inputs,dt:f32) -> bool {
    if state==nil || cache==nil || !finite(dt) || dt<0 {return false}
    problems:=inputs.problems
    if !grounding_prepare(cache,inputs.configs,problems) {return false}
    index:=core.entity_index(state.entity)
    if index>=len(cache.rows) || cache.rows[index]<=0 {return true}
    row:=int(cache.rows[index])-1
    record:=&cache.records[row]
    if record.rig!=state.entity {return true}
    config:=core.at(inputs.configs,row)
    record.blocked=0
    if !config.enabled {record.initialized=false;record.legs={};record.placements={};record.alignment={};record.previous={};record.targets={};record.rotations={};return true}
    ground:=inputs.ground
    if ground.probe==nil {return true}
    if !grounding_bind(cache,row,state,config,inputs.geometry if inputs.geometry!=0 else core.stamp(inputs.configs,row),problems) {return false}
    count:=int(config.count)
    if len(state.world)!=len(state.local) || len(state.world)==0 {grounding_inconsistent(problems,state.entity);return false}
    prepared:=cache.hierarchies[row]
    if prepared.first<0 || prepared.count!=len(state.parents) || prepared.first>len(cache.links) || prepared.count>len(cache.links)-prepared.first {grounding_inconsistent(problems,state.entity);return false}
    hierarchy:=lib.Pose_Hierarchy{state.parents[:],cache.links[prepared.first:prepared.first+prepared.count]}
    basis:=mm.TRANSFORM_IDENTITY
    if inputs.parents!=nil {
        if parent,ok:=core.get(inputs.parents,state.entity);ok && parent.entity!=core.NONE {
            basis,ok=core.world_of(inputs.transforms,inputs.parents,parent.entity)
            if !ok {
                core.report(problems,state.entity,"animation.rig_parent","the grounding of this rig cannot place it: its parent 0x%016x or one above it has no Transform; give them one",u64(parent.entity))
                return false
            }
        }
    }
    ignore:=ground_ignore(ground,inputs.parents,state.entity)
    root:=state.world[0]
    up:=grounding_up(inputs,state.entity,basis,config.up)

    velocity:mm.Vec3
    if record.initialized && dt>0 {velocity=(root.position-record.root_position)/dt}
    velocity-=up*linalg.dot(velocity,up)
    prediction:=velocity*config.prediction
    if !finite(linalg.length(prediction)) {return grounding_unsolved(problems,state.entity,"the prediction of where it goes, as it moved a distance that is not finite")}
    desired,animated,poles:[GROUNDING_LEGS]mm.Vec3
    rotations:[GROUNDING_LEGS]mm.Quat
    contacts:[GROUNDING_LEGS]lib.Surface_Contact
    supports:[GROUNDING_LEGS*3]lib.Surface_Support
    support_count:=0
    legs:[GROUNDING_LEGS]lib.Gait_Leg
    mask:=config.collision_mask
    for leg,i in config.legs[:count] {
        hip,knee,foot:=record.bones[i][0],record.bones[i][1],record.bones[i][2]
        _=hip
        animated[i]=state.world[foot].position
        rotations[i]=state.world[foot].rotation
        desired[i]=animated[i]
        poles[i]=state.world[knee].position+mm.quat_rotate(root.rotation,leg.pole_offset)
        probe:=animated[i]
        clearance:=leg.sole_height
        if config.mode==.Animated && leg.contact_bone!={} {probe=state.world[record.contact_bones[i]].position;clearance=leg.contact_offset}
        origin:=probe+up*config.trace_above
        if config.mode==.Procedural {origin+=prediction}
        hit,ok:=ground.probe(ground.user,origin,-up,config.trace_above+config.trace_below,0,ignore,mask)
        if ok && linalg.dot(hit.normal,up)>=config.minimum_ground_dot {
            contacts[i]={position=hit.point+hit.normal*clearance,normal=hit.normal,support=hit.support,support_transform=hit.support_transform,valid=true}
            if config.mode==.Animated && linalg.length(contacts[i].position-probe)>leg.max_distance {contacts[i]={}}
            grounding_support(ground,hit.support,supports[:],&support_count)
        }
        grounding_support(ground,record.legs[i].anchor.support,supports[:],&support_count)
        grounding_support(ground,record.legs[i].landing.support,supports[:],&support_count)
        if config.mode==.Animated {
            grounding_support(ground,record.placements[i].anchor.support,supports[:],&support_count)
            grounding_support(ground,record.previous[i].support,supports[:],&support_count)
        }
        strength:=leg.contact*config.global_contact
        if config.mode==.Animated {
            lift:=max(0,linalg.dot(probe-root.position,up)-clearance)
            previous:=record.previous[i]
            if previous.active {lib.surface_anchor_follow(&previous,supports[:support_count])}
            speed:=linalg.length(probe-previous.position)/dt if record.initialized && dt>0 else f32(0)
            if !contacts[i].valid || lift>leg.contact_height || speed>leg.plant_speed {strength=0}
            target,valid:=lib.foot_placement_update(&record.placements[i],probe-up*lift,contacts[i],supports[:support_count],strength,dt,{config.release_distance,config.replant_distance,config.blend_time})
            if !valid {return grounding_unsolved(problems,state.entity,"the placement of the foot",i)}
            alignment:=&record.alignment[i]
            if contacts[i].valid {
                turn,turned:=lib.look_at(mm.QUAT_IDENTITY,up,contacts[i].normal,leg.max_tilt)
                if !turned {return grounding_unsolved(problems,state.entity,"the tilt of the foot",i)}
                position:=contacts[i].position+up*lift
                position+=(target.position+up*lift-position)*target.weight
                position+=mm.quat_rotate(turn,animated[i]-probe)
                offset:=position-animated[i]
                descent:=min(0,linalg.dot(offset,up))
                offset-=up*descent*(1-target.weight)
                alpha:=dt/(config.blend_time+dt) if config.blend_time>0 && dt>0 else f32(1)
                if !record.initialized || linalg.dot(alignment.turn,alignment.turn)<.5 {alignment.offset,alignment.turn=offset,turn}
                else {
                    height:=linalg.dot(offset,up)
                    previous:=linalg.dot(alignment.offset,up)
                    alignment.offset=offset+up*(max(height,previous+(height-previous)*alpha)-height)
                    alignment.turn=mm.quat_slerp(alignment.turn,turn,alpha)
                }
            }
            goal:=leg.contact*config.global_contact if contacts[i].valid else 0
            blend:=min(dt/config.blend_time,1) if config.blend_time>0 else 1
            alignment.weight+=clamp(goal-alignment.weight,-blend,blend)
            turn:=alignment.turn if alignment.weight>0 else mm.QUAT_IDENTITY
            offset:=alignment.offset if alignment.weight>0 else mm.Vec3{}
            record.targets[i]={animated[i]+offset,mm.quat_rotate(turn,up),alignment.weight}
            record.rotations[i]=linalg.normalize0(turn*rotations[i])
            sample:=contacts[i]
            if !sample.valid {sample={normal=up,valid=true}}
            sample.position=probe
            if !lib.surface_anchor_set(&record.previous[i],sample) {return grounding_unsolved(problems,state.entity,"the anchor of the foot on its surface",i)}
        }
        legs[i]={leg.phase,leg.step_distance,leg.step_height,leg.step_duration,leg.max_distance,strength}
    }
    if config.mode==.Procedural {
        gait:=lib.Gait_Config{config.cycle_duration,config.swing_fraction,config.blend_time,int(config.max_swinging),up}
        if !lib.gait_update(gait,legs[:count],contacts[:count],supports[:support_count],desired[:count],&record.gait,record.legs[:count],dt,linalg.length(velocity)>0.001,record.targets[:count]) {return grounding_unsolved(problems,state.entity,"the gait")}
        for &target,i in record.targets[:count] {
            target.position=desired[i]+(target.position-desired[i])*target.weight
            target.weight=1 if target.weight>0 || (contacts[i].valid && legs[i].contact>0) else 0
        }
    }
    if config.weight>0 {
        for leg,i in config.legs[:count] {
            target:=&record.targets[i]
            if target.weight<=0 {
                if config.mode!=.Animated || leg.contact*config.global_contact<=0 {continue}
                sole:=mm.quat_rotate(rotations[i],linalg.normalize0(leg.foot_up))*leg.sole_height
                correction:=grounding_clearance(animated[i]-sole,{},up,config,inputs,ignore)
                if correction<=1e-5 {continue}
                target^={animated[i]+up*correction,up,leg.contact*config.global_contact}
                record.rotations[i]=rotations[i]
            }
            if config.mode==.Procedural {
                if !record.legs[i].swinging && record.legs[i].weight>0 {continue}
                target.position+=up*grounding_clearance(target.position,target.normal*leg.sole_height,up,config,inputs,ignore)
            } else {
                if record.contact_bones[i]!=record.bones[i][2] {
                    turn:=record.rotations[i]*conj(rotations[i])
                    probe:=target.position+mm.quat_rotate(turn,state.world[record.contact_bones[i]].position-animated[i])
                    target.position+=up*grounding_clearance(probe,target.normal*leg.contact_offset,up,config,inputs,ignore)
                }
                sole:=mm.quat_rotate(record.rotations[i],linalg.normalize0(leg.foot_up))*leg.sole_height
                target.position+=up*grounding_clearance(target.position-sole,{},up,config,inputs,ignore)
            }
        }
    }
    for &target in record.targets[:count] {target.weight*=config.weight}
    if config.weight<=0 {record.root_position=root.position;record.initialized=true;return true}
    skeleton:=playing_skeleton(state)
    body_weights:[GROUNDING_LEGS]f32
    if config.adjust_body && record.body>0 {
        body:=int(record.body)
        target:=state.world[body]
        ok:=true
        if config.mode==.Animated {
            offset:mm.Vec3
            resting:=record.targets
            for &foot,i in resting[:count] {
                foot.weight*=record.placements[i].weight
                if !record.placements[i].anchor.active {foot.weight=0}
                body_weights[i]=foot.weight
            }
            offset,ok=lib.pelvis_offset(animated[:count],resting[:count],up,config.max_drop,config.max_rise)
            target.position+=offset
        } else {
            resting:=record.targets
            for &foot,i in resting[:count] {
                foot.weight*=record.legs[i].weight
                if record.legs[i].swinging || !record.legs[i].anchor.active {foot.weight=0}
            }
            target,ok=lib.gait_body_target(target,resting[:count],up,config.body_height,config.max_drop,config.max_rise,config.max_tilt,config.weight)
        }
        if !ok {return grounding_unsolved(problems,state.entity,"the place of the body")}
        offset:=target.position-state.world[body].position
        turn:=target.rotation*conj(state.world[body].rotation)
        alpha:=dt/(config.blend_time+dt) if config.blend_time>0 && dt>0 else f32(1)
        if !record.initialized || linalg.dot(record.body_turn,record.body_turn)<0.5 {record.body_offset=offset;record.body_turn=turn}
        record.body_offset+=(offset-record.body_offset)*alpha
        record.body_turn=mm.quat_slerp(record.body_turn,turn,alpha)
        target.position=state.world[body].position+record.body_offset
        target.rotation=record.body_turn*state.world[body].rotation
        parent:=state.parents[body]
        local,valid:=mm.transform_relative(target,state.world[parent] if parent>=0 else basis)
        if !valid {return grounding_unsolved(problems,state.entity,"the place of the body")}
        state.local[body]=local
    }
    if !lib.pose_world(skeleton.parents,state.local[:],state.world[:],basis) {pose_problem(problems,state.entity);return false}
    if config.adjust_body && record.body>0 {
        body:=int(record.body)
        offset:=linalg.dot(record.body_offset,up)
        lower,upper:=-config.max_drop-offset,config.max_rise-offset
        for target,i in record.targets[:count] {
            weight:=body_weights[i] if config.mode==.Animated else target.weight
            if weight<=0 {continue}
            hip,knee,foot:=record.bones[i][0],record.bones[i][1],record.bones[i][2]
            ancestor:=hip
            for ancestor>body {ancestor=int(state.parents[ancestor])}
            if ancestor!=body {continue}
            length:=(linalg.length(state.world[knee].position-state.world[hip].position)+linalg.length(state.world[foot].position-state.world[knee].position))*.9999
            minimum,maximum,reachable:=lib.limb_height_range(state.world[hip].position,target.position,up,length)
            if !reachable {continue}
            lower=max(lower,minimum*weight);upper=min(upper,maximum*weight)
        }
        correction:=clamp(0,lower,upper) if lower<=upper else clamp(upper,-config.max_drop-offset,config.max_rise-offset)
        if abs(correction)>1e-6 {
            target:=state.world[body];target.position+=up*correction
            parent:=state.parents[body]
            local,valid:=mm.transform_relative(target,state.world[parent] if parent>=0 else basis)
            if !valid {return grounding_unsolved(problems,state.entity,"the height of the body")}
            state.local[body]=local;record.body_offset+=up*correction
            if !lib.pose_world_branch(hierarchy,state.local[:],state.world[:],body,basis) {pose_problem(problems,state.entity);return false}
        }
    }
    for leg,i in config.legs[:count] {
        target:=record.targets[i]
        if target.weight<=0 {continue}
        hip,knee,foot:=record.bones[i][0],record.bones[i][1],record.bones[i][2]
        contact_delta:=mm.Vec3{}
        if config.mode==.Animated {contact_delta=mm.quat_rotate(conj(state.world[foot].rotation),state.world[record.contact_bones[i]].position-state.world[foot].position)}
        if config.mode==.Animated {
            pole,valid:=lib.two_bone_pole_from_pose(state.world[hip],state.world[knee],state.world[foot],target.position)
            if !valid {return grounding_unsolved(problems,state.entity,"the pole of the knee",i)}
            poles[i]=pole+mm.quat_rotate(root.rotation,leg.pole_offset)
        }
        original,ok:=lib.two_bone_ik(state.world[hip],state.world[knee],state.world[foot],target.position,poles[i],target.weight)
        if !ok {return grounding_unsolved(problems,state.entity,"the IK",i)}
        if config.mode==.Procedural {
            replacement:lib.Surface_Contact
            if !original.reached && target.weight==1 && !record.legs[i].swinging && record.legs[i].anchor.active && contacts[i].valid {
                solved,valid:=lib.two_bone_ik(state.world[hip],state.world[knee],state.world[foot],contacts[i].position,poles[i],target.weight)
                if valid && solved.reached {
                    _,blocked:=grounding_limb_hit(ground,solved.root.position,solved.joint.position,solved.end.position,ignore,mask)
                    if !blocked {replacement=contacts[i];original=solved}
                    lower,upper:f32=0,1
                    for attempt in 0..<4 {
                        fraction:=(lower+upper)*.5
                        probe:=target.position+(contacts[i].position-target.position)*fraction
                        hit,found:=ground.probe(ground.user,probe+up*config.trace_above,-up,config.trace_above+config.trace_below,0,ignore,mask)
                        if found && linalg.dot(hit.normal,up)>=config.minimum_ground_dot {
                            position:=hit.point+hit.normal*leg.sole_height
                            candidate,valid:=lib.two_bone_ik(state.world[hip],state.world[knee],state.world[foot],position,poles[i],target.weight)
                            if valid && candidate.reached {
                                _,blocked:=grounding_limb_hit(ground,candidate.root.position,candidate.joint.position,candidate.end.position,ignore,mask)
                                if !blocked {
                                    replacement={position=position,normal=hit.normal,support=hit.support,support_transform=hit.support_transform,valid=true}
                                    original=candidate;upper=fraction;continue
                                }
                            }
                        }
                        lower=fraction
                    }
                }
            }
            hit,blocked:=grounding_limb_hit(ground,original.root.position,original.joint.position,original.end.position,ignore,mask)
            if blocked && linalg.dot(hit.normal,up)<config.minimum_ground_dot {
                length:=linalg.length(state.world[knee].position-state.world[hip].position)+linalg.length(state.world[foot].position-state.world[knee].position)
                pole:=state.world[hip].position+hit.normal*length
                solved,valid:=lib.two_bone_ik(state.world[hip],state.world[knee],state.world[foot],target.position,pole,target.weight)
                if valid && solved.reached {
                    _,intersects:=grounding_limb_hit(ground,solved.root.position,solved.joint.position,solved.end.position,ignore,mask)
                    if !intersects {poles[i]=pole;original=solved;blocked=false}
                }
            }
            if blocked && linalg.dot(hit.normal,up)>=config.minimum_ground_dot {
                position:=hit.point+hit.normal*leg.sole_height
                solved,valid:=lib.two_bone_ik(state.world[hip],state.world[knee],state.world[foot],position,poles[i],target.weight)
                if valid && solved.reached {
                    _,intersects:=grounding_limb_hit(ground,solved.root.position,solved.joint.position,solved.end.position,ignore,mask)
                    if !intersects {
                        replacement={position=position,normal=hit.normal,support=hit.support,support_transform=hit.support_transform,valid=true}
                        original=solved
                        blocked=false
                    }
                }
            }
            if replacement.valid {
                current:=&record.legs[i]
                if current.weight>0 && legs[i].contact>0 {
                    if !lib.surface_anchor_set(&current.anchor,replacement) {return grounding_unsolved(problems,state.entity,"the anchor of the foot on its surface",i)}
                    current.offset=replacement.position-desired[i]
                    current.swinging=false;current.elapsed=0;current.landing={}
                }
                record.targets[i].position,record.targets[i].normal=replacement.position,replacement.normal
                target=record.targets[i]
            }
            if blocked {record.blocked|=u16(1)<<u16(i)}
        }
        if !lib.pose_ik_apply(hierarchy,state.local[:],state.world[:],hip,knee,foot,original,basis) {return grounding_unsolved(problems,state.entity,"the IK",i)}
        if config.mode==.Procedural {
            rotation,ok:=lib.look_at(rotations[i],leg.foot_up,target.normal,leg.max_tilt,record.legs[i].weight)
            if !ok {return grounding_unsolved(problems,state.entity,"the tilt of the foot",i)}
            record.rotations[i]=rotation
        }
        rotation:=mm.quat_slerp(rotations[i],record.rotations[i],target.weight)
        if config.mode==.Animated && config.weight*leg.contact*config.global_contact==1 && (!original.reached || target.weight<1) {
            sole:=mm.quat_rotate(rotation,linalg.normalize0(leg.foot_up))*leg.sole_height
            contact:=mm.quat_rotate(rotation,contact_delta)
            for attempt in 0..<3 {
                position:=state.world[foot].position
                correction:=grounding_clearance(position-sole,{},up,config,inputs,ignore)
                if record.contact_bones[i]!=foot {correction=max(correction,grounding_clearance(position+contact,up*leg.contact_offset,up,config,inputs,ignore))}
                if correction<=1e-5 {break}
                goal:=position+up*correction
                pole,pole_valid:=lib.two_bone_pole_from_pose(state.world[hip],state.world[knee],state.world[foot],goal)
                if !pole_valid {return grounding_unsolved(problems,state.entity,"the pole of the knee",i)}
                pole+=mm.quat_rotate(root.rotation,leg.pole_offset)
                solved,valid:=lib.two_bone_ik(state.world[hip],state.world[knee],state.world[foot],goal,pole)
                if !valid {return grounding_unsolved(problems,state.entity,"the IK",i)}
                if !solved.reached {break}
                if !lib.pose_ik_apply(hierarchy,state.local[:],state.world[:],hip,knee,foot,solved,basis) {return grounding_unsolved(problems,state.entity,"the IK",i)}
                record.targets[i].position=goal
            }
        }
        state.local[foot].rotation=linalg.normalize0(conj(state.world[knee].rotation)*rotation)
        if !lib.pose_world_branch(hierarchy,state.local[:],state.world[:],foot,basis) {pose_problem(problems,state.entity);return false}
    }
    record.root_position=root.position
    record.initialized=true
    return true
}
