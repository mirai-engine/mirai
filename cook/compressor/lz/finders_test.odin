package lz_optimal

import "core:testing"
import "core:math/rand"
import "base:runtime"
import "mirai:std/compressor"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"

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
pairs_valid :: proc(data:[]u8,at:int,pairs:[]match.Unpacked_Match_Pair) -> bool {
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
    N :: match.NEWLZ_MATCH_NUM_PAIRS
    pairs:=make([]match.Unpacked_Match_Pair,compressor.BLOCK_LEN*N)
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
    short:[8]match.Unpacked_Match_Pair
    testing.expect_value(t,incremental_process_chunk(f,16,short[:],2),-1)
    testing.expect_value(t,incremental_process_chunk(f,4,short[:],1),-1)
    testing.expect_value(t,incremental_process_chunk(f,-1,short[:],2),-1)
    testing.expect_value(t,incremental_process_chunk(f,4,short[:],2),4)
    incremental_release(&f,&arena)
}

// Greedy parse over each table configuration the codecs use: every match it reports is real.
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
