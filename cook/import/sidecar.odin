package importer

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// <source>.import, the sidecar: what is versioned of an import with its
// source. It says how the source becomes assets (settings) and which asset
// each thing of the source is (outputs): nothing else decides an id. Of a
// source in the source folder of a root, the meshes, textures, sounds and
// fonts (kind_cached), which nobody edits, are files of the imported folder
// of the root named by their ids, never versioned: the registry lists them
// by where the source is, and sources.sync builds them again. The other kinds
// are documents of the assets folder, found by their id. Any other import (a
// source elsewhere, a format of a plugin, no root) keeps every output as a
// document of the folder it writes to.

SIDECAR_EXTENSION :: asset.SIDECAR_EXTENSION
SIDECAR_VERSION :: 2

Output :: asset.Import_Output

Sidecar :: struct {
    settings:Import_Settings,
    documents:bool, // every output is a document of the assets: sources.sync does not import the source
    inputs:[dynamic]string, // the files the import read besides the source, from the folder of the source: with it, what the outputs are built from
    outputs:[dynamic]Output,
}

// Whether what an import builds of a kind is of the cache: nothing edits it
// after the import, so the source and its sidecar give it back whole.
kind_cached :: proc "contextless" (kind:asset.Fourcc) -> bool {
    return kind==asset.KIND_MESH || kind==asset.KIND_TEXTURE || kind==asset.KIND_SOUND || kind==asset.KIND_FONT
}

// The sidecar of a source imported for root: next to it, or for a source
// outside root, in the source folder of root under the name of the file.
// Without a root: in the folder the import writes to, under that name.
sidecar_path :: proc(source:string,root:="",folder:="",allocator:=context.allocator) -> string {
    switch {
    case root=="" && folder!="":
        return strings.concatenate({strings.trim_right(folder,"/\\"),"/",filepath.base(source),SIDECAR_EXTENSION},allocator)
    case root!="" && filepath.is_abs(source_path({root=root},source)):
        return strings.concatenate({project.folder_path(root,.Source,context.temp_allocator),"/",filepath.base(source),SIDECAR_EXTENSION},allocator)
    }
    return strings.concatenate({source,SIDECAR_EXTENSION},allocator)
}

@(private="file")
settings_valid :: proc(settings:Import_Settings) -> bool {
    return settings.max_texture_size>=0 && settings.max_triangles>=0 && settings.collision_hulls>=0 && settings.textures<=max(textures.Encoding) && settings.rdo_lambda<=textures.RDO_LAMBDA_MAX &&
        settings.image<=max(Image_Use) && settings.alpha_coverage>=0 && settings.alpha_coverage<=1 && settings.lods<=max(Lods) && settings.collision<=max(Collision) && settings.parts<=max(Parts) && settings.front<=max(Front) && settings.rig<=max(Rig) &&
        settings.rig_crotch>=0 && settings.rig_neck>=0 && (settings.rig==.Humanoid || settings.rig_crotch==0 && settings.rig_neck==0)
}

// The settings are written only where they differ from their defaults (the
// zero value), so a sidecar shows what was chosen; reading fills the rest.
sidecar_text :: proc(sidecar:Sidecar,allocator:=context.allocator) -> string {
    settings,defaults:=sidecar.settings,Import_Settings{}
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add(&schema,Import_Settings)
    w:serial.Writer
    serial.writer_init(&w,1024,allocator)
    serial.text_write_raw(&w,"{\n  \"version\": ")
    serial.text_write_int(&w,SIDECAR_VERSION)
    serial.text_write_raw(&w,",\n  \"settings\": ")
    serial.text_write_changed(&w,&schema,type,([^]u8)(&settings)[:size_of(Import_Settings)],([^]u8)(&defaults)[:size_of(Import_Settings)],.Pretty,depth=1)
    if sidecar.documents {serial.text_write_raw(&w,",\n  \"documents\": true")}
    if len(sidecar.inputs)>0 {
        serial.text_write_raw(&w,",\n  \"inputs\": [")
        for input,at in sidecar.inputs {
            if at>0 {serial.text_write_raw(&w,", ")}
            serial.text_write_string(&w,input)
        }
        serial.text_write_raw(&w,"]")
    }
    serial.text_write_raw(&w,",\n  \"outputs\": ")
    asset.import_outputs_write(&w,sidecar.outputs[:])
    serial.text_write_raw(&w,"\n}\n")
    return string(serial.writer_take(&w))
}

// False for a text that is not the sidecar of a source: another version, a
// field or a value this build does not know, an output without an id or twice
// the same one. What it holds lives in allocator, an arena: nothing frees it
// piece by piece.
sidecar_parse :: proc(text:string,allocator:=context.allocator) -> (sidecar:Sidecar,ok:bool) {
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add(&schema,Import_Settings)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    sidecar.outputs=make([dynamic]Output,allocator)
    version:=0
    serial.text_expect(&r,'{') or_return
    for first:=true;!serial.text_accept(&r,'}');first=false {
        if !first {serial.text_expect(&r,',') or_return}
        key:=serial.text_string(&r) or_return
        // The key is a view the next string replaces.
        field:=strings.clone(key,context.temp_allocator)
        serial.text_expect(&r,':') or_return
        switch field {
        case "version":
            negative,magnitude:=serial.text_integer(&r) or_return
            if negative || magnitude!=SIDECAR_VERSION {return}
            version=int(magnitude)
        case "settings":
            serial.text_read(&r,&schema,type,([^]u8)(&sidecar.settings)[:size_of(Import_Settings)]) or_return
        case "documents":
            sidecar.documents=serial.text_keyword(&r,"true")
            if !sidecar.documents && !serial.text_keyword(&r,"false") {return}
        case "inputs":
            sidecar.inputs=make([dynamic]string,allocator)
            serial.text_expect(&r,'[') or_return
            for begun:=false;!serial.text_accept(&r,']');begun=true {
                if begun {serial.text_expect(&r,',') or_return}
                append(&sidecar.inputs,strings.clone(serial.text_string(&r) or_return,allocator))
            }
        case "outputs":
            asset.import_outputs_read(&r,&sidecar.outputs,allocator) or_return
        case:
            return
        }
    }
    serial.text_end(&r) or_return
    if version!=SIDECAR_VERSION || !settings_valid(sidecar.settings) {return}
    for output,at in sidecar.outputs {
        if output.id=={} || output.kind==0 || output.index<0 || output.part && (!kind_cached(output.kind) || output.shared) {return}
        for other in sidecar.outputs[:at] {
            if other.id==output.id || other.kind==output.kind && other.index==output.index && other.name==output.name {return}
        }
    }
    return sidecar,true
}

// What the outputs of an import are built from, as one number: the bytes of
// the source at path and of each input its sidecar lists, its settings, the
// version of what reads and writes it and whether its textures are built
// Fast. An output of the cache is current when its file is named by this key.
// With hashes, a file whose size and modification time it knows is not read.
import_key :: proc(path:string,sidecar:Sidecar,version:u32,fast:bool,hashes:^Source_Hashes=nil) -> u64 {
    key:=base.hash_combine(u64(version)<<1|u64(fast),u64(asset.MESH_VERSION)<<32|u64(asset.TEXTURE_VERSION)<<16|u64(textures.BUILD_VERSION))
    key=base.hash_combine(key,base.hash64(transmute([]u8)sidecar_text({settings=sidecar.settings},context.temp_allocator)))
    folder:=filepath.dir(path)
    for at in -1..<len(sidecar.inputs) {
        key=base.hash_combine(key,file_hash(hashes,path if at<0 else fmt.tprintf("%s/%s",folder,sidecar.inputs[at])))
    }
    return key|1
}

// The hashes of the files the imports of a root read, by path, as they were
// when read: kept in the cache of the root (SOURCE_HASHES), so a build reads
// only the files whose size or modification time changed. The bytes still
// decide: a file that changed is read again.
Source_Hashes :: struct {
    files:map[string]Source_Hash,
    changed:bool,
}
Source_Hash :: struct {size,modified:i64,hash:u64}

SOURCE_HASHES :: "sources"
// A file modified this close to when it was hashed may change again within the
// same modification time: it is hashed again on the next build.
@(private="file") SETTLED_NANOSECONDS :: 2_000_000_000

// The hashes of the root kept in path, in allocator; none when it is missing or does not read.
source_hashes_load :: proc(path:string,allocator:=context.allocator) -> (hashes:Source_Hashes) {
    hashes.files=make(map[string]Source_Hash,allocator=allocator)
    data,error:=serial.file_read(path,context.temp_allocator)
    if error!=.None {return}
    text:=string(data)
    for line in strings.split_lines_iterator(&text) {
        parts:=strings.split_n(line," ",4,context.temp_allocator)
        if len(parts)!=4 {continue}
        hash,hash_ok:=strconv.parse_u64(parts[0],16)
        size,size_ok:=strconv.parse_i64(parts[1])
        modified,modified_ok:=strconv.parse_i64(parts[2])
        if hash_ok && size_ok && modified_ok {hashes.files[strings.clone(parts[3],allocator)]={size,modified,hash}}
    }
    return
}

// Writes the hashes to path when a build changed them.
source_hashes_save :: proc(hashes:^Source_Hashes,path:string) {
    if !hashes.changed {return}
    b:=strings.builder_make(context.temp_allocator)
    for file,known in hashes.files {fmt.sbprintf(&b,"%016x %d %d %s\n",known.hash,known.size,known.modified,file)}
    if folder:=filepath.dir(path);!os.is_dir(folder) {_=os.make_directory_all(folder)}
    _=serial.file_write_atomic(path,transmute([]u8)strings.to_string(b))
}

// The hash of the bytes of a file, from hashes when its size and modification
// time are those it knows; 0 for a file that cannot be read.
@(private="file")
file_hash :: proc(hashes:^Source_Hashes,file:string) -> u64 {
    info,stat_error:=os.stat(file,context.temp_allocator)
    size,modified:=info.size,time.time_to_unix_nano(info.modification_time)
    if hashes!=nil && stat_error==nil {
        if known,found:=hashes.files[file];found && known.size==size && known.modified==modified {return known.hash}
    }
    bytes,_:=serial.file_read(file,context.temp_allocator,limit=MAX_SOURCE_BYTES)
    hash:=base.hash64(bytes)
    delete(bytes,context.temp_allocator)
    if hashes!=nil && stat_error==nil && time.time_to_unix_nano(time.now())-modified>SETTLED_NANOSECONDS {
        allocator:=hashes.files.allocator
        if _,found:=hashes.files[file];!found {hashes.files[strings.clone(file,allocator)]={}}
        hashes.files[file]={size,modified,hash}
        hashes.changed=true
    }
    return hash
}

// The sidecar at path, in allocator. found is false, with an empty one, when
// the file is not there; a file that cannot be read as a sidecar is an error,
// not the defaults, so a source is never imported in a way nobody chose nor
// given new ids over the ones it had.
sidecar_load :: proc(path:string,allocator:=context.allocator) -> (sidecar:Sidecar,found:bool,error:Error) {
    sidecar.outputs=make([dynamic]Output,allocator)
    // A source that names a device has no file next to it.
    if unsafe_path(path) {return}
    data,file_error:=serial.file_read(path,context.temp_allocator)
    if file_error==.Not_Found {return}
    if file_error!=.None {return sidecar,false,error_make(.Not_Found,"%s could not be read",path)}
    parsed,valid:=sidecar_parse(string(data),allocator)
    if !valid {return sidecar,false,error_make(.Malformed,"%s is not the settings and outputs of an import (version %d): fix it, or delete it and import its source again, which gives its assets new ids",path,SIDECAR_VERSION)}
    delete(sidecar.outputs)
    return parsed,true,{}
}

// Writes the sidecar, unless the file already says the same.
sidecar_save :: proc(path:string,sidecar:Sidecar) -> bool {
    text:=sidecar_text(sidecar,context.temp_allocator)
    if data,read_error:=os.read_entire_file(path,context.temp_allocator);read_error==nil && string(data)==text {return true}
    if folder:=filepath.dir(path);!os.is_dir(folder) {_=os.make_directory_all(folder)}
    return serial.file_write_atomic(path,transmute([]u8)text)==.None
}

// The settings kept with a source, the defaults (found false) when it has no
// sidecar. root and folder: those of its import (sidecar_path).
settings_load :: proc(source:string,root:="",folder:="") -> (settings:Import_Settings,found:bool,error:Error) {
    sidecar:Sidecar
    sidecar,found,error=sidecar_load(sidecar_path(source,root,folder,context.temp_allocator),context.temp_allocator)
    return sidecar.settings,found,error
}

// The asset the import of a source gave what the source names name, of kind;
// false when its sidecar lists none. root as in settings_load.
output_id :: proc(source:string,kind:asset.Fourcc,name:string,root:="") -> (id:base.Asset_Id,found:bool) {
    sidecar,_,error:=sidecar_load(sidecar_path(source,root,allocator=context.temp_allocator),context.temp_allocator)
    if error.code!=.None {return}
    for output in sidecar.outputs {
        if output.kind==kind && output.name==name {return output.id,true}
    }
    return
}
