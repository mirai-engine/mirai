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
motion_authoring_uses_array_lengths_and_defaults_and_refuses_windows_of_one_name :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"motion") {return};defer authoring_test_destroy(f)
    source:=authoring_test_id_text(program_test_source(f,t))
    defaults:=motion_write_defaults();inspect:=Asset_Inspect_Params{limit=1}
    authoring_test_register(f,t,"set",Motion_Write_Params,authoring_motion_set,defaults)
    authoring_test_register(f,t,"inspect",Asset_Inspect_Params,asset_inspect,&inspect)
    result:=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"actor.character","animation":"%s","windows":[{{"name":"ledge"}}]}}`,source))
    if !testing.expect(t,result.code==0,fmt.tprintf("%s %s",result.message,result.data)) {return}
    id:=authoring_test_id(f,"actor.character");identity:=authoring_test_id_text(id);revision:=authoring_test_revision(f,"actor.character")
    testing.expect(t,id!={})
    file:asset.Asset
    if !testing.expect_value(t,authoring_test_load(f,"actor.character",&file),asset.Error.None) {return}
    set,error:=anim.character_view(&file,&f.assets.types);profile:=set.motion
    if testing.expect_value(t,error,asset.Error.None) {
        testing.expect_value(t,len(profile.windows),1)
        testing.expect(t,profile.windows[0].weight==1 && profile.windows[0].translation && profile.windows[0].rotation && profile.warp.weight==1)
    }
    asset.asset_close(&file)
    result=authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s"}}`,identity));testing.expect_value(t,result.code,0)
    text:=api.json_compact(string(serial.writer_bytes(&f.out)));testing.expect(t,strings.contains(text,`"windows_total":1`) && !strings.contains(text,"spine_count"))
    result=authoring_test_execute(f,"set",`{"path":"actor.character","windows":[{"name":"ledge"},{"name":"ledge"}]}`)
    testing.expect_value(t,result.code,api.INVALID_PARAMS);testing.expect_value(t,authoring_test_revision(f,"actor.character"),revision)
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
