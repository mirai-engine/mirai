package mirai_anim

import "base:runtime"
import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

@(private="file")
pose_hierarchy_fixture :: proc() -> (parents:[12]i32,local:[12]math.Transform,basis:math.Transform) {
    parents={-1,0,0,1,2,1,3,2,5,4,6,8}
    for &pose,i in local {
        pose={{f32(i%3)*.11,-.2,f32(i%2)*.03},math.quat_axis_angle({0,1,0},f32(i)*.07),{1.1,.9,1.03}}
    }
    basis={{3,-1,2},math.quat_axis_angle({0,1,0},.43),{1.4,.8,-1.1}}
    return
}

@(test)
prepared_pose_branches_match_full_world_for_interleaved_children_and_nonuniform_trs :: proc(t:^testing.T) {
    parents,local,basis:=pose_hierarchy_fixture()
    links:[12]Pose_Link
    hierarchy,ready:=pose_hierarchy_prepare(parents[:],links[:])
    if !testing.expect(t,ready) {return}
    world,expected:[12]math.Transform
    testing.expect(t,pose_world(parents[:],local[:],world[:],basis))
    for bone in ([5]int{1,3,6,2,0}) {
        local[bone].position+={.03,.02,-.01}
        local[bone].rotation=math.quat_axis_angle({1,0,0},.12)*local[bone].rotation
        local[bone].scale*={.98,1.02,1.01}
        testing.expect(t,pose_world(parents[:],local[:],expected[:],basis))
        saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
        updated:=pose_world_branch(hierarchy,local[:],world[:],bone,basis)
        context=saved
        testing.expect(t,updated)
        testing.expect_value(t,world,expected)
    }
    socket,ok:=skeleton_socket(world[:],11,{{.3,.1,0},1,{1,1,1}})
    reference,valid:=skeleton_socket(expected[:],11,{{.3,.1,0},1,{1,1,1}})
    testing.expect(t,ok && valid && socket==reference)
}

@(test)
prepared_pose_hierarchies_reject_invalid_topology_buffers_values_and_cycles_without_allocations :: proc(t:^testing.T) {
    parents,local,basis:=pose_hierarchy_fixture()
    links:[12]Pose_Link
    hierarchy,ok:=pose_hierarchy_prepare(parents[:],links[:])
    if !testing.expect(t,ok) {return}
    saved_links:=links
    invalid_parents:=parents;invalid_parents[3]=3
    _,ready:=pose_hierarchy_prepare(invalid_parents[:],links[:])
    testing.expect(t,!ready && links==saved_links)
    _,ready=pose_hierarchy_prepare(parents[:],links[:11])
    testing.expect(t,!ready && links==saved_links)
    _,ready=pose_hierarchy_prepare(nil,nil);testing.expect(t,!ready)
    overlapping_links:[3]Pose_Link
    overlapping_parents:=(cast([^]i32)raw_data(overlapping_links[:]))[:3]
    copy(overlapping_parents,([]i32{-1,0,1}))
    before_overlap:=overlapping_links
    _,ready=pose_hierarchy_prepare(overlapping_parents,overlapping_links[:])
    testing.expect(t,!ready && overlapping_links==before_overlap)
    world:[12]math.Transform
    testing.expect(t,pose_world(parents[:],local[:],world[:],basis))
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    outcomes:[10]bool
    for variant in 0..<5 {
        broken:=links
        switch variant {
        case 0: broken[1].first_child=1
        case 1: broken[3].next_sibling=3
        case 2: broken[1].first_child=12
        case 3: broken[1].first_child=4
        case 4: broken[6].first_child=-2
        }
        outcomes[variant]=pose_world_branch({parents[:],broken[:]},local[:],world[:],1,basis)
    }
    outcomes[5]=pose_world_branch({},local[:],world[:],1,basis)
    outcomes[6]=pose_world_branch(hierarchy,local[:],world[:11],1,basis)
    outcomes[7]=pose_world_branch(hierarchy,local[:],world[:],12,basis)
    invalid:=local;invalid[3].position.x=f32(0h7fc00000)
    outcomes[8]=pose_world_branch(hierarchy,invalid[:],world[:],1,basis)
    overlapping:[13]math.Transform;copy(overlapping[:],local[:])
    outcomes[9]=pose_world_branch(hierarchy,overlapping[:12],overlapping[1:],1,basis)
    context=saved
    for outcome in outcomes {testing.expect(t,!outcome)}
}

@(test)
prepared_ik_results_match_full_recomposition_for_overlapping_chains_and_partial_weights :: proc(t:^testing.T) {
    parents,rest,basis:=pose_hierarchy_fixture()
    names:[12]u64;for &name,i in names {name=u64(i+1)}
    skeleton:=Skeleton{parents[:],names[:],rest[:]}
    links:[12]Pose_Link
    hierarchy,ok:=pose_hierarchy_prepare(parents[:],links[:])
    if !testing.expect(t,ok) {return}
    for weight in ([3]f32{0,.35,1}) {
        reference,prepared:=rest,rest
        reference_world,prepared_world:[12]math.Transform
        testing.expect(t,pose_world(parents[:],reference[:],reference_world[:],basis))
        prepared_world=reference_world
        for chain in ([3][3]int{{1,3,6},{3,6,10},{2,4,9}}) {
            root,joint,end:=chain[0],chain[1],chain[2]
            target:=reference_world[end].position+math.Vec3{.13,-.05,.07}
            pole:=reference_world[joint].position+math.Vec3{0,.4,.2}
            testing.expect(t,skeleton_ik(skeleton,reference[:],reference_world[:],root,joint,end,target,pole,weight,basis))
            solved,valid:=two_bone_ik(prepared_world[root],prepared_world[joint],prepared_world[end],target,pole,weight)
            testing.expect(t,valid)
            saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
            applied:=pose_ik_apply(hierarchy,prepared[:],prepared_world[:],root,joint,end,solved,basis)
            context=saved
            testing.expect(t,applied && prepared==reference && prepared_world==reference_world)
            rotation:=math.quat_axis_angle({1,0,0},.11)*reference_world[end].rotation
            reference[end].rotation=linalg.normalize0(conj(reference_world[joint].rotation)*rotation)
            prepared[end].rotation=linalg.normalize0(conj(prepared_world[joint].rotation)*rotation)
            testing.expect(t,pose_world(parents[:],reference[:],reference_world[:],basis))
            testing.expect(t,pose_world_branch(hierarchy,prepared[:],prepared_world[:],end,basis))
            testing.expect(t,prepared==reference && prepared_world==reference_world)
        }
    }
}
