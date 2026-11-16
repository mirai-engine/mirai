package project

import "core:os"

// The shader generation of a project: the engine's shaders compiled with the
// Slang programs of the project and of its active plugins. A build leaves it
// under .mirai, and a shipped game carries it next to its executable.

SHADERS_BUILT :: "shaders"   // inside the generated folder
SHADERS_SHIPPED :: "shaders" // inside the folder of a shipped game
SHADERS_MANIFEST :: "manifest.json"

// Where a build of the project publishes its generation, built or not.
shader_generation :: proc(root:string,allocator:=context.allocator) -> string {
    return path(folder_path(root,.Generated,context.temp_allocator),SHADERS_BUILT,allocator=allocator)
}

// The generation a run of the project at root loads: the one a build left,
// or the one a shipped game has. Empty when neither has a manifest.
shader_generation_find :: proc(root:string,allocator:=context.allocator) -> string {
    built:=shader_generation(root,context.temp_allocator)
    if os.is_file(path(built,SHADERS_MANIFEST,allocator=context.temp_allocator)) {return path(built,allocator=allocator)}
    shipped:=path(root,SHADERS_SHIPPED,allocator=context.temp_allocator)
    if os.is_file(path(shipped,SHADERS_MANIFEST,allocator=context.temp_allocator)) {return path(shipped,allocator=allocator)}
    return ""
}
