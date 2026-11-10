package ai

import "base:runtime"
import "core:math/linalg"
import "mirai:std/base"
import math "mirai:std/math"

// A navigation mesh: tiles on a square grid over XZ, each built apart
// (nav_build_tile, nav_tile_from_triangles) and added, replaced or removed at
// any time, and links that join two points of the surface (a jump, a ladder,
// a door). Polygons and links are named by Nav_Ref, which carries the slot and
// generation of their tile or link: a reference to something removed or
// replaced stops being valid instead of naming something else. Polygons know
// their neighbors inside their tile; the connections that cross to the next
// tile and those of links live in a pool of fixed capacity. Adding, replacing
// or removing a tile or a link does not allocate.

Nav_Ref :: distinct u64

// Positive when c lies to the left of the line a to b on the XZ plane drawn with x to the right and z up.
cross_xz :: #force_inline proc "contextless" (a,b,c:math.Vec3) -> f32 {return (b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x)}

// polygon: [15:0] polygon, [39:16] tile slot, [61:40] generation
// link:    [39:16] link slot, [61:40] generation, [62] crossed from its end, [63] set
NAV_REF_LINK :: u64(1)<<63
NAV_REF_REVERSE :: u64(1)<<62
NAV_SALT_MASK :: u32(1<<22-1)
NAV_SLOT_MAX :: 1<<24

nav_ref_make :: #force_inline proc "contextless" (salt,slot,index:u32) -> Nav_Ref {
    return Nav_Ref(u64(salt&NAV_SALT_MASK)<<40|u64(slot&(NAV_SLOT_MAX-1))<<16|u64(index&0xffff))
}
nav_ref_link :: #force_inline proc "contextless" (salt,slot:u32,reverse:bool) -> Nav_Ref {
    return Nav_Ref(NAV_REF_LINK|(NAV_REF_REVERSE if reverse else 0)|u64(salt&NAV_SALT_MASK)<<40|u64(slot&(NAV_SLOT_MAX-1))<<16)
}
nav_ref_is_link :: #force_inline proc "contextless" (ref:Nav_Ref) -> bool {return u64(ref)&NAV_REF_LINK!=0}
nav_ref_reverse :: #force_inline proc "contextless" (ref:Nav_Ref) -> bool {return u64(ref)&NAV_REF_REVERSE!=0}
nav_ref_salt :: #force_inline proc "contextless" (ref:Nav_Ref) -> u32 {return u32(u64(ref)>>40)&NAV_SALT_MASK}
nav_ref_slot :: #force_inline proc "contextless" (ref:Nav_Ref) -> u32 {return u32(u64(ref)>>16)&(NAV_SLOT_MAX-1)}
nav_ref_index :: #force_inline proc "contextless" (ref:Nav_Ref) -> u32 {return u32(u64(ref)&0xffff)}
// The same link crossed the other way; a polygon is itself.
nav_ref_flip :: #force_inline proc "contextless" (ref:Nav_Ref) -> Nav_Ref {
    return Nav_Ref(u64(ref)~NAV_REF_REVERSE) if nav_ref_is_link(ref) else ref
}

Nav_Tile :: struct {
    data:Nav_Tile_Data,
    salt:u32,
    next_free:i32,
    used:bool,
}

NAV_CONNECTION_LINK :: u8(0xff)
NAV_CONNECTION_ARRIVAL :: u8(0xfe)

// A way out of a polygon that its tile does not know: across an edge on the
// border of the tile into the polygon of the next tile, or onto a link.
Nav_Connection :: struct {
    to:Nav_Ref,
    next:u32,     // the next connection of the same polygon, index+1; 0 ends
    edge:u8,      // the edge it leaves through; NAV_CONNECTION_LINK onto a link; NAV_CONNECTION_ARRIVAL: no way out, a one-way link ends here
    low,high:u8,  // the part of the edge it covers, in 255ths from the first vertex of the edge
}

// What an agent must be able to do to cross a link.
Nav_Need :: struct {
    up:f32,        // m it climbs from its start to its end
    across:f32,    // m it spans on XZ without ground
    down:f32,      // m it falls
    abilities:u32, // bits the agent must all have: ladder, door...
}

Nav_Link_Desc :: struct {
    start,end:math.Vec3,
    radius:f32,     // how far from each end the surface may be found; 0: the cell of the agent
    kind:u8,        // what crossing it is, for whoever crosses: a jump, a drop, a ladder...
    two_way:bool,
    area:u8,        // whose cost the crossing pays per metre, besides `cost`
    cost:f32,
    need:Nav_Need,
    owner:u64,      // who made it: an entity, or the tile whose border generated it
}

Nav_Link :: struct {
    desc:Nav_Link_Desc,
    start_poly,end_poly:Nav_Ref, // where its ends rest; 0 while the surface there is missing
    start_point,end_point:math.Vec3, // on the surface
    salt:u32,
    next_free:i32,
    used:bool,
}

Nav_Mesh_Desc :: struct {
    origin:math.Vec3,     // corner of tile (0,0) on XZ
    tile_width:f32,       // m across a tile
    climb:f32,            // m two border edges may differ in height and still join
    max_tiles:int,
    max_links:int,
    max_connections:int,  // across tile borders and onto links; 0: 64 per tile and 2 per link
    allocator:runtime.Allocator,
}

Nav_Mesh :: struct {
    origin:math.Vec3,
    tile_width:f32,
    climb:f32,
    tiles:[]Nav_Tile,
    free_tile:i32,
    lookup:base.Hash_Map(u32), // tile coord to slot
    connections:[]Nav_Connection,
    free_connection:u32,       // index+1
    links:[]Nav_Link,
    free_link:i32,
    revision:u64,              // changes whenever a tile or a link is added or removed
    failed:u64,                // connections refused for lack of room
    allocator:runtime.Allocator,
}

nav_mesh_init :: proc(mesh:^Nav_Mesh,desc:Nav_Mesh_Desc) -> bool {
    allocator:=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    mesh^={allocator=allocator}
    if desc.max_tiles<=0 || desc.max_tiles>NAV_SLOT_MAX || desc.max_links<0 || desc.max_links>NAV_SLOT_MAX || desc.max_connections<0 {return false}
    if !(desc.tile_width>0) || desc.tile_width>1e9 || !(desc.climb>=0) || desc.climb>1e9 {return false}
    for x in desc.origin {if !(abs(x)<=1e9) {return false}}
    connections:=desc.max_connections if desc.max_connections>0 else desc.max_tiles*64+desc.max_links*2
    if connections>int(max(u32))-1 {return false}
    e1,e2,e3:runtime.Allocator_Error
    mesh.tiles,e1=make([]Nav_Tile,desc.max_tiles,allocator)
    mesh.links,e2=make([]Nav_Link,desc.max_links,allocator)
    mesh.connections,e3=make([]Nav_Connection,connections,allocator)
    if e1!=nil || e2!=nil || e3!=nil || !base.hash_map_init(&mesh.lookup,desc.max_tiles,allocator) {nav_mesh_destroy(mesh);return false}
    mesh.origin,mesh.tile_width,mesh.climb=desc.origin,desc.tile_width,desc.climb
    for &tile,i in mesh.tiles {tile.next_free=i32(i+1) if i+1<len(mesh.tiles) else -1;tile.salt=1}
    for &link,i in mesh.links {link.next_free=i32(i+1) if i+1<len(mesh.links) else -1;link.salt=1}
    mesh.free_link=0 if len(mesh.links)>0 else -1
    for &c,i in mesh.connections {c.next=u32(i+2) if i+1<len(mesh.connections) else 0}
    mesh.free_connection=1 if len(mesh.connections)>0 else 0
    return true
}
nav_mesh_destroy :: proc(mesh:^Nav_Mesh) {
    if mesh.allocator.procedure!=nil {
        for &tile in mesh.tiles {if tile.used {nav_tile_data_free(&tile.data)}}
        delete(mesh.tiles,mesh.allocator);delete(mesh.links,mesh.allocator);delete(mesh.connections,mesh.allocator)
        base.hash_map_destroy(&mesh.lookup)
    }
    mesh^={}
}

@(private)
nav_coord_key :: #force_inline proc "contextless" (coord:[2]i32) -> u64 {return u64(u32(coord.x))<<32|u64(u32(coord.y))}

// The tile coordinate a point falls in.
nav_mesh_coord :: proc "contextless" (mesh:^Nav_Mesh,point:math.Vec3) -> [2]i32 {
    if !(mesh.tile_width>0) {return {}}
    fx,fz:=(point.x-mesh.origin.x)/mesh.tile_width,(point.z-mesh.origin.z)/mesh.tile_width
    clamp_coord :: #force_inline proc "contextless" (f:f32) -> i32 {
        if !(f>-2e9) {return -2_000_000_000}
        if !(f<2e9) {return 2_000_000_000}
        i:=i32(f)
        return i-1 if f32(i)>f else i
    }
    return {clamp_coord(fx),clamp_coord(fz)}
}

nav_mesh_tile_at :: proc "contextless" (mesh:^Nav_Mesh,coord:[2]i32) -> ^Nav_Tile {
    slot,found:=base.hash_map_get(&mesh.lookup,nav_coord_key(coord))
    if !found {return nil}
    return &mesh.tiles[slot]
}

// The tile and polygon a reference names, or nil when it is not a valid polygon.
nav_poly_of :: proc "contextless" (mesh:^Nav_Mesh,ref:Nav_Ref) -> (tile:^Nav_Tile,poly:^Nav_Poly) {
    if ref==0 || u64(ref)&(NAV_REF_LINK|NAV_REF_VOLUME)!=0 {return}
    slot:=nav_ref_slot(ref)
    if int(slot)>=len(mesh.tiles) {return}
    t:=&mesh.tiles[slot]
    index:=nav_ref_index(ref)
    if !t.used || t.salt!=nav_ref_salt(ref) || int(index)>=len(t.data.polys) {return}
    return t,&t.data.polys[index]
}
// The link a reference names, or nil.
nav_link_of :: proc "contextless" (mesh:^Nav_Mesh,ref:Nav_Ref) -> ^Nav_Link {
    if !nav_ref_is_link(ref) {return nil}
    slot:=nav_ref_slot(ref)
    if int(slot)>=len(mesh.links) {return nil}
    link:=&mesh.links[slot]
    if !link.used || link.salt!=nav_ref_salt(ref) {return nil}
    return link
}
nav_ref_valid :: proc "contextless" (mesh:^Nav_Mesh,ref:Nav_Ref) -> bool {
    if nav_ref_is_link(ref) {return nav_link_of(mesh,ref)!=nil}
    _,poly:=nav_poly_of(mesh,ref)
    return poly!=nil
}
// The reference of a polygon of a tile.
nav_tile_ref :: proc "contextless" (mesh:^Nav_Mesh,tile:^Nav_Tile,index:int) -> Nav_Ref {
    slot:=u32((uintptr(tile)-uintptr(raw_data(mesh.tiles)))/size_of(Nav_Tile))
    return nav_ref_make(tile.salt,slot,u32(index))
}

// The vertices of a polygon, in their order.
nav_poly_vertices :: proc "contextless" (tile:^Nav_Tile,poly:^Nav_Poly,out:^[NAV_VERTS_PER_POLY]math.Vec3) -> int {
    count:=min(int(poly.count),NAV_VERTS_PER_POLY)
    for i in 0..<count {
        v:=int(poly.vertices[i])
        out[i]=tile.data.vertices[v] if v<len(tile.data.vertices) else {}
    }
    return count
}
nav_poly_center :: proc "contextless" (tile:^Nav_Tile,poly:^Nav_Poly) -> math.Vec3 {
    corners:[NAV_VERTS_PER_POLY]math.Vec3
    count:=nav_poly_vertices(tile,poly,&corners)
    center:math.Vec3
    for i in 0..<count {center+=corners[i]}
    return center/f32(max(count,1))
}

@(private)
nav_connection_take :: proc "contextless" (mesh:^Nav_Mesh) -> u32 {
    index:=mesh.free_connection
    if index==0 {mesh.failed+=1;return 0}
    mesh.free_connection=mesh.connections[index-1].next
    mesh.connections[index-1]={}
    return index
}
@(private)
nav_connection_give :: proc "contextless" (mesh:^Nav_Mesh,index:u32) {
    mesh.connections[index-1]={next=mesh.free_connection}
    mesh.free_connection=index
}
// Adds a connection at the head of the chain of a polygon.
@(private)
nav_connect :: proc "contextless" (mesh:^Nav_Mesh,tile:^Nav_Tile,poly:int,c:Nav_Connection) -> bool {
    index:=nav_connection_take(mesh)
    if index==0 {return false}
    mesh.connections[index-1]=c
    mesh.connections[index-1].next=tile.data.poly_links[poly]
    tile.data.poly_links[poly]=index
    return true
}
// Removes from the chains of every polygon of a tile the connections whose
// target the predicate accepts.
@(private)
nav_disconnect :: proc "contextless" (mesh:^Nav_Mesh,tile:^Nav_Tile,target:Nav_Ref,by_slot:bool) {
    for &head in tile.data.poly_links {
        previous:=&head
        for previous^!=0 {
            index:=previous^
            c:=mesh.connections[index-1]
            gone:=c.to==target
            if by_slot {gone=!nav_ref_is_link(c.to) && !nav_ref_is_link(target) && nav_ref_slot(c.to)==nav_ref_slot(target)}
            if gone {previous^=c.next;nav_connection_give(mesh,index)} else {previous=&mesh.connections[index-1].next}
        }
    }
}

// Adds a tile, taking its data: the mesh frees it when the tile is replaced,
// removed or the mesh destroyed. A tile at the same coordinate is replaced.
// Its borders join the tiles beside it and the links whose ends fall on it
// rest on it. False, leaving the data to the caller, when it has no polygons,
// its arrays disagree, or the mesh has no slot left.
nav_mesh_add_tile :: proc(mesh:^Nav_Mesh,data:Nav_Tile_Data) -> bool {
    if len(data.polys)==0 || len(data.poly_links)!=len(data.polys) || len(data.details)!=0 && len(data.details)!=len(data.polys) {return false}
    if len(data.polys)>0xffff || len(data.vertices)>0xffff {return false}
    for poly in data.polys {
        if poly.count<3 || poly.count>NAV_VERTS_PER_POLY {return false}
        for i in 0..<int(poly.count) {
            if int(poly.vertices[i])>=len(data.vertices) {return false}
            n:=poly.neighbor[i]
            if n!=NAV_EDGE_WALL && n&NAV_EDGE_PORTAL==0 && int(n)>len(data.polys) {return false}
            if n&NAV_EDGE_PORTAL!=0 && int(n&~NAV_EDGE_PORTAL)>=len(Nav_Side) {return false}
        }
    }
    for detail in data.details {
        if int(detail.vertex_first)+int(detail.vertex_count)>len(data.detail_vertices) || int(detail.triangle_first)+int(detail.triangle_count)>len(data.detail_triangles) {return false}
    }
    nav_mesh_remove_tile(mesh,data.coord)
    if mesh.free_tile<0 || len(mesh.tiles)==0 {return false}
    slot:=mesh.free_tile
    tile:=&mesh.tiles[slot]
    if !base.hash_map_set(&mesh.lookup,nav_coord_key(data.coord),u32(slot)) {return false}
    mesh.free_tile=tile.next_free
    tile.data=data
    tile.used=true
    tile.next_free=-1
    for &head in tile.data.poly_links {head=0}
    offsets:=NAV_SIDE_OFFSET
    for side in Nav_Side {
        other:=nav_mesh_tile_at(mesh,data.coord+offsets[side])
        if other==nil {continue}
        nav_connect_side(mesh,tile,other,side)
        nav_connect_side(mesh,other,tile,nav_side_opposite(side))
    }
    for &link,i in mesh.links {
        if link.used && (link.start_poly==0 || link.end_poly==0) {nav_link_rest(mesh,u32(i))}
    }
    mesh.revision+=1
    return true
}

// Removes the tile at a coordinate, and every connection into it. Links that
// rested on it wait for a tile there again.
nav_mesh_remove_tile :: proc(mesh:^Nav_Mesh,coord:[2]i32) -> bool {
    slot,found:=base.hash_map_get(&mesh.lookup,nav_coord_key(coord))
    if !found {return false}
    tile:=&mesh.tiles[slot]
    probe:=nav_ref_make(tile.salt,slot,0)
    offsets:=NAV_SIDE_OFFSET
    for side in Nav_Side {
        other:=nav_mesh_tile_at(mesh,coord+offsets[side])
        if other!=nil {nav_disconnect(mesh,other,probe,true)}
    }
    for &link,i in mesh.links {
        if !link.used {continue}
        on_start:=link.start_poly!=0 && nav_ref_slot(link.start_poly)==slot
        on_end:=link.end_poly!=0 && nav_ref_slot(link.end_poly)==slot
        if on_start || on_end {nav_link_lift(mesh,u32(i))}
    }
    for &head in tile.data.poly_links {
        for head!=0 {
            index:=head
            head=mesh.connections[index-1].next
            nav_connection_give(mesh,index)
        }
    }
    base.hash_map_remove(&mesh.lookup,nav_coord_key(coord))
    nav_tile_data_free(&tile.data)
    tile.used=false
    tile.salt=(tile.salt+1)&NAV_SALT_MASK
    if tile.salt==0 {tile.salt=1}
    tile.next_free=mesh.free_tile
    mesh.free_tile=i32(slot)
    mesh.revision+=1
    return true
}

nav_side_opposite :: #force_inline proc "contextless" (side:Nav_Side) -> Nav_Side {return Nav_Side((u8(side)+2)%4)}

// Joins the portal edges of `tile` on `side` with the overlapping portal edges
// of `other` facing back.
@(private)
nav_connect_side :: proc "contextless" (mesh:^Nav_Mesh,tile,other:^Nav_Tile,side:Nav_Side) {
    want:=NAV_EDGE_PORTAL|u16(side)
    back:=NAV_EDGE_PORTAL|u16(nav_side_opposite(side))
    along_z:=side==.Pos_X || side==.Neg_X
    for &poly,p in tile.data.polys {
        count:=int(poly.count)
        for e in 0..<count {
            if poly.neighbor[e]!=want {continue}
            a,b:=tile.data.vertices[poly.vertices[e]],tile.data.vertices[poly.vertices[(e+1)%count]]
            axis:=2 if along_z else 0
            a0,a1:=a[axis],b[axis]
            for &other_poly,q in other.data.polys {
                other_count:=int(other_poly.count)
                for f in 0..<other_count {
                    if other_poly.neighbor[f]!=back {continue}
                    c,d:=other.data.vertices[other_poly.vertices[f]],other.data.vertices[other_poly.vertices[(f+1)%other_count]]
                    across:=abs(a.x-c.x) if along_z else abs(a.z-c.z)
                    if across>mesh.tile_width*1e-4+1e-4 {continue}
                    b0,b1:=c[axis],d[axis]
                    low,high:=max(min(a0,a1),min(b0,b1)),min(max(a0,a1),max(b0,b1))
                    if high-low<=1e-4 {continue}
                    // Heights of both edges at the ends of the overlap must agree within the climb.
                    height :: proc "contextless" (p,q:math.Vec3,at:f32,axis:int) -> f32 {
                        p0,p1:=p[axis],q[axis]
                        if abs(p1-p0)<1e-6 {return p.y}
                        return p.y+(q.y-p.y)*(at-p0)/(p1-p0)
                    }
                    if abs(height(a,b,low,axis)-height(c,d,low,axis))>mesh.climb+1e-3 || abs(height(a,b,high,axis)-height(c,d,high,axis))>mesh.climb+1e-3 {continue}
                    span:=a1-a0
                    t0,t1:f32=0,1
                    if abs(span)>1e-6 {t0,t1=(low-a0)/span,(high-a0)/span}
                    if t0>t1 {t0,t1=t1,t0}
                    to:=nav_tile_ref(mesh,other,q)
                    nav_connect(mesh,tile,p,{to=to,edge=u8(e),low=u8(clamp(t0,0,1)*255+0.5),high=u8(clamp(t1,0,1)*255+0.5)})
                }
            }
        }
    }
}

// Adds a link. It rests on the surface at each end as soon as the tiles there
// exist. 0 when no slot is left or the description is not finite.
nav_mesh_add_link :: proc "contextless" (mesh:^Nav_Mesh,desc:Nav_Link_Desc) -> Nav_Ref {
    for v in ([2]math.Vec3{desc.start,desc.end}) {for x in v {if !(abs(x)<=1e9) {return 0}}}
    if !(desc.radius>=0) || !(desc.cost>=0) || desc.area>NAV_AREA_MAX {return 0}
    if mesh.free_link<0 || len(mesh.links)==0 {return 0}
    slot:=u32(mesh.free_link)
    link:=&mesh.links[slot]
    mesh.free_link=link.next_free
    link.desc=desc
    link.used=true
    link.next_free=-1
    link.start_poly,link.end_poly=0,0
    nav_link_rest(mesh,slot)
    mesh.revision+=1
    return nav_ref_link(link.salt,slot,false)
}
nav_mesh_remove_link :: proc "contextless" (mesh:^Nav_Mesh,ref:Nav_Ref) -> bool {
    link:=nav_link_of(mesh,ref)
    if link==nil {return false}
    slot:=nav_ref_slot(ref)
    nav_link_lift(mesh,slot)
    link.used=false
    link.salt=(link.salt+1)&NAV_SALT_MASK
    if link.salt==0 {link.salt=1}
    link.next_free=mesh.free_link
    mesh.free_link=i32(slot)
    mesh.revision+=1
    return true
}
// Removes every link of an owner; how many.
nav_mesh_remove_links_of :: proc "contextless" (mesh:^Nav_Mesh,owner:u64) -> (removed:int) {
    for &link,i in mesh.links {
        if link.used && link.desc.owner==owner {
            nav_mesh_remove_link(mesh,nav_ref_link(link.salt,u32(i),false))
            removed+=1
        }
    }
    return
}

// Rests the ends of a link on the surface where they are missing, and
// connects it from its start (and its end if it goes both ways) once both
// rest. A one-way link is known at its end too, as an arrival: a search
// toward a point walks the links against their way.
@(private)
nav_link_rest :: proc "contextless" (mesh:^Nav_Mesh,slot:u32) {
    link:=&mesh.links[slot]
    reach:=link.desc.radius if link.desc.radius>0 else mesh.tile_width/64
    extents:=math.Vec3{reach,max(reach,mesh.climb*2),reach}
    if link.start_poly==0 {link.start_poly,link.start_point,_=nav_find_nearest_any(mesh,link.desc.start,extents)}
    if link.end_poly==0 {link.end_poly,link.end_point,_=nav_find_nearest_any(mesh,link.desc.end,extents)}
    if link.start_poly==0 || link.end_poly==0 {return}
    if tile,_:=nav_poly_of(mesh,link.start_poly);tile!=nil {
        nav_connect(mesh,tile,int(nav_ref_index(link.start_poly)),{to=nav_ref_link(link.salt,slot,false),edge=NAV_CONNECTION_LINK})
    }
    if tile,_:=nav_poly_of(mesh,link.end_poly);tile!=nil {
        if link.desc.two_way {
            nav_connect(mesh,tile,int(nav_ref_index(link.end_poly)),{to=nav_ref_link(link.salt,slot,true),edge=NAV_CONNECTION_LINK})
        } else {
            nav_connect(mesh,tile,int(nav_ref_index(link.end_poly)),{to=nav_ref_link(link.salt,slot,false),edge=NAV_CONNECTION_ARRIVAL})
        }
    }
}
// Takes a link off the surface: it no longer leads anywhere until it rests again.
@(private)
nav_link_lift :: proc "contextless" (mesh:^Nav_Mesh,slot:u32) {
    link:=&mesh.links[slot]
    if tile,_:=nav_poly_of(mesh,link.start_poly);tile!=nil {nav_disconnect(mesh,tile,nav_ref_link(link.salt,slot,false),false)}
    if tile,_:=nav_poly_of(mesh,link.end_poly);tile!=nil {
        // Its way back, or its arrival.
        nav_disconnect(mesh,tile,nav_ref_link(link.salt,slot,true),false)
        nav_disconnect(mesh,tile,nav_ref_link(link.salt,slot,false),false)
    }
    link.start_poly,link.end_poly=0,0
}

// The ends of a node seen as a step of a path. For a polygon both are its
// center; a link is entered at its start point and left at its end point (or
// the other way when it is crossed from its end).
nav_link_ends :: proc "contextless" (link:^Nav_Link,ref:Nav_Ref) -> (from,to:math.Vec3,from_poly,to_poly:Nav_Ref) {
    if nav_ref_reverse(ref) {return link.end_point,link.start_point,link.end_poly,link.start_poly}
    return link.start_point,link.end_point,link.start_poly,link.end_poly
}

// The neighbors of a node: the polygons across its edges and connections, the
// links leaving it, or the polygon a link leads to. With `arrivals`, the
// one-way links that end on it as well, each as NAV_CONNECTION_ARRIVAL: what
// leads to the node, for a search against the way agents walk.
Nav_Step :: struct {
    to:Nav_Ref,
    edge:u8,     // of the polygon left; NAV_CONNECTION_LINK onto or off a link
    low,high:u8, // the part of the edge, in 255ths
}
Nav_Steps :: struct {
    mesh:^Nav_Mesh,
    tile:^Nav_Tile,
    poly:^Nav_Poly,
    from:Nav_Ref,
    edge:int,
    chain:u32,
    done:bool,
    arrivals:bool,
}
nav_steps :: proc "contextless" (mesh:^Nav_Mesh,from:Nav_Ref,arrivals:=false) -> (it:Nav_Steps) {
    it.mesh,it.from,it.arrivals=mesh,from,arrivals
    if nav_ref_is_link(from) {return}
    it.tile,it.poly=nav_poly_of(mesh,from)
    if it.poly==nil {it.done=true;return}
    it.chain=it.tile.data.poly_links[nav_ref_index(from)]
    return
}
nav_steps_next :: proc "contextless" (it:^Nav_Steps) -> (step:Nav_Step,ok:bool) {
    if it.done {return}
    if nav_ref_is_link(it.from) {
        it.done=true
        link:=nav_link_of(it.mesh,it.from)
        if link==nil {return}
        _,_,_,to:=nav_link_ends(link,it.from)
        if to==0 {return}
        return {to=to,edge=NAV_CONNECTION_LINK,high=255},true
    }
    for it.edge<int(it.poly.count) {
        e:=it.edge
        it.edge+=1
        n:=it.poly.neighbor[e]
        if n==NAV_EDGE_WALL || n&NAV_EDGE_PORTAL!=0 {continue}
        return {to=nav_tile_ref(it.mesh,it.tile,int(n)-1),edge=u8(e),high=255},true
    }
    for it.chain!=0 {
        c:=it.mesh.connections[it.chain-1]
        it.chain=c.next
        if c.edge==NAV_CONNECTION_ARRIVAL && !it.arrivals {continue}
        return {to=c.to,edge=c.edge,low=c.low,high=c.high},true
    }
    it.done=true
    return
}

// The portal crossed going from one node to the next, seen from the first:
// `left` and `right` such that cross_xz(inside, right, left) > 0 for a point
// inside the first polygon. A link is a single point: where it is entered or
// left.
nav_portal_points :: proc "contextless" (mesh:^Nav_Mesh,from,to:Nav_Ref) -> (left,right:math.Vec3,ok:bool) {
    if nav_ref_is_link(to) {
        link:=nav_link_of(mesh,to)
        if link==nil {return}
        start,_,_,_:=nav_link_ends(link,to)
        return start,start,true
    }
    if nav_ref_is_link(from) {
        link:=nav_link_of(mesh,from)
        if link==nil {return}
        _,end,_,_:=nav_link_ends(link,from)
        return end,end,true
    }
    tile,poly:=nav_poly_of(mesh,from)
    if poly==nil {return}
    it:=nav_steps(mesh,from)
    for step in nav_steps_next(&it) {
        if step.to!=to || step.edge==NAV_CONNECTION_LINK {continue}
        count:=int(poly.count)
        a:=tile.data.vertices[poly.vertices[step.edge]]
        b:=tile.data.vertices[poly.vertices[(int(step.edge)+1)%count]]
        if step.low!=0 || step.high!=255 {
            lo,hi:=f32(step.low)/255,f32(step.high)/255
            a,b=a+(b-a)*lo,a+(b-a)*hi
        }
        center:=nav_poly_center(tile,poly)
        if cross_xz(center,a,b)>0 {return b,a,true}
        return a,b,true
    }
    return
}

// Whether an agent that can do `can` may cross the link.
nav_link_crossable :: proc "contextless" (link:^Nav_Link,can:Nav_Need) -> bool {
    need:=link.desc.need
    return need.up<=can.up && need.across<=can.across && need.down<=can.down && need.abilities&~can.abilities==0
}

@(private)
nav_point_in_poly_xz :: proc "contextless" (point:math.Vec3,corners:[]math.Vec3) -> bool {
    inside:=false
    j:=len(corners)-1
    for i in 0..<len(corners) {
        a,b:=corners[i],corners[j]
        if (a.z>point.z)!=(b.z>point.z) && point.x<(b.x-a.x)*(point.z-a.z)/(b.z-a.z)+a.x {inside=!inside}
        j=i
    }
    return inside
}

// The height of the surface of a polygon at the XZ of a point, from its
// detail triangles (its own vertices without them). False when the point is
// not over the polygon.
nav_poly_height :: proc "contextless" (mesh:^Nav_Mesh,ref:Nav_Ref,point:math.Vec3) -> (height:f32,ok:bool) {
    tile,poly:=nav_poly_of(mesh,ref)
    if poly==nil {return}
    corners:[NAV_VERTS_PER_POLY]math.Vec3
    count:=nav_poly_vertices(tile,poly,&corners)
    index:=int(nav_ref_index(ref))
    if index<len(tile.data.details) {
        detail:=tile.data.details[index]
        for t in 0..<int(detail.triangle_count) {
            tri:=tile.data.detail_triangles[int(detail.triangle_first)+t]
            v:[3]math.Vec3
            for k in 0..<3 {v[k]=nav_detail_vertex(tile,poly,detail,tri[k],corners[:count])}
            if y,inside:=nav_triangle_height(point,v[0],v[1],v[2]);inside {return y,true}
        }
    } else {
        for i in 1..<count-1 {
            if y,inside:=nav_triangle_height(point,corners[0],corners[i],corners[i+1]);inside {return y,true}
        }
    }
    return
}
@(private)
nav_detail_vertex :: #force_inline proc "contextless" (tile:^Nav_Tile,poly:^Nav_Poly,detail:Nav_Detail,index:u8,corners:[]math.Vec3) -> math.Vec3 {
    if int(index)<len(corners) {return corners[index]}
    at:=int(detail.vertex_first)+int(index)-len(corners)
    return tile.data.detail_vertices[at] if at<len(tile.data.detail_vertices) else corners[0]
}
@(private)
nav_triangle_height :: proc "contextless" (p,a,b,c:math.Vec3) -> (y:f32,inside:bool) {
    area:=cross_xz(a,b,c)
    if abs(area)<1e-12 {return}
    wa,wb,wc:=cross_xz(p,b,c)/area,cross_xz(a,p,c)/area,cross_xz(a,b,p)/area
    tolerance:=f32(-1e-4)
    if wa<tolerance || wb<tolerance || wc<tolerance {return}
    return a.y*wa+b.y*wb+c.y*wc,true
}

// The point of a polygon nearest to `point`: over it, at its surface; else on
// its nearest boundary edge.
nav_closest_point_on_poly :: proc "contextless" (mesh:^Nav_Mesh,ref:Nav_Ref,point:math.Vec3) -> (closest:math.Vec3,over:bool) {
    tile,poly:=nav_poly_of(mesh,ref)
    if poly==nil {return point,false}
    if y,inside:=nav_poly_height(mesh,ref,point);inside {return {point.x,y,point.z},true}
    corners:[NAV_VERTS_PER_POLY]math.Vec3
    count:=nav_poly_vertices(tile,poly,&corners)
    best:=f32(max(f32))
    for i in 0..<count {
        a,b:=corners[i],corners[(i+1)%count]
        flat:=math.Vec3{point.x,0,point.z}
        on,t:=math.closest_point_segment(flat,{{a.x,0,a.z},{b.x,0,b.z}})
        d:=linalg.length2(on-flat)
        if d<best {best=d;closest=a+(b-a)*t}
    }
    return closest,false
}

// The valid polygon nearest to a point within a box of half extents around it,
// over every tile the box touches, and its nearest point. Distance counts
// the height only where the point is over the polygon, so a floor right
// under the point wins over a nearer edge beside it.
nav_find_nearest_any :: proc "contextless" (mesh:^Nav_Mesh,point,extents:math.Vec3) -> (ref:Nav_Ref,nearest:math.Vec3,ok:bool) {
    return nav_find_nearest(mesh,point,extents,nil)
}
nav_find_nearest :: proc "contextless" (mesh:^Nav_Mesh,point,extents:math.Vec3,filter:^Nav_Filter) -> (ref:Nav_Ref,nearest:math.Vec3,ok:bool) {
    for x in point {if !(abs(x)<=1e9) {return}}
    for x in extents {if !(x>=0) || !(x<=1e9) {return}}
    best:=f32(max(f32))
    it:=nav_box_polys(mesh,{point-extents,point+extents})
    for r in nav_box_polys_next(&it) {
        if filter!=nil && !nav_filter_passes(filter,it.tile.data.polys[nav_ref_index(r)].area) {continue}
        closest,over:=nav_closest_point_on_poly(mesh,r,point)
        d:f32
        if over {
            dy:=abs(closest.y-point.y)
            d=dy*dy
        } else {
            d=linalg.length2(closest-point)
        }
        if d<best || (d==best && r<ref) {best=d;ref=r;nearest=closest}
    }
    return ref,nearest,ref!=0
}

// The polygons whose boxes overlap a box (by their tree where a tile has one),
// over at most 64 tiles across:
//     it:=nav_box_polys(mesh,box)
//     for ref in nav_box_polys_next(&it) {...} // it.tile is the tile of ref
Nav_Box_Polys :: struct {
    mesh:^Nav_Mesh,
    box:math.Aabb,
    low,high,at:[2]i32,
    tile:^Nav_Tile,
    cells:[2][3]u16,
    node:int,
    done:bool,
}
nav_box_polys :: proc "contextless" (mesh:^Nav_Mesh,box:math.Aabb) -> (it:Nav_Box_Polys) {
    it.mesh,it.box=mesh,box
    it.done=true
    for x in box.min {if !(abs(x)<=1e9) {return}}
    for x in box.max {if !(abs(x)<=1e9) {return}}
    if len(mesh.tiles)==0 {return}
    it.low,it.high=nav_mesh_coord(mesh,box.min),nav_mesh_coord(mesh,box.max)
    if i64(it.high.x)-i64(it.low.x)>64 || i64(it.high.y)-i64(it.low.y)>64 {return}
    it.at={it.low.x-1,it.low.y}
    it.done=false
    return
}
nav_box_polys_next :: proc "contextless" (it:^Nav_Box_Polys) -> (ref:Nav_Ref,ok:bool) {
    for !it.done {
        if it.tile!=nil {
            tile:=it.tile
            box:=it.box
            if len(tile.data.bv)==0 {
                for it.node<len(tile.data.polys) {
                    i:=it.node
                    it.node+=1
                    corners:[NAV_VERTS_PER_POLY]math.Vec3
                    count:=nav_poly_vertices(tile,&tile.data.polys[i],&corners)
                    poly_box:=math.aabb_from_points(corners[:count])
                    if poly_box.max.x<box.min.x || poly_box.min.x>box.max.x || poly_box.max.z<box.min.z || poly_box.min.z>box.max.z {continue}
                    if poly_box.max.y<box.min.y-it.mesh.climb || poly_box.min.y>box.max.y+it.mesh.climb {continue}
                    return nav_tile_ref(it.mesh,tile,i),true
                }
            } else {
                low,high:=it.cells[0],it.cells[1]
                for it.node<len(tile.data.bv) {
                    node:=tile.data.bv[it.node]
                    overlap:=node.min.x<=high.x && node.max.x>=low.x && node.min.y<=high.y && node.max.y>=low.y && node.min.z<=high.z && node.max.z>=low.z
                    leaf:=node.index>=0
                    if overlap || leaf {it.node+=1} else {it.node+=int(-node.index)}
                    if leaf && overlap && int(node.index)<len(tile.data.polys) {return nav_tile_ref(it.mesh,tile,int(node.index)),true}
                }
            }
            it.tile=nil
        }
        it.at.x+=1
        if it.at.x>it.high.x {it.at.x=it.low.x;it.at.y+=1}
        if it.at.y>it.high.y {it.done=true;break}
        it.tile=nav_mesh_tile_at(it.mesh,it.at)
        it.node=0
        if it.tile!=nil {it.cells[0],it.cells[1]=nav_bv_quantize(it.tile,it.box)}
    }
    return
}
@(private)
nav_bv_quantize :: proc "contextless" (tile:^Nav_Tile,box:math.Aabb) -> (low,high:[3]u16) {
    q :: proc "contextless" (v,origin,cell:f32,up:bool) -> u16 {
        if !(cell>0) {return 0 if !up else 0xffff}
        f:=(v-origin)/cell
        if !(f>0) {return 0}
        if !(f<65534) {return 0xfffe}
        return u16(f)+1 if up else u16(f)
    }
    o:=tile.data.bounds.min
    cs,ch:=tile.data.cell_size,tile.data.cell_height
    low={q(box.min.x,o.x,cs,false),q(box.min.y,o.y,ch,false),q(box.min.z,o.z,cs,false)}
    high={q(box.max.x,o.x,cs,true),q(box.max.y,o.y,ch,true),q(box.max.z,o.z,cs,true)}
    return
}

// The data of a tile with room for that many of each, zeroed, in one block:
// what a builder or a reader of saved tiles fills.
nav_tile_data_alloc :: proc(vertices,polys,detail_vertices,detail_triangles,bv:int,allocator:=context.allocator) -> (data:Nav_Tile_Data,ok:bool) {
    for n in ([5]int{vertices,polys,detail_vertices,detail_triangles,bv}) {if n<0 || n>1<<24 {return}}
    size:=vertices*size_of(math.Vec3)+polys*(size_of(Nav_Poly)+size_of(Nav_Detail)+size_of(u32))+detail_vertices*size_of(math.Vec3)+detail_triangles*size_of(Nav_Detail_Triangle)+bv*size_of(Nav_Bv)+64
    block,error:=make([]byte,size,allocator)
    if error!=nil {return}
    cursor:=uintptr(raw_data(block))
    take :: proc "contextless" (cursor:^uintptr,$T:typeid,n:int) -> []T {
        align:=uintptr(align_of(T))
        cursor^=(cursor^+align-1)&~(align-1)
        out:=([^]T)(rawptr(cursor^))[:n]
        cursor^+=uintptr(n*size_of(T))
        return out
    }
    data.block,data.allocator=block,allocator
    data.vertices=take(&cursor,math.Vec3,vertices)
    data.polys=take(&cursor,Nav_Poly,polys)
    data.details=take(&cursor,Nav_Detail,polys)
    data.detail_vertices=take(&cursor,math.Vec3,detail_vertices)
    data.detail_triangles=take(&cursor,Nav_Detail_Triangle,detail_triangles)
    data.bv=take(&cursor,Nav_Bv,bv)
    data.poly_links=take(&cursor,u32,polys)
    return data,true
}

// A tile made of given triangles, one polygon each, joined where they share
// an edge (by vertex index): a surface built elsewhere or by hand. Edges that
// lie on the border of `rect` (on XZ) with nothing across are portals to the
// next tile. Triangles of zero area or with a coordinate that is not finite
// are skipped. No tree: the mesh scans its polygons.
nav_tile_from_triangles :: proc(coord:[2]i32,rect:math.Aabb,vertices:[]math.Vec3,indices:[]u32,area:u8=NAV_AREA_WALKABLE,allocator:=context.allocator) -> (data:Nav_Tile_Data,ok:bool) {
    if len(indices)==0 || len(indices)%3!=0 || len(vertices)==0 || len(vertices)>0xffff || area==NAV_AREA_BLOCKED || area>NAV_AREA_MAX {return}
    for index in indices {if int(index)>=len(vertices) {return}}
    usable :: proc "contextless" (a,b,c:math.Vec3) -> bool {
        for v in ([3]math.Vec3{a,b,c}) {for x in v {if !(abs(x)<=1e9) {return false}}}
        return abs(cross_xz(a,b,c))>1e-10
    }
    count:=0
    for i:=0;i<len(indices);i+=3 {if usable(vertices[indices[i]],vertices[indices[i+1]],vertices[indices[i+2]]) {count+=1}}
    if count==0 || count>0xffff {return}
    allocated:bool
    data,allocated=nav_tile_data_alloc(len(vertices),count,0,count,0,allocator)
    if !allocated {return}
    data.coord=coord
    copy(data.vertices,vertices)
    data.bounds=math.AABB_EMPTY
    n:=0
    for i:=0;i<len(indices);i+=3 {
        a,b,c:=indices[i],indices[i+1],indices[i+2]
        if !usable(vertices[a],vertices[b],vertices[c]) {continue}
        // Counter-clockwise seen from above, as built tiles are.
        if cross_xz(vertices[a],vertices[b],vertices[c])>0 {b,c=c,b}
        data.polys[n]={vertices={u16(a),u16(b),u16(c),0,0,0},count=3,area=area}
        data.details[n]={triangle_first=u32(n),triangle_count=1}
        data.detail_triangles[n]={0,1,2,0b010101}
        for v in ([3]u32{a,b,c}) {data.bounds=math.aabb_add_point(data.bounds,vertices[v])}
        n+=1
    }
    // Shared edges by sorting would need memory; a quadratic pass is fine for surfaces made by hand.
    for &p,i in data.polys {
        for e in 0..<3 {
            a,b:=p.vertices[e],p.vertices[(e+1)%3]
            found:=false
            search: for &q,j in data.polys {
                if i==j {continue}
                for f in 0..<3 {
                    if q.vertices[f]==b && q.vertices[(f+1)%3]==a || q.vertices[f]==a && q.vertices[(f+1)%3]==b {
                        p.neighbor[e]=u16(j+1)
                        found=true
                        break search
                    }
                }
            }
            if found {continue}
            va,vb:=vertices[a],vertices[b]
            epsilon:=f32(1e-4)
            switch {
            case abs(va.x-rect.max.x)<epsilon && abs(vb.x-rect.max.x)<epsilon: p.neighbor[e]=NAV_EDGE_PORTAL|u16(Nav_Side.Pos_X)
            case abs(va.x-rect.min.x)<epsilon && abs(vb.x-rect.min.x)<epsilon: p.neighbor[e]=NAV_EDGE_PORTAL|u16(Nav_Side.Neg_X)
            case abs(va.z-rect.max.z)<epsilon && abs(vb.z-rect.max.z)<epsilon: p.neighbor[e]=NAV_EDGE_PORTAL|u16(Nav_Side.Pos_Z)
            case abs(va.z-rect.min.z)<epsilon && abs(vb.z-rect.min.z)<epsilon: p.neighbor[e]=NAV_EDGE_PORTAL|u16(Nav_Side.Neg_Z)
            }
        }
    }
    return data,true
}

// A copy of a tile's data in a block of its own.
nav_tile_data_clone :: proc(data:^Nav_Tile_Data,allocator:=context.allocator) -> (copy_of:Nav_Tile_Data,ok:bool) {
    if len(data.block)==0 {return}
    block,error:=make([]byte,len(data.block),allocator)
    if error!=nil {return}
    copy(block,data.block)
    moved :: proc(slice:$T/[]$E,from,to:[]byte) -> T {
        if len(slice)==0 {return nil}
        offset:=uintptr(raw_data(slice))-uintptr(raw_data(from))
        return ([^]E)(rawptr(uintptr(raw_data(to))+offset))[:len(slice)]
    }
    copy_of=data^
    copy_of.block,copy_of.allocator=block,allocator
    copy_of.vertices=moved(data.vertices,data.block,block)
    copy_of.polys=moved(data.polys,data.block,block)
    copy_of.details=moved(data.details,data.block,block)
    copy_of.detail_vertices=moved(data.detail_vertices,data.block,block)
    copy_of.detail_triangles=moved(data.detail_triangles,data.block,block)
    copy_of.bv=moved(data.bv,data.block,block)
    copy_of.poly_links=moved(data.poly_links,data.block,block)
    return copy_of,true
}

// Makes dst a copy of src, with every tile, link and connection where it
// was: references into src are valid in dst. A transaction: false without
// memory, leaving dst empty.
nav_mesh_copy :: proc(dst,src:^Nav_Mesh,allocator:=context.allocator) -> bool {
    nav_mesh_destroy(dst)
    if len(src.tiles)==0 {return true}
    if !nav_mesh_init(dst,{origin=src.origin,tile_width=src.tile_width,climb=src.climb,max_tiles=len(src.tiles),max_links=len(src.links),max_connections=len(src.connections),allocator=allocator}) {return false}
    copy(dst.links,src.links)
    copy(dst.connections,src.connections)
    dst.free_tile,dst.free_link,dst.free_connection=src.free_tile,src.free_link,src.free_connection
    dst.revision,dst.failed=src.revision,src.failed
    for &tile,i in src.tiles {
        dst.tiles[i]=tile
        dst.tiles[i].data={}
        if !tile.used {continue}
        data,ok:=nav_tile_data_clone(&tile.data,allocator)
        if !ok || !base.hash_map_set(&dst.lookup,nav_coord_key(tile.data.coord),u32(i)) {
            dst.tiles[i].used=false
            nav_mesh_destroy(dst)
            return false
        }
        dst.tiles[i].data=data
    }
    return true
}
