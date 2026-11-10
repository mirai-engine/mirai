package prefab

import "core:fmt"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
morph_prefabs_keep_the_weights_a_node_sets_apart_from_its_mesh :: proc(t:^testing.T) {
    targets:=[2]asset.Morph_Target{{weight=.1},{weight=0}}
    base.text_set(targets[0].name[:],"Smile");base.text_set(targets[1].name[:],"Blink")
    meshes:=[1]importer.Imported_Mesh{{morphs=targets[:]}}
    nodes:=[3]importer.Imported_Node{
        {name="Face",path="Face",parent=-1,mesh=0,visible=true,transform=mm.TRANSFORM_IDENTITY,morph_weights={.8,0}},
        {name="Same",path="Same",parent=-1,mesh=0,visible=true,transform=mm.TRANSFORM_IDENTITY,morph_weights={.1,0}},
        {name="Plain",path="Plain",parent=-1,mesh=0,visible=true,transform=mm.TRANSFORM_IDENTITY},
    }
    model:=importer.Imported_Model{meshes=meshes[:],nodes=nodes[:]}
    ids:=[1]base.Asset_Id{{1,2}}
    assets:=importer.Import_Report{mesh_ids=ids[:],animation_id={3,4}}
    folder:=base.test_folder(t,"morph-prefab")
    if folder=="" {return}
    file:=fmt.tprintf("%s/morph-prefab.prefab",folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    _,error:=model_prefab(&model,&assets,&types,{31,32},"Faces",file)
    if !testing.expect_value(t,error,Error.None) {return}
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&scene,&types,file),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    face,found:=asset.scene_get(&scene,1,"Morph_Weights",Morph_Weights)
    testing.expect(t,found && face.names[0]==base.name_hash("Smile") && face.values[0]==.8 && face.modes[0]==.Default && face.names[1]==0)
    testing.expect(t,face.path[0]==0,"the path of the curves is that of the Animation_Target")
    _,same:=asset.scene_get(&scene,2,"Morph_Weights",Morph_Weights)
    _,plain:=asset.scene_get(&scene,3,"Morph_Weights",Morph_Weights)
    testing.expect(t,!same && !plain,"a node with the weights of its mesh needs no Morph_Weights")
}
