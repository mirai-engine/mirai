package multiplayer

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:host"
import wire "mirai:net"

// The server half: entities with Replicate are net objects for as long as
// they have the component. After every tick, the pose, the motion and the
// components of the tables written since the last one are handed to the host,
// which sends what really changed.

@(private)
Server_Object :: struct {
    object:Object,
    entity:core.Entity,
    type:wire.Type_Id,
    moving:bool,           // a simulation moved it at the last publish
    owner:Connection,
    holder:Connection,     // Delegated: the client simulating it now
    filter:wire.Filter,
    priority,radius:f32,
    ancestor:core.Entity,  // the closest one above it with Replicate: its parent on the network
    sections:[wire.OBJECT_GROUPS]core.Entity, // the references of the sections it is in: first the one it hangs from (NONE: the root), then each other whose box holds it
    placed:[2]u64,         // the stamp and the layout of its World_Transform when its sections were last looked at
    told:bool,             // the host has the groups of its sections
    member:base.Entity_Id, // its Id, while it is of the scene of the section it hangs from (scene.Section_Member); 0 otherwise
    parent:Object,         // the object of ancestor the host was told
    bindings:u64,
    stamps:[wire.MAX_FRAGMENTS]u64,
    layouts:[wire.MAX_FRAGMENTS]u64,
    position:[3]f32,       // the last one the host was told
    off:u16,               // the components off it last published (Pose.off)
    disabled:bool,         // it was off when it last published (Pose.disabled)
    visibility:u32,        // the bits the host was told (Visibility.mask)
    retype:bool,           // its entity gained or lost what its type lists: it is given the type of what it has now
    predict:bool,          // Replicate.predict as it last published (Pose.predict)
}

// Where a connection looks from: the entity it owns first.
@(private)
View :: struct {position:[3]f32,entity:core.Entity,set:bool}

// What a connection knows of the world of the server.
@(private)
Server_Peer :: struct {
    connection:Connection,
    told:bool,  // it heard the change of the world it is in now
    ready:bool, // it said it is in that world
    held:bool,  // it sees no object and hears nothing of the game (wire.connection_hold)
    sees:u32,   // the visibility bits the host was told (Visibility.sees of its seat)
}

// A group a connection gains or loses (none: all), which the host had no room for.
@(private)
Group_Change :: struct {
    connection:Connection,
    group:int,
    has:bool,
}

@(private)
Server :: struct {
    objects:[]Server_Object, // by object index
    views:[]View,            // by connection index
    peers:[]Server_Peer,     // by connection index
    visibility:[2]u64,       // the versions of Visibility and of input.Seat the bits of the objects and of the connections were read for, plus one
    layouts:[]u64,           // by table of the world info: the layout of each replicated component the types of the objects were looked at for
    changed:[]bool,          // likewise: it changed since the publish before
    moved:[2]u64,            // the layouts of core.Motion and of input.Move_Input, likewise
    ancestry:[3]u64,         // the version of the Hierarchy and the layouts of Replicate and of Scene_Reference the ancestors and sections follow
    boxes:[2]u64,            // the version of Scene_Reference and the stamps of the World_Transform of its rows the sections of each object were looked at for
    section_boxes:[dynamic]Section_Box, // the boxes of the sections as of boxes
    scene:base.Asset_Id,     // the scene the world is, and the number of that change (scene.Scene_Root)
    changes:u32,
    clock:core.Clock,        // the one the clients were told
    sections:[]base.Entity_Id, // by group of the host minus one: the Id of the reference of the section it stands for
    section_count:int,
    sections_full:bool,      // it said there are more sections than groups
    loaded:[]u64,            // by connection index, a bit per group: the sections each connection has loaded
    groups:[dynamic]Group_Change,
    gone:[dynamic]Gone_Due,
    notices:[dynamic]Gone_Notice, // which the host had no room for
}

// The box of a section where it is, and the box of the world around it.
@(private)
Section_Box :: struct {
    entity:core.Entity,
    reference:scene.Scene_Reference,
    pose:mm.Transform,
    bounds:mm.Aabb,
}

// What went from a section, for a connection that has it loaded (none: every one).
@(private)
Gone_Notice :: struct {
    connection:Connection,
    message:Net_Gone,
}

// A section a connection loaded: what of its scene is gone it is yet to hear,
// past the first sent.
@(private)
Gone_Due :: struct {
    connection:Connection,
    section:base.Entity_Id,
    sent:int,
}

@(private)
filter_of :: proc "contextless" (audience:Audience) -> wire.Filter {
    switch audience {
    case .Near:   return .Spatial
    case .Always: return .Always
    case .Owner:  return .Owner
    }
    return .Spatial
}

// The ticks between the turns of an object of update_hz: the host keeps its interval and its turns.
@(private)
publish_interval :: proc(s:^Net_Session,update_hz:f32) -> int {
    return update_hz>0?int(clamp(math.ceil(f64(s.host.desc.tick_rate)/f64(update_hz)),1,f64(max(u32)))):1
}

@(private)
server_init :: proc(s:^Net_Session,allocator:runtime.Allocator) -> bool {
    error:runtime.Allocator_Error
    if s.server.objects,error=make([]Server_Object,s.desc.max_objects,allocator);error!=nil {return false}
    if s.server.views,error=make([]View,wire.MAX_CONNECTIONS,allocator);error!=nil {return false}
    if s.server.peers,error=make([]Server_Peer,wire.MAX_CONNECTIONS,allocator);error!=nil {return false}
    s.server.clock=core.CLOCK_DEFAULT
    if s.server.sections,error=make([]base.Entity_Id,s.host.desc.replication.groups,allocator);error!=nil {return false}
    if s.server.layouts,error=make([]u64,len(s.fragments),allocator);error!=nil {return false}
    if s.server.changed,error=make([]bool,len(s.fragments),allocator);error!=nil {return false}
    if s.server.loaded,error=make([]u64,wire.MAX_CONNECTIONS*loaded_words(&s.server),allocator);error!=nil {return false}
    s.server.section_boxes=make([dynamic]Section_Box,allocator)
    s.server.groups=make([dynamic]Group_Change,allocator)
    s.server.gone=make([dynamic]Gone_Due,allocator)
    s.server.notices=make([dynamic]Gone_Notice,allocator)
    return true
}

@(private)
server_destroy :: proc(s:^Net_Session) {
    delete(s.server.objects,s.allocator)
    delete(s.server.views,s.allocator)
    delete(s.server.peers,s.allocator)
    delete(s.server.sections,s.allocator)
    delete(s.server.layouts,s.allocator)
    delete(s.server.changed,s.allocator)
    delete(s.server.loaded,s.allocator)
    delete(s.server.section_boxes)
    delete(s.server.groups)
    delete(s.server.gone)
    delete(s.server.notices)
    s.server={}
}

// Words of Server.loaded a connection takes.
@(private)
loaded_words :: proc "contextless" (server:^Server) -> int {return (len(server.sections)+63)/64}

// The bits of the sections a connection has loaded, by connection index.
@(private)
loaded_of :: proc "contextless" (server:^Server,index:int) -> []u64 {
    words:=loaded_words(server)
    return server.loaded[index*words:][:words]
}

// What an entity replicates is what it has: when the rows of a replicated
// component, of core.Motion or of input.Move_Input come or go, each object
// whose entity no longer has what its type lists is marked, and the publish
// gives it the type of what it has now (object_retype).
@(private)
server_kinds :: proc(s:^Net_Session,w:core.World_Ref) {
    server:=&s.server
    motions,moves:=core.world_table_of(w,core.Motion),core.world_table_of(w,input.Move_Input)
    count:=0
    for kind,table in s.fragments {
        layout:u64
        if kind!=wire.FRAGMENT_NONE {layout=core.world_table_at(w,&w.info.tables[table]).layout}
        server.changed[table]=layout!=server.layouts[table]
        server.layouts[table]=layout
        count+=int(server.changed[table])
    }
    seen:=[2]u64{core.layout(motions),moves!=nil?core.layout(moves):0}
    moved:=seen!=server.moved
    server.moved=seen
    if count==0 && !moved {return}
    for &slot in server.objects {
        if slot.object==0 || slot.retype {continue}
        e:=slot.entity
        t:=net_type(s,slot.type)
        if moved && ((core.staged(motions,e)!=nil)!=(t.motion>=0) || (moves!=nil && core.staged(moves,e)!=nil)!=(t.driver>=0)) {
            slot.retype=true
            continue
        }
        if count==0 {continue}
        for changed,table in server.changed {
            if !changed {continue}
            info:=&w.info.tables[table]
            if (core.raw_staged(core.world_table_at(w,info),info.info,e)!=nil)!=type_has(t,table) {slot.retype=true;break}
        }
    }
}

// Whether a type lists the replicated component of a table.
@(private)
type_has :: proc "contextless" (t:^Net_Type,table:int) -> bool {
    for held in t.tables[:t.count] {
        if held==table {return true}
    }
    return false
}

// Gives the object of an entity the type of what the entity has now, with its
// whole state: its replicas go on, of that type. False while the host has no
// room for it, and it is tried again at the next publish.
@(private)
object_retype :: proc(s:^Net_Session,w:core.World_Ref,slot:^Server_Object,disabled:bool) -> bool {
    h:=&s.host
    e:=slot.entity
    kinds:[wire.MAX_FRAGMENTS]wire.Fragment_Id
    count,fits:=entity_kinds(s,w,e,&kinds)
    if !fits {
        core.report(s.problems,e,"net.object","the replicated components it gained do not travel: it has more than an object carries (%d, besides its pose, motion and driver); replicate fewer of them",COMPONENTS)
        return true
    }
    type,composed:=wire.type_compose(&s.protocol,kinds[:count])
    if !composed {
        core.report(s.problems,e,"net.object","the replicated components it gained do not travel: they take more than the state of an object, or the %d kinds of replicated entities of the protocol are in use; replicate fewer fields, or fewer different sets of components",wire.TYPE_CAPACITY)
        return true
    }
    if type==slot.type {return true}
    local,has_pose:=core.get(core.read(core.world_table_of(w,core.Transform)),e)
    if !has_pose {return true}
    t:=net_type(s,type)
    ids:=core.world_table_of(w,core.Id)
    source,_:=core.get(core.read(core.world_table_of(w,scene.Prefab_Source)),e)
    pose:=Pose{id=core.id_of(core.read(ids),e),prefab=source.prefab,sections=section_ids(ids,slot.sections),position=local.position,rotation=local.rotation,scale=local.scale,off=components_off(w,e,t),disabled=disabled,predict=slot.predict}
    // Through rawptr: the host lets go of these locals below, which the escape analysis of Odin cannot tell.
    sources:[wire.MAX_FRAGMENTS]rawptr
    sources[0]=rawptr(&pose)
    motion,_:=motion_read(w,e)
    if t.motion>=0 {sources[t.motion]=rawptr(&motion)}
    driver:=driver_read(w,e)
    if t.driver>=0 {sources[t.driver]=rawptr(&driver)}
    for k in 0..<t.count {
        info:=&w.info.tables[t.tables[k]]
        sources[t.first+k]=core.raw_staged(core.world_table_at(w,info),info.info,e)
    }
    if wire.object_retype(h,slot.object,type,sources)!=.None {return false}
    for fragment in 0..<count {wire.object_set_source(h,slot.object,fragment,nil)}
    slot.type,slot.off,slot.disabled,slot.moving=type,pose.off,disabled,true
    // What it publishes from now on is compared with what this creation carried.
    slot.stamps,slot.layouts,slot.bindings={},{},0
    s.stats.retyped+=1
    return true
}

// The visibility bits of the objects (Visibility.mask) and of the connections
// (Visibility.sees of their seats), told to the host when Visibility or the
// seats change; what the full frame refuses is told at the next publish.
@(private)
server_visibility :: proc(s:^Net_Session,w:core.World_Ref) {
    server:=&s.server
    h:=&s.host
    visibility:=core.world_table_of(w,Visibility)
    if visibility==nil {return}
    seats:=core.world_table_of(w,input.Seat)
    seen:=[2]u64{core.version(visibility)+1,seats!=nil?core.version(seats)+1:1}
    if seen==server.visibility {return}
    told:=true
    for &slot in server.objects {
        if slot.object==0 {continue}
        mask:=visibility_of(visibility,slot.entity).mask
        if slot.visibility==mask {continue}
        if wire.object_set_visibility(h,slot.object,mask)==.None {slot.visibility=mask} else {told=false}
    }
    for &peer in server.peers {
        if peer.connection==0 {continue}
        sees:u32
        if seats!=nil {
            for row in 0..<core.count(seats) {
                if Connection(seats.values[row].peer)==peer.connection {sees=visibility_of(visibility,core.entity_at(seats,row)).sees;break}
            }
        }
        if peer.sees==sees {continue}
        if wire.connection_set_visibility(h,peer.connection,sees)==.None {peer.sees=sees} else {told=false}
    }
    if told {server.visibility=seen}
}

@(private)
visibility_of :: proc(visibility:^core.Table(Visibility),e:core.Entity) -> Visibility {
    value,_:=core.get(core.read(visibility),e)
    return value
}

// The datagrams received since the last frame, as changes to the world and as events.
@(private)
server_commands :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets,commands:[]wire.Command,inputs:^Remote_Inputs) {
    h:=&s.host
    es:=core.world_entities(w)
    for &command in commands {
        #partial switch command.kind {
        case .Connected:
            s.connections+=1
            s.joined+=1
            // Until it owns something or the game says where it looks from, it sees everything.
            wire.connection_set_view(h,command.connection,{},-1)
            // Its player is seated once its client says who it is.
            index:=object_index(Object(command.connection))
            if index<len(inputs.entries) || resize(&inputs.entries,index+1)==nil {
                inputs.entries[index]={connection=command.connection,player=s.follows?0:u64(command.connection)}
            } else {
                // Without room for its inputs it is closed, and may connect again.
                wire.host_disconnect(h,command.connection,.Capacity)
                core.report(s.problems,core.NONE,"net.memory","a connection was closed: out of memory for the inputs of its player; free memory, or lower Net_Settings.max_clients")
            }
            s.server.peers[index]={connection=command.connection,held=s.follows}
            s.server.visibility={}
            mem.zero_slice(loaded_of(&s.server,index))
            append(&s.arrived,Connection_Event{kind=.Connected,connection=command.connection})
            // Without the world to load, it is in it already.
            if !s.follows {append(&s.arrived,Connection_Event{kind=.Entered,connection=command.connection})}
        case .Disconnected:
            s.connections-=1
            s.left+=1
            s.lost+=u64(command.reason!=.Closed)
            s.server.views[object_index(Object(command.connection))]={}
            s.server.peers[object_index(Object(command.connection))]={}
            mem.zero_slice(loaded_of(&s.server,object_index(Object(command.connection))))
            if entry:=remote_entry(inputs,command.connection);entry!=nil {entry^={}}
            for len(inputs.entries)>0 && inputs.entries[len(inputs.entries)-1].connection==0 {pop(&inputs.entries)}
            append(&s.arrived,Connection_Event{kind=.Disconnected,connection=command.connection,reason=command.reason})
        case .Object_Updated:
            // The holder of a lent object sent its state.
            slot:=&s.server.objects[object_index(command.object)]
            if slot.object!=command.object || !core.alive(es,slot.entity) {continue}
            t:=net_type(s,slot.type)
            pose:Pose
            motion:Motion_State
            wire.object_read(h,&command,0,&pose,max(u64))
            if t.motion>=0 {wire.object_read(h,&command,t.motion,&motion,max(u64))}
            pose_apply(s,w,slot.entity,t,pose,motion,false)
            components_apply(s,w,slot.entity,t,&command,command.mask)
        case .Authority_Changed:
            slot:=&s.server.objects[object_index(command.object)]
            if slot.object!=command.object {continue}
            slot.holder=command.connection
            if !core.alive(es,slot.entity) {continue}
            remote_set(core.world_table_of(w,core.Remote),slot.entity,command.connection!=0)
            // The server simulates what nobody holds.
            if command.connection==0 {core.remove(core.world_table_of(w,core.Pose_Target),slot.entity)}
        case .Event:
            event_deliver(s,w,&command,inputs)
        }
    }
    server_world_update(s)
    server_gone(s,w,assets)
}

// Server: what of the sections the connections loaded is gone, as each one
// hears it, and what went from a section, as every one does; what the host
// has no room for is sent at the next step.
@(private)
server_gone :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets) {
    server:=&s.server
    h:=&s.host
    kept:=0
    for notice in server.notices {
        notice:=notice
        if wire.event_send(h,wire.Event_Id(s.own.gone),0,&notice.message,notice.connection)==.None {continue}
        server.notices[kept]=notice
        kept+=1
    }
    base.truncate(&server.notices,kept)
    if len(server.gone)==0 {return}
    es:=core.world_entities(w)
    kept=0
    for due in server.gone {
        due:=due
        peer:=&server.peers[object_index(Object(due.connection))]
        if peer.connection!=due.connection || !peer.ready {continue}
        ids:=make([dynamic]base.Entity_Id,context.temp_allocator)
        documents:scene.Documents
        if assets!=nil {documents=scene.assets_documents(assets)}
        scene.section_gone(w,documents,core.entity_of(es,due.section),&ids)
        for due.sent<len(ids) {
            message:=Net_Gone{section=due.section,changes=server.changes}
            message.count=u8(copy(message.ids[:],ids[due.sent:]))
            if wire.event_send(h,wire.Event_Id(s.own.gone),0,&message,due.connection)!=.None {break}
            due.sent+=int(message.count)
        }
        if due.sent<len(ids) {
            server.gone[kept]=due
            kept+=1
        }
    }
    base.truncate(&server.gone,kept)
}

// Server: an entity of the scene of a section, by its Id, that is not in it
// any more while the section is loaded: every client that has the section
// loaded takes it out of it, whether it sees it or not. A section without a
// group (more sections than groups) tells every client.
@(private)
gone_tell :: proc(s:^Net_Session,w:core.World_Ref,section:core.Entity,id:base.Entity_Id) {
    references:=core.world_table_of(w,scene.Scene_Reference)
    if !s.follows || id==0 || references==nil {return}
    reference,found:=core.get(core.read(references),section)
    if !found || reference.loaded=={} {return}
    server:=&s.server
    message:=Net_Gone{section=core.id_of(core.read(core.world_table_of(w,core.Id)),section),changes=server.changes,count=1}
    message.ids[0]=id
    group:=section_group(s,message.section,false)
    if group==0 {
        if wire.event_send(&s.host,wire.Event_Id(s.own.gone),0,&message,0)!=.None {append(&server.notices,Gone_Notice{message=message})}
        return
    }
    bit:=group-1
    for &peer,index in server.peers {
        if peer.connection==0 || loaded_of(server,index)[bit/64]&(1<<uint(bit%64))==0 {continue}
        if wire.event_send(&s.host,wire.Event_Id(s.own.gone),0,&message,peer.connection)!=.None {append(&server.notices,Gone_Notice{peer.connection,message})}
    }
}

// The Id of e while it is of the scene of section, the one it hangs from: what
// a client that has that section loaded has of it.
@(private)
member_of :: proc(w:core.World_Ref,e,section:core.Entity) -> base.Entity_Id {
    if section==core.NONE {return 0}
    if members:=core.world_table_of(w,scene.Section_Member);members!=nil && core.raw_row(core.raw(members),e)<0 {return 0}
    return core.id_of(core.read(core.world_table_of(w,core.Id)),e)
}

// A message of the game that arrived waits in the session for the next tick, which has it in Net_Events.
@(private)
event_deliver :: proc(s:^Net_Session,w:core.World_Ref,command:^wire.Command,inputs:^Remote_Inputs) {
    if int(command.event)>=len(s.events) || own_deliver(s,w,command,inputs) || !in_world(s,command.connection) {return}
    event:=s.events[command.event]
    if len(s.received)>=PENDING_EVENTS {
        s.stats.events_dropped+=1
        core.report(s.problems,core.NONE,"net.events_pending","a message of type %v was dropped: %d messages wait for the next tick of this world, which runs none (it is paused); resume it, or have the other ends send less while it is paused",event.type,PENDING_EVENTS)
        return
    }
    item:=Received{type=event.type,sender=command.connection,size=u16(event.size)}
    payload:=s.scratch[:event.size]
    mem.zero_slice(payload)
    if event.size>0 && !wire.event_read(&s.host,command,raw_data(payload)) {return}
    copy(item.data[:],payload)
    if command.object!=0 {item.about=core.Entity(wire.object_user(&s.host,command.object))}
    if _,error:=append(&s.received,item);error!=nil {
        s.stats.events_dropped+=1
        core.report(s.problems,core.NONE,"net.memory","a message of type %v was dropped: out of memory to keep it until the next tick; free memory",event.type)
        return
    }
    s.stats.events_received+=1
}

// The input each connection sent for the tick about to be simulated.
@(private)
server_inputs :: proc(s:^Net_Session,tick:u32,inputs:^Remote_Inputs) {
    for &entry in inputs.entries {
        if entry.connection==0 {continue}
        packet:Input_Packet
        status:=wire.input_take(&s.host,entry.connection,tick,&packet)
        entry.status=status
        entry.tick=tick
        if status==.None {
            entry.actions={}
            entry.view=0
            entry.has_look=false
            continue
        }
        entry.actions=status==.Repeated?input.remote_repeated(packet.actions):packet.actions
        // A look that was of another tick is not compared with this one's.
        entry.look,entry.look_behind={packet.look_yaw,packet.look_pitch},packet.look_behind
        entry.has_look=packet.has_look && (status==.Fresh || packet.look_behind==0)
        behind:=f64(packet.view_behind)
        if packet.has_view && s.desc.rewind_tolerance>0 {
            if stats,ok:=wire.connection_stats(&s.host,entry.connection);ok {
                corrected:bool
                behind,corrected=view_checked(behind,expected_behind(&s.host,stats),f64(s.desc.rewind_tolerance)*f64(s.host.desc.tick_rate))
                if corrected {s.stats.views_corrected+=1}
            }
        }
        entry.view=packet.has_view?max(f64(tick)-behind,0):0
    }
}

// Ticks behind its own that a client shows the others, as the server sees it: the round trip
// and four jitters (the clock puts the client half a round trip and two jitters ahead, and the
// display as much behind), the input lead and the interpolation delay (wire.clock_target and
// clock_display_target). The bias the client adds to the lead is not known here.
@(private)
expected_behind :: proc(h:^wire.Host,stats:wire.Connection_Stats) -> f64 {
    d:=&h.desc.replication
    return f64(stats.rtt+4*stats.jitter)*f64(h.desc.tick_rate)+f64(d.input_lead)+f64(d.interpolation_delay)
}

// The view a client claims, in ticks behind, unless it is farther than tolerance from the one
// expected: then the expected one.
@(private)
view_checked :: proc(claimed,expected,tolerance:f64) -> (behind:f64,corrected:bool) {
    if abs(claimed-expected)>tolerance {return expected,true}
    return claimed,false
}

// After the tick: objects for the entities that gained Replicate, none for
// those that lost it, and the state of what was written since the last publish.
@(private)
server_publish :: proc(s:^Net_Session,w:core.World_Ref,outbox:^Net_Outbox,tick:u32) {
    server:=&s.server
    h:=&s.host
    es:=core.world_entities(w)
    objects:=core.world_table_of(w,Replicate)
    links:=core.world_table_of(w,Net_Link)
    transforms:=core.world_table_of(w,core.Transform)
    worlds:=core.world_table_of(w,core.World_Transform)
    ids:=core.world_table_of(w,core.Id)
    sources:=core.world_table_of(w,scene.Prefab_Source)
    moves:=core.world_table_of(w,input.Move_Input)
    hierarchy:=core.ref(core.world_storage_of(w,core.Hierarchy))
    seats:=core.world_table_of(w,input.Seat)
    for &slot in server.objects {
        if slot.object==0 {continue}
        if core.alive(es,slot.entity) && replicated(w,objects,slot.entity) {continue}
        if wire.object_destroy(h,slot.object)==.Full {continue}
        // Destroyed while its section is loaded: whoever has the section loses it, seen or not.
        if !core.alive(es,slot.entity) {gone_tell(s,w,slot.sections[0],slot.member)}
        if core.alive(es,slot.entity) {
            core.remove(links,slot.entity)
            if slot.holder!=0 {remote_set(core.world_table_of(w,core.Remote),slot.entity,false)}
        }
        slot={}
        s.stats.objects-=1
    }
    // The ancestors and the sections change only with the hierarchy, with what replicates or with the references.
    references:=core.world_table_of(w,scene.Scene_Reference)
    // .ptr spelled out: a field reached through using in a ternary is loaded before its nil check (see ODIN_WORKAROUNDS).
    ancestry:=[3]u64{hierarchy.ptr!=nil?hierarchy.ptr.version:0,core.layout(objects),references!=nil?core.layout(references):0}
    if ancestry!=server.ancestry {
        server.ancestry=ancestry
        for &slot in server.objects {
            if slot.object==0 {continue}
            slot.ancestor=replicated_ancestor(w,hierarchy,objects,slot.entity)
            if section:=section_of(hierarchy,references,slot.entity);section!=slot.sections[0] {
                // Out of the section of its scene, whoever has that section loses it there.
                gone_tell(s,w,slot.sections[0],slot.member)
                slot.sections,slot.placed,slot.told={0=section},{},false
                slot.stamps[0],slot.layouts[0]=0,0
            }
            slot.member=member_of(w,slot.entity,slot.sections[0])
        }
    }
    // What a section that moved, loaded or changed its box holds is looked at again.
    if boxes:=sections_seen(references,worlds);boxes!=server.boxes {
        server.boxes=boxes
        section_boxes(&server.section_boxes,references,worlds)
        for &slot in server.objects {slot.placed={}}
    }

    server_kinds(s,w)
    waiting:=0
    // The rows off too: an object made while the entity was on stays while it is off (kept_off).
    for row in 0..<len(objects.entities) {
        e:=objects.entities[row]
        config:=objects.values[row]
        object:=wire.object_of_user(h,u64(e))
        disabled:=row>=core.count(objects)
        if disabled && (object==0 || !replicated(w,objects,e)) {continue}
        if object==0 {
            // Made after the object of its ancestor, in this publish or a later one.
            ancestor:=replicated_ancestor(w,hierarchy,objects,e)
            parent:Object
            if ancestor!=core.NONE {
                if parent=wire.object_of_user(h,u64(ancestor));parent==0 {continue}
            }
            object=server_create(s,w,e,config,ancestor,parent)
            if object==0 {continue}
            core.add(links,e,Net_Link{object=object})
            continue
        }
        slot:=&server.objects[object_index(object)]
        if slot.object!=object || slot.entity!=e {continue}
        // What a client holds comes from it, of the type it was lent with; of what each end simulates only the creation travels.
        if slot.retype && slot.holder==0 && config.simulation!=.Each && object_retype(s,w,slot,disabled) {slot.retype=false}
        t:=net_type(s,slot.type)
        if owner:=owner_of(w,e);slot.owner!=owner && wire.object_set_owner(h,object,owner)==.None {slot.owner=owner}
        if slot.priority!=config.priority && wire.object_set_priority(h,object,config.priority)==.None {slot.priority=config.priority}
        // In other sections, its pose says so again, and the host puts it in their groups.
        if row_changed(core.raw(worlds),e,&slot.placed[0],&slot.placed[1]) {
            if sections:=sections_of(s,server.section_boxes[:],worlds,hierarchy,e,slot.sections[0]);sections!=slot.sections {
                slot.sections,slot.told=sections,false
                slot.stamps[0],slot.layouts[0]=0,0
            }
        }
        if !slot.told && wire.object_set_groups(h,object,section_groups(s,ids,slot.sections))==.None {slot.told=true}
        if interval:=publish_interval(s,config.update_hz);wire.object_poll_interval(h,object)!=interval {wire.object_set_poll_interval(h,object,interval)}
        if server_scope(s,slot,config,true) {waiting+=1}
        // What a client holds comes from it, and of what each end simulates only the creation travels.
        if slot.holder!=0 || config.simulation==.Each {continue}
        if !wire.object_poll_due(h,object,tick) {continue}
        local,has_pose:=core.get(core.read(transforms),e)
        if !has_pose {continue}
        bindings:=wire.object_binding_revision(h)
        references_changed:=bindings!=slot.bindings
        references_published:=true
        // A write the full frame refused keeps the previous stamp, so the next interval sends it again.
        stamp,layout:=slot.stamps[0],slot.layouts[0]
        off:=components_off(w,e,t)
        moved:=row_changed(core.raw(transforms),e,&slot.stamps[0],&slot.layouts[0])
        // Off, its pose goes once, as it turns off, and what changed meanwhile goes as it turns on.
        send:=disabled!=slot.disabled || !disabled && (moved || off!=slot.off || config.predict!=slot.predict)
        if send || moved {
            written:=true
            if send {
                prefab:base.Asset_Id
                if sources!=nil {
                    if source:=(^scene.Prefab_Source)(core.raw_find(core.raw(sources),type_info_of(scene.Prefab_Source),e));source!=nil {prefab=source.prefab}
                }
                pose:=Pose{id=core.id_of(core.read(ids),e),prefab=prefab,sections=section_ids(ids,slot.sections),position=local.position,rotation=local.rotation,scale=local.scale,off=off,disabled=disabled,predict=config.predict}
                written=wire.object_write(h,object,0,&pose)==.None
                if written {slot.off,slot.disabled,slot.predict=off,disabled,config.predict}
                if written {s.stats.fragments_published+=1}
            }
            position:=local.position
            if world,has:=core.get(core.read(worlds),e);has {position=world.position}
            if linalg.length2(position-slot.position)>1 {
                if wire.object_set_position(h,object,position)==.None {slot.position=position} else {written=false}
            }
            // The view of a connection follows what it owns in the world: not its seat.
            if slot.owner!=0 && (seats==nil || !core.has(seats,e)) && !view_follow(s,w,objects,e,slot.owner,position) {written=false}
            if !written {slot.stamps[0],slot.layouts[0]=stamp,layout}
        }
        if disabled {continue}
        if t.motion>=0 {
            motion,awake:=motion_read(w,e)
            if awake || slot.moving {
                if wire.object_write(h,object,t.motion,&motion)==.None {
                    s.stats.fragments_published+=1
                    slot.moving=awake
                } else {slot.moving=true}
            }
        }
        if t.driver>=0 {
            stamp,layout=slot.stamps[t.driver],slot.layouts[t.driver]
            changed:=row_changed(core.raw(moves),e,&slot.stamps[t.driver],&slot.layouts[t.driver])
            if changed {
                value:=driver_read(w,e)
                if wire.object_write(h,object,t.driver,&value)==.None {s.stats.fragments_published+=1} else {slot.stamps[t.driver],slot.layouts[t.driver]=stamp,layout}
            }
        }
        for k in 0..<t.count {
            fragment:=t.first+k
            info:=&w.info.tables[t.tables[k]]
            table:=core.world_table_at(w,info)
            stamp,layout=slot.stamps[fragment],slot.layouts[fragment]
            names:=t.references&(1<<wire.Fragment_Mask(fragment))!=0
            changed:=row_changed(table,e,&slot.stamps[fragment],&slot.layouts[fragment])
            if !changed && !(references_changed && names) {continue}
            value:=core.raw_find(table,info.info,e)
            if value==nil {continue}
            if wire.object_write(h,object,fragment,value)==.None {s.stats.fragments_published+=1} else {
                slot.stamps[fragment],slot.layouts[fragment]=stamp,layout
                if names {references_published=false}
            }
        }
        if references_published {slot.bindings=bindings}
    }
    // An ancestor later in the rows has its object now: what waited for it does not hide for a tick.
    if waiting>0 {
        for &slot in server.objects {
            if slot.object==0 || slot.ancestor==core.NONE {continue}
            if config:=(^Replicate)(core.raw_find(core.raw(objects),type_info_of(Replicate),slot.entity));config!=nil {server_scope(s,&slot,config^,false)}
        }
    }
    server_visibility(s,w)
    events_send(s,outbox)
    wire.host_publish(h,tick)
}

// The view of a connection follows the first entity it owns.
@(private)
view_follow :: proc(s:^Net_Session,w:core.World_Ref,objects:^core.Table(Replicate),e:core.Entity,owner:Connection,position:[3]f32) -> bool {
    view:=&s.server.views[object_index(Object(owner))]
    if view.entity!=e {
        if !core.has(objects,view.entity) || owner_of(w,view.entity)!=owner || !core.alive(core.world_entities(w),view.entity) {view^={entity=e}}
    }
    if view.entity==e && (!view.set || linalg.length2(position-view.position)>1) {
        if wire.connection_set_view(&s.host,owner,position,s.desc.view_radius)==.Full {return false}
        view.position,view.set=position,true
    }
    return true
}

// The reference of the section e is in: the closest entity above it with
// scene.Scene_Reference; NONE for the root.
@(private)
section_of :: proc(hierarchy:core.Ref(core.Hierarchy),references:^core.Table(scene.Scene_Reference),e:core.Entity) -> core.Entity {
    if references==nil {return core.NONE}
    for at:=core.parent_of(hierarchy,e);at!=core.NONE;at=core.parent_of(hierarchy,at) {
        if core.has(references,at) {return at}
    }
    return core.NONE
}

// The sections e is in: home, the one it hangs from, and, when that is one,
// each other whose box holds where e is, but those around home, which hold
// it already. In more than an object has groups for, it is in home alone,
// and that is the problem net.sections.
@(private)
sections_of :: proc(s:^Net_Session,boxes:[]Section_Box,worlds:^core.Table(core.World_Transform),hierarchy:core.Ref(core.Hierarchy),e,home:core.Entity) -> (sections:[wire.OBJECT_GROUPS]core.Entity) {
    sections[0]=home
    if home==core.NONE || len(boxes)==0 {return}
    place,placed:=core.get(core.read(worlds),e)
    if !placed {return}
    count:=1
    rows: for &box in boxes {
        r:=box.entity
        if r==home || !mm.aabb_contains_point(box.bounds,place.position) || !scene.section_holds(box.reference,box.pose,place.position) {continue}
        for at:=core.parent_of(hierarchy,home);at!=core.NONE;at=core.parent_of(hierarchy,at) {
            if at==r {continue rows}
        }
        if count==len(sections) {
            core.report(s.problems,e,"net.sections","it is in more than %d sections at once, whose boxes overlap where it is: it reaches only the clients that have the section it hangs from; overlap fewer sections there",len(sections))
            return {0=home}
        }
        sections[count]=r
        count+=1
    }
    return
}

// The boxes of the sections, where they are, for sections_of: made again when
// sections_seen changes, so an object that moves reads them in a row and
// looks closer only at those whose box of the world holds it.
@(private)
section_boxes :: proc(out:^[dynamic]Section_Box,references:^core.Table(scene.Scene_Reference),worlds:^core.Table(core.World_Transform)) {
    clear(out)
    if references==nil {return}
    for row in 0..<core.count(references) {
        r:=core.entity_at(references,row)
        reference:=core.at(core.read(references),row)
        pose,has:=core.get(core.read(worlds),r)
        if !has || reference.extents=={} {continue}
        half:=reference.extents*mm.Vec3{abs(pose.scale.x),abs(pose.scale.y),abs(pose.scale.z)}
        bounds:=mm.aabb_transform({-half,half},mm.transform_matrix({pose.position,pose.rotation,{1,1,1}}))
        append(out,Section_Box{r,reference,pose.transform,bounds})
    }
}

// What the sections of the objects follow: the version of the references
// and where each of them is.
@(private)
sections_seen :: proc(references:^core.Table(scene.Scene_Reference),worlds:^core.Table(core.World_Transform)) -> (seen:[2]u64) {
    if references==nil {return}
    seen[0]=core.version(references)
    for e in references.entities[:core.count(references)] {seen[1]=seen[1]*31+row_stamp(core.raw(worlds),e)}
    return
}

// The Ids of the references of sections, as a pose names them.
@(private)
section_ids :: proc(ids:^core.Table(core.Id),sections:[wire.OBJECT_GROUPS]core.Entity) -> (out:[wire.OBJECT_GROUPS]base.Entity_Id) {
    for section,i in sections {
        if section!=core.NONE {out[i]=core.id_of(core.read(ids),section)}
    }
    return
}

// The groups of the host of sections: none when one of them has none, for
// what is in it reaches whom its audience says.
@(private)
section_groups :: proc(s:^Net_Session,ids:^core.Table(core.Id),sections:[wire.OBJECT_GROUPS]core.Entity) -> (groups:wire.Groups) {
    for section,i in sections {
        if section==core.NONE {continue}
        group:=section_group(s,core.id_of(core.read(ids),section),true)
        if group==0 {return {}}
        groups[i]=u16(group)
    }
    return
}

// The closest entity above e that replicates, NONE without one.
@(private)
replicated_ancestor :: proc(w:core.World_Ref,hierarchy:core.Ref(core.Hierarchy),objects:^core.Table(Replicate),e:core.Entity) -> core.Entity {
    for at:=core.parent_of(hierarchy,e);at!=core.NONE;at=core.parent_of(hierarchy,at) {
        if replicated(w,objects,at) {return at}
    }
    return core.NONE
}

// Whether e replicates: its Replicate is on, or off with the entity while
// its object stays (kept_off).
@(private)
replicated :: proc(w:core.World_Ref,objects:^core.Table(Replicate),e:core.Entity) -> bool {
    if core.has(objects,e) {return true}
    on,turned_off,found:=core.raw_state(core.raw(objects),e)
    return found && !on && !turned_off && kept_off(w,e)
}

// An entity off whose object stays, off (Pose.disabled), so that a client
// keeps its replica and what it has: what turns it off is a Disabled of its
// own or of something above it, and none of them is its section's
// (scene.Section_Held, what a section loaded and off or not loaded turns
// off). What its section turns off ends its object: each client has the
// section as it has it.
@(private)
kept_off :: proc(w:core.World_Ref,e:core.Entity) -> bool {
    if !core.entity_off(core.world_entities(w),e) {return false}
    held:=core.world_table_of(w,scene.Section_Held)
    if held==nil {return true}
    hierarchy:=core.ref(core.world_storage_of(w,core.Hierarchy))
    for at:=e;at!=core.NONE;at=core.parent_of(hierarchy,at) {
        if core.raw_row(core.raw(held),at)>=0 {return false}
    }
    return true
}

// The object of one entity, created with what it has now: what it has is what
// it replicates; parent is the object of its ancestor. Zero when it has no
// Transform, it has more than an object carries or the host is full.
@(private)
server_create :: proc(s:^Net_Session,w:core.World_Ref,e:core.Entity,config:Replicate,ancestor:core.Entity,parent:Object) -> Object {
    h:=&s.host
    local,has_pose:=core.get(core.read(core.world_table_of(w,core.Transform)),e)
    if !has_pose {
        core.report(s.problems,e,"net.object","it is not replicated: it has no Transform; give it one")
        return 0
    }
    kinds:[wire.MAX_FRAGMENTS]wire.Fragment_Id
    count,fits:=entity_kinds(s,w,e,&kinds)
    if !fits {
        core.report(s.problems,e,"net.object","it is not replicated: it has more replicated components than an object carries (%d, besides its pose, motion and driver); replicate fewer of them",COMPONENTS)
        return 0
    }
    type,composed:=wire.type_compose(&s.protocol,kinds[:count])
    if !composed {
        core.report(s.problems,e,"net.object","it is not replicated: its replicated components take more than the state of an object, or the %d kinds of replicated entities of the protocol are in use; replicate fewer fields, or fewer different sets of components",wire.TYPE_CAPACITY)
        return 0
    }
    t:=net_type(s,type)
    source,_:=core.get(core.read(core.world_table_of(w,scene.Prefab_Source)),e)
    ids:=core.world_table_of(w,core.Id)
    hierarchy:=core.ref(core.world_storage_of(w,core.Hierarchy))
    references,worlds:=core.world_table_of(w,scene.Scene_Reference),core.world_table_of(w,core.World_Transform)
    sections:=sections_of(s,s.server.section_boxes[:],worlds,hierarchy,e,section_of(hierarchy,references,e))
    pose:=Pose{id=core.id_of(core.read(ids),e),prefab=source.prefab,sections=section_ids(ids,sections),position=local.position,rotation=local.rotation,scale=local.scale,off=components_off(w,e,t),predict=config.predict}
    position:=local.position
    if world,has:=core.get(core.read(core.world_table_of(w,core.World_Transform)),e);has {position=world.position}
    desc:=wire.Object_Desc{
        type=type,user=u64(e),owner=owner_of(w,e),simulation=config.simulation,priority=config.priority,poll_interval=publish_interval(s,config.update_hz),
        filter=filter_of(config.audience),position=position,radius=config.radius,parent=parent,auto_authority=config.simulation==.Lent,
        groups=section_groups(s,ids,sections),
    }
    if visibility:=core.world_table_of(w,Visibility);visibility!=nil {
        if value:=core.staged(visibility,e);value!=nil {desc.visibility=value.mask}
    }
    // Through rawptr: the host lets go of these locals below, which the escape analysis of Odin cannot tell.
    desc.sources[0]=rawptr(&pose)
    motion,_:=motion_read(w,e)
    if t.motion>=0 {desc.sources[t.motion]=rawptr(&motion)}
    driver:=driver_read(w,e)
    if t.driver>=0 {desc.sources[t.driver]=rawptr(&driver)}
    for k in 0..<t.count {
        info:=&w.info.tables[t.tables[k]]
        desc.sources[t.first+k]=core.raw_staged(core.world_table_at(w,info),info.info,e)
    }
    object,error:=wire.object_create(h,desc)
    if error==.Full {
        switch wire.object_room(h,type) {
        case .Objects:
            core.report(s.problems,e,"net.objects_full","it is not replicated: the %d replicated entities of Net_Settings.max_objects are in use; raise max_objects",s.desc.max_objects)
        case .State_Words:
            core.report(s.problems,e,"net.states_full","it is not replicated: the states of the replicated entities fill the %d words of Net_Settings.replication.state_words; raise state_words, or leave it at 0 for max_objects of the largest",h.desc.replication.state_words)
        case .Frame,.Fits:
            core.report(s.problems,e,"net.frame_full","it is not replicated in this tick: what the server changed since the last publish fills what the host takes in a tick (it grows with Net_Settings.max_objects); it is replicated in a later tick")
        }
        return 0
    }
    if error!=.None {
        core.report(s.problems,e,"net.object","it is not replicated: the host refused it (%v)",error)
        return 0
    }
    // The host keeps no pointer into the world: every later state is handed to it.
    for fragment in 0..<count {wire.object_set_source(h,object,fragment,nil)}
    s.server.objects[object_index(object)]={
        object=object,entity=e,type=type,moving=true,owner=desc.owner,filter=filter_of(config.audience),priority=config.priority,radius=config.radius,ancestor=ancestor,parent=parent,position=position,
        off=pose.off,sections=sections,told=true,member=member_of(w,e,sections[0]),visibility=desc.visibility,predict=config.predict,
    }
    placed:=&s.server.objects[object_index(object)].placed
    row_changed(core.raw(worlds),e,&placed[0],&placed[1])
    s.stats.objects+=1
    return object
}

// Who sees an object: whoever sees its ancestor, or its audience at a root.
// waits: its ancestor has no object yet, and it is seen by nobody; with wait
// its parent and filter stay as they were, for after the publish made the
// objects.
@(private)
server_scope :: proc(s:^Net_Session,slot:^Server_Object,config:Replicate,wait:bool) -> (waits:bool) {
    h:=&s.host
    if slot.radius!=config.radius && wire.object_set_radius(h,slot.object,config.radius)==.None {slot.radius=config.radius}
    parent:Object
    if slot.ancestor!=core.NONE {parent=wire.object_of_user(h,u64(slot.ancestor))}
    waits=slot.ancestor!=core.NONE && parent==0
    if waits && wait {return}
    filter:=waits?wire.Filter.None:filter_of(config.audience)
    if slot.parent!=parent && wire.object_set_parent(h,slot.object,parent)==.None {slot.parent=parent}
    if slot.filter!=filter && wire.object_set_filter(h,slot.object,filter)==.None {slot.filter=filter}
    return
}

// Server: the body a connection drives looks where its client says, after the
// seat turned it with the mouse (locomotion_seat, stage input) and before the
// locomotion moves it (stage simulate). See Input_Packet. The look a client
// sends is the one it had look_behind ticks before the tick of the input (its
// input delay): what it differs by from the look this end had then is put
// right now, and in the looks kept since, which the next inputs compare with.
@(step="fixed",loops="game",stage="intent")
remote_look :: proc(session:core.Ref(Net_Session),inputs:^Remote_Inputs,seats:core.Read(input.Seat),drivables:core.Read(input.Drivable),moves:^core.Table(input.Move_Input),time:core.Time) {
    if session.ptr==nil || session.mode!=.Server {return}
    for row in 0..<core.count(drivables) {
        seat,has:=core.get(seats,core.at(drivables,row).seat)
        if !has || seat.peer==0 {continue}
        entry:=remote_entry(inputs,Connection(seat.peer))
        move:=core.get(moves,core.entity_at(drivables,row))
        if entry==nil || move==nil {continue}
        now:=int(time.tick%len(entry.looks))
        if behind:=int(entry.look_behind);entry.has_look && behind<int(entry.looks_kept)+int(behind==0) {
            had:=behind==0?[2]f32{move.look_yaw,move.look_pitch}:entry.looks[(now+len(entry.looks)-behind)%len(entry.looks)]
            // The yaw comes wrapped: the shortest turn to it keeps the body's whole turns.
            off:=[2]f32{mm.angle_wrap(entry.look[0]-had[0]),entry.look[1]-had[1]}
            move.look_yaw+=off[0]
            move.look_pitch+=off[1]
            for &kept in entry.looks {kept+=off}
        }
        entry.looks[now]={move.look_yaw,move.look_pitch}
        entry.looks_kept=min(entry.looks_kept+1,len(entry.looks))
    }
}
