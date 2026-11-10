package importer

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:std/base"
import "mirai:std/serial"

// <source>.import, the sidecar (asset/sidecar.odin): what is versioned of an
// import with its source, beside it in the assets of a project or a plugin.
// It says how the source becomes assets (settings), where its outputs go and
// which asset each thing of the source is (outputs): nothing else decides an
// id. The meshes, textures, sounds and fonts (asset.import_cached), which
// nobody edits, are files of the imported folder of the root named by their
// ids, never versioned: the registry lists them by where the sidecar is, and
// sources.sync builds them again. The other kinds are documents of the
// assets, found by their id.

SIDECAR_EXTENSION :: asset.SIDECAR_EXTENSION

Output :: asset.Import_Output

Sidecar :: struct {
    settings:Import_Settings,
    folder:string, // under the folder of the source, where its outputs go; "": beside it
    inputs:[dynamic]string, // the files the import read besides the source, from the folder of the source: with it, what the outputs are built from
    outputs:[dynamic]Output,
}

@(private="file")
settings_valid :: proc(settings:Import_Settings) -> bool {
    return settings.max_texture_size>=0 && settings.max_triangles>=0 && settings.collision_hulls>=0 && settings.textures<=max(textures.Encoding) && settings.rdo_lambda<=textures.RDO_LAMBDA_MAX &&
        settings.image<=max(Image_Use) && settings.alpha_coverage>=0 && settings.alpha_coverage<=1 && settings.lods<=max(Lods) && settings.collision<=max(Collision) && settings.parts<=max(Parts) && settings.front<=max(Front) && settings.rig<=max(Rig) &&
        settings.rig_crotch>=0 && settings.rig_neck>=0 && (settings.rig==.Humanoid || settings.rig_crotch==0 && settings.rig_neck==0)
}

// The settings as the text of their object, in the sidecar.
@(private="file")
settings_text :: proc(settings:Import_Settings,allocator:=context.allocator) -> string {
    settings:=settings
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add(&schema,Import_Settings)
    w:serial.Writer
    serial.writer_init(&w,512,allocator)
    serial.text_write(&w,&schema,type,([^]u8)(&settings)[:size_of(Import_Settings)],depth=1)
    return string(serial.writer_take(&w))
}

sidecar_text :: proc(sidecar:Sidecar,allocator:=context.allocator) -> string {
    return asset.sidecar_text(settings_text(sidecar.settings,context.temp_allocator),{folder=sidecar.folder,inputs=sidecar.inputs,outputs=sidecar.outputs},allocator)
}

// False for a text that is not the sidecar of a source (asset.sidecar_parse)
// or whose settings this build does not read. What it holds lives in
// allocator, an arena: nothing frees it piece by piece.
sidecar_parse :: proc(text:string,allocator:=context.allocator) -> (sidecar:Sidecar,ok:bool) {
    parsed:=asset.sidecar_parse(text,allocator) or_return
    sidecar.folder,sidecar.inputs,sidecar.outputs=parsed.folder,parsed.inputs,parsed.outputs
    if parsed.settings!="" {
        schema:serial.Schema
        serial.schema_init(&schema,context.temp_allocator)
        defer serial.schema_destroy(&schema)
        type,_:=serial.schema_add(&schema,Import_Settings)
        r:serial.Text_Reader
        serial.text_reader_init(&r,parsed.settings,context.temp_allocator)
        defer serial.text_reader_destroy(&r)
        serial.text_read(&r,&schema,type,([^]u8)(&sidecar.settings)[:size_of(Import_Settings)]) or_return
    }
    return sidecar,settings_valid(sidecar.settings)
}

// What the outputs of an import are built from, as one number: the bytes of
// the source at path and of each input its sidecar lists, its settings, the
// version of what reads and writes it and whether its textures are built
// Fast. An output of the cache is current when its file is named by this key.
import_key :: proc(path:string,sidecar:Sidecar,version:u32,fast:bool) -> u64 {
    key:=base.hash_combine(u64(version)<<1|u64(fast),u64(asset.MESH_VERSION)<<32|u64(asset.TEXTURE_VERSION)<<16|u64(textures.BUILD_VERSION))
    key=base.hash_combine(key,base.hash64(transmute([]u8)settings_text(sidecar.settings,context.temp_allocator)))
    folder:=filepath.dir(path)
    for at in -1..<len(sidecar.inputs) {
        file:=path if at<0 else fmt.tprintf("%s/%s",folder,sidecar.inputs[at])
        bytes,_:=serial.file_read(file,context.temp_allocator,limit=MAX_SOURCE_BYTES)
        key=base.hash_combine(key,base.hash64(bytes))
        delete(bytes,context.temp_allocator)
    }
    return key|1
}

// The sidecar of the source at source, in allocator. found is false, with an
// empty one, when the file is not there; a file that cannot be read as a
// sidecar is an error, not the defaults, so a source is never imported in a
// way nobody chose nor given new ids over the ones it had.
sidecar_load :: proc(source:string,allocator:=context.allocator) -> (sidecar:Sidecar,found:bool,error:Error) {
    sidecar.outputs=make([dynamic]Output,allocator)
    path:=strings.concatenate({source,SIDECAR_EXTENSION},context.temp_allocator)
    // A source that names a device has no file next to it.
    if unsafe_path(path) {return}
    data,file_error:=serial.file_read(path,context.temp_allocator)
    if file_error==.Not_Found {return}
    if file_error!=.None {return sidecar,false,error_make(.Not_Found,"%s could not be read",path)}
    parsed,valid:=sidecar_parse(string(data),allocator)
    if !valid {return sidecar,false,error_make(.Malformed,"%s is not the settings and outputs of an import (version %d): fix it, or delete it and import its source again, which gives its assets new ids",path,asset.SIDECAR_VERSION)}
    delete(sidecar.outputs)
    return parsed,true,{}
}

// Writes the sidecar of the source at source, unless the file already says the same.
sidecar_save :: proc(source:string,sidecar:Sidecar) -> bool {
    path:=strings.concatenate({source,SIDECAR_EXTENSION},context.temp_allocator)
    text:=sidecar_text(sidecar,context.temp_allocator)
    if data,read_error:=os.read_entire_file(path,context.temp_allocator);read_error==nil && string(data)==text {return true}
    return serial.file_write_atomic(path,transmute([]u8)text)==.None
}

// The settings kept with a source, the defaults (found false) when it has no sidecar.
settings_load :: proc(source:string) -> (settings:Import_Settings,found:bool,error:Error) {
    sidecar:Sidecar
    sidecar,found,error=sidecar_load(source,context.temp_allocator)
    return sidecar.settings,found,error
}

// The asset the import of a source gave what the source names name, of kind;
// false when its sidecar lists none.
output_id :: proc(source:string,kind:asset.Fourcc,name:string) -> (id:base.Asset_Id,found:bool) {
    sidecar,_,error:=sidecar_load(source,context.temp_allocator)
    if error.code!=.None {return}
    for output in sidecar.outputs {
        if output.kind==kind && output.name==name {return output.id,true}
    }
    return
}
