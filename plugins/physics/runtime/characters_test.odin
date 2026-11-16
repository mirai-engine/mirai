package physics

import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import scene "mirai:engine/scene"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

// From 3 m up it lands on flat ground or on a ledge below whose top is 1.5 m up, when and as fast
// as predicted from the start and again in the middle of the fall; going across off a ledge it
// lands on the floor where its arc reaches it, not on the ledge below its feet; with no ground
// nothing is.
@(test)
a_falling_character_predicts_when_and_how_fast_it_lands_on_the_arc_it_follows :: proc(t:^testing.T) {
    Case :: struct {ground:bool,start:[3]f32,ledge,height,across:f32}
    cases:=[4]Case{
        {ground=true,start={0,3,0},height=3},
        {ground=true,start={0,3,0},ledge=1.5,height=1.5},
        {ground=true,start={.6,3.5,0},ledge=3,height=3.5,across=6},
        {start={0,3,0},height=3},
    }
    box :: proc(w:^sim.World,half,position:[3]f32) {
        desc:=sim.BODY_DESC_DEFAULT
        desc.type,desc.position=.Static,position
        shape:=sim.SHAPE_DESC_DEFAULT
        shape.geometry=sim.Box{half}
        sim.shape_create(w,sim.body_create(w,desc),shape)
    }
    for c in cases {
        w:sim.World
        desc:=sim.world_desc_default()
        desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.character_capacity=16,16,128,2
        desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=1,1,1,64
        if !testing.expect(t,sim.world_init(&w,desc)) {continue}
        defer sim.world_destroy(&w)
        if c.ground {box(&w,{50,1,50},{0,-1,0})}
        if c.ledge>0 {box(&w,{1,c.ledge/2,1},{0,c.ledge/2,0})}
        ch:=sim.character_create(&w,sim.CHARACTER_DESC_DEFAULT,c.start)
        sim.body_set_linear_velocity(&w,sim.character_body(&w,ch),{c.across,0,0})
        g:=-w.gravity.y
        time,speed,found:=landing_on_arc(&w,ch)
        if !c.ground {
            testing.expectf(t,!found,"with no ground below nothing lands, not in %.3f s",time)
            continue
        }
        expected:=cmath.sqrt(2*c.height/g)
        testing.expectf(t,found && abs(time-expected)<=.02 && abs(speed-g*expected)<=.2,"from %.1f m it lands in %.3f s at %.2f m/s, not %.3f s at %.2f m/s",c.height,expected,g*expected,time,speed)
        ticks:=0
        for ; ticks<240; ticks+=1 {
            if .Standing in sim.character_state(&w,ch).ground {break}
            sim.world_step(&w,1.0/60)
            if ticks==20 {
                left,_,_:=landing_on_arc(&w,ch)
                testing.expectf(t,abs(left-(expected-21.0/60))<=.03,"in the middle of the fall it lands in %.3f s, not %.3f s",expected-21.0/60,left)
            }
        }
        testing.expectf(t,abs(f32(ticks)/60-time)<=3.0/60,"it lands after %.3f s, as predicted %.3f s",f32(ticks)/60,time)
        at:=sim.character_position(&w,ch)
        testing.expectf(t,abs(at.x-(c.start.x+c.across*time))<=.2 && abs(at.y-(c.start.y-c.height))<=.05,"it lands at %v, where its arc reaches the ground",at)
    }
}

// The capsule of a Character is where its feet are, as tall as its Collider and with the step and slope
// of its Character, and its filter sees what it collides with but never its own body; an entity without
// a character made, or a simulation not ready, has none.
@(test)
the_capsule_of_a_character_is_where_it_stands_and_leaves_its_own_body_out :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    _,early:=character_capsule(core.ref(&f.state),core.NONE)
    testing.expect(t,!early,"no capsule before the simulation is ready")
    f.gravity={0,-9.81,0}
    floor:=physics_test_box(&f,{0,-1,0},{50,1,50})
    wall:=physics_test_box(&f,{0,1,-2},{2,1,0.25})
    walker:=core.create(&f.entities)
    core.add(&f.transforms,walker,core.Transform{{1,0,1},1,{1,1,1}})
    core.add(&f.colliders,walker,collider_character(0.4,2))
    config:=character_default()
    config.step_height,config.max_slope=0.45,0.6
    core.add(&f.characters,walker,config)
    for _ in 0..<20 {physics_test_step(&f)}
    capsule,ok:=character_capsule(core.ref(&f.state),walker)
    if !testing.expect(t,ok) {return}
    at:=physics_test_pose(&f,walker).position
    testing.expectf(t,linalg.length(capsule.feet-at)<1e-4,"its feet %v where it stands %v",capsule.feet,at)
    testing.expect_value(t,capsule.up_frame,mm.QUAT_IDENTITY)
    testing.expect(t,abs(capsule.radius-0.4)<1e-5 && abs(capsule.height-2)<1e-5 && capsule.step_height==0.45 && capsule.max_slope==f32(0.6))
    hit,met:=sweep(core.ref(&f.state),Sphere{0.1},capsule.feet+{0,1,0},1,{0,0,-1},10,filter=capsule.filter)
    testing.expectf(t,met && hit.entity==wall,"from inside its capsule the sweep meets the wall, not itself: %v",hit.entity)
    found,_:=raycast(core.ref(&f.state),capsule.feet+{0,1,0},{0,-1,0},5,filter=capsule.filter)
    testing.expect_value(t,found.entity,floor)
    for other in ([3]core.Entity{core.NONE,floor,core.Entity(max(u64))}) {
        _,has:=character_capsule(core.ref(&f.state),other)
        testing.expectf(t,!has,"%v has no capsule",other)
    }
}

// An impulse changes the velocity of a Character by itself over the mass of its body, also when that mass
// comes from the density of its capsule.
@(test)
an_impulse_moves_a_character_by_the_mass_of_its_body :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{0,5,0},1,{1,1,1}})
    core.add(&f.colliders,e,collider_character())
    config:=character_default()
    config.mass=0
    core.add(&f.characters,e,config)
    physics_test_step(&f)
    l:=link_find(&f.state,e)
    if !testing.expect(t,l!=nil && l.kind==.Character) {return}
    mass:=sim.character_desc(&f.state.world,l.character).mass
    testing.expect(t,mass>1)
    apply_impulse(&f.requests,e,{100,0,0})
    physics_test_step(&f)
    v:=sim.character_velocity(&f.state.world,l.character)
    testing.expectf(t,abs(v.x-100/mass)<0.02*100/mass,"an impulse of 100 N s on %v kg gives %v m/s",mass,v.x)
}

// A Character locked along Z walks on the plane where it was made; a place puts it on another plane, where
// it stays, and the lock taken away lets its move take it along Z again.
@(test)
a_place_moves_a_character_locked_along_z_to_another_plane_where_it_stays :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    physics_test_box(&f,{0,-1,0},{50,1,50})
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{0,0,0},1,{1,1,1}})
    core.add(&f.colliders,e,collider_character())
    config:=character_default()
    config.locks={.Linear_Z}
    core.add(&f.characters,e,config)
    core.add(&f.moves,e,Character_Move{value={ground={velocity={2,0,2},force=3200},air={velocity={2,0,2},force=800}}})
    for _ in 0..<30 {physics_test_step(&f)}
    at:=physics_test_pose(&f,e).position
    testing.expectf(t,abs(at.z)<1e-3 && at.x>0.5,"walked to %v",at)
    teleport(&f.requests,e,{at.x,0,3})
    for _ in 0..<60 {physics_test_step(&f)}
    after:=physics_test_pose(&f,e).position
    testing.expectf(t,abs(after.z-3)<1e-3 && after.x>at.x+1.5,"placed at z 3, it is at %v",after)
    core.edit(&f.characters,e).locks={}
    for _ in 0..<30 {physics_test_step(&f)}
    free:=physics_test_pose(&f,e).position
    testing.expectf(t,free.z>3.5,"without the lock it walks along Z again: %v",free)
}

// A character its section holds stands where it is, on and drawn, while gravity and its move would take it:
// its body is kinematic. A place moves it while it is held, and it stays there; let go, it falls.
@(test)
a_character_its_section_holds_stays_where_it_is_and_a_place_moves_it :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{0,5,0},1,{1,1,1}})
    core.add(&f.colliders,e,collider_character())
    core.add(&f.characters,e,character_default())
    core.add(&f.moves,e,Character_Move{value={ground={velocity={2,0,0},force=3200},air={velocity={2,0,0},force=800}}})
    step :: proc(f:^Physics_Test) {
        physics_test_settle(f)
        physics_section_holds(&f.state,core.read(&f.section_held),core.read(&f.rigids))
        physics_test_step(f)
    }
    step(&f)
    core.add(&f.section_held,e,scene.Section_Held{})
    step(&f)
    held:=physics_test_pose(&f,e).position
    for _ in 0..<30 {step(&f)}
    testing.expect_value(t,physics_test_pose(&f,e).position,held)
    testing.expect(t,!core.entity_off(&f.entities,e),"it stays on, drawn")
    teleport(&f.requests,e,{10,8,0})
    for _ in 0..<30 {step(&f)}
    testing.expect_value(t,physics_test_pose(&f,e).position,[3]f32{10,8,0})
    core.remove(&f.section_held,e)
    for _ in 0..<30 {step(&f)}
    testing.expectf(t,physics_test_pose(&f,e).position.y<7,"let go, it falls: %v",physics_test_pose(&f,e).position)
}
