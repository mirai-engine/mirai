package editor

import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// What the methods that edit an asset by code share, those of the editor and
// those of plugins: the asset the params name and the values of its info as
// their text.

// Puts the values of the params, the text of the values of an asset, over info.
asset_values_read :: proc(call:^api.Call,text:string,info:^$T) -> bool {
    if text=="" {return true}
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add_type_info(&schema,type_info_of(T))
    r:serial.Text_Reader
    api.call_reader_init(call,&r,text)
    if !serial.text_read(&r,&schema,type,mem.ptr_to_bytes(info)) {
        line,column:=serial.text_position(text,r.error.offset)
        api.call_failf(call,api.INVALID_PARAMS,"%s at line %d, column %d",serial.text_error_message(&r,"values",context.temp_allocator),line,column)
        return false
    }
    return true
}

// The asset a text names, in one place for every method: its id, or its path
// under the assets folder, with or without its extension. kinds: the
// extensions it may have, separated by spaces; "": any. problem says what is
// wrong with the name, with the paths nearest to it; "": found.
asset_resolve :: proc(s:^Session,name,kinds:string) -> (id:base.Asset_Id,problem:string) {
    if parsed,is_id:=serial.text_parse_asset_id(name);is_id {return parsed,""}
    a:=s.app.assets
    if a==nil {return {},"The editor has no assets"}
    host.assets_scan(a)
    return asset.registry_resolve(&a.registry,name,kinds)
}

// asset_resolve for a reader of params.
@(private)
asset_text_resolve :: proc(user:rawptr,name,kinds:string) -> (id:base.Asset_Id,problem:string) {
    return asset_resolve((^Session)(user),name,kinds)
}

// The asset of a kind the params name; false after failing the call.
asset_named :: proc(s:^Session,call:^api.Call,name:string,kind:asset.Fourcc,extension,what:string) -> (id:base.Asset_Id,ok:bool) {
    resolved,problem:=asset_resolve(s,name,extension)
    if problem!="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s (%s)",problem,what)
        return
    }
    if file,found:=asset.registry_find(&s.app.assets.registry,resolved);found && file.kind==kind {return resolved,true}
    api.call_failf(call,api.INVALID_PARAMS,"%q is not %s of the assets",name,what)
    return
}

// The asset a *.set writes: the one the params name under `key`, named, or a
// new one with a new id at path, whose file must not exist yet.
Asset_Target :: struct {
    id:base.Asset_Id,
    file:string, // its file in the project
    created:bool,
}

asset_target :: proc(s:^Session,call:^api.Call,named,path:string,key:string,kind:asset.Fourcc,extension,what:string) -> (t:Asset_Target,ok:bool) {
    if (named=="")==(path=="") {
        api.call_failf(call,api.INVALID_PARAMS,"Give exactly one of %s, %s to change by its path under the assets folder or its id, and path, where a new one goes",key,what)
        return
    }
    a:=s.app.assets
    if named!="" {
        t.id=asset_named(s,call,named,kind,extension,what) or_return
        record,_:=asset.registry_find(&a.registry,t.id)
        t.file=asset.registry_file_path(&a.registry,record.path,context.temp_allocator)
        return t,true
    }
    if a==nil || !s.has_project {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no project")
        return
    }
    path:=strings.has_suffix(path,extension)?path:fmt.tprintf("%s%s",path,extension)
    if t.file=scene_file(s,path);t.file=="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s: %s",path,document_error_text(.Bad_Path))
        return
    }
    if file_exists(s,t.file) {
        api.call_failf(call,api.INVALID_PARAMS,"%s already exists: give it as %s to change it",path,key)
        return
    }
    t.id,t.created=asset_id_new(s),true
    return t,true
}

// Why an asset could not be read, with its path and what the registry says.
api_asset_read_problem :: proc(s:^Session,id:base.Asset_Id,kind:string) -> string {
    buffer:[base.ASSET_ID_TEXT]u8
    r:=files_registry(s)
    if r==nil {return fmt.tprintf("The %s %s could not be read: the editor has no assets",kind,base.asset_id_format(id,buffer[:]))}
    file,found:=asset.registry_find(r,id)
    if !found {return fmt.tprintf("No %s has the id %s; asset.list lists them",kind,base.asset_id_format(id,buffer[:]))}
    if busy:=import_busy(s);busy!="" {return fmt.tprintf("%s could not be read: %s",file.path,busy)}
    if _,error:=asset.registry_read(r,file.path,context.temp_allocator);error!=.None {return fmt.tprintf("%s could not be read: %v",file.path,error)}
    return fmt.tprintf("%s is not a valid %s: its contents are damaged or of another version",file.path,kind)
}

// Why an asset file could not be written, with what can be known of the cause.
api_asset_write_problem :: proc(s:^Session,path:string) -> string {
    if busy:=import_busy(s);busy!="" {return fmt.tprintf("%s could not be written: %s",path,busy)}
    return fmt.tprintf("%s could not be written: the file or its folder is read-only, or the disk is full",path)
}
