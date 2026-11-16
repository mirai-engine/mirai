#+build windows
#+private
package platform

import "base:runtime"
import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign kernel32 {
    GetModuleHandleExW :: proc(flags:win32.DWORD,address:rawptr,module:^win32.HMODULE) -> win32.BOOL ---
}

MODULE_FROM_ADDRESS :: 0x4
MODULE_UNCHANGED_REFCOUNT :: 0x2

Crash_Sink :: win32.HANDLE

_crash_handler_install :: proc() {win32.SetUnhandledExceptionFilter(crash_filter)}

crash_flush :: proc "contextless" (o:^Crash_Out) {
    for sink in o.sinks[:o.count] {
        written:win32.DWORD
        win32.WriteFile(sink,&o.buffer[0],win32.DWORD(o.used),&written,nil)
    }
    o.used=0
}

crash_filter :: proc "system" (info:^win32.EXCEPTION_POINTERS) -> win32.LONG {
    context=runtime.default_context()
    o:Crash_Out
    o.sinks[0]=win32.GetStdHandle(win32.STD_ERROR_HANDLE)
    o.count=1
    path:[512]u16
    if n:=win32.GetEnvironmentVariableW(win32.L(CRASH_REPORT_VARIABLE),&path[0],len(path));n>0 && int(n)<len(path) {
        file:=win32.CreateFileW(cstring16(&path[0]),win32.GENERIC_WRITE,win32.FILE_SHARE_READ,nil,win32.CREATE_ALWAYS,win32.FILE_ATTRIBUTE_NORMAL,nil)
        if file!=win32.INVALID_HANDLE_VALUE {
            o.sinks[1]=file
            o.count=2
        }
    }
    record:=info.ExceptionRecord
    crash_put(&o,"\nmirai: the process ended by ")
    code:=record.ExceptionCode
    switch code {
    case 0xC0000005:
        crash_put(&o,record.ExceptionInformation[0]!=nil?"an access violation writing ":"an access violation reading ")
        crash_hex(&o,u64(uintptr(record.ExceptionInformation[1])))
    case 0xC00000FD: crash_put(&o,"a stack overflow")
    case 0x80000003: crash_put(&o,"a trap: a failed assertion, its message above")
    case 0xC000008C: crash_put(&o,"a failed bounds check, its message above")
    case 0xC000001D: crash_put(&o,"an illegal instruction")
    case 0xC0000094: crash_put(&o,"an integer division by zero")
    case 0xC0000409: crash_put(&o,"a stack buffer overrun")
    case 0xC0000374: crash_put(&o,"a corrupted heap")
    case:
        crash_put(&o,"the exception ")
        crash_hex(&o,u64(code))
    }
    crash_put(&o,"\n")
    process:=win32.GetCurrentProcess()
    win32.SymSetOptions(win32.SYMOPT_LOAD_LINES|win32.SYMOPT_DEFERRED_LOADS)
    symbols:=bool(win32.SymInitialize(process,nil,true))
    frames:[CRASH_FRAMES]rawptr
    count:=int(win32.RtlCaptureStackBackTrace(0,CRASH_FRAMES,&frames[0],nil))
    // The frames from the handler to the fault are not the program's.
    first:=0
    for i in 0..<count {
        if frames[i]==record.ExceptionAddress {
            first=i
            break
        }
    }
    if first==0 {crash_frame(&o,process,symbols,uintptr(record.ExceptionAddress),false)}
    for i in first..<count {crash_frame(&o,process,symbols,uintptr(frames[i]),i>first)}
    if symbols {win32.SymCleanup(process)}
    crash_events_report(&o)
    crash_flush(&o)
    if o.count>1 {win32.CloseHandle(o.sinks[1])}
    return win32.EXCEPTION_EXECUTE_HANDLER
}

// The events the process noted before the fault, when CRASH_EVENTS_VARIABLE names their file.
crash_events_report :: proc "contextless" (o:^Crash_Out) {
    path:[512]u16
    n:=win32.GetEnvironmentVariableW(win32.L(CRASH_EVENTS_VARIABLE),&path[0],len(path))
    if n==0 || int(n)>=len(path) {return}
    file:=win32.CreateFileW(cstring16(&path[0]),win32.GENERIC_READ,win32.FILE_SHARE_READ|win32.FILE_SHARE_WRITE|win32.FILE_SHARE_DELETE,nil,win32.OPEN_EXISTING,win32.FILE_ATTRIBUTE_NORMAL,nil)
    if file==win32.INVALID_HANDLE_VALUE {return}
    defer win32.CloseHandle(file)
    head:[CRASH_EVENTS_HEAD]u8
    read:win32.DWORD
    if !win32.ReadFile(file,&head[0],CRASH_EVENTS_HEAD,&read,nil) || read!=CRASH_EVENTS_HEAD {return}
    first,count:=crash_events_order(head[:])
    if count==0 {return}
    crash_put(o,"Events before the fault, the oldest first (seconds, kind, what):\n")
    line:[CRASH_EVENT_BYTES]u8
    for i in 0..<count {
        slot:=(first+i)%CRASH_EVENT_LINES
        at:=win32.LARGE_INTEGER(CRASH_EVENTS_HEAD+slot*CRASH_EVENT_BYTES)
        if !win32.SetFilePointerEx(file,at,nil,win32.FILE_BEGIN) {return}
        if !win32.ReadFile(file,&line[0],CRASH_EVENT_BYTES,&read,nil) || read!=CRASH_EVENT_BYTES {return}
        crash_events_line(o,line[:])
    }
}

// One frame: module and offset, and the procedure, file and line when the
// module has them. Without debug information dbghelp names the nearest
// export, which is another procedure: the name goes only with a line.
crash_frame :: proc "contextless" (o:^Crash_Out,process:win32.HANDLE,symbols:bool,address:uintptr,returned:bool) {
    // A return address is the instruction after the call.
    at:=returned?address-1:address
    crash_put(o,"    ")
    module:win32.HMODULE
    if GetModuleHandleExW(MODULE_FROM_ADDRESS|MODULE_UNCHANGED_REFCOUNT,rawptr(at),&module) {
        name:[260]u16
        n:=win32.GetModuleFileNameW(module,&name[0],len(name))
        crash_wide(o,crash_wide_base(name[:n]))
        crash_put(o,"+")
        crash_hex(o,u64(at-uintptr(module)))
    } else {
        crash_hex(o,u64(at))
    }
    if symbols {
        line:win32.IMAGEHLP_LINEW64
        line.SizeOfStruct=size_of(line)
        displacement:win32.DWORD
        if win32.SymGetLineFromAddrW64(process,win32.DWORD64(at),&displacement,&line) {
            data:[size_of(win32.SYMBOL_INFOW)+256*size_of(win32.WCHAR)]u8
            symbol:=cast(^win32.SYMBOL_INFOW)&data[0]
            symbol.SizeOfStruct=size_of(win32.SYMBOL_INFOW)
            symbol.MaxNameLen=255
            if win32.SymFromAddrW(process,win32.DWORD64(at),nil,symbol) {
                crash_put(o,"  ")
                crash_wide(o,([^]u16)(&symbol.Name[0])[:symbol.NameLen])
            }
            crash_put(o,"  ")
            file:=([^]u16)(line.FileName)
            length:=0
            for file[length]!=0 {length+=1}
            crash_wide(o,crash_wide_base(file[:length]))
            crash_put(o,":")
            crash_dec(o,u64(line.LineNumber))
        }
    }
    crash_put(o,"\n")
}

crash_wide_base :: proc "contextless" (text:[]u16) -> []u16 {
    at:=0
    for c,i in text {
        if c=='/' || c=='\\' {at=i+1}
    }
    return text[at:]
}

// Names and paths in ASCII; anything else as '?'.
crash_wide :: proc "contextless" (o:^Crash_Out,text:[]u16) {
    for c in text {
        b:=[1]u8{c<128?u8(c):'?'}
        crash_put(o,string(b[:]))
    }
}
