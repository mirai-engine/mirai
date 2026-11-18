package editor

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:editor/acp"
import "mirai:editor/ai_store"
import "mirai:platform"
import "mirai:std/base"

// What goes to the agent besides its message, and what lets a chat go on when
// its native session does not: the delta of a turn, the compaction of a
// context and the handoff to a new one, built from the database without
// calling a model.

AI_COMPACT_NOTES_AT :: f64(0.75)  // of the context window: the delta asks to save what matters before it is summarized
AI_COMPACTED_NOTE :: "Context compacted"
AI_REOPENED_NOTE :: "Editor reopened"
AI_INTERRUPTED_NOTE :: "Interrupted: the editor closed while this agent worked"
AI_HANDOFF_HEADER :: "Handoff:"
AI_HANDOFF_NOTES_BYTES :: 8<<10
AI_HANDOFF_MESSAGE_BYTES :: 16<<10
AI_HANDOFF_LINES :: 256  // of the chat that are looked at, before the bytes cut them
AI_HANDOFF_AGENTS :: 16
AI_COMPACT_COMMAND :: "/compact"

AI_META_RESUME_NATIVE :: "resume_native"           // a Build restarts the editor: the main chat keeps its native session, once
AI_META_WORKING_AGENTS :: "working_agents"         // ids of the subagents that have not ended
AI_META_INTERRUPTED_AGENTS :: "interrupted_agents" // ids of those the editor closed on, until a handoff says it
AI_META_CONTEXT_SINCE :: "context_since_%d"        // of a conversation: when its context last took a turn, in milliseconds

// A context of the agent is over: the next turn opens a new native session.
ai_context_drop :: proc(task:^Ai_Task) {
    c:=&task.conversation
    c.native_session_len=0
    c.usage.context_used,c.usage.context_size=0,0
    task.stable_native,task.notes_native={},{}
    ai_task_dirty(task)
}

@(private)
ai_context_filling :: proc "contextless" (task:^Ai_Task) -> bool {
    usage:=&task.conversation.usage
    return usage.context_size>0 && f64(usage.context_used)/f64(usage.context_size)>=AI_COMPACT_NOTES_AT
}

// A native session that was restored already holds the stable instructions,
// and it has asked for notes if it is that full.
@(private)
ai_context_restored :: proc(task:^Ai_Task) {
    c:=&task.conversation
    if c.native_session_len==0 {return}
    native:=string(c.native_session[:c.native_session_len])
    base.text_set(task.stable_native[:],native)
    if ai_context_filling(task) {base.text_set(task.notes_native[:],native)}
}

// The sequence of the first line of the turn, from its name.
@(private)
ai_task_turn_sequence :: proc(task:^Ai_Task) -> i64 {
    name:=base.text_get(task.name[:])
    split:=strings.last_index_byte(name,'-')
    if split<0 {return -1}
    sequence,ok:=strconv.parse_i64(name[split+1:],10)
    return ok?sequence:-1
}

@(private)
ai_delta_listed_write :: proc(s:^Session,task:^Ai_Task,b:^strings.Builder) {
    if s.ai.store.db==nil {return}
    ai_pins_delta_write(s,b)
    ai_annotations_delta_write(s,string(task.conversation.document[:task.conversation.document_len]),b)
}

// All the delta of a turn: what the message was sent with, what the database
// holds as it starts, and what only the start of the turn knows.
ai_delta_build :: proc(s:^Session,task:^Ai_Task,turn,handoff:string,deliveries:[]ai_store.Delivery,remind:bool) -> string {
    m:=s.ai
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,turn)
    ai_delta_listed_write(s,task,&b)
    if task.conversation.kind==.Main {
        names:=AI_STATE_NAMES
        listed:=false
        for &other in m.tasks[:m.task_count] {
            if other.conversation.kind!=.Agent || ai_task_finished(&other) {continue}
            if !listed {strings.write_string(&b,"- Your subagents still working, id | title | state | document:\n");listed=true}
            fmt.sbprintf(&b,"  - %d | %s | %s | %s\n",other.id,base.text_get(other.title[:]),names[other.state],string(other.conversation.document[:other.conversation.document_len]))
        }
    }
    if remind {
        fmt.sbprintf(&b,"- This context is nearly full and will be summarized soon. Before that, save what must not be lost: decisions and conventions with `%s`, the work under way with `%s`.\n",ai_tool_name("memory.save"),ai_tool_name("chat.note"))
    }
    if len(deliveries)>0 {fmt.sbprintf(&b,"- What waited for this turn, from your subagents and from the user:\n%s\n",ai_deliveries_text(deliveries))}
    if handoff!="" {fmt.sbprintf(&b,"\n%s\n",handoff)}
    return strings.to_string(b)
}

@(private)
ai_ids_parse :: proc(text:string,allocator:=context.temp_allocator) -> []int {
    ids:=make([dynamic]int,allocator)
    for part in strings.split(text,",",context.temp_allocator) {
        if id,ok:=strconv.parse_int(part,10);ok && id>0 {append(&ids,id)}
    }
    return ids[:]
}

// The subagents of a chat that the context before this one did not see end,
// those the editor closed on first.
@(private)
ai_handoff_agents_write :: proc(m:^Ai,task:^Ai_Task,b:^strings.Builder) {
    interrupted,_:=ai_store.meta_get(&m.store,AI_META_INTERRUPTED_AGENTS)
    since_text,_:=ai_store.meta_get(&m.store,fmt.tprintf(AI_META_CONTEXT_SINCE,task.conversation.id))
    since,_:=strconv.parse_i64(since_text,10)
    names:=AI_STATE_NAMES
    listed:=false
    head :: proc(b:^strings.Builder,listed:^bool) {
        if !listed^ {strings.write_string(b,"Subagents since then:\n");listed^=true}
    }
    ids:=ai_ids_parse(interrupted)
    for id in ids {
        if other:=ai_task_find(m,id);other!=nil && other.state!=.Interrupted {continue}
        saved:=ai_store.find(&m.store,u64(id))
        if saved==nil || saved.parent!=task.conversation.id {continue}
        head(b,&listed)
        fmt.sbprintf(b,"- %d, %q: interrupted when the editor closed, on %s; it does not go on unless you send it agent.message\n",id,string(saved.title[:saved.title_len]),string(saved.document[:saved.document_len]))
    }
    conversations:[AI_HANDOFF_AGENTS]ai_store.Conversation
    count,_:=ai_store.list(&m.store,conversations[:],kinds={.Agent},parent=task.conversation.id)
    for &c in conversations[:count] {
        if c.updated_at<since {continue}
        other:=ai_task_find(m,int(c.id))
        known:=false
        for id in ids {if id==int(c.id) {known=true;break}}
        if known || other!=nil && (!ai_task_finished(other) || other.state==.Interrupted) {continue}
        head(b,&listed)
        fmt.sbprintf(b,"- %d, %q: %s\n",c.id,string(c.title[:c.title_len]),other!=nil?names[other.state]:names[.Done])
    }
}

// What a new context of a chat has to know: its notes, its latest messages,
// its subagents and what waits for the review of the user, all from the
// database. Empty when there is nothing. before: the sequence of the turn it
// goes with, whose message is not repeated.
ai_handoff_build :: proc(s:^Session,task:^Ai_Task,before:i64) -> string {
    m:=s.ai
    if m.store.db==nil {return ""}
    c:=&task.conversation
    b:=strings.builder_make(context.temp_allocator)
    notes,_:=ai_store.note_get(&m.store,c.id)
    if notes=strings.trim_space(notes);notes!="" {
        fmt.sbprintf(&b,"Notes of this chat:\n%s\n",ai_utf8_cut(notes,AI_HANDOFF_NOTES_BYTES))
    }
    lines:=make([]ai_store.Stored_Line,AI_HANDOFF_LINES,context.temp_allocator)
    count,_:=ai_store.page(&m.store,c.id,before,lines)
    first,used:=count,0
    for first>0 {
        line:=&lines[first-1]
        if line.kind==.Prompt || line.kind==.Output || line.kind==.Report {
            if used+len(line.text)+1>AI_HANDOFF_MESSAGE_BYTES {break}
            used+=len(line.text)+1
        }
        first-=1
    }
    if used>0 {
        fmt.sbprintf(&b,"Latest messages (%s with id %d reads the rest):\n",ai_tool_name("ai.history"),c.id)
        previous:ai_store.Line_Kind=.Note
        for &line in lines[first:count] {
            if line.kind==.Report {fmt.sbprintf(&b,"[subagent %s ended a turn]\n",line.text);previous=.Report;continue}
            if line.kind!=.Prompt && line.kind!=.Output {continue}
            if line.kind!=previous {strings.write_string(&b,line.kind==.Prompt?"[user]\n":"[agent]\n")}
            previous=line.kind
            strings.write_string(&b,line.text)
            strings.write_byte(&b,'\n')
        }
    }
    if c.kind==.Main {ai_handoff_agents_write(m,task,&b)}
    listed:=false
    for &other in m.tasks[:m.task_count] {
        if other.id!=task.id && c.kind!=.Main {continue}
        if !other.review.pending {continue}
        if !listed {strings.write_string(&b,"Changes the user has not reviewed yet:\n");listed=true}
        fmt.sbprintf(&b,"- %d, %q: %d changes\n",other.id,base.text_get(other.title[:]),ai_review_count(&other))
    }
    if strings.builder_len(b)==0 {return ""}
    return fmt.tprintf("%s this chat continues from a context you no longer have. What it left:\n%s",AI_HANDOFF_HEADER,strings.to_string(b))
}

// Keeps which subagents have not ended, so that the next start of the editor
// knows which ones it closed on. Written when a turn is created or ends.
ai_working_agents_save :: proc(s:^Session,m:^Ai) {
    if m.closing || m.store.db==nil {return}
    b:=strings.builder_make(context.temp_allocator)
    for &task in m.tasks[:m.task_count] {
        if task.conversation.kind==.Agent && !ai_task_finished(&task) {fmt.sbprintf(&b,"%d,",task.id)}
    }
    if message:=ai_store.meta_set(&m.store,AI_META_WORKING_AGENTS,strings.to_string(b));message!="" {notify(s,message)}
}

// The main chat comes back with a clean context, unless a Build restarted the editor.
@(private)
ai_main_reopen :: proc(s:^Session,m:^Ai,task:^Ai_Task) {
    resume,problem:=ai_store.meta_get(&m.store,AI_META_RESUME_NATIVE)
    if problem!="" {notify(s,problem)}
    if resume!="" {
        if message:=ai_store.meta_set(&m.store,AI_META_RESUME_NATIVE,"");message!="" {notify(s,message)}
        return
    }
    if task.conversation.native_session_len==0 {return}
    ai_context_drop(task)
    ai_task_line_add(s,task,AI_REOPENED_NOTE,.Divider)
    ai_task_persist(s,task)
}

// The subagents the editor closed on stay interrupted until someone writes to
// them: nothing starts them by itself.
@(private)
ai_agents_interrupted_restore :: proc(s:^Session,m:^Ai) {
    working,_:=ai_store.meta_get(&m.store,AI_META_WORKING_AGENTS)
    earlier,_:=ai_store.meta_get(&m.store,AI_META_INTERRUPTED_AGENTS)
    if working=="" && earlier=="" {return}
    mark :: proc(s:^Session,m:^Ai,id:int,noted:bool) {
        saved:=ai_store.find(&m.store,u64(id))
        if saved==nil || saved.kind!=.Agent {return}
        conversation:=saved^
        task:=ai_conversation_restore(s,&conversation)
        if task==nil {return}
        task.state=.Interrupted
        if noted {
            ai_task_note(s,task,AI_INTERRUPTED_NOTE)
            ai_task_persist(s,task)
        }
    }
    for id in ai_ids_parse(earlier) {mark(s,m,id,false)}
    for id in ai_ids_parse(working) {mark(s,m,id,true)}
    if message:=ai_store.meta_set(&m.store,AI_META_INTERRUPTED_AGENTS,strings.concatenate({earlier,working},context.temp_allocator));message!="" {notify(s,message)}
    if message:=ai_store.meta_set(&m.store,AI_META_WORKING_AGENTS,"");message!="" {notify(s,message)}
}

// A Build is about to restart the editor: the main chat goes on where it was.
ai_resume_native_mark :: proc(s:^Session) {
    if s.ai==nil || s.ai.store.db==nil || s.ai.main==0 {return}
    if message:=ai_store.meta_set(&s.ai.store,AI_META_RESUME_NATIVE,"1");message!="" {notify(s,message)}
}

// The stable block has to be sent again: the context lost it, or it changed.
@(private)
ai_context_compacted :: proc(s:^Session,task:^Ai_Task) {
    task.stable_native={}
    ai_task_note(s,task,AI_COMPACTED_NOTE)
    ai_task_persist(s,task)
}

// The worker that holds the session of a chat that does not work, if its agent has /compact.
@(private)
ai_compact_worker :: proc(m:^Ai,task:^Ai_Task) -> ^Ai_Worker {
    c:=&task.conversation
    for &worker in m.workers {
        if worker.task!=0 || worker.last_task!=task.id || worker.client.phase!=.Ready || !worker.client.compact_command {continue}
        if acp.session_id(&worker.client)==string(c.native_session[:c.native_session_len]) {return &worker}
    }
    return nil
}

// Summarizes the context of a chat that does not work: with the command of its
// agent when it has one in the worker that holds the session, and otherwise
// with a new native session and a handoff on its next turn. Gives why it cannot.
ai_chat_compact :: proc(s:^Session,task:^Ai_Task) -> string {
    m:=s.ai
    if task==nil {return "There is no chat to compact"}
    if task.conversation.kind==.Archived || ai_task_external(task) {return "This chat has no context of the editor to compact"}
    if !ai_task_finished(task) {return "The agent is working: compact when it ends"}
    if task.conversation.native_session_len==0 {return "This chat has no context to compact yet"}
    if worker:=ai_compact_worker(m,task);worker!=nil {
        command:=[1]acp.Content{{kind=.Text,text=AI_COMPACT_COMMAND}}
        if acp.prompt(&worker.client,command[:])==.None {
            worker.task=task.id;worker.cancel_deadline=0
            task.compact=.Running
            task.compact_state=task.state
            task.state=.Running;task.stop=false
            task.started=time.tick_now()
            task.heard,task.silent=platform.clock_seconds(),false
            m.scene_serial+=1
            return ""
        }
    }
    ai_context_drop(task)
    ai_context_compacted(s,task)
    return ""
}

// The command ended: the chat is as it was, with its review untouched.
@(private)
ai_compact_end :: proc(s:^Session,m:^Ai,task:^Ai_Task,exit_code:int) {
    done:=task.compact==.Running && exit_code==0 && !task.stop
    task.compact=.None
    task.state=task.compact_state
    task.stop=false
    m.scene_serial+=1
    m.deliveries_due=true
    if done {ai_context_compacted(s,task)}
    ai_task_dirty(task);ai_task_persist(s,task)
}

// What the agent reports of a compaction. One that this editor asked for is
// said when its command ends, which also covers an agent that reports nothing.
@(private)
ai_compaction_receive :: proc(s:^Session,task:^Ai_Task,status:string) {
    switch status {
    case "completed":
        if task.compact==.None {ai_context_compacted(s,task)}
    case "failed","cancelled":
        if task.compact==.Running {task.compact=.Failed}
    }
}
