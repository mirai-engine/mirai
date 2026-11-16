package editor

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:cook/shaders"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/serial"

@(private="file")
PROGRAMS_TEST_ENGINE :: #directory+"/.."

@(private="file")
programs_test_call :: proc(t:^testing.T,state:^Api_State,method,params:string) -> (reply:json.Object,failure:api.Error,ok:bool) {
    m:=api.method_find(&state.server,method)
    if !testing.expectf(t,m!=nil,"%s is registered",method) {return}
    out:=make([]u8,1<<20,context.temp_allocator)
    w:serial.Writer
    serial.writer_init_fixed(&w,out)
    // Without a project file the publication each change asks for fails at
    // once, and logs why: quiet for the call alone, so the test still logs.
    {
        context.logger=log.nil_logger()
        failure,ok=api.method_execute(&state.server,m,params,&w)
    }
    if !ok {return}
    text:=string(serial.writer_bytes(&w))
    testing.expect_value(t,api.result_mismatch(m.result_id,text),"")
    value,_:=json.parse_string(text,allocator=context.temp_allocator)
    reply,_=value.(json.Object)
    return
}

@(test)
programs_of_any_domain_are_made_and_changed_on_disk_as_steps_of_undo :: proc(t:^testing.T) {
    cleaned,_:=filepath.clean(PROGRAMS_TEST_ENGINE,context.temp_allocator)
    engine,_:=strings.replace_all(cleaned,"\\","/",context.temp_allocator)
    if _,found:=shaders.tool_find(engine,.Slangc,context.temp_allocator);!found {log.warn("slangc is not installed: run `mirai setup slang`");return}
    f:Files_Test
    if !files_test_open(t,&f,"programs-api") {return}
    defer files_test_close(&f)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=project.path(f.root,"assets",allocator=context.temp_allocator),capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    build:Build_State
    defer programs_cancel(&f.s)
    s:=&f.s
    s.app,s.build,s.engine_root,s.has_project=&app,&build,engine,true
    state:=new(Api_State);defer free(state)
    state.poll_temp=context.temp_allocator
    if !testing.expect_value(t,api.server_init(&state.server,{port=0,max_methods=8,max_connections=1,max_request=64*1024,max_response=1<<20,scratch=4<<20}),api.Init_Error.None) {return}
    defer api.server_destroy(&state.server)
    programs_api_register(s,state)
    if !testing.expectf(t,state.refused==0,"%s",state.refusal) {return}
    path:=project.path(f.root,"shaders/glow_post.slang",allocator=context.temp_allocator)
    held :: proc(path:string) -> string {
        data,error:=os.read_entire_file(path,context.temp_allocator)
        return error==nil?string(data):"<none>"
    }

    // A PostProcess program from the template of its domain, written at once.
    reply,failure,ok:=programs_test_call(t,state,"material.program.create",`{"program":"Glow_Post","kind":"postprocess"}`)
    if !testing.expectf(t,ok,"%s %s",failure.message,failure.data) {return}
    testing.expect(t,reply["kind"].(json.String)=="postprocess" && reply["compiled"].(json.Boolean) && reply["file"].(json.String)=="shaders/glow_post.slang")
    template:=shaders.program_template(.Postprocess,"Glow_Post",context.temp_allocator)
    testing.expect_value(t,held(path),template)
    testing.expect_value(t,build.programs.serial,u64(1))

    // Its name is taken now, and a source has to declare the name it is made with.
    _,failure,ok=programs_test_call(t,state,"material.program.create",`{"program":"Glow_Post"}`)
    testing.expect(t,!ok && failure.code==api.INVALID_PARAMS && strings.contains(failure.message,"material.program.edit"),failure.message)
    _,failure,ok=programs_test_call(t,state,"material.program.create",`{"program":"Other","source":"//! mirai ui Else\n"}`)
    testing.expect(t,!ok && strings.contains(failure.message,"//! mirai ui Other"),failure.message)
    _,failure,ok=programs_test_call(t,state,"material.program.create",`{"program":"Bad","kind":"light"}`)
    testing.expect(t,!ok && strings.contains(failure.message,`"light" is not one of its names`),failure.message)

    // It is found by its name, as its domain.
    reply,failure,ok=programs_test_call(t,state,"material.program.inspect",`{"program":"Glow_Post"}`)
    testing.expectf(t,ok && reply["kind"].(json.String)=="postprocess" && reply["source"].(json.String)==template,"%s",failure.message)

    // An edit that does not compile changes nothing; one that does is a step of its own.
    _,failure,ok=programs_test_call(t,state,"material.program.edit",`{"program":"Glow_Post","edits":[{"old":"p.tint","new":"p.tint*brightness"}]}`)
    testing.expect(t,!ok && failure.code==api.INVALID_PARAMS && strings.contains(failure.data,`"kind": "postprocess"`),failure.data)
    testing.expect_value(t,held(path),template)
    _,failure,ok=programs_test_call(t,state,"material.program.edit",`{"program":"Glow_Post","source":"//! mirai surface Glow_Post\n"}`)
    testing.expect(t,!ok && strings.contains(failure.message,"//! mirai postprocess Glow_Post"),failure.message)
    reply,failure,ok=programs_test_call(t,state,"material.program.edit",`{"program":"Glow_Post","edits":[{"old":"p.tint","new":"p.tint*0.5"}]}`)
    testing.expectf(t,ok && reply["compiled"].(json.Boolean),"%s %s",failure.message,failure.data)
    testing.expect(t,strings.contains(held(path),"p.tint*0.5"))

    // Its undo takes the edit back, and then the program: the steps are of the API.
    w:=edited_world(s)
    f.edits.author=history.EDIT_AUTHOR_API
    testing.expect(t,programs_test_quiet_undo(&f,w))
    testing.expect_value(t,held(path),template)
    testing.expect(t,programs_test_quiet_undo(&f,w))
    testing.expect_value(t,held(path),"<none>")
    _,_,ok=programs_test_call(t,state,"material.program.inspect",`{"program":"Glow_Post"}`)
    testing.expect(t,!ok,"an undone program is not there")

    // Publishing again answers with what that left.
    published:=build.programs.serial
    method:=api.Method{result_id=Api_Build_Result}
    result:Api_Build_Result
    publish:=api.Call{method=&method,result=&result,allocator=context.temp_allocator}
    {
        context.logger=log.nil_logger()
        api_build_shaders(s,&publish,5)
    }
    testing.expect(t,publish.failed && strings.contains(publish.error.message,"could not be published") && build.programs.serial==published+1,publish.error.message)
}

@(private="file")
programs_test_quiet_undo :: proc(f:^Files_Test,w:core.World_Ref) -> bool {
    context.logger=log.nil_logger()
    return history.undo(&f.edits,w,&f.selection)
}
