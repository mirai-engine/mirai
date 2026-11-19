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
Claim_Kind :: enum u8 {Lease,Partial}

@(private)
CLAIM_PREFIXES :: [Claim_Kind]string{.Lease="l-",.Partial="p-"}

// The points of a sweep where a test runs what other writers do meanwhile.
@(private)
Sweep_Step :: enum u8 {Marked,Published,Rechecked}

Sweep_Result :: struct {
    bytes:i64,    // of the packs and partial blobs removed
    blobs:int,    // blobs no longer named
    chunks:int,   // dead chunks dropped
    packs:int,    // packs retired
    partials:int, // partial blobs removed
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
    live:Live_Set,          // blobs and roots named by refs, leases and the caller
    marks_generation:[]bool,
    marks_table:[]bool,
    buffers:[NODE_LEVEL_MAX+2][]u8,
    compacted:[]bool,       // per pack of the store
    moved:map[Hash]Moved,   // every chunk of the compacted packs, to copy back from
    copied:map[Hash]struct{},
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
    defer {
        delete(w.live)
        delete(w.moved)
        delete(w.copied)
        delete(w.marks_generation,s.state.allocator)
        delete(w.marks_table,s.state.allocator)
        delete(w.compacted,s.state.allocator)
        for b in w.buffers {delete(b,s.state.allocator)}
        sweep_out_close(&w)
        state.recording=false
        clear(&state.recent)
    }
    live_add(&w.live,live) or_return
    leases_collect(s,&w.live,at) or_return
    // What an earlier sweep retired goes first, which frees space on a full volume.
    retired_before:=retired_list(s) or_return
    retired_remove(&w,retired_before)
    os.file_info_slice_delete(retired_before,s.state.allocator)
    refresh_locked(s) or_return
    clear(&state.recent)
    state.recording=true
    dead_writers_seal(&w) or_return
    sweep_mark(&w) or_return
    sweep_step(s,.Marked)
    sweep_compact(&w) or_return
    generation_publish(&w) or_return
    // Retired only once the generation that no longer names them is published.
    for compacted,i in w.compacted {
        if !compacted {continue}
        p:=&state.packs[i]
        from_buffer,to_buffer:[PATH_BYTES]u8
        from:=pack_path(s,"packs",p.id,&from_buffer) or_return
        to:=pack_path(s,"retired",p.id,&to_buffer) or_return
        if io_rename(s,from,to)!=.None {continue}
        w.result.packs+=1
        p.gone=true
    }
    refresh_locked(s) or_return
    sweep_step(s,.Published)
    sweep_recheck(&w) or_return
    sweep_step(s,.Rechecked)
    retired_delete(&w) or_return
    generations_prune(s) or_return
    bridge_sweep(s,&w.live,at,&w.result) or_return
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

// Seals at its last commit each pack still being written whose writer's lease
// is gone; one that committed nothing is removed.
@(private)
dead_writers_seal :: proc(w:^Sweep) -> Error {
    s:=w.s
    state:=s.state
    for i:=0;i<len(state.packs);i+=1 {
        p:=&state.packs[i]
        if p.indexed || p.sealed || p.own || p.gone || p.damaged || p.file==nil {continue}
        name:[2+32]u8
        copy(name[:],"w-")
        text:[64]u8
        copy(name[2:],writer_text(p.id.writer,&text))
        lease_buffer:[PATH_BYTES]u8
        if os.exists(join(&lease_buffer,s.root,"leases",string(name[:])) or_return) {continue}
        pack_seal_dead(w,i) or_return
    }
    return .None
}

@(private)
pack_seal_dead :: proc(w:^Sweep,index:int) -> Error {
    s:=w.s
    state:=s.state
    p:=&state.packs[index]
    buffer:[PATH_BYTES]u8
    path:=pack_path(s,"packs",p.id,&buffer) or_return
    file,error:=io_open(s,path,{.Read,.Write})
    if error==.Missing {
        p.gone=true
        return .None
    }
    if error!=.None {return error}
    size,size_error:=os.file_size(file)
    if size_error!=nil {
        os.close(file)
        return os_error(size_error)
    }
    frames:=make([dynamic]Own_Frame,0,0,context.temp_allocator)
    defer delete(frames)
    scan:Scan
    scan.frames=make([dynamic]Scanned,0,0,context.temp_allocator)
    scan.payloads=make([dynamic]u8,0,0,context.temp_allocator)
    defer {
        delete(scan.frames)
        delete(scan.payloads)
    }
    scanned:=pack_scan(file,size_of(Pack_Head),size,&scan,proc(data:rawptr,scan:^Scan,time:i64) -> Error {
        frames:=(^[dynamic]Own_Frame)(data)
        for f in scan.frames {
            frame:=Own_Frame{kind=f.head.kind,address=f.head.address}
            if f.head.kind==.Chunk {
                frame.location={offset=u64(head_data_at(f.at,f.head)),stored=f.head.stored,raw=f.head.raw,codec=f.head.codec,align=f.head.align,time=time}
            } else {
                frame.location={offset=u64(f.at),time=time}
            }
            if _,e:=append(frames,frame);e!=nil {return .Out_Of_Memory}
        }
        return .None
    },&frames)
    if scanned!=.None {
        os.close(file)
        return scanned
    }
    if scan.committed<=size_of(Pack_Head) {
        os.close(file)
        io_remove(s,path)
        p.gone=true
        return .None
    }
    sealed,seal_error:=pack_seal(s,file,frames[:],scan.committed,scan.last)
    if seal_error!=.None {
        os.close(file)
        return seal_error
    }
    p=&state.packs[index]
    if p.file!=nil {os.close(p.file)}
    p.file=file
    trailer_load_locked(s,index,sealed)
    return .None
}

// Marks what the roots reach, the blobs they name, and every chunk written or
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
    // Refs name roots and blobs; a blob's alias is kept while something names it or it is young.
    targets:=make([dynamic]Hash,0,0,context.temp_allocator)
    defer delete(targets)
    refs_each(s,&targets,proc(data:rawptr,namespace,name:string,v:Ref_Value) -> Error {
        if namespace=="" || v.address=={} {return .None}
        if _,e:=append((^[dynamic]Hash)(data),v.address);e!=nil {return .Out_Of_Memory}
        return .None
    }) or_return
    live_add(&w.live,targets[:]) or_return
    for target in w.live {walk_target(w,target) or_return}
    Aliases :: struct {w:^Sweep}
    aliases:=Aliases{w}
    refs_each(s,&aliases,proc(data:rawptr,namespace,name:string,v:Ref_Value) -> Error {
        w:=(^Aliases)(data).w
        if namespace!="" || v.address=={} {return .None}
        blob,ok:=parse_hex(name)
        if !ok {return .None}
        if blob in w.live || w.now-v.time<i64(GRACE) {return walk(w,v.address,-1,0)}
        return .None
    }) or_return
    for l,i in g.locations {
        if w.now-location_time(s,g.addresses[i],l)<i64(GRACE) {w.marks_generation[i]=true}
    }
    for k,i in state.table.keys {
        if k=={} {continue}
        if w.now-location_time(s,k,state.table.values[i])<i64(GRACE) {w.marks_table[i]=true}
    }
    return .None
}

@(private)
location_time :: proc(s:^Store,address:Hash,l:Location) -> i64 {
    if touched,ok:=s.state.touched[address];ok && touched>l.time {return touched}
    return l.time
}

// A root named by its blob's alias or by itself.
@(private)
walk_target :: proc(w:^Sweep,target:Hash) -> Error {
    text:[64]u8
    if v,found:=ref_resolve_locked(w.s,"",hex(target,&text));found {walk(w,v.address,-1,0) or_return}
    return walk(w,target,-1,0)
}

// Marks a chunk and, when it is a node of the level its parent says (any for
// a root), what it names.
@(private)
walk :: proc(w:^Sweep,address:Hash,level:int,depth:int) -> Error {
    if depth>NODE_LEVEL_MAX+1 || !mark(w,address) || level==0 {return .None}
    if w.buffers[depth]==nil {
        b,e:=make([]u8,CHUNK_MAX,w.s.state.allocator)
        if e!=nil {return .Out_Of_Memory}
        w.buffers[depth]=b
    }
    bytes,error:=chunk_bytes_locked(w.s,address,w.buffers[depth])
    if error==.Out_Of_Memory {return error}
    if error!=.None {return .None}
    n,parse_error:=node_parse(bytes)
    if parse_error!=.None || (level>0 && n.level!=level) {return .None}
    for e in n.entries {
        if n.level==0 {
            mark(w,e.address)
        } else {
            walk(w,e.address,n.level-1,depth+1) or_return
        }
    }
    return .None
}

// Marks the copy a lookup finds; false when it was marked or is not stored.
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

// The bytes of a stored chunk with the lock held, in buffer or mapped.
@(private)
chunk_bytes_locked :: proc(s:^Store,address:Hash,buffer:[]u8) -> ([]u8,Error) {
    pack,location,found:=lookup_locked(s,address)
    if !found {return nil,.Missing}
    return location_bytes_locked(s,pack,location,buffer)
}

@(private)
location_bytes_locked :: proc(s:^Store,pack:int,location:Location,buffer:[]u8) -> (bytes:[]u8,error:Error) {
    p:=&s.state.packs[pack]
    if p.file==nil {
        path_buffer:[PATH_BYTES]u8
        p.file=io_open(s,pack_path(s,"packs",p.id,&path_buffer) or_return) or_return
    }
    if p.sealed && p.view==nil {
        if mapped,e:=file_map(p.file,p.size);e==.None {p.view=mapped}
    }
    if p.view!=nil && i64(location.offset)+i64(location.stored)<=i64(len(p.view)) {
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
        w.compacted[i]=live[i]*2<total[i] || total[i]==0 || (small>=2 && total[i]<PACK_SMALL)
    }
    for l,i in g.locations {
        pack:=g.map_pack[l.pack]
        if !w.compacted[pack] || location_dead(s,pack,l) {continue}
        if _,e:=map_insert(&w.moved,g.addresses[i],Moved{pack,l});e!=nil {return .Out_Of_Memory}
        if !w.marks_generation[i] {
            w.result.chunks+=1
            continue
        }
        sweep_copy(w,g.addresses[i],pack,l) or_return
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
        sweep_copy(w,k,pack,l) or_return
    }
    return sweep_out_seal(w)
}

@(private)
pack_foldable :: proc(p:^Pack) -> bool {
    return p.sealed && !p.gone && !p.damaged
}

// Copies a live chunk into the sweep's pack, keeping its time.
@(private)
sweep_copy :: proc(w:^Sweep,address:Hash,pack:int,l:Location) -> Error {
    if address in w.copied {return .None}
    s:=w.s
    if _,e:=map_insert(&w.copied,address,struct{}{});e!=nil {return .Out_Of_Memory}
    buffer,e:=make([]u8,l.stored,context.temp_allocator)
    if e!=nil {return .Out_Of_Memory}
    defer delete(buffer,context.temp_allocator)
    bytes:=location_bytes_locked(s,pack,l,buffer) or_return
    return sweep_out_add(w,address,bytes,location_time(s,address,l))
}

@(private)
sweep_out_add :: proc(w:^Sweep,address:Hash,bytes:[]u8,time:i64) -> Error {
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
    stage_frame(out.stage,.Chunk,address,bytes,time) or_return
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
        l:=Location{offset=u64(head_data_at(at,f.head)),stored=f.head.stored,raw=f.head.raw,align=f.head.align,time=f.data_time}
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
// folded; aliases of blobs nothing names that are older than GRACE are
// dropped, and a removed ref is kept while a pack still being written could
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
        if !p.sealed && !p.gone && !p.damaged {oldest_active=min(oldest_active,p.created)}
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
            chunks[unique-1].location.time=max(chunks[unique-1].location.time,c.location.time)
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
        if namespace=="" && value.address!={} {
            blob,_:=parse_hex(name)
            if !(blob in w.live) && w.now-value.time>=i64(GRACE) {
                w.result.blobs+=1
                return .None
            }
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

// Folds the commits other writers made since the mark: a chunk one touched,
// or one a ref of theirs reaches, that is now only in a retired pack is
// copied back and a generation that holds it is published.
@(private)
sweep_recheck :: proc(w:^Sweep) -> Error {
    s:=w.s
    state:=s.state
    if len(w.moved)==0 {return .None}
    visited:=make(map[Hash]struct{},16,context.temp_allocator)
    defer delete(visited)
    recent:=make([]Recent,len(state.recent),context.temp_allocator)
    defer delete(recent,context.temp_allocator)
    copy(recent,state.recent[:])
    restored:=0
    for r in recent {
        switch r.kind {
        case .Touch: restored+=recheck_walk(w,r.address,0,0,&visited) or_return
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
    if _,_,found:=lookup_locked(s,address);found {
        if level==0 {return 0,.None}
        bytes=chunk_bytes_locked(s,address,w.buffers[depth]) or_return
    } else if moved,found:=w.moved[address];found {
        bytes=location_bytes_locked(s,moved.pack,moved.location,w.buffers[depth]) or_return
        if address_of_bytes(bytes)!=address {return 0,.None}
        sweep_out_add(w,address,bytes,max(moved.location.time,w.now)) or_return
        restored=1
        if level==0 {return restored,.None}
    } else {
        return 0,.None
    }
    n,parse_error:=node_parse(bytes)
    if parse_error!=.None || (level>0 && n.level!=level) {return restored,.None}
    children:=make([]Entry,len(n.entries),context.temp_allocator)
    defer delete(children,context.temp_allocator)
    copy(children,n.entries)
    for e in children {
        restored+=recheck_walk(w,e.address,max(n.level-1,0),depth+1,visited) or_return
    }
    return restored,.None
}

@(private)
retired_list :: proc(s:^Store) -> (entries:[]os.File_Info,error:Error) {
    buffer:[PATH_BYTES]u8
    return io_list(s,join(&buffer,s.root,"retired") or_return)
}

// Deletes what this sweep retired when no other writer runs, which could
// still be on its way to name it; else the next sweep does.
@(private)
retired_delete :: proc(w:^Sweep) -> Error {
    s:=w.s
    buffer:[PATH_BYTES]u8
    leases:=io_list(s,join(&buffer,s.root,"leases") or_return) or_return
    defer os.file_info_slice_delete(leases,s.state.allocator)
    own:[2+32]u8
    copy(own[:],"w-")
    text:[64]u8
    copy(own[2:],writer_text(s.state.writer.id,&text))
    for l in leases {
        if strings.has_prefix(l.name,"w-") && l.name!=string(own[:]) {return .None}
    }
    current:=retired_list(s) or_return
    defer os.file_info_slice_delete(current,s.state.allocator)
    retired_remove(w,current)
    return .None
}

@(private)
retired_remove :: proc(w:^Sweep,entries:[]os.File_Info) {
    for e in entries {
        if _,ok:=pack_name_parse(e.name);!ok {continue}
        if io_remove(w.s,e.fullpath)==.None {
            w.result.bytes+=e.size
        } else if os.exists(e.fullpath) {
            w.result.skipped+=1
        }
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

// Removes what was left in tmp/ by writes that stopped.
@(private)
tmp_prune :: proc(s:^Store,now:time.Time) -> Error {
    buffer:[PATH_BYTES]u8
    entries:=io_list(s,join(&buffer,s.root,"tmp") or_return) or_return
    defer os.file_info_slice_delete(entries,s.state.allocator)
    for entry in entries {
        if entry.name=="sweep" || entry.name=="partial" || entry.name=="blobs" || !older_than(entry.modification_time,now,TMP_STALE) {continue}
        base.remove_all(entry.fullpath)
    }
    return .None
}

// Claims tmp/sweep/owner for this process by creating it, which takes no
// data on a full volume; one whose holder ended, or of another machine and
// older than TMP_STALE, is taken over.
@(private)
sweep_own :: proc(s:^Store,now:time.Time) -> Error {
    buffer:[PATH_BYTES]u8
    owner:=join(&buffer,s.root,SWEEP_FOLDER,"owner") or_return
    holder:=holder_self()
    for attempt in 0..<2 {
        file,error:=io_create(s,owner)
        if error==.None {
            // Who holds it, when there is room to say.
            io_write_at(s,file,mem.ptr_to_bytes(&holder),0)
            os.close(file)
            return .None
        }
        if error!=.Invalid_Argument || attempt==1 {return .Io}
        held:Holder
        stale:=true
        if f,e:=file_open(owner);e==nil {
            info,stat_error:=os.fstat(f,context.temp_allocator)
            if read_exact(f,mem.ptr_to_bytes(&held),0)==.None {
                switch holder_state(held,holder) {
                case .Running: stale=false
                case .Ended:
                case .Unknown: stale=stat_error!=nil || older_than(info.modification_time,now,TMP_STALE)
                }
            } else {
                stale=stat_error!=nil || older_than(info.modification_time,now,TMP_STALE)
            }
            os.close(f)
        }
        if !stale {return .Io}
        file_remove(owner)
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
        case .Partial:
            hash,ok:=parse_hex(name)
            if !ok {continue}
            origin,origin_error=partial_folder(s,hash,&origin_buffer)
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
            if location_dead(s,spot.pack,spot.location) {continue}
            bytes,read_error:=location_bytes_locked(s,spot.pack,spot.location,buffer)
            if read_error==.Out_Of_Memory {return result,read_error}
            result.chunks+=1
            result.bytes+=i64(spot.location.stored)
            if read_error==.None && address_of_bytes(bytes)==spot.address {continue}
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
