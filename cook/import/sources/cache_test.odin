package sources

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/obj"
import "mirai:std/base"

@(test)
sources_are_known_by_their_content :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"sniff")
    if folder=="" {return}
    glb,_:=os.read_entire_file(FIXTURES+"hierarchy.glb",context.temp_allocator)
    gltf,_:=os.read_entire_file(FIXTURES+"single-transform.gltf",context.temp_allocator)
    usda,_:=os.read_entire_file(FIXTURES+"hierarchy.usda",context.temp_allocator)
    obj_text:="v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
    cases:=[?]struct{name:string,data:[]u8,kind:Source_Kind}{
        {"model.bin",glb,.Model},{"scene.json",gltf,.Model},{"stage.usd",usda,.Model},{"mesh.obj",transmute([]u8)obj_text,.Model},
        {"mesh.txt",transmute([]u8)obj_text,.None},{"noise.usd",transmute([]u8)string("not a stage"),.None},
        {"picture.dat",png_bytes(4,4,{9,9,9}),.Image},{"sound.bin",transmute([]u8)string("RIFF\x24\x00\x00\x00WAVEfmt "),.Sound},
        {"face.bin",#load("../../../assets/fixtures/cff.otf"),.Font},{"family.ttc",transmute([]u8)string("ttcf\x00\x02\x00\x00\x00\x00\x00\x01"),.Font},
        {"texts.csv",transmute([]u8)string("key,es\nhello,hola\n"),.Strings},{"pad.prompts.json",transmute([]u8)string(`{"entries": []}`),.Prompts},
    }
    for c in cases {
        path:=fmt.tprintf("%s/%s",folder,c.name)
        _=os.write_entire_file(path,c.data)
        testing.expectf(t,source_kind(path)==c.kind,"%s is a %v source, not %v",c.name,c.kind,source_kind(path))
    }
    // A GLB is read as one whatever its name says.
    report,error:=import_source(fmt.tprintf("%s/model.bin",folder),fmt.tprintf("%s/out",folder),{})
    testing.expectf(t,error.code==.None && len(report.assets)>0,"%v %s",error.code,error.message)
    importer.report_destroy(&report)
    _,refused:=import_source(fmt.tprintf("%s/mesh.txt",folder),fmt.tprintf("%s/out",folder))
    testing.expect(t,refused.code==.Unsupported && strings.contains(refused.message,"glTF, USD, FBX and OBJ"),refused.message)
    _,missing:=import_source(fmt.tprintf("%s/none.obj",folder),fmt.tprintf("%s/out",folder))
    testing.expect_value(t,missing.code,importer.Error_Code.Not_Found)
    // Every source has a sidecar, which keeps its id: without a root, with what it wrote and not next to it.
    texts,texts_error:=import_source(fmt.tprintf("%s/texts.csv",folder),fmt.tprintf("%s/out",folder))
    testing.expect(t,texts_error.code==.None && len(texts.assets)==1 && texts.assets[0].kind==asset.KIND_STRINGS && os.exists(fmt.tprintf("%s/out/texts.csv.import",folder)) && !os.exists(fmt.tprintf("%s/texts.csv.import",folder)))
    importer.report_destroy(&texts)
    _,collection:=import_source(fmt.tprintf("%s/family.ttc",folder),fmt.tprintf("%s/out",folder))
    testing.expect(t,collection.code==.Unsupported && strings.contains(collection.message,"collection"),collection.message)
}

// The kind_version of a file, changed in place: the header is outside its content hash.
@(private="file")
version_set :: proc(path:string,version:u16) -> bool {
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil || len(data)<asset.HEADER_SIZE {return false}
    data[10],data[11]=u8(version),u8(version>>8)
    return os.write_entire_file(path,data)==nil
}

// The mesh at path written again as it is, but for the importer version its Import_Info records.
@(private="file")
importer_version_set :: proc(path:string,version:u32) -> bool {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    a:asset.Asset
    if asset.asset_load(&a,path)!=.None {return false}
    defer asset.asset_close(&a)
    view,error:=asset.mesh_view(&a,&types)
    if error!=.None || view.source==nil {return false}
    info:=view.source^
    info.importer_version=version
    desc:=asset.Mesh_Desc{
        id=a.blob.header.id,owner=a.blob.header.owner,geometry=view.geometry,slots=view.slots,
        joints=view.joints,skeleton=view.info.skeleton,colliders=view.colliders,collision_points=view.collision_points,collision_indices=view.collision_indices,
        source=&info,
    }
    return asset.mesh_save(path,&types,desc)==.None
}

@(private="file")
kept_of :: proc(report:^importer.Import_Report) -> (meshes,textures,others:int) {
    for written in report.assets {
        if !written.kept {continue}
        switch written.kind {
        case asset.KIND_MESH: meshes+=1
        case asset.KIND_TEXTURE: textures+=1
        case: others+=1
        }
    }
    return
}

@(test)
an_import_keeps_what_its_cache_says_is_current_and_builds_again_what_changed :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"cache")
    if folder=="" {return}
    os.make_directory_all(fmt.tprintf("%s/models",folder))
    os.make_directory_all(fmt.tprintf("%s/textures",folder))
    for file in ([]string{"models/vase.obj","models/vase.mtl","textures/vase_color.png"}) {
        data,_:=os.read_entire_file(fmt.tprintf("%s%s",DEMO,file),context.temp_allocator)
        _=os.write_entire_file(fmt.tprintf("%s/%s",folder,file),data)
    }
    source:=fmt.tprintf("%s/models/vase.obj",folder)
    out:=fmt.tprintf("%s/out",folder)
    import_kept :: proc(t:^testing.T,source,out:string,options:importer.Import_Options,loc:=#caller_location) -> (meshes,textures,others:int,ok:bool) {
        report,error:=import_source(source,out,options)
        defer importer.report_destroy(&report)
        if !testing.expectf(t,error.code==.None,"%v %s",error.code,error.message,loc=loc) {return}
        meshes,textures,others=kept_of(&report)
        return meshes,textures,others,true
    }
    meshes,textures,others,ok:=import_kept(t,source,out,{})
    if !ok {return}
    testing.expect(t,meshes==0 && textures==0 && others==0,"a first import builds everything")
    mesh_path:=fmt.tprintf("%s/Vase.mesh",out)
    built,_:=os.read_entire_file(mesh_path,context.temp_allocator)

    // Nothing changed: the mesh and the texture are kept; materials and the prefab, cheap, are written again.
    meshes,textures,others,ok=import_kept(t,source,out,{})
    again,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,ok && meshes==1 && textures==1 && others==0 && string(again)==string(built),"an unchanged source keeps its mesh and its texture")

    // A mesh of another kind_version is built again.
    testing.expect(t,version_set(mesh_path,asset.MESH_VERSION-1))
    meshes,textures,_,ok=import_kept(t,source,out,{})
    redone,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,ok && meshes==0 && textures==1 && string(redone)==string(built),"a mesh of another version is built again, to the same bytes")

    // A mesh that another version of the format wrote is built again.
    testing.expect(t,importer_version_set(mesh_path,importer.import_version(obj.FORMAT.version+1)))
    meshes,_,_,ok=import_kept(t,source,out,{})
    redone,_=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,ok && meshes==0 && string(redone)==string(built),"the version of the format in Import_Info decides too")

    // A setting of the meshes builds the meshes again and keeps the textures; one of the textures, the other way round.
    meshes,textures,_,ok=import_kept(t,source,out,{collision=.Hull,ignore_stored=true})
    testing.expect(t,ok && meshes==0 && textures==1,"a setting of the meshes builds the mesh again and keeps the texture")
    hulled,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    meshes,textures,_,ok=import_kept(t,source,out,{collision=.Hull,max_texture_size=16,textures=.Uncompressed,ignore_stored=true})
    kept,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,ok && meshes==1 && textures==0 && string(kept)==string(hulled),"a setting of the textures builds the texture again and keeps the mesh")

    // --rebuild keeps nothing; with the settings of the first import, it gives its bytes.
    meshes,textures,others,ok=import_kept(t,source,out,{rebuild=true,ignore_stored=true})
    testing.expect(t,ok && meshes==0 && textures==0 && others==0,"rebuild builds everything")
    rebuilt,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,string(rebuilt)==string(built))
}

@(test)
an_import_takes_a_texture_that_another_import_built_from_the_texture_cache :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"texture-cache")
    if folder=="" {return}
    cache,image:=fmt.tprintf("%s/cache",folder),fmt.tprintf("%s/wood.png",folder)
    testing.expect(t,os.write_entire_file(image,png_bytes(16,16,{200,100,50}))==nil)
    imported :: proc(t:^testing.T,types:^asset.Types,image,out:string,options:importer.Import_Options) -> (format:asset.Texture_Format,mips:int,bytes:string) {
        report,error:=import_source(image,out,options)
        defer importer.report_destroy(&report)
        if !testing.expectf(t,error.code==.None && len(report.assets)==1,"%v %s",error.code,error.message) {return}
        data,_:=os.read_entire_file(report.assets[0].path,context.temp_allocator)
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,report.assets[0].path,context.temp_allocator),asset.Error.None) {return}
        view,view_error:=asset.texture_view(&a,types)
        if !testing.expect_value(t,view_error,asset.Error.None) {return}
        // Each import is another asset, with its own id: the content is what the cache gives.
        return view.info.format,len(view.mips),string(data[asset.HEADER_SIZE:])
    }
    options:=importer.Import_Options{texture_cache=cache}
    format,mips,first:=imported(t,&types,image,fmt.tprintf("%s/a",folder),options)
    testing.expect(t,format==.BC1 && mips==5)
    entries,_:=os.read_all_directory_by_path(cache,context.temp_allocator)
    if !testing.expect_value(t,len(entries),1) {return}

    // Into another folder the texture has the same content, made from the cache.
    _,_,second:=imported(t,&types,image,fmt.tprintf("%s/b",folder),options)
    testing.expect(t,len(first)>0 && second==first)

    // What the cache holds is what the import takes: a texture put under its key is the one written.
    kept:asset.Asset
    testing.expect_value(t,asset.asset_load(&kept,entries[0].fullpath,context.temp_allocator),asset.Error.None)
    plain:[16*16*4]u8
    testing.expect_value(t,asset.texture_save(entries[0].fullpath,&types,{id=kept.blob.header.id,width=16,height=16,format=.RGBA8,mips={plain[:]}}),asset.Error.None)
    format,mips,_=imported(t,&types,image,fmt.tprintf("%s/c",folder),options)
    testing.expect(t,format==.RGBA8 && mips==1)

    // Rebuilding does not read the cache, and builds it again.
    rebuilt:=options
    rebuilt.rebuild=true
    format,mips,_=imported(t,&types,image,fmt.tprintf("%s/d",folder),rebuilt)
    testing.expect(t,format==.BC1 && mips==5)
    _,_,again:=imported(t,&types,image,fmt.tprintf("%s/e",folder),options)
    testing.expect(t,again==first)

    // The editor's import takes the Final of the cache, and builds Fast without one.
    fast:=options
    fast.fast_textures=true
    _,_,taken:=imported(t,&types,image,fmt.tprintf("%s/f",folder),fast)
    testing.expect(t,taken==first,"the Final the cache holds")
    // Only in the imported folder of a project, where the sync of a build makes it Final.
    fast.texture_cache=fmt.tprintf("%s/empty",folder)
    fast.root=folder
    os.make_directory_all(fmt.tprintf("%s/source",folder))
    bytes,_:=os.read_entire_file(image,context.temp_allocator)
    of_project:=fmt.tprintf("%s/source/g.png",folder)
    testing.expect(t,os.write_entire_file(of_project,bytes)==nil)
    report,error:=import_source(of_project,"",fast)
    defer importer.report_destroy(&report)
    if testing.expectf(t,error.code==.None && len(report.assets)==1,"%v %s",error.code,error.message) {
        a:asset.Asset
        testing.expect_value(t,asset.asset_load(&a,report.assets[0].path,context.temp_allocator),asset.Error.None)
        view,view_error:=asset.texture_view(&a,&types)
        testing.expect(t,view_error==.None && .Fast in view.info.flags && view.info.format==.BC1 && strings.contains(report.assets[0].path,"/.mirai/imported/"),"Fast, for the sync of a build to encode again")
    }
}

@(test)
an_import_takes_a_mesh_that_another_import_built_from_the_mesh_cache :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"mesh-cache")
    if folder=="" {return}
    os.make_directory_all(fmt.tprintf("%s/models",folder))
    for file in ([]string{"models/vase.obj","models/vase.mtl"}) {
        data,_:=os.read_entire_file(fmt.tprintf("%s%s",DEMO,file),context.temp_allocator)
        _=os.write_entire_file(fmt.tprintf("%s/%s",folder,file),data)
    }
    source,out:=fmt.tprintf("%s/models/vase.obj",folder),fmt.tprintf("%s/out",folder)
    mesh_path:=fmt.tprintf("%s/Vase.mesh",out)
    options:=importer.Import_Options{mesh_cache=fmt.tprintf("%s/cache",folder)}
    colliders :: proc(t:^testing.T,types:^asset.Types,path:string) -> int {
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,path,context.temp_allocator),asset.Error.None) {return -1}
        view,error:=asset.mesh_view(&a,types)
        if !testing.expect_value(t,error,asset.Error.None) {return -1}
        return len(view.colliders)
    }
    imported :: proc(t:^testing.T,source,out:string,options:importer.Import_Options) -> bool {
        report,error:=import_source(source,out,options)
        importer.report_destroy(&report)
        return testing.expectf(t,error.code==.None,"%v %s",error.code,error.message)
    }
    if !imported(t,source,out,options) {return}
    built,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    entries,_:=os.read_all_directory_by_path(options.mesh_cache,context.temp_allocator)
    if !testing.expect_value(t,len(entries),1) {return}

    // A mesh that is not kept is built from the cache, to the same bytes.
    testing.expect(t,version_set(mesh_path,asset.MESH_VERSION-1))
    if !imported(t,source,out,options) {return}
    again,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,len(built)>0 && string(again)==string(built),"what the cache gives is what building gives")

    // What the cache holds is what the import takes: a mesh put under its key, with a collider, is the one written.
    cached:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&cached,entries[0].fullpath,context.temp_allocator),asset.Error.None) {return}
    view,view_error:=asset.mesh_view(&cached,&types)
    if !testing.expect_value(t,view_error,asset.Error.None) {return}
    points:=[4][3]f32{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    hull:=[1]asset.Collider{{kind=.Hull,rotation=1,point_count=4}}
    desc:=asset.Mesh_Desc{id=cached.blob.header.id,geometry=view.geometry,slots=view.slots,colliders=hull[:],collision_points=points[:]}
    testing.expect_value(t,asset.mesh_save(entries[0].fullpath,&types,desc),asset.Error.None)
    testing.expect(t,version_set(mesh_path,asset.MESH_VERSION-1))
    if !imported(t,source,out,options) {return}
    testing.expect_value(t,colliders(t,&types,mesh_path),1)

    // Rebuilding does not read the cache, and builds it again.
    rebuilt:=options
    rebuilt.rebuild=true
    if !imported(t,source,out,rebuilt) {return}
    testing.expect_value(t,colliders(t,&types,mesh_path),0)
    testing.expect(t,version_set(mesh_path,asset.MESH_VERSION-1))
    if !imported(t,source,out,options) {return}
    last,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,string(last)==string(built))
}
