package physics

import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

// A character of the solver on a planet of radius 20 at the origin, driven by
// locomotion_move as locomotion_step drives one, in the frame of its vertical.
@(private="file")
Planet_Test :: struct {
    w:sim.World,
    ch:sim.Character_Handle,
    loco:Locomotion_State,
    body:Character,
    walk:Walk,
    planet:volume.Gravity,
    field:f32, // m from the center within which the planet pulls; beyond, the level pulls down
}

@(private="file")
PLANET_RADIUS :: 20

@(private="file")
planet_test_init :: proc(f:^Planet_Test,position:[3]f32,rotation:=mm.QUAT_IDENTITY) -> bool {
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.character_capacity=16,16,128,2
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=1,1,1,64
    if !sim.world_init(&f.w,desc) {return false}
    body:=sim.BODY_DESC_DEFAULT
    body.type=.Static
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Sphere{PLANET_RADIUS}
    sim.shape_create(&f.w,sim.body_create(&f.w,body),shape)
    f.body,f.walk=character_default(),WALK_DEFAULT
    f.planet=volume.Gravity{pull=.Center,acceleration=9.81,radius=PLANET_RADIUS}
    f.field=max(f32)
    f.ch=sim.character_create(&f.w,sim.CHARACTER_DESC_DEFAULT,position,rotation)
    return f.ch!={}
}

@(private="file")
planet_gravity :: proc(user:rawptr,point:[3]f32) -> [3]f32 {
    f:=(^Planet_Test)(user)
    if linalg.length(point)>f.field {return {0,-9.81,0}}
    return volume.gravity_of(f.planet,mm.TRANSFORM_IDENTITY,point)
}

@(private="file")
planet_tick :: proc(f:^Planet_Test,move:[3]f32,jump:=false) {
    sim.world_set_body_gravity(&f.w,{0,-9.81,0},planet_gravity,f)
    state:=sim.character_state(&f.w,f.ch)
    given:=input.Move_Input{move=move,buttons=jump?input.action_bit(TEST_JUMP):0}
    gravity:=sim.body_gravity(&f.w,sim.character_body(&f.w,f.ch))
    m:=locomotion_move(&f.loco,f.body,f.walk,{},nil,{},character_state_of(state),state.up_frame,given,TEST_JUMP,TEST_SPRINT,TEST_CROUCH,sim.character_velocity(&f.w,f.ch),gravity,1.0/60)
    sim.character_set_move(&f.w,f.ch,m)
    sim.world_step(&f.w,1.0/60)
}

@(private="file")
planet_up :: proc(f:^Planet_Test) -> [3]f32 {return sim.up_frame_up(sim.character_state(&f.w,f.ch).up_frame)}

// Height of the feet over the surface, and how far the up is from the one of the place.
@(private="file")
planet_place :: proc(f:^Planet_Test) -> (height,tilt:f32) {
    feet:=sim.character_position(&f.w,f.ch)
    height=linalg.length(feet)-PLANET_RADIUS
    tilt=cmath.acos(clamp(linalg.dot(planet_up(f),linalg.normalize(feet)),-1,1))
    return
}

// Angle walked from the top toward -Z, around +X: from -PI/2 to 3PI/2.
@(private="file")
planet_angle :: proc(f:^Planet_Test) -> f32 {
    feet:=sim.character_position(&f.w,f.ch)
    angle:=cmath.atan2(-feet.z,feet.y)
    return angle< -0.5*cmath.PI?angle+2*cmath.PI:angle
}

// Walks forward until the angle around the planet, checking that it stands
// on the surface with the up of its place.
@(private="file")
planet_walk_to :: proc(t:^testing.T,f:^Planet_Test,angle:f32) -> bool {
    for tick in 0..<2000 {
        if planet_angle(f)>=angle {return true}
        planet_tick(f,{0,0,-1})
        if tick<30 {continue}
        height,tilt:=planet_place(f)
        feet:=sim.character_position(&f.w,f.ch)
        if !testing.expectf(t,.Standing in sim.character_state(&f.w,f.ch).ground && abs(height)<0.02 && tilt<0.01 && abs(feet.x)<0.05,"walking at %v: height %v tilt %v",feet,height,tilt) {return false}
    }
    return testing.expectf(t,false,"it did not get around the planet: %v",sim.character_position(&f.w,f.ch))
}

// A jump in place goes along the up of the place to the height of the walk,
// a little more as the planet pulls less up there, and lands where it left,
// standing, the up always that of its place.
@(private="file")
planet_jump :: proc(t:^testing.T,f:^Planet_Test) -> bool {
    for _ in 0..<20 {planet_tick(f,{})}
    from:=sim.character_position(&f.w,f.ch)
    planet_tick(f,{},true)
    highest:f32
    for tick in 0..<240 {
        planet_tick(f,{})
        height,tilt:=planet_place(f)
        highest=max(highest,height)
        if !testing.expectf(t,tilt<0.01,"the up left the place in the air: %v",tilt) {return false}
        if tick>5 && .Standing in sim.character_state(&f.w,f.ch).ground {
            testing.expectf(t,abs(height)<0.02,"landed at %v",height)
            testing.expectf(t,linalg.length(sim.character_position(&f.w,f.ch)-from)<0.05,"landed away from %v",from)
            return testing.expectf(t,highest>1.2 && highest<1.35,"the jump reached %v",highest)
        }
    }
    return testing.expect(t,false,"it did not land")
}

@(test)
a_character_walks_around_a_planet_and_jumps_on_its_side_and_underside :: proc(t:^testing.T) {
    f:=new(Planet_Test)
    defer free(f)
    testing.expect(t,planet_test_init(f,{0,PLANET_RADIUS,0}))
    defer sim.world_destroy(&f.w)
    for _ in 0..<30 {planet_tick(f,{})}
    testing.expect(t,.Standing in sim.character_state(&f.w,f.ch).ground)
    if !planet_walk_to(t,f,0.5*cmath.PI) {return}
    side:=sim.character_position(&f.w,f.ch)
    testing.expectf(t,linalg.length(linalg.normalize(side)-[3]f32{0,0,-1})<0.03,"on the side at %v",side)
    if !planet_jump(t,f) {return}
    if !planet_walk_to(t,f,cmath.PI) {return}
    under:=sim.character_position(&f.w,f.ch)
    testing.expectf(t,linalg.length(linalg.normalize(under)-[3]f32{0,-1,0})<0.03,"underneath at %v",under)
    testing.expectf(t,linalg.length(planet_up(f)-[3]f32{0,-1,0})<0.03,"its up points down: %v",planet_up(f))
    if !planet_jump(t,f) {return}
    // Still the way it started: a yaw kept in the frame heads the same way along the ground.
    testing.expect_value(t,sim.character_move(&f.w,f.ch).yaw,f32(0))
    planet_walk_to(t,f,1.4*cmath.PI)
}

// Falling from the level, where things fall down, into the field of the planet,
// the up turns smoothly toward the center at up_speed and the character lands
// on the side of the planet.
@(test)
the_up_turns_smoothly_from_the_level_into_the_field_of_a_planet :: proc(t:^testing.T) {
    f:=new(Planet_Test)
    defer free(f)
    testing.expect(t,planet_test_init(f,{0,0,-30}))
    defer sim.world_destroy(&f.w)
    f.field=28
    sim.character_launch(&f.w,f.ch,{0,4,5})
    up:=planet_up(f)
    crossed:=false
    for _ in 0..<600 {
        planet_tick(f,{})
        next:=planet_up(f)
        turned:=cmath.acos(clamp(linalg.dot(up,next),-1,1))
        if !testing.expectf(t,turned<=sim.CHARACTER_DESC_DEFAULT.up_speed/60+1e-4,"the up jumped %v",turned) {return}
        if !crossed {
            crossed=linalg.length(sim.character_position(&f.w,f.ch))<f.field
            if !crossed {testing.expect_value(t,sim.character_state(&f.w,f.ch).up_frame,mm.QUAT_IDENTITY)}
        }
        up=next
        if crossed && .Standing in sim.character_state(&f.w,f.ch).ground {break}
    }
    height,tilt:=planet_place(f)
    testing.expectf(t,crossed && .Standing in sim.character_state(&f.w,f.ch).ground,"it did not land: %v",sim.character_position(&f.w,f.ch))
    testing.expectf(t,abs(height)<0.02 && tilt<0.02,"landed at height %v, tilt %v",height,tilt)
    testing.expectf(t,sim.character_position(&f.w,f.ch).z< -10,"on the side that faces where it came from: %v",sim.character_position(&f.w,f.ch))
}

// A snapshot taken while the up turns on the planet repeats every step after
// it bit for bit: the frame of the vertical is state of the simulation.
@(test)
a_restored_snapshot_repeats_a_walk_around_a_planet_exactly :: proc(t:^testing.T) {
    f:=new(Planet_Test)
    defer free(f)
    testing.expect(t,planet_test_init(f,{0,PLANET_RADIUS,0}))
    defer sim.world_destroy(&f.w)
    script :: proc(f:^Planet_Test,tick:int) {planet_tick(f,{0.3*f32(tick%50<25?1:-1),0,-1},tick%90==40)}
    for tick in 0..<200 {script(f,tick)}
    testing.expect(t,sim.character_state(&f.w,f.ch).up_frame!=mm.QUAT_IDENTITY)
    buffer:sim.World
    defer sim.world_destroy(&buffer)
    testing.expect(t,sim.world_kept_init(&buffer,&f.w,context.allocator))
    _,ok:=sim.world_state_copy(&buffer,&f.w)
    testing.expect(t,ok)
    loco:=f.loco
    Sample :: struct {feet:[3]f32,frame:mm.Quat,hash:u64}
    first:[150]Sample
    for &sample,i in first {
        script(f,200+i)
        sample={sim.character_position(&f.w,f.ch),sim.character_state(&f.w,f.ch).up_frame,sim.world_hash(&f.w)}
    }
    _,restored:=sim.world_state_copy(&f.w,&buffer)
    testing.expect(t,restored)
    f.loco=loco
    for sample,i in first {
        script(f,200+i)
        again:=Sample{sim.character_position(&f.w,f.ch),sim.character_state(&f.w,f.ch).up_frame,sim.world_hash(&f.w)}
        if again!=sample {
            testing.expectf(t,false,"diverged %v ticks after the restore",i)
            return
        }
    }
}

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
