package acp

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:platform"

when ODIN_OS==.Windows {TEST_CWD :: "C:/project"} else {TEST_CWD :: "/project"}

Test_Events :: struct {
    counts:[Event_Kind]int,
    text,request_id,session_id,update:[1024]u8,
    replay:bool,
    code,steer_id:int,
}

collect :: proc(user:rawptr,event:Event) {
    events:=cast(^Test_Events)user
    events.counts[event.kind]+=1
    events.code=event.code;events.replay=event.replay;events.steer_id=event.steer_id
    text_set(events.text[:],event.text)
    text_set(events.request_id[:],event.request_id)
    text_set(events.session_id[:],text(at(event.value,"sessionId")))
    text_set(events.update[:],text(at(event.value,"update","content","text")))
}

text_set :: proc(buffer:[]u8,value:string) {
    for &byte in buffer {byte=0}
    if len(buffer)>0 {copy(buffer[:len(buffer)-1],value)}
}

test_client :: proc(t:^testing.T,receive_bytes:=2*1024*1024,send_bytes:=4*1024*1024) -> Client {
    client:Client
    error:=create(&client,receive_bytes=receive_bytes,send_bytes=send_bytes)
    testing.expect_value(t,error,Error.None)
    return client
}

test_message :: proc(t:^testing.T,text:string) -> json.Value {
    value,error:=json.parse_string(text,parse_integers=true,allocator=context.temp_allocator)
    testing.expectf(t,error==.None,"JSON parse error %v: %s",error,text)
    return value
}

test_queued :: proc(t:^testing.T,c:^Client) -> json.Value {
    line:=strings.trim_space(string(c.tx[c.sent:c.queued]))
    value:=test_message(t,line)
    c.queued,c.sent=0,0
    return value
}

@(test)
acp_fragments_negotiate_capabilities_and_preserve_utf8_updates :: proc(t:^testing.T) {
    c:=test_client(t)
    defer destroy(&c,nil)
    events:Test_Events
    c.pending=.Initialize;c.pending_id=1;c.phase=.Initializing
    first:=`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"resume":{},"close":{}},"promptCapabilities":{"image":true,"embeddedContext":true},"mcpCapabilities":{"http":true}},"authMethods":[{"id":"chat-gpt"}]}}`+"\r\n"
    for byte in transmute([]u8)first {
        part:[1]u8={byte};feed(&c,part[:],collect,&events)
    }
    testing.expect_value(t,events.counts[.Initialized],1)
    testing.expect_value(t,c.phase,Phase.Initialized)
    testing.expect(t,c.load_session && c.resume_session && c.close_session && c.http_mcp && c.image && c.embedded_context)
    update:=`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"conexión ✓"}}}}`+"\n"
    feed(&c,transmute([]u8)update,collect,&events)
    testing.expect_value(t,events.counts[.Update],1)
    testing.expect_value(t,strings.trim_right(string(events.update[:]),"\x00"),"conexión ✓")
    testing.expect_value(t,c.received,0)
    receive(&c,`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}`,collect,&events)
    testing.expect_value(t,events.counts[.Initialized],1)
}

@(test)
acp_session_configures_exact_model_effort_and_resumes_without_replay :: proc(t:^testing.T) {
    c:=test_client(t)
    defer destroy(&c,nil)
    events:Test_Events
    c.phase=.Initialized;c.next_id=2;c.load_session=true;c.resume_session=true;c.close_session=true;c.http_mcp=true
    desc:=Session_Desc{cwd=TEST_CWD,model="gpt-6-luna",effort="low",mcp_servers_json=`[{"type":"http","name":"mirai","url":"http://127.0.0.1:7940/mcp","headers":[{"name":"X-Mirai-Task","value":"8-0"}]}]`,meta=`{"claudeCode":{"options":{}}}`}
    testing.expect_value(t,open_session(&c,Session_Desc{cwd=TEST_CWD,meta=`[]`}),Error.Invalid_Message)
    testing.expect_value(t,open_session(&c,desc),Error.None)
    request:=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/new")
    _,has_meta:=at(request,"params","_meta","claudeCode","options").(json.Object)
    testing.expect(t,has_meta,"the session meta is sent")
    servers,_:=at(request,"params","mcpServers").(json.Array)
    testing.expect_value(t,len(servers),1)
    if len(servers)>0 {testing.expect_value(t,text(at(servers[0],"name")),"mirai")}
    options :: `"configOptions":[{"id":"model","category":"model","type":"select","options":[{"group":"gpt","options":[{"value":"gpt-6-luna"}]}]},{"id":"reasoning_effort","category":"thought_level","type":"select","options":[{"value":"low"},{"value":"high"}]}]`
    receive(&c,`{"jsonrpc":"2.0","id":2,"result":{"sessionId":"native-thread",`+options+`}}`,collect,&events)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/set_config_option")
    testing.expect_value(t,text(at(request,"params","configId")),"model")
    testing.expect_value(t,text(at(request,"params","value")),"gpt-6-luna")
    receive(&c,`{"jsonrpc":"2.0","id":3,"result":{`+options+`}}`,collect,&events)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"params","configId")),"reasoning_effort")
    testing.expect_value(t,text(at(request,"params","value")),"low")
    receive(&c,`{"jsonrpc":"2.0","id":4,"result":{`+options+`}}`,collect,&events)
    testing.expect_value(t,c.phase,Phase.Ready)
    testing.expect_value(t,events.counts[.Session_Ready],1)
    testing.expect_value(t,session_id(&c),"native-thread")
    desc.session_id="native-thread";desc.model,desc.effort="",""
    desc.mcp_servers_json=`[{"type":"http","name":"mirai","url":"http://127.0.0.1:7940/mcp","headers":[{"name":"X-Mirai-Task","value":"8-1"}]}]`
    testing.expect_value(t,open_session(&c,desc),Error.None)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/close")
    testing.expect_value(t,text(at(request,"params","sessionId")),"native-thread")
    testing.expect_value(t,session_id(&c),"native-thread")
    testing.expect_value(t,c.phase,Phase.Opening)
    testing.expect_value(t,events.counts[.Session_Ready],1)
    receive(&c,`{"jsonrpc":"2.0","id":5,"result":{}}`,collect,&events)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/resume")
    testing.expect_value(t,text(at(request,"params","sessionId")),"native-thread")
    _,has_meta=at(request,"params","_meta","claudeCode").(json.Object)
    testing.expect(t,has_meta,"the session meta is sent again on resume")
    servers,_=at(request,"params","mcpServers").(json.Array)
    testing.expect_value(t,len(servers),1)
    if len(servers)>0 {
        headers,_:=at(servers[0],"headers").(json.Array)
        testing.expect_value(t,len(headers),1)
        if len(headers)>0 {testing.expect_value(t,text(at(headers[0],"value")),"8-1")}
    }
    testing.expect_value(t,events.counts[.Session_Ready],1)
    receive(&c,`{"jsonrpc":"2.0","id":6,"result":{}}`,collect,&events)
    testing.expect_value(t,c.phase,Phase.Ready)
    testing.expect_value(t,events.counts[.Session_Ready],2)
    testing.expect_value(t,session_id(&c),"native-thread")
}

@(test)
acp_ready_session_closure_preserves_the_target_and_aborts_on_error :: proc(t:^testing.T) {
    c:=test_client(t)
    defer destroy(&c,nil)
    events:Test_Events
    c.phase=.Ready;c.close_session=true;c.load_session=true
    text_set(c.session[:],"previous-thread")
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,session_id="different-thread"}),Error.None)
    request:=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/close")
    testing.expect_value(t,text(at(request,"params","sessionId")),"previous-thread")
    receive(&c,`{"jsonrpc":"2.0","id":1,"result":{}}`,collect,&events)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/load")
    testing.expect_value(t,text(at(request,"params","sessionId")),"different-thread")
    receive(&c,`{"jsonrpc":"2.0","id":2,"result":{}}`,collect,&events)
    testing.expect_value(t,session_id(&c),"different-thread")
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD}),Error.None)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"params","sessionId")),"different-thread")
    receive(&c,`{"jsonrpc":"2.0","id":3,"result":{}}`,collect,&events)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/new")
    receive(&c,`{"jsonrpc":"2.0","id":4,"result":{"sessionId":"new-thread"}}`,collect,&events)
    testing.expect_value(t,session_id(&c),"new-thread")
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD}),Error.None)
    _=test_queued(t,&c)
    receive(&c,`{"jsonrpc":"2.0","id":5,"error":{"code":-32000,"message":"Session could not be closed"}}`,collect,&events)
    testing.expect_value(t,events.counts[.Error],1)
    testing.expect_value(t,c.queued,0)
    testing.expect_value(t,c.phase,Phase.Ready)
    testing.expect_value(t,session_id(&c),"new-thread")
    c.close_session=false
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,session_id="saved-thread"}),Error.None)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/load")
    receive(&c,`{"jsonrpc":"2.0","id":6,"result":{}}`,collect,&events)
    testing.expect_value(t,session_id(&c),"saved-thread")
}

@(test)
acp_session_titles_negotiate_only_the_index_and_rename_before_prompt :: proc(t:^testing.T) {
    c:=test_client(t,receive_bytes=4096,send_bytes=8192)
    defer destroy(&c,nil)
    events:Test_Events
    testing.expect_value(t,initialize_request(&c,true),Error.None)
    request:=test_queued(t,&c)
    capabilities,_:=at(request,"params","clientCapabilities","_meta","jetbrains","air","capabilities").(json.Array)
    testing.expect_value(t,len(capabilities),1)
    if len(capabilities)>0 {testing.expect_value(t,text(capabilities[0]),"sessionIndex")}
    testing.expect(t,at(request,"params","clientCapabilities","fs")==nil)
    testing.expect(t,at(request,"params","clientCapabilities","terminal")==nil)
    receive(&c,`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"_meta":{"jetbrains":{"air":{"version":1,"capabilities":["sessionIndex","sessionRename","sessionArchive"]}}}}}`,collect,&events)
    testing.expect(t,c.session_rename)
    title:="Decorate \"Player room\" ✓"
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,model="gpt-6-luna",effort="low",title=title}),Error.None)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/new")
    options :: `"configOptions":[{"id":"model","category":"model","type":"select","options":[{"value":"gpt-6-luna"}]},{"id":"effort","category":"thought_level","type":"select","options":[{"value":"low"}]}]`
    receive(&c,`{"jsonrpc":"2.0","id":2,"result":{"sessionId":"visual-task",`+options+`}}`,collect,&events)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/set_config_option")
    testing.expect_value(t,text(at(request,"params","configId")),"model")
    testing.expect_value(t,text(at(request,"params","value")),"gpt-6-luna")
    receive(&c,`{"jsonrpc":"2.0","id":3,"result":{`+options+`}}`,collect,&events)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"params","configId")),"effort")
    testing.expect_value(t,text(at(request,"params","value")),"low")
    receive(&c,`{"jsonrpc":"2.0","id":4,"result":{`+options+`}}`,collect,&events)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"_session/rename")
    testing.expect_value(t,text(at(request,"params","sessionId")),"visual-task")
    testing.expect_value(t,text(at(request,"params","title")),title)
    testing.expect_value(t,events.counts[.Session_Ready],0)
    testing.expect_value(t,c.phase,Phase.Configuring)
    testing.expect_value(t,prompt(&c,{{kind=.Text,text="Decorate this room."}}),Error.Invalid_State)
    testing.expect_value(t,c.queued,0)
    receive(&c,`{"jsonrpc":"2.0","id":5,"result":{}}`,collect,&events)
    testing.expect_value(t,events.counts[.Session_Ready],1)
    testing.expect_value(t,prompt(&c,{{kind=.Text,text="Decorate this room."}}),Error.None)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/prompt")
    chunks,_:=at(request,"params","prompt").(json.Array)
    testing.expect_value(t,len(chunks),1)
    if len(chunks)>0 {testing.expect_value(t,text(at(chunks[0],"text")),"Decorate this room.")}
    receive(&c,`{"jsonrpc":"2.0","id":6,"result":{"stopReason":"end_turn"}}`,collect,&events)
    testing.expect_value(t,c.queued,0)
    testing.expect_value(t,events.counts[.Error],0)
    testing.expect_value(t,events.counts[.Prompt_Done],1)
}

@(test)
acp_session_title_negotiation_is_optional_and_required_when_a_title_is_requested :: proc(t:^testing.T) {
    c:=test_client(t,receive_bytes=4096,send_bytes=8192)
    defer destroy(&c,nil)
    events:Test_Events
    testing.expect_value(t,initialize_request(&c,false),Error.None)
    request:=test_queued(t,&c)
    testing.expect(t,at(request,"params","clientCapabilities","_meta")==nil)
    receive(&c,`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"_meta":{"jetbrains":{"air":{"version":1,"capabilities":["sessionRename"]}}}}}`,collect,&events)
    testing.expect(t,!c.session_rename)
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,title="A task"}),Error.Unsupported)
    testing.expect_value(t,c.queued,0)
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD}),Error.None)
    request=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"session/new")
    receive(&c,`{"jsonrpc":"2.0","id":2,"result":{"sessionId":"normal-session"}}`,collect,&events)
    testing.expect_value(t,events.counts[.Session_Ready],1)
    testing.expect_value(t,c.queued,0)
    testing.expect_value(t,c.phase,Phase.Ready)
    c.session_titles=true;c.pending=.Initialize;c.pending_id=3
    receive(&c,`{"jsonrpc":"2.0","id":3,"result":{"protocolVersion":1,"_meta":{"jetbrains":{"air":{"version":0,"capabilities":["sessionRename"]}}}}}`,collect,&events)
    testing.expect(t,!c.session_rename)
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,title="A task"}),Error.Unsupported)
    testing.expect_value(t,c.queued,0)
    c.pending=.Initialize;c.pending_id=4
    receive(&c,`{"jsonrpc":"2.0","id":4,"result":{"protocolVersion":1,"_meta":{"jetbrains":{"air":{"version":1,"capabilities":["sessionIndex"]}}}}}`,collect,&events)
    testing.expect(t,!c.session_rename)
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,title="A task"}),Error.Unsupported)
    testing.expect_value(t,c.queued,0)
    c.session_rename=true
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,title=" \n\t"}),Error.Invalid_Message)
    oversized:[257]u8
    for &byte in oversized {byte='a'}
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,title=string(oversized[:])}),Error.Capacity)
    testing.expect_value(t,c.queued,0)
}

@(test)
acp_session_title_errors_do_not_launch_a_prompt_or_leave_a_pending_request :: proc(t:^testing.T) {
    c:=test_client(t,receive_bytes=4096,send_bytes=8192)
    defer destroy(&c,nil)
    events:Test_Events
    c.phase=.Initialized;c.session_rename=true
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,title="Visual task"}),Error.None)
    _=test_queued(t,&c)
    receive(&c,`{"jsonrpc":"2.0","id":1,"result":{"sessionId":"failed-title"}}`,collect,&events)
    request:=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"_session/rename")
    receive(&c,`{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Title write failed"}}`,collect,&events)
    testing.expect_value(t,events.counts[.Error],1)
    testing.expect_value(t,events.counts[.Session_Ready],0)
    testing.expect_value(t,c.pending,Request.None)
    testing.expect_value(t,c.deadline,f64(0))
    testing.expect_value(t,c.queued,0)
    testing.expect_value(t,error_text(&c),"Title write failed")
    testing.expect_value(t,c.phase,Phase.Ready)
}

@(test)
acp_prompt_escapes_content_and_permissions_require_an_explicit_response :: proc(t:^testing.T) {
    c:=test_client(t)
    defer destroy(&c,nil)
    events:Test_Events
    c.phase=.Ready;c.image=true;c.embedded_context=true
    text_set(c.session[:],"session-1")
    prompt_text:="Read \"Player\"\nUse the Mirai MCP.\tconexión\x01"
    content:=[]Content{
        {kind=.Text,text="Editor instructions"},
        {kind=.Text,text=prompt_text},
        {kind=.Resource,uri="mirai://play/player",mime_type="application/json",text=`{"health":75}`},
        {kind=.Resource_Link,uri="file:///project/.agents/skills/player/SKILL.md",name="player"},
        {kind=.Image,mime_type="image/png",data="iVBORw0KGgo="},
    }
    testing.expect_value(t,prompt(&c,content),Error.None)
    request:=test_queued(t,&c)
    chunks,_:=at(request,"params","prompt").(json.Array)
    testing.expect_value(t,len(chunks),5)
    testing.expect_value(t,text(at(chunks[1],"text")),prompt_text)
    testing.expect_value(t,text(at(chunks[2],"resource","text")),`{"health":75}`)
    permission_request:=`{"jsonrpc":"2.0","id":"permission-3","method":"session/request_permission","params":{"sessionId":"session-1","options":[{"optionId":"allow-once","kind":"allow_once"},{"optionId":"reject","kind":"reject_once"}],"toolCall":{"title":"Edit player"}}}`
    receive(&c,permission_request,collect,&events)
    testing.expect_value(t,events.counts[.Permission],1)
    testing.expect_value(t,c.queued,0)
    testing.expect_value(t,strings.trim_right(string(events.request_id[:]),"\x00"),`"permission-3"`)
    testing.expect_value(t,permission(&c,`"permission-3"`,"allow-once"),Error.None)
    reply:=test_queued(t,&c)
    testing.expect_value(t,text(at(reply,"id")),"permission-3")
    testing.expect_value(t,text(at(reply,"result","outcome","outcome")),"selected")
    testing.expect_value(t,text(at(reply,"result","outcome","optionId")),"allow-once")
    testing.expect_value(t,cancel(&c),Error.None)
    cancellation:=test_queued(t,&c)
    testing.expect_value(t,text(at(cancellation,"method")),"session/cancel")
    receive(&c,`{"jsonrpc":"2.0","id":1,"result":{"stopReason":"cancelled"}}`,collect,&events)
    testing.expect_value(t,c.phase,Phase.Ready)
    testing.expect_value(t,events.counts[.Prompt_Done],1)
    testing.expect_value(t,permission(&c,"null","",true),Error.Invalid_Message)
}

test_turn :: proc(t:^testing.T,c:^Client) {
    c.phase=.Ready;c.steering=true
    text_set(c.session[:],"s1")
    testing.expect_value(t,prompt(c,{{kind=.Text,text="Start"}}),Error.None)
    _=test_queued(t,c)
}

test_event_text :: proc(events:^Test_Events) -> string {
    return strings.trim_right(string(events.text[:]),"\x00")
}

@(test)
acp_initialize_announces_compaction_and_reads_steering :: proc(t:^testing.T) {
    for session_titles in ([]bool{false,true}) {
        c:=test_client(t,receive_bytes=4096,send_bytes=8192)
        defer destroy(&c,nil)
        events:Test_Events
        testing.expect_value(t,initialize_request(&c,session_titles),Error.None)
        request:=test_queued(t,&c)
        _,compaction:=at(request,"params","clientCapabilities","session","compaction").(json.Object)
        testing.expect(t,compaction,"the compaction capability is announced")
        receive(&c,`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"_meta":{"steering":{"supported":true}}}}`,collect,&events)
        testing.expect(t,c.steering)
    }
}

@(test)
acp_steer_joins_the_running_turn_and_is_answered_by_id :: proc(t:^testing.T) {
    c:=test_client(t,receive_bytes=4096,send_bytes=8192)
    defer destroy(&c,nil)
    events:Test_Events
    blocks:=[]Content{{kind=.Text,text="Also the door"}}
    c.phase=.Ready;c.steering=true
    testing.expect_value(t,steer(&c,blocks),Error.Invalid_State)
    test_turn(t,&c)
    prompt_id:=c.pending_id
    testing.expect_value(t,steer(&c,blocks),Error.None)
    first:=c.steer_id
    request:=test_queued(t,&c)
    testing.expect_value(t,text(at(request,"method")),"_session/steering")
    testing.expect_value(t,text(at(request,"params","sessionId")),"s1")
    testing.expect_value(t,text(at(request,"params","_meta","steering","idleBehavior")),"promptRequired")
    chunks,_:=at(request,"params","prompt").(json.Array)
    testing.expect_value(t,len(chunks),1)
    if len(chunks)>0 {testing.expect_value(t,text(at(chunks[0],"text")),"Also the door")}
    testing.expect_value(t,steer(&c,blocks),Error.None)
    second:=c.steer_id
    _=test_queued(t,&c)
    testing.expect(t,second>first)
    testing.expect_value(t,c.phase,Phase.Prompting)
    testing.expect_value(t,c.pending,Request.Prompt)
    testing.expect_value(t,c.pending_id,prompt_id)
    receive(&c,`{"jsonrpc":"2.0","id":2,"result":{"outcome":"injected"}}`,collect,&events)
    testing.expect_value(t,events.counts[.Steer_Done],1)
    testing.expect_value(t,events.steer_id,first)
    testing.expect_value(t,test_event_text(&events),"injected")
    testing.expect_value(t,c.phase,Phase.Prompting)
    receive(&c,`{"jsonrpc":"2.0","id":3,"result":{"outcome":"promptRequired","reason":"idle"}}`,collect,&events)
    testing.expect_value(t,events.counts[.Steer_Done],2)
    testing.expect_value(t,events.steer_id,second)
    testing.expect_value(t,test_event_text(&events),"promptRequired")
    testing.expect_value(t,c.phase,Phase.Prompting)
    receive(&c,`{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}`,collect,&events)
    testing.expect_value(t,events.counts[.Prompt_Done],1)
    testing.expect_value(t,c.phase,Phase.Ready)
}

@(test)
acp_steer_failures_do_not_end_the_turn :: proc(t:^testing.T) {
    c:=test_client(t,receive_bytes=4096,send_bytes=8192)
    defer destroy(&c,nil)
    events:Test_Events
    blocks:=[]Content{{kind=.Text,text="Also the door"}}
    test_turn(t,&c)
    testing.expect_value(t,steer(&c,blocks),Error.None)
    _=test_queued(t,&c)
    receive(&c,`{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"No turn"}}`,collect,&events)
    testing.expect_value(t,events.counts[.Steer_Done],1)
    testing.expect_value(t,test_event_text(&events),"failed")
    testing.expect_value(t,events.code,-32000)
    testing.expect_value(t,events.steer_id,c.steer_id)
    testing.expect_value(t,events.counts[.Error],0)
    testing.expect_value(t,events.counts[.Prompt_Done],0)
    testing.expect_value(t,error_text(&c),"")
    testing.expect_value(t,c.phase,Phase.Prompting)
    testing.expect_value(t,c.pending,Request.Prompt)
    testing.expect_value(t,steer(&c,blocks),Error.None)
    _=test_queued(t,&c)
    receive(&c,`{"jsonrpc":"2.0","id":3,"result":{"outcome":"unknown"}}`,collect,&events)
    testing.expect_value(t,test_event_text(&events),"failed")
    testing.expect_value(t,steer(&c,blocks),Error.None)
    _=test_queued(t,&c)
    steers_fail(&c,collect,&events)
    testing.expect_value(t,events.counts[.Steer_Done],3)
    testing.expect_value(t,events.steer_id,c.steer_id)
    testing.expect_value(t,c.steer_count,0)
    for _ in 0..<STEER_CAPACITY {
        testing.expect_value(t,steer(&c,blocks),Error.None)
        _=test_queued(t,&c)
    }
    testing.expect_value(t,steer(&c,blocks),Error.Capacity)
    testing.expect_value(t,c.queued,0)
}

@(test)
acp_steer_requires_the_announcement :: proc(t:^testing.T) {
    c:=test_client(t,receive_bytes=4096,send_bytes=8192)
    defer destroy(&c,nil)
    events:Test_Events
    c.pending=.Initialize;c.pending_id=1;c.phase=.Initializing
    receive(&c,`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"_meta":{"steering":{"supported":false}}}}`,collect,&events)
    testing.expect(t,!c.steering)
    c.phase=.Prompting
    testing.expect_value(t,steer(&c,{{kind=.Text,text="Also the door"}}),Error.Unsupported)
    testing.expect_value(t,c.queued,0)
    testing.expect_value(t,c.steer_count,0)
}

@(test)
acp_session_commands_track_compact_until_a_session_opens :: proc(t:^testing.T) {
    c:=test_client(t,receive_bytes=4096,send_bytes=8192)
    defer destroy(&c,nil)
    events:Test_Events
    c.phase=.Initialized
    with:=`{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review"},{"name":"compact"}]}}}`
    without:=`{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review"}]}}}`
    receive(&c,with,collect,&events)
    testing.expect(t,c.compact_command)
    testing.expect_value(t,events.counts[.Update],1)
    receive(&c,without,collect,&events)
    testing.expect(t,!c.compact_command)
    testing.expect_value(t,events.counts[.Update],2)
    receive(&c,with,collect,&events)
    testing.expect(t,c.compact_command)
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD}),Error.None)
    testing.expect(t,!c.compact_command)
}

@(test)
acp_capacity_and_configuration_errors_do_not_substitute_models :: proc(t:^testing.T) {
    c:=test_client(t,receive_bytes=256,send_bytes=512)
    defer destroy(&c,nil)
    events:Test_Events
    c.phase=.Ready
    text_set(c.session[:],"s")
    enormous:[1024]u8
    for &byte in enormous {byte='a'}
    testing.expect_value(t,prompt(&c,{{kind=.Text,text=string(enormous[:])}}),Error.Capacity)
    testing.expect_value(t,c.queued,0)
    testing.expect_value(t,c.phase,Phase.Ready)
    c.phase=.Prompting;c.steering=true
    testing.expect_value(t,steer(&c,{{kind=.Text,text=string(enormous[:])}}),Error.Capacity)
    testing.expect_value(t,c.queued,0)
    testing.expect_value(t,c.steer_count,0)
    testing.expect_value(t,c.next_id,1)
    c.phase=.Initialized
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,session_id="saved"}),Error.Unsupported)
    testing.expect_value(t,open_session(&c,{cwd=TEST_CWD,model="gpt-6-luna",effort="low"}),Error.None)
    _=test_queued(t,&c)
    receive(&c,`{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s","configOptions":[{"id":"model","category":"model","options":[{"value":"another-model"}]}]}}`,collect,&events)
    testing.expect_value(t,events.counts[.Error],1)
    testing.expect_value(t,events.counts[.Session_Ready],0)
    testing.expect_value(t,c.queued,0)
    testing.expect(t,strings.contains(error_text(&c),"gpt-6-luna"))
    c.phase=.Ready
    testing.expect_value(t,prompt(&c,{{kind=.Text,text="hello"}}),Error.None)
    _=test_queued(t,&c)
    receive(&c,`{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication expired","data":{"details":"Sign in again"}}}`,collect,&events)
    testing.expect_value(t,events.code,-32000)
    testing.expect_value(t,error_text(&c),"Authentication expired: Sign in again")
    testing.expect_value(t,c.phase,Phase.Ready)
    testing.expect_value(t,session_id(&c),"s")
    feed(&c,enormous[:],collect,&events)
    testing.expect_value(t,c.phase,Phase.Failed)
}

@(test)
acp_idle_poll_does_not_allocate_and_native_transport_exits_after_eof :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    c:Client
    error:=create(&c,mem.tracking_allocator(&tracking))
    testing.expect_value(t,error,Error.None)
    p,platform_error:=platform.create({headless=true,process_capacity=2})
    testing.expect_value(t,platform_error,platform.Error.None)
    if p==nil {destroy(&c,nil);return}
    defer platform.destroy(p)
    defer destroy(&c,p)
    before:=tracking.total_allocation_count
    {
        context.allocator=mem.tracking_allocator(&tracking)
        context.temp_allocator=context.allocator
        for _ in 0..<1000 {poll(&c,p,nil,nil)}
    }
    testing.expect_value(t,tracking.total_allocation_count,before)
    when ODIN_OS!=.Windows {
        script:=`read line; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}'; cat >/dev/null`
        testing.expect_value(t,start(&c,p,{command={"sh","-c",script}}),Error.None)
        events:Test_Events
        deadline:=platform.clock_seconds()+5
        for c.phase!=.Initialized && platform.clock_seconds()<deadline {
            poll(&c,p,collect,&events)
            platform.sleep_coarse(1_000_000)
        }
        testing.expect_value(t,c.phase,Phase.Initialized)
        before=tracking.total_allocation_count
        {
            context.allocator=mem.tracking_allocator(&tracking)
            context.temp_allocator=context.allocator
            for _ in 0..<1000 {poll(&c,p,collect,&events)}
        }
        testing.expect_value(t,tracking.total_allocation_count,before)
        stop(&c,p)
        for c.process!=0 && platform.clock_seconds()<deadline {
            poll(&c,p,collect,&events)
            platform.sleep_coarse(1_000_000)
        }
        testing.expect_value(t,c.process,platform.Process(0))
        testing.expect_value(t,c.phase,Phase.Stopped)
        testing.expect_value(t,events.counts[.Exited],1)
        testing.expect_value(t,events.counts[.Error],0)
    }
}
