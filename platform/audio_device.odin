package platform

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl3"
import audio "mirai:audio"

// The audio output of the system. It plays one Mixer: SDL's audio thread
// asks for frames and mixer_render fills them, at the sample rate and
// channel count of the mixer; SDL converts to what the hardware wants.

Audio_Device_Desc :: struct {
    driver:string,     // SDL audio driver; "" lets SDL choose, "dummy" plays to nowhere in real time
    buffer_frames:int, // frames the device asks for at a time: lower is less latency and more risk of gaps; the system decides when zero
    device:string,     // the output by its name in audio_device_names; "" or one the system does not list: its default
}
Audio_Error :: enum u8 {None,Already_Open,Unavailable,Device_Failed,Out_Of_Memory}
Audio_Device_Stats :: struct {
    callbacks:u64, // times the device asked for audio
    frames:u64,    // frames it was given
}

// Frames rendered per call of the mixer from the device callback.
@(private) AUDIO_DEVICE_CHUNK :: 1024

@(private)
Audio_Device :: struct {
    stream:^sdl.AudioStream,
    mixer:^audio.Mixer,
    channels:int,
    scratch:[]f32,
    subsystem,driver_chosen,frames_chosen:bool,
    callbacks,frames:u64, // atomic: written by the audio thread
}

// Starts playing the mixer on the output desc names. The mixer must outlive
// the device: close the device, or destroy the Platform, before the mixer.
audio_device_open :: proc(p:^Platform,mixer:^audio.Mixer,desc:Audio_Device_Desc={}) -> Audio_Error {
    device:=&p.audio
    if device.stream!=nil {return .Already_Open}
    if mixer==nil {return .Device_Failed}
    if desc.driver!="" {
        _=sdl.SetHint(sdl.HINT_AUDIO_DRIVER,strings.clone_to_cstring(desc.driver,context.temp_allocator))
        device.driver_chosen=true
    }
    if desc.buffer_frames>0 {
        _=sdl.SetHint(sdl.HINT_AUDIO_DEVICE_SAMPLE_FRAMES,fmt.ctprintf("%d",desc.buffer_frames))
        device.frames_chosen=true
    }
    if !sdl.InitSubSystem({.AUDIO}) {
        audio_device_release(p)
        return .Unavailable
    }
    device.subsystem=true
    device.mixer=mixer
    device.channels=mixer.channels
    scratch,allocation_error:=make([]f32,AUDIO_DEVICE_CHUNK*device.channels,p.allocator)
    if allocation_error!=nil {
        audio_device_release(p)
        return .Out_Of_Memory
    }
    device.scratch=scratch
    if error,_:=audio_stream_open(p,desc.device);error!=.None {
        audio_device_release(p)
        return error
    }
    return .None
}

// Plays the mixer on another output, by its name in audio_device_names; ""
// is the default of the system, and so is a name it does not list, when
// found is false. The mixer keeps its state: only the output changes. An
// error leaves the device closed.
audio_device_switch :: proc(p:^Platform,name:string) -> (error:Audio_Error,found:bool) {
    device:=&p.audio
    if device.stream==nil {return .Unavailable,false}
    // When this returns the audio thread no longer touches the mixer.
    sdl.DestroyAudioStream(device.stream)
    device.stream=nil
    if error,found=audio_stream_open(p,name);error!=.None {audio_device_release(p)}
    return
}

// The names of the outputs of the system, as audio_device_switch takes them;
// none while the device is closed.
audio_device_names :: proc(p:^Platform,allocator:=context.allocator) -> []string {
    if !p.audio.subsystem {return nil}
    count:c.int
    devices:=sdl.GetAudioPlaybackDevices(&count)
    if devices==nil {return nil}
    defer sdl.free(devices)
    names,error:=make([]string,int(count),allocator)
    if error!=nil {return nil}
    for &name,i in names {
        if name,error=strings.clone_from_cstring(sdl.GetAudioDeviceName(devices[i]),allocator);error==nil {continue}
        for taken in names[:i] {delete(taken,allocator)}
        delete(names,allocator)
        return nil
    }
    return names
}

// The stream of the mixer on the output of that name, playing.
@(private)
audio_stream_open :: proc(p:^Platform,name:string) -> (error:Audio_Error,found:bool) {
    device:=&p.audio
    id:=sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK
    found=name==""
    if !found {
        count:c.int
        if devices:=sdl.GetAudioPlaybackDevices(&count);devices!=nil {
            for i in 0..<int(count) {
                if string(sdl.GetAudioDeviceName(devices[i]))==name {id,found=devices[i],true;break}
            }
            sdl.free(devices)
        }
    }
    spec:=sdl.AudioSpec{format=.F32,channels=c.int(device.channels),freq=c.int(device.mixer.sample_rate)}
    device.stream=sdl.OpenAudioDeviceStream(id,&spec,audio_device_callback,device)
    if device.stream==nil {return .Device_Failed,found}
    // A device opened with a stream starts paused.
    if !sdl.ResumeAudioStreamDevice(device.stream) {return .Device_Failed,found}
    return .None,found
}

// Stops the output. When this returns the audio thread no longer touches the mixer.
audio_device_close :: proc(p:^Platform) {
    audio_device_release(p)
}
@(private)
audio_device_release :: proc(p:^Platform) {
    device:=&p.audio
    if device.stream!=nil {sdl.DestroyAudioStream(device.stream)}
    if device.subsystem {sdl.QuitSubSystem({.AUDIO})}
    if device.driver_chosen {_=sdl.ResetHint(sdl.HINT_AUDIO_DRIVER)}
    if device.frames_chosen {_=sdl.ResetHint(sdl.HINT_AUDIO_DEVICE_SAMPLE_FRAMES)}
    delete(device.scratch,p.allocator)
    device^={}
}

audio_device_is_open :: proc(p:^Platform) -> bool {return p.audio.stream!=nil}
// A paused device asks for nothing: the mixer and its clock stand still.
audio_device_set_paused :: proc(p:^Platform,paused:bool) -> bool {
    stream:=p.audio.stream
    if stream==nil {return false}
    return sdl.PauseAudioStreamDevice(stream) if paused else sdl.ResumeAudioStreamDevice(stream)
}
audio_device_paused :: proc(p:^Platform) -> bool {
    return p.audio.stream!=nil && sdl.AudioStreamDevicePaused(p.audio.stream)
}
audio_device_stats :: proc(p:^Platform) -> Audio_Device_Stats {
    return {sync.atomic_load_explicit(&p.audio.callbacks,.Relaxed),sync.atomic_load_explicit(&p.audio.frames,.Relaxed)}
}

// On SDL's audio thread: no allocation, no lock of ours, only the mixer.
@(private)
audio_device_callback :: proc "c" (userdata:rawptr,stream:^sdl.AudioStream,additional_amount,total_amount:c.int) {
    device:=cast(^Audio_Device)userdata
    frame_bytes:=device.channels*size_of(f32)
    frames:=int(additional_amount)/frame_bytes
    sync.atomic_add_explicit(&device.callbacks,1,.Relaxed)
    for frames>0 {
        n:=min(frames,len(device.scratch)/device.channels)
        audio.mixer_render(device.mixer,device.scratch[:n*device.channels])
        if !sdl.PutAudioStreamData(stream,raw_data(device.scratch),c.int(n*frame_bytes)) {return}
        sync.atomic_add_explicit(&device.frames,u64(n),.Relaxed)
        frames-=n
    }
}
