package editor

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

@(private="file") @(storage,setting="machine") Layer_Setting :: struct {quality:i32,scale:f32}
@(private="file") @(storage,setting) Layer_Rule :: struct {count:i32}
@(private="file") Layer_World :: struct {using world:core.Test_World,setting:Layer_Setting,rule:Layer_Rule}
@(private="file") Layer_Editor :: struct {api:Api}

@(private="file")
layer_test_types :: proc(types:^[dynamic]core.Test_Type) {
    test_types(types)
    append(types,core.test_type(Layer_Setting,default=proc(dst:^Layer_Setting) {dst^={quality=1,scale=1}}))
}

@(private="file")
layer_text :: proc(layer:project.Settings_Layer,root,engine:string) -> string {
    data,_:=os.read_entire_file(project.settings_file(layer,root,engine,context.temp_allocator),context.temp_allocator)
    return string(data)
}

// settings.set writes the layer it is asked for, keeping in each file only
// what differs from the layers under it; the edited World takes the project
// over the engine, and settings.get says what each layer sets. The engine
// layer holds only the settings of the machine.
@(test)
settings_are_written_by_layer_and_the_project_wins :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"editor-settings")
    if folder=="" {return}
    root,engine:=project.path(folder,"project",allocator=context.temp_allocator),project.path(folder,"engine",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil && os.make_directory_all(engine)==nil)
    info,made:=core.test_info(t,Layer_World,core.Test_None,Layer_Editor,layer_test_types)
    if !made {return}
    defer core.test_info_destroy(&info)
    world:Layer_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    setting_at,rule_at:=info.storages_by_type[Layer_Setting],info.storages_by_type[Layer_Rule]
    selection:history.Selection;defer delete(selection.entities)
    viewport:Viewport;gui:Editor_Ui;edits:history.Edits;defer history.edits_free(&edits)
    inspector:Inspector
    editor:Layer_Editor
    app:host.App
    session:=Session{info=&info,edit_world=&world,editor_world=&editor,app=&app,selection=&selection,viewport=&viewport,gui=&gui,edits=&edits,inspector=&inspector,project_root=root,engine_root=engine,has_project=true}
    defer settings_engine_free(&session)
    history.edits_reset(&edits,edited_world(&session))
    if !testing.expect(t,api_open(&session,0,true)==.None) {return};defer api_close(&session)
    state:=api_state(&session);state.poll_temp=context.temp_allocator
    if api.method_find(&state.server,"settings.get")==nil {settings_api_register(&session,state)}
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    execute :: proc(state:^Api_State,out:^serial.Writer,name,params:string) -> api.Error {
        base.arena_reset(&state.server.scratch);serial.writer_reset(out)
        error,_:=api.method_execute(&state.server,api.method_find(&state.server,name),params,out)
        return error
    }

    running:Layer_World
    session.runs[0].world=&running
    defer session.runs[0]={}
    error:=execute(state,&out,"settings.set",`{"layer":"engine","settings":{"Layer_Setting":{"quality":3,"scale":2}}}`)
    testing.expect(t,running.setting==Layer_Setting{quality=3,scale=2},"the game that plays takes the sections it changes")
    testing.expect_value(t,error.code,0)
    testing.expect(t,!strings.contains(string(serial.writer_bytes(&out)),`"Layer_Rule"`),string(serial.writer_bytes(&out)))
    testing.expect_value(t,world.setting,Layer_Setting{quality=3,scale=2})
    text:=layer_text(.Engine,root,engine)
    testing.expect(t,strings.contains(text,`"quality": 3`) && strings.contains(text,`"scale": 2`),text)
    error=execute(state,&out,"settings.set",`{"settings":{"Layer_Setting":{"scale":5}}}`)
    testing.expect_value(t,running.setting.scale,5)
    testing.expect_value(t,running.rule.count,0)
    testing.expect_value(t,error.code,0)
    text=layer_text(.Project,root,engine)
    testing.expect(t,strings.contains(text,`"scale": 5`) && !strings.contains(text,`"quality"`),text)

    // A setting of the project goes only to its file: the one of the engine
    // refuses it, and keeps without reading one it already has.
    error=execute(state,&out,"settings.set",`{"layer":"engine","settings":{"Layer_Rule":{"count":2}}}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect(t,strings.contains(error.message,"Layer_Rule") && strings.contains(error.message,"only Layer_Setting"),error.message)
    error=execute(state,&out,"settings.set",`{"settings":{"Layer_Rule":{"count":2}}}`)
    testing.expect_value(t,error.code,0)
    testing.expect_value(t,world.rule,Layer_Rule{count=2})
    testing.expect(t,os.write_entire_file(project.settings_file(.Engine,root,engine,context.temp_allocator),`{"Layer_Setting": {"quality": 3, "scale": 2}, "Layer_Rule": {"count": 8}}`)==nil)
    settings_load(&session)
    testing.expect_value(t,world.rule,Layer_Rule{count=2})
    testing.expect(t,strings.contains(string(session.toast[:session.toast_length]),"Layer_Rule"))

    // A process that reads no file of the machine, as mirai render check, has what the code and the project say.
    testing.expect(t,os.write_entire_file(project.settings_file(.Engine,root,engine,context.temp_allocator),`{"version": 3, "Layer_Setting": {"quality": 3, "scale": 2}, "Layer_Rule": {"count": 8}}`)==nil)
    settings_load(&session)
    testing.expect_value(t,world.setting,Layer_Setting{quality=3,scale=5})
    session.toast_length=0
    os.set_env(project.SETTINGS_NO_MACHINE_ENV,"1")
    settings_load(&session)
    os.unset_env(project.SETTINGS_NO_MACHINE_ENV)
    testing.expect_value(t,world.setting,Layer_Setting{quality=1,scale=5})
    testing.expect_value(t,session.toast_length,0)

    error=execute(state,&out,"settings.set",`{"layer":"engine","settings":{"Layer_Setting":{"quality":4,"scale":7}}}`)
    testing.expect_value(t,error.code,0)
    testing.expect_value(t,world.setting,Layer_Setting{quality=4,scale=5})
    testing.expect(t,strings.contains(layer_text(.Engine,root,engine),`"Layer_Rule": {"count": 8}`))

    error=execute(state,&out,"settings.get",`{"sections":["Layer_Rule"]}`)
    testing.expect_value(t,error.code,0)
    text=string(serial.writer_bytes(&out))
    testing.expect(t,strings.contains(text,`"Layer_Rule"`) && !strings.contains(text,`"machine"`) && !strings.contains(text,`"Layer_Setting"`),text)
    error=execute(state,&out,"settings.get",`{"sections":["Nope"]}`)
    testing.expect(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,"Layer_Setting"),error.message)

    error=execute(state,&out,"settings.get","{}")
    testing.expect_value(t,error.code,0)
    text=string(serial.writer_bytes(&out))
    testing.expect(t,strings.has_prefix(text,`{"machine": ["Layer_Setting"], "settings": `),text)
    at_engine,at_project:=strings.index(text,`"engine": `),strings.index(text,`"project": `)
    if !testing.expect(t,at_engine>0 && at_project>at_engine,text) {return}
    testing.expect(t,strings.contains(text[:at_engine],`"quality": 4`) && strings.contains(text[:at_engine],`"scale": 5`),text)
    testing.expect(t,strings.contains(text[at_engine:at_project],`"quality": 4`) && strings.contains(text[at_engine:at_project],`"scale": 7`),text)
    testing.expect(t,strings.contains(text[at_project:],`"scale": 5`) && !strings.contains(text[at_project:],`"quality"`),text)

    // A name the settings do not have is an error that says the ones they have.
    error=execute(state,&out,"settings.set",`{"settings":{"Layer_Rules":{"count":3}}}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect(t,strings.contains(error.message,"Layer_Rules is not a setting of the project: they are Layer_Setting, Layer_Rule"),error.message)
    error=execute(state,&out,"settings.set",`{"settings":{"Layer_Rule":{"amount":3}}}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect(t,strings.contains(error.message,`Layer_Rule: "amount" is not a field: the fields are count`),error.message)
    testing.expect_value(t,world.rule,Layer_Rule{count=2})

    for params in ([]string{
        `{"Layer_Setting":{"scale":1}}`,
        `{"layer":"machine","settings":{"Layer_Setting":{"scale":1}}}`,
        `{"layer":"engine"}`,
        `{"settings":{"Layer_Setting":{"scale":"big"}}}`,
    }) {
        error=execute(state,&out,"settings.set",params)
        testing.expect_value(t,error.code,api.INVALID_PARAMS)
        testing.expect_value(t,world.setting,Layer_Setting{quality=4,scale=5})
    }

    // The dialog: the engine layer takes what changes in it; the project
    // forgets a field that goes back to the value of the engine.
    settings_engine_load(&session)
    settings_layer_set(&session,.Engine)
    quality,scale:=i32(6),f32(9)
    setting_write(&session,setting_at,int(offset_of(Layer_Setting,quality)),mem.ptr_to_bytes(&quality))
    count:=i32(5)
    setting_write(&session,rule_at,0,mem.ptr_to_bytes(&count))
    settings_flush(&session)
    testing.expect_value(t,world.rule,Layer_Rule{count=2})
    testing.expect_value(t,world.setting,Layer_Setting{quality=6,scale=5})
    testing.expect(t,strings.contains(layer_text(.Engine,root,engine),`"quality": 6`))
    settings_layer_set(&session,.Project)
    scale=7
    setting_write(&session,setting_at,int(offset_of(Layer_Setting,scale)),mem.ptr_to_bytes(&scale))
    settings_flush(&session)
    testing.expect_value(t,world.setting,Layer_Setting{quality=6,scale=7})
    testing.expect(t,!strings.contains(layer_text(.Project,root,engine),`"Layer_Setting"`))

    session.engine_root=""
    error=execute(state,&out,"settings.set",`{"layer":"engine","settings":{"Layer_Setting":{"scale":1}}}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
}

@(private="file") @(storage,setting) Advanced_Setting :: struct {
    shown:bool `mirai:"section=Rules"`,
    pool:bool `mirai:"advanced"`,
    budget:bool `mirai:"section=Limits,advanced"`,
}
@(private="file") Advanced_World :: struct {using world:core.Test_World,setting:Advanced_Setting}

// A card draws its fields tagged advanced after the others, under a fold
// that starts closed and keeps whether it is open; a card of only those has
// just the fold. A search that finds one shows it, with its fold open.
@(test)
advanced_settings_go_last_under_a_fold_the_search_opens :: proc(t:^testing.T) {
    ctx:ui.Context
    if !testing.expect(t,ui.context_init(&ctx,{})) {return}
    defer ui.context_destroy(&ctx)
    world:Advanced_World
    if !core.test_world_init(t,&world) {return}
    defer core.test_world_destroy(&world)
    g:=Editor_Ui{ctx=&ctx,layout=LAYOUT_DEFAULT}
    inspector:Inspector
    defer core.value_free(&inspector,type_info_of(Inspector))
    app:host.App
    s:=Session{gui=&g,info=core.test_world_info(&world),edit_world=&world,app=&app,inspector=&inspector}
    frame :: proc(t:^testing.T,s:^Session,input:ui.Input) {
        ctx:=s.gui.ctx
        categories:=settings_categories(s)
        ui.frame_begin(ctx,input)
        for c in categories {
            if c.storage==0 {settings_cards(s,c,string(s.settings_dialog.search[:s.settings_dialog.search_length]),800)}
        }
        output:=ui.frame_end(ctx)
        testing.expect(t,!output.overflow)
        testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    }
    rect :: proc(s:^Session,name:string,index:int) -> (ui.Rect,bool) {
        ctx:=s.gui.ctx
        ui.id_push(ctx,ui.id(ctx,"Advanced_Setting"))
        defer ui.id_pop(ctx)
        return ui.widget_rect(ctx,ui.id(ctx,name,index))
    }
    shown :: proc(s:^Session,field:uintptr) -> bool {_,found:=rect(s,"bool",int(field)+1);return found}
    SHOWN,POOL,BUDGET :: offset_of(Advanced_Setting,shown),offset_of(Advanced_Setting,pool),offset_of(Advanced_Setting,budget)
    input:=ui.Input{size={1200,900},pointer_absent=true}
    frame(t,&s,input)
    row,_:=rect(&s,"bool",int(SHOWN)+1)
    fold,folded:=rect(&s,"settings_advanced",1)
    _,limits:=rect(&s,"settings_advanced",2)
    testing.expect(t,shown(&s,SHOWN) && !shown(&s,POOL) && !shown(&s,BUDGET),"the advanced fields start folded")
    testing.expect(t,folded && limits && fold.y>row.y,"the fold goes after the other fields, and alone in a card of only advanced fields")

    cases:=[]struct {search:string,rows:[3]bool} {
        {"pool",{false,true,false}},
        {"budget",{false,false,true}},
        {"advanced",{true,true,true}}, // the name of the setting: every field
    }
    for c in cases {
        s.settings_dialog.search_length=copy(s.settings_dialog.search[:],c.search)
        frame(t,&s,input)
        testing.expect_value(t,[3]bool{shown(&s,SHOWN),shown(&s,POOL),shown(&s,BUDGET)},c.rows)
    }
    s.settings_dialog.search_length=0
    frame(t,&s,input)
    fold,_=rect(&s,"settings_advanced",1)
    for phase in 0..<3 {
        click:=ui.Input{size=input.size,pointer=ui.rect_center(fold)}
        if phase==1 {click.down,click.pressed={.Left},{.Left}}
        if phase==2 {click.released={.Left}}
        frame(t,&s,click)
    }
    frame(t,&s,input)
    testing.expect(t,shown(&s,POOL) && !shown(&s,BUDGET),"the fold keeps that it was opened")
}

// settings.set with a preset answers the section it changed, which its params do not name.
@(test)
settings_touched_counts_what_a_preset_changes :: proc(t:^testing.T) {
    list:=[?]project.Setting{{name="Graphics_Settings"},{name="Other"}}
    keep:=settings_touched(list[:],`{}`,"Graphics_Settings")
    testing.expect(t,keep[0] && !keep[1])
}
