package destruct_multiplayer

import "core:mem"
import "mirai:core"
import "mirai:engine/scene"
import destruct "plugins:destruct/runtime"
import multiplayer "plugins:multiplayer/runtime"
import physics "plugins:physics/runtime"
import sim "plugins:physics/runtime/sim"
import fr "plugins:destruct/runtime/fracture"
import "mirai:std/base"

// Destruction over the network. The server is the only one that damages:
// every fracture event it applies (destruct.Destruct_Events.applied) goes to
// the clients as a small reliable event, numbered per destructible, and each
// client replays it on its own destructible, made from the same mesh. Nothing
// of the pieces travels.
//
// A client replays the events in order once its tick reaches the tick of the
// server they belong to. One that arrives for a tick the client already
// simulated asks the network to go back to it (multiplayer.rewind), and the
// correction replays it there; without one, it is replayed in the present.
// Either way the tick it was first replayed at is kept with the log:
// Destructible_State.sequence is part of the world, so a correction that goes
// back before it finds the destructible whole and replays the event again at
// that same tick, and so does a state of the server.
//
// A server sends the state of its broken destructibles, in chunks, to each
// connection that enters its world (when it arrives, and after each scene that
// replaces it, a saved game among them), and to a client that asks for it when
// it misses an event or its pieces stop matching the check of the server. What
// this library knows is of one world: a scene that replaces it forgets it.
//
// The bodies of the groups that are not debris are entities with the Id both
// ends draw alike (destruct.Grouped), replicated by the server as bodies; the
// client binds them to its own groups. Debris is of each end.

NET_STATE_CHUNK :: 192
NET_STATE_WORDS :: NET_STATE_CHUNK/4
NET_LOG :: 128             // events of a destructible a client keeps to replay them again after a correction
NET_ASK_TICKS :: 120       // a client asks again after this long without an answer
NET_STATE_BUDGET :: 4096   // bytes of state a server starts sending per tick


// The messages: id names the destructible, the Id of its entity in the scene both ends loaded.
@(net_message,reliable)
Net_Fracture :: struct {
    id:base.Entity_Id,
    check:u32, // fr.destructible_check after it; zero: more events of the same tick follow
    using record:destruct.Fracture_Record,
}

@(net_message,reliable)
Net_State :: struct {
    id:base.Entity_Id,
    sequence:u32,           // events the state includes
    check:u32,
    total:u32,              // bytes of the state; zero: the destructible is as created
    offset,count:u32,
    words:[NET_STATE_WORDS]u32,
}

@(net_message,from="client",reliable)
Net_Ask :: struct {id:base.Entity_Id}

@(private)
Net_Destructible :: struct {
    id:base.Entity_Id,
    log:[NET_LOG]Net_Fracture,                // client: by sequence
    placed:[NET_LOG]u64,                      // client: by sequence, the tick + 1 each event was first replayed at; 0 until then
    newest:u32,                               // highest sequence received
    state:[dynamic]u8,                        // the last state received; whole when state_ready
    state_sequence,state_check:u32,
    state_total,state_have:u32,
    state_ready,state_fresh:bool,             // fresh: it has not been looked at since it arrived
    state_at:u64,                             // the tick + 1 the state was first asked at; 0 until then
    ask:bool,
    asked:u64,                                // tick + 1 of the last ask
}

@(private)
Net_Request :: struct {
    connection:multiplayer.Connection,
    id:base.Entity_Id,
}

Net_Stats :: struct {
    sent,received:u64,   // fracture events
    states:u64,          // client: states applied
    desyncs:u64,         // client: events after which the pieces did not match the server
}

// What this library knows of the network. One for each World, never copied: a
// correction restores the world and leaves the logs as they are.
@(storage,host,by_world,free="net_free")
Destruct_Net :: struct {
    changes:u32,                   // the scene change of the world it is of (scene.Scene_Root)
    links:[dynamic]Net_Destructible,
    requests:[dynamic]Net_Request, // server: who asked for the state of which destructible
    requested:int,                 // of those, how many were served
    scratch:[dynamic]u8,
    stats:Net_Stats,
}

net_free :: proc(n:^Destruct_Net) {
    for &link in n.links {delete(link.state)}
    delete(n.links);delete(n.requests);delete(n.scratch)
    n^={}
}

// A scene replaced the world: the logs, the states and the requests were of
// destructibles of the world before, which the new one may name alike.
@(private)
net_world :: proc(n:^Destruct_Net,root:core.Ref(scene.Scene_Root)) {
    if root.ptr==nil || root.changes==n.changes {return}
    n.changes=root.changes
    for &link in n.links {delete(link.state)}
    clear(&n.links)
    clear(&n.requests)
    n.requested=0
}

@(private)
net_link :: proc(n:^Destruct_Net,id:base.Entity_Id,create:bool) -> ^Net_Destructible {
    for &link in n.links {
        if link.id==id {return &link}
    }
    if !create {return nil}
    if _,error:=append(&n.links,Net_Destructible{id=id});error!=nil {return nil}
    return &n.links[len(n.links)-1]
}

@(private)
memory_problem :: proc(problems:^core.Problems) {
    core.report(problems,core.NONE,"destruct.net_memory","out of memory for what the server says of a broken Destructible; it is asked for again and may show other pieces until then: free memory")
}

// What arrived this frame, to be used by the ticks that follow: a frame can
// have several ticks, or none. A fracture of a tick already simulated asks to
// go back to it.
@(step="input",stage="begin",after="net_begin",before="net_rewind")
destruct_net_receive :: proc(events:core.Ref(multiplayer.Net_Events),authority:core.Ref(core.Network),n:^Destruct_Net,time:core.Time,rewinds:^multiplayer.Net_Rewinds,root:core.Ref(scene.Scene_Root),problems:^core.Problems) {
    net_world(n,root)
    if authority.role==.Standalone {return}
    server:=authority.role==.Server
    for item in events.received.items {
        if fracture,ok:=multiplayer.event_read(item,Net_Fracture);ok {
            if server || fracture.sequence==0 {continue}
            link:=net_link(n,fracture.id,true)
            if link==nil {memory_problem(problems);continue}
            link.log[fracture.sequence%NET_LOG]=fracture
            link.placed[fracture.sequence%NET_LOG]=0
            link.newest=max(link.newest,fracture.sequence)
            n.stats.received+=1
            if i32(fracture.tick-u32(time.tick))<0 {multiplayer.rewind(rewinds,fracture.tick)}
        } else if chunk,state_ok:=multiplayer.event_read(item,Net_State);state_ok {
            if !server {net_chunk(n,chunk,problems)}
        } else if ask,ask_ok:=multiplayer.event_read(item,Net_Ask);ask_ok {
            if server && item.sender!=0 {append(&n.requests,Net_Request{item.sender,ask.id})}
        }
    }
}

@(private)
net_chunk :: proc(n:^Destruct_Net,chunk:Net_State,problems:^core.Problems) {
    if int(chunk.count)>NET_STATE_CHUNK {return}
    l:=net_link(n,chunk.id,true)
    if l==nil {memory_problem(problems);return}
    same:=l.state_sequence==chunk.sequence && l.state_total==chunk.total && l.state_check==chunk.check
    if chunk.offset==0 && !(same && l.state_ready) {
        // Asked again: the chunks that follow this one are of a state that has no room.
        if resize(&l.state,int(chunk.total))!=nil {l.ask=true;memory_problem(problems);return}
        l.state_sequence,l.state_check,l.state_total,l.state_have=chunk.sequence,chunk.check,chunk.total,0
        l.state_ready,l.state_at,same=false,0,true
    }
    if !same || l.state_ready || chunk.offset>l.state_have || int(chunk.offset)+int(chunk.count)>len(l.state) {return}
    chunk:=chunk
    copy(l.state[chunk.offset:][:chunk.count],([^]u8)(&chunk.words)[:chunk.count])
    l.state_have=max(l.state_have,chunk.offset+chunk.count)
    if l.state_have==l.state_total {l.state_ready,l.state_fresh,l.ask=true,true,false}
}

// Client, before destruct replays in the tick: the state of the server when it
// stands, and the events whose tick came, in order.
@(step="fixed",stage="react",before="destruct_step")
destruct_net_follow :: proc(
    authority:core.Ref(core.Network),n:^Destruct_Net,time:core.Time,requests:^destruct.Destruct_Requests,fractures:core.Ref(destruct.Fracture_State),
    destructibles:core.Read(destruct.Destructible),states:core.Read(destruct.Destructible_State),ids:core.Read(core.Id),root:core.Ref(scene.Scene_Root),
) {
    net_world(n,root)
    if authority.role!=.Client || !fractures.ready {return}
    f:=&fractures.fracture
    for row in 0..<core.count(destructibles) {
        e:=core.entity_at(destructibles,row)
        st,made:=core.get(states,e)
        id:=core.id_of(ids,e)
        if !made || id==0 || !fr.destructible_valid(f,st.handle) {continue}
        l:=net_link(n,id,false)
        if l==nil {continue}
        sequence:=st.sequence
        if l.state_ready {
            // The state stands when it is ahead of what was replayed, and when it says the pieces here are not those of the server:
            // the first time it is looked at, and again at the tick it was first asked at.
            ahead:=l.state_sequence>sequence
            differs:=l.state_sequence==sequence && l.state_check!=fr.destructible_check(f,st.handle)
            due:=ahead || differs && (l.state_at==0?l.state_fresh:time.tick+1==l.state_at)
            if l.state_at!=0 && time.tick+1<l.state_at {due=false}
            l.state_fresh=false
            if due {
                if l.state_at==0 {l.state_at=time.tick+1}
                destruct.state_replay(requests,e,l.state_sequence,l.state[:l.state_total])
                sequence=l.state_sequence
            }
        }
        for {
            slot:=(sequence+1)%NET_LOG
            logged:=&l.log[slot]
            if logged.sequence!=sequence+1 || logged.id!=id {break}
            if l.placed[slot]!=0 {
                if time.tick+1<l.placed[slot] {break}
            } else if i32(logged.tick-u32(time.tick))>0 {
                break
            } else {
                l.placed[slot]=time.tick+1
            }
            destruct.replay(requests,e,logged.record,logged.check)
            sequence=logged.sequence
        }
    }
}

// After destruct in the tick. Server: the events it applied leave, the last of
// each destructible in the tick with the check of what it became, and the
// broken destructibles go to the connections that arrived or asked. Client:
// what the replays did decides whether to ask for the state. Both: the
// groups that are not debris stand for their bodies on the network.
@(step="fixed",stage="react",after="destruct_step")
destruct_net_send :: proc(
    authority:core.Ref(core.Network),n:^Destruct_Net,time:core.Time,outbox:^multiplayer.Net_Outbox,adoptions:^multiplayer.Net_Adoptions,session:core.Ref(multiplayer.Net_Session),
    connections:core.Ref(multiplayer.Net_Connections),
    events:core.Ref(destruct.Destruct_Events),physics_state:core.Ref(physics.Physics_State),fractures:core.Ref(destruct.Fracture_State),commands:core.Commands,
    states:core.Read(destruct.Destructible_State),ids:core.Read(core.Id),objects:core.Read(multiplayer.Replicate),entities:core.Ref(core.Entities),root:core.Ref(scene.Scene_Root),problems:^core.Problems,
) {
    net_world(n,root)
    if authority.role==.Standalone || !physics_state.ready || !fractures.ready {return}
    w,f:=&physics_state.world,&fractures.fracture
    if authority.role==.Server {
        fractures_send(n,f,time,outbox,events,states,ids)
        states_serve(n,f,w,time,outbox,connections,states,ids,problems)
    } else {
        replays_verify(n,entities.ptr,time,outbox,session,events,states,ids)
    }
    for group in events.grouped.items {
        if group.debris {continue}
        if authority.role==.Server {
            if held,found:=core.get(objects,group.owner);found {
                core.commands_add(commands,group.entity,multiplayer.Replicate{audience=held.audience,priority=held.priority,radius=multiplayer.REPLICATE_DEFAULT.radius})
            }
        } else {
            multiplayer.adopt(adoptions,group.id,group.entity)
        }
    }
}

@(private)
fractures_send :: proc(n:^Destruct_Net,f:^fr.Fracture,time:core.Time,outbox:^multiplayer.Net_Outbox,events:core.Ref(destruct.Destruct_Events),states:core.Read(destruct.Destructible_State),ids:core.Read(core.Id)) {
    items:=events.applied.items
    for applied,at in items {
        id:=core.id_of(ids,applied.entity)
        if id==0 {continue}
        fracture:=Net_Fracture{id=id,record=applied.record}
        last:=true
        for later in items[at+1:] {last &&= later.entity!=applied.entity}
        if last {
            if st,found:=core.get(states,applied.entity);found && fr.destructible_valid(f,st.handle) {fracture.check=fr.destructible_check(f,st.handle)}
        }
        if multiplayer.send(outbox,time,fracture) {n.stats.sent+=1}
    }
}

// The connections that entered the world and the clients that asked get the state of the broken destructibles.
@(private)
states_serve :: proc(n:^Destruct_Net,f:^fr.Fracture,w:^sim.World,time:core.Time,outbox:^multiplayer.Net_Outbox,connections:core.Ref(multiplayer.Net_Connections),states:core.Read(destruct.Destructible_State),ids:core.Read(core.Id),problems:^core.Problems) {
    if connections.ptr!=nil {
        for event in connections.events.items {
            if event.kind!=.Entered {continue}
            for row in 0..<core.count(states) {
                st:=core.at(states,row)
                if st.sequence==0 && st.revision==0 {continue}
                if id:=core.id_of(ids,core.entity_at(states,row));id!=0 {append(&n.requests,Net_Request{event.connection,id})}
            }
        }
    }
    for budget:=NET_STATE_BUDGET;budget>0 && n.requested<len(n.requests); {
        request:=n.requests[n.requested]
        n.requested+=1
        st:destruct.Destructible_State
        found,served:=false,0
        for row in 0..<core.count(states) {
            if core.id_of(ids,core.entity_at(states,row))==request.id {
                st,found,served=core.at(states,row),true,row
                break
            }
        }
        if !found || !fr.destructible_valid(f,st.handle) {continue}
        chunk:=Net_State{id=request.id,sequence=st.sequence,check=fr.destructible_check(f,st.handle)}
        size:=0
        if fr.destructible_revision(f,st.handle)!=0 || st.sequence!=0 {
            if resize(&n.scratch,fr.destructible_state_size(f,st.handle))!=nil {
                core.report(problems,core.entity_at(states,served),"destruct.net_memory","out of memory to send the state of this broken Destructible to a client; it is tried again in the next tick: free memory, or lower Destruct_Settings.pieces")
                n.requested-=1
                break
            }
            size=fr.destructible_state_write(f,w,st.handle,n.scratch[:])
        }
        chunk.total=u32(size)
        for offset:=0;offset==0 || offset<size;offset+=NET_STATE_CHUNK {
            count:=min(size-offset,NET_STATE_CHUNK)
            chunk.offset,chunk.count=u32(offset),u32(count)
            mem.zero_slice(chunk.words[:])
            copy(([^]u8)(&chunk.words)[:count],n.scratch[offset:][:count])
            multiplayer.send(outbox,time,chunk,core.NONE,request.connection)
        }
        budget-=size+32
    }
    if n.requested>=len(n.requests) {
        clear(&n.requests)
        n.requested=0
    }
}

// A replay that did not leave the pieces the server had, or an event that is
// missing, asks for the state of the destructible.
@(private)
replays_verify :: proc(n:^Destruct_Net,es:^core.Entities,time:core.Time,outbox:^multiplayer.Net_Outbox,session:core.Ref(multiplayer.Net_Session),events:core.Ref(destruct.Destruct_Events),states:core.Read(destruct.Destructible_State),ids:core.Read(core.Id)) {
    for item in events.replayed.items {
        id:=core.id_of(ids,item.entity)
        l:=id!=0?net_link(n,id,false):nil
        if l==nil {continue}
        if item.state {
            if item.done {n.stats.states+=1}
            if item.failed {l.state_ready=false}
            continue
        }
        if !item.done {
            n.stats.desyncs+=1
            l.ask,l.asked=true,0
        }
    }
    for &l in n.links {
        e:=core.entity_of(es,l.id)
        st,found:=core.get(states,e)
        if !found {continue}
        if l.newest>st.sequence && l.log[(st.sequence+1)%NET_LOG].sequence!=st.sequence+1 {l.ask=true}
        if l.ask && (l.asked==0 || time.tick+1-l.asked>=NET_ASK_TICKS) && session.status==.Connected && multiplayer.send(outbox,time,Net_Ask{l.id}) {l.asked=time.tick+1}
    }
}
