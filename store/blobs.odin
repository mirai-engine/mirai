package store

import "base:runtime"
import "core:os"

// Complete blobs are plain files of their bytes at blobs/<first byte>/<address>,
// both in hex, and are never written in place.

put_bytes :: proc(s:^Store,data:[]u8) -> (hash:Hash,error:Error) {
    hash=address_of_bytes(data)
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
    return hash,blob_place(s,temp,hash)
}

// Puts the file at path, read once piece by piece.
put_file :: proc(s:^Store,path:string) -> (hash:Hash,error:Error) {
    source,open_error:=os.open(path)
    if open_error!=nil {return {},os_error(open_error)}
    defer os.close(source)
    size,size_error:=os.file_size(source)
    if size_error!=nil {return {},os_error(size_error)}
    temp_buffer:[PATH_BYTES]u8
    temp,file:=temp_create(s.root,&temp_buffer) or_return
    hash,error=file_hash(source,size,file,nil)
    sync_error:=os.sync(file) if error==.None else nil
    os.close(file)
    if error==.Corrupt {error=.Io}
    if error==.None && sync_error!=nil {error=.Io}
    if error!=.None || has(s,hash) {
        os.remove(temp)
        return hash if error==.None else {},error
    }
    return hash,blob_place(s,temp,hash)
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

// The piece hashes of a complete blob, checked against its address on the way.
blob_table :: proc(s:^Store,hash:Hash,allocator:=context.allocator) -> (pieces:[]Hash,error:Error) {
    buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    file,open_error:=os.open(path)
    if open_error!=nil {return nil,os_error(open_error)}
    defer os.close(file)
    size,size_error:=os.file_size(file)
    if size_error!=nil {return nil,os_error(size_error)}
    make_error:runtime.Allocator_Error
    pieces,make_error=make([]Hash,piece_count(size),allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    address:Hash
    address,error=file_hash(file,size,nil,pieces)
    if error==.None && address!=hash {error=.Corrupt}
    if error!=.None {
        delete(pieces,allocator)
        return nil,error
    }
    return pieces,.None
}

// Corrupt when the file of a complete blob no longer has the bytes of its address.
verify :: proc(s:^Store,hash:Hash) -> Error {
    buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    address,_,error:=address_of_file(path)
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

// Renames a finished file of tmp into the blob's place; a blob already there stays.
@(private)
blob_place :: proc(s:^Store,temp:string,hash:Hash) -> Error {
    buffer,folder_buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&buffer) or_return
    name:[64]u8
    text:=hex(hash,&name)
    folder_make(join(&folder_buffer,s.root,"blobs",text[:2]) or_return) or_return
    if os.is_file(path) || os.rename(temp,path)!=nil {
        os.remove(temp)
        return .None if os.is_file(path) else .Io
    }
    return .None
}

@(private)
read_complete :: proc(s:^Store,hash:Hash,offset:i64,buffer:[]u8) -> Error {
    path_buffer:[PATH_BYTES]u8
    path:=blob_file(s,hash,&path_buffer) or_return
    file,open_error:=os.open(path)
    if open_error!=nil {return os_error(open_error)}
    defer os.close(file)
    size,size_error:=os.file_size(file)
    if size_error!=nil {return os_error(size_error)}
    if offset>size || i64(len(buffer))>size-offset {return .Invalid_Argument}
    return read_exact(file,buffer,offset)
}
