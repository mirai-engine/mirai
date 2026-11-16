package platform

import "core:fmt"
import "core:mem/virtual"
import "core:os"

// When a fault ends the process: what it was, then each frame of the stack
// by module and offset, and on Windows the procedure, file and line of the
// frames whose module has its debug information. It goes to stderr and, when the variable
// CRASH_REPORT_VARIABLE names a file, to that file too. A failed assertion or
// bounds check of Odin prints its message and then faults, so it leaves its
// stack as well. The handler is the one of the process: a launcher installs
// it, never a library.
CRASH_REPORT_VARIABLE :: "MIRAI_CRASH_REPORT"
CRASH_FRAMES :: 48

crash_handler_install :: proc() {_crash_handler_install()}

// Text of a report, built on the stack: the heap may be what failed.
@(private)
Crash_Out :: struct {
    buffer:[2048]u8,
    used:int,
    sinks:[2]Crash_Sink,
    count:int,
}

@(private)
crash_put :: proc "contextless" (o:^Crash_Out,text:string) {
    for i in 0..<len(text) {
        if o.used==len(o.buffer) {crash_flush(o)}
        o.buffer[o.used]=text[i]
        o.used+=1
    }
}

@(private)
crash_hex :: proc "contextless" (o:^Crash_Out,value:u64) {
    HEX :: [16]u8{'0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'}
    hex:=HEX
    digits:[16]u8
    n:=0
    v:=value
    for {
        digits[n]=hex[v&15]
        n+=1
        v>>=4
        if v==0 {break}
    }
    crash_put(o,"0x")
    for i:=n-1;i>=0;i-=1 {crash_put(o,string(digits[i:i+1]))}
}

@(private)
crash_dec :: proc "contextless" (o:^Crash_Out,value:u64) {
    digits:[20]u8
    n:=0
    v:=value
    for {
        digits[n]=u8('0'+v%10)
        n+=1
        v/=10
        if v==0 {break}
    }
    for i:=n-1;i>=0;i-=1 {crash_put(o,string(digits[i:i+1]))}
}

// The file name of a path, either separator.
@(private)
crash_base_name :: proc "contextless" (path:string) -> string {
    at:=0
    for i in 0..<len(path) {
        if path[i]=='/' || path[i]=='\\' {at=i+1}
    }
    return path[at:]
}

// What a process did before a fault, for the report: a ring of the last
// CRASH_EVENT_LINES lines in a file mapped in memory, so noting one is a copy
// and the system keeps the file when the process ends. When
// CRASH_EVENTS_VARIABLE names that file, the report copies its lines after
// the stack, the oldest first.
CRASH_EVENTS_VARIABLE :: "MIRAI_CRASH_EVENTS"
CRASH_EVENT_LINES :: 128
CRASH_EVENT_BYTES :: 120 // a line, its newline included
@(private) CRASH_EVENTS_HEAD :: 32 // "next <decimal>", padded, then a newline

Crash_Events :: struct {
    data:[]u8, // the mapped file: the head, then the lines
    next:u64,  // the slot of the next line, counted from the first ever
    start_ns:u64,
}

// Maps the file of the events, empty. Without it, crash_event notes nothing.
crash_events_open :: proc(path:string) -> (events:Crash_Events,ok:bool) {
    size:=CRASH_EVENTS_HEAD+CRASH_EVENT_LINES*CRASH_EVENT_BYTES
    file,error:=os.open(path,{.Read,.Write,.Create,.Trunc})
    if error!=nil {return}
    blank:[CRASH_EVENTS_HEAD+CRASH_EVENT_LINES*CRASH_EVENT_BYTES]u8
    for &b in blank {b=' '}
    for i in 0..<CRASH_EVENT_LINES {blank[CRASH_EVENTS_HEAD+(i+1)*CRASH_EVENT_BYTES-1]='\n'}
    blank[CRASH_EVENTS_HEAD-1]='\n'
    _,write_error:=os.write(file,blank[:])
    os.close(file)
    if write_error!=nil {return}
    data,map_error:=virtual.map_file_from_path(path,{.Read,.Write})
    if map_error!=nil || len(data)!=size {
        if data!=nil {virtual.unmap_file(data)}
        return
    }
    events={data=data,start_ns=clock_ns()}
    crash_events_head(&events)
    return events,true
}

crash_events_close :: proc(events:^Crash_Events) {
    if events.data!=nil {virtual.unmap_file(events.data)}
    events^={}
}

// Notes a line: the seconds since the events opened, a kind and what it was.
// It does not allocate; what does not fit in a line is cut.
crash_event :: proc(events:^Crash_Events,kind,text:string) {
    if events==nil || events.data==nil {return}
    line:[CRASH_EVENT_BYTES]u8
    elapsed:=f64(clock_ns()-events.start_ns)/1e9
    written:=fmt.bprintf(line[:CRASH_EVENT_BYTES-1],"%.3f %-8s %s",elapsed,kind,text)
    slot:=events.data[CRASH_EVENTS_HEAD+int(events.next%CRASH_EVENT_LINES)*CRASH_EVENT_BYTES:][:CRASH_EVENT_BYTES]
    n:=copy(slot,written)
    for i in n..<CRASH_EVENT_BYTES-1 {slot[i]=' '}
    // A line ends where it was cut, never inside another of its own.
    for i in 0..<n {if slot[i]=='\n' || slot[i]=='\r' {slot[i]=' '}}
    slot[CRASH_EVENT_BYTES-1]='\n'
    events.next+=1
    crash_events_head(events)
}

@(private)
crash_events_head :: proc(events:^Crash_Events) {
    head:[CRASH_EVENTS_HEAD]u8
    written:=fmt.bprintf(head[:CRASH_EVENTS_HEAD-1],"next %d",events.next)
    n:=copy(events.data[:CRASH_EVENTS_HEAD-1],written)
    for i in n..<CRASH_EVENTS_HEAD-1 {events.data[i]=' '}
}

// The slot the oldest line of a file of events is in, read from its head,
// and how many lines it has.
@(private)
crash_events_order :: proc "contextless" (head:[]u8) -> (first,count:int) {
    next:u64
    for c in head[len("next "):] {
        if c<'0' || c>'9' {break}
        next=next*10+u64(c-'0')
    }
    if next<=CRASH_EVENT_LINES {return 0,int(next)}
    return int(next%CRASH_EVENT_LINES),CRASH_EVENT_LINES
}

// A line of the events as the report has it: without the spaces that pad it.
@(private)
crash_events_line :: proc "contextless" (o:^Crash_Out,line:[]u8) {
    end:=len(line)
    for end>0 && (line[end-1]==' ' || line[end-1]=='\n' || line[end-1]==0) {end-=1}
    if end==0 {return}
    crash_put(o,"    ")
    crash_put(o,string(line[:end]))
    crash_put(o,"\n")
}
