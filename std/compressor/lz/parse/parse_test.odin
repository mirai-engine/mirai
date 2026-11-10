package parse

import "core:math/rand"
import "core:testing"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"
import "mirai:std/compressor"

@(private="file")
fill_input :: proc(buf:[]u8, kind:int, r:^rand.Generator) {
    switch kind {
    case 0: for &b in buf {b=u8(rand.uint32(r^))}
    case 1: for &b in buf {b=0}
    case 2: for &b,i in buf {b=u8(i*i>>7)}
    case:
        for i:=0;i<len(buf); {
            n:=min(len(buf)-i,1+int(rand.uint32(r^)%64))
            if i>=64 && rand.uint32(r^)%2==0 {
                off:=1+int(rand.uint32(r^)%u32(i))
                for k in 0..<n {buf[i+k]=buf[i+k-off]}
            } else {
                for k in 0..<n {buf[i+k]=u8(rand.uint32(r^)%8)}
            }
            i+=n
        }
    }
}

// Every level of this package, through setup and encode_chunk: valid chunks of each input kind,
// then hostile arguments (bad lengths and pointers, tiny output buffers) never crash and report
// expansion. A level above Normal is refused without its parser.
@(test)
hostile_inputs_never_crash :: proc(t:^testing.T) {
    r:=rand.create(7)
    gen:=rand.default_random_generator(&r)
    raw:=make([]u8,300*1024)
    defer delete(raw)
    pairs:=make([]match.Unpacked_Match_Pair,compressor.CHUNK_LEN*match.NEWLZ_MATCH_NUM_PAIRS)
    defer delete(pairs)
    comp:=make([]u8,compressor.CHUNK_LEN+4096)
    defer delete(comp)
    arena:=entropy.arena_make(context.allocator)
    levels:=[]i32{-4,-3,-2,-1,1,2,3,4}
    for kind in 0..<4 {
        fill_input(raw,kind,&gen)
        for level in levels {
            e:Encoder
            testing.expect(t,setup(&e,level,raw,&arena))
            for &p in pairs {p={i32(rand.uint32(gen)%300)-20,i32(rand.uint32(gen))}}
            ct:i32;J:f32
            for pos:=0;pos<len(raw);pos+=compressor.CHUNK_LEN {
                n:=min(compressor.CHUNK_LEN,len(raw)-pos)
                l:=encode_chunk(&e,&arena,raw_data(raw),raw_data(raw)[pos:],n,raw_data(comp),
                    raw_data(comp)[len(comp):],pos,&ct,&J,nil,raw_data(pairs))
                testing.expect(t,l>=0 && l<=n)
            }
            base:=raw_data(raw)
            testing.expect_value(t,encode_chunk(&e,&arena,base,base,-5,raw_data(comp),
                raw_data(comp)[64:],0,&ct,&J,nil,raw_data(pairs)),0)
            testing.expect_value(t,encode_chunk(&e,&arena,base,base,compressor.CHUNK_LEN+1,
                raw_data(comp),raw_data(comp)[64:],0,&ct,&J,nil,nil),compressor.CHUNK_LEN+1)
            testing.expect_value(t,encode_chunk(&e,&arena,base,base[len(raw)-100:],200,
                raw_data(comp),raw_data(comp)[len(comp):],0,&ct,&J,nil,raw_data(pairs)),200)
            testing.expect_value(t,encode_chunk(&e,&arena,base,base[2:],1000,raw_data(comp),
                raw_data(comp)[len(comp):],5,&ct,&J,nil,raw_data(pairs)),1000)
            testing.expect_value(t,encode_chunk(&e,&arena,base,base,1000,raw_data(comp)[10:],
                raw_data(comp),0,&ct,&J,nil,raw_data(pairs)),1000)
            l0:=encode_chunk(&e,&arena,base,base,1000,raw_data(comp),raw_data(comp)[len(comp):],0,
                nil,nil,nil,nil)
            testing.expect(t,l0>=0 && l0<=1000)
            for room in ([]int{0,1,7,8,9,16,40,100,1000}) {
                l:=encode_chunk(&e,&arena,base,base[compressor.CHUNK_LEN:],4096,raw_data(comp),
                    raw_data(comp)[room:],compressor.CHUNK_LEN,&ct,&J,nil,raw_data(pairs))
                testing.expect(t,l>=0 && l<=4096)
                testing.expect(t,l>=4096 || l<=room)
            }
            destroy(&e,&arena)
        }
    }
    e:Encoder
    testing.expect(t,!setup(&e,compressor.LEVEL_NONE,raw,&arena))
    testing.expect(t,!setup(&e,42,raw,&arena))
    testing.expect(t,!setup(&e,compressor.LEVEL_OPTIMAL1,raw,&arena))
    testing.expect(t,!setup(&e,compressor.LEVEL_OPTIMAL5,raw,&arena,optimal={setup=proc(e:^Encoder,
        arena:^entropy.Arena) -> bool {return true}}))
    testing.expect(t,!setup(&e,compressor.LEVEL_NORMAL,raw,nil))
    testing.expect_value(t,encode_chunk(nil,&arena,raw_data(raw),raw_data(raw),1000,raw_data(comp),
        raw_data(comp)[100:],0,nil,nil,nil,nil),1000)
}

// The same input encodes to the same bytes through a fresh encoder.
@(test)
encode_is_deterministic :: proc(t:^testing.T) {
    r:=rand.create(3)
    gen:=rand.default_random_generator(&r)
    raw:=make([]u8,200*1024)
    defer delete(raw)
    fill_input(raw,3,&gen)
    arena:=entropy.arena_make(context.allocator)
    for level in ([]i32{-2,1,3,4}) {
        out:[2][dynamic]u8
        for k in 0..<2 {
            e:Encoder
            testing.expect(t,setup(&e,level,raw,&arena))
            comp:=make([]u8,compressor.CHUNK_LEN+4096)
            for pos:=0;pos<len(raw);pos+=compressor.CHUNK_LEN {
                n:=min(compressor.CHUNK_LEN,len(raw)-pos)
                l:=encode_chunk(&e,&arena,raw_data(raw),raw_data(raw)[pos:],n,raw_data(comp),
                    raw_data(comp)[len(comp):],pos,nil,nil,nil,nil)
                append(&out[k],..comp[:min(l,n)])
            }
            delete(comp)
            destroy(&e,&arena)
        }
        testing.expect(t,string(out[0][:])==string(out[1][:]))
        delete(out[0]);delete(out[1])
    }
}
