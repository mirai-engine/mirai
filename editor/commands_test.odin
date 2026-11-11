package editor

import "core:fmt"
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

// What the menus, the shortcuts and the buttons of the editor run.
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
    "asset_delete","asset_rename","asset_duplicate",
}

@(test)
every_entry_calls_a_method_of_the_api_with_params_it_takes_or_only_changes_what_the_person_sees :: proc(t:^testing.T) {
    f:=new(Commands_Test);defer free(f)
    if !commands_test_open(t,f) {return}
    defer commands_test_close(f)
    s:=&f.s
    st:=api_state(s)
    for gone in ([?]string{"editor.action","editor.view","editor.copy","play.release","camera.preview","scene.group"}) {
        testing.expectf(t,api.method_find(&st.server,gone)==nil,"%s is no method",gone)
    }
    for name in COMMANDS_OF_THE_ACTIONS {
        testing.expectf(t,command_binding(s,name)!=nil,"%s is something a person does: it has an entry",name)
    }
    // With something selected and copied, the context every entry names is there.
    history.selection_set(&f.selection,{f.entity})
    append(&s.copied,api_entity_id(edited_world(s),f.entity))
    for &b in command_bindings(s) {
        testing.expectf(t,b.label!="","the entry %s shows a label",b.name)
        testing.expectf(t,(b.method=="")!=(b.view==nil),"the entry %s runs a method or a procedure of the interface, not both",b.name)
        state:=binding_state(s,&b)
        // A key is of one entry at a time: two that share it are never on together.
        for &other in command_bindings(s) {
            if &other==&b || !b.shortcut.set || other.shortcut!=b.shortcut && other.alternate!=b.shortcut {continue}
            testing.expectf(t,state.disabled || binding_state(s,&other).disabled,"%s and %s take the same key at once",b.name,other.name)
        }
        if b.view!=nil {continue}
        method:=api.method_find(&st.server,b.method)
        if !testing.expectf(t,method!=nil,"the entry %s calls %s, which is no method",b.name,b.method) {continue}
        // What it calls with is params of its method, with ids in place of what the person has in front.
        params:=strings.builder_make(context.temp_allocator)
        if !testing.expectf(t,binding_params(s,&b,&params) || b.card,"%s has nothing to call with",b.name) {continue}
        if b.card {continue}
        testing.expectf(t,!strings.contains(strings.to_string(params),"$"),"%s leaves a context name to its method: %s",b.name,strings.to_string(params))
        base.arena_reset(&st.server.scratch)
        _,_,error,read:=api.params_read(&st.server,method,strings.to_string(params))
        testing.expectf(t,read,"%s: %s does not take %s: %s",b.name,b.method,strings.to_string(params),error.message)
    }
    // The entries are what editor.inspect tells an agent, with the method of each and what it flips.
    told:=0
    for command in api_commands(s) {
        told+=int(command.name=="delete" && command.method=="scene.write" && command.params==`{"world":"$shown","entities":[{"id":"$roots","delete":true}]}`)
        told+=int(command.name=="grid" && command.method=="preferences.set" && strings.contains(command.params,`"show_grid":`))
        told+=int(command.name=="find" && command.method=="")
    }
    testing.expect_value(t,told,3)
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
    write:=api.method_find(&st.server,"scene.write")
    // Nothing selected: the entry is off.
    testing.expect(t,command_state(s,"delete").disabled && !command_run(s,"delete") && st.commands.asked_count==0)
    // A method takes what it is given: what the person has selected is no param of it, for anyone.
    history.selection_set(&f.selection,{f.entity})
    for person in ([2]bool{false,true}) {
        st.poll_temp=context.temp_allocator
        base.arena_reset(&st.server.scratch)
        st.person=person
        refused,ran:=api.method_execute(&st.server,write,`{"entities":[{"id":"$roots","delete":true}]}`,&out)
        st.person=false
        testing.expect(t,!ran && strings.contains(refused.message,"must be an entity id") && core.world_entities(w).alive==1,refused.message)
    }
    // The entry asks; the method runs between frames, as one step of the person named as the entry.
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
        testing.expectf(t,test_command(s,name) && core.world_entities(w).alive==2 && history.edits_undo_count(&f.edits)==steps+1,"%s is one step: %s",name,string(s.toast[:s.toast_length]))
        testing.expect_value(t,history.undo_label(&f.edits),name=="paste"?"Paste":"Duplicate")
        testing.expect(t,len(f.selection.entities)==1 && api_entity_id(w,f.selection.entities[0])!=api_entity_id(w,f.entity))
        testing.expect(t,test_command(s,"undo") && core.world_entities(w).alive==1)
    }
    // An entry that flips a preference sends the opposite of what it shows, and shows what the preference holds.
    shown:=f.viewport.show_grid
    testing.expect_value(t,command_state(s,"grid").checked,shown)
    testing.expect(t,test_command(s,"grid") && f.viewport.show_grid==!shown && command_state(s,"grid").checked==!shown)
    testing.expect(t,test_command(s,"space") && f.viewport.space==.Local && command_state(s,"space").checked && test_command(s,"space") && f.viewport.space==.World)
    testing.expect(t,test_command(s,"console_panel") && f.g.layout.bottom_open && command_state(s,"console_panel").checked && !command_state(s,"build_panel").checked)
    testing.expect(t,test_command(s,"build_panel") && f.g.layout.bottom_tab==.Build && test_command(s,"build_panel") && !f.g.layout.bottom_open)
    // The entries of the scene and of the view run, and refuse nothing.
    f.viewport.orbit.distance=3
    for name in ([?]string{"select_all","focus","reset_camera","duplicate","select_all","group","rename","deselect","tool_rotate","hierarchy_panel","studio_light","find","shortcuts"}) {
        s.toast_length=0
        testing.expectf(t,test_command(s,name) && s.toast_length==0,"%s: %s",name,string(s.toast[:s.toast_length]))
        f.g.modal=.None
    }
    testing.expect_value(t,f.viewport.orbit,ORBIT_DEFAULT)
    // The original, its copy and the group that holds both, which is what stays selected.
    testing.expect_value(t,core.world_entities(w).alive,3)
    testing.expect(t,f.viewport.tool==.Rotate && command_state(s,"tool_rotate").checked && !command_state(s,"tool_move").checked)
    testing.expect(t,f.viewport.studio_light && f.g.layout.library_tab==.Hierarchy && f.inspector.rename)
    // In a mode it is not for, an entry is off.
    s.mode=.Play
    testing.expect(t,command_state(s,"group").disabled && command_state(s,"new").disabled && !command_state(s,"pause").disabled && command_state(s,"resume").disabled)
    s.mode=.Edit
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

// The params of an entry name what the person has in front; the entry puts
// ids there before the call, once for each entity in the element of a list.
@(test)
the_params_of_an_entry_take_what_the_person_has_in_front_before_the_call :: proc(t:^testing.T) {
    f:=new(Commands_Test);defer free(f)
    if !commands_test_open(t,f) {return}
    defer commands_test_close(f)
    s:=&f.s
    w:=edited_world(s)
    other:=entity_create(s,{name="Other"})
    core.world_settle(w)
    one,two:=fmt.tprintf(`"0x%016x"`,u64(api_entity_id(w,f.entity))),fmt.tprintf(`"0x%016x"`,u64(api_entity_id(w,other)))
    cases:=[?]struct{params,want:string}{
        {`{"a":1}`,`{"a":1}`},
        {`{"frame":["$selection"]}`,fmt.tprintf(`{{"frame":[%s,%s]}}`,one,two)},
        {`{"world":"$shown","entities":[{"id":"$roots","delete":true}],"select":true}`,fmt.tprintf(`{{"world":"Scene","entities":[{{"id":%s,"delete":true}},{{"id":%s,"delete":true}}],"select":true}}`,one,two)},
        {`{"entities":[{"name":"G","group":["$roots"]},{"copy":"$active"}]}`,fmt.tprintf(`{{"entities":[{{"name":"G","group":[%s,%s]}},{{"copy":%s}}]}}`,one,two,two)},
        {`{"asset":"$document","cost":"$5"}`,`{"asset":"","cost":"$5"}`},
        {`{"entities":[{"copy":"$copied"}]}`,""},
    }
    history.selection_set(&f.selection,{f.entity,other})
    for c in cases {
        b:=strings.builder_make(context.temp_allocator)
        ok:=context_write(s,&b,c.params)
        testing.expectf(t,ok==(c.want!="") && (!ok || strings.to_string(b)==c.want),"%s gave %s",c.params,strings.to_string(b))
        testing.expect_value(t,context_missing(s,c.params),c.want=="")
    }
    history.selection_clear(&f.selection)
    b:=strings.builder_make(context.temp_allocator)
    testing.expect(t,!context_write(s,&b,`{"frame":["$selection"]}`) && context_missing(s,`{"frame":["$selection"]}`) && context_missing(s,`{"entity":"$active"}`))
}

@(test)
a_method_says_in_one_place_that_it_cannot_be_called_now :: proc(t:^testing.T) {
    f:=new(Commands_Test);defer free(f)
    if !commands_test_open(t,f) {return}
    defer commands_test_close(f)
    s:=&f.s
    st:=api_state(s)
    st.poll_temp=context.temp_allocator
    w:=edited_world(s)
    out:serial.Writer
    serial.writer_init(&out);defer serial.writer_destroy(&out)
    execute :: proc(st:^Api_State,out:^serial.Writer,name,params:string) -> (api.Error,bool) {
        base.arena_reset(&st.server.scratch)
        serial.writer_reset(out)
        return api.method_execute(&st.server,api.method_find(&st.server,name),params,out)
    }
    // What a method cannot do as the editor is: its call fails with it, its entry is off, and engine.describe tells it.
    for name in ([2]string{"scene.thumbnail","simulation.apply"}) {
        error,ran:=execute(st,&out,name,name=="scene.thumbnail"?"{}":`{"entities":["Object"]}`)
        testing.expectf(t,!ran && error.code==api.NOT_NOW && error.message!="","%s: %v",name,error)
        why:=strings.clone(error.message,context.temp_allocator)
        _,described:=execute(st,&out,"engine.describe",fmt.tprintf(`{{"methods":[%q]}}`,name))
        testing.expectf(t,described && strings.contains(string(serial.writer_bytes(&out)),fmt.tprintf(`"unavailable":%s`,serial.text_quote(why))),"%s",string(serial.writer_bytes(&out)))
    }
    history.selection_set(&f.selection,{f.entity})
    testing.expect(t,command_state(s,"scene_thumbnail").disabled && command_state(s,"apply_simulation").disabled)
    // It is asked with the params the entry would call: of two entries of one method, the one that would change nothing is off.
    testing.expect(t,!command_state(s,"make_prefab").disabled && command_state(s,"make_scene").disabled)
    nothing,wrote:=execute(st,&out,"scene.write",`{"kind":"Scene","entities":[]}`)
    testing.expect(t,!wrote && nothing.code==api.NOT_NOW && strings.contains(nothing.message,"names nothing to change"),nothing.message)
    testing.expect(t,test_command(s,"make_prefab") && command_state(s,"make_prefab").disabled && !command_state(s,"make_scene").disabled)
    testing.expect(t,test_command(s,"make_scene") && !f.document.prefab)
    // What is linked to no prefab has nothing to unlink or to apply; prefabs_test.odin asks the methods on instances.
    testing.expect(t,command_state(s,"prefab_unlink").disabled && command_state(s,"prefab_apply").disabled)
    _,described:=execute(st,&out,"engine.describe",`{"methods":["scene.write"]}`)
    testing.expect(t,described && !strings.contains(string(serial.writer_bytes(&out)),`"unavailable"`))
    cases:=[?]struct{method,params,want:string}{
        {"scene.write",`{"entities":[{"group":[]}]}`,"name the entities"},
        {"scene.write",`{"entities":[{"group":["Nobody"]}]}`,"names no entity"},
        {"scene.write",`{"entities":[{"name":"Top","children":[{"group":["Object"]}]}]}`,"a group is a new entity at the top"},
        {"scene.write",`{"entities":[{"copy":"$copied"}]}`,"names no entity"},
        {"editor.tool",`{"tool":"hammer"}`,"hammer"},
        {"editor.tool",`{"tool":"move","on":false}`,"always has a mode"},
        {"editor.tool",`{}`,"tool"},
        {"history.undo",`{"asset":"nobody.ui"}`,"has no document open"},
        {"prefab.create",`{"entities":["Object"]}`,"no assets folder"},
        {"prefab.unlink",`{"entity":"Object"}`,"not linked to a prefab"},
        {"scene.new",`{"discard":"yes"}`,"discard"},
    }
    alive:=core.world_entities(w).alive
    for c in cases {
        error,ran:=execute(st,&out,c.method,c.params)
        testing.expectf(t,!ran && strings.contains(error.message,c.want),"%s %s: %s",c.method,c.params,error.message)
    }
    testing.expect(t,core.world_entities(w).alive==alive && history.edits_undo_count(&f.edits)==0 && len(s.copied)==0)
    // A method that went is a method that is not there, like any other name.
    gone,batched:=execute(st,&out,"batch",`{"calls":[{"method":"play.set","params":{}}]}`)
    testing.expect(t,!batched && !strings.contains(gone.message,"scene.write"),gone.message)
    // An entry needs a method that is registered, or a procedure, and a name no other has; a session without the registry runs none.
    testing.expect(t,!command_bind(s,{name="orphan",label="Orphan"}) && !command_bind(s,{name="save",method="scene.save",label="Save"}) && !command_bind(s,{name="lost",method="no.such.method",label="Lost"}))
    testing.expect(t,tool_entry(s,"brush","Brush",.Edit) && !tool_entry(s,"brush","Brush",.Edit))
    bare:Session
    testing.expect(t,!command_run(&bare,"save") && !command_call(&bare,"scene.save","{}") && command_state(&bare,"save").disabled && len(command_bindings(&bare))==0)
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
