package editor

import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:std/base"

Ai_Agent_Spawn_Params :: struct {
    prompt:[AI_MESSAGE_BYTES]u8 `mirai:"text,label=What the subagent has to do; it knows nothing of this chat but what this says"`,
    title:[96]u8 `mirai:"optional,text,label=Its name among the agents; empty: the start of the prompt"`,
    agent:[32]u8 `mirai:"optional,text,label=Id of a connection of ai.connections; empty: the default of the project for subagents"`,
    model:[128]u8 `mirai:"optional,text"`,
    effort:[32]u8 `mirai:"optional,text"`,
}
Ai_Agent_Message_Params :: struct {
    id:int `mirai:"min=1,label=The id of a subagent of agent.list"`,
    text:[AI_MESSAGE_BYTES]u8 `mirai:"text"`,
}
Ai_Chat_Note_Params :: struct {
    text:[AI_MESSAGE_BYTES]u8 `mirai:"text,label=The whole notes: they replace the ones before; empty clears them"`,
}
Ai_Chat_Note_Result :: struct {saved:bool}

Ai_Agent_Result :: struct {
    id:int `mirai:"label=What agent.message and agent.stop take"`,
    title:string,
    state:string `mirai:"label=queued; running; done; failed; cancelled or interrupted"`,
    connection:string `mirai:"label=Id of the connection that runs it"`,
    model,effort:string,
    document:string `mirai:"label=The document it works on"`,
    changes:int `mirai:"label=Its changes that wait for the review of the user"`,
    answer:string `mirai:"label=What it answered once it finished; empty while it works"`,
}
Ai_Agent_List_Result :: struct {
    agents:[]Ai_Agent_Result `mirai:"label=The subagents of the main chat; the latest first"`,
}

@(private)
ai_subagents_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="agent.spawn",flags={.Core,.Turn},summary="Starts a subagent from a turn of the main chat, to work in parallel with its own review, and returns at once; when its turn ends its report reaches the main chat.",params=type_info_of(Ai_Agent_Spawn_Params),result=type_info_of(Ai_Agent_Result),run=ai_method_agent_spawn})
    api_register(s,st,{name="agent.list",summary="The subagents of the main chat with their state, connection, changes to review and, once finished, their answer.",result=type_info_of(Ai_Agent_List_Result),flags={.Read_Only},run=ai_method_agent_list})
    api_register(s,st,{name="agent.message",summary="Sends a message to a subagent: it joins the turn in progress at its next safe point, or starts its next turn when it is idle.",params=type_info_of(Ai_Agent_Message_Params),result=type_info_of(Ai_Agent_Result),run=ai_method_agent_message})
    api_register(s,st,{name="agent.stop",summary="Stops a subagent, or takes it out of the queue; what it changed stays for review.",params=type_info_of(Ai_Id_Params),result=type_info_of(Ai_Agent_Result),flags={.Idempotent},run=ai_method_agent_stop})
    api_register(s,st,{name="chat.note",flags={.Core},summary="Replaces the working notes of the main chat, which outlive its context.",params=type_info_of(Ai_Chat_Note_Params),result=type_info_of(Ai_Chat_Note_Result),run=ai_method_chat_note})
}

@(private)
ai_agent_of :: proc(task:^Ai_Task) -> Ai_Agent_Result {
    names:=AI_STATE_NAMES
    c:=&task.conversation
    changes:=ai_task_reviewable(task)?ai_review_count(task):0
    return {task.id,string(c.title[:c.title_len]),names[task.state],string(c.provider[:c.provider_len]),string(c.model[:c.model_len]),string(c.effort[:c.effort_len]),string(c.document[:c.document_len]),changes,ai_task_answer(task)}
}

// The subagent an id names, brought back from the history if it left memory.
@(private)
ai_subagent_of :: proc(s:^Session,call:^api.Call,id:int) -> ^Ai_Task {
    m:=s.ai
    ai_initialize(s)
    task:=ai_task_find(m,id)
    if task==nil {
        if saved:=ai_store.find(&m.store,u64(id));saved!=nil && saved.kind==.Agent {
            conversation:=saved^
            task=ai_conversation_restore(s,&conversation)
        }
    }
    if task==nil || task.conversation.kind!=.Agent {
        api.call_failf(call,api.INVALID_PARAMS,"there is no subagent %d: agent.list names them",id)
        return nil
    }
    return task
}

@(private)
ai_method_agent_spawn :: proc(s:^Session,call:^api.Call) {
    m:=s.ai
    p:=api.call_params(call,Ai_Agent_Spawn_Params)
    caller:=ai_task_named(m,call.client_tag)
    if caller!=nil && caller.conversation.kind==.Agent {
        api.call_fail(call,api.INVALID_PARAMS,"A subagent cannot start subagents: the depth is 1. Do this work yourself, or end your turn with finish and say what is left for the main chat")
        return
    }
    if caller==nil || caller.id!=m.main || caller.state!=.Running || caller.stop {
        api.call_fail(call,api.INVALID_PARAMS,"agent.spawn works only from a running turn of the main chat, which its MCP server names")
        return
    }
    task,message:=ai_agent_spawn(s,m,base.text_get(p.prompt[:]),base.text_get(p.title[:]),base.text_get(p.agent[:]),base.text_get(p.model[:]),base.text_get(p.effort[:]))
    if task==nil {api.call_fail(call,api.INVALID_PARAMS,message);return}
    api.call_result(call,Ai_Agent_Result)^=ai_agent_of(task)
}

@(private)
ai_method_agent_list :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    m:=s.ai
    names:=AI_STATE_NAMES
    conversations:=make([]ai_store.Conversation,64,context.temp_allocator)
    agents:=make([dynamic]Ai_Agent_Result,call.allocator)
    if m.main!=0 {
        count,message:=ai_store.list(&m.store,conversations,kinds={.Agent},parent=u64(m.main))
        if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
        for &c in conversations[:count] {
            if task:=ai_task_find(m,int(c.id));task!=nil {append(&agents,ai_agent_of(task));continue}
            // Out of memory: it ended long ago, and its review is on the disk.
            append(&agents,Ai_Agent_Result{int(c.id),string(c.title[:c.title_len]),names[.Done],string(c.provider[:c.provider_len]),string(c.model[:c.model_len]),string(c.effort[:c.effort_len]),string(c.document[:c.document_len]),0,string(c.last[:c.last_len])})
        }
    }
    api.call_result(call,Ai_Agent_List_Result).agents=agents[:]
}

@(private)
ai_method_agent_message :: proc(s:^Session,call:^api.Call) {
    m:=s.ai
    p:=api.call_params(call,Ai_Agent_Message_Params)
    task:=ai_subagent_of(s,call,p.id)
    if task==nil {return}
    text:=base.text_get(p.text[:])
    if !ai_task_finished(task) {
        if message:=ai_task_steer(s,m,task,text);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    } else if created,message:=ai_task_create(s,m,ai_turn_region(s,task),text,"",task.id,turn={detached=true});created==nil {
        api.call_fail(call,api.SERVER_ERROR,message)
        return
    }
    api.call_result(call,Ai_Agent_Result)^=ai_agent_of(task)
}

@(private)
ai_method_agent_stop :: proc(s:^Session,call:^api.Call) {
    task:=ai_subagent_of(s,call,api.call_params(call,Ai_Id_Params).id)
    if task==nil {return}
    ai_task_cancel(s,s.ai,task)
    api.call_result(call,Ai_Agent_Result)^=ai_agent_of(task)
}

@(private)
ai_method_chat_note :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    m:=s.ai
    main:=ai_task_find(m,m.main)
    if main==nil {api.call_fail(call,api.SERVER_ERROR,"There is no main chat yet: it starts with the first message");return}
    if message:=ai_store.note_set(&m.store,main.conversation.id,base.text_get(api.call_params(call,Ai_Chat_Note_Params).text[:]));message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    api.call_result(call,Ai_Chat_Note_Result).saved=true
}
