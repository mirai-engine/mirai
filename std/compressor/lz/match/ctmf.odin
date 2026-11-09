package match

import "base:intrinsics"
import "base:runtime"
import "core:math/bits"
import "mirai:std/compressor/lz/entropy"

// The hash tables below read 8 bytes at every position they hash: callers keep 8 readable bytes
// after the last hashed position.

HASH_U64_MULTIPLIER :: u64(0xCF1BBCDCB7A56463)

ctmf_hash_multiplier :: #force_inline proc "contextless" (length:int) -> u64 {
    if length<=0 {return 0}
    return HASH_U64_MULTIPLIER<<(u64(8-clamp(length,1,8))*8)
}

hash_bytes_64 :: #force_inline proc "contextless" (ptr:[^]u8,
    mult:u64) -> u64 {return load64(ptr)*mult}

hash_n_bytes :: #force_inline proc "contextless" (ptr:[^]u8,$LEN:int,bits:int) -> uint {
    return uint(hash_bytes_64(ptr,ctmf_hash_multiplier(LEN))>>u64(64-bits))
}

CACHE_LINE :: 64

@(private)
alloc_aligned :: proc(arena:^entropy.Arena,$T:typeid,n:int) -> (mem:[]u8,data:[]T) {
    mem=entropy.arena_alloc(arena,u8,n*size_of(T)+CACHE_LINE)
    if mem==nil {return}
    off:=int(-uintptr(raw_data(mem))&(CACHE_LINE-1))
    data=([^]T)(&mem[off])[:n]
    return
}

//===================================================================
// Ctmf: cache table. Each row holds 1<<DEPTH_BITS entries, newest first; a u32 entry keeps the
// low CTMF_POS_BITS of the position and the high bits of the hash as a check. The next_* fields
// are the row and hash of next_ptr, prefetched one step ahead.

CTMF_POS_BITS :: 26
CTMF_POS_MASK :: u32(1<<CTMF_POS_BITS-1)
CTMF_CHECK_MASK :: ~CTMF_POS_MASK

Ctmf :: struct($H:typeid,$DEPTH_BITS:int,$SECOND_HASH_LEN:int,$MML:int) where H==u32 || H==u16 {
    hash_table_mem:[]u8,
    hash_table:[]H,
    table_size_bits:int,
    hash_row_mask:u32,
    base_ptr:[^]u8,
    next_ptr:[^]u8,
    next_row:[^]H,
    next_row_second:[^]H,
    hash_mul:u64,
    next_hash:u32, // check bits only; the second hash row uses the same value
}

// Smallest negative offset whose low CTMF_POS_BITS match the entry; in [-2^CTMF_POS_BITS,-1].
ctmf_resolve_neg_offset :: #force_inline proc "contextless" (entry:u32,pos32:u32) -> int {
    return int(i32(entry-pos32|~CTMF_POS_MASK))
}

ctmf_allocate :: proc(c:^Ctmf($H,$D,$S,$M),table_size_bits,hash2_bits,chain_bits:int,
    arena:^entropy.Arena,hash_len:int) -> bool {
    if table_size_bits<D || table_size_bits>30 {return false}
    c.table_size_bits=table_size_bits
    c.hash_row_mask=u32(1<<uint(table_size_bits)-(1<<uint(D)))
    c.next_ptr=nil
    hl:=hash_len
    if hl<=0 {hl=M}
    c.hash_mul=ctmf_hash_multiplier(hl)
    c.hash_table_mem,c.hash_table=alloc_aligned(arena,H,1<<uint(table_size_bits))
    if c.hash_table_mem==nil {return false}
    ctmf_reset(c)
    return true
}

ctmf_release :: proc(c:^Ctmf($H,$D,$S,$M),arena:^entropy.Arena) {
    entropy.arena_free(arena,c.hash_table_mem)
    c.hash_table_mem=nil
    c.hash_table=nil
}

ctmf_reset :: proc(c:^Ctmf($H,$D,$S,$M)) {
    if len(c.hash_table)>0 {runtime.mem_zero(raw_data(c.hash_table),len(c.hash_table)*size_of(H))}
}

ctmf_set_base :: #force_inline proc "contextless" (c:^Ctmf($H,$D,$S,$M),
    base:[^]u8) {c.base_ptr=base}

// Inserts a sparse sample of [max(base,preload_upto-max_preload_len),preload_upto): steps start
// at preload_len>>18 (at least 2) and halve so the last part is dense.
ctmf_set_base_and_preload :: proc "contextless" (c:^Ctmf($H,$D,$S,$M),base,preload_upto:[^]u8,
    max_preload_len:int) {
    c.base_ptr=base
    if preload_upto==base {return}
    ptr:=base
    end:=preload_upto
    preload_len:=pdiff(end,ptr)
    if preload_len<=0 {return}
    if preload_len>max_preload_len {
        preload_len=max_preload_len
        ptr=padd(end,-max_preload_len)
    }
    step:=max(preload_len>>18,2)
    num:=(preload_len/2)/step
    ctmf_set_next(c,ptr)
    for {
        num-=1
        if num<=0 {
            if uintptr(ptr)>=uintptr(end) {break}
            step>>=1
            if step<1 {break}
            num=pdiff(end,ptr)/step
            if step>1 {num/=2}
        }
        pos:=u32(pdiff(ptr,c.base_ptr))
        row:=c.next_row
        row_second:=c.next_row_second;_=row_second
        h:=c.next_hash
        ptr=padd(ptr,step)
        ctmf_set_next(c,ptr)
        ctmf_insert(c,row,pos,h)
        when S>0 {ctmf_insert(c,row_second,pos,h)}
    }
}

ctmf_prefetch_next :: #force_inline proc "contextless" (c:^Ctmf($H,$D,$S,$M),ptr:[^]u8) {
    ctmf_set_next(c,ptr)
    intrinsics.prefetch_write_data(c.next_row,3)
    when S>0 {intrinsics.prefetch_write_data(c.next_row_second,3)}
}

ctmf_set_next :: #force_inline proc "contextless" (c:^Ctmf($H,$D,$S,$M),ptr:[^]u8) {
    c.next_ptr=ptr
    h:=ctmf_hash(c,ptr)
    c.next_hash=h
    c.next_row=&raw_data(c.hash_table)[h&c.hash_row_mask]
    when S>0 {c.next_row_second=&raw_data(c.hash_table)[ctmf_second_hash_index(c,h,ptr)]}
}

// After a match of len at ptr: inserts next_ptr, then ptr+i for i doubling, and moves next to
// ptr+len. No second-hash inserts inside the match.
ctmf_step_and_insert :: proc "contextless" (c:^Ctmf($H,$D,$S,$M),ptr:[^]u8,len:int) {
    end:=padd(ptr,len)
    if uintptr(c.next_ptr)>=uintptr(end) {
        if c.next_ptr!=end {ctmf_set_next(c,end)}
        return
    }
    zero:=c.base_ptr
    ctmf_insert(c,c.next_row,u32(pdiff(c.next_ptr,zero)),c.next_hash)
    when S>0 {ctmf_insert(c,c.next_row_second,u32(pdiff(c.next_ptr,zero)),c.next_hash)}
    i:=int(i32(pdiff(c.next_ptr,ptr)))+1
    for ;i<len;i+=i {
        p:=padd(ptr,i)
        h:=ctmf_hash(c,p)
        ctmf_insert(c,&raw_data(c.hash_table)[h&c.hash_row_mask],u32(pdiff(p,zero)),h)
    }
    ctmf_set_next(c,end)
}

// Shifts the row down one slot and puts the new entry first. A u16 table stores the position only.
ctmf_insert :: #force_inline proc "contextless" (c:^Ctmf($H,$D,$S,$M),row:[^]H,pos,
    check:u32) #no_bounds_check {
    DEPTH :: 1<<uint(D)
    when H==u32 {
        e:=(pos&CTMF_POS_MASK)|(check&CTMF_CHECK_MASK)
        when DEPTH==16 {
            a0:=intrinsics.unaligned_load((^#simd[8]u32)(&row[0]))
            a1:=intrinsics.unaligned_load((^#simd[8]u32)(&row[7]))
            intrinsics.unaligned_store((^#simd[8]u32)(&row[1]),a0)
            intrinsics.unaligned_store((^#simd[8]u32)(&row[8]),a1)
        } else when DEPTH==8 {
            a0:=intrinsics.unaligned_load((^#simd[4]u32)(&row[0]))
            a1:=intrinsics.unaligned_load((^#simd[4]u32)(&row[3]))
            intrinsics.unaligned_store((^#simd[4]u32)(&row[1]),a0)
            intrinsics.unaligned_store((^#simd[4]u32)(&row[4]),a1)
        } else when DEPTH==4 {
            r0,r1,r2:=row[0],row[1],row[2]
            row[1]=r0;row[2]=r1;row[3]=r2
        } else when DEPTH==2 {
            row[1]=row[0]
        } else when DEPTH!=1 {
            #panic("Ctmf depth must be 1, 2, 4, 8 or 16")
        }
        row[0]=e
    } else {
        when DEPTH>1 {
            for i:=DEPTH-1;i>0;i-=1 {row[i]=row[i-1]}
        }
        row[0]=u16(pos)
    }
}

// Candidate offsets (cur_absolute_pos - entry, masked) of row then row2 into candidates; returns
// the bit mask of the ones whose check bits match. row2 counts once when it equals row.
ctmf_find_candidates :: #force_inline proc "contextless" (c:^Ctmf($H,$D,$S,$M),candidates:[^]u32,
    row,row2:[^]H,cur_absolute_pos,hash:u32) -> u32 #no_bounds_check {
    DEPTH :: 1<<uint(D)
    when H==u32 && (DEPTH==8 || (DEPTH==4 && S>0)) {
        // the x64 path: 4 entries of row and 4 of row2 (or the second half of row)
        rows:=[2][^]H{row,S>0?row2:row[4:]}
        mask:=u32(0)
        for r in 0..<2 {
            for d in 0..<4 {
                e:=rows[r][d]
                candidates[r*4+d]=(cur_absolute_pos-e)&CTMF_POS_MASK
                if (e~hash)&CTMF_CHECK_MASK==0 {mask|=1<<uint(r*4+d)}
            }
        }
        when S>0 {if row==row2 {mask&=0xf}}
        return mask
    } else {
        bit:=u32(1)
        mask:=u32(0)
        for d in 0..<DEPTH {
            e:=u32(row[d])
            candidates[d]=(cur_absolute_pos-e)&CTMF_POS_MASK
            if (e~hash)&CTMF_CHECK_MASK==0 {mask|=bit}
            bit<<=1
        }
        when S>0 {
            if row!=row2 {
                for d in 0..<DEPTH {
                    e:=u32(row2[d])
                    candidates[d+DEPTH]=(cur_absolute_pos-e)&CTMF_POS_MASK
                    if (e~hash)&CTMF_CHECK_MASK==0 {mask|=bit}
                    bit<<=1
                }
            }
        }
        return mask
    }
}

ctmf_second_hash_index :: #force_inline proc "contextless" (c:^Ctmf($H,$D,$S,$M),h1:u32,
    ptr:[^]u8) -> uint {
    h:=hash_n_bytes(ptr,S,c.table_size_bits)
    return h&~uint((1<<uint(D))-1)
}

// Low bits index the row (after & hash_row_mask), high bits are the check.
ctmf_hash :: #force_inline proc "contextless" (c:^Ctmf($H,$D,$S,$M),ptr:[^]u8) -> u32 {
    h:=hash_bytes_64(ptr,c.hash_mul)
    return bits.rotate_left32(u32(h>>32),c.table_size_bits)
}

//===================================================================
// Fast_Ctmf: one entry per slot, no check bits, for the HyperFast levels.

Fast_Ctmf :: struct($H:typeid) where H==u32 || H==u16 {
    hash_table_mem:[]u8,
    hash_table:[]H,
    hash_mul:u64,
    table_size_bits:int,
    hash_shift:int,
    base_ptr:[^]u8,
}

fast_ctmf_hash :: #force_inline proc "contextless" (ptr64le:u64,mul64:u64,hash_shift:int) -> uint {
    return uint((ptr64le*mul64)>>uint(hash_shift))
}

// Inserts pos and returns the previous value of the slot.
fast_ctmf_insert_u64 :: #force_inline proc "contextless" (hash_table:[^]$H,ptr64le:u64,
    hash_mul:u64,hash_shift:int,pos:int) -> H {
    h:=fast_ctmf_hash(ptr64le,hash_mul,hash_shift)
    prev:=hash_table[h]
    hash_table[h]=H(pos)
    return prev
}
fast_ctmf_insert_ptr :: #force_inline proc "contextless" (hash_table:[^]$H,ptr:[^]u8,hash_mul:u64,
    hash_shift:int,pos:int) -> H {
    return fast_ctmf_insert_u64(hash_table,load64(ptr),hash_mul,hash_shift,pos)
}
fast_ctmf_insert :: proc{fast_ctmf_insert_u64,fast_ctmf_insert_ptr}

fast_ctmf_allocate :: proc(c:^Fast_Ctmf($H),table_size_bits,hash2_bits,chain_bits:int,
    arena:^entropy.Arena,hash_len:int) -> bool {
    if table_size_bits<1 || table_size_bits>30 {return false}
    hl:=hash_len
    if hl==0 {hl=4}
    c.table_size_bits=table_size_bits
    c.hash_shift=64-table_size_bits
    switch hl {
    case 5,6,7,8: c.hash_mul=HASH_U64_MULTIPLIER<<(u64(8-hl)*8)
    case: c.hash_mul=u64(2654435761)<<32
    }
    c.hash_table_mem,c.hash_table=alloc_aligned(arena,H,1<<uint(table_size_bits))
    if c.hash_table_mem==nil {return false}
    fast_ctmf_reset(c)
    return true
}

fast_ctmf_release :: proc(c:^Fast_Ctmf($H),arena:^entropy.Arena) {
    entropy.arena_free(arena,c.hash_table_mem)
    c.hash_table_mem=nil
    c.hash_table=nil
}

fast_ctmf_reset :: proc(c:^Fast_Ctmf($H)) {
    if len(c.hash_table)>0 {runtime.mem_zero(raw_data(c.hash_table),len(c.hash_table)*size_of(H))}
}

fast_ctmf_set_base_and_preload :: proc "contextless" (c:^Fast_Ctmf($H),base,preload_upto:[^]u8,
    max_preload_len:int) {
    c.base_ptr=base
    if uintptr(preload_upto)<=uintptr(base) {return}
    ptr:=base
    end:=preload_upto
    preload_len:=pdiff(end,ptr)
    if preload_len>max_preload_len {
        preload_len=max_preload_len
        ptr=padd(end,-max_preload_len)
    }
    step:=max(preload_len>>18,2)
    num:=(preload_len/2)/step
    table:=raw_data(c.hash_table)
    for {
        num-=1
        if num<=0 {
            if uintptr(ptr)>=uintptr(end) {break}
            step>>=1
            if step<1 {break}
            num=pdiff(end,ptr)/step
            if step>1 {num/=2}
        }
        fast_ctmf_insert_ptr(table,ptr,c.hash_mul,c.hash_shift,pdiff(ptr,c.base_ptr))
        ptr=padd(ptr,step)
    }
}

//===================================================================
// The member names of the two tables, for parses written once over both.

allocate :: proc{ctmf_allocate,fast_ctmf_allocate}
release :: proc{ctmf_release,fast_ctmf_release}
reset :: proc{ctmf_reset,fast_ctmf_reset}
set_base_and_preload :: proc{ctmf_set_base_and_preload,fast_ctmf_set_base_and_preload}
