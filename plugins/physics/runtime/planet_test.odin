package physics

import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

@(private="file")
PLANET_RADIUS :: 20

// Through the world: a Character placed on the side of a planet with its up
// stands there, its Transform and its core.Vertical take that up, and a
// teleport with a rotation turns the up at once.
@(test)
a_character_of_the_world_stands_on_a_planet_with_the_up_of_its_place :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.fields=true
    planet:=core.create(&f.entities)
    core.add(&f.gravities,planet,volume.Gravity{pull=.Center,acceleration=9.81,radius=PLANET_RADIUS})
    core.add(&f.worlds,planet,core.World_Transform{transform=mm.TRANSFORM_IDENTITY})
    core.add(&f.transforms,planet,core.Transform{{},1,{1,1,1}})
    core.add(&f.colliders,planet,collider_sphere(PLANET_RADIUS))
    physics_test_settle(&f)
    side:=mm.quat_between([3]f32{0,1,0},[3]f32{1,0,0})
    walker:=core.create(&f.entities)
    core.add(&f.transforms,walker,core.Transform{{PLANET_RADIUS,0,0},side,{1,1,1}})
    core.add(&f.colliders,walker,collider_character())
    core.add(&f.characters,walker,character_default())
    vertical :: proc(f:^Physics_Test,verticals:^core.Table(core.Vertical),e:core.Entity) -> [3]f32 {
        physics_verticals(core.ref(&f.state),core.read(&f.characters),verticals)
        core.table_settle(verticals,&f.entities)
        return mm.quat_rotate(core.vertical_of(core.read(verticals),e),{0,1,0})
    }
    for _ in 0..<40 {physics_test_step(&f)}
    pose:=physics_test_pose(&f,walker)
    testing.expectf(t,linalg.length(pose.position-[3]f32{PLANET_RADIUS,0,0})<0.02,"stands at %v",pose.position)
    found,_:=core.get(&f.character_states,walker)
    testing.expect(t,found.standing)
    testing.expectf(t,linalg.length(mm.quat_rotate(pose.rotation,{0,1,0})-[3]f32{1,0,0})<1e-4,"its Transform turned %v",pose.rotation)
    up:=vertical(&f,&f.verticals,walker)
    testing.expectf(t,linalg.length(up-[3]f32{1,0,0})<1e-4,"its vertical %v",up)
    teleport(&f.requests,walker,{0,-PLANET_RADIUS,0},mm.quat_axis_angle({1,0,0},cmath.PI))
    physics_test_step(&f)
    up=vertical(&f,&f.verticals,walker)
    testing.expectf(t,linalg.length(up-[3]f32{0,-1,0})<1e-4,"the teleport turned it to %v",up)
    for _ in 0..<30 {physics_test_step(&f)}
    pose=physics_test_pose(&f,walker)
    testing.expectf(t,linalg.length(pose.position-[3]f32{0,-PLANET_RADIUS,0})<0.02,"stands underneath at %v",pose.position)
    found,_=core.get(&f.character_states,walker)
    testing.expect(t,found.standing)

}

// What a character leaves in its Character_State says how fast it goes, the vertical
// speed a game tells a stomp by.
@(test)
a_character_says_its_vertical_speed_in_its_state :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    faller:=core.create(&f.entities)
    core.add(&f.transforms,faller,core.Transform{{0,50,0},1,{1,1,1}})
    core.add(&f.colliders,faller,collider_character())
    core.add(&f.characters,faller,character_default())
    core.add(&f.moves,faller,Character_Move{value={launch={0,3,0}}})
    for _ in 0..<3 {physics_test_step(&f)}
    found,_:=core.get(&f.character_states,faller)
    testing.expectf(t,found.velocity.y>2,"goes up at %v",found.velocity)
}
