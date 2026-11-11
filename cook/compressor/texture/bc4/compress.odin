package bc4

import "core:math"
import "core:simd"
import "mirai:cook/compressor/texture/common"

// BC4 blocks (the alpha of BC3, BC4 and each half of BC5): two 8-bit
// endpoints and a 3-bit index per texel into a palette of eight values, six
// interpolated when e0 > e1, four plus the two extremes otherwise.
//
// Unsigned values work in a fixed point where 0x1000 is 1.0, finer than the
// 8-bit endpoints so the interpolated values can be told apart; BC3 alpha
// decodes to 8 bits and keeps its values as they are.

// How the 16 values of a block are interpreted.
Value_Type :: enum u8 {UNorm, Alpha}

// Values in [0,0x1000] (UNorm) or [0,0xff] (Alpha).
Source_Data :: struct {
    values:[16]i16,
    type:Value_Type,
}

// What `from` holds per block: 16 u16 (BC4), 16 pairs of u16 (BC5, whose
// halves go to bytes 0..7 and 8..15 of each output block) or 16 RGBA8 texels
// of which only the alpha is encoded (the alpha of BC3; also BGRA8).
Source :: enum u8 {R16, RG16, RGBA8_Alpha}

INIT_ERROR :: 0x7fffffff
SCALE_BITS :: 12

Block :: struct {
    e0,e1:int,
    inds:[16]u8,
}

source_bytes :: #force_inline proc "contextless" (s:Source) -> int {
    return s==.R16 ? 32 : 64
}

block_bytes :: #force_inline proc "contextless" (s:Source) -> int {
    return s==.RG16 ? 16 : 8
}

// The 16-bit value the blit of the library makes of an 8-bit one: v/255 in
// floats, times 65535 and rounded, which is exactly v*257.
unorm8_to_unorm16 :: #force_inline proc "contextless" (v:u8) -> u16 {
    return u16(v)*257
}

@(private)
I16x16 :: #simd[16]i16
@(private)
U16x16 :: #simd[16]u16

@(private)
read_u16 :: #force_inline proc "contextless" (b:[]u8,i:int) -> u16 {
    return u16(b[i])|u16(b[i+1])<<8
}

@(private)
convert_u16 :: #force_inline proc "contextless" (v:u16) -> i16 {
    return i16(((int(v)<<SCALE_BITS)+32768)/65535)
}

// One BC4 source from 16 u16 (R16), the red of 16 pairs (RG16) or 16 RGBA8
// texels (RGBA8_Alpha); src must hold source_bytes(format) bytes.
read_source :: proc "contextless" (src:[]u8,format:Source) -> (d:Source_Data) {
    switch format {
    case .R16:
        d.type=.UNorm
        for i in 0..<16 {d.values[i]=convert_u16(read_u16(src,i*2))}
    case .RG16:
        d.type=.UNorm
        for i in 0..<16 {d.values[i]=convert_u16(read_u16(src,i*4))}
    case .RGBA8_Alpha:
        d.type=.Alpha
        for i in 0..<16 {d.values[i]=i16(src[i*4+3])}
    }
    return
}

// The red and green sources of a BC5 block of 16 pairs of u16.
read_source_bc5 :: proc "contextless" (src:[]u8) -> (r,g:Source_Data) {
    r.type=.UNorm
    g.type=.UNorm
    for i in 0..<16 {
        r.values[i]=convert_u16(read_u16(src,i*4))
        g.values[i]=convert_u16(read_u16(src,i*4+2))
    }
    return
}

@(private)
maximum :: #force_inline proc "contextless" ($k:Value_Type) -> int {
    when k==.UNorm {return 1<<SCALE_BITS} else {return 255}
}

@(private)
good_enough_ssd :: #force_inline proc "contextless" ($k:Value_Type) -> u32 {
    // About 3/4 of the step between adjacent 8-bit endpoints, squared.
    when k==.UNorm {return 12*12} else {return 0}
}

@(private)
quantize :: #force_inline proc "contextless" (v:int,$k:Value_Type) -> int {
    when k==.UNorm {return ((v*255+(1<<(SCALE_BITS-1)))>>SCALE_BITS)&255} else {return v&255}
}

@(private)
dequantize :: #force_inline proc "contextless" (x:int,$k:Value_Type) -> int {
    when k==.UNorm {return (x*(1<<SCALE_BITS))/255} else {return x}
}

@(private)
in_endpoint_range :: #force_inline proc "contextless" (x:int) -> bool {
    return x>=0 && x<=255
}

@(private)
is_extremal :: #force_inline proc "contextless" (v:int,$k:Value_Type) -> bool {
    return v<=0 || v>=maximum(k)
}

encode :: proc "contextless" (b:^Block) -> u64 {
    packed:u64
    for i:=15;i>=0;i-=1 {packed=packed<<3|u64(b.inds[i]&7)}
    return packed<<16|u64(b.e0&255)|u64(b.e1&255)<<8
}

put_block :: #force_inline proc "contextless" (dest:[]u8,bits:u64) {
    for i in 0..<8 {dest[i]=u8(bits>>(uint(i)*8))}
}

get_block :: #force_inline proc "contextless" (src:[]u8) -> (bits:u64) {
    for i in 0..<8 {bits|=u64(src[i])<<(uint(i)*8)}
    return
}

// The palette of dequantized values of endpoints e0 and e1 (0..255), with
// minimum and maximum the values of indices 6 and 7 in four-value mode.
@(private)
palette_of :: #force_inline proc "contextless" (d0,d1:int,six:bool,minimum,
    maximum:int) -> (p:[8]int) {
    p[0]=d0
    p[1]=d1
    diff:=d1-d0
    if six {
        base:=7*d0
        for k in 1..=6 {p[k+1]=(base+k*diff)/7}
    } else {
        base:=5*d0
        for k in 1..=4 {p[k+1]=(base+k*diff)/5}
        p[6]=minimum
        p[7]=maximum
    }
    return
}

@(private)
palette :: #force_inline proc "contextless" (e0,e1:int,$k:Value_Type) -> [8]int {
    return palette_of(dequantize(e0,k),dequantize(e1,k),e0>e1,0,maximum(k))
}

// The index of the closest palette value for each texel and the sum of the
// squared distances, each distance clamped to 8191 (lowest index on ties).
@(private)
find_indices :: proc "contextless" (values:^Source_Data,e0,e1:int,$k:Value_Type) -> (err:u32,
    inds:[16]u8) {
    p:=palette(e0,e1,k)
    px:=transmute(I16x16)values.values
    best:U16x16=0xffff
    for j in 0..<8 {
        d:=transmute(U16x16)simd.abs(px-I16x16(i16(p[j])))
        d=simd.min(d,U16x16((1<<13)-1))
        best=simd.min(best,simd.shl(d,3)|U16x16(u16(j)))
    }
    idx:=simd.to_array(best&7)
    e:=simd.to_array(simd.shr(best,3))
    for i in 0..<16 {
        inds[i]=u8(idx[i])
        err+=u32(e[i])*u32(e[i])
    }
    return
}

@(private)
compress_endpoints :: proc "contextless" (b:^Block,values:^Source_Data,e0,e1:int,err:^u32,
    $k:Value_Type) -> bool {
    e,inds:=find_indices(values,e0,e1,k)
    if e<err^ {
        err^=e
        b.e0=e0
        b.e1=e1
        b.inds=inds
        return true
    }
    return false
}

@(private)
quantize_pair :: proc "contextless" (lo,hi:int,$k:Value_Type) -> (qlo,qhi:int) {
    qlo=quantize(lo,k)
    qhi=quantize(hi,k)
    if qlo==qhi {
        // Push apart two endpoints that quantized to the same value.
        dq:=dequantize(qlo,k)
        if 2*dq-(lo+hi)>=0 && qlo>0 {qlo-=1} else {qhi=(qhi+1)&255}
    }
    return
}

@(private)
compress_internal_1 :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,
    options:common.Options,$k:Value_Type) {
    MAX:=maximum(k)
    err^=INIT_ERROR
    sum,sum_sqr:i32
    lo,hi:=MAX,0
    extremal:i32
    notmax_sum,notmax_sum_sqr:i32
    notmax_lo,notmax_hi:=MAX,0
    for i in 0..<16 {
        v:=int(values.values[i])
        sum+=i32(v)
        sum_sqr+=i32(v*v)
        hi=max(hi,v)
        lo=min(lo,v)
        if is_extremal(v,k) {
            extremal+=1
        } else {
            notmax_sum+=i32(v)
            notmax_sum_sqr+=i32(v*v)
            notmax_hi=max(notmax_hi,v)
            notmax_lo=min(notmax_lo,v)
        }
    }
    notmax_lo=min(notmax_lo,notmax_hi)

    if extremal!=0 {
        qlo,qhi:=quantize_pair(notmax_lo,notmax_hi,k)
        if compress_endpoints(b,values,qlo,qhi,err,k) && err^==0 {return}
    }

    {
        qlo,qhi:=quantize_pair(lo,hi,k)
        if compress_endpoints(b,values,qhi,qlo,err,k) && err^<=good_enough_ssd(k) {return}
    }

    avg,variance:i32
    if extremal<4 {
        avg=(sum+8)>>4
        variance=(sum_sqr-2*avg*sum+16*avg*avg+8)>>4
    } else {
        count:=16-extremal
        if count<=0 {return}
        avg=(notmax_sum+count/2)/count
        variance=(notmax_sum_sqr-2*avg*notmax_sum+count*avg*avg+count/2)/count
    }

    sdev:=round_int(math.sqrt(f32(variance)))
    sdev=max(sdev,i32(MAX/128))

    for pass in i32(0)..<8 {
        spread:=(sdev*(8+pass))/8
        e1:=max(int(avg-spread),0)
        e0:=min(int(avg+spread),MAX)
        q1,q0:=quantize_pair(e1,e0,k)
        if extremal!=0 {
            if compress_endpoints(b,values,q1,q0,err,k) && err^<=good_enough_ssd(k) {return}
            if .BC3457_Preserve_Extremes in options {
                if hi==MAX {q0=255}
                if lo==0 {q1=0}
            }
        }
        if compress_endpoints(b,values,q0,q1,err,k) && err^<=good_enough_ssd(k) {return}
        if q0-q1>=254 {break}
    }
}

// rr_froundint: round half away from zero, then truncate.
@(private)
round_int :: #force_inline proc "contextless" (v:f32) -> i32 {
    return v>=0 ? i32(v+0.5) : i32(v-0.5)
}

@(rodata,private)
SIX_WEIGHTS := [8][2]f32{{7,0},{0,7},{6,1},{5,2},{4,3},{3,4},{2,5},{1,6}}
@(rodata,private)
FOUR_WEIGHTS := [8][2]f32{{5,0},{0,5},{4,1},{3,2},{2,3},{1,4},{0,0},{0,0}}

@(private)
optimize_endpoints_from_indices :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,
    options:common.Options,iterate:bool,$k:Value_Type) {
    MAX:=maximum(k)
    six:=b.e0>b.e1
    w:=six ? &SIX_WEIGHTS : &FOUR_WEIGHTS
    for {
        AA,AB,BB,AX,BX:f32
        lo,hi:=MAX,0
        for i in 0..<16 {
            index:=b.inds[i]&7
            v:=int(values.values[i])
            lo=min(lo,v)
            hi=max(hi,v)
            X:=f32(v)
            A:=w[index][0]
            B:=w[index][1]
            AA+=A*A
            BB+=B*B
            AB+=A*B
            AX+=A*X
            BX+=B*X
        }
        det:=AA*BB-AB*AB
        if det==0 {break}
        inv_det:=f64(w[0][0])/f64(det)
        fA:=f64(BB*AX-AB*BX)*inv_det
        fB:=f64(AA*BX-AB*AX)*inv_det
        iA:=clamp(int(round_int(f32(fA))),0,MAX)
        iB:=clamp(int(round_int(f32(fB))),0,MAX)
        q1,q0:=quantize_pair(min(iA,iB),max(iA,iB),k)
        if !six {q0,q1=q1,q0}
        if six && .BC3457_Preserve_Extremes in options {
            if hi==MAX {q0=255}
            if lo==0 {q1=0}
        }
        if q0==b.e0 && q1==b.e1 {break}
        if !compress_endpoints(b,values,q0,q1,err,k) {break}
        if !iterate {break}
    }
}

@(private)
compress_internal_2 :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,
    options:common.Options,$k:Value_Type) {
    compress_internal_1(b,err,values,options,k)
    if err^<=good_enough_ssd(k) {return}
    optimize_endpoints_from_indices(b,err,values,options,true,k)
}

@(private)
Try_Option :: enum u8 {Need_Min,Need_Max}
@(private)
Try_Options :: bit_set[Try_Option;u8]

@(private)
endpoints_legal :: #force_inline proc "contextless" (e0,e1:int,options:Try_Options) -> bool {
    if options!={} && e0>e1 {
        if .Need_Min in options && e1!=0 {return false}
        if .Need_Max in options && e0!=255 {return false}
    }
    return in_endpoint_range(e0) && in_endpoint_range(e1)
}

@(private)
try_mode_flip :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,options:Try_Options,
    $k:Value_Type) -> bool {
    return endpoints_legal(b.e1,b.e0,options) && compress_endpoints(b,values,b.e1,b.e0,err,k)
}

@(private)
pattern_search :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,options:Try_Options,
    scale:int,pattern:[][2]int,$k:Value_Type) -> int {
    s0,s1:=b.e0,b.e1
    best:=-1
    for p,i in pattern {
        e0:=s0+scale*p.x
        e1:=s1+scale*p.y
        if endpoints_legal(e0,e1,options) && compress_endpoints(b,values,e0,e1,err,k) {best=i}
    }
    return best
}

@(private)
pattern_search_both :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,
    options:Try_Options,scale:int,pattern:[][2]int,$k:Value_Type) -> int {
    s0,s1:=b.e0,b.e1
    best:=-1
    for p,i in pattern {
        e0:=s0+scale*p.x
        e1:=s1+scale*p.y
        if endpoints_legal(e0,e1,options) && compress_endpoints(b,values,e0,e1,err,k) {best=i}
        if endpoints_legal(e1,e0,options) && compress_endpoints(b,values,e1,e0,err,k) {best=i}
    }
    return best
}

// The first two again at the end so a wedge of three can wrap around.
@(rodata,private)
SMALL_HEX := [8][2]int{{2,0},{1,-2},{-1,-2},{-2,0},{-1,2},{1,2},{2,0},{1,-2}}
// The first four again at the end so a wedge of five can wrap around.
@(rodata,private)
SQUARE := [12][2]int{
    {1,0},{1,-1},{0,-1},{-1,-1},{-1,0},{-1,1},{0,1},{1,1},
    {1,0},{1,-1},{0,-1},{-1,-1},
}
@(rodata,private)
SHIFTS := [6][2]int{{-3,-3},{-2,-2},{-1,-1},{1,1},{2,2},{3,3}}
@(rodata,private)
LARGE_HEX := [12][2]int{
    {4,0},{4,2},{2,3},{0,4},{-2,3},{-4,2},{-4,0},{-4,-2},{-2,-3},{0,-4},{2,-3},{4,-2},
}

// After a step only the wedge of three moves away from where it came from
// reaches points not visited yet.
@(private)
iterated_hex_search :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,
    options:Try_Options,scale:int,$k:Value_Type) -> bool {
    improved:=pattern_search(b,err,values,options,scale,SMALL_HEX[:6],k)
    if improved<0 {return false}
    dir:=0
    for improved>=0 {
        dir=(dir+improved+5)%6
        improved=pattern_search(b,err,values,options,scale,SMALL_HEX[dir:dir+3],k)
    }
    return true
}

// A cardinal step uncovers three new points and a diagonal one five.
@(private)
iterated_square_search :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,
    options:Try_Options,scale:int,$k:Value_Type) -> bool {
    improved:=pattern_search(b,err,values,options,scale,SQUARE[:8],k)
    if improved<0 {return false}
    dir:=0
    for improved>=0 {
        dir+=improved
        parity:=dir&1
        dir=(dir-1-parity)&7
        improved=pattern_search(b,err,values,options,scale,SQUARE[dir:dir+3+2*parity],k)
    }
    return true
}

@(private)
greedy_optimize_block :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,
    options:common.Options,$k:Value_Type) {
    // A squared error of 25 for 8-bit values.
    BASE_ERROR:=u32(maximum(k)*maximum(k)/2600)
    try:Try_Options
    preserve:=.BC3457_Preserve_Extremes in options
    if (b.e1==0 || b.e0<=b.e1) && preserve {try+={.Need_Min}}
    if (b.e0==255 || b.e0<=b.e1) && preserve {try+={.Need_Max}}

    if err^>=BASE_ERROR*2 {
        if pattern_search(b,err,values,try,4,SHIFTS[:],k)>=0 {
            pattern_search(b,err,values,try,1,SHIFTS[:],k)
        }
        if err^>=BASE_ERROR*4 {
            if err^>=BASE_ERROR*16 {
                for pattern_search(b,err,values,try,10,LARGE_HEX[:],k)>=0 {}
            }
            pattern_search(b,err,values,try,8,LARGE_HEX[:],k)
            try_mode_flip(b,err,values,try,k)
            pattern_search_both(b,err,values,try,4,LARGE_HEX[:],k)
        }
        for scale:=4;scale>0;scale>>=1 {iterated_hex_search(b,err,values,try,scale,k)}
    }
    try_mode_flip(b,err,values,try,k)
    iterated_square_search(b,err,values,try,1,k)
}

@(private)
compress_internal_3 :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,
    options:common.Options,$k:Value_Type) {
    compress_internal_2(b,err,values,options,k)
    if err^<=good_enough_ssd(k) {return}
    greedy_optimize_block(b,err,values,options,k)
}

@(private)
try_brute_force :: #force_inline proc "contextless" (b:^Block,min_error:^u64,values:^Source_Data,
    e0,e1:int,$k:Value_Type) {
    err,inds:=find_indices(values,e0,e1,k)
    // Ties go to the closer endpoints.
    scaled:=u64(err)<<8|u64(abs(e1-e0))
    if scaled<min_error^ {
        min_error^=scaled
        b.e0=e0
        b.e1=e1
        b.inds=inds
    }
}

@(private)
compress_internal_brute_force :: proc "contextless" (b:^Block,err:^u32,values:^Source_Data,
    options:common.Options,$k:Value_Type) {
    MAX:=maximum(k)
    min_error:=~u64(0)
    if .BC3457_Preserve_Extremes in options {
        lo,hi:=MAX,0
        for v in values.values {
            hi=max(hi,int(v))
            lo=min(lo,int(v))
        }
        if lo==0 || hi==MAX {
            for e0 in 0..=255 {
                for e1 in e0..=255 {try_brute_force(b,&min_error,values,e0,e1,k)}
            }
            try_brute_force(b,&min_error,values,255,0,k)
            if hi!=MAX {
                for e0 in 1..=255 {try_brute_force(b,&min_error,values,e0,0,k)}
            }
            if lo!=0 {
                for e1 in 0..=254 {try_brute_force(b,&min_error,values,255,e1,k)}
            }
            err^=u32(min_error>>8)
            return
        }
    }
    for e0 in 0..=255 {
        for e1 in 0..=255 {try_brute_force(b,&min_error,values,e0,e1,k)}
    }
    err^=u32(min_error>>8)
}

@(private)
compress_kind :: proc "contextless" (values:^Source_Data,level:common.Level,options:common.Options,
    $k:Value_Type) -> (b:Block,err:u32) {
    #partial switch level {
    case .Very_Fast,.Fast: compress_internal_1(&b,&err,values,options,k)
    case .Slow: compress_internal_2(&b,&err,values,options,k)
    case .Very_Slow: compress_internal_3(&b,&err,values,options,k)
    case: compress_internal_brute_force(&b,&err,values,options,k)
    }
    return
}

// Encodes one block of values at an effort; returns its block bits and the
// internal squared error.
compress_block :: proc "contextless" (values:^Source_Data,level:common.Level,
    options:common.Options) -> (bits:u64,err:u32) {
    b:Block
    switch values.type {
    case .UNorm: b,err=compress_kind(values,level,options,.UNorm)
    case .Alpha: b,err=compress_kind(values,level,options,.Alpha)
    }
    return encode(&b),err
}

@(private)
decode_palette :: #force_inline proc "contextless" (bits:u64,$scale:int) -> (p:[8]int) {
    e0:=int(bits&255)
    e1:=int((bits>>8)&255)
    return palette_of(e0*scale,e1*scale,e0>e1,0,255*scale)
}

// The 8-bit values of a block (BC3 alpha).
decode_alpha :: proc "contextless" (block:u64) -> (out:[16]u8) {
    p:=decode_palette(block,1)
    inds:=block>>16
    for i in 0..<16 {
        out[i]=u8(p[inds&7])
        inds>>=3
    }
    return
}

// The 16-bit unsigned values of a block (BC4U, each half of BC5U).
decode_u16 :: proc "contextless" (block:u64) -> (out:[16]u16) {
    p:=decode_palette(block,257)
    inds:=block>>16
    for i in 0..<16 {
        out[i]=u16(p[inds&7])
        inds>>=3
    }
    return
}

// Encodes the blocks of `from` (source_bytes(source) bytes each) to `to`: the
// block i goes to bytes offset+i*stride (8 bytes, 16 for RG16 with green at +8).
compress :: proc(to:[]u8,stride,offset:int,from:[]u8,source:Source,level:common.Level,
    options:common.Options) -> common.Error {
    sb:=source_bytes(source)
    ob:=block_bytes(source)
    if len(from)%sb!=0 || stride<ob || offset<0 {return .Invalid}
    n:=len(from)/sb
    if n>0 && offset+(n-1)*stride+ob>len(to) {return .Invalid}
    for i in 0..<n {
        src:=from[i*sb:][:sb]
        dst:=to[offset+i*stride:][:ob]
        if source==.RG16 {
            r,g:=read_source_bc5(src)
            bits,_:=compress_block(&r,level,options)
            put_block(dst[0:8],bits)
            bits,_=compress_block(&g,level,options)
            put_block(dst[8:16],bits)
        } else {
            values:=read_source(src,source)
            bits,_:=compress_block(&values,level,options)
            put_block(dst,bits)
        }
    }
    return .None
}
