package compressor

import "base:intrinsics"
import "core:sys/info"

@(private="file") HUFF_TABLE_SIZE :: 1<<HUFF_CODELEN_LIMIT
@(private="file") HUFF_TABLE_MASK :: HUFF_TABLE_SIZE-1
// Symbol lists by code length: 2^len places up to 7, 256 above.
@(private="file") HUFF_SYMS_SIZE :: 256+256*(HUFF_CODELEN_LIMIT-7)

// Entries are len | sym<<8, indexed by the next HUFF_CODELEN_LIMIT bits of an
// LSB-first stream.
@(private)
Huff_Table :: [HUFF_TABLE_SIZE]u16

@(private="file")
Huff_State :: struct {
    out:[2][^]u8,
    out_end:[2][^]u8,
    strm0_end:[2][^]u8,
    bitp:[6][^]u8,
    bits:[6]u32,
    bitc:[6]u32,
}

@(private) unfold_negatives :: #force_inline proc "contextless" (
    i:u32,
) -> i32 {return i32(i>>1)~(-i32(i&1))}

// Exp-Golomb run length with one extra bit; 511 when illegal.
@(private="file")
packhuff8_runlen :: #force_inline proc "contextless" (b:^Bits) -> u32 {
    if bits_peek(b,8)==0 {return 511}
    lz:=bits_clz(b)
    return u32(bits_get(b,lz*2+2))-1
}

@(private="file")
decode_hufflens :: proc "contextless" (
    vb:^Bits,syms:[^]u8,last:^[HUFF_CODELEN_LIMIT+1]u32,
) -> int #no_bounds_check {
    b:=vb^
    got:=-1
    if bits_get1(&b)!=0 {
        rice_bits:=int(bits_get(&b,2))
        max_prefix:=uint(((HUFF_CODELEN_LIMIT-1)*2)>>uint(rice_bits))
        min_legal:=u64(1)<<(63-max_prefix)
        bias:=rice_bits+1
        prev4:=8*4
        i:=u32(0)
        bits_refill_safe(&b)
        got=0
        if bits_get1(&b)==0 {i=packhuff8_runlen(&b)}
        for i<256 {
            bits_refill_safe(&b)
            nz:=packhuff8_runlen(&b)
            if i+nz>256 {return -1}
            bits_refill_safe(&b)
            got+=int(nz)
            for {
                if b.bits<min_legal {return -1}
                lz:=u32(bits_clz(&b))
                tail:=u32(bits_get(&b,int(lz)+bias))
                code:=((lz-1)<<uint(rice_bits))+tail
                cur:=int(unfold_negatives(code))+hufflen_pred_get(prev4)
                if cur<1 || cur>HUFF_CODELEN_LIMIT {return -1}
                prev4=hufflen_pred_update(prev4,cur)
                count:=last[cur]
                bits_refill_safe(&b)
                syms[count]=u8(i)
                last[cur]=count+1
                i+=1
                nz-=1
                if nz==0 {break}
            }
            if i>=256 {break}
            i+=packhuff8_runlen(&b)
        }
        if i!=256 || got<2 {got=-1}
    } else {
        got=int(bits_get(&b,8))
        if got==0 {return -1}
        if got==1 {
            syms[0]=u8(bits_get(&b,8))
        } else {
            log2:=int(bits_get(&b,3))
            if log2>4 {return -1}
            for _ in 0..<got {
                bits_refill_safe(&b)
                sym:=u8(bits_get(&b,8))
                cur:=int(bits_get0(&b,log2))+1
                if cur>HUFF_CODELEN_LIMIT {return -1}
                count:=last[cur]
                syms[count]=sym
                last[cur]=count+1
            }
        }
    }
    vb^=b
    return got
}

@(private="file")
decode_hufflens2 :: proc "contextless" (
    vb:^Bits,syms:[^]u8,last:^[HUFF_CODELEN_LIMIT+1]u32,
) -> int #no_bounds_check {
    b:=vb^
    rice_bits:=int(bits_get(&b,2))
    got:=int(bits_get(&b,8))+1
    if got<2 {return -1}
    num_eg:=decode_alphabet_shape_num_eg(got,&b)
    bb:=bits_to_block(&b)
    num_unary:=got+num_eg
    unary:[256+255+16]u8 = ---
    up:=([^]u8)(&unary[0])
    if decode_unary_block(up,num_unary,&bb)!=num_unary {return -1}
    store64(up[num_unary:],0)
    store64(up[num_unary+8:],0)
    if decode_rice_bottom_block(up,got,rice_bits,&bb)!=got {return -1}
    bits_from_block(&b,&bb)
    vb^=b
    // Code length i is (prev4>>2)+delta[i], prev4 the running sum of the
    // deltas from 8*4+2: a prefix sum, 16 lanes at a time, of length-1 so
    // that any length outside 1..11 shows as a lane above 10.
    V :: #simd[16]u8
    saved:=intrinsics.unaligned_load((^V)(up[got:]))
    intrinsics.unaligned_store((^V)(up[got:]),V{})
    {
        prev:=V(8*4+2-4)
        top:=V(HUFF_CODELEN_LIMIT-1)
        worst:=top
        for i:=0;i<got;i+=16 {
            vals:=intrinsics.unaligned_load((^V)(up[i:]))
            delta:=intrinsics.simd_shr(vals,V(1))~(V{}-(vals&1))
            sum:=delta+intrinsics.simd_shuffle(V{},delta,0,16,17,18,19,20,21,22,23,24,25,26,27,
                28,29,30)
            sum+=intrinsics.simd_shuffle(V{},sum,0,1,16,17,18,19,20,21,22,23,24,25,26,27,28,29)
            sum+=intrinsics.simd_shuffle(V{},sum,0,1,2,3,16,17,18,19,20,21,22,23,24,25,26,27)
            sum+=intrinsics.simd_shuffle(V{},sum,0,1,2,3,4,5,6,7,16,17,18,19,20,21,22,23)
            base:=intrinsics.simd_shuffle(prev,prev,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,
                15)
            before:=base+intrinsics.simd_shuffle(V{},sum,0,16,17,18,19,20,21,22,23,24,25,26,27,
                28,29,30)
            prev=base+sum
            cur:=intrinsics.simd_shr(before,V(2))+delta
            worst=intrinsics.simd_max(worst,cur)
            intrinsics.unaligned_store((^V)(up[i:]),cur+1)
        }
        if intrinsics.simd_reduce_and(intrinsics.simd_lanes_eq(worst,top))==0 {return -1}
    }
    intrinsics.unaligned_store((^V)(up[got:]),saved)
    run_lens:[128*2+8+1]u16 = ---
    pairs:=decode_alphabet_shape_runlens(&run_lens[0],u32(got),u32(num_eg),up[got:],vb)
    if pairs<0 {return -1}
    // The symbol at each position, then per length the positions in order.
    sym_of:[256+16]u8 = ---
    {
        IOTA :: V{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}
        li:=0
        for pair in 0..<pairs {
            sym:=u8(run_lens[pair*2])
            run:=int(run_lens[pair*2+1])
            v:=IOTA+V(sym)
            for k:=0;k<run;k+=16 {
                intrinsics.unaligned_store((^V)(&sym_of[li+k]),v)
                v+=16
            }
            li+=run
        }
    }
    // Each symbol goes to first[len] plus the count of earlier symbols of its
    // length. Four ranges of 64 positions, each with its own counts started
    // from the bit masks of the ranges before, interleave four independent
    // chains of count updates; positions past got have length 0 and write
    // into the spare tail of syms.
    masks:[HUFF_CODELEN_LIMIT+1][4]u64
    lens:[256]u8 = ---
    {
        IOTA :: V{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}
        for i:=0;i<256;i+=16 {
            v:=intrinsics.unaligned_load((^V)(up[i:]))
            v&=transmute(V)intrinsics.simd_lanes_lt(IOTA,V(u8(clamp(got-i,0,16))))
            intrinsics.unaligned_store((^V)(&lens[i]),v)
            #unroll for len in 1..=HUFF_CODELEN_LIMIT {
                m:=u64(transmute(u16)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_eq(v,
                    V(len))))
                masks[len][i>>6]|=m<<uint(i&63)
            }
        }
    }
    at:[4][HUFF_CODELEN_LIMIT+1]u32 = ---
    for w in 0..<4 {at[w][0]=HUFF_SYMS_SIZE+u32(w)*64}
    for len in 1..=HUFF_CODELEN_LIMIT {
        count:=last[len]
        #unroll for w in 0..<4 {
            at[w][len]=count
            count+=u32(intrinsics.count_ones(masks[len][w]))
        }
        last[len]=count
    }
    ranges:=(got+63)>>6
    for k in 0..<64 {
        #unroll for w in 0..<4 {
            if w<ranges {
                l:=lens[w*64+k]
                n:=at[w][l]
                syms[n]=sym_of[w*64+k]
                at[w][l]=n+1
            }
        }
    }
    return got
}

// Fills n bytes in steps of 16; writes up to 15 bytes past p[n].
@(private="file")
sloppy_fill :: #force_inline proc "contextless" (p:[^]u8,v:u8,n:u32) #no_bounds_check {
    Splat :: #simd[16]u8
    splat:=Splat(v)
    for i:=u32(0);i<n;i+=16 {intrinsics.unaligned_store((^#simd[16]u8)(p[i:]),splat)}
}

// Builds the table indexed by reversed codes: codes are assigned MSB-first in
// order of length, then of the symbol lists. The MSB-first table is a run of
// fills; reversing the 11 index bits is an 8x8 transpose of 16-bit entries
// whose rows and columns are taken in reversed order.
@(private="file")
build_table :: proc "contextless" (
    first,last:^[HUFF_CODELEN_LIMIT+1]u32,syms:[^]u8,table:^Huff_Table,
) -> bool #no_bounds_check {
    lens:[HUFF_TABLE_SIZE+16]u8 = ---
    msb:[HUFF_TABLE_SIZE+16]u8 = ---
    lp:=([^]u8)(&lens[0])
    sp:=([^]u8)(&msb[0])
    code:u32=0
    for len in u32(1)..<HUFF_CODELEN_LIMIT {
        num:=last[len]-first[len]
        if num==0 {continue}
        shift:=HUFF_CODELEN_LIMIT-len
        per:=u32(1)<<shift
        if code+(num<<shift)>HUFF_TABLE_SIZE {return false}
        sloppy_fill(lp[code:],u8(len),num<<shift)
        list:=syms[first[len]:]
        for i in 0..<num {
            sloppy_fill(sp[code:],list[i],per)
            code+=per
        }
    }
    if num:=last[HUFF_CODELEN_LIMIT]-first[HUFF_CODELEN_LIMIT];num>0 {
        if code+num>HUFF_TABLE_SIZE {return false}
        sloppy_fill(lp[code:],HUFF_CODELEN_LIMIT,num)
        intrinsics.mem_copy_non_overlapping(sp[code:],syms[first[HUFF_CODELEN_LIMIT]:],num)
        code+=num
    }
    if code!=HUFF_TABLE_SIZE {return false}
    U8x8 :: #simd[8]u8
    U16x8 :: #simd[8]u16
    E :: HUFF_TABLE_SIZE/8
    REV3 :: [8]uint{0,4,2,6,1,5,3,7}
    rev3:=REV3
    out:=([^]u8)(table)
    row :: #force_inline proc "contextless" (lp,sp:[^]u8) -> U16x8 {
        l:=intrinsics.unaligned_load((^U8x8)(lp))
        s:=intrinsics.unaligned_load((^U8x8)(sp))
        return transmute(U16x8)intrinsics.simd_shuffle(l,s,0,8,1,9,2,10,3,11,4,12,5,13,6,14,7,15)
    }
    lo :: #force_inline proc "contextless" (a,b:U16x8) -> U16x8 {
        return intrinsics.simd_shuffle(a,b,0,8,1,9,2,10,3,11)
    }
    hi :: #force_inline proc "contextless" (a,b:U16x8) -> U16x8 {
        return intrinsics.simd_shuffle(a,b,4,12,5,13,6,14,7,15)
    }
    for s:=uint(0);s<E;s+=8 {
        rs:=uint(intrinsics.reverse_bits(u32(s))>>(32-HUFF_CODELEN_LIMIT))
        r:[8]U16x8
        #unroll for i in 0..<8 {r[i]=row(lp[rs+E*rev3[i]:],sp[rs+E*rev3[i]:])}
        pair :: #force_inline proc "contextless" (r:^[8]U16x8,i,j:int) {
            a,b:=r[i],r[j]
            r[i]=lo(a,b)
            r[j]=hi(a,b)
        }
        pair(&r,0,4);pair(&r,1,5);pair(&r,2,6);pair(&r,3,7)
        pair(&r,0,2);pair(&r,1,3);pair(&r,4,6);pair(&r,5,7)
        pair(&r,0,1);pair(&r,2,3);pair(&r,4,5);pair(&r,6,7)
        #unroll for i in 0..<8 {
            intrinsics.unaligned_store((^U16x8)(out[2*(s+E*rev3[i]):]),r[i])
        }
    }
    return true
}

// Three streams per half: 0 forward from the start, 2 forward from the end of
// 0, 1 backward from the end.
@(private="file")
huff_precise_finish :: proc "contextless" (
    s:^Huff_State,table:^Huff_Table,huff6:bool,
) -> bool #no_bounds_check {
    huff6:=huff6
    for {
        in0,in1,in2:=s.bitp[0],s.bitp[1],s.bitp[2]
        bits0,bitc0:=s.bits[0],s.bitc[0]
        bits1,bitc1:=s.bits[1],s.bitc[1]
        bits2,bitc2:=s.bits[2],s.bitc[2]
        if uintptr(in0)>uintptr(in2) {return false}
        out,out_end:=s.out[0],s.out_end[0]
        if ptr_diff(in1,in2)>=4 && ptr_diff(out_end,out)>=6 {
            in1=in1[-4:]
            out_end=out_end[-5:]
            for uintptr(out)<uintptr(out_end) {
                if uintptr(in0)>uintptr(in2) || uintptr(in2)>uintptr(in1) {break}
                bits0|=load32(in0)<<(bitc0&31)
                in0=in0[(31-bitc0)>>3:]
                bitc0|=24
                bits1|=load32be(in1)<<(bitc1&31)
                in1=in1[-int((31-bitc1)>>3):]
                bitc1|=24
                bits2|=load32(in2)<<(bitc2&31)
                in2=in2[(31-bitc2)>>3:]
                bitc2|=24
                for _ in 0..<2 {
                    e:=table[bits0&HUFF_TABLE_MASK];l:=u32(e&0xff)
                    bits0>>=l&31;bitc0-=l;out[0]=u8(e>>8)
                    e=table[bits1&HUFF_TABLE_MASK];l=u32(e&0xff)
                    bits1>>=l&31;bitc1-=l;out[1]=u8(e>>8)
                    e=table[bits2&HUFF_TABLE_MASK];l=u32(e&0xff)
                    bits2>>=l&31;bitc2-=l;out[2]=u8(e>>8)
                    out=out[3:]
                }
            }
            out_end=out_end[5:]
            in1=in1[4:]
            in0=in0[-int(bitc0>>3):];bitc0&=7
            in1=in1[bitc1>>3:];bitc1&=7
            in2=in2[-int(bitc2>>3):];bitc2&=7
        }
        for uintptr(out)<uintptr(out_end) {
            if d:=ptr_diff(in2,in0);d>1 {
                bits0|=load16(in0)<<(bitc0&31)
            } else if d==1 {
                bits0|=u32(in0[0])<<(bitc0&31)
            }
            e:=table[bits0&HUFF_TABLE_MASK];l:=u32(e&0xff)
            bits0>>=l&31;bitc0-=l;out[0]=u8(e>>8);out=out[1:]
            in0=in0[(7-bitc0)>>3:]
            bitc0&=7
            if uintptr(out)>=uintptr(out_end) {break}
            if d:=ptr_diff(in1,in2);d>1 {
                bits1|=load16be(in1[-2:])<<(bitc1&31)
                bits2|=load16(in2)<<(bitc2&31)
            } else if d==1 {
                bits1|=u32(in2[0])<<(bitc1&31)
                bits2|=u32(in2[0])<<(bitc2&31)
            }
            e=table[bits1&HUFF_TABLE_MASK];l=u32(e&0xff)
            bits1>>=l&31;bitc1-=l;out[0]=u8(e>>8);out=out[1:]
            in1=in1[-int((7-bitc1)>>3):]
            bitc1&=7
            if uintptr(out)>=uintptr(out_end) {break}
            e=table[bits2&HUFF_TABLE_MASK];l=u32(e&0xff)
            bits2>>=l&31;bitc2-=l;out[0]=u8(e>>8);out=out[1:]
            in2=in2[(7-bitc2)>>3:]
            bitc2&=7
            if uintptr(in0)>uintptr(in2) || uintptr(in2)>uintptr(in1) {return false}
        }
        if out!=out_end {return false}
        if in0!=s.strm0_end[0] || in1!=in2 {return false}
        if !huff6 {break}
        huff_second_half(s)
        huff6=false
    }
    return true
}

@(private="file")
huff_second_half :: #force_inline proc "contextless" (s:^Huff_State) {
    s.out[0]=s.out[1]
    s.out_end[0]=s.out_end[1]
    s.strm0_end[0]=s.strm0_end[1]
    for i in 0..<3 {
        s.bitp[i]=s.bitp[i+3]
        s.bits[i]=s.bits[i+3]
        s.bitc[i]=s.bitc[i+3]
    }
}

@(private="file") HUFF_DECS_PER_REFILL :: 5
@(private="file") HUFF_TRIPLE :: 3*HUFF_DECS_PER_REFILL

// The bulk loops keep each stream as a byte pointer and the bits consumed of
// its first byte: a refill loads 8 bytes with a marker bit on top, and the
// marker's distance from the top after the last symbol gives the bits used.
// The word keeps one spent bit below the next code, so that the code masked
// in place is the byte offset of its table entry.
@(private="file") HUFF_MARK :: u64(1)<<63

@(private="file")
Huff_Cursor :: struct {p:[^]u8,k:uint}

@(private="file")
cursor_fwd :: #force_inline proc "contextless" (s:^Huff_State,i:int) -> Huff_Cursor {
    if s.bitc[i]==0 {return {s.bitp[i],0}}
    return {s.bitp[i][-1:],8-uint(s.bitc[i])}
}

// Backward cursors point one past their current byte.
@(private="file")
cursor_back :: #force_inline proc "contextless" (s:^Huff_State,i:int) -> Huff_Cursor {
    if s.bitc[i]==0 {return {s.bitp[i],0}}
    return {s.bitp[i][1:],8-uint(s.bitc[i])}
}

@(private="file")
store_fwd :: #force_inline proc "contextless" (s:^Huff_State,i:int,c:Huff_Cursor) #no_bounds_check {
    if c.k==0 {s.bitp[i]=c.p;s.bits[i]=0;s.bitc[i]=0;return}
    s.bitp[i]=c.p[1:];s.bits[i]=u32(c.p[0])>>c.k;s.bitc[i]=u32(8-c.k)
}

@(private="file")
store_back :: #force_inline proc "contextless" (
    s:^Huff_State,i:int,c:Huff_Cursor,
) #no_bounds_check {
    if c.k==0 {s.bitp[i]=c.p;s.bits[i]=0;s.bitc[i]=0;return}
    s.bitp[i]=c.p[-1:];s.bits[i]=u32(c.p[-1])>>c.k;s.bitc[i]=u32(8-c.k)
}

@(private="file") HUFF_INDEX_MASK :: HUFF_TABLE_MASK<<1

@(private="file") huff_load_fwd :: #force_inline proc "contextless" (
    c:Huff_Cursor,
) -> u64 {return (load64(c.p)<<1|HUFF_MARK)>>(c.k&63)}
@(private="file") huff_load_back :: #force_inline proc "contextless" (c:Huff_Cursor) -> u64 {
    return (intrinsics.byte_swap(load64(c.p[-8:]))<<1|HUFF_MARK)>>(c.k&63)
}

@(private="file")
huff_sym :: #force_inline proc "contextless" (tb:[^]u8,w:^u64,out:[^]u8) #no_bounds_check {
    e:=u16(load16(tb[w^&HUFF_INDEX_MASK:]))
    w^>>=uint(e)&63
    out[0]=u8(e>>8)
}

@(private="file")
huff_last_fwd :: #force_inline proc "contextless" (
    tb:[^]u8,w:u64,c:^Huff_Cursor,out:[^]u8,
) #no_bounds_check {
    e:=u16(load16(tb[w&HUFF_INDEX_MASK:]))
    out[0]=u8(e>>8)
    t:=uint(intrinsics.count_leading_zeros(w))+uint(e&0xff)
    c.p=c.p[t>>3:]
    c.k=t&7
}

@(private="file")
huff_last_back :: #force_inline proc "contextless" (
    tb:[^]u8,w:u64,c:^Huff_Cursor,out:[^]u8,
) #no_bounds_check {
    e:=u16(load16(tb[w&HUFF_INDEX_MASK:]))
    out[0]=u8(e>>8)
    t:=uint(intrinsics.count_leading_zeros(w))+uint(e&0xff)
    c.p=c.p[-int(t>>3):]
    c.k=t&7
}

@(private="file")
huff64 :: #force_inline proc "contextless" (
    s:^Huff_State,table:^Huff_Table,huff6:bool,
) -> bool #no_bounds_check {
    huff6:=huff6
    if huff6 {huff6_bulk(s,table)}
    tb:=([^]u8)(table)
    for {
        out,out_end:=s.out[0],s.out_end[0]
        // Runs while the streams cannot cross within one refill; the careful
        // loop takes the rest.
        if ptr_diff(out_end,out)>HUFF_TRIPLE-1 && ptr_diff(s.bitp[1],s.bitp[2])>=9 {
            out_end=out_end[-(HUFF_TRIPLE-1):]
            c0,c1,c2:=cursor_fwd(s,0),cursor_back(s,1),cursor_fwd(s,2)
            for uintptr(out)<uintptr(out_end) {
                if uintptr(c0.p)>uintptr(c2.p) || uintptr(c2.p)>uintptr(c1.p[-8:]) {break}
                w0,w1,w2:=huff_load_fwd(c0),huff_load_back(c1),huff_load_fwd(c2)
                #unroll for k in 0..<HUFF_DECS_PER_REFILL-1 {
                    huff_sym(tb,&w0,out[3*k:])
                    huff_sym(tb,&w1,out[3*k+1:])
                    huff_sym(tb,&w2,out[3*k+2:])
                }
                L :: 3*(HUFF_DECS_PER_REFILL-1)
                huff_last_fwd(tb,w0,&c0,out[L:])
                huff_last_back(tb,w1,&c1,out[L+1:])
                huff_last_fwd(tb,w2,&c2,out[L+2:])
                out=out[HUFF_TRIPLE:]
            }
            s.out[0]=out
            store_fwd(s,0,c0);store_back(s,1,c1);store_fwd(s,2,c2)
        }
        if !huff_precise_finish(s,table,false) {return false}
        if !huff6 {break}
        huff_second_half(s)
        huff6=false
    }
    return true
}

// Both halves of a 6-stream array at once, for twice the independent work
// of the 3-stream loop; leaves the state for huff64 to finish each half.
@(private="file")
huff6_bulk :: #force_inline proc "contextless" (s:^Huff_State,table:^Huff_Table) #no_bounds_check {
    oa,ob:=s.out[0],s.out[1]
    oa_end,ob_end:=s.out_end[0],s.out_end[1]
    if ptr_diff(oa_end,oa)<=HUFF_TRIPLE-1 || ptr_diff(ob_end,ob)<=HUFF_TRIPLE-1 {return}
    if ptr_diff(s.bitp[1],s.bitp[2])<9 || ptr_diff(s.bitp[4],s.bitp[5])<9 {return}
    oa_end=oa_end[-(HUFF_TRIPLE-1):]
    ob_end=ob_end[-(HUFF_TRIPLE-1):]
    tb:=([^]u8)(table)
    c0,c1,c2:=cursor_fwd(s,0),cursor_back(s,1),cursor_fwd(s,2)
    c3,c4,c5:=cursor_fwd(s,3),cursor_back(s,4),cursor_fwd(s,5)
    for uintptr(oa)<uintptr(oa_end) && uintptr(ob)<uintptr(ob_end) {
        if uintptr(c0.p)>uintptr(c2.p) || uintptr(c2.p)>uintptr(c1.p[-8:]) {break}
        if uintptr(c3.p)>uintptr(c5.p) || uintptr(c5.p)>uintptr(c4.p[-8:]) {break}
        w0,w1,w2:=huff_load_fwd(c0),huff_load_back(c1),huff_load_fwd(c2)
        w3,w4,w5:=huff_load_fwd(c3),huff_load_back(c4),huff_load_fwd(c5)
        #unroll for k in 0..<HUFF_DECS_PER_REFILL-1 {
            huff_sym(tb,&w0,oa[3*k:]);huff_sym(tb,&w3,ob[3*k:])
            huff_sym(tb,&w1,oa[3*k+1:]);huff_sym(tb,&w4,ob[3*k+1:])
            huff_sym(tb,&w2,oa[3*k+2:]);huff_sym(tb,&w5,ob[3*k+2:])
        }
        L :: 3*(HUFF_DECS_PER_REFILL-1)
        huff_last_fwd(tb,w0,&c0,oa[L:]);huff_last_fwd(tb,w3,&c3,ob[L:])
        huff_last_back(tb,w1,&c1,oa[L+1:]);huff_last_back(tb,w4,&c4,ob[L+1:])
        huff_last_fwd(tb,w2,&c2,oa[L+2:]);huff_last_fwd(tb,w5,&c5,ob[L+2:])
        oa=oa[HUFF_TRIPLE:]
        ob=ob[HUFF_TRIPLE:]
    }
    s.out[0]=oa
    s.out[1]=ob
    store_fwd(s,0,c0);store_back(s,1,c1);store_fwd(s,2,c2)
    store_fwd(s,3,c3);store_back(s,4,c4);store_fwd(s,5,c5)
}

// Decodes a Huffman array of to_len bytes. Returns comp_len, or -1.
@(private)
get_array_huff :: proc "contextless" (
    comp:[^]u8,comp_len:int,to:[^]u8,to_len:int,huff6:bool,
) -> int #no_bounds_check {
    comp_end:=comp[comp_len:]
    vb:Bits
    bits_open(&vb,comp,comp_end)
    table:Huff_Table = ---
    {
        syms:[HUFF_SYMS_SIZE+256]u8 = ---
        first,last:[HUFF_CODELEN_LIMIT+1]u32
        cur:u32=0
        for i in 1..=7 {
            first[i]=cur;last[i]=cur
            cur+=1<<uint(i)
        }
        for i in 8..=HUFF_CODELEN_LIMIT {
            first[i]=cur;last[i]=cur
            cur+=256
        }
        got:int
        if bits_get1(&vb)!=0 {
            if bits_get1(&vb)!=0 {return -1}
            got=decode_hufflens2(&vb,&syms[0],&last)
        } else {
            got=decode_hufflens(&vb,&syms[0],&last)
        }
        if got<1 {return -1}
        if got==1 {
            fill(to,syms[0],to_len)
            return ptr_diff(bits_end_ptr(&vb),comp)
        }
        if !build_table(&first,&last,&syms[0],&table) {return -1}
    }
    start:=bits_end_ptr(&vb)
    s:Huff_State = ---
    if !huff6 {
        if ptr_diff(comp_end,start)<3 {return -1}
        len1:=int(load16(start))
        start=start[2:]
        if ptr_diff(comp_end,start)<len1+2 {return -1}
        s.out[0]=to
        s.out_end[0]=to[to_len:]
        s.strm0_end[0]=start[len1:]
        s.bitp[0]=start;s.bits[0]=0;s.bitc[0]=0
        s.bitp[1]=comp_end;s.bits[1]=0;s.bitc[1]=0
        s.bitp[2]=s.strm0_end[0];s.bits[2]=0;s.bitc[2]=0
    } else {
        if ptr_diff(comp_end,start)<6 {return -1}
        half:=(to_len+1)>>1
        first_len:=int(load24le(start))
        start=start[3:]
        if ptr_diff(comp_end,start)<first_len {return -1}
        first_end:=start[first_len:]
        len0:=int(load16(start))
        start=start[2:]
        if ptr_diff(first_end,start)<len0+2 {return -1}
        mid:=first_end
        if ptr_diff(comp_end,mid)<3 {return -1}
        len3:=int(load16(mid))
        mid=mid[2:]
        if ptr_diff(comp_end,mid)<len3+2 {return -1}
        s.out[0]=to;s.out_end[0]=to[half:]
        s.out[1]=to[half:];s.out_end[1]=to[to_len:]
        s.strm0_end[0]=start[len0:]
        s.strm0_end[1]=mid[len3:]
        s.bitp[0]=start;s.bitp[1]=first_end;s.bitp[2]=s.strm0_end[0]
        s.bitp[3]=mid;s.bitp[4]=comp_end;s.bitp[5]=s.strm0_end[1]
        s.bits={};s.bitc={}
    }
    when ODIN_ARCH==.amd64 {
        if !FORCE_GENERIC && .bmi2 in info.cpu_features() {return huff64_bmi2(&s,&table,
            huff6) ? comp_len : -1}
    }
    return huff64_generic(&s,&table,huff6) ? comp_len : -1
}

@(private="file")
huff64_generic :: proc "contextless" (
    s:^Huff_State,table:^Huff_Table,huff6:bool,
) -> bool {return huff64(s,table,huff6)}

// Variable shifts without the count register.
@(private="file", enable_target_feature="bmi,bmi2,lzcnt")
huff64_bmi2 :: proc "contextless" (
    s:^Huff_State,table:^Huff_Table,huff6:bool,
) -> bool {return huff64(s,table,huff6)}

