package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import img "mirai:cook/image"

// mirai image: compares and describes PNG captures. Results go to stdout as
// JSON; what went wrong goes to stderr as "mirai image <subcommand>: <reason>".
// Exit codes: 0 done or the threshold met, 1 the threshold not met, 2 misuse
// or an unreadable image.

IMAGE_USAGE :: "image <diff|mottle|stats|montage|crop|zoom|pick> [arguments]"

@(private="file")
DIFF_USAGE :: "mirai image diff <a.png> <b.png> [--metric ssim|psnr|mae|rmse] [--threshold X] [--region x,y,w,h] [--pixel-threshold N] [--out diff.png]"
@(private="file")
MOTTLE_USAGE :: "mirai image mottle <moving.png> <settled.png> [--region x,y,w,h] [--out mottle.png]"
@(private="file")
STATS_USAGE :: "mirai image stats <a.png> [<b.png>...] [--region x,y,w,h]"
@(private="file")
MONTAGE_USAGE :: "mirai image montage <a.png> <b.png>... --out <x.png>"
@(private="file")
CROP_USAGE :: "mirai image crop <a.png> <x> <y> <w> <h> --out <x.png>"
@(private="file")
ZOOM_USAGE :: "mirai image zoom <a.png> <x> <y> <w> <h> [--factor N] --out <x.png>"
@(private="file")
PICK_USAGE :: "mirai image pick <a.png> <x> <y> [<x> <y>...]"

cmd_image :: proc(root:string,args:[]string) -> int {
    if len(args)>0 {
        switch args[0] {
        case "diff": return image_diff_command(args[1:])
        case "mottle": return image_mottle_command(args[1:])
        case "stats": return image_stats_command(args[1:])
        case "montage": return image_montage_command(args[1:])
        case "crop": return image_zoom_command("crop",args[1:])
        case "zoom": return image_zoom_command("zoom",args[1:])
        case "pick": return image_pick_command(args[1:])
        }
        fmt.eprintfln("mirai image: unknown subcommand '%s'",args[0])
    }
    fmt.eprintln("Usage:")
    fmt.eprintfln("  %s",DIFF_USAGE)
    fmt.eprintfln("  %s",MOTTLE_USAGE)
    fmt.eprintfln("  %s",STATS_USAGE)
    fmt.eprintfln("  %s",MONTAGE_USAGE)
    fmt.eprintfln("  %s",CROP_USAGE)
    fmt.eprintfln("  %s",ZOOM_USAGE)
    fmt.eprintfln("  %s",PICK_USAGE)
    return 2
}

@(private="file")
Image_Options :: struct {
    files:[dynamic]string,
    region:img.Region,
    metric:string,
    threshold:f64,
    has_threshold:bool,
    pixel_threshold:f64,
    factor:int,
    out:string,
}

// Reads files, flags and their values; the subcommand names which flags it accepts.
@(private="file")
image_options :: proc(command:string,args:[]string,flags:[]string) -> (options:Image_Options,ok:bool) {
    options.pixel_threshold=img.DEFAULT_PIXEL_THRESHOLD
    options.metric="ssim"
    options.factor=ZOOM_FACTOR
    for at:=0;at<len(args);at+=1 {
        arg:=args[at]
        if positional(arg) {append(&options.files,arg);continue}
        accepted:=false
        for flag in flags {accepted||=flag==arg}
        if !accepted {argument_refuse(fmt.tprintf("image %s",command),arg);return {},false}
        at+=1
        if at>=len(args) {fmt.eprintfln("mirai image %s: %s needs a value",command,arg);return {},false}
        value:=args[at]
        switch arg {
        case "--metric":
            if value!="ssim" && value!="psnr" && value!="mae" && value!="rmse" {fmt.eprintfln("mirai image %s: --metric is ssim, psnr, mae or rmse, not '%s'",command,value);return {},false}
            options.metric=value
        case "--threshold":
            number,parsed:=strconv.parse_f64(value)
            if !parsed || math.is_nan(number) {fmt.eprintfln("mirai image %s: --threshold needs a number, not '%s'",command,value);return {},false}
            options.threshold,options.has_threshold=number,true
        case "--pixel-threshold":
            number,parsed:=strconv.parse_f64(value)
            if !parsed || number<0 || number>255 {fmt.eprintfln("mirai image %s: --pixel-threshold needs a number from 0 to 255, not '%s'",command,value);return {},false}
            options.pixel_threshold=number
        case "--region":
            parts:=strings.split(value,",",context.temp_allocator)
            valid:=len(parts)==4
            numbers:[4]int
            for i in 0..<min(len(parts),4) {
                number,parsed:=strconv.parse_int(parts[i])
                valid&&=parsed
                numbers[i]=number
            }
            if !valid || numbers[0]<0 || numbers[1]<0 || numbers[2]<=0 || numbers[3]<=0 {
                fmt.eprintfln("mirai image %s: --region needs x,y,w,h with x,y >= 0 and w,h > 0, not '%s'",command,value)
                return {},false
            }
            options.region={numbers[0],numbers[1],numbers[2],numbers[3]}
        case "--factor":
            number,parsed:=strconv.parse_int(value)
            if !parsed || number<1 || number>img.ZOOM_MAX_FACTOR {fmt.eprintfln("mirai image %s: --factor needs an integer from 1 to %d, not '%s'",command,img.ZOOM_MAX_FACTOR,value);return {},false}
            options.factor=number
        case "--out": options.out=value
        }
    }
    return options,true
}

@(private="file")
image_load_or_report :: proc(command,path:string) -> (image:img.Image,ok:bool) {
    error:img.Error
    image,error=img.image_load(path)
    if error!=.None {fmt.eprintfln("mirai image %s: %s: %s",command,path,img.error_message(error));return {},false}
    return image,true
}

@(private="file")
json_text :: proc(text:string) -> string {
    data,error:=json.marshal(text,{},context.temp_allocator)
    return error==nil?string(data):"\"\""
}

// JSON has no infinity: the PSNR of equal images is null.
@(private="file")
json_number :: proc(value:f64) -> string {
    return math.is_inf(value)?"null":fmt.tprintf("%.6f",value)
}

@(private="file")
print_region :: proc(region:img.Region) {
    fmt.printfln("  \"region\": {{\"x\": %d, \"y\": %d, \"w\": %d, \"h\": %d}},",region.x,region.y,region.w,region.h)
}

@(private="file")
image_diff_command :: proc(args:[]string) -> int {
    options,ok:=image_options("diff",args,{"--metric","--threshold","--region","--pixel-threshold","--out"})
    if !ok || len(options.files)!=2 {fmt.eprintln("Usage:",DIFF_USAGE);return 2}
    a,loaded_a:=image_load_or_report("diff",options.files[0])
    if !loaded_a {return 2}
    defer img.image_destroy(&a)
    b,loaded_b:=image_load_or_report("diff",options.files[1])
    if !loaded_b {return 2}
    defer img.image_destroy(&b)
    if a.width!=b.width || a.height!=b.height {
        fmt.eprintfln("mirai image diff: %s is %dx%d and %s is %dx%d; %s",options.files[0],a.width,a.height,options.files[1],b.width,b.height,img.error_message(.Size_Mismatch))
        return 2
    }
    area,region_error:=img.region_resolve(a,options.region)
    if region_error!=.None {
        fmt.eprintfln("mirai image diff: the image is %dx%d; %s",a.width,a.height,img.error_message(region_error))
        return 2
    }
    map_image:img.Image
    diff,error:=img.image_diff(a,b,options.region,options.pixel_threshold,options.out!=""?&map_image:nil)
    if error!=.None {fmt.eprintfln("mirai image diff: %s",img.error_message(error));return 2}
    if options.out!="" {
        defer img.image_destroy(&map_image)
        if write_error:=img.image_write(options.out,map_image);write_error!=.None {
            fmt.eprintfln("mirai image diff: %s: %s",options.out,img.error_message(write_error))
            return 2
        }
    }
    value:f64
    switch options.metric {
    case "ssim": value=diff.ssim
    case "psnr": value=diff.psnr
    case "mae": value=diff.mae
    case "rmse": value=diff.rmse
    }
    // Similarity measures fail below the threshold, error measures above it.
    met:=true
    if options.has_threshold {met=options.metric=="ssim" || options.metric=="psnr"?value>=options.threshold:value<=options.threshold}
    fmt.println("{")
    fmt.printfln("  \"a\": %s,",json_text(options.files[0]))
    fmt.printfln("  \"b\": %s,",json_text(options.files[1]))
    fmt.printfln("  \"width\": %d,\n  \"height\": %d,",a.width,a.height)
    print_region(area)
    fmt.printfln("  \"pixels\": %d,",diff.pixels)
    fmt.printfln("  \"luma\": {{\"mae\": %s, \"rmse\": %s, \"psnr\": %s, \"ssim\": %s, \"max_error\": %s, \"excess\": %s}},",json_number(diff.mae),json_number(diff.rmse),json_number(diff.psnr),json_number(diff.ssim),json_number(diff.max_error),json_number(diff.excess))
    names:=[3]string{"r","g","b"}
    fmt.println("  \"channels\": {")
    for channel,i in diff.channels {
        fmt.printfln("    \"%s\": {{\"mae\": %s, \"rmse\": %s, \"psnr\": %s, \"max_error\": %s}}%s",names[i],json_number(channel.mae),json_number(channel.rmse),json_number(channel.psnr),json_number(channel.max_error),i<2?",":"")
    }
    fmt.println("  },")
    fmt.printfln("  \"pixel_threshold\": %s,",json_number(options.pixel_threshold))
    fmt.printfln("  \"over_threshold_percent\": %s,",json_number(diff.over_threshold_percent))
    if options.out!="" {fmt.printfln("  \"diff_map\": %s,",json_text(options.out))}
    if options.has_threshold {
        fmt.printfln("  \"metric\": \"%s\",\n  \"value\": %s,\n  \"threshold\": %s,\n  \"pass\": %v",options.metric,json_number(value),json_number(options.threshold),met)
    } else {
        fmt.printfln("  \"metric\": \"%s\",\n  \"value\": %s",options.metric,json_number(value))
    }
    fmt.println("}")
    return met?0:1
}

// The blotches of light the first image has over the second, a capture of
// the same view settled (img.image_mottle).
@(private="file")
image_mottle_command :: proc(args:[]string) -> int {
    options,ok:=image_options("mottle",args,{"--region","--out"})
    if !ok || len(options.files)!=2 {fmt.eprintln("Usage:",MOTTLE_USAGE);return 2}
    a,loaded_a:=image_load_or_report("mottle",options.files[0])
    if !loaded_a {return 2}
    defer img.image_destroy(&a)
    b,loaded_b:=image_load_or_report("mottle",options.files[1])
    if !loaded_b {return 2}
    defer img.image_destroy(&b)
    if a.width!=b.width || a.height!=b.height {
        fmt.eprintfln("mirai image mottle: %s is %dx%d and %s is %dx%d; %s",options.files[0],a.width,a.height,options.files[1],b.width,b.height,img.error_message(.Size_Mismatch))
        return 2
    }
    area,region_error:=img.region_resolve(a,options.region)
    if region_error!=.None {
        fmt.eprintfln("mirai image mottle: the image is %dx%d; %s",a.width,a.height,img.error_message(region_error))
        return 2
    }
    map_image:img.Image
    mottle,error:=img.image_mottle(a,b,options.region,options.out!=""?&map_image:nil)
    if error!=.None {fmt.eprintfln("mirai image mottle: %s",img.error_message(error));return 2}
    if options.out!="" {
        defer img.image_destroy(&map_image)
        if write_error:=img.image_write(options.out,map_image);write_error!=.None {
            fmt.eprintfln("mirai image mottle: %s: %s",options.out,img.error_message(write_error))
            return 2
        }
    }
    fmt.println("{")
    fmt.printfln("  \"a\": %s,",json_text(options.files[0]))
    fmt.printfln("  \"b\": %s,",json_text(options.files[1]))
    print_region(area)
    fmt.printfln("  \"mean_percent\": %s,",json_number(mottle.mean))
    fmt.printfln("  \"area_percent\": %s,",json_number(mottle.area))
    if options.out!="" {fmt.printfln("  \"mottle_map\": %s,",json_text(options.out))}
    fmt.printfln("  \"smooth_percent\": %s",json_number(mottle.smooth))
    fmt.println("}")
    return 0
}

@(private="file")
image_stats_command :: proc(args:[]string) -> int {
    options,ok:=image_options("stats",args,{"--region"})
    if !ok || len(options.files)==0 {fmt.eprintln("Usage:",STATS_USAGE);return 2}
    if len(options.files)>1 {return image_sequence_stats(options)}
    image,loaded:=image_load_or_report("stats",options.files[0])
    if !loaded {return 2}
    defer img.image_destroy(&image)
    area,region_error:=img.region_resolve(image,options.region)
    if region_error!=.None {
        fmt.eprintfln("mirai image stats: the image is %dx%d; %s",image.width,image.height,img.error_message(region_error))
        return 2
    }
    stats,error:=img.image_stats(image,options.region)
    if error!=.None {fmt.eprintfln("mirai image stats: %s",img.error_message(error));return 2}
    fmt.println("{")
    fmt.printfln("  \"file\": %s,",json_text(options.files[0]))
    fmt.printfln("  \"width\": %d,\n  \"height\": %d,",image.width,image.height)
    print_region(area)
    fmt.printfln("  \"pixels\": %d,",stats.pixels)
    fmt.printfln("  \"mean_luma\": %s,",json_number(f64(stats.mean_luma)))
    fmt.printfln("  \"percentiles\": {{\"p5\": %s, \"p50\": %s, \"p95\": %s}},",json_number(f64(stats.p5)),json_number(f64(stats.p50)),json_number(f64(stats.p95)))
    fmt.printfln("  \"black_percent\": %s,",json_number(f64(stats.black_percent)))
    fmt.printfln("  \"saturated_percent\": %s,",json_number(f64(stats.saturated_percent)))
    fmt.printfln("  \"mean\": {{\"r\": %s, \"g\": %s, \"b\": %s}}",json_number(f64(stats.mean[0])),json_number(f64(stats.mean[1])),json_number(f64(stats.mean[2])))
    fmt.println("}")
    return 0
}

// The stats of each frame of a sequence, one per line, and how its mean
// luminance moves: from the frame before (delta_luma), its spread and its
// largest step. A sequence of captures of a still scene should not move.
@(private="file")
image_sequence_stats :: proc(options:Image_Options) -> int {
    lumas:=make([]f64,len(options.files),context.temp_allocator)
    lines:=make([]string,len(options.files),context.temp_allocator)
    for file,i in options.files {
        image,loaded:=image_load_or_report("stats",file)
        if !loaded {return 2}
        defer img.image_destroy(&image)
        if _,region_error:=img.region_resolve(image,options.region);region_error!=.None {
            fmt.eprintfln("mirai image stats: %s is %dx%d; %s",file,image.width,image.height,img.error_message(region_error))
            return 2
        }
        stats,error:=img.image_stats(image,options.region)
        if error!=.None {fmt.eprintfln("mirai image stats: %s: %s",file,img.error_message(error));return 2}
        lumas[i]=f64(stats.mean_luma)
        delta:="null"
        if i>0 {delta=json_number(lumas[i]-lumas[i-1])}
        lines[i]=fmt.tprintf("{{\"file\": %s, \"width\": %d, \"height\": %d, \"mean_luma\": %s, \"p5\": %s, \"p50\": %s, \"p95\": %s, \"black_percent\": %s, \"saturated_percent\": %s, \"delta_luma\": %s}}",
            json_text(file),image.width,image.height,json_number(lumas[i]),json_number(f64(stats.p5)),json_number(f64(stats.p50)),json_number(f64(stats.p95)),
            json_number(f64(stats.black_percent)),json_number(f64(stats.saturated_percent)),delta)
    }
    mean,max_delta,least,most:=0.0,0.0,lumas[0],lumas[0]
    largest:=1
    for luma,i in lumas {
        mean+=luma/f64(len(lumas))
        least,most=min(least,luma),max(most,luma)
        if i>0 && abs(luma-lumas[i-1])>max_delta {max_delta,largest=abs(luma-lumas[i-1]),i}
    }
    variance:=0.0
    for luma in lumas {variance+=(luma-mean)*(luma-mean)/f64(len(lumas))}
    fmt.println("{\n  \"frames\": [")
    for line,i in lines {fmt.printfln("    %s%s",line,i<len(lines)-1?",":"")}
    fmt.println("  ],")
    fmt.printfln("  \"mean_luma\": {{\"mean\": %s, \"stddev\": %s, \"min\": %s, \"max\": %s, \"max_delta\": %s, \"max_delta_file\": %s}}",
        json_number(mean),json_number(math.sqrt(variance)),json_number(least),json_number(most),json_number(max_delta),json_text(options.files[largest]))
    fmt.println("}")
    return 0
}

@(private="file")
image_montage_command :: proc(args:[]string) -> int {
    options,ok:=image_options("montage",args,{"--out"})
    if !ok || len(options.files)<2 || options.out=="" {fmt.eprintln("Usage:",MONTAGE_USAGE);return 2}
    error,failed:=img.image_montage(options.files[:],options.out)
    if error!=.None {fmt.eprintfln("mirai image montage: %s: %s",failed,img.error_message(error));return 2}
    fmt.printfln("{{\"out\": %s, \"images\": %d}}",json_text(options.out),len(options.files))
    return 0
}

// What zoom enlarges each pixel by when --factor is not given.
ZOOM_FACTOR :: 8

// The integers after the image: separate arguments or joined by commas,
// as 10 20 or 10,20.
@(private="file")
image_integers :: proc(command:string,args:[]string) -> (numbers:[dynamic]int,ok:bool) {
    numbers=make([dynamic]int,context.temp_allocator)
    for arg in args {
        for part in strings.split(arg,",",context.temp_allocator) {
            number,parsed:=strconv.parse_int(part,10)
            if !parsed {fmt.eprintfln("mirai image %s: '%s' is not an integer number of pixels",command,part);return numbers,false}
            append(&numbers,number)
        }
    }
    return numbers,true
}

// mirai image crop and zoom: a region of the image, as it is or with each
// pixel a square of --factor pixels, to look at it closely.
@(private="file")
image_zoom_command :: proc(command:string,args:[]string) -> int {
    usage:=command=="crop"?CROP_USAGE:ZOOM_USAGE
    options,ok:=image_options(command,args,command=="crop"?[]string{"--out"}:[]string{"--factor","--out"})
    if !ok || len(options.files)<2 || options.out=="" {fmt.eprintln("Usage:",usage);return 2}
    numbers,parsed:=image_integers(command,options.files[1:])
    if !parsed || len(numbers)!=4 {fmt.eprintln("Usage:",usage);return 2}
    region:=img.Region{numbers[0],numbers[1],numbers[2],numbers[3]}
    factor:=command=="crop"?1:options.factor
    image,loaded:=image_load_or_report(command,options.files[0])
    if !loaded {return 2}
    defer img.image_destroy(&image)
    if region.w<=0 || region.h<=0 {
        fmt.eprintfln("mirai image %s: the image is %dx%d; %s",command,image.width,image.height,img.error_message(.Bad_Region))
        return 2
    }
    zoomed,error:=img.image_zoom(image,region,factor)
    if error!=.None {fmt.eprintfln("mirai image %s: the image is %dx%d; %s",command,image.width,image.height,img.error_message(error));return 2}
    defer img.image_destroy(&zoomed)
    if write_error:=img.image_write(options.out,zoomed);write_error!=.None {
        fmt.eprintfln("mirai image %s: %s: %s",command,options.out,img.error_message(write_error))
        return 2
    }
    fmt.println("{")
    fmt.printfln("  \"file\": %s,",json_text(options.files[0]))
    print_region(region)
    if command=="zoom" {fmt.printfln("  \"factor\": %d,",factor)}
    fmt.printfln("  \"width\": %d,\n  \"height\": %d,",zoomed.width,zoomed.height)
    fmt.printfln("  \"out\": %s",json_text(options.out))
    fmt.println("}")
    return 0
}

// The values of pixels: RGBA as stored and the luminance, linear 0..1 as in stats.
@(private="file")
image_pick_command :: proc(args:[]string) -> int {
    options,ok:=image_options("pick",args,{})
    if !ok || len(options.files)<3 {fmt.eprintln("Usage:",PICK_USAGE);return 2}
    numbers,parsed:=image_integers("pick",options.files[1:])
    if !parsed || len(numbers)%2!=0 {fmt.eprintln("Usage:",PICK_USAGE);return 2}
    image,loaded:=image_load_or_report("pick",options.files[0])
    if !loaded {return 2}
    defer img.image_destroy(&image)
    lines:=make([]string,len(numbers)/2,context.temp_allocator)
    for &line,i in lines {
        x,y:=numbers[i*2],numbers[i*2+1]
        rgba,luma,error:=img.image_pixel(image,x,y)
        if error!=.None {
            fmt.eprintfln("mirai image pick: %d,%d is outside the %dx%d image: x goes from 0 to %d and y from 0 to %d",x,y,image.width,image.height,image.width-1,image.height-1)
            return 2
        }
        line=fmt.tprintf("{{\"x\": %d, \"y\": %d, \"r\": %d, \"g\": %d, \"b\": %d, \"a\": %d, \"luma\": %s}}",x,y,rgba[0],rgba[1],rgba[2],rgba[3],json_number(f64(luma)))
    }
    fmt.println("{")
    fmt.printfln("  \"file\": %s,",json_text(options.files[0]))
    fmt.printfln("  \"width\": %d,\n  \"height\": %d,",image.width,image.height)
    fmt.println("  \"pixels\": [")
    for line,i in lines {fmt.printfln("    %s%s",line,i<len(lines)-1?",":"")}
    fmt.println("  ]")
    fmt.println("}")
    return 0
}
