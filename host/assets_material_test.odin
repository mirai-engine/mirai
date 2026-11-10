package host

import "core:fmt"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

@(test)
material_values_change_in_memory_one_row_at_a_time :: proc(t:^testing.T) {
    root:=base.test_folder(t,"host-materials")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    stone,wood:=base.Asset_Id{1,1},base.Asset_Id{2,2}
    info:=asset.MATERIAL_DEFAULTS
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/stone.mat",root),&types,{id=stone,info=info}),asset.Error.None)
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/wood.mat",root),&types,{id=wood,info=info}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8})) {return}
    defer assets_destroy(&a)
    row:=assets_material_row(&a,stone)
    other:=assets_material_row(&a,wood)
    testing.expect(t,row!=0 && other!=0 && row!=other)
    testing.expect(t,!a.materials_dirty && slice.equal(a.rows_dirty[:],[]u32{row,other}),"a material that loads sends its row alone")
    assets_commit(&a)
    testing.expect_value(t,len(a.rows_dirty),0)

    changed:=info
    changed.roughness=0.25
    structure:=a.structure
    testing.expect(t,assets_material_set(&a,stone,changed,nil))
    testing.expect(t,!a.materials_dirty && slice.equal(a.rows_dirty[:],[]u32{row}),"only the row of the material goes")
    testing.expect_value(t,assets_material_values(&a,row).roughness,f32(0.25))
    testing.expect_value(t,a.structure,structure)
    assets_commit(&a)
    testing.expect(t,assets_material_set(&a,stone,changed,nil))
    testing.expect_value(t,len(a.rows_dirty),0)

    // While a row derives from the values of materials, what derives from
    // this one is asked for again by its id.
    derived:=assets_material_values(&a,other)
    derived.base_color={1,0,0}
    _,made:=assets_material_derive(&a,derived)
    testing.expect(t,made)
    assets_commit(&a)
    changed.metallic=1
    testing.expect(t,assets_material_set(&a,stone,changed,nil))
    changes,local:=assets_structure_changes(&a,structure)
    testing.expect(t,local && len(changes)==1 && changes[0].id==stone,"rows derived from it are asked for again, and only those")

    // The file still holds the old values: reloading it brings them back, and
    // reloading it again changes nothing.
    assets_commit(&a)
    testing.expect(t,assets_reload(&a,stone))
    testing.expect_value(t,assets_material_values(&a,row).roughness,info.roughness)
    structure=a.structure
    testing.expect(t,assets_reload(&a,stone))
    testing.expect(t,len(a.rows_dirty)==0 && !a.materials_dirty && a.structure==structure,"a file that did not change sends nothing")
}

@(test)
assets_read_the_files_the_registry_holds_in_memory :: proc(t:^testing.T) {
    root:=base.test_folder(t,"host-memory")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    stone,brick:=base.Asset_Id{1,1},base.Asset_Id{3,3}
    info:=asset.MATERIAL_DEFAULTS
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/stone.mat",root),&types,{id=stone,info=info}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8})) {return}
    defer assets_destroy(&a)
    row:=assets_material_row(&a,stone)
    assets_commit(&a)
    bytes_of :: proc(t:^testing.T,types:^asset.Types,id:base.Asset_Id,info:asset.Material_Info) -> []u8 {
        doc:asset.Document
        testing.expect_value(t,asset.material_document(&doc,types,{id=id,info=info}),asset.Error.None)
        defer asset.document_destroy(&doc)
        data,_:=asset.document_bytes(&doc,context.temp_allocator)
        return data
    }
    changed:=info
    changed.roughness=0.25
    testing.expect_value(t,asset.registry_memory_set(&a.registry,"stone.mat",bytes_of(t,&types,stone,changed)),asset.Error.None)
    testing.expect(t,assets_reload(&a,stone))
    testing.expect_value(t,assets_material_values(&a,row).roughness,f32(0.25))
    testing.expect(t,len(assets_unsaved(&a))==1 && assets_unsaved(&a)[0].path=="stone.mat")

    // An asset only memory holds loads like one on disk.
    created:=info
    created.metallic=1
    testing.expect_value(t,asset.registry_memory_set(&a.registry,"brick.mat",bytes_of(t,&types,brick,created)),asset.Error.None)
    other:=assets_material_row(&a,brick)
    testing.expect(t,other!=0 && assets_material_values(&a,other).metallic==1)
    testing.expect(t,assets_material(&a,brick)!=nil && !assets_material(&a,brick).failed)
}
