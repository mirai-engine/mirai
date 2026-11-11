package main

import "mirai:asset"
import "core:fmt"
import "mirai:core"
import destruct "plugins:destruct/runtime"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"
import cache "plugins:physics_cache/runtime"
import capture "plugins:physics_cache_destruct/runtime"

@(private)
Physics_Bake :: struct {
    entities:core.Entities,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(render.Mesh_Renderer),
    tints:core.Table(render.Tint),
    configs:core.Table(destruct.Destructible),
    colliders:core.Table(phys.Collider),
    rigids:core.Table(phys.Rigid_Body),
    states:core.Table(destruct.Destructible_State),
    groups:core.Table(destruct.Destructible_Group),
    elsewhere:core.Table(render.Drawn_Elsewhere),
    ids:core.Table(core.Id),
}

@(private)
physics_bake_settle :: proc(world,shared,editor:rawptr) {
    w:=cast(^Physics_Bake)world
    core.table_settle(&w.transforms,&w.entities);core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.meshes,&w.entities);core.table_settle(&w.tints,&w.entities)
    core.table_settle(&w.configs,&w.entities);core.table_settle(&w.colliders,&w.entities);core.table_settle(&w.states,&w.entities);core.table_settle(&w.groups,&w.entities)
    core.table_settle(&w.elsewhere,&w.entities);core.table_settle(&w.ids,&w.entities)
    core.entities_settle(&w.entities)
}

@(private)
physics_bake_free :: proc(w:^Physics_Bake) {
    core.table_destroy(&w.transforms);core.table_destroy(&w.parents);core.table_destroy(&w.meshes);core.table_destroy(&w.tints)
    core.table_destroy(&w.configs);core.table_destroy(&w.colliders);core.table_destroy(&w.rigids);core.table_destroy(&w.states);core.table_destroy(&w.groups)
    core.table_destroy(&w.elsewhere);core.table_destroy(&w.ids);core.entities_destroy(&w.entities)
}

@(private)
physics_cache_bake :: proc(o:^Out,fracture,mesh:base.Asset_Id) {
    id:=asset.content_id(PROJECT,"physics_cache","recorded")
    assets:host.Assets
    if !host.assets_init(&assets,{root=path(o,"assets"),capacity=128}) {o.content.failed=true;return}
    defer host.assets_destroy(&assets)
    app:=host.App{allocator=context.allocator,assets=&assets}
    if !jobs.system_init(&app.jobs,{threads=0}) {o.content.failed=true;return}
    defer jobs.system_destroy(&app.jobs)
    world:Physics_Bake;core.entities_init(&world.entities);defer physics_bake_free(&world)
    tables:=[3]core.Table_Info{
        {name="Mesh_Renderer",type=render.Mesh_Renderer,info=type_info_of(render.Mesh_Renderer),offset=offset_of(Physics_Bake,meshes)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Physics_Bake,parents)},
        {name="Tint",type=render.Tint,info=type_info_of(render.Tint),offset=offset_of(Physics_Bake,tints)},
    }
    info:=core.World_Info{entities=offset_of(Physics_Bake,entities),tables=tables[:]}
    physics:phys.Physics_State;defer phys.state_destroy(&physics)
    settings:=phys.Physics_Settings{bodies=128,shapes=256,contacts=1024,joints=1,hulls=128,breakables=1,pieces=128,bonds=512}
    problems:core.Problems
    defer core.value_free(&problems,type_info_of(core.Problems))
    if !phys.state_make(&physics,&settings,&app.jobs,&problems) {o.content.failed=true;return}
    bodies:phys.Body_Requests
    defer core.value_free(&bodies,type_info_of(phys.Body_Requests))
    // The pieces float for the cuts and fall from the strain on.
    gravity:[3]f32
    geometry:destruct.Destruct_Cache;defer destruct.cache_destroy(app.assets,&app.jobs,&geometry)
    requests:destruct.Destruct_Requests;events:destruct.Destruct_Events
    alone:core.Network
    defer core.value_free(&requests,type_info_of(destruct.Destruct_Requests))
    defer core.value_free(&events,type_info_of(destruct.Destruct_Events))
    collision:=phys.COLLISION_SETTINGS_DEFAULT
    floor,_:=phys.owned_body_create(&physics,{owner=1},{0,-.25,0},1)
    if phys.owned_shape_create(&physics,&collision,floor,{collider=phys.collider_box({4,.25,4}),rotation=1})==0 {o.content.failed=true;return}
    owner:=core.create(&world.entities)
    core.add(&world.transforms,owner,core.Transform{position={0,2,0},rotation=1,scale={1,1,1}})
    core.add(&world.meshes,owner,render.Mesh_Renderer{mesh=mesh})
    config:=destruct.destructible();config.fracture=fracture;config.impact_damage=false;config.debris_volume=0
    config.interior=material_id("Cobblestone");core.add(&world.configs,owner,config);dense:=phys.COLLIDER_DEFAULT;dense.density=2000;core.add(&world.colliders,owner,dense)
    physics_bake_settle(&world,nil,nil)
    record:cache.Cache_Recorder
    if error:=cache.record_init(&record,{frames=151,tracks=128,samples=151*128,vertices=32768,indices=65536,origin=mm.TRANSFORM_IDENTITY});error!=.None {o.content.failed=true;return}
    defer cache.record_destroy(&record)
    source:=[1]capture.Capture_Source{{entity=owner,object=1}}
    source[0].materials[0],source[0].materials[1]=material_id("Bricks"),material_id("Cobblestone")
    source[0].materials[2]=material_id("Cobblestone")
    for frame in 0..=150 {
        if frame==15 || frame==30 {
            pieces:[128]destruct.Piece_Info
            count:=destruct.pieces(destruct.Destruct_View{core.ref(&physics),core.read(&world.states),core.read(&world.groups)},owner,pieces[:])
            for piece in pieces[:min(count,len(pieces))] {
                if piece.body==0 {continue}
                body,_:=phys.body_info(core.ref(&physics),piece.body)
                center:=body.pose.position+mm.quat_rotate(body.pose.rotation,piece.center)
                destruct.slice(&requests,owner,center,{0,0,1} if frame==15 else {0,1,0})
                break
            }
        }
        if frame==45 {
            gravity={0,-9.81,0}
            destruct.strain(&requests,owner,{0,2,0},10,10000,{0,3,2})
        }
        if frame==120 {
            for e in world.groups.entities {
                if e!=owner && destruct.remove(&requests,core.read(&world.groups),e)==.None {break}
            }
        }
        destruct.destruct_step(&physics,&geometry,&requests,&events,core.ref(&alone),app.assets,&app.jobs,{playing=true,dt=1.0/30,tick=u64(frame)},core.commands(&world,&info),
            core.read(&world.configs),&world.meshes,&world.tints,core.read(&world.parents),&world.states,&world.groups,&world.elsewhere,&world.transforms,&world.ids,core.read(&world.colliders),core.read(&world.rigids),{},nil)
        physics_bake_settle(&world,nil,nil)
        if frame==15 || frame==30 {phys.apply_area(&bodies,volume.sphere(4),{position={0,2.5,0}},.6,impulse=true,velocity_change=true)}
        error:=capture.capture_destructible(&record,f32(frame)/30,source[:],destruct.Destruct_View{core.ref(&physics),core.read(&world.states),core.read(&world.groups)},core.ref(&geometry))
        if error!=.None {fmt.eprintfln("demo_content: geometry bake frame %d: %v",frame,error);o.content.failed=true;return}
        if frame<150 && !phys.simulate(&physics,&bodies,&app.jobs,1.0/30,gravity,&problems) {o.content.failed=true;return}
    }
    asset.content_check(&o.content,"recorded.physics_cache",cache.cache_save(path(o,"assets/physics_gallery/recorded.physics_cache"),&o.content.types,id,cache.record_view(&record)))
}
