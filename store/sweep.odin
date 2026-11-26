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

// A sweep holds the root's lock exclusive, so no batch is open anywhere while
// it runs: every lookup a writer made is committed, and what it found is named
// by a ref, a lease or the sweep's caller, or was written or touched within
// GRACE. It marks what the live roots reach (every ref, every lease's
// addresses, what its caller names) and what was written or touched within
// GRACE; copies the live chunks of sealed packs that are mostly dead, or small,
// into its own pack (with reclaim, of every one that holds a dead chunk);
// writes the next generation of every sealed pack, refs folded; and removes the
// replaced packs. Packs of live writers, which hold their lock, are never
// touched; a pack whose writer ended is folded up to its last commit.

@(private) TMP_STALE :: time.Hour
@(private) GONE_PREFIX :: "gone-"

Sweep_Result :: struct {
    bytes:i64,    // of the packs removed and closed: freed, unless another process holds them
    held:i64,     // of the packs removed that this value lent and keeps mapped: freed when it closes
    chunks:int,   // dead chunks dropped
    packs:int,    // packs removed
    skipped:int,  // files that would not delete, left for the next sweep
    busy:bool,    // another sweep runs, or a batch is open: nothing was swept, sweep again later
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
    out:Sweep_Out,
    result:Sweep_Result,
    reclaim:bool,
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

// reclaim: the bytes of what no root reaches leave the disk in this sweep.
// Every sealed pack that holds a dead chunk is compacted, and what this value
// wrote is kept only when a root reaches it, however fresh: live must then
// name all of it the caller still needs. What other writers wrote within
// GRACE stays. A sweep never waits: while another sweep runs or a batch is
// open, of any value, it returns busy and sweeps nothing.
sweep :: proc(s:^Store,live:[]Hash,now:Maybe(time.Time)=nil,reclaim:=false) -> (result:Sweep_Result,error:Error) {
    if s==nil || s.state==nil {return {},.Invalid_Argument}
    at:=now.? or_else time.now()
    state:=s.state
    sync.mutex_lock(&state.gate)
    defer sync.mutex_unlock(&state.gate)
    sync.mutex_lock(&state.lock)
    defer sync.mutex_unlock(&state.lock)
    // Another thread of this value is between batch_enter and batch_leave: its
    // batch is not this caller's to commit.
    if state.entered>0 || state.writer.inflight>0 {return {busy=true},.None}
    commit_locked(s,at._nsec) or_return
    if state.shared {return {busy=true},.None}
    locked:=file_lock(state.root_lock,.Exclusive,false) or_return
    if !locked {return {busy=true},.None}
    defer file_unlock(state.root_lock)
    // This value's own pack is sealed, so that what it wrote is folded too.
    if state.writer.open {
        writer_seal_locked(s) or_return
        state.writer.seq+=1
    }
    w:=Sweep{s=s,now=at._nsec,reclaim=reclaim}
    w.live=make(Live_Set,s.state.allocator)
    defer {
        delete(w.live)
        delete(w.marks_generation,s.state.allocator)
        delete(w.marks_table,s.state.allocator)
        delete(w.compacted,s.state.allocator)
        for b in w.buffers {delete(b,s.state.allocator)}
        sweep_out_close(&w)
    }
    // What earlier sweeps could not delete goes before anything is written,
    // which frees space on a full volume.
    tmp_prune(&w,at) or_return
    live_add(&w.live,live) or_return
    leases_collect(s,&w.live) or_return
    refresh_locked(s) or_return
    dead_writers_find(&w) or_return
    sweep_mark(&w) or_return
    sweep_compact(&w) or_return
    generation_publish(&w) or_return
    // Removed only once the generation that no longer names them is published.
    for compacted,i in w.compacted {
        if compacted && !state.packs[i].gone {pack_remove(&w,i)}
    }
    refresh_locked(s) or_return
    generations_prune(s) or_return
    return w.result,.None
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

// A pack still being written whose writer ended, which let its lock go, is
// dead: a sweep folds what it committed and removes it. It is read again
// first, for the commits made up to the end. A pack its writer never gave a
// head holds nothing and goes.
@(private)
dead_writers_find :: proc(w:^Sweep) -> Error {
    s:=w.s
    state:=s.state
    for i:=0;i<len(state.packs);i+=1 {
        p:=&state.packs[i]
        if p.indexed || p.sealed || p.own || p.gone || p.damaged {continue}
        buffer:[PATH_BYTES]u8
        path:=pack_file_path(s,p,&buffer) or_return
        // Opened to write: an exclusive lock on a handle only read can be
        // denied on Windows.
        probe,error:=io_open(s,path,{.Read,.Write})
        if error==.Missing {
            p.gone=true
            continue
        }
        if error!=.None {return error}
        ended,lock_error:=file_lock(probe,.Exclusive,false)
        os.close(probe)
        lock_error or_return
        if !ended {continue}
        pack_load_locked(s,i) or_return
        p=&state.packs[i]
        if p.size==0 {
            if io_remove(s,path)==.None {p.gone=true}
            continue
        }
        p.dead=true
    }
    return .None
}

// Marks what the roots reach and every chunk written or touched within GRACE
// (with reclaim, but those this value wrote).
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
    own:=state.writer.id
    reclaim:=w.reclaim && own!=({})
    for l,i in g.locations {
        if reclaim && int(l.pack)<len(g.packs) && g.packs[l.pack].writer==own {continue}
        if w.now-location_time(s,g.addresses[i],l)<i64(GRACE) {w.marks_generation[i]=true}
    }
    for k,i in state.table.keys {
        if k=={} {continue}
        l:=state.table.values[i]
        if reclaim && int(l.pack)<len(state.packs) && state.packs[l.pack].id.writer==own {continue}
        if w.now-location_time(s,k,l)<i64(GRACE) {w.marks_table[i]=true}
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

// Marks a chunk and, when it is a node of the level its parent says (any for
// a root), everything under it, at every level.
@(private)
walk :: proc(w:^Sweep,address:Hash,level:int,depth:int) -> Error {
    if depth>NODE_LEVEL_MAX+1 || !mark(w,address) || level==DATA {return .None}
    s:=w.s
    if w.buffers[depth]==nil {
        b,e:=make([]u8,CHUNK_MAX,s.state.allocator)
        if e!=nil {return .Out_Of_Memory}
        w.buffers[depth]=b
    }
    bytes,error:=chunk_bytes_locked(s,address,w.buffers[depth])
    if error==.Out_Of_Memory {return error}
    if error!=.None {return .None}
    n,parse_error:=node_parse(bytes)
    if parse_error!=.None || (level>=0 && n.level!=level) {return .None}
    for e in n.entries {
        walk(w,e.address,n.level-1 if n.level>0 else DATA,depth+1) or_return
    }
    return .None
}

// Marks the copy a lookup finds: false when it was marked already or is
// stored nowhere.
@(private)
mark :: proc(w:^Sweep,address:Hash) -> bool {
    state:=w.s.state
    if slot,found:=table_slot(&state.table,address);found && slot<len(w.marks_table) {
        l:=state.table.values[slot]
        if !location_dead(w.s,int(l.pack),l) {
            if w.marks_table[slot] {return false}
            w.marks_table[slot]=true
            return true
        }
    }
    g:=&state.generation
    if i,found:=generation_find(g,address);found && i<len(w.marks_generation) {
        l:=g.locations[i]
        if !location_dead(w.s,g.map_pack[l.pack],l) {
            if w.marks_generation[i] {return false}
            w.marks_generation[i]=true
            return true
        }
    }
    return false
}

// The stored bytes of a chunk with the lock held, in buffer or mapped: what a
// walk parses as a node, which every build stores as it is.
@(private)
chunk_bytes_locked :: proc(s:^Store,address:Hash,buffer:[]u8) -> ([]u8,Error) {
    pack,location,found:=lookup_locked(s,address)
    if !found {return nil,.Missing}
    return location_bytes_locked(s,pack,location,buffer)
}

// A slice of a mapping is given only while the file still holds it; a pack
// cut below a location is damaged.
@(private)
location_bytes_locked :: proc(s:^Store,pack:int,location:Location,buffer:[]u8) -> (bytes:[]u8,error:Error) {
    file:=pack_file_locked(s,pack) or_return
    p:=&s.state.packs[pack]
    end:=i64(location.offset)+i64(location.stored)
    size,size_error:=os.file_size(file)
    if size_error!=nil {return nil,os_error(size_error)}
    if end>size {
        p.damaged=true
        return nil,.Corrupt
    }
    if p.sealed && p.view==nil && size>=p.size {
        if mapped,e:=file_map(file,p.size);e==.None {p.view=mapped}
    }
    if p.view!=nil && end<=i64(len(p.view)) {
        return p.view[location.offset:][:location.stored],.None
    }
    if len(buffer)<int(location.stored) {return nil,.Invalid_Argument}
    read_exact(file,buffer[:location.stored],i64(location.offset)) or_return
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
        w.compacted[i]=p.dead || live[i]*2<total[i] || total[i]==0 || (small>=2 && total[i]<PACK_SMALL) || (w.reclaim && live[i]<total[i])
        // A pack of the generation that holds nothing live goes before anything
        // is written, which frees space on a full volume: the generation keeps
        // its refs, and what it held is dead to every reader.
        if p.indexed && live[i]==0 {pack_remove(w,i)}
    }
    // Copy each live chunk once, preserving its latest timestamp.
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
            old.location.time=max(old.location.time,kept.time)
            return .None
        }
        if _,e:=map_insert(chosen,address,len(order));e!=nil {return .Out_Of_Memory}
        if _,e:=append(order,Moved{pack,kept});e!=nil {return .Out_Of_Memory}
        if _,e:=append(addresses,address);e!=nil {return .Out_Of_Memory}
        return .None
    }
    for l,i in g.locations {
        pack:=g.map_pack[l.pack]
        if !w.compacted[pack] || location_dead(s,pack,l) {
            if w.compacted[pack] && !w.marks_generation[i] {w.result.chunks+=1}
            continue
        }
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
        if pack>=count || !w.compacted[pack] || location_dead(s,pack,l) {
            if pack<count && w.compacted[pack] && !w.marks_table[i] {w.result.chunks+=1}
            continue
        }
        if !w.marks_table[i] {
            w.result.chunks+=1
            continue
        }
        choose(w,&chosen,&order,&order_addresses,k,pack,l) or_return
    }
    for m,at in order {sweep_copy(w,order_addresses[at],m.pack,m.location) or_return}
    return sweep_out_seal(w)
}

@(private)
Moved :: struct {
    pack:int,
    location:Location,
}

@(private)
pack_foldable :: proc(p:^Pack) -> bool {
    return (p.sealed || p.dead) && !p.gone && !p.damaged
}

// Copies a live chunk into the sweep's pack, with the time of l.
@(private)
sweep_copy :: proc(w:^Sweep,address:Hash,pack:int,l:Location) -> Error {
    s:=w.s
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
    files_make_room_locked(s)
    s.state.files+=1
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
        if !p.sealed && !p.gone && !p.damaged && !p.dead {oldest_active=min(oldest_active,p.created)}
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
    unique:=0
    for c in chunks {
        if unique>0 && chunks[unique-1].address==c.address {
            kept:=&chunks[unique-1].location
            kept.time=max(kept.time,c.location.time)
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
    return file_write(s,s.root,path,{bytes})
}

// Removes a pack the generation no longer names. It leaves packs/ first, so
// that no value loads it again when its file will not delete (one a process
// maps on Windows): the next sweep deletes it from tmp/. What this value lent
// stays mapped until it closes.
@(private)
pack_remove :: proc(w:^Sweep,index:int) {
    s:=w.s
    p:=&s.state.packs[index]
    from_buffer,to_buffer:[PATH_BYTES]u8
    name:[len(GONE_PREFIX)+PACK_NAME]u8
    copy(name[:],GONE_PREFIX)
    pack_name(p.id,(^[PACK_NAME]u8)(&name[len(GONE_PREFIX)]))
    from,from_error:=pack_path(s,"packs",p.id,&from_buffer)
    to,to_error:=join(&to_buffer,s.root,"tmp",string(name[:]))
    if from_error!=.None || to_error!=.None || io_rename(s,from,to)!=.None {return}
    w.compacted[index]=true
    w.result.packs+=1
    p.gone=true
    held:=p.lent && p.view!=nil
    if held {pack_file_close_locked(s,p)} else {pack_close_locked(s,p)}
    if io_remove(s,to)!=.None {
        w.result.skipped+=1
    } else if held {
        w.result.held+=p.size
    } else {
        w.result.bytes+=p.size
    }
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

// Removes the packs earlier sweeps could not delete and what was left in
// tmp/ by writes that stopped.
@(private)
tmp_prune :: proc(w:^Sweep,now:time.Time) -> Error {
    s:=w.s
    buffer:[PATH_BYTES]u8
    entries:=io_list(s,join(&buffer,s.root,"tmp") or_return) or_return
    defer os.file_info_slice_delete(entries,s.state.allocator)
    for entry in entries {
        if strings.has_prefix(entry.name,GONE_PREFIX) {
            if io_remove(s,entry.fullpath)==.None {w.result.bytes+=entry.size} else {w.result.skipped+=1}
            continue
        }
        if older_than(entry.modification_time,now,TMP_STALE) {base.remove_all(entry.fullpath)}
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
    batch_enter(s) or_return
    defer batch_leave(s)
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
            if location_dead(s,spot.pack,spot.location) {continue}
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

