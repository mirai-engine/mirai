package ai

import "core:math/linalg"
import math "mirai:std/math"

// Paths over a mesh and a volume together, for an agent that walks and swims
// or walks and flies: space links join a point of the surface with a point
// of the free space (the shore and the water over it, a ledge and the air it
// takes off into), and one search goes over polygons, links and cells, from
// the polygon of a space link to its cell and, both ways, back. The memory
// and the steps are those of a volume search; the mesh is searched as by
// Nav_Query.

NAV_QUERY_SPACE_LINKS :: 256 // space links one search takes

Nav_Space_Link :: struct {
    surface:math.Vec3, // on the mesh
    space:math.Vec3,   // in the free space of the volume
    two_way:bool,      // also from the space onto the surface
    cost:f32,          // added to its length
    kind:u8,           // what crossing it is, for whoever crosses it
}

Nav_Medium_Query :: struct {
    using volume_query:Nav_Volume_Query, // its search, points and candidates are those of the whole search
    mesh:^Nav_Mesh,
    filter:Nav_Filter,
    links:[NAV_QUERY_SPACE_LINKS]Nav_Space_Link,
    polys,cells:[NAV_QUERY_SPACE_LINKS]Nav_Ref, // where the ends of each link rest
    count:int,
}

nav_medium_query_init :: proc(q:^Nav_Medium_Query,nodes:int,allocator:=context.allocator) -> bool {
    q^={}
    return nav_volume_query_init(&q.volume_query,nodes,allocator)
}
nav_medium_query_destroy :: proc(q:^Nav_Medium_Query) {
    nav_volume_query_destroy(&q.volume_query)
    q^={}
}

@(private)
nav_medium_valid :: proc "contextless" (q:^Nav_Medium_Query,ref:Nav_Ref) -> bool {
    if nav_ref_is_volume(ref) {return nav_volume_ref_valid(q.volume,ref)}
    return nav_ref_valid(q.mesh,ref)
}

@(private)
nav_medium_neighbors :: proc(q:^Nav_Medium_Query,key:u64,edges:^Edge_List) {
    ref:=Nav_Ref(key)
    slot,ok:=search_find(&q.search,key)
    if !ok {return}
    p:=q.points[slot]
    if nav_ref_is_volume(ref) {
        nav_volume_space_neighbors(&q.volume_query,key,edges)
        for i in 0..<q.count {
            if q.cells[i]!=ref || !q.links[i].two_way || edges.count>=len(q.candidates) {continue}
            c:=q.links[i]
            _,poly:=nav_poly_of(q.mesh,q.polys[i])
            if poly==nil || !nav_filter_passes(&q.filter,poly.area) {continue}
            cost:=linalg.distance(p,c.space)+linalg.distance(c.space,c.surface)+c.cost
            if q.polys[i]==q.end_ref {cost+=linalg.distance(c.surface,q.end)*nav_filter_cost(&q.filter,poly.area)}
            q.candidates[edges.count]=c.surface
            edge_add(edges,u64(q.polys[i]),cost,u32(edges.count))
        }
        return
    }
    nav_mesh_edges(q.mesh,&q.filter,ref,p,q.end,q.end_ref,q.candidates[:],edges)
    if nav_ref_is_link(ref) {return}
    _,poly:=nav_poly_of(q.mesh,ref)
    if poly==nil {return}
    area_cost:=nav_filter_cost(&q.filter,poly.area)
    for i in 0..<q.count {
        if q.polys[i]!=ref || edges.count>=len(q.candidates) {continue}
        c:=q.links[i]
        cost:=linalg.distance(p,c.surface)*area_cost+linalg.distance(c.surface,c.space)+c.cost
        if q.cells[i]==q.end_ref {cost+=linalg.distance(c.space,q.end)}
        q.candidates[edges.count]=c.space
        edge_add(edges,u64(q.cells[i]),cost,u32(edges.count))
    }
}

// The volume is searched with its weighed heuristic and the mesh with the plain one.
@(private)
nav_medium_heuristic :: proc(q:^Nav_Medium_Query,key,goal:u64) -> f32 {
    scale:=NAV_VOLUME_HEURISTIC_SCALE if nav_ref_is_volume(Nav_Ref(key)) else NAV_HEURISTIC_SCALE
    return linalg.distance(q.accepted,q.end)*scale
}
@(private)
nav_medium_accept :: proc(q:^Nav_Medium_Query,slot:u32,edge:Edge) {
    q.points[slot]=q.candidates[edge.data]
    q.accepted=q.points[slot]
}

// Starts a search from `start` to `end`, each on a polygon of the mesh or in
// a cell of the volume, over both through the space links whose ends rest on
// them within `extents` (the first NAV_QUERY_SPACE_LINKS); the filter is that
// of the mesh. nav_medium_path_step advances it and nav_medium_path_finish
// reads it.
nav_medium_path_begin :: proc(q:^Nav_Medium_Query,mesh:^Nav_Mesh,volume:^Nav_Volume,filter:^Nav_Filter,links:[]Nav_Space_Link,extents:math.Vec3,start_ref,end_ref:Nav_Ref,start,end:math.Vec3) -> Search_Status {
    q.mesh,q.volume,q.count=nil,nil,0
    if len(q.points)==0 || mesh==nil || volume==nil || filter==nil || !nav_point_finite(start) || !nav_point_finite(end) {return .Invalid}
    q.mesh,q.volume,q.filter=mesh,volume,filter^
    if !nav_medium_valid(q,start_ref) || !nav_medium_valid(q,end_ref) {q.mesh,q.volume=nil,nil;return .Invalid}
    for c in links {
        if q.count>=NAV_QUERY_SPACE_LINKS {break}
        if !nav_point_finite(c.surface) || !nav_point_finite(c.space) || !(c.cost>=0) {continue}
        poly,_,on:=nav_find_nearest(mesh,c.surface,extents,&q.filter)
        cell,_,inside:=nav_volume_find_nearest(volume,c.space,extents)
        if !on || !inside {continue}
        q.links[q.count],q.polys[q.count],q.cells[q.count]=c,poly,cell
        q.count+=1
    }
    q.start,q.end,q.start_ref,q.end_ref=start,end,start_ref,end_ref
    q.accepted=start
    status:=search_begin(&q.search,u64(start_ref),u64(end_ref),q,nav_medium_heuristic)
    if slot,ok:=search_find(&q.search,u64(start_ref));ok {q.points[slot]=start}
    return status
}
nav_medium_path_step :: proc(q:^Nav_Medium_Query,budget:int) -> Search_Status {
    if q.mesh==nil {return .Invalid}
    return search_step(&q.search,q,nav_medium_neighbors,nav_medium_heuristic,nav_medium_accept,budget)
}
// Writes the polygons, links and cells of the finished search. Without a way
// to the end, the path to the reached polygon or cell nearest to it, with
// `partial`. Invalid when a node of it stopped being valid while it ran.
nav_medium_path_finish :: proc(q:^Nav_Medium_Query,out:[]Nav_Ref) -> (count:int,status:Search_Status,partial:bool) {
    if q.mesh==nil {return 0,.Invalid,false}
    count,status,partial=nav_search_finish(&q.search,q.points,q.end,out)
    for ref in out[:count] {
        if !nav_medium_valid(q,ref) {return 0,.Invalid,false}
    }
    return
}
nav_medium_find_path :: proc(q:^Nav_Medium_Query,mesh:^Nav_Mesh,volume:^Nav_Volume,filter:^Nav_Filter,links:[]Nav_Space_Link,extents:math.Vec3,start_ref,end_ref:Nav_Ref,start,end:math.Vec3,out:[]Nav_Ref) -> (count:int,status:Search_Status,partial:bool) {
    status=nav_medium_path_begin(q,mesh,volume,filter,links,extents,start_ref,end_ref,start,end)
    if status==.Invalid {return 0,.Invalid,false}
    nav_medium_path_step(q,max(int))
    return nav_medium_path_finish(q,out)
}

// The first part of a path in one space, before it crosses into the other:
// its length, and the space link it takes after it in the order it is
// crossed (from its end in that part to its end in the next). `crosses` is
// false for a path that stays in one space.
nav_medium_first_part :: proc "contextless" (q:^Nav_Medium_Query,path:[]Nav_Ref) -> (count:int,from,to:math.Vec3,kind:u8,crosses:bool) {
    count=len(path)
    for i in 1..<len(path) {
        if nav_ref_is_volume(path[i])==nav_ref_is_volume(path[i-1]) {continue}
        count=i
        for k in 0..<q.count {
            c:=q.links[k]
            switch {
            case q.polys[k]==path[i-1] && q.cells[k]==path[i]: return i,c.surface,c.space,c.kind,true
            case q.cells[k]==path[i-1] && q.polys[k]==path[i]: return i,c.space,c.surface,c.kind,true
            }
        }
        return
    }
    return
}

// The space links of the shores of a mesh within a box: where a polygon of
// another area meets one of `water` (the ground under water deeper than it
// is walked), a link both ways from `inset` inside the dry polygon to `rise`
// over the wet one, `inset` beyond the edge; one every `spacing` metres. How
// many were written.
nav_shore_links :: proc "contextless" (mesh:^Nav_Mesh,box:math.Aabb,water:u8,inset,rise,spacing:f32,kind:u8,out:[]Nav_Space_Link) -> (count:int) {
    for &tile in mesh.tiles {
        if !tile.used || !math.aabb_overlaps(tile.data.bounds,box) {continue}
        for &poly,index in tile.data.polys {
            if poly.area==water || poly.area==NAV_AREA_BLOCKED {continue}
            from:=nav_tile_ref(mesh,&tile,index)
            center:=nav_poly_center(&tile,&poly)
            it:=nav_steps(mesh,from)
            for step in nav_steps_next(&it) {
                if nav_ref_is_link(step.to) {continue}
                next_tile,next:=nav_poly_of(mesh,step.to)
                if next==nil || next.area!=water {continue}
                left,right:=nav_step_portal(&tile,&poly,step)
                middle:=(left+right)*0.5
                if !math.aabb_contains_point(box,middle) {continue}
                out_dir:=nav_poly_center(next_tile,next)-center
                out_dir.y=0
                if linalg.length(out_dir)<1e-4 {continue}
                out_dir=linalg.normalize(out_dir)
                surface:=middle-out_dir*inset
                near:=false
                for previous in out[:count] {
                    if linalg.length2(previous.surface-surface)<spacing*spacing {near=true;break}
                }
                if near {continue}
                if count>=len(out) {return}
                out[count]={surface=surface,space=middle+out_dir*inset+{0,rise,0},two_way=true,kind=kind}
                count+=1
            }
        }
    }
    return
}
