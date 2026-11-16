package zstd

// A bit stream read backwards from its last byte, whose highest set bit marks the end.

Bit_DStream :: struct {
    bit_container:u64,
    bits_consumed:u32,
    ptr,start,limit_ptr:[^]u8,
}

Bit_DStream_Status :: enum u32 {Unfinished,End_Of_Buffer,Completed,Overflow}

@(rodata,private="file") Bit_Zero_Filled:u64

// The size of the stream must be exact.
bit_init_dstream :: proc "contextless" (bit_d:^Bit_DStream,src:[^]u8,src_size:int) -> Error #no_bounds_check {
    if src_size<1 {bit_d^={};return .Src_Size_Wrong}
    bit_d.start=src
    bit_d.limit_ptr=padd(bit_d.start,8)
    if src_size>=8 {
        bit_d.ptr=padd(src,src_size-8)
        bit_d.bit_container=read64(bit_d.ptr)
        last_byte:=src[src_size-1]
        bit_d.bits_consumed=last_byte!=0 ? 8-highbit32(u32(last_byte)) : 0
        if last_byte==0 {return .Generic}
    } else {
        bit_d.ptr=bit_d.start
        bit_d.bit_container=u64(src[0])
        switch src_size {
        case 7:
            bit_d.bit_container+=u64(src[6])<<48
            fallthrough
        case 6:
            bit_d.bit_container+=u64(src[5])<<40
            fallthrough
        case 5:
            bit_d.bit_container+=u64(src[4])<<32
            fallthrough
        case 4:
            bit_d.bit_container+=u64(src[3])<<24
            fallthrough
        case 3:
            bit_d.bit_container+=u64(src[2])<<16
            fallthrough
        case 2:
            bit_d.bit_container+=u64(src[1])<<8
        }
        last_byte:=src[src_size-1]
        bit_d.bits_consumed=last_byte!=0 ? 8-highbit32(u32(last_byte)) : 0
        if last_byte==0 {return .Corruption_Detected}
        bit_d.bits_consumed+=u32(8-src_size)*8
    }
    return .None
}

bit_look_bits :: #force_inline proc "contextless" (bit_d:^Bit_DStream,nb_bits:u32) -> u64 {
    start:=64-bit_d.bits_consumed-nb_bits
    return (bit_d.bit_container>>(start&63))&((u64(1)<<(nb_bits&63))-1)
}

// nb_bits is at least 1.
bit_look_bits_fast :: #force_inline proc "contextless" (bit_d:^Bit_DStream,nb_bits:u32) -> u64 {
    return (bit_d.bit_container<<(bit_d.bits_consumed&63))>>((64-nb_bits)&63)
}

bit_skip_bits :: #force_inline proc "contextless" (bit_d:^Bit_DStream,nb_bits:u32) {
    bit_d.bits_consumed+=nb_bits
}

bit_read_bits :: #force_inline proc "contextless" (bit_d:^Bit_DStream,nb_bits:u32) -> u64 {
    value:=bit_look_bits(bit_d,nb_bits)
    bit_skip_bits(bit_d,nb_bits)
    return value
}

// nb_bits is at least 1.
bit_read_bits_fast :: #force_inline proc "contextless" (bit_d:^Bit_DStream,nb_bits:u32) -> u64 {
    value:=bit_look_bits_fast(bit_d,nb_bits)
    bit_skip_bits(bit_d,nb_bits)
    return value
}

bit_reload_dstream_internal :: #force_inline proc "contextless" (bit_d:^Bit_DStream) -> Bit_DStream_Status {
    bit_d.ptr=padd(bit_d.ptr,-int(bit_d.bits_consumed>>3))
    bit_d.bits_consumed&=7
    bit_d.bit_container=read64(bit_d.ptr)
    return .Unfinished
}

// bits_consumed is at most 64. Overflow means the slow reload has to go on.
bit_reload_dstream_fast :: #force_inline proc "contextless" (bit_d:^Bit_DStream) -> Bit_DStream_Status {
    if uintptr(bit_d.ptr)<uintptr(bit_d.limit_ptr) {return .Overflow}
    return bit_reload_dstream_internal(bit_d)
}

// Never reads outside the buffer; once overflowed, the stream stays so.
bit_reload_dstream :: #force_inline proc "contextless" (bit_d:^Bit_DStream) -> Bit_DStream_Status {
    if bit_d.bits_consumed>64 {
        bit_d.ptr=([^]u8)(&Bit_Zero_Filled)
        return .Overflow
    }
    if uintptr(bit_d.ptr)>=uintptr(bit_d.limit_ptr) {return bit_reload_dstream_internal(bit_d)}
    if bit_d.ptr==bit_d.start {
        if bit_d.bits_consumed<64 {return .End_Of_Buffer}
        return .Completed
    }
    nb_bytes:=bit_d.bits_consumed>>3
    result:=Bit_DStream_Status.Unfinished
    if uintptr(padd(bit_d.ptr,-int(nb_bytes)))<uintptr(bit_d.start) {
        nb_bytes=u32(pdiff(bit_d.ptr,bit_d.start))
        result=.End_Of_Buffer
    }
    bit_d.ptr=padd(bit_d.ptr,-int(nb_bytes))
    bit_d.bits_consumed-=nb_bytes*8
    bit_d.bit_container=read64(bit_d.ptr)
    return result
}

// Whether every bit was consumed, exactly.
bit_end_of_dstream :: #force_inline proc "contextless" (d_stream:^Bit_DStream) -> bool {
    return d_stream.ptr==d_stream.start && d_stream.bits_consumed==64
}
