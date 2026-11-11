package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:editor/acp"
import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Fixture :: struct {
    root:string,
    world:Ai_Context_Test_World,
    info:core.World_Info,
    state:Api_State,
    editor_world:Ai_Context_Test_Editor,
    app:host.App,
    using edited:Test_Session,
    ai:^Ai,
}

// A project with the two agents connected and every worker busy, so that a
// turn stays queued until the test moves it.
@(private="file")
fixture_open :: proc(t:^testing.T,name:string) -> ^Fixture {
    f:=new(Fixture)
    f.root=base.test_folder(t,fmt.tprintf("ai-%s",name))
    described:bool
    f.info,described=ai_context_test_info(t)
    if !described || !testing.expect(t,core.world_init(&f.info,.World,&f.world,context.allocator)) || f.root=="" {
        if described {core.world_destroy(&f.info,.World,&f.world);test_info_destroy(&f.info)}
        free(f)
        return nil
    }
    test_session_open(&f.edited,core.world_ref(&f.world,&f.info))
    f.state.server.port=7940
    f.editor_world.api.state=&f.state
    f.viewport.size,f.viewport.window={800,600},{800,600}
    f.document.path_length=copy(f.document.path[:],"scenes/main.scene")
    f.ai=new(Ai)
    ai_connections_reset(f.ai)
    f.ai.initialized=true
    base.text_set(f.ai.agents_home[:],project.path(f.root,"agents",allocator=context.temp_allocator))
    for &worker in f.ai.workers {worker.task=-1}
    f.ai.connections[AI_CODEX].configured,f.ai.connections[AI_CLAUDE].configured=true,true
    testing.expect_value(t,ai_store.open(&f.ai.store,f.root),"")
    f.s.editor_world,f.s.app,f.s.ai,f.s.project_root,f.s.has_project=&f.editor_world,&f.app,f.ai,f.root,true
    return f
}

@(private="file")
fixture_close :: proc(f:^Fixture) {
    for &task in f.ai.tasks[:f.ai.task_count] {ai_review_free(&task.review);ai_steers_free(&task)}
    ai_store.close(&f.ai.store)
    test_session_close(&f.edited)
    core.world_destroy(&f.info,.World,&f.world)
    test_info_destroy(&f.info)
    free(f.ai)
    free(f)
}

// A worker of the turn with the phase it is in, and room for whole prompts.
@(private="file")
fixture_worker :: proc(t:^testing.T,f:^Fixture,task:^Ai_Task,phase:acp.Phase) -> ^Ai_Worker {
    worker:=&f.ai.workers[0]
    if len(worker.client.tx)==0 {testing.expect_value(t,acp.create(&worker.client),acp.Error.None)}
    worker.task,worker.client.phase=task.id,phase
    worker.client.queued,worker.client.sent=0,0
    return worker
}

@(private="file")
fixture_worker_close :: proc(worker:^Ai_Worker) {acp.destroy(&worker.client,nil)}

@(private="file")
sent_text :: proc(worker:^Ai_Worker) -> string {return string(worker.client.tx[:worker.client.queued])}

@(private="file")
deliveries_of :: proc(f:^Fixture,task:^Ai_Task) -> []ai_store.Delivery {
    deliveries,_:=ai_store.deliveries(&f.ai.store,task.conversation.id)
    return deliveries
}

@(private="file")
main_chat :: proc(t:^testing.T,f:^Fixture) -> ^Ai_Task {
    main,message:=ai_task_create(&f.s,f.ai,{0,0,800,600},"Make a room","codex")
    testing.expect_value(t,message,"")
    return main
}

@(test)
the_main_chat_is_restored_with_its_transcript_and_never_evicted :: proc(t:^testing.T) {
    f:=fixture_open(t,"main-restore")
    if f==nil {return}
    defer fixture_close(f)
    main:=main_chat(t,f)
    if main==nil {return}
    main.state=.Done
    ai_transcript_add(&main.transcript,"The room is ready",.Output)
    ai_task_dirty(main);ai_task_persist(&f.s,main)
    archived:=ai_store.Conversation{id=500,kind=.Archived,updated_at=9}
    testing.expect_value(t,ai_transcript_save(&f.ai.store,&archived,&main.transcript),"")
    restored:=new(Ai);defer free(restored)
    ai_connections_reset(restored)
    restored.agents_home=f.ai.agents_home
    other:=f.s
    other.ai=restored
    ai_initialize(&other)
    defer ai_store.close(&restored.store)
    defer for &task in restored.tasks[:restored.task_count] {ai_review_free(&task.review)}
    testing.expect(t,restored.main==main.id && restored.selected==main.id,"the first frame of a project shows its chat")
    loaded:=ai_task_find(restored,restored.main)
    if !testing.expect(t,loaded!=nil) {return}
    testing.expect(t,loaded.conversation.kind==.Main && loaded.state==.Done && loaded.transcript.count==main.transcript.count)
    testing.expect_value(t,restored.task_count,1)
    testing.expect(t,ai_task_find(restored,500)==nil && restored.history_count==0 && ai_store.find(&restored.store,500)!=nil,"what was archived stays readable and nothing more")
    for index in restored.task_count..<AI_TASK_CAPACITY {
        task:=&restored.tasks[index]
        task.id,task.state,task.review_finished=100+index,.Done,true
    }
    restored.task_count=AI_TASK_CAPACITY
    restored.selected=101
    slot:=ai_task_slot(restored)
    testing.expect(t,slot!=nil && ai_task_find(restored,restored.main)!=nil,"the main chat stays while others leave")
    testing.expect(t,ai_task_find(restored,101)==nil && restored.selected==restored.main,"an inspected subagent that leaves gives the view back to the chat")
}

@(test)
a_subagent_runs_in_its_own_conversation_and_keeps_the_view_of_the_user :: proc(t:^testing.T) {
    f:=fixture_open(t,"subagent-view")
    if f==nil {return}
    defer fixture_close(f)
    m:=f.ai
    main:=main_chat(t,f)
    if main==nil {return}
    main.state=.Running
    m.prompt_length=copy(m.prompt[:],"A draft")
    m.attachments[0]=base.Asset_Id{1,2};m.attachment_count=1
    agent,message:=ai_agent_spawn(&f.s,m,"Paint the wall","Painter","","","")
    if !testing.expect(t,agent!=nil && message=="",message) {return}
    testing.expect(t,agent.conversation.kind==.Agent && agent.conversation.parent==u64(main.id) && agent.id!=main.id)
    testing.expect_value(t,base.text_get(agent.title[:]),"Painter")
    testing.expect(t,m.selected==main.id && string(m.prompt[:m.prompt_length])=="A draft" && m.attachment_count==1,"nothing of what the user does moves")
    testing.expect(t,agent.attachment_count==0 && agent.context_count==0 && !agent.image,"and nothing of it goes with the subagent")
    agent.state=.Done
    continued,continue_error:=ai_task_create(&f.s,m,{0,0,800,600},"And the floor","",agent.id,turn={detached=true})
    testing.expect(t,continued==agent && continue_error=="" && m.selected==main.id && agent.state==.Queued)
    agent.state=.Done
    f.document.path_length=copy(f.document.path[:],"scenes/other.scene")
    elsewhere,elsewhere_error:=ai_task_create(&f.s,m,{0,0,800,600},"And the ceiling","",agent.id,turn={detached=true})
    testing.expect(t,elsewhere==nil && elsewhere_error!="","a subagent stays on the document it began on")
}

@(private="file")
spawn_call :: proc(s:^Session,tag:string) -> (call:api.Call,text:string) {
    p:=new(Ai_Agent_Spawn_Params,context.temp_allocator)
    base.text_set(p.prompt[:],"Paint the wall")
    w:=new(serial.Writer,context.temp_allocator)
    serial.writer_init(w,0,context.temp_allocator)
    method:=new(api.Method,context.temp_allocator)
    method^={name="agent.spawn",params_id=Ai_Agent_Spawn_Params,result_id=Ai_Agent_Result}
    call={method=method,raw="{}",client_tag=tag,params=p,out=w,allocator=context.temp_allocator}
    ai_method_agent_spawn(s,&call)
    return call,string(serial.writer_bytes(w))
}

@(test)
agent_spawn_works_only_from_a_running_turn_of_the_main_chat :: proc(t:^testing.T) {
    f:=fixture_open(t,"spawn-depth")
    if f==nil {return}
    defer fixture_close(f)
    main:=main_chat(t,f)
    if main==nil {return}
    main.state=.Running
    call,text:=spawn_call(&f.s,base.text_get(main.name[:]))
    if !testing.expectf(t,!call.failed,"%s",call.error.message) {return}
    testing.expect_value(t,api.result_mismatch(Ai_Agent_Result,text),"")
    testing.expect_value(t,f.ai.task_count,2)
    testing.expect_value(t,f.ai.selected,main.id)
    agent:=&f.ai.tasks[1]
    agent.state=.Running
    call,_=spawn_call(&f.s,base.text_get(agent.name[:]))
    testing.expect(t,call.failed && strings.contains(call.error.message,"depth is 1"),"a subagent is told why")
    call,_=spawn_call(&f.s,"")
    testing.expect(t,call.failed,"a script is no turn of the chat")
    main.state=.Done
    call,_=spawn_call(&f.s,base.text_get(main.name[:]))
    testing.expect(t,call.failed,"a chat that does not work starts nothing")
    testing.expect_value(t,f.ai.task_count,2)
}

@(test)
what_a_subagent_runs_with_follows_the_explicit_values_and_the_default_of_the_project :: proc(t:^testing.T) {
    f:=fixture_open(t,"subagent-default")
    if f==nil {return}
    defer fixture_close(f)
    m:=f.ai
    main:=new(Ai_Task);defer free(main)
    base.text_set(main.agent[:],"codex")
    c:=&main.conversation
    ai_store.conversation_set_text(c.model[:],&c.model_len,"gpt-6.1-sol")
    ai_store.conversation_set_text(c.effort[:],&c.effort_len,"high")
    base.text_set(m.connections[2].id[:],"local")
    m.connections[2].agent=.Command
    m.connection_count=3
    Case :: struct {mode:Ai_Subagent_Mode,fixed,fixed_model,fixed_effort,agent,model,effort,connection,want_model,want_effort,problem:string}
    cases:=[]Case{
        {mode=.Same,connection="codex",want_model="gpt-6.1-sol",want_effort="high"},
        {mode=.Same,model="gpt-6-astra",connection="codex",want_model="gpt-6-astra",want_effort="high"},
        {mode=.Same,agent="claude",connection="claude"},
        {mode=.Fixed,fixed="claude",fixed_model="opus",fixed_effort="medium",connection="claude",want_model="opus",want_effort="medium"},
        {mode=.Fixed,fixed="claude",fixed_model="opus",fixed_effort="medium",effort="high",connection="claude",want_model="opus",want_effort="high"},
        {mode=.Fixed,fixed="claude",fixed_model="opus",agent="codex",connection="codex",want_model="gpt-6.1-sol",want_effort="high"},
        {mode=.Pick,connection="codex",want_model="gpt-6.1-sol",want_effort="high"},
        {mode=.Pick,agent="claude",connection="claude"},
        {mode=.Fixed,fixed="local",problem="not configured"},
        {mode=.Same,agent="local",problem="not configured"},
        {mode=.Same,agent="nobody",problem="no connection"},
    }
    for entry in cases {
        m.subagent={mode=entry.mode}
        base.text_set(m.subagent.connection[:],entry.fixed);base.text_set(m.subagent.model[:],entry.fixed_model);base.text_set(m.subagent.effort[:],entry.fixed_effort)
        connection,model,effort,problem:=ai_subagent_resolve(m,main,entry.agent,entry.model,entry.effort)
        if entry.problem!="" {
            testing.expectf(t,strings.contains(problem,entry.problem),"%v said %q",entry,problem)
            continue
        }
        testing.expectf(t,problem=="" && connection==entry.connection && model==entry.want_model && effort==entry.want_effort,"%v gave %s %s %s %s",entry,connection,model,effort,problem)
    }
    p:=new(Ai_Configure_Params,context.temp_allocator)
    base.text_set(p.subagent_mode[:],"fixed")
    m.subagent={}
    testing.expect(t,ai_subagent_configure(&f.s,p)!="","fixed needs its connection")
    base.text_set(p.subagent_connection[:],"claude");base.text_set(p.subagent_effort[:],"extreme")
    testing.expect(t,ai_subagent_configure(&f.s,p)!="" && m.subagent.mode==.Same,"a value that is refused changes nothing")
    base.text_set(p.subagent_effort[:],"low")
    testing.expect_value(t,ai_subagent_configure(&f.s,p),"")
    restored:=new(Ai);defer free(restored)
    restored.agents_home=m.agents_home
    other:=f.s
    other.ai=restored
    ai_settings_initialize(&other)
    testing.expect(t,restored.subagent.mode==.Fixed && base.text_get(restored.subagent.connection[:])=="claude" && base.text_get(restored.subagent.effort[:])=="low","it is saved with the project")
}

@(test)
a_finished_subagent_reports_and_what_waits_becomes_one_system_turn_of_the_idle_chat :: proc(t:^testing.T) {
    f:=fixture_open(t,"reports")
    if f==nil {return}
    defer fixture_close(f)
    m:=f.ai
    main:=main_chat(t,f)
    if main==nil {return}
    main.state=.Done
    main_lines:=main.transcript.count
    first,_:=ai_agent_spawn(&f.s,m,"Paint the wall","Painter","","","")
    second,_:=ai_agent_spawn(&f.s,m,"Light the wall","Lighter","","","")
    if !testing.expect(t,first!=nil && second!=nil) {return}
    first.state,second.state=.Running,.Running
    ai_transcript_add(&first.transcript,"The wall is **red**.\nIt took one coat.",.Output)
    append(&first.review.changed_files,strings.clone("assets/wall.mat"))
    ai_task_end(&f.s,m,first,0)
    testing.expect_value(t,main.transcript.count,main_lines+1)
    text,kind:=ai_transcript_line(&main.transcript,main_lines)
    testing.expect(t,kind==.Report && text==fmt.tprintf("%d",first.id),"the main chat has one line with the id of the subagent")
    shown:[AI_TRANSCRIPT_LINES]bool
    ai_transcript_shown(main,shown[:main.transcript.count])
    testing.expect(t,shown[main_lines] && strings.contains(ai_report_label(m,text),"Painter"),"and it shows")
    deliveries:=deliveries_of(f,main)
    if !testing.expect_value(t,len(deliveries),1) {return}
    for fragment in ([?]string{fmt.tprintf("%d",first.id),"Painter","done","1 changes","The wall is **red**.\nIt took one coat."}) {
        testing.expectf(t,strings.contains(deliveries[0].text,fragment),"%q is missing from %q",fragment,deliveries[0].text)
    }
    ai_deliveries_advance(&f.s,m)
    testing.expect(t,main.state==.Done,"a chat waits for the subagents that still work")
    ai_task_end(&f.s,m,second,0)
    testing.expect_value(t,len(deliveries_of(f,main)),2)
    lines:=main.transcript.count
    ai_deliveries_advance(&f.s,m)
    testing.expect_value(t,main.state,Ai_Task_State.Queued)
    testing.expect_value(t,main.transcript.count,lines)
    ai_task_prompt_lines:=0
    for index in 0..<main.transcript.count {if _,line:=ai_transcript_line(&main.transcript,index);line==.Prompt {ai_task_prompt_lines+=1}}
    testing.expect_value(t,ai_task_prompt_lines,1)
    testing.expect_value(t,len(deliveries_of(f,main)),2)
    // The turn takes them when it starts: all in one, and they are gone.
    worker:=fixture_worker(t,f,main,.Ready)
    defer fixture_worker_close(worker)
    ai_send_task_prompt(&f.s,worker,main)
    sent:=sent_text(worker)
    testing.expect(t,strings.contains(sent,"Painter") && strings.contains(sent,"Lighter") && worker.client.phase==.Prompting)
    testing.expect_value(t,len(deliveries_of(f,main)),0)
    // What arrives while the user writes goes with what they send.
    ai_task_end(&f.s,m,main,0)
    worker.task=-1
    testing.expect_value(t,ai_store.delivery_add(&m.store,main.conversation.id,AI_DELIVERY_REPORT,"Subagent 9 ended"),"")
    continued,message:=ai_task_create(&f.s,m,{0,0,800,600},"Also the door","codex",main.id)
    testing.expect(t,continued==main && message=="" && main.state==.Queued)
    testing.expect_value(t,len(deliveries_of(f,main)),1)
    worker=fixture_worker(t,f,main,.Ready)
    ai_send_task_prompt(&f.s,worker,main)
    sent=sent_text(worker)
    testing.expect(t,strings.contains(sent,"Also the door") && strings.contains(sent,"Subagent 9 ended"))
    testing.expect_value(t,len(deliveries_of(f,main)),0)
    ai_task_end(&f.s,m,main,0)
    // Without anything left, an idle chat stays idle; a review of the user holds the reports back.
    worker.task=-1
    ai_deliveries_advance(&f.s,m)
    testing.expect_value(t,main.state,Ai_Task_State.Done)
    testing.expect_value(t,ai_store.delivery_add(&m.store,main.conversation.id,AI_DELIVERY_REPORT,"Subagent 9 ended"),"")
    main.review.pending=true
    m.deliveries_due=true
    ai_deliveries_advance(&f.s,m)
    testing.expect_value(t,main.state,Ai_Task_State.Done)
}

@(test)
a_message_to_a_working_chat_joins_its_turn_or_waits_for_the_next_one :: proc(t:^testing.T) {
    f:=fixture_open(t,"steer")
    if f==nil {return}
    defer fixture_close(f)
    m:=f.ai
    main:=main_chat(t,f)
    if main==nil {return}
    main.state=.Running
    worker:=fixture_worker(t,f,main,.Prompting)
    defer fixture_worker_close(worker)
    worker.client.steering=true
    callback:=Ai_Callback{session=&f.s,worker=worker}
    write :: proc(f:^Fixture,text:string) -> bool {
        f.ai.prompt_length=copy(f.ai.prompt[:],text)
        return ai_chat_send(&f.s)
    }
    prompts :: proc(task:^Ai_Task) -> (count:int) {
        for index in 0..<task.transcript.count {if _,kind:=ai_transcript_line(&task.transcript,index);kind==.Prompt {count+=1}}
        return
    }
    testing.expect(t,write(f,"Make it red") && m.prompt_length==0 && !m.pending,"the turn is not stopped")
    testing.expect(t,main.state==.Running && !main.stop && main.steer_count==1 && main.held==0)
    testing.expect_value(t,prompts(main),2)
    testing.expect(t,strings.contains(sent_text(worker),"_session/steering") && strings.contains(sent_text(worker),"Make it red"))
    ai_acp_event(&callback,acp.Event{kind=.Steer_Done,text="injected",steer_id=worker.client.steer_id})
    testing.expect(t,main.steer_count==0 && main.held==0 && len(deliveries_of(f,main))==0,"what joined the turn needs nothing else")
    // Cannot happen with the option Mirai sends; if it did, nothing else changes.
    testing.expect(t,write(f,"Make it blue"))
    ai_acp_event(&callback,acp.Event{kind=.Steer_Done,text="startedNewTurn",steer_id=worker.client.steer_id})
    testing.expect(t,main.state==.Running && main.steer_count==0 && main.held==0)
    // The turn could not take it: the line stays and the text waits.
    testing.expect(t,write(f,"Make it green"))
    lines:=main.transcript.count
    ai_acp_event(&callback,acp.Event{kind=.Steer_Done,text="promptRequired",steer_id=worker.client.steer_id})
    testing.expect(t,main.steer_count==0 && main.held==1 && main.transcript.count==lines)
    deliveries:=deliveries_of(f,main)
    if !testing.expect_value(t,len(deliveries),1) {return}
    testing.expect(t,deliveries[0].kind==AI_DELIVERY_STEER && deliveries[0].text=="Make it green")
    testing.expect(t,write(f,"Make it pink"))
    ai_acp_event(&callback,acp.Event{kind=.Steer_Done,text="failed",steer_id=worker.client.steer_id})
    testing.expect_value(t,main.held,2)
    // An agent without steering, or a turn without a worker yet.
    worker.client.steering=false
    testing.expect(t,write(f,"Make it gold"))
    worker.task=0
    testing.expect(t,write(f,"Make it grey"))
    testing.expect_value(t,main.held,4)
    testing.expect_value(t,prompts(main),7)
    // It goes as the next turn, without a second bubble and whatever else is written.
    main.state=.Done
    worker.task=-1
    m.deliveries_due=true
    lines=main.transcript.count
    ai_deliveries_advance(&f.s,m)
    testing.expect(t,main.state==.Queued && main.transcript.count==lines && main.held==4)
    worker=fixture_worker(t,f,main,.Ready)
    ai_send_task_prompt(&f.s,worker,main)
    for text in ([?]string{"Make it green","Make it pink","Make it gold","Make it grey"}) {testing.expect(t,strings.contains(sent_text(worker),text))}
    testing.expect(t,main.held==0 && len(deliveries_of(f,main))==0)
    // A chat that was stopped keeps its text for the next message.
    worker.client.phase=.Ready
    ai_task_end(&f.s,m,main,0)
    worker.task=-1
    main.stop=false
    testing.expect_value(t,ai_store.delivery_add(&m.store,main.conversation.id,AI_DELIVERY_STEER,"Later"),"")
    main.held=1
    main.state=.Cancelled
    m.deliveries_due=true
    ai_deliveries_advance(&f.s,m)
    testing.expect_value(t,main.state,Ai_Task_State.Cancelled)
}

@(test)
one_worker_is_never_taken_by_a_subagent :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{ai=m}
    m.main,m.task_count=1,AI_WORKER_CAPACITY+1
    for &task,index in m.tasks[:m.task_count] {
        task.id=index+1;task.state=.Queued
        task.conversation.kind=index==0?.Main:.Agent
    }
    for index in 0..<AI_WORKER_CAPACITY-1 {
        worker:=ai_worker_take(&s,&m.tasks[index+1],AI_CODEX)
        if !testing.expect(t,worker!=nil) {return}
        worker.task=m.tasks[index+1].id
    }
    testing.expect_value(t,ai_subagent_workers(m),AI_WORKER_CAPACITY-1)
    testing.expect(t,ai_worker_take(&s,&m.tasks[AI_WORKER_CAPACITY],AI_CODEX)==nil,"the last worker is not for a subagent")
    last:=ai_worker_take(&s,&m.tasks[0],AI_CODEX)
    if !testing.expect(t,last!=nil,"the main chat can always answer") {return}
    last.task=m.tasks[0].id
    testing.expect_value(t,ai_running_count(m),AI_WORKER_CAPACITY)
    testing.expect(t,ai_worker_take(&s,&m.tasks[AI_WORKER_CAPACITY],AI_CODEX)==nil)
}

// Sends the queued turn of a chat on a native session and ends it; gives what went out.
@(private="file")
turn_sent :: proc(t:^testing.T,f:^Fixture,task:^Ai_Task,native:string) -> string {
    worker:=fixture_worker(t,f,task,.Ready)
    base.text_set(worker.client.session[:],native)
    ai_send_task_prompt(&f.s,worker,task)
    sent:=strings.clone(sent_text(worker),context.temp_allocator)
    worker.client.phase=.Ready
    ai_task_end(&f.s,f.ai,task,0)
    worker.task=-1
    return sent
}

@(private="file")
next_message :: proc(t:^testing.T,f:^Fixture,task:^Ai_Task,text:string) {
    task.state=.Done
    continued,message:=ai_task_create(&f.s,f.ai,{0,0,800,600},text,"codex",task.id)
    testing.expect(t,continued==task && message=="",message)
}

@(private="file")
STABLE_MARK :: "You are the game agent"

@(test)
the_stable_block_is_the_same_each_turn_and_goes_once_per_native_session :: proc(t:^testing.T) {
    f:=fixture_open(t,"stable-once")
    if f==nil {return}
    defer fixture_close(f)
    defer fixture_worker_close(&f.ai.workers[0])
    main:=main_chat(t,f)
    if main==nil {return}
    first:=turn_sent(t,f,main,"native-1")
    testing.expect(t,strings.contains(first,STABLE_MARK),"the first turn of a native session has it")
    stored,_:=os.read_entire_file(ai_task_path(&f.s,main,AI_FILE_PROMPT),context.temp_allocator)
    stable:=ai_prompt_stable(&f.s,.Main)
    testing.expect(t,strings.has_prefix(string(stored),stable),"prompt.md keeps what was sent")
    testing.expect(t,!strings.contains(stable,base.text_get(main.name[:])) && !strings.contains(stable,AI_FILE_CONTEXT),"nothing of one turn is in it")
    next_message(t,f,main,"Make it red")
    second:=turn_sent(t,f,main,"native-1")
    testing.expect(t,!strings.contains(second,STABLE_MARK) && strings.contains(second,"Make it red"),"the next turn has only the delta")
    stored,_=os.read_entire_file(ai_task_path(&f.s,main,AI_FILE_PROMPT),context.temp_allocator)
    testing.expect(t,!strings.contains(string(stored),STABLE_MARK))
    testing.expect_value(t,ai_prompt_stable(&f.s,.Main),stable)
    testing.expect(t,strings.contains(ai_prompt_stable(&f.s,.Agent),"You are a subagent") && !strings.contains(stable,"You are a subagent"))
    next_message(t,f,main,"Make it blue")
    testing.expect(t,strings.contains(turn_sent(t,f,main,"native-2"),STABLE_MARK),"another native session needs it")
}

@(test)
the_stable_block_goes_again_after_a_compaction :: proc(t:^testing.T) {
    f:=fixture_open(t,"stable-compaction")
    if f==nil {return}
    defer fixture_close(f)
    defer fixture_worker_close(&f.ai.workers[0])
    main:=main_chat(t,f)
    if main==nil {return}
    turn_sent(t,f,main,"native-1")
    update :: proc(f:^Fixture,task:^Ai_Task,status:string) {
        worker:=&f.ai.workers[0]
        worker.task=task.id
        callback:=Ai_Callback{session=&f.s,worker=worker}
        text:=fmt.tprintf(`{{"sessionId":"native-1","update":{{"sessionUpdate":"compaction_update","compactionId":"c","status":%q}}}}`,status)
        value,_:=json.parse_string(text,allocator=context.temp_allocator)
        ai_acp_event(&callback,acp.Event{kind=.Update,value=value})
        worker.task=-1
    }
    update(f,main,"in_progress")
    next_message(t,f,main,"One")
    testing.expect(t,!strings.contains(turn_sent(t,f,main,"native-1"),STABLE_MARK),"a compaction that is not done changes nothing")
    update(f,main,"completed")
    last,kind:=ai_transcript_line(&main.transcript,main.transcript.count-1)
    testing.expect(t,kind==.Note && last==AI_COMPACTED_NOTE)
    next_message(t,f,main,"Two")
    sent:=turn_sent(t,f,main,"native-1")
    testing.expect(t,strings.contains(sent,STABLE_MARK) && !strings.contains(sent,"no longer have"),"the same native session summarized itself")
}

@(test)
the_delta_has_what_waits_what_is_pinned_and_who_works :: proc(t:^testing.T) {
    f:=fixture_open(t,"delta")
    if f==nil {return}
    defer fixture_close(f)
    defer fixture_worker_close(&f.ai.workers[0])
    m:=f.ai
    main:=main_chat(t,f)
    if main==nil {return}
    agent,_:=ai_agent_spawn(&f.s,m,"Paint the wall","Painter","","","")
    if !testing.expect(t,agent!=nil) {return}
    testing.expect_value(t,ai_store.delivery_add(&m.store,main.conversation.id,AI_DELIVERY_REPORT,"Subagent 9 ended well"),"")
    pin_error:=ai_store.pin_add(&m.store,"asset","materials/wall.mat","The wall")
    testing.expect_value(t,pin_error,"")
    _,here:=ai_store.annotation_add(&m.store,"todo","scenes/main.scene",33,1,2,3,"Fix this corner")
    testing.expect_value(t,here,"")
    _,there:=ai_store.annotation_add(&m.store,"todo","scenes/other.scene",33,1,2,3,"Another scene")
    testing.expect_value(t,there,"")
    sent:=turn_sent(t,f,main,"native-1")
    for fragment in ([?]string{"Subagent 9 ended well","materials/wall.mat","The wall","Fix this corner","Painter",base.text_get(main.name[:])}) {
        testing.expectf(t,strings.contains(sent,fragment),"%q is missing from the delta",fragment)
    }
    testing.expect(t,!strings.contains(sent,"Another scene"),"the annotations are those of its document")
    testing.expect_value(t,len(deliveries_of(f,main)),0)
}

@(test)
the_delta_names_pins_and_annotations_every_turn_without_images_even_after_a_compaction :: proc(t:^testing.T) {
    f:=fixture_open(t,"delta-pins")
    if f==nil {return}
    defer fixture_close(f)
    defer fixture_worker_close(&f.ai.workers[0])
    m:=f.ai
    main:=main_chat(t,f)
    if main==nil {return}
    lamp:=core.create(&f.world.entities)
    core.add(&f.world.ids,lamp,core.Id{value=0x2a})
    name:core.Name
    base.text_set(name.text[:],"Lamp")
    core.add(&f.world.names,lamp,name)
    core.settle(&f.info,&f.world,nil)
    for pin in ([?][3]string{{AI_PIN_IMAGE,"C:/art/mood.png","mood.png"},{AI_PIN_ENTITY,"000000000000002a","Lamp"},{AI_PIN_GROUP,"lights","lights"}}) {testing.expect_value(t,ai_pin_toggle(f.s.ai,pin[0],pin[1],pin[2]),"")}
    _=ai_pins_sync(f.s.ai)
    testing.expect_value(t,m.pin_count,3)
    _,on_entity:=ai_store.annotation_add(&m.store,"lights","scenes/main.scene",0x2a,1.5,2,-3,"Too dark\nhere")
    testing.expect_value(t,on_entity,"")
    _,on_surface:=ai_store.annotation_add(&m.store,"","scenes/main.scene",0,4,5,6,"A door")
    testing.expect_value(t,on_surface,"")
    present :: proc(t:^testing.T,sent:string) {
        for fragment in ([?]string{"C:/art/mood.png","mood.png","000000000000002a | Lamp","| lights | lights","1 | lights | 1.500 2.000 -3.000 | 000000000000002a Lamp | Too dark here","2 | - | 4.000 5.000 6.000 | - | A door"}) {
            testing.expectf(t,strings.contains(sent,fragment),"%q is missing from the delta",fragment)
        }
        testing.expect(t,!strings.contains(sent,`"type":"image"`),"a pinned image goes by its path")
    }
    present(t,turn_sent(t,f,main,"native-1"))
    next_message(t,f,main,"And the door")
    ai_context_compacted(&f.s,main)
    present(t,turn_sent(t,f,main,"native-1"))
    _=ai_pin_toggle(f.s.ai,AI_PIN_IMAGE,"C:/art/mood.png","mood.png")
    _=ai_pins_sync(f.s.ai)
    testing.expect_value(t,m.pin_count,2)
    next_message(t,f,main,"And the floor")
    testing.expect(t,!strings.contains(turn_sent(t,f,main,"native-1"),"C:/art/mood.png"),"unpinning takes it out")
}

@(test)
a_pinned_chip_stays_over_the_composer_once_it_leaves_the_message :: proc(t:^testing.T) {
    f:=fixture_open(t,"pin-chip")
    if f==nil {return}
    defer fixture_close(f)
    m:=f.ai
    path:="C:/art/mood.png"
    base.text_set(m.references[0][:],path)
    m.reference_count=1
    _=ai_pin_toggle(f.s.ai,AI_PIN_IMAGE,path,"mood.png")
    listed:[AI_PINS]int
    testing.expect_value(t,ai_pins_listed(&f.s,listed[:]),0)
    m.reference_count=0
    count:=ai_pins_listed(&f.s,listed[:])
    testing.expect_value(t,count,1)
    testing.expect_value(t,base.text_get(m.pins[listed[0]].ref[:]),path)
    _=ai_pin_toggle(f.s.ai,AI_PIN_IMAGE,path,"mood.png")
    testing.expect_value(t,ai_pins_listed(&f.s,listed[:]),0)
}

@(private="file")
annotation_list :: proc(t:^testing.T,f:^Fixture) -> string {
    p:=new(Ai_Annotation_List_Params,context.temp_allocator)
    w:=new(serial.Writer,context.temp_allocator)
    serial.writer_init(w,0,context.temp_allocator)
    method:=new(api.Method,context.temp_allocator)
    method^={name="annotation.list",params_id=Ai_Annotation_List_Params,result_id=Ai_Annotation_List_Result}
    call:=api.Call{method=method,raw="{}",params=p,out=w,allocator=context.temp_allocator}
    ai_method_annotation_list(&f.s,&call)
    testing.expect(t,!call.failed,call.error.message)
    return string(serial.writer_bytes(w))
}

@(private="file")
annotation_remove :: proc(f:^Fixture,id:int,group:string) -> (removed:int,failed:bool) {
    p:=new(Ai_Annotation_Remove_Params,context.temp_allocator)
    p.id=id
    base.text_set(p.group[:],group)
    r:=new(Ai_Annotation_Remove_Result,context.temp_allocator)
    method:=new(api.Method,context.temp_allocator)
    method^={name="annotation.remove",params_id=Ai_Annotation_Remove_Params,result_id=Ai_Annotation_Remove_Result}
    call:=api.Call{method=method,raw="{}",params=p,result=r,allocator=context.temp_allocator}
    ai_method_annotation_remove(&f.s,&call)
    return r.removed,call.failed
}

@(test)
annotations_outlive_the_editor_and_the_agent_reads_and_clears_them :: proc(t:^testing.T) {
    f:=fixture_open(t,"annotations")
    if f==nil {return}
    defer fixture_close(f)
    m:=f.ai
    first,error:=ai_store.annotation_add(&m.store,"lights","scenes/main.scene",0,1,2,3,"Too dark")
    testing.expect_value(t,error,"")
    _,error=ai_store.annotation_add(&m.store,"lights","scenes/main.scene",0,4,5,6,"Too bright")
    testing.expect_value(t,error,"")
    _,error=ai_store.annotation_add(&m.store,"","scenes/main.scene",0,7,8,9,"A door")
    testing.expect_value(t,error,"")
    _,error=ai_store.annotation_add(&m.store,"lights","scenes/other.scene",0,0,0,0,"Elsewhere")
    testing.expect_value(t,error,"")
    ai_annotations_sync(&f.s)
    testing.expect_value(t,m.annotations.count,3)
    ai_store.close(&m.store)
    m.annotations={}
    testing.expect_value(t,ai_store.open(&m.store,f.root),"")
    ai_annotations_sync(&f.s)
    testing.expect(t,m.annotations.count==3 && base.text_get(m.annotations.rows[0].text[:])=="Too dark","they are read back after the editor reopens")
    text:=annotation_list(t,f)
    testing.expect_value(t,api.result_mismatch(Ai_Annotation_List_Result,text),"")
    testing.expect(t,strings.contains(text,"Too bright") && !strings.contains(text,"Elsewhere"),"the list is of the open document")
    _,failed:=annotation_remove(f,0,"")
    testing.expect(t,failed,"neither an id nor a group")
    removed,refused:=annotation_remove(f,int(first)+100,"")
    testing.expect(t,refused && removed==0,"an unknown id is an error")
    removed,_=annotation_remove(f,int(first),"")
    testing.expect_value(t,removed,1)
    ai_annotations_sync(&f.s)
    testing.expect_value(t,m.annotations.count,2)
    removed,_=annotation_remove(f,0,"lights")
    testing.expect_value(t,removed,1)
    ai_annotations_sync(&f.s)
    testing.expect_value(t,m.annotations.count,1)
}

@(test)
memory_save_stays_in_its_files_and_within_its_caps :: proc(t:^testing.T) {
    f:=fixture_open(t,"memory-save")
    if f==nil {return}
    defer fixture_close(f)
    Refused :: struct {scope,topic,says:string}
    refused:=[]Refused{
        {"project","../escape","slug"},{"project","a/b","slug"},{"project","a\\b","slug"},{"project","..","slug"},{"project","Upper","slug"},
        {"user","topic","one file"},{"everyone","","scope"},
    }
    for entry in refused {
        path,message:=ai_memory_save(&f.s,entry.scope,entry.topic,"text")
        testing.expectf(t,path=="" && strings.contains(message,entry.says),"%v said %q",entry,message)
    }
    testing.expect(t,!os.exists(project.path(f.root,"escape.md",allocator=context.temp_allocator)))
    Cap :: struct {scope,topic:string,limit:int}
    for entry in ([]Cap{{"project","",AI_MEMORY_INDEX_BYTES},{"project","art",AI_MEMORY_TOPIC_BYTES},{"user","",AI_MEMORY_USER_BYTES}}) {
        big:=strings.repeat("x",entry.limit+1,context.temp_allocator)
        _,message:=ai_memory_save(&f.s,entry.scope,entry.topic,big)
        testing.expectf(t,strings.contains(message,fmt.tprintf("%d bytes",entry.limit+1)) && strings.contains(message,fmt.tprintf("%d",entry.limit)),"%v said %q",entry,message)
    }
    path,message:=ai_memory_save(&f.s,"project","art","Walls are brick")
    testing.expect(t,message=="" && path==".agents/memory/art.md",message)
    _,index:=ai_memory_save(&f.s,"project","","- art: how walls look")
    testing.expect_value(t,index,"")
    _,user:=ai_memory_save(&f.s,"user","","Prefers short answers")
    testing.expect_value(t,user,"")
    stable:=ai_prompt_stable(&f.s,.Main)
    testing.expect(t,strings.contains(stable,"how walls look") && strings.contains(stable,"Prefers short answers") && !strings.contains(stable,"Walls are brick"),"the index and the user go in the block, a topic on demand")
    for wrong in ([?]string{"../escape.md",".agents/memory/../../escape.md",".agents/memory/sub/a.md","AGENTS.md",".agents/skills/a.md","C:/Windows/a.md",ai_memory_topics_folder(&f.s)}) {
        _,problem:=ai_memory_resolve(&f.s,wrong)
        testing.expectf(t,problem!="","%s is outside the memory",wrong)
    }
    for right in ([?]string{path,ai_memory_user_path(f.ai)}) {
        full,problem:=ai_memory_resolve(&f.s,right)
        testing.expect(t,problem=="" && os.is_file(full),problem)
    }
}

@(test)
the_memory_index_catches_what_is_edited_outside_the_editor :: proc(t:^testing.T) {
    f:=fixture_open(t,"memory-index")
    if f==nil {return}
    defer fixture_close(f)
    m:=f.ai
    found :: proc(m:^Ai,word:string) -> int {
        hits:[4]ai_store.Memory_Hit
        count,_:=ai_store.memory_search(&m.store,word,hits[:])
        return count
    }
    folder:=ai_memory_topics_folder(&f.s)
    testing.expect(t,os.make_directory_all(folder)==nil)
    file:=project.path(folder,"art.md",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(file,"walls are brick")==nil)
    ai_memory_scan(&f.s)
    testing.expect_value(t,found(m,"brick"),1)
    time.sleep(50*time.Millisecond)
    testing.expect(t,os.write_entire_file(file,"walls are stone")==nil)
    ai_memory_scan(&f.s)
    testing.expect(t,found(m,"stone")==1 && found(m,"brick")==0)
    testing.expect(t,os.remove(file)==nil)
    ai_memory_scan(&f.s)
    testing.expect_value(t,found(m,"stone"),0)
}

@(test)
a_full_context_asks_for_notes_once_per_native_session :: proc(t:^testing.T) {
    f:=fixture_open(t,"notes-once")
    if f==nil {return}
    defer fixture_close(f)
    defer fixture_worker_close(&f.ai.workers[0])
    main:=main_chat(t,f)
    if main==nil {return}
    REMINDER :: "nearly full"
    testing.expect(t,!strings.contains(turn_sent(t,f,main,"native-1"),REMINDER),"not while there is room")
    main.conversation.usage.context_used,main.conversation.usage.context_size=i64(AI_COMPACT_NOTES_AT*100)+1,100
    next_message(t,f,main,"One")
    sent:=turn_sent(t,f,main,"native-1")
    testing.expect(t,strings.contains(sent,REMINDER) && strings.contains(sent,"memory_save") && strings.contains(sent,"chat_note"))
    next_message(t,f,main,"Two")
    testing.expect(t,!strings.contains(turn_sent(t,f,main,"native-1"),REMINDER),"it asks once")
    next_message(t,f,main,"Three")
    testing.expect(t,strings.contains(turn_sent(t,f,main,"native-2"),REMINDER),"each native session is asked")
}

@(test)
without_the_command_compacting_starts_a_new_native_session_with_a_handoff :: proc(t:^testing.T) {
    f:=fixture_open(t,"compact-fallback")
    if f==nil {return}
    defer fixture_close(f)
    defer fixture_worker_close(&f.ai.workers[0])
    main:=main_chat(t,f)
    if main==nil {return}
    turn_sent(t,f,main,"native-1")
    ai_transcript_add(&main.transcript,"The room has two doors",.Output)
    ai_task_dirty(main);ai_task_persist(&f.s,main)
    main.conversation.usage.context_used,main.conversation.usage.context_size=90,100
    testing.expect_value(t,ai_chat_compact(&f.s,main),"")
    testing.expect(t,main.conversation.native_session_len==0 && main.state==.Done && main.conversation.usage.context_used==0)
    last,kind:=ai_transcript_line(&main.transcript,main.transcript.count-1)
    testing.expect(t,kind==.Note && last==AI_COMPACTED_NOTE)
    next_message(t,f,main,"And the windows")
    sent:=turn_sent(t,f,main,"native-2")
    testing.expect(t,strings.contains(sent,AI_HANDOFF_HEADER) && strings.contains(sent,"The room has two doors") && strings.contains(sent,STABLE_MARK))
    next_message(t,f,main,"And the roof")
    testing.expect(t,!strings.contains(turn_sent(t,f,main,"native-2"),AI_HANDOFF_HEADER),"only its first turn")
    main.state=.Running
    testing.expect(t,ai_chat_compact(&f.s,main)!="","not while it works")
}

@(test)
the_compact_command_runs_as_a_turn_that_needs_no_finish_and_keeps_the_review :: proc(t:^testing.T) {
    f:=fixture_open(t,"compact-command")
    if f==nil {return}
    defer fixture_close(f)
    defer fixture_worker_close(&f.ai.workers[0])
    m:=f.ai
    main:=main_chat(t,f)
    if main==nil {return}
    turn_sent(t,f,main,"native-1")
    main.review.pending=true
    main.state=.Done
    lines:=main.transcript.count
    worker:=fixture_worker(t,f,main,.Ready)
    worker.task,worker.last_task,worker.client.compact_command=0,main.id,true
    testing.expect_value(t,ai_chat_compact(&f.s,main),"")
    testing.expect(t,strings.contains(sent_text(worker),AI_COMPACT_COMMAND) && worker.task==main.id && main.state==.Running)
    testing.expect_value(t,main.transcript.count,lines)
    callback:=Ai_Callback{session=&f.s,worker=worker}
    worker.client.phase=.Ready
    ai_acp_event(&callback,acp.Event{kind=.Prompt_Done})
    testing.expect(t,main.state==.Done && worker.task==0 && main.review.pending && !main.finish_called,"it ends well without finish")
    testing.expect_value(t,main.conversation.native_session_len,len("native-1"))
    last,kind:=ai_transcript_line(&main.transcript,main.transcript.count-1)
    testing.expect(t,kind==.Note && last==AI_COMPACTED_NOTE)
    worker.task=-1
    main.review.pending=false
    next_message(t,f,main,"Go on")
    testing.expect(t,strings.contains(turn_sent(t,f,main,"native-1"),STABLE_MARK))
    testing.expect_value(t,m.task_count,1)
}

@(test)
a_handoff_says_what_the_context_before_it_left :: proc(t:^testing.T) {
    f:=fixture_open(t,"handoff")
    if f==nil {return}
    defer fixture_close(f)
    m:=f.ai
    main:=main_chat(t,f)
    if main==nil {return}
    main.state=.Done
    ai_task_dirty(main)
    ai_transcript_add(&main.transcript,"The room has two doors",.Output)
    ai_transcript_add(&main.transcript,"Tool: scene.add Door · +1.0 s · 1.0 ms",.Note)
    ai_task_persist(&f.s,main)
    testing.expect_value(t,ai_store.note_set(&m.store,main.conversation.id,"Doors are done, windows are next"),"")
    ended,_:=ai_agent_spawn(&f.s,m,"Paint the wall","Painter","","","")
    gone,_:=ai_agent_spawn(&f.s,m,"Light the wall","Lighter","","","")
    if !testing.expect(t,ended!=nil && gone!=nil) {return}
    ended.state=.Done
    ended.review.pending=true
    append(&ended.review.changed_files,strings.clone("assets/wall.mat"))
    gone.state=.Interrupted
    testing.expect_value(t,ai_store.meta_set(&m.store,AI_META_INTERRUPTED_AGENTS,fmt.tprintf("%d,",gone.id)),"")
    next_message(t,f,main,"The next message")
    text:=ai_handoff_build(&f.s,main,ai_task_turn_sequence(main))
    for fragment in ([?]string{AI_HANDOFF_HEADER,"Doors are done, windows are next","Make a room","The room has two doors","Painter","Lighter","interrupted","1 changes"}) {
        testing.expectf(t,strings.contains(text,fragment),"%q is missing from %q",fragment,text)
    }
    testing.expect(t,!strings.contains(text,"The next message") && !strings.contains(text,"scene.add"),"not the turn it goes with, nor the steps")
    fresh,_:=ai_agent_spawn(&f.s,m,"First","Fresh","","","")
    if !testing.expect(t,fresh!=nil) {return}
    testing.expect_value(t,ai_handoff_build(&f.s,fresh,ai_task_turn_sequence(fresh)),"")
}

@(test)
reopening_starts_a_clean_context_unless_a_build_restarted_the_editor :: proc(t:^testing.T) {
    f:=fixture_open(t,"reopen")
    if f==nil {return}
    defer fixture_close(f)
    m:=f.ai
    main:=main_chat(t,f)
    if main==nil {return}
    main.state=.Done
    set_native :: proc(f:^Fixture,task:^Ai_Task) {
        ai_store.conversation_set_text(task.conversation.native_session[:],&task.conversation.native_session_len,"native-1")
        ai_task_dirty(task);ai_task_persist(&f.s,task)
    }
    set_native(f,main)
    agent,_:=ai_agent_spawn(&f.s,m,"Paint the wall","Painter","","","")
    if !testing.expect(t,agent!=nil) {return}
    open :: proc(f:^Fixture) -> (restored:^Ai,other:Session) {
        restored=new(Ai)
        ai_connections_reset(restored)
        restored.agents_home=f.ai.agents_home
        other=f.s
        other.ai=restored
        ai_initialize(&other)
        return
    }
    close :: proc(restored:^Ai) {
        for &task in restored.tasks[:restored.task_count] {ai_review_free(&task.review)}
        ai_store.close(&restored.store)
        free(restored)
    }
    reopened_lines:=0
    {
        restored,other:=open(f)
        defer close(restored)
        loaded:=ai_task_find(restored,restored.main)
        if !testing.expect(t,loaded!=nil) {return}
        testing.expect_value(t,loaded.conversation.native_session_len,0)
        last,kind:=ai_transcript_line(&loaded.transcript,loaded.transcript.count-1)
        testing.expect(t,kind==.Divider && last==AI_REOPENED_NOTE)
        working:=ai_task_find(restored,agent.id)
        if !testing.expect(t,working!=nil) {return}
        testing.expect(t,working.state==.Interrupted,"a subagent the editor closed on is not resumed")
        note,_:=ai_transcript_line(&working.transcript,working.transcript.count-1)
        testing.expect_value(t,note,AI_INTERRUPTED_NOTE)
        testing.expect(t,strings.contains(ai_handoff_build(&other,loaded,-1),"Painter"))
        reopened_lines=loaded.transcript.count
    }
    set_native(f,main)
    testing.expect_value(t,ai_store.meta_set(&m.store,AI_META_WORKING_AGENTS,""),"")
    ai_resume_native_mark(&f.s)
    {
        restored,_:=open(f)
        defer close(restored)
        loaded:=ai_task_find(restored,restored.main)
        if !testing.expect(t,loaded!=nil) {return}
        testing.expect_value(t,string(loaded.conversation.native_session[:loaded.conversation.native_session_len]),"native-1")
        testing.expect_value(t,base.text_get(loaded.stable_native[:]),"native-1")
        testing.expect_value(t,loaded.transcript.count,reopened_lines)
    }
    value,_:=ai_store.meta_get(&m.store,AI_META_RESUME_NATIVE)
    testing.expect_value(t,value,"")
    {
        restored,_:=open(f)
        defer close(restored)
        testing.expect_value(t,ai_task_find(restored,restored.main).conversation.native_session_len,0)
    }
}
