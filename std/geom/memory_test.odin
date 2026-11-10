package geom

import "base:runtime"
import "core:mem"
import "core:testing"

@(private="file")
Memory_Call :: enum {Slice,Slice_Whole,Fracture,Hull,Hull_Flat,Decompose,Tangents,Triangulate,Cluster_Dag,Cluster_Levels,Surface_Edit,Surface_Refine,Primitives,Weld,Hull_Mesh}

// The most requests a call of the test makes of its allocator.
@(private="file")
MEMORY_REQUESTS :: 1024

@(private="file")
Memory_Source :: struct {
    cube,bracket,ball:Mesh_Buffer,
    hull:Hull,
    sites:[5]Vec3,
    flat:[6]Vec3,
    outline:[8]Vec2, // a square and a hole in it
}

@(private="file")
memory_source_init :: proc(s:^Memory_Source) {
    cube_build(&s.cube,{2,2,2})
    extrude_build(&s.bracket,{{0,0},{2,0},{2,1},{1,1},{1,2},{0,2}},1)
    raw:Mesh_Buffer
    defer mesh_buffer_destroy(&raw)
    icosphere_build(&raw,1,3)
    mesh_weld(mesh_buffer_view(&raw),0,&s.ball)
    s.hull,_=hull_build(s.ball.positions[:],{})
    s.sites={{-0.5,-0.4,-0.3},{0.6,-0.2,0.1},{0.1,0.7,-0.5},{-0.3,0.2,0.6},{0.4,0.5,0.5}}
    s.flat={{0,0,0},{2,0,0},{2,0,1},{1,0,2},{0,0,1},{1,0,0.5}}
    s.outline={{0,0},{4,0},{4,4},{0,4},{1,1},{1,3},{3,3},{3,1}}
}

@(private="file")
memory_source_destroy :: proc(s:^Memory_Source) {
    mesh_buffer_destroy(&s.cube);mesh_buffer_destroy(&s.bracket);mesh_buffer_destroy(&s.ball)
    hull_destroy(&s.hull)
}

// What the calls write and the workspaces they keep, all in one allocator.
@(private="file")
Memory_Rig :: struct {
    allocator:runtime.Allocator,
    slicer:Slicer,
    buffers:[2]Mesh_Buffer,
    sliced:Slice_Result,
    fracture:Fracture,
    hull:Hull,
    parts:Decomposition,
    tangents:[dynamic]Vec4,
    triangles:[dynamic]u32,
    dag:Cluster_Dag,
    work:Mesh_Surface_Workspace,
}

@(private="file")
memory_rig_init :: proc(r:^Memory_Rig,allocator:runtime.Allocator) {
    r.allocator=allocator
    slicer_init(&r.slicer,allocator)
    for &buffer in r.buffers {mesh_buffer_init(&buffer,allocator)}
    fracture_init(&r.fracture,allocator)
    r.tangents=make([dynamic]Vec4,allocator)
    r.triangles=make([dynamic]u32,allocator)
    mesh_surface_workspace_init(&r.work,allocator)
}

@(private="file")
memory_rig_destroy :: proc(r:^Memory_Rig) {
    slicer_destroy(&r.slicer)
    for &buffer in r.buffers {mesh_buffer_destroy(&buffer)}
    fracture_destroy(&r.fracture)
    hull_destroy(&r.hull)
    decomposition_destroy(&r.parts)
    delete(r.tangents);delete(r.triangles)
    cluster_dag_destroy(&r.dag)
    mesh_surface_workspace_destroy(&r.work)
}

// Makes the call with the memory the allocator of the rig has left. refused:
// the call said it had none.
@(private="file")
memory_call :: proc(t:^testing.T,r:^Memory_Rig,s:^Memory_Source,call:Memory_Call,loc:=#caller_location) -> (refused:bool) {
    cube,ball:=mesh_buffer_view(&s.cube),mesh_buffer_view(&s.ball)
    other:bool
    switch call {
    case .Slice,.Slice_Whole:
        error:Slice_Error
        r.sliced,error=mesh_slice(&r.slicer,cube,{{0,1,0},0.25 if call==.Slice else 5},&r.buffers[0],&r.buffers[1])
        refused,other=error==.Out_Of_Memory,error==.Invalid_Mesh || error==.Invalid_Plane
    case .Fracture:
        error:=mesh_fracture(&r.fracture,cube,s.sites[:],{interior_material=1})
        refused,other=error==.Out_Of_Memory,error==.Invalid_Mesh || error==.No_Sites
    case .Hull,.Hull_Flat:
        hull_destroy(&r.hull)
        error:Hull_Error
        r.hull,error=hull_build(s.ball.positions[:] if call==.Hull else s.flat[:],{},r.allocator)
        refused,other=error==.Out_Of_Memory,error!=.None && error!=.Out_Of_Memory
    case .Decompose:
        decomposition_destroy(&r.parts)
        error:Decompose_Error
        r.parts,error=mesh_decompose({positions=s.bracket.positions[:],indices=s.bracket.indices[:]},{concavity=0.01},r.allocator)
        refused,other=error==.Out_Of_Memory,error==.Invalid_Mesh || error==.No_Volume
    case .Tangents:
        refused=!mesh_tangents(cube,&r.buffers[0],&r.tangents)
    case .Triangulate:
        clear(&r.triangles)
        refused=polygon_triangulate(s.outline[:],{4,4},&r.triangles)==0
    case .Cluster_Dag:
        error:=cluster_dag_build(&r.dag,{positions=ball.positions,indices=ball.indices},r.allocator)
        refused,other=error==.Out_Of_Memory,error==.Invalid_Mesh || error==.Invalid_Attributes
    case .Cluster_Levels:
        error:=cluster_levels_build(&r.dag,ball.positions,ball.indices,{{0,u32(len(ball.indices)),0}},{{0,1,0}},r.allocator)
        refused,other=error==.Out_Of_Memory,error==.Invalid_Mesh || error==.Invalid_Attributes
    case .Surface_Edit:
        _,error:=mesh_surface_edit(&r.work,cube,{kind=.Smooth,radius=2,amount=0.5},&r.buffers[0])
        refused,other=error==.Out_Of_Memory,error!=.None && error!=.Out_Of_Memory
    case .Surface_Refine:
        _,error:=mesh_surface_refine(&r.work,cube,{radius=2,max_edge_length=0.5,max_triangles=100},&r.buffers[0])
        refused,other=error==.Out_Of_Memory,error!=.None && error!=.Out_Of_Memory
    case .Primitives:
        out:=&r.buffers[0]
        mesh_buffer_clear(out)
        Shape :: proc(out:^Mesh_Buffer) -> bool
        shapes:=[]Shape{
            proc(out:^Mesh_Buffer) -> bool {return cube_build(out)},proc(out:^Mesh_Buffer) -> bool {return sphere_build(out)},
            proc(out:^Mesh_Buffer) -> bool {return icosphere_build(out)},proc(out:^Mesh_Buffer) -> bool {return cylinder_build(out)},
            proc(out:^Mesh_Buffer) -> bool {return cone_build(out)},proc(out:^Mesh_Buffer) -> bool {return prism_build(out)},
            proc(out:^Mesh_Buffer) -> bool {return pyramid_build(out)},proc(out:^Mesh_Buffer) -> bool {return capsule_build(out)},
            proc(out:^Mesh_Buffer) -> bool {return plane_build(out,{1,1},3,3)},proc(out:^Mesh_Buffer) -> bool {return torus_build(out)},
        }
        for shape,i in shapes {
            held:=[4]int{len(out.positions),len(out.normals),len(out.uvs),len(out.indices)}
            if shape(out) {continue}
            refused=true
            testing.expectf(t,held==[4]int{len(out.positions),len(out.normals),len(out.uvs),len(out.indices)},"the shape %d that was refused appended a part of itself",i,loc=loc)
            mesh_buffer_clear(out)
            break
        }
    case .Weld:
        refused=!mesh_weld(cube,0,&r.buffers[0])
    case .Hull_Mesh:
        mesh_buffer_clear(&r.buffers[0])
        refused=!hull_append_mesh(s.hull,&r.buffers[0])
    }
    testing.expectf(t,!other,"%v: an error that is not of memory",call,loc=loc)
    return
}

@(private="file")
buffer_empty :: proc(b:^Mesh_Buffer) -> bool {
    return len(b.positions)+len(b.normals)+len(b.uvs)+len(b.colors)+len(b.indices)+len(b.materials)==0
}

// A call that was refused left nothing of what it writes.
@(private="file")
memory_rig_empty :: proc(r:^Memory_Rig,call:Memory_Call) -> bool {
    switch call {
    case .Slice,.Slice_Whole:           return buffer_empty(&r.buffers[0]) && buffer_empty(&r.buffers[1]) && r.sliced=={}
    case .Fracture:                     return buffer_empty(&r.fracture.mesh) && len(r.fracture.pieces)+len(r.fracture.connections)==0
    case .Hull,.Hull_Flat:              return r.hull.vertices==nil && r.hull.sources==nil && r.hull.planes==nil && r.hull.faces==nil && r.hull.face_vertices==nil && r.hull.half_edges==nil
    case .Decompose:                    return r.parts.hulls==nil
    case .Tangents:                     return buffer_empty(&r.buffers[0]) && len(r.tangents)==0
    case .Triangulate:                  return len(r.triangles)==0
    case .Cluster_Dag,.Cluster_Levels:  return len(r.dag.clusters)+len(r.dag.vertices)+len(r.dag.triangles)+r.dag.groups+r.dag.levels==0
    case .Surface_Edit,.Surface_Refine: return buffer_empty(&r.buffers[0])
    case .Primitives,.Weld,.Hull_Mesh:  return buffer_empty(&r.buffers[0])
    }
    return false
}

@(private="file")
memory_rig_equal :: proc(a,b:^Memory_Rig,call:Memory_Call) -> bool {
    switch call {
    case .Slice,.Slice_Whole:
        return buffers_equal(&a.buffers[0],&b.buffers[0]) && buffers_equal(&a.buffers[1],&b.buffers[1]) && a.sliced==b.sliced &&
            bytes_equal(a.slicer.sources[0][:],b.slicer.sources[0][:]) && bytes_equal(a.slicer.sources[1][:],b.slicer.sources[1][:])
    case .Fracture:
        return fractures_equal(&a.fracture,&b.fracture)
    case .Hull,.Hull_Flat:
        return hulls_equal(a.hull,b.hull)
    case .Decompose:
        if len(a.parts.hulls)!=len(b.parts.hulls) || a.parts.volume!=b.parts.volume || a.parts.concavity!=b.parts.concavity {return false}
        for hull,i in a.parts.hulls {
            if !hulls_equal(hull,b.parts.hulls[i]) {return false}
        }
        return true
    case .Tangents:
        return buffers_equal(&a.buffers[0],&b.buffers[0]) && bytes_equal(a.tangents[:],b.tangents[:])
    case .Triangulate:
        return bytes_equal(a.triangles[:],b.triangles[:])
    case .Cluster_Dag,.Cluster_Levels:
        return bytes_equal(a.dag.clusters[:],b.dag.clusters[:]) && bytes_equal(a.dag.vertices[:],b.dag.vertices[:]) && bytes_equal(a.dag.triangles[:],b.dag.triangles[:]) &&
            a.dag.groups==b.dag.groups && a.dag.levels==b.dag.levels
    case .Surface_Edit,.Surface_Refine,.Primitives,.Weld,.Hull_Mesh:
        return buffers_equal(&a.buffers[0],&b.buffers[0])
    }
    return false
}

// What the package asks the allocator of its caller for, with the memory
// ending at each request in turn: the call says so and leaves nothing of what
// it writes, the workspace it used gives, with memory again, what a new one
// gives, and nothing stays allocated once it is destroyed. The writes without
// bounds checks are covered by running it over a copy of the package without
// #no_bounds_check.
@(test)
calls_without_memory_fail_whole_and_their_workspaces_work_again :: proc(t:^testing.T) {
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    limit:=Boolean_Failing_Allocator{mem.tracking_allocator(&track),-1}
    limited:=runtime.Allocator{data=&limit,procedure=boolean_failing_allocate}
    s:Memory_Source
    memory_source_init(&s)
    defer memory_source_destroy(&s)
    for call in Memory_Call {
        reference:Memory_Rig
        memory_rig_init(&reference,context.allocator)
        defer memory_rig_destroy(&reference)
        if !testing.expectf(t,!memory_call(t,&reference,&s,call),"%v: refused with memory",call) {continue}
        done,refused:=false,false
        for served in 0..<MEMORY_REQUESTS {
            r:Memory_Rig
            memory_rig_init(&r,limited)
            limit.left=served
            failed:=memory_call(t,&r,&s,call)
            limit.left=-1
            if failed {
                refused=true
                testing.expectf(t,memory_rig_empty(&r,call),"%v with %d requests served: it left a part of its result",call,served)
                testing.expectf(t,!memory_call(t,&r,&s,call),"%v after %d requests served: refused with memory",call,served)
            }
            testing.expectf(t,memory_rig_equal(&r,&reference,call),"%v with %d requests served: not what a new workspace gives",call,served)
            memory_rig_destroy(&r)
            testing.expectf(t,len(track.allocation_map)==0 && len(track.bad_free_array)==0,"%v with %d requests served: %d allocations are left",call,served,len(track.allocation_map))
            if done=!failed;done {break}
        }
        testing.expectf(t,done && refused,"%v: refused without memory %v, went through with it %v",call,refused,done)
    }
}
