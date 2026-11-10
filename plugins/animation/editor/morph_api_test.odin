package animation_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

@(private="file")
Morph_Api_Test_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    meshes:core.Table(erender.Mesh_Renderer),
    configs:core.Table(anim.Morph_Weights),
    animations:core.Table(anim.Animation),
    targets:core.Table(anim.Animation_Target),
    sources:core.Table(anim.Pose_Source),
    morphs:anim.Morph_Playback,
}
@(private="file")
Morph_Api_Test_Shared :: struct {skin:anim.Skin_Runtime}

@(test)
morph_api_inspects_named_defaults_final_weights_and_sources_and_controls_instances_with_scene_undo :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"morph-instance") {return};defer authoring_test_destroy(f)
    targets:=[2]asset.Morph_Target{{weight=.25},{weight=-.5}}
    base.text_set(targets[0].name[:],"Smile");base.text_set(targets[1].name[:],"Blink")
    id:=base.Asset_Id{81,83}
    vertices:=[3]asset.Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    if !testing.expect_value(t,source_mesh_save(fmt.tprintf("%s/face.mesh",f.root),&f.assets.types,{id=id},{vertices=vertices[:],morphs=targets[:]},{0,1,2}),asset.Error.None) {return}
    testing.expect(t,host.assets_scan(&f.assets))
    info,described:=core.test_info(t,Morph_Api_Test_World,Morph_Api_Test_Shared,core.Test_None,anim.test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    document,play:Morph_Api_Test_World
    defer for world in ([2]^Morph_Api_Test_World{&document,&play}) {core.world_destroy(&info,.World,world)}
    for world in ([2]^Morph_Api_Test_World{&document,&play}) {
        if !testing.expect(t,core.world_init(&info,.World,world,context.allocator)) {return}
        source,mesh:=core.create(&world.entities),core.create(&world.entities)
        core.add(&world.ids,source,{17});core.add(&world.ids,mesh,{18});core.add(&world.parents,mesh,{entity=source})
        core.add(&world.meshes,mesh,{mesh=id});core.add(&world.animations,source,anim.ANIMATION_DEFAULT)
        target:anim.Animation_Target;base.text_set(target.path[:],"Face");core.add(&world.targets,mesh,target)
        core.settle(&info,world,nil)
    }
    shared:Morph_Api_Test_Shared;defer delete(shared.skin.rigs)
    record,_:=asset.registry_find(&f.assets.registry,id)
    append(&shared.skin.rigs,anim.Skin_Rig{id=id,revision=1,stamp={record.size,record.time},morphs=targets[:]})
    f.app.shared=&shared
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    viewport:editor.Viewport;gui:editor.Editor_Ui
    f.session.info,f.session.edit_world,f.session.selection,f.session.edits,f.session.viewport,f.session.gui=&info,&document,&selection,&edits,&viewport,&gui
    history.edits_reset(&edits,core.world_ref(&document,&info))
    inspect:=Morph_Inspect_Params{limit=256}
    set:=Morph_Set_Params{mode=.Override}
    authoring_test_register(f,t,"inspect",Morph_Inspect_Params,morph_inspect,&inspect)
    program_test_register_result(f,t,"set",Morph_Set_Params,Morph_Set_Result,morph_set,&set)
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"entity":"0000000000000012","limit":1}`).code,0)
    output:=string(serial.writer_bytes(&f.out))
    testing.expect(t,strings.contains(output,`"total":2`) && strings.contains(output,`"name": "Smile"`) && !strings.contains(output,`"name": "Blink"`))
    testing.expect(t,strings.contains(output,`"source":"0x0000000000000011"`) && strings.contains(output,`"source_kind":"Ancestor"`) && strings.contains(output,"Face/@morph/Smile"),output)
    testing.expect(t,!strings.contains(output,"diagnostic") && !strings.contains(output,"unresolved"))
    testing.expect_value(t,authoring_test_execute(f,"set",`{"entity":"0000000000000012","name":"Smile","value":0.35,"mode":"Default"}`).code,0)
    testing.expect_value(t,edits.cursor,1)
    mesh:=document.meshes.entities[0]
    configured,has_config:=core.get(&document.configs,mesh)
    testing.expect(t,has_config && morph_api_test_count(configured)==1)
    testing.expect(t,history.undo(&edits,core.world_ref(&document,&info),&selection));testing.expect(t,!core.has(&document.configs,mesh))
    testing.expect(t,history.redo(&edits,core.world_ref(&document,&info),&selection))
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"entity":"0000000000000012"}`).code,0)
    output=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(output,`"mesh_default": 0.25`) && strings.contains(output,`"default_value": 0.35`) && strings.contains(output,`"evaluated": false`))
    before:=document.configs.values[0];cursor:=edits.cursor
    invalid:=authoring_test_execute(f,"set",`{"entity":"0000000000000012","name":"smile","value":1}`)
    testing.expect(t,invalid.code==api.INVALID_PARAMS && strings.contains(invalid.data,"Unknown_Target") && strings.contains(invalid.message,"inspect"))
    testing.expect_value(t,document.configs.values[0],before);testing.expect_value(t,edits.cursor,cursor)
    testing.expect_value(t,authoring_test_execute(f,"set",`{"entity":"0000000000000012","name":"Smile","value":-1.25}`).code,0)
    playing:=anim.Morph_Playing{entity=mesh,mesh=id,revision=1,path=base.name_hash("Face"),source=document.animations.entities[0],stamp=core.stamp(&document.configs,0)+1}
    append(&playing.current,f32(-1.25),f32(-.5));append(&document.morphs.states,playing)
    resize(&document.morphs.rows,int(core.entity_index(mesh))+1);document.morphs.rows[core.entity_index(mesh)]=1
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"entity":"0000000000000012","diagnostics":true}`).code,0)
    output=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(output,`"final_weight": -1.25`) && strings.contains(output,`"evaluated": true`) && strings.contains(output,`"pending": false`))
    testing.expect_value(t,authoring_test_execute(f,"set",`{"entity":"0000000000000012","name":"Smile","value":1.75}`).code,0)
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"entity":"0000000000000012"}`).code,0)
    testing.expect(t,strings.contains(string(serial.writer_bytes(&f.out)),`"evaluated": false`))
    cursor=edits.cursor;before=document.configs.values[0]
    f.session.mode=.Play;f.session.runs[0]={world=&play}
    testing.expect_value(t,authoring_test_execute(f,"set",`{"entity":"0000000000000012","name":"Blink","value":-2,"mode":"Additive"}`).code,0)
    testing.expect_value(t,play.configs.values[0].values[0],f32(-2));testing.expect_value(t,document.configs.values[0],before);testing.expect_value(t,edits.cursor,cursor)
    f.session.mode=.Simulate
    testing.expect_value(t,authoring_test_execute(f,"set",`{"entity":"0000000000000012","name":"Blink","value":3}`).code,0)
    testing.expect_value(t,play.configs.values[0].values[0],f32(3));testing.expect_value(t,edits.cursor,cursor)
    anim.morph_weight_set(core.edit(&play.configs,play.meshes.entities[0]),"Future",4)
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"entity":"0000000000000012","diagnostics":true}`).code,0)
    output=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(output,`"error": "Unknown_Target"`) && strings.contains(output,`"name_hash"`))
    testing.expect_value(t,authoring_test_execute(f,"set",`{"entity":"0000000000000012","name":"Future","remove":true}`).code,0)
    testing.expect_value(t,morph_api_test_count(play.configs.values[0]),1)
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"entity":"0000000000000012","diagnostics":true}`).code,0)
    output=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(output,`"error": "None"`) && !strings.contains(output,`"name_hash"`))
    testing.expect_value(t,authoring_test_execute(f,"set",`{"entity":"0000000000000012","name":"Blink","remove":true}`).code,0)
    testing.expect_value(t,morph_api_test_count(play.configs.values[0]),0);testing.expect_value(t,document.configs.values[0],before)
    version:=play.configs.version
    testing.expect_value(t,authoring_test_execute(f,"set",`{"entity":"0000000000000012","name":"Blink","remove":true}`).code,0)
    testing.expect_value(t,play.configs.version,version)
    core.edit(&play.configs,play.meshes.entities[0]).source=play.animations.entities[0]
    testing.expect_value(t,authoring_test_execute(f,"inspect",`{"entity":"0000000000000012"}`).code,0)
    testing.expect(t,strings.contains(string(serial.writer_bytes(&f.out)),`"source_kind":"Explicit"`))
    f.session.mode=.Watch
    testing.expect_value(t,authoring_test_execute(f,"set",`{"entity":"0000000000000012","name":"Smile","value":1}`).code,api.INVALID_PARAMS)
}

@(private="file")
morph_api_test_count :: proc(weights:anim.Morph_Weights) -> (count:int) {for name in weights.names {if name!=0 {count+=1}};return}

// Saves a mesh of one level of a source and its indices, as an importer writes it.
@(private)
source_mesh_save :: proc(path:string,types:^asset.Types,desc:asset.Mesh_Desc,source:asset.Mesh_Source,indices:[]u32) -> asset.Error {
    desc:=desc
    if !asset.mesh_build(source,indices,nil,&desc.geometry,context.temp_allocator) {return .Invalid}
    return asset.mesh_save(path,types,desc)
}
