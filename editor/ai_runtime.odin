package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:editor/acp"
import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// What Codex brings of the user's own setup stays out of the agent of the
// editor, which works on the game: the skills, the AGENTS.md files, plugins,
// apps and browser or computer use. Its sandbox writes only inside the
// project, and what it asks to do outside is declined (ai_permission_policy),
// except deleting files, which the user answers (ai_permissions.odin).
AI_CODEX_SESSION_CONFIG :: `CODEX_CONFIG={"project_doc_max_bytes":0,"skills.include_instructions":false,"features.apps":false,"features.plugins":false,"features.remote_plugin":false,"features.tool_suggest":false,"features.skill_search":false,"features.browser_use":false,"features.browser_use_external":false,"features.computer_use":false,"features.image_generation":false}`

AI_IDLE_SECONDS :: f64(300)
AI_SILENT_SECONDS :: f64(120)
AI_CANCEL_SECONDS :: f64(3)
Ai_Model_Option :: struct {name,value:[128]u8}
Ai_Worker :: struct {
    client:acp.Client,
    created:bool,
    provider:Ai_Provider,
    task,last_task:int,
    agent:int, // serial of the process of the agent, which its commands send as the task context agent-<serial>
    idle_since:f64,
    cancel_deadline:f64,
    tool:[128]u8, // title of the last tool call, which a tool approval may only refer to by id
    calls:[AI_TOOL_CALLS]Ai_Tool_Call, // tools of the agent under way in the turn
    call_count:int,
}

// A tool of the agent itself (a command it runs, a file it reads or edits)
// while it is under way: once it ends it is a step of the turn.
AI_TOOL_CALLS :: 16
Ai_Tool_Call :: struct {
    id:[64]u8,
    title:[160]u8,
    kind:[16]u8, // as ACP names it: read, edit, delete, move, search, execute, think, fetch, other
    started:time.Tick,
}
Ai_Callback :: struct {session:^Session,worker:^Ai_Worker}

Ai_Permission :: struct {
    worker:int,
    request:[256]u8,
    title:[512]u8,
    ids,names:[8][128]u8,
    count:int,
}

ai_initialize :: proc(s:^Session) {
    m:=s.ai
    if m.initialized || !s.has_project {return}
    m.initialized=true
    ai_settings_initialize(s)
    if message:=ai_store.open(&m.store,s.project_root);message!="" {notify(s,message);return}
    ai_memory_scan(s)
    ai_history_refresh(s)
    if saved:=ai_store.main_conversation(&m.store);saved!=nil {
        conversation:=saved^
        if task:=ai_conversation_restore(s,&conversation);task!=nil {
            m.main,m.selected=task.id,task.id
            m.stick=true
            base.text_set(m.agent[:],base.text_get(task.agent[:]))
            ai_held_count(s,task)
            ai_main_reopen(s,m,task)
        }
    }
    ai_agents_interrupted_restore(s,m)
    // What still waits for review: the subagents, and the agents outside the editor.
    waiting:[64]ai_store.Conversation
    count,_:=ai_store.list(&m.store,waiting[:],document_path(s.document),kinds={.Agent,.Archived})
    for &conversation in waiting[:count] {
        if m.task_count==AI_TASK_CAPACITY {break}
        if task:=ai_conversation_restore(s,&conversation,only_pending=true);task!=nil {ai_held_count(s,task)}
    }
}

// The messages a chat kept for its next turn when the editor closed.
@(private)
ai_held_count :: proc(s:^Session,task:^Ai_Task) {
    deliveries,_:=ai_store.deliveries(&s.ai.store,task.conversation.id)
    for &delivery in deliveries {
        if delivery.kind!=AI_DELIVERY_STEER {continue}
        task.held+=1
        task.held_lines+=strings.count(delivery.text,"\n")+1
    }
}

// Lists a page of the saved subagents whose titles have needle or whose lines
// match it in the search index; one found by its lines shows what matched in
// place of its last answer.
ai_history_refresh :: proc(s:^Session,offset:int=0,needle:string="") {
    m:=s.ai
    hits:[ai_store.HISTORY_HITS]ai_store.Search_Hit
    found:[ai_store.HISTORY_HITS]u64
    found_count:=0
    if needle!="" && ai_store.index_match(needle,true)!="" {
        // Without the index the search keeps to the titles.
        count,_:=ai_store.search(&m.store,needle,hits[:],prefix=true)
        for &hit in hits[:count] {
            if !slice.contains(found[:found_count],hit.conversation) {hits[found_count]=hit;found[found_count]=hit.conversation;found_count+=1}
        }
    }
    count,message:=ai_store.list(&m.store,m.history[:],"",offset,needle,found[:found_count],kinds={.Agent},parent=u64(m.main))
    if message!="" {notify(s,message);return}
    m.history_count,m.history_offset=count,offset
    for &c in m.history[:count] {
        if needle=="" {ai_history_outcome(m,&c)}
        if contains_fold(string(c.title[:c.title_len]),needle) {continue}
        if at,ok:=slice.linear_search(found[:found_count],c.id);ok {
            plain:[ai_store.LAST_BYTES*2]u8
            c.last_len=copy(c.last[:],ai_utf8_cut(ai_entity_marks_plain(hits[at].snippet,plain[:]),ai_store.LAST_BYTES))
        }
    }
}

// How the review of a finished agent ended, in place of its last answer.
@(private)
ai_history_outcome :: proc(m:^Ai,c:^ai_store.Conversation) {
    lines:[4]ai_store.Stored_Line
    count,_:=ai_store.page(&m.store,c.id,-1,lines[:])
    #reverse for &line in lines[:count] {
        if line.kind==.Note && strings.has_prefix(line.text,AI_REVIEWED_NOTE) {
            c.last_len=copy(c.last[:],line.text)
            return
        }
    }
}

ai_conversation_restore :: proc(s:^Session,conversation:^ai_store.Conversation,only_pending:bool=false) -> ^Ai_Task {
    m:=s.ai
    if task:=ai_task_find(m,int(conversation.id));task!=nil {
        ai_task_review_follow(s,task)
        return task
    }
    if only_pending {
        if m.task_count==AI_TASK_CAPACITY || !ai_review_pending(s,conversation.id) {return nil}
    }
    task:=ai_task_slot(m)
    if task==nil {return nil}
    task.id=int(conversation.id);task.state=.Done;task.conversation=conversation^
    ai_context_restored(task)
    task.review_finished=true
    task.world=string(conversation.document[:conversation.document_len])==document_path(s.document)?s.edit_world:nil
    base.text_set(task.title[:],string(conversation.title[:conversation.title_len]))
    base.text_set(task.agent[:],string(conversation.provider[:conversation.provider_len]))
    ai_task_glyph_set(m,task)
    if message:=ai_transcript_load(&m.store,conversation.id,&task.transcript);message!="" {notify(s,message);return task}
    latest:=-1
    for i:=task.transcript.count-1;i>=0;i-=1 {if task.transcript.lines[i].kind==.Prompt {latest=i;break}}
    if latest>=0 {
        first:=latest
        sequence:=ai_store.latest_user_message(&m.store,conversation.id)
        if sequence>=0 {first=int(sequence)-task.transcript.dropped} else {
            for first>0 && task.transcript.lines[first-1].kind==.Prompt {first-=1}
            sequence=i64(task.transcript.dropped+first)
        }
        base.text_format(task.name[:],"%d-%d",task.id,sequence)
        // The message of the turn, from the chat when its folder lost it.
        if path:=ai_task_path(s,task,AI_FILE_MESSAGE);!os.exists(path) && os.make_directory_all(ai_task_path(s,task,""))==nil {
            b:=strings.builder_make(context.temp_allocator)
            for i in max(first,0)..=latest {
                text,_:=ai_transcript_line(&task.transcript,i)
                if i>max(first,0) {strings.write_byte(&b,'\n')}
                strings.write_string(&b,text)
            }
            _=os.write_entire_file(path,strings.to_string(b))
        }
    }
    // The review names entities of the scene of the conversation: it is read
    // with that scene open (ai_task_review_follow).
    task.review_deferred=string(conversation.document[:conversation.document_len])!=document_path(s.document)
    if !task.review_deferred {
        if message:=ai_review_load(s,task);message!="" {notify(s,message)}
    }
    m.scene_serial+=1
    return task
}

// A conversation restored while another scene was open takes its review once
// its scene is the one open and it is shown again.
ai_task_review_follow :: proc(s:^Session,task:^Ai_Task) {
    if !task.review_deferred || task.document_closed || s.document==nil || string(task.conversation.document[:task.conversation.document_len])!=document_path(s.document) {return}
    task.review_deferred=false
    task.world=s.edit_world
    if message:=ai_review_load(s,task);message!="" {notify(s,message)}
    s.ai.scene_serial+=1
}

ai_history_select :: proc(s:^Session,conversation:^ai_store.Conversation) {
    if task:=ai_conversation_restore(s,conversation);task!=nil {ai_chat_select(s,task)}
    else {notify(s,"Too many conversations are awaiting review")}
}

ai_task_current :: proc(s:^Session,task:^Ai_Task) -> bool {
    if task.document_closed {return false}
    if task.world!=nil && task.world!=s.edit_world {return false}
    document:=string(task.conversation.document[:task.conversation.document_len])
    return document==(s.document!=nil?document_path(s.document):"")
}

ai_task_persist :: proc(s:^Session,task:^Ai_Task) {
    if !task.dirty || task.conversation.id==0 || s.ai.store.folder=="" {return}
    task.conversation.updated_at=time.to_unix_nanoseconds(time.now())/1_000_000
    if message:=ai_transcript_save(&s.ai.store,&task.conversation,&task.transcript,task.dirty_sequence);message!="" {
        notify(s,message);return
    }
    task.dirty=false
    if message:=ai_review_save(s,task);message!="" {notify(s,message)}
}

// The message of a turn in its chat: what the chat has not saved is saved
// before its oldest lines make room.
ai_task_prompt_add :: proc(s:^Session,task:^Ai_Task,text:string) {
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        line:=strings.trim_right(line,"\r")
        for {
            count:=min(len(line),AI_LINE_BYTES)
            if count<len(line) {for count>0 && (u8(line[count])&0xc0)==0x80 {count-=1}}
            t:=&task.transcript
            if t.count==AI_TRANSCRIPT_LINES || t.used+count>AI_TRANSCRIPT_BYTES {
                ai_task_persist(s,task)
                ai_transcript_drop(t)
            }
            ai_task_dirty(task)
            ai_transcript_add(t,line[:count],.Prompt)
            line=line[count:]
            if line=="" {break}
        }
    }
}

// The instructions the editor adds for the agents of the project: a file of
// the project, read when a turn starts and written by ai.configure.
ai_instructions_path :: proc(s:^Session) -> string {
    return project.path(s.project_root,".mirai","ai","instructions.md",allocator=context.temp_allocator)
}

ai_instructions_read :: proc(s:^Session) -> string {
    if s.project_root=="" {return ""}
    data,error:=os.read_entire_file(ai_instructions_path(s),context.temp_allocator)
    return error==nil?string(data):""
}

ai_instructions_write :: proc(s:^Session,text:string) -> string {
    if len(text)>=AI_MESSAGE_BYTES {return "The instructions exceed their capacity"}
    path:=ai_instructions_path(s)
    if text=="" {
        if os.exists(path) && os.remove(path)!=nil {return "The instructions could not be cleared"}
        return ""
    }
    folder:=project.path(s.project_root,".mirai","ai",allocator=context.temp_allocator)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return "The instructions could not be saved"}
    if serial.file_write_atomic(path,transmute([]u8)text)!=.None {return "The instructions could not be saved"}
    // They go with the stable block, which a context that has it would not get again.
    if s.ai!=nil {for &task in s.ai.tasks[:s.ai.task_count] {task.stable_native={}}}
    return ""
}

ai_task_dirty :: proc(task:^Ai_Task) {
    first:=max(task.transcript.dropped+task.transcript.count-1,0)
    if !task.dirty {task.dirty_sequence=first} else {task.dirty_sequence=min(task.dirty_sequence,first)}
    task.dirty=true
}

ai_stream_add :: proc(s:^Session,task:^Ai_Task,text:string) {
    if text=="" {return}
    for rune,index in text {
        if rune=='\r' {continue}
        end:=index+1
        for end<len(text) && (u8(text[end])&0xc0)==0x80 {end+=1}
        count:=end-index
        t:=&task.transcript
        if t.used+count>AI_TRANSCRIPT_BYTES || (!task.stream_open || t.count==0 || int(t.lines[t.count-1].length)+count>AI_LINE_BYTES) && t.count==AI_TRANSCRIPT_LINES {
            ai_task_persist(s,task)
            ai_transcript_drop(t)
        }
        ai_task_dirty(task)
        if !task.stream_open || task.transcript.count==0 {
            ai_transcript_add(&task.transcript,"",.Output);task.stream_open=true
        }
        if rune=='\n' {task.stream_open=false;continue}
        if int(t.lines[t.count-1].length)+count>AI_LINE_BYTES {ai_transcript_add(t,"",.Output)}
        t.used+=copy(t.bytes[t.used:],text[index:end]);t.lines[t.count-1].length+=u16(count);ai_transcript_touch(t,t.count-1)
    }
}

ai_task_note :: proc(s:^Session,task:^Ai_Task,format:string,args:..any) {
    if task.transcript.count==AI_TRANSCRIPT_LINES || task.transcript.used+256>AI_TRANSCRIPT_BYTES {ai_task_persist(s,task)}
    ai_task_dirty(task)
    ai_note(task,format,..args)
}

// A call of the API that the turn made, a step of the turn: what it worked
// on, the ids and paths it names (ai_call_refs), when since the turn
// started, how long it took, or why it failed.
ai_tool_note :: proc(s:^Session,task:^Ai_Task,method,target,refs,failure:string,took:time.Duration) {
    task.stream_open=false
    at:=task.started=={}?0:time.duration_seconds(time.tick_since(task.started))
    // The target ends where the fields of the note begin.
    target,_:=strings.replace_all(target," · "," ",context.temp_allocator)
    space:=" " if target!="" else ""
    named:=fmt.tprintf(" · ref %s",refs) if refs!="" else ""
    if failure!="" {ai_task_note(s,task,"Tool failed: %s%s%s%s · +%.1f s · %s",method,space,target,named,at,failure)}
    else {ai_task_note(s,task,"Tool: %s%s%s%s · +%.1f s · %.1f ms",method,space,target,named,at,time.duration_milliseconds(took))}
}

// A tool call of the agent, as ACP reports it while it goes: when it ends it
// is a step of the turn, as a call of the API is, with its kind as the method
// and its title as what it worked on. The tools of the editor's MCP server
// are steps already, by the header of the turn.
ai_tool_call_receive :: proc(s:^Session,worker:^Ai_Worker,task:^Ai_Task,update:json.Value) {
    id:=acp.text(acp.at(update,"toolCallId"))
    if id=="" {return}
    index:=-1
    for &call,i in worker.calls[:worker.call_count] {if base.text_get(call.id[:])==id {index=i;break}}
    if index<0 {
        if worker.call_count==AI_TOOL_CALLS {return}
        index=worker.call_count
        worker.call_count+=1
        worker.calls[index]={started=time.tick_now()}
        base.text_set(worker.calls[index].id[:],id)
    }
    call:=&worker.calls[index]
    if title:=acp.text(acp.at(update,"title"));title!="" {base.text_set(call.title[:],title)}
    if kind:=acp.text(acp.at(update,"kind"));kind!="" {base.text_set(call.kind[:],kind)}
    status:=acp.text(acp.at(update,"status"))
    if status!="completed" && status!="failed" {return}
    title:=base.text_get(call.title[:])
    editor:=strings.has_prefix(title,"mcp.mirai.") || strings.has_prefix(title,"mcp__mirai__") || acp.text(acp.at(update,"rawInput","server"))=="mirai"
    if !editor && title!="" {
        kind:=base.text_get(call.kind[:])
        if kind=="" {kind="other"}
        ai_tool_note(s,task,kind,title,"",status=="failed"?"failed":"",time.tick_since(call.started))
    }
    worker.calls[index]=worker.calls[worker.call_count-1]
    worker.call_count-=1
}

// The tool of the agent under way the latest, for the line of what it does now.
ai_tool_call_current :: proc(m:^Ai,task:^Ai_Task) -> (kind,title:string,ok:bool) {
    for &worker in m.workers {
        if worker.task!=task.id || worker.call_count==0 {continue}
        call:=&worker.calls[worker.call_count-1]
        return base.text_get(call.kind[:]),base.text_get(call.title[:]),true
    }
    return
}

ai_start_client :: proc(s:^Session,worker:^Ai_Worker,provider:Ai_Provider) -> string {
    m:=s.ai;c:=&worker.client;connection:=&m.connections[provider]
    if !connection.installed {return connection.agent==.Command?"The command of the agent was not found":"Download the agent from AI connections first"}
    if c.process!=0 {
        if worker.provider==provider && c.phase!=.Failed && c.phase!=.Stopping {return ""}
        if c.phase!=.Stopping {acp.stop(c,s.app.platform)}
        return "The previous agent is closing; retry shortly"
    }
    if !worker.created {
        error:=acp.create(&worker.client,s.app.allocator,receive_bytes=4<<20)
        if error!=.None {return "No memory for the ACP connection"}
        worker.created=true
    }
    command:=make([dynamic]string,context.temp_allocator)
    if connection.agent==.Command {
        program,found:=ai_executable_find(base.text_get(connection.command[:]))
        if !found {return "The command of the agent was not found"}
        append(&command,program)
        for i in 0..<connection.argument_count {append(&command,base.text_get(connection.arguments[i][:]))}
    } else if connection.user {
        // The adapter of the user: its program, or with Node the script of its npm package.
        program,script:=ai_user_adapter(connection.agent)
        if program=="" {return "The adapter of your installation is gone; install it again or download the agent"}
        if script!="" {
            node,found:=ai_executable_find("node")
            if !found {return "Node is needed to start the adapter npm installed"}
            append(&command,node)
        }
        append(&command,program)
    } else if entry:=ai_agent_entry(m,connection.agent,connection.runtime);connection.runtime==.Bundled {append(&command,entry)} else {
        runtime,found:=ai_runtime_path(s,connection.runtime)
        if !found {return "The selected runtime is missing; reinstall the agent"}
        append(&command,runtime)
        if connection.runtime==.Bun {append(&command,"--no-install")}
        if connection.runtime==.Pnpm {
            when ODIN_OS==.Windows {command[0]="cmd";append(&command,"/d","/c",runtime)}
            append(&command,"--silent","--dir",ai_agents_folder(m,ai_connection_id(m,provider)),"run","mirai-acp")
        } else {append(&command,entry)}
    }
    // The environment of the user as it is: the agent signs in and configures
    // itself as it always does. Mirai only names the program of the agent
    // and, for the commands it runs, this editor and the agent.
    environment:=make([dynamic]string,context.temp_allocator)
    if connection.agent==.Codex {
        if !ai_codex_rules_write(s.project_root) {return "The rules that make Codex ask before deleting files could not be written in .codex/rules"}
        if binary:=ai_codex_binary(s);binary!="" {append(&environment,fmt.tprintf("CODEX_PATH=%s",binary))}
        else if !connection.user {return "The native Codex executable is missing; download the agent again"}
        append(&environment,ai_codex_session_config(s.project_root),"INITIAL_AGENT_MODE=workspace-write")
    }
    if connection.agent==.Claude {
        binary:=ai_claude_binary()
        if binary=="" {return "Claude Code is missing; download the agent again"}
        append(&environment,fmt.tprintf("CLAUDE_CODE_EXECUTABLE=%s",binary))
    }
    // The process outlives a turn, so what its commands inherit names the
    // agent, and the editor attributes their calls to the turn it runs.
    m.agent_serial+=1
    worker.agent=m.agent_serial
    append(&environment,fmt.tprintf("%s=%s%d",api.AI_TASK_VARIABLE,AI_AGENT_TAG,worker.agent),fmt.tprintf("%s=%d",api.PORT_VARIABLE,api_port(s)))
    worker.provider=provider
    if acp.start(c,s.app.platform,{command=command[:],working_directory=s.project_root,environment=environment[:]},session_titles=connection.agent==.Codex)!=.None {return "The ACP agent could not be started"}
    worker.idle_since=0
    return ""
}

// The tools of the editor are allowed to Claude without asking, but those that
// delete (AI_CLAUDE_SESSION_META): what they change is reviewed and reverted in
// the editor, as with Codex (ai_permission_policy). Everything else asks the user.
ai_open_task_session :: proc(s:^Session,worker:^Ai_Worker,task:^Ai_Task) {
    m:=s.ai
    meta:=m.connections[worker.provider].agent==.Claude?AI_CLAUDE_SESSION_META:""
    server:=fmt.tprintf(`[{{"type":"http","name":"mirai","url":"http://127.0.0.1:%d/mcp","headers":[{{"name":"X-Mirai-Ai-Task","value":"%s"}}]}]`,api_port(s),base.text_get(task.name[:]))
    title:=m.connections[worker.provider].agent==.Codex?string(task.conversation.title[:task.conversation.title_len]):""
    if error:=acp.open_session(&worker.client,{cwd=s.project_root,session_id=string(task.conversation.native_session[:task.conversation.native_session_len]),mcp_servers_json=server,model=string(task.conversation.model[:task.conversation.model_len]),effort=string(task.conversation.effort[:task.conversation.effort_len]),title=title,meta=meta});error!=.None {
        ai_task_fail(task,"The ACP session could not be opened: %v",error);ai_task_end(s,m,task,1)
    }
}

ai_send_task_prompt :: proc(s:^Session,worker:^Ai_Worker,task:^Ai_Task) {
    worker.call_count=0
    native:=acp.session_id(&worker.client)
    c:=&task.conversation
    new_context:=string(c.native_session[:c.native_session_len])!=native
    ai_store.conversation_set_text(c.native_session[:],&c.native_session_len,native)
    turn,error:=os.read_entire_file(ai_task_path(s,task,AI_FILE_PROMPT),context.temp_allocator)
    if error!=nil {ai_task_fail(task,"The editor instructions could not be read");ai_task_end(s,s.ai,task,1);return}
    message,message_error:=os.read_entire_file(ai_task_path(s,task,AI_FILE_MESSAGE),context.temp_allocator)
    if message_error!=nil {ai_task_fail(task,"The message of the turn could not be read");ai_task_end(s,s.ai,task,1);return}
    // What waited for this chat goes with its turn, whatever started it.
    deliveries:[]ai_store.Delivery
    if s.ai.store.db!=nil {
        problem:string
        deliveries,problem=ai_store.deliveries(&s.ai.store,task.conversation.id)
        if problem!="" {notify(s,problem)}
    }
    remind:=ai_context_filling(task) && base.text_get(task.notes_native[:])!=native
    handoff:=new_context?ai_handoff_build(s,task,ai_task_turn_sequence(task)):""
    delta:=ai_delta_build(s,task,string(turn),handoff,deliveries,remind)
    // The stable block goes first and alone, so that it is the prefix the prompt cache keeps.
    send_stable:=base.text_get(task.stable_native[:])!=native
    stable:=send_stable?ai_prompt_stable(s,c.kind):""
    content:=make([dynamic]acp.Content,context.temp_allocator)
    if send_stable {append(&content,acp.Content{kind=.Text,text=stable})}
    append(&content,acp.Content{kind=.Text,text=delta})
    if len(message)>0 {append(&content,acp.Content{kind=.Text,text=string(message)})}
    if task.references>0 && !worker.client.image {ai_task_fail(task,"This agent does not take images: send the message without its references");ai_task_end(s,s.ai,task,1);return}
    if problem,ok:=ai_references_content(s,task,&content);!ok {ai_task_fail(task,problem);ai_task_end(s,s.ai,task,1);return}
    if error:=acp.prompt(&worker.client,content[:]);error!=.None {ai_task_fail(task,"The prompt could not be sent: %v",error);ai_task_end(s,s.ai,task,1);return}
    if os.write_entire_file(ai_task_path(s,task,AI_FILE_PROMPT),strings.concatenate({stable,delta},context.temp_allocator))!=nil {notify(s,"The instructions of the turn could not be kept")}
    base.text_set(task.stable_native[:],native)
    if remind {base.text_set(task.notes_native[:],native)}
    if c.kind==.Main && s.ai.store.db!=nil {
        if new_context {
            if problem:=ai_store.meta_set(&s.ai.store,AI_META_INTERRUPTED_AGENTS,"");problem!="" {notify(s,problem)}
        }
        now:=time.to_unix_nanoseconds(time.now())/1_000_000
        if problem:=ai_store.meta_set(&s.ai.store,fmt.tprintf(AI_META_CONTEXT_SINCE,c.id),fmt.tprintf("%d",now));problem!="" {notify(s,problem)}
    }
    for &delivery in deliveries {
        if problem:=ai_store.delivery_remove(&s.ai.store,delivery.id);problem!="" {notify(s,problem)}
    }
    if len(deliveries)>0 {
        task.held,task.held_lines=0,0
        for &steer in task.steers[:task.steer_count] {task.held_lines+=steer.lines}
    }
    task.heard,task.silent=platform.clock_seconds(),false
    ai_task_dirty(task);ai_task_persist(s,task)
}

ai_model_choices :: proc(s:^Session,provider:Ai_Provider,value:json.Value) {
    m:=s.ai
    options,_:=acp.at(value,"configOptions").(json.Array)
    for option in options {
        if acp.text(acp.at(option,"category"))!="model" {continue}
        m.model_counts[provider]=0
        choices,_:=acp.at(option,"options").(json.Array)
        for choice in choices {
            grouped,is_group:=acp.at(choice,"options").(json.Array)
            if !is_group {grouped=make(json.Array,0,1,context.temp_allocator);append(&grouped,choice)}
            for item in grouped {
                if m.model_counts[provider]>=len(m.models[provider]) {break}
                if m.connections[provider].agent==.Codex && !ai_codex_model_supported(acp.text(acp.at(item,"value"))) {continue}
                target:=&m.models[provider][m.model_counts[provider]]
                base.text_set(target.value[:],acp.text(acp.at(item,"value")))
                base.text_set(target.name[:],acp.text(acp.at(item,"name")))
                m.model_counts[provider]+=1
            }
        }
    }
}

ai_permission_receive :: proc(s:^Session,worker:^Ai_Worker,event:acp.Event) {
    m:=s.ai
    if m.permission_count==len(m.permissions) {_=acp.permission(&worker.client,event.request_id,"",true);return}
    p:=&m.permissions[m.permission_count];p^={worker=int((uintptr(worker)-uintptr(&m.workers[0]))/size_of(Ai_Worker))};m.permission_count+=1
    base.text_set(p.request[:],event.request_id)
    base.text_set(p.title[:],acp.text(acp.at(event.value,"toolCall","title")))
    options,_:=acp.at(event.value,"options").(json.Array)
    for option in options {
        if p.count==len(p.ids) {break}
        base.text_set(p.ids[p.count][:],acp.text(acp.at(option,"optionId")))
        base.text_set(p.names[p.count][:],acp.text(acp.at(option,"name")))
        p.count+=1
    }
    // It is answered in the thread of its session: out of sight, a toast says it waits.
    if task:=ai_task_find(m,worker.task);task!=nil && (m.selected!=task.id || s.gui==nil || s.gui.layout.library_tab!=.Ai || !s.gui.layout.left_open) {
        notify(s,fmt.tprintf("%s asks for permission",ai_chat_title(base.text_get(task.title[:]))))
    }
}

// What a Codex turn may do is fixed, so it is not asked of the user: calling
// the tools of the editor, the only MCP server it has, is allowed, and the
// sandbox already lets it write inside the project. Anything else it asks for
// (a command outside the sandbox, a file outside the project) is declined,
// and its details say so.
@(private)
ai_permission_policy :: proc(s:^Session,worker:^Ai_Worker,task:^Ai_Task,event:acp.Event) {
    if ai_permission_deletes(event.value,base.text_get(worker.tool[:])) {ai_permission_receive(s,worker,event);return}
    option,allow:=ai_permission_choice(event.value)
    _=acp.permission(&worker.client,event.request_id,option,option=="")
    if !allow {ai_tool_note(s,task,"permission","","",fmt.tprintf("declined: %s",acp.text(acp.at(event.value,"toolCall","title"))),0)}
}

// The option that answers a request for permission by that policy; empty
// cancels it when the request offers none of that kind.
@(private)
ai_permission_choice :: proc(request:json.Value) -> (option:string,allow:bool) {
    flag,is_flag:=acp.at(request,"_meta","is_mcp_tool_approval").(json.Boolean)
    allow=is_flag && bool(flag)
    wanted:=allow?"allow_once":"reject_once"
    options,_:=acp.at(request,"options").(json.Array)
    for candidate in options {
        if acp.text(acp.at(candidate,"kind"))==wanted {return acp.text(acp.at(candidate,"optionId")),allow}
    }
    return "",allow
}

// Answers as cancelled what the agent of a worker still asks: a turn that is
// stopped does not wait on a question nobody will answer.
@(private)
ai_permissions_cancel :: proc(m:^Ai,worker:^Ai_Worker) {
    index:=int((uintptr(worker)-uintptr(&m.workers[0]))/size_of(Ai_Worker))
    for i:=m.permission_count-1;i>=0;i-=1 {
        if m.permissions[i].worker!=index {continue}
        _=acp.permission(&worker.client,base.text_get(m.permissions[i].request[:]),"",true)
        copy(m.permissions[i:m.permission_count-1],m.permissions[i+1:m.permission_count]);m.permission_count-=1
    }
}

ai_permission_answer :: proc(s:^Session,index:int,option:string,cancel:bool) -> string {
    m:=s.ai
    if index<0 || index>=m.permission_count {return "There is no pending permission"}
    p:=&m.permissions[index]
    worker:=&m.workers[p.worker]
    if !cancel {
        found:=false
        for &id in p.ids[:p.count] {if base.text_get(id[:])==option {found=true;break}}
        if !found {return "Unknown permission option"}
    }
    if acp.permission(&worker.client,base.text_get(p.request[:]),option,cancel)!=.None {return "The permission reply could not be sent"}
    copy(m.permissions[index:m.permission_count-1],m.permissions[index+1:m.permission_count])
    m.permission_count-=1
    return ""
}

ai_acp_event :: proc(user:rawptr,event:acp.Event) {
    callback:=cast(^Ai_Callback)user
    s:=callback.session;worker:=callback.worker;m:=s.ai;task:=ai_task_find(m,worker.task)
    login:=m.login && worker==&m.workers[0]
    probe:=m.probe.active && worker==&m.workers[0]
    switch event.kind {
    case .Initialized:
        ai_agent_announced(s,worker.provider,&worker.client,event.value)
        if probe {ai_probe_end(s,"");return}
        if login {
            methods,_:=acp.at(event.value,"authMethods").(json.Array)
            // Only an agent added by its command signs in through ACP, with the
            // first method it offers.
            chosen:=len(methods)>0?acp.text(acp.at(methods[0],"id")):""
            if chosen=="" || acp.authenticate(&worker.client,chosen)!=.None {m.login=false;m.connection_ui.busy=false;base.text_set(m.connection_ui.error[:],"No account sign-in method is available");acp.stop(&worker.client,s.app.platform)}
        } else if task!=nil {ai_open_task_session(s,worker,task)}
    case .Authenticated:
        if !login {if task!=nil {ai_open_task_session(s,worker,task)};return}
        previous:=m.connections[worker.provider]
        m.connections[worker.provider].configured=true
        if !ai_settings_save(s) {m.connections[worker.provider]=previous;base.text_set(m.connection_ui.error[:],"The connection settings could not be saved")}
        m.login=false;m.connection_ui.busy=false;m.connection_ui.screen=.Overview
        acp.stop(&worker.client,s.app.platform)
    case .Config_Options:ai_model_choices(s,worker.provider,event.value)
    case .Session_Ready:if task!=nil {ai_send_task_prompt(s,worker,task)}
    case .Update:
        native:=acp.session_id(&worker.client)
        ours:=task!=nil && !event.replay && native!="" && acp.text(acp.at(event.value,"sessionId"))==native
        update:=acp.at(event.value,"update")
        kind:=acp.text(acp.at(update,"sessionUpdate"))
        if kind=="session_info_update" {
            if ours {ai_task_agent_error(s,task,acp.at(update,"_meta","codex","error"),platform.clock_seconds())}
            ai_session_title_update(s,worker,event.value);return
        }
        if !ours {return}
        task.heard,task.silent=platform.clock_seconds(),false
        switch kind {
        case "usage_update":
            usage:=&task.conversation.usage
            usage.context_used,usage.context_size=i64(ai_json_number(acp.at(update,"used"))),i64(ai_json_number(acp.at(update,"size")))
            if cost:=ai_json_number(acp.at(update,"cost","amount"));cost>0 {usage.cost=cost}
        case "agent_message_chunk":
        case "tool_call","tool_call_update":
            task.stream_open=false
            if title:=acp.text(acp.at(update,"title"));title!="" {base.text_set(worker.tool[:],title)}
            ai_tool_call_receive(s,worker,task,update)
        case "plan":ai_plan_receive(task,update)
        case "compaction_update":ai_compaction_receive(s,task,acp.text(acp.at(update,"status")))
        case:
        }
    case .Permission:
        native:=acp.session_id(&worker.client)
        if task==nil || task.stop || native=="" || acp.text(acp.at(event.value,"sessionId"))!=native {_=acp.permission(&worker.client,event.request_id,"",true);return}
        if m.connections[worker.provider].agent==.Codex {ai_permission_policy(s,worker,task,event);return}
        ai_permission_receive(s,worker,event)
    case .Prompt_Done:
        if task!=nil {
            // Totals of the session: the agent counts them across its turns.
            if usage:=acp.at(event.value,"usage");usage!=nil {
                u:=&task.conversation.usage
                u.input,u.output=i64(ai_json_number(acp.at(usage,"inputTokens"))),i64(ai_json_number(acp.at(usage,"outputTokens")))
                u.cache_read,u.cache_write=i64(ai_json_number(acp.at(usage,"cachedReadTokens"))),i64(ai_json_number(acp.at(usage,"cachedWriteTokens")))
                u.total=i64(ai_json_number(acp.at(usage,"totalTokens")))
            }
            if task.compact==.None && !task.stop && !task.finish_called && !task.system_turn {ai_task_fail(task,"The agent completed without calling finish");ai_task_end(s,m,task,1)}
            else {ai_task_end(s,m,task,0)}
        }
    case .Error:
        if task!=nil {
            ai_task_persist(s,task)
            if said:=base.text_get(task.said[:]);said!="" {ai_task_fail(task,"Connection error: %s. The agent printed: %s",event.text,said)} else {ai_task_fail(task,"Connection error: %s",event.text)}
            ai_task_end(s,m,task,1);acp.stop(&worker.client,s.app.platform)
        }
        if probe {ai_probe_end(s,event.text)}
        if login {m.login=false;m.connection_ui.busy=false;base.text_set(m.connection_ui.error[:],event.text);m.connection_ui.screen=.Auth;acp.stop(&worker.client,s.app.platform)}
    case .Stderr:
        if login || probe {base.text_set(m.connection_ui.log[:],event.text)}
        if task!=nil {ai_said_keep(task,event.text)}
    case .Exited:
        if probe {ai_probe_end(s,fmt.tprintf("it ended with %d before answering",event.code))}
        if task!=nil {
            if said:=base.text_get(task.said[:]);said!="" {ai_task_fail(task,"The agent exited before completing its response. It printed: %s",said)} else {ai_task_fail(task,"The agent exited before completing its response")}
            ai_task_end(s,m,task,1)
        }
    case .Notice:
    case .Steer_Done:ai_steer_done(s,worker,event)
    }
}

// The plan the agent reports replaces the one before; a status it does not
// name is pending, and entries past the capacity are left out.
ai_plan_receive :: proc(task:^Ai_Task,update:json.Value) {
    entries,_:=acp.at(update,"entries").(json.Array)
    task.plan_count=0
    for entry in entries {
        if task.plan_count==AI_PLAN_ENTRIES {break}
        text:=strings.trim_space(acp.text(acp.at(entry,"content")))
        if text=="" {continue}
        item:=&task.plan[task.plan_count]
        item^={}
        // The first line, cut where a character starts.
        if split:=strings.index_byte(text,'\n');split>=0 {text=strings.trim_space(text[:split])}
        count:=min(len(text),len(item.text)-1)
        for count>0 && count<len(text) && (text[count]&0xc0)==0x80 {count-=1}
        copy(item.text[:],text[:count])
        switch acp.text(acp.at(entry,"status")) {
        case "in_progress":item.status=.In_Progress
        case "completed":item.status=.Completed
        }
        task.plan_count+=1
    }
}

@(private)
ai_json_number :: proc(value:json.Value) -> f64 {
    #partial switch v in value {
    case json.Integer: return f64(v)
    case json.Float: return f64(v)
    }
    return 0
}

// Says once in the transcript that the agent has not answered its prompt
// for a while, so a turn that waits on nothing does not look like work.
@(private)
ai_task_silence :: proc(s:^Session,task:^Ai_Task,now:f64) {
    if task.state!=.Running || task.stop || task.silent || task.heard==0 || now-task.heard<AI_SILENT_SECONDS {return}
    task.silent=true
    ai_task_note(s,task,"The agent has not answered for %d s; Stop ends the turn",int(now-task.heard))
}

// Codex reports its retries and errors in the session's info, not in the
// turn's messages, so a turn that reconnects shows nothing without this note.
@(private)
ai_task_agent_error :: proc(s:^Session,task:^Ai_Task,error:json.Value,now:f64) {
    message:=strings.trim_space(acp.text(acp.at(error,"message")))
    if message=="" {return}
    task.heard,task.silent=now,false
    details:=strings.trim_space(acp.text(acp.at(error,"additionalDetails")))
    if details!="" && details!=message {ai_task_note(s,task,"The agent reported: %s (%s)",message,details)} else {ai_task_note(s,task,"The agent reported: %s",message)}
}

// Keeps the last line the agent printed that has text: what a failure shows.
@(private)
ai_said_keep :: proc(task:^Ai_Task,text:string) {
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        if line:=strings.trim_space(line);line!="" {base.text_set(task.said[:],line[:min(len(line),len(task.said)-1)])}
    }
}

ai_running_count :: proc "contextless" (m:^Ai) -> int {
    count:=0
    for &worker in m.workers {if worker.task!=0 {count+=1}}
    return count
}

ai_task_worker :: proc(m:^Ai,id:int) -> ^Ai_Worker {
    if id==0 {return nil}
    for &worker in m.workers {if worker.task==id {return &worker}}
    return nil
}

ai_task_busy :: proc(m:^Ai,id:int) -> bool {
    task:=ai_task_find(m,id)
    return task!=nil && !ai_task_finished(task)
}

ai_process_running :: proc(m:^Ai) -> bool {
    for &worker in m.workers {if worker.client.process!=0 {return true}}
    return false
}

ai_workers_stop :: proc(s:^Session,provider:Ai_Provider,all:bool=false) {
    for &worker in s.ai.workers {
        if !all && worker.provider!=provider {continue}
        if task:=ai_task_find(s.ai,worker.task);task!=nil {ai_task_cancel(s,s.ai,task)}
        if worker.client.process!=0 {acp.stop(&worker.client,s.app.platform)}
    }
}

ai_worker_take :: proc(s:^Session,task:^Ai_Task,provider:Ai_Provider) -> ^Ai_Worker {
    m:=s.ai
    if task.conversation.kind==.Agent && ai_subagent_workers(m)>=AI_WORKER_CAPACITY-1 {return nil}
    for &worker in m.workers {
        if worker.task==0 && worker.last_task==task.id && worker.provider==provider && (worker.client.process==0 || worker.client.phase==.Ready) {return &worker}
    }
    for &worker in m.workers {
        if worker.task==0 && worker.client.process==0 {return &worker}
    }
    for &worker in m.workers {
        if worker.task!=0 || worker.client.phase!=.Ready {continue}
        if worker.provider==provider {return &worker}
        acp.stop(&worker.client,s.app.platform)
    }
    return nil
}

ai_task_start :: proc(s:^Session,m:^Ai,task:^Ai_Task) {
    provider,ok:=ai_provider_find(m,base.text_get(task.agent[:]))
    if !ok {ai_task_fail(task,"The agent of this chat is no longer in AI connections");ai_task_dirty(task);ai_task_persist(s,task);ai_task_settle(s,m,task);return}
    connection:=&m.connections[provider]
    if connection.agent==.Codex && !ai_codex_model_supported(string(task.conversation.model[:task.conversation.model_len])) {ai_task_fail(task,"Choose GPT-6 Luna, GPT-6.1 Sol or GPT-6 Astra");ai_task_dirty(task);ai_task_persist(s,task);ai_task_settle(s,m,task);return}
    if !connection.configured {ai_task_fail(task,"Connect the agent in AI connections first");ai_task_dirty(task);ai_task_persist(s,task);ai_task_settle(s,m,task);return}
    worker:=ai_worker_take(s,task,provider)
    if worker==nil {return}
    task.state=.Running;task.started=time.tick_now();task.state_before=edits_state(s.edits)
    task.plan_count=0
    task.sources,task.shaders=code_fingerprint(s.project_root),shaders_fingerprint(s.project_root);worker.task,worker.last_task=task.id,task.id;worker.cancel_deadline=0
    ai_code_begin(s,m,task)
    m.scene_serial+=1
    if message:=ai_start_client(s,worker,provider);message!="" {ai_task_fail(task,"%s",message);ai_task_end(s,m,task,1);return}
    task.pid=platform.process_id(s.app.platform,worker.client.process)
    if worker.client.phase==.Ready || worker.client.phase==.Initialized {ai_open_task_session(s,worker,task)}
    ai_task_dirty(task);ai_task_persist(s,task)
}

ai_task_end :: proc(s:^Session,m:^Ai,task:^Ai_Task,exit_code:int) {
    // The run a turn kept alive ends with it: no agent is playing it anymore.
    ai_run_release(s,task)
    if worker:=ai_task_worker(m,task.id);worker!=nil {
        index:=int((uintptr(worker)-uintptr(&m.workers[0]))/size_of(Ai_Worker))
        if exit_code!=0 {
            #partial switch worker.client.phase {
            case .Initialized,.Opening,.Configuring,.Failed:acp.stop(&worker.client,s.app.platform)
            }
        }
        worker.task=0;worker.idle_since=platform.clock_seconds();worker.cancel_deadline=0
        for i:=m.permission_count-1;i>=0;i-=1 {
            if m.permissions[i].worker!=index {continue}
            copy(m.permissions[i:m.permission_count-1],m.permissions[i+1:m.permission_count]);m.permission_count-=1
        }
    }
    task.stream_open=false
    if task.compact!=.None {ai_compact_end(s,m,task,exit_code);return}
    task.exit_code=exit_code;task.seconds=f32(time.duration_seconds(time.tick_since(task.started)))
    task.conversation.seconds+=task.seconds
    task.state_after=edits_state(s.edits)
    if task.stop {task.state=.Cancelled;ai_task_note(s,task,"Cancelled")} else if exit_code!=0 {task.state=.Failed} else {task.state=.Done}
    // Shaders the agent wrote with its own tools are published like those of the API; code needs a Build.
    shaders_changed:=shaders_fingerprint(s.project_root)!=task.shaders
    if shaders_changed && s.build!=nil {programs_publish_request(s)}
    task.needs_build=code_fingerprint(s.project_root)!=task.sources
    task.files_changed=!ai_code_end(s,m,task)
    m.scene_serial+=1
    ai_task_dirty(task);ai_task_persist(s,task)
    ai_memory_scan(s)
    ai_task_settle(s,m,task)
}

ai_task_poll :: proc(s:^Session,m:^Ai) {
    now:=platform.clock_seconds()
    for &worker in m.workers {
        if !worker.created {continue}
        callback:=Ai_Callback{session=s,worker=&worker}
        acp.poll(&worker.client,s.app.platform,ai_acp_event,&callback)
        ai_cancel_expire(s,m,&worker,now)
        if task:=ai_task_find(m,worker.task);task!=nil {ai_task_silence(s,task,now)}
        if worker.task==0 && !(m.login && &worker==&m.workers[0]) && worker.client.process!=0 && worker.client.phase==.Ready && worker.idle_since>0 && now-worker.idle_since>=AI_IDLE_SECONDS {acp.stop(&worker.client,s.app.platform)}
    }
    ai_login_poll(s)
    ai_install_poll(s)
    if now-m.last_flush>=0.2 {
        for &task in m.tasks[:m.task_count] {if task.dirty {ai_task_persist(s,&task)}}
        m.last_flush=now
    }
}

ai_queue_advance :: proc(s:^Session,m:^Ai) {
    if m.login || m.probe.active || m.installer!=0 || m.connection_pending.kind!=.None {return}
    for &task in m.tasks[:m.task_count] {
        if ai_running_count(m)>=AI_WORKER_CAPACITY {break}
        if task.state==.Queued && ai_task_current(s,&task) {ai_task_start(s,m,&task)}
    }
}

ai_task_cancel :: proc(s:^Session,m:^Ai,task:^Ai_Task) -> bool {
    // An agent outside the editor is not stopped from here: its turn ends.
    if ai_task_external(task) {return ai_external_end(s,task)}
    if task.state==.Queued {task.state=.Cancelled;ai_note(task,"Cancelled");m.scene_serial+=1;ai_task_dirty(task);ai_task_persist(s,task);ai_task_settle(s,m,task);return true}
    if task.state!=.Running {return false}
    task.stop=true
    worker:=ai_task_worker(m,task.id)
    if worker!=nil && worker.client.phase==.Prompting && acp.cancel(&worker.client)==.None {
        ai_permissions_cancel(m,worker)
        if worker.cancel_deadline==0 {worker.cancel_deadline=platform.clock_seconds()+AI_CANCEL_SECONDS}
    } else {
        if worker!=nil {acp.stop(&worker.client,s.app.platform)}
        ai_task_end(s,m,task,1)
    }
    return true
}

@(private)
ai_cancel_expire :: proc(s:^Session,m:^Ai,worker:^Ai_Worker,now:f64) -> bool {
    if worker.cancel_deadline==0 || now<worker.cancel_deadline {return false}
    task:=ai_task_find(m,worker.task)
    worker.cancel_deadline=0
    if task==nil || !task.stop {return false}
    if worker.client.process!=0 {_=platform.process_terminate(s.app.platform,worker.client.process,true)}
    acp.stop(&worker.client,s.app.platform)
    ai_task_end(s,m,task,1)
    return true
}

ai_task_retry :: proc(s:^Session,m:^Ai,task:^Ai_Task) -> string {
    if !ai_task_finished(task) || !ai_task_current(s,task) {return "The task is not ready to retry"}
    if ai_task_external(task) {return "The turn of an agent outside the editor is asked again from that agent"}
    if m.pending || ai_running_count(m)>=AI_WORKER_CAPACITY || m.login || m.installer!=0 {return "Wait for an agent to finish"}
    if !task.review_finished {if message:=ai_task_revert(s,m,task);message!="" {return message}}
    prompt,error:=os.read_entire_file(ai_task_path(s,task,AI_FILE_MESSAGE),context.temp_allocator)
    if error!=nil || len(prompt)==0 {return "The original message is unavailable"}
    m.prompt_length=copy(m.prompt[:AI_MESSAGE_BYTES-1],prompt)
    ai_task_select(m,task)
    m.region,m.has_region=task.region,task.region.w>0 && task.region.h>0
    base.text_set(m.pending_model[:],string(task.conversation.model[:task.conversation.model_len]))
    base.text_set(m.pending_effort[:],string(task.conversation.effort[:task.conversation.effort_len]))
    m.pending=true;m.submit_frame=s.frame;m.focus=true
    return ""
}

ai_destroy :: proc(s:^Session) {
    m:=s.ai
    m.closing=true
    m.connection_pending={}
    if m.login_process!=0 {platform.process_release(s.app.platform,m.login_process);m.login_process=0;m.login=false}
    if m.installer!=0 {
        ai_install_cancel(s)
        until:=platform.clock_seconds()+3
        for m.installer!=0 && platform.clock_seconds()<until {ai_install_poll(s);if m.installer!=0 {time.sleep(10*time.Millisecond)}}
        if m.installer!=0 {platform.process_release(s.app.platform,m.installer)}
    }
    for &task in m.tasks[:m.task_count] {
        ai_task_persist(s,&task)
        host.app_png_write_wait(s.app,&task.image_write)
        for &write in task.reference_writes {host.app_png_write_wait(s.app,&write)}
    }
    for &worker in m.workers {if worker.created {acp.stop(&worker.client,s.app.platform)}}
    until:=platform.clock_seconds()+4
    for ai_process_running(m) && platform.clock_seconds()<until {ai_task_poll(s,m);if ai_process_running(m) {time.sleep(10*time.Millisecond)}}
    for &worker in m.workers {if worker.created {acp.destroy(&worker.client,s.app.platform);worker.created=false};worker.task=0}
    for &task in m.tasks[:m.task_count] {ai_review_free(&task.review);ai_steers_free(&task)}
    ai_code_free(m)
    delete(m.marks);m.marks=nil
    delete(m.asset_marks);m.asset_marks=nil
    ai_store.close(&m.store)
    m.installer=0
}
