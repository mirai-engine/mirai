package store

import "base:intrinsics"
import "core:crypto"
import "core:hash/xxhash"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "mirai:std/base"

// One sweep runs at a time on a root, by the claim tmp/sweep/owner. It marks
// what the live roots reach (every ref, every lease's addresses, what its
// caller names) and what was written or touched within GRACE; copies the live
// chunks of sealed packs that are mostly dead, or small, into its own pack;
// writes the next generation of every sealed pack, refs folded; retires the
// replaced packs; and then rechecks the commits other writers made meanwhile,
// copying back from a retired pack what one of them touched or named. Active
// packs of live writers are never touched; a pack whose writer's lease is
// gone is sealed at its last commit. A retired pack is deleted once no writer
// can still be on its way to name it: at once when no other writer runs, else
// by the next sweep.

@(private) TMP_STALE :: time.Hour
@(private) SWEEP_FOLDER :: "tmp/sweep"

@(private)
Claim_Kind :: enum u8 {Lease}

@(private)
CLAIM_PREFIXES :: [Claim_Kind]string{.Lease="l-"}

// The points of a sweep, a commit and a listing where a test runs what other
// values do meanwhile.
@(private)
Sweep_Step :: enum u8 {
    Collected, // a sweep read the leases
    Marked,
    Published,
    Rechecked,
    Claimed,   // a sweep found the claim of a holder that ended, before taking it
    Verified,  // a commit looked its batch up against the newest generation
    Committed, // a commit wrote its commit frame
    Names,     // a listing of namespaces collected them
}

Sweep_Result :: struct {
    bytes:i64,    // of the packs removed and closed: freed, unless another process holds them
    held:i64,     // of the packs removed that this value lent and keeps open: freed when it closes
    chunks:int,   // dead chunks dropped
    packs:int,    // packs retired
    skipped:int,  // files that would not delete, left for the next sweep
}

Usage :: struct {
    bytes:i64,
    packs:int,
}

@(private)
Live_Set :: map[Hash]struct{}

// What the packs folder holds.
usage :: proc(s:^Store) -> (total:Usage,error:Error) {
    if s==nil || s.state==nil {return {},.Invalid_Argument}
    buffer:[PATH_BYTES]u8
    entries:=io_list(s,join(&buffer,s.root,"packs") or_return) or_return
    defer os.file_info_slice_delete(entries,s.state.allocator)
    for e in entries {
        if _,ok:=pack_name_parse(e.name);ok {
            total.bytes+=e.size
            total.packs+=1
        }
    }
    return total,.None
}

@(private)
Sweep :: struct {
    s:^Store,
    now:i64,
    live:Live_Set,          // roots named by refs, leases and the caller
    marks_generation:[]bool,
    marks_table:[]bool,
    buffers:[NODE_LEVEL_MAX+2][]u8,
    compacted:[]bool,       // per pack of the store
    moved:map[Hash]Moved,   // every chunk of the compacted packs, to copy back from
    copied:map[Hash]struct{},
    revive:map[Hash]Moved,  // live chunks only a retired pack holds, copied back
    leases:[dynamic]Lease_Info, // as the sweep read them
    generation:u64,         // the one it publishes
    out:Sweep_Out,
    result:Sweep_Result,
}

@(private)
Moved :: struct {
    pack:int,
    location:Location,
}

// The pack a sweep copies into.
@(private)
Sweep_Out :: struct {
    id:Pack_Id,
    file:^os.File,
    end:i64,
    frames:[dynamic]Own_Frame,
    stage:^Stage,
}

sweep :: proc(s:^Store,live:[]Hash,now:Maybe(time.Time)=nil) -> (result:Sweep_Result,error:Error) {
    if s==nil || s.state==nil {return {},.Invalid_Argument}
    at:=now.? or_else time.now()
    // Another sweep running on the root does this one's work.
    if sweep_own(s,at)!=.None {return {},.None}
    defer sweep_release(s)
    state:=s.state
    sync.mutex_lock(&state.lock)
    defer sync.mutex_unlock(&state.lock)
    // This value's own pack is sealed, so that what it wrote is folded too.
    commit_locked(s,at._nsec) or_return
    if state.writer.open {
        writer_seal_locked(s) or_return
        state.writer.seq+=1
    }
    claims_settle(s,at) or_return
    w:=Sweep{s=s,now=at._nsec}
    w.live=make(Live_Set,s.state.allocator)
    w.moved=make(map[Hash]Moved,s.state.allocator)
    w.copied=make(map[Hash]struct{},s.state.allocator)
    w.revive=make(map[Hash]Moved,s.state.allocator)
    w.leases=make([dynamic]Lease_Info,0,0,s.state.allocator)
    defer {
        delete(w.live)
        delete(w.moved)
        delete(w.copied)
        delete(w.revive)
        delete(w.leases)
        delete(w.marks_generation,s.state.allocator)
        delete(w.marks_table,s.state.allocator)
        delete(w.compacted,s.state.allocator)
        for b in w.buffers {delete(b,s.state.allocator)}
        sweep_out_close(&w)
        state.recording=false
        clear(&state.recent)
    }
    live_add(&w.live,live) or_return
    leases_collect(s,&w.live,at,&w.leases) or_return
    sweep_step(s,.Collected)
    refresh_locked(s) or_return
    retired_load_locked(s) or_return
    clear(&state.recent)
    state.recording=true
    dead_writers_find(&w) or_return
    sweep_mark(&w) or_return
    sweep_step(s,.Marked)
    // What earlier sweeps retired and nothing waits on goes before anything is written,
    // which frees space on a full volume.
    retired_prune(&w,true) or_return
    sweep_compact(&w) or_return
    generation_publish(&w) or_return
    // Another sweep published this generation: it owns it, and this one retires nothing.
    if w.generation==0 {return w.result,.None}
    // Retired only once the generation that no longer names them is published.
    for compacted,i in w.compacted {
        if !compacted {continue}
        p:=&state.packs[i]
        from_buffer,to_buffer:[PATH_BYTES]u8
        name:[RETIRED_NAME]u8
        from:=pack_path(s,"packs",p.id,&from_buffer) or_return
        to:=join(&to_buffer,s.root,"retired",retired_name(w.generation,p.id,&name)) or_return
        if io_rename(s,from,to)!=.None {continue}
        w.result.packs+=1
        p.gone=true
    }
    refresh_locked(s) or_return
    sweep_step(s,.Published)
    sweep_recheck(&w) or_return
    sweep_step(s,.Rechecked)
    retired_prune(&w,false) or_return
    generations_prune(s) or_return
    tmp_prune(s,at) or_return
    return w.result,.None
}

@(private)
sweep_step :: proc(s:^Store,step:Sweep_Step) {
    if h:=s.state.hooks;h!=nil && h.step!=nil {h.step(h.data,step)}
}

@(private)
live_add :: proc(set:^Live_Set,hashes:[]Hash) -> Error {
    for hash in hashes {
        if _,error:=map_insert(set,hash,struct{}{});error!=nil {return .Out_Of_Memory}
    }
    return .None
}

@(private)
older_than :: proc(at,now:time.Time,age:time.Duration) -> bool {
    return at._nsec<now._nsec && u64(now._nsec)-u64(at._nsec)>u64(age)
}

// A pack still being written whose writer's lease is gone is dead: a sweep
// folds what it committed and retires it, and never writes into it, since
// its writer may still run (a lease of another machine not refreshed in
// time): that writer finds its lease gone at its next commit and writes its
// batch again elsewhere. The pack is read again first, for commits made up
// to the lease's removal.
@(private)
dead_writers_find :: proc(w:^Sweep) -> Error {
    s:=w.s
    state:=s.state
    for i:=0;i<len(state.packs);i+=1 {
        p:=&state.packs[i]
        if p.indexed || p.sealed || p.own || p.gone || p.damaged || p.retired>0 || p.file==nil {continue}
        name:[2+32]u8
        copy(name[:],"w-")
        text:[64]u8
        copy(name[2:],writer_text(p.id.writer,&text))
        lease_buffer:[PATH_BYTES]u8
        if os.exists(join(&lease_buffer,s.root,"leases",string(name[:])) or_return) {continue}
        pack_load_locked(s,i) or_return
        state.packs[i].dead=true
    }
    return .None
}

// Marks what the roots reach and every chunk written or
// touched within GRACE.
@(private)
sweep_mark :: proc(w:^Sweep) -> Error {
    s:=w.s
    state:=s.state
    g:=&state.generation
    e:mem.Allocator_Error
    w.marks_generation,e=make([]bool,len(g.addresses),s.state.allocator)
    if e!=nil {return .Out_Of_Memory}
    w.marks_table,e=make([]bool,len(state.table.keys),s.state.allocator)
    if e!=nil {return .Out_Of_Memory}
    targets:=make([dynamic]Hash,0,0,context.temp_allocator)
    defer delete(targets)
    refs_each(s,&targets,proc(data:rawptr,namespace,name:string,v:Ref_Value) -> Error {
        if v.address=={} {return .None}
        if _,e:=append((^[dynamic]Hash)(data),v.address);e!=nil {return .Out_Of_Memory}
        return .None
    }) or_return
    live_add(&w.live,targets[:]) or_return
    for target in w.live {walk(w,target,-1,0) or_return}
    for l,i in g.locations {
        if w.now-location_time(s,g.addresses[i],l)<i64(GRACE) {w.marks_generation[i]=true}
    }
    for k,i in state.table.keys {
        if k=={} {continue}
        if w.now-location_time(s,k,state.table.values[i])<i64(GRACE) {w.marks_table[i]=true}
    }
    // What was touched within GRACE and only a retired pack holds comes back.
    for address,touched in state.touched {
        if w.now-touched>=i64(GRACE) {continue}
        walk(w,address,DATA,0) or_return
    }
    return .None
}

@(private)
location_time :: proc(s:^Store,address:Hash,l:Location) -> i64 {
    if touched,ok:=s.state.touched[address];ok && touched>l.time {return touched}
    return l.time
}

// A level of a walk: a data chunk, not a node; -1 is a root of any level.
@(private) DATA :: -2

@(private)
Marked :: enum u8 {Now,Already,Missing}

// Marks a chunk and, when it is a node of the level its parent says (any for
// a root), everything under it, at every level. A chunk only a retired pack
// holds is copied back by this sweep.
@(private)
walk :: proc(w:^Sweep,address:Hash,level:int,depth:int) -> Error {
    if depth>NODE_LEVEL_MAX+1 {return .None}
    s:=w.s
    if w.buffers[depth]==nil {
        b,e:=make([]u8,CHUNK_MAX,s.state.allocator)
        if e!=nil {return .Out_Of_Memory}
        w.buffers[depth]=b
    }
    bytes:[]u8
    switch mark(w,address) {
    case .Already: return .None
    case .Now:
        if level==DATA {return .None}
        read,error:=chunk_bytes_locked(s,address,w.buffers[depth])
        if error==.Out_Of_Memory {return error}
        if error!=.None {return .None}
        bytes=read
    case .Missing:
        if address in w.revive {return .None}
        pack,location,found:=retired_lookup_locked(s,address)
        if !found {return .None}
        read,holds,error:=location_holds_locked(s,pack,location,address,w.buffers[depth])
        if error==.Out_Of_Memory {return error}
        if error!=.None || !holds {return .None}
        if _,e:=map_insert(&w.revive,address,Moved{pack,location});e!=nil {return .Out_Of_Memory}
        if level==DATA {return .None}
        bytes=read
    }
    n,parse_error:=node_parse(bytes)
    if parse_error!=.None || (level>=0 && n.level!=level) {return .None}
    for e in n.entries {
        walk(w,e.address,n.level-1 if n.level>0 else DATA,depth+1) or_return
    }
    return .None
}

// Marks the copy a lookup finds.
@(private)
mark :: proc(w:^Sweep,address:Hash) -> Marked {
    state:=w.s.state
    if slot,found:=table_slot(&state.table,address);found && slot<len(w.marks_table) {
        l:=state.table.values[slot]
        if !location_dead(w.s,int(l.pack),l) {
            if w.marks_table[slot] {return .Already}
            w.marks_table[slot]=true
            return .Now
        }
    }
    g:=&state.generation
    if i,found:=generation_find(g,address);found && i<len(w.marks_generation) {
        l:=g.locations[i]
        if !location_dead(w.s,g.map_pack[l.pack],l) {
            if w.marks_generation[i] {return .Already}
            w.marks_generation[i]=true
            return .Now
        }
    }
    return .Missing
}

// The stored bytes of a chunk with the lock held, in buffer or mapped: what a
// walk parses as a node, which every build stores as it is.
@(private)
chunk_bytes_locked :: proc(s:^Store,address:Hash,buffer:[]u8) -> ([]u8,Error) {
    pack,location,found:=lookup_locked(s,address,readable=false)
    if !found {return nil,.Missing}
    return location_bytes_locked(s,pack,location,buffer)
}

// A slice of a mapping is given only while the file still holds it; a pack
// cut below a location is damaged.
@(private)
location_bytes_locked :: proc(s:^Store,pack:int,location:Location,buffer:[]u8) -> (bytes:[]u8,error:Error) {
    p:=&s.state.packs[pack]
    if p.file==nil {
        path_buffer:[PATH_BYTES]u8
        p.file=io_open(s,pack_file_path(s,p,&path_buffer) or_return) or_return
    }
    end:=i64(location.offset)+i64(location.stored)
    size,size_error:=os.file_size(p.file)
    if size_error!=nil {return nil,os_error(size_error)}
    if end>size {
        p.damaged=true
        return nil,.Corrupt
    }
    if p.sealed && p.view==nil && size>=p.size {
        if mapped,e:=file_map(p.file,p.size);e==.None {p.view=mapped}
    }
    if p.view!=nil && end<=i64(len(p.view)) {
        return p.view[location.offset:][:location.stored],.None
    }
    if len(buffer)<int(location.stored) {return nil,.Invalid_Argument}
    read_exact(p.file,buffer[:location.stored],i64(location.offset)) or_return
    return buffer[:location.stored],.None
}

// Calls visit with the newest value of every ref, from the generation and the fold.
@(private)
refs_each :: proc(s:^Store,data:rawptr,visit:proc(data:rawptr,namespace,name:string,v:Ref_Value) -> Error) -> Error {
    state:=s.state
    g:=&state.generation
    for r in g.refs {
        ns,_:=generation_string(g,r.namespace)
        name,_:=generation_string(g,r.name)
        v,found:=ref_resolve_locked(s,ns,name)
        if !found {continue}
        key_buffer:[2*NAME_MAX+1]u8
        if _,folded:=state.refs[ref_key(ns,name,&key_buffer)];folded && v.pack>=0 {continue}
        visit(data,ns,name,v) or_return
    }
    for key,v in state.refs {
        slash:=strings.index_byte(key,'/')
        if slash<0 {continue}
        resolved,found:=ref_resolve_locked(s,key[:slash],key[slash+1:])
        if !found || resolved.pack!=v.pack || resolved.offset!=v.offset {continue}
        visit(data,key[:slash],key[slash+1:],v) or_return
    }
    return .None
}

// Picks the sealed packs under half live, and the small ones when there are
// several, and copies their live chunks into the sweep's pack.
@(private)
sweep_compact :: proc(w:^Sweep) -> Error {
    s:=w.s
    state:=s.state
    g:=&state.generation
    count:=len(state.packs)
    e:mem.Allocator_Error
    w.compacted,e=make([]bool,count,s.state.allocator)
    if e!=nil {return .Out_Of_Memory}
    total,live,chunks:=make([]i64,count,context.temp_allocator),make([]i64,count,context.temp_allocator),make([]int,count,context.temp_allocator)
    defer {
        delete(total,context.temp_allocator)
        delete(live,context.temp_allocator)
        delete(chunks,context.temp_allocator)
    }
    for l,i in g.locations {
        pack:=g.map_pack[l.pack]
        if location_dead(s,pack,l) {continue}
        total[pack]+=i64(l.stored)
        chunks[pack]+=1
        if w.marks_generation[i] {live[pack]+=i64(l.stored)}
    }
    for k,i in state.table.keys {
        if k=={} {continue}
        l:=state.table.values[i]
        pack:=int(l.pack)
        if location_dead(s,pack,l) {continue}
        total[pack]+=i64(l.stored)
        chunks[pack]+=1
        if w.marks_table[i] {live[pack]+=i64(l.stored)}
    }
    small:=0
    for &p,i in state.packs {
        if pack_foldable(&p) && total[i]<PACK_SMALL && live[i]==total[i] {small+=1}
    }
    for &p,i in state.packs {
        if !pack_foldable(&p) {continue}
        w.compacted[i]=p.dead || live[i]*2<total[i] || total[i]==0 || (small>=2 && total[i]<PACK_SMALL)
    }
    // Of the copies of a live chunk in the packs compacted, the one copied is one every build
    // reads when there is one: the generation then indexes it, whichever copy a table favored.
    chosen:=make(map[Hash]int,16,context.temp_allocator)
    defer delete(chosen)
    order:=make([dynamic]Moved,0,0,context.temp_allocator)
    defer delete(order)
    order_addresses:=make([dynamic]Hash,0,0,context.temp_allocator)
    defer delete(order_addresses)
    choose :: proc(w:^Sweep,chosen:^map[Hash]int,order:^[dynamic]Moved,addresses:^[dynamic]Hash,address:Hash,pack:int,l:Location) -> Error {
        kept:=l
        kept.time=location_time(w.s,address,l)
        if at,found:=chosen[address];found {
            old:=&order[at]
            time:=max(old.location.time,kept.time)
            if int(old.location.codec) not_in CODECS_OPEN && int(l.codec) in CODECS_OPEN {old^=Moved{pack,kept}}
            old.location.time=time
            return .None
        }
        if _,e:=map_insert(chosen,address,len(order));e!=nil {return .Out_Of_Memory}
        if _,e:=append(order,Moved{pack,kept});e!=nil {return .Out_Of_Memory}
        if _,e:=append(addresses,address);e!=nil {return .Out_Of_Memory}
        return .None
    }
    for l,i in g.locations {
        pack:=g.map_pack[l.pack]
        if !w.compacted[pack] || location_dead(s,pack,l) {continue}
        if _,e:=map_insert(&w.moved,g.addresses[i],Moved{pack,l});e!=nil {return .Out_Of_Memory}
        if !w.marks_generation[i] {
            w.result.chunks+=1
            continue
        }
        choose(w,&chosen,&order,&order_addresses,g.addresses[i],pack,l) or_return
    }
    for k,i in state.table.keys {
        if k=={} {continue}
        l:=state.table.values[i]
        pack:=int(l.pack)
        if pack>=count || !w.compacted[pack] || location_dead(s,pack,l) {continue}
        if _,e:=map_insert(&w.moved,k,Moved{pack,l});e!=nil {return .Out_Of_Memory}
        if !w.marks_table[i] {
            w.result.chunks+=1
            continue
        }
        choose(w,&chosen,&order,&order_addresses,k,pack,l) or_return
    }
    for m,at in order {sweep_copy(w,order_addresses[at],m.pack,m.location) or_return}
    for address,moved in w.revive {
        if address in w.copied {continue}
        if _,e:=map_insert(&w.copied,address,struct{}{});e!=nil {return .Out_Of_Memory}
        buffer,e:=make([]u8,moved.location.stored,context.temp_allocator)
        if e!=nil {return .Out_Of_Memory}
        bytes,holds,error:=location_holds_locked(s,moved.pack,moved.location,address,buffer)
        if error==.None && holds {error=sweep_out_add(w,address,bytes,moved.location)}
        delete(buffer,context.temp_allocator)
        if error==.Out_Of_Memory || error==.No_Space || error==.Io {return error}
    }
    return sweep_out_seal(w)
}

@(private)
pack_foldable :: proc(p:^Pack) -> bool {
    return (p.sealed || p.dead) && !p.gone && !p.damaged && p.retired==0
}

// Copies a live chunk into the sweep's pack, with the time of l.
@(private)
sweep_copy :: proc(w:^Sweep,address:Hash,pack:int,l:Location) -> Error {
    if address in w.copied {return .None}
    s:=w.s
    if _,e:=map_insert(&w.copied,address,struct{}{});e!=nil {return .Out_Of_Memory}
    buffer,e:=make([]u8,l.stored,context.temp_allocator)
    if e!=nil {return .Out_Of_Memory}
    defer delete(buffer,context.temp_allocator)
    bytes:=location_bytes_locked(s,pack,l,buffer) or_return
    return sweep_out_add(w,address,bytes,l)
}

// Appends the stored bytes of a chunk to the sweep's pack in the frame they
// had, with the time of from.
@(private)
sweep_out_add :: proc(w:^Sweep,address:Hash,bytes:[]u8,from:Location) -> Error {
    s:=w.s
    out:=&w.out
    if out.file==nil {
        crypto.rand_bytes(out.id.writer[:])
        buffer:[PATH_BYTES]u8
        out.file=io_create(s,pack_path(s,"packs",out.id,&buffer) or_return) or_return
        head:=Pack_Head{writer=out.id.writer,created=w.now}
        copy(head.magic[:],PACK_MAGIC)
        io_write_at(s,out.file,mem.ptr_to_bytes(&head),0) or_return
        out.end=size_of(Pack_Head)
        out.frames=make([dynamic]Own_Frame,0,0,s.state.allocator)
        out.stage=stage_new(s) or_return
        stage_reset(out.stage)
    }
    stage_frame(out.stage,.Chunk,address,bytes,from.time,from.codec,int(from.raw)) or_return
    if len(out.stage.bytes)>=STAGE_BYTES {sweep_out_flush(w) or_return}
    if out.end>=PACK_MAX {sweep_out_seal(w) or_return}
    return .None
}

@(private)
sweep_out_flush :: proc(w:^Sweep) -> Error {
    s:=w.s
    out:=&w.out
    st:=out.stage
    if st==nil || len(st.frames)==0 {return .None}
    base:=align_up(out.end,i64(st.align))
    io_write_at(s,out.file,st.bytes[:],base) or_return
    for f in st.frames {
        at:=base+i64(f.at)
        l:=Location{offset=u64(head_data_at(at,f.head)),stored=f.head.stored,raw=f.head.raw,codec=f.head.codec,align=f.head.align,time=f.data_time}
        if _,e:=append(&out.frames,Own_Frame{kind=.Chunk,address=f.head.address,location=l});e!=nil {return .Out_Of_Memory}
    }
    out.end=base+i64(len(st.bytes))
    stage_reset(st)
    return .None
}

// Seals the sweep's pack and loads it as a sealed pack of the store.
@(private)
sweep_out_seal :: proc(w:^Sweep) -> Error {
    s:=w.s
    out:=&w.out
    if out.file==nil {return .None}
    sweep_out_flush(w) or_return
    size:=pack_seal(s,out.file,out.frames[:],out.end,w.now) or_return
    index:=pack_add_locked(s,out.id) or_return
    p:=&s.state.packs[index]
    p.file,p.created=out.file,w.now
    out.file=nil
    clear(&out.frames)
    if !trailer_load_locked(s,index,size) {return .Corrupt}
    if index>=len(w.compacted) {
        grown,e:=make([]bool,len(s.state.packs),s.state.allocator)
        if e!=nil {return .Out_Of_Memory}
        copy(grown,w.compacted)
        delete(w.compacted,s.state.allocator)
        w.compacted=grown
    }
    return .None
}

@(private)
sweep_out_close :: proc(w:^Sweep) {
    out:=&w.out
    if out.file!=nil {os.close(out.file)}
    delete(out.frames)
    if out.stage!=nil {stage_free(w.s,out.stage)}
    out^={}
}

// Writes the next generation: every sealed pack not compacted, the chunks
// they hold once each, and the refs of the generation and of sealed packs
// folded, and a removed ref is kept while a pack still being written could
// hold an older frame of it. The file is synced and renamed into index/.
@(private)
generation_publish :: proc(w:^Sweep) -> Error {
    s:=w.s
    state:=s.state
    g:=&state.generation
    count:=len(state.packs)
    order:=make([]int,count,context.temp_allocator)
    defer delete(order,context.temp_allocator)
    packs:=make([dynamic]Idx_Pack,0,0,context.temp_allocator)
    defer delete(packs)
    oldest_active:=max(i64)
    for &p,i in state.packs {
        order[i]=-1
        if !p.sealed && !p.gone && !p.damaged && !p.dead && p.retired==0 {oldest_active=min(oldest_active,p.created)}
        if !pack_foldable(&p) || (i<len(w.compacted) && w.compacted[i]) {continue}
        order[i]=len(packs)
        if _,e:=append(&packs,Idx_Pack{writer=p.id.writer,seq=p.id.seq,size=u64(p.size),created=p.created});e!=nil {return .Out_Of_Memory}
    }
    Chunk :: struct {address:Hash,location:Location}
    chunks:=make([dynamic]Chunk,0,len(g.addresses)+state.table.count,context.temp_allocator)
    defer delete(chunks)
    for l,i in g.locations {
        pack:=g.map_pack[l.pack]
        if order[pack]<0 || location_dead(s,pack,l) {continue}
        c:=Chunk{g.addresses[i],l}
        c.location.pack=u32(order[pack])
        c.location.time=location_time(s,c.address,l)
        if _,e:=append(&chunks,c);e!=nil {return .Out_Of_Memory}
    }
    for k,i in state.table.keys {
        if k=={} {continue}
        l:=state.table.values[i]
        pack:=int(l.pack)
        if pack>=count || order[pack]<0 || location_dead(s,pack,l) {continue}
        c:=Chunk{k,l}
        c.location.pack=u32(order[pack])
        c.location.time=location_time(s,k,l)
        if _,e:=append(&chunks,c);e!=nil {return .Out_Of_Memory}
    }
    slice.sort_by(chunks[:],proc(a,b:Chunk) -> bool {return hash_less(a.address,b.address)})
    // Of several copies, one every build reads.
    unique:=0
    for c in chunks {
        if unique>0 && chunks[unique-1].address==c.address {
            kept:=&chunks[unique-1].location
            time:=max(kept.time,c.location.time)
            if int(kept.codec) not_in CODECS_OPEN && int(c.location.codec) in CODECS_OPEN {kept^=c.location}
            kept.time=time
            continue
        }
        chunks[unique]=c
        unique+=1
    }
    resize(&chunks,unique)
    // Refs.
    Folded :: struct {namespace,name:string,address:Hash,time:i64}
    Collect :: struct {w:^Sweep,refs:[dynamic]Folded,oldest_active:i64}
    collect:=Collect{w=w,refs=make([dynamic]Folded,0,0,context.temp_allocator),oldest_active=oldest_active}
    defer delete(collect.refs)
    refs_each(s,&collect,proc(data:rawptr,namespace,name:string,v:Ref_Value) -> Error {
        c:=(^Collect)(data)
        w:=c.w
        state:=w.s.state
        value:=v
        if v.pack>=0 && !pack_foldable(&state.packs[v.pack]) {
            // A frame of a pack still being written stays there; the generation keeps what it had.
            indexed,found:=generation_ref(&state.generation,namespace,name)
            if !found {return .None}
            value={address=indexed.address,time=indexed.time,pack=-1}
        }
        if _,e:=append(&c.refs,Folded{namespace,name,value.address,value.time});e!=nil {return .Out_Of_Memory}
        return .None
    }) or_return
    // Removed refs the fold no longer shows still hide older frames of packs being written.
    for r in g.refs {
        if r.address!={} || r.time<oldest_active {continue}
        ns,_:=generation_string(g,r.namespace)
        name,_:=generation_string(g,r.name)
        key_buffer:[2*NAME_MAX+1]u8
        if v,folded:=state.refs[ref_key(ns,name,&key_buffer)];folded && v.time>r.time {continue}
        if _,e:=append(&collect.refs,Folded{ns,name,{},r.time});e!=nil {return .Out_Of_Memory}
    }
    for key,v in state.refs {
        if v.address!={} || v.time<oldest_active || v.pack<0 || !pack_foldable(&state.packs[v.pack]) {continue}
        slash:=strings.index_byte(key,'/')
        if slash<0 {continue}
        if resolved,found:=ref_resolve_locked(s,key[:slash],key[slash+1:]);found || resolved.time>v.time {continue}
        if _,e:=append(&collect.refs,Folded{key[:slash],key[slash+1:],{},v.time});e!=nil {return .Out_Of_Memory}
    }
    slice.sort_by(collect.refs[:],proc(a,b:Folded) -> bool {return ref_compare(a.namespace,a.name,b.namespace,b.name)<0})
    // One record of each name: the newest.
    kept:=0
    for r in collect.refs {
        if kept>0 && ref_compare(collect.refs[kept-1].namespace,collect.refs[kept-1].name,r.namespace,r.name)==0 {
            if r.time>collect.refs[kept-1].time {collect.refs[kept-1]=r}
            continue
        }
        collect.refs[kept]=r
        kept+=1
    }
    refs:=collect.refs[:kept]
    names_bytes:=0
    for r in refs {names_bytes+=2+len(r.namespace)+len(r.name)}
    // Layout.
    head:=Idx_Head{number=g.number+1,packs=u32(len(packs)),refs=u32(len(refs)),chunks=u64(len(chunks)),names=u32(names_bytes)}
    copy(head.magic[:],IDX_MAGIC)
    size:=size_of(Idx_Head)+len(packs)*size_of(Idx_Pack)+FANOUT*4+len(chunks)*(size_of(Hash)+size_of(Location))+len(refs)*size_of(Idx_Ref)+names_bytes+8
    bytes,e:=make([]u8,size,context.temp_allocator)
    if e!=nil {return .Out_Of_Memory}
    defer delete(bytes,context.temp_allocator)
    at:=0
    copy(bytes[at:],mem.ptr_to_bytes(&head));at+=size_of(Idx_Head)
    copy(bytes[at:],slice.to_bytes(packs[:]));at+=len(packs)*size_of(Idx_Pack)
    fanout:=([^]u32)(raw_data(bytes[at:]))[:FANOUT];at+=FANOUT*4
    for c in chunks {fanout[int(c.address[0])<<8|int(c.address[1])]+=1}
    for i in 1..<FANOUT {fanout[i]+=fanout[i-1]}
    for c in chunks {
        a:=c.address
        copy(bytes[at:],a[:])
        at+=size_of(Hash)
    }
    for c in chunks {
        l:=c.location
        copy(bytes[at:],mem.ptr_to_bytes(&l))
        at+=size_of(Location)
    }
    names_at:=at+len(refs)*size_of(Idx_Ref)
    names:=0
    for r in refs {
        ns_offset:=names
        bytes[names_at+names]=u8(len(r.namespace))
        copy(bytes[names_at+names+1:],r.namespace)
        names+=1+len(r.namespace)
        name_offset:=names
        bytes[names_at+names]=u8(len(r.name))
        copy(bytes[names_at+names+1:],r.name)
        names+=1+len(r.name)
        entry:=Idx_Ref{namespace=u32(ns_offset),name=u32(name_offset),address=r.address,time=r.time}
        copy(bytes[at:],mem.ptr_to_bytes(&entry))
        at+=size_of(Idx_Ref)
    }
    check:=xxhash.XXH3_64_default(bytes[:size-8])
    intrinsics.unaligned_store((^u64)(raw_data(bytes[size-8:])),check)
    buffer:[PATH_BYTES]u8
    name:[GENERATION_NAME]u8
    path:=join(&buffer,s.root,"index",generation_name(head.number,&name)) or_return
    // Published only when no other sweep published this number: exactly one owns it.
    taken:=file_publish(s,path,{bytes}) or_return
    if taken {return .None}
    w.generation=head.number
    return .None
}

// Folds the commits other writers made since the mark: a chunk one touched,
// or one a ref of theirs reaches, that is now only in a retired pack is
// copied back and a generation that holds it is published.
@(private)
sweep_recheck :: proc(w:^Sweep) -> Error {
    s:=w.s
    state:=s.state
    if len(w.moved)==0 && state.retired.count==0 {return .None}
    visited:=make(map[Hash]struct{},16,context.temp_allocator)
    defer delete(visited)
    recent:=make([]Recent,len(state.recent),context.temp_allocator)
    defer delete(recent,context.temp_allocator)
    copy(recent,state.recent[:])
    restored:=0
    for r in recent {
        switch r.kind {
        case .Touch: restored+=recheck_walk(w,r.address,DATA,0,&visited) or_return
        case .Ref:
            text:[64]u8
            if v,found:=ref_resolve_locked(s,"",hex(r.address,&text));found {restored+=recheck_walk(w,v.address,-1,0,&visited) or_return}
            restored+=recheck_walk(w,r.address,-1,0,&visited) or_return
        case .Pad,.Chunk,.Tombstone,.Commit:
        }
    }
    if restored==0 {return .None}
    sweep_out_seal(w) or_return
    for &c in w.compacted {c=false}
    w.generation=0
    generation_publish(w) or_return
    return refresh_locked(s)
}

// Copies back what is missing under address from the packs a sweep retired.
@(private)
recheck_walk :: proc(w:^Sweep,address:Hash,level:int,depth:int,visited:^map[Hash]struct{}) -> (restored:int,error:Error) {
    if depth>NODE_LEVEL_MAX+1 || address in visited^ {return 0,.None}
    if _,e:=map_insert(visited,address,struct{}{});e!=nil {return 0,.Out_Of_Memory}
    s:=w.s
    if w.buffers[depth]==nil {
        b,e:=make([]u8,CHUNK_MAX,s.state.allocator)
        if e!=nil {return 0,.Out_Of_Memory}
        w.buffers[depth]=b
    }
    bytes:[]u8
    if _,_,found:=lookup_locked(s,address,readable=false);found {
        if level==DATA {return 0,.None}
        bytes=chunk_bytes_locked(s,address,w.buffers[depth]) or_return
    } else {
        moved,in_moved:=w.moved[address]
        if !in_moved {
            pack,location,found:=retired_lookup_locked(s,address)
            if !found {return 0,.None}
            moved={pack,location}
        }
        holds:bool
        bytes,holds=location_holds_locked(s,moved.pack,moved.location,address,w.buffers[depth]) or_return
        if !holds {return 0,.None}
        kept:=moved.location
        kept.time=max(kept.time,w.now)
        sweep_out_add(w,address,bytes,kept) or_return
        restored=1
        if level==DATA {return restored,.None}
    }
    n,parse_error:=node_parse(bytes)
    if parse_error!=.None || (level>=0 && n.level!=level) {return restored,.None}
    children:=make([]Entry,len(n.entries),context.temp_allocator)
    defer delete(children,context.temp_allocator)
    copy(children,n.entries)
    for e in children {
        restored+=recheck_walk(w,e.address,n.level-1 if n.level>0 else DATA,depth+1,visited) or_return
    }
    return restored,.None
}

@(private)
retired_list :: proc(s:^Store) -> (entries:[]os.File_Info,error:Error) {
    buffer:[PATH_BYTES]u8
    return io_list(s,join(&buffer,s.root,"retired") or_return)
}

// Deletes the retired packs nothing can still need. A pack retired by the
// sweep that published generation g goes once every other writer's lease
// carries g or later (none still commits a batch looked up before g) and
// every other lease carries g or later or is what this sweep marked from;
// before compaction, a pack this sweep copies back from stays.
@(private)
retired_prune :: proc(w:^Sweep,before:bool) -> Error {
    s:=w.s
    state:=s.state
    scratch:=make(Live_Set,state.allocator)
    defer delete(scratch)
    infos:=make([dynamic]Lease_Info,0,0,state.allocator)
    defer delete(infos)
    leases_collect(s,&scratch,time.Time{_nsec=w.now},&infos) or_return
    own:[2+32]u8
    copy(own[:],"w-")
    text:[64]u8
    copy(own[2:],writer_text(state.writer.id,&text))
    entries:=retired_list(s) or_return
    defer os.file_info_slice_delete(entries,state.allocator)
    files: for e in entries {
        generation,id,ok:=retired_name_parse(e.name)
        if !ok {continue}
        for &info in infos {
            name:=string(info.name[:info.name_len])
            if info.generation>=generation || name==string(own[:]) {continue}
            if !strings.has_prefix(name,"w-") {
                unchanged:=false
                for &read in w.leases {
                    if string(read.name[:read.name_len])==name && read.checksum==info.checksum {unchanged=true}
                }
                if unchanged {continue}
            }
            continue files
        }
        index:=pack_find(s,id)
        if before {
            for _,moved in w.revive {
                if moved.pack==index {continue files}
            }
        }
        p:^Pack=&state.packs[index] if index>=0 else nil
        if p!=nil && !p.lent {pack_close(p)}
        if io_remove(s,e.fullpath)==.None {
            if p!=nil && p.lent && (p.view!=nil || p.file!=nil) {
                w.result.held+=e.size
            } else {
                w.result.bytes+=e.size
                if p!=nil {p.pruned=true}
            }
        } else if os.exists(e.fullpath) {
            w.result.skipped+=1
        }
    }
    return .None
}

// Removes generations older than the one before the current.
@(private)
generations_prune :: proc(s:^Store) -> Error {
    current:=s.state.generation.number
    buffer:[PATH_BYTES]u8
    entries:=io_list(s,join(&buffer,s.root,"index") or_return) or_return
    defer os.file_info_slice_delete(entries,s.state.allocator)
    for e in entries {
        number,ok:=generation_name_parse(e.name)
        if ok && number+1<current {io_remove(s,e.fullpath)}
    }
    return .None
}

// Removes what was left in tmp/ by writes that stopped.
@(private)
tmp_prune :: proc(s:^Store,now:time.Time) -> Error {
    buffer:[PATH_BYTES]u8
    entries:=io_list(s,join(&buffer,s.root,"tmp") or_return) or_return
    defer os.file_info_slice_delete(entries,s.state.allocator)
    for entry in entries {
        if entry.name=="sweep" || !older_than(entry.modification_time,now,TMP_STALE) {continue}
        base.remove_all(entry.fullpath)
    }
    return .None
}

// Claims tmp/sweep/owner for this process by creating it, which takes no
// data on a full volume. A claim whose holder ended, or of another machine and
// older than TMP_STALE, is taken over by moving it away and making sure what
// moved is the claim judged, never one another sweep made meanwhile.
@(private)
Sweep_Claim :: struct #packed {
    holder:Holder,
    nonce:[16]u8,
}

@(private)
sweep_own :: proc(s:^Store,now:time.Time) -> Error {
    buffer:[PATH_BYTES]u8
    owner:=join(&buffer,s.root,SWEEP_FOLDER,"owner") or_return
    self:=holder_self()
    for attempt in 0..<2 {
        file,error:=io_create(s,owner)
        if error==.None {
            // Who holds it, when there is room to say.
            claim:=Sweep_Claim{holder=self}
            crypto.rand_bytes(claim.nonce[:])
            io_write_at(s,file,mem.ptr_to_bytes(&claim),0)
            os.close(file)
            return .None
        }
        if error!=.Invalid_Argument || attempt==1 {return .Io}
        judged:Sweep_Claim
        stale:=true
        if f,e:=file_open(owner);e==nil {
            info,stat_error:=os.fstat(f,context.temp_allocator)
            if read_exact(f,mem.ptr_to_bytes(&judged),0)==.None {
                switch holder_state(judged.holder,self) {
                case .Running: stale=false
                case .Ended:
                case .Unknown: stale=stat_error!=nil || older_than(info.modification_time,now,TMP_STALE)
                }
            } else {
                stale=stat_error!=nil || older_than(info.modification_time,now,TMP_STALE)
            }
            os.close(f)
        } else {
            continue
        }
        if !stale {return .Io}
        sweep_step(s,.Claimed)
        aside_buffer:[PATH_BYTES]u8
        aside:=temp_name(s.root,"claim-",&aside_buffer) or_return
        if rename_replace(owner,aside)!=nil {return .Io}
        moved:Sweep_Claim
        same:=false
        if f,e:=file_open(aside);e==nil {
            same=read_exact(f,mem.ptr_to_bytes(&moved),0)==.None && moved==judged
            os.close(f)
        }
        if !same {
            // Another sweep's claim: it goes back, and that sweep does the work.
            rename_new(aside,owner)
            file_remove(aside)
            return .Io
        }
        file_remove(aside)
    }
    return .Io
}

@(private)
sweep_release :: proc(s:^Store) {
    buffer:[PATH_BYTES]u8
    if owner,error:=join(&buffer,s.root,SWEEP_FOLDER,"owner");error==.None {file_remove(owner)}
}

// Moves path to tmp/sweep/<kind>-<name>, never over another claim: the
// sweep judges it there, away from writers. Nothing is created, so a full
// volume does not stop it.
@(private)
sweep_claim :: proc(s:^Store,path:string,kind:Claim_Kind,name:string,claim_buffer:^[PATH_BYTES]u8) ->
    (claimed:string,error:Error) {
    prefixes:=CLAIM_PREFIXES
    entry:[2+NAME_MAX]u8
    if len(name)>NAME_MAX {return "",.Invalid_Argument}
    copy(entry[:],prefixes[kind])
    copy(entry[2:],name)
    claimed=join(claim_buffer,s.root,SWEEP_FOLDER,string(entry[:2+len(name)])) or_return
    exists:=rename_new(path,claimed) or_return
    if exists {return "",.Io}
    return claimed,.None
}

@(private)
sweep_restore :: proc(path,claimed:string) -> Error {
    exists:=rename_new(claimed,path) or_return
    if exists {
        if os.is_directory(claimed) {return os_error(base.remove_all(claimed))}
        return os_error(file_remove(claimed))
    }
    return .None
}

// Gives back what a sweep that stopped left claimed.
@(private)
claims_settle :: proc(s:^Store,now:time.Time) -> Error {
    buffer:[PATH_BYTES]u8
    folder:=join(&buffer,s.root,SWEEP_FOLDER) or_return
    entries:=io_list(s,folder) or_return
    defer os.file_info_slice_delete(entries,s.state.allocator)
    prefixes:=CLAIM_PREFIXES
    for entry in entries {
        if len(entry.name)<3 {continue}
        kind,found:=Claim_Kind(0),false
        for prefix,k in prefixes {
            if strings.has_prefix(entry.name,prefix) {kind,found=k,true}
        }
        if !found {continue}
        name:=entry.name[2:]
        origin_buffer:[PATH_BYTES]u8
        origin:string
        origin_error:Error
        switch kind {
        case .Lease:
            if !name_valid(name) {continue}
            origin,origin_error=join(&origin_buffer,s.root,"leases",name)
        }
        if origin_error!=.None {continue}
        sweep_restore(origin,entry.fullpath)
    }
    return .None
}

Scrub_Result :: struct {
    chunks:int,
    bytes:i64,
    damaged:int,
    finished:bool, // the pass reached the end of the sealed packs and begins again
}

// Checks the chunks of sealed packs against their addresses, about budget
// bytes from where the last scrub of this value stopped; each damaged copy
// gets a Tombstone frame, so it is no longer read, and a sweep drops it.
scrub :: proc(s:^Store,budget:i64,now:Maybe(time.Time)=nil) -> (result:Scrub_Result,error:Error) {
    if s==nil || s.state==nil || budget<=0 {return {},.Invalid_Argument}
    at:=(now.? or_else time.now())._nsec
    state:=s.state
    st:=stage_take(s) or_return
    defer stage_give(s,st)
    {
        sync.mutex_lock(&state.lock)
        defer sync.mutex_unlock(&state.lock)
        refresh_locked(s) or_return
        Spot :: struct {pack:int,location:Location,address:Hash}
        spots:=make([dynamic]Spot,0,0,context.temp_allocator)
        defer delete(spots)
        g:=&state.generation
        for l,i in g.locations {
            if _,e:=append(&spots,Spot{g.map_pack[l.pack],l,g.addresses[i]});e!=nil {return {},.Out_Of_Memory}
        }
        for k,i in state.table.keys {
            if k=={} {continue}
            l:=state.table.values[i]
            if !state.packs[l.pack].sealed {continue}
            if _,e:=append(&spots,Spot{int(l.pack),l,k});e!=nil {return {},.Out_Of_Memory}
        }
        slice.sort_by(spots[:],proc(a,b:Spot) -> bool {
            if a.pack!=b.pack {return a.pack<b.pack}
            return a.location.offset<b.location.offset
        })
        buffer,e:=make([]u8,CHUNK_MAX,context.temp_allocator)
        if e!=nil {return {},.Out_Of_Memory}
        defer delete(buffer,context.temp_allocator)
        result.finished=true
        for spot in spots {
            if spot.pack<state.scrub_pack || (spot.pack==state.scrub_pack && int(spot.location.offset)<state.scrub_at) {continue}
            if result.bytes>=budget {
                state.scrub_pack,state.scrub_at=spot.pack,int(spot.location.offset)
                result.finished=false
                break
            }
            // A frame of a codec this build lacks is for a build that has it to check.
            if location_dead(s,spot.pack,spot.location) || !codec_readable(s,spot.location.codec) {continue}
            _,holds,read_error:=location_holds_locked(s,spot.pack,spot.location,spot.address,buffer)
            if read_error==.Out_Of_Memory {return result,read_error}
            result.chunks+=1
            result.bytes+=i64(spot.location.stored)
            if read_error==.None && holds {continue}
            tomb_stage(s,st,spot.pack,spot.location,spot.address) or_return
            result.damaged+=1
        }
        if result.finished {state.scrub_pack,state.scrub_at=0,0}
    }
    if len(st.frames)==0 {return result,.None}
    stage_write(s,st,at) or_return
    return result,commit(s,time.Time{_nsec=at})
}

@(private)
tomb_stage :: proc(s:^Store,st:^Stage,pack:int,location:Location,address:Hash) -> Error {
    id:=s.state.packs[pack].id
    payload:=Tomb_Payload{writer=id.writer,seq=id.seq,offset=location.offset}
    return stage_frame(st,.Tombstone,address,mem.ptr_to_bytes(&payload))
}

// Looks up what roots names that before did not against the newest
// generation, everything under each, and copies back and commits what a sweep
// retired: the generation it was checked against. What is in no pack at all
// (an object still on its way) is not this lease's to bring back.
@(private)
roots_settle :: proc(s:^Store,roots,before:[]Hash) -> (generation:u64,error:Error) {
    if s==nil || s.state==nil {return 0,.Invalid_Argument}
    state:=s.state
    st:^Stage
    defer if st!=nil {stage_free(s,st)}
    {
        sync.mutex_lock(&state.lock)
        defer sync.mutex_unlock(&state.lock)
        refresh_locked(s) or_return
        known:=make(map[Hash]struct{},len(before),context.temp_allocator)
        defer delete(known)
        for b in before {map_insert(&known,b,struct{}{})}
        visited:=make(map[Hash]struct{},16,context.temp_allocator)
        defer delete(visited)
        for r in roots {
            if r in known {continue}
            restore_locked(s,&st,r,-1,0,&visited) or_return
        }
        generation=state.generation.number
    }
    if st==nil || len(st.frames)==0 {return generation,.None}
    at:=time.now()._nsec
    stage_write(s,st,at) or_return
    commit(s,time.Time{_nsec=at}) or_return
    return generation,.None
}

// Stages into st, made when needed, what is missing under address and a
// retired pack holds, at every level; missing counts what no pack holds.
@(private)
restore_locked :: proc(s:^Store,st:^^Stage,address:Hash,level,depth:int,visited:^map[Hash]struct{}) -> (missing:int,error:Error) {
    if depth>NODE_LEVEL_MAX+1 || address in visited^ {return 0,.None}
    if _,e:=map_insert(visited,address,struct{}{});e!=nil {return 0,.Out_Of_Memory}
    buffer,e:=make([]u8,CHUNK_MAX,context.temp_allocator)
    if e!=nil {return 0,.Out_Of_Memory}
    defer delete(buffer,context.temp_allocator)
    bytes:[]u8
    if pack,location,found:=lookup_locked(s,address,readable=false);found {
        if level==DATA {return 0,.None}
        read,read_error:=location_bytes_locked(s,pack,location,buffer)
        if read_error!=.None {return 0,read_error if read_error==.Out_Of_Memory else .None}
        bytes=read
    } else {
        retired_load_locked(s) or_return
        pack,location,in_retired:=retired_lookup_locked(s,address)
        if !in_retired {return 1,.None}
        read,holds,read_error:=location_holds_locked(s,pack,location,address,buffer)
        if read_error!=.None || !holds {return 1,.None}
        if st^==nil {
            st^=stage_new(s) or_return
            stage_reset(st^)
        }
        stage_frame(st^,.Chunk,address,read,location.time,location.codec,int(location.raw)) or_return
        if level==DATA {return 0,.None}
        bytes=read
    }
    n,parse_error:=node_parse(bytes)
    if parse_error!=.None || (level>=0 && n.level!=level) {return 0,.None}
    children,f:=make([]Entry,len(n.entries),context.temp_allocator)
    if f!=nil {return 0,.Out_Of_Memory}
    defer delete(children,context.temp_allocator)
    copy(children,n.entries)
    for c in children {
        missing+=restore_locked(s,st,c.address,n.level-1 if n.level>0 else DATA,depth+1,visited) or_return
    }
    return missing,.None
}

// Adds the packs that hold a ref's target and everything under it.
@(private)
root_packs_locked :: proc(s:^Store,target:Hash,packs:^map[int]struct{},visited:^map[Hash]struct{}) {
    text:[64]u8
    if v,found:=ref_resolve_locked(s,"",hex(target,&text));found {tree_packs_locked(s,v.address,-1,0,packs,visited)}
    tree_packs_locked(s,target,-1,0,packs,visited)
}

@(private)
tree_packs_locked :: proc(s:^Store,address:Hash,level,depth:int,packs:^map[int]struct{},visited:^map[Hash]struct{}) {
    if depth>NODE_LEVEL_MAX+1 || address in visited^ {return}
    map_insert(visited,address,struct{}{})
    pack,location,found:=find_locked(s,address,readable=false)
    if !found {return}
    map_insert(packs,pack,struct{}{})
    if level==DATA {return}
    buffer,e:=make([]u8,CHUNK_MAX,context.temp_allocator)
    if e!=nil {return}
    defer delete(buffer,context.temp_allocator)
    bytes,read_error:=location_bytes_locked(s,pack,location,buffer)
    if read_error!=.None {return}
    n,parse_error:=node_parse(bytes)
    if parse_error!=.None || (level>=0 && n.level!=level) {return}
    children,f:=make([]Entry,len(n.entries),context.temp_allocator)
    if f!=nil {return}
    defer delete(children,context.temp_allocator)
    copy(children,n.entries)
    for c in children {tree_packs_locked(s,c.address,n.level-1 if n.level>0 else DATA,depth+1,packs,visited)}
}
