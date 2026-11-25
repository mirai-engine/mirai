package abilities_multiplayer

import "base:runtime"
import "core:math/linalg"
import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"
import ab "plugins:abilities/runtime"
import anim "plugins:animation/runtime"
import multiplayer "plugins:multiplayer/runtime"
import phys "plugins:physics/runtime"

// Lag compensation of the rays of abilities. On a server, a pellet that the seat of a remote player
// aimed is judged where that player saw the others: at the tick its input says it showed them
// (multiplayer.rewind_tick), against the hit zones of each entity with multiplayer.Rewind as they
// were then, or its colliders at its pose then without zones, and against the rest of the world as
// it is. The zones of rewound entities are kept per tick in a ring as deep as the history of the
// poses (multiplayer.Rewind_History). It runs by itself between abilities_step and abilities_shots;
// nothing in the world moves, and the game calls nothing.

// The places of the zones of an entity in a tick.
Zone_Rewound :: struct {
    entity:core.Entity,
    placed_bits:u16,
    placed:[anim.HIT_ZONES]anim.Zone_Placed,
}

Zone_Frame :: struct {
    tick:u64, // 0: empty
    count:int,
    entries:[]Zone_Rewound, // room for as many entities as the poses of multiplayer.Rewind_History
}

// Server: a frame per tick, by tick modulo its length, as many as Rewind_History has. Of this end:
// neither copied with the world nor sent.
@(storage,host,by_world,free="zone_history_free")
Zone_History :: struct {
    frames:[]Zone_Frame,
    entries:[]Zone_Rewound,
    allocator:runtime.Allocator,
}

zone_history_free :: proc(history:^Zone_History) {
    delete(history.frames,history.allocator)
    delete(history.entries,history.allocator)
    history^={}
}

// The ring of slots ticks with room for the zones of entities entities each, made when the session
// first records zones, as a load: a stable tick does not allocate. False without memory.
zone_history_make :: proc(history:^Zone_History,slots,entities:int,allocator:runtime.Allocator) -> bool {
    zone_history_free(history)
    history.allocator=allocator
    error:runtime.Allocator_Error
    if history.frames,error=make([]Zone_Frame,slots,allocator);error!=nil {return false}
    if history.entries,error=make([]Zone_Rewound,slots*entities,allocator);error!=nil {zone_history_free(history);return false}
    for &frame,index in history.frames {frame.entries=history.entries[index*entities:][:entities]}
    return true
}

// At the end of a tick on a server, after the poses: the zones of every entity with Rewind that has
// placed ones, under the number of the tick. Nothing runs in a world without zones.
@(step="fixed",loops="game",stage="end",after="rewind_record",before="net_tick_tail")
abilities_rewind_record :: proc(
    session:core.Ref(multiplayer.Net_Session),time:core.Time,marked:^core.Table(multiplayer.Rewind,.Read),
    poses:^core.Table(anim.Hit_Zone_Pose,.Read),rewinds:core.Ref(multiplayer.Rewind_History),
    history:^Zone_History,allocator:runtime.Allocator,problems:^core.Problems,
) {
    if core.count(poses)==0 && len(history.frames)==0 {return}
    if session.ptr==nil || !session.host_ready || session.mode!=.Server || time.resimulating || rewinds.ptr==nil {return}
    slots:=len(rewinds.frames)
    if slots==0 {return}
    entities:=len(rewinds.frames[0].poses)
    if len(history.frames)!=slots || len(history.frames[0].entries)!=entities {
        if !zone_history_make(history,slots,entities,allocator) {
            core.report(problems,core.NONE,"abilities.rewind","the hit zones of %d ticks for lag compensation were not made (out of memory); free memory, or lower Net_Settings.replication.history_seconds or rewind_entities",slots-1)
            return
        }
    }
    zones_record(history,time.tick,marked,poses,problems)
}

// Keeps the zones of tick of the entities with Rewind that have placed ones.
zones_record :: proc(history:^Zone_History,tick:u64,marked:^core.Table(multiplayer.Rewind,$A),poses:^core.Table(anim.Hit_Zone_Pose,$B),problems:^core.Problems) {
    if len(history.frames)==0 {return}
    frame:=&history.frames[tick%u64(len(history.frames))]
    frame.tick,frame.count=tick,0
    for row in 0..<core.count(poses) {
        e:=core.entity_at(poses,row)
        pose:=core.at(poses,row)
        if pose.placed_bits==0 || !core.has(marked,e) {continue}
        if frame.count==len(frame.entries) {
            core.report(problems,e,"abilities.rewind","its hit zones are not remembered for lag compensation: more than %d entities have Rewind; give it to fewer, or raise Net_Settings.rewind_entities",len(frame.entries))
            continue
        }
        frame.entries[frame.count]={e,pose.placed_bits,pose.placed}
        frame.count+=1
    }
}

// The zones of e at a tick with fraction: between the frames of the two ticks around it, or the
// one before a teleport (multiplayer.REWIND_TELEPORT). False when the history does not have it.
zones_at :: proc(history:^Zone_History,e:core.Entity,tick:f64) -> (zones:Zone_Rewound,ok:bool) {
    if history==nil || tick<0 {return}
    whole:=u64(tick)
    zones=zone_find(history,e,whole) or_return
    after,has_after:=zone_find(history,e,whole+1)
    fraction:=f32(tick-f64(whole))
    if !has_after || fraction<=0 || after.placed_bits!=zones.placed_bits {return zones,true}
    for &at,i in zones.placed {
        if zones.placed_bits&(u16(1)<<u16(i))==0 {continue}
        next:=after.placed[i]
        if linalg.length(next.position-at.position)>multiplayer.REWIND_TELEPORT {continue}
        at={linalg.lerp(at.position,next.position,fraction),mm.quat_nlerp(at.rotation,next.rotation,fraction)}
    }
    return zones,true
}

@(private)
zone_find :: proc(history:^Zone_History,e:core.Entity,tick:u64) -> (zones:Zone_Rewound,ok:bool) {
    if len(history.frames)==0 || tick==0 {return}
    frame:=&history.frames[tick%u64(len(history.frames))]
    if frame.tick!=tick {return}
    for &entry in frame.entries[:frame.count] {
        if entry.entity==e {return entry,true}
    }
    return
}

// What the lag compensation of a tick reads.
@(params)
Rewind_World :: struct {
    seats:core.Ref(inp.Seats),
    net_seats:^core.Table(multiplayer.Net_Seat,.Read),
    inputs:core.Ref(multiplayer.Remote_Inputs),
    rewinds:core.Ref(multiplayer.Rewind_History),
    history:core.Ref(Zone_History),
    marked:^core.Table(multiplayer.Rewind,.Read),
    physics:core.Ref(phys.Physics_State),
    zone_sets:^core.Table(anim.Hit_Zone_Set,.Read),
    zone_poses:^core.Table(anim.Hit_Zone_Pose,.Read),
    zones:core.Records(anim.Hit_Zones),
    time:core.Time,
}

// Judges each pellet a remote seat aimed at the tick its player saw, before abilities_shots
// applies it. Nothing runs in a tick without pellets or without rewound entities.
@(step="fixed",loops="game",server,after="abilities_step",before="abilities_shots")
abilities_rewind :: proc(shots:^ab.Ability_Shots,w:Rewind_World) {
    if shots.count==0 || core.count(w.marked)==0 || w.history.ptr==nil {return}
    w:=w
    for &shot in shots.items[:min(shots.count,ab.SHOTS)] {
        if shot.resolved || shot.aim==core.NONE {continue}
        net,remote:=core.get(w.net_seats,inp.seat_of(w.seats,shot.aim))
        if !remote || net.connection==0 {continue}
        tick:=multiplayer.rewind_tick(w.inputs,net.connection,w.time) or_continue
        shot.hit=shot_rewind(&w,&shot,tick)
        shot.resolved=true
    }
}

// Where a pellet stops when the entities with Rewind are where they were at tick: their zones then
// (their colliders then, without zones), and the rest of the world as it is now.
shot_rewind :: proc(w:^Rewind_World,shot:^ab.Ability_Shot,tick:f64) -> ab.Shot_Hit {
    present:=ab.Shot_World{physics=w.physics,zone_sets=w.zone_sets,zone_poses=w.zone_poses,zones=w.zones}
    marked:=w.marked.entities[:core.count(w.marked)]
    best:=ab.shot_cast(&present,shot,marked)
    for e in marked {
        if e==shot.aim || e==shot.user {continue}
        if zones,found:=zones_at(w.history.ptr,e,tick);found {
            set,has:=core.get(w.zone_sets,e)
            hit:=anim.zones_ray(anim.zones_of(w.zones,set.zones) if has else nil,zones.placed[:],zones.placed_bits,shot.origin,shot.direction,best.distance,shot.radius) or_continue
            best={entity=e,point=hit.point,normal=hit.normal,distance=hit.distance,zone=i8(hit.zone),tags=hit.tags}
            continue
        }
        if w.rewinds.ptr==nil {continue}
        position,rotation:=multiplayer.rewind_pose(w.rewinds.ptr,e,tick) or_continue
        hit:=phys.raycast_at(w.physics,e,position,rotation,shot.origin,shot.direction,best.distance) or_continue
        if hit.distance<best.distance {best={entity=e,point=hit.point,normal=hit.normal,distance=hit.distance,zone=-1}}
    }
    return best
}
