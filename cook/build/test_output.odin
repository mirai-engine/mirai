package build

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

// What the runner reads from what a test executable of core:testing says, a
// line at a time: which tests run and since when, which failed, and what of it
// to show. Its log entries are "[LEVEL] --- [time] text", and the lines that
// follow one without a header of their own belong to it.
Test_Output :: struct {
    quiet:bool,         // only failures, warnings and the summary
    states_hidden:bool, // the state changes are the runner's, not asked by a flag
    running:map[string]time.Tick, // tests that run (package.name), with when they started
    changed:time.Tick,  // when a test started or ended last, or the executable started
    started:int,        // tests that started
    finished:int,       // tests the summary says ended; -1 before the summary
    summary:bool,       // the summary of the runner began
    shown:bool,         // the lines of the current entry are shown
    hung:bool,          // the executable hung and was killed
    failed:[dynamic]string, // package.name, once each
    errors:[dynamic]string, // the entries at error level and above, which name their test
    // Procedures whose fatal message came before their test started: the
    // runner orders a batch of messages by when they were made, and makes the
    // one of a start when it reads it.
    stopped:[dynamic]string,
}

// The name of a test without its package (pkg.name).
test_bare :: proc(name:string) -> string {
    return name[strings.last_index_byte(name,'.')+1:]
}

// Reads a line of the output: what to print of it and whether to print it.
test_output_line :: proc(out:^Test_Output,raw:string,now:time.Tick) -> (text:string,show:bool) {
    line:=strings.trim_right(raw,"\r")
    if out.summary {
        switch {
        // The runner says how to run the failed ones again by recompiling: mirai test says --failed.
        case line=="",
             strings.has_prefix(line,"To run only the failed test"),
             strings.has_prefix(line,"\t-define:ODIN_TEST_NAMES="),
             strings.has_prefix(line,"If your terminal supports OSC 52"):
            return "",false
        case strings.has_prefix(line," - "):
            tab:=strings.index_byte(line,'\t')
            test_failed_add(out,strings.trim_space(line[3:tab if tab>=0 else len(line)]))
        }
        return line,true
    }
    if finished,is_summary:=test_summary_line(line);is_summary {
        out.summary=true
        out.finished=finished
        clear(&out.running)
        out.changed=now
        return line,true
    }
    level,body,entry:=test_log_entry(line)
    if !entry {
        // "No tests to run.", "No test found for the name: ..." are the runner's.
        return line,!out.quiet || strings.has_prefix(line,"No test") || (line!="" && (out.shown || strings.contains(line,".odin(")))
    }
    out.shown=!out.quiet || level>=.Warning
    if level>=.Error {append(&out.errors,strings.clone(strings.trim_space(line)))}
    if name,state,changed:=test_state_change(body);changed {
        switch state {
        case "Running":
            out.started+=1
            if at,found:=slice.linear_search(out.stopped[:],test_bare(name));found {
                unordered_remove(&out.stopped,at)
            } else {
                out.running[strings.clone(name)]=now
            }
        case "Failed":
            delete_key(&out.running,name)
            test_failed_add(out,name)
        case:
            delete_key(&out.running,name)
        }
        out.changed=now
        return line,out.shown && !out.states_hidden
    }
    // A test stopped by a signal ends without a state change: with what the
    // runner says of it, or with the fatal message of the test itself.
    if level==.Fatal {
        if stopped,signalled:=test_signal_stop(body);signalled {
            delete_key(&out.running,stopped)
            test_failed_add(out,stopped)
            out.changed=now
        } else if procedure,located:=test_log_procedure(body);located {
            ended:=false
            for running in out.running {
                if test_bare(running)!=procedure {continue}
                delete_key(&out.running,running)
                out.changed=now
                ended=true
                break
            }
            if !ended {append(&out.stopped,strings.clone(procedure))}
        }
    }
    return line,out.shown
}

// Whether the executable hangs: no test started or ended for timeout. Each one
// that runs then has run at least that long, and before the first one or
// after the last one nothing should take it.
test_hung :: proc(out:Test_Output,timeout:time.Duration,now:time.Tick) -> bool {
    return timeout>0 && time.tick_diff(out.changed,now)>=timeout
}

// What the entries at error level and above say of a test, with where.
test_messages :: proc(out:^Test_Output,name:string,allocator:runtime.Allocator) -> []string {
    needle:=fmt.tprintf(":%s()]",test_bare(name))
    messages:=make([dynamic]string,allocator)
    for line in out.errors {
        if strings.contains(line,needle) {append(&messages,strings.clone(line,allocator))}
    }
    return messages[:]
}

@(private="file")
test_failed_add :: proc(out:^Test_Output,name:string) {
    if !slice.contains(out.failed[:],name) {append(&out.failed,strings.clone(name))}
}

// "Finished 3 tests in 1.2s. ...": the summary of the runner, with how many ended.
@(private="file")
test_summary_line :: proc(line:string) -> (finished:int,ok:bool) {
    if !strings.has_prefix(line,"Finished ") {return}
    rest:=line[len("Finished "):]
    digits:=0
    for digits<len(rest) && rest[digits]>='0' && rest[digits]<='9' {
        finished=finished*10+int(rest[digits]-'0')
        digits+=1
    }
    return finished,digits>0 && strings.has_prefix(rest[digits:]," test")
}

// The level and the text of a log entry, after its time when it has one.
@(private="file")
test_log_entry :: proc(line:string) -> (level:runtime.Logger_Level,body:string,ok:bool) {
    HEADERS :: [5]struct{text:string,level:runtime.Logger_Level}{
        {"[DEBUG] --- ",.Debug},{"[INFO ] --- ",.Info},{"[WARN ] --- ",.Warning},{"[ERROR] --- ",.Error},{"[FATAL] --- ",.Fatal},
    }
    for header in HEADERS {
        if !strings.has_prefix(line,header.text) {continue}
        body=line[len(header.text):]
        if len(body)>1 && body[0]=='[' && body[1]>='0' && body[1]<='9' {
            if close:=strings.index(body,"] ");close>0 {body=body[close+2:]}
        }
        return header.level,body,true
    }
    return
}

// "Test #3 pkg.name changed state to Running.": the test and its new state.
@(private="file")
test_state_change :: proc(body:string) -> (name,state:string,ok:bool) {
    rest:=strings.trim_prefix(body,"Test #")
    if len(rest)==len(body) {return}
    rest=rest[max(strings.index_byte(rest,' '),0)+1:]
    MARK :: " changed state to "
    at:=strings.index(rest,MARK)
    if at<0 {return}
    return rest[:at],strings.trim_right(rest[at+len(MARK):],"."),true
}

// "Caught signal to stop test #3 pkg.name for: ...": the test it stopped.
@(private="file")
test_signal_stop :: proc(body:string) -> (name:string,ok:bool) {
    rest:=strings.trim_prefix(body,"Caught signal to stop test #")
    if len(rest)==len(body) {return}
    rest=rest[max(strings.index_byte(rest,' '),0)+1:]
    end:=strings.index(rest," for:")
    if end<0 {return}
    return rest[:end],true
}

// "[file.odin:12:procedure()] ...": the procedure an entry comes from.
@(private="file")
test_log_procedure :: proc(body:string) -> (procedure:string,ok:bool) {
    if !strings.has_prefix(body,"[") {return}
    end:=strings.index(body,"()] ")
    if end<0 {return}
    location:=body[1:end]
    return location[strings.last_index_byte(location,':')+1:],true
}

// The tests that run, the oldest first, counted as failed: the executable
// ended without them ending.
@(private)
test_running_failed :: proc(out:^Test_Output) -> []string {
    Running :: struct {name:string,since:time.Tick}
    running:=make([dynamic]Running,context.temp_allocator)
    for name,since in out.running {append(&running,Running{name,since})}
    slice.sort_by(running[:],proc(a,b:Running) -> bool {return time.tick_diff(a.since,b.since)>0})
    names:=make([dynamic]string,context.temp_allocator)
    for r in running {
        append(&names,test_bare(r.name))
        test_failed_add(out,r.name)
    }
    return names[:]
}
