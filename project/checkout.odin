package project

import "base:runtime"
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

// The collections of the compressor: compressor is what the engine imports, the private one
// where a checkout holds a clone of it (git ignores ext/), in ext/ of its own or of its main
// checkout, and the open one otherwise; compressor_open is always the open one, which the private
// one delegates the open formats to.
COMPRESSOR_PRIVATE :: "ext/mirai-compression"
COMPRESSOR_OPEN :: "std/compressor"

// The folder of the collection compressor of a build of the engine at engine_root.
compressor_folder :: proc(engine_root:string,allocator:=context.allocator) -> (folder:string,private:bool) {
    own:=path(engine_root,COMPRESSOR_PRIVATE,allocator=context.temp_allocator)
    if os.is_dir(own) {return forward_slashes(own,allocator),true}
    shared:=path(shared_root(engine_root,context.temp_allocator),COMPRESSOR_PRIVATE,allocator=context.temp_allocator)
    if os.is_dir(shared) {return forward_slashes(shared,allocator),true}
    return forward_slashes(path(engine_root,COMPRESSOR_OPEN,allocator=context.temp_allocator),allocator),false
}

// The flags of the compiler that name the collections of the compressor.
compressor_flags :: proc(engine_root:string,allocator:=context.allocator) -> (flags:[2]string,error:runtime.Allocator_Error) {
    folder,_:=compressor_folder(engine_root,context.temp_allocator)
    open:=forward_slashes(path(engine_root,COMPRESSOR_OPEN,allocator=context.temp_allocator),context.temp_allocator)
    flags[0]=strings.concatenate({"-collection:compressor=",folder},allocator) or_return
    flags[1]=strings.concatenate({"-collection:compressor_open=",open},allocator) or_return
    return
}

// A cache of what imports build, kept by content (TEXTURE_CACHE, MESH_CACHE):
// what a file of it holds depends on what it was made from and on no project,
// so every project of a checkout shares it, and so do the worktrees of the
// repository: <main>/.mirai/cache/<name>, where main is the main checkout of
// the repository root is in. A project outside any repository keeps its own.
content_cache_path :: proc(root,name:string,allocator:=context.allocator) -> string {
    folder:=path_absolute(root,context.temp_allocator)
    for at:=folder;at!="";at=os.dir(at) {
        if os.exists(path(at,".git",allocator=context.temp_allocator)) {
            return cache_path(shared_root(at,context.temp_allocator),name,allocator=allocator)
        }
        if os.dir(at)==at {break}
    }
    return cache_path(root,name,allocator=allocator)
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
