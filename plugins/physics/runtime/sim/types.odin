package mirai_physics

import "core:mem"
import "mirai:std/base"
import math "mirai:std/math"

Aabb :: math.Aabb

Body_Handle :: distinct base.Handle
Shape_Handle :: distinct base.Handle
Joint_Handle :: distinct base.Handle
Hull_Handle :: distinct base.Handle
Mesh_Handle :: distinct base.Handle
Heightfield_Handle :: distinct base.Handle

SPECULATIVE_DISTANCE :: 4*LINEAR_SLOP
MATCH_DISTANCE :: 2*LINEAR_SLOP // a contact point this close to one of the last step is the same point
AABB_MARGIN :: 0.1
TIME_TO_SLEEP :: 0.5 // seconds
MAX_ROTATION :: 0.25*PI // per step, radians
GRAPH_COLORS :: 24
MAX_WORKERS :: 64

// Runs body over [0,count) split in ranges of about `grain` items; `worker` is below worker_count and
// unique among ranges running at the same time. Must return after every range has finished.
Parallel_For :: #type proc(count,grain:int,data:rawptr,body:proc(data:rawptr,first,last,worker:int))

World_Desc :: struct {
    allocator:mem.Allocator,
    body_capacity,shape_capacity,contact_capacity,joint_capacity:int,
    hull_capacity,mesh_capacity,heightfield_capacity:int,
    character_capacity:int,
    fluid_capacity:int,
    breakable_capacity,piece_capacity,bond_capacity:int, // their pools are made with the first breakable
    event_capacity:int, // per kind of event and step
    static_change_capacity:int, // boxes static_changes keeps for a reader that falls behind
    gravity:Vec3,
    substeps:int,
    worker_count:int,
    parallel_for:Parallel_For, // nil runs every stage on the calling thread
    parallel_user:rawptr,      // in context.user_ptr while parallel_for runs: the job system it forwards to
    contact_hertz:f32,         // stiffness of the contact spring
    contact_damping_ratio:f32,
    contact_speed:f32,         // m/s, cap of the speed that resolves penetration
    joint_hertz:f32,
    joint_damping_ratio:f32,
    restitution_threshold:f32, // m/s, slower impacts do not bounce
    max_linear_speed:f32,      // m/s
    hit_speed:f32,             // m/s of approach below which a contact point is a load, not a hit
    sleep_disabled:bool,
}

world_desc_default :: proc() -> World_Desc {
    return {
        allocator=context.allocator,
        body_capacity=4096,shape_capacity=4096,contact_capacity=16384,joint_capacity=1024,
        hull_capacity=256,mesh_capacity=1024,heightfield_capacity=1024,event_capacity=1024,
        character_capacity=256,fluid_capacity=64,static_change_capacity=1024,
        breakable_capacity=64,piece_capacity=2048,bond_capacity=8192,
        gravity={0,-9.81,0},substeps=4,worker_count=1,
        contact_hertz=30,contact_damping_ratio=10,contact_speed=3,
        joint_hertz=60,joint_damping_ratio=2,
        restitution_threshold=1,max_linear_speed=400,hit_speed=0.5,
    }
}

Body_Type :: enum u32 {Static,Kinematic,Dynamic}

Body_Flag :: enum u32 {
    Awake,
    Sleep_Disabled,
    Bullet,
    Lock_Linear_X,Lock_Linear_Y,Lock_Linear_Z,
    Lock_Angular_X,Lock_Angular_Y,Lock_Angular_Z,
    Mass_Override, // the mass was set by the caller and shapes do not change it
    Own_Gravity,   // it falls with its gravity, not with that of the world
    Enlarged,      // a shape left its fat box during the last step
    Character,     // capsule of a character: its contacts and boxes look ahead by its speed
    Debris,        // small fragment: collides with static bodies only and raises no events
}
Body_Flags :: bit_set[Body_Flag;u32]
BODY_LOCKS :: Body_Flags{.Lock_Linear_X,.Lock_Linear_Y,.Lock_Linear_Z,.Lock_Angular_X,.Lock_Angular_Y,.Lock_Angular_Z}

Body_Desc :: struct {
    type:Body_Type,
    position:Vec3,
    rotation:Quat, // zero means identity
    linear_velocity,angular_velocity:Vec3,
    linear_damping,angular_damping:f32,
    gravity_scale:f32,
    sleep_threshold:f32, // m/s
    locks:Body_Flags,    // subset of BODY_LOCKS
    bullet:bool,
    sleep_disabled:bool,
    asleep:bool,
    debris:bool,
    user_data:u64,
}

BODY_DESC_DEFAULT :: Body_Desc{type=.Dynamic,rotation=QUAT_IDENTITY,gravity_scale=1,sleep_threshold=0.05}

// Slot of a body. Plain data: the whole array is copied by snapshots.
Body :: struct {
    user_data:u64,
    position:Vec3, // origin of the body frame
    rotation:Quat,
    center:Vec3,   // world center of mass
    local_center:Vec3,
    linear_velocity,angular_velocity:Vec3,
    force,torque:Vec3,
    inertia,inv_inertia:Mat3, // local, about the center of mass
    mass,inv_mass:f32,
    linear_damping,angular_damping,gravity_scale:f32,
    sleep_threshold,sleep_time:f32,
    max_extent,min_extent:f32, // farthest shape point from the center of mass; smallest inner radius
    shape_list,shape_count:i32,
    contact_list,contact_count:i32, // edge keys: contact index *2 + side
    joint_list:i32,
    island,island_prev,island_next:i32, // island of the body, -1 when static, and its neighbors in it
    solver_index:i32,
    generation:u32,  // odd while the slot is in use
    type:Body_Type,
    flags:Body_Flags,
    gravity:Vec3, // m/s2, with Own_Gravity
}
#assert(size_of(Body)==280)

// Dynamic bodies that touching contacts and joints connect, directly or not, fall asleep and wake together as
// an island. A kinematic body is an island of its own; a static body has none.
Island :: struct {
    head,tail:i32, // bodies, linked by island_prev and island_next; head is the next free slot while unused
    count:i32,
    removed:i32,   // constraints gone since the island was last split: it may have come apart
}
#assert(size_of(Island)==16)

Shape_Type :: enum u32 {Sphere,Capsule,Box,Hull,Cylinder,Mesh,Heightfield}

Sphere :: struct {radius:f32}
// Along the local Y axis: two hemispheres whose centers are half_height away from the center.
Capsule :: struct {radius,half_height:f32}
Box :: struct {half_extents:Vec3}
// Along the local Y axis, with flat caps half_height away from the center.
Cylinder :: struct {radius,half_height:f32}
Geometry :: union {Sphere,Capsule,Box,Cylinder,Hull_Handle,Mesh_Handle,Heightfield_Handle}

// A shape belongs to `layers` and answers every layer: it blocks those in `block`, only overlaps those in
// `overlap` and ignores the rest. A pair takes the weaker answer of its two shapes: Ignore, then Overlap,
// then Block. Shapes of the same non-zero group never meet.
Collision_Layers :: distinct u32
Filter :: struct {
    layers,block,overlap:Collision_Layers,
    _:u32,
    group:u64,
}
FILTER_DEFAULT :: Filter{layers=1,block=0xffffffff}
Response :: enum u8 {Ignore,Overlap,Block}

// Two dynamic bodies, one with a shape in layers `a` and the other in `b` (either way round), yield to each
// other: the normal impulse of their contact is at most `force` N times the substep, so they pass through
// one another pushing instead of blocking. Without a rule a contact is rigid.
Push_Rule :: struct {
    a,b:Collision_Layers,
    force:f32, // N
}
PUSH_RULE_CAPACITY :: 16

Shape_Flag :: enum u32 {
    Moved,   // needs new pairs at the next step
    One_Way, // blocks only what comes from the side its local +Y faces
    Hits,    // its contacts raise hit events
    Twin,    // a copy that the twin of its body carries elsewhere (twin.odin)
}
Shape_Flags :: bit_set[Shape_Flag;u32]

Shape_Desc :: struct {
    geometry:Geometry,
    transform:Transform, // in the body frame; a zero rotation means identity
    friction,restitution:f32,
    rolling_resistance:f32, // m: torque against rolling per newton of normal force, the coefficient times the radius (0.01 x 0.3 m for a tire)
    density:f32, // kg/m3
    filter:Filter,
    user_data:u64,
    surface_speed:Vec3, // m/s in the frame of the shape: how its surface moves under what it carries, a conveyor
    one_way:bool,       // blocks only what comes from the side its local +Y faces
    dominance:i8,       // between two dynamic bodies the shape of more dominance pushes as if its body had infinite mass
    hits:bool,          // its contacts raise hit events
    tag:u32,            // the caller's own number for the shape, zero for none
    // m: rounds the edges of a box or a cylinder without changing its size, below its smallest half extent.
    // A hull is rounded when it is made (hull_create); spheres, capsules, meshes and heightfields ignore it.
    convex_radius:f32,
    drag:f32, // Cd in a fluid; zero takes the measured value of its form (CD_SPHERE...)
}

SHAPE_DESC_DEFAULT :: Shape_Desc{transform=TRANSFORM_IDENTITY,friction=0.6,density=1000,filter=FILTER_DEFAULT}

Shape :: struct {
    user_data:u64,
    filter:Filter,
    local:Transform,
    size:Vec3, // sphere: radius in x. capsule and cylinder: radius in x, half height in y. box: half extents
    aabb,fat:Aabb,
    friction,restitution,density:f32,
    body,next,prev:i32,
    proxy:i32,
    resource:u32, // slot of the hull, mesh or heightfield
    tag:u32,
    generation:u32,
    type:Shape_Type,
    flags:Shape_Flags,
    rolling_resistance:f32,
    dominance:i32,
    surface_speed:Vec3, // m/s, in the frame of the shape
    radius:f32, // convex radius of a box, hull or cylinder: it collides as its core, smaller by this, inflated by it
    drag:f32,   // Cd in a fluid
    source:i32, // a copy of a twin: the shape it copies
}
#assert(size_of(Shape)==200)

Contact_Flag :: enum u32 {
    Touching,
    Overlap, // the pair only overlaps: no manifold and no response
    Started,  // touching began in the last step
    Stopped,
    Disjoint, // the fat boxes stopped overlapping
    Visited,
    Continuous,
    Pass,     // met a one-way shape from its back: goes through it until the shapes stop touching
}
Contact_Flags :: bit_set[Contact_Flag;u32]

// What a manifold carries from one step to the next: feature ids and impulses for warm starting.
Manifold_State :: struct {
    count:i32,
    ids:[MANIFOLD_MAX_POINTS]u32,
    points:[MANIFOLD_MAX_POINTS]Vec3, // on shape A, in its frame
    normal_impulses:[MANIFOLD_MAX_POINTS]f32,
    friction_impulse:Vec3, // world
    twist_impulse:f32,
    rolling_impulse:Vec3,  // world
}

Contact_Edge :: struct {prev,next:i32}

// The axis that decided the last narrow phase of two hulls, tried first at the next one.
Sat_Kind :: enum u8 {None,Face_A,Face_B,Edges}
Sat_Cache :: struct {separation:f32,index_a,index_b:u16,kind:Sat_Kind}

Contact :: struct {
    shape_a,shape_b:i32,
    body_a,body_b:i32,
    edges:[2]Contact_Edge,
    flags:Contact_Flags,
    friction,restitution,rolling_resistance:f32,
    manifold:Manifold_State,
    extra:i32, // block of further manifolds of a contact with a mesh, or -1
    manifold_count:i32,
    sat:Sat_Cache,
}
#assert(size_of(Contact)==180)

// Geometry of a manifold, recomputed every step for awake contacts. Anchors are relative to the centers of
// mass of the bodies, in world axes.
// `impulse` is the normal impulse of the last step and `approach` the speed in m/s at which the surfaces
// closed in before it, both zero until the contact is solved.
Manifold_Point :: struct {anchor_a,anchor_b,point:Vec3,separation,impulse,approach:f32}
Manifold :: struct {normal:Vec3,count:i32,points:[MANIFOLD_MAX_POINTS]Manifold_Point}

EXTRA_MANIFOLDS :: 3
Manifold_Block :: struct {manifolds:[EXTRA_MANIFOLDS]Manifold_State,next_free:i32}

// The user data of the bodies and of the shapes of an event when it was raised: what follows in the step, a
// breakable that breaks, may end them before the event is read.
Event_Users :: struct {body_a,body_b,shape_a,shape_b:u64}
Contact_Begin_Event :: struct {
    shape_a,shape_b:Shape_Handle,
    body_a,body_b:Body_Handle,
    point,normal:Vec3, // normal from A to B
    impulse:f32,       // N s, normal impulse applied in the step
    users:Event_Users,
}
Contact_End_Event :: struct {shape_a,shape_b:Shape_Handle,body_a,body_b:Body_Handle,users:Event_Users}
// One for each shape of a pair that overlaps, as `shape`. `crossed`: a bullet went through the other
// shape within the step, so the pair begins and ends in the same step. In users, A is `shape` and its body.
Overlap_Event :: struct {shape,other:Shape_Handle,body,other_body:Body_Handle,crossed:bool,users:Event_Users}
Joint_Break_Event :: struct {joint:Joint_Handle,body_a,body_b:Body_Handle,force,torque:f32}
Body_Event :: struct {body:Body_Handle,user_data:u64}
// A contact of a shape that raises hits, at the points that approached faster than World_Desc.hit_speed.
Contact_Hit_Event :: struct {
    shape_a,shape_b:Shape_Handle,
    point,normal:Vec3, // mean of those points; normal from A to B
    impulse:f32,       // N s, normal impulse of those points in the step
}

// Events of the last step. The slices belong to the world and last until the next step or restore.
Events :: struct {
    contact_begin:[]Contact_Begin_Event,
    contact_end:[]Contact_End_Event,
    overlap_begin,overlap_end:[]Overlap_Event,
    joint_break:[]Joint_Break_Event,
    sleep,wake:[]Body_Event,
    hit:[]Contact_Hit_Event,
    breaks:[]Break_Event, // what broke the breakables: the hits of the step, what expired and breakables_strain
}

Stats :: struct {
    bodies,shapes,contacts,joints,characters,fluids:int,
    breakables,pieces:int,
    awake_bodies,active_contacts,constraints,islands:int,
    colors,overflow_constraints:int,
    // Requests refused because a capacity was exhausted, since the world was created.
    body_capacity_exhausted,shape_capacity_exhausted,contact_capacity_exhausted,joint_capacity_exhausted:int,
    manifold_capacity_exhausted,event_capacity_exhausted,geometry_capacity_exhausted:int,
    character_capacity_exhausted,fluid_capacity_exhausted:int,
    // Breakables, breaks and cuts refused because a capacity of theirs or of the world ran out.
    breakable_capacity_exhausted:int,
    // Shapes a bullet went through in a step beyond the CCD_OVERLAP_CAPACITY it keeps, without their overlap
    // events, since the world was created.
    ccd_overlaps_dropped:int,
}

// Milliseconds spent in each stage of the last step.
Profile :: struct {
    pairs:f32,        // broad phase
    narrow_phase:f32,
    prepare:f32,      // islands, colors and constraint setup
    solve:f32,
    finalize:f32,     // poses, boxes, bullets and the tree
    sleep:f32,        // events, joint breaks, sleeping and breakables
}
