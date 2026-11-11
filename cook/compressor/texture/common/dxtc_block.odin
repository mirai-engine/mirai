package common

import "base:intrinsics"
import "core:simd"

// A BC1 block as stored: endpoints c0 (low 16 bits) and c1 (high), packed 565, then the
// 2-bit indices of the texels, texel 0 in the low bits. Four colors when c0 > c1.
BC1_Block :: struct {
    endpoints:u32,
    indices:u32,
}

// Whether the client reads the alpha of a BC1 block: with Alpha the transparency of a
// texel cannot change; with No_Alpha the transparent color 3 of the three color mode is
// free black; Four_Color is the color half of BC2 and BC3, always four colors.
BC1_Palette_Mode :: enum u8 {No_Alpha, Alpha, Four_Color}

DXTC_ERROR_BIG :: (u32(1)<<30)-1

bc1_c0 :: #force_inline proc "contextless" (b:BC1_Block) -> u16 {return u16(b.endpoints)}
bc1_c1 :: #force_inline proc "contextless" (b:BC1_Block) -> u16 {return u16(b.endpoints>>16)}
bc1_make_endpoints :: #force_inline proc "contextless" (c0,c1:u16) -> u32 {
    return u32(c0)|(u32(c1)<<16)
}

bc1_is_4color :: #force_inline proc "contextless" (endpoints:u32,mode:BC1_Palette_Mode) -> bool {
    if mode==.Four_Color {return true}
    return u16(endpoints)>u16(endpoints>>16)
}

bc1_is_bc3_canonical :: #force_inline proc "contextless" (endpoints:u32) -> bool {
    return u16(endpoints)>=u16(endpoints>>16)
}

// Prefers c0 >= c1, the order four color blocks have anyway.
bc1_bc3_canonicalize :: proc "contextless" (b:^BC1_Block) {
    if u16(b.endpoints)<u16(b.endpoints>>16) {
        b.endpoints=(b.endpoints>>16)|(b.endpoints<<16)
        b.indices~=0x55555555
    }
}

bc1_put_block :: #force_inline proc "contextless" (to:[]u8,b:BC1_Block) {
    (^[8]u8)(raw_data(to))^=transmute([8]u8)b
}

bc1_get_block :: #force_inline proc "contextless" (from:[]u8) -> BC1_Block {
    return transmute(BC1_Block)(^[8]u8)(raw_data(from))^
}

// The palette of the endpoints e (c0 then c1, BGRA in 16-bit lanes, alpha 255): c0, c1,
// then c0+((c1-c0)*85+128)>>8 and c1+((c0-c1)*85+128)>>8 (83 for G) with four colors, the
// rounded average and black without.
@(private="file")
bc1_palette_lanes :: #force_inline proc "contextless" (e:V8i16,palette:^[4]Color,
    mode:BC1_Palette_Mode,e0_gt_e1:bool) {
    o:=simd.shuffle(e,e,4,5,6,7,0,1,2,3)
    d:=o-e
    four:=mode==.Four_Color || e0_gt_e1
    interp4:=e+simd.shr(d*V8i16{85,83,85,85,85,83,85,85}+V8i16(128),V8u16(8))
    interp3:=e+simd.shr(d+V8i16(1),V8u16(1))
    black:=V8i16{0,0,0,0,0,0,0,mode==.Alpha ? 0 : 255}
    keep3:=V8i16{-1,-1,-1,-1,0,0,0,0}
    interp:=four ? interp4 : (interp3&keep3)|black
    intrinsics.unaligned_store((^#simd[16]u8)(palette),cast(#simd[16]u8)simd.shuffle(e,interp,
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15))
}

// c0 and c1 must have alpha 255; they are copied to the output.
bc1_palette_from_colors :: #force_inline proc "contextless" (c0,c1:Color,palette:^[4]Color,
    mode:BC1_Palette_Mode,e0_gt_e1:bool) {
    bc1_palette_lanes(cast(V8i16)transmute(#simd[8]u8)[2]Color{c0,c1},palette,mode,e0_gt_e1)
}

bc1_palette_565 :: proc "contextless" (c0,c1:u16,palette:^[4]Color,mode:BC1_Palette_Mode) {
    bc1_palette_from_colors(unquantize_565(c0),unquantize_565(c1),palette,mode,c0>c1)
}

bc1_palette :: proc "contextless" (endpoints:u32,palette:^[4]Color,mode:BC1_Palette_Mode) {
    bc1_palette_565(u16(endpoints),u16(endpoints>>16),palette,mode)
}

bc1_palette_unpacked :: #force_inline proc "contextless" (e0,e1:Unpacked_565,palette:^[4]Color,
    mode:BC1_Palette_Mode) {
    x:=cast(V8i16)transmute(#simd[8]u8)[2]u32{u32(e0),u32(e1)}
    e:=simd.shr(x*V8i16{132,65,132,0,132,65,132,0},V8u16(4))|V8i16{0,0,0,255,0,0,0,255}
    bc1_palette_lanes(e,palette,mode,e0>e1)
}

// Four palette entries per pair of endpoints.
bc1_palettes_batched :: proc "contextless" (endpoints:[][2]Unpacked_565,palettes:[][4]Color,
    mode:BC1_Palette_Mode) {
    n:=min(len(endpoints),len(palettes))
    for i in 0..<n {bc1_palette_unpacked(endpoints[i][0],endpoints[i][1],&palettes[i],mode)}
}

bc1_decompress :: proc "contextless" (to:^Color_Block,from:BC1_Block,mode:BC1_Palette_Mode) {
    palette:[4]Color
    bc1_palette(from.endpoints,&palette,mode)
    indices:=from.indices
    for i in 0..<16 {
        to[i]=palette[indices&3]
        indices>>=2
    }
}

kill_alpha :: proc "contextless" (b:^Color_Block) {
    for i in 0..<16 {b[i][A]=255}
}

swap_rb :: proc "contextless" (b:^Color_Block) {
    for i in 0..<16 {b[i][0],b[i][2]=b[i][2],b[i][0]}
}

// Alpha below 128.
is_one_bit_transparent :: #force_inline proc "contextless" (c:Color) -> bool {return c[A]<128}

// Transparent texels become 0 (black, alpha 0), the others get alpha 255.
make_one_bit_transparent_canonical :: #force_inline proc "contextless" (c:^Color) {
    if is_one_bit_transparent(c^) {c^={}} else {c[A]=255}
}

// Bit 2*i set when texel i is transparent (canonical 0).
bc1_one_bit_transparent_mask :: proc "contextless" (b:^Color_Block) -> u32 {
    out:u32
    for i in 0..<16 {
        if color_dw(b[i])==0 {out|=1<<(u32(i)*2)}
    }
    return out
}

bc1_one_bit_transparent_mask_from_indices :: #force_inline proc "contextless" (is3c:bool,
    indices:u32) -> u32 {
    if !is3c {return 0}
    return indices&(indices>>1)&0x55555555
}

bc1_one_bit_transparent_mask_same :: proc "contextless" (mask,endpoints,indices:u32) -> bool {
    if bc1_is_4color(endpoints,.Alpha) {return mask==0}
    return mask==indices&(indices>>1)&0x55555555
}

bc1_one_bit_transparent_same :: proc "contextless" (b:^Color_Block,endpoints,indices:u32) -> bool {
    return bc1_one_bit_transparent_mask_same(bc1_one_bit_transparent_mask(b),endpoints,indices)
}

// Squared RGBA difference of every texel to the palette entry its index picks.
bc1_palette_ssd_rgba :: #force_inline proc "contextless" (colors:^Color_Block,palette:^[4]Color,
    in_indices:u32) -> u32 {
    indices:=in_indices
    ssd:u32
    for i in 0..<16 {
        ssd+=delta_sqr_rgba(colors[i],palette[indices&3])
        indices>>=2
    }
    return ssd
}

// Plain RGBA SSD; the colors must already be canonical for the mode.
bc1_compute_ssd_rgba :: proc "contextless" (colors:^Color_Block,b:BC1_Block,
    mode:BC1_Palette_Mode) -> u32 {
    palette:[4]Color
    bc1_palette(b.endpoints,&palette,mode)
    return bc1_palette_ssd_rgba(colors,&palette,b.indices)
}

// The 16-bit B,R and G,2A lanes of eight texels (two rows of a block). Twice the alpha
// makes its squared difference count 4 times: with canonical alpha (0 or 255) a change of
// transparency always costs more than any RGB error. scale doubles every channel, which
// multiplies the squared differences by 4 and leaves room for an index in their low bits.
// The 256-bit kernel helpers pass arrays: they may stay uninlined (odin-lang/Odin#7780).
@(private="file")
bc1_unpack_rows :: #force_inline proc "contextless" (rows:[32]u8,$scale:i16) -> (br,ga:[16]i16) {
    u:=transmute(V16u16)rows
    S :: scale
    br=transmute([16]i16)(transmute(V16i16)(u&V16u16(0xff))*V16i16(S))
    ga=transmute([16]i16)(transmute(V16i16)simd.shr(u,V16u16(8))*V16i16{S,2*S,S,2*S,S,2*S,S,
        2*S,S,2*S,S,2*S,S,2*S,S,2*S})
    return
}

// The four entries of a palette in both halves.
@(private="file")
bc1_load_palette :: #force_inline proc "contextless" (palette:^[4]Color,
    $scale:i16) -> (br,ga:[16]i16) {
    p:=(^[16]u8)(palette)^
    return bc1_unpack_rows(transmute([32]u8)[2][16]u8{p,p},scale)
}

// The squared differences of x and y rotated by k within each half (k<0: entry -k-1 of
// y in all four lanes of each half).
@(private="file")
bc1_delta_sqr8 :: #force_inline proc "contextless" (x_br,x_ga,y_br,y_ga:[16]i16,
    $k:int) -> [8]i32 {
    yb:=transmute(V8i32)y_br
    yg:=transmute(V8i32)y_ga
    when k>0 {
        yb=simd.shuffle(yb,yb,k,(k+1)&3,(k+2)&3,(k+3)&3,4+k,4+((k+1)&3),4+((k+2)&3),4+((k+3)&3))
        yg=simd.shuffle(yg,yg,k,(k+1)&3,(k+2)&3,(k+3)&3,4+k,4+((k+1)&3),4+((k+2)&3),4+((k+3)&3))
    } else when k<0 {
        e :: -k-1
        yb=simd.shuffle(yb,yb,e,e,e,e,4+e,4+e,4+e,4+e)
        yg=simd.shuffle(yg,yg,e,e,e,e,4+e,4+e,4+e,4+e)
    }
    dbr:=transmute(V16i16)yb-transmute(V16i16)x_br
    dga:=transmute(V16i16)yg-transmute(V16i16)x_ga
    p:=(cast(#simd[16]i32)dbr)*(cast(#simd[16]i32)dbr)
    q:=(cast(#simd[16]i32)dga)*(cast(#simd[16]i32)dga)
    mp:=simd.shuffle(p,p,0,2,4,6,8,10,12,14)+simd.shuffle(p,p,1,3,5,7,9,11,13,15)
    mq:=simd.shuffle(q,q,0,2,4,6,8,10,12,14)+simd.shuffle(q,q,1,3,5,7,9,11,13,15)
    return transmute([8]i32)(mp+mq)
}

// The least error of each texel of two rows against the four entries of the palette:
// every texel is compared with every entry, through rotations of the palette.
@(private="file")
bc1_best_errors8 :: #force_inline proc "contextless" (row_br,row_ga,pal_br,
    pal_ga:[16]i16) -> [8]i32 {
    best:=transmute(V8i32)bc1_delta_sqr8(row_br,row_ga,pal_br,pal_ga,0)
    best=simd.min(best,transmute(V8i32)bc1_delta_sqr8(row_br,row_ga,pal_br,pal_ga,1))
    best=simd.min(best,transmute(V8i32)bc1_delta_sqr8(row_br,row_ga,pal_br,pal_ga,2))
    best=simd.min(best,transmute(V8i32)bc1_delta_sqr8(row_br,row_ga,pal_br,pal_ga,3))
    return transmute([8]i32)best
}

// 4 times the least error of each texel of two rows (from twice scaled channels) plus the
// index of its palette entry, ties to the lower index.
@(private="file")
bc1_best_indices8 :: #force_inline proc "contextless" (row_br,row_ga,pal_br,
    pal_ga:[16]i16) -> [8]i32 {
    d0:=transmute(V8i32)bc1_delta_sqr8(row_br,row_ga,pal_br,pal_ga,-1)
    d1:=transmute(V8i32)bc1_delta_sqr8(row_br,row_ga,pal_br,pal_ga,-2)
    d2:=transmute(V8i32)bc1_delta_sqr8(row_br,row_ga,pal_br,pal_ga,-3)
    d3:=transmute(V8i32)bc1_delta_sqr8(row_br,row_ga,pal_br,pal_ga,-4)
    best01:=simd.min(d0,d1+V8i32(1))
    best23:=simd.min(d2,d3+V8i32(1))
    return transmute([8]i32)simd.min(best01,best23+V8i32(2))
}

@(private)
bc1_find_indices_body :: #force_inline proc "contextless" (b:^Color_Block,palette:^[4]Color,
    err:^u32) -> u32 {
    pal_br,pal_ga:=bc1_load_palette(palette,2)
    rows:=(^[2][32]u8)(b)
    br0,ga0:=bc1_unpack_rows(rows[0],2)
    br1,ga1:=bc1_unpack_rows(rows[1],2)
    best0:=transmute(V8u32)bc1_best_indices8(br0,ga0,pal_br,pal_ga)
    best1:=transmute(V8u32)bc1_best_indices8(br1,ga1,pal_br,pal_ga)
    // Texel i goes to bits 2i.
    packed:=(best0&V8u32(3))*V8u32{1,1<<2,1<<4,1<<6,1<<8,1<<10,1<<12,1<<14}|
        (best1&V8u32(3))*V8u32{1<<16,1<<18,1<<20,1<<22,1<<24,1<<26,1<<28,1<<30}
    if err!=nil {
        err^=simd.reduce_add_pairs(simd.shr(best0,V8u32(2))+simd.shr(best1,V8u32(2)))
    }
    return simd.reduce_or(packed)
}

bc1_find_indices :: proc "contextless" (b:^Color_Block,endpoints:u32,mode:BC1_Palette_Mode,
    err:^u32=nil) -> u32 {
    palette:[4]Color
    bc1_palette(endpoints,&palette,mode)
    return bc1_find_indices_palette(b,&palette,err)
}

// The pixels whose best errors against many palettes are wanted, unpacked once.
BC1_Find_Errors_Context :: struct {
    br,ga:[2][16]i16,
}

BC1_FIND_ERRORS_COUNT_SHIFT :: 8
BC1_FIND_ERRORS_COUNT_LIMIT :: 1<<BC1_FIND_ERRORS_COUNT_SHIFT

bc1_find_errors_init :: #force_inline proc "contextless" (ctx:^BC1_Find_Errors_Context,
    b:^Color_Block) {
    rows:=(^[2][32]u8)(b)
    for h in 0..<2 {ctx.br[h],ctx.ga[h]=bc1_unpack_rows(rows[h],1)}
}

bc1_eval_palette :: #force_inline proc "contextless" (ctx:^BC1_Find_Errors_Context,
    palette:^[4]Color) -> u32 {
    pal_br,pal_ga:=bc1_load_palette(palette,1)
    sum:=transmute(V8i32)bc1_best_errors8(ctx.br[0],ctx.ga[0],pal_br,pal_ga)+
        transmute(V8i32)bc1_best_errors8(ctx.br[1],ctx.ga[1],pal_br,pal_ga)
    return u32(simd.reduce_add_pairs(sum))
}

@(private)
bc1_eval_palettes_body :: #force_inline proc "contextless" (ctx:^BC1_Find_Errors_Context,
    out_ssds:[]u32,palettes:[][4]Color) #no_bounds_check {
    n:=min(len(out_ssds),len(palettes))
    for i in 0..<n {out_ssds[i]=bc1_eval_palette(ctx,&palettes[i])}
}

@(private)
bc1_find_best_palette_body :: #force_inline proc "contextless" (ctx:^BC1_Find_Errors_Context,
    palettes:[][4]Color) -> u32 #no_bounds_check {
    count:=min(len(palettes),BC1_FIND_ERRORS_COUNT_LIMIT)
    if count==0 {return ~u32(0)}
    best:=bc1_eval_palette(ctx,&palettes[0])<<BC1_FIND_ERRORS_COUNT_SHIFT
    for i in 1..<count {
        best=min(best,(bc1_eval_palette(ctx,&palettes[i])<<BC1_FIND_ERRORS_COUNT_SHIFT)|u32(i))
    }
    return best
}

// Refines 4 means of the RGB colors of the block in place (alpha is ignored).
bc1_solve_rgb_4means :: proc "contextless" (means:^[4]Color,colors:^Color_Block) {
    ITER_LIMIT :: 128
    iters_left:=ITER_LIMIT
    for {
        sums:[4]Vec3i
        counts:[4]i32
        worst_d_i:u32
        for i in 0..<16 {
            c:=colors[i]
            d0:=delta_sqr_rgb(c,means[0])<<2
            d1:=(delta_sqr_rgb(c,means[1])<<2)+1
            d2:=(delta_sqr_rgb(c,means[2])<<2)+2
            d3:=(delta_sqr_rgb(c,means[3])<<2)+3
            min_d:=min(d0,d1,d2,d3)
            index:=min_d&3
            sums[index]+=color_to_vec3i(c)
            counts[index]+=1
            worst_d_i=max(worst_d_i,(min_d<<4)|(u32(i)~15))
        }
        any_changed:=false
        for i in 0..<4 {
            count:=counts[i]
            if count==0 {
                means[i]=colors[15~(worst_d_i&15)]
                continue
            }
            recip:=f32(1)/f32(count)
            s:=sums[i]
            c:=Color{u8(round_to_int(f32(s.x)*recip)),u8(round_to_int(f32(s.y)*recip)),
                u8(round_to_int(f32(s.z)*recip)),255}
            if color_dw(c)!=color_dw(means[i]) {
                any_changed=true
                means[i]=c
            }
        }
        iters_left-=1
        if !any_changed || iters_left<=0 {break}
    }
}
