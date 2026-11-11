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

@(private="file") SINE_OGG :: #load("../../audio/testdata/sine_mono.ogg")           // 0.5 s of 440 Hz at 44.1 kHz, amplitude 0.5
@(private="file") THREE_OGG :: #load("../../audio/testdata/three_channels.ogg")
@(private="file") TONE_OGG :: #load("../../audio/testdata/tone_long.ogg")           // 2 s of 330 Hz at 32 kHz, mono

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
sound_open :: proc(t:^testing.T,path:string,types:^asset.Types,a:^asset.Asset) -> (view:asset.Sound_View,ok:bool) {
    if !testing.expect_value(t,asset.asset_load(a,path),asset.Error.None) {return}
    error:asset.Error
    view,error=asset.sound_view(a,types)
    return view,testing.expect_value(t,error,asset.Error.None)
}

@(test)
a_wav_and_an_ogg_become_sounds_decoded_or_streamed_by_their_length :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    root,folder:=test_assets(t,"sound")
    if folder=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)

    samples:=make([]i16,2*4410);defer delete(samples)
    for &sample,i in samples {sample=i16(12000*math.sin(f32(i/2)*2*math.PI*440/48000))*(i%2==0?1:-1)}
    samples[0],samples[1]=32767,-32768
    wav:=wav_bytes(samples,2,48000);defer delete(wav)
    path:=fmt.tprintf("%s/Step Left.wav",folder)
    _=os.write_entire_file(path,wav)

    report,error:=import_sound(path,options={root=root})
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,len(report.assets),1)
    if len(report.assets)==1 {
        written:=report.assets[0]
        testing.expect(t,written.kind==asset.KIND_SOUND && written.id!={} && strings.has_suffix(written.path,".sound") && strings.contains(written.path,"/.mirai/imported/") && written.bytes<len(samples)*2)
        a:asset.Asset
        if view,ok:=sound_open(t,written.path,&types,&a);ok {
            testing.expect(t,view.info^==asset.Sound_Info{2,48000,4410,0,.Lossless,{}})
            lossless_same(t,view,samples)
            testing.expect(t,view.source!=nil && serial.text_field(view.source.importer[:])==IMPORTER_NAME && view.source.source_size==u64(len(wav)))
        }
        asset.asset_close(&a)
    }
    // Imported again it is the same asset; told to stream, it streams the same coded samples.
    again,again_error:=import_sound(path,{storage=.Stream},{root=root})
    testing.expect_value(t,again_error.code,Error_Code.None)
    if len(again.assets)==1 && len(report.assets)==1 {
        testing.expect(t,again.assets[0].id==report.assets[0].id)
        a:asset.Asset
        if view,ok:=sound_open(t,again.assets[0].path,&types,&a);ok {
            testing.expect(t,view.info^==asset.Sound_Info{2,48000,4410,0,.Lossless,{.Stream}})
            lossless_same(t,view,samples)
        }
        asset.asset_close(&a)
    }
    report_destroy(&report);report_destroy(&again)

    // A 24 bit WAV at the rate of the mixer that 16 bits would round streams its file as it is.
    deep:=wav_bytes(samples,2,48000,low=0x40);defer delete(deep)
    deep_path:=fmt.tprintf("%s/deep.wav",folder)
    _=os.write_entire_file(deep_path,deep)
    report,error=import_sound(deep_path,{storage=.Stream},{root=root})
    testing.expect_value(t,error.code,Error_Code.None)
    if len(report.assets)==1 {
        a:asset.Asset
        if view,ok:=sound_open(t,report.assets[0].path,&types,&a);ok {
            testing.expect(t,view.info^==asset.Sound_Info{2,48000,4410,0,.File,{.Stream}} && mem.compare(view.file,deep)==0)
        }
        asset.asset_close(&a)
    }
    report_destroy(&report)

    // Half a second of Vorbis at 44.1 kHz, brought to the rate of the mixer: decoded when short,
    // streamed from a quarter of a second on, coded again since its file is at another rate.
    ogg:=fmt.tprintf("%s/sine.ogg",folder)
    _=os.write_entire_file(ogg,SINE_OGG)
    report,error=import_sound(ogg,options={root=root})
    testing.expect_value(t,error.code,Error_Code.None)
    if len(report.assets)==1 {
        a:asset.Asset
        if view,ok:=sound_open(t,report.assets[0].path,&types,&a);ok {
            testing.expect(t,view.info.encoding==.Lossless && view.info.channels==1 && view.info.sample_rate==audio.MIXER_RATE && abs(int(view.info.frames)-24000)<=70)
            pcm,_:=audio.decode(view.lossless,context.temp_allocator)
            peak:f32
            for sample in pcm.samples {peak=max(peak,abs(sample))}
            testing.expect(t,abs(peak-0.5)<0.02,"The decoded samples keep their level")
        }
        asset.asset_close(&a)
    }
    report_destroy(&report)
    report,error=import_sound(ogg,{stream_seconds=0.25},{root=root})
    testing.expect_value(t,error.code,Error_Code.None)
    if len(report.assets)==1 {
        a:asset.Asset
        if view,ok:=sound_open(t,report.assets[0].path,&types,&a);ok {
            testing.expect(t,view.info.encoding==.Lossless && .Stream in view.info.flags && view.info.sample_rate==audio.MIXER_RATE)
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
    report,error=import_sound(sine_path,options={root=root})
    testing.expect_value(t,error.code,Error_Code.None)
    if len(report.assets)==1 {
        a:asset.Asset
        if view,ok:=sound_open(t,report.assets[0].path,&types,&a);ok {
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

    // What is not a sound that plays leaves no file.
    refuse :: proc(t:^testing.T,root,folder,name:string,bytes:[]u8,code:Error_Code) {
        path:=fmt.tprintf("%s/%s",folder,name)
        if bytes!=nil {_=os.write_entire_file(path,bytes)}
        report,error:=import_sound(path,options={root=root})
        testing.expect_value(t,error.code,code)
        testing.expect(t,len(report.assets)==0 && !os.exists(fmt.tprintf("%s.import",path)),name)
    }
    refuse(t,root,folder,"noise.wav",{1,2,3,4,5,6,7,8,9,10,11,12,13,14},.Malformed)
    refuse(t,root,folder,"surround.ogg",THREE_OGG,.Unsupported)
    refuse(t,root,folder,"cut.wav",wav[:44],.Malformed)
    refuse(t,root,folder,"none.ogg",nil,.Not_Found)
}

// What loading a sound costs by how it is stored, and what it holds in memory.
@(test)
bench_loading_a_lossless_sound_against_decoding_its_file :: proc(t:^testing.T) {
    if !BENCH {return}
    ROUNDS :: 20
    best :: proc(body:proc(data:rawptr),data:rawptr) -> f64 {
        low:=time.Duration(max(i64))
        for _ in 0..<ROUNDS {
            start:=time.tick_now()
            body(data)
            low=min(low,time.tick_since(start))
        }
        return time.duration_microseconds(low)
    }
    State :: struct {mixer:^audio.Mixer,samples:[]i16,scratch:[]f32,file,lossless:[]u8,channels,rate:int}
    pcm,_:=audio.decode(TONE_OGG,context.allocator)
    defer audio.pcm_destroy(&pcm)
    seconds:=f64(len(pcm.samples))/f64(pcm.sample_rate)
    mixer,_:=audio.mixer_create({})
    defer audio.mixer_destroy(mixer)
    s:=State{mixer=mixer,samples=make([]i16,len(pcm.samples)),scratch=make([]f32,len(pcm.samples)),file=TONE_OGG,channels=pcm.channels,rate=pcm.sample_rate}
    defer {delete(s.samples);delete(s.scratch)}
    for sample,i in pcm.samples {s.samples[i]=i16(sample*32767)}
    s.lossless,_=audio.lossless_encode(s.samples,s.channels,s.rate)
    defer delete(s.lossless)
    decoded:=best(proc(data:rawptr) {
        s:=cast(^State)data
        sound,_:=audio.sound_load(s.mixer,s.lossless)
        audio.sound_destroy(s.mixer,sound)
        audio.mixer_render(s.mixer,s.scratch[:512])
        audio.mixer_update(s.mixer)
    },&s)
    vorbis:=best(proc(data:rawptr) {
        s:=cast(^State)data
        sound,_:=audio.sound_load(s.mixer,s.file)
        audio.sound_destroy(s.mixer,sound)
        audio.mixer_render(s.mixer,s.scratch[:512])
        audio.mixer_update(s.mixer)
    },&s)
    stream:=best(proc(data:rawptr) {
        s:=cast(^State)data
        sound,_:=audio.sound_stream(s.mixer,s.file)
        audio.sound_destroy(s.mixer,sound)
        audio.mixer_render(s.mixer,s.scratch[:512])
        audio.mixer_update(s.mixer)
    },&s)
    fmt.printfln("sound of %.2f s, %d Hz, %d channel(s): ogg %d bytes, pcm16 %d bytes, lossless %d bytes, f32 in the mixer %d bytes",seconds,pcm.sample_rate,pcm.channels,len(TONE_OGG),len(s.samples)*2,len(s.lossless),len(pcm.samples)*4)
    fmt.printfln("load by decoding the lossless samples whole:      %.1f us, %.1f us per second of sound",decoded,decoded/seconds)
    fmt.printfln("load by decoding the Vorbis file whole:           %.1f us, %.1f us per second of sound",vorbis,vorbis/seconds)
    fmt.printfln("open as a stream (decoder only):                  %.1f us",stream)
}
