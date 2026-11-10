package editor

import "base:runtime"
import "core:strings"
import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

Ai_Task_Params :: struct {
    region:[4]f32 `mirai:"optional,label=x y width and height in window points; omitted: the whole viewport"`,
    prompt:[AI_MESSAGE_BYTES]u8 `mirai:"text"`,
    agent:[32]u8 `mirai:"optional,text,label=Id of a connection of ai.connections; empty uses the selected one"`,
    model:[128]u8 `mirai:"optional,text"`,
    effort:[32]u8 `mirai:"optional,text"`,
    conversation:int `mirai:"optional,min=0,label=The id of a subagent to send it to; zero sends it to the main chat"`,
}
Ai_Status_Params :: struct {
    id:int `mirai:"optional,min=0,label=Only this task with its transcript"`,
    from:int `mirai:"optional,min=0,label=First line of the transcript to return"`,
}
Ai_Id_Params :: struct {
    id:int `mirai:"min=1"`,
}
Ai_Compact_Params :: struct {
    id:int `mirai:"optional,min=0,label=The chat; zero compacts the main chat"`,
}
Ai_History_Params :: struct {
    id:int `mirai:"optional,min=0,label=Conversation whose messages to read (up to 128); zero lists 64 conversations of the project"`,
    offset:int `mirai:"optional,min=0,label=First conversation to list"`,
    before:int `mirai:"optional,min=0,label=Return messages before this sequence; zero returns the newest page"`,
}
Ai_History_Search_Params :: struct {
    query:[512]u8 `mirai:"text,label=Words, an entity id or an asset path; all must be in the line, OR between two takes either"`,
    limit:int `mirai:"optional,min=0,max=50,label=Hits to return; zero returns 10"`,
    conversation:int `mirai:"optional,min=0,label=Only this conversation; zero searches all of the project"`,
}
Ai_Permission_Params :: struct {
    index:int `mirai:"optional,min=0,label=The request as ai.status lists it"`,
    option:[128]u8 `mirai:"optional,text,label=The id of one of its options"`,
    cancel:bool `mirai:"optional,label=Cancel the request instead of answering it"`,
}

Ai_Task_Result :: struct {
    id:int `mirai:"label=The conversation; ai.task continues it with conversation"`,
    kind:string `mirai:"label=main; agent (a subagent of the main chat) or archived"`,
    parent:int `mirai:"label=Of a subagent: its main chat"`,
    held:int `mirai:"label=Messages written to it that have not reached its agent"`,
    state:string `mirai:"label=queued; running; done; failed; cancelled or interrupted"`,
    prompt:string `mirai:"label=The start of the message"`,
    agent:string `mirai:"label=The connection that runs it; until it starts the one asked for"`,
    model:string,
    effort:string,
    play:bool `mirai:"label=Sent during a Play: the agent gets the live player"`,
    region:[4]f32 `mirai:"label=x y width and height in window points"`,
    entities:int `mirai:"label=The entities of the region its context lists"`,
    image:bool `mirai:"label=Whether the capture of the region was written"`,
    seconds:f32 `mirai:"label=How long it ran"`,
    steps:int `mirai:"label=The changes its review recorded"`,
    revertible:bool `mirai:"label=Whether ai.revert can revert it"`,
    review_finished:bool `mirai:"label=The user confirmed its result"`,
    review_pending:bool `mirai:"label=Changes to the scene or its settings or files wait for review"`,
    files_changed:bool `mirai:"label=The agent changed files of the project its review could not keep (larger than 1 MB, or past its capacity); ai.revert refuses it"`,
    changed:[]base.Entity_Id `mirai:"label=The entities it changed"`,
    changed_files:[]string `mirai:"label=Project paths of the files it wrote through the API"`,
    skipped:int `mirai:"label=Changes that reverting it kept because others changed them later"`,
    undone:bool `mirai:"label=Its changes were reverted"`,
    declined:bool `mirai:"label=The user reverted it; ai.restore takes the changes back for review"`,
    needs_build:bool `mirai:"label=It changed the code of the project: it needs a Build"`,
    finish_called:bool `mirai:"label=The agent called finish; the task runs until its ACP turn ends"`,
    lines:int `mirai:"label=Lines of its transcript so far"`,
    first:int `mirai:"optional,label=Of a task asked by id: the line its transcript starts at"`,
    transcript:[]Ai_Task_Line `mirai:"optional,label=Of a task asked by id: its lines from first"`,
}
Ai_Task_Line :: struct {
    kind:string `mirai:"label=prompt (what it was asked); output (printed by the agent); note (said by the editor); report (a subagent with this id ended a turn) or divider (a new context of the chat began)"`,
    text:string,
}

Ai_Status_Result :: struct {
    running:[]int `mirai:"label=The tasks a worker runs"`,
    process_running:bool `mirai:"label=Whether a process of an agent is open; also between turns"`,
    capacity:int `mirai:"label=How many conversations run at once"`,
    show_agents_in_scene:bool,
    permissions:[]Ai_Status_Permission `mirai:"label=The requests of agents that wait for the user"`,
    chat:Ai_Status_Chat,
    tasks:[]Ai_Task_Result `mirai:"label=Every task; with id only that one"`,
}
Ai_Status_Permission :: struct {
    index:int `mirai:"label=What ai.permission takes as index"`,
    task:int,
    title:string,
    options:[]Ai_Status_Option,
}
Ai_Status_Option :: struct {
    id:string `mirai:"label=What ai.permission takes as option"`,
    name:string,
}
Ai_Status_Chat :: struct {
    open:bool,
    rect:[4]f32 `mirai:"label=Of the chat in window points; zero when closed"`,
    region:[4]f32 `mirai:"label=In window points; zero without one"`,
    selected:int `mirai:"label=The task the chat shows"`,
    main:int `mirai:"label=The task of the main chat; 0 until its first message"`,
}

Ai_Permission_Result :: struct {ok:bool}

AI_LINE_NAMES :: [ai_store.Line_Kind]string{.Output="output",.Prompt="prompt",.Note="note",.Report="report",.Divider="divider"}

Api_Ai_History :: struct {
    conversations:[]Api_Ai_Conversation `mirai:"optional,label=Without id: the conversations of the project, the last updated first"`,
    messages:[]Api_Ai_Message `mirai:"optional,label=With id: its messages, the oldest first"`,
}
Api_Ai_Conversation :: struct {
    id:int `mirai:"label=What id takes"`,
    title:string,
    document:string `mirai:"label=The document it worked on"`,
    provider:string `mirai:"label=The id of its connection"`,
    model,effort:string,
    updated_at:int `mirai:"label=Unix time in milliseconds"`,
}
Api_Ai_Message :: struct {
    sequence:int `mirai:"label=What before takes"`,
    kind:string `mirai:"label=prompt, output, note, report or divider"`,
    text,role,event_type,tool:string,
    context_:string `mirai:"name=context,label=JSON as text"`,
}
Api_Ai_History_Search :: struct {
    hits:[]Api_Ai_History_Search_Result `mirai:"label=The best first"`,
}

Api_Ai_History_Search_Result :: struct {
    conversation:int `mirai:"label=What ai.history takes as id"`,
    title:string,
    sequence:int `mirai:"label=ai.history with before set to sequence+1 returns the messages up to it"`,
    kind:string `mirai:"label=prompt, output, note, report or divider. A note is said by the editor, as a step of a turn: Tool: method target"`,
    snippet:string `mirai:"label=Words around the matches, which go between **"`,
    updated_at:int `mirai:"label=Of the conversation, Unix time in milliseconds"`,
}

@(private)
ai_api_register :: proc(s:^Session,st:^Api_State) {
    ai_connections_api_register(s,st)
    ai_subagents_api_register(s,st)
    ai_memory_api_register(s,st)
    ai_annotations_api_register(s,st)
    ai_provenance_api_register(s,st)
    api_viewport_register(s,st)
    api_ai_finish_register(s,st)
    api_register(s,st,{name="ai.task",summary="Sends a message to the main chat of the project, or to a subagent, over ACP with the skills of the project and Mirai MCP, starting the agent when needed; poll ai.status until it ends.",params=type_info_of(Ai_Task_Params),result=type_info_of(Ai_Task_Result),run=ai_method_task})
    api_register(s,st,{name="ai.status",summary="The tasks of the agents of this editor, with the permissions they wait for and the state of the chat.",params=type_info_of(Ai_Status_Params),result=type_info_of(Ai_Status_Result),flags={.Read_Only},run=ai_method_status})
    api_register(s,st,{name="ai.cancel",summary="Stops the agent of a task, or takes a queued one out of the queue.",params=type_info_of(Ai_Id_Params),result=type_info_of(Ai_Task_Result),flags={.Idempotent},run=ai_method_cancel})
    api_register(s,st,{name="ai.revert",summary="Reverts the scene fields and project files a task changed through the API, keeping what users or agents wrote afterwards. Files the agent wrote with its own tools stay.",params=type_info_of(Ai_Id_Params),result=type_info_of(Ai_Task_Result),flags={.Destructive},run=ai_method_revert})
    api_register(s,st,{name="ai.restore",summary="Takes back the changes of a task the user reverted (declined) to be reviewed again, keeping newer edits of users or agents.",params=type_info_of(Ai_Id_Params),result=type_info_of(Ai_Task_Result),flags={.Destructive},run=ai_method_restore})
    api_register(s,st,{name="ai.review.accept",summary="Confirms the result of a task and clears its agent icon and scene outlines without changing the scene.",params=type_info_of(Ai_Id_Params),result=type_info_of(Ai_Task_Result),run=ai_method_finish_review})
    api_register(s,st,{name="ai.retry",summary="Reverts the scene changes of a task and sends its message again in the same conversation, with the same icon and color.",params=type_info_of(Ai_Id_Params),result=type_info_of(Ai_Task_Result),run=ai_method_retry})
    api_register(s,st,{name="ai.history",summary="The saved conversations of the project, or a page of the saved messages of one.",params=type_info_of(Ai_History_Params),result=type_info_of(Api_Ai_History),flags={.Read_Only},run=ai_method_history})
    api_register(s,st,{name="ai.history.search",summary="Full-text search of the saved conversations of the project: what was asked, answered and done in earlier chats, by words, an entity id or an asset path, ranked by BM25. Each hit is short; ai.history with its conversation and before pages the messages around it.",params=type_info_of(Ai_History_Search_Params),result=type_info_of(Api_Ai_History_Search),flags={.Read_Only},run=ai_method_history_search})
    api_register(s,st,{name="ai.turn_end",summary="Ends the turn of the agent outside the editor that calls (the client of mirai mcp, or mirai rpc --client NAME): its changes wait for the review of the user, and its next call opens the turn again until they are resolved. The turns of the agents of the editor and a turn already ended stay as they are. The Stop hook of Claude Code in a project calls it.",result=type_info_of(Ai_Turn_End_Result),flags={.Idempotent},run=ai_method_turn_end})
    api_register(s,st,{name="ai.compact",summary="Summarizes the context of a chat that is not working, with the command of its agent or else with a new native session; the chat goes on.",params=type_info_of(Ai_Compact_Params),result=type_info_of(Ai_Task_Result),run=ai_method_compact})
    api_register(s,st,{name="ai.permission",summary="Answers a permission an agent waits for with one of its options, or cancels it.",params=type_info_of(Ai_Permission_Params),result=type_info_of(Ai_Permission_Result),run=ai_method_permission})
}

Ai_Turn_End_Result :: struct {
    ended:bool `mirai:"label=A turn of the caller was running and ended"`,
    id:int `mirai:"label=The chat of the turn; 0 without one"`,
}

@(private)
ai_method_turn_end :: proc(s:^Session,call:^api.Call) {
    result:=api.call_result(call,Ai_Turn_End_Result)
    if call.client_tag!="" {return}
    if call.client_name=="" {
        api.call_fail(call,api.INVALID_PARAMS,"ai.turn_end ends the turn of an agent outside the editor: call it through mirai mcp, or with mirai rpc --client NAME")
        return
    }
    if s.ai==nil {return}
    if task:=ai_external_running(s,call.client_name);task!=nil {
        result.id=task.id
        result.ended=ai_external_end(s,task)
    }
}

@(private)
ai_task_result :: proc(s:^Session,task:^Ai_Task,allocator:runtime.Allocator,transcript:bool,from:int) -> (r:Ai_Task_Result) {
    names:=AI_STATE_NAMES
    kinds:=AI_LINE_NAMES
    conversation_kinds:=[ai_store.Conversation_Kind]string{.Main="main",.Agent="agent",.Archived="archived"}
    t:=&task.transcript
    c:=&task.conversation
    r={
        id=int(task.id),kind=conversation_kinds[c.kind],parent=int(c.parent),held=int(ai_task_held(task)),state=names[task.state],
        prompt=base.text_get(task.title[:]),agent=base.text_get(task.agent[:]),model=string(c.model[:c.model_len]),effort=string(c.effort[:c.effort_len]),
        play=task.play,region={task.region.x,task.region.y,task.region.w,task.region.h},entities=int(task.entities),image=task.image,seconds=task.seconds,
        steps=len(task.review.transactions),
        revertible=ai_task_finished(task) && !task.review_finished && ai_review_revertible(s,&task.review) && !task.files_changed && ai_task_current(s,task),
        review_finished=task.review_finished,review_pending=task.review.pending,files_changed=task.files_changed,
        changed=task.review.changed_ids[:],changed_files=task.review.changed_files[:],skipped=int(task.review.skipped),
        undone=task.undone,declined=task.declined,needs_build=task.needs_build,finish_called=task.finish_called,lines=t.dropped+t.count,
    }
    if transcript {
        first:=clamp(from-t.dropped,0,t.count)
        r.first=t.dropped+first
        r.transcript=make([]Ai_Task_Line,t.count-first,allocator)
        for index in first..<t.count {
            text,kind:=ai_transcript_line(t,index)
            r.transcript[index-first]={kinds[kind],text}
        }
    }
    return
}

@(private)
ai_method_task :: proc(s:^Session,call:^api.Call) {
    m:=s.ai
    params:=api.call_params(call,Ai_Task_Params)
    region:=ui.Rect{params.region[0],params.region[1],params.region[2],params.region[3]}
    if region=={} {region={s.viewport.origin.x,s.viewport.origin.y,s.viewport.size.x,s.viewport.size.y}}
    prompt:=base.text_get(params.prompt[:])
    api_frames(s,1,HEADLESS_DT)
    ai_initialize(s)
    if params.conversation!=0 && ai_task_find(m,params.conversation)==nil {
        saved:=ai_store.find(&m.store,u64(params.conversation))
        if saved==nil {api.call_fail(call,api.INVALID_PARAMS,"The conversation does not exist");return}
        conversation:=saved^
        if ai_conversation_restore(s,&conversation)==nil {api.call_fail(call,api.SERVER_ERROR,"Too many conversations are awaiting review");return}
    }
    task,message:=ai_task_create(s,m,region,prompt,base.text_get(params.agent[:]),params.conversation,base.text_get(params.model[:]),base.text_get(params.effort[:]),{detached=params.conversation!=0 && params.conversation!=m.main})
    if task==nil {
        api.call_fail(call,api.SERVER_ERROR,message)
        return
    }
    api.call_result(call,Ai_Task_Result)^=ai_task_result(s,task,call.allocator,true,0)
}

@(private)
ai_method_status :: proc(s:^Session,call:^api.Call) {
    m:=s.ai
    params:=api.call_params(call,Ai_Status_Params)
    only:^Ai_Task
    if params.id!=0 {
        if only=ai_task_find(m,params.id);only==nil {
            api.call_failf(call,api.INVALID_PARAMS,"there is no task %d",params.id)
            return
        }
    }
    rect :: proc(r:ui.Rect) -> [4]f32 {return {r.x,r.y,r.w,r.h}}
    r:=api.call_result(call,Ai_Status_Result)
    running:=make([dynamic]int,call.allocator)
    for &worker in m.workers {if worker.task!=0 {append(&running,int(worker.task))}}
    r.running,r.process_running,r.capacity,r.show_agents_in_scene=running[:],ai_process_running(m),AI_WORKER_CAPACITY,m.show_agents_in_scene
    r.permissions=make([]Ai_Status_Permission,m.permission_count,call.allocator)
    for &p,index in m.permissions[:m.permission_count] {
        options:=make([]Ai_Status_Option,p.count,call.allocator)
        for &option,at in options {option={base.text_get(p.ids[at][:]),base.text_get(p.names[at][:])}}
        r.permissions[index]={index,int(m.workers[p.worker].task),base.text_get(p.title[:]),options}
    }
    r.chat={m.chat_open,rect(m.chat_open?m.chat_rect:{}),rect(m.has_region?m.region:{}),int(m.selected),int(m.main)}
    tasks:=make([dynamic]Ai_Task_Result,call.allocator)
    for &task in m.tasks[:m.task_count] {
        if only==nil || only==&task {append(&tasks,ai_task_result(s,&task,call.allocator,only!=nil,params.from))}
    }
    r.tasks=tasks[:]
}

@(private)
ai_task_of :: proc(s:^Session,call:^api.Call) -> ^Ai_Task {
    id:=api.call_params(call,Ai_Id_Params).id
    task:=ai_task_find(s.ai,id)
    if task==nil {api.call_failf(call,api.INVALID_PARAMS,"there is no task %d",id)}
    return task
}

@(private)
ai_method_cancel :: proc(s:^Session,call:^api.Call) {
    task:=ai_task_of(s,call)
    if task==nil {return}
    ai_task_cancel(s,s.ai,task)
    api.call_result(call,Ai_Task_Result)^=ai_task_result(s,task,call.allocator,false,0)
}

@(private)
ai_method_compact :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    id:=api.call_params(call,Ai_Compact_Params).id
    if id==0 {id=s.ai.main}
    task:=ai_task_find(s.ai,id)
    if task==nil {api.call_failf(call,api.INVALID_PARAMS,"there is no chat %d: ai.status lists them",id);return}
    if message:=ai_chat_compact(s,task);message!="" {api.call_fail(call,api.INVALID_PARAMS,message);return}
    api.call_result(call,Ai_Task_Result)^=ai_task_result(s,task,call.allocator,false,0)
}

@(private)
ai_method_revert :: proc(s:^Session,call:^api.Call) {
    task:=ai_task_of(s,call)
    if task==nil {return}
    if message:=ai_task_revert(s,s.ai,task);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    ai_task_persist(s,task)
    api.call_result(call,Ai_Task_Result)^=ai_task_result(s,task,call.allocator,false,0)
}

ai_method_restore :: proc(s:^Session,call:^api.Call) {
    task:=ai_task_of(s,call)
    if task==nil {return}
    if message:=ai_task_restore(s,s.ai,task);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    ai_task_persist(s,task)
    api.call_result(call,Ai_Task_Result)^=ai_task_result(s,task,call.allocator,false,0)
}

ai_method_finish_review :: proc(s:^Session,call:^api.Call) {
    task:=ai_task_of(s,call)
    if task==nil {return}
    if !ai_task_finish(s,s.ai,task) {api.call_fail(call,api.SERVER_ERROR,"The task is not ready for review");return}
    ai_task_persist(s,task)
    api.call_result(call,Ai_Task_Result)^=ai_task_result(s,task,call.allocator,false,0)
}

ai_method_retry :: proc(s:^Session,call:^api.Call) {
    task:=ai_task_of(s,call)
    if task==nil {return}
    if message:=ai_task_retry(s,s.ai,task);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    api_frames(s,3,HEADLESS_DT)
    api.call_result(call,Ai_Task_Result)^=ai_task_result(s,task,call.allocator,false,0)
}

ai_method_history_search :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    p:=api.call_params(call,Ai_History_Search_Params)
    hits:[ai_store.SEARCH_HITS]ai_store.Search_Hit
    query:=base.text_get(p.query[:])
    if ai_store.index_match(query,false)=="" {api.call_fail(call,api.INVALID_PARAMS,ai_store.SEARCH_NO_WORDS);return}
    limit:=p.limit if p.limit>0 else 10
    count,message:=ai_store.search(&s.ai.store,query,hits[:min(limit,len(hits))],u64(p.conversation),marks={"**","**"},allocator=call.allocator)
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    kinds:=AI_LINE_NAMES
    found:=make([dynamic]Api_Ai_History_Search_Result,call.allocator)
    for &hit in hits[:count] {
        if c:=ai_store.find(&s.ai.store,hit.conversation);c!=nil {
            append(&found,Api_Ai_History_Search_Result{int(c.id),strings.clone(string(c.title[:c.title_len]),call.allocator),int(hit.sequence),kinds[hit.kind],hit.snippet,int(c.updated_at)})
        }
    }
    api.call_result(call,Api_Ai_History_Search).hits=found[:]
}

ai_method_permission :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Ai_Permission_Params)
    if message:=ai_permission_answer(s,p.index,base.text_get(p.option[:]),p.cancel);message!="" {api.call_fail(call,api.INVALID_PARAMS,message);return}
    api.call_result(call,Ai_Permission_Result).ok=true
}

ai_method_history :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    p:=api.call_params(call,Ai_History_Params)
    r:=api.call_result(call,Api_Ai_History)
    if p.id==0 {
        conversations:=make([]ai_store.Conversation,64,call.allocator)
        count,message:=ai_store.list(&s.ai.store,conversations,"",p.offset)
        if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
        r.conversations=make([]Api_Ai_Conversation,count,call.allocator)
        for &c,index in conversations[:count] {
            r.conversations[index]={int(c.id),string(c.title[:c.title_len]),string(c.document[:c.document_len]),string(c.provider[:c.provider_len]),string(c.model[:c.model_len]),string(c.effort[:c.effort_len]),int(c.updated_at)}
        }
        return
    }
    lines:[128]ai_store.Stored_Line
    count,message:=ai_store.page(&s.ai.store,u64(p.id),p.before==0?-1:i64(p.before),lines[:],call.allocator)
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    kinds:=AI_LINE_NAMES
    r.messages=make([]Api_Ai_Message,count,call.allocator)
    for &line,index in lines[:count] {
        r.messages[index]={int(line.sequence),kinds[line.kind],line.text,line.role,line.event_type,line.tool,line.context_json}
    }
}
