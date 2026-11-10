package water

import "core:math/linalg"
import "core:testing"
import render "mirai:engine/render"
import geom "mirai:std/geom"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

@(test)
the_surface_grid_faces_up_and_shares_every_edge_between_its_levels :: proc(t:^testing.T) {
    buffer:geom.Mesh_Buffer
    defer geom.mesh_buffer_destroy(&buffer)
    surface_build(&buffer)
    testing.expect(t,len(buffer.indices)>0 && len(buffer.indices)%3==0)
    testing.expect_value(t,len(buffer.normals),len(buffer.positions))
    // Every triangle faces +Y.
    area:f32
    for i:=0;i<len(buffer.indices);i+=3 {
        a,b,c:=buffer.positions[buffer.indices[i]],buffer.positions[buffer.indices[i+1]],buffer.positions[buffer.indices[i+2]]
        n:=geom.Vec3{(b-a).y*(c-a).z-(b-a).z*(c-a).y,(b-a).z*(c-a).x-(b-a).x*(c-a).z,(b-a).x*(c-a).y-(b-a).y*(c-a).x}
        testing.expectf(t,n.y>0,"triangle %d faces %v",i/3,n)
        area+=0.5*n.y
    }
    // The triangles cover the square of the last level once.
    side:=2*SURFACE_CELL*SURFACE_HALF*f32(1<<u32(SURFACE_LEVELS-1))
    testing.expectf(t,abs(area-side*side)<1e-3*side*side,"covers %v of %v",area,side*side)
    // An edge inside the grid belongs to two triangles, one each way: no level ends inside an edge of another.
    edges:=make(map[[2]u32]int,context.temp_allocator)
    for i:=0;i<len(buffer.indices);i+=3 {
        for k in 0..<3 {
            a,b:=buffer.indices[i+k],buffer.indices[i+(k+1)%3]
            edges[{a,b}]+=1
        }
    }
    border:=0
    for edge,count in edges {
        testing.expect_value(t,count,1)
        if edge.yx not_in edges {border+=1}
    }
    testing.expect_value(t,border,8*SURFACE_HALF)
}

@(test)
a_body_that_enters_the_water_fast_splashes_once_and_a_still_one_does_not :: proc(t:^testing.T) {
    falling:=phys.Fluid_Body{center={1,-0.2,2},velocity={0,-4,0},volume=0.2,whole=1,surface=0,reach=0.8}
    birth,ok:=splash_of(falling,0)
    testing.expect(t,ok)
    testing.expect(t,birth.position=={1,0,2} && birth.velocity.y>0 && birth.count>=4)
    _,ok=splash_of(falling,0.2) // it was in already
    testing.expect(t,!ok)
    slow:=falling
    slow.velocity.y=-0.5
    _,ok=splash_of(slow,0)
    testing.expect(t,!ok)
    floating:=phys.Fluid_Body{center={0,0,0},velocity={0.5,0,0},volume=0.5,whole=1,reach=0.9}
    _,ok=splash_of(floating,0.5)
    testing.expect(t,!ok)
}

// The shaders get the bodies relative to the origin the renderer draws from:
// its box moves by it, and its surface by the height of the origin.
@(test)
the_bodies_go_to_the_shaders_relative_to_the_origin :: proc(t:^testing.T) {
    state:Water_Gpu
    box:=mm.Transform{{-18000.5,-2,9000},1,{40,4,40}}
    state.bodies[0]={to_box=mm.mat4_rows(linalg.inverse(mm.transform_matrix(box))),surface={0,0,0,1}}
    state.count=1
    origin:=[3]f32{-17408,1024,9216}
    got:=bodies_relative(&state,origin)[0]
    testing.expect_value(t,got.surface,[4]f32{-1024,0,0,1})
    testing.expect_value(t,got.to_box,render.origin_from_world(state.bodies[0].to_box,origin))
}

// The waves of a plane go to the shaders measured from the origin of the
// pass: the surface the shaders find there is the one of the physics; and a
// dry box crosses a plane where the waves can be.
@(test)
the_waves_go_to_the_shaders_from_the_origin_and_dry_boxes_cut_the_planes_they_cross :: proc(t:^testing.T) {
    state:Water_Gpu
    state.waves[0].waves[0]={direction={0.6,0.8},length=14,amplitude=0.5,speed=4.7,phase=1}
    state.waves[0].count,state.waves[0].steepness=1,0.7
    state.bodies[0]={surface={2,1,0,0}}
    room:=mm.Transform{{30,1.5,0},1,{6,4,6}}
    state.bodies[1]={to_box=mm.mat4_rows(linalg.inverse(mm.transform_matrix(room))),surface={3.5,0,1,1}}
    deep:=mm.Transform{{30,-20,0},1,{6,4,6}}
    state.bodies[2]={to_box=mm.mat4_rows(linalg.inverse(mm.transform_matrix(deep))),surface={-18,0,1,1}}
    state.count,state.time=3,123.5
    origin:=[3]f32{-17408,1024,9216}
    got:=bodies_relative(&state,origin)
    terms,count:=phys.wave_terms(&state.waves[0],state.time,{f64(origin.x),f64(origin.z)})
    testing.expect_value(t,count,1)
    testing.expect_value(t,got[0].waves[0],[4]f32{terms[0].k.x,terms[0].k.y,terms[0].amplitude,terms[0].across})
    testing.expect_value(t,got[0].phases[0][0],terms[0].phase)
    testing.expect_value(t,got[0].surface.x,f32(2-1024))
    floor,top:=dry_span(state.bodies[1])
    testing.expect(t,abs(floor+0.5)<1e-4 && abs(top-3.5)<1e-4)
    testing.expect(t,dry_crosses(&state,1,0) && crosses_plane(&state,1))
    testing.expect(t,!dry_crosses(&state,2,0),"a dry box deep under the waves")
    testing.expect(t,!dry_crosses(&state,0,1),"a plane is not a dry box")
}
