package image

import "core:math"

SSIM_WINDOW :: 8
DEFAULT_PIXEL_THRESHOLD :: 8
// What a difference map multiplies the error by so that small errors show.
DIFF_GAIN :: 8

Channel_Diff :: struct {mae,rmse,psnr,max_error:f64}

// Errors on luminance are over 0..255 of linear light; those of a channel,
// over its stored 0..255. PSNR is +Inf when the images are equal.
Image_Diff :: struct {
    pixels:int,
    mae,rmse,psnr,ssim,max_error:f64,
    excess:f64, // mean of how much brighter the first image is than the second, luminance
    channels:[3]Channel_Diff,
    over_threshold_percent:f64, // pixels with a channel off by more than the threshold
}

psnr_of :: proc(mse:f64) -> f64 {
    return mse<=0?math.inf_f64(1):10*math.log10(255.0*255.0/mse)
}

// Compares the same region of two images of the same size. threshold is the
// error of a channel, over 0..255, above which a pixel counts as different.
// With a diff_map, fills it with the absolute error of each pixel, amplified,
// in gray; the caller frees it.
image_diff :: proc(a,b:Image,region:Region,threshold:f64=DEFAULT_PIXEL_THRESHOLD,diff_map:^Image=nil,allocator:=context.allocator) -> (diff:Image_Diff,error:Error) {
    if a.width!=b.width || a.height!=b.height {return {},.Size_Mismatch}
    area:=region_resolve(a,region) or_return
    count:=area.w*area.h
    lumas_a,error_a:=make([]f32,count,allocator)
    lumas_b,error_b:=make([]f32,count,allocator)
    defer delete(lumas_a,allocator)
    defer delete(lumas_b,allocator)
    if error_a!=nil || error_b!=nil {return {},.Out_Of_Memory}
    map_pixels:[]u8
    if diff_map!=nil {
        pixels,map_error:=make([]u8,count*4,allocator)
        if map_error!=nil {return {},.Out_Of_Memory}
        map_pixels=pixels
    }
    table:=linear_table()
    luma_abs,luma_squared,luma_excess:f64
    channel_abs,channel_squared:[3]f64
    over:int
    at:=0
    for y in area.y..<area.y+area.h {
        offset:=(y*a.width+area.x)*4
        for x in 0..<area.w {
            pa,pb:=a.pixels[offset+x*4:][:4],b.pixels[offset+x*4:][:4]
            la,lb:=luminance(&table,pa)*255,luminance(&table,pb)*255
            lumas_a[at],lumas_b[at]=la,lb
            luma_error:=f64(abs(la-lb))
            luma_abs+=luma_error
            luma_excess+=f64(max(la-lb,0))
            luma_squared+=luma_error*luma_error
            diff.max_error=max(diff.max_error,luma_error)
            worst:f64
            for channel in 0..<3 {
                e:=f64(abs(int(pa[channel])-int(pb[channel])))
                channel_abs[channel]+=e
                channel_squared[channel]+=e*e
                diff.channels[channel].max_error=max(diff.channels[channel].max_error,e)
                worst=max(worst,e)
            }
            if worst>threshold {over+=1}
            if map_pixels!=nil {
                value:=u8(min(worst*DIFF_GAIN,255))
                map_pixels[at*4],map_pixels[at*4+1],map_pixels[at*4+2],map_pixels[at*4+3]=value,value,value,255
            }
            at+=1
        }
    }
    total:=f64(count)
    diff.pixels=count
    diff.mae=luma_abs/total
    diff.excess=luma_excess/total
    diff.rmse=math.sqrt(luma_squared/total)
    diff.psnr=psnr_of(luma_squared/total)
    for channel in 0..<3 {
        diff.channels[channel]={mae=channel_abs[channel]/total,rmse=math.sqrt(channel_squared[channel]/total),psnr=psnr_of(channel_squared[channel]/total),max_error=diff.channels[channel].max_error}
    }
    diff.over_threshold_percent=f64(over)*100/total
    diff.ssim=ssim(lumas_a,lumas_b,area.w,area.h)
    if diff_map!=nil {diff_map^={pixels=map_pixels,width=area.w,height=area.h,allocator=allocator}}
    return diff,.None
}

// Mean over every window of SSIM_WINDOW (the image when it is smaller) with
// K1=0.01, K2=0.03 and L=255.
@(private)
ssim :: proc(a,b:[]f32,width,height:int) -> f64 {
    C1 :: (0.01*255.0)*(0.01*255.0)
    C2 :: (0.03*255.0)*(0.03*255.0)
    window_w,window_h:=min(SSIM_WINDOW,width),min(SSIM_WINDOW,height)
    n:=f64(window_w*window_h)
    total:f64
    windows:=0
    for y in 0..=height-window_h {
        for x in 0..=width-window_w {
            sa,sb,saa,sbb,sab:f64
            for wy in 0..<window_h {
                row:=(y+wy)*width+x
                for wx in 0..<window_w {
                    va,vb:=f64(a[row+wx]),f64(b[row+wx])
                    sa+=va;sb+=vb;saa+=va*va;sbb+=vb*vb;sab+=va*vb
                }
            }
            mean_a,mean_b:=sa/n,sb/n
            var_a,var_b,covariance:=saa/n-mean_a*mean_a,sbb/n-mean_b*mean_b,sab/n-mean_a*mean_b
            total+=((2*mean_a*mean_b+C1)*(2*covariance+C2))/((mean_a*mean_a+mean_b*mean_b+C1)*(var_a+var_b+C2))
            windows+=1
        }
    }
    return total/f64(windows)
}
