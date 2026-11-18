package importer

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// A format of tests whose file is a quad of two triangles in a mirrored space
// of centimeters: a smooth one with uvs and a flat one, both morphing, with a
// target that lifts a corner and one that moves nothing.
@(private="file")
morph_read :: proc(r:^Reader,bytes:[]u8) -> bool {
    b:Mesh_Builder
    builder_init(&b,r)
    slot:=builder_slot(&b,1,"Paint",-1) or_return
    points:=[4][3]f32{{0,0,0},{0,100,0},{0,100,100},{0,0,100}}
    uvs:=[4][2]f32{{0,0},{1,0},{1,1},{0,1}}
    for flat in ([2]bool{false,true}) {
        offset:=[3]f32{0,0,200} if flat else {}
        for triangle in ([2][3]int{{0,1,2},{0,2,3}}) {
            corners:[3]Corner
            for s,k in triangle {
                corners[k]={position=points[s]+offset,normal={1,0,0},uv=uvs[s],has_uv=true,color=WHITE,flat=flat,morph=u32(s+1+(4 if flat else 0))}
            }
            builder_triangle(&b,slot,corners)
        }
    }
    mesh:=builder_finish(&b,"Quad")
    lift:=make([][3]f32,8,context.temp_allocator)
    lift[2],lift[6]={30,0,0},{30,0,0}
    normals:=make([][3]f32,8,context.temp_allocator)
    normals[2]={0,0,.5}
    builder_morph(&b,&mesh,{name="Lift",weight=.25,positions=lift,normals=normals}) or_return
    builder_morph(&b,&mesh,{name="Still",positions=make([][3]f32,8,context.temp_allocator)}) or_return
    mesh_add(r,mesh)
    append(&r.nodes,Imported_Node{name=own(r,"Quad"),parent=-1,transform=mm.TRANSFORM_IDENTITY,mesh=0,visible=true})
    return true
}

@(private="file")
MORPH_FORMAT :: Format{name="Morph test",extensions={0=".morph"},space={meters_per_unit=0.01,axes={.Negative_Y,.Z,.X},v_origin=.Bottom},sniff=proc(head:[]u8) -> Sniff {return .Extension},read=morph_read}

@(private="file")
morph_delta_of :: proc(mesh:Imported_Mesh,target,vertex:int) -> asset.Morph_Delta {
    shape:=mesh.morphs[target]
    for delta in mesh.morph_deltas[shape.first:][:shape.count] {if int(delta.vertex)==vertex {return delta}}
    return {vertex=u32(vertex)}
}

@(test)
morph_targets_turn_with_the_space_and_make_flat_normals_and_tangents_of_their_shape :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"morph-space")
    if folder=="" {return}
    path:=fmt.tprintf("%s/quad.morph",folder);_=os.write_entire_file(path,"quad")
    formats:=[1]Format{MORPH_FORMAT}
    model,error:=import_model(path,formats[:]);defer model_destroy(&model)
    if !testing.expectf(t,error.code==.None,"%v %s",error.code,error.message) {return}
    mesh:=model.meshes[0]
    testing.expect_value(t,len(mesh.morphs),2)
    testing.expect(t,mesh.morphs[0].weight==.25 && mesh.morphs[1].count==0,"a target that moves nothing keeps no deltas")
    testing.expect_value(t,len(mesh.vertices),10)
    basis,_:=space_basis(MORPH_FORMAT.space)
    shaped:=make([][3]f32,len(mesh.vertices),context.temp_allocator)
    normals:=make([][3]f32,len(mesh.vertices),context.temp_allocator)
    for vertex,v in mesh.vertices {
        delta:=morph_delta_of(mesh,0,v)
        shaped[v]=vertex.position+delta.position
        normals[v]=linalg.normalize(mm.normal_unpack(vertex.normal)+delta.normal)
    }
    for at:=0;at<len(mesh.indices);at+=3 {
        triangle:=mesh.indices[at:][:3]
        for vertex in triangle {
            if delta:=morph_delta_of(mesh,0,int(vertex));delta.position!={} {
                testing.expect(t,linalg.length(delta.position-space_point(basis,{30,0,0}))<1e-5,"position deltas turn and scale with the space of the source")
            }
        }
        if at<6 {continue}
        face:=linalg.normalize(linalg.cross(shaped[triangle[1]]-shaped[triangle[0]],shaped[triangle[2]]-shaped[triangle[0]]))
        for vertex in triangle {testing.expect(t,linalg.length(normals[vertex]-face)<1e-4,"a flat corner follows its face at weight 1")}
    }
    smooth_lifted:=-1
    for v in 0..<4 {if morph_delta_of(mesh,0,v).position!={} {smooth_lifted=v}}
    if !testing.expect(t,smooth_lifted>=0) {return}
    testing.expect(t,linalg.length(morph_delta_of(mesh,0,smooth_lifted).normal-space_direction(basis,{0,0,.5}))<1e-5,"a stated normal delta turns with the space")
    uvs:=make([][2]f32,len(mesh.vertices),context.temp_allocator)
    for vertex,v in mesh.vertices {uvs[v]=vertex.uv}
    corners:=make([][4]f32,len(mesh.indices),context.temp_allocator)
    if !testing.expect(t,geom.corner_tangents(shaped,normals,uvs,mesh.indices,corners)) {return}
    for vertex,at in mesh.indices {
        if at>=6 {break}
        rest,_:=mm.tangent_unpack(mesh.vertices[vertex].tangent)
        moved:=linalg.normalize(rest+morph_delta_of(mesh,0,int(vertex)).tangent)
        testing.expectf(t,linalg.length(moved-corners[at].xyz)<1e-3,"corner %d takes at weight 1 the MikkTSpace tangent of the shape",at)
    }
}

@(test)
morph_levels_move_each_vertex_with_the_vertices_it_took_its_attributes_from :: proc(t:^testing.T) {
    sphere:geom.Mesh_Buffer;geom.mesh_buffer_init(&sphere,context.temp_allocator);geom.sphere_build(&sphere,1,32,16)
    vertices:=make([]asset.Vertex,len(sphere.positions),context.temp_allocator)
    deltas:=make([]asset.Morph_Delta,len(sphere.positions),context.temp_allocator)
    for point,i in sphere.positions {
        vertices[i]=test_vertex(point,sphere.normals[i],{})
        deltas[i]={vertex=u32(i),position={point.x*.2,point.y*.3,0},normal={point.x*.1,0,0},tangent={0,point.z,0}}
    }
    targets:=[1]asset.Morph_Target{{count=u32(len(deltas))}}
    asset.text_set(targets[0].name[:],"Inflate")
    levels:=mesh_levels(vertices,sphere.indices[:],nil,nil,allocator=context.temp_allocator,morphs=targets[:],morph_deltas=deltas)
    if !testing.expect(t,len(levels.lods)>1) {return}
    geometry:asset.Mesh_Geometry
    testing.expect(t,levels_geometry(levels,{},&geometry,context.temp_allocator),"the deltas of every level name their vertices")
    testing.expect(t,len(geometry.morphs)==1 && geometry.morphs[0].count>0,"the deltas follow the vertices of the clusters")
    level:=levels.lods[1]
    moved:=0
    for delta in levels.morph_deltas {
        if delta.vertex<level.first_vertex || delta.vertex>=level.first_vertex+level.vertex_count {continue}
        vertex:=levels.vertices[delta.vertex]
        // A vertex of a level sits where a vertex of level 0 is, whose position delta it takes.
        found:=false
        for source,i in vertices {if source.position==vertex.position && deltas[i].position==delta.position {found=true;break}}
        testing.expect(t,found)
        moved+=1
    }
    testing.expect(t,moved>0,"the vertices of the levels move")
}
