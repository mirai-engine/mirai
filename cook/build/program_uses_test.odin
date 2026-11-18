package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:project"
import "mirai:render/abi"
import "mirai:std/base"

@(private="file")
uses_write :: proc(t:^testing.T,parts:..string,text:="") {
    file:=project.path(..parts,allocator=context.temp_allocator)
    directory:=file[:strings.last_index_byte(file,'/')]
    testing.expect(t,os.make_directory_all(directory)==nil || os.is_dir(directory))
    testing.expect(t,os.write_entire_file(file,text)==nil,file)
}

// A material draws its program by its alpha mode, the material of an overlay
// of another as an overlay, and an asset of a kind whose plugin declares
// program_uses so the program of the material it depends on.
@(test)
program_uses_are_what_the_assets_draw_each_program_as :: proc(t:^testing.T) {
    root:=base.test_folder(t,"build-uses")
    if root=="" {return}
    m:=project.manifest_default("Uses Game")
    base.text_set(m.plugins[0][:],"glow")
    uses_write(t,root,project.PROJECT_FILE,text=project.manifest_text(&m,context.temp_allocator))
    plugin:project.Plugin_Manifest
    base.text_set(plugin.name[:],"glow")
    base.text_set(plugin.version[:],"1.0.0")
    plugin.parts={.Assets}
    base.text_set(plugin.asset_kinds[0].extension[:],".spark")
    base.text_set(plugin.asset_kinds[0].kind[:],"SPRK")
    plugin.asset_kinds[0].version=1
    base.text_set(plugin.asset_kinds[0].program_uses[0][:],"particle_sprite")
    uses_write(t,root,"plugins","glow",project.PLUGIN_FILE,text=project.plugin_text(&plugin,context.temp_allocator))

    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    GLASS,STONE,MOSS,EMBER,PLAIN :: base.Asset_Id{1,1},base.Asset_Id{1,2},base.Asset_Id{1,3},base.Asset_Id{1,4},base.Asset_Id{1,5}
    material :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,program:string,alpha:asset.Alpha_Mode,overlays:[]asset.Material_Overlay={}) {
        info:=asset.MATERIAL_DEFAULTS
        info.alpha_mode=alpha
        base.text_set(info.program[:],program)
        uses_write(t,path,text="")
        testing.expect_value(t,asset.material_save(path,types,{id=id,info=info,overlays=overlays}),asset.Error.None)
    }
    assets:=project.path(root,"assets",allocator=context.temp_allocator)
    material(t,&types,project.path(assets,"glass.mat",allocator=context.temp_allocator),GLASS,"Glass",.Blend)
    material(t,&types,project.path(assets,"stone.mat",allocator=context.temp_allocator),STONE,"Stone",.Opaque,{{id=1,material=MOSS,enabled=true}})
    material(t,&types,project.path(assets,"moss.mat",allocator=context.temp_allocator),MOSS,"Moss",.Mask)
    material(t,&types,project.path(assets,"ember.mat",allocator=context.temp_allocator),EMBER,"Ember",.Opaque)
    material(t,&types,project.path(assets,"plain.mat",allocator=context.temp_allocator),PLAIN,"",.Blend)
    Spark :: struct {material:base.Asset_Id}
    doc:asset.Document
    asset.document_init(&doc,asset.Fourcc(u32('S')|u32('P')<<8|u32('R')<<16|u32('K')<<24),{1,6},context.temp_allocator)
    doc.kind_version=1
    spark:=Spark{EMBER}
    _,put:=asset.document_put_row(&doc,&types,"spark",&spark)
    testing.expect_value(t,put,asset.Error.None)
    fire:=project.path(root,"plugins/glow/assets/fire.spark",allocator=context.temp_allocator)
    uses_write(t,fire,text="")
    testing.expect_value(t,asset.document_save(&doc,fire),asset.Error.None)

    p,error:=project.open(root,"")
    defer project.close(&p)
    testing.expect_value(t,error.code,project.Error_Code.None)
    uses,problem:=program_uses(&p,context.temp_allocator)
    testing.expect_value(t,problem,"")
    want:=[]struct{program:string,uses:abi.Program_Uses}{{"Ember",{.Opaque,.Particle_Sprite}},{"Glass",{.Blend}},{"Moss",{.Opaque,.Overlay}},{"Stone",{.Opaque}}}
    testing.expect_value(t,len(uses),len(want))
    for each,i in want {
        if i>=len(uses) {break}
        testing.expect_value(t,uses[i].program,each.program)
        testing.expect_value(t,uses[i].uses,each.uses)
    }
}
