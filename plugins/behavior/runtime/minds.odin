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

MINDS_CAPACITY :: 16
MIND_NAME :: 16
MIND_ACTION_NAME :: 24

Mind_Name :: [MIND_NAME]u8

Mind_Entry :: struct {
    name:Mind_Name,
    actions:typeid, // the enum of its actions, in the binary of the game
    names:[ai.MIND_ACTIONS][MIND_ACTION_NAME]u8, // of each value of the enum, for whoever cannot read the enum (the editor)
}

// The minds registered, by name. Shared: every library that runs minds registers its own.
@(storage,host,shared)
Minds :: struct {
    entries:[MINDS_CAPACITY]Mind_Entry,
    count:int,
}

// An agent that decides with a mind: the name the game registered it by and
// what it runs, which the game's tick advances. Shared: every library that
// runs minds writes the agents of its own.
@(component,shared,description="Decides with the mind registered by this name: every tick its think procedure proposes actions with scores and the best runs.")
Mind_Agent :: struct {
    mind:Mind_Name `mirai:"text"`,
    state:ai.Mind `mirai:"hidden"`,
}

MIND_KEEP :: f32(0.05) // the margin of the running action of an agent over the others

// The rows of the Mind_Agents of each mind that ticked in a world, on then
// off, in the order of the table. They are grouped again when the rows move,
// when a mind ticks there the first time, and when an agent changed its mind:
// its old mind finds another name in its row, or a row of no mind found the
// name of one, at the first tick after. Shared: every library that runs minds
// keeps those of its own.
@(storage,host,by_world,shared,free="mind_rows_free")
Mind_Rows :: struct {
    names:[MINDS_CAPACITY]Mind_Name,
    actions:[MINDS_CAPACITY]typeid,    // each was registered with
    rows:[MINDS_CAPACITY][dynamic]i32, // of each
    loose:[dynamic]i32,                // of no mind that ticked in the world
    count:int,
    shape:core.Shape,
    tick:u64,                          // the loose rows were last looked at
    stale:bool,
}

mind_rows_free :: proc(g:^Mind_Rows) {
    for &rows in g.rows {delete(rows)}
    delete(g.loose)
    g^={}
}

// Registers a mind under a name, or replaces the one there (a game that
// changed its code). The generated world checks the name and how many minds
// there are when it builds.
mind_register :: proc(minds:^Minds,name:string,$A:typeid) {
    key,ok:=name_make(name)
    if !ok || minds==nil {return}
    for &entry in minds.entries[:clamp(minds.count,0,MINDS_CAPACITY)] {
        if entry.name!=key {continue}
        if entry.actions!=A {entry_set(&entry,key,A,type_info_of(A))}
        return
    }
    if minds.count>=MINDS_CAPACITY {return}
    entry_set(&minds.entries[minds.count],key,A,type_info_of(A))
    minds.count+=1
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
    for &entry in minds.entries[:clamp(minds.count,0,MINDS_CAPACITY)] {
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
// running action runs every tick, and it thinks too when that action ends. An
// agent far from the players (nav.Nav_Far) is off and decides on: its mind
// ticks once every step of what is far (nav.nav_far_decide), and what it
// claims lasts until its next tick. Only a world that plays decides, and a
// tick that runs again (time.resimulating) does not: its actions would repeat
// what they did. Without Mind_Rows it looks at every row.
minds_tick :: proc(w:^Mind_World,name:string,acts:^[$A]$P,think:proc(t:^ai.Think(A))) {
    key:=mind_name(name)
    slot:=mind_slot(w,name,key,A)
    time:=w.time
    if !time.playing || time.resimulating || time.dt<=0 {return}
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
        if !mind_row_is(w,row,key) {continue}
        e:=core.entity_at(agents,row)
        period:=u64(1)
        if near>0 && w.worlds!=nil {
            if at,ok:=core.get(w.worlds,e);ok {period=ai.cadence_period(scene.sources_distance(w.sources.ptr,at.position,at.position),near,slowest)}
        }
        mind_run(e,&core.edit_at(agents,row).state,acts,think,&ctx,ai.cadence_due(time.tick,u64(core.entity_index(e)),period))
    }
    if w.fars==nil || !nav.nav_far_decide(time) {return}
    // Until its next tick, once every step of what is far.
    ctx.lease=u32(nav.NAV_FAR_PERIOD/max(time.dt,1e-6)+0.5)+1
    for i in off..<total {
        row:=i
        if slot>=0 {row=int(rows[i])}
        if !mind_row_is(w,row,key) {continue}
        e:=agents.entities[row]
        if !far_of(w.fars,e) {continue}
        // edit_at reaches only the rows on: an off row is written in place.
        far:=cast(^Mind_Agent)core.raw_edit(core.raw(agents),type_info_of(Mind_Agent),e)
        mind_run(e,&far.state,acts,think,&ctx)
    }
}

// The index of a mind in the Mind_Rows of the world, which registers it
// the first time it ticks there and again when its actions are of another
// binary; -1 without Mind_Rows, registering it every tick.
@(private)
mind_slot :: proc(w:^Mind_World,name:string,key:Mind_Name,$A:typeid) -> int {
    g:=w.rows
    if g==nil {
        mind_register(w.minds,name,A)
        return -1
    }
    for i in 0..<g.count {
        if g.names[i]!=key {continue}
        if g.actions[i]!=A {
            mind_register(w.minds,name,A)
            g.actions[i]=A
        }
        return i
    }
    mind_register(w.minds,name,A)
    if g.count>=MINDS_CAPACITY {return -1}
    g.names[g.count],g.actions[g.count]=key,A
    g.count+=1
    g.stale=true
    return g.count-1
}

// Whether the row is of the mind; when it is no longer, its rows are grouped again.
@(private)
mind_row_is :: #force_inline proc "contextless" (w:^Mind_World,row:int,key:Mind_Name) -> bool {
    if w.agents.values[row].mind==key {return true}
    if w.rows!=nil {w.rows.stale=true}
    return false
}

// Groups the rows by mind again when they moved or went stale. False without memory.
@(private)
mind_rows_group :: proc(g:^Mind_Rows,agents:^core.Table(Mind_Agent),tick:u64) -> bool {
    moved:=core.reshaped(agents,&g.shape)
    if g.tick!=tick {
        g.tick=tick
        for row in g.loose {
            if int(row)<len(agents.entities) && mind_rows_index(g,agents.values[row].mind)>=0 {g.stale=true;break}
        }
    }
    if !moved && !g.stale {return true}
    g.stale=true
    for &rows in g.rows[:g.count] {clear(&rows)}
    clear(&g.loose)
    for row in 0..<len(agents.entities) {
        i:=mind_rows_index(g,agents.values[row].mind)
        if _,err:=append(&g.loose if i<0 else &g.rows[i],i32(row));err!=nil {return false}
    }
    g.stale=false
    return true
}

@(private)
mind_rows_index :: proc "contextless" (g:^Mind_Rows,name:Mind_Name) -> int {
    for i in 0..<g.count {
        if g.names[i]==name {return i}
    }
    return -1
}

// Reports the agents of a name no mind of the game declares.
@(step="fixed",stage="apply",server)
minds_unknown :: proc(minds:core.Ref(Minds),agents:^core.Table(Mind_Agent,.Read),time:core.Time,problems:^core.Problems) {
    if !time.playing || time.resimulating {return}
    for row in 0..<core.count(agents) {
        name:=agents.values[row].mind
        if mind_of(minds.ptr,name)!=nil {continue}
        text:=base.text_get(name[:])
        core.report(problems,core.entity_at(agents,row),"behavior.mind","No mind is declared as %q: give the think procedure of a mind @(mind=%q), or fix the name of its Mind_Agent",text,text)
    }
}

@(private)
mind_run :: proc(e:core.Entity,m:^ai.Mind,acts:^[$A]$P,think:proc(t:^ai.Think(A)),ctx:^ai.Mind_Context,decide:=true) {
    ctx.holder=u64(e)
    ai.mind_tick(m,acts,think,ctx,decide)
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
