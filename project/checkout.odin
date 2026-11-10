package project

import "core:os"
import "core:strings"

// The checkouts of one repository of the engine are one engine on this
// machine. Its main checkout keeps what belongs to the machine: the file of
// the engine layer of the settings, the preferences of the editor, and the
// dependencies and caches of cook/workspace. A git worktree reaches them
// through the repository it belongs to; a checkout that is not a worktree
// keeps its own.

// The main checkout of the repository root belongs to, with forward slashes:
// root itself unless root is a git worktree, whose .git file names the
// repository.
shared_root :: proc(root:string,allocator:=context.allocator) -> string {
    own:=forward_slashes(root,allocator)
    data,error:=os.read_entire_file(path(root,".git",allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return own}
    text:=strings.trim_space(string(data))
    if !strings.has_prefix(text,"gitdir:") {return own}
    gitdir:=strings.trim_space(text[len("gitdir:"):])
    if !os.is_absolute_path(gitdir) {gitdir=path(root,gitdir,allocator=context.temp_allocator)}
    common:=gitdir
    if named,named_error:=os.read_entire_file(path(gitdir,"commondir",allocator=context.temp_allocator),context.temp_allocator);named_error==nil {
        relative:=strings.trim_space(string(named))
        common=os.is_absolute_path(relative)?relative:path(gitdir,relative,allocator=context.temp_allocator)
    }
    common,_=os.clean_path(common,context.temp_allocator)
    // A bare repository has no main checkout.
    if os.base(common)!=".git" {return own}
    main:=os.dir(common)
    if !os.is_dir(main) {return own}
    delete(own,allocator)
    return forward_slashes(main,allocator)
}

// The folder of the files of the engine on this machine: the .mirai of its
// main checkout. "" when the engine is not known.
machine_folder :: proc(engine_root:string,allocator:=context.allocator) -> string {
    if engine_root=="" {return ""}
    return folder_path(shared_root(engine_root,context.temp_allocator),.Generated,allocator)
}

@(private="file")
forward_slashes :: proc(text:string,allocator:=context.allocator) -> string {
    result,error:=strings.clone(text,allocator)
    if error!=nil {return ""}
    for &c in transmute([]u8)result {
        if c=='\\' {c='/'}
    }
    return result
}

// The folder of the agents of the editor for the user of this machine,
// outside every checkout, build and project: the adapters Mirai installs and
// what it knows of the agents of the user, which an update, a rebuild or
// another worktree keep. "" without a folder of user data.
AGENTS_FOLDER :: "Editor agents"
agents_folder :: proc(allocator:=context.allocator) -> string {
    data,error:=os.user_data_dir(context.temp_allocator)
    if error!=nil {return ""}
    folder:=forward_slashes(path(data,"Mirai",AGENTS_FOLDER,allocator=context.temp_allocator),allocator)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {
        delete(folder,allocator)
        return ""
    }
    return folder
}
