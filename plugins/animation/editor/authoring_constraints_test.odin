package animation_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:editor/api"
import "mirai:asset"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

@(test)
procedural_profile_authoring_derives_nested_arrays_and_exposes_compact_typed_results :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"constraints") {return};defer authoring_test_destroy(f)
    defaults:=Profile_Set_Params{};profile_constraints_defaults(&defaults)
    authoring_test_register(f,t,"set",Profile_Set_Params,authoring_profile_set,&defaults)
    inspect:=Asset_Inspect_Params{limit=16};authoring_test_register(f,t,"inspect",Asset_Inspect_Params,asset_inspect,&inspect)
    // A new .character of only modifiers names no clips.
    result:=authoring_test_execute(f,"set",`{"path":"constraints.character","table":"Multi_IK","multi_ik":{"name":"arm","root":{"path":"shoulder"},"effectors":[{"name":"hand","bone":{"path":"hand"},"pole":[0,0,1],"use_pole":true,"reach":{"soft_distance":0.05,"max_stretch":0.2}}]}}`)
    if !testing.expect(t,result.code==0,result.message) {return}
    result=authoring_test_execute(f,"set",`{"path":"constraints.character","table":"Twist","twist":{"name":"twist","source":{"path":"hand"},"root":{"path":"shoulder"},"end":{"path":"hand"},"amounts":[{"value":0.25},{"value":0.75}]}}`)
    if !testing.expect(t,result.code==0,result.message) {return}
    identity:=authoring_test_id_text(authoring_test_id(f,"constraints.character"))
    file:asset.Asset;testing.expect_value(t,authoring_test_load(f,"constraints.character",&file),asset.Error.None)
    set,error:=anim.character_view(&file,&f.assets.types);profile:=set.pose
    testing.expect_value(t,error,asset.Error.None);testing.expect(t,set.info.animation=={} && len(profile.multi_ik[0].joints)==0 && profile.multi_ik[0].effectors[0].use_pole && profile.multi_ik[0].effectors[0].pole=={0,0,1} && profile.multi_ik[0].effectors[0].reach.max_stretch==.2 && profile.multi_ik[0].settings.iterations==32 && profile.twist[0].amount_count==2 && profile.twist[0].amounts[1]==.75);asset.asset_close(&file)
    result=authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s","table":"Twist"}}`,identity));testing.expect_value(t,result.code,0)
    text:=api.json_compact(string(serial.writer_bytes(&f.out)));testing.expect(t,!strings.contains(text,"amount_count") && strings.contains(text,`"value":0.75`) && !strings.contains(text,"limit_count"))
    schema:=authoring_result_schema(Asset_Inspect_Result,context.temp_allocator);testing.expect(t,!strings.contains(schema,"amount_count") && !strings.contains(schema,"effector_count") && !strings.contains(schema,"limit_count"))
}
