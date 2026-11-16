package mirai_audio

import "core:math"
import "core:testing"
import "mirai:std/base"

@(private="file") SINE_MONO :: #load("testdata/sine_mono.ogg")     // 0.5 s of 440 Hz at 44.1 kHz, amplitude 0.5
@(private="file") SINE_STEREO :: #load("testdata/sine_stereo.ogg") // 0.25 s at 48 kHz: 440 Hz left, 880 Hz right
@(private="file") THREE_CHANNELS :: #load("testdata/three_channels.ogg")

@(private="file")
put :: proc(file:^[dynamic]u8,value:u32,bytes:int) {
    for i in 0..<bytes {append(file,u8(value>>(u32(i)*8)))}
}
// A WAV file around data. tag: 1 integer PCM, 3 IEEE float.
@(private)
test_wav :: proc(tag:u32,channels,rate,bits:int,data:[]u8,extensible:=false,junk:=false,loop_start:=-1) -> []u8 {
    file:=make([dynamic]u8,context.temp_allocator)
    append(&file,"RIFF");put(&file,0,4);append(&file,"WAVE")
    if junk {
        // A chunk of odd length before the format: readers skip it and its padding byte.
        append(&file,"LIST");put(&file,5,4);append(&file,"hello");append(&file,0)
    }
    append(&file,"fmt ");put(&file,40 if extensible else 16,4)
    put(&file,0xFFFE if extensible else tag,2);put(&file,u32(channels),2);put(&file,u32(rate),4)
    put(&file,u32(rate*channels*bits/8),4);put(&file,u32(channels*bits/8),2);put(&file,u32(bits),2)
    if extensible {
        put(&file,22,2);put(&file,u32(bits),2);put(&file,3,4)
        put(&file,tag,4);put(&file,0x0010_0000,4);put(&file,0xAA00_0080,4);put(&file,0x719B_3800,4)
    }
    append(&file,"data");put(&file,u32(len(data)),4);append(&file,..data)
    if len(data)%2==1 {append(&file,0)}
    if loop_start>=0 {
        // A sampler chunk with one forward loop from loop_start to the end.
        append(&file,"smpl");put(&file,60,4)
        for _ in 0..<7 {put(&file,0,4)}
        put(&file,1,4);put(&file,0,4)
        put(&file,0,4);put(&file,0,4);put(&file,u32(loop_start),4);put(&file,max(u32),4);put(&file,0,4);put(&file,0,4)
    }
    size:=u32(len(file)-8)
    for i in 0..<4 {file[4+i]=u8(size>>(u32(i)*8))}
    return file[:]
}
// The Ogg Vorbis file with one more comment in its comment header, the first
// packet of its second page.
@(private="file")
ogg_with_comment :: proc(file:[]u8,comment:string) -> []u8 {
    page_length :: proc(page:[]u8) -> (n:int) {
        n=27+int(page[26])
        for lacing in page[27:][:page[26]] {n+=int(lacing)}
        return
    }
    first:=page_length(file)
    second:=file[first:][:page_length(file[first:])]
    lacing:=second[27:][:second[26]]
    size,k:=0,0
    for {size+=int(lacing[k]);k+=1;if lacing[k-1]<255 {break}}
    packet:=second[27+len(lacing):][:size]
    at:=11+int(wav_u32(packet[7:])) // past the vendor
    page:=make([dynamic]u8,context.temp_allocator)
    append(&page,..second[:27])
    grown:=make([dynamic]u8,context.temp_allocator)
    append(&grown,..packet[:at]);put(&grown,wav_u32(packet[at:])+1,4);append(&grown,..packet[at+4:size-1])
    put(&grown,u32(len(comment)),4);append(&grown,comment);append(&grown,packet[size-1])
    for n:=len(grown);;n-=255 {
        append(&page,u8(min(n,255)))
        if n<255 {break}
    }
    append(&page,..lacing[k:])
    page[26]=u8(len(page)-27)
    append(&page,..grown[:]);append(&page,..second[27+len(lacing)+size:])
    for i in 22..<26 {page[i]=0}
    crc:u32
    for value in page {
        entry:=(crc>>24~u32(value))<<24
        for _ in 0..<8 {entry=entry&0x80000000!=0?entry<<1~0x04c11db7:entry<<1}
        crc=crc<<8~entry
    }
    for i in 0..<4 {page[22+i]=u8(crc>>(u32(i)*8))}
    out:=make([dynamic]u8,context.temp_allocator)
    append(&out,..file[:first]);append(&out,..page[:]);append(&out,..file[first+len(second):])
    return out[:]
}
@(private="file")
bytes_of :: proc(values:[]$T) -> []u8 {
    return (cast([^]u8)raw_data(values))[:len(values)*size_of(T)]
}

@(test)
wav_decodes_every_sample_format_it_names :: proc(t:^testing.T) {
    allocator:=context.temp_allocator
    // 16 bit, stereo: the common case.
    s16:=[]i16le{0,32767,-32768,16384,-16384,1}
    pcm,error:=wav_decode(test_wav(1,2,22050,16,bytes_of(s16)),allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,pcm.channels==2 && pcm.sample_rate==22050 && len(pcm.samples)==6)
    want16:=[]f32{0,32767.0/32768,-1,0.5,-0.5,1.0/32768}
    for value,i in want16 {test_near(t,pcm.samples[i],value,0)}

    u8_data:=[]u8{128,255,0,192,64}
    pcm,error=wav_decode(test_wav(1,1,8000,8,u8_data),allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,pcm.channels==1 && pcm.sample_rate==8000 && len(pcm.samples)==5)
    want8:=[]f32{0,127.0/128,-1,0.5,-0.5}
    for value,i in want8 {test_near(t,pcm.samples[i],value,0)}
    // Kept as it is in a mixer, its voices play the same samples.
    {
        m:=test_mixer(t)
        defer mixer_destroy(m)
        sound,load_error:=sound_load(m,test_wav(1,1,RATE,8,u8_data))
        testing.expect(t,load_error==.None && mixer_stats(m).sound_bytes==len(u8_data))
        voice_play(m,sound)
        out:=test_render(m,6)
        for value,i in want8 {test_near(t,out[i*2],value*f32(math.SQRT_TWO/2))}
        test_near(t,out[10],0,0)
    }

    s24:=[]u8{0,0,0, 0xff,0xff,0x7f, 0,0,0x80, 0,0,0x40, 0xff,0xff,0xff}
    pcm,error=wav_decode(test_wav(1,1,96000,24,s24),allocator)
    testing.expect_value(t,error,Error.None)
    want24:=[]f32{0,8388607.0/8388608,-1,0.5,-1.0/8388608}
    testing.expect_value(t,len(pcm.samples),5)
    for value,i in want24 {test_near(t,pcm.samples[i],value,0)}

    s32:=[]i32le{0,2147483647,-2147483648,1<<30,-(1<<30)}
    pcm,error=wav_decode(test_wav(1,1,48000,32,bytes_of(s32)),allocator)
    testing.expect_value(t,error,Error.None)
    want32:=[]f32{0,1,-1,0.5,-0.5}
    for value,i in want32 {test_near(t,pcm.samples[i],value,0)}

    f32_data:=[]f32le{0,1,-1,0.25,-1.5,3.25e-3}
    pcm,error=wav_decode(test_wav(3,2,44100,32,bytes_of(f32_data)),allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,pcm.channels,2)
    for value,i in f32_data {test_near(t,pcm.samples[i],f32(value),0)}

    f64_data:=[]f64le{0,1,-1,0.125}
    pcm,error=wav_decode(test_wav(3,1,44100,64,bytes_of(f64_data)),allocator)
    testing.expect_value(t,error,Error.None)
    for value,i in f64_data {test_near(t,pcm.samples[i],f32(value),0)}

    // What is not a number, or does not fit an f32, is silence: it would stay in every filter it reached.
    hostile:=[]f64le{f64le(transmute(f64)u64(0x7FF8_0000_0000_0001)),f64le(transmute(f64)u64(0x7FF0_0000_0000_0000)),1e300,-0.5}
    pcm,error=wav_decode(test_wav(3,1,44100,64,bytes_of(hostile)),allocator)
    testing.expect_value(t,error,Error.None)
    for value,i in ([?]f32{0,0,0,-0.5}) {test_near(t,pcm.samples[i],value,0)}
    nan32:=[]u32le{0x7FC0_0000,0xFF80_0000,0x3F00_0000}
    pcm,error=wav_decode(test_wav(3,1,44100,32,bytes_of(nan32)),allocator)
    testing.expect_value(t,error,Error.None)
    for value,i in ([?]f32{0,0,0.5}) {test_near(t,pcm.samples[i],value,0)}

    // The extensible header, with a chunk of odd length before it.
    pcm,error=wav_decode(test_wav(1,2,22050,16,bytes_of(s16),extensible=true,junk=true),allocator)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,pcm.channels==2 && pcm.sample_rate==22050)
    for value,i in want16 {test_near(t,pcm.samples[i],value,0)}
    pcm,error=wav_decode(test_wav(3,1,48000,32,bytes_of(f32_data),extensible=true),allocator)
    testing.expect_value(t,error,Error.None)
    test_near(t,pcm.samples[3],0.25,0)

    // The first loop of a sampler chunk says where a loop goes back to; one past the end is none.
    for c in ([?][2]int{{2,2},{len(f32_data),0},{0,0}}) {
        pcm,error=wav_decode(test_wav(3,1,48000,32,bytes_of(f32_data),loop_start=c[0]),allocator)
        testing.expect(t,error==.None && pcm.loop_start==c[1] && len(pcm.samples)==len(f32_data))
    }
}

@(test)
wav_that_is_damaged_or_unsupported_is_refused :: proc(t:^testing.T) {
    allocator:=context.temp_allocator
    s16:=[]i16le{1,2,3,4,5,6,7,8}
    good:=test_wav(1,2,22050,16,bytes_of(s16))
    _,error:=wav_decode(good[:8],allocator)
    testing.expect_value(t,error,Error.Invalid_Data)
    _,error=wav_decode(nil,allocator)
    testing.expect_value(t,error,Error.Invalid_Data)
    // No data chunk, and no format chunk.
    _,error=wav_decode(good[:36],allocator)
    testing.expect_value(t,error,Error.Invalid_Data)
    headless:=make([]u8,len(good),allocator)
    copy(headless,good)
    copy(headless[12:],"junk")
    _,error=wav_decode(headless,allocator)
    testing.expect_value(t,error,Error.Invalid_Data)
    // ADPCM, 12 bits and six channels are not played.
    _,error=wav_decode(test_wav(2,1,22050,4,{1,2,3,4}),allocator)
    testing.expect_value(t,error,Error.Unsupported_Format)
    _,error=wav_decode(test_wav(1,1,22050,12,{1,2,3,4}),allocator)
    testing.expect_value(t,error,Error.Unsupported_Format)
    _,error=wav_decode(test_wav(1,6,48000,16,bytes_of(s16)),allocator)
    testing.expect_value(t,error,Error.Unsupported_Format)
    _,error=wav_decode(test_wav(1,0,48000,16,bytes_of(s16)),allocator)
    testing.expect_value(t,error,Error.Invalid_Data)
    // A file cut in the middle of its samples plays what is whole.
    pcm,cut_error:=wav_decode(good[:len(good)-5],allocator)
    testing.expect_value(t,cut_error,Error.None)
    testing.expect_value(t,len(pcm.samples),4)
    test_near(t,pcm.samples[3],4.0/32768,0)
    // Neither format.
    _,error=decode({'M','T','h','d',0,0,0,6,0,0,0,0},allocator)
    testing.expect_value(t,error,Error.Invalid_Data)
}

@(test)
ogg_vorbis_decodes_to_the_sound_that_was_encoded :: proc(t:^testing.T) {
    pcm,error:=vorbis_decode(SINE_MONO,context.allocator)
    testing.expect_value(t,error,Error.None)
    defer pcm_destroy(&pcm)
    testing.expect(t,pcm.channels==1 && pcm.sample_rate==44100)
    testing.expect_value(t,len(pcm.samples),22050)
    // A lossy codec: the sine comes back close, not equal.
    worst,energy:=f32(0),f64(0)
    for sample,i in pcm.samples {
        want:=0.5*f32(math.sin(2*math.PI*440*f64(i)/44100))
        worst=max(worst,abs(sample-want))
        energy+=f64(sample)*f64(sample)
    }
    testing.expectf(t,worst<0.02,"the decoded sine is off by %v",worst)
    test_near(t,f32(math.sqrt(energy/22050)),0.5*math.SQRT_TWO/2,5e-3)

    stereo,stereo_error:=decode(SINE_STEREO,context.allocator)
    testing.expect_value(t,stereo_error,Error.None)
    defer pcm_destroy(&stereo)
    testing.expect(t,stereo.channels==2 && stereo.sample_rate==48000)
    testing.expect_value(t,len(stereo.samples),12000*2)
    worst=0
    for i in 0..<12000 {
        left:=0.5*f32(math.sin(2*math.PI*440*f64(i)/48000))
        right:=0.5*f32(math.sin(2*math.PI*880*f64(i)/48000))
        worst=max(worst,abs(stereo.samples[i*2]-left),abs(stereo.samples[i*2+1]-right))
    }
    testing.expectf(t,worst<0.05,"the decoded stereo sines are off by %v",worst)

    // The comment LOOPSTART, in any case, says where a loop goes back to; one outside the sound is none.
    for c in ([?]struct{comment:string,loop_start:int}{{"loopstart=1000",1000},{"LOOPSTART=22050",0},{"LOOPSTART=x",0},{"TITLE=hum",0}}) {
        pcm,error:=vorbis_decode(ogg_with_comment(SINE_MONO,c.comment),context.temp_allocator)
        testing.expectf(t,error==.None && pcm.loop_start==c.loop_start && len(pcm.samples)==22050,"%v: %v %v",c.comment,error,pcm.loop_start)
    }

    // Not Vorbis, and Vorbis cut short of its headers.
    garbage:=[]u8{'O','g','g','S',0,2,0,0,0,0,0,0,0,0,1,2,3,4,0,0,0,0,9,9,9,9,1,30,1,2,3}
    _,error=vorbis_decode(garbage,context.allocator)
    testing.expect_value(t,error,Error.Invalid_Data)
    whole:=SINE_MONO
    _,error=vorbis_decode(whole[:300],context.allocator)
    testing.expect_value(t,error,Error.Invalid_Data)
    _,error=vorbis_decode(nil,context.allocator)
    testing.expect_value(t,error,Error.Invalid_Data)
    // More than two channels are not played, in memory or streamed.
    _,error=vorbis_decode(THREE_CHANNELS,context.allocator)
    testing.expect_value(t,error,Error.Unsupported_Format)
    m:=test_mixer(t)
    defer mixer_destroy(m)
    _,error=sound_load(m,THREE_CHANNELS)
    testing.expect_value(t,error,Error.Unsupported_Format)
    _,error=sound_stream(m,THREE_CHANNELS)
    testing.expect_value(t,error,Error.Unsupported_Format)
    testing.expect_value(t,mixer_stats(m).sounds,0)
}

@(test)
sound_is_loaded_from_a_wav_or_an_ogg_file :: proc(t:^testing.T) {
    m:=test_mixer(t,{sound_capacity=3})
    defer mixer_destroy(m)
    ramp:=make([]i16le,200,context.temp_allocator)
    for &value,i in ramp {value=i16le((i/2+1)*100*(1 if i%2==0 else -1))}
    wav,error:=sound_load(m,test_wav(1,2,RATE,16,bytes_of(ramp)))
    testing.expect_value(t,error,Error.None)
    testing.expect(t,sound_frames(m,wav)==100 && sound_channels(m,wav)==2 && sound_sample_rate(m,wav)==RATE)
    // A WAV of 16 bits keeps its samples as they are, which every voice decodes.
    testing.expect_value(t,mixer_stats(m).sound_bytes,len(ramp)*2)
    voice_play(m,wav)
    out:=test_render(m,120)
    for i in 0..<120 {
        want:=f32(i+1)*100/32768 if i<100 else 0
        if !test_near(t,out[i*2],want,0) || !test_near(t,out[i*2+1],-want,0) {break}
    }
    ogg,ogg_error:=sound_load(m,SINE_MONO)
    testing.expect_value(t,ogg_error,Error.None)
    // An Ogg Vorbis is decoded whole.
    testing.expect_value(t,mixer_stats(m).sound_bytes,len(ramp)*2+22050*4)
    testing.expect(t,sound_frames(m,ogg)==22050 && sound_channels(m,ogg)==1 && sound_sample_rate(m,ogg)==44100)
    test_near(t,sound_seconds(m,ogg),0.5)
    // Played by a 48 kHz mixer it is still 440 Hz.
    voice_play(m,ogg)
    out=test_render(m,4800)
    worst:=f32(0)
    for i in 0..<4800 {
        want:=0.5*f32(math.sin(2*math.PI*440*f64(i)/RATE))*f32(math.SQRT_TWO/2)
        worst=max(worst,abs(out[i*2]-want))
    }
    testing.expectf(t,worst<0.02,"the played sine is off by %v",worst)
    // What cannot be decoded takes no slot; a full table refuses.
    _,error=sound_load(m,{1,2,3,4})
    testing.expect_value(t,error,Error.Invalid_Data)
    testing.expect_value(t,mixer_stats(m).sounds,2)
    _,error=sound_load(m,SINE_STEREO)
    testing.expect_value(t,error,Error.None)
    _,error=sound_load(m,SINE_STEREO)
    testing.expect_value(t,error,Error.Capacity_Exhausted)
}

// stb_vorbis reads what a page says without checking it: a damaged page used
// to crash every caller but the importer, which was the only one to check.
@(test)
a_damaged_ogg_stream_is_cut_at_its_last_whole_page_for_every_decoder :: proc(t:^testing.T) {
    testing.expect_value(t,ogg_whole_pages(SINE_MONO),len(SINE_MONO))
    testing.expect_value(t,ogg_whole_pages(nil),0)
    source:=SINE_MONO
    testing.expect_value(t,ogg_whole_pages(source[:26]),0)
    r:=base.rng_make(0x6f6767)
    file:=make([]u8,len(SINE_MONO))
    defer delete(file)
    m:=test_mixer(t)
    defer mixer_destroy(m)
    refused,shorter,intact:=0,0,0
    for round in 0..<600 {
        copy(file,SINE_MONO)
        cut:=len(file)
        switch round%4 {
        case 0: cut=int(base.rng_u32(&r))%len(file)
        case 1: file[int(base.rng_u32(&r))%len(file)]~=u8(1+base.rng_u32(&r)%255)
        case 2:
            // The header of a page: its flags, its position, its segment table.
            at:=0
            for skip:=int(base.rng_u32(&r))%8;skip>0;skip-=1 {
                next:=ogg_whole_pages(file[at:][:min(len(file)-at,27+int(file[at+26])+255*int(file[at+26]))])
                if next==0 || at+next>=len(file) {break}
                at+=next
            }
            file[at+5+int(base.rng_u32(&r))%22]=u8(base.rng_u32(&r))
        case 3:
            start:=int(base.rng_u32(&r))%len(file)
            for &value in file[start:][:min(64,len(file)-start)] {value=u8(base.rng_u32(&r))}
        }
        damaged:=file[:cut]
        whole:=ogg_whole_pages(damaged)
        testing.expect(t,whole<=len(damaged))
        pcm,error:=decode(damaged,context.allocator)
        if error==.None {
            testing.expect(t,pcm.channels==1 && pcm.sample_rate==44100 && len(pcm.samples)<=22050)
            if len(pcm.samples)<22050 {shorter+=1} else {intact+=1}
            pcm_destroy(&pcm)
        } else {
            testing.expect_value(t,error,Error.Invalid_Data)
            refused+=1
        }
        // The same bytes as a stream, read to their end.
        if d,open_error:=decoder_open(damaged,context.allocator);open_error==.None {
            block:[4096]f32
            total:=0
            for {
                got:=decoder_read(&d,block[:])
                total+=got
                if got<len(block) {break}
            }
            testing.expect(t,total<=22050)
            decoder_close(&d,context.allocator)
        }
        if sound,stream_error:=sound_stream(m,damaged);stream_error==.None {sound_destroy(m,sound)}
        mixer_update(m)
    }
    testing.expect(t,refused>0 && shorter>0)
    testing.expectf(t,intact<300,"%d damaged files decoded whole",intact)
}
