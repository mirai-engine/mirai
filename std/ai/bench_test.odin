package ai

@(require) import "core:log"
@(require) import cmath "core:math"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import "core:math/linalg"
@(require) import math "mirai:std/math"

// Measurements of the hot paths: mirai test std/ai --release -define:MIRAI_BENCH=true
BENCH :: #config(MIRAI_BENCH,false)

when BENCH {

BENCH_ROUNDS :: 7

// Runs the body several times and reports the median: the machine is shared.
Bench :: struct {rounds:[BENCH_ROUNDS]time.Duration,start:time.Tick,round:int}
bench_round :: proc(b:^Bench) -> bool {
    if b.round>0 {b.rounds[b.round-1]=time.tick_since(b.start)}
    if b.round>=BENCH_ROUNDS {return false}
    b.round+=1
    b.start=time.tick_now()
    return true
}
bench_report :: proc(name:string,b:^Bench,operations:int,sink:f32=0) {
    for i in 1..<BENCH_ROUNDS {
        for j:=i;j>0 && b.rounds[j]<b.rounds[j-1];j-=1 {b.rounds[j],b.rounds[j-1]=b.rounds[j-1],b.rounds[j]}
    }
    log.infof("%-46s %10.1f ns/op   (%d ops, check %v)",name,f64(time.duration_nanoseconds(b.rounds[BENCH_ROUNDS/2]))/f64(operations),operations,sink)
}

// A square of side x side unit cells in one tile, two triangles each, with a
// wall of missing cells every eighth column that leaves alternating gaps.
bench_mesh :: proc(mesh:^Nav_Mesh,side:int) {
    vertices:=make([dynamic]math.Vec3);defer delete(vertices)
    indices:=make([dynamic]u32);defer delete(indices)
    for z in 0..=side {for x in 0..=side {append(&vertices,math.Vec3{f32(x),0,f32(z)})}}
    for z in 0..<side {
        for x in 0..<side {
            if x%8==4 && (z<side-3 if (x/8)%2==0 else z>=3) {continue}
            a,b,c,d:=u32(z*(side+1)+x),u32(z*(side+1)+x+1),u32((z+1)*(side+1)+x+1),u32((z+1)*(side+1)+x)
            append(&indices,a,b,c,a,c,d)
        }
    }
    nav_mesh_init(mesh,{tile_width=f32(side),climb=0.3,max_tiles=1})
    data,_:=nav_tile_from_triangles({0,0},{{0,-1,0},{f32(side),1,f32(side)}},vertices[:],indices[:])
    nav_mesh_add_tile(mesh,data)
}

@(test)
bench_navmesh :: proc(t:^testing.T) {
    SIDE :: 100
    QUERIES :: 2000
    mesh:Nav_Mesh
    bench_mesh(&mesh,SIDE)
    defer nav_mesh_destroy(&mesh)
    q:Nav_Query
    nav_query_init(&q,1<<15)
    defer nav_query_destroy(&q)
    filter:=Nav_Filter{can=NAV_CAN_ALL}
    rng:=math.rng_make(3)
    points:=make([]math.Vec3,QUERIES);defer delete(points)
    refs:=make([]Nav_Ref,QUERIES);defer delete(refs)
    for &p in points {p={math.random_range(&rng,0,SIDE),0.5,math.random_range(&rng,0,SIDE)}}
    sink:f32
    b:Bench
    for bench_round(&b) {
        for p,i in points {ref,position,_:=nav_find_nearest_any(&mesh,p,{1,2,1});refs[i]=ref;sink+=position.x}
    }
    bench_report("nav_find_nearest, 19k triangles, no tree",&b,QUERIES,sink)
    path:[1024]Nav_Ref
    corners:[256]Nav_Corner
    b={}
    PATHS :: 50
    for bench_round(&b) {
        for i in 0..<PATHS {
            count,_,_:=nav_find_path(&q,&mesh,refs[i],refs[QUERIES-1-i],points[i],points[QUERIES-1-i],&filter,path[:])
            n,_:=nav_straight_path(&mesh,points[i],points[QUERIES-1-i],path[:count],corners[:])
            sink+=f32(n)
        }
    }
    bench_report("nav_find_path and nav_straight_path, 19k triangles",&b,PATHS,sink)
    total:f32
    found:=0
    for i in 0..<PATHS {
        count,status,_:=nav_find_path(&q,&mesh,refs[i],refs[QUERIES-1-i],points[i],points[QUERIES-1-i],&filter,path[:])
        if status==.Found {
            n,_:=nav_straight_path(&mesh,points[i],points[QUERIES-1-i],path[:count],corners[:])
            found+=1
            for j in 1..<n {total+=linalg.length(corners[j].position-corners[j-1].position)}
        }
    }
    log.infof("paths found %d of %d, mean length %.3f",found,PATHS,total/f32(max(found,1)))
    // A horde: every point is a follower of the last one, each by a search of its own, then all by one toward it.
    FOLLOWERS :: 400
    target,end:=refs[QUERIES-1],points[QUERIES-1]
    expanded:=0
    b={}
    for bench_round(&b) {
        expanded=0
        for i in 0..<FOLLOWERS {
            count,_,_:=nav_find_path(&q,&mesh,refs[i],target,points[i],end,&filter,path[:])
            expanded+=q.search.stats.expanded
            sink+=f32(count)
        }
    }
    bench_report("400 followers of one end, a search each",&b,FOLLOWERS,f32(expanded))
    b={}
    for bench_round(&b) {
        nav_toward_begin(&q,&mesh,target,end,&filter)
        for i in 0..<FOLLOWERS {
            nav_toward_reach(&q,refs[i],max(int))
            count,_:=nav_toward_path(&q,refs[i],path[:])
            sink+=f32(count)
        }
    }
    bench_report("400 followers of one end, one search toward it",&b,FOLLOWERS,f32(q.search.stats.expanded))
}

// A zombie of 3 actions: it attacks or chases what it sees, else wanders;
// the actions end now and then.
Bench_Act :: enum u8 {Wander,Attack,Chase}

bench_think :: proc(t:^Think(Bench_Act)) {
    f:=(^[2]i32)(t.user)
    if f[0]>0 {
        if f[1]<=1 {propose(t,.Attack,0.9)}
        propose(t,.Chase,0.5)
    } else {
        propose(t,.Wander,0.1)
    }
}

bench_mind_act :: proc(a:^Act(Bench_Act)) -> Status {
    if a.phase==.Exit {return .Success}
    if a.action==.Wander && stage(a)==0 {
        if elapsed(a)<0.5 {return .Running}
        next_stage(a)
    }
    return .Success if (a.mind.ticks+u32(a.action))%3==0 else .Running
}

@(test)
bench_minds :: proc(t:^testing.T) {
    AGENTS :: 1000
    TICKS :: 60
    minds:=make([]Mind,AGENTS);defer delete(minds)
    facts:=make([][2]i32,AGENTS);defer delete(facts)
    acts:=[Bench_Act]proc(a:^Act(Bench_Act)) -> Status{.Wander=bench_mind_act,.Attack=bench_mind_act,.Chase=bench_mind_act}
    ctx:Mind_Context
    sink:f32
    b:Bench
    for bench_round(&b) {
        for tick in 0..<TICKS {
            ctx.time=f64(tick)/30
            ctx.tick=u64(tick)
            for &m,i in minds {
                facts[i]={i32((i+tick)/20%2),i32((i*7+tick)%4)}
                ctx.user=&facts[i]
                if _,running:=mind_tick(&m,&acts,bench_think,&ctx);running {sink+=1}
            }
        }
    }
    bench_report("mind_tick, 1000 zombies of 3 actions",&b,AGENTS*TICKS,sink)
    log.infof("bytes per agent: %d",size_of(Mind))
}

// A tile of 64 by 64 cells: a floor larger than the tile, stairs, boxes and a bridge.
@(test)
bench_nav_build_tile :: proc(t:^testing.T) {
    vertices:=make([dynamic]math.Vec3);defer delete(vertices)
    indices:=make([dynamic]u32);defer delete(indices)
    quad :: proc(vertices:^[dynamic]math.Vec3,indices:^[dynamic]u32,a,b,c,d:math.Vec3) {
        first:=u32(len(vertices))
        append(vertices,a,b,c,d)
        append(indices,first,first+1,first+2,first,first+2,first+3)
    }
    box :: proc(vertices:^[dynamic]math.Vec3,indices:^[dynamic]u32,l,h:math.Vec3) {
        quad(vertices,indices,{l.x,h.y,l.z},{l.x,h.y,h.z},{h.x,h.y,h.z},{h.x,h.y,l.z})
        quad(vertices,indices,{l.x,l.y,l.z},{l.x,h.y,l.z},{h.x,h.y,l.z},{h.x,l.y,l.z})
        quad(vertices,indices,{l.x,l.y,h.z},{h.x,l.y,h.z},{h.x,h.y,h.z},{l.x,h.y,h.z})
        quad(vertices,indices,{l.x,l.y,l.z},{l.x,l.y,h.z},{l.x,h.y,h.z},{l.x,h.y,l.z})
        quad(vertices,indices,{h.x,l.y,l.z},{h.x,h.y,l.z},{h.x,h.y,h.z},{h.x,l.y,h.z})
    }
    quad(&vertices,&indices,{-4,0,-4},{-4,0,24},{24,0,24},{24,0,-4})
    for k in 0..<8 {box(&vertices,&indices,{1+f32(k)*0.6,0,10},{1.6+f32(k)*0.6,f32(k+1)*0.2,14})}
    rng:=math.rng_make(5)
    for _ in 0..<12 {
        p:=math.Vec3{math.random_range(&rng,0,15),0,math.random_range(&rng,0,15)}
        box(&vertices,&indices,p,p+{math.random_range(&rng,0.4,2),math.random_range(&rng,0.3,2),math.random_range(&rng,0.4,2)})
    }
    box(&vertices,&indices,{-4,2.5,4},{24,2.75,6})
    config:=Nav_Build_Config{tile_size=64,cell_size=0.25,cell_height=0.1,agent_radius=0.5,agent_height=2,agent_climb=0.4,agent_max_slope=0.8,min_region_area=8,merge_region_area=20,max_edge_length=3,max_edge_error=0.3,detail_sample_distance=1.5,detail_max_error=0.1}
    input:=Nav_Build_Input{vertices=vertices[:],indices=indices[:]}
    scratch:Nav_Build_Scratch
    nav_build_scratch_init(&scratch)
    defer nav_build_scratch_destroy(&scratch)
    data:Nav_Tile_Data
    nav_build_tile(config,{},input,&scratch,&data)
    polys:=len(data.polys)
    nav_tile_data_free(&data)
    b:Bench
    for bench_round(&b) {
        nav_build_tile(config,{},input,&scratch,&data)
        nav_tile_data_free(&data)
    }
    bench_report("nav_build_tile, 64x64 cells",&b,1,f32(polys))
    // The same tile once an obstacle settles on it: from its triangles, and from the field its build kept.
    obstacle:=[1]Nav_Area_Volume{{points={{6,6},{8,6},{8,8},{6,8},{},{},{},{}},count=4,area=NAV_AREA_BLOCKED,min_y=-1,max_y=2}}
    input.volumes=obstacle[:]
    field:Nav_Tile_Field
    nav_build_tile(config,{},input,&scratch,&data,field=&field)
    defer nav_tile_field_free(&field)
    nav_tile_data_free(&data)
    b={}
    for bench_round(&b) {
        nav_build_tile(config,{},input,&scratch,&data)
        polys=len(data.polys)
        nav_tile_data_free(&data)
    }
    bench_report("nav_build_tile with an obstacle, 64x64 cells",&b,1,f32(polys))
    b={}
    for bench_round(&b) {
        nav_build_tile_again(config,{},&field,obstacle[:],&scratch,&data)
        polys=len(data.polys)
        nav_tile_data_free(&data)
    }
    bench_report("nav_build_tile_again with an obstacle",&b,1,f32(polys))
    log.infof("the field of the tile takes %d bytes",len(field.block))
}

// A crowd of agents at about one per 1.2 units of area (or volume), each
// heading for the point mirrored through the center, against its 16 nearest.
bench_avoid :: proc($N:int,name:string) {
    AGENTS :: 256
    NEIGHBORS :: 16
    REPEAT :: 20
    side:=cmath.pow(f32(AGENTS)*1.2,1/f32(N))
    rng:=math.rng_make(7)
    agents:=make([]Avoid_Agent(N),AGENTS);defer delete(agents)
    preferred:=make([][N]f32,AGENTS);defer delete(preferred)
    for &a,i in agents {
        for k in 0..<N {a.position[k]=math.random_range(&rng,0,side)}
        a.radius=0.4
        goal:[N]f32
        for k in 0..<N {goal[k]=side-a.position[k]}
        preferred[i]=linalg.normalize0(goal-a.position)*1.5
        a.velocity=preferred[i]
    }
    lists:=make([]Avoid_Agent(N),AGENTS*NEIGHBORS);defer delete(lists)
    distances:=make([]f32,AGENTS);defer delete(distances)
    for a,i in agents {
        for b,j in agents {distances[j]=linalg.length2(b.position-a.position) if j!=i else 1e30}
        for k in 0..<NEIGHBORS {
            best:=0
            for d,j in distances {if d<distances[best] {best=j}}
            lists[i*NEIGHBORS+k]=agents[best]
            distances[best]=1e30
        }
    }
    sink:f32
    b:Bench
    for bench_round(&b) {
        for _ in 0..<REPEAT {
            for a,i in agents {
                v:=avoid_velocity(a,preferred[i],1.5,lists[i*NEIGHBORS:][:NEIGHBORS],2,1.0/30)
                sink+=v[0]
            }
        }
    }
    bench_report(name,&b,AGENTS*REPEAT,sink)
    when N==2 {
        // Each in a yard of its own, three units across.
        b={}
        for bench_round(&b) {
            for _ in 0..<REPEAT {
                for a,i in agents {
                    p:=a.position
                    walls:=[8]Avoid_Wall{
                        {{p.x-1.5,p.y+1.5},{p.x,p.y+1.5}},{{p.x,p.y+1.5},{p.x+1.5,p.y+1.5}},{{p.x+1.5,p.y+1.5},{p.x+1.5,p.y}},{{p.x+1.5,p.y},{p.x+1.5,p.y-1.5}},
                        {{p.x+1.5,p.y-1.5},{p.x,p.y-1.5}},{{p.x,p.y-1.5},{p.x-1.5,p.y-1.5}},{{p.x-1.5,p.y-1.5},{p.x-1.5,p.y}},{{p.x-1.5,p.y},{p.x-1.5,p.y+1.5}},
                    }
                    v:=avoid_velocity(a,preferred[i],1.5,lists[i*NEIGHBORS:][:NEIGHBORS],2,1.0/30,walls[:],0.5)
                    sink+=v[0]
                }
            }
        }
        bench_report("avoid_velocity 2D, 16 neighbors and 8 walls",&b,AGENTS*REPEAT,sink)
    }
}

@(test)
bench_avoidance :: proc(t:^testing.T) {
    bench_avoid(2,"avoid_velocity 2D, 16 neighbors")
    bench_avoid(3,"avoid_velocity 3D, 16 neighbors")
}

// The air of the Swarm arena of the demo: a yard of 52 x 16 x 52 m with a
// floor, six pillars and a wall hanging from 3.5 m to 14 m, for an agent of
// 0.6 x 1.8 m; and a path from one side of the wall to the other, under it.
@(test)
bench_nav_volume :: proc(t:^testing.T) {
    config:=Nav_Volume_Config{voxel=0.15,layers=4,half={0.3,0.9,0.3}}
    vertices:=make([dynamic]math.Vec3);defer delete(vertices)
    indices:=make([dynamic]u32);defer delete(indices)
    volume_box_triangles(&vertices,&indices,{{-30,-1,-30},{30,0,30}})
    volume_box_triangles(&vertices,&indices,{{-28,3.5,-0.5},{28,14,0.5}})
    for i in 0..<6 {
        c:=math.Vec3{f32(i%3-1)*12,6,f32(i/3)*20-10}
        volume_box_triangles(&vertices,&indices,{c-{1,6,1},c+{1,6,1}})
    }
    spaces:=[]math.Aabb{{{-26,0,-26},{26,16,26}}}
    input:=Nav_Volume_Input{vertices=vertices[:],indices=indices[:],spaces=spaces}
    scratch:Nav_Volume_Scratch
    nav_volume_scratch_init(&scratch)
    defer nav_volume_scratch_destroy(&scratch)
    volume:Nav_Volume
    nav_volume_init(&volume,{voxel=config.voxel,layers=config.layers,max_zones=256})
    defer nav_volume_destroy(&volume)
    b:Bench
    zones:=0
    for bench_round(&b) {
        zones=0
        for z in i32(-3)..=2 {for y in i32(0)..=1 {for x in i32(-3)..=2 {
            data:Nav_Volume_Data
            if nav_volume_build(config,{x,y,z},input,&scratch,&data)==.Built && nav_volume_add_zone(&volume,data) {zones+=1}
        }}}
    }
    bench_report("nav_volume_build, a zone of 64^3 voxels",&b,zones,f32(zones))
    q:Nav_Volume_Query
    nav_volume_query_init(&q,1<<16)
    defer nav_volume_query_destroy(&q)
    a,c:=math.Vec3{0,8,12},math.Vec3{0,8,-12}
    from,_:=nav_volume_find(&volume,a)
    to,_:=nav_volume_find(&volume,c)
    path:[1024]Nav_Ref
    expanded:=0
    b={}
    for bench_round(&b) {
        nav_volume_find_path(&q,&volume,from,to,a,c,path[:])
        expanded=q.search.stats.expanded
    }
    bench_report("nav_volume_find_path, under a wall",&b,1,f32(expanded))
    // The region of a section over half of the courtyard: a portal where its
    // free space goes on across the border, and a search for each pair.
    half :: proc(user:rawptr,point:math.Vec3) -> u64 {return 1 if point.x<0 else 2}
    graph:Nav_Coarse
    defer nav_coarse_destroy(&graph)
    portals:=0
    b={}
    for bench_round(&b) {
        portals,_,_=nav_coarse_build_region_volume(&graph,&volume,&q,1,1,{{-26,0,-26},{0,16,26}},half,nil)
    }
    bench_report("nav_coarse_build_region_volume, half of it",&b,1,f32(portals))
    // In steps, as the navigation plugin makes it over ticks: a zone of its border or ways that expand
    // 256 cells a step. Its longest step.
    build:Nav_Coarse_Build
    defer nav_coarse_build_destroy(&build)
    longest:time.Duration
    steps:=0
    nav_coarse_begin_region_volume(&build,&graph,&volume,1,1,{{-26,0,-26},{0,16,26}})
    for {
        start:=time.tick_now()
        status:=nav_coarse_step_region_volume(&build,&graph,&volume,&q,half,nil,256)
        longest=max(longest,time.tick_since(start))
        steps+=1
        if status!=.Running {break}
    }
    log.infof("nav_coarse_step_region_volume, 256 cells: %d steps, the longest %v",steps,longest)
}

}
