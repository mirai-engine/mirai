package physics_cache

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import destruct "plugins:destruct/runtime"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:host"
import sim "plugins:physics/runtime/sim"
import fr "plugins:destruct/runtime/fracture"
import "mirai:std/jobs"
import mm "mirai:std/math"

@(private)
Cache_Test_World :: struct {
    es:core.Entities,
    meshes:core.Table(render.Mesh_Renderer),
    parents:core.Table(core.Parent),
    tints:core.Table(render.Tint),
    transforms:core.Table(core.Transform),
    configs:core.Table(destruct.Destructible),
    colliders:core.Table(phys.Collider),
    states:core.Table(destruct.Destructible_State),
    groups:core.Table(destruct.Destructible_Group),
    elsewhere:core.Table(render.Drawn_Elsewhere),
    ids:core.Table(core.Id),
}

@(private)
cache_test_settle :: proc(world,shared,editor:rawptr) {
    w:=cast(^Cache_Test_World)world
    core.table_settle(&w.meshes,&w.es);core.table_settle(&w.parents,&w.es);core.table_settle(&w.tints,&w.es)
    core.table_settle(&w.transforms,&w.es);core.table_settle(&w.configs,&w.es);core.table_settle(&w.colliders,&w.es);core.table_settle(&w.states,&w.es)
    core.table_settle(&w.groups,&w.es);core.table_settle(&w.elsewhere,&w.es);core.table_settle(&w.ids,&w.es)
    core.entities_settle(&w.es)
}

@(private)
cache_test_world_free :: proc(w:^Cache_Test_World) {
    core.table_destroy(&w.meshes);core.table_destroy(&w.parents);core.table_destroy(&w.tints)
    core.table_destroy(&w.transforms);core.table_destroy(&w.configs);core.table_destroy(&w.colliders);core.table_destroy(&w.states)
    core.table_destroy(&w.groups);core.table_destroy(&w.elsewhere);core.table_destroy(&w.ids)
    core.entities_destroy(&w.es)
}

@(private)
cache_test_step :: proc(w:^Cache_Test_World,physics:^phys.Physics_State,fractures:^destruct.Fracture_State,geometry:^destruct.Destruct_Cache,requests:^destruct.Destruct_Requests,events:^destruct.Destruct_Events,app:^host.App,info:^core.World_Info,tick:u64) {
    alone:core.Network
    settings:=destruct.Destruct_Settings{destructibles=2,pieces=16,connections=64}
    destruct.destruct_step(physics,fractures,core.ref(&settings),geometry,requests,events,core.ref(&alone),app,{playing=true,dt=1.0/60,tick=tick},core.commands(w,info),
        core.read(&w.configs),&w.meshes,&w.tints,core.read(&w.parents),&w.states,&w.groups,&w.elsewhere,&w.transforms,&w.ids,core.read(&w.colliders),{},nil)
    cache_test_settle(w,nil,nil)
}

@(test)
destructible_geometry_and_detached_group_poses_play_after_the_source_world_is_destroyed :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-cache-assets-%d",directory,os.get_pid())
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=32})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{allocator=context.allocator,assets=&assets}
    testing.expect(t,jobs.system_init(&app.jobs,{threads=0}))
    defer jobs.system_destroy(&app.jobs)
    world:Cache_Test_World
    core.entities_init(&world.es)
    defer cache_test_world_free(&world)
    tables:=[3]core.Table_Info{
        {name="Mesh_Renderer",type=render.Mesh_Renderer,info=type_info_of(render.Mesh_Renderer),offset=offset_of(Cache_Test_World,meshes)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Cache_Test_World,parents)},
        {name="Tint",type=render.Tint,info=type_info_of(render.Tint),offset=offset_of(Cache_Test_World,tints)},
    }
    info:=core.World_Info{entities=offset_of(Cache_Test_World,es),tables=tables[:]}
    physics:=phys.Physics_State{}
    if !testing.expect(t,sim.world_init(&physics.world,{body_capacity=32,shape_capacity=64,contact_capacity=128,joint_capacity=8,hull_capacity=64,event_capacity=32,gravity={0,-9.81,0}})) {return}
    physics.ready=true
    defer phys.state_destroy(&physics)
    fractures:destruct.Fracture_State
    defer destruct.fracture_state_destroy(&fractures)
    geometry:destruct.Destruct_Cache
    defer destruct.cache_destroy(&app,&geometry)
    requests:destruct.Destruct_Requests
    events:destruct.Destruct_Events
    defer core.value_free(&requests,type_info_of(destruct.Destruct_Requests))
    defer core.value_free(&events,type_info_of(destruct.Destruct_Events))
    owner:=core.create(&world.es)
    core.add(&world.transforms,owner,core.Transform{position={3,2,-4},rotation=1,scale={1,1,1}})
    core.add(&world.meshes,owner,render.Mesh_Renderer{shape=.Cube})
    core.add(&world.configs,owner,destruct.destructible(pieces=4,seed=55));core.add(&world.colliders,owner,destruct.collider_fracture())
    cache_test_settle(&world,nil,nil)
    for tick in 0..<4 {cache_test_step(&world,&physics,&fractures,&geometry,&requests,&events,&app,&info,u64(tick))}
    state,has:=core.get(core.read(&world.states),owner)
    if !testing.expect(t,has && fr.destructible_valid(&fractures.fracture,state.handle)) {return}
    testing.expect_value(t,phys.body_of(core.ref(&physics),owner),state.body)
    record:Cache_Recorder
    testing.expect_value(t,record_init(&record,{frames=8,tracks=16,samples=128,vertices=8192,indices=16384,origin={position={3,2,-4},rotation=1,scale={1,1,1}}}),Cache_Error.None)
    defer record_destroy(&record)
    source:=[1]Capture_Source{{entity=owner,object=1}}
    capture :: proc(r:^Cache_Recorder,w:^Cache_Test_World,p:^phys.Physics_State,fs:^destruct.Fracture_State,g:^destruct.Destruct_Cache,sources:[]Capture_Source,time:f32)->Cache_Error {
        return capture_destructible(r,time,sources,destruct.Destruct_View{core.ref(p),core.ref(fs),core.read(&w.states),core.read(&w.groups)},core.ref(g))
    }
    testing.expect_value(t,capture(&record,&world,&physics,&fractures,&geometry,source[:],0),Cache_Error.None)
    testing.expect_value(t,len(record.tracks),4)
    destruct.strain(&requests,owner,{3,2,-4},4,1e6,{2,4,1})
    cache_test_step(&world,&physics,&fractures,&geometry,&requests,&events,&app,&info,4)
    groups:[16]destruct.Group_Info
    count:=destruct.groups(destruct.Destruct_View{core.ref(&physics),core.ref(&fractures),core.read(&world.states),core.read(&world.groups)},owner,groups[:])
    testing.expect(t,count>1)
    for group in groups[:count] {
        testing.expect_value(t,phys.body_of(core.ref(&physics),group.entity),group.body)
        testing.expect_value(t,sim.body_user_data(&physics.world,group.body),u64(group.entity))
    }
    sim.world_step(&physics.world,1.0/60)
    testing.expect_value(t,capture(&record,&world,&physics,&fractures,&geometry,source[:],1.0/60),Cache_Error.None)
    destruct.slice(&requests,owner,{3,2,-4},{1,0,0})
    cache_test_step(&world,&physics,&fractures,&geometry,&requests,&events,&app,&info,5)
    sim.world_step(&physics.world,1.0/60)
    testing.expect_value(t,capture(&record,&world,&physics,&fractures,&geometry,source[:],2.0/60),Cache_Error.None)
    testing.expect(t,len(record.tracks)>4)
    expected:[16]Playback_Piece
    end:=cache_sample(record_view(&record),2.0/60,expected[:])
    path:=fmt.tprintf("%s/mirai-cache-%d.physics_cache",directory,os.get_pid())
    defer os.remove(path)
    testing.expect_value(t,cache_save(path,&assets.types,{456,789},record_view(&record)),asset.Error.None)
    destruct.cache_destroy(&app,&geometry)
    phys.state_destroy(&physics)
    file:asset.Asset
    testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None)
    defer asset.asset_close(&file)
    loaded,error:=cache_view(&file,&assets.types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    actual:[16]Playback_Piece
    testing.expect_value(t,cache_sample(loaded,2.0/60,actual[:]),end)
    for piece,index in actual[:end] {testing.expect_value(t,piece,expected[index])}
    for tick in 0..<120 {cache_sample(loaded,f32(119-tick)/119*loaded.info.duration,actual[:])}
    testing.expect_value(t,cache_sample(loaded,0,actual[:]),4)
}
