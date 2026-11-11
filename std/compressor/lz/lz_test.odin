package lz

import "core:mem"
import "core:testing"
import "mirai:std/compressor"
import "mirai:std/compressor/lz/entropy"

@(private="file")
inputs :: proc() -> [][]u8 {
    out:=make([dynamic][]u8,context.temp_allocator)
    state:u32=0x9e3779b9
    for n in ([]int{1,2,31,256,257,300,4097,140000,300000}) {
        for kind in 0..<4 {
            b:=make([]u8,n,context.temp_allocator)
            for i in 0..<n {
                state=state*1664525+1013904223
                switch kind {
                case 0: b[i]=0xAB
                case 1: b[i]=u8(state>>24)
                case 2: b[i]=u8(i%5)
                case 3: b[i]=(i/700)%2==0 ? u8(state>>24) : u8(i>>4)
                }
            }
            append(&out,b)
        }
    }
    return out[:]
}

@(test)
every_level_repeats_itself_within_the_bound_and_decodes_to_its_input :: proc(
    t:^testing.T,
) {
    e:Encoder
    testing.expect_value(t,encoder_init(&e),Error.None)
    defer encoder_destroy(&e)
    d:compressor.Decoder
    testing.expect_value(t,compressor.decoder_init(&d),compressor.Error.None)
    defer compressor.decoder_destroy(&d)
    for src in inputs() {
        for level in Level {
            bound:=compress_bound(len(src))
            a:=make([]u8,bound,context.temp_allocator)
            b:=make([]u8,bound,context.temp_allocator)
            na,ea:=compress(&e,mode(level),src,a)
            nb,eb:=compress(&e,mode(level),src,b)
            testing.expect_value(t,ea,Error.None)
            testing.expect_value(t,eb,Error.None)
            testing.expect(t,na>0 && na<=bound)
            testing.expect(t,na==nb && string(a[:na])==string(b[:nb]))
            out:=make([]u8,len(src),context.temp_allocator)
            written,de:=compressor.decompress(&d,a[:na],out)
            testing.expectf(t,de==.None && written==len(src) && string(out)==string(src),
                "%v of %d bytes: %v",level,len(src),de)
        }
    }
}

@(test)
hostile_arguments_return_errors :: proc(t:^testing.T) {
    e:Encoder
    encoder_init(&e)
    defer encoder_destroy(&e)
    src:=make([]u8,70000,context.temp_allocator)
    for i in 0..<len(src) {src[i]=u8(i*7>>3)}
    n,err:=compress(&e,mode(.Normal),nil,nil)
    testing.expect(t,n==0 && err==.None)
    n,err=compress(nil,mode(.Normal),src,nil)
    testing.expect_value(t,err,Error.Invalid)
    // No level, a level that does not exist and a level above Normal without its parser.
    for level in ([]i32{0,12,-1,compressor.LEVEL_OPTIMAL1,compressor.LEVEL_OPTIMAL5}) {
        n,err=compress(&e,Mode{level=level},src,make([]u8,compress_bound(len(src)),context.temp_allocator))
        testing.expect(t,n==0 && err==.Invalid)
    }
    // The blocks of a framing that has no input or output, outside them, or that was not set up.
    f:Framing
    testing.expect_value(t,compress_sub(nil,0,100,0),-1)
    testing.expect_value(t,compress_sub(&f,0,100,0),-1)
    arena:=entropy.arena_make(context.temp_allocator)
    f.arena=&arena
    f.parser.raw=src
    f.output=make([]u8,compress_bound(1000),context.temp_allocator)
    for c in ([][3]int{{0,0,0},{-1,10,0},{len(src)-10,11,0},{0,1001,0},{0,1000,1},{0,10,-1},{0,1000,0}}) {
        testing.expect_value(t,compress_sub(&f,c[0],c[1],c[2]),-1)
    }
    // Noise, which no level packs into the smallest of these.
    noise:=make([]u8,70000,context.temp_allocator)
    state:=u32(0x2545f491)
    for &b in noise {state=state*1664525+1013904223;b=u8(state>>24)}
    for size in ([]int{0,1,10,150}) {
        dst:=make([]u8,size,context.temp_allocator)
        n,err=compress(&e,mode(.Fast),noise,dst)
        testing.expect_value(t,err,Error.Output_Too_Small)
        n,err=compress(&e,mode(.SuperFast),src[:200],dst)
        testing.expect_value(t,err,Error.Output_Too_Small)
    }
}

@(test)
running_out_of_memory_returns_an_error :: proc(t:^testing.T) {
    src:=make([]u8,300000,context.temp_allocator)
    for i in 0..<len(src) {src[i]=u8((i*i)>>9)}
    dst:=make([]u8,compress_bound(len(src)),context.temp_allocator)
    for size in ([]int{1000,400000,1200000,3000000}) {
        backing:=make([]u8,size,context.temp_allocator)
        for level in ([]Level{.SuperFast,.Normal}) {
            a:mem.Arena
            mem.arena_init(&a,backing)
            e:Encoder
            encoder_init(&e,mem.arena_allocator(&a))
            _,err:=compress(&e,mode(level),src,dst)
            testing.expect(t,err==.None || err==.Out_Of_Memory)
        }
    }
}

// With piece_len each piece is a stream of its own that decodes alone, the last one even when it
// is smaller than the stored size; a piece_len that is not a multiple of the block is refused.
@(test)
pieces_decode_on_their_own :: proc(t:^testing.T) {
    e:Encoder
    testing.expect_value(t,encoder_init(&e),Error.None)
    defer encoder_destroy(&e)
    d:compressor.Decoder
    testing.expect_value(t,compressor.decoder_init(&d),compressor.Error.None)
    defer compressor.decoder_destroy(&d)
    PIECE :: compressor.BLOCK_LEN
    for tail in ([]int{0,100,5000}) {
        src:=make([]u8,2*PIECE+tail,context.temp_allocator)
        state:=u32(0x1234567)
        for &b,i in src {state=state*1664525+1013904223;b=(i/3000)%2==0 ? u8(state>>29) : u8(i>>6)}
        for level in ([]Level{.SuperFast,.Normal}) {
            dst:=make([]u8,compress_bound(len(src)),context.temp_allocator)
            n,err:=compress(&e,mode(level),src,dst,PIECE)
            testing.expect_value(t,err,Error.None)
            found:[4]compressor.Piece
            count,scan:=compressor.pieces(dst[:n],len(src),found[:])
            testing.expect_value(t,scan,compressor.Error.None)
            testing.expect_value(t,count,tail>0 ? 3 : 2)
            for piece,i in found[:min(count,len(found))] {
                testing.expect_value(t,piece.dst,i*PIECE)
                src_end,dst_end:=n,len(src)
                if i+1<count {src_end,dst_end=found[i+1].src,found[i+1].dst}
                out:=make([]u8,dst_end-piece.dst,context.temp_allocator)
                written,de:=compressor.decompress(&d,dst[piece.src:src_end],out)
                testing.expectf(t,de==.None && written==len(out) && string(out)==string(src[piece.dst:dst_end]),
                    "%v, piece %d of %d: %v",level,i,count,de)
            }
            // A piece_len past the input is the stream without pieces.
            one:=make([]u8,len(dst),context.temp_allocator)
            plain:=make([]u8,len(dst),context.temp_allocator)
            a,_:=compress(&e,mode(level),src,one,4*PIECE)
            b,_:=compress(&e,mode(level),src,plain)
            testing.expect(t,a>0 && string(one[:a])==string(plain[:b]))
        }
    }
    n,err:=compress(&e,mode(.Normal),make([]u8,1000,context.temp_allocator),make([]u8,2000,context.temp_allocator),100)
    testing.expect(t,n==0 && err==.Invalid)
}
