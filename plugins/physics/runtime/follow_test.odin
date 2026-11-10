package physics

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import sim "plugins:physics/runtime/sim"

// A character a following pose target leads (a shown replica of the network)
// is where the target says after every step: its own move and a box in its
// way do not take it elsewhere.
@(test)
a_following_target_leads_a_character_where_it_says :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{0,1,0},1,{1,1,1}})
    core.add(&f.colliders,e,collider_character())
    core.add(&f.characters,e,character_default())
    // It walks to +X by its move, and a box stands on the way of the target.
    core.add(&f.moves,e,Character_Move{value={ground={velocity={5,0,0},force=1e4},air={velocity={5,0,0},force=1e4}}})
    physics_test_box(&f,{0.6,1,-1},{0.2,1,0.2},RIGID_BODY_DYNAMIC)
    core.add(&f.replicas,e,core.Pose_Target{follow=true,placed=1,position={0,1,0},rotation=1,scale={1,1,1}})
    physics_test_step(&f)
    for tick in 0..<60 {
        // The target goes to -Z at 1.5 m/s, through the box.
        goal:=[3]f32{0,1,-f32(tick+1)*1.5/60}
        core.add(&f.replicas,e,core.Pose_Target{follow=true,placed=1,position=goal,rotation=1,scale={1,1,1},linear={0,0,-1.5}})
        physics_test_settle(&f)
        physics_pose_targets(&f.state,core.read(&f.replicas),&f.transforms,core.read(&f.parents),core.read(&f.rigids),core.read(&f.characters))
        physics_test_step(&f)
        at:=physics_test_pose(&f,e).position
        if !testing.expectf(t,linalg.distance(at,goal)<1e-3,"tick %d: at %v and not at the target %v",tick,at,goal) {return}
    }
    l:=link_find(&f.state,e)
    testing.expect(t,l!=nil && linalg.distance(sim.body_linear_velocity(&f.state.world,sim.character_body(&f.state.world,l.character)),[3]f32{0,0,-1.5})<1e-3,"with the velocity of the target")

    // Without the target it walks by its move again.
    core.remove(&f.replicas,e)
    physics_test_settle(&f)
    physics_pose_targets(&f.state,core.read(&f.replicas),&f.transforms,core.read(&f.parents),core.read(&f.rigids),core.read(&f.characters))
    before:=physics_test_pose(&f,e).position
    for _ in 0..<10 {physics_test_step(&f)}
    testing.expect(t,physics_test_pose(&f,e).position.x>before.x+0.3,"it walks again")
}
