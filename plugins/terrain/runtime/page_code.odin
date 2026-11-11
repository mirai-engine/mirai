package terrain

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/codec"

// The values of a page as its block holds them, before LZ: one coding for
// the file, the blocks of pages that leave memory and the pages the network
// sends.

// The step of the heights a .terrain stores, in meters: each is saved as the
// nearest multiple, at most half a step away. A power of two, so a height read
// from a file is saved again as it is and edits do not drift.
HEIGHT_STEP :: 1.0/1024

// The first byte of a coded page.
@(private)
Page_Code :: enum u8 {
    Values, // the values as they are
    // f32 on multiples of HEIGHT_STEP: each one's distance in steps from the plane of its
    // neighbors left, above and above-left, zigzag, in byte planes.
    Lattice,
}

// The code, the bytes of a value and the values of a row (u16), before the values.
@(private) PAGE_HEADER :: 4
// The most bytes a coded page takes: what terrain_page_bytes writes.
PAGE_BYTES_MAX :: PAGE_HEADER+PAGE_VALUES*4

// Where a height lands on the lattice of HEIGHT_STEP.
@(private)
lattice_step :: #force_inline proc "contextless" (value:f32) -> i32 {return i32(math.round(f64(value)*(1/HEIGHT_STEP)))}

@(private)
lattice_value :: #force_inline proc "contextless" (step:i32) -> f32 {return f32(step)*HEIGHT_STEP}

// The height a file holds for value: the nearest multiple of HEIGHT_STEP.
height_quantize :: proc "contextless" (value:f32) -> f32 {return lattice_value(lattice_step(value))}

// Whether every value is, bit for bit, the multiple of HEIGHT_STEP it lands on.
@(private)
page_on_lattice :: proc "contextless" (values:[]f32) -> bool {
    for value in values {
        if !(abs(value)<1<<20) || transmute(u32)lattice_value(lattice_step(value))!=transmute(u32)value {return false}
    }
    return true
}

// The values of a page, in rows of width, coded into out, which has
// PAGE_HEADER bytes more than they. quantize puts f32 values on the lattice
// of HEIGHT_STEP; otherwise a page goes as Lattice only when every value
// already is on it, and comes back the same.
@(private)
page_code :: proc(values:[]$T,width:int,quantize:bool,out:[]u8) -> []u8 {
    n:=len(values)
    coded:=out[:PAGE_HEADER+n*size_of(T)]
    code:=Page_Code.Values
    when T==f32 {
        if width>=1 && width<=PAGE && n%width==0 && (quantize || page_on_lattice(values)) {code=.Lattice}
    }
    coded[0],coded[1],coded[2],coded[3]=u8(code),size_of(T),u8(width),u8(width>>8)
    body:=coded[PAGE_HEADER:]
    when T==f32 {
        if code==.Lattice {
            put :: #force_inline proc "contextless" (body:[]u8,n,k:int,q,predicted:u32) {
                d:=i32(q-predicted)
                z:=u32(d<<1)~u32(d>>31)
                body[k],body[n+k],body[2*n+k],body[3*n+k]=u8(z),u8(z>>8),u8(z>>16),u8(z>>24)
            }
            left,up,upleft:u32
            for k in 0..<n {
                q:=u32(lattice_step(values[k]))
                if k<width {
                    put(body,n,k,q,left)
                } else {
                    up=u32(lattice_step(values[k-width]))
                    put(body,n,k,q,k%width==0?up:left+up-upleft)
                }
                left,upleft=q,up
                if (k+1)%width==0 {left=0}
            }
            return coded
        }
    }
    copy(body,mem.slice_to_bytes(values))
    return coded
}

// The values of a coded page into out: false when coded is not a page of
// that many bytes.
@(private)
page_uncode :: proc(coded,out:[]u8) -> bool #no_bounds_check {
    if len(coded)!=PAGE_HEADER+len(out) {return false}
    size,width:=int(coded[1]),int(coded[2])|int(coded[3])<<8
    if size<1 || size>4 || len(out)%size!=0 {return false}
    n:=len(out)/size
    body:=coded[PAGE_HEADER:]
    switch coded[0] {
    case u8(Page_Code.Values):
        copy(out,body)
        return true
    case u8(Page_Code.Lattice):
        if size!=4 || width<1 || width>n || n%width!=0 {return false}
        // The steps first, as u32 in out, then their heights in their place.
        steps:=([^]u32)(raw_data(out))
        residual :: #force_inline proc "contextless" (body:[]u8,n,k:int) -> u32 #no_bounds_check {
            z:=u32(body[k])|u32(body[n+k])<<8|u32(body[2*n+k])<<16|u32(body[3*n+k])<<24
            return (z>>1)~(0-(z&1))
        }
        left:u32
        for k in 0..<width {
            left+=residual(body,n,k)
            intrinsics.unaligned_store(&steps[k],left)
        }
        for first:=width;first<n;first+=width {
            up:=intrinsics.unaligned_load(&steps[first-width])
            left=up+residual(body,n,first)
            intrinsics.unaligned_store(&steps[first],left)
            upleft:=up
            for k in first+1..<first+width {
                up=intrinsics.unaligned_load(&steps[k-width])
                left=left+up-upleft+residual(body,n,k)
                intrinsics.unaligned_store(&steps[k],left)
                upleft=up
            }
        }
        heights:=([^]f32)(raw_data(out))
        for k in 0..<n {intrinsics.unaligned_store(&heights[k],lattice_value(i32(intrinsics.unaligned_load(&steps[k]))))}
        return true
    }
    return false
}

// What reading the block of a page works in: room for the block and for its
// coded values, and the decoder of its LZ.
@(private)
Page_Reader :: struct {block:[]u8,coded:[]u8,decoder:asset.Stream_Decoder}

// The most a block of a page takes, whatever compresses it.
@(private)
PAGE_BLOCK_MAX :: PAGE_BYTES_MAX+PAGE_BYTES_MAX/16+256

// What the blocks of the pages of a source are read and written with: a game shipped with a
// plugin's codecs names them; the zero value is LZ when the program has it.
Page_Codecs :: struct {table:^codec.Table,writes:^asset.Pack_Codecs}

@(private)
page_reader_init :: proc(r:^Page_Reader,allocator:runtime.Allocator,codecs:Page_Codecs) -> bool {
    r^={}
    error:runtime.Allocator_Error
    if r.block,error=make([]u8,PAGE_BLOCK_MAX,allocator);error!=nil {return false}
    if r.coded,error=make([]u8,PAGE_BYTES_MAX,allocator);error!=nil || asset.stream_decoder_init(&r.decoder,allocator,codecs.table)!=.None {
        delete(r.block,allocator)
        delete(r.coded,allocator)
        r^={}
        return false
    }
    return true
}

@(private)
page_reader_destroy :: proc(r:^Page_Reader,allocator:runtime.Allocator) {
    delete(r.block,allocator)
    delete(r.coded,allocator)
    asset.stream_decoder_destroy(&r.decoder)
    r^={}
}

// The coded values of a block into all of coded: false when the block is not
// the one hashed or does not hold that many.
@(private)
page_unpack :: proc(block:[]u8,hash:u64,coded:[]u8,decoder:^asset.Stream_Decoder) -> bool {
    return base.hash64(block)==hash && asset.unpack(decoder,block,coded)==.None
}

// The values of a block into out, those of its page, through coded, of
// PAGE_BYTES_MAX bytes: false when the block is not the one hashed or does
// not hold them.
@(private)
page_decode :: proc(block:[]u8,hash:u64,out:[]u8,decoder:^asset.Stream_Decoder,coded:[]u8) -> bool {
    if PAGE_HEADER+len(out)>len(coded) {return false}
    page:=coded[:PAGE_HEADER+len(out)]
    return page_unpack(block,hash,page,decoder) && page_uncode(page,out)
}

// What coding a page into a block works in: the LZ encoder, and room for
// the coded values and for the block.
@(private)
Page_Writer :: struct {encoder:asset.Block_Encoder,coded:[]u8,block:[]u8,allocator:runtime.Allocator}

@(private)
page_writer_init :: proc(w:^Page_Writer,allocator:runtime.Allocator,writes:^asset.Pack_Codecs) -> bool {
    w^={allocator=allocator}
    error:runtime.Allocator_Error
    if w.coded,error=make([]u8,PAGE_BYTES_MAX,allocator);error!=nil {return false}
    if w.block,error=make([]u8,asset.block_bound(writes,PAGE_BYTES_MAX),allocator);error!=nil {
        delete(w.coded,allocator)
        w^={}
        return false
    }
    asset.block_encoder_init(&w.encoder,allocator,writes)
    return true
}

@(private)
page_writer_destroy :: proc(w:^Page_Writer) {
    if w.coded==nil {return}
    asset.block_encoder_destroy(&w.encoder)
    delete(w.coded,w.allocator)
    delete(w.block,w.allocator)
    w^={}
}

// The block of the values of a page in rows of width, in w until the next
// call; quantize as page_code.
@(private)
page_encode :: proc(w:^Page_Writer,values:[]$T,width:int,quantize:bool) -> (block:[]u8,ok:bool) {
    size,error:=asset.block_encode(&w.encoder,asset.PACK_EDIT,page_code(values,width,quantize,w.coded),w.block)
    return w.block[:size],error==.None
}
