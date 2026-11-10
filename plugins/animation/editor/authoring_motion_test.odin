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

@(test)
motion_authoring_uses_array_lengths_defaults_and_monotonic_distance_diagnostics :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"motion") {return};defer authoring_test_destroy(f)
    source:=authoring_test_id_text(program_test_source(f,t))
    defaults:=motion_write_defaults();inspect:=Asset_Inspect_Params{limit=1}
    authoring_test_register(f,t,"set",Motion_Write_Params,authoring_motion_set,defaults)
    authoring_test_register(f,t,"inspect",Asset_Inspect_Params,asset_inspect,&inspect)
    entry:=new(Authoring_Test_Entry,context.temp_allocator);entry^={&f.session,authoring_motion_distance}
    testing.expect_value(t,api.method_register(&f.server,{name="distance",params=type_info_of(Motion_Distance_Params_Query),result=type_info_of(Motion_Distance_Result),user=entry,handler=proc(call:^api.Call) {entry:=(^Authoring_Test_Entry)(call.user);entry.run(entry.session,call)}}),api.Register_Error.None)
    definition:=`"windows":[{"name":"ledge"}],"distances":[{"clip":"walk","name":"stop","keys":[{"time":0,"distance":3},{"time":1,"distance":1},{"time":2,"distance":0}]}]`
    result:=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"actor.character","animation":"%s",%s}}`,source,definition))
    if !testing.expect(t,result.code==0,fmt.tprintf("%s %s",result.message,result.data)) {return}
    id:=authoring_test_id(f,"actor.character");identity:=authoring_test_id_text(id);revision:=authoring_test_revision(f,"actor.character")
    testing.expect(t,id!={})
    file:asset.Asset
    if !testing.expect_value(t,authoring_test_load(f,"actor.character",&file),asset.Error.None) {return}
    set,error:=anim.character_view(&file,&f.assets.types);profile:=set.motion
    if testing.expect_value(t,error,asset.Error.None) {
        testing.expect_value(t,len(profile.windows),1);testing.expect_value(t,len(profile.keys),3)
        testing.expect(t,profile.windows[0].weight==1 && profile.windows[0].translation && profile.windows[0].rotation && profile.warp.weight==1)
    }
    asset.asset_close(&file)
    result=authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s"}}`,identity));testing.expect_value(t,result.code,0)
    text:=api.json_compact(string(serial.writer_bytes(&f.out)));testing.expect(t,strings.contains(text,`"windows_total":1`) && strings.contains(text,`"distances_total":1`) && !strings.contains(text,"spine_count"))
    testing.expect(t,strings.contains(text,`"distance":3`) || strings.contains(text,`"distance":3`))
    result=authoring_test_execute(f,"distance",fmt.tprintf(`{{"asset":"%s","name":"stop","distance":2}}`,identity));testing.expect_value(t,result.code,0)
    text=api.json_compact(string(serial.writer_bytes(&f.out)));testing.expect(t,strings.contains(text,"0.5") && strings.contains(text,"walk"))
    bad,_:=strings.replace_all(definition,`"distance":1`,`"distance":3`,context.allocator)
    defer delete(bad)
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"actor.character",%s}}`,bad))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"distances[0].keys"));testing.expect_value(t,authoring_test_revision(f,"actor.character"),revision)
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"actor.character","windows":[]}}`));testing.expect_value(t,result.code,0)
    testing.expect_value(t,authoring_test_id(f,"actor.character"),id)
}

@(test)
motion_authoring_warps_the_body_of_the_skeleton_and_rejects_invalid_ranges_and_transient_controls_in_edit :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"motion-pose") {return};defer authoring_test_destroy(f)
    source:=authoring_test_id_text(program_test_source(f,t))
    defaults:=motion_write_defaults()
    authoring_test_register(f,t,"set",Motion_Write_Params,authoring_motion_set,defaults)
    requested:=request_defaults();authoring_test_register(f,t,"request",Request_Params,request,requested)
    result:=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"pose.character","animation":"%s","warp":{{"stride":true,"orientation":true,"min_stride":0.5,"max_stride":2,"max_angle":1,"weight":1}}}}`,source))
    if !testing.expect(t,result.code==0,fmt.tprintf("%s %s",result.message,result.data)) {return}
    file:asset.Asset
    if !testing.expect_value(t,authoring_test_load(f,"pose.character",&file),asset.Error.None) {return};defer asset.asset_close(&file)
    set,error:=anim.character_view(&file,&f.assets.types)
    if testing.expect_value(t,error,asset.Error.None) {testing.expect(t,set.motion.warp.stride && set.motion.warp.orientation && set.motion.warp.max_angle==1)}
    result=authoring_test_execute(f,"set",`{"path":"pose.character","warp":{"stride":true,"min_stride":2,"max_stride":0.5,"max_angle":1,"weight":1}}`)
    testing.expect_value(t,result.code,api.INVALID_PARAMS)
    result=authoring_test_execute(f,"request",`{"entity":"0000000000000001","motion":[{"name":"ledge"}]}`)
    testing.expect_value(t,result.code,api.INVALID_PARAMS)
}

@(private="file")
Motion_Authoring_World :: struct {using world:core.Test_World,ids:core.Table(core.Id),animations:core.Table(anim.Animation),playback:anim.Playback,requests:anim.Animation_Requests}

@(test)
motion_distance_api_queues_forward_playback_rejects_backward_clock_and_allows_explicit_seek :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"motion-distance-play") {return};defer authoring_test_destroy(f)
    defaults:=motion_write_defaults();authoring_test_register(f,t,"set",Motion_Write_Params,authoring_motion_set,defaults)
    requested:=request_defaults();authoring_test_register(f,t,"request",Request_Params,request,requested)
    source_id:=base.Asset_Id{77,88}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/source.anim",f.root),&f.assets.types,{id=source_id,clips={{name="walk",tracks={{target="hip",property=.Position,keys={{time=0},{time=2,value={2,0,0,0}}}}}}}}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    result:=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"distance.character","animation":"%s","distances":[{{"clip":"walk","name":"stop","keys":[{{"time":0,"distance":3}},{{"time":2,"distance":0}}]}}]}}`,authoring_test_id_text(source_id)))
    if !testing.expect_value(t,result.code,0) {return}
    character_id:=authoring_test_id(f,"distance.character")
    world:Motion_Authoring_World;if !core.test_world_init(t,&world,anim.test_types) {return};defer core.test_world_destroy(&world)
    entity:=core.create(&world.entities);core.add(&world.ids,entity,{value=17})
    config:=anim.ANIMATION_DEFAULT;config.asset=character_id;core.add(&world.animations,entity,config)
    core.test_world_settle(&world)
    state:=anim.Playing{entity=entity,asset=source_id,clip=0,fader={current=lib.player_make(1)},was_playing=true,time=.5,duration=2};state.fader.current.time=.5
    append(&world.playback.states,state);resize(&world.playback.rows,core.entity_index(entity)+1);world.playback.rows[core.entity_index(entity)]=1
    f.session.info,f.session.mode=core.test_world_info(&world),.Play;f.session.runs[0]={world=&world}
    result=authoring_test_execute(f,"request",`{"entity":"0000000000000011","distance":{"name":"stop","distance":1.5}}`)
    testing.expect(t,result.code==0,fmt.tprintf("%s %s",result.message,result.data));testing.expect_value(t,len(world.requests.distances.items),1)
    if len(world.requests.distances.items)>0 {testing.expect_value(t,world.requests.distances.items[0],anim.Animation_Distance_Request{entity=entity,clip=base.name_hash("walk"),time=1})}
    result=authoring_test_execute(f,"request",`{"entity":"0000000000000011","distance":{"name":"stop","distance":3}}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Backwards"));testing.expect_value(t,len(world.requests.distances.items),1)
    result=authoring_test_execute(f,"request",`{"entity":"0000000000000011","distance":{"name":"stop","distance":3,"seek":true}}`)
    testing.expect_value(t,result.code,0);testing.expect_value(t,len(world.requests.distances.items),2)
    if len(world.requests.distances.items)>1 {testing.expect_value(t,world.requests.distances.items[1],anim.Animation_Distance_Request{entity=entity,clip=base.name_hash("walk"),time=0,seek=true})}
    f.session.mode=.Edit;testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","distance":{"name":"stop","distance":1}}`).code,api.INVALID_PARAMS)
}
