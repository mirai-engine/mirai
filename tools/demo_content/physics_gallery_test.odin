package main

import "core:testing"
import "core:fmt"
import "core:os"
import "mirai:asset"
import sim "plugins:physics/runtime/sim"
import fr "plugins:destruct/runtime/fracture"
import "mirai:std/geom"
import cache "plugins:physics_cache/runtime"

@(test)
gallery_geometry_bake_records_two_cuts_new_interior_meshes_and_fragment_retirement :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-gallery-geometry-%d",directory,os.get_pid())
    o:=Out{root=root};asset.content_init(&o.content,PROJECT);defer asset.content_destroy(&o.content)
    if !testing.expect_value(t,os.make_directory_all(path(&o,"assets/physics")),nil) {return}
    defer os.remove_all(root)
    sources:=physics_sources(&o)
    if !testing.expect(t,!o.content.failed) {return}
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&file,path(&o,"assets/physics/recorded.physics_cache")),asset.Error.None) {return}
    defer asset.asset_close(&file)
    view,error:=cache.cache_view(&file,&o.content.types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    testing.expect_value(t,file.blob.header.id,sources.cache)
    testing.expect_value(t,view.info.duration,f32(5))
    samples:[128]cache.Playback_Piece
    initial:=cache.cache_sample(view,0,samples[:])
    first:=cache.cache_sample(view,.5,samples[:])
    second:=cache.cache_sample(view,1,samples[:])
    before:=cache.cache_sample(view,119.0/30,samples[:])
    retired:=cache.cache_sample(view,4,samples[:])
    testing.expect_value(t,initial,8)
    testing.expect(t,first>initial && second>first)
    testing.expect(t,retired<before && retired>0)
    testing.expect(t,len(view.tracks)>second)
    has_interior:=false
    for material in view.materials {if material==2 {has_interior=true;break}}
    testing.expect(t,has_interior)
    testing.expect_value(t,cache.cache_sample(view,0,samples[:]),initial)
}

@(test)
gallery_mixed_source_keeps_supports_and_full_collision_leaves_while_only_small_pieces_expire :: proc(t:^testing.T) {
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    builder:asset.Fracture_Builder;asset.fracture_builder_init(&builder);defer asset.fracture_builder_destroy(&builder)
    if !testing.expect(t,physics_mixed_build(&builder,geom.mesh_buffer_view(&cube))) {return}
    desc:=asset.fracture_builder_desc(&builder,{})
    info:asset.Fracture_Info
    view:=asset.Fracture_View{info=&info,vertices=desc.vertices,indices=desc.indices,pieces=desc.pieces,connections=desc.connections,clusters=desc.clusters}
    fracture:geom.Fracture;geom.fracture_init(&fracture);defer geom.fracture_destroy(&fracture)
    if !testing.expect_value(t,asset.fracture_geometry(view,&fracture),asset.Error.None) {return}
    anchors:[8]bool
    for piece,at in builder.pieces {anchors[at]=piece.anchor}
    w:sim.World;wd:=sim.world_desc_default()
    wd.body_capacity,wd.shape_capacity,wd.contact_capacity,wd.joint_capacity=16,32,64,1
    wd.hull_capacity=16;wd.gravity={}
    if !testing.expect(t,sim.world_init(&w,wd)) {return};defer sim.world_destroy(&w)
    f:fr.Fracture;fd:=fr.desc_default();fd.bodies,fd.destructibles,fd.pieces,fd.connections=wd.body_capacity,1,16,64
    if !testing.expect(t,fr.fracture_init(&f,fd)) {return};defer fr.fracture_destroy(&f)
    dd:=fr.DESTRUCTIBLE_DESC_DEFAULT;dd.fracture=&fracture;dd.piece_anchors=anchors[:];dd.debris_volume=.1;dd.debris_ticks=480
    h,error:=fr.destructible_create(&f,&w,dd)
    if !testing.expect_value(t,error,fr.Destructible_Error.None) {return}
    root:=fr.destructible_body(&f,h)
    _,broke:=fr.destructible_strain(&f,&w,h,{0,.7,0},4,10000)
    if !testing.expect(t,broke) {return}
    pieces:[8]fr.Piece_Info;testing.expect_value(t,fr.destructible_pieces(&f,&w,h,pieces[:]),8)
    debris,solids,supports:int
    for piece in pieces {
        if .Anchor in piece.flags {
            supports+=1;testing.expect_value(t,piece.body,root);testing.expect(t,.Debris not_in piece.flags)
        } else if .Debris in piece.flags {
            debris+=1;testing.expect(t,piece.volume<dd.debris_volume)
            remaining,expires:=fr.destructible_body_remaining_ticks(&f,&w,h,piece.body)
            testing.expect(t,expires && remaining==480)
        } else {
            solids+=1;testing.expect(t,piece.volume>dd.debris_volume && piece.body!=root)
            _,expires:=fr.destructible_body_remaining_ticks(&f,&w,h,piece.body);testing.expect(t,!expires)
        }
    }
    testing.expect_value(t,supports,4);testing.expect_value(t,solids,2);testing.expect_value(t,debris,2)
    for _ in 0..<481 {sim.world_step(&w,1.0/60);fr.fracture_update(&f,&w)}
    for piece in pieces {
        testing.expect_value(t,sim.body_valid(&w,piece.body),.Debris not_in piece.flags)
    }
}
