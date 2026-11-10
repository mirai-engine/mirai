package editor

import "core:os"
import "core:path/filepath"
import "core:strings"
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
    api_method_register(s,{params=type_info_of(Api_Test_Params),result=type_info_of(Api_Test_Result),
        name="test.plugin",defaults=&defaults,run=api_test_run_v1,
        entry={label="Test plugin",params=`{"value":3}`,shortcut={key=.F9,set=true},menu=.View},
    })
}
api_test_register_v2 :: proc(s:^Session) {
    defaults:=Api_Test_Params{value=9}
    api_method_register(s,{params=type_info_of(Api_Test_Params),result=type_info_of(Api_Test_Result),name="test.plugin",defaults=&defaults,run=api_test_run_v2})
}
api_test_run_v1 :: proc(s:^Session,call:^api.Call) {
    value:=api.call_params(call,Api_Test_Params).value
    api.call_result(call,Api_Test_Result).value=value
    if api_person(s) {s.frames=int(value)}
}
api_test_run_v2 :: proc(s:^Session,call:^api.Call) {api.call_result(call,Api_Test_Result).value=2*api.call_params(call,Api_Test_Params).value}

// The methods that still write their result into call.out or read their
// params from the text: engine.describe writes the schemas themselves, and
// what remains of rpc_init reads an object whose keys the world or a program
// names. A file holds exactly these; one that holds fewer lowers its count
// here, and none is added.
@(private="file")
API_HAND_WRITTEN :: [?]struct{file,pattern:string,count:int}{
    {"editor/api/rpc.odin","writes_result=true",1},
    {"plugins/ui_inspector/editor/api_tree.odin","writes_result=true",1},
    {"plugins/ui_inspector/editor/bindings.odin","writes_result=true",3},
    {"editor/api_material_instance.odin","rpc_init(",2},
    {"editor/api_play_edit.odin","rpc_init(",1},
}

// No method is described, read or written by hand past the files above.
@(test)
methods_are_described_read_and_written_by_their_structs :: proc(t:^testing.T) {
    root,_:=filepath.join({#directory,".."},context.temp_allocator)
    patterns:=[?]string{"writes_result=true","rpc_init(","result=type_info_of(serial.Json)","params_schema=","result_schema="}
    files:=make([dynamic]string,context.temp_allocator)
    walk :: proc(folder:string,files:^[dynamic]string) {
        entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
        if error!=nil {return}
        for entry in entries {
            if entry.type==.Directory {walk(entry.fullpath,files);continue}
            if strings.has_suffix(entry.name,".odin") && !strings.has_suffix(entry.name,"_test.odin") {append(files,entry.fullpath)}
        }
    }
    for folder in ([?]string{"editor","plugins"}) {
        path,_:=filepath.join({root,folder},context.temp_allocator)
        walk(path,&files)
    }
    testing.expect(t,len(files)>100,"the sources of the editor and the plugins are found")
    allowed:=API_HAND_WRITTEN
    for path in files {
        data,error:=os.read_entire_file(path,context.temp_allocator)
        if error!=nil {continue}
        relative,_:=filepath.rel(root,path,context.temp_allocator)
        relative,_=strings.replace_all(relative,"\\","/",context.temp_allocator)
        for pattern in patterns {
            count:=strings.count(string(data),pattern)
            limit:=0
            for entry in allowed {
                if entry.file==relative && entry.pattern==pattern {limit=entry.count}
            }
            testing.expectf(t,count==limit,"%s has %d of %q and may have %d: a method takes a struct for its params and fills one for its result",relative,count,pattern,limit)
        }
    }
}

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
    api_opened,api_problem:=api_open(&session,0,true)
    if !testing.expectf(t,api_opened==.None,"%v: %s",api_opened,api_problem) {return}
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
