package sources

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/textures"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"

// Builds again what the imports of a project or a plugin keep in its imported
// folder, which is not versioned, from its sources and their sidecars: what
// mirai build and mirai import --project run. A source is imported when one
// of its outputs of the cache is missing, or when the source, its sidecar, a
// file it read (the stamp its import leaves lists them with size, time and
// hash) or the build that imports changed. A file of the folder that no
// sidecar lists is removed.

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

@(private="file") STAMP_FOLDER :: ".stamps"
@(private="file") STAMP_MAGIC :: u32('M')|u32('I')<<8|u32('S')<<16|u32('T')<<24
@(private="file") STAMP_VERSION :: 1

@(private="file")
Stamp_File :: struct {
    path:string, // relative to the root when inside it
    size,time:i64,
    hash:u64,
}

// What the build that imports is: a stamp of another one is not current.
@(private="file")
build_key :: proc() -> u64 {
    key:=base.hash_combine(u64(importer.IMPORTER_VERSION),u64(importer.SIDECAR_VERSION))
    key=base.hash_combine(key,u64(STAMP_VERSION))
    key=base.hash_combine(key,u64(textures.BUILD_VERSION))
    key=base.hash_combine(key,importer.MESH_CACHE_VERSION)
    for format in FORMATS {
        key=base.hash_combine(key,base.hash64(transmute([]u8)format.name))
        key=base.hash_combine(key,u64(format.version))
    }
    for kind in asset.KINDS {key=base.hash_combine(key,u64(kind.kind)<<16|u64(kind.version))}
    return key
}

@(private="file")
stamp_path :: proc(root,source:string) -> string {
    named:=strings.to_lower(importer.source_path({root=root},source),context.temp_allocator)
    return fmt.tprintf("%s/%s/%016x.stamp",project.imported_path(root,context.temp_allocator),STAMP_FOLDER,base.hash64(transmute([]u8)named))
}

@(private="file")
stamp_file :: proc(root,path:string) -> (file:Stamp_File,ok:bool) {
    info,error:=os.stat(path,context.temp_allocator)
    if error!=nil || info.type!=.Regular {return}
    data,read_error:=serial.file_read(path,context.temp_allocator,limit=importer.MAX_SOURCE_BYTES)
    if read_error!=.None {return}
    return {importer.source_path({root=root},path),info.size,time.time_to_unix_nano(info.modification_time),base.hash64(data)},true
}

// Leaves the stamp of an import that wrote its assets: what it was built
// from. Only an import into a root has one; one that cannot be written costs
// the next sync importing the source again.
@(private)
stamp_write :: proc(path:string,options:importer.Import_Options,report:^importer.Import_Report) {
    if options.root=="" || filepath.is_abs(importer.source_path(options,path)) || os.is_dir(path) {return}
    sidecar,read_error:=serial.file_read(importer.sidecar_path(path,options.root,allocator=context.temp_allocator),context.temp_allocator)
    if read_error!=.None {return}
    w:serial.Writer
    serial.writer_init(&w,allocator=context.temp_allocator)
    serial.write_u32(&w,STAMP_MAGIC)
    serial.write_u32(&w,STAMP_VERSION)
    serial.write_u64(&w,build_key())
    serial.write_u8(&w,u8(options.fast_textures))
    serial.write_u64(&w,base.hash64(sidecar))
    serial.write_varint(&w,u64(len(report.read)+1))
    for at in -1..<len(report.read) {
        file,ok:=stamp_file(options.root,path if at<0 else report.read[at])
        if !ok {return}
        serial.write_string(&w,file.path)
        serial.write_svarint(&w,file.size)
        serial.write_svarint(&w,file.time)
        serial.write_u64(&w,file.hash)
    }
    target:=stamp_path(options.root,path)
    if folder:=filepath.dir(target);!os.is_dir(folder) {_=os.make_directory_all(folder)}
    if w.overflow==0 {_=serial.file_write_atomic(target,serial.writer_bytes(&w))}
}

// Whether the stamp of a source says its outputs were built from what the
// source, its sidecar and the files it read are now, by this build. A file
// whose size and time are those of the stamp is not read.
@(private="file")
stamp_current :: proc(root,source:string) -> bool {
    data,error:=serial.file_read(stamp_path(root,source),context.temp_allocator)
    if error!=.None {return false}
    r:=serial.reader_init(data)
    if serial.read_u32(&r)!=STAMP_MAGIC || serial.read_u32(&r)!=STAMP_VERSION || serial.read_u64(&r)!=build_key() {return false}
    // A texture the editor built Fast is not what a build, which wants it Final, has.
    if serial.read_u8(&r)!=0 {return false}
    sidecar,read_error:=serial.file_read(importer.sidecar_path(source,root,allocator=context.temp_allocator),context.temp_allocator)
    if read_error!=.None || serial.read_u64(&r)!=base.hash64(sidecar) {return false}
    count:=serial.read_count(&r,1)
    for _ in 0..<count {
        named:=strings.clone(serial.read_string(&r),context.temp_allocator)
        size,changed,hash:=serial.read_svarint(&r),serial.read_svarint(&r),serial.read_u64(&r)
        if r.failed {return false}
        path:=named if filepath.is_abs(named) else project.path(root,named,allocator=context.temp_allocator)
        info,stat_error:=os.stat(path,context.temp_allocator)
        if stat_error!=nil || info.size!=size {return false}
        if time.time_to_unix_nano(info.modification_time)==changed {continue}
        // Touched and the same, as a checkout leaves it: its bytes decide.
        bytes,file_error:=serial.file_read(path,context.temp_allocator,limit=importer.MAX_SOURCE_BYTES)
        if file_error!=.None || base.hash64(bytes)!=hash {return false}
    }
    return !r.failed && count>0
}

// The sidecars under root, by absolute path with forward slashes, but those
// under a folder whose name starts with a dot and, in a project, those of its
// plugins, each of which is a root of its own.
@(private="file")
sidecars_under :: proc(root:string) -> []string {
    found:=make([dynamic]string,context.temp_allocator)
    todo:=make([dynamic]string,context.temp_allocator)
    top:=project.path_absolute(root,context.temp_allocator)
    append(&todo,top)
    names:=project.FOLDER_NAMES
    own_plugins:=os.exists(project.path(top,project.PROJECT_FILE,allocator=context.temp_allocator))
    for next:=0;next<len(todo);next+=1 {
        entries,error:=os.read_all_directory_by_path(todo[next],context.temp_allocator)
        if error!=nil {continue}
        for entry in entries {
            if strings.has_prefix(entry.name,".") {continue}
            path:=fmt.tprintf("%s/%s",todo[next],entry.name)
            if entry.type==.Directory {
                if own_plugins && next==0 && entry.name==names[.Plugins] {continue}
                append(&todo,path)
            } else if entry.type==.Regular && strings.has_suffix(entry.name,importer.SIDECAR_EXTENSION) {
                append(&found,path)
            }
        }
    }
    return found[:]
}

// Brings the imported folder of the project or the plugin at root up to date
// with its sources. The report, in allocator, counts what was imported and
// lists the sources that did not import: with one, the folder is as up to
// date as the others allow, and nothing is removed from it.
sync :: proc(root:string,options:Sync_Options={},allocator:=context.allocator) -> (report:Sync_Report) {
    report.allocator=allocator
    report.failures.allocator,report.warnings.allocator=allocator,allocator
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)

    top:=project.path_absolute(root,context.temp_allocator)
    imported:=project.imported_path(top,context.temp_allocator)
    import_options:=importer.Import_Options{
        root=top,rebuild=options.rebuild,worker=options.worker,
        texture_cache=options.texture_cache if options.texture_cache!="" else project.content_cache_path(top,project.TEXTURE_CACHE,context.temp_allocator),
        mesh_cache=options.mesh_cache if options.mesh_cache!="" else project.content_cache_path(top,project.MESH_CACHE,context.temp_allocator),
    }
    listed:=make(map[string]struct{},context.temp_allocator) // files of the imported folder the sidecars list, in lower case
    stamps:=make(map[string]struct{},context.temp_allocator)
    whole:=true
    for file in sidecars_under(top) {
        source:=file[:len(file)-len(importer.SIDECAR_EXTENSION)]
        sidecar,_,error:=importer.sidecar_load(file,context.temp_allocator)
        if error.code!=.None {
            append(&report.failures,strings.clone(error.message,allocator))
            whole=false
            continue
        }
        cached,missing:=false,false
        for output in sidecar.outputs {
            if output.path=="" {continue}
            cached=true
            missing||=!os.exists(fmt.tprintf("%s/%s",imported,output.path))
        }
        // A source in the source folder under the name of a file that is elsewhere has no cache.
        if !cached {continue}
        report.sources+=1
        stamps[strings.to_lower(filepath.base(stamp_path(top,source)),context.temp_allocator)]={}
        if !os.exists(source) {
            append(&report.failures,fmt.aprintf("%s: the source of %s is missing: restore it, or delete the sidecar, which gives up its assets",source,file,allocator=allocator))
            whole=false
            continue
        }
        if options.rebuild || missing || !stamp_current(top,source) {
            written,import_error:=import_source(source,"",import_options,nil,allocator)
            if import_error.code!=.None {
                append(&report.failures,fmt.aprintf("%s: %s",source,import_error.message,allocator=allocator))
                whole=false
                continue
            }
            report.imported+=1
            for warning in written.warnings {append(&report.warnings,fmt.aprintf("%s: %s",source,warning,allocator=allocator))}
            importer.report_destroy(&written)
            // What the import gives now: a part the source gained, or lost.
            if sidecar,_,error=importer.sidecar_load(file,context.temp_allocator);error.code!=.None {whole=false;continue}
        }
        for output in sidecar.outputs {
            if output.path!="" {listed[strings.to_lower(output.path,context.temp_allocator)]={}}
        }
    }
    if !whole || !os.is_dir(imported) {return}
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,imported)
    for next:=0;next<len(todo);next+=1 {
        entries,error:=os.read_all_directory_by_path(todo[next],context.temp_allocator)
        if error!=nil {continue}
        for entry in entries {
            path:=fmt.tprintf("%s/%s",todo[next],entry.name)
            if entry.type==.Directory {
                if next==0 && entry.name==STAMP_FOLDER {
                    kept,_:=os.read_all_directory_by_path(path,context.temp_allocator)
                    for stamp in kept {
                        if _,used:=stamps[strings.to_lower(stamp.name,context.temp_allocator)];!used {os.remove(fmt.tprintf("%s/%s",path,stamp.name))}
                    }
                } else if !strings.has_prefix(entry.name,".") {
                    append(&todo,path)
                }
                continue
            }
            if entry.type!=.Regular || strings.has_prefix(entry.name,".") || strings.has_suffix(entry.name,".tmp") {continue}
            if _,kept:=listed[strings.to_lower(path[len(imported)+1:],context.temp_allocator)];kept {continue}
            if os.remove(path)==nil {report.removed+=1}
        }
    }
    return
}
