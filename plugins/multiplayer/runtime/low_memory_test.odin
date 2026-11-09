package multiplayer

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"

// Refuses the requests of one size and serves the others from its owner.
@(private="file")
Size_Refusal :: struct {owner:runtime.Allocator,size,refused:int}

@(private="file")
size_refusal_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    refusal:=(^Size_Refusal)(data)
    if (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) && size>0 && size==refusal.size {
        refusal.refused+=1
        return nil,.Out_Of_Memory
    }
    return refusal.owner.procedure(refusal.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// The tables of the protocol of a session, each without memory in turn: the
// session is refused and frees what it took, and with memory it is built.
// By the size of each table and not by request: std/serial does not survive
// every request refused (schema.odin). And a connection that arrives without
// memory for the inputs of its player: it is closed with a problem, and
// seated once there is memory.
@(test)
a_session_without_memory_is_refused_and_a_connection_without_room_is_closed :: proc(t:^testing.T) {
    info:=net_test_info();defer delete(info.tables);defer delete(info.storages)
    world:Net_Test_World
    net_test_init(&world,context.allocator)
    defer net_test_destroy(&world)
    ref:=core.world_ref(&world,&info)
    refusal:=Size_Refusal{owner=context.allocator}
    sizes:=[]int{len(info.tables)*size_of(wire.Fragment_Id),len(info.messages)*size_of(Net_Event),wire.TYPE_CAPACITY*size_of(Net_Type),0}
    for size in sizes {
        s:=Net_Session{allocator={size_refusal_proc,&refusal}}
        refusal.size,refusal.refused=size,0
        built:=protocol_build(&s,ref)
        whole:=built && len(s.fragments)==len(info.tables) && len(s.events)==len(info.messages) && s.types!=nil
        session_destroy(&s)
        testing.expectf(t,built==(refusal.refused==0) && whole==built,"with the requests of %d bytes refused (%d of them): built %v, whole %v",size,refusal.refused,built,whole)
        testing.expectf(t,(refusal.refused>0)==(size>0),"no request of %d bytes: the size of a table changed",size)
    }
    failure:=Rollback_Allocation{owner=context.allocator}
    limited:=runtime.Allocator{rollback_allocator,&failure}

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
}
