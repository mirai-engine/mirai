package ai

import math "mirai:std/math"

// The path an agent follows, as plain data that copies with the agent: the
// polygons and links from where it is to its target. Each tick it moves the
// start to where the agent is (nav_corridor_move), asks for the next corners
// (nav_corridor_corners) and, when it reaches a link, crosses it
// (nav_corridor_cross). A path longer than the corridor keeps its first part,
// with the target on its last polygon, and is `cut`: whoever follows plans
// again before its end.

NAV_CORRIDOR_CAPACITY :: 64

Nav_Corridor :: struct {
    path:[NAV_CORRIDOR_CAPACITY]Nav_Ref,
    count:i32,
    position:math.Vec3, // of the agent, on the surface
    target:math.Vec3,   // on the last polygon of the path
    cut:bool,           // the path goes on past the last polygon
}

// A corridor of one polygon where the agent is.
nav_corridor_reset :: proc "contextless" (c:^Nav_Corridor,ref:Nav_Ref,position:math.Vec3) {
    c^={position=position,target=position}
    c.path[0]=ref
    c.count=1 if ref!=0 else 0
}

// Takes a path that starts on the polygon the agent is on and straightens it
// once (nav_path_straighten). When it does not fit, its first part, with the
// target moved onto the last polygon kept.
nav_corridor_set :: proc(c:^Nav_Corridor,mesh:^Nav_Mesh,filter:^Nav_Filter,target:math.Vec3,path:[]Nav_Ref) -> bool {
    if len(path)==0 || !nav_ref_valid(mesh,path[0]) {return false}
    count:=min(len(path),NAV_CORRIDOR_CAPACITY)
    // A cut path does not end on a link: its end would have no polygon.
    for count>1 && nav_ref_is_link(path[count-1]) {count-=1}
    copy(c.path[:count],path[:count])
    c.count=i32(count)
    c.target=target
    c.cut=count<len(path)
    if c.cut || nav_ref_is_link(path[count-1]) {
        c.target,_=nav_closest_point_on_poly(mesh,c.path[count-1],target)
    }
    c.count=i32(nav_path_straighten(mesh,filter,c.position,c.target,c.path[:],count))
    return true
}

nav_corridor_first :: #force_inline proc "contextless" (c:^Nav_Corridor) -> Nav_Ref {return c.path[0] if c.count>0 else 0}
nav_corridor_last :: #force_inline proc "contextless" (c:^Nav_Corridor) -> Nav_Ref {return c.path[c.count-1] if c.count>0 && c.count<=NAV_CORRIDOR_CAPACITY else 0}
@(private)
nav_corridor_slice :: #force_inline proc "contextless" (c:^Nav_Corridor) -> []Nav_Ref {return c.path[:clamp(c.count,0,NAV_CORRIDOR_CAPACITY)]}

// The next corners of the straight path from the agent to the target: the
// first is the next point to head for, and the list stops at the start of
// the first link. Corners closer to the agent than `reach` are passed.
nav_corridor_corners :: proc(c:^Nav_Corridor,mesh:^Nav_Mesh,out:[]Nav_Corner,reach:f32=0.01) -> int {
    path:=nav_corridor_slice(c)
    if len(path)==0 || len(out)==0 {return 0}
    scratch:[8]Nav_Corner
    corners:=scratch[:]
    count,_:=nav_straight_path(mesh,c.position,c.target,path,corners)
    near :: #force_inline proc "contextless" (a,b:math.Vec3,reach:f32) -> bool {return (a.x-b.x)*(a.x-b.x)+(a.z-b.z)*(a.z-b.z)<=reach*reach}
    written:=0
    for corner in corners[:count] {
        if .Start in corner.flags && corner.flags&{.Link,.End}=={} {continue}
        if written==0 && near(corner.position,c.position,reach) && corner.flags&{.Link,.End}=={} {continue}
        if written>=len(out) {break}
        out[written]=corner
        written+=1
        if .Link in corner.flags {break}
    }
    return written
}

// Moves the start of the corridor to where the agent is, over the surface
// from the first polygon: the polygons it walked over join the front of the
// path. The agent's position becomes the reachable one nearest to `position`.
// What no longer fits is cut from the end, with the target on the new last
// polygon. False when the first polygon is no longer valid.
nav_corridor_move :: proc(c:^Nav_Corridor,mesh:^Nav_Mesh,filter:^Nav_Filter,position:math.Vec3) -> bool {
    first:=nav_corridor_first(c)
    if !nav_ref_valid(mesh,first) || nav_ref_is_link(first) {return false}
    visited:[NAV_MOVE_NODES]Nav_Ref
    result,count:=nav_move_along_surface(mesh,first,c.position,position,filter,visited[:])
    if count==0 {return false}
    kept,cut:=nav_merge_start_moved(c.path[:],len(nav_corridor_slice(c)),visited[:count])
    c.count=i32(kept)
    c.position=result
    if cut {
        for c.count>1 && nav_ref_is_link(c.path[c.count-1]) {c.count-=1}
        c.cut=true
        c.target,_=nav_closest_point_on_poly(mesh,c.path[c.count-1],c.target)
    }
    return true
}

// Joins the polygons walked from the start (in order) to the front of a path:
// from the last of them back to the furthest polygon the path shares. Cut when
// the end of the path no longer fits.
@(private)
nav_merge_start_moved :: proc "contextless" (path:[]Nav_Ref,count:int,visited:[]Nav_Ref) -> (kept:int,cut:bool) {
    furthest_path,furthest_visited:=-1,-1
    search: for i:=count-1;i>=0;i-=1 {
        for j:=len(visited)-1;j>=0;j-=1 {
            if path[i]==visited[j] {furthest_path,furthest_visited=i,j;break search}
        }
    }
    if furthest_path<0 {return count,false}
    need:=len(visited)-furthest_visited
    from:=min(furthest_path+1,count)
    size:=max(0,count-from)
    if need+size>len(path) {size,cut=len(path)-need,true}
    if size>0 {copy(path[need:need+size],path[from:from+size])}
    for i in 0..<need {path[i]=visited[len(visited)-1-i]}
    return need+size,cut
}

// Crosses the link at the front of the corridor: the path goes on from the
// polygon at its far end, and the agent is placed at that end. The ends of
// the link, as crossed; false when the next step is not a valid link.
nav_corridor_cross :: proc "contextless" (c:^Nav_Corridor,mesh:^Nav_Mesh) -> (from,to:math.Vec3,link:Nav_Ref,ok:bool) {
    path:=nav_corridor_slice(c)
    at:=-1
    for ref,i in path {if nav_ref_is_link(ref) {at=i;break}}
    if at<0 || at+1>=len(path) {return}
    l:=nav_link_of(mesh,path[at])
    if l==nil {return}
    from,to,_,_=nav_link_ends(l,path[at])
    link=path[at]
    rest:=len(path)-at-1
    copy(c.path[:rest],path[at+1:])
    c.count=i32(rest)
    c.position=to
    return from,to,link,true
}

// Whether the first `ahead` steps of the corridor still exist and are walked
// by the filter; when not, plan again.
nav_corridor_valid :: proc "contextless" (c:^Nav_Corridor,mesh:^Nav_Mesh,filter:^Nav_Filter,ahead:int) -> bool {
    path:=nav_corridor_slice(c)
    if len(path)==0 {return false}
    for ref in path[:clamp(ahead,0,len(path))] {
        if nav_ref_is_link(ref) {
            link:=nav_link_of(mesh,ref)
            if link==nil || link.start_poly==0 || link.end_poly==0 || !nav_link_crossable(link,filter.can) {return false}
            continue
        }
        _,poly:=nav_poly_of(mesh,ref)
        if poly==nil || !nav_filter_passes(filter,poly.area) {return false}
    }
    return true
}
