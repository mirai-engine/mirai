package behavior

import "base:runtime"
import "mirai:core"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import scene "mirai:engine/scene"
import "mirai:engine/volume"
import nav "plugins:navigation/runtime"

// The minds of a game and the agents that run them. A mind is an enum of
// actions, a procedure for each and a think procedure that proposes them
// (ai.mind_tick). The game declares its think with @(mind="name") and each
// action with @(act="Value"), and the world generator ticks the agents of each
// mind in a fixed, server step named after its think: it binds what the
// procedures of the mind receive, as for any step, and calls minds_tick,
// which registers the mind by name the first time it ticks in a world and
// gives the agents far from the players their tick. The registry is the same
// for every world; the state of each agent is plain data in its Mind_Agent and
// copies with the world, and each world keeps the rows of each mind
// (Mind_Rows), so that a mind visits only its own agents. A tick that runs
// again decides nothing. What an action plays (anim.play, anim.look) reaches
// the clients through the replicated state of the animation.

MIND_NAME :: 16
MIND_ACTION_NAME :: 24

Mind_Name :: [MIND_NAME]u8

Mind_Entry :: struct {
    name:Mind_Name,
    actions:typeid, // the enum of its actions, in the binary of the game
    names:[ai.MIND_ACTIONS][MIND_ACTION_NAME]u8, // of each value of the enum, for whoever cannot read the enum (the editor)
}

// The minds registered, by name, as many as the game declares: each one is
// added the first time it ticks. Shared: every library that runs minds
// registers its own.
@(storage,host,shared,free="minds_free")
Minds :: struct {
    entries:[dynamic]Mind_Entry,
}

minds_free :: proc(minds:^Minds) {
    delete(minds.entries)
    minds^={}
}

// An agent that decides with a mind: the name the game registered it by and
// what it runs, which the game's tick advances. Shared: every library that
// runs minds writes the agents of its own.
@(component,shared,description="Decides with the mind registered by this name: every tick its think procedure proposes actions with scores and the best runs.")
Mind_Agent :: struct {
    mind:Mind_Name `mirai:"text"`,
    state:ai.Mind `mirai:"hidden"`,
    // The mind whose actions `state` is of: when `mind` names another, this
    // one exits what runs before the new one ticks the agent.
    owner:Mind_Name `mirai:"hidden"`,
}

MIND_KEEP :: f32(0.05) // the margin of the running action of an agent over the others

// The rows of the Mind_Agents of each mind that ticked in a world, on then
// off, in the order of the table: a row is of its owner while the owner
// still has to exit its action, else of its mind. They are grouped again when
// the rows move, when a mind ticks there the first time, and when an agent
// changed its mind: its old mind finds another name in its row, or a row of
// no mind found the name of one, at the first tick after. Shared: every
// library that runs minds keeps those of its own.
@(storage,host,by_world,shared,free="mind_rows_free")
Mind_Rows :: struct {
    names:[dynamic]Mind_Name,
    actions:[dynamic]typeid,    // each was registered with
    rows:[dynamic][dynamic]i32, // of each
    loose:[dynamic]i32,         // of no mind that ticked in the world
    shape:core.Shape,
    tick:u64,                   // the loose rows were last looked at
    first:u64,                  // the first tick a mind ticked in the world: every mind did by the next
    begun,stale:bool,
}

mind_rows_free :: proc(g:^Mind_Rows) {
    for &rows in g.rows {delete(rows)}
    delete(g.names)
    delete(g.actions)
    delete(g.rows)
    delete(g.loose)
    g^={}
}

// Agents to think at their next tick whatever their cadence: an event of the
// game for them (damage, an order). minds_wake also wakes those that noticed
// something (Perception_Events) and those navigation told about their path
// (Nav_Events).
@(storage,queue)
Mind_Wakes :: struct {
    using queue:core.Queue(core.Entity),
}

wake :: proc(wakes:^Mind_Wakes,e:core.Entity) {
    if wakes!=nil && e!=core.NONE {core.push(&wakes.queue,e)}
}

// The agents that think in this tick whatever their cadence, a bit by the
// index of their entity: minds_wake, its only writer, sets them before the
// minds tick and clears them at the next tick.
@(storage)
Mind_Woken :: struct {
    bits:[dynamic]u64,
    any:bool,
}

// Gathers the wakes of the tick: those asked, what the perceivers noticed in
// this tick and what navigation told the agents in the tick before. It grows
// only with the entities.
@(step="fixed",stage="input",after="perception_update",server)
minds_wake :: proc(
    woken:^Mind_Woken,wakes:^Mind_Wakes,noticed:core.Ref(Perception_Events),paths:core.Ref(nav.Nav_Events),
    entities:core.Ref(core.Entities),problems:^core.Problems,
) {
    if woken.any {
        for &word in woken.bits {word=0}
        woken.any=false
    }
    if entities.ptr!=nil {
        if words:=(len(entities.generation)+63)/64;len(woken.bits)<words && resize(&woken.bits,words)!=nil {
            core.report(problems,core.NONE,"behavior.memory","No memory to wake the minds; free memory")
        }
    }
    for e in core.take(&wakes.queue) {mind_wake(woken,e)}
    if noticed.ptr!=nil {
        for event in noticed.items {if event.kind==.Noticed {mind_wake(woken,event.perceiver)}}
    }
    if paths.ptr!=nil {
        for event in paths.items {mind_wake(woken,event.entity)}
    }
}

@(private)
mind_wake :: proc "contextless" (woken:^Mind_Woken,e:core.Entity) {
    i:=core.entity_index(e)
    if e==core.NONE || i>>6>=len(woken.bits) {return}
    woken.bits[i>>6]|=1<<uint(i&63)
    woken.any=true
}

// Whether the agent thinks in this tick whatever its cadence.
mind_woken :: #force_inline proc "contextless" (woken:^Mind_Woken,e:core.Entity) -> bool {
    if woken==nil {return false}
    i:=core.entity_index(e)
    return i>>6<len(woken.bits) && woken.bits[i>>6]&(1<<uint(i&63))!=0
}

// Registers a mind under a name, or replaces the one there (a game that
// changed its code). False without memory.
mind_register :: proc(minds:^Minds,name:string,$A:typeid) -> bool {
    key,ok:=name_make(name)
    if !ok || minds==nil {return false}
    for &entry in minds.entries {
        if entry.name!=key {continue}
        if entry.actions!=A {entry_set(&entry,key,A,type_info_of(A))}
        return true
    }
    if _,err:=append(&minds.entries,Mind_Entry{});err!=nil {return false}
    entry_set(&minds.entries[len(minds.entries)-1],key,A,type_info_of(A))
    return true
}

// The names come from the type info of the binary that registers: the editor
// and the plugins are other binaries, which do not know the enums of a game.
@(private)
entry_set :: proc "contextless" (entry:^Mind_Entry,name:Mind_Name,actions:typeid,info:^runtime.Type_Info) {
    entry^={name=name,actions=actions}
    t:=info
    for t!=nil {
        named,ok:=t.variant.(runtime.Type_Info_Named)
        if !ok {break}
        t=named.base
    }
    if t==nil {return}
    e,ok:=t.variant.(runtime.Type_Info_Enum)
    if !ok {return}
    for value,i in e.values {
        if value>=0 && int(value)<ai.MIND_ACTIONS && i<len(e.names) {base.text_set(entry.names[value][:],e.names[i])}
    }
}

// The name of a value of the enum of a mind; empty when it has none.
mind_action_name :: proc(entry:^Mind_Entry,action:u16) -> string {
    if entry==nil || int(action)>=ai.MIND_ACTIONS {return ""}
    return base.text_get(entry.names[action][:])
}

// The mind registered under a name, or nil.
mind_of :: proc "contextless" (minds:^Minds,name:Mind_Name) -> ^Mind_Entry {
    if minds==nil {return nil}
    for &entry in minds.entries {
        if entry.name==name {return &entry}
    }
    return nil
}

mind_name :: proc "contextless" (name:string) -> Mind_Name {
    key,_:=name_make(name)
    return key
}

// What every mind reads and asks for: its agents, how they walk,
// the smart objects and the claims. The generated step of a mind binds it
// first in the context of the mind, which the procedures of the mind reach
// through their ai.Mind_Context: the helpers of behavior take only the
// action or the think.
@(params)
Mind_World :: struct {
    minds:^Minds,
    agents:^core.Table(Mind_Agent),
    rows:^Mind_Rows,
    requests:^nav.Nav_Requests,
    paths:^core.Table(nav.Nav_Path,.Read),
    fars:^core.Table(nav.Nav_Far,.Read),
    objects:^core.Table(Smart_Object,.Read),
    smart_index:core.Ref(Smart_Index),
    states:^core.Table(Smart_State,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    patrols:^core.Table(Patrol),
    splines:^core.Table(volume.Spline,.Read),
    claims:^Claims,
    woken:core.Ref(Mind_Woken),
    sources:core.Ref(scene.Simulation_Sources),
    settings:core.Ref(Behavior_Settings),
    problems:^core.Problems,
    time:core.Time,
}

// Ticks every agent of a mind, registered the first time it ticks in the
// world: ctx.holder is the agent, as the holder of what it claims, and
// ctx.user is w, the start of the context of the mind. An agent thinks less
// often the farther it is from the simulation sources (the bodies the seats
// drive, each Streaming_Source): once every ai.cadence_period ticks of
// Behavior_Settings.think_near, each on the ticks of its own phase; its
// running action runs every tick, and it thinks too when that action ends or
// when it is woken (Mind_Woken). An agent far from the players (nav.Nav_Far)
// is off and decides on: its mind ticks once every step of what is far
// (nav.nav_far_decide), and what it claims lasts until its next tick. An
// agent whose Mind_Agent.mind changed is ticked by its new mind once the old
// one exited what it ran (Aborted) and forgot its state. Only a world that
// plays decides. A tick that runs again (time.resimulating) decides again, as
// the copy it runs from holds the minds as they were: it is a replay of the
// history of the editor, since a client, which corrects its prediction, runs
// no server step. Without Mind_Rows it looks at every row.
minds_tick :: proc(w:^Mind_World,name:string,acts:^[$A]$P,think:proc(t:^ai.Think(A))) {
    key:=mind_name(name)
    time:=w.time
    slot,registered:=mind_slot(w,name,key,A,time.tick)
    if !registered {
        core.report(w.problems,core.NONE,"behavior.memory","No memory to register the mind %q; free memory",name)
        return
    }
    if !time.playing || time.dt<=0 {return}
    agents:=w.agents
    on:=core.count(agents)
    total:=len(agents.entities)
    rows:[]i32
    if slot>=0 {
        if !mind_rows_group(w.rows,agents,time.tick) {
            core.report(w.problems,core.NONE,"behavior.memory","No memory to group the agents of the minds; free memory")
            return
        }
        rows=w.rows.rows[slot][:]
        total=len(rows)
    }
    near:=w.settings.think_near if w.settings.ptr!=nil else 0
    slowest:=core.ticks_of(time,w.settings.think_slowest) if w.settings.ptr!=nil else 0
    ctx:=ai.Mind_Context{user=w,tick=time.tick,dt=time.dt,keep=MIND_KEEP,lease=1}
    if w.claims!=nil {ctx.reservations=&w.claims.reservations}
    // The rows after those on are off: of them, the agents far.
    off:=total
    for i in 0..<total {
        row:=i
        if slot>=0 {row=int(rows[i])}
        if row>=on {off=i;break}
        turn:=mind_turn(w,&agents.values[row],key,time.tick)
        if turn==.Skip {continue}
        e:=core.entity_at(agents,row)
        agent:=core.edit_at(agents,row)
        if turn==.Stop {
            mind_halt(w,e,agent,acts,&ctx)
            continue
        }
        decide:=mind_woken(w.woken.ptr,e)
        if !decide {
            period:=u64(1)
            if near>0 && w.worlds!=nil {
                if at,ok:=core.get(w.worlds,e);ok {period=ai.cadence_period(scene.sources_distance(w.sources.ptr,at.position,at.position),near,slowest)}
            }
            decide=ai.cadence_due(time.tick,u64(core.entity_index(e)),period)
        }
        mind_run(e,agent,key,acts,think,&ctx,decide)
    }
    if w.fars==nil || !nav.nav_far_decide(time) {return}
    // Until its next tick, once every step of what is far.
    ctx.lease=u32(nav.NAV_FAR_PERIOD/max(time.dt,1e-6)+0.5)+1
    for i in off..<total {
        row:=i
        if slot>=0 {row=int(rows[i])}
        e:=agents.entities[row]
        if !far_of(w.fars,e) {continue}
        // edit_at reaches only the rows on: an off row is written in place.
        far:=cast(^Mind_Agent)core.raw_edit(core.raw(agents),type_info_of(Mind_Agent),e)
        switch mind_turn(w,far,key,time.tick) {
        case .Skip:
        case .Stop: mind_halt(w,e,far,acts,&ctx)
        case .Run: mind_run(e,far,key,acts,think,&ctx)
        }
    }
}

// The index of a mind in the Mind_Rows of the world, which registers it
// the first time it ticks there and again when its actions are of another
// binary; -1 without Mind_Rows, registering it every tick. False without
// memory.
@(private)
mind_slot :: proc(w:^Mind_World,name:string,key:Mind_Name,$A:typeid,tick:u64) -> (int,bool) {
    g:=w.rows
    if g==nil {return -1,mind_register(w.minds,name,A)}
    if !g.begun {g.begun,g.first=true,tick}
    for i in 0..<len(g.names) {
        if g.names[i]!=key {continue}
        if g.actions[i]!=A {
            if !mind_register(w.minds,name,A) {return -1,false}
            g.actions[i]=A
        }
        return i,true
    }
    if !mind_register(w.minds,name,A) {return -1,false}
    if _,err:=append(&g.names,key);err!=nil {return -1,false}
    if _,err:=append(&g.actions,A);err!=nil {
        pop(&g.names)
        return -1,false
    }
    if _,err:=append(&g.rows,[dynamic]i32{});err!=nil {
        pop(&g.names)
        pop(&g.actions)
        return -1,false
    }
    g.stale=true
    return len(g.names)-1,true
}

@(private)
Mind_Turn :: enum u8 {
    Skip, // not of this mind, or of a new one that waits for its old one to exit
    Run,
    Stop, // the agent changed its mind: this one, its owner, exits what it runs
}

// What the mind `key` does with an agent in this tick. A state owned by a
// mind that does not tick in the world (once every mind ticked there) is
// forgotten by the new one, which cannot run its Exit. Without Mind_Rows a
// mind waits for any registered owner. A row in the group of another mind
// groups them again.
@(private)
mind_turn :: proc "contextless" (w:^Mind_World,agent:^Mind_Agent,key:Mind_Name,tick:u64) -> Mind_Turn {
    none:Mind_Name
    if agent.mind==key && (agent.owner==key || agent.owner==none) {return .Run}
    if agent.owner==key {return .Stop}
    if agent.mind==key {
        waits:=mind_of(w.minds,agent.owner)!=nil
        if g:=w.rows;g!=nil {waits=mind_rows_index(g,agent.owner)>=0 || g.first==tick}
        if !waits {return .Run}
    }
    if w.rows!=nil {w.rows.stale=true}
    return .Skip
}

// Exits what the agent runs with Aborted, with the procedures of the mind
// that owns its state, and forgets that state: its exits and cooldowns are
// of values of this mind's enum.
@(private)
mind_halt :: proc(w:^Mind_World,e:core.Entity,agent:^Mind_Agent,acts:^[$A]$P,ctx:^ai.Mind_Context) {
    ctx.holder=u64(e)
    ai.mind_stop(&agent.state,acts,ctx)
    ai.mind_clear(&agent.state,ctx.reservations,ctx.holder)
    agent.owner={}
    if w.rows!=nil {w.rows.stale=true}
}

// Groups the rows by mind again when they moved or went stale. False without memory.
@(private)
mind_rows_group :: proc(g:^Mind_Rows,agents:^core.Table(Mind_Agent),tick:u64) -> bool {
    moved:=core.reshaped(agents,&g.shape)
    if g.tick!=tick {
        g.tick=tick
        for row in g.loose {
            if int(row)<len(agents.entities) && mind_rows_index(g,mind_row_name(g,&agents.values[row]))>=0 {g.stale=true;break}
        }
    }
    if !moved && !g.stale {return true}
    g.stale=true
    for &rows in g.rows {clear(&rows)}
    clear(&g.loose)
    for row in 0..<len(agents.entities) {
        i:=mind_rows_index(g,mind_row_name(g,&agents.values[row]))
        if _,err:=append(&g.loose if i<0 else &g.rows[i],i32(row));err!=nil {return false}
    }
    g.stale=false
    return true
}

// The mind a row is grouped with: its owner while that ticks in the world and
// has to exit its action, else its mind.
@(private)
mind_row_name :: proc "contextless" (g:^Mind_Rows,agent:^Mind_Agent) -> Mind_Name {
    none:Mind_Name
    if agent.owner!=none && agent.owner!=agent.mind && mind_rows_index(g,agent.owner)>=0 {return agent.owner}
    return agent.mind
}

@(private)
mind_rows_index :: proc "contextless" (g:^Mind_Rows,name:Mind_Name) -> int {
    for i in 0..<len(g.names) {
        if g.names[i]==name {return i}
    }
    return -1
}

// Reports the agents of a name no mind of the game declares.
@(step="fixed",stage="apply",server)
minds_unknown :: proc(minds:core.Ref(Minds),agents:^core.Table(Mind_Agent,.Read),time:core.Time,problems:^core.Problems) {
    if !time.playing {return}
    for row in 0..<core.count(agents) {
        name:=agents.values[row].mind
        if mind_of(minds.ptr,name)!=nil {continue}
        text:=base.text_get(name[:])
        core.report(problems,core.entity_at(agents,row),"behavior.mind","No mind is declared as %q: give the think procedure of a mind @(mind=%q), or fix the name of its Mind_Agent",text,text)
    }
}

// Ticks the agent with the mind `key`, which owns its state from now on: a
// state of a mind that cannot exit it is forgotten first.
@(private)
mind_run :: proc(e:core.Entity,agent:^Mind_Agent,key:Mind_Name,acts:^[$A]$P,think:proc(t:^ai.Think(A)),ctx:^ai.Mind_Context,decide:=true) {
    ctx.holder=u64(e)
    if agent.owner!=key {
        none:Mind_Name
        if agent.owner!=none {ai.mind_clear(&agent.state,ctx.reservations,ctx.holder)}
        agent.owner=key
    }
    ai.mind_tick(&agent.state,acts,think,ctx,decide)
}

// The agent a procedure of a mind runs for: of its ai.Act or its ai.Think.
agent :: #force_inline proc "contextless" (a:^$T) -> core.Entity {return core.Entity(a.holder)}

@(private)
world_of :: #force_inline proc "contextless" (a:^$T) -> ^Mind_World {return (^Mind_World)(a.user)}

// The Nav_Path of the agent of an action or a think procedure: on, or off
// while it is far.
agent_path :: proc(a:^$T) -> (nav.Nav_Path,bool) {
    w,e:=world_of(a),agent(a)
    return read_row(w.paths,e,far_of(w.fars,e))
}

@(private)
behavior_row :: proc "contextless" (table:^core.Table($T,$A),e:core.Entity,include_off:bool) -> int {
    if table==nil {return -1}
    if include_off {return core.raw_row(core.raw(table),e)}
    return core.row_of(table,e)
}

@(private)
read_row :: proc "contextless" (table:^core.Table($T,$A),e:core.Entity,include_off:bool) -> (T,bool) {
    if row:=behavior_row(table,e,include_off);row>=0 {return table.values[row],true}
    return {},false
}

// Walks the agent to `goal`: Success when it arrives, Failure when
// navigation cannot take it there; it stops the agent when the action is
// interrupted.
move_act :: proc(a:^ai.Act($A),goal:[3]f32) -> ai.Status {
    w,e:=world_of(a),agent(a)
    switch a.phase {
    case .Enter:
        nav.nav_move_to(w.requests,e,goal)
        return .Running
    case .Update:
        return path_status(a)
    case .Exit:
        if a.cause==.Aborted {nav.nav_stop(w.requests,e)}
    }
    return .Success
}

// Follows `target`, keeping `distance`, and follows the new one when the
// target changes: Running while it follows, Failure without a target or when
// navigation cannot; it stops the agent on Exit. It keeps the target in the
// first word of its memory.
chase_act :: proc(a:^ai.Act($A),target:core.Entity,distance:f32) -> ai.Status {
    w,e:=world_of(a),agent(a)
    if a.phase==.Exit {
        nav.nav_stop(w.requests,e)
        return .Success
    }
    if target==core.NONE {return .Failure}
    if a.phase==.Enter || u64(target)!=a.memory[0] {
        a.memory[0]=u64(target)
        nav.nav_follow(w.requests,e,target,distance)
        return .Running
    }
    p,ok:=agent_path(a)
    return .Failure if ok && p.state==.Failed else .Running
}

// Running while the agent walks or waits for its path, Success once there
// (Failure when it could only get near), Failure when navigation failed.
path_status :: proc(a:^$T) -> ai.Status {
    p,ok:=agent_path(a)
    if !ok {return .Running}
    #partial switch p.state {
    case .Arrived: return .Failure if p.partial else .Success
    case .Failed,.Idle,.Arrived_Partial: return .Failure
    }
    return .Running
}

// A name for a mind: false when it is empty or longer than a Mind_Name holds.
name_make :: proc "contextless" (text:string) -> (name:Mind_Name,ok:bool) {
    if len(text)==0 || len(text)>=MIND_NAME {return}
    base.text_set(name[:],text)
    return name,true
}
