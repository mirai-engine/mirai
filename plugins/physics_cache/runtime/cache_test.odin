package physics_cache

import "core:math/linalg"
import "core:mem"
import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/serial"

@(test)
portable_cache_preserves_geometry_topology_interpolation_and_reverse_without_simulation :: proc(t:^testing.T) {
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube)
    geom.cube_build(&cube)
    resize(&cube.colors,len(cube.positions))
    for &color,index in cube.colors {color={f32(index)/f32(len(cube.colors)),.5,.25,1}}
    record:Cache_Recorder
    testing.expect_value(t,record_init(&record,{frames=4,tracks=3,samples=8,vertices=128,indices=256,origin=mm.TRANSFORM_IDENTITY}),Cache_Error.None)
    defer record_destroy(&record)
    first,error:=record_mesh(&record,1,7,geom.mesh_buffer_view(&cube))
    testing.expect_value(t,error,Cache_Error.None)
    second,added:=record_mesh(&record,1,8,geom.mesh_buffer_view(&cube))
    testing.expect_value(t,added,Cache_Error.None)
    pose:=mm.TRANSFORM_IDENTITY
    samples:=[2]Cache_Sample{{first,pose},{second,pose}}
    testing.expect_value(t,record_frame(&record,0,samples[:1]),Cache_Error.None)
    samples[0].pose.position={2,0,0}
    samples[0].pose.rotation=mm.quat_axis_angle({0,1,0},mm.PI/2)
    samples[1].pose.position={0,3,0}
    testing.expect_value(t,record_frame(&record,1,samples[:]),Cache_Error.None)
    samples[1].pose.position={0,5,0}
    testing.expect_value(t,record_frame(&record,2,samples[1:]),Cache_Error.None)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    document:asset.Document
    testing.expect_value(t,cache_document(&document,&types,{123,456},record_view(&record)),asset.Error.None)
    defer asset.document_destroy(&document)
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    testing.expect_value(t,asset.document_write(&document,&writer),asset.Error.None)
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&writer)),asset.Error.None)
    defer asset.asset_close(&file)
    loaded,read:=cache_view(&file,&types)
    if !testing.expect_value(t,read,asset.Error.None) {return}
    testing.expect(t,asset.blob_verify_hash(&file.blob))
    testing.expect_value(t,loaded.info.duration,f32(2))
    testing.expect_value(t,loaded.tracks[0].piece,i32(7))
    testing.expect_value(t,len(loaded.vertices),len(cube.positions)*2)
    output:[3]Playback_Piece
    testing.expect_value(t,cache_sample(loaded,.5,output[:]),1)
    testing.expect(t,linalg.length(output[0].pose.position-mm.Vec3{1,0,0})<1e-6)
    testing.expect(t,mm.quat_angle(output[0].pose.rotation,mm.quat_axis_angle({0,1,0},mm.PI/4))<.001)
    testing.expect_value(t,cache_sample(loaded,1.5,output[:]),2)
    testing.expect_value(t,output[1].pose.position,mm.Vec3{0,4,0})
    testing.expect_value(t,cache_sample(loaded,2,output[:]),1)
    testing.expect_value(t,output[0].track,second)
    player:=Geometry_Playback{time=2,rate=-1,playing=true}
    player_advance(&player,2,.5)
    testing.expect_value(t,player.time,f32(1.5))
    testing.expect_value(t,cache_sample(loaded,player.time,output[:]),2)
    player_advance(&player,2,1)
    testing.expect_value(t,cache_sample(loaded,player.time,output[:]),1)
    testing.expect_value(t,output[0].pose.position,mm.Vec3{1,0,0})
    rebuilt:geom.Mesh_Buffer;geom.mesh_buffer_init(&rebuilt);defer geom.mesh_buffer_destroy(&rebuilt)
    testing.expect(t,cache_mesh(loaded,first,&rebuilt))
    testing.expect_value(t,len(rebuilt.indices),len(cube.indices))
    for position,index in rebuilt.positions {
        testing.expect_value(t,position,cube.positions[index])
        testing.expect_value(t,rebuilt.normals[index],cube.normals[index])
        testing.expect_value(t,rebuilt.uvs[index],cube.uvs[index])
        testing.expect_value(t,rebuilt.colors[index],cube.colors[index])
    }
}

@(test)
cache_recording_and_sampling_reuse_capacity_and_reject_bad_frames :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator);defer mem.tracking_allocator_destroy(&tracking)
    old:=context
    context.allocator=mem.tracking_allocator(&tracking)
    defer context=old
    record:Cache_Recorder
    testing.expect_value(t,record_init(&record,{frames=128,tracks=1,samples=128,vertices=24,indices=36,origin=mm.TRANSFORM_IDENTITY}),Cache_Error.None)
    defer record_destroy(&record)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    track,error:=record_mesh(&record,0,0,geom.mesh_buffer_view(&cube))
    if !testing.expect_value(t,error,Cache_Error.None) {return}
    before:=tracking.total_allocation_count
    input:=[1]Cache_Sample{{track,mm.TRANSFORM_IDENTITY}}
    output:[1]Playback_Piece
    for frame in 0..<128 {
        input[0].pose.position.x=f32(frame)
        testing.expect_value(t,record_frame(&record,f32(frame)/60,input[:]),Cache_Error.None)
        testing.expect_value(t,cache_sample(record_view(&record),f32(frame)/60,output[:]),1)
    }
    testing.expect_value(t,tracking.total_allocation_count,before)
    testing.expect_value(t,record_frame(&record,3,input[:]),Cache_Error.Capacity)
    testing.expect_value(t,record_frame(&record,1,input[:]),Cache_Error.Invalid)
    bad:=record_view(&record)
    original:=record.samples[0].track
    record.samples[0].track=123
    testing.expect(t,!cache_check(bad))
    record.samples[0].track=original
    record.frames[0].first=max(u32)
    testing.expect(t,!cache_check(bad))
    testing.expect_value(t,cache_sample(bad,0,output[:]),0)
}

@(test)
cache_player_handles_seek_pause_loop_and_reverse_boundaries :: proc(t:^testing.T) {
    player:=Geometry_Playback{time=.25,rate=-1,playing=true,loop=true}
    player_advance(&player,2,.5)
    testing.expect_value(t,player.time,f32(1.75))
    player.playing=false
    player_advance(&player,2,.5)
    testing.expect_value(t,player.time,f32(1.75))
    player.loop,player.playing=false,true
    player_advance(&player,2,4)
    testing.expect(t,player.time==0 && !player.playing)
    player={time=1.9,rate=1,playing=true}
    player_advance(&player,2,.5)
    testing.expect(t,player.time==2 && !player.playing)
}

@(test)
truncated_cache_files_are_rejected_without_leaking :: proc(t:^testing.T) {
    record:Cache_Recorder
    testing.expect_value(t,record_init(&record,{frames=1,tracks=1,samples=1,vertices=24,indices=36,origin=mm.TRANSFORM_IDENTITY}),Cache_Error.None)
    defer record_destroy(&record)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    track,error:=record_mesh(&record,0,0,geom.mesh_buffer_view(&cube))
    if !testing.expect_value(t,error,Cache_Error.None) {return}
    sample:=[1]Cache_Sample{{track,mm.TRANSFORM_IDENTITY}}
    record_frame(&record,0,sample[:])
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    document:asset.Document
    testing.expect_value(t,cache_document(&document,&types,{1,2},record_view(&record)),asset.Error.None)
    defer asset.document_destroy(&document)
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    testing.expect_value(t,asset.document_write(&document,&writer),asset.Error.None)
    bytes:=serial.writer_bytes(&writer)
    for count in 0..<len(bytes) {
        file:asset.Asset
        error:=asset.asset_open(&file,bytes[:count])
        testing.expect(t,error!=.None)
        asset.asset_close(&file)
    }
}

@(private="file")
Player_World :: struct {
    using world:core.Test_World,
    players:core.Table(Geometry_Playback),
    requests:Geometry_Requests,
}

@(test)
cache_content_reloads_releases_old_geometry_and_obeys_public_player_requests :: proc(t:^testing.T) {
    root:=base.test_folder(t,"cache-player")
    if root=="" {return}
    path:=fmt.tprintf("%s/play.physics_cache",root)
    record:Cache_Recorder
    testing.expect_value(t,record_init(&record,{frames=3,tracks=2,samples=6,vertices=64,indices=128,origin=mm.TRANSFORM_IDENTITY}),Cache_Error.None)
    defer record_destroy(&record)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    track,error:=record_mesh(&record,0,0,geom.mesh_buffer_view(&cube))
    if !testing.expect_value(t,error,Cache_Error.None) {return}
    samples:=[2]Cache_Sample{{track,mm.TRANSFORM_IDENTITY},{track,mm.TRANSFORM_IDENTITY}}
    record_frame(&record,0,samples[:1]);samples[0].pose.position={2,0,0};record_frame(&record,2,samples[:1])
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{771,221}
    testing.expect_value(t,cache_save(path,&types,id,record_view(&record)),asset.Error.None)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=16})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{allocator=context.allocator,assets=&assets}
    library:Cache_Library
    defer cache_library_free(&library)
    w:Player_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    players,requests:=&w.players,&w.requests
    e:=core.create(&w.entities)
    core.add(players,e,Geometry_Playback{source=id,rate=1,playing=true})
    core.test_world_settle(&w)
    physics_cache_update(players,requests,&library,{dt=.5},app.assets,app.allocator)
    state,_:=core.get(core.read(players),e)
    testing.expect_value(t,state.time,f32(.5))
    testing.expect_value(t,len(assets.meshes)-len(assets.free_meshes),1)
    prior_mesh:=library.contents[0].meshes[0]
    pause(requests,e);physics_cache_update(players,requests,&library,{dt=.5},app.assets,app.allocator)
    state,_=core.get(core.read(players),e)
    testing.expect(t,!state.playing && state.time==.5)
    play(requests,e,-1,true);physics_cache_update(players,requests,&library,{dt=.5},app.assets,app.allocator)
    state,_=core.get(core.read(players),e)
    testing.expect(t,state.playing && state.rate==-1 && state.time==1.5)
    seek(requests,e,.25);pause(requests,e);physics_cache_update(players,requests,&library,{},app.assets,app.allocator)
    state,_=core.get(core.read(players),e)
    testing.expect(t,state.time==.25 && !state.playing)
    second,added:=record_mesh(&record,0,1,geom.mesh_buffer_view(&cube))
    testing.expect_value(t,added,Cache_Error.None)
    samples[1].track=second
    record_frame(&record,3,samples[:])
    testing.expect_value(t,cache_save(path,&types,id,record_view(&record)),asset.Error.None)
    testing.expect_value(t,asset.registry_scan(&assets.registry),asset.Error.None)
    view:=cache_content(&library,app.assets,app.allocator,id)
    if !testing.expect(t,view!=nil) {return}
    testing.expect(t,view.info.duration==3 && len(view.tracks)==2)
    testing.expect(t,!host.assets_mesh_generated(&assets,prior_mesh))
    testing.expect_value(t,len(assets.meshes)-len(assets.free_meshes),2)
}
