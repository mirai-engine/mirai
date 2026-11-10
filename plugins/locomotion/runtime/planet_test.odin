package locomotion

import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

@(private="file")
PLANET_RADIUS :: 20

// A walker on a planet of radius 20 at the origin, whose Gravity pulls toward its center; within field
// m of it when field is not zero, and the world pulls down beyond.
@(private="file")
planet_test_init :: proc(t:^testing.T,f:^Loco_Test,position:[3]f32,field:f32=0) -> bool {
    if !loco_test_init(t,f,position,false) {return false}
    f.fields=true
    planet:=core.create(&f.entities)
    core.add(&f.gravities,planet,volume.Gravity{pull=.Center,acceleration=9.81,radius=PLANET_RADIUS})
    if field>0 {core.add(&f.volumes,planet,volume.sphere(field))}
    core.add(&f.worlds,planet,core.World_Transform{transform=mm.TRANSFORM_IDENTITY})
    core.add(&f.transforms,planet,core.Transform{{},1,{1,1,1}})
    core.add(&f.colliders,planet,phys.collider_sphere(PLANET_RADIUS))
    return true
}

@(private="file")
planet_tick :: proc(f:^Loco_Test,move:[3]f32,jump:=false) {loco_test_tick(f,move,1,JUMP if jump else 0)}

@(private="file")
planet_up :: proc(f:^Loco_Test) -> [3]f32 {
    capsule,_:=phys.character_capsule(core.ref(&f.state),f.e)
    return mm.quat_rotate(capsule.up_frame,{0,1,0})
}

// Height of the feet over the surface, and how far the up is from the one of the place.
@(private="file")
planet_place :: proc(f:^Loco_Test) -> (height,tilt:f32) {
    feet:=loco_position(f)
    height=linalg.length(feet)-PLANET_RADIUS
    tilt=cmath.acos(clamp(linalg.dot(planet_up(f),linalg.normalize(feet)),-1,1))
    return
}

// Angle walked from the top toward -Z, around +X: from -PI/2 to 3PI/2.
@(private="file")
planet_angle :: proc(f:^Loco_Test) -> f32 {
    feet:=loco_position(f)
    angle:=cmath.atan2(-feet.z,feet.y)
    return angle< -0.5*cmath.PI?angle+2*cmath.PI:angle
}

// Walks forward until the angle around the planet, checking that it stands
// on the surface with the up of its place.
@(private="file")
planet_walk_to :: proc(t:^testing.T,f:^Loco_Test,angle:f32) -> bool {
    for tick in 0..<2000 {
        if planet_angle(f)>=angle {return true}
        planet_tick(f,{0,0,-1})
        if tick<30 {continue}
        height,tilt:=planet_place(f)
        feet:=loco_position(f)
        if !testing.expectf(t,loco_found(f).standing && abs(height)<0.02 && tilt<0.01 && abs(feet.x)<0.05,"walking at %v: height %v tilt %v",feet,height,tilt) {return false}
    }
    return testing.expectf(t,false,"it did not get around the planet: %v",loco_position(f))
}

// A jump in place goes along the up of the place to the height of the walk,
// a little more as the planet pulls less up there, and lands where it left,
// standing, the up always that of its place.
@(private="file")
planet_jump :: proc(t:^testing.T,f:^Loco_Test) -> bool {
    for _ in 0..<20 {planet_tick(f,{})}
    from:=loco_position(f)
    planet_tick(f,{},true)
    highest:f32
    for tick in 0..<240 {
        planet_tick(f,{})
        height,tilt:=planet_place(f)
        highest=max(highest,height)
        if !testing.expectf(t,tilt<0.01,"the up left the place in the air: %v",tilt) {return false}
        if tick>5 && loco_found(f).standing {
            testing.expectf(t,abs(height)<0.02,"landed at %v",height)
            testing.expectf(t,linalg.length(loco_position(f)-from)<0.05,"landed away from %v",from)
            return testing.expectf(t,highest>1.2 && highest<1.35,"the jump reached %v",highest)
        }
    }
    return testing.expect(t,false,"it did not land")
}

@(test)
a_character_walks_around_a_planet_and_jumps_on_its_side_and_underside :: proc(t:^testing.T) {
    f:=new(Loco_Test)
    defer free(f)
    if !planet_test_init(t,f,{0,PLANET_RADIUS,0}) {return}
    defer loco_test_destroy(f)
    for _ in 0..<30 {planet_tick(f,{})}
    testing.expect(t,loco_found(f).standing)
    if !planet_walk_to(t,f,0.5*cmath.PI) {return}
    side:=loco_position(f)
    testing.expectf(t,linalg.length(linalg.normalize(side)-[3]f32{0,0,-1})<0.03,"on the side at %v",side)
    if !planet_jump(t,f) {return}
    if !planet_walk_to(t,f,cmath.PI) {return}
    under:=loco_position(f)
    testing.expectf(t,linalg.length(linalg.normalize(under)-[3]f32{0,-1,0})<0.03,"underneath at %v",under)
    testing.expectf(t,linalg.length(planet_up(f)-[3]f32{0,-1,0})<0.03,"its up points down: %v",planet_up(f))
    if !planet_jump(t,f) {return}
    // Still the way it started: a yaw kept in the frame heads the same way along the ground.
    move,_:=core.get(&f.moves,f.e)
    testing.expect_value(t,move.value.yaw,f32(0))
    planet_walk_to(t,f,1.4*cmath.PI)
}

// Falling from the level, where things fall down, into the field of the planet,
// the up turns smoothly toward the center at up_speed and the character lands
// on the side of the planet.
@(test)
the_up_turns_smoothly_from_the_level_into_the_field_of_a_planet :: proc(t:^testing.T) {
    f:=new(Loco_Test)
    defer free(f)
    if !planet_test_init(t,f,{0,0,-30},28) {return}
    defer loco_test_destroy(f)
    phys.apply_impulse(&f.requests,f.e,[3]f32{0,4,5}*phys.character_default().mass)
    planet_tick(f,{})
    up:=planet_up(f)
    crossed:=false
    for _ in 0..<600 {
        planet_tick(f,{})
        next:=planet_up(f)
        turned:=cmath.acos(clamp(linalg.dot(up,next),-1,1))
        if !testing.expectf(t,turned<=phys.character_default().up_speed/60+1e-4,"the up jumped %v",turned) {return}
        if !crossed {
            crossed=linalg.length(loco_position(f))<28
            if !crossed {testing.expectf(t,linalg.length(next-[3]f32{0,1,0})<1e-5,"up %v",next)}
        }
        up=next
        if crossed && loco_found(f).standing {break}
    }
    height,tilt:=planet_place(f)
    testing.expectf(t,crossed && loco_found(f).standing,"it did not land: %v",loco_position(f))
    testing.expectf(t,abs(height)<0.02 && tilt<0.02,"landed at height %v, tilt %v",height,tilt)
    testing.expectf(t,loco_position(f).z< -10,"on the side that faces where it came from: %v",loco_position(f))
}

// A copy of the world taken while the up turns on the planet repeats every step after it bit for bit:
// the frame of the vertical is state of the simulation, and what the locomotion carries is in its rows.
@(test)
a_copied_world_repeats_a_walk_around_a_planet_exactly :: proc(t:^testing.T) {
    f:=new(Loco_Test)
    defer free(f)
    if !planet_test_init(t,f,{0,PLANET_RADIUS,0}) {return}
    defer loco_test_destroy(f)
    script :: proc(f:^Loco_Test,tick:int) {planet_tick(f,{0.3*f32(tick%50<25?1:-1),0,-1},tick%90==40)}
    for tick in 0..<200 {script(f,tick)}
    testing.expect(t,linalg.length(planet_up(f)-[3]f32{0,1,0})>1e-3)
    buffer:=new(Loco_World)
    defer free(buffer)
    if !core.test_world_init(t,buffer,test_types) {return}
    defer core.test_world_destroy(buffer)
    testing.expect(t,core.test_world_copy(buffer,&f.w))
    Sample :: struct {feet,up:[3]f32,hash:u64}
    first:[150]Sample
    for &sample,i in first {
        script(f,200+i)
        sample={loco_position(f),planet_up(f),phys.state_hash(core.ref(&f.state))}
    }
    testing.expect(t,core.test_world_copy(&f.w,buffer))
    for sample,i in first {
        script(f,200+i)
        again:=Sample{loco_position(f),planet_up(f),phys.state_hash(core.ref(&f.state))}
        if again!=sample {
            testing.expectf(t,false,"diverged %v ticks after the copy",i)
            return
        }
    }
}
