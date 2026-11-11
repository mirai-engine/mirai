package multiplayer

import "core:strings"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:engine/scene"
import phys "plugins:physics/runtime"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"

// A server decides what it simulates, also what a client predicts; what a
// client holds now is decided there. A new role starts the marks again.
@(test)
remote_follows_what_a_client_holds_on_a_server_and_a_new_role_clears_it :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    e:=net_test_body(&world,&info,1)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=17,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,0,.Server)) {return}
    defer session_destroy(&s)
    ref:=core.world_ref(&world,&info)
    core.add(&world.objects,e,net_test_replicate(simulation=.Lent))
    net_test_own(&world,e,3)
    core.settle(&info,&world,nil)
    s.host_ready=true
    authority_follow(&s,ref)
    core.settle(&info,&world,nil)
    testing.expect(t,core.owned(&world.remotes,e),"what a connection owns and predicts is decided here")

    s.server.objects[1]={object=Object(1),entity=e}
    held:=[]wire.Command{{kind=.Authority_Changed,object=Object(1),connection=3}}
    server_commands(&s,ref,nil,held,&world.remote)
    core.settle(&info,&world,nil)
    testing.expect(t,!core.owned(&world.remotes,e),"what a client holds is decided there")
    back:=[]wire.Command{{kind=.Authority_Changed,object=Object(1),connection=0}}
    server_commands(&s,ref,nil,back,&world.remote)
    core.settle(&info,&world,nil)
    testing.expect(t,core.owned(&world.remotes,e),"and here again when it gives it back")

    server_commands(&s,ref,nil,held,&world.remote)
    core.settle(&info,&world,nil)
    session_destroy(&s)
    authority_follow(&s,ref)
    core.settle(&info,&world,nil)
    testing.expect(t,core.count(&world.remotes)==0,"a session that ends leaves every entity to this end")
    s.host_ready=true // its host is still there for session_destroy
}

// A client decides the replica it predicts or holds, and not the others,
// as their roles change.
@(test)
remote_follows_the_replicas_a_client_neither_predicts_nor_holds :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    e:=net_test_body(&world,&info,1)
    shared:=Net_Test_Shared{info=&info}
    defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared,&app)
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=13,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&s)
    ref:=core.world_ref(&world,&info)
    r:=net_test_replica(&s,ref,e,.Shown,.Lent)
    testing.expect(t,!core.owned(&world.remotes,e),"someone else's replica is decided by the server")
    r.role=.Held
    replica_classify(&s,ref,r)
    core.settle(&info,&world,nil)
    testing.expect(t,core.owned(&world.remotes,e),"what it holds is decided here")
    r.role=.Predicted
    replica_classify(&s,ref,r)
    core.settle(&info,&world,nil)
    testing.expect(t,core.owned(&world.remotes,e),"and what it predicts")
    r.role=.Shown
    replica_classify(&s,ref,r)
    core.settle(&info,&world,nil)
    testing.expect(t,!core.owned(&world.remotes,e))
}

@(private="file")
@(component,replicated)
Net_Test_Names :: struct {names:[]string}

@(private="file")
Names_World :: struct {
    using world:core.Test_World,
    names:core.Table(Net_Test_Names),
}

// An array of bytes travels as one field, so its bytes must fit one part of a state.
@(private="file")
@(component,replicated)
Net_Test_Wide :: struct {bytes:[1024]u8}

@(private="file")
Wide_World :: struct {
    using world:core.Test_World,
    wide:core.Table(Net_Test_Wide),
}

// A replicated component the protocol cannot carry opens no network: the
// problem and the reason of the session name the component and why.
@(test)
a_replicated_component_that_does_not_fit_the_protocol_is_refused_with_its_fix :: proc(t:^testing.T) {
    refused :: proc(t:^testing.T,$W:typeid,name,why:string) {
        info,described:=core.test_info(t,W)
        if !described {return}
        defer core.test_info_destroy(&info)
        problems:core.Problems
        s:=Net_Session{allocator=context.allocator,problems=&problems}
        testing.expect(t,!protocol_build(&s,core.world_ref(nil,&info)))
        session_destroy(&s)
        refusal:=base.text_get(s.refusal[:])
        testing.expectf(t,strings.contains(refusal,name) && strings.contains(refusal,"does not fit the protocol") && strings.contains(refusal,why),"%s",refusal)
        testing.expect_value(t,problems.count,1)
        testing.expect_value(t,base.text_get(problems.entries[0].code[:]),"net.protocol")
    }
    refused(t,Names_World,"Net_Test_Names","not plain data")
    refused(t,Wide_World,"Net_Test_Wide","one of its fields encodes in more than")
}

@(private="file")
Crowded_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    worlds:core.Table(core.World_Transform),
    instances:core.Table(scene.Prefab_Instance),
    motions:core.Table(core.Motion),
    moves:core.Table(input.Move_Input),
    values:[COMPONENTS+1]core.Table(Net_Test_Value),
}

// A body with a driver and more replicated components than an object carries
// besides its pose, motion and driver is not replicated, and the problem says
// how many it may have.
@(test)
an_entity_with_more_replicated_components_than_an_object_carries_is_not_replicated :: proc(t:^testing.T) {
    w:Crowded_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    ref:=core.test_world_ref(&w)
    e:=core.create(&w.entities)
    core.add(&w.transforms,e,core.TRANSFORM_IDENTITY)
    core.add(&w.motions,e,core.Motion{})
    core.add(&w.moves,e,input.Move_Input{})
    for &table in w.values {core.add(&table,e,Net_Test_Value{})}
    core.test_world_settle(&w)
    problems:core.Problems
    s:=Net_Session{allocator=context.allocator,problems=&problems}
    defer session_destroy(&s)
    if !testing.expect(t,protocol_build(&s,ref)) {return}
    app:host.App
    testing.expect_value(t,server_create(&s,ref,e,REPLICATE_DEFAULT,core.NONE,0),Object(0))
    found:=core.problem_find(&problems,e,"net.object")
    if !testing.expect(t,found!=nil,"the entity is named") {return}
    testing.expectf(t,strings.contains(core.problem_text(found),"more replicated components"),"%s",core.problem_text(found))
}
