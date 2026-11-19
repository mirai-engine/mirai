package store

import "base:runtime"
import "core:mem"
import "core:os"
import "core:time"

// Complete blobs are plain files of their bytes at blobs/<first byte>/<address>,
// both in hex, and are never written in place.

put_bytes :: proc(s:^Store,data:[]u8,now:Maybe(time.Time)=nil) -> (hash:Hash,error:Error) {
    if s==nil || s.root=="" {return {},.Invalid_Argument}
    pieces:=bytes_table(data,s.allocator) or_return
    defer delete(pieces,s.allocator)
    hash=address_value(i64(len(data)),pieces)
    refreshed:=blob_refresh(s,hash,i64(len(data)),now.? or_else time.now())
    return hash,put_bytes_after_refresh(s,data,pieces,hash,refreshed,now)
}

@(private)
put_bytes_after_refresh :: proc(s:^Store,data:[]u8,pieces:[]Hash,hash:Hash,
    refreshed:Error,now:Maybe(time.Time)) -> Error {
    if refreshed!=.Missing && refreshed!=.Wrong_Size {return refreshed}
    temp_buffer:[PATH_BYTES]u8
    temp,file:=temp_create(s.root,&temp_buffer) or_return
    error:=file_fill(file,{data})
    os.close(file)
    placed:bool
    if error==.None {placed,error=blob_place(s,temp,hash,i64(len(data)),now)}
    if error!=.None {
        file_remove(temp)
        return error
    }
    if placed {table_keep(s,hash,i64(len(data)),pieces)}
    return .None
}

// Puts the file at path, read once piece by piece.
put_file :: proc(s:^Store,path:string,now:Maybe(time.Time)=nil) -> (hash:Hash,error:Error) {
    if s==nil || s.root=="" {return {},.Invalid_Argument}
    source,open_error:=file_open(path)
    if open_error!=nil {return {},os_error(open_error)}
    defer os.close(source)
    size,size_error:=os.file_size(source)
    if size_error!=nil {return {},os_error(size_error)}
    pieces,make_error:=make([]Hash,piece_count(size),s.allocator)
    if make_error!=nil {return {},.Out_Of_Memory}
    defer delete(pieces,s.allocator)
    temp_buffer:[PATH_BYTES]u8
    temp,file:=temp_create(s.root,&temp_buffer) or_return
    defer file_remove(temp)
    hash,error=file_hash(source,size,file,pieces)
    if error==.None {error=file_fill(file,nil)}
    os.close(file)
    if error==.Corrupt {error=.Io}
    if error!=.None {return {},error}
    placed:=blob_place(s,temp,hash,size,now) or_return
    if placed {table_keep(s,hash,size,pieces)}
    return hash,.None
}

// Whether the blob is complete here.
has :: proc(s:^Store,hash:Hash) -> bool {
    buffer:[PATH_BYTES]u8
    path,error:=blob_file(s,hash,&buffer)
    return error==.None && os.is_file(path)
}

// The bytes of a complete blob, or of one being received.
blob_size :: proc(s:^Store,hash:Hash) -> (total:i64,error:Error) {
    buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    file,open_error:=file_open(path)
    if open_error==nil {
        defer os.close(file)
        size,size_error:=os.file_size(file)
        return size,os_error(size_error)
    }
    if open_error!=.Not_Exist {return 0,os_error(open_error)}
    p:=partial_open(s,hash,{}) or_return
    defer partial_close(&p)
    return p.size,.None
}

// The path of a complete blob, for readers that open it themselves.
blob_path :: proc(s:^Store,hash:Hash,allocator:=context.allocator) -> (cloned_path:string,error:Error) {
    buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    if !os.is_file(path) {return "",.Missing}
    cloned,clone_error:=make([]u8,len(path),allocator)
    if clone_error!=nil {return "",.Out_Of_Memory}
    copy(cloned,path)
    return string(cloned),.None
}

// Fills buffer with the bytes of the blob from offset: from a complete blob,
// or from the pieces a partial one has; Not_Here_Yet when one of the pieces
// of the range has not arrived. Every piece is checked as a Reader checks it.
read :: proc(s:^Store,hash:Hash,offset:i64,buffer:[]u8) -> Error {
    r:=reader_open(s,hash) or_return
    defer reader_close(&r)
    return reader_read(&r,offset,buffer)
}

// The piece hashes of a blob, complete or being received: its kept table,
// checked against the address; one damaged or not kept is hashed again from
// the file and kept.
blob_table :: proc(s:^Store,hash:Hash,allocator:=context.allocator) -> (pieces:[]Hash,error:Error) {
    r:=reader_open(s,hash) or_return
    defer reader_close(&r)
    return reader_table(&r,allocator)
}

// A blob held open to read checked pieces, complete or being received; its
// owner closes it. A piece of a complete blob is checked against the kept
// table, which is checked against the address when the reader opens: one
// that does not match proves the file damaged, and the blob is removed so it
// can be fetched or put again. A piece of a partial blob is checked against
// its table and is Not_Here_Yet until it arrives whole.
Reader :: struct {
    s:^Store,
    hash:Hash,
    p:Partial, // of a complete blob: data, and table unless it has one piece; of a partial one: table, data and have
    complete:bool,
}

reader_open :: proc(s:^Store,hash:Hash) -> (r:Reader,error:Error) {
    if s==nil || s.root=="" {return {},.Invalid_Argument}
    r.s,r.hash=s,hash
    // A partial blob may complete between the two looks.
    for attempt in 0..<2 {
        r.p,error=complete_open(s,hash)
        if error==.None {
            r.complete=true
            return r,.None
        }
        if error!=.Missing {return {},error}
        r.p,error=partial_open(s,hash,{.Data,.Have})
        if error==.None {return r,.None}
        if error!=.Missing || attempt==1 {return {},error}
    }
    return {},.Missing
}

reader_close :: proc(r:^Reader) {
    partial_close(&r.p)
    r^={}
}

reader_size :: proc(r:^Reader) -> i64 {return r.p.size}

// Piece index, checked, read into buffer, which holds at least its size.
reader_piece :: proc(r:^Reader,index:int,buffer:[]u8) -> (piece:[]u8,error:Error) {
    if r.p.data==nil {return nil,.Invalid_Argument}
    if index<0 || index>=r.p.count || len(buffer)<piece_size(r.p.size,index) {return nil,.Invalid_Argument}
    if !r.complete {
        mark:[1]u8
        read_exact(r.p.have,mark[:],i64(index)) or_return
        if mark[0]==0 {return nil,.Not_Here_Yet}
        good:bool
        _,piece,good=partial_piece(&r.p,index,buffer) or_return
        return piece,.None if good else .Not_Here_Yet
    }
    piece=buffer[:piece_size(r.p.size,index)]
    read_error:=read_exact(r.p.data,piece,i64(index)*PIECE_BYTES)
    entry:=r.hash
    if r.p.table!=nil && read_error==.None {read_error=read_exact(r.p.table,entry[:],TABLE_HEADER+i64(index)*size_of(Hash))}
    if read_error==.None && piece_value(piece,index,r.p.size)==entry {return piece,.None}
    if read_error!=.None && read_error!=.Corrupt {return nil,read_error}
    remove(r.s,r.hash)
    return nil,.Corrupt
}

// Fills buffer with the checked bytes of the blob from offset.
reader_read :: proc(r:^Reader,offset:i64,buffer:[]u8) -> Error {
    if r.p.data==nil {return .Invalid_Argument}
    if offset<0 || offset>r.p.size || i64(len(buffer))>r.p.size-offset {return .Invalid_Argument}
    if len(buffer)==0 {return .None}
    first:=int(offset/PIECE_BYTES)
    last:=int((offset+i64(len(buffer))-1)/PIECE_BYTES)
    piece_buffer:[PIECE_BYTES]u8=---
    for index in first..=last {
        start:=i64(index)*PIECE_BYTES
        from:=max(offset,start)
        to:=min(offset+i64(len(buffer)),start+i64(piece_size(r.p.size,index)))
        // A whole piece of the range is checked where it lands.
        target:=buffer[from-offset:to-offset] if from==start && to-from==i64(piece_size(r.p.size,index)) else piece_buffer[:]
        piece:=reader_piece(r,index,target) or_return
        if raw_data(piece)!=raw_data(buffer[from-offset:]) {copy(buffer[from-offset:to-offset],piece[from-start:to-start])}
    }
    return .None
}

// The piece hashes of the blob.
reader_table :: proc(r:^Reader,allocator:=context.allocator) -> (pieces:[]Hash,error:Error) {
    if r.p.data==nil {return nil,.Invalid_Argument}
    make_error:runtime.Allocator_Error
    pieces,make_error=make([]Hash,r.p.count,allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    if r.p.table==nil {
        if len(pieces)==1 {
            // Its own address: worth giving only of bytes that hash to it.
            buffer:[PIECE_BYTES]u8=---
            if _,error=reader_piece(r,0,buffer[:]);error!=.None {
                delete(pieces,allocator)
                return nil,error
            }
            pieces[0]=r.hash
        }
        return pieces,.None
    }
    error=read_exact(r.p.table,mem.slice_to_bytes(pieces),TABLE_HEADER)
    // The kept table of a complete blob was checked when the reader opened.
    if error==.None && !r.complete && address_value(r.p.size,pieces)!=r.hash {error=.Corrupt}
    if error!=.None {
        delete(pieces,allocator)
        return nil,error
    }
    return pieces,.None
}

// Opens a complete blob and its kept table, checked against the address; a
// table damaged or not kept is hashed again from the file, and a file that
// does not hash to the address is removed (Corrupt).
@(private)
complete_open :: proc(s:^Store,hash:Hash) -> (Partial,Error) {
    p,error:=complete_files(s,hash)
    if error!=.None {
        partial_close(&p)
        return {},error
    }
    return p,.None
}

@(private)
complete_files :: proc(s:^Store,hash:Hash) -> (p:Partial,error:Error) {
    buffer:[PATH_BYTES]u8
    open_error:os.Error
    p.data,open_error=file_open(blob_file(s,hash,&buffer) or_return)
    if open_error!=nil {return {},os_error(open_error)}
    size_error:os.Error
    p.size,size_error=os.file_size(p.data)
    if size_error!=nil {return p,os_error(size_error)}
    p.count=piece_count(p.size)
    if p.count==0 && hash!=address_of_bytes(nil) {return p,.Corrupt}
    if p.count<=1 {return p,.None}
    table_buffer:[PATH_BYTES]u8
    path:=table_file(s,hash,&table_buffer) or_return
    p.table,open_error=file_open(path)
    if open_error==nil {
        checked:=table_check(p.table,p.size,hash)
        if checked==.None {return p,.None}
        if checked!=.Corrupt {return p,checked}
        os.close(p.table)
        p.table=nil
    } else if open_error!=.Not_Exist {
        return p,os_error(open_error)
    }
    rebuilt:=table_rebuild(s,hash,p.data,p.size,path)
    if rebuilt==.Corrupt {remove(s,hash)}
    if rebuilt!=.None {return p,rebuilt}
    p.table,open_error=file_open(path)
    return p,os_error(open_error)
}

// Writes the table of the file of a complete blob to path, a run of pieces
// at a time; Corrupt when the file does not hash to the address.
@(private)
table_rebuild :: proc(s:^Store,hash:Hash,data:^os.File,size:i64,path:string) -> Error {
    buffer,folder_buffer:[PATH_BYTES]u8
    name:[64]u8
    folder_make(join(&folder_buffer,s.root,"tables",hex(hash,&name)[:2]) or_return) or_return
    temp,file:=temp_create(s.root,&buffer) or_return
    header:=table_header(size)
    error:=file_append(file,{header[:]})
    if error==.None {error=table_hash(data,size,file,hash)}
    if error==.None {error=file_fill(file,nil)}
    os.close(file)
    if error==.None {error=os_error(rename_replace(temp,path))}
    if error!=.None {file_remove(temp)}
    return error
}

// Corrupt when the file of a complete blob no longer has the bytes of its address.
verify :: proc(s:^Store,hash:Hash) -> Error {
    buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    address,_,error:=address_of_file(path,s.allocator)
    if error==.Io {return .Corrupt}
    if error!=.None {return error}
    return .None if address==hash else .Corrupt
}

// Removes the blob, complete or partial.
remove :: proc(s:^Store,hash:Hash) -> Error {
    buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    removed:=file_remove(path)
    if removed!=nil && removed!=.Not_Exist {return os_error(removed)}
    table_drop(s,hash)
    discarded:=partial_discard(s,hash)
    if discarded!=.None && discarded!=.Missing {return discarded}
    return .Missing if removed!=nil && discarded==.Missing else .None
}

@(private)
blob_file :: proc(s:^Store,hash:Hash,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    name:[64]u8
    text:=hex(hash,&name)
    return join(buffer,s.root,"blobs",text[:2],text)
}

// None when the blob of size is here, its time refreshed; Missing when it is
// not; Wrong_Size when a file of another size holds its place, to be
// replaced.
@(private)
blob_refresh :: proc(s:^Store,hash:Hash,size:i64,now:time.Time) -> Error {
    buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    at,found:=regular_info(s,path) or_return
    if found!=size {return .Wrong_Size}
    if !older_than(at,now,BLOB_REFRESH_AGE) {return .None}
    return blob_touch(s,path,now)
}

@(private)
blob_touch :: proc(s:^Store,path:string,now:time.Time) -> Error {
    os_error(os.change_times(path,now,now)) or_return
    // A path-based time change can resolve the file just before it is claimed.
    at,_:=regular_info(s,path) or_return
    return .Missing if older_than(at,now,BLOB_REFRESH_AGE) else .None
}

// Renames a finished file of size into place, over a file of another size
// there, or refreshes the blob another writer placed.
@(private)
blob_place :: proc(s:^Store,temp:string,hash:Hash,size:i64,clock:Maybe(time.Time)) ->
    (placed:bool,error:Error) {
    buffer,folder_buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    name:[64]u8
    text:=hex(hash,&name)
    for _ in 0..<TEMP_ATTEMPTS {
        now:=clock.? or_else time.now()
        refreshed:=blob_refresh(s,hash,size,now)
        if refreshed==.None {
            file_remove(temp)
            return false,.None
        }
        if refreshed!=.Missing && refreshed!=.Wrong_Size {return false,refreshed}
        folder_make(join(&folder_buffer,s.root,"blobs",text[:2]) or_return) or_return
        os_error(os.change_times(temp,now,now)) or_return
        if refreshed==.Wrong_Size {
            // Any writer replaces it with the same bytes.
            os_error(rename_replace(temp,path)) or_return
            return true,.None
        }
        exists:=rename_new(temp,path) or_return
        if !exists {return true,.None}
    }
    return false,.Io
}

// The kept table of a blob: tables/<first byte>/<address>, its size as u64
// little endian and its piece hashes, as the table of a partial blob.
@(private)
table_file :: proc(s:^Store,hash:Hash,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    name:[64]u8
    text:=hex(hash,&name)
    return join(buffer,s.root,"tables",text[:2],text)
}

// Keeps the table of a complete blob of several pieces; one that cannot be
// written is hashed again when asked for.
@(private)
table_keep :: proc(s:^Store,hash:Hash,size:i64,pieces:[]Hash) {
    if len(pieces)<2 {return}
    buffer,folder_buffer:[PATH_BYTES]u8
    path,error:=table_file(s,hash,&buffer)
    if error!=.None {return}
    name:[64]u8
    folder,folder_error:=join(&folder_buffer,s.root,"tables",hex(hash,&name)[:2])
    if folder_error!=.None || folder_make(folder)!=.None {return}
    header:=table_header(size)
    file_write(s.root,path,{header[:],mem.slice_to_bytes(pieces)})
}

@(private)
table_drop :: proc(s:^Store,hash:Hash) {
    buffer:[PATH_BYTES]u8
    if path,error:=table_file(s,hash,&buffer);error==.None {file_remove(path)}
}

@(private)
table_header :: proc "contextless" (size:i64) -> (header:[TABLE_HEADER]u8) {
    for i in 0..<TABLE_HEADER {header[i]=u8(u64(size)>>(8*uint(i)))}
    return
}
