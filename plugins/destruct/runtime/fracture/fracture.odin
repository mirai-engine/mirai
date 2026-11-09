package fracture

import "core:mem"
import "core:math/linalg"
import "core:hash/xxhash"
import "mirai:std/base"
import "mirai:std/geom"
import math "mirai:std/math"
import sim "plugins:physics/runtime/sim"

// The fracture model: destructibles made of convex pieces held by connections, over the public API of a
// simulation world. Its pieces are shapes of that world, tagged with their slot, whose hits damage them;
// what comes off becomes new bodies of it. Its state, apart from the world, is copied with fracture_copy
// whenever the world is.

Vec3 :: sim.Vec3
Quat :: sim.Quat
Mat3 :: sim.Mat3
Aabb :: sim.Aabb
Filter :: sim.Filter
Body_Handle :: sim.Body_Handle
Shape_Handle :: sim.Shape_Handle
Hull_Handle :: sim.Hull_Handle
Radial_Falloff :: sim.Radial_Falloff

Destructible_Handle :: distinct base.Handle

Desc :: struct {
    allocator:mem.Allocator,
    bodies:int, // the body capacity of the world it fractures
    destructibles,pieces,connections:int,
    events:int, // fracture events per step
}

desc_default :: proc() -> Desc {
    return {allocator=context.allocator,bodies=4096,destructibles=64,pieces=2048,connections=8192,events=1024}
}

// Counters and list heads of the pools, copied with them.
State :: struct {
    destructible_high,destructible_free,destructible_count:i32,
    piece_high,piece_free,piece_count:i32,
    connection_high,connection_free,connection_count:i32,
    updated:u64, // the tick of the world after the step fracture_update last saw
}

Stats :: struct {
    destructibles,pieces:int,
    // Requests refused because a capacity of the fracture or of the world ran out, and fracture events
    // that did not fit in those of a step, since the fracture was made.
    capacity_exhausted,events_dropped:int,
}

Fracture :: struct {
    desc:Desc,
    allocator:mem.Allocator,
    // State copied by fracture_copy.
    using state:State,
    destructibles:[]Destructible,
    pieces:[]Piece,
    connections:[]Connection,
    piece_hulls:[]Hull_Handle,     // hull each piece slot owns; it outlives its piece until the slot is used again
    piece_origins:[]Piece_Origin, // where the piece of each slot came from; rewritten with its hull
    // Of the last step and of the call that runs.
    events:[]Fracture_Event,
    event_count:int,
    tick:u64, // of the world, for the change that runs
    scratch:Scratch,
    stats:Stats,
}

Destructible_Desc :: struct {
    mesh:geom.Mesh,        // closed, in the frame of the destructible
    sites:[]Vec3,          // Voronoi sites in that frame: one piece each (geom.sites_generate fills them)
    anchors:[]Aabb,        // in that frame, up to DESTRUCTIBLE_ANCHOR_CAPACITY: the pieces that reach into one are fixed to the static world
    position:Vec3,
    rotation:Quat,         // zero means identity
    density:f32,           // kg/m3
    friction,restitution:f32,
    gravity_scale:f32,
    kinematic:bool,
    filter:Filter,
    strength:f32,          // N s per m2 of shared face that a connection takes before it breaks
    impact_damage:bool,
    damage_threshold:f32,  // N s of a contact in one step below which it does no damage
    damage_radius:f32,     // m around a contact point that its damage reaches
    debris_volume:f32,     // m3: a group that comes off smaller than this is debris
    debris_ticks:u32,      // steps that debris lasts
    removal_ticks:u32,     // zero keeps detached non-debris pieces
    remove_on_sleep:bool,
    passive_removal:bool,  // preserves deadlines while only explicit Remove events retire non-debris
    hull_vertices:int,     // most vertices of the hull of a piece; zero is 32
    fracture:^geom.Fracture, // the mesh already fractured by whoever also needs its pieces: mesh and sites are not read
    piece_anchors:[]bool,
    piece_clusters:[]i32,
    clusters:[]Cluster_Desc,
    cluster_points:[]Vec3, // in that frame: the points that clusters name for their hulls
    connection_strength:[]f32,
    user_data:u64,         // of the bodies and shapes of the destructible
}

DESTRUCTIBLE_DESC_DEFAULT :: Destructible_Desc{
    rotation=sim.QUAT_IDENTITY,density=2000,friction=0.6,gravity_scale=1,filter=sim.FILTER_DEFAULT,
    strength=500,impact_damage=true,damage_threshold=50,damage_radius=0.5,debris_volume=0.001,debris_ticks=300,hull_vertices=32,
}

Destructible_Error :: enum {None,Invalid_Desc,Invalid_Mesh,No_Pieces,Capacity,Out_Of_Memory}

DESTRUCTIBLE_ANCHOR_CAPACITY :: 4

// While whole, a cluster collides as the convex hull of points [first_point,first_point+point_count) of
// Destructible_Desc.cluster_points; without points, as the hull of its pieces.
Cluster_Desc :: struct {parent:i32,strength:f32,first_point,point_count:u32}
Cluster_Info :: struct {parent:i32,strength,strain:f32,broken:bool}

// What a destructible can need from the fracture or the world after it was made.
Capacity :: enum u8 {Pieces,Hulls,Connections,Shapes,Bodies}
Capacities :: bit_set[Capacity;u8]

Fracture_Kind :: enum u32 {
    Damage, // explicit: strains the connections around the point and throws what comes off
    Impact, // the same, caused by a contact of the step; only what leaves a static body is thrown
    Slice,  // cut by the plane through the point
    Weaken,
    Remove,
}

// What broke a destructible, small enough to send: applying it to an equal world gives an equal result.
Fracture_Event :: struct {
    destructible:Destructible_Handle,
    tick:u32,     // of the world when it was applied
    piece:i32,    // id of a piece: only the body that holds it is damaged or cut. -1: every body of the destructible
    point:Vec3,   // world
    vector:Vec3,  // impulse in N s, or the normal of the plane of a slice
    radius:f32,   // m
    kind:Fracture_Kind,
    strain:f32,  // N s, independent of the impulse
    half_extents:Vec3, // nonzero selects a box instead of a sphere
    rotation:Quat,
    falloff:Radial_Falloff,
}
#assert(size_of(Fracture_Event)==88)

Piece_Flag :: enum u32 {
    Anchor, // fixed to the static world
    Debris,
    Gone,   // expired, or replaced by the two halves of a cut
}
Piece_Flags :: bit_set[Piece_Flag;u32]

@(private)
Piece :: struct {
    shape:Shape_Handle,
    hull:Hull_Handle,
    expire:u64,   // tick at which a debris piece disappears
    center:Vec3,  // center of mass in the frame of the destructible, which is the frame of every body it becomes
    volume:f32,
    destructible:i32,
    next:i32,
    flags:Piece_Flags,
    group:u32,    // which body of the destructible it is on: 0 the one it was created as, else the revision that made the body
    cluster:i32,
    _:u32,
}
#assert(size_of(Piece)==64)

@(private) Connection_Flag :: enum u32 {Broken,Cluster}
@(private) Connection_Flags :: bit_set[Connection_Flag;u32]

@(private)
Connection :: struct {
    a,b:i32,      // piece slots. A cluster: one of its pieces, and the slot of its hull or -1
    next:i32,
    flags:Connection_Flags,
    area:f32,     // m2 of the face the pieces share
    strain:f32,   // N s of damage taken
    center:Vec3,  // in the frame of the destructible
    strength:f32,
    cluster:i32, // cluster slot; a cluster record names its parent here
}
#assert(size_of(Connection)==44)

@(private) Destruct_Flag :: enum u32 {Anchored,Remove_On_Sleep,Passive_Removal,Impact_Damage}
@(private) Destruct_Flags :: bit_set[Destruct_Flag;u32]

@(private)
Destructible :: struct {
    user_data:u64,
    body:Body_Handle, // the body it was created as
    piece_list,piece_tail,piece_count:i32,
    connection_list,connection_tail,connection_count:i32,
    density,friction,restitution:f32,
    gravity_scale:f32,
    strength,damage_threshold,damage_radius,debris_volume:f32,
    debris_ticks:u32,
    removal_ticks:u32,
    flags:Destruct_Flags,
    hull_vertices:i32,
    filter:Filter,
    anchors:[DESTRUCTIBLE_ANCHOR_CAPACITY]Aabb,
    anchor_count:i32,
    revision:u32,     // changes of its pieces: every group that left, every cut, every piece removed
    generation:u32, // odd while the slot is in use
    next_free:i32,
}
#assert(size_of(Destructible)==224)

Piece_Info :: struct {
    id:i32,             // stable while the destructible lives
    body:Body_Handle,   // null once the piece is gone
    shape:Shape_Handle,
    center:Vec3,        // in the frame of the body
    volume:f32,
    flags:Piece_Flags,
    group:u32,          // id of its body among those of the destructible: 0 is the one it was created as. The same wherever the same events were applied
    source:i32,         // piece of the fracture it is; -1 for a half of a cut
    parent:i32,         // id of the piece it was cut from; -1 for a piece of the fracture
    cut_normal:Vec3,    // plane of that cut in the frame of the body: the half in front, when front
    cut_offset:f32,
    front:bool,
}
Connection_Info :: struct {a,b:i32,area,strain:f32,broken:bool}

@(private)
Scratch :: struct {
    parent,group,source:[]i32, // per piece slot
    body:[]Body_Handle,        // per piece slot: the body it is on, or is to be on; zero out of the world
    made,from:[]Body_Handle,   // per piece slot: the body a group that leaves is made, and the one it leaves
    ids:[]u32,
    volume:[]f32,
    anchored:[]bool,
    side:[]i8,
    keeper:[]i32,              // per body slot
    changed:[]bool,            // per body slot: its shapes changed and its mass waits for settle
    changed_list:[]Body_Handle,
    changed_count:int,
    cluster_body:[]i32,        // per connection slot
    hits:[]Fracture_Event,
    lost:[]u32,                // per destructible slot, since the last step began: events that did not fit
    refused:[]Capacities,      // and the capacities that refused it something
}

// Mass properties a hull takes from what it stands for: those of the pieces of a cluster.
@(private) Hull_Mass :: struct {volume:f32,center:Vec3,inertia:Mat3}

// Where the piece of a slot came from. Outside the state, like its hull: a slot is rewritten only by the
// piece that repeats the one it held.
@(private)
Piece_Origin :: struct {
    source,parent:i32,
    plane:Vec3,
    offset:f32,
    front:bool,
}

@(private) SLICE_TOLERANCE :: 1e-4 // m within which a piece is on one side of a cut

@(private) dot :: #force_inline proc "contextless" (a,b:Vec3) -> f32 {return linalg.dot(a,b)}
@(private) cross :: #force_inline proc "contextless" (a,b:Vec3) -> Vec3 {return linalg.cross(a,b)}
@(private) length :: #force_inline proc "contextless" (a:Vec3) -> f32 {return linalg.length(a)}
// Zero for a vector too short to give a direction.
@(private) normalize :: #force_inline proc "contextless" (a:Vec3) -> Vec3 {
    l:=length(a)
    if l<1e-20 {return {}}
    return a*(1/l)
}
@(private) xf_point :: #force_inline proc "contextless" (t:sim.Transform,p:Vec3) -> Vec3 {return math.quat_rotate(t.q,p)+t.p}
@(private) xf_inv_point :: #force_inline proc "contextless" (t:sim.Transform,p:Vec3) -> Vec3 {return math.quat_rotate(conj(t.q),p-t.p)}
@(private) body_slot :: #force_inline proc "contextless" (h:Body_Handle) -> i32 {return i32(base.handle_index(base.Handle(h)))}

// A transaction that allocates.
fracture_init :: proc(f:^Fracture,desc:Desc) -> bool {
    f^={}
    d:=desc
    if d.allocator.procedure==nil {d.allocator=context.allocator}
    d.bodies,d.destructibles,d.pieces,d.connections,d.events=max(d.bodies,0),max(d.destructibles,0),max(d.pieces,0),max(d.connections,0),max(d.events,0)
    f.desc=d
    f.allocator=d.allocator
    f.destructible_free,f.piece_free,f.connection_free=-1,-1,-1
    a:=d.allocator
    ok:=true
    alloc :: proc($T:typeid,count:int,a:mem.Allocator,ok:^bool) -> []T {
        if count<=0 {return nil}
        slice,error:=make([]T,count,a)
        if error!=nil {ok^=false}
        return slice
    }
    f.destructibles=alloc(Destructible,d.destructibles,a,&ok)
    f.pieces=alloc(Piece,d.pieces,a,&ok)
    f.connections=alloc(Connection,d.connections,a,&ok)
    f.piece_hulls=alloc(Hull_Handle,d.pieces,a,&ok)
    f.piece_origins=alloc(Piece_Origin,d.pieces,a,&ok)
    f.events=alloc(Fracture_Event,d.events,a,&ok)
    s:=&f.scratch
    bodies:=d.bodies
    s.parent=alloc(i32,d.pieces,a,&ok)
    s.group=alloc(i32,d.pieces,a,&ok)
    s.source=alloc(i32,d.pieces,a,&ok)
    s.body=alloc(Body_Handle,d.pieces,a,&ok)
    s.made=alloc(Body_Handle,d.pieces,a,&ok)
    s.from=alloc(Body_Handle,d.pieces,a,&ok)
    s.ids=alloc(u32,max(d.pieces,d.connections),a,&ok)
    s.volume=alloc(f32,d.pieces,a,&ok)
    s.anchored=alloc(bool,d.pieces,a,&ok)
    s.side=alloc(i8,d.pieces,a,&ok)
    s.keeper=alloc(i32,bodies,a,&ok)
    s.changed=alloc(bool,bodies,a,&ok)
    s.changed_list=alloc(Body_Handle,bodies,a,&ok)
    s.cluster_body=alloc(i32,d.connections,a,&ok)
    s.hits=alloc(Fracture_Event,max(d.events,1),a,&ok)
    s.lost=alloc(u32,d.destructibles,a,&ok)
    s.refused=alloc(Capacities,d.destructibles,a,&ok)
    if !ok {fracture_destroy(f);return false}
    return true
}

// Frees the fracture. Its bodies and hulls stay in the world, which goes with it.
fracture_destroy :: proc(f:^Fracture) {
    a:=f.allocator
    if a.procedure==nil {return}
    delete(f.destructibles,a);delete(f.pieces,a);delete(f.connections,a);delete(f.piece_hulls,a);delete(f.piece_origins,a);delete(f.events,a)
    s:=&f.scratch
    delete(s.parent,a);delete(s.group,a);delete(s.source,a);delete(s.body,a);delete(s.made,a);delete(s.from,a);delete(s.ids,a)
    delete(s.volume,a);delete(s.anchored,a);delete(s.side,a);delete(s.keeper,a);delete(s.changed,a);delete(s.changed_list,a)
    delete(s.cluster_body,a);delete(s.hits,a);delete(s.lost,a);delete(s.refused,a)
    f^={}
}

// Makes dst, a fracture of the same capacities, what src is. With geometry, the world of dst took the
// hulls of the world of src, and dst takes the hulls its piece slots own; without it, dst is of the same
// world, which kept its hulls, and keeps them too. Events of the last step are not copied.
fracture_copy :: proc(dst,src:^Fracture,geometry:=true) -> bool {
    if dst==src {return true}
    if !desc_equal(dst.desc,src.desc) {return false}
    copy_pool :: proc(dst,src:[]$T,high:i32) {
        copy(dst[:high],src[:high])
        if int(high)<len(dst) {mem.zero_slice(dst[high:])}
    }
    copy_pool(dst.destructibles,src.destructibles,src.destructible_high)
    copy_pool(dst.pieces,src.pieces,src.piece_high)
    copy_pool(dst.connections,src.connections,src.connection_high)
    if geometry {
        copy(dst.piece_hulls,src.piece_hulls)
        copy(dst.piece_origins,src.piece_origins)
    }
    dst.state=src.state
    dst.event_count=0
    return true
}

// Whether two fractures have the same capacities, and so can be copied into each other.
desc_equal :: proc(a,b:Desc) -> bool {
    x,y:=a,b
    x.allocator,y.allocator={},{}
    return x==y
}

// Hash of the state fracture_copy copies. Two fractures that were made and changed alike have equal hashes.
fracture_hash :: proc(f:^Fracture) -> u64 {
    state:=f.state
    hash:=xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&state),0)
    for block in ([3][]byte{mem.slice_to_bytes(f.destructibles[:f.destructible_high]),mem.slice_to_bytes(f.pieces[:f.piece_high]),mem.slice_to_bytes(f.connections[:f.connection_high])}) {
        if len(block)>0 {hash=xxhash.XXH3_64_with_seed(block,hash)}
    }
    return hash
}

fracture_stats :: proc(f:^Fracture) -> Stats {
    s:=f.stats
    s.destructibles,s.pieces=int(f.destructible_count),int(f.piece_count)
    return s
}

// What the fracture did in the last step: damage from contacts and pieces removed.
fracture_events :: proc(f:^Fracture) -> []Fracture_Event {return f.events[:f.event_count]}

@(private)
destructible_get :: #force_inline proc "contextless" (f:^Fracture,h:Destructible_Handle) -> (^Destructible,i32) {
    index:=base.handle_index(base.Handle(h))
    generation:=base.handle_generation(base.Handle(h))
    if index>=u32(f.destructible_high) || generation&1==0 || f.destructibles[index].generation!=generation {return nil,-1}
    return &f.destructibles[index],i32(index)
}
@(private) destructible_handle :: #force_inline proc "contextless" (f:^Fracture,index:i32) -> Destructible_Handle {
    return Destructible_Handle(base.handle_make(u32(index),f.destructibles[index].generation))
}

destructible_valid :: proc(f:^Fracture,h:Destructible_Handle) -> bool {
    d,_:=destructible_get(f,h)
    return d!=nil
}

@(private)
piece_alloc :: proc(f:^Fracture) -> i32 {
    index:=f.piece_free
    if index>=0 {
        f.piece_free=f.pieces[index].next
    } else if int(f.piece_high)<len(f.pieces) {
        index=f.piece_high
        f.piece_high+=1
    } else {
        return -1
    }
    f.piece_count+=1
    return index
}
@(private)
piece_release :: proc(f:^Fracture,index:i32) {
    f.pieces[index]={next=f.piece_free}
    f.piece_free=index
    f.piece_count-=1
}
@(private)
connection_alloc :: proc(f:^Fracture) -> i32 {
    index:=f.connection_free
    if index>=0 {
        f.connection_free=f.connections[index].next
    } else if int(f.connection_high)<len(f.connections) {
        index=f.connection_high
        f.connection_high+=1
    } else {
        return -1
    }
    f.connection_count+=1
    return index
}

// Gives a piece slot its hull. The slot keeps the hull of the piece it held before; a new piece builds over
// it under the same handle, so that repeating a cut after a copy gives the same state. With mass, the hull
// weighs that instead of its own volume.
@(private)
piece_hull_set :: proc(f:^Fracture,w:^sim.World,index:i32,desc:sim.Hull_Desc,mass:^Hull_Mass=nil) -> (Hull_Handle,bool) {
    handle:=f.piece_hulls[index]
    if sim.hull_get(w,handle)!=nil && !sim.hull_in_use(w,handle) {
        if !sim.hull_rebuild(w,handle,desc) {
            sim.hull_destroy(w,handle)
            f.piece_hulls[index]={}
            return {},false
        }
    } else {
        ok:bool
        if handle,ok=sim.hull_create(w,desc);!ok {return {},false}
        f.piece_hulls[index]=handle
    }
    if mass!=nil {sim.hull_set_mass(w,handle,mass.volume,mass.center,mass.inertia)}
    return handle,true
}

// A new piece slot with the convex hull of the points, in no list yet, or -1.
@(private)
piece_slot_build :: proc(f:^Fracture,w:^sim.World,d:i32,points:[]Vec3,counts,indices:^[dynamic]u8,mass:^Hull_Mass=nil) -> i32 {
    max_vertices:=int(f.destructibles[d].hull_vertices)
    built,error:=geom.hull_build(points,{max_vertices=max_vertices},f.allocator)
    if error!=.None {return -1}
    defer geom.hull_destroy(&built)
    if geom.hull_is_flat(built) {return -1}
    if len(built.vertices)>sim.HULL_MAX_VERTICES || len(built.faces)>sim.HULL_MAX_FACES || len(built.face_vertices)>sim.HULL_MAX_HALF_EDGES {return -1}
    clear(counts)
    clear(indices)
    for face in built.faces {
        append(counts,u8(face.vertex_count))
        for vertex in built.face_vertices[face.first_vertex:][:face.vertex_count] {append(indices,u8(vertex))}
    }
    index:=piece_alloc(f)
    if index<0 {return -1}
    handle,ok:=piece_hull_set(f,w,index,{built.vertices,counts[:],indices[:]},mass)
    if !ok {
        piece_release(f,index)
        return -1
    }
    hull:=sim.hull_get(w,handle)
    f.pieces[index]={hull=handle,center=hull.center,volume=hull.volume,destructible=d,next=-1,cluster=-1}
    f.piece_origins[index]={source=-1,parent=-1}
    return index
}

// A new piece with the convex hull of the points, or -1.
@(private)
piece_build :: proc(f:^Fracture,w:^sim.World,d:i32,points:[]Vec3,counts,indices:^[dynamic]u8) -> i32 {
    index:=piece_slot_build(f,w,d,points,counts,indices)
    if index<0 {return -1}
    hull:=sim.hull_get(w,f.pieces[index].hull)
    owner:=&f.destructibles[d]
    for anchor in owner.anchors[:owner.anchor_count] {
        if math.aabb_overlaps(hull.aabb,anchor) {f.pieces[index].flags+={.Anchor}}
    }
    return index
}

@(private)
piece_append :: proc(f:^Fracture,d:^Destructible,index:i32) {
    if d.piece_tail>=0 {f.pieces[d.piece_tail].next=index} else {d.piece_list=index}
    d.piece_tail=index
    d.piece_count+=1
}
@(private)
connection_append :: proc(f:^Fracture,d:^Destructible,connection:Connection) -> bool {
    index:=connection_alloc(f)
    if index<0 {return false}
    f.connections[index]=connection
    f.connections[index].next=-1
    if d.connection_tail>=0 {f.connections[d.connection_tail].next=index} else {d.connection_list=index}
    d.connection_tail=index
    d.connection_count+=1
    return true
}

// A shape of a destructible on a body: the hull of a piece, whose slot `owner` is, or of a cluster, which
// names one of its pieces. Its tag is that slot plus one. The mass of the body waits for settle.
@(private)
destruct_shape :: proc(f:^Fracture,w:^sim.World,hull:Hull_Handle,body:Body_Handle,owner:i32) -> Shape_Handle {
    index:=f.pieces[owner].destructible
    d:=&f.destructibles[index]
    desc:=sim.Shape_Desc{
        geometry=hull,transform=sim.TRANSFORM_IDENTITY,friction=d.friction,restitution=d.restitution,
        density=d.density,filter=d.filter,user_data=d.user_data,hits=.Impact_Damage in d.flags,tag=u32(owner)+1,
    }
    handle:=sim.shape_create(w,body,desc,false)
    if handle=={} {
        f.scratch.refused[index]+={.Shapes}
        return {}
    }
    destruct_changed(f,body)
    return handle
}

// Puts the shape of a piece on a body.
@(private)
piece_attach :: proc(f:^Fracture,w:^sim.World,index:i32,body:Body_Handle) -> bool {
    f.pieces[index].shape=destruct_shape(f,w,f.pieces[index].hull,body,index)
    return f.pieces[index].shape!={}
}

// Whether the shape of a piece is its own, not the one of a whole cluster it is in.
@(private)
piece_own_shape :: proc(w:^sim.World,piece:^Piece) -> bool {
    return piece.hull!={} && sim.shape_hull(w,piece.shape)==piece.hull
}

// Takes the own shape of a piece off its body.
@(private)
piece_detach :: proc(f:^Fracture,w:^sim.World,index:i32) {
    if piece_own_shape(w,&f.pieces[index]) {
        destruct_changed(f,sim.shape_body(w,f.pieces[index].shape))
        sim.shape_destroy(w,f.pieces[index].shape,false)
    }
    f.pieces[index].shape={}
}

// Takes a piece out of the world; the body goes with its last shape. A removal takes every piece of a
// body, so the mass of the body is not updated.
@(private)
piece_remove :: proc(f:^Fracture,w:^sim.World,index:i32) {
    piece:=&f.pieces[index]
    if sim.shape_valid(w,piece.shape) {
        body:=sim.shape_body(w,piece.shape)
        sim.shape_destroy(w,piece.shape,false)
        if sim.body_shapes(w,body,nil)==0 {sim.body_destroy(w,body)}
    }
    piece.shape={}
    f.destructibles[piece.destructible].revision+=1
    piece.flags+={.Gone}
}

@(private)
destruct_changed :: proc(f:^Fracture,body:Body_Handle) {
    s:=&f.scratch
    slot:=body_slot(body)
    if s.changed[slot] {return}
    s.changed[slot]=true
    s.changed_list[s.changed_count]=body
    s.changed_count+=1
}

// The mass of every body whose shapes changed, once: what it holds now, with the velocity its center
// had where the center moves to.
@(private)
destruct_settle :: proc(f:^Fracture,w:^sim.World) {
    s:=&f.scratch
    for body in s.changed_list[:s.changed_count] {
        if !s.changed[body_slot(body)] {continue}
        s.changed[body_slot(body)]=false
        sim.body_mass_update(w,body)
    }
    s.changed_count=0
}

// The body every piece of the destructible is on, into the scratch: zero for one out of the world.
@(private)
destruct_bodies :: proc(f:^Fracture,w:^sim.World,d:^Destructible) {
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        f.scratch.body[slot]=sim.shape_body(w,f.pieces[slot].shape)
    }
}

// Gives every piece of the destructible the shape it collides with on the body that the scratch names
// for it: the hull of the outermost whole cluster above it, or its own. A cluster is whole while it is
// unbroken and every piece under it is on one body; with fold false none is. A piece without a body
// leaves the world. False when a shape did not fit: that piece is out of the world.
@(private)
destruct_collide :: proc(f:^Fracture,w:^sim.World,index:i32,fold:bool) -> bool {
    d:=&f.destructibles[index]
    s:=&f.scratch
    held:=s.cluster_body
    // The body slot under each cluster: -1 none seen yet, -2 none, -3 under a whole cluster with a hull,
    // -4 whole without a hull.
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        if .Cluster in f.connections[slot].flags {held[slot]=fold && .Broken not_in f.connections[slot].flags?-1:-2}
    }
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        body:i32=s.body[slot]=={}?-1:body_slot(s.body[slot])
        for above:=f.pieces[slot].cluster;above>=0;above=f.connections[above].cluster {
            if body<0 {held[above]=-2} else if held[above]==-1 {held[above]=body} else if held[above]!=body {held[above]=-2}
        }
    }
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        c:=&f.connections[slot]
        if .Cluster not_in c.flags {continue}
        if c.cluster>=0 && (held[c.cluster]>=0 || held[c.cluster]==-3) {
            held[slot]=-3
        } else if c.b<0 && held[slot]>=0 {
            held[slot]=-4
        }
    }
    // The shape of a cluster stays while the cluster stands whole on its body.
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        c:=&f.connections[slot]
        if .Cluster not_in c.flags || c.b<0 {continue}
        phantom:=&f.pieces[c.b]
        valid:=sim.shape_valid(w,phantom.shape)
        if valid && body_slot(sim.shape_body(w,phantom.shape))==held[slot] {continue}
        if valid {
            destruct_changed(f,sim.shape_body(w,phantom.shape))
            sim.shape_destroy(w,phantom.shape,false)
        }
        phantom.shape={}
    }
    ok:=true
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        piece:=&f.pieces[slot]
        body:=s.body[slot]
        unit:i32=-1
        for above:=piece.cluster;above>=0 && body!={};above=f.connections[above].cluster {
            if held[above]>=0 {unit=above;break}
        }
        if unit<0 && piece_own_shape(w,piece) && sim.shape_body(w,piece.shape)==body {continue}
        piece_detach(f,w,slot)
        if body=={} {continue}
        if unit<0 {
            ok&&=piece_attach(f,w,slot,body)
            continue
        }
        c:=&f.connections[unit]
        phantom:=&f.pieces[c.b]
        if !sim.shape_valid(w,phantom.shape) {phantom.shape=destruct_shape(f,w,phantom.hull,body,c.a)}
        piece.shape=phantom.shape
        ok&&=piece.shape!={}
    }
    return ok
}

// Gives a cluster the slot of its hull: the convex hull of the points, or of the hulls of its pieces
// without points, weighing what its pieces weigh. A hull that would not hold their center of mass is
// left out, and the cluster collides as its pieces.
@(private)
cluster_hull_build :: proc(f:^Fracture,w:^sim.World,index,cluster:i32,points:[]Vec3,counts,indices:^[dynamic]u8) {
    d:=&f.destructibles[index]
    mass:Hull_Mass
    moment:Vec3
    inertia:Mat3
    gathered:=make([dynamic]Vec3,f.allocator)
    defer delete(gathered)
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        under:=false
        for above:=f.pieces[slot].cluster;above>=0 && !under;above=f.connections[above].cluster {under=above==cluster}
        hull:=sim.hull_get(w,f.pieces[slot].hull)
        if !under || hull==nil {continue}
        volume:=hull.volume
        mass.volume+=volume
        moment+=volume*hull.center
        inertia+=hull.inertia+sim.mat3_point_inertia(volume,hull.center)
        if len(points)==0 {append(&gathered,..hull.vertices)}
    }
    if !(mass.volume>0) {return}
    mass.center=moment/mass.volume
    mass.inertia=inertia-sim.mat3_point_inertia(mass.volume,mass.center)
    phantom:=piece_slot_build(f,w,index,len(points)>0?points:gathered[:],counts,indices,&mass)
    if phantom<0 {return}
    if hull:=sim.hull_get(w,f.pieces[phantom].hull);!(hull.inner_radius>0) {
        piece_release(f,phantom)
        return
    }
    f.connections[cluster].b=phantom
}

// Fractures a mesh into a destructible: one piece per connected part of each Voronoi cell, each with the convex hull of its part
// of the mesh as shape, connected to the pieces it shares a face with. It starts as one body, static if
// any piece is anchored and dynamic otherwise. A transaction that allocates: not for the middle of a tick.
destructible_create :: proc(f:^Fracture,w:^sim.World,desc:Destructible_Desc) -> (handle:Destructible_Handle,error:Destructible_Error) {
    if !(desc.density>0) || !destruct_finite(desc.density,desc.friction,desc.restitution,desc.gravity_scale,desc.strength,desc.damage_threshold,desc.damage_radius,desc.debris_volume,
       desc.position.x,desc.position.y,desc.position.z,desc.rotation.x,desc.rotation.y,desc.rotation.z,desc.rotation.w) ||
       desc.friction<0 || desc.restitution<0 || desc.restitution>1 || desc.strength<0 || desc.damage_threshold<0 || desc.damage_radius<0 || desc.debris_volume<0 {return {},.Invalid_Desc}
    if desc.fracture==nil && (len(desc.sites)==0 || !geom.mesh_is_valid(desc.mesh) || len(desc.mesh.indices)==0) {return {},.Invalid_Desc}
    if len(desc.anchors)>DESTRUCTIBLE_ANCHOR_CAPACITY {return {},.Invalid_Desc}
    if f.destructible_free<0 && int(f.destructible_high)>=len(f.destructibles) {
        f.stats.capacity_exhausted+=1
        return {},.Capacity
    }
    own:geom.Fracture
    defer if desc.fracture==nil {geom.fracture_destroy(&own)}
    fracture:=desc.fracture
    if fracture==nil {
        geom.fracture_init(&own,f.allocator)
        switch geom.mesh_fracture(&own,desc.mesh,desc.sites) {
        case .None:
        case .Out_Of_Memory: return {},.Out_Of_Memory
        case .Invalid_Mesh,.No_Sites: return {},.Invalid_Mesh
        }
        fracture=&own
    }
    count:=len(fracture.pieces)
    if count==0 {return {},.No_Pieces}
    if !destruct_source_valid(desc,fracture) {return {},.Invalid_Desc}
    world:=sim.world_stats(w)
    if int(f.piece_count)+count+len(desc.clusters)>len(f.pieces) || int(f.connection_count)+len(fracture.connections)+len(desc.clusters)>len(f.connections) ||
       world.shapes+count>w.desc.shape_capacity || world.bodies>=w.desc.body_capacity {
        f.stats.capacity_exhausted+=1
        return {},.Capacity
    }
    index:=f.destructible_free
    if index>=0 {
        f.destructible_free=f.destructibles[index].next_free
    } else {
        index=f.destructible_high
        f.destructible_high+=1
    }
    f.destructible_count+=1
    d:=&f.destructibles[index]
    d^={
        user_data=desc.user_data,piece_list=-1,piece_tail=-1,connection_list=-1,connection_tail=-1,
        density=desc.density,friction=desc.friction,restitution=desc.restitution,gravity_scale=desc.gravity_scale,
        strength=desc.strength,damage_threshold=desc.damage_threshold,damage_radius=desc.damage_radius,
        debris_volume=desc.debris_volume,debris_ticks=desc.debris_ticks,removal_ticks=desc.removal_ticks,
        hull_vertices=i32(clamp(desc.hull_vertices==0?32:desc.hull_vertices,4,sim.HULL_MAX_VERTICES)),
        filter=desc.filter,anchor_count=i32(len(desc.anchors)),generation=d.generation+1,next_free=-1,
    }
    if desc.impact_damage {d.flags+={.Impact_Damage}}
    copy(d.anchors[:],desc.anchors)
    slots,slots_error:=make([]i32,count,f.allocator)
    cluster_slots,clusters_error:=make([]i32,len(desc.clusters),f.allocator)
    counts:=make([dynamic]u8,f.allocator)
    indices:=make([dynamic]u8,f.allocator)
    defer {
        delete(slots,f.allocator)
        delete(cluster_slots,f.allocator)
        delete(counts)
        delete(indices)
    }
    if slots_error!=nil || clusters_error!=nil {
        destructible_release(f,w,index)
        f.stats.capacity_exhausted+=1
        return {},.Capacity
    }
    hulls_refused:=sim.world_stats(w).geometry_capacity_exhausted
    anchored:=false
    for _,i in fracture.pieces {
        slot:=piece_build(f,w,index,geom.fracture_piece_mesh(fracture,i).positions,&counts,&indices)
        slots[i]=slot
        if slot<0 {continue}
        f.piece_origins[slot].source=i32(i)
        f.pieces[slot].cluster=-1
        if len(desc.piece_anchors)>0 && desc.piece_anchors[i] {f.pieces[slot].flags+={.Anchor}}
        piece_append(f,d,slot)
        anchored||=.Anchor in f.pieces[slot].flags
    }
    failed:=sim.world_stats(w).geometry_capacity_exhausted!=hulls_refused
    if !failed && d.piece_count==0 {
        destructible_release(f,w,index)
        return {},.No_Pieces
    }
    if !failed {
        body_desc:=sim.BODY_DESC_DEFAULT
        body_desc.type=desc.kinematic?.Kinematic:anchored?.Static:.Dynamic
        body_desc.gravity_scale=desc.gravity_scale
        body_desc.position,body_desc.rotation=desc.position,desc.rotation==0?sim.QUAT_IDENTITY:desc.rotation
        body_desc.user_data=desc.user_data
        d.body=sim.body_create(w,body_desc)
        failed=d.body=={}
    }
    if failed {
        f.stats.capacity_exhausted+=1
        destructible_release(f,w,index)
        return {},.Capacity
    }
    if anchored {d.flags+={.Anchored}}
    if desc.remove_on_sleep {d.flags+={.Remove_On_Sleep}}
    if desc.passive_removal {d.flags+={.Passive_Removal}}
    for cluster,at in desc.clusters {
        first:i32=-1
        for piece_cluster,piece in desc.piece_clusters {
            for ancestor:=piece_cluster;ancestor>=0;ancestor=desc.clusters[ancestor].parent {
                if ancestor==i32(at) && slots[piece]>=0 {first=slots[piece];break}
            }
            if first>=0 {break}
        }
        connection_append(f,d,{a=first,b=-1,flags={.Cluster},area=1,strength=cluster.strength,cluster=cluster.parent>=0?cluster_slots[cluster.parent]:-1})
        cluster_slots[at]=d.connection_tail
    }
    for piece_cluster,piece in desc.piece_clusters {
        if slots[piece]>=0 && piece_cluster>=0 {f.pieces[slots[piece]].cluster=cluster_slots[piece_cluster]}
    }
    for connection,at in fracture.connections {
        a,b:=slots[connection.a],slots[connection.b]
        if a<0 || b<0 {continue}
        strength:=len(desc.connection_strength)>0 && desc.connection_strength[at]>0?desc.connection_strength[at]:d.strength
        cluster:i32=-1
        if len(desc.piece_clusters)>0 {
            common:=destruct_cluster_common(desc.clusters,desc.piece_clusters[connection.a],desc.piece_clusters[connection.b])
            if common>=0 {cluster=cluster_slots[common]}
        }
        connection_append(f,d,{a=a,b=b,area=connection.area,strength=strength,cluster=cluster,center=0.5*(f.pieces[a].center+f.pieces[b].center)})
    }
    for cluster,at in desc.clusters {
        cluster_hull_build(f,w,index,cluster_slots[at],desc.cluster_points[cluster.first_point:][:cluster.point_count],&counts,&indices)
    }
    // Every piece starts on the first body, the whole clusters folded into their hulls.
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {f.scratch.body[slot]=d.body}
    failed=sim.world_stats(w).geometry_capacity_exhausted!=hulls_refused || !destruct_collide(f,w,index,true)
    destruct_settle(f,w)
    if failed {
        f.stats.capacity_exhausted+=1
        destructible_release(f,w,index)
        return {},.Capacity
    }
    return destructible_handle(f,index),.None
}

// Removes the bodies and shapes of the destructible and frees its slots.
@(private)
destructible_release :: proc(f:^Fracture,w:^sim.World,index:i32) {
    d:=&f.destructibles[index]
    for slot:=d.piece_list;slot>=0; {
        next:=f.pieces[slot].next
        piece_remove(f,w,slot)
        piece_release(f,slot)
        slot=next
    }
    for slot:=d.connection_list;slot>=0; {
        next:=f.connections[slot].next
        if c:=f.connections[slot];.Cluster in c.flags && c.b>=0 {
            piece_remove(f,w,c.b)
            piece_release(f,c.b)
        }
        f.connections[slot]={next=f.connection_free}
        f.connection_free=slot
        f.connection_count-=1
        slot=next
    }
    if sim.body_valid(w,d.body) && sim.body_shapes(w,d.body,nil)==0 {sim.body_destroy(w,d.body)}
    d^={generation=d.generation+1,next_free=f.destructible_free}
    f.destructible_free=index
    f.destructible_count-=1
}

// Destroys every body the destructible has become. The hulls of its pieces stay registered until their
// slots are used again, so a copy taken before can still be restored.
destructible_destroy :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle) {
    if d,index:=destructible_get(f,h);d!=nil {destructible_release(f,w,index)}
}

destructible_find :: proc(f:^Fracture,user_data:u64) -> Destructible_Handle {
    for &d,slot in f.destructibles[:f.destructible_high] {
        if d.generation&1!=0 && d.user_data==user_data {return Destructible_Handle(base.handle_make(u32(slot),d.generation))}
    }
    return {}
}

// The body the destructible was created as: where its anchored pieces are, or its largest part.
destructible_body :: proc(f:^Fracture,h:Destructible_Handle) -> Body_Handle {
    d,_:=destructible_get(f,h)
    return d!=nil?d.body:{}
}

// Changes what every piece meets, those that came off included.
destructible_set_filter :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,filter:Filter) {
    d,_:=destructible_get(f,h)
    if d==nil {return}
    d.filter=filter
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        if piece_own_shape(w,&f.pieces[slot]) {sim.shape_set_filter(w,f.pieces[slot].shape,filter)}
    }
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        if c:=f.connections[slot];.Cluster in c.flags && c.b>=0 {sim.shape_set_filter(w,f.pieces[c.b].shape,filter)}
    }
}

// Pieces of the destructible, gone ones included, written to `out`; returns how many there are.
destructible_pieces :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,out:[]Piece_Info) -> int {
    d,_:=destructible_get(f,h)
    if d==nil {return 0}
    count:=0
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        piece:=&f.pieces[slot]
        if count<len(out) {
            origin:=f.piece_origins[slot]
            out[count]={
                id=slot,body=sim.shape_body(w,piece.shape),shape=piece.shape,center=piece.center,volume=piece.volume,flags=piece.flags,group=piece.group,
                source=origin.source,parent=origin.parent,cut_normal=origin.plane,cut_offset=origin.offset,front=origin.front,
            }
        }
        count+=1
    }
    return count
}

// Connections of the destructible, broken ones included; `a` and `b` are piece ids.
destructible_connections :: proc(f:^Fracture,h:Destructible_Handle,out:[]Connection_Info) -> int {
    d,_:=destructible_get(f,h)
    if d==nil {return 0}
    count:=0
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        c:=&f.connections[slot]
        if .Cluster in c.flags {continue}
        if count<len(out) {out[count]={c.a,c.b,c.area,c.strain,.Broken in c.flags}}
        count+=1
    }
    return count
}

// Mass of the pieces that are still in the world.
destructible_mass :: proc(f:^Fracture,h:Destructible_Handle) -> f32 {
    d,_:=destructible_get(f,h)
    if d==nil {return 0}
    volume:f32
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        if .Gone not_in f.pieces[slot].flags {volume+=f.pieces[slot].volume}
    }
    return volume*d.density
}

@(private)
hull_to_mesh :: proc(hull:^sim.Hull,out:^geom.Mesh_Buffer) {
    geom.mesh_buffer_clear(out)
    append(&out.positions,..hull.vertices)
    for first in hull.face_edges {
        edge:=hull.edges[first]
        corner:=u32(edge.origin)
        edge=hull.edges[edge.next]
        previous:=u32(edge.origin)
        for edge.next!=first {
            edge=hull.edges[edge.next]
            append(&out.indices,corner,previous,u32(edge.origin))
            previous=u32(edge.origin)
        }
    }
}

// The hull of a piece as a closed triangle mesh in the frame of its body.
destructible_piece_mesh :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,id:i32,out:^geom.Mesh_Buffer) -> bool {
    d,index:=destructible_get(f,h)
    if d==nil || id<0 || id>=f.piece_high || f.pieces[id].destructible!=index {return false}
    hull:=sim.hull_get(w,f.pieces[id].hull)
    if hull==nil {return false}
    hull_to_mesh(hull,out)
    return true
}

// Damages the destructible around a world point: each connection within the radius takes the size of
// the impulse, fading to nothing at the radius; what comes off shares the impulse. Returns the event that
// repeats it elsewhere and whether anything broke.
destructible_damage :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,point:Vec3,radius:f32,impulse:Vec3) -> (event:Fracture_Event,broke:bool) {
    return destructible_strain(f,w,h,point,radius,length(impulse),impulse)
}

// Cuts the destructible by the plane through a world point: the pieces the plane crosses become two, each
// with a new hull, and the two sides come apart. Between ticks; it allocates.
destructible_slice :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,point,normal:Vec3) -> (event:Fracture_Event,cut:bool) {
    d,index:=destructible_get(f,h)
    if d==nil {return}
    f.tick=sim.world_tick(w)
    event={destructible=h,tick=u32(f.tick),piece=-1,point=point,vector=normal,kind=.Slice}
    return event,fracture_slice(f,w,index,&event)
}

// The same on the body that holds one piece alone, whose frame the event can then travel in: what the
// event does no longer depends on where the other bodies of the destructible are. strained: some
// connection of that body was within the radius.
destructible_damage_body :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,piece:i32,point:Vec3,radius:f32,impulse:Vec3) -> (event:Fracture_Event,broke,strained:bool) {
    d,index:=destructible_get(f,h)
    if d==nil || piece_body(f,w,index,piece)=={} {return}
    f.tick=sim.world_tick(w)
    event={destructible=h,tick=u32(f.tick),piece=piece,point=point,vector=impulse,radius=radius,kind=.Damage,strain=length(impulse),falloff=.Linear}
    broke,strained=fracture_damage(f,w,index,&event)
    return
}
destructible_slice_body :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,piece:i32,point,normal:Vec3) -> (event:Fracture_Event,cut:bool) {
    d,index:=destructible_get(f,h)
    if d==nil || piece_body(f,w,index,piece)=={} {return}
    f.tick=sim.world_tick(w)
    event={destructible=h,tick=u32(f.tick),piece=piece,point=point,vector=normal,kind=.Slice}
    return event,fracture_slice(f,w,index,&event)
}

destructible_remove_body :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,piece:i32) -> (event:Fracture_Event,removed:bool) {
    d,index:=destructible_get(f,h)
    if d==nil || piece_body(f,w,index,piece)=={} || f.pieces[piece].group==0 {return}
    f.tick=sim.world_tick(w)
    event={destructible=h,tick=u32(f.tick),piece=piece,kind=.Remove}
    return event,destruct_remove_body(f,w,index,piece)
}

// Steps until the pieces of the destructible on a body expire, and whether they do.
destructible_body_remaining_ticks :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,body:Body_Handle) -> (ticks:u32,expires:bool) {
    d,_:=destructible_get(f,h)
    if d==nil || !sim.body_valid(w,body) {return}
    deadline:=max(u64)
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        piece:=&f.pieces[slot]
        if piece.group!=0 && piece.shape!={} && sim.shape_body(w,piece.shape)==body {deadline=min(deadline,piece.expire)}
    }
    tick:=sim.world_tick(w)
    if deadline!=max(u64) {return u32(min(u64(max(u32)),deadline>tick?deadline-tick:0)),true}
    return
}

// The body a piece of a destructible is on; zero for what is not a piece of it in the world.
@(private)
piece_body :: proc(f:^Fracture,w:^sim.World,index,piece:i32) -> Body_Handle {
    if piece<0 || piece>=f.piece_high || f.pieces[piece].destructible!=index {return {}}
    return sim.shape_body(w,f.pieces[piece].shape)
}

// Applies an event recorded by this fracture or by another one in the same state.
fracture_event_apply :: proc(f:^Fracture,w:^sim.World,event:Fracture_Event) -> bool {
    d,index:=destructible_get(f,event.destructible)
    if d==nil {return false}
    e:=event
    if e.piece>=0 && piece_body(f,w,index,e.piece)=={} {return false}
    f.tick=sim.world_tick(w)
    switch e.kind {
    case .Damage,.Impact,.Weaken:
        broke,_:=fracture_damage(f,w,index,&e)
        return broke
    case .Slice: return fracture_slice(f,w,index,&e)
    case .Remove: return destruct_remove_body(f,w,index,e.piece)
    }
    return false
}

@(private)
fracture_damage :: proc(f:^Fracture,w:^sim.World,index:i32,event:^Fracture_Event) -> (broke,strained:bool) {
    d:=&f.destructibles[index]
    size:=event.strain
    if !(size>0) || event.falloff>.Logarithmic || !destruct_finite(size,event.radius,event.point.x,event.point.y,event.point.z,event.vector.x,event.vector.y,event.vector.z,
       event.half_extents.x,event.half_extents.y,event.half_extents.z,event.rotation.x,event.rotation.y,event.rotation.z,event.rotation.w) {return}
    if event.half_extents=={} {if !(event.radius>0) {return}}
    else if !(event.half_extents.x>0 && event.half_extents.y>0 && event.half_extents.z>0) {return}
    only:=piece_body(f,w,index,event.piece)
    broke,strained=destruct_clusters_damage(f,w,index,event,only)
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        c:=&f.connections[slot]
        if c.flags&{.Broken,.Cluster}!={} || c.cluster>=0 {continue}
        body:=sim.shape_body(w,f.pieces[c.a].shape)
        if body=={} || event.piece>=0 && body!=only {continue}
        weight:=destruct_region_weight(event,xf_point(sim.body_transform(w,body),c.center))
        if weight<=0 {continue}
        c.strain=min(max(f32),c.strain+size*weight)
        strained=true
        if event.kind!=.Weaken && c.strain>=c.strength*c.area {
            c.flags+={.Broken}
            broke=true
        }
    }
    if broke {destructible_regroup(f,w,index,event)}
    return
}

// Splits the bodies of a destructible along its broken connections. In a static body the groups without
// an anchor come off; in a dynamic body, all but the largest. Each group becomes a dynamic body in the
// frame of the one it leaves, with its velocity there, and debris when it is small.
@(private)
destructible_regroup :: proc(f:^Fracture,w:^sim.World,index:i32,event:^Fracture_Event) {
    d:=&f.destructibles[index]
    s:=&f.scratch
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        s.parent[slot],s.group[slot]=slot,-1
        s.volume[slot],s.anchored[slot]=0,false
    }
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        c:=&f.connections[slot]
        if c.flags&{.Broken,.Cluster}=={} {sim.union_join(s.parent,c.a,c.b)}
    }
    destruct_bodies(f,w,d)
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        from:=s.body[slot]
        if from=={} {continue}
        root:=sim.union_find(s.parent,slot)
        s.volume[root]+=f.pieces[slot].volume
        if .Anchor in f.pieces[slot].flags {s.anchored[root]=true}
        s.keeper[body_slot(from)]=-1
    }
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        from:=s.body[slot]
        if from=={} || s.parent[slot]!=slot {continue}
        if keeper:=s.keeper[body_slot(from)];keeper<0 || s.volume[slot]>s.volume[keeper] {s.keeper[body_slot(from)]=slot}
    }
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        piece:=&f.pieces[slot]
        from:=s.body[slot]
        if from=={} || .Debris in piece.flags {continue}
        root:=sim.union_find(s.parent,slot)
        if sim.body_type(w,from)!=.Dynamic && .Anchored in d.flags?s.anchored[root]:s.keeper[body_slot(from)]==root {continue}
        if s.group[root]==-1 {
            xf:=sim.body_transform(w,from)
            desc:=sim.BODY_DESC_DEFAULT
            desc.gravity_scale=d.gravity_scale
            desc.position,desc.rotation,desc.user_data=xf.p,xf.q,d.user_data
            desc.debris=s.volume[root]<d.debris_volume
            created:=sim.body_create(w,desc)
            if created=={} {
                f.stats.capacity_exhausted+=1
                s.refused[index]+={.Bodies}
                s.group[root]=-2
            } else {
                d.revision+=1
                s.ids[root]=d.revision
                s.group[root]=0
                s.made[root],s.from[root]=created,from
            }
        }
        if s.group[root]<0 {continue}
        to:=s.made[root]
        s.body[slot]=to
        piece.group=s.ids[root]
        piece.expire=d.removal_ticks>0?f.tick+u64(d.removal_ticks):max(u64)
        if sim.body_is_debris(w,to) {
            piece.flags+={.Debris}
            piece.expire=f.tick+u64(d.debris_ticks)
        }
    }
    destruct_collide(f,w,index,true)
    // A body that came off weighs what it holds before it takes the velocity it had where it was.
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        if s.group[slot]==0 {
            sim.body_mass_update(w,s.made[slot])
            s.changed[body_slot(s.made[slot])]=false
        }
    }
    // The groups leave with the velocity their body had where they were, and share the impulse of the
    // event by volume and closeness to its point.
    weight:f32
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        if s.group[slot]!=0 {continue}
        body,parent:=s.made[slot],s.from[slot]
        center:=sim.body_center(w,body)
        parent_type:=sim.body_type(w,parent)
        if parent_type!=.Static {
            angular:=sim.body_angular_velocity(w,parent)
            sim.body_set_velocity(w,body,sim.body_linear_velocity(w,parent)+cross(angular,center-sim.body_center(w,parent)),angular)
        }
        if event.kind==.Damage || (event.kind==.Impact && parent_type==.Static) {
            s.volume[slot]*=destruct_region_weight(event,center)
            weight+=s.volume[slot]
        } else {
            s.volume[slot]=0
        }
    }
    if weight>0 {
        for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
            if s.group[slot]!=0 {continue}
            body:=s.made[slot]
            sim.body_set_linear_velocity(w,body,sim.body_linear_velocity(w,body)+event.vector*(s.volume[slot]/weight*(1/sim.body_mass(w,body))))
        }
    }
    destruct_settle(f,w)
}

// Whether the next `count` new piece slots find hulls: a slot used before builds over its own, any other
// takes a free hull slot. Slots beyond the capacity are not counted here.
@(private)
piece_hulls_available :: proc(f:^Fracture,w:^sim.World,count:int) -> bool {
    needed:=0
    slot,high:=f.piece_free,f.piece_high
    for _ in 0..<count {
        index:i32
        if slot>=0 {
            index,slot=slot,f.pieces[slot].next
        } else if int(high)<len(f.pieces) {
            index,high=high,high+1
        } else {
            break
        }
        if hull:=f.piece_hulls[index];sim.hull_get(w,hull)==nil || sim.hull_in_use(w,hull) {needed+=1}
    }
    return needed==0 || sim.hulls_free(w)>=needed
}

@(private)
fracture_slice :: proc(f:^Fracture,w:^sim.World,index:i32,event:^Fracture_Event) -> bool {
    d:=&f.destructibles[index]
    s:=&f.scratch
    normal:=normalize(event.vector)
    if normal=={} {return false}
    last_piece,last_connection:=d.piece_tail,d.connection_tail
    only:=piece_body(f,w,index,event.piece)
    // Side of each piece: 1 in front, -1 behind, 2 across the plane, 0 out of the cut.
    cuts,folded:=0,0
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        piece:=&f.pieces[slot]
        s.side[slot]=0
        body:=sim.shape_body(w,piece.shape)
        hull:=sim.hull_get(w,piece.hull)
        if body!={} && !piece_own_shape(w,piece) {folded+=1}
        if body=={} || hull==nil || .Debris in piece.flags || event.piece>=0 && body!=only {continue}
        xf:=sim.body_transform(w,body)
        n:=math.quat_rotate(conj(xf.q),normal)
        offset:=dot(n,xf_inv_point(xf,event.point))
        lo,hi:=max(f32),min(f32)
        for vertex in hull.vertices {
            distance:=dot(n,vertex)-offset
            lo,hi=min(lo,distance),max(hi,distance)
        }
        s.side[slot]=lo>=-SLICE_TOLERANCE?1:hi<=SLICE_TOLERANCE?-1:2
        if s.side[slot]==2 {cuts+=1}
    }
    connections,standing:=0,0
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        c:=&f.connections[slot]
        if .Cluster in c.flags {
            if c.b<0 {continue}
            if sim.shape_valid(w,f.pieces[c.b].shape) {standing+=1}
            continue
        }
        if .Broken in c.flags {continue}
        if s.side[c.a]==2 {connections+=1}
        if s.side[c.b]==2 {connections+=1}
    }
    // The pieces folded into whole clusters take their own shapes back: a cut ends the hierarchy.
    refused:Capacities
    if int(f.piece_count)+2*cuts>len(f.pieces) {refused+={.Pieces}}
    if int(f.connection_count)+connections>len(f.connections) {refused+={.Connections}}
    if sim.world_stats(w).shapes-standing+folded+cuts>w.desc.shape_capacity {refused+={.Shapes}}
    if !piece_hulls_available(f,w,2*cuts) {refused+={.Hulls}}
    if refused!={} {
        f.stats.capacity_exhausted+=1
        s.refused[index]+=refused
        return false
    }
    changed:=false
    if cuts>0 {
        destruct_bodies(f,w,d)
        destruct_collide(f,w,index,false)
        slicer:geom.Slicer
        buffers:[3]geom.Mesh_Buffer
        geom.slicer_init(&slicer,f.allocator)
        for &buffer in buffers {geom.mesh_buffer_init(&buffer,f.allocator)}
        counts:=make([dynamic]u8,f.allocator)
        indices:=make([dynamic]u8,f.allocator)
        defer {
            geom.slicer_destroy(&slicer)
            for &buffer in buffers {geom.mesh_buffer_destroy(&buffer)}
            delete(counts)
            delete(indices)
        }
        for slot:=d.piece_list;slot>=0; {
            current:=slot
            slot=current==last_piece?-1:f.pieces[current].next
            if s.side[current]!=2 {continue}
            piece:=f.pieces[current]
            body:=sim.shape_body(w,piece.shape)
            xf:=sim.body_transform(w,body)
            n:=math.quat_rotate(conj(xf.q),normal)
            offset:=dot(n,xf_inv_point(xf,event.point))
            halves,halved:=piece_cut(f,w,index,current,n,offset,&slicer,&buffers,&counts,&indices)
            if !halved {
                // Too thin a cut to make two solids: the piece goes whole to the side of its center.
                s.side[current]=dot(n,piece.center)-offset>=0?1:-1
                continue
            }
            piece_detach(f,w,current)
            f.pieces[current].flags+={.Gone}
            d.revision+=1
            for half,k in halves {
                s.side[half]=k==0?1:-1
                piece_append(f,d,half)
                piece_attach(f,w,half,body)
            }
            s.group[current],s.source[current]=halves[0],halves[1]
            changed=true
        }
    }
    // A connection survives on each side where both of its pieces have a part.
    for slot:=d.connection_list;slot>=0; {
        current:=slot
        slot=current==last_connection?-1:f.connections[current].next
        c:=f.connections[current]
        if c.flags&{.Broken,.Cluster}!={} {continue}
        sa,sb:=s.side[c.a],s.side[c.b]
        if sa==sb && sa!=2 {continue}
        f.connections[current].flags+={.Broken}
        changed=true
        if sa!=2 && sb!=2 {continue}
        scale:f32=sa==2 && sb==2?0.5:1
        for want,k in ([2]i8{1,-1}) {
            a:=sa==2?(k==0?s.group[c.a]:s.source[c.a]):sa==want?c.a:-1
            b:=sb==2?(k==0?s.group[c.b]:s.source[c.b]):sb==want?c.b:-1
            if a<0 || b<0 {continue}
            connection_append(f,d,{a=a,b=b,area=c.area*scale,strain=c.strain*scale,center=c.center,strength=c.strength,cluster=-1})
        }
    }
    if changed {
        for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
            c:=&f.connections[slot]
            if .Cluster in c.flags {c.flags+={.Broken}} else {c.cluster=-1}
        }
        destructible_regroup(f,w,index,event)
    } else if cuts>0 {
        destruct_bodies(f,w,d)
        destruct_collide(f,w,index,true)
        destruct_settle(f,w)
    }
    return changed
}

// Lists an event of the step; one that does not fit counts against its destructible.
@(private)
fracture_push :: proc(f:^Fracture,index:i32,event:Fracture_Event) {
    if f.event_count>=len(f.events) {
        f.scratch.lost[index]+=1
        f.stats.events_dropped+=1
        return
    }
    f.events[f.event_count]=event
    f.event_count+=1
}

// After each step of the world, once: its hits on a piece harder than the threshold of its destructible
// damage it around the hit point, and expired debris disappears. The events are those of fracture_events.
fracture_update :: proc(f:^Fracture,w:^sim.World) {
    if sim.world_tick(w)==f.updated {return}
    f.updated=sim.world_tick(w)
    s:=&f.scratch
    mem.zero_slice(s.lost)
    mem.zero_slice(s.refused)
    f.event_count=0
    if f.destructible_count==0 {return}
    f.tick=sim.world_tick(w)-1
    count:=0
    for hit in sim.world_events(w).hit {
        shapes:=[2]Shape_Handle{hit.shape_a,hit.shape_b}
        for shape,side in shapes {
            tag:=sim.shape_tag(w,shape)
            if tag==0 || i32(tag-1)>=f.piece_high || f.pieces[tag-1].shape!=shape {continue}
            piece:=&f.pieces[tag-1]
            if piece.flags&{.Debris,.Gone}!={} {continue}
            d:=&f.destructibles[piece.destructible]
            if .Impact_Damage not_in d.flags || hit.impulse<d.damage_threshold {continue}
            if count>=len(s.hits) {
                f.stats.events_dropped+=1
                s.lost[piece.destructible]+=1
                continue
            }
            // The normal goes from shape A to shape B: the impulse on each one points into it.
            s.hits[count]={
                destructible=destructible_handle(f,piece.destructible),tick=u32(f.tick),piece=i32(tag-1),point=hit.point,
                vector=hit.normal*(side==0?-hit.impulse:hit.impulse),radius=d.damage_radius,kind=.Impact,strain=hit.impulse,falloff=.Linear,
            }
            count+=1
        }
    }
    for &event in s.hits[:count] {
        if d,index:=destructible_get(f,event.destructible);d!=nil {
            fracture_damage(f,w,index,&event)
            fracture_push(f,index,event)
        }
    }
    for &d,index in f.destructibles[:f.destructible_high] {
        // Only a broken destructible has bodies that expire.
        if d.generation&1==0 || d.revision==0 {continue}
        for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
            piece:=&f.pieces[slot]
            if .Gone in piece.flags {continue}
            if .Debris in piece.flags {
                if piece.expire<=f.tick {piece_remove(f,w,slot)}
                continue
            }
            if .Passive_Removal in d.flags {continue}
            body:=sim.shape_body(w,piece.shape)
            if piece.group==0 || body=={} || piece.expire>f.tick && (.Remove_On_Sleep not_in d.flags || sim.body_is_awake(w,body)) {continue}
            event:=Fracture_Event{destructible=destructible_handle(f,i32(index)),tick=u32(f.tick),piece=slot,kind=.Remove}
            if destruct_remove_body(f,w,i32(index),slot) {fracture_push(f,i32(index),event)}
        }
    }
}

// What the destructible could not get since its last step began: fracture events that did not fit in
// those of a step (Desc.events), whose damage was not done or not listed, and the capacities that refused
// it what a fracture or a cut needed.
destructible_shortfall :: proc(f:^Fracture,h:Destructible_Handle) -> (events:int,refused:Capacities) {
    d,index:=destructible_get(f,h)
    if d==nil {return}
    return int(f.scratch.lost[index]),f.scratch.refused[index]
}
