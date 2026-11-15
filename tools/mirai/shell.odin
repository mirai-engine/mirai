package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:std/subprocess"

// The shell that runs the scripts of the repository: Git Bash on Windows, found as mirai.cmd finds
// it, through git --exec-path (the bash of the PATH is usually the one of WSL, which has no odin);
// sh elsewhere.
shell_executable :: proc() -> (path:string,found:bool) {
    when ODIN_OS==.Windows {
        state,exec,_,error:=subprocess.exec({command={"git","--exec-path"}},context.allocator)
        if error!=nil || state.exit_code!=0 {return "git --exec-path",false}
        bash:=git_bash(strings.trim_space(string(exec)))
        return bash,os.is_file(bash)
    } else {
        return "sh",true
    }
}

// The bash of the Git for Windows whose git --exec-path is exec: <root>/mingw64/libexec/git-core.
git_bash :: proc(exec:string) -> string {return join(exec,"..","..","..","bin","bash.exe")}

// command with the script it starts run by shell_executable, where the system cannot start one
// itself: on Windows, a file named with a path that begins with #! (./mirai).
// ok is false, after saying why, when the script needs a shell that is not there.
script_command :: proc(command:[]string) -> (resolved:[]string,ok:bool) {
    when ODIN_OS==.Windows {
        if len(command)==0 || !strings.contains_any(command[0],"/\\") || !shebang(command[0]) {return command,true}
        shell,found:=shell_executable()
        if !found {
            fmt.eprintfln("mirai: %s is an sh script and no Git Bash was found by %s; install Git for Windows with git on the PATH",command[0],shell)
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
