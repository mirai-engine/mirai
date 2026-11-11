package destruct_multiplayer

import "mirai:core"
import "mirai:engine/scene"
import destruct "plugins:destruct/runtime"
import multiplayer "plugins:multiplayer/runtime"
import physics "plugins:physics/runtime"
import "mirai:std/base"

// Destruction over the network, as a journal (multiplayer.Journal) keyed by
// the Id of each destructible. The server is the only one that damages: every
// fracture event it applies (destruct.Destruct_Events.applied) is an
// operation, the last of a destructible in the tick with the check of what it
// became, and each client replays it on its own destructible, made from the
// same mesh; a fracture of a tick it already simulated takes it back there.
// The part of a destructible is its whole state, which the server offers each
// connection that enters its world and gives a client whose pieces stop
// matching. Nothing of the pieces travels.
//
// The bodies of the groups that are not debris are entities with the Id both
// ends draw alike (destruct.Grouped), replicated by the server as bodies; the
// client binds them to its own groups. Debris is of each end.

DESTRUCT_JOURNAL :: u32(0x64657374)

#assert(size_of(destruct.Fracture_Record)<=multiplayer.JOURNAL_BODY)

// One for each World, never copied.
@(storage,host,by_world,free="net_free")
Destruct_Net :: struct {journal:multiplayer.Journal}

net_free :: proc(n:^Destruct_Net) {multiplayer.journal_free(&n.journal)}

@(private)
key_of :: proc(ids:^core.Table(core.Id,$A),e:core.Entity) -> multiplayer.Journal_Key {return {u64(core.id_of(ids,e)),0}}

@(step="fixed",stage="begin")
destruct_net_receive :: proc(inbox:multiplayer.Journal_Inbox,authority:core.Ref(core.Network),n:^Destruct_Net,time:core.Time,rewinds:^multiplayer.Net_Rewinds,root:core.Ref(scene.Scene_Root),problems:^core.Problems) {
    multiplayer.journal_world(&n.journal,DESTRUCT_JOURNAL,root)
    if authority.role==.Standalone {return}
    multiplayer.journal_receive(&n.journal,inbox,authority.role==.Server,0,time,rewinds,true,0,problems)
}

// Client, before destruct replays in the tick: what the journal hands of each destructible.
@(step="fixed",stage="react")
destruct_net_follow :: proc(
    authority:core.Ref(core.Network),n:^Destruct_Net,time:core.Time,requests:^destruct.Destruct_Requests,physics_state:core.Ref(physics.Physics_State),
    destructibles:^core.Table(destruct.Destructible,.Read),states:^core.Table(destruct.Destructible_State,.Read),ids:^core.Table(core.Id,.Read),root:core.Ref(scene.Scene_Root),
) {
    multiplayer.journal_world(&n.journal,DESTRUCT_JOURNAL,root)
    if authority.role!=.Client || !physics_state.ready {return}
    for row in 0..<core.count(destructibles) {
        e:=core.entity_at(destructibles,row)
        st,made:=core.get(states,e)
        if !made || core.id_of(ids,e)==0 || !physics.breakable_valid(physics_state,st.handle) {continue}
        for due in multiplayer.journal_due(&n.journal,key_of(ids,e),time,0) {
            if due.part!=nil {
                destruct.state_replay(requests,e,due.part.bytes,due.tag)
            } else {
                destruct.replay(requests,e,(^destruct.Fracture_Record)(&due.op.body)^,u32(due.op.check),due.tag)
            }
        }
    }
}

// After destruct in the tick. Server: the events it applied are published,
// and the broken destructibles go to the connections that entered or asked.
// Client: what the replays did. Both: the groups that are not debris stand
// for their bodies on the network.
@(step="fixed",stage="react")
destruct_net_send :: proc(
    authority:core.Ref(core.Network),n:^Destruct_Net,time:core.Time,outbox:^multiplayer.Net_Outbox,spawns:^multiplayer.Net_Spawns,session:core.Ref(multiplayer.Net_Session),
    connections:core.Ref(multiplayer.Net_Connections),
    events:core.Ref(destruct.Destruct_Events),physics_state:core.Ref(physics.Physics_State),commands:core.Commands,
    states:^core.Table(destruct.Destructible_State,.Read),ids:^core.Table(core.Id,.Read),objects:^core.Table(multiplayer.Replicate,.Read),entities:core.Ref(core.Entities),root:core.Ref(scene.Scene_Root),problems:^core.Problems,
) {
    j:=&n.journal
    multiplayer.journal_world(j,DESTRUCT_JOURNAL,root)
    if authority.role==.Standalone || !physics_state.ready {return}
    if authority.role==.Server {
        items:=events.applied.items
        for applied,at in items {
            if core.id_of(ids,applied.entity)==0 {continue}
            op:=multiplayer.Journal_Op{key=key_of(ids,applied.entity),low={0,0,0},high={-1,-1,-1}}
            (^destruct.Fracture_Record)(&op.body)^=applied.record
            last:=true
            for later in items[at+1:] {last &&= later.entity!=applied.entity}
            if st,found:=core.get(states,applied.entity);last && found && physics.breakable_valid(physics_state,st.handle) {op.check=u64(physics.breakable_check(physics_state,st.handle))}
            multiplayer.journal_publish(j,outbox,op,time)
        }
        multiplayer.journal_connections(j,connections)
        if connections.ptr!=nil {
            for event in connections.events.items {
                if event.kind!=.Entered {continue}
                for row in 0..<core.count(states) {
                    st:=core.at(states,row)
                    e:=core.entity_at(states,row)
                    if (st.sequence!=0 || st.revision!=0) && core.id_of(ids,e)!=0 {multiplayer.journal_offer(j,event.connection,key_of(ids,e),true)}
                }
            }
        }
        for sv in multiplayer.journal_serves(j,outbox,time) {
            sv.whole=true
            e:=core.entity_of(entities.ptr,base.Entity_Id(sv.key[0]))
            st,found:=core.get(states,e)
            if !found || !physics.breakable_valid(physics_state,st.handle) {multiplayer.journal_part(j,sv,nil,true);continue}
            size:=0
            buffer:[]u8
            if physics.breakable_revision(physics_state,st.handle)!=0 || st.sequence!=0 {
                ok:bool
                if buffer,ok=multiplayer.journal_buffer(j,physics.breakable_state_size(physics_state,st.handle));!ok {
                    core.report(problems,e,"destruct.net_memory","out of memory to send the state of this broken Destructible to a client; it is tried again in the next tick: free memory, or lower Physics_Settings.pieces")
                    continue
                }
                size=physics.breakable_state_write(physics_state,st.handle,buffer)
            }
            multiplayer.journal_part(j,sv,buffer[:size],true)
        }
    } else {
        for item in events.replayed.items {
            result:=multiplayer.Journal_Result.Done
            if !item.done {result=item.state && !item.failed?.Again:.Failed}
            multiplayer.journal_result(j,item.tag,result,u64(item.check),time)
        }
        multiplayer.journal_flush(j,outbox,time,session)
    }
    for group in events.grouped.items {
        if group.debris {continue}
        if authority.role==.Server {
            if held,found:=core.get(objects,group.owner);found {
                core.commands_add(commands,group.entity,multiplayer.Replicate{audience=held.audience,priority=held.priority,radius=multiplayer.REPLICATE_DEFAULT.radius})
            }
        } else {
            multiplayer.predict_kept(spawns,group.entity)
        }
    }
}
