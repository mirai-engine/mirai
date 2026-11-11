package mirai_physics

import "core:testing"
import cmath "core:math"

@(private) TETRAHEDRON_VERTICES :: [4]Vec3{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
@(private) TETRAHEDRON_COUNTS :: [4]u8{3,3,3,3}
@(private) TETRAHEDRON_INDICES :: [12]u8{0,2,1, 0,1,3, 0,3,2, 1,2,3}

// A prism with a regular polygon as its cross section, along Y.
@(private)
test_prism :: proc(w:^World,sides:int,radius,half_height:f32) -> (Hull_Handle,bool) {
    vertices:[32]Vec3
    counts:[18]u8
    indices:[128]u8
    cursor:=0
    for i in 0..<sides {
        angle:=2*cmath.PI*f32(i)/f32(sides)
        vertices[2*i]={radius*cmath.cos(angle),-half_height,radius*cmath.sin(angle)}
        vertices[2*i+1]={radius*cmath.cos(angle),half_height,radius*cmath.sin(angle)}
        next:=(i+1)%sides
        counts[i]=4
        indices[cursor],indices[cursor+1],indices[cursor+2],indices[cursor+3]=u8(2*i),u8(2*i+1),u8(2*next+1),u8(2*next)
        cursor+=4
    }
    counts[sides],counts[sides+1]=u8(sides),u8(sides)
    for i in 0..<sides {
        indices[cursor+i]=u8(2*i)
        indices[cursor+sides+i]=u8(2*(sides-1-i)+1)
    }
    cursor+=2*sides
    return hull_create(w,{vertices[:2*sides],counts[:sides+2],indices[:cursor]})
}

@(test)
hulls_must_be_closed_and_convex :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    vertices:=TETRAHEDRON_VERTICES
    counts:=TETRAHEDRON_COUNTS
    indices:=TETRAHEDRON_INDICES
    hull,ok:=hull_create(&w,{vertices[:],counts[:],indices[:]})
    testing.expect(t,ok)
    slot,_:=hull_slot(&w,hull)
    expect_near(t,slot.hull.volume,1.0/6,1e-5)
    expect_near3(t,slot.hull.center,{0.25,0.25,0.25},1e-5)
    testing.expect_value(t,len(slot.hull.edges),12)
    // An open surface, an inside-out one and one with an edge used twice are refused.
    _,open:=hull_create(&w,{vertices[:],counts[:3],indices[:9]})
    testing.expect(t,!open)
    inverted:=[12]u8{0,1,2, 0,3,1, 0,2,3, 1,3,2}
    _,inside_out:=hull_create(&w,{vertices[:],counts[:],inverted[:]})
    testing.expect(t,!inside_out)
    repeated:=[12]u8{0,2,1, 0,2,1, 0,3,2, 1,2,3}
    _,twice:=hull_create(&w,{vertices[:],counts[:],repeated[:]})
    testing.expect(t,!twice)
    // A dent makes a vertex stick out of another face.
    dented:=[5]Vec3{{0,0,0},{1,0,0},{0,1,0},{0,0,1},{0.1,0.1,0.1}}
    dent_counts:=[6]u8{3,3,3,3,3,3}
    dent_indices:=[18]u8{0,2,1, 0,1,3, 0,3,2, 1,2,4, 2,3,4, 3,1,4}
    _,concave:=hull_create(&w,{dented[:],dent_counts[:],dent_indices[:]})
    testing.expect(t,!concave)
    // A hull in use cannot be destroyed.
    body:=body_create(&w,BODY_DESC_DEFAULT)
    desc:=SHAPE_DESC_DEFAULT
    desc.geometry=hull
    shape:=shape_create(&w,body,desc)
    testing.expect(t,shape!={})
    testing.expect(t,!hull_destroy(&w,hull))
    shape_destroy(&w,shape)
    testing.expect(t,hull_destroy(&w,hull))
    testing.expect(t,!hull_destroy(&w,hull))
    desc.geometry=hull
    testing.expect_value(t,shape_create(&w,body,desc),Shape_Handle{})
}

@(test)
a_box_shaped_hull_has_the_mass_of_a_box :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    storage:Box_Hull
    view:=box_hull(&storage,{0.5,1,2})
    counts:=BOX_FACE_COUNTS
    indices:=BOX_FACE_INDICES
    hull,ok:=hull_create(&w,{view.vertices,counts[:],indices[:]})
    testing.expect(t,ok)
    slot,_:=hull_slot(&w,hull)
    for edge,i in slot.hull.edges {testing.expect_value(t,edge,view.edges[i])}
    expect_near(t,slot.hull.inner_radius,0.5,1e-5)
    a:=body_create(&w,BODY_DESC_DEFAULT)
    b:=body_create(&w,BODY_DESC_DEFAULT)
    desc:=SHAPE_DESC_DEFAULT
    desc.transform={{1,2,3},q_axis_angle(normalize(Vec3{1,2,3}),0.7)}
    desc.geometry=hull
    shape_create(&w,a,desc)
    desc.geometry=Box{{0.5,1,2}}
    shape_create(&w,b,desc)
    mass_a,center_a,inertia_a:=body_mass_properties(&w,a)
    mass_b,center_b,inertia_b:=body_mass_properties(&w,b)
    expect_near(t,mass_a,mass_b,0.01)
    expect_near3(t,center_a,center_b,1e-4)
    for i in 0..<3 {
        for j in 0..<3 {expect_near(t,inertia_a[i,j],inertia_b[i,j],1e-3*mass_b)}
    }
}

@(test)
hull_bodies_rest_on_boxes_and_on_each_other :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    prism,ok:=test_prism(&w,8,0.5,0.4)
    testing.expect(t,ok)
    bodies:[4]Body_Handle
    for i in 0..<4 {bodies[i]=test_body(&w,prism,{0,0.41+f32(i)*0.81,0})}
    ball:=test_body(&w,Sphere{0.3},{3,0.35,0})
    resting:=test_body(&w,prism,{3,-5,0},.Static)
    body_set_transform(&w,resting,{3,-0.4,0},QUAT_IDENTITY)
    capsule:=test_body(&w,Capsule{0.2,0.3},{6,2,0})
    plinth:=test_body(&w,prism,{6,0.5,0})
    test_steps(&w,300)
    for body,i in bodies {
        testing.expect(t,!body_is_awake(&w,body))
        expect_near3(t,body_position(&w,body),{0,0.4+f32(i)*0.8,0},0.03)
    }
    expect_near3(t,body_position(&w,ball),{3,0.3,0},0.02)
    expect_near(t,body_position(&w,plinth).y,0.4,0.02)
    testing.expect(t,body_position(&w,capsule).y>0.15)
    testing.expect(t,!body_is_awake(&w,capsule))
}

// A flat square grid of triangles around the origin, `cells` per side, with an optional height function.
@(private)
// dirty: each cell also repeats a triangle from another corner and has three corners in a row, of no area.
test_grid_mesh :: proc(w:^World,cells:int,size:f32,height:proc(x,z:f32)->f32=nil,dirty:=false) -> (Mesh_Handle,bool) {
    vertices:=make([]Vec3,(cells+1)*(cells+1),context.temp_allocator)
    indices:=make([dynamic]u32,0,12*cells*cells,context.temp_allocator)
    for row in 0..=cells {
        for column in 0..=cells {
            x,z:=(f32(column)/f32(cells)-0.5)*size,(f32(row)/f32(cells)-0.5)*size
            vertices[row*(cells+1)+column]={x,height==nil?0:height(x,z),z}
        }
    }
    for row in 0..<cells {
        for column in 0..<cells {
            a:=u32(row*(cells+1)+column)
            b:=a+1
            c:=a+u32(cells+1)
            d:=c+1
            append(&indices,a,c,b, b,c,d)
            if dirty {append(&indices,c,b,a, a,b,a)}
            if dirty && column+2<=cells {append(&indices,a,b,b+1)}
        }
    }
    return mesh_create(w,{vertices=vertices,indices=indices[:]})
}

@(test)
slivers_and_repeats_of_a_mesh_are_dropped_and_its_real_edges_stay :: proc(t:^testing.T) {
    // A table top and its front, split at m under the edge a-b: a sliver a,b,m closes the seam.
    a,b,m,e,f,c,d:u32=0,1,2,3,4,5,6
    vertices:=[7]Vec3{{0,0,0},{2,0,0},{1,0,0},{0,0,-1},{2,0,-1},{0,-1,0},{2,-1,0}}
    top:=[]u32{a,b,f, a,f,e}
    front:=[]u32{c,d,m, c,m,a, d,b,m}
    dirt:=[]u32{a,b,m, b,f,a, a,a,b}
    indices:=make([dynamic]u32,context.temp_allocator)
    append(&indices,..top)
    append(&indices,..dirt[:3])
    append(&indices,..front)
    append(&indices,..dirt[3:])
    edge_hit :: proc(mesh:^Mesh,from,to:u32) -> (hit:bool,found:bool) {
        for triangle,at in mesh.triangles {
            for k in 0..<3 {
                p,q:=triangle[k],triangle[(k+1)%3]
                if p==from && q==to || p==to && q==from {return mesh.flags[at]>>u32(k)&1==1,true}
            }
        }
        return
    }
    for inside_out in ([2]bool{false,true}) {
        mesh:Mesh
        if !testing.expect(t,mesh_build(&mesh,{vertices[:],indices[:],nil,inside_out},context.allocator)) {return}
        defer mesh_release(&mesh,context.allocator)
        testing.expect_value(t,len(mesh.triangles),5)
        for edge in ([?][3]u32{{a,b,1},{a,m,1},{m,b,1},{a,f,0}}) {
            hit,found:=edge_hit(&mesh,edge[0],edge[1])
            testing.expectf(t,found && hit==(edge[2]==1),"edge %v-%v of the mesh turned %v: hit %v",edge[0],edge[1],inside_out,hit)
        }
        triangle:=mesh.triangles[0]
        n:=cross(vertices[triangle[1]]-vertices[triangle[0]],vertices[triangle[2]]-vertices[triangle[0]])
        testing.expectf(t,(n.y>0 || n.z>0)!=inside_out,"turned %v, a triangle faces %v",inside_out,n)
    }
}

@(private)
test_static_shape :: proc(w:^World,geometry:Geometry,position:Vec3={}) -> Body_Handle {
    body:=body_create(w,{type=.Static,position=position})
    desc:=SHAPE_DESC_DEFAULT
    desc.geometry=geometry
    shape_create(w,body,desc)
    return body
}

@(test)
meshes_are_validated_and_shared :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    vertices:=[3]Vec3{{0,0,0},{0,0,1},{1,0,0}}
    bad:=[3]u32{0,1,7}
    _,out_of_range:=mesh_create(&w,{vertices=vertices[:],indices=bad[:]})
    testing.expect(t,!out_of_range)
    _,empty:=mesh_create(&w,{vertices=vertices[:]})
    testing.expect(t,!empty)
    mesh,ok:=test_grid_mesh(&w,4,8)
    testing.expect(t,ok)
    slot,_:=mesh_slot(&w,mesh)
    testing.expect_value(t,len(slot.mesh.triangles),32)
    // On a flat grid only the border edges can be hit.
    border:=0
    for flags in slot.mesh.flags {
        for e in 0..<3 {border+=int(flags>>u32(e)&1)}
    }
    testing.expect_value(t,border,16)
    ground:=test_static_shape(&w,mesh)
    testing.expect(t,!mesh_destroy(&w,mesh))
    body_destroy(&w,ground)
    testing.expect(t,mesh_destroy(&w,mesh))
    for _ in 0..<4 {
        _,created:=test_grid_mesh(&w,1,1)
        testing.expect(t,created)
    }
    _,full:=test_grid_mesh(&w,1,1)
    testing.expect(t,!full)
    testing.expect_value(t,world_stats(&w).geometry_capacity_exhausted,1)
}

@(test)
shapes_rest_on_a_triangle_mesh :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    mesh,ok:=test_grid_mesh(&w,8,16)
    testing.expect(t,ok)
    test_static_shape(&w,mesh)
    sphere:=test_body(&w,Sphere{0.5},{0.3,1,0.2})
    box:=test_body(&w,Box{{0.5,0.5,0.5}},{3,0.7,0.4})
    capsule:=test_body(&w,Capsule{0.3,0.5},{-3,0.5,0})
    body_set_transform(&w,capsule,{-3,0.5,0.3},q_axis_angle({0,0,1},cmath.PI/2))
    prism,_:=test_prism(&w,6,0.5,0.3)
    hull:=test_body(&w,prism,{0.2,0.5,4})
    stack:=test_body(&w,Box{{0.4,0.4,0.4}},{3,1.8,0.4})
    test_steps(&w,300)
    expect_near3(t,body_position(&w,sphere),{0.3,0.5,0.2},0.02)
    expect_near3(t,body_position(&w,box),{3,0.5,0.4},0.02)
    expect_near3(t,body_position(&w,capsule),{-3,0.3,0.3},0.03)
    expect_near3(t,body_position(&w,hull),{0.2,0.3,4},0.02)
    expect_near3(t,body_position(&w,stack),{3,1.4,0.4},0.03)
    for body in ([5]Body_Handle{sphere,box,capsule,hull,stack}) {testing.expect(t,!body_is_awake(&w,body))}
    // Below the surface nothing holds: the triangles face up only.
    under:=test_body(&w,Sphere{0.3},{5,-1,5})
    test_steps(&w,60)
    testing.expect(t,body_position(&w,under).y<-2)
}

@(test)
sliding_over_inner_edges_of_a_flat_mesh_does_not_bump :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w,contacts=512))
    defer world_destroy(&w)
    mesh,ok:=test_grid_mesh(&w,40,40,dirty=true)
    testing.expect(t,ok)
    test_static_shape(&w,mesh)
    box:=test_body(&w,Box{{0.3,0.3,0.3}},{-15,0.3,0.13},friction=0)
    ball:=test_body(&w,Sphere{0.3},{-15,0.3,3.21},friction=0)
    capsule:=test_body(&w,Capsule{0.2,0.4},{-15,0.2,-3.3},friction=0)
    body_set_transform(&w,capsule,{-15,0.2,-3.3},q_axis_angle({0,0,1},cmath.PI/2))
    for body in ([3]Body_Handle{box,ball,capsule}) {
        body_set_velocity(&w,body,{6,0,1.5},{})
        body_set_sleep_disabled(&w,body,true)
    }
    test_steps(&w,30)
    for _ in 0..<240 {
        world_step(&w,1.0/60)
        for body in ([3]Body_Handle{box,ball,capsule}) {
            v:=body_linear_velocity(&w,body)
            testing.expectf(t,abs(v.y)<0.02 && abs(v.x-6)<0.02 && abs(v.z-1.5)<0.02,"an inner edge deflected body %v at %v: %v",body,body_position(&w,body),v)
        }
    }
    expect_near(t,body_position(&w,box).y,0.3,0.01)
    testing.expect(t,abs(body_rotation(&w,box).w)>0.9999)
}

@(test)
a_mesh_corner_holds_a_box_from_three_sides :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    // A floor and two walls meeting at the origin, facing +x, +y and +z.
    vertices:=[7]Vec3{{0,0,0},{4,0,0},{0,4,0},{0,0,4},{4,0,4},{4,4,0},{0,4,4}}
    indices:=[18]u32{0,3,4, 0,4,1, 0,1,5, 0,5,2, 0,2,6, 0,6,3}
    mesh,ok:=mesh_create(&w,{vertices=vertices[:],indices=indices[:]})
    testing.expect(t,ok)
    test_static_shape(&w,mesh)
    world_set_gravity(&w,{-6,-6,-6})
    box:=test_body(&w,Box{{0.5,0.5,0.5}},{0.8,0.9,0.7},friction=0)
    test_steps(&w,240)
    expect_near3(t,body_position(&w,box),{0.5,0.5,0.5},0.02)
    testing.expect(t,!body_is_awake(&w,box))
    // A wall stops a body that slides into it.
    world_set_gravity(&w,{0,-9.81,0})
    slider:=test_body(&w,Box{{0.3,0.3,0.3}},{3,0.3,2},friction=0.2)
    body_set_velocity(&w,slider,{-6,0,0},{})
    test_steps(&w,120)
    expect_near(t,body_position(&w,slider).x,0.31,0.02)
}

@(private)
test_heights :: proc(w:^World,columns,rows:int,cell:Vec3,height:proc(column,row:int)->f32) -> (Heightfield_Handle,bool) {
    heights:=make([]f32,columns*rows,context.temp_allocator)
    for row in 0..<rows {
        for column in 0..<columns {heights[row*columns+column]=height(column,row)}
    }
    return heightfield_create(w,{heights=heights,columns=columns,rows=rows,cell=cell})
}

@(test)
heightfields_are_validated :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    heights:=[6]f32{0,0,0,0,0,0}
    _,wrong_count:=heightfield_create(&w,{heights=heights[:],columns=3,rows=3,cell={1,1,1}})
    testing.expect(t,!wrong_count)
    _,flat_cell:=heightfield_create(&w,{heights=heights[:],columns=3,rows=2,cell={1,1,0}})
    testing.expect(t,!flat_cell)
    _,one_row:=heightfield_create(&w,{heights=heights[:],columns=6,rows=1,cell={1,1,1}})
    testing.expect(t,!one_row)
    _,overflow:=heightfield_create(&w,{heights=heights[:],columns=max(int),rows=2,cell={1,1,1}})
    testing.expect(t,!overflow)
    _,infinite_cell:=heightfield_create(&w,{heights=heights[:],columns=3,rows=2,cell={max(f32),1,max(f32)}})
    testing.expect(t,!infinite_cell)
    field,ok:=heightfield_create(&w,{heights=heights[:],columns=3,rows=2,cell={1,1,1}})
    testing.expect(t,ok)
    body:=test_static_shape(&w,field)
    testing.expect(t,!heightfield_destroy(&w,field))
    body_destroy(&w,body)
    testing.expect(t,heightfield_destroy(&w,field))
}

@(test)
heightfield_cells_keep_the_cross_diagonal_and_capacity_can_be_reused :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    heights:=[4]f32{0,0,0,2}
    field,ok:=heightfield_create(&w,{heights=heights[:],columns=2,rows=2,cell={1,1,1}})
    testing.expect(t,ok)
    body:=test_static_shape(&w,field)
    for point in ([2]Vec3{{0.25,0,0.25},{0.75,1,0.75}}) {
        hit,hit_ok:=ray_cast_closest(&w,{point.x,4,point.z},{0,-8,0})
        testing.expect(t,hit_ok)
        expect_near(t,hit.point.y,point.y,1e-5)
    }
    next,next_ok:=heightfield_create(&w,{heights=heights[:],columns=2,rows=2,cell={1,1,1}})
    testing.expect(t,next_ok)
    refused,refused_ok:=heightfield_create(&w,{heights=heights[:],columns=2,rows=2,cell={1,1,1}})
    testing.expect(t,!refused_ok && refused=={})
    testing.expect_value(t,world_stats(&w).geometry_capacity_exhausted,1)
    body_destroy(&w,body)
    testing.expect(t,heightfield_destroy(&w,field))
    replacement,replacement_ok:=heightfield_create(&w,{heights=heights[:],columns=2,rows=2,cell={1,1,1}})
    testing.expect(t,replacement_ok && replacement!=field)
    testing.expect(t,!heightfield_destroy(&w,field))
    testing.expect(t,heightfield_destroy(&w,next))
    testing.expect(t,heightfield_destroy(&w,replacement))
}

@(test)
mesh_edge_masks_follow_original_triangles_after_bvh_ordering :: proc(t:^testing.T) {
    vertices:[48]Vec3
    indices:[48]u32
    masks:[16]u8
    for triangle in 0..<16 {
        x:=f32((15-triangle)*10)
        vertices[3*triangle],vertices[3*triangle+1],vertices[3*triangle+2]={x,0,0},{x,0,1},{x+1,0,0}
        for corner in 0..<3 {indices[3*triangle+corner]=u32(3*triangle+corner)}
        masks[triangle]=u8(triangle%7+1)
    }
    mesh:Mesh
    testing.expect(t,mesh_build(&mesh,{vertices[:],indices[:],masks[:],false},context.allocator))
    defer mesh_release(&mesh,context.allocator)
    for triangle,index in mesh.triangles {
        original:=int(triangle[0])/3
        testing.expect_value(t,mesh.flags[index],u8(7)&~masks[original])
    }
    bad_count:=[1]u8{}
    bad_bits:=[16]u8{};bad_bits[0]=8
    rejected:Mesh
    testing.expect(t,!mesh_build(&rejected,{vertices[:],indices[:],bad_count[:],false},context.allocator))
    testing.expect(t,!mesh_build(&rejected,{vertices[:],indices[:],bad_bits[:],false},context.allocator))
}

@(test)
heightfield_border_masks_are_copied_and_classify_each_segment_independently :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    heights:=[9]f32{}
    borders:=[8]u8{1,0,0,1,1,0,0,1}
    desc:=Heightfield_Desc{heights=heights[:],columns=3,rows=3,cell={1,1,1},disabled_borders=borders[:]}
    field,ok:=heightfield_create(&w,desc)
    testing.expect(t,ok)
    for &value in borders {value=0}
    slot,_:=heightfield_slot(&w,field)
    expected:=[4][2]u8{{0,0},{4,4},{1,2},{0,0}}
    for row in 0..<2 {for column in 0..<2 {
        _,flags,_:=heightfield_cell(&slot.field,column,row)
        testing.expect_value(t,flags,expected[row*2+column])
    }}
    desc.disabled_borders=borders[:1]
    _,bad_count:=heightfield_create(&w,desc)
    testing.expect(t,!bad_count)
    borders[0]=2;desc.disabled_borders=borders[:]
    _,bad_value:=heightfield_create(&w,desc)
    testing.expect(t,!bad_value)
    testing.expect(t,!mesh_edge_active({0,1,0},{0,0,0},{1,0,0},{0,0,1}))
    testing.expect(t,!mesh_edge_active({0,1,0},{0,0,0},{1,0,0},{0,1,1}))
    testing.expect(t,mesh_edge_active({0,1,0},{0,0,0},{1,0,0},{0,-1,1}))
}

@(test)
shapes_rest_on_a_heightfield :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    // A plane that rises along x: y=0.25x after scaling.
    field,ok:=test_heights(&w,33,33,{0.5,0.5,0.5},proc(column,row:int)->f32 {return 0.25*f32(column)})
    testing.expect(t,ok)
    test_static_shape(&w,field,{-8,0,-8})
    slope:=cmath.atan(f32(0.25))
    up:=Vec3{-cmath.sin(slope),cmath.cos(slope),0}
    box:=test_body(&w,Box{{0.4,0.4,0.4}},{})
    on_surface:=Vec3{0.2,2.05,0.1}
    body_set_transform(&w,box,on_surface+up*0.41,q_axis_angle({0,0,1},slope))
    ball:=test_body(&w,Sphere{0.4},Vec3{0.2,2.05,3.1}+up*0.41,friction=0)
    test_steps(&w,90)
    // Friction holds the box on the slope; the frictionless ball slides down along it.
    expect_near3(t,body_position(&w,box),on_surface+up*0.4,0.03)
    p:=body_position(&w,ball)
    testing.expect(t,p.x< -1)
    expect_near(t,p.y,0.25*(p.x+8)+0.4/cmath.cos(slope),0.02)
    expect_near(t,p.z,3.1,0.01)
    // Beyond the border there is nothing.
    out:=test_body(&w,Sphere{0.4},{-12,1,0})
    test_steps(&w,60)
    testing.expect(t,body_position(&w,out).y< -2)
}

@(test)
rolling_over_a_flat_heightfield_does_not_bump :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    field,ok:=test_heights(&w,41,41,{1,1,1},proc(column,row:int)->f32 {return 2})
    testing.expect(t,ok)
    test_static_shape(&w,field,{-20,-2,-20})
    box:=test_body(&w,Box{{0.3,0.3,0.3}},{-15,0.3,0.13},friction=0)
    ball:=test_body(&w,Sphere{0.3},{-15,0.3,3.21},friction=0)
    for body in ([2]Body_Handle{box,ball}) {
        body_set_velocity(&w,body,{6,0,1.5},{})
        body_set_sleep_disabled(&w,body,true)
    }
    test_steps(&w,30)
    for _ in 0..<240 {
        world_step(&w,1.0/60)
        for body in ([2]Body_Handle{box,ball}) {
            v:=body_linear_velocity(&w,body)
            testing.expectf(t,abs(v.y)<0.02 && abs(v.x-6)<0.02 && abs(v.z-1.5)<0.02,"an inner edge deflected body %v at %v: %v",body,body_position(&w,body),v)
        }
    }
}

@(test)
heightfield_holes_have_no_surface_and_keep_their_edges_hittable :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    heights:=[16]f32{}
    // The middle cell of a 3x3 grid of cells is a hole.
    holes:=[9]u8{0,0,0,0,1,0,0,0,0}
    desc:=Heightfield_Desc{heights=heights[:],columns=4,rows=4,cell={1,1,1},holes=holes[:]}
    field,ok:=heightfield_create(&w,desc)
    testing.expect(t,ok)
    holes[4]=0
    slot,_:=heightfield_slot(&w,field)
    _,_,open:=heightfield_cell(&slot.field,1,1)
    testing.expect(t,!open,"the field keeps its own copy of the holes")
    // Flat cells disable their inner edges, except where a hole is across them.
    _,left,_:=heightfield_cell(&slot.field,0,1)
    testing.expect_value(t,left[1]&0b100,u8(0b100))
    _,far,_:=heightfield_cell(&slot.field,0,0)
    testing.expect_value(t,far[1]&0b100,u8(0))
    test_static_shape(&w,field)
    _,through:=ray_cast_closest(&w,{1.5,4,1.5},{0,-8,0})
    testing.expect(t,!through)
    hit,beside:=ray_cast_closest(&w,{0.5,4,1.5},{0,-8,0})
    testing.expect(t,beside && abs(hit.point.y)<1e-5)
    ball:=test_body(&w,Sphere{0.3},{1.5,1,1.5})
    rest:=test_body(&w,Sphere{0.3},{0.5,1,0.5})
    test_steps(&w,90)
    testing.expect(t,body_position(&w,ball).y< -1,"a body falls through the hole")
    expect_near(t,body_position(&w,rest).y,0.3,0.02)
    desc.holes=holes[:8]
    _,bad_count:=heightfield_create(&w,desc)
    testing.expect(t,!bad_count)
    holes[0]=2;desc.holes=holes[:]
    _,bad_value:=heightfield_create(&w,desc)
    testing.expect(t,!bad_value)
}


@(test)
a_ball_rests_on_a_ridge_too_flat_to_be_hit :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    // A slope along z with a ridge along it at column 6 whose edges are too flat to be hit, as a terrain
    // has them: over a vertex of the ridge the nearest point is on edges every triangle there leaves to
    // the one across.
    field,ok:=test_heights(&w,13,13,{1.0/12,1,1.0/12},proc(column,row:int)->f32 {return 1+(0.13*f32(row)-0.011*abs(f32(column-6)))/12})
    testing.expect(t,ok)
    test_static_shape(&w,field,{})
    ground:=f32(1+0.13*6.0/12)
    for radius in ([3]f32{0.08,0.2,0.6}) {
        ball:=test_body(&w,Sphere{radius},{0.5,ground+radius+0.1,0.5})
        test_steps(&w,30)
        p:=body_position(&w,ball)
        testing.expectf(t,p.y>ground+radius-0.05,"a ball of radius %v went through the ridge to %v",radius,p)
        body_destroy(&w,ball)
    }
}
