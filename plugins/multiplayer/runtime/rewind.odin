package multiplayer

import "base:runtime"
import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"

// Lag compensation: the server sees the world as a player saw it.
//
// A client shows the others interpolated, Clock.display behind the server:
// half the round trip, twice the jitter and the interpolation delay. What a
// player aims at is where the others were that long ago. Every input a client
// sends carries how far behind its tick it showed them
// (Input_Packet.view_behind, kept in Remote_Input.view as a tick), and the
// server remembers, tick by tick, the pose it published of each entity with
// Rewind. A game that judges an instant hit (a shot, a melee swing) asks
// rewind_tick for the tick that player saw and rewind_pose for where each
// target was then, and judges against that: nothing moves, and the world is
// never put back.

// How far back a player can be seen by default, within the history of the session.
REWIND_SECONDS :: f32(0.5)
// A move longer than this between two ticks is a teleport, metres: the pose
// is not interpolated across it.
REWIND_TELEPORT :: f32(2)

@(component,description="The server remembers its pose of the last ticks, so a hit is judged where the player who aimed saw it (lag compensation).")
Rewind :: struct {}

Rewind_Pose :: struct {
    entity:core.Entity,
    position:[3]f32,
    rotation:mm.Quat,
}

Rewind_Frame :: struct {
    tick:u64, // 0: empty
    count:int,
    poses:[]Rewind_Pose, // room for Net_Settings.rewind_entities
}

// Server: the poses of the entities with Rewind, a frame per tick in a ring as
// deep as the history of the session (session_history) and one more for the
// tick being written. It is of this end: neither copied with the world nor sent.
@(storage,host,by_world,free="rewind_free")
Rewind_History :: struct {
    frames:[]Rewind_Frame, // by tick modulo its length
    poses:[]Rewind_Pose,   // of every frame
    allocator:runtime.Allocator,
}

rewind_free :: proc(history:^Rewind_History) {
    delete(history.frames,history.allocator)
    delete(history.poses,history.allocator)
    history^={}
}

// The ring of slots ticks, each with room for the poses of entities entities. Made when the session opens, as
// a load: a stable tick does not allocate. False without memory.
rewind_make :: proc(history:^Rewind_History,slots,entities:int,allocator:runtime.Allocator) -> bool {
    rewind_free(history)
    history.allocator=allocator
    error:runtime.Allocator_Error
    if history.frames,error=make([]Rewind_Frame,slots,allocator);error!=nil {return false}
    if history.poses,error=make([]Rewind_Pose,slots*entities,allocator);error!=nil {rewind_free(history);return false}
    for &frame,index in history.frames {frame.poses=history.poses[index*entities:][:entities]}
    return true
}

// At the end of a tick, with what the server publishes: the Transform of
// every entity with Rewind, under the number of the tick.
@(step="fixed",loops="game",stage="end",before="net_tick_tail")
rewind_record :: proc(session:core.Ref(Net_Session),time:core.Time,marked:^core.Table(Rewind,.Read),transforms:^core.Table(core.Transform,.Read),history:^Rewind_History,allocator:runtime.Allocator,problems:^core.Problems) {
    if session.ptr==nil || !session.host_ready || session.mode!=.Server || time.resimulating {return}
    if slots:=session_history(session)+1;len(history.frames)!=slots && !rewind_make(history,slots,session.desc.rewind_entities,allocator) {
        core.report(problems,core.NONE,"multiplayer.rewind","the poses of %d ticks for lag compensation were not made (out of memory); free memory, or lower Net_Settings.replication.history_seconds or rewind_entities",slots-1)
        return
    }
    frame:=&history.frames[time.tick%u64(len(history.frames))]
    frame.tick,frame.count=time.tick,0
    for row in 0..<core.count(marked) {
        e:=core.entity_at(marked,row)
        placed,has:=core.get(transforms,e)
        if !has {continue}
        if frame.count==len(frame.poses) {
            core.report(problems,e,"multiplayer.rewind","its pose is not remembered for lag compensation: more than %d entities have Rewind; give it to fewer, or raise Net_Settings.rewind_entities",len(frame.poses))
            continue
        }
        frame.poses[frame.count]={e,placed.position,placed.rotation}
        frame.count+=1
    }
}

// Server: the tick, with fraction, that the client of a connection showed the
// others at when it sent the input of the tick being simulated: no later than
// that tick, and no more than max_seconds before it. false without an input
// that says it (a connection that sent none yet, or a lost one).
rewind_tick :: proc(inputs:core.Ref(Remote_Inputs),connection:Connection,time:core.Time,max_seconds:=REWIND_SECONDS) -> (tick:f64,ok:bool) {
    entry:=remote_entry(inputs.ptr,connection)
    if entry==nil || entry.status==.None || entry.view<=0 {return}
    now:=f64(time.tick)
    oldest:=now-(time.dt>0?f64(max_seconds/time.dt):0)
    return clamp(entry.view,max(oldest,0),now),true
}

// Where an entity with Rewind was at a tick with fraction, as the server
// published it: between the poses of the two ticks around it, or the one
// before a teleport. false when the history does not have it then.
rewind_pose :: proc(history:^Rewind_History,e:core.Entity,tick:f64) -> (position:[3]f32,rotation:mm.Quat,ok:bool) {
    if history==nil || tick<0 {return}
    whole:=u64(tick)
    before,has_before:=rewind_find(history,e,whole)
    if !has_before {return}
    after,has_after:=rewind_find(history,e,whole+1)
    fraction:=f32(tick-f64(whole))
    if !has_after || fraction<=0 || linalg.length(after.position-before.position)>REWIND_TELEPORT {
        return before.position,before.rotation,true
    }
    return linalg.lerp(before.position,after.position,fraction),mm.quat_nlerp(before.rotation,after.rotation,fraction),true
}

@(private)
rewind_find :: proc(history:^Rewind_History,e:core.Entity,tick:u64) -> (pose:Rewind_Pose,ok:bool) {
    if len(history.frames)==0 {return}
    frame:=&history.frames[tick%u64(len(history.frames))]
    if frame.tick!=tick || tick==0 {return}
    for p in frame.poses[:frame.count] {
        if p.entity==e {return p,true}
    }
    return
}
