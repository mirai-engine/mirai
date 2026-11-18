package workspace

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// The processes that open a device of the GPU, from every checkout, share
// the memory of the card: each one holds a turn (gpu-<n>.lock) for as long as
// its device lives, and its owner says what it is charged: what it is expected
// to hold at most. A turn is given under GPU_ADMISSION_LOCK when the charges
// of those that hold one and its own fit the card, but for a part left to the
// desktop and the programs outside the turns (gpu_admits); the first one is
// always given. The charge of an editor is the peak of the last session of
// its project (gpu_peak, which the editor keeps), GPU_CHARGE_DEFAULT before
// one; a process with a device and no project is charged GPU_CHARGE_DEVICE.
// The memory of the card is what the last device opened said (gpu_memory,
// which the editor keeps), GPU_MEMORY_ASSUMED before one.
//
// The turn of a person (person) is taken without waiting and counts for the
// others; when every turn file is held it runs without one. Any other waits
// while a measurement it is not part of runs: what measures takes
// MEASURE_LOCK first and its GPU turns after it, and no holder of a GPU turn
// waits for MEASURE_LOCK without a limit, so the two never wait for each
// other. The turns of a measurement say so in their owner, and one of them
// is given beside the others of the same measurement when no one else holds
// a turn, also beyond the card: what it compares runs at once.
GPU_TURNS :: 8
GPU_ADMISSION_LOCK :: "gpu.lock"
GPU_MEMORY_ASSUMED :: i64(4)<<30
GPU_CHARGE_DEFAULT :: i64(3)<<30
GPU_CHARGE_DEVICE :: i64(1)<<30
// The card is left this part of its memory for what holds no turn.
GPU_RESERVE_PART :: 8
// The cache of what the devices said: GPU_MEMORY_FILE and the peaks by project.
GPU_FOLDER :: "gpu"
GPU_MEMORY_FILE :: "memory"
@(private)
GPU_CHARGE_SUFFIX :: " MiB of the GPU"
@(private)
GPU_MEASUREMENT_TAG :: ", measuring for pid "

// The file of a turn.
gpu_turn_path :: proc(root:string,turn:int,allocator:=context.allocator) -> string {
    return lock_path(root,fmt.tprintf("gpu-%d.lock",turn),allocator)
}

// What the holder of a turn writes: what, the measurement it is part of
// (its MEASURE_ENV; "" for none) and what it is charged.
gpu_holder_text :: proc(what:string,charge:i64,part_of:="",allocator:=context.temp_allocator) -> string {
    tag:=part_of!=""?strings.concatenate({GPU_MEASUREMENT_TAG,part_of},context.temp_allocator):""
    return fmt.aprintf("%s%s, %d%s",what,tag,max(charge,0)>>20,GPU_CHARGE_SUFFIX,allocator=allocator)
}

// The measurement a holder wrote it is part of; "" for none.
gpu_holder_measurement :: proc(holder:string) -> string {
    at:=strings.last_index(holder,GPU_MEASUREMENT_TAG)
    if at<0 {return ""}
    rest:=holder[at+len(GPU_MEASUREMENT_TAG):]
    end:=strings.index(rest,", ")
    return rest[:end] if end>=0 else rest
}

// The charge a holder wrote; false when it wrote none.
gpu_holder_charge :: proc(holder:string) -> (charge:i64,ok:bool) {
    if !strings.has_suffix(holder,GPU_CHARGE_SUFFIX) {return}
    text:=holder[:len(holder)-len(GPU_CHARGE_SUFFIX)]
    at:=strings.last_index(text,", ")
    if at<0 {return}
    mib:=strconv.parse_i64(text[at+2:]) or_return
    return mib<<20,mib>=0
}

// A turn that is held: what its holder wrote, its charge and since when.
Gpu_Holder :: struct {
    holder:string,
    charge:i64,
    since:time.Time,
}

// The turns held now. A holder that wrote no charge, as one that is just
// taking its turn, counts as GPU_CHARGE_DEFAULT.
gpu_holders :: proc(root:string,allocator:=context.allocator) -> []Gpu_Holder {
    holders:=make([dynamic]Gpu_Holder,allocator)
    for turn in 0..<GPU_TURNS {
        held,holder,since:=lock_holder(gpu_turn_path(root,turn,context.temp_allocator),allocator)
        if !held {continue}
        charge,charged:=gpu_holder_charge(holder)
        append(&holders,Gpu_Holder{holder,charged?charge:GPU_CHARGE_DEFAULT,since})
    }
    return holders[:]
}

// Bytes of the memory of the card, as the last device opened said it.
gpu_memory :: proc(root:string) -> (bytes:i64,known:bool) {
    return number_read(join(cache_folder(root,GPU_FOLDER,context.temp_allocator),GPU_MEMORY_FILE))
}

gpu_memory_write :: proc(root:string,bytes:i64) {
    if bytes<=0 {return}
    if said,_:=gpu_memory(root);said==bytes {return}
    number_write(join(cache_folder(root,GPU_FOLDER,context.temp_allocator),GPU_MEMORY_FILE),bytes)
}

// The file of the peak of the sessions of a project: by the project, which a
// copy of it under its .mirai/tmp/ shares.
gpu_peak_path :: proc(root,folder:string,allocator:=context.allocator) -> string {
    key:=slashes(folder,context.temp_allocator)
    if at:=strings.index(key,"/.mirai/tmp/");at>=0 {key=key[:at]}
    key=strings.trim_right(key,"/")
    when ODIN_OS==.Windows || ODIN_OS==.Darwin {key=strings.to_lower(key,context.temp_allocator)}
    name:=fmt.tprintf("%016x",hash.fnv64a(transmute([]u8)key))
    return slashes(join(cache_folder(root,GPU_FOLDER,context.temp_allocator),"peaks",name),allocator)
}

// The most memory of the card the last session of the project held.
gpu_peak :: proc(root,folder:string) -> (bytes:i64,known:bool) {
    return number_read(gpu_peak_path(root,folder,context.temp_allocator))
}

gpu_peak_write :: proc(root,folder:string,bytes:i64) {
    if bytes>0 {number_write(gpu_peak_path(root,folder,context.temp_allocator),bytes)}
}

// What a process with a device of the project at folder is charged; "" is
// one without a project.
gpu_charge :: proc(root,folder:string) -> i64 {
    if folder=="" {return GPU_CHARGE_DEVICE}
    if peak,known:=gpu_peak(root,folder);known {return peak}
    return GPU_CHARGE_DEFAULT
}

// Whether a turn charged charge may start on a card of memory bytes, beside
// the turns charged charges: they fit with the part left to the rest, or
// none is held.
gpu_admits :: proc(memory:i64,charges:[]i64,charge:i64) -> bool {
    if len(charges)==0 {return true}
    room:=memory-memory/GPU_RESERVE_PART-charge
    for each in charges {room-=each}
    return room>=0
}

// Why a turn is not taken: the measurement that runs, or the turns held.
Gpu_Wait :: struct {
    measurement:string, // who measures; "" when it is not that
    holders:[]Gpu_Holder,
    memory:i64,         // of the card, as admission took it
    memory_known:bool,
}

// Takes a turn when one is given now. what names the holder; a person takes
// one without the room for it, and part_of is the measurement this process
// is part of (its MEASURE_ENV; see above). A lock that cannot be made gives
// none and says nothing: the work goes on without it.
gpu_try :: proc(root,what:string,charge:i64,person:=false,part_of:="") -> (lock:Lock,taken:bool,waiting:Gpu_Wait) {
    if !person && part_of=="" {
        held,holder,_:=lock_holder(lock_path(root,MEASURE_LOCK,context.temp_allocator),context.temp_allocator)
        if held && !strings.has_prefix(holder,fmt.tprintf("pid %d,",os.get_pid())) {
            waiting.measurement=holder!=""?holder:"a process that does not say which"
            return
        }
    }
    admission,admitted:=lock_acquire(lock_path(root,GPU_ADMISSION_LOCK,context.temp_allocator),fmt.tprintf("pid %d, %s",os.get_pid(),what))
    if !admitted {return}
    defer lock_release(&admission)
    waiting.holders=gpu_holders(root,context.temp_allocator)
    memory,known:=gpu_memory(root)
    waiting.memory,waiting.memory_known=known?memory:GPU_MEMORY_ASSUMED,known
    charges:=make([]i64,len(waiting.holders),context.temp_allocator)
    alone:=part_of!=""
    for holder,i in waiting.holders {
        charges[i]=holder.charge
        alone&&=gpu_holder_measurement(holder.holder)==part_of
    }
    if !person && (len(waiting.holders)>=GPU_TURNS || !alone && !gpu_admits(waiting.memory,charges,charge)) {return}
    text:=gpu_holder_text(what,charge,part_of)
    for turn in 0..<GPU_TURNS {
        failed:bool
        lock,taken,_,failed=lock_take(gpu_turn_path(root,turn,context.temp_allocator),text)
        if taken || failed {break}
    }
    return
}

// Blocks until a turn is given and takes it (gpu_try). notice runs when what
// it waits for changes. A person never waits: ok is false when every turn
// file is held.
gpu_acquire :: proc(root,what:string,charge:i64,person:=false,notice:proc(waiting:Gpu_Wait)=nil) -> (lock:Lock,ok:bool) {
    told:=""
    part_of:=measurement(context.temp_allocator)
    for {
        taken:bool
        waiting:Gpu_Wait
        lock,taken,waiting=gpu_try(root,what,charge,person,part_of)
        if taken {return lock,true}
        if person {return}
        if waiting.measurement=="" && len(waiting.holders)==0 {return}
        b:=strings.builder_make(context.temp_allocator)
        strings.write_string(&b,waiting.measurement)
        for holder in waiting.holders {strings.write_string(&b,holder.holder)}
        if said:=strings.to_string(b);said!=told && notice!=nil {
            notice(waiting)
            told=strings.clone(said,context.temp_allocator)
        }
        time.sleep(250*time.Millisecond)
    }
}

// Names the holder of a turn again: the process that holds it now, as an
// editor started with it.
gpu_turn_rename :: proc(lock:^Lock,what:string,charge:i64) {
    if !lock.held {return}
    _=os.write_entire_file(lock.owner,transmute([]u8)gpu_holder_text(what,charge,measurement(context.temp_allocator)))
}

@(private)
number_read :: proc(path:string) -> (value:i64,known:bool) {
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {return}
    value,known=strconv.parse_i64(strings.trim_space(string(data)))
    return value,known && value>0
}

// Written whole and renamed into place: a reader never sees half of it.
@(private)
number_write :: proc(path:string,value:i64) {
    if os.make_directory_all(os.dir(path))!=nil && !os.is_dir(os.dir(path)) {return}
    staged:=fmt.tprintf("%s.%d.tmp",path,os.get_pid())
    if os.write_entire_file(staged,transmute([]u8)fmt.tprintf("%d\n",value))!=nil {return}
    if os.rename(staged,path)!=nil {_=os.remove(staged)}
}
