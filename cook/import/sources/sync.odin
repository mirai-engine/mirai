package sources

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"

// Builds again what the imports of a project or a plugin keep in its imported
// folder, which is not versioned, from the sources in its source folder and
// their sidecars: what a build runs before it compiles or cooks. A source is
// imported when one of its outputs of the cache is missing, older than the
// source or its sidecar, of another version of the importer or a texture the
// editor built Fast; what each output was built from is its Import_Info,
// which the import itself compares. A file of the folder that no sidecar
// with its source lists is removed.

Sync_Options :: struct {
    texture_cache,mesh_cache:string, // "": those of the root (project.content_cache_path)
    rebuild:bool,                    // imports every source again
    worker:jobs.Worker_Ref,
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

// Whether the output of the cache at path is what the import of the source
// named, changed at `since` at the latest, gives: there, not older, of that
// source where it is now, written by this importer and, for a texture, Final.
@(private="file")
output_current :: proc(path,named:string,kind:asset.Fourcc,since:time.Time,types:^asset.Types) -> bool {
    info,error:=os.stat(path,context.temp_allocator)
    if error!=nil || time.diff(info.modification_time,since)>0 {return false}
    header,source,imported,peek_error:=asset.import_peek(path,types)
    known,_:=asset.kind_info(kind)
    if peek_error!=.None || !imported || header.kind_version!=known.version || u16(source.importer_version)!=importer.IMPORTER_VERSION || base.text_get(source.source[:])!=named {return false}
    if kind!=asset.KIND_TEXTURE {return true}
    file:asset.Asset
    if asset.asset_load(&file,path,context.temp_allocator)!=.None {return false}
    defer asset.asset_close(&file)
    view,view_error:=asset.texture_view(&file,types)
    return view_error==.None && .Fast not_in view.info.flags
}

// Brings the imported folder of the project or the plugin at root up to date
// with the sources of its source folder. The report, in allocator, counts
// what was imported and lists the sources that did not import: with one, the
// folder is as up to date as the others allow, and nothing is removed from it.
sync :: proc(root:string,options:Sync_Options={},allocator:=context.allocator) -> (report:Sync_Report) {
    report.allocator=allocator
    report.failures.allocator,report.warnings.allocator=allocator,allocator
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    defer asset.types_destroy(&types)

    top:=project.path_absolute(root,context.temp_allocator)
    imported:=project.imported_path(top,context.temp_allocator)
    import_options:=importer.Import_Options{
        root=top,rebuild=options.rebuild,worker=options.worker,
        texture_cache=options.texture_cache if options.texture_cache!="" else project.content_cache_path(top,project.TEXTURE_CACHE,context.temp_allocator),
        mesh_cache=options.mesh_cache if options.mesh_cache!="" else project.content_cache_path(top,project.MESH_CACHE,context.temp_allocator),
    }
    listed:=make(map[string]struct{},context.temp_allocator) // the files of the imported folder the sidecars list
    whole:=true
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,project.folder_path(top,.Source,context.temp_allocator))
    for next:=0;next<len(todo);next+=1 {
        entries,_:=os.read_all_directory_by_path(todo[next],context.temp_allocator)
        for entry in entries {
            file:=fmt.tprintf("%s/%s",todo[next],entry.name)
            if entry.type==.Directory && !strings.has_prefix(entry.name,".") {append(&todo,file)}
            source:=strings.trim_suffix(file,importer.SIDECAR_EXTENSION)
            // A sidecar without its source next to it is of a source outside the root, or of one that is gone.
            if entry.type!=.Regular || source==file || !os.exists(source) || source_kind(source)==.None {continue}
            sidecar,_,error:=importer.sidecar_load(file,context.temp_allocator)
            if error.code!=.None {
                append(&report.failures,strings.clone(error.message,allocator))
                whole=false
                continue
            }
            if sidecar.documents {continue}
            since,_:=os.modification_time_by_path(source)
            if changed,_:=os.modification_time_by_path(file);time.diff(since,changed)>0 {since=changed}
            cached,current:=false,!options.rebuild
            for pass in 0..<2 {
                for output in sidecar.outputs {
                    known,_:=asset.kind_info(output.kind)
                    if !importer.kind_cached(output.kind) || output.shared {continue}
                    buffer:[base.ASSET_ID_TEXT]u8
                    name:=fmt.tprintf("%s%s",base.asset_id_format(output.id,buffer[:]),known.extension)
                    if pass==1 {listed[name]={};continue}
                    cached=true
                    current&&=output_current(fmt.tprintf("%s/%s",imported,name),importer.source_path(import_options,source),output.kind,since,&types)
                }
                if pass==1 || !cached {break}
                report.sources+=1
                if current {continue}
                written,import_error:=import_source(source,"",import_options,nil,allocator)
                if import_error.code!=.None {
                    append(&report.failures,fmt.aprintf("%s: %s",source,import_error.message,allocator=allocator))
                    whole=false
                    break
                }
                report.imported+=1
                for warning in written.warnings {append(&report.warnings,fmt.aprintf("%s: %s",source,warning,allocator=allocator))}
                importer.report_destroy(&written)
                // What the import gives now: a part the source gained, or lost.
                if sidecar,_,error=importer.sidecar_load(file,context.temp_allocator);error.code!=.None {whole=false;break}
            }
        }
    }
    if !whole {return}
    entries,_:=os.read_all_directory_by_path(imported,context.temp_allocator)
    for entry in entries {
        if _,kept:=listed[entry.name];entry.type!=.Regular || kept || strings.has_suffix(entry.name,".tmp") {continue}
        if os.remove(fmt.tprintf("%s/%s",imported,entry.name))==nil {report.removed+=1}
    }
    return
}
