package bc6

import "core:math"
import "core:math/rand"
import "core:testing"
import "mirai:asset"
import "mirai:cook/compressor/texture/common"

@(private="file")
SPECIALS :: [8]u16{0x7e00,0x7c00,0xfc00,0xbc00,0x8000,0x0001,0x7bff,0x7c01}

@(test)
hostile_halfs_never_crash :: proc(t:^testing.T) {
    state:=rand.create(3)
    r:=rand.default_random_generator(&state)
    N :: 6
    specials:=SPECIALS
    blocks:[N]common.Half_Block
    for &b in blocks {
        for &px in b {
            for &c in px {
                v:=rand.uint32(r)
                c=v&3==0 ? specials[(v>>2)&7] : u16(v>>16)
            }
        }
    }
    to:[N*16]u8
    for level in common.Level {
        for options in ([2]common.Options{{},{.BC6_Favor_Luminance}}) {
            testing.expect_value(t,compress(to[:],blocks[:],level,options),common.Error.None)
            for i in 0..<N {
                st:Block_State
                testing.expect(t,state_from_bits(&st,(^[16]u8)(&to[i*16])))
            }
        }
    }
    testing.expect_value(t,compress(to[:16],blocks[:],.Slow,{}),common.Error.Invalid)

    floats:[N]common.Float4_Block
    for &b,i in floats {
        for &px,k in b {
            for &c,j in px {c=f32(i*k-j)*0.37}
        }
        b[0]={math.nan_f32(),math.inf_f32(1),math.inf_f32(-1),-1}
        b[1]={max(f32),-max(f32),1e-40,70000}
    }
    activity:[N]common.Float_Block
    for &a,i in activity {for &v in a {v=f32(i)}}
    activity[2][5]=math.nan_f32()
    baseline:[N*16]u8
    compress(baseline[:],blocks[:],.Very_Slow,{})
    out:[N*16]u8
    for level in common.Level {
        testing.expect_value(t,rd(out[:],floats[:],baseline[:],activity[:],50,{},{effort=level}),
            common.Error.None)
    }
    bad:=baseline
    for i in 0..<16 {bad[i]=0xff}
    testing.expect_value(t,rd(out[:],floats[:],bad[:],activity[:],50,{},{}),common.Error.Invalid)
    testing.expect_value(t,rd(out[:],floats[:],baseline[:],activity[:2],50,{},{}),
        common.Error.Invalid)
}

@(test)
encodes_are_deterministic :: proc(t:^testing.T) {
    state:=rand.create(5)
    r:=rand.default_random_generator(&state)
    N :: 64
    blocks:[N]common.Half_Block
    for &b,i in blocks {
        for &px,k in b {
            for &c,j in px {c=u16(0x3000+i*37+k*11+j*5+int(rand.uint32(r)&7))}
        }
    }
    a,b:[N*16]u8
    compress(a[:],blocks[:],.Very_Slow,{.BC6_Favor_Luminance})
    compress(b[:],blocks[:],.Very_Slow,{.BC6_Favor_Luminance})
    testing.expect(t,a==b)
    floats:[N]common.Float4_Block
    for &f,i in floats {
        for k in 0..<16 {for c in 0..<4 {f[k][c]=half_to_f32(blocks[i][k][c])}}
    }
    activity:[N]common.Float_Block
    for &x in activity {for &v in x {v=1}}
    ra,rb:[N*16]u8
    rd(ra[:],floats[:],a[:],activity[:],30,{.BC6_Favor_Luminance},{effort=.Slow})
    rd(rb[:],floats[:],a[:],activity[:],30,{.BC6_Favor_Luminance},{effort=.Slow})
    testing.expect(t,ra==rb)
}

@(test)
halfs_round_trip_through_floats :: proc(t:^testing.T) {
    for h in 0..<0x10000 {
        if h&0x7c00==0x7c00 && h&0x3ff!=0 {continue} // NaN
        testing.expect_value(t,f32_to_half(half_to_f32(u16(h))),u16(h))
    }
}

@(test)
single_color_decodes_close :: proc(t:^testing.T) {
    for v in ([?]u16{0,1,0x0400,0x3c00,0x4a00,0x7bff}) {
        b:[1]common.Half_Block
        for &px in b[0] {px={v,v/2,v/3,0x3c00}}
        bits:[16]u8
        compress(bits[:],b[:],.Slow,{})
        out:=asset.texture_bc6h_block_decode(bits)
        for c in 0..<3 {
            want:=f64(half_to_f32(b[0][0][c]))
            got:=f64(half_to_f32(out[0][c]))
            testing.expect(t,abs(got-want)<=want*0.002+1e-7)
        }
    }
}

// The endpoint and delta bits the encoder fits each mode to are those of the format.
@(test)
the_modes_of_the_encoder_are_those_of_the_format :: proc(t:^testing.T) {
    modes:=asset.BC6H_MODES
    for mode,i in modes {
        desc:=MODE_DESC[i]
        testing.expect(t,desc.epb==int(mode.epb) && desc.is_two_subset==(mode.ns==2),"endpoint bits and subsets")
        for c in 0..<3 {
            testing.expect_value(t,desc.db[c],mode.db==0 ? 0 : int(mode.db)+int(c==int(mode.bc)))
        }
    }
}
