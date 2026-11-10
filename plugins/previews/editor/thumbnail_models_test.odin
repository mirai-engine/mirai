package previews_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import anim "mirai:std/anim"
import "mirai:std/base"

// A component of a game that names the animation its entity plays.
@(private="file")
Test_Player :: struct {clip:base.Asset_Id,speed:f32}

@(private="file")
test_skeleton :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,paths:[]string) {
    bones:=make([]asset.Skeleton_Bone,len(paths),context.temp_allocator)
    for bone_path,i in paths {
        bone:=&bones[i]
        bone^={target=base.name_hash(bone_path),parent=i32(i)-1,rotation=1,scale={1,1,1}}
        slash:=strings.last_index_byte(bone_path,'/')
        base.text_set(bone.name[:],bone_path[slash+1:])
        base.text_set(bone.path[:],bone_path)
    }
    testing.expect_value(t,asset.skeleton_save(path,types,{id=id,bones=bones}),asset.Error.None)
}

@(private="file")
test_mesh :: proc(t:^testing.T,types:^asset.Types,path:string,id,skeleton:base.Asset_Id) {
    vertices:=[3]asset.Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    indices:=[3]u32{0,1,2}
    desc:=asset.Mesh_Desc{id=id}
    skin:[3]asset.Skin_Vertex
    joints:=[1]asset.Rig_Joint{{node=0,inverse_bind=1}}
    source:=asset.Mesh_Source{vertices=vertices[:]}
    if skeleton!={} {
        for &influence in skin {influence.weights[0]=255}
        source.skin,desc.joints,desc.skeleton=skin[:],joints[:],skeleton
    }
    testing.expect(t,asset.mesh_build(source,indices[:],nil,&desc.geometry,context.temp_allocator))
    testing.expect_value(t,asset.mesh_save(path,types,desc),asset.Error.None)
}

@(private="file")
test_animation :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,targets:[]string) {
    keys:=[2]anim.Keyframe{{time=0},{time=1,value={0,1,0,0}}}
    tracks:=make([]asset.Animation_Track_Desc,len(targets),context.temp_allocator)
    for target,i in targets {tracks[i]={target=target,property=.Position,keys=keys[:]}}
    clips:=[1]asset.Animation_Clip_Desc{{name="clip",tracks=tracks}}
    testing.expect_value(t,asset.animation_save(path,types,{id=id,clips=clips[:]}),asset.Error.None)
}

// A document whose entity 1 plays animation with a mesh, and whose entity 2,
// under it, shows another.
@(private="file")
test_document :: proc(t:^testing.T,types:^asset.Types,path:string,kind:asset.Fourcc,id,animation,mesh,child_mesh:base.Asset_Id) {
    scene:asset.Scene
    testing.expect_value(t,asset.scene_init(&scene,types,kind,id),asset.Error.None)
    defer asset.scene_destroy(&scene)
    _,error:=asset.scene_entity_add(&scene,1,0,"Player")
    testing.expect_value(t,error,asset.Error.None)
    _,error=asset.scene_entity_add(&scene,2,1,"Part")
    testing.expect_value(t,error,asset.Error.None)
    if animation!={} {
        player:=Test_Player{clip=animation,speed=1}
        testing.expect_value(t,asset.scene_set(&scene,1,"Test_Player",&player),asset.Error.None)
    }
    for each,entity in ([2]base.Asset_Id{mesh,child_mesh}) {
        if each=={} {continue}
        renderer:=erender.Mesh_Renderer{mesh=each}
        testing.expect_value(t,asset.scene_set(&scene,base.Entity_Id(entity+1),"Mesh_Renderer",&renderer),asset.Error.None)
    }
    testing.expect_value(t,asset.scene_save(&scene,path),asset.Error.None)
}

@(test)
thumbnails_show_the_model_an_animation_moves :: proc(t:^testing.T) {
    root:=base.test_folder(t,"thumbnail-models")
    if root=="" {return}
    for folder in ([?]string{"a","b","c","d"}) {os.make_directory_all(project.path(root,folder,allocator=context.temp_allocator))}
    file:=proc(root,name:string) -> string {return fmt.tprintf("%s/%s",root,name)}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)

    biped:=[?]string{"hips","hips/chest"}
    robot_rig,tall_rig,spider_rig:=base.Asset_Id{7,1},base.Asset_Id{7,2},base.Asset_Id{7,3}
    test_skeleton(t,&types,file(root,"a/robot.skeleton"),robot_rig,biped[:])
    test_skeleton(t,&types,file(root,"b/tall.skeleton"),tall_rig,biped[:])
    test_skeleton(t,&types,file(root,"c/spider.skeleton"),spider_rig,{"body","body/leg"})
    robot,tall,spider,jelly:=base.Asset_Id{8,1},base.Asset_Id{8,2},base.Asset_Id{8,3},base.Asset_Id{8,4}
    test_mesh(t,&types,file(root,"a/robot.mesh"),robot,robot_rig)
    test_mesh(t,&types,file(root,"b/tall.mesh"),tall,tall_rig)
    test_mesh(t,&types,file(root,"c/spider.mesh"),spider,spider_rig)
    test_mesh(t,&types,file(root,"c/jelly.mesh"),jelly,{})
    walk,stride,crawl,blink,still:=base.Asset_Id{9,1},base.Asset_Id{9,2},base.Asset_Id{9,3},base.Asset_Id{9,4},base.Asset_Id{9,5}
    test_animation(t,&types,file(root,"walk.anim"),walk,biped[:])
    test_animation(t,&types,file(root,"stride.anim"),stride,biped[:])
    test_animation(t,&types,file(root,"crawl.anim"),crawl,{"body/leg"})
    test_animation(t,&types,file(root,"blink.anim"),blink,{"Part/@morph/Blink"})
    test_animation(t,&types,file(root,"still.anim"),still,{"nobody"})
    level,jelly_prefab:=base.Asset_Id{10,1},base.Asset_Id{10,2}
    test_document(t,&types,file(root,"level.scene"),asset.KIND_SCENE,level,stride,tall,{})
    test_document(t,&types,file(root,"jelly.prefab"),asset.KIND_PREFAB,jelly_prefab,blink,{},jelly)

    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=16})) {return}
    defer host.assets_destroy(&assets)
    if !testing.expect(t,host.assets_scan(&assets)) {return}
    m:Thumbnail_Models
    defer thumbnail_models_destroy(&m)

    // Unplayed, the skinned mesh whose bones it moves; the first by path of two that have as many.
    testing.expect_value(t,thumbnail_animation_model(&m,&assets,walk),Thumbnail_Model{mesh=robot})
    testing.expect_value(t,thumbnail_animation_model(&m,&assets,crawl),Thumbnail_Model{mesh=spider})
    testing.expect_value(t,thumbnail_animation_model(&m,&assets,still),Thumbnail_Model{})
    // Played, the skinned mesh of the entity that plays it, over the bone match.
    testing.expect_value(t,thumbnail_animation_model(&m,&assets,stride),Thumbnail_Model{mesh=tall})
    // An entity that plays it without moving a skeleton shows with what hangs from it.
    testing.expect_value(t,thumbnail_animation_model(&m,&assets,blink),Thumbnail_Model{document=jelly_prefab,root=1})

    // The scene stops playing it: the bone match again, once the registry sees the change.
    test_document(t,&types,file(root,"level.scene"),asset.KIND_SCENE,level,{},tall,{})
    testing.expect_value(t,thumbnail_animation_model(&m,&assets,stride),Thumbnail_Model{mesh=tall})
    if !testing.expect_value(t,asset.registry_scan(&assets.registry),asset.Error.None) {return}
    testing.expect_value(t,thumbnail_animation_model(&m,&assets,stride),Thumbnail_Model{mesh=robot})
}
