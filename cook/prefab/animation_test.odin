package prefab

import "core:fmt"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/gltf"
import "mirai:core"
import "mirai:std/math"
import "mirai:std/base"

@(rodata,private="file")
GLTF:=[?]importer.Format{gltf.FORMAT}

@(private="file")
root_of :: proc(scene:^asset.Scene) -> base.Entity_Id {
    root,_:=asset.prefab_root(scene)
    return root
}

@(test)
imported_animation_prefab_preserves_targets_and_clip_asset :: proc(t:^testing.T) {
    model,error:=importer.import_model(#directory+"/../../assets/fixtures/animation.gltf",GLTF[:])
    if !testing.expect_value(t,error.code,importer.Error_Code.None) {return}
    defer importer.model_destroy(&model)
    folder:=base.test_folder(t,"animation-prefab")
    if folder=="" {return}
    path:=fmt.tprintf("%s/animation-prefab.scene",folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    animation_id:=base.Asset_Id{17,29}
    assets:=importer.Import_Report{animation_id=animation_id}
    report,write_error:=model_prefab(&model,&assets,&types,{1,2},"animated",path)
    testing.expect_value(t,write_error,Error.None)
    testing.expect_value(t,report.entities,3)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    Playback :: struct {asset:base.Asset_Id,speed,weight:f32,playing,loop:bool}
    Target :: struct {path:[asset.NODE_PATH_CAPACITY]u8}
    a,found:=asset.scene_get(&scene,root_of(&scene),"Animation",Playback)
    testing.expect(t,found && a.asset==animation_id && a.playing && a.loop && a.speed==1 && a.weight==1)
    first,found_first:=asset.scene_get(&scene,1,"Animation_Target",Target)
    second,found_second:=asset.scene_get(&scene,2,"Animation_Target",Target)
    testing.expect(t,found_first && found_second && base.text_get(first.path[:])==model.nodes[0].path && base.text_get(second.path[:])==model.nodes[1].path && first.path!=second.path)
}

@(test)
an_animated_source_root_keeps_a_separate_prefab_placement :: proc(t:^testing.T) {
    nodes:=[1]importer.Imported_Node{{name="animated root",path="animated root",parent=-1,mesh=-1,transform=math.TRANSFORM_IDENTITY,target=123,visible=true}}
    nodes[0].transform.position={2,3,4}
    model:=importer.Imported_Model{nodes=nodes[:]}
    folder:=base.test_folder(t,"animation-placement")
    if folder=="" {return}
    path:=fmt.tprintf("%s/animation-placement.scene",folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    assets:=importer.Import_Report{animation_id={1,3}}
    report,error:=model_prefab(&model,&assets,&types,{1,2},"placed",path)
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expect_value(t,report.entities,2)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    testing.expect_value(t,root_of(&scene),base.Entity_Id(2))
    Playback :: struct {asset:base.Asset_Id}
    Target :: struct {path:[asset.NODE_PATH_CAPACITY]u8}
    _,animated:=asset.scene_get(&scene,root_of(&scene),"Animation",Playback)
    _,targeted:=asset.scene_get(&scene,root_of(&scene),"Animation_Target",Target)
    target,child_target:=asset.scene_get(&scene,1,"Animation_Target",Target)
    testing.expect(t,animated && !targeted && child_target && base.text_get(target.path[:])=="animated root")
    root,_:=asset.scene_get(&scene,root_of(&scene),"Transform",core.Transform)
    child,_:=asset.scene_get(&scene,1,"Transform",core.Transform)
    testing.expect_value(t,root.position,math.Vec3{})
    testing.expect_value(t,child.position,math.Vec3{2,3,4})
}

@(test)
a_skinned_source_without_clips_keeps_an_untargeted_placement_root :: proc(t:^testing.T) {
    model,import_error:=importer.import_model(#directory+"/../../assets/fixtures/skeletal-analytic.gltf",GLTF[:])
    if !testing.expect_value(t,import_error.code,importer.Error_Code.None) {return}
    defer importer.model_destroy(&model)
    folder:=base.test_folder(t,"skin-placement")
    if folder=="" {return}
    path:=fmt.tprintf("%s/skin-placement.scene",folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    mesh_ids:=[1]base.Asset_Id{{13,31}}
    skeleton_ids:=[1]base.Asset_Id{{17,37}}
    assets:=importer.Import_Report{mesh_ids=mesh_ids[:],skeleton_ids=skeleton_ids[:]}
    report,error:=model_prefab(&model,&assets,&types,{1,2},"placed",path)
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expect_value(t,report.entities,1)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,path),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    testing.expect_value(t,root_of(&scene),base.Entity_Id(5))
    // The placement root is the rig: it shows the skinned mesh, whose node needs no entity of its own.
    Target :: struct {path:[asset.NODE_PATH_CAPACITY]u8}
    _,root_targeted:=asset.scene_get(&scene,root_of(&scene),"Animation_Target",Target)
    shown,has_mesh:=asset.scene_get(&scene,root_of(&scene),"Mesh_Renderer",struct {mesh:base.Asset_Id})
    _,child_found:=asset.scene_entity_find(&scene,2)
    testing.expect(t,!root_targeted && has_mesh && shown.mesh==mesh_ids[0] && !child_found)
}
