package compressor

import "base:intrinsics"

// Even nibbles: bytes 0-3 of the zero counts, odd nibbles: bytes 4-6, last: carry.
@(private="file", rodata)
UNARY_TABLE := [256]u32{
    0x80000000,0x00000007,0x10000006,0x00000006,0x20000005,0x00000105,0x10000005,0x00000005,
    0x30000004,0x00000204,0x10000104,0x00000104,0x20000004,0x00010004,0x10000004,0x00000004,
    0x40000003,0x00000303,0x10000203,0x00000203,0x20000103,0x00010103,0x10000103,0x00000103,
    0x30000003,0x00020003,0x10010003,0x00010003,0x20000003,0x01000003,0x10000003,0x00000003,
    0x50000002,0x00000402,0x10000302,0x00000302,0x20000202,0x00010202,0x10000202,0x00000202,
    0x30000102,0x00020102,0x10010102,0x00010102,0x20000102,0x01000102,0x10000102,0x00000102,
    0x40000002,0x00030002,0x10020002,0x00020002,0x20010002,0x01010002,0x10010002,0x00010002,
    0x30000002,0x02000002,0x11000002,0x01000002,0x20000002,0x00000012,0x10000002,0x00000002,
    0x60000001,0x00000501,0x10000401,0x00000401,0x20000301,0x00010301,0x10000301,0x00000301,
    0x30000201,0x00020201,0x10010201,0x00010201,0x20000201,0x01000201,0x10000201,0x00000201,
    0x40000101,0x00030101,0x10020101,0x00020101,0x20010101,0x01010101,0x10010101,0x00010101,
    0x30000101,0x02000101,0x11000101,0x01000101,0x20000101,0x00000111,0x10000101,0x00000101,
    0x50000001,0x00040001,0x10030001,0x00030001,0x20020001,0x01020001,0x10020001,0x00020001,
    0x30010001,0x02010001,0x11010001,0x01010001,0x20010001,0x00010011,0x10010001,0x00010001,
    0x40000001,0x03000001,0x12000001,0x02000001,0x21000001,0x01000011,0x11000001,0x01000001,
    0x30000001,0x00000021,0x10000011,0x00000011,0x20000001,0x00001001,0x10000001,0x00000001,
    0x70000000,0x00000600,0x10000500,0x00000500,0x20000400,0x00010400,0x10000400,0x00000400,
    0x30000300,0x00020300,0x10010300,0x00010300,0x20000300,0x01000300,0x10000300,0x00000300,
    0x40000200,0x00030200,0x10020200,0x00020200,0x20010200,0x01010200,0x10010200,0x00010200,
    0x30000200,0x02000200,0x11000200,0x01000200,0x20000200,0x00000210,0x10000200,0x00000200,
    0x50000100,0x00040100,0x10030100,0x00030100,0x20020100,0x01020100,0x10020100,0x00020100,
    0x30010100,0x02010100,0x11010100,0x01010100,0x20010100,0x00010110,0x10010100,0x00010100,
    0x40000100,0x03000100,0x12000100,0x02000100,0x21000100,0x01000110,0x11000100,0x01000100,
    0x30000100,0x00000120,0x10000110,0x00000110,0x20000100,0x00001100,0x10000100,0x00000100,
    0x60000000,0x00050000,0x10040000,0x00040000,0x20030000,0x01030000,0x10030000,0x00030000,
    0x30020000,0x02020000,0x11020000,0x01020000,0x20020000,0x00020010,0x10020000,0x00020000,
    0x40010000,0x03010000,0x12010000,0x02010000,0x21010000,0x01010010,0x11010000,0x01010000,
    0x30010000,0x00010020,0x10010010,0x00010010,0x20010000,0x00011000,0x10010000,0x00010000,
    0x50000000,0x04000000,0x13000000,0x03000000,0x22000000,0x02000010,0x12000000,0x02000000,
    0x31000000,0x01000020,0x11000010,0x01000010,0x21000000,0x01001000,0x11000000,0x01000000,
    0x40000000,0x00000030,0x10000020,0x00000020,0x20000010,0x00001010,0x10000010,0x00000010,
    0x30000000,0x00002000,0x10001000,0x00001000,0x20000000,0x00100000,0x10000000,0x00000000,
}

// Decodes count unary codes (zeros before each one bit). Writes up to 7 entries
// past the end. Returns count, or -1.
@(private)
decode_unary_block :: proc "contextless" (
    unary:[^]u8,count:int,br:^Block_Bits,
) -> int #no_bounds_check {
    if count<=0 {return count}
    ptr,end:=br.ptr,br.end
    pos:=br.pos_in_byte
    out:=0
    if ptr_diff(end,ptr)<=0 {return -1}
    val:=ptr[0]&u8(0xff>>pos)
    ptr=ptr[1:]
    carry:=u32(0)-pos
    for {
        if val!=0 {
            tab:=UNARY_TABLE[val]
            store32(unary[out:],(tab&0x0f0f0f0f)+carry)
            store32(unary[out+4:],(tab>>4)&0x0f0f0f0f)
            out+=int(intrinsics.count_ones(val))
            if out>=count {break}
            carry=tab>>28
        } else {
            carry+=8
        }
        if ptr_diff(end,ptr)<=0 {return -1}
        val=ptr[0]
        ptr=ptr[1:]
    }
    for out>count {
        val&=val-1
        out-=1
    }
    if val&1==0 {
        ptr=ptr[-1:]
        pos=8-u32(intrinsics.count_trailing_zeros(val))
    } else {
        pos=0
    }
    br.ptr=ptr
    br.pos_in_byte=pos
    return count
}

// Adds rice_k low bits under each of count unary codes. codes needs 8 bytes of
// padding past the end. Returns count, or -1.
@(private)
decode_rice_bottom_block :: proc "contextless" (
    codes:[^]u8,count:int,rice_k:int,br:^Block_Bits,
) -> int #no_bounds_check {
    if rice_k<0 || rice_k>3 {return -1}
    if rice_k==0 {return count}
    ptr,end:=br.ptr,br.end
    pos:=br.pos_in_byte
    uni_bits:=count*rice_k
    uni_bytes:=(int(pos)+uni_bits+7)>>3
    if uni_bytes>ptr_diff(end,ptr) {return -1}
    tail_count:=min(uni_bytes,4)
    read:=ptr
    mark:=ptr[uni_bytes-tail_count:]
    out:=0
    saved:=load64(codes[count:])
    tail:[8]u8
    for i in 0..<tail_count {tail[i]=mark[i]}
    tail_ptr:=([^]u8)(&tail[0])
    switch rice_k {
    case 1:
        shift:=24-pos
        for {
            if uintptr(read)>=uintptr(mark) {
                read=tail_ptr[ptr_diff(read,mark):]
                mark=tail_ptr[4:]
            }
            x:=u64((load32be(read)>>shift)&0xff)
            read=read[1:]
            x=(x~(x<<28))&0x0000000f0000000f
            x=(x~(x<<14))&0x0003000300030003
            x=(x~(x<<7))&0x0101010101010101
            x=intrinsics.byte_swap(x)
            store64(codes[out:],(load64(codes[out:])<<1)+x)
            out+=8
            if out>=count {break}
        }
    case 2:
        shift:=16-pos
        for {
            if uintptr(read)>=uintptr(mark) {
                read=tail_ptr[ptr_diff(read,mark):]
                mark=tail_ptr[4:]
            }
            x:=u64((load32be(read)>>shift)&0xffff)
            read=read[2:]
            x=(x~(x<<24))&0x000000ff000000ff
            x=(x~(x<<12))&0x000f000f000f000f
            x=(x~(x<<6))&0x0303030303030303
            x=intrinsics.byte_swap(x)
            store64(codes[out:],(load64(codes[out:])<<2)+x)
            out+=8
            if out>=count {break}
        }
    case 3:
        shift:=8-pos
        for {
            if uintptr(read)>=uintptr(mark) {
                read=tail_ptr[ptr_diff(read,mark):]
                mark=tail_ptr[4:]
            }
            x:=u64((load32be(read)>>shift)&0xffffff)
            read=read[3:]
            x=(x~(x<<20))&0x00000fff00000fff
            x=(x~(x<<10))&0x003f003f003f003f
            x=(x~(x<<5))&0x0707070707070707
            x=intrinsics.byte_swap(x)
            store64(codes[out:],(load64(codes[out:])<<3)+x)
            out+=8
            if out>=count {break}
        }
    }
    store64(codes[count:],saved)
    total:=uni_bits+int(pos)
    br.ptr=ptr[total>>3:]
    br.pos_in_byte=u32(total&7)
    return count
}

// Number of Exp-Golomb codes of an alphabet shape of num_syms symbols.
@(private)
decode_alphabet_shape_num_eg :: #force_inline proc "contextless" (num_syms:int,b:^Bits) -> int {
    if num_syms==256 {return 0}
    bound:=min(num_syms,257-num_syms)*2
    nbits:=32-int(intrinsics.count_leading_zeros(u32(bound-1)))
    large:=(1<<uint(nbits))-bound
    peek:=int(bits_peek(b,nbits))
    if peek>>1<large {
        bits_use(b,nbits-1)
        return peek>>1
    }
    bits_use(b,nbits)
    return peek-large
}

@(private="file")
shape_zero_run :: #force_inline proc "contextless" (prefix:u32,b:^Bits) -> u32 {
    if prefix>7 {return 511}
    extra:=int(prefix)+1
    code:=(u32(1)<<uint(extra))+u32(bits_get(b,extra))
    return code-2+1
}

@(private="file")
shape_nonzero_run :: #force_inline proc "contextless" (prefix:u32,b:^Bits) -> u32 {
    if prefix>8 {return 511}
    code:=(u32(1)<<uint(prefix))+u32(bits_get0(b,int(prefix)))
    return code
}

// Fills run_lens with (first symbol, length) pairs of the nonzero runs.
// run_prefix needs 8 zeroed bytes past its end. Returns the pair count, or -1.
@(private)
decode_alphabet_shape_runlens :: proc "contextless" (
    run_lens:^[128*2+8+1]u16,num_nonzero:u32,num_eg:u32,run_prefix:[^]u8,vb:^Bits,
) -> int {
    run_lens:=view(run_lens)
    pairs:=int(num_eg>>1)
    b:=vb^
    prefix:=run_prefix
    cur:=u32(0)
    if num_eg&1!=0 {
        bits_refill_safe(&b)
        cur=u32(u16(shape_zero_run(u32(prefix[0]),&b)))
        prefix=prefix[1:]
    }
    for pair in 0..<pairs {
        bits_refill_safe(&b)
        run_lens[pair*2+1]=u16(shape_nonzero_run(u32(prefix[0]),&b))
        run_lens[pair*2+2]=u16(shape_zero_run(u32(prefix[1]),&b))
        prefix=prefix[2:]
    }
    total:=u32(0)
    for pair in 0..<pairs {
        nz:=u32(run_lens[pair*2+1])
        z:=u32(run_lens[pair*2+2])
        run_lens[pair*2]=u16(cur)
        cur+=nz+z
        total+=nz
    }
    if cur>=256 || total>=num_nonzero {return -1}
    final:=num_nonzero-total
    if cur+final>256 {return -1}
    run_lens[pairs*2]=u16(cur)
    run_lens[pairs*2+1]=u16(final)
    vb^=b
    return pairs+1
}
