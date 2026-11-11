package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:editor/ai_store"
import "mirai:project"
import "mirai:host"
import "mirai:platform"
import "mirai:editor/acp"
import "mirai:std/base"
import "mirai:third_party/sqlite"

@(test)
ai_stream_persists_before_cache_eviction_and_preserves_unicode :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-stream");if root=="" {return}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    testing.expect_value(t,ai_store.open(&m.store,root),"")
    defer ai_store.close(&m.store)
    task:=&m.tasks[0];task.id=1;task.conversation.id=1
    s:=Session{ai=m}
    chunk:=strings.concatenate({strings.repeat("a",1023,context.temp_allocator),"🙂é\n"},context.temp_allocator)
    expected:=200*(len(chunk)-1)
    for i in 0..<200 {ai_stream_add(&s,task,chunk)}
    ai_task_note(&s,task,"Retained")
    ai_task_persist(&s,task)
    testing.expect(t,task.transcript.dropped>0 && task.transcript.used<=AI_TRANSCRIPT_BYTES)
    total,notes:=0,0
    before:i64=-1
    for {
        lines:[128]ai_store.Stored_Line
        count,message:=ai_store.page(&m.store,1,before,lines[:])
        testing.expect_value(t,message,"")
        if count==0 {break}
        before=i64(lines[0].sequence)
        for line in lines[:count] {
            if line.kind==.Output {total+=len(line.text)} else if line.text=="Retained" {notes+=1}
            encoded,error:=json.marshal(line.text,{},context.temp_allocator)
            testing.expect(t,error==nil && len(encoded)>0)
        }
    }
    testing.expect_value(t,total,expected)
    testing.expect_value(t,notes,1)
}

@(test)
ai_connections_of_codex_and_claude_belong_to_the_machine_and_stay_lazy :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-lazy");if root=="" {return}
    // Two projects, or two worktrees of one, and one folder of the user.
    home:=project.path(root,"agents",allocator=context.temp_allocator)
    first,second:=project.path(root,"first",allocator=context.temp_allocator),project.path(root,"second",allocator=context.temp_allocator)
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    base.text_set(m.agents_home[:],home)
    m.initialized=true
    s:=Session{ai=m,project_root=first,has_project=true}
    ai_settings_initialize(&s)
    m.connections[AI_CODEX].installed=true
    base.text_set(m.connections[AI_CODEX].model[:],"gpt-6.1-sol")
    m.connections[AI_CODEX].configured=true
    testing.expect(t,ai_settings_save(&s))
    testing.expect(t,!m.workers[0].created && !ai_process_running(m))
    restored:=new(Ai);defer free(restored);ai_connections_reset(restored)
    base.text_set(restored.agents_home[:],home)
    other:=Session{ai=restored,project_root=second,has_project=true}
    ai_settings_initialize(&other)
    testing.expect(t,restored.connections[AI_CODEX].configured && !restored.workers[0].created && !ai_process_running(restored),"the connection is of the machine")
    testing.expect_value(t,base.text_get(restored.connections[AI_CODEX].model[:]),"gpt-6-luna")
    ai_task_fail(&m.tasks[0],"Connection error: account expired")
    testing.expect(t,m.connections[AI_CODEX].configured && m.tasks[0].state==.Failed)
    ai_connection_disconnect(&s,AI_CODEX)
    testing.expect(t,!m.connections[AI_CODEX].configured && m.connections[AI_CODEX].installed)
    // What an initialize announced is kept for the adapter it is of.
    base.text_set(m.connections[AI_CLAUDE].adapter[:],"/somewhere/claude-agent-acp")
    client:acp.Client
    client.resume_session,client.image,client.session_rename=true,true,true
    announced,_:=json.parse_string(`{"protocolVersion":1,"agentInfo":{"name":"claude-agent-acp","version":"0.80.0"}}`,allocator=context.temp_allocator)
    m.connections[AI_CLAUDE].user=true
    ai_agent_announced(&s,AI_CLAUDE,&client,announced)
    c:=&m.connections[AI_CLAUDE]
    testing.expect(t,c.known_capabilities=={.Resume,.Image,.Rename} && base.text_get(c.version[:])=="0.80.0")
    versions:=AI_AGENT_VERSIONS
    testing.expect_value(t,base.text_get(c.latest[:]),versions[.Claude])
    testing.expect(t,strings.has_prefix(ai_update_command(c,versions[.Claude]),"npm install -g @agentclientprotocol/claude-agent-acp@"))
    ai_settings_initialize(&other)
    testing.expect(t,restored.connections[AI_CLAUDE].known_capabilities=={.Resume,.Image,.Rename} && base.text_get(restored.connections[AI_CLAUDE].known_adapter[:])=="/somewhere/claude-agent-acp")
    testing.expect(t,ai_version_older("0.80.0","0.89.1") && !ai_version_older("0.89.1","0.89.1") && !ai_version_older("2.10.0","2.9.9"))
}

@(test)
ai_codex_models_are_restricted_and_tools_of_the_agent_are_steps_once_they_end :: proc(t:^testing.T) {
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    s:=Session{ai=m}
    testing.expect(t,ai_codex_model_supported("gpt-6-luna") && ai_codex_model_supported("gpt-6.1-sol") && ai_codex_model_supported("gpt-6-astra"))
    testing.expect(t,!ai_codex_model_supported("gpt-5") && !ai_codex_model_supported(""))
    testing.expect_value(t,ai_connection_configure(&s,AI_CODEX,"gpt-5","low"),"Unsupported Codex model")
    choices,_:=json.parse_string(`{"configOptions":[{"category":"model","options":[{"value":"gpt-5","name":"Other"},{"value":"gpt-6-luna","name":"Luna"},{"options":[{"value":"gpt-6-astra","name":"Astra"}]}]}]}`,allocator=context.temp_allocator)
    ai_model_choices(&s,AI_CODEX,choices)
    testing.expect_value(t,m.model_counts[AI_CODEX],2)
    m.task_count=1;m.tasks[0].id=1;m.workers[0].task=1
    base.text_set(m.workers[0].client.session[:],"current-session")
    callback:=Ai_Callback{session=&s,worker=&m.workers[0]}
    kinds:=[2]string{"tool_call","tool_call_update"}
    for kind in kinds {
        update,_:=json.parse_string(fmt.tprintf(`{{"sessionId":"current-session","update":{{"sessionUpdate":"%s","title":"Hidden tool","status":"failed"}}}}`,kind),allocator=context.temp_allocator)
        ai_acp_event(&callback,acp.Event{kind=.Update,value=update})
    }
    testing.expect_value(t,m.tasks[0].transcript.count,0)
    // A tool of the agent is a step when it ends, with its kind and its latest
    // title; one of the editor's MCP server is a step by the API already.
    events:=[?]string{
        `{"sessionId":"current-session","update":{"sessionUpdate":"tool_call","toolCallId":"a","kind":"execute","title":"Run","status":"pending"}}`,
        `{"sessionId":"current-session","update":{"sessionUpdate":"tool_call","toolCallId":"b","kind":"execute","title":"mcp.mirai.scene_add","status":"in_progress"}}`,
        `{"sessionId":"current-session","update":{"sessionUpdate":"tool_call_update","toolCallId":"a","title":"Run mirai build","status":"in_progress"}}`,
        `{"sessionId":"current-session","update":{"sessionUpdate":"tool_call_update","toolCallId":"b","status":"completed"}}`,
    }
    for text in events {
        update,_:=json.parse_string(text,allocator=context.temp_allocator)
        ai_acp_event(&callback,acp.Event{kind=.Update,value=update})
    }
    testing.expect_value(t,m.tasks[0].transcript.count,0)
    kind,title,running:=ai_tool_call_current(m,&m.tasks[0])
    testing.expect(t,running && kind=="execute" && title=="Run mirai build")
    update,_:=json.parse_string(`{"sessionId":"current-session","update":{"sessionUpdate":"tool_call_update","toolCallId":"a","status":"failed"}}`,allocator=context.temp_allocator)
    ai_acp_event(&callback,acp.Event{kind=.Update,value=update})
    testing.expect_value(t,m.tasks[0].transcript.count,1)
    text,_:=ai_transcript_line(&m.tasks[0].transcript,0)
    call,ok:=ai_call_parse(text)
    testing.expect(t,ok && call.failed && call.method=="execute" && call.target=="Run mirai build")
    _,_,running=ai_tool_call_current(m,&m.tasks[0])
    testing.expect(t,!running)
}

when ODIN_OS!=.Windows {
    @(test)
    codex_is_asked_for_the_sign_in_of_the_user_and_mirai_signs_in_to_nothing :: proc(t:^testing.T) {
        // A Codex of the user in PATH would answer instead of the one of the test.
        if program,_:=ai_user_program("codex","@openai/codex");program!="" {return}
        root:=base.test_folder(t,"ai-login");if root=="" {return}
        m:=new(Ai);defer free(m);ai_connections_reset(m)
        base.text_set(m.agents_home[:],project.path(root,"agents",allocator=context.temp_allocator))
        folder:=ai_agents_folder(m,"codex")
        testing.expect(t,os.make_directory_all(folder)==nil)
        executable:=project.path(folder,"test-codex",allocator=context.temp_allocator)
        script:=`#!/bin/sh
test "$1" = login || exit 1
test "$2" = status || exit 2
test -f "$PWD/signed-in" || exit 1
printf 'Logged in using ChatGPT\n'
exit 0
`
        testing.expect(t,os.write_entire_file(executable,script)==nil)
        testing.expect(t,os.chmod(executable,{.Read_User,.Write_User,.Execute_User})==nil)
        testing.expect(t,os.write_entire_file(project.path(folder,"installation.json",allocator=context.temp_allocator),string(`{"codex_binary":"test-codex"}`))==nil)
        p,error:=platform.create({headless=true,process_capacity=2})
        testing.expect_value(t,error,platform.Error.None);if p==nil {return}
        defer platform.destroy(p)
        m.initialized=true;m.connections[AI_CODEX].installed=true
        app:=host.App{platform=p}
        s:=Session{ai=m,app=&app,project_root=root,has_project=true}
        defer ai_destroy(&s)
        wait :: proc(s:^Session) {
            until:=platform.clock_seconds()+5
            for s.ai.login_process!=0 && platform.clock_seconds()<until {ai_login_poll(s);platform.sleep_coarse(1_000_000)}
        }
        testing.expect_value(t,ai_login_start(&s,AI_CODEX),"")
        testing.expect(t,m.login && m.login_process!=0 && !m.workers[0].created && !ai_process_running(m))
        wait(&s)
        testing.expect(t,!m.connections[AI_CODEX].configured && strings.contains(base.text_get(m.connection_ui.error[:]),"login\" in a terminal"),"without a sign-in the user is told to sign in")
        testing.expect(t,os.write_entire_file(project.path(root,"signed-in",allocator=context.temp_allocator),"")==nil)
        testing.expect_value(t,ai_login_start(&s,AI_CODEX),"")
        wait(&s)
        testing.expect(t,m.login_process==0 && !m.login && m.connections[AI_CODEX].configured)
        testing.expect(t,!os.exists(project.path(root,".mirai","ai","codex-account",allocator=context.temp_allocator)),"no account of its own")
    }
}

when ODIN_OS!=.Windows {
    @(test)
    ai_agents_added_by_command_are_saved_started_with_their_arguments_and_removed :: proc(t:^testing.T) {
        root:=base.test_folder(t,"ai-command");if root=="" {return}
        testing.expect(t,os.make_directory_all(root)==nil)
        // An agent that checks its arguments and answers initialize.
        executable:=project.path(root,"test-agent",allocator=context.temp_allocator)
        script:=`#!/bin/sh
test "$1" = --acp || exit 1
test "$2" = --quiet || exit 2
read line
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}'
cat >/dev/null
`
        testing.expect(t,os.write_entire_file(executable,script)==nil)
        testing.expect(t,os.chmod(executable,{.Read_User,.Write_User,.Execute_User})==nil)
        p,error:=platform.create({headless=true,process_capacity=2})
        testing.expect_value(t,error,platform.Error.None);if p==nil {return}
        defer platform.destroy(p)
        m:=new(Ai);defer free(m)
        base.text_set(m.agents_home[:],project.path(root,"agents",allocator=context.temp_allocator))
        app:=host.App{platform=p,allocator=context.allocator}
        s:=Session{ai=m,app=&app,project_root=root,has_project=true}
        defer ai_destroy(&s)
        m.initialized=true;ai_settings_initialize(&s)
        provider,message:=ai_connection_add(&s,"My Agent",executable,"--acp  --quiet")
        testing.expect_value(t,message,"")
        testing.expect(t,provider==Ai_Provider(2) && ai_connection_id(m,provider)=="my-agent" && m.connections[provider].agent==.Command)
        testing.expect(t,m.connections[provider].installed && m.connections[provider].argument_count==2)
        _,message=ai_connection_add(&s,"my agent","sh","")
        testing.expect(t,message!="","the id of a name is taken once")
        _,message=ai_connection_add(&s,"Codex","sh","")
        testing.expect(t,message!="","Codex keeps its own connection")
        testing.expect_value(t,ai_connection_set(&s,provider,true),"")
        // The settings keep it as it was added.
        restored:=new(Ai);defer free(restored)
        restored.agents_home=m.agents_home
        other:=Session{ai=restored,app=&app,project_root=root,has_project=true}
        restored.initialized=true;ai_settings_initialize(&other)
        found,known:=ai_provider_find(restored,"my-agent")
        testing.expect(t,known && found==provider && restored.connections[found].configured && restored.connections[found].agent==.Command)
        testing.expect(t,base.text_get(restored.connections[found].command[:])==executable && base.text_get(restored.connections[found].arguments[1][:])=="--quiet")
        // It starts as its command with its arguments.
        testing.expect_value(t,ai_start_client(&s,&m.workers[0],provider),"")
        until:=platform.clock_seconds()+5
        for m.workers[0].client.phase!=.Initialized && platform.clock_seconds()<until {
            acp.poll(&m.workers[0].client,p,nil,nil)
            platform.sleep_coarse(1_000_000)
        }
        testing.expect_value(t,m.workers[0].client.phase,acp.Phase.Initialized)
        testing.expect(t,ai_install_start(&s,"download",provider,.Automatic)!="","Mirai does not install it")
        testing.expect_value(t,ai_connection_remove(&s,provider),"")
        testing.expect_value(t,m.connection_count,2)
        testing.expect(t,ai_connection_remove(&s,AI_CLAUDE)!="","Codex and Claude stay")
        ai_settings_initialize(&other)
        _,known=ai_provider_find(restored,"my-agent")
        testing.expect(t,!known && restored.connection_count==2)
    }
}

@(test)
codex_turns_may_call_the_editor_and_nothing_else_is_asked_of_the_user :: proc(t:^testing.T) {
    parse :: proc(text:string) -> json.Value {
        value,_:=json.parse_string(text,allocator=context.temp_allocator)
        return value
    }
    // A tool of `mirai` runs.
    option,allow:=ai_permission_choice(parse(`{"_meta":{"is_mcp_tool_approval":true},"options":[{"optionId":"allow","kind":"allow_once"},{"optionId":"cancel","kind":"reject_once"}]}`))
    testing.expect(t,allow && option=="allow")
    // A command outside the sandbox, or a file outside the project, is declined.
    option,allow=ai_permission_choice(parse(`{"toolCall":{"title":"Edit ../engine/core.odin"},"options":[{"optionId":"approved","kind":"allow_once"},{"optionId":"denied","kind":"reject_once"}]}`))
    testing.expect(t,!allow && option=="denied")
    // Without an option to decline, the request is cancelled.
    option,allow=ai_permission_choice(parse(`{"options":[{"optionId":"approved","kind":"allow_once"}]}`))
    testing.expect(t,!allow && option=="")
}

@(test)
the_plan_the_agent_reports_replaces_the_one_before :: proc(t:^testing.T) {
    parse :: proc(text:string) -> json.Value {
        value,_:=json.parse_string(text,allocator=context.temp_allocator)
        return value
    }
    task:=new(Ai_Task);defer free(task)
    ai_plan_receive(task,parse(`{"sessionUpdate":"plan","entries":[{"content":"Read the scene","priority":"high","status":"completed"},{"content":"  ","status":"pending"},{"content":"Move the lamp\nand more","status":"in_progress"},{"content":"Check the light","status":"pending"}]}`))
    testing.expect_value(t,task.plan_count,3)
    testing.expect(t,base.text_get(task.plan[0].text[:])=="Read the scene" && task.plan[0].status==.Completed)
    testing.expect(t,base.text_get(task.plan[1].text[:])=="Move the lamp" && task.plan[1].status==.In_Progress,"an entry shows its first line")
    testing.expect(t,task.plan[2].status==.Pending)
    long:=strings.repeat("é",AI_PLAN_BYTES,context.temp_allocator)
    ai_plan_receive(task,parse(strings.concatenate({`{"entries":[{"content":"`,long,`","status":"done"}]}`},context.temp_allocator)))
    testing.expect_value(t,task.plan_count,1)
    text:=base.text_get(task.plan[0].text[:])
    testing.expect(t,len(text)<AI_PLAN_BYTES && len(text)%2==0 && task.plan[0].status==.Pending,"a long entry is cut between characters and an unknown status is pending")
    ai_plan_receive(task,parse(`{"entries":[]}`))
    testing.expect_value(t,task.plan_count,0)
}

@(test)
the_capture_of_a_turn_is_saved_at_half_size :: proc(t:^testing.T) {
    // Four pixels of 2x2 become one, their mean, channel by channel.
    pixels:=[]u8{0,0,0,255, 100,0,0,255, 0,200,0,255, 100,200,40,255, 9,9,9,9, 9,9,9,9, 9,9,9,9, 9,9,9,9}
    out:[8]u8
    ai_half_pixels(pixels[:16],2,2,out[:4])
    testing.expect_value(t,[4]u8{out[0],out[1],out[2],out[3]},[4]u8{50,100,10,255})
    // An odd last row or column is left out.
    wide:=[]u8{10,10,10,10, 30,30,30,30, 50,50,50,50, 10,10,10,10, 30,30,30,30, 50,50,50,50}
    ai_half_pixels(wide,3,2,out[:4])
    testing.expect_value(t,out[0],u8(20))
}

// A turn whose agent says nothing after its prompt says so once, and a failure
// shows the last line the agent printed.
@(test)
ai_turns_say_when_the_agent_is_silent_and_what_it_printed :: proc(t:^testing.T) {
    s:Session
    task:Ai_Task
    task.state=.Running
    task.heard=10
    ai_task_silence(&s,&task,10+AI_SILENT_SECONDS-1)
    testing.expect_value(t,task.transcript.count,0)
    ai_task_silence(&s,&task,10+AI_SILENT_SECONDS)
    ai_task_silence(&s,&task,10+AI_SILENT_SECONDS*2)
    testing.expect_value(t,task.transcript.count,1)
    text,kind:=ai_transcript_line(&task.transcript,0)
    testing.expect(t,kind==.Note && strings.contains(text,"has not answered for 120 s"),text)
    ai_said_keep(&task,"INFO starting\nERROR stream disconnected: 401 Unauthorized\n\n")
    ai_said_keep(&task,"   \n")
    testing.expect_value(t,base.text_get(task.said[:]),"ERROR stream disconnected: 401 Unauthorized")
    info,_:=json.parse_string(`{"_meta":{"codex":{"error":{"message":"Reconnecting... 2/5","additionalDetails":"stream disconnected before completion: idle timeout waiting for SSE","willRetry":true}}}}`,allocator=context.temp_allocator)
    ai_task_agent_error(&s,&task,acp.at(info,"_meta","codex","error"),500)
    ai_task_agent_error(&s,&task,acp.at(info,"_meta","codex","nothing"),600)
    testing.expect(t,task.transcript.count==2 && task.heard==500 && !task.silent)
    text,kind=ai_transcript_line(&task.transcript,1)
    testing.expect_value(t,text,"The agent reported: Reconnecting... 2/5 (stream disconnected before completion: idle timeout waiting for SSE)")
}

@(test)
ai_history_search_feeds_by_title_or_by_what_chats_said :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-history-search");if root=="" {return}
    m:=new(Ai);defer free(m)
    document:=new(Document);defer free(document)
    document.path_length=copy(document.path[:],"scene/main.scene")
    s:=Session{ai=m,document=document}
    defer ai_store.close(&m.store)
    testing.expect_value(t,ai_store.open(&m.store,root),"")
    titled:=ai_store.Conversation{id=1,kind=.Agent,created_at=100,updated_at=200}
    ai_store.conversation_set_text(titled.title[:],&titled.title_len,"Lanterns of the harbor")
    said:=ai_store.Conversation{id=2,kind=.Agent,created_at=100,updated_at=200}
    ai_store.conversation_set_text(said.title[:],&said.title_len,"Player questions")
    transcript:=new(Ai_Transcript,context.temp_allocator)
    ai_transcript_add(transcript,"Light the pier",.Prompt)
    ai_transcript_add(transcript,"Hung a [lantern](entity:0x2a) on the pier.",.Output)
    testing.expect_value(t,ai_transcript_save(&m.store,&said,transcript),"")
    testing.expect_value(t,string(said.last[:said.last_len]),"Hung a lantern on the pier.")
    transcript^={}
    ai_transcript_add(transcript,"Name the boats",.Prompt)
    testing.expect_value(t,ai_transcript_save(&m.store,&titled,transcript),"")
    ai_history_refresh(m,0,"lant")
    testing.expect_value(t,m.history_count,2)
    for &c in m.history[:m.history_count] {
        last:=string(c.last[:c.last_len])
        if c.id==2 {testing.expectf(t,strings.contains(last,"Hung a lantern on the pier"),"a chat found by its lines shows what matched, got %q",last)}
    }
    ai_history_refresh(m,0,"boats")
    testing.expect(t,m.history_count==1 && m.history[0].id==1)
    ai_history_refresh(m,0,"·")
    testing.expect_value(t,m.history_count,0)
}

@(test)
ai_stream_does_not_wait_for_another_editor_and_loses_no_line :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-stream-busy");if root=="" {return}
    m:=new(Ai);defer free(m);ai_connections_reset(m)
    testing.expect_value(t,ai_store.open(&m.store,root),"")
    defer ai_store.close(&m.store)
    m.task_count=1
    task:=&m.tasks[0];task.id=1;task.conversation.id=1
    s:=Session{ai=m}
    // Another editor of the project, in a write that does not end.
    other:^sqlite.Db
    path:=strings.clone_to_cstring(project.path(root,".mirai/ai/chat.db",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,sqlite.open_v2(path,&other,sqlite.OPEN_READWRITE|sqlite.OPEN_NOMUTEX,nil)==sqlite.OK)
    defer sqlite.close_v2(other)
    testing.expect(t,sqlite.exec(other,"BEGIN IMMEDIATE",nil,nil,nil)==sqlite.OK)

    // An answer long enough for the transcript to forget lines the database does not have yet.
    chunk:=strings.concatenate({strings.repeat("a",1023,context.temp_allocator),"\n"},context.temp_allocator)
    started:=time.tick_now()
    now:=f64(1)
    for i in 0..<200 {
        ai_stream_add(&s,task,fmt.tprintf("%04d%s",i,chunk))
        now+=AI_FLUSH_SECONDS
        ai_persist_poll(&s,m,now)
    }
    testing.expect(t,time.tick_since(started)<ai_store.OPEN_BUSY_MS*time.Millisecond/2,"the frames did not wait for the other editor")
    testing.expect(t,task.transcript.dropped>0 && ai_store.pending(&m.store)>0)
    testing.expect_value(t,s.toast_length,0)
    lines:=make([]ai_store.Stored_Line,400,context.temp_allocator)
    count,_:=ai_store.page(&m.store,1,-1,lines)
    testing.expect_value(t,count,0)

    testing.expect(t,sqlite.exec(other,"COMMIT",nil,nil,nil)==sqlite.OK)
    ai_persist_poll(&s,m,now+AI_FLUSH_SECONDS)
    testing.expect(t,ai_store.pending(&m.store)==0 && !task.dirty)
    count,_=ai_store.page(&m.store,1,-1,lines)
    testing.expect_value(t,count,400)
    for line,index in lines[:count] {
        // Each chunk is two lines: its number with what fits of it, and its last characters.
        if line.sequence!=u64(index) || index%2==0 && !strings.has_prefix(line.text,fmt.tprintf("%04d",index/2)) {
            testing.expectf(t,false,"line %d of the answer was lost or changed place",index)
            break
        }
    }
}
