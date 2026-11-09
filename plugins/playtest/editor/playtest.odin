package playtest_editor

import "mirai:core"
import "mirai:editor"

// What an agent or a bot plays a game with: the small answer of play.observe,
// the monitors of play.qa.* with their repros, and the bot of play.explore.
// It only listens to the ticks the API runs (editor.Run_Provider).

@(storage,free="playtest_free")
Playtest :: struct {
    runs:[editor.EDITOR_RUNS]Playtest_Run,
}

Playtest_Run :: struct {
    id:u64, // Run.id; 0: the place is free
    qa:^Run_Qa,
    observed:Run_Observed,
}

@(storage)
Playtest_Api :: struct {provider:editor.Api_Provider}
playtest_api_default :: proc() -> Playtest_Api {return {provider={register=playtest_register}}}

@(storage)
Playtest_Listener :: struct {provider:editor.Run_Provider}
playtest_listener_default :: proc() -> Playtest_Listener {
    return {provider={input=qa_log_tick,ticked=qa_tick,call=qa_log_call,focus=qa_log_focus,ended=playtest_run_ended}}
}

@(private)
playtest_register :: proc(s:^editor.Session) {
    observe_api_register(s)
    qa_api_register(s)
    explore_api_register(s)
}

playtest_free :: proc(p:^Playtest) {
    for &slot in p.runs {qa_free(slot.qa)}
    p^={}
}

@(private)
playtest_of :: proc(s:^editor.Session) -> ^Playtest {
    if s.editor_world==nil || s.info==nil {return nil}
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Playtest)
}

// What it keeps of a run, made the first time; nil when there is no room.
@(private)
playtest_run :: proc(s:^editor.Session,r:^editor.Run) -> ^Playtest_Run {
    p:=playtest_of(s)
    if p==nil {return nil}
    free_place:^Playtest_Run
    for &slot in p.runs {
        if slot.id==r.id {return &slot}
        if slot.id==0 && free_place==nil {free_place=&slot}
    }
    if free_place!=nil {free_place^={id=r.id}}
    return free_place
}

// The monitors and the log of a run; nil before the API drove it.
@(private)
qa_of :: proc(s:^editor.Session,r:^editor.Run) -> ^Run_Qa {
    p:=playtest_of(s)
    if p==nil {return nil}
    for &slot in p.runs {
        if slot.id==r.id {return slot.qa}
    }
    return nil
}

@(private)
playtest_run_ended :: proc(s:^editor.Session,r:^editor.Run) {
    p:=playtest_of(s)
    if p==nil {return}
    for &slot in p.runs {
        if slot.id!=r.id {continue}
        qa_free(slot.qa)
        slot={}
    }
}
