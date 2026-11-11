package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Preferences_Test :: struct {
    g:Editor_Ui,
    c:Content,
    v:Viewport,
    console:Console,
    n:Play_Players,
    h:Play_History,
    ai:^Ai,
    p:Preferences,
    s:Session,
}

@(private="file")
preferences_test_open :: proc(f:^Preferences_Test,engine:string) {
    f.g.layout=LAYOUT_DEFAULT
    f.c=CONTENT_DEFAULT
    f.v.preferences=VIEWPORT_PREFERENCES_DEFAULT
    f.console=CONSOLE_DEFAULT
    f.n=PLAY_PLAYERS_DEFAULT
    f.h=PLAY_HISTORY_DEFAULT
    if f.ai==nil {f.ai=new(Ai)}
    f.ai.view=AI_DEFAULT.view
    f.p={}
    f.s=Session{gui=&f.g,content=&f.c,viewport=&f.v,console=&f.console,play_players=&f.n,play_history=&f.h,ai=f.ai,preferences=&f.p,engine_root=engine}
}

// What the user leaves goes to the file of the machine with only what differs
// from the code, and the next editor finds it there.
@(test)
preferences_keep_what_differs_from_the_code_and_come_back :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"preferences")
    if folder=="" {return}
    f:=new(Preferences_Test);defer free(f)
    defer free(f.ai)
    preferences_test_open(f,folder)
    preferences_open(&f.s,{})
    testing.expect(t,strings.has_suffix(f.p.file,"/.mirai/"+PREFERENCES_FILE),f.p.file)
    defer delete(f.p.file)
    f.g.layout.bottom_open,f.g.layout.bottom_height=true,300
    f.c.view.columns,f.c.view.mode=7,.Grid
    f.v.snap,f.v.fly_speed=true,9
    f.console.hidden={.Debug,.Info}
    f.n.players=3
    f.ai.show_agents_in_scene=false
    preferences_save(&f.s)
    data,error:=os.read_entire_file(f.p.file,context.temp_allocator)
    testing.expect(t,error==nil)
    text:=string(data)
    for part in ([]string{`"bottom_height": 300`,`"columns": 7`,`"snap": true`,`"players": 3`,`"show_agents_in_scene": false`,`"Info"`}) {
        testing.expectf(t,strings.contains(text,part),"%s in %s",part,text)
    }
    testing.expectf(t,!strings.contains(text,`"left_open"`) && !strings.contains(text,`"show_parts"`),"only what differs: %s",text)
    // The next editor starts from the code and reads the file over it.
    path:=f.p.file
    f.p.file=""
    preferences_test_open(f,folder)
    preferences_open(&f.s,{})
    testing.expect_value(t,f.p.file,path)
    delete(path)
    testing.expect(t,f.g.layout.bottom_open && f.g.layout.bottom_height==300 && f.g.layout.left_open)
    testing.expect(t,f.c.view.columns==7 && f.c.view.arrangement==.Names)
    testing.expect(t,f.v.snap && f.v.fly_speed==9 && f.v.grid==0.5)
    testing.expect(t,f.console.hidden=={.Debug,.Info} && f.n.players==3 && !f.ai.show_agents_in_scene)
    // Nothing changed: nothing is written; a Play keeps its layout out of the file.
    written:=f.p.kept.written
    preferences_save(&f.s)
    testing.expect_value(t,f.p.kept.written,written)
    f.s.mode=.Play
    f.g.layout.left_open=false
    preferences_save(&f.s)
    testing.expect_value(t,f.p.kept.written,written)
}

// A headless editor, as agents and tests run it, keeps the preferences of
// the user out of what it does, unless it is asked to keep them.
@(test)
a_headless_editor_neither_reads_nor_writes_preferences_unless_asked :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"preferences")
    if folder=="" {return}
    f:=new(Preferences_Test);defer free(f)
    defer free(f.ai)
    preferences_test_open(f,folder)
    preferences_open(&f.s,{})
    f.c.view.columns=8
    preferences_save(&f.s)
    delete(f.p.file)
    preferences_test_open(f,folder)
    preferences_open(&f.s,{headless=true})
    testing.expect(t,f.p.file=="" && f.c.view.columns==CONTENT_VIEW_DEFAULT.columns)
    f.c.view.columns=5
    preferences_save(&f.s)
    preferences_open(&f.s,{headless=true,preferences=true})
    testing.expect(t,f.p.file!="" && f.c.view.columns==8)
    delete(f.p.file)
    // Without the engine there is nowhere to keep them.
    preferences_test_open(f,"")
    preferences_open(&f.s,{})
    testing.expect_value(t,f.p.file,"")
}

// Recent and Favorites of the browser are of the user and of the project: the
// file in the .mirai of the project keeps them for the next editor.
@(test)
the_marks_of_the_browser_are_kept_in_the_project :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"marks")
    if folder=="" {return}
    project:=strings.concatenate({folder,"/game"},context.temp_allocator)
    testing.expect(t,os.make_directory_all(strings.concatenate({project,"/.mirai"},context.temp_allocator))==nil)
    f:=new(Preferences_Test);defer free(f)
    defer free(f.ai)
    preferences_test_open(f,folder)
    f.s.project_root=project
    preferences_open(&f.s,{})
    testing.expect(t,strings.has_suffix(f.p.marks_file,"/game/.mirai/"+MARKS_FILE),f.p.marks_file)
    content_used(&f.s,{1,2})
    content_favorite_toggle(&f.c,{3,4})
    preferences_save(&f.s)
    delete(f.p.file);delete(f.p.marks_file)
    preferences_test_open(f,folder)
    f.s.project_root=project
    preferences_open(&f.s,{})
    defer {delete(f.p.file);delete(f.p.marks_file)}
    testing.expect(t,f.c.marks.recent[0]=={1,2} && f.c.marks.recent[1]=={} && f.c.marks.favorites[0]=={3,4})
}

// Where the browser of a project was left, its folder, its filters and what
// is open, comes back in the next editor with its marks; the search does not.
@(test)
the_navigation_of_the_browser_is_kept_in_the_project :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"navigation")
    if folder=="" {return}
    project:=strings.concatenate({folder,"/game"},context.temp_allocator)
    testing.expect(t,os.make_directory_all(strings.concatenate({project,"/.mirai"},context.temp_allocator))==nil)
    f:=new(Preferences_Test);defer free(f)
    defer free(f.ai)
    preferences_test_open(f,folder)
    f.s.project_root=project
    preferences_open(&f.s,{})
    content_place_set(&f.c,"Meshes/nested")
    f.c.categories,f.c.unused={.Mesh},true
    content_enter(&f.c,.None,"Meshes/nested")
    f.c.filter_length=copy(f.c.filter[:],"box")
    preferences_save(&f.s)
    data,_:=os.read_entire_file(f.p.marks_file,context.temp_allocator)
    testing.expectf(t,strings.contains(string(data),`"Content_Navigation"`) && strings.contains(string(data),`"place": "Meshes/nested"`) && !strings.contains(string(data),"box"),"%s",string(data))
    delete(f.p.file);delete(f.p.marks_file)
    core.value_free(&f.c,type_info_of(Content))

    preferences_test_open(f,folder)
    f.s.project_root=project
    preferences_open(&f.s,{})
    defer {delete(f.p.file);delete(f.p.marks_file);core.value_free(&f.c,type_info_of(Content))}
    expect_kept :: proc(t:^testing.T,c:^Content) {
        testing.expect_value(t,string(c.place[:c.place_length]),"Meshes/nested")
        testing.expect_value(t,string(c.at.folder[:c.at.length]),"Meshes/nested")
        testing.expect(t,c.categories=={.Mesh} && c.unused && c.filter_length==0)
    }
    expect_kept(t,&f.c)
    testing.expect(t,f.c.restore)
    // The registry still has all of it: the browser is left as it was read
    // and nothing is written again.
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    content_registry_read(&f.c,&registry,{CONTENT_TEST_PLUGIN_KIND})
    content_navigation_restore(&f.c,&registry)
    expect_kept(t,&f.c)
    testing.expect(t,!f.c.restore)
    written:=f.p.marks.written
    preferences_save(&f.s)
    testing.expect_value(t,f.p.marks.written,written)
}

@(private="file") Preferences_World :: struct {using world:core.Test_World}
@(private="file") Preferences_Editor :: struct {api:Api}

// preferences.set changes the areas it names at once and the file keeps what
// differs from the code; preferences.get says both.
@(test)
preferences_are_read_and_changed_through_the_api :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"preferences")
    if folder=="" {return}
    f:=new(Preferences_Test);defer free(f)
    defer free(f.ai)
    preferences_test_open(f,folder)
    preferences_open(&f.s,{})
    defer delete(f.p.file)
    info,made:=core.test_info(t,Preferences_World,core.Test_None,Preferences_Editor,test_types)
    if !made {return}
    defer core.test_info_destroy(&info)
    world:Preferences_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    inspector:Inspector
    editor:Preferences_Editor
    app:host.App
    f.s.info,f.s.edit_world,f.s.editor_world,f.s.app=&info,&world,&editor,&app
    f.s.selection,f.s.edits,f.s.inspector=&selection,&edits,&inspector
    history.edits_reset(&edits,edited_world(&f.s))
    if !testing.expect(t,api_open(&f.s,0,true)==.None) {return};defer api_close(&f.s)
    state:=api_state(&f.s);state.poll_temp=context.temp_allocator
    if api.method_find(&state.server,"preferences.get")==nil {preferences_api_register(&f.s,state)}
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    execute :: proc(state:^Api_State,out:^serial.Writer,name,params:string) -> api.Error {
        base.arena_reset(&state.server.scratch);serial.writer_reset(out)
        error,_:=api.method_execute(&state.server,api.method_find(&state.server,name),params,out)
        return error
    }

    error:=execute(state,&out,"preferences.set",`{"preferences":{"Viewport_Preferences":{"snap":true,"fly_speed":7}}}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,f.v.snap && f.v.fly_speed==7)
    text:=string(serial.writer_bytes(&out))
    api_result_shape_expect(t,text,Api_Preferences)
    kept:=strings.index(text,`"kept": `)
    testing.expect(t,kept>0 && strings.contains(text[kept:],`"fly_speed": 7`) && !strings.contains(text[kept:],`"grid"`),text)
    data,_:=os.read_entire_file(f.p.file,context.temp_allocator)
    testing.expect(t,strings.contains(string(data),`"fly_speed": 7`),string(data))

    for refusal in ([?][2]string{
        {`{"preferences":{"Viewports":{"snap":false}}}`,"Viewports is not an area of the preferences: they are Layout, Content_View"},
        {`{"preferences":{"Viewport_Preferences":{"zoom":1}}}`,`"zoom" is not a field`},
        {`{"Viewport_Preferences":{"snap":false}}`,`"Viewport_Preferences" is not a field: the fields are preferences`},
    }) {
        error=execute(state,&out,"preferences.set",refusal[0])
        testing.expect_value(t,error.code,api.INVALID_PARAMS)
        testing.expectf(t,strings.contains(error.message,refusal[1]),"%s: %s",refusal[0],error.message)
        testing.expect(t,f.v.snap && f.v.fly_speed==7)
    }
}
