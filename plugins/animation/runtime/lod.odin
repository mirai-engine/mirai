package anim

import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/ai"

// How much of the animation of a rig runs in a fixed tick, by its distance to the simulation
// sources (Animation_Budget_Config), never by what a view shows: a world and its copies, and a
// server and its clients, decide alike. Clocks, markers, events and root motion run in every tick;
// the zero value runs everything.
Rig_Lod :: struct {
    period:u32, // ticks between two of its poses (ai.cadence_period); 0 or 1: every tick
    wait:bool,  // not a tick of its cadence: its matching searches only when it must
    skip:bool,  // its pose is not evaluated: it keeps the last one, carried with its entity
    plain:bool, // its grounding, springs and twists do not run
}

// The decision of a rig in the tick under way, and the rig whose decision it shares: the rigs
// that follow another (Pose_Source, an attached rig) take that of the first of their chain.
@(private)
Lod_Rig :: struct {
    using lod:Rig_Lod,
    root:i32,    // in Playback.rigs
    read:bool,   // gameplay reads its pose: it runs everything
    forced:bool, // a member of its chain changes what it plays, or has no pose yet: it is posed
}

// What gameplay that reads the pose of a rig asks in each tick it reads it (a ragdoll, a hitbox
// placed by a bone): that rig is posed with all its modifiers in that tick, at any distance.
animation_read :: proc(requests:^Animation_Requests,rig:core.Entity) {
    if requests==nil {return}
    if rig==core.NONE {core.refuse(&requests.reads);return}
    core.offer(&requests.reads,rig)
}

// Whether someone watches what the world poses: a dedicated server runs its game without the
// phases Ui and Render (the editor draws the game it plays in its own loop, but runs its Ui).
// Outside a loop of the host (a test, a tool) it is watched.
@(private)
lod_presented :: proc "contextless" (app:^host.App) -> bool {
    if app==nil || app.played_count<=0 {return true}
    for played in app.played[:min(app.played_count,len(app.played))] {if played.phases&{.Ui,.Render}!={} {return true}}
    return false
}

// Decides, before the clocks of the tick, how much of each rig runs: Playback.work.lods by rig.
// A rig gameplay reads (animation_read, a Bone_Attachment, a pose asked of it, a field its curves
// write) runs everything, and so does the chain it is in; without sources, out of Play or with
// cadence_near and cosmetic_distance 0, everything runs where it is drawn. Where nothing is drawn,
// only what gameplay reads is posed.
@(private)
lod_decide :: proc(playback:^Playback,runtime:^Modifier_Runtime,requests:^Animation_Requests,
    fields:^Field_Playback,sources:^scene.Simulation_Sources,transforms:^core.Table(core.Transform),
    parents:^core.Table(core.Parent,.Read),config:Animation_Budget_Config,time:core.Time,
    presented:bool,problems:^core.Problems) {
    reads:=core.take(&requests.reads)
    lods:=&playback.work.lods
    clear(lods)
    playback.work.presented=presented
    cadence:=config.cadence_near>0 && config.cadence_near<=max(f32)
    cosmetic:=config.cosmetic_distance>0 && config.cosmetic_distance<=max(f32)
    if !time.playing || presented && !cadence && !cosmetic {return}
    count:=len(playback.rigs)
    if !program_array_resize(lods,count) {
        clear(lods)
        memory_problem(problems,core.NONE,"the level of detail of the rigs, so each is posed in full")
        return
    }
    mark :: proc(playback:^Playback,rig:core.Entity) {
        if at:=rig_find(playback,rig);at>=0 {playback.work.lods[at].read=true}
    }
    for &lod,i in lods {
        lod={root=i32(i)}
        if rig:=modifier_rig(core.ref(runtime),playback.rigs[i].entity);rig!=nil && len(rig.attachments)>0 {lod.read=true}
    }
    for rig in reads {mark(playback,rig)}
    for request in requests.poses.items {mark(playback,request.rig)}
    for request in requests.final_poses.items {mark(playback,request.rig)}
    if fields!=nil {for bound in fields.fields {mark(playback,bound.player)}}
    // The first rig of each chain: what a rig follows (Pose_Source), else what it is attached to.
    for &lod,i in lods {
        at:=i
        for _ in 0..<count {
            rig:=playback.rigs[at]
            next:=rig_find(playback,rig.leader if rig.leader!=core.NONE else rig.attachment)
            if next<0 || next==i {break}
            at=next
        }
        lod.root=i32(at)
    }
    for lod in lods {if lod.read {lods[lod.root].read=true}}
    slowest:=core.ticks_of(time,config.cadence_slowest)
    for &lod,i in lods {
        if lod.root!=i32(i) || lod.read {continue}
        e:=playback.rigs[i].entity
        distance:=f32(0)
        if at,placed:=constraint_world(transforms,parents,nil,e);placed {
            distance=scene.sources_distance(sources,at.position,at.position)
        }
        period:=ai.cadence_period(distance,config.cadence_near,slowest) if cadence else 1
        lod.period=u32(min(period,u64(max(u32))))
        lod.wait=!ai.cadence_due(time.tick,u64(core.entity_index(e)),period)
        lod.skip=lod.wait || !presented
        lod.plain=!presented || cosmetic && !(distance<=config.cosmetic_distance)
    }
    for &lod in lods {if lod.root>=0 {lod.lod=lods[lod.root].lod}}
}

// The decision of the rig at row of Playback.rigs for its state: everything without one.
@(private)
lod_of :: #force_inline proc "contextless" (playback:^Playback,row:int) -> Rig_Lod {
    return playback.work.lods[row].lod if row>=0 && row<len(playback.work.lods) else {}
}

// Once the clocks of the tick ran: a chain is posed whole when one of its rigs changes what it
// plays (a jump of its matching, an action that starts or ends: its blend starts in this tick)
// or has no pose yet, where poses are drawn. Each rig then takes the decision of its chain.
@(private)
lod_settle :: proc(playback:^Playback) {
    lods:=playback.work.lods[:]
    if len(lods)==0 {return}
    if playback.work.presented {
        for row in playback.work.rows {
            if row.rig<0 || int(row.rig)>=len(lods) {continue}
            state:=&playback.states[row.state]
            changed:=state.program.transition!=0 || state.stack!=nil && (state.stack.blend.slots|state.stack.blend.cuts)!=0
            if changed || !state.pose_ready {lods[lods[row.rig].root].forced=true}
        }
    }
    for row in playback.work.rows {
        if row.rig<0 || int(row.rig)>=len(lods) {continue}
        chain:=lods[lods[row.rig].root]
        state:=&playback.states[row.state]
        state.lod.skip=chain.skip && !chain.forced
    }
}

// Starts the springs and the grounding of a rig over from its pose.
@(private)
lod_restart :: proc "contextless" (rig:^Modifier_Rig) {
    for &binding in rig.grounding {grounding_reset(&binding.record)}
    for &binding in rig.spring_states {binding.springs={}}
}
