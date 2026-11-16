package platform

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(test)
crash_events_keep_the_last_lines_in_a_file_the_report_reads_oldest_first :: proc(t:^testing.T) {
    folder,error:=os.make_directory_temp("","mirai-crash-events-*",context.temp_allocator)
    testing.expect(t,error==nil);if error!=nil {return}
    defer base.remove_all(folder)
    path:=fmt.tprintf("%s/events.txt",folder)
    events,ok:=crash_events_open(path)
    testing.expect(t,ok);if !ok {return}
    total:=CRASH_EVENT_LINES+5
    for i in 0..<total {crash_event(&events,"api",fmt.tprintf("call %d\nwith a newline that stays in its line",i))}
    long:=strings.repeat("x",CRASH_EVENT_BYTES*2,context.temp_allocator)
    crash_event(&events,"step",long)
    total+=1
    // What the system keeps of the mapping is what the handler reads, without the process.
    data,read_error:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,read_error==nil && len(data)==CRASH_EVENTS_HEAD+CRASH_EVENT_LINES*CRASH_EVENT_BYTES)
    crash_events_close(&events)
    first,count:=crash_events_order(data[:CRASH_EVENTS_HEAD])
    testing.expect_value(t,count,CRASH_EVENT_LINES)
    lines:=make([dynamic]string,context.temp_allocator)
    for i in 0..<count {
        slot:=(first+i)%CRASH_EVENT_LINES
        line:=string(data[CRASH_EVENTS_HEAD+slot*CRASH_EVENT_BYTES:][:CRASH_EVENT_BYTES])
        testing.expect(t,strings.count(line,"\n")==1 && strings.has_suffix(line,"\n"),"a line ends once, where it ends")
        append(&lines,strings.trim_space(line))
    }
    oldest:=total-CRASH_EVENT_LINES
    testing.expect(t,strings.contains(lines[0],fmt.tprintf("call %d with",oldest)),lines[0])
    testing.expect(t,strings.contains(lines[len(lines)-1],"step") && strings.contains(lines[len(lines)-1],"xxx"),"the newest is last, cut to its line")
}
