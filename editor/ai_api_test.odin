package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(test)
ai_methods_write_the_results_they_declare :: proc(t:^testing.T) {
    temporary:=context.temp_allocator
    defer {context.temp_allocator=temporary}
    storages:=[]core.Storage_Info{{name="Sky"}}
    info:=core.World_Info{storages=storages}
    m:=new(Ai);defer free(m)
    s:=Session{ai=m,info=&info}
    m.task_count,m.workers[0].task=2,7
    task:=&m.tasks[0];task.id=7;task.state=.Running
    m.tasks[1].id,m.tasks[1].state=8,.Queued
    base.text_set(task.title[:],"Paint the cube")
    append(&task.review.changed_ids,base.Entity_Id(0x2a))
    append(&task.review.changed_files,"assets/cube.mat")
    defer {delete(task.review.changed_ids);delete(task.review.changed_files)}
    ai_transcript_add(&task.transcript,"Paint the cube",.Prompt)
    ai_transcript_add(&task.transcript,"",.Output)
    m.permission_count=1
    permission:=&m.permissions[0]
    base.text_set(permission.title[:],"Write cube.mat")
    base.text_set(permission.ids[0][:],"allow");base.text_set(permission.names[0][:],"Allow")
    permission.count=1
    m.connection_count=2
    base.text_set(m.connections[0].id[:],"codex");m.connections[0].agent=.Codex
    command:=&m.connections[1]
    base.text_set(command.id[:],"local");command.agent=.Command
    base.text_set(command.command[:],"agent");base.text_set(command.arguments[0][:],"--acp");command.argument_count=1
    root:=project.path_absolute(fmt.tprintf(".mirai/test-ai-api-%d",os.get_pid()),context.temp_allocator)
    if !testing.expect(t,!os.exists(root)) {return}
    defer os.remove_all(root)
    testing.expect_value(t,ai_store_open(&m.store,root),"");defer ai_store_close(&m.store)
    saved:=Ai_Conversation{id=1,updated_at=200}
    ai_conversation_set_text(saved.title[:],&saved.title_len,"Paint the cube")
    testing.expect_value(t,ai_store_save(&m.store,&saved,&task.transcript),"")
    testing.expect_value(t,ai_store_annotate(&m.store,1,0,"user","context","",`{"player":4}`),"")
    state:=new(Api_State);defer free(state)
    state.poll_temp=temporary
    if !testing.expect_value(t,api.server_init(&state.server,{port=0,max_methods=64,max_connections=1,max_request=16*1024,max_response=256*1024,scratch=512*1024}),api.Init_Error.None) {return}
    defer api.server_destroy(&state.server)
    ai_api_register(&s,state)
    if !testing.expectf(t,state.refused==0,"%s",state.refusal) {return}
    out_buffer:=make([]u8,64*1024,context.temp_allocator)
    // ai.history answers a list of the conversations or of the messages of one.
    for request in ([]struct{method,params,key:string}{{"ai.status",`{}`,""},{"ai.status",`{"id":7,"from":1}`,""},{"ai.cancel",`{"id":8}`,""},{"ai.connections",`{}`,""},{"agent.list",`{}`,""},{"memory.search",`{"query":"wall"}`,""},{"annotation.list",`{}`,""},{"ai.provenance",`{"asset":"cube.mat"}`,""},{"ai.history",`{}`,"updated_at"},{"ai.history",`{"id":1}`,"sequence"}}) {
        method:=api.method_find(&state.server,request.method)
        if !testing.expect(t,method!=nil) {continue}
        w:serial.Writer
        serial.writer_init_fixed(&w,out_buffer)
        _,ok:=api.method_execute(&state.server,method,request.params,&w)
        text:=string(serial.writer_bytes(&w))
        if !testing.expectf(t,ok,"%s failed",request.method) {continue}
        if request.key=="" {
            testing.expect_value(t,api.result_mismatch(method.result_id,text),"")
            continue
        }
        reply,reply_error:=json.parse_string(text,allocator=context.temp_allocator)
        items,listed:=reply.(json.Array)
        testing.expectf(t,reply_error==.None && listed && len(items)>0,"%s answers %s",request.method,text)
        for item in items {
            _,keyed:=item.(json.Object)[request.key]
            testing.expectf(t,keyed,"%s answers %s",request.method,text)
        }
    }
}
