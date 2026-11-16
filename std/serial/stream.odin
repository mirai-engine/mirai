package serial

import "base:intrinsics"
import "base:runtime"
import "core:mem"

// Byte streams, little endian. A Writer grows through its allocator or is
// fixed over a buffer of the caller; bytes that do not fit are dropped and
// counted in overflow. A Reader never reads out of bounds: the first read
// that does not fit sets failed, and every read after it returns zero.

#assert(ODIN_ENDIAN==.Little)

WRITER_ALIGNMENT :: 64

Writer :: struct {
    data:[]u8, // capacity
    count:int,
    overflow:int,
    allocator:runtime.Allocator, // without a procedure: fixed over data
}

writer_init :: proc(w:^Writer,capacity:=0,allocator:=context.allocator) {
    w^={allocator=allocator}
    if capacity>0 {w.data,_=mem.alloc_bytes_non_zeroed(capacity,WRITER_ALIGNMENT,allocator)}
}
writer_init_fixed :: proc(w:^Writer,buffer:[]u8) {w^={data=buffer}}
writer_destroy :: proc(w:^Writer) {
    if w.allocator.procedure!=nil {mem.free_bytes(w.data,w.allocator)}
    w^={}
}
writer_reset :: proc(w:^Writer) {w.count,w.overflow=0,0}
writer_bytes :: #force_inline proc(w:^Writer) -> []u8 {return w.data[:w.count]}
// The bytes written, now owned by the caller; the writer is left empty.
writer_take :: proc(w:^Writer) -> []u8 {
    out:=w.data[:w.count]
    w.data,w.count=nil,0
    return out
}

// size more bytes at the end, not initialized.
writer_grow :: proc(w:^Writer,size:int) -> (out:[]u8,ok:bool) {
    if size<0 {return nil,false}
    if size>len(w.data)-w.count {
        if w.allocator.procedure==nil || size>max(int)/2-w.count {
            w.overflow+=min(size,max(int)-w.overflow)
            return nil,false
        }
        capacity:=max(len(w.data)*2,w.count+size,256)
        data,error:=mem.alloc_bytes_non_zeroed(capacity,WRITER_ALIGNMENT,w.allocator)
        if error!=nil {
            w.overflow+=min(size,max(int)-w.overflow)
            return nil,false
        }
        copy(data,w.data[:w.count])
        mem.free_bytes(w.data,w.allocator)
        w.data=data
    }
    out=w.data[w.count:][:size]
    w.count+=size
    return out,true
}

write_bytes :: proc(w:^Writer,bytes:[]u8) {
    if out,ok:=writer_grow(w,len(bytes));ok {copy(out,bytes)}
}
write_zeros :: proc(w:^Writer,size:int) {
    if out,ok:=writer_grow(w,size);ok {mem.zero_slice(out)}
}
// Zeros up to the next multiple of alignment, a power of two; any other
// alignment writes nothing.
write_align :: proc(w:^Writer,alignment:int) {
    if alignment<=0 || alignment&(alignment-1)!=0 {return}
    write_zeros(w,mem.align_forward_int(w.count,alignment)-w.count)
}
write_scalar :: #force_inline proc(w:^Writer,value:$T) where intrinsics.type_is_numeric(T) || intrinsics.type_is_boolean(T) {
    if out,ok:=writer_grow(w,size_of(T));ok {intrinsics.unaligned_store((^T)(raw_data(out)),value)}
}
write_u8 :: proc(w:^Writer,value:u8) {write_scalar(w,value)}
write_u16 :: proc(w:^Writer,value:u16) {write_scalar(w,value)}
write_u32 :: proc(w:^Writer,value:u32) {write_scalar(w,value)}
write_u64 :: proc(w:^Writer,value:u64) {write_scalar(w,value)}
write_i8 :: proc(w:^Writer,value:i8) {write_scalar(w,value)}
write_i16 :: proc(w:^Writer,value:i16) {write_scalar(w,value)}
write_i32 :: proc(w:^Writer,value:i32) {write_scalar(w,value)}
write_i64 :: proc(w:^Writer,value:i64) {write_scalar(w,value)}
write_f32 :: proc(w:^Writer,value:f32) {write_scalar(w,value)}
write_f64 :: proc(w:^Writer,value:f64) {write_scalar(w,value)}
write_bool :: proc(w:^Writer,value:bool) {write_scalar(w,u8(value))}

VARINT_BYTES :: 10

// LEB128: seven bits per byte, low bits first.
write_varint :: proc(w:^Writer,value:u64) {
    buffer:[VARINT_BYTES]u8
    count,rest:=0,value
    for rest>=0x80 {
        buffer[count]=u8(rest)|0x80
        rest>>=7
        count+=1
    }
    buffer[count]=u8(rest)
    write_bytes(w,buffer[:count+1])
}
// Zigzag: small magnitudes of either sign take few bytes.
write_svarint :: proc(w:^Writer,value:i64) {write_varint(w,u64(value<<1)~u64(value>>63))}
// Length as a varint, then the bytes.
write_string :: proc(w:^Writer,text:string) {
    write_varint(w,u64(len(text)))
    write_bytes(w,transmute([]u8)text)
}
// Overwrites bytes already written.
writer_patch :: proc(w:^Writer,offset:int,bytes:[]u8) -> bool {
    if offset<0 || offset>w.count || len(bytes)>w.count-offset {return false}
    copy(w.data[offset:],bytes)
    return true
}

Reader :: struct {
    data:[]u8,
    offset:int,
    failed:bool,
}

reader_init :: proc(data:[]u8) -> Reader {return {data=data}}
reader_remaining :: #force_inline proc(r:^Reader) -> int {return r.failed?0:len(r.data)-r.offset}
reader_seek :: proc(r:^Reader,offset:int) {
    if offset<0 || offset>len(r.data) {r.failed=true;return}
    r.offset=offset
}

// A view of the next size bytes; nil once the reader failed.
read_bytes :: proc(r:^Reader,size:int) -> []u8 {
    if r.failed || size<0 || size>len(r.data)-r.offset {r.failed=true;return nil}
    out:=r.data[r.offset:][:size]
    r.offset+=size
    return out
}
read_into :: proc(r:^Reader,out:[]u8) {
    if bytes:=read_bytes(r,len(out));!r.failed {copy(out,bytes)}
}
read_skip :: proc(r:^Reader,size:int) {read_bytes(r,size)}
// An alignment that is not a power of two fails the reader.
read_align :: proc(r:^Reader,alignment:int) {
    if alignment<=0 || alignment&(alignment-1)!=0 {
        r.failed=true
        return
    }
    read_bytes(r,mem.align_forward_int(r.offset,alignment)-r.offset)
}
read_scalar :: #force_inline proc(r:^Reader,$T:typeid) -> (value:T) where intrinsics.type_is_numeric(T) {
    if r.failed || size_of(T)>len(r.data)-r.offset {r.failed=true;return}
    value=intrinsics.unaligned_load((^T)(raw_data(r.data[r.offset:])))
    r.offset+=size_of(T)
    return
}
read_u8 :: proc(r:^Reader) -> u8 {return read_scalar(r,u8)}
read_u16 :: proc(r:^Reader) -> u16 {return read_scalar(r,u16)}
read_u32 :: proc(r:^Reader) -> u32 {return read_scalar(r,u32)}
read_u64 :: proc(r:^Reader) -> u64 {return read_scalar(r,u64)}
read_i8 :: proc(r:^Reader) -> i8 {return read_scalar(r,i8)}
read_i16 :: proc(r:^Reader) -> i16 {return read_scalar(r,i16)}
read_i32 :: proc(r:^Reader) -> i32 {return read_scalar(r,i32)}
read_i64 :: proc(r:^Reader) -> i64 {return read_scalar(r,i64)}
read_f32 :: proc(r:^Reader) -> f32 {return read_scalar(r,f32)}
read_f64 :: proc(r:^Reader) -> f64 {return read_scalar(r,f64)}
read_bool :: proc(r:^Reader) -> bool {return read_scalar(r,u8)!=0}

// Fails on a value that does not fit 64 bits or that runs past ten bytes.
read_varint :: proc(r:^Reader) -> (value:u64) {
    for shift:=uint(0);shift<70;shift+=7 {
        b:=read_u8(r)
        if r.failed {return 0}
        if shift==63 && b>1 {r.failed=true;return 0}
        value|=u64(b&0x7f)<<shift
        if b<0x80 {return value}
    }
    r.failed=true
    return 0
}
read_svarint :: proc(r:^Reader) -> i64 {
    value:=read_varint(r)
    return i64(value>>1)~-i64(value&1)
}
// A count of elements that take at least element_size bytes each of what is
// left to read: a hostile count cannot ask for more memory than the input has.
read_count :: proc(r:^Reader,element_size:int) -> int {
    value:=read_varint(r)
    if r.failed {return 0}
    if value>u64(reader_remaining(r)/max(element_size,1)) {r.failed=true;return 0}
    return int(value)
}
// A view into the data of the reader.
read_string :: proc(r:^Reader) -> string {
    size:=read_count(r,1)
    return string(read_bytes(r,size))
}
