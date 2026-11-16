package build

import "base:runtime"
import "core:os"
import "core:strings"
import "mirai:cook/workspace"
import "mirai:std/subprocess"
import "mirai:project"

// Where scripts/setup_linux_deps.py leaves the dependencies, inside the deps
// of the engine (workspace.deps_folder).
@(private)
LINUX_DEPS :: "linux-amd64"
// The Vulkan SDK of Windows inside the deps: its Bin has the validation layer.
@(private)
WINDOWS_VULKAN_LAYERS :: "vulkan-sdk-windows/Bin"
@(private)
HOMEBREW_LIB :: "/opt/homebrew/lib"
// Where scripts/setup_macos_deps.py leaves SDL3, inside the deps of the engine.
@(private)
MACOS_DEPS :: "macos-arm64"
// The file of SDL3 a program loads on macOS.
@(private)
MACOS_SDL :: "libSDL3.0.dylib"

// The flags the compiler needs to link the engine and SDL3: the one of
// scripts/setup_linux_deps.py on Linux; on macOS the one of
// scripts/setup_macos_deps.py, or Homebrew's. A shipped executable looks for
// SDL3 next to itself instead of in the engine, but Homebrew's, whose id
// names its folder.
platform_flags :: proc(engine_root:string,out:^[dynamic]string,shipped:=false,allocator:=context.allocator) {
    when ODIN_OS==.Linux {
        sdl:=strings.concatenate({linux_deps(engine_root),"/sdl3/lib"},context.temp_allocator)
        if os.is_dir(sdl) {
            linker_flags_append(out,strings.concatenate({`-L"`,sdl,`" -Wl,-rpath,"`,shipped?`\$ORIGIN`:sdl,`"`},context.temp_allocator),allocator)
        }
    } else when ODIN_OS==.Darwin {
        sdl,relocatable:=macos_sdl(engine_root)
        // The deployment target of the executable follows the SDL3 it links.
        minimum:="13.0"
        state,output,_,error:=subprocess.exec({command={"otool","-arch","arm64","-l",strings.concatenate({sdl,"/libSDL3.dylib"},context.temp_allocator)}},context.temp_allocator)
        if error==nil && state.exit_code==0 {
            if version,found:=macos_minimum_version(string(output));found {minimum=version}
        }
        append(out,strings.concatenate({"-minimum-os-version:",minimum},allocator))
        linker_flags_append(out,strings.concatenate({`-L"`,sdl,`" -Wl,-rpath,"`,shipped && relocatable?"@executable_path":sdl,`"`},context.temp_allocator),allocator)
    }
}

@(private)
linker_flags_append :: proc(out:^[dynamic]string,flags:string,allocator:=context.allocator) {
    prefix :: "-extra-linker-flags:"
    for &flag in out^ {
        if strings.has_prefix(flag,prefix) {
            flag=strings.concatenate({flag," ",flags},allocator)
            return
        }
    }
    append(out,strings.concatenate({prefix,flags},allocator))
}

// The variables the compiler and what it builds need on this platform, as
// NAME=value over what the process has: the Odin root with the C libraries
// compiled, and where the linker, the loader and Vulkan find the rest. The
// validation layer of the deps is added to the ones Vulkan finds. Empty when
// the environment of the process is enough.
platform_environment :: proc(engine_root:string,allocator:=context.allocator) -> []string {
    variables:=make([dynamic]string,allocator)
    when ODIN_OS==.Windows {
        layers:=strings.concatenate({workspace.deps_folder(engine_root,context.temp_allocator),"/",WINDOWS_VULKAN_LAYERS},context.temp_allocator)
        if os.is_file(strings.concatenate({layers,"/VkLayer_khronos_validation.json"},context.temp_allocator)) {
            search_path_prepend(&variables,"VK_ADD_LAYER_PATH",layers,allocator)
        }
    } else when ODIN_OS==.Linux {
        deps:=linux_deps(engine_root)
        odin_root:=strings.concatenate({deps,"/odin"},context.temp_allocator)
        if os.is_dir(strings.concatenate({odin_root,"/vendor"},context.temp_allocator)) {
            append(&variables,strings.concatenate({"ODIN_ROOT=",odin_root},allocator))
        }
        sdl:=strings.concatenate({deps,"/sdl3/lib"},context.temp_allocator)
        if os.is_dir(sdl) {
            search_path_prepend(&variables,"LIBRARY_PATH",sdl,allocator)
            search_path_prepend(&variables,"LD_LIBRARY_PATH",sdl,allocator)
        }
        layers:=strings.concatenate({deps,"/vulkan-sdk/share/vulkan/explicit_layer.d"},context.temp_allocator)
        if os.is_dir(layers) {search_path_prepend(&variables,"VK_ADD_LAYER_PATH",layers,allocator)}
    } else when ODIN_OS==.Darwin {
        if sdl,_:=macos_sdl(engine_root);os.is_dir(sdl) {search_path_prepend(&variables,"LIBRARY_PATH",sdl,allocator)}
    }
    return variables[:]
}

// The whole environment of a child that needs platform_environment, with
// libraries first where the loader looks for the libraries it links; nil when
// it inherits the one of the process as it is.
@(private)
child_environment :: proc(engine_root:string,allocator:runtime.Allocator,libraries:[]string=nil) -> []string {
    variables:=make([dynamic]string,allocator)
    append(&variables,..platform_environment(engine_root,allocator))
    loader :: "PATH" when ODIN_OS==.Windows else "DYLD_LIBRARY_PATH" when ODIN_OS==.Darwin else "LD_LIBRARY_PATH"
    separator :: ";" when ODIN_OS==.Windows else ":"
    for folder in libraries {
        at:=-1
        for variable,i in variables {
            if strings.has_prefix(variable,loader+"=") {at=i}
        }
        if at<0 {
            search_path_prepend(&variables,loader,folder,allocator)
            continue
        }
        variables[at]=strings.concatenate({loader,"=",folder,separator,variables[at][len(loader)+1:]},allocator)
    }
    if len(variables)==0 {return nil}
    inherited,_:=os.environ(allocator)
    list:=make([dynamic]string,0,len(inherited)+len(variables),allocator)
    outer: for entry in inherited {
        // Odin ends the environment of Linux with an empty entry (odin-lang/Odin#7964),
        // which std/subprocess refuses (ODIN_WORKAROUNDS).
        if entry=="" {continue}
        if cut:=strings.index_byte(entry,'=');cut>0 {
            for variable in variables {
                if strings.has_prefix(variable,entry[:cut+1]) {continue outer}
            }
        }
        append(&list,entry)
    }
    append(&list,..variables[:])
    return list[:]
}

@(private="file")
search_path_prepend :: proc(variables:^[dynamic]string,name,directory:string,allocator:runtime.Allocator) {
    separator :: ";" when ODIN_OS==.Windows else ":"
    current,_:=os.lookup_env(name,context.temp_allocator)
    present:=false
    rest:=current
    for entry in strings.split_iterator(&rest,separator) {
        if project.path_same(slashes(entry,context.temp_allocator),directory) {present=true}
    }
    if present {return}
    append(variables,strings.concatenate({name,"=",directory,current==""?"":separator,current},allocator))
}

// The Linux dependencies of scripts/setup_linux_deps.py, also from a worktree.
@(private)
linux_deps :: proc(engine_root:string) -> string {
    return strings.concatenate({workspace.deps_folder(engine_root,context.temp_allocator),"/",LINUX_DEPS},context.temp_allocator)
}

// The SDL3 the engine links, as a package of the engine carries it: its
// install folder relative to the deps of the engine, the one of
// scripts/setup_linux_deps.py or of scripts/setup_macos_deps.py. "" on
// Windows, where it comes with the compiler, and on macOS with Homebrew's,
// which a package cannot carry: its id names its folder.
sdl_deps_folder :: proc(engine_root:string) -> string {
    when ODIN_OS==.Linux {
        if os.is_file(strings.concatenate({linux_deps(engine_root),"/sdl3/lib/libSDL3.so.0"},context.temp_allocator)) {return LINUX_DEPS+"/sdl3"}
    } else when ODIN_OS==.Darwin {
        if _,relocatable:=macos_sdl(engine_root);relocatable {return MACOS_DEPS+"/sdl3"}
    }
    return ""
}

// The folder of the SDL3 of scripts/setup_macos_deps.py, whose id is under
// @rpath: what links it finds it next to itself, so a package of the engine
// and a shipped game do without Homebrew. Without it, Homebrew's.
@(private)
macos_sdl :: proc(engine_root:string) -> (folder:string,relocatable:bool) {
    deps:=strings.concatenate({workspace.deps_folder(engine_root,context.temp_allocator),"/",MACOS_DEPS,"/sdl3/lib"},context.temp_allocator)
    if os.is_file(strings.concatenate({deps,"/",MACOS_SDL},context.temp_allocator)) {return deps,true}
    return HOMEBREW_LIB,false
}

@(private)
macos_minimum_version :: proc(otool_output:string) -> (version:string,found:bool) {
    command:=""
    rest:=otool_output
    for line in strings.split_lines_iterator(&rest) {
        fields:=strings.fields(line,context.temp_allocator)
        if len(fields)<2 {continue}
        if fields[0]=="cmd" {command=fields[1];continue}
        if (command=="LC_BUILD_VERSION" && fields[0]=="minos") || (command=="LC_VERSION_MIN_MACOSX" && fields[0]=="version") {
            major:=0
            for character in fields[1] {
                if character<'0' || character>'9' {break}
                major=major*10+int(character-'0')
            }
            return major>=13?fields[1]:"13.0",true
        }
    }
    return "",false
}
