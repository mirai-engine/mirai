package editor

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"

@(test)
an_imported_material_keeps_unsaved_changes_over_an_import_and_goes_back_by_field :: proc(t:^testing.T) {
    root:=base.test_folder(t,"material-base")
    if root=="" {return}
    folder:=project.path(root,"assets",allocator=context.temp_allocator)
    os.make_directory_all(folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    body:=base.Asset_Id{4,4}
    path:=fmt.tprintf("%s/body.mat",folder)
    source:asset.Import_Info
    asset.text_set(source.source[:],"body.gltf")
    asset.text_set(source.name[:],"Body")
    given:=asset.MATERIAL_DEFAULTS
    given.roughness=0.5
    given.maps.base_color.texture={1,1}
    bytes :: proc(t:^testing.T,types:^asset.Types,id:base.Asset_Id,info:asset.Material_Info,imported:^asset.Material_Info,source:^asset.Import_Info) -> []u8 {
        data,error:=asset.material_bytes(types,{id=id,info=info,imported=imported,source=source},context.temp_allocator)
        testing.expect_value(t,error,asset.Error.None)
        return data
    }
    testing.expect(t,os.write_entire_file(path,bytes(t,&types,body,given,&given,&source))==nil)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    materials:Materials
    info:core.World_Info
    s:=Session{app=&app,materials=&materials,info=&info}

    // A person makes the material rougher and does not save it.
    rough:=given
    rough.roughness=0.9
    testing.expect(t,file_write(&s,path,bytes(t,&types,body,rough,&given,&source),"Material"))
    imported:=material_base(&s,body)
    testing.expect(t,imported!=nil && imported^==given,"the reference of its fields is what the source gave")

    // The source gives another texture, and its import writes the file.
    now:=given
    now.maps.base_color.texture={2,2}
    testing.expect(t,os.write_entire_file(path,bytes(t,&types,body,now,&now,&source))==nil)
    host.assets_scan(&assets)
    material_rebase(&s,body)
    file:asset.Asset
    if !testing.expect(t,asset_read(&s,"body.mat",&file)) {return}
    view,error:=asset.material_view(&file,&assets.types)
    testing.expect(t,error==.None && view.imported!=nil && view.imported^==now)
    testing.expect(t,view.info.roughness==0.9 && view.info.maps.base_color.texture==base.Asset_Id{2,2},"unsaved, the change stays and the new texture arrives")
    asset.asset_close(&file)
    testing.expect(t,asset_unsaved(&s,body))
    imported=material_base(&s,body)
    testing.expect(t,imported!=nil && imported^==now,"the reference follows the file")

    // Going back to what the source gave leaves what the disk holds: nothing unsaved.
    testing.expect(t,material_write(&s,body,{kind=.Revert,paths={"roughness"}}))
    testing.expect(t,!asset_unsaved(&s,body))
    testing.expect_value(t,host.assets_material_values(&assets,host.assets_material_row(&assets,body)).roughness,f32(0.5))
}

// Apply to material: what an entity changes of the material of a slot,
// values, a map and its overlays, goes into the file of the material; what it
// changes of another slot stays out.
@(test)
the_override_of_a_slot_of_an_entity_goes_into_its_material :: proc(t:^testing.T) {
    root:=base.test_folder(t,"material-apply")
    if root=="" {return}
    folder:=project.path(root,"assets",allocator=context.temp_allocator)
    os.make_directory_all(folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    wall:=base.Asset_Id{5,5}
    path:=fmt.tprintf("%s/wall.mat",folder)
    data,error:=asset.material_bytes(&types,{id=wall,info=asset.MATERIAL_DEFAULTS},context.temp_allocator)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,os.write_entire_file(path,data)==nil)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    materials:Materials
    info:core.World_Info
    s:=Session{app=&app,materials=&materials,info=&info}

    names:=erender.MATERIAL_VALUE_NAMES
    maps:=erender.MATERIAL_MAP_NAMES
    roughness:=base.name_hash(names[3])
    override:=erender.Material_Values{own_overlays=true,overlay_count=1}
    testing.expect(t,erender.material_value(&override,roughness,{0.7,0,0,0},1) && erender.material_value(&override,roughness,{0.2,0,0,0},0))
    testing.expect(t,override_texture_put(&override,0,base.name_hash(maps[.Base_Color]),{7,7},true))
    override.overlays[0]={id=1,material={9,9},blend=.Multiply,enabled=true}
    testing.expect(t,override.count==2 && erender.material_value_find(&override,0,roughness)!=erender.material_value_find(&override,1,roughness),"each slot keeps a value of its own")
    testing.expect(t,erender.material_values_slot(&override,1) && !erender.material_values_slot(&override,2))
    given,rest:=override_split(&override,0)
    testing.expect(t,given.count==1 && given.texture_count==1 && given.own_overlays,"the first slot takes the overlays")
    testing.expect(t,rest.count==1 && rest.slots[0]==1 && rest.texture_count==0 && !rest.own_overlays)
    testing.expect(t,material_write(&s,wall,{kind=.Override,override=&given}))

    file:asset.Asset
    if !testing.expect(t,asset_read(&s,"wall.mat",&file)) {return}
    defer asset.asset_close(&file)
    view,view_error:=asset.material_view(&file,&assets.types)
    if !testing.expect_value(t,view_error,asset.Error.None) {return}
    testing.expect_value(t,view.info.roughness,f32(0.2))
    testing.expect_value(t,view.info.maps.base_color.texture,base.Asset_Id{7,7})
    testing.expect(t,len(view.overlays)==1 && view.overlays[0].material==base.Asset_Id{9,9} && view.overlays[0].blend==.Multiply)
}
