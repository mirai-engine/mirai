package editor

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:editor/acp"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:ui"

AI_TASK_CAPACITY :: 16
AI_WORKER_CAPACITY :: 8 // one of them is never taken by a subagent: the main chat can always answer
AI_MESSAGE_BYTES :: ui.TEXT_EDIT_CAPACITY // of a message or of the instructions of the project, as the chat edits them
AI_STEP_CAPACITY :: 64 // steps of undo remembered per task
AI_PATH_BYTES :: 512
AI_REFERENCES :: 4         // images a message takes to show what the user wants
AI_REFERENCE_SIDE :: 800   // pixels of the square one fits in, as the agent reads it
AI_REFERENCE_QUALITY :: 90 // of the JPEG of one
AI_FOLDER :: "ai"      // under the generated folder of the project
AI_REGION_MIN :: f32(8)   // minimum snapshot side in window points

Ai_Task_State :: enum u8 {Queued,Running,Done,Failed,Cancelled,Interrupted}
Ai_Compact :: enum u8 {None,Running,Failed}

// The plan of a turn as the agent reports it (the ACP update plan): each
// report replaces the whole list. It lasts until the next turn and is not saved.
AI_PLAN_ENTRIES :: 16
AI_PLAN_BYTES :: 160
Ai_Plan_Status :: enum u8 {Pending,In_Progress,Completed}
Ai_Plan_Entry :: struct {
    text:[AI_PLAN_BYTES]u8,
    status:Ai_Plan_Status,
}
AI_STATE_NAMES :: [Ai_Task_State]string{.Queued="queued",.Running="running",.Done="done",.Failed="failed",.Cancelled="cancelled",.Interrupted="interrupted"}

// What the agent wants back when it ends a turn with a question. Every kind
// also takes free text: the user is never cornered into the options.
Ai_Question :: enum u8 {None,Text,Single,Multi,Confirm}
AI_QUESTION_BYTES :: 512
AI_QUESTION_OPTIONS :: 12

// What a message from the document of a material takes: the material, its
// program, the values the user picked, the channel the preview showed and the
// variant set last.
Ai_Material_Context :: struct {
    open:bool,          // the document of the material is in front: the message is about it
    id:base.Asset_Id,   // of the material; zero: the program alone
    material:[256]u8,   // its path under the assets folder; empty: the program alone
    program:[64]u8,
    picks:[MATERIAL_PICKS][64]u8,
    pick_count:int,
    channel:[16]u8,     // as editor.material.show names it; empty: lit
    variant:[MATERIAL_VARIANT_LABEL_BYTES]u8, // the variant the preview shows, or the one set last
    variant_applied:bool,                      // it was set on the material
}

Ai_Task :: struct {
    id:int, // from 1, in the order they were asked
    state:Ai_Task_State,
    name:[32]u8,    // of its folder
    title:[96]u8,   // the start of the prompt
    agent:[32]u8,   // the one asked for until it starts; then the one that runs it
    region:ui.Rect, // window points
    window:[2]f32,
    entities,entities_total:int, // listed in its context, and drawn in the region
    image:bool,     // the capture of the region was written
    pid,exit_code:int,
    stop:bool,      // asked to end
    started:time.Tick,
    seconds:f32,    // it ran
    heard:f64,      // clock seconds of the prompt or the last update of the agent since
    silent:bool,    // the transcript says the agent has not answered since heard
    said:[256]u8,   // the last line the agent printed to stderr
    state_before,state_after:u64, // of the history when it started and when it ended
    steps:[AI_STEP_CAPACITY]u64,  // state of the World after each step of undo it produced, oldest first
    step_count:int,
    undone:bool,
    declined:bool, // the user reverted its scene changes; its record is kept to take them back
    sources:u64,    // fingerprint of the code of the project when it started
    shaders:u64,    // and of its shaders, which the editor publishes itself
    needs_build:bool,
    files_changed:bool, // it changed files of the project its review could not keep: the turn cannot be reverted
    code:[dynamic]Ai_Code_File, // while it runs: the files of the project as it found them (ai_code.odin)
    transcript:Ai_Transcript,
    conversation:Ai_Conversation,
    dirty_sequence:int,
    dirty:bool,
    stream_open:bool,
    finish_called:bool,
    system_turn:bool, // the editor started this turn: it may end without finish, having nothing to say
    play:bool,
    world:rawptr,
    document_closed:bool,
    icon,color_index:u8,
    question:Ai_Question,
    options:[AI_QUESTION_BYTES]u8, // one choice per line
    options_length:int,
    review_finished:bool,
    review_deferred:bool, // restored while another scene was open: its review waits for that scene
    image_write:host.Png_Write, // of region.png, while a job writes it
    references:int, // the reference images of the message, reference-<n>.jpg from 1
    attachments:[AI_ATTACHMENTS]base.Asset_Id, // the assets the message is about
    attachment_count:int,
    range:Ai_Range, // the time chosen on a timeline the message is about
    reference_writes:[AI_REFERENCES]host.Png_Write,
    review:Ai_Review,
    anchor:[3]f32,  // where its figure stands
    anchor_set:bool,
    facing:f32,     // the turn of its figure about +Y, toward what it works on
    figure_shown:bool, // its figure appeared: it stays through the turns of the conversation until the agent ends
    context_ids:[AI_ENTITY_CAPACITY]base.Entity_Id,
    context_count:int,
    kept,rejected:int, // the changes the review kept and put back one by one, for the note that ends it
    material:Ai_Material_Context,
    about:int,          // the unit its message is about (ai_about_set)
    plan:[AI_PLAN_ENTRIES]Ai_Plan_Entry,
    plan_count:int,
    held:int,       // messages written while it worked that wait in deliveries for its next turn
    held_lines:int, // the lines of the transcript that have not reached its agent, the latest ones of the user
    steers:[acp.STEER_CAPACITY]Ai_Steer, // sent to the running turn, until the agent says what became of them
    steer_count:int,
    compact:Ai_Compact,      // the /compact the editor sent is running; the state of the chat goes back to compact_state
    compact_state:Ai_Task_State,
    stable_native:[256]u8,   // the native session that has the stable instructions
    notes_native:[256]u8,    // the native session that was asked to save its notes
}

// What the editor shows of the agents, as it keeps it between sessions.
Ai_View :: struct {
    show_agents_in_scene:bool,
}

@(storage)
Ai :: struct {
    tasks:[AI_TASK_CAPACITY]Ai_Task,
    main:int, // the task of the chat of the project; 0 until its first message
    code:map[string][]u8, // what files of the project held, by path, size and time: those the turns that run started with
    task_count:int,
    next_id:int,

    workers:[AI_WORKER_CAPACITY]Ai_Worker,
    agent_serial:int, // the last Ai_Worker.agent given
    initialized:bool,
    connections:[AI_CONNECTION_CAPACITY]Ai_Connection, // ai_connections: Codex, Claude and the agents added by command
    connection_count:int,
    default_runtime:Ai_Runtime,
    agents_home:[AI_PATH_BYTES]u8, // project.agents_folder, or the folder a test gives
    probe:Ai_Probe,
    connection_ui:Ai_Connections_Ui,
    store:Ai_Store,
    history:[64]Ai_Conversation,
    history_count,history_offset:int,
    last_flush:f64,
    login:bool,
    login_provider:Ai_Provider,
    login_process:platform.Process,
    login_cancelled:bool,
    connection_pending:Ai_Connection_Pending,
    installer:platform.Process,
    install_operation:[32]u8,
    install_cancel:[AI_PATH_BYTES]u8,
    install_provider:Ai_Provider,
    models:[AI_CONNECTION_CAPACITY][32]Ai_Model_Option,
    model_counts:[AI_CONNECTION_CAPACITY]int,
    permissions:[8]Ai_Permission,
    permission_count:int,
    using view:Ai_View,
    scene_serial:u64,

    // What the chat shows and what the next message takes, one per project.
    region:ui.Rect,
    has_region:bool,
    selected:int, // the task shown: the main chat, or a subagent while it is inspected
    prompt:[AI_MESSAGE_BYTES]u8,
    prompt_length:int,
    references:[AI_REFERENCES][AI_PATH_BYTES]u8, // images the next message takes, by their path
    reference_count:int,
    attachments:[AI_ATTACHMENTS]base.Asset_Id, // assets dragged onto the chat that the next message takes
    attachment_count:int,
    range:Ai_Range, // the time chosen on a timeline the next message takes
    about:int,          // the unit the next message is about, as a chip over the composer
    annotations:Ai_Annotations,
    pins:[AI_PINS]Ai_Pin_Row, // of the database, read when it changes
    pin_count:int,
    pins_loaded:bool,
    provenance_views:[Ai_Provenance_Kind]Ai_Provenance_View, // what the rows of Details show
    asset_marks:map[u64]int, // the unit an asset waits for, by the hash of its path; made for asset_marks_serial
    asset_marks_serial:u64,
    agent:[32]u8,
    focus:bool,
    scroll:f32,
    scroll_to:int, // a sequence of the chat shown, plus one, to bring into sight; 0: none
    list_scroll:[2]f32,
    stick:bool,
    chat_expanded:bool, // the chat takes the whole area below the bars
    agents_open:bool,   // the status line is unfolded into the list of the units
    report_open:int,    // the subagent whose report card lists its changes; 0: none
    report_scroll:[2]f32,
    reports:[AI_REPORT_CACHE]Ai_Report_Text, // answers of subagents no longer in tasks
    report_next:int,
    chat_hits:[AI_CHAT_HITS]Ai_Chat_Hit,     // of the search of the main chat
    chat_hit_count:int,
    hit_view:Ai_Hit_View,
    memory_ui:Ai_Memory_Ui,

    subagent:Ai_Subagent_Default, // what a subagent runs with unless agent.spawn says otherwise
    deliveries_due:bool, // something happened that may let what waits in deliveries go
    closing:bool,        // the editor is closing: the turns it cuts stay interrupted, without a report
    chat_open:bool,
    submit_frame:u64,
    pending:bool,
    pending_model:[128]u8,
    pending_effort:[32]u8,
    chat_rect:ui.Rect, // of the chat on the window, as last drawn
    history_scroll:[2]f32,
    steps_task,steps_line:int, // the steps of a turn unfolded: its conversation and the sequence of its first call
    review_open:bool,  // the changes of the review over the composer are listed one per row
    composer_empty_y:f32, // window points where the composer of the empty chat stood last
    composer_drop_at:f64, // ui time the composer began to go down after the first message; 0: still
    composer_drop_from:f32,
    review_task:int, // conversation being walked through, and how far
    review_at:int,
    review_scroll:[2]f32, // of the list of changes of the card under the chat
    review_shown:base.Entity_Id, // a deletion of review_task the walk brought into sight: Details shows it
    review_selection:u64,        // while the selection keeps this serial
    marks:[dynamic]Ai_Review_Mark, // rows of the entity Details shows, for its id and the serial they were made with
    marks_id:base.Entity_Id,
    marks_serial:u64,
    picked:[AI_QUESTION_OPTIONS]bool, // choices ticked of a question with several, of the conversation picked_task
    picked_task:int,
    details:int,         // conversation whose details are open in a dialog; 0: none
    details_scroll:f32,
    material:Ai_Material_Context, // what the document of a material gives the next message
    play_after:[AI_PATH_BYTES]u8, // a scene an answer asked to play: it plays once Open has put it in place
}

AI_DEFAULT :: Ai{view={show_agents_in_scene=true}}

ai_task_find :: proc(m:^Ai,id:int) -> ^Ai_Task {
    for &task in m.tasks[:m.task_count] {
        if task.id==id {return &task}
    }
    return nil
}

ai_task_finished :: proc "contextless" (task:^Ai_Task) -> bool {return task.state>=.Done}

// Seconds the turn took, or is taking while it runs.
ai_task_seconds :: proc(task:^Ai_Task) -> f32 {
    if ai_task_finished(task) || task.started=={} {return task.seconds}
    return f32(time.duration_seconds(time.tick_since(task.started)))
}

// A turn that ended and still waits for the user to keep or revert it.
ai_task_reviewable :: proc "contextless" (task:^Ai_Task) -> bool {
    return ai_task_finished(task) && !task.review_finished && (task.state==.Done || task.review.pending || task.context_count>0)
}

@(private)
ai_document_closed :: proc(s:^Session,world:rawptr) {
    if s.ai==nil {return}
    for &task in s.ai.tasks[:s.ai.task_count] {
        if task.world!=world || task.document_closed {continue}
        task.document_closed=true
        if !ai_task_finished(&task) {ai_task_cancel(s,s.ai,&task)}
    }
}

// The turns of the document that are still working: running or queued.
ai_working_count :: proc(s:^Session) -> (count:int) {
    if s.ai==nil {return}
    for &task in s.ai.tasks[:s.ai.task_count] {if !ai_task_finished(&task) && ai_task_current(s,&task) {count+=1}}
    return
}

// The changes of the turns of the document that wait for review.
ai_review_waiting_count :: proc(s:^Session) -> (count:int) {
    if s.ai==nil {return}
    for &task in s.ai.tasks[:s.ai.task_count] {
        if ai_task_reviewable(&task) && task.review.pending && ai_task_current(s,&task) {count+=ai_review_waiting(&task.review)}
    }
    return
}

// Stops the turns of the document that are still working. The API refuses
// their calls from now on: what is saved or discarded next is all they did.
ai_working_stop :: proc(s:^Session) {
    if s.ai==nil {return}
    for &task in s.ai.tasks[:s.ai.task_count] {
        if !ai_task_finished(&task) && ai_task_current(s,&task) {ai_task_cancel(s,s.ai,&task)}
    }
}

// Room for one more task: the oldest finished one is forgotten when the list is full.
@(private)
ai_task_slot :: proc(m:^Ai) -> ^Ai_Task {
    if m.task_count==AI_TASK_CAPACITY {
        for &task,index in m.tasks[:m.task_count] {
            if !ai_task_finished(&task) {continue}
            if task.id==m.main || !task.review_finished && (task.review.pending || task.context_count>0) {continue}
            if m.selected==task.id {m.selected=m.main}
            ai_review_free(&task.review)
            ai_steers_free(&task)
            copy(m.tasks[index:m.task_count-1],m.tasks[index+1:m.task_count])
            m.task_count-=1
            break
        }
        if m.task_count==AI_TASK_CAPACITY {return nil}
    }
    task:=&m.tasks[m.task_count]
    m.task_count+=1
    task^={}
    return task
}

// A file of the folder of a task, or the folder itself, in the temporary allocator.
@(private)
ai_task_path :: proc(s:^Session,task:^Ai_Task,file:string,allocator:=context.temp_allocator) -> string {
    folder:=project.folder_path(s.project_root,.Generated,allocator)
    name:=base.text_get(task.name[:])
    if file=="" {return fmt.aprintf("%s/%s/%s",folder,AI_FOLDER,name,allocator=allocator)}
    return fmt.aprintf("%s/%s/%s/%s",folder,AI_FOLDER,name,file,allocator=allocator)
}

@(private)
ai_note :: proc(task:^Ai_Task,format:string,args:..any) {
    buffer:[256]u8
    ai_transcript_add(&task.transcript,fmt.bprintf(buffer[:],format,..args),.Note)
}

@(private)
ai_task_fail :: proc(task:^Ai_Task,format:string,args:..any) {
    ai_note(task,format,..args)
    task.state=.Failed
}

@(private)
ai_task_select :: proc(m:^Ai,task:^Ai_Task) {
    m.selected=task.id
    // m.agent is the one of the main chat: an inspected agent keeps its own.
    if base.text_get(task.agent[:])!="" && !ai_task_inspected(task) {base.text_set(m.agent[:],base.text_get(task.agent[:]))}
    m.chat_open,m.stick=true,true
}

@(step="input",stage="begin")
ai_input :: proc(s:^Session,m:^Ai) {
    if s.app==nil || s.app.platform==nil || !s.has_project {return}
    ai_initialize(s)
    for &task in m.tasks[:m.task_count] {
        if task.image_write.busy {host.app_png_write_poll(s.app,&task.image_write)}
        for &write in task.reference_writes {if write.busy {host.app_png_write_poll(s.app,&write)}}
        if task.review_deferred {ai_task_review_follow(s,&task)}
    }
    if m.pending && s.frame>m.submit_frame {
        m.pending=false
        region:=m.has_region?m.region:free_region(s.gui,s.viewport.window)
        // The chat of an agent outside the editor is not written to: a message goes to the main chat.
        continuing:=m.selected
        agent:=base.text_get(m.agent[:])
        if selected:=ai_task_find(m,continuing);selected!=nil {
            if ai_task_external(selected) {continuing=0} else if ai_task_subagent(selected) {agent=""}
        }
        first:=m.main==0
        task,message:=ai_task_create(s,m,region,string(m.prompt[:m.prompt_length]),agent,continuing,base.text_get(m.pending_model[:]),base.text_get(m.pending_effort[:]))
        m.pending_model,m.pending_effort={},{}
        if task==nil {
            notify(s,message)
        } else {
            // From the empty chat the composer goes down to its place.
            if first && m.composer_empty_y>0 && s.gui!=nil {m.composer_drop_at,m.composer_drop_from=max(s.gui.ctx.time,1e-6),m.composer_empty_y}
            m.prompt_length,m.reference_count,m.attachment_count=0,0,0
            m.range={}
            m.about=0
            m.annotations.group_count=0
            m.has_region=false
            ai_task_select(m,task)
        }
        m.focus=true
    }
    ai_play_follow(s)
    ai_task_poll(s,m)
    ai_external_poll(s,m)
    ai_deliveries_advance(s,m)
    ai_queue_advance(s,m)
}

AI_QUESTION_NAMES :: [Ai_Question]string{.None="",.Text="text",.Single="single",.Multi="multi",.Confirm="confirm"}

ai_question_parse :: proc(text:string) -> (kind:Ai_Question,ok:bool) {
    names:=AI_QUESTION_NAMES
    if text=="" {return .None,true}
    for value,name in names {if value!="" && value==text {return name,true}}
    return .None,false
}

// The choices of a question, one per line, without empty ones.
ai_question_options :: proc(task:^Ai_Task,out:[][]u8) -> int {
    count,start:=0,0
    text:=string(task.options[:task.options_length])
    for index in 0..=len(text) {
        if index<len(text) && text[index]!='\n' {continue}
        line:=text[start:index]
        start=index+1
        if len(line)==0 {continue}
        if count<len(out) {out[count]=transmute([]u8)line}
        count+=1
    }
    return count
}

// The task a request belongs to, by the header of its turn: zero when the
// call comes from outside a turn.
// A turn that ends takes the run it kept alive with it.
ai_run_release :: proc(s:^Session,task:^Ai_Task) {
    if task!=nil {run_stop(s,task.id)}
}

// The game a turn looks at: a run of its own, or that of the user it began inside.
ai_task_run :: proc(s:^Session,task:^Ai_Task) -> ^Run {
    if r:=run_find(s,task.id);r!=nil {return r}
    if task.play {return run_find(s,0)}
    return nil
}

ai_task_of_call :: proc(s:^Session,call:^api.Call) -> int {
    task:=ai_task_named(s.ai,call.client_tag) if call!=nil else nil
    return task.id if task!=nil else 0
}

// The task context of the commands an agent runs: this and the serial of
// its process (Ai_Worker.agent).
AI_AGENT_TAG :: "agent-"

// The turn a task context names: a turn by its name, as the MCP server of
// its session sends it, or the one the agent of that serial runs now.
ai_task_named :: proc(m:^Ai,tag:string) -> ^Ai_Task {
    if m==nil || tag=="" {return nil}
    if strings.has_prefix(tag,AI_AGENT_TAG) {
        serial,ok:=strconv.parse_int(tag[len(AI_AGENT_TAG):],10)
        if !ok || serial<=0 {return nil}
        for &worker in m.workers {
            if worker.agent==serial && worker.task>0 {return ai_task_find(m,worker.task)}
        }
        return nil
    }
    for &task in m.tasks[:m.task_count] {
        if base.text_get(task.name[:])==tag {return &task}
    }
    return nil
}
