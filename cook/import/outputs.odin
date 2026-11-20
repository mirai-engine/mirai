package importer

import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"
import "mirai:store"

// The assets of an import that is not that of one model: the scene of a
// level, the source a plugin imports whole with the models it reads
// (output_model). They are the assets of the package of their source as those
// of a model are (identity.odin): the root by output_root, each other one by
// kind and name (then index). Each is written to the file its part gives and
// taken by output_written: a blob of the build, and a document also written
// or followed in the folder of the documents. outputs_end puts the manifest
// and the build in the store. Outputs does not move while it is open: its
// search keeps memory of its own. One thread at a time.
Outputs :: struct {
    w:Writer,
    report:Import_Report,
    source:string, // the source as imports name it
    importer:string,
    size,hash:u64,
    version:u32,
    current:Maybe(bool), // the store has every output of the cache of the package, built from what it is made from now: models cook nothing ahead
    scratch:mem.Dynamic_Arena, // the temp memory of the search
}

// Starts the outputs of an import of the file at source, whose bytes have
// size and hash, read by a writer of version (import_version), with the
// settings its package keeps unless options.ignore_stored. folder: under
// the folder of the documents, where the new documents of a first import go
// ("" in it), unless output_part names another. importer: what reads it, as
// its package records it (asset.Package_Origin.importer).
outputs_begin :: proc(o:^Outputs,source,folder:string,size,hash:u64,version:u32,options:Import_Options,importer:="",allocator:=context.allocator) -> Error {
    o^={size=size,hash=hash,version=version}
    caller:=context.temp_allocator
    mem.dynamic_arena_init(&o.scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    report_init(&o.report,allocator)
    o.source=source_path(source)
    o.importer=strings.clone(importer,context.temp_allocator)
    if !writer_init(&o.w,source,folder,options,&o.report,allocator) {
        error:=writer_error(&o.w,caller)
        _,_=outputs_end(o,true)
        return error
    }
    o.w.version=version
    // The settings its package keeps are those of every import of it.
    if o.w.stored && !options.ignore_stored {
        settings,valid:=settings_parse(o.w.previous.settings)
        if !valid {
            writer_fail(&o.w,.Malformed,"the settings the package of %s keeps (%s) are not those of this build: import it as a new package",source,o.w.previous.settings)
            error:=writer_error(&o.w,caller)
            _,_=outputs_end(o,true)
            return error
        }
        o.w.options.settings=settings
    }
    o.report.settings=o.w.options.settings
    return {}
}

// The file (in the temp allocator) and id of the root of the import: the
// asset of kind the package of the source lists, of that name when it lists
// several of the kind, else a new one.
output_root :: proc(o:^Outputs,kind:asset.Fourcc,name,extension:string) -> (id:base.Asset_Id,path:string,error:Error) {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    listed:=0
    for a in o.w.previous.assets {listed+=int(a.kind==kind)}
    parts:=[1]Part{{kind=kind,name=name,extension=extension,only=listed<=1}}
    parts_plan(&o.w,parts[:])
    return parts[0].id,strings.clone(parts[0].path,caller),{}
}

// A file the import reads besides its source: the package lists it, and its
// bytes are part of what the import is made from (identity_of). Every input
// is given before the first output of the cache is planned, when that is
// fixed: a new one after it is an error.
output_input :: proc(o:^Outputs,file:string) -> Error {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    if writer_input(&o.w,file) {return {}}
    return input_late(file,caller)
}

// The file to write and the id of another output of kind: the asset the
// package of the source lists with that name (the same index first), else a
// new one, a document of folder ("": that of the import) in the folder of the
// documents. Asked for again with the same name and index, it is the same.
output_part :: proc(o:^Outputs,kind:asset.Fourcc,name:string,index:int,extension:string,folder:="") -> (id:base.Asset_Id,path:string) {
    ids,paths:=output_parts(o,kind,{name},index,extension,folder)
    return ids[0],paths[0]
}

// The files and ids of other outputs of kind, by name, as output_part gives
// each. In the temp allocator.
output_parts :: proc(o:^Outputs,kind:asset.Fourcc,names:[]string,index:int,extension:string,folder:="") -> (ids:[]base.Asset_Id,paths:[]string) {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    parts:=make([]Part,len(names),context.temp_allocator)
    for name,i in names {parts[i]={kind=kind,name=name,index=index,extension=extension}}
    kept:=o.w.folder
    if folder!="" && o.w.folder!="" {o.w.folder=folder}
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

// Takes the output id, written to the file its part gave: a blob of the
// build, a document also written or followed in the folder of the documents,
// and the report lists it as name.
output_written :: proc(o:^Outputs,id:base.Asset_Id,name:string,detail:="") -> Error {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    for output,at in o.w.outputs {
        if output.id!=id {continue}
        if !writer_put(&o.w,at,o.w.paths[at]) {
            error:=writer_error(&o.w,caller)
            o.w.error={}
            return error
        }
        record(&o.w,at,name,detail)
        return {}
    }
    return error_make(.Malformed,"%s: no part of the import is the asset %v: write the outputs output_root and output_part give",o.source,id,allocator=caller)
}

output_warn :: proc(o:^Outputs,format:string,args:..any) {
    append(&o.report.warnings,fmt.aprintf(format,..args,allocator=o.report.allocator))
}

output_catalog_path :: proc(o:^Outputs,path:string) -> Error {
    if !asset.folder_valid(path) {
        return error_make(.Malformed,"the library folder %q must be relative and use forward slashes",path)
    }
    o.w.catalog_path=strings.clone(path,o.w.keep)
    return {}
}

output_program :: proc(o:^Outputs,source:string) -> (address:store.Hash,error:Error) {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    if len(source)==0 || o.w.options.store==nil {
        return {},error_make(.Malformed,"a generated program needs source and a store",
            allocator=caller)
    }
    hash,put_error:=asset.record_put(o.w.options.store,transmute([]u8)source)
    if put_error!=.None {
        return {},error_make(.Write,"could not store the generated source (%v)",
            put_error,allocator=caller)
    }
    if hash in o.w.programs {return hash,{}}
    if o.w.programs==nil {o.w.programs=make(map[store.Hash]struct{},o.w.keep)}
    if _,no_room:=map_insert(&o.w.programs,hash,struct{}{});no_room!=nil {
        return {},error_make(.Write,"could not record the generated source in the build",
            allocator=caller)
    }
    append(&o.report.programs,asset.generated_program_id(hash,o.report.allocator))
    return hash,{}
}

// Whether the store has every output of the cache of the package, built from
// what the import is made from now: then the writer takes each, and a model
// read ahead for it needs nothing cooked (model_cook). It fixes what the
// import is made from: every input is given (output_input) before.
outputs_current :: proc(o:^Outputs) -> bool {
    if current,known:=o.current.?;known {return current}
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    o.current=writer_current(&o.w)
    return o.current.?
}

// Ends the outputs: puts the manifest of the package and its build in the
// store, names them, and gives the report, with a warning for each asset the
// package listed that none took. failed removes the documents the outputs
// created, records nothing and gives no report.
outputs_end :: proc(o:^Outputs,failed:bool,allocator:=context.allocator) -> (report:Import_Report,error:Error) {
    caller:=allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    if failed || !writer_finish(&o.w,filepath.stem(o.source),o.importer if o.importer!="" else "whole") {
        if !failed {error=writer_error(&o.w,caller)}
        writer_rollback(&o.w)
        report_destroy(&o.report)
    } else {
        report=o.report
    }
    writer_close(&o.w)
    delete(o.w.error.message,o.w.allocator)
    mem.dynamic_arena_destroy(&o.scratch)
    o^={}
    return
}
