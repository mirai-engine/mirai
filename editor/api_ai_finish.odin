package editor

import "core:strings"
import "core:unicode/utf8"
import "mirai:editor/api"
import "mirai:std/base"

AI_FINISH_RESPONSE_BYTES :: 8*1024

Api_Ai_Finish_Params :: struct {
    response:[AI_FINISH_RESPONSE_BYTES+1]u8 `mirai:"optional,text,label=Final English answer for a question or explanation; omit for a visible editor result. Write an entity of the scene as [Name](entity:ID), and a scene the user can try in Play as [What to try](play:path of the scene under the assets folder), which the chat draws as a button"`,
    question:Api_Ai_Finish_Question `mirai:"optional,label=Ask the user instead of closing the subject; with the question in response. single or multi when the answer is one or some of a few things you can name (such as entities of the scene): the user picks from options with a click. text for an open answer; confirm for yes or no. Omit it to close the subject"`,
    options:[AI_QUESTION_OPTIONS][AI_QUESTION_OPTION_BYTES]u8 `mirai:"optional,text,trim,label=The choices of single or multi; the user may always answer with their own text instead"`,
}

// What finish asks, as agents name it.
Api_Ai_Finish_Question :: enum u8 {none,text,single,multi,confirm}

AI_QUESTION_OPTION_BYTES :: 96
Api_Ai_Finish_Result :: struct {accepted:bool}

@(private)
api_ai_finish_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="finish",flags={.Core,.Turn},summary="Call exactly once when the current task is complete: it is the only tool that writes the answer of the agent to the chat. The editor knows the turn by the MCP server of the agent. The task stays running until its ACP turn ends.",params=Api_Ai_Finish_Params,result=Api_Ai_Finish_Result,run=api_ai_finish})
}

@(private)
api_ai_finish :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Ai_Finish_Params)
    m:=s.ai
    task:=ai_task_named(m,call.client_tag)
    if task==nil || ai_task_worker(m,task.id)==nil {
        api.call_fail(call,api.INVALID_PARAMS,"finish ends the turn of an agent of the editor, which its MCP server names; an agent outside the editor ends its turn with ai.turn_end")
        return
    }
    if task.state!=.Running || task.stop || !ai_task_current(s,task) {
        api.call_fail(call,api.SERVER_ERROR,"The task is not running")
        return
    }
    if task.finish_called {api.call_fail(call,api.SERVER_ERROR,"finish has already been called for this turn");return}
    response:=base.text_get(p.response[:])
    if len(response)>AI_FINISH_RESPONSE_BYTES || !utf8.valid_string(response) {
        api.call_fail(call,api.INVALID_PARAMS,"The final response must be valid UTF-8 and at most 8192 bytes")
        return
    }
    kinds:=[Api_Ai_Finish_Question]Ai_Question{.none=.None,.text=.Text,.single=.Single,.multi=.Multi,.confirm=.Confirm}
    kind:=kinds[p.question]
    // The choices as the task keeps them: one per line.
    joined:[AI_QUESTION_BYTES]u8
    length:=0
    for &option in p.options {
        text:=strings.trim_space(base.text_get(option[:]))
        if text=="" {continue}
        if strings.contains_any(text,"\r\n") {api.call_fail(call,api.INVALID_PARAMS,"An option is one line");return}
        if length+len(text)+1>len(joined) {api.call_failf(call,api.INVALID_PARAMS,"The options take at most %d bytes together",len(joined)-AI_QUESTION_OPTIONS)
            return}
        if length>0 {joined[length]='\n';length+=1}
        length+=copy(joined[length:],text)
    }
    options:=string(joined[:length])
    switch {
    case kind!=.None && response=="":
        api.call_fail(call,api.INVALID_PARAMS,"A question needs its text in response")
        return
    case (kind==.Single || kind==.Multi) && options=="":
        api.call_fail(call,api.INVALID_PARAMS,"single and multi need their choices in options, such as [\"Stone block\", \"Wood box\"]; use text for an open answer")
        return
    case kind==.Confirm && options!="":
        api.call_fail(call,api.INVALID_PARAMS,"confirm answers yes or no and takes no options")
        return
    case kind==.Text && options!="":
        api.call_fail(call,api.INVALID_PARAMS,"text takes no options")
        return
    }
    task.question=kind
    task.options_length=copy(task.options[:],options)
    task.finish_called=true
    task.stream_open=false
    ai_stream_add(s,task,response)
    ai_task_dirty(task)
    ai_task_persist(s,task)
    api.call_result(call,Api_Ai_Finish_Result).accepted=true
}

