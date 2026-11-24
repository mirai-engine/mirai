package mirai_audio

// The echo of a bus, miniaudio's ma_delay with its decay as feedback: what
// comes in plays at once and again seconds later, each echo feedback times the
// last. Its line is reserved the first time the bus is given one. A change of
// time crossfades from the old tap to the new one over the chunk, and wet and
// feedback ramp across it, so it never clicks.

Delay :: struct {
    seconds:f32,  // between the sound and its first echo; up to DELAY_SECONDS_MAX
    feedback:f32, // share of each echo that echoes again; up to DELAY_FEEDBACK_MAX
    wet:f32,      // gain of the echoes; 0: none
}

DELAY_SECONDS_MAX :: f32(1)
DELAY_FEEDBACK_MAX :: f32(0.95)

@(private)
Delay_Line :: struct {
    memory:[]f32, // stereo frames, a power of two of them; nil until the bus has a delay
    write:int,
    params:Delay,
    frames,old_frames:int, // of the tap, and of the one before the last change
    wet,feedback:f32,      // reached at the end of the last chunk
    moved:bool,            // the tap moved: crossfade from the old one in the next chunk
    used,stale:bool,       // it ran; it stopped while it held echoes, which the next run clears
}

// Frames of a delay line: past the longest delay by a chunk, a power of two.
@(private)
delay_line_frames :: proc(sample_rate:int) -> int {
    frames:=CHUNK_FRAMES
    for frames<int(DELAY_SECONDS_MAX*f32(sample_rate))+CHUNK_FRAMES {frames*=2}
    return frames
}

@(private)
delay_clamp :: proc "contextless" (d:Delay) -> Delay {
    return {clamp(d.seconds,0,DELAY_SECONDS_MAX),clamp(d.feedback,0,DELAY_FEEDBACK_MAX),max(d.wet,0)}
}

@(private)
delay_apply :: proc "contextless" (line:^Delay_Line,d:Delay,memory:[]f32,sample_rate:int) {
    line.memory=memory
    frames:=max(int(d.seconds*f32(sample_rate)+0.5),1)
    if frames!=line.frames {
        if !line.moved {line.old_frames=line.frames}
        line.frames,line.moved=frames,line.old_frames!=0
    }
    line.params=d
}

// Adds the echoes of a bus to its n frames, in place.
@(private)
delay_run :: proc "contextless" (line:^Delay_Line,buffer:[^]f32,n:int) {
    if line.memory==nil || line.params.wet==0 && line.wet==0 {
        line.stale||=line.used
        line.used=false
        return
    }
    if line.stale {
        #no_bounds_check for &x in line.memory {x=0}
        line.stale,line.write,line.moved=false,0,false
    }
    mask:=len(line.memory)/2-1
    memory:=raw_data(line.memory)
    wet0,feedback0:=line.wet,line.feedback
    dwet,dfeedback:=(line.params.wet-wet0)/f32(n),(line.params.feedback-feedback0)/f32(n)
    old:=line.old_frames if line.moved else line.frames
    #no_bounds_check for k in 0..<n {
        t:=f32(k)/f32(n)
        wet,feedback:=wet0+dwet*f32(k),feedback0+dfeedback*f32(k)
        w:=(line.write+k)&mask
        r:=(line.write+k-line.frames)&mask
        o:=(line.write+k-old)&mask
        for c in 0..<2 {
            tap:=memory[r*2+c]
            if line.moved {
                before:=memory[o*2+c]
                tap=before+(tap-before)*t
            }
            x:=buffer[k*2+c]
            memory[w*2+c]=x+feedback*tap
            buffer[k*2+c]=x+wet*tap
        }
    }
    line.write=(line.write+n)&mask
    line.wet,line.feedback,line.moved,line.used=line.params.wet,line.params.feedback,false,true
}
