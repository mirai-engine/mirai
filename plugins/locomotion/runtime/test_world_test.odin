package locomotion

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// A world with physics and locomotion, stepped as the loop steps them: locomotion_step, then physics.
@(private)
@(test_world)
Loco_World :: struct {
    using world:Test_World,
    using physics:phys.Test_Physics,
    loco_states:core.Table(Locomotion_State),
    inputs:core.Table(input.Move_Input),
    walks:core.Table(Walk),
    flights:core.Table(Fly),
    swims:core.Table(Swim),
    slides:core.Table(Slide),
    mantles:core.Table(Mantle),
    slide_states:core.Table(Slide_State),
    mantle_states:core.Table(Mantle_State),
    remotes:core.Table(core.Remote),
    paces:core.Table(core.Own_Pace),
    loco_requests:Locomotion_Requests,
    places:core.Places,
}

@(private)
Loco_Test :: struct {
    using w:Loco_World,
    using host:phys.Test_Physics_Host,
    e:core.Entity, // the walker the test drives
}

// The actions of a test world: input.Look_Action from 0, and Walk_Action after it.
@(private) TEST_WALK_BASE :: input.Action(len(input.Look_Action))
@(private) TEST_JUMP :: TEST_WALK_BASE+input.Action(Walk_Action.Jump)
@(private) TEST_SPRINT :: TEST_WALK_BASE+input.Action(Walk_Action.Sprint)
@(private) TEST_CROUCH :: TEST_WALK_BASE+input.Action(Walk_Action.Crouch)
@(private) JUMP :: input.Action_Mask(1)<<u64(TEST_JUMP)
@(private) SPRINT :: input.Action_Mask(1)<<u64(TEST_SPRINT)
@(private) CROUCH :: input.Action_Mask(1)<<u64(TEST_CROUCH)

// A walker with a Character and a Walk at position, on a floor at 0 with ground, under the gravity of the
// world.
@(private)
loco_test_init :: proc(t:^testing.T,f:^Loco_Test,position:[3]f32,ground:=true) -> bool {
    if !test_world_init(t,&f.w) {return false}
    f.settings={bodies=32,shapes=32,contacts=256,joints=4,characters=4}
    f.gravity={0,-9.81,0}
    if ground {loco_test_box(f,{50,1,50},{0,-1,0})}
    f.e=loco_test_walker(f,position)
    core.add(&f.inputs,f.e,input.Move_Input{})
    return true
}

@(private)
loco_test_destroy :: proc(f:^Loco_Test) {
    phys.test_host_destroy(&f.host)
    test_world_destroy(&f.w)
}

// A Character at position, with a Walk unless walks is false.
@(private)
loco_test_walker :: proc(f:^Loco_Test,position:[3]f32,rotation:=mm.QUAT_IDENTITY,walks:=true) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{position,rotation,{1,1,1}})
    core.add(&f.colliders,e,phys.collider_character())
    // It faces the look it is asked at once: what a test asks of its move is in the axes of that look.
    core.add(&f.characters,e,phys.character_default())
    walk:=WALK_DEFAULT
    walk.turn_speed=0
    if walks {core.add(&f.walks,e,walk)}
    return e
}

// A box of collision: static, or the body rigid gives it.
@(private)
loco_test_box :: proc(f:^Loco_Test,half,position:[3]f32,rotation:=mm.QUAT_IDENTITY,rigid:Maybe(phys.Rigid_Body)=nil,density:f32=1000) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{position,rotation,{1,1,1}})
    collider:=phys.collider_box(half)
    collider.density=density
    core.add(&f.colliders,e,collider)
    if body,has:=rigid.?;has {core.add(&f.rigids,e,body)}
    return e
}

// Ticks of the loop in which the game writes the same Move_Input to every walker that has one, move in
// the axes of the look yaw in the frame of its vertical; locomotion adds it to a walker on its first tick.
@(private)
loco_test_tick :: proc(f:^Loco_Test,move:[3]f32,ticks:=1,buttons:=input.Action_Mask(0),yaw:f32=0,pitch:f32=0,clock:=core.CLOCK_DEFAULT) {
    dt:=f32(1.0/60)
    for _ in 0..<ticks {
        test_world_settle(&f.w)
        for row in 0..<core.count(&f.inputs) {
            // What asks a velocity is an AI of the test, which wrote it.
            if core.at(&f.inputs,row).world_velocity {continue}
            frame:=mm.QUAT_IDENTITY
            if capsule,made:=phys.character_capsule(core.ref(&f.state),core.entity_at(&f.inputs,row));made {frame=capsule.up_frame}
            core.edit_at(&f.inputs,row)^=input.Move_Input{move=mm.quat_rotate(frame*mm.quat_axis_angle({0,1,0},yaw),move),look_yaw=yaw,look_pitch=pitch,buttons=buttons}
        }
        loco_test_move(f,dt,clock)
        phys.physics_places(&f.places,&f.requests,core.ref(&f.state),core.read(&f.rigids),core.read(&f.characters))
        clear(&f.places.queue.items)
        test_world_settle(&f.w)
        // The logs of a tick, as their readers are handed them.
        e:=&f.events
        clear(&e.contact_begin.items);clear(&e.contact_end.items);clear(&e.overlap_begin.items);clear(&e.overlap_end.items);clear(&e.sleep.items);clear(&e.wake.items);clear(&e.joint_break.items)
        phys.test_step(&f.physics,&f.host,dt)
        test_world_settle(&f.w)
    }
}

@(private)
loco_state :: proc(f:^Loco_Test,e:=core.NONE) -> Locomotion_State {
    state,_:=core.get(&f.loco_states,e if e!=core.NONE else f.e)
    return state
}

@(private)
loco_position :: proc(f:^Loco_Test,e:=core.NONE) -> [3]f32 {
    pose,_:=core.get(&f.transforms,e if e!=core.NONE else f.e)
    return pose.position
}

// What the last step left of the walker: its velocity, its ground, its height, its fluid.
@(private)
loco_found :: proc(f:^Loco_Test,e:=core.NONE) -> phys.Character_State {
    found,_:=core.get(&f.character_states,e if e!=core.NONE else f.e)
    return found
}

@(private)
loco_velocity :: proc(f:^Loco_Test,e:=core.NONE) -> [3]f32 {
    motion,_:=core.get(&f.bodies,e if e!=core.NONE else f.e)
    return motion.linear
}

@(private)
near :: proc(a,b,tolerance:f32) -> bool {return abs(a-b)<=tolerance}

@(private)
mantle_state :: proc(f:^Loco_Test) -> Mantle_State {
    state,_:=core.get(&f.mantle_states,f.e)
    return state
}

@(private)
loco_test_move :: proc(f:^Loco_Test,dt:f32,clock:core.Clock) {
    time:=core.Time{playing=true,dt=dt}
    actions:=input.Input_Of(Walk_Action){base=TEST_WALK_BASE}
    slide_step(core.read(&f.slides),&f.slide_states,core.read(&f.loco_states),core.read(&f.walks),core.read(&f.characters),core.read(&f.colliders),
        core.read(&f.character_states),core.read(&f.bodies),core.read(&f.inputs),&f.moves,&f.loco_requests,core.ref(&f.state),core.read(&f.paces),actions,time,clock)
    mantle_step(core.read(&f.mantles),&f.mantle_states,core.read(&f.loco_states),core.read(&f.walks),core.read(&f.characters),core.read(&f.colliders),
        core.read(&f.character_states),core.read(&f.inputs),core.read(&f.transforms),core.read(&f.parents),&f.moves,&f.loco_requests,core.ref(&f.state),core.read(&f.paces),actions,time,clock)
    test_world_settle(&f.w)
    locomotion_prepare(core.read(&f.characters),core.read(&f.colliders),&f.loco_states,&f.moves,&f.inputs,
        core.read(&f.walks),core.read(&f.flights),core.read(&f.swims),&f.loco_requests,time,&f.problems)
    test_world_settle(&f.w)
    locomotion_step(
        core.read(&f.characters),&f.loco_states,&f.moves,&f.inputs,core.read(&f.walks),core.read(&f.flights),core.read(&f.swims),
        core.read(&f.character_states),core.read(&f.bodies),core.read(&f.transforms),
        core.read(&f.parents),core.read(&f.remotes),core.ref(&f.state),core.ref(&f.places),core.read(&f.paces),actions,time,clock,&f.problems,
    )
}
