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
// of another as an overlay, an entity of a scene the materials it gives
// overlays and those its values make blended or opaque, and an asset of a kind whose plugin declares
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
    GLASS,STONE,MOSS,EMBER,PLAIN,RUNE,TILE :: base.Asset_Id{1,1},base.Asset_Id{1,2},base.Asset_Id{1,3},base.Asset_Id{1,4},base.Asset_Id{1,5},base.Asset_Id{1,6},base.Asset_Id{1,7}
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
    material(t,&types,project.path(assets,"rune.mat",allocator=context.temp_allocator),RUNE,"Rune",.Opaque)
    material(t,&types,project.path(assets,"tile.mat",allocator=context.temp_allocator),TILE,"Tile",.Opaque)
    // One entity lays rune over a cube; another shows tile blended.
    scene:asset.Scene
    testing.expect_value(t,asset.scene_init(&scene,&types,{1,8},context.temp_allocator),asset.Error.None)
    // The components of engine/render, with fields the cook does not read.
    Renderer :: struct {mesh:base.Asset_Id,shape:u8,materials:[abi.MATERIAL_SLOTS]base.Asset_Id,shadows:bool}
    Values :: struct {
        color:[4]f32,
        emission:[3]f32,
        count:u32,
        slots:[abi.INSTANCE_VALUES_MAX]u8,
        names:[abi.INSTANCE_VALUES_MAX]u64,
        values:[abi.INSTANCE_VALUES_MAX][4]f32,
        own_overlays:bool,
        overlay_count:u32,
        overlays:[asset.MATERIAL_MAX_OVERLAYS]asset.Material_Overlay,
    }
    looks:[2]struct{renderer:Renderer,values:Values}
    looks[0].values.own_overlays,looks[0].values.overlay_count=true,1
    looks[0].values.overlays[0]={id=1,material=RUNE,enabled=true}
    looks[1].renderer.materials[0]=TILE
    looks[1].values.count=1
    looks[1].values.names[0]=base.name_hash("alpha_mode")
    looks[1].values.values[0]={f32(asset.Alpha_Mode.Blend),0,0,0}
    for &look,i in looks {
        id:=base.Entity_Id(i+1)
        asset.scene_entity_add(&scene,id,0,"look")
        testing.expect_value(t,asset.scene_set(&scene,id,"Mesh_Renderer",&look.renderer),asset.Error.None)
        testing.expect_value(t,asset.scene_set(&scene,id,"Material_Values",&look.values),asset.Error.None)
    }
    level:=project.path(assets,"level.scene",allocator=context.temp_allocator)
    uses_write(t,level,text="")
    testing.expect_value(t,asset.scene_save(&scene,level),asset.Error.None)
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
    uses,_,problem:=program_uses(&p,context.temp_allocator)
    testing.expect_value(t,problem,"")
    want:=[]struct{program:string,uses:abi.Program_Uses}{{"Ember",{.Opaque,.Particle_Sprite}},{"Glass",{.Blend}},{"Moss",{.Opaque,.Overlay}},{"Rune",{.Opaque,.Overlay}},{"Stone",{.Opaque}},{"Tile",{.Opaque,.Blend}}}
    testing.expect_value(t,len(uses),len(want))
    for each,i in want {
        if i>=len(uses) {break}
        testing.expect_value(t,uses[i].program,each.program)
        testing.expect_value(t,uses[i].uses,each.uses)
    }
}

// The stages draw viewmodels when a scene or a prefab of the project or of a
// plugin holds a Viewmodel, or when the code of the game names
// render.Viewmodel; without either the project has no generation and runs the
// shaders of the engine, a struct of its own of that name aside.
@(test)
a_viewmodel_in_the_assets_or_the_code_asks_the_stages_for_it :: proc(t:^testing.T) {
    Case :: struct {name:string,prefab:bool,code:string,viewmodel:bool}
    cases:=[]Case{
        {"a prefab of a plugin",true,"",true},
        {"the code of the game",false,"package game\nimport erender \"mirai:engine/render\"\nrifle :: proc() -> erender.Viewmodel {return {fov=1}}\n",true},
        {"neither",false,"package game\nimport \"mirai:core\"\nViewmodel :: struct {fov:f32}\nlook :: proc(c:core.Commands) -> Viewmodel {return {}}\n",false},
    }
    for c in cases {
        root:=base.test_folder(t,"build-viewmodel")
        if root=="" {return}
        m:=project.manifest_default("Viewmodel Game")
        base.text_set(m.plugins[0][:],"arms")
        uses_write(t,root,project.PROJECT_FILE,text=project.manifest_text(&m,context.temp_allocator))
        plugin:project.Plugin_Manifest
        base.text_set(plugin.name[:],"arms")
        base.text_set(plugin.version[:],"1.0.0")
        plugin.parts={.Assets}
        uses_write(t,root,"plugins","arms",project.PLUGIN_FILE,text=project.plugin_text(&plugin,context.temp_allocator))
        types:asset.Types
        asset.types_init(&types,context.temp_allocator)
        scene:asset.Scene
        testing.expect_value(t,asset.scene_init(&scene,&types,{2,1},context.temp_allocator),asset.Error.None)
        asset.scene_entity_add(&scene,1,0,"rifle")
        Viewmodel :: struct {fov:f32}
        Light :: struct {intensity:f32}
        if c.prefab {
            testing.expect_value(t,asset.scene_set(&scene,1,"Viewmodel",&Viewmodel{1}),asset.Error.None)
        } else {
            testing.expect_value(t,asset.scene_set(&scene,1,"Point_Light",&Light{1}),asset.Error.None)
        }
        rifle:=project.path(root,"plugins/arms/assets/Rifle.scene",allocator=context.temp_allocator)
        uses_write(t,rifle,text="")
        testing.expect_value(t,asset.scene_save(&scene,rifle),asset.Error.None)
        if c.code!="" {uses_write(t,root,"game","rifle.odin",text=c.code)}

        p,error:=project.open(root,"")
        defer project.close(&p)
        testing.expect_value(t,error.code,project.Error_Code.None)
        _,viewmodel,problem:=shaders_uses(&p,nil,context.temp_allocator)
        testing.expect_value(t,problem,"")
        testing.expectf(t,viewmodel==c.viewmodel,"%s: viewmodel %v",c.name,viewmodel)
        // Without the root of the engine a generation cannot be made: one that is wanted fails.
        job:=shaders_run(&p)
        testing.expectf(t,(job.result.status==.None)==!c.viewmodel,"%s: %v",c.name,job.result.status)
        shaders_destroy(job)
    }
}
