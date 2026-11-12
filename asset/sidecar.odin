package asset

import "base:runtime"
import "core:fmt"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// <source>.import, the sidecar of a source of a project or a plugin, beside
// it in its assets folder: the settings its import applies (read by
// cook/import with the schema of its Import_Settings), the folder of the
// source's folder its outputs go to, the files the import reads besides the
// source and one output per asset the source gives, with its id. What nobody
// edits (import_cached) is no file of the assets but of the imported folder
// that goes with them, <id>-<key><extension>, never versioned: the registry
// lists it at <folder of the sidecar>/<folder>/<name><extension>, so a source
// that moves with its sidecar takes it along, and one that is gone takes it
// out of the listing.

SIDECAR_EXTENSION :: ".import"
SIDECAR_VERSION :: 3

// One asset an import gives, by what it is in the source.
Import_Output :: struct {
    kind:Fourcc,
    name:string, // in the source: the mesh, the material, the image
    index:int,   // among those of its kind in the source
    id:base.Asset_Id,
    part:bool,   // of the cache: it is a part of the root of the import, decided when it was first imported
}

Sidecar :: struct {
    settings:string, // the text of the settings object, "" without one
    folder:string,   // under the folder of the source, where its outputs go; "": beside it
    inputs:[dynamic]string, // the files the import read besides the source, from the folder of the source
    outputs:[dynamic]Import_Output,
}

// Whether what an import builds of a kind is of the cache: nothing edits it
// after the import, so the source and its sidecar give it back whole.
import_cached :: proc "contextless" (kind:Fourcc) -> bool {
    return kind==KIND_MESH || kind==KIND_TEXTURE || kind==KIND_SOUND || kind==KIND_FONT
}

// The file of an imported asset: in folder, by its id and what it was built from.
imported_file :: proc(folder:string,id:base.Asset_Id,key:u64,extension:string,allocator:=context.allocator) -> string {
    buffer:[base.ASSET_ID_TEXT]u8
    digits:[16]u8
    file,error:=strings.concatenate({folder,"/",base.asset_id_format(id,buffer[:]),"-",fmt.bprintf(digits[:],"%016x",key),extension},allocator)
    if error!=nil {return ""}
    return file
}

// The id and the key a file name of an imported folder says.
imported_name :: proc(name:string) -> (id:base.Asset_Id,key:u64,ok:bool) {
    if len(name)<49 || name[32]!='-' {return}
    id=serial.text_parse_asset_id(name[:32]) or_return
    key=serial.text_parse_hex(name[33:49]) or_return
    return id,key,true
}

// The text of a sidecar whose settings are already the text of their object.
sidecar_text :: proc(settings:string,sidecar:Sidecar,allocator:=context.allocator) -> string {
    w:serial.Writer
    serial.writer_init(&w,1024,allocator)
    serial.text_write_raw(&w,"{\n  \"version\": ")
    serial.text_write_int(&w,SIDECAR_VERSION)
    serial.text_write_raw(&w,",\n  \"settings\": ")
    serial.text_write_raw(&w,settings)
    if sidecar.folder!="" {
        serial.text_write_raw(&w,",\n  \"folder\": ")
        serial.text_write_string(&w,sidecar.folder)
    }
    if len(sidecar.inputs)>0 {
        serial.text_write_raw(&w,",\n  \"inputs\": [")
        for input,at in sidecar.inputs {
            if at>0 {serial.text_write_raw(&w,", ")}
            serial.text_write_string(&w,input)
        }
        serial.text_write_raw(&w,"]")
    }
    serial.text_write_raw(&w,",\n  \"outputs\": [")
    for output,at in sidecar.outputs {
        buffer:[4]u8
        serial.text_write_raw(&w,at>0?",\n    {\"kind\": ":"\n    {\"kind\": ")
        serial.text_write_string(&w,strings.trim_right(fourcc_text(output.kind,&buffer)," "))
        serial.text_write_raw(&w,", \"name\": ")
        serial.text_write_string(&w,output.name)
        serial.text_write_raw(&w,", \"index\": ")
        serial.text_write_int(&w,i64(output.index))
        serial.text_write_raw(&w,", \"id\": \"")
        serial.text_write_asset_id(&w,output.id)
        serial.text_write_raw(&w,output.part?"\", \"part\": true}":"\"}")
    }
    serial.text_write_raw(&w,len(sidecar.outputs)>0?"\n  ]\n}\n":"]\n}\n")
    return string(serial.writer_take(&w))
}

// False for a text that is not a sidecar of this version: a field or a value
// it does not know, a folder that leaves the folder of the source, an output
// without an id or kind, twice the same id or the same output. What it holds
// lives in allocator, an arena: nothing frees it piece by piece; settings is
// a view of text.
sidecar_parse :: proc(text:string,allocator:=context.allocator) -> (sidecar:Sidecar,ok:bool) {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    sidecar.inputs=make([dynamic]string,allocator)
    sidecar.outputs=make([dynamic]Import_Output,allocator)
    version:=u64(0)
    serial.text_expect(&r,'{') or_return
    for first:=true;!serial.text_accept(&r,'}');first=false {
        if !first {serial.text_expect(&r,',') or_return}
        // The key is a view the next string replaces.
        field:=strings.clone(serial.text_string(&r) or_return,context.temp_allocator)
        serial.text_expect(&r,':') or_return
        switch field {
        case "version":
            negative,magnitude:=serial.text_integer(&r) or_return
            if negative {return}
            version=magnitude
        case "settings":
            serial.text_space(&r)
            start:=r.offset
            if serial.text_peek(&r)!='{' {return}
            serial.text_skip(&r) or_return
            sidecar.settings=text[start:r.offset]
        case "folder":
            no_room:runtime.Allocator_Error
            if sidecar.folder,no_room=strings.clone(serial.text_string(&r) or_return,allocator);no_room!=nil {return}
        case "inputs":
            serial.text_expect(&r,'[') or_return
            for begun:=false;!serial.text_accept(&r,']');begun=true {
                if begun {serial.text_expect(&r,',') or_return}
                input,no_room:=strings.clone(serial.text_string(&r) or_return,allocator)
                if no_room!=nil {return}
                append(&sidecar.inputs,input)
            }
        case "outputs":
            serial.text_expect(&r,'[') or_return
            for begun:=false;!serial.text_accept(&r,']');begun=true {
                if begun {serial.text_expect(&r,',') or_return}
                append(&sidecar.outputs,output_read(&r,allocator) or_return)
            }
        case:
            return
        }
    }
    serial.text_end(&r) or_return
    if version!=SIDECAR_VERSION || !folder_valid(sidecar.folder) {return}
    for output,at in sidecar.outputs {
        if output.id=={} || output.kind==0 || output.part && !import_cached(output.kind) {return}
        for other in sidecar.outputs[:at] {
            if other.id==output.id || other.kind==output.kind && other.index==output.index && other.name==output.name {return}
        }
    }
    return sidecar,true
}

@(private="file")
output_read :: proc(r:^serial.Text_Reader,allocator:=context.allocator) -> (output:Import_Output,ok:bool) {
    serial.text_expect(r,'{') or_return
    for first:=true;!serial.text_accept(r,'}');first=false {
        if !first {serial.text_expect(r,',') or_return}
        field:=strings.clone(serial.text_string(r) or_return,context.temp_allocator)
        serial.text_expect(r,':') or_return
        switch field {
        case "kind":
            text:=serial.text_string(r) or_return
            if len(text)==0 || len(text)>4 {return}
            bytes:=[4]u8{' ',' ',' ',' '}
            copy(bytes[:],text)
            output.kind=Fourcc(u32(bytes[0])|u32(bytes[1])<<8|u32(bytes[2])<<16|u32(bytes[3])<<24)
        case "name":
            no_room:runtime.Allocator_Error
            if output.name,no_room=strings.clone(serial.text_string(r) or_return,allocator);no_room!=nil {return}
        case "index":
            negative,magnitude:=serial.text_integer(r) or_return
            if negative || magnitude>u64(max(i32)) {return}
            output.index=int(magnitude)
        case "id":
            output.id=serial.text_parse_asset_id(serial.text_string(r) or_return) or_return
        case "part":
            output.part=serial.text_keyword(r,"true")
            if !output.part && !serial.text_keyword(r,"false") {return}
        case:
            return
        }
    }
    return output,true
}

// A folder under the folder of a source: relative, with forward slashes,
// and never out of it.
@(private="file")
folder_valid :: proc(folder:string) -> bool {
    if folder=="" {return true}
    if folder[0]=='/' || strings.contains_any(folder,"\\:") {return false}
    rest:=folder
    for part in strings.split_iterator(&rest,"/") {
        if part=="" || part=="." || part==".." {return false}
    }
    return true
}

// The paths the registry lists the cache outputs of a sidecar at, under
// listed (the path of the sidecar's folder in the registry, "" or ending
// with '/'): <folder>/<name><extension> with the name as safe_path gives it,
// and " (<index>)" before the extension for an output whose kind and name one
// of a lower index has. "" for an output that is not of the cache. In the
// temp allocator.
sidecar_paths :: proc(sidecar:Sidecar,listed:string) -> []string {
    paths:=make([]string,len(sidecar.outputs),context.temp_allocator)
    folder:=sidecar.folder!=""?fmt.tprintf("%s%s/",listed,sidecar.folder):listed
    for output,at in sidecar.outputs {
        info,known:=kind_info(output.kind)
        if !known || !import_cached(output.kind) {continue}
        name:=safe_path(output.name)
        repeated:=false
        for other in sidecar.outputs {repeated||=other.kind==output.kind && other.name==output.name && other.index<output.index}
        paths[at]=fmt.tprintf("%s%s (%d)%s",folder,name,output.index,info.extension) if repeated else fmt.tprintf("%s%s%s",folder,name,info.extension)
    }
    return paths
}

// A name a file can have: what no file system takes becomes _, and the
// spaces and dots of its ends go. "unnamed" when nothing is left. In the
// temp allocator.
safe_name :: proc(name:string) -> string {
    cleaned:=name_clean(name)
    return cleaned if cleaned!="" else "unnamed"
}

// Where under the folder of an import the output named name goes: each part
// between '/' as safe_name makes it, without the parts that are empty, "."
// or "..". "unnamed" when no part is left. In the temp allocator.
safe_path :: proc(name:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    rest:=name
    for part in strings.split_iterator(&rest,"/") {
        cleaned:=name_clean(part)
        if cleaned=="" {continue}
        if strings.builder_len(b)>0 {strings.write_byte(&b,'/')}
        strings.write_string(&b,cleaned)
    }
    return strings.to_string(b) if strings.builder_len(b)>0 else "unnamed"
}

@(private="file")
name_clean :: proc(name:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for r in name {
        switch {
        case r<32 || r==127,r=='<',r=='>',r==':',r=='"',r=='/',r=='\\',r=='|',r=='?',r=='*',r=='#':
            strings.write_byte(&b,'_')
        case:
            strings.write_rune(&b,r)
        }
    }
    return strings.trim(strings.to_string(b)," .")
}
