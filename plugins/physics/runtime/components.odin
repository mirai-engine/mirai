package physics

import "core:math/linalg"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

Body_Type :: sim.Body_Type
Query_Filter :: sim.Query_Filter
Collision_Filter :: sim.Filter
QUERY_FILTER_DEFAULT :: Query_Filter{filter={layers=0xffffffff,block=0xffffffff}} // hits every collider that collides with something; no sensor
Sphere :: sim.Sphere
Capsule :: sim.Capsule
Box :: sim.Box
Cylinder :: sim.Cylinder

Body_Lock :: enum u8 {Linear_X,Linear_Y,Linear_Z,Angular_X,Angular_Y,Angular_Z}
Body_Locks :: bit_set[Body_Lock;u8]

// The body of the entity. The simulation owns the Transform of every entity
// that has one: to move it the game pushes a request (teleport, move_kinematic).
@(component,locks="core.Transform",description="A simulated rigid body with mass, damping and motion settings. Its colliders define the physical shape.")
Rigid_Body :: struct {
    type:Body_Type,
    mass:f32 `mirai:"min=0,unit=kg"`, // 0: from the density of the colliders
    linear_damping:f32 `mirai:"min=0"`,
    angular_damping:f32 `mirai:"min=0"`,
    gravity_scale:f32,
    locks:Body_Locks,
    bullet:bool,
}

RIGID_BODY_DYNAMIC :: Rigid_Body{type=.Dynamic,gravity_scale=1}
RIGID_BODY_KINEMATIC :: Rigid_Body{type=.Kinematic,gravity_scale=1}
RIGID_BODY_STATIC :: Rigid_Body{type=.Static,gravity_scale=1}
RIGID_BODY_DEFAULT :: RIGID_BODY_DYNAMIC

Collider_Kind :: enum u8 {
    Box,
    Sphere,
    Capsule,
    Cylinder,
    Hull, // the convex hull of what the Mesh_Renderer of the entity shows
    Mesh, // the triangles of what the Mesh_Renderer shows; no mass, intended for static geometry
    Heightfield, // the compact height grid of a generated Mesh_Renderer; no mass
    External, // another plugin makes its shapes from this surface and collision (shapes, for a brush): physics makes none
}

COLLIDER_HULL_VERTICES :: 32

// One shape. With a Rigid_Body it is on the body of the entity; without, on
// the body of the nearest ancestor that has one, placed where the entity is
// relative to it, or on a static body of its own when no ancestor has one.
// The size is multiplied by the world scale of the entity; a Hull, Mesh or Heightfield
// takes its geometry from the Mesh_Renderer instead of size; an External one, from another plugin.
// A Character takes its capsule and its collision from it. Shared: the
// libraries that make entities (terrain chunks, the walls portals cut) write
// it on theirs.
@(component,shared,replicated,description="Defines a collision shape, its surface and how it meets the others: the categories it belongs to and collides with, from a preset or its own.")
Collider :: struct {
    kind:Collider_Kind `mirai:"section=Shape"`,
    size:[3]f32 `mirai:"min=0,unit=m"`, // box: half extents. sphere: radius in x. capsule and cylinder: radius in x, half height in y, along Y
    convex_radius:f32 `mirai:"min=0,unit=m"`, // rounds the edges of a box, cylinder or hull without changing its size
    center:[3]f32 `mirai:"unit=m"`,     // in the frame of the entity
    friction:f32 `mirai:"min=0,section=Surface"`,
    restitution:f32 `mirai:"min=0,max=1"`,
    density:f32 `mirai:"min=0,unit=kg/m3"`,
    drag:f32 `mirai:"min=0"`,           // Cd in a fluid; 0: the measured value of its kind (a sphere 0.47, a box 1.05)
    preset:Collision_Preset `mirai:"section=Filtering"`, // Custom: the sensor, belongs and collides below
    sensor:bool,                        // blocks nothing and reports what it overlaps
    belongs:Collision_Layers,
    collides:Collision_Layers,          // a sensor: those it reports
    group:core.Entity,                  // colliders of the same group never meet: a ragdoll, a vehicle
    surface_speed:[3]f32 `mirai:"unit=m/s,section=Motion"`, // in the frame of the entity: how the surface moves under what it carries, a conveyor
    one_way:bool,                       // blocks only what comes from the side the +Y of the entity faces
    dominance:i8,                       // a dynamic body pushes one of less dominance as if it had infinite mass, and is not pushed back
}

COLLIDER_DEFAULT :: Collider{size={0.5,0.5,0.5},friction=0.6,density=1000,belongs=1,collides=COLLISION_LAYERS_ALL}

collider_box :: proc "contextless" (half_extents:[3]f32) -> Collider {
    c:=COLLIDER_DEFAULT
    c.kind,c.size=.Box,half_extents
    return c
}
collider_sphere :: proc "contextless" (radius:f32) -> Collider {
    c:=COLLIDER_DEFAULT
    c.kind,c.size=.Sphere,{radius,0,0}
    return c
}
collider_capsule :: proc "contextless" (radius,half_height:f32) -> Collider {
    c:=COLLIDER_DEFAULT
    c.kind,c.size=.Capsule,{radius,half_height,0}
    return c
}
collider_cylinder :: proc "contextless" (radius,half_height:f32) -> Collider {
    c:=COLLIDER_DEFAULT
    c.kind,c.size=.Cylinder,{radius,half_height,0}
    return c
}
collider_hull :: proc "contextless" () -> Collider {
    c:=COLLIDER_DEFAULT
    c.kind=.Hull
    return c
}
collider_mesh :: proc "contextless" () -> Collider {
    c:=COLLIDER_DEFAULT
    c.kind=.Mesh
    return c
}
collider_heightfield :: proc "contextless" () -> Collider {
    c:=COLLIDER_DEFAULT
    c.kind=.Heightfield
    return c
}
// The capsule of a character: the height from its feet to the top of its head, standing on the feet.
collider_character :: proc "contextless" (radius:f32=0.3,height:f32=1.8) -> Collider {
    c:=COLLIDER_DEFAULT
    c.kind,c.size,c.center,c.friction=.Capsule,{radius,max(height*0.5-radius,0),0},{0,height*0.5,0},0
    return c
}

// The capsule Collider of the entity moved by the solver as a body that stands
// on the ground: its Transform is the position of the feet and its rotation,
// whose +Y is its up (core.Vertical) and which faces the yaw of its move, and
// the capsule stands on the feet along that up. The up turns toward the
// opposite of the gravity it feels, at up_speed. Its Character_Move drives it,
// which its locomotion writes in the mode it is in (locomotion.odin). Its
// size, mass and step_height take effect by making the character again; the
// simulation reads only its fields up to locks, and the locomotion writes the
// rest.
@(component,replicated,locks="core.Transform",description="A physical character that stands on walkable ground, steps and pushes, moved by its Move_Input in the mode it is in, with the parameters of the component of that mode (Walk, Fly...).")
Character :: struct {
    mass:f32 `mirai:"min=0,unit=kg"`, // 0: from the density of the capsule
    max_slope:f32 `mirai:"angle,min=0"`,
    step_height:f32 `mirai:"min=0,unit=m"`,
    traction_force:f32 `mirai:"min=0,unit=N"`,
    adhesion_force:f32 `mirai:"min=0,unit=N"`,
    gravity_scale:f32,
    push_force:f32 `mirai:"min=0,unit=N"`, // most of the traction passed to a dynamic body it leans on; 0: all of it
    density:f32 `mirai:"min=0,unit=kg/m3"`, // of the body in a fluid, whose volume is its mass over this: 985 a person; 0: no buoyancy
    up_speed:f32 `mirai:"angle,min=0,unit=deg/s"`, // its up turns toward the opposite of its gravity: around a planet; 0: it keeps its up
    locks:Body_Locks,                       // world axes the simulation never moves its feet along, as for a Rigid_Body; a place still does. Its move turns it: the angular ones do nothing
    mode:Locomotion_Mode,                   // the one it starts in; then the one it is in
    move_relative_to:Move_Relative,         // forward, for the seat that drives it
    pitch_limit:f32 `mirai:"angle,min=0"`,  // of the look a seat gives it, up and down from level
    turn_speed:f32 `mirai:"angle,min=0,unit=deg/s"`, // toward its move, moving relative to the camera or the world; 0: at once
    jumped:bool `mirai:"transient,readonly,hidden"`,           // in the air by a jump: no coyote time
    jump_held:bool `mirai:"transient,readonly,hidden"`,        // the jump button was down in the last tick
    ready:bool `mirai:"transient,local,hidden"`,               // its look was taken from where it stands
    coyote:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // left
    added:[3]f32 `mirai:"transient,readonly,hidden,unit=m/s"`, // what additive layered moves put in the last drive
    driven:[3]f32 `mirai:"transient,readonly,hidden,unit=m/s"`, // what the locomotion drove toward in the last tick without them, in the world
    pace:f32 `mirai:"transient,readonly,hidden"`,       // of its last move (core.Own_Pace): its velocity is that of its own time by it; 0: 1
    layer_time:f32 `mirai:"transient,readonly,hidden"`, // part of a tick of its own time its layered moves have not spent
    move_count:u32 `mirai:"transient,readonly,hidden"`,
    moves:[LAYERED_MOVE_CAPACITY]Layered_Move `mirai:"transient,readonly,hidden"`,
    crouched:bool `mirai:"transient,readonly,hidden"`,    // it asks for the crouch_height of its Walk: crouching or sliding
    crouch_held:bool `mirai:"transient,readonly,hidden"`, // the crouch button was down in the last tick
    crouch_lock:bool `mirai:"transient,readonly,hidden"`, // a slide ended with it standing up: crouch held does nothing until it is let go
    crouch_on:bool `mirai:"transient,readonly,hidden"`,   // it asks to crouch: crouch held, or toggled on with crouch_toggle
    crouch_buffer:f32 `mirai:"transient,readonly,hidden,unit=s"`, // left of a crouch pressed in the air, which slides on landing
    air_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,       // since it last stood
    fall_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,      // going down in the air without a stop: what a long fall is
    jump_speed:f32 `mirai:"transient,readonly,hidden,unit=m/s"`,   // up, of its last jump: a jump held keeps it (Walk.jump_rise)
    jump_rise:f32 `mirai:"transient,readonly,hidden,unit=s"`,      // left in which its jump held keeps jump_speed
    slide_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // it has slid
    slide_cooldown:f32 `mirai:"transient,readonly,hidden,unit=s"`, // left before crouch starts another slide
    slide_course:[3]f32 `mirai:"transient,readonly,hidden"`,       // where it started sliding, across its up
    slide_turn:f32 `mirai:"transient,readonly,hidden"`,            // radians its move turned the course from there, left about its up
    mantle_from,mantle_to:[3]f32 `mirai:"transient,readonly,hidden,unit=m"`, // where its feet start and end a mantle, in the world
    mantle_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // of the mantle it climbs
    mantle_height:f32 `mirai:"transient,readonly,unit=m"`,          // of the ledge of its last mantle over its feet: the animation of the climb chooses by it
    sprint_active:bool `mirai:"transient,readonly"`,                // in a tactical sprint (Tactical_Sprint): the camera and the animation choose by it
    sprint_spent:f32 `mirai:"transient,readonly"`,                  // energy of its Tactical_Sprint used: 0 is full (tactical_energy)
    sprint_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // in the tactical sprint: its ramp (tactical_boost)
    sprint_rest:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // since energy was last spent
    sprint_off:f32 `mirai:"transient,readonly,hidden,unit=s"`,      // without sprinting in the tactical sprint
    ledge_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,      // standing at the min_speed of its Ledge_Jump or more
    ledge_ready:bool `mirai:"transient,readonly"`,                  // a jump now is a ledge jump: the prompt of a game
    ledge_jumping:bool `mirai:"transient,readonly"`,                // in the air by a ledge jump, until it lands
}

PITCH_LIMIT_DEFAULT :: f32(85*mm.RAD_PER_DEG)

// A human of 80 kg that looks where it walks: the values of sim.CHARACTER_DESC_DEFAULT. Its capsule is collider_character().
character_default :: proc "contextless" () -> Character {
    d:=sim.CHARACTER_DESC_DEFAULT
    return {
        mass=d.mass,max_slope=d.max_slope,step_height=d.step_height,traction_force=d.traction_force,
        adhesion_force=d.adhesion_force,gravity_scale=d.gravity_scale,push_force=d.push_force,density=d.density,up_speed=d.up_speed,
        pitch_limit=PITCH_LIMIT_DEFAULT,turn_speed=500*mm.RAD_PER_DEG,
    }
}

// Whether two characters are the same body for the simulation: the fields it reads.
character_body_same :: proc "contextless" (a,b:Character) -> bool {
    return a.mass==b.mass && a.max_slope==b.max_slope && a.step_height==b.step_height && a.traction_force==b.traction_force &&
        a.adhesion_force==b.adhesion_force && a.gravity_scale==b.gravity_scale && a.push_force==b.push_force && a.density==b.density &&
        a.up_speed==b.up_speed && a.locks==b.locks

}

Drive :: sim.Drive
Move_Flag :: sim.Move_Flag
Move_Flags :: sim.Move_Flags

// What drives a Character from the next step on: its locomotion writes it,
// or a mode of the game under it, and the step hands it to the simulation.
// The locomotion adds it while the character plays.
@(component,shared,description="How the Character is driven: toward a velocity on the ground and another in the air, with a launch and the yaw it faces.")
Character_Move :: struct {
    value:sim.Character_Move `mirai:"transient,readonly"`,
    // m of the capsule from the feet to the top of the head it asks for: crouching. The step makes it
    // that tall before it moves it, and shorter only when what is over it lets it grow back (cramped in
    // its Character_State); 0, or taller than its Collider, is the height of its Collider.
    height:f32 `mirai:"transient,readonly,unit=m"`,
}

// What the last step left of a character, besides its core.Motion: the ground
// it found and how deep in a fluid it is, where the next step starts. Only the
// simulation writes it. The body faces the yaw of its Character_Move: whoever
// writes it adds ground_turn to it on every step, so the body, its walk and
// the camera turn together on ground that turns.
@(component,description="Whether the character stands, the ground physics found under it and how deep in a fluid it is.")
Character_State :: struct {
    standing:bool `mirai:"transient,readonly"`,
    walkable:bool `mirai:"transient,readonly,hidden"`,      // the ground under it, standing or not
    ground_distance:f32 `mirai:"transient,readonly,hidden,unit=m"`, // of the feet above it; 0 without ground
    ground_normal:[3]f32 `mirai:"transient,readonly,hidden"`,
    ground_velocity:[3]f32 `mirai:"transient,readonly,hidden,unit=m/s"`,
    ground_turn:f32 `mirai:"transient,readonly,hidden"`, // radians the ground turned the character in the last step
    wall_normal:[3]f32 `mirai:"transient,readonly,hidden"`, // of the wall it leans on, across its up and out of the wall; zero without one
    fluid:Fluid_Flags `mirai:"transient,readonly"`,
    submersion:f32 `mirai:"transient,readonly,min=0,max=1"`, // share of the body, from the feet to the head, under the surface
    head_depth:f32 `mirai:"transient,readonly,unit=m"`,       // of the top of the head under the surface; negative above it
    depth:f32 `mirai:"transient,readonly,hidden,unit=m"`,     // of fluid over the feet
    fluid_velocity:[3]f32 `mirai:"transient,readonly,hidden,unit=m/s"`, // the current around it
    height:f32 `mirai:"transient,readonly,hidden,unit=m"`, // of its capsule now, from the feet to the top of the head
    cramped:bool `mirai:"transient,readonly"`,             // shorter than the height its Character_Move asks: what is over it keeps it down
    velocity:[3]f32 `mirai:"transient,readonly,unit=m/s"`, // of the character itself after the last step, vertical speed included
}

character_state_of :: proc "contextless" (found:sim.Character_State) -> Character_State {
    return {
        standing=.Standing in found.ground,walkable=.Walkable in found.ground,ground_distance=found.ground_distance,
        ground_normal=found.ground_normal,ground_velocity=found.ground_velocity,ground_turn=found.ground_turn,wall_normal=found.wall_normal,
        fluid=found.fluid,submersion=found.submersion,head_depth=found.head_depth,depth=found.depth,fluid_velocity=found.fluid_velocity,
    }
}

Joint_Kind :: enum u8 {
    Fixed,     // the two frames coincide
    Spherical, // the anchors coincide; cone limits the angle between the axes and the limit, the twist
    Revolute,  // rotation about the axis; limit, motor and spring act on the angle
    Prismatic, // translation along the axis; limit, motor and spring act on the translation
    Distance,  // the anchors stay at length, or between lower and upper pulled toward length by the spring
    SixDOF,
}
Joint_Motion :: sim.Joint_Motion
Joint_Drive :: sim.Joint_Drive
Joint_Axis :: sim.Joint_Axis
Joint_Error :: sim.Joint_Error

// Joins the body of its entity to the body of target, or to the world when
// target is NONE. Both need a body of their own: a Rigid_Body, a Collider
// without one, or a Character as target. The joint acts in a frame of each
// body: anchor and rotation give the one of the entity, in its own space, and
// the X axis of the rotation is the axis of the joint. With auto_target the
// frame of the target is taken from where the two bodies are when the joint
// is made, and kept in Joint_State.
@(component,replicated)
Joint :: struct {
    kind:Joint_Kind `mirai:"section=Bodies"`,
    target:core.Entity,
    anchor:[3]f32 `mirai:"unit=m"`,
    rotation:mm.Quat,        // zero: identity
    target_anchor:[3]f32 `mirai:"unit=m"`,
    target_rotation:mm.Quat,
    auto_target:bool,
    collide:bool,            // the two bodies keep colliding with each other
    limit:bool `mirai:"section=Limits"`,
    lower,upper:f32,         // radians (revolute, spherical twist) or meters (prismatic, distance)
    cone:f32 `mirai:"angle,min=0"`, // spherical; zero: no limit
    motor:bool `mirai:"section=Motor"`,
    motor_speed:f32,         // rad/s or m/s
    max_motor:f32 `mirai:"min=0"`, // N m or N
    spring:bool `mirai:"section=Spring"`,
    hertz:f32 `mirai:"min=0"`,
    damping_ratio:f32 `mirai:"min=0"`,
    spring_target:f32,       // angle or translation the spring pulls toward
    length:f32 `mirai:"min=0,unit=m"`, // distance; zero: the distance when the joint is made
    break_force:f32 `mirai:"min=0,unit=N,section=Breaking"`,  // zero: unbreakable
    break_torque:f32 `mirai:"min=0"`,        // N m
    linear:[3]Joint_Axis `mirai:"section=Axes"`,
    angular:[3]Joint_Axis,
}

// What the simulation knows of a joint. broken stops the joint from being made
// again until the game clears it; the rest is what auto_target took.
@(component,replicated)
Joint_State :: struct {
    broken:bool,
    taken:bool,
    target_anchor:[3]f32,
    target_rotation:mm.Quat,
    length:f32,
    error:Joint_Error `mirai:"readonly"`,
}

joint_axis :: proc "contextless" (axis:[3]f32) -> mm.Quat {
    length:=linalg.length(axis)
    if length<1e-6 {return 1}
    return mm.quat_between([3]f32{1,0,0},axis/length)
}

joint_fixed :: proc "contextless" (target:core.Entity) -> Joint {
    return {kind=.Fixed,target=target,rotation=1,target_rotation=1,auto_target=true}
}
joint_spherical :: proc "contextless" (target:core.Entity,anchor:[3]f32={},cone:f32=0) -> Joint {
    return {kind=.Spherical,target=target,anchor=anchor,rotation=1,target_rotation=1,auto_target=true,cone=cone}
}
// A hinge about axis through anchor, both in the space of the entity.
joint_revolute :: proc "contextless" (target:core.Entity,anchor:[3]f32={},axis:=[3]f32{1,0,0}) -> Joint {
    return {kind=.Revolute,target=target,anchor=anchor,rotation=joint_axis(axis),target_rotation=1,auto_target=true}
}
// A slider along axis, in the space of the entity.
joint_prismatic :: proc "contextless" (target:core.Entity,axis:=[3]f32{1,0,0},anchor:[3]f32={}) -> Joint {
    return {kind=.Prismatic,target=target,anchor=anchor,rotation=joint_axis(axis),target_rotation=1,auto_target=true}
}
// A rod from anchor on the entity to target_anchor on the target, each in the
// space of its own; with hertz, a spring of that frequency instead.
joint_distance :: proc "contextless" (target:core.Entity,anchor:[3]f32={},target_anchor:[3]f32={},length:f32=0,hertz:f32=0,damping_ratio:f32=1) -> Joint {
    return {
        kind=.Distance,target=target,anchor=anchor,rotation=1,target_anchor=target_anchor,target_rotation=1,length=length,
        spring=hertz>0,hertz=hertz,damping_ratio=damping_ratio,limit=hertz>0,lower=0,upper=max(f32),
    }
}

joint_sixdof :: proc "contextless" (target:core.Entity,anchor:[3]f32={}) -> Joint {
    joint:=Joint{kind=.SixDOF,target=target,anchor=anchor,rotation=1,target_rotation=1,auto_target=true}
    for &axis in joint.linear {axis.motion=.Locked}
    for &axis in joint.angular {axis.motion=.Locked}
    return joint
}

joint_configuration_error :: proc "contextless" (joint:Joint) -> Joint_Error {
    return sim.joint_configuration_error({
        type=sim.Joint_Type(joint.kind),frame_a={joint.anchor,joint.rotation},frame_b={joint.target_anchor,joint.target_rotation},
        enable_limit=joint.limit,lower=joint.lower,upper=joint.upper,cone=joint.cone,
        enable_motor=joint.motor,motor_speed=joint.motor_speed,max_motor=joint.max_motor,
        enable_spring=joint.spring,hertz=joint.hertz,damping_ratio=joint.damping_ratio,target=joint.spring_target,
        length=joint.length,break_force=joint.break_force,break_torque=joint.break_torque,linear=joint.linear,angular=joint.angular,
    })
}

joint_drive_pose :: proc "contextless" (joint:^Joint,translation:[3]f32,rotation:mm.Quat,hertz:f32=5,damping_ratio:f32=1,max_force:f32=1000,max_torque:f32=1000) -> Joint_Error {
    if joint==nil {return .Invalid_Value}
    desc:=sim.Joint_Desc{type=sim.Joint_Type(joint.kind),linear=joint.linear,angular=joint.angular}
    if error:=sim.joint_drive_pose(&desc,translation,rotation,hertz,damping_ratio,max_force,max_torque);error!=.None {return error}
    next:=joint^
    next.linear,next.angular=desc.linear,desc.angular
    if error:=joint_configuration_error(next);error!=.None {return error}
    joint^=next
    return .None
}
