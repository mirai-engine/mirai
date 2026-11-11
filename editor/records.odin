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
    if a==nil || s.app.info==nil {return "The editor has no assets or no project"}
    return records.load(&a.registry,&a.types,s.app.info,id,e,allocator)
}

// Writes the table into its file as an edit, in the open gesture or in a
// step named label; message says why it was not written.
records_edit_publish :: proc(s:^Session,e:^records.Edit,label:string) -> (message:string) {
    a:=s.app.assets
    if a==nil || s.app.info.schema==nil {return "The editor has no assets or no project"}
    bytes,problem:=records.file_bytes(e,&a.types,s.app.info)
    if problem!="" {return problem}
    if !file_write(s,e.file,bytes,label) {return "the table could not be written"}
    return ""
}

// The tables of the type at index in the assets, by their paths.
records_tables :: proc(s:^Session,index:int,allocator:=context.temp_allocator) -> []host.Record_File {
    return host.app_record_tables(s.app,index,allocator)
}
