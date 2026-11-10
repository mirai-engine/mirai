package destruct

import "mirai:core"
import physics "plugins:physics/runtime"
import "mirai:std/base"
import mm "mirai:std/math"

// The events this end causes are recorded in the frame of the body they are
// about (Destruct_Events.applied), and those another end recorded apply here
// from that frame to where this end has that body (replay), in their order:
// a destructible made from the same mesh breaks the same wherever its bodies are.

// The next event of the sequence of a destructible, in the frame of its body.
@(private)
event_note :: proc(c:^Ctx,e:core.Entity,event:physics.Break_Event) {
    st:=core.get(c.states,e)
    if st==nil || !physics.breakable_valid(c.view,st.handle) {return}
    count:=min(physics.breakable_pieces(c.view,st.handle,c.cache.infos),len(c.cache.infos))
    frame,_:=physics.body_pose(c.view,physics.breakable_body(c.view,st.handle))
    place:=max(u32)
    for piece,at in c.cache.infos[:count] {
        if piece.id==event.piece {place=u32(at)}
        // A piece the event cut left its frame to its halves.
        if piece.body!={} && (piece.id==event.piece || piece.parent==event.piece) {frame,_=physics.body_pose(c.view,piece.body)}
    }
    inverse:=conj(frame.q)
    st.sequence+=1
    core.push(&c.events.applied,Applied{e,{
        sequence=st.sequence,tick=u32(c.time.tick),piece=place,kind=event.kind,
        point=mm.quat_rotate(inverse,event.point-frame.p),vector=mm.quat_rotate(inverse,event.vector),radius=event.radius,strain=event.strain,
        half_extents=event.half_extents,rotation=inverse*(event.rotation==0?mm.QUAT_IDENTITY:event.rotation),falloff=event.falloff,
    }})
}

// The states, then the events, other ends recorded, in the order asked. A
// destructible whose replay is not done takes no more replays in the tick.
@(private)
replays_apply :: proc(c:^Ctx,states:[]State_Replay,replays:[]Replay) {
    for asked in states {
        done,failed:bool
        check:u32
        if st:=core.get(c.states,asked.entity);st!=nil && physics.breakable_valid(c.view,st.handle) {
            done,failed=state_apply(c,asked.entity,st,asked)
            if done {check=physics.breakable_check(c.view,st.handle)}
        }
        core.push(&c.events.replayed,Replayed{entity=asked.entity,sequence=asked.sequence,state=true,done=done,failed=failed,check=check})
    }
    for asked in replays {
        if replay_stopped(c,asked.entity) {continue}
        st:=core.get(c.states,asked.entity)
        entry:=entry_find(c.cache,asked.entity)
        done:=false
        check:u32
        if st!=nil && entry!=nil && physics.breakable_valid(c.view,st.handle) {
            done=event_replay(c,asked.entity,st,entry,asked.record)
            st.sequence=asked.record.sequence
            check=physics.breakable_check(c.view,st.handle)
            // The check is of the last event of a tick of the other end.
            if asked.check!=0 && asked.check!=check {done=false}
        }
        core.push(&c.events.replayed,Replayed{entity=asked.entity,sequence=asked.record.sequence,done=done,check=check})
    }
}

@(private)
replay_stopped :: proc(c:^Ctx,e:core.Entity) -> bool {
    for item in c.events.replayed.items {
        if item.entity==e && !item.done {return true}
    }
    return false
}

// An event another end recorded, from the frame of the body it was recorded
// in to where this end has that body.
@(private)
event_replay :: proc(c:^Ctx,e:core.Entity,st:^Destructible_State,entry:^Entry,record:Fracture_Record) -> bool {
    count:=min(physics.breakable_pieces(c.view,st.handle,c.cache.infos),len(c.cache.infos))
    event:=physics.Break_Event{breakable=st.handle,tick=record.tick,piece=-1,kind=record.kind,radius=record.radius,strain=record.strain,half_extents=record.half_extents,falloff=record.falloff}
    frame:physics.Body_Pose
    if record.piece==max(u32) {
        frame,_=physics.body_pose(c.view,physics.breakable_body(c.view,st.handle))
    } else {
        if int(record.piece)>=count {return false}
        piece:=c.cache.infos[record.piece]
        if piece.body=={} {return record.kind==.Remove}
        frame,_=physics.body_pose(c.view,piece.body)
        event.piece=piece.id
    }
    event.point=frame.p+mm.quat_rotate(frame.q,record.point)
    event.vector=mm.quat_rotate(frame.q,record.vector)
    event.rotation=frame.q*record.rotation
    physics.breakable_event_apply(c.state,event)
    event_applied(c,e,entry,event,false)
    return true
}

// Makes the destructible what the other end said it became. It is made again
// first, since a state applies to a destructible that is as created; the tick
// that follows makes it and the state is asked again: not done while that
// waits. failed: it does not apply here.
@(private)
state_apply :: proc(c:^Ctx,e:core.Entity,st:^Destructible_State,asked:State_Replay) -> (done,failed:bool) {
    remake :: proc(c:^Ctx,e:core.Entity,st:^Destructible_State) {
        physics.breakable_destroy(c.state,st.handle)
        c.cache.stats.destroyed+=1
        core.add(c.states,e,Destructible_State{})
    }
    if physics.breakable_revision(c.view,st.handle)!=0 || st.sequence!=0 {
        remake(c,e,st)
        return
    }
    if len(asked.data)>0 && !physics.breakable_state_apply(c.state,st.handle,asked.data) {
        // Half applied: whole again, and without this state.
        core.report(c.problems,e,"destruct.replay_state","a state of this Destructible recorded on another end did not apply, so it is made whole again; if it repeats, the two ends fracture different meshes: give both the same assets")
        remake(c,e,st)
        return false,true
    }
    st.sequence=asked.sequence
    return true,false
}

// The entity of a group of a broken destructible gets, in a network session,
// the Id every end draws alike from the Id of the destructible and the group.
@(private)
group_identify :: proc(c:^Ctx,owner,e:core.Entity,group:Scratch_Group) {
    if c.authority==.Standalone {return}
    destructible:=core.id_of(core.read(c.ids),owner)
    if destructible==0 {return}
    state:=base.hash_combine(u64(destructible),u64(group.group)+1)
    id:=core.id_new(c.es,&state)
    core.add(c.ids,e,core.Id{id})
    core.push(&c.events.grouped,Grouped{owner=owner,entity=e,id=id,debris=group.debris})
}
