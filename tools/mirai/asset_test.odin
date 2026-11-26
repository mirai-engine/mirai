package main

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

// mirai asset ls of a folder inside the assets of a project lists only its files and finds
// their dependencies anywhere in those assets; one that is nowhere is still missing.
@(test)
asset_ls_of_a_subfolder_finds_dependencies_elsewhere_in_the_project :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    project:=base.test_folder(t,"asset-ls")
    if project=="" {return}
    assets:=fmt.tprintf("%s/assets",project)
    os.make_directory_all(fmt.tprintf("%s/sub",assets))
    os.make_directory_all(fmt.tprintf("%s/other",assets))
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    pixels:[16]u8
    texture:=base.Asset_Id{1,1}
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/other/b.tex",assets),&types,{id=texture,width=2,height=2,format=.RGBA8,mips={pixels[:]}}),asset.Error.None)
    material:=asset.MATERIAL_DEFAULTS
    material.maps.base_color.texture=texture
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/sub/a.mat",assets),&types,{id={2,2},info=material}),asset.Error.None)
    testing.expect_value(t,asset_ls("",{fmt.tprintf("%s/sub",assets)}),0)
    testing.expect_value(t,asset_ls("",{assets}),0)

    material.maps.base_color.texture={9,9}
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/sub/lost.mat",assets),&types,{id={3,3},info=material}),asset.Error.None)
    testing.expect_value(t,asset_ls("",{fmt.tprintf("%s/sub",assets)}),1)
    testing.expect_value(t,asset_ls("",{fmt.tprintf("%s/other",assets)}),0)
}
