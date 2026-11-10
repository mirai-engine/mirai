package mirai_physics

import "core:mem"
import "mirai:std/base"
import "mirai:std/geom"
import math "mirai:std/math"

// Breakable bodies: a breakable is made of convex pieces held by bonds. Its pieces are shapes of the
// world, tagged with their slot, whose hits damage them at the end of the step that raised them; what
// comes off becomes new bodies. Its pools are state of the world: a snapshot, a restore and a copy take
// them with the bodies. They are made with the first breakable, so a world that breaks nothing holds none.

Breakable_Handle :: distinct base.Handle

Breakable_Desc :: struct {
    mesh:geom.Mesh,        // closed, in the frame of the breakable
    sites:[]Vec3,          // Voronoi sites in that frame: one piece each (geom.sites_generate fills them)
    anchors:[]Aabb,        // in that frame, up to BREAKABLE_ANCHOR_CAPACITY: the pieces that reach into one are fixed to the static world
    position:Vec3,
    rotation:Quat,         // zero means identity
    density:f32,           // kg/m3
    friction,restitution:f32,
    gravity_scale:f32,
    kinematic:bool,
    filter:Filter,
    strength:f32,          // N s per m2 of shared face that a bond takes before it breaks
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
    bond_strength:[]f32,
    user_data:u64,         // of the bodies and shapes of the breakable
}

BREAKABLE_DESC_DEFAULT :: Breakable_Desc{
    rotation=QUAT_IDENTITY,density=2000,friction=0.6,gravity_scale=1,filter=FILTER_DEFAULT,
    strength=500,impact_damage=true,damage_threshold=50,damage_radius=0.5,debris_volume=0.001,debris_ticks=300,hull_vertices=32,
}

Breakable_Error :: enum {None,Invalid_Desc,Invalid_Mesh,No_Pieces,Capacity,Out_Of_Memory}

BREAKABLE_ANCHOR_CAPACITY :: 4

// While whole, a cluster collides as the convex hull of points [first_point,first_point+point_count) of
// Breakable_Desc.cluster_points; without points, as the hull of its pieces.
Cluster_Desc :: struct {parent:i32,strength:f32,first_point,point_count:u32}
Cluster_Info :: struct {parent:i32,strength,strain:f32,broken:bool}

// What a breakable can need from its pools or from the world after it was made.
Break_Capacity :: enum u8 {Pieces,Hulls,Bonds,Shapes,Bodies}
Break_Capacities :: bit_set[Break_Capacity;u8]

Break_Kind :: enum u32 {
    Damage, // explicit: strains the bonds around the point and throws what comes off
    Impact, // the same, caused by a contact of the step; only what leaves a static body is thrown
    Slice,  // cut by the plane through the point
    Weaken,
    Remove,
}

// What broke a breakable, small enough to send: applying it to an equal world gives an equal result.
Break_Event :: struct {
    breakable:Breakable_Handle,
    tick:u32,     // of the world when it was applied
    piece:i32,    // id of a piece: only the body that holds it is damaged or cut. -1: every body of the breakable
    point:Vec3,   // world
    vector:Vec3,  // impulse in N s, or the normal of the plane of a slice
    radius:f32,   // m
    kind:Break_Kind,
    strain:f32,  // N s, independent of the impulse
    half_extents:Vec3, // nonzero selects a box instead of a sphere
    rotation:Quat,
    falloff:Radial_Falloff,
}
#assert(size_of(Break_Event)==88)

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
    center:Vec3,  // center of mass in the frame of the breakable, which is the frame of every body it becomes
    volume:f32,
    breakable:i32,
    next:i32,
    flags:Piece_Flags,
    group:u32,    // which body of the breakable it is on: 0 the one it was created as, else the revision that made the body
    cluster:i32,
    _:u32,
}
#assert(size_of(Piece)==64)

@(private) Bond_Flag :: enum u32 {Broken,Cluster}
@(private) Bond_Flags :: bit_set[Bond_Flag;u32]

@(private)
Bond :: struct {
    a,b:i32,      // piece slots. A cluster: one of its pieces, and the slot of its hull or -1
    next:i32,
    flags:Bond_Flags,
    area:f32,     // m2 of the face the pieces share
    strain:f32,   // N s of damage taken
    center:Vec3,  // in the frame of the breakable
    strength:f32,
    cluster:i32, // cluster slot; a cluster record names its parent here
}
#assert(size_of(Bond)==44)

@(private) Breakable_Flag :: enum u32 {Anchored,Remove_On_Sleep,Passive_Removal,Impact_Damage}
@(private) Breakable_Flags :: bit_set[Breakable_Flag;u32]

@(private)
Breakable :: struct {
    user_data:u64,
    body:Body_Handle, // the body it was created as
    piece_list,piece_tail,piece_count:i32,
    bond_list,bond_tail,bond_count:i32,
    density,friction,restitution:f32,
    gravity_scale:f32,
    strength,damage_threshold,damage_radius,debris_volume:f32,
    debris_ticks:u32,
    removal_ticks:u32,
    flags:Breakable_Flags,
    hull_vertices:i32,
    filter:Filter,
    anchors:[BREAKABLE_ANCHOR_CAPACITY]Aabb,
    anchor_count:i32,
    revision:u32,     // changes of its pieces: every group that left, every cut, every piece removed
    generation:u32, // odd while the slot is in use
    next_free:i32,
}
#assert(size_of(Breakable)==224)

Piece_Info :: struct {
    id:i32,             // stable while the breakable lives
    body:Body_Handle,   // null once the piece is gone
    shape:Shape_Handle,
    center:Vec3,        // in the frame of the body
    volume:f32,
    flags:Piece_Flags,
    group:u32,          // id of its body among those of the breakable: 0 is the one it was created as. The same wherever the same events were applied
    source:i32,         // piece of the fracture it is; -1 for a half of a cut
    parent:i32,         // id of the piece it was cut from; -1 for a piece of the fracture
    cut_normal:Vec3,    // plane of that cut in the frame of the body: the half in front, when front
    cut_offset:f32,
    front:bool,
}
Bond_Info :: struct {a,b:i32,area,strain:f32,broken:bool}

@(private)
Break_Scratch :: struct {
    made:bool,                 // the pools exist, and in a world that steps this scratch does
    tick:u64,                  // of the world, for the change that runs
    parent,group,source:[]i32, // per piece slot
    body:[]Body_Handle,        // per piece slot: the body it is on, or is to be on; zero out of the world
    made_body,from:[]Body_Handle, // per piece slot: the body a group that leaves is made, and the one it leaves
    firsts:[]i32,              // one piece of each body of a breakable
    ids:[]u32,
    volume:[]f32,
    anchored:[]bool,
    side:[]i8,
    keeper:[]i32,              // per body slot
    marks:[]u32,               // per body slot: equal to mark for the bodies taken in the pass under way
    mark:u32,
    changed:[]bool,            // per body slot: its shapes changed and its mass waits for settle
    changed_list:[]Body_Handle,
    changed_count:int,
    cluster_body:[]i32,        // per bond slot
    hits:[]Break_Event,
    lost:[]u32,                // per breakable slot, since the last step began: events that did not fit
    refused:[]Break_Capacities, // and the capacities that refused it something
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

@(private) body_slot :: #force_inline proc "contextless" (h:Body_Handle) -> i32 {return i32(base.handle_index(base.Handle(h)))}

// The pools of the breakables and, in a world that steps, their scratch and events: made with the first
// breakable and with the state of a world that has them. A transaction that allocates; false without memory.
@(private)
breakables_make :: proc(w:^World) -> bool {
    s:=&w.breaking
    if s.made {return true}
    d:=w.desc
    a:=w.allocator
    ok:=true
    alloc :: proc($T:typeid,count:int,a:mem.Allocator,ok:^bool) -> []T {
        if count<=0 {return nil}
        slice,error:=make([]T,count,a)
        if error!=nil {ok^=false}
        return slice
    }
    w.breakables=alloc(Breakable,d.breakable_capacity,a,&ok)
    w.pieces=alloc(Piece,d.piece_capacity,a,&ok)
    w.bonds=alloc(Bond,d.bond_capacity,a,&ok)
    w.piece_hulls=alloc(Hull_Handle,d.piece_capacity,a,&ok)
    w.piece_origins=alloc(Piece_Origin,d.piece_capacity,a,&ok)
    if !w.kept {
        pieces,bonds,bodies:=d.piece_capacity,d.bond_capacity,d.body_capacity
        w.events.breaks=alloc(Break_Event,d.event_capacity,a,&ok)
        s.parent=alloc(i32,pieces,a,&ok)
        s.group=alloc(i32,pieces,a,&ok)
        s.source=alloc(i32,pieces,a,&ok)
        s.firsts=alloc(i32,pieces,a,&ok)
        s.body=alloc(Body_Handle,pieces,a,&ok)
        s.made_body=alloc(Body_Handle,pieces,a,&ok)
        s.from=alloc(Body_Handle,pieces,a,&ok)
        s.ids=alloc(u32,max(pieces,bonds),a,&ok)
        s.volume=alloc(f32,pieces,a,&ok)
        s.anchored=alloc(bool,pieces,a,&ok)
        s.side=alloc(i8,pieces,a,&ok)
        s.keeper=alloc(i32,bodies,a,&ok)
        s.marks=alloc(u32,bodies,a,&ok)
        s.changed=alloc(bool,bodies,a,&ok)
        s.changed_list=alloc(Body_Handle,bodies,a,&ok)
        s.cluster_body=alloc(i32,bonds,a,&ok)
        s.hits=alloc(Break_Event,2*d.event_capacity,a,&ok) // a hit damages the piece on each of its sides
        s.lost=alloc(u32,d.breakable_capacity,a,&ok)
        s.refused=alloc(Break_Capacities,d.breakable_capacity,a,&ok)
    }
    if !ok {
        breakables_free(w)
        return false
    }
    s.made=true
    return true
}

@(private)
breakables_free :: proc(w:^World) {
    a:=w.allocator
    delete(w.breakables,a);delete(w.pieces,a);delete(w.bonds,a);delete(w.piece_hulls,a);delete(w.piece_origins,a);delete(w.events.breaks,a)
    s:=&w.breaking
    delete(s.parent,a);delete(s.group,a);delete(s.source,a);delete(s.firsts,a);delete(s.body,a);delete(s.made_body,a);delete(s.from,a);delete(s.ids,a)
    delete(s.volume,a);delete(s.anchored,a);delete(s.side,a);delete(s.keeper,a);delete(s.marks,a);delete(s.changed,a);delete(s.changed_list,a)
    delete(s.cluster_body,a);delete(s.hits,a);delete(s.lost,a);delete(s.refused,a)
    w.breakables,w.pieces,w.bonds,w.piece_hulls,w.piece_origins,w.events.breaks=nil,nil,nil,nil,nil,nil
    w.breaking={}
}

// What a copy of the state of src into dst takes besides the pools: the hull and the origin of each piece
// slot, which are geometry. The hulls of src are in dst already.
@(private)
breakables_geometry_copy :: proc(dst,src:^World) {
    count:=int(max(src.piece_high,src.piece_hull_high))
    copy(dst.piece_hulls[:count],src.piece_hulls[:count])
    copy(dst.piece_origins[:count],src.piece_origins[:count])
    if count<len(dst.piece_hulls) {
        mem.zero_slice(dst.piece_hulls[count:])
        mem.zero_slice(dst.piece_origins[count:])
    }
    dst.piece_hull_high=src.piece_hull_high
}

@(private)
breakable_get :: #force_inline proc "contextless" (w:^World,h:Breakable_Handle) -> (^Breakable,i32) {
    index:=base.handle_index(base.Handle(h))
    generation:=base.handle_generation(base.Handle(h))
    // A kept world only holds its breakables: it has no scratch to read or change them with.
    if w.kept || index>=u32(w.breakable_high) || generation&1==0 || w.breakables[index].generation!=generation {return nil,-1}
    return &w.breakables[index],i32(index)
}
@(private) breakable_handle :: #force_inline proc "contextless" (w:^World,index:i32) -> Breakable_Handle {
    return Breakable_Handle(base.handle_make(u32(index),w.breakables[index].generation))
}

breakable_valid :: proc(w:^World,h:Breakable_Handle) -> bool {
    d,_:=breakable_get(w,h)
    return d!=nil
}

@(private)
piece_alloc :: proc(w:^World) -> i32 {
    index:=w.piece_free
    if index>=0 {
        w.piece_free=w.pieces[index].next
    } else if int(w.piece_high)<len(w.pieces) {
        index=w.piece_high
        w.piece_high+=1
    } else {
        return -1
    }
    w.piece_count+=1
    return index
}
@(private)
piece_release :: proc(w:^World,index:i32) {
    w.pieces[index]={next=w.piece_free}
    w.piece_free=index
    w.piece_count-=1
}
@(private)
bond_alloc :: proc(w:^World) -> i32 {
    index:=w.bond_free
    if index>=0 {
        w.bond_free=w.bonds[index].next
    } else if int(w.bond_high)<len(w.bonds) {
        index=w.bond_high
        w.bond_high+=1
    } else {
        return -1
    }
    w.bond_count+=1
    return index
}

// Gives a piece slot its hull. The slot keeps the hull of the piece it held before; a new piece builds over
// it under the same handle, so that repeating a cut after a copy gives the same state. With mass, the hull
// weighs that instead of its own volume.
@(private)
piece_hull_set :: proc(w:^World,index:i32,desc:Hull_Desc,mass:^Hull_Mass=nil) -> (Hull_Handle,bool) {
    handle:=w.piece_hulls[index]
    if hull_get(w,handle)!=nil && !hull_in_use(w,handle) {
        if !hull_rebuild(w,handle,desc) {
            hull_destroy(w,handle)
            w.piece_hulls[index]={}
            return {},false
        }
    } else {
        ok:bool
        if handle,ok=hull_create(w,desc);!ok {return {},false}
        w.piece_hulls[index]=handle
        w.piece_hull_high=max(w.piece_hull_high,index+1)
    }
    if mass!=nil {hull_set_mass(w,handle,mass.volume,mass.center,mass.inertia)}
    return handle,true
}

// A new piece slot with the convex hull of the points, in no list yet, or -1.
@(private)
piece_slot_build :: proc(w:^World,d:i32,points:[]Vec3,counts,indices:^[dynamic]u8,mass:^Hull_Mass=nil) -> i32 {
    max_vertices:=int(w.breakables[d].hull_vertices)
    built,error:=geom.hull_build(points,{max_vertices=max_vertices},w.allocator)
    if error!=.None {return -1}
    defer geom.hull_destroy(&built)
    if geom.hull_is_flat(built) {return -1}
    if len(built.vertices)>HULL_MAX_VERTICES || len(built.faces)>HULL_MAX_FACES || len(built.face_vertices)>HULL_MAX_HALF_EDGES {return -1}
    clear(counts)
    clear(indices)
    for face in built.faces {
        append(counts,u8(face.vertex_count))
        for vertex in built.face_vertices[face.first_vertex:][:face.vertex_count] {append(indices,u8(vertex))}
    }
    index:=piece_alloc(w)
    if index<0 {return -1}
    handle,ok:=piece_hull_set(w,index,{built.vertices,counts[:],indices[:]},mass)
    if !ok {
        piece_release(w,index)
        return -1
    }
    hull:=hull_get(w,handle)
    w.pieces[index]={hull=handle,center=hull.center,volume=hull.volume,breakable=d,next=-1,cluster=-1}
    w.piece_origins[index]={source=-1,parent=-1}
    return index
}

// A new piece with the convex hull of the points, or -1.
@(private)
piece_build :: proc(w:^World,d:i32,points:[]Vec3,counts,indices:^[dynamic]u8) -> i32 {
    index:=piece_slot_build(w,d,points,counts,indices)
    if index<0 {return -1}
    hull:=hull_get(w,w.pieces[index].hull)
    owner:=&w.breakables[d]
    for anchor in owner.anchors[:owner.anchor_count] {
        if math.aabb_overlaps(hull.aabb,anchor) {w.pieces[index].flags+={.Anchor}}
    }
    return index
}

@(private)
piece_append :: proc(w:^World,d:^Breakable,index:i32) {
    if d.piece_tail>=0 {w.pieces[d.piece_tail].next=index} else {d.piece_list=index}
    d.piece_tail=index
    d.piece_count+=1
}
@(private)
bond_append :: proc(w:^World,d:^Breakable,bond:Bond) -> bool {
    index:=bond_alloc(w)
    if index<0 {return false}
    w.bonds[index]=bond
    w.bonds[index].next=-1
    if d.bond_tail>=0 {w.bonds[d.bond_tail].next=index} else {d.bond_list=index}
    d.bond_tail=index
    d.bond_count+=1
    return true
}

// A shape of a breakable on a body: the hull of a piece, whose slot `owner` is, or of a cluster, which
// names one of its pieces. Its tag is that slot plus one. The mass of the body waits for settle.
@(private)
break_shape :: proc(w:^World,hull:Hull_Handle,body:Body_Handle,owner:i32) -> Shape_Handle {
    index:=w.pieces[owner].breakable
    d:=&w.breakables[index]
    desc:=Shape_Desc{
        geometry=hull,transform=TRANSFORM_IDENTITY,friction=d.friction,restitution=d.restitution,
        density=d.density,filter=d.filter,user_data=d.user_data,hits=.Impact_Damage in d.flags,tag=u32(owner)+1,
    }
    handle:=shape_create(w,body,desc,false)
    if handle=={} {
        w.breaking.refused[index]+={.Shapes}
        return {}
    }
    break_changed(w,body)
    return handle
}

// Puts the shape of a piece on a body.
@(private)
piece_attach :: proc(w:^World,index:i32,body:Body_Handle) -> bool {
    w.pieces[index].shape=break_shape(w,w.pieces[index].hull,body,index)
    return w.pieces[index].shape!={}
}

// Whether the shape of a piece is its own, not the one of a whole cluster it is in.
@(private)
piece_own_shape :: proc(w:^World,piece:^Piece) -> bool {
    return piece.hull!={} && shape_hull(w,piece.shape)==piece.hull
}

// Takes the own shape of a piece off its body.
@(private)
piece_detach :: proc(w:^World,index:i32) {
    if piece_own_shape(w,&w.pieces[index]) {
        break_changed(w,shape_body(w,w.pieces[index].shape))
        shape_destroy(w,w.pieces[index].shape,false)
    }
    w.pieces[index].shape={}
}

// Takes a piece out of the world; the body goes with its last shape. A removal takes every piece of a
// body, so the mass of the body is not updated.
@(private)
piece_remove :: proc(w:^World,index:i32) {
    piece:=&w.pieces[index]
    if shape_valid(w,piece.shape) {
        body:=shape_body(w,piece.shape)
        shape_destroy(w,piece.shape,false)
        if body_shapes(w,body,nil)==0 {body_destroy(w,body)}
    }
    piece.shape={}
    w.breakables[piece.breakable].revision+=1
    piece.flags+={.Gone}
}

@(private)
break_changed :: proc(w:^World,body:Body_Handle) {
    s:=&w.breaking
    slot:=body_slot(body)
    if s.changed[slot] {return}
    s.changed[slot]=true
    s.changed_list[s.changed_count]=body
    s.changed_count+=1
}

// The mass of every body whose shapes changed, once: what it holds now, with the velocity its center
// had where the center moves to.
@(private)
break_settle :: proc(w:^World) {
    s:=&w.breaking
    for body in s.changed_list[:s.changed_count] {
        if !s.changed[body_slot(body)] {continue}
        s.changed[body_slot(body)]=false
        body_mass_update(w,body)
    }
    s.changed_count=0
}

// The body every piece of the breakable is on, into the scratch: zero for one out of the world.
@(private)
break_bodies :: proc(w:^World,d:^Breakable) {
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        w.breaking.body[slot]=shape_body(w,w.pieces[slot].shape)
    }
}

// Gives every piece of the breakable the shape it collides with on the body that the scratch names
// for it: the hull of the outermost whole cluster above it, or its own. A cluster is whole while it is
// unbroken and every piece under it is on one body; with fold false none is. A piece without a body
// leaves the world. False when a shape did not fit: that piece is out of the world.
@(private)
break_collide :: proc(w:^World,index:i32,fold:bool) -> bool {
    d:=&w.breakables[index]
    s:=&w.breaking
    held:=s.cluster_body
    // The body slot under each cluster: -1 none seen yet, -2 none, -3 under a whole cluster with a hull,
    // -4 whole without a hull.
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        if .Cluster in w.bonds[slot].flags {held[slot]=fold && .Broken not_in w.bonds[slot].flags?-1:-2}
    }
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        body:i32=s.body[slot]=={}?-1:body_slot(s.body[slot])
        for above:=w.pieces[slot].cluster;above>=0;above=w.bonds[above].cluster {
            if body<0 {held[above]=-2} else if held[above]==-1 {held[above]=body} else if held[above]!=body {held[above]=-2}
        }
    }
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        if .Cluster not_in c.flags {continue}
        if c.cluster>=0 && (held[c.cluster]>=0 || held[c.cluster]==-3) {
            held[slot]=-3
        } else if c.b<0 && held[slot]>=0 {
            held[slot]=-4
        }
    }
    // The shape of a cluster stays while the cluster stands whole on its body.
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        if .Cluster not_in c.flags || c.b<0 {continue}
        phantom:=&w.pieces[c.b]
        valid:=shape_valid(w,phantom.shape)
        if valid && body_slot(shape_body(w,phantom.shape))==held[slot] {continue}
        if valid {
            break_changed(w,shape_body(w,phantom.shape))
            shape_destroy(w,phantom.shape,false)
        }
        phantom.shape={}
    }
    ok:=true
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        piece:=&w.pieces[slot]
        body:=s.body[slot]
        unit:i32=-1
        for above:=piece.cluster;above>=0 && body!={};above=w.bonds[above].cluster {
            if held[above]>=0 {unit=above;break}
        }
        if unit<0 && piece_own_shape(w,piece) && shape_body(w,piece.shape)==body {continue}
        piece_detach(w,slot)
        if body=={} {continue}
        if unit<0 {
            ok&&=piece_attach(w,slot,body)
            continue
        }
        c:=&w.bonds[unit]
        phantom:=&w.pieces[c.b]
        if !shape_valid(w,phantom.shape) {phantom.shape=break_shape(w,phantom.hull,body,c.a)}
        piece.shape=phantom.shape
        ok&&=piece.shape!={}
    }
    return ok
}

// Gives a cluster the slot of its hull: the convex hull of the points, or of the hulls of its pieces
// without points, weighing what its pieces weigh. A hull that would not hold their center of mass is
// left out, and the cluster collides as its pieces.
@(private)
cluster_hull_build :: proc(w:^World,index,cluster:i32,points:[]Vec3,counts,indices:^[dynamic]u8) {
    d:=&w.breakables[index]
    mass:Hull_Mass
    moment:Vec3
    inertia:Mat3
    gathered:=make([dynamic]Vec3,w.allocator)
    defer delete(gathered)
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        under:=false
        for above:=w.pieces[slot].cluster;above>=0 && !under;above=w.bonds[above].cluster {under=above==cluster}
        hull:=hull_get(w,w.pieces[slot].hull)
        if !under || hull==nil {continue}
        volume:=hull.volume
        mass.volume+=volume
        moment+=volume*hull.center
        inertia+=hull.inertia+mat3_point_inertia(volume,hull.center)
        if len(points)==0 {append(&gathered,..hull.vertices)}
    }
    if !(mass.volume>0) {return}
    mass.center=moment/mass.volume
    mass.inertia=inertia-mat3_point_inertia(mass.volume,mass.center)
    phantom:=piece_slot_build(w,index,len(points)>0?points:gathered[:],counts,indices,&mass)
    if phantom<0 {return}
    if hull:=hull_get(w,w.pieces[phantom].hull);!(hull.inner_radius>0) {
        piece_release(w,phantom)
        return
    }
    w.bonds[cluster].b=phantom
}

// Fractures a mesh into a breakable: one piece per connected part of each Voronoi cell, each with the convex hull of its part
// of the mesh as shape, connected to the pieces it shares a face with. It starts as one body, static if
// any piece is anchored and dynamic otherwise. A transaction that allocates: not for the middle of a tick.
breakable_create :: proc(w:^World,desc:Breakable_Desc) -> (handle:Breakable_Handle,error:Breakable_Error) {
    if !(desc.density>0) || !break_finite(desc.density,desc.friction,desc.restitution,desc.gravity_scale,desc.strength,desc.damage_threshold,desc.damage_radius,desc.debris_volume,
       desc.position.x,desc.position.y,desc.position.z,desc.rotation.x,desc.rotation.y,desc.rotation.z,desc.rotation.w) ||
       desc.friction<0 || desc.restitution<0 || desc.restitution>1 || desc.strength<0 || desc.damage_threshold<0 || desc.damage_radius<0 || desc.debris_volume<0 {return {},.Invalid_Desc}
    if desc.fracture==nil && (len(desc.sites)==0 || !geom.mesh_is_valid(desc.mesh) || len(desc.mesh.indices)==0) {return {},.Invalid_Desc}
    if len(desc.anchors)>BREAKABLE_ANCHOR_CAPACITY || w.kept {return {},.Invalid_Desc}
    if !breakables_make(w) {return {},.Out_Of_Memory}
    if w.breakable_free<0 && int(w.breakable_high)>=len(w.breakables) {
        w.stats.breakable_capacity_exhausted+=1
        return {},.Capacity
    }
    own:geom.Fracture
    defer if desc.fracture==nil {geom.fracture_destroy(&own)}
    fracture:=desc.fracture
    if fracture==nil {
        geom.fracture_init(&own,w.allocator)
        switch geom.mesh_fracture(&own,desc.mesh,desc.sites) {
        case .None:
        case .Out_Of_Memory: return {},.Out_Of_Memory
        case .Invalid_Mesh,.No_Sites: return {},.Invalid_Mesh
        }
        fracture=&own
    }
    count:=len(fracture.pieces)
    if count==0 {return {},.No_Pieces}
    if !break_source_valid(desc,fracture) {return {},.Invalid_Desc}
    world:=world_stats(w)
    if int(w.piece_count)+count+len(desc.clusters)>len(w.pieces) || int(w.bond_count)+len(fracture.connections)+len(desc.clusters)>len(w.bonds) ||
       world.shapes+count>w.desc.shape_capacity || world.bodies>=w.desc.body_capacity {
        w.stats.breakable_capacity_exhausted+=1
        return {},.Capacity
    }
    index:=w.breakable_free
    if index>=0 {
        w.breakable_free=w.breakables[index].next_free
    } else {
        index=w.breakable_high
        w.breakable_high+=1
    }
    w.breakable_count+=1
    d:=&w.breakables[index]
    d^={
        user_data=desc.user_data,piece_list=-1,piece_tail=-1,bond_list=-1,bond_tail=-1,
        density=desc.density,friction=desc.friction,restitution=desc.restitution,gravity_scale=desc.gravity_scale,
        strength=desc.strength,damage_threshold=desc.damage_threshold,damage_radius=desc.damage_radius,
        debris_volume=desc.debris_volume,debris_ticks=desc.debris_ticks,removal_ticks=desc.removal_ticks,
        hull_vertices=i32(clamp(desc.hull_vertices==0?32:desc.hull_vertices,4,HULL_MAX_VERTICES)),
        filter=desc.filter,anchor_count=i32(len(desc.anchors)),generation=d.generation+1,next_free=-1,
    }
    if desc.impact_damage {d.flags+={.Impact_Damage}}
    copy(d.anchors[:],desc.anchors)
    slots,slots_error:=make([]i32,count,w.allocator)
    cluster_slots,clusters_error:=make([]i32,len(desc.clusters),w.allocator)
    counts:=make([dynamic]u8,w.allocator)
    indices:=make([dynamic]u8,w.allocator)
    defer {
        delete(slots,w.allocator)
        delete(cluster_slots,w.allocator)
        delete(counts)
        delete(indices)
    }
    if slots_error!=nil || clusters_error!=nil {
        breakable_release(w,index)
        w.stats.breakable_capacity_exhausted+=1
        return {},.Capacity
    }
    hulls_refused:=world_stats(w).geometry_capacity_exhausted
    anchored:=false
    for _,i in fracture.pieces {
        slot:=piece_build(w,index,geom.fracture_piece_mesh(fracture,i).positions,&counts,&indices)
        slots[i]=slot
        if slot<0 {continue}
        w.piece_origins[slot].source=i32(i)
        w.pieces[slot].cluster=-1
        if len(desc.piece_anchors)>0 && desc.piece_anchors[i] {w.pieces[slot].flags+={.Anchor}}
        piece_append(w,d,slot)
        anchored||=.Anchor in w.pieces[slot].flags
    }
    failed:=world_stats(w).geometry_capacity_exhausted!=hulls_refused
    if !failed && d.piece_count==0 {
        breakable_release(w,index)
        return {},.No_Pieces
    }
    if !failed {
        body_desc:=BODY_DESC_DEFAULT
        body_desc.type=desc.kinematic?.Kinematic:anchored?.Static:.Dynamic
        body_desc.gravity_scale=desc.gravity_scale
        body_desc.position,body_desc.rotation=desc.position,desc.rotation==0?QUAT_IDENTITY:desc.rotation
        body_desc.user_data=desc.user_data
        d.body=body_create(w,body_desc)
        failed=d.body=={}
    }
    if failed {
        w.stats.breakable_capacity_exhausted+=1
        breakable_release(w,index)
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
        bond_append(w,d,{a=first,b=-1,flags={.Cluster},area=1,strength=cluster.strength,cluster=cluster.parent>=0?cluster_slots[cluster.parent]:-1})
        cluster_slots[at]=d.bond_tail
    }
    for piece_cluster,piece in desc.piece_clusters {
        if slots[piece]>=0 && piece_cluster>=0 {w.pieces[slots[piece]].cluster=cluster_slots[piece_cluster]}
    }
    for bond,at in fracture.connections {
        a,b:=slots[bond.a],slots[bond.b]
        if a<0 || b<0 {continue}
        strength:=len(desc.bond_strength)>0 && desc.bond_strength[at]>0?desc.bond_strength[at]:d.strength
        cluster:i32=-1
        if len(desc.piece_clusters)>0 {
            common:=break_cluster_common(desc.clusters,desc.piece_clusters[bond.a],desc.piece_clusters[bond.b])
            if common>=0 {cluster=cluster_slots[common]}
        }
        bond_append(w,d,{a=a,b=b,area=bond.area,strength=strength,cluster=cluster,center=0.5*(w.pieces[a].center+w.pieces[b].center)})
    }
    for cluster,at in desc.clusters {
        cluster_hull_build(w,index,cluster_slots[at],desc.cluster_points[cluster.first_point:][:cluster.point_count],&counts,&indices)
    }
    // Every piece starts on the first body, the whole clusters folded into their hulls.
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {w.breaking.body[slot]=d.body}
    failed=world_stats(w).geometry_capacity_exhausted!=hulls_refused || !break_collide(w,index,true)
    break_settle(w)
    if failed {
        w.stats.breakable_capacity_exhausted+=1
        breakable_release(w,index)
        return {},.Capacity
    }
    return breakable_handle(w,index),.None
}

// Removes the bodies and shapes of the breakable and frees its slots.
@(private)
breakable_release :: proc(w:^World,index:i32) {
    d:=&w.breakables[index]
    for slot:=d.piece_list;slot>=0; {
        next:=w.pieces[slot].next
        piece_remove(w,slot)
        piece_release(w,slot)
        slot=next
    }
    for slot:=d.bond_list;slot>=0; {
        next:=w.bonds[slot].next
        if c:=w.bonds[slot];.Cluster in c.flags && c.b>=0 {
            piece_remove(w,c.b)
            piece_release(w,c.b)
        }
        w.bonds[slot]={next=w.bond_free}
        w.bond_free=slot
        w.bond_count-=1
        slot=next
    }
    if body_valid(w,d.body) && body_shapes(w,d.body,nil)==0 {body_destroy(w,d.body)}
    d^={generation=d.generation+1,next_free=w.breakable_free}
    w.breakable_free=index
    w.breakable_count-=1
}

// Destroys every body the breakable has become. The hulls of its pieces stay registered until their
// slots are used again, so a copy taken before can still be restored.
breakable_destroy :: proc(w:^World,h:Breakable_Handle) {
    if d,index:=breakable_get(w,h);d!=nil {breakable_release(w,index)}
}

// The breakable made with this user data; zero without one.
breakable_find :: proc(w:^World,user_data:u64) -> Breakable_Handle {
    if w.kept {return {}}
    for &d,slot in w.breakables[:w.breakable_high] {
        if d.generation&1!=0 && d.user_data==user_data {return Breakable_Handle(base.handle_make(u32(slot),d.generation))}
    }
    return {}
}

// The body the breakable was created as: where its anchored pieces are, or its largest part.
breakable_body :: proc(w:^World,h:Breakable_Handle) -> Body_Handle {
    d,_:=breakable_get(w,h)
    return d!=nil?d.body:{}
}

// Changes what every piece meets, those that came off included.
breakable_set_filter :: proc(w:^World,h:Breakable_Handle,filter:Filter) {
    d,_:=breakable_get(w,h)
    if d==nil {return}
    d.filter=filter
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        if piece_own_shape(w,&w.pieces[slot]) {shape_set_filter(w,w.pieces[slot].shape,filter)}
    }
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        if c:=w.bonds[slot];.Cluster in c.flags && c.b>=0 {shape_set_filter(w,w.pieces[c.b].shape,filter)}
    }
}

// Pieces of the breakable, gone ones included, written to `out`; returns how many there are.
breakable_pieces :: proc(w:^World,h:Breakable_Handle,out:[]Piece_Info) -> int {
    d,_:=breakable_get(w,h)
    if d==nil {return 0}
    count:=0
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        piece:=&w.pieces[slot]
        if count<len(out) {
            origin:=w.piece_origins[slot]
            out[count]={
                id=slot,body=shape_body(w,piece.shape),shape=piece.shape,center=piece.center,volume=piece.volume,flags=piece.flags,group=piece.group,
                source=origin.source,parent=origin.parent,cut_normal=origin.plane,cut_offset=origin.offset,front=origin.front,
            }
        }
        count+=1
    }
    return count
}

// Bonds of the breakable, broken ones included; `a` and `b` are piece ids.
breakable_bonds :: proc(w:^World,h:Breakable_Handle,out:[]Bond_Info) -> int {
    d,_:=breakable_get(w,h)
    if d==nil {return 0}
    count:=0
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        if .Cluster in c.flags {continue}
        if count<len(out) {out[count]={c.a,c.b,c.area,c.strain,.Broken in c.flags}}
        count+=1
    }
    return count
}

// Mass of the pieces that are still in the world.
breakable_mass :: proc(w:^World,h:Breakable_Handle) -> f32 {
    d,_:=breakable_get(w,h)
    if d==nil {return 0}
    volume:f32
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        if .Gone not_in w.pieces[slot].flags {volume+=w.pieces[slot].volume}
    }
    return volume*d.density
}

@(private)
hull_to_mesh :: proc(hull:^Hull,out:^geom.Mesh_Buffer) {
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
breakable_piece_mesh :: proc(w:^World,h:Breakable_Handle,id:i32,out:^geom.Mesh_Buffer) -> bool {
    d,index:=breakable_get(w,h)
    if d==nil || id<0 || id>=w.piece_high || w.pieces[id].breakable!=index {return false}
    hull:=hull_get(w,w.pieces[id].hull)
    if hull==nil {return false}
    hull_to_mesh(hull,out)
    return true
}

// Damages the breakable around a world point: each bond within the radius takes the size of
// the impulse, fading to nothing at the radius; what comes off shares the impulse. Returns the event that
// repeats it elsewhere and whether anything broke.
breakable_damage :: proc(w:^World,h:Breakable_Handle,point:Vec3,radius:f32,impulse:Vec3) -> (event:Break_Event,broke:bool) {
    return breakable_strain(w,h,point,radius,length(impulse),impulse)
}

// Cuts the breakable by the plane through a world point: the pieces the plane crosses become two, each
// with a new hull, and the two sides come apart. Between ticks; it allocates.
breakable_slice :: proc(w:^World,h:Breakable_Handle,point,normal:Vec3) -> (event:Break_Event,cut:bool) {
    d,index:=breakable_get(w,h)
    if d==nil {return}
    w.breaking.tick=w.tick
    event={breakable=h,tick=u32(w.breaking.tick),piece=-1,point=point,vector=normal,kind=.Slice}
    return event,break_slice(w,index,&event)
}

// The same on the body that holds one piece alone, whose frame the event can then travel in: what the
// event does no longer depends on where the other bodies of the breakable are. strained: some
// bond of that body was within the radius.
breakable_damage_body :: proc(w:^World,h:Breakable_Handle,piece:i32,point:Vec3,radius:f32,impulse:Vec3) -> (event:Break_Event,broke,strained:bool) {
    d,index:=breakable_get(w,h)
    if d==nil || piece_body(w,index,piece)=={} {return}
    w.breaking.tick=w.tick
    event={breakable=h,tick=u32(w.breaking.tick),piece=piece,point=point,vector=impulse,radius=radius,kind=.Damage,strain=length(impulse),falloff=.Linear}
    broke,strained=break_damage(w,index,&event)
    return
}
breakable_slice_body :: proc(w:^World,h:Breakable_Handle,piece:i32,point,normal:Vec3) -> (event:Break_Event,cut:bool) {
    d,index:=breakable_get(w,h)
    if d==nil || piece_body(w,index,piece)=={} {return}
    w.breaking.tick=w.tick
    event={breakable=h,tick=u32(w.breaking.tick),piece=piece,point=point,vector=normal,kind=.Slice}
    return event,break_slice(w,index,&event)
}

breakable_remove_body :: proc(w:^World,h:Breakable_Handle,piece:i32) -> (event:Break_Event,removed:bool) {
    d,index:=breakable_get(w,h)
    if d==nil || piece_body(w,index,piece)=={} || w.pieces[piece].group==0 {return}
    w.breaking.tick=w.tick
    event={breakable=h,tick=u32(w.breaking.tick),piece=piece,kind=.Remove}
    return event,break_remove_body(w,index,piece)
}

// Steps until the pieces of the breakable on a body expire, and whether they do.
breakable_body_remaining_ticks :: proc(w:^World,h:Breakable_Handle,body:Body_Handle) -> (ticks:u32,expires:bool) {
    d,_:=breakable_get(w,h)
    if d==nil || !body_valid(w,body) {return}
    deadline:=max(u64)
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        piece:=&w.pieces[slot]
        if piece.group!=0 && piece.shape!={} && shape_body(w,piece.shape)==body {deadline=min(deadline,piece.expire)}
    }
    tick:=world_tick(w)
    if deadline!=max(u64) {return u32(min(u64(max(u32)),deadline>tick?deadline-tick:0)),true}
    return
}

// The body a piece of a breakable is on; zero for what is not a piece of it in the world.
@(private)
piece_body :: proc(w:^World,index,piece:i32) -> Body_Handle {
    if piece<0 || piece>=w.piece_high || w.pieces[piece].breakable!=index {return {}}
    return shape_body(w,w.pieces[piece].shape)
}

// Applies an event recorded by this world or by another one in the same state.
break_event_apply :: proc(w:^World,event:Break_Event) -> bool {
    d,index:=breakable_get(w,event.breakable)
    if d==nil {return false}
    e:=event
    if e.piece>=0 && piece_body(w,index,e.piece)=={} {return false}
    w.breaking.tick=w.tick
    switch e.kind {
    case .Damage,.Impact,.Weaken:
        broke,_:=break_damage(w,index,&e)
        return broke
    case .Slice: return break_slice(w,index,&e)
    case .Remove: return break_remove_body(w,index,e.piece)
    }
    return false
}

@(private)
break_damage :: proc(w:^World,index:i32,event:^Break_Event) -> (broke,strained:bool) {
    d:=&w.breakables[index]
    size:=event.strain
    if !(size>0) || event.falloff>.Logarithmic || !break_finite(size,event.radius,event.point.x,event.point.y,event.point.z,event.vector.x,event.vector.y,event.vector.z,
       event.half_extents.x,event.half_extents.y,event.half_extents.z,event.rotation.x,event.rotation.y,event.rotation.z,event.rotation.w) {return}
    if event.half_extents=={} {if !(event.radius>0) {return}}
    else if !(event.half_extents.x>0 && event.half_extents.y>0 && event.half_extents.z>0) {return}
    only:=piece_body(w,index,event.piece)
    broke,strained=break_clusters_damage(w,index,event,only)
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        if c.flags&{.Broken,.Cluster}!={} || c.cluster>=0 {continue}
        body:=shape_body(w,w.pieces[c.a].shape)
        if body=={} || event.piece>=0 && body!=only {continue}
        weight:=break_region_weight(event,xf_point(body_transform(w,body),c.center))
        if weight<=0 {continue}
        c.strain=min(max(f32),c.strain+size*weight)
        strained=true
        if event.kind!=.Weaken && c.strain>=c.strength*c.area {
            c.flags+={.Broken}
            broke=true
        }
    }
    if broke {breakable_regroup(w,index,event)}
    return
}

// Splits the bodies of a breakable along its broken bonds. In a static body the groups without
// an anchor come off; in a dynamic body, all but the largest. Each group becomes a dynamic body in the
// frame of the one it leaves, with its velocity there, and debris when it is small.
@(private)
breakable_regroup :: proc(w:^World,index:i32,event:^Break_Event) {
    d:=&w.breakables[index]
    s:=&w.breaking
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        s.parent[slot],s.group[slot]=slot,-1
        s.volume[slot],s.anchored[slot]=0,false
    }
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        if c.flags&{.Broken,.Cluster}=={} {union_join(s.parent,c.a,c.b)}
    }
    break_bodies(w,d)
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        from:=s.body[slot]
        if from=={} {continue}
        root:=union_find(s.parent,slot)
        s.volume[root]+=w.pieces[slot].volume
        if .Anchor in w.pieces[slot].flags {s.anchored[root]=true}
        s.keeper[body_slot(from)]=-1
    }
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        from:=s.body[slot]
        if from=={} || s.parent[slot]!=slot {continue}
        if keeper:=s.keeper[body_slot(from)];keeper<0 || s.volume[slot]>s.volume[keeper] {s.keeper[body_slot(from)]=slot}
    }
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        piece:=&w.pieces[slot]
        from:=s.body[slot]
        if from=={} || .Debris in piece.flags {continue}
        root:=union_find(s.parent,slot)
        if body_type(w,from)!=.Dynamic && .Anchored in d.flags?s.anchored[root]:s.keeper[body_slot(from)]==root {continue}
        if s.group[root]==-1 {
            xf:=body_transform(w,from)
            desc:=BODY_DESC_DEFAULT
            desc.gravity_scale=d.gravity_scale
            desc.position,desc.rotation,desc.user_data=xf.p,xf.q,d.user_data
            desc.debris=s.volume[root]<d.debris_volume
            created:=body_create(w,desc)
            if created=={} {
                w.stats.breakable_capacity_exhausted+=1
                s.refused[index]+={.Bodies}
                s.group[root]=-2
            } else {
                d.revision+=1
                s.ids[root]=d.revision
                s.group[root]=0
                s.made_body[root],s.from[root]=created,from
            }
        }
        if s.group[root]<0 {continue}
        to:=s.made_body[root]
        s.body[slot]=to
        piece.group=s.ids[root]
        piece.expire=d.removal_ticks>0?w.breaking.tick+u64(d.removal_ticks):max(u64)
        if body_is_debris(w,to) {
            piece.flags+={.Debris}
            piece.expire=w.breaking.tick+u64(d.debris_ticks)
        }
    }
    break_collide(w,index,true)
    // A body that came off weighs what it holds before it takes the velocity it had where it was.
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        if s.group[slot]==0 {
            body_mass_update(w,s.made_body[slot])
            s.changed[body_slot(s.made_body[slot])]=false
        }
    }
    // The groups leave with the velocity their body had where they were, and share the impulse of the
    // event by volume and closeness to its point.
    weight:f32
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        if s.group[slot]!=0 {continue}
        body,parent:=s.made_body[slot],s.from[slot]
        center:=body_center(w,body)
        parent_type:=body_type(w,parent)
        if parent_type!=.Static {
            angular:=body_angular_velocity(w,parent)
            body_set_velocity(w,body,body_linear_velocity(w,parent)+cross(angular,center-body_center(w,parent)),angular)
        }
        if event.kind==.Damage || (event.kind==.Impact && parent_type==.Static) {
            s.volume[slot]*=break_region_weight(event,center)
            weight+=s.volume[slot]
        } else {
            s.volume[slot]=0
        }
    }
    if weight>0 {
        for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
            if s.group[slot]!=0 {continue}
            body:=s.made_body[slot]
            body_set_linear_velocity(w,body,body_linear_velocity(w,body)+event.vector*(s.volume[slot]/weight*(1/body_mass(w,body))))
        }
    }
    break_settle(w)
}

// Whether the next `count` new piece slots find hulls: a slot used before builds over its own, any other
// takes a free hull slot. Slots beyond the capacity are not counted here.
@(private)
piece_hulls_available :: proc(w:^World,count:int) -> bool {
    needed:=0
    slot,high:=w.piece_free,w.piece_high
    for _ in 0..<count {
        index:i32
        if slot>=0 {
            index,slot=slot,w.pieces[slot].next
        } else if int(high)<len(w.pieces) {
            index,high=high,high+1
        } else {
            break
        }
        if hull:=w.piece_hulls[index];hull_get(w,hull)==nil || hull_in_use(w,hull) {needed+=1}
    }
    return needed==0 || hulls_free(w)>=needed
}

@(private)
break_slice :: proc(w:^World,index:i32,event:^Break_Event) -> bool {
    d:=&w.breakables[index]
    s:=&w.breaking
    normal:=normalize(event.vector)
    if normal=={} {return false}
    last_piece,last_connection:=d.piece_tail,d.bond_tail
    only:=piece_body(w,index,event.piece)
    // Side of each piece: 1 in front, -1 behind, 2 across the plane, 0 out of the cut.
    cuts,folded:=0,0
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        piece:=&w.pieces[slot]
        s.side[slot]=0
        body:=shape_body(w,piece.shape)
        hull:=hull_get(w,piece.hull)
        if body!={} && !piece_own_shape(w,piece) {folded+=1}
        if body=={} || hull==nil || .Debris in piece.flags || event.piece>=0 && body!=only {continue}
        xf:=body_transform(w,body)
        n:=q_rotate(conj(xf.q),normal)
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
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        if .Cluster in c.flags {
            if c.b<0 {continue}
            if shape_valid(w,w.pieces[c.b].shape) {standing+=1}
            continue
        }
        if .Broken in c.flags {continue}
        if s.side[c.a]==2 {connections+=1}
        if s.side[c.b]==2 {connections+=1}
    }
    // The pieces folded into whole clusters take their own shapes back: a cut ends the hierarchy.
    refused:Break_Capacities
    if int(w.piece_count)+2*cuts>len(w.pieces) {refused+={.Pieces}}
    if int(w.bond_count)+connections>len(w.bonds) {refused+={.Bonds}}
    if world_stats(w).shapes-standing+folded+cuts>w.desc.shape_capacity {refused+={.Shapes}}
    if !piece_hulls_available(w,2*cuts) {refused+={.Hulls}}
    if refused!={} {
        w.stats.breakable_capacity_exhausted+=1
        s.refused[index]+=refused
        return false
    }
    changed:=false
    if cuts>0 {
        break_bodies(w,d)
        break_collide(w,index,false)
        slicer:geom.Slicer
        buffers:[3]geom.Mesh_Buffer
        geom.slicer_init(&slicer,w.allocator)
        for &buffer in buffers {geom.mesh_buffer_init(&buffer,w.allocator)}
        counts:=make([dynamic]u8,w.allocator)
        indices:=make([dynamic]u8,w.allocator)
        defer {
            geom.slicer_destroy(&slicer)
            for &buffer in buffers {geom.mesh_buffer_destroy(&buffer)}
            delete(counts)
            delete(indices)
        }
        for slot:=d.piece_list;slot>=0; {
            current:=slot
            slot=current==last_piece?-1:w.pieces[current].next
            if s.side[current]!=2 {continue}
            piece:=w.pieces[current]
            body:=shape_body(w,piece.shape)
            xf:=body_transform(w,body)
            n:=q_rotate(conj(xf.q),normal)
            offset:=dot(n,xf_inv_point(xf,event.point))
            halves,halved:=piece_cut(w,index,current,n,offset,&slicer,&buffers,&counts,&indices)
            if !halved {
                // Too thin a cut to make two solids: the piece goes whole to the side of its center.
                s.side[current]=dot(n,piece.center)-offset>=0?1:-1
                continue
            }
            piece_detach(w,current)
            w.pieces[current].flags+={.Gone}
            d.revision+=1
            for half,k in halves {
                s.side[half]=k==0?1:-1
                piece_append(w,d,half)
                piece_attach(w,half,body)
            }
            s.group[current],s.source[current]=halves[0],halves[1]
            changed=true
        }
    }
    // A bond survives on each side where both of its pieces have a part.
    for slot:=d.bond_list;slot>=0; {
        current:=slot
        slot=current==last_connection?-1:w.bonds[current].next
        c:=w.bonds[current]
        if c.flags&{.Broken,.Cluster}!={} {continue}
        sa,sb:=s.side[c.a],s.side[c.b]
        if sa==sb && sa!=2 {continue}
        w.bonds[current].flags+={.Broken}
        changed=true
        if sa!=2 && sb!=2 {continue}
        scale:f32=sa==2 && sb==2?0.5:1
        for want,k in ([2]i8{1,-1}) {
            a:=sa==2?(k==0?s.group[c.a]:s.source[c.a]):sa==want?c.a:-1
            b:=sb==2?(k==0?s.group[c.b]:s.source[c.b]):sb==want?c.b:-1
            if a<0 || b<0 {continue}
            bond_append(w,d,{a=a,b=b,area=c.area*scale,strain=c.strain*scale,center=c.center,strength=c.strength,cluster=-1})
        }
    }
    if changed {
        for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
            c:=&w.bonds[slot]
            if .Cluster in c.flags {c.flags+={.Broken}} else {c.cluster=-1}
        }
        breakable_regroup(w,index,event)
    } else if cuts>0 {
        break_bodies(w,d)
        break_collide(w,index,true)
        break_settle(w)
    }
    return changed
}

// Lists an event of the step; one that does not fit counts against its breakable.
@(private)
break_push :: proc(w:^World,index:i32,event:Break_Event) {
    count:=w.events.counts[8]
    if count>=len(w.events.breaks) {
        w.breaking.lost[index]+=1
        w.stats.break_events_dropped+=1
        return
    }
    w.events.breaks[count]=event
    w.events.counts[8]=count+1
}

// The end of a step: its hits on a piece harder than the threshold of its breakable damage it around the
// hit point, and what expired leaves. The events are those of world_events(w).breaks.
@(private)
breakables_update :: proc(w:^World) {
    s:=&w.breaking
    if !s.made {return}
    mem.zero_slice(s.lost)
    mem.zero_slice(s.refused)
    if w.breakable_count==0 {return}
    s.tick=w.tick-1
    count:=0
    for hit in world_events(w).hit {
        shapes:=[2]Shape_Handle{hit.shape_a,hit.shape_b}
        for shape,side in shapes {
            tag:=shape_tag(w,shape)
            if tag==0 || i32(tag-1)>=w.piece_high || w.pieces[tag-1].shape!=shape {continue}
            piece:=&w.pieces[tag-1]
            if piece.flags&{.Debris,.Gone}!={} {continue}
            d:=&w.breakables[piece.breakable]
            if .Impact_Damage not_in d.flags || hit.impulse<d.damage_threshold {continue}
            // The normal goes from shape A to shape B: the impulse on each one points into it.
            s.hits[count]={
                breakable=breakable_handle(w,piece.breakable),tick=u32(w.breaking.tick),piece=i32(tag-1),point=hit.point,
                vector=hit.normal*(side==0?-hit.impulse:hit.impulse),radius=d.damage_radius,kind=.Impact,strain=hit.impulse,falloff=.Linear,
            }
            count+=1
        }
    }
    for &event in s.hits[:count] {
        if d,index:=breakable_get(w,event.breakable);d!=nil {
            break_damage(w,index,&event)
            break_push(w,index,event)
        }
    }
    for &d,index in w.breakables[:w.breakable_high] {
        // Only a broken breakable has bodies that expire.
        if d.generation&1==0 || d.revision==0 {continue}
        for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
            piece:=&w.pieces[slot]
            if .Gone in piece.flags {continue}
            if .Debris in piece.flags {
                if piece.expire<=w.breaking.tick {piece_remove(w,slot)}
                continue
            }
            if .Passive_Removal in d.flags {continue}
            body:=shape_body(w,piece.shape)
            if piece.group==0 || body=={} || piece.expire>w.breaking.tick && (.Remove_On_Sleep not_in d.flags || body_is_awake(w,body)) {continue}
            event:=Break_Event{breakable=breakable_handle(w,i32(index)),tick=u32(w.breaking.tick),piece=slot,kind=.Remove}
            if break_remove_body(w,i32(index),slot) {break_push(w,i32(index),event)}
        }
    }
}

// What the breakable could not get since its last step began: break events that did not fit in those of
// a step (World_Desc.event_capacity), whose damage was not done or not listed, and the capacities that
// refused it what a break or a cut needed.
breakable_shortfall :: proc(w:^World,h:Breakable_Handle) -> (events:int,refused:Break_Capacities) {
    d,index:=breakable_get(w,h)
    if d==nil {return}
    return int(w.breaking.lost[index]),w.breaking.refused[index]
}
