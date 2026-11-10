package ai

import "base:runtime"
import "core:math/linalg"
import math "mirai:std/math"

// Queries over a Nav_Volume. Paths are found with the same keyed A* as over
// a mesh, from node to node and voxel to voxel across their faces: a node
// leads to the face neighbor of its size, or to the bigger node that holds
// it, or to every free cell of a split neighbor that touches the face. A
// path is followed toward the farthest of its next portals in sight
// (nav_volume_corridor_steer), so the steps of the octree do not show.

NAV_VOLUME_EDGES :: 512
// The heuristic weighs twice the distance left: in front of a wall the search
// spreads over the voxels of its face, and a heavier heuristic reaches the
// way around with a third of the cells, for a path a few percent longer
// once pulled tight.
NAV_VOLUME_HEURISTIC_SCALE :: f32(2)
NAV_VOLUME_RAY_STEPS :: 4096 // cells a ray crosses before it gives up

Nav_Volume_Query :: struct {
    search:Search,
    points:[]math.Vec3,                        // where the path enters each cell
    candidates:[NAV_VOLUME_EDGES]math.Vec3,
    accepted:math.Vec3,
    volume:^Nav_Volume,
    start,end:math.Vec3,
    start_ref,end_ref:Nav_Ref,
    allocator:runtime.Allocator,
}

nav_volume_query_init :: proc(q:^Nav_Volume_Query,nodes:int,allocator:=context.allocator) -> bool {
    q^={allocator=allocator}
    if nodes<=0 || nodes>1<<24 {return false}
    if !search_init(&q.search,{nodes=nodes,keyed=true,max_edges=NAV_VOLUME_EDGES,allocator=allocator}) {return false}
    points,error:=make([]math.Vec3,nodes,allocator)
    if error!=nil {search_destroy(&q.search);return false}
    q.points=points
    return true
}
nav_volume_query_destroy :: proc(q:^Nav_Volume_Query) {
    if q.allocator.procedure!=nil {delete(q.points,q.allocator)}
    search_destroy(&q.search)
    q^={}
}

@(private)
NAV_VOLUME_DIRECTIONS :: [6][3]i32{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}

// Where a path from `p` toward `end` enters a box through its face that looks
// back along `axis`: where the line crosses that face, held inside it.
@(private)
nav_volume_entry :: proc "contextless" (p,end:math.Vec3,face:math.Aabb) -> math.Vec3 {
    entry:=p
    for axis in 0..<3 {
        if face.min[axis]!=face.max[axis] {continue}
        d:=end[axis]-p[axis]
        if abs(d)>1e-12 {
            t:=clamp((face.min[axis]-p[axis])/d,0,1)
            entry=p+(end-p)*t
        }
        break
    }
    return linalg.clamp(entry,face.min,face.max)
}

// The face two touching boxes share; empty on every axis but one when they touch.
@(private)
nav_volume_face :: proc "contextless" (a,b:math.Aabb) -> math.Aabb {
    return {linalg.max(a.min,b.min),linalg.min(a.max,b.max)}
}

@(private)
nav_volume_space_edge :: proc "contextless" (q:^Nav_Volume_Query,edges:^Edge_List,from:math.Vec3,from_box:math.Aabb,zone:^Nav_Volume_Zone,slot:u32,layer:int,cell:[3]i32) {
    if edges.count>=len(q.candidates) {edges.dropped+=1;return}
    to:=nav_volume_ref(zone.salt,slot,layer,cell)
    box:=nav_volume_cell_box(q.volume,zone.data.coord,layer,cell)
    entry:=nav_volume_entry(from,q.end,nav_volume_face(from_box,box))
    cost:=linalg.distance(from,entry)
    if to==q.end_ref {cost+=linalg.distance(entry,q.end)}
    q.candidates[edges.count]=entry
    edge_add(edges,u64(to),cost,u32(edges.count))
}

// Every free cell of a node, or of its children, that touches its face on
// `axis`: the low face when `low`.
@(private)
nav_volume_space_face :: proc "contextless" (q:^Nav_Volume_Query,edges:^Edge_List,from:math.Vec3,from_box:math.Aabb,zone:^Nav_Volume_Zone,slot:u32,layer:int,index:u32,cell:[3]i32,axis:int,low:bool) {
    data:=&zone.data
    node:=data.nodes[int(data.first[layer])+int(index)]
    switch node.cell {
    case .Blocked:
    case .Free:
        nav_volume_space_edge(q,edges,from,from_box,zone,slot,layer,cell)
    case .Mixed:
        if layer==0 {
            bits:=data.voxels[node.children]
            for i in 0..<16 {
                local:[3]i32
                local[axis]=0 if low else 3
                local[(axis+1)%3]=i32(i&3)
                local[(axis+2)%3]=i32(i>>2)
                if bits&(u64(1)<<nav_volume_voxel_bit(local))!=0 {continue}
                nav_volume_space_edge(q,edges,from,from_box,zone,slot,-1,nav_volume_shl(cell,2)+local)
            }
            return
        }
        for o in u32(0)..<8 {
            if (o>>uint(axis))&1!=(0 if low else 1) {continue}
            child:=nav_volume_shl(cell,1)+[3]i32{i32(o&1),i32((o>>1)&1),i32((o>>2)&1)}
            nav_volume_space_face(q,edges,from,from_box,zone,slot,layer-1,node.children+o,child,axis,low)
        }
    }
}

@(private)
nav_volume_space_neighbors :: proc(q:^Nav_Volume_Query,key:u64,edges:^Edge_List) {
    ref:=Nav_Ref(key)
    zone:=nav_volume_zone_of(q.volume,ref)
    if zone==nil {return}
    at,ok:=search_find(&q.search,key)
    if !ok {return}
    from:=q.points[at]
    layer,cell:=nav_volume_ref_layer(ref),nav_volume_ref_cell(ref)
    from_box:=nav_volume_cell_box(q.volume,zone.data.coord,layer,cell)
    size:=i32(1) if layer<0 else i32(NAV_VOLUME_BLOCK)<<uint(layer)
    n:=i32(NAV_VOLUME_BLOCK)<<q.volume.layers
    low_voxel:=cell if layer<0 else nav_volume_shl(cell,uint(2+layer))
    directions:=NAV_VOLUME_DIRECTIONS
    for d,k in directions {
        axis:=k/2
        voxel:=low_voxel+d*size
        coord:=zone.data.coord
        if voxel[axis]<0 {voxel[axis]+=n;coord[axis]-=1} else if voxel[axis]>=n {voxel[axis]-=n;coord[axis]+=1}
        other:=zone if coord==zone.data.coord else nav_volume_zone_at(q.volume,coord)
        if other==nil {continue}
        slot:=nav_volume_zone_slot(q.volume,other)
        found,found_cell,state,index:=nav_volume_descend(&other.data,voxel,layer)
        switch state {
        case .Blocked:
        case .Free:
            nav_volume_space_edge(q,edges,from,from_box,other,slot,found,found_cell)
        case .Mixed:
            nav_volume_space_face(q,edges,from,from_box,other,slot,found,index,found_cell,axis,d[axis]>0)
        }
    }
}
@(private)
nav_volume_space_heuristic :: proc(q:^Nav_Volume_Query,key,goal:u64) -> f32 {return linalg.distance(q.accepted,q.end)*NAV_VOLUME_HEURISTIC_SCALE}
@(private)
nav_volume_space_accept :: proc(q:^Nav_Volume_Query,slot:u32,edge:Edge) {
    q.points[slot]=q.candidates[edge.data]
    q.accepted=q.points[slot]
}

// Starts a search for a path from `start` in the cell start_ref to `end` in
// end_ref; nav_volume_path_step advances it and nav_volume_path_finish reads
// it. Zones may change between steps: cells that stop being valid lead
// nowhere, and the finished path is checked again.
nav_volume_path_begin :: proc(q:^Nav_Volume_Query,volume:^Nav_Volume,start_ref,end_ref:Nav_Ref,start,end:math.Vec3) -> Search_Status {
    q.volume=nil
    if len(q.points)==0 || volume==nil || !nav_point_finite(start) || !nav_point_finite(end) {return .Invalid}
    if !nav_volume_ref_valid(volume,start_ref) || !nav_volume_ref_valid(volume,end_ref) {return .Invalid}
    q.volume=volume
    q.start,q.end,q.start_ref,q.end_ref=start,end,start_ref,end_ref
    q.accepted=start
    status:=search_begin(&q.search,u64(start_ref),u64(end_ref),q,nav_volume_space_heuristic)
    if slot,ok:=search_find(&q.search,u64(start_ref));ok {q.points[slot]=start}
    return status
}
nav_volume_path_step :: proc(q:^Nav_Volume_Query,budget:int) -> Search_Status {
    if q.volume==nil {return .Invalid}
    return search_step(&q.search,q,nav_volume_space_neighbors,nav_volume_space_heuristic,nav_volume_space_accept,budget)
}
// Writes the cells of the finished search. Without a way to the end, the
// path to the reached cell nearest to it, with `partial`. Invalid when a cell
// of it stopped being valid while the search ran.
nav_volume_path_finish :: proc(q:^Nav_Volume_Query,out:[]Nav_Ref) -> (count:int,status:Search_Status,partial:bool) {
    if q.volume==nil {return 0,.Invalid,false}
    count,status,partial=nav_search_finish(&q.search,q.points,q.end,out)
    for ref in out[:count] {
        if !nav_volume_ref_valid(q.volume,ref) {return 0,.Invalid,false}
    }
    return
}
nav_volume_find_path :: proc(q:^Nav_Volume_Query,volume:^Nav_Volume,start_ref,end_ref:Nav_Ref,start,end:math.Vec3,out:[]Nav_Ref) -> (count:int,status:Search_Status,partial:bool) {
    status=nav_volume_path_begin(q,volume,start_ref,end_ref,start,end)
    if status==.Invalid {return 0,.Invalid,false}
    nav_volume_path_step(q,max(int))
    return nav_volume_path_finish(q,out)
}

// The free cell nearest to a point within `extents` of it on each axis, and
// the nearest point of that cell.
nav_volume_find_nearest :: proc "contextless" (volume:^Nav_Volume,point,extents:math.Vec3) -> (ref:Nav_Ref,nearest:math.Vec3,ok:bool) {
    if !nav_point_finite(point) || !nav_point_finite(extents) {return}
    if found,inside:=nav_volume_find(volume,point);inside {return found,point,true}
    query:=math.Aabb{point-linalg.abs(extents),point+linalg.abs(extents)}
    low,high:=nav_volume_coord(volume,query.min),nav_volume_coord(volume,query.max)
    if i64(high.x-low.x+1)*i64(high.y-low.y+1)*i64(high.z-low.z+1)>4096 {return}
    best:=f32(max(f32))
    Item :: struct {layer:int,index:u32,cell:[3]i32}
    stack:[8*NAV_VOLUME_MAX_LAYERS+8]Item
    for z in low.z..=high.z {
        for y in low.y..=high.y {
            for x in low.x..=high.x {
                zone:=nav_volume_zone_at(volume,{x,y,z})
                if zone==nil {continue}
                data:=&zone.data
                top:=1
                stack[0]={int(data.layers),0,{}}
                for top>0 {
                    top-=1
                    item:=stack[top]
                    node:=data.nodes[int(data.first[item.layer])+int(item.index)]
                    if node.cell==.Blocked {continue}
                    box:=nav_volume_cell_box(volume,data.coord,item.layer,item.cell)
                    if !math.aabb_overlaps(box,query) || linalg.length2(linalg.clamp(point,box.min,box.max)-point)>=best {continue}
                    if node.cell==.Free {
                        nav_volume_nearest_take(volume,zone,item.layer,item.cell,point,&best,&ref,&nearest)
                        continue
                    }
                    if item.layer==0 {
                        bits:=data.voxels[node.children]
                        for i in u32(0)..<64 {
                            local:=[3]i32{i32(i&3),i32((i>>2)&3),i32(i>>4)}
                            if bits&(u64(1)<<nav_volume_voxel_bit(local))!=0 {continue}
                            nav_volume_nearest_take(volume,zone,-1,nav_volume_shl(item.cell,2)+local,point,&best,&ref,&nearest)
                        }
                        continue
                    }
                    for o in u32(0)..<8 {
                        stack[top]={item.layer-1,node.children+o,nav_volume_shl(item.cell,1)+[3]i32{i32(o&1),i32((o>>1)&1),i32((o>>2)&1)}}
                        top+=1
                    }
                }
            }
        }
    }
    if ref==0 || !math.aabb_contains_point(query,nearest) {return 0,{},false}
    return ref,nearest,true
}

@(private)
nav_volume_nearest_take :: proc "contextless" (volume:^Nav_Volume,zone:^Nav_Volume_Zone,layer:int,cell:[3]i32,point:math.Vec3,best:^f32,ref:^Nav_Ref,nearest:^math.Vec3) {
    box:=nav_volume_cell_box(volume,zone.data.coord,layer,cell)
    // Just inside, so that the point finds the cell again.
    inset:=volume.voxel*1e-3
    p:=linalg.clamp(point,box.min+inset,box.max-inset)
    d:=linalg.length2(p-point)
    if d>=best^ {return}
    best^=d
    ref^=nav_volume_ref(zone.salt,nav_volume_zone_slot(volume,zone),layer,cell)
    nearest^=p
}

// Whether the segment from `from` to `to` crosses only free cells; when not,
// the share of it before the first cell that is not.
nav_volume_raycast :: proc "contextless" (volume:^Nav_Volume,from,to:math.Vec3) -> (clear:bool,t:f32) {
    if !nav_point_finite(from) || !nav_point_finite(to) || !(volume.voxel>0) {return false,0}
    d:=to-from
    length:=linalg.length(d)
    step:=volume.voxel*1e-3/max(length,1e-6)
    for _ in 0..<NAV_VOLUME_RAY_STEPS {
        p:=from+d*min(t,1)
        coord:=nav_volume_coord(volume,p)
        zone:=nav_volume_zone_at(volume,coord)
        if zone==nil {return false,t}
        voxel,_:=nav_volume_voxel_at(volume,coord,p)
        layer,cell,state,_:=nav_volume_descend(&zone.data,voxel)
        if state!=.Free {return false,t}
        if t>=1 {return true,1}
        box:=nav_volume_cell_box(volume,coord,layer,cell)
        leave:=f32(max(f32))
        for axis in 0..<3 {
            if d[axis]>0 {leave=min(leave,(box.max[axis]-from[axis])/d[axis])}
            if d[axis]<0 {leave=min(leave,(box.min[axis]-from[axis])/d[axis])}
        }
        if leave>=1 {return true,1}
        t=max(leave,t)+step
    }
    return false,t
}

// A free point at random within `radius` of a center, tried a few times.
nav_volume_random_point_around :: proc(volume:^Nav_Volume,center:math.Vec3,radius:f32,rng:^math.Rng) -> (ref:Nav_Ref,point:math.Vec3,ok:bool) {
    if rng==nil || !nav_point_finite(center) || !(radius>=0) {return}
    for _ in 0..<32 {
        offset:=math.Vec3{math.random_f32(rng),math.random_f32(rng),math.random_f32(rng)}*2-1
        if linalg.length2(offset)>1 {continue}
        p:=center+offset*radius
        if found,inside:=nav_volume_find(volume,p);inside {return found,p,true}
    }
    return
}

// The point to pass from one cell of a path to the next: the center of the
// face they share.
nav_volume_portal :: proc "contextless" (volume:^Nav_Volume,from,to:Nav_Ref) -> (point:math.Vec3,ok:bool) {
    a,valid_a:=nav_volume_ref_box(volume,from)
    b,valid_b:=nav_volume_ref_box(volume,to)
    if !valid_a || !valid_b {return}
    face:=nav_volume_face(a,b)
    slack:=volume.voxel*1e-3
    for axis in 0..<3 {if face.min[axis]>face.max[axis]+slack {return}}
    return (face.min+face.max)*0.5,true
}

// Takes a path of cells that starts where the agent is. When it does not fit,
// its first part, with the target at the center of the last cell kept.
nav_volume_corridor_set :: proc "contextless" (c:^Nav_Corridor,volume:^Nav_Volume,target:math.Vec3,path:[]Nav_Ref) -> bool {
    if len(path)==0 || !nav_volume_ref_valid(volume,path[0]) {return false}
    count:=min(len(path),NAV_CORRIDOR_CAPACITY)
    copy(c.path[:count],path[:count])
    c.count=i32(count)
    c.target=target
    if count<len(path) {
        box,_:=nav_volume_ref_box(volume,c.path[count-1])
        c.target=math.aabb_center(box)
    }
    return true
}

// The point an agent at `position` heads for: the farthest of the next
// `ahead` portals of its corridor, or its target, that it sees in a straight
// line; the cells before it are dropped. `end` when that is the target. An
// agent pushed out of the free space heads back into the first cell. Not ok
// when a cell stopped being valid or none of them is in sight: plan again.
nav_volume_corridor_steer :: proc "contextless" (c:^Nav_Corridor,volume:^Nav_Volume,position:math.Vec3,ahead:int) -> (point:math.Vec3,end,ok:bool) {
    count:=int(clamp(c.count,0,NAV_CORRIDOR_CAPACITY))
    if count==0 {return}
    c.position=position
    last:=min(count-1,max(ahead,1))
    for i in 0..=last {if !nav_volume_ref_valid(volume,c.path[i]) {return}}
    here,inside:=nav_volume_find(volume,position)
    if !inside {
        box,_:=nav_volume_ref_box(volume,c.path[0])
        inset:=min(volume.voxel*0.25,(box.max.x-box.min.x)*0.25)
        return linalg.clamp(position,box.min+inset,box.max-inset),false,true
    }
    // Already in a cell further on: the portals behind it are passed.
    for k in 1..=last {
        if c.path[k]!=here {continue}
        copy(c.path[:count-k],c.path[k:count])
        count-=k
        c.count=i32(count)
        last=min(count-1,max(ahead,1))
        break
    }
    for j:=last;j>=0;j-=1 {
        target:=c.target
        if j<count-1 {
            portal,adjacent:=nav_volume_portal(volume,c.path[j],c.path[j+1])
            if !adjacent {return}
            target=portal
        }
        seen,_:=nav_volume_raycast(volume,position,target)
        if !seen {continue}
        if j>0 {
            copy(c.path[:count-j],c.path[j:count])
            c.count=i32(count-j)
        }
        return target,j==count-1,true
    }
    return
}

NAV_VOLUME_PULL_AHEAD :: 32 // portals a pulled path looks for ahead of each corner

// The corners of a path of cells pulled tight: from `start`, the farthest
// portal of the path, or `end`, in a straight line, and again from there.
// Writes as many as fit; `complete` when the end did.
nav_volume_straight_path :: proc "contextless" (volume:^Nav_Volume,start,end:math.Vec3,path:[]Nav_Ref,out:[]math.Vec3) -> (count:int,complete:bool) {
    if len(out)==0 || len(path)==0 || !nav_point_finite(start) || !nav_point_finite(end) {return}
    out[0]=start
    count=1
    from:=start
    last:=len(path)-1
    for i:=0;i<=last; {
        chosen:=i
        point:=end
        for j:=min(last,i+NAV_VOLUME_PULL_AHEAD);j>=i;j-=1 {
            p:=end
            if j<last {
                portal,adjacent:=nav_volume_portal(volume,path[j],path[j+1])
                if !adjacent {return}
                p=portal
            }
            // The next portal is always in sight: the cell between is a box.
            seen:=j==i
            if !seen {seen,_=nav_volume_raycast(volume,from,p)}
            if seen {chosen,point=j,p;break}
        }
        if count>=len(out) {return}
        out[count]=point
        count+=1
        from=point
        i=chosen+1
    }
    return count,true
}
