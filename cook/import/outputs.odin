package importer

import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"

// The assets of an import that is not that of one model: the scene of a
// level, the source a plugin imports whole with the models it reads
// (output_model). They are the assets the sidecar of their source lists as
// those of a model are (identity.odin): the root by output_root, each other
// one by kind and name (then index). A new one gets a random id and a file of
// its own, a name with '/' in that folder under the one of the import, and
// outputs_end writes the sidecar. Outputs does not move while it is open: its
// search keeps memory of its own. One thread at a time.
Outputs :: struct {
    w:Writer,
    report:Import_Report,
    source:string, // the source as imports name it
    size,hash:u64,
    version:u32,
    current:Maybe(bool), // every output of the cache the sidecar lists is current: models cook nothing ahead
    scratch:mem.Dynamic_Arena, // the temp memory of the search
}

// Starts the outputs of an import of the file at source, whose bytes have
// size and hash, read by a writer of version (import_version), with the
// settings its sidecar keeps unless options.ignore_stored. folder: under
// the folder of the source, where the new documents of a first import go
// ("" beside it), unless output_part names another.
outputs_begin :: proc(o:^Outputs,source,folder:string,size,hash:u64,version:u32,options:Import_Options,allocator:=context.allocator) -> Error {
    o^={size=size,hash=hash,version=version}
    caller:=context.temp_allocator
    mem.dynamic_arena_init(&o.scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    report_init(&o.report,allocator)
    o.source=source_path(options,source)
    if !writer_init(&o.w,source,folder,options,&o.report,allocator) {
        error:=outputs_error(o,caller)
        outputs_end(o,true)
        return error
    }
    // The settings kept with the source are those of every import of it.
    if o.w.stored && !options.ignore_stored {o.w.options.settings=o.w.sidecar.settings}
    o.report.settings=o.w.options.settings
    return {}
}

// The error of the writer, its message in allocator.
@(private="file")
outputs_error :: proc(o:^Outputs,allocator:mem.Allocator) -> Error {
    return writer_error(&o.w,allocator)
}

// The file (in the temp allocator) and id of the root of the import: the
// output of kind the sidecar of the source lists, of that name when it lists
// several of the kind, else a new one.
output_root :: proc(o:^Outputs,kind:asset.Fourcc,name,extension:string) -> (id:base.Asset_Id,path:string,error:Error) {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    listed:=0
    for output in o.w.sidecar.outputs {listed+=int(output.kind==kind)}
    parts:=[1]Part{{kind=kind,name=name,extension=extension,only=listed<=1}}
    parts_plan(&o.w,parts[:])
    return parts[0].id,strings.clone(parts[0].path,caller),{}
}

// A file the import reads besides its source: the sidecar lists it, and its
// bytes are part of what the outputs of the cache are built from
// (import_key), so sync imports the source again when it changes. Every
// input is given before the first output of the cache is planned, when that
// key is fixed: a new one after it is an error.
output_input :: proc(o:^Outputs,file:string) -> Error {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    if writer_input(&o.w,file) {return {}}
    return input_late(file,caller)
}

// The file and id of another output of kind: the one the sidecar of the
// source lists with that name (the same index first), else a new one, a
// document in folder ("": that of the import).
output_part :: proc(o:^Outputs,kind:asset.Fourcc,name:string,index:int,extension:string,folder:="") -> (id:base.Asset_Id,path:string) {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    parts:=[1]Part{{kind=kind,name=name,index=index,extension=extension}}
    if folder!="" {
        kept:=o.w.folder
        o.w.folder=folder
        defer o.w.folder=kept
        parts_plan(&o.w,parts[:])
    } else {
        parts_plan(&o.w,parts[:])
    }
    return parts[0].id,strings.clone(parts[0].path,caller)
}

// The files and ids of other outputs of kind, by name, as output_part gives
// each. In the temp allocator.
output_parts :: proc(o:^Outputs,kind:asset.Fourcc,names:[]string,index:int,extension:string,folder:="") -> (ids:[]base.Asset_Id,paths:[]string) {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    parts:=make([]Part,len(names),context.temp_allocator)
    for name,i in names {parts[i]={kind=kind,name=name,index=index,extension=extension}}
    kept:=o.w.folder
    if folder!="" {o.w.folder=folder}
    parts_plan(&o.w,parts)
    o.w.folder=kept
    ids=make([]base.Asset_Id,len(parts),caller)
    paths=make([]string,len(parts),caller)
    for &p,i in parts {ids[i],paths[i]=p.id,strings.clone(p.path,caller)}
    return
}

// The Import_Info of an output: the source, what of it the output is and
// the settings it is made from.
output_info :: proc(o:^Outputs,name:string,index:int,settings:u64=0) -> asset.Import_Info {
    return import_info(o.source,name,index,o.size,o.hash,settings,o.version)
}

// Records an output written at path: the report lists it, and a failure of
// the import removes it when it is new.
output_written :: proc(o:^Outputs,id:base.Asset_Id,kind:asset.Fourcc,name,path:string,existed:bool,detail:="") {
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    record(&o.w,id,kind,name,path,o.source,existed,detail)
}

output_warn :: proc(o:^Outputs,format:string,args:..any) {
    append(&o.report.warnings,fmt.aprintf(format,..args,allocator=o.report.allocator))
}

// Ends the outputs: writes the sidecar of the source and gives the report,
// with a warning for each output the sidecar listed that none took. failed
// removes the files the outputs created, leaves the sidecar as it was and
// gives no report.
outputs_end :: proc(o:^Outputs,failed:bool) -> (report:Import_Report) {
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    if failed {
        writer_rollback(&o.w)
        report_destroy(&o.report)
    } else {
        if !writer_finish(&o.w) {writer_warn(&o.w,"%s",o.w.error.message)}
        report=o.report
    }
    asset.types_destroy(&o.w.types)
    delete(o.w.error.message,o.w.allocator)
    mem.dynamic_arena_destroy(&o.scratch)
    o^={}
    return
}
