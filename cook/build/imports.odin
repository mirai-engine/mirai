package build

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:project"
import "mirai:std/subprocess"

// Brings the packages each root (a project, a plugin) pins in its
// packages.mirai to builds this engine reads (cook/import/sources.project_refresh)
// in the store at store_root ("": the machine's), with the import program of
// the engine (Engine_Paths.import_program, of the defines the engine was
// built with), which reads the formats the plugins of the project add from
// the library of its editor: the tool builds without the importers. A build
// is taken from the store, then from the store at from ("": none; an
// installed engine adds the store of the builds of its plugins), then built
// from its source when the source is on this machine; a package none of them
// gives fails by name. Textures are required Final for a build that cooks
// them (final) and taken Fast, as the editor imports them, for one that does
// not. What the program says of each source it imports goes to the output
// of this process as it says it: a large source imports for minutes.
// message, in the temp allocator: why it failed, with the source and the
// reason the program gave, or, when it ended without saying (a crash, a
// signal), how it ended and the source it was importing.
imports_refresh :: proc(program:string,roots:[]string,final:bool,store_root:string,from:="") -> (ok:bool,message:string) {
    if len(roots)==0 {return true,""}
    refresh:Import_Refresh
    command:=imports_command(program,roots,final,store_root,from)
    if error:=imports_start(&refresh,command,context.temp_allocator);error!=nil {
        return false,fmt.tprintf("the import program could not run: %v",error)
    }
    defer subprocess.release(&refresh.process)
    for {
        if done,ok,message:=imports_poll(&refresh,true);done {return ok,message}
    }
}

@(private)
Import_Refresh :: struct {
    process:subprocess.Process,
    output:[subprocess.Stream][dynamic]byte,
}

@(private)
imports_command :: proc(program:string,roots:[]string,final:bool,store_root:string,from:="") -> []string {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,program)
    if final {append(&command,"--final")}
    if store_root!="" {append(&command,"--store",store_root)}
    if from!="" {append(&command,"--from",from)}
    for root in roots {append(&command,"--refresh",root)}
    return command[:]
}

@(private)
imports_start :: proc(refresh:^Import_Refresh,command:[]string,allocator:runtime.Allocator) -> os.Error {
    refresh.process=subprocess.start({command=command},pipes=.Separate) or_return
    subprocess.stdin_close(&refresh.process)
    for &text in refresh.output {text=make([dynamic]byte,allocator)}
    return nil
}

@(private)
imports_poll :: proc(refresh:^Import_Refresh,wait:bool) -> (done,ok:bool,message:string) {
    buffer:[4096]byte
    quiet:=true
    for stream in subprocess.Stream {
        count,_:=subprocess.read(&refresh.process,stream,buffer[:])
        if count==0 {continue}
        quiet=false
        if _,error:=append(&refresh.output[stream],..buffer[:count]);error!=nil {
            return true,false,"there is not enough memory for the import program's output"
        }
        if stream==.Stdout {_,_=os.write(os.stdout,buffer[:count])}
    }
    state,error:=subprocess.wait(&refresh.process,0)
    if error!=nil && error!=os.General_Error.Timeout {
        return true,false,fmt.tprintf("the import program could not be waited for: %v",error)
    }
    if state.exited && refresh.process.stdout==nil && refresh.process.stderr==nil {
        if state.exit_code==0 && state.success {return true,true,""}
        return true,false,imports_failure(state,string(refresh.output[.Stdout][:]),string(refresh.output[.Stderr][:]))
    }
    if wait && quiet {time.sleep(time.Millisecond)}
    return false,false,""
}

// Why the import program failed: what it said on its error output, else how
// it ended and the last source it said it was importing.
@(private)
imports_failure :: proc(state:os.Process_State,said,errors:string) -> string {
    if text:=strings.trim_space(errors);text!="" {return text}
    ended:=fmt.tprintf("the import program ended with exit code %d",state.exit_code)
    if !state.success {ended=fmt.tprintf("the import program crashed or was killed (code %d)",state.exit_code)}
    lines:=strings.split_lines(said,context.temp_allocator)
    #reverse for line in lines {
        if strings.has_prefix(line,"importing ") {return fmt.tprintf("%s while %s, without saying why: run the import again (mirai import --refresh) to see it",ended,line)}
    }
    return fmt.tprintf("%s before importing any source, without saying why: run the import again (mirai import --refresh) to see it",ended)
}

// The roots of a project whose packages its builds refresh: the project and
// its active plugins, those with a packages.mirai. In the temp allocator.
imports_roots :: proc(p:^project.Project) -> []string {
    roots:=make([dynamic]string,context.temp_allocator)
    for folder in project.asset_folders(p,context.temp_allocator) {
        if os.is_file(project.path(folder.root,asset.PACKAGES_FILE,allocator=context.temp_allocator)) {append(&roots,folder.root)}
    }
    return roots[:]
}
