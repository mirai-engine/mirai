package sources

import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:cook/cache"
import importer "mirai:cook/import"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"

// The library of the machine: the packages its store keeps (asset/packages.odin)
// and what a project does with them.
//
// - ingest: a source anywhere on disk becomes a package of the store, where
//   it is; nothing is copied into a project. Ingesting the same origin again
//   finds its package (asset.REF_ORIGINS) and keeps its ids; one whose
//   identity and build are current is not imported again. Two processes that
//   ingest one origin at once take turns (a lock per origin), and the second
//   finds the work done.
// - project_add: pins a package in the project's packages.mirai, with the
//   text of its manifest beside it (project_pin and project_unpin, their only
//   writers), and follows it into the project.
// - project_refresh: for each package a project pins, the build this engine
//   reads, from the local refs, else from the caller's source, else by
//   ingesting its origin when it is on this machine (also when the source
//   changed); else the report says, by package name, that a machine with its
//   source must ingest it. A manifest the store lacks comes from the
//   project's file of it, else from the caller's source. What it asks the
//   source for is asked together first (refresh_prefetch). It never removes a
//   blob, a ref or a file, and never builds without the source.
//
// Following a package writes or follows its documents in the project's folder
// of it: from the build's baselines (importer.documents_follow), and for a
// model whose source is here, by importing it with the project's folder,
// which also writes its prefab in the game's types (prefab.model_prefab). The
// pin records what each file it writes over holds as written
// (asset.Package_Written): a refresh leaves one that changed since as it is
// and warns, and an import into the project asks first (Library_Options.changed).

// What the library of the editor of the project at root gives its imports:
// the formats of models and the importers of whole sources its plugins add,
// with what they read prepared for its assets, and the types of its game,
// which the prefab of a model is written in, with the packages of root listed
// from the store s; release(state) lets them go. problem: why there are none.
// Only a program that links the editor reads it (editor.import_library).
Library :: #type proc(root:string,s:^store.Store,allocator:mem.Allocator) -> Library_Imports
Library_Imports :: struct {
    formats:[]importer.Format,
    wholes:[]Whole_Source,
    world:^core.World_Info,
    release:proc(state:rawptr),
    state:rawptr,
    problem:string,
}

Library_Options :: struct {
    store:^store.Store,
    // Asked for what the store does not have before building: a manifest by
    // (asset.REF_MANIFESTS, <hash its pin names>), a build by (asset.REF_IMPORTS, <key>) and,
    // with Fast textures allowed, then by (asset.REF_IMPORTS_FAST, <key>), or
    // for a package whose importer the library lacks by (asset.REF_BUILDS,
    // <build_select>), with every object it lists, a result of cook/cache.
    source:cache.Source,
    // Fast textures allowed: imports build them Fast unless the texture cache
    // has them Final, and a Fast build is taken, here or from the source; false:
    // Final required, what a cook ships, and a Fast build is never asked for.
    fast_textures:bool,
    rebuild:bool,    // ingest: imports the source again, also when it is current
    // What an import into a project (project_ingest) does with its documents
    // that changed since they were last written; a refresh and the follow of
    // project_add keep them, unless Discard.
    changed:importer.Changed,
    // The project or plugin the library works for: its plugins read sources
    // (plugins) and its game's types hold prefabs. "": the formats of the engine alone.
    root:string,
    plugins:Library, // nil: no formats of plugins, and no prefabs of models
    // What the plugins give, already prepared by the caller, which releases
    // it (the editor, from its session): taken in place of plugins.
    imports:^Library_Imports,
    worker:jobs.Worker_Ref,
    progress:io.Writer, // where each source imported is said as it goes; nil: nowhere
}

Library_Report :: struct {
    packages:int, // pinned by the project
    ingested:int, // imported now
    fetched:int,  // builds the source gave
    missing:[dynamic]string,  // a package with no build here and no source on this machine, by name, and what gives it
    failures:[dynamic]string, // what could not be read or imported, with the reason
    warnings:[dynamic]string,
    allocator:mem.Allocator,
}

library_report_destroy :: proc(report:^Library_Report) {
    for text in report.missing {delete(text,report.allocator)}
    for text in report.failures {delete(text,report.allocator)}
    for text in report.warnings {delete(text,report.allocator)}
    delete(report.missing)
    delete(report.failures)
    delete(report.warnings)
    report^={}
}

// Ingests the source at origin, a file or a folder anywhere on disk, as a
// package of options.store. settings, when given, replace those its package
// keeps. A source whose package is current (same identity, a build this
// engine reads) is not imported: the report names its package and lists no
// assets. In allocator.
ingest :: proc(origin:string,options:Library_Options,settings:^importer.Import_Settings=nil,allocator:=context.allocator) -> (report:importer.Import_Report,error:importer.Error) {
    l:Library_State
    library_begin(&l,options,allocator)
    defer library_end(&l)
    return library_ingest(&l,origin,{},settings,"",nil,.Keep,allocator)
}

// Pins the package whose manifest the store keeps under manifest in the
// project at root, its cache listed under folder of its assets, using assets
// (none: all), and follows it there (project_refresh). In allocator.
project_add :: proc(root:string,manifest:store.Hash,folder:string,assets:[]base.Asset_Id,options:Library_Options,allocator:=context.allocator) -> (report:Library_Report) {
    report_begin(&report,allocator)
    l:Library_State
    library_begin(&l,options,allocator)
    defer library_end(&l)
    context.temp_allocator=l.temp
    top:=project.path_absolute(root,context.temp_allocator)
    digits:[64]u8
    p,error:=asset.package_get(options.store,manifest,context.temp_allocator)
    if error!=.None {
        report_line(&report.failures,"%s: the manifest %s is not a package in the store at %s (%v): ingest its source, or fetch it from a peer that has it",top,store.hex(manifest,&digits),options.store.root,error)
        return
    }
    entry:=asset.Project_Package{id=p.id,manifest=manifest,folder=folder}
    entry.assets=make([dynamic]base.Asset_Id,context.temp_allocator)
    for id in assets {
        known:=false
        for &a in p.assets {known||=a.id==id}
        if !known {
            report_line(&report.failures,"%s: package %s has no asset %v: use one its manifest lists",top,p.name,id)
            return
        }
        if !slice.contains(entry.assets[:],id) {append(&entry.assets,id)}
    }
    lock,locked:=project_pin_lock(top)
    if !locked {project_pin_lock_report(&report,top);return}
    defer workspace.lock_release(&lock)
    previous,_,pin_read_error:=asset.packages_load(top,context.temp_allocator)
    if pin_read_error!=.None {
        report_line(&report.failures,"%s: %s could not be read (%v): restore it, then add the package again",top,asset.PACKAGES_FILE,pin_read_error)
        return
    }
    for &pin in previous.packages {
        if pin.id!=p.id {continue}
        entry.folder,entry.written=pin.folder,pin.written
        if len(assets)==0 || len(pin.assets)==0 {
            clear(&entry.assets)
        } else {
            for id in pin.assets {
                if !slice.contains(entry.assets[:],id) {append(&entry.assets,id)}
            }
        }
        break
    }
    if !asset.folder_valid(entry.folder) {
        report_line(&report.failures,"%s: a folder is relative to the assets, with forward slashes, and never leaves them",top)
        return
    }
    l.adding=true
    report.packages=1
    project_follow_begin(&l,top)
    package_refresh(&l,top,entry,&report,true)
    return
}

Package_Add :: struct {manifest:store.Hash,folder:string}

project_add_many :: proc(root:string,requests:[]Package_Add,options:Library_Options,allocator:=context.allocator) -> (report:Library_Report) {
    report_begin(&report,allocator)
    if len(requests)==0 {return}
    if options.store==nil {
        report_line(&report.failures,"%s: the library needs a store to add these packages",root)
        return
    }
    l:Library_State
    library_begin(&l,options,allocator)
    defer library_end(&l)
    context.temp_allocator=l.temp
    top:=project.path_absolute(root,l.temp)
    if l.options.root=="" {l.options.root=top}
    l.adding=true
    l.preparing=true
    l.prepared=make([dynamic]Prepared_Add,l.temp)
    seen:=make(map[base.Asset_Id]store.Hash,l.temp)
    if l.options.source.fetch!=nil {
        lacking:=make([dynamic]string,l.temp)
        for request in requests {
            digits:[64]u8
            name:=store.hex(request.manifest,&digits)
            if object,error:=store.ref_get(options.store,asset.REF_MANIFESTS,name);error!=.None || !store.chunk_has(options.store,object) {
                append(&lacking,strings.clone(name,l.temp))
            }
        }
        fetch_many(&l,asset.REF_MANIFESTS,lacking[:])
    }
    for request in requests {
        if !asset.folder_valid(request.folder) {
            report_line(&report.failures,"%s: a folder is relative to the assets, with forward slashes, and never leaves them",request.folder)
            return
        }
        p,error:=asset.package_get(options.store,request.manifest,l.temp)
        digits:[64]u8
        if error==.Not_Found && fetch(&l,asset.REF_MANIFESTS,store.hex(request.manifest,&digits)) {
            p,error=asset.package_get(options.store,request.manifest,l.temp)
        }
        if error!=.None {
            report_line(&report.missing,"the store has no readable package manifest %s (%v): ingest its source, or fetch it from a peer that has it",store.hex(request.manifest,&digits),error)
            return
        }
        if old,present:=seen[p.id];present {
            if old==request.manifest {continue}
            report_line(&report.failures,"package %s: this selection contains more than one manifest of the package",p.name)
            return
        }
        seen[p.id]=request.manifest
        package_refresh(&l,top,{id=p.id,manifest=request.manifest,folder=request.folder},&report,true,&p)
    }
    if len(report.missing)>0 || len(report.failures)>0 {return}

    lock,locked:=project_pin_lock(top)
    if !locked {project_pin_lock_report(&report,top);return}
    defer workspace.lock_release(&lock)
    previous,_,read_error:=asset.packages_load(top,l.temp)
    if read_error!=.None {
        report_line(&report.failures,"%s/%s could not be read (%v): restore it, then add the packages again",top,asset.PACKAGES_FILE,read_error)
        return
    }
    pinned:=make(map[base.Asset_Id]int,l.temp)
    for &entry,at in previous.packages {pinned[entry.id]=at}
    project_follow_begin(&l,top)
    l.pins=make([dynamic]asset.Project_Package,l.temp)
    l.backups=importer.document_backups_begin()
    committed:=false
    defer {
        path,backup:=importer.document_backups_finish(&l.backups,committed)
        if path!="" {
            report_line(&report.failures,"%s could not be restored after the failed addition (backup: %s)",path,backup)
        }
    }
    for &prepared in l.prepared {
        entry:=prepared.entry
        if at,known:=pinned[entry.id];known {
            entry.folder,entry.written=previous.packages[at].folder,previous.packages[at].written
        }
        destination:=documents_folder(l.assets,entry.folder)
        documents_write(&l,top,&entry,&prepared.pkg,&prepared.build,destination,&report)
        if len(report.failures)>0 {return}
        if prepared.prefab {warn_missing_prefab(&l,&prepared.pkg,&report)}
    }
    if error:=project_pin_many(top,options.store,&previous,l.pins[:],&l.backups);error!=.None {
        report_line(&report.failures,"%s/%s could not be written (%v): check the project's files and try again",top,asset.PACKAGES_FILE,error)
        return
    }
    committed=true
    report.packages=len(l.pins)
    return
}

// Ingests the source at origin as ingest does and pins its package in the
// project at root under folder, with what the project used of it before: one
// import, which for a model writes its documents and its prefab there. The
// report of the import and that of the project, in allocator.
project_ingest :: proc(root,origin,folder:string,options:Library_Options,settings:^importer.Import_Settings=nil,allocator:=context.allocator) -> (report:importer.Import_Report,added:Library_Report,error:importer.Error) {
    report_begin(&added,allocator)
    l:Library_State
    library_begin(&l,options,allocator)
    defer library_end(&l)
    caller:=context.temp_allocator
    context.temp_allocator=l.temp
    top:=project.path_absolute(root,context.temp_allocator)
    lock,locked:=project_pin_lock(top)
    if !locked {
        return {},added,importer.error_make(.Write,"%s/%s could not be locked: check that the project is writable",top,asset.PACKAGES_FILE,allocator=caller)
    }
    defer workspace.lock_release(&lock)
    project_follow_begin(&l,top)
    entry:=asset.Project_Package{folder=folder}
    documents:=l.assets if folder=="" else fmt.tprintf("%s/%s",l.assets,folder)
    r,_:=reader_of(&l,importer.path_key(origin))
    model:=r.kind==.Model && plugins_world(&l)!=nil
    // What the project pins of the package its source was ingested as before.
    if p,_,found,_:=importer.package_previous(options.store,{},importer.path_key(origin),context.temp_allocator);found {
        list,_,_:=asset.packages_load(top,context.temp_allocator)
        for &other in list.packages {
            if other.id==p.id {entry.assets,entry.written=other.assets,other.written}
        }
    }
    report,error=library_ingest(&l,origin,{},settings,documents if model else "",entry.written[:],l.options.changed,allocator)
    if error.code!=.None {
        error.message=strings.clone(error.message,caller)
        return
    }
    if entry.id!=report.package_id {entry.assets,entry.written={},{}}
    entry.id,entry.manifest=report.package_id,report.manifest
    if model {entry.written=written_list(report.written[:])}
    if pin_error:=project_pin_locked(top,options.store,entry);pin_error!=.None {
        report_line(&added.failures,"%s: %s could not be written (%v): a folder is relative to the assets, with forward slashes, and never leaves them",top,asset.PACKAGES_FILE,pin_error)
        return
    }
    added.packages=1
    if !model {package_refresh(&l,top,entry,&added,true)}
    return
}

// A list of what was written the pin keeps, by id, in the temp allocator.
@(private="file")
written_list :: proc(written:[]asset.Package_Written) -> [dynamic]asset.Package_Written {
    list:=make([dynamic]asset.Package_Written,context.temp_allocator)
    append(&list,..written)
    slice.sort_by(list[:],proc(a,b:asset.Package_Written) -> bool {return a.id[0]<b.id[0] || a.id[0]==b.id[0] && a.id[1]<b.id[1]})
    return list
}

// Brings the packages the project at root pins to builds this engine reads,
// and its documents along. The report, in allocator, says what was ingested
// or fetched, and by package name what no source here and no peer gave.
project_refresh :: proc(root:string,options:Library_Options,allocator:=context.allocator) -> (report:Library_Report) {
    report_begin(&report,allocator)
    l:Library_State
    library_begin(&l,options,allocator)
    defer library_end(&l)
    context.temp_allocator=l.temp
    top:=project.path_absolute(root,context.temp_allocator)
    lock,locked:=project_pin_lock(top)
    if !locked {project_pin_lock_report(&report,top);return}
    defer workspace.lock_release(&lock)
    list,_,error:=asset.packages_load(top,context.temp_allocator)
    if error!=.None {
        report_line(&report.failures,"%s/%s does not read (%v): fix it from its history; nothing was refreshed",top,asset.PACKAGES_FILE,error)
        return
    }
    report.packages=len(list.packages)
    if len(list.packages)==0 {return}
    index:=store.read_index(options.store)
    l.index=&index
    project_follow_begin(&l,top)
    refresh_prefetch(&l,top,list.packages[:])
    for &entry,at in list.packages {
        if options.progress.procedure!=nil {fmt.wprintfln(options.progress,"package %d of %d",at+1,len(list.packages))}
        package_refresh(&l,top,entry,&report,false)
    }
    return
}

// Pins entry in the packages.mirai of the project at root, in place of the
// entry of the same package, and writes beside it the text of the manifest
// that s keeps under entry.manifest (asset.package_file). It and
// project_unpin are the only writers of those files. A pin lands whole or
// leaves the root as it was: a list that does not save puts the manifest's
// file back.
project_pin :: proc(root:string,s:^store.Store,entry:asset.Project_Package) -> asset.Error {
    lock,locked:=project_pin_lock(root,wait=false)
    if !locked {return .IO}
    defer workspace.lock_release(&lock)
    return project_pin_locked(root,s,entry)
}

@(private="file")
project_pin_locked :: proc(root:string,s:^store.Store,entry:asset.Project_Package) -> (error:asset.Error) {
    list,_,read_error:=asset.packages_load(root,context.temp_allocator)
    if read_error!=.None {return read_error}
    backups:=importer.document_backups_begin()
    defer {
        path,_:=importer.document_backups_finish(&backups,error==.None)
        if path!="" {error=.IO}
    }
    return project_pin_many(root,s,&list,[]asset.Project_Package{entry},&backups)
}

@(private="file")
project_pin_lock :: proc(root:string,wait:=true) -> (workspace.Lock,bool) {
    path:=fmt.tprintf("%s/.mirai/locks/pins",root)
    what:="mirai project packages"
    if wait {return workspace.lock_acquire(path,what)}
    lock,taken,_,_:=workspace.lock_take(path,what)
    return lock,taken
}

@(private="file")
project_pin_lock_report :: proc(report:^Library_Report,root:string) {
    report_line(&report.failures,"%s/%s could not be locked: check that the project is writable",root,asset.PACKAGES_FILE)
}

@(private="file")
project_pin_many :: proc(root:string,s:^store.Store,list:^asset.Packages,entries:[]asset.Project_Package,backups:^importer.Document_Backups) -> asset.Error {
    indices:=make(map[base.Asset_Id]int,context.temp_allocator)
    for &entry,at in list.packages {indices[entry.id]=at}
    for entry in entries {
        if at,replaced:=indices[entry.id];replaced {
            list.packages[at]=entry
        } else {
            indices[entry.id]=len(list.packages)
            if _,no_room:=append(&list.packages,entry);no_room!=nil {return .Out_Of_Memory}
        }
    }
    asset.packages_text(list,context.temp_allocator) or_return
    for &entry in entries {
        importer.document_backup(backups,asset.package_file(root,entry.id)) or_return
        asset.package_file_save(s,root,&entry) or_return
    }
    return asset.packages_save(root,list)
}

// Removes the package id from the packages.mirai of the project at root, and
// the file of its manifest; what the store keeps of it stays. False with
// nothing to remove.
project_unpin :: proc(root:string,id:base.Asset_Id) -> (removed:bool,error:asset.Error) {
    lock,locked:=project_pin_lock(root,wait=false)
    if !locked {return false,.IO}
    defer workspace.lock_release(&lock)
    list,_:=asset.packages_load(root,context.temp_allocator) or_return
    for &other,at in list.packages {
        if other.id!=id {continue}
        ordered_remove(&list.packages,at)
        asset.packages_save(root,&list) or_return
        removed=true
        break
    }
    return removed,asset.package_file_remove(root,id)
}

// What ingest, project_add and project_refresh share for one call.
@(private="file")
Library_State :: struct {
    options:Library_Options,
    index:^store.Store,            // the Store index for all reads in a project refresh
    scratch:mem.Dynamic_Arena,
    temp:mem.Allocator,
    plugins:Library_Imports,
    plugins_read:bool,
    formats:[]importer.Format,     // FORMATS and those of the plugins, once read
    assets:string,                 // of the project followed
    registry:^asset.Registry,      // its assets, scanned once
    asked:map[string]bool,         // "<namespace>/<name>" asked of the source, and whether it gave it
    adding:bool,
    preparing:bool,
    prepared:[dynamic]Prepared_Add,
    pins:[dynamic]asset.Project_Package,
    backups:importer.Document_Backups,
}

@(private="file")
Prepared_Add :: struct {
    entry:asset.Project_Package,
    pkg:asset.Package,
    build:asset.Build,
    prefab:bool,
}

@(private="file")
library_begin :: proc(l:^Library_State,options:Library_Options,allocator:mem.Allocator) {
    l.options=options
    mem.dynamic_arena_init(&l.scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    l.temp=base.dynamic_arena_allocator(&l.scratch)
    l.formats=FORMATS[:]
    l.asked=make(map[string]bool,l.temp)
}

@(private="file")
library_end :: proc(l:^Library_State) {
    if l.plugins.release!=nil {l.plugins.release(l.plugins.state)}
    mem.dynamic_arena_destroy(&l.scratch)
}

@(private="file")
library_index :: proc(l:^Library_State) -> ^store.Store {
    return l.index if l.index!=nil else l.options.store
}

// The formats, the whole importers and the game types of the plugins of the
// root of the library, read the first time a source needs them.
@(private="file")
plugins_read :: proc(l:^Library_State) {
    if l.plugins_read {return}
    l.plugins_read=true
    switch {
    case l.options.imports!=nil:
        l.plugins=l.options.imports^
        l.plugins.release=nil
    case l.options.plugins==nil || l.options.root=="": return
    case: l.plugins=l.options.plugins(l.options.root,l.options.store,l.temp)
    }
    all:=make([dynamic]importer.Format,0,len(FORMATS)+len(l.plugins.formats),l.temp)
    append(&all,..FORMATS[:])
    append(&all,..l.plugins.formats)
    l.formats=all[:]
}

@(private="file")
project_follow_begin :: proc(l:^Library_State,top:string) {
    if l.options.root=="" {l.options.root=top}
    l.assets=project.folder_path(top,.Assets,l.temp)
    l.registry=new(asset.Registry,l.temp)
    asset.registry_init(l.registry,l.assets,"",l.temp)
    asset.registry_scan(l.registry)
}

// What reads the source at origin: kind (None for one a plugin imports
// whole), the formats it is read with and the whole importer that claims it.
@(private="file")
Source_Reader :: struct {
    kind:Source_Kind,
    whole:Whole_Source,
    claimed:bool,
}

@(private="file")
reader_of :: proc(l:^Library_State,origin:string) -> (r:Source_Reader,ok:bool) {
    r.kind=source_kind(origin,l.formats)
    if r.kind==.None || r.kind==.Model {
        plugins_read(l)
        if r.whole,r.claimed=whole_find(l.plugins.wholes,origin);r.claimed {return {kind=.None,whole=r.whole,claimed=true},true}
        r.kind=source_kind(origin,l.formats)
    }
    return r,r.kind!=.None
}

// The key of the build of p this engine reads (importer.build_key): the
// versions of the engine with that of what reads its origin, an engine
// importer, a format of the engine or of the plugins, or the importer of a
// plugin that imports it whole, with the code of that plugin. False when none
// of those is the one its manifest records.
@(private="file")
package_key :: proc(l:^Library_State,p:^asset.Package) -> (key:store.Hash,ok:bool) {
    version:u32
    code:u64
    switch p.origin.importer {
    case "image","sound","font","prompts":
        version=importer.import_version(0)
    case:
        found:=false
        for format in FORMATS {
            if format.name==p.origin.importer {version,found=importer.import_version(format.version),true}
        }
        if !found {
            plugins_read(l)
            for format in l.formats {
                if format.name==p.origin.importer {version,found=importer.import_version(format.version),true}
            }
            for whole in l.plugins.wholes {
                if !found && whole.name!="" && whole.name==p.origin.importer {version,code,found=importer.import_version(whole.version),whole.code,true}
            }
        }
        if !found {return}
    }
    return importer.build_key(p.identity,version,code),true
}

@(private="file")
Found :: struct {
    build:asset.Build,
    hash:store.Hash,
    final:bool,
    fast_here:bool, // a Fast build is here, which a Final one was required over
}

// The build of p under key this store has whole: Final, or Fast when Fast
// textures are allowed. A build is taken only under the namespace of what its
// manifest says it is.
@(private="file")
build_here :: proc(l:^Library_State,p:^asset.Package,key:store.Hash) -> (f:Found,ok:bool) {
    s:=library_index(l)
    digits:[64]u8
    name:=store.hex(key,&digits)
    for namespace,at in ([2]string{asset.REF_IMPORTS,asset.REF_IMPORTS_FAST}) {
        hash,ref_error:=store.ref_get(s,namespace,name)
        if ref_error!=.None {continue}
        b,error:=asset.build_get(s,hash,l.temp)
        if error!=.None || b.package_id!=p.id || b.key!=key || b.final!=(at==0) {continue}
        if !asset.build_whole(s,&b) {continue}
        if at==1 && !l.options.fast_textures {
            f.fast_here=true
            continue
        }
        return {build=b,hash=hash,final=at==0},true
    }
    return
}

// The build of p this engine reads here: by its key, or for a source whose
// importer this library lacks (a plugin that imports it whole and is not
// read), the one this machine chose for its manifest (asset.REF_BUILDS) when
// it is whole.
@(private="file")
build_found :: proc(l:^Library_State,p:^asset.Package,manifest,key:store.Hash,keyed:bool) -> (f:Found,ok:bool) {
    if keyed {return build_here(l,p,key)}
    s:=library_index(l)
    digits:[64]u8
    hash,ref_error:=store.ref_get(s,asset.REF_BUILDS,store.hex(asset.build_select(manifest,p),&digits))
    if ref_error!=.None {return}
    b,error:=asset.build_get(s,hash,l.temp)
    if error!=.None || b.package_id!=p.id {return}
    if !asset.build_whole(s,&b) {return}
    if !b.final && !l.options.fast_textures {return {fast_here=true},false}
    return {build=b,hash=hash,final=b.final},true
}

// Asks the source of the library for the ref (namespace, name), once per call
// of the library.
@(private="file")
fetch :: proc(l:^Library_State,namespace,name:string) -> bool {
    if given,asked:=l.asked[fmt.aprintf("%s/%s",namespace,name,allocator=l.temp)];asked {return given}
    names:=[1]string{name}
    fetch_many(l,namespace,names[:])
    return l.asked[fmt.aprintf("%s/%s",namespace,name,allocator=l.temp)]
}

// Asks the source for the refs of namespace with names together, but those
// asked before.
@(private="file")
fetch_many :: proc(l:^Library_State,namespace:string,names:[]string) {
    source:=l.options.source
    if source.fetch==nil || len(names)==0 {return}
    asking:=make([dynamic]string,l.temp)
    keys:=make([dynamic]string,l.temp)
    for name in names {
        key:=fmt.aprintf("%s/%s",namespace,name,allocator=l.temp)
        if key in l.asked {continue}
        l.asked[key]=false
        append(&asking,name)
        append(&keys,key)
    }
    given:=make([]bool,len(asking),l.temp)
    source.fetch(source.user,l.options.store,namespace,asking[:],given)
    for key,k in keys {l.asked[key]=given[k]}
}

// Asks the source for the builds of the keys (hex of import keys) together:
// Final, then, with Fast textures allowed, Fast for those it gave no Final of.
@(private="file")
fetch_builds :: proc(l:^Library_State,keys:[]string) {
    fetch_many(l,asset.REF_IMPORTS,keys)
    if !l.options.fast_textures {return}
    lacking:=make([dynamic]string,l.temp)
    for key in keys {
        if !build_given(l,key) {append(&lacking,key)}
    }
    fetch_many(l,asset.REF_IMPORTS_FAST,lacking[:])
}

// Whether the source gave a build of the key (hex of an import key).
@(private="file")
build_given :: proc(l:^Library_State,key:string) -> bool {
    return l.asked[fmt.aprintf("%s/%s",asset.REF_IMPORTS,key,allocator=l.temp)] || l.asked[fmt.aprintf("%s/%s",asset.REF_IMPORTS_FAST,key,allocator=l.temp)]
}

// What a refresh will ask the source for, asked together before the packages
// are refreshed in order, which then find it here: the manifests the store
// does not keep, then the builds of the packages that have none here and no
// changed source here to ingest again: by key, or the build a peer chose for
// one whose importer this library lacks. A refresh asks for nothing else.
@(private="file")
refresh_prefetch :: proc(l:^Library_State,top:string,entries:[]asset.Project_Package) {
    if l.options.source.fetch==nil {return}
    s:=library_index(l)
    lacking:=make([dynamic]string,l.temp)
    for entry in entries {
        entry:=entry
        if _,error:=asset.package_load(s,top,&entry,l.temp);error==.Not_Found {
            digits:[64]u8
            append(&lacking,strings.clone(store.hex(entry.manifest,&digits),l.temp))
        }
    }
    fetch_many(l,asset.REF_MANIFESTS,lacking[:])
    keys:=make([dynamic]string,l.temp)
    choices:=make([dynamic]string,l.temp) // of the packages whose importer this library lacks: the build a peer chose
    for entry in entries {
        entry:=entry
        p,error:=asset.package_load(s,top,&entry,l.temp)
        if error!=.None {continue}
        source:=importer.origin_path(p.origin.path,top)
        if source!="" && !importer.unsafe_path(source) && os.exists(source) && source_changed(l,&p,source) {continue}
        key,keyed:=package_key(l,&p)
        if _,found:=build_found(l,&p,entry.manifest,key,keyed);found {continue}
        digits:[64]u8
        if keyed {
            append(&keys,strings.clone(store.hex(key,&digits),l.temp))
        } else {
            append(&choices,strings.clone(store.hex(asset.build_select(entry.manifest,&p),&digits),l.temp))
        }
    }
    fetch_builds(l,keys[:])
    fetch_many(l,asset.REF_BUILDS,choices[:])
}

// The import of the source at origin into the store, with its lock: what
// ingest does. manifest: the package it was ingested as (zero: the one this
// machine names for origin). documents: the folder of the project the
// documents and the prefab of the import are written or followed in ("":
// none), with the registry and the game types of the library; written and
// changed: what the project's pin records its files held when last written,
// and what becomes of one that changed since (Import_Options.changed).
@(private="file")
library_ingest :: proc(l:^Library_State,path:string,manifest:store.Hash,settings:^importer.Import_Settings,documents:string,written:[]asset.Package_Written,changed:importer.Changed,allocator:mem.Allocator) -> (report:importer.Import_Report,error:importer.Error) {
    caller:=context.temp_allocator
    context.temp_allocator=l.temp
    s:=l.options.store
    if s==nil {return {},importer.error_make(.Write,"%s: the library keeps packages in a store: give it one",path,allocator=caller)}
    if importer.unsafe_path(path) || !os.exists(path) {return {},importer.error_make(.Not_Found,"%s does not exist",path,allocator=caller)}
    origin:=importer.path_key(path)
    r,known:=reader_of(l,origin)
    if !known {
        return {},importer.error_make(.Unsupported,"%s is not a source Mirai imports: a model (%s), an image, a sound (WAV, Ogg Vorbis), a font (TrueType, OpenType) or a manifest of prompts (%s); a format a plugin adds imports with the plugin in the project%s",
            origin,importer.format_names(l.formats),importer.PROMPTS_MANIFEST,l.plugins.problem!=""?fmt.tprintf(" (%s)",l.plugins.problem):"",allocator=caller)
    }
    name:[64]u8
    lock,locked:=workspace.lock_acquire(fmt.tprintf("%s/locks/%s",s.root,asset.origin_name(origin,&name)),fmt.tprintf("mirai ingest %s",origin))
    defer if locked {workspace.lock_release(&lock)}
    hashes:=importer.source_hashes_load(s,origin,l.temp)
    defer importer.source_hashes_save(s,origin,&hashes)
    code:=r.whole.code if r.claimed else 0
    // Current: the work is done, here or by another process that held the lock.
    if !l.options.rebuild && settings==nil && documents=="" {
        if p,hash,found,_:=importer.package_previous(s,manifest,origin,l.temp);found {
            kept,valid:=importer.settings_parse(p.settings)
            if valid && importer.identity_of(p.id,origin,p.inputs[:],kept,code,&hashes)==p.identity {
                key,keyed:=package_key(l,&p)
                if f,here:=build_found(l,&p,hash,key,keyed);here {
                    {
                        importer.report_init(&report,allocator)
                        report.package_id,report.manifest,report.build,report.key,report.final=p.id,hash,f.hash,key,f.final
                        report.settings=kept
                        return
                    }
                }
            }
        }
    }
    options:=importer.Import_Options{
        store=s,cache_source=l.options.source,manifest=manifest,documents=documents,root=l.options.root,
        rebuild=l.options.rebuild,fast_textures=l.options.fast_textures,worker=l.options.worker,hashes=&hashes,
    }
    if documents!="" {options.registry,options.world,options.written,options.changed=l.registry,l.plugins.world,written,changed}
    if options.root=="" {options.root,_=importer.source_root(origin,l.temp)}
    if settings!=nil {options.settings,options.ignore_stored=settings^,true}
    progress:importer.Progress
    if l.options.progress.procedure!=nil {
        importer.progress_begin(&progress,l.options.progress,filepath.base(origin))
        options.progress=&progress
    }
    wholes:[]Whole_Source
    if r.claimed {wholes=l.plugins.wholes}
    report,error=import_source(origin,options,l.formats,wholes,allocator)
    if error.code!=.None {error.message=strings.clone(error.message,caller)}
    return
}

// One package a project pins, brought to a build this engine reads and
// followed into the project: when its build changed, or always with follow.
@(private="file")
package_refresh :: proc(l:^Library_State,top:string,entry:asset.Project_Package,report:^Library_Report,follow:bool,known:^asset.Package=nil) {
    s:=l.options.store
    index:=library_index(l)
    entry:=entry
    digits,id_text:[64]u8
    id_name:=base.asset_id_format(entry.id,id_text[:32])
    p:asset.Package
    error:asset.Error
    if known!=nil {
        p=known^
    } else {
        manifest_root:=top if !l.adding else ""
        p,error=asset.package_load(index,manifest_root,&entry,l.temp)
        if error==.Not_Found && fetch(l,asset.REF_MANIFESTS,store.hex(entry.manifest,&digits)) {
            p,error=asset.package_load(index,manifest_root,&entry,l.temp)
        }
    }
    #partial switch error {
    case .None:
    case .Not_Found:
        report_line(&report.missing,"package %s: neither the store at %s nor %s has its manifest %s, and no peer gave it: restore that file from version control",id_name,s.root,asset.package_file(top,entry.id),store.hex(entry.manifest,&digits))
        return
    case .Hash:
        report_line(&report.failures,"package %s: %s is not the manifest %s/%s pins: restore both from version control, or ingest its source again",id_name,asset.package_file(top,entry.id),top,asset.PACKAGES_FILE)
        return
    case:
        report_line(&report.failures,"package %s: its manifest %s in the store at %s is not a package of this version (%v): ingest its source again",id_name,store.hex(entry.manifest,&digits),s.root,error)
        return
    }
    source:=importer.origin_path(p.origin.path,top)
    origin_here:=!l.preparing && source!="" && !importer.unsafe_path(source) && os.exists(source)
    documents:=documents_folder(l.assets,entry.folder)
    prefab:=model_prefab_of(l,&p)
    if prefab && len(entry.assets)>0 {
        selected,_,selection_error:=asset.package_selection(&p,entry.assets[:],l.temp)
        if selection_error!=.None {
            report_line(&report.failures,"package %s: the selected assets could not be read (%v)",p.name,selection_error)
            return
        }
        prefab=false
        id:=prefab_id(&p)
        for a,at in p.assets {
            if a.id!=id {continue}
            prefab=selected[at]
            break
        }
    }
    // A source here that changed is ingested again, keeping its ids, and the project follows it.
    if origin_here && source_changed(l,&p,source) {
        reingest(l,top,&entry,&p,source,documents,prefab,"its source changed",report)
        return
    }
    key,keyed:=package_key(l,&p)
    f:Found
    found:bool
    f,found=build_found(l,&p,entry.manifest,key,keyed)
    key_name:=strings.clone(store.hex(key,&digits),l.temp)
    select:=strings.clone(store.hex(asset.build_select(entry.manifest,&p),&digits),l.temp)
    chosen_given:=false // the ref of this machine's choice is the one the source gave, not yet followed
    switch {
    case keyed && found && build_given(l,key_name):
        // The source gave it before the refresh came to it.
        report.fetched+=1
    case keyed && !found:
        names:=[1]string{key_name}
        fetch_builds(l,names[:])
        if build_given(l,key_name) {
            if f,found=build_here(l,&p,key);found {report.fetched+=1}
        }
    case !keyed:
        // Without its importer the build is the one a peer chose for its manifest.
        if !found && fetch(l,asset.REF_BUILDS,select) {f,found=build_found(l,&p,entry.manifest,key,keyed)}
        chosen_given=found && l.asked[fmt.tprintf("%s/%s",asset.REF_BUILDS,select)]
        if chosen_given {report.fetched+=1}
    }
    if !found {
        if origin_here {
            reingest(l,top,&entry,&p,source,documents,prefab,"this engine reads no build of it here",report)
            return
        }
        switch {
        case !keyed:
            problem:=l.plugins.problem!="" ? fmt.tprintf(" (%s)",l.plugins.problem) : ""
            report_line(&report.missing,"package %s: no plugin of the project read here imports it as %q%s, so its build cannot be found by key, and no peer gave the build it chose: build the project's editor with the plugin that imports it active, or ingest its source (%s) with this engine",p.name,p.origin.importer,problem,p.origin.path)
        case f.fast_here:
            report_line(&report.missing,"package %s: only a build with Fast textures is here, and Final is required: a machine with its source (%s) must ingest it with this engine, or a peer that has its Final build (import key %s) must give it",p.name,p.origin.path,store.hex(key,&digits))
        case:
            report_line(&report.missing,"package %s: no build of it for this engine (import key %s) is here or at a peer: a machine with its source (%s) must ingest it with this engine",p.name,store.hex(key,&digits),p.origin.path)
        }
        return
    }
    previous,_:=store.ref_get(index,asset.REF_BUILDS,select)
    if previous!=f.hash {
        if ref_error:=store.ref_set(s,asset.REF_BUILDS,select,f.hash);ref_error!=.None {
            report_line(&report.failures,"package %s: the ref %s/%s could not be set in the store at %s: %v",p.name,asset.REF_BUILDS,select,s.root,ref_error)
            return
        }
    }
    if l.preparing {
        if _,error:=append(&l.prepared,Prepared_Add{entry,p,f.build,prefab});error!=nil {
            report_line(&report.failures,"package %s: out of memory preparing the addition",p.name)
        }
        return
    }
    if !follow && previous==f.hash && !chosen_given {return}
    // A model's prefab is written from its source in the game's types: the import does it, with the documents.
    if prefab && origin_here && plugins_world(l)!=nil {
        reingest(l,top,&entry,&p,source,documents,prefab,"it is followed into the project",report)
        return
    }
    documents_write(l,top,&entry,&p,&f.build,documents,report)
    if prefab && follow {warn_missing_prefab(l,&p,report)}
}

@(private="file")
documents_folder :: proc(assets,folder:string) -> string {
    return assets if folder=="" else fmt.tprintf("%s/%s",assets,folder)
}

@(private="file")
warn_missing_prefab :: proc(l:^Library_State,p:^asset.Package,report:^Library_Report) {
    if _,has:=asset.registry_find(l.registry,prefab_id(p));!has {
        report_line(&report.warnings,"package %s: its prefab is written from its source (%s) in the types of the game: add it individually on a machine that has the source, with the project's editor built",p.name,p.origin.path)
    }
}

// The types of the game of the library's root, read once.
@(private="file")
plugins_world :: proc(l:^Library_State) -> ^core.World_Info {
    plugins_read(l)
    return l.plugins.world
}

// Writes or follows the documents of the build b of p into documents and pins
// what their files hold as it leaves them in entry.
@(private="file")
documents_write :: proc(l:^Library_State,top:string,entry:^asset.Project_Package,p:^asset.Package,b:^asset.Build,documents:string,report:^Library_Report) {
    changed:=importer.Changed.Discard if l.options.changed==.Discard else .Keep
    build:=b^
    if len(entry.assets)>0 {
        selected,_,selection_error:=asset.package_selection(p,entry.assets[:],l.temp)
        if selection_error!=.None {
            report_line(&report.failures,"package %s: the selected documents could not be read (%v)",p.name,selection_error)
            return
        }
        used:=make(map[base.Asset_Id]bool,l.temp)
        for a,at in p.assets {used[a.id]=selected[at]}
        build.outputs=make([dynamic]asset.Build_Output,l.temp)
        for o in b.outputs {
            if used[o.id] {append(&build.outputs,o)}
        }
    }
    backups:=&l.backups if l.preparing else nil
    written,error:=importer.documents_follow(l.options.store,p,&build,documents,l.registry,entry.written[:],changed,plugin_kinds(l),l.temp,backups=backups)
    if error.code!=.None {
        report_line(&report.failures,"package %s: %s",p.name,error.message)
        return
    }
    recorded:=make([dynamic]asset.Package_Written,l.temp)
    for w in written {
        if w.warning!="" {report_line(&report.warnings,"package %s: %s",p.name,w.warning)}
        if w.hash!=0 {append(&recorded,asset.Package_Written{w.id,w.hash})}
    }
    written_pin(l,top,entry,recorded[:],p,report)
}

// The extensions of the kinds of the active plugins of the root of the
// library, which a new file of a document of theirs takes.
@(private="file")
plugin_kinds :: proc(l:^Library_State) -> []importer.Kind_Extension {
    if l.options.root=="" {return nil}
    p,error:=project.open(l.options.root,project.engine_root_find("",context.temp_allocator),context.temp_allocator)
    if error.code!=.None {return nil}
    out:=make([dynamic]importer.Kind_Extension,l.temp)
    for index in p.active {
        for &k in p.plugins[index].manifest.asset_kinds {
            extension,code:=base.text_get(k.extension[:]),base.text_get(k.kind[:])
            if extension!="" && code!="" {append(&out,importer.Kind_Extension{asset.fourcc(code),strings.clone(extension,l.temp)})}
        }
    }
    return out[:]
}

// Pins in entry what the files of its documents hold as written, when it
// differs from what it records.
@(private="file")
written_pin :: proc(l:^Library_State,top:string,entry:^asset.Project_Package,written:[]asset.Package_Written,p:^asset.Package,report:^Library_Report) {
    // A document of the package this pass did not write holds what it held, so
    // its record stays: a model's prefab, which only a library with the game's
    // types writes, is not forgotten by a refresh without them.
    merged:=make([dynamic]asset.Package_Written,context.temp_allocator)
    append(&merged,..written)
    records: for old in entry.written {
        for w in written {
            if w.id==old.id {continue records}
        }
        for &a in p.assets {
            if a.id==old.id {
                append(&merged,old)
                continue records
            }
        }
    }
    written:=written_list(merged[:])
    same:=len(written)==len(entry.written)
    for w,at in written {
        if !same {break}
        same=entry.written[at]==w
    }
    if same && !l.adding {return}
    entry.written=written
    if l.preparing {
        if _,error:=append(&l.pins,entry^);error!=nil {
            report_line(&report.failures,"package %s: out of memory recording the addition",p.name)
        }
        return
    }
    if pin_error:=project_pin_locked(top,l.options.store,entry^);pin_error!=.None {
        report_line(&report.failures,"package %s: %s/%s could not be written: %v",p.name,top,asset.PACKAGES_FILE,pin_error)
    }
}

// Whether what the source of p, here at source, is made from now is not what
// p was ingested from: its bytes, those of its inputs, or the code of the
// plugin that imports it whole.
@(private="file")
source_changed :: proc(l:^Library_State,p:^asset.Package,source:string) -> bool {
    settings,valid:=importer.settings_parse(p.settings)
    if !valid {return false}
    code:u64
    if r,known:=reader_of(l,source);known && r.claimed {code=r.whole.code}
    hashes:=importer.source_hashes_load(library_index(l),source,l.temp)
    defer importer.source_hashes_save(l.options.store,source,&hashes)
    return importer.identity_of(p.id,source,p.inputs[:],settings,code,&hashes)!=p.identity
}

// Ingests the source of p again, here at source, keeping its ids, and pins
// the manifest it gives; a model is imported with the project's folder, which follows its
// documents and writes its prefab, and any other follows from its build.
@(private="file")
reingest :: proc(l:^Library_State,top:string,entry:^asset.Project_Package,p:^asset.Package,source,documents:string,prefab:bool,why:string,report:^Library_Report) {
    if l.options.progress.procedure!=nil {fmt.wprintfln(l.options.progress,"importing %s: %s",source,why)}
    started:=time.tick_now()
    model:=prefab && plugins_world(l)!=nil
    changed:=importer.Changed.Discard if l.options.changed==.Discard else .Keep
    written,error:=library_ingest(l,source,entry.manifest,nil,documents if model else "",entry.written[:],changed,l.temp)
    if error.code!=.None {
        report_line(&report.failures,"package %s: %s",p.name,error.message)
        return
    }
    defer importer.report_destroy(&written)
    report.ingested+=1
    for warning in written.warnings {report_line(&report.warnings,"package %s: %s",p.name,warning)}
    if l.options.progress.procedure!=nil {fmt.wprintfln(l.options.progress,"  %s: %d assets, %.1f s",p.name,len(written.assets),time.duration_seconds(time.tick_since(started)))}
    if written.manifest!=entry.manifest {
        entry.manifest=written.manifest
        if !l.adding {
            if pin_error:=project_pin_locked(top,l.options.store,entry^);pin_error!=.None {
                report_line(&report.failures,"package %s: %s/%s could not be written: %v",p.name,top,asset.PACKAGES_FILE,pin_error)
                return
            }
        }
    }
    if model {
        written_pin(l,top,entry,written.written[:],p,report)
        return
    }
    again,read_error:=asset.package_get(l.options.store,written.manifest,l.temp)
    b,build_error:=asset.build_get(l.options.store,written.build,l.temp)
    if read_error!=.None || build_error!=.None {
        report_line(&report.failures,"package %s: the store at %s does not read what its import put (%v, %v)",p.name,l.options.store.root,read_error,build_error)
        return
    }
    documents_write(l,top,entry,&again,&b,documents,report)
    if prefab {
        if _,has:=asset.registry_find(l.registry,prefab_id(&again));!has {
            report_line(&report.warnings,"package %s: its prefab is written in the types of the game, which the library of the project's editor has: %s",p.name,"build the project's editor, then refresh")
        }
    }
}

// Whether p is a model whose prefab its import writes from the source: one a
// format reads, with a scene its build has no baseline of.
@(private="file")
model_prefab_of :: proc(l:^Library_State,p:^asset.Package) -> bool {
    if prefab_id(p)=={} {return false}
    for format in FORMATS {
        if format.name==p.origin.importer {return true}
    }
    plugins_read(l)
    for format in l.formats {
        if format.name==p.origin.importer {return true}
    }
    return false
}

@(private="file")
prefab_id :: proc(p:^asset.Package) -> base.Asset_Id {
    for &a in p.assets {
        if a.kind==asset.KIND_SCENE {return a.id}
    }
    return {}
}

@(private="file")
report_begin :: proc(report:^Library_Report,allocator:mem.Allocator) {
    report.allocator=allocator
    report.missing.allocator,report.failures.allocator,report.warnings.allocator=allocator,allocator,allocator
}

@(private="file")
report_line :: proc(lines:^[dynamic]string,format:string,args:..any) {
    append(lines,fmt.aprintf(format,..args,allocator=lines.allocator))
}
