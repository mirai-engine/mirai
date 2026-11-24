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

@(test)
pose_corrective_authoring_roundtrips_inspects_and_rejects_invalid_rows :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"correctives") {return};defer authoring_test_destroy(f)
    defaults:=Profile_Set_Params{};profile_constraints_defaults(&defaults)
    authoring_test_register(f,t,"set",Profile_Set_Params,authoring_profile_set,&defaults)
    inspect:=Asset_Inspect_Params{limit=16};authoring_test_register(f,t,"inspect",Asset_Inspect_Params,asset_inspect,&inspect)

    // Author Twist, Cone, and Swing correctives through animation.modifier.set.
    writes:=[]string{
        `{"path":"hero.character","table":"Corrective","corrective":{"name":"dyn_kneepad_l","driver":{"path":"calf_l"},"bone":{"path":"dyn_kneepad_l"},"mode":"Twist","axis":[1,0,0],"min_angle":0,"max_angle":1.57,"position":[0,0,-0.04]}}`,
        `{"path":"hero.character","table":"Corrective","corrective":{"name":"pelvis_side_l","driver":{"path":"thigh_l"},"bone":{"path":"pelvis_side_l"},"mode":"Cone","axis":[0,-1,0],"cone_axis":[0,0,-1],"min_angle":0,"max_angle":1.57,"smooth":true,"position":[0.03,0.02,0]}}`,
        `{"path":"hero.character","table":"Corrective","corrective":{"name":"clavPushJnt_l","driver":{"path":"upperarm_l"},"bone":{"path":"clavPushJnt_l"},"mode":"Swing","axis":[1,0,0],"min_angle":0.1,"max_angle":1.4,"scale":[1.1,1,1]}}`,
    }
    for call in writes {
        res:=authoring_test_execute(f,"set",call)
        if !testing.expectf(t,res.code==0,"%s: %s",call,res.message) {return}
    }
    identity:=authoring_test_id_text(authoring_test_id(f,"hero.character"))
    file:asset.Asset
    if !testing.expect_value(t,authoring_test_load(f,"hero.character",&file),asset.Error.None) {return}
    set,error:=anim.character_view(&file,&f.assets.types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect_value(t,len(set.pose.correctives),3)
    testing.expect(t,set.pose.correctives[0].mode==.Twist && set.pose.correctives[0].scale=={1,1,1} && set.pose.correctives[0].rotation==1)
    testing.expect(t,set.pose.correctives[1].mode==.Cone && set.pose.correctives[1].smooth && set.pose.correctives[1].cone_axis=={0,0,-1})
    testing.expect(t,set.pose.correctives[2].mode==.Swing && set.pose.correctives[2].scale.x==1.1)
    asset.asset_close(&file)

    // Inspect Corrective table via animation.asset.inspect.
    res:=authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s","table":"Corrective"}}`,identity))
    testing.expect_value(t,res.code,0)
    text:=api.json_compact(string(serial.writer_bytes(&f.out)))
    testing.expect(t,strings.contains(text,`"Corrective":3`) && strings.contains(text,`"pelvis_side_l"`) && strings.contains(text,`"dyn_kneepad_l"`))

    // Table-driven invalid edits fail without bumping revision.
    revision:=authoring_test_revision(f,"hero.character")
    invalids:=[]string{
        `{"path":"hero.character","table":"Corrective","corrective":{"name":"self","driver":{"path":"thigh_l"},"bone":{"path":"thigh_l"}}}`,
        `{"path":"hero.character","table":"Corrective","corrective":{"name":"cycle","driver":{"path":"pelvis_side_l"},"bone":{"path":"thigh_l"}}}`,
        `{"path":"hero.character","table":"Corrective","corrective":{"name":"bad_range","driver":{"path":"a"},"bone":{"path":"b"},"min_angle":1.2,"max_angle":0.5}}`,
        `{"path":"hero.character","table":"Corrective","corrective":{"name":"bad_axis","driver":{"path":"a"},"bone":{"path":"b"},"axis":[0,0,0]}}`,
        `{"path":"hero.character","table":"Corrective","corrective":{"name":"bad_scale","driver":{"path":"a"},"bone":{"path":"b"},"scale":[0,1,1]}}`,
    }
    for call in invalids {
        bad:=authoring_test_execute(f,"set",call)
        testing.expectf(t,bad.code==api.INVALID_PARAMS,"%s: got code %d",call,bad.code)
        testing.expect_value(t,authoring_test_revision(f,"hero.character"),revision)
    }

    // Remove by name round-trips cleanly.
    res=authoring_test_execute(f,"set",`{"path":"hero.character","table":"Corrective","corrective":{"name":"clavPushJnt_l","driver":{"path":"upperarm_l"},"bone":{"path":"clavPushJnt_l"}},"remove":true}`)
    testing.expect_value(t,res.code,0)
    if !testing.expect_value(t,authoring_test_load(f,"hero.character",&file),asset.Error.None) {return}
    set,error=anim.character_view(&file,&f.assets.types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect_value(t,len(set.pose.correctives),2)
    asset.asset_close(&file)
}
