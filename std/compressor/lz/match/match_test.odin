package match

import "core:testing"
import "core:math/rand"
import "base:intrinsics"
import "base:runtime"
import "mirai:std/compressor"
import "mirai:std/compressor/lz/entropy"

@(private="file")
make_input :: proc(size,pattern:int,gen:runtime.Random_Generator) -> []u8 {
    d:=make([]u8,size)
    for i in 0..<size {
        switch pattern {
        case 0: d[i]=0
        case 1: d[i]=u8(rand.uint32(gen))
        case 2: d[i]=u8(i%3)
        case 3: d[i]=i<size/2?u8(rand.uint32(gen)&7):d[i-size/2]
        }
    }
    return d
}

// The pairs of one position: decreasing lengths, offsets inside the buffer and matching bytes
// (the first and last 32 of each match).
@(private="file")
pairs_valid :: proc(data:[]u8,at:int,pairs:[]Unpacked_Match_Pair) -> bool {
    prev:=max(i32)
    for m in pairs {
        if m.length==0 {break}
        if m.length<0 || m.length>prev || m.offset<1 || int(m.offset)>at {return false}
        l:=min(int(m.length),len(data)-at)
        for j in 0..<min(l,64) {
            i:=j<32?j:l-64+j
            if data[at+i]!=data[at+i-int(m.offset)] {return false}
        }
        prev=m.length
    }
    return true
}

// Every reported pair points inside the buffer, before the position, at bytes that match.
@(test)
finders_hostile_inputs :: proc(t:^testing.T) {
    r:=rand.create(7)
    gen:=runtime.default_random_generator(&r)
    arena:=entropy.arena_make(context.allocator)
    sizes:=[?]int{1,2,3,4,5,8,9,12,17,64,1000,65537,262145}
    N :: NEWLZ_MATCH_NUM_PAIRS
    pairs:=make([]Unpacked_Match_Pair,compressor.BLOCK_LEN*N)
    defer delete(pairs)
    for kind in ([?]Finder_Kind{.Ctmf_Find_All,.Suffix_Trie}) {
        for size in sizes {
            for pattern in 0..<4 {
                if size==262145 && pattern>1 {continue}
                data:=make_input(size,pattern,gen)
                defer delete(data)
                for start in ([?]int{0,size/3}) {
                    f:=incremental_create(kind,raw_data(data),size,start,nil,&arena)
                    testing.expect(t,f!=nil)
                    pos:=start
                    for {
                        n:=incremental_process_chunk(f,size>65537?compressor.BLOCK_LEN:7777,pairs,N)
                        testing.expect(t,n>=0)
                        if n<=0 {break}
                        for p in 0..<n {
                            if !pairs_valid(data,pos+p,pairs[p*N:][:N]) {
                                testing.expectf(t,false,"%v size %d pattern %d: bad pairs at %d",
                                    kind,size,pattern,pos+p)
                                return
                            }
                        }
                        pos+=n
                    }
                    testing.expect_value(t,pos,size)
                    incremental_release(&f,&arena)
                    testing.expect(t,f==nil)
                }
            }
        }
    }
}

@(test)
finders_reject_invalid :: proc(t:^testing.T) {
    arena:=entropy.arena_make(context.allocator)
    data:=[16]u8{}
    testing.expect(t,incremental_create(.Suffix_Trie,raw_data(data[:]),0,0,nil,&arena)==nil)
    testing.expect(t,incremental_create(.Ctmf_Find_All,raw_data(data[:]),16,16,nil,&arena)==nil)
    testing.expect(t,incremental_create(.Ctmf_Find_All,nil,16,0,nil,&arena)==nil)
    testing.expect(t,incremental_create(.None,raw_data(data[:]),16,0,nil,&arena)==nil)
    f:=incremental_create(.Suffix_Trie,raw_data(data[:]),16,0,nil,&arena)
    short:[8]Unpacked_Match_Pair
    testing.expect_value(t,incremental_process_chunk(f,16,short[:],2),-1)
    testing.expect_value(t,incremental_process_chunk(f,4,short[:],1),-1)
    testing.expect_value(t,incremental_process_chunk(f,-1,short[:],2),-1)
    testing.expect_value(t,incremental_process_chunk(f,4,short[:],2),4)
    incremental_release(&f,&arena)
}

// Greedy parse over each table configuration the codecs use: every match it reports is real.
@(private="file")
ctmf_parse :: proc(t:^testing.T,c:^$C,data:[]u8,arena:^entropy.Arena) -> int {
    testing.expect(t,allocate(c,16,16,16,arena,0))
    defer release(c,arena)
    base:=raw_data(data)
    half:=len(data)/2
    set_base_and_preload(c,base,padd(base,half),half)
    end:=len(data)-8
    found:=0
    when intrinsics.type_is_specialization_of(C,Ctmf) {
        ctmf_set_next(c,padd(base,half))
        for pos:=half;pos<end; {
            ptr:=padd(base,pos)
            row,row2,hash:=c.next_row,c.next_row_second,c.next_hash
            ctmf_set_next(c,padd(ptr,1))
            cand:[32]u32
            mask:=ctmf_find_candidates(c,raw_data(cand[:]),row,row2,u32(pos),hash)
            ctmf_insert(c,row,u32(pos),hash)
            best,best_off:=0,0
            for d in 0..<32 {
                if mask&(1<<uint(d))==0 {continue}
                off:=int(cand[d])
                if off==0 || off>pos {continue}
                l:=getmatchlen_mml4(ptr,padd(ptr,-off),padd(base,len(data)))
                if l>best {best,best_off=l,off}
            }
            if best>=4 && pos+best<end {
                found+=1
                for i in 0..<best {testing.expect(t,data[pos+i]==data[pos+i-best_off])}
                ctmf_step_and_insert(c,ptr,best)
                pos+=best
            } else {
                pos+=1
            }
        }
    } else {
        for pos:=half;pos<end;pos+=1 {
            ptr:=padd(base,pos)
            prev:=int(fast_ctmf_insert(raw_data(c.hash_table),ptr,c.hash_mul,c.hash_shift,pos))
            off:=pos-prev
            if prev!=0 && off>0 && getmatchlen_mml4(ptr,padd(ptr,-off),padd(base,
                len(data)))>=4 {found+=1}
        }
    }
    return found
}


@(test)
ctmf_tables_find_real_matches :: proc(t:^testing.T) {
    r:=rand.create(3)
    gen:=runtime.default_random_generator(&r)
    data:=make_input(1<<16,3,gen)
    defer delete(data)
    arena:=entropy.arena_make(context.allocator)
    {c:Ctmf(u32,2,8,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Ctmf(u32,1,0,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Ctmf(u32,3,0,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Ctmf(u32,4,8,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Ctmf(u32,0,0,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Ctmf(u16,1,0,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>=0)}
    {c:Ctmf(u16,0,0,4);testing.expect(t,ctmf_parse(t,&c,data,&arena)>=0)}
    {c:Fast_Ctmf(u32);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
    {c:Fast_Ctmf(u16);testing.expect(t,ctmf_parse(t,&c,data,&arena)>0)}
}

// Matches of the second half against an LRM set over the first: found, real and in range.
@(test)
lrm_scanner_finds_far_matches :: proc(t:^testing.T) {
    r:=rand.create(11)
    gen:=runtime.default_random_generator(&r)
    CHUNK :: 1<<18
    data:=make([]u8,3*CHUNK)
    defer delete(data)
    for i in 0..<len(data) {
        data[i]=i>=2*CHUNK && i%4096<2048?data[i-2*CHUNK+77]:u8(rand.uint32(gen))
    }
    arena:=entropy.arena_make(context.allocator)
    casc:=lrm_create_cascade_incremental(raw_data(data),2*CHUNK,LRM_STEP,LRM_JUMP_BITS,0,CHUNK,
        LRM_HASH_LENGTH,&arena)
    testing.expect(t,casc!=nil)
    defer lrm_destroy_cascade(casc)
    set:Lrm_Set
    testing.expect(t,lrm_cascade_get_set_align_update_incremental(casc,&set,&data[2*CHUNK],
        &data[2*CHUNK]))
    testing.expect_value(t,set.count,1)
    s:Lrm_Scanner
    end:=padd(raw_data(data),len(data))
    lrm_scanner_windowed_init(&s,&set,&data[2*CHUNK],end,compressor.MAX_OFFSET)
    found:=0
    for p in 2*CHUNK..<len(data) {
        off:int
        l:=lrm_scanner_windowed_find_match_and_roll(&s,&data[p],end,&off)
        if l<=0 {continue}
        found+=1
        if !testing.expect(t,off>p-2*CHUNK && off<=p && p+int(l)<=len(data)) {return}
        for i in 0..<int(l) {
            if data[p+i]!=data[p+i-off] {testing.expectf(t,false,"bad lrm match at %d",p);return}
        }
    }
    testing.expect(t,found>CHUNK/4)
}

@(test)
stdsort_sorts_with_ties :: proc(t:^testing.T) {
    r:=rand.create(5)
    gen:=runtime.default_random_generator(&r)
    less :: proc "contextless" (a,b:Lrm_Entry) -> bool {return a.hash<b.hash}
    for n in ([?]int{0,1,2,3,4,5,6,7,100,1000,20000}) {
        for range in ([?]u32{1,3,1<<30}) {
            a:=make([]Lrm_Entry,n)
            defer delete(a)
            sum:=0
            for i in 0..<n {a[i]=Lrm_Entry{rand.uint32(gen)%range,u32(i)};sum+=i}
            entropy.stdsort(a,less)
            got:=0
            for i in 0..<n {
                got+=int(a[i].pos32)
                if i>0 {testing.expect(t,a[i-1].hash<=a[i].hash)}
            }
            testing.expect_value(t,got,sum)
        }
    }
}
