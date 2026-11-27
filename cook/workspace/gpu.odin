package workspace

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:project"
import "mirai:std/subprocess"

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
// memory of the others; when every turn file is held it runs without one. Any
// other waits while a measurement it is not part of runs (measured), and is
// given a turn only while no other program a person does not run holds one
// (GPU_AGENTS). The others wait in a queue, first come first served
// (GPU_QUEUE). The turns of a measurement say so in their owner, and one of
// them is given beside the others of the same measurement when no one else
// holds a turn, also beyond the card: what it compares runs at once.
//
// A turn says whether its holder puts work on the GPU now or stays open
// idle (GPU_OPEN_TAG): a test, a player or an editor that starts or runs a
// call that draws works, and a measurement waits for it before it times
// (gpu_work); a session that waits for calls and the editor or player of a
// person are open, and a measurement only says that they load the GPU
// (gpu_load).
GPU_TURNS :: 8
// The turns given at once to programs no person runs, but those of one
// measurement: GPU work beside a test that times itself, a capture or a
// measurement changes what it gives.
GPU_AGENTS :: 1
// The folder of the tickets of the queue: a lock each waiter holds while it
// waits, named by when it came, so that the names sort in its order. A ticket
// no process holds is of a waiter that ended: it is skipped and removed.
GPU_QUEUE :: "gpu-queue"
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
@(private)
GPU_HELD_TAG :: ", held "
@(private)
GPU_HELD_SUFFIX :: " MiB at most"
@(private)
GPU_OPEN_TAG :: ", open and idle"
@(private)
GPU_PERSON_TAG :: ", of a person"

// The file of a turn.
gpu_turn_path :: proc(root:string,turn:int,allocator:=context.allocator) -> string {
    return lock_path(root,fmt.tprintf("gpu-%d.lock",turn),allocator)
}

// What the holder of a turn writes: what, whether a person runs it, the
// measurement it is part of (its MEASURE_ENV; "" for none), whether it is
// open and idle, what it is charged and the most it held (0 before it says).
gpu_holder_text :: proc(what:string,charge:i64,part_of:="",held:=i64(0),open:=false,person:=false,allocator:=context.temp_allocator) -> string {
    tag:=part_of!=""?strings.concatenate({GPU_MEASUREMENT_TAG,part_of},context.temp_allocator):""
    return gpu_owner_text(strings.concatenate({what,person?GPU_PERSON_TAG:"",tag,open?GPU_OPEN_TAG:""},context.temp_allocator),charge,held,allocator)
}

// The owner text of what (with its tags), its charge and the most it held.
@(private)
gpu_owner_text :: proc(what:string,charge,held:i64,allocator:=context.temp_allocator) -> string {
    if held>0 {return fmt.aprintf("%s, %d%s%s%d%s",what,max(charge,0)>>20,GPU_CHARGE_SUFFIX,GPU_HELD_TAG,held>>20,GPU_HELD_SUFFIX,allocator=allocator)}
    return fmt.aprintf("%s, %d%s",what,max(charge,0)>>20,GPU_CHARGE_SUFFIX,allocator=allocator)
}

// Whether a holder wrote that it is open and idle.
gpu_holder_open :: proc(holder:string) -> bool {
    what,_,_,ok:=gpu_holder_parse(holder)
    return ok && strings.has_suffix(what,GPU_OPEN_TAG)
}

// What a holder wrote, in parts: what it is with its measurement, its charge
// and the most it held; ok is false when it wrote no charge.
gpu_holder_parse :: proc(holder:string) -> (what:string,charge,held:i64,ok:bool) {
    text:=holder
    if strings.has_suffix(text,GPU_HELD_SUFFIX) {
        if at:=strings.last_index(text,GPU_HELD_TAG);at>=0 {
            mib,parsed:=strconv.parse_i64(text[at+len(GPU_HELD_TAG):len(text)-len(GPU_HELD_SUFFIX)])
            if !parsed || mib<0 {return}
            text,held=text[:at],mib<<20
        }
    }
    if !strings.has_suffix(text,GPU_CHARGE_SUFFIX) {return}
    text=text[:len(text)-len(GPU_CHARGE_SUFFIX)]
    at:=strings.last_index(text,", ")
    if at<0 {return}
    mib:=strconv.parse_i64(text[at+2:]) or_return
    return text[:at],mib<<20,held,mib>=0
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
    _,charge,_,ok=gpu_holder_parse(holder)
    return
}

// A turn that is held: what its holder wrote, its charge, the most it held,
// since when, whether it is open and idle and whether a person runs it.
Gpu_Holder :: struct {
    holder:string,
    charge:i64,
    held:i64,
    since:time.Time,
    open:bool,
    person:bool,
}

// The turns held now. A holder that wrote no charge, as one that is just
// taking its turn, counts as GPU_CHARGE_DEFAULT and works.
gpu_holders :: proc(root:string,allocator:=context.allocator) -> []Gpu_Holder {
    holders:=make([dynamic]Gpu_Holder,allocator)
    for turn in 0..<GPU_TURNS {
        taken,holder,since:=lock_holder(gpu_turn_path(root,turn,context.temp_allocator),allocator)
        if !taken {continue}
        what,charge,held,charged:=gpu_holder_parse(holder)
        append(&holders,Gpu_Holder{holder,charged?charge:GPU_CHARGE_DEFAULT,held,since,charged && strings.has_suffix(what,GPU_OPEN_TAG),strings.contains(what,GPU_PERSON_TAG)})
    }
    return holders[:]
}

// The GPU work in flight a measurement waits for before it times: the turns
// that work (not open), of no process measurer names (a pid) nor of its
// measurement.
gpu_work :: proc(root,measurer:string,allocator:=context.allocator) -> []Gpu_Holder {
    work:=make([dynamic]Gpu_Holder,allocator)
    own:=fmt.tprintf("pid %s, ",measurer)
    for holder in gpu_holders(root,allocator) {
        if holder.open || strings.has_prefix(holder.holder,own) || gpu_holder_measurement(holder.holder)==measurer {continue}
        append(&work,holder)
    }
    return work[:]
}

// The owner file of the turn process pid is named the holder of, looked for
// first at turn (where it was before; -1 for none), and what it says; at is
// -1 while none names pid.
@(private)
gpu_turn_owner :: proc(root:string,pid:int,turn:int) -> (at:int,owner,holder:string) {
    prefix:=fmt.tprintf("pid %d, ",pid)
    for i in -1..<GPU_TURNS {
        at=i<0?turn:i
        if at<0 || at>=GPU_TURNS || i>=0 && at==turn {continue}
        owner=strings.concatenate({gpu_turn_path(root,at,context.temp_allocator),".owner"},context.temp_allocator)
        data,error:=os.read_entire_file(owner,context.temp_allocator)
        holder=strings.trim_space(string(data))
        if error==nil && strings.has_prefix(holder,prefix) {return}
    }
    return -1,"",""
}

// Writes an owner file again, keeping its time: it says since when the turn is held.
@(private)
gpu_owner_rewrite :: proc(owner,text:string) {
    info,stated:=os.stat(owner,context.temp_allocator)
    text_write(owner,text,stated==nil?info.modification_time:nil)
}

// What the holder of a turn says while it runs: the most it held, which
// raises its charge when it passes it and never lowers it, so that the next
// admission counts what it really takes. The turn is the one process pid is
// named the holder of (gpu_turn_owner); found is where it is, -1 while none
// names pid.
gpu_turn_raise :: proc(root:string,pid:int,held:i64,turn:=-1) -> (found:int) {
    owner,holder:string
    found,owner,holder=gpu_turn_owner(root,pid,turn)
    if found<0 {return}
    if what,charge,said,ok:=gpu_holder_parse(holder);ok && held>>20>said>>20 {
        gpu_owner_rewrite(owner,gpu_owner_text(what,max(charge,held),held))
    }
    return
}

// What the holder of a turn says when it starts or stops putting work on the
// GPU: open, it stays open and idle and no measurement waits for it. The turn
// is found as gpu_turn_raise finds it.
gpu_turn_mark :: proc(root:string,pid:int,open:bool,turn:=-1) -> (found:int) {
    owner,holder:string
    found,owner,holder=gpu_turn_owner(root,pid,turn)
    if found<0 {return}
    what,charge,held,ok:=gpu_holder_parse(holder)
    bare:=strings.trim_suffix(what,GPU_OPEN_TAG)
    if ok && (bare!=what)!=open {
        gpu_owner_rewrite(owner,gpu_owner_text(strings.concatenate({bare,open?GPU_OPEN_TAG:""},context.temp_allocator),charge,held))
    }
    return
}

// What the holders held at most beyond what the card has for the turns (its
// memory less the part left to the rest); 0 when they fit.
gpu_held_over :: proc(memory:i64,holders:[]Gpu_Holder) -> i64 {
    held:i64
    for holder in holders {held+=holder.held}
    return max(held-(memory-memory/GPU_RESERVE_PART),0)
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

// Why a program no person watches must not run on the adapter device it
// opened: the turns account for a card of its own memory and it opened on
// another one that MIRAI_GPU (preferred) did not name. "" when it may.
gpu_off_card :: proc(card:Gpu_Card,known:bool,device,preferred:string) -> (problem:string) {
    if !known || !card.own || device=="" || device==card.name {return}
    if preferred!="" && strings.contains(strings.to_lower(device,context.temp_allocator),strings.to_lower(preferred,context.temp_allocator)) {return}
    return fmt.tprintf("it opened on %s, not on the card %s that the GPU turns account for: Vulkan does not offer that card now (lost, or its driver resetting), and on another adapter frames take seconds and what is measured means nothing. Restart the machine until mirai doctor --probe-gpu names %s, or set MIRAI_GPU to a part of the name %q to run there anyway",device,card.name,card.name,device)
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
// copy of it under its .mirai/tmp/ and another git worktree of its repository
// share.
gpu_peak_path :: proc(root,folder:string,allocator:=context.allocator) -> string {
    key:=slashes(folder,context.temp_allocator)
    if at:=strings.index(key,"/.mirai/tmp/");at>=0 {key=key[:at]}
    key=strings.trim_right(key,"/")
    for at:=key;at!=""; {
        if os.exists(join(at,".git")) {
            shared:=strings.trim_right(project.shared_root(at,context.temp_allocator),"/")
            if !project.path_same(shared,at) {
                key=strings.concatenate({shared,key[len(at):]},context.temp_allocator)
            }
            break
        }
        slash:=strings.last_index_byte(at,'/')
        if slash<=0 || (slash==2 && at[1]==':') {break}
        at=at[:slash]
    }
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

// Why a turn is not taken: the measurement that runs, the turns held or the
// waiters that came first.
Gpu_Wait :: struct {
    measurement:string, // who measures; "" when it is not that
    holders:[]Gpu_Holder,
    ahead:[]string,     // what the waiters that came first wrote, in their order
    memory:i64,         // of the card, as admission took it
    memory_known:bool,
    refused:Gpu_Refused,
}

// Why a turn is refused rather than waited for: the room is held by what
// waits for the command to end (Own: its process, an ancestor of it or the
// session of its project), or the time it was given passed (Limit).
Gpu_Refused :: enum u8 {None,Own,Limit}

// Takes a turn when one is given now. what names the holder; a person takes
// one without the room for it and stays open, and part_of is the measurement
// this process is part of (its MEASURE_ENV; see above). A lock that cannot be
// made gives none and says nothing: the work goes on without it.
gpu_try :: proc(root,what:string,charge:i64,person:=false,part_of:="") -> (lock:Lock,taken:bool,waiting:Gpu_Wait) {
    if !person {
        if running,holder:=measured(root,true,part_of,context.temp_allocator);running==.Wait {
            waiting.measurement=holder
            return
        }
    }
    admission,admitted:=lock_acquire(lock_path(root,GPU_ADMISSION_LOCK,context.temp_allocator),fmt.tprintf("pid %d, %s",os.get_pid(),what))
    if !admitted {return}
    defer lock_release(&admission)
    waiting.holders=gpu_holders(root,context.temp_allocator)
    waiting.memory,waiting.memory_known=gpu_memory(root)
    if !person && !gpu_room(waiting.holders,waiting.memory,charge,part_of) {return}
    text:=gpu_holder_text(what,charge,part_of,open=person,person=person)
    for turn in 0..<GPU_TURNS {
        failed:bool
        lock,taken,_,failed=lock_take(gpu_turn_path(root,turn,context.temp_allocator),text)
        if taken || failed {break}
    }
    return
}

// Whether a turn charged charge fits beside holders on a card of memory
// bytes: a turn free, fewer than GPU_AGENTS holders a person does not run
// and the room for it, or every holder part of the same measurement
// (part_of).
@(private)
gpu_room :: proc(holders:[]Gpu_Holder,memory,charge:i64,part_of:string) -> bool {
    charges:=make([]i64,len(holders),context.temp_allocator)
    alone:=part_of!=""
    agents:=0
    for holder,i in holders {
        charges[i]=holder.charge
        same:=part_of!="" && gpu_holder_measurement(holder.holder)==part_of
        alone&&=same
        if !same && !holder.person {agents+=1}
    }
    return len(holders)<GPU_TURNS && (alone || agents<GPU_AGENTS && gpu_admits(memory,charges,charge))
}

// Joins the queue: a ticket named by now, held until it is dropped
// (gpu_ticket_drop). Not held when the lock cannot be made: it waits unseen.
@(private)
gpu_ticket_take :: proc(root,what:string) -> (ticket:Lock,name:string) {
    name=fmt.tprintf("%019d-%d.lock",time.time_to_unix_nano(time.now()),os.get_pid())
    ticket,_,_,_=lock_take(lock_path(root,join(GPU_QUEUE,name),context.temp_allocator),what)
    return
}

@(private)
gpu_ticket_drop :: proc(ticket:^Lock) {
    if !ticket.held {return}
    path:=strings.trim_suffix(strings.clone(ticket.owner,context.temp_allocator),".owner")
    lock_release(ticket)
    _=os.remove(path)
}

// What the waiters whose tickets sort before name wrote, in their order. The
// ticket of one that ended is removed once it is a second old: a younger one
// may be of a waiter that is just taking it.
@(private)
gpu_queue_ahead :: proc(root,name:string) -> []string {
    folder:=lock_path(root,GPU_QUEUE,context.temp_allocator)
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    ahead:=make([dynamic]string,context.temp_allocator)
    for entry in entries {
        if !strings.has_suffix(entry.name,".lock") || entry.name>=name {continue}
        path:=join(folder,entry.name)
        if held,holder,_:=lock_holder(path,context.temp_allocator);held {
            append(&ahead,holder)
        } else if time.diff(entry.modification_time,time.now())>time.Second {
            _=os.remove(path)
        }
    }
    return ahead[:]
}

// The holders that wait for a command to end, so that waiting for them does
// not give it room: those of the processes of own (it and its ancestors) and
// the session or editor of its project folder.
gpu_own :: proc(holders:[]Gpu_Holder,own:[]int,folder:string,allocator:=context.temp_allocator) -> []Gpu_Holder {
    list:=make([dynamic]Gpu_Holder,allocator)
    for holder in holders {
        mine:=false
        for pid in own {mine||=strings.has_prefix(holder.holder,fmt.tprintf("pid %d, ",pid))}
        if folder!="" {
            key:=slashes(folder,context.temp_allocator)
            for at:=strings.index(holder.holder,key);at>=0 && !mine; {
                end:=at+len(key)
                mine=end==len(holder.holder) || holder.holder[end]==',' || holder.holder[end]==' '
                next:=strings.index(holder.holder[end:],key)
                at=next<0?-1:end+next
            }
        }
        if mine {append(&list,holder)}
    }
    return list[:]
}

// This process and those above it, nearest first.
process_lineage :: proc(allocator:=context.temp_allocator) -> []int {
    list:=make([dynamic]int,allocator)
    for pid:=os.get_pid();pid>0 && len(list)<64 && !slice.contains(list[:],pid); {
        append(&list,pid)
        info,error:=os.process_info_by_pid(pid,{.PPid},context.temp_allocator)
        if error!=nil {break}
        pid=info.ppid
    }
    return list[:]
}

// Blocks until a turn is given and takes it (gpu_try), at most limit (zero:
// no limit), after the waiters that came first (GPU_QUEUE). notice runs once
// with who holds the room and who waits before it, and again when they or
// their charges change. A person never waits: ok is false when every turn
// file is held. Nor does what waiting would not help (Gpu_Refused.Own: the
// room is held by holders gpu_own names for its project folder), nor what
// waited limit: ok is false and refused says why and who holds it. A turn of
// a measurement that already holds one does not queue: those before it may
// wait for it.
gpu_acquire :: proc(root,what:string,charge:i64,person:=false,notice:proc(waiting:Gpu_Wait)=nil,limit:=time.Duration(0),folder:="") -> (lock:Lock,ok:bool,refused:Gpu_Wait) {
    told:=""
    part_of:=measurement(context.temp_allocator)
    lineage:=process_lineage()
    start:=time.tick_now()
    queued:=!person
    for holder in gpu_holders(root,context.temp_allocator) {
        if part_of!="" && gpu_holder_measurement(holder.holder)==part_of {queued=false}
    }
    ticket:Lock
    name:string
    if queued {ticket,name=gpu_ticket_take(root,what)}
    defer gpu_ticket_drop(&ticket)
    for {
        taken:bool
        waiting:Gpu_Wait
        if queued {waiting.ahead=gpu_queue_ahead(root,name)}
        if len(waiting.ahead)==0 {
            lock,taken,waiting=gpu_try(root,what,charge,person,part_of)
            if taken {return lock,true,{}}
            if person {return}
            if waiting.measurement=="" && len(waiting.holders)==0 {return}
        } else {
            waiting.holders=gpu_holders(root,context.temp_allocator)
            waiting.memory,waiting.memory_known=gpu_memory(root)
        }
        if waiting.measurement=="" && !gpu_room(gpu_own(waiting.holders,lineage,folder),waiting.memory,charge,part_of) {
            waiting.refused=.Own
            return {},false,waiting
        }
        if limit>0 && time.tick_since(start)>=limit {
            waiting.refused=.Limit
            return {},false,waiting
        }
        // Who holds it and their charges: not what they held nor whether they draw now.
        b:=strings.builder_make(context.temp_allocator)
        strings.write_string(&b,waiting.measurement)
        for holder in waiting.holders {
            what_,_,_,_:=gpu_holder_parse(holder.holder)
            fmt.sbprintf(&b,"%s %d;",strings.trim_suffix(what_,GPU_OPEN_TAG),holder.charge)
        }
        for waiter in waiting.ahead {fmt.sbprintf(&b,"%s;",waiter)}
        if said:=strings.to_string(b);said!=told && notice!=nil {
            notice(waiting)
            told=strings.clone(said,context.temp_allocator)
        }
        time.sleep(250*time.Millisecond)
    }
}

// Names the holder of a turn again: the process that holds it now, as an
// editor started with it. It stays open or working, and of a person, as it was.
gpu_turn_rename :: proc(lock:^Lock,what:string,charge:i64) {
    if !lock.held {return}
    before,_:=os.read_entire_file(lock.owner,context.temp_allocator)
    open:=gpu_holder_open(strings.trim_space(string(before)))
    person:=strings.contains(string(before),GPU_PERSON_TAG)
    _=os.write_entire_file(lock.owner,transmute([]u8)gpu_holder_text(what,charge,measurement(context.temp_allocator),open=open,person=person))
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

// An editor or a player of the engine that runs.
Engine_Program :: struct {pid:int,path,command:string}

// The editors and players of the engine that run, but those of own and this
// process: one that draws loads the GPU and holds its memory.
engine_programs :: proc(own:[]int,allocator:=context.temp_allocator) -> []Engine_Program {
    list:=make([dynamic]Engine_Program,allocator)
    pids,error:=os.process_list(context.temp_allocator)
    if error!=nil {return nil}
    for pid in pids {
        if pid==os.get_pid() || slice.contains(own,pid) {continue}
        info,info_error:=os.process_info_by_pid(pid,{.Executable_Path},context.temp_allocator)
        if info_error!=nil || info.executable_path=="" {continue}
        name:=strings.to_lower(strings.trim_suffix(os.base(slashes(info.executable_path,context.temp_allocator)),project.EXECUTABLE_SUFFIX),context.temp_allocator)
        if name!="mirai-editor" && name!="mirai-player" {continue}
        program:=Engine_Program{pid=pid,path=strings.clone(info.executable_path,allocator)}
        program.command=program.path
        if full,full_error:=os.process_info_by_pid(pid,{.Command_Line},context.temp_allocator);full_error==nil && full.command_line!="" {program.command=strings.clone(full.command_line,allocator)}
        append(&list,program)
    }
    return list[:]
}

// The percent of the GPU in use while what measures draws nothing from which
// another program loads it: a desktop on a 4K display alone keeps it at 10-15.
GPU_LOAD_BUSY :: 25

// What else loads the GPU while what measures draws nothing, added to
// warnings after when_: with programs, the other programs of the engine but
// those of own, sessions other agents keep open among them; with nvidia-smi,
// how busy the GPU is, whatever program loads it. loaded: it was busy, and a
// time measured meanwhile does not count.
gpu_load :: proc(warnings:^[dynamic]string,own:[]int,when_:string,programs:bool) -> (loaded:bool) {
    if programs {
        for program in engine_programs(own) {
            append(warnings,fmt.aprintf("%s: another program of the engine is open (pid %d, %s): it loads the GPU when it draws and holds its memory",when_,program.pid,program.path))
        }
    }
    total,samples:=0,0
    for _ in 0..<10 {
        state,stdout,_,error:=subprocess.exec({command={"nvidia-smi","--query-gpu=utilization.gpu","--format=csv,noheader,nounits"}},context.temp_allocator)
        if error!=nil || state.exit_code!=0 {break}
        line:=strings.trim_space(string(stdout))
        if cut:=strings.index_byte(line,'\n');cut>=0 {line=strings.trim_space(line[:cut])}
        busy,valid:=strconv.parse_int(line,10)
        if !valid {break}
        total+=busy
        samples+=1
        time.sleep(200*time.Millisecond)
    }
    switch {
    case samples==0:
        note:="no nvidia-smi: whether another program uses the GPU was not measured"
        if !slice.contains(warnings[:],note) {append(warnings,note)}
    case total/samples>=GPU_LOAD_BUSY:
        append(warnings,fmt.aprintf("%s: the GPU was %d %% busy while nothing measured drew: another program uses it and the measurement does not count",when_,total/samples))
        loaded=true
    }
    return
}

@(private)
number_read :: proc(path:string) -> (value:i64,known:bool) {
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {return}
    value,known=strconv.parse_i64(strings.trim_space(string(data)))
    return value,known && value>0
}

// Written whole and renamed into place: a reader never sees half of it, nor
// another time than modified when one is given.
@(private)
text_write :: proc(path,text:string,modified:Maybe(time.Time)=nil) {
    if os.make_directory_all(os.dir(path))!=nil && !os.is_dir(os.dir(path)) {return}
    staged:=fmt.tprintf("%s.%d.tmp",path,os.get_pid())
    file,opened:=os.open(staged,{.Write,.Create,.Trunc},os.Permissions_Read_All+{.Write_User})
    if opened!=nil {return}
    _,error:=os.write(file,transmute([]u8)text)
    // fchtimes_whole_nanoseconds: os.change_times keeps only microseconds on macOS.
    if at,given:=modified.?;given && error==nil {error=os.fchange_times(file,at,at)}
    if closed:=os.close(file);error==nil {error=closed}
    if error!=nil || os.rename(staged,path)!=nil {_=os.remove(staged)}
}
