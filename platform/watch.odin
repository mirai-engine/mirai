package platform

import "mirai:std/base"

// File watching by polling, the same on every system: a watch walks its
// folder a few entries per call, remembers the size and modification time of
// every file and reports what differs from the previous pass. How a folder is
// listed belongs to the system (watch_windows.odin, watch_posix.odin), and so
// does telling that nothing under it changed since the last pass: where the
// system can, a pass over a quiet folder walks nothing.

Watch :: distinct base.Handle

Watch_Desc :: struct {
    path:string,
    recursive:bool,
    hidden:bool,          // also names that start with a dot; they are skipped otherwise, folders included
    report_existing:bool, // report the files that were already there as Created
    file_capacity:int,    // files remembered; 4096 when zero
    path_bytes:int,       // bytes of their relative paths, plus two per file; 66 per file when zero
}
Watch_Error :: enum u8 {None,Capacity_Exhausted,Not_Found,Out_Of_Memory}
Watch_Event_Kind :: enum u8 {Created,Changed,Removed}
// path is relative to the watched folder, with forward slashes. It is valid
// until the next watch_poll of the same watch.
Watch_Event :: struct {kind:Watch_Event_Kind,path:string}
Watch_Stats :: struct {
    files:int,      // files remembered now
    passes:u64,     // complete passes over the folder
    quiet:u64,      // of those, the ones that walked nothing: the system told that nothing had changed
    untracked:u64,  // files seen that did not fit in the capacities, counted once per pass that walked
    too_deep:u64,   // folders below WATCH_DEPTH levels, not entered
}

WATCH_DEPTH :: 32
WATCH_PATH_BYTES :: 1024 // longest path of a watched file, root included
// The budget of a poll is counted in files listed. Opening a folder costs
// the system about as much as listing this many of them, and sweeping this
// many slots of the file table, which only reads memory, about as much as one.
WATCH_FOLDER_COST :: 64
WATCH_SWEEP_PER_UNIT :: 64

@(private)
Dir_Entry :: struct {name:string,directory:bool,size:u64,modified:i64}

@(private)
Watch_File :: struct {
    hash:u64,
    offset:u32, // of its relative path in text
    length:u16, // 0: empty slot
    pass:u16,   // low bits of the pass that last saw it
    size:u64,
    modified:i64,
}
@(private)
Watch_Level :: struct {iterator:Dir_Iterator,relative_length:int}
@(private)
Watch_Phase :: enum u8 {Idle,Walk,Sweep}
@(private)
Watch_Slot :: struct {
    generation:u32,
    used:bool,
    recursive,hidden,report_existing:bool,
    files:[]Watch_File, // open addressing, a power of two at most half full
    file_count,file_capacity:int,
    text:[]u8,text_used,text_dead:int,
    path:[WATCH_PATH_BYTES]u8,root_length,path_length:int, // root, a slash, and the folder or file being visited
    levels:[WATCH_DEPTH]Watch_Level,depth:int,
    phase:Watch_Phase,
    pass:u64,
    first_pass:bool,
    sweep:int,
    // An entry already read from its folder that could not be finished in the last poll.
    held:bool,held_entry:Dir_Entry,held_name:[WATCH_PATH_BYTES]u8,
    compact:bool,
    notify:Dir_Notify,
    notified:bool, // the system tells when something under the folder changes
    stats:Watch_Stats,
}
@(private)
Watch_Table :: struct {slots:[]Watch_Slot}

@(private)
watch_table_init :: proc(p:^Platform,capacity:int) -> bool {
    slots,error:=make([]Watch_Slot,capacity,p.allocator)
    if error!=nil {return false}
    for &slot in slots {slot.generation=1}
    p.watches.slots=slots
    return true
}
@(private)
watch_table_destroy :: proc(p:^Platform) {
    for &slot in p.watches.slots {
        if slot.used {watch_slot_destroy(p,&slot)}
    }
    delete(p.watches.slots,p.allocator)
    p.watches.slots=nil
}
@(private)
watch_slot :: proc(p:^Platform,watch:Watch) -> ^Watch_Slot {
    index:=base.handle_index(base.Handle(watch))
    if watch==0 || int(index)>=len(p.watches.slots) {return nil}
    slot:=&p.watches.slots[index]
    if !slot.used || slot.generation!=base.handle_generation(base.Handle(watch)) {return nil}
    return slot
}

watch_create :: proc(p:^Platform,desc:Watch_Desc) -> (watch:Watch,error:Watch_Error) {
    if desc.path=="" || len(desc.path)+2>=WATCH_PATH_BYTES {return 0,.Not_Found}
    index:=-1
    for slot,i in p.watches.slots {
        if !slot.used {index=i;break}
    }
    if index<0 {p.stats.watches_exhausted+=1;return 0,.Capacity_Exhausted}
    probe:Dir_Iterator
    if !dir_open(&probe,desc.path) {return 0,.Not_Found}
    dir_close(&probe)
    w:=&p.watches.slots[index]
    generation:=w.generation
    w^={generation=generation,used=true,recursive=desc.recursive,hidden=desc.hidden,report_existing=desc.report_existing,first_pass=true}
    w.file_capacity=desc.file_capacity if desc.file_capacity>0 else 4096
    slots:=4
    for slots<w.file_capacity*2 {slots*=2}
    files,files_error:=make([]Watch_File,slots,p.allocator)
    text,text_error:=make([]u8,desc.path_bytes if desc.path_bytes>0 else w.file_capacity*66,p.allocator)
    if files_error!=nil || text_error!=nil {
        delete(files,p.allocator);delete(text,p.allocator)
        w^={generation=generation}
        return 0,.Out_Of_Memory
    }
    w.files=files;w.text=text
    w.root_length=copy(w.path[:],desc.path)
    for w.root_length>1 && (w.path[w.root_length-1]=='/' || w.path[w.root_length-1]=='\\') {w.root_length-=1}
    w.path[w.root_length]='/'
    w.root_length+=1
    w.path_length=w.root_length
    return Watch(base.handle_make(u32(index),generation)),.None
}
watch_destroy :: proc(p:^Platform,watch:Watch) {
    if w:=watch_slot(p,watch);w!=nil {watch_slot_destroy(p,w)}
}
@(private)
watch_slot_destroy :: proc(p:^Platform,w:^Watch_Slot) {
    for i in 0..<w.depth {dir_close(&w.levels[i].iterator)}
    if w.notified {dir_notify_close(&w.notify)}
    delete(w.files,p.allocator);delete(w.text,p.allocator)
    w^={generation=w.generation+1}
}
watch_stats :: proc(p:^Platform,watch:Watch) -> Watch_Stats {
    w:=watch_slot(p,watch)
    if w==nil {return {}}
    w.stats.files=w.file_count
    return w.stats
}

// Advances the scan by budget units (a file listed is one, a folder opened
// WATCH_FOLDER_COST) and writes what it found to events. It stops early when events is full, so nothing is lost: the
// next call goes on from there. pass_complete is true on the call that
// finishes a pass over the whole folder, removed files included.
watch_poll :: proc(p:^Platform,watch:Watch,budget:int,events:[]Watch_Event) -> (count:int,pass_complete:bool) {
    w:=watch_slot(p,watch)
    if w==nil {return 0,false}
    if w.compact {watch_compact(w)}
    left:=budget
    for left>0 && count<len(events) {
        switch w.phase {
        case .Idle:
            if w.notified {
                changed:bool
                changed,w.notified=dir_notify_take(&w.notify)
                if !w.notified {dir_notify_close(&w.notify)}
                if !changed {
                    w.stats.passes+=1
                    w.stats.quiet+=1
                    return count,true
                }
            } else {
                // Asked before the walk: what changes during it is told for the next pass.
                w.notified=dir_notify_open(&w.notify,string(w.path[:w.root_length]),w.recursive)
            }
            w.pass+=1
            w.path_length=w.root_length
            w.depth=0
            if !dir_open(&w.levels[0].iterator,string(w.path[:w.root_length])) {
                // The folder itself is gone: every file of it is removed.
                // Its handle would keep the name of the folder taken.
                if w.notified {dir_notify_close(&w.notify);w.notified=false}
                w.phase=.Sweep;w.sweep=0
                continue
            }
            w.levels[0].relative_length=0
            w.depth=1
            w.phase=.Walk
            left-=WATCH_FOLDER_COST
        case .Walk:
            level:=&w.levels[w.depth-1]
            entry:=w.held_entry
            if !w.held {
                ok:bool
                entry,ok=dir_next(&level.iterator,w.held_name[:])
                if !ok {
                    dir_close(&level.iterator)
                    w.depth-=1
                    if w.depth==0 {w.phase=.Sweep;w.sweep=0}
                    continue
                }
                left-=1
            }
            w.held=false
            if !w.hidden && entry.name[0]=='.' {continue}
            relative_length:=level.relative_length+len(entry.name)
            if level.relative_length>0 {relative_length+=1}
            if w.root_length+relative_length+1>=WATCH_PATH_BYTES || relative_length>int(max(u16)) {w.stats.untracked+=1;continue}
            // The relative path of the entry, after the one of its folder.
            at:=w.root_length+level.relative_length
            if level.relative_length>0 {w.path[at]='/';at+=1}
            copy(w.path[at:],entry.name)
            relative:=string(w.path[w.root_length:][:relative_length])
            if entry.directory {
                if !w.recursive {continue}
                if w.depth>=WATCH_DEPTH {w.stats.too_deep+=1;continue}
                next:=&w.levels[w.depth]
                if dir_open(&next.iterator,string(w.path[:w.root_length+relative_length])) {
                    next.relative_length=relative_length
                    w.depth+=1
                }
                left-=WATCH_FOLDER_COST
                continue
            }
            hash:=base.name_hash(relative)
            if file:=watch_find(w,hash,relative);file!=nil {
                file.pass=u16(w.pass)
                if file.size!=entry.size || file.modified!=entry.modified {
                    file.size=entry.size;file.modified=entry.modified
                    events[count]={.Changed,string(w.text[file.offset:][:file.length])};count+=1
                }
                continue
            }
            if w.file_count>=w.file_capacity || w.text_used+2+relative_length>len(w.text) {
                if w.text_dead>0 && w.file_count<w.file_capacity {
                    // Room can be made, but not now: the events of this call point into the text.
                    w.held=true;w.held_entry=entry;w.compact=true
                    return count,false
                }
                w.stats.untracked+=1
                continue
            }
            file:=watch_insert(w,hash,relative)
            file.size=entry.size;file.modified=entry.modified;file.pass=u16(w.pass)
            if !w.first_pass || w.report_existing {
                events[count]={.Created,string(w.text[file.offset:][:file.length])};count+=1
            }
        case .Sweep:
            swept:=0
            for w.sweep<len(w.files) && swept<WATCH_SWEEP_PER_UNIT && count<len(events) {
                file:=&w.files[w.sweep]
                swept+=1
                if file.length==0 || file.pass==u16(w.pass) {w.sweep+=1;continue}
                events[count]={.Removed,string(w.text[file.offset:][:file.length])};count+=1
                // Removing shifts later files back into this slot: it is looked at again.
                watch_remove(w,w.sweep)
            }
            left-=1
            if w.sweep>=len(w.files) {
                w.phase=.Idle
                w.first_pass=false
                w.stats.passes+=1
                return count,true
            }
        }
    }
    return count,false
}

// text holds, for every path, its length in two bytes and then its bytes.
@(private)
watch_find :: proc(w:^Watch_Slot,hash:u64,relative:string) -> ^Watch_File {
    mask:=len(w.files)-1
    for i:=int(hash)&mask;;i=(i+1)&mask {
        file:=&w.files[i]
        if file.length==0 {return nil}
        if file.hash==hash && string(w.text[file.offset:][:file.length])==relative {return file}
    }
}
// The caller has checked that the file and its path fit.
@(private)
watch_insert :: proc(w:^Watch_Slot,hash:u64,relative:string) -> ^Watch_File {
    mask:=len(w.files)-1
    i:=int(hash)&mask
    for w.files[i].length!=0 {i=(i+1)&mask}
    file:=&w.files[i]
    file^={hash=hash,offset=u32(w.text_used+2),length=u16(len(relative))}
    w.text[w.text_used]=u8(len(relative));w.text[w.text_used+1]=u8(len(relative)>>8)
    copy(w.text[w.text_used+2:],relative)
    w.text_used+=2+len(relative)
    w.file_count+=1
    return file
}
// Empties a slot and closes the gap in its probe chain. The path stays in
// text, dead, until watch_compact: a Removed event still points at it.
@(private)
watch_remove :: proc(w:^Watch_Slot,index:int) {
    mask:=len(w.files)-1
    w.text_dead+=2+int(w.files[index].length)
    w.file_count-=1
    hole:=index
    for i:=(index+1)&mask;;i=(i+1)&mask {
        file:=w.files[i]
        if file.length==0 {break}
        home:=int(file.hash)&mask
        // The file can move back into the hole when its home is not between the hole and it.
        if (i-home)&mask>=(i-hole)&mask {w.files[hole]=file;hole=i}
    }
    w.files[hole]={}
}
// Moves the paths of the files that are left to the start of text. A path
// is alive when the file found by its name is the one stored at its place.
@(private)
watch_compact :: proc(w:^Watch_Slot) {
    w.compact=false
    if w.text_dead==0 {return}
    used:=0
    for at:=0;at<w.text_used; {
        length:=int(w.text[at])|int(w.text[at+1])<<8
        relative:=string(w.text[at+2:][:length])
        if file:=watch_find(w,base.name_hash(relative),relative);file!=nil && int(file.offset)==at+2 {
            copy(w.text[used:],w.text[at:][:2+length])
            file.offset=u32(used+2)
            used+=2+length
        }
        at+=2+length
    }
    w.text_used=used;w.text_dead=0
}
