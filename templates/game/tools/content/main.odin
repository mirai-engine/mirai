package main

import "core:fmt"
import "core:math"
import "core:os"
import "mirai:asset"
import "mirai:cook/content"
import importer "mirai:cook/import"
import world "generated:editor_world"

// Writes what no art source holds: a badge (.tex) and a hum (.sound, imported
// from the WAV this writes beside it). mirai content builds and runs it in the
// root of the project; content.Writer also writes tables of game data
// (records_write) and scenes (scene_write) from code (mirai docs content-tool).

PROJECT :: "game_content"
BADGE_SIZE :: 64
HUM_RATE :: 22050
HUM_SECONDS :: 2

// An orange disc with a white core, transparent around it.
write_badge :: proc(w:^content.Writer) {
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
    content.check(w,"assets/hud/badge.tex",asset.texture_save("assets/hud/badge.tex",&w.types,
        {id=id,width=BADGE_SIZE,height=BADGE_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
}

// Two seconds of a low hum that loops without a click: every partial fits a
// whole number of times. The WAV is the source; the .sound is its import.
write_hum :: proc(w:^content.Writer) {
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
    // Written only when it differs, so that the import of an unchanged source is the same file.
    if !content.source_write(w,"assets/arena/hum.wav",file) {return}
    report,error:=importer.import_sound("assets/arena/hum.wav",{},{root="."})
    if error.code!=.None {
        fmt.eprintfln("content: %s",error.message)
        w.failed=true
        return
    }
    importer.report_destroy(&report)
}

main :: proc() {
    w:content.Writer
    if !content.open(&w,world.info()) {os.exit(1)}
    for folder in ([]string{"assets/arena","assets/hud"}) {os.make_directory_all(folder)}
    write_badge(&w)
    write_hum(&w)
    free_all(context.temp_allocator)
    os.exit(content.close(&w))
}
