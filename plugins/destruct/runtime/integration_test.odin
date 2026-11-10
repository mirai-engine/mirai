package destruct

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import volume "mirai:engine/volume"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/jobs"
import mm "mirai:std/math"

@(private="file")
Destruct_World :: struct {
    using world:core.Test_World,
    using rows:Test_Destruct,
}

@(private="file")
Destruct_Test :: struct {
    using w:Destruct_World,
    using application:Test_Destruct_Host,
    tick:u64,
}

// folder: of base.test_folder, asked for before the test puts an allocator of its own in the context.
@(private="file")
destruct_test_init :: proc(t:^testing.T,f:^Destruct_Test,folder:string,hulls:int=8,anchor_first:bool=true,pieces:int=2,events:int=0) -> bool {
    if folder=="" {return false}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    b:asset.Fracture_Builder;asset.fracture_builder_init(&b);defer asset.fracture_builder_destroy(&b)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    for part in 0..<pieces {asset.fracture_piece_add(&b,geom.mesh_buffer_view(&cube),{{f32(part)*1.02-f32(pieces-1)*.51,0,0},1,{1,1,1}},anchor=anchor_first && part==0)}
    if asset.fracture_connect_proximity(&b,.03,.5,10)!=.None {return false}
    if asset.fracture_save(fmt.tprintf("%s/source.fracture",folder),&types,asset.fracture_builder_desc(&b,{1,2}))!=.None {return false}
    if !core.test_world_init(t,&f.w,test_types) {return false}
    f.app.assets,f.app.allocator=&f.assets,context.allocator
    if !jobs.system_init(&f.app.jobs,{threads=0}) {return false}
    if !host.assets_init(&f.assets,{root=folder,capacity=32}) {return false}
    return phys.test_state_make(&f.physics,{bodies=16,shapes=32,contacts=64,joints=4,hulls=i32(hulls),breakables=2,pieces=32,bonds=64,events=i32(events)})
}

@(private="file")
destruct_test_destroy :: proc(f:^Destruct_Test) {
    cache_destroy(f.app.assets,&f.app.jobs,&f.cache);jobs.system_destroy(&f.app.jobs)
    core.test_world_destroy(&f.w)
    host.assets_destroy(&f.assets)
}

@(private="file")
destruct_test_step :: proc(f:^Destruct_Test,resimulating:=false) {
    core.test_world_settle(&f.w)
    f.tick+=1
    test_step(&f.rows,&f.application,core.commands_of(core.test_world_ref(&f.w)),{dt=1.0/60,playing=true,tick=f.tick,resimulating=resimulating})
    core.test_world_settle(&f.w)
}

@(private="file")
destruct_test_entity :: proc(f:^Destruct_Test,config:Destructible,pose:=core.TRANSFORM_IDENTITY) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.configs,e,config);core.add(&f.colliders,e,collider_fracture());core.add(&f.transforms,e,pose);core.add(&f.meshes,e,render.Mesh_Renderer{shape=.Cube})
    return e
}

@(test)
pieces_take_the_surface_and_collision_of_the_fracture_collider_and_a_new_preset_keeps_them :: proc(t:^testing.T) {
    f:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-collision"))) {return}
    defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2}
    e:=destruct_test_entity(&f,config)
    destruct_test_step(&f);destruct_test_step(&f)
    surface:=core.get(&f.colliders,e)
    surface.friction,surface.restitution=0.2,0.4
    destruct_test_step(&f)
    handle:=core.get(&f.states,e).handle
    infos:[2]Piece_Info
    if !testing.expect_value(t,pieces(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,infos[:]),2) {return}
    solid:=phys.collision_filter(nil,collider_fracture())
    for piece in infos {
        shape:=&f.physics.world.shapes[base.handle_index(base.Handle(piece.shape))]
        testing.expect(t,shape.friction==0.2 && shape.restitution==0.4 && shape.filter==solid)
    }
    core.get(&f.colliders,e).preset=phys.PRESET_TRIGGER
    destruct_test_step(&f)
    trigger:=phys.collision_filter(nil,{preset=phys.PRESET_TRIGGER})
    testing.expect_value(t,core.get(&f.states,e).handle,handle)
    testing.expect_value(t,core.get(&f.states,e).applied_filter,trigger)
    for piece in infos {testing.expect_value(t,f.physics.world.shapes[base.handle_index(base.Handle(piece.shape))].filter,trigger)}
    testing.expect_value(t,f.problems.count,0)
}

@(test)
a_destructible_that_cannot_be_made_names_its_entity_and_the_fix :: proc(t:^testing.T) {
    f:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-problems"))) {return}
    defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2}
    boxed:=destruct_test_entity(&f,config)
    core.add(&f.colliders,boxed,phys.collider_box({0.5,0.5,0.5}))
    bare:=destruct_test_entity(&f,config)
    core.remove(&f.meshes,bare)
    destruct_test_step(&f);destruct_test_step(&f)
    collider:=core.problem_find(&f.problems,boxed,"destruct.collider")
    mesh:=core.problem_find(&f.problems,bare,"destruct.mesh")
    if !testing.expect(t,collider!=nil && mesh!=nil,"each entity has the problem of its own cause") {return}
    testing.expect(t,strings.contains(core.problem_text(collider),"collider_fracture()"),core.problem_text(collider))
    testing.expect(t,strings.contains(core.problem_text(mesh),"it has no Mesh_Renderer"),core.problem_text(mesh))
    testing.expect(t,!core.has(&f.states,boxed) || !phys.breakable_valid(core.ref(&f.physics),core.get(&f.states,boxed).handle))
}

@(test)
a_strain_asked_of_physics_in_a_volume_breaks_a_destructible_and_is_applied_as_its_events :: proc(t:^testing.T) {
    f:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-strain-area"),pieces=4)) {return}
    defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2};config.debris_volume=0;config.gravity_scale=0
    e:=destruct_test_entity(&f,config)
    destruct_test_step(&f);destruct_test_step(&f)
    bodies:phys.Body_Requests;defer delete(bodies.queue.items)
    out:[4]Group_Info
    // A weakening reaches its bonds by the weight of the volume and lets nothing go.
    phys.strain_area(&bodies,volume.sphere(4,blend=1),{},1,weakening=true)
    testing.expect(t,phys.simulate(&f.physics,&bodies,&f.app.jobs,1.0/60,{}))
    destruct_test_step(&f)
    if !testing.expect_value(t,len(f.events.applied.items),1) {return}
    applied:=f.events.applied.items[0]
    testing.expect(t,applied.entity==e && applied.record.kind==.Weaken && applied.record.radius==4 && applied.record.blend==1 && applied.record.strain==1)
    testing.expect_value(t,groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,out[:]),1)
    // What breaks it is applied as one event, and every piece is a body of its own.
    phys.strain_area(&bodies,volume.sphere(4),{},1e6)
    testing.expect(t,phys.simulate(&f.physics,&bodies,&f.app.jobs,1.0/60,{}))
    destruct_test_step(&f)
    testing.expect(t,len(f.events.applied.items)==1 && f.events.applied.items[0].record.kind==.Damage)
    testing.expect_value(t,groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,out[:]),4)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
impact_damage_configuration_keeps_passive_clients_intact_and_explicit_server_strain_enabled :: proc(t:^testing.T) {
    for client in ([2]bool{false,true}) {
        f:Destruct_Test
        if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-impact-policy"))) {return}
        defer destruct_test_destroy(&f)
        config:=destructible();config.fracture={1,2};config.gravity_scale=0;config.debris_volume=0;config.damage_threshold=0
        testing.expect(t,config.impact_damage)
        f.authority.role=.Client if client else .Server
        e:=destruct_test_entity(&f,config)
        destruct_test_step(&f);destruct_test_step(&f)
        ball:=phys.test_ball(&f.physics,{-.51,0,3},{0,0,-30})
        impacts:=0
        for _ in 0..<12 {
            phys.simulate(&f.physics,nil,&f.app.jobs,1.0/60)
            impacts+=len(phys.breakable_events(core.ref(&f.physics)))
        }
        slowed,_:=phys.body_info(core.ref(&f.physics),ball)
        testing.expect(t,slowed.linear.z>-30)
        if client {testing.expect_value(t,impacts,0)} else {testing.expect(t,impacts>0)}
        config.impact_damage=false
        core.get(&f.configs,e)^=config
        destruct_test_step(&f);destruct_test_step(&f)
        second:=phys.test_ball(&f.physics,{.51,0,3},{0,0,-30})
        for _ in 0..<12 {
            phys.simulate(&f.physics,nil,&f.app.jobs,1.0/60)
            testing.expect_value(t,len(phys.breakable_events(core.ref(&f.physics))),0)
        }
        slowed,_=phys.body_info(core.ref(&f.physics),second)
        testing.expect(t,slowed.linear.z>-30)
        strain(&f.requests,e,{},4,1000)
        destruct_test_step(&f)
        out:[4]Group_Info
        testing.expect_value(t,groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,out[:]),1 if client else 2)
    }
}

@(test)
fragment_removal_validates_the_group_and_retires_its_physics_proxy :: proc(t:^testing.T) {
    f:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-remove"))) {return}
    defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2};config.debris_volume=0;config.gravity_scale=0;config.removal_lifetime=1
    e:=destruct_test_entity(&f,config)
    destruct_test_step(&f);destruct_test_step(&f)
    testing.expect_value(t,remove(&f.requests,core.read(&f.groups),e),Remove_Error.Missing_Group)
    testing.expect_value(t,len(f.requests.queue.items),0)
    strain(&f.requests,e,{},4,1000);destruct_test_step(&f)
    out:[4]Group_Info
    testing.expect_value(t,groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,out[:]),2)
    fragment:Group_Info
    for group in out[:2] {
        if group.group!=0 {fragment=group;continue}
        testing.expect(t,!group.expires)
    }
    testing.expect(t,fragment.expires)
    testing.expect_value(t,fragment.remaining_ticks,u32(60))
    for row in 0..<core.count(core.read(&f.groups)) {
        if f.groups.values[row].group==0 {
            testing.expect_value(t,remove(&f.requests,core.read(&f.groups),f.groups.entities[row]),Remove_Error.Retained_Group)
        }
    }
    testing.expect_value(t,len(f.requests.queue.items),0)
    testing.expect_value(t,remove(&f.requests,core.read(&f.groups),fragment.entity),Remove_Error.None)
    destruct_test_step(&f)
    testing.expect(t,core.alive(&f.entities,e) && !core.alive(&f.entities,fragment.entity))
    _,standing:=phys.body_pose(core.ref(&f.physics),fragment.body)
    testing.expect(t,!standing)
    testing.expect_value(t,phys.body_of(core.ref(&f.physics),fragment.entity),phys.Body_Handle(0))
    testing.expect_value(t,groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,out[:]),1)
    testing.expect_value(t,remove(&f.requests,core.read(&f.groups),fragment.entity),Remove_Error.Missing_Group)
}

@(test)
the_fractures_one_end_applies_replay_alike_on_another_and_passive_ends_keep_deadlines :: proc(t:^testing.T) {
    a,b:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&a,base.test_folder(t,"destruct-remove-server"))) {return}
    defer destruct_test_destroy(&a)
    if !testing.expect(t,destruct_test_init(t,&b,base.test_folder(t,"destruct-remove-client"))) {return}
    defer destruct_test_destroy(&b)
    config:=destructible();config.fracture={1,2};config.debris_volume=0;config.gravity_scale=0;config.removal_lifetime=1
    first:=destruct_test_entity(&a,config);second:=destruct_test_entity(&b,config)
    core.add(&a.ids,first,core.Id{42});core.add(&b.ids,second,core.Id{42})
    a.authority.role=.Server
    b.authority.role=.Client
    destruct_test_step(&a);destruct_test_step(&a);destruct_test_step(&b);destruct_test_step(&b)
    deliver :: proc(a,b:^Destruct_Test,to:core.Entity) {
        for item in a.events.applied.items {replay(&b.requests,to,item.record)}
    }
    strain(&a.requests,first,{},4,1000);destruct_test_step(&a)
    deliver(&a,&b,second);destruct_test_step(&b)
    server,client:[4]Group_Info
    testing.expect_value(t,groups(Destruct_View{core.ref(&a.physics),core.read(&a.states),core.read(&a.groups)},first,server[:]),2)
    testing.expect_value(t,groups(Destruct_View{core.ref(&b.physics),core.read(&b.states),core.read(&b.groups)},second,client[:]),2)
    detached_a,detached_b:Group_Info
    for group in server[:2] {if group.group!=0 {detached_a=group}}
    for group in client[:2] {if group.group!=0 {detached_b=group}}
    testing.expect(t,detached_b.expires)
    testing.expect_value(t,detached_b.remaining_ticks,detached_a.remaining_ticks)
    testing.expect_value(t,remove(&b.requests,core.read(&b.groups),detached_b.entity),Remove_Error.None)
    destruct_test_step(&b)
    _,standing:=phys.body_pose(core.ref(&b.physics),detached_b.body)
    testing.expect(t,standing)
    for _ in 0..<61 {phys.simulate(&b.physics,nil,&b.app.jobs,1.0/60)}
    _,standing=phys.body_pose(core.ref(&b.physics),detached_b.body)
    testing.expect(t,standing)
    remaining,expires:=phys.breakable_body_remaining_ticks(core.ref(&b.physics),core.get(&b.states,second).handle,detached_b.body)
    testing.expect(t,expires)
    testing.expect_value(t,remaining,u32(0))
    testing.expect_value(t,remove(&a.requests,core.read(&a.groups),detached_a.entity),Remove_Error.None)
    destruct_test_step(&a);deliver(&a,&b,second);destruct_test_step(&b)
    testing.expect(t,!core.alive(&a.entities,detached_a.entity) && !core.alive(&b.entities,detached_b.entity))
    testing.expect_value(t,phys.breakable_check(core.ref(&a.physics),core.get(&a.states,first).handle),phys.breakable_check(core.ref(&b.physics),core.get(&b.states,second).handle))
    testing.expect_value(t,core.get(&a.states,first).sequence,u32(2))
    testing.expect_value(t,core.get(&b.states,second).sequence,u32(2))
    for item in b.events.replayed.items {testing.expect(t,item.done)}
}

@(test)
cosmetic_fragments_can_be_removed_locally_on_a_passive_client :: proc(t:^testing.T) {
    f:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-remove-cosmetic"))) {return}
    defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2};config.debris_volume=2;config.gravity_scale=0
    e:=destruct_test_entity(&f,config)
    f.authority.role=.Client
    destruct_test_step(&f);destruct_test_step(&f)
    state:=core.get(&f.states,e)
    phys.test_strain(&f.physics,state.handle,{},4,1000)
    destruct_test_step(&f)
    out:[4]Group_Info
    testing.expect_value(t,groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,out[:]),2)
    fragment:Group_Info
    for group in out[:2] {if group.group!=0 {fragment=group}}
    testing.expect(t,fragment.debris && fragment.expires)
    before:=phys.breakable_check(core.ref(&f.physics),state.handle)
    testing.expect_value(t,remove(&f.requests,core.read(&f.groups),fragment.entity),Remove_Error.None)
    destruct_test_step(&f)
    testing.expect(t,!core.alive(&f.entities,fragment.entity))
    testing.expect_value(t,phys.breakable_check(core.ref(&f.physics),state.handle),before)
    testing.expect_value(t,len(f.events.applied.items),0)
}

@(test)
authored_destruction_proxies_geometry_and_groups_survive_cache_recovery_offline :: proc(t:^testing.T) {
    f:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-recover"))) {return}
    defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2};config.debris_volume=0;config.gravity_scale=0
    e:=destruct_test_entity(&f,config,core.Transform{{0,2,0},1,{1,1,1}})
    destruct_test_step(&f);destruct_test_step(&f)
    initial:=core.get(&f.states,e).handle
    testing.expect(t,phys.body_of(core.ref(&f.physics),e)!=0)
    strain(&f.requests,e,{0,2,0},4,1000)
    destruct_test_step(&f)
    out:[8]Group_Info
    testing.expect_value(t,groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,out[:]),2)
    for group in out[:2] {
        testing.expect_value(t,phys.body_of(core.ref(&f.physics),group.entity),group.body)
        testing.expect_value(t,phys.entity_of(core.ref(&f.physics),group.body),group.entity)
    }
    cut_geometry:geom.Mesh_Buffer;geom.mesh_buffer_init(&cut_geometry);defer geom.mesh_buffer_destroy(&cut_geometry)
    before:=phys.state_hash(core.ref(&f.physics))
    f.physics.epoch+=1
    destruct_test_step(&f)
    testing.expect_value(t,core.get(&f.states,e).handle,initial)
    testing.expect_value(t,phys.state_hash(core.ref(&f.physics)),before)
    after:[8]Group_Info
    testing.expect_value(t,groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,after[:]),2)
    for group,at in after[:2] {testing.expect_value(t,group.entity,out[at].entity)}
    info:[4]Piece_Info;testing.expect_value(t,pieces(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,info[:]),2)
    testing.expect(t,piece_geometry(core.ref(&f.cache),e,info[0].id,&cut_geometry))
    testing.expect_value(t,len(cut_geometry.indices),36)
    transforms_version:=core.version(core.read(&f.transforms))
    destruct_test_step(&f)
    testing.expect_value(t,core.version(core.read(&f.transforms)),transforms_version)
    core.remove(&f.configs,e);core.remove(&f.states,e);destruct_test_step(&f)
    testing.expect_value(t,phys.body_of(core.ref(&f.physics),e),phys.Body_Handle(0))
    testing.expect_value(t,core.count(core.read(&f.groups)),0)
    testing.expect_value(t,f.physics.world.body_count,i32(0))
}

@(test)
moving_destructible_anchors_follow_the_author_parent_with_public_kinematic_requests :: proc(t:^testing.T) {
    f:Destruct_Test;if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-parent"))) {return};defer destruct_test_destroy(&f)
    parent:=core.create(&f.entities);parent_pose:=core.Transform{{3,1,2},mm.quat_axis_angle({0,1,0},.4),{2,1,.5}}
    core.add(&f.transforms,parent,parent_pose)
    config:=destructible();config.fracture={1,2};config.follow_parent=true
    local:=core.Transform{{1,.5,0},1,{1,1,1}}
    e:=destruct_test_entity(&f,config,local);core.add(&f.parents,e,core.Parent{entity=parent})
    destruct_test_step(&f);destruct_test_step(&f)
    held,_:=phys.body_info(core.ref(&f.physics),phys.body_of(core.ref(&f.physics),e))
    testing.expect_value(t,held.type,phys.Body_Type.Kinematic)
    parent_pose.position.x+=2;core.get(&f.transforms,parent)^=parent_pose
    requests:phys.Body_Requests;defer delete(requests.queue.items)
    destruct_parent_motion(core.ref(&f.physics),core.read(&f.configs),core.read(&f.states),core.read(&f.transforms),core.read(&f.parents),&requests,{playing=true,dt=1.0/60})
    testing.expect_value(t,len(requests.queue.items),1)
    request:=requests.queue.items[0];wanted:=mm.transform_compose({parent_pose.position,parent_pose.rotation,parent_pose.scale},{local.position,local.rotation,local.scale})
    testing.expect_value(t,request.entity,e);testing.expect_value(t,request.kind,phys.Body_Request_Kind.Kinematic)
    testing.expect_value(t,request.position,wanted.position);testing.expect_value(t,request.rotation,wanted.rotation)
}

@(test)
rejected_authored_destruction_does_not_leave_root_or_fragment_proxies :: proc(t:^testing.T) {
    f:Destruct_Test;if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-budget"),1)) {return};defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2}
    e:=destruct_test_entity(&f,config)
    destruct_test_step(&f)
    testing.expect(t,core.get(&f.states,e).failed)
    testing.expect_value(t,phys.body_of(core.ref(&f.physics),e),phys.Body_Handle(0))
    testing.expect_value(t,core.count(core.read(&f.groups)),0)
    testing.expect_value(t,f.physics.world.body_count,i32(0))
    testing.expect_value(t,f.physics.world.shape_count,i32(0))
}

@(test)
damage_requested_before_the_first_tick_waits_for_an_authored_body_then_applies_once :: proc(t:^testing.T) {
    f:Destruct_Test;if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-initial-intent"))) {return};defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2};config.gravity_scale=0;config.debris_volume=0
    e:=destruct_test_entity(&f,config)
    strain(&f.requests,e,{},4,1000)
    destruct_test_step(&f)
    testing.expect_value(t,len(f.requests.waiting.items),1)
    testing.expect_value(t,core.get(&f.states,e).revision,u32(0))
    destruct_test_step(&f)
    testing.expect_value(t,len(f.requests.waiting.items),0)
    testing.expect(t,core.get(&f.states,e).revision>0)
    revision:=core.get(&f.states,e).revision
    destruct_test_step(&f)
    testing.expect_value(t,core.get(&f.states,e).revision,revision)
}

@(test)
successive_cuts_keep_detached_proxies_and_all_live_fragment_meshes :: proc(t:^testing.T) {
    f:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-repeated-cuts"))) {return}
    defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2};config.gravity_scale=0;config.debris_volume=0
    e:=destruct_test_entity(&f,config)
    destruct_test_step(&f);destruct_test_step(&f)
    strain(&f.requests,e,{},4,1000);destruct_test_step(&f)
    poses:[16]Group_Info
    testing.expect_value(t,groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,poses[:]),2)
    target:Group_Info
    for pose in poses[:2] {if pose.group!=0 {target=pose}}
    root_mesh:base.Asset_Id
    root_entity:=core.NONE
    for row in 0..<core.count(core.read(&f.groups)) {
        if f.groups.values[row].group!=0 {continue}
        root_entity=f.groups.entities[row]
        mesh,_:=core.get(core.read(&f.meshes),root_entity);root_mesh=mesh.mesh
    }
    for pass in 0..<3 {
        pieces_out:[16]Piece_Info
        count:=min(pieces(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,pieces_out[:]),len(pieces_out))
        point:[3]f32
        found:=false
        for piece in pieces_out[:count] {
            if piece.body!=target.body {continue}
            pose,_:=phys.body_pose(core.ref(&f.physics),target.body)
            point=pose.p+mm.quat_rotate(pose.q,piece.center);found=true;break
        }
        if !testing.expect(t,found,"the original detached proxy still owns a live piece") {return}
        slice(&f.requests,target.entity,point,{0,1,0})
        destruct_test_step(&f)
        phys.simulate(&f.physics,nil,&f.app.jobs,1.0/60)
        destruct_test_step(&f)
        testing.expect(t,core.alive(&f.entities,target.entity))
        testing.expect_value(t,phys.body_of(core.ref(&f.physics),target.entity),target.body)
        testing.expect_value(t,groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,poses[:]),3+pass)
        testing.expect_value(t,core.count(core.read(&f.groups)),3+pass)
        testing.expect_value(t,f.assets.stats.generated,3+pass)
        root,_:=core.get(core.read(&f.meshes),root_entity)
        testing.expect_value(t,root.mesh,root_mesh)
        for row in 0..<core.count(core.read(&f.groups)) {
            mesh,has:=core.get(core.read(&f.meshes),f.groups.entities[row])
            testing.expect(t,has && host.assets_mesh_generated(&f.assets,mesh.mesh))
        }
    }
    testing.expect_value(t,f.problems.count,0)
}

@(test)
root_slice_requests_preserve_previous_groups_meshes_and_volume_across_ticks :: proc(t:^testing.T) {
    f:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-root-repeated-cuts"),hulls=32,anchor_first=false)) {return}
    defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2};config.gravity_scale=0;config.debris_volume=0
    e:=destruct_test_entity(&f,config)
    destruct_test_step(&f);destruct_test_step(&f)
    handle:=core.get(&f.states,e).handle
    live_volume :: proc(f:^Destruct_Test,e:core.Entity) -> (volume:f32) {
        held:[64]Piece_Info
        count:=min(pieces(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,held[:]),len(held))
        for piece in held[:count] {
            if piece.body!=0 {volume+=piece.volume}
        }
        return
    }
    whole:=live_volume(&f,e)
    previous:[16]Group_Info
    previous_count:=min(groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,previous[:]),len(previous))
    for pass in 0..<3 {
        pieces_out:[32]Piece_Info
        count:=min(pieces(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,pieces_out[:]),len(pieces_out))
        point:[3]f32
        for piece in pieces_out[:count] {
            if piece.body==0 {continue}
            pose,_:=phys.body_pose(core.ref(&f.physics),piece.body)
            point=pose.p+mm.quat_rotate(pose.q,piece.center);break
        }
        slice(&f.requests,e,point,pass%2==0?[3]f32{0,1,0}:{1,0,0})
        destruct_test_step(&f)
        phys.simulate(&f.physics,nil,&f.app.jobs,1.0/60)
        destruct_test_step(&f)
        for group in previous[:previous_count] {
            testing.expect(t,core.alive(&f.entities,group.entity))
            testing.expect_value(t,phys.body_of(core.ref(&f.physics),group.entity),group.body)
        }
        testing.expect(t,abs(live_volume(&f,e)-whole)<5e-6,"successive root cuts preserve all live volume")
        previous_count=min(groups(Destruct_View{core.ref(&f.physics),core.read(&f.states),core.read(&f.groups)},e,previous[:]),len(previous))
        testing.expect(t,previous_count>=pass+2)
        testing.expect_value(t,f.assets.stats.generated,previous_count)
        for row in 0..<core.count(core.read(&f.groups)) {
            mesh,has:=core.get(core.read(&f.meshes),f.groups.entities[row])
            testing.expect(t,has && host.assets_mesh_generated(&f.assets,mesh.mesh))
        }
    }
    testing.expect_value(t,f.problems.count,0)
}

@(test)
a_cut_the_simulation_has_no_room_for_names_the_capacity_to_raise :: proc(t:^testing.T) {
    f:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-cut-capacity"),hulls=3)) {return}
    defer destruct_test_destroy(&f)
    config:=destructible();config.fracture={1,2};config.gravity_scale=0
    e:=destruct_test_entity(&f,config)
    destruct_test_step(&f);destruct_test_step(&f)
    slice(&f.requests,e,{-.51,0,0},{1,0,0})
    destruct_test_step(&f)
    testing.expect_value(t,phys.breakable_revision(core.ref(&f.physics),core.get(&f.states,e).handle),u32(0))
    problem:=core.problem_find(&f.problems,e,"destruct.capacity")
    if !testing.expect(t,problem!=nil,"the refused cut is a problem of its destructible") {return}
    testing.expect(t,strings.contains(core.problem_text(problem),"raise Physics_Settings.hulls"),core.problem_text(problem))
}

@(test)
impacts_lost_for_lack_of_events_name_the_setting_to_raise :: proc(t:^testing.T) {
    f:Destruct_Test
    if !testing.expect(t,destruct_test_init(t,&f,base.test_folder(t,"destruct-lost-events"),anchor_first=false,events=1)) {return}
    defer destruct_test_destroy(&f)
    // One wall falls on the other: their hit is one event of the step, and damages both.
    config:=destructible();config.fracture={1,2}
    walls:[2]core.Entity
    for &wall,i in walls {
        pose:=core.TRANSFORM_IDENTITY;pose.position={0,f32(i)*1.5,0}
        config.gravity_scale=f32(i)
        wall=destruct_test_entity(&f,config,pose)
    }
    destruct_test_step(&f);destruct_test_step(&f)
    for _ in 0..<40 {
        phys.simulate(&f.physics,nil,&f.app.jobs,1.0/60)
        destruct_test_step(&f)
        for wall in walls {
            if problem:=core.problem_find(&f.problems,wall,"destruct.events");problem!=nil {
                testing.expect(t,strings.contains(core.problem_text(problem),"raise events"),core.problem_text(problem))
                return
            }
        }
    }
    testing.expect(t,false,"an impact that did not fit was not reported")
}
