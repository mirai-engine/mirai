package sources

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:cook/cache"
import importer "mirai:cook/import"
import "mirai:cook/import/gltf"
import "mirai:cook/import/obj"
import "mirai:cook/import/usd"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:store"

FIXTURES :: #directory+"/../../../assets/fixtures/"
DEMO :: #directory+"/../../../demo/assets/"

@(rodata)
USD_TEXT:=usd.Options{no_usdcat=true}

// FORMATS with USD read as text, without usdcat, as every machine can.
text_formats :: proc() -> [3]importer.Format {
    return {gltf.FORMAT,usd.format(&USD_TEXT),obj.FORMAT}
}

write_text :: proc(folder,name,text:string) -> string {
    path:=fmt.tprintf("%s/%s",folder,name)
    _=os.write_entire_file(path,text)
    return path
}

// A Library that gives no formats and the types of the game context.user_ptr
// points to: what sync and mirai import write the prefab of a model in.
test_library :: proc(root:string,s:^store.Store,allocator:mem.Allocator) -> Library_Imports {
    return {world=(^core.World_Info)(context.user_ptr)}
}

// formats: FORMATS when nil.
import_ok :: proc(t:^testing.T,path:string,options:importer.Import_Options={},formats:[]importer.Format=nil) -> (model:importer.Imported_Model,ok:bool) {
    error:importer.Error
    model,error=importer.import_model(path,formats if formats!=nil else FORMATS[:],options)
    ok=testing.expectf(t,error.code==.None,"%s: %v %s",path,error.code,error.message)
    return
}

find_node :: proc(model:^importer.Imported_Model,name:string) -> int {
    for node,i in model.nodes {
        if node.name==name {return i}
    }
    return -1
}

close_to :: proc(a,b:[3]f32,tolerance:f32=1e-5) -> bool {return linalg.length(a-b)<tolerance}

unpacked_normal :: proc(vertex:asset.Vertex) -> [3]f32 {return mm.normal_unpack(vertex.normal)}

contains :: proc(text,part:string) -> bool {return strings.contains(text,part)}

string_of :: proc(field:[]u8) -> string {
    for b,i in field {
        if b==0 {return string(field[:i])}
    }
    return string(field)
}

// Writes model as the import of a copy of its source in the assets of the
// test project at root, as import_write takes it, into the store of the test
// (test_options).
write_into :: proc(t:^testing.T,model:^importer.Imported_Model,root:string,options:importer.Import_Options={}) -> (report:importer.Import_Report,error:importer.Error) {
    assets:=fmt.tprintf("%s/assets",root)
    copied:=fmt.tprintf("%s/%s",assets,filepath.base(model.source))
    if model.source!=copied {
        os.make_directory_all(assets)
        data,_:=os.read_entire_file(model.source,context.temp_allocator)
        _=os.write_entire_file(copied,data)
        model.source=copied
    }
    options:=options
    options.root=root
    return importer.import_write(model,test_options(t,model.source,options))
}

// Copies files of a folder (FIXTURES, DEMO), by their paths under it, into
// the assets of the test project at root under the same paths, and gives
// where the first went.
copy_in :: proc(root,from:string,files:..string) -> string {
    first:string
    for file,at in files {
        target:=fmt.tprintf("%s/assets/%s",root,file)
        os.make_directory_all(filepath.dir(target))
        data,_:=os.read_entire_file(fmt.tprintf("%s%s",from,file),context.temp_allocator)
        _=os.write_entire_file(target,data)
        if at==0 {first=target}
    }
    return first
}

// options of an import of the source at path as a project that adds it
// imports it: in the store of the test, <root>/store, with its documents in
// the folder of the source (root: options.root, else the project whose assets
// hold the source, else its folder), unless options give them.
test_options :: proc(t:^testing.T,path:string,options:importer.Import_Options={},loc:=#caller_location) -> importer.Import_Options {
    options:=options
    root:=options.root
    if root=="" {root,_=source_root(path,context.temp_allocator)}
    if root=="" {root=filepath.dir(path)}
    os.make_directory_all(root)
    // A root that cannot hold a store leaves none: the import says so.
    if options.store==nil {
        if s,error:=store.open(fmt.tprintf("%s/store",root),context.temp_allocator);error==.None {
            options.store=new(store.Store,context.temp_allocator)
            options.store^=s
        }
    }
    if options.documents=="" {options.documents=filepath.dir(importer.path_key(path))}
    return options
}

// import_source with test_options.
import_test :: proc(t:^testing.T,path:string,options:importer.Import_Options={},formats:[]importer.Format=nil,wholes:[]Whole_Source=nil,allocator:=context.allocator,loc:=#caller_location) -> (report:importer.Import_Report,error:importer.Error) {
    return import_source(path,test_options(t,path,options,loc),formats,wholes,allocator)
}

// A store at folder, in the temp allocator; nil when it cannot be opened.
test_store :: proc(t:^testing.T,folder:string,loc:=#caller_location) -> ^store.Store {
    s,error:=store.open(folder,context.temp_allocator)
    if !testing.expect_value(t,error,store.Error.None,loc=loc) {return nil}
    kept:=new(store.Store,context.temp_allocator)
    kept^=s
    return kept
}

// The registry of the assets of the project at root with the cache of the
// package the import of report wrote listed at their top, as a project that
// pins it lists them.
registry_with :: proc(t:^testing.T,root:string,report:^importer.Import_Report,r:^asset.Registry,loc:=#caller_location) -> bool {
    s:=test_store(t,fmt.tprintf("%s/store",root),loc)
    if s==nil {return false}
    list:asset.Packages
    list.packages=make([dynamic]asset.Project_Package,context.temp_allocator)
    append(&list.packages,asset.Project_Package{id=report.package_id,manifest=report.manifest})
    resolved,error:=asset.packages_resolve(s,&list,context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None,loc=loc) {return false}
    asset.registry_init(r,fmt.tprintf("%s/assets",root),"",context.allocator,resolved.listed[:])
    return testing.expect_value(t,asset.registry_scan(r),asset.Error.None,loc=loc)
}

// The results a cache of s keeps (cook/cache), in the temp allocator.
cached_refs :: proc(s:^store.Store,name:string) -> []store.Ref {
    buffer:[store.NAME_MAX]u8
    refs,_:=store.ref_list(s,asset.cache_namespace(name,&buffer),context.temp_allocator)
    return refs
}

// The key of a result of a cache by the name of its ref, <key>-<version>.
cached_key :: proc(ref:store.Ref) -> u64 {
    key,_:=strconv.parse_u64_of_base(ref.name[:min(16,len(ref.name))],16)
    return key
}

// A source that copies what the store at user keeps, as a peer would give
// it: the blob of the ref and, for a build, every blob it lists.
copy_source :: proc(from:^store.Store) -> cache.Source {
    fetch :: proc(user:rawptr,into:^store.Store,namespace,name:string) -> bool {
        from:=(^store.Store)(user)
        hash,error:=store.ref_get(from,namespace,name)
        if error!=.None || !blob_copy(from,into,hash) {return false}
        if namespace==asset.REF_IMPORTS {
            b,build_error:=asset.build_get(from,hash,context.temp_allocator)
            if build_error!=.None {return false}
            for o in b.outputs {
                if !blob_copy(from,into,o.blob) {return false}
            }
        }
        return store.ref_set(into,namespace,name,hash)==.None
    }
    return {fetch=fetch,user=from}
}

// Copies the blob hash of from into into.
blob_copy :: proc(from,into:^store.Store,hash:store.Hash) -> bool {
    path,path_error:=store.blob_path(from,hash,context.temp_allocator)
    if path_error!=.None {return false}
    put,put_error:=store.put_file(into,path)
    return put_error==.None && put==hash
}

// A folder of a test as the root of a project, with its assets folder, where
// the sources of its imports are. "" when there is none.
test_project :: proc(t:^testing.T,name:string) -> (root,assets:string) {
    root=base.test_folder(t,name)
    if root=="" {return}
    assets=fmt.tprintf("%s/assets",root)
    os.make_directory_all(assets)
    return
}
