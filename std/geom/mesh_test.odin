package geom

import "core:testing"

// Box with four vertices per face, like a render mesh: closed by position only.
@(private) test_box :: proc(b:^Mesh_Buffer,lo,hi:Vec3,material:u32=0) {
    normals:=[6]Vec3{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}
    center,half:=(lo+hi)*0.5,(hi-lo)*0.5
    for n in normals {
        u:=Vec3{n.y,n.z,n.x}
        w:=Vec3{n.y*u.z-n.z*u.y,n.z*u.x-n.x*u.z,n.x*u.y-n.y*u.x}
        base:=u32(len(b.positions))
        corners:=[4]Vec3{n-u-w,n+u-w,n+u+w,n-u+w}
        for c,i in corners {
            append(&b.positions,center+c*half)
            append(&b.normals,n)
            append(&b.uvs,Vec2{f32(i&1~(i>>1)),f32(i>>1)})
        }
        append(&b.indices,base,base+1,base+2,base,base+2,base+3)
        append(&b.materials,material,material)
    }
}

@(test)
weld_merges_positions_to_their_first_occurrence :: proc(t:^testing.T) {
    positions:=[]Vec3{{0,0,0},{1,0,0},{0,0,0},{1,0,0.0005},{-0.0,0,0},{2,0,0},{1,0,0}}
    remap:[7]u32
    testing.expect_value(t,positions_weld(positions,0,remap[:]),4)
    testing.expect_value(t,remap,[7]u32{0,1,0,3,0,5,1})
    testing.expect_value(t,positions_weld(positions,0.001,remap[:]),3)
    testing.expect_value(t,remap,[7]u32{0,1,0,1,0,5,1})
    // Chains do not drift: a vertex only merges into a representative.
    chain:=[]Vec3{{0,0,0},{0.6,0,0},{1.2,0,0},{1.8,0,0}}
    testing.expect_value(t,positions_weld(chain,1,remap[:4]),2)
    testing.expect_value(t,remap[0],u32(0))
    testing.expect_value(t,remap[1],u32(0))
    testing.expect_value(t,remap[2],u32(2))
    testing.expect_value(t,remap[3],u32(2))
    testing.expect_value(t,positions_weld(nil,0,nil),0)
}

@(test)
weld_collapses_a_box_and_can_keep_its_seams :: proc(t:^testing.T) {
    box,out:Mesh_Buffer
    mesh_buffer_init(&box);mesh_buffer_init(&out)
    defer mesh_buffer_destroy(&box)
    defer mesh_buffer_destroy(&out)
    test_box(&box,{-1,-1,-1},{1,1,1},3)
    // A sliver that welding turns into a line disappears.
    append(&box.positions,Vec3{5,5,5},Vec3{5,5,5.00001},Vec3{6,5,5})
    append(&box.normals,Vec3{0,1,0},Vec3{0,1,0},Vec3{0,1,0})
    append(&box.uvs,Vec2{},Vec2{},Vec2{})
    append(&box.indices,24,25,26)
    append(&box.materials,9)
    mesh_weld(mesh_buffer_view(&box),0.001,&out)
    testing.expect_value(t,len(out.positions),8)
    testing.expect_value(t,len(out.indices),36)
    testing.expect_value(t,len(out.normals),8)
    testing.expect_value(t,len(out.materials),12)
    testing.expect(t,mesh_is_valid(mesh_buffer_view(&out)))
    testing.expect(t,mesh_is_closed(out.positions[:],out.indices[:]))
    for m in out.materials {testing.expect_value(t,m,u32(3))}
    mesh_weld(mesh_buffer_view(&box),0.001,&out,keep_seams=true)
    testing.expect_value(t,len(out.positions),24)
    testing.expect_value(t,len(out.indices),36)
}

@(test)
topology_tells_closed_open_and_non_manifold_meshes_apart :: proc(t:^testing.T) {
    box:Mesh_Buffer
    mesh_buffer_init(&box)
    defer mesh_buffer_destroy(&box)
    test_box(&box,{0,0,0},{1,2,3})
    adjacency:=make([]u32,len(box.indices))
    defer delete(adjacency)
    topology:=mesh_topology(box.positions[:],box.indices[:],adjacency)
    testing.expect_value(t,topology,Mesh_Topology{})
    testing.expect(t,mesh_is_closed(box.positions[:],box.indices[:]))
    for twin,h in adjacency {
        testing.expect(t,twin!=NONE && adjacency[twin]==u32(h))
        a,b:=box.positions[box.indices[h]],box.positions[box.indices[h/3*3+(h%3+1)%3]]
        c,d:=box.positions[box.indices[twin]],box.positions[box.indices[twin/3*3+(twin%3+1)%3]]
        testing.expect(t,a==d && b==c)
    }
    // By index the 24 vertices of the box are six separate quads.
    by_index:=mesh_topology(box.positions[:],box.indices[:],nil,false)
    testing.expect_value(t,by_index.boundary_edges,24)

    open:=box.indices[:len(box.indices)-3]
    topology=mesh_topology(box.positions[:],open)
    testing.expect_value(t,topology.boundary_edges,3)
    testing.expect_value(t,topology.non_manifold_edges,0)
    testing.expect(t,!mesh_is_closed(box.positions[:],open))

    flipped:=make([]u32,len(box.indices))
    defer delete(flipped)
    copy(flipped,box.indices[:])
    flipped[0],flipped[1]=flipped[1],flipped[0]
    topology=mesh_topology(box.positions[:],flipped)
    testing.expect_value(t,topology.non_manifold_edges,6)
    testing.expect(t,!mesh_topology_is_closed(topology))

    doubled:[dynamic]u32
    defer delete(doubled)
    append(&doubled,..box.indices[:])
    append(&doubled,box.indices[0],box.indices[1],box.indices[2])
    topology=mesh_topology(box.positions[:],doubled[:])
    testing.expect(t,topology.non_manifold_edges>0)

    degenerate:[dynamic]u32
    defer delete(degenerate)
    append(&degenerate,..box.indices[:])
    append(&degenerate,box.indices[0],box.indices[0],box.indices[1])
    topology=mesh_topology(box.positions[:],degenerate[:])
    testing.expect_value(t,topology.degenerate_triangles,1)
    testing.expect_value(t,topology.boundary_edges,0)
}

@(test)
topology_finds_a_vertex_shared_by_two_fans :: proc(t:^testing.T) {
    // Two tetrahedra that touch at the origin.
    positions:=[]Vec3{{0,0,0},{1,0,0},{0,1,0},{0,0,1},{-1,0,0},{0,-1,0},{0,0,-1}}
    indices:=[]u32{0,2,1, 0,1,3, 0,3,2, 1,2,3, 0,4,5, 0,6,4, 0,5,6, 4,6,5}
    topology:=mesh_topology(positions,indices)
    testing.expect_value(t,topology.boundary_edges,0)
    testing.expect_value(t,topology.non_manifold_edges,0)
    testing.expect_value(t,topology.pinched_vertices,1)
    testing.expect(t,!mesh_is_closed(positions,indices))
    labels:[8]u32
    testing.expect_value(t,mesh_components(positions,indices,labels[:]),1)
}

@(test)
components_are_numbered_by_their_first_triangle :: proc(t:^testing.T) {
    boxes:Mesh_Buffer
    mesh_buffer_init(&boxes)
    defer mesh_buffer_destroy(&boxes)
    test_box(&boxes,{0,0,0},{1,1,1})
    test_box(&boxes,{5,0,0},{6,1,1})
    test_box(&boxes,{1,1,1},{2,2,2})
    labels:=make([]u32,len(boxes.indices)/3)
    defer delete(labels)
    testing.expect_value(t,mesh_components(boxes.positions[:],boxes.indices[:],labels),2)
    for label,i in labels {testing.expect_value(t,label,u32(1) if i/12==1 else u32(0))}
}

@(test)
normals_of_a_welded_box_point_along_its_diagonals :: proc(t:^testing.T) {
    box,welded:Mesh_Buffer
    mesh_buffer_init(&box);mesh_buffer_init(&welded)
    defer mesh_buffer_destroy(&box)
    defer mesh_buffer_destroy(&welded)
    test_box(&box,{-1,-1,-1},{1,1,1})
    mesh_weld(mesh_buffer_view(&box),0,&welded)
    mesh_compute_normals(welded.positions[:],welded.indices[:],welded.normals[:])
    for n,i in welded.normals {
        p:=welded.positions[i]
        for k in 0..<3 {testing.expectf(t,abs(n[k]-p[k]*0.57735027)<1e-5,"normal %v at %v",n,p)}
    }
    lo,hi:=mesh_bounds(welded.positions[:])
    testing.expect_value(t,lo,Vec3{-1,-1,-1})
    testing.expect_value(t,hi,Vec3{1,1,1})
    testing.expect_value(t,mesh_volume(box.positions[:],box.indices[:]),8)
    testing.expect_value(t,mesh_area(box.positions[:],box.indices[:]),24)
}

@(test)
topology_tells_watertight_from_manifold :: proc(t:^testing.T) {
    // Two tetrahedra glued along the edge 0-1: four triangles share it, two
    // in each direction.
    positions:=[]Vec3{{0,0,0},{1,0,0},{0,1,0},{0,0,1},{0,-1,0},{0,0,-1}}
    indices:=[]u32{0,2,1, 0,1,3, 0,3,2, 1,2,3, 0,4,1, 0,1,5, 0,5,4, 1,4,5}
    topology:=mesh_topology(positions,indices)
    testing.expect_value(t,topology.boundary_edges,0)
    testing.expect_value(t,topology.non_manifold_edges,4)
    testing.expect(t,mesh_topology_is_watertight(topology) && !mesh_topology_is_closed(topology))
    // Without one triangle the surplus of each open edge is counted once.
    topology=mesh_topology(positions,indices[3:])
    testing.expect_value(t,topology.boundary_edges,3)
    testing.expect(t,!mesh_topology_is_watertight(topology))
}
