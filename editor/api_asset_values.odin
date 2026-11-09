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
// those of plugins: the asset the params name, the values of its info as
// their text, and the result that names it.

ASSET_PARAMS_EXTRA :: 4

// The params of a method that edits an asset by code: the asset under `key`
// (its path under the assets folder, or its id), the path of a new one, its
// values and the text of the other keys the method takes.
Asset_Params :: struct {
    named,path:string,
    values:string,                    // the text of the object
    extra:[ASSET_PARAMS_EXTRA]string, // the text of each key of extra given; empty: not given
}

asset_params :: proc(call:^api.Call,key:string,extra:[]string={}) -> (p:Asset_Params,ok:bool) {
    r:serial.Text_Reader
    serial.text_reader_init(&r,call.raw,context.temp_allocator)
    failed :: proc(call:^api.Call,r:^serial.Text_Reader) -> bool {
        line,column:=serial.text_position(call.raw,r.error.offset)
        api.call_failf(call,api.INVALID_PARAMS,"%s at line %d, column %d",serial.text_error_message(r,allocator=context.temp_allocator),line,column)
        return false
    }
    if !serial.text_accept(&r,'{') {
        serial.text_fail(&r,.Expected_Object)
        return p,failed(call,&r)
    }
    if serial.text_accept(&r,'}') {return p,true}
    for {
        serial.text_space(&r)
        name,named:=serial.text_string(&r)
        if !named || !serial.text_expect(&r,':') {return p,failed(call,&r)}
        name=strings.clone(name,context.temp_allocator)
        serial.text_space(&r)
        other:=-1
        for each,i in extra[:min(len(extra),ASSET_PARAMS_EXTRA)] {
            if each==name {other=i;break}
        }
        switch {
        case name==key || name=="path":
            text,read:=serial.text_string(&r)
            if !read {return p,failed(call,&r)}
            if name=="path" {p.path=strings.clone(text,context.temp_allocator)} else {p.named=strings.clone(text,context.temp_allocator)}
        case name=="values" || other>=0:
            start:=r.offset
            if !serial.text_skip(&r) {return p,failed(call,&r)}
            if other>=0 {p.extra[other]=call.raw[start:r.offset]} else {p.values=call.raw[start:r.offset]}
        }
        if serial.text_accept(&r,',') {continue}
        if !serial.text_expect(&r,'}') {return p,failed(call,&r)}
        return p,true
    }
}

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

// Opens the result of an asset: its id under `key` and its path.
asset_named_write :: proc(s:^Session,out:^serial.Writer,key:string,id:base.Asset_Id) {
    serial.write_u8(out,'{')
    serial.text_write_string(out,key)
    serial.write_u8(out,':')
    serial.write_u8(out,'"')
    serial.text_write_asset_id(out,id)
    serial.write_u8(out,'"')
    if file,found:=asset.registry_find(&s.app.assets.registry,id);found {
        api.write_key(out,"path")
        serial.text_write_string(out,file.path)
    }
}

// The values of an asset as their text, under `key` of the result.
asset_values_write :: proc(out:^serial.Writer,key:string,info:^$T) {
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add_type_info(&schema,type_info_of(T))
    api.write_key(out,key)
    serial.text_write(out,&schema,type,mem.ptr_to_bytes(info),.Line)
}

// Whether a path is of one of the extensions, separated by spaces; "": any.
@(private="file")
asset_kinds_take :: proc(path,kinds:string) -> bool {
    if kinds=="" {return true}
    rest:=kinds
    for kind in strings.fields_iterator(&rest) {
        if strings.has_suffix(path,kind) {return true}
    }
    return false
}

// A path without the extension of its file.
@(private="file")
asset_path_stem :: proc(path:string) -> string {
    dot:=strings.last_index_byte(path,'.')
    slash:=strings.last_index_byte(path,'/')
    return dot>slash?path[:dot]:path
}

// The paths nearest to a name among the assets of the kinds, as a list.
@(private="file")
asset_nearest :: proc(r:^asset.Registry,name,kinds:string) -> string {
    paths,stems:=make([dynamic]string,context.temp_allocator),make([dynamic]string,context.temp_allocator)
    for &file in r.files {
        if file.state!=.Asset || !asset.registry_listed(&file) || !asset_kinds_take(file.path,kinds) {continue}
        append(&paths,file.path)
        append(&stems,asset_path_stem(file.path))
    }
    nearest:[base.NAME_NEAREST]int
    last:=asset_path_stem(name)
    count:=base.names_nearest(last[strings.last_index_byte(last,'/')+1:],stems[:],nearest[:])
    b:=strings.builder_make(context.temp_allocator)
    for at,i in nearest[:count] {fmt.sbprintf(&b,"%s%s",i>0?", ":"",paths[at])}
    return strings.to_string(b)
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
    r:=&a.registry
    if file,found:=asset.registry_find_path(r,name);found && file.state==.Asset && asset_kinds_take(file.path,kinds) {return file.id,""}
    matches:=make([dynamic]^asset.Registry_File,context.temp_allocator)
    for &file in r.files {
        if file.state==.Asset && asset_path_stem(file.path)==name && asset_kinds_take(file.path,kinds) {append(&matches,&file)}
    }
    if len(matches)==1 {return matches[0].id,""}
    b:=strings.builder_make(context.temp_allocator)
    if len(matches)>1 {
        for each,i in matches {fmt.sbprintf(&b,"%s%s",i>0?", ":"",each.path)}
        return {},fmt.tprintf("%q names several assets: %s; give the path with its extension",name,strings.to_string(b))
    }
    kind:=kinds!=""?fmt.tprintf("%s ",kinds):""
    if nearest:=asset_nearest(r,name,kinds);nearest!="" {
        return {},fmt.tprintf("%q is no %sasset; the nearest paths are %s",name,kind,nearest)
    }
    return {},fmt.tprintf("%q is no %sasset and none is near that name: asset.list lists them and asset.import brings one",name,kind)
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

// The asset a *.set writes: the one the params name under `key`, or a new one
// with a new id at path, whose file must not exist yet.
Asset_Target :: struct {
    id:base.Asset_Id,
    file:string, // its file in the project
    created:bool,
}

asset_target :: proc(s:^Session,call:^api.Call,p:^Asset_Params,key:string,kind:asset.Fourcc,extension,what:string) -> (t:Asset_Target,ok:bool) {
    if (p.named=="")==(p.path=="") {
        api.call_failf(call,api.INVALID_PARAMS,"Give exactly one of %s, %s to change by its path under the assets folder or its id, and path, where a new one goes",key,what)
        return
    }
    a:=s.app.assets
    if p.named!="" {
        t.id=asset_named(s,call,p.named,kind,extension,what) or_return
        record,_:=asset.registry_find(&a.registry,t.id)
        t.file=asset.registry_file_path(&a.registry,record.path,context.temp_allocator)
        return t,true
    }
    if a==nil || !s.has_project {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no project")
        return
    }
    path:=strings.has_suffix(p.path,extension)?p.path:fmt.tprintf("%s%s",p.path,extension)
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
