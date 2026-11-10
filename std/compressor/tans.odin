package compressor

import "base:intrinsics"
import "core:sys/info"

@(private="file")
// The next state is next plus the low len bits of the stream.
Tans_Entry :: struct {
    len:u8,
    sym:u8,
    next:u16,
}
#assert(size_of(Tans_Entry)==4)

@(private="file")
Tans_Counts :: struct {
    num_singles:int,
    num_larger:int,
    singles:[256]u8, // symbols with one slot, ascending
    larger:[256]u32, // sym<<16 | count for counts above one, ascending
}

@(private="file")
Tans_State :: struct {
    table:[^]Tans_Entry,
    out:[^]u8,
    out_end:[^]u8,
    bitp:[2][^]u8,
    bits:[2]u32,
    bitc:[2]u32,
    state:[5]u32,
}

@(private="file") TANS_BUCKET_BITS :: 2
@(private="file") TANS_BUCKET_SIZE :: 1<<TANS_BUCKET_BITS
@(private="file") TANS_BUCKET_MASK :: TANS_BUCKET_SIZE-1

@(private="file")
insertion_sort :: proc "contextless" (a:[]$T) #no_bounds_check {
    for i in 1..<len(a) {
        v:=a[i]
        j:=i
        for j>0 && v<a[j-1] {a[j]=a[j-1];j-=1}
        a[j]=v
    }
}

@(private="file")
unpack_counts4 :: proc "contextless" (
    l_bits:int,counts:^Tans_Counts,b:^Bits,
) -> bool {
    seen_table:[256]bool
    seen:=view(&seen_table)
    singles_of,larger_of:=view(&counts.singles),view(&counts.larger)
    L:=u32(1)<<uint(l_bits)
    bits_refill_safe(b)
    num_non_zero:=int(bits_get(b,3))+2
    max_delta_bits_bits:=32-int(intrinsics.count_leading_zeros(u32(l_bits)))
    max_delta_bits:=int(bits_get(b,max_delta_bits_bits))
    if max_delta_bits==0 || max_delta_bits>l_bits {return false}
    cur,sum:u32
    singles,larger:=0,0
    for _ in 0..<num_non_zero-1 {
        bits_refill_safe(b)
        sym:=int(bits_get(b,8))
        if seen[sym] {return false}
        cur+=u32(bits_get(b,max_delta_bits))
        if cur==0 {return false}
        seen[sym]=true
        if cur==1 {
            singles_of[singles]=u8(sym);singles+=1
        } else {
            larger_of[larger]=u32(sym)<<16|cur;larger+=1
        }
        sum+=cur
        if sum>=L {return false}
    }
    bits_refill_safe(b)
    mps:=int(bits_get(b,8))
    if seen[mps] {return false}
    last:=L-sum
    if last<cur || last<=1 {return false}
    larger_of[larger]=u32(mps)<<16|last;larger+=1
    insertion_sort(singles_of[:singles])
    insertion_sort(larger_of[:larger])
    counts.num_singles=singles
    counts.num_larger=larger
    return true
}

@(private="file")
unfold_delta_clamped :: #force_inline proc "contextless" (delta:u32,pred:i32) -> i32 {
    if i32(delta)<=2*pred {return unfold_negatives(delta)+pred}
    return i32(delta)
}

@(private="file")
unpack_counts_delta :: proc "contextless" (
    l_bits:int,counts:^Tans_Counts,vbl:^Bits,
) -> bool {
    singles_of,larger_of:=view(&counts.singles),view(&counts.larger)
    k:=int(bits_get(vbl,3))
    got:=int(bits_get(vbl,8))+1
    if got<2 {return false}
    num_eg:=decode_alphabet_shape_num_eg(got,vbl)
    bb:=bits_to_block(vbl)
    num_unary:=got+num_eg
    unary_table:[256+255+16]u8 = ---
    unary:=view(&unary_table)
    up:=([^]u8)(&unary_table[0])
    if decode_unary_block(up,num_unary,&bb)!=num_unary {return false}
    store64(up[num_unary:],0)
    store64(up[num_unary+8:],0)
    vb:Bits
    bits_from_block(&vb,&bb)
    run_lens_table:[128*2+8+1]u16 = ---
    run_lens:=view(&run_lens_table)
    pairs:=decode_alphabet_shape_runlens(&run_lens_table,u32(got),u32(num_eg),up[got:],&vb)
    if pairs<0 {return false}
    vbl^=vb
    bits_refill_safe(vbl)
    sum:u32
    L:=u32(1)<<uint(l_bits)
    pred_state:i32=1*4+2
    singles,larger:=0,0
    bias:=u32(1)<<uint(k)
    ui:=0
    for pair in 0..<pairs {
        i:=u32(run_lens[pair*2])
        run:=run_lens[pair*2+1]
        for {
            bits_refill_safe(vbl)
            pred:=pred_state>>2
            extra:=u32(unary[ui])+u32(k);ui+=1
            if extra>15 {return false}
            delta:=(u32(1)<<extra)-bias
            delta+=u32(bits_get0(vbl,int(extra)))
            count:=unfold_delta_clamped(delta,pred)
            pred_state=pred_state-pred+min(count,pred*2)
            count+=1
            singles_of[singles]=u8(i)
            larger_of[larger]=(i<<16)+u32(count)
            singles+=int(count==1)
            larger+=int(count>=2)
            sum+=u32(count)
            i+=1
            run-=1
            if run==0 {break}
        }
    }
    counts.num_singles=singles
    counts.num_larger=larger
    return sum==L
}

@(private="file")
unpack_counts :: proc "contextless" (vb:^Bits,l_bits:int,counts:^Tans_Counts) -> bool {
    b:=vb^
    bits_refill_safe(&b)
    ok:=false
    if bits_get1(&b)!=0 {
        ok=unpack_counts_delta(l_bits,counts,&b)
    } else {
        ok=unpack_counts4(l_bits,counts,&b)
    }
    if !ok {return false}
    vb^=b
    return true
}

@(private="file")
entry32 :: #force_inline proc "contextless" (e:Tans_Entry) -> u32 {return transmute(u32)e}

@(private="file")
tans_fill :: proc "contextless" (
    table:[^]Tans_Entry,l_bits:int,counts:^Tans_Counts,
) {
    singles_of,larger_of:=view(&counts.singles),view(&counts.larger)
    L:=1<<uint(l_bits)
    t:=([^]u32)(table)
    bucket_table:[TANS_BUCKET_SIZE]int
    bucket:=view(&bucket_table)
    total:=L-counts.num_singles
    even:=total>>TANS_BUCKET_BITS
    rem:=total&TANS_BUCKET_MASK
    cum:=0
    for r in 0..<TANS_BUCKET_SIZE {
        bucket[r]=cum
        cum+=even
        if r<rem {cum+=1}
    }
    {
        e:=entry32({len=u8(l_bits)})
        dest:=total
        for i in 0..<counts.num_singles {
            t[dest]=e|u32(singles_of[i])<<8
            dest+=1
        }
    }
    cumulative:=0
    for li in 0..<counts.num_larger {
        packed:=larger_of[li]
        sym:=u8(packed>>16)
        count:=int(packed&0xffff)
        if count<=TANS_BUCKET_SIZE {
            m:=u32((1<<uint(count))-1)
            m<<=uint(cumulative&TANS_BUCKET_MASK)
            m|=m>>TANS_BUCKET_SIZE
            for c in 0..<count {
                r:=int(intrinsics.count_trailing_zeros(m))
                m&=m-1
                dest:=bucket[r];bucket[r]+=1
                from:=count+c
                nb:=l_bits-(31-int(intrinsics.count_leading_zeros(u32(from))))
                table[dest]={sym=sym,len=u8(nb),next=u16((from<<uint(nb))&(L-1))}
            }
        } else {
            bsr:=31-int(intrinsics.count_leading_zeros(u32(count)))
            nb:=l_bits-bsr
            threshold:=(1<<uint(bsr+1))-count
            one:=u32(1)<<uint(nb)
            e:=entry32({sym=sym,len=u8(nb),next=u16((count<<uint(nb))&(L-1))})
            inc:=one<<16
            countdown:=threshold
            for r in 0..<TANS_BUCKET_SIZE {
                run:=(count+((cumulative+TANS_BUCKET_MASK-r)&TANS_BUCKET_MASK))>>TANS_BUCKET_BITS
                dest:=bucket[r]
                if countdown<run {
                    for _ in 0..<countdown {t[dest]=e;dest+=1;e+=inc}
                    nb-=1
                    e=entry32({sym=sym,len=u8(nb),next=0})
                    inc>>=1
                    for _ in 0..<run-countdown {t[dest]=e;dest+=1;e+=inc}
                    countdown=count
                } else {
                    for _ in 0..<run {t[dest]=e;dest+=1;e+=inc}
                    countdown-=run
                }
                bucket[r]=dest
            }
        }
        cumulative+=count
    }
}

@(private="file")
tans_finish :: #force_inline proc "contextless" (s:^Tans_State) -> bool #no_bounds_check {
    LOOKAHEAD :: 2*3
    MAX_READ :: 2*3+4
    TAIL :: 2*MAX_READ+2*LOOKAHEAD
    tail:[TAIL]u8 = ---
    final_nbytes:=0
    in0,in1:=s.bitp[0],s.bitp[1]
    bits0,bitc0:=s.bits[0],s.bitc[0]
    bits1,bitc1:=s.bits[1],s.bitc[1]
    if uintptr(in1)<uintptr(in0) {return false}
    out,out_end:=s.out,s.out_end
    t0,t1,t2:=uint(s.state[0]),uint(s.state[1]),uint(s.state[2])
    t3,t4:=uint(s.state[3]),uint(s.state[4])
    table:=s.table
    loop: for uintptr(out)<uintptr(out_end) {
        left:=ptr_diff(in1,in0)
        if left<MAX_READ {
            if final_nbytes!=0 {return false}
            in0=in0[-int(bitc0>>3):];bitc0&=7
            in1=in1[bitc1>>3:];bitc1&=7
            left=ptr_diff(in1,in0)
            if left<0 {return false}
            intrinsics.mem_copy_non_overlapping(&tail[0],in0,left)
            intrinsics.mem_copy_non_overlapping(&tail[TAIL-left],in1[-left:],left)
            in0=([^]u8)(&tail[0])
            in1=([^]u8)(&tail[0])[TAIL:]
            final_nbytes=TAIL-left
        }
        refill0 :: #force_inline proc "contextless" (bits:^u32,bitc:^u32,p:^[^]u8) {
            bits^|=load32(p^)<<(bitc^&31)
            p^=p^[(31-bitc^)>>3:]
            bitc^|=24
        }
        refill1 :: #force_inline proc "contextless" (bits:^u32,bitc:^u32,p:^[^]u8) {
            bits^|=load32be(p^[-4:])<<(bitc^&31)
            p^=p^[-int((31-bitc^)>>3):]
            bitc^|=24
        }
        dec :: #force_inline proc "contextless" (
            table:[^]Tans_Entry,st:^uint,bits:^u32,bitc:^u32,out:^[^]u8,
        ) {
            e:=table[st^]
            out^[0]=e.sym;out^=out^[1:]
            st^=uint(bits^&mask32(u32(e.len)))+uint(e.next)
            bits^>>=e.len&31
            bitc^-=u32(e.len)
        }
        refill0(&bits0,&bitc0,&in0)
        dec(table,&t0,&bits0,&bitc0,&out);if uintptr(out)>=uintptr(out_end) {break loop}
        dec(table,&t1,&bits0,&bitc0,&out);if uintptr(out)>=uintptr(out_end) {break loop}
        refill0(&bits0,&bitc0,&in0)
        dec(table,&t2,&bits0,&bitc0,&out);if uintptr(out)>=uintptr(out_end) {break loop}
        dec(table,&t3,&bits0,&bitc0,&out);if uintptr(out)>=uintptr(out_end) {break loop}
        refill0(&bits0,&bitc0,&in0)
        dec(table,&t4,&bits0,&bitc0,&out);if uintptr(out)>=uintptr(out_end) {break loop}
        refill1(&bits1,&bitc1,&in1)
        dec(table,&t0,&bits1,&bitc1,&out);if uintptr(out)>=uintptr(out_end) {break loop}
        dec(table,&t1,&bits1,&bitc1,&out);if uintptr(out)>=uintptr(out_end) {break loop}
        refill1(&bits1,&bitc1,&in1)
        dec(table,&t2,&bits1,&bitc1,&out);if uintptr(out)>=uintptr(out_end) {break loop}
        dec(table,&t3,&bits1,&bitc1,&out);if uintptr(out)>=uintptr(out_end) {break loop}
        refill1(&bits1,&bitc1,&in1)
        dec(table,&t4,&bits1,&bitc1,&out)
    }
    in0=in0[-int(bitc0>>3):]
    in1=in1[bitc1>>3:]
    if ptr_diff(in1,in0)!=final_nbytes {return false}
    if t0|t1|t2|t3|t4>255 {return false}
    out_end[0]=u8(t0);out_end[1]=u8(t1);out_end[2]=u8(t2);out_end[3]=u8(t3);out_end[4]=u8(t4)
    return true
}

@(private="file")
tans64 :: #force_inline proc "contextless" (s:^Tans_State) -> bool #no_bounds_check {
    out,out_end:=s.out,s.out_end
    in0,in1:=s.bitp[0],s.bitp[1]
    if ptr_diff(in1,in0)>=8 && ptr_diff(out_end,out)>=10 {
        bits0,bitc0:=u64(s.bits[0]),uint(s.bitc[0])
        bits1,bitc1:=u64(s.bits[1]),uint(s.bitc[1])
        st:[5]uint
        for i in 0..<5 {st[i]=uint(s.state[i])}
        table:=s.table
        in1=in1[-8:]
        out_end=out_end[-10:]
        for uintptr(in0)<=uintptr(in1) && uintptr(out)<=uintptr(out_end) {
            bits0|=load64(in0)<<(bitc0&63)
            in0=in0[(63-bitc0)>>3:]
            bitc0|=56
            bits1|=load64be(in1)<<(bitc1&63)
            in1=in1[-int((63-bitc1)>>3):]
            bitc1|=56
            #unroll for i in 0..<5 {
                e:=table[st[i]]
                out[i]=e.sym
                st[i]=uint(u32(bits0)&mask32(u32(e.len)))+uint(e.next)
                bits0>>=e.len&63
                bitc0-=uint(e.len)
            }
            #unroll for i in 0..<5 {
                e:=table[st[i]]
                out[5+i]=e.sym
                st[i]=uint(u32(bits1)&mask32(u32(e.len)))+uint(e.next)
                bits1>>=e.len&63
                bitc1-=uint(e.len)
            }
            out=out[10:]
        }
        in1=in1[8:]
        s.out=out
        s.bitp[0]=in0[-int(bitc0>>3):]
        s.bitp[1]=in1[bitc1>>3:]
        s.bits[0]=u32(bits0)
        s.bits[1]=u32(bits1)
        s.bitc[0]=u32(bitc0&7)
        s.bitc[1]=u32(bitc1&7)
        for i in 0..<5 {s.state[i]=u32(st[i])}
    }
    return tans_finish(s)
}

// Decodes a tANS array of to_len bytes. Returns comp_len, or -1.
@(private)
get_array_tans :: proc "contextless" (
    comp:[^]u8,comp_len:int,to:[^]u8,to_len:int,scratch,scratch_end:[^]u8,
) -> int #no_bounds_check {
    comp_ptr:=comp
    comp_end:=comp[comp_len:]
    if comp_len<8 || to_len<5 {return -1}
    l_bits:int
    counts:Tans_Counts = ---
    {
        vb:Bits
        bits_open(&vb,comp_ptr,comp_end)
        if bits_get1(&vb)!=0 {return -1}
        l_bits=int(bits_get(&vb,2))+TANS_L_BITS_MIN
        if !unpack_counts(&vb,l_bits,&counts) {return -1}
        comp_ptr=bits_end_ptr(&vb)
    }
    payload:=ptr_diff(comp_end,comp_ptr)
    PAD :: 8
    small:[2*PAD+8]u8
    if payload<8 {
        if payload<=0 {return -1}
        intrinsics.mem_copy_non_overlapping(&small[PAD],comp_ptr,payload)
        comp_ptr=([^]u8)(&small[PAD])
        comp_end=comp_ptr[payload:]
    }
    L:=1<<uint(l_bits)
    if ptr_diff(scratch_end,scratch)<16 {return -1}
    mem:=align_up(scratch,16)
    if ptr_diff(scratch_end,mem)<16+L*size_of(Tans_Entry) {return -1}
    table:=([^]Tans_Entry)(mem[16:])
    tans_fill(table,l_bits,&counts)

    mask:=u64(L-1)
    bits1:=load64(comp_ptr)
    p1:=comp_ptr[8:]
    bits2:=load64be(comp_end[-8:])
    p2:=comp_end[-16:]
    x1:=bits1&mask;bits1>>=uint(l_bits)
    x2:=bits2&mask;bits2>>=uint(l_bits)
    x3:=bits1&mask;bits1>>=uint(l_bits)
    x4:=bits2&mask;bits2>>=uint(l_bits)
    x5:=bits1&mask;bits1>>=uint(l_bits)
    cnt1:=64-3*l_bits
    cnt2:=64-2*l_bits
    s:=Tans_State{
        table=table,
        out=to,
        out_end=to[to_len-5:],
        bitp={p1[-(cnt1>>3):],p2[8+(cnt2>>3):]},
        bits={u32(bits1),u32(bits2)},
        bitc={u32(cnt1&7),u32(cnt2&7)},
        state={u32(x1),u32(x2),u32(x3),u32(x4),u32(x5)},
    }
    when ODIN_ARCH==.amd64 {
        if !FORCE_GENERIC && .bmi2 in info.cpu_features() {return tans_bmi2(&s) ? comp_len : -1}
    }
    if !tans_generic(&s) {return -1}
    return comp_len
}

@(private="file")
tans_generic :: proc "contextless" (s:^Tans_State) -> bool {return tans64(s)}

// The low len bits by bzhi.
@(private="file", enable_target_feature="bmi,bmi2")
tans_bmi2 :: proc "contextless" (s:^Tans_State) -> bool {return tans64(s)}
