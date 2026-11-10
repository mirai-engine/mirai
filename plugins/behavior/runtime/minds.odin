package behavior

import "base:runtime"
import "mirai:core"
import "mirai:std/ai"
import "mirai:std/base"
import nav "plugins:navigation/runtime"

// The minds of a game and the agents that run them. A mind is an enum of
// actions, a procedure for each and a think procedure that proposes them
// (ai.mind_tick). The game declares its think with @(mind="name") and each
// action with @(act="Value"), and the world generator ticks the agents of each
// mind in a fixed, server step named after its think: it binds what the
// procedures of the mind receive, as for any step, and calls minds_tick,
// which registers the mind by name and gives the agents far from the players
// their tick. The registry is the same for every world; the state of each
// agent is plain data in its Mind_Agent and copies with the world. A tick
// that runs again decides nothing, and the clients see what each agent does
// in its Mind_Presentation.

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

// What the players see of what the mind of an agent does, written where it
// decides and replicated: the clients show it (an animation, where the head
// turns) without running the mind. It travels if the entity has it when it
// is first replicated: its prefab carries it with its Mind_Agent.
@(component,shared,replicated,description="What the players see of what the mind of this agent does: its action and step, what it looks at and the animation it asks for. Written on the server, replicated to the clients.")
Mind_Presentation :: struct {
    action:u16 `mirai:"readonly"`,         // the value of the enum of the action that runs, ai.MIND_NONE
    step:u16 `mirai:"readonly"`,           // of the step it runs, ai.MIND_NONE
    look:core.Entity `mirai:"readonly"`,  // what it looks at, or none
    look_point:[3]f32 `mirai:"readonly,unit=m,precision=0.01"`, // where it looks without an entity
    animation:u16 `mirai:"readonly"`,     // the game's id of the animation it asks for
    animations:u16 `mirai:"readonly"`,    // times it asked for one: the same animation asked again shows again
}
MIND_PRESENTATION_DEFAULT :: Mind_Presentation{action=ai.MIND_NONE,step=ai.MIND_NONE,animation=ai.MIND_NONE}

MIND_KEEP :: f32(0.05) // the margin of the running action of an agent over the others

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

// What every mind reads and asks for: its agents, how they walk and show,
// the smart objects and the claims. The generated step of a mind binds it
// first in the context of the mind, which the procedures of the mind reach
// through their ai.Mind_Context: the helpers of behavior take only the
// action or the think.
@(params)
Mind_World :: struct {
    minds:^Minds,
    agents:^core.Table(Mind_Agent),
    presentations:^core.Table(Mind_Presentation),
    requests:^nav.Nav_Requests,
    paths:^core.Table(nav.Nav_Path,.Read),
    fars:^core.Table(nav.Nav_Far,.Read),
    objects:^core.Table(Smart_Object,.Read),
    states:^core.Table(Smart_State,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    claims:^Claims,
    time:core.Time,
}

// Ticks every agent of a mind, after registering it: ctx.holder is the agent,
// as the holder of what it claims, and ctx.user is w, the start of the
// context of the mind. After its tick its Mind_Presentation (an agent without
// one gets it before) shows the action and the step it runs. An agent far
// from the players (nav.Nav_Far) is off and decides on: its mind ticks once
// every step of what is far (nav.nav_far_decide), and what it claims lasts
// until its next tick. Only a world that plays decides, and a tick that runs
// again (time.resimulating) does not: its actions would repeat what they did.
minds_tick :: proc(w:^Mind_World,name:string,acts:^[$A]$P,think:proc(t:^ai.Think(A))) {
    mind_register(w.minds,name,A)
    time:=w.time
    if !time.playing || time.resimulating || time.dt<=0 {return}
    key:=mind_name(name)
    agents:=w.agents
    ctx:=ai.Mind_Context{user=w,tick=time.tick,dt=time.dt,keep=MIND_KEEP,lease=1}
    if w.claims!=nil {ctx.reservations=&w.claims.reservations}
    for row in 0..<core.count(agents) {
        if agents.values[row].mind!=key {continue}
        mind_run(w,core.entity_at(agents,row),&core.edit_at(agents,row).state,acts,think,&ctx)
    }
    if w.fars==nil || !nav.nav_far_decide(time) {return}
    // Until its next tick, once every step of what is far.
    ctx.lease=u32(nav.NAV_FAR_PERIOD/max(time.dt,1e-6)+0.5)+1
    // The rows after those on are off: of them, the agents far.
    for row in core.count(agents)..<len(agents.entities) {
        if agents.values[row].mind!=key {continue}
        e:=agents.entities[row]
        if core.raw_find(core.raw(w.fars),type_info_of(nav.Nav_Far),e)==nil {continue}
        mind_run(w,e,&core.edit_at(agents,row).state,acts,think,&ctx)
    }
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
mind_run :: proc(w:^Mind_World,e:core.Entity,m:^ai.Mind,acts:^[$A]$P,think:proc(t:^ai.Think(A)),ctx:^ai.Mind_Context) {
    ctx.holder=u64(e)
    if w.presentations!=nil {
        if _,found:=presentation_read(w.presentations,e);!found {core.add(w.presentations,e,MIND_PRESENTATION_DEFAULT)}
    }
    ai.mind_tick(m,acts,think,ctx)
    shown,found:=presentation_read(w.presentations,e)
    if !found {return}
    next:=shown
    next.action,next.step=ai.mind_running(m)
    if next!=shown {presentation_write(w.presentations,e,next)}
}

// The agent a procedure of a mind runs for: of its ai.Act or its ai.Think.
agent :: #force_inline proc "contextless" (a:^$T) -> core.Entity {return core.Entity(a.holder)}

@(private)
world_of :: #force_inline proc "contextless" (a:^$T) -> ^Mind_World {return (^Mind_World)(a.user)}

// The Mind_Presentation of an agent: the one it is given in this function,
// or its row, on or off while it is far.
@(private)
presentation_read :: proc(presentations:^core.Table(Mind_Presentation),e:core.Entity) -> (shown:Mind_Presentation,ok:bool) {
    if presentations==nil {return}
    t:=core.raw(presentations)
    found:=core.raw_added(t,type_info_of(Mind_Presentation),e)
    if found==nil {found=core.raw_find(t,type_info_of(Mind_Presentation),e)}
    if found==nil {return}
    return (cast(^Mind_Presentation)found)^,true
}

@(private)
presentation_write :: proc(presentations:^core.Table(Mind_Presentation),e:core.Entity,shown:Mind_Presentation) {
    if row:=cast(^Mind_Presentation)core.raw_staged(core.raw(presentations),type_info_of(Mind_Presentation),e);row!=nil {row^=shown}
}

// The agent looks at an entity, or at a point without one, as the players
// see it. Without its Mind_Presentation, nothing.
present_look :: proc(a:^ai.Act($A),target:core.Entity,point:[3]f32={}) {
    w,e:=world_of(a),agent(a)
    shown,found:=presentation_read(w.presentations,e)
    if !found || shown.look==target && shown.look_point==point {return}
    shown.look,shown.look_point=target,point
    presentation_write(w.presentations,e,shown)
}

// The agent asks for an animation by the game's id: the players see it
// start, again each time it is asked. Without its Mind_Presentation, nothing.
present_animation :: proc(a:^ai.Act($A),animation:u16) {
    w,e:=world_of(a),agent(a)
    shown,found:=presentation_read(w.presentations,e)
    if !found {return}
    shown.animation=animation
    shown.animations+=1
    presentation_write(w.presentations,e,shown)
}

// The Nav_Path of the agent of an action or a think procedure: on, or off
// while it is far.
agent_path :: proc(a:^$T) -> (p:nav.Nav_Path,ok:bool) {
    w,e:=world_of(a),agent(a)
    if p,ok=core.get(w.paths,e);ok || w.paths==nil {return}
    found:=cast(^nav.Nav_Path)core.raw_find(core.raw(w.paths),type_info_of(nav.Nav_Path),e)
    if found==nil {return}
    return found^,true
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
    case .Failed,.Idle: return .Failure
    }
    return .Running
}

// A name for a mind: false when it is empty or longer than a Mind_Name holds.
name_make :: proc "contextless" (text:string) -> (name:Mind_Name,ok:bool) {
    if len(text)==0 || len(text)>=MIND_NAME {return}
    base.text_set(name[:],text)
    return name,true
}
