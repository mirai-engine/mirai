package animation_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import lib "mirai:std/anim"
import anim "plugins:animation/runtime"

@(private="file")
Preview_Test_World :: struct {using world:core.Test_World,animations:core.Table(anim.Animation),playback:anim.Playback,events:anim.Animation_Events,actions:anim.Action_Runtime}
@(private="file")
Preview_Test_Shared :: struct {sources:anim.Source_Assets}

@(test)
preview_trace_matches_its_typed_schema_names_curves_events_and_enforces_paging :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"trace") {return};defer authoring_test_destroy(f)
    id:=base.Asset_Id{16,32}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/source.anim",f.root),&f.assets.types,{id=id,clips={{name="walk",tracks={{target="pulse",property=.Float,keys={{time=0,value={2,0,0,0}},{time=1,value={4,0,0,0}}}},{target="look",property=.Vector,keys={{time=0,value={1,2,3,4}}}}},markers={{time=.5,name="step"}}}}}),asset.Error.None);host.assets_scan(&f.assets)
    file:asset.Asset;testing.expect_value(t,authoring_test_load(f,"source.anim",&file),asset.Error.None);defer asset.asset_close(&file)
    view,error:=asset.animation_view(&file,&f.assets.types);testing.expect_value(t,error,asset.Error.None)
    w:Preview_Test_World;if !core.test_world_init(t,&w,anim.test_types) {return};defer core.test_world_destroy(&w)
    entity:=core.create(&w.entities);description:=anim.ANIMATION_DEFAULT;description.asset=id;core.add(&w.animations,entity,description);core.test_world_settle(&w)
    content:=host.content_animation(&f.app,id);if !testing.expect(t,content!=nil) {return}
    player:=lib.player_make(1);player.time=.5
    append(&w.playback.states,anim.Playing{entity=entity,asset=id,clip=0,time=.5,duration=1,fader={current=player},motion={translation={1,0,0},rotation=1},root_enabled=true})
    w.playback.states[0].layers[1]={clip=base.name_hash("walk"),weight=.5,fader={current=player}}
    w.playback.states[0].asked[1]={clip=base.name_hash("walk"),weight=.5,sync=true};w.playback.states[0].stack=2
    append(&w.playback.states[0].curves,anim.Curve_Output{target=base.name_hash("pulse"),property=.Float,value={3,0,0,0},weight=.4});append(&w.playback.states[0].curves,anim.Curve_Output{target=base.name_hash("look"),property=.Vector,value={1,2,3,4},weight=.7})
    core.push(&w.events.queue,anim.Animation_Event{entity=entity,kind=.Marker,clip=base.name_hash("walk"),name=base.name_hash("step"),time=.5,weight=.4})
    trace:=Preview_Trace{view=view};serial.writer_init(&trace.writer,4096);defer serial.writer_destroy(&trace.writer)
    p:=Preview_Params{trace=true,trace_offset=1,trace_limit=1,ticks=3,dt=.1};call:=api.Call{server=&f.server,out=&f.out,allocator=context.temp_allocator}
    world:=core.test_world_ref(&w);preview_trace_frame(&call,&trace,world,entity,&p,0,&f.app);testing.expect_value(t,trace.shown,u32(0));preview_trace_frame(&call,&trace,world,entity,&p,1,&f.app);testing.expect_value(t,trace.shown,u32(1))
    text:=string(serial.writer_bytes(&trace.writer));testing.expect(t,strings.contains(text,`"clip": "walk"`) && strings.contains(text,`"marker": "step"`) && strings.contains(text,`"property": "Float"`) && strings.contains(text,`"property": "Vector"`) && strings.contains(text,`"translation": [1, 0, 0]`))
    synced:=false
    testing.expect_value(t,api.method_register(&f.server,{name="validate_frame",params=Preview_Trace_Result,params_info=type_info_of(Preview_Trace_Result),result=serial.Json,writes_result=true,user=&synced,handler=proc(call:^api.Call) {frame:=api.call_params(call,Preview_Trace_Result);for leaf in frame.leaves {if leaf.layer==1 {(^bool)(call.user)^=leaf.sync_mode==.Markers && leaf.source==.Layer}};serial.text_write_raw(call.out,"{}")}}),api.Register_Error.None)
    result:=authoring_test_execute(f,"validate_frame",text);testing.expect(t,result.code==0 && synced,result.message)
    count:=trace.writer.count;preview_trace_frame(&call,&trace,world,entity,&p,2,&f.app);testing.expect_value(t,trace.writer.count,count)
    serial.writer_reset(&f.out);preview_trace_result(&call,&trace,&p);testing.expect(t,strings.contains(string(serial.writer_bytes(&f.out)),`"trace_truncated":true`))
}

@(test)
preview_trace_resolves_external_marker_and_curve_labels_from_their_source_once :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"trace-sources") {return};defer authoring_test_destroy(f)
    primary,other:=base.Asset_Id{17,32},base.Asset_Id{17,33}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/primary.anim",f.root),&f.assets.types,{id=primary,clips={{name="walk",tracks={{target="pulse",property=.Float,keys={{time=0,value={1,0,0,0}}}}},markers={{time=.25,name="primary_step"}}}}}),asset.Error.None)
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/other.anim",f.root),&f.assets.types,{id=other,clips={{name="walk",tracks={{target="SmileOnly",property=.Float,slot=2,keys={{time=0,value={.75,0,0,0}}}}},markers={{time=.5,name="external_contact"}}}}}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    first:=host.content_animation(&f.app,primary);second:=host.content_animation(&f.app,other)
    if !testing.expect(t,first!=nil && second!=nil) {return}
    sources:=[2]host.Content_Animation{host.content_animation(&f.app,primary)^,host.content_animation(&f.app,other)^}
    shared:Preview_Test_Shared;shared.sources.allocator=context.allocator;defer anim.source_assets_free(&shared.sources)
    ids:=make([]base.Asset_Id,2);ids[0],ids[1]=primary,other
    append(&shared.sources.sets,anim.Source_Set{primary=primary,ids=ids,generations=make([]u32,2)});append(&shared.sources.plans,anim.Source_Plan{primary=primary,set=1,valid=true})
    testing.expect_value(t,anim.source_join(&shared.sources,&shared.sources.sets[0],primary,sources[:]),anim.Source_Error.None)
    f.app.shared=&shared
    file:asset.Asset;testing.expect_value(t,host.assets_file(&f.assets,primary,asset.KIND_ANIMATION,&file),asset.Error.None);defer asset.asset_close(&file)
    view,error:=asset.animation_view(&file,&f.assets.types);testing.expect_value(t,error,asset.Error.None)
    info,described:=core.test_info(t,Preview_Test_World,Preview_Test_Shared,core.Test_None,anim.test_types);if !described {return};defer core.test_info_destroy(&info)
    w:Preview_Test_World;defer core.world_destroy(&info,.World,&w);if !testing.expect(t,core.world_init(&info,.World,&w,context.allocator)) {return}
    entity:=core.create(&w.entities);description:=anim.ANIMATION_DEFAULT;description.asset=primary;core.add(&w.animations,entity,description);core.settle(&info,&w,nil)
    player:=lib.player_make(2);player.time=.5
    append(&w.playback.states,anim.Playing{entity=entity,asset=primary,source_plan=1,generation=shared.sources.sets[0].content.generation,clip=1,time=.5,duration=.5,fader={current=player}})
    append(&w.playback.states[0].curves,anim.Curve_Output{target=base.name_hash("SmileOnly"),property=.Float,slot=2,value={.75,0,0,0},weight=1})
    core.push(&w.events.queue,anim.Animation_Event{entity=entity,kind=.Marker,animation=other,clip=base.name_hash("walk"),name=base.name_hash("external_contact"),time=.5,weight=1})
    trace:=Preview_Trace{view=view,primary=primary};defer preview_trace_sources_close(&trace)
    serial.writer_init(&trace.writer,16384);defer serial.writer_destroy(&trace.writer)
    p:=Preview_Params{trace=true,trace_limit=2,ticks=1,dt=.1};call:=api.Call{server=&f.server,out=&f.out,allocator=context.temp_allocator}
    ref:=core.world_ref(&w,&info)
    testing.expect(t,preview_trace_frame(&call,&trace,ref,entity,&p,0,&f.app))
    text:=string(serial.writer_bytes(&trace.writer))
    testing.expect(t,strings.contains(text,`"clip": "walk"`) && strings.contains(text,`"marker": "external_contact"`) && strings.contains(text,`"target": "SmileOnly"`) && strings.contains(text,`"target_hash":`))
    testing.expect(t,strings.contains(text,authoring_test_id_text(other)) && trace.source_count==1)
    loads:=f.assets.stats.loads
    testing.expect(t,preview_trace_frame(&call,&trace,ref,entity,&p,1,&f.app) && f.assets.stats.loads==loads)
}
