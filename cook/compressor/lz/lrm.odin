package lz_optimal

import "base:intrinsics"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"

// Long range matcher: a sorted table of rolling hashes of every `step`-th position of a chunk,
// with a jump table on the top hash bits and a blocked Bloom filter. A cascade is a binary tree
// of LRMs over equal chunks (pairs merged upwards); a set is the list of LRMs that covers
// everything before a chunk boundary, closest first.

LRM_MIN_MATCH_LEN :: 8
LRM_GOOD_ENOUGH_LEN :: 256
LRM_NUM_DUPES :: 16
LRM_CASCADE_MAX_LEVELS :: 8
LRM_SET_MAX :: 64
LRM_SCANNER_WINDOW_SIZE :: 32

// Default build parameters of the encoder's LRM.
LRM_STEP :: 6
LRM_HASH_LENGTH :: 8
LRM_JUMP_BITS :: 10

@(private="file") HASH_MUL :: u32(741103597)
@(private="file") HASH_MUL4 :: u32(1360715025)
@(private="file") BLOOM_COL_SHIFT :: 9
@(private="file") BLOOM_COL_SIZE :: 1<<BLOOM_COL_SHIFT
@(private="file") BLOOM_COL_MASK :: BLOOM_COL_SIZE-1
@(private="file") BLOOM_COL_WORDS :: BLOOM_COL_SIZE/32
@(private="file") BLOOM_NHASH :: 3

Lrm_Entry :: struct {hash:u32, pos32:u32} // pos32 is relative to match_base_ptr

Lrm :: struct {
    entries:[]Lrm_Entry, // the last one is a sentry with hash 0xFFFFFFFF
    entries_mem:[]Lrm_Entry,
    bloom_row_shift:int,
    bloom:[]u32,
    hash_length:int,
    hash_mul_end:u32,
    // covers [chunk_base_ptr,chunk_base_ptr+buf_size); match_base_ptr is inside it
    chunk_base_ptr:[^]u8,
    match_base_ptr:[^]u8,
    buf_size:int,
    jump_in:[]i32,
    jump_in_shift:uint,
}

Lrm_Cascade :: struct {
    lrms:[LRM_CASCADE_MAX_LEVELS][]^Lrm,
    chunk_size:int,
    buffer:[^]u8,
    buf_size:int,
    step,jump_bits_0,jump_bits_inc,hash_length:int,
    num_chunks,next_chunk:int,
    arena:^entropy.Arena,
}

Lrm_Set :: struct {lrms:[LRM_SET_MAX]^Lrm, count:int}

Lrm_Scanner :: struct {
    last_ml_plus_ptr:uintptr,
    hash:u32,
    hash_mul_end:u32,
    last_off:int,
    hash_length:int,
    end_ptr:uintptr, // buffer end - hash length; 0 makes the scanner return no matches
    set:^Lrm_Set,
    match_offset_limit:int,
    // windowed scanner:
    base_ptr,last_ptr,window_base:uintptr,
    window_len:[LRM_SCANNER_WINDOW_SIZE]i32,
    window_off:[LRM_SCANNER_WINDOW_SIZE]int,
}

lrm_initial_hash4 :: #force_inline proc "contextless" (p:[^]u8) -> u32 {
    return u32(p[3])+HASH_MUL*(u32(p[2])+HASH_MUL*(u32(p[1])+HASH_MUL*u32(p[0])))
}

lrm_initial_hash :: proc "contextless" (p:[^]u8,length:int) -> u32 {
    if length==8 {return lrm_initial_hash4(p)*HASH_MUL4+lrm_initial_hash4(padd(p,4))}
    h:=u32(0)
    for i in 0..<length {h*=HASH_MUL;h+=u32(p[i])}
    return h
}

lrm_roll_hash :: #force_inline proc "contextless" (hash,mul_end:u32,add,remove:u8) -> u32 {
    h:=hash-u32(remove)*mul_end
    h*=HASH_MUL
    return h+u32(add)
}

@(private="file")
bloom_insert :: #force_inline proc "contextless" (bloom:[]u32,shift:int,hash:u32) #no_bounds_check {
    row:=bloom[int(hash>>uint(shift))*BLOOM_COL_WORDS:]
    mixed:=hash*3677199193
    counter:=mixed
    col_step:=mixed>>(32-BLOOM_COL_SHIFT)
    for _ in 0..<BLOOM_NHASH {
        column:=counter&BLOOM_COL_MASK
        row[column>>5]|=1<<(column&31)
        counter+=col_step
    }
}

@(private="file")
bloom_maybe_contains :: #force_inline proc "contextless" (bloom:[]u32,shift:int,
    hash:u32) -> bool #no_bounds_check {
    row:=bloom[int(hash>>uint(shift))*BLOOM_COL_WORDS:]
    mixed:=hash*3677199193
    counter:=mixed
    col_step:=mixed>>(32-BLOOM_COL_SHIFT)
    maybe:=u32(1)
    for _ in 0..<BLOOM_NHASH {
        column:=counter&BLOOM_COL_MASK
        maybe&=row[column>>5]>>(column&31)
        counter+=col_step
    }
    return maybe!=0
}

@(private="file")
lrm_free_bloom :: proc(lrm:^Lrm,arena:^entropy.Arena) {
    entropy.arena_free(arena,lrm.bloom)
    lrm.bloom=nil
}

@(private="file")
lrm_make_jump :: proc(lrm:^Lrm,jump_bits:int,arena:^entropy.Arena) -> bool {
    entries:=lrm.entries
    num:=len(entries)-1
    entropy.arena_free(arena,lrm.jump_in)
    lrm.jump_in=nil
    if jump_bits>0 && num>4 {
        lrm.jump_in_shift=uint(32-jump_bits)
        size:=1<<uint(jump_bits)
        lrm.jump_in=entropy.arena_alloc(arena,i32,size+1)
        if lrm.jump_in==nil {return false}
        hi:=0
        for j in 0..<size {
            jh:=u32(j)<<lrm.jump_in_shift
            for hi<num && entries[hi].hash<jh {hi+=1}
            lrm.jump_in[j]=i32(hi)
        }
        lrm.jump_in[size]=i32(num)
    } else {
        lrm.jump_in_shift=32
        lrm.jump_in=entropy.arena_alloc(arena,i32,2)
        if lrm.jump_in==nil {return false}
        lrm.jump_in[0]=0
        lrm.jump_in[1]=i32(num)
    }
    lrm_free_bloom(lrm,arena)
    if num>4*1024 {
        log2:=(31+3-BLOOM_COL_SHIFT)-int(intrinsics.count_leading_zeros(u32(num)))
        if log2<=0 {return false}
        nrows:=1<<uint(log2)
        shift:=32-log2
        lrm.bloom=entropy.arena_alloc_zeroed(arena,u32,nrows*BLOOM_COL_WORDS)
        if lrm.bloom==nil {return false}
        lrm.bloom_row_shift=shift
        for i in 0..<num {bloom_insert(lrm.bloom,shift,entries[i].hash)}
    }
    return true
}

// Keeps the first LRM_NUM_DUPES+1 entries of each run of equal hashes.
@(private="file")
lrm_dedupe :: proc "contextless" (lrm:^Lrm) #no_bounds_check {
    e:=lrm.entries
    n:=len(e)
    if n<=LRM_NUM_DUPES*2 {return}
    src:=1
    for src<n && e[src].hash!=e[src-1].hash {src+=1}
    if src==n {return}
    dst:=src-1
    for {
        cur:=e[dst].hash
        last:=min(n,src+LRM_NUM_DUPES)
        for src<last && e[src].hash==cur {dst+=1;e[dst]=e[src];src+=1}
        for src<n && e[src].hash==cur {src+=1}
        if src==n {break}
        dst+=1;e[dst]=e[src];src+=1
        for src<n && e[src].hash!=e[dst].hash {dst+=1;e[dst]=e[src];src+=1}
        if src==n {break}
    }
    lrm.entries=e[:dst+1]
}

@(private="file")
entry_less :: proc "contextless" (a,b:Lrm_Entry) -> bool {return a.hash<b.hash}

@(private="file")
lrm_fill :: proc(lrm:^Lrm,buffer:[^]u8,buf_size,step,jump_bits,hash_length:int,
    arena:^entropy.Arena) -> bool #no_bounds_check {
    if buf_size<hash_length || hash_length<LRM_MIN_MATCH_LEN || buf_size>1<<30 ||
        step<1 {return false}
    num:=1+(buf_size-hash_length)/step
    lrm.chunk_base_ptr=buffer
    lrm.match_base_ptr=buffer
    lrm.buf_size=buf_size
    lrm.hash_length=hash_length
    lrm.hash_mul_end=1
    for _ in 0..<hash_length-1 {lrm.hash_mul_end*=HASH_MUL}
    lrm.entries_mem=entropy.arena_alloc(arena,Lrm_Entry,num+1)
    if lrm.entries_mem==nil {return false}
    entries:=lrm.entries_mem
    ei:=0
    last:=max(u32)
    for pos:=0;pos<=buf_size-hash_length;pos+=step {
        h:=lrm_initial_hash(padd(buffer,pos),hash_length)
        if h==last {continue}
        last=h
        entries[ei]=Lrm_Entry{h,u32(pos)}
        ei+=1
    }
    entropy.stdsort(entries[:ei],entry_less)
    sentry:=entries[ei-1]
    sentry.hash=max(u32)
    entries[ei]=sentry
    lrm.entries=entries[:ei+1]
    lrm_dedupe(lrm)
    return lrm_make_jump(lrm,jump_bits,arena)
}

@(private="file")
lrm_destroy :: proc(lrm:^Lrm,arena:^entropy.Arena) {
    if lrm==nil {return}
    lrm_free_bloom(lrm,arena)
    entropy.arena_free(arena,lrm.jump_in)
    entropy.arena_free(arena,lrm.entries_mem)
    entropy.arena_free(arena,([^]Lrm)(lrm)[:1])
}

@(private="file")
lrm_new :: proc(arena:^entropy.Arena) -> ^Lrm {
    s:=entropy.arena_alloc_zeroed(arena,Lrm,1)
    return s==nil?nil:&s[0]
}

// Best match among entries with this hash: the longest, ties to the lowest offset; stops at
// LRM_GOOD_ENOUGH_LEN. Offsets >= match_offset_limit are ignored.
lrm_find_match :: proc "contextless" (lrm:^Lrm,hash:u32,ptr,ptrend:[^]u8,match_offset:^int,
    match_offset_limit:int) -> i32 #no_bounds_check {
    if lrm==nil || pdiff(ptrend,ptr)<LRM_MIN_MATCH_LEN {return 0}
    if lrm.bloom!=nil && !bloom_maybe_contains(lrm.bloom,lrm.bloom_row_shift,hash) {return 0}
    ji:=int(u64(hash)>>lrm.jump_in_shift)
    jump1:=int(lrm.jump_in[ji])
    entries:=lrm.entries
    if entries[jump1].hash>hash {return 0}
    best_ml:=i32(0)
    best_off:=match_offset_limit
    jump2:=int(lrm.jump_in[ji+1])
    it:=jump1
    nleft:=jump2-jump1
    if nleft>0 {
        for {
            half:=nleft>>1
            if half==0 {break}
            mid:=it+half
            if entries[mid].hash<hash {it=mid}
            nleft-=half
        }
        if entries[it].hash<hash {it+=1}
    }
    ml_must_be_above:=LRM_MIN_MATCH_LEN-1
    for it<len(entries) && entries[it].hash==hash {
        vs:=padd(lrm.match_base_ptr,int(entries[it].pos32))
        ml:int
        if uintptr(vs)<uintptr(ptr) && match.havematch_better(ptr,vs,ptrend,ml_must_be_above,&ml) {
            ml_must_be_above=ml-1
            off:=pdiff(ptr,vs)
            if off<best_off {
                best_ml=i32(ml)
                best_off=off
                if best_ml>=LRM_GOOD_ENOUGH_LEN {
                    match_offset^=best_off
                    return best_ml
                }
            }
        }
        it+=1
    }
    match_offset^=best_off
    return best_ml
}

@(private="file")
lrm_fill_merge :: proc(lrm:^Lrm,lhs,rhs:^Lrm,jump_bits:int,
    arena:^entropy.Arena) -> bool #no_bounds_check {
    lrm.hash_length=lhs.hash_length
    lrm.hash_mul_end=lhs.hash_mul_end
    rhs_add:=pdiff(rhs.chunk_base_ptr,lhs.chunk_base_ptr)
    lrm.chunk_base_ptr=lhs.chunk_base_ptr
    lrm.buf_size=rhs_add+rhs.buf_size
    if lrm.buf_size>=1<<31 {
        lrm.match_base_ptr=rhs.match_base_ptr
        lrm.entries_mem=entropy.arena_alloc(arena,Lrm_Entry,len(rhs.entries))
        if lrm.entries_mem==nil {return false}
        copy(lrm.entries_mem,rhs.entries)
        lrm.entries=lrm.entries_mem
        return lrm_make_jump(lrm,jump_bits,arena)
    }
    lrm.match_base_ptr=lrm.chunk_base_ptr
    rhs_add32:=u32(rhs_add)
    le:=lhs.entries
    ln:=len(le)-1
    re:=rhs.entries
    rn:=len(re)-1
    lrm.entries_mem=entropy.arena_alloc(arena,Lrm_Entry,ln+rn+1)
    if lrm.entries_mem==nil {return false}
    e:=lrm.entries_mem
    li,ri,d:=0,0,0
    for {
        if le[li].hash<=re[ri].hash {
            e[d]=le[li];li+=1;d+=1
            if li>=ln {break}
        } else {
            e[d]=Lrm_Entry{re[ri].hash,re[ri].pos32+rhs_add32};ri+=1;d+=1
            if ri>=rn {break}
        }
    }
    for ri<rn {e[d]=Lrm_Entry{re[ri].hash,re[ri].pos32+rhs_add32};d+=1;ri+=1}
    for li<ln {e[d]=le[li];li+=1;d+=1}
    e[d]=le[ln]
    lrm.entries=e[:d+1]
    lrm_dedupe(lrm)
    return lrm_make_jump(lrm,jump_bits,arena)
}

// The longest match over the set; ties keep the earlier (closer) LRM.
lrm_set_find_match :: proc "contextless" (set:^Lrm_Set,hash:u32,ptr,ptrend:[^]u8,match_offset:^int,
    match_offset_limit:int) -> i32 {
    best_len:=i32(0)
    best_off:=0
    for i in 0..<(set==nil?0:set.count) {
        off:int
        l:=lrm_find_match(set.lrms[i],hash,ptr,ptrend,&off,match_offset_limit)
        if l>best_len {best_len=l;best_off=off}
    }
    match_offset^=best_off
    return best_len
}

lrm_set_get_base_ptr :: proc "contextless" (set:^Lrm_Set) -> [^]u8 {
    if set==nil || set.count==0 {return nil}
    return set.lrms[set.count-1].chunk_base_ptr
}

//===================================================================
// Cascade

@(private="file")
lrm_fill_cascade_setup :: proc(casc:^Lrm_Cascade,buffer:[^]u8,buf_size,step,jump_bits_0,
    jump_bits_inc,base_chunk_size,hash_length:int) -> bool {
    casc.buffer=buffer
    casc.buf_size=buf_size
    casc.chunk_size=base_chunk_size
    casc.num_chunks=buf_size/base_chunk_size
    casc.next_chunk=0
    for level in 0..<LRM_CASCADE_MAX_LEVELS {
        n:=casc.num_chunks>>uint(level)
        if n==0 {continue}
        casc.lrms[level]=entropy.arena_alloc_zeroed(casc.arena,^Lrm,n)
        if casc.lrms[level]==nil {return false}
    }
    casc.step=step
    casc.jump_bits_0=jump_bits_0
    casc.jump_bits_inc=jump_bits_inc
    casc.hash_length=hash_length
    return true
}

@(private="file")
lrm_fill_cascade_increment :: proc(casc:^Lrm_Cascade) -> bool {
    if casc.next_chunk>=casc.num_chunks {return false}
    arena:=casc.arena
    chunk:=casc.next_chunk
    casc.next_chunk+=1
    cur:=lrm_new(arena)
    if cur==nil {return false}
    if !lrm_fill(cur,padd(casc.buffer,chunk*casc.chunk_size),casc.chunk_size,casc.step,
        casc.jump_bits_0,casc.hash_length,arena) {
        lrm_destroy(cur,arena)
        return false
    }
    level:=0
    for (chunk>>uint(level))&1==1 && level+1<LRM_CASCADE_MAX_LEVELS {
        merged:=lrm_new(arena)
        lhs:=casc.lrms[level][(chunk>>uint(level))-1]
        if merged==nil || lhs==nil || !lrm_fill_merge(merged,lhs,cur,
            casc.jump_bits_0+level*casc.jump_bits_inc,arena) {
            lrm_destroy(merged,arena)
            lrm_destroy(cur,arena)
            return false
        }
        lrm_destroy(cur,arena)
        cur=merged
        level+=1
    }
    casc.lrms[level][chunk>>uint(level)]=cur
    return true
}

@(private="file")
lrm_cascade_alloc :: proc(buffer:[^]u8,buf_size,step,jump_bits_0,jump_bits_inc,base_chunk_size,
    hash_length:int,arena:^entropy.Arena) -> ^Lrm_Cascade {
    if buffer==nil || buf_size<0 || step<1 || hash_length<LRM_MIN_MATCH_LEN ||
        base_chunk_size<hash_length ||
        base_chunk_size>1<<30 || jump_bits_0<0 || jump_bits_0>31 || jump_bits_inc<0 ||
        jump_bits_0+(LRM_CASCADE_MAX_LEVELS-1)*jump_bits_inc>24 {return nil}
    s:=entropy.arena_alloc_zeroed(arena,Lrm_Cascade,1)
    if s==nil {return nil}
    casc:=&s[0]
    casc.arena=arena
    if !lrm_fill_cascade_setup(casc,buffer,buf_size,step,jump_bits_0,jump_bits_inc,base_chunk_size,
        hash_length) {
        lrm_destroy_cascade(casc)
        return nil
    }
    return casc
}

// A cascade over [buffer,buffer+buf_size) in chunks of base_chunk_size, filled as sets ask for it.
// Keeps arena for the fills. nil on invalid parameters or out of memory.
lrm_create_cascade_incremental :: proc(buffer:[^]u8,buf_size,step,jump_bits_0,jump_bits_inc,
    base_chunk_size,hash_length:int,arena:^entropy.Arena) -> ^Lrm_Cascade {
    return lrm_cascade_alloc(buffer,buf_size,step,jump_bits_0,jump_bits_inc,base_chunk_size,
        hash_length,arena)
}

lrm_destroy_cascade :: proc(casc:^Lrm_Cascade) {
    if casc==nil {return}
    arena:=casc.arena
    for level in 0..<LRM_CASCADE_MAX_LEVELS {
        for l in casc.lrms[level] {lrm_destroy(l,arena)}
        entropy.arena_free(arena,casc.lrms[level])
    }
    entropy.arena_free(arena,([^]Lrm_Cascade)(casc)[:1])
}

@(private="file")
lrm_cascade_get_set_by_chunk_index :: proc "contextless" (casc:^Lrm_Cascade,set:^Lrm_Set,
    chunk_index:int) {
    if set==nil {return}
    set.count=0
    if casc==nil {return}
    if chunk_index==0 {return}
    push :: proc "contextless" (set:^Lrm_Set,l:^Lrm) {
        if l!=nil && set.count<LRM_SET_MAX {set.lrms[set.count]=l;set.count+=1}
    }
    ci:=chunk_index
    for level:=0;level<LRM_CASCADE_MAX_LEVELS && ci!=0;level+=1 {
        if ci&1!=0 && ci-1<len(casc.lrms[level]) {push(set,casc.lrms[level][ci-1])}
        ci>>=1
    }
    if ci!=0 {
        top:=casc.lrms[LRM_CASCADE_MAX_LEVELS-1]
        for i:=2*ci-2-1;i>=0;i-=1 {
            if i<len(top) {push(set,top[i])}
        }
    }
}

@(private="file")
lrm_cascade_fill_until :: proc(casc:^Lrm_Cascade,chunk_index:int) -> bool {
    if casc==nil {return false}
    for chunk_index>casc.next_chunk && casc.next_chunk<casc.num_chunks {
        if !lrm_fill_cascade_increment(casc) {return false}
    }
    return true
}

@(private="file")
lrm_cascade_get_chunk_index_align :: proc "contextless" (casc:^Lrm_Cascade,start_ptr,
    parse_ptr:[^]u8) -> int {
    if casc==nil {return 0}
    start:=pdiff(start_ptr,casc.buffer)
    if start<=0 {return 0}
    chunk_up:=(start+casc.chunk_size-1)/casc.chunk_size
    start_up:=chunk_up*casc.chunk_size
    if start_up<=pdiff(parse_ptr,casc.buffer) && start_up<=casc.buf_size {return chunk_up}
    start=min(start,casc.buf_size)
    return start/casc.chunk_size
}

lrm_cascade_get_set_align_update_incremental :: proc(casc:^Lrm_Cascade,set:^Lrm_Set,start_ptr,
    parse_ptr:[^]u8) -> bool {
    ci:=lrm_cascade_get_chunk_index_align(casc,start_ptr,parse_ptr)
    ok:=lrm_cascade_fill_until(casc,ci)
    lrm_cascade_get_set_by_chunk_index(casc,set,ci)
    return ok
}

//===================================================================
// Scanners

// A nil or empty set makes a scanner that returns no matches.
lrm_scanner_init :: proc "contextless" (s:^Lrm_Scanner,set:^Lrm_Set,start_ptr,end_ptr:[^]u8,
    match_offset_limit:int) {
    s^={}
    if set!=nil && set.count>0 {
        s.set=set
        first:=set.lrms[0]
        s.hash_mul_end=first.hash_mul_end
        s.hash_length=first.hash_length
        s.end_ptr=uintptr(end_ptr)-uintptr(s.hash_length)
        s.match_offset_limit=match_offset_limit
        if uintptr(start_ptr)<s.end_ptr {
            s.hash=lrm_initial_hash(start_ptr,s.hash_length)
        } else {
            s.end_ptr=0
        }
    }
}

lrm_scanner_find_match_and_roll :: proc "contextless" (s:^Lrm_Scanner,ptr,ptrend:[^]u8,
    match_offset:^int) -> i32 {
    p:=uintptr(ptr)
    if p>s.end_ptr {return 0}
    lrm_len:int
    if s.last_ml_plus_ptr>=p+LRM_GOOD_ENOUGH_LEN {
        lrm_len=int(s.last_ml_plus_ptr-p)
        match_offset^=s.last_off
    } else {
        lrm_len=int(lrm_set_find_match(s.set,s.hash,ptr,ptrend,match_offset,s.match_offset_limit))
        if s.last_ml_plus_ptr>p+uintptr(lrm_len) {
            lrm_len=int(s.last_ml_plus_ptr-p)
            match_offset^=s.last_off
        }
        s.last_ml_plus_ptr=uintptr(lrm_len)+p
        s.last_off=match_offset^
    }
    if p<s.end_ptr {s.hash=lrm_roll_hash(s.hash,s.hash_mul_end,ptr[s.hash_length],ptr[0])}
    return i32(lrm_len)
}

// Finds matches LRM_SCANNER_WINDOW_SIZE ahead and extends them backwards into the window, so
// matches the stepped hashing missed are found. Must be called at consecutive positions.
lrm_scanner_windowed_init :: proc "contextless" (s:^Lrm_Scanner,set:^Lrm_Set,start_ptr,
    end_ptr:[^]u8,match_offset_limit:int) {
    lrm_scanner_init(s,set,start_ptr,end_ptr,match_offset_limit)
    s.base_ptr=uintptr(start_ptr)
    s.last_ptr=uintptr(start_ptr)
    s.window_base=uintptr(lrm_set_get_base_ptr(set))
    for i in 0..<LRM_SCANNER_WINDOW_SIZE {
        s.window_off[i]=0
        s.window_len[i]=lrm_scanner_find_match_and_roll(s,padd(start_ptr,i),end_ptr,
            &s.window_off[i])
    }
}

lrm_scanner_windowed_find_match_and_roll :: proc "contextless" (s:^Lrm_Scanner,ptr,ptrend:[^]u8,
    match_offset:^int) -> i32 #no_bounds_check {
    s.last_ptr+=1
    wi:=int(uintptr(ptr)-s.base_ptr)&(LRM_SCANNER_WINDOW_SIZE-1)
    ret:=s.window_len[wi]
    match_offset^=s.window_off[wi]
    window_ptr:=padd(ptr,LRM_SCANNER_WINDOW_SIZE)
    wl:=lrm_scanner_find_match_and_roll(s,window_ptr,ptrend,&s.window_off[wi])
    s.window_len[wi]=wl
    if wl>0 {
        woff:=s.window_off[wi]
        vs:=padd(window_ptr,-woff)
        for back in 1..<LRM_SCANNER_WINDOW_SIZE {
            if uintptr(vs)-uintptr(back)<s.window_base || uintptr(vs)<uintptr(back) {break}
            if padd(window_ptr,-back)[0]!=padd(vs,-back)[0] {break}
            bi:=(wi-back+LRM_SCANNER_WINDOW_SIZE)&(LRM_SCANNER_WINDOW_SIZE-1)
            if wl+i32(back)>s.window_len[bi] {
                s.window_len[bi]=wl+i32(back)
                s.window_off[bi]=woff
            }
        }
    }
    return ret
}
