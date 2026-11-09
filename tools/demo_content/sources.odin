package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import "mirai:project"

// The imports of demo/source/textures and demo/source/models into
// demo/assets, with sources.import_source as the editor and mirai import do.
// Each image is read as its use asks, which its name tells; the maps of the
// materials name it by the id that use gives.

// The cutoff of the masked materials that read an image: every level of its
// texture keeps that coverage. Their settings are written next to them, so
// the editor and mirai import give the same textures when they import them.
@(private) ALPHA_COVERAGE :: [?]struct{file:string,cutoff:f32}{{"grate_color.png",0.5},{"leaves_color.png",0.5}}

// Files under a folder, relative to it with forward slashes, sorted.
@(private)
files_under :: proc(folder:string,out:^[dynamic]string,relative:="") {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        name:=relative==""?entry.name:fmt.tprintf("%s/%s",relative,entry.name)
        if entry.type==.Directory {
            files_under(fmt.tprintf("%s/%s",folder,entry.name),out,name)
        } else {
            append(out,name)
        }
    }
    if relative=="" {slice.sort(out[:])}
}

// The textures built by an import before, which the editor of the demo shares.
@(private="file")
texture_cache :: proc(o:^Out) -> string {return project.cache_path(fmt.tprintf("%s/demo",o.root),project.TEXTURE_CACHE,allocator=context.temp_allocator)}

// How an image is read, by the end of its name: _normal a normal map, _orm
// occlusion, roughness and metalness as they are, any other a color.
@(private)
texture_options :: proc(o:^Out,file:string) -> importer.Import_Options {
    stem:=filepath.stem(file)
    options:=importer.Import_Options{root=fmt.tprintf("%s/demo",o.root),image=.Color,no_save=true,texture_cache=texture_cache(o)}
    if strings.has_suffix(stem,"_normal") {options.image=.Normal} else if strings.has_suffix(stem,"_orm") {options.image=.Data}
    for entry in ALPHA_COVERAGE {
        if entry.file==file {options.alpha_coverage,options.ignore_stored,options.no_save=entry.cutoff,true,false}
    }
    return options
}

// The folder under assets/ of the texture of an image, from the start of its
// name: the area or the surface it belongs to.
@(private)
TEXTURE_FOLDERS :: [?]struct{prefix,folder:string}{
    {"bricks_","surfaces/bricks"},{"brushed_","surfaces/metal"},{"church_glass_","church"},{"cobblestone_","surfaces/cobblestone"},
    {"grate_","surfaces/metal"},{"leaves_","gallery"},{"marble_","surfaces/marble"},{"neon_","surfaces/neon"},{"planks_","surfaces/wood"},
    {"sky_","sky"},{"stained_glass_","surfaces/glass"},{"tiles_","surfaces/tiles"},{"vase_","gallery"},
}

// file: relative to source/textures. The texture goes to its folder of
// TEXTURE_FOLDERS with the name of the file.
import_texture :: proc(o:^Out,file:string) {
    source:=fmt.tprintf("source/textures/%s",file)
    folder:=""
    for entry in TEXTURE_FOLDERS {
        if strings.has_prefix(filepath.base(file),entry.prefix) {folder=entry.folder;break}
    }
    if folder=="" {
        fmt.eprintfln("demo_content: %s: no folder for its texture",source)
        o.content.failed=true
        return
    }
    report,error:=sources.import_source(path(o,source),path(o,fmt.tprintf("assets/%s",folder)),texture_options(o,file))
    if error.code!=.None {
        fmt.eprintfln("demo_content: %s: %s",source,error.message)
        o.content.failed=true
        return
    }
    defer importer.report_destroy(&report)
    fmt.printfln("wrote assets/%s/%s.tex",folder,strings.trim_suffix(filepath.base(file),filepath.ext(file)))
}

// The folder under assets/ of the output of each model of source/models.
@(private)
MODEL_FOLDERS :: [?]struct{file,folder:string}{
    {"mirai/mirai.glb","characters/mirai"},{"morph-playground/jelly.gltf","characters/jelly/jelly.gltf"},
    {"plant.gltf","gallery/plant.gltf"},{"skeletal-character/robot.glb","characters/robot/robot.glb"},
    {"skeletal-character/robot.gltf","characters/robot/robot.gltf"},{"vase.obj","gallery/vase.obj"},
}

// file: relative to source/models. Its meshes, materials and prefab go to its
// folder of MODEL_FOLDERS. Its images of source/textures are those
// import_texture writes.
import_model :: proc(o:^Out,file:string) {
    source:=fmt.tprintf("source/models/%s",file)
    folder:=""
    for entry in MODEL_FOLDERS {
        if entry.file==file {folder=entry.folder;break}
    }
    if folder=="" {
        fmt.eprintfln("demo_content: %s: no folder for its import",source)
        o.content.failed=true
        return
    }
    report,error:=sources.import_source(path(o,source),path(o,fmt.tprintf("assets/%s",folder)),{root=fmt.tprintf("%s/demo",o.root),texture_cache=texture_cache(o)})
    if error.code!=.None {
        fmt.eprintfln("demo_content: %s: %s",source,error.message)
        o.content.failed=true
        return
    }
    defer importer.report_destroy(&report)
    for written in report.assets {
        switch {
        case written.kind==asset.KIND_MESH,written.kind==asset.KIND_MATERIAL: fmt.printfln("%s: %s",written.name,written.detail)
        case written.kind==asset.KIND_PREFAB: fmt.printfln("wrote assets/%s/%s.prefab",folder,written.name)
        }
    }
    for warning in report.warnings {fmt.printfln("%s: %s",source,warning)}
    fmt.printfln("imported %s",source)
}

// Every image of source/textures and every model of source/models.
import_sources :: proc(o:^Out) {
    images,models:[dynamic]string
    images.allocator,models.allocator=context.temp_allocator,context.temp_allocator
    files_under(path(o,"source/textures"),&images)
    for file in images {
        if sources.source_kind(path(o,fmt.tprintf("source/textures/%s",file)))==.Image {import_texture(o,file)}
    }
    files_under(path(o,"source/models"),&models)
    for file in models {
        if sources.source_kind(path(o,fmt.tprintf("source/models/%s",file)))==.Model {import_model(o,file)}
    }
}
