package main

import "core:fmt"
import "core:path/filepath"
import "mirai:project"

// mirai setup path: the bin/ folder of this engine in the PATH of the user,
// in place of the one of another copy. Once per copy: a build replaces
// bin/mirai in the same folder.
setup_path :: proc(root:string) -> int {
    absolute,error:=filepath.abs(root,context.temp_allocator)
    if error!=nil {fmt.eprintln("mirai setup path: could not resolve",root);return 1}
    message,ok:=path_add(join(absolute,"bin"),.Bin)
    if !ok {fmt.eprintln(message);return 1}
    fmt.println(message)
    return 0
}

// What the engine puts in the PATH of the user: one of each, the one of this
// copy in place of that of another.
Path_Entry :: enum {Bin,Ripgrep}

// Whether a folder of the PATH is an entry of kind of some copy of the engine.
path_entry_is :: proc(entry:string,kind:Path_Entry) -> bool {
    parent:=filepath.dir(entry)
    switch kind {
    case .Bin:     return project.path_same(filepath.base(entry),"bin") && project.engine_root_is(parent)
    case .Ripgrep: return project.path_same(filepath.base(entry),"ripgrep") && project.path_same(filepath.base(parent),".deps")
    }
    return false
}

