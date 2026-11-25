package vehicles

import "core:math"
import "core:math/linalg"
import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// Bodies that steer themselves: a boat, a submarine, a hovercraft, a turret.
// A Vehicle is a Rigid_Body moved by the Thrusters that hang from it and
// steered by its Move_Input in its own axes (Move_Frame.Body): right steers,
// up rises, back reverses. A seat writes it from the actions of this plugin,
// in their own input context (the one a Mount enters for its rider); an AI
// writes the same input (move_toward). Each tick the controls close on what
// is asked (smoothing), each thruster pushes along its forward at its place
// with a force that fades to nothing at its top speed, in the medium it
// works in, and the hull turns toward its steer or its look and keeps
// upright with torques: everything through the requests of physics, so a
// tick simulated again pushes alike. An Aim turns its entity about one axis
// toward the look of the body it hangs from (a turret ring, a barrel).
// Fuel, damage and who may drive are the game's.

// The input context of the actions of a vehicle: a Mount puts the seat of its rider in it.
@(name="vehicle") VEHICLE_CONTEXT : inp.Input_Context : 8

// What a seat drives a vehicle with, in VEHICLE_CONTEXT.
@(actions)
Vehicle_Action :: enum u8 {Throttle,Steer,Rise}

vehicle_action_defaults :: proc "contextless" () -> [Vehicle_Action]inp.Action_Bindings {
    return {
        .Throttle=inp.action_default_in(VEHICLE_CONTEXT,.Axis,inp.binding_key_axis(.S,.W),inp.binding_gamepad_axis(.Left_Y)),
        .Steer=inp.action_default_in(VEHICLE_CONTEXT,.Axis,inp.binding_key_axis(.A,.D),inp.binding_gamepad_axis(.Left_X)),
        .Rise=inp.action_default_in(VEHICLE_CONTEXT,.Axis,inp.binding_key_axis(.C,.Space),inp.binding_gamepad_axis(.Right_Trigger),inp.binding_gamepad_axis(.Left_Trigger,-1)),
    }
}

Vehicle_Facing :: enum u8 {
    None,  // only its thrusters turn it
    Steer, // its steer turns it, at turn_speed for a whole steer
    Look,  // it turns toward the yaw of its look, at turn_speed at most
}

@(component,replicated,description="A rigid body its thrusters push and its Move_Input steers in its own axes: a boat, a submarine, a hovercraft.")
Vehicle :: struct {
    smoothing:f32 `mirai:"min=0,unit=s"`,    // the controls close half of the way to what is asked in this time; 0: at once
    facing:Vehicle_Facing,
    turn_speed:f32 `mirai:"min=0,unit=rad/s"`, // the yaw rate it turns at, about the up of the world
    upright:f32 `mirai:"min=0,unit=rad/s"`,    // how fast a spring brings its up back to the up of the world; 0: no spring
}

VEHICLE_DEFAULT :: Vehicle{smoothing=0.15,facing=.Steer,turn_speed=0.8,upright=2}

TURN_RESPONSE :: f32(0.25) // s the yaw rate takes to reach what is asked

// The controls of a vehicle as they close on what its Move_Input asks.
@(component,derived,description="The controls of a vehicle as they close on what its input asks.")
Vehicle_Controls :: struct {
    throttle,steer,rise:f32 `mirai:"transient,readonly"`, // each -1 to 1
}

Thruster_Axis :: enum u8 {Throttle,Steer,Rise}

Thruster_Medium :: enum u8 {
    Any,   // air or water: a jet, a fan
    Fluid, // only while its place is in a fluid (physics.Fluid): a propeller out of the water gives nothing
}

// Pushes the Vehicle it hangs from along its own forward (-Z), at its place.
@(component,replicated,description="Pushes the vehicle it hangs from along its forward, at its place, with a force that fades to nothing at its top speed.")
Thruster :: struct {
    force:f32 `mirai:"min=0,unit=N"`,       // at a whole control, standing still
    top_speed:f32 `mirai:"min=0,unit=m/s"`, // along where it pushes, the force is nothing at it; 0: it never fades
    axis:Thruster_Axis,                     // the control it follows
    steer_angle:f32 `mirai:"angle"`,        // it turns about its up by this much at a whole steer, as a rudder; positive turns the vehicle toward the steer from behind it
    medium:Thruster_Medium,
}

THRUSTER_DEFAULT :: Thruster{force=4000,top_speed=10}

// Writes the Move_Input of each vehicle a seat drives here from the actions
// of its seat, in the axes of the vehicle.
@(step="fixed",stage="input",after="camera_drive")
vehicles_input :: proc(vehicles:^core.Table(Vehicle,.Read),moves:^core.Table(inp.Move_Input),actions:inp.Input_Of(Vehicle_Action),remotes:^core.Table(core.Remote,.Read)) {
    if core.count(vehicles)==0 {return}
    for row in 0..<core.count(vehicles) {
        e:=core.entity_at(vehicles,row)
        seat:=inp.driver_of(actions.state,e)
        if seat==core.NONE || !core.owned(remotes,e) {continue}
        move:=core.edit(moves,e)
        if move==nil || move.frame!=.Body {continue}
        move.move={inp.seat_value(actions,seat,.Steer),inp.seat_value(actions,seat,.Rise),-inp.seat_value(actions,seat,.Throttle)}
    }
}

// What the simulation of a tick reads.
@(params)
Vehicle_View :: struct {
    physics:core.Ref(phys.Physics_State),
    moves:^core.Table(inp.Move_Input,.Read),
    locals:^core.Table(core.Transform,.Read),
    parents:^core.Table(core.Parent,.Read),
    verticals:^core.Table(core.Vertical,.Read),
    remotes:^core.Table(core.Remote,.Read),
}

// The controls, the pushes of the thrusters, the turn and the spring of each
// vehicle, and where each Aim turns, for the step of physics of the tick.
@(step="fixed",stage="simulate",before="physics_prepare")
vehicles_simulate :: proc(
    vehicles:^core.Table(Vehicle,.Read),controls:^core.Table(Vehicle_Controls),thrusters:^core.Table(Thruster,.Read),aims:^core.Table(Aim),
    view:Vehicle_View,requests:^phys.Body_Requests,time:core.Time,problems:^core.Problems,
) {
    if core.count(vehicles)==0 && core.count(controls)==0 && core.count(aims)==0 {return}
    for row:=core.count(controls)-1;row>=0;row-=1 {
        if e:=core.entity_at(controls,row);!core.has(vehicles,e) {core.remove(controls,e)}
    }
    dt:=time.dt
    if dt>0 {
        for row in 0..<core.count(vehicles) {
            e:=core.entity_at(vehicles,row)
            if !core.owned(view.remotes,e) {continue}
            vehicle_step(e,core.at(vehicles,row),controls,view,requests,dt,problems)
        }
        if core.count(thrusters)>0 {thrusters_push(vehicles,controls,thrusters,view,requests)}
    }
    aims_turn(aims,view,dt)
}

// The controls a Move_Input asks, in the axes of a body at rotation.
move_controls :: proc "contextless" (move:inp.Move_Input,rotation:mm.Quat) -> Vehicle_Controls {
    asked:=move.move
    if move.frame==.View {asked=mm.quat_rotate(conj(rotation),asked)}
    return {throttle=clamp(-asked.z,-1,1),steer=clamp(asked.x,-1,1),rise=clamp(asked.y,-1,1)}
}

@(private)
vehicle_step :: proc(e:core.Entity,vehicle:Vehicle,controls:^core.Table(Vehicle_Controls),view:Vehicle_View,requests:^phys.Body_Requests,dt:f32,problems:^core.Problems) {
    body,ok:=phys.body_info(view.physics,phys.body_of(view.physics,e))
    if !ok || body.type!=.Dynamic {return}
    move,_:=core.get(view.moves,e)
    asked:=move_controls(move,body.pose.rotation)
    now:=core.staged(controls,e)
    if now==nil {
        if !core.add(controls,e,Vehicle_Controls{}) {
            core.report(problems,e,"vehicles.memory","out of memory for the controls of this vehicle; free memory")
            return
        }
        now=core.staged(controls,e)
    }
    // Each control closes half of its way in smoothing seconds.
    closed:f32=1
    if vehicle.smoothing>0 {closed=1-math.exp(-math.LN2*dt/vehicle.smoothing)}
    next:=now^
    next.throttle+=(asked.throttle-next.throttle)*closed
    next.steer+=(asked.steer-next.steer)*closed
    next.rise+=(asked.rise-next.rise)*closed
    if next!=now^ {now^=next}

    up:=[3]f32{0,1,0}
    turn:[3]f32 // angular acceleration asked, rad/s^2
    spin:=linalg.dot(body.angular,up)
    switch vehicle.facing {
    case .None:
    case .Steer:
        turn+=up*(-next.steer*vehicle.turn_speed-spin)/TURN_RESPONSE
    case .Look:
        heading:=mm.yaw_of_direction(mm.quat_forward(body.pose.rotation))
        look:=move.look_yaw
        if vertical:=core.vertical_of(view.verticals,e);vertical!=mm.QUAT_IDENTITY {
            look=mm.yaw_of_direction(mm.quat_rotate(vertical,mm.quat_rotate(mm.quat_axis_angle({0,1,0},look),[3]f32{0,0,-1})))
        }
        wanted:=clamp(mm.angle_delta(heading,look)/TURN_RESPONSE,-vehicle.turn_speed,vehicle.turn_speed)
        turn+=up*(wanted-spin)/TURN_RESPONSE
    }
    if vehicle.upright>0 {
        // A critically damped spring from its up to the up of the world.
        tilt:=linalg.cross(mm.quat_rotate(body.pose.rotation,up),up)
        swing:=body.angular-up*spin
        turn+=tilt*vehicle.upright*vehicle.upright-swing*2*vehicle.upright
    }
    if turn=={} || !(linalg.length(turn)<1e6) {return}
    // The torque that gives it that acceleration: its inertia turned into the world.
    local:=mm.quat_rotate(conj(body.pose.rotation),turn)
    phys.apply_torque(requests,e,mm.quat_rotate(body.pose.rotation,body.inertia*local))
}

// Each thruster pushes the vehicle it hangs from by the control it follows.
@(private)
thrusters_push :: proc(vehicles:^core.Table(Vehicle,$A),controls:^core.Table(Vehicle_Controls),thrusters:^core.Table(Thruster,$B),view:Vehicle_View,requests:^phys.Body_Requests) {
    for row in 0..<core.count(thrusters) {
        e:=core.entity_at(thrusters,row)
        thruster:=core.at(thrusters,row)
        hull:=core.ancestor_with(view.parents,vehicles,e)
        if hull==core.NONE || !core.owned(view.remotes,hull) {continue}
        now,driven:=core.get(controls,hull)
        if !driven {continue}
        amount:f32
        switch thruster.axis {
        case .Throttle: amount=now.throttle
        case .Steer:    amount=now.steer
        case .Rise:     amount=now.rise
        }
        if amount==0 || thruster.force==0 {continue}
        place,placed:=core.world_of(view.locals,view.parents,e)
        if !placed {continue}
        if thruster.medium==.Fluid {
            sample,_,wet:=phys.fluid_at(view.physics,place.position)
            if !wet || !(sample.density>0) {continue}
        }
        body,ok:=phys.body_info(view.physics,phys.body_of(view.physics,hull))
        if !ok || body.type!=.Dynamic {continue}
        along:=mm.quat_forward(place.rotation)
        if thruster.steer_angle!=0 {along=mm.quat_rotate(mm.quat_axis_angle(mm.quat_rotate(place.rotation,[3]f32{0,1,0}),now.steer*thruster.steer_angle),along)}
        // Along where it pushes, the force fades to nothing at its top speed.
        center:=body.pose.position+mm.quat_rotate(body.pose.rotation,body.center)
        velocity:=body.linear+linalg.cross(body.angular,place.position-center)
        pushing:=along*math.sign(amount)
        fade:f32=1
        if thruster.top_speed>0 {fade=clamp(1-linalg.dot(velocity,pushing)/thruster.top_speed,0,1)}
        if fade==0 {continue}
        phys.apply_force(requests,hull,along*thruster.force*amount*fade,place.position)
    }
}

// The Move_Input in the axes of a vehicle at pose that takes it toward a point
// and slows it within arrive meters of it: what an AI writes with
// input.move_set, as a seat would steer.
move_toward :: proc "contextless" (pose:mm.Transform,point:[3]f32,arrive:f32=4) -> inp.Move_Input {
    toward:=mm.quat_rotate(conj(pose.rotation),point-pose.position)
    toward.y=0
    distance:=linalg.length(toward)
    if distance<1e-3 {return {frame=.Body}}
    // Right of it steers right; behind it, a full turn toward the side it is on.
    steer:=clamp(math.atan2(toward.x,-toward.z)/(0.25*math.PI),-1,1)
    throttle:=clamp(distance/max(arrive,1e-3),0,1)*clamp(-toward.z/distance+0.5,0,1)
    return {move={steer,0,-throttle},frame=.Body}
}
