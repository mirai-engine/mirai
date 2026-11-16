package shaders

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "mirai:cook/workspace"
import "mirai:std/base"
import "mirai:std/subprocess"
import "mirai:project"

Tool :: enum {Slangc,Spirv_Val,Spirv_Opt,Spirv_Cross}

@(private)
TOOL_NAMES :: [Tool]string{.Slangc="slangc",.Spirv_Val="spirv-val",.Spirv_Opt="spirv-opt",.Spirv_Cross="spirv-cross"}

// The tool the environment names (MIRAI_SLANGC or MIRAI_SLANG, for the
// compiler), then the one installed under the deps of root
// (workspace.deps_folder: also from a worktree), then PATH. What a
// checkout installed comes before PATH: an editor has no SDK in its PATH, and
// a slangc that happens to be there is not the pinned one.
tool_find :: proc(root:string,tool:Tool,allocator:=context.allocator) -> (path:string,ok:bool) {
    names:=TOOL_NAMES
    executable:=strings.concatenate({names[tool],project.EXECUTABLE_SUFFIX},context.temp_allocator)
    if tool==.Slangc {
        for variable in ([]string{"MIRAI_SLANGC","MIRAI_SLANG"}) {
            if configured,found:=os.lookup_env(variable,context.temp_allocator);found && configured!="" {return path_clean(configured,allocator),true}
        }
        candidate:=path_join(workspace.deps_folder(root,context.temp_allocator),"slang/bin",executable,allocator=context.temp_allocator)
        if os.is_file(candidate) {return strings.clone(candidate,allocator),true}
    } else {
        // In a folder one, two or three levels below .deps, the shallowest first.
        deps:=workspace.deps_folder(root,context.temp_allocator)
        level:=make([dynamic]string,context.temp_allocator)
        append(&level,deps)
        for _ in 0..<3 {
            next:=make([dynamic]string,context.temp_allocator)
            for directory in level {
                entries,err:=os.read_all_directory_by_path(directory,context.temp_allocator)
                if err!=nil {continue}
                for entry in entries {
                    child:=path_join(directory,entry.name,allocator=context.temp_allocator)
                    if os.is_directory(child) {append(&next,child)}
                }
            }
            slice.sort_by(next[:],path_less)
            for directory in next {
                candidate:=path_join(directory,executable,allocator=context.temp_allocator)
                if os.is_file(candidate) {return strings.clone(candidate,allocator),true}
            }
            level=next
        }
    }
    search,_:=os.lookup_env("PATH",context.temp_allocator)
    directories,_:=os.split_path_list(search,context.temp_allocator)
    for directory in directories {
        if directory=="" {continue}
        candidate:=path_clean(path_join(directory,executable,allocator=context.temp_allocator),context.temp_allocator)
        if os.is_file(candidate) {return strings.clone(candidate,allocator),true}
    }
    return "",false
}

// Tools that run at once: one for each worker of a generation.
@(private)
RUNNER_CAPACITY :: 64

// What a compilation is charged when nothing is known of any: the peak of
// the largest stages.
@(private)
SLANGC_PEAK_BYTES :: i64(6) << 30

// The memory compilations leave free for everything else.
@(private)
MEMORY_RESERVE :: i64(2) << 30

// How often a compilation that waits for room looks again.
@(private)
ROOM_POLL :: 100*time.Millisecond

// What a tool run takes of memory. One with a charge starts only when the
// machine has room for it (admits), looked at in the ledger, which lists the
// compilations of every process: generations run at once in several.
@(private)
Memory :: struct {
    charge:i64,    // the most it is expected to hold at once; 0 starts at once
    ledger:string, // the file of the compilations that run (CACHE_LEDGER); "" counts those of the runner
    record:string, // where its peak is kept once it succeeds (CACHE_PEAKS); "" keeps none
    turn:  int,    // of those of the runner that wait for room, the lowest goes first; the same turn, the first that asked
    waited:^time.Duration, // nil or what is added the time it waited for room
}

// A compilation that runs: what it was charged and what it holds now.
@(private)
Admitted :: struct {charge,held:i64}

// Whether a compilation charged charge may start: free is the memory the
// machine has free now, running the compilations that run in every process
// and own how many of them are of this runner. What one has not taken yet of
// its charge counts as taken: the system still says it is free. A runner
// always runs one.
@(private)
admits :: proc(free:i64,running:[]Admitted,own:int,charge:i64) -> bool {
    if own==0 {return true}
    room:=free-MEMORY_RESERVE-charge
    for each in running {room-=max(each.charge-each.held,0)}
    return room>=0
}

// What a compilation of key is charged: its peak the last time, else the
// largest peak known, else SLANGC_PEAK_BYTES.
@(private)
charge_of :: proc(peaks:map[string]i64,key:string) -> i64 {
    if peak,known:=peaks[key];known {return peak}
    largest:i64
    for _,peak in peaks {largest=max(largest,peak)}
    return largest if largest>0 else SLANGC_PEAK_BYTES
}

// A runner that is cancelled starts no tool and has killed those that ran.
@(private)
Runner :: struct {
    lock:     sync.Mutex,
    turned:   sync.Cond, // a compilation ended, or the one that waits first changed
    waiting:  [RUNNER_CAPACITY]Turn, // the compilations that wait for room (guarded by lock)
    waiting_count,tickets:int,
    runs:     int,  // tools run since the runner was made (guarded by lock)
    cancelled:bool, // guarded by lock
    running:  [RUNNER_CAPACITY]Running, // the tools started and not yet waited for (guarded by lock)
    running_count:int,
    most:     int, // the most compilations with a charge that ran at once (guarded by lock)
}

@(private)
Turn :: struct {turn,ticket:int}

@(private)
Running :: struct {
    process:subprocess.Process,
    charge: i64,
}

// Runs a tool and returns what it wrote to stdout and stderr, in the order it
// wrote it. ok: it could be started and exited with zero.
@(private)
tool_run :: proc(runner:^Runner,command:[]string,allocator:=context.allocator,memory:=Memory{}) -> (output:string,ok:bool) {
    process:subprocess.Process
    problem:string
    if memory.charge<=0 {
        process,problem=tool_start(runner,command,0,allocator)
    } else {
        process,problem=tool_admit(runner,command,memory,allocator)
    }
    if problem!="" {return problem,false}
    collected:=make([dynamic]u8,allocator)
    buffer:[4096]u8
    for {
        count,read_error:=os.read(process.stdout,buffer[:])
        if count>0 {append(&collected,..buffer[:count])}
        if read_error!=nil || count<=0 {break}
    }
    // Out of the list before it is waited for: a process waited for may give its id to another one.
    {
        sync.guard(&runner.lock)
        for i in 0..<runner.running_count {
            if runner.running[i].process.pid!=process.pid {continue}
            runner.running_count-=1
            runner.running[i]=runner.running[runner.running_count]
            break
        }
        sync.cond_broadcast(&runner.turned)
    }
    state,wait_error:=subprocess.wait(&process)
    if memory.charge>0 && memory.ledger!="" {
        if lock,listed:=ledger_lock(memory.ledger);listed {
            ledger_update(memory.ledger,nil,leave=process.pid)
            workspace.lock_release(&lock)
        }
    }
    ok=wait_error==nil && state.exited && state.exit_code==0
    if ok && memory.record!="" && process.peak>0 {peak_write(memory.record,process.peak)}
    subprocess.release(&process)
    return string(lf_bytes(collected[:])),ok
}

// Starts a tool and lists it in the runner; problem says why it did not start.
@(private)
tool_start :: proc(runner:^Runner,command:[]string,charge:i64,allocator:runtime.Allocator) -> (process:subprocess.Process,problem:string) {
    sync.guard(&runner.lock)
    if runner.cancelled {return {},strings.clone("the generation was cancelled",allocator)}
    runner.runs+=1
    start_error:os.Error
    process,start_error=subprocess.start({command=command},pipes=.Merged)
    if start_error!=nil {return {},strings.concatenate({"could not run ",command[0]},allocator)}
    if runner.running_count<RUNNER_CAPACITY {
        runner.running[runner.running_count]={process,charge}
        runner.running_count+=1
    }
    if charge>0 {runner.most=max(runner.most,runner_compiling(runner))}
    return
}

// Starts a compilation once the machine has room for it, and lists it in the
// ledger while its lock is held, so that no other process takes that room.
// The compilations of a runner ask one at a time, by their turns.
@(private)
tool_admit :: proc(runner:^Runner,command:[]string,memory:Memory,allocator:runtime.Allocator) -> (process:subprocess.Process,problem:string) {
    asked:=time.tick_now()
    defer if memory.waited!=nil {memory.waited^+=time.tick_since(asked)}
    sync.lock(&runner.lock)
    me:=Turn{memory.turn,runner.tickets}
    runner.tickets+=1
    if runner.waiting_count<RUNNER_CAPACITY {
        runner.waiting[runner.waiting_count]=me
        runner.waiting_count+=1
    }
    for {
        if runner.cancelled {problem=strings.clone("the generation was cancelled",allocator);break}
        first:=true
        for other in runner.waiting[:runner.waiting_count] {first&&=!(other.turn<me.turn || other.turn==me.turn && other.ticket<me.ticket)}
        if !first {sync.cond_wait(&runner.turned,&runner.lock);continue}
        own:=runner_compiling(runner)
        running:=make([dynamic]Admitted,context.temp_allocator)
        for each in runner.running[:runner.running_count] {
            if each.charge==0 {continue}
            held,_,_:=subprocess.memory_held(each.process.pid)
            append(&running,Admitted{each.charge,held})
        }
        sync.unlock(&runner.lock)
        lock,listed:=ledger_lock(memory.ledger)
        if listed {
            clear(&running)
            ledger_update(memory.ledger,&running)
        }
        // A machine that does not say what is free has room for one.
        _,free,_:=base.memory_stats()
        admitted:=admits(free,running[:],own,memory.charge)
        if admitted {
            process,problem=tool_start(runner,command,memory.charge,allocator)
            if listed && problem=="" {ledger_update(memory.ledger,nil,add=fmt.tprintf("%d %d %d\n",os.get_pid(),process.pid,memory.charge))}
        }
        if listed {workspace.lock_release(&lock)}
        sync.lock(&runner.lock)
        if admitted {break}
        sync.cond_wait_with_timeout(&runner.turned,&runner.lock,ROOM_POLL)
    }
    for each,i in runner.waiting[:runner.waiting_count] {
        if each!=me {continue}
        runner.waiting_count-=1
        runner.waiting[i]=runner.waiting[runner.waiting_count]
        break
    }
    sync.cond_broadcast(&runner.turned)
    sync.unlock(&runner.lock)
    return
}

// The compilations with a charge the runner runs (lock held).
@(private)
runner_compiling :: proc(runner:^Runner) -> int {
    count:=0
    for each in runner.running[:runner.running_count] {count+=int(each.charge>0)}
    return count
}

// Takes the lock of a ledger; false when there is none or it cannot be made.
@(private)
ledger_lock :: proc(path:string) -> (lock:workspace.Lock,ok:bool) {
    if path=="" {return}
    lock_path:=strings.concatenate({path,".lock"},context.temp_allocator)
    what:=fmt.tprintf("pid %d",os.get_pid())
    for {
        taken,failed:bool
        lock,taken,_,failed=workspace.lock_take(lock_path,what)
        if taken {return lock,true}
        if failed {return {},false}
        time.sleep(time.Millisecond)
    }
}

// Rewrites a ledger whose lock is held: lines "<generation pid> <compiler
// pid> <charge>". It keeps those whose generation and compiler run, but the
// compiler leave, adds the line add and appends to running what each one kept
// was charged and holds now.
@(private)
ledger_update :: proc(path:string,running:^[dynamic]Admitted,leave:=0,add:="") {
    data,_:=os.read_entire_file(path,context.temp_allocator)
    kept:=strings.builder_make(context.temp_allocator)
    changed:=add!=""
    text:=string(data)
    for line in strings.split_lines_iterator(&text) {
        fields:=strings.fields(line,context.temp_allocator)
        values:[3]i64
        parsed:=len(fields)==3
        for &value,i in values {
            if !parsed {break}
            value,parsed=strconv.parse_i64(fields[i])
        }
        held:i64
        alive:=false
        if parsed && int(values[1])!=leave && subprocess.process_alive(int(values[0])) {held,_,alive=subprocess.memory_held(int(values[1]))}
        if !alive {changed=true;continue}
        if running!=nil {append(running,Admitted{values[2],held})}
        strings.write_string(&kept,line)
        strings.write_byte(&kept,'\n')
    }
    strings.write_string(&kept,add)
    if changed {write_file_atomic(path,kept.buf[:])}
}

// No tool starts any more and those running are killed: their runs fail.
@(private)
runner_cancel :: proc(runner:^Runner) {
    sync.guard(&runner.lock)
    runner.cancelled=true
    sync.cond_broadcast(&runner.turned)
    for &each in runner.running[:runner.running_count] {_=subprocess.terminate(&each.process,force=true)}
}

@(private)
runner_cancelled :: proc(runner:^Runner) -> bool {
    sync.guard(&runner.lock)
    return runner.cancelled
}
