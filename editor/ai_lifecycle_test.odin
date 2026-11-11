package editor

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:editor/acp"
import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"

@(private="file")
ai_cancel_test_mutation :: proc(s:^Session,call:^api.Call) {s.ai.next_id+=1}

@(private="file")
ai_agent_test_read :: proc(s:^Session,call:^api.Call) {s.ai.next_id=ai_task_of_call(s,call)}

// A command of the agent sends the context its process inherited, which
// names the agent and not a turn: the editor attributes the call to the turn
// that agent runs when the call arrives, as the MCP server of that turn does.
@(test)
an_agent_command_is_attributed_to_the_turn_its_agent_runs :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    m.task_count=3
    m.tasks[0]={id=1,state=.Done};base.text_set(m.tasks[0].name[:],"1-0")
    m.tasks[1]={id=2,state=.Running};base.text_set(m.tasks[1].name[:],"1-1")
    m.tasks[2]={id=3,state=.Queued};base.text_set(m.tasks[2].name[:],"2-0")
    m.workers[0].agent,m.workers[0].task=3,2
    m.workers[1].agent=4
    s:=Session{ai=m}
    state:=Api_State{poll_temp=context.temp_allocator}
    entry:=Api_Entry{state=&state,session=&s,run=ai_agent_test_read}
    method:=api.Method{name="scene.inspect",flags={.Read_Only}}
    read :: proc(method:^api.Method,entry:^Api_Entry,tag:string) -> api.Call {
        entry.session.ai.next_id=0
        call:=api.Call{method=method,user=entry,client_tag=tag,allocator=context.temp_allocator}
        api_trampoline(&call)
        return call
    }
    call:=read(&method,&entry,"agent-3")
    testing.expect(t,!call.failed && call.client_tag=="1-1" && m.next_id==2,"the call belongs to the turn its agent runs")
    for tag in ([?]string{"agent-4","agent-9","agent-0","agent-","agent-x"}) {
        call=read(&method,&entry,tag)
        testing.expectf(t,call.failed && m.next_id==0,"%s runs no turn",tag)
    }
    // The same process takes the turn of another conversation.
    m.tasks[1].state,m.tasks[2].state=.Done,.Running
    m.workers[0].task=3
    call=read(&method,&entry,"agent-3")
    testing.expect(t,!call.failed && call.client_tag=="2-0" && m.next_id==3,"a later turn of the agent takes its later calls")
    call=read(&method,&entry,"1-1")
    testing.expect(t,call.failed,"the context of a turn that ended is still rejected")
}

@(private="file")
ai_external_test_read :: proc(s:^Session,call:^api.Call) {s.ai.next_id=-1 if s.edits.author==history.EDIT_AUTHOR_API else int(s.edits.author)}

// The calls of an agent outside the editor are the turn of a chat of its own,
// which ends when it says so or stops calling, opens again while its review
// waits and is followed by the next turn of the chat once it was resolved.
@(test)
an_agent_outside_the_editor_works_in_a_turn_of_its_own_until_it_ends :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-external");if root=="" {return}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    testing.expect_value(t,ai_store.open(&m.store,root),"");defer ai_store.close(&m.store)
    m.initialized=true
    edits:history.Edits
    document:Document
    viewport:Viewport
    s:=Session{ai=m,has_project=true,project_root=root,edits=&edits,document=&document,viewport=&viewport}
    state:=Api_State{poll_temp=context.temp_allocator}
    entry:=Api_Entry{state=&state,session=&s,run=ai_external_test_read}
    method:=api.Method{name="scene.inspect",flags={.Read_Only}}
    read :: proc(method:^api.Method,entry:^Api_Entry,tag,client:string) -> api.Call {
        call:=api.Call{method=method,user=entry,raw="{}",client_tag=tag,client_name=client,allocator=context.temp_allocator}
        api_trampoline(&call)
        return call
    }
    end :: proc(s:^Session,tag,client:string) -> Ai_Turn_End_Result {
        method:=api.Method{name="ai.turn_end",result_id=Ai_Turn_End_Result}
        result:Ai_Turn_End_Result
        call:=api.Call{method=&method,raw="{}",client_tag=tag,client_name=client,result=&result,allocator=context.temp_allocator}
        ai_method_turn_end(s,&call)
        return result
    }
    read(&method,&entry,"","")
    testing.expect(t,m.task_count==0 && m.next_id==-1,"a call without a turn or a client is of no agent")
    read(&method,&entry,"","claude-code")
    if !testing.expect_value(t,m.task_count,1) {return}
    task:=&m.tasks[0]
    defer ai_review_free(&task.review)
    testing.expect(t,ai_task_external(task) && task.state==.Running && base.text_get(task.title[:])=="Claude Code" && task.icon==AI_GLYPH_CLAUDE)
    testing.expect(t,m.next_id==task.id && task.transcript.count>0,"its calls are steps of its turn and its edits are of it")
    first:=strings.clone(base.text_get(task.name[:]),context.temp_allocator)
    // The hook of a Claude Code the editor runs ends nothing; a second end is the same end.
    testing.expect(t,!end(&s,"9-0","claude-code").ended && task.state==.Running)
    testing.expect(t,end(&s,"","claude-code").ended && task.state==.Done && task.review_finished,"a turn that changed nothing is done with")
    testing.expect(t,!end(&s,"","claude-code").ended)
    read(&method,&entry,"","claude-code")
    testing.expect(t,m.task_count==1 && task.state==.Running && base.text_get(task.name[:])!=first,"the next call is the next turn of its chat")
    // An end while its changes wait is not an answer: the next call opens the same turn again.
    append(&task.review.changed_ids,7)
    second:=strings.clone(base.text_get(task.name[:]),context.temp_allocator)
    testing.expect(t,end(&s,"","claude-code").ended && !task.review_finished && ai_task_reviewable(task))
    read(&method,&entry,"","claude-code")
    testing.expect(t,task.state==.Running && base.text_get(task.name[:])==second)
    // Stop on its row ends the turn, and so does a silence.
    testing.expect(t,ai_task_cancel(&s,m,task) && task.state==.Done && !task.stop)
    read(&method,&entry,"","claude-code")
    task.heard-=AI_EXTERNAL_IDLE+1
    ai_external_poll(&s,m)
    testing.expect(t,task.state==.Done)
    testing.expect_value(t,ai_task_retry(&s,m,task),"The turn of an agent outside the editor is asked again from that agent")
    read(&method,&entry,"","codex")
    testing.expect(t,m.task_count==2 && m.tasks[1].icon==AI_GLYPH_CODEX && m.tasks[1].id!=task.id,"another client has its own chat")
    defer ai_review_free(&m.tasks[1].review)
    // finish is not for an agent outside the editor: it ends its turn with ai.turn_end.
    finish :: proc(s:^Session,client,response:string,question:Api_Ai_Finish_Question) -> api.Call {
        method:=new(api.Method,context.temp_allocator)
        method^={name="finish",params_id=Api_Ai_Finish_Params,result_id=Api_Ai_Finish_Result}
        p:=new(Api_Ai_Finish_Params,context.temp_allocator)
        base.text_set(p.response[:],response)
        p.question=question
        result:=new(Api_Ai_Finish_Result,context.temp_allocator)
        call:=api.Call{method=method,raw="{}",client_name=client,params=p,result=result,allocator=context.temp_allocator}
        api_ai_finish(s,&call)
        return call
    }
    codex:=&m.tasks[1]
    testing.expect(t,finish(&s,"codex","Moved the box",.none).failed && codex.state==.Running)
    testing.expect(t,end(&s,"","codex").ended && codex.state==.Done)
}

@(test)
cancelled_turn_rejects_mcp_mutations_and_releases_an_unresponsive_worker :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    m.task_count=1
    task:=&m.tasks[0];task.id=1;task.state=.Running;task.started=time.tick_now()
    base.text_set(task.name[:],"1-0")
    worker:=&m.workers[0]
    testing.expect_value(t,acp.create(&worker.client,receive_bytes=512,send_bytes=512),acp.Error.None)
    defer acp.destroy(&worker.client)
    worker.created=true;worker.task=1;worker.client.phase=.Prompting
    app:host.App
    edits:history.Edits
    document:Document
    s:=Session{ai=m,app=&app,edits=&edits,document=&document,project_root=".mirai/missing-cancel-test"}
    m.permissions[0]={worker=0,count=1};m.permission_count=1
    base.text_set(m.permissions[0].request[:],`"permission-7"`)
    testing.expect(t,ai_task_cancel(&s,m,task))
    testing.expect(t,task.stop && task.state==.Running && worker.cancel_deadline>0)
    sent:=string(worker.client.tx[:worker.client.queued])
    testing.expect(t,m.permission_count==0 && strings.contains(sent,`"id":"permission-7"`) && strings.contains(sent,`"outcome":"cancelled"`),"stopping answers what the agent still asks")
    state:=Api_State{poll_temp=context.temp_allocator}
    entry:=Api_Entry{state=&state,session=&s,run=ai_cancel_test_mutation}
    method:=api.Method{name="scene.set"}
    call:=api.Call{method=&method,user=&entry,client_tag="1-0",allocator=context.temp_allocator}
    api_trampoline(&call)
    testing.expect(t,call.failed && m.next_id==0,"a cancelled turn cannot write while waiting for its provider")
    deadline:=worker.cancel_deadline
    testing.expect(t,!ai_cancel_expire(&s,m,worker,deadline-0.1) && worker.task==1)
    testing.expect(t,ai_cancel_expire(&s,m,worker,deadline+0.1))
    testing.expect(t,task.state==.Cancelled && worker.task==0 && worker.cancel_deadline==0 && worker.client.phase==.Stopped)
    testing.expect_value(t,ai_running_count(m),0)
}

@(test)
project_chat_restore_uses_the_latest_user_message_after_empty_visual_turns :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-empty-turns");if root=="" {return}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    testing.expect_value(t,ai_store.open(&m.store,root),"");defer ai_store.close(&m.store)
    document:Document
    s:=Session{ai=m,project_root=root,document=&document}
    m.task_count=1
    task:=&m.tasks[0]
    task.id=1;task.conversation.id=1;task.state=.Done;task.finish_called=true
    ai_store.conversation_set_text(task.conversation.title[:],&task.conversation.title_len,"Visual task")
    ai_transcript_add(&task.transcript,"Decorate the room",.Prompt)
    ai_transcript_add(&task.transcript,"Move the chair\nunder the window",.Prompt)
    base.text_set(task.name[:],"1-1")
    task.dirty=true;task.dirty_sequence=0;ai_task_persist(&s,task)
    testing.expect_value(t,ai_store.annotate(&m.store,1,0,"user","user_message","","{}"),"")
    testing.expect_value(t,ai_store.annotate(&m.store,1,1,"user","user_message","","{}"),"")
    restored:=new(Ai);defer free(restored);ai_connections_reset(restored)
    testing.expect_value(t,ai_store.open(&restored.store,root),"");defer ai_store.close(&restored.store)
    reopened:=Session{ai=restored,project_root=root,document=&document}
    loaded:=ai_conversation_restore(&reopened,&task.conversation)
    if !testing.expect(t,loaded!=nil) {return}
    defer ai_review_free(&loaded.review)
    testing.expect_value(t,base.text_get(loaded.name[:]),"1-1")
    message,error:=os.read_entire_file(ai_task_path(&reopened,loaded,AI_FILE_MESSAGE),context.temp_allocator)
    testing.expect(t,error==nil && string(message)=="Move the chair\nunder the window","the message of the turn comes back from the chat")
    testing.expect(t,loaded.review_finished && loaded.state==.Done && len(loaded.review.transactions)==0,"the review of a turn does not outlive the editor")
}

@(test)
retry_preserves_the_original_model_and_effort_when_connection_defaults_changed :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-retry");if root=="" {return}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    m.task_count=1
    task:=&m.tasks[0];task.id=1;task.state=.Done;task.review_finished=true
    base.text_set(task.name[:],"1-0")
    base.text_set(task.agent[:],"codex")
    ai_store.conversation_set_text(task.conversation.model[:],&task.conversation.model_len,"gpt-6-luna")
    ai_store.conversation_set_text(task.conversation.effort[:],&task.conversation.effort_len,"low")
    base.text_set(m.connections[AI_CODEX].model[:],"gpt-6-astra")
    base.text_set(m.connections[AI_CODEX].effort[:],"high")
    document:Document
    s:=Session{ai=m,document=&document,project_root=root}
    testing.expect(t,os.make_directory_all(ai_task_path(&s,task,""))==nil && os.write_entire_file(ai_task_path(&s,task,AI_FILE_MESSAGE),"Decorate this room")==nil)
    testing.expect_value(t,ai_task_retry(&s,m,task),"")
    testing.expect_value(t,string(m.prompt[:m.prompt_length]),"Decorate this room")
    testing.expect(t,m.pending && m.selected==1)
    testing.expect_value(t,base.text_get(m.pending_model[:]),"gpt-6-luna")
    testing.expect_value(t,base.text_get(m.pending_effort[:]),"low")
}

@(test)
failed_session_setup_stops_its_worker_and_completed_sessions_stay_warm :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    m.task_count=1
    task:=&m.tasks[0];task.id=1;task.started=time.tick_now()
    worker:=&m.workers[0]
    app:host.App
    edits:history.Edits
    s:=Session{ai=m,app=&app,edits=&edits,project_root=".mirai/missing-setup-test"}
    phases:=[4]acp.Phase{.Initialized,.Opening,.Configuring,.Failed}
    for phase in phases {
        task.state=.Running;worker.task=1;worker.client.phase=phase
        ai_task_end(&s,m,task,1)
        testing.expect(t,task.state==.Failed && worker.task==0 && worker.client.phase==.Stopped)
    }
    task.state=.Running;worker.task=1;worker.client.phase=.Ready
    ai_task_end(&s,m,task,0)
    testing.expect(t,task.state==.Done && worker.task==0 && worker.client.phase==.Ready)
}

@(test)
stale_session_updates_do_not_change_current_tasks_and_permissions_are_cancelled :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    m.task_count=1
    task:=&m.tasks[0];task.id=1;task.state=.Running
    // An agent whose permissions the user answers; those of Codex follow ai_permission_policy.
    worker:=&m.workers[0];worker.task=1;worker.provider=AI_CLAUDE
    testing.expect_value(t,acp.create(&worker.client,receive_bytes=512,send_bytes=512),acp.Error.None)
    defer acp.destroy(&worker.client)
    base.text_set(worker.client.session[:],"current-session")
    s:=Session{ai=m}
    callback:=Ai_Callback{session=&s,worker=worker}
    old_update,_:=json.parse_string(`{"sessionId":"previous-session","update":{"sessionUpdate":"tool_call","kind":"edit"}}`,allocator=context.temp_allocator)
    ai_acp_event(&callback,acp.Event{kind=.Update,value=old_update})
    testing.expect(t,task.heard==0)
    stale_permission,_:=json.parse_string(`{"sessionId":"previous-session","toolCall":{"title":"Previous edit"},"options":[{"optionId":"allow","name":"Allow"}]}`,allocator=context.temp_allocator)
    ai_acp_event(&callback,acp.Event{kind=.Permission,value=stale_permission,request_id="10"})
    testing.expect(t,m.permission_count==0 && strings.contains(string(worker.client.tx[:worker.client.queued]),`"outcome":"cancelled"`))
    current_update,_:=json.parse_string(`{"sessionId":"current-session","update":{"sessionUpdate":"tool_call","kind":"edit"}}`,allocator=context.temp_allocator)
    ai_acp_event(&callback,acp.Event{kind=.Update,value=current_update})
    testing.expect(t,task.heard>0)
    current_permission,_:=json.parse_string(`{"sessionId":"current-session","toolCall":{"title":"Current edit"},"options":[{"optionId":"allow","name":"Allow"}]}`,allocator=context.temp_allocator)
    ai_acp_event(&callback,acp.Event{kind=.Permission,value=current_permission,request_id="11"})
    testing.expect(t,m.permission_count==1 && base.text_get(m.permissions[0].title[:])=="Current edit")
    task.stop=true
    ai_acp_event(&callback,acp.Event{kind=.Permission,value=current_permission,request_id="12"})
    testing.expect(t,m.permission_count==1 && strings.contains(string(worker.client.tx[:worker.client.queued]),`"id":12`))
}

@(test)
the_usage_an_agent_reports_lands_in_its_conversation :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    m.task_count=1
    task:=&m.tasks[0];task.id=1;task.state=.Running;task.started=time.tick_now();task.finish_called=true
    worker:=&m.workers[0];worker.task=1;worker.provider=AI_CLAUDE
    testing.expect_value(t,acp.create(&worker.client,receive_bytes=512,send_bytes=512),acp.Error.None)
    defer acp.destroy(&worker.client)
    base.text_set(worker.client.session[:],"current-session")
    app:host.App
    edits:history.Edits
    s:=Session{ai=m,app=&app,edits=&edits,project_root=".mirai/missing-usage-test"}
    callback:=Ai_Callback{session=&s,worker=worker}
    update,_:=json.parse_string(`{"sessionId":"current-session","update":{"sessionUpdate":"usage_update","used":48000,"size":200000,"cost":{"amount":0.25,"currency":"USD"}}}`,allocator=context.temp_allocator)
    ai_acp_event(&callback,acp.Event{kind=.Update,value=update})
    u:=task.conversation.usage
    testing.expect(t,u.context_used==48000 && u.context_size==200000 && u.cost==0.25,"The context and the cost follow usage_update")
    done,_:=json.parse_string(`{"stopReason":"end_turn","usage":{"inputTokens":1200,"outputTokens":340,"cachedReadTokens":9000,"totalTokens":10540}}`,allocator=context.temp_allocator)
    ai_acp_event(&callback,acp.Event{kind=.Prompt_Done,value=done})
    u=task.conversation.usage
    testing.expect(t,u.input==1200 && u.output==340 && u.cache_read==9000 && u.total==10540,"The tokens come with the end of the turn")
    testing.expect(t,task.state==.Done && task.conversation.seconds>=0,"The turn adds its seconds to the conversation")
}
