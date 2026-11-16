package build

import "core:fmt"
import "core:strings"
import "mirai:project"

// What a project is built into. The editor is the library with the world of
// the editor, built against the declarations of the engine's binaries, which
// the editor and the player load (the player runs only its game); the game is
// the program that ships, built whole from the sources with the engine, which
// never sees an engine-time package.
Target :: enum u8 {
    Editor,
    Game,
}

@(private)
TARGET_NAMES :: [Target]string{.Editor="editor",.Game="game"}

// <project>/.mirai/gen: the generated packages, the collection "generated".
generated_root :: proc(root:string,allocator:=context.allocator) -> string {
    return project.path(project.folder_path(root,.Generated,context.temp_allocator),"gen",allocator=allocator)
}

// <project>/.mirai/gen/<target>: the main package the compiler is given.
generated_folder :: proc(root:string,target:Target,allocator:=context.allocator) -> string {
    names:=TARGET_NAMES
    return project.path(generated_root(root,context.temp_allocator),names[target],allocator=allocator)
}

// What the project generates for a target: its world and its main. Two
// projects that generate the same text build the same program.
generate :: proc(p:^project.Project,target:Target,allocator:=context.allocator) -> string {
    out:=world_generate(p,context.temp_allocator,target==.Game)
    if len(out.errors)>0 {return strings.join(out.errors,"\n",allocator)}
    switch target {
    case .Editor: return strings.concatenate({out.editor_world,out.editor_main},allocator)
    case .Game:   return strings.concatenate({out.shipped_world,out.game_main},allocator)
    }
    return ""
}

// Writes the generated packages. The errors of out are those of the attributes of the project's packages.
generated_write :: proc(p:^project.Project,target:Target) -> (out:Generated,ok:bool) {
    return world_write_files(p,target==.Game)
}

// The flags every compilation of a project's generated code needs.
generated_flags :: proc(root:string,allocator:=context.allocator) -> [2]string {
    return {fmt.aprintf("-collection:generated=%s",generated_root(root,context.temp_allocator),allocator=allocator),fmt.aprintf("-custom-attribute:%s",CUSTOM_ATTRIBUTES,allocator=allocator)}
}
