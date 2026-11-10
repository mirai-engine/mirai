package base

import "base:intrinsics"
import "core:mem"

// Change stamps of arrays copied in blocks: one per chunk of CHUNK slots, the revision of the last write to
// any of its slots. Between arrays of one timeline (copied from one another, and written only by the one
// that stamps with revisions no other repeats) an equal stamp means equal bytes, so a copy skips that
// chunk. Stamp 0 is a chunk never written: all zeros.
CHUNK_BITS :: 6
CHUNK :: 1<<CHUNK_BITS

chunks_of :: #force_inline proc "contextless" (slots:int) -> int {return (max(slots,0)+CHUNK-1)>>CHUNK_BITS}

// The slot was written at this revision. Workers that write slots of one chunk at once stamp it alike.
chunk_stamp :: #force_inline proc "contextless" (stamps:[]u64,slot:int,revision:u64) {
    intrinsics.atomic_store_explicit(&stamps[slot>>CHUNK_BITS],revision,.Relaxed)
}

// The stamp of a chunk, 0 past the stamps.
chunk_stamp_at :: #force_inline proc "contextless" (stamps:[]u64,chunk:int) -> u64 {return chunk<len(stamps)?stamps[chunk]:0}

// An array of elements of `size` bytes that one set of stamps covers, with others of the same slots.
Chunk_Copy :: struct {dst,src:[]byte,size:int}

// Makes the first `slots` slots of each array of dst those of src, chunk by chunk: the chunks whose stamps
// differ, or all with whole, which take the stamps of src. src past its end reads as zeros; slots and stamps
// dst lacks are left out. Returns the bytes written.
chunks_copy :: proc "contextless" (arrays:[]Chunk_Copy,dst_stamps,src_stamps:[]u64,slots:int,whole:bool) -> (written:int) {
    for k in 0..<min(chunks_of(slots),len(dst_stamps)) {
        stamp:=chunk_stamp_at(src_stamps,k)
        if !whole && dst_stamps[k]==stamp {continue}
        for a in arrays {
            if a.size<=0 {continue}
            first,last:=k*CHUNK*a.size,min((k+1)*CHUNK,len(a.dst)/a.size)*a.size
            if first>=last {continue}
            from:=clamp(len(a.src),first,last)
            if from>first {mem.copy_non_overlapping(&a.dst[first],&a.src[first],from-first)}
            if last>from {mem.zero(&a.dst[from],last-from)}
            written+=last-first
        }
        dst_stamps[k]=stamp
    }
    return
}
