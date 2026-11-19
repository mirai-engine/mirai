package workspace

import "core:fmt"
import "core:os"
import "core:strings"
import si "core:sys/info"
import "core:time"
import "mirai:project"

// The checkouts of one repository share what is costly to download or to
// build: the dependencies of .deps and the caches under .mirai/cache, kept by
// the main checkout (project.shared_root).

// The .deps of root, or the one of the main checkout when root has none. A
// checkout without either gets its own: that is where installs write.
deps_folder :: proc(root:string,allocator:=context.allocator) -> string {
    own:=join(root,".deps")
    if os.is_dir(own) {return slashes(own,allocator)}
    shared:=join(project.shared_root(root,context.temp_allocator),".deps")
    if os.is_dir(shared) {return slashes(shared,allocator)}
    return slashes(own,allocator)
}

// A cache every checkout of the repository shares: <main>/.mirai/cache/<name>.
cache_folder :: proc(root,name:string,allocator:=context.allocator) -> string {
    return slashes(join(project.shared_root(root,context.temp_allocator),".mirai","cache",name),allocator)
}

// The Odin compiler pinned under the deps of root, when it is there.
deps_compiler :: proc(root:string,allocator:=context.allocator) -> (path:string,found:bool) {
    deps:=deps_folder(root,context.temp_allocator)
    executable:=strings.concatenate({"odin",project.EXECUTABLE_SUFFIX},context.temp_allocator)
    for folder in ([3]string{"odin/dist","linux-amd64/odin","odin"}) {
        candidate:=join(deps,folder,executable)
        if os.is_file(candidate) {return slashes(candidate,allocator),true}
    }
    return "",false
}

// A lock between processes: who holds it is the only one that runs what it
// guards, whatever checkout it comes from. The system releases it when its
// process ends.
Lock :: struct {
    handle:uintptr,
    owner:string, // file that names who holds it
    held:bool,
    next:^Lock,   // what is released with it
}

// Blocks until the lock of path is free and takes it. notice runs once, with
// what the holder wrote, when the lock is busy. what names this holder.
lock_acquire :: proc(path,what:string,notice:proc(holder:string)=nil) -> (lock:Lock,ok:bool) {
    folder:=os.dir(path)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return}
    owner:=strings.concatenate({path,".owner"},context.allocator)
    noticed:=false
    for {
        handle,taken,failed:=lock_try(path)
        if failed {delete(owner);return}
        if taken {
            lock={handle=handle,owner=owner,held=true}
            _=os.write_entire_file(owner,transmute([]u8)what)
            return lock,true
        }
        if !noticed && notice!=nil {
            holder,_:=os.read_entire_file(owner,context.temp_allocator)
            notice(strings.trim_space(string(holder)))
            noticed=true
        }
        time.sleep(250*time.Millisecond)
    }
}

lock_release :: proc(lock:^Lock) {
    if lock.next!=nil {
        lock_release(lock.next)
        free(lock.next)
        lock.next=nil
    }
    if !lock.held {return}
    _=os.remove(lock.owner)
    lock_close(lock.handle)
    delete(lock.owner)
    lock^={}
}

// Lets go of the lock in this process without freeing it: a child that
// inherited its handle (subprocess.start, detached) holds it until it ends,
// and its owner file stays.
lock_hand_over :: proc(lock:^Lock) {
    if !lock.held {return}
    lock_close(lock.handle)
    delete(lock.owner)
    lock^={}
}

// Takes the lock of path when it is free. When it is busy, holder is what
// its holder wrote; failed when the lock cannot be made at all.
lock_take :: proc(path,what:string) -> (lock:Lock,taken:bool,holder:string,failed:bool) {
    folder:=os.dir(path)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return {},false,"",true}
    owner:=strings.concatenate({path,".owner"},context.allocator)
    handle,ok,try_failed:=lock_try(path)
    if !ok {
        delete(owner)
        if try_failed {return {},false,"",true}
        written,_:=os.read_entire_file(strings.concatenate({path,".owner"},context.temp_allocator),context.temp_allocator)
        return {},false,strings.trim_space(string(written)),false
    }
    _=os.write_entire_file(owner,transmute([]u8)what)
    return {handle=handle,owner=owner,held=true},true,"",false
}

// Waits until the lock of path is free, without taking it, for at most limit
// (zero: no limit). notice runs once, with what the holder wrote, when it is
// busy. false when the limit passed first.
lock_wait :: proc(path:string,notice:proc(holder:string)=nil,limit:=time.Duration(0)) -> bool {
    start:=time.tick_now()
    noticed:=false
    for {
        handle,taken,failed:=lock_try(path)
        if failed {return true}
        if taken {lock_close(handle);return true}
        if !noticed && notice!=nil {
            holder,_:=os.read_entire_file(strings.concatenate({path,".owner"},context.temp_allocator),context.temp_allocator)
            notice(strings.trim_space(string(holder)))
            noticed=true
        }
        if limit>0 && time.tick_since(start)>=limit {return false}
        time.sleep(250*time.Millisecond)
    }
}

// The locks every checkout of the repository shares: <main>/.mirai/cache/locks/<name>.
lock_path :: proc(root,name:string,allocator:=context.allocator) -> string {
    return slashes(join(cache_folder(root,"locks",context.temp_allocator),name),allocator)
}

// The compilations of a machine share a few turns: BUILD_LOCK, the first, and
// those after it while the memory of another one is free, because together
// they can run out of it. A generation of shaders has SHADERS_LOCK, which no
// compilation waits for. Within a checkout or a project they go one at a
// time: they write the same files. BUILD_NOTE says when one took a turn last
// (builds_since). What measures time holds MEASURE_LOCK only while it times,
// and starts once no compilation runs and no GPU work of another runs
// (measure_try, gpu_work). While it runs, what would put work on the GPU and
// is not part of it waits for it to end, and what uses no GPU runs at low
// priority (measured). A process whose MEASURE_ENV is set is part of a
// measurement (its children) while that one holds MEASURE_LOCK: it neither
// takes MEASURE_LOCK nor waits for it. MEASURE_ENV holds the pid of the
// holder, which is also what the holder wrote first in the lock
// (measure_holder): a process that is no child of the measurement, like the
// editor of a session a command of it calls, is told that pid and runs as
// part of it while the lock says the same (measurement_holds). No process
// waits for MEASURE_LOCK while its GPU turn says it works (gpu_turn_mark):
// a measurement waits for those, so the two never wait for each other.
BUILD_LOCK :: "build.lock"
SHADERS_LOCK :: "shaders.lock"
BUILD_NOTE :: "build.last"
MEASURE_LOCK :: "measure.lock"
MEASURE_ENV :: "MIRAI_MEASURE"

// Whether this process is part of a measurement: its MEASURE_ENV is set.
measuring :: proc() -> bool {
    return measurement(context.temp_allocator)!=""
}

// The measurement this process is part of, as MEASURE_ENV names it; "" outside one.
measurement :: proc(allocator:=context.allocator) -> string {
    value,_:=os.lookup_env(MEASURE_ENV,allocator)
    return value
}

// What the holder of MEASURE_LOCK writes in it: its pid, as MEASURE_ENV gives
// it to its children, and what it measures.
measure_holder :: proc(what:string,allocator:=context.temp_allocator) -> string {
    return fmt.aprintf("pid %d, %s",os.get_pid(),what,allocator=allocator)
}

// Whether the measurement a caller says it is part of (its MEASURE_ENV)
// holds MEASURE_LOCK now.
measurement_holds :: proc(root,measurement:string) -> bool {
    if measurement=="" {return false}
    held,holder,_:=lock_holder(lock_path(root,MEASURE_LOCK,context.temp_allocator),context.temp_allocator)
    return held && strings.has_prefix(holder,fmt.tprintf("pid %s,",measurement))
}

// The most turns of the compilations of a machine, and the memory free that
// a turn after the first asks for: what the largest compiler of a build takes.
BUILD_TURNS :: 4
BUILD_TURN_MEMORY :: 4<<30

// The file of a turn.
@(private)
build_turn_path :: proc(root:string,turn:int,allocator:=context.allocator) -> string {
    return lock_path(root,turn==0?BUILD_LOCK:fmt.tprintf("build-%d.lock",turn),allocator)
}

// The locks a compilation or a generation of shaders holds while it runs.
@(private)
build_paths :: proc(root:string) -> []string {
    paths:=make([]string,BUILD_TURNS+1,context.temp_allocator)
    for turn in 0..<BUILD_TURNS {paths[turn]=build_turn_path(root,turn,context.temp_allocator)}
    paths[BUILD_TURNS]=lock_path(root,SHADERS_LOCK,context.temp_allocator)
    return paths
}

// How many turns this machine has: one per two physical cores, and at least one.
@(private)
build_turns :: proc() -> int {
    physical,_,counted:=si.cpu_core_count()
    return clamp(physical/2,1,BUILD_TURNS) if counted else 1
}

// The memory a build that starts now can count on; 0 when unknown.
@(private)
build_memory_free :: proc() -> i64 {
    total,free,_,_,known:=si.ram_stats()
    if !known {return 0}
    // macOS does not say what is free.
    return free>0?free:total/2
}

// Takes the first turn that is free of those there are: one after the first
// only with the memory of another compilation free. When none is taken,
// holder is who has the first.
@(private)
build_turn_try :: proc(root,what:string,turns:int,memory:i64) -> (lock:Lock,taken:bool,holder:string,failed:bool) {
    for turn in 0..<turns {
        if turn>0 && memory<BUILD_TURN_MEMORY {return}
        written:string
        lock,taken,written,failed=lock_take(build_turn_path(root,turn,context.temp_allocator),what)
        if taken || failed {return}
        if turn==0 {holder=written}
    }
    return
}

// Takes what keeps the other compilations out of the files of root and of
// also, one folder after the other: they are always taken in that order.
@(private)
build_folders_acquire :: proc(lock:^Lock,root,what:string,notice:proc(holder:string),also:[]string) {
    take :: proc(lock:^Lock,folder,what:string,notice:proc(holder:string)) {
        taken,ok:=lock_acquire(join(folder,".mirai","build-turn.lock"),what,notice)
        if !ok {return}
        next:=new(Lock)
        next^=taken
        next.next=lock.next
        lock.next=next
    }
    take(lock,root,what,notice)
    for folder in also {
        if !project.path_same(folder,root) {take(lock,folder,what,notice)}
    }
}

@(private)
build_note :: proc(root,what:string) {
    _=os.write_entire_file(lock_path(root,BUILD_NOTE,context.temp_allocator),transmute([]u8)what)
}

// Blocks until no other compilation writes the files of root or of the
// folders of also and a turn is free, takes them and notes that a compilation
// starts now: BUILD_NOTE holds what, and its modification time is when.
// notice runs once for each thing it waits for, with who has it.
build_acquire :: proc(root,what:string,notice:proc(holder:string)=nil,also:=[]string{}) -> (lock:Lock,ok:bool) {
    held:Lock
    build_folders_acquire(&held,root,what,notice,also)
    noticed:=false
    for {
        turn,taken,holder,failed:=build_turn_try(root,what,build_turns(),build_memory_free())
        if failed {break}
        if taken {
            lock,ok=turn,true
            build_note(root,what)
            break
        }
        if !noticed && notice!=nil {
            notice(holder)
            noticed=true
        }
        time.sleep(250*time.Millisecond)
    }
    lock.next=held.next
    return
}

// The same for a generation of shaders, which takes no turn of the
// compilations: only one generation runs at a time.
shaders_acquire :: proc(root,what:string,notice:proc(holder:string)=nil) -> (lock:Lock,ok:bool) {
    held:Lock
    build_folders_acquire(&held,root,what,notice,nil)
    lock,ok=lock_acquire(lock_path(root,SHADERS_LOCK,context.temp_allocator),what,notice)
    if ok {build_note(root,what)}
    lock.next=held.next
    return
}

// Whether a compilation that takes a turn ran at some moment since since:
// one holds it now or took it after since. A measurement starts once no
// compilation runs (measure_try, and the lock_wait of who takes MEASURE_LOCK),
// so one that took it before since ended before the measurement started.
builds_since :: proc(root:string,since:time.Time) -> bool {
    for path in build_paths(root) {
        if held,_,_:=lock_holder(path,context.temp_allocator);held {return true}
    }
    info,error:=os.stat(lock_path(root,BUILD_NOTE,context.temp_allocator),context.temp_allocator)
    return error==nil && time.diff(since,info.modification_time)>=0
}

// What a process does about the measurement that holds MEASURE_LOCK: Run when
// none does or it is part of it (this process, the measurement its MEASURE_ENV
// names, or part_of, a caller's MEASURE_ENV); else Wait for it to end when it
// would put work on the GPU (gpu), and Low, at low priority, when it uses
// none. holder: what the holder of MEASURE_LOCK wrote.
Measured :: enum u8 {Run,Low,Wait}

measured :: proc(root:string,gpu:bool,part_of:="",allocator:=context.allocator) -> (what:Measured,holder:string) {
    held,written,_:=lock_holder(lock_path(root,MEASURE_LOCK,context.temp_allocator),context.temp_allocator)
    if !held {return .Run,""}
    for pid in ([3]string{fmt.tprintf("%d",os.get_pid()),measurement(context.temp_allocator),part_of}) {
        if pid!="" && strings.has_prefix(written,fmt.tprintf("pid %s,",pid)) {return .Run,""}
    }
    if written=="" {written="a process that does not say which"}
    return gpu?.Wait:.Low,strings.clone(written,allocator)
}

// Waits while a measurement makes what puts work on the GPU wait (measured),
// at most limit (zero: no limit). notice runs once, with its holder; stop,
// asked while it waits, ends the wait. false when the limit or stop came
// first.
measurement_wait :: proc(root:string,part_of:="",notice:proc(holder:string)=nil,limit:=time.Duration(0),stop:proc(user:rawptr)->bool=nil,user:rawptr=nil) -> bool {
    start:=time.tick_now()
    noticed:=false
    for {
        what,holder:=measured(root,true,part_of,context.temp_allocator)
        if what!=.Wait {return true}
        if !noticed && notice!=nil {
            notice(holder)
            noticed=true
        }
        if limit>0 && time.tick_since(start)>=limit || stop!=nil && stop(user) {return false}
        time.sleep(250*time.Millisecond)
    }
}

// Whether the lock of path is held, what its holder wrote and when it took
// it. Not held when it is free or cannot be made, whatever an owner file left
// by a process that ended says.
lock_holder :: proc(path:string,allocator:=context.allocator) -> (held:bool,holder:string,since:time.Time) {
    handle,taken,failed:=lock_try(path)
    if taken {lock_close(handle)}
    if taken || failed {return}
    owner:=strings.concatenate({path,".owner"},context.temp_allocator)
    written,_:=os.read_entire_file(owner,context.temp_allocator)
    text:=strings.trim_space(string(written))
    if info,error:=os.stat(owner,context.temp_allocator);error==nil {since=info.modification_time}
    return true,strings.clone(text,allocator),since
}

// What a measurement that has not started waits for.
Measure_Wait :: enum u8 {None,Measurement,Build,Gpu}

// A wait of measure_try that has no limit.
MEASURE_WAIT_ALL :: time.Duration(1<<62)

// Starts a measurement that waits at most wait (zero: not at all): takes
// MEASURE_LOCK and then waits for the compilations that run and for the GPU
// work of others in flight (gpu_work); compilations that start later run at
// low priority, and GPU work waits for it to end (measured). notice runs once
// for each thing it waits for, with its holder. While it waits, the GPU turn
// this process holds says it is open and idle, as it says again how it was
// when it returns: the measurement that runs, or the one that waits for this
// one's GPU work, never waits for it. When the time runs out, why is what it
// waited for and holder who holds it. A lock that cannot be made
// does not stop it, nor does being part of a measurement that holds it, the
// one of this process (its MEASURE_ENV) or of the caller it measures for
// (part_of): lock is then not held.
measure_try :: proc(root,what:string,wait:=time.Duration(0),part_of:="",notice:proc(why:Measure_Wait,holder:string)=nil) -> (lock:Lock,ok:bool,holder:string,why:Measure_Wait) {
    if measurement_holds(root,measurement(context.temp_allocator)) || measurement_holds(root,part_of) {return {},true,"",.None}
    start:=time.tick_now()
    Waited :: struct {told:bit_set[Measure_Wait],idled,began:bool,root:string}
    waited:=Waited{root=root}
    defer if waited.idled {gpu_turn_mark(root,os.get_pid(),false)}
    tell :: proc(waited:^Waited,notice:proc(why:Measure_Wait,holder:string),why:Measure_Wait,holder:string) {
        if !waited.began {
            waited.began=true
            _,_,turn:=gpu_turn_owner(waited.root,os.get_pid(),-1)
            if turn!="" && !gpu_holder_open(turn) {waited.idled=gpu_turn_mark(waited.root,os.get_pid(),true)>=0}
        }
        if why in waited.told || notice==nil {return}
        notice(why,holder!=""?holder:"a process that does not say which")
        waited.told+={why}
    }
    measure_path:=lock_path(root,MEASURE_LOCK,context.temp_allocator)
    for {
        taken,failed:bool
        lock,taken,holder,failed=lock_take(measure_path,what)
        if failed {return {},true,"",.None}
        if taken {break}
        left:=wait-time.tick_since(start)
        if left<=0 {return {},false,holder,.Measurement}
        tell(&waited,notice,.Measurement,holder)
        lock_wait(measure_path,nil,left)
    }
    for build_path in build_paths(root) {
        for {
            build,taken,builder,failed:=lock_take(build_path,what)
            lock_release(&build)
            if taken || failed {break}
            left:=wait-time.tick_since(start)
            if left<=0 {
                lock_release(&lock)
                return {},false,builder,.Build
            }
            tell(&waited,notice,.Build,builder)
            lock_wait(build_path,nil,left)
        }
    }
    measurer:=fmt.tprintf("%d",os.get_pid())
    for {
        work:=gpu_work(root,measurer,context.temp_allocator)
        if len(work)==0 {break}
        if wait-time.tick_since(start)<=0 {
            lock_release(&lock)
            return {},false,work[0].holder,.Gpu
        }
        tell(&waited,notice,.Gpu,work[0].holder)
        time.sleep(250*time.Millisecond)
    }
    return lock,true,"",.None
}

@(private)
join :: proc(parts:..string) -> string {
    path,_:=os.join_path(parts,context.temp_allocator)
    return path
}

@(private)
slashes :: proc(path:string,allocator:=context.allocator) -> string {
    result,_:=strings.replace_all(path,"\\","/",allocator)
    return strings.clone(result,allocator) if raw_data(result)==raw_data(path) else result
}
