package multiplayer

import "core:fmt"
import "core:mem"
import "core:slice"
import "mirai:core"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import wire "mirai:net"
import "base:runtime"

// The world of a session is the scene of its server. When a scene replaces
// the world of an end (scene.Scene_Root.changes), what the session knew of its
// entities is of a world that is gone, and the new one numbers its entities
// from scratch:
//
//   server  the objects of the world before end, and those of the new one are
//           made again; the connections stay, held (they see no object and
//           hear nothing of the game), and each hears the scene and the number
//           of the change (Net_World). A client that says it is in that world
//           (Net_World_Ready) is let go (Entered), and the new world reaches
//           it. A client that arrives hears the same.
//   client  once no scene is loading, it loads the one it heard, unless it is
//           in it already as it arrives; when a scene replaced its world, it
//           forgets its replicas and its history, and says it is in the world
//           of that change. One that cannot load the scene leaves, saying which.
//
// What the game sends belongs to a world: an end drops what comes from one
// that is not in the same world. A client says which sections of the world it
// has loaded (Net_Section), and the server replicates what is in a section
// only to the clients that have it (a group of the host per section).

// What the session takes as the world it opens in.
@(private)
world_seen :: proc(s:^Net_Session,w:core.World_Ref) {
    root:=core.world_storage_of(w,scene.Scene_Root)
    if root==nil {return}
    if s.mode==.Server {s.server.scene,s.server.changes=root.scene,root.changes} else {s.client.seen=root.changes}
}

// First thing at each step of the network: a scene that replaced the world
// since the last one.
@(private)
world_follow :: proc(s:^Net_Session,w:core.World_Ref) {
    if !s.host_ready {return}
    root:=core.world_storage_of(w,scene.Scene_Root)
    if root==nil {return}
    if s.mode==.Server {
        if root.changes!=s.server.changes {server_world(s,w,root^)}
    } else if root.changes!=s.client.seen {
        client_world(s,w,root^)
    }
}

// What the world brought of the network is of the world before it (the
// entities kept across the change), or of a saved game.
@(private)
world_strip :: proc(w:core.World_Ref) {
    strip :: proc(t:^core.Table($T)) {
        if t==nil {return}
        for e in t.entities {core.remove(t,e)}
    }
    strip(core.world_table_of(w,Net_Link))
    strip(core.world_table_of(w,core.Remote))
    strip(core.world_table_of(w,core.Pose_Target))
    core.world_settle(w)
}

// Server: the objects of the world before end, unbound so that none names an
// entity of this one while it goes, and every connection waits for the world,
// with none of its sections.
@(private)
server_world :: proc(s:^Net_Session,w:core.World_Ref,root:scene.Scene_Root) {
    server:=&s.server
    server.scene,server.changes=root.scene,root.changes
    for &slot in server.objects {
        if slot.object==0 {continue}
        wire.object_bind(&s.host,slot.object,0)
        slot.entity,slot.ancestor,slot.sections,slot.holder,slot.member=core.NONE,core.NONE,{},0,0
    }
    mem.zero_slice(server.views)
    server.visibility={}
    mem.zero_slice(server.layouts)
    server.moved={}
    server.ancestry={}
    mem.zero_slice(server.sections)
    server.section_count,server.sections_full=0,false
    mem.zero_slice(server.loaded)
    clear(&server.groups)
    clear(&server.gone)
    clear(&server.notices)
    for &peer in server.peers {
        if peer.connection==0 {continue}
        peer.told,peer.ready=false,false
        if wire.connection_clear_groups(&s.host,peer.connection)!=.None {append(&server.groups,Group_Change{connection=peer.connection})}
    }
    world_strip(w)
    server_world_update(s)
}

// Server: what each connection still has to hear of the world, and whether it
// sees it; what the host has no room for is tried again at the next step. A
// connection let go into the world has entered it.
@(private)
server_world_update :: proc(s:^Net_Session) {
    if !s.follows {return}
    h:=&s.host
    for &peer in s.server.peers {
        if peer.connection==0 {continue}
        if !peer.told {
            message:=Net_World{scene=s.server.scene,changes=s.server.changes,connection=peer.connection}
            peer.told=wire.event_send(h,wire.Event_Id(s.own.world),0,&message,peer.connection)==.None
        }
        if peer.held==peer.ready && wire.connection_hold(h,peer.connection,!peer.ready)==.None {
            peer.held=!peer.ready
            if peer.ready {append(&s.arrived,Connection_Event{kind=.Entered,connection=peer.connection})}
        }
    }
    kept:=0
    for change in s.server.groups {
        done:=change.group==0?wire.connection_clear_groups(h,change.connection):wire.connection_set_group(h,change.connection,change.group,change.has)
        if done==.Full {
            s.server.groups[kept]=change
            kept+=1
        }
    }
    base.truncate(&s.server.groups,kept)
}

// Server: the clock of the world goes to every client with the tick.
@(private)
server_clock :: proc(s:^Net_Session,w:core.World_Ref,stopped:bool) {
    clock:=core.world_storage_of(w,core.Clock)
    if clock==nil {return}
    now:=core.Clock{paused=clock.paused || stopped,scale=clock.scale>0?clock.scale:1}
    if now!=s.server.clock && wire.clock_set(&s.host,now.paused,now.scale)==.None {s.server.clock=now}
}

// Whether the other end of a connection is in the world of this one: what the
// game sends from one that is not belongs to another world.
@(private)
in_world :: proc(s:^Net_Session,connection:Connection) -> bool {
    if !s.follows {return true}
    if s.mode==.Client {return s.client.answered}
    peer:=&s.server.peers[object_index(Object(connection))]
    return peer.connection==connection && peer.ready
}

// A message of the session itself; false for one of the game.
@(private)
own_deliver :: proc(s:^Net_Session,w:core.World_Ref,command:^wire.Command,inputs:^Remote_Inputs) -> bool {
    h:=&s.host
    switch int(command.event) {
    case s.own.world:
        message:Net_World
        if s.mode==.Client && wire.event_read(h,command,&message) {client_heard(s,w,message)}
    case s.own.ready:
        message:Net_World_Ready
        if s.mode!=.Server || !wire.event_read(h,command,&message) {return true}
        peer:=&s.server.peers[object_index(Object(command.connection))]
        if peer.connection==command.connection && message.changes==s.server.changes {
            peer.ready=true
            server_world_update(s)
        }
    case s.own.player:
        message:Net_Player
        if s.mode!=.Server || !wire.event_read(h,command,&message) {return true}
        entry:=remote_entry(inputs,command.connection)
        if entry==nil {return true}
        // One player a connection, and one that is someone: a client of this engine sends no other.
        if entry.player!=0 || message.secret=={} {
            wire.host_disconnect(h,command.connection,.Denied_Player)
            return true
        }
        player:=player_id(message.secret)
        // The same player connected again: the older connection gives way.
        for &other in inputs.entries {
            if other.connection==0 || other.connection==command.connection || other.player!=player {continue}
            wire.host_disconnect(h,other.connection,.Replaced)
            other={}
        }
        entry.player=player
    case s.own.section:
        message:Net_Section
        if s.mode!=.Server || !wire.event_read(h,command,&message) {return true}
        peer:=&s.server.peers[object_index(Object(command.connection))]
        if peer.connection!=command.connection || message.changes!=s.server.changes || message.id==0 {return true}
        group:=section_group(s,message.id,message.loaded)
        if group==0 {return true}
        words:=loaded_of(&s.server,object_index(Object(command.connection)))
        bit:=u64(1)<<uint((group-1)%64)
        if message.loaded {words[(group-1)/64]|=bit} else {words[(group-1)/64]&=~bit}
        if wire.connection_set_group(h,command.connection,group,message.loaded)==.Full {
            append(&s.server.groups,Group_Change{command.connection,group,message.loaded})
        }
        // What of it is gone it hears once it has it.
        for i:=len(s.server.gone)-1;i>=0;i-=1 {
            if s.server.gone[i].connection==command.connection && s.server.gone[i].section==message.id {unordered_remove(&s.server.gone,i)}
        }
        if message.loaded {append(&s.server.gone,Gone_Due{connection=command.connection,section=message.id})}
    case s.own.gone:
        message:Net_Gone
        if s.mode==.Client && wire.event_read(h,command,&message) {client_gone(s,w,message)}
    case:
        return false
    }
    return true
}

// Server: the group of the host that stands for a section, by the Id of its
// reference; one is given to a section new to this world when make. 0 without
// one: when every group is in use, a section has none and what is in it is
// seen as its audience says.
@(private)
section_group :: proc(s:^Net_Session,id:base.Entity_Id,make:bool) -> int {
    server:=&s.server
    if id==0 || !s.follows {return 0}
    for known,index in server.sections[:server.section_count] {
        if known==id {return index+1}
    }
    if !make {return 0}
    if server.section_count==len(server.sections) {
        if server.section_count>0 && !server.sections_full {
            server.sections_full=true
            core.report(s.problems,core.NONE,"net.sections","the world has more sections than the %d groups of Net_Settings.replication.groups: what is in the rest goes to every client its audience reaches, loaded or not; raise groups",len(server.sections))
        }
        return 0
    }
    server.sections[server.section_count]=id
    server.section_count+=1
    return server.section_count
}

// Client: the world of the server, as it arrives or changes.
@(private)
client_heard :: proc(s:^Net_Session,w:core.World_Ref,message:Net_World) {
    c:=&s.client
    c.connection=message.connection
    if c.heard && message.changes==c.changes {return}
    c.first=!c.heard
    c.heard,c.changes,c.scene=true,message.changes,message.scene
    c.asked,c.answered=false,false
}

// Client: once no scene is loading, the scene of the server is asked for, or,
// in it, the server hears so. A scene that did not load ends the session.
@(private)
client_world_update :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator) {
    c:=&s.client
    h:=&s.host
    if s.follows && !c.player_told && s.status==.Connected {
        message:=Net_Player{player_secret(s,w)}
        c.player_told=wire.event_send(h,wire.Event_Id(s.own.player),0,&message)==.None
    }
    if !c.heard {return}
    if c.answered {
        client_sections(s,w)
        return
    }
    root:=core.world_storage_of(w,scene.Scene_Root)
    requests:=core.world_storage_of(w,scene.Scene_Requests)
    if c.scene!={} && (root==nil || requests==nil) {
        client_lacks(s,w,assets,allocator,.No_Assets)
        return
    }
    if c.asked {
        if results:=core.world_storage_of(w,scene.Scene_Results);results!=nil {
            if result,found:=scene.result_of(results,c.scene);found && result.error!=.None {
                client_lacks(s,w,assets,allocator,result.error)
                return
            }
        }
    }
    if requests!=nil && len(requests.queue.items)>0 {return}
    if loads:=core.world_storage_of(w,scene.Scene_Loads);loads!=nil && loads.job!=nil {return}
    in_it:=c.scene=={} || root.scene==c.scene && (c.first || c.asked)
    if !in_it {
        // Asked and loaded, but another scene took its place: asked again.
        scene.request(requests,c.scene)
        c.asked=true
        return
    }
    message:=Net_World_Ready{c.changes}
    c.answered=wire.event_send(h,wire.Event_Id(s.own.ready),0,&message)==.None
    if c.answered {client_sections(s,w)}
}

// Client: the secret of the player it presents. That of the profile of the
// player, made the first time and written to the profile, or one of this
// world alone when it was asked for one (Open_Request.new_player), or when
// the world keeps no profile.
@(private)
player_secret :: proc(s:^Net_Session,w:core.World_Ref) -> [2]u64 {
    identity:=core.world_storage_of(w,Net_Identity)
    if s.wanted.new_player || identity==nil {
        if s.secret=={} {s.secret=secret_new()}
        return s.secret
    }
    if identity.secret=={} {identity.secret=secret_new()}
    return identity.secret
}

// Client: the sections of the world it has loaded, as they load and drop,
// told to the server; what the server has no room for is told at the next step.
@(private)
client_sections :: proc(s:^Net_Session,w:core.World_Ref) {
    c:=&s.client
    references:=core.world_table_of(w,scene.Scene_Reference)
    ids:=core.world_table_of(w,core.Id)
    if !s.follows || references==nil || ids==nil {return}
    seen:=c.sections_seen
    if !core.touched(references,&seen) {return}
    loaded:=make([dynamic]base.Entity_Id,context.temp_allocator)
    for row in 0..<core.count(references) {
        reference:=core.at(references,row)
        if reference.loaded=={} {continue}
        if id:=core.id_of(core.read(ids),core.entity_at(references,row));id!=0 {append(&loaded,id)}
    }
    tell :: proc(s:^Net_Session,id:base.Entity_Id,loaded:bool) -> bool {
        message:=Net_Section{id=id,changes=s.client.changes,loaded=loaded}
        return wire.event_send(&s.host,wire.Event_Id(s.own.section),0,&message)==.None
    }
    told:=true
    for i:=len(c.sections)-1;i>=0;i-=1 {
        if slice.contains(loaded[:],c.sections[i]) {continue}
        if !tell(s,c.sections[i],false) {told=false;continue}
        unordered_remove(&c.sections,i)
    }
    for id in loaded {
        if slice.contains(c.sections[:],id) {continue}
        if !tell(s,id,true) {told=false;continue}
        append(&c.sections,id)
    }
    if told {c.sections_seen=seen}
}

// Client: what the server says is gone from a section takes it out of it here
// while it is loaded, but what a replica holds, which the server says where
// it is.
@(private)
client_gone :: proc(s:^Net_Session,w:core.World_Ref,message:Net_Gone) {
    c:=&s.client
    if message.changes!=c.changes || !section_loaded(w,message.section) {return}
    es:=core.world_entities(w)
    section:=core.entity_of(es,message.section)
    hierarchy:=core.ref(core.world_storage_of(w,core.Hierarchy))
    references:=core.world_table_of(w,scene.Scene_Reference)
    message:=message
    ids: for id in message.ids[:min(int(message.count),len(message.ids))] {
        e:=core.entity_of(es,id)
        if e==core.NONE || section_of(hierarchy,references,e)!=section {continue}
        for &r in c.replicas[:c.replica_high] {
            if r.object!=0 && r.entity==e {continue ids}
        }
        core.world_destroy_tree(w,e)
    }
}

// Client: whether the section of a reference, by its Id, is loaded here.
@(private)
section_loaded :: proc(w:core.World_Ref,id:base.Entity_Id) -> bool {
    references:=core.world_table_of(w,scene.Scene_Reference)
    if references==nil {return false}
    reference,found:=core.get(references,core.entity_of(core.world_entities(w),id))
    return found && reference.loaded!={}
}

// Client: the scene the server is in did not load. It leaves, saying which,
// and that a client needs the assets of its server.
@(private)
client_lacks :: proc(s:^Net_Session,w:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,error:scene.Error) {
    name:[base.ASSET_ID_TEXT]u8
    what:=base.asset_id_format(s.client.scene,name[:])
    if assets!=nil {what=host.assets_name(assets,s.client.scene,&name)}
    core.report(s.problems,core.NONE,"net.scene","the server is in scene %s, which this client could not load (%v): a client needs the assets of its server; run it from the same project",what,error)
    wire.host_disconnect(&s.host,0,.Scene_Missing)
    client_end(s,w,allocator,0,.Scene_Missing,fmt.tprintf("the server %s is in scene %s, which this client could not load (%s): a client needs the assets of its server; run it from the same project",s.address,what,scene.error_text(error)))
}

// Client: the session ends, with the reason for a person (text, which it
// copies); what came of the server goes, or stays as an entity of the scene.
@(private)
client_end :: proc(s:^Net_Session,w:core.World_Ref,allocator:runtime.Allocator,connection:Connection,reason:Disconnect_Reason,text:string) {
    was:=s.status==.Connected
    s.left+=u64(was)
    s.lost+=u64(was && reason!=.Closed && reason!=.Scene_Missing)
    s.status,s.reason=.Disconnected,reason
    reason_keep(s,allocator,text)
    for &r in s.client.replicas[:s.client.replica_high] {
        if r.object!=0 {replica_destroy(s,w,r.object,.Leave)}
    }
    history_reset(s)
    append(&s.arrived,Connection_Event{kind=.Disconnected,connection=connection,reason=reason})
    s.ended=true
}

// Client: a scene replaced the world. The entities of the replicas are gone
// with it, and so is the history: what comes of the server is made again, and
// the sections the server was told of are of the world before.
@(private)
client_world :: proc(s:^Net_Session,w:core.World_Ref,root:scene.Scene_Root) {
    c:=&s.client
    c.seen=root.changes
    for &r in c.replicas[:c.replica_high] {
        if r.object==0 {continue}
        slot_release(s,&r)
        wire.object_bind(&s.host,r.object,0)
        r={}
    }
    c.replica_high,c.waiting=0,0
    clear(&c.sections)
    c.sections_seen={}
    history_reset(s)
    for &frame in c.frames {frame.whole=true}
    world_strip(w)
    if c.answered {
        core.report(s.problems,core.NONE,"net.scene","a scene replaced the world of this client while it was in the world of its server: the server decides the scene of a session; load scenes on the server, and every client follows")
    }
}
