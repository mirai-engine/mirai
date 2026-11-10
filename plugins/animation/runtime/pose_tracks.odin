package anim

import "base:runtime"
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
    bones:[dynamic]lib.Bone_Blend,  // by binding
    references:[dynamic]i32,        // three a binding: its tracks of the reference clip of an additive layer
    rig_rotations:[dynamic]mm.Quat, // of a layer blended in the space of the rig: the base, the layer and the blend, by binding
}

// What the pose of a rig could not do in its job; animation_tick reports it.
Pose_Faults :: struct {
    program,mirror,memory:bool,
    layer_bone,layer_reference:u16, // a bit a slot of the stack
}

// An entity of a tick between its clocks, which run in order on the owner thread, and what
// follows its pose there; the pose in between runs in a job.
@(private)
Pose_Row :: struct {
    state:i32,   // in Playback.states
    content:i32, // in Playback.work_contents + 1; 0: it plays nothing
    programmed:bool,
    animation:Animation,
    dt,current_dt,sought:f32,
    distance,action_distance:^Animation_Distance_Request,
    distance_error:Distance_Error,
    placed:mm.Transform,
    faults:Pose_Faults,
}

@(private)
Pose_Batch :: struct {playback:^Playback,transforms:core.Read(core.Transform)}

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
    if !pose_scratch_prepare(playback,max(len(playback.scratch),1),count) {return false}
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

// Room in the scratch of each of `workers` jobs for a rig of `bones` bindings and for every rig
// bound before. It allocates only when a rig with more bindings is bound or the jobs become more.
@(private)
pose_scratch_prepare :: proc(playback:^Playback,workers,bones:int) -> bool {
    playback.bones_peak=max(playback.bones_peak,bones)
    if len(playback.scratch)<workers && resize(&playback.scratch,workers)!=nil {return false}
    n:=playback.bones_peak
    for &scratch in playback.scratch {
        if len(scratch.bones)>=n {continue}
        if resize(&scratch.references,3*n)!=nil || resize(&scratch.rig_rotations,3*n)!=nil || resize(&scratch.bones,n)!=nil {return false}
    }
    return true
}

// The scratch of a job cleared for the bindings of state, and the map of its tracks. False for a
// state bound to no content or without room, which blends nothing.
@(private)
pose_room :: proc "contextless" (playback:^Playback,state:^Playing,worker:int) -> (scratch:^Pose_Scratch,bones:[]lib.Bone_Blend,shared:^Track_Map,ok:bool) {
    n:=len(state.bindings)
    at:=int(state.tracks)-1
    if worker<0 || worker>=len(playback.scratch) || at<0 || at>=len(playback.track_maps) {return}
    scratch=&playback.scratch[worker]
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
pose_row :: proc(playback:^Playback,row:^Pose_Row,transforms:core.Read(core.Transform),worker:int) {
    if row.content==0 {return}
    state:=&playback.states[row.state]
    content:=&playback.work_contents[row.content-1]
    if row.programmed {
        if !program_pose(playback,state,content,row.animation,&state.program.output,worker) {row.faults.program=true;return}
        if root:=state.program.root;state.program.has_root && root.in_place {if bone,reference,ok:=animation_root_reference(state,root,state.local[:],transforms);ok {state.local[bone]=reference}}
        row.faults=pose_layers(playback,state,content,row.animation,transforms,worker)
        sample_layer_curves(state,content,row.animation)
    } else {
        row.faults=pose_sample(playback,state,content,row.animation,transforms,worker)
        sample_curves(state,content,row.animation.weight,row.animation)
    }
    if row.animation.mirror && !playing_mirror(state,state.local[:]) {row.faults.mirror=true}
}

@(private)
pose_rows :: proc(batch:^Pose_Batch,first,last:int,worker:int) {
    context.allocator={pose_job_allocator_proc,nil}
    for &row in batch.playback.work[first:last] {pose_row(batch.playback,&row,batch.transforms,worker)}
}

// The poses of the rows of a tick, in jobs when they are more than a range holds: each row is
// independent, so the result does not depend on how they are split.
@(private)
pose_rows_run :: proc(playback:^Playback,transforms:core.Read(core.Transform),system:^jobs.Job_System,grain:int) {
    count:=len(playback.work)
    if count==0 {return}
    batch:=Pose_Batch{playback,transforms}
    if system!=nil && grain>0 && count>grain && jobs.worker_count(system)>1 && pose_scratch_prepare(playback,jobs.worker_count(system),0) {
        jobs.parallel_for(system,jobs.OWNER,count,grain,pose_rows,&batch)
    } else {pose_rows(&batch,0,count,jobs.OWNER)}
}

@(private)
pose_faults_report :: proc(problems:^core.Problems,e:core.Entity,faults:Pose_Faults,actions:^Action_Runtime=nil) {
    if faults.memory {memory_problem(problems,e,"the blend of its clips")}
    for i in 0..<STACK_SLOTS {
        if faults.layer_bone&(u16(1)<<u16(i))!=0 {
            core.report(problems,e,"animation.layer_bone","layer '%s' of the .character of this entity plays over a bone, or a part or region of the body, that this rig does not have, so it plays nothing; give its over one of its bones, a part or region of its body (@upper_body), or none",stack_slot_name(actions,e,i))
        }
        if faults.layer_reference&(u16(1)<<u16(i))!=0 {
            core.report(problems,e,"animation.layer_reference","layer '%s' of the .character of this entity adds its clip over a reference clip its animation does not have, so it plays nothing; give its reference_clip the name of one of its clips, or none to subtract the clip that plays",stack_slot_name(actions,e,i))
        }
    }
    if faults.mirror {
        core.report(problems,e,"animation.mirror","Animation.mirror is on, and this rig has no skeleton whose bones say their side (Left, Right, L_, _R...) to swap, so it plays unmirrored; turn mirror off, or name the bones of its skeleton by side")
    }
}
