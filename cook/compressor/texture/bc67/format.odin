package bc67

import "mirai:asset"

// The fields of a BC7 block as an encoder reads them back, and the tables it searches. The block
// format itself (modes, partitions, anchors, weights, and BC6H whole) is described in asset,
// which decodes it: the records here are built from those tables.

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

// A BC7 mode and its number.
Mode_Desc :: struct {
    mode:u8,
    using layout:asset.Bc7_Mode,
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

@(rodata)
BC7_MODES := [8]Mode_Desc{
    {0,asset.BC7_MODES[0]},{1,asset.BC7_MODES[1]},{2,asset.BC7_MODES[2]},{3,asset.BC7_MODES[3]},
    {4,asset.BC7_MODES[4]},{5,asset.BC7_MODES[5]},{6,asset.BC7_MODES[6]},{7,asset.BC7_MODES[7]},
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
partition_of :: #force_inline proc "contextless" (ns:u8,id:u32) -> (p:Partition) {
    id:=id&63
    switch ns {
    case 2:
        for subset,texel in asset.BC7_PARTITIONS_2[id] {p.subset_mask|=u32(subset)<<uint(2*texel)}
        p.anchor0=u16(asset.BC7_ANCHORS_2[id])
    case 3:
        for subset,texel in asset.BC7_PARTITIONS_3[id] {p.subset_mask|=u32(subset)<<uint(2*texel)}
        anchors:=asset.BC7_ANCHORS_3[id]
        p.anchor0,p.anchor1=u16(min(anchors[0],anchors[1])),u16(max(anchors[0],anchors[1]))
    }
    return
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
