package prefab

import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/gltf"
import "mirai:std/base"

// An entity of the prefab of a model collides only when its mesh has
// colliders of its source: an Auto Collider, which takes them. A mesh
// without them gives its entity no Collider.
@(test)
only_a_mesh_with_colliders_of_its_source_gives_its_entity_a_collider :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"prefab-colliders")
    if folder=="" {return}
    source:=fmt.tprintf("%s/props.gltf",folder)
    path:=fmt.tprintf("%s/props.scene",folder)
    positions:=[9]f32{0,0,0,1,0,0,0,1,0}
    encoded,_:=base64.encode(mem.slice_to_bytes(positions[:]),allocator=context.temp_allocator)
    text:=strings.concatenate({`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1]}],"meshes":[{"name":"Crate","primitives":[{"attributes":{"POSITION":0}}]},{"name":"Rug","primitives":[{"attributes":{"POSITION":0}}]}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}],"bufferViews":[{"buffer":0,"byteLength":36}],"buffers":[{"byteLength":36,"uri":"data:application/octet-stream;base64,`,encoded,`"}],
        "nodes":[{"name":"Crate","mesh":0},{"name":"Rug","mesh":1}]}`},context.temp_allocator)
    if !testing.expect(t,os.write_entire_file(source,transmute([]u8)text)==nil) {return}
    formats:=[1]importer.Format{gltf.FORMAT}
    model,error:=importer.import_model(source,formats[:])
    if !testing.expectf(t,error.code==.None,"%v: %s",error.code,error.message) {return}
    defer importer.model_destroy(&model)
    if !testing.expect_value(t,len(model.meshes),2) {return}
    crate:=0 if model.meshes[0].name=="Crate" else 1
    box:=[1]asset.Collider{{kind=.Box,rotation=1,size={0.5,0.5,0.5}}}
    model.meshes[crate].collision.colliders=box[:]
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    assets:=importer.Import_Report{allocator=context.allocator}
    defer importer.report_destroy(&assets)
    assets.mesh_ids=make([]base.Asset_Id,2)
    assets.mesh_ids[0],assets.mesh_ids[1]={3,4},{5,6}
    _,write_error:=model_prefab(&model,&assets,&types,import_world(t),{1,2},"props",path)
    if !testing.expect_value(t,write_error,Error.None) {return}
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    entity_of :: proc(scene:^asset.Scene,name:string) -> base.Entity_Id {
        for i in 0..<asset.scene_entity_count(scene) {if record:=asset.scene_entity(scene,i);record.name==name {return record.id}}
        return 0
    }
    collider,collides:=asset.scene_get(&scene,entity_of(&scene,"Crate"),"Collider",Game_Collider)
    testing.expectf(t,collides && collider.kind==.Auto && collider.friction==GAME_COLLIDER_DEFAULT.friction,"the crate collides as the colliders of its mesh: %v",collider)
    _,rug_collides:=asset.scene_get(&scene,entity_of(&scene,"Rug"),"Collider",Game_Collider)
    testing.expect(t,!rug_collides,"the rug, whose mesh has none, does not collide")
}
