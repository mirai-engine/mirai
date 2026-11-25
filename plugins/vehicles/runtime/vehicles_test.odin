package vehicles

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// A world with physics and vehicles, stepped as the loop steps them.
@(private)
@(test_world)
Vehicle_World :: struct {
    using world:Test_World,
    using physics:phys.Test_Physics,
    vehicles:core.Table(Vehicle),
    controls:core.Table(Vehicle_Controls),
    thrusters:core.Table(Thruster),
    aims:core.Table(Aim),
    inputs:core.Table(inp.Move_Input),
    remotes:core.Table(core.Remote),
    seat_state:inp.Seats,
}

@(private)
Vehicle_Test :: struct {
    using w:Vehicle_World,
    using host:phys.Test_Physics_Host,
}

@(private)
vehicle_test_init :: proc(t:^testing.T,f:^Vehicle_Test,gravity:[3]f32={}) -> bool {
    if !test_world_init(t,&f.w) {return false}
    f.settings={bodies=16,shapes=32,contacts=128,joints=4,characters=2}
    f.gravity=gravity
    return true
}

@(private)
vehicle_test_destroy :: proc(f:^Vehicle_Test) {
    phys.test_host_destroy(&f.host)
    test_world_destroy(&f.w)
}

// A tick of the loop: the vehicles push, then physics steps.
@(private)
vehicle_test_tick :: proc(f:^Vehicle_Test,dt:f32=1.0/60) {
    test_world_settle(&f.w)
    view:=Vehicle_View{core.ref(&f.state),core.read(&f.inputs),core.read(&f.transforms),core.read(&f.parents),core.read(&f.verticals),core.read(&f.remotes)}
    vehicles_simulate(core.read(&f.vehicles),&f.controls,core.read(&f.thrusters),&f.aims,view,&f.requests,{dt=dt,playing=true},&f.host.problems)
    test_world_settle(&f.w)
    phys.test_step(&f.physics,&f.host,dt)
    test_world_settle(&f.w)
}

// A hull of 4 by 1 by 1 m, as heavy as the water it displaces, with a thruster at its stern.
@(private)
vehicle_test_hull :: proc(f:^Vehicle_Test,position:[3]f32,thruster:Thruster,vehicle:=VEHICLE_DEFAULT,drag:f32=0.02) -> (hull,stern:core.Entity) {
    hull=core.create(&f.entities)
    core.add(&f.transforms,hull,core.Transform{position,1,{1,1,1}})
    collider:=phys.collider_box({0.5,0.5,2})
    collider.drag=drag
    core.add(&f.colliders,hull,collider)
    rigid:=phys.RIGID_BODY_DYNAMIC
    rigid.mass=4000
    core.add(&f.rigids,hull,rigid)
    core.add(&f.vehicles,hull,vehicle)
    core.add(&f.inputs,hull,inp.Move_Input{frame=.Body})
    stern=core.create(&f.entities)
    core.add(&f.transforms,stern,core.Transform{{0,0,2},1,{1,1,1}})
    core.add(&f.parents,stern,core.Parent{entity=hull})
    core.add(&f.thrusters,stern,thruster)
    return
}

@(private)
vehicle_test_sea :: proc(f:^Vehicle_Test) {
    sea:=core.create(&f.entities)
    core.add(&f.fluids,sea,phys.Fluid{density=1000})
    core.add(&f.volumes,sea,volume.plane())
    core.add(&f.transforms,sea,core.TRANSFORM_IDENTITY)
}

@(private)
vehicle_test_ask :: proc(f:^Vehicle_Test,hull:core.Entity,move:[3]f32) {
    test_world_settle(&f.w)
    core.edit(&f.inputs,hull).move=move
}

// A submarine as heavy as the water it displaces, 5 m down, at full throttle:
// its propeller brings it to its top speed, within 2%, and it stays at its depth.
@(test)
a_submarine_reaches_the_top_speed_of_its_thruster_and_holds_its_depth :: proc(t:^testing.T) {
    f:Vehicle_Test
    if !vehicle_test_init(t,&f,{0,-9.81,0}) {return}
    defer vehicle_test_destroy(&f)
    vehicle_test_sea(&f)
    hull,_:=vehicle_test_hull(&f,{0,-5,0},Thruster{force=100000,top_speed=11,medium=.Fluid})
    vehicle_test_tick(&f)
    vehicle_test_ask(&f,hull,{0,0,-1})
    for _ in 0..<6*60 {vehicle_test_tick(&f)}
    motion,_:=core.get(&f.bodies,hull)
    speed:=-motion.linear.z
    testing.expectf(t,abs(speed-11)<=0.02*11,"it goes at %v m/s",speed)
    pose,_:=core.get(&f.transforms,hull)
    testing.expectf(t,abs(pose.position.y+5)<0.1 && abs(pose.position.x)<0.1,"it stays 5 m down on its course: %v",pose.position)
    testing.expectf(t,f.host.problems.count==0,"%d problems",f.host.problems.count)
}

// Out of the water a propeller pushes nothing; a jet does.
@(test)
a_propeller_out_of_the_water_gives_no_force :: proc(t:^testing.T) {
    f:Vehicle_Test
    if !vehicle_test_init(t,&f) {return}
    defer vehicle_test_destroy(&f)
    vehicle_test_sea(&f)
    propeller,_:=vehicle_test_hull(&f,{0,5,0},Thruster{force=10000,top_speed=10,medium=.Fluid})
    jet,_:=vehicle_test_hull(&f,{10,5,0},Thruster{force=10000,top_speed=10,medium=.Any})
    vehicle_test_tick(&f)
    vehicle_test_ask(&f,propeller,{0,0,-1})
    vehicle_test_ask(&f,jet,{0,0,-1})
    for _ in 0..<60 {vehicle_test_tick(&f)}
    dry,_:=core.get(&f.bodies,propeller)
    flying,_:=core.get(&f.bodies,jet)
    testing.expectf(t,linalg.length(dry.linear)<1e-4,"the propeller moved it at %v",dry.linear)
    testing.expectf(t,flying.linear.z< -1,"the jet moves it at %v",flying.linear)
}

// A turret: a yaw ring that turns within a quarter of a turn either side, a
// barrel that tilts up to 0.5 rad under it, both at their speeds, toward a
// look behind and high: they stop at their limits, and get there no faster
// than they turn.
@(test)
an_aim_turns_toward_the_look_within_its_speed_and_limits :: proc(t:^testing.T) {
    f:Vehicle_Test
    if !vehicle_test_init(t,&f) {return}
    defer vehicle_test_destroy(&f)
    base,ring,barrel:=core.create(&f.entities),core.create(&f.entities),core.create(&f.entities)
    core.add(&f.transforms,base,core.Transform{{0,0,0},mm.quat_axis_angle({0,1,0},0.3),{1,1,1}})
    core.add(&f.inputs,base,inp.Move_Input{look_yaw=math.PI,look_pitch=1,frame=.Body})
    core.add(&f.transforms,ring,core.TRANSFORM_IDENTITY)
    core.add(&f.parents,ring,core.Parent{entity=base})
    core.add(&f.aims,ring,Aim{axis=.Yaw,speed=1,min=-math.PI/2,max=math.PI/2})
    core.add(&f.transforms,barrel,core.TRANSFORM_IDENTITY)
    core.add(&f.parents,barrel,core.Parent{entity=ring})
    core.add(&f.aims,barrel,Aim{axis=.Pitch,speed=0.5,min=-0.1,max=0.5})
    vehicle_test_tick(&f)
    first,_:=core.get(&f.aims,ring)
    testing.expectf(t,abs(first.angle-1.0/60)<1e-5,"a tick turns it as far as its speed: %v",first.angle)
    for _ in 0..<4*60 {vehicle_test_tick(&f)}
    yaw,_:=core.get(&f.aims,ring)
    pitch,_:=core.get(&f.aims,barrel)
    testing.expectf(t,abs(yaw.angle-math.PI/2)<1e-5,"the ring stops at its limit: %v",yaw.angle)
    testing.expectf(t,abs(pitch.angle-0.5)<1e-5,"the barrel stops at its limit: %v",pitch.angle)
    // Within its limits it points where the body looks.
    core.edit(&f.inputs,base).look_yaw=0.8
    core.edit(&f.inputs,base).look_pitch=0.2
    for _ in 0..<4*60 {vehicle_test_tick(&f)}
    yaw,_=core.get(&f.aims,ring)
    pitch,_=core.get(&f.aims,barrel)
    testing.expectf(t,abs(yaw.angle-0.5)<1e-3 && abs(pitch.angle-0.2)<1e-3,"it points at the look: yaw %v pitch %v",yaw.angle,pitch.angle)
    vehicles_show(core.read(&f.aims),&f.transforms)
    test_world_settle(&f.w)
    shown,_:=core.get(&f.transforms,barrel)
    testing.expectf(t,linalg.length(mm.quat_forward(shown.rotation)-mm.quat_forward(mm.quat_axis_angle({1,0,0},0.2)))<1e-3,"its Transform shows it: %v",shown.rotation)
}

// An AI writes the Move_Input of a boat no seat drives toward a point: it gets there.
@(test)
an_ai_input_takes_a_boat_to_a_point :: proc(t:^testing.T) {
    f:Vehicle_Test
    if !vehicle_test_init(t,&f) {return}
    defer vehicle_test_destroy(&f)
    vehicle:=VEHICLE_DEFAULT
    vehicle.turn_speed=1.2
    hull,_:=vehicle_test_hull(&f,{0,0,0},Thruster{force=8000,top_speed=6},vehicle)
    test_world_settle(&f.w)
    core.edit(&f.rigids,hull).linear_damping=0.3
    point:=[3]f32{30,0,-20}
    reached:=-1
    for tick in 0..<40*60 {
        test_world_settle(&f.w)
        pose,_:=core.get(&f.transforms,hull)
        if linalg.length(pose.position.xz-point.xz)<3 {
            reached=tick
            break
        }
        inp.move_set(&f.inputs,core.ref(&f.seat_state),hull,move_toward({pose.position,pose.rotation,{1,1,1}},point))
        vehicle_test_tick(&f)
    }
    testing.expectf(t,reached>=0,"the boat reaches the point")
}

// A world without vehicles, thrusters or aims: the steps do nothing and leave no row.
@(test)
a_world_without_vehicles_pays_nothing :: proc(t:^testing.T) {
    f:Vehicle_Test
    if !vehicle_test_init(t,&f) {return}
    defer vehicle_test_destroy(&f)
    body:=core.create(&f.entities)
    core.add(&f.transforms,body,core.TRANSFORM_IDENTITY)
    core.add(&f.inputs,body,inp.Move_Input{move={0,0,-1},frame=.Body})
    for _ in 0..<3 {vehicle_test_tick(&f)}
    vehicles_input(core.read(&f.vehicles),&f.inputs,{state=core.ref(&f.seat_state)},core.read(&f.remotes))
    testing.expect_value(t,core.count(&f.controls),0)
    testing.expect_value(t,len(f.requests.queue.items),0)
    move,_:=core.get(&f.inputs,body)
    testing.expect_value(t,move.move,[3]f32{0,0,-1})
}
