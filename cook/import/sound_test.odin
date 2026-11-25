package importer

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import audio "mirai:audio"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"

@(private="file") SINE_OGG :: #load("../../audio/testdata/sine_mono.ogg")           // 0.5 s of 440 Hz at 44.1 kHz, amplitude 0.5
@(private="file") THREE_OGG :: #load("../../audio/testdata/three_channels.ogg")
@(private="file") TONE_OGG :: #load("../../audio/testdata/tone_long.ogg")           // 2 s of 330 Hz at 32 kHz, mono
@(private="file") CLICK_OGG :: #load("../../audio/testdata/click.ogg")              // 20 ms of decaying noise, then silence to 1 s, at 44.1 kHz, mono
// 2 s at 44.1 kHz, mono: 1 s of silence, 12 kHz at amplitude 0.5 to frame 86000, silence; LOOPSTART=44100.
@(private="file") INTRO_OGG :: #load("../../audio/testdata/intro_tone.ogg")

// A WAV file of interleaved samples, 16 bit, or 24 with low the low byte of every sample.
@(private="file")
wav_bytes :: proc(samples:[]i16,channels,rate:int,allocator:=context.allocator,low:=-1) -> []u8 {
    size:=2 if low<0 else 3
    file:=make([]u8,44+len(samples)*size,allocator)
    put :: proc(file:[]u8,at:int,value:u32,size:int) {for i in 0..<size {file[at+i]=u8(value>>uint(8*i))}}
    copy(file,"RIFF");put(file,4,u32(len(file)-8),4);copy(file[8:],"WAVEfmt ")
    put(file,16,16,4);put(file,20,1,2);put(file,22,u32(channels),2);put(file,24,u32(rate),4);put(file,28,u32(rate*channels*size),4)
    put(file,32,u32(channels*size),2);put(file,34,u32(size*8),2)
    copy(file[36:],"data");put(file,40,u32(len(samples)*size),4)
    for sample,i in samples {
        value:=u32(u16(sample)) if low<0 else u32(u16(sample))<<8|u32(u8(low))
        put(file,44+i*size,value,size)
    }
    return file
}
// The samples of a lossless sound, as the mixer plays them.
@(private="file")
lossless_same :: proc(t:^testing.T,view:asset.Sound_View,samples:[]i16,loc:=#caller_location) -> bool {
    pcm,error:=audio.decode(view.lossless,context.temp_allocator)
    if !testing.expect_value(t,error,audio.Error.None,loc=loc) || !testing.expect_value(t,len(pcm.samples),len(samples),loc=loc) {return false}
    for sample,i in samples {
        if pcm.samples[i]!=f32(sample)*(1.0/32768) {return testing.expectf(t,false,"sample %d differs",i,loc=loc)}
    }
    return true
}

@(private="file")
sound_open :: proc(t:^testing.T,s:^store.Store,written:Written,types:^asset.Types,a:^asset.Asset) -> (view:asset.Sound_View,ok:bool) {
    if !testing.expect_value(t,written_open(s,written,a),asset.Error.None) {return}
    error:asset.Error
    view,error=asset.sound_view(a,types)
    return view,testing.expect_value(t,error,asset.Error.None)
}

@(test)
a_wav_and_an_ogg_become_sounds_coded_or_kept_as_their_file :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    _,folder,s:=test_assets(t,"sound")
    if folder=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)

    samples:=make([]i16,2*4410);defer delete(samples)
    for &sample,i in samples {sample=i16(12000*math.sin(f32(i/2)*2*math.PI*440/48000))*(i%2==0?1:-1)}
    samples[0],samples[1]=32767,-32768
    wav:=wav_bytes(samples,2,48000);defer delete(wav)
    path:=fmt.tprintf("%s/Step Left.wav",folder)
    _=os.write_entire_file(path,wav)

    report,error:=import_sound(path,options={store=s})
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,len(report.assets),1)
    if len(report.assets)==1 {
        written:=report.assets[0]
        testing.expect(t,written.kind==asset.KIND_SOUND && written.id!={} && written.object!={} && written.path=="" && written.bytes<len(samples)*2)
        a:asset.Asset
        if view,ok:=sound_open(t,s,written,&types,&a);ok {
            testing.expect(t,view.info^==asset.Sound_Info{2,48000,4410,0,.Lossless})
            lossless_same(t,view,samples)
            testing.expect(t,view.source!=nil && serial.text_field(view.source.importer[:])==IMPORTER_NAME && view.source.source_size==u64(len(wav)))
        }
        asset.asset_close(&a)
    }
    // Imported again it is the same asset, with the same coded samples.
    again,again_error:=import_sound(path,{store=s})
    testing.expect_value(t,again_error.code,Error_Code.None)
    if len(again.assets)==1 && len(report.assets)==1 {
        testing.expect(t,again.assets[0].id==report.assets[0].id)
        a:asset.Asset
        if view,ok:=sound_open(t,s,again.assets[0],&types,&a);ok {
            testing.expect(t,view.info^==asset.Sound_Info{2,48000,4410,0,.Lossless})
            lossless_same(t,view,samples)
        }
        asset.asset_close(&a)
    }
    report_destroy(&report);report_destroy(&again)

    // A 24 bit WAV told File keeps its file as it is, which 16 bits would round.
    deep:=wav_bytes(samples,2,48000,low=0x40);defer delete(deep)
    deep_path:=fmt.tprintf("%s/deep.wav",folder)
    _=os.write_entire_file(deep_path,deep)
    report,error=import_sound(deep_path,{store=s,sound=.File})
    testing.expect_value(t,error.code,Error_Code.None)
    if len(report.assets)==1 {
        a:asset.Asset
        if view,ok:=sound_open(t,s,report.assets[0],&types,&a);ok {
            testing.expect(t,view.info^==asset.Sound_Info{2,48000,4410,0,.File} && mem.compare(view.file,deep)==0)
        }
        asset.asset_close(&a)
    }
    report_destroy(&report)

    // Half a second of Vorbis at 44.1 kHz told Lossless: coded and brought to the rate of the mixer.
    ogg:=fmt.tprintf("%s/sine.ogg",folder)
    _=os.write_entire_file(ogg,SINE_OGG)
    report,error=import_sound(ogg,{store=s,sound=.Lossless})
    testing.expect_value(t,error.code,Error_Code.None)
    if len(report.assets)==1 {
        a:asset.Asset
        if view,ok:=sound_open(t,s,report.assets[0],&types,&a);ok {
            testing.expect(t,view.info.encoding==.Lossless && view.info.channels==1 && view.info.sample_rate==audio.MIXER_RATE && abs(int(view.info.frames)-24000)<=70)
            pcm,_:=audio.decode(view.lossless,context.temp_allocator)
            peak:f32
            for sample in pcm.samples {peak=max(peak,abs(sample))}
            testing.expect(t,abs(peak-0.5)<0.02,"The decoded samples keep their level")
        }
        asset.asset_close(&a)
    }
    report_destroy(&report)

    // A 12 kHz sine recorded at 44.1 kHz plays at its level, copied by a voice at its own pitch.
    sine:=make([]i16,44100);defer delete(sine)
    for &sample,i in sine {sample=i16(16000*math.sin(2*math.PI*12000*f64(i)/44100))}
    sine_wav:=wav_bytes(sine,1,44100);defer delete(sine_wav)
    sine_path:=fmt.tprintf("%s/air.wav",folder)
    _=os.write_entire_file(sine_path,sine_wav)
    report,error=import_sound(sine_path,{store=s})
    testing.expect_value(t,error.code,Error_Code.None)
    if len(report.assets)==1 {
        a:asset.Asset
        if view,ok:=sound_open(t,s,report.assets[0],&types,&a);ok {
            testing.expect(t,view.info.sample_rate==audio.MIXER_RATE && view.info.frames==48000)
            mixer,_:=audio.mixer_create({})
            sound,_:=audio.sound_load(mixer,view.lossless)
            audio.voice_play(mixer,sound)
            out:=make([]f32,9700*2,context.temp_allocator)
            // A little at a time, as a game: the voice decodes the lossless samples as it plays.
            for at:=0;at<9700;at+=485 {
                audio.mixer_render(mixer,out[at*2:][:485*2])
                audio.mixer_update(mixer)
            }
            audio.mixer_destroy(mixer)
            s,c:f64
            for i in 100..<9700 {
                phase:=2*math.PI*12000*f64(i)/f64(audio.MIXER_RATE)
                s+=f64(out[i*2])*math.sin(phase)
                c+=f64(out[i*2])*math.cos(phase)
            }
            // Each side of the pan carries it at cos(pi/4).
            level:=2*math.sqrt(s*s+c*c)/9600/(math.SQRT_TWO/2)/(16000.0/32768)
            testing.expectf(t,abs(20*math.log10(level))<0.5,"12 kHz plays at %v dB",20*math.log10(level))
        }
        asset.asset_close(&a)
    }
    report_destroy(&report)

    // An Ogg Vorbis at 44.1 kHz smaller than its samples coded keeps its file at its own rate: a
    // voice plays its 12 kHz at that pitch, for its length, and loops back to its LOOPSTART, in
    // the frames of the file.
    intro_path:=fmt.tprintf("%s/intro.ogg",folder)
    _=os.write_entire_file(intro_path,INTRO_OGG)
    report,error=import_sound(intro_path,{store=s})
    testing.expect_value(t,error.code,Error_Code.None)
    if len(report.assets)==1 {
        a:asset.Asset
        if view,ok:=sound_open(t,s,report.assets[0],&types,&a);ok {
            testing.expect(t,view.info.encoding==.File && view.info.sample_rate==44100 && view.info.loop_start==44100 && mem.compare(view.file,INTRO_OGG)==0)
            testing.expectf(t,report.assets[0].bytes-len(INTRO_OGG)<2048,"%d bytes for a file of %d",report.assets[0].bytes,len(INTRO_OGG))
            mixer,_:=audio.mixer_create({})
            sound,_:=audio.sound_load(mixer,view.file)
            testing.expect(t,audio.sound_set_loop_start(mixer,sound,int(view.info.loop_start)))
            desc:=audio.VOICE_DEFAULT
            desc.loop=true
            audio.voice_play(mixer,sound,desc)
            FRAMES :: 150000
            out:=make([]f32,FRAMES*2,context.temp_allocator)
            for at:=0;at<FRAMES;at+=500 {
                audio.mixer_render(mixer,out[at*2:][:500*2])
                audio.mixer_update(mixer)
            }
            audio.mixer_destroy(mixer)
            // The tone at 12 kHz in the output, while it sounds, through a voice that resamples it.
            s,c:f64
            for i in 50000..<90000 {
                phase:=2*math.PI*12000*f64(i)/f64(audio.MIXER_RATE)
                s+=f64(out[i*2])*math.sin(phase)
                c+=f64(out[i*2])*math.cos(phase)
            }
            level:=20*math.log10(2*math.sqrt(s*s+c*c)/40000/(math.SQRT_TWO/2)/0.5)
            testing.expectf(t,level>-1 && level<0.5,"12 kHz plays at %v dB",level)
            // Where it sounds: from 1 s to frame 86000 of the file, then from the loop start again.
            sounds :: proc(out:[]f32,at:int) -> bool {
                e:f64
                for i in at..<at+100 {e+=f64(out[i*2])*f64(out[i*2])}
                return e/100>0.01
            }
            edges:[dynamic]int
            edges.allocator=context.temp_allocator
            for at:=100;at+100<=FRAMES;at+=100 {
                if sounds(out,at)!=sounds(out,at-100) {append(&edges,at)}
            }
            // At 48 kHz: on at 48000, off at 93605, on at 96000 (the end of the file), off at 141605, on at 144000.
            want:=[?]int{48000,93605,96000,141605,144000}
            testing.expectf(t,len(edges)==len(want),"edges at %v",edges[:])
            for edge,i in edges[:min(len(edges),len(want))] {testing.expectf(t,abs(edge-want[i])<=600,"edge %d at %d, not %d",i,edge,want[i])}
        }
        asset.asset_close(&a)
    }
    report_destroy(&report)

    // What is not a sound that plays leaves no file.
    refuse :: proc(t:^testing.T,s:^store.Store,folder,name:string,bytes:[]u8,code:Error_Code) {
        path:=fmt.tprintf("%s/%s",folder,name)
        if bytes!=nil {_=os.write_entire_file(path,bytes)}
        report,error:=import_sound(path,{store=s})
        testing.expect_value(t,error.code,code)
        testing.expect(t,len(report.assets)==0,name)
    }
    refuse(t,s,folder,"noise.wav",{1,2,3,4,5,6,7,8,9,10,11,12,13,14},.Malformed)
    refuse(t,s,folder,"surround.ogg",THREE_OGG,.Unsupported)
    refuse(t,s,folder,"cut.wav",wav[:44],.Malformed)
    refuse(t,s,folder,"none.ogg",nil,.Not_Found)
}

// A short Ogg Vorbis keeps by default the smaller of its file and its
// samples coded: a tone its file, a click and its silence its samples. Kept,
// it plays as its samples decoded. Lossless and File say which; importing it
// again without options keeps what its package keeps.
@(test)
a_short_ogg_keeps_the_smaller_of_its_file_and_its_samples_coded :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    _,folder,s:=test_assets(t,"sound_file")
    if folder=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    ogg:=fmt.tprintf("%s/sine.ogg",folder)
    _=os.write_entire_file(ogg,SINE_OGG)
    Case :: struct {given:Maybe(Sound_Coding),keeps:bool,what:string}
    coded:=0
    for c in ([?]Case{
        {nil,true,"by default its file, the smaller"},
        {.Lossless,false,"told Lossless"},
        {nil,false,"again, by what its package keeps"},
        {.File,true,"told File"},
    }) {
        options:=Import_Options{store=s}
        if given,told:=c.given.?;told {options.sound,options.ignore_stored=given,true}
        report,error:=import_sound(ogg,options)
        testing.expectf(t,error.code==.None && len(report.assets)==1,"%s: %v",c.what,error)
        if len(report.assets)!=1 {
            report_destroy(&report)
            continue
        }
        a:asset.Asset
        if view,ok:=sound_open(t,s,report.assets[0],&types,&a);ok {
            if c.keeps {
                testing.expectf(t,view.info.encoding==.File && view.info.sample_rate==44100 && view.info.frames==22050 && mem.compare(view.file,SINE_OGG)==0,"%s: %v",c.what,view.info^)
                mixer,_:=audio.mixer_create({})
                sound,loaded:=audio.sound_load(mixer,view.file)
                testing.expect_value(t,loaded,audio.Error.None)
                audio.voice_play(mixer,sound)
                out:=make([]f32,4800*2,context.temp_allocator)
                audio.mixer_render(mixer,out)
                peak:f32
                for sample in out {peak=max(peak,abs(sample))}
                // A mono voice in the middle: constant power on each side.
                testing.expectf(t,abs(peak-0.5*math.SQRT_TWO/2)<0.02,"%s: it plays at its level: %v",c.what,peak)
                audio.mixer_destroy(mixer)
            } else {
                testing.expectf(t,view.info.encoding==.Lossless && len(view.file)==0,"%s: %v",c.what,view.info^)
                coded=len(view.lossless)
            }
        }
        asset.asset_close(&a)
        report_destroy(&report)
    }
    testing.expectf(t,coded>len(SINE_OGG),"the file kept (%d bytes) is smaller than its samples coded (%d)",len(SINE_OGG),coded)
    click,error:=sound_build(CLICK_OGG,allocator=context.temp_allocator)
    testing.expectf(t,error==.None && len(click.file)==0 && len(click.lossless)>0 && len(click.lossless)<len(CLICK_OGG),"a click and its silence code smaller than its file (%d bytes): %d",len(CLICK_OGG),len(click.lossless))
}
