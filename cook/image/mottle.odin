package image

import "core:math"

// Blotches of light between two images of the same view, as a camera that
// moves leaves them on a wall: the relative difference of their light,
// smoothed over MOTTLE_FINE of the height, less its own mean over
// MOTTLE_WIDE, on the smooth surfaces of the second image. A change of
// exposure or of the light of the whole view moves the wide scale, which
// this leaves out; the blur of a moving image on edges and textures falls
// where the second image has detail of its own, which the mask leaves out.
MOTTLE_FINE :: 1.0/300    // σ, a share of the height of the region
MOTTLE_WIDE :: 1.0/45
MOTTLE_DETAIL :: 0.03     // detail of the second image at those scales, relative to its light, above which a pixel is not smooth
MOTTLE_SPOT :: 0.02       // relative difference above which a smooth pixel counts as a blotch
MOTTLE_GAIN :: 255.0/0.05 // what the map multiplies the difference by

Image_Mottle :: struct {
    mean:f64,   // percent: mean relative difference over the smooth pixels
    area:f64,   // percent of the smooth pixels in a blotch (MOTTLE_SPOT)
    smooth:f64, // percent of the region that is smooth
}

// With a mottle_map, fills it with the difference of each smooth pixel,
// amplified, in gray, and the pixels left out in dark blue; the caller frees it.
image_mottle :: proc(a,b:Image,region:Region,mottle_map:^Image=nil,allocator:=context.allocator) -> (mottle:Image_Mottle,error:Error) {
    if a.width!=b.width || a.height!=b.height {return {},.Size_Mismatch}
    area:=region_resolve(a,region) or_return
    count:=area.w*area.h
    buffers:[6][]f32
    for &buffer in buffers {
        values,alloc_error:=make([]f32,count,allocator)
        if alloc_error!=nil {
            for other in buffers {delete(other,allocator)}
            return {},.Out_Of_Memory
        }
        buffer=values
    }
    defer {for buffer in buffers {delete(buffer,allocator)}}
    scratch,scratch_error:=make([]f32,max(area.w,area.h),allocator)
    if scratch_error!=nil {return {},.Out_Of_Memory}
    defer delete(scratch,allocator)
    light_a,light_b,fine_a,fine_b,wide_b,wide_r:=buffers[0],buffers[1],buffers[2],buffers[3],buffers[4],buffers[5]
    table:=linear_table()
    at:=0
    for y in area.y..<area.y+area.h {
        offset:=(y*a.width+area.x)*4
        for x in 0..<area.w {
            light_a[at]=luminance(&table,a.pixels[offset+x*4:][:4])
            light_b[at]=luminance(&table,b.pixels[offset+x*4:][:4])
            at+=1
        }
    }
    fine,wide:=f32(MOTTLE_FINE*f64(area.h)),f32(MOTTLE_WIDE*f64(area.h))
    copy(fine_a,light_a)
    copy(fine_b,light_b)
    copy(wide_b,light_b)
    mottle_blur(fine_a,scratch,area.w,area.h,fine)
    mottle_blur(fine_b,scratch,area.w,area.h,fine)
    mottle_blur(wide_b,scratch,area.w,area.h,wide)
    // light_b becomes the smooth mask, light_a the relative difference.
    for i in 0..<count {
        detail:=max(abs(light_b[i]-fine_b[i]),abs(fine_b[i]-wide_b[i]))/max(wide_b[i],0.01)
        light_b[i]=detail<MOTTLE_DETAIL?1:0
        light_a[i]=(fine_a[i]-fine_b[i])/max(fine_b[i],0.01)
    }
    // Smooth all around: within the fine scale, nothing has detail.
    mottle_blur(light_b,scratch,area.w,area.h,fine)
    copy(wide_r,light_a)
    mottle_blur(wide_r,scratch,area.w,area.h,wide)
    map_pixels:[]u8
    if mottle_map!=nil {
        pixels,map_error:=make([]u8,count*4,allocator)
        if map_error!=nil {return {},.Out_Of_Memory}
        map_pixels=pixels
    }
    sum:f64
    smooth,spots:int
    for i in 0..<count {
        blotch:=abs(light_a[i]-wide_r[i])
        flat:=light_b[i]>0.99
        if flat {
            sum+=f64(blotch)
            smooth+=1
            if blotch>MOTTLE_SPOT {spots+=1}
        }
        if map_pixels!=nil {
            value:=u8(min(f64(blotch)*MOTTLE_GAIN,255))
            pixel:=map_pixels[i*4:][:4]
            if flat {pixel[0],pixel[1],pixel[2]=value,value,value} else {pixel[0],pixel[1],pixel[2]=0,0,64}
            pixel[3]=255
        }
    }
    if smooth>0 {mottle.mean,mottle.area=sum*100/f64(smooth),f64(spots)*100/f64(smooth)}
    mottle.smooth=f64(smooth)*100/f64(count)
    if mottle_map!=nil {mottle_map^={pixels=map_pixels,width=area.w,height=area.h,allocator=allocator}}
    return mottle,.None
}

// A gaussian of σ sigma pixels as three box filters a way, edges clamped
// (Kovesi's boxes for a gaussian): its cost does not grow with sigma.
@(private="file")
mottle_blur :: proc(values,scratch:[]f32,width,height:int,sigma:f32) {
    if sigma<=0.5 {return}
    ideal:=math.sqrt(4*sigma*sigma+1)
    low:=int(ideal)
    if low%2==0 {low-=1}
    high:=low+2
    lower:=int(math.round((12*sigma*sigma-3*f32(low*low)-12*f32(low)-9)/(-4*f32(low)-4)))
    for pass in 0..<3 {
        radius:=((pass<lower?low:high)-1)/2
        if radius<=0 {continue}
        for y in 0..<height {mottle_box(values[y*width:][:width],1,width,radius,scratch)}
        for x in 0..<width {mottle_box(values[x:],width,height,radius,scratch)}
    }
}

@(private="file")
mottle_box :: proc(line:[]f32,stride,count,radius:int,scratch:[]f32) {
    for i in 0..<count {scratch[i]=line[i*stride]}
    sum:f32
    for k in -radius..=radius {sum+=scratch[clamp(k,0,count-1)]}
    scale:=1/f32(2*radius+1)
    for i in 0..<count {
        line[i*stride]=sum*scale
        sum+=scratch[min(i+radius+1,count-1)]-scratch[max(i-radius,0)]
    }
}
