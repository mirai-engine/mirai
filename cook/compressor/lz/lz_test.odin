package lz_optimal

import "core:math/rand"
import "core:mem"
import "core:testing"
import "mirai:std/compressor"
import "mirai:std/compressor/lz"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"
import "mirai:std/compressor/lz/parse"

// Sizes around the stored limit, one chunk, and several blocks; constant, noise, a short period
// and noise that alternates with a ramp.
@(private="file")
inputs :: proc() -> [][]u8 {
    out:=make([dynamic][]u8,context.temp_allocator)
    state:u32=0x9e3779b9
    for n in ([]int{1,256,257,4097,140000,600000}) {
        for kind in 0..<4 {
            b:=make([]u8,n,context.temp_allocator)
            for i in 0..<n {
                state=state*1664525+1013904223
                switch kind {
                case 0: b[i]=0xAB
                case 1: b[i]=u8(state>>24)
                case 2: b[i]=u8(i%5)
                case 3: b[i]=(i/700)%2==0 ? u8(state>>29) : u8(i>>4)
                }
            }
            append(&out,b)
        }
    }
    return out[:]
}

@(test)
every_level_repeats_itself_within_the_bound_and_decodes_to_its_input :: proc(t:^testing.T) {
    e:lz.Encoder
    testing.expect_value(t,lz.encoder_init(&e),lz.Error.None)
    defer lz.encoder_destroy(&e)
    d:compressor.Decoder
    testing.expect_value(t,compressor.decoder_init(&d),compressor.Error.None)
    defer compressor.decoder_destroy(&d)
    for src in inputs() {
        for level in Level {
            bound:=lz.compress_bound(len(src))
            a:=make([]u8,bound,context.temp_allocator)
            b:=make([]u8,bound,context.temp_allocator)
            na,ea:=lz.compress(&e,mode(level),src,a)
            nb,eb:=lz.compress(&e,mode(level),src,b)
            testing.expect_value(t,ea,lz.Error.None)
            testing.expect_value(t,eb,lz.Error.None)
            testing.expect(t,na>0 && na<=bound)
            testing.expect(t,na==nb && string(a[:na])==string(b[:nb]))
            out:=make([]u8,len(src),context.temp_allocator)
            written,de:=compressor.decompress(&d,a[:na],out)
            testing.expectf(t,de==.None && written==len(src) && string(out)==string(src),
                "%v of %d bytes: %v",level,len(src),de)
        }
    }
}

// The packs of a cook are levels of this package, and a stream in pieces is its pieces one after
// the other.
@(test)
the_packs_of_a_cook_write_pieces_that_decode_on_their_own :: proc(t:^testing.T) {
    e:lz.Encoder
    testing.expect_value(t,lz.encoder_init(&e),lz.Error.None)
    defer lz.encoder_destroy(&e)
    d:compressor.Decoder
    testing.expect_value(t,compressor.decoder_init(&d),compressor.Error.None)
    defer compressor.decoder_destroy(&d)
    PIECE :: compressor.BLOCK_LEN
    src:=make([]u8,2*PIECE+5000,context.temp_allocator)
    state:=u32(0x1234567)
    for &b,i in src {state=state*1664525+1013904223;b=(i/3000)%2==0 ? u8(state>>29) : u8(i>>6)}
    for pack in ([]lz.Mode{QUICK,SHIP}) {
        dst:=make([]u8,lz.compress_bound(len(src)),context.temp_allocator)
        n,err:=lz.compress(&e,pack,src,dst,PIECE)
        testing.expect_value(t,err,lz.Error.None)
        found:[4]compressor.Piece
        count,scan:=compressor.pieces(dst[:n],len(src),found[:])
        testing.expect(t,scan==.None && count==3)
        at:=0
        for piece,i in found[:min(count,len(found))] {
            from:=src[i*PIECE:min(len(src),(i+1)*PIECE)]
            alone:=make([]u8,lz.compress_bound(len(from)),context.temp_allocator)
            size,piece_error:=lz.compress_piece(&e,pack,from,alone)
            testing.expect(t,piece_error==.None && piece.src==at && string(alone[:size])==string(dst[at:][:size]))
            out:=make([]u8,len(from),context.temp_allocator)
            written,de:=compressor.decompress(&d,alone[:size],out)
            testing.expectf(t,de==.None && written==len(out) && string(out)==string(from),"piece %d: %v",i,de)
            at+=size
        }
        testing.expect_value(t,at,n)
    }
}

@(test)
running_out_of_memory_returns_an_error :: proc(t:^testing.T) {
    src:=make([]u8,300000,context.temp_allocator)
    for i in 0..<len(src) {src[i]=u8((i*i)>>9)}
    dst:=make([]u8,lz.compress_bound(len(src)),context.temp_allocator)
    for size in ([]int{1000,400000,1200000,3000000,20000000}) {
        backing:=make([]u8,size,context.temp_allocator)
        for level in ([]Level{.Optimal1,.Optimal2,.Optimal4}) {
            a:mem.Arena
            mem.arena_init(&a,backing)
            e:lz.Encoder
            lz.encoder_init(&e,mem.arena_allocator(&a))
            _,err:=lz.compress(&e,mode(level),src,dst)
            testing.expect(t,err==.None || err==.Out_Of_Memory)
        }
    }
}

// The parse of every level over match pairs that no finder would give, and into outputs with no
// room: it never reads or writes outside its buffers and reports expansion.
@(test)
garbage_match_pairs_and_tiny_outputs_never_crash_the_parse :: proc(t:^testing.T) {
    r:=rand.create(7)
    gen:=rand.default_random_generator(&r)
    raw:=make([]u8,300*1024)
    defer delete(raw)
    pairs:=make([]match.Unpacked_Match_Pair,compressor.CHUNK_LEN*match.NEWLZ_MATCH_NUM_PAIRS)
    defer delete(pairs)
    comp:=make([]u8,compressor.CHUNK_LEN+4096)
    defer delete(comp)
    arena:=entropy.arena_make(context.allocator)
    base:=raw_data(raw)
    for kind in 0..<3 {
        for &b,i in raw {
            switch kind {
            case 0: b=u8(rand.uint32(gen))
            case 1: b=0
            case 2: b=u8(i*i>>7)
            }
        }
        for level in Level {
            e:parse.Encoder
            testing.expect(t,parse.setup(&e,i32(level),raw,&arena,optimal=mode(level).parser))
            for &p in pairs {p={i32(rand.uint32(gen)%300)-20,i32(rand.uint32(gen))}}
            ct:i32;J:f32
            for pos:=0;pos<len(raw);pos+=compressor.CHUNK_LEN {
                n:=min(compressor.CHUNK_LEN,len(raw)-pos)
                l:=parse.encode_chunk(&e,&arena,base,base[pos:],n,raw_data(comp),
                    raw_data(comp)[len(comp):],pos,&ct,&J,nil,raw_data(pairs))
                testing.expect(t,l>=0 && l<=n)
            }
            testing.expect_value(t,parse.encode_chunk(&e,&arena,base,base,1000,raw_data(comp),
                raw_data(comp)[len(comp):],0,nil,nil,nil,nil),1000)
            for room in ([]int{0,1,7,8,9,16,40,100,1000}) {
                l:=parse.encode_chunk(&e,&arena,base,base[compressor.CHUNK_LEN:],4096,
                    raw_data(comp),raw_data(comp)[room:],compressor.CHUNK_LEN,&ct,&J,nil,
                    raw_data(pairs))
                testing.expect(t,l>=0 && l<=4096)
                testing.expect(t,l>=4096 || l<=room)
            }
            parse.destroy(&e,&arena)
        }
    }
}
