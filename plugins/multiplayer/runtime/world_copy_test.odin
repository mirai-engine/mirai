package multiplayer

import inp "mirai:engine/input"
import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import wire "mirai:net"

@(private) Rollback_Allocation :: struct {owner:runtime.Allocator,remaining:int,requests:int}
@(private)
rollback_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=cast(^Rollback_Allocation)data
    if size>0 && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {
        state.requests+=1
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
rollback_copy_failure_keeps_live_world_and_warm_publication_does_not_allocate :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    world:Net_Test_World;testing.expect(t,net_test_init(&world,&info));defer core.world_destroy(&info,.World,&world)
    entity:=net_test_body(&world,&info,1)
    shared:=Net_Test_Shared{info=&info};defer phys.collider_meshes_destroy(&shared.colliders)
    allocation:=Rollback_Allocation{owner=context.allocator,remaining=100000}
    app:=host.App{info=&info,allocator={rollback_allocator,&allocation},tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared,&app)
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=19,endpoints=2,packets=128})) {return}
    defer wire.sim_network_destroy(&network)
    session:Net_Session
    if !testing.expect(t,net_test_session(&session,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&session)
    shared.session=&session
    c:=&session.client
    c.any,c.newest=true,2
    frame:=&c.frames[2]
    world.time.tick=2
    testing.expect(t,core.world_copy(&info,frame.world,&world))
    frame.valid,frame.tick=true,2
    world.time.tick=3
    before,_:=core.get(&world.transforms,entity)
    values,transforms:=raw_data(world.values.values),raw_data(world.transforms.values)
    total:=world.force.total
    snapshot:=cast(^Net_Test_World)frame.world
    source_total:=snapshot.force.total
    allocation.remaining=0
    testing.expect(t,!client_rollback(&session,core.world_ref(&world,&info),&app,1))
    after,_:=core.get(&world.transforms,entity)
    testing.expect_value(t,after,before)
    testing.expect_value(t,world.force.total,total)
    testing.expect_value(t,raw_data(world.values.values),values)
    testing.expect_value(t,raw_data(world.transforms.values),transforms)
    testing.expect_value(t,snapshot.force.total,source_total)
    testing.expect(t,!world.time.resimulating && shared.session==&session && c.frames[2].world==snapshot)
    testing.expect_value(t,session.stats.corrected,u64(0))
    allocation.remaining=100000
    testing.expect(t,client_rollback(&session,core.world_ref(&world,&info),&app,1))
    testing.expect(t,client_rollback(&session,core.world_ref(&world,&info),&app,1))
    allocation.remaining=0
    requests:=allocation.requests
    saved:=context
    context.allocator,context.temp_allocator=mem.nil_allocator(),mem.nil_allocator()
    ok:=client_rollback(&session,core.world_ref(&world,&info),&app,1)
    context=saved
    testing.expect(t,ok)
    testing.expect_value(t,allocation.requests,requests)
    testing.expect_value(t,session.stats.corrected,u64(3))
    testing.expect(t,!world.time.resimulating && world.time.tick==3 && shared.session==&session)
}

@(private) Clock_Seen :: struct {time:core.Time,phase:core.Phase,content:u32}
@(private) Clock_Test_Shared :: struct {using net:Net_Test_Shared,seen:[dynamic]Clock_Seen}

@(private)
clock_test_fixed :: proc(world,shared,editor,application:rawptr) {
    w:=cast(^Net_Test_World)world
    seen:=Clock_Seen{w.time,w.frame.phase,host.content_generation(cast(^host.App)application)}
    append(&(cast(^Clock_Test_Shared)shared).seen,seen)
    net_test_fixed(world,shared,editor,application)
}

@(test)
a_rollback_replays_its_ticks_and_leaves_the_clock_and_the_frame_where_they_were :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    info.loops[.Game][.Fixed]=clock_test_fixed
    world:Net_Test_World;testing.expect(t,net_test_init(&world,&info));defer core.world_destroy(&info,.World,&world)
    net_test_body(&world,&info,1)
    shared:=Clock_Test_Shared{net={info=&info}};defer phys.collider_meshes_destroy(&shared.colliders);defer delete(shared.seen)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared.net,&app)
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=23,endpoints=2,packets=64})) {return}
    defer wire.sim_network_destroy(&network)
    session:Net_Session
    if !testing.expect(t,net_test_session(&session,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&session)
    shared.session=&session
    // Each tick ran in a frame that had loaded more content: the ticks run again see what they saw.
    content:host.Content
    app.content=&content
    world.time.tick=1
    for _ in 0..<4 {
        world.frame.phase=.Fixed
        content.generations=u32(world.time.tick)
        clock_test_fixed(&world,&shared,nil,&app)
        core.time_advance(&world.time)
    }
    content.generations=9
    world.frame={accumulator=0.01,dt=0.02,alpha=0.6,phase=.Input}
    time,frame:=world.time,world.frame
    clear(&shared.seen)
    testing.expect(t,client_rollback(&session,core.world_ref(&world,&info),&app,1))
    testing.expect_value(t,world.time,time)
    testing.expect_value(t,world.frame,frame)
    testing.expect_value(t,len(shared.seen),3)
    for seen,i in shared.seen {
        testing.expect(t,seen.time.resimulating && seen.time.tick==u64(2+i) && seen.phase==.Fixed)
        testing.expect_value(t,seen.content,u32(2+i))
    }
    testing.expect_value(t,host.content_generation(&app),u32(9))
    testing.expect_value(t,session.stats.resimulated,u64(3))
}

@(test)
a_tick_a_library_asks_to_go_back_to_runs_again_from_the_copy_it_started_from :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    info.loops[.Game][.Fixed]=clock_test_fixed
    world:Net_Test_World;testing.expect(t,net_test_init(&world,&info));defer core.world_destroy(&info,.World,&world)
    net_test_body(&world,&info,1)
    shared:=Clock_Test_Shared{net={info=&info}};defer phys.collider_meshes_destroy(&shared.colliders);defer delete(shared.seen)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared.net,&app)
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=29,endpoints=2,packets=64})) {return}
    defer wire.sim_network_destroy(&network)
    session:Net_Session
    if !testing.expect(t,net_test_session(&session,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&session)
    shared.session=&session
    world.time.tick=1
    for _ in 0..<6 {
        clock_test_fixed(&world,&shared,nil,&app)
        core.time_advance(&world.time)
    }
    time:=world.time
    clear(&shared.seen)
    client_reconcile(&session,core.world_ref(&world,&info),&app,1.0/60)
    rewinds:Net_Rewinds;defer delete(rewinds.queue.items)
    rewind(&rewinds,9)
    rewind(&rewinds,4)
    rewind(&rewinds,5)
    problems:core.Problems
    net_rewind(core.world_ref(&world,&info),&app,&session,&rewinds,&problems)
    testing.expect_value(t,len(rewinds.queue.items),0)
    testing.expect_value(t,session.stats.rewound,u64(1))
    testing.expect_value(t,world.time,time)
    testing.expect_value(t,len(shared.seen),3)
    for seen,i in shared.seen {testing.expect(t,seen.time.resimulating && seen.time.tick==u64(4+i))}
    clear(&shared.seen)
    rewind(&rewinds,7)
    net_rewind(core.world_ref(&world,&info),&app,&session,&rewinds,&problems)
    testing.expect_value(t,len(shared.seen),0)
    testing.expect_value(t,problems.count,0)
}

// Whether two worlds of the test hold the same rows, each added or not alike,
// and the same simulation. A copy of what changed keeps a stamp of its own
// for a row a rollback gave back its value.
@(private)
net_test_same :: proc(info:^core.World_Info,a,b:^Net_Test_World) -> bool {
    for &table in info.tables {
        x,y:=cast(^core.Raw_Table)(uintptr(a)+table.offset),cast(^core.Raw_Table)(uintptr(b)+table.offset)
        if x.on!=y.on || x.values.len!=y.values.len || !slice.equal(x.entities[:],y.entities[:]) || !slice.equal(x.off[:],y.off[:]) {return false}
        for stamp,row in x.stamps {if (stamp~y.stamps[row])&1==1 {return false}}
        size:=table.info.size*x.values.len
        if size>0 && mem.compare_ptrs(x.values.data,y.values.data,size)!=0 {return false}
    }
    return a.time==b.time && phys.state_hash(core.ref(&a.state))==phys.state_hash(core.ref(&b.state)) && slice.equal(a.entities.generation[:],b.entities.generation[:])
}

@(test)
history_copies_of_what_changed_equal_whole_copies_through_writes_layout_changes_and_corrections :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    world:Net_Test_World;testing.expect(t,net_test_init(&world,&info));defer core.world_destroy(&info,.World,&world)
    first:=net_test_body(&world,&info,1)
    second:=net_test_body(&world,&info,2,{1,0,0})
    shared:=Net_Test_Shared{info=&info};defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared,&app)
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=37,endpoints=2,packets=64})) {return}
    defer wire.sim_network_destroy(&network)
    session:Net_Session
    if !testing.expect(t,net_test_session(&session,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&session)
    shared.session=&session
    expected:Net_Test_World
    core.world_init(&info,.World,&expected,context.allocator)
    defer core.world_destroy(&info,.World,&expected)
    c:=&session.client
    for tick in 1..=48 {
        switch tick {
        case 9:  core.edit(&world.values,first).force=-3
        case 14: core.add(&world.move_inputs,second,inp.Move_Input{})
        case 20: core.remove(&world.values,second)
        case 27: core.add(&world.values,second,Net_Test_Value{force=2})
        }
        if tick==33 || tick==41 {
            client_reconcile(&session,core.world_ref(&world,&info),&app,1.0/60)
            testing.expect(t,client_rollback(&session,core.world_ref(&world,&info),&app,u32(tick-9)))
        }
        core.settle(&info,&world,nil)
        world.time.tick=u64(tick)
        testing.expect(t,core.world_copy(&info,&expected,&world))
        net_test_fixed(&world,&shared,nil,&app)
        frame:=&c.frames[tick%len(c.frames)]
        testing.expectf(t,frame.valid && frame.tick==u32(tick) && net_test_same(&info,cast(^Net_Test_World)frame.world,&expected),"the copy of tick %d is not the world as the tick found it",tick)
    }
    testing.expect_value(t,session.stats.corrected,u64(2))
}

@(private) Sync_Test_Shared :: struct {using net:Net_Test_Shared,body:core.Entity,calls:int,outside:bool}

// The fixed loop of the test; with outside, it pushes the body by how many times it ran, which is not in the World.
@(private)
sync_test_fixed :: proc(world,shared,editor,application:rawptr) {
    w:=cast(^Net_Test_World)world
    sh:=cast(^Sync_Test_Shared)shared
    sh.calls+=1
    if sh.outside {phys.apply_force(&w.requests,sh.body,{0,f32(sh.calls%5),0})}
    net_test_fixed(world,shared,editor,application)
}

// An interpolated replica without a body for an entity with a Transform.
@(private)
net_test_interpolated :: proc(s:^Net_Session,w:core.World_Ref,e:core.Entity) -> ^Replica {
    return net_test_replica(s,w,e,.Shown,.Server)
}

// The server says where the replica was at a tick.
@(private)
net_test_state :: proc(s:^Net_Session,r:^Replica,tick:u32,position:[3]f32) {
    r.tick=tick
    r.pose.position=position
    replica_sample(s,r,0)
}

// With late, an interpolated replica gets the states of its last ticks after they ran.
@(private)
sync_test_run :: proc(t:^testing.T,outside:bool,late:=false) -> (problems:core.Problems,body:core.Entity,moved:bool,skipped:u64) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    info.loops[.Game][.Fixed]=sync_test_fixed
    world:Net_Test_World;testing.expect(t,net_test_init(&world,&info));defer core.world_destroy(&info,.World,&world)
    body=net_test_body(&world,&info,1)
    net_test_body(&world,&info,2,{3,0,0})
    shared:=Sync_Test_Shared{net={info=&info},body=body,outside=outside};defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared.net,&app)
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=41,endpoints=2,packets=64})) {return}
    defer wire.sim_network_destroy(&network)
    session:Net_Session
    if !testing.expect(t,net_test_session(&session,&world,&info,&app,&network,1,.Client,settings={max_objects=8,predicted_capacity=8,replication={history_seconds=0.25},sync_test=4})) {return}
    defer session_destroy(&session)
    shared.session=&session
    session.problems=&problems
    ref:=core.world_ref(&world,&info)
    replica:^Replica
    if late {
        shown:=core.create(&world.entities)
        core.add(&world.transforms,shown,core.Transform{rotation=1,scale={1,1,1}})
        core.settle(&info,&world,nil)
        replica=net_test_interpolated(&session,ref,shown)
        for tick in u32(1)..=6 {net_test_state(&session,replica,tick,{f32(tick),0,0})}
    }
    for tick in 1..=8 {
        world.time.tick=u64(tick)
        sync_test_fixed(&world,&shared,nil,&app)
        core.time_advance(&world.time)
    }
    // Ticks 6, 7 and 8 showed the replica past its newest state; now the states of those ticks arrived.
    if late {
        for tick in u32(7)..=9 {net_test_state(&session,replica,tick,{f32(tick),5,0})}
    }
    before,_:=core.get(&world.transforms,body)
    time:=world.time
    client_sync_test(&session,ref,&app)
    after,_:=core.get(&world.transforms,body)
    testing.expect_value(t,session.stats.sync_tested,u64(4))
    testing.expect_value(t,world.time,time)
    moved,skipped=before!=after,session.stats.sync_skipped
    return
}

@(test)
sync_test_names_what_a_fixed_function_reading_outside_the_world_changes :: proc(t:^testing.T) {
    problems,body,moved,_:=sync_test_run(t,true)
    testing.expect(t,!moved)
    found:=core.problem_find(&problems,body,"net.sync_test")
    if !testing.expect(t,found!=nil,"the body is named") {return}
    testing.expectf(t,strings.contains(core.problem_text(found),"Transform"),"%s",core.problem_text(found))
    clean,_,clean_moved,clean_skipped:=sync_test_run(t,false)
    testing.expect(t,!clean_moved)
    testing.expect_value(t,clean.count,0)
    testing.expect_value(t,clean_skipped,u64(0))
}

// A state of the server that arrives after a tick ran changes what the
// network gives that tick when it runs again: SyncTest leaves the tick out,
// and still finds what a fixed function changes in the others.
@(test)
sync_test_leaves_out_the_ticks_that_states_arriving_late_change :: proc(t:^testing.T) {
    late,_,_,skipped:=sync_test_run(t,false,true)
    testing.expect_value(t,skipped,u64(3))
    testing.expectf(t,late.count==0,"a false difference: %s",late.count>0?core.problem_text(&late.entries[0]):"")
    outside,_,_,_:=sync_test_run(t,true,true)
    found:=core.problem_find(&outside,core.NONE,"net.sync_test")
    testing.expect(t,found!=nil,"a fixed function that reads outside the World is still found")
}

// A correction between the first time a tick ran and SyncTest runs it again
// from the world it corrected: SyncTest compares with what the correction left.
@(test)
sync_test_after_a_correction_compares_with_what_the_correction_left :: proc(t:^testing.T) {
    f:Correction_Fixture
    defer correction_fixture_destroy(&f)
    if !correction_fixture_init(t,&f,.Predicted,{max_objects=8,predicted_capacity=8,replication={history_seconds=0.5},sync_test=4}) {return}
    problems:core.Problems
    f.session.problems=&problems
    correction_fixture_state(&f,8,{0,0.1,0})
    client_reconcile(&f.session,core.world_ref(&f.world,&f.info),&f.app,1.0/60)
    testing.expect_value(t,f.session.stats.corrected,u64(1))
    client_sync_test(&f.session,core.world_ref(&f.world,&f.info),&f.app)
    testing.expect_value(t,f.session.stats.sync_tested,u64(4))
    testing.expect_value(t,f.session.stats.sync_skipped,u64(0))
    testing.expectf(t,problems.count==0,"a false difference: %s",problems.count>0?core.problem_text(&problems.entries[0]):"")
}

// A correction runs each tick again with the interpolated replicas as far
// behind the display as that tick showed them, not as far as they are now.
@(test)
a_rollback_places_interpolated_replicas_as_far_behind_as_each_tick_did :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer test_info_destroy(&info)
    world:Net_Test_World;testing.expect(t,net_test_init(&world,&info));defer core.world_destroy(&info,.World,&world)
    net_test_body(&world,&info,1)
    shown:=core.create(&world.entities)
    core.add(&world.transforms,shown,core.Transform{rotation=1,scale={1,1,1}})
    core.settle(&info,&world,nil)
    shared:=Net_Test_Shared{info=&info};defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared,&app)
    network:wire.Sim_Network
    if !testing.expect(t,wire.sim_network_init(&network,{seed=43,endpoints=2,packets=64})) {return}
    defer wire.sim_network_destroy(&network)
    session:Net_Session
    if !testing.expect(t,net_test_session(&session,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&session)
    shared.session=&session
    problems:core.Problems
    session.problems=&problems
    ref:=core.world_ref(&world,&info)
    r:=net_test_interpolated(&session,ref,shown)
    for tick in u32(1)..=20 {net_test_state(&session,r,tick,{f32(tick),0,0})}
    r.delay=0
    world.time.tick=1
    placed:[3]f32
    for _ in 1..=8 {
        net_test_fixed(&world,&shared,nil,&app)
        local,_:=core.get(&world.transforms,shown)
        placed=local.position
        core.time_advance(&world.time)
    }
    // Its states come further apart from now on: it is shown three ticks further back.
    r.delay=3
    testing.expect(t,client_rollback(&session,ref,&app,4))
    local,_:=core.get(&world.transforms,shown)
    testing.expectf(t,local.position==placed,"tick 8 ran again with the replica at %v, and the first time it was at %v",local.position,placed)
    testing.expect_value(t,problems.count,0)
}
