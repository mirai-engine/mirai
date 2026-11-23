package behavior_editor

import "core:strings"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import behavior "plugins:behavior/runtime"

// What the mind of an agent did at the ticks a run played, read by playing them again as
// play.history does: at each row the action and the step it ran, the best proposals of its last
// decision and the exits since the row before. What it perceived is for behavior.perception.

History_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The Mind_Agent by its name, a path Parent/Child, its id or its handle; found again at each tick"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
    from:[api.DURATION_TEXT]u8 `mirai:"optional,text,label=The first row: a number is a tick and a text ending in s is a game time as 240 or 3.2s; the oldest kept when omitted"`,
    to:[api.DURATION_TEXT]u8 `mirai:"optional,text,label=The last row in the form of from; the newest kept when omitted or past it"`,
    every:int `mirai:"optional,min=1,label=Ticks from one row to the next"`,
}

History_Result :: struct {
    next:u64 `mirai:"label=The from that goes on when the rows filled before to; 0 when they reached it"`,
    rows:[]History_Row,
}

// A row: what the mind did after a tick; one without the agent at that tick holds tick and missing.
History_Row :: struct {
    tick:u64,
    missing:string `mirai:"optional,label=Why the row tells nothing: the agent is not there, or its mind is not registered"`,
    mind:string `mirai:"optional"`,
    running:Frame_Result `mirai:"optional,label=The action it runs; left out with none"`,
    step:Frame_Result `mirai:"optional,label=The step of the action it runs; left out with none"`,
    score,commit:f32 `mirai:"optional"`,
    proposals:[]Proposal_Result `mirai:"optional,label=The best of its last decision"`,
    exits:[]Exit_Result `mirai:"optional,label=Its exits since the row before, the most recent first"`,
}

// What a look at the past keeps from one row to the next.
@(private="file")
History_Look :: struct {
    s:^editor.Session,
    call:^api.Call,
    entity:string,
    rows:[dynamic]History_Row,
    seen:u64,  // the tick of the frame looked at before; 0 before the first
    found:bool, // some tick has the agent
}

@(private)
history_register :: proc(s:^editor.Session) {
    defaults:=History_Params{every=1}
    editor.api_method_register(s,{name="behavior.history",summary="What the mind of a Mind_Agent did at the ticks the game of the caller, or the last Play of the user, keeps: at each row the action and the step it ran, the best proposals of its last decision with their scores and its exits since the row before with their cause and what interrupted them, read by playing those ticks again; the game stays as it is.",params=type_info_of(History_Params),result=type_info_of(History_Result),defaults=&defaults,flags={.Read_Only},run=history})
}

@(private)
history :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,History_Params)
    look:=History_Look{s=s,call=call,entity=base.text_get(p.entity[:]),rows=make([dynamic]History_Row,call.allocator)}
    next,ok:=editor.history_look(s,call,p.player,p.from[:],p.to[:],p.every,editor.API_TRACE_ROWS,history_look,&look)
    if !ok {return}
    if !look.found {
        api.call_failf(call,api.INVALID_PARAMS,"entity %q names no Mind_Agent of the game at those ticks; scene.inspect with world Game lists the entities of the game and play.history the ticks it keeps",look.entity)
        return
    }
    r:=api.call_result(call,History_Result)
    r.next,r.rows=next,look.rows[:]
}

@(private="file")
history_look :: proc(s:^editor.Session,w:core.World_Ref,row:bool,data:rawptr) -> string {
    l:=(^History_Look)(data)
    now:core.Time
    if t:=core.world_storage_of(w,core.Time);t!=nil {now=t^}
    // The time of a frame is past the ticks it ran: those since the time of the frame looked at
    // before, or for the first the tick before its time.
    since:=l.seen if l.seen>0 else max(now.tick,1)-1
    defer l.seen=now.tick
    if !row {return ""}
    out:=History_Row{tick=now.tick}
    defer append(&l.rows,out)
    e,problem:=editor.api_entity_select(w,l.entity,"entity",true,l.call.allocator)
    agents:=core.world_table_of(w,behavior.Mind_Agent)
    if problem=="" && (agents==nil || !core.has(agents,e)) {problem="it has no Mind_Agent at this tick"}
    if problem!="" {
        out.missing=strings.trim_space(problem)
        return ""
    }
    l.found=true
    agent:=&agents.values[core.row_of(agents,e)]
    none:behavior.Mind_Name
    entry:=behavior.mind_of(minds_of(s),agent.owner if agent.owner!=none else agent.mind)
    out.mind=name_text(agent.mind)
    if entry==nil {
        out.missing="no mind is registered by this name"
        return ""
    }
    m:=&agent.state
    out.running,out.step=mind_frames(w,entry,m,now)
    out.score,out.commit=m.score,m.commit
    out.proposals=mind_proposals(entry,m,l.call.allocator)
    out.exits=mind_exits(entry,m,now,since,l.call.allocator)
    return ""
}
