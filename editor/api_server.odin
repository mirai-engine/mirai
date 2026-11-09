package editor

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import "mirai:core"
import "mirai:editor/api"
import escene "mirai:engine/scene"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The agent API of the editor: the server of editor/api (JSON-RPC and MCP on
// 127.0.0.1) with the methods of the editor registered on it. The server is
// polled once per frame between frames, so every handler runs on the main
// thread and may advance frames itself (engine.step, capture). A
// method that edits the scene is one transaction of the history: one step of
// undo, or nothing at all when any part of it fails.

API_VERSION :: "12"
API_INSTRUCTIONS :: "Mirai editor. The tools are the basics of a scene; call runs any other method, of the editor or of a plugin, by its name with its params. engine.describe lists the methods and the plugins of the project, and with methods, prefix or plugin gives their schemas; mirai mcp --plugins <names> lists the tools of those plugins too. Every method takes _select, the fields of its result to keep (a.b,c[0].d), and _wait_until, a condition (phase=Built) it is called again until. scene.inspect gives the ids of the entities."
API_METHOD_CAPACITY :: 384 // methods registered by the editor and its plugins; the server adds engine.describe
API_PATH_BYTES :: 1024
API_STORAGE_BYTES :: 256*1024 // the largest storage the API reads and writes
API_IDLE_WAIT :: 10*time.Millisecond // a manual editor without calls: how often it looks at builds, imports and collaboration
API_ACTIVE :: 2*time.Second // after a call, how long the editor keeps the rate of a window with focus
API_SETTLE_FRAMES :: 600 // the most frames a handler runs to finish what it asked of the next ones
API_BUILD_SECONDS :: 600 // how long a call waits for a build it needs
API_SHADERS_SECONDS :: 600 // how long a call that draws waits for shaders that changed on disk

Api_Handler :: #type proc(s:^Session,call:^api.Call)

@(private)
Api_Entry :: struct {
    state:^Api_State,
    session:^Session,
    run:Api_Handler,
}

// Memory of the API; the storage only points at it because the server must stay where it was made.
Api_State :: struct {
    server:api.Server,
    schema:serial.Schema,
    types:[]serial.Type_Index, // by table of the world info; TYPE_NONE when a component is not plain data
    storage_types:[]serial.Type_Index, // by storage of the world info; TYPE_NONE when it is not plain data of the World
    queue_types:[]serial.Type_Index,   // by storage of the world info: of the items of its core.Queue; TYPE_NONE without one that is plain data
    names:[]serial.Choice,     // the names of the types @(names), which schema.named points into
    largest:int,               // bytes of the largest component or storage the API shows
    entries:[API_METHOD_CAPACITY]Api_Entry,
    count:int,
    refused:int,                // methods that were not registered
    refusal:string,             // why the first one was not, in refusal_buffer
    refusal_buffer:[256]u8,
    poll_temp:runtime.Allocator,
    allocator:runtime.Allocator,
    in_call:int,
    last_call:time.Tick, // when a call arrived last: an agent that drives the editor keeps it at its rate
    stepping:bool,
    waiting:int,    // handlers inside api_wait: what runs meanwhile holds no world of theirs
    restart:bool,   // a Build asked to start the editor again while a call waits for it
    step_frames:u64, // app.stats.frames when the times of the functions were last read
    manual:bool,       // frames advance only when asked to: engine.step, capture, editor.input
    port:int,
    library_generation:int,
    plugin:string, // of the provider whose methods are being registered; empty for the editor
    scripts:[EDITOR_RUNS]Run_Script, // the input play.input scheduled for each place of Session.runs
    step_frame:Api_Step_Frame,      // a frame of a step in place of one of the editor; for tests without a window
}

@(storage)
Api :: struct {
    state:^Api_State,
    // The parts of the last frame of the editor loop, in ms.
    begin_ms,tools_ms,panels_ms,end_ms:f32,
}

@(private)
api_of :: proc(s:^Session) -> ^Api {
    if s.info==nil || s.editor_world==nil {return nil}
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Api)
}

api_state :: proc(s:^Session) -> ^Api_State {
    a:=api_of(s)
    return a==nil?nil:a.state
}

// The port the API listens on; 0 without one.
api_port :: proc(s:^Session) -> int {
    st:=api_state(s)
    return st==nil?0:api.server_port(&st.server)
}

Api_Open_Error :: enum {None,No_Storage,Server,Methods}

// Opens the server and registers the methods. port 0 lets the system choose.
// A method that cannot be registered stops the opening with the reason.
api_open :: proc(s:^Session,port:int,manual:bool) -> Api_Open_Error {
    a:=api_of(s)
    if a==nil {return .No_Storage}
    st:=new(Api_State)
    st.allocator=context.allocator
    st.manual=manual
    if error:=api.server_init(&st.server,{port=port,name="mirai",version=API_VERSION,instructions=API_INSTRUCTIONS,docs_root=s.engine_root,max_methods=API_METHOD_CAPACITY+1,max_response=4<<20,allocator=context.allocator});error!=.None {
        free(st)
        return .Server
    }
    st.server.assets={s,asset_text_resolve}
    st.server.entities={s,api_entity_text_resolve}
    api_schema_build(s,st)
    st.port=api.server_port(&st.server)
    a.state=st
    api_plugins_set(s,st)
    guides:=AI_GUIDES
    api.server_guides_set(&st.server,guides[:])
    api_methods_register(s,st)
    api_providers_register(s)
    if st.refused>0 {
        fmt.eprintfln("mirai: the API does not open: %d methods did not register, the first: %s",st.refused,st.refusal)
        api_close(s)
        return .Methods
    }
    st.library_generation=s.library_generation
    st.server.pause,st.server.user=api_server_pause,s
    api_disk_baseline(s)
    api_port_file_write(s,st.port)
    return .None
}

api_close :: proc(s:^Session) {
    a:=api_of(s)
    if a==nil || a.state==nil {return}
    st:=a.state
    api_port_file_remove(s)
    api.server_destroy(&st.server)
    api_schema_free(st)
    free(st)
    a.state=nil
}

@(private)
api_port_file_path :: proc(s:^Session) -> string {
    return project.path(s.project_root,".mirai",api.PORT_FILE,allocator=context.temp_allocator)
}

@(private)
api_port_file_write :: proc(s:^Session,port:int) {
    if !s.has_project {return}
    engine:=engine_folder_here(s)
    data,error:=json.marshal(api.Port_File{port,os.get_pid(),s.project_root,engine,s.engine_stamp,build.target_stamp_of(s.project_root,.Editor,context.temp_allocator),s.headless},{pretty=true},context.temp_allocator)
    if error!=nil {return}
    path:=api_port_file_path(s)
    _=os.make_directory_all(path[:strings.last_index_byte(path,'/')])
    _=serial.file_write_atomic(path,data)
}

// The port file again, after a Build replaced the library it names.
@(private)
api_port_file_refresh :: proc(s:^Session) {
    if st:=api_state(s);st!=nil {api_port_file_write(s,st.port)}
}

// Only the file this process wrote: another editor of the project may have written its own.
@(private)
api_port_file_remove :: proc(s:^Session) {
    if !s.has_project {return}
    path:=api_port_file_path(s)
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {return}
    written:api.Port_File
    if json.unmarshal(data,&written,allocator=context.temp_allocator)==nil && written.pid==os.get_pid() {_=os.remove(path)}
}

// The schema of every component of the world, to read and write their values as JSON.
@(private)
api_schema_build :: proc(s:^Session,st:^Api_State) {
    serial.schema_init(&st.schema,context.allocator)
    st.names,_=core.schema_named(&st.schema,s.info)
    st.types=make([]serial.Type_Index,len(s.info.tables))
    for &t,i in s.info.tables {
        st.types[i]=serial.TYPE_NONE
        if t.place!=.World {continue}
        index,ok:=serial.schema_add_type_info(&st.schema,t.info)
        if ok {
            st.types[i]=index
            st.largest=max(st.largest,t.info.size)
            for field in t.fields {serial.schema_describe(&st.schema,index,field.name,field.text)}
        }
    }
    st.storage_types=make([]serial.Type_Index,len(s.info.storages))
    st.queue_types=make([]serial.Type_Index,len(s.info.storages))
    for &info,i in s.info.storages {
        st.storage_types[i],st.queue_types[i]=serial.TYPE_NONE,serial.TYPE_NONE
        if _,item,queued:=api_queue_of(info.info);queued && info.place==.World && !info.by_world {
            if index,ok:=serial.schema_add_type_info(&st.schema,item);ok {st.queue_types[i]=index}
        }
        if info.place!=.World || info.by_world || info.info==nil || info.info.size>API_STORAGE_BYTES {continue}
        if index,ok:=serial.schema_add_type_info(&st.schema,info.info);ok {
            st.storage_types[i]=index
            st.largest=max(st.largest,info.info.size)
        }
    }
}

// Frees what api_schema_build made.
@(private)
api_schema_free :: proc(st:^Api_State) {
    delete(st.schema.named);delete(st.names)
    if st.schema.types!=nil {serial.schema_destroy(&st.schema)}
    delete(st.types);delete(st.storage_types);delete(st.queue_types)
    st.schema,st.names,st.types,st.storage_types,st.queue_types,st.largest={},nil,nil,nil,nil,0
}

@(private)
api_table_index :: proc(s:^Session,t:^core.Table_Info) -> int {
    return int((uintptr(t)-uintptr(raw_data(s.info.tables)))/size_of(core.Table_Info))
}

// Answers what arrived. Between frames.
@(private)
api_poll :: proc(s:^Session) {
    st:=api_state(s)
    if st==nil || st.in_call>0 {return}
    st.poll_temp=context.temp_allocator
    if st.library_generation!=s.library_generation {
        if !api.server_methods_reset(&st.server) {return}
        st.count,st.refused=0,0
        api_schema_free(st)
        api_schema_build(s,st)
        api_plugins_set(s,st)
        api_methods_register(s,st)
        api_providers_register(s)
        if st.refused>0 {log.errorf("%d methods of the API were not registered after the reload, the first: %s",st.refused,st.refusal)}
        st.library_generation=s.library_generation
    }
    api.server_poll(&st.server)
}

// A manual editor (headless, driven by the API) does not draw frames by itself: it answers requests and waits.
@(private)
api_idle :: proc(s:^Session) -> bool {
    st:=api_state(s)
    if st==nil || !st.manual || st.stepping {return false}
    api_poll(s)
    build_poll(s)
    // No frame runs the requests here: the restart a Build asks for would wait for engine.step.
    if .Restart in s.requests {
        s.requests-={.Restart}
        restart(s,{"--built"})
        return true
    }
    api_jobs(s)
    api.server_wait(&st.server,API_IDLE_WAIT)
    return true
}

// What runs beside the frames of a manual editor, between frames.
@(private)
api_jobs :: proc(s:^Session) {
    import_poll(s)
    git_poll(s)
    projects_poll(s)
    plugins_git_poll(s)
    play_plugin_poll(s)
    runs_pump(s)
    collab_update(s)
    recovery_update(s)
}

// Keeps the editor going from inside a handler until pending says false:
// frames with a window, so the user and other work go on, and only the jobs
// in a manual editor, whose frames advance when asked. The library a build
// left loads meanwhile: the handler holds nothing of the worlds, and no text
// of the temporary allocator, across this. False when the time ran out or the
// editor is ending.
api_wait :: proc(s:^Session,seconds:f64,user:rawptr,pending:proc(s:^Session,user:rawptr)->bool) -> bool {
    st:=api_state(s)
    if st==nil {return !pending(s,user)}
    started:=time.tick_now()
    st.waiting+=1
    defer {
        st.waiting-=1
        if st.waiting==0 && st.restart {
            st.restart=false
            s.requests+={.Restart}
        }
    }
    for pending(s,user) {
        if s.quit || time.duration_seconds(time.tick_since(started))>seconds {return false}
        if st.manual {
            temp:=runtime.default_temp_allocator_temp_begin()
            build_poll(s)
            api_jobs(s)
            runtime.default_temp_allocator_temp_end(temp)
            time.sleep(API_IDLE_WAIT)
        } else if api_frames(s,1,0)==0 {
            return false
        }
    }
    return true
}

// Advances whole frames from inside a handler until pending says false or
// frames ran out: what the handler asked of the next frames is done when it
// answers, also in a manual editor. False when they ran out or the editor is
// ending.
api_settle :: proc(s:^Session,user:rawptr,pending:proc(s:^Session,user:rawptr)->bool,frames:=API_SETTLE_FRAMES) -> bool {
    if api_state(s)==nil {return !pending(s,user)}
    for _ in 0..<frames {
        if !pending(s,user) {return true}
        if api_frames(s,1,0)==0 || s.quit {return false}
    }
    return !pending(s,user)
}

// Between two calls of _wait_until the editor goes on as a handler that waits does.
@(private)
api_server_pause :: proc(server:^api.Server,seconds:f64) -> bool {
    s:=(^Session)(server.user)
    st:=api_state(s)
    context.temp_allocator=st.poll_temp
    st.in_call+=1
    defer st.in_call-=1
    going_on :: proc(s:^Session,user:rawptr) -> bool {return !s.quit}
    api_wait(s,seconds,nil,going_on)
    return !s.quit
}

// What is on disk when the editor opens, against which api_disk_sync looks.
@(private)
api_disk_baseline :: proc(s:^Session) {
    if s.app!=nil {host.app_assets_watch_now(s.app)}
    if s.build!=nil && s.has_project {s.build.shader_sources=shaders_fingerprint(s.project_root)}
}

// What changed on disk since the last call is there for this one, whoever
// changed it: assets are read again where they are loaded, with unsaved ones
// kept, and shaders are published; a call that draws waits for them. False,
// with the call failed, when they could not be published.
@(private)
api_disk_sync :: proc(s:^Session,call:^api.Call) -> bool {
    if s.app==nil {return true}
    host.app_assets_watch_now(s.app)
    if s.build==nil || !s.has_project {return true}
    sources:=shaders_fingerprint(s.project_root)
    if sources==s.build.shader_sources {return true}
    s.build.shader_sources=sources
    programs_publish_request(s)
    if !api_call_draws(call) {return true}
    if ok,message:=programs_wait(s,API_SHADERS_SECONDS,true);!ok {
        api.call_fail(call,api.SERVER_ERROR,message)
        return false
    }
    return true
}

// Whether a method draws the scene or starts what draws it.
@(private)
api_call_draws :: proc(call:^api.Call) -> bool {
    switch call.method.name {
    case "capture","play.start","play.record","view.viewport","material.preview.capture","animation.capture","ui.capture": return true
    }
    return false
}

// Whether an agent drives the editor: a call runs, or one arrived within API_ACTIVE.
api_active :: proc(s:^Session) -> bool {
    st:=api_state(s)
    if st==nil {return false}
    return st.in_call>0 || st.stepping || st.last_call!={} && time.tick_since(st.last_call)<API_ACTIVE
}

@(private)
api_trampoline :: proc(call:^api.Call) {
    entry:=(^Api_Entry)(call.user)
    st:=entry.state
    // The server lends its scratch as the temporary allocator of a request, and a frame empties the
    // temporary allocator: a method that advances frames would lose its own call.
    context.temp_allocator=st.poll_temp
    st.in_call+=1
    defer st.in_call-=1
    st.last_call=time.tick_now()
    task:^Ai_Task
    if call.client_tag!="" {
        if entry.session.ai==nil {api.call_fail(call,api.SERVER_ERROR,"The editor has no AI task context");return}
        task=ai_task_named(entry.session.ai,call.client_tag)
        if task==nil || task.state!=.Running || task.stop || !ai_task_current(entry.session,task) {
            api.call_fail(call,api.SERVER_ERROR,"The agent's turn is no longer active")
            return
        }
        if task.finish_called && .Read_Only not_in call.method.flags {
            api.call_fail(call,api.SERVER_ERROR,"The agent has already finished this turn")
            return
        }
        // A call of an agent's command belongs to the turn it runs when the call arrives.
        call.client_tag=strings.clone(base.text_get(task.name[:]),call.allocator)
    }
    // An agent outside the editor works in a turn of its own, which it does not name.
    external:=ai_external_turn(entry.session,call.client_name) if task==nil && ai_external_call(call) else nil
    turn:=task if task!=nil else external
    // What the user left pending is a step of the user before the call edits.
    edits:=entry.session.edits
    if edits!=nil && api_call_edits(call) {
        if turn!=nil || edits.open || edits.commit || edits.preview {tools_release(entry.session)}
        edits_commit(edits,edited_world(entry.session),entry.session.selection)
    }
    if edits!=nil {edits_select(edits,edited_world(entry.session),document_selection(entry.session))}
    task_id,external_id:=task!=nil?task.id:0,external!=nil?external.id:0
    // What the call works on is named before it runs: a deletion takes its name with it.
    target_buffer:[96]u8
    target:=ai_call_target(entry.session,call.raw,target_buffer[:]) if turn!=nil else ""
    refs_buffer:[256]u8
    refs:=ai_call_refs(call.raw,refs_buffer[:]) if turn!=nil else ""
    serial_before:=edits!=nil?edits.serial:0
    started:=time.tick_now()
    if edits!=nil && !api_call_as_user(call) {edits.author=turn!=nil?Edit_Author(turn.id):EDIT_AUTHOR_API}
    collab_held_begin(entry.session)
    event(entry.session,"api",call.method.name)
    if st.in_call>1 || api_disk_sync(entry.session,call) {entry.run(entry.session,call)}
    collab_held_end(entry.session,call)
    if edits!=nil {
        // A gesture the call opened and ended is its step, without waiting for the frame.
        if edits.commit && edits.opener==edits.author {
            sections_sync(entry.session)
            edits_flush(edits,edited_world(entry.session),document_selection(entry.session))
        }
        // What the call selected is a step of its author.
        edits_select(edits,edited_world(entry.session),document_selection(entry.session))
        edits.author=EDIT_AUTHOR_USER
    }
    files_settle(entry.session)
    if task_id!=0 {task=ai_task_find(entry.session.ai,task_id)}
    if task!=nil && base.text_get(task.name[:])!=call.client_tag {task=nil}
    if external_id!=0 {task=ai_task_find(entry.session.ai,external_id)}
    if task!=nil {ai_tool_note(entry.session,task,call.method.name,target,refs,call.failed?call.error.message:"",time.tick_since(started))}
    if task!=nil && !call.failed && .Read_Only not_in call.method.flags && !strings.has_prefix(call.method.name,"engine.") && entry.session.edits!=nil && entry.session.edits.serial!=serial_before {
        ai_review_record(entry.session,task,serial_before)
        ai_task_dirty(task)
        ai_task_persist(entry.session,task)
    }
}

// Whether a method may edit the document: not one that only reads, runs
// frames, input or captures of the editor, moves its camera or selection, or
// ends a turn.
@(private)
api_call_edits :: proc(call:^api.Call) -> bool {
    switch call.method.name {
    case "finish","editor.select","camera.set","editor.section_view","editor.section_travel": return false
    }
    return .Read_Only not_in call.method.flags && !api_call_as_user(call)
}

// Whether a method runs frames, input or captures of the editor as the user
// would: what they change is the user's.
@(private)
api_call_as_user :: proc(call:^api.Call) -> bool {
    name:=call.method.name
    return name=="editor.input" || name=="capture" || strings.has_prefix(name,"engine.")
}

Api_Method :: struct {
    name,summary:string,
    params,result:typeid,
    params_info,result_info:^runtime.Type_Info,
    defaults:rawptr,
    run:Api_Handler,
    flags:api.Method_Flags,
    params_schema,result_schema:string,
    writes_result:bool, // the handler writes the result into call.out; result only gives its schema
}

// A provider is the sole field of an Editor storage with a default procedure.
// The current library supplies its descriptor; no callback is retained in the World.
Api_Provider :: struct {register:proc(s:^Session)}

// The methods of a provider belong to the plugin that gives it.
@(private)
api_providers_register :: proc(s:^Session) {
    found:[PROVIDER_CAPACITY]Api_Provider
    plugins:[PROVIDER_CAPACITY]string
    st:=api_state(s)
    for provider,i in found[:provided_all(s,found[:],plugins[:])] {
        if provider.register==nil {continue}
        if st!=nil {st.plugin=plugins[i]}
        provider.register(s)
    }
    if st!=nil {st.plugin=""}
}

// The plugins the project finds and the ones it uses, for engine.describe.
@(private)
api_plugins_set :: proc(s:^Session,st:^Api_State) {
    api.server_plugins_set(&st.server,nil)
    if !s.has_project {return}
    p,error:=project.open(s.project_root,s.engine_root,context.temp_allocator)
    if error.code!=.None {return}
    plugins:=make([]api.Plugin,len(p.plugins),context.temp_allocator)
    for &plugin,i in p.plugins {plugins[i]={base.text_get(plugin.manifest.name[:]),slice.contains(p.active,i)}}
    api.server_plugins_set(&st.server,plugins)
}

api_method_register :: proc(s:^Session,m:Api_Method) -> bool {
    st:=api_state(s)
    return st!=nil && api_register(s,st,m)
}

api_register :: proc(s:^Session,st:^Api_State,m:Api_Method) -> bool {
    refuse :: proc(st:^Api_State,format:string,args:..any) -> bool {
        st.refused+=1
        if st.refused==1 {st.refusal=fmt.bprintf(st.refusal_buffer[:],format,..args)}
        return false
    }
    if st.count>=len(st.entries) {
        return refuse(st,"%s: the API holds %d methods; raise API_METHOD_CAPACITY in editor/api_server.odin",m.name,API_METHOD_CAPACITY)
    }
    entry:=&st.entries[st.count]
    entry^={state=st,session=s,run=m.run}
    result:=api.method_register(&st.server,{
        name=m.name,summary=m.summary,plugin=st.plugin,params=m.params,result=m.result,defaults=m.defaults,
        params_info=m.params_info,result_info=m.result_info,
        params_schema=m.params_schema,result_schema=m.result_schema,handler=api_trampoline,user=entry,flags=m.flags,writes_result=m.writes_result,
    })
    if result!=.None {
        return refuse(st,"%s could not be registered: %v %s",m.name,result,st.server.schema.error)
    }
    st.count+=1
    return true
}

// ---------------------------------------------------------------- guards

// What every method that changes the scene checks first. A drag in progress
// ends before the edit. The scene of the document can be edited while a game
// runs: the game keeps its own copy and the user sees the changes when the
// run stops.
api_guard :: proc(s:^Session,call:^api.Call) -> bool {
    tools_release(s)
    edits_cancel(s.edits,edited_world(s))
    if s.edits.open || s.edits.commit || s.edits.preview {
        api.call_fail(call,api.SERVER_ERROR,edits_error_text(s.edits.error))
        return false
    }
    return true
}

// Opens the transaction of an edit. False, with the call failed, when the scene cannot be edited now.
api_edit_begin :: proc(s:^Session,call:^api.Call,label:string) -> bool {
    api_guard(s,call) or_return
    if !edits_begin(s.edits,document_selection(s),label) {
        api.call_fail(call,api.SERVER_ERROR,edits_error_text(s.edits.error))
        return false
    }
    if error:=edits_cancel_prepare(s.edits,edited_world(s));error!=.None {
        s.edits.open,s.edits.commit=false,false
        s.edits.error=error
        api.call_fail(call,api.SERVER_ERROR,edits_error_text(error))
        return false
    }
    return true
}

// Closes it: a step of undo when everything applied, nothing at all otherwise.
api_edit_end :: proc(s:^Session,call:^api.Call,applied:bool) -> bool {
    w:=edited_world(s)
    selection:=document_selection(s)
    if !applied || call.failed {
        edits_cancel(s.edits,w)
        selection_restore(selection,w,s.edits.selection[:])
        if !call.failed {api.call_fail(call,api.SERVER_ERROR,"The edit could not be applied")}
        return false
    }
    sections_sync(s)
    edits_end(s.edits)
    if !edits_commit(s.edits,w,selection) && s.edits.error!=.No_Change {
        error:=s.edits.error
        edits_cancel(s.edits,w)
        selection_restore(selection,w,s.edits.selection[:])
        api.call_fail(call,api.SERVER_ERROR,edits_error_text(error))
        return false
    }
    selection_prune(selection,w)
    return true
}

// ---------------------------------------------------------------- reading JSON by hand

// The params of a method without a params type: keys in any order, some of
// them values of schemas that only the world knows.
Rpc_Args :: struct {
    r:serial.Text_Reader,
    call:^api.Call,
    text:string,
    key:[64]u8,
    failed:bool,
}

Rpc_Object :: struct {started:bool}

rpc_init :: proc(a:^Rpc_Args,call:^api.Call,text:string) {
    a^={call=call,text=text}
    api.call_reader_init(call,&a.r,text)
}

rpc_fail :: proc(a:^Rpc_Args,format:string,args:..any) -> bool {
    if !a.failed {
        a.failed=true
        api.call_failf(a.call,api.INVALID_PARAMS,format,..args)
    }
    return false
}

// A failure of the shape or the type of params read by hand: its data says
// what the method takes.
rpc_fail_type :: proc(a:^Rpc_Args,format:string,args:..any) -> bool {
    if !a.failed {
        a.failed=true
        usage:=a.call.server!=nil && a.call.method!=nil?api.params_usage(a.call.server,a.call.method):""
        api.call_fail(a.call,api.INVALID_PARAMS,fmt.aprintf(format,..args,allocator=a.call.allocator),usage)
    }
    return false
}

// A key the object does not take: which ones it does, the nearest first when
// the key looks like it.
rpc_fail_unknown :: proc(a:^Rpc_Args,key:string,valid:..string) -> bool {
    nearest:=""
    closest:=max(len(key)/2,2)+1
    for name in valid {
        if distance:=strings.levenshtein_distance(key,name,context.temp_allocator);distance<closest {nearest,closest=name,distance}
    }
    if nearest!="" {return rpc_fail_type(a,"unknown field %q; did you mean %s? It takes %s",key,nearest,strings.join(valid,", ",context.temp_allocator))}
    return rpc_fail_type(a,"unknown field %q; it takes %s",key,strings.join(valid,", ",context.temp_allocator))
}

rpc_object_begin :: proc(a:^Rpc_Args,what:string) -> bool {
    if a.failed {return false}
    if !serial.text_accept(&a.r,'{') {return rpc_fail_type(a,"%s must be an object",what)}
    return true
}

// The next key of an open object, with the reader at its value. more is
// false at the end of the object and after a failure.
rpc_next :: proc(a:^Rpc_Args,o:^Rpc_Object) -> (key:string,more:bool) {
    r:=&a.r
    if a.failed || serial.text_accept(r,'}') {return}
    separated:=!o.started || serial.text_accept(r,',')
    o.started=true
    name,read:=serial.text_string(r)
    if !separated || !read || !serial.text_accept(r,':') {
        line,column:=serial.text_position(a.text,r.offset)
        rpc_fail_type(a,"malformed JSON at line %d column %d",line,column)
        return
    }
    count:=copy(a.key[:],name)
    return string(a.key[:count]),true
}

@(private)
rpc_finite :: proc "contextless" (values:..f32) -> bool {
    for v in values {
        if v-v!=0 {return false}
    }
    return true
}

@(private)
rpc_number :: proc(a:^Rpc_Args,what:string) -> (value:f32,ok:bool) {
    if a.failed {return}
    bits,read:=serial.text_read_float(&a.r,4)
    value=transmute(f32)u32(bits)
    if !read || !rpc_finite(value) {return 0,rpc_fail_type(a,"%s must be a finite number",what)}
    return value,true
}

@(private)
rpc_vector :: proc(a:^Rpc_Args,what:string,out:[]f32) -> bool {
    if a.failed {return false}
    if !serial.text_accept(&a.r,'[') {return rpc_fail_type(a,"%s must be an array of %d numbers",what,len(out))}
    for &value,i in out {
        if i>0 && !serial.text_accept(&a.r,',') {return rpc_fail_type(a,"%s must be an array of %d numbers",what,len(out))}
        value=rpc_number(a,what) or_return
    }
    if !serial.text_accept(&a.r,']') {return rpc_fail_type(a,"%s must be an array of %d numbers",what,len(out))}
    return true
}

rpc_bool :: proc(a:^Rpc_Args,what:string) -> (value,ok:bool) {
    if a.failed {return}
    if serial.text_keyword(&a.r,"true") {return true,true}
    if serial.text_keyword(&a.r,"false") {return false,true}
    return false,rpc_fail_type(a,"%s must be true or false",what)
}

rpc_unsigned :: proc(a:^Rpc_Args,what:string) -> (value:u64,ok:bool) {
    if a.failed {return}
    negative,magnitude,read:=serial.text_integer(&a.r)
    if !read || negative {return 0,rpc_fail_type(a,"%s must be a non negative integer",what)}
    return magnitude,true
}

// The id of the entity a param read by hand names, as any param of type
// base.Entity_Id takes it; null is none.
rpc_id :: proc(a:^Rpc_Args,what:string) -> (id:base.Entity_Id,ok:bool) {
    if a.failed {return}
    if serial.text_keyword(&a.r,"null") {return 0,true}
    text,read:=serial.text_string(&a.r)
    if !read {return 0,rpc_fail_type(a,"%s must be the name of an entity, a path Parent/Child, an id or a handle",what)}
    entities:serial.Text_Entities
    if a.call.server!=nil {entities=a.call.server.entities}
    if entities.resolve==nil {
        value,parsed:=serial.text_parse_hex(text)
        if !parsed {return 0,rpc_fail_type(a,"%s must be an entity id",what)}
        return base.Entity_Id(value),true
    }
    problem:string
    if id,problem=entities.resolve(entities.user,text);problem!="" {return 0,rpc_fail(a,"%s: %s",what,problem)}
    return id,true
}

rpc_text :: proc(a:^Rpc_Args,what:string,out:[]u8) -> (text:string,ok:bool) {
    if a.failed {return}
    value,read:=serial.text_string(&a.r)
    if !read {return "",rpc_fail_type(a,"%s must be a string",what)}
    if len(value)>len(out) {return "",rpc_fail_type(a,"%s is longer than %d bytes",what,len(out))}
    return string(out[:copy(out,value)]),true
}

// The text of the next value, whatever it is.
rpc_raw :: proc(a:^Rpc_Args) -> (text:string,ok:bool) {
    if a.failed {return}
    serial.text_space(&a.r)
    start:=a.r.offset
    if !serial.text_skip(&a.r) {
        line,column:=serial.text_position(a.text,a.r.error.offset)
        return "",rpc_fail_type(a,"malformed JSON at line %d column %d",line,column)
    }
    return a.text[start:a.r.offset],true
}

// ---------------------------------------------------------------- small helpers

// The id of an entity of a world, 0 without one.
api_entity_id :: proc(w:core.World_Ref,e:core.Entity) -> base.Entity_Id {
    return core.id_of(core.read(core.world_table_of(w,core.Id)),e)
}

// The live entity of a world with an Id, as of its last settle; NONE for 0
// or an Id no entity has.
api_entity :: proc(w:core.World_Ref,id:base.Entity_Id) -> core.Entity {
    return core.entity_of(core.world_entities(w),id)
}

// A turn of an AI agent does not throw away what the user has not saved: the
// method fails and the agent has to ask. what says what it would have done.
@(private)
api_turn_refused :: proc(s:^Session,call:^api.Call,what:string) -> bool {
    if ai_task_of_call(s,call)==0 {return false}
    api.call_fail(call,api.SERVER_ERROR,api_error_text(call,"A turn of an AI agent cannot %s; finish with a question for the user instead",what))
    return true
}

@(private)
api_error_text :: proc(call:^api.Call,format:string,args:..any) -> string {
    return fmt.aprintf(format,..args,allocator=call.allocator)
}

@(private)
api_lower :: proc(text:string,allocator:=context.temp_allocator) -> string {
    return strings.to_lower(text,allocator)
}

@(private)
Api_Part :: enum u8 {Begin,Tools,Panels,End}

// Records how long a step of the editor loop took, for engine.status.
@(private)
api_timed :: proc(s:^Session,part:Api_Part,started:u64) {
    a:=api_of(s)
    if a==nil {return}
    ms:=f32(platform.clock_ns()-started)/1e6
    switch part {
    case .Begin:  a.begin_ms=ms
    case .Tools:  a.tools_ms=ms
    case .Panels: a.panels_ms=ms
    case .End:    a.end_ms=ms
    }
}
