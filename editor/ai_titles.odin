package editor

import "core:encoding/json"
import "core:strings"
import "mirai:editor/acp"
import "mirai:editor/ai_store"
import "mirai:std/base"

// The title an agent gives a conversation. Claude Agent ACP summarizes the
// first text of the prompt, which is the instructions of the editor, and
// renaming needs a Claude Code newer than the one a user may have: a chat of
// Claude keeps the start of its first message.
ai_session_title_update :: proc(s:^Session,worker:^Ai_Worker,value:json.Value) {
    m:=s.ai
    if m.connections[worker.provider].agent==.Claude {return}
    session:=acp.text(acp.at(value,"sessionId"))
    title:=strings.trim_space(acp.text(acp.at(value,"update","title")))
    if session=="" || title=="" {return}
    if newline:=strings.index_byte(title,'\n');newline>=0 {title=title[:newline]}
    task:^Ai_Task
    for &candidate in m.tasks[:m.task_count] {
        native:=string(candidate.conversation.native_session[:candidate.conversation.native_session_len])
        if native==session || native=="" && candidate.id==worker.task && session==acp.session_id(&worker.client) {task=&candidate;break}
    }
    if task==nil || len(title)>len(task.conversation.title) {return}
    c:=&task.conversation
    if title==string(c.title[:c.title_len]) {return}
    ai_store.conversation_set_text(c.title[:],&c.title_len,title)
    base.text_set(task.title[:],title)
    if !task.dirty {task.dirty_sequence=task.transcript.dropped+task.transcript.count}
    task.dirty=true
    ai_task_persist(s,task)
    for &row in m.history[:m.history_count] {
        if row.id==c.id {row.title,row.title_len,row.updated_at=c.title,c.title_len,c.updated_at;break}
    }
}
