package animation_editor

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

@(private)
program_test_source :: proc(f:^Authoring_Test,t:^testing.T) -> base.Asset_Id {
    id:=base.Asset_Id{16,32}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/source.anim",f.root),&f.assets.types,{id=id,clips={{name="idle"},{name="walk"}}}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    return id
}

@(test)
blend_space_authoring_prepares_samples_preserves_identity_and_rejects_partial_edits :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"program-blend") {return};defer authoring_test_destroy(f)
    source:=authoring_test_id_text(program_test_source(f,t))
    defaults:=program_blend_defaults()
    inspect:=Authoring_Inspect_Params{offset=1,limit=1}
    authoring_test_register(f,t,"set",Blend_Write_Params,program_blend_set,defaults)
    authoring_test_register(f,t,"inspect",Authoring_Inspect_Params,program_blend_inspect,&inspect)
    authoring_test_register(f,t,"sample",Blend_Sample_Params,program_blend_sample)
    definition:=fmt.tprintf(`"info":{{"animation":"%s","dimension":"One","x":{{"name":"speed","min":0,"max":2}}}},"samples":[{{"position":[0,0],"clip":"idle"}},{{"position":[2,0],"clip":"walk"}}]`,source)
    request:=fmt.tprintf(`{{"path":"locomotion.blend",%s}}`,definition)
    created:=authoring_test_execute(f,"set",request)
    if !testing.expect(t,created.code==0,fmt.tprintf("%s: %s",created.message,request)) {return}
    id:=authoring_test_id(f,"locomotion.blend");identity:=authoring_test_id_text(id)
    neither:=authoring_test_execute(f,"set",fmt.tprintf(`{{%s}}`,definition))
    testing.expect_value(t,neither.code,api.INVALID_PARAMS)
    existing:=authoring_test_execute(f,"set",request)
    testing.expect(t,existing.code==0 && strings.contains(api.json_compact(string(serial.writer_bytes(&f.out))),`"replaced":true`) && authoring_test_id(f,"locomotion.blend")==id,existing.message)
    file:asset.Asset
    testing.expect_value(t,authoring_test_load(f,"locomotion.blend",&file),asset.Error.None)
    profile,error:=anim.blend_space_view(&file,&f.assets.types)
    testing.expect_value(t,error,asset.Error.None);testing.expect_value(t,len(profile.segments),1);testing.expect_value(t,profile.samples[1].speed,f32(1))
    asset.asset_close(&file)
    testing.expect_value(t,authoring_test_execute(f,"sample",fmt.tprintf(`{{"asset":"%s","position":[1,0]}}`,identity)).code,0)
    text:=api.json_compact(string(serial.writer_bytes(&f.out)));testing.expect(t,strings.contains(text,`"weight":0.5`) && strings.contains(text,`"clip":"idle"`) && strings.contains(text,`"clip":"walk"`))
    testing.expect_value(t,authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s"}}`,identity)).code,0)
    text=api.json_compact(string(serial.writer_bytes(&f.out)));testing.expect(t,strings.contains(text,`"samples_total":2`) && strings.contains(text,`"index":1`) && !strings.contains(text,`"index":0`))
    revision:=authoring_test_revision(f,"locomotion.blend")
    bad,_:=strings.replace_all(definition,`"position":[2,0]`,`"position":[0,0]`,context.temp_allocator)
    testing.expect_value(t,authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"locomotion.blend",%s}}`,bad)).code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_revision(f,"locomotion.blend"),revision)
    bad,_=strings.replace_all(definition,`"clip":"walk"`,`"clip":"missing"`,context.temp_allocator)
    testing.expect_value(t,authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"locomotion.blend",%s}}`,bad)).code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_revision(f,"locomotion.blend"),revision)
    changed,_:=strings.replace_all(definition,`"position":[2,0]`,`"position":[1,0]`,context.temp_allocator)
    testing.expect_value(t,authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"locomotion.blend",%s}}`,changed)).code,0)
    testing.expect_value(t,authoring_test_id(f,"locomotion.blend"),id)
    testing.expect(t,authoring_test_revision(f,"locomotion.blend")!=revision)
    f.session.mode=.Play
    testing.expect_value(t,authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"locomotion.blend",%s}}`,definition)).code,0)
}

@(test)
two_dimensional_blend_authoring_bakes_triangles_and_rejects_collinear_replacements :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"program-blend-2d") {return};defer authoring_test_destroy(f)
    source:=authoring_test_id_text(program_test_source(f,t))
    defaults:=program_blend_defaults();inspect:=Authoring_Inspect_Params{limit=16}
    authoring_test_register(f,t,"set",Blend_Write_Params,program_blend_set,defaults)
    authoring_test_register(f,t,"inspect",Authoring_Inspect_Params,program_blend_inspect,&inspect)
    authoring_test_register(f,t,"sample",Blend_Sample_Params,program_blend_sample)
    definition:=fmt.tprintf(`"info":{{"animation":"%s","dimension":"Two","x":{{"name":"direction","min":0,"max":1}},"y":{{"name":"speed","min":0,"max":1}}}},"samples":[{{"position":[0,0],"clip":"idle"}},{{"position":[1,0],"clip":"walk"}},{{"position":[0,1],"clip":"walk"}}]`,source)
    result:=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"locomotion.blend",%s}}`,definition))
    if !testing.expect(t,result.code==0,result.message) {return}
    id:=authoring_test_id(f,"locomotion.blend");identity:=authoring_test_id_text(id)
    revision:=authoring_test_revision(f,"locomotion.blend")
    testing.expect_value(t,authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s"}}`,identity)).code,0)
    text:=api.json_compact(string(serial.writer_bytes(&f.out)));testing.expect(t,strings.contains(text,`"triangles_total":1`) && strings.contains(text,"direction") && strings.contains(text,"speed"))
    testing.expect_value(t,authoring_test_execute(f,"sample",fmt.tprintf(`{{"asset":"%s","position":[0.25,0.25]}}`,identity)).code,0)
    text=api.json_compact(string(serial.writer_bytes(&f.out)));testing.expect(t,strings.count(text,`"index":`)==3 && strings.contains(text,`"weight":0.5`) && strings.count(text,`"weight":0.25`)==2)
    collinear,_:=strings.replace_all(definition,`"position":[0,1]`,`"position":[0.5,0]`,context.temp_allocator)
    testing.expect_value(t,authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"locomotion.blend",%s}}`,collinear)).code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_revision(f,"locomotion.blend"),revision)
}

Program_Test_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    animations:core.Table(anim.Animation),
    modifiers:core.Table(anim.Pose_Modifiers),
    animation_requests:anim.Animation_Requests,
    modifier_requests:anim.Modifier_Requests,
    modifier_runtime:anim.Modifier_Runtime,
}
// The World_Info of a document and of the World its Play runs, and both made.
@(private="file")
program_test_worlds :: proc(t:^testing.T,info:^core.World_Info,document,play:^Program_Test_World) -> bool {
    info^=core.test_info(t,Program_Test_World,anim.test_types) or_return
    return testing.expect(t,core.world_init(info,.World,document,context.allocator) && core.world_init(info,.World,play,context.allocator))
}
@(private="file")
program_test_worlds_destroy :: proc(info:^core.World_Info,document,play:^Program_Test_World) {
    if info.sizes[.World]>0 {core.world_destroy(info,.World,document);core.world_destroy(info,.World,play)}
    core.test_info_destroy(info)
}
@(private)
program_test_register_result :: proc(f:^Authoring_Test,t:^testing.T,name:string,$P,$R:typeid,run:editor.Api_Handler,defaults:^P=nil) {
    entry:=new(Authoring_Test_Entry,context.temp_allocator);entry^={&f.session,run}
    testing.expect_value(t,api.method_register(&f.server,{name=name,params=type_info_of(P),result=type_info_of(R),defaults=defaults,user=entry,handler=proc(call:^api.Call) {entry:=(^Authoring_Test_Entry)(call.user);entry.run(entry.session,call)}}),api.Register_Error.None)
}

@(test)
program_runtime_api_sets_named_parameters_and_keeps_actions_and_modifier_controls_out_of_edit :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"program-runtime") {return};defer authoring_test_destroy(f)
    source:=program_test_source(f,t)
    set_id,pose_id,match_id:=base.Asset_Id{17,33},base.Asset_Id{18,34},base.Asset_Id{19,36}
    // Its action set: a layer Arm whose weight is a parameter, a wave in it and a vault over the whole body.
    layer:=anim.STACK_LAYER_DEFAULT;base.text_set(layer.name[:],"Arm");base.text_set(layer.clip[:],"walk");layer.weight=0
    definitions:=[2]anim.Action_Definition{anim.ACTION_DEFINITION_DEFAULT,anim.ACTION_DEFINITION_DEFAULT}
    base.text_set(definitions[0].name[:],"Wave");base.text_set(definitions[0].clip[:],"walk");base.text_set(definitions[0].layer[:],"Arm")
    base.text_set(definitions[1].name[:],"Vault");base.text_set(definitions[1].clip[:],"walk")
    testing.expect_value(t,anim.action_profile_save(fmt.tprintf("%s/runtime.action",f.root),&f.assets.types,set_id,{info={animation=source},layers={layer},actions=definitions[:]}),asset.Error.None)
    clips:=[1]anim.Match_Source{{modes=1<<1,loop=true}};base.text_set(clips[0].clip[:],"idle")
    info:=anim.MATCH_INFO_DEFAULT;info.animation=source
    testing.expect_value(t,anim.match_save(fmt.tprintf("%s/runtime.match",f.root),&f.assets.types,match_id,{info=info,clips=clips[:]}),asset.Error.None)
    look:=anim.LOOK_CONSTRAINT_DEFAULT;look.bone=anim.bone_ref("head")
    testing.expect_value(t,anim.pose_profile_save(fmt.tprintf("%s/runtime.pose",f.root),&f.assets.types,pose_id,{look={look}}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    document,play:Program_Test_World;world_info:core.World_Info;defer program_test_worlds_destroy(&world_info,&document,&play)
    if !program_test_worlds(t,&world_info,&document,&play) {return}
    test_locomotion_modes(&world_info)
    for world in ([2]^Program_Test_World{&document,&play}) {
        entity:=core.create(&world.entities);core.add(&world.ids,entity,{value=17})
        value:=anim.ANIMATION_DEFAULT;value.asset,value.actions=match_id,set_id;core.add(&world.animations,entity,value)
        modifier:=anim.POSE_MODIFIERS_DEFAULT;modifier.profile=pose_id;core.add(&world.modifiers,entity,modifier)
        core.settle(&world_info,world,nil)
    }
    f.session.info,f.session.edit_world,f.session.mode=&world_info,&document,.Play;f.session.runs[0]={world=&play}
    requested:=request_defaults();authoring_test_register(f,t,"request",Request_Params,request,requested)
    inspect:=Modifier_Inspect_Params{limit=128};authoring_test_register(f,t,"inspect",Modifier_Inspect_Params,program_modifier_inspect,&inspect)
    // A parameter is the weight of a layer of its set, asked of the running world.
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","parameters":[{"name":"Arm","value":0.6}]}`).code,0)
    testing.expect(t,strings.contains(api.json_compact(string(serial.writer_bytes(&f.out))),`"kind":"Parameter","name":"Arm"`))
    if testing.expect_value(t,len(play.animation_requests.values.items),1) {
        queued:=play.animation_requests.values.items[0]
        testing.expect(t,queued.name==base.name_hash("Arm") && queued.value==.6)
    }
    for bad in ([4]string{`{"index":0,"value":0.8}`,`{"name":"","value":0.8}`,`{"name":"Arm","value":2}`,`{"name":"speed","value":0.5}`}) {
        result:=authoring_test_execute(f,"request",fmt.tprintf(`{{"entity":"0000000000000011","parameters":[%s]}}`,bad))
        testing.expectf(t,result.code==api.INVALID_PARAMS,"%s: %s",bad,result.data)
    }
    unknown:=authoring_test_execute(f,"request",`{"entity":"0000000000000011","parameters":[{"name":"speed","value":0.5}]}`)
    testing.expect(t,strings.contains(unknown.data,"Unknown_Reference") && strings.contains(unknown.data,"Parameters: Arm"),unknown.data)
    testing.expect_value(t,len(play.animation_requests.values.items),1);testing.expect_value(t,len(document.animation_requests.values.items),0)
    // An action is played and stopped by its name, in its layer or over the whole body.
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","actions":[{"name":"Vault"},{"name":"Wave"}]}`).code,0)
    testing.expect(t,strings.contains(api.json_compact(string(serial.writer_bytes(&f.out))),`"kind":"Play","name":"Vault"`))
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","actions":[{"name":"Vault","stop":true}]}`).code,0)
    if testing.expect_value(t,len(play.animation_requests.plays.items),3) {
        plays:=play.animation_requests.plays.items
        testing.expect(t,base.text_get(plays[0].action[:])=="Vault" && !plays[0].stop && base.text_get(plays[1].action[:])=="Wave" && plays[2].stop && base.text_get(plays[2].action[:])=="Vault")
    }
    for bad in ([3]string{`{"name":"Jump"}`,`{"name":"Vault","section":"missing"}`,`{"name":"Vault","tick":1}`}) {
        result:=authoring_test_execute(f,"request",fmt.tprintf(`{{"entity":"0000000000000011","actions":[%s]}}`,bad))
        testing.expectf(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"actions[0].`) && strings.contains(result.data,`"fix":`),"%s: %s",bad,result.data)
    }
    testing.expect_value(t,len(play.animation_requests.plays.items),3)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","controls":[{"kind":"Look","slot":1,"weight":0.3}]}`).code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","controls":[{"kind":"Look","name":"head","weight":0.3,"fade":0.2}]}`).code,0)
    testing.expect_value(t,len(play.modifier_requests.controls.items),1);testing.expect_value(t,len(document.modifier_requests.controls.items),0)
    testing.expect_value(t,play.modifier_requests.controls.items[0].fade,f32(.2))
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"entity":"0000000000000011"}`).code,0)
    text:=api.json_compact(string(serial.writer_bytes(&f.out)));testing.expect(t,strings.contains(text,`"kind":"Look"`) && strings.contains(text,`"name":"head"`) && !strings.contains(text,`"slot"`) && !strings.contains(text,`"diagnostic"`))
    // Edit changes the document: what only a running world takes is refused there.
    f.session.mode=.Edit
    for runtime in ([3]string{`"actions":[{"name":"Vault"}]`,`"parameters":[{"name":"Arm","value":0.5}]`,`"controls":[{"kind":"Look","name":"head"}]`}) {
        result:=authoring_test_execute(f,"request",fmt.tprintf(`{{"entity":"0000000000000011",%s}}`,runtime))
        testing.expectf(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Runtime_Required"),"%s: %s",runtime,result.data)
    }
    testing.expect_value(t,len(document.animation_requests.plays.items),0);testing.expect_value(t,len(document.animation_requests.values.items),0);testing.expect_value(t,len(document.modifier_requests.controls.items),0)
    temporary:Preview_Params;copy(temporary.entity[:],"0000000000000011")
    base.text_set(temporary.parameters[0].name[:],"Arm");temporary.parameters[0].value=.4
    temporary.controls[0]={kind=.Look,weight=.2,enabled=false};base.text_set(temporary.controls[0].name[:],"head")
    preview_call:=api.Call{raw=`{"parameters":[{"name":"Arm","value":0.4}],"controls":[{"kind":"Look","name":"head","weight":0.2,"enabled":false}]}`,allocator=context.temp_allocator}
    testing.expect(t,request_apply(&f.session,&preview_call,core.world_ref(&play,&world_info),play.ids.entities[0],&temporary,0,nil))
    if testing.expect_value(t,len(play.animation_requests.values.items),2) {testing.expect_value(t,play.animation_requests.values.items[1].value,f32(.4))}
    testing.expect_value(t,len(play.modifier_requests.controls.items),2)
    testing.expect_value(t,len(document.animation_requests.values.items),0);testing.expect_value(t,len(document.modifier_requests.controls.items),0)
}

@(test)
modifier_goal_api_resolves_targets_in_the_running_world_accepts_the_origin_and_keeps_contact_strength_separate :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"modifier-goal") {return};defer authoring_test_destroy(f)
    pose_id:=base.Asset_Id{19,35}
    ik:=anim.IK_CONSTRAINT_DEFAULT;ik.root,ik.joint,ik.end=anim.bone_ref("hip"),anim.bone_ref("knee"),anim.bone_ref("foot")
    look:=anim.LOOK_CONSTRAINT_DEFAULT;look.bone=anim.bone_ref("head");look.weight=.4
    other:=look;other.bone=anim.bone_ref("eyes")
    contact:=anim.FOOT_CONTACT_CONSTRAINT_DEFAULT;contact.root,contact.joint,contact.end,contact.pelvis=ik.root,ik.joint,ik.end,ik.root
    testing.expect_value(t,anim.pose_profile_save(fmt.tprintf("%s/goals.pose",f.root),&f.assets.types,pose_id,{ik={ik},look={other,look},contacts={contact}}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    document,play:Program_Test_World;info:core.World_Info;defer program_test_worlds_destroy(&info,&document,&play)
    if !program_test_worlds(t,&info,&document,&play) {return}
    core.create(&play.entities)
    for world in ([2]^Program_Test_World{&document,&play}) {
        entity:=core.create(&world.entities);core.add(&world.ids,entity,{value=17})
        modifier:=anim.POSE_MODIFIERS_DEFAULT;modifier.profile=pose_id;core.add(&world.modifiers,entity,modifier)
        target:=core.create(&world.entities);core.add(&world.ids,target,{value=18})
        core.settle(&info,world,nil)
    }
    f.session.info,f.session.edit_world,f.session.mode=&info,&document,.Play;f.session.runs[0]={world=&play}
    requested:=request_defaults();authoring_test_register(f,t,"request",Request_Params,request,requested)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","goals":[{"kind":"Look","name":"head","target":{"kind":"Entity","entity":"0000000000000012"}}]}`).code,0)
    if !testing.expect_value(t,len(play.modifier_requests.queue.items),1) {return}
    goal:=play.modifier_requests.queue.items[0]
    testing.expect(t,goal.rig==play.ids.entities[0] && goal.target.kind==.Entity && goal.target.entity==play.ids.entities[1] && goal.target.entity!=document.ids.entities[1])
    testing.expect(t,goal.slot==1 && goal.weight==.4 && goal.enabled)
    ik_result:=authoring_test_execute(f,"request",`{"entity":"0000000000000011","goals":[{"kind":"IK","name":"foot","target":{"position":[0,0,0]}}]}`)
    if !testing.expectf(t,ik_result.code==0,"%s %s",ik_result.message,ik_result.data) {return}
    goal=play.modifier_requests.queue.items[1]
    testing.expect(t,goal.target.kind==.World && goal.target.position=={} && goal.target.rotation==1 && goal.weight==1 && goal.enabled)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","controls":[{"kind":"Contact","name":"foot","weight":0.2}]}`).code,0)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","goals":[{"kind":"Contact","name":"foot","position":[1,2,3],"normal":[0,0,1],"contact":0.7,"grounded":true}]}`).code,0)
    goal=play.modifier_requests.queue.items[2]
    testing.expect(t,goal.kind==.Contact && goal.position=={1,2,3} && goal.normal=={0,0,1} && goal.weight==.7)
    testing.expect_value(t,len(play.modifier_requests.controls.items),1)
    testing.expect_value(t,play.modifier_requests.controls.items[0].weight,f32(.2))
    for request in ([9]string{
        `{"entity":"0000000000000011","goals":[{"kind":"Look","name":"missing"}]}`,
        `{"entity":"0000000000000011","goals":[{"kind":"Look","name":"head","target":{"kind":"Entity","entity":"0000000000000099"}}]}`,
        `{"entity":"0000000000000012","goals":[{"kind":"Look","name":"head"}]}`,
        `{"entity":"0000000000000011","goals":[{"kind":"Look","name":"head","weight":0.5}]}`,
        `{"entity":"0000000000000011","goals":[{"kind":"Look","name":"head","position":[1e999,0,0]}]}`,
        `{"entity":"0000000000000011","goals":[{"kind":"Look","name":"head","normal":[0,1,0]}]}`,
        `{"entity":"0000000000000011","goals":[{"kind":"Look","name":"head","contact":0.5}]}`,
        `{"entity":"0000000000000011","goals":[{"kind":"Look","name":"head","enabled":false}]}`,
        `{"entity":"0000000000000011","goals":[{"kind":"Look","name":"head","target":{"kind":"Entity","entity":"0000000000000012"},"position":[0,0,0]}]}`,
    }) {testing.expect_value(t,authoring_test_execute(f,"request",request).code,api.INVALID_PARAMS)}
    testing.expect_value(t,len(play.modifier_requests.queue.items),3)
    f.session.mode=.Simulate
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","goals":[{"kind":"Contact","name":"foot","grounded":false}]}`).code,0)
    testing.expect(t,len(play.modifier_requests.queue.items)==4 && !play.modifier_requests.queue.items[3].enabled && play.modifier_requests.queue.items[3].normal=={0,1,0})
    f.session.mode=.Edit
    testing.expect_value(t,authoring_test_execute(f,"request",`{"entity":"0000000000000011","goals":[{"kind":"Look","name":"head"}]}`).code,api.INVALID_PARAMS)
    testing.expect_value(t,len(play.modifier_requests.queue.items),4)
    testing.expect(t,len(document.modifier_requests.queue.items)==0 && len(document.modifier_requests.controls.items)==0)
    preview:Preview_Params;copy(preview.entity[:],"0000000000000011")
    preview.goals[0]={kind=.Look,target={kind=.Entity,rotation=1,scale={1,1,1}},normal={0,1,0}};copy(preview.goals[0].target.entity[:],"0000000000000012");base.text_set(preview.goals[0].name[:],"head")
    call:=api.Call{raw=`{"goals":[{"kind":"Look","name":"head","target":{"kind":"Entity","entity":"0000000000000012"}}]}`,allocator=context.temp_allocator}
    testing.expect(t,request_apply(&f.session,&call,core.world_ref(&play,&info),play.ids.entities[0],&preview,0,nil))
    testing.expect(t,len(play.modifier_requests.queue.items)==5 && play.modifier_requests.queue.items[4].target.entity==play.ids.entities[1])
    testing.expect_value(t,len(document.modifier_requests.queue.items),0)
    f.session.mode=.Play
    testing.expect_value(t,anim.pose_profile_save(fmt.tprintf("%s/goals.pose",f.root),&f.assets.types,pose_id,{look={look,look}}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    ambiguous:=authoring_test_execute(f,"request",`{"entity":"0000000000000011","goals":[{"kind":"Look","name":"head","target":{"kind":"Entity","entity":"0000000000000012"}}]}`)
    testing.expect_value(t,ambiguous.code,api.INVALID_PARAMS);testing.expect(t,strings.contains(ambiguous.data,"Ambiguous_Reference"))
    testing.expect_value(t,len(play.modifier_requests.queue.items),5)
}
