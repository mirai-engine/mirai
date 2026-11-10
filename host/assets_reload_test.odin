package host

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

// A reload of a file that changed into one that does not open keeps what
// loaded before and says why, once however often it is tried; once the file
// is whole again the reload takes it and the error goes.
@(test)
a_reload_of_a_damaged_file_keeps_what_loaded_and_says_why_until_it_is_whole :: proc(t:^testing.T) {
    root:=base.test_folder(t,"host-reload")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    stone:=base.Asset_Id{1,1}
    info:=asset.MATERIAL_DEFAULTS
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/stone.mat",root),&types,{id=stone,info=info}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8})) {return}
    defer assets_destroy(&a)
    row:=assets_material_row(&a,stone)
    assets_commit(&a)
    testing.expect(t,row!=0 && len(a.errors)==0)

    bytes_of :: proc(t:^testing.T,types:^asset.Types,id:base.Asset_Id,info:asset.Material_Info) -> []u8 {
        doc:asset.Document
        testing.expect_value(t,asset.material_document(&doc,types,{id=id,info=info}),asset.Error.None)
        defer asset.document_destroy(&doc)
        data,_:=asset.document_bytes(&doc,context.temp_allocator)
        return data
    }
    changed:=info
    changed.roughness=0.25
    damaged:=bytes_of(t,&types,stone,changed)
    damaged[len(damaged)-1]~=0xff
    testing.expect_value(t,asset.registry_memory_set(&a.registry,"stone.mat",damaged),asset.Error.None)
    reloads:=a.stats.reloads
    for _ in 0..<2 {
        testing.expect(t,!assets_reload(&a,stone))
        testing.expect_value(t,assets_material_values(&a,row).roughness,info.roughness)
    }
    testing.expect_value(t,a.stats.reloads,reloads)
    if testing.expect_value(t,len(a.errors),1) {
        testing.expect(t,a.errors[0].id==stone && a.errors[0].kind==.Material && a.errors[0].problem==.Corrupt,"the file contradicts its hash")
    }

    testing.expect_value(t,asset.registry_memory_set(&a.registry,"stone.mat",bytes_of(t,&types,stone,changed)),asset.Error.None)
    testing.expect(t,assets_reload(&a,stone))
    testing.expect_value(t,assets_material_values(&a,row).roughness,f32(0.25))
    testing.expect_value(t,len(a.errors),0)
}

// A folder mounted in a shipped game (a packed index) loads its assets at once;
// a refresh sees what is written in it and not in the shipped folder, and once
// unmounted what loaded from it stays while it is in use.
@(test)
a_folder_mounted_in_a_shipped_game_is_refreshed_alone_and_keeps_what_loaded :: proc(t:^testing.T) {
    root,guest:=base.test_folder(t,"host-mount"),base.test_folder(t,"host-mount-user")
    if root=="" || guest=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    stone,moss,late,unseen:=base.Asset_Id{1,1},base.Asset_Id{2,2},base.Asset_Id{3,3},base.Asset_Id{4,4}
    info:=asset.MATERIAL_DEFAULTS
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/stone.mat",root),&types,{id=stone,info=info}),asset.Error.None)
    shipped:asset.Registry;asset.registry_init(&shipped,root);defer asset.registry_destroy(&shipped)
    testing.expect_value(t,asset.registry_scan(&shipped),asset.Error.None)
    testing.expect(t,asset.registry_save(&shipped,fmt.tprintf("%s/%s",root,asset.REGISTRY_INDEX)))
    info.roughness=0.25
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/moss.mat",guest),&types,{id=moss,info=info}),asset.Error.None)

    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8}) && a.indexed) {return}
    defer assets_destroy(&a)
    refused,error:=assets_mount(&a,guest,"user")
    testing.expect(t,error==.None && refused==0)
    row:=assets_material_row(&a,moss)
    assets_commit(&a)
    testing.expect(t,row!=0 && len(a.errors)==0 && assets_material_values(&a,row).roughness==0.25)

    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/late.mat",guest),&types,{id=late,info=info}),asset.Error.None)
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/unseen.mat",root),&types,{id=unseen,info=info}),asset.Error.None)
    testing.expect(t,assets_refresh(&a,{"user/late.mat","unseen.mat"}))
    _,written:=asset.registry_find(&a.registry,late)
    _,shipped_late:=asset.registry_find(&a.registry,unseen)
    testing.expect(t,written && !shipped_late)

    testing.expect_value(t,assets_unmount(&a,"user"),asset.Error.None)
    _,listed:=asset.registry_find(&a.registry,moss)
    testing.expect(t,!listed && assets_material_row(&a,moss)==row && assets_material_values(&a,row).roughness==0.25)
    testing.expect_value(t,assets_unmount(&a,"user"),asset.Error.Not_Found)
}
