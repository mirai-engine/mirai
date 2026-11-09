package common

import "base:intrinsics"
import "base:runtime"
import "core:simd"

// Multiplies every lambda of the RDO encoders.
GLOBAL_LAMBDA_SCALE :: f32(0.75)

// What the activity measures: the distance of RGBA, RGB or A to a low pass of the source.
Activity_Mode :: enum u8 {RGBA_1F, RGB_1F, A_1F}

MAX_FILTER_TAPS :: 64

@(private="file")
LOWPASS_SIGMA :: f32(2.2)
@(private="file")
ACTIVITY_BLUR_SIGMA :: f32(1.25)

@(private="file")
APPROX_EXP_HUMP_C :: -0.34168466148744669
@(private="file")
LN2 :: 0.6931471805599453

// e^x within 0.3%, for x in about [-700,700].
exp_approx :: proc "contextless" (x:f64) -> f64 {
    t:=x*(1.0/LN2)
    ti:=u64(1023+t)
    tf:=t-f64(ti)+1023
    y:=transmute(f64)(ti<<52)
    y*=1.0+tf+APPROX_EXP_HUMP_C*tf*(1.0-tf)
    return y
}

// Half of a normalized gaussian, filter[0] the center tap; returns the taps used.
make_gaussian :: proc "contextless" (filter:^[MAX_FILTER_TAPS]f32,sigma:f64) -> int {
    cutoff:=(1.0/256.0)*sigma*2.506628274631
    sum:f64
    width:=1
    filter[0]=1
    for width<MAX_FILTER_TAPS {
        q:=f64(width)/sigma
        val:=exp_approx(-0.5*(q*q))
        if val<cutoff {break}
        sum+=val
        filter[width]=f32(val)
        width+=1
    }
    sum*=2
    sum+=1.0
    tap0:=f32(1.0/sum)
    for i in 0..<width {filter[i]*=tap0}
    return width
}

// Mirror with the edge repeated (-1 -> 0), clamped inside for tiny sizes.
mirror_index :: #force_inline proc "contextless" (i,w:int) -> int {
    if uint(i)<uint(w) {return i}
    r:=i<0?-i-1:2*w-i-1
    return clamp(r,0,w-1)
}

// out[j] = filter[0]*from[j] + sum of filter[i]*(from[j+i*step]+from[j-i*step]) for j in
// [0,count), every tap in the same order as the scalar sum; from[j-i*step] must exist.
@(private="file")
blur_interior :: #force_inline proc "contextless" (out,from:[^]f32,count,step:int,
    filter:^[MAX_FILTER_TAPS]f32,fw:int) -> int #no_bounds_check {
    V :: #simd[8]f32
    j:=0
    for ; j+8<=count; j+=8 {
        acc:=V(filter[0])*intrinsics.unaligned_load((^V)(&from[j]))
        for i in 1..<fw {
            a:=intrinsics.unaligned_load((^V)(&from[j+i*step]))
            b:=intrinsics.unaligned_load((^V)(&from[j-i*step]))
            acc+=V(filter[i])*(a+b)
        }
        intrinsics.unaligned_store((^V)(&out[j]),acc)
    }
    for ; j<count; j+=1 {
        acc:=filter[0]*from[j]
        for i in 1..<fw {acc+=filter[i]*(from[j+i*step]+from[j-i*step])}
        out[j]=acc
    }
    return count
}

// Separable gaussian blur of a w*h image of nc floats per pixel (rows packed); calls
// consumer with each blurred row in order.
@(private="file")
gaussian_blur_rows :: proc(src:[]f32,w,h,nc:int,sigma:f64,ctx:rawptr,consumer:proc(ctx:rawptr,
    row:[]f32,y:int),allocator:runtime.Allocator) -> Error #no_bounds_check {
    filter:[MAX_FILTER_TAPS]f32
    fw:=make_gaussian(&filter,sigma)
    rc:=w*nc
    hblur,e1:=make([]f32,rc*h,allocator)
    if e1!=nil {return .Out_Of_Memory}
    defer delete(hblur,allocator)
    out,e2:=make([]f32,rc,allocator)
    if e2!=nil {return .Out_Of_Memory}
    defer delete(out,allocator)
    // Texels whose taps all fall inside the row.
    x0:=fw-1
    x1:=w-(fw-1)
    if x1-x0<8 {x0,x1=w,w}
    border :: #force_inline proc "contextless" (from,to:[]f32,x,w,nc,fw:int,
        filter:^[MAX_FILTER_TAPS]f32) #no_bounds_check {
        for c in 0..<nc {
            accum:=filter[0]*from[x*nc+c]
            for i in 1..<fw {
                accum+=filter[i]*(from[mirror_index(x+i,w)*nc+c]+from[mirror_index(x-i,w)*nc+c])
            }
            to[x*nc+c]=accum
        }
    }
    for y in 0..<h {
        from:=src[y*rc:][:rc]
        to:=hblur[y*rc:][:rc]
        for x in 0..<x0 {border(from,to,x,w,nc,fw,&filter)}
        if x0<x1 {
            blur_interior(raw_data(to[x0*nc:]),raw_data(from[x0*nc:]),(x1-x0)*nc,nc,&filter,fw)
        }
        for x in x1..<w {border(from,to,x,w,nc,fw,&filter)}
    }
    V :: #simd[8]f32
    rows:[MAX_FILTER_TAPS][2][^]f32
    for y in 0..<h {
        for i in 1..<fw {
            rows[i]={raw_data(hblur[mirror_index(y+i,h)*rc:]),raw_data(hblur[mirror_index(y-i,h)*rc:])}
        }
        row0:=raw_data(hblur[y*rc:])
        f:=0
        for ; f+8<=rc; f+=8 {
            acc:=V(filter[0])*intrinsics.unaligned_load((^V)(&row0[f]))
            for i in 1..<fw {
                a:=intrinsics.unaligned_load((^V)(&rows[i][0][f]))
                b:=intrinsics.unaligned_load((^V)(&rows[i][1][f]))
                acc+=V(filter[i])*(a+b)
            }
            intrinsics.unaligned_store((^V)(&out[f]),acc)
        }
        for ; f<rc; f+=1 {
            accum:=filter[0]*row0[f]
            for i in 1..<fw {accum+=filter[i]*(rows[i][0][f]+rows[i][1][f])}
            out[f]=accum
        }
        consumer(ctx,out,y)
    }
    return .None
}

@(private="file")
half_to_f32 :: #force_inline proc "contextless" (h:u16) -> f32 {return f32(transmute(f16)h)}

@(private="file")
surface_f32_row :: #force_inline proc "contextless" (s:Surface,y:int) -> []f32 {
    row:=surface_row(s,y)
    return ([^]f32)(raw_data(row))[:s.width]
}

// The source as nc floats per pixel (rows packed): RGBA8 normalized to [0,1], floats as
// they are; the first nc of R, G, B, A.
@(private="file")
source_to_floats :: proc(s:Surface,nc:int,allocator:runtime.Allocator) -> ([]f32,Error) #no_bounds_check {
    out,err:=make([]f32,s.width*s.height*nc,allocator)
    if err!=nil {return nil,.Out_Of_Memory}
    MULT:f32:1.0/255.0
    for y in 0..<s.height {
        row:=surface_row(s,y)
        to:=out[y*s.width*nc:]
        switch s.format {
        case .RGBA8:
            if nc==4 {
                for x in 0..<s.width {
                    v:=cast(#simd[4]f32)intrinsics.unaligned_load((^#simd[4]u8)(&row[x*4]))
                    intrinsics.unaligned_store((^#simd[4]f32)(&to[x*4]),v*MULT+0.0)
                }
            } else {
                for x in 0..<s.width {for c in 0..<nc {to[x*nc+c]=f32(row[x*4+c])*MULT+0.0}}
            }
        case .RGBA16F:
            p:=([^]u16)(raw_data(row))
            for x in 0..<s.width {for c in 0..<nc {to[x*nc+c]=half_to_f32(p[x*4+c])}}
        case .RGBA32F:
            p:=([^]f32)(raw_data(row))
            for x in 0..<s.width {for c in 0..<nc {to[x*nc+c]=p[x*4+c]}}
        case .R32F:
            p:=([^]f32)(raw_data(row))
            for x in 0..<s.width {
                px:=[4]f32{p[x],0,0,1}
                for c in 0..<nc {to[x*nc+c]=px[c]}
            }
        }
    }
    return out,.None
}

@(private="file")
preprocess_activity_row :: proc "contextless" (out,activity_in:[]f32,scaler:f32) {
    C:f32:1.0
    for i in 0..<len(out) {
        activity:=intrinsics.sqrt(activity_in[i])
        scale:=256.0/(C+scaler*activity)
        out[i]=max(scale,1.0)
    }
}

@(private="file")
valid_activity_dest :: proc "contextless" (to,source:Surface) -> bool {
    if to.format!=.R32F || to.width!=source.width || to.height!=source.height {return false}
    if to.width<=0 || to.height<=0 {return false}
    if to.stride<to.width*4 || source.stride<source.width*pixel_bytes(source.format) {return false}
    if len(to.pixels)<(to.height-1)*to.stride+to.width*4 {return false}
    source_end:=(source.height-1)*source.stride+source.width*pixel_bytes(source.format)
    if len(source.pixels)<source_end {return false}
    return true
}

@(private="file")
Activity_Context :: struct {
    source:[]f32, // nc floats per pixel
    nc:int,
    mode:Activity_Mode,
    temp:[]f32, // one float per pixel
    final:Surface,
    w:int,
    scaler:f32,
}

@(private="file")
activity_pass1 :: proc(ctx_ptr:rawptr,lowpass:[]f32,y:int) {
    ctx:=(^Activity_Context)(ctx_ptr)
    w:=ctx.w
    nc:=ctx.nc
    src:=ctx.source[y*w*nc:]
    act:=ctx.temp[y*w:]
    for x in 0..<w {
        s:=src[x*nc:]
        l:=lowpass[x*nc:]
        if nc==4 {
            dr:=s[0]-l[0]; dg:=s[1]-l[1]; db:=s[2]-l[2]; da:=s[3]-l[3]
            switch ctx.mode {
            case .RGBA_1F: act[x]=(dr*dr+dg*dg)+(db*db+da*da)
            case .RGB_1F: act[x]=(dr*dr+dg*dg)+db*db
            case .A_1F: act[x]=da*da
            }
        } else {
            d0:=s[0]-l[0]
            dsqr:=d0*d0
            if nc==2 {
                d1:=s[1]-l[1]
                dsqr+=d1*d1
            }
            act[x]=dsqr
        }
    }
}

@(private="file")
activity_pass2 :: proc(ctx_ptr:rawptr,blurred:[]f32,y:int) {
    ctx:=(^Activity_Context)(ctx_ptr)
    preprocess_activity_row(surface_f32_row(ctx.final,y),blurred,ctx.scaler)
}

// The perceptual weight of every texel of source (RGBA8, or floats) into to (R32F, the
// same size): high where error shows most. dest_channel_count is what the encoded format
// keeps (1 for BC4, 2 for BC5, 4 otherwise). The borders of source mirror.
make_activity_mask :: proc(to,source:Surface,mode:Activity_Mode,options:Options,
    dest_channel_count:int=4,allocator:=context.allocator) -> Error {
    if !valid_activity_dest(to,source) {return .Invalid}
    nc:=4
    if mode==.RGB_1F && 1<=dest_channel_count && dest_channel_count<=2 {nc=dest_channel_count}
    src,err:=source_to_floats(source,nc,allocator)
    if err!=.None {return err}
    defer delete(src,allocator)
    w:=source.width
    h:=source.height
    temp,e2:=make([]f32,w*h,allocator)
    if e2!=nil {return .Out_Of_Memory}
    defer delete(temp,allocator)
    ctx:=Activity_Context{source=src,nc=nc,mode=mode,temp=temp,final=to,w=w,scaler=4.0*256.0}
    if e:=gaussian_blur_rows(src,w,h,nc,f64(LOWPASS_SIGMA),&ctx,activity_pass1,
        allocator);e!=.None {return e}
    return gaussian_blur_rows(temp,w,h,1,f64(ACTIVITY_BLUR_SIGMA),&ctx,activity_pass2,allocator)
}

@(private="file")
Hdr_Context :: struct {
    source:[]f32, // 3 floats per pixel
    avg_intens:[]f32,
    w_sub:int,
    temp:[]f32,
    final:Surface,
    w:int,
}

@(private="file")
hdr_avgintens :: proc(ctx_ptr:rawptr,row:[]f32,y:int) {
    ctx:=(^Hdr_Context)(ctx_ptr)
    to:=ctx.avg_intens[y*ctx.w_sub:]
    EPS:f32:1.0/(16777216.0*16777216.0)
    for x in 0..<ctx.w_sub {
        v:=row[x*3:]
        len2:=v[0]*v[0]+v[1]*v[1]+v[2]*v[2]
        to[x]=1.0/(len2+EPS)
    }
}

@(private="file")
hdr_pass1 :: proc(ctx_ptr:rawptr,lowpass:[]f32,y:int) {
    ctx:=(^Hdr_Context)(ctx_ptr)
    w:=ctx.w
    src:=ctx.source[y*w*3:]
    avg:=ctx.avg_intens[(y>>2)*ctx.w_sub:]
    act:=ctx.temp[y*w:]
    for x in 0..<w {
        dx:=src[x*3]-lowpass[x*3]
        dy:=src[x*3+1]-lowpass[x*3+1]
        dz:=src[x*3+2]-lowpass[x*3+2]
        dsqr:=dx*dx+dy*dy+dz*dz
        act[x]=dsqr*avg[x>>2]
    }
}

@(private="file")
hdr_pass2 :: proc(ctx_ptr:rawptr,blurred:[]f32,y:int) {
    ctx:=(^Hdr_Context)(ctx_ptr)
    preprocess_activity_row(surface_f32_row(ctx.final,y),blurred,1536.0)
}

// The activity of an HDR source (RGBA16F or RGBA32F; RGB only), normalized by the local
// intensity.
make_activity_mask_hdr :: proc(to,source:Surface,options:Options,
    allocator:=context.allocator) -> Error {
    if !valid_activity_dest(to,source) {return .Invalid}
    src,err:=source_to_floats(source,3,allocator)
    if err!=.None {return err}
    defer delete(src,allocator)
    w:=source.width
    h:=source.height
    w_sub:=(w+3)/4
    h_sub:=(h+3)/4
    sub,e1:=make([]f32,w_sub*h_sub*3,allocator)
    if e1!=nil {return .Out_Of_Memory}
    defer delete(sub,allocator)
    for y in 0..<h_sub {
        fm0:=src[min(y*4+0,h-1)*w*3:]
        fm1:=src[min(y*4+1,h-1)*w*3:]
        fm2:=src[min(y*4+2,h-1)*w*3:]
        fm3:=src[min(y*4+3,h-1)*w*3:]
        for x in 0..<w_sub {
            sum:[3]f32
            for i in 0..<4 {
                xi:=min(x*4+i,w-1)*3
                a:=[3]f32{fm0[xi],fm0[xi+1],fm0[xi+2]}
                b:=[3]f32{fm1[xi],fm1[xi+1],fm1[xi+2]}
                c:=[3]f32{fm2[xi],fm2[xi+1],fm2[xi+2]}
                d:=[3]f32{fm3[xi],fm3[xi+1],fm3[xi+2]}
                sum+=a+b+c+d
            }
            to:=(1.0/16.0)*sum
            sub[(y*w_sub+x)*3+0]=to[0]
            sub[(y*w_sub+x)*3+1]=to[1]
            sub[(y*w_sub+x)*3+2]=to[2]
        }
    }
    avg,e2:=make([]f32,w_sub*h_sub,allocator)
    if e2!=nil {return .Out_Of_Memory}
    defer delete(avg,allocator)
    temp,e3:=make([]f32,w*h,allocator)
    if e3!=nil {return .Out_Of_Memory}
    defer delete(temp,allocator)
    ctx:=Hdr_Context{source=src,avg_intens=avg,w_sub=w_sub,temp=temp,final=to,w=w}
    if e:=gaussian_blur_rows(sub,w_sub,h_sub,3,f64(f32(2.2)),&ctx,hdr_avgintens,
        allocator);e!=.None {return e}
    if e:=gaussian_blur_rows(src,w,h,3,f64(LOWPASS_SIGMA),&ctx,hdr_pass1,
        allocator);e!=.None {return e}
    return gaussian_blur_rows(temp,w,h,1,f64(ACTIVITY_BLUR_SIGMA),&ctx,hdr_pass2,allocator)
}

// Activity 2 everywhere: VQD is then twice the SSD (the RMSE metric).
make_activity_mask_constant_for_rmse :: proc(to,source:Surface) -> Error {
    if !valid_activity_dest(to,source) {return .Invalid}
    for y in 0..<to.height {
        row:=surface_f32_row(to,y)
        for x in 0..<len(row) {row[x]=2.0}
    }
    return .None
}

// The texels of the row r of a block that indices pick from palette.
bc1_palette_row :: #force_inline proc "contextless" (palette:V16u8,indices:u32,r:int) -> V16u8 {
    sel:=simd.shr(V4u32(indices>>uint(8*r)),V4u32{0,2,4,6})&V4u32(3)
    ctrl:=simd.shl(sel,V4u32(2))*V4u32(0x01010101)+V4u32(0x03020100)
    return simd.runtime_swizzle(palette,transmute(V16u8)ctrl)
}

// Activity weighted SSD of the RGBA of colors against what the indices pick from palette.
// Columns accumulate down the rows, then (c0+c1)+(c2+c3).
vqd_bc1_body :: #force_inline proc "contextless" (colors:^Color_Block,palette:^[4]Color,
    in_indices:u32,activity:^Float_Block) -> f32 {
    pal:=load_u8x16(palette)
    c:=([^]V16u8)(colors)
    act:=([^]V4f32)(activity)
    lanes:V4f32
    for r in 0..<4 {
        d:=ssd_rgba4(load_u8x16(&c[r]),bc1_palette_row(pal,in_indices,r))
        lanes+=cast(V4f32)d*intrinsics.unaligned_load(&act[r])
    }
    l:=simd.to_array(lanes)
    return (l[0]+l[1])+(l[2]+l[3])
}

vqd :: proc "contextless" (colors1,colors2:^Color_Block,activity:^Float_Block) -> f32 {
    c1:=([^]V16u8)(colors1)
    c2:=([^]V16u8)(colors2)
    act:=([^]V4f32)(activity)
    lanes:V4f32
    for r in 0..<4 {
        d:=ssd_rgba4(load_u8x16(&c1[r]),load_u8x16(&c2[r]))
        lanes+=cast(V4f32)d*intrinsics.unaligned_load(&act[r])
    }
    l:=simd.to_array(lanes)
    return (l[0]+l[1])+(l[2]+l[3])
}

// For 16-bit values that do not use the whole range. Rows sum in pairs, then
// (c0+c2)+(c1+c3).
vqd_s16 :: proc "contextless" (colors1,colors2:^[16]i16,activity:^Float_Block) -> f32 {
    a:=([^]#simd[4]i16)(colors1)
    b:=([^]#simd[4]i16)(colors2)
    act:=([^]V4f32)(activity)
    rows:[4]V4f32
    for r in 0..<4 {
        d:=cast(V4f32)(intrinsics.unaligned_load(&a[r])-intrinsics.unaligned_load(&b[r]))
        rows[r]=(d*d)*intrinsics.unaligned_load(&act[r])
    }
    s:=simd.to_array((rows[0]+rows[1])+(rows[2]+rows[3]))
    return (s[0]+s[2])+(s[1]+s[3])
}

