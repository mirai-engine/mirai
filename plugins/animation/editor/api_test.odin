package animation_editor

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Api_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    animations:core.Table(anim.Animation),
    requests:anim.Animation_Requests,
}

@(private)
api_test_settle :: proc(world,shared,editor:rawptr) {
    w:=(^Api_Test_World)(world)
    core.table_settle(&w.ids,&w.entities)
    core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.animations,&w.entities)
}

@(private)
api_test_destroy :: proc(w:^Api_Test_World) {
    core.table_destroy(&w.ids);core.table_destroy(&w.parents)
    core.table_destroy(&w.animations)
    delete(w.requests.seeks.items);delete(w.requests.poses.items);delete(w.requests.match_plays.items)
    core.entities_destroy(&w.entities)
}

@(test)
animation_stop_and_seek_operate_on_the_play_world_and_refuse_edit_seeks :: proc(t:^testing.T) {
    document,play_world:Api_Test_World
    core.entities_init(&document.entities);core.entities_init(&play_world.entities)
    defer api_test_destroy(&document);defer api_test_destroy(&play_world)
    tables:=[3]core.Table_Info{
        {type=core.Id,info=type_info_of(core.Id),offset=offset_of(Api_Test_World,ids)},
        {type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Api_Test_World,parents)},
        {type=anim.Animation,info=type_info_of(anim.Animation),offset=offset_of(Api_Test_World,animations)},
    }
    storages:=[1]core.Storage_Info{{type=anim.Animation_Requests,info=type_info_of(anim.Animation_Requests),offset=offset_of(Api_Test_World,requests)}}
    info:=core.World_Info{tables=tables[:],storages=storages[:],settle=api_test_settle}
    for w in ([2]^Api_Test_World{&document,&play_world}) {
        e:=core.create(&w.entities)
        core.add(&w.ids,e,core.Id{17})
        core.add(&w.animations,e,anim.ANIMATION_DEFAULT)
        api_test_settle(w,nil,nil)
    }
    s:=editor.Session{edit_world=&document,info=&info,mode=.Play}
    s.runs[0]={world=&play_world}
    p:=request_defaults();copy(p.entity[:],"0000000000000011");p.stop=true
    out:serial.Writer;serial.writer_init(&out,4096);defer serial.writer_destroy(&out)
    method:=api.Method{params_id=Request_Params}
    call:=api.Call{method=&method,params=p,raw=`{"entity":"0000000000000011","stop":true}`,out=&out,allocator=context.temp_allocator}
    request(&s,&call)
    testing.expect(t,!call.failed && !play_world.animations.values[0].playing && document.animations.values[0].playing)
    p=request_defaults();copy(p.entity[:],"0000000000000011");p.seek=1.25
    call=api.Call{method=&method,params=p,raw=`{"entity":"0000000000000011","seek":1.25}`,out=&out,allocator=context.temp_allocator}
    request(&s,&call)
    testing.expect(t,!call.failed && len(play_world.requests.seeks.items)==1 && len(document.requests.seeks.items)==0)
    s.mode=.Edit
    s.runs[0]={}
    call.failed=false
    request(&s,&call)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS && strings.contains(call.error.data,"Runtime_Required") && len(document.requests.seeks.items)==0)
}

@(test)
animation_subtree_queries_bound_cycles_and_keep_neighboring_roots_separate :: proc(t:^testing.T) {
    w:Api_Test_World
    core.entities_init(&w.entities);defer api_test_destroy(&w)
    table:=[1]core.Table_Info{{type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Api_Test_World,parents)}}
    info:=core.World_Info{tables=table[:]}
    a,b,child,cycle:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.parents,child,core.Parent{entity=a})
    core.add(&w.parents,cycle,core.Parent{entity=cycle})
    core.table_settle(&w.parents,&w.entities)
    world:=core.world_ref(&w,&info)
    testing.expect(t,within(world,a,a) && within(world,child,a) && !within(world,child,b) && !within(world,cycle,a))
}

@(test)
animation_api_refuses_non_finite_configuration_before_touching_the_world :: proc(t:^testing.T) {
    s:editor.Session
    invalid:=transmute(f32)u32(0x7fc00000)
    params:=Play_Params{speed=invalid}
    method:=api.Method{params_id=Play_Params}
    call:=api.Call{method=&method,params=&params,allocator=context.temp_allocator}
    play(&s,&call)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS)
    params=Play_Params{speed=1,weight=invalid}
    call.failed=false
    play(&s,&call)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS)
}
