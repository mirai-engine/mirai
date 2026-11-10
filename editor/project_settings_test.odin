package editor

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

@(private="file") Api_Test_World :: struct {using world:core.Test_World}
@(private="file") Api_Test_Editor :: struct {api:Api}

@(private="file")
api_test_execute :: proc(state:^Api_State,out:^serial.Writer,name,params:string) -> api.Error {
    base.arena_reset(&state.server.scratch);serial.writer_reset(out)
    error,_:=api.method_execute(&state.server,api.method_find(&state.server,name),params,out)
    return error
}

@(private="file")
plugin_folder_write :: proc(root,name,dependency:string) {
    folder:=project.path(root,"plugins",name,allocator=context.temp_allocator)
    _=os.make_directory_all(folder)
    m:project.Plugin_Manifest
    base.text_set(m.name[:],name)
    base.text_set(m.version[:],"1.0.0")
    if dependency!="" {base.text_set(m.dependencies[0][:],dependency)}
    project.plugin_write(project.path(folder,project.PLUGIN_FILE,allocator=context.temp_allocator),&m)
}

// project.set changes only the fields it names and the plugins it switches,
// checked against the project before anything is written; project.get says
// what the file has and every plugin the project sees.
@(test)
project_set_writes_project_mirai_only_when_all_of_it_is_valid :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"editor-project")
    if folder=="" {return}
    root:=project.path(folder,"game",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(project.path(root,"assets/scenes",allocator=context.temp_allocator))==nil)
    m:=project.manifest_default("Game")
    file:=project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator)
    testing.expect_value(t,project.manifest_write(file,&m).code,project.Error_Code.None)
    plugin_folder_write(root,"alpha","")
    plugin_folder_write(root,"beta","alpha")
    testing.expect(t,os.write_entire_file(project.path(root,"assets/scenes/main.scene",allocator=context.temp_allocator),"")==nil)
    testing.expect(t,os.write_entire_file(project.path(root,"icon.png",allocator=context.temp_allocator),"")==nil)

    info,made:=core.test_info(t,Api_Test_World,core.Test_None,Api_Test_Editor,test_types)
    if !made {return}
    defer core.test_info_destroy(&info)
    world:Api_Test_World
    if !testing.expect(t,info.init[.World](&world,context.allocator)) {return}
    defer info.destroy[.World](&world)
    selection:history.Selection;defer delete(selection.entities)
    viewport:Viewport;gui:Editor_Ui;edits:history.Edits;defer history.edits_free(&edits)
    inspector:Inspector
    editor:Api_Test_Editor
    app:host.App
    // Without the root of the engine a change of the plugins starts no build.
    building:Build_State
    processes:Player_Processes
    session:=Session{info=&info,edit_world=&world,editor_world=&editor,app=&app,selection=&selection,viewport=&viewport,gui=&gui,edits=&edits,inspector=&inspector,build=&building,processes=&processes,project_root=root,assets_root=project.path(root,"assets",allocator=context.temp_allocator),has_project=true}
    history.edits_reset(&edits,edited_world(&session))
    if !testing.expect(t,api_open(&session,0,true)==.None) {return};defer api_close(&session)
    state:=api_state(&session);state.poll_temp=context.temp_allocator
    if api.method_find(&state.server,"project.get")==nil {project_api_register(&session,state)}
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    read :: proc(file:string) -> project.Manifest {
        m,_:=project.manifest_read(file)
        return m
    }

    error:=api_test_execute(state,&out,"project.set",`{"version":"1.2.3","identifier":"com.studio.game","icon":"icon.png","start_scene":"scenes/main.scene","window":{"mode":"Fullscreen"},"plugins":{"beta":true}}`)
    testing.expect_value(t,error.code,0)
    text:=strings.clone(string(serial.writer_bytes(&out)),context.temp_allocator)
    api_result_shape_expect(t,text,Api_Project_Changed)
    testing.expect(t,strings.contains(text,`"building": false`) && strings.contains(text,`"beta"`) && !strings.contains(text,"manifest"),text)
    written:=read(file)
    testing.expect_value(t,base.text_get(written.version[:]),"1.2.3")
    testing.expect_value(t,base.text_get(written.identifier[:]),"com.studio.game")
    testing.expect_value(t,written.window.mode,project.Window_Mode.Fullscreen)
    testing.expect_value(t,written.window.width,i32(1280))
    testing.expect_value(t,base.text_get(written.plugins[0][:]),"beta")
    error=api_test_execute(state,&out,"project.get",`{}`)
    testing.expect_value(t,error.code,0)
    text=strings.clone(string(serial.writer_bytes(&out)),context.temp_allocator)
    api_result_shape_expect(t,text,Api_Project)
    testing.expect(t,strings.contains(text,`"name": "alpha", "active": true, "named": false, "needed_by": "beta"`),text)

    // Each of these is refused with what is wrong and how to fix it, and leaves the file as it is.
    refusals:=[?]struct{params,says:string}{
        {`{"plugins":{"alpha":false}}`,"alpha is needed by beta"},
        {`{"plugins":{"gamma":true}}`,"gamma is not a plugin of the project or of the engine: they are alpha, beta"},
        {`{"plugins":{"beta":1}}`,"true to activate it or false to deactivate it"},
        {`{"identifier":"com studio"}`,"com.studio.game"},
        {`{"icon":"missing.png"}`,"does not exist in the project"},
        {`{"start_scene":"scenes/none.scene"}`,"does not exist"},
        {`{"window":{"width":0}}`,"go from 1 to"},
        {`{"title":"Game"}`,"title"},
        {`{"name":""}`,"name is missing"},
    }
    for refusal in refusals {
        error=api_test_execute(state,&out,"project.set",refusal.params)
        testing.expect_value(t,error.code,api.INVALID_PARAMS)
        testing.expectf(t,strings.contains(error.message,refusal.says),"%s: %s",refusal.params,error.message)
        testing.expect(t,read(file)==written)
    }

    // What a change that started a build says of it: still running, or the first error once it failed.
    building.phase=.Running
    still,failed:=api_project_build_state(&session)
    testing.expect(t,still && failed=="")
    building.phase=.Failed
    defer delete(building.diagnostics)
    append(&building.diagnostics,Build_Diagnostic{.Error,"game/game.odin",3,9,"could not find the plugin spawn"})
    still,failed=api_project_build_state(&session)
    testing.expect(t,!still && strings.contains(failed,"could not find the plugin spawn") && strings.contains(failed,"game/game.odin"),failed)
    building.phase=.Idle

    error=api_test_execute(state,&out,"project.set",`{"plugins":{"beta":false}}`)
    testing.expect_value(t,error.code,0)
    written=read(file)
    testing.expect_value(t,base.text_get(written.plugins[0][:]),"")
    error=api_test_execute(state,&out,"project.get","{}")
    testing.expect_value(t,error.code,0)
    api_result_shape_expect(t,string(serial.writer_bytes(&out)),Api_Project)
}
