package bc67

// Bit layouts of BC6H and BC7 blocks (Khronos Data Format 1.1, BPTC) and their
// decoders.

Optimal_Endpoint :: struct {
    err:u16,
    lo,hi:u8,
}

// A set of partition subsets an encoder searches at one effort.
Subset_Collection :: struct {
    masks:[]u32,      // bit i of masks[j] set: texel i is in subset j
    rcp_count:[]f32,  // 1/popcount(masks[j])
    subsets:[][4]u8,  // subsets each partition uses, partition id in slot 3
    num_part2:int,         // 2-subset partitions included
    num_part3:int,         // 3-subset partitions included
    num_subsets_part2:int, // subsets of the 2-subset partitions
    num_subsets_all:int,
}

// A BC7 mode, with the field names of the specification.
Mode_Desc :: struct {
    mode:u8,
    ns:u8,  // subsets
    pb:u8,  // partition bits
    rb:u8,  // rotation bits
    isb:u8, // index selection bits
    cb:u8,  // color bits
    ab:u8,  // alpha bits
    epb:u8, // endpoint p-bits
    spb:u8, // shared p-bits
    ib:u8,  // index bits per texel
    ib2:u8, // secondary index bits per texel
}

Partition :: struct {
    subset_mask:u32,   // 2 bits per texel: its subset
    anchor0,anchor1:u16, // first and second non-0 anchor texels, ascending (0: none)
}

// A BC7 block decoded so that its fields encode back to the same bits.
Block_Raw_Desc :: struct {
    mode:^Mode_Desc,
    partition_id:u8,
    rot:u8,
    ind_sel:u8,
    // [channel][index] in the channel order of the bits: rotation applied, the
    // scalar channel always in 3.
    endpoints_raw:[4][6]u8,
    inds:[2][16]u8,
}

BC6H_Mode_Desc :: struct {
    linmode:u8, // D3D numbering, 0-based
    mode:u8,    // Khronos numbering
    ns:u8,
    pb:u8,
    epb:u8,  // endpoint bits
    db:u8,   // delta bits (0: no delta coding)
    bc:u8,   // channel with one more delta bit (3: none)
    ib:u8,
}

// A BC6H block decoded so that its fields encode back to the same bits.
BC6H_Block_Raw_Desc :: struct {
    mode:^BC6H_Mode_Desc,
    partition_id:u8,
    endpoints_quant:[3][4]i32,    // [channel][index] quantized, after delta decoding
    endpoints_internal:[3][4]i32, // 17-bit signed, before the final dequantization
    inds:[16]u8,
}

@(rodata)
BC7_MODES := [8]Mode_Desc{
    // #,NS,PB,RB,ISB,CB,AB,EPB,SPB,IB,IB2
    {0,3,4,0,0,4,0,1,0,3,0},
    {1,2,6,0,0,6,0,0,1,3,0},
    {2,3,6,0,0,5,0,0,0,2,0},
    {3,2,6,0,0,7,0,1,0,2,0},
    {4,1,0,2,1,5,6,0,0,2,3},
    {5,1,0,2,0,7,8,0,0,2,2},
    {6,1,0,0,0,7,7,1,0,4,0},
    {7,2,6,0,0,5,5,1,0,2,0},
}

@(rodata)
BC6H_MODES := [14]BC6H_Mode_Desc{
    // #L,#K,NS,PB,EPB,DB,BC,IB
    {0,0,2,5,10,5,3,3},
    {1,1,2,5,7,6,3,3},
    {2,2,2,5,11,4,0,3},
    {3,6,2,5,11,4,1,3},
    {4,10,2,5,11,4,2,3},
    {5,14,2,5,9,5,3,3},
    {6,18,2,5,8,5,0,3},
    {7,22,2,5,8,5,1,3},
    {8,26,2,5,8,5,2,3},
    {9,30,2,5,6,0,3,3},
    {10,3,1,0,10,0,3,4},
    {11,7,1,0,11,9,3,4},
    {12,11,1,0,12,8,3,4},
    {13,15,1,0,16,4,3,4},
}

// Every BC6H/BC7 partition shape: 0 one subset, 1-64 two subsets, 65-128 three.
@(rodata)
BC67_PARTITIONS := [1+64+64]Partition{
    {0x00000000,0,0}, {0x50505050,15,0}, {0x40404040,15,0}, {0x54545454,15,0}, {0x54505040,15,0},
    {0x50404000,15,0}, {0x55545450,15,0}, {0x55545040,15,0}, {0x54504000,15,0}, {0x50400000,15,0},
    {0x55555450,15,0}, {0x55544000,15,0}, {0x54400000,15,0}, {0x55555440,15,0}, {0x55550000,15,0},
    {0x55555500,15,0}, {0x55000000,15,0}, {0x55150100,15,0}, {0x00004054,2,0}, {0x15010000,8,0},
    {0x00405054,2,0}, {0x00004050,2,0}, {0x15050100,8,0}, {0x05010000,8,0}, {0x40505054,15,0},
    {0x00404050,2,0}, {0x05010100,8,0}, {0x14141414,2,0}, {0x05141450,2,0}, {0x01155440,8,0},
    {0x00555500,8,0}, {0x15014054,2,0}, {0x05414150,2,0}, {0x44444444,15,0}, {0x55005500,15,0},
    {0x11441144,6,0}, {0x05055050,8,0}, {0x05500550,2,0}, {0x11114444,8,0}, {0x41144114,15,0},
    {0x44111144,15,0}, {0x15055054,2,0}, {0x01055040,8,0}, {0x05041050,2,0}, {0x05455150,2,0},
    {0x14414114,2,0}, {0x50050550,15,0}, {0x41411414,15,0}, {0x00141400,6,0}, {0x00041504,6,0},
    {0x00105410,2,0}, {0x10541000,6,0}, {0x04150400,8,0}, {0x50410514,15,0}, {0x41051450,15,0},
    {0x05415014,2,0}, {0x14054150,2,0}, {0x41050514,15,0}, {0x41505014,15,0}, {0x40011554,15,0},
    {0x54150140,15,0}, {0x50505500,15,0}, {0x00555050,2,0}, {0x15151010,2,0}, {0x54540404,15,0},
    {0xaa685050,3,15}, {0x6a5a5040,3,8}, {0x5a5a4200,8,15}, {0x5450a0a8,3,15}, {0xa5a50000,8,15},
    {0xa0a05050,3,15}, {0x5555a0a0,3,15}, {0x5a5a5050,8,15}, {0xaa550000,8,15}, {0xaa555500,8,15},
    {0xaaaa5500,6,15}, {0x90909090,6,15}, {0x94949494,6,15}, {0xa4a4a4a4,5,15}, {0xa9a59450,3,15},
    {0x2a0a4250,3,8}, {0xa5945040,3,15}, {0x0a425054,3,8}, {0xa5a5a500,8,15}, {0x55a0a0a0,3,15},
    {0xa8a85454,3,15}, {0x6a6a4040,3,8}, {0xa4a45000,6,15}, {0x1a1a0500,8,10}, {0x0050a4a4,3,5},
    {0xaaa59090,8,15}, {0x14696914,6,8}, {0x69691400,6,10}, {0xa08585a0,8,15}, {0xaa821414,5,15},
    {0x50a4a450,10,15}, {0x6a5a0200,8,15}, {0xa9a58000,8,15}, {0x5090a0a8,3,15}, {0xa8a09050,3,15},
    {0x24242424,5,10}, {0x00aa5500,6,10}, {0x24924924,8,10}, {0x24499224,8,9}, {0x50a50a50,10,15},
    {0x500aa550,6,15}, {0xaaaa4444,3,15}, {0x66660000,8,15}, {0xa5a0a5a0,5,15}, {0x50a050a0,3,15},
    {0x69286928,6,15}, {0x44aaaa44,6,15}, {0x66666600,8,15}, {0xaa444444,3,15}, {0x54a854a8,3,15},
    {0x95809580,5,15}, {0x96969600,5,15}, {0xa85454a8,5,15}, {0x80959580,8,15}, {0xaa141414,5,15},
    {0x96960000,10,15}, {0xaaaa1414,5,15}, {0xa05050a0,10,15}, {0xa0a5a5a0,8,15},
    {0x96000000,13,15}, {0x40804080,3,15}, {0xa9a8a9a8,12,15}, {0xaaaaaa44,3,15}, {0x2a4a5254,3,8},
}

// LSB-first bit reader of a 16-byte block.
@(private)
Bit_Buf :: struct {
    bitbuf:u64,    // at least 32 valid bits, LSB-aligned
    refillbuf:u64, // reservoir the refills come from
    next_refill:int, // bits until the next refill
}

@(private)
bitbuf_init :: #force_inline proc "contextless" (b:^Bit_Buf,block:^[16]u8) {
    b.bitbuf=0; b.refillbuf=0
    for i in 0..<8 {
        b.bitbuf|=u64(block[i])<<uint(i*8)
        b.refillbuf|=u64(block[i+8])<<uint(i*8)
    }
    b.next_refill=32
}

@(private)
bitbuf_get :: #force_inline proc "contextless" (b:^Bit_Buf,count:u32) -> u32 {
    val:=u32(b.bitbuf&u64((u32(1)<<count)-1))
    b.bitbuf>>=count
    b.next_refill-=int(count)
    if b.next_refill<0 {
        b.next_refill+=32
        b.bitbuf|=b.refillbuf<<uint(b.next_refill)
        b.refillbuf>>=32
    }
    return val
}

@(private)
bitbuf_get32 :: #force_inline proc "contextless" (b:^Bit_Buf) -> u32 {
    val:=u32(b.bitbuf)
    b.bitbuf=(b.bitbuf>>32)|(b.refillbuf<<uint(b.next_refill))
    b.refillbuf>>=32
    return val
}

// Inserts a zero bit at pos, shifting the higher bits up by one.
@(private)
insert_zero_bit :: #force_inline proc "contextless" (v:u64,pos:int) -> u64 {
    high_mask:=~u64(0)<<uint(pos)
    return (v&~high_mask)|((v&high_mask)<<1)
}

// The partition of a mode with ns subsets; id below 64 (16 for 3 subsets in mode 0).
partition_of :: #force_inline proc "contextless" (ns:u8,id:u32) -> ^Partition {
    FIRST :: [4]u32{0,0,1,65}
    first:=FIRST
    return &BC67_PARTITIONS[first[ns&3]+(id&63)]
}

@(private)
read_inds :: proc "contextless" (buf:^Bit_Buf,index_bits:int,anchor1,anchor2:int) -> u64 {
    total:=index_bits*16-1-int(anchor1!=0)-int(anchor2!=0)
    index:=u64(bitbuf_get(buf,u32(total&31)))
    if total>=32 {
        index|=u64(bitbuf_get32(buf))<<uint(total&31)
    }
    msb:=index_bits-1
    index=insert_zero_bit(index,msb)
    if anchor1!=0 {index=insert_zero_bit(index,anchor1*index_bits+msb)}
    if anchor2!=0 {index=insert_zero_bit(index,anchor2*index_bits+msb)}
    return index
}

@(private)
bc7_expand :: proc "contextless" (vals:[]u8,num_in_bits:int,num_endpts:int) {
    MULTS :: [4]int{(1<<11)+(1<<6),(1<<10)+(1<<4),(1<<9)+(1<<2),(1<<8)+(1<<0)}
    mults:=MULTS
    mul:=mults[(num_in_bits-5)&3]
    for i in 0..<num_endpts {
        vals[i]=u8((int(vals[i])*mul)>>8)
    }
}

@(private)
bc7_read_mode :: proc "contextless" (buf:^Bit_Buf) -> ^Mode_Desc {
    mode:=0
    for bitbuf_get(buf,1)==0 {
        mode+=1
        if mode==8 {return nil}
    }
    return &BC7_MODES[mode]
}

@(private)
bc7_decode_endpoints :: proc "contextless" (endpoints:^[4][6]u8,buf:^Bit_Buf,m:^Mode_Desc) {
    num_endpts:=int(m.ns)*2
    num_color_bits:=u32(m.cb)
    for ch in 0..<3 {
        for i in 0..<num_endpts {endpoints[ch][i]=u8(bitbuf_get(buf,num_color_bits))}
    }
    num_alpha_bits:=u32(m.ab)
    for i in 0..<num_endpts {endpoints[3][i]=u8(bitbuf_get(buf,num_alpha_bits))}
    num_pbits:=u32(m.epb+m.spb)
    if num_pbits!=0 {
        pbits:u32
        if m.spb!=0 {
            for i:=0; i<num_endpts; i+=2 {pbits|=(bitbuf_get(buf,1)*3)<<uint(i)}
        } else {
            pbits=bitbuf_get(buf,u32(num_endpts))
        }
        for i in 0..<num_endpts {
            pbit:=u8(pbits&1)
            for ch in 0..<4 {endpoints[ch][i]=(endpoints[ch][i]<<1)|pbit}
            pbits>>=1
        }
    }
    for ch in 0..<3 {bc7_expand(endpoints[ch][:],int(num_color_bits+num_pbits),num_endpts)}
    if num_alpha_bits==0 {
        for i in 0..<6 {endpoints[3][i]=255}
    } else {
        bc7_expand(endpoints[3][:],int(num_alpha_bits+num_pbits),num_endpts)
    }
}

@(private)
unpack_inds :: proc "contextless" (out:^[16]u8,inds:u64,indbits:u32) {
    mask:=u64((u32(1)<<indbits)-1)
    inds:=inds
    for i in 0..<16 {
        out[i]=u8(inds&mask)
        inds>>=indbits
    }
}

// Whether the block is well-formed.
bc7_analyze_block_raw :: proc "contextless" (desc:^Block_Raw_Desc,block:^[16]u8) -> bool {
    buf:Bit_Buf
    bitbuf_init(&buf,block)
    desc^={}
    m:=bc7_read_mode(&buf)
    desc.mode=m
    if m==nil {return false}
    desc.partition_id=u8(bitbuf_get(&buf,u32(m.pb)))
    desc.rot=u8(bitbuf_get(&buf,u32(m.rb)))
    desc.ind_sel=u8(bitbuf_get(&buf,u32(m.isb)))
    bc7_decode_endpoints(&desc.endpoints_raw,&buf,m)
    part:=partition_of(m.ns,u32(desc.partition_id))
    inds0:=read_inds(&buf,int(m.ib),int(part.anchor0),int(part.anchor1))
    unpack_inds(&desc.inds[0],inds0,u32(m.ib))
    if m.ib2!=0 {
        inds1:=read_inds(&buf,int(m.ib2),int(part.anchor0),int(part.anchor1))
        unpack_inds(&desc.inds[1],inds1,u32(m.ib2))
    }
    return true
}

@(private)
bc6h_read_mode :: proc "contextless" (buf:^Bit_Buf) -> ^BC6H_Mode_Desc {
    mode:=bitbuf_get(buf,2)
    if mode>=2 {
        mode=2+(mode-2)*8+bitbuf_get(buf,3)
        if mode>=14 {return nil}
    }
    return &BC6H_MODES[mode]
}

@(rodata)
@(private)
BITREV6 := [64]u8{
    0x00,0x20,0x10,0x30,0x08,0x28,0x18,0x38,0x04,0x24,0x14,0x34,0x0c,0x2c,0x1c,0x3c,
    0x02,0x22,0x12,0x32,0x0a,0x2a,0x1a,0x3a,0x06,0x26,0x16,0x36,0x0e,0x2e,0x1e,0x3e,
    0x01,0x21,0x11,0x31,0x09,0x29,0x19,0x39,0x05,0x25,0x15,0x35,0x0d,0x2d,0x1d,0x3d,
    0x03,0x23,0x13,0x33,0x0b,0x2b,0x1b,0x3b,0x07,0x27,0x17,0x37,0x0f,0x2f,0x1f,0x3f,
}

@(private)
bc6h_decode_endpoints :: proc "contextless" (endpoints,e:^[3][4]i32,buf:^Bit_Buf,m:^BC6H_Mode_Desc,
    is_signed:bool) {
    extra:i32
    if m.mode<=1 {extra=i32(bitbuf_get(buf,3))}
    e[0][0]=i32(bitbuf_get(buf,10))
    e[1][0]=i32(bitbuf_get(buf,10))
    e[2][0]=i32(bitbuf_get(buf,10))
    e[0][1]=i32(bitbuf_get(buf,10))
    e[1][1]=i32(bitbuf_get(buf,10))
    e[2][1]=i32(bitbuf_get(buf,10))
    if m.ns>=2 {
        e[0][2]=i32(bitbuf_get(buf,6))
        e[0][3]=i32(bitbuf_get(buf,6))
        e[1][2]=e[0][1]>>6
        e[1][3]=e[1][1]>>6
        e[2][2]=e[2][1]>>6
    }
    switch m.linmode {
    case 0:
        e[1][2]|=(extra&1)<<4
        e[1][3]|=(e[0][1]&0x20)>>1
        e[2][2]|=(extra&2)<<3
        e[2][3]=((e[1][1]&0x20)>>5)|((e[2][1]&0x20)>>4)|((e[0][2]&0x20)>>3)|((e[0][3]&0x20)>>2)|
            ((extra&4)<<2)
    case 1:
        e[1][2]|=((e[1][0]&0x200)>>5)|((extra&1)<<5)
        e[1][3]|=((extra&6)<<3)
        e[2][2]|=((e[0][0]&0x200)>>5)|((e[1][0]&0x80)>>2)
        e[2][3]=((e[0][0]&0x180)>>7)|((e[1][0]&0x100)>>6)|((e[2][0]&0x80)>>4)|
            ((e[2][0]&0x100)>>3)|((e[2][0]&0x200)>>5)
    case 2:
        e[0][0]|=(e[0][1]&0x20)<<5
        e[1][0]|=(e[1][1]&0x10)<<6
        e[2][0]|=(e[2][1]&0x10)<<6
        e[2][3]=((e[1][1]&0x20)>>5)|((e[2][1]&0x20)>>4)|((e[0][2]&0x20)>>3)|((e[0][3]&0x20)>>2)
    case 3:
        e[0][0]|=(e[0][1]&0x10)<<6
        e[1][0]|=(e[1][1]&0x20)<<5
        e[2][0]|=(e[2][1]&0x10)<<6
        e[1][2]|=(e[0][3]&0x10)
        e[1][3]|=(e[0][1]&0x20)>>1
        e[2][3]=((e[0][2]&0x10)>>4)|((e[2][1]&0x20)>>4)|((e[0][2]&0x20)>>3)|((e[0][3]&0x20)>>2)
    case 4:
        e[0][0]|=(e[0][1]&0x10)<<6
        e[1][0]|=(e[1][1]&0x10)<<6
        e[2][0]|=(e[2][1]&0x20)<<5
        e[2][2]|=(e[0][1]&0x20)>>1
        e[2][3]=((e[1][1]&0x20)>>5)|((e[0][2]&0x30)>>3)|((e[0][3]&0x20)>>2)|(e[0][3]&0x10)
    case 5:
        e[1][2]|=(e[1][0]&0x200)>>5
        e[1][3]|=(e[0][1]&0x20)>>1
        e[2][2]|=(e[0][0]&0x200)>>5
        e[2][3]=((e[1][1]&0x20)>>5)|((e[2][1]&0x20)>>4)|((e[0][2]&0x20)>>3)|((e[0][3]&0x20)>>2)|
            ((e[2][0]&0x200)>>5)
    case 6:
        e[1][2]|=(e[1][0]&0x200)>>5
        e[1][3]|=(e[0][0]&0x100)>>4
        e[2][2]|=(e[0][0]&0x200)>>5
        e[2][3]=((e[1][1]&0x20)>>5)|((e[2][1]&0x20)>>4)|((e[1][0]&0x100)>>6)|((e[2][0]&0x300)>>5)
    case 7:
        e[1][2]|=((e[1][0]&0x200)>>5)|((e[1][0]&0x100)>>3)
        e[1][3]|=((e[0][1]&0x20)>>1)|((e[2][0]&0x100)>>3)
        e[2][2]|=(e[0][0]&0x200)>>5
        e[2][3]=((e[0][0]&0x100)>>8)|((e[2][1]&0x20)>>4)|((e[0][2]&0x20)>>3)|((e[0][3]&0x20)>>2)|
            ((e[2][0]&0x200)>>5)
    case 8:
        e[1][2]|=(e[1][0]&0x200)>>5
        e[1][3]|=(e[0][1]&0x20)>>1
        e[2][2]|=((e[0][0]&0x200)>>5)|((e[1][0]&0x100)>>3)
        e[2][3]=((e[1][1]&0x20)>>5)|((e[0][0]&0x100)>>7)|((e[0][2]&0x20)>>3)|((e[0][3]&0x20)>>2)|
            ((e[2][0]&0x200)>>5)|((e[2][0]&0x100)>>3)
    case 9:
        e[1][2]|=((e[1][0]&0x200)>>5)|((e[1][0]&0x40)>>1)
        e[1][3]|=((e[0][0]&0x40)>>2)|((e[2][0]&0x40)>>1)
        e[2][2]|=((e[0][0]&0x200)>>5)|((e[1][0]&0x80)>>2)
        e[2][3]=((e[0][0]&0x180)>>7)|((e[1][0]&0x100)>>6)|((e[2][0]&0x80)>>4)|
            ((e[2][0]&0x100)>>3)|((e[2][0]&0x200)>>5)
    case 10:
    case 11,12,13:
        // The top 6 bits of R_1/G_1/B_1, reversed, extend R_0/G_0/B_0; the modes
        // where they belong to R_1/G_1/B_1 ignore them below.
        e[0][0]|=i32(BITREV6[(e[0][1]>>4)&63])<<10
        e[1][0]|=i32(BITREV6[(e[1][1]>>4)&63])<<10
        e[2][0]|=i32(BITREV6[(e[2][1]>>4)&63])<<10
    }
    num_ep:=int(m.ns)*2
    if m.db!=0 {
        for chan in 0..<3 {
            delta_bits:=i32(m.db)+i32(chan==int(m.bc))
            sign_bit:=i32(1)<<uint(delta_bits-1)
            value_bits:=sign_bit-1
            for i in 1..<num_ep {
                delta:=(e[chan][i]&value_bits)-(e[chan][i]&sign_bit)
                e[chan][i]=e[chan][0]+delta
            }
        }
    }
    epb:=i32(m.epb)
    if !is_signed {
        zext_mask:=(i32(1)<<uint(epb))-1
        for chan in 0..<3 {
            for i in 0..<num_ep {
                x:=e[chan][i]&zext_mask
                e[chan][i]=x
                deq:i32
                if epb>=16 {deq=x
                } else if x==0 {deq=0
                } else if x==zext_mask {deq=0xffff
                } else {deq=((x<<16)+0x8000)>>uint(epb)}
                endpoints[chan][i]=deq
            }
        }
    } else {
        sign_bit:=i32(1)<<uint(epb-1)
        value_bits:=sign_bit-1
        for chan in 0..<3 {
            for i in 0..<num_ep {
                x:=(e[chan][i]&value_bits)-(e[chan][i]&sign_bit)
                e[chan][i]=x
                deq:i32
                if epb>=16 {
                    deq=x
                } else {
                    xsign:=x>>31
                    xabs:=(x~xsign)-xsign
                    if xabs==0 {deq=0
                    } else if xabs>=value_bits {deq=0x7fff
                    } else {deq=((xabs<<15)+0x4000)>>uint(epb-1)}
                    deq=(deq~xsign)-xsign
                }
                endpoints[chan][i]=deq
            }
        }
    }
}

// Whether the block is well-formed.
bc6h_analyze_block_raw :: proc "contextless" (desc:^BC6H_Block_Raw_Desc,is_signed:bool,
    block:^[16]u8) -> bool {
    buf:Bit_Buf
    bitbuf_init(&buf,block)
    desc^={}
    m:=bc6h_read_mode(&buf)
    desc.mode=m
    if m==nil {return false}
    bc6h_decode_endpoints(&desc.endpoints_internal,&desc.endpoints_quant,&buf,m,is_signed)
    desc.partition_id=u8(bitbuf_get(&buf,u32(m.pb)))
    part:=partition_of(m.ns,u32(desc.partition_id))
    inds:=read_inds(&buf,int(m.ib),int(part.anchor0),int(part.anchor1))
    unpack_inds(&desc.inds,inds,u32(m.ib))
    return true
}
