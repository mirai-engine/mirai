package mirai_physics

import "core:testing"
import "core:fmt"

@(test)
box_topology_table_matches_the_builder :: proc(t:^testing.T) {
    counts:=BOX_FACE_COUNTS
    indices:=BOX_FACE_INDICES
    edges:[24]Half_Edge
    face_edges:[6]u16
    testing.expect(t,hull_topology_build(8,counts[:],indices[:],edges[:],face_edges[:]))
    if edges!=BOX_EDGES || face_edges!=BOX_FACE_EDGES {
        fmt.println("BOX",edges,face_edges)
        testing.fail(t)
    }
    tri_counts:=[2]u8{3,3}
    tri_indices:=[6]u8{0,1,2, 0,2,1}
    tri_edges:[6]Half_Edge
    tri_face_edges:[2]u16
    testing.expect(t,hull_topology_build(3,tri_counts[:],tri_indices[:],tri_edges[:],tri_face_edges[:]))
    if tri_edges!=TRIANGLE_EDGES || tri_face_edges!=TRIANGLE_FACE_EDGES {
        fmt.println("TRI",tri_edges,tri_face_edges)
        testing.fail(t)
    }
}

// A cube hull scaled along its axes is the box it scales to, for the bounds, the mass, rays and what rests
// on it, and many shapes share the one hull at their own scales.
@(test)
a_hull_scaled_along_its_axes_is_the_box_it_scales_to :: proc(t:^testing.T) {
    w:World
    if !testing.expect(t,test_world(&w)) {return}
    defer world_destroy(&w)
    cube:[8]Vec3
    for &v,i in cube {v={i&1!=0?0.5:-0.5,i&2!=0?0.5:-0.5,i&4!=0?0.5:-0.5}}
    counts,indices:=BOX_FACE_COUNTS,BOX_FACE_INDICES
    hull,made:=hull_create(&w,{cube[:],counts[:],indices[:]})
    if !testing.expect(t,made) {return}
    scale:=Vec3{4,0.5,2}
    scaled:=SHAPE_DESC_DEFAULT
    scaled.geometry,scaled.scale=hull,scale
    box:=SHAPE_DESC_DEFAULT
    box.geometry=Box{scale*0.5}
    // Bounds and mass, of a dynamic body of each.
    a,b:=body_create(&w,BODY_DESC_DEFAULT),body_create(&w,BODY_DESC_DEFAULT)
    sa,sb:=shape_create(&w,a,scaled),shape_create(&w,b,box)
    expect_near3(t,shape_bounds(&w,sa).max,shape_bounds(&w,sb).max,1e-4)
    mass_a,_,inertia_a:=body_mass_properties(&w,a)
    mass_b,_,inertia_b:=body_mass_properties(&w,b)
    expect_near(t,mass_a,mass_b,1e-2)
    for i in 0..<3 {expect_near(t,inertia_a[i,i],inertia_b[i,i],1e-1)}
    body_destroy(&w,a);body_destroy(&w,b)
    // A static floor of each, far apart: a ray meets them alike, and a falling box rests on them alike.
    floors:=[2]Vec3{{0,0,0},{20,0,0}}
    for p,i in floors {
        desc:=BODY_DESC_DEFAULT
        desc.type,desc.position=.Static,p
        floor:=body_create(&w,desc)
        shape_create(&w,floor,i==0?scaled:box)
    }
    for p in floors {
        hit,found:=ray_cast_closest(&w,p+{1.5,3,0.8},{0,-10,0})
        testing.expect(t,found)
        expect_near(t,hit.point.y,0.25,1e-4)
        expect_near3(t,hit.normal,{0,1,0},1e-4)
    }
    side,found:=ray_cast_closest(&w,{-5,0,0.3},{5,0,0})
    testing.expect(t,found && abs(side.point.x+2)<1e-4 && length(side.normal-Vec3{-1,0,0})<1e-4,"its side 2 m out")
    falling:[2]Body_Handle
    for p,i in floors {falling[i]=test_body(&w,Box{{0.2,0.2,0.2}},p+{1,1,0.5})}
    // A scaled hull falls and rests on the ground too.
    test_ground(&w,{50,0.5,50})
    dropped:=SHAPE_DESC_DEFAULT
    dropped.geometry,dropped.scale=hull,Vec3{1,0.4,1}
    desc:=BODY_DESC_DEFAULT
    desc.position={-10,2,0}
    piece:=body_create(&w,desc)
    shape_create(&w,piece,dropped)
    test_steps(&w,180)
    expect_near(t,body_position(&w,falling[0]).y,body_position(&w,falling[1]).y,1e-2)
    expect_near(t,body_position(&w,falling[0]).y,0.45,2e-2)
    expect_near(t,body_position(&w,piece).y,0.2,2e-2)
    // A scale at or below zero is refused.
    scaled.scale={1,0,1}
    testing.expect(t,shape_create(&w,piece,scaled)=={})
}
