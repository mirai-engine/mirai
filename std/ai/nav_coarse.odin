package ai

import "base:runtime"
import "core:math/linalg"
import "core:slice"
import "mirai:std/base"
import math "mirai:std/math"

// A coarse graph of how the regions of a mesh or of a volume join (the
// sections of a world): portals where the surface, or the free space, crosses
// the border of a region, and between two portals of the same region the
// length of the way over the surface or through the space, with its corners. What moves where the mesh is not there is routed through it: from a
// point of one region to a point of another, through the portals of those
// between. A region is made from the mesh while the mesh is there and kept
// after its tiles go. A region the graph does not know, as the space outside
// every region, is crossed in a straight line between the portals that face it.
// The portals, ways and corners of a region are one block of each array, in
// the order of the regions.

NAV_PORTAL_MERGE :: f32(4)  // m: crossings of a border this near each other are one portal
NAV_REGION_PORTALS :: 32    // portals a region keeps
NAV_REGION_CROSSINGS :: 4096 // crossings of its border a region looks at
NAV_COARSE_CORNERS :: 16    // corners a way keeps between its two portals

Nav_Portal :: struct {
    position:math.Vec3,
    region,outside:u64,       // the region on whose border it is, and the one beyond it; 0: outside every region
    twin:i32,                 // the portal of the region beyond facing back nearest to it; -1: none
    edge_first,edge_count:u32, // its ways inside its region
}

Nav_Coarse_Edge :: struct {
    to:u32,                        // the portal it leads to
    length:f32,                    // m over the surface
    corner_first,corner_count:u32, // where it turns between the two portals, in order from this one
}

Nav_Coarse_Region :: struct {
    key:u64,
    hash:u64,                      // of what it was made from, for its maker
    portal_first,portal_count:u32,
    edge_first,edge_count:u32,
    corner_first,corner_count:u32,
}

Nav_Coarse :: struct {
    regions:[dynamic]Nav_Coarse_Region,
    portals:[dynamic]Nav_Portal,
    edges:[dynamic]Nav_Coarse_Edge,
    corners:[dynamic]math.Vec3,
}

// The region a point of the surface is in, by the boxes of its caller.
Nav_Region_Of :: proc(user:rawptr,point:math.Vec3) -> u64

nav_coarse_destroy :: proc(c:^Nav_Coarse) {
    delete(c.regions);delete(c.portals);delete(c.edges);delete(c.corners)
    c^={}
}

// Makes dst a copy of src. A transaction: false without memory, leaving dst empty.
nav_coarse_copy :: proc(dst,src:^Nav_Coarse,allocator:=context.allocator) -> bool {
    nav_coarse_destroy(dst)
    if len(src.regions)==0 {return true}
    e1,e2,e3,e4:runtime.Allocator_Error
    dst.regions,e1=make([dynamic]Nav_Coarse_Region,len(src.regions),allocator)
    dst.portals,e2=make([dynamic]Nav_Portal,len(src.portals),allocator)
    dst.edges,e3=make([dynamic]Nav_Coarse_Edge,len(src.edges),allocator)
    dst.corners,e4=make([dynamic]math.Vec3,len(src.corners),allocator)
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil {nav_coarse_destroy(dst);return false}
    copy(dst.regions[:],src.regions[:]);copy(dst.portals[:],src.portals[:]);copy(dst.edges[:],src.edges[:]);copy(dst.corners[:],src.corners[:])
    return true
}

// The region of a key the graph knows, or nil.
nav_coarse_region :: proc "contextless" (c:^Nav_Coarse,key:u64) -> ^Nav_Coarse_Region {
    if key==0 {return nil}
    for &region in c.regions {if region.key==key {return &region}}
    return nil
}

// Takes a region out of the graph, with its portals and ways. False when the graph does not know it.
nav_coarse_remove :: proc(c:^Nav_Coarse,key:u64) -> bool {
    at:=-1
    for region,i in c.regions {if region.key==key {at=i;break}}
    if at<0 {return false}
    gone:=c.regions[at]
    if !nav_coarse_consistent(c) {
        clear(&c.regions);clear(&c.portals);clear(&c.edges);clear(&c.corners)
        return true
    }
    pf,pc:=int(gone.portal_first),int(gone.portal_count)
    ef,ec:=int(gone.edge_first),int(gone.edge_count)
    cf,cc:=int(gone.corner_first),int(gone.corner_count)
    remove_range(&c.portals,pf,pf+pc)
    remove_range(&c.edges,ef,ef+ec)
    remove_range(&c.corners,cf,cf+cc)
    ordered_remove(&c.regions,at)
    for &region in c.regions[at:] {
        region.portal_first-=u32(pc);region.edge_first-=u32(ec);region.corner_first-=u32(cc)
    }
    for &portal in c.portals[pf:] {portal.edge_first-=u32(ec)}
    for &edge in c.edges {
        if int(edge.to)>=pf+pc {edge.to-=u32(pc)}
        if int(edge.corner_first)>=cf+cc {edge.corner_first-=u32(cc)}
    }
    nav_coarse_twins(c)
    return true
}

// Adds to dst the regions of src it does not know. A transaction: false
// without memory, leaving dst as it was.
nav_coarse_merge :: proc(dst,src:^Nav_Coarse) -> bool {
    if !nav_coarse_consistent(src) {return true}
    added:=false
    for region in src.regions {
        if nav_coarse_region(dst,region.key)!=nil {continue}
        pf,pc:=int(region.portal_first),int(region.portal_count)
        ef,ec:=int(region.edge_first),int(region.edge_count)
        cf,cc:=int(region.corner_first),int(region.corner_count)
        portals,edges,corners,regions:=len(dst.portals),len(dst.edges),len(dst.corners),len(dst.regions)
        _,e1:=append(&dst.portals,..src.portals[pf:pf+pc])
        _,e2:=append(&dst.edges,..src.edges[ef:ef+ec])
        _,e3:=append(&dst.corners,..src.corners[cf:cf+cc])
        moved:=region
        moved.portal_first,moved.edge_first,moved.corner_first=u32(portals),u32(edges),u32(corners)
        _,e4:=append(&dst.regions,moved)
        if e1!=nil || e2!=nil || e3!=nil || e4!=nil {
            base.truncate(&dst.portals,portals);base.truncate(&dst.edges,edges);base.truncate(&dst.corners,corners);base.truncate(&dst.regions,regions)
            nav_coarse_twins(dst)
            return false
        }
        for &portal in dst.portals[portals:] {portal.edge_first=portal.edge_first-u32(ef)+u32(edges)}
        for &edge in dst.edges[edges:] {
            edge.to=edge.to-u32(pf)+u32(portals)
            edge.corner_first=edge.corner_first-u32(cf)+u32(corners)
        }
        added=true
    }
    if added {nav_coarse_twins(dst)}
    return true
}

// Whether the blocks of the regions cover the arrays and every index stays in
// them: a graph read from a file may not.
@(private)
nav_coarse_consistent :: proc "contextless" (c:^Nav_Coarse) -> bool {
    portals,edges,corners:u64
    for region in c.regions {
        if u64(region.portal_first)!=portals || u64(region.edge_first)!=edges || u64(region.corner_first)!=corners {return false}
        portals+=u64(region.portal_count);edges+=u64(region.edge_count);corners+=u64(region.corner_count)
    }
    if portals!=u64(len(c.portals)) || edges!=u64(len(c.edges)) || corners!=u64(len(c.corners)) {return false}
    for region in c.regions {
        for portal in c.portals[region.portal_first:][:region.portal_count] {
            if portal.region!=region.key || u64(portal.edge_first)+u64(portal.edge_count)>edges {return false}
            if portal.edge_first<region.edge_first || portal.edge_first+portal.edge_count>region.edge_first+region.edge_count {return false}
            if !nav_point_finite(portal.position) {return false}
        }
    }
    for edge in c.edges {
        if u64(edge.to)>=portals || u64(edge.corner_first)+u64(edge.corner_count)>corners || !(edge.length>=0) || !(edge.length<=1e9) {return false}
    }
    for corner in c.corners {if !nav_point_finite(corner) {return false}}
    return true
}

// Each portal facing a region the graph knows takes the portal of that region facing back nearest to it.
@(private)
nav_coarse_twins :: proc "contextless" (c:^Nav_Coarse) {
    for &p in c.portals {
        p.twin=-1
        if p.outside==0 {continue}
        best:=f32(max(f32))
        for q,j in c.portals {
            if q.region!=p.outside || q.outside!=p.region {continue}
            d:=linalg.length2(q.position-p.position)
            if d<best {best=d;p.twin=i32(j)}
        }
    }
}

// Where the surface crosses the border of a region: a point on the edge it
// crosses, and the region beyond it.
@(private)
Nav_Crossing :: struct {
    point:math.Vec3,
    outside:u64,
}

// How the ways of a region are found over what it was made from: where a
// portal is on it (farther for a portal kept from before), and the search of
// the way between two points of it, in steps of a budget of nodes, whose
// finish writes the corners of the way, both ends included; 0 without a way.
@(private)
Coarse_Ways :: struct {
    user:rawptr,
    snap:proc(user:rawptr,point:math.Vec3,far:bool) -> (ref:Nav_Ref,at:math.Vec3,ok:bool),
    begin:proc(user:rawptr,a,b:math.Vec3,from,to:Nav_Ref) -> bool,
    step:proc(user:rawptr,budget:int) -> (status:Search_Status,expanded:int),
    finish:proc(user:rawptr,a,b:math.Vec3,out:[]math.Vec3) -> int,
}

// A region of the graph on its way, made in steps so that it spreads over
// ticks: the crossings of the border of a volume, a zone a step (those of a
// mesh when it begins), then the way between every two portals by searches
// that expand at most a budget of nodes a step. The region it makes again
// stays in the graph until its last step puts the new one in its place. It
// keeps no pointer: each step is given what it began with, and a way through
// cells that stopped being valid meanwhile is left out.
Nav_Coarse_Build :: struct {
    key,hash:u64,
    portals:[NAV_REGION_PORTALS]Nav_Portal,
    refs:[NAV_REGION_PORTALS]Nav_Ref,
    at:[NAV_REGION_PORTALS]math.Vec3, // where each portal meets what the region is made from
    count:int,
    complete:bool,                     // every crossing and portal fit
    from,to:int,                       // the pair whose way comes next, from<to
    searching:bool,                    // its search began
    ways:[NAV_REGION_PORTALS][NAV_REGION_PORTALS]Coarse_Way, // by pair, from<to
    corners:[dynamic]math.Vec3,
    crossings:[dynamic]Nav_Crossing,   // NAV_REGION_CROSSINGS, the first crossing_count found
    crossing_count:int,
    // While the border of a volume is scanned: the zone it comes to, those it
    // covers, and what its portals are made with when it ends.
    scanning:bool,
    scan,scan_low,scan_high:[3]i32,
    box:math.Aabb,
    merge:f32,
    kept:[NAV_REGION_PORTALS]Nav_Portal,
    kept_count:int,
}

@(private)
Coarse_Way :: struct {
    length:f32,
    corner_first,corner_count:u32,
    found:bool,
}

Nav_Coarse_Status :: enum u8 {
    Running, // the step ran out of its budget: call it again
    Done,    // the region is in the graph
    Failed,  // no memory: the region is left out
}

nav_coarse_build_destroy :: proc(b:^Nav_Coarse_Build) {
    delete(b.corners);delete(b.crossings)
    b^={}
}

// A build of a region from the start, keeping the room it has. False without memory.
@(private)
coarse_build_reset :: proc(b:^Nav_Coarse_Build,key,hash:u64) -> bool {
    corners,crossings:=b.corners,b.crossings
    clear(&corners)
    if len(crossings)!=NAV_REGION_CROSSINGS && resize(&crossings,NAV_REGION_CROSSINGS)!=nil {return false}
    b^={key=key,hash=hash,complete=true,to=1,corners=corners,crossings=crossings}
    return true
}

// Starts making again the part of a region of the graph from the mesh: the
// crossings of the border of `box`, joined into portals when they are near
// and lead to the same region (`region_of` tells, of a point of the surface
// beyond); nav_coarse_step_region then finds the way over the surface
// between every two of them for an agent of the filter. The portals it had
// toward the regions `kept` (those whose mesh is not there to show them
// again) stay when no new one faces the same region near them. A
// transaction: it allocates. False, leaving the region out, when the box,
// the key or the arguments are not usable or there is no memory.
nav_coarse_begin_region :: proc(b:^Nav_Coarse_Build,c:^Nav_Coarse,mesh:^Nav_Mesh,filter:^Nav_Filter,key,hash:u64,box:math.Aabb,region_of:Nav_Region_Of,user:rawptr,kept:[]u64={}) -> bool {
    old,old_count:=coarse_kept(c,key,kept)
    if !coarse_begin_region(b,mesh,filter,key,hash,box,region_of,user,old[:old_count]) {
        nav_coarse_remove(c,key)
        return false
    }
    return true
}

@(private)
coarse_begin_region :: proc(b:^Nav_Coarse_Build,mesh:^Nav_Mesh,filter:^Nav_Filter,key,hash:u64,box:math.Aabb,region_of:Nav_Region_Of,user:rawptr,old:[]Nav_Portal) -> bool {
    if key==0 || mesh==nil || filter==nil || region_of==nil || len(mesh.tiles)==0 {return false}
    if !nav_point_finite(box.min) || !nav_point_finite(box.max) || !(box.min.x<=box.max.x && box.min.y<=box.max.y && box.min.z<=box.max.z) {return false}
    low,high:=nav_mesh_coord(mesh,box.min),nav_mesh_coord(mesh,box.max)
    if i64(high.x)-i64(low.x)>4096 || i64(high.y)-i64(low.y)>4096 || !coarse_build_reset(b,key,hash) {return false}
    crossings:=b.crossings[:]
    complete:bool
    count:=0
    complete=true
    inside :: proc "contextless" (box:math.Aabb,p:math.Vec3,climb:f32) -> bool {
        return p.x>=box.min.x && p.x<=box.max.x && p.z>=box.min.z && p.z<=box.max.z && p.y>=box.min.y-climb && p.y<=box.max.y+climb
    }
    // Tiles by coordinate, polygons in order: the same mesh gives the same crossings.
    for z in low.y-1..=high.y+1 {
        for x in low.x-1..=high.x+1 {
            tile:=nav_mesh_tile_at(mesh,{x,z})
            if tile==nil {continue}
            for &poly,i in tile.data.polys {
                if !nav_filter_passes(filter,poly.area) {continue}
                center:=nav_poly_center(tile,&poly)
                if !inside(box,center,mesh.climb) {continue}
                from:=nav_tile_ref(mesh,tile,i)
                it:=nav_steps(mesh,from)
                for step in nav_steps_next(&it) {
                    point,beyond:math.Vec3
                    if nav_ref_is_link(step.to) {
                        link:=nav_link_of(mesh,step.to)
                        if link==nil || !nav_link_crossable(link,filter.can) {continue}
                        start,end,_,to:=nav_link_ends(link,step.to)
                        other_tile,other:=nav_poly_of(mesh,to)
                        if other==nil {continue}
                        point,beyond=start,nav_poly_center(other_tile,other)
                        if inside(box,end,mesh.climb) {continue}
                    } else {
                        other_tile,other:=nav_poly_of(mesh,step.to)
                        if other==nil || !nav_filter_passes(filter,other.area) {continue}
                        beyond=nav_poly_center(other_tile,other)
                        if inside(box,beyond,mesh.climb) {continue}
                        left,right,found:=nav_portal_points(mesh,from,step.to)
                        if !found {continue}
                        point=(left+right)*0.5
                    }
                    outside:=region_of(user,beyond)
                    if outside==key {continue}
                    if count==len(crossings) {complete=false;continue}
                    crossings[count]={point,outside}
                    count+=1
                }
            }
        }
    }
    b.complete=complete
    ways:=Mesh_Ways{mesh=mesh,filter=filter}
    coarse_build_portals(b,crossings[:count],old,coarse_mesh_ways(&ways))
    return true
}

// Advances a build begun by nav_coarse_begin_region with searches that
// expand about `budget` polygons, given the mesh and the filter it began with.
nav_coarse_step_region :: proc(b:^Nav_Coarse_Build,c:^Nav_Coarse,mesh:^Nav_Mesh,q:^Nav_Query,filter:^Nav_Filter,budget:int) -> Nav_Coarse_Status {
    ways:=Mesh_Ways{mesh,q,filter}
    return coarse_build_step(b,c,coarse_mesh_ways(&ways),budget)
}

// Makes again the part of a region of the graph from the mesh at once, as
// nav_coarse_begin_region and its steps. How many portals; false, leaving the
// region out, when it cannot be made, and `complete` false when some
// crossings or portals did not fit.
nav_coarse_build_region :: proc(c:^Nav_Coarse,mesh:^Nav_Mesh,q:^Nav_Query,filter:^Nav_Filter,key,hash:u64,box:math.Aabb,region_of:Nav_Region_Of,user:rawptr,kept:[]u64={}) -> (portals:int,complete,ok:bool) {
    if q==nil || len(q.points)==0 {nav_coarse_remove(c,key);return}
    b:Nav_Coarse_Build
    defer nav_coarse_build_destroy(&b)
    if !nav_coarse_begin_region(&b,c,mesh,filter,key,hash,box,region_of,user,kept) {return}
    status:=Nav_Coarse_Status.Running
    for status==.Running {status=nav_coarse_step_region(&b,c,mesh,q,filter,max(int))}
    if status!=.Done {return}
    return b.count,b.complete,true
}

@(private)
Mesh_Ways :: struct {mesh:^Nav_Mesh,q:^Nav_Query,filter:^Nav_Filter}

@(private)
coarse_mesh_ways :: proc(w:^Mesh_Ways) -> Coarse_Ways {
    snap :: proc(user:rawptr,point:math.Vec3,far:bool) -> (ref:Nav_Ref,at:math.Vec3,ok:bool) {
        w:=(^Mesh_Ways)(user)
        reach:=f32(NAV_PORTAL_MERGE*0.5) if far else 0.5
        return nav_find_nearest(w.mesh,point,{reach,w.mesh.climb+reach,reach},w.filter)
    }
    begin :: proc(user:rawptr,a,b:math.Vec3,from,to:Nav_Ref) -> bool {
        w:=(^Mesh_Ways)(user)
        return w.q!=nil && nav_path_begin(w.q,w.mesh,from,to,a,b,w.filter)!=.Invalid
    }
    step :: proc(user:rawptr,budget:int) -> (status:Search_Status,expanded:int) {
        w:=(^Mesh_Ways)(user)
        before:=w.q.search.stats.expanded
        status=nav_path_step(w.q,budget)
        return status,w.q.search.stats.expanded-before
    }
    finish :: proc(user:rawptr,a,b:math.Vec3,out:[]math.Vec3) -> int {
        w:=(^Mesh_Ways)(user)
        path:=transmute([]Nav_Ref)w.q.search.channel
        n,status,partial:=nav_path_finish(w.q,path)
        if status!=.Found || partial || n==0 {return 0}
        turns:[512]Nav_Corner
        turned,_:=nav_straight_path(w.mesh,a,b,path[:n],turns[:])
        count:=min(turned,len(out))
        for k in 0..<count {out[k]=turns[k].position}
        return count
    }
    return {w,snap,begin,step,finish}
}

// The portals a region has toward the regions kept, before it is made again.
@(private)
coarse_kept :: proc "contextless" (c:^Nav_Coarse,key:u64,kept:[]u64) -> (old:[NAV_REGION_PORTALS]Nav_Portal,count:int) {
    region:=nav_coarse_region(c,key)
    if region==nil || len(kept)==0 || !nav_coarse_consistent(c) {return}
    for p in c.portals[region.portal_first:][:region.portal_count] {
        for k in kept {
            if p.outside!=k || k==0 {continue}
            if count<len(old) {old[count]=p;count+=1}
            break
        }
    }
    return
}

// The portals of a build from the crossings of the border of its region:
// crossings toward the same region within `merge` are one portal, and the old
// portals come back when no new one faces their region near them.
@(private)
coarse_build_portals :: proc(b:^Nav_Coarse_Build,found:[]Nav_Crossing,old:[]Nav_Portal,ways:Coarse_Ways,merge:f32=NAV_PORTAL_MERGE) {
    key:=b.key
    // Near crossings toward the same region are one portal: the crossing nearest the middle of them.
    slice.sort_by(found,proc(a,b:Nav_Crossing) -> bool {
        if a.outside!=b.outside {return a.outside<b.outside}
        if a.point.x!=b.point.x {return a.point.x<b.point.x}
        if a.point.z!=b.point.z {return a.point.z<b.point.z}
        return a.point.y<b.point.y
    })
    taken:[NAV_REGION_CROSSINGS]bool
    for seed,i in found {
        if taken[i] {continue}
        if b.count==NAV_REGION_PORTALS {b.complete=false;break}
        middle:math.Vec3
        members:=0
        for j in i..<len(found) {
            if found[j].outside!=seed.outside || found[j].point.x-seed.point.x>merge {break}
            if taken[j] || linalg.length(found[j].point-seed.point)>merge {continue}
            middle+=found[j].point
            members+=1
        }
        middle/=f32(members)
        best,nearest:=f32(max(f32)),i
        for j in i..<len(found) {
            if found[j].outside!=seed.outside || found[j].point.x-seed.point.x>merge {break}
            if taken[j] || linalg.length(found[j].point-seed.point)>merge {continue}
            taken[j]=true
            if d:=linalg.length2(found[j].point-middle);d<best {best,nearest=d,j}
        }
        b.portals[b.count]={position=found[nearest].point,region=key,outside=seed.outside,twin=-1}
        b.count+=1
    }
    fresh:=b.count
    for p in old {
        again:=false
        for m in b.portals[:fresh] {if m.outside==p.outside && linalg.length(m.position-p.position)<=merge {again=true;break}}
        if again {continue}
        if b.count==NAV_REGION_PORTALS {b.complete=false;break}
        b.portals[b.count]={position=p.position,region=key,outside=p.outside,twin=-1}
        b.count+=1
    }
    for p in 0..<b.count {
        b.refs[p],b.at[p],_=ways.snap(ways.user,b.portals[p].position,p>=fresh)
        // A portal found now is where the surface is; one kept stays where the region beyond has it.
        if p<fresh {b.portals[p].position=b.at[p]}
    }
}

// Searches the ways between the portals of a build, once each pair: the
// other way is the same, turned around. When every way is searched, puts the
// region in the graph.
@(private)
coarse_build_step :: proc(b:^Nav_Coarse_Build,c:^Nav_Coarse,ways:Coarse_Ways,budget:int) -> Nav_Coarse_Status {
    left:=budget
    for b.from<b.count-1 {
        if b.to>=b.count {b.from+=1;b.to=b.from+1;continue}
        from,to:=b.from,b.to
        if !b.searching {
            if b.refs[from]==0 || b.refs[to]==0 || !ways.begin(ways.user,b.at[from],b.at[to],b.refs[from],b.refs[to]) {b.to+=1;continue}
            b.searching=true
        }
        if left<=0 {return .Running}
        status,expanded:=ways.step(ways.user,left)
        left-=max(expanded,1)
        if status==.Running {return .Running}
        b.searching=false
        b.to+=1
        turns:[512]math.Vec3
        turned:=ways.finish(ways.user,b.at[from],b.at[to],turns[:])
        if turned<2 {continue}
        // Its inner corners: those of the way, and where a kept portal meets what the region is made from.
        start,end:=b.portals[from].position,b.portals[to].position
        inner:=turns[:turned]
        if inner[len(inner)-1]==end {inner=inner[:len(inner)-1]}
        // Its length from portal to portal, and at most NAV_COARSE_CORNERS of its inner corners, spread along it.
        way:=Coarse_Way{corner_first=u32(len(b.corners)),found=true}
        previous:=start
        for corner in inner {way.length+=linalg.length(corner-previous);previous=corner}
        way.length+=linalg.length(end-previous)
        if len(inner)>0 && inner[0]==start {inner=inner[1:]}
        kept:=min(len(inner),NAV_COARSE_CORNERS)
        for k in 0..<kept {
            pick:=k*len(inner)/kept if kept<len(inner) else k
            if _,e:=append(&b.corners,inner[pick]);e!=nil {nav_coarse_remove(c,b.key);return .Failed}
        }
        way.corner_count=u32(kept)
        b.ways[from][to]=way
    }
    return coarse_build_finish(b,c)
}

// Puts the region of a build in the graph, in place of the one it had.
@(private)
coarse_build_finish :: proc(b:^Nav_Coarse_Build,c:^Nav_Coarse) -> Nav_Coarse_Status {
    nav_coarse_remove(c,b.key)
    portals_before,edges_before,corners_before:=len(c.portals),len(c.edges),len(c.corners)
    region:=Nav_Coarse_Region{key=b.key,hash=b.hash,portal_first=u32(portals_before),edge_first=u32(edges_before),corner_first=u32(corners_before)}
    made:=b.portals
    failed:=false
    fill: for p in 0..<b.count {
        made[p].edge_first=u32(len(c.edges))
        for other in 0..<b.count {
            way:=b.ways[min(p,other)][max(p,other)]
            if other==p || !way.found {continue}
            edge:=Nav_Coarse_Edge{to=u32(portals_before+other),length=way.length,corner_first=u32(len(c.corners)),corner_count=way.corner_count}
            corners:=b.corners[way.corner_first:][:way.corner_count]
            for k in 0..<len(corners) {
                corner:=corners[k] if p<other else corners[len(corners)-1-k]
                if _,e:=append(&c.corners,corner);e!=nil {failed=true;break fill}
            }
            if _,e:=append(&c.edges,edge);e!=nil {failed=true;break fill}
        }
        made[p].edge_count=u32(len(c.edges))-made[p].edge_first
    }
    if !failed {
        _,e:=append(&c.portals,..made[:b.count])
        failed=e!=nil
    }
    if !failed {
        region.portal_count=u32(b.count)
        region.edge_count=u32(len(c.edges)-edges_before)
        region.corner_count=u32(len(c.corners)-corners_before)
        _,e:=append(&c.regions,region)
        failed=e!=nil
    }
    if failed {base.truncate(&c.portals,portals_before);base.truncate(&c.edges,edges_before);base.truncate(&c.corners,corners_before)}
    nav_coarse_twins(c)
    return .Failed if failed else .Done
}

// Starts making again the part of a region of the graph from a volume, as
// nav_coarse_begin_region does from a mesh: the crossings of the border of
// `box` are where its free space goes on beyond it, at the middle of where
// each free node or voxel meets a face of the box, found by the steps of
// nav_coarse_step_region_volume a zone at a time, and the ways between the
// portals are the paths through the free space, pulled tight. A transaction:
// it allocates.
nav_coarse_begin_region_volume :: proc(b:^Nav_Coarse_Build,c:^Nav_Coarse,volume:^Nav_Volume,key,hash:u64,box:math.Aabb,kept:[]u64={}) -> bool {
    old,old_count:=coarse_kept(c,key,kept)
    if key==0 || volume==nil || len(volume.zones)==0 || !(volume.voxel>0) || !nav_point_finite(box.min) || !nav_point_finite(box.max) || !(box.min.x<=box.max.x && box.min.y<=box.max.y && box.min.z<=box.max.z) {
        nav_coarse_remove(c,key)
        return false
    }
    grown:=math.Aabb{box.min-volume.voxel,box.max+volume.voxel}
    low,high:=nav_volume_coord(volume,grown.min),nav_volume_coord(volume,grown.max)
    if i64(high.x-low.x+1)*i64(high.y-low.y+1)*i64(high.z-low.z+1)>1<<16 || !coarse_build_reset(b,key,hash) {
        nav_coarse_remove(c,key)
        return false
    }
    b.scanning,b.scan,b.scan_low,b.scan_high,b.box=true,low,low,high,box
    // A face of free space is crossed anywhere: a few portals across it, not one every NAV_PORTAL_MERGE.
    size:=box.max-box.min
    b.merge=max(NAV_PORTAL_MERGE,max(size.x,size.y,size.z)*0.5)
    copy(b.kept[:],old[:old_count])
    b.kept_count=old_count
    return true
}

// Advances a build begun by nav_coarse_begin_region_volume, given the volume
// it began with: a step scans the next zone along the border of the box
// (`region_of` tells the region beyond a crossing), or searches ways that
// expand about `budget` cells.
nav_coarse_step_region_volume :: proc(b:^Nav_Coarse_Build,c:^Nav_Coarse,volume:^Nav_Volume,q:^Nav_Volume_Query,region_of:Nav_Region_Of,user:rawptr,budget:int) -> Nav_Coarse_Status {
    ways:=Volume_Ways{volume,q}
    if b.scanning {
        coarse_volume_scan(b,volume,region_of,user)
        if !b.scanning {coarse_build_portals(b,b.crossings[:b.crossing_count],b.kept[:b.kept_count],coarse_volume_ways(&ways),b.merge)}
        return .Running
    }
    return coarse_build_step(b,c,coarse_volume_ways(&ways),budget)
}

// The crossings of the border of the box of a build in the next zone it
// scans, by coordinate, cells in order: the same volume gives the same crossings.
@(private)
coarse_volume_scan :: proc(b:^Nav_Coarse_Build,volume:^Nav_Volume,region_of:Nav_Region_Of,user:rawptr) {
    box:=b.box
    grown:=math.Aabb{box.min-volume.voxel,box.max+volume.voxel}
    Item :: struct {layer:int,index:u32,cell:[3]i32}
    stack:[8*NAV_VOLUME_MAX_LAYERS+8]Item
    for b.scanning {
        zone:=nav_volume_zone_at(volume,b.scan)
        b.scan.x+=1
        if b.scan.x>b.scan_high.x {b.scan.x=b.scan_low.x;b.scan.y+=1}
        if b.scan.y>b.scan_high.y {b.scan.y=b.scan_low.y;b.scan.z+=1}
        if b.scan.z>b.scan_high.z {b.scanning=false}
        if zone==nil || region_of==nil {continue}
        data:=&zone.data
        top:=1
        stack[0]={int(data.layers),0,{}}
        for top>0 {
            top-=1
            item:=stack[top]
            node:=data.nodes[int(data.first[item.layer])+int(item.index)]
            if node.cell==.Blocked {continue}
            cell_box:=nav_volume_cell_box(volume,data.coord,item.layer,item.cell)
            // Only a cell a face of the box goes through meets the border: those within it are passed by.
            if !math.aabb_overlaps(cell_box,grown) || !coarse_cell_on_border(cell_box,box) {continue}
            if node.cell==.Free {
                coarse_volume_crossings(volume,cell_box,box,b.key,region_of,user,b.crossings[:],&b.crossing_count,&b.complete)
                continue
            }
            if item.layer==0 {
                bits:=data.voxels[node.children]
                for i in u32(0)..<64 {
                    local:=[3]i32{i32(i&3),i32((i>>2)&3),i32(i>>4)}
                    if bits&(u64(1)<<nav_volume_voxel_bit(local))!=0 {continue}
                    voxel:=nav_volume_cell_box(volume,data.coord,-1,nav_volume_shl(item.cell,2)+local)
                    coarse_volume_crossings(volume,voxel,box,b.key,region_of,user,b.crossings[:],&b.crossing_count,&b.complete)
                }
                continue
            }
            for o in u32(0)..<8 {
                stack[top]={item.layer-1,node.children+o,nav_volume_shl(item.cell,1)+[3]i32{i32(o&1),i32((o>>1)&1),i32((o>>2)&1)}}
                top+=1
            }
        }
        return
    }
}

// Makes again the part of a region of the graph from a volume at once, as
// nav_coarse_build_region does from a mesh.
nav_coarse_build_region_volume :: proc(c:^Nav_Coarse,volume:^Nav_Volume,q:^Nav_Volume_Query,key,hash:u64,box:math.Aabb,region_of:Nav_Region_Of,user:rawptr,kept:[]u64={}) -> (portals:int,complete,ok:bool) {
    if q==nil || len(q.points)==0 {nav_coarse_remove(c,key);return}
    b:Nav_Coarse_Build
    defer nav_coarse_build_destroy(&b)
    if region_of==nil {nav_coarse_remove(c,key);return}
    if !nav_coarse_begin_region_volume(&b,c,volume,key,hash,box,kept) {return}
    status:=Nav_Coarse_Status.Running
    for status==.Running {status=nav_coarse_step_region_volume(&b,c,volume,q,region_of,user,max(int))}
    if status!=.Done {return}
    return b.count,b.complete,true
}

@(private)
Volume_Ways :: struct {volume:^Nav_Volume,q:^Nav_Volume_Query}

@(private)
coarse_volume_ways :: proc(w:^Volume_Ways) -> Coarse_Ways {
    snap :: proc(user:rawptr,point:math.Vec3,far:bool) -> (ref:Nav_Ref,at:math.Vec3,ok:bool) {
        w:=(^Volume_Ways)(user)
        reach:=f32(NAV_PORTAL_MERGE*0.5) if far else w.volume.voxel*2
        return nav_volume_find_nearest(w.volume,point,{reach,reach,reach})
    }
    begin :: proc(user:rawptr,a,b:math.Vec3,from,to:Nav_Ref) -> bool {
        w:=(^Volume_Ways)(user)
        return w.q!=nil && nav_volume_path_begin(w.q,w.volume,from,to,a,b)!=.Invalid
    }
    step :: proc(user:rawptr,budget:int) -> (status:Search_Status,expanded:int) {
        w:=(^Volume_Ways)(user)
        before:=w.q.search.stats.expanded
        status=nav_volume_path_step(w.q,budget)
        return status,w.q.search.stats.expanded-before
    }
    finish :: proc(user:rawptr,a,b:math.Vec3,out:[]math.Vec3) -> int {
        w:=(^Volume_Ways)(user)
        path:=transmute([]Nav_Ref)w.q.search.channel
        n,status,partial:=nav_volume_path_finish(w.q,path)
        if status!=.Found || partial || n==0 {return 0}
        count,_:=nav_volume_straight_path(w.volume,a,b,path[:n],out)
        return count
    }
    return {w,snap,begin,step,finish}
}

// Whether a plane of a face of a box goes through a cell.
@(private)
coarse_cell_on_border :: proc "contextless" (cell,box:math.Aabb) -> bool {
    for axis in 0..<3 {
        for plane in ([2]f32{box.min[axis],box.max[axis]}) {if plane>=cell.min[axis] && plane<=cell.max[axis] {return true}}
    }
    return false
}

// The crossings of the border of a box where a free cell meets one of its
// faces and the free space goes on beyond: one at the middle of where they
// meet, toward the region beyond. One near another toward the same region is
// left out: they are one portal.
@(private)
coarse_volume_crossings :: proc(volume:^Nav_Volume,cell,box:math.Aabb,key:u64,region_of:Nav_Region_Of,user:rawptr,crossings:[]Nav_Crossing,count:^int,complete:^bool) {
    step:=volume.voxel*0.5
    for axis in 0..<3 {
        a,b:=(axis+1)%3,(axis+2)%3
        if !(max(cell.min[a],box.min[a])<min(cell.max[a],box.max[a])) || !(max(cell.min[b],box.min[b])<min(cell.max[b],box.max[b])) {continue}
        for side in 0..<2 {
            plane:=box.min[axis] if side==0 else box.max[axis]
            if plane<cell.min[axis] || plane>cell.max[axis] {continue}
            point:math.Vec3
            point[axis]=plane
            point[a]=(max(cell.min[a],box.min[a])+min(cell.max[a],box.max[a]))*0.5
            point[b]=(max(cell.min[b],box.min[b])+min(cell.max[b],box.max[b]))*0.5
            out:=f32(-1) if side==0 else 1
            inside,beyond:=point,point
            inside[axis]-=out*step
            beyond[axis]+=out*step
            if _,free:=nav_volume_find(volume,inside);!free {continue}
            if _,free:=nav_volume_find(volume,beyond);!free {continue}
            outside:=region_of(user,beyond)
            if outside==key {continue}
            near:=false
            for crossing in crossings[:count^] {
                if crossing.outside==outside && linalg.length2(crossing.point-point)<NAV_PORTAL_MERGE*NAV_PORTAL_MERGE*0.0625 {near=true;break}
            }
            if near {continue}
            if count^==len(crossings) {complete^=false;continue}
            crossings[count^]={point,outside}
            count^+=1
        }
    }
}

// The search over the portals of a graph from a point to another: its nodes
// are the portals, then the start and the goal.
@(private)
Coarse_Space :: struct {
    c:^Nav_Coarse,
    from,to:math.Vec3,
    from_region,to_region:u64,
    from_known,to_known:bool,
    start,goal:u64,
}

@(private)
coarse_position :: proc "contextless" (s:^Coarse_Space,node:u64) -> math.Vec3 {
    if node==s.start {return s.from}
    if node==s.goal {return s.to}
    return s.c.portals[node].position
}

@(private)
coarse_neighbors :: proc(s:^Coarse_Space,node:u64,edges:^Edge_List) {
    c:=s.c
    if node==s.goal {return}
    if node==s.start {
        if s.from_region==s.to_region {edge_add(edges,s.goal,linalg.length(s.to-s.from))}
        for p,i in c.portals {
            if p.region==s.from_region || !s.from_known && p.outside==s.from_region {edge_add(edges,u64(i),linalg.length(p.position-s.from))}
        }
        return
    }
    p:=c.portals[node]
    for edge in c.edges[p.edge_first:][:p.edge_count] {edge_add(edges,u64(edge.to),edge.length)}
    beyond_known:=nav_coarse_region(c,p.outside)!=nil
    switch {
    case p.twin>=0:
        edge_add(edges,u64(p.twin),linalg.length(c.portals[p.twin].position-p.position))
    case beyond_known:
        for q,j in c.portals {if q.region==p.outside {edge_add(edges,u64(j),linalg.length(q.position-p.position))}}
    case:
        // Across a region the graph does not know: straight to the other portals that face it.
        for q,j in c.portals {
            if u64(j)!=node && q.outside==p.outside {edge_add(edges,u64(j),linalg.length(q.position-p.position))}
        }
    }
    if p.region==s.to_region || !s.to_known && p.outside==s.to_region {edge_add(edges,s.goal,linalg.length(s.to-p.position))}
}

@(private)
coarse_heuristic :: proc(s:^Coarse_Space,node,goal:u64) -> f32 {return linalg.length(s.to-coarse_position(s,node))*NAV_HEURISTIC_SCALE}

// The way from a point of one region to a point of another through the
// portals of the graph: the points to walk through after `from`, the corners
// of the ways inside the regions the graph knows among them, ending at `to`.
// The search is dense and needs a node per portal and two more, and room for
// the edges of a portal (Search_Desc.max_edges): those dropped are not taken.
// Found; Output_Full with what fits when the way is longer than `out`;
// No_Path when the portals do not join the two regions; Invalid for points
// that are not finite or a search too small.
nav_coarse_route :: proc(c:^Nav_Coarse,s:^Search,from:math.Vec3,from_region:u64,to:math.Vec3,to_region:u64,out:[]math.Vec3) -> (count:int,status:Search_Status) {
    if !nav_point_finite(from) || !nav_point_finite(to) || search_keyed(s) || search_nodes(s)<len(c.portals)+2 || len(s.channel)<len(c.portals)+2 {return 0,.Invalid}
    if !nav_coarse_consistent(c) {return 0,.Invalid}
    space:=Coarse_Space{
        c=c,from=from,to=to,from_region=from_region,to_region=to_region,
        from_known=nav_coarse_region(c,from_region)!=nil,to_known=nav_coarse_region(c,to_region)!=nil,
        start=u64(len(c.portals)),goal=u64(len(c.portals)+1),
    }
    status=search_run(s,space.start,space.goal,&space,coarse_neighbors,coarse_heuristic)
    if status!=.Found {return 0,status}
    nodes,found:=search_path(s,s.channel)
    if found!=.Found {return 0,found}
    put :: proc "contextless" (out:[]math.Vec3,count:^int,point:math.Vec3) -> bool {
        if count^>0 && out[count^-1]==point {return true}
        if count^>=len(out) {return false}
        out[count^]=point
        count^+=1
        return true
    }
    for k in 1..<nodes {
        a,b:=s.channel[k-1],s.channel[k]
        if a<space.start && b<space.start {
            // The shortest way of a to b, with its corners.
            p:=c.portals[a]
            way:=-1
            for edge,e in c.edges[p.edge_first:][:p.edge_count] {
                if u64(edge.to)==b && (way<0 || edge.length<c.edges[int(p.edge_first)+way].length) {way=e}
            }
            if way>=0 {
                edge:=c.edges[int(p.edge_first)+way]
                for corner in c.corners[edge.corner_first:][:edge.corner_count] {
                    if !put(out,&count,corner) {return count,.Output_Full}
                }
            }
        }
        if !put(out,&count,coarse_position(&space,b)) {return count,.Output_Full}
    }
    return count,.Found
}
