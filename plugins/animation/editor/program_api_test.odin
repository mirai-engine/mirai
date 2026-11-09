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
    testing.expect(t,existing.code==0 && strings.contains(string(serial.writer_bytes(&f.out)),`"replaced":true`) && authoring_test_id(f,"locomotion.blend")==id,existing.message)
    file:asset.Asset
    testing.expect_value(t,authoring_test_load(f,"locomotion.blend",&file),asset.Error.None)
    profile,error:=anim.blend_space_view(&file,&f.assets.types)
    testing.expect_value(t,error,asset.Error.None);testing.expect_value(t,len(profile.segments),1);testing.expect_value(t,profile.samples[1].speed,f32(1))
    asset.asset_close(&file)
    testing.expect_value(t,authoring_test_execute(f,"sample",fmt.tprintf(`{{"asset":"%s","position":[1,0]}}`,identity)).code,0)
    text:=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(text,`"weight":0.5`) && strings.contains(text,`"clip":"idle"`) && strings.contains(text,`"clip":"walk"`))
    testing.expect_value(t,authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s"}}`,identity)).code,0)
    text=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(text,`"samples_total":2`) && strings.contains(text,`"index":1`) && !strings.contains(text,`"index":0`))
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
    text:=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(text,`"triangles_total":1`) && strings.contains(text,"direction") && strings.contains(text,"speed"))
    testing.expect_value(t,authoring_test_execute(f,"sample",fmt.tprintf(`{{"asset":"%s","position":[0.25,0.25]}}`,identity)).code,0)
    text=string(serial.writer_bytes(&f.out));testing.expect(t,strings.count(text,`"index":`)==3 && strings.contains(text,`"weight":0.5`) && strings.count(text,`"weight":0.25`)==2)
    collinear,_:=strings.replace_all(definition,`"position":[0,1]`,`"position":[0.5,0]`,context.temp_allocator)
    testing.expect_value(t,authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"locomotion.blend",%s}}`,collinear)).code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_revision(f,"locomotion.blend"),revision)
}

@(test)
graph_authoring_resolves_named_dependencies_and_preserves_files_on_invalid_edits :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"program-graph") {return};defer authoring_test_destroy(f)
    source:=authoring_test_id_text(program_test_source(f,t))
    defaults:=program_graph_defaults();inspect:=Authoring_Inspect_Params{limit=16}
    authoring_test_register(f,t,"set",Graph_Write_Params,program_graph_set,defaults)
    authoring_test_register(f,t,"inspect",Authoring_Inspect_Params,program_graph_inspect,&inspect)
    definition:=fmt.tprintf(`"animation":"%s","output":"locomotion","nodes":[{{"name":"locomotion","kind":"Blend","left":"idle","right":"walk","weight_parameter":"speed"}},{{"name":"walk","kind":"Clip","clip":"walk"}},{{"name":"idle","kind":"Clip","clip":"idle"}}],"parameters":[{{"name":"speed","value":0,"min":0,"max":1}}]`,source)
    created:=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"movement.agraph",%s}}`,definition))
    if !testing.expect(t,created.code==0,created.message) {return}
    id:=authoring_test_id(f,"movement.agraph");identity:=authoring_test_id_text(id)
    revision:=authoring_test_revision(f,"movement.agraph")
    file:asset.Asset
    testing.expect_value(t,authoring_test_load(f,"movement.agraph",&file),asset.Error.None)
    profile,error:=anim.graph_view(&file,&f.assets.types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect_value(t,profile.nodes[0].speed,f32(1));testing.expect_value(t,profile.nodes[0].x_param,i16(-1));testing.expect(t,profile.nodes[0].loop)
    testing.expect(t,profile.nodes[2].left<2 && profile.nodes[2].right<2 && profile.info.output==2);asset.asset_close(&file)
    testing.expect_value(t,authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s"}}`,identity)).code,0)
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    result_type,result_registered:=serial.schema_add_type_info(&schema,type_info_of(Graph_Inspect_Result));if !testing.expect(t,result_registered) {return}
    result:=new(Graph_Inspect_Result,context.temp_allocator)
    reader:serial.Text_Reader;serial.text_reader_init(&reader,string(serial.writer_bytes(&f.out)),context.temp_allocator);defer serial.text_reader_destroy(&reader)
    parsed:=serial.text_read(&reader,&schema,result_type,mem.ptr_to_bytes(result)) && serial.text_end(&reader)
    testing.expect(t,parsed && result.nodes_total==3 && base.text_get(result.nodes[2].value.left[:])=="idle" && base.text_get(result.nodes[2].value.weight_parameter[:])=="speed")
    for replacement in ([3][2]string{{`"left":"idle"`,`"left":"locomotion"`},{`"output":"locomotion"`,`"output":"missing"`},{`"weight_parameter":"speed"`,`"weight_parameter":"missing"`}}) {
        bad,_:=strings.replace_all(definition,replacement[0],replacement[1],context.temp_allocator)
        result:=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"movement.agraph",%s}}`,bad))
        testing.expect_value(t,result.code,api.INVALID_PARAMS);testing.expect(t,strings.contains(result.data,`"path"`) && strings.contains(result.data,`"code"`))
        testing.expect_value(t,authoring_test_revision(f,"movement.agraph"),revision)
    }
    updated,_:=strings.replace_all(definition,`"value":0`,`"value":0.5`,context.temp_allocator)
    testing.expect_value(t,authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"movement.agraph",%s}}`,updated)).code,0)
    testing.expect_value(t,authoring_test_id(f,"movement.agraph"),id)
}

@(test)
graph_dry_run_checks_named_references_without_writing :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"program-dry-run") {return};defer authoring_test_destroy(f)
    identity:=authoring_test_id_text(program_test_source(f,t))
    defaults:=program_graph_defaults()
    authoring_test_register(f,t,"set",Graph_Write_Params,program_graph_set,defaults)
    request:=fmt.tprintf(`{{"path":"checked.agraph","dry_run":true,"animation":"%s","output":"blend","nodes":[{{"name":"blend","kind":"Blend","left":"idle","right":"walk"}},{{"name":"walk","kind":"Clip","clip":"walk"}},{{"name":"idle","kind":"Clip","clip":"idle"}}]}}`,identity)
    result:=authoring_test_execute(f,"set",request)
    testing.expect_value(t,result.code,0)
    text:=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(text,`"dry_run":true`) && strings.contains(text,`"asset"`))
    testing.expect(t,!authoring_test_exists(f,"checked.agraph"))
    schema:=authoring_result_schema(Graph_Inspect_Result,type_info_of(Graph_Inspect_Result),context.temp_allocator)
    testing.expect(t,strings.contains(schema,`"weight_parameter"`) && strings.contains(schema,`"sync_mode"`) && !strings.contains(schema,`"x_param"`))
    bad,_:=strings.replace_all(request,`"left":"idle"`,`"left":"absent"`,context.temp_allocator)
    result=authoring_test_execute(f,"set",bad)
    testing.expect_value(t,result.code,api.INVALID_PARAMS);testing.expect(t,strings.contains(result.data,`"path":"nodes[0].left"`) && strings.contains(result.data,`"expected":"a declared name"`) && strings.contains(result.data,`"fix":`))
    testing.expect(t,!authoring_test_exists(f,"checked.agraph"))
}
@(test)
graph_sync_fields_belong_to_sources_and_inspection_matches_the_typed_result :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"program-source-sync") {return};defer authoring_test_destroy(f)
    identity:=authoring_test_id_text(program_test_source(f,t));defaults:=program_graph_defaults();inspect:=Authoring_Inspect_Params{limit=16}
    authoring_test_register(f,t,"set",Graph_Write_Params,program_graph_set,defaults)
    authoring_test_register(f,t,"inspect",Authoring_Inspect_Params,program_graph_inspect,&inspect)
    request:=fmt.tprintf(`{{"path":"sync.agraph","animation":"%s","output":"mix","nodes":[{{"name":"mix","kind":"Blend","left":"idle","right":"walk"}},{{"name":"idle","kind":"Clip","clip":"idle","sync_mode":"Independent"}},{{"name":"walk","kind":"Clip","clip":"walk","sync_mode":"Independent"}}]}}`,identity)
    result:=authoring_test_execute(f,"set",request);if !testing.expect(t,result.code==0,result.message) {return}
    asset_id:=authoring_test_id(f,"sync.agraph");revision:=authoring_test_revision(f,"sync.agraph")
    result=authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s"}}`,authoring_test_id_text(asset_id)));if !testing.expect(t,result.code==0,result.message) {return}
    text:=strings.clone(string(serial.writer_bytes(&f.out)),context.temp_allocator)
    nodes,_:=authoring_json_field(text,"nodes",context.temp_allocator);row,_:=authoring_json_element(nodes,2,context.temp_allocator);value,_:=authoring_json_field(row,"value",context.temp_allocator)
    testing.expect(t,!strings.contains(value,"sync_mode") && !strings.contains(value,"sync_duration") && !strings.contains(value,"sync_group"))
    schema:=authoring_result_schema(Graph_Inspect_Result,type_info_of(Graph_Inspect_Result),context.temp_allocator)
    testing.expect(t,strings.contains(schema,`"required":["name","kind"]`))
    testing.expect_value(t,api.method_register(&f.server,{name="shape",params=Graph_Inspect_Result,params_info=type_info_of(Graph_Inspect_Result),handler=proc(call:^api.Call) {serial.text_write_raw(call.out,"{}")}}),api.Register_Error.None)
    result=authoring_test_execute(f,"shape",text);testing.expect(t,result.code==0,result.message)
    replace,_:=strings.replace_all(request,`"path":"sync.agraph"`,`"path":"sync.agraph"`,context.temp_allocator)
    bad,_:=strings.replace_all(replace,`"left":"idle"`,`"sync_mode":"Independent","left":"idle"`,context.temp_allocator)
    result=authoring_test_execute(f,"set",bad)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"nodes[0].sync_mode"`) && strings.contains(result.data,`"code":"Source_Only"`))
    testing.expect_value(t,authoring_test_revision(f,"sync.agraph"),revision)
    bad,_=strings.replace_all(replace,`"clip":"walk"`,`"clip":"walk","curves":"Additive"`,context.temp_allocator)
    result=authoring_test_execute(f,"set",bad)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"nodes[2].curves"`) && strings.contains(result.data,`"code":"Unsupported_Policy"`))
}

Program_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    animations:core.Table(anim.Animation),
    modifiers:core.Table(anim.Pose_Modifiers),
    animation_requests:anim.Animation_Requests,
    modifier_requests:anim.Modifier_Requests,
    modifier_runtime:anim.Modifier_Runtime,
}
@(private)
program_test_settle :: proc(world,shared,ed:rawptr) {
    w:=(^Program_Test_World)(world)
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.animations,&w.entities);core.table_settle(&w.modifiers,&w.entities)
}
@(private)
program_test_destroy :: proc(w:^Program_Test_World) {
    core.table_destroy(&w.ids);core.table_destroy(&w.animations);core.table_destroy(&w.modifiers)
    delete(w.animation_requests.seeks.items);delete(w.animation_requests.poses.items);delete(w.animation_requests.match_plays.items)
    delete(w.modifier_requests.queue.items);delete(w.modifier_requests.controls.items);anim.modifier_runtime_free(&w.modifier_runtime)
    core.entities_destroy(&w.entities)
}
@(private)
program_test_register_result :: proc(f:^Authoring_Test,t:^testing.T,name:string,$P,$R:typeid,run:editor.Api_Handler,defaults:^P=nil) {
    entry:=new(Authoring_Test_Entry,context.temp_allocator);entry^={&f.session,run}
    testing.expect_value(t,api.method_register(&f.server,{name=name,params=P,params_info=type_info_of(P),result=R,result_info=type_info_of(R),defaults=defaults,user=entry,handler=proc(call:^api.Call) {entry:=(^Authoring_Test_Entry)(call.user);entry.run(entry.session,call)}}),api.Register_Error.None)
}

@(test)
program_runtime_api_sets_named_parameters_and_keeps_plays_and_modifier_controls_out_of_edit :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"program-runtime") {return};defer authoring_test_destroy(f)
    source:=program_test_source(f,t)
    graph_id,pose_id,match_id:=base.Asset_Id{17,33},base.Asset_Id{18,34},base.Asset_Id{19,36}
    nodes:=[1]anim.Graph_Node{anim.GRAPH_NODE_DEFAULT};base.text_set(nodes[0].name[:],"idle");base.text_set(nodes[0].clip[:],"idle")
    parameters:=[1]anim.Graph_Parameter{{min=0,max=1}};base.text_set(parameters[0].name[:],"speed")
    testing.expect_value(t,anim.graph_save(fmt.tprintf("%s/runtime.agraph",f.root),&f.assets.types,graph_id,{info={animation=source},nodes=nodes[:],parameters=parameters[:]}),asset.Error.None)
    clips:=[1]anim.Match_Source{{modes=1<<1,loop=true}};base.text_set(clips[0].clip[:],"idle")
    info:=anim.MATCH_INFO_DEFAULT;info.animation=source
    testing.expect_value(t,anim.match_save(fmt.tprintf("%s/runtime.match",f.root),&f.assets.types,match_id,{info=info,clips=clips[:]}),asset.Error.None)
    look:=anim.LOOK_CONSTRAINT_DEFAULT;look.bone=anim.bone_ref("head")
    testing.expect_value(t,anim.pose_profile_save(fmt.tprintf("%s/runtime.pose",f.root),&f.assets.types,pose_id,{look={look}}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    document,play:Program_Test_World;core.entities_init(&document.entities);core.entities_init(&play.entities);defer program_test_destroy(&document);defer program_test_destroy(&play)
    tables:=[3]core.Table_Info{{type=core.Id,info=type_info_of(core.Id),offset=offset_of(Program_Test_World,ids)},{type=anim.Animation,info=type_info_of(anim.Animation),offset=offset_of(Program_Test_World,animations)},{type=anim.Pose_Modifiers,info=type_info_of(anim.Pose_Modifiers),offset=offset_of(Program_Test_World,modifiers)}}
    storages:=[3]core.Storage_Info{{type=anim.Animation_Requests,info=type_info_of(anim.Animation_Requests),offset=offset_of(Program_Test_World,animation_requests)},{type=anim.Modifier_Requests,info=type_info_of(anim.Modifier_Requests),offset=offset_of(Program_Test_World,modifier_requests)},{type=anim.Modifier_Runtime,info=type_info_of(anim.Modifier_Runtime),offset=offset_of(Program_Test_World,modifier_runtime)}}
    world_info:=core.World_Info{tables=tables[:],storages=storages[:],settle=program_test_settle};test_locomotion_modes(&world_info)
    for world in ([2]^Program_Test_World{&document,&play}) {
        entity:=core.create(&world.entities);core.add(&world.ids,entity,{value=17})
        value:=anim.ANIMATION_DEFAULT;value.asset=graph_id;core.add(&world.animations,entity,value)
        modifier:=anim.POSE_MODIFIERS_DEFAULT;modifier.profile=pose_id;core.add(&world.modifiers,entity,modifier)
        program_test_settle(world,nil,nil)
    }
    f.session.info,f.session.edit_world,f.session.mode=&world_info,&document,.Play;f.session.runs[0]={world=&play}
    requested:=request_defaults();authoring_test_register(f,t,"request",Request_Params,request,requested)
    inspect:=Modifier_Inspect_Params{limit=128};authoring_test_register(f,t,"inspect",Modifier_Inspect_Params,program_modifier_inspect,&inspect)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","parameters":[{"name":"speed","value":0.6}]}`).code,0)
    testing.expect(t,strings.contains(string(serial.writer_bytes(&f.out)),`"kind":"Parameter","name":"speed"`))
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","parameters":[{"index":0,"value":0.8}]}`).code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","parameters":[{"name":"","value":0.8}]}`).code,api.INVALID_PARAMS)
    testing.expect_value(t,play.animations.values[0].parameters[0],f32(.6));testing.expect_value(t,document.animations.values[0].parameter_names,[anim.GRAPH_PARAMETERS]u64{})
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","parameters":[{"name":"speed","value":2}]}`).code,api.INVALID_PARAMS)
    testing.expect_value(t,play.animations.values[0].parameters[0],f32(.6))
    // A play asks the .match, not a graph; it plays a clip of its library with the options of match_play.
    not_matching:=authoring_test_execute(f,"request",`{"id":"11","plays":[{"clip":"walk"}]}`)
    testing.expect(t,not_matching.code==api.INVALID_PARAMS && strings.contains(not_matching.data,"Not_Matching"))
    play.animations.values[0].asset=match_id
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","plays":[{"clip":"walk","mode":"Falling","fade":0.1,"entry":"Keep_Time","phase":0.5,"priority":2,"wait":true}]}`).code,0)
    if testing.expect_value(t,len(play.animation_requests.match_plays.items),1) {
        queued:=play.animation_requests.match_plays.items[0]
        testing.expect(t,queued.clip==base.name_hash("walk") && queued.mode==0 && queued.fade==.1 && queued.entry==.Keep_Time && queued.phase==.5 && queued.priority==2 && queued.wait)
    }
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","plays":[{"clip":"walk"}]}`).code,0)
    testing.expect(t,len(play.animation_requests.match_plays.items)==2 && play.animation_requests.match_plays.items[1].fade==anim.MATCH_PLAY_OPTIONS_DEFAULT.fade && play.animation_requests.match_plays.items[1].phase==1)
    for bad in ([4]string{`{"id":"11","plays":[{"clip":"run"}]}`,`{"id":"11","plays":[{"clip":"walk","mode":"Climbing"}]}`,`{"id":"11","plays":[{"clip":"walk","marker":"step"}]}`,`{"id":"11","plays":[{"clip":"walk","tick":1}]}`}) {
        result:=authoring_test_execute(f,"request",bad)
        testing.expectf(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"plays[0].`) && strings.contains(result.data,`"fix":`),"%s: %s",bad,result.data)
    }
    testing.expect_value(t,len(play.animation_requests.match_plays.items),2)
    play.animations.values[0].asset=graph_id
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","controls":[{"kind":"Look","slot":1,"weight":0.3}]}`).code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","controls":[{"kind":"Look","name":"head","weight":0.3,"fade":0.2}]}`).code,0)
    testing.expect_value(t,len(play.modifier_requests.controls.items),1);testing.expect_value(t,len(document.modifier_requests.controls.items),0)
    testing.expect_value(t,play.modifier_requests.controls.items[0].fade,f32(.2))
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"id":"11"}`).code,0)
    text:=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(text,`"kind":"Look"`) && strings.contains(text,`"name":"head"`) && !strings.contains(text,`"slot"`) && !strings.contains(text,`"diagnostic"`))
    f.session.mode=.Edit
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","plays":[{"clip":"walk"}]}`).code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","controls":[{"kind":"Look","name":"head"}]}`).code,api.INVALID_PARAMS)
    testing.expect_value(t,len(document.animation_requests.match_plays.items),0);testing.expect_value(t,len(document.modifier_requests.controls.items),0)
    temporary:=Preview_Params{id=17}
    base.text_set(temporary.parameters[0].name[:],"speed");temporary.parameters[0].value=.4
    temporary.controls[0]={kind=.Look,weight=.2,enabled=false};base.text_set(temporary.controls[0].name[:],"head")
    preview_call:=api.Call{raw=`{"parameters":[{"name":"speed","value":0.4}],"controls":[{"kind":"Look","name":"head","weight":0.2,"enabled":false}]}`,allocator=context.temp_allocator}
    testing.expect(t,request_apply(&f.session,&preview_call,core.world_ref(&play,&world_info),play.ids.entities[0],&temporary,0,nil))
    testing.expect_value(t,play.animations.values[0].parameters[0],f32(.4))
    testing.expect_value(t,len(play.modifier_requests.controls.items),2)
    testing.expect_value(t,document.animations.values[0].parameter_names,[anim.GRAPH_PARAMETERS]u64{});testing.expect_value(t,len(document.modifier_requests.controls.items),0)
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
    document,play:Program_Test_World;core.entities_init(&document.entities);core.entities_init(&play.entities);defer program_test_destroy(&document);defer program_test_destroy(&play)
    tables:=[3]core.Table_Info{{type=core.Id,info=type_info_of(core.Id),offset=offset_of(Program_Test_World,ids)},{type=anim.Animation,info=type_info_of(anim.Animation),offset=offset_of(Program_Test_World,animations)},{type=anim.Pose_Modifiers,info=type_info_of(anim.Pose_Modifiers),offset=offset_of(Program_Test_World,modifiers)}}
    storages:=[3]core.Storage_Info{{type=anim.Animation_Requests,info=type_info_of(anim.Animation_Requests),offset=offset_of(Program_Test_World,animation_requests)},{type=anim.Modifier_Requests,info=type_info_of(anim.Modifier_Requests),offset=offset_of(Program_Test_World,modifier_requests)},{type=anim.Modifier_Runtime,info=type_info_of(anim.Modifier_Runtime),offset=offset_of(Program_Test_World,modifier_runtime)}}
    info:=core.World_Info{tables=tables[:],storages=storages[:],settle=program_test_settle}
    core.create(&play.entities)
    for world in ([2]^Program_Test_World{&document,&play}) {
        entity:=core.create(&world.entities);core.add(&world.ids,entity,{value=17})
        modifier:=anim.POSE_MODIFIERS_DEFAULT;modifier.profile=pose_id;core.add(&world.modifiers,entity,modifier)
        target:=core.create(&world.entities);core.add(&world.ids,target,{value=18})
        program_test_settle(world,nil,nil)
    }
    f.session.info,f.session.edit_world,f.session.mode=&info,&document,.Play;f.session.runs[0]={world=&play}
    requested:=request_defaults();authoring_test_register(f,t,"request",Request_Params,request,requested)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","goals":[{"kind":"Look","name":"head","target":{"kind":"Entity","entity":"12"}}]}`).code,0)
    if !testing.expect_value(t,len(play.modifier_requests.queue.items),1) {return}
    goal:=play.modifier_requests.queue.items[0]
    testing.expect(t,goal.rig==play.ids.entities[0] && goal.target.kind==.Entity && goal.target.entity==play.ids.entities[1] && goal.target.entity!=document.ids.entities[1])
    testing.expect(t,goal.slot==1 && goal.weight==.4 && goal.enabled)
    ik_result:=authoring_test_execute(f,"request",`{"id":"11","goals":[{"kind":"IK","name":"foot","target":{"position":[0,0,0]}}]}`)
    if !testing.expectf(t,ik_result.code==0,"%s %s",ik_result.message,ik_result.data) {return}
    goal=play.modifier_requests.queue.items[1]
    testing.expect(t,goal.target.kind==.World && goal.target.position=={} && goal.target.rotation==1 && goal.weight==1 && goal.enabled)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","controls":[{"kind":"Contact","name":"foot","weight":0.2}]}`).code,0)
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","goals":[{"kind":"Contact","name":"foot","position":[1,2,3],"normal":[0,0,1],"contact":0.7,"grounded":true}]}`).code,0)
    goal=play.modifier_requests.queue.items[2]
    testing.expect(t,goal.kind==.Contact && goal.position=={1,2,3} && goal.normal=={0,0,1} && goal.weight==.7)
    testing.expect_value(t,len(play.modifier_requests.controls.items),1)
    testing.expect_value(t,play.modifier_requests.controls.items[0].weight,f32(.2))
    for request in ([9]string{
        `{"id":"11","goals":[{"kind":"Look","name":"missing"}]}`,
        `{"id":"11","goals":[{"kind":"Look","name":"head","target":{"kind":"Entity","entity":"99"}}]}`,
        `{"id":"12","goals":[{"kind":"Look","name":"head"}]}`,
        `{"id":"11","goals":[{"kind":"Look","name":"head","weight":0.5}]}`,
        `{"id":"11","goals":[{"kind":"Look","name":"head","position":[1e999,0,0]}]}`,
        `{"id":"11","goals":[{"kind":"Look","name":"head","normal":[0,1,0]}]}`,
        `{"id":"11","goals":[{"kind":"Look","name":"head","contact":0.5}]}`,
        `{"id":"11","goals":[{"kind":"Look","name":"head","enabled":false}]}`,
        `{"id":"11","goals":[{"kind":"Look","name":"head","target":{"kind":"Entity","entity":"12"},"position":[0,0,0]}]}`,
    }) {testing.expect_value(t,authoring_test_execute(f,"request",request).code,api.INVALID_PARAMS)}
    testing.expect_value(t,len(play.modifier_requests.queue.items),3)
    f.session.mode=.Simulate
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","goals":[{"kind":"Contact","name":"foot","grounded":false}]}`).code,0)
    testing.expect(t,len(play.modifier_requests.queue.items)==4 && !play.modifier_requests.queue.items[3].enabled && play.modifier_requests.queue.items[3].normal=={0,1,0})
    f.session.mode=.Edit
    testing.expect_value(t,authoring_test_execute(f,"request",`{"id":"11","goals":[{"kind":"Look","name":"head"}]}`).code,api.INVALID_PARAMS)
    testing.expect_value(t,len(play.modifier_requests.queue.items),4)
    testing.expect(t,len(document.modifier_requests.queue.items)==0 && len(document.modifier_requests.controls.items)==0)
    preview:=Preview_Params{id=17}
    preview.goals[0]={kind=.Look,target={kind=.Entity,entity=18,rotation=1,scale={1,1,1}},normal={0,1,0}};base.text_set(preview.goals[0].name[:],"head")
    call:=api.Call{raw=`{"goals":[{"kind":"Look","name":"head","target":{"kind":"Entity","entity":"12"}}]}`,allocator=context.temp_allocator}
    testing.expect(t,request_apply(&f.session,&call,core.world_ref(&play,&info),play.ids.entities[0],&preview,0,nil))
    testing.expect(t,len(play.modifier_requests.queue.items)==5 && play.modifier_requests.queue.items[4].target.entity==play.ids.entities[1])
    testing.expect_value(t,len(document.modifier_requests.queue.items),0)
    f.session.mode=.Play
    testing.expect_value(t,anim.pose_profile_save(fmt.tprintf("%s/goals.pose",f.root),&f.assets.types,pose_id,{look={look,look}}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    ambiguous:=authoring_test_execute(f,"request",`{"id":"11","goals":[{"kind":"Look","name":"head","target":{"kind":"Entity","entity":"12"}}]}`)
    testing.expect_value(t,ambiguous.code,api.INVALID_PARAMS);testing.expect(t,strings.contains(ambiguous.data,"Ambiguous_Reference"))
    testing.expect_value(t,len(play.modifier_requests.queue.items),5)
}
