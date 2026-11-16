package editor

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:editor/acp"
import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

@(test)
finish_typed_results_work_through_rpc_and_mcp_dispatch :: proc(t:^testing.T) {
    temporary:=context.temp_allocator
    defer {context.temp_allocator=temporary}
    m:=new(Ai);defer free(m)
    s:=Session{ai=m}
    m.task_count,m.workers[0].task=1,7
    task:=&m.tasks[0];task.id=7;task.state=.Running
    base.text_set(task.name[:],"7-0")
    state:=new(Api_State);defer free(state)
    state.poll_temp=temporary
    if !testing.expect_value(t,api.server_init(&state.server,{port=0,max_methods=4,max_connections=1,max_request=16*1024,max_response=4096,scratch=128*1024}),api.Init_Error.None) {return}
    defer api.server_destroy(&state.server)
    api_ai_finish_register(&s,state)
    method:=api.method_find(&state.server,"finish")
    if !testing.expect(t,method!=nil && method.result_id==Api_Ai_Finish_Result) {return}
    request:=`{"jsonrpc":"2.0","id":1,"method":"finish","params":{}}`
    testing.expect(t,api.process(&state.server,request,.Rpc))
    testing.expect(t,!task.finish_called,"finish outside a turn finishes nothing")
    state.server.out.count=0
    testing.expect(t,api.process(&state.server,request,.Rpc,"7-0"))
    rpc:struct {result:Api_Ai_Finish_Result}
    testing.expect(t,json.unmarshal(serial.writer_bytes(&state.server.out),&rpc,allocator=temporary)==nil)
    testing.expect_value(t,rpc.result,Api_Ai_Finish_Result{accepted=true})
    testing.expect(t,task.finish_called && task.state==.Running && finish_answer(task)=="","normal RPC dispatch handles a typed result without a free-form writer")
    task.finish_called=false
    state.server.out.count=0
    request=`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"finish","arguments":{"response":"The cube is blue."}}}`
    testing.expect(t,api.process(&state.server,request,.Mcp,"7-0"))
    mcp:struct {result:struct {content:[]struct {type,text:string},isError:bool}}
    if !testing.expect(t,json.unmarshal(serial.writer_bytes(&state.server.out),&mcp,allocator=temporary)==nil && !mcp.result.isError && len(mcp.result.content)==1) {return}
    result:Api_Ai_Finish_Result
    testing.expect(t,json.unmarshal(transmute([]u8)mcp.result.content[0].text,&result,allocator=temporary)==nil)
    testing.expect_value(t,result,Api_Ai_Finish_Result{accepted=true})
    testing.expect(t,task.finish_called && task.state==.Running)
    testing.expect_value(t,finish_answer(task),"The cube is blue.")
}

// The answers of a turn, one after another: the steps of its calls are notes.
@(private="file")
finish_answer :: proc(task:^Ai_Task) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for i in 0..<task.transcript.count {
        if text,kind:=ai_transcript_line(&task.transcript,i);kind==.Output {strings.write_string(&b,text)}
    }
    return strings.to_string(b)
}

@(test)
finish_writes_only_the_final_answer_and_waits_for_acp_completion :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-finish");if root=="" {return}
    m:=new(Ai);defer free(m)
    testing.expect_value(t,ai_store.open(&m.store,root),"");defer ai_store.close(&m.store)
    app:host.App
    edits:history.Edits
    s:=Session{ai=m,app=&app,edits=&edits,project_root=root}
    task:=&m.tasks[0]
    m.task_count,m.workers[0].task,m.selected=2,1,1;m.chat_open=true
    base.text_set(m.workers[0].client.session[:],"current-session")
    callback:=Ai_Callback{session=&s,worker=&m.workers[0]}
    task.id=1;task.conversation.id=1;task.state=.Running;task.started=time.tick_now()
    m.tasks[1].id=2;m.tasks[1].state=.Queued
    base.text_set(task.name[:],"1-0");base.text_set(m.tasks[1].name[:],"2-0")
    ai_transcript_add(&task.transcript,"Move the cube",.Prompt)
    chatter,_:=json.parse_string(`{"sessionId":"current-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"This chatter must stay hidden"}}}`,allocator=context.temp_allocator)
    ai_acp_event(&callback,acp.Event{kind=.Update,value=chatter})
    testing.expect_value(t,task.transcript.count,1)
    params:=Api_Ai_Finish_Params{}
    method:=api.Method{params_id=Api_Ai_Finish_Params,result_id=Api_Ai_Finish_Result}
    result:Api_Ai_Finish_Result
    call:=api.Call{method=&method,params=&params,result=&result,client_tag="2-0",allocator=context.temp_allocator}
    api_ai_finish(&s,&call)
    testing.expect(t,call.failed && !task.finish_called && !m.tasks[1].finish_called && result=={},"a turn that does not run cannot finish")
    call.client_tag="1-0"
    call.failed=false;call.error={}
    api_ai_finish(&s,&call)
    testing.expect(t,!call.failed && result==Api_Ai_Finish_Result{accepted=true} && call.out==nil,"a typed result succeeds without a free-form writer")
    testing.expect(t,task.finish_called && task.state==.Running && m.workers[0].task==1,"finish requests completion but does not mark the task done")
    testing.expect_value(t,task.transcript.count,1)
    ai_acp_event(&callback,acp.Event{kind=.Update,value=chatter})
    testing.expect_value(t,task.transcript.count,1)
    result={}
    api_ai_finish(&s,&call)
    testing.expect(t,call.failed && result=={} && task.transcript.count==1,"a repeated finish cannot add a second answer")
    ai_acp_event(&callback,acp.Event{kind=.Prompt_Done})
    testing.expect(t,task.state==.Done && m.workers[0].task==0)
    task.state=.Running;task.finish_called=false;task.started=time.tick_now();m.workers[0].task=1
    base.text_set(params.response[:],"The player's health is 100.")
    call.failed=false;call.error={}
    api_ai_finish(&s,&call)
    testing.expect(t,!call.failed && task.state==.Running)
    testing.expect_value(t,task.transcript.count,2)
    text,kind:=ai_transcript_line(&task.transcript,1)
    testing.expect(t,text=="The player's health is 100." && kind==.Output)
    ai_acp_event(&callback,acp.Event{kind=.Update,value=chatter})
    testing.expect_value(t,task.transcript.count,2)
    saved:[8]ai_store.Stored_Line
    count,message:=ai_store.page(&m.store,1,-1,saved[:])
    testing.expect(t,message=="" && count==2 && saved[1].role=="assistant" && saved[1].text==text,"the finish answer is saved as assistant content")
    ai_acp_event(&callback,acp.Event{kind=.Prompt_Done})
    testing.expect(t,task.state==.Done && m.workers[0].task==0)
    task.state=.Running;task.finish_called=false;task.started=time.tick_now();m.workers[0].task=1
    call.failed=false;call.error={};result={}
    for &byte in params.response {byte='a'}
    api_ai_finish(&s,&call)
    testing.expect(t,call.failed && !task.finish_called && result=={} && task.transcript.count==2,"an oversized answer cannot partially finish the task")
    params.response={};params.response[0]=0xff
    call.failed=false;call.error={}
    api_ai_finish(&s,&call)
    testing.expect(t,call.failed && !task.finish_called && task.transcript.count==2,"invalid UTF-8 cannot enter the chat")
}

@(test)
finish_ends_the_turn_its_tag_names_and_no_other :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m)
    app:host.App
    edits:history.Edits
    s:=Session{ai=m,app=&app,edits=&edits}
    m.task_count=2
    for &task,index in m.tasks[:m.task_count] {
        task.id=index+1;task.state=.Running;task.started=time.tick_now()
        base.text_format(task.name[:],"%d-0",task.id)
        m.workers[index].task=task.id
    }
    method:=api.Method{params_id=Api_Ai_Finish_Params,result_id=Api_Ai_Finish_Result}
    params:Api_Ai_Finish_Params
    result:Api_Ai_Finish_Result
    call:=api.Call{method=&method,params=&params,result=&result,client_tag="9-0",allocator=context.temp_allocator}
    api_ai_finish(&s,&call)
    testing.expect(t,call.failed && !m.tasks[0].finish_called && !m.tasks[1].finish_called,"a turn that is not there finishes nothing")
    call.client_tag="1-0";call.failed=false;call.error={}
    base.text_set(params.response[:],"The player is beside the crate.")
    api_ai_finish(&s,&call)
    testing.expect(t,!call.failed && m.tasks[0].finish_called && !m.tasks[1].finish_called)
    params.response={};call.client_tag="2-0";call.failed=false;call.error={};result={}
    api_ai_finish(&s,&call)
    testing.expect(t,!call.failed && m.tasks[1].finish_called && m.tasks[1].transcript.count==0,"a visible task finishes without text while another question has an answer")
    second:=Ai_Callback{session=&s,worker=&m.workers[1]}
    ai_acp_event(&second,{kind=.Prompt_Done})
    testing.expect(t,m.tasks[1].state==.Done && m.workers[1].task==0 && m.tasks[0].state==.Running && m.workers[0].task==1,"one ACP completion releases only its own worker")
    first:=Ai_Callback{session=&s,worker=&m.workers[0]}
    ai_acp_event(&first,{kind=.Prompt_Done})
    testing.expect(t,m.tasks[0].state==.Done && ai_running_count(m)==0)
}

@(test)
finish_is_required_and_acp_errors_and_cancellation_remain_visible :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m)
    app:host.App
    edits:history.Edits
    s:=Session{ai=m,app=&app,edits=&edits,project_root=".mirai/missing-ai-finish-project"}
    m.task_count,m.selected=1,1;m.chat_open=true
    task:=&m.tasks[0];task.id=1;task.conversation.id=1
    callback:=Ai_Callback{session=&s,worker=&m.workers[0]}
    reset :: proc(m:^Ai,task:^Ai_Task) {
        task.state=.Running;task.stop=false;task.finish_called=false
        task.started=time.tick_now();task.transcript={};m.workers[0].task=task.id
    }
    reset(m,task)
    ai_acp_event(&callback,acp.Event{kind=.Prompt_Done})
    testing.expect(t,task.state==.Failed && m.workers[0].task==0 && task.exit_code!=0)
    text,kind:=ai_transcript_line(&task.transcript,0)
    testing.expect(t,kind==.Note && strings.contains(text,"without calling finish"))
    reset(m,task)
    task.finish_called=true
    ai_acp_event(&callback,acp.Event{kind=.Error,text="Account expired"})
    testing.expect(t,task.state==.Failed && task.exit_code!=0)
    text,kind=ai_transcript_line(&task.transcript,0)
    testing.expect(t,kind==.Note && strings.contains(text,"Account expired"))
    reset(m,task)
    task.stop=true
    ai_acp_event(&callback,acp.Event{kind=.Prompt_Done})
    testing.expect(t,task.state==.Cancelled && m.workers[0].task==0)
    text,kind=ai_transcript_line(&task.transcript,0)
    testing.expect(t,kind==.Note && text=="Cancelled")
    reset(m,task)
    ai_acp_event(&callback,acp.Event{kind=.Exited})
    testing.expect(t,task.state==.Failed && m.workers[0].task==0)
    text,kind=ai_transcript_line(&task.transcript,0)
    testing.expect(t,kind==.Note && strings.contains(text,"exited before completing"))
}

@(test)
finish_asks_the_user_with_its_kind_and_its_choices :: proc(t:^testing.T) {
    temporary:=context.temp_allocator
    defer {context.temp_allocator=temporary}
    m:=new(Ai);defer free(m)
    s:=Session{ai=m}
    m.task_count,m.workers[0].task=1,7
    task:=&m.tasks[0];task.id=7;task.state=.Running
    base.text_set(task.name[:],"7-0")
    state:=new(Api_State);defer free(state)
    state.poll_temp=temporary
    if !testing.expect_value(t,api.server_init(&state.server,{port=0,max_methods=4,max_connections=1,max_request=16*1024,max_response=16*1024,scratch=128*1024}),api.Init_Error.None) {return}
    defer api.server_destroy(&state.server)
    api_ai_finish_register(&s,state)
    failed :: proc(state:^Api_State,request:string) -> bool {
        state.server.out.count=0
        api.process(&state.server,request,.Rpc,"7-0")
        return strings.contains(string(serial.writer_bytes(&state.server.out)),`"error"`)
    }
    testing.expect(t,failed(state,`{"jsonrpc":"2.0","id":1,"method":"finish","params":{"question":"maybe","response":"?"}}`),"the kind is one of the four")
    testing.expect(t,failed(state,`{"jsonrpc":"2.0","id":2,"method":"finish","params":{"question":"single","options":["A","B"]}}`),"a question needs its text")
    testing.expect(t,failed(state,`{"jsonrpc":"2.0","id":3,"method":"finish","params":{"question":"single","response":"Which one?"}}`),"single needs choices")
    testing.expect(t,failed(state,`{"jsonrpc":"2.0","id":4,"method":"finish","params":{"question":"confirm","response":"Delete it?","options":["A"]}}`),"confirm takes no choices")
    testing.expect(t,failed(state,`{"jsonrpc":"2.0","id":5,"method":"finish","params":{"question":"single","response":"Which one?","options":["A
B"]}}`),"an option is one line")
    testing.expect(t,!task.finish_called && task.question==.None)
    // What an agent sees: the kinds by name and the choices as a list of strings; outside a turn, no finish.
    state.server.out.count=0
    api.process(&state.server,`{"jsonrpc":"2.0","id":6,"method":"tools/list"}`,.Mcp)
    testing.expect(t,!strings.contains(string(serial.writer_bytes(&state.server.out)),`"finish"`),"only the turn of an agent of the editor lists finish")
    state.server.out.count=0
    api.process(&state.server,`{"jsonrpc":"2.0","id":6,"method":"tools/list"}`,.Mcp,"7-0")
    tools:=string(serial.writer_bytes(&state.server.out))
    testing.expect(t,strings.contains(tools,`\"enum\":[\"none\",\"text\",\"single\",\"multi\",\"confirm\"]`) || strings.contains(tools,`"enum":["none","text","single","multi","confirm"]`),"question lists its kinds")
    testing.expect(t,strings.contains(tools,`"items":{"type":"string"`),"options is a list of strings")
    state.server.out.count=0
    request:=`{"jsonrpc":"2.0","id":7,"method":"finish","params":{"question":"multi","response":"Which ones should I align?","options":["Cube","Sphere","","Light"]}}`
    testing.expect(t,api.process(&state.server,request,.Rpc,"7-0"))
    testing.expect(t,task.finish_called && task.question==.Multi)
    options:[AI_QUESTION_OPTIONS][]u8
    count:=ai_question_options(task,options[:])
    testing.expect_value(t,count,3)
    testing.expect_value(t,string(options[0]),"Cube")
    testing.expect_value(t,string(options[2]),"Light")
    testing.expect(t,finish_answer(task)=="Which ones should I align?","the question is the answer of the turn")
    // The glyph of a conversation that asks is its own, not the one of a result.
    testing.expect(t,ai_agent_icon(task)!=ui.icon_user(u8(User_Icon.Agent_Star)) && ai_agent_icon(task)==ui.icon_user(u8(User_Icon.Agent_Star_Ask)))
}

@(test)
a_turn_cannot_quit_the_editor_nor_replace_the_document :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m)
    s:=Session{ai=m}
    m.task_count=1
    task:=&m.tasks[0];task.id=4;task.state=.Running
    base.text_set(task.name[:],"4-0")
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    load:=Api_Path_Params{}
    fresh:=Api_Scene_New_Params{}
    calls:=[3]struct{run:Api_Handler,params:rawptr,type:typeid}{{api_shutdown,nil,nil},{api_scene_open,&load,Api_Path_Params},{api_scene_new,&fresh,Api_Scene_New_Params}}
    for c in calls {
        method:=api.Method{params_id=c.type}
        call:=api.Call{method=&method,params=c.params,out=&out,allocator=context.temp_allocator,client_tag="4-0"}
        c.run(&s,&call)
        testing.expect(t,call.failed && strings.contains(call.error.message,"A turn of an AI agent cannot"),"the agent has to ask the user")
    }
    testing.expect(t,!s.quit,"the editor goes on")
}
