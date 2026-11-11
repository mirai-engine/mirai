#+build windows
#+private
package subprocess

import "core:os"
import "core:strings"
import win "core:sys/windows"

// core:sys/windows does not declare these.
foreign import kernel32 "system:Kernel32.lib"

Attribute_List :: distinct rawptr

@(default_calling_convention="system")
foreign kernel32 {
    InitializeProcThreadAttributeList :: proc(list:Attribute_List,count,flags:win.DWORD,size:^win.SIZE_T) -> win.BOOL ---
    UpdateProcThreadAttribute :: proc(list:Attribute_List,flags:win.DWORD,attribute:win.DWORD_PTR,value:rawptr,size:win.SIZE_T,previous:rawptr,returned:^win.SIZE_T) -> win.BOOL ---
    DeleteProcThreadAttributeList :: proc(list:Attribute_List) ---
    GetConsoleProcessList :: proc(list:^win.DWORD,count:win.DWORD) -> win.DWORD ---
    CreateJobObjectW :: proc(attributes:rawptr,name:win.LPCWSTR) -> win.HANDLE ---
    SetInformationJobObject :: proc(job:win.HANDLE,class:i32,information:rawptr,size:win.DWORD) -> win.BOOL ---
    AssignProcessToJobObject :: proc(job,process:win.HANDLE) -> win.BOOL ---
    GetPriorityClass :: proc(process:win.HANDLE) -> win.DWORD ---
    TerminateJobObject :: proc(job:win.HANDLE,exit_code:win.UINT) -> win.BOOL ---
    SetNamedPipeHandleState :: proc(pipe:win.HANDLE,mode,collection_count,collect_timeout:^win.DWORD) -> win.BOOL ---
}

// How high this process runs, comparable between processes: higher runs first.
priority_rank :: proc() -> int {
    switch GetPriorityClass(win.GetCurrentProcess()) {
    case win.IDLE_PRIORITY_CLASS:         return 1
    case win.BELOW_NORMAL_PRIORITY_CLASS: return 2
    case win.NORMAL_PRIORITY_CLASS:       return 3
    case win.ABOVE_NORMAL_PRIORITY_CLASS: return 4
    case win.HIGH_PRIORITY_CLASS:         return 5
    }
    return 6
}

JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS :: 9
JOB_OBJECT_LIMIT_PROCESS_MEMORY :: 0x00000100
JOB_OBJECT_LIMIT_BREAKAWAY_OK :: 0x00000800
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x00002000
PIPE_NOWAIT :: 0x00000001

JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
    PerProcessUserTimeLimit,PerJobUserTimeLimit:i64,
    LimitFlags:win.DWORD,
    MinimumWorkingSetSize,MaximumWorkingSetSize:uint,
    ActiveProcessLimit:win.DWORD,
    Affinity:uint,
    PriorityClass,SchedulingClass:win.DWORD,
    IoInfo:[6]u64,
    ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed:uint,
}

PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x20002

STARTUPINFOEXW :: struct {
    StartupInfo:win.STARTUPINFOW,
    lpAttributeList:Attribute_List,
}

_start :: proc(desc:os.Process_Desc,limits:Limits) -> (process:Process,error:os.Error) {
    flags:win.DWORD=0 if has_console() else win.CREATE_NO_WINDOW
    if limits.priority==.Low {flags|=win.BELOW_NORMAL_PRIORITY_CLASS}
    job:=CreateJobObjectW(nil,nil)
    if job==nil {return {},last_error()}
    // Breakaway lets a detached grandchild leave the tree, as detached does here.
    information:JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    information.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE|JOB_OBJECT_LIMIT_BREAKAWAY_OK
    if limits.memory>0 {
        information.LimitFlags|=JOB_OBJECT_LIMIT_PROCESS_MEMORY
        information.ProcessMemoryLimit=uint(limits.memory)
    }
    if !SetInformationJobObject(job,JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,&information,size_of(information)) {
        error=last_error()
        win.CloseHandle(job)
        return
    }
    process,error=create(desc.command,desc.env,desc.working_dir,{file_handle(desc.stdin),file_handle(desc.stdout),file_handle(desc.stderr)},flags,job)
    if error!=nil {win.CloseHandle(job);return}
    process.tree=uintptr(job)
    return
}

_detached :: proc(desc:os.Process_Desc) -> (process:Process,error:os.Error) {
    // A console of its own: closing the one of the caller, or Ctrl+C in it, does not end it.
    flags:win.DWORD=win.CREATE_NO_WINDOW
    streams:=[3]win.HANDLE{file_handle(desc.stdin),file_handle(desc.stdout),file_handle(desc.stderr)}
    process,error=create(desc.command,desc.env,desc.working_dir,streams,flags|win.CREATE_BREAKAWAY_FROM_JOB)
    if error!=nil {process,error=create(desc.command,desc.env,desc.working_dir,streams,flags)}
    return
}

_terminate :: proc(process:^Process,force:bool) -> os.Error {
    if process.tree==0 {return os.process_kill({pid=process.pid,handle=process.handle})}
    if !TerminateJobObject(win.HANDLE(process.tree),1) {return last_error()}
    return nil
}

// The job kills what is still in it as its handle closes.
_tree_close :: proc(process:^Process) {
    if process.tree!=0 {win.CloseHandle(win.HANDLE(process.tree))}
    process.tree=0
}

// A write that does not fit returns at once, taking nothing.
_stdin_nonblocking :: proc(file:^os.File) {
    mode:win.DWORD=PIPE_NOWAIT
    _=SetNamedPipeHandleState(file_handle(file),&mode,nil,nil)
}

has_console :: proc() -> bool {
    first:win.DWORD
    return GetConsoleProcessList(&first,1)!=0
}

file_handle :: proc(file:^os.File) -> win.HANDLE {
    return file==nil?nil:win.HANDLE(os.fd(file))
}

// Starts command with streams (stdin, stdout, stderr; nil is the null
// device) as the only handles it inherits. env nil is the environment of this
// process. With a job, the child joins it before it runs.
create :: proc(command,env:[]string,working_dir:string,streams:[3]win.HANDLE,flags:win.DWORD,job:win.HANDLE=nil) -> (process:Process,error:os.Error) {
    scratch:=context.temp_allocator
    line:=win.utf8_to_wstring(command_line(command,scratch),scratch)
    folder:=win.utf8_to_wstring(working_dir,scratch) if working_dir!="" else nil
    block:[]u16
    if env!=nil {
        block=environment_block(env,scratch)
        if block==nil {return {},.Invalid_Command}
    }
    // Inheritable copies, so that the caller's handles keep the inheritance they have.
    current:=win.GetCurrentProcess()
    inherited:[3]win.HANDLE
    defer for handle in inherited {
        if handle!=nil {win.CloseHandle(handle)}
    }
    null:win.HANDLE
    defer if null!=nil {win.CloseHandle(null)}
    for stream,i in streams {
        source:=stream
        if source==nil || source==win.INVALID_HANDLE_VALUE {
            if null==nil {
                null=win.CreateFileW(win.L("NUL"),win.GENERIC_READ|win.GENERIC_WRITE,win.FILE_SHARE_READ|win.FILE_SHARE_WRITE,nil,win.OPEN_EXISTING,win.FILE_ATTRIBUTE_NORMAL,nil)
                if null==win.INVALID_HANDLE_VALUE {null=nil;return {},last_error()}
            }
            source=null
        }
        if !win.DuplicateHandle(current,source,current,&inherited[i],0,true,win.DUPLICATE_SAME_ACCESS) {
            inherited[i]=nil
            return {},last_error()
        }
    }
    size:win.SIZE_T
    InitializeProcThreadAttributeList(nil,1,0,&size)
    memory,memory_error:=make_aligned([]u8,int(size),align_of(rawptr),scratch)
    if memory_error!=nil {return {},memory_error}
    list:=Attribute_List(raw_data(memory))
    if !InitializeProcThreadAttributeList(list,1,0,&size) {return {},last_error()}
    defer DeleteProcThreadAttributeList(list)
    if !UpdateProcThreadAttribute(list,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,&inherited[0],size_of(inherited),nil,nil) {return {},last_error()}
    startup:STARTUPINFOEXW
    startup.StartupInfo={
        cb=size_of(STARTUPINFOEXW),
        dwFlags=win.STARTF_USESTDHANDLES,
        hStdInput=inherited[0],
        hStdOutput=inherited[1],
        hStdError=inherited[2],
    }
    startup.lpAttributeList=list
    creation:=flags|win.EXTENDED_STARTUPINFO_PRESENT
    if block!=nil {creation|=win.CREATE_UNICODE_ENVIRONMENT}
    if job!=nil {creation|=win.CREATE_SUSPENDED}
    info:win.PROCESS_INFORMATION
    if !win.CreateProcessW(nil,line,nil,nil,true,creation,raw_data(block),folder,&startup.StartupInfo,&info) {return {},last_error()}
    defer win.CloseHandle(info.hThread)
    if job!=nil {
        if !AssignProcessToJobObject(job,info.hProcess) {
            error=last_error()
            win.TerminateProcess(info.hProcess,1)
            win.CloseHandle(info.hProcess)
            return
        }
        win.ResumeThread(info.hThread)
    }
    return {pid=int(info.dwProcessId),handle=uintptr(info.hProcess)},nil
}

last_error :: proc() -> os.Error {
    code:=win.GetLastError()
    if code==win.ERROR_FILE_NOT_FOUND || code==win.ERROR_PATH_NOT_FOUND {return .Not_Exist}
    return os.Platform_Error(code)
}

// The arguments as the C runtime of the child splits them again.
command_line :: proc(command:[]string,allocator:=context.allocator) -> string {
    b:=strings.builder_make(allocator)
    for argument,i in command {
        if i>0 {strings.write_byte(&b,' ')}
        if argument!="" && strings.index_any(argument," \t\n\v\"")<0 {
            strings.write_string(&b,argument)
            continue
        }
        strings.write_byte(&b,'"')
        backslashes:=0
        for c in transmute([]u8)argument {
            if c=='\\' {backslashes+=1;continue}
            // Backslashes are literal unless a quote follows them.
            for _ in 0..<(backslashes*2+1 if c=='"' else backslashes) {strings.write_byte(&b,'\\')}
            strings.write_byte(&b,c)
            backslashes=0
        }
        for _ in 0..<backslashes*2 {strings.write_byte(&b,'\\')}
        strings.write_byte(&b,'"')
    }
    return strings.to_string(b)
}

// "NAME=VALUE\0...\0\0" in UTF-16; of a name given twice, the last one.
// Windows compares names without case.
environment_block :: proc(env:[]string,allocator:=context.allocator) -> []u16 {
    b:=strings.builder_make(context.temp_allocator)
    outer: for entry,i in env {
        name,_:=variable_name(entry)
        for later in env[i+1:] {
            if later_name,_:=variable_name(later);strings.equal_fold(later_name,name) {continue outer}
        }
        strings.write_string(&b,entry)
        strings.write_byte(&b,0)
    }
    strings.write_byte(&b,0)
    return win.utf8_to_utf16(strings.to_string(b),allocator)
}

process_close :: proc(process:os.Process) {_=win.CloseHandle(win.HANDLE(process.handle))}
