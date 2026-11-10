package main

import "core:testing"
import "core:fmt"
import "core:os"
import "mirai:asset"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:std/geom"
import "mirai:std/jobs"
import cache "plugins:physics_cache/runtime"
import "mirai:std/base"

@(test)
gallery_geometry_bake_records_two_cuts_new_interior_meshes_and_fragment_retirement :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-gallery-geometry-%d",directory,os.get_pid())
    o:=Out{root=root};asset.content_init(&o.content,PROJECT);defer asset.content_destroy(&o.content)
    if !testing.expect_value(t,os.make_directory_all(path(&o,"assets/physics_gallery")),nil) {return}
    defer base.remove_all(root)
    sources:=physics_sources(&o)
    if !testing.expect(t,!o.content.failed) {return}
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&file,path(&o,"assets/physics_gallery/recorded.physics_cache")),asset.Error.None) {return}
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
    physics:phys.Physics_State;settings:=phys.Physics_Settings{bodies=16,shapes=32,contacts=64,joints=1,hulls=16,breakables=1,pieces=16,bonds=64}
    if !testing.expect(t,phys.test_state_make(&physics,settings)) {return};defer phys.state_destroy(&physics)
    view_of:=core.ref(&physics)
    dd:=phys.BREAKABLE_DESC_DEFAULT;dd.fracture=&fracture;dd.piece_anchors=anchors[:];dd.debris_volume=.1;dd.debris_ticks=480
    h,error:=phys.breakable_create(&physics,dd)
    if !testing.expect_value(t,error,phys.Breakable_Error.None) {return}
    root:=phys.breakable_body(view_of,h)
    broke,_:=phys.test_strain(&physics,h,{0,.7,0},4,10000)
    if !testing.expect(t,broke) {return}
    pieces:[8]phys.Piece_Info;testing.expect_value(t,phys.breakable_pieces(view_of,h,pieces[:]),8)
    debris,solids,supports:int
    for piece in pieces {
        if .Anchor in piece.flags {
            supports+=1;testing.expect_value(t,piece.body,root);testing.expect(t,.Debris not_in piece.flags)
        } else if .Debris in piece.flags {
            debris+=1;testing.expect(t,piece.volume<dd.debris_volume)
            remaining,expires:=phys.breakable_body_remaining_ticks(view_of,h,piece.body)
            testing.expect(t,expires && remaining==480)
        } else {
            solids+=1;testing.expect(t,piece.volume>dd.debris_volume && piece.body!=root)
            _,expires:=phys.breakable_body_remaining_ticks(view_of,h,piece.body);testing.expect(t,!expires)
        }
    }
    testing.expect_value(t,supports,4);testing.expect_value(t,solids,2);testing.expect_value(t,debris,2)
    job_system:jobs.Job_System
    for _ in 0..<481 {testing.expect(t,phys.simulate(&physics,nil,&job_system,1.0/60,{}))}
    for piece in pieces {
        _,valid:=phys.body_info(core.ref(&physics),piece.body)
        testing.expect_value(t,valid,.Debris not_in piece.flags)
    }
}
