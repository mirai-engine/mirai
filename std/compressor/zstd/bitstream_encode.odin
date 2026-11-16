package zstd

// Writes forward; the reader goes backward. The register is 64 bits on every supported platform.

Bit_CStream :: struct {
    bit_container:u64,
    bit_pos:u32,
    start_ptr,ptr,end_ptr:[^]u8,
}

@(rodata,private="file") BIT_Encode_Mask:=[32]u32{
    0,1,3,7,0xF,0x1F,
    0x3F,0x7F,0xFF,0x1FF,0x3FF,0x7FF,
    0xFFF,0x1FFF,0x3FFF,0x7FFF,0xFFFF,0x1FFFF,
    0x3FFFF,0x7FFFF,0xFFFFF,0x1FFFFF,0x3FFFFF,0x7FFFFF,
    0xFFFFFF,0x1FFFFFF,0x3FFFFFF,0x7FFFFFF,0xFFFFFFF,0x1FFFFFFF,
    0x3FFFFFFF,0x7FFFFFFF,
}

bit_init_cstream :: proc "contextless" (bit_c:^Bit_CStream,start_ptr:[^]u8,dst_capacity:int) -> (size:int,err:Error) {
    bit_c.bit_container=0
    bit_c.bit_pos=0
    bit_c.start_ptr=start_ptr
    bit_c.ptr=start_ptr
    bit_c.end_ptr=padd(start_ptr,dst_capacity-size_of(u64))
    if dst_capacity<=size_of(u64) {return 0,.Dst_Size_Too_Small}
    return 0,.None
}

// At most 31 bits, and the register must have room for them.
bit_add_bits :: #force_inline proc "contextless" (bit_c:^Bit_CStream,value:u64,nb_bits:u32) #no_bounds_check {
    bit_c.bit_container|=(value&u64(BIT_Encode_Mask[nb_bits]))<<bit_c.bit_pos
    bit_c.bit_pos+=nb_bits
}

// All the bits of value above nb_bits must be 0.
bit_add_bits_fast :: #force_inline proc "contextless" (bit_c:^Bit_CStream,value:u64,nb_bits:u32) {
    bit_c.bit_container|=value<<bit_c.bit_pos
    bit_c.bit_pos+=nb_bits
}

// Does not check the end of the buffer.
bit_flush_bits_fast :: #force_inline proc "contextless" (bit_c:^Bit_CStream) {
    nb_bytes:=bit_c.bit_pos>>3
    write64(bit_c.ptr,bit_c.bit_container)
    bit_c.ptr=padd(bit_c.ptr,int(nb_bytes))
    bit_c.bit_pos&=7
    bit_c.bit_container>>=nb_bytes*8
}

// Stops at the end of the buffer; bit_close_cstream reveals the overflow.
bit_flush_bits :: #force_inline proc "contextless" (bit_c:^Bit_CStream) {
    nb_bytes:=bit_c.bit_pos>>3
    write64(bit_c.ptr,bit_c.bit_container)
    bit_c.ptr=padd(bit_c.ptr,int(nb_bytes))
    if uintptr(bit_c.ptr)>uintptr(bit_c.end_ptr) {bit_c.ptr=bit_c.end_ptr}
    bit_c.bit_pos&=7
    bit_c.bit_container>>=nb_bytes*8
}

// The size of the stream in bytes, 0 if it did not fit.
bit_close_cstream :: proc "contextless" (bit_c:^Bit_CStream) -> int {
    bit_add_bits_fast(bit_c,1,1)
    bit_flush_bits(bit_c)
    if uintptr(bit_c.ptr)>=uintptr(bit_c.end_ptr) {return 0}
    return pdiff(bit_c.ptr,bit_c.start_ptr)+(bit_c.bit_pos>0 ? 1 : 0)
}
