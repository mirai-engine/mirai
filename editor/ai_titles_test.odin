package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:editor/acp"
import "mirai:editor/ai_store"
import "mirai:project"
import "mirai:std/base"

@(test)
ai_session_titles_update_the_matching_project_chat_after_the_turn :: proc(t:^testing.T) {
    root:=project.path_absolute(fmt.tprintf(".mirai/test-ai-title-%d",os.get_pid()),context.temp_allocator)
    if !testing.expect(t,!os.exists(root)) {return}
    defer os.remove_all(root)
    m:=new(Ai);defer free(m)
    testing.expect_value(t,ai_store.open(&m.store,root),"")
    defer ai_store.close(&m.store)
    m.task_count=2
    for &task,index in m.tasks[:m.task_count] {
        task.id=index+1;task.conversation.id=u64(task.id);task.state=.Done
        ai_store.conversation_set_text(task.conversation.native_session[:],&task.conversation.native_session_len,fmt.tprintf("native-%d",task.id))
        ai_store.conversation_set_text(task.conversation.title[:],&task.conversation.title_len,"Original")
        ai_transcript_add(&task.transcript,"User message",.Prompt)
        task.dirty=true
    }
    s:=Session{ai=m,project_root=root}
    callback:=Ai_Callback{session=&s,worker=&m.workers[0]}
    for &task in m.tasks[:m.task_count] {ai_task_persist(&s,&task)}
    m.history_count=2
    for &row,index in m.history[:m.history_count] {row=m.tasks[index].conversation}
    values:=[]string{
        `{"sessionId":"unknown","update":{"sessionUpdate":"session_info_update","title":"Wrong"}}`,
        `{"sessionId":"native-2","update":{"sessionUpdate":"session_info_update","title":"  Compact scene title  "}}`,
    }
    for text in values {
        value,error:=json.parse_string(text,allocator=context.temp_allocator)
        testing.expect_value(t,error,json.Error.None)
        ai_acp_event(&callback,{kind=.Update,value=value})
    }
    testing.expect_value(t,string(m.tasks[0].conversation.title[:m.tasks[0].conversation.title_len]),"Original")
    testing.expect_value(t,base.text_get(m.tasks[1].title[:]),"Compact scene title")
    testing.expect_value(t,string(m.history[1].title[:m.history[1].title_len]),"Compact scene title")
    testing.expect_value(t,m.tasks[1].transcript.count,1)
    rows:[2]ai_store.Conversation
    count,message:=ai_store.list(&m.store,rows[:])
    testing.expect_value(t,message,"");testing.expect_value(t,count,2)
    for &row in rows[:count] {if row.id==2 {testing.expect_value(t,string(row.title[:row.title_len]),"Compact scene title")}}
    m.workers[0].task=1;base.text_set(m.workers[0].client.session[:],"opening")
    m.tasks[0].conversation.native_session_len=0
    value,_:=json.parse_string(`{"sessionId":"opening","update":{"sessionUpdate":"session_info_update","title":"Opening title"}}`,allocator=context.temp_allocator)
    ai_acp_event(&callback,{kind=.Update,value=value,replay=true})
    testing.expect_value(t,base.text_get(m.tasks[0].title[:]),"Opening title")
    m.workers[1].task=2;base.text_set(m.workers[1].client.session[:],"opening-second")
    m.tasks[1].conversation.native_session_len=0
    value,_=json.parse_string(`{"sessionId":"opening-second","update":{"sessionUpdate":"session_info_update","title":"Second worker title"}}`,allocator=context.temp_allocator)
    ai_acp_event(&callback,{kind=.Update,value=value,replay=true})
    testing.expect_value(t,base.text_get(m.tasks[1].title[:]),"Compact scene title")
    second_callback:=Ai_Callback{session=&s,worker=&m.workers[1]}
    ai_acp_event(&second_callback,{kind=.Update,value=value,replay=true})
    testing.expect_value(t,base.text_get(m.tasks[1].title[:]),"Second worker title")
    testing.expect_value(t,base.text_get(m.tasks[0].title[:]),"Opening title")
}
