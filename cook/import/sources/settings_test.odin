package sources

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import importer "mirai:cook/import"

// An OBJ of a sphere, smooth, with texture coordinates.
@(private="file")
sphere_obj :: proc(folder:string) -> string {
    sphere:geom.Mesh_Buffer
    geom.mesh_buffer_init(&sphere,context.temp_allocator)
    geom.sphere_build(&sphere,1,48,24)
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"o Ball\n")
    for position in sphere.positions {fmt.sbprintf(&b,"v %f %f %f\n",position.x,position.y,position.z)}
    for uv in sphere.uvs {fmt.sbprintf(&b,"vt %f %f\n",uv.x,uv.y)}
    for normal in sphere.normals {fmt.sbprintf(&b,"vn %f %f %f\n",normal.x,normal.y,normal.z)}
    for triangle in 0..<len(sphere.indices)/3 {
        a,b_,c:=sphere.indices[triangle*3]+1,sphere.indices[triangle*3+1]+1,sphere.indices[triangle*3+2]+1
        fmt.sbprintf(&b,"f %d/%d/%d %d/%d/%d %d/%d/%d\n",a,a,a,b_,b_,b_,c,c,c)
    }
    return write_text(folder,"ball.obj",strings.to_string(b))
}

@(test)
a_source_without_colliders_gives_a_mesh_of_levels_without_any :: proc(t:^testing.T) {
    _,folder:=test_project(t,"levels")
    if folder=="" {return}
    source:=sphere_obj(folder)
    model,ok:=import_ok(t,source,{front=.X})
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect(t,model.settings.front==.X && !model.stored)
    report,error:=write_into(&model,fmt.tprintf("%s/out",folder),{front=.X})
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    if error.code!=.None || len(report.assets)==0 {return}
    written:=report.assets[len(report.assets)-1]
    testing.expect_value(t,written.kind,asset.KIND_MESH)
    testing.expect(t,strings.has_suffix(written.detail," triangles"),written.detail)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&a,written.path),asset.Error.None) {return}
    defer asset.asset_close(&a)
    view,view_error:=asset.mesh_view(&a,&types)
    testing.expect_value(t,view_error,asset.Error.None)
    testing.expect(t,asset.mesh_check_indices(view))
    // A static mesh is a DAG: the detail names the triangles of each of its levels.
    testing.expect(t,len(view.levels)>2 && .Levels not_in view.info.flags)
    testing.expect(t,strings.count(written.detail,"/")==len(view.levels)-1,written.detail)
    testing.expect(t,len(view.colliders)==0 && len(view.collision_points)==0,"the import makes no collider the source does not give")
    testing.expect(t,view.source!=nil && view.source.settings_hash==importer.mesh_settings_hash(model.settings) && view.source.settings_hash!=importer.mesh_settings_hash({}),"the asset names the settings it was made with")
    testing.expect(t,int(view.info.vertex_count)==len(view.vertices) && view.levels[0].triangle_count<view.info.triangle_count)
}

@(test)
the_sidecar_of_a_source_keeps_its_settings_and_importing_again_uses_them :: proc(t:^testing.T) {
    root,folder:=test_project(t,"settings")
    if folder=="" {return}
    source:=sphere_obj(folder)
    file:=fmt.tprintf("%s.import",source)
    stored,found,load_error:=importer.settings_load(source)
    testing.expect(t,!found && load_error.code==.None && stored=={},"a source without a sidecar has the defaults")
    wanted:=importer.Import_Settings{textures=.Uncompressed,rdo_lambda=-1,image=.Normal,alpha_coverage=0.5,lods=.None,rig=.Spider}
    testing.expect(t,importer.sidecar_save(source,{settings=wanted}))
    text,_:=os.read_entire_file(file,context.temp_allocator)
    testing.expect(t,strings.contains(string(text),"\"lods\": \"None\"") && strings.contains(string(text),"\"rig\": \"Spider\"") && strings.contains(string(text),"\"textures\": \"Uncompressed\"") && strings.contains(string(text),"\"alpha_coverage\": 0.5") && strings.contains(string(text),"\"rdo_lambda\": -1"),string(text))
    stored,found,load_error=importer.settings_load(source)
    testing.expect(t,found && load_error.code==.None && stored==wanted)
    // The same sidecar is not written again.
    before,_:=os.modification_time_by_path(file)
    testing.expect(t,importer.sidecar_save(source,{settings=wanted}))
    after,_:=os.modification_time_by_path(file)
    testing.expect_value(t,after,before)

    // The stored settings are the ones of the import, whatever the options say.
    model,ok:=import_ok(t,source,{front=.X})
    if !ok {return}
    testing.expect_value(t,model.settings,wanted)
    report,error:=write_into(&model,root,{front=.X})
    testing.expect_value(t,error.code,importer.Error_Code.None)
    if error.code==.None {
        detail:=report.assets[len(report.assets)-1].detail
        testing.expect(t,!strings.contains(detail,"/"),detail)
        importer.report_destroy(&report)
    }
    importer.model_destroy(&model)
    // Unless whoever imports sets them now.
    model,ok=import_ok(t,source,{front=.X,ignore_stored=true})
    if !ok {return}
    testing.expect_value(t,model.settings,importer.Import_Settings{front=.X})
    importer.model_destroy(&model)

    // A sidecar nobody wrote is an error, not the defaults nor other ids: settings an import
    // does not know, a text of another version or of none, an output without an id, one id
    // twice, a part that is not of the cache, a field no sidecar has, a folder out of the one
    // of the source.
    ID :: "\"id\": \"00000000000000010000000000000002\""
    whole :: proc(settings,outputs:string) -> string {return fmt.tprintf("{{\"version\": 3, \"settings\": %s, \"outputs\": [%s]}}",settings,outputs)}
    for broken in ([]string{
        whole("{\"lods\": \"Sometimes\"}",""),whole("{\"scale\": 2}",""),"{",whole("{\"rdo_lambda\": 1000}",""),whole("{\"alpha_coverage\": 1.5}",""),whole("{\"alpha_coverage\": \"nan\"}",""),whole("{\"rig\": \"Fox\", \"rig_crotch\": 0.9}",""),
        "{}","{\"lods\": \"None\"}","{\"version\": 2, \"settings\": {}, \"outputs\": []}",
        "{\"version\": 3, \"settings\": {}, \"folder\": \"../up\", \"outputs\": []}","{\"version\": 3, \"settings\": {}, \"folder\": \"/root\", \"outputs\": []}",
        whole("{}","{\"kind\": \"MESH\", \"name\": \"Ball\", \"index\": 0}"),
        whole("{}",fmt.tprintf("{{\"kind\": \"MESH\", \"name\": \"Ball\", \"index\": 0, %s}}, {{\"kind\": \"MAT\", \"name\": \"Skin\", \"index\": 0, %s}}",ID,ID)),
        whole("{}",fmt.tprintf("{{\"kind\": \"MAT\", \"name\": \"Skin\", \"index\": 0, %s, \"part\": true}}",ID)),
        whole("{}",fmt.tprintf("{{\"kind\": \"MESH\", \"name\": \"Ball\", \"index\": 0, %s, \"path\": \"Ball.mesh\"}}",ID)),
    }) {
        write_text(folder,"ball.obj.import",broken)
        _,_,broken_error:=importer.settings_load(source)
        testing.expectf(t,broken_error.code==.Malformed,"%s is refused",broken)
        _,import_error:=importer.import_model(source,FORMATS[:])
        testing.expect_value(t,import_error.code,importer.Error_Code.Malformed)
    }
    write_text(folder,"ball.obj.import",whole("{}",""))
    stored,found,load_error=importer.settings_load(source)
    testing.expect(t,found && load_error.code==.None && stored=={},"a setting that is not named has its default")
}

@(test)
a_mesh_records_only_the_settings_it_is_built_from :: proc(t:^testing.T) {
    hash:=importer.mesh_settings_hash
    testing.expect(t,hash({textures=.Uncompressed,image=.Normal,alpha_coverage=0.5})==hash({}),"the settings of textures and images do not build a mesh")
    testing.expect(t,hash({lods=.None})!=hash({}) && hash({front=.X})!=hash({}),"levels and the front do")
    testing.expect(t,hash({rig=.Humanoid})!=hash({}) && hash({rig=.Humanoid,rig_crotch=0.9})!=hash({rig=.Humanoid}),"and a rig that weights it, with what it is told of the body")
    testing.expect(t,hash({rig=.Fox})!=hash({rig=.Humanoid}) && hash({rig=.Fox})!=hash({rig=.Horse}),"each template its own")
    testing.expect(t,hash({rig=.Source,rig_crotch=0.9})==hash({}),"which means nothing to the rig of the source")
}

@(test)
a_standalone_image_takes_its_use_from_its_settings :: proc(t:^testing.T) {
    root,folder:=test_project(t,"image-settings")
    if folder=="" {return}
    path:=fmt.tprintf("%s/normal.png",folder)
    _=os.write_entire_file(path,png_bytes(8,8,{128,128,255}))
    testing.expect(t,importer.sidecar_save(path,{settings={image=.Normal,textures=.Uncompressed}}))
    report,error:=importer.import_texture(path,{root=root,image=.Color})
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    if error.code!=.None {return}
    testing.expect(t,report.assets[0].id!={})
    testing.expect(t,strings.contains(report.assets[0].detail,"8x8"),report.assets[0].detail)
    testing.expect_value(t,report.settings,importer.Import_Settings{image=.Normal,textures=.Uncompressed})
    text,_:=os.read_entire_file(fmt.tprintf("%s%s",path,importer.SIDECAR_EXTENSION),context.temp_allocator)
    testing.expect(t,strings.contains(string(text),`"image": "Normal"`) && strings.contains(string(text),`"textures": "Uncompressed"`) && !strings.contains(string(text),"lods"),string(text))
}

@(test)
the_coverage_of_a_standalone_image_is_a_setting_its_sidecar_keeps :: proc(t:^testing.T) {
    _,folder:=test_project(t,"image-coverage")
    if folder=="" {return}
    path:=fmt.tprintf("%s/leaves.png",folder)
    _=os.write_entire_file(path,png_bytes(16,16,{40,120,30},masked=true))
    import_image :: proc(t:^testing.T,path:string,options:importer.Import_Options,loc:=#caller_location) -> (written:importer.Written,coverage:f32,ok:bool) {
        report,error:=import_source(path,options)
        defer importer.report_destroy(&report)
        if !testing.expectf(t,error.code==.None && len(report.assets)==1,"%v %s",error.code,error.message,loc=loc) {return}
        written=report.assets[0]
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,written.path),asset.Error.None,loc=loc) {return}
        defer asset.asset_close(&a)
        view,view_error:=asset.texture_view(&a,&types)
        if !testing.expect_value(t,view_error,asset.Error.None,loc=loc) {return}
        return written,view.info.alpha_coverage,true
    }
    first,coverage,ok:=import_image(t,path,{image=.Color,alpha_coverage=0.5})
    if !ok {return}
    testing.expect_value(t,coverage,f32(0.5))
    stored,found,_:=importer.settings_load(path)
    testing.expect(t,found && stored==importer.Import_Settings{image=.Color,alpha_coverage=0.5},"the coverage is saved with the use of the image")
    // Whoever imports it again, without knowing the material that shows it, gets the same texture.
    again,kept_coverage,kept_ok:=import_image(t,path,{})
    testing.expect(t,kept_ok && again.kept && again.id==first.id && kept_coverage==0.5,"importing again with the stored settings keeps the texture")
}

@(test)
a_vertex_that_is_not_a_number_fails_its_model_with_a_message :: proc(t:^testing.T) {
    _,folder:=test_project(t,"not_a_number")
    if folder=="" {return}
    model,ok:=import_ok(t,sphere_obj(folder),{})
    if !ok {return}
    defer importer.model_destroy(&model)
    model.meshes[0].vertices[5].position.y=transmute(f32)u32(0x7fc00000)
    out:=fmt.tprintf("%s/out",folder)
    report,error:=write_into(&model,out)
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)
    testing.expectf(t,strings.contains(error.message,"not a number") && strings.contains(error.message,model.meshes[0].name),"%q",error.message)
    entries,_:=os.read_all_directory_by_path(fmt.tprintf("%s/.mirai/imported",out),context.temp_allocator)
    for entry in entries {testing.expectf(t,!strings.has_suffix(entry.name,".mesh"),"%s stays after the failure",entry.name)}
}
