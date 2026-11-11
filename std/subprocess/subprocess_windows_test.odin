#+build windows
package subprocess

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import win "core:sys/windows"

// "console": how the console of this process looks. "orphan start|detached
// <log>": from a process without a console, starts "console" and passes on
// what it says.
probe_windows :: proc(args:[]string) -> int {
    switch args[0] {
    case "console":
        window:=win.GetConsoleWindow()
        list:[64]win.DWORD
        count:=int(GetConsoleProcessList(&list[0],len(list)))
        shares:=false
        for pid in list[:min(count,len(list))] {
            if int(pid)==os.get_ppid() {shares=true}
        }
        visible:=window!=nil && bool(win.IsWindowVisible(window))
        fmt.printf("console=%d window=%d visible=%d shares=%d\n",int(count>0),int(window!=nil),int(visible),int(shares))
        return 0
    case "orphan":
        fmt.printf("orphan console=%d\n",int(has_console()))
        command:=probe_command("console")
        if args[1]=="start" {
            state,stdout,stderr,error:=exec({command=command},context.temp_allocator)
            if error!=nil || state.exit_code!=0 {fmt.printf("exec failed: %v %s\n",error,stderr);return 1}
            os.write(os.stdout,stdout)
            return 0
        }
        log,open_error:=os.open(args[2],{.Write,.Create,.Trunc})
        if open_error!=nil {fmt.printf("open failed: %v\n",open_error);return 1}
        process,error:=detached({command=command,stdout=log,stderr=log})
        os.close(log)
        if error!=nil {fmt.printf("detached failed: %v\n",error);return 1}
        _,_=wait(&process)
        written,_:=os.read_entire_file(args[2],context.temp_allocator)
        os.write(os.stdout,written)
        return 0
    }
    return 2
}

// What a child started by this process without a console says.
@(private="file")
orphan_report :: proc(t:^testing.T,kind:string) -> string {
    log:=strings.concatenate({probe_program(),".orphan.log"},context.temp_allocator)
    defer os.remove(log)
    reader,writer,pipe_error:=os.pipe()
    if pipe_error!=nil {testing.fail_now(t,"no pipe")}
    defer os.close(reader)
    streams:=[3]win.HANDLE{nil,file_handle(writer),file_handle(writer)}
    process,error:=create(probe_command("orphan",kind,log),nil,"",streams,win.DETACHED_PROCESS)
    os.close(writer)
    if error!=nil {testing.fail_now(t,fmt.tprintf("the orphan could not start: %v",error))}
    said:=make([dynamic]u8,context.temp_allocator)
    buffer:[512]u8
    for {
        count,read_error:=os.read(reader,buffer[:])
        append(&said,..buffer[:max(count,0)])
        if read_error!=nil || count<=0 {break}
    }
    _,_=wait(&process)
    return string(said[:])
}

@(test)
a_child_of_a_process_without_console_opens_no_window :: proc(t:^testing.T) {
    said:=orphan_report(t,"start")
    testing.expectf(t,strings.contains(said,"orphan console=0"),"the orphan had a console: %q",said)
    testing.expectf(t,strings.contains(said,"console=1 window=0 visible=0"),"%q",said)
}

@(test)
a_detached_child_of_a_process_without_console_opens_no_window :: proc(t:^testing.T) {
    said:=orphan_report(t,"detached")
    testing.expectf(t,strings.contains(said,"orphan console=0"),"the orphan had a console: %q",said)
    testing.expectf(t,strings.contains(said,"console=1 window=0 visible=0"),"%q",said)
}

// Its own console, so that closing the one of this process does not end it.
@(test)
a_detached_child_has_a_console_without_window_of_its_own :: proc(t:^testing.T) {
    log:=strings.concatenate({probe_program(),".own.log"},context.temp_allocator)
    defer os.remove(log)
    file,open_error:=os.open(log,{.Write,.Create,.Trunc})
    if open_error!=nil {testing.fail_now(t,fmt.tprintf("open: %v",open_error))}
    process,error:=detached({command=probe_command("console"),stdout=file,stderr=file})
    os.close(file)
    if error!=nil {testing.fail_now(t,fmt.tprintf("detached: %v",error))}
    _,_=wait(&process)
    said,_:=os.read_entire_file(log,context.temp_allocator)
    testing.expect_value(t,string(said),"console=1 window=0 visible=0 shares=0\n")
}

@(test)
a_child_shares_the_console_of_its_parent :: proc(t:^testing.T) {
    if !has_console() {return}
    _,stdout,_,error:=exec({command=probe_command("console")},context.temp_allocator)
    testing.expectf(t,error==nil,"exec: %v",error)
    testing.expectf(t,strings.contains(string(stdout),"shares=1"),"%q",string(stdout))
}

@(test)
the_command_line_quotes_only_what_needs_it :: proc(t:^testing.T) {
    line:=command_line({`C:\Program Files\x.exe`,"plain","",`a"b`,`end\`,`c:\dir\`},context.temp_allocator)
    testing.expect_value(t,line,`"C:\Program Files\x.exe" plain "" "a\"b" end\ c:\dir\`)
}
