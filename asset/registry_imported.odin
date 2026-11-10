package asset

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:std/base"
import "mirai:std/serial"

// What the imports of the sources of a project build that nobody edits
// (meshes, textures, sounds, fonts) is not in its assets folder: each is a
// file of the imported folder that goes with it, <id>-<key><extension>, never
// versioned, where key says what it was built from. The registry lists it as
// any other asset (Registry_File.imported is that key), at a path it derives
// from where the sidecar that lists it is now: the folder of the source under
// the source folder and, for what is not the root of its import, a folder
// named after the source file. Nothing stores that path: a source that moves
// with its sidecar takes its outputs with it at the next scan, without an
// import, and one that is gone is not listed.

// One asset an import gives, by what it is in the source: what a sidecar lists.
Import_Output :: struct {
    kind:Fourcc,
    name:string, // in the source: the mesh, the material, the image
    index:int,   // among those of its kind in the source
    id:base.Asset_Id,
    part:bool,   // of one of the imported folder: it is a part of the root of the import, decided when it was first imported
    shared:bool, // another import writes it: this one only names it
}

SIDECAR_EXTENSION :: ".import"
// Where the sources of the root of an imported folder are: beside its generated folder.
@(private="file") SOURCES :: "source"

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

import_outputs_write :: proc(w:^serial.Writer,outputs:[]Import_Output) {
    serial.text_write_raw(w,"[")
    for output,at in outputs {
        buffer:[4]u8
        serial.text_write_raw(w,at>0?",\n    {\"kind\": ":"\n    {\"kind\": ")
        serial.text_write_string(w,strings.trim_right(fourcc_text(output.kind,&buffer)," "))
        serial.text_write_raw(w,", \"name\": ")
        serial.text_write_string(w,output.name)
        serial.text_write_raw(w,", \"index\": ")
        serial.text_write_int(w,i64(output.index))
        serial.text_write_raw(w,", \"id\": \"")
        serial.text_write_asset_id(w,output.id)
        serial.text_write_raw(w,output.part?"\", \"part\": true":"\"")
        serial.text_write_raw(w,output.shared?", \"shared\": true}":"}")
    }
    serial.text_write_raw(w,len(outputs)>0?"\n  ]":"]")
}

// The outputs a sidecar lists after "outputs":, in allocator (an arena: nothing frees them one by one).
import_outputs_read :: proc(r:^serial.Text_Reader,outputs:^[dynamic]Import_Output,allocator:=context.allocator) -> bool {
    serial.text_expect(r,'[') or_return
    for begun:=false;!serial.text_accept(r,']');begun=true {
        if begun {serial.text_expect(r,',') or_return}
        output:Import_Output
        serial.text_expect(r,'{') or_return
        for first:=true;!serial.text_accept(r,'}');first=false {
            if !first {serial.text_expect(r,',') or_return}
            field:=strings.clone(serial.text_string(r) or_return,context.temp_allocator)
            serial.text_expect(r,':') or_return
            switch field {
            case "kind":
                text:=serial.text_string(r) or_return
                if len(text)==0 || len(text)>4 {return false}
                bytes:=[4]u8{' ',' ',' ',' '}
                copy(bytes[:],text)
                output.kind=Fourcc(u32(bytes[0])|u32(bytes[1])<<8|u32(bytes[2])<<16|u32(bytes[3])<<24)
            case "name":
                name,no_name:=strings.clone(serial.text_string(r) or_return,allocator)
                if no_name!=nil {return false}
                output.name=name
            case "index":
                negative,magnitude:=serial.text_integer(r) or_return
                if negative || magnitude>u64(max(i32)) {return false}
                output.index=int(magnitude)
            case "id":
                output.id=serial.text_parse_asset_id(serial.text_string(r) or_return) or_return
            case "part","shared":
                value:=serial.text_keyword(r,"true")
                if !value && !serial.text_keyword(r,"false") {return false}
                if field=="part" {output.part=value} else {output.shared=value}
            case:
                return false
            }
        }
        if output.id=={} || output.kind==0 {return false}
        append(outputs,output)
    }
    return true
}

// Appends the assets of the imported folders of the root and of the mounts:
// what the sidecars of their sources list that the folder holds.
@(private)
registry_imported_list :: proc(r:^Registry,known:map[string]u32,previous:[]Registry_File,previous_dependencies:[]base.Asset_Id) -> Error {
    taken:=make(map[string]struct{},context.temp_allocator)
    for file in r.files {taken[file.path]={}}
    for folder in r.folders {taken[folder]={}}
    list :: proc(r:^Registry,imported,prefix:string,taken:^map[string]struct{},known:map[string]u32,previous:[]Registry_File,previous_dependencies:[]base.Asset_Id) -> Error {
        held,error:=os.read_all_directory_by_path(imported,context.temp_allocator)
        if imported=="" || error!=nil {return .None}
        Kept :: struct {key:u64,size,time:i64}
        keys:=make(map[base.Asset_Id]Kept,context.temp_allocator)
        for info in held {
            if id,key,named:=imported_name(info.name);named && info.type==.Regular {keys[id]={key,info.size,time.time_to_unix_nano(info.modification_time)}}
        }
        // The project or the plugin: the imported folder is in its generated folder.
        sources:=fmt.tprintf("%s/%s",imported[:max(strings.last_index_byte(imported[:max(strings.last_index_byte(imported,'/'),0)],'/'),0)],SOURCES)
        todo:=make([dynamic]string,context.temp_allocator)
        append(&todo,"")
        for next:=0;next<len(todo);next+=1 {
            entries,_:=os.read_all_directory_by_path(fmt.tprintf("%s/%s",sources,todo[next]),context.temp_allocator)
            for entry in entries {
                if entry.type==.Directory && !strings.has_prefix(entry.name,".") {append(&todo,fmt.tprintf("%s%s/",todo[next],entry.name))}
                file:=strings.trim_suffix(entry.name,SIDECAR_EXTENSION)
                if entry.type!=.Regular || file==entry.name || !os.exists(fmt.tprintf("%s/%s%s",sources,todo[next],file)) {continue}
                text,read_error:=serial.file_read(entry.fullpath,context.temp_allocator)
                if read_error!=.None {continue}
                outputs:=make([dynamic]Import_Output,context.temp_allocator)
                t:serial.Text_Reader
                serial.text_reader_init(&t,string(text),context.temp_allocator)
                // The outputs of the sidecar: what else it says is the import's.
                listed:=serial.text_expect(&t,'{')
                for first:=true;listed && !serial.text_accept(&t,'}');first=false {
                    if !first {listed=serial.text_expect(&t,',')}
                    key,named:=serial.text_string(&t)
                    outputs_next:=key=="outputs"
                    listed=listed && named && serial.text_expect(&t,':') && (import_outputs_read(&t,&outputs,context.temp_allocator) if outputs_next else serial.text_skip(&t))
                }
                serial.text_reader_destroy(&t)
                for output,at in outputs {
                    kept,built:=keys[output.id]
                    kind,known_kind:=kind_info(output.kind)
                    if !listed || !built || !known_kind || output.shared {continue}
                    // The root of an import is listed beside its source; its other outputs, in a folder of the name of the source.
                    folder:=at==0?todo[next]:fmt.tprintf("%s%s/",todo[next],file)
                    if prefix!="" {folder=fmt.tprintf("%s/%s",prefix,folder)}
                    name,_:=strings.replace_all(output.name,"/","_",context.temp_allocator)
                    path:=fmt.tprintf("%s%s%s",folder,name,kind.extension)
                    for n:=2;(path in taken);n+=1 {path=fmt.tprintf("%s%s (%d)%s",folder,name,n,kind.extension)}
                    taken[path]={}
                    // The folders it is in are folders of the listing, also without a file of the assets.
                    for at:=strings.index_byte(folder,'/');at>=0;at=strings.index_byte(folder[at+1:],'/')<0?-1:at+1+strings.index_byte(folder[at+1:],'/') {
                        if folder[:at+1] in taken {continue}
                        kept_folder,no_folder:=strings.clone(folder[:at+1],r.allocator)
                        if no_folder!=nil {return .Out_Of_Memory}
                        append(&r.folders,kept_folder)
                        taken[kept_folder]={}
                    }
                    registered:=Registry_File{size=kept.size,time=kept.time,imported=kept.key}
                    r.stats.files+=1
                    registry_walk_reuse(r,&registered,imported_file(imported,output.id,kept.key,kind.extension,context.temp_allocator),path,known,previous,previous_dependencies) or_return
                    if registered.state==.Asset {registry_file_add(r,registered,path) or_return}
                }
            }
        }
        return .None
    }
    list(r,r.imported,"",&taken,known,previous,previous_dependencies) or_return
    for mount in r.mounts {list(r,mount.imported,mount.prefix,&taken,known,previous,previous_dependencies) or_return}
    return .None
}

// The file of the imported asset the registry lists at path, built from key.
@(private)
registry_imported_file :: proc(r:^Registry,path:string,id:base.Asset_Id,key:u64,allocator:=context.allocator) -> string {
    folder:=r.imported
    for mount in r.mounts {
        if registry_under(path,mount.prefix) {folder=mount.imported;break}
    }
    return imported_file(folder,id,key,path[strings.last_index_byte(path,'.'):],allocator)
}
