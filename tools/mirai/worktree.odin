package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:project"

WORKTREE_USAGE :: "worktree new <name> [--from <branch or commit>] [--branch <branch>]"

// mirai worktree new <name>: a git worktree in <main>/.worktrees/<name>,
// on a new branch (the name, or --branch) from --from (the HEAD of this
// checkout by default). It needs nothing copied: .deps comes from the main
// checkout, and the C libraries, the stages of the shaders and the binaries
// of the engine from the caches every checkout shares (workspace), by the
// sources they are built from. Its shader tables are generated here. What
// git ignores and every checkout compiles comes with worktree_files_copy.
cmd_worktree :: proc(root:string,args:[]string) -> int {
    if len(args)<2 || args[0]!="new" {fmt.eprintfln("Usage: mirai %s",WORKTREE_USAGE);return 2}
    if !positional(args[1]) {return argument_unknown("worktree",args[1])}
    name,from,branch:=args[1],"HEAD",args[1]
    for i:=2;i<len(args);i+=1 {
        switch {
        case args[i]=="--from" && i+1<len(args):   i+=1;from=args[i]
        case args[i]=="--branch" && i+1<len(args): i+=1;branch=args[i]
        case: return argument_unknown("worktree",args[i])
        }
    }
    for c in name {
        if !(c>='a' && c<='z' || c>='0' && c<='9' || c=='-' || c=='_' || c=='.') {
            fmt.eprintfln("mirai worktree: '%s' is not a valid folder name: lowercase letters, digits, '-', '_' and '.'",name)
            return 2
        }
    }
    shared:=project.shared_root(root,context.temp_allocator)
    folder:=join(shared,".worktrees",name)
    if os.exists(folder) {fmt.eprintfln("mirai worktree: %s already exists; choose another name or `git worktree remove` the old one",folder);return 1}
    if code:=run(root,{"git","worktree","add","-b",branch,folder,from});code!=0 {
        fmt.eprintfln("mirai worktree: git did not create the worktree; if the branch %s already exists, pass another one with --branch",branch)
        return code
    }
    worktree_files_copy(shared,folder)
    if !ensure_runtime_dependencies(folder) {fmt.eprintln("mirai worktree: the C libraries will be built on the first build (mirai deps shows why not now)")}
    // The tool of the worktree builds render, which embeds the shader tables
    // git does not keep: this tool generates them so that it can build.
    if !engine_shaders(folder) {fmt.eprintfln("mirai worktree: generate them with MIRAI_ROOT=%s and this tool's `shaders` before building",folder)}
    slashed,_:=strings.replace_all(folder,"\\","/",context.temp_allocator)
    fmt.printfln("Worktree %s on the branch %s.",slashed,branch)
    fmt.printfln("  cd \"%s\"; ./mirai build engine",slashed)
    return 0
}

// Copies into the checkout folder the folders .mirai/worktree-files of the main checkout lists, one
// per line: code git ignores that every checkout compiles. A folder the commit of that checkout
// still tracks stays as it is.
worktree_files_copy :: proc(shared,folder:string) {
    list,error:=os.read_entire_file(join(shared,".mirai","worktree-files"),context.temp_allocator)
    if error!=nil {return}
    text:=string(list)
    for line in strings.split_lines_iterator(&text) {
        name:=strings.trim_space(line)
        if name=="" {continue}
        if _,ignored:=render_git(folder,"check-ignore","-q",fmt.tprintf("%s/worktree-files-probe",name));!ignored {continue}
        if os.copy_directory_all(join(folder,name),join(shared,name))!=nil {fmt.eprintfln("mirai worktree: %s could not be copied from %s",name,shared)}
    }
}
