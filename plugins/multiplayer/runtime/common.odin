package multiplayer

import "core:math/linalg"
import "core:mem"
import "mirai:core"
import input "mirai:engine/input"
import wire "mirai:net"

// What both ends do with the world: read and write the replicated components
// by reflection, move a replica, send events.

@(private)
row_stamp :: proc(table:^core.Raw_Table,e:core.Entity) -> u64 {
    if table==nil {return 0}
    row:=core.raw_row(table,e)
    return row<0?0:table.stamps[row]
}

@(private)
row_changed :: proc(table:^core.Raw_Table,e:core.Entity,stamp,layout:^u64) -> bool {
    if table==nil {return false}
    now:=row_stamp(table,e)
    changed:=now!=stamp^ || table.layout!=layout^
    stamp^,layout^=now,table.layout
    return changed
}

// The fragments an entity replicates: its pose, its motion when a simulation
// moves it, its driver when it has a Move_Input, and its replicated
// components, on or off. False when they do not fit an object.
@(private)
entity_kinds :: proc(s:^Net_Session,w:core.World_Ref,e:core.Entity,kinds:^[wire.MAX_FRAGMENTS]wire.Fragment_Id) -> (count:int,fits:bool) {
    kinds[0]=FRAGMENT_POSE
    count=1
    if core.staged(core.world_table_of(w,core.Motion),e)!=nil {
        kinds[count]=FRAGMENT_MOTION
        count+=1
    }
    if moves:=core.world_table_of(w,input.Move_Input);moves!=nil && core.staged(moves,e)!=nil {
        kinds[count]=FRAGMENT_DRIVER
        count+=1
    }
    components:=0
    for kind,table in s.fragments {
        if kind==wire.FRAGMENT_NONE {continue}
        info:=&w.info.tables[table]
        if core.raw_staged(core.world_table_at(w,info),info.info,e)==nil {continue}
        if components==COMPONENTS {return count,false}
        kinds[count]=kind
        count+=1
        components+=1
    }
    return count,true
}

// The velocities of what a simulation moves, as this end has them now.
@(private)
motion_read :: proc(w:core.World_Ref,e:core.Entity) -> (motion:Motion_State,awake:bool) {
    held:=core.staged(core.world_table_of(w,core.Motion),e)
    if held==nil {return}
    return {held.linear,held.angular},held.awake
}

// The fields of the components of a type that mask names, from the state a
// command carries into the entity; a component it lacks is added whole. One
// that names an entity this end does not have, not here yet or not
// replicated, leaves the entity until it does: it would name something else.
@(private)
components_apply :: proc(s:^Net_Session,w:core.World_Ref,e:core.Entity,t:^Net_Type,command:^wire.Command,mask:u64) {
    pending:=t.references!=0?wire.object_references_pending(&s.host,command):0
    for k in 0..<t.count {
        fragment:=t.first+k
        bits:=wire.type_fragment_mask(&s.protocol,t.type,fragment)
        if mask&bits==0 {continue}
        info:=&w.info.tables[t.tables[k]]
        table:=core.world_table_at(w,info)
        row:=core.raw_staged(table,info.info,e)
        if pending&bits!=0 {
            if row!=nil {core.raw_remove(table,e)}
            continue
        }
        if row!=nil {
            wire.object_read(&s.host,command,fragment,row,mask)
            continue
        }
        value:=s.scratch[:info.info.size]
        mem.zero_slice(value)
        wire.object_read(&s.host,command,fragment,raw_data(value),max(u64))
        core.raw_add(table,info.info,e,raw_data(value))
    }
}

// Puts an entity where a state of the network says, with those velocities:
// whoever owns its Transform takes it at the start of the next tick
// (core.Pose_Target). rest also puts a body to sleep there.
@(private)
pose_apply :: proc(s:^Net_Session,w:core.World_Ref,e:core.Entity,t:^Net_Type,pose:Pose,motion:Motion_State,follow:bool,rest:=false) {
    components_turn(w,e,t,pose.off)
    s.placed+=1
    replica_write(w,e,{
        follow=follow,placed=s.placed,rest=rest,position=pose.position,rotation=pose.rotation,scale=pose.scale,
        linear=motion.linear,angular=motion.angular,
    })
}

@(private) REPLICA_JUMP :: 4 // m a shown replica goes in a tick at the most: farther, it jumped there

// A shown replica heads for a state of the network in the tick, pushing what
// it touches; one farther than it goes in a tick is put there first.
@(private)
pose_follow :: proc(s:^Net_Session,w:core.World_Ref,e:core.Entity,t:^Net_Type,pose:Pose,motion:Motion_State) {
    components_turn(w,e,t,pose.off)
    value:=core.Pose_Target{
        follow=true,position=pose.position,rotation=pose.rotation,scale=pose.scale,
        linear=motion.linear,angular=motion.angular,
    }
    replicas:=core.world_table_of(w,core.Pose_Target)
    held:=core.staged(replicas,e)
    local,has:=core.get(core.read(core.world_table_of(w,core.Transform)),e)
    if held!=nil && has && linalg.length2(local.position-pose.position)<=REPLICA_JUMP*REPLICA_JUMP {
        value.placed=held.placed
    } else {
        s.placed+=1
        value.placed=s.placed
    }
    if held!=nil {held^=value} else {core.add(replicas,e,value)}
}

@(private)
replica_write :: proc(w:core.World_Ref,e:core.Entity,value:core.Pose_Target) {
    replicas:=core.world_table_of(w,core.Pose_Target)
    if held:=core.staged(replicas,e);held!=nil {held^=value} else {core.add(replicas,e,value)}
}

// The components of a type that the entity turned off by themselves, a bit each.
@(private)
components_off :: proc(w:core.World_Ref,e:core.Entity,t:^Net_Type) -> (mask:u16) {
    for k in 0..<t.count {
        // Which one of a single component is on is of each end: a sky active here, another there.
        if w.info.tables[t.tables[k]].single {continue}
        if _,off,_:=core.raw_state(core.world_table_at(w,&w.info.tables[t.tables[k]]),e);off {mask|=1<<u16(k)}
    }
    return
}

// Turns the components of a type off or on as the bits of a state say.
@(private)
components_turn :: proc(w:core.World_Ref,e:core.Entity,t:^Net_Type,mask:u16) {
    for k in 0..<t.count {
        info:=&w.info.tables[t.tables[k]]
        if info.single {continue}
        table:=core.world_table_at(w,info)
        _,off,found:=core.raw_state(table,e)
        want:=mask&(1<<u16(k))!=0
        // A row that waits for the end of the function turns after it is added.
        waits:=!found && core.raw_added(table,info.info,e)!=nil
        if !waits && (!found || off==want) {continue}
        if want {core.raw_disable(table,e)} else {core.raw_enable(table,e)}
    }
}

@(private)
driver_read :: proc(w:core.World_Ref,e:core.Entity) -> (value:Driver_State) {
    moves:=core.world_table_of(w,input.Move_Input)
    if moves!=nil {value.move,value.has_move=core.get(moves,e)}
    return
}

// The messages that arrived since the last tick, by type, where the
// core.Inbox(T) of each type reads them, in the order they arrived. The
// buffers trade places: those of the tick before wait for the next messages.
@(private)
messages_fill :: proc(s:^Net_Session,m:^core.Net_Messages) {
    if len(m.types)<len(s.received) && resize(&m.types,len(s.received))!=nil {
        core.report(s.problems,core.NONE,"net.memory","the messages that arrived were dropped: out of memory to hand them to the tick; free memory")
        for &pending in s.received {pending.count=0}
        return
    }
    for &pending,event in s.received {
        m.types[event],pending=pending,m.types[event]
        pending.count=0
    }
}

// Sends the messages the games queued.
@(private)
events_send :: proc(s:^Net_Session,outbox:^Net_Outbox) {
    h:=&s.host
    items:=outbox.queue.items[:]
    sent:=len(items)
    defer {
        remove_range(&outbox.queue.items,0,sent)
        if len(outbox.queue.items)==0 {clear(&outbox.bytes)}
    }
    for item,k in items {
        event:=-1
        for record,i in s.events {
            if record.type==item.type {event=i;break}
        }
        if event<0 {
            core.report(s.problems,core.NONE,"net.event","a message of type %v was not sent: it is not a message of the network; declare its structure @(net_message)",item.type)
            continue
        }
        object:Object
        if item.about!=core.NONE {
            object=wire.object_of_user(h,u64(item.about))
            if object==0 {
                core.report(s.problems,item.about,"net.event_about","a message of type %v about this entity was not sent: the entity is not replicated; send it about an entity with Replicate, or about none",item.type)
                continue
            }
        }
        // Where its fields are aligned.
        payload:=s.scratch[:s.events[event].size]
        copy(payload,outbox.bytes[item.at:])
        error:=wire.event_send(h,wire.Event_Id(event),object,raw_data(payload),item.to)
        if error==.None {
            s.stats.events_sent+=1
        } else if error==.Full && s.events[event].reliable {
            // The queue of a connection has no room: it waits for the next
            // frame with what was asked after it, in order.
            sent=k
            return
        } else {
            core.report(s.problems,item.about,"net.event_send","a message of type %v was not sent: the host refused it (%v): its queue is full, or it does not fit in a packet; send fewer or smaller messages",item.type,error)
        }
    }
}
