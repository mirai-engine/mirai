package editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import img "mirai:cook/image"
import "mirai:cook/movie"
import "mirai:core"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:project"
import render "mirai:render"
import "mirai:std/base"
import "mirai:std/jobs"

Record_Format :: enum u8 {
    Png16, // after the tonemap: what the window shows, 16 bits a channel
    Exr,   // before the tonemap: the exposed linear image, half floats
}

Api_Play_Record_Params :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"optional,text,label=Folder of the sequence; its frames are frame_000000 and on and the sound audio.wav. Under .mirai/recordings when empty"`,
    format:Record_Format `mirai:"optional,label=Png16: after the tonemap as the window shows it; Exr: before it in linear light unclipped"`,
    fps:int `mirai:"optional,min=1,max=240,label=Frames per second of the sequence; each lasts 1/fps of the time of the game"`,
    seconds:f32 `mirai:"optional,min=0.004,max=600,unit=s,label=Time of the game recorded"`,
    width:int `mirai:"optional,min=16,max=4096,label=Pixels of each frame"`,
    height:int `mirai:"optional,min=16,max=4096,label=Pixels of each frame"`,
    audio:bool `mirai:"optional,label=Mixes what the game makes heard into audio.wav as it plays"`,
    sheet:int `mirai:"optional,min=0,max=64,label=Tiles of sheet.png: frames evenly spaced from the first to the last each with its tick in the corner; 0: no sheet"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Record_Result :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The absolute folder of the sequence"`,
    first:[API_PATH_BYTES]u8 `mirai:"text,label=The file of its first frame"`,
    audio:[API_PATH_BYTES]u8 `mirai:"text,label=The WAV of 32-bit floats; empty without sound"`,
    sheet:[API_PATH_BYTES]u8 `mirai:"text,label=The contact sheet; empty without one"`,
    manifest:[API_PATH_BYTES]u8 `mirai:"text,label=manifest.json: the tick and time and camera and held actions of each frame and which frames the sheet shows"`,
    frames:int,
    fps:int,
    width,height:int,
    format:Record_Format,
    tick_from,tick_to:u64 `mirai:"label=The ticks of the game when it began and when it ended"`,
    seconds:f64 `mirai:"label=Time of the game it advanced"`,
    real_seconds:f64 `mirai:"label=What the recording took: drawing, reading back and writing every frame"`,
    sample_rate,channels:int,
    audio_frames:u64,
}

@(private)
api_play_record_register :: proc(s:^Session,st:^Api_State) {
    record_default:=Api_Play_Record_Params{format=.Png16,fps=30,seconds=2,width=1280,height=720,audio=true,sheet=16}
    api_register(s,st,{name="play.record",summary="Records the game of the caller as a sequence of images and its sound, frame after frame at a fixed rate whatever the clock: it pauses the game, advances it 1/fps each frame and draws it alone through its camera. Ends paused.",params=Api_Play_Record_Params,result=Api_Play_Record_Result,defaults=&record_default,run=api_play_record})
}

// A frame on its way to a file, and to its tile of the sheet.
@(private)
Record_Write :: struct {
    path:string,
    pixels:[]f32,
    width,height:int,
    format:Record_Format,
    sheet:^img.Sheet,
    tile:int, // -1: not on the sheet
    tick:u64,
    error:movie.Error,
    counter:jobs.Counter,
}

@(private)
record_write :: proc(w:^Record_Write,worker:int) {
    switch w.format {
    case .Png16: w.error=movie.png16_write(w.path,w.pixels,w.width,w.height)
    case .Exr:   w.error=movie.exr_write(w.path,w.pixels,w.width,w.height)
    }
    if w.tile>=0 {_=img.sheet_put(w.sheet,w.tile,w.pixels,w.width,w.height,w.format==.Exr,w.tick)}
}

// manifest.json of a recording: what each frame shows, to read before any image.
@(private)
Record_Manifest :: struct {
    fps:int,
    width,height:int,
    format:string,
    ticks_per_second:int,
    tick_from,tick_to:u64,
    audio:string,
    sheet:Record_Manifest_Sheet,
}

@(private)
Record_Manifest_Sheet :: struct {
    file:string,
    columns,rows:int,
    tile_width,tile_height:int,
    frames:[]int, // the frame of each tile, from the top left
}

@(private)
Record_Manifest_Frame :: struct {
    frame:int,
    file:string,
    tick:u64,     // the tick the frame shows: play.seek goes back to it
    seconds:f64,  // the time of the game then
    tile:int,     // its tile on the sheet; -1: none
    camera:Record_Manifest_Camera,
    inputs:[]Record_Manifest_Input, // the actions play.input held in its ticks
}

@(private)
Record_Manifest_Camera :: struct {
    position,forward,up:[3]f32,
    fov_deg:f32,
}

@(private)
Record_Manifest_Input :: struct {
    slot:int,
    action:string,
    value:[2]f32,
    until:u64, // the first tick it no longer acts in; 0: until let go
}

@(private)
api_play_record :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Record_Params)
    r,own:=api_play_run(s,call,p.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,"No game is playing; play.start first");return}
    if !own {api_play_refused(call);return}
    if s.app==nil || s.app.renderer==nil {api.call_fail(call,api.SERVER_ERROR,"play.record requires a GPU; start without --no-gpu");return}
    if problem:=run_script_blocks(s,r);problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    owner,player:=r.owner,r.player
    folder:string
    if path:=strings.trim_space(base.text_get(p.path[:]));path!="" {
        problem:string
        folder,problem=api_file_path(s.project_root,path,context.temp_allocator)
        if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    } else {
        if s.project_root=="" {api.call_fail(call,api.INVALID_PARAMS,"path is required without a project");return}
        tick:u64
        if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {tick=t.tick}
        folder=project.path(s.project_root,".mirai","recordings",fmt.tprintf("play-%d-%d",owner,tick),allocator=context.temp_allocator)
    }
    if os.is_file(folder) {api.call_failf(call,api.INVALID_PARAMS,"%s is a file: path names the folder of the sequence",folder);return}
    if error:=os.make_directory_all(folder);error!=nil && !os.is_dir(folder) {api.call_failf(call,api.SERVER_ERROR,"The folder %s could not be made: %s",folder,os.error_string(error));return}
    // The frames below free the temporary memory.
    folder=strings.clone(folder,s.app.allocator)
    defer delete(folder,s.app.allocator)
    extension:=p.format==.Exr?"exr":"png"
    // What an earlier recording left in the folder goes: a longer one would leave frames past these.
    for ext in ([2]string{"png","exr"}) {
        for n:=0;;n+=1 {
            if os.remove(project.path(folder,fmt.tprintf("frame_%06d.%s",n,ext),allocator=context.temp_allocator))!=nil {break}
        }
    }
    for name in ([3]string{"audio.wav","sheet.png","manifest.json"}) {_=os.remove(project.path(folder,name,allocator=context.temp_allocator))}
    began:=time.tick_now()
    frames:=max(int(f64(p.seconds)*f64(p.fps)+0.5),1)
    width,height:=p.width,p.height
    sheet:img.Sheet
    tiles:=min(p.sheet,frames)
    if tiles>0 {
        error:img.Error
        if sheet,error=img.sheet_make(tiles,width,height,s.app.allocator);error!=.None {
            api.call_failf(call,api.SERVER_ERROR,"No sheet of %d tiles of %dx%d: %s",tiles,width,height,img.error_message(error))
            return
        }
    }
    defer img.sheet_destroy(&sheet)
    shown:=make([dynamic]Record_Manifest_Frame,0,frames,s.app.allocator)
    held:=make([dynamic]Record_Manifest_Input,s.app.allocator)
    spans:=make([dynamic][2]int,0,frames,s.app.allocator) // of held, by frame
    defer {delete(shown);delete(held);delete(spans)}

    // Two frames on their way to their files while the next ones are drawn.
    writes:[2]Record_Write
    for &w in writes {
        pixels,error:=make([]f32,width*height*4,s.app.allocator)
        if error!=nil {
            for &other in writes {delete(other.pixels,s.app.allocator)}
            api.call_failf(call,api.SERVER_ERROR,"No memory for frames of %dx%d: record smaller ones",width,height)
            return
        }
        w=Record_Write{pixels=pixels,width=width,height=height,format=p.format}
    }
    defer for &w in writes {
        jobs.wait(&s.app.jobs,jobs.OWNER,&w.counter)
        delete(w.pixels,s.app.allocator)
        delete(w.path,s.app.allocator)
    }
    wide:=p.format==.Exr?render.View_Wide.Scene:render.View_Wide.Display
    rec:host.World_Recording
    if !host.app_recording_begin(s.app,&rec,{i32(width),i32(height)},wide,p.audio) {
        api.call_failf(call,api.SERVER_ERROR,"The recording could not start: the renderer takes no image of %dx%d, or the audio device could not be paused",width,height)
        return
    }
    defer host.app_recording_end(s.app,&rec)
    rate,channels:=host.app_recording_audio(s.app,&rec)
    wav:movie.Wav_Writer
    audio_path:string
    if p.audio {
        audio_path=project.path(folder,"audio.wav",allocator=s.app.allocator)
        if error:=movie.wav_open(&wav,audio_path,rate,channels);error!=.None {
            delete(audio_path,s.app.allocator)
            api.call_failf(call,api.SERVER_ERROR,"%s: %s",audio_path,movie.error_message(error))
            return
        }
    }
    defer if audio_path!="" {delete(audio_path,s.app.allocator)}
    sound,sound_error:=make([]f32,(rate/p.fps+2)*channels,s.app.allocator)
    if sound_error!=nil {
        if p.audio {movie.wav_close(&wav)}
        api.call_fail(call,api.SERVER_ERROR,"No memory for the sound of a frame")
        return
    }
    defer delete(sound,s.app.allocator)

    if owner==0 && !play_paused(s) {play_pause(s,true,stepped=true)}
    s.recording={i32(width),i32(height)}
    s.viewport.output_size=s.recording
    defer s.recording={}
    start:core.Time
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {start=t^}
    failure:string
    done:=0
    // Each frame ends where the frames so far put it, in ticks, and a hair
    // later: one that ends on a tick reaches it whatever the rounding.
    ticks:=max(int(1/f64(s.app.tick_dt)+0.5),1)
    for frame in 0..<frames {
        holds_from:=len(held)
        record_holds(s,run_ref(s,r),&held)
        dt:=(f64((frame+1)*ticks)/f64(p.fps)-f64(frame*ticks)/f64(p.fps)+1e-9)*f64(s.app.tick_dt)
        // A frame longer than the ticks a frame of the game runs is played in parts, drawn once.
        parts:=max(int(math.ceil(dt/(f64(max(s.app.max_ticks,1))*f64(s.app.tick_dt)))),1)
        for _ in 0..<parts {
            r.step,r.frame_dt=true,dt/f64(parts)
            if api_frames(s,1,0)==0 {failure="the editor was asked to end";break}
            if r=run_player(s,owner,player);r==nil {failure="the game ended";break}
        }
        if failure!="" {break}
        if p.audio {
            // The sound of the frames so far, to the sample, whatever their rate.
            due:=u64(frame+1)*u64(rate)/u64(p.fps)-rec.mixed
            part:=sound[:int(due)*channels]
            host.app_recording_mix(s.app,&rec,part)
            if error:=movie.wav_append(&wav,part);error!=.None {failure=fmt.tprintf("%s: %s",audio_path,movie.error_message(error));break}
        }
        w:=&writes[frame%2]
        jobs.wait(&s.app.jobs,jobs.OWNER,&w.counter)
        if w.error!=.None {failure=fmt.tprintf("%s: %s",w.path,movie.error_message(w.error));break}
        if !host.app_recording_frame(s.app,&rec,r.world,w.pixels) {failure="the frame could not be drawn";break}
        delete(w.path,s.app.allocator)
        w.path=project.path(folder,fmt.tprintf("frame_%06d.%s",frame,extension),allocator=s.app.allocator)
        shot:=Record_Manifest_Frame{frame=frame,tile=tiles>0?img.sheet_tile(frame,tiles,frames):-1}
        if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {shot.tick,shot.seconds=t.tick,t.seconds}
        camera:=s.app.camera
        shot.camera={position=camera.position,forward=camera.forward,up=camera.up,fov_deg=camera.fov_y}
        append(&shown,shot)
        append(&spans,[2]int{holds_from,len(held)})
        w.sheet,w.tile,w.tick=&sheet,shot.tile,shot.tick
        jobs.run(&s.app.jobs,jobs.OWNER,record_write,w,&w.counter)
        done+=1
    }
    for &w in writes {
        jobs.wait(&s.app.jobs,jobs.OWNER,&w.counter)
        if w.error!=.None && failure=="" {failure=fmt.tprintf("%s: %s",w.path,movie.error_message(w.error))}
    }
    if p.audio {
        if error:=movie.wav_close(&wav);error!=.None && failure=="" {failure=fmt.tprintf("%s: %s",audio_path,movie.error_message(error))}
    }
    s.view_cut=true
    sheet_path,manifest_path:string
    if failure=="" && tiles>0 {
        sheet_path=project.path(folder,"sheet.png",allocator=context.temp_allocator)
        if error:=img.image_write(sheet_path,sheet.image);error!=.None {failure=fmt.tprintf("%s: %s",sheet_path,img.error_message(error))}
    }
    if failure=="" {
        manifest:=Record_Manifest{
            fps=p.fps,width=width,height=height,format=fmt.tprint(p.format),
            ticks_per_second=ticks,tick_from=start.tick,audio=p.audio?"audio.wav":"",
        }
        if tiles>0 {
            manifest.sheet={file="sheet.png",columns=sheet.columns,rows=sheet.rows,tile_width=sheet.tile.x,tile_height=sheet.tile.y}
            manifest.sheet.frames=make([]int,tiles,context.temp_allocator)
            for &f,k in manifest.sheet.frames {f=img.sheet_frame(k,tiles,frames)}
        }
        if len(shown)>0 {manifest.tick_to=shown[len(shown)-1].tick}
        for &shot,i in shown {
            shot.file=fmt.tprintf("frame_%06d.%s",shot.frame,extension)
            shot.inputs=held[spans[i][0]:spans[i][1]]
        }
        manifest_path=project.path(folder,"manifest.json",allocator=context.temp_allocator)
        if problem:=record_manifest_write(manifest_path,manifest,shown[:]);problem!="" {failure=problem}
    }
    if failure!="" {
        api.call_failf(call,api.SERVER_ERROR,"The recording stopped after %d of %d frames: %s; %s keeps those",done,frames,failure,folder)
        return
    }
    result:=api.call_result(call,Api_Play_Record_Result)
    api_text_put(result.path[:],folder)
    api_text_put(result.first[:],project.path(folder,fmt.tprintf("frame_%06d.%s",0,extension),allocator=context.temp_allocator))
    api_text_put(result.audio[:],audio_path)
    api_text_put(result.sheet[:],sheet_path)
    api_text_put(result.manifest[:],manifest_path)
    result.frames,result.fps,result.width,result.height,result.format=done,p.fps,width,height,p.format
    result.tick_from=start.tick
    result.real_seconds=time.duration_seconds(time.tick_since(began))
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {result.tick_to,result.seconds=t.tick,t.seconds-start.seconds}
    if p.audio {result.sample_rate,result.channels,result.audio_frames=rate,channels,wav.frames}
}

// The actions each local seat holds in the next tick the game runs.
@(private)
record_holds :: proc(s:^Session,w:core.World_Ref,out:^[dynamic]Record_Manifest_Input) {
    seats:=core.world_table_of(w,input.Seat)
    if seats==nil {return}
    tick:u64
    if t:=core.world_storage_of(w,core.Time);t!=nil {tick=t.tick}
    requests:=core.world_storage_of(w,input.Hold_Requests)
    read:=core.read(seats)
    for row in 0..<core.count(read) {
        seat:=core.at(read,row)
        if !input.seat_local(seat) {continue}
        holds,count:=input.holds_at(seat,core.entity_at(read,row),requests,tick)
        for h in holds[:count] {
            name,_:=core.name_of(s.info,input.Action,i64(h.action))
            append(out,Record_Manifest_Input{slot=int(seat.slot),action=name,value=h.value,until=h.until})
        }
    }
}

// The manifest with a line per frame, to read in parts; "" or what failed.
@(private)
record_manifest_write :: proc(path:string,manifest:Record_Manifest,frames:[]Record_Manifest_Frame) -> string {
    head,error:=json.marshal(manifest,{},context.temp_allocator)
    if error!=nil {return "No memory for the manifest"}
    b:=strings.builder_make(context.temp_allocator)
    strings.write_bytes(&b,head[:len(head)-1])
    strings.write_string(&b,`,"frames":[`)
    for &frame,i in frames {
        line,line_error:=json.marshal(frame,{},context.temp_allocator)
        if line_error!=nil {return "No memory for the manifest"}
        strings.write_string(&b,i==0?"\n":",\n")
        strings.write_bytes(&b,line)
    }
    strings.write_string(&b,"\n]}\n")
    if write_error:=os.write_entire_file(path,b.buf[:]);write_error!=nil {return fmt.tprintf("%s: %s",path,os.error_string(write_error))}
    return ""
}
