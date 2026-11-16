package importer

import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:std/geom"
import mm "mirai:std/math"

// The nodes that the names of a source make collision only are colliders of
// the mesh they name, placed where they are in its space, and leave the
// model with the meshes only they show: each piece of a UCX_ a hull, a UBX_
// the box it is, a USP_ the sphere, a UCP_ the capsule around it, and a
// -colonly under a mesh its triangles. A -col mesh stays drawn and collides
// with its own triangles.
@(test)
the_names_of_nodes_author_the_colliders_of_the_mesh_they_name :: proc(t:^testing.T) {
    r:=Reader{out=context.temp_allocator}
    r.nodes.allocator,r.meshes.allocator,r.colliders.allocator,r.warnings.allocator=context.temp_allocator,context.temp_allocator,context.temp_allocator,context.temp_allocator
    mesh_of :: proc(r:^Reader,name:string,buffer:^geom.Mesh_Buffer,offset:geom.Vec3={}) -> int {
        vertices:=make([]asset.Vertex,len(buffer.positions),context.temp_allocator)
        for p,i in buffer.positions {vertices[i]=asset.Vertex{position=p+offset}}
        append(&r.meshes,Imported_Mesh{name=name,vertices=vertices,indices=buffer.indices[:],skeleton=-1})
        return len(r.meshes)-1
    }
    node_of :: proc(r:^Reader,name:string,mesh,parent:int,position:[3]f32={}) -> int {
        append(&r.nodes,Imported_Node{name=name,parent=parent,transform={position,1,{1,1,1}},mesh=mesh,visible=true})
        return len(r.nodes)-1
    }
    shape :: proc(build:proc(out:^geom.Mesh_Buffer) -> bool) -> ^geom.Mesh_Buffer {
        buffer:=new(geom.Mesh_Buffer,context.temp_allocator)
        geom.mesh_buffer_init(buffer,context.temp_allocator)
        build(buffer)
        return buffer
    }
    cube:=shape(proc(out:^geom.Mesh_Buffer) -> bool {return geom.cube_build(out,{2,1,4})})
    ball:=shape(proc(out:^geom.Mesh_Buffer) -> bool {return geom.sphere_build(out,0.5)})
    pill:=shape(proc(out:^geom.Mesh_Buffer) -> bool {return geom.capsule_build(out,0.25,1)})
    // Two cubes apart: two pieces.
    pair:=shape(proc(out:^geom.Mesh_Buffer) -> bool {return geom.cube_build(out)})
    first:=len(pair.positions)
    for i in 0..<first {append(&pair.positions,pair.positions[i]+{5,0,0})}
    count:=len(pair.indices)
    for i in 0..<count {append(&pair.indices,pair.indices[i]+u32(first))}
    crate:=node_of(&r,"Crate",mesh_of(&r,"Crate",cube),-1,{10,0,0})
    node_of(&r,"UCX_Crate_01",mesh_of(&r,"UCX_Crate_01",pair),-1,{10,0,0})
    node_of(&r,"ubx_crate",mesh_of(&r,"ubx_crate",cube),-1,{10,2,0})
    node_of(&r,"USP_Crate",mesh_of(&r,"USP_Crate",ball),-1,{10,0,3})
    node_of(&r,"UCP_Crate.001",mesh_of(&r,"UCP_Crate.001",pill),-1,{10,0,-3})
    node_of(&r,"Rock-colonly",mesh_of(&r,"Rock",cube),crate,{0,1,0})
    wall:=node_of(&r,"Wall_col",mesh_of(&r,"Wall",cube),-1)
    testing.expect(t,colliders_resolve(&r))
    testing.expect_value(t,len(r.nodes),2)
    testing.expect_value(t,len(r.meshes),2)
    if len(r.nodes)!=2 || len(r.meshes)!=2 {return}
    testing.expect(t,r.nodes[crate].name=="Crate" && r.nodes[1].name=="Wall","the collision nodes leave, and a -col keeps its name without it")
    testing.expect(t,r.nodes[1].mesh==1 && r.meshes[1].name=="Wall")
    kinds:[asset.Collider_Kind]int
    collision:=r.meshes[0].collision
    for c in collision.colliders {kinds[c.kind]+=1}
    testing.expectf(t,kinds[.Hull]==2 && kinds[.Box]==1 && kinds[.Sphere]==1 && kinds[.Capsule]==1 && kinds[.Mesh]==1,"the colliders of the crate: %v",kinds)
    near :: proc(a,b:[3]f32,tolerance:f32=1e-3) -> bool {return linalg.length(a-b)<=tolerance}
    for c in collision.colliders {
        switch c.kind {
        case .Box:
            testing.expectf(t,near(c.center,{0,2,0}) && near(c.size,{1,0.5,2}),"the box is where its node is from the crate, of its size: %v",c)
        case .Sphere:
            testing.expectf(t,near(c.center,{0,0,3}) && abs(c.size.x-0.5)<1e-2,"the sphere: %v",c)
        case .Capsule:
            axis:=mm.quat_rotate(c.rotation,{0,1,0})
            testing.expectf(t,near(c.center,{0,0,-3},1e-2) && abs(c.size.x-0.25)<1e-2 && abs(abs(axis.y)-1)<1e-3,"the capsule lies along its length: %v",c)
        case .Hull:
            low,high:=collision.points[c.first_point],collision.points[c.first_point]
            for p in collision.points[c.first_point:][:c.point_count] {low,high=linalg.min(low,p),linalg.max(high,p)}
            testing.expectf(t,near(high-low,{1,1,1}),"each piece of the UCX_ is one cube: %v %v",low,high)
        case .Mesh:
            testing.expectf(t,int(c.index_count)==len(cube.indices) && near(collision.points[c.first_point],cube.positions[0]+{0,1,0}),"the triangles of the -colonly where it is under the crate: %v",c)
        }
    }
    own:=r.meshes[1].collision
    testing.expect(t,len(own.colliders)==1 && own.colliders[0].kind==.Mesh && int(own.colliders[0].index_count)==len(cube.indices),"a -col collides with its own triangles")
    _=wall
}
