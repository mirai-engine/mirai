package animation_editor

import "core:fmt"
import "core:strings"
import aa "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import anim "plugins:animation/runtime"

// What a rig did at the ticks a run played, read by playing them again as play.history does: the
// matching as animation.inspect part Match reads it, and the pose part Pose places, at each row.
History_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The rig by its name, a path Parent/Child, its id or its handle; found again at each tick"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
    from:[api.DURATION_TEXT]u8 `mirai:"optional,text,label=The first row: a number is a tick and a text ending in s is a game time as 240 or 3.2s; the oldest kept when omitted"`,
    to:[api.DURATION_TEXT]u8 `mirai:"optional,text,label=The last row in the form of from; the newest kept when omitted or past it"`,
    every:int `mirai:"optional,min=1,label=Ticks from one row to the next"`,
    candidates:int `mirai:"optional,min=0,max=16,clamp,label=At a row where it searched, that many of the first candidates of its last search"`,
    names:[POSE_NAMES][aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=The bones and sockets each row places, as animation.inspect part Pose takes them"`,
    stage:anim.Tick_Pose `mirai:"optional,label=With names: the pose each row reads, as animation.inspect part Pose takes it"`,
}

History_Result :: struct {
    next:u64 `mirai:"label=The from that goes on when the rows filled before to; 0 when they reached it"`,
    rows:[]History_Row,
}

// A row: what the rig was doing after a tick; one it lacks at that tick holds tick, code and reason.
History_Row :: struct {
    tick:u64,
    using missing:Instance_Missing `mirai:"inline"`,
    using match:Preview_Match_Result `mirai:"inline"`,
    searched:bool `mirai:"optional,label=It searched since the row before; in the first row, in its tick when the history keeps the tick before"`,
    jumped:bool `mirai:"optional,label=It jumped to another row of the database since the row before, read as searched"`,
    candidates:[]Instance_Match_Candidate `mirai:"optional,label=Where it searched: those of its last search, least cost first; the first is the row the search gave"`,
    pose:Instance_Pose `mirai:"optional,label=With names: where they are at stage"`,
}

@(private)
history_register :: proc(s:^editor.Session) {
    defaults:=History_Params{every=1}
    editor.api_method_register(s,{params=type_info_of(History_Params),result=type_info_of(History_Result),name="animation.history",summary="What a rig did at the ticks the game of the caller, or the last Play of the user, keeps: the clip its matching played, whether it searched or jumped, the candidates of each search with their costs and the pose of its bones, read by playing those ticks again; the game stays as it is.",defaults=&defaults,flags={.Read_Only},run=history})
}

// What a look at the past keeps from one row to the next.
@(private="file")
History_Look :: struct {
    s:^editor.Session,
    call:^api.Call,
    p:^History_Params,
    rows:[dynamic]History_Row,
    query:Pose_Query,
    queried:bool,  // names were found on the skeleton of the rig
    posed:bool,    // the call asks for a pose
    looked:bool,   // a tick was looked at before this one
    found:bool,    // some tick has the rig
    searches,jumps:u32, // of the rig at the tick looked at before; 0 without it there
    failure:api.Error,  // what failed the call inside a look
}

@(private)
history :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,History_Params)
    look:=History_Look{s=s,call=call,p=p,rows=make([dynamic]History_Row,call.allocator)}
    for &name in p.names {if base.text_get(name[:])!="" {look.posed=true;break}}
    next,ok:=editor.history_look(s,call,p.player,p.from[:],p.to[:],p.every,editor.API_TRACE_ROWS,history_look,&look)
    if !ok {
        if look.failure.code!=0 {call.error=look.failure}
        return
    }
    if !look.found {
        authoring_failure(call,"entity","Missing_Entity","a rig of the game at one of those ticks",base.text_get(p.entity[:]),"The entity names no rig at the ticks asked",fix="scene.inspect with world Game lists the entities of the game; play.history gives the ticks it keeps")
        return
    }
    r:=api.call_result(call,History_Result)
    r.next,r.rows=next,look.rows[:]
}

@(private="file")
history_look :: proc(s:^editor.Session,w:core.World_Ref,row:bool,data:rawptr) -> string {
    l:=(^History_Look)(data)
    call,p:=l.call,l.p
    looked:=l.looked
    l.looked=true
    searches,jumps:=l.searches,l.jumps
    l.searches,l.jumps=0,0
    e,problem:=editor.api_entity_select(w,base.text_get(p.entity[:]),"entity",true,call.allocator)
    alive:=problem==""
    if alive {l.found=true}
    m:Match_Open
    matching:=false
    if alive {m,matching=match_open(s,call,w,e)}
    failed:=Instance_Missing{}
    if alive && !matching {failed=history_missing(call)}
    if matching {l.searches,l.jumps=m.result.searches,m.result.jumps}
    if !row {return ""}
    out:History_Row
    if t:=core.world_storage_of(w,core.Time);t!=nil {out.tick=t.tick}
    defer append(&l.rows,out)
    if !alive {
        base.text_set(out.code[:],"Missing_Entity")
        base.text_set(out.reason[:],strings.trim_space(problem))
        return ""
    }
    if !matching {out.missing=failed}
    if matching {
        out.match=m.result
        // A rig made again since the tick before counts its searches from 0.
        if m.result.searches<searches {searches,jumps=0,0}
        out.searched=looked && m.result.searches>searches
        out.jumped=looked && m.result.jumps>jumps
        if out.searched && p.candidates>0 && m.state!=nil && m.state.program.match.searched.search==m.result.searches {
            out.candidates=match_candidates(call,&m,p.candidates)
        }
    }
    if !l.posed {return ""}
    if !l.queried {
        l.query=pose_query(s,call,w,e,&p.names)
        if call.failed {
            l.failure=call.error
            return fmt.tprintf("%s",call.error.message)
        }
        l.queried=l.query.rows!=nil
    }
    out.pose=instance_pose(call,w,e,&l.query,p.stage)
    if call.failed {out.pose={missing=history_missing(call)}}
    return ""
}

// The code and reason a part fails the call with, as a part a rig lacks: the call goes on.
@(private)
history_missing :: proc(call:^api.Call) -> (m:Instance_Missing) {
    base.text_set(m.code[:],strings.trim(api.json_member(call.error.data,"code"),`"`))
    base.text_set(m.reason[:],call.error.message)
    call.failed,call.error=false,{}
    return
}
