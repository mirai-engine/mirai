package physics

import "core:hash/xxhash"
import "core:math/linalg"
import "core:mem"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/spatial"
import sim "plugins:physics/runtime/sim"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import "mirai:std/jobs"

// Capacities of the simulation, read when its world is made; zero takes the
// default. Where things fall is a Gravity of the world. Changing a capacity afterwards has no effect.
@(storage,setting)
Physics_Settings :: struct {
    bodies:i32 `mirai:"section=Capacity,advanced"`,
    shapes,contacts,joints,characters:i32 `mirai:"advanced"`,
    hulls,meshes,heightfields:i32 `mirai:"advanced"`,
    fluids:i32 `mirai:"advanced"`, // Fluid
    breakables,pieces,bonds:i32 `mirai:"advanced"`, // of what breaks: a Destructible is a breakable of pieces held by bonds

    events:i32 `mirai:"advanced"`, // of each kind per tick: contacts, sleep, hits
    substeps:i32 `mirai:"section=Simulation,advanced"`,
}

// The what of the simulation of a world: the sim.World and the links from
// entities to what was made for them. Copied state by state, with the
// geometry its bodies need: what a slot of geometry holds is known by a hash
// of it, so a copy into a world that has it already does not compare it.
@(storage,copy="state_copy",copy_kept="state_copy_kept",swap="state_swap",free="state_destroy",shared,reset="state_reset")
Physics_State :: struct {
    ready:bool,
    world:sim.World,
    links:core.Entity_Map(Link),        // by entity with a body, a collider, a character or a proxy
    // Of the chunks of links.values: the revision of the world at their last write, as the pools of the
    // simulation are stamped. A copy takes the chunks that differ, and the entities and rows with any.
    link_stamps:[dynamic]u64,
    joints:core.Entity_Map(Joint_Link), // by entity with a Joint
    fluids:core.Entity_Map(Fluid_Link), // by entity with a Fluid
    fluids_synced:u64, // the versions of the tables the fluids were last made from
    world_body:sim.Body_Handle, // the static body joints to the world hold on to
    geometry:[dynamic]Geometry_Mark, // by slot of the hulls, then the meshes, then the heightfields of the world
    sources:[dynamic]Geometry_Source, // by slot as geometry: what it was made from, to share it
    source_stamps:[dynamic]u64, // of the chunks of sources, as link_stamps
    pieces:[dynamic]Piece, // runs of Link.pieces; a zero entry is free
    forwarded:[6]int, // events of the simulation already sent
    pass:u32,
    epoch:u32, // invalidates host caches when simulation storage is replaced
    synced:u64, // the versions of the tables and assets the bodies were last made from
    rows_seen:[4]core.Seen, // of Rigid_Body, Collider, Character and Volume, at the end of the last sync that reached every body
    sealed_key:u64, // what a sync reads besides the Transform values, at the last one; 0 makes the next whole
    transforms_seen:core.Seen, // of Transform, at the end of the last tick that left the bodies as their rows
    unmade:bool, // the last sync left a body or character unmade, which a whole sync tries again
    sealed:[dynamic]Sealed_Body, // scratch of sealed_sync, as long as the rows of the bodies
    visited:[dynamic]u32, // scratch of a sync, by link: the pass that synced it
    proxies:[dynamic]core.Entity, // the entities of the Proxy links
    held:[dynamic]Held, // what a manipulation or a pose target steers
    owned:[dynamic]Owned, // by slot of the bodies of the world: those another library owns (owned.odin)
    owned_stamps:[dynamic]u64, // of the chunks of owned, as link_stamps
    // The links, by where they are, whose rows the next step brings back besides those of the bodies it moves
    // (link_touch); with touched_all, every link.
    touched:[dynamic]u32,
    touched_all:bool,
    collision:Collision_Settings, // those the filters of the shapes were made with
    pushes_set:bool, // the simulation has the push rules of collision
    own_gravity:bool, // the bodies fall with the gravity of their place (gravity_apply)
    gravity:Gravity_Fields, // what they fall with; not copied, made again from the tables of its world
    targets_seen:core.Seen, // of core.Pose_Target, by physics_pose_targets
    stats:Physics_Stats,
}

Physics_Stats :: struct {
    bodies_created,bodies_destroyed:u64,
    shapes_created,shapes_destroyed:u64,
    characters_created,characters_destroyed:u64,
    teleports:u64,
}

@(private)
Link_Kind :: enum u8 {None,Body,Compound,Character,Proxy}

// An entity a sync of the sealed Transform rows goes through, by where a whole sync reaches it.
@(private)
Sealed_Body :: struct {order:u64,entity:core.Entity}

// What a slot of geometry holds: the generation it was hashed at and the hash.
@(private)
Geometry_Mark :: struct {generation,revision:u32,hash:u64} // revision: of a hull rebuilt under its handle

// A convex piece of a Hull collider whose mesh has several, after the first: its own hull and shape on the
// body of the link.
@(private)
Piece :: struct {shape:sim.Shape_Handle,hull:sim.Hull_Handle}

@(private)
Piece_Run :: struct {first,count:u32}

// What the simulation made for one entity. Whether its rows changed is told by their stamps, and
// what its shapes were made from by made.
@(private)
Link :: struct {
    kind:Link_Kind,
    body:sim.Body_Handle,
    shape:sim.Shape_Handle,
    hull:sim.Hull_Handle,
    pieces:Piece_Run, // the pieces after the first, in Physics_State.pieces
    mesh:sim.Mesh_Handle,
    heightfield:sim.Heightfield_Handle,
    character:sim.Character_Handle,
    owner:core.Entity, // compound: the ancestor whose body carries the shape
    made:u64, // a hash of what its shapes or its capsule were made from (shape_key): another asks to make them again
}

// Who holds a body, heading for a pose in every step: a manipulation (a tool, a
// ragdoll) or a following pose target, which goes first and holds it as kinematic.
// A character a following target leads is put at its pose after every step.
@(private)
Hold_Source :: enum u8 {Manipulation,Target}

// What steers a body or a character: the sources that hold it, and the pose target it took.
@(private)
Held :: struct {
    entity:core.Entity,
    by:bit_set[Hold_Source;u8],
    type_before:Body_Type, // what the body was before it was held as kinematic
    release:bool,          // the following manipulation lets go once its pose is reached
    follow:bool,           // the manipulation holds the body as kinematic; else a spring pulls it
    placed:u32,            // the core.Pose_Target.placed it took
    pose:[Hold_Source]sim.Transform,
    linear:[3]f32,         // of a character a following target leads
    pull:sim.Joint_Handle, // the spring from the world body of a manipulation that pulls
}

@(private)
Shown :: struct {
    mesh:base.Asset_Id,
    shape:host.Shape,
    revision:u64, // asset revision; zero for immutable generated IDs
    generated:bool,
}

@(private)
Joint_Link :: struct {
    joint:sim.Joint_Handle,
    a,b:sim.Body_Handle,
    applied:Joint,
    frames:Joint_Frames,
    local:core.Transform, // of the entity of the joint, when it was made
    refused:bool,
}

// What of the Joint_State a joint is made from: another writer changing it
// makes the joint again.
@(private)
Joint_Frames :: struct {
    taken:bool,
    b_anchor:[3]f32,
    b_rotation:mm.Quat,
}

Body_Request_Kind :: enum u8 {
    Teleport,  // position and rotation in the world: what core.place asks of a body
    Velocity,  // linear and angular
    Impulse,   // linear at the center of mass or at point; angular
    Force,
    Area_Force,   // on every body in a volume; it names no entity
    Area_Impulse,
    Area_Strain,  // of the breakables in a volume, once the step ran (strain_area)
    Kinematic, // the pose a kinematic body reaches in the tick
    Manipulate,
    Release_Manipulation,
}

Body_Request :: struct {
    entity:core.Entity,
    kind:Body_Request_Kind,
    position:[3]f32,
    rotation:mm.Quat,
    linear,angular:[3]f32,
    point:[3]f32,
    at_point,override:bool,
    // Of an area request: the volume placed at position, rotation and scale, whose weight rises over
    // blend metres inside its border; linear is where it pushes, zero for away from its center. The
    // points of an Outline are those of the Spline of entity.

    area:volume.Volume,
    scale:[3]f32,
    blend:f32,
    strength:f32,
    falloff:sim.Radial_Falloff,
    filter:Query_Filter,
    falloff_range:Weight_Range, // the zero value is {0,1}
    noise:Field_Noise,
}

// The game moves bodies and characters by pushing here; the simulation takes
// the requests at the start of its next step.
@(storage,queue)
Body_Requests :: struct {
    queue:core.Queue(Body_Request),
}

@(private)
teleport :: proc(requests:^Body_Requests,e:core.Entity,position:[3]f32,rotation:mm.Quat=1) {
    core.push(&requests.queue,Body_Request{entity=e,kind=.Teleport,position=position,rotation=rotation})
}
set_velocity :: proc(requests:^Body_Requests,e:core.Entity,linear:[3]f32,angular:[3]f32={}) {
    core.push(&requests.queue,Body_Request{entity=e,kind=.Velocity,linear=linear,angular=angular})
}
// N s at the center of mass, or at a world point.
apply_impulse :: proc(requests:^Body_Requests,e:core.Entity,impulse:[3]f32,point:Maybe([3]f32)=nil) {
    p,at_point:=point.?
    core.push(&requests.queue,Body_Request{entity=e,kind=.Impulse,linear=impulse,point=p,at_point=at_point})
}
apply_angular_impulse :: proc(requests:^Body_Requests,e:core.Entity,impulse:[3]f32) {
    core.push(&requests.queue,Body_Request{entity=e,kind=.Impulse,angular=impulse})
}
apply_force :: proc(requests:^Body_Requests,e:core.Entity,force:[3]f32,point:Maybe([3]f32)=nil) {
    p,at_point:=point.?
    core.push(&requests.queue,Body_Request{entity=e,kind=.Force,linear=force,point=p,at_point=at_point})
}
apply_torque :: proc(requests:^Body_Requests,e:core.Entity,torque:[3]f32) {
    core.push(&requests.queue,Body_Request{entity=e,kind=.Force,angular=torque})
}
Radial_Falloff :: sim.Radial_Falloff
Weight_Range :: sim.Weight_Range
Field_Noise :: sim.Field_Noise
// A force (N) on every body whose center of mass is in a volume placed at pose, in this tick: a blast, a
// gust, a magnet. With impulse, an impulse (N s), or a change of velocity (m/s) with velocity_change. It
// pushes away from the center of the volume, or along the up of a Plane (a negative strength pulls the
// other way); with `along`, that way of the world instead. The body gets the strength by the weight of the volume
// where it is, 1 inside and rising over blend metres from the border, through the falloff curve; range
// and noise scale it. A pose without rotation or scale is one that neither turns nor scales.
apply_area :: proc(requests:^Body_Requests,area:volume.Volume,pose:mm.Transform,strength:f32,along:[3]f32={},impulse:=false,velocity_change:=false,blend:f32=0,falloff:Radial_Falloff=.Linear,filter:=QUERY_FILTER_DEFAULT,range:Weight_Range={},noise:Field_Noise={},outline_of:=core.NONE) {
    core.push(&requests.queue,Body_Request{
        entity=outline_of,kind=impulse?.Area_Impulse:.Area_Force,area=area,position=pose.position,rotation=pose.rotation,scale=pose.scale,blend=blend,
        strength=strength,linear=along,override=velocity_change,falloff=falloff,filter=filter,falloff_range=range,noise=noise,
    })
}
// The kinematic body takes the velocity that reaches the pose in one tick, so it pushes what it touches.
move_kinematic :: proc(requests:^Body_Requests,e:core.Entity,position:[3]f32,rotation:mm.Quat=1) {
    core.push(&requests.queue,Body_Request{entity=e,kind=.Kinematic,position=position,rotation=rotation})
}
// Holds a body toward a world pose until manipulation_end. A dynamic body stays dynamic: a spring of bounded
// force pulls it, so it collides and pushes with at most PULL_WEIGHTS times its weight. A static or
// kinematic body, or any with follow (a pose by design: an animated ragdoll), is held as kinematic and
// reaches the pose at the solver's speed limits, pushing what it touches.
manipulation_target :: proc(requests:^Body_Requests,e:core.Entity,position:[3]f32,rotation:mm.Quat=1,follow:=false) {
    core.push(&requests.queue,Body_Request{entity=e,kind=.Manipulate,position=position,rotation=rotation,override=follow})
}
// Lets go: a pulled body at once, a held one once it reaches its pose. A body dynamic again keeps its
// velocity; any other stops.
manipulation_end :: proc(requests:^Body_Requests,e:core.Entity) {
    core.push(&requests.queue,Body_Request{entity=e,kind=.Release_Manipulation})
}

// a and b are the entities of the bodies; collider_a and collider_b those of the colliders that touched,
// another entity when the collider is a child of the body.
Contact_Begin :: struct {
    a,b:core.Entity,
    collider_a,collider_b:core.Entity,
    point,normal:[3]f32, // normal from a to b
    impulse:f32,         // N s applied in the step
}
Contact_End :: struct {a,b,collider_a,collider_b:core.Entity}
// One for each side of a pair that overlaps: entity is the body and collider the collider of that side.
// crossed: a fast body went through the other collider within the tick, which begins and ends the pair at once.
Overlap_Event :: struct {entity,other,collider,other_collider:core.Entity,crossed:bool}
Body_Event :: struct {entity:core.Entity}
Joint_Break :: struct {
    entity:core.Entity, // of the Joint
    force:f32,          // N
    torque:f32,         // N m
}

// What happened in the last tick. The simulation clears and fills it at the
// start of its step; the functions that run after it read items. An entity
// is NONE for a body that belongs to none (those of a destructible name the destructible).
@(storage)
Physics_Events :: struct {
    contact_begin:core.Events(Contact_Begin),
    contact_end:core.Events(Contact_End),
    overlap_begin:core.Events(Overlap_Event),
    overlap_end:core.Events(Overlap_Event),
    sleep:core.Events(Body_Event),
    wake:core.Events(Body_Event),
    joint_break:core.Events(Joint_Break),
}

@(private)
events_reserve :: proc(events:^Physics_Events,capacity:int) -> bool {
    if capacity>max(int)/2 {return false}
    total:=capacity*2
    return reserve(&events.contact_begin.items,total)==nil && reserve(&events.contact_end.items,total)==nil &&
        reserve(&events.overlap_begin.items,total)==nil && reserve(&events.overlap_end.items,total)==nil &&
        reserve(&events.sleep.items,total)==nil && reserve(&events.wake.items,total)==nil &&
        reserve(&events.joint_break.items,capacity)==nil
}

// The gravity of the world where no Gravity has a border, m/s2; that of a
// body is gravity_of_entity.
gravity :: proc(physics:core.Ref(Physics_State)) -> [3]f32 {
    if physics.ptr==nil || !physics.ready {return sim.world_desc_default().gravity}
    return physics.world.gravity
}

// The body of an entity that has a Rigid_Body, a Collider or a Character; zero until the tick after they appear.
body_of :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> sim.Body_Handle {
    link:=link_find(physics.ptr,e)
    if link==nil {return {}}
    if link.kind==.Character {return sim.character_body(&physics.world,link.character)}
    return link.body
}

// What the simulation holds of a body: that of an entity (body_of), of a Hit, of a library.
Body_Info :: struct {
    type:Body_Type, // Kinematic also while another owner or a manipulation holds it
    pose:mm.Transform, // rigid
    linear:[3]f32 `mirai:"unit=m/s"`,
    angular:[3]f32 `mirai:"unit=rad/s"`,
    awake:bool,
    contacts:int, // the shapes an awake body touches after the last step
}

// False for a body that is gone, or while the simulation is not ready.
body_info :: proc(physics:core.Ref(Physics_State),body:Body_Handle) -> (info:Body_Info,ok:bool) {
    if physics.ptr==nil || !physics.ready || !sim.body_valid(&physics.world,body) {return}
    w:=&physics.world
    pose:=sim.body_transform(w,body)
    return {
        type=sim.body_type(w,body),pose={pose.p,pose.q,{1,1,1}},
        linear=sim.body_linear_velocity(w,body),angular=sim.body_angular_velocity(w,body),
        awake=sim.body_is_awake(w,body),contacts=sim.body_contacts(w,body,nil),
    },true
}

// The hash of the whole simulation, the one core.Simulation_Hash records: two worlds whose simulations would
// step alike give the same. Zero while it is not ready.
state_hash :: proc(physics:core.Ref(Physics_State)) -> u64 {
    if physics.ptr==nil || !physics.ready {return 0}
    return sim.world_hash(&physics.world)
}

collider_debug_draw :: proc(physics:core.Ref(Physics_State),e:core.Entity,out:^sim.Debug_Draw) -> bool {
    out.line_count,out.point_count,out.lines_dropped,out.points_dropped=0,0,0,0
    if !physics.ready {return false}
    link:=link_find(physics.ptr,e)
    if link==nil || !sim.shape_debug_draw(&physics.world,link.shape,out) {return false}
    for piece in pieces_of(physics.ptr,link) {
        rest:=sim.Debug_Draw{lines=out.lines[min(out.line_count,len(out.lines)):],points=out.points[min(out.point_count,len(out.points)):]}
        if !sim.shape_debug_draw(&physics.world,piece.shape,&rest) {continue}
        out.line_count+=rest.line_count;out.point_count+=rest.point_count
        out.lines_dropped+=rest.lines_dropped;out.points_dropped+=rest.points_dropped
    }
    return true
}

collider_ready :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> bool {
    if !physics.ready {return false}
    link:=link_find(physics.ptr,e)
    return link!=nil && sim.shape_valid(&physics.world,link.shape)
}

collider_bounds :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> (bounds:mm.Aabb,ok:bool) {
    if !physics.ready {return}
    link:=link_find(physics.ptr,e)
    if link==nil || !sim.shape_valid(&physics.world,link.shape) {return}
    bounds=sim.shape_bounds(&physics.world,link.shape)
    for piece in pieces_of(physics.ptr,link) {
        if !sim.shape_valid(&physics.world,piece.shape) {continue}
        more:=sim.shape_bounds(&physics.world,piece.shape)
        bounds.min,bounds.max=linalg.min(bounds.min,more.min),linalg.max(bounds.max,more.max)
    }
    return bounds,true
}

geometry_budget :: proc(physics:core.Ref(Physics_State),kind:Collider_Kind) -> (used,capacity:int) {
    if !physics.ready {return}
    switch kind {
    case .Hull:
        capacity=len(physics.world.hulls)
        for slot in physics.world.hulls {if slot.generation&1!=0 {used+=1}}
    case .Mesh:
        capacity=len(physics.world.meshes)
        for slot in physics.world.meshes {if slot.generation&1!=0 {used+=1}}
    case .Heightfield:
        capacity=len(physics.world.heightfields)
        for slot in physics.world.heightfields {if slot.generation&1!=0 {used+=1}}
    case .Box,.Sphere,.Capsule,.Cylinder,.External:
    }
    return
}

// The entity a body follows; NONE for a body created outside the components.
entity_of :: proc(physics:core.Ref(Physics_State),body:sim.Body_Handle) -> core.Entity {
    return core.Entity(sim.body_user_data(&physics.world,body))
}

// Compound colliders name their owning body; characters cannot be held.
manipulation_owner :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> core.Entity {
    if physics.ptr==nil || !physics.ready {return core.NONE}
    owner:=e
    l:=link_find(physics.ptr,e)
    if l!=nil && l.kind==.Compound {
        owner=l.owner
        l=link_find(physics.ptr,owner)
    }
    if l==nil || l.kind!=.Body && l.kind!=.Proxy || !sim.body_valid(&physics.world,l.body) {return core.NONE}
    return owner
}

// entity is the body that was hit and collider the entity of its collider, another one when the collider
// is a child of the body. overlap: the shape does not block the query. A query that starts inside a shape
// reports distance zero and a zero normal.
Hit :: struct {
    entity,collider:core.Entity,
    point,normal:[3]f32,
    distance:f32,
    overlap:bool,
    body:sim.Body_Handle,
    shape:sim.Shape_Handle,
}

// Most hits a list query writes, and most shapes an overlap looks at.
QUERY_HIT_CAPACITY :: 64
OVERLAP_CAPACITY :: 256

@(private)
hit_of :: proc(world:^sim.World,found:sim.Ray_Hit,max_distance:f32) -> Hit {
    return {
        entity=core.Entity(sim.body_user_data(world,found.body)),collider=core.Entity(sim.shape_user_data(world,found.shape)),
        point=found.point,normal=found.normal,distance=found.fraction*max_distance,overlap=found.overlap,body=found.body,shape=found.shape,
    }
}

@(private)
query_prepare :: proc(physics:core.Ref(Physics_State),direction:[3]f32,max_distance:f32,ignore:core.Entity,filter:Query_Filter) -> (translation:[3]f32,prepared:Query_Filter,ok:bool) {
    if physics.ptr==nil || !physics.ready || !(max_distance>0 && max_distance<=max(f32)) {return}
    length:=linalg.length(direction)
    if !(length>1e-12 && length<=max(f32)) {return}
    prepared=filter
    if ignore!=core.NONE {prepared.ignore_body=body_of(physics,ignore)}
    return direction*(max_distance/length),prepared,true
}

// The closest shape that blocks the ray. The direction needs no particular length.
raycast :: proc(physics:core.Ref(Physics_State),origin,direction:[3]f32,max_distance:f32=1000,ignore:=core.NONE,filter:=QUERY_FILTER_DEFAULT) -> (hit:Hit,ok:bool) {
    translation,prepared:=query_prepare(physics,direction,max_distance,ignore,filter) or_return
    found:=sim.ray_cast_closest(&physics.world,origin,translation,prepared) or_return
    return hit_of(&physics.world,found,max_distance),true
}

// The ray against the colliders of one entity as if its body were at a pose, whatever they collide with: where
// it was at another time, as the lag compensation of the network tells (physics_multiplayer).
raycast_at :: proc(physics:core.Ref(Physics_State),e:core.Entity,position:[3]f32,rotation:mm.Quat,origin,direction:[3]f32,max_distance:f32=1000) -> (hit:Hit,ok:bool) {
    translation,_:=query_prepare(physics,direction,max_distance,core.NONE,{}) or_return
    found:=sim.body_ray_cast(&physics.world,body_of(physics,e),{position,rotation},origin,translation) or_return
    return hit_of(&physics.world,found,max_distance),true
}

// The shapes along the ray, nearest first: by channel the ones it only overlaps (when filter.overlaps)
// up to the first that blocks, by object type all of them. Writes up to QUERY_HIT_CAPACITY, keeping the
// nearest, and returns how many it wrote.
raycast_all :: proc(physics:core.Ref(Physics_State),origin,direction:[3]f32,hits:[]Hit,max_distance:f32=1000,ignore:=core.NONE,filter:=QUERY_FILTER_DEFAULT) -> int {
    translation,prepared,ok:=query_prepare(physics,direction,max_distance,ignore,filter)
    if !ok {return 0}
    found:[QUERY_HIT_CAPACITY]sim.Ray_Hit
    count:=sim.ray_cast_all(&physics.world,origin,translation,found[:min(len(hits),len(found))],prepared)
    for i in 0..<count {hits[i]=hit_of(&physics.world,found[i],max_distance)}
    return count
}

// A shape that moves without turning; a capsule or a cylinder lies along the Y axis of its rotation.
Sweep_Shape :: union {Sphere,Capsule,Box,Cylinder}

@(private)
sweep_geometry :: proc "contextless" (shape:Sweep_Shape) -> (geometry:sim.Geometry) {
    switch g in shape {
    case Sphere: geometry=g
    case Capsule: geometry=g
    case Box: geometry=g
    case Cylinder: geometry=g
    }
    return
}

// The first shape that blocks a sphere, capsule or box moving from `position` along `direction`: the
// point where they meet and how far the shape went.
sweep :: proc(physics:core.Ref(Physics_State),shape:Sweep_Shape,position:[3]f32,rotation:mm.Quat,direction:[3]f32,max_distance:f32,ignore:=core.NONE,filter:=QUERY_FILTER_DEFAULT) -> (hit:Hit,ok:bool) {
    if shape==nil {return}
    translation,prepared:=query_prepare(physics,direction,max_distance,ignore,filter) or_return
    found:=sim.shape_cast_closest(&physics.world,sweep_geometry(shape),{position,rotation},translation,prepared) or_return
    return hit_of(&physics.world,found,max_distance),true
}

// What the moving shape touches along the way, as raycast_all.
sweep_all :: proc(physics:core.Ref(Physics_State),shape:Sweep_Shape,position:[3]f32,rotation:mm.Quat,direction:[3]f32,hits:[]Hit,max_distance:f32,ignore:=core.NONE,filter:=QUERY_FILTER_DEFAULT) -> int {
    if shape==nil {return 0}
    translation,prepared,ok:=query_prepare(physics,direction,max_distance,ignore,filter)
    if !ok {return 0}
    found:[QUERY_HIT_CAPACITY]sim.Ray_Hit
    count:=sim.shape_cast_all(&physics.world,sweep_geometry(shape),{position,rotation},translation,found[:min(len(hits),len(found))],prepared)
    for i in 0..<count {hits[i]=hit_of(&physics.world,found[i],max_distance)}
    return count
}

// The nearest point of a shape that blocks the query, within max_distance of `point`; inside a shape the
// distance is zero. normal goes from the shape toward the point.
Closest :: struct {
    entity,collider:core.Entity,
    point,normal:[3]f32,
    distance:f32,
    body:sim.Body_Handle,
    shape:sim.Shape_Handle,
}
closest_point :: proc(physics:core.Ref(Physics_State),point:[3]f32,max_distance:f32,ignore:=core.NONE,filter:=QUERY_FILTER_DEFAULT) -> (closest:Closest,ok:bool) {
    if physics.ptr==nil || !physics.ready || !(max_distance>=0 && max_distance<=max(f32)) {return}
    prepared:=filter
    if ignore!=core.NONE {prepared.ignore_body=body_of(physics,ignore)}
    found:=sim.closest_point(&physics.world,point,max_distance,prepared) or_return
    return {
        entity=core.Entity(sim.body_user_data(&physics.world,found.body)),collider=core.Entity(sim.shape_user_data(&physics.world,found.shape)),
        point=found.point,normal=found.normal,distance=found.distance,body=found.body,shape=found.shape,
    },true
}

// Entities whose shapes touch the volume, each once. complete is false when more shapes than
// OVERLAP_CAPACITY touch it or more entities than results holds.
overlap_sphere :: proc(physics:core.Ref(Physics_State),center:[3]f32,radius:f32,results:[]core.Entity,filter:=QUERY_FILTER_DEFAULT) -> (count:int,complete:bool) {
    return overlap(physics,sim.Sphere{radius},{center,1},results,filter)
}
overlap_box :: proc(physics:core.Ref(Physics_State),center,half_extents:[3]f32,rotation:mm.Quat,results:[]core.Entity,filter:=QUERY_FILTER_DEFAULT) -> (count:int,complete:bool) {
    return overlap(physics,sim.Box{half_extents},{center,rotation},results,filter)
}
overlap_capsule :: proc(physics:core.Ref(Physics_State),center:[3]f32,radius,half_height:f32,rotation:mm.Quat,results:[]core.Entity,filter:=QUERY_FILTER_DEFAULT) -> (count:int,complete:bool) {
    return overlap(physics,sim.Capsule{radius,half_height},{center,rotation},results,filter)
}
overlap_cylinder :: proc(physics:core.Ref(Physics_State),center:[3]f32,radius,half_height:f32,rotation:mm.Quat,results:[]core.Entity,filter:=QUERY_FILTER_DEFAULT) -> (count:int,complete:bool) {
    return overlap(physics,sim.Cylinder{radius,half_height},{center,rotation},results,filter)
}

@(private)
overlap :: proc(physics:core.Ref(Physics_State),geometry:sim.Geometry,transform:sim.Transform,results:[]core.Entity,filter:Query_Filter) -> (count:int,complete:bool) {
    if physics.ptr==nil || !physics.ready {return}
    world:=&physics.world
    shapes:[OVERLAP_CAPACITY]sim.Shape_Handle
    found:=sim.overlap_shape(world,geometry,transform,shapes[:],filter)
    complete=found<=len(shapes)
    each: for shape in shapes[:min(found,len(shapes))] {
        e:=core.Entity(sim.body_user_data(world,sim.shape_body(world,shape)))
        if e==core.NONE {continue}
        for seen in results[:count] {
            if seen==e {continue each}
        }
        if count>=len(results) {
            complete=false
            break
        }
        results[count]=e
        count+=1
    }
    return
}

// Makes dst the world of src: the same bodies, geometry and links.
state_copy :: proc(dst,src:^Physics_State) -> bool {_,ok:=state_copy_as(dst,src,false);return ok}

// The copy a history keeps to copy back later: the pools of its simulation
// only as large as those of src are used, not as their capacities.
state_copy_kept :: proc(dst,src:^Physics_State) -> bool {_,ok:=state_copy_as(dst,src,true);return ok}

// Returns the bytes it wrote of the simulation and of the links, the geometry sources and the owned bodies:
// those of the chunks written since the copy dst holds, or all of them from another timeline.
@(private)
state_copy_as :: proc(dst,src:^Physics_State,kept:bool) -> (written:int,ok:bool) {
    if dst==src {return 0,true}
    if !core.entity_map_copy(&dst.joints,&src.joints) || !core.entity_map_copy(&dst.fluids,&src.fluids) {return}
    if !array_copy(&dst.pieces,src.pieces[:]) || !array_copy(&dst.proxies,src.proxies[:]) || !array_copy(&dst.held,src.held[:]) {return}
    clear(&dst.visited)
    dst.touched_all=true
    dst.world_body,dst.pass,dst.stats,dst.collision,dst.targets_seen,dst.rows_seen=src.world_body,src.pass,src.stats,src.collision,src.targets_seen,src.rows_seen
    dst.forwarded={}
    if !src.ready {
        if dst.ready {sim.world_destroy(&dst.world)}
        dst.ready=false
        dst.epoch=max(dst.epoch,src.epoch)+1;if dst.epoch==0 {dst.epoch=1}
        return stamped_state_copy(dst,src,true)
    }
    wanted:=src.world.desc
    wanted.parallel_user=nil
    wanted.allocator=context.allocator
    if dst.ready {
        have:=dst.world.desc
        have.parallel_user=nil
        have.allocator=wanted.allocator
        if have!=wanted || dst.world.kept!=kept || kept && !sim.world_state_fits(&dst.world,&src.world) {
            sim.world_destroy(&dst.world)
            dst.ready=false
        }
    }
    remade:=!dst.ready
    if remade {
        clear(&dst.geometry)
        if !(kept?sim.world_kept_init(&dst.world,&src.world,wanted.allocator):sim.world_init(&dst.world,wanted)) {
            return
        }
        dst.ready=true
    }
    // Of one timeline, as the simulation copies its pools: what dst holds of src since they were last alike.
    written=stamped_state_copy(dst,src,remade || dst.world.lineage!=src.world.lineage) or_return
    if !geometry_copy(dst,src) {return}
    dst.pushes_set=src.pushes_set
    dst.own_gravity=src.own_gravity
    dst.gravity.index.made=false
    pools,copied:=sim.world_state_copy(&dst.world,&src.world)
    if !copied {return}
    dst.synced,dst.fluids_synced=src.synced,src.fluids_synced
    dst.sealed_key,dst.transforms_seen,dst.unmade=0,{},src.unmade
    dst.epoch=max(dst.epoch,src.epoch)+1;if dst.epoch==0 {dst.epoch=1}
    return written+pools,true
}

// The links, the geometry sources and the owned bodies of src in dst, chunk by chunk.
@(private)
stamped_state_copy :: proc(dst,src:^Physics_State,whole:bool) -> (written:int,ok:bool) {
    d,s:=&dst.links,&src.links
    had:=len(d.values)
    written=stamped_copy(&d.values,&dst.link_stamps,s.values[:],src.link_stamps[:],whole) or_return
    if written>0 || len(s.values)<had {
        if !array_copy(&d.entities,s.entities[:]) || !array_copy(&d.rows,s.rows[:]) {return}
        written+=len(s.entities)*size_of(core.Entity)+len(s.rows)*size_of(i32)
    }
    sources:=stamped_copy(&dst.sources,&dst.source_stamps,src.sources[:],src.source_stamps[:],whole) or_return
    owned:=stamped_copy(&dst.owned,&dst.owned_stamps,src.owned[:],src.owned_stamps[:],whole) or_return
    return written+sources+owned,true
}

// dst as src, taking the chunks stamped otherwise in src, or all with whole. Returns the bytes written.
@(private)
stamped_copy :: proc(dst:^[dynamic]$T,dst_stamps:^[dynamic]u64,src:[]T,src_stamps:[]u64,whole:bool) -> (written:int,ok:bool) {
    had:=len(dst)
    if resize(dst,len(src))!=nil || !stamps_fit(dst_stamps,had,len(src)) {return}
    arrays:=[1]base.Chunk_Copy{{mem.slice_to_bytes(dst[:]),mem.slice_to_bytes(src),size_of(T)}}
    return base.chunks_copy(arrays[:],dst_stamps[:],src_stamps,len(src),whole || len(src_stamps)<base.chunks_of(len(src))),true
}

// Stamps for the chunks of count slots; when there were had, those of the slots it gains at zero, so a copy
// takes them.
@(private)
stamps_fit :: proc(stamps:^[dynamic]u64,had,count:int) -> bool {
    if resize(stamps,base.chunks_of(count))!=nil {return false}
    if count>had {for &stamp in stamps[min(had>>base.CHUNK_BITS,len(stamps)):] {stamp=0}}
    return true
}

// A slot of an array of the state was written: a copy takes its chunk again.
@(private)
slot_stamp :: proc(state:^Physics_State,stamps:[]u64,slot:int) {
    if k:=slot>>base.CHUNK_BITS;slot>=0 && k<len(stamps) {stamps[k]=state.world.revision}
}

state_swap :: proc(a,b:^Physics_State) {
    if a==b {return}
    epoch:=max(a.epoch,b.epoch)+1;if epoch==0 {epoch=1}
    a^,b^=b^,a^
    a.epoch,b.epoch=epoch,epoch
    // A world put back from its history through a staged copy goes on with the timeline of the history.
    if a.ready && b.ready {
        sim.world_succeed(&a.world,&b.world)
        sim.world_succeed(&b.world,&a.world)
    }
}

// Frees the simulation of a world.
state_destroy :: proc(state:^Physics_State) {
    if state.ready {sim.world_destroy(&state.world)}
    core.entity_map_destroy(&state.links);core.entity_map_destroy(&state.joints);core.entity_map_destroy(&state.fluids);delete(state.geometry);delete(state.sources);delete(state.pieces)
    delete(state.sealed);delete(state.proxies);delete(state.touched);delete(state.owned);delete(state.held);delete(state.visited)
    delete(state.link_stamps);delete(state.source_stamps);delete(state.owned_stamps)
    volume.index_destroy(&state.gravity.index)
    state^={}
}

// Forgets the simulation of a world whose entities were all replaced, as loading a game does: the next step makes it again from the rows.
state_reset :: proc(state:^Physics_State) {
    if state.ready {sim.world_destroy(&state.world)}
    state.ready=false
    clear(&state.geometry)
    clear(&state.sources);clear(&state.source_stamps)
    clear(&state.pieces)
    clear(&state.proxies)
    clear(&state.held)
    clear(&state.touched)
    clear(&state.owned);clear(&state.owned_stamps)
    core.entity_map_clear(&state.links);core.entity_map_clear(&state.joints);core.entity_map_clear(&state.fluids)
    state.world_body={}
    state.forwarded={}
    state.gravity.index.made=false
    state.epoch+=1
}

// Shared geometry of src, slot by slot, in dst. The state copy does not hold
// it. A slot is copied when what it holds differs: by its generation and the
// hash of its geometry, each taken once per generation in its own world. The
// shapes that use a slot are counted by the state copy that follows.
@(private)
geometry_copy :: proc(dst_state,src_state:^Physics_State) -> bool {
    dst,src:=&dst_state.world,&src_state.world
    if !geometry_marks(src_state) || !geometry_marks(dst_state) {return false}
    a:=dst.allocator
    hulls,meshes:=len(src.hulls),len(src.meshes)
    for i in 0..<min(len(src.hulls),len(dst.hulls)) {
        s,d:=&src.hulls[i],&dst.hulls[i]
        live:=s.generation&1!=0
        if live && d.generation==s.generation && dst_state.geometry[i]==src_state.geometry[i] {continue}
        next:sim.Hull
        if live {ok:bool;next,ok=hull_clone(s.hull,a);if !ok {return false}}
        if d.generation&1!=0 {sim.hull_free(&d.hull,a)}
        d.generation,d.revision=s.generation,s.revision
        d.hull=next
        dst_state.geometry[i]=src_state.geometry[i]
    }
    for i in 0..<min(len(src.meshes),len(dst.meshes)) {
        s,d:=&src.meshes[i],&dst.meshes[i]
        live:=s.generation&1!=0
        if live && d.generation==s.generation && dst_state.geometry[len(dst.hulls)+i]==src_state.geometry[hulls+i] {continue}
        next:sim.Mesh
        if live {ok:bool;next,ok=mesh_clone(s.mesh,a);if !ok {return false}}
        if d.generation&1!=0 {sim.mesh_release(&d.mesh,a)}
        d.generation=s.generation
        d.mesh=next
        dst_state.geometry[len(dst.hulls)+i]=src_state.geometry[hulls+i]
    }
    for i in 0..<min(len(src.heightfields),len(dst.heightfields)) {
        s,d:=&src.heightfields[i],&dst.heightfields[i]
        live:=s.generation&1!=0
        if live && d.generation==s.generation && dst_state.geometry[len(dst.hulls)+len(dst.meshes)+i]==src_state.geometry[hulls+meshes+i] {continue}
        next:sim.Heightfield
        if live {
            next=s.field;next.heights=nil;next.disabled_borders=nil;next.holes=nil
            ok:bool
            next.heights,ok=cloned(s.field.heights,a);if !ok {return false}
            next.disabled_borders,ok=cloned(s.field.disabled_borders,a);if !ok {delete(next.heights,a);return false}
            next.holes,ok=cloned(s.field.holes,a);if !ok {delete(next.heights,a);delete(next.disabled_borders,a);return false}
        }
        delete(d.field.heights,a)
        delete(d.field.disabled_borders,a)
        delete(d.field.holes,a)
        d.field=next
        d.generation=s.generation
        dst_state.geometry[len(dst.hulls)+len(dst.meshes)+i]=src_state.geometry[hulls+meshes+i]
    }
    return true
}

// The marks of every slot of geometry, hashing again only the slots whose generation changed.
@(private)
geometry_marks :: proc(state:^Physics_State) -> bool {
    w:=&state.world
    total:=len(w.hulls)+len(w.meshes)+len(w.heightfields)
    // A copy marks its source too: what the source keeps is the source's, not the copier's.
    if state.geometry.allocator.procedure==nil {state.geometry.allocator=w.allocator}
    if len(state.geometry)!=total && resize(&state.geometry,total)!=nil {return false}
    for &slot,i in w.hulls {
        mark:=&state.geometry[i]
        if slot.generation&1==0 {mark^={};continue}
        if mark.generation==slot.generation && mark.revision==slot.revision {continue}
        h:=&slot.hull
        mark^={slot.generation,slot.revision,geometry_hash(h.vertices,geometry_hash(h.planes,geometry_hash(h.face_edges,geometry_hash(h.edges,0))))}
    }
    for &slot,i in w.meshes {
        mark:=&state.geometry[len(w.hulls)+i]
        if slot.generation&1==0 {mark^={};continue}
        if mark.generation==slot.generation {continue}
        m:=&slot.mesh
        mark^={generation=slot.generation,hash=geometry_hash(m.vertices,geometry_hash(m.triangles,geometry_hash(m.flags,0)))}
    }
    for &slot,i in w.heightfields {
        mark:=&state.geometry[len(w.hulls)+len(w.meshes)+i]
        if slot.generation&1==0 {mark^={};continue}
        if mark.generation==slot.generation {continue}
        f:=&slot.field
        shape:=[5]i64{i64(f.columns),i64(f.rows),i64(transmute(u32)f.cell.x),i64(transmute(u32)f.cell.y),i64(transmute(u32)f.cell.z)}
        mark^={generation=slot.generation,hash=geometry_hash(f.heights,geometry_hash(f.disabled_borders,geometry_hash(f.holes,geometry_hash(shape[:],0))))}
    }
    return true
}

@(private)
geometry_hash :: proc(values:[]$T,seed:u64) -> u64 {
    return len(values)==0?seed:xxhash.XXH3_64_with_seed(mem.slice_to_bytes(values),seed)
}

// dst as long as src with its values, reusing its memory.
@(private)
array_copy :: proc(dst:^[dynamic]$T,src:[]T) -> bool {
    if non_zero_resize(dst,len(src))!=nil {return false}
    copy(dst[:],src)
    return true
}

@(private)
sliced_equal :: proc(a,b:[]$T) -> bool {
    if len(a)!=len(b) {return false}
    return mem.compare(mem.slice_to_bytes(a),mem.slice_to_bytes(b))==0
}

@(private)
cloned :: proc(source:[]$T,a:mem.Allocator) -> ([]T,bool) {
    out,error:=make([]T,len(source),a)
    if error!=nil {return nil,false}
    copy(out,source)
    return out,true
}

@(private)
hull_clone :: proc(h:sim.Hull,a:mem.Allocator) -> (out:sim.Hull,ok:bool) {
    out=h
    out.vertices,out.planes,out.face_edges,out.edges=nil,nil,nil,nil
    defer if !ok {sim.hull_free(&out,a)}
    out.vertices,ok=cloned(h.vertices,a);if !ok {return}
    out.planes,ok=cloned(h.planes,a);if !ok {return}
    out.face_edges,ok=cloned(h.face_edges,a);if !ok {return}
    out.edges,ok=cloned(h.edges,a)
    return
}

@(private)
mesh_clone :: proc(m:sim.Mesh,a:mem.Allocator) -> (out:sim.Mesh,ok:bool) {
    out=m
    out.vertices,out.triangles,out.flags=nil,nil,nil
    out.bvh={allocator=a}
    defer if !ok {sim.mesh_release(&out,a)}
    out.vertices,ok=cloned(m.vertices,a);if !ok {return}
    out.triangles,ok=cloned(m.triangles,a);if !ok {return}
    out.flags,ok=cloned(m.flags,a);if !ok {return}
    error:mem.Allocator_Error
    out.bvh.nodes,error=mem.make_aligned([]spatial.Bvh_Node,len(m.bvh.nodes),64,a);if error!=nil {ok=false;return}
    copy(out.bvh.nodes,m.bvh.nodes)
    out.bvh.order,ok=cloned(m.bvh.order,a)
    return
}

@(private)
physics_parallel_for :: proc(count,grain:int,data:rawptr,body:proc(data:rawptr,first,last,worker:int)) {
    link:=cast(^Parallel)context.user_ptr
    jobs_parallel_for(link,count,grain,data,body)
}

// Makes the simulation of state with the capacities of settings, as the first physics_step of a world does;
// true once it is ready. A tool or a test that simulates without a world (simulate) makes it here.
state_make :: proc(state:^Physics_State,settings:^Physics_Settings,job_system:^jobs.Job_System,problems:^core.Problems) -> bool {
    if state.ready {return true}
    desc:=sim.world_desc_default()
    desc.allocator=context.allocator
    made:=settings_capacities(settings^)
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=int(made.bodies),int(made.shapes),int(made.contacts),int(made.joints)
    desc.character_capacity,desc.fluid_capacity=int(made.characters),int(made.fluids)
    desc.breakable_capacity,desc.piece_capacity,desc.bond_capacity=int(made.breakables),int(made.pieces),int(made.bonds)
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity=int(made.hulls),int(made.meshes),int(made.heightfields)
    desc.event_capacity,desc.substeps=int(made.events),int(made.substeps)
    desc.worker_count=jobs_workers(job_system)
    desc.parallel_for=physics_parallel_for
    clear(&state.geometry)
    clear(&state.sources);clear(&state.source_stamps)
    clear(&state.owned);clear(&state.owned_stamps)
    if !sim.world_init(&state.world,desc) {
        core.report(problems,core.NONE,"physics.world","the simulation of this world was not made: out of memory for the capacities of Physics_Settings (%d bodies, %d shapes, %d contacts), or one of them is not valid; lower them, or free memory",desc.body_capacity,desc.shape_capacity,desc.contact_capacity)
        return false
    }
    state.ready=true
    state.synced,state.fluids_synced,state.pushes_set,state.own_gravity=0,0,false,false
    state.sealed_key=0
    state.touched_all=true
    return true
}
