package image

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import stbi "vendor:stb/image"
import "mirai:cook/textures"
import mm "mirai:std/math"

// Comparing and describing images for the agents that tune a look: PNG files
// to RGBA8, the difference between two images, the statistics of one, a
// montage of several, and a region cropped or enlarged and the values of
// single pixels to look closely. Alpha is ignored by every measure.
// Luminance is Rec. 709 over linear light, so a measure follows what the
// eye sees of light; the error of a channel is on its stored 0..255 value,
// the unit a pixel threshold is given in.

Image :: textures.Image

Error :: enum u8 {
    None,
    Unreadable,    // the file cannot be read
    Undecodable,   // not an image stb can decode, or too large
    Empty,         // no pixels
    Size_Mismatch, // two images of different size
    Bad_Region,    // outside the image, or with no area
    Bad_Count,     // a montage needs at least one image
    Too_Large,     // a zoom past ZOOM_MAX_FACTOR or ZOOM_MAX_SIDE
    Write_Failed,
    Out_Of_Memory,
}

error_message :: proc(error:Error) -> string {
    switch error {
    case .None: return "no error"
    case .Unreadable: return "the file could not be read: check the path and its permissions"
    case .Undecodable: return "not a valid PNG, JPEG, TGA or BMP image, or too large"
    case .Empty: return "the image has no pixels"
    case .Size_Mismatch: return "the images have different sizes: capture both at the same resolution"
    case .Bad_Region: return "the region falls outside the image or has no area: use an x,y,w,h inside its bounds"
    case .Bad_Count: return "images are missing"
    case .Too_Large: return fmt.tprintf("the factor goes from 1 to %d and the zoomed image is at most %d pixels on a side: use a smaller region or factor",ZOOM_MAX_FACTOR,ZOOM_MAX_SIDE)
    case .Write_Failed: return "the PNG could not be written: check that the folder exists and is writable"
    case .Out_Of_Memory: return "out of memory"
    }
    return "unknown error"
}

// A rectangle of pixels from the top left. Zero width and height: the whole image.
Region :: struct {x,y,w,h:int}

image_load :: proc(path:string,allocator:=context.allocator) -> (image:Image,error:Error) {
    bytes,read_error:=os.read_entire_file(path,allocator)
    if read_error!=nil {return {},.Unreadable}
    defer delete(bytes,allocator)
    decoded,decode_error:=textures.image_decode(bytes,allocator)
    switch decode_error {
    case .None: return decoded,.None
    case .Out_Of_Memory: return {},.Out_Of_Memory
    case .Unsupported,.Too_Large,.Invalid: return {},.Undecodable
    }
    return {},.Undecodable
}

image_destroy :: textures.image_destroy

image_write :: proc(path:string,image:Image) -> Error {
    if image.width<=0 || image.height<=0 || len(image.pixels)!=image.width*image.height*4 {return .Empty}
    file:=strings.clone_to_cstring(path,context.temp_allocator)
    defer delete(file,context.temp_allocator)
    if stbi.write_png(file,c.int(image.width),c.int(image.height),4,raw_data(image.pixels),c.int(image.width*4))==0 {return .Write_Failed}
    return .None
}

region_resolve :: proc(image:Image,region:Region) -> (resolved:Region,error:Error) {
    if image.width<=0 || image.height<=0 {return {},.Empty}
    if region.w==0 && region.h==0 && region.x==0 && region.y==0 {return {0,0,image.width,image.height},.None}
    if region.x<0 || region.y<0 || region.w<=0 || region.h<=0 || region.x+region.w>image.width || region.y+region.h>image.height {return {},.Bad_Region}
    return region,.None
}

// Linear light of each stored value, 0..1.
@(private)
linear_table :: proc() -> (table:[256]f32) {
    for i in 0..<256 {
        table[i]=mm.srgb_to_linear(f32(i)/255)
    }
    return
}

@(private)
luminance :: proc(table:^[256]f32,pixel:[]u8) -> f32 {
    return 0.2126*table[pixel[0]]+0.7152*table[pixel[1]]+0.0722*table[pixel[2]]
}

Image_Stats :: struct {
    pixels:int,
    mean_luma:f32,       // linear, 0..1
    p5,p50,p95:f32,      // percentiles of the linear luminance
    black_percent:f32,   // luminance below BLACK_LUMA
    saturated_percent:f32, // any channel at 254/255 or more
    mean:[3]f32,         // per channel on the stored value, 0..1
}

BLACK_LUMA :: 0.02
SATURATED_VALUE :: 254

image_stats :: proc(image:Image,region:Region,allocator:=context.allocator) -> (stats:Image_Stats,error:Error) {
    area:=region_resolve(image,region) or_return
    lumas,alloc_error:=make([]f32,area.w*area.h,allocator)
    if alloc_error!=nil {return {},.Out_Of_Memory}
    defer delete(lumas,allocator)
    table:=linear_table()
    sums:[3]f64
    luma_sum:f64
    black,saturated:int
    at:=0
    for y in area.y..<area.y+area.h {
        row:=image.pixels[(y*image.width+area.x)*4:]
        for x in 0..<area.w {
            pixel:=row[x*4:x*4+4]
            luma:=luminance(&table,pixel)
            lumas[at]=luma;at+=1
            luma_sum+=f64(luma)
            for channel in 0..<3 {sums[channel]+=f64(pixel[channel])}
            if luma<BLACK_LUMA {black+=1}
            if pixel[0]>=SATURATED_VALUE || pixel[1]>=SATURATED_VALUE || pixel[2]>=SATURATED_VALUE {saturated+=1}
        }
    }
    count:=len(lumas)
    slice.sort(lumas)
    percentile :: proc(sorted:[]f32,fraction:f64) -> f32 {
        return sorted[clamp(int(math.round(fraction*f64(len(sorted)-1))),0,len(sorted)-1)]
    }
    stats={
        pixels=count,
        mean_luma=f32(luma_sum/f64(count)),
        p5=percentile(lumas,0.05),p50=percentile(lumas,0.5),p95=percentile(lumas,0.95),
        black_percent=f32(f64(black)*100/f64(count)),
        saturated_percent=f32(f64(saturated)*100/f64(count)),
    }
    for channel in 0..<3 {stats.mean[channel]=f32(sums[channel]/f64(count)/255)}
    return stats,.None
}

// The pixel at x, y from the top left, and its luminance (linear, 0..1).
image_pixel :: proc(image:Image,x,y:int) -> (rgba:[4]u8,luma:f32,error:Error) {
    if image.width<=0 || image.height<=0 {return {},0,.Empty}
    if x<0 || y<0 || x>=image.width || y>=image.height {return {},0,.Bad_Region}
    copy(rgba[:],image.pixels[(y*image.width+x)*4:][:4])
    table:=linear_table()
    return rgba,luminance(&table,rgba[:]),.None
}

ZOOM_MAX_FACTOR :: 64
ZOOM_MAX_SIDE :: 16384

// The pixels of a region, each one a square of factor by factor pixels
// (nearest neighbour); a factor of 1 crops.
image_zoom :: proc(image:Image,region:Region,factor:int,allocator:=context.allocator) -> (zoomed:Image,error:Error) {
    area:=region_resolve(image,region) or_return
    if factor<1 || factor>ZOOM_MAX_FACTOR || area.w*factor>ZOOM_MAX_SIDE || area.h*factor>ZOOM_MAX_SIDE {return {},.Too_Large}
    width,height:=area.w*factor,area.h*factor
    pixels,alloc_error:=make([]u8,width*height*4,allocator)
    if alloc_error!=nil {return {},.Out_Of_Memory}
    for y in 0..<height {
        row:=pixels[y*width*4:][:width*4]
        if y%factor!=0 {copy(row,pixels[(y-1)*width*4:][:width*4]);continue}
        source:=image.pixels[((area.y+y/factor)*image.width+area.x)*4:][:area.w*4]
        if factor==1 {copy(row,source);continue}
        for x in 0..<width {copy(row[x*4:][:4],source[x/factor*4:][:4])}
    }
    return {pixels=pixels,width=width,height=height,allocator=allocator},.None
}

image_crop :: proc(image:Image,region:Region,allocator:=context.allocator) -> (cropped:Image,error:Error) {
    return image_zoom(image,region,1,allocator)
}

// The images side by side at the height of the first, in the order given;
// a taller or shorter one is scaled to that height by nearest neighbour.
image_montage :: proc(paths:[]string,out:string,allocator:=context.allocator) -> (error:Error,failed:string) {
    if len(paths)==0 {return .Bad_Count,""}
    images,alloc_error:=make([]Image,len(paths),allocator)
    if alloc_error!=nil {return .Out_Of_Memory,""}
    defer {
        for &image in images {if image.pixels!=nil {image_destroy(&image)}}
        delete(images,allocator)
    }
    for path,i in paths {
        loaded,load_error:=image_load(path,allocator)
        if load_error!=.None {return load_error,path}
        images[i]=loaded
    }
    height:=images[0].height
    width:=0
    for image in images {width+=image.height==height?image.width:max(1,(image.width*height+image.height/2)/image.height)}
    pixels,pixels_error:=make([]u8,width*height*4,allocator)
    if pixels_error!=nil {return .Out_Of_Memory,""}
    montage:=Image{pixels=pixels,width=width,height=height,allocator=allocator}
    defer image_destroy(&montage)
    left:=0
    for image in images {
        scaled:=image.height==height?image.width:max(1,(image.width*height+image.height/2)/image.height)
        for y in 0..<height {
            source_y:=image.height==height?y:min(image.height-1,y*image.height/height)
            for x in 0..<scaled {
                source_x:=image.height==height?x:min(image.width-1,x*image.width/scaled)
                copy(montage.pixels[(y*width+left+x)*4:][:4],image.pixels[(source_y*image.width+source_x)*4:][:4])
            }
        }
        left+=scaled
    }
    return image_write(out,montage),out
}
