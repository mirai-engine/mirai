package asset

import "base:intrinsics"
import "core:simd"

// BC7 (BPTC): 4x4 texels in 16 bytes, in one of eight modes that trade
// subsets (pieces of the block, each with its two endpoints), endpoint
// precision and index bits, with alpha in the endpoints or apart. What a
// block decodes to follows the Khronos Data Format Specification. BC6H
// shares its partitions of two subsets, their anchors and its weights.

// A mode, with the field names of the specification. This file is the description of the block
// format: what encodes blocks (cook/compressor/texture) reads these tables.
Bc7_Mode :: struct {
    ns:u8,  // subsets: 1 to 3, by a partition of the block
    pb:u8,  // partition bits
    rb:u8,  // rotation bits (modes 4 and 5): the color channel alpha swaps with
    isb:u8, // index selection bit (mode 4): which of the two index sets is the color's
    cb:u8,  // color bits per endpoint and channel, before a p-bit
    ab:u8,  // alpha bits; 0: alpha is 255
    epb:u8, // 1: a low bit of its own for each endpoint
    spb:u8, // 1: a low bit shared by the two endpoints of a subset
    ib:u8,  // index bits
    ib2:u8, // of the second index set of modes 4 and 5
}

BC7_MODES :: [8]Bc7_Mode{
    // ns,pb,rb,isb,cb,ab,epb,spb,ib,ib2
    {3,4,0,0,4,0,1,0,3,0},
    {2,6,0,0,6,0,0,1,3,0},
    {3,6,0,0,5,0,0,0,2,0},
    {2,6,0,0,7,0,1,0,2,0},
    {1,0,2,1,5,6,0,0,2,3},
    {1,0,2,0,7,8,0,0,2,2},
    {1,0,0,0,7,7,1,0,4,0},
    {2,6,0,0,5,5,1,0,2,0},
}

// The weight of the second endpoint, out of 64, for each index, by the bits of the index: 2, 3
// and 4.
@(rodata)
BC7_WEIGHTS := [5][16]u8{
    {},{},{0,21,43,64,0,0,0,0,0,0,0,0,0,0,0,0},{0,9,18,27,37,46,55,64,0,0,0,0,0,0,0,0},
    {0,4,9,13,17,21,26,30,34,38,43,47,51,55,60,64},
}

// The subset of each texel, row by row, for the 64 partitions of two and of
// three subsets.
@(rodata)
BC7_PARTITIONS_2 := [64][16]u8{
    {0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1},
    {0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1},
    {0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1},
    {0,0,0,1,0,0,1,1,0,0,1,1,0,1,1,1},
    {0,0,0,0,0,0,0,1,0,0,0,1,0,0,1,1},
    {0,0,1,1,0,1,1,1,0,1,1,1,1,1,1,1},
    {0,0,0,1,0,0,1,1,0,1,1,1,1,1,1,1},
    {0,0,0,0,0,0,0,1,0,0,1,1,0,1,1,1},
    {0,0,0,0,0,0,0,0,0,0,0,1,0,0,1,1},
    {0,0,1,1,0,1,1,1,1,1,1,1,1,1,1,1},
    {0,0,0,0,0,0,0,1,0,1,1,1,1,1,1,1},
    {0,0,0,0,0,0,0,0,0,0,0,1,0,1,1,1},
    {0,0,0,1,0,1,1,1,1,1,1,1,1,1,1,1},
    {0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1},
    {0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1},
    {0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1},
    {0,0,0,0,1,0,0,0,1,1,1,0,1,1,1,1},
    {0,1,1,1,0,0,0,1,0,0,0,0,0,0,0,0},
    {0,0,0,0,0,0,0,0,1,0,0,0,1,1,1,0},
    {0,1,1,1,0,0,1,1,0,0,0,1,0,0,0,0},
    {0,0,1,1,0,0,0,1,0,0,0,0,0,0,0,0},
    {0,0,0,0,1,0,0,0,1,1,0,0,1,1,1,0},
    {0,0,0,0,0,0,0,0,1,0,0,0,1,1,0,0},
    {0,1,1,1,0,0,1,1,0,0,1,1,0,0,0,1},
    {0,0,1,1,0,0,0,1,0,0,0,1,0,0,0,0},
    {0,0,0,0,1,0,0,0,1,0,0,0,1,1,0,0},
    {0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0},
    {0,0,1,1,0,1,1,0,0,1,1,0,1,1,0,0},
    {0,0,0,1,0,1,1,1,1,1,1,0,1,0,0,0},
    {0,0,0,0,1,1,1,1,1,1,1,1,0,0,0,0},
    {0,1,1,1,0,0,0,1,1,0,0,0,1,1,1,0},
    {0,0,1,1,1,0,0,1,1,0,0,1,1,1,0,0},
    {0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1},
    {0,0,0,0,1,1,1,1,0,0,0,0,1,1,1,1},
    {0,1,0,1,1,0,1,0,0,1,0,1,1,0,1,0},
    {0,0,1,1,0,0,1,1,1,1,0,0,1,1,0,0},
    {0,0,1,1,1,1,0,0,0,0,1,1,1,1,0,0},
    {0,1,0,1,0,1,0,1,1,0,1,0,1,0,1,0},
    {0,1,1,0,1,0,0,1,0,1,1,0,1,0,0,1},
    {0,1,0,1,1,0,1,0,1,0,1,0,0,1,0,1},
    {0,1,1,1,0,0,1,1,1,1,0,0,1,1,1,0},
    {0,0,0,1,0,0,1,1,1,1,0,0,1,0,0,0},
    {0,0,1,1,0,0,1,0,0,1,0,0,1,1,0,0},
    {0,0,1,1,1,0,1,1,1,1,0,1,1,1,0,0},
    {0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0},
    {0,0,1,1,1,1,0,0,1,1,0,0,0,0,1,1},
    {0,1,1,0,0,1,1,0,1,0,0,1,1,0,0,1},
    {0,0,0,0,0,1,1,0,0,1,1,0,0,0,0,0},
    {0,1,0,0,1,1,1,0,0,1,0,0,0,0,0,0},
    {0,0,1,0,0,1,1,1,0,0,1,0,0,0,0,0},
    {0,0,0,0,0,0,1,0,0,1,1,1,0,0,1,0},
    {0,0,0,0,0,1,0,0,1,1,1,0,0,1,0,0},
    {0,1,1,0,1,1,0,0,1,0,0,1,0,0,1,1},
    {0,0,1,1,0,1,1,0,1,1,0,0,1,0,0,1},
    {0,1,1,0,0,0,1,1,1,0,0,1,1,1,0,0},
    {0,0,1,1,1,0,0,1,1,1,0,0,0,1,1,0},
    {0,1,1,0,1,1,0,0,1,1,0,0,1,0,0,1},
    {0,1,1,0,0,0,1,1,0,0,1,1,1,0,0,1},
    {0,1,1,1,1,1,1,0,1,0,0,0,0,0,0,1},
    {0,0,0,1,1,0,0,0,1,1,1,0,0,1,1,1},
    {0,0,0,0,1,1,1,1,0,0,1,1,0,0,1,1},
    {0,0,1,1,0,0,1,1,1,1,1,1,0,0,0,0},
    {0,0,1,0,0,0,1,0,1,1,1,0,1,1,1,0},
    {0,1,0,0,0,1,0,0,0,1,1,1,0,1,1,1},
}

@(rodata)
BC7_PARTITIONS_3 := [64][16]u8{
    {0,0,1,1,0,0,1,1,0,2,2,1,2,2,2,2},
    {0,0,0,1,0,0,1,1,2,2,1,1,2,2,2,1},
    {0,0,0,0,2,0,0,1,2,2,1,1,2,2,1,1},
    {0,2,2,2,0,0,2,2,0,0,1,1,0,1,1,1},
    {0,0,0,0,0,0,0,0,1,1,2,2,1,1,2,2},
    {0,0,1,1,0,0,1,1,0,0,2,2,0,0,2,2},
    {0,0,2,2,0,0,2,2,1,1,1,1,1,1,1,1},
    {0,0,1,1,0,0,1,1,2,2,1,1,2,2,1,1},
    {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2},
    {0,0,0,0,1,1,1,1,1,1,1,1,2,2,2,2},
    {0,0,0,0,1,1,1,1,2,2,2,2,2,2,2,2},
    {0,0,1,2,0,0,1,2,0,0,1,2,0,0,1,2},
    {0,1,1,2,0,1,1,2,0,1,1,2,0,1,1,2},
    {0,1,2,2,0,1,2,2,0,1,2,2,0,1,2,2},
    {0,0,1,1,0,1,1,2,1,1,2,2,1,2,2,2},
    {0,0,1,1,2,0,0,1,2,2,0,0,2,2,2,0},
    {0,0,0,1,0,0,1,1,0,1,1,2,1,1,2,2},
    {0,1,1,1,0,0,1,1,2,0,0,1,2,2,0,0},
    {0,0,0,0,1,1,2,2,1,1,2,2,1,1,2,2},
    {0,0,2,2,0,0,2,2,0,0,2,2,1,1,1,1},
    {0,1,1,1,0,1,1,1,0,2,2,2,0,2,2,2},
    {0,0,0,1,0,0,0,1,2,2,2,1,2,2,2,1},
    {0,0,0,0,0,0,1,1,0,1,2,2,0,1,2,2},
    {0,0,0,0,1,1,0,0,2,2,1,0,2,2,1,0},
    {0,1,2,2,0,1,2,2,0,0,1,1,0,0,0,0},
    {0,0,1,2,0,0,1,2,1,1,2,2,2,2,2,2},
    {0,1,1,0,1,2,2,1,1,2,2,1,0,1,1,0},
    {0,0,0,0,0,1,1,0,1,2,2,1,1,2,2,1},
    {0,0,2,2,1,1,0,2,1,1,0,2,0,0,2,2},
    {0,1,1,0,0,1,1,0,2,0,0,2,2,2,2,2},
    {0,0,1,1,0,1,2,2,0,1,2,2,0,0,1,1},
    {0,0,0,0,2,0,0,0,2,2,1,1,2,2,2,1},
    {0,0,0,0,0,0,0,2,1,1,2,2,1,2,2,2},
    {0,2,2,2,0,0,2,2,0,0,1,2,0,0,1,1},
    {0,0,1,1,0,0,1,2,0,0,2,2,0,2,2,2},
    {0,1,2,0,0,1,2,0,0,1,2,0,0,1,2,0},
    {0,0,0,0,1,1,1,1,2,2,2,2,0,0,0,0},
    {0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0},
    {0,1,2,0,2,0,1,2,1,2,0,1,0,1,2,0},
    {0,0,1,1,2,2,0,0,1,1,2,2,0,0,1,1},
    {0,0,1,1,1,1,2,2,2,2,0,0,0,0,1,1},
    {0,1,0,1,0,1,0,1,2,2,2,2,2,2,2,2},
    {0,0,0,0,0,0,0,0,2,1,2,1,2,1,2,1},
    {0,0,2,2,1,1,2,2,0,0,2,2,1,1,2,2},
    {0,0,2,2,0,0,1,1,0,0,2,2,0,0,1,1},
    {0,2,2,0,1,2,2,1,0,2,2,0,1,2,2,1},
    {0,1,0,1,2,2,2,2,2,2,2,2,0,1,0,1},
    {0,0,0,0,2,1,2,1,2,1,2,1,2,1,2,1},
    {0,1,0,1,0,1,0,1,0,1,0,1,2,2,2,2},
    {0,2,2,2,0,1,1,1,0,2,2,2,0,1,1,1},
    {0,0,0,2,1,1,1,2,0,0,0,2,1,1,1,2},
    {0,0,0,0,2,1,1,2,2,1,1,2,2,1,1,2},
    {0,2,2,2,0,1,1,1,0,1,1,1,0,2,2,2},
    {0,0,0,2,1,1,1,2,1,1,1,2,0,0,0,2},
    {0,1,1,0,0,1,1,0,0,1,1,0,2,2,2,2},
    {0,0,0,0,0,0,0,0,2,1,1,2,2,1,1,2},
    {0,1,1,0,0,1,1,0,2,2,2,2,2,2,2,2},
    {0,0,2,2,0,0,1,1,0,0,1,1,0,0,2,2},
    {0,0,2,2,1,1,2,2,1,1,2,2,0,0,2,2},
    {0,0,0,0,0,0,0,0,0,0,0,0,2,1,1,2},
    {0,0,0,2,0,0,0,1,0,0,0,2,0,0,0,1},
    {0,2,2,2,1,2,2,2,0,2,2,2,1,2,2,2},
    {0,1,0,1,2,2,2,2,2,2,2,2,2,2,2,2},
    {0,1,1,1,2,0,1,1,2,2,0,1,2,2,2,0},
}


// The texel of each subset after the first whose index is stored a bit
// shorter, its top bit being zero: of the second subset of a partition in
// two, and of the second and third of a partition in three. The first
// subset has it at texel 0.
@(rodata)
BC7_ANCHORS_2 := [64]u8{
    15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,
    15,2,8,2,2,8,8,15,2,8,2,2,8,8,2,2,
    15,15,6,8,2,8,15,15,2,8,2,2,2,15,15,6,
    6,2,6,8,15,15,2,2,15,15,15,15,15,2,2,15,
}

@(rodata)
BC7_ANCHORS_3 := [64][2]u8{
    {3,15},{3,8},{15,8},{15,3},{8,15},{3,15},{15,3},{15,8},
    {8,15},{8,15},{6,15},{6,15},{6,15},{5,15},{3,15},{3,8},
    {3,15},{3,8},{8,15},{15,3},{3,15},{3,8},{6,15},{10,8},
    {5,3},{8,15},{8,6},{6,10},{8,15},{5,15},{15,10},{15,8},
    {8,15},{15,3},{3,15},{5,10},{6,10},{10,8},{8,9},{15,10},
    {15,6},{3,15},{15,8},{5,15},{15,3},{15,6},{15,6},{15,8},
    {3,15},{15,3},{5,15},{5,15},{5,15},{8,15},{5,15},{10,15},
    {5,15},{10,15},{8,15},{13,15},{15,3},{12,15},{3,15},{3,8},
}

// A value between two endpoints, as every BC7 decoder interpolates it.
bc7_interpolate :: proc "contextless" (e0,e1,weight:u32) -> u32 {
    return (e0*(64-weight)+e1*weight+32)>>6
}

// Texels of a BC7 block, row by row. A block of no mode (its first byte
// zero) decodes as transparent black, as the specification asks.
texture_bc7_block_decode :: proc "contextless" (block:[16]u8) -> (texels:[16][4]u8) {
    switch intrinsics.count_trailing_zeros(block[0]) {
    case 0: return bc7_decode_mode(block,0)
    case 1: return bc7_decode_mode(block,1)
    case 2: return bc7_decode_mode(block,2)
    case 3: return bc7_decode_mode(block,3)
    case 4: return bc7_decode_mode(block,4)
    case 5: return bc7_decode_mode(block,5)
    case 6: return bc7_decode_mode(block,6)
    case 7: return bc7_decode_mode(block,7)
    }
    return
}

@(private="file")
bc7_field :: #force_inline proc "contextless" (bits:u128,at:int,$N:int) -> u32 {
    return u32(bits>>uint(at))&u32((1<<uint(N))-1)
}

// v with a zero bit inserted at bit pos.
@(private="file")
bc7_insert_zero :: #force_inline proc "contextless" (v:u64,pos:u32) -> u64 {
    low:=(u64(1)<<pos)-1
    return (v&low)|((v&~low)<<1)
}

@(private="file")
bc7_decode_mode :: #force_inline proc "contextless" (block:[16]u8,
    $M:int) -> (texels:[16][4]u8) #no_bounds_check {
    L :: BC7_MODES[M]
    NS :: int(L.ns); PB :: int(L.pb); RB :: int(L.rb); ISB :: int(L.isb); CB :: int(L.cb)
    AB :: int(L.ab); EPB :: int(L.epb); SPB :: int(L.spb); IB :: int(L.ib); IB2 :: int(L.ib2)
    bits:=transmute(u128)block
    partition:=bc7_field(bits,M+1,PB)
    rotation:=bc7_field(bits,M+1+PB,RB)
    selector:=bc7_field(bits,M+1+PB+RB,ISB)
    E :: M+1+PB+RB+ISB
    A :: E+3*NS*2*CB
    P :: A+NS*2*AB
    PBIT :: min(EPB+SPB,1)
    NC :: CB+PBIT
    NA :: (AB+PBIT)*min(AB,1)
    ep:[3][2]u32 // RGBA bytes
    #unroll for s in 0..<NS {
        #unroll for e in 0..<2 {
            v:[4]u32
            #unroll for c in 0..<3 {v[c]=bc7_field(bits,E+((c*NS+s)*2+e)*CB,CB)}
            when AB>0 {v[3]=bc7_field(bits,A+(s*2+e)*AB,AB)}
            when EPB>0 {
                p:=bc7_field(bits,P+s*2+e,1)
                for &x in v {x=x<<1|p}
            } else when SPB>0 {
                p:=bc7_field(bits,P+s,1)
                for &x in v {x=x<<1|p}
            }
            #unroll for c in 0..<3 {v[c]=v[c]<<uint(8-NC)|v[c]>>uint(2*NC-8)}
            when NA>0 {v[3]=v[3]<<uint(8-NA)|v[3]>>uint(2*NA-8)} else {v[3]=255}
            ep[s][e]=v[0]|v[1]<<8|v[2]<<16|v[3]<<24
        }
    }
    I0 :: 16*IB-NS
    I1 :: (16*IB2-1)*min(IB2,1)
    f0:=u64(bits>>uint(128-I0-I1))&((u64(1)<<uint(I0))-1)
    f0=bc7_insert_zero(f0,u32(IB-1))
    when NS==2 {
        f0=bc7_insert_zero(f0,u32(BC7_ANCHORS_2[partition])*u32(IB)+u32(IB-1))
    } else when NS==3 {
        a1:=u32(BC7_ANCHORS_3[partition][0])
        a2:=u32(BC7_ANCHORS_3[partition][1])
        f0=bc7_insert_zero(f0,min(a1,a2)*u32(IB)+u32(IB-1))
        f0=bc7_insert_zero(f0,max(a1,a2)*u32(IB)+u32(IB-1))
    }
    lo,hi,w:[16]u32
    when IB2>0 {
        f1:=u64(bits>>uint(128-I1))&((u64(1)<<uint(I1))-1)
        f1=bc7_insert_zero(f1,u32(IB2-1))
        w0:=&BC7_WEIGHTS[IB]
        w1:=&BC7_WEIGHTS[IB2]
        for i in 0..<16 {
            c:=u32(w0[(f0>>uint(i*IB))&((1<<uint(IB))-1)])
            a:=u32(w1[(f1>>uint(i*IB2))&((1<<uint(IB2))-1)])
            if selector==1 {c,a=a,c}
            w[i]=c|c<<8|c<<16|a<<24
        }
    } else {
        w0:=&BC7_WEIGHTS[IB]
        for i in 0..<16 {w[i]=u32(w0[(f0>>uint(i*IB))&((1<<uint(IB))-1)])*0x01010101}
    }
    for i in 0..<16 {
        s:=0
        when NS==2 {s=int(BC7_PARTITIONS_2[partition][i])}
        when NS==3 {s=int(BC7_PARTITIONS_3[partition][i])}
        lo[i]=ep[s][0]
        hi[i]=ep[s][1]
    }
    U :: #simd[16]u16
    B :: #simd[16]u8
    out:[4]B
    #unroll for q in 0..<4 {
        l:=cast(U)transmute(B)(^[4]u32)(&lo[q*4])^
        h:=cast(U)transmute(B)(^[4]u32)(&hi[q*4])^
        x:=cast(U)transmute(B)(^[4]u32)(&w[q*4])^
        out[q]=cast(B)simd.shr(l*(U(64)-x)+h*x+U(32),U(6))
    }
    when RB>0 {
        for &o in out {
            switch rotation {
            case 1: o=simd.shuffle(o,o,3,1,2,0,7,5,6,4,11,9,10,8,15,13,14,12)
            case 2: o=simd.shuffle(o,o,0,3,2,1,4,7,6,5,8,11,10,9,12,15,14,13)
            case 3: o=simd.shuffle(o,o,0,1,3,2,4,5,7,6,8,9,11,10,12,13,15,14)
            }
        }
    }
    texels=transmute([16][4]u8)out
    return
}
