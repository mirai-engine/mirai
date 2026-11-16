package mirai_audio

import "base:runtime"

// WAV (RIFF) decoding: integer PCM of 8, 16, 24 and 32 bits and IEEE float
// of 32 and 64 bits, mono or stereo, also inside WAVE_FORMAT_EXTENSIBLE.

@(private)
Wav_Format :: enum u8 {U8,S16,S24,S32,F32,F64}
@(private)
WAV_SAMPLE_BYTES :: [Wav_Format]int{.U8=1,.S16=2,.S24=3,.S32=4,.F32=4,.F64=8}
@(private)
Wav :: struct {
    data:[]u8, // the samples as stored, inside the file
    format:Wav_Format,
    channels,sample_rate:int,
    frames:int,
    loop_start:int, // of the first loop its smpl chunk names; 0 without one
}

@(private)
wav_u16 :: proc "contextless" (b:[]u8) -> u32 {return u32(b[0])|u32(b[1])<<8}
@(private)
wav_u32 :: proc "contextless" (b:[]u8) -> u32 {return u32(b[0])|u32(b[1])<<8|u32(b[2])<<16|u32(b[3])<<24}

@(private)
wav_parse :: proc(file:[]u8) -> (wav:Wav,error:Error) {
    if len(file)<12 || string(file[:4])!="RIFF" || string(file[8:12])!="WAVE" {return {},.Invalid_Data}
    has_format,has_data:=false,false
    for at:=12;at+8<=len(file); {
        id:=string(file[at:at+4])
        size:=int(wav_u32(file[at+4:]))
        body:=file[at+8:]
        // A file cut short, or written as a stream, has a size that goes past its end.
        if size>len(body) {size=len(body)}
        switch id {
        case "fmt ":
            if size<16 {return {},.Invalid_Data}
            tag:=wav_u16(body)
            wav.channels=int(wav_u16(body[2:]))
            wav.sample_rate=int(wav_u32(body[4:]))
            bits:=wav_u16(body[14:])
            if tag==0xFFFE {
                // WAVE_FORMAT_EXTENSIBLE: the format is the first field of the sub format GUID.
                if size<40 {return {},.Invalid_Data}
                tag=wav_u16(body[24:])
            }
            switch {
            case tag==1 && bits==8:wav.format=.U8
            case tag==1 && bits==16:wav.format=.S16
            case tag==1 && bits==24:wav.format=.S24
            case tag==1 && bits==32:wav.format=.S32
            case tag==3 && bits==32:wav.format=.F32
            case tag==3 && bits==64:wav.format=.F64
            case:return {},.Unsupported_Format
            }
            if wav.channels<1 || wav.sample_rate<=0 {return {},.Invalid_Data}
            if wav.channels>2 {return {},.Unsupported_Format}
            has_format=true
        case "data":
            if !has_data {wav.data=body[:size];has_data=true}
        case "smpl":
            // Nine fields, the count of loops among them, and the first loop:
            // its cue, its type and its start, as Godot reads it.
            if size>=60 && wav_u32(body[28:])>0 {wav.loop_start=int(wav_u32(body[44:]))}
        }
        at+=8+size+(size&1)
    }
    if !has_format || !has_data {return {},.Invalid_Data}
    sizes:=WAV_SAMPLE_BYTES
    wav.frames=len(wav.data)/(sizes[wav.format]*wav.channels)
    if wav.loop_start>=wav.frames {wav.loop_start=0}
    return wav,.None
}

// Converts frames [first,first+len(out)/channels) to f32 in out and returns how many there were.
@(private)
wav_convert :: proc "contextless" (wav:^Wav,first:int,out:[]f32) -> int {
    sizes:=WAV_SAMPLE_BYTES
    size:=sizes[wav.format]
    count:=min(len(out)/wav.channels,wav.frames-first)
    if count<=0 {return 0}
    source:=wav.data[first*wav.channels*size:]
    #no_bounds_check for i in 0..<count*wav.channels {
        b:=source[i*size:]
        switch wav.format {
        case .U8:out[i]=(f32(b[0])-128)*(1.0/128)
        case .S16:out[i]=f32(i16(u16(b[0])|u16(b[1])<<8))*(1.0/32768)
        case .S24:out[i]=f32(i32(u32(b[0])<<8|u32(b[1])<<16|u32(b[2])<<24)>>8)*(1.0/8388608)
        case .S32:out[i]=f32(f64(i32(u32(b[0])|u32(b[1])<<8|u32(b[2])<<16|u32(b[3])<<24))*(1.0/2147483648))
        case .F32:out[i]=transmute(f32)(u32(b[0])|u32(b[1])<<8|u32(b[2])<<16|u32(b[3])<<24)
        case .F64:
            bits:=u64(0)
            for k in 0..<8 {bits|=u64(b[k])<<(u32(k)*8)}
            out[i]=f32(transmute(f64)bits)
        }
        // A sample that is not a number, or beyond what f32 holds, would stay in every filter it reaches.
        if !(abs(out[i])<=max(f32)) {out[i]=0}
    }
    return count
}

// Frames [first,first+len(out)/channels) of a WAV of 8 or 16 bits, to 16
// bits, and how many there were.
@(private)
wav_convert_i16 :: proc "contextless" (wav:^Wav,first:int,out:[]i16) -> int {
    count:=min(len(out)/wav.channels,wav.frames-first)
    if count<=0 {return 0}
    n:=count*wav.channels
    if wav.format==.S16 {
        source:=wav.data[first*wav.channels*2:][:n*2]
        for i in 0..<n {out[i]=i16(u16(source[i*2])|u16(source[i*2+1])<<8)}
    } else {
        source:=wav.data[first*wav.channels:][:n]
        for i in 0..<n {out[i]=(i16(source[i])-128)<<8}
    }
    return count
}

wav_decode :: proc(file:[]u8,allocator:runtime.Allocator) -> (pcm:Pcm,error:Error) {
    wav:=wav_parse(file) or_return
    samples,failed:=make([]f32,wav.frames*wav.channels,allocator)
    if failed!=nil {return {},.Out_Of_Memory}
    wav_convert(&wav,0,samples)
    return {samples,wav.channels,wav.sample_rate,wav.loop_start},.None
}
