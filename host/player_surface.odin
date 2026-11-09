package host

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import audio "mirai:audio"
import "mirai:platform"
import "mirai:rhi"

// A player whose image another process shows: the editor that opened it puts
// it in its viewport (--surface). Without a window it draws each frame into
// the next of SURFACE_RING shared textures and says on stdout which one is
// ready, in lines that start with SURFACE_PREFIX:
//
//   mirai-surface <width> <height> <id>...  the textures; again after a resize
//   mirai-frame <index>                     the texture the last frame finished
//   mirai-relative <0|1>                    the game asks for the mouse relative or not
//
// Its input comes on stdin, one event a line, in points of its image:
//
//   key <key> <down> <repeat> | text <codepoint> | wheel <dx> <dy>
//   button <button> <down> <clicks> <x> <y> | motion <x> <y> <dx> <dy>
//   focus <0|1> | size <width> <height>   (pixels)
//
// It is heard only while it has the focus.
//
// The end of stdin ends the player: the one that showed it is gone.

SURFACE_RING :: 3
SURFACE_PREFIX :: "mirai-"
SURFACE_FORMAT :: rhi.Format.BGRA8_Srgb // the UI samples it as the colors of the screen

@(private)
Player_Surface :: struct {
    textures:[SURFACE_RING]rhi.Texture,
    shared:[SURFACE_RING]rhi.Shared_Texture,
    next:int,
    size:[2]i32,         // pixels of the textures
    density:f32,
    relative,announced:bool,
    reader:^thread.Thread,
    lock:sync.Mutex,
    pending:[dynamic]u8, // what stdin brought, not read yet
    closed:bool,         // stdin ended
}

@(private)
surface_open :: proc(app:^App,s:^Player_Surface) -> bool {
    s.density=app.density
    error:runtime.Allocator_Error
    if s.pending,error=make([dynamic]u8,0,4096);error!=nil {return false}
    if app.mixer!=nil {_=audio.bus_set_mute(app.mixer,audio.BUS_MASTER,true)}
    if !surface_textures(app,s,app.drawable) {return false}
    s.reader=thread.create(surface_read)
    if s.reader==nil {return false}
    s.reader.data=s
    thread.start(s.reader)
    return true
}

@(private)
surface_close :: proc(app:^App,s:^Player_Surface) {
    surface_textures_free(app,s)
    // The reader stays blocked on stdin until it ends: it goes with the process.
    delete(s.pending)
}

@(private)
surface_textures_free :: proc(app:^App,s:^Player_Surface) {
    if app.device!=nil {rhi.device_wait_idle(app.device)}
    for &texture in s.textures {
        if texture!=0 {rhi.texture_destroy(app.device,texture)}
        texture=0
    }
    app.output=0
}

// The ring the size of the drawable, and its line.
@(private)
surface_textures :: proc(app:^App,s:^Player_Surface,size:[2]i32) -> bool {
    surface_textures_free(app,s)
    if app.device==nil || size.x<=0 || size.y<=0 {return false}
    for i in 0..<SURFACE_RING {
        s.textures[i],s.shared[i]=rhi.texture_create_shared(app.device,{width=u32(size.x),height=u32(size.y),format=SURFACE_FORMAT,usage={.Color_Target,.Sampled},name="surface"})
        if s.textures[i]==0 {
            fmt.eprintfln("mirai: %s",rhi.device_error(app.device))
            return false
        }
    }
    s.size,s.next,s.announced=size,0,false
    return true
}

@(private)
surface_read :: proc(t:^thread.Thread) {
    s:=(^Player_Surface)(t.data)
    buffer:[4096]u8
    for {
        n,error:=os.read(os.stdin,buffer[:])
        sync.mutex_lock(&s.lock)
        if n>0 {append(&s.pending,..buffer[:n])}
        if n<=0 || error!=nil {s.closed=true}
        sync.mutex_unlock(&s.lock)
        if n<=0 || error!=nil {return}
    }
}

// Before a frame: the events stdin brought go in as those of a window, and
// the frame draws into the next texture. False once stdin ended.
@(private)
surface_frame_begin :: proc(app:^App,s:^Player_Surface) -> bool {
    sync.mutex_lock(&s.lock)
    closed:=s.closed
    end:=len(s.pending)
    for end>0 && s.pending[end-1]!='\n' {end-=1}
    text:=strings.clone(string(s.pending[:end]),context.temp_allocator)
    remove_range(&s.pending,0,end)
    sync.mutex_unlock(&s.lock)
    for line in strings.split_lines_iterator(&text) {surface_event(app,s,line)}
    if !s.announced {
        line:=strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&line,"%ssurface %d %d",SURFACE_PREFIX,s.size.x,s.size.y)
        for id in s.shared {fmt.sbprintf(&line," %d",u64(id))}
        fmt.println(strings.to_string(line))
        s.announced=true
    }
    app.output=s.textures[s.next]
    return !closed
}

// After it: the texture is ready once the GPU is done with it.
@(private)
surface_frame_end :: proc(app:^App,s:^Player_Surface) {
    if app.output==0 {return}
    rhi.device_wait_idle(app.device)
    fmt.printfln("%sframe %d",SURFACE_PREFIX,s.next)
    s.next=(s.next+1)%SURFACE_RING
    if relative:=platform.window_relative_mouse(app.platform);relative!=s.relative {
        s.relative=relative
        fmt.printfln("%srelative %d",SURFACE_PREFIX,relative?1:0)
    }
    // A resize takes effect once the drawable has the new size.
    if app.drawable!=s.size && app.drawable.x>0 && app.drawable.y>0 {
        if !surface_textures(app,s,app.drawable) {app.quit=true}
    }
}

@(private)
surface_event :: proc(app:^App,s:^Player_Surface,line:string) {
    fields:=strings.fields(line,context.temp_allocator)
    if len(fields)==0 {return}
    number :: proc(fields:[]string,i:int) -> f32 {
        if i>=len(fields) {return 0}
        value,_:=strconv.parse_f32(fields[i])
        return value
    }
    p:=app.platform
    switch fields[0] {
    case "key":
        key:=int(number(fields,1))
        if key<0 || key>int(max(platform.Key)) {return}
        _=platform.input_inject(p,platform.Key_Event{key=platform.Key(key),down=number(fields,2)!=0,repeat=number(fields,3)!=0})
    case "text":
        _=platform.input_inject(p,platform.Text_Event{codepoint=rune(number(fields,1))})
    case "button":
        button:=int(number(fields,1))
        if button<0 || button>int(max(platform.Mouse_Button)) {return}
        _=platform.input_inject(p,platform.Mouse_Button_Event{button=platform.Mouse_Button(button),down=number(fields,2)!=0,clicks=u8(number(fields,3)),position={number(fields,4),number(fields,5)}})
    case "motion":
        _=platform.input_inject(p,platform.Mouse_Motion_Event{position={number(fields,1),number(fields,2)},delta={number(fields,3),number(fields,4)}})
    case "wheel":
        _=platform.input_inject(p,platform.Mouse_Wheel_Event{delta={number(fields,1),number(fields,2)}})
    case "focus":
        focused:=number(fields,1)!=0
        _=platform.input_inject(p,platform.Window_Event{kind=focused?.Focus_Gained:.Focus_Lost})
        // Only the player with the focus is heard: the others would sound at once.
        if app.mixer!=nil {_=audio.bus_set_mute(app.mixer,audio.BUS_MASTER,!focused)}
    case "size":
        size:=[2]i32{i32(number(fields,1)),i32(number(fields,2))}
        if size.x<=0 || size.y<=0 || size==s.size {return}
        density:=s.density>0?s.density:1
        platform.window_set_size(p,{max(i32(f32(size.x)/density+0.5),1),max(i32(f32(size.y)/density+0.5),1)})
    }
}
