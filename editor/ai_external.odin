package editor

import "core:fmt"
import "core:strings"
import "core:time"
import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:platform"
import "mirai:std/base"

// An agent outside the editor (Claude Code, Codex or another MCP client) is
// told apart by the name it calls with (X-Mirai-Client): its calls are the
// turn of a chat of its own, which the panel shows like those of the agents
// of the editor, with its steps, its figure and its review. The turn ends
// when the agent says so (finish with its answer, or ai.turn_end, which the
// Stop hook of Claude Code in a project calls) or after AI_EXTERNAL_IDLE
// without calls. A call after that
// opens the turn again while its review waits, and starts the next turn of
// the chat once the user resolved it. Two instances of a client share it.

AI_EXTERNAL_PREFIX :: "external:" // of Ai_Task.agent and of the provider of its chat
AI_EXTERNAL_NAME :: 22            // bytes of the name of the client kept: with the prefix it fits in Ai_Task.agent
AI_EXTERNAL_IDLE :: 30            // seconds without calls that end its turn

ai_task_external :: proc(task:^Ai_Task) -> bool {return strings.has_prefix(base.text_get(task.agent[:]),AI_EXTERNAL_PREFIX)}

// The Ai_Task.agent of the turns of a client.
ai_external_agent :: proc(client:string) -> string {
    return fmt.tprintf("%s%s",AI_EXTERNAL_PREFIX,client[:min(len(client),AI_EXTERNAL_NAME)])
}

// The name of the client of an agent outside the editor, or "".
ai_external_client :: proc(agent:string) -> string {
    return agent[len(AI_EXTERNAL_PREFIX):] if strings.has_prefix(agent,AI_EXTERNAL_PREFIX) else ""
}

// How the chat of a client is called: the product its name says, or the name.
ai_external_title :: proc(client:string) -> string {
    switch {
    case strings.contains(client,"claude-code"): return "Claude Code"
    case strings.contains(client,"codex"):       return "Codex"
    case strings.contains(client,"claude"):      return "Claude"
    case strings.contains(client,"cursor"):      return "Cursor"
    }
    return client
}

// The mark of Claude or Codex for those clients; ok false for another.
ai_external_glyph :: proc(client:string) -> (icon:u8,ok:bool) {
    switch {
    case strings.contains(client,"claude"): return AI_GLYPH_CLAUDE,true
    case strings.contains(client,"codex"):  return AI_GLYPH_CODEX,true
    }
    return
}

// The name of the agent of a turn as the scene shows it: that of its
// connection, the chat of its client outside the editor, or its id.
ai_agent_name :: proc(m:^Ai,task:^Ai_Task) -> string {
    name:=base.text_get(task.agent[:])
    if provider,known:=ai_provider_find(m,name);known {return ai_connection_name(m,provider)}
    if client:=ai_external_client(name);client!="" {return ai_external_title(client)}
    return name
}

// Whether a call of a client outside the editor is part of its turn: not
// those that read or end the turns themselves.
ai_external_call :: proc(call:^api.Call) -> bool {
    return call.client_tag=="" && call.client_name!="" && !strings.has_prefix(call.method.name,"ai.") && call.method.name!="finish"
}

// The turn the calls of client belong to in the document of the editor:
// the open one, the one whose review waits (open again), or a new one, the
// next of its chat when it had one. nil when the editor keeps no chats.
ai_external_turn :: proc(s:^Session,client:string) -> ^Ai_Task {
    m:=s.ai
    if m==nil || !s.has_project || s.edits==nil {return nil}
    ai_initialize(s)
    if m.store.folder=="" {return nil}
    agent:=ai_external_agent(client)
    previous:^Ai_Task
    for &task in m.tasks[:m.task_count] {
        if base.text_get(task.agent[:])!=agent || !ai_task_current(s,&task) {continue}
        if previous==nil || task.id>previous.id {previous=&task}
    }
    now:=platform.clock_seconds()
    if previous!=nil && !previous.review_finished {
        if previous.state!=.Running {ai_external_begin(s,previous)}
        previous.heard=now
        return previous
    }
    task:=previous
    if task!=nil {
        task.stop=false;task.exit_code=0;task.pid=0;task.seconds=0
        task.question=.None;task.options_length=0
        task.state_before=0;task.state_after=0;task.step_count=0;task.undone=false;task.declined=false;task.needs_build=false;task.files_changed=false
        ai_review_free(&task.review)
        task.review_finished=false
        task.stream_open=false;task.finish_called=false;task.document_closed=false
    } else {
        id,error:=ai_store.next_id(&m.store)
        if error!="" || id>u64(max(int)) {return nil}
        task=ai_task_slot(m)
        if task==nil {return nil}
        task.id=int(id)
        task.conversation.id=id
        task.conversation.kind=.Archived
        task.conversation.created_at=time.time_to_unix_nano(time.now())/1_000_000
        title:=ai_external_title(agent[len(AI_EXTERNAL_PREFIX):])
        ai_store.conversation_set_text(task.conversation.title[:],&task.conversation.title_len,title)
        ai_store.conversation_set_text(task.conversation.document[:],&task.conversation.document_len,document_path(s.document))
        ai_store.conversation_set_text(task.conversation.provider[:],&task.conversation.provider_len,agent)
        base.text_set(task.title[:],title)
        base.text_set(task.agent[:],agent)
        task.icon=u8(task.id)%AI_AGENT_ICON_COUNT
        task.color_index=u8((task.id-1)%len(AGENT_COLORS))
        ai_task_glyph_set(m,task)
    }
    task.world=s.edit_world
    task.play=s.mode!=.Edit
    task.context_count=0
    task.anchor_set=false
    ai_scene_anchor(s,task)
    m.next_id=max(m.next_id,task.id)
    base.text_format(task.name[:],"%d-%d",task.id,task.transcript.dropped+task.transcript.count)
    ai_external_begin(s,task)
    task.heard=now
    ai_history_refresh(s)
    return task
}

// The turn of client that runs, or nil.
ai_external_running :: proc(s:^Session,client:string) -> ^Ai_Task {
    if s.ai==nil {return nil}
    agent:=ai_external_agent(client)
    for &task in s.ai.tasks[:s.ai.task_count] {
        if task.state==.Running && base.text_get(task.agent[:])==agent {return &task}
    }
    return nil
}

// The turn works: it was new, or a call came after it ended.
@(private="file")
ai_external_begin :: proc(s:^Session,task:^Ai_Task) {
    task.state=.Running
    task.started=time.tick_now()
    if task.state_before==0 {task.state_before=edits_state(s.edits)}
    s.ai.scene_serial+=1
    ai_task_dirty(task);ai_task_persist(s,task)
}

// Ends the turn of an agent outside the editor; what it changed waits for
// review, and a turn that changed nothing is done with. False when it was not running.
ai_external_end :: proc(s:^Session,task:^Ai_Task) -> bool {
    if task==nil || !ai_task_external(task) || task.state!=.Running {return false}
    task.state=.Done
    task.stop=false
    task.seconds=f32(time.duration_seconds(time.tick_since(task.started)))
    task.conversation.seconds+=task.seconds
    task.state_after=edits_state(s.edits)
    if ai_review_waiting(&task.review)==0 && !task.declined {task.review_finished=true}
    s.ai.scene_serial+=1
    ai_task_dirty(task);ai_task_persist(s,task)
    return true
}

// Ends the turns of the agents outside the editor that stopped calling.
ai_external_poll :: proc(s:^Session,m:^Ai) {
    now:=platform.clock_seconds()
    for &task in m.tasks[:m.task_count] {
        if task.state==.Running && ai_task_external(&task) && now-task.heard>=AI_EXTERNAL_IDLE {ai_external_end(s,&task)}
    }
}
