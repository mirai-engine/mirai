package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The shell that runs the scripts of the repository: Git Bash on Windows, looked for where
// mirai.cmd looks (the bash of the PATH is usually the one of WSL, which has no odin), sh
// elsewhere. path is the first place looked when it is in none.
shell_executable :: proc() -> (path:string,found:bool) {
    when ODIN_OS==.Windows {
        env :: proc(name:string) -> string {value,_:=os.lookup_env(name,context.temp_allocator);return value}
        git,_:=path_find("git")
        return git_bash_find({env("ProgramFiles"),env("ProgramFiles(x86)"),env("LocalAppData")},env("GIT_INSTALL_ROOT"),git)
    } else {
        return "sh",true
    }
}

// bin/bash.exe of Git for Windows: under Git of each of program_folders (ProgramFiles,
// ProgramFiles(x86), then Programs/Git of LocalAppData), under install_root, or under the root
// of git, the git.exe of PATH, which is in <root>/cmd or <root>/mingw64/bin. Empty folders are
// skipped. path is the first place looked when it is in none.
git_bash_find :: proc(program_folders:[3]string,install_root,git:string) -> (path:string,found:bool) {
    roots:=make([dynamic]string,context.temp_allocator)
    for folder,i in program_folders {
        if folder=="" {continue}
        append(&roots,join(folder,"Programs","Git") if i==2 else join(folder,"Git"))
    }
    if install_root!="" {append(&roots,install_root)}
    if git!="" {
        folder:=filepath.dir(git)
        append(&roots,filepath.dir(folder),filepath.dir(filepath.dir(folder)))
    }
    for root in roots {
        if bash:=join(root,"bin","bash.exe");os.is_file(bash) {return bash,true}
    }
    if len(roots)>0 {return join(roots[0],"bin","bash.exe"),false}
    return "bash.exe",false
}

// command with the script it starts run by shell_executable, where the system cannot start one
// itself: on Windows, a file named with a path that begins with #! (./mirai).
// ok is false, after saying why, when the script needs a shell that is not there.
script_command :: proc(command:[]string) -> (resolved:[]string,ok:bool) {
    when ODIN_OS==.Windows {
        if len(command)==0 || !strings.contains_any(command[0],"/\\") || !shebang(command[0]) {return command,true}
        shell,found:=shell_executable()
        if !found {
            fmt.eprintfln("mirai: %s is an sh script and Git Bash is missing in %s; install Git for Windows",command[0],shell)
            return nil,false
        }
        list:=make([dynamic]string,0,len(command)+1)
        slashed,_:=strings.replace_all(command[0],"\\","/")
        append(&list,shell,slashed)
        append(&list,..command[1:])
        return list[:],true
    } else {
        return command,true
    }
}

// Whether the file begins with #!.
shebang :: proc(path:string) -> bool {
    file,error:=os.open(path)
    if error!=nil {return false}
    defer os.close(file)
    head:[2]u8
    count,_:=os.read(file,head[:])
    return count==2 && head=={'#','!'}
}
