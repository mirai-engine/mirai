package editor

import "core:os"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

@(private)
Create_Test_Provider :: struct {provider:Asset_Document_Provider}
// The world of the files tests with what the editor holds of a plugin that makes documents.
@(private) Create_Test_Editor :: struct {provider:Create_Test_Provider}
@(test_world,editor="Create_Test_Editor") @(private) Create_Test_World :: struct {using world:Test_World,ids:core.Table(core.Id)}
@(private) create_test_provider_default :: proc() -> Create_Test_Provider {return {provider={kinds={0=asset.KIND_UI},count=1,creates={0},create=create_test_file}}}
// The empty .ui of the test plugin; none for the id that stands for a failure.
@(private="file")
create_test_file :: proc(s:^Session,kind:asset.Fourcc,id:base.Asset_Id) -> []u8 {
    if id==CREATE_TEST_FAILS {return nil}
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[1]ui.Tree_Node{ui.tree_node_record(&texts,-1,{kind=.Box,name="root"})}
    styles:=[1]ui.Node_Style{}
    bytes,_:=host.ui_tree_bytes(&s.app.assets.types,id,{nodes=nodes[:],styles=styles[:]},allocator=context.temp_allocator)
    return bytes
}
@(private="file") CREATE_TEST_FAILS :: base.Asset_Id{7,7}

// Create gives the first free name of a folder, numbered, and makes each kind
// as it says: a folder and a scene on disk at once, the rest as a step of the
// history of the scene that the registry holds until it is written.
@(test)
create_makes_each_kind_with_a_free_name_where_it_says :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"asset-create") {return}
    defer files_test_close(&f)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=project.path(f.root,"assets",allocator=context.temp_allocator),capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    s:=&f.s
    s.app=&app
    r:=&assets.registry
    disk :: proc(f:^Files_Test,path:string) -> string {return project.path(f.root,"assets",path,allocator=context.temp_allocator)}

    testing.expect_value(t,asset_create_default(s,asset.KIND_SOUND_SET),"New Sound Set")
    testing.expect_value(t,asset_create_default(s,ASSET_CREATE_FOLDER),"New Folder")
    testing.expect_value(t,asset_create_path(r,"Materials","New Material",".mat"),"Materials/New Material.mat")
    material:=asset_id_new(s)
    testing.expect_value(t,asset_create(s,asset.KIND_MATERIAL,"Materials/New Material.mat",material),"")
    files_test_commit(&f)
    file,found:=asset.registry_find(r,material)
    testing.expect(t,found && file.path=="Materials/New Material.mat" && file.kind==asset.KIND_MATERIAL)
    testing.expect(t,!os.exists(disk(&f,"Materials/New Material.mat")),"the registry holds it until its step is written")
    testing.expect_value(t,asset_create_path(r,"Materials","New Material",".mat"),"Materials/New Material 2.mat")
    // A folder only a file the registry holds is in is taken too.
    testing.expect_value(t,asset_create_path(r,"","Materials",""),"Materials 2")
    // Undo takes it away before it reached the disk.
    testing.expect(t,history.undo(&f.edits,edited_world(s),&f.selection))
    _,found=asset.registry_find(r,material)
    testing.expect(t,!found)
    testing.expect(t,history.redo(&f.edits,edited_world(s),&f.selection))

    // A folder is made at once and the registry knows it without files.
    testing.expect_value(t,asset_create(s,ASSET_CREATE_FOLDER,"Empty",{}),"")
    testing.expect(t,os.is_dir(disk(&f,"Empty")) && slice.contains(r.folders[:],"Empty/"))
    testing.expect_value(t,asset_create_path(r,"","Empty",""),"Empty 2")
    scene:=asset_id_new(s)
    testing.expect_value(t,asset_create(s,asset.KIND_SCENE,"Empty/New Scene.scene",scene),"")
    file,found=asset.registry_find(r,scene)
    testing.expect(t,found && file.kind==asset.KIND_SCENE && os.exists(disk(&f,"Empty/New Scene.scene")),"a scene opens from its file")
    testing.expect(t,!asset.registry_prefab(file),"a scene is no prefab, whatever its roots")
    prefab:=asset_id_new(s)
    testing.expect_value(t,asset_create(s,ASSET_CREATE_PREFAB,"Empty/New Prefab.scene",prefab),"")
    file,found=asset.registry_find(r,prefab)
    testing.expect(t,found && asset.registry_prefab(file) && asset_create_kind_name(s,ASSET_CREATE_PREFAB)=="prefab","a prefab is a .scene of that kind")
    testing.expect(t,slice.contains(asset_create_kinds(s),asset.KIND_STRINGS) && slice.contains(asset_create_kinds(s),asset.KIND_FONT))
    testing.expect_value(t,asset_create_kind_name(s,asset.KIND_STRINGS),"strings")
    for kind in ([]asset.Fourcc{asset.KIND_SOUND_SET,asset.KIND_STRINGS,asset.KIND_FONT}) {
        id:=asset_id_new(s)
        path:=asset_create_path(r,"Effects",asset_create_default(s,kind),asset_create_extension(s,kind))
        testing.expect_value(t,asset_create(s,kind,path,id),"")
        files_test_commit(&f)
        file,found=asset.registry_find(r,id)
        testing.expect(t,found && file.kind==kind && !os.exists(disk(&f,path)))
    }

    // Names and folders that cannot be.
    testing.expect(t,asset_name_refusal("New Material")=="" && asset_name_refusal("a/b")!="" && asset_name_refusal(".hidden")!="" && asset_name_refusal("end.")!="" && asset_name_refusal("")!="")
    clean,refusal:=asset_folder_clean(r,"\\Materials\\Deep/")
    testing.expect(t,clean=="Materials/Deep" && refusal=="")
    _,refusal=asset_folder_clean(r,"Materials/../out")
    testing.expect(t,refusal!="")
    // A kind no plugin creates is refused.
    testing.expect(t,!slice.contains(asset_create_kinds(s),asset.KIND_UI))
    testing.expect(t,asset_create(s,asset.KIND_UI,"hud.ui",asset_id_new(s))!="")
}

// The plugin of a kind it creates gives its empty file, made with the id the
// editor gave, which goes where the editor says as an edit.
@(test)
a_plugin_gives_the_empty_file_of_a_kind_it_creates :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"asset-create-plugin") {return}
    defer files_test_close(&f)
    info,made:=test_info(t,Create_Test_World)
    if !made {return}
    defer test_info_destroy(&info)
    f.s.info=&info
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=project.path(f.root,"assets",allocator=context.temp_allocator),capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    s:=&f.s
    s.app=&app
    kinds:=asset_create_kinds(s)
    testing.expect_value(t,kinds[len(kinds)-1],asset.KIND_UI)
    testing.expect_value(t,asset_create_kind_name(s,asset.KIND_SOUND_SET),"sound_set")

    id:=asset_id_new(s)
    testing.expect_value(t,asset_create(s,asset.KIND_UI,"UI/New UI.ui",id),"")
    files_test_commit(&f)
    file,found:=asset.registry_find(&assets.registry,id)
    testing.expect(t,found && file.path=="UI/New UI.ui" && file.kind==asset.KIND_UI)
    // What the plugin could not make is told and leaves no file.
    testing.expect(t,asset_create(s,asset.KIND_UI,"UI/Other.ui",CREATE_TEST_FAILS)!="")
    _,found=asset.registry_find(&assets.registry,CREATE_TEST_FAILS)
    testing.expect(t,!found)
}
