package destruct

import "core:math/linalg"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:std/base"

// Destruction as a game declares it. An entity with Mesh_Renderer and
// Destructible is fractured when the game starts simulating it: one convex
// piece per site, joined to its neighbours. Contacts and the game damage it;
// the pieces that come loose become bodies of the simulation. The pieces are
// data of the simulation, not entities: once the destructible is broken it is
// drawn by one generated mesh per body, on an entity of this library.

Destruct_Pattern :: enum u8 {
    Uniform,   // sites spread evenly in the bounds of the mesh
    Clustered, // gathered around a few centers
    Radial,    // around the center of the bounds, denser towards it
}

Fracture_Kind :: phys.Break_Kind
Piece_Info :: phys.Piece_Info
Piece_Flags :: phys.Piece_Flags
Piece_Flag :: phys.Piece_Flag
Destruct_Cluster_Info :: phys.Cluster_Info

// The mesh must be closed. Its pieces replace the Collider of the entity, of
// any kind, and take its surface and collision (none: COLLIDER_DEFAULT); they
// move as its Rigid_Body says (none: dynamic): of a kinematic or static one
// the body it is made as is kinematic, and every piece falls with its
// gravity_scale. Physics moves it as a body: physics.move_kinematic moves a
// kinematic one.
@(component)
Destructible :: struct {
    pieces:u32 `mirai:"min=1,section=Fracture"`,
    seed:u64,
    pattern:Destruct_Pattern,
    anchored:bool,                              // the pieces that reach the base of the mesh, its lowest local Y, are fixed to the world
    fracture:base.Asset_Id `mirai:"kind=.fracture"`,
    hull_vertices:u32 `mirai:"min=4,max=255,section=Pieces"`,
    strength:f32 `mirai:"min=0,unit=N s/m2,section=Damage"`,    // N s per m2 of shared face that a connection takes before it breaks
    impact_damage:bool,
    damage_threshold:f32 `mirai:"min=0,unit=N s"`, // N s of an impact in one tick below which it does no damage
    damage_radius:f32 `mirai:"min=0,unit=m"`,   // around the point of an impact: where its damage starts
    propagation:f32 `mirai:"min=0,max=1"`,      // share of the strain a connection that breaks leaves over that goes on to its neighbours: 0 stops a crack at the damage radius
    debris_volume:f32 `mirai:"min=0,unit=m3,section=Debris"`,  // a group that comes off smaller than this is debris: it touches only static bodies
    debris_lifetime:f32 `mirai:"min=0,unit=s"`, // and disappears after this long
    removal_lifetime:f32 `mirai:"min=0,unit=s"`,
    remove_on_sleep:bool,
    interior:base.Asset_Id `mirai:"section=Appearance,kind=.mat"`,                    // material of the faces a fracture opens; zero: the one of the first slot
}

// The values of physics.BREAKABLE_DESC_DEFAULT.
destructible :: proc "contextless" (pieces:u32=16,anchored:=false,seed:u64=1) -> Destructible {
    d:=phys.BREAKABLE_DESC_DEFAULT
    return {
        pieces=pieces,seed=seed,anchored=anchored,hull_vertices=u32(d.hull_vertices),strength=d.strength,
        impact_damage=d.impact_damage,damage_threshold=d.damage_threshold,damage_radius=d.damage_radius,propagation=d.propagation,debris_volume=d.debris_volume,debris_lifetime=5,
    }
}

destructible_default :: proc "contextless" () -> Destructible {return destructible()}

// What this library keeps of a destructible. Only it writes it.
@(component)
Destructible_State :: struct {
    handle:phys.Breakable_Handle `mirai:"transient,readonly,hidden"`,
    revision:u32 `mirai:"transient,readonly,hidden"`,         // of the simulation destructible that the groups mirror
    detached:u32 `mirai:"transient,readonly"`,                // pieces that left the body of the entity
    sequence:u32 `mirai:"transient,readonly,hidden"`,         // fracture events applied to it since it was made; a state that broke it counts as one
    passive:bool `mirai:"transient,readonly,hidden"`,           // made on a client: only what the server says damages it
    broken:bool `mirai:"transient,readonly"`,                 // drawn by its groups instead of its own mesh
    waiting:bool `mirai:"transient,readonly,hidden"`,         // its pieces are being cut
    failed:bool `mirai:"transient,readonly,hidden"`,          // it could not be made: not tried again until what it is made from changes
}

// On the entity this library makes for a body of a broken destructible: the
// body that is still the destructible's own is a child of it (group 0), each
// one that came off an entity of its own with the Transform of its body. It is
// a proxy of that body in physics, which writes its Transform.
@(component,locks="core.Transform")
Destructible_Group :: struct {
    owner:core.Entity `mirai:"transient,readonly"`, // the destructible
    group:u32 `mirai:"transient,readonly"`,         // physics.Piece_Info.group: the same on every end of a network session
    debris:bool `mirai:"transient,readonly"`,       // cosmetic: of this world alone
    mesh:base.Asset_Id `mirai:"transient,readonly,hidden"`, // generated for its pieces, which its Mesh_Renderer shows
    members:u64 `mirai:"transient,readonly,hidden"`,        // hash of the ids of the pieces mesh was made of
}

// What is asked of a destructible, or of one body that broke off it: the event each of its bodies gets.
Destruct_Request :: struct {
    entity:core.Entity,
    using event:phys.Break_Event,
}

// A fracture event applied to a destructible, in the frame of the body it was
// about, so that it applies the same to the same destructible made from the
// same mesh wherever that body is: what another end replays.
Fracture_Record :: struct {
    piece:u32,     // place in the list of pieces of one of the body it is about, whose frame point and vector are in; max: the destructible's own body
    kind:Fracture_Kind,
    point,vector:[3]f32,
    radius:f32,
    strain:f32,
    half_extents:[3]f32,
    rotation:quaternion128,
    blend:f32,
}

// A fracture recorded on another end, to apply to a destructible here. check,
// when not zero, is physics.breakable_check after it there: the replays of the
// destructible that follow in the tick wait when it is not the same here. tag
// is of who asked, back in Replayed.
Replay :: struct {
    entity:core.Entity,
    record:Fracture_Record,
    check:u32,
    tag:u64,
}

// The state another end had of a destructible (physics.breakable_state_write);
// empty: as created. data is read in the tick it is asked.
State_Replay :: struct {
    entity:core.Entity,
    data:[]u8,
    tag:u64,
}

// What damage and slice ask for, and the replays of what other ends
// recorded; this library takes them after the step of the tick.
@(storage,queue)
Destruct_Requests :: struct {
    queue:core.Queue(Destruct_Request),
    waiting:core.Queue(Destruct_Request),
    replays:core.Queue(Replay),
    states:core.Queue(State_Replay),
}

replay :: proc(requests:^Destruct_Requests,e:core.Entity,record:Fracture_Record,check:u32=0,tag:u64=0) {
    core.push(&requests.replays,Replay{entity=e,record=record,check=check,tag=tag})
}

state_replay :: proc(requests:^Destruct_Requests,e:core.Entity,data:[]u8,tag:u64=0) {
    core.push(&requests.states,State_Replay{entity=e,data=data,tag=tag})
}

// Damages a destructible around a world point: every connection within the
// radius takes the size of the impulse, fading to nothing at the radius, and
// what comes off shares the impulse.
damage :: proc(requests:^Destruct_Requests,e:core.Entity,point:[3]f32,radius:f32,impulse:[3]f32) {
    core.push(&requests.queue,Destruct_Request{e,{kind=.Damage,region={point=point,radius=radius,blend=radius},vector=impulse,strain=linalg.length(impulse)}})
}

strain :: proc(requests:^Destruct_Requests,e:core.Entity,point:[3]f32,radius,amount:f32,impulse:[3]f32={}) {
    core.push(&requests.queue,Destruct_Request{e,{kind=.Damage,region={point=point,radius=radius,blend=radius},vector=impulse,strain=amount}})
}

weaken :: proc(requests:^Destruct_Requests,e:core.Entity,point:[3]f32,radius,amount:f32) {
    core.push(&requests.queue,Destruct_Request{e,{kind=.Weaken,region={point=point,radius=radius,blend=radius},strain=amount}})
}

// Cuts a destructible by the plane through a world point: the pieces the
// plane crosses become two and the two sides come apart.
slice :: proc(requests:^Destruct_Requests,e:core.Entity,point,normal:[3]f32) {
    core.push(&requests.queue,Destruct_Request{e,{kind=.Slice,region={point=point},vector=normal}})
}

Remove_Error :: enum {None,Missing_Group,Retained_Group}

remove :: proc(requests:^Destruct_Requests,groups:core.Read(Destructible_Group),e:core.Entity) -> Remove_Error {
    group,has:=core.get(groups,e)
    if !has {return .Missing_Group}
    if group.group==0 {return .Retained_Group}
    core.push(&requests.queue,Destruct_Request{e,{kind=.Remove}})
    return .None
}

Fracture :: struct {
    entity:core.Entity,
    kind:Fracture_Kind,
    point:[3]f32,   // world
    impulse:[3]f32, // N s; the normal of the plane for a Slice
    pieces:u32,     // that came off with it
}

Applied :: struct {
    entity:core.Entity,
    record:Fracture_Record,
}

// What a replay did: done is false when an event did not apply or did not
// leave the check it named, and when a state waits for the destructible to be
// made again, which the next tick does.
Replayed :: struct {
    entity:core.Entity,
    tag:u64,     // of the replay
    state:bool,  // of a State_Replay
    done:bool,
    failed:bool, // a state that does not apply here: the ends fracture different meshes
    check:u32,   // physics.breakable_check after it
}

// The entity of a group of a broken destructible in a network session, with
// the Id every end draws alike from the Id of the destructible and the group.
Grouped :: struct {
    owner,entity:core.Entity,
    id:base.Entity_Id,
    debris:bool, // of each end: it is not replicated
}

// What happened to the destructibles in the tick: pieces that left their
// body, the events applied, in order, what the replays did and the groups made
// with an Id. This library clears it and fills it every tick.
@(storage)
Destruct_Events :: struct {
    fractured:core.Events(Fracture),
    applied:core.Events(Applied),
    replayed:core.Events(Replayed),
    grouped:core.Events(Grouped),
}
