package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:cook/import/sources"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"

// asset.import takes by name what an image holds and where a model stands
// facing, and by its id the skeleton the clips of a model go on, and says
// what it takes when given another.
@(test)
asset_import_takes_the_settings_of_a_source_and_says_what_each_takes :: proc(t:^testing.T) {
    Setting :: enum {Image,Skeleton,Front}
    Case :: struct {setting:Setting,path,wrong,says,known:string}
    cases:=[?]Case{
        {.Image,"T_Katana_MR.png","metallic","data","Data"},
        {.Skeleton,"walk.glb","crusader","skeleton","0123456789abcdef0123456789abcdef"},
        {.Front,"walk.glb","up","negative_x","Negative_X"},
    }
    imports:Importer
    s:=Session{app=&host.App{},importer=&imports}
    run :: proc(s:^Session,c:Case,value:string) -> api.Call {
        params:Import_Params
        base.text_set(params.path[:],c.path)
        switch c.setting {
        case .Image:    base.text_set(params.image[:],value)
        case .Skeleton: base.text_set(params.skeleton[:],value)
        case .Front:    base.text_set(params.front[:],value)
        }
        method:=api.Method{params_id=Import_Params}
        call:=api.Call{method=&method,params=&params,allocator=context.temp_allocator}
        api_asset_import(s,&call)
        call.method,call.params=nil,nil
        return call
    }
    for c in cases {
        wrong:=run(&s,c,c.wrong)
        testing.expectf(t,wrong.failed && wrong.error.code==api.INVALID_PARAMS && strings.contains(wrong.error.message,c.says),"%v: %s",c.setting,wrong.error.message)
        // A value it knows passes on to the import, which here has no asset folder to write into.
        known:=run(&s,c,c.known)
        testing.expectf(t,known.failed && known.error.code==api.SERVER_ERROR && strings.contains(known.error.message,"asset folder"),"%v: %s",c.setting,known.error.message)
    }
}

@(test)
asset_import_reads_a_relative_source_from_the_project :: proc(t:^testing.T) {
    s:=Session{project_root="C:/game"}
    testing.expect_value(t,asset_import_source(&s,"assets/hero/walk.glb"),"C:/game/assets/hero/walk.glb")
    testing.expect_value(t,asset_import_source(&s,"C:/elsewhere/walk.glb"),"C:/elsewhere/walk.glb")
}

// A source whose import wrote a document that changed since is not imported
// again without a word: asset.import fails naming it and how to go on, and the
// import of the content browser asks, with the documents that changed.
@(test)
importing_over_a_changed_document_asks_first :: proc(t:^testing.T) {
    root:=base.test_folder(t,"import-changed")
    if root=="" {return}
    folder:=fmt.tprintf("%s/assets",root)
    os.make_directory_all(folder)
    assets:host.Assets
    asset.types_init(&assets.types);defer asset.types_destroy(&assets.types)
    asset.registry_init(&assets.registry,folder);defer asset.registry_destroy(&assets.registry)
    hall:=base.Asset_Id{7,9}
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_init(&scene,&assets.types,hall,context.temp_allocator),asset.Error.None) {return}
    _,_=asset.scene_entity_add(&scene,asset.scene_new_id(&scene),{},"Added")
    testing.expect_value(t,asset.scene_save(&scene,fmt.tprintf("%s/hall.scene",folder)),asset.Error.None)
    asset.scene_destroy(&scene)
    source:=fmt.tprintf("%s/hall.level",folder)
    _=os.write_entire_file(source,"LEVEL")
    outputs:=make([dynamic]asset.Import_Output,context.temp_allocator)
    append(&outputs,asset.Import_Output{kind=asset.KIND_SCENE,name="hall",id=hall,written=1})
    _=os.write_entire_file(fmt.tprintf("%s.import",source),asset.sidecar_text("{}",{outputs=outputs},context.temp_allocator))
    testing.expect_value(t,asset.registry_scan(&assets.registry),asset.Error.None)

    imports:Importer
    gui:Editor_Ui
    defer delete(gui.import_changed)
    s:=Session{app=&host.App{assets=&assets},importer=&imports,gui=&gui}
    params:Import_Params
    base.text_set(params.path[:],source)
    method:=api.Method{params_id=Import_Params}
    call:=api.Call{method=&method,params=&params,allocator=context.temp_allocator}
    api_asset_import(&s,&call)
    testing.expectf(t,call.failed && strings.contains(call.error.message,"hall.scene") && strings.contains(call.error.message,"discard_changes"),"%s",call.error.message)
    testing.expect(t,gui.modal==.None,"a call asks nobody")
    testing.expect(t,!import_file(&s,source,ask=true) && imports.running==nil,"nothing is imported")
    testing.expect(t,gui.modal==.Import_Changes && len(gui.import_changed)==1 && gui.import_changed[0]==hall && base.text_get(gui.import_source[:])==source,"the user is asked, with what changed")
}
