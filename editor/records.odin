package editor

import "mirai:editor/records"
import "mirai:host"
import "mirai:std/base"

// What the tables of game data (package editor/records) need of the session:
// the assets and the layout of the project, and the write of the file as an
// edit, a step of the history like any other.

// A table as its file says now, in memory or on disk; message says
// why it cannot be changed when it cannot.
records_edit_load :: proc(s:^Session,id:base.Asset_Id,e:^records.Edit,allocator:=context.allocator) -> (message:string) {
    a:=s.app.assets
    if a==nil {return "The editor has no assets or no project"}
    return records.load(&a.registry,&a.types,s.app.info,id,e,allocator)
}

// Writes the table into its file as an edit, in the open gesture or in a
// step named label; message says why it was not written.
records_edit_publish :: proc(s:^Session,e:^records.Edit,label:string) -> (message:string) {
    a:=s.app.assets
    if a==nil {return "The editor has no assets or no project"}
    bytes,problem:=records.file_bytes(e,&a.types)
    if problem!="" {return problem}
    if !file_write(s,e.file,bytes,label) {return "the table could not be written"}
    return ""
}

// The tables of rows of a type in the assets, by their paths: the one that
// declares it and those that hold rows of it.
records_tables :: proc(s:^Session,type:string,allocator:=context.temp_allocator) -> []host.Record_File {
    return host.app_record_tables(s.app,type,allocator)
}

// The table that declares a type; {} when none does.
records_declaring :: proc(s:^Session,type:string) -> host.Record_File {
    for &file in host.app_record_files(s.app) {
        if file.declares && base.text_get(file.type[:])==type {return file}
    }
    return {}
}

// The record types the assets declare, by name, in the order of their files.
records_type_names :: proc(s:^Session,allocator:=context.temp_allocator) -> []string {
    names:=make([dynamic]string,allocator)
    for &file in host.app_record_files(s.app) {
        if file.declares {append(&names,base.text_get(file.type[:]))}
    }
    return names[:]
}

// The index in World_Info.records of a type the build has; -1 before it does.
records_built :: proc(s:^Session,type:string) -> int {
    if s.app.info==nil {return -1}
    for &r,i in s.app.info.records {
        if r.name==type {return i}
    }
    return -1
}

// A new empty table that declares its type, named from its file, as
// asset.create and Create make it.
records_create_bytes :: proc(s:^Session,id:base.Asset_Id,path,file:string) -> (bytes:[]u8,message:string) {
    a:=s.app.assets
    if a==nil {return nil,"The editor has no assets or no project"}
    e:records.Edit
    if message=records.create(id,file,records.folder_of(path),records.type_of_file(path),&e,context.temp_allocator);message!="" {return}
    defer records.destroy(&e)
    return records.file_bytes(&e,&a.types)
}
