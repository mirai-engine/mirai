package ai

import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

corridor_plan :: proc(t:^testing.T,c:^Nav_Corridor,q:^Nav_Query,mesh:^Nav_Mesh,filter:^Nav_Filter,a,b:math.Vec3) {
    path:[256]Nav_Ref
    from:=nearest(t,mesh,a)
    count,status,_:=nav_find_path(q,mesh,from,nearest(t,mesh,b),a,b,filter,path[:])
    testing.expect_value(t,status,Search_Status.Found)
    nav_corridor_reset(c,from,a)
    testing.expect(t,nav_corridor_set(c,mesh,filter,b,path[:count]))
}

@(test)
a_corridor_follows_the_agent_and_gives_its_next_corner :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    testing.expect(t,nav_mesh_init(&mesh,{tile_width=8,climb=0.3,max_tiles=4}))
    defer nav_mesh_destroy(&mesh)
    walkable:[64]bool
    for &w,i in walkable {w=!(i%8==4 && i/8<6)}
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},8,8,walkable[:],size=8)))
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Corridor
    a,b:=math.Vec3{1.5,0,1.5},math.Vec3{6.5,0,1.5}
    corridor_plan(t,&c,&q,&mesh,&filter,a,b)
    corners:[4]Nav_Corner
    // Walk toward each next corner in steps of 0.25 m, as an agent would.
    position:=a
    arrived:=false
    for _ in 0..<200 {
        n:=nav_corridor_corners(&c,&mesh,corners[:])
        testing.expect(t,n>=1)
        if n==0 {break}
        next:=corners[0].position
        if .End in corners[0].flags && linalg.distance(position,next)<0.05 {arrived=true;break}
        step:=next-position
        length:=linalg.length(step)
        if length>0.25 {step*=0.25/length}
        testing.expect(t,nav_corridor_move(&c,&mesh,&filter,position+step))
        position=c.position
        // Never through the wall.
        testing.expect(t,!(position.x>4.01 && position.x<4.99 && position.z<5.99))
    }
    testing.expect(t,arrived)
    testing.expect(t,c.count==1 && c.path[0]==nearest(t,&mesh,b))
}

@(test)
a_planned_path_is_straightened_but_keeps_around_a_costly_area :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    testing.expect(t,nav_mesh_init(&mesh,{tile_width=8,climb=0.3,max_tiles=4}))
    defer nav_mesh_destroy(&mesh)
    // Area 2 is a band at x 4..5 below z 6; area 3 a patch at x 2..3 below z 5.
    tile:=cell_tile(t,{0,0},8,8,size=8)
    for &p,i in tile.polys {
        cell:=i/2
        if cell%8==4 && cell/8<6 {p.area=2}
        if cell%8==2 && cell/8<5 {p.area=3}
    }
    testing.expect(t,nav_mesh_add_tile(&mesh,tile))
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,512))
    defer nav_query_destroy(&q)
    a,b:=math.Vec3{0.5,0,1.5},math.Vec3{6.5,0,1.5}
    from:=nearest(t,&mesh,a)
    // A* goes around both; the agent's filter only minds the band.
    planned:=test_filter()
    planned.costs[2],planned.costs[3]=10,10
    path:[256]Nav_Ref
    count,status,_:=nav_find_path(&q,&mesh,from,nearest(t,&mesh,b),a,b,&planned,path[:])
    testing.expect_value(t,status,Search_Status.Found)
    filter:=test_filter()
    filter.costs[2]=10
    corners:[16]Nav_Corner
    raw,_:=nav_straight_path(&mesh,a,b,path[:count],corners[:])
    length :: proc(corners:[]Nav_Corner) -> (sum:f32) {
        for i in 1..<len(corners) {sum+=linalg.distance(corners[i-1].position,corners[i].position)}
        return
    }
    before:=length(corners[:raw])
    c:Nav_Corridor
    nav_corridor_reset(&c,from,a)
    testing.expect(t,nav_corridor_set(&c,&mesh,&filter,b,path[:count]))
    areas:bit_set[0..=NAV_AREA_MAX;u64]
    for ref in c.path[:c.count] {
        _,poly:=nav_poly_of(&mesh,ref)
        areas+={poly.area}
    }
    n,complete:=nav_straight_path(&mesh,c.position,c.target,c.path[:c.count],corners[:])
    testing.expect(t,complete)
    // Straight through the patch, around the band by its top corners.
    testing.expect(t,3 in areas)
    testing.expect(t,length(corners[:n])<before-0.1)
    for corner in corners[:n] {
        testing.expect(t,!(corner.position.x>4.01 && corner.position.x<4.99 && corner.position.z<5.99))
    }
    testing.expect(t,n==4 && linalg.distance(corners[1].position,math.Vec3{4,0,6})<1e-3 && linalg.distance(corners[2].position,math.Vec3{5,0,6})<1e-3)
    // With the band as cheap as the ground, the path goes straight through it.
    filter.costs[2]=1
    nav_corridor_reset(&c,from,a)
    testing.expect(t,nav_corridor_set(&c,&mesh,&filter,b,path[:count]))
    n,_=nav_straight_path(&mesh,c.position,c.target,c.path[:c.count],corners[:])
    testing.expect_value(t,n,2)
}

@(test)
a_corridor_stops_at_a_link_and_goes_on_from_its_end :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    gap_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    link:=nav_mesh_add_link(&mesh,{start={2.9,0,1},end={5.1,1.5,1},radius=0.3,area=NAV_AREA_WALKABLE})
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Corridor
    a,b:=math.Vec3{0.5,0,1},math.Vec3{7.5,1.5,1}
    corridor_plan(t,&c,&q,&mesh,&filter,a,b)
    corners:[4]Nav_Corner
    n:=nav_corridor_corners(&c,&mesh,corners[:])
    testing.expect(t,n==1 && .Link in corners[0].flags && corners[0].ref==link)
    testing.expect(t,nav_corridor_move(&c,&mesh,&filter,{2.9,0,1}))
    from,to,crossed,ok:=nav_corridor_cross(&c,&mesh)
    testing.expect(t,ok && crossed==link && linalg.distance(from,math.Vec3{2.9,0,1})<1e-3 && linalg.distance(to,math.Vec3{5.1,1.5,1})<1e-3)
    testing.expect(t,!nav_ref_is_link(c.path[0]) && linalg.distance(c.position,to)<1e-3)
    n=nav_corridor_corners(&c,&mesh,corners[:])
    testing.expect(t,n==1 && .End in corners[0].flags && linalg.distance(corners[0].position,b)<1e-3)
    _,_,_,ok=nav_corridor_cross(&c,&mesh)
    testing.expect(t,!ok)
}

// Off its path the agent adds what it walked to the front, and after a
// target that moves the end follows it.
@(test)
a_corridor_takes_back_the_polygons_walked_off_it_and_follows_its_target :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},4,4)))
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Corridor
    a,b:=math.Vec3{1.5,0,1.5},math.Vec3{3.5,0,1.5}
    corridor_plan(t,&c,&q,&mesh,&filter,a,b)
    count:=c.count
    // Pushed back and away from the path: the corridor grows at its front and still ends at the target.
    testing.expect(t,nav_corridor_move(&c,&mesh,&filter,{0.5,0,3.5}))
    testing.expect(t,c.count>count && c.path[0]==nearest(t,&mesh,{0.5,0,3.5}) && nav_corridor_last(&c)==nearest(t,&mesh,b))
    joined :: proc(t:^testing.T,mesh:^Nav_Mesh,c:^Nav_Corridor) {
        for i in 1..<int(c.count) {
            _,_,ok:=nav_portal_points(mesh,c.path[i-1],c.path[i])
            testing.expect(t,ok)
        }
    }
    joined(t,&mesh,&c)
    // Its end follows a target that moves on and aside, and back over the path, without a search.
    for to in ([?]math.Vec3{{3.5,0,3.5},{1.5,0,3.5},{0.5,0,3.5}}) {
        testing.expect(t,nav_corridor_move_target(&c,&mesh,&filter,to))
        testing.expectf(t,nav_corridor_last(&c)==nearest(t,&mesh,to) && linalg.distance(c.target,to)<1e-3,"toward %v it ends at %v",to,c.target)
        joined(t,&mesh,&c)
    }
    testing.expect(t,c.count<=2)
    // Off the mesh it stops at its edge; a cut corridor or a damaged one does not move.
    testing.expect(t,nav_corridor_move_target(&c,&mesh,&filter,{-3,0,3.5}) && c.target.x>=0)
    c.cut=true
    testing.expect(t,!nav_corridor_move_target(&c,&mesh,&filter,{3.5,0,0.5}))
    c.cut,c.count=false,0
    testing.expect(t,!nav_corridor_move_target(&c,&mesh,&filter,{3.5,0,0.5}) && !nav_corridor_move_target(&c,nil,&filter,{3.5,0,0.5}))
}

@(test)
a_long_path_keeps_its_first_part_and_a_target_on_it :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    testing.expect(t,nav_mesh_init(&mesh,{tile_width=64,climb=0.3,max_tiles=1}))
    defer nav_mesh_destroy(&mesh)
    // A corridor one cell wide and 60 long: two triangles per cell.
    walkable:[64*2]bool
    for &w,i in walkable {w=i<60}
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},64,2,walkable[:],size=64)))
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,512))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Corridor
    // One that fits is cut once the agent, pushed back, adds what it walked to its front.
    corridor_plan(t,&c,&q,&mesh,&filter,{8.5,0,0.5},{37.5,0,0.5})
    testing.expect(t,!c.cut)
    testing.expect(t,nav_corridor_move(&c,&mesh,&filter,{1.5,0,0.5}))
    testing.expect(t,c.cut && c.count==NAV_CORRIDOR_CAPACITY && c.target.x<37)
    on,_:=nav_closest_point_on_poly(&mesh,nav_corridor_last(&c),c.target)
    testing.expect(t,linalg.distance(on,c.target)<1e-4)
    // One whose end, following its target, outgrows it is cut there too.
    corridor_plan(t,&c,&q,&mesh,&filter,{1.5,0,0.5},{30.5,0,0.5})
    testing.expect(t,!c.cut && nav_corridor_move_target(&c,&mesh,&filter,{36.5,0,0.5}))
    testing.expect(t,c.cut && c.count==NAV_CORRIDOR_CAPACITY && c.target.x<36)
    on,_=nav_closest_point_on_poly(&mesh,nav_corridor_last(&c),c.target)
    testing.expect(t,linalg.distance(on,c.target)<1e-4)
    a,b:=math.Vec3{0.5,0,0.5},math.Vec3{59.5,0,0.5}
    corridor_plan(t,&c,&q,&mesh,&filter,a,b)
    testing.expect_value(t,c.count,i32(NAV_CORRIDOR_CAPACITY))
    testing.expect(t,c.cut && c.target.x<59 && c.target.x>20)
    testing.expect(t,nav_corridor_valid(&c,&mesh,&filter,8))
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},64,2,walkable[:],size=64)))
    testing.expect(t,!nav_corridor_valid(&c,&mesh,&filter,8))
    testing.expect(t,!nav_corridor_move(&c,&mesh,&filter,a))
}

@(test)
following_a_path_and_querying_the_mesh_do_not_allocate :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    gap_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    nav_mesh_add_link(&mesh,{start={2.9,0,1},end={5.1,1.5,1},radius=0.3,area=NAV_AREA_WALKABLE,two_way=true})
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    a,b:=math.Vec3{0.5,0,1},math.Vec3{7.5,1.5,1}
    from,to:=nearest(t,&mesh,a),nearest(t,&mesh,b)
    rng:=math.rng_make(3)
    counter:Alloc_Counter
    saved:=context
    context.allocator=counting_allocator(&counter)
    context.temp_allocator=context.allocator
    path:[64]Nav_Ref
    corners:[8]Nav_Corner
    visited:[16]Nav_Ref
    c:Nav_Corridor
    for round in 0..<20 {
        count,status,_:=nav_find_path(&q,&mesh,from,to,a,b,&filter,path[:])
        if status!=.Found {break}
        nav_straight_path(&mesh,a,b,path[:count],corners[:])
        nav_corridor_reset(&c,from,a)
        nav_corridor_set(&c,&mesh,&filter,b,path[:count])
        nav_corridor_move(&c,&mesh,&filter,a+{0.1*f32(round),0,0})
        nav_corridor_corners(&c,&mesh,corners[:])
        nav_raycast(&mesh,from,a,{2.5,0,1.5},&filter,visited[:])
        nav_random_point(&mesh,&filter,&rng)
        nav_random_point_around(&q,&mesh,from,a,2,&filter,&rng)
        nav_distance_to_wall(&q,&mesh,from,a,2,&filter)
        nav_find_nearest(&mesh,b,{1,2,1},&filter)
    }
    context=saved
    testing.expect_value(t,counter.calls,0)
}
