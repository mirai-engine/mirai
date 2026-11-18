package sources

import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:cook/cache"
import importer "mirai:cook/import"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"
import "mirai:store"

// Builds again what the imports of a project or a plugin keep in its imported
// folder, which is not versioned, from the sources in its assets folder and
// their sidecars: what every build of a project runs. An output of the cache
// is current when its file is named by the key of what its import builds from
// now (importer.import_key): the bytes of the source and of the files it
// read, its settings and the importer (for a source a plugin imports whole,
// the code of that plugin), with textures built Final, or Fast under
// Sync_Options.fast_textures, which also takes them Final; a file whose size
// and modification time the cache of the root knows is not read
// (importer.Source_Hashes). An import of documents alone is current by its
// stamp, named the same way. A source with an output that is not current, or
// with a document of a version of its kind this build does not read, is
// imported, with the formats of the engine or, for one none of them reads,
// the importer of a plugin of the project that claims it whole or else the
// formats the plugins add; a file of the folder that no sidecar with its
// source lists is removed.

// What the library of the editor of the project at root gives its imports:
// the formats of models and the importers of whole sources its plugins add,
// with what they read prepared for its assets, and the types of its game,
// which the prefab of a model is written in; release(state) lets them go.
// problem: why there are none. Only a program that links the editor reads it
// (editor.import_library).
Library :: #type proc(root:string,allocator:mem.Allocator) -> Library_Imports
Library_Imports :: struct {
    formats:[]importer.Format,
    wholes:[]Whole_Source,
    world:^core.World_Info,
    release:proc(state:rawptr),
    state:rawptr,
    problem:string,
}

Sync_Options :: struct {
    store:^store.Store,              // whose caches keep what imports build (importer.Import_Options); nil: none
    cache_source:cache.Source,
    rebuild:bool,                    // imports every source again
    // Textures built Fast, as the editor imports them, unless the texture
    // cache keeps them Final: what a build that does not cook needs. Outputs
    // built Final are current too. False: Final, what a cooked game ships.
    fast_textures:bool,
    worker:jobs.Worker_Ref,
    library:Library,                 // nil: the formats of the engine alone, and no model imports
    // Where it says, as it goes, each source it imports, why and how far it
    // is (importer.Progress); nil: nowhere.
    progress:io.Writer,
}

Sync_Report :: struct {
    sources:int,  // with outputs
    imported:int, // imported now
    removed:int,  // files of the imported folder that no sidecar lists, removed
    failures:[dynamic]string, // a source that did not import, with the reason
    warnings:[dynamic]string,
    allocator:mem.Allocator,
}

sync_report_destroy :: proc(report:^Sync_Report) {
    for text in report.failures {delete(text,report.allocator)}
    for text in report.warnings {delete(text,report.allocator)}
    delete(report.failures)
    delete(report.warnings)
    report^={}
}

// Brings the imported folder of the project or the plugin at root up to date
// with the sources of its assets folder. The report, in allocator, counts
// what was imported and lists the sources that did not import: with one, the
// folder is as up to date as the others allow, and nothing is removed from it.
sync :: proc(root:string,options:Sync_Options={},allocator:=context.allocator) -> (report:Sync_Report) {
    report.allocator=allocator
    report.failures.allocator,report.warnings.allocator=allocator,allocator
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)

    top:=project.path_absolute(root,context.temp_allocator)
    imported:=project.imported_path(top,context.temp_allocator)
    assets:=project.folder_path(top,.Assets,context.temp_allocator)
    registry:asset.Registry
    asset.registry_init(&registry,assets,"",context.temp_allocator)
    asset.registry_scan(&registry)
    import_options:=importer.Import_Options{
        root=top,registry=&registry,rebuild=options.rebuild,worker=options.worker,fast_textures=options.fast_textures,
        store=options.store,cache_source=options.cache_source,
    }
    // The library, read once a source needs a format of its plugins or a model imports.
    library:Library_Read
    defer if library.release!=nil {library.release(library.state)}
    versions:=kind_versions(top,context.temp_allocator)
    complete:=true
    // The sources to import, found first so that each line says how many there are.
    Pending :: struct {source:string,formats:[]importer.Format,wholes:[]Whole_Source,kind:Source_Kind,version:u32,code:u64,why:string}
    pending:=make([dynamic]Pending,context.temp_allocator)
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,assets)
    for next:=0;next<len(todo);next+=1 {
        entries,_:=os.read_all_directory_by_path(todo[next],context.temp_allocator)
        for entry in entries {
            file:=fmt.tprintf("%s/%s",todo[next],entry.name)
            if entry.type==.Directory && !strings.has_prefix(entry.name,".") {append(&todo,file)}
            source:=strings.trim_suffix(file,asset.SIDECAR_EXTENSION)
            if entry.type!=.Regular || source==file || !os.exists(source) {continue}
            text,read_error:=os.read_entire_file(file,context.temp_allocator)
            sidecar,valid:=asset.sidecar_parse(string(text),context.temp_allocator)
            if read_error!=nil || !valid {
                append(&report.failures,fmt.aprintf("%s is not the settings and outputs of an import (version %d)",file,asset.SIDECAR_VERSION,allocator=allocator))
                complete=false
                continue
            }
            if len(sidecar.outputs)==0 {continue}
            formats:=FORMATS[:]
            kind:=source_kind(source,formats)
            // A source a plugin imports whole is keyed as a source of no format, with the code of its plugin.
            wholes:[]Whole_Source
            code:u64
            if kind==.None {
                library_read(&library,options,top,&import_options)
                if whole,claimed:=whole_find(library.wholes,source);claimed {
                    wholes,code=library.wholes,whole.code
                } else {
                    all:=make([dynamic]importer.Format,0,len(FORMATS)+len(library.formats),context.temp_allocator)
                    append(&all,..FORMATS[:])
                    append(&all,..library.formats)
                    formats=all[:]
                    if kind=source_kind(source,formats);kind==.None {
                        append(&report.failures,fmt.aprintf("%s: no format or importer of the engine or of the plugins of the project reads it%s",source,library.problem!=""?fmt.tprintf(" (%s)",library.problem):"",allocator=allocator))
                        complete=false
                        continue
                    }
                }
            }
            version:=importer.import_version(0)
            if kind==.Model {
                buffer:[importer.SNIFF_BYTES]u8
                head,_,_:=serial.file_read_head(source,buffer[:])
                if format,found:=importer.format_find(formats,head,filepath.ext(source));found {version=importer.import_version(format.version)}
            }
            report.sources+=1
            why:string
            switch {
            case options.rebuild:why="everything is built again"
            case !documents_read(sidecar,&registry,versions):why="a document of it is of a version this build does not read"
            case:why="what it builds is kept in the store"
            }
            append(&pending,Pending{source,formats,wholes,kind,version,code,why})
        }
    }
    for p,at in pending {
        named:=strings.trim_prefix(p.source,fmt.tprintf("%s/",assets))
        if options.progress.procedure!=nil {fmt.wprintfln(options.progress,"importing %s (%d of %d): %s",named,at+1,len(pending),p.why)}
        started:=time.tick_now()
        if p.kind==.Model {library_read(&library,options,top,&import_options)}
        progress:importer.Progress
        source_options:=import_options
        if options.progress.procedure!=nil {
            importer.progress_begin(&progress,options.progress,named)
            source_options.progress=&progress
        }
        written,import_error:=import_source(p.source,source_options,p.formats,p.wholes,allocator)
        if import_error.code!=.None {
            if options.progress.procedure!=nil {fmt.wprintfln(options.progress,"  %s failed after %.1f s",named,time.duration_seconds(time.tick_since(started)))}
            append(&report.failures,fmt.aprintf("%s: %s",p.source,import_error.message,allocator=allocator))
            complete=false
            continue
        }
        report.imported+=1
        kept:=0
        for asset in written.assets {kept+=int(asset.kept)}
        if options.progress.procedure!=nil {fmt.wprintfln(options.progress,"  %s: %d assets (%d kept), %d warnings, %.1f s",named,len(written.assets),kept,len(written.warnings),time.duration_seconds(time.tick_since(started)))}
        for warning in written.warnings {append(&report.warnings,fmt.aprintf("%s: %s",p.source,warning,allocator=allocator))}
        importer.report_destroy(&written)
    }
    return
}

// Whether this build reads every document the sidecar lists that the assets
// have: one of another version of its kind is made again by importing its
// source. versions: of each kind this build knows (kind_versions).
@(private="file")
documents_read :: proc(sidecar:asset.Sidecar,registry:^asset.Registry,versions:map[asset.Fourcc]u16) -> bool {
    for output in sidecar.outputs {
        if asset.import_cached(output.kind) {continue}
        file,found:=asset.registry_find(registry,output.id)
        if !found {continue}
        if version,known:=versions[file.kind];known && file.kind_version!=version {return false}
    }
    return true
}

// The version of each kind of asset this build reads: those of the engine
// and those the plugins of the engine and of the project at or above root
// declare.
@(private="file")
kind_versions :: proc(root:string,allocator:=context.allocator) -> map[asset.Fourcc]u16 {
    versions:=make(map[asset.Fourcc]u16,allocator)
    for info in asset.KINDS {versions[info.kind]=info.version}
    names:=project.FOLDER_NAMES
    plugins:=make([dynamic]project.Plugin,context.temp_allocator)
    if engine:=project.engine_root_find("",context.temp_allocator);engine!="" {
        _=project.plugins_discover(project.path(engine,names[.Plugins],allocator=context.temp_allocator),.Engine,&plugins,context.temp_allocator)
    }
    for folder:=root;folder!="" && folder!=".";folder=filepath.dir(folder) {
        if os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)) {
            _=project.plugins_discover(project.path(folder,names[.Plugins],allocator=context.temp_allocator),.Project,&plugins,context.temp_allocator)
            break
        }
        if filepath.dir(folder)==folder {break}
    }
    for &plugin in plugins {
        for &kind in plugin.manifest.asset_kinds {
            if letters:=base.text_get(kind.kind[:]);len(letters)==4 {versions[asset.fourcc(letters)]=kind.version}
        }
    }
    return versions
}

@(private="file")
Library_Read :: struct {using imports:Library_Imports,read:bool}

@(private="file")
library_read :: proc(library:^Library_Read,options:Sync_Options,top:string,import_options:^importer.Import_Options) {
    if library.read || options.library==nil {return}
    library.imports=options.library(top,context.temp_allocator)
    import_options.world=library.world
    library.read=true
}
