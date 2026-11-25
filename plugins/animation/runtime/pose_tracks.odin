package anim

import "base:runtime"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import lib "mirai:std/anim"
import mm "mirai:std/math"

// By track of the library of a content, the binding it moves: made when the bindings of a state
// are built and shared by every state bound alike to that content.
Track_Map :: struct {
    content:base.Asset_Id,
    generation:u32,
    users:u32,             // states bound to it; 0: free
    targets:[dynamic]u64,  // of the bindings it was made for
    bones:[dynamic]i32,    // by track: its binding, -1 for a track that moves none
    twins:[dynamic][2]i32, // a binding with the target of an earlier one, and that one, whose blend it takes
}

// What one job blends the clips of a rig in, with room for the bindings of the largest.
Pose_Scratch :: struct {
    pose:[dynamic]mm.Transform,
    bones:[dynamic]lib.Bone_Blend,  // by binding
    references:[dynamic]i32,        // three a binding: its tracks of the reference clip of an additive layer
    rig_rotations:[dynamic]mm.Quat, // of a layer blended in the space of the rig: the base, the layer and the blend, by binding
}

// What the pose of a rig could not do in its job; animation_tick reports it.
Pose_Faults :: struct {
    program,mirror,memory:bool,
    layer_reference:u16, // a bit a slot of the stack
}

// An entity of a tick between its clocks, which run in order on the owner thread, and what
// follows its pose there; the pose in between runs in a job.
@(private)
Pose_Row :: struct {
    state:i32,   // in Playback.states
    rig:i32,     // in Playback.rigs; -1: an entity without skeleton
    content:i32, // in Playback.work_contents + 1; 0: it plays nothing
    programmed:bool,
    animation:Animation,
    dt,sought:f32,
    placed:mm.Transform,
    faults:Pose_Faults,
}

@(private)
Pose_Batch :: struct {playback:^Playback,transforms:^core.Table(core.Transform,.Read)}

@(private)
track_map_free :: proc(shared:^Track_Map) {
    delete(shared.targets);delete(shared.bones);delete(shared.twins)
    shared^={}
}

@(private)
tracks_release :: proc(playback:^Playback,state:^Playing) {
    at:=int(state.tracks)-1
    state.tracks=0
    if at<0 || at>=len(playback.track_maps) {return}
    shared:=&playback.track_maps[at]
    if shared.users>1 {shared.users-=1} else {track_map_free(shared)}
}

// Pairs the tracks of content with the bindings of state, on the map of another state bound alike
// when there is one, and leaves room to blend them. False when memory ran out: state is bound to
// no map. A state that binds again does it on the side and takes the map once the rest is ready.
@(private)
tracks_bind :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation) -> bool {
    tracks_release(playback,state)
    count:=len(state.bindings)
    if !pose_scratch_prepare(playback,max(len(playback.work.jobs),1),count) {return false}
    if content==nil {return true}
    library:=&content.lib
    track_count:=clamp(library.track_count,0,len(library.tracks))
    free:=-1
    for &known,i in playback.track_maps {
        if known.users==0 {if free<0 {free=i};continue}
        if known.content!=content.id || known.generation!=content.generation || len(known.bones)!=track_count || len(known.targets)!=count {continue}
        same:=true
        for binding,b in state.bindings {if known.targets[b]!=binding.target {same=false;break}}
        if !same {continue}
        known.users+=1;state.tracks=u32(i+1)
        return true
    }
    next:=Track_Map{content=content.id,generation=content.generation,users=1}
    keys:[dynamic]base.Sort_Key64
    defer delete(keys)
    if resize(&next.targets,count)!=nil || resize(&next.bones,track_count)!=nil || resize(&keys,count)!=nil {track_map_free(&next);return false}
    for binding,b in state.bindings {next.targets[b]=binding.target;keys[b]={key=binding.target,index=u32(b)}}
    slice.sort_by(keys[:],proc(a,b:base.Sort_Key64) -> bool {return a.key<b.key || a.key==b.key && a.index<b.index})
    first:=0
    for key,i in keys {
        if i==0 || keys[i-1].key!=key.key {first=i;continue}
        if append(&next.twins,[2]i32{i32(key.index),i32(keys[first].index)})!=1 {track_map_free(&next);return false}
    }
    for track,t in library.tracks[:track_count] {
        next.bones[t]=-1
        if track.slot!=0 || u8(track.property)>u8(lib.Property.Scale) {continue}
        low,high:=0,count
        for low<high {
            middle:=low+(high-low)/2
            if keys[middle].key<track.target {low=middle+1} else {high=middle}
        }
        if low<count && keys[low].key==track.target {next.bones[t]=i32(keys[low].index)}
    }
    if free<0 {
        if append(&playback.track_maps,Track_Map{})!=1 {track_map_free(&next);return false}
        free=len(playback.track_maps)-1
    }
    playback.track_maps[free]=next
    state.tracks=u32(free+1)
    return true
}

@(private)
pose_scratch_free :: proc(scratch:^Pose_Scratch) {
    delete(scratch.bones);delete(scratch.references);delete(scratch.rig_rotations);delete(scratch.pose)
    scratch^={}
}

// Room in the scratch of each of `workers` jobs for a rig of `bones` bindings and for every rig
// bound before. It allocates only when a rig with more bindings is bound or the jobs become more.
@(private)
pose_scratch_prepare :: proc(playback:^Playback,workers,bones:int) -> bool {
    playback.bones_peak=max(playback.bones_peak,bones)
    if len(playback.work.jobs)<workers && resize(&playback.work.jobs,workers)!=nil {return false}
    n:=playback.bones_peak
    for &scratch in playback.work.jobs {
        if len(scratch.bones)>=n {continue}
        if resize(&scratch.pose,3*n)!=nil || resize(&scratch.references,3*n)!=nil || resize(&scratch.rig_rotations,3*n)!=nil || resize(&scratch.bones,n)!=nil {return false}
    }
    return true
}

// The scratch of a job cleared for the bindings of state, and the map of its tracks. False for a
// state bound to no content or without room, which blends nothing.
@(private)
pose_room :: proc "contextless" (playback:^Playback,state:^Playing,worker:int) -> (scratch:^Pose_Scratch,bones:[]lib.Bone_Blend,shared:^Track_Map,ok:bool) {
    n:=len(state.bindings)
    at:=int(state.tracks)-1
    if worker<0 || worker>=len(playback.work.jobs) || at<0 || at>=len(playback.track_maps) {return}
    scratch=&playback.work.jobs[worker]
    shared=&playback.track_maps[at]
    if len(scratch.bones)<n || len(scratch.references)<3*n || len(scratch.rig_rotations)<3*n || len(shared.targets)!=n {return nil,nil,nil,false}
    bones=scratch.bones[:n]
    mem.zero_slice(bones)
    return scratch,bones,shared,true
}

// Gives each binding that shares its target with an earlier one what the tracks gave that one.
@(private)
tracks_twins :: #force_inline proc "contextless" (shared:^Track_Map,bones:[]lib.Bone_Blend) {
    for twin in shared.twins {bones[twin[0]]=bones[twin[1]]}
}

// A pose job takes no memory: what would allocate in it fails instead.
@(private)
pose_job_allocator_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    #partial switch mode {
    case .Alloc,.Alloc_Non_Zeroed,.Resize,.Resize_Non_Zeroed: return nil,.Out_Of_Memory
    case .Free,.Free_All: return nil,.None
    }
    return nil,.Mode_Not_Implemented
}

// The pose of one entity from the clocks its row left: it writes only its own state and the
// scratch of its job.
@(private)
pose_row :: proc(playback:^Playback,row:^Pose_Row,transforms:^core.Table(core.Transform,$A),worker:int) {
    if row.content==0 {return}
    state:=&playback.states[row.state]
    if state.lod.skip {return}
    content:=&playback.work.contents[row.content-1]
    row.faults=pose_compose(playback,state,content,row.animation,row.programmed,row.dt+state.waited,core.read(transforms),worker)
    if row.animation.mirror {
        if worker<0 || worker>=len(playback.work.jobs) ||
            !playing_mirror(state,playing_pose(state,.Local),playback.work.jobs[worker].pose[:]) {
            row.faults.mirror=true
        }
    }
}

// The pose and curves of the base and the stack of state, through the inertia of what its slots
// changed in the tick; dt: seconds since its last pose, the ticks it skipped (Rig_Lod) included.
@(private)
pose_compose :: proc(playback:^Playback,state:^Playing,content:^host.Content_Animation,animation:Animation,programmed:bool,dt:f32,transforms:^core.Table(core.Transform,.Read),worker:int) -> (faults:Pose_Faults) {
    dt:=dt if animation.playing else 0
    stack:=state.stack
    // What it showed in a tick that is not the one before (it was not posed since) is not blended
    // from, nor a blend kept from then.
    before:[]mm.Transform
    capture:=false
    if stack!=nil {
        inertia:=&stack.inertia
        if inertia.frame+1+u64(state.skipped)!=playback.frame {inertia.kept,inertia.state=0,{}}
        // A blend measures how the pose its slots changed to moves: that pose a tick before is the
        // base then under the layers where their clips were; after skipped ticks it is not known.
        _,_,before,_=inertia_poses(inertia)
        capture=stack.slots>0 && stack_blending(stack.blend) && inertia.kept>0 && dt>0 && state.skipped==0 && len(before)==len(playing_pose(state,.Local))
    }
    if programmed {
        runtime:=&state.program
        if !program_pose(playback,state,content,animation,&runtime.output,worker) {faults.program=true;return}
        capture=false
        if root:=runtime.root;runtime.has_root && root.in_place {
            if bone,reference,ok:=animation_root_reference(state,root,playing_pose(state,.Local),transforms);ok {playing_pose(state,.Local)[bone]=reference}
        }
        faults=pose_layers(playback,state,content,animation,playing_pose(state,.Local),transforms,worker)
        sample_layer_curves(state,content,animation)
    } else {
        if capture {
            copy(before,playing_pose(state,.Local))
            capture=pose_base(playback,state,content,animation,transforms,state.prev_fader,before,worker)
            if capture {pose_layers(playback,state,content,animation,before,transforms,worker,previous=true)}
        }
        faults=pose_sample(playback,state,content,animation,transforms,worker)
        sample_curves(state,content,animation.weight,animation)
    }
    if stack!=nil {
        stack_inertia_apply(state,dt,capture)
        stack.inertia.frame=playback.frame
    }
    return
}

// Whether a slot of the stack changed in the tick and asks a time to blend.
@(private)
stack_blending :: proc "contextless" (blend:Stack_Blend) -> bool {
    for duration in blend.durations {if duration>0 {return true}}
    return false
}

// The root motion of the stack of state through the blend of the slots that carry it: when a slot
// over the whole pose changes and the root moved by the clips in the tick before too, the
// difference of its velocity decays over the shortest time such a slot asks, without carrying its
// acceleration, which is noisy; a slot that cuts ends it. dt: 0 when it does not play.
@(private)
stack_root_inertia :: proc(state:^Playing,frame:u64,dt:f32) {
    stack:=state.stack
    if stack==nil || stack.slots==0 && !state.program.ready || !(dt>0) {return}
    root:=&stack.inertia.root
    velocity :: proc(delta:Root_Delta,dt:f32) -> [2]mm.Vec3 {
        turn:=delta.rotation;if real(turn)<0 {turn=-turn}
        return {delta.translation/dt,lib.quat_log(turn)/dt}
    }
    shortest:=max(0,state.program.transition)
    cut:=state.program.transition<0
    for i in 0..<int(stack.slots) {
        if stack.asked[i].over!={} {continue}
        if stack.blend.cuts&(u16(1)<<u16(i))!=0 {cut=true}
        if duration:=stack.blend.durations[i];duration>0 && (shortest==0 || duration<shortest) {shortest=duration}
    }
    if cut || !state.root_enabled {root.duration=0} else if shortest>0 && root.shown && root.frame+1==frame {
        now:=velocity(state.motion,dt)
        root.offset,root.duration,root.elapsed={root.velocity[0]-now[0],root.velocity[1]-now[1]},shortest,0
    }
    if root.elapsed<root.duration {
        root.elapsed+=dt
        share:=lib.inertial_remaining(root.elapsed,root.duration)*dt
        state.motion.translation+=root.offset[0]*share
        state.motion.rotation=linalg.normalize0(state.motion.rotation*lib.quat_exp(root.offset[1]*share))
        if state.body_motion.move!=.None {state.body_motion.translation+=root.offset[0]*share}
    }
    root.velocity,root.shown,root.frame=velocity(state.motion,dt),state.root_enabled,frame
}

@(private)
inertia_poses :: proc "contextless" (inertia:^Stack_Inertia) -> (shown,shown_before,before,older:[]mm.Transform) {
    n:=len(inertia.poses)/4
    shown,shown_before=inertia.poses[:n],inertia.poses[n:2*n]
    if inertia.flipped {shown,shown_before=shown_before,shown}
    return shown,shown_before,inertia.poses[2*n:3*n],inertia.poses[3*n:]
}

@(private)
inertia_curves :: proc "contextless" (inertia:^Stack_Inertia) -> (shown,shown_before:[]Curve_Output) {
    n:=len(inertia.history)/2
    shown,shown_before=inertia.history[:n],inertia.history[n:]
    if inertia.flipped {return shown_before,shown}
    return
}

// Room for the inertia of the stack of state, made on the owner thread before its pose: what it
// showed is forgotten when its bones or its curves change. A program (locomotion) blends its jumps
// by it too, so it makes the stack of a state that plays one. False when memory ran out.
@(private)
stack_inertia_prepare :: proc(state:^Playing) -> bool {
    stack:=state.stack
    if stack==nil {
        if !state.program.ready {return true}
        if stack=stack_make(state);stack==nil {return false}
    }
    inertia:=&stack.inertia
    if stack.slots==0 && !state.program.ready {inertia.kept,inertia.state=0,{};return true}
    n:=len(state.bindings);c:=len(state.curves)
    shown,_:=inertia_curves(inertia)
    same:=len(inertia.poses)==n*4 && len(shown)==c && inertia.bound==state.bound
    for curve,k in shown[:min(c,len(shown))] {same &&=curve_same(curve,state.curves[k])}
    if !same {inertia.kept,inertia.state=0,{}}
    inertia.bound=state.bound
    return program_array_resize(&inertia.poses,n*4) && program_array_resize(&inertia.history,c*2) &&
        program_array_resize(&inertia.bones,n) && program_array_resize(&inertia.curves,c*5) &&
        stack_scratch_prepare(state)
}

// The scratch of the stack of state sized for its bindings and curves: a copy of the world keeps
// its own, made for another state, so the owner thread sizes it before each pose.
@(private)
stack_scratch_prepare :: proc(state:^Playing) -> bool {
    scratch:=&state.stack.scratch
    n:=len(state.bindings);c:=len(state.curves)
    return program_array_resize(&scratch.curves,c*3) && program_array_resize(&scratch.values,c*15) &&
        program_array_resize(&scratch.durations,n)
}

// The pose and curves of the stack of state through its inertia, dt seconds after the tick it
// showed last: what its slots changed in this tick blends from that pose, with the velocity of the
// target from before (its pose a tick before) when there is one. Each bone blends over the shortest
// time of the slots that move it, the others over what their blend had left, the curves over the
// shortest of the tick; a slot that cuts takes off the offsets of what it moves. What it shows is
// kept for the next tick. A pose or curve that is not finite ends the blend.
@(private)
stack_inertia_apply :: proc(state:^Playing,dt:f32,previous_target:bool) {
    stack:=state.stack
    if stack==nil {return}
    inertia,scratch:=&stack.inertia,&stack.scratch;n:=len(playing_pose(state,.Local));c:=len(state.curves)
    if !state.program.ready && stack.slots==0 || len(inertia.poses)!=n*4 || len(inertia.bones)!=n || len(scratch.durations)!=n || len(inertia.history)!=c*2 || len(scratch.values)!=c*15 {return}
    shown,shown_before,before,older:=inertia_poses(inertia)
    curves,curves_before:=inertia_curves(inertia)
    blend:=stack.blend
    values:=scratch.values[:];old,now,target:=values[:c*5],values[c*5:c*10],values[c*10:]
    transition:=state.program.transition
    if transition<0 {inertia.state={};inertia.kept=0;mem.zero_slice(inertia.bones[:]);mem.zero_slice(inertia.curves[:])}
    if (transition>0 || blend.slots!=0) && inertia.kept>0 {
        if transition>0 || stack_blending(blend) {
            durations:=scratch.durations[:]
            for &duration in durations {duration=transition if transition>0 else -1}
            shortest:=transition if transition>0 else max(f32)
            for asked,i in blend.durations[:stack.slots] {
                if asked<=0 {continue}
                shortest=min(shortest,asked)
                if stack.asked[i].over=={} {for &duration in durations {duration=asked if duration<0 else min(duration,asked)}} else if len(stack.masks)>=(i+1)*n {
                    for share,b in stack.masks[i*n:][:n] {if share>0 {durations[b]=asked if durations[b]<0 else min(durations[b],asked)}}
                }
            }
            history:=inertia.kept>1
            curves_flatten(curves,now);curves_flatten(curves_before if history else curves,old);curves_flatten(state.curves[:],target)
            input:=lib.Inertial_Input{previous=shown_before if history else shown,current=shown,target=playing_pose(state,.Local),previous_curves=old,current_curves=now,target_curves=target,durations=durations,dt=inertia.dt if history else 0,duration=shortest}
            if previous_target {
                pose_extrapolate_back(before,playing_pose(state,.Local),older,input.dt/dt)
                input.target,input.target_previous=before,older
            }
            if !lib.inertial_capture(&inertia.state,inertia.bones[:],inertia.curves[:],input) {inertia.state={}}
            // A bone no clip moves, or a channel of it, stays where the pose puts it.
            for binding,b in state.bindings {
                bone:=&inertia.bones[b]
                if binding.target==0 {bone^={};continue}
                if .Position not_in binding.driven {bone.position,bone.speed.x={},0}
                if .Rotation not_in binding.driven {bone.rotation,bone.speed.y={},0}
                if .Scale not_in binding.driven {bone.scale,bone.speed.z={},0}
            }
        }
        for i in 0..<int(stack.slots) {
            if blend.cuts&(u16(1)<<u16(i))==0 {continue}
            if stack.asked[i].over=={} {mem.zero_slice(inertia.bones[:]);mem.zero_slice(inertia.curves[:]);break}
            if len(stack.masks)<(i+1)*n {continue}
            for share,b in stack.masks[i*n:][:n] {if share>0 {inertia.bones[b]={}}}
        }
    }
    if inertia.state.active {
        curves_flatten(state.curves[:],target)
        if !lib.inertial_advance(&inertia.state,dt) || !lib.inertial_pose_apply(inertia.state,inertia.bones[:],playing_pose(state,.Local),playing_pose(state,.Local)) || !lib.inertial_curves_apply(inertia.state,inertia.curves[:],target,target) {inertia.state={}} else {
            for &curve,k in state.curves {for &v,j in curve.value {v=target[k*5+j]};curve.weight=mm.saturate(target[k*5+4])}
        }
    }
    if dt>0 && inertia.kept>0 {
        inertia.flipped=!inertia.flipped
        shown,curves=shown_before,curves_before
        inertia.dt,inertia.kept=dt,2
    }
    copy(shown,playing_pose(state,.Local));copy(curves,state.curves[:])
    inertia.kept=max(inertia.kept,1)
}

// The values and weight of each curve, 5 a curve.
@(private)
curves_flatten :: proc "contextless" (curves:[]Curve_Output,out:[]f32) {
    for curve,k in curves {for v,j in curve.value {out[k*5+j]=v};out[k*5+4]=curve.weight}
}

// The pose a tick before the pose before, along the velocity from it to now; ratio: that tick over
// the one from before to now.
@(private)
pose_extrapolate_back :: proc "contextless" (before,now,out:[]mm.Transform,ratio:f32) {
    for value,b in before {
        old:=value
        old.position-=(now[b].position-value.position)*ratio;old.scale-=(now[b].scale-value.scale)*ratio
        delta:=mm.quat_inverse(value.rotation)*now[b].rotation;old.rotation=value.rotation*mm.quat_slerp(1,mm.quat_inverse(delta),ratio)
        out[b]=old
    }
}

@(private)
pose_rows :: proc(batch:^Pose_Batch,first,last:int,worker:int) {
    context.allocator={pose_job_allocator_proc,nil}
    for &row in batch.playback.work.rows[first:last] {pose_row(batch.playback,&row,batch.transforms,worker)}
}

// The poses of the rows of a tick, in jobs when they are more than a range holds: each row is
// independent, so the result does not depend on how they are split.
@(private)
pose_rows_run :: proc(playback:^Playback,transforms:^core.Table(core.Transform,$A),system:^jobs.Job_System,grain:int) {
    count:=len(playback.work.rows)
    if count==0 {return}
    batch:=Pose_Batch{playback,core.read(transforms)}
    // A copy of the world brings its states bound and leaves its work to it: the scratch of the
    // owner is sized here for them, once; a job without room reports it as a fault of memory.
    pose_scratch_prepare(playback,1,0)
    if system!=nil && grain>0 && count>grain && jobs.worker_count(system)>1 && pose_scratch_prepare(playback,jobs.worker_count(system),0) {
        jobs.parallel_for(system,jobs.OWNER,count,grain,pose_rows,&batch)
    } else {pose_rows(&batch,0,count,jobs.OWNER)}
}

@(private)
pose_faults_report :: proc(problems:^core.Problems,e:core.Entity,faults:Pose_Faults,actions:^Action_Runtime=nil) {
    if faults.memory {memory_problem(problems,e,"the blend of its clips")}
    for i in 0..<STACK_SLOTS {
        if faults.layer_reference&(u16(1)<<u16(i))!=0 {
            core.report(problems,e,"animation.layer_reference","layer '%s' of the .character of this entity adds its clip over a reference clip its animation does not have, so it plays nothing; give its reference_clip the name of one of its clips, or none to subtract the clip that plays",stack_slot_name(actions,e,i))
        }
    }
    if faults.mirror {
        core.report(problems,e,"animation.mirror","Animation.mirror is on, and this rig has no skeleton whose bones say their side (Left, Right, L_, _R...) to swap, so it plays unmirrored; turn mirror off, or name the bones of its skeleton by side")
    }
}
