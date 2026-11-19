package store

import "base:intrinsics"
import "core:hash/xxhash"
import "core:mem"
import "core:os"
import "core:strings"

// What a Store value knows of its root: the newest index generation, mapped,
// and for every pack it does not hold, the pack's chunks in one table and its
// ref frames folded, newest first. A lookup that misses reads the root again:
// new generations, new packs, and new commits of packs still being written.

// index/<generation>.idx: Idx_Head, [packs]Idx_Pack, fanout [65536]u32 by the
// first two bytes, sorted [chunks]Hash, [chunks]Location, [refs]Idx_Ref sorted
// by namespace and name, names, and the xxh3 of all before it.
@(private) IDX_MAGIC :: "MIRIDX03"
@(private) FANOUT :: 65536

@(private)
Idx_Head :: struct #packed {
    magic:[8]u8,
    number:u64,
    packs:u32,
    refs:u32,
    chunks:u64,
    names:u32,
    reserved:u32,
}

@(private)
Idx_Pack :: struct #packed {
    writer:[16]u8,
    seq:u32,
    reserved:u32,
    size:u64,
    created:i64,
}

// A ref folded into a generation; a removed one has a zero address and is
// kept while a pack that could hold an older frame of it is not folded.
@(private)
Idx_Ref :: struct #packed {
    namespace:u32, // offset in names of its length (u8) and bytes
    name:u32,
    address:Hash,
    time:i64,
}

#assert(size_of(Idx_Head)==40 && size_of(Idx_Pack)==40 && size_of(Idx_Ref)==48)

@(private)
Generation :: struct {
    number:u64,
    file:^os.File,
    view:[]u8,
    packs:[]Idx_Pack,
    fanout:[]u32,
    addresses:[]Hash,
    locations:[]Location,
    refs:[]Idx_Ref,
    names:[]u8,
    map_pack:[]int, // each of its packs in the store's
}

@(private)
Ref_Value :: struct {
    address:Hash,
    time:i64,
    pack:int,
    offset:i64,
}

@(private)
Tomb_Key :: struct {
    pack:int,
    offset:u64,
}

@(private)
Recent :: struct {
    kind:Frame_Kind,
    address:Hash,
}

// Open addressing by the address's first bytes; a zero address is empty.
@(private)
Table :: struct {
    keys:[]Hash,
    values:[]Location,
    count:int,
}

@(private)
table_make :: proc(t:^Table,capacity:int,allocator:=context.allocator) -> Error {
    keys,e:=make([]Hash,capacity,allocator)
    if e!=nil {return .Out_Of_Memory}
    values,f:=make([]Location,capacity,allocator)
    if f!=nil {
        delete(keys,allocator)
        return .Out_Of_Memory
    }
    t^={keys=keys,values=values}
    return .None
}

@(private)
table_destroy :: proc(t:^Table,allocator:=context.allocator) {
    delete(t.keys,allocator)
    delete(t.values,allocator)
    t^={}
}

@(private)
table_slot :: proc "contextless" (t:^Table,address:Hash) -> (slot:int,found:bool) {
    if len(t.keys)==0 {return -1,false}
    mask:=len(t.keys)-1
    key:=address
    i:=int(intrinsics.unaligned_load((^u64)(&key[0])))&mask
    for {
        k:=&t.keys[i]
        if k^==address {return i,true}
        if k^==({}) {return i,false}
        i=(i+1)&mask
    }
}

@(private)
table_put :: proc(t:^Table,address:Hash,location:Location,decodes:Codecs,allocator:=context.allocator) -> Error {
    if address=={} {return .None}
    if (t.count+1)*4>len(t.keys)*3 {
        bigger:Table
        table_make(&bigger,max(len(t.keys)*2,1024),allocator) or_return
        for k,i in t.keys {
            if k=={} {continue}
            slot,_:=table_slot(&bigger,k)
            bigger.keys[slot],bigger.values[slot]=k,t.values[i]
            bigger.count+=1
        }
        table_destroy(t,allocator)
        t^=bigger
    }
    slot,found:=table_slot(t,address)
    if found {
        // Of two copies the newer is kept, unless the other reads where it does not.
        time:=max(t.values[slot].time,location.time)
        if codec_rank(location.codec,decodes)>=codec_rank(t.values[slot].codec,decodes) {t.values[slot]=location}
        t.values[slot].time=time
        return .None
    }
    t.keys[slot],t.values[slot]=address,location
    t.count+=1
    return .None
}

@(private)
state_init :: proc(s:^Store) {
    state:=s.state
    state.packs=make([dynamic]Pack,0,0,s.state.allocator)
    state.pack_index=make(map[Pack_Id]int,s.state.allocator)
    state.refs=make(map[string]Ref_Value,s.state.allocator)
    state.tombs=make(map[Tomb_Key]struct{},s.state.allocator)
    state.touched=make(map[Hash]i64,s.state.allocator)
    state.stages=make([dynamic]^Stage,0,0,s.state.allocator)
    state.builders=make([dynamic]^Object_Writer,0,0,s.state.allocator)
    state.recent=make([dynamic]Recent,0,0,s.state.allocator)
    state.coders=make([dynamic]^Coder,0,0,s.state.allocator)
    codecs_init(s)
    w:=&state.writer
    w.deduped=make([dynamic]Deduped,0,0,s.state.allocator)
    w.named=make([dynamic]Hash,0,0,s.state.allocator)
    w.own=make([dynamic]Own_Frame,0,0,s.state.allocator)
}

@(private)
state_destroy :: proc(s:^Store) {
    state:=s.state
    generation_close(s,&state.generation)
    for &p in state.packs {pack_close(&p)}
    delete(state.packs)
    delete(state.pack_index)
    refs_clear(s)
    delete(state.refs)
    delete(state.tombs)
    delete(state.touched)
    table_destroy(&state.table,state.allocator)
    table_destroy(&state.retired,state.allocator)
    for st in state.stages {stage_free(s,st)}
    delete(state.stages)
    for b in state.builders {
        object_writer_destroy(b)
        free(b,state.allocator)
    }
    delete(state.builders)
    delete(state.recent)
    for c in state.coders {coder_free(s,c)}
    delete(state.coders)
    w:=&state.writer
    delete(w.deduped)
    delete(w.named)
    delete(w.own)
    free(state,state.allocator)
    s.state=nil
}

@(private)
pack_close :: proc(p:^Pack) {
    if p.view!=nil {file_unmap(p.view)}
    if p.file!=nil {os.close(p.file)}
    p.view,p.file=nil,nil
}

@(private)
refs_clear :: proc(s:^Store) {
    for key in s.state.refs {delete(key,s.state.allocator)}
    clear(&s.state.refs)
}

@(private)
pack_find :: proc(s:^Store,id:Pack_Id) -> int {
    return s.state.pack_index[id] or_else -1
}

@(private)
pack_add_locked :: proc(s:^Store,id:Pack_Id) -> (int,Error) {
    if i,found:=s.state.pack_index[id];found {return i,.None}
    if _,e:=append(&s.state.packs,Pack{id=id});e!=nil {return -1,.Out_Of_Memory}
    index:=len(s.state.packs)-1
    if _,e:=map_insert(&s.state.pack_index,id,index);e!=nil {
        pop(&s.state.packs)
        return -1,.Out_Of_Memory
    }
    return index,.None
}

// The number of the newest generation in index/; 0 when there is none.
@(private)
generation_newest :: proc(s:^Store) -> (newest:u64,error:Error) {
    buffer:[PATH_BYTES]u8
    entries:=io_list(s,join(&buffer,s.root,"index") or_return) or_return
    defer os.file_info_slice_delete(entries,s.state.allocator)
    for e in entries {
        if number,ok:=generation_name_parse(e.name);ok {newest=max(newest,number)}
    }
    return newest,.None
}

@(private) GENERATION_NAME :: 16+4

@(private)
generation_name :: proc(number:u64,buffer:^[GENERATION_NAME]u8) -> string {
    digits:="0123456789abcdef"
    for i in 0..<16 {buffer[i]=digits[(number>>(4*uint(15-i)))&15]}
    copy(buffer[16:],".idx")
    return string(buffer[:])
}

@(private)
generation_name_parse :: proc(name:string) -> (number:u64,ok:bool) {
    if len(name)!=GENERATION_NAME || name[16:]!=".idx" {return}
    for i in 0..<16 {
        d:=hex_digit(name[i]) or_return
        number=number<<4|u64(d)
    }
    return number,number>0
}

// Maps and checks a generation of any origin: every count against the file's
// size, the check, the fanout, the order of addresses and refs, and every
// location and name inside what the generation holds.
@(private)
generation_load :: proc(s:^Store,number:u64) -> (g:Generation,error:Error) {
    buffer:[PATH_BYTES]u8
    name:[GENERATION_NAME]u8
    path:=join(&buffer,s.root,"index",generation_name(number,&name)) or_return
    file:=io_open(s,path) or_return
    g.file,g.number=file,number
    defer if error!=.None {generation_close(s,&g)}
    size,size_error:=os.file_size(file)
    if size_error!=nil {return g,os_error(size_error)}
    fixed:=i64(size_of(Idx_Head)+FANOUT*4+8)
    if size<fixed || size>i64(max(int)) {return g,.Corrupt}
    g.view=file_map(file,size) or_return
    view:=g.view
    head:=intrinsics.unaligned_load((^Idx_Head)(raw_data(view)))
    if string(head.magic[:])!=IDX_MAGIC || head.number!=number || head.reserved!=0 {return g,.Corrupt}
    if u64(head.packs)>u64(size)/size_of(Idx_Pack) || head.chunks>u64(size)/(size_of(Hash)+size_of(Location)) ||
        u64(head.refs)>u64(size)/size_of(Idx_Ref) || i64(head.names)>size {
        return g,.Corrupt
    }
    total:=u64(fixed)+u64(head.packs)*size_of(Idx_Pack)+head.chunks*(size_of(Hash)+size_of(Location))+u64(head.refs)*size_of(Idx_Ref)+u64(head.names)
    if total!=u64(size) {return g,.Corrupt}
    stored:=intrinsics.unaligned_load((^u64)(raw_data(view[size-8:])))
    if xxhash.XXH3_64_default(view[:size-8])!=stored {return g,.Corrupt}
    at:=size_of(Idx_Head)
    g.packs=([^]Idx_Pack)(raw_data(view[at:]))[:head.packs]
    at+=int(head.packs)*size_of(Idx_Pack)
    g.fanout=([^]u32)(raw_data(view[at:]))[:FANOUT]
    at+=FANOUT*4
    g.addresses=([^]Hash)(raw_data(view[at:]))[:head.chunks]
    at+=int(head.chunks)*size_of(Hash)
    g.locations=([^]Location)(raw_data(view[at:]))[:head.chunks]
    at+=int(head.chunks)*size_of(Location)
    g.refs=([^]Idx_Ref)(raw_data(view[at:]))[:head.refs]
    at+=int(head.refs)*size_of(Idx_Ref)
    g.names=view[at:][:head.names]
    previous:u32
    for f,i in g.fanout {
        if f<previous {return g,.Corrupt}
        previous=f
        _=i
    }
    if u64(previous)!=head.chunks {return g,.Corrupt}
    for a,i in g.addresses {
        if i>0 && !hash_less(g.addresses[i-1],a) {return g,.Corrupt}
        bucket:=int(a[0])<<8|int(a[1])
        if u32(i)>=g.fanout[bucket] || (bucket>0 && u32(i)<g.fanout[bucket-1]) {return g,.Corrupt}
    }
    for p in g.packs {
        if p.reserved!=0 {return g,.Corrupt}
    }
    for l in g.locations {
        if !location_valid(l,u64(len(g.packs)),g.packs[l.pack].size if l.pack<u32(len(g.packs)) else 0) {return g,.Corrupt}
    }
    for r,i in g.refs {
        namespace,ok:=generation_string(&g,r.namespace)
        if !ok {return g,.Corrupt}
        name,name_ok:=generation_string(&g,r.name)
        if !name_ok || !(namespace=="" || name_valid(namespace)) || !name_valid(name) {return g,.Corrupt}
        if i>0 {
            pn,_:=generation_string(&g,g.refs[i-1].namespace)
            pm,_:=generation_string(&g,g.refs[i-1].name)
            if ref_compare(pn,pm,namespace,name)>=0 {return g,.Corrupt}
        }
    }
    map_pack,e:=make([]int,len(g.packs),s.state.allocator)
    if e!=nil {return g,.Out_Of_Memory}
    g.map_pack=map_pack
    return g,.None
}

@(private)
location_valid :: proc "contextless" (l:Location,packs:u64,pack_size:u64) -> bool {
    if u64(l.pack)>=packs || !sizes_valid(l.codec,l.stored,l.raw) {return false}
    if l.align!=ALIGN_SMALL && l.align!=ALIGN_LARGE {return false}
    return l.offset>=size_of(Pack_Head)+size_of(Frame_Head) && l.offset<=pack_size && u64(l.stored)<=pack_size-l.offset
}

@(private)
generation_string :: proc "contextless" (g:^Generation,offset:u32) -> (string,bool) {
    if u64(offset)>=u64(len(g.names)) {return "",false}
    n:=int(g.names[offset])
    if int(offset)+1+n>len(g.names) {return "",false}
    return string(g.names[int(offset)+1:][:n]),true
}

@(private)
ref_compare :: proc "contextless" (a_namespace,a_name,b_namespace,b_name:string) -> int {
    if c:=strings.compare(a_namespace,b_namespace);c!=0 {return c}
    return strings.compare(a_name,b_name)
}

@(private)
generation_close :: proc(s:^Store,g:^Generation) {
    if g.view!=nil {file_unmap(g.view)}
    if g.file!=nil {os.close(g.file)}
    delete(g.map_pack,s.state.allocator)
    g^={}
}

// The position of address in the generation.
@(private)
generation_find :: proc "contextless" (g:^Generation,address:Hash) -> (int,bool) {
    if len(g.addresses)==0 {return -1,false}
    bucket:=int(address[0])<<8|int(address[1])
    low:=0 if bucket==0 else int(g.fanout[bucket-1])
    high:=int(g.fanout[bucket])
    for low<high {
        mid:=(low+high)/2
        c:=hash_compare(g.addresses[mid],address)
        if c==0 {return mid,true}
        if c<0 {low=mid+1} else {high=mid}
    }
    return -1,false
}

@(private)
generation_ref :: proc "contextless" (g:^Generation,namespace,name:string) -> (Idx_Ref,bool) {
    low,high:=0,len(g.refs)
    for low<high {
        mid:=(low+high)/2
        ns,_:=generation_string(g,g.refs[mid].namespace)
        n,_:=generation_string(g,g.refs[mid].name)
        c:=ref_compare(ns,n,namespace,name)
        if c==0 {return g.refs[mid],true}
        if c<0 {low=mid+1} else {high=mid}
    }
    return {},false
}

// Reads the root again: a newer generation, packs not seen, and new commits
// of packs still being written by others.
@(private)
refresh_locked :: proc(s:^Store) -> Error {
    state:=s.state
    newest:=generation_newest(s) or_return
    number:=state.generation.number
    if newest>number {
        g:=generation_load(s,newest) or_return
        generation_close(s,&state.generation)
        state.generation=g
        for &p in state.packs {p.indexed=false}
        for gp,i in g.packs {
            index:=pack_add_locked(s,{writer=gp.writer,seq=gp.seq}) or_return
            p:=&state.packs[index]
            p.indexed,p.sealed,p.size,p.created=true,true,i64(gp.size),gp.created
            p.gone=false
            state.generation.map_pack[i]=index
        }
        state_rebuild_locked(s)
        writer_ack_locked(s)
    }
    packs_read_locked(s) or_return
    // Outside a sweep, a pack that is gone is read again only by its path, from retired/.
    if newest>number && !state.recording {
        for &p in state.packs {
            if p.gone && !p.lent && !p.own {pack_close(&p)}
        }
    }
    return .None
}

// Reads the packs folder: loads each pack not seen and the new commits of
// those still being written by others.
@(private)
packs_read_locked :: proc(s:^Store) -> Error {
    state:=s.state
    buffer:[PATH_BYTES]u8
    entries:=io_list(s,join(&buffer,s.root,"packs") or_return) or_return
    defer os.file_info_slice_delete(entries,s.state.allocator)
    listed:=make([]bool,len(state.packs)+len(entries),context.temp_allocator)
    defer delete(listed,context.temp_allocator)
    for e in entries {
        id,ok:=pack_name_parse(e.name)
        if !ok {continue}
        index:=pack_add_locked(s,id) or_return
        if index<len(listed) {listed[index]=true}
        p:=&state.packs[index]
        if p.indexed || p.own || p.damaged || p.retired>0 || (p.sealed && p.file!=nil) {continue}
        if !p.sealed && p.file!=nil && e.size<=p.size {continue}
        pack_load_locked(s,index) or_return
    }
    // A pack a sweep retired is no longer read, though this value may hold it open.
    w:=&state.writer
    for &p,i in state.packs {
        if i<len(listed) && !listed[i] && !p.indexed && p.retired==0 && !(w.open && i==w.pack) {p.gone=true}
    }
    return .None
}

// Reads what a pack the generation does not hold adds: a sealed pack's
// trailer, or the frames of the commits after what was read. A pack of any
// origin that does not read is damaged and skipped.
@(private)
pack_load_locked :: proc(s:^Store,index:int) -> Error {
    state:=s.state
    p:=&state.packs[index]
    if p.file==nil {
        buffer:[PATH_BYTES]u8
        file,error:=io_open(s,pack_file_path(s,p,&buffer) or_return)
        if error==.Missing {
            if p.retired==0 {p.gone=true}
            return .None
        }
        if error!=.None {return error}
        // A pack its writer has made but not yet given its head is read again on the next miss.
        if size,size_error:=os.file_size(file);size_error!=nil || size<size_of(Pack_Head) {
            os.close(file)
            return .None
        }
        p.file=file
        head:Pack_Head
        if read_exact(file,mem.ptr_to_bytes(&head),0)!=.None || string(head.magic[:])!=PACK_MAGIC || head.writer!=p.id.writer {
            p.damaged=true
            return .None
        }
        p.created,p.size=head.created,size_of(Pack_Head)
    }
    size,size_error:=os.file_size(p.file)
    if size_error!=nil {return os_error(size_error)}
    if trailer_load_locked(s,index,size) {return .None}
    p=&state.packs[index]
    if p.damaged {return .None}
    Apply :: struct {s:^Store,pack:int}
    apply:=Apply{s,index}
    scan:Scan
    scan.frames=make([dynamic]Scanned,0,0,context.temp_allocator)
    scan.payloads=make([dynamic]u8,0,0,context.temp_allocator)
    defer {
        delete(scan.frames)
        delete(scan.payloads)
    }
    pack_scan(p.file,p.size,size,&scan,proc(data:rawptr,scan:^Scan,time:i64) -> Error {
        a:=(^Apply)(data)
        state:=a.s.state
        retired:=state.packs[a.pack].retired>0
        for f in scan.frames {
            if retired {
                if f.head.kind!=.Chunk {continue}
                l:=Location{pack=u32(a.pack),offset=u64(head_data_at(f.at,f.head)),stored=f.head.stored,raw=f.head.raw,codec=f.head.codec,align=f.head.align,time=time}
                table_put(&state.retired,f.head.address,l,state.decodes,state.allocator) or_return
                continue
            }
            payload:=scan.payloads[f.payload[0]:f.payload[1]]
            frame_apply(a.s,a.pack,f.head,f.at,payload,time) or_return
        }
        return .None
    },&apply) or_return
    p=&state.packs[index]
    if scan.committed>p.size {p.size,p.last=scan.committed,scan.last}
    return .None
}

// Loads a pack's trailer when its footer checks; false for a pack without one.
@(private)
trailer_load_locked :: proc(s:^Store,index:int,size:i64) -> bool {
    state:=s.state
    p:=&state.packs[index]
    if size<size_of(Pack_Head)+size_of(Footer) {return false}
    footer:Footer
    if read_exact(p.file,mem.ptr_to_bytes(&footer),size-size_of(Footer))!=.None || string(footer.magic[:])!=SEAL_MAGIC {return false}
    trailer:=i64(footer.trailer)
    if footer.trailer>u64(size) || trailer!=align_up(i64(min(footer.frames_end,u64(size))),8) || footer.frames_end<size_of(Pack_Head) {return false}
    body:=u64(size)-size_of(Footer)-footer.trailer
    if u64(footer.chunks)>body/(size_of(Hash)+size_of(Location)) || u64(footer.extras)>body/size_of(Extra) {return false}
    if u64(footer.chunks)*(size_of(Hash)+size_of(Location))+256*4+u64(footer.extras)*size_of(Extra)!=body {return false}
    view:=p.view
    if view==nil {
        error:Error
        view,error=file_map(p.file,size)
        if error!=.None {return false}
    }
    mapped:=p.view==nil
    if i64(len(view))<size {return false}
    trailer_bytes:=view[trailer:size-size_of(Footer)]
    if footer_check(trailer_bytes,&footer)!=footer.check {
        if mapped {file_unmap(view)}
        return false
    }
    chunks:=int(footer.chunks)
    addresses:=([^]Hash)(raw_data(trailer_bytes))[:chunks]
    locations:=([^]Location)(raw_data(trailer_bytes[chunks*size_of(Hash):]))[:chunks]
    fanout:=([^]u32)(raw_data(trailer_bytes[chunks*(size_of(Hash)+size_of(Location)):]))[:256]
    extras:=([^]Extra)(raw_data(trailer_bytes[chunks*(size_of(Hash)+size_of(Location))+256*4:]))[:footer.extras]
    valid:=fanout[255]==footer.chunks
    for b in 1..<256 {valid&&=fanout[b]>=fanout[b-1]}
    for a,i in addresses {
        if !valid {break}
        valid=(i==0 || hash_less(addresses[i-1],a)) && u32(i)<fanout[a[0]]
        l:=locations[i]
        valid&&=l.pack==0 && location_valid(l,1,footer.frames_end)
    }
    for x in extras {
        if !valid {break}
        valid=footer.frames_end>=size_of(Pack_Head)+size_of(Frame_Head) && x.offset>=size_of(Pack_Head) && x.offset<=footer.frames_end-size_of(Frame_Head)
    }
    if !valid {
        if mapped {file_unmap(view)}
        p.damaged=true
        return true
    }
    p.view,p.sealed,p.size,p.last=view,true,size,footer.last
    if p.indexed {return true}
    table:=&state.retired if p.retired>0 else &state.table
    for a,i in addresses {
        l:=locations[i]
        l.pack=u32(index)
        if table_put(table,a,l,state.decodes,state.allocator)!=.None {return true}
    }
    if p.retired>0 {return true}
    for x in extras {
        head:=intrinsics.unaligned_load((^Frame_Head)(raw_data(view[x.offset:])))
        if !head_valid(&head) || head.kind==.Chunk || head.kind==.Commit || u64(head_end(i64(x.offset),head))>footer.frames_end {continue}
        payload:=view[x.offset+size_of(Frame_Head):][:head.stored]
        frame_apply(s,index,head,i64(x.offset),payload,x.time)
    }
    return true
}

// Adds what a committed frame says to the state.
@(private)
frame_apply :: proc(s:^Store,pack:int,head:Frame_Head,at:i64,payload:[]u8,time:i64) -> Error {
    state:=s.state
    switch head.kind {
    case .Chunk:
        l:=Location{pack=u32(pack),offset=u64(head_data_at(at,head)),stored=head.stored,raw=head.raw,codec=head.codec,align=head.align,time=time}
        return table_put(&state.table,head.address,l,state.decodes,state.allocator)
    case .Touch:
        if old,found:=state.touched[head.address];found && old>=time {return .None}
        if _,e:=map_insert(&state.touched,head.address,time);e!=nil {return .Out_Of_Memory}
        recent_add(s,.Touch,head.address) or_return
    case .Ref:
        namespace,name,ref_time,ok:=ref_payload(payload)
        if !ok {return .None}
        ref_fold(s,namespace,name,{address=head.address,time=ref_time,pack=pack,offset=at}) or_return
        recent_add(s,.Ref,head.address) or_return
    case .Tombstone:
        if len(payload)!=size_of(Tomb_Payload) {return .None}
        t:=intrinsics.unaligned_load((^Tomb_Payload)(raw_data(payload)))
        index:=pack_add_locked(s,{writer=t.writer,seq=t.seq}) or_return
        if _,e:=map_insert(&state.tombs,Tomb_Key{index,t.offset},struct{}{});e!=nil {return .Out_Of_Memory}
    case .Pad,.Commit:
    }
    return .None
}

@(private)
recent_add :: proc(s:^Store,kind:Frame_Kind,address:Hash) -> Error {
    if !s.state.recording {return .None}
    if _,e:=append(&s.state.recent,Recent{kind,address});e!=nil {return .Out_Of_Memory}
    return .None
}

@(private)
ref_payload :: proc(payload:[]u8) -> (namespace,name:string,time:i64,ok:bool) {
    if len(payload)<REF_FIXED {return}
    time=intrinsics.unaligned_load((^i64)(raw_data(payload)))
    a,b:=int(payload[8]),int(payload[9])
    if REF_FIXED+a+b!=len(payload) {return}
    namespace=string(payload[REF_FIXED:][:a])
    name=string(payload[REF_FIXED+a:][:b])
    if !(namespace=="" || name_valid(namespace)) || !name_valid(name) {return}
    return namespace,name,time,true
}

// Keeps the newer of what the fold holds for a name and v.
@(private)
ref_fold :: proc(s:^Store,namespace,name:string,v:Ref_Value) -> Error {
    key_buffer:[2*NAME_MAX+1]u8
    key:=ref_key(namespace,name,&key_buffer)
    if old,found:=s.state.refs[key];found {
        if !ref_newer(v,old) {return .None}
        s.state.refs[key]=v
        return .None
    }
    cloned,e:=strings.clone(key,s.state.allocator)
    if e!=nil {return .Out_Of_Memory}
    if _,f:=map_insert(&s.state.refs,cloned,v);f!=nil {
        delete(cloned,s.state.allocator)
        return .Out_Of_Memory
    }
    return .None
}

@(private)
ref_newer :: proc "contextless" (a,b:Ref_Value) -> bool {
    if a.time!=b.time {return a.time>b.time}
    if a.pack!=b.pack {return a.pack>b.pack}
    return a.offset>b.offset
}

@(private)
ref_key :: proc(namespace,name:string,buffer:^[2*NAME_MAX+1]u8) -> string {
    n:=copy(buffer[:],namespace)
    buffer[n]='/'
    n+=1
    n+=copy(buffer[n:],name)
    return string(buffer[:n])
}

// The newest value of a ref, from the fold or the generation; found is false
// for one never set or removed.
@(private)
ref_resolve_locked :: proc(s:^Store,namespace,name:string) -> (v:Ref_Value,found:bool) {
    state:=s.state
    key_buffer:[2*NAME_MAX+1]u8
    folded,in_fold:=state.refs[ref_key(namespace,name,&key_buffer)]
    indexed,in_generation:=generation_ref(&state.generation,namespace,name)
    switch {
    case in_fold && in_generation:
        v=folded
        if indexed.time>folded.time {v={address=indexed.address,time=indexed.time,pack=-1}}
    case in_fold: v=folded
    case in_generation: v={address=indexed.address,time=indexed.time,pack=-1}
    case: return {},false
    }
    return v,v.address!={}
}

// Rebuilds what the packs outside the generation add, from their files and,
// for this value's open pack, from what its writer wrote.
@(private)
state_rebuild_locked :: proc(s:^Store) {
    state:=s.state
    table_destroy(&state.table,state.allocator)
    refs_clear(s)
    clear(&state.tombs)
    clear(&state.touched)
    w:=&state.writer
    for &p,i in state.packs {
        if p.indexed || p.gone || p.damaged || p.retired>0 {continue}
        if p.own && w.open && i==w.pack {
            for f in w.own {
                at:=i64(f.location.offset)
                switch f.kind {
                case .Chunk:
                    l:=f.location
                    l.pack=u32(i)
                    table_put(&state.table,f.address,l,state.decodes,state.allocator)
                case .Ref,.Touch,.Tombstone:
                    head:Frame_Head
                    payload:[REF_FIXED+2*NAME_MAX]u8
                    if read_exact(w.file,mem.ptr_to_bytes(&head),at)!=.None || !head_valid(&head) {continue}
                    if read_exact(w.file,payload[:head.stored],at+size_of(Frame_Head))!=.None {continue}
                    frame_apply(s,i,head,at,payload[:head.stored],f.location.time)
                case .Pad,.Commit:
                }
            }
            continue
        }
        // A sealed pack keeps its mapping: slices of it may be held.
        if p.sealed && p.view!=nil {
            trailer_load_locked(s,i,p.size)
            continue
        }
        p.sealed=false
        if p.file!=nil {p.size=size_of(Pack_Head)}
        pack_load_locked(s,i)
    }
}

// Where the chunk at address is, without reading the root again; a copy a
// tombstone names, in a pack that is gone or of a codec this value does not
// decode is not found unless readable is false: a chunk is in the store, for
// what refs, leases and sweeps keep, in a frame of any codec.
@(private)
lookup_locked :: proc(s:^Store,address:Hash,readable:=true) -> (pack:int,location:Location,found:bool) {
    state:=s.state
    if slot,in_table:=table_slot(&state.table,address);in_table {
        location=state.table.values[slot]
        pack=int(location.pack)
        found=!location_dead(s,pack,location) && (!readable || codec_readable(s,location.codec))
    }
    if !found {
        if i,in_generation:=generation_find(&state.generation,address);in_generation {
            location=state.generation.locations[i]
            pack=state.generation.map_pack[location.pack]
            found=!location_dead(s,pack,location) && (!readable || codec_readable(s,location.codec))
        }
    }
    if !found {return -1,{},false}
    if touched,ok:=state.touched[address];ok && touched>location.time {location.time=touched}
    return pack,location,true
}

@(private)
location_dead :: proc(s:^Store,pack:int,location:Location) -> bool {
    if pack<0 || pack>=len(s.state.packs) || s.state.packs[pack].gone || s.state.packs[pack].damaged {return true}
    return Tomb_Key{pack,location.offset} in s.state.tombs
}

// lookup_locked, reading the root again once when it misses.
@(private)
find_locked :: proc(s:^Store,address:Hash,readable:=true) -> (pack:int,location:Location,found:bool) {
    pack,location,found=lookup_locked(s,address,readable)
    if found {return}
    if refresh_locked(s)!=.None {return}
    pack,location,found=lookup_locked(s,address,readable)
    if found {return}
    // A chunk a sweep retired that a commit still names is read where it went.
    if retired_load_locked(s)!=.None {return}
    pack,location,found=retired_lookup_locked(s,address)
    if found && readable && !codec_readable(s,location.codec) {return -1,{},false}
    return
}

// Where a chunk is in a pack a sweep retired.
@(private)
retired_lookup_locked :: proc(s:^Store,address:Hash,readable:=true) -> (pack:int,location:Location,found:bool) {
    state:=s.state
    slot,in_table:=table_slot(&state.retired,address)
    if !in_table {return -1,{},false}
    location=state.retired.values[slot]
    pack=int(location.pack)
    if pack>=len(state.packs) || state.packs[pack].damaged || state.packs[pack].pruned {return -1,{},false}
    return pack,location,true
}

// Loads the packs of retired/ not loaded yet: retired/<generation>-<pack>,
// the generation that dropped them.
@(private)
retired_load_locked :: proc(s:^Store) -> Error {
    state:=s.state
    buffer:[PATH_BYTES]u8
    entries:=io_list(s,join(&buffer,s.root,"retired") or_return) or_return
    defer os.file_info_slice_delete(entries,state.allocator)
    for e in entries {
        generation,id,ok:=retired_name_parse(e.name)
        if !ok {continue}
        index:=pack_add_locked(s,id) or_return
        p:=&state.packs[index]
        if p.retired==generation && p.file!=nil && (p.sealed || e.size<=p.size) {continue}
        if p.retired!=generation {
            // This value read it in packs/: its open file is the same one.
            p.retired=generation
            p.gone,p.indexed=true,false
            if p.view==nil {p.sealed=false}
            if p.file!=nil && !p.sealed {p.size=size_of(Pack_Head)}
        }
        pack_load_locked(s,index) or_return
    }
    return .None
}

@(private) RETIRED_NAME :: 17+PACK_NAME

@(private)
retired_name :: proc(generation:u64,id:Pack_Id,buffer:^[RETIRED_NAME]u8) -> string {
    digits:="0123456789abcdef"
    for i in 0..<16 {buffer[i]=digits[(generation>>(4*uint(15-i)))&15]}
    buffer[16]='-'
    name:[PACK_NAME]u8
    copy(buffer[17:],pack_name(id,&name))
    return string(buffer[:])
}

@(private)
retired_name_parse :: proc(name:string) -> (generation:u64,id:Pack_Id,ok:bool) {
    if len(name)!=RETIRED_NAME || name[16]!='-' {return}
    for i in 0..<16 {
        d:=hex_digit(name[i]) or_return
        generation=generation<<4|u64(d)
    }
    id=pack_name_parse(name[17:]) or_return
    return generation,id,generation>0
}

// The file of a pack: in packs/, or in retired/ under the generation that dropped it.
@(private)
pack_file_path :: proc(s:^Store,p:^Pack,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    if p.retired==0 {return pack_path(s,"packs",p.id,buffer)}
    name:[RETIRED_NAME]u8
    return join(buffer,s.root,"retired",retired_name(p.retired,p.id,&name))
}
