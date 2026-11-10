package editor

import "mirai:ui"

// What the rest of the editor reads and asks of the chats. Its panels go
// through these procedures and those of the tasks (ai_task_*, ai_review_*,
// ai_scene_*) instead of the fields of Ai; a nil Ai is an editor without chats.

// The chats and agents of the project that the editor holds.
ai_tasks :: proc(m:^Ai) -> []Ai_Task {
    return m.tasks[:m.task_count] if m!=nil else nil
}

// The chat of the project, nil until its first message.
ai_main_task :: proc(m:^Ai) -> ^Ai_Task {
    return ai_task_find(m,m.main) if m!=nil && m.main!=0 else nil
}

// Moves when what the agents show in the scene, or what waits for review, changes.
ai_scene_serial :: proc(m:^Ai) -> u64 {
    return m.scene_serial if m!=nil else 0
}

ai_agents_in_scene :: proc(m:^Ai) -> bool {
    return m==nil || m.show_agents_in_scene
}

ai_chat_open :: proc(m:^Ai) -> bool {
    return m!=nil && m.chat_open
}

ai_chat_expanded :: proc(m:^Ai) -> bool {
    return m!=nil && m.chat_expanded
}

ai_chat_show :: proc(m:^Ai,open:bool) {
    if m!=nil {m.chat_open=open}
}

ai_chat_focus :: proc(m:^Ai,focus:bool) {
    if m!=nil {m.focus=focus}
}

// True when the chat is open and the point of the window is on it.
ai_chat_holds :: proc(m:^Ai,point:[2]f32) -> bool {
    return m!=nil && m.chat_open && ui.rect_contains(m.chat_rect,point)
}

// The part of the window the next message shows the agent.
ai_region_set :: proc(m:^Ai,rect:ui.Rect) {
    if m!=nil {m.region,m.has_region=rect,true}
}

// What the document of a material gives the next message; the zero value when none is in front.
ai_material_set :: proc(m:^Ai,material:Ai_Material_Context) {
    if m!=nil {m.material=material}
}

ai_material_open :: proc(m:^Ai) -> bool {
    return m!=nil && m.material.open
}

// Drops the message that waits to be sent and stops the turns that run or wait, with a note of why.
ai_turns_stop :: proc(s:^Session,m:^Ai,note:string) {
    if m==nil {return}
    m.pending=false
    for &task in m.tasks[:m.task_count] {
        if task.state!=.Running && task.state!=.Queued {continue}
        ai_note(&task,"%s",note)
        ai_task_cancel(s,m,&task)
    }
}

// Sends text to the chat of the project as a message of the user, and shows the chat.
ai_chat_ask :: proc(s:^Session,m:^Ai,text:string) -> bool {
    if m==nil {return false}
    m.selected=m.main
    m.prompt_length=copy(m.prompt[:AI_MESSAGE_BYTES-1],text)
    library_select(s,.Ai)
    return ai_chat_send(s)
}

// What the editor shows of the agents, which its preferences keep; nil without chats.
ai_view_preferences :: proc(m:^Ai) -> ^Ai_View {return &m.view if m!=nil else nil}

// The reviews of the chats follow the scene that was opened.
ai_reviews_reconcile :: proc(s:^Session,m:^Ai) {for &task in ai_tasks(m) {ai_review_reconcile(s,m,&task)}}
