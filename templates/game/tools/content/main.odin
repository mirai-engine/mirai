package main

import "core:fmt"
import "core:math"
import "core:os"
import "mirai:asset"
import importer "mirai:cook/import"

// Writes what no art source holds: a badge (.tex) and a hum (.sound, imported
// from the WAV this writes into source/). The scene, the prefabs and the .ui of
// assets/ are their own source: the API and the editor edit those files and
// nothing here writes them. mirai content runs it.

PROJECT :: "game_content"
BADGE_SIZE :: 64
HUM_RATE :: 22050
HUM_SECONDS :: 2

// An orange disc with a white core, transparent around it.
write_badge :: proc(c:^asset.Content) {
    id:=asset.content_id(PROJECT,"texture","badge")
    pixels:=make([]u8,BADGE_SIZE*BADGE_SIZE*4,context.temp_allocator)
    coverage :: proc(distance,radius:f32) -> f32 {return clamp(radius-distance+0.5,0,1)}
    for y in 0..<BADGE_SIZE {
        for x in 0..<BADGE_SIZE {
            distance:=math.sqrt(math.pow(f32(x)+0.5-BADGE_SIZE/2,2)+math.pow(f32(y)+0.5-BADGE_SIZE/2,2))
            core:=coverage(distance,12)
            color:=[3]f32{255,170,40}*(1-core)+[3]f32{255,255,255}*core
            at:=(y*BADGE_SIZE+x)*4
            pixels[at],pixels[at+1],pixels[at+2]=u8(color.r),u8(color.g),u8(color.b)
            pixels[at+3]=u8(255*coverage(distance,30))
        }
    }
    asset.content_check(c,"assets/hud/badge.tex",asset.texture_save("assets/hud/badge.tex",&c.types,
        {id=id,width=BADGE_SIZE,height=BADGE_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
}

// Two seconds of a low hum that loops without a click: every partial fits a
// whole number of times. The WAV is the source; the .sound is its import.
write_hum :: proc(c:^asset.Content) {
    FRAMES :: HUM_RATE*HUM_SECONDS
    file:=make([]u8,44+FRAMES*2,context.temp_allocator)
    le :: proc(file:[]u8,at:int,value:u32,size:int) {for i in 0..<size {file[at+i]=u8(value>>uint(8*i))}}
    copy(file,"RIFF");le(file,4,u32(len(file)-8),4);copy(file[8:],"WAVEfmt ")
    le(file,16,16,4);le(file,20,1,2);le(file,22,1,2);le(file,24,HUM_RATE,4);le(file,28,HUM_RATE*2,4);le(file,32,2,2);le(file,34,16,2)
    copy(file[36:],"data");le(file,40,FRAMES*2,4)
    for frame in 0..<FRAMES {
        t:=f64(frame)/HUM_RATE
        wave:=0.5*math.sin(2*math.PI*110*t)+0.25*math.sin(2*math.PI*220*t)+0.12*math.sin(2*math.PI*330*t)
        tremolo:=0.75+0.25*math.sin(2*math.PI*1.5*t)
        le(file,44+frame*2,u32(u16(i16(wave*tremolo*20000))),2)
    }
    os.make_directory_all("source/sounds")
    // Written only when it differs, so that the import of an unchanged source is the same file.
    existing,read_error:=os.read_entire_file("source/sounds/hum.wav",context.temp_allocator)
    if (read_error!=nil || string(existing)!=string(file)) && os.write_entire_file("source/sounds/hum.wav",file)!=nil {
        fmt.eprintln("content: source/sounds/hum.wav could not be written")
        c.failed=true
        return
    }
    report,error:=importer.import_sound("source/sounds/hum.wav","assets/arena",{},{root="."})
    if error.code!=.None {
        fmt.eprintfln("content: %s",error.message)
        c.failed=true
        return
    }
    defer importer.report_destroy(&report)
    fmt.printfln("imported %s",report.assets[0].path)
}

main :: proc() {
    c:asset.Content
    asset.content_init(&c,PROJECT)
    defer asset.content_destroy(&c)
    for folder in ([]string{"assets/arena","assets/hud"}) {os.make_directory_all(folder)}
    write_badge(&c)
    write_hum(&c)
    free_all(context.temp_allocator)
    if c.failed {os.exit(1)}
}
