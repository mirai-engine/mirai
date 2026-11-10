package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:std/serial"

Api_Test_Provider :: struct {provider:Api_Provider}
Api_Test_Editor :: struct {api:Api,provider:Api_Test_Provider}
Api_Test_Params :: struct {value:i32 `mirai:"optional"`}
Api_Test_Result :: struct {value:i32}

api_test_provider_v1 :: proc(dst:rawptr) {(^Api_Test_Provider)(dst)^={provider={register=api_test_register_v1}}}
api_test_provider_v2 :: proc(dst:rawptr) {(^Api_Test_Provider)(dst)^={provider={register=api_test_register_v2}}}
api_test_register_v1 :: proc(s:^Session) {
    defaults:=Api_Test_Params{value=7}
    // The method comes with its entry of the View menu and its key: a plugin gives one thing.
    api_method_register(s,Api_Test_Params,Api_Test_Result,{
        name="test.plugin",defaults=&defaults,run=api_test_run_v1,
        entry={label="Test plugin",params=`{"value":3}`,shortcut={key=.F9,set=true},menu=.View},
    })
}
api_test_register_v2 :: proc(s:^Session) {
    defaults:=Api_Test_Params{value=9}
    api_method_register(s,Api_Test_Params,Api_Test_Result,{name="test.plugin",defaults=&defaults,run=api_test_run_v2})
}
api_test_run_v1 :: proc(s:^Session,call:^api.Call) {
    value:=api.call_params(call,Api_Test_Params).value
    api.call_result(call,Api_Test_Result).value=value
    if api_person(s) {s.frames=int(value)}
}
api_test_run_v2 :: proc(s:^Session,call:^api.Call) {api.call_result(call,Api_Test_Result).value=2*api.call_params(call,Api_Test_Params).value}

@(private="file")
Api_Test_World :: struct {using world:core.Test_World}

@(private="file")
api_test_types :: proc(types:^[dynamic]core.Test_Type) {
    append(types,core.test_type(Api_Test_Provider,default=proc(dst:^Api_Test_Provider) {api_test_provider_v1(dst)}))
}

@(test)
editor_plugin_methods_exist_before_frames_and_reload_from_current_metadata :: proc(t:^testing.T) {
    world:Api_Test_Editor
    edits:history.Edits
    info,described:=core.test_info(t,Api_Test_World,core.Test_None,Api_Test_Editor,api_test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    provider:=&info.storages[info.storages_by_type[Api_Test_Provider]]
    provider.plugin="test_plugin"
    session:=Session{info=&info,editor_world=&world,edits=&edits}
    if !testing.expect_value(t,api_open(&session,0,true),Api_Open_Error.None) {return}
    defer api_close(&session)
    state:=api_state(&session)
    state.poll_temp=context.temp_allocator
    port:=api_port(&session)
    out:serial.Writer
    serial.writer_init(&out)
    defer serial.writer_destroy(&out)
    method:=api.method_find(&state.server,"test.plugin")
    if !testing.expect(t,method!=nil) {return}
    testing.expect_value(t,method.plugin,"test_plugin")
    testing.expect_value(t,api.method_find(&state.server,"engine.describe").plugin,"")
    error,ok:=api.method_execute(&state.server,method,"{}",&out)
    testing.expectf(t,ok,"%v",error)
    testing.expect_value(t,string(serial.writer_bytes(&out)),`{"value": 7}`)
    testing.expect(t,!api_person(&session) && session.frames==0)
    // Its entry is named as its method, and its key runs the method as the person at the editor.
    entry:=command_binding(&session,"test.plugin")
    if !testing.expect(t,entry!=nil && entry.method=="test.plugin" && entry.menu==.View) {return}
    shortcuts_run(&session,{.F9},{})
    testing.expect_value(t,session.frames,0)
    commands_run(&session)
    testing.expect_value(t,session.frames,3)
    testing.expect(t,!api_person(&session))
    provider.default=api_test_provider_v2
    session.library_generation+=1
    api_poll(&session)
    testing.expect_value(t,api_port(&session),port)
    testing.expect_value(t,session.frame,u64(0))
    out.count=0
    method=api.method_find(&state.server,"test.plugin")
    if !testing.expect(t,method!=nil) {return}
    error,ok=api.method_execute(&state.server,method,"{}",&out)
    testing.expectf(t,ok,"%v",error)
    testing.expect_value(t,string(serial.writer_bytes(&out)),`{"value": 18}`)
    // The entries are those of the library in use: the new one gives none.
    testing.expect(t,command_binding(&session,"test.plugin")==nil && command_binding(&session,"save")!=nil)
}
