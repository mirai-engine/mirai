package store

import "core:mem"
import "core:os"
import "core:time"
import "mirai:std/base"

// A blob being received lives in partial/<address>/: `table` (its size as
// u64 little endian and its piece hashes), `data` (the pieces at their
// offsets) and `have` (one byte per piece, 1 once it is in data). A folder
// appears there whole through a rename; each writer writes only its own
// piece and its own byte, so receivers in several processes need no lock.
// Whoever finds every piece marked completes the blob: it claims the folder
// by renaming it to partial/<address>.claimed, checks it there and publishes
// only what it checked; a folder it cannot complete goes back. The rename
// lets one claimer through, and the others keep using the claimed folder.

@(private)
TABLE_HEADER :: 8

@(private)
Partial :: struct {
    table,data,have:^os.File,
    size:i64,
    count:int,
}

@(private)
Partial_File :: enum {Data,Have}

// A partial folder claimed for completion. Its strings point into its own
// buffers: it is not copied.
@(private)
Claim :: struct {
    buffer:[PATH_BYTES]u8,
    partial:string, // partial/<address>.claimed; "" when nothing is claimed
    published,discard:bool,
}

@(private)
CLAIMED :: ".claimed"

// Starts receiving a blob from its address and piece table; the table is
// checked against the address before anything is kept.
receive_begin :: proc(s:^Store,hash:Hash,size:i64,pieces:[]Hash,now:Maybe(time.Time)=nil) -> Error {
    if s==nil || s.root=="" {return .Invalid_Argument}
    if size<0 || len(pieces)!=piece_count(size) {return .Invalid_Argument}
    if address_value(size,pieces)!=hash {return .Corrupt}
    refreshed:=blob_refresh(s,hash,now.? or_else time.now())
    if refreshed==.None {
        partial_discard(s,hash)
        return .None
    }
    if refreshed!=.Missing {return refreshed}
    if size==0 {
        _,error:=put_bytes(s,nil,now)
        return error
    }
    existing,existing_error:=partial_open(s,hash,{.Data,.Have})
    if existing_error==.None {
        full,full_error:=partial_full(&existing)
        partial_close(&existing)
        if full_error!=.None {return full_error}
        if !full {return .None}
        if finished:=partial_finish(s,hash,now);finished!=.Corrupt {return finished}
    } else if existing_error==.Corrupt {
        partial_discard(s,hash)
    }
    folder_buffer,made_buffer:[PATH_BYTES]u8
    folder:=partial_folder(s,hash,&folder_buffer) or_return
    made:=temp_folder(s.root,"receive-",&made_buffer) or_return
    error:=partial_write(made,size,pieces)
    if error==.None && os.rename(made,folder)!=nil {
        error=.None if os.is_directory(folder) else .Io
    }
    base.remove_all(made)
    return error
}

// Keeps one received piece: checked against the table and written at its
// offset; a duplicate is harmless. The piece that leaves none missing
// completes the blob.
receive_piece :: proc(s:^Store,hash:Hash,index:int,piece:[]u8,now:Maybe(time.Time)=nil) -> Error {
    if s==nil || s.root=="" {return .Invalid_Argument}
    p,error:=partial_open(s,hash,{.Data,.Have})
    if error==.Missing {return complete_piece(s,hash,index,piece)}
    if error!=.None {return error}
    defer partial_close(&p)
    if index<0 || index>=p.count || len(piece)!=piece_size(p.size,index) {return .Invalid_Argument}
    expected:Hash
    read_exact(p.table,expected[:],TABLE_HEADER+i64(index)*size_of(Hash)) or_return
    if piece_value(piece,index,p.size)!=expected {return .Corrupt}
    if _,write_error:=os.write_at(p.data,piece,i64(index)*PIECE_BYTES);write_error!=nil {return os_error(write_error)}
    mark:=[1]u8{1}
    if _,write_error:=os.write_at(p.have,mark[:],i64(index));write_error!=nil {return os_error(write_error)}
    full:=partial_full(&p) or_return
    partial_close(&p)
    if !full {return .None}
    return partial_finish(s,hash,now)
}

// The indices of the pieces a blob being received still lacks; none for a
// complete blob. One with none missing is completed first.
receive_missing :: proc(s:^Store,hash:Hash,allocator:=context.allocator,now:Maybe(time.Time)=nil) ->
    (missing:[]int,error:Error) {
    if s==nil || s.root=="" {return nil,.Invalid_Argument}
    for attempt in 0..<2 {
        if has(s,hash) {return nil,.None}
        p:Partial
        p,error=partial_open(s,hash,{.Have})
        if error==.Missing && has(s,hash) {return nil,.None}
        if error!=.None {return nil,error}
        missing,error=partial_absent(&p,allocator)
        partial_close(&p)
        if error!=.None || len(missing)>0 || attempt==1 {return missing,error}
        delete(missing,allocator)
        finished:=partial_finish(s,hash,now)
        if finished!=.None {return nil,finished}
    }
    return nil,.None
}

@(private)
partial_folder :: proc(s:^Store,hash:Hash,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    name:[64]u8
    return join(buffer,s.root,"partial",hex(hash,&name))
}

// Opens the table of a blob being received, and the files asked for; the
// sizes of the table and of have are checked.
@(private)
partial_open :: proc(s:^Store,hash:Hash,files:bit_set[Partial_File]) -> (p:Partial,error:Error) {
    folder_buffer:[PATH_BYTES]u8
    p,error=partial_open_at(partial_folder(s,hash,&folder_buffer) or_return,files)
    if error!=.Missing {return}
    return partial_open_at(claimed_folder(s,hash,&folder_buffer) or_return,files)
}

@(private)
claimed_folder :: proc(s:^Store,hash:Hash,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    name:[64+len(CLAIMED)]u8
    hex(hash,(^[64]u8)(&name))
    copy(name[64:],CLAIMED)
    return join(buffer,s.root,"partial",string(name[:]))
}

@(private)
partial_open_at :: proc(folder:string,files:bit_set[Partial_File]) -> (p:Partial,error:Error) {
    buffer:[PATH_BYTES]u8
    open_error:os.Error
    p.table,open_error=os.open(join(&buffer,folder,"table") or_return)
    if open_error!=nil {return {},os_error(open_error)}
    defer if error!=.None {partial_close(&p)}
    header:[TABLE_HEADER]u8
    read_exact(p.table,header[:],0) or_return
    for i in 0..<TABLE_HEADER {p.size|=i64(header[i])<<(8*uint(i))}
    if p.size<=0 {return p,.Corrupt}
    p.count=piece_count(p.size)
    table_size,size_error:=os.file_size(p.table)
    if size_error!=nil {return p,os_error(size_error)}
    if table_size!=TABLE_HEADER+i64(p.count)*size_of(Hash) {return p,.Corrupt}
    if .Data in files {
        p.data,open_error=os.open(join(&buffer,folder,"data") or_return,{.Read,.Write})
        if open_error!=nil {return p,os_error(open_error)}
    }
    if .Have in files {
        p.have,open_error=os.open(join(&buffer,folder,"have") or_return,{.Read,.Write})
        if open_error!=nil {return p,os_error(open_error)}
        have_size,have_error:=os.file_size(p.have)
        if have_error!=nil {return p,os_error(have_error)}
        if have_size!=i64(p.count) {return p,.Corrupt}
    }
    return p,.None
}

@(private)
partial_close :: proc(p:^Partial) {
    for file in ([3]^os.File{p.table,p.data,p.have}) {
        if file!=nil {os.close(file)}
    }
    p.table,p.data,p.have=nil,nil,nil
}

@(private)
partial_write :: proc(folder:string,size:i64,pieces:[]Hash) -> Error {
    buffer:[PATH_BYTES]u8
    header:[TABLE_HEADER]u8
    for i in 0..<TABLE_HEADER {header[i]=u8(u64(size)>>(8*uint(i)))}
    table,table_error:=os.open(join(&buffer,folder,"table") or_return,{.Write,.Create,.Trunc})
    if table_error!=nil {return os_error(table_error)}
    _,header_error:=os.write(table,header[:])
    _,pieces_error:=os.write(table,mem.slice_to_bytes(pieces))
    os.close(table)
    if header_error!=nil || pieces_error!=nil {return .Io}
    data,data_error:=os.open(join(&buffer,folder,"data") or_return,{.Write,.Create,.Trunc})
    if data_error!=nil {return os_error(data_error)}
    os.close(data)
    have,have_error:=os.open(join(&buffer,folder,"have") or_return,{.Write,.Create,.Trunc})
    if have_error!=nil {return os_error(have_error)}
    truncate_error:=os.truncate(have,i64(len(pieces)))
    os.close(have)
    return os_error(truncate_error)
}

@(private)
partial_full :: proc(p:^Partial) -> (full:bool,error:Error) {
    marks:[4096]u8
    for at:=0;at<p.count;at+=len(marks) {
        chunk:=marks[:min(len(marks),p.count-at)]
        read_exact(p.have,chunk,i64(at)) or_return
        for mark in chunk {
            if mark==0 {return false,.None}
        }
    }
    return true,.None
}

// Completes the blob of a partial folder whose pieces are all marked:
// claims it, checks it and publishes it, or gives it back. Nothing to claim
// is no error: another receiver holds it or it is gone.
@(private)
partial_finish :: proc(s:^Store,hash:Hash,now:Maybe(time.Time)) -> Error {
    c:Claim
    claimed:=partial_claim(s,hash,&c,now.? or_else time.now())
    if claimed==.Missing {return .None}
    if claimed!=.None {return claimed}
    defer claim_end(s,hash,&c)
    complete:=claim_verify(s,hash,&c) or_return
    if !complete {return .None}
    return claim_publish(s,hash,&c,now)
}

// Renames the partial folder to its claimed name. A claim older than
// TMP_STALE was left by a process that ended: it goes back first.
@(private)
partial_claim :: proc(s:^Store,hash:Hash,c:^Claim,now:time.Time) -> Error {
    from_buffer:[PATH_BYTES]u8
    from:=partial_folder(s,hash,&from_buffer) or_return
    claimed:=claimed_folder(s,hash,&c.buffer) or_return
    if !os.is_directory(from) {
        at,time_error:=os.modification_time_by_path(claimed)
        if time_error==nil && older_than(at,now,TMP_STALE) {
            os.rename(claimed,from)
        }
        if !os.is_directory(from) {return .Missing}
    }
    os.change_times(from,now,now)
    if os.rename(from,claimed)!=nil {return .Missing}
    c.partial=claimed
    return .None
}

// Whether every piece of the claimed folder is marked and matches the table,
// and the table the address. A piece that does not match is marked missing
// again; a table that does not match is Corrupt and the folder is discarded.
@(private)
claim_verify :: proc(s:^Store,hash:Hash,c:^Claim) -> (complete:bool,error:Error) {
    p:Partial
    p,error=partial_open_at(c.partial,{.Data,.Have})
    if error==.Corrupt {c.discard=true}
    if error!=.None {return false,error}
    defer partial_close(&p)
    full:=partial_full(&p) or_return
    if !full {return false,.None}
    pieces,make_error:=make([]Hash,p.count,s.allocator)
    if make_error!=nil {return false,.Out_Of_Memory}
    defer delete(pieces,s.allocator)
    read_exact(p.table,mem.slice_to_bytes(pieces),TABLE_HEADER) or_return
    buffer:[PIECE_BYTES]u8=---
    damaged:=false
    for index in 0..<p.count {
        _,_,good:=partial_piece(&p,index,&buffer) or_return
        if !good {damaged=true}
    }
    address:=address_value(p.size,pieces)
    data_size,size_error:=os.file_size(p.data)
    if size_error!=nil {return false,os_error(size_error)}
    if address!=hash || data_size>p.size {
        c.discard=true
        return false,.Corrupt
    }
    return !damaged,.None
}

// Moves the checked data into the blob's place, and its table to the kept tables.
@(private)
claim_publish :: proc(s:^Store,hash:Hash,c:^Claim,now:Maybe(time.Time)=nil) -> Error {
    buffer,table_buffer,kept_buffer,folder_buffer:[PATH_BYTES]u8
    placed:=blob_place(s,join(&buffer,c.partial,"data") or_return,hash,now) or_return
    c.published=true
    if !placed {return .None}
    name:[64]u8
    if folder_make(join(&folder_buffer,s.root,"tables",hex(hash,&name)[:2]) or_return)==.None {
        os.rename(join(&table_buffer,c.partial,"table") or_return,table_file(s,hash,&kept_buffer) or_return)
    }
    return .None
}

// Gives a claimed folder that was neither published nor discarded back to
// partial/, and removes one that was.
@(private)
claim_end :: proc(s:^Store,hash:Hash,c:^Claim) {
    if c.partial=="" {return}
    if !c.published && !c.discard {
        back_buffer:[PATH_BYTES]u8
        if back,error:=partial_folder(s,hash,&back_buffer);error==.None && os.rename(c.partial,back)==nil {
            c.partial=""
            return
        }
    }
    folder_discard(s,c.partial)
    c.partial=""
}

// Reads piece index of a partial blob and checks it against its table entry;
// a piece that does not match has its mark cleared.
@(private)
partial_piece :: proc(p:^Partial,index:int,buffer:^[PIECE_BYTES]u8) -> (entry:Hash,piece:[]u8,good:bool,error:Error) {
    read_exact(p.table,entry[:],TABLE_HEADER+i64(index)*size_of(Hash)) or_return
    piece=buffer[:piece_size(p.size,index)]
    got:=read_exact(p.data,piece,i64(index)*PIECE_BYTES)
    if got!=.None && got!=.Corrupt {return entry,nil,false,got}
    if got==.None && piece_value(piece,index,p.size)==entry {return entry,piece,true,.None}
    unmark:=[1]u8{0}
    if _,write_error:=os.write_at(p.have,unmark[:],i64(index));write_error!=nil {return entry,nil,false,os_error(write_error)}
    return entry,nil,false,.None
}

// The indices of the pieces not marked.
@(private)
partial_absent :: proc(p:^Partial,allocator:=context.allocator) -> (missing:[]int,error:Error) {
    absent:=0
    marks:[4096]u8
    for at:=0;at<p.count;at+=len(marks) {
        chunk:=marks[:min(len(marks),p.count-at)]
        read_exact(p.have,chunk,i64(at)) or_return
        for mark in chunk {
            if mark==0 {absent+=1}
        }
    }
    list,make_error:=make([]int,absent,allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    n:=0
    for at:=0;at<p.count;at+=len(marks) {
        chunk:=marks[:min(len(marks),p.count-at)]
        if error=read_exact(p.have,chunk,i64(at));error!=.None {
            delete(list,allocator)
            return nil,error
        }
        for mark,i in chunk {
            if mark==0 && n<len(list) {
                list[n]=at+i
                n+=1
            }
        }
    }
    return list[:n],.None
}

// A piece given for a blob with no partial folder: harmless once the blob is
// complete, when index and length fit it.
@(private)
complete_piece :: proc(s:^Store,hash:Hash,index:int,piece:[]u8) -> Error {
    size,error:=blob_size(s,hash)
    if error!=.None {return error}
    if index<0 || index>=piece_count(size) || len(piece)!=piece_size(size,index) {return .Invalid_Argument}
    return .None
}

// Moves the partial folder of a blob into tmp and removes it there.
@(private)
partial_discard :: proc(s:^Store,hash:Hash) -> Error {
    folder_buffer:[PATH_BYTES]u8
    return folder_discard(s,partial_folder(s,hash,&folder_buffer) or_return)
}

@(private)
folder_discard :: proc(s:^Store,folder:string) -> Error {
    made_buffer,moved_buffer:[PATH_BYTES]u8
    if !os.is_directory(folder) {return .Missing}
    made:=temp_folder(s.root,"discard-",&made_buffer) or_return
    moved:=join(&moved_buffer,made,"blob") or_return
    renamed:=os.rename(folder,moved)
    base.remove_all(made)
    if renamed!=nil {return .Missing if !os.is_directory(folder) else .Io}
    return .None
}

// The range of a blob being received, when all its pieces are here and match the table.
@(private)
read_partial :: proc(s:^Store,hash:Hash,offset:i64,buffer:[]u8) -> Error {
    p:=partial_open(s,hash,{.Data,.Have}) or_return
    defer partial_close(&p)
    if offset>p.size || i64(len(buffer))>p.size-offset {return .Invalid_Argument}
    if len(buffer)==0 {return .None}
    first:=int(offset/PIECE_BYTES)
    last:=int((offset+i64(len(buffer))-1)/PIECE_BYTES)
    piece_buffer:[PIECE_BYTES]u8=---
    for index in first..=last {
        mark:[1]u8
        read_exact(p.have,mark[:],i64(index)) or_return
        if mark[0]==0 {return .Not_Here_Yet}
        _,piece,good:=partial_piece(&p,index,&piece_buffer) or_return
        if !good {return .Not_Here_Yet}
        start:=i64(index)*PIECE_BYTES
        from:=max(offset,start)
        to:=min(offset+i64(len(buffer)),start+i64(len(piece)))
        copy(buffer[from-offset:to-offset],piece[from-start:to-start])
    }
    return .None
}
