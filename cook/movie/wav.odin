package movie

import "core:os"

// A WAV of 32-bit float samples written as they come: the header says how
// long it is once wav_close writes it.
Wav_Writer :: struct {
    file:^os.File,
    rate,channels:int,
    frames:u64,
    failed:bool,
}

@(private)
WAV_HEADER :: 12+26+12+8 // RIFF, fmt of a float format, fact and the head of data

wav_open :: proc(w:^Wav_Writer,path:string,rate,channels:int) -> Error {
    w^={rate=rate,channels=channels}
    if rate<=0 || channels<1 {return .Invalid}
    file,error:=os.open(path,{.Write,.Create,.Trunc},os.Permissions_Read_All+{.Write_User})
    if error!=nil {return .Write_Failed}
    w.file=file
    header:[WAV_HEADER]u8
    if _,write_error:=os.write(w.file,header[:]);write_error!=nil {
        wav_close(w)
        return .Write_Failed
    }
    return .None
}

// Appends interleaved frames at the channels of the writer.
wav_append :: proc(w:^Wav_Writer,samples:[]f32) -> Error {
    if w.file==nil || w.failed || len(samples)%w.channels!=0 {return .Invalid}
    bytes:=([^]u8)(raw_data(samples))[:len(samples)*4]
    if count,error:=os.write(w.file,bytes);error!=nil || count!=len(bytes) {
        w.failed=true
        return .Write_Failed
    }
    w.frames+=u64(len(samples)/w.channels)
    return .None
}

// Writes the header and closes the file.
wav_close :: proc(w:^Wav_Writer) -> Error {
    if w.file==nil {return .Invalid}
    defer {os.close(w.file);w.file=nil}
    if w.failed {return .Write_Failed}
    data:=w.frames*u64(w.channels)*4
    header:=make([dynamic]u8,0,WAV_HEADER)
    defer delete(header)
    append(&header,'R','I','F','F');put_u32_le(&header,u32(WAV_HEADER-8+data))
    append(&header,'W','A','V','E')
    append(&header,'f','m','t',' ');put_u32_le(&header,18)
    append(&header,3,0) // IEEE float
    append(&header,u8(w.channels),0)
    put_u32_le(&header,u32(w.rate))
    put_u32_le(&header,u32(w.rate*w.channels*4))
    append(&header,u8(w.channels*4),0,32,0,0,0)
    append(&header,'f','a','c','t');put_u32_le(&header,4);put_u32_le(&header,u32(w.frames))
    append(&header,'d','a','t','a');put_u32_le(&header,u32(data))
    if _,error:=os.write_at(w.file,header[:],0);error!=nil {return .Write_Failed}
    return .None
}
