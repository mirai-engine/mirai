package project

import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:std/serial"

// An engine is a checkout of its repository, which builds its binaries from
// its sources, or an installed engine: the folder `mirai package engine`
// makes, with its binaries already built and ENGINE_FILE at its root. An
// installed engine builds projects and never itself.

ENGINE_FILE :: "engine.mirai"

// What a package of the engine is made for, as its archives are named.
ENGINE_PLATFORM :: ("macos" when ODIN_OS==.Darwin else ODIN_OS_STRING)+"-"+ODIN_ARCH_STRING

// What an installed engine says of itself; written when it is packaged.
Engine_Manifest :: struct {
    version:Version `mirai:"text"`, // ENGINE_VERSION of its sources
    commit:Name `mirai:"text"`,     // of the repository it was built from
    platform:Name `mirai:"text"`,   // ENGINE_PLATFORM of the machine that built it
    odin:Name `mirai:"text"`,       // the release of the compiler under its .deps
    slang:Version `mirai:"text"`,   // of the shader compiler under its .deps
}

// Whether root is an installed engine.
engine_installed :: proc(root:string) -> bool {
    return root!="" && os.is_file(path(root,ENGINE_FILE,allocator=context.temp_allocator))
}

// Whether folder is the root of an engine: an installed one, or a checkout
// with its sources and the sources of its tool.
engine_root_is :: proc(folder:string) -> bool {
    if folder=="" {return false}
    if engine_installed(folder) {return true}
    return os.is_file(path(folder,"AGENTS.md",allocator=context.temp_allocator)) && os.is_dir(path(folder,"tools/mirai",allocator=context.temp_allocator))
}

// The root of the engine a program belongs to: the one given, MIRAI_ROOT,
// or the nearest folder above the executable or the working directory that
// is one. Absolute, with forward slashes; "" when there is none.
engine_root_find :: proc(given:string,allocator:=context.allocator) -> string {
    if engine_root_is(given) {return path_absolute(given,allocator)}
    if value,found:=os.lookup_env("MIRAI_ROOT",context.temp_allocator);found && engine_root_is(value) {return path_absolute(value,allocator)}
    starts:[2]string
    starts[0],_=os.get_executable_directory(context.temp_allocator)
    starts[1],_=os.get_working_directory(context.temp_allocator)
    for start in starts {
        folder:=start
        for folder!="" {
            if engine_root_is(folder) {return path_absolute(folder,allocator)}
            parent:=filepath.dir(folder)
            if parent==folder || parent=="" || parent=="." || len(parent)>=len(folder) {break}
            folder=parent
        }
    }
    return ""
}

// The mirai tool of an engine: what the editor runs for its agents and installers.
tool_file :: proc(engine_root:string,allocator:=context.allocator) -> string {
    return path(engine_root,"bin",strings.concatenate({"mirai",".exe" when ODIN_OS==.Windows else ""},context.temp_allocator),allocator=allocator)
}

engine_manifest_parse :: proc(text:string) -> (m:Engine_Manifest,error:Error) {
    error=value_parse(text,&m,Engine_Manifest)
    return
}

// The manifest of the installed engine at root.
engine_manifest_read :: proc(root:string) -> (m:Engine_Manifest,error:Error) {
    data,file_error:=serial.file_read(path(root,ENGINE_FILE,allocator=context.temp_allocator),context.temp_allocator)
    if file_error!=.None {return {},{code=file_error==.Not_Found?.Not_Found:.Read_Failed}}
    return engine_manifest_parse(string(data))
}

engine_manifest_text :: proc(m:^Engine_Manifest,allocator:=context.allocator) -> string {return value_text(m,Engine_Manifest,allocator)}

engine_manifest_write :: proc(root:string,m:^Engine_Manifest) -> Error {
    text:=engine_manifest_text(m,context.temp_allocator)
    if text=="" {return schema_failed(Engine_Manifest)}
    return {code=serial.file_write_atomic(path(root,ENGINE_FILE,allocator=context.temp_allocator),transmute([]u8)text)==.None?.None:.Write_Failed}
}
