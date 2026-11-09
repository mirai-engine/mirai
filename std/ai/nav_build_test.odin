package ai

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:testing"
import math "mirai:std/math"

@(private="file")
test_config :: proc() -> Nav_Build_Config {
    return {
        tile_size=32,
        cell_size=0.25,
        cell_height=0.125,
        agent_radius=0.5,
        agent_height=2,
        agent_climb=0.5,
        agent_max_slope=math.PI/4,
        min_region_area=8,
        merge_region_area=20,
        max_edge_length=3,
        max_edge_error=0.3,
        detail_sample_distance=1.5,
        detail_max_error=0.125,
    }
}

@(private="file")
Test_Mesh :: struct {
    vertices:[dynamic]math.Vec3,
    indices:[dynamic]u32,
}

@(private="file")
test_mesh_destroy :: proc(m:^Test_Mesh) {delete(m.vertices);delete(m.indices)}

@(private="file")
test_quad :: proc(m:^Test_Mesh,a,b,c,d:math.Vec3) {
    first:=u32(len(m.vertices))
    append(&m.vertices,a,b,c,d)
    append(&m.indices,first,first+1,first+2,first,first+2,first+3)
}

@(private="file")
test_plane :: proc(m:^Test_Mesh,x0,z0,x1,z1,y:f32) {
    test_quad(m,{x0,y,z0},{x0,y,z1},{x1,y,z1},{x1,y,z0})
}

@(private="file")
test_box :: proc(m:^Test_Mesh,low,high:math.Vec3) {
    l,h:=low,high
    test_quad(m,{l.x,h.y,l.z},{l.x,h.y,h.z},{h.x,h.y,h.z},{h.x,h.y,l.z})
    test_quad(m,{l.x,l.y,l.z},{h.x,l.y,l.z},{h.x,l.y,h.z},{l.x,l.y,h.z})
    test_quad(m,{l.x,l.y,l.z},{l.x,h.y,l.z},{h.x,h.y,l.z},{h.x,l.y,l.z})
    test_quad(m,{l.x,l.y,h.z},{h.x,l.y,h.z},{h.x,h.y,h.z},{l.x,h.y,h.z})
    test_quad(m,{l.x,l.y,l.z},{l.x,l.y,h.z},{l.x,h.y,h.z},{l.x,h.y,l.z})
    test_quad(m,{h.x,l.y,l.z},{h.x,h.y,l.z},{h.x,h.y,h.z},{h.x,l.y,h.z})
}

@(private="file")
test_input :: proc(m:^Test_Mesh,volumes:[]Nav_Area_Volume=nil) -> Nav_Build_Input {
    return {vertices=m.vertices[:],indices=m.indices[:],volumes=volumes}
}

@(private="file")
test_build :: proc(t:^testing.T,m:^Test_Mesh,coord:=[2]i32{},config:=Nav_Build_Config{},volumes:[]Nav_Area_Volume=nil,loc:=#caller_location) -> (data:Nav_Tile_Data,status:Nav_Build_Status) {
    config:=config
    if config.tile_size==0 {config=test_config()}
    scratch:Nav_Build_Scratch
    nav_build_scratch_init(&scratch)
    defer nav_build_scratch_destroy(&scratch)
    status=nav_build_tile(config,coord,test_input(m,volumes),&scratch,&data)
    if status==.Built {test_check_tile(t,&data,loc)}
    return
}

// The cross product of the XZ triangle: negative when counter-clockwise seen from above.
@(private="file")
test_cross :: proc(a,b,c:math.Vec3) -> f32 {return (b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x)}

// Every polygon is convex, counter-clockwise seen from above and linked both
// ways; details and the tree name what exists.
@(private="file")
test_check_tile :: proc(t:^testing.T,data:^Nav_Tile_Data,loc:=#caller_location) {
    testing.expect(t,len(data.polys)>0,loc=loc)
    testing.expect_value(t,len(data.details),len(data.polys),loc=loc)
    testing.expect_value(t,len(data.poly_links),len(data.polys),loc=loc)
    testing.expect_value(t,len(data.bv),2*len(data.polys)-1,loc=loc)
    for p,i in data.polys {
        n:=int(p.count)
        if !testing.expect(t,n>=3 && n<=NAV_VERTS_PER_POLY,loc=loc) {return}
        testing.expect(t,p.area!=NAV_AREA_BLOCKED,loc=loc)
        for k in 0..<n {
            if !testing.expect(t,int(p.vertices[k])<len(data.vertices),loc=loc) {return}
        }
        for k in 0..<n {
            a,b,c:=data.vertices[p.vertices[k]],data.vertices[p.vertices[(k+1)%n]],data.vertices[p.vertices[(k+2)%n]]
            testing.expectf(t,test_cross(a,b,c)<=0,"polygon %d turns clockwise at %d",i,k,loc=loc)
            testing.expect(t,math.aabb_contains_point(math.aabb_expand(data.bounds,1e-3),a),loc=loc)
        }
        for k in 0..<n {
            neighbor:=p.neighbor[k]
            if neighbor==NAV_EDGE_WALL || neighbor&NAV_EDGE_PORTAL!=0 {
                testing.expect(t,neighbor&NAV_EDGE_PORTAL==0 || neighbor&~NAV_EDGE_PORTAL<4,loc=loc)
                continue
            }
            other:=int(neighbor)-1
            if !testing.expect(t,other<len(data.polys),loc=loc) {return}
            a,b:=p.vertices[k],p.vertices[(k+1)%n]
            q:=data.polys[other]
            back:=false
            for j in 0..<int(q.count) {
                if q.vertices[j]==b && q.vertices[(j+1)%int(q.count)]==a && int(q.neighbor[j])==i+1 {back=true}
            }
            testing.expectf(t,back,"polygon %d is not linked back from %d",i,other,loc=loc)
        }
        d:=data.details[i]
        if !testing.expect(t,int(d.vertex_first)+int(d.vertex_count)<=len(data.detail_vertices),loc=loc) {return}
        if !testing.expect(t,int(d.triangle_first)+int(d.triangle_count)<=len(data.detail_triangles),loc=loc) {return}
        testing.expect(t,d.triangle_count>0,loc=loc)
        for tri in data.detail_triangles[d.triangle_first:][:d.triangle_count] {
            corners:[3]math.Vec3
            for k in 0..<3 {
                if !testing.expect(t,int(tri[k])<n+int(d.vertex_count),loc=loc) {return}
                corners[k]=data.vertices[p.vertices[tri[k]]] if int(tri[k])<n else data.detail_vertices[int(d.vertex_first)+int(tri[k])-n]
            }
            testing.expect(t,test_cross(corners[0],corners[1],corners[2])<=0,loc=loc)
        }
    }
    leaves:=0
    for node,i in data.bv {
        if node.index>=0 {
            leaves+=1
            testing.expect(t,int(node.index)<len(data.polys),loc=loc)
        } else {
            testing.expect(t,i+int(-node.index)<=len(data.bv),loc=loc)
        }
    }
    testing.expect_value(t,leaves,len(data.polys),loc=loc)
    for link in data.poly_links {testing.expect_value(t,link,0,loc=loc)}
    testing.expect_value(t,data.hash,0,loc=loc)
}

// The height of the detail mesh of the polygon under the point.
@(private="file")
test_detail_height :: proc(data:^Nav_Tile_Data,poly:int,p:math.Vec3) -> (height:f32,ok:bool) {
    q:=data.polys[poly]
    d:=data.details[poly]
    vertex :: proc(data:^Nav_Tile_Data,q:Nav_Poly,d:Nav_Detail,index:u8) -> math.Vec3 {
        if index<q.count {return data.vertices[q.vertices[index]]}
        return data.detail_vertices[int(d.vertex_first)+int(index-q.count)]
    }
    for tri in data.detail_triangles[d.triangle_first:][:d.triangle_count] {
        a,b,c:=vertex(data,q,d,tri[0]),vertex(data,q,d,tri[1]),vertex(data,q,d,tri[2])
        area:=test_cross(a,b,c)
        if area==0 {continue}
        u,v,w:=test_cross(p,b,c)/area,test_cross(a,p,c)/area,test_cross(a,b,p)/area
        if u< -1e-4 || v< -1e-4 || w< -1e-4 {continue}
        return a.y*u+b.y*v+c.y*w,true
    }
    return
}

// The polygon whose XZ footprint holds the point, with its detail surface
// within tolerance of the height of the point.
@(private="file")
test_find_poly :: proc(data:^Nav_Tile_Data,p:math.Vec3,tolerance:f32=0.3) -> int {
    for poly,i in data.polys {
        n:=int(poly.count)
        inside:=true
        for k in 0..<n {
            a,b:=data.vertices[poly.vertices[k]],data.vertices[poly.vertices[(k+1)%n]]
            if test_cross(a,b,p)>0 {inside=false;break}
        }
        if !inside {continue}
        if height,ok:=test_detail_height(data,i,p);ok && abs(height-p.y)<=tolerance {return i}
    }
    return -1
}

@(private="file")
test_connected :: proc(data:^Nav_Tile_Data,from,to:int) -> bool {
    if from<0 || to<0 {return false}
    seen:=make([]bool,len(data.polys))
    defer delete(seen)
    queue:=make([dynamic]int)
    defer delete(queue)
    append(&queue,from)
    seen[from]=true
    for head:=0;head<len(queue);head+=1 {
        p:=data.polys[queue[head]]
        if queue[head]==to {return true}
        for k in 0..<int(p.count) {
            n:=p.neighbor[k]
            if n==NAV_EDGE_WALL || n&NAV_EDGE_PORTAL!=0 || seen[n-1] {continue}
            seen[n-1]=true
            append(&queue,int(n-1))
        }
    }
    return false
}

@(private="file")
test_area :: proc(data:^Nav_Tile_Data) -> f32 {
    total:f32
    for p in data.polys {
        a:=data.vertices[p.vertices[0]]
        for k in 1..<int(p.count)-1 {total-=test_cross(a,data.vertices[p.vertices[k]],data.vertices[p.vertices[k+1]])*0.5}
    }
    return total
}

@(test)
a_flat_plane_is_covered_but_for_the_agent_radius :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_plane(&m,0.1,0.1,7.9,7.9,0)
    data,status:=test_build(t,&m)
    defer nav_tile_data_free(&data)
    testing.expect_value(t,status,Nav_Build_Status.Built)
    config:=test_config()
    low,high:=data.bounds.min,data.bounds.max
    margin:=2*config.cell_size
    for k in ([2]int{0,2}) {
        testing.expectf(t,abs(low[k]-(0.1+config.agent_radius))<=margin,"low %v",low)
        testing.expectf(t,abs(high[k]-(7.9-config.agent_radius))<=margin,"high %v",high)
    }
    testing.expect(t,abs(low.y)<=config.cell_height && abs(high.y)<=config.cell_height)
    covered:=(high.x-low.x)*(high.z-low.z)
    testing.expectf(t,abs(test_area(&data)-covered)<=covered*1e-3,"area %v of %v",test_area(&data),covered)
    for p in data.polys {
        for k in 0..<int(p.count) {testing.expect_value(t,p.neighbor[k]&NAV_EDGE_PORTAL,0)}
    }
    testing.expect(t,test_find_poly(&data,{4,0,4})>=0)
}

@(test)
a_box_keeps_the_surface_an_agent_radius_away :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_plane(&m,-4,-4,12,12,0)
    test_box(&m,{3,0,3},{5,1,5})
    data,status:=test_build(t,&m)
    defer nav_tile_data_free(&data)
    testing.expect_value(t,status,Nav_Build_Status.Built)
    testing.expect(t,test_find_poly(&data,{4,0,4})<0)
    testing.expect(t,test_find_poly(&data,{5.25,0,4})<0)
    testing.expect(t,test_find_poly(&data,{4,0,2.75})<0)
    testing.expect(t,test_find_poly(&data,{6.25,0,4})>=0)
    testing.expect(t,test_find_poly(&data,{4,0,1.75})>=0)
    testing.expect(t,test_find_poly(&data,{4,1,4})>=0)
}

@(test)
a_pillar_inside_one_region_leaves_a_hole_in_its_polygons :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_plane(&m,-4,-4,12,12,0)
    test_box(&m,{3,0,3},{5,2.5,5})
    config:=test_config()
    config.merge_region_area=400
    data,status:=test_build(t,&m,config=config)
    defer nav_tile_data_free(&data)
    testing.expect_value(t,status,Nav_Build_Status.Built)
    testing.expect(t,test_find_poly(&data,{4,0,4})<0)
    for p in ([4]math.Vec3{{1.5,0,4},{6.5,0,4},{4,0,1.5},{4,0,6.5}}) {testing.expect(t,test_find_poly(&data,p)>=0)}
    hole:=64-test_area(&data)
    testing.expectf(t,hole>=9 && hole<=16,"the hole measures %v",hole)
}

@(test)
stairs_within_the_climb_connect_and_a_higher_step_does_not :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    heights:=[4]f32{0,0.375,0.75,1.5}
    edges:=[5]f32{0.5,2,3.5,5,7.5}
    for k in 0..<4 {
        test_plane(&m,edges[k],0.5,edges[k+1],7.5,heights[k])
        if k>0 {test_quad(&m,{edges[k],heights[k-1],0.5},{edges[k],heights[k],0.5},{edges[k],heights[k],7.5},{edges[k],heights[k-1],7.5})}
    }
    data,status:=test_build(t,&m)
    defer nav_tile_data_free(&data)
    testing.expect_value(t,status,Nav_Build_Status.Built)
    bottom:=test_find_poly(&data,{1.25,0,4})
    middle:=test_find_poly(&data,{4.25,0.75,4})
    top:=test_find_poly(&data,{6.5,1.5,4})
    testing.expect(t,bottom>=0 && middle>=0 && top>=0)
    testing.expect(t,test_connected(&data,bottom,middle))
    testing.expect(t,!test_connected(&data,bottom,top))
    testing.expect(t,!test_connected(&data,top,middle))
}

@(test)
a_slope_steeper_than_the_maximum_is_not_walkable :: proc(t:^testing.T) {
    for slope in ([2]f32{0.577,1.732}) {
        m:Test_Mesh
        defer test_mesh_destroy(&m)
        test_quad(&m,{1,0,1},{1,0,7},{7,6*slope,7},{7,6*slope,1})
        data,status:=test_build(t,&m)
        defer nav_tile_data_free(&data)
        if slope<1 {
            testing.expect_value(t,status,Nav_Build_Status.Built)
            testing.expect(t,test_find_poly(&data,{4,3*slope,4},0.5)>=0)
        } else {
            testing.expect_value(t,status,Nav_Build_Status.Empty)
        }
    }
}

@(private="file")
test_bumps :: proc(x,z:f32) -> f32 {
    ridge :: proc(t:f32) -> f32 {
        u:=t/2
        k:=int(u)
        heights:=[5]f32{0,0.6,1.2,0.6,0}
        return heights[k%4]+(heights[k%4+1]-heights[k%4])*(u-f32(k))
    }
    return ridge(x)+ridge(z)
}

@(test)
the_detail_mesh_follows_a_bumpy_floor :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    N :: 16
    for z in 0..=N {
        for x in 0..=N {append(&m.vertices,math.Vec3{f32(x)*0.5,test_bumps(f32(x)*0.5,f32(z)*0.5),f32(z)*0.5})}
    }
    for z in 0..<N {
        for x in 0..<N {
            a:=u32(z*(N+1)+x)
            append(&m.indices,a,a+N+1,a+1,a+1,a+N+1,a+N+2)
        }
    }
    data,status:=test_build(t,&m)
    defer nav_tile_data_free(&data)
    testing.expect_value(t,status,Nav_Build_Status.Built)
    testing.expect(t,len(data.detail_vertices)>0)
    found:=0
    for z:=f32(1.1);z<7;z+=0.37 {
        for x:=f32(1.1);x<7;x+=0.37 {
            p:=math.Vec3{x,test_bumps(x,z),z}
            if test_find_poly(&data,p,0.5)>=0 {found+=1}
        }
    }
    testing.expectf(t,found==16*16,"the detail mesh is within reach at %d of %d points",found,16*16)
}

@(test)
a_bridge_over_a_floor_gives_two_layers :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_plane(&m,-4,-4,12,12,0)
    test_box(&m,{-4,2.5,3},{12,2.75,5})
    data,status:=test_build(t,&m)
    defer nav_tile_data_free(&data)
    testing.expect_value(t,status,Nav_Build_Status.Built)
    below:=test_find_poly(&data,{4,0,4})
    above:=test_find_poly(&data,{4,2.75,4})
    testing.expect(t,below>=0 && above>=0 && below!=above)
    testing.expect(t,!test_connected(&data,below,above))
}

@(test)
volumes_mark_their_area_and_a_blocked_volume_removes_the_surface :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_plane(&m,-4,-4,12,12,0)
    volumes:=[3]Nav_Area_Volume{
        {points={{1,1},{3,1},{3,3},{1,3},{},{},{},{}},count=4,area=5,min_y=-1,max_y=1},
        {points={{5,5},{7,5},{7,7},{5,7},{},{},{},{}},count=4,area=NAV_AREA_BLOCKED,min_y=-1,max_y=1},
        {points={{1,5},{3,5},{3,7},{1,7},{},{},{},{}},count=4,area=7,min_y=1,max_y=2},
    }
    data,status:=test_build(t,&m,volumes=volumes[:])
    defer nav_tile_data_free(&data)
    testing.expect_value(t,status,Nav_Build_Status.Built)
    marked:=test_find_poly(&data,{2,0,2})
    plain:=test_find_poly(&data,{6,0,2})
    above:=test_find_poly(&data,{2,0,6})
    testing.expect(t,marked>=0 && plain>=0 && above>=0)
    testing.expect_value(t,data.polys[marked].area,5)
    testing.expect_value(t,data.polys[plain].area,NAV_AREA_WALKABLE)
    testing.expect_value(t,data.polys[above].area,NAV_AREA_WALKABLE)
    testing.expect(t,test_find_poly(&data,{6,0,6})<0)
    testing.expect(t,test_find_poly(&data,{6,0,4.75})<0)
}

@(test)
a_ceiling_lower_than_the_agent_removes_the_surface_below :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_plane(&m,-4,-4,12,12,0)
    test_box(&m,{2,1.5,2},{6,1.75,6})
    data,status:=test_build(t,&m)
    defer nav_tile_data_free(&data)
    testing.expect_value(t,status,Nav_Build_Status.Built)
    testing.expect(t,test_find_poly(&data,{4,0,4})<0)
    testing.expect(t,test_find_poly(&data,{1,0,1})>=0)
    testing.expect(t,test_find_poly(&data,{4,1.75,4})>=0)
}

@(private="file")
test_portal_vertices :: proc(data:^Nav_Tile_Data,side:Nav_Side) -> [dynamic]math.Vec3 {
    out:[dynamic]math.Vec3
    for p in data.polys {
        for k in 0..<int(p.count) {
            if p.neighbor[k]!=NAV_EDGE_PORTAL|u16(side) {continue}
            for v in ([2]u16{p.vertices[k],p.vertices[(k+1)%int(p.count)]}) {
                if !slice.contains(out[:],data.vertices[v]) {append(&out,data.vertices[v])}
            }
        }
    }
    slice.sort_by(out[:],proc(a,b:math.Vec3) -> bool {return a.z<b.z || a.z==b.z && a.x<b.x})
    return out
}

@(test)
neighbor_tiles_meet_at_portals_with_the_same_vertices :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_plane(&m,-4,-4,20,12,0)
    left,status_left:=test_build(t,&m,{0,0})
    defer nav_tile_data_free(&left)
    right,status_right:=test_build(t,&m,{1,0})
    defer nav_tile_data_free(&right)
    testing.expect_value(t,status_left,Nav_Build_Status.Built)
    testing.expect_value(t,status_right,Nav_Build_Status.Built)
    rect:=nav_tile_rect(test_config(),{0,0})
    testing.expect_value(t,rect,math.Aabb{{0,-max(f32),0},{8,max(f32),8}})
    lines:=[Nav_Side][2]f32{.Pos_X={0,8},.Pos_Z={2,8},.Neg_X={0,0},.Neg_Z={2,0}}
    for side in Nav_Side {
        vertices:=test_portal_vertices(&left,side)
        defer delete(vertices)
        testing.expectf(t,len(vertices)>=2,"no portal on %v",side)
        axis,at:=int(lines[side][0]),lines[side][1]
        for v in vertices {testing.expectf(t,v[axis]==at,"%v portal vertex %v off its border",side,v)}
    }
    for p in left.polys {
        for k in 0..<int(p.count) {
            a,b:=left.vertices[p.vertices[k]],left.vertices[p.vertices[(k+1)%int(p.count)]]
            on_border:=a.x==b.x && (a.x==0 || a.x==8) || a.z==b.z && (a.z==0 || a.z==8)
            testing.expect(t,on_border==(p.neighbor[k]&NAV_EDGE_PORTAL!=0))
        }
    }
    shared_left:=test_portal_vertices(&left,.Pos_X)
    defer delete(shared_left)
    shared_right:=test_portal_vertices(&right,.Neg_X)
    defer delete(shared_right)
    testing.expectf(t,slice.equal(shared_left[:],shared_right[:]),"%v and %v",shared_left,shared_right)
}

@(private="file")
test_scene :: proc(m:^Test_Mesh) {
    test_plane(m,-4,-4,12,12,0)
    test_box(m,{1,0,1},{2.5,1,2.5})
    test_box(m,{5,0,1},{6,3,6.5})
    for k in 0..<4 {
        y:=f32(k+1)*0.25
        test_box(m,{1+f32(k)*0.75,0,4.5},{1.75+f32(k)*0.75,y,7})
    }
}

@(test)
the_same_input_builds_the_same_bytes :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_scene(&m)
    volumes:=[1]Nav_Area_Volume{{points={{3,3},{4,3},{4,4},{3,4},{},{},{},{}},count=4,area=9,min_y=-1,max_y=1}}
    first,status_first:=test_build(t,&m,volumes=volumes[:])
    defer nav_tile_data_free(&first)
    testing.expect_value(t,status_first,Nav_Build_Status.Built)
    scratch:Nav_Build_Scratch
    nav_build_scratch_init(&scratch)
    defer nav_build_scratch_destroy(&scratch)
    for _ in 0..<2 {
        again:Nav_Tile_Data
        testing.expect_value(t,nav_build_tile(test_config(),{},test_input(&m,volumes[:]),&scratch,&again),Nav_Build_Status.Built)
        testing.expect(t,slice.equal(first.block,again.block))
        nav_tile_data_free(&again)
    }
}

@(test)
a_second_build_of_a_tile_allocates_no_scratch :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_scene(&m)
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    scratch:Nav_Build_Scratch
    nav_build_scratch_init(&scratch,mem.tracking_allocator(&tracking))
    defer nav_build_scratch_destroy(&scratch)
    allocated:i64
    for round in 0..<3 {
        data:Nav_Tile_Data
        testing.expect_value(t,nav_build_tile(test_config(),{},test_input(&m),&scratch,&data),Nav_Build_Status.Built)
        nav_tile_data_free(&data)
        if round==2 {testing.expect_value(t,tracking.total_memory_allocated,allocated)}
        allocated=tracking.total_memory_allocated
    }
}

@(test)
nothing_walkable_builds_an_empty_tile :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    data,status:=test_build(t,&m)
    testing.expect_value(t,status,Nav_Build_Status.Empty)
    testing.expect(t,data.block==nil)
    test_plane(&m,40,40,50,50,0)
    _,status=test_build(t,&m)
    testing.expect_value(t,status,Nav_Build_Status.Empty)
    clear(&m.vertices)
    clear(&m.indices)
    test_plane(&m,3,3,3.4,3.4,0)
    _,status=test_build(t,&m)
    testing.expect_value(t,status,Nav_Build_Status.Empty)
    nan:=f32(0h7fc00000)
    clear(&m.vertices)
    clear(&m.indices)
    test_plane(&m,0,0,8,nan,0)
    _,status=test_build(t,&m)
    testing.expect_value(t,status,Nav_Build_Status.Empty)
}

@(test)
invalid_configs_and_inputs_are_rejected :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_plane(&m,0,0,8,8,0)
    scratch:Nav_Build_Scratch
    nav_build_scratch_init(&scratch)
    defer nav_build_scratch_destroy(&scratch)
    data:Nav_Tile_Data
    nan:=f32(0h7fc00000)
    configs:[dynamic]Nav_Build_Config
    defer delete(configs)
    for k in 0..<14 {
        c:=test_config()
        switch k {
        case 0: c.tile_size=0
        case 1: c.cell_size=0
        case 2: c.cell_height=nan
        case 3: c.agent_radius=-1
        case 4: c.agent_height=0
        case 5: c.agent_max_slope=math.PI/2
        case 6: c.agent_max_slope=-0.1
        case 7: c.min_region_area=-1
        case 8: c.merge_region_area=-1
        case 9: c.tile_size=NAV_BUILD_MAX_CELLS
        case 10: c.detail_sample_distance=-1
        case 11: c.origin.x=f32(0h7f800000)
        case 12: c.agent_climb=1e30
        case 13: c.max_edge_error=nan
        }
        append(&configs,c)
    }
    for c in configs {
        testing.expect_value(t,nav_build_tile(c,{},test_input(&m),&scratch,&data),Nav_Build_Status.Invalid)
        testing.expect_value(t,nav_tile_rect(c,{}),math.Aabb{})
    }
    testing.expect_value(t,nav_build_tile(test_config(),{max(i32),0},test_input(&m),&scratch,&data),Nav_Build_Status.Invalid)
    input:=test_input(&m)
    input.indices=m.indices[:5]
    testing.expect_value(t,nav_build_tile(test_config(),{},input,&scratch,&data),Nav_Build_Status.Invalid)
    input=test_input(&m)
    input.vertices=m.vertices[:3]
    testing.expect_value(t,nav_build_tile(test_config(),{},input,&scratch,&data),Nav_Build_Status.Invalid)
    input=test_input(&m)
    input.triangle_areas={1}
    testing.expect_value(t,nav_build_tile(test_config(),{},input,&scratch,&data),Nav_Build_Status.Invalid)
    input.triangle_areas={1,NAV_AREA_MAX+1}
    testing.expect_value(t,nav_build_tile(test_config(),{},input,&scratch,&data),Nav_Build_Status.Invalid)
    volumes:=[1]Nav_Area_Volume{{count=9,area=1}}
    input=test_input(&m,volumes[:])
    testing.expect_value(t,nav_build_tile(test_config(),{},input,&scratch,&data),Nav_Build_Status.Invalid)
    volumes[0]={count=4,area=NAV_AREA_MAX+1}
    testing.expect_value(t,nav_build_tile(test_config(),{},input,&scratch,&data),Nav_Build_Status.Invalid)
    testing.expect_value(t,nav_build_tile(test_config(),{},test_input(&m),nil,&data),Nav_Build_Status.Invalid)
    testing.expect_value(t,nav_build_tile(test_config(),{},test_input(&m),&scratch,nil),Nav_Build_Status.Invalid)
    testing.expect(t,data.block==nil)
}

@(test)
triangle_areas_mark_their_triangles :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_plane(&m,0.5,0.5,4,7.5,0)
    test_plane(&m,4,0.5,7.5,7.5,0)
    areas:=[4]u8{3,3,NAV_AREA_BLOCKED,NAV_AREA_BLOCKED}
    input:=test_input(&m)
    input.triangle_areas=areas[:]
    scratch:Nav_Build_Scratch
    nav_build_scratch_init(&scratch)
    defer nav_build_scratch_destroy(&scratch)
    data:Nav_Tile_Data
    testing.expect_value(t,nav_build_tile(test_config(),{},input,&scratch,&data),Nav_Build_Status.Built)
    defer nav_tile_data_free(&data)
    test_check_tile(t,&data)
    left:=test_find_poly(&data,{2,0,4})
    testing.expect(t,left>=0 && data.polys[left].area==3)
    testing.expect(t,test_find_poly(&data,{6,0,4})<0)
}

@(test)
zero_scratch_and_tile_data_are_safe :: proc(t:^testing.T) {
    m:Test_Mesh
    defer test_mesh_destroy(&m)
    test_plane(&m,0,0,8,8,0)
    scratch:Nav_Build_Scratch
    data:Nav_Tile_Data
    testing.expect_value(t,nav_build_tile(test_config(),{},test_input(&m),&scratch,&data),Nav_Build_Status.Invalid)
    testing.expect(t,data.block==nil)
    nav_build_scratch_destroy(&scratch)
    nav_build_scratch_destroy(nil)
    nav_build_scratch_init(nil)
    nav_tile_data_free(&data)
    testing.expect_value(t,nav_tile_rect({},{}),math.Aabb{})
    testing.expect_value(t,nav_build_margin({}),0)
    testing.expect_value(t,nav_build_margin(test_config()),5*test_config().cell_size)
    // A failing allocator gives Out_Of_Memory and leaves out empty.
    nav_build_scratch_init(&scratch,runtime.nil_allocator())
    testing.expect(t,scratch.allocator.procedure!=nil)
    testing.expect_value(t,nav_build_tile(test_config(),{},test_input(&m),&scratch,&data),Nav_Build_Status.Out_Of_Memory)
    nav_build_scratch_destroy(&scratch)
    nav_build_scratch_init(&scratch)
    defer nav_build_scratch_destroy(&scratch)
    testing.expect_value(t,nav_build_tile(test_config(),{},test_input(&m),&scratch,&data,runtime.nil_allocator()),Nav_Build_Status.Out_Of_Memory)
    testing.expect(t,data.block==nil)
    // So does the memory of the scratch and of the tile ending at each request in turn.
    Served :: struct {owner:runtime.Allocator,remaining:int}
    served:=Served{owner=context.allocator}
    limited:=runtime.Allocator{proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        s:=(^Served)(data)
        if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
            if s.remaining<=0 {return nil,.Out_Of_Memory}
            s.remaining-=1
        }
        return s.owner.procedure(s.owner.data,mode,size,alignment,old_memory,old_size,loc)
    },&served}
    built,refused:=false,false
    for requests in 0..<4096 {
        starved:Nav_Build_Scratch
        nav_build_scratch_init(&starved,limited)
        served.remaining=requests
        status:=nav_build_tile(test_config(),{},test_input(&m),&starved,&data,limited)
        served.remaining=max(int)
        built=status==.Built
        if !built {
            refused=true
            testing.expectf(t,status==.Out_Of_Memory && data.block==nil,"a tile with %d requests served: %v",requests,status)
        }
        nav_tile_data_free(&data)
        nav_build_scratch_destroy(&starved)
        if built {break}
    }
    testing.expect(t,built && refused)
}
