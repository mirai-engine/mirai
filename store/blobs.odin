package store

import "base:runtime"
import "core:mem"
import "core:os"

// Complete blobs are plain files of their bytes at blobs/<first byte>/<address>,
// both in hex, and are never written in place.

put_bytes :: proc(s:^Store,data:[]u8) -> (hash:Hash,error:Error) {
    pieces:=bytes_table(data,s.allocator) or_return
    defer delete(pieces,s.allocator)
    hash=address_value(i64(len(data)),pieces)
    if has(s,hash) {return hash,.None}
    temp_buffer:[PATH_BYTES]u8
    temp,file:=temp_create(s.root,&temp_buffer) or_return
    _,write_error:=os.write(file,data)
    sync_error:=os.sync(file)
    os.close(file)
    if write_error!=nil || sync_error!=nil {
        os.remove(temp)
        return {},os_error(write_error) if write_error!=nil else .Io
    }
    if error=blob_place(s,temp,hash);error!=.None {
        os.remove(temp)
        return hash,error
    }
    table_keep(s,hash,i64(len(data)),pieces)
    return hash,.None
}

// Puts the file at path, read once piece by piece.
put_file :: proc(s:^Store,path:string) -> (hash:Hash,error:Error) {
    source,open_error:=os.open(path)
    if open_error!=nil {return {},os_error(open_error)}
    defer os.close(source)
    size,size_error:=os.file_size(source)
    if size_error!=nil {return {},os_error(size_error)}
    pieces,make_error:=make([]Hash,piece_count(size),s.allocator)
    if make_error!=nil {return {},.Out_Of_Memory}
    defer delete(pieces,s.allocator)
    temp_buffer:[PATH_BYTES]u8
    temp,file:=temp_create(s.root,&temp_buffer) or_return
    hash,error=file_hash(source,size,file,pieces)
    sync_error:=os.sync(file) if error==.None else nil
    os.close(file)
    if error==.Corrupt {error=.Io}
    if error==.None && sync_error!=nil {error=.Io}
    if error!=.None || has(s,hash) {
        os.remove(temp)
        return hash if error==.None else {},error
    }
    if error=blob_place(s,temp,hash);error!=.None {
        os.remove(temp)
        return hash,error
    }
    table_keep(s,hash,size,pieces)
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
    file,open_error:=os.open(path)
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
// of the range has not arrived.
read :: proc(s:^Store,hash:Hash,offset:i64,buffer:[]u8) -> Error {
    if offset<0 {return .Invalid_Argument}
    for attempt in 0..<2 {
        error:=read_complete(s,hash,offset,buffer)
        if error!=.Missing {return error}
        error=read_partial(s,hash,offset,buffer)
        if error!=.Missing || attempt==1 {return error}
    }
    return .Missing
}

// The piece hashes of a complete blob: its kept table when that one matches
// the address and the size, otherwise hashed from the file once and kept.
blob_table :: proc(s:^Store,hash:Hash,allocator:=context.allocator) -> (pieces:[]Hash,error:Error) {
    r:=reader_open(s,hash) or_return
    defer reader_close(&r)
    make_error:runtime.Allocator_Error
    pieces,make_error=make([]Hash,piece_count(r.size),allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    if table_load(s,hash,r.size,pieces)==.None {return pieces,.None}
    address:Hash
    address,error=file_hash(r.file,r.size,nil,pieces)
    if error==.None && address!=hash {error=.Corrupt}
    if error!=.None {
        delete(pieces,allocator)
        return nil,error
    }
    table_keep(s,hash,r.size,pieces)
    return pieces,.None
}

// A complete blob held open for many range reads; its owner closes it.
Reader :: struct {
    file:^os.File,
    size:i64,
}

reader_open :: proc(s:^Store,hash:Hash) -> (r:Reader,error:Error) {
    buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    open_error:os.Error
    r.file,open_error=os.open(path)
    if open_error!=nil {return {},os_error(open_error)}
    size_error:os.Error
    r.size,size_error=os.file_size(r.file)
    if size_error!=nil {
        reader_close(&r)
        return {},os_error(size_error)
    }
    return r,.None
}

// Fills buffer with the bytes of the blob from offset.
reader_read :: proc(r:^Reader,offset:i64,buffer:[]u8) -> Error {
    if r.file==nil {return .Invalid_Argument}
    if offset<0 || offset>r.size || i64(len(buffer))>r.size-offset {return .Invalid_Argument}
    return read_exact(r.file,buffer,offset)
}

reader_close :: proc(r:^Reader) {
    if r.file!=nil {os.close(r.file)}
    r^={}
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
    removed:=os.remove(path)
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

// Renames a finished file into the blob's place; a blob already there stays
// and the file goes. A failed rename leaves the file where it was.
@(private)
blob_place :: proc(s:^Store,temp:string,hash:Hash) -> Error {
    buffer,folder_buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    name:[64]u8
    text:=hex(hash,&name)
    folder_make(join(&folder_buffer,s.root,"blobs",text[:2]) or_return) or_return
    if os.is_file(path) || os.rename(temp,path)!=nil {
        if !os.is_file(path) {return .Io}
        os.remove(temp)
    }
    return .None
}

@(private)
read_complete :: proc(s:^Store,hash:Hash,offset:i64,buffer:[]u8) -> Error {
    r:=reader_open(s,hash) or_return
    defer reader_close(&r)
    return reader_read(&r,offset,buffer)
}

// The kept table of a blob: tables/<first byte>/<address>, its size as u64
// little endian and its piece hashes, as the table of a partial blob.
@(private)
table_file :: proc(s:^Store,hash:Hash,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    name:[64]u8
    text:=hex(hash,&name)
    return join(buffer,s.root,"tables",text[:2],text)
}

// Fills pieces from the kept table; Corrupt when it does not match size and address.
@(private)
table_load :: proc(s:^Store,hash:Hash,size:i64,pieces:[]Hash) -> Error {
    buffer:[PATH_BYTES]u8
    path:=table_file(s,hash,&buffer) or_return
    file,open_error:=os.open(path)
    if open_error!=nil {return os_error(open_error)}
    defer os.close(file)
    table_size,size_error:=os.file_size(file)
    if size_error!=nil {return os_error(size_error)}
    if len(pieces)!=piece_count(size) || table_size!=TABLE_HEADER+i64(len(pieces))*size_of(Hash) {return .Corrupt}
    header:[TABLE_HEADER]u8
    read_exact(file,header[:],0) or_return
    if header!=table_header(size) {return .Corrupt}
    read_exact(file,mem.slice_to_bytes(pieces),TABLE_HEADER) or_return
    return .None if address_value(size,pieces)==hash else .Corrupt
}

// Keeps the table of a complete blob; one that cannot be written is hashed again when asked for.
@(private)
table_keep :: proc(s:^Store,hash:Hash,size:i64,pieces:[]Hash) {
    buffer,folder_buffer:[PATH_BYTES]u8
    path,error:=table_file(s,hash,&buffer)
    if error!=.None {return}
    name:[64]u8
    folder,folder_error:=join(&folder_buffer,s.root,"tables",hex(hash,&name)[:2])
    if folder_error!=.None || folder_make(folder)!=.None {return}
    header:=table_header(size)
    file_write(s.root,path,header[:],mem.slice_to_bytes(pieces))
}

@(private)
table_drop :: proc(s:^Store,hash:Hash) {
    buffer:[PATH_BYTES]u8
    if path,error:=table_file(s,hash,&buffer);error==.None {os.remove(path)}
}

@(private)
table_header :: proc "contextless" (size:i64) -> (header:[TABLE_HEADER]u8) {
    for i in 0..<TABLE_HEADER {header[i]=u8(u64(size)>>(8*uint(i)))}
    return
}
