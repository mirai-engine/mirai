package editor

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// A session with the interface and the storages the entries read, and the registry of the methods.
@(private="file")
Commands_Test :: struct {
    world:Shell_Test_World,
    ctx:ui.Context,
    g:Editor_Ui,
    app:host.App,
    viewport:Viewport,
    selection:history.Selection,
    inspector:Inspector,
    edits:history.Edits,
    document:Document,
    build:Build_State,
    ai:Ai,
    finder:Finder,
    graphics:Graphics,
    materials:Materials,
    content:Content,
    commands:Api,
    s:Session,
    entity:core.Entity,
}

@(private="file")
commands_test_open :: proc(t:^testing.T,f:^Commands_Test) -> bool {
    if !test_world_init(t,&f.world) {return false}
    f.entity=core.create(&f.world.entities)
    core.add(&f.world.ids,f.entity,core.Id{1})
    core.add(&f.world.names,f.entity,core.name_make("Object"))
    core.add(&f.world.transforms,f.entity,core.TRANSFORM_IDENTITY)
    test_world_settle(&f.world)
    testing.expect(t,test_ui_init(&f.ctx,{}))
    f.g={ctx=&f.ctx,layout={left_open=true,right_open=true}}
    viewport_init(&f.viewport)
    f.s=Session{info=test_world_info(&f.world),edit_world=&f.world,headless=true,app=&f.app,gui=&f.g,viewport=&f.viewport,selection=&f.selection,inspector=&f.inspector,edits=&f.edits,document=&f.document,build=&f.build,ai=&f.ai,finder=&f.finder,graphics=&f.graphics,materials=&f.materials,content=&f.content}
    history.edits_reset(&f.edits,edited_world(&f.s))
    return test_commands_open(t,&f.s,&f.commands)
}

@(private="file")
commands_test_close :: proc(f:^Commands_Test) {
    test_commands_close(&f.s)
    history.edits_free(&f.edits)
    delete(f.selection.entities)
    delete(f.s.copied)
    core.value_free(&f.inspector,type_info_of(Inspector))
    core.value_free(&f.content,type_info_of(Content))
    viewport_free(&f.viewport)
    ui.context_destroy(&f.ctx)
    test_world_destroy(&f.world)
}

// What the menus, the shortcuts and the buttons of the editor did before they were entries of methods.
@(private="file")
COMMANDS_OF_THE_ACTIONS :: [?]string{
    "new","open","save","save_all","save_as","build","quit",
    "undo","redo","copy","paste","duplicate","delete","rename","select_all","deselect","group",
    "tool_move","tool_rotate","tool_scale","space","snap",
    "focus","reset_camera","scene_thumbnail","grid","indicators","output_frame","game_detail","studio_light","hierarchy_panel","inspector_panel","console_panel","build_panel","library_panel",
    "play","play_from_camera","simulate","apply_simulation","pause","stop","release_input",
    "shortcuts",
    "find","import","ai_chat","source_control","graphics","settings","projects",
    "prefab_create","prefab_apply","prefab_revert","prefab_unlink","prefab_apply_base",
    "camera_preview","camera_keep","camera_discard",
}

@(test)
every_entry_of_a_menu_or_a_shortcut_calls_a_method_of_the_api_with_params_it_takes :: proc(t:^testing.T) {
    f:=new(Commands_Test);defer free(f)
    if !commands_test_open(t,f) {return}
    defer commands_test_close(f)
    s:=&f.s
    st:=api_state(s)
    for gone in ([?]string{"editor.action","editor.view","editor.copy","play.release","camera.preview"}) {
        testing.expectf(t,api.method_find(&st.server,gone)==nil,"%s only changed what a person sees: it is no method",gone)
    }
    for name in COMMANDS_OF_THE_ACTIONS {
        testing.expectf(t,command_binding(s,name)!=nil,"%s is something a person does: it has an entry",name)
    }
    for &b in command_bindings(s) {
        testing.expectf(t,b.label!="","the entry %s shows a label",b.name)
        // What only changes what the person sees is no method.
        if b.view!=nil {continue}
        method:=api.method_find(&st.server,b.method)
        if !testing.expectf(t,method!=nil,"the entry %s calls %s, which is no method",b.name,b.method) {continue}
        // Whatever it shows, checked or not, its params are params of its method.
        state:=binding_state(s,&b)
        for checked in ([2]bool{false,true}) {
            params:=strings.builder_make(context.temp_allocator)
            binding_params(&params,b.params,checked)
            base.arena_reset(&st.server.scratch)
            _,_,error,read:=api.params_read(&st.server,method,strings.to_string(params))
            testing.expectf(t,read,"%s: %s does not take %s: %s",b.name,b.method,strings.to_string(params),error.message)
        }
        // A key is of one entry at a time: two that share it are never on together.
        for &other in command_bindings(s) {
            if &other==&b || !b.shortcut.set || other.shortcut!=b.shortcut && other.alternate!=b.shortcut {continue}
            testing.expectf(t,state.disabled || binding_state(s,&other).disabled,"%s and %s take the same key at once",b.name,other.name)
        }
    }
    // The entries are what editor.inspect tells an agent, with the method of each.
    found:=false
    for command in api_commands(s) {found ||= command.name=="delete" && command.method=="scene.write" && command.params==`{"root":"$roots","entities":[{"delete":true}]}`}
    testing.expect(t,found,"delete calls scene.write on the roots")
}

@(test)
a_gesture_runs_its_method_between_frames_with_what_the_person_has_selected :: proc(t:^testing.T) {
    f:=new(Commands_Test);defer free(f)
    if !commands_test_open(t,f) {return}
    defer commands_test_close(f)
    s:=&f.s
    st:=api_state(s)
    w:=edited_world(s)
    out:serial.Writer
    serial.writer_init(&out);defer serial.writer_destroy(&out)
    delete_method:=api.method_find(&st.server,"scene.write")
    // Nothing selected: the entry is off, and the method says so to a gesture that reaches it.
    testing.expect(t,command_state(s,"delete").disabled && !command_run(s,"delete"))
    testing.expect(t,command_call(s,"scene.write",`{"root":"$roots","entities":[{"delete":true}]}`))
    commands_run(s)
    testing.expect(t,strings.contains(string(s.toast[:s.toast_length]),"nothing is selected") && core.world_entities(w).alive==1,string(s.toast[:s.toast_length]))
    // An agent names its entities: the selection of the person is not a param of its calls.
    history.selection_set(&f.selection,{f.entity})
    st.poll_temp=context.temp_allocator
    base.arena_reset(&st.server.scratch)
    refused,ran:=api.method_execute(&st.server,delete_method,`{"root":"$roots","entities":[{"delete":true}]}`,&out)
    testing.expect(t,!ran && strings.contains(refused.message,"names no entity") && core.world_entities(w).alive==1,refused.message)
    // The entry asks; the method runs between frames, as one step of the person.
    testing.expect(t,command_run(s,"delete"))
    testing.expect_value(t,core.world_entities(w).alive,1)
    commands_run(s)
    testing.expect_value(t,core.world_entities(w).alive,0)
    testing.expect_value(t,history.undo_label(&f.edits),"Delete")
    testing.expect(t,len(f.selection.entities)==0 && st.commands.asked_count==0)
    testing.expect(t,test_command(s,"undo") && core.world_entities(w).alive==1)
    // Duplicate and Paste copy beside what they copy as one step each, which leaves the copies selected.
    for name in ([?]string{"duplicate","paste"}) {
        testing.expect(t,test_command(s,"select_all") && test_command(s,"copy"))
        steps:=history.edits_undo_count(&f.edits)
        testing.expectf(t,test_command(s,name) && core.world_entities(w).alive==2 && history.edits_undo_count(&f.edits)==steps+1,"%s is one step",name)
        testing.expect_value(t,history.undo_label(&f.edits),name=="paste"?"Paste":"Duplicate")
        testing.expect(t,len(f.selection.entities)==1 && api_entity_id(w,f.selection.entities[0])!=api_entity_id(w,f.entity))
        testing.expect(t,test_command(s,"undo") && core.world_entities(w).alive==1)
    }
    // A toggle sends the opposite of what it shows.
    shown:=f.viewport.show_grid
    testing.expect_value(t,command_state(s,"grid").checked,shown)
    testing.expect(t,test_command(s,"grid") && f.viewport.show_grid==!shown && command_state(s,"grid").checked==!shown)
    testing.expect(t,test_command(s,"space") && f.viewport.space==.Local && test_command(s,"space") && f.viewport.space==.World)
    // The entries of the scene and of the view run their methods, which refuse nothing.
    f.viewport.orbit.distance=3
    for name in ([?]string{"select_all","focus","reset_camera","duplicate","select_all","group","rename","deselect","tool_rotate","hierarchy_panel","studio_light","console_panel","find","shortcuts"}) {
        s.toast_length=0
        testing.expectf(t,test_command(s,name) && s.toast_length==0,"%s: %s",name,string(s.toast[:s.toast_length]))
        f.g.modal=.None
    }
    testing.expect_value(t,f.viewport.orbit,ORBIT_DEFAULT)
    // The original, its copy and the group that holds both.
    testing.expect_value(t,core.world_entities(w).alive,3)
    testing.expect(t,f.viewport.tool==.Rotate && f.viewport.studio_light && f.g.layout.library_tab==.Hierarchy && f.g.layout.bottom_open && f.inspector.rename)
    // What cannot run says why, and leaves the editor as it was.
    alive:=core.world_entities(w).alive
    s.toast_length=0
    testing.expect(t,!command_run(s,"no_such_entry"))
    testing.expect(t,command_call(s,"no.such.method","{}"))
    commands_run(s)
    testing.expect(t,strings.contains(string(s.toast[:s.toast_length]),"no.such.method"))
    s.toast_length=0
    testing.expect(t,command_call(s,"scene.write",`{"root":`))
    commands_run(s)
    testing.expect(t,s.toast_length>0 && core.world_entities(w).alive==alive)
    long:=strings.repeat("x",COMMAND_PARAMS+1,context.temp_allocator)
    testing.expect(t,!command_call(s,"scene.write",long))
    for _ in 0..<COMMAND_QUEUE {testing.expect(t,command_call(s,"editor.select","{}"))}
    testing.expect(t,!command_call(s,"editor.select","{}"),"past its room a frame asks for nothing more")
    commands_run(s)
    testing.expect_value(t,st.commands.asked_count,0)
}

@(test)
the_params_of_an_entry_take_what_it_shows_in_place_of_a_toggle :: proc(t:^testing.T) {
    cases:=[?]struct{params:string,checked:bool,want:string}{
        {"",false,"{}"},
        {`{"a":1}`,true,`{"a":1}`},
        {`{"on":"$toggle"}`,false,`{"on":true}`},
        {`{"on":"$toggle"}`,true,`{"on":false}`},
        {`{"space":"$toggle:Local:World","x":"$toggle"}`,false,`{"space":"Local","x":true}`},
        {`{"space":"$toggle:Local:World"}`,true,`{"space":"World"}`},
        {`{"e":"$roots","p":"$ask"}`,true,`{"e":"$roots","p":"$ask"}`},
        {`{"broken":"$toggle`,false,`{"broken":`},
    }
    for c in cases {
        b:=strings.builder_make(context.temp_allocator)
        binding_params(&b,c.params,c.checked)
        testing.expect_value(t,strings.to_string(b),c.want)
    }
}

@(test)
the_methods_a_menu_calls_refuse_an_agent_what_they_cannot_do_and_say_how :: proc(t:^testing.T) {
    f:=new(Commands_Test);defer free(f)
    if !commands_test_open(t,f) {return}
    defer commands_test_close(f)
    s:=&f.s
    st:=api_state(s)
    st.poll_temp=context.temp_allocator
    w:=edited_world(s)
    out:serial.Writer
    serial.writer_init(&out);defer serial.writer_destroy(&out)
    cases:=[?]struct{method,params,want:string}{
        {"scene.group",`{"entities":[]}`,"name the entities"},
        {"scene.group",`{"entities":["Nobody"]}`,"names no entity"},
        {"scene.group",`{"entities":["$roots"]}`,"names no entity"},
        {"scene.write",`{"entities":[{"copy":"$copied"}]}`,"names no entity"},
        {"editor.tool",`{"tool":"hammer"}`,"hammer"},
        {"editor.tool",`{"tool":"move","on":false}`,"always has a mode"},
        {"editor.tool",`{}`,"tool"},
        {"scene.thumbnail",`{}`,"thumbnail"},
        {"scene.new",`{"discard":"yes"}`,"discard"},
    }
    alive:=core.world_entities(w).alive
    for c in cases {
        base.arena_reset(&st.server.scratch)
        serial.writer_reset(&out)
        method:=api.method_find(&st.server,c.method)
        if !testing.expectf(t,method!=nil,"%s is a method",c.method) {continue}
        error,ran:=api.method_execute(&st.server,method,c.params,&out)
        testing.expectf(t,!ran && strings.contains(error.message,c.want),"%s %s: %s",c.method,c.params,error.message)
    }
    testing.expect(t,core.world_entities(w).alive==alive && history.edits_undo_count(&f.edits)==0 && len(s.copied)==0)
    // An entry needs a method and a name no other has; a session without the registry runs none.
    testing.expect(t,!command_bind(s,{name="orphan",label="Orphan"}) && !command_bind(s,{name="save",method="scene.save",label="Save"}))
    testing.expect(t,tool_entry(s,"brush","Brush",.Edit) && !tool_entry(s,"brush","Brush",.Edit))
    bare:Session
    testing.expect(t,!command_run(&bare,"save") && !command_call(&bare,"scene.save","{}") && command_state(&bare,"save").disabled && len(command_bindings(&bare))==0 && !api_person(&bare))
    commands_run(&bare)
}

// A batch runs calls of any methods in order: a call takes what one before
// it answered, the first that fails stops it, and with transaction what they
// edit is one step, or nothing.
@(test)
a_batch_runs_calls_in_order_with_references_and_as_one_step :: proc(t:^testing.T) {
    f:=new(Commands_Test);defer free(f)
    if !commands_test_open(t,f) {return}
    defer commands_test_close(f)
    s:=&f.s
    st:=api_state(s)
    st.poll_temp=context.temp_allocator
    w:=edited_world(s)
    out:serial.Writer
    serial.writer_init(&out);defer serial.writer_destroy(&out)
    batch:=api.method_find(&st.server,"batch")
    if !testing.expect(t,batch!=nil,"batch is a method") {return}
    LAMP :: `{"method":"scene.write","params":{"entities":[{"name":"Lamp"}]}}`
    MOVE :: `{"method":"scene.write","params":{"root":"$0.id","entities":[{"position":[1,2,3]}]}}`
    cases:=[?]struct{params:string,steps,alive:int,says:string}{
        // The second call names what the first made, the third reads it, and all of it is one step.
        {`{"transaction":true,"calls":[`+LAMP+`,`+MOVE+`,{"method":"scene.inspect","params":{"name":"$0.created[0].name","components":true}}]}`,1,2,`"position":[1,2,3]`},
        // Without transaction each call is its own step.
        {`{"calls":[`+LAMP+`,`+MOVE+`]}`,2,2,`"results":[{"method":"scene.write","result":{`},
        // The call that fails stops the batch: as one step nothing of it stays; otherwise what ran before does.
        {`{"transaction":true,"calls":[`+LAMP+`,{"method":"scene.write","params":{"root":"Nobody","entities":[{}]}}]}`,0,1,`calls[1] scene.write: root: "Nobody" names no entity`},
        {`{"calls":[`+LAMP+`,{"method":"scene.write","params":{"root":"Nobody","entities":[{}]}},`+LAMP+`]}`,1,2,`calls[1] scene.write: root: "Nobody" names no entity`},
        {`{"calls":[{"method":"scene.write","params":{"root":"$2.id","entities":[{}]}}]}`,0,1,"calls[0] scene.write: $2.id: the batch has 0 results so far"},
        {`{"calls":[`+LAMP+`,{"method":"scene.write","params":{"root":"$0.nothing","entities":[{}]}}]}`,1,2,"calls[1] scene.write: $0.nothing: "},
        {`{"calls":[{"method":"no.such.method"}]}`,0,1,`calls[0] no.such.method: "no.such.method" is not a method`},
        {`{"transaction":true,"calls":[`+LAMP+`,{"method":"batch","params":{"transaction":true,"calls":[`+LAMP+`]}}]}`,0,1,"calls[1] batch: a batch that is one step runs inside another"},
        {`{"calls":[]}`,0,1,"calls"},
        {`{"calls":[7]}`,0,1,"calls"},
    }
    for c in cases {
        steps:=f.edits.cursor
        base.arena_reset(&st.server.scratch)
        serial.writer_reset(&out)
        error,ran:=api.method_execute(&st.server,batch,c.params,&out)
        answer:=ran?string(serial.writer_bytes(&out)):error.message
        tight,_:=strings.remove_all(answer," ",context.temp_allocator)
        says,_:=strings.remove_all(c.says," ",context.temp_allocator)
        testing.expectf(t,strings.contains(tight,says),"%s: %s",c.params,answer)
        testing.expectf(t,f.edits.cursor==steps+c.steps && core.world_entities(w).alive==c.alive,"%s: %d steps and %d entities",c.params,f.edits.cursor-steps,core.world_entities(w).alive)
        testing.expect(t,!st.transaction && !f.edits.open)
        // Each case starts from the scene as it was: the caller undoes its steps.
        for _ in 0..<c.steps {
            base.arena_reset(&st.server.scratch)
            serial.writer_reset(&out)
            _,undone:=api.method_execute(&st.server,api.method_find(&st.server,"history.undo"),"{}",&out)
            testing.expect(t,undone)
        }
        testing.expect_value(t,core.world_entities(w).alive,1)
    }
}
