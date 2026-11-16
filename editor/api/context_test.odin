package api

import "core:strings"
import "core:testing"
import "mirai:std/base"

@(test)
http_task_context_is_isolated_per_request_and_rejects_conflicting_headers :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    method:=method_find(&f.server,"test.echo")
    original:=method.handler
    method.handler=proc(call:^Call) {base.text_set(call_result(call,Echo_Result).text[:],call.client_tag)}
    defer {method.handler=original}
    body:=`{"jsonrpc":"2.0","id":1,"method":"test.echo","params":{"text":"ignored"}}`
    for tag in ([]string{"12-0","13-2",""}) {
        headers:="Content-Type: application/json\r\n"
        if tag!="" {headers=strings.concatenate({headers,"X-Mirai-Ai-Task: ",tag,"\r\n"},context.temp_allocator)}
        response:=exchange(server_port(&f.server),http_request("/rpc",body,headers))
        split:=strings.index(response,"\r\n\r\n")
        if !testing.expect(t,split>=0 && strings.has_prefix(response,"HTTP/1.1 200")) {return}
        value:=parse_json(t,response[split+4:])
        testing.expect_value(t,string_of(at(value,"result","text")),tag)
    }
    for headers in ([]string{
        "Content-Type: application/json\r\nX-Mirai-Ai-Task: 12-0\r\nX-Mirai-Ai-Task: 13-0\r\n",
        "Content-Type: application/json\r\nX-Mirai-Ai-Task: \r\n",
        "Content-Type: application/json\r\nX-Mirai-Client: two words\r\n",
        "Content-Type: application/json\r\nX-Mirai-Client: codex\r\nX-Mirai-Client: cursor\r\n",
        "Content-Type: application/json\r\nX-Mirai-Measure: mine\r\n",
    }) {
        response:=exchange(server_port(&f.server),http_request("/rpc",body,headers))
        testing.expect(t,strings.has_prefix(response,"HTTP/1.1 400"))
    }
}

// A turn of the editor names its turn and not its client; an agent outside
// the editor, its client, which mirai mcp takes from the initialize it
// forwards; a command inside a measurement, which one.
@(test)
the_client_sends_the_turn_of_a_task_or_the_name_of_its_agent_with_its_calls :: proc(t:^testing.T) {
    f:Fixture
    if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    method:=method_find(&f.server,"test.echo")
    original:=method.handler
    method.handler=proc(call:^Call) {base.text_set(call_result(call,Echo_Result).text[:],strings.concatenate({call.client_tag,"|",call.client_name,"|",call.measure},context.temp_allocator))}
    defer {method.handler=original}
    cases:=[?]struct{tag,client,measure,text:string}{{"7-3","","","7-3||"},{"7-3","claude-code","","7-3||"},{"","claude-code","","|claude-code|"},{"","claude-code","4120","|claude-code|4120"},{"","","","||"}}
    for c in cases {
        result,error,ok:=rpc_call(server_port(&f.server),"test.echo",`{"text":"ignored"}`,1,3000,context.temp_allocator,c.tag,c.client,measure=c.measure)
        if !testing.expectf(t,ok,"%v",error) {return}
        testing.expect_value(t,string_of(at(parse_json(t,result),"text")),c.text)
    }
    names:=[?][2]string{
        {`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Claude Code","version":"2"}}}`,"claude-code"},
        {`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`,""},
        {`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"clientInfo":{"name":"codex"}}}`,""},
        {`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"a-client-whose-name-is-far-too-long"}}}`,"a-client-whose-name-is-far-too-"},
    }
    for n in names {testing.expect_value(t,bridge_client_name(context.temp_allocator,n[0]),n[1])}
}
