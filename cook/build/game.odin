package build

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:project"
import "mirai:std/base"

// What a shipped game carries next to its executable besides its cooked
// assets (cook.odin), which hold those of its active plugins, and its
// settings (Job.settings): the manifest, the icon, the bindings, the shader generation
// and the dynamic libraries the runtime loads. A dedicated server, which
// nobody sees, carries neither the icon nor the shaders. Sources of art and
// of code stay behind.
@(private)
game_copies :: proc(p:^project.Project,folder,compiler:string,a:runtime.Allocator,server:=false) -> []Copy {
    copies:=make([dynamic]Copy,a)
    names:=project.FOLDER_NAMES
    parts:=project.PART_NAMES
    append(&copies,Copy{project.path(p.root,project.PROJECT_FILE,allocator=a),project.path(folder,project.PROJECT_FILE,allocator=a),false})
    if icon:=base.text_get(p.manifest.icon[:]);icon!="" && !server {
        if from:=project.path(p.root,icon,allocator=a);os.is_file(from) {append(&copies,Copy{from,project.path(folder,icon,allocator=a),false})}
    }
    if !server {shaders_copies(&copies,p.root,folder,a)}
    when ODIN_OS==.Windows {
        // SDL3 is linked dynamically and ships with the compiler.
        odin_root,configured:=os.lookup_env("ODIN_ROOT",context.temp_allocator)
        if !configured || odin_root=="" {
            cut:=strings.last_index_any(compiler,"/\\")
            odin_root=cut>=0?compiler[:cut]:"."
        }
        if sdl:=project.path(odin_root,"vendor/sdl3/SDL3.dll",allocator=a);os.is_file(sdl) {
            append(&copies,Copy{sdl,project.path(folder,"SDL3.dll",allocator=a),false})
        }
    } else when ODIN_OS==.Linux {
        // The SDL3 of scripts/setup_linux_deps.py: platform_flags makes the game look for it next to itself.
        if sdl:=project.path(linux_deps(p.engine_root),"sdl3/lib/libSDL3.so.0",allocator=a);os.is_file(sdl) {
            append(&copies,Copy{sdl,project.path(folder,"libSDL3.so.0",allocator=a),false})
        }
    } else when ODIN_OS==.Darwin {
        // The SDL3 of scripts/setup_macos_deps.py: platform_flags makes the game look for it next to itself.
        if sdl,relocatable:=macos_sdl(p.engine_root);relocatable {
            append(&copies,Copy{project.path(sdl,MACOS_SDL,allocator=a),project.path(folder,MACOS_SDL,allocator=a),false})
        }
    }
    return copies[:]
}

// Puts next to the executable of a game what it ships: its files, its
// settings, and the assets of the project, cooked.
@(private)
job_ship :: proc(job:^Job) -> Failure {
    if !copies_run(job.copies) {return .Copy_Failed}
    folder:=job.published[:strings.last_index_byte(job.published,'/')]
    if os.write_entire_file(project.path(folder,project.SETTINGS_FILE,allocator=context.temp_allocator),job.settings)!=nil {return .Copy_Failed}
    if job.cook.assets=="" {return .None}
    job.result.cook=cook_assets(job.cook)
    return job.result.cook.error==.None?.None:.Cook_Failed
}

// Files are replaced and folders merged: nothing of the destination is removed.
@(private)
copies_run :: proc(copies:[]Copy) -> bool {
    for copy in copies {
        parent:=copy.to[:strings.last_index_byte(copy.to,'/')]
        if os.make_directory_all(parent)!=nil && !os.is_dir(parent) {return false}
        if copy.folder {
            if os.copy_directory_all(copy.to,copy.from)!=nil {return false}
        } else if os.copy_file(copy.to,copy.from)!=nil {
            return false
        }
    }
    return true
}

// The engine-time packages among the sources of a build, by folder: the
// editor/ and cook/ of the engine, the editor/ of the project, the editor/ of
// any plugin of either, what is generated for the editor and every package of
// the development plugins, whose folders are given. Sorted.
engine_time_packages :: proc(sources:[]string,root,engine_root:string,development:[]string={},allocator:=context.allocator) -> []string {
    inside :: proc(file,folder:string) -> (relative:string,ok:bool) {
        if folder=="" || len(file)<=len(folder) || file[len(folder)]!='/' || !project.path_same(file[:len(folder)],folder) {return "",false}
        return file[len(folder)+1:],true
    }
    plugin_editor :: proc(relative:string) -> bool {
        if !strings.has_prefix(relative,"plugins/") {return false}
        rest:=relative[len("plugins/"):]
        slash:=strings.index_byte(rest,'/')
        return slash>0 && strings.has_prefix(rest[slash+1:],"editor/")
    }
    found:=make([dynamic]string,allocator)
    for source in sources {
        engine_time:=false
        if relative,ok:=inside(source,engine_root);ok {
            for prefix in ([]string{"editor/","cook/"}) {
                if strings.has_prefix(relative,prefix) {engine_time=true}
            }
            if plugin_editor(relative) {engine_time=true}
        }
        if relative,ok:=inside(source,root);ok {
            if strings.has_prefix(relative,"editor/") || strings.has_prefix(relative,".mirai/gen/editor/") || strings.has_prefix(relative,".mirai/gen/editor_world/") || plugin_editor(relative) {engine_time=true}
        }
        for folder in development {
            if _,ok:=inside(source,folder);ok {engine_time=true}
        }
        if !engine_time {continue}
        folder:=source[:strings.last_index_byte(source,'/')]
        known:=false
        for other in found {
            if other==folder {known=true;break}
        }
        if !known {append(&found,strings.clone(folder,allocator))}
    }
    slice.sort(found[:])
    return found[:]
}
