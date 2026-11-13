package sources

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/prefab"
import "mirai:std/base"

@(test)
sources_are_known_by_their_content :: proc(t:^testing.T) {
    _,folder:=test_project(t,"sniff")
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
        {"texts.csv",transmute([]u8)string("key,es\nhello,hola\n"),.None},{"pad.prompts.json",transmute([]u8)string(`{"entries": []}`),.Prompts},
    }
    for c in cases {
        path:=fmt.tprintf("%s/%s",folder,c.name)
        _=os.write_entire_file(path,c.data)
        testing.expectf(t,source_kind(path)==c.kind,"%s is a %v source, not %v",c.name,c.kind,source_kind(path))
    }
    // A GLB is read as one whatever its name says.
    report,error:=import_source(fmt.tprintf("%s/model.bin",folder),{world=prefab.import_world(t)})
    testing.expectf(t,error.code==.None && len(report.assets)>0,"%v %s",error.code,error.message)
    importer.report_destroy(&report)
    _,refused:=import_source(fmt.tprintf("%s/mesh.txt",folder))
    testing.expect(t,refused.code==.Unsupported && strings.contains(refused.message,"glTF, USD, FBX and OBJ"),refused.message)
    _,missing:=import_source(fmt.tprintf("%s/none.obj",folder))
    testing.expect_value(t,missing.code,importer.Error_Code.Not_Found)
    // Every source has a sidecar, next to it, which keeps its id.
    picture,picture_error:=import_source(fmt.tprintf("%s/picture.dat",folder))
    testing.expect(t,picture_error.code==.None && len(picture.assets)==1 && picture.assets[0].kind==asset.KIND_TEXTURE && os.exists(fmt.tprintf("%s/picture.dat.import",folder)))
    importer.report_destroy(&picture)
    _,collection:=import_source(fmt.tprintf("%s/family.ttc",folder))
    testing.expect(t,collection.code==.Unsupported && strings.contains(collection.message,"collection"),collection.message)
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

// The path of the mesh a report wrote.
@(private="file")
mesh_of :: proc(report:^importer.Import_Report) -> (path:string,id:base.Asset_Id) {
    for written in report.assets {
        if written.kind==asset.KIND_MESH {return strings.clone(written.path,context.temp_allocator),written.id}
    }
    return
}

// What is current is decided by the name of a file of the cache alone: the key
// of what the import builds from now.
@(test)
an_import_keeps_what_its_cache_says_is_current_and_builds_again_what_changed :: proc(t:^testing.T) {
    root,_:=test_project(t,"cache")
    if root=="" {return}
    source:=copy_in(root,DEMO,"gallery/vase.obj","gallery/vase.mtl","gallery/vase_color.png")
    world:=prefab.import_world(t)
    import_kept :: proc(t:^testing.T,source:string,options:importer.Import_Options,loc:=#caller_location) -> (meshes,textures,others:int,mesh:string,id:base.Asset_Id,ok:bool) {
        report,error:=import_source(source,options)
        defer importer.report_destroy(&report)
        if !testing.expectf(t,error.code==.None,"%v %s",error.code,error.message,loc=loc) {return}
        meshes,textures,others=kept_of(&report)
        mesh,id=mesh_of(&report)
        return meshes,textures,others,mesh,id,true
    }
    meshes,textures,others,mesh_path,mesh_id,ok:=import_kept(t,source,{world=world})
    if !ok {return}
    testing.expect(t,meshes==0 && textures==0 && others==0,"a first import builds everything")
    built,_:=os.read_entire_file(mesh_path,context.temp_allocator)

    // Nothing changed: the mesh and the texture are kept; materials and the prefab, cheap, are written again.
    again_path:string
    meshes,textures,others,again_path,_,ok=import_kept(t,source,{world=world})
    again,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,ok && meshes==1 && textures==1 && others==0 && again_path==mesh_path && string(again)==string(built),"an unchanged source keeps its mesh and its texture")

    // A setting changes what everything is built from: built again, under a new name, with the same ids.
    turned_path:string
    turned_id:base.Asset_Id
    meshes,textures,_,turned_path,turned_id,ok=import_kept(t,source,{world=world,front=.X,ignore_stored=true})
    testing.expect(t,ok && meshes==0 && textures==0 && turned_id==mesh_id && turned_path!=mesh_path && !os.exists(mesh_path),"a setting builds again, and the file of before goes")

    // --rebuild keeps nothing; with the settings of the first import, it gives its bytes.
    rebuilt_path:string
    meshes,textures,others,rebuilt_path,_,ok=import_kept(t,source,{world=world,rebuild=true,ignore_stored=true})
    testing.expect(t,ok && meshes==0 && textures==0 && others==0 && rebuilt_path==mesh_path,"rebuild builds everything")
    rebuilt,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,string(rebuilt)==string(built))
}

@(test)
an_import_takes_a_texture_that_another_import_built_from_the_texture_cache :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    root,folder:=test_project(t,"texture-cache")
    if folder=="" {return}
    cache:=fmt.tprintf("%s/cache",root)
    bytes:=png_bytes(16,16,{200,100,50})
    // Each import is another image of the project, with its own id: the levels are what the cache gives.
    imported :: proc(t:^testing.T,types:^asset.Types,folder,name:string,bytes:[]u8,options:importer.Import_Options) -> (format:asset.Texture_Format,mips:int,texels:string,flags:asset.Texture_Flags) {
        image:=fmt.tprintf("%s/%s.png",folder,name)
        _=os.write_entire_file(image,bytes)
        report,error:=import_source(image,options)
        defer importer.report_destroy(&report)
        if !testing.expectf(t,error.code==.None && len(report.assets)==1,"%v %s",error.code,error.message) {return}
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,report.assets[0].path,context.temp_allocator),asset.Error.None) {return}
        view,view_error:=asset.texture_view(&a,types)
        if !testing.expect_value(t,view_error,asset.Error.None) {return}
        return view.info.format,len(view.mips),strings.clone(string(view.texels),context.temp_allocator),view.info.flags
    }
    options:=importer.Import_Options{texture_cache=cache}
    format,mips,first,_:=imported(t,&types,folder,"a",bytes,options)
    testing.expect(t,format==.BC1 && mips==5)
    entries,_:=os.read_all_directory_by_path(cache,context.temp_allocator)
    if !testing.expect_value(t,len(entries),1) {return}

    // Another import of the same image has the same levels, made from the cache.
    _,_,second,_:=imported(t,&types,folder,"b",bytes,options)
    testing.expect(t,len(first)>0 && second==first)

    // What the cache holds is what the import takes: a texture put under its key is the one written.
    kept:asset.Asset
    testing.expect_value(t,asset.asset_load(&kept,entries[0].fullpath,context.temp_allocator),asset.Error.None)
    plain:[16*16*4]u8
    testing.expect_value(t,asset.texture_save(entries[0].fullpath,&types,{id=kept.blob.header.id,width=16,height=16,format=.RGBA8,mips={plain[:]}}),asset.Error.None)
    format,mips,_,_=imported(t,&types,folder,"c",bytes,options)
    testing.expect(t,format==.RGBA8 && mips==1)

    // Rebuilding does not read the cache, and builds it again.
    rebuilt:=options
    rebuilt.rebuild=true
    format,mips,_,_=imported(t,&types,folder,"d",bytes,rebuilt)
    testing.expect(t,format==.BC1 && mips==5)
    _,_,again,_:=imported(t,&types,folder,"e",bytes,options)
    testing.expect(t,again==first)

    // The editor's import takes the Final of the cache, and builds Fast without one, for the sync of a build to encode again.
    fast:=options
    fast.fast_textures=true
    _,_,taken,_:=imported(t,&types,folder,"f",bytes,fast)
    testing.expect(t,taken==first,"the Final the cache holds")
    fast.texture_cache=fmt.tprintf("%s/empty",root)
    flags:asset.Texture_Flags
    format,_,_,flags=imported(t,&types,folder,"g",bytes,fast)
    testing.expect(t,.Fast in flags && format==.BC1,"Fast, for the sync of a build to encode again")
}

@(test)
an_import_takes_a_mesh_that_another_import_built_from_the_mesh_cache :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    root,_:=test_project(t,"mesh-cache")
    if root=="" {return}
    source:=copy_in(root,DEMO,"gallery/vase.obj","gallery/vase.mtl")
    options:=importer.Import_Options{world=prefab.import_world(t),mesh_cache=fmt.tprintf("%s/cache",root)}
    colliders :: proc(t:^testing.T,types:^asset.Types,path:string) -> int {
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,path,context.temp_allocator),asset.Error.None) {return -1}
        view,error:=asset.mesh_view(&a,types)
        if !testing.expect_value(t,error,asset.Error.None) {return -1}
        return len(view.colliders)
    }
    imported :: proc(t:^testing.T,source:string,options:importer.Import_Options) -> (mesh:string,ok:bool) {
        report,error:=import_source(source,options)
        defer importer.report_destroy(&report)
        mesh,_=mesh_of(&report)
        return mesh,testing.expectf(t,error.code==.None,"%v %s",error.code,error.message)
    }
    mesh_path,ok:=imported(t,source,options)
    if !ok {return}
    built,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    entries,_:=os.read_all_directory_by_path(options.mesh_cache,context.temp_allocator)
    if !testing.expect_value(t,len(entries),1) {return}

    // A mesh whose file is gone is built from the cache, to the same bytes.
    testing.expect(t,os.remove(mesh_path)==nil)
    if _,ok=imported(t,source,options);!ok {return}
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
    testing.expect(t,os.remove(mesh_path)==nil)
    if _,ok=imported(t,source,options);!ok {return}
    testing.expect_value(t,colliders(t,&types,mesh_path),1)

    // Rebuilding does not read the cache, and builds it again.
    rebuilt:=options
    rebuilt.rebuild=true
    if _,ok=imported(t,source,rebuilt);!ok {return}
    testing.expect_value(t,colliders(t,&types,mesh_path),0)
    testing.expect(t,os.remove(mesh_path)==nil)
    if _,ok=imported(t,source,options);!ok {return}
    last,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,string(last)==string(built))
}
