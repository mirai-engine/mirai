package animation_editor

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

@(private)
Action_Inspect_Allocator :: struct {owner:runtime.Allocator,size:int,failed:bool}

@(private)
action_inspect_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Action_Inspect_Allocator)(data)
    if (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) && size==state.size && !state.failed {state.failed=true;return nil,.Out_Of_Memory}
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
action_authoring_resolves_named_sections_defaults_and_preserves_assets_on_failure :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"actions") {return};defer authoring_test_destroy(f)
    source:=program_test_source(f,t);identity:=authoring_test_id_text(source);inspect:=Asset_Inspect_Params{limit=32}
    // The spans of the clip: start and end are the sections of the action, hit a window of it.
    spans:=[?]asset.Animation_Marker_Desc{{time=0,name="start",duration=.2},{time=.4,name="end",duration=.4},{time=.1,name="hit",duration=.2},{time=.3,name="impact"}}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/source.anim",f.root),&f.assets.types,{id=source,clips={{name="idle"},{name="walk",tracks={{target="hip",property=.Position,keys={{time=0},{time=1,value={1,0,0,0}}}}},markers=spans[:]}}}),asset.Error.None);host.assets_scan(&f.assets)
    authoring_test_register(f,t,"set",Action_Write_Params,authoring_action_set,action_write_defaults());authoring_test_register(f,t,"inspect",Asset_Inspect_Params,asset_inspect,&inspect)
    definition:=fmt.tprintf(`"animation":"%s","actions":[{{"name":"attack","clip":"walk"}}],"sections":[{{"action":"attack","name":"start","next":"end"}},{{"action":"attack","name":"end"}}]`,identity)
    result:=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"hero.character",%s}}`,definition));if !testing.expect(t,result.code==0,fmt.tprintf("%s: %s",result.message,definition)) {return}
    asset_id:=authoring_test_id(f,"hero.character");asset_text:=authoring_test_id_text(asset_id);revision:=authoring_test_revision(f,"hero.character")
    file:asset.Asset;testing.expect_value(t,authoring_test_load(f,"hero.character",&file),asset.Error.None)
    set,error:=anim.character_view(&file,&f.assets.types);profile:=set.actions;testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,profile.actions[0].weight==1 && profile.actions[0].speed==1 && profile.actions[0].exit==1 && profile.actions[0].layer=={} && profile.sections[0].next==1 && profile.sections[1].next== -1);asset.asset_close(&file)
    result=authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s"}}`,asset_text));testing.expect_value(t,result.code,0)
    text:=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(text,`"next": "end"`) && !strings.contains(text,"section_count"))
    {
        failure:=Action_Inspect_Allocator{owner=context.temp_allocator,size=2*size_of(Action_Section_Params)}
        params:=Asset_Inspect_Params{asset=asset_id,limit=32}
        call:=api.Call{method=api.method_find(&f.server,"inspect"),params=&params,out=&f.out,allocator={action_inspect_allocator,&failure}}
        serial.writer_reset(&f.out)
        asset_inspect(&f.session,&call)
        testing.expect(t,failure.failed && call.failed && call.error.code==api.SERVER_ERROR)
        testing.expect(t,strings.contains(call.error.data,"Out_Of_Memory"))
        testing.expect_value(t,authoring_test_revision(f,"hero.character"),revision)
    }
    bad,_:=strings.replace_all(definition,`"next":"end"`,`"next":"missing"`,context.temp_allocator)
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"hero.character",%s}}`,bad));testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"sections[0].next"))
    testing.expect_value(t,authoring_test_revision(f,"hero.character"),revision)
    // A section is a span of its clip, not a point.
    bad=fmt.tprintf(`"animation":"%s","actions":[{{"name":"attack","clip":"walk"}}],"sections":[{{"action":"attack","name":"impact"}}]`,identity)
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"hero.character",%s}}`,bad));testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"sections[0].name") && strings.contains(result.data,"Missing_Span"))
    testing.expect_value(t,authoring_test_revision(f,"hero.character"),revision)
    bad=fmt.tprintf(`"animation":"%s","actions":[{{"name":"attack","clip":"walk"}},{{"name":"second","clip":"walk","layer":"Arm"}}]`,identity)
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"hero.character",%s}}`,bad));testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"actions[1].layer") && strings.contains(result.data,"Missing_Reference"))
    bad=fmt.tprintf(`"animation":"%s","layers":[{{"name":"Lean","mode":"Additive"}}],"actions":[{{"name":"attack","clip":"walk","layer":"Lean","root_motion":"Extract"}}]`,identity)
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"hero.character",%s}}`,bad));testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"UnsupportedPolicy"))
    bad=fmt.tprintf(`"animation":"%s","layers":[{{"name":"Arm","clip":"missing"}}]`,identity)
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"hero.character",%s}}`,bad));testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"layers[0].clip"))
    testing.expect_value(t,authoring_test_revision(f,"hero.character"),revision)
    // A body moves by root motion, and its vertical asks for a move.
    for c in ([2][2]string{{`"body_move":"Additive"`,"actions[0].body_move"},{`"body_vertical":true`,"actions[0].body_vertical"}}) {
        bad=fmt.tprintf(`"animation":"%s","actions":[{{"name":"attack","clip":"walk",%s}}]`,identity,c[0])
        result=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"hero.character",%s}}`,bad));testing.expectf(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,c[1]),"%s: %s",c[0],result.data)
        testing.expect_value(t,authoring_test_revision(f,"hero.character"),revision)
    }
    schema:=authoring_result_schema(Asset_Inspect_Result,type_info_of(Asset_Inspect_Result),context.temp_allocator);testing.expect(t,strings.contains(schema,`"root_motion"`) && strings.contains(schema,`"cancel"`) && !strings.contains(schema,"section_count"))
    requested:=request_defaults();authoring_test_register(f,t,"request",Request_Params,request,requested)
    result=authoring_test_execute(f,"request",`{"entity":"0000000000000001","actions":[{"name":"attack"}]}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"actions"`) && strings.contains(result.data,`"code":"Runtime_Required"`))
}
