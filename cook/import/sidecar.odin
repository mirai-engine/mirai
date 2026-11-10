package importer

import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// What is versioned of an import: the source and, next to it, <source>.import,
// a text that says how the source becomes assets (its settings), where they go
// (folder) and which asset each thing of the source is (outputs). The id of an
// output lives there and nowhere else decides it: importing the source again,
// on any machine, gives every part the asset it had, so what names it keeps
// naming it. What the import builds is of two sorts:
//
//   - the cache (kind_cached): meshes, textures, sounds and fonts. Nobody
//     edits them; they are files of the imported folder of the project
//     (project.imported_path), which is never versioned, at the path the
//     sidecar gives them among the assets, and are built again from the source
//     and the sidecar wherever they are missing (sources.sync);
//   - documents: materials, prefabs, skeletons, clips, texts and prompts. The
//     editor edits them, so they are files of the assets folder, versioned,
//     found by their id wherever a person moved them; an import writes again
//     what the source gives and keeps what was changed.
//
// An import whose source cannot be imported again from the checkout alone has
// no cache: every output is a document of the folder. That is a source outside
// the root, whose sidecar is kept in the source folder of the root under the
// name of the file; a format the engine does not have
// (Import_Options.documents); and an import without a root, which belongs to
// no project: its sidecar is kept in the folder it writes to, under the name
// of the file, and nothing is written next to the source.

SIDECAR_EXTENSION :: ".import"
SIDECAR_VERSION :: 1

// One asset an import gives, by what it is in the source.
Output :: struct {
    kind:asset.Fourcc,
    name:string,       // in the source: the mesh, the material, the image
    index:int,         // among those of its kind in the source
    id:base.Asset_Id,
    path:string,       // of one in the cache: its path among the assets; "" for a document
    part:bool,         // of one in the cache: it is a part of the root of the import (parts.odin), decided when it was first imported
    shared:bool,       // another import writes it: this one only names it
}

Sidecar :: struct {
    settings:Import_Settings,
    // Where new outputs go: a folder of the assets of the root ("" for the
    // assets folder itself). Outside them, or without a root: a path that
    // starts at the folder of the sidecar with ./ or ../, else an absolute one.
    folder:string,
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
kind_text :: proc(kind:asset.Fourcc,buffer:^[4]u8) -> string {
    return strings.trim_right(asset.fourcc_text(kind,buffer)," ")
}

@(private="file")
kind_parse :: proc(text:string) -> (kind:asset.Fourcc,ok:bool) {
    if len(text)==0 || len(text)>4 {return 0,false}
    bytes:=[4]u8{' ',' ',' ',' '}
    copy(bytes[:],text)
    return asset.Fourcc(u32(bytes[0])|u32(bytes[1])<<8|u32(bytes[2])<<16|u32(bytes[3])<<24),true
}

@(private="file")
settings_valid :: proc(settings:Import_Settings) -> bool {
    return settings.max_texture_size>=0 && settings.max_triangles>=0 && settings.collision_hulls>=0 && settings.textures<=max(textures.Encoding) && settings.rdo_lambda<=textures.RDO_LAMBDA_MAX &&
        settings.image<=max(Image_Use) && settings.alpha_coverage>=0 && settings.alpha_coverage<=1 && settings.lods<=max(Lods) && settings.collision<=max(Collision) && settings.parts<=max(Parts) && settings.front<=max(Front) && settings.rig<=max(Rig) &&
        settings.rig_crotch>=0 && settings.rig_neck>=0 && (settings.rig==.Humanoid || settings.rig_crotch==0 && settings.rig_neck==0)
}

sidecar_text :: proc(sidecar:Sidecar,allocator:=context.allocator) -> string {
    settings:=sidecar.settings
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add(&schema,Import_Settings)
    w:serial.Writer
    serial.writer_init(&w,1024,allocator)
    serial.text_write_raw(&w,"{\n  \"version\": ")
    serial.text_write_int(&w,SIDECAR_VERSION)
    serial.text_write_raw(&w,",\n  \"settings\": ")
    serial.text_write(&w,&schema,type,([^]u8)(&settings)[:size_of(Import_Settings)],depth=1)
    serial.text_write_raw(&w,",\n  \"folder\": ")
    serial.text_write_string(&w,sidecar.folder)
    serial.text_write_raw(&w,",\n  \"outputs\": [")
    for output,at in sidecar.outputs {
        buffer:[4]u8
        serial.text_write_raw(&w,at>0?",\n    {\"kind\": ":"\n    {\"kind\": ")
        serial.text_write_string(&w,kind_text(output.kind,&buffer))
        serial.text_write_raw(&w,", \"name\": ")
        serial.text_write_string(&w,output.name)
        serial.text_write_raw(&w,", \"index\": ")
        serial.text_write_int(&w,i64(output.index))
        serial.text_write_raw(&w,", \"id\": \"")
        serial.text_write_asset_id(&w,output.id)
        serial.text_write_raw(&w,"\"")
        if output.path!="" {
            serial.text_write_raw(&w,", \"path\": ")
            serial.text_write_string(&w,output.path)
        }
        if output.part {serial.text_write_raw(&w,", \"part\": true")}
        if output.shared {serial.text_write_raw(&w,", \"shared\": true")}
        serial.text_write_raw(&w,"}")
    }
    serial.text_write_raw(&w,len(sidecar.outputs)>0?"\n  ]\n}\n":"]\n}\n")
    return string(serial.writer_take(&w))
}

// False for a text that is not the sidecar of a source: another version, a
// field or a value this build does not know, an output without an id or twice
// the same one. What it holds lives in allocator.
sidecar_parse :: proc(text:string,allocator:=context.allocator) -> (sidecar:Sidecar,ok:bool) {
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add(&schema,Import_Settings)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    sidecar.outputs=make([dynamic]Output,allocator)
    defer if !ok {
        sidecar_destroy(&sidecar,allocator)
        sidecar={}
    }
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
        case "folder":
            folder:=serial.text_string(&r) or_return
            delete(sidecar.folder,allocator)
            sidecar.folder=strings.clone(folder,allocator)
        case "outputs":
            serial.text_expect(&r,'[') or_return
            for begun:=false;!serial.text_accept(&r,']');begun=true {
                if begun {serial.text_expect(&r,',') or_return}
                output:=output_parse(&r,allocator) or_return
                append(&sidecar.outputs,output)
            }
        case:
            return
        }
    }
    serial.text_end(&r) or_return
    if version!=SIDECAR_VERSION || !settings_valid(sidecar.settings) || !path_plain(sidecar.folder,true) {return}
    for output,at in sidecar.outputs {
        if output.id=={} || output.kind==0 || output.index<0 || !path_plain(output.path,false) {return}
        if output.path!="" && (!kind_cached(output.kind) || output.shared) {return}
        if output.part && output.path=="" {return}
        for other in sidecar.outputs[:at] {
            if other.id==output.id || other.kind==output.kind && other.index==output.index && other.name==output.name {return}
            if output.path!="" && strings.equal_fold(other.path,output.path) {return}
        }
    }
    return sidecar,true
}

@(private="file")
output_parse :: proc(r:^serial.Text_Reader,allocator:=context.allocator) -> (output:Output,ok:bool) {
    defer if !ok {
        delete(output.name,allocator)
        delete(output.path,allocator)
    }
    serial.text_expect(r,'{') or_return
    for first:=true;!serial.text_accept(r,'}');first=false {
        if !first {serial.text_expect(r,',') or_return}
        key:=serial.text_string(r) or_return
        field:=strings.clone(key,context.temp_allocator)
        serial.text_expect(r,':') or_return
        switch field {
        case "kind":
            output.kind=kind_parse(serial.text_string(r) or_return) or_return
        case "name":
            name:=serial.text_string(r) or_return
            delete(output.name,allocator)
            output.name=strings.clone(name,allocator)
        case "index":
            negative,magnitude:=serial.text_integer(r) or_return
            if negative || magnitude>u64(max(i32)) {return}
            output.index=int(magnitude)
        case "id":
            output.id=serial.text_parse_asset_id(serial.text_string(r) or_return) or_return
        case "path":
            path:=serial.text_string(r) or_return
            delete(output.path,allocator)
            output.path=strings.clone(path,allocator)
        case "part","shared":
            value:=serial.text_keyword(r,"true")
            if !value && !serial.text_keyword(r,"false") {return}
            if field=="part" {output.part=value} else {output.shared=value}
        case:
            return
        }
    }
    return output,true
}

// Whether a path a sidecar holds stays where it says: relative, with forward
// slashes and no name that climbs out of its folder or that a file cannot
// have. A folder may also be an absolute path (an import without a root).
@(private="file")
path_plain :: proc(path:string,folder:bool) -> bool {
    if path=="" {return true}
    if unsafe_path(path) || strings.contains_rune(path,'\\') {return false}
    if folder {return true}
    if filepath.is_abs(path) || strings.has_prefix(path,"/") {return false}
    rest:=path
    for name in strings.split_iterator(&rest,"/") {
        if name=="" || name==".." || name=="." {return false}
    }
    return true
}

sidecar_destroy :: proc(sidecar:^Sidecar,allocator:=context.allocator) {
    for output in sidecar.outputs {
        delete(output.name,allocator)
        delete(output.path,allocator)
    }
    delete(sidecar.outputs)
    delete(sidecar.folder,allocator)
    sidecar^={}
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

// The folder the sidecar at file says its import goes to, for the root it was
// imported with.
sidecar_folder :: proc(root,file:string,sidecar:Sidecar,allocator:=context.temp_allocator) -> string {
    folder:=sidecar.folder
    joined:string
    switch {
    case filepath.is_abs(folder) || strings.has_prefix(folder,"/"):
        joined=folder
    case folder=="." || folder==".." || strings.has_prefix(folder,"./") || strings.has_prefix(folder,"../") || root=="":
        // What the sidecar sees from where it is.
        joined,_=filepath.join({filepath.dir(file),folder},context.temp_allocator)
    case:
        joined,_=filepath.join({project.folder_path(root,.Assets,context.temp_allocator),folder},context.temp_allocator)
    }
    slashed,_:=strings.replace_all(joined,"\\","/",allocator)
    return slashed
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
