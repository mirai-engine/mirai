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
import sim "plugins:physics/runtime/sim"
import "mirai:std/base"

@(component,replicated)
Net_Test_Value :: struct {force:f32,target:core.Entity}

@(private) NET_TEST_TABLES :: 27

@(private)
Net_Test_World :: struct {
    es:core.Entities,
    gravities:core.Table(volume.Gravity),gravity_places:core.Table(volume.Volume), // one Gravity: none unless a test gives it
    values:core.Table(Net_Test_Value),
    transforms:core.Table(core.Transform),
    worlds:core.Table(core.World_Transform),
    identities:core.Table(core.Id),
    parents:core.Table(core.Parent),
    names:core.Table(core.Name),
    objects:core.Table(Replicate),
    links:core.Table(Net_Link),
    replicas:core.Table(core.Pose_Target),
    remotes:core.Table(core.Remote),
    offsets:core.Table(render.Draw_Offset),
    rigids:core.Table(phys.Rigid_Body),
    colliders:core.Table(phys.Collider),
    characters:core.Table(phys.Character),
    moves:core.Table(inp.Move_Input),
    joints:core.Table(phys.Joint),
    motions:core.Table(core.Motion),
    character_states:core.Table(phys.Character_State),
    joint_states:core.Table(phys.Joint_State),
    meshes:core.Table(render.Mesh_Renderer),
    sources:core.Table(scene.Prefab_Source),
    drivables:core.Table(inp.Drivable),
    seats:core.Table(inp.Seat),
    references:core.Table(scene.Scene_Reference),
    tombstones:core.Table(scene.Tombstone),
    disabled:core.Table(core.Disabled),
    held:core.Table(scene.Section_Held),
    time:core.Time,
    frame:core.Frame_Time, // never copied, as copy=false in a generated world
    input:core.Input,
    bindings:inp.Input_Map,
    physics:phys.Physics_State,
    settings:phys.Physics_Settings,
    requests:phys.Body_Requests,
    events:phys.Physics_Events,
    remote:Remote_Inputs,
    received:Net_Events, // never copied: what pump takes while the game is paused
    request:Session_Request,
    network:core.Network,
    sync_check:core.Sync_Check,
    simulation_hash:core.Simulation_Hash,
    places:core.Pose_Target_Places,
    hierarchy:core.Hierarchy,
    root:scene.Scene_Root,
    scene_requests:scene.Scene_Requests,
    scene_results:scene.Scene_Results,
    connections:Net_Connections,
    clock:core.Clock,
    clock_requests:core.Clock_Requests,
    identity:Net_Identity,
    force_total:f32,
}

@(private)
Net_Test_Shared :: struct {session:^Net_Session,info:^core.World_Info,colliders:phys.Collider_Meshes}

@(private)
net_test_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    context.allocator=allocator
    w:=cast(^Net_Test_World)data
    if !core.entities_init(&w.es) {return false}
    core.table_init(&w.values,"Net_Test_Value")
    core.table_init(&w.transforms,"core.Transform")
    core.table_init(&w.worlds,"core.World_Transform")
    core.table_init(&w.gravities,"Gravity")
    core.table_init(&w.gravity_places,"Volume")
    core.add(&w.gravities,core.create(&w.es),volume.Gravity{})
    core.table_settle(&w.gravities,&w.es)
    core.table_init(&w.identities,"core.Id")
    core.table_init(&w.parents,"core.Parent")
    core.table_init(&w.names,"core.Name")
    core.table_init(&w.objects,"Replicate")
    core.table_init(&w.links,"Net_Link")
    core.table_init(&w.replicas,"core.Pose_Target")
    core.table_init(&w.remotes,"core.Remote")
    core.table_init(&w.offsets,"render.Draw_Offset")
    core.table_init(&w.rigids,"phys.Rigid_Body")
    core.table_init(&w.colliders,"phys.Collider")
    core.table_init(&w.characters,"phys.Character")
    core.table_init(&w.moves,"inp.Move_Input")
    core.table_init(&w.joints,"phys.Joint")
    core.table_init(&w.motions,"core.Motion")
    core.table_init(&w.character_states,"phys.Character_State")
    core.table_init(&w.joint_states,"phys.Joint_State")
    core.table_init(&w.meshes,"render.Mesh_Renderer")
    core.table_init(&w.sources,"scene.Prefab_Source")
    core.table_init(&w.drivables,"inp.Drivable")
    core.table_init(&w.seats,"inp.Seat")
    core.table_init(&w.references,"scene.Scene_Reference")
    core.table_init(&w.tombstones,"scene.Tombstone")
    core.table_init(&w.disabled,"core.Disabled")
    core.table_init(&w.held,"scene.Section_Held")
    w.disabled.base=true
    // As the generator declares them: a body and a character own their Transform.
    w.rigids.locks=make([]core.Lock,1)
    w.rigids.locks[0]={core.lock_offset(&w.rigids,&w.transforms),1,nil,"core.Transform"}
    w.characters.locks=make([]core.Lock,1)
    w.characters.locks[0]={core.lock_offset(&w.characters,&w.transforms),2,nil,"core.Transform"}
    w.settings={bodies=8,shapes=8,contacts=32,joints=8,characters=4,hulls=1,meshes=1,heightfields=1}
    w.time,w.frame={dt=1.0/60,playing=true},core.FRAME_TIME_DEFAULT
    w.clock=core.CLOCK_DEFAULT
    inp.input_map_action(&w.bindings,NET_TEST_PUSH,.Axis)
    inp.input_map_bind(&w.bindings,NET_TEST_PUSH,inp.binding_key_axis(.Left,.Right))
    inp.input_map_action(&w.bindings,NET_TEST_FIRE,.Button)
    inp.input_map_bind(&w.bindings,NET_TEST_FIRE,inp.binding_gamepad_button(.South))
    inp.input_map_action(&w.bindings,NET_TEST_STEER,.Axis)
    inp.input_map_bind(&w.bindings,NET_TEST_STEER,inp.binding_gamepad_axis(.Left_X))
    return true
}

@(private) NET_TEST_PUSH :: inp.Action(16)
@(private) NET_TEST_FIRE :: inp.Action(17)
@(private) NET_TEST_STEER :: inp.Action(18)

// The player at a client: the seat whose actions it sends.
@(private)
net_test_player :: proc(w:^Net_Test_World) -> core.Entity {
    seat:=core.create(&w.es)
    core.add(&w.seats,seat,inp.Seat{})
    core.table_settle(&w.seats,&w.es)
    return seat
}

// The seats of this machine take their actions from the devices of the tick, as input_seats does.
@(private)
net_test_feed :: proc(w:^Net_Test_World) {
    for row in 0..<core.count(&w.seats) {
        if !inp.seat_local(w.seats.values[row]) {continue}
        device:=w.input
        inp.seat_feed(core.at(&w.seats,row),&device,&w.bindings,false)
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

@(private)
net_test_destroy :: proc(data:rawptr) {
    w:=cast(^Net_Test_World)data
    phys.state_destroy(&w.physics)
    delete(w.rigids.locks)
    delete(w.characters.locks)
    core.table_destroy(&w.values)
    core.table_destroy(&w.transforms)
    core.table_destroy(&w.worlds)
    core.table_destroy(&w.gravities)
    core.table_destroy(&w.gravity_places)
    core.table_destroy(&w.identities)
    core.table_destroy(&w.parents)
    core.table_destroy(&w.names)
    core.table_destroy(&w.objects)
    core.table_destroy(&w.links)
    core.table_destroy(&w.replicas)
    core.table_destroy(&w.remotes)
    core.table_destroy(&w.offsets)
    core.table_destroy(&w.rigids)
    core.table_destroy(&w.colliders)
    core.table_destroy(&w.characters)
    core.table_destroy(&w.moves)
    core.table_destroy(&w.joints)
    core.table_destroy(&w.motions)
    core.table_destroy(&w.character_states)
    core.table_destroy(&w.joint_states)
    core.table_destroy(&w.meshes)
    core.table_destroy(&w.sources)
    core.table_destroy(&w.drivables)
    core.table_destroy(&w.seats)
    core.table_destroy(&w.references)
    core.table_destroy(&w.tombstones)
    core.table_destroy(&w.disabled)
    core.table_destroy(&w.held)
    delete(w.clock_requests.queue.items)
    core.value_free(&w.requests,type_info_of(phys.Body_Requests))
    core.value_free(&w.events,type_info_of(phys.Physics_Events))
    delete(w.remote.entries)
    core.value_free(&w.received,type_info_of(Net_Events))
    core.value_free(&w.hierarchy,type_info_of(core.Hierarchy))
    delete(w.scene_requests.queue.items);delete(w.scene_results.queue.items);delete(w.connections.events.items)
    core.entities_destroy(&w.es)
}

@(private)
net_test_copy :: proc(dst,src:rawptr) -> bool {
    d,s:=cast(^Net_Test_World)dst,cast(^Net_Test_World)src
    if d.es.generation.allocator.procedure!=nil {context.allocator=d.es.generation.allocator}
    synced:=core.ids_synced(&s.es,core.read(&s.identities))
    if !core.entities_copy(&d.es,&s.es) {return false}
    if !core.table_copy(&d.values,&s.values) {return false}
    if !core.table_copy(&d.transforms,&s.transforms) {return false}
    if !core.table_copy(&d.worlds,&s.worlds) {return false}
    if !core.table_copy(&d.identities,&s.identities) {return false}
    if !core.table_copy(&d.parents,&s.parents) {return false}
    if !core.table_copy(&d.names,&s.names) {return false}
    if !core.table_copy(&d.objects,&s.objects) {return false}
    if !core.table_copy(&d.links,&s.links) {return false}
    if !core.table_copy(&d.replicas,&s.replicas) {return false}
    if !core.table_copy(&d.remotes,&s.remotes) {return false}
    if !core.table_copy(&d.offsets,&s.offsets) {return false}
    if !core.table_copy(&d.rigids,&s.rigids) {return false}
    if !core.table_copy(&d.colliders,&s.colliders) {return false}
    if !core.table_copy(&d.characters,&s.characters) {return false}
    if !core.table_copy(&d.moves,&s.moves) {return false}
    if !core.table_copy(&d.joints,&s.joints) {return false}
    if !core.table_copy(&d.motions,&s.motions) {return false}
    if !core.table_copy(&d.character_states,&s.character_states) {return false}
    if !core.table_copy(&d.joint_states,&s.joint_states) {return false}
    if !core.table_copy(&d.meshes,&s.meshes) {return false}
    if !core.table_copy(&d.sources,&s.sources) {return false}
    if !core.table_copy(&d.drivables,&s.drivables) {return false}
    if !core.table_copy(&d.seats,&s.seats) {return false}
    if !core.table_copy(&d.references,&s.references) {return false}
    if !core.table_copy(&d.tombstones,&s.tombstones) {return false}
    if !core.table_copy(&d.disabled,&s.disabled) {return false}
    if !core.table_copy(&d.held,&s.held) {return false}
    if !phys.state_copy(&d.physics,&s.physics) {return false}
    d.time,d.input,d.settings=s.time,s.input,s.settings
    d.network,d.sync_check,d.simulation_hash,d.places=s.network,s.sync_check,s.simulation_hash,s.places
    d.force_total,d.root,d.clock,d.identity=s.force_total,s.root,s.clock,s.identity
    core.ids_moved(&d.es,core.read(&d.identities),synced)
    return core.value_copy(&d.requests,&s.requests,type_info_of(phys.Body_Requests)) &&
           core.value_copy(&d.events,&s.events,type_info_of(phys.Physics_Events)) &&
           core.value_copy(&d.remote,&s.remote,type_info_of(Remote_Inputs)) &&
           core.value_copy(&d.hierarchy,&s.hierarchy,type_info_of(core.Hierarchy)) &&
           core.value_copy(&d.scene_requests,&s.scene_requests,type_info_of(scene.Scene_Requests)) &&
           core.value_copy(&d.scene_results,&s.scene_results,type_info_of(scene.Scene_Results)) &&
           core.value_copy(&d.connections,&s.connections,type_info_of(Net_Connections))
}

// The copy of what changed, with marks by the index of net_test_info.
@(private)
net_test_copy_changed :: proc(dst,src:rawptr,marks:[]core.Copy_Mark) -> bool {
    d,s:=cast(^Net_Test_World)dst,cast(^Net_Test_World)src
    if d.es.generation.allocator.procedure!=nil {context.allocator=d.es.generation.allocator}
    synced:=core.ids_synced(&s.es,core.read(&s.identities))
    if !core.entities_copy(&d.es,&s.es) {return false}
    if !core.table_copy_changed(&d.values,&s.values,&marks[0]) {return false}
    if !core.table_copy_changed(&d.transforms,&s.transforms,&marks[1]) {return false}
    if !core.table_copy_changed(&d.worlds,&s.worlds,&marks[2]) {return false}
    if !core.table_copy_changed(&d.identities,&s.identities,&marks[3]) {return false}
    if !core.table_copy_changed(&d.parents,&s.parents,&marks[4]) {return false}
    if !core.table_copy_changed(&d.names,&s.names,&marks[5]) {return false}
    if !core.table_copy_changed(&d.objects,&s.objects,&marks[6]) {return false}
    if !core.table_copy_changed(&d.links,&s.links,&marks[7]) {return false}
    if !core.table_copy_changed(&d.replicas,&s.replicas,&marks[8]) {return false}
    if !core.table_copy_changed(&d.remotes,&s.remotes,&marks[9]) {return false}
    if !core.table_copy_changed(&d.offsets,&s.offsets,&marks[10]) {return false}
    if !core.table_copy_changed(&d.rigids,&s.rigids,&marks[11]) {return false}
    if !core.table_copy_changed(&d.colliders,&s.colliders,&marks[12]) {return false}
    if !core.table_copy_changed(&d.characters,&s.characters,&marks[13]) {return false}
    if !core.table_copy_changed(&d.moves,&s.moves,&marks[14]) {return false}
    if !core.table_copy_changed(&d.joints,&s.joints,&marks[15]) {return false}
    if !core.table_copy_changed(&d.motions,&s.motions,&marks[16]) {return false}
    if !core.table_copy_changed(&d.character_states,&s.character_states,&marks[17]) {return false}
    if !core.table_copy_changed(&d.joint_states,&s.joint_states,&marks[18]) {return false}
    if !core.table_copy_changed(&d.meshes,&s.meshes,&marks[19]) {return false}
    if !core.table_copy_changed(&d.sources,&s.sources,&marks[20]) {return false}
    if !core.table_copy_changed(&d.drivables,&s.drivables,&marks[21]) {return false}
    if !core.table_copy_changed(&d.seats,&s.seats,&marks[22]) {return false}
    if !core.table_copy_changed(&d.references,&s.references,&marks[23]) {return false}
    if !core.table_copy_changed(&d.tombstones,&s.tombstones,&marks[24]) {return false}
    if !core.table_copy_changed(&d.disabled,&s.disabled,&marks[25]) {return false}
    if !core.table_copy_changed(&d.held,&s.held,&marks[26]) {return false}
    if !phys.state_copy(&d.physics,&s.physics) {return false}
    d.time,d.input,d.settings=s.time,s.input,s.settings
    d.network,d.sync_check,d.simulation_hash,d.places=s.network,s.sync_check,s.simulation_hash,s.places
    d.force_total,d.root,d.clock,d.identity=s.force_total,s.root,s.clock,s.identity
    core.ids_moved(&d.es,core.read(&d.identities),synced)
    return core.value_copy(&d.requests,&s.requests,type_info_of(phys.Body_Requests)) &&
           core.value_copy(&d.events,&s.events,type_info_of(phys.Physics_Events)) &&
           core.value_copy(&d.remote,&s.remote,type_info_of(Remote_Inputs)) &&
           core.value_copy(&d.hierarchy,&s.hierarchy,type_info_of(core.Hierarchy)) &&
           core.value_copy(&d.scene_requests,&s.scene_requests,type_info_of(scene.Scene_Requests)) &&
           core.value_copy(&d.scene_results,&s.scene_results,type_info_of(scene.Scene_Results)) &&
           core.value_copy(&d.connections,&s.connections,type_info_of(Net_Connections))
}

@(private)
net_test_swap :: proc(a,b:rawptr) {
    d,s:=cast(^Net_Test_World)a,cast(^Net_Test_World)b
    d_synced,s_synced:=core.ids_synced(&d.es,core.read(&d.identities)),core.ids_synced(&s.es,core.read(&s.identities))
    d.es,s.es=s.es,d.es
    core.table_swap(&d.values,&s.values)
    core.table_swap(&d.transforms,&s.transforms)
    core.table_swap(&d.worlds,&s.worlds)
    core.table_swap(&d.identities,&s.identities)
    core.table_swap(&d.parents,&s.parents)
    core.table_swap(&d.names,&s.names)
    core.table_swap(&d.objects,&s.objects)
    core.table_swap(&d.links,&s.links)
    core.table_swap(&d.replicas,&s.replicas)
    core.table_swap(&d.remotes,&s.remotes)
    core.table_swap(&d.offsets,&s.offsets)
    core.table_swap(&d.rigids,&s.rigids)
    core.table_swap(&d.colliders,&s.colliders)
    core.table_swap(&d.characters,&s.characters)
    core.table_swap(&d.moves,&s.moves)
    core.table_swap(&d.joints,&s.joints)
    core.table_swap(&d.motions,&s.motions)
    core.table_swap(&d.character_states,&s.character_states)
    core.table_swap(&d.joint_states,&s.joint_states)
    core.table_swap(&d.meshes,&s.meshes)
    core.table_swap(&d.sources,&s.sources)
    core.table_swap(&d.drivables,&s.drivables)
    core.table_swap(&d.seats,&s.seats)
    core.table_swap(&d.references,&s.references)
    core.table_swap(&d.tombstones,&s.tombstones)
    core.table_swap(&d.disabled,&s.disabled)
    core.table_swap(&d.held,&s.held)
    phys.state_swap(&d.physics,&s.physics)
    d.time,s.time=s.time,d.time
    d.input,s.input=s.input,d.input
    d.settings,s.settings=s.settings,d.settings
    d.network,s.network=s.network,d.network
    d.sync_check,s.sync_check=s.sync_check,d.sync_check
    d.simulation_hash,s.simulation_hash=s.simulation_hash,d.simulation_hash
    d.places,s.places=s.places,d.places
    d.force_total,s.force_total=s.force_total,d.force_total
    d.requests,s.requests=s.requests,d.requests
    d.events,s.events=s.events,d.events
    d.remote,s.remote=s.remote,d.remote
    d.hierarchy,s.hierarchy=s.hierarchy,d.hierarchy
    d.root,s.root=s.root,d.root
    d.scene_requests,s.scene_requests=s.scene_requests,d.scene_requests
    d.scene_results,s.scene_results=s.scene_results,d.scene_results
    d.connections,s.connections=s.connections,d.connections
    d.clock,s.clock=s.clock,d.clock
    d.clock_requests,s.clock_requests=s.clock_requests,d.clock_requests
    d.identity,s.identity=s.identity,d.identity
    core.ids_moved(&d.es,core.read(&d.identities),s_synced)
    core.ids_moved(&s.es,core.read(&s.identities),d_synced)
}

@(private)
net_test_settle :: proc(world,shared,editor:rawptr) {
    w:=cast(^Net_Test_World)world
    // As the generated settle: what is off follows Disabled and the tree before the other tables move their rows.
    core.table_settle(&w.parents,&w.es)
    _=core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.es)
    core.table_settle(&w.disabled,&w.es)
    core.entities_activity(&w.es,core.read(&w.disabled),core.ref(&w.hierarchy))
    core.table_settle(&w.values,&w.es)
    core.table_settle(&w.transforms,&w.es)
    core.table_settle(&w.worlds,&w.es)
    core.table_settle(&w.gravities,&w.es)
    core.table_settle(&w.gravity_places,&w.es)
    core.table_settle(&w.identities,&w.es)
    core.table_settle(&w.names,&w.es)
    core.table_settle(&w.objects,&w.es)
    core.table_settle(&w.links,&w.es)
    core.table_settle(&w.replicas,&w.es)
    core.table_settle(&w.remotes,&w.es)
    core.table_settle(&w.offsets,&w.es)
    core.table_settle(&w.rigids,&w.es)
    core.table_settle(&w.colliders,&w.es)
    core.table_settle(&w.characters,&w.es)
    core.table_settle(&w.moves,&w.es)
    core.table_settle(&w.joints,&w.es)
    core.table_settle(&w.motions,&w.es)
    core.table_settle(&w.character_states,&w.es)
    core.table_settle(&w.joint_states,&w.es)
    core.table_settle(&w.meshes,&w.es)
    core.table_settle(&w.sources,&w.es)
    core.table_settle(&w.drivables,&w.es)
    core.table_settle(&w.seats,&w.es)
    core.table_settle(&w.references,&w.es)
    core.table_settle(&w.tombstones,&w.es)
    core.table_settle(&w.held,&w.es)
    core.entities_settle(&w.es)
}

// follows: the messages of the session are in the protocol, as in a world the
// generator makes, and the seats replicate.
@(private)
net_test_info :: proc(follows:=false) -> core.World_Info {
    tables:=make([]core.Table_Info,NET_TEST_TABLES)
    tables[0]={name="Net_Test_Value",type=Net_Test_Value,info=type_info_of(Net_Test_Value),offset=offset_of(Net_Test_World,values),replicated=.All}
    tables[1]={name="core.Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Net_Test_World,transforms)}
    tables[2]={name="core.World_Transform",type=core.World_Transform,info=type_info_of(core.World_Transform),offset=offset_of(Net_Test_World,worlds)}
    tables[3]={name="core.Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Net_Test_World,identities)}
    tables[4]={name="core.Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Net_Test_World,parents)}
    tables[5]={name="core.Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Net_Test_World,names)}
    tables[6]={name="Replicate",type=Replicate,info=type_info_of(Replicate),offset=offset_of(Net_Test_World,objects)}
    tables[7]={name="Net_Link",type=Net_Link,info=type_info_of(Net_Link),offset=offset_of(Net_Test_World,links)}
    tables[8]={name="core.Pose_Target",type=core.Pose_Target,info=type_info_of(core.Pose_Target),offset=offset_of(Net_Test_World,replicas)}
    tables[9]={name="core.Remote",type=core.Remote,info=type_info_of(core.Remote),offset=offset_of(Net_Test_World,remotes)}
    tables[10]={name="render.Draw_Offset",type=render.Draw_Offset,info=type_info_of(render.Draw_Offset),offset=offset_of(Net_Test_World,offsets)}
    tables[11]={name="phys.Rigid_Body",type=phys.Rigid_Body,info=type_info_of(phys.Rigid_Body),offset=offset_of(Net_Test_World,rigids)}
    tables[12]={name="phys.Collider",type=phys.Collider,info=type_info_of(phys.Collider),offset=offset_of(Net_Test_World,colliders),replicated=.All}
    tables[13]={name="phys.Character",type=phys.Character,info=type_info_of(phys.Character),offset=offset_of(Net_Test_World,characters)}
    tables[14]={name="inp.Move_Input",type=inp.Move_Input,info=type_info_of(inp.Move_Input),offset=offset_of(Net_Test_World,moves)}
    tables[15]={name="phys.Joint",type=phys.Joint,info=type_info_of(phys.Joint),offset=offset_of(Net_Test_World,joints),replicated=.All}
    tables[16]={name="core.Motion",type=core.Motion,info=type_info_of(core.Motion),offset=offset_of(Net_Test_World,motions)}
    tables[17]={name="phys.Character_State",type=phys.Character_State,info=type_info_of(phys.Character_State),offset=offset_of(Net_Test_World,character_states)}
    tables[18]={name="phys.Joint_State",type=phys.Joint_State,info=type_info_of(phys.Joint_State),offset=offset_of(Net_Test_World,joint_states),replicated=.All}
    tables[19]={name="render.Mesh_Renderer",type=render.Mesh_Renderer,info=type_info_of(render.Mesh_Renderer),offset=offset_of(Net_Test_World,meshes)}
    tables[20]={name="scene.Prefab_Source",type=scene.Prefab_Source,info=type_info_of(scene.Prefab_Source),offset=offset_of(Net_Test_World,sources)}
    tables[21]={name="inp.Drivable",type=inp.Drivable,info=type_info_of(inp.Drivable),offset=offset_of(Net_Test_World,drivables)}
    tables[22]={name="inp.Seat",type=inp.Seat,info=type_info_of(inp.Seat),offset=offset_of(Net_Test_World,seats),replicated=follows?.All:.None}
    tables[23]={name="scene.Scene_Reference",type=scene.Scene_Reference,info=type_info_of(scene.Scene_Reference),offset=offset_of(Net_Test_World,references),replicated=.All}
    tables[24]={name="scene.Tombstone",type=scene.Tombstone,info=type_info_of(scene.Tombstone),offset=offset_of(Net_Test_World,tombstones)}
    tables[25]={name="core.Disabled",type=core.Disabled,info=type_info_of(core.Disabled),offset=offset_of(Net_Test_World,disabled)}
    tables[26]={name="scene.Section_Held",type=scene.Section_Held,info=type_info_of(scene.Section_Held),offset=offset_of(Net_Test_World,held)}
    storages:=make([]core.Storage_Info,20)
    storages[0]={name="core.Time",type=core.Time,info=type_info_of(core.Time),offset=offset_of(Net_Test_World,time),keep=true}
    storages[1]={name="core.Input",type=core.Input,info=type_info_of(core.Input),offset=offset_of(Net_Test_World,input),keep=true}
    storages[2]={name="phys.Physics_State",type=phys.Physics_State,info=type_info_of(phys.Physics_State),offset=offset_of(Net_Test_World,physics)}
    storages[3]={name="Remote_Inputs",type=Remote_Inputs,info=type_info_of(Remote_Inputs),offset=offset_of(Net_Test_World,remote),keep=true}
    storages[4]={name="core.Frame_Time",type=core.Frame_Time,info=type_info_of(core.Frame_Time),offset=offset_of(Net_Test_World,frame)}
    storages[5]={name="Net_Events",type=Net_Events,info=type_info_of(Net_Events),offset=offset_of(Net_Test_World,received),keep=true}
    storages[6]={name="Session_Request",type=Session_Request,info=type_info_of(Session_Request),offset=offset_of(Net_Test_World,request),keep=true}
    storages[7]={name="core.Network",type=core.Network,info=type_info_of(core.Network),offset=offset_of(Net_Test_World,network),keep=true}
    storages[8]={name="core.Sync_Check",type=core.Sync_Check,info=type_info_of(core.Sync_Check),offset=offset_of(Net_Test_World,sync_check)}
    storages[9]={name="core.Simulation_Hash",type=core.Simulation_Hash,info=type_info_of(core.Simulation_Hash),offset=offset_of(Net_Test_World,simulation_hash)}
    storages[10]={name="core.Pose_Target_Places",type=core.Pose_Target_Places,info=type_info_of(core.Pose_Target_Places),offset=offset_of(Net_Test_World,places)}
    storages[11]={name="core.Hierarchy",type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Net_Test_World,hierarchy)}
    storages[12]={name="scene.Scene_Root",type=scene.Scene_Root,info=type_info_of(scene.Scene_Root),offset=offset_of(Net_Test_World,root),keep=true}
    storages[13]={name="scene.Scene_Requests",type=scene.Scene_Requests,info=type_info_of(scene.Scene_Requests),offset=offset_of(Net_Test_World,scene_requests),keep=true}
    storages[14]={name="scene.Scene_Results",type=scene.Scene_Results,info=type_info_of(scene.Scene_Results),offset=offset_of(Net_Test_World,scene_results),keep=true}
    storages[15]={name="Net_Connections",type=Net_Connections,info=type_info_of(Net_Connections),offset=offset_of(Net_Test_World,connections)}
    storages[16]={name="core.Clock",type=core.Clock,info=type_info_of(core.Clock),offset=offset_of(Net_Test_World,clock),keep=true}
    storages[17]={name="core.Clock_Requests",type=core.Clock_Requests,info=type_info_of(core.Clock_Requests),offset=offset_of(Net_Test_World,clock_requests),keep=true}
    storages[18]={name="Net_Identity",type=Net_Identity,info=type_info_of(Net_Identity),offset=offset_of(Net_Test_World,identity),keep=true}
    storages[19]={name="inp.Input_Map",type=inp.Input_Map,info=type_info_of(inp.Input_Map),offset=offset_of(Net_Test_World,bindings),keep=true}
    messages:[]core.Message_Info
    if follows {
        messages=make([]core.Message_Info,5)
        messages[0]={name="Net_World",library="multiplayer",type=Net_World,info=type_info_of(Net_World),from=.Server,reliable=true}
        messages[1]={name="Net_World_Ready",library="multiplayer",type=Net_World_Ready,info=type_info_of(Net_World_Ready),from=.Client,reliable=true}
        messages[2]={name="Net_Player",library="multiplayer",type=Net_Player,info=type_info_of(Net_Player),from=.Client,reliable=true}
        messages[3]={name="Net_Section",library="multiplayer",type=Net_Section,info=type_info_of(Net_Section),from=.Client,reliable=true}
        messages[4]={name="Net_Gone",library="multiplayer",type=Net_Gone,info=type_info_of(Net_Gone),from=.Server,reliable=true}
    }
    info:=core.World_Info{sizes={.World=size_of(Net_Test_World),.Shared=0,.Editor=0},aligns={.World=align_of(Net_Test_World),.Shared=1,.Editor=1},entities=offset_of(Net_Test_World,es),tables=tables,storages=storages,messages=messages,copy=net_test_copy,copy_changed=net_test_copy_changed,swap=net_test_swap}
    info.init[.World],info.destroy[.World]=net_test_init,net_test_destroy
    info.loops[.Game][.Fixed]=net_test_fixed
    return info
}

// What the fixed loop runs of physics: the places of the replicas, then the step.
@(private)
net_test_physics :: proc(w:^Net_Test_World,shared:^Net_Test_Shared,app:^host.App) {
    phys.physics_pose_targets(&w.physics,core.read(&w.replicas),&w.transforms,core.read(&w.parents),core.read(&w.rigids),core.read(&w.characters))
    net_test_settle(w,nil,nil)
    core.pose_targets_place(core.read(&w.replicas),&w.transforms,&w.places)
    net_test_settle(w,nil,nil)
    for value,index in w.values.values {
        w.force_total+=value.force
        phys.apply_force(&w.requests,w.values.entities[index],{value.force,0,0})
    }
    // Its characters are not driven: they stand where they are.
    undriven:core.Table(phys.Character_Move)
    phys.physics_step(&w.physics,core.ref(&w.settings),&w.requests,&w.events,&shared.colliders,app,w.time,
        core.read(&w.rigids),core.read(&w.colliders),core.read(&w.characters),core.read(&undriven),&w.joints,
        core.read(&w.meshes),core.read(&w.parents),core.read(&w.names),&w.transforms,&w.motions,core.read(&w.replicas),
        &w.character_states,&w.joint_states,{},nil,{},core.ref(&w.sync_check),&w.simulation_hash,nil,nil,
        core.read(&w.gravities),core.read(&w.gravity_places),core.read(&w.worlds),{},{},core.ref(&w.hierarchy))
    net_test_settle(w,nil,nil)
}

@(private)
net_test_fixed :: proc(world,shared,editor,application:rawptr) {
    w:=cast(^Net_Test_World)world
    sh:=cast(^Net_Test_Shared)shared
    app:=cast(^host.App)application
    ref:=core.world_ref(w,sh.info)
    if sh.session!=nil {
        net_tick_head(ref,app,sh.session,&w.remote,nil,sh.session.problems)
        net_test_settle(w,nil,nil)
    }
    net_test_feed(w)
    net_test_physics(w,sh,app)
    if sh.session!=nil {
        outbox:Net_Outbox
        adoptions:Net_Adoptions
        net_tick_tail(ref,app,sh.session,&outbox,&adoptions,sh.session.problems)
        core.value_free(&outbox,type_info_of(Net_Outbox))
        core.value_free(&adoptions,type_info_of(Net_Adoptions))
    }
}

@(private)
net_test_body :: proc(w:^Net_Test_World,id:base.Entity_Id,position:[3]f32={}) -> core.Entity {
    e:=core.create(&w.es)
    core.add(&w.identities,e,core.Id{id})
    core.add(&w.transforms,e,core.Transform{position=position,rotation=1,scale={1,1,1}})
    core.add(&w.rigids,e,phys.Rigid_Body{type=.Dynamic,mass=1})
    core.add(&w.colliders,e,phys.collider_box({0.1,0.1,0.1}))
    core.add(&w.values,e,Net_Test_Value{force=1})
    net_test_settle(w,nil,nil)
    return e
}

@(private)
net_test_replicate :: proc(audience:=Audience.Near,simulation:=Simulation.Server,update_hz:f32=0,radius:f32=1,priority:f32=1) -> Replicate {
    return {simulation=simulation,audience=audience,priority=priority,update_hz=update_hz,radius=radius}
}

// The seat of a connection drives e: the connection owns it. Settled by the caller.
@(private)
net_test_own :: proc(w:^Net_Test_World,e:core.Entity,connection:Connection) {
    seat:=core.create(&w.es)
    core.add(&w.seats,seat,inp.Seat{peer=u64(connection)})
    core.add(&w.drivables,e,inp.Drivable{seat=seat})
}

@(private)
net_test_session :: proc(s:^Net_Session,w:^Net_Test_World,info:^core.World_Info,app:^host.App,network:^wire.Sim_Network,endpoint:int,mode:wire.Mode,transport:wire.Transport={},settings:=Net_Settings{max_objects=8,predicted_capacity=8,replication={history_seconds=0.25},resimulate_budget=600}) -> bool {
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
    ready:=mode==.Client?client_init(s,core.world_ref(w,info),app):server_init(s,context.allocator)
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
    r^={object=1,entity=e,type=net_test_type(s,w,e),role=role,simulation=simulation,slot=-1}
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
    local,_:=core.get(core.read(&w.transforms),r.entity)
    pose:=Pose{id=core.id_of(core.read(&w.identities),r.entity),position=local.position,rotation=local.rotation,scale=local.scale}
    motion,_:=motion_read(core.world_ref(w,s.info),r.entity)
    return net_test_pack(s,w,r,tick,pose,motion,force,words)
}

@(test)
authoritative_components_replay_at_their_ticks_with_real_physics :: proc(t:^testing.T) {
    info:=net_test_info()
    defer delete(info.tables)
    defer delete(info.storages)
    world:Net_Test_World
    net_test_init(&world,context.allocator)
    defer net_test_destroy(&world)
    e:=net_test_body(&world,1)
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
    net_test_copy(&expected,first)
    defer net_test_destroy(&expected)
    expected.values.values[0].force=4
    reference_shared:=Net_Test_Shared{info=&info}
    defer phys.collider_meshes_destroy(&reference_shared.colliders)
    for tick in 2..<6 {
        expected.time.tick=u64(tick)
        net_test_physics(&expected,&reference_shared,&app)
        if tick==3 {
            expected.values.values[0].force=7
            local,_:=core.get(core.read(&third.transforms),e)
            motion,_:=core.get(core.read(&third.motions),e)
            core.push(&expected.requests.queue,phys.Body_Request{entity=e,kind=.Teleport,position=local.position,rotation=local.rotation})
            phys.set_velocity(&expected.requests,e,motion.linear,motion.angular)
        }
    }
    words:=make([]u32,s.client.words_per)
    defer delete(words)
    one:=net_test_command(&s,first,r,1,4,words)
    replica_update(&s,core.world_ref(&world,&info),&app,&one)
    three:=net_test_command(&s,third,r,3,7,words)
    replica_update(&s,core.world_ref(&world,&info),&app,&three)
    client_reconcile(&s,core.world_ref(&world,&info),&app,1.0/60)
    testing.expect_value(t,s.stats.corrected,u64(1))
    testing.expect_value(t,world.values.values[0].force,f32(7))
    testing.expect_value(t,world.force_total,expected.force_total)
    got,_:=core.get(core.read(&world.transforms),e)
    wanted,_:=core.get(core.read(&expected.transforms),e)
    testing.expectf(t,linalg.length(got.position-wanted.position)<0.002,"position %v expected %v",got.position,wanted.position)
    before:=got.position
    client_reconcile(&s,core.world_ref(&world,&info),&app,1.0/60)
    got,_=core.get(core.read(&world.transforms),e)
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
    info:=net_test_info()
    defer delete(info.tables)
    defer delete(info.storages)
    world:Net_Test_World
    net_test_init(&world,context.allocator)
    defer net_test_destroy(&world)
    source:=net_test_body(&world,1)
    target:=net_test_body(&world,2,{1,0,0})
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=2,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,0,.Server)) {return}
    defer session_destroy(&s)
    if !testing.expect(t,client_init(&s,core.world_ref(&world,&info),&app)) {return}
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
    replica_create(&s,core.world_ref(&world,&info),&app,&command)
    net_test_settle(&world,nil,nil)
    testing.expect(t,!core.has(&world.values,source),"it waits for its target off the replica")
    testing.expect_value(t,wire.object_bind(&s.host,target_object,u64(target)),wire.Error.None)
    references_refresh(&s,core.world_ref(&world,&info))
    net_test_settle(&world,nil,nil)
    resolved,found:=core.get(core.read(&world.values),source)
    testing.expect(t,found && resolved.target==target && resolved.force==3)
    testing.expect(t,s.stats.references_resolved>0)
    testing.expect_value(t,wire.object_destroy(&s.host,target_object),wire.Error.None)
    references_refresh(&s,core.world_ref(&world,&info))
    net_test_settle(&world,nil,nil)
    testing.expect(t,!core.has(&world.values,source),"it leaves with its target")
}

@(test)
server_publishes_only_changed_rows_at_the_objects_frequency :: proc(t:^testing.T) {
    info:=net_test_info()
    defer delete(info.tables)
    defer delete(info.storages)
    world:Net_Test_World
    net_test_init(&world,context.allocator)
    defer net_test_destroy(&world)
    first:=net_test_body(&world,1)
    second:=net_test_body(&world,2,{1,0,0})
    core.add(&world.objects,first,net_test_replicate(audience=.Always))
    core.add(&world.objects,second,net_test_replicate(audience=.Always))
    net_test_settle(&world,nil,nil)
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
        server_publish(&s,core.world_ref(&world,&info),&app,&outbox,u32(tick))
        net_test_settle(&world,nil,nil)
    }
    before:=s.stats.fragments_published
    core.get(&world.values,first).force=9
    server_publish(&s,core.world_ref(&world,&info),&app,&outbox,4)
    testing.expect_value(t,s.stats.fragments_published-before,u64(1))
    // Ten times a second at 60 ticks: on its turn, once every six ticks, whatever changed between turns.
    core.get(&world.objects,first).update_hz=10
    before=s.stats.fragments_published
    for tick in 5..<17 {
        core.get(&world.values,first).force=f32(tick)
        server_publish(&s,core.world_ref(&world,&info),&app,&outbox,u32(tick))
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
net_test_physical_objects :: proc(w:^Net_Test_World,entities:[2]core.Entity,connected:Connection) {
    core.add(&w.objects,entities[0],net_test_replicate(audience=.Always))
    net_test_own(w,entities[0],connected)
    core.add(&w.objects,entities[1],net_test_replicate(audience=.Always))
    joint:=phys.joint_fixed(entities[1])
    joint.break_force=10
    core.add(&w.joints,entities[0],joint)
    core.add(&w.joint_states,entities[0],phys.Joint_State{})
    core.disable(&w.joints,entities[0])
    net_test_settle(w,nil,nil)
    core.get(&w.values,entities[0]).target=entities[1]
}

@(private)
net_test_physical_convergence :: proc(t:^testing.T,udp:bool) {
    info:=net_test_info()
    defer delete(info.tables)
    defer delete(info.storages)
    worlds:[2]Net_Test_World
    shares:[2]Net_Test_Shared
    apps:[2]host.App
    sessions:[2]Net_Session
    entities:[2][2]core.Entity
    for &world,index in worlds {
        net_test_init(&world,context.allocator)
        entities[index][0]=net_test_body(&world,1)
        entities[index][1]=net_test_body(&world,2,{1,0,0})
        shares[index].info=&info
        apps[index]={info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shares[index]}
        net_test_physics(&world,&shares[index],&apps[index])
        core.get(&world.values,entities[index][0]).force=0
        core.get(&world.values,entities[index][1]).force=0
    }
    net_test_player(&worlds[1])
    defer for &world in worlds {net_test_destroy(&world)}
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
            server_commands(&sessions[0],core.world_ref(&worlds[0],&info),nil,wire.host_poll(&sessions[0].host),&server_events,&worlds[0].remote)
            client_commands(&sessions[1],core.world_ref(&worlds[1],&info),&apps[1],wire.host_poll(&sessions[1].host),&client_events)
            for event in net_test_arrived(&sessions[0]) {if event.kind==.Connected {connected=event.connection}}
            core.value_free(&server_events,type_info_of(Net_Events));core.value_free(&client_events,type_info_of(Net_Events))
            if connected!=0 && sessions[1].status==.Connected {break}
            time.sleep(time.Millisecond)
        }
        if !testing.expect(t,connected!=0 && sessions[1].status==.Connected,"UDP physics handshake did not complete within two seconds") {return}
        net_test_physical_objects(&worlds[0],entities[0],connected)
        time_base=wire.host_time(&sessions[0].host)
        fmt.printf("UDP physics endpoints: server 127.0.0.1:%d, client 127.0.0.1:%d; 599 ticks at 60 Hz, client lead 8 ticks\n",sockets[0].address.port,sockets[1].address.port)
    }
    saw_break,saw_joint:bool
    for tick in 1..<600 {
        now:=time_base+f64(tick)/60
        if !udp {wire.sim_network_advance(&network,now)}
        for &session in sessions {wire.host_update(&session.host,now)}
        server_events,client_events:Net_Events
        server_commands(&sessions[0],core.world_ref(&worlds[0],&info),nil,wire.host_poll(&sessions[0].host),&server_events,&worlds[0].remote)
        for event in net_test_arrived(&sessions[0]) {
            if event.kind==.Connected {
                connected=event.connection
                net_test_physical_objects(&worlds[0],entities[0],connected)
            }
        }
        client_commands(&sessions[1],core.world_ref(&worlds[1],&info),&apps[1],wire.host_poll(&sessions[1].host),&client_events)
        client_reconcile(&sessions[1],core.world_ref(&worlds[1],&info),&apps[1],1.0/60)
        core.value_free(&server_events,type_info_of(Net_Events))
        core.value_free(&client_events,type_info_of(Net_Events))
        if tick==60 {core.enable(&worlds[0].joints,entities[0][0])}
        if tick==90 {core.get(&worlds[0].values,entities[0][0]).force=400}
        if tick==140 {
            core.get(&worlds[0].values,entities[0][0]).force=0
            joint:=phys.joint_prismatic(entities[0][1])
            joint.motor,joint.motor_speed,joint.max_motor=true,1,100
            core.add(&worlds[0].joints,entities[0][0],joint)
            core.add(&worlds[0].joint_states,entities[0][0],phys.Joint_State{})
        }
        if tick==200 {core.get(&worlds[0].joints,entities[0][0]).motor_speed=-1}
        if tick==260 {core.disable(&worlds[0].joints,entities[0][0])}
        worlds[1].input.gamepads[0]={connected=true,down={.South},axes={.Left_X=0.75,.Left_Y=0,.Right_X=0,.Right_Y=0,.Left_Trigger=0,.Right_Trigger=0}}
        for &world,index in worlds {
            net_test_settle(&world,nil,nil)
            world.time.tick=u64(tick+(index==1?8:0))
            net_test_fixed(&world,&shares[index],nil,&apps[index])
        }
        if state,has:=core.get(core.read(&worlds[1].joint_states),entities[1][0]);has && state.broken {saw_break=true}
        if core.has(&worlds[1].joints,entities[1][0]) {saw_joint=true}
        if tick==300 {
            for e in entities[0] {phys.set_velocity(&worlds[0].requests,e,{},{})}
        }
        for &session in sessions {wire.host_update(&session.host,now)}
    }
    testing.expect(t,connected!=0 && sessions[1].status==.Connected)
    testing.expect(t,saw_joint && saw_break)
    testing.expect(t,!core.has(&worlds[1].joints,entities[1][0]))
    client_value,_:=core.get(core.read(&worlds[1].values),entities[1][0])
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
        server_pose,_:=core.get(core.read(&worlds[0].transforms),entities[0][index])
        client_pose,_:=core.get(core.read(&worlds[1].transforms),entities[1][index])
        testing.expectf(t,linalg.length(server_pose.position-client_pose.position)<0.02,"body %d server %v client %v",index,server_pose.position,client_pose.position)
    }
    testing.expect(t,sessions[1].stats.corrected>0)
    testing.expect_value(t,problems[0].count,0)
    testing.expect_value(t,problems[1].count,0)
    if udp {
        server_stats,client_stats:=wire.host_stats(&sessions[0].host),wire.host_stats(&sessions[1].host)
        testing.expect(t,server_stats.packets_sent>0 && server_stats.packets_received>0 && client_stats.packets_sent>0 && client_stats.packets_received>0)
        link,_:=core.get(core.read(&worlds[1].links),entities[1][0])
        r:=replica_of(&sessions[1],link.object)
        testing.expect(t,r!=nil && r.role==.Predicted && r.mode==.Predicted)
        object:=wire.object_of_user(&sessions[0].host,u64(entities[0][0]))
        testing.expect(t,object!=0 && sessions[0].server.objects[object_index(object)].holder==0)
        fmt.printf("UDP physics result: server packets sent/received %d/%d, client %d/%d, corrections %d, physics/net failures 0\n",server_stats.packets_sent,server_stats.packets_received,client_stats.packets_sent,client_stats.packets_received,sessions[1].stats.corrected)
    }
}

@(test)
remote_character_intent_is_replayed_from_its_authoritative_tick :: proc(t:^testing.T) {
    info:=net_test_info()
    defer delete(info.tables)
    defer delete(info.storages)
    world:Net_Test_World
    net_test_init(&world,context.allocator)
    defer net_test_destroy(&world)
    e:=net_test_body(&world,1)
    core.remove(&world.rigids,e)
    core.add(&world.colliders,e,phys.collider_character())
    core.add(&world.characters,e,phys.character_default())
    core.add(&world.moves,e,inp.Move_Input{})
    net_test_settle(&world,nil,nil)
    shared:=Net_Test_Shared{info=&info}
    defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared,&app)
    testing.expect(t,sim.body_valid(&world.physics.world,phys.body_of(core.ref(&world.physics),e)))
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=6,endpoints=2,packets=64}))
    defer wire.sim_network_destroy(&network)
    s:Net_Session
    if !testing.expect(t,net_test_session(&s,&world,&info,&app,&network,1,.Client)) {return}
    defer session_destroy(&s)
    r:=net_test_replica(&s,core.world_ref(&world,&info),e,.Shown,.Server)
    driver_fragment:=net_type(&s,r.type).driver
    if !testing.expect(t,driver_fragment>=0,"a Move_Input replicates its driver") {return}
    words:=make([]u32,s.client.words_per)
    defer delete(words)
    one:=net_test_command(&s,&world,r,1,0,words)
    driver:=Driver_State{has_move=true,move=inp.Move_Input{move={1,0,0}}}
    wire.object_pack(&s.host,r.type,driver_fragment,&driver,words)
    replica_update(&s,core.world_ref(&world,&info),&app,&one)
    three:=net_test_command(&s,&world,r,3,0,words)
    driver.move=inp.Move_Input{move={-1,0,0},look_yaw=0.25}
    wire.object_pack(&s.host,r.type,driver_fragment,&driver,words)
    replica_update(&s,core.world_ref(&world,&info),&app,&three)
    for tick in 1..<4 {
        client_inputs(&s,core.world_ref(&world,&info),u32(tick))
        move,_:=core.get(core.read(&world.moves),e)
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
    info:=net_test_info()
    defer delete(info.tables)
    defer delete(info.storages)
    world:Net_Test_World
    net_test_init(&world,context.allocator)
    defer net_test_destroy(&world)
    world.settings.bodies,world.settings.shapes,world.settings.joints=64,64,32
    driven,joined:[PAIRS]core.Entity
    // The bodies of a client are replicas: the simulation groups them for the network.
    body :: proc(w:^Net_Test_World,id:base.Entity_Id,position:[3]f32) -> core.Entity {
        e:=net_test_body(w,id,position)
        core.add(&w.replicas,e,core.Pose_Target{position=position,rotation=1,scale={1,1,1}})
        return e
    }
    for k in 0..<PAIRS {
        driven[k]=body(&world,base.Entity_Id(2*k+1),{f32(k)*4,0,0})
        joined[k]=body(&world,base.Entity_Id(2*k+2),{f32(k)*4,0,1})
        core.add(&world.joints,joined[k],phys.joint_fixed(driven[k]))
    }
    alone:=body(&world,base.Entity_Id(2*PAIRS+1),{0,0,10})
    net_test_settle(&world,nil,nil)
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
    replica :: proc(c:^Client,index:int,e:core.Entity,role:Role) {c.replicas[index]={object=Object(index),entity=e,role=role,slot=-1}}
    for k in 0..<PAIRS {
        a,_:=core.get(core.read(&world.motions),driven[k])
        b,_:=core.get(core.read(&world.motions),joined[k])
        testing.expectf(t,a.island!=0 && a.island==b.island,"pair %d: islands %d and %d",k,a.island,b.island)
        replica(c,1+k,driven[k],.Predicted)
        replica(c,1+PAIRS+k,joined[k],.Shown)
    }
    replica(c,1+2*PAIRS,alone,.Shown)
    c.replica_high=2+2*PAIRS
    records_capture(&s,core.world_ref(&world,&info),1)
    for k in 0..<PAIRS {testing.expectf(t,replica_critical(&s.desc,&c.replicas[1+PAIRS+k],1),"the replica joined to body %d is not critical",k)}
    testing.expect(t,!replica_critical(&s.desc,&c.replicas[1+2*PAIRS],1))
}

// The child hangs from parent in the hierarchy: a root while parent does not
// replicate, seen with parent once it does, a root again when parent is
// destroyed, and seen with the replacement it is moved under.
@(test)
object_scope_controls_relevance_radius_and_follows_the_replicated_ancestor :: proc(t:^testing.T) {
    info:=net_test_info();defer delete(info.tables);defer delete(info.storages)
    worlds:[2]Net_Test_World
    apps:[2]host.App
    sessions:[2]Net_Session
    for &world,index in worlds {net_test_init(&world,context.allocator);apps[index]={allocator=context.allocator,tick_dt=1.0/60}}
    defer for &world in worlds {net_test_destroy(&world)}
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
    parent:=net_test_body(world,1,{100,0,0})
    child:=net_test_body(world,2,{200,0,0})
    large:=net_test_body(world,3,{10,0,0})
    core.add(&world.parents,child,core.Parent{entity=parent})
    core.add(&world.objects,child,net_test_replicate(audience=.Always,priority=100))
    core.add(&world.objects,large,net_test_replicate(radius=0))
    net_test_settle(world,nil,nil)
    outbox:Net_Outbox;defer core.value_free(&outbox,type_info_of(Net_Outbox))
    connected:Connection
    replacement:=core.NONE
    first_parent,child_object,large_object:Object
    for tick in 1..<200 {
        now:=f64(tick)/60
        wire.sim_network_advance(&network,now)
        for &session in sessions {wire.host_update(&session.host,now)}
        for command in wire.host_poll(&sessions[0].host) {
            if command.kind==.Connected {
                connected=command.connection
                testing.expect(t,view_set(&sessions[0],connected,{},1))
            }
        }
        wire.host_poll(&sessions[1].host)
        if tick==20 {core.add(&world.objects,parent,net_test_replicate(audience=.Custom))}
        if tick==40 {testing.expect(t,relevance_set(&sessions[0],parent,connected,true))}
        if tick==70 {testing.expect(t,relevance_set(&sessions[0],parent,connected,false))}
        if tick==100 {testing.expect(t,relevance_set(&sessions[0],parent,connected,true));core.get(&world.objects,large).radius=10}
        if tick==120 {core.destroy(&world.es,parent)}
        if tick==121 {
            replacement=net_test_body(world,4,{100,0,0})
            core.add(&world.objects,replacement,net_test_replicate(audience=.Custom))
            testing.expect(t,relevance_set(&sessions[0],replacement,connected,true))
            testing.expect(t,replacement!=parent && core.entity_index(replacement)==core.entity_index(parent))
        }
        if tick==165 {core.add(&world.parents,child,core.Parent{entity=replacement})}
        net_test_settle(world,nil,nil)
        server_publish(&sessions[0],core.world_ref(world,&info),&apps[0],&outbox,u32(tick))
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
    info:=net_test_info();defer delete(info.tables);defer delete(info.storages)
    world:Net_Test_World;net_test_init(&world,context.allocator);defer net_test_destroy(&world)
    source:=net_test_body(&world,1)
    initial:=net_test_body(&world,2,{1,0,0})
    target:=net_test_body(&world,3,{0,0,2})
    for &value in world.values.values {value.force=0}
    core.add(&world.joints,source,phys.joint_fixed(initial))
    net_test_settle(&world,nil,nil)
    shared:=Net_Test_Shared{info=&info};defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    net_test_physics(&world,&shared,&app)
    testing.expect_value(t,world.physics.world.joint_count,i32(1))
    core.push(&world.requests.queue,phys.Body_Request{entity=source,kind=.Teleport,position={0,1,0},rotation=quaternion(w=.70710677,x=0,y=.70710677,z=0)})
    net_test_physics(&world,&shared,&app)
    ref:=core.world_ref(&world,&info)
    network:wire.Sim_Network
    testing.expect(t,wire.sim_network_init(&network,{seed=91,endpoints=2,packets=64}));defer wire.sim_network_destroy(&network)
    session:Net_Session
    if !testing.expect(t,net_test_session(&session,&world,&info,&app,&network,0,.Server)) {return}
    defer session_destroy(&session)
    if !testing.expect(t,client_init(&session,ref,&app)) {return}
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
    replica_create(&session,ref,&app,&command)
    net_test_settle(&world,nil,nil)
    testing.expect(t,!core.has(&world.joints,source))
    net_test_physics(&world,&shared,&app)
    testing.expect_value(t,world.physics.world.joint_count,i32(0))
    testing.expect_value(t,wire.object_bind(&session.host,target_object,u64(target)),wire.Error.None)
    references_refresh(&session,ref)
    net_test_settle(&world,nil,nil)
    held,has:=core.get(core.read(&world.joints),source)
    testing.expect(t,has && held.target==target)
    net_test_physics(&world,&shared,&app)
    took,_:=core.get(core.read(&world.joint_states),source)
    testing.expect(t,took.taken && took.target_anchor==state.target_anchor && took.target_rotation==state.target_rotation)
    testing.expect_value(t,world.physics.world.joint_count,i32(1))
    r:=replica_of(&session,object)
    if !testing.expect(t,r!=nil) {return}
    // Retargeted to an entity that is replicated, with frames of its own.
    joint.target=initial
    joint.anchor={.2,0,0}
    state.target_anchor={-1,.5,0}
    retarget:=net_test_command(&session,&world,r,2,0,words)
    wire.object_pack(&session.host,type,joint_fragment,&joint,words)
    wire.object_pack(&session.host,type,state_fragment,&state,words)
    replica_update(&session,ref,&app,&retarget)
    net_test_settle(&world,nil,nil)
    net_test_physics(&world,&shared,&app)
    took,_=core.get(core.read(&world.joint_states),source)
    testing.expect(t,took.taken && took.target_anchor==state.target_anchor)
    generation:=world.physics.world.joints[0].generation
    joint.motor=true;joint.motor_speed=1;joint.max_motor=1
    retune:=net_test_command(&session,&world,r,3,0,words)
    wire.object_pack(&session.host,type,joint_fragment,&joint,words)
    wire.object_pack(&session.host,type,state_fragment,&state,words)
    replica_update(&session,ref,&app,&retune)
    net_test_settle(&world,nil,nil)
    net_test_physics(&world,&shared,&app)
    testing.expect_value(t,world.physics.world.joints[0].generation,generation)
    target_pose,_:=core.get(core.read(&world.transforms),initial)
    pose_apply(&session,ref,initial,net_type(&session,net_test_type(&session,ref,initial)),Pose{position=target_pose.position,rotation=target_pose.rotation,scale={2,1,1}},Motion_State{},false)
    net_test_settle(&world,nil,nil)
    net_test_physics(&world,&shared,&app)
    scaled,_:=core.get(core.read(&world.transforms),initial)
    testing.expect_value(t,scaled.scale,[3]f32{2,1,1})
    took,_=core.get(core.read(&world.joint_states),source)
    testing.expect(t,took.taken && took.target_anchor==state.target_anchor)
    testing.expect_value(t,world.physics.world.joint_count,i32(1))
}
