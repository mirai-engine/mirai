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

// Whether a model is read by a format that is not one of FORMATS: one a
// plugin adds, which only an editor with that plugin has.
@(private)
model_of_plugin :: proc(path:string,formats:[]importer.Format) -> bool {
    buffer:[importer.SNIFF_BYTES]u8
    head,_,error:=serial.file_read_head(path,buffer[:])
    if error!=.None {return false}
    format,found:=importer.format_find(formats,head,strings.to_lower(filepath.ext(path),context.temp_allocator))
    if !found {return false}
    for own in FORMATS {
        if own.name==format.name {return false}
    }
    return true
}

// Imports a source file into folder: a model writes its assets and, when it
// has nodes, the prefab of its hierarchy, which the report lists last; an
// image or a sound writes one asset. The sidecar of the source
// (<source>.import, Import_Report.saved) keeps the settings it was imported
// with, the folder and the id of each asset: importing the source again, with
// folder "" for the one its sidecar says, gives the same assets. With
// options.root, what the import builds that nobody edits goes to the imported
// folder of the root and the rest to folder (importer.Sidecar); a model of a
// format a plugin adds keeps everything in folder, since only an editor with
// that plugin imports it.
import_source :: proc(path,folder:string,options:importer.Import_Options={},formats:[]importer.Format=nil,allocator:=context.allocator) -> (report:importer.Import_Report,error:importer.Error) {
    formats:=formats if formats!=nil else FORMATS[:]
    options,folder:=options,folder
    kind:=source_kind(path,formats)
    if folder=="" && kind!=.None {
        // Where its source is among the sources: a model in a folder of its own.
        names:=project.FOLDER_NAMES
        named:=importer.source_path(options,path)
        if options.root=="" || !strings.has_prefix(named,names[.Source]) {return {},importer.error_make(.Not_Found,"%s: pass the folder its assets go to; only a source in the %s folder of a project (root) goes where it is",path,names[.Source])}
        beside,_:=strings.replace_all(filepath.dir(named[len(names[.Source]):]),"\\","/",context.temp_allocator)
        folder=fmt.tprintf("%s/%s%s",project.folder_path(options.root,.Assets,context.temp_allocator),strings.trim_left(beside,"/."),kind==.Model?fmt.tprintf("/%s",model_folder(path,formats)):"")
    }
    if kind==.Model && model_of_plugin(path,formats) {options.documents=true}
    // Without a root the sidecar is in the folder, which reading a model does not know.
    if kind==.Model && options.root=="" && !options.ignore_stored {
        stored,found,settings_error:=importer.settings_load(path,"",folder)
        if settings_error.code!=.None {return {},settings_error}
        if found {options.settings,options.ignore_stored=stored,true}
    }
    switch kind {
    case .None:
        if importer.unsafe_path(path) || !os.exists(path) {return {},importer.error_make(.Not_Found,"%s does not exist",path)}
        return {},importer.error_make(.Unsupported,"%s is not a file Mirai imports: a model (%s), an image, a sound (WAV, Ogg Vorbis), a font (TrueType, OpenType), texts (CSV) or a manifest of prompts (%s); the formats a plugin adds import in the editor",path,importer.format_names(formats),importer.PROMPTS_MANIFEST)
    case .Model:
        report,error=prefab.model_import(path,folder,formats,options,allocator)
    case .Image:
        report,error=importer.import_texture(path,folder,options,allocator)
    case .Sound:
        report,error=importer.import_sound(path,folder,{},options,allocator)
    case .Font:
        report,error=importer.import_font(path,folder,options,allocator)
    case .Strings:
        report,error=importer.import_strings(path,folder,options,allocator)
    case .Prompts:
        report,error=importer.import_prompts(path,folder,options,allocator)
    }
    if error.code!=.None {return {},error}
    return report,{}
}
