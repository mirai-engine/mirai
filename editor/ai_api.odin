package editor

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
    kind:[8]u8 `mirai:"text,label=main; agent (a subagent of the main chat) or archived"`,
    parent:int `mirai:"label=Of a subagent: its main chat"`,
    held:int `mirai:"label=Messages written to it that have not reached its agent"`,
    state:[16]u8 `mirai:"text,label=queued; running; done; failed; cancelled or interrupted"`,
    prompt:[96]u8 `mirai:"text,label=The start of the message"`,
    agent:[32]u8 `mirai:"text,label=The connection that runs it; until it starts the one asked for"`,
    model:[128]u8 `mirai:"text"`,
    effort:[32]u8 `mirai:"text"`,
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
    changed:[1]base.Entity_Id `mirai:"list,label=The entities it changed"`,
    changed_files:[1][AI_PATH_BYTES]u8 `mirai:"text,list,label=Project paths of the files it wrote through the API"`,
    skipped:int `mirai:"label=Changes that reverting it kept because others changed them later"`,
    undone:bool `mirai:"label=Its changes were reverted"`,
    declined:bool `mirai:"label=The user reverted it; ai.restore takes the changes back for review"`,
    needs_build:bool `mirai:"label=It changed the code of the project: it needs a Build"`,
    finish_called:bool `mirai:"label=The agent called finish; the task runs until its ACP turn ends"`,
    lines:int `mirai:"label=Lines of its transcript so far"`,
    first:int `mirai:"optional,label=Of a task asked by id: the line its transcript starts at"`,
    transcript:[1]Ai_Task_Line `mirai:"list,optional,label=Of a task asked by id: its lines from first"`,
}
Ai_Task_Line :: struct {
    kind:[8]u8 `mirai:"text,label=prompt (what it was asked); output (printed by the agent); note (said by the editor); report (a subagent with this id ended a turn) or divider (a new context of the chat began)"`,
    text:[AI_LINE_BYTES]u8 `mirai:"text"`,
}

Ai_Status_Result :: struct {
    running:[1]int `mirai:"list,label=The tasks a worker runs"`,
    process_running:bool `mirai:"label=Whether a process of an agent is open; also between turns"`,
    capacity:int `mirai:"label=How many conversations run at once"`,
    show_agents_in_scene:bool,
    permissions:[1]Ai_Status_Permission `mirai:"list,label=The requests of agents that wait for the user"`,
    chat:Ai_Status_Chat,
    tasks:[1]Ai_Task_Result `mirai:"list,label=Every task; with id only that one"`,
}
Ai_Status_Permission :: struct {
    index:int `mirai:"label=What ai.permission takes as index"`,
    task:int,
    title:[512]u8 `mirai:"text"`,
    options:[8]Ai_Status_Option,
}
Ai_Status_Option :: struct {
    id:[128]u8 `mirai:"text,label=What ai.permission takes as option"`,
    name:[128]u8 `mirai:"text"`,
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

@(private) AI_HISTORY_RESULT :: `{"type":"array","description":"Without id: the conversations of the project; the last updated first. With id: its messages; the oldest first.","items":{"anyOf":[` +
    `{"type":"object","properties":{"id":{"type":"integer","description":"What id takes"},"title":{"type":"string"},"document":{"type":"string","description":"The document it worked on"},"provider":{"type":"string","description":"The id of its connection"},"model":{"type":"string"},"effort":{"type":"string"},"updated_at":{"type":"integer","description":"Unix time in milliseconds"}},"required":["id","title","document","provider","model","effort","updated_at"],"additionalProperties":false},` +
    `{"type":"object","properties":{"sequence":{"type":"integer","description":"What before takes"},"kind":{"enum":["prompt","output","note","report","divider"]},"text":{"type":"string"},"role":{"type":"string"},"event_type":{"type":"string"},"tool":{"type":"string"},"context":{"type":"string","description":"JSON as text"}},"required":["sequence","kind","text","role","event_type","tool","context"],"additionalProperties":false}` +
    `]}}`

@(private) AI_HISTORY_SEARCH_RESULT :: `{"type":"array","description":"The matching lines of the saved conversations, the best first.","items":{"type":"object","properties":{` +
    `"conversation":{"type":"integer","description":"What ai.history takes as id"},"title":{"type":"string"},` +
    `"sequence":{"type":"integer","description":"ai.history with before set to sequence+1 returns the messages up to it"},` +
    `"kind":{"enum":["prompt","output","note","report","divider"],"description":"A note is said by the editor, as a step of a turn: Tool: method target"},` +
    `"snippet":{"type":"string","description":"Words around the matches, which go between **"},"updated_at":{"type":"integer","description":"Of the conversation, Unix time in milliseconds"}},` +
    `"required":["conversation","title","sequence","kind","snippet","updated_at"],"additionalProperties":false}}`

@(private)
ai_api_register :: proc(s:^Session,st:^Api_State) {
    ai_connections_api_register(s,st)
    ai_subagents_api_register(s,st)
    ai_memory_api_register(s,st)
    ai_annotations_api_register(s,st)
    ai_provenance_api_register(s,st)
    api_viewport_register(s,st)
    api_ai_finish_register(s,st)
    api_register(s,st,{name="ai.task",summary="Sends a message to the main chat of the project, or to a subagent, over ACP with the skills of the project and Mirai MCP, starting the agent when needed; poll ai.status until it ends.",params=Ai_Task_Params,result=Ai_Task_Result,writes_result=true,run=ai_method_task})
    api_register(s,st,{name="ai.status",summary="The tasks of the agents of this editor, with the permissions they wait for and the state of the chat.",params=Ai_Status_Params,result=Ai_Status_Result,writes_result=true,flags={.Read_Only},run=ai_method_status})
    api_register(s,st,{name="ai.cancel",summary="Stops the agent of a task, or takes a queued one out of the queue.",params=Ai_Id_Params,result=Ai_Task_Result,writes_result=true,flags={.Idempotent},run=ai_method_cancel})
    api_register(s,st,{name="ai.revert",summary="Reverts the scene fields and project files a task changed through the API, keeping what users or agents wrote afterwards. Files the agent wrote with its own tools stay.",params=Ai_Id_Params,result=Ai_Task_Result,writes_result=true,flags={.Destructive},run=ai_method_revert})
    api_register(s,st,{name="ai.restore",summary="Takes back the changes of a task the user reverted (declined) to be reviewed again, keeping newer edits of users or agents.",params=Ai_Id_Params,result=Ai_Task_Result,writes_result=true,flags={.Destructive},run=ai_method_restore})
    api_register(s,st,{name="ai.review.accept",summary="Confirms the result of a task and clears its agent icon and scene outlines without changing the scene.",params=Ai_Id_Params,result=Ai_Task_Result,writes_result=true,run=ai_method_finish_review})
    api_register(s,st,{name="ai.retry",summary="Reverts the scene changes of a task and sends its message again in the same conversation, with the same icon and color.",params=Ai_Id_Params,result=Ai_Task_Result,writes_result=true,run=ai_method_retry})
    api_register(s,st,{name="ai.history",summary="The saved conversations of the project, or a page of the saved messages of one.",params=Ai_History_Params,result_schema=AI_HISTORY_RESULT,flags={.Read_Only},run=ai_method_history})
    api_register(s,st,{name="ai.history.search",summary="Full-text search of the saved conversations of the project: what was asked, answered and done in earlier chats, by words, an entity id or an asset path, ranked by BM25. Each hit is short; ai.history with its conversation and before pages the messages around it.",params=Ai_History_Search_Params,result_schema=AI_HISTORY_SEARCH_RESULT,flags={.Read_Only},run=ai_method_history_search})
    api_register(s,st,{name="ai.turn_end",summary="Ends the turn of the agent outside the editor that calls (the client of mirai mcp, or mirai rpc --client NAME): its changes wait for the review of the user, and its next call opens the turn again until they are resolved. The turns of the agents of the editor and a turn already ended stay as they are. The Stop hook of Claude Code in a project calls it.",result=Ai_Turn_End_Result,flags={.Idempotent},run=ai_method_turn_end})
    api_register(s,st,{name="ai.compact",summary="Summarizes the context of a chat that is not working, with the command of its agent or else with a new native session; the chat goes on.",params=Ai_Compact_Params,result=Ai_Task_Result,writes_result=true,run=ai_method_compact})
    api_register(s,st,{name="ai.permission",summary="Answers a permission an agent waits for with one of its options, or cancels it.",params=Ai_Permission_Params,result=Ai_Permission_Result,run=ai_method_permission})
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
ai_put_rect :: proc(w:^serial.Writer,name:string,rect:ui.Rect,first:=false) {
    values:=[4]f32{rect.x,rect.y,rect.w,rect.h}
    api.write_numbers(w,name,values[:],first)
}

@(private)
ai_task_write :: proc(s:^Session,task:^Ai_Task,w:^serial.Writer,transcript:bool,from:int) {
    names:=AI_STATE_NAMES
    kinds:=AI_LINE_NAMES
    conversation_kinds:=[ai_store.Conversation_Kind]string{.Main="main",.Agent="agent",.Archived="archived"}
    t:=&task.transcript
    serial.write_u8(w,'{')
    api.write_int(w,"id",i64(task.id),true)
    api.write_text(w,"kind",conversation_kinds[task.conversation.kind])
    api.write_int(w,"parent",i64(task.conversation.parent))
    api.write_int(w,"held",i64(ai_task_held(task)))
    api.write_text(w,"state",names[task.state])
    api.write_text(w,"prompt",base.text_get(task.title[:]))
    api.write_text(w,"agent",base.text_get(task.agent[:]))
    api.write_text(w,"model",string(task.conversation.model[:task.conversation.model_len]))
    api.write_text(w,"effort",string(task.conversation.effort[:task.conversation.effort_len]))
    api.write_bool(w,"play",task.play)
    ai_put_rect(w,"region",task.region)
    api.write_int(w,"entities",i64(task.entities))
    api.write_bool(w,"image",task.image)
    api.write_key(w,"seconds");api.write_number(w,task.seconds)
    api.write_int(w,"steps",i64(len(task.review.transactions)))
    api.write_bool(w,"revertible",ai_task_finished(task) && !task.review_finished && ai_review_revertible(s,&task.review) && !task.files_changed && ai_task_current(s,task))
    api.write_bool(w,"review_finished",task.review_finished)
    api.write_bool(w,"review_pending",task.review.pending)
    api.write_bool(w,"files_changed",task.files_changed)
    api.write_key(w,"changed");serial.write_u8(w,'[')
    for id,index in task.review.changed_ids {if index>0 {serial.write_u8(w,',')};api.write_id(w,id)}
    serial.write_u8(w,']')
    api.write_key(w,"changed_files");serial.write_u8(w,'[')
    for path,index in task.review.changed_files {if index>0 {serial.write_u8(w,',')};serial.text_write_string(w,path)}
    serial.write_u8(w,']')
    api.write_int(w,"skipped",i64(task.review.skipped))
    api.write_bool(w,"undone",task.undone)
    api.write_bool(w,"declined",task.declined)
    api.write_bool(w,"needs_build",task.needs_build)
    api.write_bool(w,"finish_called",task.finish_called)
    api.write_int(w,"lines",i64(t.dropped+t.count))
    if transcript {
        first:=clamp(from-t.dropped,0,t.count)
        api.write_int(w,"first",i64(t.dropped+first))
        api.write_key(w,"transcript");serial.write_u8(w,'[')
        for index in first..<t.count {
            text,kind:=ai_transcript_line(t,index)
            if index>first {serial.write_u8(w,',')}
            serial.write_u8(w,'{')
            api.write_text(w,"kind",kinds[kind],true)
            api.write_text(w,"text",text)
            serial.write_u8(w,'}')
        }
        serial.write_u8(w,']')
    }
    serial.write_u8(w,'}')
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
    ai_task_write(s,task,call.out,true,0)
}

@(private)
ai_method_status :: proc(s:^Session,call:^api.Call) {
    m:=s.ai
    params:=api.call_params(call,Ai_Status_Params)
    w:=call.out
    only:^Ai_Task
    if params.id!=0 {
        if only=ai_task_find(m,params.id);only==nil {
            api.call_failf(call,api.INVALID_PARAMS,"there is no task %d",params.id)
            return
        }
    }
    serial.write_u8(w,'{')
    api.write_key(w,"running",true);serial.write_u8(w,'[')
    comma:=false
    for &worker in m.workers {if worker.task!=0 {if comma {serial.write_u8(w,',')};comma=true;serial.text_write_int(w,i64(worker.task))}}
    serial.write_u8(w,']')
    api.write_bool(w,"process_running",ai_process_running(m))
    api.write_int(w,"capacity",AI_WORKER_CAPACITY)
    api.write_bool(w,"show_agents_in_scene",m.show_agents_in_scene)
    api.write_key(w,"permissions");serial.write_u8(w,'[')
    for &p,index in m.permissions[:m.permission_count] {
        if index>0 {serial.write_u8(w,',')}
        serial.write_u8(w,'{');api.write_int(w,"index",i64(index),true);api.write_int(w,"task",i64(m.workers[p.worker].task));api.write_text(w,"title",base.text_get(p.title[:]))
        api.write_key(w,"options");serial.write_u8(w,'[')
        for option in 0..<p.count {if option>0 {serial.write_u8(w,',')};serial.write_u8(w,'{');api.write_text(w,"id",base.text_get(p.ids[option][:]),true);api.write_text(w,"name",base.text_get(p.names[option][:]));serial.write_u8(w,'}')}
        serial.text_write_raw(w,"]}")
    }
    serial.write_u8(w,']')
    api.write_key(w,"chat");serial.write_u8(w,'{')
    api.write_bool(w,"open",m.chat_open,true)
    ai_put_rect(w,"rect",m.chat_open?m.chat_rect:{})
    ai_put_rect(w,"region",m.has_region?m.region:{})
    api.write_int(w,"selected",i64(m.selected))
    api.write_int(w,"main",i64(m.main))
    serial.write_u8(w,'}')
    api.write_key(w,"tasks");serial.write_u8(w,'[')
    first:=true
    for &task in m.tasks[:m.task_count] {
        if only!=nil && only!=&task {continue}
        if !first {serial.write_u8(w,',')}
        first=false
        ai_task_write(s,&task,w,only!=nil,params.from)
    }
    serial.text_write_raw(w,"]}")
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
    ai_task_write(s,task,call.out,false,0)
}

@(private)
ai_method_compact :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    id:=api.call_params(call,Ai_Compact_Params).id
    if id==0 {id=s.ai.main}
    task:=ai_task_find(s.ai,id)
    if task==nil {api.call_failf(call,api.INVALID_PARAMS,"there is no chat %d: ai.status lists them",id);return}
    if message:=ai_chat_compact(s,task);message!="" {api.call_fail(call,api.INVALID_PARAMS,message);return}
    ai_task_write(s,task,call.out,false,0)
}

@(private)
ai_method_revert :: proc(s:^Session,call:^api.Call) {
    task:=ai_task_of(s,call)
    if task==nil {return}
    if message:=ai_task_revert(s,s.ai,task);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    ai_task_persist(s,task)
    ai_task_write(s,task,call.out,false,0)
}

ai_method_restore :: proc(s:^Session,call:^api.Call) {
    task:=ai_task_of(s,call)
    if task==nil {return}
    if message:=ai_task_restore(s,s.ai,task);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    ai_task_persist(s,task)
    ai_task_write(s,task,call.out,false,0)
}

ai_method_finish_review :: proc(s:^Session,call:^api.Call) {
    task:=ai_task_of(s,call)
    if task==nil {return}
    if !ai_task_finish(s,s.ai,task) {api.call_fail(call,api.SERVER_ERROR,"The task is not ready for review");return}
    ai_task_persist(s,task)
    ai_task_write(s,task,call.out,false,0)
}

ai_method_retry :: proc(s:^Session,call:^api.Call) {
    task:=ai_task_of(s,call)
    if task==nil {return}
    if message:=ai_task_retry(s,s.ai,task);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    api_frames(s,3,HEADLESS_DT)
    ai_task_write(s,task,call.out,false,0)
}

ai_method_history_search :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    p:=api.call_params(call,Ai_History_Search_Params);w:=call.out
    hits:[ai_store.SEARCH_HITS]ai_store.Search_Hit
    query:=base.text_get(p.query[:])
    if ai_store.index_match(query,false)=="" {api.call_fail(call,api.INVALID_PARAMS,ai_store.SEARCH_NO_WORDS);return}
    limit:=p.limit if p.limit>0 else 10
    count,message:=ai_store.search(&s.ai.store,query,hits[:min(limit,len(hits))],u64(p.conversation),marks={"**","**"},allocator=call.allocator)
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    kinds:=AI_LINE_NAMES
    serial.write_u8(w,'[')
    written:=0
    for &hit in hits[:count] {
        c:=ai_store.find(&s.ai.store,hit.conversation)
        if c==nil {continue}
        if written>0 {serial.write_u8(w,',')}
        written+=1
        serial.write_u8(w,'{');api.write_int(w,"conversation",i64(c.id),true);api.write_text(w,"title",string(c.title[:c.title_len]))
        api.write_int(w,"sequence",i64(hit.sequence));api.write_text(w,"kind",kinds[hit.kind]);api.write_text(w,"snippet",hit.snippet)
        api.write_int(w,"updated_at",c.updated_at);serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
}

ai_method_permission :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Ai_Permission_Params)
    if message:=ai_permission_answer(s,p.index,base.text_get(p.option[:]),p.cancel);message!="" {api.call_fail(call,api.INVALID_PARAMS,message);return}
    api.call_result(call,Ai_Permission_Result).ok=true
}

ai_method_history :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    p:=api.call_params(call,Ai_History_Params);w:=call.out
    if p.id==0 {
        conversations:[64]ai_store.Conversation
        count,message:=ai_store.list(&s.ai.store,conversations[:],"",p.offset)
        if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
        serial.write_u8(w,'[')
        for &c,index in conversations[:count] {
            if index>0 {serial.write_u8(w,',')}
            serial.write_u8(w,'{');api.write_int(w,"id",i64(c.id),true)
            api.write_text(w,"title",string(c.title[:c.title_len]));api.write_text(w,"document",string(c.document[:c.document_len]))
            api.write_text(w,"provider",string(c.provider[:c.provider_len]));api.write_text(w,"model",string(c.model[:c.model_len]));api.write_text(w,"effort",string(c.effort[:c.effort_len]))
            api.write_int(w,"updated_at",c.updated_at);serial.write_u8(w,'}')
        }
        serial.write_u8(w,']');return
    }
    lines:[128]ai_store.Stored_Line
    count,message:=ai_store.page(&s.ai.store,u64(p.id),p.before==0?-1:i64(p.before),lines[:],call.allocator)
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    serial.write_u8(w,'[')
    kinds:=AI_LINE_NAMES
    for &line,index in lines[:count] {
        if index>0 {serial.write_u8(w,',')}
        serial.write_u8(w,'{');api.write_int(w,"sequence",i64(line.sequence),true);api.write_text(w,"kind",kinds[line.kind]);api.write_text(w,"text",line.text)
        api.write_text(w,"role",line.role);api.write_text(w,"event_type",line.event_type);api.write_text(w,"tool",line.tool);api.write_text(w,"context",line.context_json);serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
}
