package physics

import "core:fmt"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import scene "mirai:engine/scene"
import sim "plugins:physics/runtime/sim"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
reloading_a_scene_recreates_body_velocity_and_automatic_joint_frames :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"physics-reload")
    if folder=="" {return}
    file:=fmt.tprintf("%s/physics.scene",folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    authored:asset.Scene
    testing.expect_value(t,asset.scene_init(&authored,&types,asset.KIND_SCENE,{12,45}),asset.Error.None)
    defer asset.scene_destroy(&authored)
    _,added:=asset.scene_entity_add(&authored,1,0,"Driven body")
    testing.expect_value(t,added,asset.Error.None)
    pose:=core.Transform{{1,2,0},1,{1,1,1}}
    rigid:=RIGID_BODY_DYNAMIC;rigid.mass=1
    collider:=collider_box({.2,.2,.2})
    joint:=joint_sixdof(core.NONE);joint_drive_pose(&joint,{.5,.2,0},1,4,1,500,500)
    testing.expect_value(t,asset.scene_set(&authored,1,"Transform",&pose),asset.Error.None)
    testing.expect_value(t,asset.scene_set(&authored,1,"Rigid_Body",&rigid),asset.Error.None)
    testing.expect_value(t,asset.scene_set(&authored,1,"Collider",&collider),asset.Error.None)
    testing.expect_value(t,asset.scene_set(&authored,1,"Joint",&joint),asset.Error.None)
    testing.expect_value(t,asset.scene_save(&authored,file),asset.Error.None)
    source:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&source,file),asset.Error.None) {return}
    defer asset.asset_close(&source)
    f:Physics_Test;if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    w:=core.test_world_ref(&f.w)
    previous:core.Entity
    previous_body:sim.Body_Handle
    for _ in 0..<3 {
        // The rows of the scene go and the state of physics stays: it follows them.
        core.entities_clear(&f.entities)
        core.table_clear(&f.transforms);core.table_clear(&f.names);core.table_clear(&f.rigids);core.table_clear(&f.colliders)
        core.table_clear(&f.joints);core.table_clear(&f.joint_states);core.table_clear(&f.bodies)
        _,error:=scene.instantiate(w,&source,&types)
        core.world_settle(w)
        if !testing.expect_value(t,error,scene.Error.None) {return}
        e:=core.entity_at(&f.rigids,0)
        testing.expect(t,e!=previous && !core.alive(&f.entities,previous))
        testing.expect_value(t,physics_test_pose(&f,e),pose)
        physics_test_step(&f)
        body:=body_of(core.ref(&f.state),e)
        testing.expect(t,body!=previous_body && !sim.body_valid(&f.state.world,previous_body))
        testing.expect(t,linalg.length(physics_test_pose(&f,e).position-pose.position)<.05)
        for _ in 0..<180 {physics_test_step(&f)}
        testing.expect(t,linalg.length(physics_test_pose(&f,e).position-(pose.position+[3]f32{.5,.2,0}))<.01)
        set_velocity(&f.requests,e,{10,0,0},{0,2,0})
        physics_test_step(&f)
        apply_impulse(&f.requests,e,{100,0,0})
        previous,previous_body=e,body
    }
}

@(test)
scaled_chain_links_keep_their_adjacent_edge_anchors_together_after_launch :: proc(t:^testing.T) {
    f:Physics_Test;if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    links:[7]core.Entity
    rigid:=RIGID_BODY_DYNAMIC;rigid.mass=2;rigid.bullet=true
    for &link,index in links {
        link=core.create(&f.entities)
        core.add(&f.transforms,link,core.Transform{{f32(index)*.42-1.26,3,0},1,{.4,.4,.4}})
        core.add(&f.colliders,link,collider_box({.5,.5,.5}));core.add(&f.rigids,link,rigid)
        core.add(&f.joints,link,joint_spherical(links[index-1] if index>0 else core.NONE,{-.525,0,0}))
    }
    worst_anchor,worst_center:f32
    for tick in 0..<480 {
        if tick==240 {apply_impulse(&f.requests,links[len(links)-1],{0,10,15})}
        physics_test_step(&f)
        if tick<60 {continue}
        for index in 1..<len(links) {
            a,b:=physics_test_pose(&f,links[index-1]),physics_test_pose(&f,links[index])
            state,_:=core.get(&f.joint_states,links[index])
            testing.expect_value(t,state.error,Joint_Error.None)
            target:=a.position+mm.quat_rotate(a.rotation,state.target_anchor*a.scale)
            own:=b.position+mm.quat_rotate(b.rotation,mm.Vec3{-.525,0,0}*b.scale)
            worst_anchor=max(worst_anchor,linalg.length(own-target))
            worst_center=max(worst_center,linalg.length(a.position-b.position))
        }
    }
    testing.expectf(t,worst_anchor<.015,"anchor separation %v",worst_anchor)
    testing.expectf(t,worst_center<.45,"center separation %v",worst_center)
}
