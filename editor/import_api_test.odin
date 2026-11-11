package editor

import "core:strings"
import "core:testing"
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
    testing.expect_value(t,asset_import_source(&s,"source/walk.glb"),"C:/game/source/walk.glb")
    testing.expect_value(t,asset_import_source(&s,"C:/elsewhere/walk.glb"),"C:/elsewhere/walk.glb")
}

@(test)
an_import_goes_where_it_is_asked_and_no_folder_is_named_after_its_type :: proc(t:^testing.T) {
    Case :: struct {kind:sources.Source_Kind,folder,model,expected:string}
    for c in ([]Case{{.Model,"","knight","knight"},{.Model,"characters","knight","characters/knight"},{.Image,"","",""},{.Image,"surfaces/wood","","surfaces/wood"},{.Sound,"","",""}}) {
        testing.expect_value(t,import_destination(c.kind,c.folder,c.model),c.expected)
    }
}
