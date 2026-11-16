package physics_cache_destruct

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import cache "plugins:physics_cache/runtime"
import destruct "plugins:destruct/runtime"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

@(private)
@(test_world)
Cache_Test_World :: struct {
    using world:Test_World,
    using rows:destruct.Test_Destruct,
}

@(private="file")
cache_test_step :: proc(w:^Cache_Test_World,h:^destruct.Test_Destruct_Host,tick:u64) {
    destruct.test_step(&w.rows,h,core.commands_of(test_world_ref(w)),{playing=true,dt=1.0/60,tick=tick})
    test_world_settle(w)
}

@(test)
destructible_geometry_and_detached_group_poses_play_after_the_source_world_is_destroyed :: proc(t:^testing.T) {
    root:=base.test_folder(t,"cache-assets")
    if root=="" {return}
    h:destruct.Test_Destruct_Host
    if !testing.expect(t,host.assets_init(&h.assets,{root=root,capacity=32})) {return}
    defer host.assets_destroy(&h.assets)
    h.app={allocator=context.allocator,assets=&h.assets}
    testing.expect(t,jobs.system_init(&h.app.jobs,{threads=0}))
    defer jobs.system_destroy(&h.app.jobs)
    world:Cache_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    if !testing.expect(t,phys.test_state_make(&world.physics,{bodies=32,shapes=64,contacts=128,joints=8,hulls=64,events=32,breakables=2,pieces=16,bonds=64})) {return}
    defer destruct.cache_destroy(h.app.assets,&h.app.jobs,&h.cache)
    owner:=core.create(&world.entities)
    core.add(&world.transforms,owner,core.Transform{position={3,2,-4},rotation=1,scale={1,1,1}})
    core.add(&world.meshes,owner,render.Mesh_Renderer{shape=.Cube})
    core.add(&world.configs,owner,destruct.destructible(pieces=4,seed=55))
    test_world_settle(&world)
    for tick in 0..<4 {cache_test_step(&world,&h,u64(tick))}
    state,has:=core.get(&world.states,owner)
    if !testing.expect(t,has && phys.breakable_valid(core.ref(&world.physics),state.handle)) {return}
    testing.expect_value(t,phys.body_of(core.ref(&world.physics),owner),phys.breakable_body(core.ref(&world.physics),state.handle))
    record:cache.Cache_Recorder
    testing.expect_value(t,cache.record_init(&record,{frames=8,tracks=16,samples=128,vertices=8192,indices=16384,origin={position={3,2,-4},rotation=1,scale={1,1,1}}}),cache.Cache_Error.None)
    defer cache.record_destroy(&record)
    source:=[1]Capture_Source{{entity=owner,object=1}}
    capture :: proc(r:^cache.Cache_Recorder,w:^Cache_Test_World,g:^destruct.Destruct_Cache,sources:[]Capture_Source,time:f32)->cache.Cache_Error {
        return capture_destructible(r,time,sources,destruct.Destruct_View{core.ref(&w.physics),core.read(&w.states),core.read(&w.groups)},core.ref(g))
    }
    testing.expect_value(t,capture(&record,&world,&h.cache,source[:],0),cache.Cache_Error.None)
    testing.expect_value(t,len(record.tracks),4)
    destruct.strain(&world.requests,owner,{3,2,-4},4,1e6,{2,4,1})
    cache_test_step(&world,&h,4)
    groups:[16]destruct.Group_Info
    count:=destruct.groups(destruct.Destruct_View{core.ref(&world.physics),core.read(&world.states),core.read(&world.groups)},owner,groups[:])
    testing.expect(t,count>1)
    for group in groups[:count] {
        testing.expect_value(t,phys.body_of(core.ref(&world.physics),group.entity),group.body)
        testing.expect_value(t,phys.entity_of(core.ref(&world.physics),group.body),group.entity)
    }
    testing.expect(t,phys.simulate(&world.physics,nil,&h.app.jobs,1.0/60))
    testing.expect_value(t,capture(&record,&world,&h.cache,source[:],1.0/60),cache.Cache_Error.None)
    destruct.slice(&world.requests,owner,{3,2,-4},{1,0,0})
    cache_test_step(&world,&h,5)
    testing.expect(t,phys.simulate(&world.physics,nil,&h.app.jobs,1.0/60))
    testing.expect_value(t,capture(&record,&world,&h.cache,source[:],2.0/60),cache.Cache_Error.None)
    testing.expect(t,len(record.tracks)>4)
    expected:[16]cache.Playback_Piece
    end:=cache.cache_sample(cache.record_view(&record),2.0/60,expected[:])
    path:=fmt.tprintf("%s/destruct.physics_cache",base.test_folder(t,"cache-file"))
    testing.expect_value(t,cache.cache_save(path,&h.assets.types,{456,789},cache.record_view(&record)),asset.Error.None)
    destruct.cache_destroy(h.app.assets,&h.app.jobs,&h.cache)
    phys.state_destroy(&world.physics)
    file:asset.Asset
    testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None)
    defer asset.asset_close(&file)
    loaded,error:=cache.cache_view(&file,&h.assets.types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    actual:[16]cache.Playback_Piece
    testing.expect_value(t,cache.cache_sample(loaded,2.0/60,actual[:]),end)
    for piece,index in actual[:end] {testing.expect_value(t,piece,expected[index])}
    for tick in 0..<120 {cache.cache_sample(loaded,f32(119-tick)/119*loaded.info.duration,actual[:])}
    testing.expect_value(t,cache.cache_sample(loaded,0,actual[:]),4)
}
