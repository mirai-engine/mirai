package anim

import "mirai:core"
import lib "mirai:std/anim"
import mm "mirai:std/math"

// Gives a rig that takes the pose of another (Pose_Source) the finished pose of that rig on the
// bones they share by name or path, paired once per bind, keeping its own animation on the bones
// only it has: a modular head of its own skeleton that follows a body. The retarget of clips onto
// another skeleton pairs the bones the same way (source_retarget).
@(private)
leader_follow :: proc(state:^Playing,playback:^Playback,inputs:Constraint_Inputs,transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent,$A),parent_world:mm.Transform) -> bool {
    problems:=inputs.problems
    leader:=constraint_playing(core.ref(playback),state.leader)
    posed:=leader!=nil && leader.finished==playback.frame
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
            core.report(problems,state.entity,"animation.follow_bones","this rig takes the pose of entity 0x%016x, and their skeletons share no bone name, so it keeps its own pose; take it from a rig whose skeleton has bones of the names of these (animation.asset.inspect lists them), or play the clips on this rig, which retargets them onto its skeleton",u64(state.leader))
            return false
        }
        state.follow_bound=bound
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
