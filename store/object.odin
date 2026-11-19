package store

import "base:runtime"
import "core:os"
import "core:sync"
import "core:time"
import "mirai:std/jobs"

// Puts cut bytes into chunks, look each one up and append only the missing
// ones to this value's pack, gathered into one write per stage. A chunk found
// already stored is named without writing; when its copy is older than a
// quarter of GRACE a Touch frame refreshes it, so a sweep keeps it. Nothing is
// visible to other values until commit.

// An object being put; put_finish ends it. With a worker of a job system,
// the bytes are cut on the caller's thread, in order, and each chunk is hashed,
// looked up and appended by a job; the leaves join the tree in the order of the
// cuts, so the object is the same as one put on one thread.
Put :: struct {
    s:^Store,
    builder:^Object_Writer,
    stage:^Stage,
    now:i64,
    worker:jobs.Worker_Ref,
    batches:^Put_Batches,
}

// Two runs of cut chunks: one the jobs work on while the caller cuts the other.
@(private)
Put_Batches :: struct {
    bytes:[2][]u8,
    chunks:[2][dynamic]Put_Chunk,
    used:[2]int,
    turn:int,
    counter:jobs.Counter,
    pending:bool, // the jobs of the other run are queued
}

@(private)
Put_Chunk :: struct {
    s:^Store,
    now:i64,
    bytes:[]u8,
    address:Hash,
    error:Error,
}

@(private) PUT_RUN :: 16*CHUNK_MAX // bytes of a run of chunks

// Puts bytes as an object of one group, without committing.
put :: proc(s:^Store,data:[]u8,now:Maybe(time.Time)=nil,worker:=jobs.Worker_Ref{}) -> (address:Hash,error:Error) {
    if s==nil || s.state==nil {return {},.Invalid_Argument}
    at:=(now.? or_else time.now())._nsec
    if len(data)<=CHUNK_MAX && chunk_cut(data)==len(data) {
        // One chunk and a root of one entry, as the builder makes them.
        st:=stage_take(s) or_return
        defer stage_give(s,st)
        p:=Put{s=s,stage=st,now=at}
        entries:[1]Entry
        count:=0
        if len(data)>0 {
            entries[0]={address=address_of_bytes(data),size=u64(len(data))}
            count=1
            put_chunk(&p,entries[0].address,data) or_return
        }
        groups:=[1]Group{{count=u32(count)}}
        buffer:[size_of(Node)+size_of(Entry)+size_of(Group)]u8
        node:=node_encode(buffer[:],0,entries[:count],groups[:]) or_return
        address=address_of_bytes(node)
        put_chunk(&p,address,node) or_return
        stage_write(s,st,at) or_return
        batch_check(s,at) or_return
        return address,.None
    }
    p:=put_begin(s,now,worker) or_return
    if e:=put_write(&p,data);e!=.None {
        put_abandon(&p)
        return {},e
    }
    address,_,error=put_finish(&p)
    return
}

put_begin :: proc(s:^Store,now:Maybe(time.Time)=nil,worker:=jobs.Worker_Ref{}) -> (p:Put,error:Error) {
    if s==nil || s.state==nil {return {},.Invalid_Argument}
    p.s=s
    p.now=(now.? or_else time.now())._nsec
    p.worker=worker
    p.stage=stage_take(s) or_return
    sync.mutex_lock(&s.state.lock)
    if n:=len(s.state.builders);n>0 {p.builder=pop(&s.state.builders)}
    sync.mutex_unlock(&s.state.lock)
    if p.builder==nil {
        b,e:=new(Object_Writer,s.state.allocator)
        if e!=nil {
            stage_give(s,p.stage)
            return {},.Out_Of_Memory
        }
        if object_writer_init(b,{},s.state.allocator)!=.None {
            free(b,s.state.allocator)
            stage_give(s,p.stage)
            return {},.Out_Of_Memory
        }
        p.builder=b
    }
    return p,.None
}

// Gives the next bytes of the object.
put_write :: proc(p:^Put,data:[]u8) -> Error {
    p.builder.tree.sink={procedure=put_sink,data=p}
    if p.worker.system==nil {return object_write(p.builder,data)}
    b:=p.builder
    if !b.started {
        tree_group(&b.tree,0,0) or_return
        b.started=true
    }
    chunker_feed(&b.chunker,data) or_return
    for chunk in chunker_next(&b.chunker) {put_run_add(p,chunk) or_return}
    return .None
}

// Copies a cut chunk into the run being filled, handing the run to jobs when full.
@(private)
put_run_add :: proc(p:^Put,chunk:[]u8) -> Error {
    if p.batches==nil {
        b,e:=new(Put_Batches,p.s.state.allocator)
        if e!=nil {return .Out_Of_Memory}
        p.batches=b
        for k in 0..<2 {
            bytes,f:=make([]u8,PUT_RUN,p.s.state.allocator)
            if f!=nil {return .Out_Of_Memory}
            b.bytes[k]=bytes
            b.chunks[k]=make([dynamic]Put_Chunk,0,0,p.s.state.allocator)
        }
    }
    b:=p.batches
    if b.used[b.turn]+len(chunk)>PUT_RUN {put_run_dispatch(p) or_return}
    at:=b.used[b.turn]
    copy(b.bytes[b.turn][at:],chunk)
    b.used[b.turn]+=len(chunk)
    if _,e:=append(&b.chunks[b.turn],Put_Chunk{s=p.s,now=p.now,bytes=b.bytes[b.turn][at:][:len(chunk)]});e!=nil {return .Out_Of_Memory}
    return .None
}

// Waits for the jobs of the other run and adds its leaves in order, then
// queues the jobs of this one and turns to the other.
@(private)
put_run_dispatch :: proc(p:^Put) -> Error {
    b:=p.batches
    put_run_settle(p) or_return
    js:=p.worker.system
    for &c in b.chunks[b.turn] {jobs.run(js,p.worker.worker,.Frame,put_chunk_job,&c,&b.counter)}
    b.pending=len(b.chunks[b.turn])>0
    b.turn=1-b.turn
    b.used[b.turn]=0
    clear(&b.chunks[b.turn])
    return .None
}

// Waits for the queued run and adds its leaves to the tree in the order of the cuts.
@(private)
put_run_settle :: proc(p:^Put) -> Error {
    b:=p.batches
    if b==nil || !b.pending {return .None}
    jobs.wait(p.worker.system,p.worker.worker,&b.counter)
    b.pending=false
    other:=1-b.turn
    for c in b.chunks[other] {
        c.error or_return
        tree_put_leaf(&p.builder.tree,c.address,u64(len(c.bytes))) or_return
    }
    return .None
}

@(private)
put_chunk_job :: proc(c:^Put_Chunk,worker:int) {
    c.address=address_of_bytes(c.bytes)
    st,error:=stage_take(c.s)
    if error!=.None {
        c.error=error
        return
    }
    defer stage_give(c.s,st)
    p:=Put{s=c.s,stage=st,now=c.now}
    if c.error=put_chunk(&p,c.address,c.bytes);c.error!=.None {return}
    c.error=stage_write(c.s,st,c.now)
}

// Gives a container chunk of a native asset as the next group, cut where its
// writer says.
put_native :: proc(p:^Put,tag,index:u32,align:u8,data:[]u8,cuts:[]int) -> Error {
    p.builder.tree.sink={procedure=put_sink,data=p}
    p.builder.started=true
    return tree_put_native(&p.builder.tree,tag,index,align,data,cuts)
}

// Ends the object: its root's address and the bytes under it.
put_finish :: proc(p:^Put,meta:[]u8={}) -> (address:Hash,total:u64,error:Error) {
    defer put_abandon(p)
    p.builder.tree.sink={procedure=put_sink,data=p}
    if p.worker.system!=nil && p.builder.started {
        b:=p.builder
        chunker_end(&b.chunker)
        for chunk in chunker_next(&b.chunker) {put_run_add(p,chunk) or_return}
        if p.batches!=nil {
            put_run_dispatch(p) or_return
            put_run_settle(p) or_return
        }
    }
    address,total=object_finish(p.builder,meta) or_return
    stage_write(p.s,p.stage,p.now) or_return
    batch_check(p.s,p.now) or_return
    return
}

// Gives back what a put holds; what it already wrote stays for the batch.
put_abandon :: proc(p:^Put) {
    if p.s==nil {return}
    s:=p.s
    if b:=p.batches;b!=nil {
        if b.pending {jobs.wait(p.worker.system,p.worker.worker,&b.counter)}
        for k in 0..<2 {
            delete(b.bytes[k],s.state.allocator)
            delete(b.chunks[k])
        }
        free(b,s.state.allocator)
    }
    if p.builder!=nil {
        object_writer_reset(p.builder)
        sync.mutex_lock(&s.state.lock)
        _,e:=append(&s.state.builders,p.builder)
        sync.mutex_unlock(&s.state.lock)
        if e!=nil {
            object_writer_destroy(p.builder)
            free(p.builder,s.state.allocator)
        }
    }
    stage_give(s,p.stage)
    p^={}
}

@(private)
put_sink :: proc(data:rawptr,kind:Chunk_Kind,address:Hash,bytes:[]u8) -> Error {
    return put_chunk((^Put)(data),address,bytes)
}

@(private)
put_chunk :: proc(p:^Put,address:Hash,bytes:[]u8) -> Error {
    for f in p.stage.frames {
        if f.head.kind==.Chunk && f.head.address==address {return .None}
    }
    s:=p.s
    state:=s.state
    sync.mutex_lock(&state.lock)
    w:=&state.writer
    if w.frames==0 && len(w.deduped)==0 {w.generation=state.generation.number}
    pack,location,found:=lookup_locked(s,address)
    touch:=false
    if found {
        touch=p.now-location.time>i64(GRACE/4)
        if _,e:=append(&w.deduped,Deduped{address=address,pack=state.packs[pack].id,location=location});e!=nil {
            sync.mutex_unlock(&state.lock)
            return .Out_Of_Memory
        }
    }
    sync.mutex_unlock(&state.lock)
    if found {
        if touch {return stage_frame(p.stage,.Touch,address,nil)}
        return .None
    }
    stage_frame(p.stage,.Chunk,address,bytes) or_return
    if len(p.stage.bytes)>=STAGE_BYTES {
        stage_write(s,p.stage,p.now) or_return
        stage_reset(p.stage)
    }
    return .None
}

// Commits a batch that grew past BATCH_MAX.
@(private)
batch_check :: proc(s:^Store,now:i64) -> Error {
    state:=s.state
    sync.mutex_lock(&state.lock)
    defer sync.mutex_unlock(&state.lock)
    if state.writer.pending<BATCH_MAX {return .None}
    return commit_locked(s,now)
}

// Whether the chunk at address is stored.
chunk_has :: proc(s:^Store,address:Hash) -> bool {
    if s==nil || s.state==nil {return false}
    sync.mutex_lock(&s.state.lock)
    defer sync.mutex_unlock(&s.state.lock)
    // Another value may have tombstoned it, or a sweep dropped it: the root is read again first.
    if refresh_locked(s)!=.None {return false}
    _,_,found:=lookup_locked(s,address)
    return found
}

// The bytes of the chunk at address: a slice of its mapped pack once the pack
// is sealed, otherwise read into buffer, which holds at least CHUNK_MAX bytes
// or the chunk's size. Nothing is checked against the address: a scrub and a
// receiver's report find damage.
chunk_read :: proc(s:^Store,address:Hash,buffer:[]u8) -> (bytes:[]u8,error:Error) {
    if s==nil || s.state==nil {return nil,.Invalid_Argument}
    file,view,location:=chunk_locate(s,address) or_return
    if view!=nil {return view[location.offset:][:location.stored],.None}
    if len(buffer)<int(location.stored) {return nil,.Invalid_Argument}
    bytes=buffer[:location.stored]
    if e:=read_exact(file,bytes,i64(location.offset));e!=.None {return nil,e}
    return bytes,.None
}

// The file or mapping that holds a chunk; a sealed pack is mapped the first
// time it is read.
@(private)
chunk_locate :: proc(s:^Store,address:Hash) -> (file:^os.File,view:[]u8,location:Location,error:Error) {
    state:=s.state
    sync.mutex_lock(&state.lock)
    defer sync.mutex_unlock(&state.lock)
    for attempt in 0..<2 {
        pack,found_location,found:=find_locked(s,address)
        location=found_location
        if !found {return nil,nil,{},.Missing}
        p:=&state.packs[pack]
        if p.file==nil {
            buffer:[PATH_BYTES]u8
            path:=pack_file_path(s,p,&buffer) or_return
            opened,open_error:=io_open(s,path)
            if open_error==.Missing && attempt==0 {
                // Retired by a sweep since this value read the generation.
                if p.retired==0 {p.gone=true}
                refresh_locked(s) or_return
                continue
            }
            if open_error!=.None {return nil,nil,{},open_error}
            p.file=opened
        }
        // Nothing is read beyond the file's size now: a pack cut below a chunk is damaged.
        end:=i64(location.offset)+i64(location.stored)
        size,size_error:=os.file_size(p.file)
        if size_error!=nil {return nil,nil,{},os_error(size_error)}
        if end>size {
            p.damaged=true
            return nil,nil,{},.Corrupt
        }
        if p.sealed && p.view==nil && size>=p.size {
            if mapped,map_error:=file_map(p.file,p.size);map_error==.None {p.view=mapped}
        }
        if p.view!=nil && end<=i64(len(p.view)) {return p.file,p.view,location,.None}
        return p.file,nil,location,.None
    }
    return nil,nil,{},.Missing
}

// An object held open to read its bytes, by its root.
Object :: struct {
    s:^Store,
    address:Hash,
    root:Node_View, // into root_bytes
    root_bytes:[]u8,
    nodes:[2][]u8,
    chunk:[]u8,
    turn:int,
}

object_open :: proc(s:^Store,address:Hash) -> (o:Object,error:Error) {
    if s==nil || s.state==nil {return {},.Invalid_Argument}
    o.s,o.address=s,address
    defer if error!=.None {object_close(&o)}
    for &b in o.nodes {
        e:runtime.Allocator_Error
        b,e=make([]u8,CHUNK_MAX,s.state.allocator)
        if e!=nil {return o,.Out_Of_Memory}
    }
    chunk,e:=make([]u8,CHUNK_MAX,s.state.allocator)
    if e!=nil {return o,.Out_Of_Memory}
    o.chunk=chunk
    bytes:=chunk_read(s,address,o.nodes[0]) or_return
    root,f:=make([]u8,len(bytes),s.state.allocator)
    if f!=nil {return o,.Out_Of_Memory}
    copy(root,bytes)
    o.root_bytes=root
    o.root=node_parse(root) or_return
    if o.root.level>0 && len(o.root.groups)>1 {groups_check(&o) or_return}
    return o,.None
}

// Above level 0 a root's groups cannot be checked against its entries alone:
// each group must begin on the boundary of its first leaf, so the leaves are
// walked once, their nodes only.
@(private)
groups_check :: proc(o:^Object) -> Error {
    Check :: struct {o:^Object,groups:[]Group,next:int,leaf,at:u64,buffers:[NODE_LEVEL_MAX+1][]u8}
    c:=Check{o=o,groups=o.root.groups}
    defer for b in c.buffers {delete(b,o.s.state.allocator)}
    visit :: proc(c:^Check,n:Node_View) -> Error {
        if n.level==0 {
            for e in n.entries {
                for c.next<len(c.groups) && u64(c.groups[c.next].first)==c.leaf {
                    if c.groups[c.next].offset!=c.at {return .Corrupt}
                    c.next+=1
                }
                c.leaf+=1
                c.at+=e.size
            }
            return .None
        }
        if c.buffers[n.level-1]==nil {
            b,e:=make([]u8,CHUNK_MAX,c.o.s.state.allocator)
            if e!=nil {return .Out_Of_Memory}
            c.buffers[n.level-1]=b
        }
        entries:=n.entries
        for e in entries {
            bytes:=chunk_read(c.o.s,e.address,c.buffers[n.level-1]) or_return
            child,parse_error:=node_parse(bytes)
            if parse_error!=.None || child.level!=n.level-1 || child.total!=e.size || len(child.groups)>0 || len(child.meta)>0 {return .Corrupt}
            visit(c,child) or_return
        }
        return .None
    }
    visit(&c,o.root) or_return
    for c.next<len(c.groups) {
        if u64(c.groups[c.next].first)!=c.leaf || c.groups[c.next].offset!=c.at {return .Corrupt}
        c.next+=1
    }
    return .None
}

object_close :: proc(o:^Object) {
    if o.s==nil {return}
    for b in o.nodes {delete(b,o.s.state.allocator)}
    delete(o.chunk,o.s.state.allocator)
    delete(o.root_bytes,o.s.state.allocator)
    o^={}
}

// The bytes of data under the object.
object_size :: proc(o:^Object) -> u64 {return o.root.total}

// The groups of the object's root and its meta, as slices of the object.
object_groups :: proc(o:^Object) -> []Group {return o.root.groups}
object_meta :: proc(o:^Object) -> []u8 {return o.root.meta}

// Fills buffer with the object's bytes from offset, descending once per leaf
// node and reading its chunks in order.
object_read :: proc(o:^Object,offset:u64,buffer:[]u8) -> Error {
    if o.s==nil {return .Invalid_Argument}
    if offset>o.root.total || u64(len(buffer))>o.root.total-offset {return .Invalid_Argument}
    done:=0
    for done<len(buffer) {
        at:=offset+u64(done)
        n:=o.root
        for n.level>0 {
            next:=-1
            for e,i in n.entries {
                if at<e.size {next=i;break}
                at-=e.size
            }
            if next<0 {return .Corrupt}
            n=object_child(o,n,n.entries[next]) or_return
        }
        start:=-1
        for e,i in n.entries {
            if at<e.size {start=i;break}
            at-=e.size
        }
        if start<0 {return .Corrupt}
        for e in n.entries[start:] {
            if done>=len(buffer) {break}
            bytes:=chunk_read(o.s,e.address,o.chunk) or_return
            if u64(len(bytes))!=e.size {return .Corrupt}
            done+=copy(buffer[done:],bytes[at:])
            at=0
        }
    }
    return .None
}

// Fills buffer with the bytes of a group of the object from offset.
group_read :: proc(o:^Object,group:int,offset:u64,buffer:[]u8) -> Error {
    if o.s==nil || group<0 || group>=len(o.root.groups) {return .Invalid_Argument}
    start:=o.root.groups[group].offset
    end:=o.root.groups[group+1].offset if group+1<len(o.root.groups) else o.root.total
    if offset>end-start || u64(len(buffer))>end-start-offset {return .Invalid_Argument}
    return object_read(o,start+offset,buffer)
}

// The chunk that holds a group's byte offset: its bytes, a slice of the mapped
// pack when it is sealed and otherwise of the object's buffer until the next
// call, and where offset falls in it.
group_chunk :: proc(o:^Object,group:int,offset:u64) -> (bytes:[]u8,at:u64,error:Error) {
    if o.s==nil {return nil,0,.Invalid_Argument}
    leaf:=group_locate(object_source(o),o.address,group,offset) or_return
    bytes=chunk_read(o.s,leaf.address,o.chunk) or_return
    if u64(len(bytes))!=leaf.size {return nil,0,.Corrupt}
    start:=o.root.groups[group].offset
    return bytes,start+offset-leaf.offset,.None
}

@(private)
object_source :: proc(o:^Object) -> Node_Source {
    return {procedure=proc(data:rawptr,address:Hash) -> ([]u8,Error) {
        o:=(^Object)(data)
        if address==o.address {return o.root_bytes,.None}
        o.turn=1-o.turn
        return chunk_read(o.s,address,o.nodes[o.turn])
    },data=o}
}

@(private)
object_child :: proc(o:^Object,parent:Node_View,entry:Entry) -> (Node_View,Error) {
    return node_child(object_source(o),parent,entry)
}
