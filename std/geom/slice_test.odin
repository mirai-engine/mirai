package geom

import "core:testing"
import "mirai:std/base"
import mm "mirai:std/math"

@(private) test_quad :: proc(b:^Mesh_Buffer,p0,p1,p2,p3:Vec3) {
    base:=u32(len(b.positions))
    a,c:=dvec(p1)-dvec(p0),dvec(p3)-dvec(p0)
    n:=fvec(dnormalize(dcross(a,c)))
    for p,i in ([4]Vec3{p0,p1,p2,p3}) {
        append(&b.positions,p)
        append(&b.normals,n)
        append(&b.uvs,Vec2{f32(i&1~(i>>1)),f32(i>>1)})
    }
    append(&b.indices,base,base+1,base+2,base,base+2,base+3)
    append(&b.materials,0,0)
}

// Square ring around the Y axis: outer half-size 2, hole half-size 1, height 1.
@(private) test_frame :: proc(b:^Mesh_Buffer) {
    ring:=[4]Vec2{{1,1},{1,-1},{-1,-1},{-1,1}}
    for i in 0..<4 {
        a,c:=ring[i],ring[(i+1)%4]
        o0,o1:=Vec3{a.x*2,0,a.y*2},Vec3{c.x*2,0,c.y*2}
        i0,i1:=Vec3{a.x,0,a.y},Vec3{c.x,0,c.y}
        up,down:=Vec3{0,0.5,0},Vec3{0,-0.5,0}
        test_quad(b,o0+up,o1+up,i1+up,i0+up)
        test_quad(b,o1+down,o0+down,i0+down,i1+down)
        test_quad(b,o0+down,o1+down,o1+up,o0+up)
        test_quad(b,i1+down,i0+down,i0+up,i1+up)
    }
}

@(private) Slice_Rig :: struct {slicer:Slicer,mesh,front,back:Mesh_Buffer}
@(private) slice_rig_init :: proc(r:^Slice_Rig) {
    slicer_init(&r.slicer)
    mesh_buffer_init(&r.mesh);mesh_buffer_init(&r.front);mesh_buffer_init(&r.back)
}
@(private) slice_rig_destroy :: proc(r:^Slice_Rig) {
    slicer_destroy(&r.slicer)
    mesh_buffer_destroy(&r.mesh);mesh_buffer_destroy(&r.front);mesh_buffer_destroy(&r.back)
}

@(private) expect_closed :: proc(t:^testing.T,b:^Mesh_Buffer,what:string,loc:=#caller_location) {
    topology:=mesh_topology(b.positions[:],b.indices[:])
    testing.expectf(t,mesh_topology_is_closed(topology),"%s is not closed: %v",what,topology,loc=loc)
    testing.expectf(t,mesh_is_valid(mesh_buffer_view(b)),"%s has inconsistent streams",what,loc=loc)
}

@(private) buffer_volume :: proc(b:^Mesh_Buffer) -> f32 {return mesh_volume(b.positions[:],b.indices[:])}

@(test)
slice_halves_a_box_into_two_closed_boxes :: proc(t:^testing.T) {
    r:Slice_Rig
    slice_rig_init(&r)
    defer slice_rig_destroy(&r)
    test_box(&r.mesh,{-1,-1,-1},{1,1,1},5)
    result,error:=mesh_slice(&r.slicer,mesh_buffer_view(&r.mesh),{{0,1,0},0.5},&r.front,&r.back,{cap_material=9,cap_uv_scale=2})
    testing.expect_value(t,error,Slice_Error.None)
    testing.expect_value(t,result.open_edges,0)
    expect_closed(t,&r.front,"front")
    expect_closed(t,&r.back,"back")
    testing.expectf(t,abs(buffer_volume(&r.front)-2)<1e-5,"front volume %v",buffer_volume(&r.front))
    testing.expectf(t,abs(buffer_volume(&r.back)-6)<1e-5,"back volume %v",buffer_volume(&r.back))
    for side,k in ([2]Slice_Side{result.front,result.back}) {
        out:=&r.front if k==0 else &r.back
        testing.expect_value(t,side.triangles,len(out.indices)/3)
        testing.expect_value(t,side.cap_first+side.cap_triangles,side.triangles)
        testing.expect(t,side.cap_triangles>=2)
        testing.expectf(t,abs(side.cap_area-4)<1e-5,"cap area %v",side.cap_area)
        testing.expect_value(t,len(r.slicer.sources[k]),side.triangles)
        for triangle in 0..<side.triangles {
            cap:=triangle>=side.cap_first
            testing.expect_value(t,out.materials[triangle],u32(9) if cap else u32(5))
            testing.expect_value(t,r.slicer.sources[k][triangle]==SLICE_CAP,cap)
            if !cap {continue}
            // Caps face the other side, with planar coordinates in cut units.
            for c in 0..<3 {
                v:=out.indices[triangle*3+c]
                testing.expect_value(t,out.positions[v].y,0.5)
                testing.expect_value(t,out.normals[v],Vec3{0,-1,0} if k==0 else Vec3{0,1,0})
                testing.expect_value(t,out.uvs[v],Vec2{out.positions[v].z*2,out.positions[v].x*2})
            }
            a,b,c:=out.positions[out.indices[triangle*3]],out.positions[out.indices[triangle*3+1]],out.positions[out.indices[triangle*3+2]]
            normal:=dcross(dvec(b)-dvec(a),dvec(c)-dvec(a))
            testing.expect(t,(normal.y<0)==(k==0) && normal.y!=0)
        }
    }
}

@(test)
slice_interpolates_attributes_along_the_cut_edges :: proc(t:^testing.T) {
    r:Slice_Rig
    slice_rig_init(&r)
    defer slice_rig_destroy(&r)
    test_box(&r.mesh,{0,0,0},{4,1,1})
    for p in r.mesh.positions {append(&r.mesh.colors,Vec4{p.x/4,p.y,p.z,1})}
    for &uv,i in r.mesh.uvs {uv={r.mesh.positions[i].x*10,r.mesh.positions[i].y}}
    result,_:=mesh_slice(&r.slicer,mesh_buffer_view(&r.mesh),{{1,0,0},1},&r.front,&r.back)
    for k in 0..<2 {
        out:=&r.front if k==0 else &r.back
        side:=result.front if k==0 else result.back
        testing.expect_value(t,len(out.colors),len(out.positions))
        for triangle in 0..<side.cap_first {
            for c in 0..<3 {
                v:=out.indices[triangle*3+c]
                p:=out.positions[v]
                testing.expectf(t,abs(out.colors[v].x-p.x/4)<1e-6 && abs(out.colors[v].y-p.y)<1e-6,"color %v at %v",out.colors[v],p)
                testing.expectf(t,abs(out.uvs[v].x-p.x*10)<1e-5 && abs(out.uvs[v].y-p.y)<1e-6,"uv %v at %v",out.uvs[v],p)
                testing.expect(t,abs(out.normals[v].x)+abs(out.normals[v].y)+abs(out.normals[v].z)==1)
            }
        }
        for v in out.indices[side.cap_first*3:] {testing.expect_value(t,out.colors[v],Vec4{1,1,1,1})}
    }
}

@(test)
slice_that_misses_or_touches_returns_the_mesh_on_one_side :: proc(t:^testing.T) {
    r:Slice_Rig
    slice_rig_init(&r)
    defer slice_rig_destroy(&r)
    test_box(&r.mesh,{-1,-1,-1},{1,1,1})
    mesh:=mesh_buffer_view(&r.mesh)
    planes:=[?]struct {plane:Plane,front:bool}{
        {{{0,1,0},5},false},{{{0,1,0},-5},true},
        {{{0,1,0},1},false},{{{0,1,0},-1},true},     // on a face
        {{{0,-1,0},1},false},{{{1,1,0},2},false},    // on a face from the other side, on an edge
        {{{1,1,1},3},false},{{{-1,-1,-1},3},false},  // on a corner
    }
    for c in planes {
        result,error:=mesh_slice(&r.slicer,mesh,c.plane,&r.front,&r.back)
        testing.expect_value(t,error,Slice_Error.None)
        whole,empty:=&r.front if c.front else &r.back,&r.back if c.front else &r.front
        testing.expectf(t,len(empty.indices)==0 && len(empty.positions)==0,"plane %v leaves something on the far side",c.plane)
        testing.expectf(t,bytes_equal(whole.positions[:],mesh.positions) && bytes_equal(whole.indices[:],mesh.indices),"plane %v changes the mesh",c.plane)
        testing.expect_value(t,result.front.cap_triangles+result.back.cap_triangles,0)
        testing.expect_value(t,(result.front if c.front else result.back).triangles,12)
    }
    _,error:=mesh_slice(&r.slicer,mesh,{{0,0,0},1},&r.front,&r.back)
    testing.expect_value(t,error,Slice_Error.Invalid_Plane)
    broken:=mesh
    broken.indices=[]u32{0,1,99}
    broken.materials=nil
    _,error=mesh_slice(&r.slicer,broken,{{0,1,0},0},&r.front,&r.back)
    testing.expect_value(t,error,Slice_Error.Invalid_Mesh)
}

@(test)
slice_through_vertices_and_edges_stays_closed :: proc(t:^testing.T) {
    r:Slice_Rig
    slice_rig_init(&r)
    defer slice_rig_destroy(&r)
    test_box(&r.mesh,{-1,-1,-1},{1,1,1})
    mesh:=mesh_buffer_view(&r.mesh)
    // Diagonal planes through four corners, through one corner and through
    // the face diagonals that the triangles use.
    planes:=[?]Plane{{{1,1,0},0},{{1,0,1},0},{{1,-1,0},0},{{1,1,1},0},{{1,1,1},1},{{1,1,-1},-1},{{0,1,1},0},{{2,1,0},1}}
    for plane in planes {
        result,_:=mesh_slice(&r.slicer,mesh,plane,&r.front,&r.back)
        testing.expect_value(t,result.open_edges,0)
        expect_closed(t,&r.front,"front")
        expect_closed(t,&r.back,"back")
        front,back:=buffer_volume(&r.front),buffer_volume(&r.back)
        testing.expectf(t,front>0 && back>0 && abs(front+back-8)<1e-4,"plane %v: volumes %v + %v",plane,front,back)
        testing.expectf(t,abs(result.front.cap_area-result.back.cap_area)<1e-4 && result.front.cap_area>0,"plane %v: cap areas %v and %v",plane,result.front.cap_area,result.back.cap_area)
    }
}

@(test)
slice_caps_a_ring_with_a_hole_and_with_two_loops :: proc(t:^testing.T) {
    r:Slice_Rig
    slice_rig_init(&r)
    defer slice_rig_destroy(&r)
    test_frame(&r.mesh)
    mesh:=mesh_buffer_view(&r.mesh)
    expect_closed(t,&r.mesh,"frame")
    total:=mesh_volume(mesh.positions,mesh.indices)
    testing.expect_value(t,total,12)
    // Across the axis the cut is a square with a square hole.
    result,_:=mesh_slice(&r.slicer,mesh,{{0,1,0},0.25},&r.front,&r.back)
    expect_closed(t,&r.front,"front")
    expect_closed(t,&r.back,"back")
    testing.expectf(t,abs(result.front.cap_area-12)<1e-4 && abs(result.back.cap_area-12)<1e-4,"cap areas %v %v",result.front.cap_area,result.back.cap_area)
    testing.expectf(t,abs(buffer_volume(&r.front)-3)<1e-4,"front volume %v",buffer_volume(&r.front))
    testing.expectf(t,abs(buffer_volume(&r.back)-9)<1e-4,"back volume %v",buffer_volume(&r.back))
    // Along the axis it is two separate rectangles.
    result,_=mesh_slice(&r.slicer,mesh,{{1,0,0},0.25},&r.front,&r.back)
    expect_closed(t,&r.front,"front")
    expect_closed(t,&r.back,"back")
    testing.expectf(t,abs(result.front.cap_area-2)<1e-4 && abs(result.back.cap_area-2)<1e-4,"cap areas %v %v",result.front.cap_area,result.back.cap_area)
    front,back:=buffer_volume(&r.front),buffer_volume(&r.back)
    testing.expectf(t,abs(front+back-total)<1e-4,"volumes %v + %v",front,back)
    labels:=make([]u32,len(r.front.indices)/3)
    defer delete(labels)
    testing.expect_value(t,mesh_components(r.front.positions[:],r.front.indices[:],labels),1)
    // A plane that grazes the hole wall: the wall is on the plane.
    result,_=mesh_slice(&r.slicer,mesh,{{1,0,0},1},&r.front,&r.back)
    expect_closed(t,&r.front,"front")
    expect_closed(t,&r.back,"back")
    front,back=buffer_volume(&r.front),buffer_volume(&r.back)
    testing.expectf(t,abs(front-4)<1e-4 && abs(back-8)<1e-4,"volumes %v + %v",front,back)
}

@(test)
slice_of_an_open_mesh_leaves_the_cut_open_and_reports_it :: proc(t:^testing.T) {
    r:Slice_Rig
    slice_rig_init(&r)
    defer slice_rig_destroy(&r)
    test_box(&r.mesh,{-1,-1,-1},{1,1,1})
    // Without the +X face.
    mesh:=mesh_buffer_view(&r.mesh)
    mesh.indices=mesh.indices[6:]
    mesh.materials=mesh.materials[2:]
    result,error:=mesh_slice(&r.slicer,mesh,{{0,1,0},0},&r.front,&r.back)
    testing.expect_value(t,error,Slice_Error.None)
    testing.expect(t,result.open_edges>0)
    testing.expect_value(t,result.front.cap_triangles,0)
    testing.expect(t,result.front.triangles>0 && result.back.triangles>0)
    // One side only, and no cap on request.
    mesh_buffer_clear(&r.front)
    test_box(&r.front,{0,0,0},{1,1,1})
    result,_=mesh_slice(&r.slicer,mesh_buffer_view(&r.mesh),{{0,1,0},0},nil,&r.back,{open=true})
    testing.expect_value(t,result.back.cap_triangles,0)
    testing.expect(t,result.front.triangles>0 && result.front.cap_first==result.front.triangles)
    testing.expect_value(t,len(r.front.positions),24)
    testing.expect_value(t,mesh_topology(r.back.positions[:],r.back.indices[:]).boundary_edges,8)
}

@(private) buffers_equal :: proc(a,b:^Mesh_Buffer) -> bool {
    return bytes_equal(a.positions[:],b.positions[:]) && bytes_equal(a.normals[:],b.normals[:]) && bytes_equal(a.uvs[:],b.uvs[:]) &&
        bytes_equal(a.colors[:],b.colors[:]) && bytes_equal(a.indices[:],b.indices[:]) && bytes_equal(a.materials[:],b.materials[:])
}

@(private) random_plane :: proc(rng:^base.Rng,positions:[]Vec3,round:int) -> Plane {
    through:=positions[int(base.rng_u32(rng))%len(positions)]
    normal:=mm.random_in_sphere(rng)
    switch round%4 {
    case 1: normal={1,0,0} if round%3==0 else {0,1,0} if round%3==1 else {0,0,1} // through a vertex, along an axis
    case 2: through+=mm.random_in_sphere(rng)*0.1
    case 3: through=(through+positions[int(base.rng_u32(rng))%len(positions)])*0.5
    }
    if normal=={} {normal={0,1,0}}
    return plane_from_point(normal,through)
}

@(test)
slices_of_random_planes_stay_closed_and_keep_the_volume :: proc(t:^testing.T) {
    r:Slice_Rig
    slice_rig_init(&r)
    defer slice_rig_destroy(&r)
    again_slicer:Slicer
    slicer_init(&again_slicer)
    defer slicer_destroy(&again_slicer)
    front2,back2,again:Mesh_Buffer
    mesh_buffer_init(&front2);mesh_buffer_init(&back2);mesh_buffer_init(&again)
    defer mesh_buffer_destroy(&front2)
    defer mesh_buffer_destroy(&back2)
    defer mesh_buffer_destroy(&again)
    rng:=base.rng_make(0x511ce)
    for round in 0..<360 {
        shape:=Shape(round%len(Shape))
        mesh_buffer_clear(&r.mesh)
        shape_build(&r.mesh,shape)
        scales:=[3]f32{1,1e-3,300}
        scale:=scales[round/len(Shape)%3]
        offset:=Vec3{mm.random_f32(&rng)-0.5,mm.random_f32(&rng)-0.5,mm.random_f32(&rng)-0.5}*scale*(round%7==0?2000:2)
        for &p in r.mesh.positions {p=p*scale+offset}
        mesh:=mesh_buffer_view(&r.mesh)
        total:=mesh_volume(mesh.positions,mesh.indices)
        plane:=random_plane(&rng,mesh.positions,round)
        result,error:=mesh_slice(&r.slicer,mesh,plane,&r.front,&r.back,{cap_material=1})
        testing.expect_value(t,error,Slice_Error.None)
        testing.expectf(t,result.open_edges==0,"round %d (%v): %d open edges",round,shape,result.open_edges)
        front,back:=buffer_volume(&r.front),buffer_volume(&r.back)
        // The parts overlap or miss at most the tolerance along the cut.
        slack:=1e-4*total+tolerance_noise(positions_max_abs(mesh.positions))*(result.front.cap_area+scale*scale)*4
        testing.expectf(t,abs(front+back-total)<=slack && front>=-slack && back>=-slack,"round %d (%v): %v + %v is not %v (slack %v)",round,shape,front,back,total,slack)
        if result.front.triangles>0 {expect_closed(t,&r.front,"front")}
        if result.back.triangles>0 {expect_closed(t,&r.back,"back")}
        testing.expectf(t,abs(result.front.cap_area-result.back.cap_area)<=1e-3*(result.front.cap_area+scale*scale*1e-3),"round %d (%v): cap areas %v and %v",round,shape,result.front.cap_area,result.back.cap_area)

        // The same cut with other scratch memory gives the same bytes.
        mesh_slice(&again_slicer,mesh,plane,&again,nil,{cap_material=1})
        testing.expectf(t,buffers_equal(&again,&r.front),"round %d (%v): two cuts differ",round,shape)

        // A part with a cap is cut again, across or along the first cut.
        if result.back.triangles==0 || result.back.cap_triangles==0 {continue}
        part:=mesh_buffer_view(&r.back)
        second:=random_plane(&rng,part.positions,round/2)
        if round%5==0 {second=plane}
        if round%5==1 {second={-plane.normal,-plane.d}}
        result,error=mesh_slice(&r.slicer,part,second,&front2,&back2,{cap_material=2})
        testing.expectf(t,result.open_edges==0,"round %d (%v): second cut has %d open edges",round,shape,result.open_edges)
        front2_volume,back2_volume:=buffer_volume(&front2),buffer_volume(&back2)
        testing.expectf(t,abs(front2_volume+back2_volume-back)<=slack*2,"round %d (%v): second cut %v + %v is not %v",round,shape,front2_volume,back2_volume,back)
        if result.front.triangles>0 {expect_closed(t,&front2,"front of the second cut")}
        if result.back.triangles>0 {expect_closed(t,&back2,"back of the second cut")}
    }
}
