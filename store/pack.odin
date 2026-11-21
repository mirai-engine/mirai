package store

import "base:intrinsics"
import "core:crypto"
import "core:hash"
import "core:hash/xxhash"
import "core:mem"
import "core:os"
import "core:slice"
import "core:sync"
import "core:time"
import "mirai:std/base"

// A pack is packs/<writer>-<seq>.pack: a Pack_Head, then frames, each a
// Frame_Head and its data at an offset aligned to 1<<align, appended only by
// the writer whose lease is w-<writer>. A Commit frame closes a batch: readers
// take frames only up to the last commit whose count and sum of heads match
// what precedes it, so a torn tail is never read and a pack is never reopened
// to write. A sealed pack ends in a trailer of its chunks sorted by address and
// a Footer; a pack without one is read by scanning its frames.

@(private) PACK_MAGIC :: "MIRPACK3"
@(private) SEAL_MAGIC :: "MIRSEAL3"
@(private) PACK_SMALL :: 16<<20 // sealed packs under it are merged by a sweep
@(private) STAGE_BYTES :: 1<<20 // frames gathered before one write
@(private) ALIGN_SMALL :: 6
@(private) ALIGN_LARGE :: 12    // for data of CHUNK_AVG and more, so it maps on pages
@(private) ALIGN_FRAME :: 3

@(private)
Frame_Kind :: enum u8 {Pad,Chunk,Ref,Touch,Tombstone,Commit}

@(private)
Frame_Head :: struct #packed {
    kind:Frame_Kind,
    codec:u8,     // 0: stored as given
    align:u8,     // log2 of the alignment of the data
    reserved:u8,
    stored:u32,   // bytes of data after the head and its padding
    raw:u32,      // bytes before the store's codec
    address:Hash, // Chunk, Touch, Tombstone: the chunk; Ref: the target, zero for a removed ref
    check:u32,    // crc32 of the bytes before it
}

@(private)
Pack_Head :: struct #packed {
    magic:[8]u8,
    writer:[16]u8,
    created:i64,
}

@(private)
Commit_Payload :: struct #packed {
    frames:u32, // frames since the last commit
    reserved:u32,
    heads:u64,  // sum of frame_sum over them
    time:i64,   // nanoseconds of the system clock
}

// Ref payload: time i64, namespace length u8, name length u8, namespace, name.
@(private) REF_FIXED :: 10

@(private)
Tomb_Payload :: struct #packed {
    writer:[16]u8,
    seq:u32,
    offset:u64, // of the data of the damaged copy
}

// Where the data of a chunk is: in a sealed pack's trailer, a generation and a
// store's table.
@(private)
Location :: struct #packed {
    pack:u32,   // of the generation, or of the store's packs in its table
    offset:u64, // of the data
    stored:u32,
    raw:u32,
    codec:u8,
    align:u8,
    time:i64,   // of the commit that wrote or last touched it
}

@(private)
Extra :: struct #packed {
    offset:u64, // of the head of a Ref, Touch or Tombstone frame
    time:i64,
}

// Trailer: sorted [chunks]Hash, [chunks]Location, fanout [256]u32 by first
// byte, [extras]Extra, then the Footer that ends the file.
@(private)
Footer :: struct #packed {
    trailer:u64,
    frames_end:u64, // of the last commit
    chunks:u32,
    extras:u32,
    last:i64,       // time of the last commit
    check:u64,      // xxh3 of the trailer, seeded with that of the fields above
    magic:[8]u8,
}

#assert(size_of(Frame_Head)==48 && size_of(Pack_Head)==32 && size_of(Location)==30 && size_of(Footer)==48)

@(private)
Pack_Id :: struct {
    writer:[16]u8,
    seq:u32,
}

@(private)
Pack :: struct {
    id:Pack_Id,
    file:^os.File, // open once needed; the own pack's is open to write
    view:[]u8,     // the mapping of a sealed pack
    size:i64,      // sealed: of the file; otherwise the end of its last commit read
    created:i64,
    last:i64,      // time of its last commit known
    retired:u64,   // the generation that dropped it into retired/; 0: in packs/
    sealed,indexed,own,gone,damaged:bool,
    dead:bool,     // still being written by a writer whose lease is gone: a sweep folds what it committed
    lent:bool,     // its file or mapping went to a caller, who may still hold slices of it: kept open
    pruned:bool,   // deleted from retired/ and closed: nothing reads it
}

@(private)
Writer :: struct {
    id:[16]u8,
    seq:u32,
    open:bool,
    pack:int,
    file:^os.File,
    end,committed:i64, // reserved; end of the last commit
    inflight:int,      // writes reserved and not landed
    rotating:bool,
    frames:u32,
    heads:u64,
    pending:i64,
    generation:u64,    // of the state the batch's lookups saw
    deduped:[dynamic]Deduped,
    named:[dynamic]Hash,
    own:[dynamic]Own_Frame, // of the open pack, for its trailer
    broken:Error,
    holder:Holder,
    lease_generation:u64,
    leased:bool,
}

// A chunk a batch found already stored instead of writing it.
@(private)
Deduped :: struct {
    address:Hash,
    pack:Pack_Id,
    location:Location,
}

@(private)
Own_Frame :: struct {
    kind:Frame_Kind,
    address:Hash,
    location:Location, // of a chunk; of another kind, offset is of its head
}

// Frames gathered to be written at once from a base aligned to align.
@(private)
Stage :: struct {
    bytes:[dynamic]u8,
    frames:[dynamic]Staged,
    align:int,
    time:i64,
    coder:^Coder, // of the puts that stage into it, made the first time one encodes
}

@(private)
Staged :: struct {
    at:int, // of the head, from the base
    head:Frame_Head,
    data_time:i64, // a chunk's time to keep (a copy keeps its original's)
}

@(private)
align_up :: proc "contextless" (value:i64,alignment:i64) -> i64 {
    return (value+alignment-1)&~(alignment-1)
}

@(private)
head_seal :: proc "contextless" (head:^Frame_Head) {
    head.check=hash.crc32(mem.ptr_to_bytes(head)[:44])
}

@(private)
head_data_at :: proc "contextless" (at:i64,head:Frame_Head) -> i64 {
    return align_up(at+size_of(Frame_Head),i64(1)<<head.align)
}

@(private)
head_end :: proc "contextless" (at:i64,head:Frame_Head) -> i64 {
    return align_up(head_data_at(at,head)+i64(head.stored),8)
}

// Whether a head of any origin is one a writer writes: its check, its kind's
// alignment and sizes.
@(private)
head_valid :: proc "contextless" (head:^Frame_Head) -> bool {
    if head.reserved!=0 || head.check!=hash.crc32(mem.ptr_to_bytes(head)[:44]) || head.codec!=CODEC_NONE && head.kind!=.Chunk {return false}
    switch head.kind {
    case .Pad: return false
    case .Chunk: return (head.align==ALIGN_SMALL || head.align==ALIGN_LARGE) && sizes_valid(head.codec,head.stored,head.raw)
    case .Ref: return head.align==ALIGN_FRAME && head.stored>REF_FIXED && head.stored<=REF_FIXED+2*NAME_MAX && head.raw==head.stored
    case .Touch: return head.align==ALIGN_FRAME && head.stored==0 && head.raw==0
    case .Tombstone: return head.align==ALIGN_FRAME && head.stored==size_of(Tomb_Payload) && head.raw==head.stored
    case .Commit: return head.align==ALIGN_FRAME && head.stored==size_of(Commit_Payload) && head.raw==head.stored && head.address=={}
    }
    return false
}

// Whether a chunk frame's sizes are ones a writer writes: as they are, or
// encoded smaller than the chunk.
@(private)
sizes_valid :: proc "contextless" (codec:u8,stored,raw:u32) -> bool {
    if int(codec)>=CODECS_MAX || stored<1 || stored>CHUNK_MAX {return false}
    return raw==stored if codec==CODEC_NONE else raw>stored && raw<=CHUNK_MAX
}

// What a commit sums of a frame: its head, the payload of one that is not a
// chunk, and where it is.
@(private)
frame_sum :: proc(bytes:[]u8,at:i64) -> u64 {
    return xxhash.XXH3_64_with_seed(bytes,u64(at))
}

@(private)
stage_reset :: proc(st:^Stage) {
    clear(&st.bytes)
    clear(&st.frames)
    st.align=1<<ALIGN_SMALL
}

// Appends a frame; data is copied. A chunk's data is encoded by codec from
// raw bytes, or with CODEC_NONE the chunk as it is.
@(private)
stage_frame :: proc(st:^Stage,kind:Frame_Kind,address:Hash,data:[]u8,data_time:i64=0,codec:=u8(CODEC_NONE),raw:=0) -> Error {
    align:=u8(ALIGN_FRAME)
    if kind==.Chunk {align=ALIGN_LARGE if len(data)>=CHUNK_AVG else ALIGN_SMALL}
    head:=Frame_Head{kind=kind,codec=codec,align=align,stored=u32(len(data)),raw=u32(raw if codec!=CODEC_NONE else len(data)),address=address}
    head_seal(&head)
    at:=align_up(i64(len(st.bytes)),8)
    data_at:=head_data_at(at,head)
    end:=align_up(data_at+i64(len(data)),8)
    old:=len(st.bytes)
    if resize(&st.bytes,int(end))!=nil {return .Out_Of_Memory}
    mem.zero_slice(st.bytes[old:])
    head_bytes:=head
    copy(st.bytes[at:],mem.ptr_to_bytes(&head_bytes))
    copy(st.bytes[data_at:],data)
    if _,e:=append(&st.frames,Staged{at=int(at),head=head,data_time=data_time});e!=nil {
        base.truncate(&st.bytes,old)
        return .Out_Of_Memory
    }
    st.align=max(st.align,1<<align)
    return .None
}

@(private)
stage_take :: proc(s:^Store) -> (st:^Stage,error:Error) {
    sync.mutex_lock(&s.state.lock)
    if n:=len(s.state.stages);n>0 {
        st=pop(&s.state.stages)
    }
    sync.mutex_unlock(&s.state.lock)
    if st==nil {
        e:Error
        st,e=stage_new(s)
        if e!=.None {return nil,e}
    }
    stage_reset(st)
    return st,.None
}

@(private)
stage_new :: proc(s:^Store) -> (^Stage,Error) {
    st,e:=new(Stage,s.state.allocator)
    if e!=nil {return nil,.Out_Of_Memory}
    st.bytes=make([dynamic]u8,0,0,s.state.allocator)
    st.frames=make([dynamic]Staged,0,0,s.state.allocator)
    return st,.None
}

@(private)
stage_give :: proc(s:^Store,st:^Stage) {
    if st==nil {return}
    sync.mutex_lock(&s.state.lock)
    _,e:=append(&s.state.stages,st)
    sync.mutex_unlock(&s.state.lock)
    if e!=nil {stage_free(s,st)}
}

@(private)
stage_free :: proc(s:^Store,st:^Stage) {
    if st.coder!=nil {coder_free(s,st.coder)}
    delete(st.bytes)
    delete(st.frames)
    free(st,s.state.allocator)
}

// Writes a stage to this value's pack: the range is reserved under the lock
// and written outside it, so threads write at once; its chunks are found by
// this value as soon as they land, and by others once committed.
@(private)
stage_write :: proc(s:^Store,st:^Stage,now:i64) -> Error {
    if len(st.frames)==0 {return .None}
    state:=s.state
    sync.mutex_lock(&state.lock)
    base,file,error:=reserve_locked(s,st)
    sync.mutex_unlock(&state.lock)
    if error!=.None {return error}
    sum:=stage_sum(st,base)
    written:=io_write_at(s,file,st.bytes[:],base)
    sync.mutex_lock(&state.lock)
    error=land_locked(s,st,base,sum,written,now)
    sync.mutex_unlock(&state.lock)
    return error
}

// stage_write with the lock already held.
@(private)
stage_write_locked :: proc(s:^Store,st:^Stage,now:i64) -> Error {
    if len(st.frames)==0 {return .None}
    base,file:=reserve_locked(s,st) or_return
    sum:=stage_sum(st,base)
    written:=io_write_at(s,file,st.bytes[:],base)
    return land_locked(s,st,base,sum,written,now)
}

@(private)
stage_sum :: proc(st:^Stage,base:i64) -> (sum:u64) {
    for f in st.frames {
        length:=size_of(Frame_Head)+(0 if f.head.kind==.Chunk else int(f.head.stored))
        sum+=frame_sum(st.bytes[f.at:][:length],base+i64(f.at))
    }
    return
}

@(private)
reserve_locked :: proc(s:^Store,st:^Stage) -> (base:i64,file:^os.File,error:Error) {
    w:=&s.state.writer
    need:=i64(len(st.bytes))
    for {
        writer_ready_locked(s) or_return
        if w.end+need+i64(st.align)<=PACK_MAX || w.end<=size_of(Pack_Head) {break}
        // One thread rotates the pack; the others wait for the new one.
        if w.rotating {
            sync.cond_wait(&s.state.written,&s.state.lock)
            continue
        }
        w.rotating=true
        rotated:=writer_rotate_locked(s)
        w.rotating=false
        sync.cond_broadcast(&s.state.written)
        rotated or_return
    }
    base=align_up(w.end,i64(st.align))
    w.end=base+need
    w.inflight+=1
    return base,w.file,.None
}

@(private)
land_locked :: proc(s:^Store,st:^Stage,base:i64,sum:u64,written:Error,now:i64) -> Error {
    state:=s.state
    w:=&state.writer
    w.inflight-=1
    defer if w.inflight==0 {sync.cond_broadcast(&state.written)}
    if written!=.None {
        // A failed write gives its range back unless another was reserved after it.
        if w.end==base+i64(len(st.bytes)) {w.end=base}
        if w.broken==.None {w.broken=written}
        return written
    }
    if w.broken!=.None {return w.broken}
    w.frames+=u32(len(st.frames))
    w.heads+=sum
    w.pending+=i64(len(st.bytes))
    if reserve(&w.own,len(w.own)+len(st.frames))!=nil {
        w.broken=.Out_Of_Memory
        return .Out_Of_Memory
    }
    for f in st.frames {
        at:=base+i64(f.at)
        frame:=Own_Frame{kind=f.head.kind,address=f.head.address}
        switch f.head.kind {
        case .Chunk:
            time:=f.data_time if f.data_time!=0 else now
            frame.location={pack=u32(w.pack),offset=u64(head_data_at(at,f.head)),stored=f.head.stored,raw=f.head.raw,codec=f.head.codec,align=f.head.align,time=time}
        case .Ref,.Touch,.Tombstone,.Commit,.Pad:
            frame.location={offset=u64(at),time=now}
        }
        append(&w.own,frame)
        payload:=st.bytes[f.at+size_of(Frame_Head):][:f.head.stored] if f.head.kind!=.Chunk else nil
        if e:=frame_apply(s,w.pack,f.head,at,payload,frame.location.time);e!=.None {
            w.broken=e
            return e
        }
        if f.head.kind==.Ref {
            if _,e:=append(&w.named,f.head.address);e!=nil {
                w.broken=.Out_Of_Memory
                return .Out_Of_Memory
            }
        }
    }
    return .None
}

// Makes the writer's pack the first time it is needed, with the lease that
// says its writer runs.
@(private)
writer_ready_locked :: proc(s:^Store) -> Error {
    w:=&s.state.writer
    if w.broken!=.None {return w.broken}
    if w.open {return .None}
    if w.id==({}) {
        crypto.rand_bytes(w.id[:])
        // Lookups of the batch made against an older generation wait on it.
        seen:=s.state.generation.number
        if len(w.deduped)>0 {seen=min(seen,w.generation)}
        w.holder=holder_self()
        w.lease_generation=seen
        lease_buffer:[PATH_BYTES]u8
        path:=writer_lease_path(s,&lease_buffer) or_return
        if error:=lease_write(s,path,w.holder,seen,nil,time.now());error!=.None {
            w.id={}
            return error
        }
        w.leased=true
    }
    return writer_pack_open_locked(s)
}

// Hex of a writer id: 32 digits.
@(private)
writer_text :: proc(id:[16]u8,buffer:^[64]u8) -> string {
    whole:Hash
    id:=id
    copy(whole[:],id[:])
    return hex(whole,buffer)[:32]
}

@(private)
writer_lease_path :: proc(s:^Store,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    name:[2+32]u8
    text:[64]u8
    copy(name[:],"w-")
    copy(name[2:],writer_text(s.state.writer.id,&text))
    return join(buffer,s.root,"leases",string(name[:]))
}

@(private)
writer_pack_open_locked :: proc(s:^Store) -> Error {
    state:=s.state
    w:=&state.writer
    id:=Pack_Id{writer=w.id,seq=w.seq}
    buffer:[PATH_BYTES]u8
    path:=pack_path(s,"packs",id,&buffer) or_return
    file:=io_create(s,path) or_return
    now:=time.now()._nsec
    head:=Pack_Head{writer=w.id,created=now}
    copy(head.magic[:],PACK_MAGIC)
    if e:=io_write_at(s,file,mem.ptr_to_bytes(&head),0);e!=.None {
        os.close(file)
        file_remove(path)
        return e
    }
    index,error:=pack_add_locked(s,id)
    if error!=.None {
        os.close(file)
        file_remove(path)
        return error
    }
    p:=&state.packs[index]
    p.file,p.own,p.created,p.size=file,true,now,size_of(Pack_Head)
    w.open,w.pack,w.file=true,index,file
    w.end,w.committed=size_of(Pack_Head),size_of(Pack_Head)
    w.frames,w.heads,w.pending=0,0,0
    clear(&w.own)
    return .None
}

// Commits the batch of this value's writer: its frames and the commit frame
// that makes them visible to every reader reach the disk with one flush of its
// own pack before it returns; an open pack of another writer whose chunks or
// objects the batch names is flushed first, so nothing it names can be lost to
// a crash that keeps it. When a sweep published a generation since the batch's lookups,
// before or after its commit frame, what the batch named without writing is
// looked up again and what the sweep dropped is copied back from the retired
// pack that still holds it; what is gone everywhere fails the commit
// (Missing). A writer whose lease is gone (a sweep judged it ended) writes its
// batch again in a new pack under a new lease.
commit :: proc(s:^Store,now:Maybe(time.Time)=nil) -> Error {
    if s==nil || s.state==nil {return .Invalid_Argument}
    sync.mutex_lock(&s.state.lock)
    defer sync.mutex_unlock(&s.state.lock)
    return commit_locked(s,(now.? or_else time.now())._nsec)
}

@(private) COMMIT_ROUNDS :: 4

@(private)
commit_locked :: proc(s:^Store,now:i64) -> Error {
    state:=s.state
    w:=&state.writer
    for w.inflight>0 {sync.cond_wait(&state.written,&state.lock)}
    if w.broken!=.None {
        e:=w.broken
        batch_drop_locked(s)
        return e
    }
    if !w.open || w.frames==0 {
        batch_reset(w)
        writer_ack_locked(s)
        return .None
    }
    for _ in 0..<COMMIT_ROUNDS {
        from:=w.committed
        if e:=commit_frame_locked(s,now);e!=.None {
            batch_drop_locked(s)
            return e
        }
        if !writer_alive_locked(s,now) {
            if e:=writer_redo_locked(s,from,now);e!=.None {
                batch_drop_locked(s)
                return e
            }
            continue
        }
        copied,settled:=batch_settle_locked(s,now)
        if settled!=.None {
            batch_reset(w)
            return settled
        }
        if !copied {break}
    }
    batch_reset(w)
    writer_ack_locked(s)
    return .None
}

// Flushes what the batch names in other open packs, looks the batch up
// against the newest generation, writes the commit frame and flushes its own
// pack once.
@(private)
commit_frame_locked :: proc(s:^Store,now:i64) -> Error {
    state:=s.state
    w:=&state.writer
    if w.frames==0 {return .None}
    foreign_flush_locked(s) or_return
    batch_verify_locked(s,now) or_return
    sweep_step(s,.Verified)
    payload:=Commit_Payload{frames=w.frames,heads=w.heads,time=now}
    head:=Frame_Head{kind=.Commit,align=ALIGN_FRAME,stored=size_of(Commit_Payload),raw=size_of(Commit_Payload)}
    head_seal(&head)
    bytes:[size_of(Frame_Head)+size_of(Commit_Payload)]u8
    copy(bytes[:],mem.ptr_to_bytes(&head))
    copy(bytes[size_of(Frame_Head):],mem.ptr_to_bytes(&payload))
    at:=align_up(w.end,8)
    io_write_at(s,w.file,bytes[:],at) or_return
    w.end=at+len(bytes)
    io_sync(s,w.file) or_return
    w.committed=w.end
    w.frames,w.heads,w.pending=0,0,0
    p:=&state.packs[w.pack]
    p.size,p.last=w.committed,now
    sweep_step(s,.Committed)
    return .None
}

@(private)
batch_reset :: proc(w:^Writer) {
    w.frames,w.heads,w.pending=0,0,0
    clear(&w.deduped)
    clear(&w.named)
}

// The batch's frames are cut off the pack, which no reader took past its last
// commit, and the state is read again without them.
@(private)
batch_drop_locked :: proc(s:^Store) {
    w:=&s.state.writer
    if w.open && w.end>w.committed {
        if os.truncate(w.file,w.committed)==nil {
            w.end=w.committed
            for len(w.own)>0 && i64(w.own[len(w.own)-1].location.offset)>=w.committed {pop(&w.own)}
            w.broken=.None
        } else {
            // A pack whose tail cannot go takes no more frames: the next batch begins another.
            writer_abandon_locked(s)
        }
    } else {
        w.broken=.None
    }
    batch_reset(w)
    state_rebuild_locked(s)
}

// Looks up again, against a generation a sweep published since the batch
// began, what the batch named without writing, and stages what the sweep
// retired back into this pack.
@(private)
batch_verify_locked :: proc(s:^Store,now:i64) -> Error {
    state:=s.state
    w:=&state.writer
    newest:=generation_newest(s) or_return
    if newest<=w.generation {return .None}
    refresh_locked(s) or_return
    w.generation=state.generation.number
    _,missing:=batch_restore_locked(s,now) or_return
    if missing>0 {return .Missing}
    return .None
}

// After the commit frame: when a sweep published a generation since the
// batch was looked up, what it dropped is copied back, to commit again.
@(private)
batch_settle_locked :: proc(s:^Store,now:i64) -> (copied:bool,error:Error) {
    state:=s.state
    w:=&state.writer
    newest:=generation_newest(s) or_return
    if newest<=w.generation {return false,.None}
    refresh_locked(s) or_return
    w.generation=state.generation.number
    missing:int
    copied,missing=batch_restore_locked(s,now) or_return
    clear(&w.deduped)
    clear(&w.named)
    if missing>0 {return copied,.Missing}
    return copied,.None
}

// Stages back from retired packs what the batch found stored, and what its
// refs reach, that the current generation no longer holds.
@(private)
batch_restore_locked :: proc(s:^Store,now:i64) -> (copied:bool,missing:int,error:Error) {
    w:=&s.state.writer
    st:^Stage
    defer if st!=nil {stage_free(s,st)}
    visited:=make(map[Hash]struct{},16,context.temp_allocator)
    defer delete(visited)
    for d in w.deduped {missing+=restore_locked(s,&st,d.address,DATA,0,&visited) or_return}
    for target in w.named {
        if target=={} {continue}
        missing+=restore_locked(s,&st,target,-1,0,&visited) or_return
    }
    if st!=nil && len(st.frames)>0 {
        stage_write_locked(s,st,now) or_return
        copied=true
    }
    return
}

// Flushes the open packs of other writers that hold what the batch names.
@(private)
foreign_flush_locked :: proc(s:^Store) -> Error {
    state:=s.state
    w:=&state.writer
    packs:=make(map[int]struct{},16,context.temp_allocator)
    defer delete(packs)
    for d in w.deduped {
        if i:=pack_find(s,d.pack);i>=0 {map_insert(&packs,i,struct{}{})}
    }
    if len(w.named)>0 {
        visited:=make(map[Hash]struct{},16,context.temp_allocator)
        defer delete(visited)
        for target in w.named {
            if target!={} {root_packs_locked(s,target,&packs,&visited)}
        }
    }
    for i in packs {
        p:=&state.packs[i]
        if p.sealed || p.indexed || p.gone || p.retired>0 || (w.open && i==w.pack) {continue}
        buffer:[PATH_BYTES]u8
        file,error:=io_open(s,pack_file_path(s,p,&buffer) or_return,{.Read,.Write})
        if error==.Missing {continue}
        if error!=.None {return error}
        flushed:=io_sync(s,file)
        os.close(file)
        flushed or_return
    }
    return .None
}

// Whether the root still sees this writer: its lease is there, refreshed
// when older than a quarter of LEASE_MAX_AGE for other machines' sweeps.
@(private)
writer_alive_locked :: proc(s:^Store,now:i64) -> bool {
    w:=&s.state.writer
    if !w.leased {return true}
    buffer:[PATH_BYTES]u8
    path,error:=writer_lease_path(s,&buffer)
    if error!=.None {return true}
    info,stat_error:=os.stat(path,context.temp_allocator)
    if stat_error!=nil {return false}
    at:=time.Time{_nsec=now}
    if older_than(info.modification_time,at,LEASE_MAX_AGE/4) {
        if os.change_times(path,at,at)!=nil {return false}
    }
    return true
}

// A writer a sweep judged ended writes the frames of its batch again, from
// from, in a new pack under a new lease; the old pack is the sweep's.
@(private)
writer_redo_locked :: proc(s:^Store,from:i64,now:i64) -> Error {
    state:=s.state
    w:=&state.writer
    frames:=make([dynamic]Own_Frame,0,len(w.own),context.temp_allocator)
    defer delete(frames)
    for f in w.own {
        if i64(f.location.offset)>=from {append(&frames,f)}
    }
    old:=w.file
    st:=stage_new(s) or_return
    defer stage_free(s,st)
    stage_reset(st)
    buffer,e:=make([]u8,CHUNK_MAX+REF_FIXED+2*NAME_MAX,context.temp_allocator)
    if e!=nil {return .Out_Of_Memory}
    defer delete(buffer,context.temp_allocator)
    for f in frames {
        if f.kind==.Chunk {
            data:=buffer[:f.location.stored]
            read_exact(old,data,i64(f.location.offset)) or_return
            stage_frame(st,.Chunk,f.address,data,f.location.time,f.location.codec,int(f.location.raw)) or_return
            continue
        }
        head:Frame_Head
        read_exact(old,mem.ptr_to_bytes(&head),i64(f.location.offset)) or_return
        if !head_valid(&head) {return .Corrupt}
        payload:=buffer[:head.stored]
        read_exact(old,payload,i64(f.location.offset)+size_of(Frame_Head)) or_return
        stage_frame(st,head.kind,head.address,payload) or_return
    }
    p:=&state.packs[w.pack]
    p.own=false
    w.open,w.file,w.leased=false,nil,false
    w.id,w.seq={},0
    clear(&w.own)
    return stage_write_locked(s,st,now)
}

// Says in the writer's lease that nothing it has named waits on a
// generation older than the current one.
@(private)
writer_ack_locked :: proc(s:^Store) {
    state:=s.state
    w:=&state.writer
    if !w.leased || w.frames>0 || w.inflight>0 || len(w.deduped)>0 || len(w.named)>0 {return}
    generation:=state.generation.number
    if generation<=w.lease_generation {return}
    buffer:[PATH_BYTES]u8
    path,error:=writer_lease_path(s,&buffer)
    if error!=.None {return}
    if lease_write(s,path,w.holder,generation,nil,time.now())==.None {w.lease_generation=generation}
}

// Commits, seals the pack and begins the next one.
@(private)
writer_rotate_locked :: proc(s:^Store) -> Error {
    commit_locked(s,time.now()._nsec) or_return
    writer_seal_locked(s) or_return
    s.state.writer.seq+=1
    return writer_pack_open_locked(s)
}

// Writes the trailer and footer of the writer's committed pack and syncs it.
@(private)
writer_seal_locked :: proc(s:^Store) -> Error {
    state:=s.state
    w:=&state.writer
    if !w.open {return .None}
    p:=&state.packs[w.pack]
    if w.committed<=size_of(Pack_Head) {
        // A pack that took nothing is removed.
        os.close(w.file)
        buffer:[PATH_BYTES]u8
        if path,e:=pack_path(s,"packs",p.id,&buffer);e==.None {io_remove(s,path)}
        p.file,p.gone=nil,true
        w.open,w.file=false,nil
        clear(&w.own)
        return .None
    }
    size:=pack_seal(s,w.file,w.own[:],w.committed,p.last) or_return
    p.sealed,p.size,p.own=true,size,false
    w.open,w.file=false,nil
    clear(&w.own)
    // The file stays open to read.
    return .None
}

// A pack whose tail could not be cut is left for a sweep to seal at its last
// commit; the writer goes on in a new one.
@(private)
writer_abandon_locked :: proc(s:^Store) {
    w:=&s.state.writer
    w.open,w.file=false,nil
    w.broken=.None
    w.seq+=1
    clear(&w.own)
}

@(private)
writer_close_locked :: proc(s:^Store) {
    state:=s.state
    w:=&state.writer
    if w.open {
        commit_locked(s,time.now()._nsec)
        writer_seal_locked(s)
    }
    if w.leased {
        buffer:[PATH_BYTES]u8
        if path,error:=writer_lease_path(s,&buffer);error==.None {file_remove(path)}
        w.leased=false
    }
}

// Writes the trailer of frames after frames_end and the footer, and syncs:
// the size of the sealed file.
@(private)
pack_seal :: proc(s:^Store,file:^os.File,frames:[]Own_Frame,frames_end:i64,last:i64) -> (size:i64,error:Error) {
    bytes:=trailer_build(frames,frames_end,last) or_return
    defer delete(bytes,context.temp_allocator)
    at:=align_up(frames_end,8)
    if os.truncate(file,at)!=nil {return 0,.Io}
    io_write_at(s,file,bytes,at) or_return
    io_sync(s,file) or_return
    return at+i64(len(bytes)),.None
}

@(private)
trailer_build :: proc(frames:[]Own_Frame,frames_end:i64,last:i64) -> (bytes:[]u8,error:Error) {
    chunks,extras:int
    for f in frames {
        if f.kind==.Chunk {chunks+=1} else {extras+=1}
    }
    order,e:=make([]int,chunks,context.temp_allocator)
    if e!=nil {return nil,.Out_Of_Memory}
    defer delete(order,context.temp_allocator)
    n:=0
    for f,i in frames {
        if f.kind==.Chunk {order[n]=i;n+=1}
    }
    Sorter :: struct {frames:[]Own_Frame}
    sorter:=Sorter{frames}
    context.user_ptr=&sorter
    slice.sort_by(order,proc(a,b:int) -> bool {
        f:=(^Sorter)(context.user_ptr).frames
        return hash_less(f[a].address,f[b].address)
    })
    // One copy of each address.
    unique:=0
    for i in order {
        if unique>0 && frames[order[unique-1]].address==frames[i].address {continue}
        order[unique]=i
        unique+=1
    }
    chunks=unique
    total:=chunks*(size_of(Hash)+size_of(Location))+256*4+extras*size_of(Extra)+size_of(Footer)
    bytes,e=make([]u8,total,context.temp_allocator)
    if e!=nil {return nil,.Out_Of_Memory}
    addresses:=([^]Hash)(raw_data(bytes))[:chunks]
    locations:=([^]Location)(raw_data(bytes[chunks*size_of(Hash):]))[:chunks]
    fanout:=([^]u32)(raw_data(bytes[chunks*(size_of(Hash)+size_of(Location)):]))[:256]
    extra_at:=chunks*(size_of(Hash)+size_of(Location))+256*4
    extra_list:=([^]Extra)(raw_data(bytes[extra_at:]))[:extras]
    for i,k in order[:chunks] {
        addresses[k]=frames[i].address
        l:=frames[i].location
        l.pack=0
        locations[k]=l
        fanout[frames[i].address[0]]+=1
    }
    for b in 1..<256 {fanout[b]+=fanout[b-1]}
    k:=0
    for f in frames {
        if f.kind==.Chunk {continue}
        extra_list[k]={offset=f.location.offset,time=f.location.time}
        k+=1
    }
    footer:=Footer{trailer=u64(align_up(frames_end,8)),frames_end=u64(frames_end),chunks=u32(chunks),extras=u32(extras),last=last}
    copy(footer.magic[:],SEAL_MAGIC)
    footer.check=footer_check(bytes[:total-size_of(Footer)],&footer)
    copy(bytes[total-size_of(Footer):],mem.ptr_to_bytes(&footer))
    return bytes,.None
}

@(private)
footer_check :: proc(trailer:[]u8,footer:^Footer) -> u64 {
    fields:=mem.ptr_to_bytes(footer)[:32]
    return xxhash.XXH3_64_with_seed(trailer,xxhash.XXH3_64_default(fields))
}

@(private)
hash_less :: proc "contextless" (a,b:Hash) -> bool {
    for i in 0..<32 {
        if a[i]!=b[i] {return a[i]<b[i]}
    }
    return false
}

@(private)
hash_compare :: proc "contextless" (a,b:Hash) -> int {
    for i in 0..<32 {
        if a[i]!=b[i] {return -1 if a[i]<b[i] else 1}
    }
    return 0
}

// packs/<writer hex>-<seq hex>.pack, or the same in another folder.
@(private)
pack_path :: proc(s:^Store,folder:string,id:Pack_Id,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    name:[PACK_NAME]u8
    return join(buffer,s.root,folder,pack_name(id,&name))
}

@(private) PACK_NAME :: 32+1+8+5

@(private)
pack_name :: proc(id:Pack_Id,buffer:^[PACK_NAME]u8) -> string {
    text:[64]u8
    copy(buffer[:],writer_text(id.writer,&text))
    buffer[32]='-'
    digits:="0123456789abcdef"
    for i in 0..<8 {buffer[33+i]=digits[(id.seq>>(4*uint(7-i)))&15]}
    copy(buffer[41:],".pack")
    return string(buffer[:])
}

@(private)
pack_name_parse :: proc(name:string) -> (id:Pack_Id,ok:bool) {
    if len(name)!=PACK_NAME || name[32]!='-' || name[41:]!=".pack" {return}
    for i in 0..<16 {
        high:=hex_digit(name[2*i]) or_return
        low:=hex_digit(name[2*i+1]) or_return
        id.writer[i]=high<<4|low
    }
    for i in 0..<8 {
        d:=hex_digit(name[33+i]) or_return
        id.seq=id.seq<<4|u32(d)
    }
    return id,true
}

// What scanning a pack hands each valid commit: its frames since the last.
@(private)
Scanned :: struct {
    head:Frame_Head,
    at:i64,
    payload:[2]int, // into the scan's payloads, of a frame that is not a chunk
}

@(private)
Scan :: struct {
    frames:[dynamic]Scanned,
    payloads:[dynamic]u8,
    committed:i64, // end of the last valid commit
    last:i64,      // its time
}

@(private) SCAN_WINDOW :: 1<<20

// Reads the frames of a pack without trailer from `from`, the end of a commit,
// up to size, and hands those of each valid commit to apply; stops at the
// first frame that is not whole and valid. scan.committed is then where the
// next scan begins.
@(private)
pack_scan :: proc(file:^os.File,from,size:i64,scan:^Scan,apply:proc(data:rawptr,scan:^Scan,time:i64) -> Error,data:rawptr) -> Error {
    scan.committed=from
    clear(&scan.frames)
    clear(&scan.payloads)
    window,e:=make([]u8,SCAN_WINDOW,context.temp_allocator)
    if e!=nil {return .Out_Of_Memory}
    defer delete(window,context.temp_allocator)
    window_at,window_len:i64=-1,0
    count:u32
    sum:u64
    at:=from
    // Bytes [offset, offset+n) of the pack from the window, read again where needed.
    view :: proc(file:^os.File,window:[]u8,window_at,window_len:^i64,offset,n,size:i64) -> []u8 {
        if offset<0 || n<0 || offset+n>size || n>i64(len(window)) {return nil}
        if window_at^<0 || offset<window_at^ || offset+n>window_at^+window_len^ {
            want:=min(i64(len(window)),size-offset)
            got,_:=os.read_at(file,window[:want],offset)
            if i64(got)<n {
                window_at^=-1
                return nil
            }
            window_at^,window_len^=offset,i64(got)
        }
        return window[offset-window_at^:][:n]
    }
    for at+8<=size {
        word:=view(file,window,&window_at,&window_len,at,8,size)
        if word==nil {break}
        if intrinsics.unaligned_load((^u64)(raw_data(word)))==0 {
            at+=8
            continue
        }
        bytes:=view(file,window,&window_at,&window_len,at,size_of(Frame_Head),size)
        if bytes==nil {break}
        head:=intrinsics.unaligned_load((^Frame_Head)(raw_data(bytes)))
        if !head_valid(&head) {break}
        end:=head_end(at,head)
        if end>size {break}
        if head.kind==.Commit {
            body:=view(file,window,&window_at,&window_len,at,size_of(Frame_Head)+size_of(Commit_Payload),size)
            if body==nil {break}
            payload:=intrinsics.unaligned_load((^Commit_Payload)(raw_data(body[size_of(Frame_Head):])))
            if payload.frames!=count || payload.heads!=sum || payload.reserved!=0 || count==0 {break}
            apply(data,scan,payload.time) or_return
            scan.committed,scan.last=end,payload.time
            clear(&scan.frames)
            clear(&scan.payloads)
            count,sum=0,0
            at=end
            continue
        }
        length:=i64(size_of(Frame_Head))+(0 if head.kind==.Chunk else i64(head.stored))
        body:=view(file,window,&window_at,&window_len,at,length,size)
        if body==nil {break}
        frame:=Scanned{head=head,at=at}
        if head.kind!=.Chunk {
            start:=len(scan.payloads)
            if _,e:=append(&scan.payloads,..body[size_of(Frame_Head):]);e!=nil {return .Out_Of_Memory}
            frame.payload={start,len(scan.payloads)}
        }
        if _,e:=append(&scan.frames,frame);e!=nil {return .Out_Of_Memory}
        count+=1
        sum+=frame_sum(body,at)
        at=end
    }
    return .None
}
