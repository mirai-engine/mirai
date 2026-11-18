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
// The card is what the devices opened said of it (gpu_card, which the editor
// keeps; gpu_card_said decides between them), GPU_MEMORY_ASSUMED before one.
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
// More than a card holds: a project never measured opens beside no other,
// since a guess below what it takes fills the card with the next one.
GPU_CHARGE_DEFAULT :: i64(1)<<40
GPU_CHARGE_DEVICE :: i64(1)<<30
// The card is left this part of its memory for what holds no turn.
GPU_RESERVE_PART :: 8
// The cache of what the devices said: GPU_CARD_FILE and the peaks by project.
GPU_FOLDER :: "gpu"
GPU_CARD_FILE :: "card"
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

// What a device said of the card it runs on: the bytes of the memory it keeps
// its resources in and whether that memory is its own (a discrete card) or
// the system's.
Gpu_Card :: struct {
    bytes:i64,
    own:bool,
    name:string, // of the adapter
}

@(private)
GPU_CARD_OWN :: "own"
@(private)
GPU_CARD_SHARED :: "shared"

// The card the turns divide, as gpu_card_write kept it.
gpu_card :: proc(root:string,allocator:=context.temp_allocator) -> (card:Gpu_Card,known:bool) {
    data,error:=os.read_entire_file(join(cache_folder(root,GPU_FOLDER,context.temp_allocator),GPU_CARD_FILE),context.temp_allocator)
    if error!=nil {return}
    bytes,_,rest:=strings.partition(strings.trim_space(string(data))," ")
    kind,_,name:=strings.partition(rest," ")
    card.bytes=strconv.parse_i64(bytes) or_return
    if card.bytes<=0 || kind!=GPU_CARD_OWN && kind!=GPU_CARD_SHARED || name=="" {return}
    return {card.bytes,kind==GPU_CARD_OWN,strings.clone(name,allocator)},true
}

// The memory of the card admission takes: the one kept, GPU_MEMORY_ASSUMED
// before one.
gpu_memory :: proc(root:string) -> (bytes:i64,known:bool) {
    card:Gpu_Card
    if card,known=gpu_card(root);!known {return GPU_MEMORY_ASSUMED,false}
    return card.bytes,true
}

// The card that is kept when a device says said beside the one kept: a
// card of its own over one that shares the memory of the system, and of two
// of the same kind the smaller, so that admission never takes the card for
// larger than a device said it is, whatever device said it last. refused
// says which of the two is not kept and why.
gpu_card_said :: proc(kept:Gpu_Card,known:bool,said:Gpu_Card) -> (card:Gpu_Card,refused:string) {
    GIB :: f64(1<<30)
    switch {
    case said.bytes<=0:
        return kept,fmt.tprintf("the device %s did not say the memory it keeps its resources in",said.name)
    case !known || !kept.own && said.own:
        return said,""
    case kept.own && !said.own:
        return kept,fmt.tprintf("the GPU turns divide the card %s (%.1f GiB), not %s, which shares the memory of the system: set MIRAI_GPU so that the editors run on the card",kept.name,f64(kept.bytes)/GIB,said.name)
    case said.bytes>kept.bytes:
        return kept,fmt.tprintf("%s said %.1f GiB, more than the %.1f GiB that %s said; the GPU turns keep the smaller",said.name,f64(said.bytes)/GIB,f64(kept.bytes)/GIB,kept.name)
    case said.bytes<kept.bytes:
        return said,fmt.tprintf("%s said %.1f GiB before, more than the %.1f GiB that %s says; the GPU turns keep the smaller",kept.name,f64(kept.bytes)/GIB,f64(said.bytes)/GIB,said.name)
    }
    return kept,""
}

// Keeps what a device said of the card by gpu_card_said, under
// GPU_ADMISSION_LOCK so that two that say it at once both count; refused is
// what gpu_card_said refused.
gpu_card_write :: proc(root:string,said:Gpu_Card) -> (refused:string) {
    admission,admitted:=lock_acquire(lock_path(root,GPU_ADMISSION_LOCK,context.temp_allocator),fmt.tprintf("pid %d, the card %s",os.get_pid(),said.name))
    if !admitted {return}
    defer lock_release(&admission)
    kept,known:=gpu_card(root)
    card:Gpu_Card
    card,refused=gpu_card_said(kept,known,said)
    if card.bytes<=0 || known && card.bytes==kept.bytes && card.own==kept.own && card.name==kept.name {return}
    text:=fmt.tprintf("%d %s %s\n",card.bytes,card.own?GPU_CARD_OWN:GPU_CARD_SHARED,card.name)
    text_write(join(cache_folder(root,GPU_FOLDER,context.temp_allocator),GPU_CARD_FILE),text)
    return
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
    if bytes>0 {text_write(gpu_peak_path(root,folder,context.temp_allocator),fmt.tprintf("%d\n",bytes))}
}

// Whether a device holds so close to what the driver lets it hold (budget)
// that the driver may be keeping some of what it wants out of the card: what
// it holds then is less than what it needs.
gpu_pressed :: proc(used,budget:i64) -> bool {
    return budget>0 && budget-used<budget/GPU_RESERVE_PART
}

// What the end of a session keeps of its peak: what it held, also below the
// peak kept, unless the card pressed it at some point (gpu_pressed): then
// what it held does not lower the charge.
gpu_peak_end :: proc(root,folder:string,peak:i64,pressed:bool) {
    if kept,known:=gpu_peak(root,folder);pressed && known && kept>=peak {return}
    gpu_peak_write(root,folder,peak)
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
    waiting.memory,waiting.memory_known=gpu_memory(root)
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

// Names the process `to` the holder of the turns held by process `from`,
// which hands them to it: an editor that starts again as another.
gpu_turn_follow :: proc(root:string,from,to:int) {
    prefix:=fmt.tprintf("pid %d, ",from)
    for turn in 0..<GPU_TURNS {
        path:=gpu_turn_path(root,turn,context.temp_allocator)
        held,holder,_:=lock_holder(path,context.temp_allocator)
        if !held || !strings.has_prefix(holder,prefix) {continue}
        text:=fmt.tprintf("pid %d, %s",to,holder[len(prefix):])
        _=os.write_entire_file(strings.concatenate({path,".owner"},context.temp_allocator),transmute([]u8)text)
    }
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
text_write :: proc(path,text:string) {
    if os.make_directory_all(os.dir(path))!=nil && !os.is_dir(os.dir(path)) {return}
    staged:=fmt.tprintf("%s.%d.tmp",path,os.get_pid())
    if os.write_entire_file(staged,transmute([]u8)text)!=nil {return}
    if os.rename(staged,path)!=nil {_=os.remove(staged)}
}
