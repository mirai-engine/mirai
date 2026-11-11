package ai

import "base:runtime"
import "core:math/linalg"
import math "mirai:std/math"

// Queries over a Nav_Mesh. Paths are found with A* over polygons and links,
// in slices of a budget when asked to, and pulled tight with the funnel
// algorithm; the funnel stops at every link, whose crossing is up to whoever
// follows the path.

// What an agent walks and crosses. A zero filter walks every area at cost 1
// and crosses no link.
Nav_Filter :: struct {
    costs:[NAV_AREA_MAX+1]f32, // per metre on each area; 0 counts as 1. Below 1 the path found may not be the cheapest
    excluded:u64,              // bit per area never walked
    can:Nav_Need,              // what the agent can do: a link that needs more is not taken
}
NAV_CAN_ALL :: Nav_Need{up=max(f32),across=max(f32),down=max(f32),abilities=max(u32)}

nav_filter_passes :: #force_inline proc "contextless" (filter:^Nav_Filter,area:u8) -> bool {
    return area!=NAV_AREA_BLOCKED && area<=NAV_AREA_MAX && filter.excluded&(u64(1)<<area)==0
}
nav_filter_cost :: #force_inline proc "contextless" (filter:^Nav_Filter,area:u8) -> f32 {
    cost:=filter.costs[area&NAV_AREA_MAX]
    return cost if cost>0 else 1
}

NAV_QUERY_EDGES :: 64
NAV_HEURISTIC_SCALE :: f32(0.999)

// The memory of path searches over meshes: a keyed Search whose capacity
// bounds the polygons and links one search reaches, and where the path
// enters each of them. One search runs in it at a time; not safe to share
// between threads.
Nav_Query :: struct {
    search:Search,
    points:[]math.Vec3,
    candidates:[NAV_QUERY_EDGES]math.Vec3,
    accepted:math.Vec3,
    mesh:^Nav_Mesh,
    filter:Nav_Filter,
    start,end:math.Vec3,
    start_ref,end_ref:Nav_Ref,
    toward:bool, // the search walks against the way agents do: nav_toward_begin
    around:Nav_Around,
    allocator:runtime.Allocator,
}

nav_query_init :: proc(q:^Nav_Query,nodes:int,allocator:=context.allocator) -> bool {
    q^={allocator=allocator}
    if nodes<=0 || nodes>1<<24 {return false}
    if !search_init(&q.search,{nodes=nodes,keyed=true,max_edges=NAV_QUERY_EDGES,allocator=allocator}) {return false}
    points,error:=make([]math.Vec3,nodes,allocator)
    if error!=nil {search_destroy(&q.search);return false}
    q.points=points
    return true
}
nav_query_destroy :: proc(q:^Nav_Query) {
    if q.allocator.procedure!=nil {delete(q.points,q.allocator)}
    search_destroy(&q.search)
    q^={}
}

@(private)
nav_point_finite :: #force_inline proc "contextless" (v:math.Vec3) -> bool {return abs(v.x)<=1e9 && abs(v.y)<=1e9 && abs(v.z)<=1e9}

// The portal of a step out of a polygon, ordered as nav_portal_points does.
@(private)
nav_step_portal :: proc "contextless" (tile:^Nav_Tile,poly:^Nav_Poly,step:Nav_Step) -> (left,right:math.Vec3) {
    count:=int(poly.count)
    a:=tile.data.vertices[poly.vertices[step.edge]]
    b:=tile.data.vertices[poly.vertices[(int(step.edge)+1)%count]]
    if step.low!=0 || step.high!=255 {
        lo,hi:=f32(step.low)/255,f32(step.high)/255
        a,b=a+(b-a)*lo,a+(b-a)*hi
    }
    if cross_xz(nav_poly_center(tile,poly),a,b)>0 {return b,a}
    return a,b
}

@(private)
nav_space_neighbors :: proc(q:^Nav_Query,key:u64,edges:^Edge_List) {
    slot,ok:=search_find(&q.search,key)
    if !ok {return}
    nav_mesh_edges(q.mesh,&q.filter,Nav_Ref(key),q.points[slot],q.end,q.end_ref,q.candidates[:],edges,q.toward)
}

// The edges out of a polygon or a link of a mesh, entered at p, for a search
// toward `end` on end_ref (none: toward nothing): where each enters what it
// leads to goes to candidates, at the index of its edge. `against`: the
// edges that lead into it instead, for a search that walks from an end back
// to where agents start: the same polygons across its edges, at the same
// cost (the part walked is the one on this polygon either way), and each
// link that ends on it, named as crossed from its end.
@(private)
nav_mesh_edges :: proc(mesh:^Nav_Mesh,filter:^Nav_Filter,from:Nav_Ref,p,end:math.Vec3,end_ref:Nav_Ref,candidates:[]math.Vec3,edges:^Edge_List,against:=false) {
    if nav_ref_is_link(from) {
        link:=nav_link_of(mesh,from)
        if link==nil || edges.count>=len(candidates) {return}
        _,to_point,_,to_poly:=nav_link_ends(link,from)
        _,poly:=nav_poly_of(mesh,to_poly)
        if poly==nil || !nav_filter_passes(filter,poly.area) {return}
        cost:=linalg.distance(p,to_point)*nav_filter_cost(filter,link.desc.area)+link.desc.cost
        if to_poly==end_ref {cost+=linalg.distance(to_point,end)*nav_filter_cost(filter,poly.area)}
        candidates[edges.count]=to_point
        edge_add(edges,u64(to_poly),cost,u32(edges.count))
        return
    }
    tile,poly:=nav_poly_of(mesh,from)
    if poly==nil {return}
    area_cost:=nav_filter_cost(filter,poly.area)
    it:=nav_steps(mesh,from,against)
    for step in nav_steps_next(&it) {
        if edges.count>=len(candidates) {break}
        entry:math.Vec3
        end_cost:f32
        to:=step.to
        if nav_ref_is_link(step.to) {
            link:=nav_link_of(mesh,step.to)
            if link==nil || !nav_link_crossable(link,filter.can) || !nav_filter_passes(filter,link.desc.area) {continue}
            // A link that goes both ways is walked into this polygon as it is walked out of it.
            if step.edge==NAV_CONNECTION_ARRIVAL {to=nav_ref_flip(step.to)} else if against && !link.desc.two_way {continue}
            entry,_,_,_=nav_link_ends(link,to)
        } else {
            _,next:=nav_poly_of(mesh,step.to)
            if next==nil || !nav_filter_passes(filter,next.area) {continue}
            left,right:=nav_step_portal(tile,poly,step)
            _,entry,_,_=math.closest_segment_segment({p,end if end_ref!=0 else p},{right,left})
            if step.to==end_ref {end_cost=linalg.distance(entry,end)*nav_filter_cost(filter,next.area)}
        }
        candidates[edges.count]=entry
        edge_add(edges,u64(to),linalg.distance(p,entry)*area_cost+end_cost,u32(edges.count))
    }
}
@(private)
nav_space_heuristic :: proc(q:^Nav_Query,key,goal:u64) -> f32 {return linalg.distance(q.accepted,q.end)*NAV_HEURISTIC_SCALE}
@(private)
nav_space_accept :: proc(q:^Nav_Query,slot:u32,edge:Edge) {
    q.points[slot]=q.candidates[edge.data]
    q.accepted=q.points[slot]
}

// Starts a search for a path from `start` on the polygon start_ref to `end`
// on end_ref; nav_path_step advances it and nav_path_finish reads it. The
// mesh may change between steps: polygons and links that stop being valid
// lead nowhere, and the finished path is checked again.
nav_path_begin :: proc(q:^Nav_Query,mesh:^Nav_Mesh,start_ref,end_ref:Nav_Ref,start,end:math.Vec3,filter:^Nav_Filter) -> Search_Status {
    q.mesh=nil
    if len(q.points)==0 || mesh==nil || filter==nil || !nav_point_finite(start) || !nav_point_finite(end) {return .Invalid}
    _,first:=nav_poly_of(mesh,start_ref)
    _,last:=nav_poly_of(mesh,end_ref)
    if first==nil || last==nil {return .Invalid}
    q.mesh,q.filter,q.toward=mesh,filter^,false
    q.start,q.end,q.start_ref,q.end_ref=start,end,start_ref,end_ref
    q.accepted=start
    status:=search_begin(&q.search,u64(start_ref),u64(end_ref),q,nav_space_heuristic)
    if slot,ok:=search_find(&q.search,u64(start_ref));ok {q.points[slot]=start}
    return status
}
nav_path_step :: proc(q:^Nav_Query,budget:int) -> Search_Status {
    if q.mesh==nil {return .Invalid}
    return search_step(&q.search,q,nav_space_neighbors,nav_space_heuristic,nav_space_accept,budget)
}
// Writes the path of polygons and links of the finished search. Without a way
// to the end, the path to the reached polygon nearest to it, with `partial`.
// Invalid when a node of it stopped being valid while the search ran.
nav_path_finish :: proc(q:^Nav_Query,out:[]Nav_Ref) -> (count:int,status:Search_Status,partial:bool) {
    if q.mesh==nil {return 0,.Invalid,false}
    count,status,partial=nav_search_finish(&q.search,q.points,q.end,out)
    for ref in out[:count] {
        if !nav_ref_valid(q.mesh,ref) {return 0,.Invalid,false}
    }
    return
}

// The path of a finished search of any space, over the points where it
// entered each node: the one it found, or without a way to the end, the path
// to the node it reached nearest to `end` that is not a link, with `partial`.
// Whoever searched checks that its nodes still are.
@(private)
nav_search_finish :: proc(search:^Search,points:[]math.Vec3,end:math.Vec3,out:[]Nav_Ref) -> (count:int,status:Search_Status,partial:bool) {
    status=search.status
    keys:=transmute([]u64)out
    #partial switch status {
    case .Found:
        count,status=search_path(search,keys)
    case .No_Path,.Open_Full:
        best:=f32(max(f32))
        nearest:u64
        for slot in 0..<u32(len(points)) {
            if !search_reached(search,slot) {continue}
            key:=search_key(search,slot)
            if nav_ref_is_link(Nav_Ref(key)) {continue}
            d:=linalg.length2(points[slot]-end)
            if d<best {best=d;nearest=key}
        }
        if nearest==0 {return 0,status,false}
        count,_=search_path_to(search,nearest,keys)
        partial=count>0
    case:
        return 0,status,false
    }
    return
}
// The whole search at once.
nav_find_path :: proc(q:^Nav_Query,mesh:^Nav_Mesh,start_ref,end_ref:Nav_Ref,start,end:math.Vec3,filter:^Nav_Filter,out:[]Nav_Ref) -> (count:int,status:Search_Status,partial:bool) {
    status=nav_path_begin(q,mesh,start_ref,end_ref,start,end,filter)
    if status==.Invalid {return 0,.Invalid,false}
    nav_path_step(q,max(int))
    return nav_path_finish(q,out)
}

NAV_COSTS_SLICE :: 32 // polygons nav_costs expands between looks at its targets

// The costs from `start` on start_ref to the polygons around it, cheapest
// first, until every one of `targets` is reached or the query is full; each
// step enters a polygon at the point of its portal nearest to where it comes
// from. nav_cost_to reads them: one search measures the way to many ends.
nav_costs :: proc(q:^Nav_Query,mesh:^Nav_Mesh,start_ref:Nav_Ref,start:math.Vec3,filter:^Nav_Filter,targets:[]Nav_Ref) -> bool {
    if !nav_costs_begin(q,mesh,start_ref,start,filter,false) {return false}
    for target in targets {nav_costs_reach(q,target,max(int))}
    q.mesh=nil
    return true
}

// Starts the search without a goal that nav_costs_reach advances: from a
// start outward, or toward an end against the way agents walk.
@(private)
nav_costs_begin :: proc(q:^Nav_Query,mesh:^Nav_Mesh,ref:Nav_Ref,point:math.Vec3,filter:^Nav_Filter,toward:bool) -> bool {
    q.mesh=nil
    if len(q.points)==0 || mesh==nil || filter==nil || !nav_point_finite(point) {return false}
    if _,poly:=nav_poly_of(mesh,ref);poly==nil {return false}
    q.mesh,q.filter,q.toward=mesh,filter^,toward
    q.start,q.end,q.start_ref,q.end_ref=point,point,ref,0
    search_begin(&q.search,u64(ref),0,q,nav_around_heuristic)
    if slot,ok:=search_find(&q.search,u64(ref));ok {q.points[slot]=point}
    return true
}

// Expands the search, cheapest first, until the polygon `ref` is settled
// (Found), up to `budget` polygons (Running: call it again); No_Path when the
// search ends without it, Open_Full when the query is full first.
@(private)
nav_costs_reach :: proc(q:^Nav_Query,ref:Nav_Ref,budget:int) -> Search_Status {
    if q.mesh==nil {return .Invalid}
    left:=budget
    for {
        if slot,ok:=search_find(&q.search,u64(ref));ok && q.search.closed[slot]==q.search.generation {return .Found}
        if q.search.status!=.Running {return q.search.status}
        if left<=0 {return .Running}
        before:=q.search.stats.expanded
        search_step(&q.search,q,nav_space_neighbors,nav_around_heuristic,nav_space_accept,min(left,NAV_COSTS_SLICE))
        left-=max(q.search.stats.expanded-before,1)
    }
}

// One search for all who go to the same end: from `end` on end_ref outward
// against the way agents walk, cheapest first, over what `filter` walks and
// crosses. nav_toward_reach expands it as far as the polygon of each of them
// and nav_toward_path reads its way from there, so the search costs what the
// farthest of them asks and each one after it only its path. The polygons may
// not be those a search of its own picks: each is left at the point of its
// portal nearest to where the way goes on, not to where it comes from. The
// mesh may change while it lasts: what expired leads nowhere, and a path is
// checked when it is read. False when the end is not on the mesh.
nav_toward_begin :: proc(q:^Nav_Query,mesh:^Nav_Mesh,end_ref:Nav_Ref,end:math.Vec3,filter:^Nav_Filter) -> bool {
    return nav_costs_begin(q,mesh,end_ref,end,filter,true)
}
// Found once the way from the polygon `ref` to the end is known; Running
// when `budget` polygons were expanded first: call it again. No_Path when
// none leads from it to the end, Open_Full when the query was full before
// it was reached, Invalid without a search begun by nav_toward_begin.
nav_toward_reach :: proc(q:^Nav_Query,ref:Nav_Ref,budget:int) -> Search_Status {
    if !q.toward || nav_ref_is_link(ref) {return .Invalid}
    return nav_costs_reach(q,ref,budget)
}
// The polygons and links from `ref`, which nav_toward_reach found, to the
// end, in the order they are walked. Nothing when it does not fit `out` or a
// part of it is no longer of the mesh.
nav_toward_path :: proc(q:^Nav_Query,ref:Nav_Ref,out:[]Nav_Ref) -> (count:int,ok:bool) {
    if q.mesh==nil || !q.toward {return}
    slot,found:=search_find(&q.search,u64(ref))
    if !found || q.search.closed[slot]!=q.search.generation {return}
    for {
        if count>=len(out) {return 0,false}
        at:=Nav_Ref(search_key(&q.search,slot))
        // The search walked each link from its end.
        out[count]=nav_ref_flip(at) if nav_ref_is_link(at) else at
        if !nav_ref_valid(q.mesh,out[count]) {return 0,false}
        count+=1
        if q.search.parent[slot]==slot {break}
        slot=q.search.parent[slot]
    }
    return count,true
}

// The cost of the way from the start of the last nav_costs to `end` on the
// polygon ref, over the polygons and links that search took to it, entering
// each where a path search toward `end` would. False when it did not reach ref.
nav_cost_to :: proc(q:^Nav_Query,mesh:^Nav_Mesh,ref:Nav_Ref,end:math.Vec3) -> (cost:f32,ok:bool) {
    if mesh==nil || q.toward || !nav_point_finite(end) || nav_ref_is_link(ref) {return}
    keys:=q.search.channel
    count,status:=search_path_to(&q.search,u64(ref),keys)
    if status!=.Found || count==0 || Nav_Ref(keys[0])!=q.start_ref {return}
    p:=q.start
    for i in 0..<count-1 {
        from,to:=Nav_Ref(keys[i]),Nav_Ref(keys[i+1])
        if nav_ref_is_link(from) {
            link:=nav_link_of(mesh,from)
            if link==nil {return}
            _,leave,_,_:=nav_link_ends(link,from)
            cost+=linalg.distance(p,leave)*nav_filter_cost(&q.filter,link.desc.area)+link.desc.cost
            p=leave
            continue
        }
        _,poly:=nav_poly_of(mesh,from)
        if poly==nil {return}
        left,right,found:=nav_portal_points(mesh,from,to)
        if !found {return}
        entry:=left
        if !nav_ref_is_link(to) {_,entry,_,_=math.closest_segment_segment({p,end},{right,left})}
        cost+=linalg.distance(p,entry)*nav_filter_cost(&q.filter,poly.area)
        p=entry
    }
    _,last:=nav_poly_of(mesh,ref)
    if last==nil {return}
    return cost+linalg.distance(p,end)*nav_filter_cost(&q.filter,last.area),true
}

Nav_Corner_Flag :: enum u8 {
    Start,
    End,
    Link, // the start of a link: the path crosses `ref` from here to its end
}
Nav_Corner_Flags :: bit_set[Nav_Corner_Flag;u8]
// A point where a straight path turns, and the node it goes on through.
Nav_Corner :: struct {
    position:math.Vec3,
    ref:Nav_Ref,
    flags:Nav_Corner_Flags,
}

// The corners of the straight path from `start` to `end` through the nodes
// of `path`: the start, every corner the funnel turns around, every link start
// and the end. Writes as many as fit; `complete` when the end did. A node that
// is no longer valid (a tile built again) ends it at the point of the last
// valid polygon nearest the end, without the End flag (Detour's findStraightPath).
nav_straight_path :: proc(mesh:^Nav_Mesh,start,end:math.Vec3,path:[]Nav_Ref,out:[]Nav_Corner) -> (count:int,complete:bool) {
    if len(path)==0 || len(out)==0 || !nav_point_finite(start) || !nav_point_finite(end) {return}
    path,end:=path,end
    valid:=0
    for valid<len(path) && nav_ref_valid(mesh,path[valid]) {valid+=1}
    for valid>0 && nav_ref_is_link(path[valid-1]) {valid-=1}
    if valid==0 {return}
    cut:=valid<len(path)
    if cut {
        path=path[:valid]
        end,_=nav_closest_point_on_poly(mesh,path[valid-1],end)
    }
    push :: proc "contextless" (out:[]Nav_Corner,count:^int,corner:Nav_Corner) -> bool {
        if count^>0 {
            last:=&out[count^-1]
            if last.position==corner.position {last.flags|=corner.flags;if corner.ref!=0 && .Link in corner.flags {last.ref=corner.ref};return true}
        }
        if count^>=len(out) {return false}
        out[count^]=corner
        count^+=1
        return true
    }
    if !push(out,&count,{position=start,ref=path[0],flags={.Start}}) {return}
    from:=start
    first:=0
    for i in 0..<len(path) {
        if !nav_ref_is_link(path[i]) {continue}
        link:=nav_link_of(mesh,path[i])
        if link==nil {return}
        enter,leave,_,_:=nav_link_ends(link,path[i])
        if !nav_funnel_path(mesh,from,enter,path[first:i],out,&count) {return}
        if !push(out,&count,{position=enter,ref=path[i],flags={.Link}}) {return}
        from=leave
        first=i+1
    }
    if first<len(path) {
        if !nav_funnel_path(mesh,from,end,path[first:],out,&count) {return}
    } else if !push(out,&count,{position=from,ref=0}) {return}
    if !push(out,&count,{position=end,flags={} if cut else {.End}}) {return}
    return count,!cut
}

// Pushes the corners of the straight path from `from` to `to` over polygons,
// without `from` and `to`. False when the output is full or a step is missing.
@(private)
nav_funnel_path :: proc(mesh:^Nav_Mesh,from,to:math.Vec3,polys:[]Nav_Ref,out:[]Nav_Corner,count:^int) -> bool {
    portal :: proc(mesh:^Nav_Mesh,polys:[]Nav_Ref,i:int,from,to:math.Vec3) -> (left,right:math.Vec3,ok:bool) {
        if i==0 {return from,from,true}
        if i>=len(polys) {return to,to,true}
        return nav_portal_points(mesh,polys[i-1],polys[i])
    }
    same :: #force_inline proc "contextless" (a,b:math.Vec3) -> bool {return (a.x-b.x)*(a.x-b.x)+(a.z-b.z)*(a.z-b.z)<1e-12}
    corner :: proc(out:[]Nav_Corner,count:^int,position:math.Vec3,ref:Nav_Ref) -> bool {
        if count^>0 && out[count^-1].position==position {return true}
        if count^>=len(out) {return false}
        out[count^]={position=position,ref=ref}
        count^+=1
        return true
    }
    if len(polys)==0 {return true}
    // A start that lies on the first portal is in the next polygon as well:
    // from there the portal would open the funnel half a turn, which the side
    // tests below cannot tell from a funnel that has closed.
    polys:=polys
    for len(polys)>=2 {
        left,right,ok:=nav_portal_points(mesh,polys[0],polys[1])
        if !ok || !nav_on_segment_xz(from,left,right) {break}
        polys=polys[1:]
    }
    apex,left,right:=from,from,from
    apex_index,left_index,right_index:=0,0,0
    portals:=len(polys)+1
    for i:=1;i<portals; {
        portal_left,portal_right,ok:=portal(mesh,polys,i,from,to)
        if !ok {return false}
        if cross_xz(apex,right,portal_right)>=0 {
            if same(apex,right) || cross_xz(apex,left,portal_right)<=0 {
                right=portal_right;right_index=i
            } else {
                if !corner(out,count,left,polys[min(left_index,len(polys)-1)]) {return false}
                apex=left;apex_index=left_index
                left=apex;right=apex;left_index=apex_index;right_index=apex_index
                i=apex_index+1
                continue
            }
        }
        if cross_xz(apex,left,portal_left)<=0 {
            if same(apex,left) || cross_xz(apex,right,portal_left)>=0 {
                left=portal_left;left_index=i
            } else {
                if !corner(out,count,right,polys[min(right_index,len(polys)-1)]) {return false}
                apex=right;apex_index=right_index
                left=apex;right=apex;left_index=apex_index;right_index=apex_index
                i=apex_index+1
                continue
            }
        }
        i+=1
    }
    return true
}

// Whether p lies on the segment a to b, seen on the XZ plane.
@(private)
nav_on_segment_xz :: proc "contextless" (p,a,b:math.Vec3) -> bool {
    ax,az,bx,bz:=a.x-p.x,a.z-p.z,b.x-p.x,b.z-p.z
    cross:=ax*bz-az*bx
    length2:=(b.x-a.x)*(b.x-a.x)+(b.z-a.z)*(b.z-a.z)
    tolerance:=1e-5+1e-6*(abs(p.x)+abs(p.z))
    return cross*cross<=tolerance*tolerance*length2 && ax*bx+az*bz<=0
}

NAV_STRAIGHTEN_POLYS :: 256 // longest path nav_path_straighten works on
NAV_STRAIGHTEN_RAY :: 64    // polygons one of its rays may cross
NAV_STRAIGHTEN_INSET :: 0.01 // metres a ray ends inside the polygon past a corner

// Takes out the bends of the straight path from `start` to `end` through
// path[:count] that a raycast skips at no more cost than the bend walks: the
// polygons the ray crosses replace those the bend went through. One pass over
// the bends; the path is pulled again and stays as it was when that costs
// more. len(path) is its room. The new count.
nav_path_straighten :: proc(mesh:^Nav_Mesh,filter:^Nav_Filter,start,end:math.Vec3,path:[]Nav_Ref,count:int) -> int {
    if mesh==nil || filter==nil || count<2 || count>min(len(path),NAV_STRAIGHTEN_POLYS) {return count}
    corners:[NAV_STRAIGHTEN_POLYS+2]Nav_Corner
    at:[NAV_STRAIGHTEN_POLYS+2]int
    n,complete:=nav_straight_path(mesh,start,end,path[:count],corners[:])
    if !complete || n<3 || !nav_corner_indices(path[:count],corners[:n],at[:n]) {return count}
    before,priced:=nav_pulled_cost(mesh,filter,path[:count],corners[:n],at[:n])
    if !priced {return count}
    original:[NAV_STRAIGHTEN_POLYS]Nav_Ref
    copy(original[:count],path[:count])
    total:=count
    changed:=false
    for k:=1;k+1<n; {
        delta,removed:=nav_remove_bend(mesh,filter,path[:min(len(path),NAV_STRAIGHTEN_POLYS)],&total,corners[:n],at[:n],k)
        if !removed {k+=1;continue}
        for j in k+1..<n {at[j]+=delta}
        copy(corners[k:n-1],corners[k+1:n])
        copy(at[k:n-1],at[k+1:n])
        n-=1
        changed=true
    }
    if !changed {return count}
    n,complete=nav_straight_path(mesh,start,end,path[:total],corners[:])
    if complete && nav_corner_indices(path[:total],corners[:n],at[:n]) {
        after,ok:=nav_pulled_cost(mesh,filter,path[:total],corners[:n],at[:n])
        if ok && after<=before {return total}
    }
    copy(path[:count],original[:count])
    return count
}

// For each corner of a straight path, the index in `path` of the polygon the
// path goes on through from it: of the link for a link start, of the last
// node for the end.
@(private)
nav_corner_indices :: proc "contextless" (path:[]Nav_Ref,corners:[]Nav_Corner,at:[]int) -> bool {
    i:=0
    for corner,k in corners {
        if k>0 {
            if .End in corner.flags && .Link not_in corner.flags {
                i=len(path)-1
            } else {
                for i<len(path) && path[i]!=corner.ref {i+=1}
                if i>=len(path) {return false}
            }
        }
        at[k]=i
    }
    return true
}

// The index in `path` of the last polygon the straight path walks before
// corner k: the one before its link for a link start.
@(private)
nav_corner_last_poly :: #force_inline proc "contextless" (corners:[]Nav_Corner,at:[]int,k:int) -> int {
    return at[k]-1 if .Link in corners[k].flags else at[k]
}

// What walking a straight path costs, as A* counts it: each stretch on the
// polygons it crosses, each link from end to end.
@(private)
nav_pulled_cost :: proc(mesh:^Nav_Mesh,filter:^Nav_Filter,path:[]Nav_Ref,corners:[]Nav_Corner,at:[]int) -> (cost:f32,ok:bool) {
    from:=corners[0].position
    for k in 1..<len(corners) {
        first:=at[k-1]
        if .Link in corners[k-1].flags {
            link:=nav_link_of(mesh,path[first])
            if link==nil {return}
            enter,leave,_,_:=nav_link_ends(link,path[first])
            cost+=linalg.distance(enter,leave)*nav_filter_cost(filter,link.desc.area)+link.desc.cost
            from=leave
            first+=1
        }
        last:=nav_corner_last_poly(corners,at,k)
        if last>=first {cost+=nav_segment_cost(mesh,filter,from,corners[k].position,path[first:last+1])}
        from=corners[k].position
    }
    return cost,true
}

// What the segment from a to b costs over `polys`, in the order it crosses
// them: each part by the cost of its area, and what none of them holds by the
// last one's.
@(private)
nav_segment_cost :: proc(mesh:^Nav_Mesh,filter:^Nav_Filter,a,b:math.Vec3,polys:[]Nav_Ref) -> f32 {
    length:=linalg.distance(a,b)
    if !(length>0) {return 0}
    cost,walked,area_cost:=f32(0),f32(0),f32(1)
    for ref in polys {
        tile,poly:=nav_poly_of(mesh,ref)
        if poly==nil {continue}
        corners:[NAV_VERTS_PER_POLY]math.Vec3
        n:=nav_poly_vertices(tile,poly,&corners)
        ok,tmin,tmax,_,_:=nav_segment_poly_xz(a,b,corners[:n])
        area_cost=nav_filter_cost(filter,poly.area)
        if !ok {continue}
        from:=max(tmin,walked)
        if tmax>from {cost+=(tmax-from)*length*area_cost;walked=tmax}
    }
    return cost+max(1-walked,0)*length*area_cost
}

// Replaces the polygons from corner k-1 to corner k+1 with those of a ray
// between them when the ray reaches k+1 and costs no more than the bend at k.
// How much the index of what follows moved.
@(private)
nav_remove_bend :: proc(mesh:^Nav_Mesh,filter:^Nav_Filter,path:[]Nav_Ref,total:^int,corners:[]Nav_Corner,at:[]int,k:int) -> (delta:int,ok:bool) {
    previous,bend,next:=corners[k-1],corners[k],corners[k+1]
    if .Link in previous.flags || bend.flags&{.Start,.End,.Link}!={} {return}
    count:=total^
    from,through,to:=at[k-1],at[k],nav_corner_last_poly(corners,at,k+1)
    if to<through || to>=count {return}
    // A corner is a vertex that several polygons of the path share: the ray
    // aims a little inside the first of them, the side the bend reaches it
    // from, so that it ends on that one without grazing the others.
    target:=next.position
    if next.flags&{.Link,.End}=={} {
        first:=through
        for first<to {
            on,_:=nav_closest_point_on_poly(mesh,path[first],target)
            if (on.x-target.x)*(on.x-target.x)+(on.z-target.z)*(on.z-target.z)<=1e-6 {break}
            first+=1
        }
        to=first
        tile,poly:=nav_poly_of(mesh,path[to])
        if poly==nil {return}
        inward:=nav_poly_center(tile,poly)-target
        distance:=linalg.length(inward)
        if distance>0 {target+=inward*(min(NAV_STRAIGHTEN_INSET,distance*0.5)/distance)}
    }
    visited:[NAV_STRAIGHTEN_RAY]Nav_Ref
    t,_,crossed:=nav_raycast(mesh,path[from],previous.position,target,filter,visited[:])
    if t!=max(f32) || crossed==0 || crossed>=len(visited) {return}
    // Never onto an area dearer than the bend walks, however short the part.
    dearest:f32
    for ref in path[from:to+1] {
        if _,poly:=nav_poly_of(mesh,ref);poly!=nil {dearest=max(dearest,nav_filter_cost(filter,poly.area))}
    }
    for ref in visited[:crossed] {
        _,poly:=nav_poly_of(mesh,ref)
        if poly==nil || nav_filter_cost(filter,poly.area)>dearest {return}
    }
    // The ray ends on a polygon of the bend that holds the next corner.
    resume:=-1
    for j in through..=to {if path[j]==visited[crossed-1] {resume=j+1;break}}
    if resume<0 {return}
    for ref in visited[1:max(crossed-1,1)] {
        for j in 0..<from {if path[j]==ref {return}}
        for j in resume..<count {if path[j]==ref {return}}
    }
    size:=from+crossed+count-resume
    if size>len(path) {return}
    straight:=nav_segment_cost(mesh,filter,previous.position,target,visited[:crossed])
    bent:=nav_segment_cost(mesh,filter,previous.position,bend.position,path[from:through+1])+nav_segment_cost(mesh,filter,bend.position,target,path[through:to+1])
    if !(straight<=bent) {return}
    copy(path[from+crossed:size],path[resume:count])
    copy(path[from:from+crossed],visited[:crossed])
    total^=size
    return from+crossed-resume,true
}

// Which edges of a polygon lead to a polygon the filter walks.
@(private)
nav_open_edges :: proc "contextless" (mesh:^Nav_Mesh,ref:Nav_Ref,filter:^Nav_Filter) -> (open:[NAV_VERTS_PER_POLY]Nav_Ref) {
    it:=nav_steps(mesh,ref)
    for step in nav_steps_next(&it) {
        if step.edge==NAV_CONNECTION_LINK || nav_ref_is_link(step.to) {continue}
        _,next:=nav_poly_of(mesh,step.to)
        if next!=nil && nav_filter_passes(filter,next.area) && open[step.edge]==0 {open[step.edge]=step.to}
    }
    return
}

NAV_MOVE_NODES :: 16

// Moves from `start` on start_ref toward `end` over the surface, without
// crossing walls or links: the reachable point nearest to `end` among the
// polygons within reach, and the polygons from start_ref to the one it lies
// on, written to `visited`. The height is that of the surface there.
nav_move_along_surface :: proc(mesh:^Nav_Mesh,start_ref:Nav_Ref,start,end:math.Vec3,filter:^Nav_Filter,visited:[]Nav_Ref) -> (result:math.Vec3,count:int) {
    if !nav_point_finite(start) || !nav_point_finite(end) || filter==nil {return start,0}
    if _,poly:=nav_poly_of(mesh,start_ref);poly==nil {return start,0}
    nodes:[NAV_MOVE_NODES]Nav_Ref
    parents:[NAV_MOVE_NODES]i8
    used:=1
    nodes[0],parents[0]=start_ref,-1
    best,best_node:=start,0
    best_distance:=f32(max(f32))
    center:=(start+end)*0.5
    radius:=linalg.distance(start,end)*0.5+1e-3
    flat :: #force_inline proc "contextless" (v:math.Vec3) -> math.Vec3 {return {v.x,0,v.z}}
    for at:=0;at<used;at+=1 {
        ref:=nodes[at]
        tile,poly:=nav_poly_of(mesh,ref)
        if poly==nil {continue}
        corners:[NAV_VERTS_PER_POLY]math.Vec3
        n:=nav_poly_vertices(tile,poly,&corners)
        if nav_point_in_poly_xz(end,corners[:n]) {best,best_node,best_distance=end,at,0;break}
        open:=nav_open_edges(mesh,ref,filter)
        for e in 0..<n {
            a,b:=corners[e],corners[(e+1)%n]
            if open[e]==0 {
                on,t:=math.closest_point_segment(flat(end),{flat(a),flat(b)})
                d:=linalg.length2(on-flat(end))
                if d<best_distance {best_distance=d;best=a+(b-a)*t;best_node=at}
                continue
            }
            seen:=false
            for k in 0..<used {if nodes[k]==open[e] {seen=true;break}}
            if seen || used>=NAV_MOVE_NODES {continue}
            on,_:=math.closest_point_segment(flat(center),{flat(a),flat(b)})
            if linalg.length2(on-flat(center))>radius*radius {continue}
            nodes[used],parents[used]=open[e],i8(at)
            used+=1
        }
    }
    depth:=0
    for k:=best_node;k>=0;k=int(parents[k]) {depth+=1}
    count=min(depth,len(visited))
    write:=depth-1
    for k:=best_node;k>=0;k=int(parents[k]) {
        if write<count {visited[write]=nodes[k]}
        write-=1
    }
    if y,ok:=nav_poly_height(mesh,nodes[best_node],best);ok {best.y=y}
    return best,count
}

NAV_WALL_NODES :: 16 // polygons nav_walls_near looks at

// The walls near a point of the surface, for avoid_velocity: the edges that
// lead to no polygon the filter walks, among the polygons joined to
// start_ref whose way there stays within `radius` of `center` on XZ, each as
// (x, z) with the surface to its right, nearest first. Writes those that fit
// `out`, at most AVOID_MAX_WALLS; how many.
nav_walls_near :: proc(mesh:^Nav_Mesh,start_ref:Nav_Ref,center:math.Vec3,radius:f32,filter:^Nav_Filter,out:[]Avoid_Wall) -> (count:int) {
    if filter==nil || !nav_point_finite(center) || !(radius>=0) || !(radius<=1e9) {return}
    if _,poly:=nav_poly_of(mesh,start_ref);poly==nil {return}
    room:=min(len(out),AVOID_MAX_WALLS)
    if room==0 {return}
    distances:[AVOID_MAX_WALLS]f32
    nodes:[NAV_WALL_NODES]Nav_Ref
    nodes[0]=start_ref
    used:=1
    flat :: #force_inline proc "contextless" (v:math.Vec3) -> math.Vec3 {return {v.x,0,v.z}}
    for at:=0;at<used;at+=1 {
        ref:=nodes[at]
        tile,poly:=nav_poly_of(mesh,ref)
        if poly==nil {continue}
        corners:[NAV_VERTS_PER_POLY]math.Vec3
        n:=nav_poly_vertices(tile,poly,&corners)
        inside:=nav_poly_center(tile,poly)
        open:=nav_open_edges(mesh,ref,filter)
        for e in 0..<n {
            a,b:=corners[e],corners[(e+1)%n]
            on,_:=math.closest_point_segment(flat(center),{flat(a),flat(b)})
            d:=linalg.length2(on-flat(center))
            if !(d<=radius*radius) {continue}
            if open[e]!=0 {
                seen:=false
                for k in 0..<used {if nodes[k]==open[e] {seen=true;break}}
                if !seen && used<NAV_WALL_NODES {nodes[used]=open[e];used+=1}
                continue
            }
            if count==room && d>=distances[count-1] {continue}
            wall:=Avoid_Wall{{a.x,a.z},{b.x,b.z}}
            along:=wall.b-wall.a
            if along.y*(inside.x-a.x)-along.x*(inside.z-a.z)<0 {wall.a,wall.b=wall.b,wall.a}
            slot:=min(count,room-1)
            for slot>0 && distances[slot-1]>d {
                out[slot]=out[slot-1];distances[slot]=distances[slot-1]
                slot-=1
            }
            out[slot]=wall;distances[slot]=d
            count=min(count+1,room)
        }
    }
    return
}

// Walks the segment from `start` on start_ref toward `end` over the surface
// as seen from above. `t` is the fraction of the segment walked before a wall
// (max(f32) when it reaches the end) and `normal` the wall's, on XZ; the
// polygons crossed go to `visited`.
nav_raycast :: proc(mesh:^Nav_Mesh,start_ref:Nav_Ref,start,end:math.Vec3,filter:^Nav_Filter,visited:[]Nav_Ref) -> (t:f32,normal:math.Vec3,count:int) {
    if !nav_point_finite(start) || !nav_point_finite(end) || filter==nil {return 0,{},0}
    ref:=start_ref
    for steps:=0;steps<1<<16;steps+=1 {
        tile,poly:=nav_poly_of(mesh,ref)
        if poly==nil {return 0,{},count}
        if count<len(visited) {visited[count]=ref;count+=1}
        corners:[NAV_VERTS_PER_POLY]math.Vec3
        n:=nav_poly_vertices(tile,poly,&corners)
        ok,_,tmax,_,exit:=nav_segment_poly_xz(start,end,corners[:n])
        if !ok {return 0,{},count}
        if exit<0 {return max(f32),{},count}
        // The neighbor through the exit edge whose part of the edge the segment crosses.
        next:Nav_Ref
        hit:=start+(end-start)*tmax
        it:=nav_steps(mesh,ref)
        for step in nav_steps_next(&it) {
            if int(step.edge)!=exit || nav_ref_is_link(step.to) {continue}
            _,other:=nav_poly_of(mesh,step.to)
            if other==nil || !nav_filter_passes(filter,other.area) {continue}
            if step.low!=0 || step.high!=255 {
                a,b:=corners[exit],corners[(exit+1)%n]
                _,s:=math.closest_point_segment({hit.x,0,hit.z},{{a.x,0,a.z},{b.x,0,b.z}})
                if s*255<f32(step.low)-1 || s*255>f32(step.high)+1 {continue}
            }
            next=step.to
            break
        }
        if next==0 {
            a,b:=corners[exit],corners[(exit+1)%n]
            edge:=b-a
            normal=linalg.normalize0(math.Vec3{edge.z,0,-edge.x})
            if cross_xz(a,b,nav_poly_center(tile,poly))<0 {normal=-normal}
            if linalg.dot(normal,end-start)>0 {normal=-normal}
            return tmax,normal,count
        }
        ref=next
    }
    return 0,{},count
}
// Clips the segment by a convex polygon on XZ: where it enters and leaves
// (fractions) and through which edges; -1 for an end inside.
@(private)
nav_segment_poly_xz :: proc "contextless" (p0,p1:math.Vec3,corners:[]math.Vec3) -> (ok:bool,tmin,tmax:f32,enter,exit:int) {
    tmin,tmax,enter,exit=0,1,-1,-1
    d:=p1-p0
    n:=len(corners)
    // Orientation: normals point inside for counter-clockwise on (x, z up).
    sign:=f32(1)
    if n>=3 && cross_xz(corners[0],corners[1],corners[2])<0 {sign=-1}
    for i in 0..<n {
        a,b:=corners[i],corners[(i+1)%n]
        edge:=b-a
        diff:=p0-a
        numerator:=sign*(edge.x*diff.z-edge.z*diff.x)
        denominator:=-sign*(edge.x*d.z-edge.z*d.x)
        if abs(denominator)<1e-9 {
            if numerator<0 {return false,0,0,-1,-1}
            continue
        }
        t:=numerator/denominator
        if denominator<0 {
            if t>tmin {tmin=t;enter=i}
            if tmin>tmax {return false,0,0,-1,-1}
        } else {
            if t<tmax {tmax=t;exit=i}
            if tmax<tmin {return false,0,0,-1,-1}
        }
    }
    return true,tmin,tmax,enter,exit
}

// A random point of the mesh, each polygon as likely as its area, among the
// areas the filter walks.
nav_random_point :: proc(mesh:^Nav_Mesh,filter:^Nav_Filter,rng:^math.Rng) -> (ref:Nav_Ref,point:math.Vec3,ok:bool) {
    if filter==nil || rng==nil {return}
    total:f32
    for &tile in mesh.tiles {
        if !tile.used {continue}
        for &poly,i in tile.data.polys {
            if !nav_filter_passes(filter,poly.area) {continue}
            area:=nav_poly_area_xz(&tile,&poly)
            if !(area>0) {continue}
            total+=area
            if math.random_f32(rng)*total<=area {ref=nav_tile_ref(mesh,&tile,i)}
        }
    }
    if ref==0 {return}
    return ref,nav_random_point_in_poly(mesh,ref,rng),true
}
@(private)
nav_poly_area_xz :: proc "contextless" (tile:^Nav_Tile,poly:^Nav_Poly) -> f32 {
    corners:[NAV_VERTS_PER_POLY]math.Vec3
    n:=nav_poly_vertices(tile,poly,&corners)
    area:f32
    for i in 1..<n-1 {area+=abs(cross_xz(corners[0],corners[i],corners[i+1]))*0.5}
    return area
}
@(private)
nav_random_point_in_poly :: proc(mesh:^Nav_Mesh,ref:Nav_Ref,rng:^math.Rng) -> math.Vec3 {
    tile,poly:=nav_poly_of(mesh,ref)
    corners:[NAV_VERTS_PER_POLY]math.Vec3
    n:=nav_poly_vertices(tile,poly,&corners)
    total:f32
    pick:=1
    for i in 1..<n-1 {
        area:=abs(cross_xz(corners[0],corners[i],corners[i+1]))
        total+=area
        if math.random_f32(rng)*total<=area {pick=i}
    }
    s,t:=math.random_f32(rng),math.random_f32(rng)
    if s+t>1 {s,t=1-s,1-t}
    p:=corners[0]+(corners[pick]-corners[0])*s+(corners[pick+1]-corners[0])*t
    if y,ok:=nav_poly_height(mesh,ref,p);ok {p.y=y}
    return p
}

// What a walk over the polygons around a point gathers.
@(private)
Nav_Around :: struct {
    center:math.Vec3,
    radius:f32,
    random:bool, // every polygon within the radius, not only up to the nearest wall; one picked when there is an rng
    rng:^math.Rng,
    total:f32,
    pick:Nav_Ref,
    wall:f32, // squared distance to the nearest wall found
    wall_point,wall_normal:math.Vec3,
}

@(private)
nav_around_neighbors :: proc(q:^Nav_Query,key:u64,edges:^Edge_List) {
    from:=Nav_Ref(key)
    tile,poly:=nav_poly_of(q.mesh,from)
    if poly==nil {return}
    a:=&q.around
    corners:[NAV_VERTS_PER_POLY]math.Vec3
    n:=nav_poly_vertices(tile,poly,&corners)
    if a.random && a.rng!=nil {
        area:=nav_poly_area_xz(tile,poly)
        if area>0 {
            a.total+=area
            if math.random_f32(a.rng)*a.total<=area {a.pick=from}
        }
    }
    flat :: #force_inline proc "contextless" (v:math.Vec3) -> math.Vec3 {return {v.x,0,v.z}}
    open:=nav_open_edges(q.mesh,from,&q.filter)
    slot,_:=search_find(&q.search,key)
    count:=0
    for e in 0..<n {
        x,y:=corners[e],corners[(e+1)%n]
        on,_:=math.closest_point_segment(flat(a.center),{flat(x),flat(y)})
        d:=linalg.length2(on-flat(a.center))
        if open[e]==0 {
            if !a.random && d<a.wall {
                a.wall=d
                _,t:=math.closest_point_segment(flat(a.center),{flat(x),flat(y)})
                a.wall_point=x+(y-x)*t
                edge:=y-x
                a.wall_normal=linalg.normalize0(math.Vec3{edge.z,0,-edge.x})
                if linalg.dot(a.wall_normal,a.center-a.wall_point)<0 {a.wall_normal=-a.wall_normal}
            }
            continue
        }
        limit:=a.radius*a.radius if a.random else min(a.radius*a.radius,a.wall)
        if d>limit || count>=len(q.candidates) {continue}
        q.candidates[count]=(x+y)*0.5
        edge_add(edges,u64(open[e]),linalg.distance(q.points[slot],q.candidates[count]),u32(count))
        count+=1
    }
}
@(private)
nav_around_heuristic :: proc(q:^Nav_Query,key,goal:u64) -> f32 {return 0}

@(private)
nav_around :: proc(q:^Nav_Query,mesh:^Nav_Mesh,start_ref:Nav_Ref,center:math.Vec3,radius:f32,filter:^Nav_Filter) -> bool {
    q.mesh=nil
    if len(q.points)==0 || filter==nil || !nav_point_finite(center) || !(radius>=0) || !(radius<=1e9) {return false}
    if _,poly:=nav_poly_of(mesh,start_ref);poly==nil {return false}
    q.mesh,q.filter,q.toward=mesh,filter^,false
    q.end_ref=0
    status:=search_begin(&q.search,u64(start_ref),0,q,nav_around_heuristic)
    if slot,ok:=search_find(&q.search,u64(start_ref));ok {q.points[slot]=center}
    if status==.Running {search_step(&q.search,q,nav_around_neighbors,nav_around_heuristic,nav_space_accept,max(int))}
    q.mesh=nil
    return true
}

// A random point among the polygons connected to start_ref within `radius`
// of `center`, each as likely as its area.
nav_random_point_around :: proc(q:^Nav_Query,mesh:^Nav_Mesh,start_ref:Nav_Ref,center:math.Vec3,radius:f32,filter:^Nav_Filter,rng:^math.Rng) -> (ref:Nav_Ref,point:math.Vec3,ok:bool) {
    if rng==nil {return}
    q.around={center=center,radius=radius,random=true,rng=rng}
    if !nav_around(q,mesh,start_ref,center,radius,filter) || q.around.pick==0 {return}
    ref=q.around.pick
    return ref,nav_random_point_in_poly(mesh,ref,rng),true
}

// The distance from `center` to the nearest wall among the polygons
// connected to start_ref, looking up to `radius`; the point and the normal of
// that wall. `radius` and false when there is none that near.
nav_distance_to_wall :: proc(q:^Nav_Query,mesh:^Nav_Mesh,start_ref:Nav_Ref,center:math.Vec3,radius:f32,filter:^Nav_Filter) -> (distance:f32,point,normal:math.Vec3,ok:bool) {
    q.around={center=center,radius=radius,wall=radius*radius}
    if !nav_around(q,mesh,start_ref,center,radius,filter) {return radius,{},{},false}
    if q.around.wall>=radius*radius {return radius,{},{},false}
    return linalg.sqrt(q.around.wall),q.around.wall_point,q.around.wall_normal,true
}
