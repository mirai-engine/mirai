package main

import "core:fmt"
import "core:os"
import "mirai:asset"
import destruct "plugins:destruct/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

// The fractures, the meshes, the baked cuts, the dust and the ragdoll of the physics gallery.
write_physics_gallery :: proc(o:^Out) {
    physics_sources(o)
    physics_dust(o)
    physics_ragdoll(o)
}

@(private)
physics_source_save :: proc(o:^Out,b:^destruct.Fracture_Builder,name:string) -> (fracture,mesh:base.Asset_Id) {
    fracture,mesh=asset.content_id(PROJECT,"fracture",name),asset.content_id(PROJECT,"mesh",name)
    asset.content_check(&o.content,fmt.tprintf("%s.fracture",name),destruct.fracture_save(path(o,fmt.tprintf("assets/physics_gallery/%s.fracture",name)),&o.content.types,destruct.fracture_builder_desc(b,fracture,mesh)))
    indices:=make([dynamic]u32,context.temp_allocator)
    for piece in b.pieces {for index in b.indices[piece.first_index:][:piece.index_count] {append(&indices,piece.first_vertex+index)}}
    mesh_write_built(o,fmt.tprintf("%s.mesh",name),fmt.tprintf("assets/physics_gallery/%s.mesh",name),{id=mesh,slots={{id=0,material=material_id("Bricks")},{id=1,material=material_id("Cobblestone")}}},{vertices=b.vertices[:]},indices[:])
    return
}

@(private)
physics_sources :: proc(o:^Out) {
    os.make_directory_all(path(o,"assets/physics_gallery"))
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube)
    geom.cube_build(&cube)
    b:destruct.Fracture_Builder;destruct.fracture_builder_init(&b);defer destruct.fracture_builder_destroy(&b)
    for y in 0..<2 {for x in 0..<4 {
        pose:=mm.Transform{{f32(x)*.62-.93,f32(y)*.57+.285,0},1,{.6,.55,.65}}
        _,error:=destruct.fracture_piece_add(&b,geom.mesh_buffer_view(&cube),pose)
        if error!=.None {o.content.failed=true;return}
    }}
    asset.content_check(&o.content,"bricks proximity",destruct.fracture_connect_proximity(&b,.04,.3,60))
    physics_source_save(o,&b,"bricks")
    destruct.fracture_cluster_add(&b,-1,150);destruct.fracture_cluster_add(&b,0,100);destruct.fracture_cluster_add(&b,0,100)
    for &piece,at in b.pieces {piece.cluster=1 if at%4<2 else 2}
    hierarchy,hierarchy_mesh:=physics_source_save(o,&b,"hierarchy")
    physics_cache_bake(o,hierarchy,hierarchy_mesh)
    mixed:destruct.Fracture_Builder;destruct.fracture_builder_init(&mixed);defer destruct.fracture_builder_destroy(&mixed)
    if !physics_mixed_build(&mixed,geom.mesh_buffer_view(&cube)) {o.content.failed=true;return}
    physics_source_save(o,&mixed,"mixed_bricks")
    clear(&b.vertices);clear(&b.indices);clear(&b.pieces);clear(&b.connections);clear(&b.clusters)
    for y in 0..<4 {for x in 0..<4 {
        _,error:=destruct.fracture_piece_add(&b,geom.mesh_buffer_view(&cube),{{f32(x)*.52-.78,f32(y)*.52+.26,0},1,{.5,.5,.4}},anchor=y==0)
        if error!=.None {o.content.failed=true;return}
    }}
    asset.content_check(&o.content,"wall proximity",destruct.fracture_connect_proximity(&b,.04,.2,35))
    physics_source_save(o,&b,"wall")
}

@(private)
physics_mixed_build :: proc(b:^destruct.Fracture_Builder,cube:geom.Mesh) -> bool {
    for y in 0..<2 {for x in 0..<4 {
        size:=mm.Vec3{.35,.35,.35} if y==1 && x>=2 else mm.Vec3{.6,.55,.65}
        height:=size.y/2 if y==0 else .57+size.y/2
        _,error:=destruct.fracture_piece_add(b,cube,{{f32(x)*.62-.93,height,0},1,size},anchor=y==0)
        if error!=.None {return false}
    }}
    return destruct.fracture_connect_proximity(b,.04,.3,60)==.None
}

// The dust a fracture of the gallery raises, which its burst prefab plays.
@(private)
physics_dust :: proc(o:^Out) {
    dust:=effect.PARTICLE_DEFAULTS;dust.duration=.05;dust.rate=0;dust.bursts[0]={count=50,cycles=1}
    dust.shape=.Sphere;dust.shape_size={.5,.5,.5};dust.lifetime={1.5,2};dust.speed={.7,1.4};dust.size={.15,.25};dust.gravity=.1
    dust.colors={{.9,.72,.42,.85},{1,.9,.65,.65}};dust.drag=1
    id:=asset.content_id(PROJECT,"particle","physics_dust")
    asset.content_check(&o.content,"physics dust",effect.particle_save(path(o,"assets/physics_gallery/physics_dust.particle"),&o.content.types,{id=id,info=dust}))
}
