package animation_editor

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

@(private)
@(test_world)
Api_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    animations:core.Table(anim.Animation),
    requests:anim.Animation_Requests,
}

@(test)
animation_stop_and_seek_operate_on_the_play_world_and_refuse_edit_seeks :: proc(t:^testing.T) {
    info,described:=test_info(t,Api_Test_World)
    if !described {return}
    defer test_info_destroy(&info)
    document,play_world:Api_Test_World
    defer for w in ([2]^Api_Test_World{&document,&play_world}) {core.world_destroy(&info,.World,w)}
    for w in ([2]^Api_Test_World{&document,&play_world}) {
        if !testing.expect(t,core.world_init(&info,.World,w,context.allocator)) {return}
        e:=core.create(&w.entities)
        core.add(&w.ids,e,core.Id{17})
        core.add(&w.animations,e,anim.ANIMATION_DEFAULT)
        core.settle(&info,w,nil)
    }
    s:=editor.Session{edit_world=&document,info=&info,mode=.Play}
    s.runs[0]={world=&play_world}
    p:=request_defaults();copy(p.entity[:],"0000000000000011");p.stop=true
    out:serial.Writer;serial.writer_init(&out,4096);defer serial.writer_destroy(&out)
    method:=api.Method{params_id=Request_Params,result_id=Request_Result}
    answer:Request_Result
    call:=api.Call{method=&method,params=p,result=&answer,raw=`{"entity":"0000000000000011","stop":true}`,out=&out,allocator=context.temp_allocator}
    request(&s,&call)
    testing.expect(t,!call.failed && !play_world.animations.values[0].playing && document.animations.values[0].playing)
    p=request_defaults();copy(p.entity[:],"0000000000000011");p.seek=1.25
    call=api.Call{method=&method,params=p,result=&answer,raw=`{"entity":"0000000000000011","seek":1.25}`,out=&out,allocator=context.temp_allocator}
    request(&s,&call)
    testing.expect(t,!call.failed && len(play_world.requests.timeline.items)==1 && len(document.requests.timeline.items)==0)
    s.mode=.Edit
    s.runs[0]={}
    call.failed=false
    request(&s,&call)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS && strings.contains(call.error.data,"Tracks_Required") && len(document.requests.timeline.items)==0)
}

@(test)
animation_subtree_queries_bound_cycles_and_keep_neighboring_roots_separate :: proc(t:^testing.T) {
    w:Api_Test_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    a,b,child,cycle:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.parents,child,core.Parent{entity=a})
    core.add(&w.parents,cycle,core.Parent{entity=cycle})
    test_world_settle(&w)
    world:=test_world_ref(&w)
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
    params=Play_Params{speed=1,fade=invalid}
    call.failed=false
    play(&s,&call)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS)
}
