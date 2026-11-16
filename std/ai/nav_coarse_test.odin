package ai

import "base:runtime"
import "core:math/linalg"
import "core:mem"
import "core:testing"
import math "mirai:std/math"

// Regions of TEST_TILE along x: region k+1 holds x in [k*TEST_TILE, (k+1)*TEST_TILE).
@(private="file")
region_by_tile :: proc(user:rawptr,point:math.Vec3) -> u64 {
    if point.x<0 {return 0}
    return u64(point.x/TEST_TILE)+1
}

@(private="file")
region_box :: proc(key:u64) -> math.Aabb {
    x:=f32(key-1)*TEST_TILE
    return {{x,-1,0},{x+TEST_TILE,1,TEST_TILE}}
}

// A row of tiles of 4 x 4 unit cells along x.
@(private="file")
row_mesh :: proc(t:^testing.T,mesh:^Nav_Mesh,tiles:int) {
    test_mesh(t,mesh)
    for x in 0..<tiles {testing.expect(t,nav_mesh_add_tile(mesh,cell_tile(t,{i32(x),0},4,4)))}
}

@(test)
the_border_of_a_region_gives_a_portal_toward_each_region_beyond_and_the_way_between_them :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    row_mesh(t,&mesh,3)
    defer nav_mesh_destroy(&mesh)
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,1024))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Coarse
    defer nav_coarse_destroy(&c)
    count,complete,ok:=nav_coarse_build_region(&c,&mesh,&q,&filter,2,7,region_box(2),region_by_tile,nil)
    testing.expect(t,ok && complete)
    testing.expect_value(t,count,2)
    region:=nav_coarse_region(&c,2)
    testing.expect(t,region!=nil && region.hash==7 && region.portal_count==2 && region.edge_count==2)
    outside:[2]u64
    for p,i in c.portals {
        outside[i]=p.outside
        testing.expect(t,p.region==2 && p.edge_count==1 && p.twin==-1)
        // On the border it crosses.
        border:=f32(4) if p.outside==1 else 8
        testing.expectf(t,abs(p.position.x-border)<0.6,"a portal toward %d at %v",p.outside,p.position)
        edge:=c.edges[p.edge_first]
        testing.expect(t,edge.length>=3.9 && edge.length<5)
    }
    testing.expect(t,outside=={1,3} || outside=={3,1})
    // Made again from the same mesh, it is the same.
    count,_,ok=nav_coarse_build_region(&c,&mesh,&q,&filter,2,8,region_box(2),region_by_tile,nil)
    testing.expect(t,ok && count==2 && len(c.regions)==1 && len(c.portals)==2 && len(c.edges)==2 && nav_coarse_region(&c,2).hash==8)
    // A region with no surface across its border has no portals; outside every tile, no surface at all.
    count,_,ok=nav_coarse_build_region(&c,&mesh,&q,&filter,9,1,{{100,-1,0},{104,1,4}},region_by_tile,nil)
    testing.expect(t,ok && count==0 && nav_coarse_region(&c,9)!=nil)
    _,_,ok=nav_coarse_build_region(&c,&mesh,&q,&filter,0,1,region_box(1),region_by_tile,nil)
    testing.expect(t,!ok)
}

// Four regions along x; the third is not made: the way crosses it straight
// between the portals of the second and the fourth that face it.
@(test)
a_coarse_route_goes_through_the_portals_of_the_regions_between :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    row_mesh(t,&mesh,4)
    defer nav_mesh_destroy(&mesh)
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,1024))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Coarse
    defer nav_coarse_destroy(&c)
    for key in ([3]u64{1,2,4}) {
        _,_,ok:=nav_coarse_build_region(&c,&mesh,&q,&filter,key,key,region_box(key),region_by_tile,nil)
        testing.expect(t,ok)
    }
    // The portals of the first and the second toward each other are twins.
    twins:=0
    for p in c.portals {if p.twin>=0 {twins+=1;testing.expect(t,c.portals[p.twin].twin>=0)}}
    testing.expect_value(t,twins,2)
    s:Search
    testing.expect(t,search_init(&s,{nodes=64,max_edges=64}))
    defer search_destroy(&s)
    from,to:=math.Vec3{1,0,2},math.Vec3{15,0,2}
    out:[16]math.Vec3
    count,status:=nav_coarse_route(&c,&s,from,1,to,4,out[:])
    testing.expect_value(t,status,Search_Status.Found)
    testing.expect(t,count>=4 && out[count-1]==to)
    // Through the borders at 4, 8 and 12, in order.
    crossed:[3]bool
    previous:=from
    for point in out[:count] {
        testing.expect(t,point.x>=previous.x-1e-3)
        for border,i in ([3]f32{4,8,12}) {if abs(point.x-border)<0.6 {crossed[i]=true}}
        previous=point
    }
    testing.expectf(t,crossed=={true,true,true},"crossed %v: %v",crossed,out[:count])
    // A short output holds the first points.
    short,full:=nav_coarse_route(&c,&s,from,1,to,4,out[:2])
    testing.expect(t,full==.Output_Full && short==2)
    // Within one region: straight there.
    count,status=nav_coarse_route(&c,&s,{1,0,1},1,{3,0,3},1,out[:])
    testing.expect(t,status==.Found && count==1 && out[0]==math.Vec3{3,0,3})
    // A copy routes the same; without the second region the first does not join the fourth, and merged back it does.
    copied:Nav_Coarse
    testing.expect(t,nav_coarse_copy(&copied,&c))
    defer nav_coarse_destroy(&copied)
    testing.expect(t,nav_coarse_remove(&c,2) && !nav_coarse_remove(&c,2))
    testing.expect(t,len(c.regions)==2 && nav_coarse_region(&c,2)==nil)
    _,status=nav_coarse_route(&c,&s,from,1,to,4,out[:])
    testing.expect_value(t,status,Search_Status.No_Path)
    testing.expect(t,nav_coarse_merge(&c,&copied))
    testing.expect(t,len(c.regions)==3 && len(c.portals)==len(copied.portals) && len(c.edges)==len(copied.edges))
    count,status=nav_coarse_route(&c,&s,from,1,to,4,out[:])
    testing.expect(t,status==.Found && out[count-1]==to)
    // A search smaller than the graph cannot route it.
    small:Search
    testing.expect(t,search_init(&small,{nodes=2}))
    defer search_destroy(&small)
    _,status=nav_coarse_route(&c,&small,from,1,to,4,out[:])
    testing.expect_value(t,status,Search_Status.Invalid)
}

// The way kept between two portals goes around what is between them, with its corners.
@(test)
the_way_between_two_portals_keeps_its_corners_and_its_length_over_the_surface :: proc(t:^testing.T) {
    // The region is the column x in [4, 8], entered from the west below and above a wall
    // that leaves a gap at its east end; west of it, the two sides do not join.
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    walled,below:[16]bool
    for z in 0..<4 {
        for x in 0..<4 {
            walled[z*4+x]=z<3 || x==3
            below[z*4+x]=z<3
        }
    }
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},4,4,below[:])))
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,1},4,4)))
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{1,0},4,4,walled[:])))
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{1,1},4,4)))
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,1024))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Coarse
    defer nav_coarse_destroy(&c)
    west :: proc(user:rawptr,point:math.Vec3) -> u64 {
        if point.x>=4 {return 2}
        return 1 if point.z<4 else 3
    }
    count,_,ok:=nav_coarse_build_region(&c,&mesh,&q,&filter,2,1,{{4,-1,0},{8,1,8}},west,nil)
    testing.expect(t,ok && count==2)
    for p in c.portals {
        testing.expect(t,p.edge_count==1)
        edge:=c.edges[p.edge_first]
        straight:=linalg.length(c.portals[edge.to].position-p.position)
        testing.expectf(t,edge.corner_count>=1 && edge.length>straight+2,"%v corners, %v long, straight %v",edge.corner_count,edge.length,straight)
        for corner in c.corners[edge.corner_first:][:edge.corner_count] {testing.expect(t,corner.x>=4)}
    }
}

// Regions of the volume of volume_wall along x: 1 below 6, 2 up to 10, 3 beyond.
@(private="file")
region_by_x :: proc(user:rawptr,point:math.Vec3) -> u64 {
    if point.x<6 {return 1}
    if point.x<=10 {return 2}
    return 3
}

// A region of a volume across the wall: its portals face the regions on both
// sides, and the way between them goes under the wall, through the free space.
@(test)
the_border_of_a_region_of_a_volume_gives_portals_where_its_free_space_goes_on :: proc(t:^testing.T) {
    volume:Nav_Volume
    volume_wall(t,&volume,{voxel=0.25,layers=2,half={0.3,0.3,0.3}})
    defer nav_volume_destroy(&volume)
    q:Nav_Volume_Query
    testing.expect(t,nav_volume_query_init(&q,1<<16))
    defer nav_volume_query_destroy(&q)
    c:Nav_Coarse
    defer nav_coarse_destroy(&c)
    count,complete,ok:=nav_coarse_build_region_volume(&c,&volume,&q,2,1,{{6,0,0},{10,16,16}},region_by_x,nil)
    testing.expect(t,ok && complete && count>=2)
    sides:[2]bool
    for p in c.portals {
        testing.expect(t,p.region==2 && (p.outside==1 || p.outside==3))
        testing.expectf(t,abs(p.position.x-(6 if p.outside==1 else 10))<0.6,"a portal toward %d at %v",p.outside,p.position)
        sides[0]|=p.outside==1
        sides[1]|=p.outside==3
    }
    testing.expect(t,sides=={true,true})
    // A way from one side to the other dips under the wall.
    under:=false
    for p in c.portals {
        if p.outside!=1 {continue}
        for edge in c.edges[p.edge_first:][:p.edge_count] {
            if c.portals[edge.to].outside!=3 {continue}
            testing.expect(t,edge.length>4)
            for corner in c.corners[edge.corner_first:][:edge.corner_count] {under|=corner.y<3}
        }
    }
    testing.expect(t,under)
    // Made again from the same volume, it is the same.
    again,_,_:=nav_coarse_build_region_volume(&c,&volume,&q,2,2,{{6,0,0},{10,16,16}},region_by_x,nil)
    testing.expect(t,again==count && len(c.regions)==1)
    // Made in steps of a small budget, the region it makes again stays until the last step, which
    // gives the same region.
    edges,corners:=len(c.edges),len(c.corners)
    b:Nav_Coarse_Build
    defer nav_coarse_build_destroy(&b)
    testing.expect(t,nav_coarse_begin_region_volume(&b,&c,&volume,2,3,{{6,0,0},{10,16,16}}))
    steps:=0
    made:=Nav_Coarse_Status.Running
    for ;made==.Running && steps<100000;steps+=1 {
        testing.expect(t,nav_coarse_region(&c,2).hash==2)
        made=nav_coarse_step_region_volume(&b,&c,&volume,&q,region_by_x,nil,16)
    }
    testing.expect_value(t,made,Nav_Coarse_Status.Done)
    testing.expectf(t,steps>2,"%d steps",steps)
    testing.expect(t,nav_coarse_region(&c,2).hash==3 && len(c.regions)==1 && len(c.portals)==count && len(c.edges)==edges && len(c.corners)==corners)
    // A route through it from one side to the other takes the way under the wall.
    s:Search
    testing.expect(t,search_init(&s,{nodes=64,max_edges=64}))
    defer search_destroy(&s)
    out:[32]math.Vec3
    n,status:=nav_coarse_route(&c,&s,{4,12,8},1,{12,12,8},3,out[:])
    testing.expect_value(t,status,Search_Status.Found)
    lowest:=f32(16)
    for point in out[:n] {lowest=min(lowest,point.y)}
    testing.expectf(t,lowest<3,"the route %v",out[:n])
}

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Coarse_Memory :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
coarse_memory_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Coarse_Memory)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// What the coarse graph asks memory for, with the memory ending at each
// request in turn: the call says so, the graph is as it was, nothing stays
// allocated, and with memory enough it goes through.
@(test)
coarse_graph_calls_without_memory_leave_it_as_it_was :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    row_mesh(t,&mesh,3)
    defer nav_mesh_destroy(&mesh)
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,1024))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    others:Nav_Coarse
    defer nav_coarse_destroy(&others)
    for key in ([]u64{1,3}) {
        _,_,made:=nav_coarse_build_region(&others,&mesh,&q,&filter,key,1,region_box(key),region_by_tile,nil)
        if !testing.expect(t,made) {return}
    }
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    limit:=Coarse_Memory{owner=mem.tracking_allocator(&track),remaining=max(int)}
    Call :: enum {Build,Merge,Copy}
    for call in Call {
        done,refused:=false,false
        for served in 0..<256 {
            context.allocator=runtime.Allocator{coarse_memory_proc,&limit}
            // The graph holds region 2 before the call, with no room to spare.
            c,copied:Nav_Coarse
            _,_,made:=nav_coarse_build_region(&c,&mesh,&q,&filter,2,7,region_box(2),region_by_tile,nil)
            if !testing.expect(t,made) {return}
            shrink(&c.regions);shrink(&c.portals);shrink(&c.edges);shrink(&c.corners)
            before:=[4]int{len(c.regions),len(c.portals),len(c.edges),len(c.corners)}
            ok:bool
            limit.remaining=served
            switch call {
            case .Build: _,_,ok=nav_coarse_build_region(&c,&mesh,&q,&filter,3,7,region_box(3),region_by_tile,nil)
            case .Merge: ok=nav_coarse_merge(&c,&others)
            case .Copy:  ok=nav_coarse_copy(&copied,&c)
            }
            limit.remaining=max(int)
            if !ok {
                refused=true
                after:=[4]int{len(c.regions),len(c.portals),len(c.edges),len(c.corners)}
                testing.expectf(t,after==before && nav_coarse_consistent(&c) && nav_coarse_region(&c,2)!=nil && nav_coarse_region(&c,3)==nil,"%v with %d requests served: the graph changed, %v from %v",call,served,after,before)
                testing.expectf(t,len(copied.regions)+len(copied.portals)+len(copied.edges)+len(copied.corners)==0,"%v with %d requests served kept a part",call,served)
            }
            nav_coarse_destroy(&c);nav_coarse_destroy(&copied)
            testing.expectf(t,len(track.allocation_map)==0,"%v with %d requests served: %d allocations are left",call,served,len(track.allocation_map))
            if done=ok;done {break}
        }
        testing.expectf(t,done && refused,"%v: refused without memory %v, went through with it %v",call,refused,done)
    }
}
