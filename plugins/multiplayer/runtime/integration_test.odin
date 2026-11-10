package multiplayer

import inp "mirai:engine/input"
import "base:runtime"
import "core:math/linalg"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:time"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:engine/render"
import "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"

@(component,replicated)
Net_Test_Value :: struct {force:f32,target:core.Entity}

// A component an entity gains after it is first replicated.
@(component,replicated)
Net_Test_Late :: struct {level:i32}

// The forces net_test_physics applied, added up.
@(private)
Net_Test_Force :: struct {total:f32}

// The tables and the storages of the test world of this package. A test
// world that adds its own holds them after its header.
@(private)
Net_Test_Tables :: struct {
    using physics:phys.Test_Physics,
    values:core.Table(Net_Test_Value),
    lates:core.Table(Net_Test_Late),
    identities:core.Table(core.Id),
    objects:core.Table(Replicate),
    links:core.Table(Net_Link),
    remotes:core.Table(core.Remote),
    offsets:core.Table(render.Draw_Offset),
    move_inputs:core.Table(inp.Move_Input),
    instances:core.Table(scene.Prefab_Instance),
    pendings:core.Table(scene.Prefab_Pending),
    drivables:core.Table(inp.Drivable),
    seats:core.Table(inp.Seat),
    absents:core.Table(Seat_Absent),
    visibility:core.Table(Visibility),
    spawns:core.Table(Predicted_Spawn),
    references:core.Table(scene.Scene_Reference),
    tombstones:core.Table(scene.Tombstone),
    held:core.Table(scene.Section_Held),
    time:core.Time,
    frame:core.Frame_Time,
    input:core.Input,
    bindings:inp.Input_Map,
    remote:Remote_Inputs,
    received:Net_Events,
    outbox:Net_Outbox,
    request:Session_Request,
    network:core.Network,
    places:core.Pose_Target_Places,
    root:scene.Scene_Root,
    scene_requests:scene.Scene_Requests,
    scene_results:scene.Scene_Results,
    connections:Net_Connections,
    clock:core.Clock,
    clock_requests:core.Clock_Requests,
    identity:Net_Identity,
    force:Net_Test_Force,
}

@(private)
Net_Test_World :: struct {
    using world:core.Test_World,
    using net:Net_Test_Tables,
}

// What the fixed loop of a test takes that its World does not hold.
@(private)
Net_Test_Shared :: struct {
    session:^Net_Session,
    info:^core.World_Info,
    colliders:phys.Collider_Meshes,
    spawn_at:u64, // the tick in which the game makes an entity on both ends (predict_spawn); 0: none
    sent:int,     // the messages it sent with them
}

@(private)
net_test_types :: proc(types:^[dynamic]core.Test_Type) {
    test_types(types)
    phys.test_types(types)
}

// The World_Info of Net_Test_World, with the fixed loop of these tests.
// follows: the messages of the session are in the protocol, as in a world
// the generator makes; the test deletes them.
@(private)
net_test_info :: proc(t:^testing.T,follows:=false,loc:=#caller_location) -> (info:core.World_Info,ok:bool) {
    info=core.test_info(t,Net_Test_World,net_test_types,context.allocator,loc) or_return
    if follows {
        info.messages=slice.clone([]core.Message_Info{
            {name="Net_World",library="multiplayer",type=Net_World,info=type_info_of(Net_World),from=.Server,reliable=true},
            {name="Net_World_Ready",library="multiplayer",type=Net_World_Ready,info=type_info_of(Net_World_Ready),from=.Client,reliable=true},
            {name="Net_Player",library="multiplayer",type=Net_Player,info=type_info_of(Net_Player),from=.Client,reliable=true},
            {name="Net_Section",library="multiplayer",type=Net_Section,info=type_info_of(Net_Section),from=.Client,reliable=true},
            {name="Net_Gone",library="multiplayer",type=Net_Gone,info=type_info_of(Net_Gone),from=.Server,reliable=true},
        })
    }
    info.loops[.Game][.Fixed]=net_test_fixed
    return info,true
}

@(private) NET_TEST_PUSH :: inp.Action(16)
@(private) NET_TEST_FIRE :: inp.Action(17)
@(private) NET_TEST_STEER :: inp.Action(18)

// A world of info as these tests start it: without gravity unless a test
// gives it one, with room for a few bodies and the actions a seat sends.
@(private)
net_test_init :: proc(w:^$W,info:^core.World_Info) -> bool {
    if !core.world_init(info,.World,w,context.allocator) {return false}
    core.add(&w.gravities,core.create(&w.entities),volume.Gravity{})
    core.settle(info,w,nil)
    w.settings={bodies=8,shapes=8,contacts=32,joints=8,characters=4,hulls=1,meshes=1,heightfields=1}
    w.time={dt=1.0/60,playing=true}
    inp.input_map_action(&w.bindings,NET_TEST_PUSH,.Axis)
    inp.input_map_bind(&w.bindings,NET_TEST_PUSH,inp.binding_key_axis(.Left,.Right))
    inp.input_map_action(&w.bindings,NET_TEST_FIRE,.Button)
    inp.input_map_bind(&w.bindings,NET_TEST_FIRE,inp.binding_gamepad_button(.South))
    inp.input_map_action(&w.bindings,NET_TEST_STEER,.Axis)
    inp.input_map_bind(&w.bindings,NET_TEST_STEER,inp.binding_gamepad_axis(.Left_X))
    return true
}

// The player at a client: the seat whose actions it sends.
@(private)
net_test_player :: proc(w:^Net_Test_World,info:^core.World_Info) -> core.Entity {
    seat:=core.create(&w.entities)
    core.add(&w.seats,seat,inp.Seat{})
    core.settle(info,w,nil)
    return seat
}

// The seats of this machine take their actions from the devices of the tick, as input_seats does.
@(private)
net_test_feed :: proc(w:^Net_Test_World) {
    for row in 0..<core.count(&w.seats) {
        if !inp.seat_local(w.seats.values[row]) {continue}
        device:=w.input
        inp.seat_feed(core.edit_at(&w.seats,row),&device,&w.bindings,false,1.0/60)
    }
}

// The value an axis action had in what a connection sent.
@(private)
net_test_axis :: proc(sent:inp.Remote_Actions,a:inp.Action) -> f32 {
    sent:=sent
    for axis in sent.axes[:min(int(sent.axis_count),inp.REMOTE_AXES)] {
        if axis.action==a {return axis.value.x}
    }
    return 0
}

// What the fixed loop runs of physics: the places of the replicas, then the step.
@(private)
net_test_physics :: proc(w:^$W,shared:^Net_Test_Shared,app:^host.App) {
    // It takes every storage to write: as the call of a loop function does before it runs.
    core.revisions_moved(w.storage_revisions[:])
    phys.physics_pose_targets(&w.state,core.read(&w.replicas),&w.transforms,core.read(&w.parents),core.read(&w.rigids),core.read(&w.characters))
    core.settle(shared.info,w,nil)
    core.pose_targets_place(core.read(&w.replicas),&w.transforms,&w.places)
    core.settle(shared.info,w,nil)
    for value,index in w.values.values {
        w.force.total+=value.force
        phys.apply_force(&w.requests,w.values.entities[index],{value.force,0,0})
    }
    // Its characters have no Character_Move: they stand where they are.
    phys.physics_step(&w.state,core.ref(&w.settings),&w.requests,&w.events,&shared.colliders,app,w.time,
        core.read(&w.rigids),core.read(&w.colliders),core.read(&w.characters),core.read(&w.moves),&w.joints,
        core.read(&w.statics),core.read(&w.parents),core.read(&w.names),&w.transforms,&w.bodies,core.read(&w.replicas),
        &w.character_states,&w.joint_states,{},nil,{},core.ref(&w.sync_check),&w.simulation_hash,nil,nil,
        core.read(&w.gravities),core.read(&w.volumes),core.read(&w.worlds),{},{},core.ref(&w.hierarchy))
    core.settle(shared.info,w,nil)
}

@(private)
net_test_fixed :: proc(world,shared,editor,application:rawptr) {
    w:=cast(^Net_Test_World)world
    sh:=cast(^Net_Test_Shared)shared
    app:=cast(^host.App)application
    ref:=core.world_ref(w,sh.info)
    core.revisions_moved(w.storage_revisions[:])
    if sh.session!=nil {
        net_tick_head(ref,app,sh.session,&w.remote,nil,nil,sh.session.problems)
        core.settle(sh.info,w,nil)
    }
    net_test_feed(w)
    if sh.spawn_at!=0 && w.time.tick==sh.spawn_at {
        e:=core.create(&w.entities)
        core.add(&w.transforms,e,core.Transform{position={0,5,0},rotation=1,scale={1,1,1}})
        core.add(&w.values,e,Net_Test_Value{})
        predict_spawn(core.ref(sh.session),&w.identities,&w.spawns,e,0,w.time)
        sh.sent+=int(send(&w.outbox,u32(1)))
        core.settle(sh.info,w,nil)
    }
    net_test_physics(w,sh,app)
    if sh.session!=nil {
        outbox:Net_Outbox
        adoptions:Net_Adoptions
        net_tick_tail(ref,sh.session,&outbox,&adoptions,sh.session.problems)
        core.value_free(&outbox,type_info_of(Net_Outbox))
        core.value_free(&adoptions,type_info_of(Net_Adoptions))
    }
}

@(private)
net_test_body :: proc(w:^Net_Test_World,info:^core.World_Info,id:base.Entity_Id,position:[3]f32={}) -> core.Entity {
    e:=core.create(&w.entities)
    core.add(&w.identities,e,core.Id{id})
    core.add(&w.transforms,e,core.Transform{position=position,rotation=1,scale={1,1,1}})
    core.add(&w.rigids,e,phys.Rigid_Body{type=.Dynamic,mass=1})
    core.add(&w.colliders,e,phys.collider_box({0.1,0.1,0.1}))
    core.add(&w.values,e,Net_Test_Value{force=1})
    core.settle(info,w,nil)
    return e
}

@(private)
net_test_replicate :: proc(audience:=Audience.Near,simulation:=Simulation.Server,update_hz:f32=0,radius:f32=1,priority:f32=1) -> Replicate {
    return {simulation=simulation,audience=audience,priority=priority,update_hz=update_hz,radius=radius}
}

// The seat of a connection drives e: the connection owns it. Settled by the caller.
@(private)
net_test_own :: proc(w:^Net_Test_World,e:core.Entity,connection:Connection) {
    seat:=core.create(&w.entities)
    core.add(&w.seats,seat,inp.Seat{peer=u64(connection)})
    core.add(&w.drivables,e,inp.Drivable{seat=seat})
}

@(private)
net_test_session :: proc(s:^Net_Session,w:rawptr,info:^core.World_Info,app:^host.App,network:^wire.Sim_Network,endpoint:int,mode:wire.Mode,transport:wire.Transport={},settings:=Net_Settings{max_objects=8,predicted_capacity=8,replication={history_seconds=0.25},resimulate_budget=600}) -> bool {
    s.allocator,s.info=context.allocator,info
    tick_dt:=app.tick_dt>0?app.tick_dt:1.0/60
    s.desc=settings_resolve(settings,tick_dt)
    if !protocol_build(s,core.world_ref(w,info)) {return false}
    exchange:=transport
    if exchange.send==nil {exchange=wire.sim_endpoint_transport(network,endpoint)}
    desc:=wire.Host_Desc{mode=mode,protocol=&s.protocol,transport=exchange,protocol_id=99,seed=u64(endpoint+1),tick_rate=int(1/tick_dt+0.5),replication=s.desc.replication,hold=s.follows,allocator=context.allocator}
    desc.replication.max_objects=s.desc.max_objects
    if wire.host_init(&s.host,desc)!=.None {return false}
    s.host_ready,s.mode=true,mode
    ready:=mode==.Client?client_init(s,core.world_ref(w,info),app.allocator):server_init(s,context.allocator)
    world_seen(s,core.world_ref(w,info))
    return ready
}

// What arrived at a session since the last call, as the next tick would take it.
@(private)
net_test_arrived :: proc(s:^Net_Session) -> []Connection_Event {
    events:=slice.clone(s.arrived[:],context.temp_allocator)
    clear(&s.arrived)
    return events
}

// The type of the protocol an entity replicates as with what it has now.
@(private)
net_test_type :: proc(s:^Net_Session,w:core.World_Ref,e:core.Entity) -> wire.Type_Id {
    kinds:[wire.MAX_FRAGMENTS]wire.Fragment_Id
    count,_:=entity_kinds(s,w,e,&kinds)
    type,_:=wire.type_compose(&s.protocol,kinds[:count])
    return type
}

// The fragment of a type that carries a component; -1 without one.
@(private)
net_test_fragment :: proc(s:^Net_Session,type:wire.Type_Id,component:typeid) -> int {
    t:=net_type(s,type)
    for k in 0..<t.count {
        if s.info.tables[t.tables[k]].type==component {return t.first+k}
    }
    return -1
}

// A replica of object 1 for an entity of the world, of the type and at the pose
// it has now, as the client classifies it.
@(private)
net_test_replica :: proc(s:^Net_Session,w:core.World_Ref,e:core.Entity,role:Role,simulation:Simulation) -> ^Replica {
    r:=&s.client.replicas[1]
    local,_:=core.get(core.read(core.world_table_of(w,core.Transform)),e)
    r^={object=1,entity=e,type=net_test_type(s,w,e),role=role,simulation=simulation,slot=-1,samples=-1}
    r.pose={id=core.id_of(core.read(core.world_table_of(w,core.Id)),e),position=local.position,rotation=local.rotation,scale=local.scale}
    r.motion,_=motion_read(w,e)
    wire.smoothing_init(&r.smoothing)
    s.client.replica_high=max(s.client.replica_high,2)
    core.add(core.world_table_of(w,Net_Link),e,Net_Link{object=1})
    core.world_settle(w)
    replica_classify(s,w,r)
    core.world_settle(w)
    return r
}

// The state of a replica as a server sends it at tick: pose and motion, an
// empty driver, Net_Test_Value with force and every other component as w has it.
@(private)
net_test_pack :: proc(s:^Net_Session,w:^Net_Test_World,r:^Replica,tick:u32,pose:Pose,motion:Motion_State,force:f32,words:[]u32) -> wire.Command {
    ref:=core.world_ref(w,s.info)
    t:=net_type(s,r.type)
    pose,motion:=pose,motion
    wire.object_pack(&s.host,t.type,0,&pose,words)
    if t.motion>=0 {wire.object_pack(&s.host,t.type,t.motion,&motion,words)}
    if t.driver>=0 {
        driver:Driver_State
        wire.object_pack(&s.host,t.type,t.driver,&driver,words)
    }
    for k in 0..<t.count {
        info:=&s.info.tables[t.tables[k]]
        value:=s.scratch[:info.info.size]
        mem.zero_slice(value)
        if info.type==Net_Test_Value {
            (^Net_Test_Value)(raw_data(value)).force=force
        } else if row:=core.raw_find(core.world_table_at(ref,info),info.info,r.entity);row!=nil {
            mem.copy(raw_data(value),row,info.info.size)
        }
        wire.object_pack(&s.host,t.type,t.first+k,raw_data(value),words)
    }
    return {kind=.Object_Updated,type=t.type,object=r.object,tick=tick,mask=s.protocol.types[t.type].all,words=words}
}

// The state of a replica as w has its entity.
@(private)
net_test_command :: proc(s:^Net_Session,w:^Net_Test_World,r:^Replica,tick:u32,force:f32,words:[]u32) -> wire.Command {
    local,_:=core.get(&w.transforms,r.entity)
    pose:=Pose{id=core.id_of(core.read(&w.identities),r.entity),position=local.position,rotation=local.rotation,scale=local.scale}
    motion,_:=motion_read(core.world_ref(w,s.info),r.entity)
    return net_test_pack(s,w,r,tick,pose,motion,force,words)
}

@(test)
authoritative_components_replay_at_their_ticks_with_real_physics :: proc(t:^testing.T) {
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
    testing.expect(t,wire.sim_network_init(&network,{seed=77,endpoints=2,packets=128}))
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&s)
    shared.session=&s
    r:=net_test_replica(&s,core.world_ref(&world,&info),e,.Predicted,.Server)
    for tick in 1..<6 {
        world.time.tick=u64(tick)
        net_test_fixed(&world,&shared,nil,&app)
    }
    first:=cast(^Net_Test_World)s.client.frames[2].world
    third:=cast(^Net_Test_World)s.client.frames[4].world
    expected:Net_Test_World
    core.world_init(&info,.World,&expected,context.allocator)
    core.world_copy(&info,&expected,first)
    defer core.world_destroy(&info,.World,&expected)
    expected.values.values[0].force=4
    reference_shared:=Net_Test_Shared{info=&info}
    defer phys.collider_meshes_destroy(&reference_shared.colliders)
    for tick in 2..<6 {
        expected.time.tick=u64(tick)
        net_test_physics(&expected,&reference_shared,&app)
        if tick==3 {
            expected.values.values[0].force=7
            local,_:=core.get(&third.transforms,e)
            motion,_:=core.get(&third.bodies,e)
            core.push(&expected.requests.queue,phys.Body_Request{entity=e,kind=.Teleport,position=local.position,rotation=local.rotation})
            phys.set_velocity(&expected.requests,e,motion.linear,motion.angular)
        }
    }
    words:=make([]u32,s.client.words_per)
    defer delete(words)
    one:=net_test_command(&s,first,r,1,4,words)
    replica_update(&s,core.world_ref(&world,&info),app.assets,&one)
    three:=net_test_command(&s,third,r,3,7,words)
    replica_update(&s,core.world_ref(&world,&info),app.assets,&three)
    client_reconcile(&s,core.world_ref(&world,&info),&app,1.0/60)
    testing.expect_value(t,s.stats.corrected,u64(1))
    testing.expect_value(t,world.values.values[0].force,f32(7))
    testing.expect_value(t,world.force.total,expected.force.total)
    got,_:=core.get(&world.transforms,e)
    wanted,_:=core.get(&expected.transforms,e)
    testing.expectf(t,linalg.length(got.position-wanted.position)<0.002,"position %v expected %v",got.position,wanted.position)
    before:=got.position
    client_reconcile(&s,core.world_ref(&world,&info),&app,1.0/60)
    got,_=core.get(&world.transforms,e)
    testing.expect_value(t,got.position,before)
}

@(test)
predicted_transforms_compare_rotation_scale_and_quantized_components :: proc(t:^testing.T) {
    settings:=settings_resolve({},1.0/60)
    record:=Record{rotation=1,scale={1,1,1}}
    pose:=Pose{rotation=1,scale={1,1,1}}
    motion:Motion_State
    testing.expect(t,!record_differs(&settings,false,&record,&pose,&motion))
    pose.rotation=quaternion(w=0,x=1,y=0,z=0)
    testing.expect(t,record_differs(&settings,false,&record,&pose,&motion))
    pose.rotation=1
    pose.scale={2,1,1}
    testing.expect(t,record_differs(&settings,false,&record,&pose,&motion))
}

// A component that names an entity this end has no object for is off the
// replica until the object is bound, and leaves it again when that object ends.
@(test)
component_references_resolve_after_binding_and_clear_after_destruction :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    source:=net_test_body(&world,&info,1)
    target:=net_test_body(&world,&info,2,{1,0,0})
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=2,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,0,.Server)) {return}
    defer session_destroy(&s)
    if !testing.expect(t,client_init(&s,core.world_ref(&world,&info),app.allocator)) {return}
    type:=net_test_type(&s,core.world_ref(&world,&info),source)
    target_object,error:=wire.object_create(&s.host,{type=type})
    if !testing.expect_value(t,error,wire.Error.None) {return}
    source_object,created:=wire.object_create(&s.host,{type=type,user=u64(source)})
    if !testing.expect_value(t,created,wire.Error.None) {return}
    words:=make([]u32,s.client.words_per)
    defer delete(words)
    replica:=Replica{object=source_object,entity=source,type=type}
    command:=net_test_command(&s,&world,&replica,1,3,words)
    command.kind=.Object_Created
    command.role=.Predicted
    command.simulation=.Server
    fragment:=net_test_fragment(&s,type,Net_Test_Value)
    for leaf in s.protocol.types[type].leaves {
        if int(leaf.fragment)==fragment && leaf.kind==.Object {
            words[leaf.word]=u32(u64(target_object))
            words[leaf.word+1]=u32(u64(target_object)>>32)
        }
    }
    replica_create(&s,core.world_ref(&world,&info),app.assets,&command)
    core.settle(&info,&world,nil)
    testing.expect(t,!core.has(&world.values,source),"it waits for its target off the replica")
    testing.expect_value(t,wire.object_bind(&s.host,target_object,u64(target)),wire.Error.None)
    references_refresh(&s,core.world_ref(&world,&info))
    core.settle(&info,&world,nil)
    resolved,found:=core.get(&world.values,source)
    testing.expect(t,found && resolved.target==target && resolved.force==3)
    testing.expect(t,s.stats.references_resolved>0)
    testing.expect_value(t,wire.object_destroy(&s.host,target_object),wire.Error.None)
    references_refresh(&s,core.world_ref(&world,&info))
    core.settle(&info,&world,nil)
    testing.expect(t,!core.has(&world.values,source),"it leaves with its target")
}

@(test)
server_publishes_only_changed_rows_at_the_objects_frequency :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    first:=net_test_body(&world,&info,1)
    second:=net_test_body(&world,&info,2,{1,0,0})
    core.add(&world.objects,first,net_test_replicate(audience=.Always))
    core.add(&world.objects,second,net_test_replicate(audience=.Always))
    core.settle(&info,&world,nil)
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=3,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,0,.Server)) {return}
    defer session_destroy(&s)
    outbox:Net_Outbox
    defer core.value_free(&outbox,type_info_of(Net_Outbox))
    for tick in 1..<4 {
        server_publish(&s,core.world_ref(&world,&info),&outbox,u32(tick))
        core.settle(&info,&world,nil)
    }
    before:=s.stats.fragments_published
    core.edit(&world.values,first).force=9
    server_publish(&s,core.world_ref(&world,&info),&outbox,4)
    testing.expect_value(t,s.stats.fragments_published-before,u64(1))
    // Ten times a second at 60 ticks: on its turn, once every six ticks, whatever changed between turns.
    core.edit(&world.objects,first).update_hz=10
    before=s.stats.fragments_published
    for tick in 5..<17 {
        core.edit(&world.values,first).force=f32(tick)
        server_publish(&s,core.world_ref(&world,&info),&outbox,u32(tick))
    }
    testing.expect_value(t,s.stats.fragments_published-before,u64(2))
    testing.expect_value(t,wire.object_poll_interval(&s.host,wire.object_of_user(&s.host,u64(first))),6)
}

@(test)
physical_joints_inputs_and_components_converge_on_a_damaged_network :: proc(t:^testing.T) {
    net_test_physical_convergence(t,false)
}

@(test)
authoritative_physics_joints_and_inputs_converge_over_real_udp_localhost :: proc(t:^testing.T) {
    net_test_physical_convergence(t,true)
}

// The server replicates both bodies to the client that connected, the first
// one owned by it, with a joint that is off until the server turns it on.
@(private)
net_test_physical_objects :: proc(w:^Net_Test_World,info:^core.World_Info,entities:[2]core.Entity,connected:Connection) {
    core.add(&w.objects,entities[0],net_test_replicate(audience=.Always))
    net_test_own(w,entities[0],connected)
    core.add(&w.objects,entities[1],net_test_replicate(audience=.Always))
    joint:=phys.joint_fixed(entities[1])
    joint.break_force=10
    core.add(&w.joints,entities[0],joint)
    core.add(&w.joint_states,entities[0],phys.Joint_State{})
    core.disable(&w.joints,entities[0])
    core.settle(info,w,nil)
    core.edit(&w.values,entities[0]).target=entities[1]
}

@(private)
net_test_physical_convergence :: proc(t:^testing.T,udp:bool) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    entities:[2][2]core.Entity
    for &world,index in worlds {
        net_test_init(&world,&info)
        entities[index][0]=net_test_body(&world,&info,1)
        entities[index][1]=net_test_body(&world,&info,2,{1,0,0})
        shares[index].info=&info
        apps[index]={info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
        net_test_physics(&world,&shares[index],&apps[index])
        core.edit(&world.values,entities[index][0]).force=0
        core.edit(&world.values,entities[index][1]).force=0
    }
    net_test_player(&worlds[1],&info)
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    defer for &app in apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    defer for &share in shares {phys.collider_meshes_destroy(&share.colliders)}
    network:wire.Sim_Network
    sockets:[2]wire.Udp
    defer for &socket in sockets {wire.udp_close(&socket)}
    if udp {
        for &socket in sockets {
            if !testing.expect(t,wire.udp_open(&socket,wire.address_loopback(0)),"cannot bind the physics UDP fixture on localhost") {return}
        }
    } else {
        if !testing.expect(t,wire.sim_network_init(&network,{seed=543,endpoints=2,packets=1024})) {return}
    }
    defer if !udp {wire.sim_network_destroy(&network)}
    for &session,index in sessions {
        exchange:wire.Transport
        if udp {exchange=wire.udp_transport(&sockets[index])}
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client,exchange)) {return}
        shares[index].session=&session
    }
    defer for &session in sessions {session_destroy(&session)}
    problems:[2]core.Problems
    sessions[0].problems,sessions[1].problems=&problems[0],&problems[1]
    endpoint:=udp?sockets[0].address:wire.address_memory(0)
    testing.expect_value(t,wire.host_connect(&sessions[1].host,endpoint),wire.Error.None)
    if !udp {for index in 0..<2 {wire.sim_endpoint_conditions(&network,index,{latency=0.06,jitter=0.015,loss=0.2,duplicate=0.1,reorder=0.1,reorder_delay=0.04})}}
    outbox:Net_Outbox
    defer core.value_free(&outbox,type_info_of(Net_Outbox))
    connected:Connection
    time_base:f64
    if udp {
        start:=time.tick_now()
        for time.duration_seconds(time.tick_since(start))<2 {
            now:=wire.host_time(&sessions[0].host)
            for &session in sessions {wire.host_update(&session.host,now)}
            server_events,client_events:Net_Events
            server_commands(&sessions[0],core.world_ref(&worlds[0],&info),nil,wire.host_poll(&sessions[0].host),&worlds[0].remote)
            client_commands(&sessions[1],core.world_ref(&worlds[1],&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host))
            for event in net_test_arrived(&sessions[0]) {if event.kind==.Connected {connected=event.connection}}
            core.value_free(&server_events,type_info_of(Net_Events));core.value_free(&client_events,type_info_of(Net_Events))
            if connected!=0 && sessions[1].status==.Connected {break}
            time.sleep(time.Millisecond)
        }
        if !testing.expect(t,connected!=0 && sessions[1].status==.Connected,"UDP physics handshake did not complete within two seconds") {return}
        net_test_physical_objects(&worlds[0],&info,entities[0],connected)
        time_base=wire.host_time(&sessions[0].host)
        fmt.printf("UDP physics endpoints: server 127.0.0.1:%d, client 127.0.0.1:%d; 599 ticks at 60 Hz, client lead 8 ticks\n",sockets[0].address.port,sockets[1].address.port)
    }
    saw_break,saw_joint:bool
    for tick in 1..<600 {
        now:=time_base+f64(tick)/60
        if !udp {wire.sim_network_advance(&network,now)}
        for &session in sessions {wire.host_update(&session.host,now)}
        server_events,client_events:Net_Events
        server_commands(&sessions[0],core.world_ref(&worlds[0],&info),nil,wire.host_poll(&sessions[0].host),&worlds[0].remote)
        for event in net_test_arrived(&sessions[0]) {
            if event.kind==.Connected {
                connected=event.connection
                net_test_physical_objects(&worlds[0],&info,entities[0],connected)
            }
        }
        client_commands(&sessions[1],core.world_ref(&worlds[1],&info),apps[1].assets,apps[1].allocator,wire.host_poll(&sessions[1].host))
        client_reconcile(&sessions[1],core.world_ref(&worlds[1],&info),&apps[1],1.0/60)
        core.value_free(&server_events,type_info_of(Net_Events))
        core.value_free(&client_events,type_info_of(Net_Events))
        if tick==60 {core.enable(&worlds[0].joints,entities[0][0])}
        if tick==90 {core.edit(&worlds[0].values,entities[0][0]).force=400}
        if tick==140 {
            core.edit(&worlds[0].values,entities[0][0]).force=0
            joint:=phys.joint_prismatic(entities[0][1])
            joint.motor,joint.motor_speed,joint.max_motor=true,1,100
            core.add(&worlds[0].joints,entities[0][0],joint)
            core.add(&worlds[0].joint_states,entities[0][0],phys.Joint_State{})
        }
        if tick==200 {core.edit(&worlds[0].joints,entities[0][0]).motor_speed=-1}
        if tick==260 {core.disable(&worlds[0].joints,entities[0][0])}
        // Components the entities gain and lose long after they were first replicated.
        if tick==320 {for e in entities[0] {core.add(&worlds[0].lates,e,Net_Test_Late{level=7})}}
        if tick==400 {core.edit(&worlds[0].lates,entities[0][1]).level=9}
        if tick==480 {core.remove(&worlds[0].lates,entities[0][0])}
        worlds[1].input.gamepads[0]={connected=true,down={.South},axes={.Left_X=0.75,.Left_Y=0,.Right_X=0,.Right_Y=0,.Left_Trigger=0,.Right_Trigger=0}}
        for &world,index in worlds {
            core.settle(&info,&world,nil)
            world.time.tick=u64(tick+(index==1?8:0))
            net_test_fixed(&world,&shares[index],nil,&apps[index])
        }
        if state,has:=core.get(&worlds[1].joint_states,entities[1][0]);has && state.broken {saw_break=true}
        if core.has(&worlds[1].joints,entities[1][0]) {saw_joint=true}
        if tick==300 {
            for e in entities[0] {phys.set_velocity(&worlds[0].requests,e,{},{})}
        }
        for &session in sessions {wire.host_update(&session.host,now)}
    }
    testing.expect(t,connected!=0 && sessions[1].status==.Connected)
    testing.expect(t,saw_joint && saw_break)
    testing.expect(t,!core.has(&worlds[1].joints,entities[1][0]))
    client_value,_:=core.get(&worlds[1].values,entities[1][0])
    testing.expect_value(t,client_value.target,entities[1][1])
    testing.expect_value(t,client_value.force,f32(0))
    remote,status:=remote_input(core.ref(&worlds[0].remote),connected)
    testing.expect(t,status!=.None && remote.down&inp.action_bit(NET_TEST_FIRE)!=0)
    // The axis as the client's seat took it, past its dead zone.
    steer:=inp.seat_action(core.read(&worlds[1].seats),inp.local_seat(core.read(&worlds[1].seats),0),NET_TEST_STEER).value
    testing.expectf(t,steer>0.5 && abs(net_test_axis(remote,NET_TEST_STEER)-steer)<0.001,"steer %v at the client, %v at the server",steer,net_test_axis(remote,NET_TEST_STEER))
    // The input says what tick of the server the client showed, near the one
    // simulated. This fixture moves the client's tick by hand, not with its
    // clock, so how far behind is measured by the game, not here.
    entry:=remote_entry(&worlds[0].remote,connected)
    testing.expectf(t,entry!=nil && entry.view>0 && abs(f64(entry.tick)-entry.view)<60,"view %v at tick %v",entry.view if entry!=nil else 0,entry.tick if entry!=nil else 0)
    for index in 0..<2 {
        server_pose,_:=core.get(&worlds[0].transforms,entities[0][index])
        client_pose,_:=core.get(&worlds[1].transforms,entities[1][index])
        testing.expectf(t,linalg.length(server_pose.position-client_pose.position)<0.02,"body %d server %v client %v",index,server_pose.position,client_pose.position)
    }
    late,has_late:=core.get(core.read(&worlds[1].lates),entities[1][1])
    testing.expectf(t,has_late && late.level==9 && !core.has(&worlds[1].lates,entities[1][0]),"the client has the late component of the second body %v at level %d, and that of the first %v",has_late,late.level,core.has(&worlds[1].lates,entities[1][0]))
    testing.expect_value(t,sessions[0].stats.retyped,u64(3))
    testing.expect_value(t,sessions[1].stats.spawned,u64(2))
    testing.expect(t,sessions[1].stats.corrected>0)
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
    if udp {
        server_stats,client_stats:=wire.host_stats(&sessions[0].host),wire.host_stats(&sessions[1].host)
        testing.expect(t,server_stats.packets_sent>0 && server_stats.packets_received>0 && client_stats.packets_sent>0 && client_stats.packets_received>0)
        link,_:=core.get(&worlds[1].links,entities[1][0])
        r:=replica_of(&sessions[1],link.object)
        testing.expect(t,r!=nil && r.role==.Predicted && r.mode==.Predicted)
        object:=wire.object_of_user(&sessions[0].host,u64(entities[0][0]))
        testing.expect(t,object!=0 && sessions[0].server.objects[object_index(object)].holder==0)
        fmt.printf("UDP physics result: server packets sent/received %d/%d, client %d/%d, corrections %d, physics/net failures 0\n",server_stats.packets_sent,server_stats.packets_received,client_stats.packets_sent,client_stats.packets_received,sessions[1].stats.corrected)
    }
}

@(test)
remote_character_intent_is_replayed_from_its_authoritative_tick :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    e:=net_test_body(&world,&info,1)
    core.remove(&world.rigids,e)
    core.add(&world.colliders,e,phys.collider_character())
    core.add(&world.characters,e,phys.character_default())
    core.add(&world.move_inputs,e,inp.Move_Input{})
    core.settle(&info,&world,nil)
    shared:=Net_Test_Shared{info=&info}
    defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared,&app)
    _,made:=phys.body_info(core.ref(&world.state),phys.body_of(core.ref(&world.state),e))
    testing.expect(t,made)
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=6,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&s)
    r:=net_test_replica(&s,core.world_ref(&world,&info),e,.Shown,.Server)
    // Predicted, as while it is within reach of what this client drives.
    r.pose.predict=true
    replica_classify(&s,core.world_ref(&world,&info),r)
    driver_fragment:=net_type(&s,r.type).driver
    if !testing.expect(t,driver_fragment>=0,"a Move_Input replicates its driver") {return}
    words:=make([]u32,s.client.words_per)
    defer delete(words)
    one:=net_test_command(&s,&world,r,1,0,words)
    driver:=Driver_State{has_move=true,move=inp.Move_Input{move={1,0,0}}}
    wire.object_pack(&s.host,r.type,driver_fragment,&driver,words)
    replica_update(&s,core.world_ref(&world,&info),app.assets,&one)
    three:=net_test_command(&s,&world,r,3,0,words)
    driver.move=inp.Move_Input{move={-1,0,0},look_yaw=0.25}
    wire.object_pack(&s.host,r.type,driver_fragment,&driver,words)
    replica_update(&s,core.world_ref(&world,&info),app.assets,&three)
    for tick in 1..<4 {
        client_inputs(&s,core.world_ref(&world,&info),u32(tick))
        move,_:=core.get(&world.move_inputs,e)
        testing.expect_value(t,move.move.x,tick<3?f32(1):f32(-1))
        _,status:=remote_input(core.ref(&world.remote),55)
        testing.expect(t,status==.None,"the actions of another player never reach a client")
        world.time.tick=u64(tick)
        net_test_physics(&world,&shared,&app)
    }
}

// What a client drives has no small limit of islands: a replica joined to any
// of two dozen of its bodies shares an island with what it drives, and is
// critical; one alone is not.
@(test)
replicas_joined_to_any_of_many_driven_bodies_are_critical :: proc(t:^testing.T) {
    PAIRS :: 24
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    world.settings.bodies,world.settings.shapes,world.settings.joints=64,64,32
    driven,joined:[PAIRS]core.Entity
    // The bodies of a client are replicas: the simulation groups them for the network.
    body :: proc(w:^Net_Test_World,info:^core.World_Info,id:base.Entity_Id,position:[3]f32) -> core.Entity {
        e:=net_test_body(w,info,id,position)
        core.add(&w.replicas,e,core.Pose_Target{position=position,rotation=1,scale={1,1,1}})
        return e
    }
    for k in 0..<PAIRS {
        driven[k]=body(&world,&info,base.Entity_Id(2*k+1),{f32(k)*4,0,0})
        joined[k]=body(&world,&info,base.Entity_Id(2*k+2),{f32(k)*4,0,1})
        core.add(&world.joints,joined[k],phys.joint_fixed(driven[k]))
    }
    alone:=body(&world,&info,base.Entity_Id(2*PAIRS+1),{0,0,10})
    core.settle(&info,&world,nil)
    shared:=Net_Test_Shared{info=&info}
    defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    // A body gets its core.Motion when it is made, and its group with the next step.
    for _ in 0..<2 {net_test_physics(&world,&shared,&app)}
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=9,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,1,.Client,settings={max_objects=64,predicted_capacity=8,replication={history_seconds=0.25}})) {return}
    defer session_destroy(&s)
    c:=&s.client
    ref:=core.world_ref(&world,&info)
    replica :: proc(s:^Net_Session,w:core.World_Ref,index:int,e:core.Entity,role:Role) {
        s.client.replicas[index]={object=Object(index),entity=e,role=role,type=net_test_type(s,w,e),slot=-1,samples=-1}
    }
    for k in 0..<PAIRS {
        a,_:=core.get(&world.bodies,driven[k])
        b,_:=core.get(&world.bodies,joined[k])
        testing.expectf(t,a.island!=0 && a.island==b.island,"pair %d: islands %d and %d",k,a.island,b.island)
        replica(&s,ref,1+k,driven[k],.Predicted)
        replica(&s,ref,1+PAIRS+k,joined[k],.Shown)
    }
    replica(&s,ref,1+2*PAIRS,alone,.Shown)
    c.replica_high=2+2*PAIRS
    driven_list(c)
    records_capture(&s,ref,1)
    c.newest,c.any=1,true
    for k in 0..<PAIRS {testing.expectf(t,replica_wanted(&s,&c.replicas[1+PAIRS+k])==.Predicted,"the replica joined to body %d is not predicted",k)}
    testing.expect_value(t,replica_wanted(&s,&c.replicas[1+2*PAIRS]),Mode.Interpolated)
    // And it is interpolated again once it has been out of reach for critical_ticks.
    c.newest=1+u32(s.desc.critical_ticks)
    testing.expect_value(t,replica_wanted(&s,&c.replicas[1+PAIRS]),Mode.Predicted)
    c.newest+=1
    testing.expect_value(t,replica_wanted(&s,&c.replicas[1+PAIRS]),Mode.Interpolated)
}

// The child hangs from parent in the hierarchy: a root while parent does not
// replicate, seen with parent once it does, a root again when parent is
// destroyed, and seen with the replacement it is moved under.
@(test)
object_scope_controls_relevance_radius_and_follows_the_replicated_ancestor :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    worlds:[2]Net_Test_World
    apps:[2]host.App
    sessions:[2]Net_Session
    for &world,index in worlds {net_test_init(&world,&info);apps[index]={allocator=context.allocator,tick_dt=1.0/60}}
    defer for &world in worlds {core.world_destroy(&info,.World,&world)}
    defer for &app in apps {host.app_world_scratch_free(&app);delete(app.worlds)}
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=72,endpoints=2,packets=1024}))
    defer wire.sim_network_destroy(&network)
    for &session,index in sessions {
        if !testing.expect(t,net_test_session(&session,&worlds[index],&info,&apps[index],&network,index,index==0?.Server:.Client)) {return}
    }
    defer for &session in sessions {session_destroy(&session)}
    testing.expect_value(t,wire.host_connect(&sessions[1].host,wire.address_memory(0)),wire.Error.None)
    world:=&worlds[0]
    parent:=net_test_body(world,&info,1,{100,0,0})
    child:=net_test_body(world,&info,2,{200,0,0})
    large:=net_test_body(world,&info,3,{10,0,0})
    core.add(&world.parents,child,core.Parent{entity=parent})
    core.add(&world.objects,child,net_test_replicate(audience=.Always,priority=100))
    core.add(&world.objects,large,net_test_replicate(radius=0))
    core.settle(&info,world,nil)
    outbox:Net_Outbox;defer core.value_free(&outbox,type_info_of(Net_Outbox))
    connected:Connection
    replacement:=core.NONE
    // The seat of the connection: its bits say whether it sees parent.
    seat:=core.create(&world.entities)
    first_parent,child_object,large_object:Object
    for tick in 1..<200 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        commands:=wire.host_poll(&sessions[0].host)
        server_commands(&sessions[0],core.world_ref(world,&info),nil,commands,&world.remote)
        for command in commands {
            if command.kind==.Connected {
                connected=command.connection
                testing.expect(t,view_set(&sessions[0],connected,{},1))
            }
        }
        wire.host_poll(&sessions[1].host)
        if tick==20 {
            core.add(&world.objects,parent,net_test_replicate(audience=.Always))
            core.add(&world.visibility,parent,Visibility{mask=1})
            core.add(&world.seats,seat,inp.Seat{peer=u64(connected)})
        }
        if tick==40 {core.add(&world.visibility,seat,Visibility{sees=1})}
        if tick==70 {core.add(&world.visibility,seat,Visibility{})}
        if tick==100 {core.add(&world.visibility,seat,Visibility{sees=1});core.edit(&world.objects,large).radius=10}
        if tick==120 {core.destroy(&world.entities,parent)}
        if tick==121 {
            replacement=net_test_body(world,&info,4,{100,0,0})
            core.add(&world.objects,replacement,net_test_replicate(audience=.Always))
            core.add(&world.visibility,replacement,Visibility{mask=1})
            testing.expect(t,replacement!=parent && core.entity_index(replacement)==core.entity_index(parent))
        }
        if tick==165 {core.add(&world.parents,child,core.Parent{entity=replacement})}
        core.settle(&info,world,nil)
        server_publish(&sessions[0],core.world_ref(world,&info),&outbox,u32(tick))
        wire.host_update(&sessions[0].host,now)
        if tick==19 {
            child_object=wire.object_of_user(&sessions[0].host,u64(child))
            testing.expect(t,child_object!=0 && wire.object_valid(&sessions[1].host,child_object))
            testing.expect_value(t,sessions[0].server.objects[object_index(child_object)].parent,Object(0))
        }
        // The child comes first in the rows: it takes the object of parent made after it in the same publish.
        if tick==20 {
            slot:=&sessions[0].server.objects[object_index(child_object)]
            testing.expect(t,slot.parent!=0 && slot.parent==wire.object_of_user(&sessions[0].host,u64(parent)))
            testing.expect_value(t,slot.filter,wire.Filter.Always)
        }
        if tick==30 {
            first_parent=wire.object_of_user(&sessions[0].host,u64(parent))
            large_object=wire.object_of_user(&sessions[0].host,u64(large))
            testing.expect(t,first_parent!=0 && large_object!=0)
            testing.expect_value(t,wire.object_of_user(&sessions[0].host,u64(child)),child_object)
            testing.expect(t,!wire.object_valid(&sessions[1].host,first_parent) && !wire.object_valid(&sessions[1].host,child_object))
        }
        if tick==65 {
            testing.expect(t,wire.object_valid(&sessions[1].host,first_parent) && wire.object_valid(&sessions[1].host,child_object))
            testing.expect(t,!wire.object_valid(&sessions[1].host,large_object))
        }
        if tick==95 {testing.expect(t,!wire.object_valid(&sessions[1].host,first_parent) && !wire.object_valid(&sessions[1].host,child_object))}
        if tick==115 {testing.expect(t,wire.object_valid(&sessions[1].host,large_object))}
        if tick==160 {
            testing.expect(t,wire.object_valid(&sessions[1].host,child_object))
            testing.expect_value(t,wire.object_of_user(&sessions[0].host,u64(child)),child_object)
            testing.expect_value(t,sessions[0].server.objects[object_index(child_object)].parent,Object(0))
        }
    }
    testing.expect(t,connected!=0)
    testing.expect(t,wire.object_valid(&sessions[1].host,child_object))
    testing.expect_value(t,sessions[0].server.objects[object_index(child_object)].parent,wire.object_of_user(&sessions[0].host,u64(replacement)))
}

// The Joint of a replica waits off it for its target; the frames the server
// took for it hold when it is retargeted, retuned or its target is rescaled.
@(test)
replicated_joint_waits_for_its_target_and_preserves_authoritative_frames_on_retarget :: proc(t:^testing.T) {
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World;net_test_init(&world,&info);defer core.world_destroy(&info,.World,&world)
    source:=net_test_body(&world,&info,1)
    initial:=net_test_body(&world,&info,2,{1,0,0})
    target:=net_test_body(&world,&info,3,{0,0,2})
    for &value in world.values.values {value.force=0}
    core.add(&world.joints,source,phys.joint_fixed(initial))
    core.settle(&info,&world,nil)
    shared:=Net_Test_Shared{info=&info};defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared,&app)
    testing.expect_value(t,world.state.world.joint_count,i32(1))
    core.push(&world.requests.queue,phys.Body_Request{entity=source,kind=.Teleport,position={0,1,0},rotation=quaternion(w=.70710677,x=0,y=.70710677,z=0)})
    net_test_physics(&world,&shared,&app)
    ref:=core.world_ref(&world,&info)
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=91,endpoints=2,packets=64}));defer wire.sim_network_destroy(&network)
    session:Net_Session
    if !testing.expect(t,net_test_session(&session,&world,&info,&app,&network,0,.Server)) {return}
    defer session_destroy(&session)
    if !testing.expect(t,client_init(&session,ref,app.allocator)) {return}
    type:=net_test_type(&session,ref,source)
    joint_fragment,state_fragment:=net_test_fragment(&session,type,phys.Joint),net_test_fragment(&session,type,phys.Joint_State)
    if !testing.expect(t,joint_fragment>=0 && state_fragment>=0,"the body replicates its joint") {return}
    target_object,target_error:=wire.object_create(&session.host,{type=type})
    if !testing.expect_value(t,target_error,wire.Error.None) {return}
    _,initial_error:=wire.object_create(&session.host,{type=type,user=u64(initial)})
    if !testing.expect_value(t,initial_error,wire.Error.None) {return}
    object,error:=wire.object_create(&session.host,{type=type,user=u64(source)})
    if !testing.expect_value(t,error,wire.Error.None) {return}
    words:=make([]u32,session.client.words_per);defer delete(words)
    replica:=Replica{object=object,entity=source,type=type}
    command:=net_test_command(&session,&world,&replica,1,0,words)
    joint:=phys.joint_revolute(core.NONE)
    state:=phys.Joint_State{taken=true,target_anchor={1,2,3},target_rotation=quaternion(w=1,x=0,y=0,z=0)}
    wire.object_pack(&session.host,type,joint_fragment,&joint,words)
    wire.object_pack(&session.host,type,state_fragment,&state,words)
    for leaf in session.protocol.types[type].leaves {
        // The only reference of a Joint is its target.
        if int(leaf.fragment)==joint_fragment && leaf.kind==.Object {words[leaf.word]=u32(u64(target_object));words[leaf.word+1]=u32(u64(target_object)>>32);break}
    }
    command.kind,command.role,command.simulation=.Object_Created,.Predicted,.Server
    replica_create(&session,ref,app.assets,&command)
    core.settle(&info,&world,nil)
    testing.expect(t,!core.has(&world.joints,source))
    net_test_physics(&world,&shared,&app)
    testing.expect_value(t,world.state.world.joint_count,i32(0))
    testing.expect_value(t,wire.object_bind(&session.host,target_object,u64(target)),wire.Error.None)
    references_refresh(&session,ref)
    core.settle(&info,&world,nil)
    held,has:=core.get(&world.joints,source)
    testing.expect(t,has && held.target==target)
    net_test_physics(&world,&shared,&app)
    took,_:=core.get(&world.joint_states,source)
    testing.expect(t,took.taken && took.target_anchor==state.target_anchor && took.target_rotation==state.target_rotation)
    testing.expect_value(t,world.state.world.joint_count,i32(1))
    r:=replica_of(&session,object)
    if !testing.expect(t,r!=nil) {return}
    // Retargeted to an entity that is replicated, with frames of its own.
    joint.target=initial
    joint.anchor={.2,0,0}
    state.target_anchor={-1,.5,0}
    retarget:=net_test_command(&session,&world,r,2,0,words)
    wire.object_pack(&session.host,type,joint_fragment,&joint,words)
    wire.object_pack(&session.host,type,state_fragment,&state,words)
    replica_update(&session,ref,app.assets,&retarget)
    core.settle(&info,&world,nil)
    net_test_physics(&world,&shared,&app)
    took,_=core.get(&world.joint_states,source)
    testing.expect(t,took.taken && took.target_anchor==state.target_anchor)
    generation:=world.state.world.joints[0].generation
    joint.motor=true;joint.motor_speed=1;joint.max_motor=1
    retune:=net_test_command(&session,&world,r,3,0,words)
    wire.object_pack(&session.host,type,joint_fragment,&joint,words)
    wire.object_pack(&session.host,type,state_fragment,&state,words)
    replica_update(&session,ref,app.assets,&retune)
    core.settle(&info,&world,nil)
    net_test_physics(&world,&shared,&app)
    testing.expect_value(t,world.state.world.joints[0].generation,generation)
    target_pose,_:=core.get(&world.transforms,initial)
    pose_apply(&session,ref,initial,net_type(&session,net_test_type(&session,ref,initial)),Pose{position=target_pose.position,rotation=target_pose.rotation,scale={2,1,1}},Motion_State{},false)
    core.settle(&info,&world,nil)
    net_test_physics(&world,&shared,&app)
    scaled,_:=core.get(&world.transforms,initial)
    testing.expect_value(t,scaled.scale,[3]f32{2,1,1})
    took,_=core.get(&world.joint_states,source)
    testing.expect(t,took.taken && took.target_anchor==state.target_anchor)
    testing.expect_value(t,world.state.world.joint_count,i32(1))
}
