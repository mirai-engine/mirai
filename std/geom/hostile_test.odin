package geom

import "mirai:std/base"
import "core:testing"

// Every public procedure is handed indices out of range, streams of other
// lengths, NaN, infinities and huge or tiny coordinates, empty and coincident
// inputs, and parameters out of range. What it writes is a mesh whose streams
// agree and whose indices are of its vertices, a stream of another length is
// not written, and what it reports is of what it was given.

@(private="file") HOSTILE_ROUNDS :: #config(GEOM_HOSTILE_ROUNDS,400)


@(private="file")
hostile_vec3 :: proc(h:^base.Hostile,wild:bool) -> Vec3 {
    if !wild {return {f32(base.hostile_int(h,201)-100)/50,f32(base.hostile_int(h,201)-100)/50,f32(base.hostile_int(h,201)-100)/50}}
    return {base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h)}
}

// A mesh that may be anything: valid, degenerate or broken.
@(private="file")
hostile_mesh :: proc(h:^base.Hostile,positions:^[dynamic]Vec3,indices:^[dynamic]u32,normals:^[dynamic]Vec3,materials:^[dynamic]u32) -> Mesh {
    clear(positions);clear(indices);clear(normals);clear(materials)
    n:=base.hostile_int(h,24)
    wild:=base.hostile_int(h,4)==0
    same:=base.hostile_int(h,6)==0
    first:=hostile_vec3(h,wild)
    for _ in 0..<n {append(positions,same?first:hostile_vec3(h,wild))}
    count:=base.hostile_int(h,40)
    if base.hostile_int(h,3)!=0 {count-=count%3}
    broken:=base.hostile_int(h,5)==0
    for _ in 0..<count {append(indices,u32(base.hostile_int(h,max(n,1)+(broken?3:0))))}
    mesh:=Mesh{positions=positions[:],indices=indices[:]}
    if base.hostile_int(h,4)==0 {
        for _ in 0..<n+(base.hostile_int(h,3)==0?1:0) {append(normals,hostile_vec3(h,false))}
        mesh.normals=normals[:]
    }
    if base.hostile_int(h,4)==0 {
        for _ in 0..<count/3+(base.hostile_int(h,3)==0?1:0) {append(materials,u32(base.hostile_int(h,4)))}
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
    h:=base.Hostile{71}
    values:[125]f32
    out:Mesh_Buffer;mesh_buffer_init(&out);defer mesh_buffer_destroy(&out)
    for _ in 0..<HOSTILE_ROUNDS {
        n:=base.hostile_int(&h,6)
        for &value in values {value=base.hostile_f32(&h)}
        grid:=Scalar_Grid{samples={n,n,n},cell=hostile_vec3(&h,base.hostile_int(&h,2)==0),origin=hostile_vec3(&h,true),values=values[:min(n*n*n,len(values))]}
        low,high:[3]int
        for axis in 0..<3 {low[axis]=base.hostile_int(&h,7)-1;high[axis]=base.hostile_int(&h,7)-1}
        lod:Iso_Lod
        if base.hostile_int(&h,2)==0 {
            lod.level=u8(base.hostile_int(&h,ISO_LEVELS_MAX+2))
            for &face in lod.faces {face=u8(base.hostile_int(&h,4))}
            for &edge in lod.edges {edge=u8(base.hostile_int(&h,4))}
        }
        isosurface(grid,low,high,&out,base.hostile_f32(&h),lod)
        if !testing.expect(t,mesh_is_valid(mesh_buffer_view(&out)),"A surface of any grid is a mesh of its own vertices") {return}
    }
}

@(private="file")
buffers_destroy :: proc(b:^Hostile_Buffers) {delete(b.positions);delete(b.indices);delete(b.normals);delete(b.materials)}

@(private="file")
hostile_finite :: proc(positions:[]Vec3) -> bool {
    for p in positions {if p-p!={} {return false}}
    return true
}

@(test)
hostile_meshes_through_the_utilities :: proc(t:^testing.T) {
    UNWRITTEN :: 0xa5a5a5a5
    h:=base.Hostile{1}
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
        if testing.failed(t) {return}
        mesh:=hostile_mesh(&h,&b.positions,&b.indices,&b.normals,&b.materials)
        vertices,triangles:=len(mesh.positions),len(mesh.indices)/3
        finite:=hostile_finite(mesh.positions)
        in_range:=true
        for index in mesh.indices {in_range&&=int(index)<vertices}
        streams:=len(mesh.indices)%3==0 && (len(mesh.normals)==0 || len(mesh.normals)==vertices) && (len(mesh.materials)==0 || len(mesh.materials)==triangles)
        testing.expect(t,mesh_is_valid(mesh)==(in_range && streams),"A mesh is valid exactly when its streams agree and its indices are of its vertices")
        lo,hi:=mesh_bounds(mesh.positions)
        for p in mesh.positions {
            for axis in 0..<3 {testing.expect(t,!finite || (p[axis]>=lo[axis] && p[axis]<=hi[axis]),"The bounds of some points leave one out")}
        }
        _=mesh_mass_properties(mesh.positions,mesh.indices)
        _=mesh_volume(mesh.positions,mesh.indices)
        testing.expect(t,!finite || mesh_area(mesh.positions,mesh.indices)>=0,"A mesh of finite points has a negative area")
        resize(&normals,vertices+base.hostile_int(&h,3)-1)
        mesh_compute_normals(mesh.positions,mesh.indices,normals[:])
        if finite && len(normals)==vertices {
            for normal in normals {
                length:=normal.x*normal.x+normal.y*normal.y+normal.z*normal.z
                if !testing.expect(t,abs(length-1)<1e-3,"A computed normal is not unit") {break}
            }
        }
        resize(&adjacency,len(mesh.indices)+base.hostile_int(&h,3)-1)
        with_adjacency:=base.hostile_int(&h,2)==0
        _=mesh_topology(mesh.positions,mesh.indices,adjacency[:] if with_adjacency else nil,base.hostile_int(&h,2)==0)
        if with_adjacency && in_range && len(adjacency)==len(mesh.indices) && len(mesh.indices)%3==0 {
            for opposite,edge in adjacency {
                if !testing.expect(t,opposite==NONE || (int(opposite)<len(adjacency) && int(adjacency[opposite])==edge),"The opposite of a half-edge is not a half-edge that points back") {break}
            }
        }
        _=mesh_is_closed(mesh.positions,mesh.indices)
        resize(&labels,triangles+base.hostile_int(&h,3)-1)
        for &label in labels {label=UNWRITTEN}
        components:=mesh_components(mesh.positions,mesh.indices,labels[:])
        for label,triangle in labels {
            if len(labels)!=triangles {
                testing.expect(t,components==0 && label==UNWRITTEN,"Labels of another length were written or counted")
            } else if !testing.expect(t,int(label)<components || (label==NONE && !triangle_in(mesh.indices,triangle*3,vertices)),"A triangle has a component that does not exist") {break}
        }
        resize(&remap,vertices+base.hostile_int(&h,3)-1)
        for &entry in remap {entry=UNWRITTEN}
        representatives:=positions_weld(mesh.positions,base.hostile_f32(&h),remap[:])
        testing.expect(t,representatives>=0 && representatives<=vertices,"A weld has more representatives than vertices")
        for entry,vertex in remap {
            if len(remap)!=vertices {
                testing.expect(t,representatives==0 && entry==UNWRITTEN,"A remap of another length was written or counted")
            } else if !testing.expect(t,int(entry)<=vertex && remap[min(int(entry),vertex)]==entry,"A vertex welds to a lower vertex that is its own representative") {break}
        }
        mesh_weld(mesh,base.hostile_f32(&h),&out,base.hostile_int(&h,2)==0)
        testing.expect(t,mesh_is_valid(mesh_buffer_view(&out)) && (in_range || len(out.positions)==0),"A welded mesh is valid, and empty when an index was out of range")
    }
}

@(test)
hostile_points_through_the_hull :: proc(t:^testing.T) {
    memory:base.Hostile_Memory
    context.allocator=base.hostile_memory_begin(&memory)
    defer {
        leaked,bad_frees:=base.hostile_memory_end(&memory)
        testing.expectf(t,leaked==0 && bad_frees==0,"%d allocations were left and %d frees were of nothing",leaked,bad_frees)
    }
    h:=base.Hostile{2}
    b:Hostile_Buffers
    defer buffers_destroy(&b)
    out:Mesh_Buffer
    mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&out)
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        mesh:=hostile_mesh(&h,&b.positions,&b.indices,&b.normals,&b.materials)
        finite:=hostile_finite(mesh.positions)
        desc:=Hull_Desc{max_vertices=base.hostile_int(&h,12)-4,tolerance=base.hostile_int(&h,3)==0?base.hostile_f32(&h):0}
        hull,error:=hull_build(mesh.positions,desc)
        if error==.None {
            _=hull_mass_properties(hull)
            _=hull_distance_outside(hull,hostile_vec3(&h,true))
            _=hull_is_valid(hull,base.hostile_f32(&h))
            _=hull_is_flat(hull)
            // The points are within 2 of the origin when they are finite.
            testing.expect(t,!finite || hull_is_valid(hull,1e-2+2*abs(desc.tolerance)),"The hull of finite points breaks its invariants")
            mesh_buffer_clear(&out)
            appended:=hull_append_mesh(hull,&out)
            testing.expect(t,appended && mesh_is_valid(mesh_buffer_view(&out)) && len(out.indices)>0,"A hull does not turn into a mesh of its own vertices")
        } else {
            testing.expect(t,len(hull.vertices)==0,"A hull that was not built has vertices")
        }
        hull_destroy(&hull)
        volume:=points_hull_volume(mesh.positions,desc)
        testing.expect(t,!finite || (volume>=0 && volume-volume==0),"The hull of finite points has no volume that is a number")
    }
}

@(test)
hostile_meshes_through_slice_and_fracture :: proc(t:^testing.T) {
    h:=base.Hostile{3}
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
        plane:=Plane{normal=hostile_vec3(&h,base.hostile_int(&h,3)==0),d=base.hostile_f32(&h)}
        options:=Slice_Options{tolerance=base.hostile_int(&h,3)==0?base.hostile_f32(&h):0,open=base.hostile_int(&h,2)==0,cap_uv_scale=base.hostile_f32(&h)}
        _,_=mesh_slice(&s,mesh,plane,base.hostile_int(&h,4)==0?nil:&front,base.hostile_int(&h,4)==0?nil:&back,options)
        if !testing.expect(t,mesh_is_valid(mesh_buffer_view(&front)) && mesh_is_valid(mesh_buffer_view(&back)),"A side of a slice is not a mesh of its own vertices") {return}
        resize(&sites,base.hostile_int(&h,10))
        lo,hi:=mesh_bounds(mesh.positions)
        sites_generate(sites[:],{pattern=Site_Pattern(base.hostile_int(&h,3)),seed=base.hostile_next(&h),lo=lo,hi=hi,clusters=base.hostile_int(&h,6)-2,cluster_radius=base.hostile_f32(&h),center=hostile_vec3(&h,true),radius=base.hostile_f32(&h)})
        if base.hostile_int(&h,4)==0 && len(sites)>0 {sites[base.hostile_int(&h,len(sites))]=hostile_vec3(&h,true)}
        _=mesh_fracture(&f,mesh,sites[:],{tolerance=base.hostile_int(&h,3)==0?base.hostile_f32(&h):0,min_volume=base.hostile_f32(&h)})
        for piece in 0..<len(f.pieces) {
            if !testing.expect(t,mesh_is_valid(fracture_piece_mesh(&f,piece)),"A piece of a fracture is not a mesh of its own vertices") {return}
        }
        testing.expect(t,len(fracture_piece_mesh(&f,len(f.pieces)+base.hostile_int(&h,3)).indices)==0 && len(fracture_piece_mesh(&f,-1-base.hostile_int(&h,3)).indices)==0,"A piece that does not exist has a mesh")
    }
}

@(test)
hostile_meshes_through_simplify_and_decompose :: proc(t:^testing.T) {
    h:=base.Hostile{4}
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
        resize(&destination,len(mesh.indices)+base.hostile_int(&h,3)-1)
        stride:=base.hostile_int(&h,5)
        for &w in weights[:stride] {w=base.hostile_int(&h,4)==0?base.hostile_f32(&h):1}
        resize(&attributes,base.hostile_int(&h,4)==0?base.hostile_int(&h,8):len(mesh.positions)*stride)
        for &a in attributes {a=base.hostile_f32(&h)}
        resize(&locks,base.hostile_int(&h,2)==0?len(mesh.positions):base.hostile_int(&h,3))
        for &l in locks {l=transmute(Simplify_Vertex)u8(base.hostile_int(&h,8))}
        options:=transmute(Simplify_Options)u32(base.hostile_int(&h,256))
        result,failed:=simplify(destination[:],mesh.indices,mesh.positions,(base.hostile_int(&h,12)-2)*3,base.hostile_f32(&h),options,attributes[:],weights[:stride],locks[:])
        if failed==.None {
            for index in destination[:result.index_count] {testing.expect(t,int(index)<len(mesh.positions))}
        }
        if round%4==0 {
            d,_:=mesh_decompose(mesh,{max_hulls=base.hostile_int(&h,6)-1,max_hull_vertices=base.hostile_int(&h,12)-1,concavity=base.hostile_f32(&h),planes_per_axis=base.hostile_int(&h,5)-1,tolerance=base.hostile_int(&h,3)==0?base.hostile_f32(&h):0})
            decomposition_destroy(&d)
        }
    }
}

@(private="file")
hostile_polygon :: proc(h:^base.Hostile,points:^[dynamic]Vec2,loops:^[dynamic]int) {
    clear(points);clear(loops)
    n:=base.hostile_int(h,20)
    wild:=base.hostile_int(h,4)==0
    for _ in 0..<n {
        p:=hostile_vec3(h,wild)
        append(points,Vec2{p.x,p.y})
    }
    rest:=n
    for rest>0 && len(loops)<4 {
        size:=base.hostile_int(h,rest+3)-1
        append(loops,size)
        rest-=max(size,1)
    }
}

@(test)
hostile_polygons_through_the_ear_clipping :: proc(t:^testing.T) {
    h:=base.Hostile{5}
    points:[dynamic]Vec2
    loops:[dynamic]int
    triangles,pieces,sizes:[dynamic]u32
    defer {delete(points);delete(loops);delete(triangles);delete(pieces);delete(sizes)}
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_polygon(&h,&points,&loops)
        _=polygon_triangulate(points[:],loops[:],&triangles,Polygon_Rule(base.hostile_int(&h,2)))
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
    h:=base.Hostile{7}
    points:[dynamic]Vec2
    loops:[dynamic]int
    triangles,halfedges:[dynamic]u32
    defer {delete(points);delete(loops);delete(triangles);delete(halfedges)}
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_polygon(&h,&points,&loops)
        with_halfedges:=base.hostile_int(&h,2)==0
        count:=delaunay_triangulate(points[:],&triangles,&halfedges if with_halfedges else nil)
        finite:=true
        for p in points {finite&&=p-p=={}}
        if !testing.expect(t,count*3==len(triangles) && (finite || count==0),"A triangulation counts its triangles, and has none of a point that is not finite") {return}
        for index in triangles {
            if !testing.expect(t,int(index)<len(points),"A triangle has a corner that is not a point") {return}
        }
        if !with_halfedges || count==0 {continue}
        if !testing.expect(t,len(halfedges)==len(triangles),"Every edge of a triangle has a place for its opposite") {return}
        for opposite,edge in halfedges {
            if !testing.expect(t,opposite==NONE || (int(opposite)<len(halfedges) && int(halfedges[opposite])==edge),"The opposite of an edge is not an edge that points back") {return}
        }
    }
}

@(test)
hostile_parameters_through_the_primitives :: proc(t:^testing.T) {
    h:=base.Hostile{6}
    out:Mesh_Buffer
    mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&out)
    for _ in 0..<HOSTILE_ROUNDS/4 {
        mesh_buffer_clear(&out)
        count:=base.hostile_int(&h,70)-4
        size:=hostile_vec3(&h,true)
        cube_build(&out,size)
        sphere_build(&out,base.hostile_f32(&h),count,base.hostile_int(&h,70)-4)
        icosphere_build(&out,base.hostile_f32(&h),base.hostile_int(&h,8)-2)
        cylinder_build(&out,base.hostile_f32(&h),base.hostile_f32(&h),count)
        cone_build(&out,base.hostile_f32(&h),base.hostile_f32(&h),count)
        prism_build(&out,size)
        pyramid_build(&out,size)
        capsule_build(&out,base.hostile_f32(&h),base.hostile_f32(&h),count,base.hostile_int(&h,40)-4)
        plane_build(&out,{size.x,size.y},base.hostile_int(&h,40)-4,base.hostile_int(&h,40)-4)
        torus_build(&out,base.hostile_f32(&h),base.hostile_f32(&h),count,base.hostile_int(&h,40)-4)
        path:=[3]Vec3{hostile_vec3(&h,true),hostile_vec3(&h,true),hostile_vec3(&h,true)}
        tube_build(&out,path[:base.hostile_int(&h,4)],{base.hostile_f32(&h),base.hostile_f32(&h)},count,base.hostile_int(&h,20)-4)
        profile:=[3]Vec2{{base.hostile_f32(&h),base.hostile_f32(&h)},{base.hostile_f32(&h),base.hostile_f32(&h)},{base.hostile_f32(&h),base.hostile_f32(&h)}}
        lathe_build(&out,profile[:base.hostile_int(&h,4)],count)
        extrude_build(&out,profile[:base.hostile_int(&h,4)],base.hostile_f32(&h))
        blade:=Blade{base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_int(&h,20)-4}
        blade_build(&out,hostile_vec3(&h,true),hostile_vec3(&h,true),blade)
        fan_build(&out,hostile_vec3(&h,true),base.hostile_int(&h,8)-2,blade,base.hostile_f32(&h),u32(base.hostile_next(&h)))
        blob_build(&out,size,base.hostile_int(&h,4)-1,base.hostile_f32(&h),u32(base.hostile_next(&h)))
        mesh_buffer_paint(&out,{1,1,1,1})
        mesh_buffer_place(&out,base.hostile_int(&h,1<<20)-512,hostile_vec3(&h,true),base.hostile_f32(&h),size)
        if !testing.expect(t,mesh_is_valid(mesh_buffer_view(&out)),"The primitives of any parameters are not a mesh of its own vertices") {return}
        broken:=base.hostile_int(&h,4)==0
        if broken {append(&out.indices,u32(base.hostile_next(&h)))}
        flat:=mesh_buffer_flatten(&out)
        testing.expect(t,broken || (flat && mesh_is_valid(mesh_buffer_view(&out)) && len(out.positions)==len(out.indices)),"A flattened mesh does not have a vertex for every corner")
    }
}

@(test)
hostile_meshes_through_clusters_and_their_dag :: proc(t:^testing.T) {
    h:=base.Hostile{8}
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
        max_vertices,min_triangles,max_triangles:=base.hostile_int(&h,300)-10,base.hostile_int(&h,20)-2,base.hostile_int(&h,600)-10
        resize(&meshlets,meshlets_bound(len(mesh.indices),max_vertices,max(min_triangles,1))+base.hostile_int(&h,3)-1)
        resize(&vertices,len(mesh.indices));resize(&triangles,len(mesh.indices))
        count,failed:=meshlets_build(meshlets[:],vertices[:],triangles[:],mesh.indices,mesh.positions,max_vertices,min_triangles,max_triangles,base.hostile_f32(&h),base.hostile_f32(&h))
        if failed==.None {
            for m in meshlets[:count] {
                testing.expect(t,int(m.vertex_offset+m.vertex_count)<=len(vertices) && int(m.triangle_offset+m.triangle_count*3)<=len(triangles))
            }
        }
        _=cluster_bounds(mesh.indices,mesh.positions)
        radii:=make([]f32,base.hostile_int(&h,2)==0?len(mesh.positions):base.hostile_int(&h,4),context.temp_allocator)
        for &r in radii {r=base.hostile_f32(&h)}
        _,_=spheres_bound(mesh.positions,radii)
        local:[MESHLET_MAX_VERTICES]u32
        local_triangles:[64]u8
        _=meshlet_local_indices(local[:base.hostile_int(&h,len(local)+1)],local_triangles[:],mesh.indices[:min(len(mesh.indices),len(local_triangles))])
        // Clusters of three indices each, or of any count.
        clear(&counts)
        for at:=0;at<len(mesh.indices); {
            n:=min(base.hostile_int(&h,9)+(base.hostile_int(&h,5)==0?0:1),len(mesh.indices)-at)
            append(&counts,u32(n))
            at+=max(n,1)
        }
        resize(&groups,len(counts)+base.hostile_int(&h,3)-1)
        generators:=make([]u32,base.hostile_int(&h,2)==0?len(counts):base.hostile_int(&h,3),context.temp_allocator)
        for &g in generators {g=u32(base.hostile_int(&h,4))}
        _,_=clusters_partition(groups[:],mesh.indices,counts[:],mesh.positions,base.hostile_int(&h,20)-2,generators)
        clear(&ranges)
        for _ in 0..<base.hostile_int(&h,4) {append(&ranges,Cluster_Range{u32(base.hostile_int(&h,len(mesh.indices)+2)),u32(base.hostile_int(&h,len(mesh.indices)+2)),u32(base.hostile_int(&h,3))})}
        weights:=[]f32{base.hostile_f32(&h),1}
        attributes:=make([]f32,base.hostile_int(&h,3)==0?base.hostile_int(&h,9):len(mesh.positions)*2,context.temp_allocator)
        for &a in attributes {a=base.hostile_int(&h,8)==0?base.hostile_f32(&h):f32(base.hostile_int(&h,5))}
        lock:=make([]Simplify_Vertex,base.hostile_int(&h,3)==0?base.hostile_int(&h,4):len(mesh.positions),context.temp_allocator)
        for &l in lock {l=transmute(Simplify_Vertex)u8(base.hostile_int(&h,8))}
        if cluster_dag_build(&dag,{positions=mesh.positions,indices=mesh.indices,ranges=ranges[:],attributes=attributes,attribute_weights=weights[:base.hostile_int(&h,3)],vertex_lock=lock})==.None {
            for c in dag.clusters {testing.expect(t,int(c.first_vertex+c.vertex_count)<=len(dag.vertices) && int(c.first_triangle+c.triangle_count)*3<=len(dag.triangles))}
        }
        clear(&levels)
        for _ in 0..<base.hostile_int(&h,4) {append(&levels,Cluster_Level{u32(base.hostile_int(&h,len(ranges)+2)),u32(base.hostile_int(&h,3)),base.hostile_f32(&h)})}
        _=cluster_levels_build(&dag,mesh.positions,mesh.indices,ranges[:],levels[:])
        free_all(context.temp_allocator)
    }
}
