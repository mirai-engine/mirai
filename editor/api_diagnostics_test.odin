package editor

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:std/base"
import "mirai:std/serial"

Api_Diagnostics_Test_Editor :: struct {api:Api}

@(private)
@(test_world,editor="Api_Diagnostics_Test_Editor")
Api_Diagnostics_Test_World :: struct {using world:Test_World}

@(private="file")
api_diagnostics_session :: proc(t:^testing.T,world:^Api_Diagnostics_Test_Editor,edits:^history.Edits,info:^core.World_Info) -> (s:Session,ok:bool) {
    info^=test_info(t,Api_Diagnostics_Test_World) or_return
    return {info=info,editor_world=world,edits=edits},true
}

@(test)
editor_api_registers_every_method_and_refuses_loudly_when_full :: proc(t:^testing.T) {
    world:Api_Diagnostics_Test_Editor
    edits:history.Edits
    info:core.World_Info
    session,described:=api_diagnostics_session(t,&world,&edits,&info)
    if !described {return}
    defer test_info_destroy(&info)
    api_opened,api_problem:=api_open(&session,0,true)
    if !testing.expectf(t,api_opened==.None,"%v: %s",api_opened,api_problem) {return}
    defer api_close(&session)
    state:=api_state(&session)
    testing.expect_value(t,state.refused,0)
    testing.expect_value(t,state.count+1,state.server.method_count)
    for name in AI_PROMPT_TOOLS {
        method:=api.method_find(&state.server,name)
        testing.expectf(t,method!=nil && .Core in method.flags,"the instructions name %s as a tool: it must be listed",name)
    }
    // The plugins of a project register through providers, after the methods of the editor.
    PLUGIN_METHODS :: 64
    testing.expectf(t,state.count+PLUGIN_METHODS<=API_METHOD_CAPACITY,"the editor registers %d of %d methods; raise API_METHOD_CAPACITY",state.count,API_METHOD_CAPACITY)
    for state.count<API_METHOD_CAPACITY {
        if !testing.expectf(t,api_register(&session,state,{name=fmt.tprintf("fill.m%d",state.count),run=proc(s:^Session,call:^api.Call) {}}),"%s",state.refusal) {return}
    }
    testing.expect_value(t,state.refused,0)
    testing.expect(t,!api_register(&session,state,{name="fill.over",run=proc(s:^Session,call:^api.Call) {}}))
    testing.expect_value(t,state.refused,1)
    testing.expect(t,strings.contains(state.refusal,"API_METHOD_CAPACITY") && strings.contains(state.refusal,"fill.over"),state.refusal)
    testing.expect_value(t,state.count+1,state.server.method_count)
}

@(test)
editor_engine_diagnostics_lists_the_console_after_a_serial :: proc(t:^testing.T) {
    world:Api_Diagnostics_Test_Editor
    edits:history.Edits
    info:core.World_Info
    console:Console
    resize(&console.entries,CONSOLE_CAPACITY)
    defer console_destroy(&console)
    session,described:=api_diagnostics_session(t,&world,&edits,&info)
    if !described {return}
    defer test_info_destroy(&info)
    session.console=&console
    api_opened,api_problem:=api_open(&session,0,true)
    if !testing.expectf(t,api_opened==.None,"%v: %s",api_opened,api_problem) {return}
    defer api_close(&session)
    state:=api_state(&session)
    state.poll_temp=context.temp_allocator
    console_add(&console,.Info,"loaded")
    console_add(&console,.Error,"first failure")
    mark:=console.serial
    console_add(&console,.Warning,"disk slow")
    console_add(&console,.Warning,"slow frame")
    console_add(&console,.Warning,"slow frame")
    console_add(&console,.Debug,"noise")
    console_add(&console,.Error,"second failure")
    console_add(&console,.Error,"third failure")
    method:=api.method_find(&state.server,"engine.diagnostics")
    if !testing.expect(t,method!=nil) {return}
    out:serial.Writer
    serial.writer_init(&out)
    defer serial.writer_destroy(&out)
    error,ok:=api.method_execute(&state.server,method,fmt.tprintf(`{{"since":%d,"min_level":"Warning","limit":3}}`,mark),&out)
    if !testing.expectf(t,ok,"%v",error) {return}
    value,parsed:=json.parse(serial.writer_bytes(&out),allocator=context.temp_allocator)
    if !testing.expect_value(t,parsed,json.Error.None) {return}
    root:=value.(json.Object)
    console_object:=root["console"].(json.Object)
    entries:=console_object["entries"].(json.Array)
    testing.expect_value(t,int(console_object["omitted"].(json.Float)),1)
    testing.expect_value(t,int(console_object["serial"].(json.Float)),int(console.serial))
    if testing.expect_value(t,len(entries),3) {
        testing.expect_value(t,entries[0].(json.Object)["text"].(json.String),"slow frame")
        testing.expect_value(t,int(entries[0].(json.Object)["repeats"].(json.Float)),1)
        testing.expect_value(t,entries[1].(json.Object)["text"].(json.String),"second failure")
        testing.expect_value(t,entries[2].(json.Object)["text"].(json.String),"third failure")
        testing.expect_value(t,entries[1].(json.Object)["level"].(json.String),"Error")
    }
    validation:=root["validation"].(json.Object)
    testing.expect_value(t,int(validation["errors"].(json.Float)),0)
    testing.expect_value(t,len(validation["messages"].(json.Array)),0)
    testing.expect_value(t,len(root["asset_errors"].(json.Array)),0)
    testing.expect_value(t,root["build"].(json.Object)["phase"].(json.String),"Idle")
    testing.expect_value(t,len(root["problems"].(json.Array)),0)
}

@(private)
@(test_world)
Problems_Test_World :: struct {using world:Test_World,ids:core.Table(core.Id),names:core.Table(core.Name)}

@(test)
editor_engine_diagnostics_names_the_entity_of_each_problem :: proc(t:^testing.T) {
    world:Problems_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    hero:=core.create(&world.entities)
    name:core.Name
    base.text_set(name.text[:],"Hero")
    core.add(&world.ids,hero,{value=7})
    core.add(&world.names,hero,name)
    test_world_settle(&world)
    problems:core.Problems
    core.report(&problems,core.NONE,"scene.spawn","The prefab 'props/crate.scene' did not spawn: the file is missing. Import it again.")
    core.report(&problems,hero,"animation.clip","Animation.clip is '%s', which the skeleton does not have; name one of its clips.","run")
    core.report(&problems,hero,"animation.clip","Animation.clip is '%s', which the skeleton does not have; name one of its clips.","walk")
    listed:=api_problems_of(test_world_ref(&world),&problems,"edit",context.temp_allocator)
    text,_:=serial.text_encode(listed,.Line,context.temp_allocator)
    value,parsed:=json.parse(text,allocator=context.temp_allocator)
    if !testing.expectf(t,parsed==.None,"%v: %s",parsed,string(text)) {return}
    root:=value.(json.Object)
    testing.expect_value(t,int(root["serial"].(json.Float)),3)
    testing.expect_value(t,int(root["evicted"].(json.Float)),0)
    entries:=root["entries"].(json.Array)
    if !testing.expect_value(t,len(entries),2) {return}
    spawn,clip:=entries[0].(json.Object),entries[1].(json.Object)
    testing.expect_value(t,spawn["code"].(json.String),"scene.spawn")
    testing.expect(t,spawn["id"].(json.String)=="" && spawn["entity"].(json.String)=="" && !spawn["alive"].(json.Boolean),"a problem about no entity names none")
    testing.expect_value(t,clip["code"].(json.String),"animation.clip")
    testing.expect_value(t,clip["id"].(json.String),"0x0000000000000007")
    testing.expect_value(t,clip["entity"].(json.String),fmt.tprintf("0x%016x",u64(hero)))
    testing.expect_value(t,clip["name"].(json.String),"Hero")
    testing.expect(t,clip["alive"].(json.Boolean))
    testing.expect_value(t,clip["message"].(json.String),"Animation.clip is 'run', which the skeleton does not have; name one of its clips.")
    testing.expect_value(t,int(clip["count"].(json.Float)),2)
    testing.expect_value(t,int(clip["first"].(json.Float)),2)
    testing.expect_value(t,int(clip["last"].(json.Float)),3)
}
