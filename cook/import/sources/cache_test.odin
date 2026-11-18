package sources

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:cook/cache"
import importer "mirai:cook/import"
import "mirai:cook/prefab"
import "mirai:cook/textures"
import "mirai:std/base"
import "mirai:store"

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
    report,error:=import_test(t,fmt.tprintf("%s/model.bin",folder),{world=prefab.import_world(t)})
    testing.expectf(t,error.code==.None && len(report.assets)>0,"%v %s",error.code,error.message)
    importer.report_destroy(&report)
    _,refused:=import_test(t,fmt.tprintf("%s/mesh.txt",folder))
    testing.expect(t,refused.code==.Unsupported && strings.contains(refused.message,"glTF, USD, FBX and OBJ"),refused.message)
    _,missing:=import_test(t,fmt.tprintf("%s/none.obj",folder))
    testing.expect_value(t,missing.code,importer.Error_Code.Not_Found)
    // An image is known by its bytes, and nothing is written beside it.
    picture,picture_error:=import_test(t,fmt.tprintf("%s/picture.dat",folder))
    testing.expect(t,picture_error.code==.None && len(picture.assets)==1 && picture.assets[0].kind==asset.KIND_TEXTURE && !os.exists(fmt.tprintf("%s/picture.dat.import",folder)))
    importer.report_destroy(&picture)
    _,collection:=import_test(t,fmt.tprintf("%s/family.ttc",folder))
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

// The path and id of the asset of kind a report wrote.
@(private="file")
written_of :: proc(report:^importer.Import_Report,kind:asset.Fourcc=asset.KIND_MESH) -> (path:string,id:base.Asset_Id) {
    for written in report.assets {
        if written.kind==kind {return strings.clone(written.path,context.temp_allocator),written.id}
    }
    return
}

// Records in the file at path that it was built with settings, as one that
// other encoders or another builder made; gives what it recorded.
@(private="file")
built_with :: proc(t:^testing.T,path:string,settings:u64) -> (was:u64) {
    doc:asset.Document
    if !testing.expect_value(t,asset.document_load(&doc,path),asset.Error.None) {return}
    defer asset.document_destroy(&doc)
    table,found:=asset.document_table(&doc,asset.TABLE_IMPORT)
    if !testing.expect(t,found && doc.tables[table].columns[0].size==size_of(asset.Import_Info)) {return}
    info:=&mem.slice_data_cast([]asset.Import_Info,doc.tables[table].columns[0].data)[0]
    was,info.settings_hash=info.settings_hash,settings
    testing.expect_value(t,asset.document_save(&doc,path),asset.Error.None)
    return
}

// What is current is a blob a build of the package has: the build of the key
// of what the import is made from now, else the one this machine chose for
// its previous manifest, when what the blob records it was built from is what
// it would be built from now.
@(test)
an_import_keeps_what_its_builds_say_is_current_and_builds_again_what_changed :: proc(t:^testing.T) {
    root,_:=test_project(t,"cache")
    if root=="" {return}
    source:=copy_in(root,DEMO,"gallery/vase.obj","gallery/vase.mtl","gallery/vase_color.png")
    world:=prefab.import_world(t)
    s:=test_store(t,fmt.tprintf("%s/store",root))
    if s==nil {return}
    Kept :: struct {meshes,textures,others:int,mesh,texture:string,id:base.Asset_Id,manifest,build:store.Hash}
    import_kept :: proc(t:^testing.T,source:string,options:importer.Import_Options,loc:=#caller_location) -> (k:Kept,ok:bool) {
        report,error:=import_test(t,source,options)
        defer importer.report_destroy(&report)
        if !testing.expectf(t,error.code==.None,"%v %s",error.code,error.message,loc=loc) {return}
        k.meshes,k.textures,k.others=kept_of(&report)
        k.mesh,k.id=written_of(&report)
        k.texture,_=written_of(&report,asset.KIND_TEXTURE)
        k.manifest,k.build=report.manifest,report.build
        return k,true
    }
    first,ok:=import_kept(t,source,{world=world,store=s})
    if !ok {return}
    testing.expect(t,first.meshes==0 && first.textures==0 && first.others==0,"a first import builds everything")
    built,_:=os.read_entire_file(first.mesh,context.temp_allocator)
    texture,_:=os.read_entire_file(first.texture,context.temp_allocator)
    same :: proc(path:string,bytes:[]u8) -> bool {
        now,_:=os.read_entire_file(path,context.temp_allocator)
        return len(bytes)>0 && string(now)==string(bytes)
    }

    // Nothing changed: the mesh and the texture are kept; materials and the prefab, cheap, are written again.
    again:Kept
    again,ok=import_kept(t,source,{world=world,store=s})
    testing.expect(t,ok && again.meshes==1 && again.textures==1 && again.others==0 && again.mesh==first.mesh && same(first.mesh,built),"an unchanged source keeps its mesh and its texture")

    // Another code that imports it (that of a plugin that imports it whole) is another key, and
    // the same mesh and image: the blobs of the build before are taken, not built.
    coded:Kept
    coded,ok=import_kept(t,source,{world=world,store=s,importer_code=1})
    testing.expect(t,ok && coded.meshes==1 && coded.textures==1 && coded.id==first.id && coded.mesh==first.mesh && coded.texture==first.texture,"a blob of another key is taken")

    // One that records other encoders (a texture) or another builder (a mesh) is built again.
    b,read_error:=asset.build_get(s,coded.build,context.temp_allocator)
    p,_:=asset.package_get(s,coded.manifest,context.temp_allocator)
    if !testing.expect_value(t,read_error,asset.Error.None) {return}
    recorded:[2]u64
    for &o in b.outputs {
        if o.kind!=asset.KIND_MESH && o.kind!=asset.KIND_TEXTURE {continue}
        blob,_:=store.blob_path(s,o.blob,context.temp_allocator)
        data,_:=os.read_entire_file(blob,context.temp_allocator)
        other:=fmt.tprintf("%s/other",root)
        _=os.write_entire_file(other,data)
        recorded[int(o.kind==asset.KIND_TEXTURE)]=built_with(t,other,1)
        o.blob,_=store.put_file(s,other)
    }
    forged,_:=asset.build_put(s,&b)
    digits:[64]u8
    store.ref_set(s,asset.REF_BUILDS,store.hex(asset.build_select(coded.manifest,&p),&digits),forged)
    other:Kept
    other,ok=import_kept(t,source,{world=world,store=s,importer_code=2})
    testing.expect(t,ok && other.meshes==0 && other.textures==0,"what other encoders or another builder made is built again")
    testing.expect(t,same(other.mesh,built) && same(other.texture,texture) && recorded[0]!=1 && recorded[1]!=1,"to the bytes of now")

    // A setting of the mesh builds it again, another blob with the same id; the texture is
    // built from the same image and settings and is taken.
    turned:Kept
    turned,ok=import_kept(t,source,{world=world,store=s,front=.X,ignore_stored=true})
    testing.expect(t,ok && turned.meshes==0 && turned.textures==1 && turned.id==first.id && turned.mesh!=other.mesh && os.exists(other.mesh),"a setting builds again, and the blob of before stays in the store")

    // --rebuild keeps nothing; with the settings of the first import, it gives its bytes.
    rebuilt:Kept
    rebuilt,ok=import_kept(t,source,{world=world,store=s,rebuild=true,ignore_stored=true})
    testing.expect(t,ok && rebuilt.meshes==0 && rebuilt.textures==0 && rebuilt.others==0 && rebuilt.mesh==first.mesh,"rebuild builds everything")
    testing.expect(t,same(first.mesh,built))
}

@(test)
an_import_takes_a_texture_that_another_import_built_from_the_texture_cache :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    root,folder:=test_project(t,"texture-cache")
    if folder=="" {return}
    kept:=test_store(t,fmt.tprintf("%s/store",root))
    if kept==nil {return}
    bytes:=png_bytes(16,16,{200,100,50})
    // Each import is another image of the project, with its own id: the levels are what the cache gives.
    imported :: proc(t:^testing.T,types:^asset.Types,folder,name:string,bytes:[]u8,options:importer.Import_Options) -> (format:asset.Texture_Format,mips:int,texels:string,flags:asset.Texture_Flags) {
        image:=fmt.tprintf("%s/%s.png",folder,name)
        _=os.write_entire_file(image,bytes)
        report,error:=import_test(t,image,options)
        defer importer.report_destroy(&report)
        if !testing.expectf(t,error.code==.None && len(report.assets)==1,"%v %s",error.code,error.message) {return}
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,report.assets[0].path,context.temp_allocator),asset.Error.None) {return}
        view,view_error:=asset.texture_view(&a,types)
        if !testing.expect_value(t,view_error,asset.Error.None) {return}
        return view.info.format,len(view.mips),strings.clone(string(view.texels),context.temp_allocator),view.info.flags
    }
    options:=importer.Import_Options{store=kept}
    format,mips,first,_:=imported(t,&types,folder,"a",bytes,options)
    testing.expect(t,format==.BC1 && mips==5)
    entries:=cached_refs(kept,textures.CACHE)
    if !testing.expect_value(t,len(entries),1) {return}

    // Another import of the same image has the same levels, made from the cache.
    _,_,second,_:=imported(t,&types,folder,"b",bytes,options)
    testing.expect(t,len(first)>0 && second==first)

    // What the cache holds is what the import takes: a texture put under its key is the one written.
    plain:[16*16*4]u8
    planes:=[1][]u8{plain[:]}
    flat:=textures.Built{width=16,height=16,format=.RGBA8,mips=planes[:]}
    testing.expect(t,textures.cache_write({store=kept},cached_key(entries[0]),&types,&flat))
    format,mips,_,_=imported(t,&types,folder,"c",bytes,options)
    testing.expect(t,format==.RGBA8 && mips==1)

    // A store that misses asks its source before building: what a peer built is taken as it is.
    peer:=options
    peer.store=test_store(t,fmt.tprintf("%s/peer",root))
    peer.cache_source=copy_source(kept)
    format,mips,_,_=imported(t,&types,folder,"p",bytes,peer)
    testing.expect(t,format==.RGBA8 && mips==1,"the levels of the source, not built")
    testing.expect_value(t,len(cached_refs(peer.store,textures.CACHE)),1)

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
    fast.store=test_store(t,fmt.tprintf("%s/empty",root))
    flags:asset.Texture_Flags
    format,_,_,flags=imported(t,&types,folder,"g",bytes,fast)
    testing.expect(t,.Fast in flags && format==.BC1,"Fast, for the sync of a build to encode again")
}

@(test)
an_import_takes_a_mesh_that_another_import_built_from_the_mesh_cache :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    root,_:=test_project(t,"mesh-cache")
    if root=="" {return}
    kept:=test_store(t,fmt.tprintf("%s/store",root))
    if kept==nil {return}
    source:=copy_in(root,DEMO,"gallery/vase.obj","gallery/vase.mtl")
    options:=importer.Import_Options{world=prefab.import_world(t),store=kept}
    colliders :: proc(t:^testing.T,types:^asset.Types,path:string) -> int {
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,path,context.temp_allocator),asset.Error.None) {return -1}
        view,error:=asset.mesh_view(&a,types)
        if !testing.expect_value(t,error,asset.Error.None) {return -1}
        return len(view.colliders)
    }
    imported :: proc(t:^testing.T,source:string,options:importer.Import_Options) -> (mesh:string,ok:bool) {
        report,error:=import_test(t,source,options)
        defer importer.report_destroy(&report)
        mesh,_=written_of(&report)
        return mesh,testing.expectf(t,error.code==.None,"%v %s",error.code,error.message)
    }
    mesh_path,ok:=imported(t,source,options)
    if !ok {return}
    built,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    entries:=cached_refs(kept,importer.MESH_CACHE)
    if !testing.expect_value(t,len(entries),1) {return}

    // A mesh whose file is gone is built from the cache, to the same bytes.
    testing.expect(t,os.remove(mesh_path)==nil)
    if _,ok=imported(t,source,options);!ok {return}
    again,_:=os.read_entire_file(mesh_path,context.temp_allocator)
    testing.expect(t,len(built)>0 && string(again)==string(built),"what the cache gives is what building gives")

    // What the cache holds is what the import takes: a mesh put under its key, with a collider, is the one written.
    key:=cached_key(entries[0])
    cached:asset.Asset
    if !testing.expect(t,cache.load({store=kept},importer.MESH_CACHE,key,importer.MESH_CACHE_VERSION,&cached,context.temp_allocator)) {return}
    view,view_error:=asset.mesh_view(&cached,&types)
    if !testing.expect_value(t,view_error,asset.Error.None) {return}
    points:=[4][3]f32{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    hull:=[1]asset.Collider{{kind=.Hull,rotation=1,point_count=4}}
    doc:asset.Document
    if !testing.expect_value(t,asset.mesh_document(&doc,&types,{id=cached.blob.header.id,geometry=view.geometry,slots=view.slots,colliders=hull[:],collision_points=points[:]},context.temp_allocator),asset.Error.None) {return}
    hulled,bytes_error:=asset.document_bytes(&doc,context.temp_allocator)
    testing.expect(t,bytes_error==.None && cache.put({store=kept},importer.MESH_CACHE,key,importer.MESH_CACHE_VERSION,hulled))
    testing.expect(t,os.remove(mesh_path)==nil)
    hulled_path:string
    if hulled_path,ok=imported(t,source,options);!ok {return}
    testing.expect_value(t,colliders(t,&types,hulled_path),1)

    // A store that misses asks its source before building: what a peer built is taken as it is.
    peer:=options
    peer.store=test_store(t,fmt.tprintf("%s/peer",root))
    peer.cache_source=copy_source(kept)
    peer_path:string
    if peer_path,ok=imported(t,source,peer);!ok {return}
    testing.expect_value(t,colliders(t,&types,peer_path),1)

    // Rebuilding does not read the cache, and builds it again.
    rebuilt:=options
    rebuilt.rebuild=true
    rebuilt_path:string
    if rebuilt_path,ok=imported(t,source,rebuilt);!ok {return}
    testing.expect_value(t,colliders(t,&types,rebuilt_path),0)
    last,_:=os.read_entire_file(rebuilt_path,context.temp_allocator)
    testing.expect(t,string(last)==string(built))
}
