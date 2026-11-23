package sources

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import importer "mirai:cook/import"
import "mirai:cook/prefab"
import "mirai:store"

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
    report,error:=write_into(t,&model,fmt.tprintf("%s/out",folder),{front=.X})
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
    testing.expect(t,view.source!=nil && view.source.settings_hash==importer.mesh_build_hash(model.settings) && view.source.settings_hash!=importer.mesh_build_hash({}),"the asset names the settings it was made with")
    testing.expect(t,int(view.info.vertex_count)==len(view.vertices) && view.levels[0].triangle_count<view.info.triangle_count)
}

// The settings a source is ingested with are kept in its package: importing
// it again uses them, whatever the options say, unless they are set now; a
// package whose settings this build does not read is refused, never the
// defaults.
@(test)
the_package_of_a_source_keeps_its_settings_and_importing_again_uses_them :: proc(t:^testing.T) {
    root,folder:=test_project(t,"settings")
    if folder=="" {return}
    source:=sphere_obj(folder)
    options:=test_options(t,source,{root=root,world=prefab.import_world(t)})
    stored,found,load_error:=importer.settings_load(options,source)
    testing.expect(t,!found && load_error.code==.None && stored=={},"a source never ingested has the defaults")
    wanted:=importer.Import_Settings{textures=.Uncompressed,rdo_lambda=-1,lods=.None,front=.X}
    chosen:=options
    chosen.settings=wanted
    first,error:=import_source(source,chosen)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.report_destroy(&first)
    p,read_error:=asset.package_get(options.store,first.manifest,context.temp_allocator)
    testing.expect_value(t,read_error,asset.Error.None)
    testing.expect(t,strings.contains(p.settings,"\"lods\": \"None\"") && strings.contains(p.settings,"\"textures\": \"Uncompressed\"") && strings.contains(p.settings,"\"rdo_lambda\": -1") && !strings.contains(p.settings,"rig"),p.settings)
    stored,found,load_error=importer.settings_load(options,source)
    testing.expect(t,found && load_error.code==.None && stored==wanted)

    // The stored settings are the ones of the import, whatever the options say.
    told:=options
    told.front=.Z
    model,ok:=import_ok(t,source,told)
    if !ok {return}
    testing.expect_value(t,model.settings,wanted)
    importer.model_destroy(&model)
    // Unless whoever imports sets them now.
    told.ignore_stored=true
    model,ok=import_ok(t,source,told)
    if !ok {return}
    testing.expect_value(t,model.settings,importer.Import_Settings{front=.Z})
    importer.model_destroy(&model)

    // Settings nobody wrote are refused, not the defaults: a value an import does not know,
    // out of its range, a field it does not have, heights without the rig they go with.
    for broken in ([]string{"{\"lods\": \"Sometimes\"}","{\"scale\": 2}","{","{\"rdo_lambda\": 1000}","{\"alpha_coverage\": 1.5}","{\"alpha_coverage\": \"nan\"}","{\"rig\": \"Fox\", \"rig_crotch\": 0.9}"}) {
        _,valid:=importer.settings_parse(broken)
        testing.expectf(t,!valid,"%s is refused",broken)
    }
    // A package that keeps them refuses its import.
    kept:=p
    kept.settings="{\"lods\": \"Sometimes\"}"
    manifest,put_error:=asset.package_put(options.store,&kept)
    testing.expect_value(t,put_error,asset.Error.None)
    pinned:=options
    pinned.manifest=manifest
    _,import_error:=importer.import_model(source,FORMATS[:],pinned)
    testing.expect_value(t,import_error.code,importer.Error_Code.Malformed)
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
    first,first_error:=importer.import_texture(path,test_options(t,path,{root=root,image=.Normal,textures=.Uncompressed}))
    if !testing.expectf(t,first_error.code==.None,"%s",first_error.message) {return}
    importer.report_destroy(&first)
    options:=test_options(t,path,{root=root,image=.Color})
    report,error:=importer.import_texture(path,options)
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.None)
    if error.code!=.None {return}
    testing.expect(t,report.assets[0].id!={})
    testing.expect(t,strings.contains(report.assets[0].detail,"8x8"),report.assets[0].detail)
    testing.expect_value(t,report.settings,importer.Import_Settings{image=.Normal,textures=.Uncompressed})
    p,_:=asset.package_get(options.store,report.manifest,context.temp_allocator)
    testing.expect(t,strings.contains(p.settings,`"image": "Normal"`) && strings.contains(p.settings,`"textures": "Uncompressed"`) && !strings.contains(p.settings,"lods"),p.settings)
}

@(test)
the_coverage_of_a_standalone_image_is_a_setting_its_package_keeps :: proc(t:^testing.T) {
    _,folder:=test_project(t,"image-coverage")
    if folder=="" {return}
    path:=fmt.tprintf("%s/leaves.png",folder)
    _=os.write_entire_file(path,png_bytes(16,16,{40,120,30},masked=true))
    import_image :: proc(t:^testing.T,path:string,options:importer.Import_Options,loc:=#caller_location) -> (written:importer.Written,coverage:f32,ok:bool) {
        report,error:=import_test(t,path,options)
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
    stored,found,_:=importer.settings_load(test_options(t,path),path)
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
    report,error:=write_into(t,&model,out)
    defer importer.report_destroy(&report)
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)
    testing.expectf(t,strings.contains(error.message,"not a number") && strings.contains(error.message,model.meshes[0].name),"%q",error.message)
    s:=test_store(t,fmt.tprintf("%s/store",out))
    refs,_:=store.ref_list(s,asset.REF_PACKAGES,context.temp_allocator)
    testing.expect(t,len(refs)==0,"a failed import names no package")
}

// The colliders of a mesh in its written asset, by kind.
@(private="file")
written_colliders :: proc(t:^testing.T,report:^importer.Import_Report) -> (colliders:[]asset.Collider,points:int) {
    types:asset.Types;asset.types_init(&types,context.temp_allocator);defer asset.types_destroy(&types)
    for written in report.assets {
        if written.kind!=asset.KIND_MESH {continue}
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,written.path),asset.Error.None) {return}
        defer asset.asset_close(&a)
        view,view_error:=asset.mesh_view(&a,&types)
        if !testing.expect_value(t,view_error,asset.Error.None) {return}
        held:=make([]asset.Collider,len(view.colliders),context.temp_allocator)
        copy(held,view.colliders)
        return held,len(view.collision_points)
    }
    return
}

// Colliders a person authored for a mesh live in the settings of the package
// of its source: every import of the source makes them again on the mesh it
// builds, which stays an object of the cache like any other mesh; a reimport
// with no options keeps them, and settings with a collider an import cannot
// make are refused.
@(test)
the_colliders_the_settings_give_a_mesh_come_back_with_every_import :: proc(t:^testing.T) {
    root,folder:=test_project(t,"collider-settings")
    if folder=="" {return}
    testing.expect(t,asset.import_cached(asset.KIND_MESH),"a mesh is of the cache: nothing edits it after the import")
    source:=sphere_obj(folder)
    wanted:importer.Import_Settings
    box:=&wanted.colliders[0]
    base.text_set(box.mesh[:],"Ball")
    box.shape,box.center,box.size=.Box,{0,1,0},{1,2,3}
    hull:=&wanted.colliders[1]
    base.text_set(hull.mesh[:],"Ball")
    hull.shape,hull.point_count=.Points,4
    hull.points[0],hull.points[1],hull.points[2],hull.points[3]={0,0,0},{2,0,0},{0,2,0},{0,0,2}
    options:=test_options(t,source,{root=root,world=prefab.import_world(t)})
    chosen:=options
    chosen.settings=wanted
    first,error:=import_source(source,chosen)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.report_destroy(&first)
    objects_written(options.store,&first)
    p,_:=asset.package_get(options.store,first.manifest,context.temp_allocator)
    testing.expect(t,strings.contains(p.settings,"colliders"),p.settings)
    check :: proc(t:^testing.T,report:^importer.Import_Report,loc:=#caller_location) {
        colliders,points:=written_colliders(t,report)
        testing.expectf(t,len(colliders)==2,"the box and the hull, in place of none: %v",colliders,loc=loc)
        if len(colliders)!=2 {return}
        testing.expect(t,colliders[0].kind==.Box && colliders[0].center=={0,1,0} && colliders[0].size=={1,2,3},loc=loc)
        testing.expect(t,colliders[1].kind==.Hull && colliders[1].point_count==4 && points==4,loc=loc)
    }
    check(t,&first)

    // Imported again, built anew, with the settings of no one: the package keeps them.
    again:=options
    again.rebuild=true
    second,second_error:=import_source(source,again)
    if !testing.expectf(t,second_error.code==.None,"%s",second_error.message) {return}
    defer importer.report_destroy(&second)
    objects_written(options.store,&second)
    check(t,&second)

    // A collider that names no mesh of the source is warned of.
    lost:=wanted
    base.text_set(lost.colliders[2].mesh[:],"Crate")
    lost.colliders[2].shape=.Hull
    model,ok:=import_ok(t,source,{settings=lost,ignore_stored=true})
    if ok {
        warned:=false
        for warning in model.warnings {warned||=strings.contains(warning,"Crate")}
        testing.expectf(t,warned,"%v",model.warnings)
        importer.model_destroy(&model)
    }
    for broken in ([]string{`{"colliders": [{"mesh": "Ball", "shape": "Box"}]}`,`{"colliders": [{"shape": "Hull"}]}`,`{"colliders": [{"mesh": "Ball", "shape": "Points", "point_count": 3}]}`}) {
        _,valid:=importer.settings_parse(broken)
        testing.expectf(t,!valid,"%s is refused",broken)
    }
    testing.expect(t,importer.mesh_settings_hash(wanted)!=importer.mesh_settings_hash({}),"a mesh records the colliders it was given")
}
