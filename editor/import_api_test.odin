package editor

import "core:strings"
import "core:testing"
import "mirai:cook/import/sources"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"

// asset.import takes what an image holds by name (color, data, normal,
// normal_green_down) and says what it takes when given another.
@(test)
asset_import_takes_the_use_of_an_image_by_name :: proc(t:^testing.T) {
    imports:Importer
    s:=Session{app=&host.App{},importer=&imports}
    run :: proc(s:^Session,image:string) -> api.Call {
        params:Import_Params
        base.text_set(params.path[:],"T_Katana_MR.png")
        base.text_set(params.image[:],image)
        method:=api.Method{params_id=Import_Params}
        call:=api.Call{method=&method,params=&params,allocator=context.temp_allocator}
        api_asset_import(s,&call)
        call.method,call.params=nil,nil
        return call
    }
    wrong:=run(&s,"metallic")
    testing.expect(t,wrong.failed && wrong.error.code==api.INVALID_PARAMS && strings.contains(wrong.error.message,"data"),wrong.error.message)
    // A known use passes on to the import, which here has no asset folder to write into.
    known:=run(&s,"Data")
    testing.expect(t,known.failed && known.error.code==api.SERVER_ERROR && strings.contains(known.error.message,"asset folder"),known.error.message)
}

// asset.import takes the skeleton a model's clips go on by its id and refuses what is not one.
@(test)
asset_import_takes_the_skeleton_of_the_clips_by_its_id :: proc(t:^testing.T) {
    imports:Importer
    s:=Session{app=&host.App{},importer=&imports}
    run :: proc(s:^Session,skeleton:string) -> api.Call {
        params:Import_Params
        base.text_set(params.path[:],"walk.glb")
        base.text_set(params.skeleton[:],skeleton)
        method:=api.Method{params_id=Import_Params}
        call:=api.Call{method=&method,params=&params,allocator=context.temp_allocator}
        api_asset_import(s,&call)
        call.method,call.params=nil,nil
        return call
    }
    wrong:=run(&s,"crusader")
    testing.expect(t,wrong.failed && wrong.error.code==api.INVALID_PARAMS && strings.contains(wrong.error.message,"skeleton"),wrong.error.message)
    // An id passes on to the import, which here has no asset folder to write into.
    known:=run(&s,"0123456789abcdef0123456789abcdef")
    testing.expect(t,known.failed && known.error.code==api.SERVER_ERROR && strings.contains(known.error.message,"asset folder"),known.error.message)
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
