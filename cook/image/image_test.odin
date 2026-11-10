package image

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import "mirai:std/base"

solid :: proc(width,height:int,r,g,b:u8) -> Image {
    pixels:=make([]u8,width*height*4,context.temp_allocator)
    for i in 0..<width*height {pixels[i*4],pixels[i*4+1],pixels[i*4+2],pixels[i*4+3]=r,g,b,255}
    return {pixels=pixels,width=width,height=height,allocator=context.temp_allocator}
}

@(test)
identical_images_have_ssim_one_and_infinite_psnr :: proc(t:^testing.T) {
    a:=solid(16,12,90,120,200)
    for i in 0..<16*12 {a.pixels[i*4]=u8(i*7)}
    b:=solid(16,12,0,0,0)
    copy(b.pixels,a.pixels)
    diff,error:=image_diff(a,b,{})
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,diff.ssim,1.0)
    testing.expect(t,math.is_inf(diff.psnr,1),"PSNR is +Inf")
    testing.expect_value(t,diff.mae,0.0)
    testing.expect_value(t,diff.rmse,0.0)
    testing.expect_value(t,diff.max_error,0.0)
    testing.expect_value(t,diff.over_threshold_percent,0.0)
    testing.expect_value(t,diff.pixels,16*12)
}

@(test)
a_known_offset_gives_the_expected_errors :: proc(t:^testing.T) {
    a:=solid(10,10,100,100,100)
    b:=solid(10,10,110,100,100)
    diff,error:=image_diff(a,b,{})
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,diff.channels[0].mae,10.0)
    testing.expect_value(t,diff.channels[0].rmse,10.0)
    testing.expect_value(t,diff.channels[0].max_error,10.0)
    testing.expect_value(t,diff.channels[1].mae,0.0)
    testing.expect(t,math.abs(diff.channels[0].psnr-20*math.log10(f64(255.0/10.0)))<1e-9,"PSNR of a channel")
    testing.expect_value(t,diff.over_threshold_percent,100.0)
    below,_:=image_diff(a,b,{},10)
    testing.expect_value(t,below.over_threshold_percent,0.0)
    testing.expect(t,diff.ssim<1 && diff.ssim>0.9,"a small shift keeps SSIM high")
    testing.expect(t,diff.mae>0 && diff.rmse>=diff.mae && diff.max_error>=diff.mae,"luminance errors are ordered")
}

@(test)
a_region_measures_only_its_pixels :: proc(t:^testing.T) {
    a:=solid(8,8,50,50,50)
    b:=solid(8,8,50,50,50)
    for y in 4..<8 {for x in 4..<8 {b.pixels[(y*8+x)*4]=250}}
    whole,_:=image_diff(a,b,{})
    testing.expect_value(t,whole.over_threshold_percent,25.0)
    equal,error:=image_diff(a,b,{0,0,4,4})
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,equal.pixels,16)
    testing.expect_value(t,equal.max_error,0.0)
    testing.expect_value(t,equal.ssim,1.0)
    different,_:=image_diff(a,b,{4,4,4,4})
    testing.expect_value(t,different.over_threshold_percent,100.0)
    testing.expect_value(t,different.channels[0].max_error,200.0)

    _,outside:=image_diff(a,b,{6,6,4,4})
    testing.expect_value(t,outside,Error.Bad_Region)
    _,empty:=image_diff(a,b,{1,1,0,3})
    testing.expect_value(t,empty,Error.Bad_Region)
}

@(test)
images_of_different_size_are_refused :: proc(t:^testing.T) {
    _,error:=image_diff(solid(8,8,0,0,0),solid(8,9,0,0,0),{})
    testing.expect_value(t,error,Error.Size_Mismatch)
}

@(test)
the_diff_map_amplifies_the_error :: proc(t:^testing.T) {
    a:=solid(4,4,10,10,10)
    b:=solid(4,4,10,10,10)
    b.pixels[0]=13
    b.pixels[4+1]=200
    map_image:Image
    _,error:=image_diff(a,b,{},DEFAULT_PIXEL_THRESHOLD,&map_image,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,map_image.width,4)
    testing.expect_value(t,map_image.pixels[0],u8(3*DIFF_GAIN))
    testing.expect_value(t,map_image.pixels[4],u8(255))
    testing.expect_value(t,map_image.pixels[8],u8(0))
    testing.expect_value(t,map_image.pixels[3],u8(255))
}

@(test)
stats_describe_a_known_image :: proc(t:^testing.T) {
    image:=solid(4,4,0,0,0)
    for i in 0..<8 {image.pixels[i*4],image.pixels[i*4+1],image.pixels[i*4+2]=255,255,255}
    stats,error:=image_stats(image,{},context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,stats.pixels,16)
    testing.expect_value(t,stats.black_percent,50.0)
    testing.expect_value(t,stats.saturated_percent,50.0)
    testing.expect(t,math.abs(stats.mean_luma-0.5)<1e-5,"half white")
    testing.expect_value(t,stats.p5,0.0)
    testing.expect(t,math.abs(stats.p95-1)<1e-5,"white at the top")
    testing.expect(t,math.abs(stats.mean[0]-0.5)<1e-6 && math.abs(stats.mean[2]-0.5)<1e-6,"mean per channel")

    top,_:=image_stats(image,{0,0,4,2},context.temp_allocator)
    testing.expect_value(t,top.saturated_percent,100.0)
    testing.expect_value(t,top.black_percent,0.0)
    testing.expect_value(t,top.mean[1],1.0)
    _,outside:=image_stats(image,{3,3,2,2},context.temp_allocator)
    testing.expect_value(t,outside,Error.Bad_Region)
}

@(test)
a_montage_puts_images_side_by_side_at_one_height :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"image")
    if folder=="" {return}
    first,second:=fmt.tprintf("%s/a.png",folder),fmt.tprintf("%s/b.png",folder)
    out:=fmt.tprintf("%s/montage.png",folder)
    testing.expect_value(t,image_write(first,solid(4,4,255,0,0)),Error.None)
    testing.expect_value(t,image_write(second,solid(8,8,0,0,255)),Error.None)
    error,failed:=image_montage({first,second},out,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    montage,load_error:=image_load(out,context.temp_allocator)
    testing.expect_value(t,load_error,Error.None)
    testing.expect_value(t,montage.width,8)
    testing.expect_value(t,montage.height,4)
    testing.expect_value(t,montage.pixels[0],u8(255))
    testing.expect_value(t,montage.pixels[(0*8+4)*4+2],u8(255))
    testing.expect_value(t,montage.pixels[(3*8+7)*4+2],u8(255))

    missing:=fmt.tprintf("%s/missing.png",folder)
    error,failed=image_montage({first,missing},out,context.temp_allocator)
    testing.expect_value(t,error,Error.Unreadable)
    testing.expect_value(t,failed,missing)
    error,_=image_montage({},out,context.temp_allocator)
    testing.expect_value(t,error,Error.Bad_Count)
}

@(test)
a_sheet_tiles_evenly_spaced_frames_in_order_each_with_its_number :: proc(t:^testing.T) {
    // 9 of 31 frames: the first, the last and every 30/8 between, each shown once.
    shown:[9]int
    for k in 0..<9 {
        shown[k]=sheet_frame(k,9,31)
        testing.expect_value(t,sheet_tile(shown[k],9,31),k)
    }
    testing.expect(t,shown[0]==0 && shown[8]==30 && shown[4]==15)
    for k in 1..<9 {testing.expect(t,shown[k]>shown[k-1])}
    testing.expect_value(t,sheet_tile(1,9,31),-1)
    testing.expect_value(t,sheet_frame(0,1,31),0)

    sheet,error:=sheet_make(5,320,180,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    defer sheet_destroy(&sheet)
    testing.expect(t,sheet.columns==3 && sheet.rows==2 && sheet.tile==[2]int{320,180})
    testing.expect_value(t,sheet.image.width,3*320+2*SHEET_GAP)
    frame:=make([]f32,320*180*4,context.temp_allocator)
    for i in 0..<320*180 {frame[i*4+1]=0.5}
    frame[0]=math.nan_f32()
    testing.expect_value(t,sheet_put(&sheet,4,frame,320,180,false,0),Error.None)
    testing.expect_value(t,sheet_put(&sheet,0,frame,320,180,true,1234567),Error.None)
    at :: proc(s:^Sheet,x,y:int) -> [4]u8 {
        p:=s.image.pixels[(y*s.image.width+x)*4:][:4]
        return {p[0],p[1],p[2],p[3]}
    }
    // Tile 4 is second in the second row, past a gap; its middle is the frame as stored.
    middle:=at(&sheet,320+SHEET_GAP+160,180+SHEET_GAP+90)
    testing.expect_value(t,middle,[4]u8{0,128,0,255})
    // Tile 0 encodes linear light; its corner has the number in white on black.
    testing.expect_value(t,at(&sheet,160,90)[1],u8(188))
    white,black:=0,0
    for y in 0..<20 {
        for x in 0..<120 {
            p:=at(&sheet,x,y)
            if p=={255,255,255,255} {white+=1} else if p=={0,0,0,255} {black+=1}
        }
    }
    testing.expect(t,white>0 && black>0,"the label is drawn")
    testing.expect_value(t,at(&sheet,320+SHEET_GAP+160,90),[4]u8{0,0,0,255})
    testing.expect_value(t,sheet_put(&sheet,5,frame,320,180,false,0),Error.Bad_Count)
    testing.expect_value(t,sheet_put(&sheet,0,frame[:4],320,180,false,0),Error.Empty)
    _,error=sheet_make(0,320,180)
    testing.expect_value(t,error,Error.Bad_Count)
    _,error=sheet_make(SHEET_CAPACITY+1,320,180)
    testing.expect_value(t,error,Error.Bad_Count)
}

@(test)
a_sheet_of_given_columns_takes_regions_of_frames_black_outside_them :: proc(t:^testing.T) {
    sheet,error:=sheet_make(5,40,20,context.temp_allocator,columns=2)
    testing.expect_value(t,error,Error.None)
    defer sheet_destroy(&sheet)
    testing.expect(t,sheet.columns==2 && sheet.rows==3 && sheet.tile==[2]int{40,20})
    pixels:=make([]u8,100*50*4,context.temp_allocator)
    for i in 0..<100*50 {pixels[i*4],pixels[i*4+3]=200,255}
    frame:=Image{pixels=pixels,width=100,height=50}
    // Tile 3 is the second of the second row; its region goes past the right edge of the frame.
    testing.expect_value(t,sheet_put_region(&sheet,3,frame,{80,10,40,20},7),Error.None)
    at :: proc(s:^Sheet,x,y:int) -> [4]u8 {
        p:=s.image.pixels[(y*s.image.width+x)*4:][:4]
        return {p[0],p[1],p[2],p[3]}
    }
    left,top:=40+SHEET_GAP,20+SHEET_GAP
    testing.expect_value(t,at(&sheet,left+10,top+15),[4]u8{200,0,0,255})
    testing.expect_value(t,at(&sheet,left+30,top+15),[4]u8{0,0,0,255})
    testing.expect_value(t,at(&sheet,left+10,15),[4]u8{0,0,0,255})
    testing.expect_value(t,sheet_put_region(&sheet,5,frame,{0,0,40,20},0),Error.Bad_Count)
    testing.expect_value(t,sheet_put_region(&sheet,0,frame,{0,0,0,20},0),Error.Empty)
    testing.expect_value(t,sheet_put_region(&sheet,0,frame,{max(int)/2,0,40,20},0),Error.Bad_Region)
    _,error=sheet_make(4,40,20,columns=-1)
    testing.expect_value(t,error,Error.Bad_Count)
}

// A wall lit in a gradient, with blotches of `strength` of its light every
// `every` pixels, `size` pixels wide.
wall :: proc(width,height:int,scale,strength:f64,every,size:int) -> Image {
    image:=solid(width,height,0,0,0)
    for y in 0..<height {
        for x in 0..<width {
            light:=(0.2+0.3*f64(x)/f64(width))*scale
            dx,dy:=(x%every)-every/2,(y%every)-every/2
            if dx*dx+dy*dy<size*size/4 {light*=1+strength*(((x/every+y/every)%2==0)?1:-1)}
            value:=u8(clamp(math.pow(light,1/2.2)*255,0,255))
            image.pixels[(y*width+x)*4],image.pixels[(y*width+x)*4+1],image.pixels[(y*width+x)*4+2]=value,value,value
        }
    }
    return image
}

@(test)
mottle_finds_blotches_and_leaves_out_exposure :: proc(t:^testing.T) {
    settled:=wall(480,900,1,0,1,0)
    same,error:=image_mottle(settled,settled,{},nil,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,same.mean,0.0)
    testing.expect(t,same.smooth>90,"a gradient is smooth")
    brighter,_:=image_mottle(wall(480,900,1.3,0,1,0),settled,{},nil,context.temp_allocator)
    testing.expectf(t,brighter.mean<0.2 && brighter.area<1,"an exposure change is no blotch: %v",brighter)
    blotched:=wall(480,900,1,0.15,72,36)
    mottle:Image_Mottle
    mottle_map:Image
    mottle,error=image_mottle(blotched,settled,{},&mottle_map,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    testing.expectf(t,mottle.mean>1 && mottle.area>10,"blotches of 15 %% show: %v",mottle)
    testing.expect_value(t,mottle_map.width,480)
    _,mismatch:=image_mottle(blotched,solid(480,899,0,0,0),{},nil,context.temp_allocator)
    testing.expect_value(t,mismatch,Error.Size_Mismatch)
}

@(test)
mottle_leaves_out_texture_a_moving_image_blurs :: proc(t:^testing.T) {
    sharp:=solid(400,300,0,0,0)
    soft:=solid(400,300,0,0,0)
    for y in 0..<300 {
        for x in 0..<400 {
            checker:=((x/6+y/6)%2==0)
            value:=u8(checker?200:60)
            near:=u8(checker?170:90)
            sharp.pixels[(y*400+x)*4],sharp.pixels[(y*400+x)*4+1],sharp.pixels[(y*400+x)*4+2]=value,value,value
            soft.pixels[(y*400+x)*4],soft.pixels[(y*400+x)*4+1],soft.pixels[(y*400+x)*4+2]=near,near,near
        }
    }
    mottle,error:=image_mottle(soft,sharp,{},nil,context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    testing.expectf(t,mottle.smooth<5 && mottle.area<1,"a texture is not smooth: %v",mottle)
}

@(test)
a_file_that_is_not_an_image_is_refused :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"image")
    if folder=="" {return}
    path:=fmt.tprintf("%s/text.png",folder)
    _=os.write_entire_file(path,"not a png")
    _,error:=image_load(path,context.temp_allocator)
    testing.expect_value(t,error,Error.Undecodable)
}

// A 4x2 image whose pixel x, y has red 10*x, green 10*y and blue 7.
@(private="file")
ramp :: proc() -> Image {
    image:=solid(4,2,0,0,7)
    for y in 0..<2 {for x in 0..<4 {image.pixels[(y*4+x)*4],image.pixels[(y*4+x)*4+1]=u8(10*x),u8(10*y)}}
    return image
}

@(test)
crop_and_zoom_keep_the_pixels_of_the_region :: proc(t:^testing.T) {
    image:=ramp()
    cropped,error:=image_crop(image,{1,1,2,1},context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,[2]int{cropped.width,cropped.height},[2]int{2,1})
    testing.expect_value(t,[4]u8{cropped.pixels[0],cropped.pixels[1],cropped.pixels[2],cropped.pixels[3]},[4]u8{10,10,7,255})
    testing.expect_value(t,cropped.pixels[4],u8(20))
    zoomed,zoom_error:=image_zoom(image,{2,0,2,2},3,context.temp_allocator)
    testing.expect_value(t,zoom_error,Error.None)
    testing.expect_value(t,[2]int{zoomed.width,zoomed.height},[2]int{6,6})
    for y in 0..<6 {
        for x in 0..<6 {
            pixel:=zoomed.pixels[(y*6+x)*4:]
            testing.expectf(t,pixel[0]==u8(10*(2+x/3)) && pixel[1]==u8(10*(y/3)),"%d,%d is the pixel %d,%d: %v",x,y,2+x/3,y/3,pixel[:4])
        }
    }
    _,outside:=image_crop(image,{3,0,2,1},context.temp_allocator)
    testing.expect_value(t,outside,Error.Bad_Region)
    _,huge:=image_zoom(image,{},ZOOM_MAX_FACTOR+1,context.temp_allocator)
    testing.expect_value(t,huge,Error.Too_Large)
}

@(test)
a_pixel_has_its_stored_values_and_linear_luminance :: proc(t:^testing.T) {
    image:=ramp()
    image.pixels[(1*4+3)*4],image.pixels[(1*4+3)*4+1],image.pixels[(1*4+3)*4+2]=255,255,255
    rgba,luma,error:=image_pixel(image,3,1)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,rgba,[4]u8{255,255,255,255})
    testing.expect(t,math.abs(luma-1)<1e-5,"white is 1")
    rgba,luma,error=image_pixel(image,0,0)
    testing.expect_value(t,rgba,[4]u8{0,0,7,255})
    testing.expect(t,luma>0 && luma<0.001,"dark blue is almost black")
    _,_,error=image_pixel(image,4,0)
    testing.expect_value(t,error,Error.Bad_Region)
    _,_,error=image_pixel(image,0,-1)
    testing.expect_value(t,error,Error.Bad_Region)
}
