package editor

import "mirai:editor/api"
import "mirai:std/base"

// The method of watching another run.

Api_Watch_Params :: struct {
    task:int `mirai:"optional,min=0,label=The AI task whose run is shown; without one the viewport stops watching"`,
}

Api_Watch_Result :: struct {
    watching:bool,
    task:int,
    name:[96]u8 `mirai:"text,label=The title of the task"`,
}

@(private)
watch_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="editor.watch",summary="Shows in the viewport the run of an agent, without stopping or editing it. Outside a turn only.",params=type_info_of(Api_Watch_Params),result=type_info_of(Api_Watch_Result),run=api_editor_watch})
}

@(private)
api_watch_result :: proc(s:^Session,call:^api.Call) {
    r:=api.call_result(call,Api_Watch_Result)
    if s.mode!=.Watch {return}
    r.watching,r.task=true,s.watch.task
    base.text_set(r.name[:],watch_name(s))
}

@(private)
api_editor_watch :: proc(s:^Session,call:^api.Call) {
    if ai_task_of_call(s,call)!=0 {
        api.call_fail(call,api.SERVER_ERROR,"A turn does not choose what the editor shows")
        return
    }
    params:=api.call_params(call,Api_Watch_Params)
    switch {
    case params.task==0: watch_stop(s)
    case !watch_start(s,params.task):
        api.call_fail(call,api.SERVER_ERROR,"That task has no run: it plays with play.start inside its turn")
        return
    }
    api_watch_result(s,call)
}
