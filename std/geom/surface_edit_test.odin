package geom

import "base:runtime"
import "core:testing"
import "core:time"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
surface_brush_sculpts_in_any_direction_and_flattens_an_oriented_plane :: proc(t:^testing.T) {
    mesh,out:Mesh_Buffer
    mesh_buffer_init(&mesh);mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&mesh);defer mesh_buffer_destroy(&out)
    plane_build(&mesh,{4,4},4,4)
    for p in mesh.positions {append(&mesh.colors,Vec4{p.x,p.z,0,1})}
    for i in 0..<len(mesh.indices)/3 {append(&mesh.materials,u32(i%3))}
    source:=mesh_buffer_view(&mesh)
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    result,error:=mesh_surface_edit(&work,source,{kind=.Sculpt,normal={2,0,0},radius=1.5,amount=0.25},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    testing.expect(t,result.changed && result.vertices>0)
    for p,i in source.positions {
        if p==(Vec3{}) {testing.expect_value(t,out.positions[i],Vec3{0.25,0,0})}
        if dlength(dvec(p))>=1.5 {testing.expect_value(t,out.positions[i],p)}
        testing.expect_value(t,out.uvs[i],source.uvs[i]);testing.expect_value(t,out.colors[i],source.colors[i])
    }
    testing.expect(t,bytes_equal(out.indices[:],source.indices) && bytes_equal(out.materials[:],source.materials))
    result,error=mesh_surface_edit(&work,source,{kind=.Flatten,center={0,1,0},normal={1,1,0},radius=10,amount=1},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    for p,i in source.positions {
        before:=abs(f64(p.x)+f64(p.y)-1)
        after:=abs(f64(out.positions[i].x)+f64(out.positions[i].y)-1)
        testing.expect(t,after<=before+1e-6)
    }
    testing.expect(t,result.low.y<=0 && result.high.y>0)
}

@(test)
surface_smoothing_preserves_boundaries_and_moves_attribute_seams_together :: proc(t:^testing.T) {
    mesh,out:Mesh_Buffer
    mesh_buffer_init(&mesh);mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&mesh);defer mesh_buffer_destroy(&out)
    plane_build(&mesh,{4,4},4,4)
    for &p in mesh.positions {if p==(Vec3{}) {p.y=1}}
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    result,error:=mesh_surface_edit(&work,mesh_buffer_view(&mesh),{kind=.Smooth,radius=8,amount=0.5,lock_boundary=true},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    testing.expect(t,result.changed)
    for p,i in mesh.positions {
        if abs(p.x)==2 || abs(p.z)==2 {testing.expect_value(t,out.positions[i],p)}
        if p==(Vec3{0,1,0}) {testing.expect(t,out.positions[i].y<1 && out.positions[i].y>0)}
    }
    mesh_buffer_clear(&mesh);cube_build(&mesh)
    result,error=mesh_surface_edit(&work,mesh_buffer_view(&mesh),{kind=.Smooth,radius=2,amount=0.1},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    for p,i in mesh.positions {for q,j in mesh.positions {if p==q {testing.expect_value(t,out.positions[i],out.positions[j])}}}
    testing.expect(t,mesh_is_closed(out.positions[:],out.indices[:]))
}

@(test)
surface_refinement_is_conforming_on_closed_meshes_and_attribute_seams :: proc(t:^testing.T) {
    mesh,out,again:Mesh_Buffer
    for b in ([]^Mesh_Buffer{&mesh,&out,&again}) {mesh_buffer_init(b)}
    defer for b in ([]^Mesh_Buffer{&mesh,&out,&again}) {mesh_buffer_destroy(b)}
    cube_build(&mesh)
    for p in mesh.positions {append(&mesh.colors,Vec4{p.x+0.5,p.y+0.5,p.z+0.5,1})}
    for i in 0..<len(mesh.indices)/3 {append(&mesh.materials,u32(i))}
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    desc:=Mesh_Surface_Refine{center={0.4,0.4,0.4},radius=0.55,max_edge_length=0.6,max_triangles=100}
    result,error:=mesh_surface_refine(&work,mesh_buffer_view(&mesh),desc,&out)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    testing.expect(t,result.changed && result.vertices>0 && result.triangles>12)
    topology:=mesh_topology(out.positions[:],out.indices[:])
    testing.expect(t,mesh_topology_is_closed(topology))
    testing.expect(t,abs(mesh_volume(out.positions[:],out.indices[:])-1)<1e-6)
    for p,i in mesh.positions {testing.expect_value(t,out.positions[i],p);testing.expect_value(t,out.uvs[i],mesh.uvs[i])}
    for p,i in out.positions {testing.expect_value(t,out.colors[i],Vec4{p.x+0.5,p.y+0.5,p.z+0.5,1})}
    for triangle in 0..<len(out.indices)/3 {
        slot:=out.materials[triangle]
        for k in 0..<3 {testing.expect_value(t,out.normals[out.indices[triangle*3+k]],mesh.normals[mesh.indices[slot*3]])}
    }
    _,error=mesh_surface_refine(&work,mesh_buffer_view(&mesh),desc,&again)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    testing.expect(t,buffers_equal(&out,&again))
}

@(test)
surface_refinement_covers_every_split_pattern_without_changing_area :: proc(t:^testing.T) {
    positions:=[3]Vec3{{0,0,0},{2,0,0},{0,2,0}}
    indices:=[3]u32{0,1,2}
    mesh:=Mesh{positions=positions[:],indices=indices[:]}
    out:Mesh_Buffer;mesh_buffer_init(&out);defer mesh_buffer_destroy(&out)
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    cases:=[4]Mesh_Surface_Refine{
        {center={8,8,0},radius=0.1,max_edge_length=1,max_triangles=4},
        {center={1,0,0},radius=0.1,max_edge_length=1,max_triangles=4},
        {center={0,0,0},radius=0.1,max_edge_length=1,max_triangles=4},
        {center={0,0,0},radius=8,max_edge_length=1,max_triangles=4},
    }
    for desc,i in cases {
        result,error:=mesh_surface_refine(&work,mesh,desc,&out)
        testing.expect_value(t,error,Mesh_Surface_Error.None)
        testing.expect_value(t,result.triangles,i+1)
        testing.expect(t,abs(mesh_area(out.positions[:],out.indices[:])-2)<1e-6)
        for j:=0;j<len(out.indices);j+=3 {
            a,b,c:=dvec(out.positions[out.indices[j]]),dvec(out.positions[out.indices[j+1]]),dvec(out.positions[out.indices[j+2]])
            testing.expect(t,dcross(b-a,c-a).z>0)
        }
    }
    _,error:=mesh_surface_refine(&work,mesh,{radius=8,max_edge_length=1,max_triangles=3},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.Budget_Exceeded);testing.expect_value(t,len(out.indices),0)
    result:Mesh_Surface_Result
    result,error=mesh_surface_refine(&work,mesh,{radius=8,max_edge_length=1,max_triangles=4,lock_boundary=true},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.None);testing.expect(t,!result.changed)
}

@(test)
surface_brush_and_refinement_match_independently_processed_chunk_borders :: proc(t:^testing.T) {
    whole:Mesh_Buffer;mesh_buffer_init(&whole);defer mesh_buffer_destroy(&whole)
    plane_build(&whole,{4,4},4,4)
    indices:[2][dynamic]u32
    defer for list in indices {delete(list)}
    for t:=0;t<len(whole.indices);t+=3 {
        sum:f32
        for k in 0..<3 {sum+=whole.positions[whole.indices[t+k]].x}
        append(&indices[sum>0?1:0],..whole.indices[t:t+3])
    }
    parts:[2]Mesh_Buffer
    for &part in parts {mesh_buffer_init(&part)}
    defer for &part in parts {mesh_buffer_destroy(&part)}
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    for chunk in 0..<2 {
        source:=mesh_buffer_view(&whole);source.indices=indices[chunk][:]
        _,error:=mesh_surface_refine(&work,source,{center={},radius=1.5,max_edge_length=0.75,max_triangles=100},&parts[chunk])
        testing.expect_value(t,error,Mesh_Surface_Error.None)
    }
    for p in parts[0].positions {
        if p.x!=0 {continue}
        found:=false
        for q in parts[1].positions {if p==q {found=true;break}}
        testing.expect(t,found)
    }
    for chunk in 0..<2 {
        source:=mesh_buffer_view(&whole);source.indices=indices[chunk][:]
        _,error:=mesh_surface_edit(&work,source,{center={},normal={1,2,3},radius=2,amount=0.3},&parts[chunk])
        testing.expect_value(t,error,Mesh_Surface_Error.None)
    }
    for p,i in whole.positions {if p.x==0 {testing.expect_value(t,parts[0].positions[i],parts[1].positions[i])}}
}

@(test)
surface_operations_validate_inputs_aliases_budgets_and_memory_failure :: proc(t:^testing.T) {
    mesh,out:Mesh_Buffer
    mesh_buffer_init(&mesh);mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&mesh);defer mesh_buffer_destroy(&out)
    cube_build(&mesh)
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    brush:=Mesh_Surface_Brush{normal={0,1,0},radius=1,amount=0.2}
    _,error:=mesh_surface_edit(&work,mesh_buffer_view(&mesh),brush,&mesh)
    testing.expect_value(t,error,Mesh_Surface_Error.Aliased_Output);testing.expect_value(t,len(mesh.indices),36)
    uninitialized:Mesh_Surface_Workspace
    _,error=mesh_surface_edit(&uninitialized,mesh_buffer_view(&mesh),brush,&out)
    testing.expect_value(t,error,Mesh_Surface_Error.Invalid_Mesh)
    for radius in ([]f32{0,-1,f32(0h7f800000),f32(0h7fc00000)}) {
        invalid:=brush;invalid.radius=radius
        _,error=mesh_surface_edit(&work,mesh_buffer_view(&mesh),invalid,&out)
        testing.expect_value(t,error,Mesh_Surface_Error.Invalid_Brush)
    }
    for hardness in ([]f32{-1,1,f32(0h7f800000),f32(0h7fc00000)}) {
        invalid:=brush;invalid.hardness=hardness
        _,error=mesh_surface_edit(&work,mesh_buffer_view(&mesh),invalid,&out)
        testing.expect_value(t,error,Mesh_Surface_Error.Invalid_Brush)
    }
    empty:Mesh_Buffer;mesh_buffer_init(&empty,runtime.nil_allocator());defer mesh_buffer_destroy(&empty)
    _,error=mesh_surface_edit(&work,mesh_buffer_view(&mesh),brush,&empty)
    testing.expect_value(t,error,Mesh_Surface_Error.Out_Of_Memory)
    failed:Mesh_Surface_Workspace;mesh_surface_workspace_init(&failed,runtime.nil_allocator());defer mesh_surface_workspace_destroy(&failed)
    _,error=mesh_surface_refine(&failed,mesh_buffer_view(&mesh),{radius=2,max_edge_length=0.5,max_triangles=100},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.Out_Of_Memory)
    _,error=mesh_surface_edit(&failed,mesh_buffer_view(&mesh),{kind=.Smooth,radius=2,amount=0.5},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.Out_Of_Memory)
    source:=mesh_buffer_view(&mesh);mesh.positions[0].x=f32(0h7fc00000)
    _,error=mesh_surface_edit(&work,source,brush,&out)
    testing.expect_value(t,error,Mesh_Surface_Error.Invalid_Mesh)
    mesh.positions[0].x=0;mesh.indices[0]=max(u32)
    _,error=mesh_surface_refine(&work,source,{radius=1,max_edge_length=1,max_triangles=100},&out)
    testing.expect_value(t,error,Mesh_Surface_Error.Invalid_Mesh)
}

@(test)
surface_operations_reuse_capacity_after_warmup :: proc(t:^testing.T) {
    mesh,out:Mesh_Buffer
    mesh_buffer_init(&mesh);mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&mesh);defer mesh_buffer_destroy(&out)
    sphere_build(&mesh,1,12,8)
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    source:=mesh_buffer_view(&mesh)
    desc:=Mesh_Surface_Refine{radius=2,max_edge_length=0.2,max_triangles=2000}
    _,error:=mesh_surface_refine(&work,source,desc,&out)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    set_allocators :: proc(w:^Mesh_Surface_Workspace,out:^Mesh_Buffer,allocator:runtime.Allocator) {
        w.representatives.allocator=allocator;w.next.allocator=allocator;w.corner_edges.allocator=allocator
        w.sums.allocator=allocator;w.counts.allocator=allocator;w.locked.allocator=allocator;w.edges.allocator=allocator
        w.points.keys.allocator=allocator;w.points.values.allocator=allocator
        w.edge_map.keys.allocator=allocator;w.edge_map.values.allocator=allocator
        w.midpoints.keys.allocator=allocator;w.midpoints.values.allocator=allocator
        out.positions.allocator=allocator;out.normals.allocator=allocator;out.indices.allocator=allocator
        out.uvs.allocator=allocator;out.colors.allocator=allocator;out.materials.allocator=allocator
    }
    set_allocators(&work,&out,runtime.nil_allocator())
    for _ in 0..<4 {
        _,error=mesh_surface_refine(&work,source,desc,&out)
        testing.expect_value(t,error,Mesh_Surface_Error.None)
        _,error=mesh_surface_edit(&work,source,{kind=.Smooth,radius=2,amount=0.1},&out)
        testing.expect_value(t,error,Mesh_Surface_Error.None)
    }
    set_allocators(&work,&out,context.allocator)
}

@(test)
surface_normals_join_smooth_chunk_seams_and_keep_untouched_vertices :: proc(t:^testing.T) {
    shared,split,a,b:Mesh_Buffer
    for out in ([]^Mesh_Buffer{&shared,&split,&a,&b}) {mesh_buffer_init(out)}
    defer for out in ([]^Mesh_Buffer{&shared,&split,&a,&b}) {mesh_buffer_destroy(out)}
    plane_build(&shared,{8,8},8,8)
    for i in shared.indices {
        append(&split.positions,shared.positions[i]);append(&split.normals,shared.normals[i])
        append(&split.uvs,shared.uvs[i]);append(&split.indices,u32(len(split.indices)))
    }
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    brush:=Mesh_Surface_Brush{kind=.Sculpt,center={0.1,0,0.1},normal={0,1,0},radius=1.5,amount=0.5}
    _,error:=mesh_surface_edit(&work,mesh_buffer_view(&shared),brush,&a)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    _,error=mesh_surface_edit(&work,mesh_buffer_view(&split),brush,&b)
    testing.expect_value(t,error,Mesh_Surface_Error.None)
    for original,i in shared.indices {
        testing.expect_value(t,b.positions[i],a.positions[original])
        testing.expect_value(t,b.normals[i],a.normals[original])
    }
    for p,i in shared.positions {if abs(p.x)==4 || abs(p.z)==4 {testing.expect_value(t,a.normals[i],shared.normals[i])}}
}

@(test)
surface_operations_return_on_hostile_meshes_and_parameters :: proc(t:^testing.T) {
    rounds :: #config(GEOM_HOSTILE_ROUNDS,400)
    rng:=base.rng_make(1743)
    positions,normals:[12]Vec3
    indices:[24]u32
    out:Mesh_Buffer;mesh_buffer_init(&out);defer mesh_buffer_destroy(&out)
    work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
    scalar :: proc(rng:^base.Rng) -> f32 {
        switch base.rng_u32(rng)%8 {
        case 0:return f32(0h7fc00000)
        case 1:return f32(0h7f800000)
        case 2:return 1e30
        case 3:return 1e-30
        case 4:return 0
        }
        return mm.random_range(rng,-4,4)
    }
    for iteration in 0..<rounds {
        for &p in positions {p={scalar(&rng),scalar(&rng),scalar(&rng)}}
        for &n in normals {n={scalar(&rng),scalar(&rng),scalar(&rng)}}
        for &i in indices {i=base.rng_u32(&rng)%14}
        mesh:=Mesh{positions=positions[:],normals=normals[:int(base.rng_u32(&rng)%13)],indices=indices[:int(base.rng_u32(&rng)%25)]}
        brush:=Mesh_Surface_Brush{kind=Mesh_Surface_Brush_Kind(base.rng_u32(&rng)%6),center={scalar(&rng),0,scalar(&rng)},normal={scalar(&rng),1,scalar(&rng)},delta={scalar(&rng),scalar(&rng),scalar(&rng)},radius=scalar(&rng),amount=scalar(&rng),hardness=scalar(&rng),lock_boundary=base.rng_u32(&rng)%2==0}
        if iteration%4==0 {
            for &p in positions {p=mm.random_in_sphere(&rng)*((iteration%8==0)?1e30:1e-30)}
            for &n in normals {n={0,1,0}}
            for &i in indices {i=base.rng_u32(&rng)%u32(len(positions))}
            mesh={positions=positions[:],normals=normals[:],indices=indices[:]}
            brush={kind=Mesh_Surface_Brush_Kind((iteration/4)%4),normal={1,2,3},rotation=quaternion(w=scalar(&rng),x=scalar(&rng),y=scalar(&rng),z=scalar(&rng)),radius=2e30,amount=0.1}
        }
        _,error:=mesh_surface_edit(&work,mesh,brush,&out)
        if error==.None {testing.expect(t,mesh_is_valid(mesh_buffer_view(&out)));for p in out.positions {testing.expect(t,finite3(p))}}
        _,error=mesh_surface_refine(&work,mesh,{center=brush.center,radius=brush.radius,max_edge_length=scalar(&rng),max_triangles=int(base.rng_u32(&rng)%80)-1},&out)
        if error==.None {testing.expect(t,mesh_is_valid(mesh_buffer_view(&out)));for p in out.positions {testing.expect(t,finite3(p))}}
    }
}

@(test)
bench_surface_edit :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        mesh,out:Mesh_Buffer
        mesh_buffer_init(&mesh);mesh_buffer_init(&out)
        defer mesh_buffer_destroy(&mesh);defer mesh_buffer_destroy(&out)
        plane_build(&mesh,{32,32},32,32)
        work:Mesh_Surface_Workspace;mesh_surface_workspace_init(&work);defer mesh_surface_workspace_destroy(&work)
        source:=mesh_buffer_view(&mesh)
        for kind in ([4]Mesh_Surface_Brush_Kind{.Sculpt,.Smooth,.Flatten,.Drag}) {
            brush:=Mesh_Surface_Brush{kind=kind,center={0,0.5,0},normal={1,2,0},delta={0.1,0.2,0},radius=4,amount=0.1,hardness=kind==.Drag?0.5:0}
            mesh_surface_edit(&work,source,brush,&out)
            start:=time.tick_now()
            for _ in 0..<200 {mesh_surface_edit(&work,source,brush,&out)}
            bench_report(kind==.Sculpt?"surface Sculpt 2048 triangles":kind==.Smooth?"surface Smooth 2048 triangles":kind==.Flatten?"surface Flatten 2048 triangles":"surface Drag 2048 triangles",200,time.tick_since(start))
        }
        desc:=Mesh_Surface_Refine{radius=4,max_edge_length=0.75,max_triangles=8192}
        mesh_surface_refine(&work,source,desc,&out)
        start:=time.tick_now()
        for _ in 0..<200 {mesh_surface_refine(&work,source,desc,&out)}
        bench_report("surface Refine 2048 triangles",200,time.tick_since(start))
    }
}
