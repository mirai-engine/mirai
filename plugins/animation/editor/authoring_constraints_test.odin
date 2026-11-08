package animation_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:editor"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

@(test)
procedural_profile_authoring_derives_nested_arrays_and_exposes_compact_typed_results :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"constraints") {return};defer authoring_test_destroy(f)
    defaults:=Profile_Set_Params{};profile_constraints_defaults(&defaults)
    authoring_test_register(f,t,"create",Authoring_Create_Params,authoring_profile_create);authoring_test_register(f,t,"set",Profile_Set_Params,authoring_profile_set,&defaults)
    inspect:=Profile_Inspect_Params{limit=16};authoring_test_register(f,t,"inspect",Profile_Inspect_Params,authoring_profile_inspect,&inspect)
    if !testing.expect_value(t,authoring_test_execute(f,"create",`{"path":"constraints.pose"}`).code,0) {return}
    id:=authoring_test_id(f,"constraints.pose");identity:=authoring_test_id_text(id)
    result:=authoring_test_execute(f,"set",fmt.tprintf(`{{"asset":"%s","table":"Chain_IK","chain_ik":{{"name":"arm","root":{{"path":"shoulder"}},"end":{{"path":"hand"}},"limits":[{{"min_bend":0,"max_bend":2}}]}}}}`,identity))
    if !testing.expect(t,result.code==0,result.message) {return}
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"asset":"%s","table":"Twist","twist":{{"name":"twist","source":{{"path":"hand"}},"root":{{"path":"shoulder"}},"end":{{"path":"hand"}},"amounts":[{{"value":0.25}},{{"value":0.75}}]}}}}`,identity))
    if !testing.expect(t,result.code==0,result.message) {return}
    file:asset.Asset;testing.expect_value(t,authoring_test_load(f,"constraints.pose",&file),asset.Error.None)
    profile,error:=anim.pose_profile_view(&file,&f.assets.types);testing.expect_value(t,error,asset.Error.None);testing.expect(t,profile.chain_ik[0].limit_count==1 && profile.chain_ik[0].iterations==24 && profile.twist[0].amount_count==2 && profile.twist[0].amounts[1]==.75);asset.asset_close(&file)
    result=authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s","table":"Twist"}}`,identity));testing.expect_value(t,result.code,0)
    text:=string(serial.writer_bytes(&f.out));testing.expect(t,!strings.contains(text,"amount_count") && strings.contains(text,`"value": 0.75`) && !strings.contains(text,"limit_count"))
    schema:=authoring_result_schema(Profile_Inspect_Result,type_info_of(Profile_Inspect_Result),context.temp_allocator);testing.expect(t,!strings.contains(schema,"amount_count") && !strings.contains(schema,"effector_count") && !strings.contains(schema,"limit_count"))
}
