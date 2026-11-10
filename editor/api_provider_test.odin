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
    api_method_register(s,{name="test.plugin",params=Api_Test_Params,params_info=type_info_of(Api_Test_Params),result=Api_Test_Result,result_info=type_info_of(Api_Test_Result),defaults=&defaults,run=api_test_run_v1})
}
api_test_register_v2 :: proc(s:^Session) {
    defaults:=Api_Test_Params{value=9}
    api_method_register(s,{name="test.plugin",params=Api_Test_Params,params_info=type_info_of(Api_Test_Params),result=Api_Test_Result,result_info=type_info_of(Api_Test_Result),defaults=&defaults,run=api_test_run_v2})
}
api_test_run_v1 :: proc(s:^Session,call:^api.Call) {api.call_result(call,Api_Test_Result).value=api.call_params(call,Api_Test_Params).value}
api_test_run_v2 :: proc(s:^Session,call:^api.Call) {api.call_result(call,Api_Test_Result).value=2*api.call_params(call,Api_Test_Params).value}

@(test)
editor_plugin_methods_exist_before_frames_and_reload_from_current_metadata :: proc(t:^testing.T) {
    world:Api_Test_Editor
    edits:history.Edits
    storages:=[2]core.Storage_Info{
        {name="Api",type=Api,info=type_info_of(Api),place=.Editor,offset=offset_of(Api_Test_Editor,api)},
        {name="Api_Test_Provider",type=Api_Test_Provider,info=type_info_of(Api_Test_Provider),place=.Editor,offset=offset_of(Api_Test_Editor,provider),default=api_test_provider_v1,plugin="test_plugin"},
    }
    info:=core.World_Info{storages=storages[:]}
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
    storages[1].default=api_test_provider_v2
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
}
