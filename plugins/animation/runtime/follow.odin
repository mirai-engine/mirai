package anim

import "mirai:core"
import lib "mirai:std/anim"
import mm "mirai:std/math"

// Gives a rig that takes the pose of another (Pose_Source) that pose on the bones they share by
// name or path, paired once per bind: at stage Finished, the finished pose of that rig, keeping
// its own animation on the bones only it has; at stage Sampled, the sampled pose of that rig,
// carried across their rest poses with translations scaled to its bones, before its own
// modifiers. The bake of clips onto another skeleton pairs the bones the same way.
@(private)
leader_follow :: proc(state:^Playing,playback:^Playback,inputs:Constraint_Inputs,transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,$A),parent_world:mm.Transform) -> bool {
    problems:=inputs.problems
    leader:=constraint_playing(core.ref(playback),state.leader)
    posed:=leader!=nil && (leader.seen==playback.frame if state.stage==.Sampled else leader.finished==playback.frame)
    if leader==nil || leader==state || !posed || len(playing_pose(leader,.Local))==0 || leader.skeleton=={} {
        core.report(problems,state.entity,"animation.follow_rig","this rig takes the pose of entity 0x%016x through Pose_Source, which is not a rig posed before it in this tick (or takes it back), so it keeps its own pose; name a rig whose Mesh_Renderer shows a skinned mesh",u64(state.leader))
        return false
    }
    bound:=[2]u64{leader.bound,state.bound}
    if state.follow_bound!=bound || len(state.follow)!=len(playing_pose(state,.Local)) {
        if resize(&state.follow,len(playing_pose(state,.Local)))!=nil {memory_problem(problems,state.entity,"the pose it follows");state.follow_bound={};return false}
        shared,ok:=lib.follow_prepare(playing_skeleton(state),playing_skeleton(leader),playing_topology(state).aliases[:],playing_topology(leader).aliases[:],state.follow[:])
        state.follow_bound={}
        if !ok || shared==0 {
            core.report(problems,state.entity,"animation.follow_bones","this rig takes the pose of entity 0x%016x, and their skeletons share no bone name, so it keeps its own pose; take it from a rig whose skeleton has bones of the names of these (animation.asset.inspect lists them), or map them with Chain Retarget rows in its .character",u64(state.leader))
            return false
        }
        if state.stage==.Sampled && !follow_retarget_prepare(state,leader) {
            core.report(problems,state.entity,"animation.follow_pose","the sampled pose of entity 0x%016x cannot be carried onto this rig: a rest pose of either has a value that is not finite or a bone of zero length; check both skeletons",u64(state.leader))
            return false
        }
        state.follow_bound=bound
    }
    if state.stage==.Sampled {
        source:=playing_skeleton(leader);target:=playing_skeleton(state)
        source.rest,target.rest=state.retarget_rest[:len(playing_topology(leader).rest)],state.retarget_rest[len(playing_topology(leader).rest):]
        sampled:=state.retarget_world[len(playing_topology(leader).rest)+len(playing_topology(state).rest):]
        copy(sampled,playing_pose(leader,.Sampled));if follow_wrapped(leader) {sampled[0]=mm.TRANSFORM_IDENTITY}
        actor:=playing_pose(state,.Local)[0]
        ok:=lib.retarget_pose(source,target,state.retarget[:],sampled,state.retarget_world[:len(playing_topology(leader).rest)],state.retarget_world[len(playing_topology(leader).rest):][:len(playing_topology(state).rest)],playing_pose(state,.Local))
        if follow_wrapped(state) {playing_pose(state,.Local)[0]=actor}
        if !ok {core.report(problems,state.entity,"animation.follow_pose","the sampled pose of entity 0x%016x cannot be carried onto this rig: a value of it is not finite; check its animation (animation.analyze)",u64(state.leader))}
        return ok
    }
    // The finished pose of the leader in the world, once for all of its followers.
    if leader.world_final!=playback.frame || len(playing_pose(leader,.World))!=len(playing_pose(leader,.Local)) {
        leader_world:=mm.TRANSFORM_IDENTITY
        if parent,has:=core.get(parents,leader.entity);has && parent.entity!=core.NONE {
            placed,ok:=constraint_world(transforms,parents,inputs.worlds,parent.entity)
            if !ok {
                core.report(problems,state.entity,"animation.follow_rig","the rig this one follows (0x%016x) cannot be placed: one of its parents has no Transform; give them one",u64(state.leader))
                return false
            }
            leader_world=placed
        }
        if len(playing_pose(leader,.World))!=len(playing_pose(leader,.Local)) || !lib.pose_world(playing_topology(leader).parents[:],playing_pose(leader,.Local),playing_pose(leader,.World),leader_world) {
            core.report(problems,state.entity,"animation.follow_pose","the pose this rig follows could not be carried onto it: a value of it, of the rig it follows or of their places is not finite, or a scale is zero; check both poses (animation.analyze)")
            return false
        }
        leader.world_final=playback.frame
    }
    if !lib.follow_pose(playing_topology(state).parents[:],state.follow[:],playing_pose(leader,.Local),playing_pose(leader,.World),playing_pose(state,.Local),playing_pose(state,.World),parent_world) {
        core.report(problems,state.entity,"animation.follow_pose","the pose this rig follows could not be carried onto it: a value of it, of the rig it follows or of their places is not finite, or a scale is zero; check both poses (animation.analyze)")
        return false
    }
    return true
}

// A rig whose first bone is its entity rather than a bone of its skeleton: its rest is the
// identity in a retarget.
@(private)
follow_wrapped :: proc(state:^Playing) -> bool {return len(state.bindings)>0 && state.bindings[0].target==0 && playing_topology(state).parents[0]<0}

// The retarget of the sampled pose of leader onto state, by the bones follow paired.
@(private)
follow_retarget_prepare :: proc(state,leader:^Playing) -> bool {
    n,m:=len(playing_topology(state).rest),len(playing_topology(leader).rest)
    if resize(&state.retarget,n)!=nil || resize(&state.retarget_rest,m+n)!=nil || resize(&state.retarget_world,m+n+m)!=nil {return false}
    mapping:=make([]i32,n,context.temp_allocator)
    for bone,i in state.follow {mapping[i]=bone.leader}
    copy(state.retarget_rest[:m],playing_topology(leader).rest[:]);copy(state.retarget_rest[m:],playing_topology(state).rest[:])
    if follow_wrapped(leader) {state.retarget_rest[0]=mm.TRANSFORM_IDENTITY}
    if follow_wrapped(state) {state.retarget_rest[m]=mm.TRANSFORM_IDENTITY}
    source:=playing_skeleton(leader);target:=playing_skeleton(state)
    source.rest,target.rest=state.retarget_rest[:m],state.retarget_rest[m:]
    return lib.retarget_prepare(source,target,mapping,state.retarget_world[:m],state.retarget_world[m:][:n],state.retarget[:])
}
