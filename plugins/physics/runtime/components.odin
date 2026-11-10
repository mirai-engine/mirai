package physics

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
    External, // another plugin makes its shapes from this surface and collision (destruct, for a Destructible): physics makes none
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
// which the locomotion plugin writes from its Walk, Fly or Swim, or a game.
// Only an author writes it: its size, mass and step_height take effect by
// making the character again.
@(component,replicated,locks="core.Transform",description="A physical character that stands on walkable ground, steps and pushes, moved by its Character_Move.")
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
    turn_speed:f32 `mirai:"angle,min=0,unit=deg/s"`, // its yaw toward where it goes, as a seat that moves it relative to the camera or the world or an agent that steers it turn it; 0: at once
}

// A human of 80 kg: the values of sim.CHARACTER_DESC_DEFAULT. Its capsule is collider_character().
character_default :: proc "contextless" () -> Character {
    d:=sim.CHARACTER_DESC_DEFAULT
    return {
        mass=d.mass,max_slope=d.max_slope,step_height=d.step_height,traction_force=d.traction_force,
        adhesion_force=d.adhesion_force,gravity_scale=d.gravity_scale,push_force=d.push_force,density=d.density,up_speed=d.up_speed,
        turn_speed=500*mm.RAD_PER_DEG,
    }
}

Drive :: sim.Drive
Character_Drive :: sim.Character_Move

// What drives a Character from the next step on: the locomotion plugin or a
// game writes it, and the step hands it to the simulation.
@(component,shared,description="How the Character is driven: toward a velocity on the ground and another in the air, with a launch and the yaw it faces.")
Character_Move :: struct {
    value:Character_Drive `mirai:"transient,readonly"`,
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

Joint_Motion :: sim.Joint_Motion
Joint_Drive :: sim.Joint_Drive
Joint_Axis :: sim.Joint_Axis
Joint_Error :: sim.Joint_Error

// Joins two bodies: a, or the body of the parent of its entity when a is NONE, and b, or the world when b is
// NONE; each needs a body of its own (a Rigid_Body, a Collider without one, a Character). The Transform of
// its entity is its frame, seen from a, and seen from b where the joint is when it is made, which Joint_State
// keeps, unless b_frame gives it. Each move along an axis of that frame and each turn about it is free,
// locked or limited, with an optional drive: the X axis is the one of a hinge or a slider, and the turns
// about Y and Z, limited together, a cone. The presets joint_fixed, joint_spherical, joint_revolute,
// joint_prismatic and joint_distance lock what each kind locks.
@(component,replicated,description="Joins two bodies at its own frame: each move along its axes and each turn about them free, locked or limited, with an optional drive.")
Joint :: struct {
    a:core.Entity `mirai:"section=Bodies"`,
    b:core.Entity,
    b_frame:bool,             // b_anchor and b_rotation give its frame on b
    b_anchor:[3]f32 `mirai:"unit=m"`,
    b_rotation:mm.Quat,       // zero: identity
    collide:bool,             // the two bodies keep colliding with each other
    break_force:f32 `mirai:"min=0,unit=N,section=Breaking"`, // zero: unbreakable
    break_torque:f32 `mirai:"min=0,unit=N m"`,
    linear:[3]Joint_Axis `mirai:"section=Axes"`, // along X, Y and Z: two or three limited share one limit, on the length across them
    angular:[3]Joint_Axis,    // about X, Y and Z: Y and Z limited share one, a cone whose angle toward each side is its limit
}

// What the simulation knows of a joint. broken stops the joint from being made
// again until the game repairs it; b_anchor and b_rotation are the frame on b it took.
@(component,replicated)
Joint_State :: struct {
    broken:bool,
    taken:bool,
    b_anchor:[3]f32,
    b_rotation:mm.Quat,
    error:Joint_Error `mirai:"readonly"`,
}

@(private) JOINT_LOCKED :: [3]Joint_Axis{{motion=.Locked},{motion=.Locked},{motion=.Locked}}

joint_fixed :: proc "contextless" (b:core.Entity) -> Joint {
    return {b=b,linear=JOINT_LOCKED,angular=JOINT_LOCKED}
}
// The anchors coincide; with cone, the X axis of b turns at most that much from that of a.
joint_spherical :: proc "contextless" (b:core.Entity,cone:f32=0) -> Joint {
    joint:=Joint{b=b,linear=JOINT_LOCKED}
    if cone>0 {joint.angular[1],joint.angular[2]={motion=.Limited,lower=-cone,upper=cone},{motion=.Limited,lower=-cone,upper=cone}}
    return joint
}
// A hinge about the X axis of its frame.
joint_revolute :: proc "contextless" (b:core.Entity) -> Joint {
    return {b=b,linear=JOINT_LOCKED,angular={{},{motion=.Locked},{motion=.Locked}}}
}
// A slider along the X axis of its frame.
joint_prismatic :: proc "contextless" (b:core.Entity) -> Joint {
    return {b=b,linear={{},{motion=.Locked},{motion=.Locked}},angular=JOINT_LOCKED}
}
// The frame stays between lower and upper meters from b_anchor on b: a rope from 0, a rod at lower equal to upper.
joint_distance :: proc "contextless" (b:core.Entity,b_anchor:[3]f32,lower,upper:f32) -> Joint {
    limit:=Joint_Axis{motion=.Limited,lower=lower,upper=upper}
    return {b=b,b_frame=true,b_anchor=b_anchor,b_rotation=1,linear={limit,limit,limit}}
}

joint_configuration_error :: proc "contextless" (joint:Joint) -> Joint_Error {
    return sim.joint_configuration_error({
        frame_b={joint.b_anchor,joint.b_rotation},break_force=joint.break_force,break_torque=joint.break_torque,
        linear=joint.linear,angular=joint.angular,
    })
}

// Drives a joint toward a translation and a rotation of b in its frame: sim.joint_drive_pose.
joint_drive_pose :: proc "contextless" (joint:^Joint,translation:[3]f32,rotation:mm.Quat,hertz:f32=5,damping_ratio:f32=1,max_force:f32=1000,max_torque:f32=1000) -> Joint_Error {
    if joint==nil {return .Invalid_Value}
    desc:=sim.Joint_Desc{linear=joint.linear,angular=joint.angular}
    if error:=sim.joint_drive_pose(&desc,translation,rotation,hertz,damping_ratio,max_force,max_torque);error!=.None {return error}
    next:=joint^
    next.linear,next.angular=desc.linear,desc.angular
    if error:=joint_configuration_error(next);error!=.None {return error}
    joint^=next
    return .None
}
