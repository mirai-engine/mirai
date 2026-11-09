package editor

import "core:fmt"
import "core:strconv"
import "core:strings"
import "mirai:editor/acp"
import "mirai:std/base"
import "mirai:ui"

// The agents the main chat starts are tasks of the editor, depth 1: each with
// its conversation, its turns and its review, bound to the document it began on.

Ai_Subagent_Mode :: enum u8 {
    Same,  // as the main chat
    Fixed, // the connection, model and effort of Ai_Subagent_Default
    Pick,  // the agent chooses with agent.spawn; what it leaves out is as Same
}
AI_SUBAGENT_MODES :: [Ai_Subagent_Mode]string{.Same="same",.Fixed="fixed",.Pick="pick"}

Ai_Subagent_Default :: struct {
    mode:Ai_Subagent_Mode,
    connection:[32]u8,
    model:[128]u8,
    effort:[32]u8,
}

// How a turn comes to be, besides its message.
Ai_Turn :: struct {
    system:bool,   // the editor starts it: no line of the user, and its message is what waits in deliveries
    detached:bool, // it takes nothing of the composer, the selection or the view of the user
    parent:int,    // a new subagent of this main chat
    title:string,  // of a new subagent; empty: the start of its prompt
}

AI_DELIVERY_REPORT :: "report" // a subagent ended a turn
AI_DELIVERY_STEER :: "steer"   // a message that could not join the turn it was written during

// A message sent to a running turn, until the agent answers what became of it.
Ai_Steer :: struct {
    id:int,     // Client.steer_id
    worker:int, // of Ai.workers
    text:string,
    lines:int,  // it took in the transcript
}

@(private)
ai_worker_index :: proc "contextless" (m:^Ai,worker:^Ai_Worker) -> int {
    return int((uintptr(worker)-uintptr(&m.workers[0]))/size_of(Ai_Worker))
}

ai_steers_free :: proc(task:^Ai_Task) {
    for &steer in task.steers[:task.steer_count] {delete(steer.text)}
    task.steer_count=0
}

// Messages written to a chat that have not reached its agent.
ai_task_held :: proc "contextless" (task:^Ai_Task) -> int {return task.held+task.steer_count}

// A subagent of the main chat.
ai_task_subagent :: proc "contextless" (task:^Ai_Task) -> bool {return task.conversation.kind==.Agent}

// What is looked at instead of the main chat: a subagent or an agent outside the editor.
ai_task_inspected :: proc(task:^Ai_Task) -> bool {return ai_task_subagent(task) || ai_task_external(task)}

// The workers subagents hold. One worker stays out of their reach.
ai_subagent_workers :: proc(m:^Ai) -> (count:int) {
    for &worker in m.workers {
        if task:=ai_task_find(m,worker.task);task!=nil && task.conversation.kind==.Agent {count+=1}
    }
    return
}

@(private)
ai_subagents_working :: proc(m:^Ai) -> bool {
    for &task in m.tasks[:m.task_count] {
        if task.conversation.kind==.Agent && !ai_task_finished(&task) {return true}
    }
    return false
}

// What a turn of an API call or of the deliveries looks at: the region of the
// last turn of its chat, or what the panels leave free.
@(private)
ai_turn_region :: proc(s:^Session,task:^Ai_Task) -> ui.Rect {
    if task!=nil {
        if _,ok:=ai_region_clamp(task.region,s.viewport.window);ok {return task.region}
    }
    return free_region(s.gui,s.viewport.window)
}

// The connection, model and effort of a subagent: what agent.spawn says first,
// then the default of the project. Only a connection that is configured is
// chosen, and none takes the place of another.
ai_subagent_resolve :: proc(m:^Ai,main:^Ai_Task,agent,model,effort:string) -> (connection,chosen_model,chosen_effort,problem:string) {
    defaults:=&m.subagent
    fixed:=base.text_get(defaults.connection[:])
    same:=base.text_get(main.agent[:])
    connection=agent
    if connection=="" {connection=defaults.mode==.Fixed?fixed:same}
    provider,known:=ai_provider_find(m,connection)
    if !known {
        problem=fmt.tprintf("There is no connection %q: ai.connections lists them",connection)
        return
    }
    if !m.connections[provider].configured {
        problem=fmt.tprintf("The connection %q is not configured: connect it in AI connections, or name another one with agent",connection)
        return
    }
    chosen_model,chosen_effort=model,effort
    switch {
    case defaults.mode==.Fixed && connection==fixed:
        if chosen_model=="" {chosen_model=base.text_get(defaults.model[:])}
        if chosen_effort=="" {chosen_effort=base.text_get(defaults.effort[:])}
    case connection==same:
        c:=&main.conversation
        if chosen_model=="" {chosen_model=string(c.model[:c.model_len])}
        if chosen_effort=="" {chosen_effort=string(c.effort[:c.effort_len])}
    }
    return
}

// Starts a subagent of the main chat. It does not touch what the user is
// looking at or writing; the answer comes back as a report of the main chat.
ai_agent_spawn :: proc(s:^Session,m:^Ai,prompt,title,agent,model,effort:string) -> (task:^Ai_Task,message:string) {
    main:=ai_task_find(m,m.main)
    if main==nil {return nil,"A subagent starts from a turn of the main chat, and there is none"}
    connection,chosen_model,chosen_effort,problem:=ai_subagent_resolve(m,main,agent,model,effort)
    if problem!="" {return nil,problem}
    return ai_task_create(s,m,ai_turn_region(s,main),prompt,connection,0,chosen_model,chosen_effort,{parent=main.id,title=title})
}

// What the agent of a task said last, once it has finished saying it.
ai_task_answer :: proc(task:^Ai_Task) -> string {
    if !ai_task_finished(task) {return ""}
    t:=&task.transcript
    last:=-1
    for index:=t.count-1;index>=0;index-=1 {
        text,kind:=ai_transcript_line(t,index)
        if kind==.Prompt {break}
        if kind==.Output && strings.trim_space(text)!="" {last=index;break}
    }
    if last<0 {return ""}
    first:=last
    for first>0 && t.lines[first-1].kind==.Output {first-=1}
    shown:=make([]bool,t.count,context.temp_allocator)
    for index in first..=last {shown[index]=true}
    return ai_message_text(t,first,shown)
}

// Adds a line to a chat that may be working, saving first what would be lost.
@(private)
ai_task_line_add :: proc(s:^Session,task:^Ai_Task,text:string,kind:Ai_Line_Kind) {
    if task.transcript.count==AI_TRANSCRIPT_LINES || task.transcript.used+len(text)>AI_TRANSCRIPT_BYTES {ai_task_persist(s,task)}
    ai_task_dirty(task)
    task.stream_open=false
    ai_transcript_add(&task.transcript,text,kind)
}

// A subagent ended a turn: the main chat gets a line, and what it ended with
// waits for its next turn.
@(private)
ai_agent_report :: proc(s:^Session,m:^Ai,task:^Ai_Task) {
    main:=ai_task_find(m,int(task.conversation.parent))
    if main==nil {return}
    id:[32]u8
    ai_task_line_add(s,main,fmt.bprintf(id[:],"%d",task.id),.Report)
    if m.store.db==nil {return}
    names:=AI_STATE_NAMES
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"Subagent %d, %q, ended a turn: %s, %d changes waiting for review.",task.id,base.text_get(task.title[:]),names[task.state],ai_review_count(task))
    if task.question!=.None {strings.write_string(&b," It asked the user a question and waits for the answer.")}
    if answer:=ai_task_answer(task);answer!="" {fmt.sbprintf(&b,"\nIts answer:\n%s",answer)}
    if message:=ai_store_delivery_add(&m.store,main.conversation.id,AI_DELIVERY_REPORT,strings.to_string(b));message!="" {notify(s,message)}
}

// A turn reached its end, or will not start. A subagent that goes on with a
// held message reports when it is done with it.
@(private)
ai_task_settle :: proc(s:^Session,m:^Ai,task:^Ai_Task) {
    if m.closing {return}
    ai_working_agents_save(s,m)
    m.deliveries_due=true
    if task.conversation.kind==.Agent && (task.held==0 || task.state!=.Done) {ai_agent_report(s,m,task)}
}

// Keeps a message for the next turn of its chat. Its line is in the chat already.
@(private)
ai_steer_hold :: proc(s:^Session,m:^Ai,task:^Ai_Task,text:string) -> string {
    if message:=ai_store_delivery_add(&m.store,task.conversation.id,AI_DELIVERY_STEER,text);message!="" {return message}
    task.held+=1
    return ""
}

// A message for a chat that works: its line goes in at once and it joins the
// turn at its next safe point; whatever cannot join goes as its next turn. A
// note goes to the agent with the message, not to the thread.
ai_task_steer :: proc(s:^Session,m:^Ai,task:^Ai_Task,text:string,note:string="") -> string {
    text:=strings.trim_space(text)
    if text=="" {return "The message is empty"}
    if len(text)>=AI_MESSAGE_BYTES {return "The message is too long"}
    task.stream_open=false
    t:=&task.transcript
    before:=t.dropped+t.count
    ai_task_prompt_add(s,task,text)
    lines:=t.dropped+t.count-before
    task.held_lines+=lines
    sent:=text
    if note!="" {sent=fmt.tprintf("%s\n\n%s",text,note)}
    if worker:=ai_task_worker(m,task.id);worker!=nil && !task.stop && task.steer_count<len(task.steers) && worker.client.steering {
        owned:=strings.clone(sent)
        content:=[1]acp.Content{{kind=.Text,text=sent}}
        if acp.steer(&worker.client,content[:])==.None {
            task.steers[task.steer_count]={id=worker.client.steer_id,worker=ai_worker_index(m,worker),text=owned,lines=lines}
            task.steer_count+=1
            return ""
        }
        delete(owned)
    }
    return ai_steer_hold(s,m,task,sent)
}

// The agent said what became of a message sent to a running turn.
@(private)
ai_steer_done :: proc(s:^Session,worker:^Ai_Worker,event:acp.Event) {
    m:=s.ai
    index:=ai_worker_index(m,worker)
    for &task in m.tasks[:m.task_count] {
        for &steer,at in task.steers[:task.steer_count] {
            if steer.worker!=index || steer.id!=event.steer_id {continue}
            text,lines:=steer.text,steer.lines
            defer delete(text)
            copy(task.steers[at:],task.steers[at+1:task.steer_count])
            task.steer_count-=1
            task.steers[task.steer_count]={}
            // A turn that started for it took it as well.
            if event.text!="injected" && event.text!="startedNewTurn" {
                if message:=ai_steer_hold(s,m,&task,text);message!="" {notify(s,message)}
            } else {
                task.held_lines=max(task.held_lines-lines,0)
            }
            m.deliveries_due=true
            return
        }
    }
}

// What waits to reach a conversation, as the text of one block.
@(private)
ai_deliveries_text :: proc(deliveries:[]Ai_Delivery) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for &delivery,index in deliveries {
        if index>0 {strings.write_string(&b,"\n\n")}
        strings.write_string(&b,delivery.text)
    }
    return strings.to_string(b)
}

@(private)
ai_delivery_turn :: proc(s:^Session,m:^Ai,task:^Ai_Task) {
    if turn,message:=ai_task_create(s,m,ai_turn_region(s,task),"","",task.id,turn={system=true});turn==nil {notify(s,message)}
}

// A chat that waits for nothing takes what was left for it, as one turn of
// its own. Only a turn that went well is followed: after a failure or a Stop
// it all goes with the next message of the user. Reports wait while a subagent
// works, so that the main chat gets them together, and while the main chat has
// changes to review, which a new turn would confirm.
ai_deliveries_advance :: proc(s:^Session,m:^Ai) {
    if !m.deliveries_due {return}
    m.deliveries_due=false
    for &task in m.tasks[:m.task_count] {
        if task.conversation.kind==.Agent && task.held>0 && task.steer_count==0 && task.state==.Done && ai_task_current(s,&task) {ai_delivery_turn(s,m,&task)}
    }
    main:=ai_task_find(m,m.main)
    if main==nil || main.state!=.Done || main.steer_count>0 {return}
    if main.held==0 {
        if ai_subagents_working(m) || main.review.pending {return}
        deliveries,message:=ai_store_deliveries(&m.store,main.conversation.id)
        if message!="" {notify(s,message);return}
        if len(deliveries)==0 {return}
    }
    ai_delivery_turn(s,m,main)
}

// The title of a unit, which may no longer be in memory.
ai_unit_title :: proc(m:^Ai,id:int) -> string {
    title:=""
    if task:=ai_task_find(m,id);task!=nil {
        title=base.text_get(task.title[:])
    } else if saved:=ai_store_find(&m.store,u64(id));saved!=nil {
        title=string(saved.title[:saved.title_len])
    }
    return ai_chat_title(title)
}

// The subagent of a report line: its text is the id.
ai_report_id :: proc(text:string) -> int {
    id,_:=strconv.parse_int(text,10)
    return id
}

// The title of a report in the thread.
ai_report_label :: proc(m:^Ai,text:string) -> string {
    id:=ai_report_id(text)
    ending:="finished"
    if task:=ai_task_find(m,id);task!=nil {
        #partial switch task.state {
        case .Failed:      ending="failed"
        case .Cancelled:   ending="stopped"
        case .Interrupted: ending="interrupted"
        }
    }
    return fmt.tprintf("%s %s",ai_unit_title(m,id),ending)
}
