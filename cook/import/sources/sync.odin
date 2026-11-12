package sources

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import importer "mirai:cook/import"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"

// Builds again what the imports of a project or a plugin keep in its imported
// folder, which is not versioned, from the sources in its assets folder and
// their sidecars: what every build of a project runs. An output is current
// when its file is named by the key of what its import builds from now
// (importer.import_key): the bytes of the source and of the files it read,
// its settings and the importer, with textures built Final, or Fast under
// Sync_Options.fast_textures, which also takes them Final; a file whose
// size and modification time the cache of the root knows is not read
// (importer.Source_Hashes). A source with an
// output that is not is imported, with the formats of the engine or, for one
// none of them reads, the importer of a plugin of the project that claims it
// whole or else the formats the plugins add; a file of the folder that no
// sidecar with its source lists is removed.

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
    texture_cache,mesh_cache:string, // "": those of the root (project.content_cache_path)
    rebuild:bool,                    // imports every source again
    // Textures built Fast, as the editor imports them, unless the texture
    // cache keeps them Final: what a build that does not cook needs. Outputs
    // built Final are current too. False: Final, what a cooked game ships.
    fast_textures:bool,
    worker:jobs.Worker_Ref,
    library:Library,                 // nil: the formats of the engine alone, and no model imports
}

Sync_Report :: struct {
    sources:int,  // with outputs of the cache
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
    asset.registry_init(&registry,assets,"",context.temp_allocator,imported)
    asset.registry_scan(&registry)
    import_options:=importer.Import_Options{
        root=top,registry=&registry,rebuild=options.rebuild,worker=options.worker,fast_textures=options.fast_textures,
        texture_cache=options.texture_cache if options.texture_cache!="" else project.content_cache_path(top,project.TEXTURE_CACHE,context.temp_allocator),
        mesh_cache=options.mesh_cache if options.mesh_cache!="" else project.content_cache_path(top,project.MESH_CACHE,context.temp_allocator),
    }
    // The library, read once a source needs a format of its plugins or a model imports.
    library:Library_Read
    defer if library.release!=nil {library.release(library.state)}
    hashes_path:=project.cache_path(top,importer.SOURCE_HASHES,allocator=context.temp_allocator)
    hashes:=importer.source_hashes_load(hashes_path,context.temp_allocator)
    defer importer.source_hashes_save(&hashes,hashes_path)
    listed:=make(map[string]struct{},context.temp_allocator) // the files of the imported folder the sidecars list
    complete:=true
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,assets)
    for next:=0;next<len(todo);next+=1 {
        entries,_:=os.read_all_directory_by_path(todo[next],context.temp_allocator)
        for entry in entries {
            file:=fmt.tprintf("%s/%s",todo[next],entry.name)
            if entry.type==.Directory && !strings.has_prefix(entry.name,".") {append(&todo,file)}
            source:=strings.trim_suffix(file,importer.SIDECAR_EXTENSION)
            if entry.type!=.Regular || source==file || !os.exists(source) {continue}
            sidecar,_,error:=importer.sidecar_load(source,context.temp_allocator)
            if error.code!=.None {
                append(&report.failures,strings.clone(error.message,allocator))
                complete=false
                continue
            }
            formats:=FORMATS[:]
            kind:=source_kind(source,formats)
            // A source a plugin imports whole is keyed as a source of no format: version 0.
            wholes:[]Whole_Source
            if kind==.None && len(sidecar.outputs)>0 {
                library_read(&library,options,top,&import_options)
                if _,claimed:=whole_find(library.wholes,source);claimed {
                    wholes=library.wholes
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
            // Final is current in either mode; Fast only for a sync of fast textures.
            key:=importer.import_key(source,sidecar,version,false,&hashes)
            cached,current:=outputs_held(sidecar,imported,key)
            if cached && !current && options.fast_textures {
                fast:=importer.import_key(source,sidecar,version,true,&hashes)
                if _,held:=outputs_held(sidecar,imported,fast);held {key,current=fast,true}
            }
            if !cached {continue}
            report.sources+=1
            if !current || options.rebuild {
                if kind==.Model {library_read(&library,options,top,&import_options)}
                written,import_error:=import_source(source,import_options,formats,wholes,allocator)
                if import_error.code!=.None {
                    append(&report.failures,fmt.aprintf("%s: %s",source,import_error.message,allocator=allocator))
                    complete=false
                    continue
                }
                report.imported+=1
                for warning in written.warnings {append(&report.warnings,fmt.aprintf("%s: %s",source,warning,allocator=allocator))}
                importer.report_destroy(&written)
                // What the import gives now: a part the source gained, or lost.
                if sidecar,_,error=importer.sidecar_load(source,context.temp_allocator);error.code!=.None {complete=false;continue}
                key=importer.import_key(source,sidecar,version,options.fast_textures,&hashes)
            }
            for output in sidecar.outputs {
                known,_:=asset.kind_info(output.kind)
                if asset.import_cached(output.kind) {listed[filepath.base(asset.imported_file(imported,output.id,key,known.extension,context.temp_allocator))]={}}
            }
        }
    }
    if !complete {return}
    entries,_:=os.read_all_directory_by_path(imported,context.temp_allocator)
    for entry in entries {
        if _,kept:=listed[entry.name];entry.type!=.Regular || kept || strings.has_suffix(entry.name,".tmp") {continue}
        if os.remove(fmt.tprintf("%s/%s",imported,entry.name))==nil {report.removed+=1}
    }
    return
}

// Whether the sidecar lists outputs of the cache, and whether the imported
// folder has each of them built from key.
@(private="file")
outputs_held :: proc(sidecar:importer.Sidecar,imported:string,key:u64) -> (cached,current:bool) {
    current=true
    for output in sidecar.outputs {
        known,_:=asset.kind_info(output.kind)
        if !asset.import_cached(output.kind) {continue}
        cached=true
        current&&=os.exists(asset.imported_file(imported,output.id,key,known.extension,context.temp_allocator))
    }
    return
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
