package save

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The profile of the player: the @(storage,persist) of every library, beside
// the folder of the slots and apart from them. It belongs to whoever plays on
// this machine, not to a save game: the world reads it the first time it runs
// and writes it by itself when it changes. A storage stored with another
// layout migrates by the names of its fields; one the file lacks keeps its value.
//
// The options of the player (the settings of the machine: graphics, the
// volumes of the buses, the language and scale of the interfaces, the
// bindings it changed) are kept the same way, in its settings.mirai. Each
// file is written a while after it changes (project.Rest), and when the world
// goes. A game asks for nothing and documents are not concerned.

PROFILE :: "profile.save"

@(private) KIND_PROFILE :: asset.Fourcc(u32('P')|u32('R')<<8|u32('O')<<16|u32('F')<<24)
@(private) PROFILE_ID :: base.Asset_Id{0x656c69666f727069,1}

// Whether this world read the profile.
@(storage,keep)
Profile_State :: struct {read:bool}

// The files of the player that the library keeps by itself.
@(private)
Kept_File :: enum u8 {Profile,Options}

// The hash of the bytes a file of the player holds. A field that is not saved
// does not count.
@(private)
kept_hashes :: proc(w:core.World_Ref,app:^host.App) -> (hashes:[Kept_File]u64) {
    ws:=w.info.schema if w.info.schema!=nil else core.world_schema_make(w.info,context.temp_allocator)
    for storage,i in w.info.storages {
        if storage.persist && storage.place==w.place && ws!=nil {
            at:=([^]u8)(uintptr(w.data)+storage.offset)
            for run in ws.storages[i].layout.runs {hashes[.Profile]=base.hash64(at[run.offset:][:run.size],hashes[.Profile])}
        }
        if storage.setting!=.Machine || storage.by_world || app.options=="" {continue}
        place:=storage.place==.Shared?app.shared:storage.place==.World?w.data:nil
        if place!=nil {hashes[.Options]=base.hash64(mem.byte_slice(rawptr(uintptr(place)+storage.offset),storage.info.size),hashes[.Options])}
    }
    return
}

@(private)
kept_write :: proc(file:Kept_File,w:core.World_Ref,app:^host.App,state:^Save_State,problems:^core.Problems) {
    error:Error
    switch file {
    case .Profile: error=profile_write(w,app,state,problems)
    case .Options: error=options_write(w,app)
    }
    if error==.None || error==.Unavailable {return}
    core.report(problems,core.NONE,"save.kept","the %v of the player was not written: %s; it is written again when it changes, or check the permissions of its folder",file,error_text(error))
}

// Looks at the files of the player and writes the ones that rest after changing.
@(private)
kept_watch :: proc(work:^Save_Work,w:core.World_Ref,app:^host.App,state:^Save_State,dt:f32,problems:^core.Problems) {
    if !work.watching {
        work.watching=true
        hashes:=kept_hashes(w,app)
        for &kept,file in work.kept {project.rest_init(&kept,hashes[file])}
        return
    }
    looked:=false
    for &kept in work.kept {looked=project.rest_look(&kept,dt)}
    if !looked {return}
    hashes:=kept_hashes(w,app)
    for &kept,file in work.kept {
        if project.rest_due(&kept,hashes[file]) {kept_write(file,w,app,state,problems)}
    }
}

// What has not been written yet, when the world goes.
@(private)
kept_flush :: proc(work:^Save_Work,w:core.World_Ref,app:^host.App,state:^Save_State,problems:^core.Problems) {
    if !work.watching {return}
    hashes:=kept_hashes(w,app)
    for &kept,file in work.kept {
        if project.rest_flush(&kept,hashes[file]) {kept_write(file,w,app,state,problems)}
    }
}

// The options of the player to their file; Unavailable without them (the editor).
options_write :: proc(w:core.World_Ref,app:^host.App) -> Error {
    if app.options=="" {return .Unavailable}
    return host.app_options_save(app,w.data)?.None:.Write_Failed
}

// The path of the profile: in the folder that holds the one of the slots.
profile_path :: proc(state:^Save_State,app:^host.App) -> (path:string,error:Error) {
    dir:=folder(state,app)
    if dir=="" {return "",.Unavailable}
    joined,join_error:=filepath.join({filepath.dir(dir),PROFILE},context.temp_allocator)
    if join_error!=nil {return "",.Failed}
    return joined,.None
}

// The name of a storage in the profile: its library and its type.
@(private)
profile_table :: proc(storage:core.Storage_Info) -> string {
    return fmt.tprintf("%s/%s",storage.library,storage.name)
}

// Why the profile cannot hold a persist storage, with how to fix it; "" when
// it can. The generator refuses such storages: a World_Info made otherwise
// may have them.
@(private)
profile_unkept :: proc(ws:^core.World_Schema,i:int,storage:core.Storage_Info) -> string {
    v:=&ws.storages[i]
    if len(v.entities)>0 {return "holds an Entity, which names nothing in another run: keep the Entity_Id of what it names (core.id_of)"}
    if v.type!=serial.TYPE_NONE {return ""}
    s:serial.Schema
    serial.schema_init(&s,context.temp_allocator)
    defer serial.schema_destroy(&s)
    serial.schema_add_type_info(&s,storage.info)
    return fmt.tprintf("is not plain data (%s): give a list a fixed array ([N]T) and a count, and a text a [N]u8 that base.text_set writes",s.error)
}

// Writes the persist storages of the world to the profile, replacing it. A
// storage the profile cannot hold writes none, and is a problem that names it.
profile_write :: proc(w:core.World_Ref,app:^host.App,state:^Save_State,problems:^core.Problems=nil) -> Error {
    path:=profile_path(state,app) or_return
    ws:=w.info.schema if w.info.schema!=nil else core.world_schema_make(w.info,context.temp_allocator)
    if ws==nil {return .Failed}
    doc:asset.Document
    asset.document_init(&doc,KIND_PROFILE,PROFILE_ID,context.temp_allocator)
    defer asset.document_destroy(&doc)
    for storage,i in w.info.storages {
        if !storage.persist || storage.place!=w.place {continue}
        if why:=profile_unkept(ws,i,storage);why!="" {
            core.report(problems,core.NONE,"save.profile_storage","the profile of the player was not written: its storage %s %s",profile_table(storage),why)
            return .Failed
        }
        v:=&ws.storages[i]
        link:serial.Schema_Import
        asset.document_import_begin(&doc,&link,&ws.schema)
        imported:=asset.document_import(&doc,&link,v.type)
        serial.schema_import_destroy(&link)
        if imported==serial.TYPE_NONE {return .Failed}
        table,table_error:=asset.document_table_add(&doc,profile_table(storage),{.Single})
        if table_error!=.None {return .Failed}
        if _,column_error:=asset.document_column_add(&doc,table,asset.COLUMN_VALUE,imported,{},.Stream);column_error!=.None {return .Failed}
        serial.value_write(&v.layout,asset.document_cell(&doc,table,0,0),rawptr(uintptr(w.data)+storage.offset),1)
    }
    data,write_error:=asset.document_bytes(&doc,context.temp_allocator)
    if write_error!=.None {return .Failed}
    dir:=filepath.dir(path)
    if os.make_directory_all(dir)!=nil && !os.is_dir(dir) {return .Write_Failed}
    return serial.file_write_atomic(path,data)==.None?.None:.Write_Failed
}

// Reads the profile into the persist storages of the world. Not_Found when
// there is none yet; a profile that does not read leaves them as they were,
// and a storage it cannot hold or whose values do not read is a problem that
// names it.
profile_read :: proc(w:core.World_Ref,app:^host.App,state:^Save_State,problems:^core.Problems=nil) -> Error {
    path:=profile_path(state,app) or_return
    if !os.is_file(path) {return .Not_Found}
    data,read_error:=os.read_entire_file(path,context.temp_allocator)
    if read_error!=nil {return .Not_Found}
    a:asset.Asset
    if asset.asset_open(&a,data,context.temp_allocator)!=.None || a.blob.header.kind!=KIND_PROFILE {return .Corrupt}
    defer asset.asset_close(&a)
    ws:=w.info.schema if w.info.schema!=nil else core.world_schema_make(w.info,context.temp_allocator)
    if ws==nil {return .Failed}
    // Every storage reads into a copy first: a profile that fails halfway changes none.
    Read :: struct {at:rawptr,value:[]u8}
    reads:=make([dynamic]Read,context.temp_allocator)
    for storage,i in w.info.storages {
        if !storage.persist || storage.place!=w.place {continue}
        if why:=profile_unkept(ws,i,storage);why!="" {
            core.report(problems,core.NONE,"save.profile_storage","the profile of the player was not read: its storage %s %s",profile_table(storage),why)
            return .Failed
        }
        table,found:=asset.asset_table(&a,profile_table(storage))
        if !found {continue}
        at:=core.world_storage_at(w,i)
        current:=mem.byte_slice(at,storage.info.size)
        value:=make([]u8,storage.info.size,context.temp_allocator)
        if asset.asset_column_read(&a,table,0,&ws.schema,ws.storages[i].type,value,current)!=.None {
            core.report(problems,core.NONE,"save.profile_storage","the profile of the player was not read: the values of its storage %s do not read; delete %s, or let the game write it again",profile_table(storage),path)
            return .Corrupt
        }
        append(&reads,Read{at,value})
    }
    for r in reads {copy(mem.byte_slice(r.at,len(r.value)),r.value)}
    return .None
}
