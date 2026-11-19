package store

import "base:runtime"
import "core:mem"
import "core:os"
import "core:sync"
import "core:time"
import "mirai:std/blake3"

// Bridge, removed by the branches that rebuild the consumers on objects
// (exchange/chunks, asset/parts, share/tree): a blob is the standard BLAKE3 of
// a whole file's bytes, kept as an object of one group and an alias, a ref of
// the reserved namespace "" whose name is the blob's hex and whose target is
// the object's root. The old wire serves and receives a blob in pieces of
// PIECE_BYTES whose table is checked against the blob's address.

// A blob is cut in pieces of PIECE_BYTES, the last one shorter; an empty blob
// has none. A piece is a BLAKE3 group, so the address is the root of the table.
PIECE_BYTES :: 64<<10
#assert(PIECE_BYTES==blake3.GROUP_BYTES)

@(private) BLOBS_FOLDER :: "tmp/blobs"

piece_count :: proc "contextless" (size:i64) -> int {
    if size<=0 {return 0}
    return int((size-1)/PIECE_BYTES+1)
}

// The bytes of piece index of a blob of size; 0 for an index out of range.
piece_size :: proc "contextless" (size:i64,index:int) -> int {
    if index<0 || index>=piece_count(size) {return 0}
    return int(min(size-i64(index)*PIECE_BYTES,PIECE_BYTES))
}

// The address of the file at path, read once piece by piece.
address_of_file :: proc(path:string,allocator:=context.allocator) -> (hash:Hash,size:i64,error:Error) {
    file,open_error:=file_open(path)
    if open_error!=nil {return {},0,os_error(open_error)}
    defer os.close(file)
    file_size,size_error:=os.file_size(file)
    if size_error!=nil {return {},0,os_error(size_error)}
    hasher:blake3.Hasher
    buffer:[PIECE_BYTES]u8=---
    for at:=i64(0);at<file_size;at+=PIECE_BYTES {
        piece:=buffer[:min(PIECE_BYTES,file_size-at)]
        if e:=read_exact(file,piece,at);e!=.None {return {},0,.Io if e==.Corrupt else e}
        blake3.update(&hasher,piece)
    }
    return Hash(blake3.final(&hasher)),file_size,.None
}

// The value of piece index of a blob of size, from its bytes: the BLAKE3
// hash of a blob of one piece, otherwise its BLAKE3 group value.
@(private)
piece_value :: proc(piece:[]u8,index:int,size:i64) -> Hash {
    if size<=PIECE_BYTES {return Hash(blake3.hash(piece))}
    value,_:=blake3.group_value(piece,u64(max(index,0)))
    return Hash(value)
}

// The address of a blob of size, from its piece table; a table that does not
// fit size gives a value no blob has.
@(private)
address_value :: proc(size:i64,pieces:[]Hash) -> Hash {
    if size<0 || len(pieces)!=piece_count(size) {return {}}
    if size==0 {return Hash(blake3.hash(nil))}
    if len(pieces)==1 {return pieces[0]}
    root,_:=blake3.root(transmute([]blake3.Hash)pieces,u64(size))
    return Hash(root)
}

// The root of the object of a blob, from its alias.
@(private)
alias_locked :: proc(s:^Store,blob:Hash) -> (root:Hash,time:i64,found:bool) {
    text:[64]u8
    v,ok:=ref_resolve_locked(s,"",hex(blob,&text))
    if !ok {return {},0,false}
    _,_,present:=lookup_locked(s,v.address)
    return v.address,v.time,present
}

@(private)
alias_stage :: proc(st:^Stage,blob,root:Hash,now:i64) -> Error {
    text:[64]u8
    return ref_stage(st,"",hex(blob,&text),root,now)
}

// None when the blob is here at size, its alias refreshed when older than a
// quarter of GRACE; Missing when it is not; Wrong_Size when its object holds
// another size.
@(private)
blob_present :: proc(s:^Store,blob:Hash,size:i64,now:Maybe(time.Time)) -> Error {
    at:=(now.? or_else time.now())._nsec
    sync.mutex_lock(&s.state.lock)
    refresh_locked(s)
    root,since,found:=alias_locked(s,blob)
    total:i64=-1
    if found {
        buffer:[CHUNK_MAX]u8
        if bytes,error:=chunk_bytes_locked(s,root,buffer[:]);error==.None {
            if n,parse_error:=node_parse(bytes);parse_error==.None {total=i64(n.total)}
        }
    }
    sync.mutex_unlock(&s.state.lock)
    if !found {return .Missing}
    if total!=size {return .Wrong_Size}
    if at-since<=i64(GRACE/4) {return .None}
    st:=stage_take(s) or_return
    defer stage_give(s,st)
    alias_stage(st,blob,root,at) or_return
    stage_write(s,st,at) or_return
    return commit(s,time.Time{_nsec=at})
}

put_bytes :: proc(s:^Store,data:[]u8,now:Maybe(time.Time)=nil) -> (hash:Hash,error:Error) {
    if s==nil || s.state==nil {return {},.Invalid_Argument}
    hash=address_of_bytes(data)
    present:=blob_present(s,hash,i64(len(data)),now)
    if present!=.Missing && present!=.Wrong_Size {return hash,present}
    at:=(now.? or_else time.now())._nsec
    root:=put(s,data,time.Time{_nsec=at}) or_return
    return hash,alias_commit(s,hash,root,at)
}

@(private)
alias_commit :: proc(s:^Store,blob,root:Hash,at:i64) -> Error {
    st:=stage_take(s) or_return
    defer stage_give(s,st)
    alias_stage(st,blob,root,at) or_return
    stage_write(s,st,at) or_return
    return commit(s,time.Time{_nsec=at})
}

// The root of a complete blob's object, from its alias as this value knows
// it, without reading the root again: what a peer serves for a blob address.
blob_root :: proc(s:^Store,blob:Hash) -> (root:Hash,found:bool) {
    if s==nil || s.state==nil {return {},false}
    sync.mutex_lock(&s.state.lock)
    defer sync.mutex_unlock(&s.state.lock)
    root,_,found=alias_locked(s,blob)
    return
}

// Names a received object as a blob once its bytes hash to the blob's
// address (Corrupt otherwise): the alias goes into the batch, after the
// chunks it reaches, and commit makes it visible.
blob_alias :: proc(s:^Store,blob,root:Hash,now:Maybe(time.Time)=nil) -> Error {
    if s==nil || s.state==nil {return .Invalid_Argument}
    o:=object_open(s,root) or_return
    hasher:blake3.Hasher
    buffer,e:=make([]u8,1<<20,context.temp_allocator)
    if e!=nil {
        object_close(&o)
        return .Out_Of_Memory
    }
    size:=object_size(&o)
    for at:=u64(0);at<size; {
        part:=buffer[:min(u64(len(buffer)),size-at)]
        if read_error:=object_read(&o,at,part);read_error!=.None {
            object_close(&o)
            delete(buffer,context.temp_allocator)
            return read_error
        }
        blake3.update(&hasher,part)
        at+=u64(len(part))
    }
    object_close(&o)
    delete(buffer,context.temp_allocator)
    if Hash(blake3.final(&hasher))!=blob {return .Corrupt}
    at:=(now.? or_else time.now())._nsec
    st:=stage_take(s) or_return
    defer stage_give(s,st)
    alias_stage(st,blob,root,at) or_return
    return stage_write(s,st,at)
}

// Puts the file at path, read once.
put_file :: proc(s:^Store,path:string,now:Maybe(time.Time)=nil) -> (hash:Hash,error:Error) {
    if s==nil || s.state==nil {return {},.Invalid_Argument}
    hash,_,error=blob_put_path(s,path,nil,now)
    return
}

// Puts the file at path as a blob's object and alias; with expected, only
// when its bytes hash to it (Corrupt otherwise).
@(private)
blob_put_path :: proc(s:^Store,path:string,expected:Maybe(Hash),now:Maybe(time.Time)) -> (hash:Hash,size:i64,error:Error) {
    source,open_error:=file_open(path)
    if open_error!=nil {return {},0,os_error(open_error)}
    defer os.close(source)
    file_size,size_error:=os.file_size(source)
    if size_error!=nil {return {},0,os_error(size_error)}
    at:=(now.? or_else time.now())._nsec
    p:=put_begin(s,time.Time{_nsec=at}) or_return
    hasher:blake3.Hasher
    buffer,e:=make([]u8,1<<20,context.temp_allocator)
    if e!=nil {
        put_abandon(&p)
        return {},0,.Out_Of_Memory
    }
    defer delete(buffer,context.temp_allocator)
    for done:=i64(0);done<file_size; {
        part:=buffer[:min(i64(len(buffer)),file_size-done)]
        if read_error:=read_exact(source,part,done);read_error!=.None {
            put_abandon(&p)
            return {},0,.Io if read_error==.Corrupt else read_error
        }
        blake3.update(&hasher,part)
        if write_error:=put_write(&p,part);write_error!=.None {
            put_abandon(&p)
            return {},0,write_error
        }
        done+=i64(len(part))
    }
    after:[1]u8
    if n,_:=os.read_at(source,after[:],file_size);n>0 {
        put_abandon(&p)
        return {},0,.Io
    }
    root,_:=put_finish(&p) or_return
    hash=Hash(blake3.final(&hasher))
    if want,ok:=expected.?;ok && want!=hash {return hash,file_size,.Corrupt}
    return hash,file_size,alias_commit(s,hash,root,at)
}

// Whether the blob is complete here.
has :: proc(s:^Store,hash:Hash) -> bool {
    if s==nil || s.state==nil {return false}
    sync.mutex_lock(&s.state.lock)
    defer sync.mutex_unlock(&s.state.lock)
    // Another value may have removed it, or a sweep dropped it: the root is read again first.
    if refresh_locked(s)!=.None {return false}
    _,_,found:=alias_locked(s,hash)
    return found
}

// The object of a complete blob, open.
@(private)
blob_object :: proc(s:^Store,hash:Hash) -> (o:Object,error:Error) {
    sync.mutex_lock(&s.state.lock)
    root,_,found:=alias_locked(s,hash)
    if !found {
        refresh_locked(s)
        root,_,found=alias_locked(s,hash)
    }
    sync.mutex_unlock(&s.state.lock)
    if !found {return {},.Missing}
    return object_open(s,root)
}

// The bytes of a complete blob, or of one being received.
blob_size :: proc(s:^Store,hash:Hash) -> (total:i64,error:Error) {
    if s==nil || s.state==nil {return 0,.Invalid_Argument}
    o,open_error:=blob_object(s,hash)
    if open_error==.None {
        defer object_close(&o)
        return i64(object_size(&o)),.None
    }
    if open_error!=.Missing {return 0,open_error}
    p:=partial_open(s,hash,{}) or_return
    defer partial_close(&p)
    return p.size,.None
}

// The path of a file of a complete blob's bytes, for readers that open it
// themselves: written once into the root's tmp/blobs and kept while the
// blob is used.
blob_path :: proc(s:^Store,hash:Hash,allocator:=context.allocator) -> (cloned_path:string,error:Error) {
    if s==nil || s.state==nil {return "",.Invalid_Argument}
    o:=blob_object(s,hash) or_return
    defer object_close(&o)
    buffer:[PATH_BYTES]u8
    name:[64]u8
    path:=join(&buffer,s.root,BLOBS_FOLDER,hex(hash,&name)) or_return
    size:=i64(object_size(&o))
    if info,stat_error:=os.stat(path,context.temp_allocator);stat_error==nil && info.size==size && info.type==.Regular {
        now:=time.now()
        os.change_times(path,now,now)
    } else {
        temp_buffer:[PATH_BYTES]u8
        temp,file:=temp_create(s,s.root,&temp_buffer) or_return
        written:=object_copy(&o,file)
        os.close(file)
        if written==.None {written=io_rename(s,temp,path)}
        if written!=.None {
            file_remove(temp)
            return "",written
        }
    }
    cloned,clone_error:=make([]u8,len(path),allocator)
    if clone_error!=nil {return "",.Out_Of_Memory}
    copy(cloned,path)
    return string(cloned),.None
}

@(private)
object_copy :: proc(o:^Object,file:^os.File) -> Error {
    buffer,e:=make([]u8,1<<20,context.temp_allocator)
    if e!=nil {return .Out_Of_Memory}
    defer delete(buffer,context.temp_allocator)
    size:=object_size(o)
    for at:=u64(0);at<size; {
        part:=buffer[:min(u64(len(buffer)),size-at)]
        object_read(o,at,part) or_return
        io_write_at(o.s,file,part,i64(at)) or_return
        at+=u64(len(part))
    }
    return .None
}

// Fills buffer with the bytes of the blob from offset: from a complete blob,
// or from the pieces a partial one has (Not_Here_Yet when one of the range has
// not arrived, each checked as a Reader checks it).
read :: proc(s:^Store,hash:Hash,offset:i64,buffer:[]u8) -> Error {
    r:=reader_open(s,hash) or_return
    defer reader_close(&r)
    return reader_read(&r,offset,buffer)
}

// The piece hashes of a blob: of a complete one, hashed from its bytes and
// checked against its address; of a partial one, its table.
blob_table :: proc(s:^Store,hash:Hash,allocator:=context.allocator) -> (pieces:[]Hash,error:Error) {
    r:=reader_open(s,hash) or_return
    defer reader_close(&r)
    return reader_table(&r,allocator)
}

// A blob held open to read checked pieces, complete or being received; its
// owner closes it. The piece table of a complete blob is hashed from its bytes
// the first time a piece is asked, and checked against the address: bytes
// that do not make it prove the blob damaged, and it is removed so that it is
// fetched or put again.
Reader :: struct {
    s:^Store,
    hash:Hash,
    p:Partial, // of a blob being received
    complete:bool,
    object:Object,
    size:i64,
    table:[]Hash,
}

reader_open :: proc(s:^Store,hash:Hash) -> (r:Reader,error:Error) {
    if s==nil || s.state==nil {return {},.Invalid_Argument}
    r.s,r.hash=s,hash
    for attempt in 0..<2 {
        r.object,error=blob_object(s,hash)
        if error==.None {
            r.complete=true
            r.size=i64(object_size(&r.object))
            if r.size==0 && hash!=address_of_bytes(nil) {
                object_close(&r.object)
                return {},.Corrupt
            }
            return r,.None
        }
        if error!=.Missing {return {},error}
        r.p,error=partial_open(s,hash,{.Data,.Have})
        if error==.None {
            r.size=r.p.size
            return r,.None
        }
        if error!=.Missing || attempt==1 {return {},error}
    }
    return {},.Missing
}

reader_close :: proc(r:^Reader) {
    partial_close(&r.p)
    object_close(&r.object)
    if r.s!=nil {delete(r.table,r.s.state.allocator)}
    r^={}
}

reader_size :: proc(r:^Reader) -> i64 {return r.size}

// The table of a complete blob, hashed once from its bytes.
@(private)
reader_hash :: proc(r:^Reader) -> Error {
    if r.table!=nil || r.size==0 {return .None}
    pieces,e:=make([]Hash,piece_count(r.size),r.s.state.allocator)
    if e!=nil {return .Out_Of_Memory}
    buffer:[PIECE_BYTES]u8=---
    for &piece,index in pieces {
        bytes:=buffer[:piece_size(r.size,index)]
        if read_error:=object_read(&r.object,u64(index)*PIECE_BYTES,bytes);read_error!=.None {
            delete(pieces,r.s.state.allocator)
            return read_error
        }
        piece=piece_value(bytes,index,r.size)
    }
    if address_value(r.size,pieces)!=r.hash {
        delete(pieces,r.s.state.allocator)
        blob_damaged(r.s,r.hash)
        return .Corrupt
    }
    r.table=pieces
    return .None
}

// Piece index, checked, read into buffer, which holds at least its size.
reader_piece :: proc(r:^Reader,index:int,buffer:[]u8) -> (piece:[]u8,error:Error) {
    if r.s==nil {return nil,.Invalid_Argument}
    if index<0 || index>=piece_count(r.size) || len(buffer)<piece_size(r.size,index) {return nil,.Invalid_Argument}
    if !r.complete {
        mark:[1]u8
        read_exact(r.p.have,mark[:],i64(index)) or_return
        if mark[0]==0 {return nil,.Not_Here_Yet}
        good:bool
        _,piece,good=partial_piece(&r.p,index,buffer) or_return
        return piece,.None if good else .Not_Here_Yet
    }
    reader_hash(r) or_return
    piece=buffer[:piece_size(r.size,index)]
    object_read(&r.object,u64(index)*PIECE_BYTES,piece) or_return
    if piece_value(piece,index,r.size)==r.table[index] {return piece,.None}
    blob_damaged(r.s,r.hash)
    return nil,.Corrupt
}

// Fills buffer with the checked bytes of the blob from offset.
reader_read :: proc(r:^Reader,offset:i64,buffer:[]u8) -> Error {
    if r.s==nil {return .Invalid_Argument}
    if offset<0 || offset>r.size || i64(len(buffer))>r.size-offset {return .Invalid_Argument}
    if len(buffer)==0 {return .None}
    if r.complete && r.table==nil && offset==0 && i64(len(buffer))==r.size {
        // The whole blob: read once and checked against its address.
        object_read(&r.object,0,buffer) or_return
        if address_of_bytes(buffer)==r.hash {return .None}
        blob_damaged(r.s,r.hash)
        return .Corrupt
    }
    first:=int(offset/PIECE_BYTES)
    last:=int((offset+i64(len(buffer))-1)/PIECE_BYTES)
    piece_buffer:[PIECE_BYTES]u8=---
    for index in first..=last {
        start:=i64(index)*PIECE_BYTES
        from:=max(offset,start)
        to:=min(offset+i64(len(buffer)),start+i64(piece_size(r.size,index)))
        piece:=reader_piece(r,index,piece_buffer[:]) or_return
        copy(buffer[from-offset:to-offset],piece[from-start:to-start])
    }
    return .None
}

// The piece hashes of the blob.
reader_table :: proc(r:^Reader,allocator:=context.allocator) -> (pieces:[]Hash,error:Error) {
    if r.s==nil {return nil,.Invalid_Argument}
    make_error:runtime.Allocator_Error
    if r.complete {
        reader_hash(r) or_return
        pieces,make_error=make([]Hash,piece_count(r.size),allocator)
        if make_error!=nil {return nil,.Out_Of_Memory}
        copy(pieces,r.table)
        return pieces,.None
    }
    pieces,make_error=make([]Hash,r.p.count,allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    error=read_exact(r.p.table,mem.slice_to_bytes(pieces),TABLE_HEADER)
    if error==.None && address_value(r.p.size,pieces)!=r.hash {error=.Corrupt}
    if error!=.None {
        delete(pieces,allocator)
        return nil,error
    }
    return pieces,.None
}

// Corrupt when the bytes of a complete blob no longer make its address; each
// damaged chunk gets a Tombstone frame and the blob is removed. A file written
// for blob_path that no longer holds them is removed and written again when
// asked.
verify :: proc(s:^Store,hash:Hash) -> Error {
    if s==nil || s.state==nil {return .Invalid_Argument}
    buffer:[PATH_BYTES]u8
    name:[64]u8
    if path,e:=join(&buffer,s.root,BLOBS_FOLDER,hex(hash,&name));e==.None && os.exists(path) {
        if address,_,error:=address_of_file(path,s.state.allocator);error!=.None || address!=hash {file_remove(path)}
    }
    o:=blob_object(s,hash) or_return
    defer object_close(&o)
    hasher:blake3.Hasher
    piece:[PIECE_BYTES]u8=---
    size:=object_size(&o)
    for at:=u64(0);at<size;at+=PIECE_BYTES {
        bytes:=piece[:min(PIECE_BYTES,size-at)]
        if e:=object_read(&o,at,bytes);e!=.None {
            if e==.Out_Of_Memory || e==.Io {return e}
            blob_damaged(s,hash)
            return .Corrupt
        }
        blake3.update(&hasher,bytes)
    }
    if Hash(blake3.final(&hasher))==hash {return .None}
    blob_damaged(s,hash)
    return .Corrupt
}

// Tombstones the chunks of a blob's object that do not match their address
// and removes the blob.
@(private)
blob_damaged :: proc(s:^Store,hash:Hash) {
    state:=s.state
    st,error:=stage_take(s)
    if error!=.None {return}
    defer stage_give(s,st)
    at:=time.now()._nsec
    sync.mutex_lock(&state.lock)
    root,_,found:=alias_locked(s,hash)
    if found {
        visited:=make(map[Hash]struct{},16,context.temp_allocator)
        damaged_walk(s,st,root,-1,0,&visited)
        delete(visited)
    }
    text:[64]u8
    ref_stage(st,"",hex(hash,&text),{},at)
    sync.mutex_unlock(&state.lock)
    if stage_write(s,st,at)==.None {commit(s,time.Time{_nsec=at})}
    blob_file_drop(s,hash)
}

@(private)
damaged_walk :: proc(s:^Store,st:^Stage,address:Hash,level,depth:int,visited:^map[Hash]struct{}) {
    if depth>NODE_LEVEL_MAX+1 || address in visited^ {return}
    map_insert(visited,address,struct{}{})
    pack,location,found:=lookup_locked(s,address)
    if !found {return}
    buffer,e:=make([]u8,CHUNK_MAX,context.temp_allocator)
    if e!=nil {return}
    defer delete(buffer,context.temp_allocator)
    bytes,read_error:=location_bytes_locked(s,pack,location,buffer)
    if read_error!=.None || address_of_bytes(bytes)!=address {
        tomb_stage(s,st,pack,location,address)
        return
    }
    if level==0 {return}
    n,parse_error:=node_parse(bytes)
    if parse_error!=.None || (level>0 && n.level!=level) {return}
    children,f:=make([]Entry,len(n.entries),context.temp_allocator)
    if f!=nil {return}
    defer delete(children,context.temp_allocator)
    copy(children,n.entries)
    for c in children {damaged_walk(s,st,c.address,max(n.level-1,0) if n.level>0 else 0,depth+1,visited)}
}

// Removes the blob, complete or partial: its alias goes, and its chunks stay
// until a sweep finds nothing else reaching them.
remove :: proc(s:^Store,hash:Hash) -> Error {
    if s==nil || s.state==nil {return .Invalid_Argument}
    present:=has(s,hash)
    removed:=Error.None
    if present {
        at:=time.now()._nsec
        st:=stage_take(s) or_return
        text:[64]u8
        if removed=ref_stage(st,"",hex(hash,&text),{},at);removed==.None {removed=stage_write(s,st,at)}
        stage_give(s,st)
        if removed==.None {removed=commit(s,time.Time{_nsec=at})}
        if removed!=.None {return removed}
    }
    blob_file_drop(s,hash)
    discarded:=partial_discard(s,hash)
    if discarded!=.None && discarded!=.Missing {return discarded}
    return .Missing if !present && discarded==.Missing else .None
}

@(private)
blob_file_drop :: proc(s:^Store,hash:Hash) {
    buffer:[PATH_BYTES]u8
    name:[64]u8
    if path,e:=join(&buffer,s.root,BLOBS_FOLDER,hex(hash,&name));e==.None {file_remove(path)}
}

// What a sweep removes of the bridge: the files written for blob_path of blobs
// that are no longer here or not used for TMP_STALE, and the partial blobs
// outside the live set that took no piece for PARTIAL_GRACE_AGE.
@(private)
bridge_sweep :: proc(s:^Store,live:^Live_Set,now:time.Time,result:^Sweep_Result) -> Error {
    buffer:[PATH_BYTES]u8
    entries:=io_list(s,join(&buffer,s.root,BLOBS_FOLDER) or_return) or_return
    defer os.file_info_slice_delete(entries,s.state.allocator)
    for e in entries {
        hash,ok:=parse_hex(e.name)
        if !ok {continue}
        _,_,present:=alias_locked(s,hash)
        if present && (hash in live^ || !older_than(e.modification_time,now,TMP_STALE)) {continue}
        file_remove(e.fullpath)
    }
    return partials_sweep(s,live,now,result)
}
