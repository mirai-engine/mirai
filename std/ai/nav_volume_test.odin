package ai

import "core:math/linalg"
import "core:mem"
import "core:testing"
import math "mirai:std/math"

// The twelve triangles of a box.
volume_box_triangles :: proc(vertices:^[dynamic]math.Vec3,indices:^[dynamic]u32,box:math.Aabb) {
    first:=u32(len(vertices))
    for i in 0..<8 {
        append(vertices,math.Vec3{box.max.x if i&1!=0 else box.min.x,box.max.y if i&2!=0 else box.min.y,box.max.z if i&4!=0 else box.min.z})
    }
    faces:=[6][4]u32{{0,2,6,4},{1,5,7,3},{0,4,5,1},{2,3,7,6},{0,1,3,2},{4,6,7,5}}
    for f in faces {append(indices,first+f[0],first+f[1],first+f[2],first+f[0],first+f[2],first+f[3])}
}

VOLUME_TEST_CONFIG :: Nav_Volume_Config{voxel=0.25,layers=4,half={0.3,0.3,0.3}}

// A cube of 16 m with a wall across it from y=3 up: the way from one side to
// the other goes under it.
volume_wall :: proc(t:^testing.T,volume:^Nav_Volume,config:=VOLUME_TEST_CONFIG) {
    testing.expect(t,nav_volume_init(volume,{voxel=config.voxel,layers=config.layers,max_zones=64}))
    vertices:[dynamic]math.Vec3
    indices:[dynamic]u32
    defer {delete(vertices);delete(indices)}
    volume_box_triangles(&vertices,&indices,{{7.5,3,0},{8.5,16,16}})
    spaces:=[]math.Aabb{{{0,0,0},{16,16,16}}}
    scratch:Nav_Volume_Scratch
    nav_volume_scratch_init(&scratch)
    defer nav_volume_scratch_destroy(&scratch)
    size:=volume.zone_size
    n:=i32(16/size)
    for z in 0..<n {for y in 0..<n {for x in 0..<n {
        data:Nav_Volume_Data
        status:=nav_volume_build(config,{x,y,z},{vertices=vertices[:],indices=indices[:],spaces=spaces},&scratch,&data)
        testing.expect_value(t,status,Nav_Build_Status.Built)
        testing.expect(t,nav_volume_add_zone(volume,data))
    }}}
}

volume_path :: proc(t:^testing.T,volume:^Nav_Volume,q:^Nav_Volume_Query,a,b:math.Vec3,out:[]Nav_Ref) -> int {
    from,ok_from:=nav_volume_find(volume,a)
    to,ok_to:=nav_volume_find(volume,b)
    testing.expect(t,ok_from && ok_to)
    count,status,partial:=nav_volume_find_path(q,volume,from,to,a,b,out)
    testing.expect_value(t,status,Search_Status.Found)
    testing.expect(t,!partial && count>0 && out[0]==from && out[count-1]==to)
    return count
}

@(test)
a_zone_keeps_free_only_what_is_clear_of_the_grown_obstacles :: proc(t:^testing.T) {
    volume:Nav_Volume
    volume_wall(t,&volume)
    defer nav_volume_destroy(&volume)
    _,in_wall:=nav_volume_find(&volume,{8,8,8})
    _,beside:=nav_volume_find(&volume,{8.7,8,8})
    _,clear:=nav_volume_find(&volume,{9.2,8,8})
    _,under:=nav_volume_find(&volume,{8,2,8})
    _,outside:=nav_volume_find(&volume,{8,8,-1})
    testing.expect(t,!in_wall && !beside && clear && under && !outside)
    // Open space is a few big nodes, not a voxel each.
    zone:=nav_volume_zone_at(&volume,{0,0,0})
    testing.expect(t,zone!=nil && len(zone.data.nodes)<4096 && len(zone.data.voxels)<1024)
}

@(test)
a_zone_is_the_same_whatever_the_order_of_its_triangles :: proc(t:^testing.T) {
    vertices:[dynamic]math.Vec3
    indices:[dynamic]u32
    defer {delete(vertices);delete(indices)}
    volume_box_triangles(&vertices,&indices,{{7.5,3,0},{8.5,16,16}})
    volume_box_triangles(&vertices,&indices,{{2,1,2},{3.3,2.1,5.2}})
    spaces:=[]math.Aabb{{{0,0,0},{16,16,16}}}
    scratch:Nav_Volume_Scratch
    nav_volume_scratch_init(&scratch)
    defer nav_volume_scratch_destroy(&scratch)
    a,b:Nav_Volume_Data
    testing.expect_value(t,nav_volume_build(VOLUME_TEST_CONFIG,{},{vertices=vertices[:],indices=indices[:],spaces=spaces},&scratch,&a),Nav_Build_Status.Built)
    defer nav_volume_data_free(&a)
    reversed:=make([]u32,len(indices))
    defer delete(reversed)
    for i in 0..<len(indices)/3 {
        j:=len(indices)/3-1-i
        reversed[i*3],reversed[i*3+1],reversed[i*3+2]=indices[j*3+2],indices[j*3],indices[j*3+1]
    }
    testing.expect_value(t,nav_volume_build(VOLUME_TEST_CONFIG,{},{vertices=vertices[:],indices=reversed,spaces=spaces},&scratch,&b),Nav_Build_Status.Built)
    defer nav_volume_data_free(&b)
    testing.expect(t,a.first==b.first && mem.compare(a.block,b.block)==0)
}

@(test)
a_path_through_a_volume_goes_under_the_wall_and_never_through_it :: proc(t:^testing.T) {
    volume:Nav_Volume
    // Zones of 4 m: the path crosses from zone to zone.
    volume_wall(t,&volume,{voxel=0.25,layers=2,half={0.3,0.3,0.3}})
    defer nav_volume_destroy(&volume)
    q:Nav_Volume_Query
    testing.expect(t,nav_volume_query_init(&q,1<<16))
    defer nav_volume_query_destroy(&q)
    a,b:=math.Vec3{4,12,8},math.Vec3{12,12,8}
    path:[1024]Nav_Ref
    count:=volume_path(t,&volume,&q,a,b,path[:])
    clear,_:=nav_volume_raycast(&volume,a,b)
    testing.expect(t,!clear)
    // Through the portals of its cells, every leg is in free space, and it dips under the wall.
    from:=a
    lowest:=f32(16)
    length:=f32(0)
    for i in 0..<count {
        to:=b
        if i+1<count {
            portal,ok:=nav_volume_portal(&volume,path[i],path[i+1])
            testing.expect(t,ok)
            to=portal
        }
        seen,_:=nav_volume_raycast(&volume,from,to)
        testing.expect(t,seen)
        lowest=min(lowest,to.y)
        length+=linalg.distance(from,to)
        from=to
    }
    testing.expect(t,lowest<2.8)
    testing.expect(t,length>linalg.distance(a,b)+12)
}

@(test)
an_agent_follows_a_volume_corridor_to_its_end :: proc(t:^testing.T) {
    volume:Nav_Volume
    volume_wall(t,&volume)
    defer nav_volume_destroy(&volume)
    q:Nav_Volume_Query
    testing.expect(t,nav_volume_query_init(&q,1<<16))
    defer nav_volume_query_destroy(&q)
    a,b:=math.Vec3{4,12,8},math.Vec3{12,12,8}
    path:[1024]Nav_Ref
    count:=volume_path(t,&volume,&q,a,b,path[:])
    c:Nav_Corridor
    testing.expect(t,nav_volume_corridor_set(&c,&volume,b,path[:count]))
    position:=a
    arrived:=false
    for _ in 0..<2000 {
        next,end,ok:=nav_volume_corridor_steer(&c,&volume,position,6)
        testing.expect(t,ok)
        if !ok {break}
        step:=next-position
        length:=linalg.length(step)
        if end && length<0.01 {arrived=true;break}
        if length>0.1 {step*=0.1/length}
        _,free:=nav_volume_find(&volume,position+step)
        testing.expect(t,free)
        position+=step
    }
    testing.expect(t,arrived)
}

@(test)
a_rebuilt_zone_ends_the_references_into_the_old_one :: proc(t:^testing.T) {
    volume:Nav_Volume
    volume_wall(t,&volume)
    defer nav_volume_destroy(&volume)
    ref,ok:=nav_volume_find(&volume,{4,12,8})
    testing.expect(t,ok && nav_volume_ref_valid(&volume,ref))
    copied:Nav_Volume
    testing.expect(t,nav_volume_copy(&copied,&volume))
    defer nav_volume_destroy(&copied)
    testing.expect(t,nav_volume_ref_valid(&copied,ref))
    scratch:Nav_Volume_Scratch
    nav_volume_scratch_init(&scratch)
    defer nav_volume_scratch_destroy(&scratch)
    data:Nav_Volume_Data
    spaces:=[]math.Aabb{{{0,0,0},{16,16,16}}}
    testing.expect_value(t,nav_volume_build(VOLUME_TEST_CONFIG,{},{spaces=spaces},&scratch,&data),Nav_Build_Status.Built)
    testing.expect(t,nav_volume_add_zone(&volume,data))
    testing.expect(t,!nav_volume_ref_valid(&volume,ref) && nav_volume_ref_valid(&copied,ref))
    // Without the wall, the way is straight.
    clear,_:=nav_volume_raycast(&volume,{4,12,8},{12,12,8})
    testing.expect(t,clear)
}

@(test)
the_nearest_free_point_leaves_the_grown_obstacle :: proc(t:^testing.T) {
    volume:Nav_Volume
    volume_wall(t,&volume)
    defer nav_volume_destroy(&volume)
    ref,point,ok:=nav_volume_find_nearest(&volume,{7.9,10,8},{2,2,2})
    testing.expect(t,ok && nav_volume_ref_valid(&volume,ref))
    testing.expect(t,point.x<=7.0 && point.x>6.9 && abs(point.y-10)<1e-3)
    _,_,none:=nav_volume_find_nearest(&volume,{8,10,8},{0.2,0.2,0.2})
    testing.expect(t,!none)
    rng:=math.rng_make(5)
    for _ in 0..<20 {
        around,p,found:=nav_volume_random_point_around(&volume,{4,8,8},3,&rng)
        testing.expect(t,found && nav_volume_ref_valid(&volume,around) && linalg.distance(p,math.Vec3{4,8,8})<=3)
    }
}

@(test)
searching_and_steering_through_a_volume_do_not_allocate :: proc(t:^testing.T) {
    volume:Nav_Volume
    volume_wall(t,&volume)
    defer nav_volume_destroy(&volume)
    q:Nav_Volume_Query
    testing.expect(t,nav_volume_query_init(&q,1<<16))
    defer nav_volume_query_destroy(&q)
    a,b:=math.Vec3{4,12,8},math.Vec3{12,12,8}
    from,_:=nav_volume_find(&volume,a)
    to,_:=nav_volume_find(&volume,b)
    rng:=math.rng_make(3)
    path:[256]Nav_Ref
    c:Nav_Corridor
    counter:Alloc_Counter
    saved:=context
    context.allocator=counting_allocator(&counter)
    context.temp_allocator=context.allocator
    for round in 0..<5 {
        count,status,_:=nav_volume_find_path(&q,&volume,from,to,a,b,path[:])
        if status!=.Found {break}
        nav_volume_corridor_set(&c,&volume,b,path[:count])
        nav_volume_corridor_steer(&c,&volume,a+{0,-0.1*f32(round),0},6)
        nav_volume_raycast(&volume,a,b)
        nav_volume_find_nearest(&volume,{8,10,8},{2,2,2})
        nav_volume_random_point_around(&volume,a,2,&rng)
    }
    context=saved
    testing.expect_value(t,counter.calls,0)
}

@(test)
hostile_calls_through_volumes :: proc(t:^testing.T) {
    volume:Nav_Volume
    volume_wall(t,&volume,{voxel=0.25,layers=2,half={0.3,0.3,0.3}})
    defer nav_volume_destroy(&volume)
    empty:Nav_Volume
    q:Nav_Volume_Query
    testing.expect(t,nav_volume_query_init(&q,4096))
    defer nav_volume_query_destroy(&q)
    rng:=math.rng_make(17)
    weird:=[]f32{0,-0.0,1e-30,-1e30,1e30,max(f32),-max(f32),f32(0h7f800000),f32(0hff800000),f32(0h7fc00000),4,8,12,2}
    pick :: proc(rng:^math.Rng,weird:[]f32) -> math.Vec3 {
        p:math.Vec3
        for &x in p {x=weird[math.rng_u32(rng)%u32(len(weird))] if math.rng_u32(rng)%3==0 else math.random_f32(rng)*16}
        return p
    }
    refs :: proc(rng:^math.Rng,volume:^Nav_Volume) -> Nav_Ref {
        switch math.rng_u32(rng)%3 {
        case 0: return Nav_Ref(math.rng_u64(rng))
        case 1: return Nav_Ref(math.rng_u64(rng)&~NAV_REF_LINK|NAV_REF_VOLUME)
        }
        ref,_:=nav_volume_find(volume,{math.random_f32(rng)*16,math.random_f32(rng)*16,math.random_f32(rng)*16})
        return ref
    }
    path:[64]Nav_Ref
    c:Nav_Corridor
    volumes:=[]^Nav_Volume{&volume,&empty}
    for _ in 0..<1500 {
        a,b:=pick(&rng,weird),pick(&rng,weird)
        for v in volumes {
            ref,other:=refs(&rng,&volume),refs(&rng,&volume)
            nav_volume_ref_valid(v,ref)
            nav_volume_ref_box(v,ref)
            nav_volume_find(v,a)
            nav_volume_find_nearest(v,a,b)
            nav_volume_raycast(v,a,b)
            nav_volume_random_point_around(v,a,b.x,&rng)
            nav_volume_portal(v,ref,other)
            count,_,_:=nav_volume_find_path(&q,v,ref,other,a,b,path[:])
            nav_volume_corridor_set(&c,v,b,path[:count])
            c.count=i32(math.rng_u32(&rng)%80)-8
            for &r in c.path[:8] {r=refs(&rng,&volume)}
            nav_volume_corridor_steer(&c,v,a,int(math.rng_u32(&rng)%100)-10)
        }
    }
    scratch:Nav_Volume_Scratch
    nav_volume_scratch_init(&scratch)
    defer nav_volume_scratch_destroy(&scratch)
    vertices:=[]math.Vec3{{1,1,1},{f32(0h7fc00000),2,2},{3,f32(0h7f800000),3},{1e30,0,0},{2,3,4},{5,1,2}}
    configs:=[]Nav_Volume_Config{
        {voxel=0},{voxel=-1},{voxel=f32(0h7fc00000)},{voxel=1e-30,layers=2},{voxel=0.5,layers=7},{voxel=0.5,layers=-1},
        {voxel=0.5,layers=2,half={f32(0h7fc00000),0,0}},{voxel=0.5,layers=2,half={-1,0,0}},{voxel=0.5,layers=2,origin={1e30,0,0}},
        {voxel=0.5,layers=2,half={1e5,1e5,1e5}},{voxel=1e5,layers=3},
    }
    inputs:=[]Nav_Volume_Input{
        {},{vertices=vertices,indices={0,1,2,3,4,5}},{vertices=vertices,indices={0,4,5,0,9,1}},{vertices=vertices,indices={0,4}},
        {spaces={{{f32(0h7fc00000),0,0},{1,1,1}},{{5,5,5},{-5,-5,-5}},{{-1e30,-1e30,-1e30},{1e30,1e30,1e30}}}},
    }
    coords:=[][3]i32{{},{1_000_000,0,0},{-2_000_000_000,0,0},{max(i32),min(i32),0}}
    for config in configs {
        for input in inputs {
            for coord in coords {
                data:Nav_Volume_Data
                status:=nav_volume_build(config,coord,input,&scratch,&data)
                if status==.Built {
                    zone:=data.coord
                    if nav_volume_add_zone(&volume,data) {nav_volume_remove_zone(&volume,zone)} else {nav_volume_data_free(&data)}
                }
            }
        }
    }
    // Forged zones are refused.
    nodes:=[]Nav_Volume_Node{{children=0,cell=.Mixed},{children=99,cell=.Mixed},{cell=Nav_Volume_Cell(7)}}
    forged:=[]Nav_Volume_Data{
        {layers=2,nodes=nodes},{layers=9,nodes=nodes},{layers=2},{layers=2,nodes=nodes[2:]},
        {layers=2,nodes=nodes[1:2],first={2=0,1=1,0=1}},{layers=0,nodes=nodes[:1]},
    }
    for data in forged {testing.expect(t,!nav_volume_add_zone(&volume,data))}
}
