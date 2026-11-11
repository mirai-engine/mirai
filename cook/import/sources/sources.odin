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
import "mirai:project"
import "mirai:std/serial"

// The source files a project imports and the one way they are imported, the
// same from the editor, from mirai import, from sync and from the tools that
// generate content: a model in one of the formats given (FORMATS, and those
// the plugins of the project add) becomes its meshes, materials, textures, skeletons and
// clips with a prefab of its hierarchy; an image becomes a texture; a sound
// file, a sound; a font, a font; a manifest
// of prompts, a pack of prompts and its atlases. A format of the engine is a
// package of its own with its Format; it is added here and nowhere else.

@(rodata)
FORMATS:=[?]importer.Format{gltf.FORMAT,usd.FORMAT,fbx.FORMAT,obj.FORMAT}

IMAGE_EXTENSIONS :: [?]string{".png",".jpg",".jpeg",".tga",".bmp",".gif",".psd",".hdr"}
SOUND_EXTENSIONS :: [?]string{".wav",".ogg"}
FONT_EXTENSIONS :: [?]string{".ttf",".otf",".ttc"}

Source_Kind :: enum u8 {None,Model,Image,Sound,Font,Prompts}

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

// What a file is, by its first bytes: a model of one of formats (nil:
// FORMATS), an image stb decodes, a WAV or Ogg sound or a font (a collection
// too, which the import refuses saying why). A format whose bytes say
// nothing (OBJ, TGA, a manifest of prompts) is known by its extension.
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

// The project or the plugin whose assets folder has the file at path: the
// folder that holds the nearest assets folder above it. False for a file in
// no assets folder.
source_root :: proc(path:string,allocator:=context.allocator) -> (root:string,ok:bool) {
    names:=project.FOLDER_NAMES
    folder:=project.path_absolute(path,context.temp_allocator)
    for {
        parent:=filepath.dir(folder)
        if parent==folder {return}
        if filepath.base(parent)==names[.Assets] {return strings.clone(filepath.dir(parent),allocator),true}
        folder=parent
    }
}

// Imports a source file in the assets folder of a project or a plugin
// (options.root; "": source_root): a model writes its assets and, when it
// has nodes, the prefab of its hierarchy, which the report lists last; an
// image or a sound writes one asset. The sidecar of the source
// (<source>.import, Import_Report.saved) keeps the settings it was imported
// with, the folder of its assets and the id of each of them: importing the
// source again gives the same assets. What the import builds that nobody
// edits goes to the imported folder of the root (importer.Sidecar), whatever
// the format that reads it.
import_source :: proc(path:string,options:importer.Import_Options={},formats:[]importer.Format=nil,allocator:=context.allocator) -> (report:importer.Import_Report,error:importer.Error) {
    formats:=formats if formats!=nil else FORMATS[:]
    options:=options
    kind:=source_kind(path,formats)
    if options.root=="" {options.root,_=source_root(path,context.temp_allocator)}
    switch kind {
    case .None:
        if importer.unsafe_path(path) || !os.exists(path) {return {},importer.error_make(.Not_Found,"%s does not exist",path)}
        return {},importer.error_make(.Unsupported,"%s is not a file Mirai imports: a model (%s), an image, a sound (WAV, Ogg Vorbis), a font (TrueType, OpenType) or a manifest of prompts (%s); a format a plugin adds imports with the plugin in the project",path,importer.format_names(formats),importer.PROMPTS_MANIFEST)
    case .Model:
        return prefab.model_import(path,formats,options,allocator)
    case .Image:
        return importer.import_texture(path,options,allocator)
    case .Sound:
        return importer.import_sound(path,{},options,allocator)
    case .Font:
        return importer.import_font(path,options,allocator)
    case .Prompts:
        return importer.import_prompts(path,options,allocator)
    }
    return
}
