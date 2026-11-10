package multiplayer

import "base:runtime"
import "core:log"
import "core:testing"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"

// The protocol of a session with the memory ending at each request in turn:
// the session is refused and frees what it took, and with memory it is built.
// And a connection that arrives without memory for the inputs of its player:
// it is closed with a problem, and seated once there is memory. And a
// launched player whose session ends without memory for the text of why: it
// still ends, with the code of the network.
@(test)
a_session_without_memory_is_refused_and_a_connection_without_room_is_closed :: proc(t:^testing.T) {
    info:=net_test_info();defer delete(info.tables);defer delete(info.storages)
    world:Net_Test_World
    net_test_init(&world,context.allocator)
    defer net_test_destroy(&world)
    ref:=core.world_ref(&world,&info)
    failure:=Rollback_Allocation{owner=context.allocator}
    limited:=runtime.Allocator{rollback_allocator,&failure}
    built,refused:=false,false
    for budget:=0;!built && budget<4096;budget+=1 {
        s:=Net_Session{allocator=limited}
        failure.remaining=budget
        built=protocol_build(&s,ref)
        failure.remaining=max(int)
        whole:=built && len(s.fragments)==len(info.tables) && len(s.events)==len(info.messages) && s.types!=nil
        session_destroy(&s)
        refused||=!built
        testing.expectf(t,whole==built,"with %d requests served: built %v, whole %v",budget,built,whole)
    }
    testing.expect(t,built && refused,"refused without memory, and with it the protocol is built")

    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=17,endpoints=2,packets=64})) {return}
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,0,.Server)) {return}
    defer session_destroy(&s)
    problems:core.Problems
    s.problems=&problems
    events:Net_Events
    defer core.value_free(&events,type_info_of(Net_Events))
    world.remote.entries=make([dynamic]Remote_Input,limited)
    connected:=[]wire.Command{{kind=.Connected,connection=3}}
    budgets:=[]int{0,max(int)}
    for budget in budgets {
        failure.remaining=budget
        server_commands(&s,ref,nil,connected,&events,&world.remote)
        failure.remaining=max(int)
        testing.expectf(t,problems.count==1 && (remote_entry(&world.remote,3)!=nil)==(budget!=0),"with %d requests served: %d problems, seated %v",budget,problems.count,remote_entry(&world.remote,3)!=nil)
    }

    for mode in ([2]wire.Mode{.Client,.Server}) {
        ended:=Net_Session{allocator=limited,launched=true,mode=mode,problems=&problems}
        player:=host.App{allocator=limited}
        failure.remaining=0
        // The player is told with an error in the log, which would fail the test.
        logger:=context.logger
        context.logger=log.nil_logger()
        session_fail(&ended,player.allocator,"the server went away")
        context.logger=logger
        failure.remaining=max(int)
        testing.expectf(t,ended.reason_text=="" && core.problem_find(&problems,core.NONE,"net.reason")!=nil,"%v: the reason found memory, or no problem says it did not",mode)
        report_update(&ended,&player)
        testing.expectf(t,player.quit && player.exit_code==PLAYER_NET,"%v: quit %v with code %d",mode,player.quit,player.exit_code)
    }
}
