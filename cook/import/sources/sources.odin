package sources

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/fbx"
import "mirai:cook/import/gltf"
import "mirai:cook/import/obj"
import "mirai:cook/import/usd"
import "mirai:cook/prefab"
import "mirai:std/serial"

// The source files a project imports and the one way they are imported, the
// same from the editor, from mirai import and from the tools that generate
// content: a model in one of the formats given (FORMATS, and in the editor
// those of plugins) becomes its meshes, materials, textures, skeletons and
// clips with a prefab of its hierarchy; an image becomes a texture; a sound
// file, a sound; a font, a font; a CSV of texts, a table of texts; a manifest
// of prompts, a pack of prompts and its atlases. A format of the engine is a
// package of its own with its Format; it is added here and nowhere else.

@(rodata)
FORMATS:=[?]importer.Format{gltf.FORMAT,usd.FORMAT,fbx.FORMAT,obj.FORMAT}

IMAGE_EXTENSIONS :: [?]string{".png",".jpg",".jpeg",".tga",".bmp",".gif",".psd",".hdr"}
SOUND_EXTENSIONS :: [?]string{".wav",".ogg"}
FONT_EXTENSIONS :: [?]string{".ttf",".otf",".ttc"}

Source_Kind :: enum u8 {None,Model,Image,Sound,Font,Strings,Prompts}

// What an image imported on its own holds by what its name says, for a source
// with no use in its settings: a normal map, linear data (roughness, metal,
// occlusion, masks, heights) or else a color.
image_use :: proc(path:string) -> importer.Image_Use {
    name:=strings.to_lower(filepath.stem(path),context.temp_allocator)
    for part in ([?]string{"normal","nrm"}) {
        if strings.contains(name,part) {return .Normal}
    }
    // The short forms only as a word after the first: "wall_n_2" and "wall_nor_gl", not "panel_nmbr".
    words:=name
    _,_=strings.split_iterator(&words,"_")
    for word in strings.split_iterator(&words,"_") {
        switch word {
        case "n","nm","nor","norm": return .Normal
        }
    }
    for part in ([?]string{"rough","metal","orm","occlusion","_ao","height","displace","mask","specular","data"}) {
        if strings.contains(name,part) {return .Data}
    }
    return .Color
}

// The use of an image by its name in asset.import and the settings: color,
// data, normal or normal_green_down, in any case.
image_use_from_name :: proc(name:string) -> (use:importer.Image_Use,ok:bool) {
    switch strings.to_lower(name,context.temp_allocator) {
    case "color","srgb": return .Color,true
    case "data","linear": return .Data,true
    case "normal": return .Normal,true
    case "normal_green_down": return .Normal_Green_Down,true
    }
    return .Color,false
}

// The folder of models/ the import of a model goes to: what its format (of
// formats; nil: FORMATS) says (Format.folder), else its file name.
model_folder :: proc(path:string,formats:[]importer.Format=nil) -> string {
    formats:=formats if formats!=nil else FORMATS[:]
    extension:=strings.to_lower(filepath.ext(path),context.temp_allocator)
    for format in formats {
        for known in format.extensions {
            if known!="" && known==extension && format.folder!=nil {return format.folder(path)}
        }
    }
    return filepath.base(path)
}

// What a file is, by its first bytes: a model of one of formats (nil:
// FORMATS), an image stb decodes, a WAV or Ogg sound or a font (a collection
// too, which the import refuses saying why). A format whose bytes say
// nothing (OBJ, TGA, CSV, a manifest of prompts) is known by its extension.
// None for anything else and for a file that cannot be read.
source_kind :: proc(path:string,formats:[]importer.Format=nil) -> Source_Kind {
    formats:=formats if formats!=nil else FORMATS[:]
    if importer.unsafe_path(path) {return .None}
    // A folder is a pack of prompts when the names of its images say inputs.
    if os.is_dir(path) {
        entries,_:=importer.prompts_folder(path,context.temp_allocator)
        return .Prompts if len(entries)>0 else .None
    }
    buffer:[importer.SNIFF_BYTES]u8
    head,_,error:=serial.file_read_head(path,buffer[:])
    if error!=.None {return .None}
    extension:=strings.to_lower(filepath.ext(path),context.temp_allocator)
    if _,found:=importer.format_find(formats,head,extension);found {return .Model}
    text:=string(head)
    switch {
    case extension==".csv":
        return .Strings
    case strings.has_suffix(strings.to_lower(path,context.temp_allocator),importer.PROMPTS_MANIFEST):
        return .Prompts
    case strings.has_prefix(text,"\x89PNG"),strings.has_prefix(text,"\xff\xd8\xff"),strings.has_prefix(text,"BM"),strings.has_prefix(text,"GIF8"),strings.has_prefix(text,"8BPS"),
         strings.has_prefix(text,"#?RADIANCE"),strings.has_prefix(text,"#?RGBE"):
        return .Image
    case strings.has_prefix(text,"RIFF") && len(text)>=12 && text[8:12]=="WAVE",strings.has_prefix(text,"OggS"):
        return .Sound
    case strings.has_prefix(text,"\x00\x01\x00\x00"),strings.has_prefix(text,"true"),strings.has_prefix(text,"OTTO"),strings.has_prefix(text,"ttcf"):
        return .Font
    case extension==".tga":
        return .Image
    }
    return .None
}

// Imports a source file into folder: a model writes its assets and, when it
// has nodes, <folder>/<name>.prefab, which the report lists last; an image or
// a sound writes one asset. The settings a model or an image was imported
// with are written next to it (<source>.import, Import_Report.saved) unless
// options.no_save; a settings file that cannot be written leaves a warning.
import_source :: proc(path,folder:string,options:importer.Import_Options={},formats:[]importer.Format=nil,allocator:=context.allocator) -> (report:importer.Import_Report,error:importer.Error) {
    formats:=formats if formats!=nil else FORMATS[:]
    switch source_kind(path,formats) {
    case .None:
        if importer.unsafe_path(path) || !os.exists(path) {return {},importer.error_make(.Not_Found,"%s does not exist",path)}
        return {},importer.error_make(.Unsupported,"%s is not a file Mirai imports: a model (%s), an image, a sound (WAV, Ogg Vorbis), a font (TrueType, OpenType), texts (CSV) or a manifest of prompts (%s); the formats a plugin adds import in the editor",path,importer.format_names(formats),importer.PROMPTS_MANIFEST)
    case .Model:
        report,error=prefab.model_import(path,folder,formats,options,allocator)
    case .Image:
        report,error=importer.import_texture(path,folder,options,allocator)
    case .Sound:
        return importer.import_sound(path,folder,{},options,allocator)
    case .Font:
        return importer.import_font(path,folder,options,allocator)
    case .Strings:
        return importer.import_strings(path,folder,options,allocator)
    case .Prompts:
        return importer.import_prompts(path,folder,options,allocator)
    }
    if error.code!=.None {return {},error}
    if options.no_save {return report,{}}
    if importer.settings_save(path,report.settings) {
        report.saved=importer.settings_path(path,allocator)
    } else {
        append(&report.warnings,fmt.aprintf("the settings could not be written to %s",importer.settings_path(path,context.temp_allocator),allocator=allocator))
    }
    return report,{}
}
