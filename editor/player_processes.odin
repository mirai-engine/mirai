package editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:std/subprocess"
import "mirai:ui"

// Players of other processes the editor shows. A plugin that plays a game
// of its own (multiplayer: the online players of a game on the network)
// opens a process of the player per player, with the arguments that say what
// each one plays. Each runs the game of the library this editor loaded, as
// its Play does, so nothing is built for them. Each draws,
// without a window, into shared textures the editor shows in its part of the
// viewport, beside the parts of the local players of Play, and gets the input
// of the editor while it has the focus (host/player_surface.odin); a device
// that cannot share textures gets a window per player instead, tiled over the
// display.

PLAYER_PROCESSES :: 4 // the players of Play and those of other processes are this many at most
PLAYER_PROCESS_LINE :: 256
PLAY_COPIES_FOLDER :: "play"     // in the generated folder of the project
PLAY_SCENE :: "play.scene"       // the copy of the scene the game of this editor runs
PLAY_HOST_SCENE :: "host.scene"  // the copy of the scene of the game of the host that a guest joins

@(private)
Player_Process :: struct {
    handle:subprocess.Process,
    line:[PLAYER_PROCESS_LINE]u8, // output not ended by a newline yet
    length:int,
    // A player the editor shows: the textures it draws, as entries of the table of the renderer.
    images:[host.SURFACE_RING]gpu.Texture_Handle,
    size:[2]i32,  // pixels of its textures
    asked:[2]i32, // pixels it was told to draw
    shown:int,    // the texture of its last frame, plus one; 0: none yet
    relative:bool, // its game asks for the mouse relative
}

// A process that ended, and its exit code.
Player_Exit :: struct {index,code:int}

// The local players of Play, as the editor keeps them between sessions.
@(storage)
Play_Players :: struct {
    players:int, // that share the screen of this editor
}

PLAY_PLAYERS_DEFAULT :: Play_Players{players=1}

@(storage)
Player_Processes :: struct {
    processes:[PLAYER_PROCESSES]Player_Process,
    first,count:int, // the tile of the first process, after the local players of Play, and how many
    opened:bool,
    embedded:bool,   // they draw into the viewport; otherwise each has a window
    focus:int,       // the process with the input, plus one; 0: none
    captured:bool,   // the keyboard and the mouse go to it
    launch:Player_Launch, // the game player.start runs in a window of its own (player_launch.odin)
}

// The processes take the tiles from first on, count of them: what the screen
// is split into while they start and then.
player_processes_reserve :: proc(s:^Session,first,count:int) {
    p:=s.processes
    p.first,p.count=clamp(first,0,PLAYER_PROCESSES),clamp(count,0,PLAYER_PROCESSES)
}

// Opens a process of the player per command, on the tiles reserved: each
// command is what follows the program, without what the editor adds to show
// it. focus gives the first one the input from the start. Returns why it
// could not; then none is left open.
player_processes_open :: proc(s:^Session,commands:[][]string,focus:bool) -> string {
    p:=s.processes
    player:=engine_program_here(s,"mirai-player")
    if !os.is_file(player) {return "The player program is missing"}
    p.embedded=s.app.device!=nil && rhi.device_shares_textures(s.app.device) && s.gui.ctx!=nil
    display,tiled:=platform.display_usable(s.app.platform)
    for args,k in commands[:min(len(commands),p.count)] {
        command:=player_process_command(s,player,args,k,display,tiled)
        process,error:=subprocess.start({command=command,working_dir=s.project_root},pipes=.Merged)
        if error!=nil {
            player_processes_close(s)
            return "A player could not be started"
        }
        p.processes[k]={handle=process}
    }
    p.opened=true
    if focus && p.embedded {
        p.focus=1
        player_send(s,&p.processes[0],"focus 1")
    }
    return ""
}

// The command of the k-th process: the player on the library of this editor,
// whose game it runs, attached to it and shown in its tile, a texture of the
// viewport or a window of the display.
@(private)
player_process_command :: proc(s:^Session,player:string,args:[]string,k:int,display:[4]i32,tiled:bool) -> []string {
    p:=s.processes
    tiles:=p.first+p.count
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,player,"--attached")
    append(&command,..args)
    if p.embedded {
        pixels:=player_pixels(s,player_tile(player_region(s),tiles,p.first+k))
        p.processes[k].asked=pixels
        append(&command,"--surface",fmt.tprintf("%d,%d,%g",pixels.x,pixels.y,s.app.density))
    } else if tiled && tiles>1 {
        // Several windows share the display as the screen is split.
        r:=player_tile({f32(display.x),f32(display.y),f32(display.z),f32(display.w)},tiles,p.first+k)
        append(&command,"--window",fmt.tprintf("%d,%d,%d,%d",i32(r.x),i32(r.y),i32(r.w),i32(r.h)))
    }
    return command[:]
}

// What the processes printed, to the console, and those that ended since the last poll.
player_processes_poll :: proc(s:^Session) -> (exits:[PLAYER_PROCESSES]Player_Exit,count:int) {
    p:=s.processes
    if !p.opened {return}
    platform_:=s.app.platform
    for &process,i in p.processes[:p.count] {
        if process.handle.pid==0 {continue}
        player_drain(s,&process,i)
        state,_:=subprocess.wait(&process.handle,0)
        if !state.exited {continue}
        player_drain(s,&process,i)
        subprocess.release(&process.handle)
        player_images_free(s,&process)
        code:=state.exit_code
        if code!=0 {log.warnf("%s ended with code %d",player_name(p,i),code)}
        if p.focus==i+1 {
            if p.captured {platform.window_set_relative_mouse(platform_,false)}
            p.focus,p.captured=0,false
        }
        exits[count]={i,code}
        count+=1
    }
    return
}

// How many processes are alive.
player_processes_alive :: proc(s:^Session) -> (alive:int) {
    p:=s.processes
    if p==nil {return}
    for &process in p.processes[:p.count] {
        if process.handle.pid==0 {continue}
        if state,_:=subprocess.wait(&process.handle,0);!state.exited {alive+=1}
    }
    return
}

// Ends the processes and gives the screen back to the local players of Play.
player_processes_close :: proc(s:^Session) {
    p:=s.processes
    if p==nil {return}
    for &process in p.processes {
        subprocess.release(&process.handle)
        player_images_free(s,&process)
        process={}
    }
    if p.captured {platform.window_set_relative_mouse(s.app.platform,false)}
    p.focus,p.captured,p.embedded,p.opened=0,false,false,false
    p.first,p.count=0,0
    s.app.player_tile_count=0
}

// The parts the screen is split into: every player of this editor.
@(private)
player_tile_count :: proc "contextless" (p:^Player_Processes) -> int {return p.first+p.count}

// The part of a region one of count tiles takes: halves side by side for
// two, quarters for three and four, as local players split the screen.
@(private)
player_tile :: proc "contextless" (region:ui.Rect,count,index:int) -> ui.Rect {
    columns:=count>1?2:1
    rows:=count>2?2:1
    x,y:=index%columns,index/columns
    left,top:=f32(int(region.w)*x/columns),f32(int(region.h)*y/rows)
    return {region.x+left,region.y+top,f32(int(region.w)*(x+1)/columns)-left,f32(int(region.h)*(y+1)/rows)-top}
}

// The part of the window the players take: all of it under the bar.
@(private)
player_region :: proc(s:^Session) -> ui.Rect {
    size:=s.gui.ctx!=nil?s.gui.ctx.size:[2]f32{1280,800}
    bar:=s.gui.rects.bar.h
    return {0,bar,max(size.x,1),max(size.y-bar,1)}
}

@(private)
player_pixels :: proc(s:^Session,r:ui.Rect) -> [2]i32 {
    density:=s.app.density>0?s.app.density:1
    return {max(i32(r.w*density+0.5),1),max(i32(r.h*density+0.5),1)}
}

// What a process printed, a line at a time, to the console.
@(private)
player_drain :: proc(s:^Session,process:^Player_Process,at:int) {
    buffer:[2048]u8
    for {
        count,open:=subprocess.read(&process.handle,.Stdout,buffer[:])
        for b in buffer[:count] {
            if b=='\n' || process.length==len(process.line) {
                text:=strings.trim_right_space(string(process.line[:process.length]))
                if strings.has_prefix(text,host.SURFACE_PREFIX) {player_surface_line(s,process,text[len(host.SURFACE_PREFIX):])}
                else if process.length>0 {log.infof("%s: %s",player_name(s.processes,at),text)}
                process.length=0
                if b=='\n' {continue}
            }
            process.line[process.length]=b
            process.length+=1
        }
        if count<len(buffer) || !open {break}
    }
}

@(private)
player_name :: proc(p:^Player_Processes,at:int) -> string {return fmt.tprintf("P%d",p.first+at+1)}

// A line of a process about its textures: they changed, or one is ready.
@(private)
player_surface_line :: proc(s:^Session,process:^Player_Process,line:string) {
    fields:=strings.fields(line,context.temp_allocator)
    if len(fields)==0 {return}
    switch fields[0] {
    case "surface":
        if len(fields)!=3+host.SURFACE_RING || s.app.renderer==nil {return}
        width,_:=strconv.parse_int(fields[1])
        height,_:=strconv.parse_int(fields[2])
        player_images_free(s,process)
        for i in 0..<host.SURFACE_RING {
            id,_:=strconv.parse_u64(fields[3+i])
            handle,added:=gpu.texture_add_shared(s.app.renderer,rhi.Shared_Texture(id),width,height,host.SURFACE_FORMAT,"player process")
            if !added {
                log.errorf("the image of a player could not be opened: %s",s.app.renderer.error)
                player_images_free(s,process)
                return
            }
            process.images[i]=handle
        }
        process.size={i32(width),i32(height)}
    case "frame":
        if len(fields)<2 {return}
        index,_:=strconv.parse_int(fields[1])
        if index>=0 && index<host.SURFACE_RING && process.images[index]!=0 {process.shown=index+1}
    case "relative":
        process.relative=len(fields)>1 && fields[1]=="1"
        p:=s.processes
        if p.captured && &p.processes[p.focus-1]==process {platform.window_set_relative_mouse(s.app.platform,process.relative)}
    }
}

@(private)
player_images_free :: proc(s:^Session,process:^Player_Process) {
    for &image in process.images {
        if image!=0 && s.app.renderer!=nil {gpu.texture_remove(s.app.renderer,image)}
        image=0
    }
    process.shown=0
}

// The players of other processes draw into the viewport.
player_processes_images :: proc "contextless" (s:^Session) -> bool {
    p:=s.processes
    return p!=nil && p.opened && p.embedded
}

// They have the whole viewport: the editor shows them instead of the scene.
player_processes_view :: proc "contextless" (s:^Session) -> bool {return player_processes_images(s) && s.processes.first==0}

// The keyboard and the mouse go to one of them.
player_processes_captured :: proc "contextless" (s:^Session) -> bool {return player_processes_images(s) && s.processes.captured}

// The keyboard and the mouse go back to the editor; the players keep playing.
player_processes_release :: proc(s:^Session) {
    s.processes.captured=false
    platform.window_set_relative_mouse(s.app.platform,false)
}

// The process whose part of the viewport has a point, plus one; 0: none.
player_process_at :: proc(s:^Session,point:[2]f32) -> int {
    if !player_processes_images(s) {return 0}
    p:=s.processes
    region:=player_region(s)
    for k in 0..<p.count {
        if ui.rect_contains(player_tile(region,player_tile_count(p),p.first+k),point) {return k+1}
    }
    return 0
}

// The parts of the local players of Play, for the renderer and the UI of its
// game; none when it has the whole viewport.
@(private)
player_tiles_update :: proc(s:^Session) {
    p:=s.processes
    s.app.player_tile_count=0
    if p==nil || p.count==0 || p.first==0 || run_find(s,0)==nil {return}
    region:=player_region(s)
    density:=s.app.density>0?s.app.density:1
    for slot in 0..<min(p.first,len(s.app.player_tiles)) {
        r:=player_tile(region,player_tile_count(p),slot)
        s.app.player_tiles[slot]={i32(r.x*density+0.5),i32(r.y*density+0.5),i32(r.w*density+0.5),i32(r.h*density+0.5)}
        s.app.player_tile_count=slot+1
    }
}

// The image of each process in its part of the viewport, under the panels,
// the one with the input outlined.
player_processes_view_build :: proc(s:^Session) {
    if !player_processes_images(s) {return}
    p:=s.processes
    g:=s.gui
    ctx:=g.ctx
    region:=player_region(s)
    tiles:=player_tile_count(p)
    for k in 0..<p.count {
        process:=&p.processes[k]
        r:=player_tile(region,tiles,p.first+k)
        quad:ui.Quad
        if process.shown>0 && s.app.renderer!=nil {
            if image:=gpu.ui_image(s.app.renderer,process.images[process.shown-1]);image!=0 {quad=ui.quad_whole(.Image,image&~gpu.UI_MATERIAL_IMAGE_BIT)}
        }
        focused:=p.focus==k+1 && p.captured
        if ui.box(ctx,{width=ui.fixed(r.w),height=ui.fixed(r.h),float={to=.Surface,offset={r.x,r.y}},image=quad,fill=quad=={}?ui.tone(ctx,"panel"):{},
            stroke=focused?ui.tone(ctx,"accent"):ui.tone(ctx,"border"),stroke_width=focused?2:1,padding={10,10,10,10},align_x=.End,align_y=.End}) {
            label:=tiles>1?fmt.tprintf("P%d",p.first+k+1):""
            if process.shown==0 {label=tiles>1?fmt.tprintf("P%d  Connecting...",p.first+k+1):"Connecting..."}
            if label!="" {
                if ui.box(ctx,{width=ui.FIT,height=ui.fixed(20),padding={6,0,6,0},align_y=.Center,fill=ui.color_alpha(ui.tone(ctx,"popup"),220),radius=4}) {ui.label(ctx,label,ui.metric(ctx,"font_small"),focused?ui.tone(ctx,"text"):ui.tone(ctx,"text_muted"))}
            }
        }
    }
}

// Before the frame of the editor: a click on a process gives it the input;
// while it has it, the events of the window go to it, F1 takes the input
// back and Esc ends the game. The editor and the Play see no pointer
// meanwhile. The size of each part of the viewport goes to its process when
// it changes.
player_processes_input :: proc(s:^Session) {
    player_tiles_update(s)
    if !player_processes_images(s) {return}
    p:=s.processes
    app,g:=s.app,s.gui
    platform_:=app.platform
    frame:=platform.input_frame(platform_)
    region:=player_region(s)
    tiles:=player_tile_count(p)
    for k in 0..<p.count {
        process:=&p.processes[k]
        pixels:=player_pixels(s,player_tile(region,tiles,p.first+k))
        if process.handle.pid!=0 && pixels!=process.asked {
            process.asked=pixels
            player_send(s,process,fmt.tprintf("size %d %d",pixels.x,pixels.y))
        }
    }
    if !p.captured {
        free:=g.modal==.None && g.ctx!=nil && g.ctx.popup.count==0 && g.ctx.edit.id==0
        if !(free && .Left in frame.mouse_pressed && frame.mouse_inside) {return}
        point:=frame.mouse_position
        if ui.rect_contains(g.rects.bar,point) {return}
        k:=player_process_at(s,point)
        if k==0 {
            // The Play of this editor takes it back: the processes stop hearing.
            if p.focus!=0 {player_send(s,&p.processes[p.focus-1],"focus 0")}
            p.focus=0
            return
        }
        play_release_input(s)
        if p.focus!=0 && p.focus!=k {player_send(s,&p.processes[p.focus-1],"focus 0")}
        p.focus,p.captured=k,true
        focused:=&p.processes[k-1]
        player_send(s,focused,"focus 1")
        platform.window_set_relative_mouse(platform_,focused.relative)
        // The click that gives the input does not reach the game, nor the editor.
        app.ui_input.pressed,app.ui_input.down={},{}
        return
    }
    process:=&p.processes[p.focus-1]
    tile:=player_tile(region,tiles,p.first+p.focus-1)
    if .F1 in frame.keys_pressed {
        player_processes_release(s)
        return
    }
    if .Escape in frame.keys_pressed {
        s.requests+={.Stop}
        return
    }
    for event in platform.input_events(platform_) {
        switch e in event {
        case platform.Key_Event:
            if e.key==.F1 || e.key==.F5 || e.key==.Escape {continue}
            player_send(s,process,fmt.tprintf("key %d %d %d",int(e.key),e.down?1:0,e.repeat?1:0))
        case platform.Text_Event:
            player_send(s,process,fmt.tprintf("text %d",int(e.codepoint)))
        case platform.Mouse_Button_Event:
            player_send(s,process,fmt.tprintf("button %d %d %d %g %g",int(e.button),e.down?1:0,e.clicks,e.position.x-tile.x,e.position.y-tile.y))
        case platform.Mouse_Motion_Event:
            player_send(s,process,fmt.tprintf("motion %g %g %g %g",e.position.x-tile.x,e.position.y-tile.y,e.delta.x,e.delta.y))
        case platform.Mouse_Wheel_Event:
            player_send(s,process,fmt.tprintf("wheel %g %g",e.delta.x,e.delta.y))
        case platform.Gamepad_Device_Event,platform.Gamepad_Button_Event,platform.Gamepad_Axis_Event,platform.Window_Event,platform.Drop_Event,platform.Pen_Event:
        }
    }
    app.ui_input={size=app.ui_input.size,scale=app.ui_input.scale,safe=app.ui_input.safe,dt=app.ui_input.dt,pointer=app.ui_input.pointer,pointer_absent=true,view=app.ui_input.view}
}

@(private)
player_send :: proc(s:^Session,process:^Player_Process,line:string) {
    if process.handle.pid==0 {return}
    bytes:=transmute([]u8)fmt.tprintf("%s\n",line)
    _=subprocess.write(&process.handle,bytes)
}

// A copy of the scene a game of players of other processes runs, in the
// generated folder of the project.
play_copy_file :: proc(s:^Session,name:string) -> string {
    folder:=project.path(project.folder_path(s.project_root,.Generated,context.temp_allocator),PLAY_COPIES_FOLDER,allocator=context.temp_allocator)
    if !os.is_dir(folder) {_=os.make_directory_all(folder)}
    return project.path(folder,name,allocator=context.temp_allocator)
}

// Why the API does not start a game of players of other processes while
// assets have unsaved changes: they read the saved files. Empty without any.
play_unsaved :: proc(s:^Session) -> string {
    unsaved:=assets_unsaved_paths(s)
    if len(unsaved)==0 {return ""}
    names:=strings.builder_make(context.temp_allocator)
    for path,i in unsaved {
        if i>0 {strings.write_string(&names,", ")}
        strings.write_string(&names,unsaved_name(s,path))
    }
    one:=len(unsaved)==1
    return fmt.tprintf("The players of a game in other processes read the saved files, and %s unsaved changes: %s. Save %s with asset.save, or pass saved_only:true to play with what the files hold",one?"this asset has":"these assets have",strings.to_string(names),one?"it":"them")
}
