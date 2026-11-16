package geom

import "core:testing"

// A closed prism: an outline in the xy plane, counterclockwise, from z 0 to height.
@(private="file") prism :: proc(out:^Mesh_Buffer,outline:[]Vec2,height:f32) {
    n:=u32(len(outline))
    for p in outline {append(&out.positions,Vec3{p.x,p.y,0})}
    for p in outline {append(&out.positions,Vec3{p.x,p.y,height})}
    caps:=make([dynamic]u32,context.temp_allocator)
    polygon_triangulate(outline,{len(outline)},&caps)
    for t:=0;t+2<len(caps);t+=3 {
        append(&out.indices,caps[t],caps[t+2],caps[t+1])
        append(&out.indices,caps[t]+n,caps[t+1]+n,caps[t+2]+n)
    }
    for i in 0..<n {
        j:=(i+1)%n
        append(&out.indices,i,j,j+n,i,j+n,i+n)
    }
}

// How far outside every hull the worst vertex of the mesh is.
@(private="file") worst_outside :: proc(d:Decomposition,positions:[]Vec3) -> (worst:f32) {
    for p in positions {
        nearest:=f32(1e30)
        for hull in d.hulls {nearest=min(nearest,hull_distance_outside(hull,p))}
        worst=max(worst,nearest)
    }
    return
}

@(test)
decompose_gives_one_hull_for_a_convex_mesh :: proc(t:^testing.T) {
    box:Mesh_Buffer
    mesh_buffer_init(&box)
    defer mesh_buffer_destroy(&box)
    cube_build(&box,{2,1,3})
    d,error:=mesh_decompose(mesh_buffer_view(&box))
    defer decomposition_destroy(&d)
    testing.expect_value(t,error,Decompose_Error.None)
    testing.expect_value(t,len(d.hulls),1)
    testing.expect(t,abs(d.volume-6)<1e-4 && abs(d.mesh_volume-6)<1e-4 && d.concavity<1e-5)
    if len(d.hulls)==1 {
        testing.expect_value(t,len(d.hulls[0].vertices),8)
        testing.expect(t,hull_is_valid(d.hulls[0],1e-5))
    }
}

@(test)
decompose_cuts_an_l_shape_into_its_two_boxes :: proc(t:^testing.T) {
    shape:Mesh_Buffer
    mesh_buffer_init(&shape)
    defer mesh_buffer_destroy(&shape)
    prism(&shape,{{0,0},{2,0},{2,1},{1,1},{1,2},{0,2}},1)
    source:=mesh_buffer_view(&shape)
    testing.expect(t,mesh_is_closed(source.positions,source.indices))
    testing.expect(t,abs(mesh_volume(source.positions,source.indices)-3)<1e-5)

    // One hull has to span the notch: a quarter more volume than the shape.
    one,_:=mesh_decompose(source,{max_hulls=1})
    defer decomposition_destroy(&one)
    testing.expect_value(t,len(one.hulls),1)
    testing.expect(t,abs(one.volume-3.5)<1e-4 && abs(one.concavity-0.5/3.5)<1e-4)

    d,error:=mesh_decompose(source)
    defer decomposition_destroy(&d)
    testing.expect_value(t,error,Decompose_Error.None)
    testing.expect_value(t,len(d.hulls),2)
    testing.expectf(t,abs(d.volume-3)<1e-4 && d.concavity<1e-5,"two hulls hold %v of a shape of 3",d.volume)
    for hull in d.hulls {
        testing.expect(t,hull_is_valid(hull,1e-5))
        testing.expect_value(t,len(hull.vertices),8)
    }
    testing.expect(t,worst_outside(d,source.positions)<=1e-5,"every vertex of the shape is in a hull")
}

@(test)
decompose_takes_islands_apart_and_bounds_hulls_and_vertices :: proc(t:^testing.T) {
    pair:Mesh_Buffer
    mesh_buffer_init(&pair)
    defer mesh_buffer_destroy(&pair)
    cube_build(&pair,{1,1,1})
    first:=len(pair.positions)
    cube_build(&pair,{0.5,0.5,0.5})
    for &p in pair.positions[first:] {p+={4,0,0}}
    source:=mesh_buffer_view(&pair)
    d,_:=mesh_decompose(source)
    defer decomposition_destroy(&d)
    testing.expect_value(t,len(d.hulls),2)
    testing.expect(t,abs(d.volume-1.125)<1e-4,"two cubes, each its own hull")
    if len(d.hulls)==2 {testing.expect(t,abs(hull_mass_properties(d.hulls[0]).volume-1)<1e-4,"the largest island comes first")}
    joined,_:=mesh_decompose(source,{max_hulls=1})
    defer decomposition_destroy(&joined)
    testing.expect_value(t,len(joined.hulls),1)
    testing.expect(t,joined.volume>2,"one hull spans both")

    ring:Mesh_Buffer
    mesh_buffer_init(&ring)
    defer mesh_buffer_destroy(&ring)
    welded(&ring,proc(out:^Mesh_Buffer) {torus_build(out,1,0.3,32,12)})
    torus:=mesh_buffer_view(&ring)
    volume:=mesh_volume(torus.positions,torus.indices)
    single,_:=mesh_decompose(torus,{max_hulls=1,max_hull_vertices=64})
    defer decomposition_destroy(&single)
    previous:=single.volume
    for hulls in ([]int{4,8,16}) {
        parts,parts_error:=mesh_decompose(torus,{max_hulls=hulls,max_hull_vertices=24})
        defer decomposition_destroy(&parts)
        testing.expect_value(t,parts_error,Decompose_Error.None)
        testing.expect(t,len(parts.hulls)<=hulls && len(parts.hulls)>hulls/2)
        testing.expectf(t,parts.volume<previous,"%d hulls hold %v, fewer held %v",hulls,parts.volume,previous)
        previous=parts.volume
        for hull in parts.hulls {testing.expect(t,len(hull.vertices)<=24 && len(hull.vertices)>=4)}
    }
    // Sixteen hulls fill less than half of the hole one hull closes.
    testing.expectf(t,previous-volume<(single.volume-volume)*0.5,"%v against %v around a torus of %v",previous,single.volume,volume)
}

@(test)
decompose_survives_degenerate_and_open_input :: proc(t:^testing.T) {
    d,error:=mesh_decompose({})
    testing.expect(t,error==.No_Volume && len(d.hulls)==0)
    points:=[]Vec3{{0,0,0},{1,0,0},{0,1,0},{1,1,0}}
    _,error=mesh_decompose({positions=points,indices={0,1,2,1,3,2}})
    testing.expect_value(t,error,Decompose_Error.No_Volume)
    _,error=mesh_decompose({positions=points,indices={0,1,7}})
    testing.expect_value(t,error,Decompose_Error.Invalid_Mesh)
    _,error=mesh_decompose({positions=points,indices={0,1,2}},{max_hulls=-1})
    testing.expect_value(t,error,Decompose_Error.Invalid_Mesh)
    nan:=f32(0h7fc00000)
    broken:=[]Vec3{{0,0,0},{1,0,0},{0,1,0},{nan,0,1}}
    _,error=mesh_decompose({positions=broken,indices={0,1,2,0,1,3}})
    testing.expect_value(t,error,Decompose_Error.Invalid_Mesh)

    // A box without its lid and a triangle with a repeated corner: still covered by hulls.
    box:Mesh_Buffer
    mesh_buffer_init(&box)
    defer mesh_buffer_destroy(&box)
    cube_build(&box)
    resize(&box.indices,len(box.indices)-6)
    append(&box.indices,0,0,1)
    open,open_error:=mesh_decompose({positions=box.positions[:],indices=box.indices[:]},{max_hulls=4})
    defer decomposition_destroy(&open)
    testing.expect_value(t,open_error,Decompose_Error.None)
    testing.expect(t,len(open.hulls)>=1 && len(open.hulls)<=4)
    for hull in open.hulls {testing.expect(t,hull_is_valid(hull,1e-4))}

    // Every point in one place.
    same:=[]Vec3{{1,1,1},{1,1,1},{1,1,1},{1,1,1}}
    _,error=mesh_decompose({positions=same,indices={0,1,2,0,2,3}})
    testing.expect_value(t,error,Decompose_Error.No_Volume)
}

@(test)
decompose_is_deterministic :: proc(t:^testing.T) {
    shape:Mesh_Buffer
    mesh_buffer_init(&shape)
    defer mesh_buffer_destroy(&shape)
    // A cross: four notches.
    prism(&shape,{{1,0},{2,0},{2,1},{3,1},{3,2},{2,2},{2,3},{1,3},{1,2},{0,2},{0,1},{1,1}},0.5)
    source:=mesh_buffer_view(&shape)
    testing.expect(t,mesh_is_closed(source.positions,source.indices))
    a,_:=mesh_decompose(source,{max_hulls=6})
    defer decomposition_destroy(&a)
    b,_:=mesh_decompose(source,{max_hulls=6})
    defer decomposition_destroy(&b)
    testing.expect(t,len(a.hulls)==len(b.hulls) && a.volume==b.volume && a.concavity==b.concavity)
    if len(a.hulls)==len(b.hulls) {
        for hull,i in a.hulls {testing.expect(t,hulls_equal(hull,b.hulls[i]),"the same hulls in the same order")}
    }
    testing.expectf(t,len(a.hulls)>=3 && abs(a.volume-2.5)<1e-3,"%d hulls hold %v of a cross of 2.5",len(a.hulls),a.volume)
    testing.expect(t,worst_outside(a,source.positions)<=1e-5)
}
