package behavior

import "base:intrinsics"
import "base:runtime"
import "mirai:core"
import "mirai:std/ai"
import "mirai:std/base"
import nav "plugins:navigation/runtime"

// The minds of a game and the agents that run them. A mind is an enum of
// actions, a procedure for each and a think procedure that proposes them
// (ai.mind_tick); the game ticks the agents of each in a function of its own
// with minds_tick, which registers the mind by name the first time, checks
// it, and gives the actions what the function received (the agents far from
// the players included). The registry is the same for every world; the
// state of each agent is plain data in its Mind_Agent and copies with the
// world. Minds decide on the server alone: the function that ticks them is
// `server`, a tick that runs again decides nothing, and the clients see what
// each one does in its Mind_Presentation.

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

Mind_Problem :: enum u8 {
    None,
    Name,           // empty or longer than a Mind_Name holds
    Missing_Action, // a value of the enum without a procedure
    No_Think,
    Full,           // MINDS_CAPACITY minds are registered
}

// Registers a mind under a name, or replaces the one there (a game that
// changed its code), after checking it: every action has its procedure and
// there is a think procedure. On a problem, `action` is the value of the
// enum without a procedure; mind_problem_text says how to fix it.
mind_register :: proc(minds:^Minds,name:string,acts:^[$A]$P,think:proc(t:^ai.Think(A))) -> (problem:Mind_Problem,action:int) {
    #assert(intrinsics.type_is_enum(A) && int(min(A))>=0 && int(max(A))<ai.MIND_ACTIONS)
    #assert(P==proc(a:^ai.Act(A)) -> ai.Status)
    action=-1
    key,ok:=name_make(name)
    if !ok {return .Name,action}
    if acts==nil {return .Missing_Action,int(min(A))}
    for procedure,a in acts {
        if procedure==nil {return .Missing_Action,int(a)}
    }
    if think==nil {return .No_Think,action}
    if minds==nil {return .Full,action}
    for &entry in minds.entries[:clamp(minds.count,0,MINDS_CAPACITY)] {
        if entry.name!=key {continue}
        if entry.actions!=A {entry_set(&entry,key,A,type_info_of(A))}
        return
    }
    if minds.count>=MINDS_CAPACITY {return .Full,action}
    entry_set(&minds.entries[minds.count],key,A,type_info_of(A))
    minds.count+=1
    return
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

// What to do about a problem of mind_register.
mind_problem_text :: proc "contextless" (problem:Mind_Problem) -> string {
    switch problem {
    case .None: return ""
    case .Name: return "the name of a mind is 1 to 15 bytes"
    case .Missing_Action: return "an action of the enum has no procedure: set it in the array of actions, or take the value out of the enum"
    case .No_Think: return "it has no think procedure: pass the procedure that proposes its actions"
    case .Full: return "no room is left: a game registers at most MINDS_CAPACITY minds, so join those that share their actions"
    }
    return ""
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

// Ticks every agent of a mind, after registering it: before each tick,
// w.entity is that agent, so the actions know whom they move, and ctx.holder
// is the agent, as the holder of what it claims; after it, its
// Mind_Presentation (when w.presentations has the table, and an agent without
// one gets it before) shows the action and the step it runs. An agent far
// from the players (nav.Nav_Far) is off and decides on: its mind ticks once
// every step of what is far (nav.nav_far_decide), with w.far, and what it
// claims lasts until its next tick. A tick that runs again (time.resimulating)
// decides nothing: its actions would repeat what they did. A mind that does
// not register, and agents of a name never registered, are the problem
// behavior.mind.
minds_tick :: proc(minds:^Minds,agents:^core.Table(Mind_Agent),name:string,acts:^[$A]$P,think:proc(t:^ai.Think(A)),ctx:^ai.Mind_Context,w:^Act_World,time:core.Time,problems:^core.Problems) {
    if time.resimulating || ctx==nil || w==nil {return}
    problem,action:=mind_register(minds,name,acts,think)
    if problem!=.None {
        if action>=0 {
            core.report(problems,core.NONE,"behavior.mind","The mind %q does not run: %s (%v)",name,mind_problem_text(problem),A(action))
        } else {
            core.report(problems,core.NONE,"behavior.mind","The mind %q does not run: %s",name,mind_problem_text(problem))
        }
        return
    }
    key:=mind_name(name)
    ctx.time,ctx.tick,ctx.lease=time.seconds,time.tick,1
    w.far=false
    for row in 0..<core.count(agents) {
        if agents.values[row].mind!=key {continue}
        w.entity=core.entity_at(agents,row)
        mind_run(&core.edit_at(agents,row).state,acts,think,ctx,w)
    }
    if w.fars.table==nil || !nav.nav_far_decide(time) {return}
    // Until its next tick, once every step of what is far.
    ctx.lease=u32(nav.NAV_FAR_PERIOD/max(time.dt,1e-6)+0.5)+1
    // The rows after those on are off: of them, the agents far.
    for row in core.count(agents)..<len(agents.entities) {
        if agents.values[row].mind!=key {continue}
        e:=agents.entities[row]
        if core.raw_find(core.raw(w.fars.table),type_info_of(nav.Nav_Far),e)==nil {continue}
        w.entity,w.far=e,true
        mind_run(&core.edit_at(agents,row).state,acts,think,ctx,w)
    }
    w.far=false
    ctx.lease=1
}

// Reports the agents whose mind nobody ticks with minds_tick: call it once
// after the minds of a tick, with the names they ran.
minds_unknown :: proc(minds:^Minds,agents:^core.Table(Mind_Agent),problems:^core.Problems) {
    for row in 0..<core.count(agents) {
        name:=agents.values[row].mind
        if mind_of(minds,name)!=nil {continue}
        name_text:=name
        core.report(problems,core.entity_at(agents,row),"behavior.mind","No mind is registered as %q: tick it with behavior.minds_tick, or fix the name of its Mind_Agent",base.text_get(name_text[:]))
    }
}

@(private)
mind_run :: proc(m:^ai.Mind,acts:^[$A]$P,think:proc(t:^ai.Think(A)),ctx:^ai.Mind_Context,w:^Act_World) {
    ctx.holder=u64(w.entity)
    present_ensure(w)
    ai.mind_tick(m,acts,think,ctx)
    shown,found:=presentation_read(w)
    if !found {return}
    next:=shown
    next.action,next.step=ai.mind_running(m)
    if next!=shown {presentation_write(w,next)}
}

// Gives the agent of w its Mind_Presentation before its first tick, so its actions can write it.
@(private)
present_ensure :: proc(w:^Act_World) {
    if w.presentations==nil {return}
    if _,found:=presentation_read(w);!found {core.add(w.presentations,w.entity,MIND_PRESENTATION_DEFAULT)}
}

// The Mind_Presentation of the agent of w: the one it is given in this
// function, or its row, on or off while it is far.
@(private)
presentation_read :: proc(w:^Act_World) -> (shown:Mind_Presentation,ok:bool) {
    if w.presentations==nil {return}
    t:=core.raw(w.presentations)
    found:=core.raw_added(t,type_info_of(Mind_Presentation),w.entity)
    if found==nil {found=core.raw_find(t,type_info_of(Mind_Presentation),w.entity)}
    if found==nil {return}
    return (cast(^Mind_Presentation)found)^,true
}

@(private)
presentation_write :: proc(w:^Act_World,shown:Mind_Presentation) {
    if row:=cast(^Mind_Presentation)core.raw_staged(core.raw(w.presentations),type_info_of(Mind_Presentation),w.entity);row!=nil {row^=shown}
}

// The agent of w looks at an entity, or at a point without one, as the
// players see it. Without its Mind_Presentation, nothing.
present_look :: proc(w:^Act_World,target:core.Entity,point:[3]f32={}) {
    shown,found:=presentation_read(w)
    if !found || shown.look==target && shown.look_point==point {return}
    shown.look,shown.look_point=target,point
    presentation_write(w,shown)
}

// The agent of w asks for an animation by the game's id: the players see it
// start, again each time it is asked. Without its Mind_Presentation, nothing.
present_animation :: proc(w:^Act_World,animation:u16) {
    shown,found:=presentation_read(w)
    if !found {return}
    shown.animation=animation
    shown.animations+=1
    presentation_write(w,shown)
}

// What every mind of a game reads and asks for: a loop function receives it
// and adds only the tables of the game (mind_tick).
@(params)
Mind_World :: struct {
    minds:^Minds,
    agents:^core.Table(Mind_Agent),
    presentations:^core.Table(Mind_Presentation),
    requests:^nav.Nav_Requests,
    paths:core.Read(nav.Nav_Path),
    fars:core.Read(nav.Nav_Far),
    nav_agents:core.Read(nav.Nav_Agent),
    links:core.Read(nav.Nav_Link),
    perceptions:core.Read(Perception),
    perceivables:core.Read(Perceivable),
    worlds:core.Read(core.World_Transform),
    places:^Place_Requests,
    results:core.Read(Place_Result),
    objects:core.Read(Smart_Object),
    states:core.Read(Smart_State),
    claims:^Claims,
    uses:^Smart_Uses,
    noises:^Noises,
    influence:core.Ref(Influence),
    time:core.Time,
    problems:^core.Problems,
}

// What the actions of a tick read, from a Mind_World. A game makes its context begin with it
// (using) and adds its own tables.
Mind_Tick :: struct {
    using act:Act_World,
    smart:Smart_View,
    world:Mind_World,
    worlds:core.Read(core.World_Transform),
    perceptions:core.Read(Perception),
    perceivables:core.Read(Perceivable),
    agents:core.Read(nav.Nav_Agent),
    links:core.Read(nav.Nav_Link),
    places:^Place_Requests,
    results:core.Read(Place_Result),
    uses:^Smart_Uses,
    noises:^Noises,
    influence:^Influence,
}

mind_tick :: proc(world:Mind_World) -> Mind_Tick {
    return {
        act={requests=world.requests,paths=world.paths,fars=world.fars,presentations=world.presentations},
        smart={objects=world.objects,states=world.states,worlds=world.worlds,claims=world.claims,time=world.time.seconds,tick=world.time.tick},
        world=world,worlds=world.worlds,perceptions=world.perceptions,perceivables=world.perceivables,agents=world.nav_agents,links=world.links,
        places=world.places,results=world.results,uses=world.uses,noises=world.noises,influence=world.influence.ptr,
    }
}

// What the actions of a game usually need of the world, which its context
// can begin with (using) so the actions below work on it.
Act_World :: struct {
    entity:core.Entity,
    requests:^nav.Nav_Requests,
    paths:core.Read(nav.Nav_Path),
    fars:core.Read(nav.Nav_Far),
    presentations:^core.Table(Mind_Presentation), // none: the agents present nothing
    far:bool, // the agent is far from the players: its components are off
}

// The Nav_Path of the agent: on, or off while it is far.
agent_path :: proc(w:^Act_World) -> (p:nav.Nav_Path,ok:bool) {
    if p,ok=core.get(w.paths,w.entity);ok || !w.far || w.paths.table==nil {return}
    found:=cast(^nav.Nav_Path)core.raw_find(core.raw(w.paths.table),type_info_of(nav.Nav_Path),w.entity)
    if found==nil {return}
    return found^,true
}

// Walks the agent to `goal`: Success when it arrives, Failure when
// navigation cannot take it there; it stops the agent when the action is
// interrupted.
move_act :: proc(w:^Act_World,a:^ai.Act($A),goal:[3]f32) -> ai.Status {
    switch a.phase {
    case .Enter:
        nav.nav_move_to(w.requests,w.entity,goal)
        return .Running
    case .Update:
        return path_status(w)
    case .Exit:
        if a.cause==.Aborted {nav.nav_stop(w.requests,w.entity)}
    }
    return .Success
}

// Follows `target`, keeping `distance`: Running while it follows, Failure
// when navigation cannot; it stops the agent on Exit.
follow_act :: proc(w:^Act_World,a:^ai.Act($A),target:core.Entity,distance:f32) -> ai.Status {
    switch a.phase {
    case .Enter:
        nav.nav_follow(w.requests,w.entity,target,distance)
        return .Running
    case .Update:
        p,ok:=agent_path(w)
        if ok && p.state==.Failed {return .Failure}
        return .Running
    case .Exit:
        nav.nav_stop(w.requests,w.entity)
    }
    return .Success
}

// Running while the agent walks or waits for its path, Success once there
// (Failure when it could only get near), Failure when navigation failed.
path_status :: proc(w:^Act_World) -> ai.Status {
    p,ok:=agent_path(w)
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
