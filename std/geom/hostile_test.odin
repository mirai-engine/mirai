package geom

import "core:testing"

// Every public procedure takes whatever it is given and returns: indices out
// of range, streams of other lengths, NaN, infinities and huge or tiny
// coordinates, empty and coincident inputs, and parameters out of range.

@(private="file") HOSTILE_ROUNDS :: #config(GEOM_HOSTILE_ROUNDS,400)

@(private="file")
Hostile :: struct {state:u64}

@(private="file")
hostile_next :: proc(h:^Hostile) -> u64 {
    h.state+=0x9e3779b97f4a7c15
    z:=h.state
    z=(z~(z>>30))*0xbf58476d1ce4e5b9
    z=(z~(z>>27))*0x94d049bb133111eb
    return z~(z>>31)
}

@(private="file")
hostile_int :: proc(h:^Hostile,below:int) -> int {return below<=0?0:int(hostile_next(h)%u64(below))}

@(private="file")
hostile_f32 :: proc(h:^Hostile) -> f32 {
    switch hostile_int(h,12) {
    case 0: return f32(0h7fc00000)
    case 1: return f32(0h7f800000)
    case 2: return f32(0hff800000)
    case 3: return 1e30
    case 4: return -1e30
    case 5: return 1e-30
    case 6: return 0
    case 7: return 1
    }
    return f32(hostile_int(h,2001)-1000)/100
}

@(private="file")
hostile_vec3 :: proc(h:^Hostile,wild:bool) -> Vec3 {
    if !wild {return {f32(hostile_int(h,201)-100)/50,f32(hostile_int(h,201)-100)/50,f32(hostile_int(h,201)-100)/50}}
    return {hostile_f32(h),hostile_f32(h),hostile_f32(h)}
}

// A mesh that may be anything: valid, degenerate or broken.
@(private="file")
hostile_mesh :: proc(h:^Hostile,positions:^[dynamic]Vec3,indices:^[dynamic]u32,normals:^[dynamic]Vec3,materials:^[dynamic]u32) -> Mesh {
    clear(positions);clear(indices);clear(normals);clear(materials)
    n:=hostile_int(h,24)
    wild:=hostile_int(h,4)==0
    same:=hostile_int(h,6)==0
    first:=hostile_vec3(h,wild)
    for _ in 0..<n {append(positions,same?first:hostile_vec3(h,wild))}
    count:=hostile_int(h,40)
    if hostile_int(h,3)!=0 {count-=count%3}
    broken:=hostile_int(h,5)==0
    for _ in 0..<count {append(indices,u32(hostile_int(h,max(n,1)+(broken?3:0))))}
    mesh:=Mesh{positions=positions[:],indices=indices[:]}
    if hostile_int(h,4)==0 {
        for _ in 0..<n+(hostile_int(h,3)==0?1:0) {append(normals,hostile_vec3(h,false))}
        mesh.normals=normals[:]
    }
    if hostile_int(h,4)==0 {
        for _ in 0..<count/3+(hostile_int(h,3)==0?1:0) {append(materials,u32(hostile_int(h,4)))}
        mesh.materials=materials[:]
    }
    return mesh
}

@(private="file")
Hostile_Buffers :: struct {
    positions:[dynamic]Vec3,
    indices:[dynamic]u32,
    normals:[dynamic]Vec3,
    materials:[dynamic]u32,
}

@(test)
hostile_scalar_grids_through_isosurface :: proc(t:^testing.T) {
    h:=Hostile{71}
    values:[125]f32
    out:Mesh_Buffer;mesh_buffer_init(&out);defer mesh_buffer_destroy(&out)
    for _ in 0..<HOSTILE_ROUNDS {
        n:=hostile_int(&h,6)
        for &value in values {value=hostile_f32(&h)}
        grid:=Scalar_Grid{samples={n,n,n},cell=hostile_vec3(&h,hostile_int(&h,2)==0),origin=hostile_vec3(&h,true),values=values[:min(n*n*n,len(values))]}
        low,high:[3]int
        for axis in 0..<3 {low[axis]=hostile_int(&h,7)-1;high[axis]=hostile_int(&h,7)-1}
        lod:Iso_Lod
        if hostile_int(&h,2)==0 {
            lod.level=u8(hostile_int(&h,ISO_LEVELS_MAX+2))
            for &face in lod.faces {face=u8(hostile_int(&h,4))}
            for &edge in lod.edges {edge=u8(hostile_int(&h,4))}
        }
        isosurface(grid,low,high,&out,hostile_f32(&h),lod)
    }
}

@(private="file")
buffers_destroy :: proc(b:^Hostile_Buffers) {delete(b.positions);delete(b.indices);delete(b.normals);delete(b.materials)}

@(test)
hostile_meshes_through_the_utilities :: proc(t:^testing.T) {
    h:=Hostile{1}
    b:Hostile_Buffers
    defer buffers_destroy(&b)
    out:Mesh_Buffer
    mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&out)
    labels,remap,adjacency:[dynamic]u32
    defer {delete(labels);delete(remap);delete(adjacency)}
    normals:[dynamic]Vec3
    defer delete(normals)
    for _ in 0..<HOSTILE_ROUNDS {
        mesh:=hostile_mesh(&h,&b.positions,&b.indices,&b.normals,&b.materials)
        _=mesh_is_valid(mesh)
        _,_=mesh_bounds(mesh.positions)
        _=mesh_mass_properties(mesh.positions,mesh.indices)
        _=mesh_volume(mesh.positions,mesh.indices)
        _=mesh_area(mesh.positions,mesh.indices)
        resize(&normals,len(mesh.positions)+hostile_int(&h,3)-1)
        mesh_compute_normals(mesh.positions,mesh.indices,normals[:])
        resize(&adjacency,len(mesh.indices)+hostile_int(&h,3)-1)
        _=mesh_topology(mesh.positions,mesh.indices,hostile_int(&h,2)==0?adjacency[:]:nil,hostile_int(&h,2)==0)
        _=mesh_is_closed(mesh.positions,mesh.indices)
        resize(&labels,len(mesh.indices)/3+hostile_int(&h,3)-1)
        _=mesh_components(mesh.positions,mesh.indices,labels[:])
        resize(&remap,len(mesh.positions)+hostile_int(&h,3)-1)
        _=positions_weld(mesh.positions,hostile_f32(&h),remap[:])
        mesh_weld(mesh,hostile_f32(&h),&out,hostile_int(&h,2)==0)
    }
}

@(test)
hostile_points_through_the_hull :: proc(t:^testing.T) {
    h:=Hostile{2}
    b:Hostile_Buffers
    defer buffers_destroy(&b)
    out:Mesh_Buffer
    mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&out)
    for _ in 0..<HOSTILE_ROUNDS {
        mesh:=hostile_mesh(&h,&b.positions,&b.indices,&b.normals,&b.materials)
        desc:=Hull_Desc{max_vertices=hostile_int(&h,12)-4,tolerance=hostile_int(&h,3)==0?hostile_f32(&h):0}
        hull,error:=hull_build(mesh.positions,desc)
        if error==.None {
            _=hull_mass_properties(hull)
            _=hull_distance_outside(hull,hostile_vec3(&h,true))
            _=hull_is_valid(hull,hostile_f32(&h))
            _=hull_is_flat(hull)
            mesh_buffer_clear(&out)
            hull_append_mesh(hull,&out)
        }
        hull_destroy(&hull)
        _=points_hull_volume(mesh.positions,desc)
    }
}

@(test)
hostile_meshes_through_slice_and_fracture :: proc(t:^testing.T) {
    h:=Hostile{3}
    b:Hostile_Buffers
    defer buffers_destroy(&b)
    s:Slicer
    slicer_init(&s)
    defer slicer_destroy(&s)
    front,back:Mesh_Buffer
    mesh_buffer_init(&front);mesh_buffer_init(&back)
    defer {mesh_buffer_destroy(&front);mesh_buffer_destroy(&back)}
    f:Fracture
    fracture_init(&f)
    defer fracture_destroy(&f)
    sites:[dynamic]Vec3
    defer delete(sites)
    for _ in 0..<HOSTILE_ROUNDS {
        mesh:=hostile_mesh(&h,&b.positions,&b.indices,&b.normals,&b.materials)
        plane:=Plane{normal=hostile_vec3(&h,hostile_int(&h,3)==0),d=hostile_f32(&h)}
        options:=Slice_Options{tolerance=hostile_int(&h,3)==0?hostile_f32(&h):0,open=hostile_int(&h,2)==0,cap_uv_scale=hostile_f32(&h)}
        _,_=mesh_slice(&s,mesh,plane,hostile_int(&h,4)==0?nil:&front,hostile_int(&h,4)==0?nil:&back,options)
        resize(&sites,hostile_int(&h,10))
        lo,hi:=mesh_bounds(mesh.positions)
        sites_generate(sites[:],{pattern=Site_Pattern(hostile_int(&h,3)),seed=hostile_next(&h),lo=lo,hi=hi,clusters=hostile_int(&h,6)-2,cluster_radius=hostile_f32(&h),center=hostile_vec3(&h,true),radius=hostile_f32(&h)})
        if hostile_int(&h,4)==0 && len(sites)>0 {sites[hostile_int(&h,len(sites))]=hostile_vec3(&h,true)}
        _=mesh_fracture(&f,mesh,sites[:],{tolerance=hostile_int(&h,3)==0?hostile_f32(&h):0,min_volume=hostile_f32(&h)})
        for piece in 0..<len(f.pieces) {_=fracture_piece_mesh(&f,piece)}
    }
}

@(test)
hostile_meshes_through_simplify_and_decompose :: proc(t:^testing.T) {
    h:=Hostile{4}
    b:Hostile_Buffers
    defer buffers_destroy(&b)
    destination:[dynamic]u32
    defer delete(destination)
    attributes:[dynamic]f32
    defer delete(attributes)
    locks:[dynamic]Simplify_Vertex
    defer delete(locks)
    weights:[4]f32
    for round in 0..<HOSTILE_ROUNDS {
        mesh:=hostile_mesh(&h,&b.positions,&b.indices,&b.normals,&b.materials)
        resize(&destination,len(mesh.indices)+hostile_int(&h,3)-1)
        stride:=hostile_int(&h,5)
        for &w in weights[:stride] {w=hostile_int(&h,4)==0?hostile_f32(&h):1}
        resize(&attributes,hostile_int(&h,4)==0?hostile_int(&h,8):len(mesh.positions)*stride)
        for &a in attributes {a=hostile_f32(&h)}
        resize(&locks,hostile_int(&h,2)==0?len(mesh.positions):hostile_int(&h,3))
        for &l in locks {l=transmute(Simplify_Vertex)u8(hostile_int(&h,8))}
        options:=transmute(Simplify_Options)u32(hostile_int(&h,256))
        result,failed:=simplify(destination[:],mesh.indices,mesh.positions,(hostile_int(&h,12)-2)*3,hostile_f32(&h),options,attributes[:],weights[:stride],locks[:])
        if failed==.None {
            for index in destination[:result.index_count] {testing.expect(t,int(index)<len(mesh.positions))}
        }
        if round%4==0 {
            d,_:=mesh_decompose(mesh,{max_hulls=hostile_int(&h,6)-1,max_hull_vertices=hostile_int(&h,12)-1,concavity=hostile_f32(&h),planes_per_axis=hostile_int(&h,5)-1,tolerance=hostile_int(&h,3)==0?hostile_f32(&h):0})
            decomposition_destroy(&d)
        }
    }
}

@(private="file")
hostile_polygon :: proc(h:^Hostile,points:^[dynamic]Vec2,loops:^[dynamic]int) {
    clear(points);clear(loops)
    n:=hostile_int(h,20)
    wild:=hostile_int(h,4)==0
    for _ in 0..<n {
        p:=hostile_vec3(h,wild)
        append(points,Vec2{p.x,p.y})
    }
    rest:=n
    for rest>0 && len(loops)<4 {
        size:=hostile_int(h,rest+3)-1
        append(loops,size)
        rest-=max(size,1)
    }
}

@(test)
hostile_polygons_through_the_ear_clipping :: proc(t:^testing.T) {
    h:=Hostile{5}
    points:[dynamic]Vec2
    loops:[dynamic]int
    triangles,pieces,sizes:[dynamic]u32
    defer {delete(points);delete(loops);delete(triangles);delete(pieces);delete(sizes)}
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_polygon(&h,&points,&loops)
        _=polygon_triangulate(points[:],loops[:],&triangles,Polygon_Rule(hostile_int(&h,2)))
        clear(&pieces);clear(&sizes)
        count:=polygon_convex_partition(points[:],loops[:],&pieces,&sizes)
        used:=0
        for size in sizes {used+=int(size)}
        testing.expect(t,count==len(sizes) && used==len(pieces))
        for index in pieces {testing.expect(t,int(index)<len(points))}
    }
    square:=[]Vec2{{0,0},{1,0},{1,1},{0,1}}
    nan:=[]Vec2{{0,0},{1,0},{f32(0h7fc00000),1},{0,1}}
    for loops in ([][]int{{max(int),max(int)},{5},{-1,4},{2},{}}) {
        testing.expect_value(t,polygon_triangulate(square,loops,&triangles),0)
        testing.expect_value(t,polygon_convex_partition(square,loops,&pieces,&sizes),0)
    }
    testing.expect_value(t,polygon_convex_partition(nan,{4},&pieces,&sizes),0)
}

@(test)
hostile_points_through_delaunay :: proc(t:^testing.T) {
    h:=Hostile{7}
    points:[dynamic]Vec2
    loops:[dynamic]int
    triangles,halfedges:[dynamic]u32
    defer {delete(points);delete(loops);delete(triangles);delete(halfedges)}
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_polygon(&h,&points,&loops)
        _=delaunay_triangulate(points[:],&triangles,hostile_int(&h,2)==0?&halfedges:nil)
    }
}

@(test)
hostile_parameters_through_the_primitives :: proc(t:^testing.T) {
    h:=Hostile{6}
    out:Mesh_Buffer
    mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&out)
    for _ in 0..<HOSTILE_ROUNDS/4 {
        mesh_buffer_clear(&out)
        count:=hostile_int(&h,70)-4
        size:=hostile_vec3(&h,true)
        cube_build(&out,size)
        sphere_build(&out,hostile_f32(&h),count,hostile_int(&h,70)-4)
        icosphere_build(&out,hostile_f32(&h),hostile_int(&h,8)-2)
        cylinder_build(&out,hostile_f32(&h),hostile_f32(&h),count)
        cone_build(&out,hostile_f32(&h),hostile_f32(&h),count)
        prism_build(&out,size)
        pyramid_build(&out,size)
        capsule_build(&out,hostile_f32(&h),hostile_f32(&h),count,hostile_int(&h,40)-4)
        plane_build(&out,{size.x,size.y},hostile_int(&h,40)-4,hostile_int(&h,40)-4)
        torus_build(&out,hostile_f32(&h),hostile_f32(&h),count,hostile_int(&h,40)-4)
        _=mesh_is_valid(mesh_buffer_view(&out))
        path:=[3]Vec3{hostile_vec3(&h,true),hostile_vec3(&h,true),hostile_vec3(&h,true)}
        tube_build(&out,path[:hostile_int(&h,4)],{hostile_f32(&h),hostile_f32(&h)},count,hostile_int(&h,20)-4)
        profile:=[3]Vec2{{hostile_f32(&h),hostile_f32(&h)},{hostile_f32(&h),hostile_f32(&h)},{hostile_f32(&h),hostile_f32(&h)}}
        lathe_build(&out,profile[:hostile_int(&h,4)],count)
        extrude_build(&out,profile[:hostile_int(&h,4)],hostile_f32(&h))
        blade:=Blade{hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_int(&h,20)-4}
        blade_build(&out,hostile_vec3(&h,true),hostile_vec3(&h,true),blade)
        fan_build(&out,hostile_vec3(&h,true),hostile_int(&h,8)-2,blade,hostile_f32(&h),u32(hostile_next(&h)))
        blob_build(&out,size,hostile_int(&h,4)-1,hostile_f32(&h),u32(hostile_next(&h)))
        mesh_buffer_paint(&out,{1,1,1,1})
        mesh_buffer_place(&out,hostile_int(&h,1<<20)-512,hostile_vec3(&h,true),hostile_f32(&h),size)
        if hostile_int(&h,4)==0 {append(&out.indices,u32(hostile_next(&h)))}
        mesh_buffer_flatten(&out)
    }
}

@(test)
hostile_meshes_through_clusters_and_their_dag :: proc(t:^testing.T) {
    h:=Hostile{8}
    b:Hostile_Buffers
    defer buffers_destroy(&b)
    meshlets:[dynamic]Meshlet
    vertices:[dynamic]u32
    triangles:[dynamic]u8
    counts:[dynamic]u32
    groups:[dynamic]u32
    ranges:[dynamic]Cluster_Range
    levels:[dynamic]Cluster_Level
    defer {delete(meshlets);delete(vertices);delete(triangles);delete(counts);delete(groups);delete(ranges);delete(levels)}
    dag:Cluster_Dag
    defer cluster_dag_destroy(&dag)
    for _ in 0..<HOSTILE_ROUNDS {
        mesh:=hostile_mesh(&h,&b.positions,&b.indices,&b.normals,&b.materials)
        max_vertices,min_triangles,max_triangles:=hostile_int(&h,300)-10,hostile_int(&h,20)-2,hostile_int(&h,600)-10
        resize(&meshlets,meshlets_bound(len(mesh.indices),max_vertices,max(min_triangles,1))+hostile_int(&h,3)-1)
        resize(&vertices,len(mesh.indices));resize(&triangles,len(mesh.indices))
        count,failed:=meshlets_build(meshlets[:],vertices[:],triangles[:],mesh.indices,mesh.positions,max_vertices,min_triangles,max_triangles,hostile_f32(&h),hostile_f32(&h))
        if failed==.None {
            for m in meshlets[:count] {
                testing.expect(t,int(m.vertex_offset+m.vertex_count)<=len(vertices) && int(m.triangle_offset+m.triangle_count*3)<=len(triangles))
            }
        }
        _=cluster_bounds(mesh.indices,mesh.positions)
        radii:=make([]f32,hostile_int(&h,2)==0?len(mesh.positions):hostile_int(&h,4),context.temp_allocator)
        for &r in radii {r=hostile_f32(&h)}
        _,_=spheres_bound(mesh.positions,radii)
        local:[MESHLET_MAX_VERTICES]u32
        local_triangles:[64]u8
        _=meshlet_local_indices(local[:hostile_int(&h,len(local)+1)],local_triangles[:],mesh.indices[:min(len(mesh.indices),len(local_triangles))])
        // Clusters of three indices each, or of any count.
        clear(&counts)
        for at:=0;at<len(mesh.indices); {
            n:=min(hostile_int(&h,9)+(hostile_int(&h,5)==0?0:1),len(mesh.indices)-at)
            append(&counts,u32(n))
            at+=max(n,1)
        }
        resize(&groups,len(counts)+hostile_int(&h,3)-1)
        generators:=make([]u32,hostile_int(&h,2)==0?len(counts):hostile_int(&h,3),context.temp_allocator)
        for &g in generators {g=u32(hostile_int(&h,4))}
        _,_=clusters_partition(groups[:],mesh.indices,counts[:],mesh.positions,hostile_int(&h,20)-2,generators)
        clear(&ranges)
        for _ in 0..<hostile_int(&h,4) {append(&ranges,Cluster_Range{u32(hostile_int(&h,len(mesh.indices)+2)),u32(hostile_int(&h,len(mesh.indices)+2)),u32(hostile_int(&h,3))})}
        weights:=[]f32{hostile_f32(&h),1}
        attributes:=make([]f32,hostile_int(&h,3)==0?hostile_int(&h,9):len(mesh.positions)*2,context.temp_allocator)
        for &a in attributes {a=hostile_int(&h,8)==0?hostile_f32(&h):f32(hostile_int(&h,5))}
        lock:=make([]Simplify_Vertex,hostile_int(&h,3)==0?hostile_int(&h,4):len(mesh.positions),context.temp_allocator)
        for &l in lock {l=transmute(Simplify_Vertex)u8(hostile_int(&h,8))}
        if cluster_dag_build(&dag,{positions=mesh.positions,indices=mesh.indices,ranges=ranges[:],attributes=attributes,attribute_weights=weights[:hostile_int(&h,3)],vertex_lock=lock})==.None {
            for c in dag.clusters {testing.expect(t,int(c.first_vertex+c.vertex_count)<=len(dag.vertices) && int(c.first_triangle+c.triangle_count)*3<=len(dag.triangles))}
        }
        clear(&levels)
        for _ in 0..<hostile_int(&h,4) {append(&levels,Cluster_Level{u32(hostile_int(&h,len(ranges)+2)),u32(hostile_int(&h,3)),hostile_f32(&h)})}
        _=cluster_levels_build(&dag,mesh.positions,mesh.indices,ranges[:],levels[:])
        free_all(context.temp_allocator)
    }
}
