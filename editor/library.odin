package editor

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:cook/import/sources"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"
import "mirai:ui"

// The library of the machine in the editor: the packages the store of the
// session keeps (cook/import/sources/library.odin) and what a root of the
// editor, the project or a plugin, pins of them in its packages.mirai.
// Importing ingests a source where it is and pins its package (import.odin);
// packages.list lists the packages of the library with their assets, and
// packages.add, or a package of a library root of the content browser carried
// onto a folder (content_library.odin), pins one or some
// of its assets in a folder of the project, as an import that runs in its
// thread. Deleting the root of a package unpins it and moving it moves where
// the package is listed (asset_delete.odin, asset_move.odin); none of them
// removes a blob of the store or touches a source outside the project.

// A root of the registry: the project (prefix "") or a plugin mounted under prefix.
Library_Root :: struct {root,prefix:string}

// The package a root pins that gives an asset: its entry in the list of the
// root and its manifest, in the temp allocator.
@(private)
Library_Pin :: struct {
    root:Library_Root,
    entry:asset.Project_Package,
    p:asset.Package,
}

// A package of the library, as packages.list tells it.
@(private)
Library_Package :: struct {
    id:base.Asset_Id,
    manifest:store.Hash,
    name,origin,catalog_path:string,
    pinned:bool,   // the project pins it
    folder:string, // where the project lists it, when pinned
    assets:[]Library_Asset,
    root:store.Hash,      // the object its card shows (asset.build_shown) in the build of this machine; zero: none
    shown:base.Asset_Id,  // the asset of that object
    objects:[]store.Hash, // of every asset of that build, sorted
}

@(private)
Library_Asset :: struct {
    id:base.Asset_Id,
    name:string,
    kind:asset.Fourcc,
    bytes:i64, // of its file in the build of this machine; 0 when not built
    built:bool,
    pinned:bool,
}

// Lists again what the packages of root list, from the store of the session,
// and scans the registry. What they cannot list is told in the log.
@(private)
library_relist :: proc(s:^Session,root:Library_Root) {
    r:=files_registry(s)
    if r==nil {return}
    packages,error:=asset.root_packages(root.root,s.store.root,context.temp_allocator)
    if error!=.None {
        log.warnf("the packages of %s could not be listed: %v",root.root,error)
        return
    }
    for problem in packages.problems {log.warnf("assets: %s",problem)}
    if !asset.registry_listed_set(r,root.prefix,packages.listed) {log.warnf("the packages of %s could not be listed: no memory",root.root)}
    host.assets_scan(s.app.assets)
}

// The package a root pins that gives the asset of file, with its manifest,
// for what a package lists (by the package the registry lists it from) and
// for a scene, which may be the root of one; false for any other asset, an
// asset no package gives, or without the store.
@(private)
library_pin_of :: proc(s:^Session,r:^asset.Registry,file:^asset.Registry_File) -> (pin:Library_Pin,found:bool) {
    if s.store.root=="" || !file.listed && file.kind!=asset.KIND_SCENE {return}
    root,_,rooted:=import_root_of(s,r,content_folder_of(file.path))
    if !rooted {return}
    // What a package lists names it: only its manifest is read.
    listed:base.Asset_Id
    if file.listed {
        entries:=r.listed
        for mount in r.mounts {
            if mount.prefix==root.prefix && root.prefix!="" {entries=mount.listed}
        }
        for &l in entries {
            if l.id==file.id {listed=l.package_id}
        }
        if listed=={} {return}
    }
    list,_,error:=asset.packages_load(root.root,context.temp_allocator)
    if error!=.None {return}
    for &entry in list.packages {
        if listed!={} && entry.id!=listed {continue}
        p,read_error:=asset.package_get(&s.store,entry.manifest,context.temp_allocator)
        if read_error!=.None || p.id!=entry.id {continue}
        for &a in p.assets {
            if a.id==file.id {return {root,entry,p},true}
        }
    }
    return
}


// Where the root of a package is in the registry, or its id when it is not there.
@(private)
library_root_named :: proc(r:^asset.Registry,p:^asset.Package) -> string {
    root:=asset.package_root(p)
    if file,found:=asset.registry_find(r,root);found {return file.path}
    buffer:[base.ASSET_ID_TEXT]u8
    return fmt.tprintf("%s (%s)",p.name,base.asset_id_format(root,buffer[:]))
}

// Pins entry again in its root, with what changed of it, and lists again.
@(private)
library_repin :: proc(s:^Session,root:Library_Root,entry:asset.Project_Package) -> string {
    if error:=sources.project_pin(root.root,&s.store,entry);error!=.None {
        return fmt.tprintf("%s/%s could not be written (%v): check that it is not read-only, then try again",root.root,asset.PACKAGES_FILE,error)
    }
    library_relist(s,root)
    return ""
}

// The packages of the library of the session, by name, with whether the
// root at root pins them. In allocator.
@(private)
library_list :: proc(s:^Session,root:string,allocator:=context.allocator) -> (list:[]Library_Package,problem:string) {
    if s.store.root=="" {return nil,"The editor has no store, where the library keeps its packages: start it with --store <folder>"}
    refs,error:=store.ref_list(&s.store,asset.REF_PACKAGES,context.temp_allocator)
    if error!=.None && error!=.Missing {return nil,fmt.tprintf("The packages of the store at %s could not be listed (%v): check that the folder reads",s.store.root,error)}
    pins:asset.Packages
    if root!="" {pins,_,_=asset.packages_load(root,context.temp_allocator)}
    out:=make([dynamic]Library_Package,0,len(refs),allocator)
    for ref in refs {
        p,read_error:=asset.package_get(&s.store,ref.hash,allocator)
        if read_error!=.None {continue}
        entry:=Library_Package{id=p.id,manifest=ref.hash,name=p.name,
            origin=p.origin.path,catalog_path=p.catalog_path}
        selected:[]bool
        for &pinned in pins.packages {
            if pinned.id!=p.id {continue}
            entry.pinned,entry.folder=true,strings.clone(pinned.folder,allocator)
            selected,_,_=asset.package_selection(&p,pinned.assets[:],context.temp_allocator)
            break
        }
        outputs:=make(map[base.Asset_Id]asset.Build_Output,context.temp_allocator)
        digits:[64]u8
        if built,ref_error:=store.ref_get(&s.store,asset.REF_BUILDS,store.hex(asset.build_select(ref.hash,&p),&digits));ref_error==.None {
            if b,build_error:=asset.build_get(&s.store,built,context.temp_allocator);build_error==.None && b.package_id==p.id {
                for o in b.outputs {outputs[o.id]=o}
                entry.root,entry.objects,entry.shown=library_build_preview(&b,&p,{},allocator)
            }
        }
        assets:=make([]Library_Asset,len(p.assets),allocator)
        for &a,at in p.assets {
            assets[at]={id=a.id,name=a.name,kind=a.kind,pinned=at<len(selected) && selected[at]}
            o,found:=outputs[a.id]
            if found && o.kind==a.kind && asset.object_whole(&s.store,o.object,refresh=false) {
                assets[at].built=true
                if header,error:=asset.object_header(&s.store,o.object);error==.None {
                    assets[at].bytes=i64(header.total_size)
                }
            }
        }
        entry.assets=assets
        append(&out,entry)
    }
    slice.sort_by(out[:],proc(a,b:Library_Package) -> bool {return a.name<b.name || a.name==b.name && a.id.x<b.id.x})
    return out[:],""
}

@(private)
library_add_target :: proc(s:^Session,folder:string) -> (root:Library_Root,rest,problem:string) {
    r:=files_registry(s)
    if r==nil {return {},"","The project has no assets folder to add into"}
    if busy:=import_busy(s);busy!="" {return {},"",busy}
    clean,refused:=asset_folder_clean(r,folder)
    if refused!="" {return {},"",fmt.tprintf("folder: %s",refused)}
    rooted:bool
    root,rest,rooted=import_root_of(s,r,clean)
    if !rooted {
        return {},"",fmt.tprintf("folder: %s is a folder of the editor or the engine: give a folder of the project or of a plugin",clean)
    }
    if s.store.root=="" {return {},"","The editor has no store: start it with --store <folder>"}
    return
}

// Starts adding a named package or the selected assets of it.
@(private)
library_add :: proc(s:^Session,named:string,ids:[]string,folder:string) -> string {
    root,rest,problem:=library_add_target(s,folder)
    if problem!="" {return problem}
    wanted:=strings.trim_space(named)
    if wanted=="" {return "name: give the id or the name of a package, as packages.list lists them"}
    p:asset.Package
    manifest:store.Hash
    id,is_id:=serial.text_parse_asset_id(wanted)
    if is_id {
        text:[base.ASSET_ID_TEXT]u8
        hash,_:=store.ref_get(&s.store,asset.REF_PACKAGES,base.asset_id_format(id,text[:]))
        if hash!={} {
            candidate,error:=asset.package_get(&s.store,hash,context.temp_allocator)
            if error==.None && candidate.id==id {p,manifest=candidate,hash}
        }
    } else {
        refs,error:=store.ref_list(&s.store,asset.REF_PACKAGES,context.temp_allocator)
        if error!=.None && error!=.Missing {
            return fmt.tprintf("The packages of %s could not be read (%v)",s.store.root,error)
        }
        for ref in refs {
            candidate,read_error:=asset.package_get(&s.store,ref.hash,context.temp_allocator)
            if read_error!=.None || candidate.name!=wanted {continue}
            if manifest!={} {
                return fmt.tprintf("name: more than one package is named %q: give its id, as packages.list lists them",wanted)
            }
            p,manifest=candidate,ref.hash
        }
    }
    if manifest=={} {
        return fmt.tprintf("name: the library at %s has no package %q: packages.list lists them, and asset.import ingests a source",s.store.root,wanted)
    }
    used:=make([dynamic]base.Asset_Id,0,len(ids),context.temp_allocator)
    for text in ids {
        asset_id,parsed:=serial.text_parse_asset_id(strings.trim_space(text))
        known:=false
        for &a in p.assets {known||=parsed && a.id==asset_id}
        if !known {return fmt.tprintf("assets: %q is no asset of the package %s: give the ids packages.list lists for it, or none for all",text,p.name)}
        if !slice.contains(used[:],asset_id) {append(&used,asset_id)}
    }
    requests:=[1]sources.Package_Add{{manifest=manifest,folder=rest}}
    return library_add_start(s,root,p.name,requests[:],used[:])
}

@(private)
library_add_start :: proc(s:^Session,root:Library_Root,name:string,requests:[]sources.Package_Add,assets:[]base.Asset_Id,group:=false) -> string {
    allocator:=runtime.heap_allocator()
    job:=new(Import_Job,allocator)
    job^={allocator=allocator,started=time.tick_now(),group_add=group}
    job.store=s.store
    job.source=strings.clone(name,allocator)
    job.root,job.prefix=strings.clone(root.root,allocator),strings.clone(root.prefix,allocator)
    job.additions=library_add_clone(requests,allocator)
    job.assets=slice.clone(assets,allocator)
    import_plugins_prepare(s,job,true,{},0)
    if !import_job_start(s,job,"Adding %s",name) {
        return string(s.importer.message[:s.importer.message_length])
    }
    return ""
}

@(private)
library_add_clone :: proc(requests:[]sources.Package_Add,allocator:mem.Allocator) -> []sources.Package_Add {
    added:=slice.clone(requests,allocator)
    for &entry in added {entry.folder=strings.clone(entry.folder,allocator)}
    return added
}

@(private)
content_packages_add :: proc(s:^Session,library:i32,ids:[]base.Asset_Id,folder:string,name:="Folder") {
    if len(ids)==0 {return}
    root,rest,problem:=library_add_target(s,folder)
    if problem!="" {notify(s,problem);return}
    listing:=&s.content.libraries
    library_root:=content_library_root_of(s.content,library)
    by_id:=make(map[base.Asset_Id]^Content_Package,context.temp_allocator)
    for &p in listing.packages {
        if p.root==library_root {by_id[p.id]=&p}
    }
    requests:=make([]sources.Package_Add,len(ids),context.temp_allocator)
    for id,i in ids {
        p:=by_id[id]
        if p==nil || p.manifest=={} {
            notify(s,"The library changed. Open the folder again.")
            return
        }
        path:=p.folder
        if rest!="" {path=fmt.tprintf("%s/%s",rest,p.folder)}
        requests[i]={manifest=p.manifest,folder=path}
    }
    if library==0 {
        problem=library_add_start(s,root,name,requests,nil,group=true)
    } else {
        problem=collab_take_start(s,name,folder,requests,nil)
    }
    if problem!="" {notify(s,problem)}
}

// ---------------------------------------------------------------- packages.list, packages.add

Api_Packages_List_Params :: struct {
    name:string `mirai:"optional,label=Only the packages whose name holds it, in any case; empty: all"`,
}

Api_Packages_List_Result :: struct {
    store:string `mirai:"label=The folder of the store the library keeps its packages in"`,
    packages:[]Api_Package,
}
Api_Package :: struct {
    id:base.Asset_Id,
    name:string,
    source:string `mirai:"label=Where its source was when it was ingested on this machine"`,
    pinned:bool `mirai:"label=The project pins it"`,
    folder:string `mirai:"optional,label=Of the assets, where the project lists it, when pinned"`,
    thumbnail:string `mirai:"label=The key of the small thumbnail of its root; empty: it has no build here"`,
    thumbnail_here:bool `mirai:"label=The store of this machine keeps that thumbnail"`,
    assets:[]Api_Package_Asset,
}
Api_Package_Asset :: struct {
    id:base.Asset_Id,
    name:string `mirai:"label=In the source"`,
    kind:string,
    bytes:i64 `mirai:"label=Of its file in the build of this machine; 0 when not built"`,
    built:bool `mirai:"label=This machine has a build of it this engine reads"`,
}

Api_Packages_Add_Params :: struct {
    name:string `mirai:"label=The package: its id or its name, as packages.list lists them"`,
    assets:[]string `mirai:"optional,label=Of the package, the ids of the assets the project uses, with what they depend on; none: all"`,
    folder:string `mirai:"optional,label=The folder under the asset folder it is listed in; none: the root of the assets"`,
    seconds:int `mirai:"optional,min=1,max=7200,unit=s,label=How long it waits for the end of the add; past that it answers importing and the add goes on"`,
}

@(private)
api_packages_list :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Packages_List_Params)
    packages,problem:=library_list(s,s.project_root,call.allocator)
    if problem!="" {
        api.call_fail(call,api.SERVER_ERROR,problem)
        return
    }
    wanted:=strings.to_lower(strings.trim_space(params.name),context.temp_allocator)
    out:=make([dynamic]Api_Package,0,len(packages),call.allocator)
    for &p in packages {
        if wanted!="" && !strings.contains(strings.to_lower(p.name,context.temp_allocator),wanted) {continue}
        assets:=make([]Api_Package_Asset,len(p.assets),call.allocator)
        for a,at in p.assets {
            kind:="other"
            if info,known:=asset.kind_info(a.kind);known {kind=info.name}
            assets[at]={a.id,a.name,kind,a.bytes,a.built}
        }
        entry:=Api_Package{id=p.id,name=p.name,source=p.origin,pinned=p.pinned,folder=p.folder,assets=assets}
        entry.thumbnail,entry.thumbnail_here=api_thumbnail_of(s,p.root,p.objects,call.allocator)
        append(&out,entry)
    }
    result:=api.call_result(call,Api_Packages_List_Result)
    result.store=strings.clone(s.store.root,call.allocator)
    result.packages=out[:]
}

@(private)
api_packages_add :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Packages_Add_Params)
    if problem:=library_add(s,params.name,params.assets,params.folder);problem!="" {
        api.call_fail(call,api.INVALID_PARAMS,problem)
        return
    }
    importing :: proc(s:^Session,user:rawptr) -> bool {return s.importer.running!=nil}
    api_wait(s,f64(params.seconds),nil,importing,"adding")
    api_import_status_answer(s,call)
}

// Of the build this machine chose for a package: the object of its asset id
// (none: the one it shows, asset.build_shown) and those of all its assets,
// sorted, as thumbnail_package_key takes them.
@(private)
library_build_objects :: proc(s:^Session,manifest:store.Hash,p:^asset.Package,id:base.Asset_Id,allocator:=context.temp_allocator) -> (object:store.Hash,objects:[]store.Hash,shown:base.Asset_Id,built:bool) {
    digits:[64]u8
    hash,ref_error:=store.ref_get(&s.store,asset.REF_BUILDS,store.hex(asset.build_select(manifest,p),&digits))
    if ref_error!=.None {return}
    b,error:=asset.build_get(&s.store,hash,context.temp_allocator)
    if error!=.None || b.package_id!=p.id {return}
    object,objects,shown=library_build_preview(&b,p,id,allocator)
    return object,objects,shown,object!={}
}

@(private)
library_build_preview :: proc(b:^asset.Build,p:^asset.Package,id:base.Asset_Id,
    allocator:runtime.Allocator) -> (object:store.Hash,objects:[]store.Hash,shown:base.Asset_Id) {
    objects=make([]store.Hash,len(b.outputs),allocator)
    shown=id
    if id=={} {object,shown=asset.build_shown(b,p)}
    for o,k in b.outputs {
        objects[k]=o.object
        if id!={} && o.id==id {object=o.object}
    }
    slice.sort_by(objects,proc(a,b:store.Hash) -> bool {
        a,b:=a,b
        return string(a[:])<string(b[:])
    })
    return
}

// The key of the small thumbnail of a package whose root is object, and whether this store keeps it.
@(private)
api_thumbnail_of :: proc(s:^Session,object:store.Hash,objects:[]store.Hash,allocator:=context.allocator) -> (name:string,here:bool) {
    if object=={} {return}
    key:=thumbnail_package_key(.Small,thumbnail_programs(s),object,objects)
    buffer:[16]u8
    name=strings.clone(thumbnail_name(key,&buffer),allocator)
    _,error:=store.ref_get(&s.store,THUMBNAIL_NAMESPACE,name)
    return name,error==.None
}

// The manifest and package of this machine's library a listed output of the registry comes from.
@(private)
library_package_of_output :: proc(s:^Session,r:^asset.Registry,id:base.Asset_Id) -> (manifest:store.Hash,p:asset.Package,found:bool) {
    package_id:base.Asset_Id
    lists:=make([dynamic][]asset.Package_Listed,context.temp_allocator)
    append(&lists,r.listed)
    for mount in r.mounts {append(&lists,mount.listed)}
    search: for list in lists {
        for &l in list {
            if l.id==id {package_id=l.package_id;break search}
        }
    }
    if package_id=={} || s.store.root=="" {return}
    buffer:[base.ASSET_ID_TEXT]u8
    hash,error:=store.ref_get(&s.store,asset.REF_PACKAGES,base.asset_id_format(package_id,buffer[:]))
    if error!=.None {return}
    read,read_error:=asset.package_get(&s.store,hash,context.temp_allocator)
    if read_error!=.None || read.id!=package_id {return}
    return hash,read,true
}
