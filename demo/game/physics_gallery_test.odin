package game

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import destruct "plugins:destruct/runtime"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/jobs"
import mm "mirai:std/math"
import cache "plugins:physics_cache/runtime"

// A simulation of the settings given, made as the physics plugin makes it for a world.
gallery_physics_make :: proc(state:^phys.Physics_State,settings:phys.Physics_Settings) -> bool {
    settings:=settings
    job_system:jobs.Job_System
    problems:core.Problems
    return phys.state_make(state,&settings,&job_system,&problems)
}

@(test)
gallery_geometry_actions_restart_once_per_trigger_alternating_forward_and_reverse :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    views:core.Table(Physics_Gallery_View);stations:core.Table(Physics_Gallery)
    states:core.Table(destruct.Destructible_State);groups:core.Table(destruct.Destructible_Group);force_fields:core.Table(phys.Force_Field);strain_fields:core.Table(destruct.Strain_Field)
    defer core.table_destroy(&views);defer core.table_destroy(&stations);defer core.table_destroy(&states);defer core.table_destroy(&groups);defer core.table_destroy(&force_fields);defer core.table_destroy(&strain_fields)
    actions:inp.Actions;requests:destruct.Destruct_Requests;bodies:phys.Body_Requests;playback:cache.Geometry_Requests;ragdolls:Ragdoll_Gallery_Requests
    defer delete(requests.queue.items);defer delete(requests.waiting.items);defer delete(bodies.queue.items);defer delete(playback.queue.items);defer delete(ragdolls.queue.items)
    physics:phys.Physics_State
    core.add(&views,core.create(&entities),PHYSICS_GALLERY_VIEW_DEFAULT)
    recorded,station:=core.create(&entities),core.create(&entities)
    core.add(&stations,station,Physics_Gallery{station=17,target=recorded})
    core.table_settle(&views,&entities);core.table_settle(&stations,&entities)
    for activation in 1..=3 {
        core.edit(&stations,station).trigger=u32(activation)
        for repeat in 0..<2 {physics_gallery_actions(&views,&stations,{actions=core.ref(&actions)},&requests,&bodies,&force_fields,&strain_fields,&playback,&ragdolls,{playing=true,dt=.5},destruct.Destruct_View{core.ref(&physics),core.read(&states),core.read(&groups)})}
        testing.expect_value(t,len(playback.queue.items),1)
        for command in core.take(&playback.queue) {
            testing.expect_value(t,command.entity,recorded)
            testing.expect(t,command.kind==.Play)
            testing.expect_value(t,command.value,f32(-1) if activation==2 else f32(1))
            testing.expect(t,command.restart)
        }
    }
    testing.expect_value(t,len(requests.queue.items),0);testing.expect_value(t,len(bodies.queue.items),0)
}
@(test)
gallery_removal_events_do_not_launch_fragments_count_fractures_or_spawn_dust :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    stations:core.Table(Physics_Gallery);defer core.table_destroy(&stations)
    counts:Physics_Gallery_Events;events:destruct.Destruct_Events;bodies:phys.Body_Requests;app:host.App;spawned:core.Problems;spawner:=scene.Spawner{problems=&spawned}
    defer delete(events.fractured.items);defer delete(bodies.queue.items)
    e:=core.create(&entities)
    core.add(&stations,e,Physics_Gallery{station=10,target=e});core.table_settle(&stations,&entities)
    core.push(&events.fractured,destruct.Fracture{entity=e,kind=.Remove})
    physics_gallery_events(core.read(&stations),&counts,core.ref(&events),spawner,&bodies)
    testing.expect_value(t,counts.counts[10],u32(0));testing.expect_value(t,spawned.count,0);testing.expect_value(t,len(bodies.queue.items),0)
    core.push(&events.fractured,destruct.Fracture{entity=e,kind=.Damage})
    physics_gallery_events(core.read(&stations),&counts,core.ref(&events),spawner,&bodies)
    testing.expect_value(t,counts.counts[10],u32(1));testing.expect_value(t,spawned.count,1);testing.expect_value(t,len(bodies.queue.items),1)
}

@(test)
gallery_internal_strain_holds_then_releases_a_suspended_collection_without_launching :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    views:core.Table(Physics_Gallery_View);stations:core.Table(Physics_Gallery);states:core.Table(destruct.Destructible_State);groups:core.Table(destruct.Destructible_Group);force_fields:core.Table(phys.Force_Field);strain_fields:core.Table(destruct.Strain_Field)
    defer core.table_destroy(&views);defer core.table_destroy(&stations);defer core.table_destroy(&states);defer core.table_destroy(&groups);defer core.table_destroy(&force_fields);defer core.table_destroy(&strain_fields)
    actions:inp.Actions;requests:destruct.Destruct_Requests;bodies:phys.Body_Requests;caches:cache.Geometry_Requests;ragdolls:Ragdoll_Gallery_Requests
    defer delete(requests.queue.items);defer delete(requests.waiting.items);defer delete(bodies.queue.items);defer delete(caches.queue.items);defer delete(ragdolls.queue.items)
    physics:phys.Physics_State;defer phys.state_destroy(&physics)
    settings:=phys.Physics_Settings{bodies=8,shapes=32,contacts=32,joints=1,hulls=16,breakables=1,pieces=32,bonds=64}
    if !testing.expect(t,gallery_physics_make(&physics,settings)) {return}
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    sites:=[2][3]f32{{-.25,0,0},{.25,0,0}}
    dd:=phys.BREAKABLE_DESC_DEFAULT;dd.mesh,dd.sites=geom.mesh_buffer_view(&cube),sites[:];dd.position={0,2,0};dd.kinematic=true;dd.debris_volume=0
    h,error:=phys.breakable_create(&physics,dd)
    if !testing.expect_value(t,error,phys.Breakable_Error.None) {return}
    root:=phys.breakable_body(core.ref(&physics),h)
    target,station:=core.create(&entities),core.create(&entities)
    core.add(&views,core.create(&entities),PHYSICS_GALLERY_VIEW_DEFAULT)
    core.add(&stations,station,Physics_Gallery{station=11,target=target,origin={0,1,0},trigger=1})
    core.add(&states,target,destruct.Destructible_State{handle=h,body=root})
    core.table_settle(&views,&entities);core.table_settle(&stations,&entities);core.table_settle(&states,&entities)
    for activation in 1..=2 {
        core.edit(&stations,station).trigger=u32(activation)
        physics_gallery_actions(&views,&stations,{actions=core.ref(&actions)},&requests,&bodies,&force_fields,&strain_fields,&caches,&ragdolls,{playing=true,dt=1.0/60},destruct.Destruct_View{core.ref(&physics),core.read(&states),core.read(&groups)})
        command:=requests.queue.items[activation-1]
        testing.expect_value(t,command.vector,mm.Vec3{})
        if activation==1 {
            testing.expect_value(t,command.kind,destruct.Fracture_Kind.Weaken)
            asked:=command.event;asked.breakable,asked.piece=h,-1
            _,_,ok:=phys.break_apply(&physics,asked)
            testing.expect(t,ok);testing.expect_value(t,phys.breakable_revision(core.ref(&physics),h),u32(0))
            for _ in 0..<30 {gallery_step(&physics)}
            testing.expect_value(t,gallery_body(&physics,root).pose.position,dd.position)
        } else {
            testing.expect_value(t,command.kind,destruct.Fracture_Kind.Damage)
            asked:=command.event;asked.breakable,asked.piece=h,-1
            _,ok,_:=phys.break_apply(&physics,asked)
            testing.expect(t,ok)
            pieces:[2]phys.Piece_Info;testing.expect_value(t,phys.breakable_pieces(core.ref(&physics),h,pieces[:]),2)
            testing.expect(t,pieces[0].body!=pieces[1].body)
            falling:=pieces[0].body if pieces[0].body!=root else pieces[1].body
            testing.expect_value(t,gallery_body(&physics,falling).linear,mm.Vec3{})
            before:=gallery_body(&physics,falling).pose.position
            for _ in 0..<30 {gallery_step(&physics)}
            testing.expect(t,gallery_body(&physics,falling).pose.position.y<before.y-.5)
            testing.expect_value(t,gallery_body(&physics,root).pose.position,dd.position)
        }
    }
    events:destruct.Destruct_Events;counts:Physics_Gallery_Events;app:host.App;spawned:core.Problems;spawner:=scene.Spawner{problems=&spawned}
    defer delete(events.fractured.items)
    core.push(&events.fractured,destruct.Fracture{entity=target,kind=.Damage})
    physics_gallery_events(core.read(&stations),&counts,core.ref(&events),spawner,&bodies)
    testing.expect_value(t,len(bodies.queue.items),0)
}

@(test)
gallery_keeps_initial_trigger_until_ready_and_slices_through_a_live_piece_center :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    views:core.Table(Physics_Gallery_View);stations:core.Table(Physics_Gallery);states:core.Table(destruct.Destructible_State);groups:core.Table(destruct.Destructible_Group);force_fields:core.Table(phys.Force_Field);strain_fields:core.Table(destruct.Strain_Field)
    defer core.table_destroy(&views);defer core.table_destroy(&stations);defer core.table_destroy(&states);defer core.table_destroy(&groups);defer core.table_destroy(&force_fields);defer core.table_destroy(&strain_fields)
    actions:inp.Actions;requests:destruct.Destruct_Requests;bodies:phys.Body_Requests;caches:cache.Geometry_Requests;ragdolls:Ragdoll_Gallery_Requests
    defer delete(requests.queue.items);defer delete(requests.waiting.items);defer delete(bodies.queue.items);defer delete(caches.queue.items);defer delete(ragdolls.queue.items)
    physics:phys.Physics_State;defer phys.state_destroy(&physics)
    view:=core.create(&entities);station:=core.create(&entities);target:=core.create(&entities)
    core.add(&views,view,PHYSICS_GALLERY_VIEW_DEFAULT)
    core.add(&stations,station,Physics_Gallery{station=2,target=target,trigger=1,origin={3,1,5}})
    core.table_settle(&views,&entities);core.table_settle(&stations,&entities);core.entities_settle(&entities)
    physics_gallery_actions(&views,&stations,{actions=core.ref(&actions)},&requests,&bodies,&force_fields,&strain_fields,&caches,&ragdolls,{playing=true,dt=1.0/60},destruct.Destruct_View{core.ref(&physics),core.read(&states),core.read(&groups)})
    testing.expect_value(t,core.at(&stations,core.row_of(&stations,station)).activations,u32(0));testing.expect_value(t,len(requests.queue.items),0)
    settings:=phys.Physics_Settings{bodies=8,shapes=32,contacts=32,joints=1,hulls=32,breakables=1,pieces=32,bonds=64}
    testing.expect(t,gallery_physics_make(&physics,settings))
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    sites:=[2][3]f32{{-.25,0,0},{.25,0,0}}
    config:=phys.BREAKABLE_DESC_DEFAULT;config.mesh,config.sites=geom.mesh_buffer_view(&cube),sites[:];config.position={3,.3,5};config.rotation=mm.quat_axis_angle({0,1,0},.4)
    h,error:=phys.breakable_create(&physics,config)
    if !testing.expect_value(t,error,phys.Breakable_Error.None) {return}
    body:=phys.breakable_body(core.ref(&physics),h)
    core.add(&states,target,destruct.Destructible_State{handle=h,body=body});core.table_settle(&states,&entities)
    physics_gallery_actions(&views,&stations,{actions=core.ref(&actions)},&requests,&bodies,&force_fields,&strain_fields,&caches,&ragdolls,{playing=true,dt=1.0/60},destruct.Destruct_View{core.ref(&physics),core.read(&states),core.read(&groups)})
    testing.expect_value(t,core.at(&stations,core.row_of(&stations,station)).activations,u32(1));testing.expect_value(t,len(requests.queue.items),1)
    command:=requests.queue.items[0];testing.expect_value(t,command.kind,destruct.Fracture_Kind.Slice)
    asked:=command.event;asked.breakable,asked.piece=h,-1
    _,cut,_:=phys.break_apply(&physics,asked)
    testing.expect(t,cut);testing.expect(t,phys.breakable_revision(core.ref(&physics),h)>0)
    testing.expect(t,abs(command.region.point.y-.3)<.001)
    events:destruct.Destruct_Events;counts:Physics_Gallery_Events;app:host.App;spawned:core.Problems;spawner:=scene.Spawner{problems=&spawned}
    defer delete(events.fractured.items)
    core.push(&events.fractured,destruct.Fracture{entity=target,kind=.Slice,point=command.region.point})
    physics_gallery_events(core.read(&stations),&counts,core.ref(&events),spawner,&bodies)
    testing.expect_value(t,counts.counts[2],u32(1));testing.expect_value(t,len(bodies.queue.items),1)
    launch:=bodies.queue.items[0]
    testing.expect_value(t,launch.kind,phys.Body_Request_Kind.Area_Impulse)
    pieces:[8]destruct.Piece_Info;piece_count:=phys.breakable_pieces(core.ref(&physics),h,pieces[:])
    live:phys.Body_Handle
    for piece in pieces[:min(piece_count,len(pieces))] {if piece.body!=0 {live=piece.body;break}}
    if !testing.expect(t,live!=0) {return}
    before:=gallery_body(&physics,live).pose
    problems:core.Problems
    gallery_step(&physics,&bodies,&problems)
    testing.expect_value(t,problems.count,0)
    launched:=0
    for piece in pieces[:min(piece_count,len(pieces))] {
        // A launch changes the velocity by its strength; one step of gravity, by a sixth of a m/s.
        if piece.body!=0 && linalg.length(gallery_body(&physics,piece.body).linear)>launch.strength*.5 {launched+=1}
    }
    testing.expect(t,launched>=2)
    testing.expect(t,gallery_body(&physics,live).pose.position!=before.position)
    core.edit(&stations,station).station=10
    physics_gallery_events(core.read(&stations),&counts,core.ref(&events),spawner,&bodies)
    testing.expect_value(t,spawned.count,1)
    testing.expect(t,physics_gallery_burst_at(command.region.point).z>command.region.point.z+.7)
}

@(test)
gallery_event_counts_restart_when_the_scene_is_loaded_again :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    stations:core.Table(Physics_Gallery);defer core.table_destroy(&stations)
    counts:Physics_Gallery_Events;events:destruct.Destruct_Events;bodies:phys.Body_Requests;app:host.App;spawned:core.Problems;spawner:=scene.Spawner{problems=&spawned}
    defer delete(events.fractured.items);defer delete(bodies.queue.items)
    for _ in 0..<3 {
        e:=core.create(&entities)
        core.add(&stations,e,Physics_Gallery{station=10,target=e})
        core.table_settle(&stations,&entities)
        physics_gallery_events(core.read(&stations),&counts,core.ref(&events),spawner,&bodies)
        testing.expect_value(t,counts.counts[10],u32(0))
        core.push(&events.fractured,destruct.Fracture{entity=e})
        physics_gallery_events(core.read(&stations),&counts,core.ref(&events),spawner,&bodies)
        testing.expect_value(t,counts.counts[10],u32(1))
        clear(&events.fractured.items)
        core.entities_clear(&entities);core.table_clear(&stations)
    }
}

@(test)
gallery_fragments_remain_while_sleeping_and_fade_before_their_physical_expiry :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    stations:core.Table(Physics_Gallery);states:core.Table(destruct.Destructible_State);groups:core.Table(destruct.Destructible_Group);tints:core.Table(render.Tint)
    defer core.table_destroy(&stations);defer core.table_destroy(&states);defer core.table_destroy(&groups);defer core.table_destroy(&tints)
    physics:phys.Physics_State;defer phys.state_destroy(&physics)
    settings:=phys.Physics_Settings{bodies=8,shapes=32,contacts=32,joints=1,hulls=16,breakables=1,pieces=32,bonds=64}
    if !testing.expect(t,gallery_physics_make(&physics,settings)) {return}
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    sites:=[2][3]f32{{-.25,0,0},{.25,0,0}}
    dd:=phys.BREAKABLE_DESC_DEFAULT;dd.mesh,dd.sites=geom.mesh_buffer_view(&cube),sites[:];dd.removal_ticks=480;dd.debris_volume=0
    target,fragment:=core.create(&entities),core.create(&entities)
    dd.user_data=u64(target)
    handle,error:=phys.breakable_create(&physics,dd)
    if !testing.expect_value(t,error,phys.Breakable_Error.None) {return}
    _,fractured,_:=phys.break_apply(&physics,{breakable=handle,piece=-1,region={radius=10,blend=10},strain=10000})
    if !testing.expect(t,fractured) {return}
    root:=phys.breakable_body(core.ref(&physics),handle)
    pieces:[8]destruct.Piece_Info;count:=phys.breakable_pieces(core.ref(&physics),handle,pieces[:])
    body:phys.Body_Handle
    for piece in pieces[:min(count,len(pieces))] {if piece.body!=root && piece.body!=0 {body=piece.body;break}}
    if !testing.expect(t,body!=0) {return}
    phys.proxy_set(&physics,target,root,{},1);phys.proxy_set(&physics,fragment,body,{},1)
    core.add(&stations,core.create(&entities),Physics_Gallery{station=9,target=target,fade_seconds=2})
    core.add(&states,target,destruct.Destructible_State{handle=handle,body=root})
    core.add(&groups,fragment,destruct.Destructible_Group{owner=target,group=1})
    original:=render.Tint{color={.3,.4,.5,1}}
    core.add(&tints,fragment,original);core.add(&tints,target,original)
    core.table_settle(&stations,&entities);core.table_settle(&states,&entities);core.table_settle(&groups,&entities);core.table_settle(&tints,&entities)
    for tick in 0..<480 {
        physics_gallery_fade(core.read(&stations),destruct.Destruct_View{core.ref(&physics),core.read(&states),core.read(&groups)},&tints,{playing=true,dt=1.0/60})
        if tick==360 {testing.expect_value(t,core.at(&tints,core.row_of(&tints,fragment)).color.a,f32(1))}
        if tick==420 {testing.expect(t,abs(core.at(&tints,core.row_of(&tints,fragment)).color.a-.5)<.001)}
        info,valid:=phys.body_info(core.ref(&physics),body)
        if tick==360 {testing.expect(t,!info.awake)}
        testing.expect(t,valid)
        testing.expect_value(t,core.at(&tints,core.row_of(&tints,target)),original)
        gallery_step(&physics,gravity={})
    }
    physics_gallery_fade(core.read(&stations),destruct.Destruct_View{core.ref(&physics),core.read(&states),core.read(&groups)},&tints,{playing=true,dt=1.0/60})
    testing.expect_value(t,core.at(&tints,core.row_of(&tints,fragment)).color.a,f32(0))
    gallery_step(&physics,gravity={})
    _,kept:=phys.body_info(core.ref(&physics),body)
    _,stays:=phys.body_info(core.ref(&physics),root)
    testing.expect(t,!kept && stays)
}

// A tick of a simulation that only the breakables of a test fill.
@(private="file")
gallery_step :: proc(physics:^phys.Physics_State,requests:^phys.Body_Requests=nil,problems:^core.Problems=nil,gravity:=[3]f32{0,-9.81,0}) {
    job_system:jobs.Job_System
    phys.simulate(physics,requests,&job_system,1.0/60,gravity,problems)
}

@(private="file")
gallery_body :: proc(physics:^phys.Physics_State,body:phys.Body_Handle) -> phys.Body_Info {
    info,_:=phys.body_info(core.ref(physics),body)
    return info
}
