package store

import "core:mem"
import "core:os"
import "mirai:std/base"

// A blob being received lives in partial/<address>/: `table` (its size as
// u64 little endian and its piece hashes), `data` (the pieces at their
// offsets) and `have` (one byte per piece, 1 once it is in data). A folder
// appears there whole through a rename; each writer writes only its own
// piece and its own byte, so receivers in several processes need no lock.

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

// Starts receiving a blob from its address and piece table; the table is
// checked against the address before anything is kept. A blob already
// complete or being received is left as it is.
receive_begin :: proc(s:^Store,hash:Hash,size:i64,pieces:[]Hash) -> Error {
    if size<0 || len(pieces)!=piece_count(size) {return .Invalid_Argument}
    if table_address(size,pieces)!=hash {return .Corrupt}
    if has(s,hash) {
        partial_discard(s,hash)
        return .None
    }
    if size==0 {
        _,error:=put_bytes(s,nil)
        return error
    }
    existing,existing_error:=partial_open(s,hash,{.Data,.Have})
    partial_close(&existing)
    if existing_error==.None {return .None}
    if existing_error==.Corrupt {partial_discard(s,hash)}
    folder_buffer,tmp_buffer:[PATH_BYTES]u8
    folder:=partial_folder(s,hash,&folder_buffer) or_return
    tmp:=join(&tmp_buffer,s.root,"tmp") or_return
    made,made_error:=os.make_directory_temp(tmp,"receive-*",s.allocator)
    if made_error!=nil {return os_error(made_error)}
    defer delete(made,s.allocator)
    error:=partial_write(made,size,pieces)
    if error==.None && os.rename(made,folder)!=nil {
        error=.None if os.is_directory(folder) else .Io
    }
    base.remove_all(made)
    return error
}

// Keeps one received piece: checked against the table and written at its
// offset; a duplicate is harmless. The last missing piece completes the blob.
receive_piece :: proc(s:^Store,hash:Hash,index:int,piece:[]u8) -> Error {
    p,error:=partial_open(s,hash,{.Data,.Have})
    if error==.Missing {return complete_piece(s,hash,index,piece)}
    if error!=.None {return error}
    defer partial_close(&p)
    if index<0 || index>=p.count || len(piece)!=piece_size(p.size,index) {return .Invalid_Argument}
    expected:Hash
    read_exact(p.table,expected[:],TABLE_HEADER+i64(index)*size_of(Hash)) or_return
    if piece_value(piece,index)!=expected {return .Corrupt}
    if _,write_error:=os.write_at(p.data,piece,i64(index)*PIECE_BYTES);write_error!=nil {return os_error(write_error)}
    mark:=[1]u8{1}
    if _,write_error:=os.write_at(p.have,mark[:],i64(index));write_error!=nil {return os_error(write_error)}
    full:=partial_full(&p) or_return
    if !full {return .None}
    return partial_complete(s,hash,&p)
}

// The indices of the pieces a blob being received still lacks; none for a complete blob.
receive_missing :: proc(s:^Store,hash:Hash,allocator:=context.allocator) -> (missing:[]int,error:Error) {
    if has(s,hash) {return nil,.None}
    p:Partial
    p,error=partial_open(s,hash,{.Have})
    if error==.Missing && has(s,hash) {return nil,.None}
    if error!=.None {return nil,error}
    defer partial_close(&p)
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

@(private)
partial_folder :: proc(s:^Store,hash:Hash,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    name:[64]u8
    return join(buffer,s.root,"partial",hex(hash,&name))
}

// Opens the table of a blob being received, and the files asked for; the
// sizes of the table and of have are checked.
@(private)
partial_open :: proc(s:^Store,hash:Hash,files:bit_set[Partial_File]) -> (p:Partial,error:Error) {
    folder_buffer,buffer:[PATH_BYTES]u8
    folder:=partial_folder(s,hash,&folder_buffer) or_return
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

// Checks every piece of data against the table and the table against the
// address. A piece that does not match is marked missing again; a table that
// does not match discards the blob. When all match, data becomes the blob.
@(private)
partial_complete :: proc(s:^Store,hash:Hash,p:^Partial) -> Error {
    Checking :: struct {
        buffer:[PIECE_BYTES]u8,
        p:^Partial,
        damaged:bool,
    }
    checking:=Checking{p=p}
    address:=address_value(p.size,proc(user:rawptr,index:int) -> (Hash,Error) {
        c:=(^Checking)(user)
        entry:Hash
        if error:=read_exact(c.p.table,entry[:],TABLE_HEADER+i64(index)*size_of(Hash));error!=.None {return {},error}
        piece:=c.buffer[:piece_size(c.p.size,index)]
        got:=read_exact(c.p.data,piece,i64(index)*PIECE_BYTES)
        if got!=.None && got!=.Corrupt {return {},got}
        if got==.Corrupt || piece_value(piece,index)!=entry {
            c.damaged=true
            unmark:=[1]u8{0}
            if _,write_error:=os.write_at(c.p.have,unmark[:],i64(index));write_error!=nil {return {},os_error(write_error)}
        }
        return entry,.None
    },&checking) or_return
    damaged:=checking.damaged
    data_size,size_error:=os.file_size(p.data)
    if size_error!=nil {return os_error(size_error)}
    if address!=hash || data_size>p.size {
        partial_close(p)
        partial_discard(s,hash)
        return .Corrupt
    }
    if damaged {return .None}
    partial_close(p)
    folder_buffer,data_buffer:[PATH_BYTES]u8
    folder:=partial_folder(s,hash,&folder_buffer) or_return
    data:=join(&data_buffer,folder,"data") or_return
    if !os.is_file(data) {return .None if has(s,hash) else .Missing}
    blob_place(s,data,hash) or_return
    partial_discard(s,hash)
    return .None
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
    folder_buffer,tmp_buffer,moved_buffer:[PATH_BYTES]u8
    folder:=partial_folder(s,hash,&folder_buffer) or_return
    if !os.is_directory(folder) {return .Missing}
    tmp:=join(&tmp_buffer,s.root,"tmp") or_return
    made,made_error:=os.make_directory_temp(tmp,"discard-*",s.allocator)
    if made_error!=nil {return os_error(made_error)}
    defer delete(made,s.allocator)
    moved:=join(&moved_buffer,made,"blob") or_return
    renamed:=os.rename(folder,moved)
    base.remove_all(made)
    if renamed!=nil {return .Missing if !os.is_directory(folder) else .Io}
    return .None
}

// The range of a blob being received, when all its pieces are here.
@(private)
read_partial :: proc(s:^Store,hash:Hash,offset:i64,buffer:[]u8) -> Error {
    p:=partial_open(s,hash,{.Data,.Have}) or_return
    defer partial_close(&p)
    if offset>p.size || i64(len(buffer))>p.size-offset {return .Invalid_Argument}
    if len(buffer)==0 {return .None}
    first:=int(offset/PIECE_BYTES)
    last:=int((offset+i64(len(buffer))-1)/PIECE_BYTES)
    marks:[4096]u8
    for at:=first;at<=last;at+=len(marks) {
        chunk:=marks[:min(len(marks),last+1-at)]
        read_exact(p.have,chunk,i64(at)) or_return
        for mark in chunk {
            if mark==0 {return .Not_Here_Yet}
        }
    }
    return read_exact(p.data,buffer,offset)
}
