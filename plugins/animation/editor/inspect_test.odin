package animation_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

result_shape_mismatch :: proc($T:typeid,text:string) -> string {return api.result_mismatch(T,text,type_info_of(T))}

@(test)
inspectors_read_every_definition_kind_and_the_parts_of_an_instance :: proc(t:^testing.T) {
    f:=new(Pose_Bake_Test);defer free(f);if !pose_bake_test_init(f,t,"inspect") {return};defer pose_bake_test_destroy(f)
    library:=setup_test_character(f,t)
    a:=&f.authoring
    setup_defaults:=Setup_Params{want=SETUP_ALL};asset_defaults:=Asset_Inspect_Params{limit=128};instance_defaults:=Instance_Inspect_Params{limit=128}
    authoring_test_register(a,t,"setup",Setup_Params,setup,&setup_defaults)
    authoring_test_register(a,t,"asset",Asset_Inspect_Params,asset_inspect,&asset_defaults)
    authoring_test_register(a,t,"instance",Instance_Inspect_Params,instance_inspect,&instance_defaults)
    preview_defaults:=new(Preview_Params,context.temp_allocator);preview_defaults.dt,preview_defaults.limit,preview_defaults.trace_limit=1.0/60,256,16;request_rows_defaults(preview_defaults)
    authoring_test_register(a,t,"preview",Preview_Params,preview,preview_defaults)
    test_locomotion_modes(&f.info)
    result:=authoring_test_execute(a,"setup",fmt.tprintf(`{{"id":"11","library":"%s","folder":"c"}}`,authoring_test_id_text(library)))
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    testing.expect_value(t,result_shape_mismatch(Setup_Result,string(serial_bytes(a))),"")
    expect :: proc(t:^testing.T,a:^Authoring_Test,request:string,needles:..string,loc:=#caller_location) {
        result:=authoring_test_execute(a,"asset",request)
        if !testing.expectf(t,result.code==0,"%s: %s %s",request,result.message,result.data,loc=loc) {return}
        text:=string(serial_bytes(a))
        for needle in needles {testing.expectf(t,strings.contains(text,needle),"%s lacks %s",request,needle,loc=loc)}
        testing.expect_value(t,result_shape_mismatch(Asset_Inspect_Result,text),"",loc=loc)
    }
    id :: proc(a:^Authoring_Test,path:string) -> string {return authoring_test_id_text(authoring_test_id(a,path))}
    expect(t,a,fmt.tprintf(`{{"asset":"%s","clip":"Walk"}}`,authoring_test_id_text(library)),`"path"`,`"Walk"`)
    expect(t,a,fmt.tprintf(`{{"asset":"%s","clip":"Walk","section":"Track","target":"root","property":"Position"}}`,authoring_test_id_text(library)),`"keys"`)
    expect(t,a,fmt.tprintf(`{{"asset":"%s","section":"Body"}}`,id(a,"figure.skeleton")),`"part":"Head"`,`"stored":true`)
    expect(t,a,fmt.tprintf(`{{"asset":"%s"}}`,id(a,"figure.skeleton")),`"bones_total"`)
    expect(t,a,fmt.tprintf(`{{"asset":"%s","table":"Look"}}`,id(a,"c/figure.pose")),`"look"`)
    expect(t,a,fmt.tprintf(`{{"asset":"%s"}}`,id(a,"c/figure.match")),`"match_clips":[{"clip":"Idle"`,`"modes":["WALKING"]`,`"databases":[]`)
    expect(t,a,fmt.tprintf(`{{"asset":"%s"}}`,id(a,"c/figure.motion")),`"pose"`)
    expect(t,a,fmt.tprintf(`{{"asset":"%s"}}`,id(a,"c/figure.action")),`"Wave Arm_R"`)
    result=authoring_test_execute(a,"asset",fmt.tprintf(`{{"asset":"%s"}}`,id(a,"figure.mesh")))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Invalid_Kind"))
    result=authoring_test_execute(a,"instance",`{"id":"11"}`)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    text:=string(serial_bytes(a))
    testing.expectf(t,strings.contains(text,`"rig":{"clips"`) && strings.contains(text,`"match":{"available":false,"code":"Not_Running"`) && strings.contains(text,`"modifiers":{`),"instance %s",text)
    testing.expect_value(t,result_shape_mismatch(Instance_Inspect_Result,text),"")
    result=authoring_test_execute(a,"instance",`{"id":"11","diagnostics":true}`)
    testing.expect(t,result.code==0)
    testing.expect_value(t,result_shape_mismatch(Instance_Inspect_Result,string(serial_bytes(a))),"")
    result=authoring_test_execute(a,"instance",`{"id":"11","parts":["Match"]}`)
    testing.expect(t,result.code==0 && !strings.contains(string(serial_bytes(a)),`"rig"`))
    // A preview plays the .match on a copy: it builds the database of the skeleton, and a play
    // forces its clip until matching takes over.
    result=authoring_test_execute(a,"preview",`{"id":"11","ticks":2,"plays":[{"clip":"Walk","mode":"Walking","tick":1}]}`)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    text=string(serial_bytes(a))
    testing.expectf(t,strings.contains(text,`"match":{"available": true`) && strings.contains(text,`"clip": "Walk", "mode": "WALKING", "forced": true`),"preview %s",text)
    testing.expect_value(t,result_shape_mismatch(Preview_Result,text),"")
    expect(t,a,fmt.tprintf(`{{"asset":"%s"}}`,id(a,"c/figure.match")),`"databases":[{"rows": `,`"error": "None"`)

    // The Pose part: names that do not exist fail the call; a rig that has not posed says so.
    result=authoring_test_execute(a,"instance",`{"id":"11","parts":["Pose"],"names":["@hand_r","baton"]}`)
    testing.expect(t,result.code==0 && strings.contains(string(serial_bytes(a)),`"pose":{"available":false,"code":"Not_Posed"`))
    result=authoring_test_execute(a,"instance",`{"id":"11","parts":["Pose"],"names":["@hand_r","batton"]}`)
    testing.expectf(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Missing_Name") && strings.contains(result.data,"batton") && strings.contains(result.data,"animation.asset.inspect"),"%s %s",result.message,result.data)
    result=authoring_test_execute(a,"instance",`{"id":"11","parts":["Pose"]}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Missing_Names"))
    // It poses with the entity at x=10 and every bone at rest: the hand is where the skeleton has it,
    // and the world adds where the entity stands.
    bones:=body_test_figure()
    state:=anim.Playing{entity=f.rig,skeleton=base.Asset_Id{840,2},pose_ready=true}
    resize(&state.parents,len(bones)+1);resize(&state.local,len(bones)+1)
    state.parents[0],state.local[0]=-1,mm.TRANSFORM_IDENTITY
    for bone,i in bones {state.parents[i+1]=bone.parent+1;state.local[i+1]={position=bone.translation,rotation=1,scale={1,1,1}}}
    append(&f.world.playback.states,state)
    row:=core.entity_index(f.rig);resize(&f.world.playback.rows,row+1);f.world.playback.rows[row]=1
    core.add(&f.world.transforms,f.rig,core.from_math(mm.Transform{position={10,0,0},rotation=1,scale={1,1,1}}));pose_bake_test_settle(&f.world,nil,nil)
    result=authoring_test_execute(a,"instance",`{"id":"11","parts":["Pose"],"names":["@hand_r","baton","root/pelvis"]}`)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    text=string(serial_bytes(a))
    for needle in ([]string{`"name": "@hand_r", "kind": "Bone"`,`"world": {"position": [10.7, 1.45, 0]`,`"entity": {"position": [0.7, 1.45, 0]`,`"name": "baton", "kind": "Socket"`,`"entity": {"position": [0, 1, 0]`}) {testing.expectf(t,strings.contains(text,needle),"pose lacks %s in %s",needle,text)}
    testing.expect_value(t,result_shape_mismatch(Instance_Inspect_Result,text),"")
}

@(test)
inspecting_a_rig_the_game_made_names_it_by_its_handle_and_reads_the_last_search_of_its_matching :: proc(t:^testing.T) {
    f:=new(Pose_Bake_Test);defer free(f);if !pose_bake_test_init(f,t,"inspect-handle") {return};defer pose_bake_test_destroy(f)
    library:=setup_test_character(f,t)
    a:=&f.authoring
    setup_defaults:=Setup_Params{want=SETUP_ALL};instance_defaults:=Instance_Inspect_Params{limit=128}
    authoring_test_register(a,t,"setup",Setup_Params,setup,&setup_defaults)
    authoring_test_register(a,t,"instance",Instance_Inspect_Params,instance_inspect,&instance_defaults)
    test_locomotion_modes(&f.info)
    result:=authoring_test_execute(a,"setup",fmt.tprintf(`{{"id":"11","library":"%s","folder":"c"}}`,authoring_test_id_text(library)))
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    // Without its id the rig is as one the game made: only its handle names it.
    core.remove(&f.world.ids,f.rig);pose_bake_test_settle(&f.world,nil,nil)
    // As play.inspect gives it.
    handle:=fmt.tprintf("0x%016x",u64(f.rig))
    Refusal :: struct {request,code,fix:string}
    refused :: proc(t:^testing.T,a:^Authoring_Test,cases:[]Refusal,loc:=#caller_location) {
        for c in cases {
            result:=authoring_test_execute(a,"instance",c.request)
            testing.expectf(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,c.code) && strings.contains(result.data,c.fix),"%s: %s %s",c.request,result.message,result.data,loc=loc)
        }
    }
    refused(t,a,{{fmt.tprintf(`{{"entity":"%s"}}`,handle),"Not_Playing","scene.inspect"},{`{"id":"11"}`,"Missing_Entity","scene.inspect"},{`{}`,"Missing_Entity","play.inspect"}})
    a.session.mode=.Play
    world:=core.world_ref(&f.world,&f.info)
    for _ in 0..<6 {
        anim.match_goal(&f.world.requests,{rig=f.rig,mode=1,velocity={0,0,-1},desired={0,0,-1},facing={0,0,-1},acceleration=10,braking=10})
        testing.expect(t,anim.animation_evaluate(world,&a.app,1.0/60))
    }
    refused(t,a,{{`{"id":"11"}`,"Missing_Entity","handle in entity"},{`{"entity":"0000000000000001"}`,"Missing_Entity","play.inspect"},{`{"entity":"rig"}`,"Invalid_Handle","play.inspect"},{fmt.tprintf(`{{"id":"11","entity":"%s"}}`,handle),"Ambiguous_Entity","play.inspect"}})
    result=authoring_test_execute(a,"instance",fmt.tprintf(`{{"entity":"%s","parts":["Rig","Match"]}}`,handle))
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    text:=string(serial_bytes(a))
    for needle in ([]string{fmt.tprintf(`"entity":"%s"`,handle),`"rig":{"clips"`,`"match":{"available": true`,`"ranges":[{"clip":"Idle"`,`"modes":["WALKING"]`,`"travel":[`,`"search":{"search":1,"mode":"WALKING","entry":false,"candidates":[{"range": `,`"costs": {"foot_position": `,`"reason": "None"`,`"reason": "Stationary"`}) {
        testing.expectf(t,strings.contains(text,needle),"inspect lacks %s in %s",needle,text)
    }
    testing.expect_value(t,result_shape_mismatch(Instance_Inspect_Result,text),"")
}
