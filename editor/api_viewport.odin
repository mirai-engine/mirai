package editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import img "mirai:cook/image"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"

Api_Viewport_Params :: struct {
    request:[64]u8 `mirai:"optional,text,label=An older message of the turn by the folder of its snapshot under .mirai/ai; empty: the message of the turn of the caller"`,
}

Api_Viewport_Result :: struct {
    path:string `mirai:"label=The absolute path of the PNG the message saved; MCP also returns the image"`,
}

Api_Capture_Of :: enum u8 {Auto,Scene,Game}

// What capture draws over the image alone to show what the frames do not:
// overlays by name, those of the editor and those plugins register
// (Capture_Overlay_Provider).
API_CAPTURE_OVERLAYS :: 16
API_CAPTURE_OVERLAY_NAME :: 32
API_CAPTURE_OVERLAY_BOUNDS :: "bounds"
API_CAPTURE_OVERLAY_TRAJECTORY :: "trajectory"

// The overlays debug names, as capture draws them.
Api_Capture_Overlays :: struct {
    bounds,trajectory:bool,
    draws:[API_CAPTURE_OVERLAYS]proc(s:^Session,w:core.World_Ref,lines:^gpu.Debug_Lines),
    count:int, // of draws
}

Api_Capture_Params :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"optional,text,label=PNG to write: absolute (C:/shots/a.png or /c/shots/a.png as Git Bash writes it) or relative to the folder of the project; its folder is made; the answer is only where it is and its size. Without it one under .mirai/captures and MCP also returns the image"`,
    ui:bool `mirai:"optional,label=The whole window with the editor around what it shows, as the user sees it; false: the image alone"`,
    of:Api_Capture_Of `mirai:"optional,label=What the image alone shows. Game: the game of the caller through its camera with its own interfaces. Scene: what the viewport shows through its camera without panels or gizmos or grid or selection. Auto: Game while the caller has one playing, otherwise Scene"`,
    debug:[API_CAPTURE_OVERLAYS][API_CAPTURE_OVERLAY_NAME]u8 `mirai:"optional,text,label=Overlays by name drawn as lines over the image alone and over every cell of a filmstrip, seen through what is in front: bounds the box in the world of each mesh drawn (follow in another color), trajectory the path of follow (or else of the body of the focused seat) along the ticks of a filmstrip, and those of the plugins of the project (skeleton, match, collision, contacts, joints, hitboxes, navigation); an unknown name fails listing those there are. Neither the document nor the viewport changes"`,
    frames:int `mirai:"optional,min=0,max=3600,label=Frames drawn first so that what builds up over time settles; 0: as many as the image needs and its textures streamed in. At most 120 of a game"`,
    dt:f32 `mirai:"optional,min=0.0001,max=0.25,unit=s,label=Not of a game: the step of each frame of a manual editor"`,
    seconds:f64 `mirai:"optional,min=-1,max=1e9,unit=s,label=Not of a game: the clock of the window when the frames start, which the renderer draws by; below 0 it goes on: a scene loaded again and captured at the same seconds draws the same frames"`,
    generated:bool `mirai:"optional,label=With ui: the image the window showed before that of the last frame, which frame generation drew"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
    every:[api.DURATION_TEXT]u8 `mirai:"optional,text,label=Filmstrip: what the game runs between two cells of one image: a number is ticks and a text ending in s is seconds as 10 or 0.5s; with segments and no count as many cells as they last; 0: an image of now"`,
    count:int `mirai:"optional,min=0,max=64,label=Filmstrip: its cells; the first shows the game before the first tick; with segments and no every they spread evenly over their ticks"`,
    columns:int `mirai:"optional,min=0,max=64,label=Filmstrip: cells across; 0: as square as they fit"`,
    segments:[API_STEP_SEGMENTS]Api_Play_Segment `mirai:"optional,label=Filmstrip: the input along its ticks as play.step takes it; they say how many ticks it runs"`,
    follow:[API_ENTITY_TEXT]u8 `mirai:"optional,text,entity,label=Filmstrip: every cell is centered on where this entity shows; by its name or a path Parent/Child or its id or its handle"`,
    size:[2]f32 `mirai:"optional,min=8,max=4096,label=Filmstrip that follows an entity: width and height of a cell in points of the image"`,
    region:[4]f32 `mirai:"optional,label=x y width height of the part written, in pixels from the top left of the image; of a filmstrip, in points, what every cell shows in place of following an entity. None: all of it"`,
    width:int `mirai:"optional,min=0,max=4096,label=Pixels of the image alone; 0 keeps the aspect of what it shows (its size when height is 0 too)"`,
    height:int `mirai:"optional,min=0,max=4096,label=Pixels of the image alone; 0 keeps the aspect of what it shows (its size when width is 0 too)"`,
}

// A game draws at most these frames for an image.
// The lines debug draws over an image, two vertices each; those past it are left out.
API_CAPTURE_DEBUG_VERTICES :: 65536

API_CAPTURE_GAME_FRAMES :: 120

// The longest a capture of automatic frames waits for textures to stream in.
API_CAPTURE_TEXTURES_WAIT :: 10*time.Second

// The longest a capture waits for what its frames draw to be made (api_view_wait).
API_VIEW_WAIT :: API_SHADERS_SECONDS*time.Second
API_VIEW_POLL :: 20*time.Millisecond

// What the renderer counted of the image it drew last.
Api_Capture_Seen :: struct {
    textures_pending:int `mirai:"label=Textures still streaming when the image was taken; above 0 with frames left automatic: its wait ran out"`,
    instances_drawn:int `mirai:"label=Instances drawn in the image; 0 with instances_culled above 0: the camera sees none of what is there; all three 0: nothing is there for it to see"`,
    instances_culled:int `mirai:"label=Instances outside the view of its camera or hidden from it"`,
    instances_occluded:int `mirai:"label=Instances in its view behind something drawn"`,
}

Api_Capture_Result :: struct {
    path:string `mirai:"label=The absolute path of the file written"`,
    width:int `mirai:"label=Pixels of the image"`,
    height:int `mirai:"label=Pixels of the image"`,
    columns:int `mirai:"optional,label=A filmstrip: its cells across"`,
    rows:int `mirai:"optional,label=A filmstrip: its cells down"`,
    cell:[2]int `mirai:"optional,label=A filmstrip: the pixels of a cell"`,
    ticks:int `mirai:"optional,label=A filmstrip: the ticks it ran"`,
    cells:[]Api_Capture_Cell `mirai:"optional,label=A filmstrip: its cells from the top left row by row"`,
    using seen:Api_Capture_Seen `mirai:"inline"`,
}
Api_Capture_Cell :: struct {
    tick:u64 `mirai:"label=The tick of the game it shows"`,
    at:[]f32 `mirai:"optional,label=Following an entity: where it shows in points of the image; absent when it is behind the camera or gone"`,
}

@(private)
api_viewport_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="view.viewport",summary="see what the user was looking at when sent this message",params=type_info_of(Api_Viewport_Params),result=type_info_of(Api_Viewport_Result),flags={.Core,.Read_Only,.Idempotent,.Draws},run=api_view_viewport})
    capture_default:=Api_Capture_Params{dt=HEADLESS_DT,seconds=-1,size={256,256}}
    api_register(s,st,{name="capture",summary="Draws fresh frames and writes a PNG: alone, the game of the caller as its camera shows it, drawn without showing it on the user's screen, or the edited scene through the camera of the viewport when no game plays (of chooses); with ui, the window of the editor as the user sees it. With path the answer is only where it is and its size; without path MCP also returns the image. With every and count, or segments with every or count, it steps the game and writes one filmstrip of cells around an entity or a region with the tick of each.",params=type_info_of(Api_Capture_Params),result=type_info_of(Api_Capture_Result),defaults=&capture_default,flags={.Core,.Read_Only,.As_User,.Draws},run=api_capture})
}

// What the caller is playing as an image, the scene the viewport shows or the
// window: all the images of the editor and the game come out of here.
@(private)
api_capture :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Capture_Params)
    r,own:=api_play_run(s,call,p.player)
    if p.ui && p.of!=.Auto {api.call_fail(call,api.INVALID_PARAMS,"of chooses what the image alone shows: leave it out with ui");return}
    if p.ui && (p.width>0 || p.height>0) {api.call_fail(call,api.INVALID_PARAMS,"width and height size the image alone: leave ui out with them, or leave them out for the window");return}
    if p.generated && !p.ui {api.call_fail(call,api.INVALID_PARAMS,"generated reads the image the window showed: pass ui true with it");return}
    overlays,named:=api_capture_overlays(s,call,p.debug[:])
    if !named {return}
    if api_capture_overlays_any(overlays) && p.ui {api.call_fail(call,api.INVALID_PARAMS,"debug draws over the image alone: leave ui out with it");return}
    filmstrip:=(p.every[0]!=0 && base.text_get(p.every[:])!="0") || api_filmstrip_spread(call,p)
    if filmstrip && p.of==.Scene {api.call_fail(call,api.INVALID_PARAMS,"a filmstrip steps the game: leave of out, or give Game");return}
    game:=!p.ui && p.of!=.Scene && (r!=nil || p.of==.Game)
    if (game || filmstrip) && r==nil {api_no_game(call);return}
    if game || filmstrip {
        if p.seconds>=0 || p.dt!=HEADLESS_DT {api.call_fail(call,api.INVALID_PARAMS,"dt and seconds are the clock of the window: a game runs by its ticks, so leave them out");return}
        if p.frames>API_CAPTURE_GAME_FRAMES {api.call_failf(call,api.INVALID_PARAMS,"frames: a game draws at most %d for an image",API_CAPTURE_GAME_FRAMES);return}
    }
    strip,ok:=api_filmstrip_read(s,call,r,own,p,overlays)
    if !ok {return}
    if overlays.trajectory && strip==nil {api.call_fail(call,api.INVALID_PARAMS,"trajectory is the path along the ticks of a filmstrip: give every with count, or segments");return}
    region:img.Region
    if strip!=nil {
        if p.width>0 || p.height>0 {api.call_fail(call,api.INVALID_PARAMS,"width and height size one image: a filmstrip takes the size of its cell or a region");return}
        if p.ui && r.owner!=0 {api.call_fail(call,api.INVALID_PARAMS,"The window does not show the game of a turn: leave ui out of its filmstrip");return}
    } else if p.region!={} {
        q:=p.region
        if !rpc_finite(q.x) || !rpc_finite(q.y) || !rpc_finite(q.z) || !rpc_finite(q.w) || q.x<0 || q.y<0 || q.z<1 || q.w<1 {
            api.call_fail(call,api.INVALID_PARAMS,"region is x, y, width and height in pixels, from the top left: give it a width and a height, or leave it out for the whole image")
            return
        }
        region={int(q.x),int(q.y),int(q.z),int(q.w)}
    }
    if s.app==nil || s.app.renderer==nil {api.call_fail(call,api.SERVER_ERROR,"capture requires a GPU; start without --no-gpu");return}
    started:=time.tick_now()
    given:=base.text_get(p.path[:])
    // Relative to the project, its folder made. The frames drawn below free the temporary memory.
    name:="editor.png"
    if game || strip!=nil {name=fmt.tprintf("play-%d%s.png",r.owner,strip!=nil?"-strip":"")}
    path,writable:=api_capture_file(s,call,given,name,s.app.allocator)
    if !writable {return}
    defer delete(path,s.app.allocator)
    // Nothing is drawn while a compilation of programs makes the first frames draw stand-ins.
    if ok,_:=api_view_wait(s,call,p.dt,started,window_frames=!game && strip==nil);!ok {return}
    if strip!=nil {api_filmstrip_run(s,call,strip,path,given=="");return}
    debug:[]gpu.Debug_Lines
    build_debug :: proc(s:^Session,call:^api.Call,w:core.World_Ref,overlays:^Api_Capture_Overlays) -> ([]gpu.Debug_Lines,bool) {
        if !api_capture_overlays_any(overlays^) {return nil,true}
        lines,made:=api_capture_debug_make(call)
        if !made {return nil,false}
        api_capture_debug_draw(s,w,overlays,core.NONE,nil,&lines)
        out:=make([]gpu.Debug_Lines,1,call.allocator)
        out[0]=lines
        return out,true
    }
    pixels:[]u8
    width,height:int
    wait:=p.frames==0?API_CAPTURE_TEXTURES_WAIT:time.Duration(0)
    if game {
        debug_ok:bool
        debug,debug_ok=build_debug(s,call,run_ref(s,r),&overlays)
        if !debug_ok {return}
        frames:=p.frames>0?p.frames:API_CAPTURE_SETTLE
        for {
            drawn:bool
            pixels,width,height,drawn=api_play_pixels(s,r,frames,wait=wait,debug=debug)
            if !drawn {api.call_failf(call,api.SERVER_ERROR,"The game could not be drawn: %s",host.app_draw_problem(s.app));return}
            // What those frames found being made: drawn again once it is, its own frames
            // streaming what arrives, without stepping the game.
            ok,changed:=api_view_wait(s,call,p.dt,started,window_frames=false)
            if ok && !changed {break}
            delete(pixels,s.app.allocator)
            if !ok {return}
            frames,wait=API_CAPTURE_SETTLE,API_CAPTURE_TEXTURES_WAIT
        }
        if size:=api_capture_size({i32(width),i32(height)},p.width,p.height);int(size.x)!=width || int(size.y)!=height {
            scaled,made:=api_pixels_scale(pixels,width,height,size,s.app.allocator)
            delete(pixels,s.app.allocator)
            if !made {api.call_failf(call,api.SERVER_ERROR,"The image of %dx%d could not be made: out of memory",size.x,size.y);return}
            pixels,width,height=scaled,int(size.x),int(size.y)
        }
    } else {
        drawn:=s.app.stats.frames_drawn
        if p.seconds>=0 {s.app.seconds=p.seconds}
        api_frames(s,max(p.frames,1),p.dt)
        // What those frames found being made (a program's pipelines, a mesh arriving): frames more once it is.
        for {
            ok,changed:=api_view_wait(s,call,p.dt,started)
            if !ok {return}
            if !changed {break}
            api_frames(s,API_CAPTURE_SETTLE,p.dt)
        }
        if s.app.stats.frames_drawn==drawn {api.call_failf(call,api.SERVER_ERROR,"The renderer could not draw the frame: %s",host.app_draw_problem(s.app));return}
        if p.ui && wait>0 {api_capture_textures_settle(s,p.dt,wait)}
        if p.generated && !gpu.renderer_stats(s.app.renderer).generated {
            api.call_fail(call,api.SERVER_ERROR,"The last frame showed no generated image: frame generation needs FSR 3.1 as the antialiasing, frame_generation on in Graphics_Settings and a frame with history")
            return
        }
        // Build debug overlays after the scene frames have evaluated animations and transforms.
        debug_ok:bool
        debug,debug_ok=build_debug(s,call,shown_world(s),&overlays)
        if !debug_ok {return}
        size:=api_capture_size(api_capture_viewport(s.app),p.width,p.height)
        read:bool
        pixels,width,height,read=api_capture_image(s,p.ui,size,p.generated,wait,debug)
        if !read {api.call_failf(call,api.SERVER_ERROR,"The image of %dx%d could not be drawn or read: %s",size.x,size.y,host.app_draw_problem(s.app));return}
    }
    seen:=api_capture_seen(s.app)
    if region!={} {
        cropped,error:=img.image_crop({pixels=pixels,width=width,height=height},region,s.app.allocator)
        delete(pixels,s.app.allocator)
        if error==.Bad_Region {
            api.call_failf(call,api.INVALID_PARAMS,"region %d,%d,%d,%d falls outside the image of %dx%d: x plus width may be %d at most and y plus height %d",region.x,region.y,region.w,region.h,width,height,width,height)
            return
        }
        if error!=.None {api.call_fail(call,api.SERVER_ERROR,"The region could not be cut: out of memory");return}
        pixels,width,height=cropped.pixels,cropped.width,cropped.height
    }
    api_capture_answer(s,call,path,pixels,width,height,given=="",seen)
}

// The storage of the lines debug draws over an image, in the allocator of
// the call; false after failing it.
@(private)
api_capture_debug_make :: proc(call:^api.Call) -> (lines:gpu.Debug_Lines,ok:bool) {
    storage,error:=make([]gpu.Debug_Vertex,API_CAPTURE_DEBUG_VERTICES,call.allocator)
    if error!=nil {api.call_fail(call,api.SERVER_ERROR,"No memory for the lines of debug");return}
    return gpu.debug_lines_make(storage,depth_test=false),true
}

API_CAPTURE_BOUNDS :: [4]f32{0.2,1,0.4,1}
API_CAPTURE_FOLLOWED :: [4]f32{1,0.85,0.1,1}
API_CAPTURE_TRAIL :: [4]f32{1,0.25,0.9,1}

// The overlays names asks for, the plugins' by the name each registers.
// False after failing the call for a name no overlay of the project has,
// listing those it has.
@(private)
api_capture_overlays :: proc(s:^Session,call:^api.Call,names:[][API_CAPTURE_OVERLAY_NAME]u8) -> (overlays:Api_Capture_Overlays,ok:bool) {
    found:[PROVIDER_CAPACITY]Capture_Overlay_Provider
    providers:=found[:provided_all(s,found[:])]
    taken:[PROVIDER_CAPACITY]bool
    for &text in names {
        name:=base.text_get(text[:])
        switch name {
        case "": continue
        case API_CAPTURE_OVERLAY_BOUNDS: overlays.bounds=true;continue
        case API_CAPTURE_OVERLAY_TRAJECTORY: overlays.trajectory=true;continue
        }
        known:=false
        for provider,i in providers {
            if provider.name!=name || provider.draw==nil {continue}
            known=true
            if !taken[i] {
                overlays.draws[overlays.count]=provider.draw
                overlays.count+=1
                taken[i]=true
            }
            break
        }
        if known {continue}
        available:=make([dynamic]string,0,len(providers)+2,context.temp_allocator)
        append(&available,API_CAPTURE_OVERLAY_BOUNDS,API_CAPTURE_OVERLAY_TRAJECTORY)
        for provider in providers {if provider.draw!=nil {append(&available,provider.name)}}
        api.call_failf(call,api.INVALID_PARAMS,"debug %q: no overlay of the project has that name; it has %s (a plugin that is not in the project draws none)",name,strings.join(available[:],", ",context.temp_allocator))
        return {},false
    }
    return overlays,true
}

@(private)
api_capture_overlays_any :: proc(overlays:Api_Capture_Overlays) -> bool {
    return overlays.bounds || overlays.trajectory || overlays.count>0
}

// The lines of debug over an image of w as it is now, in place of those
// lines held: the world boxes of the meshes it draws (those of follow and
// what hangs from it in their own color) and trail, the path taken; the
// overlays of the plugins draw the rest.
@(private)
api_capture_debug_draw :: proc(s:^Session,w:core.World_Ref,overlays:^Api_Capture_Overlays,follow:core.Entity,trail:[][3]f32,lines:^gpu.Debug_Lines) {
    gpu.debug_lines_clear(lines)
    if overlays.bounds && s.app.assets!=nil {
        items:=scene_items(s,w)
        for item in scene_item_next(&items) {
            if !item.body {continue}
            low,high,known:=mesh_bounds(s.app.assets,item.mesh)
            if !known {continue}
            box:=mm.aabb_transform({low,high},mm.transform_matrix(item.world))
            followed:=follow!=core.NONE && entity_under(w,item.entity,follow)
            gpu.debug_box(lines,box.min,box.max,API_CAPTURE_FOLLOWED if followed else API_CAPTURE_BOUNDS)
        }
    }
    if overlays.trajectory && len(trail)>0 {
        for i in 1..<len(trail) {gpu.debug_line(lines,trail[i-1],trail[i],API_CAPTURE_TRAIL)}
        gpu.debug_sphere(lines,trail[len(trail)-1],0.1,API_CAPTURE_TRAIL,12)
    }
    for draw in overlays.draws[:overlays.count] {draw(s,w,lines)}
}

// Window frames until no texture of what the window shows is pending or the
// wait runs out, then enough for what builds up over frames to settle with them.
@(private)
api_capture_textures_settle :: proc(s:^Session,dt:f32,wait:time.Duration) {
    started:=time.tick_now()
    waited:=false
    for gpu.textures_update(s.app.renderer)+host.app_assets_arriving(s.app)>0 && time.tick_since(started)<wait && !s.quit {
        api_frames(s,1,dt)
        waited=true
    }
    if waited {api_frames(s,API_CAPTURE_SETTLE,dt)}
}

// Until nothing the frames draw is being made (view_pending), for at most
// wait since the call started: the programs of the project are followed, the
// pipelines frames asked for awaited and, while meshes or textures arrive,
// frames of the window drawn. A window draws frames meanwhile anyway; a
// manual editor draws none for the programs alone, so its clock stays, and
// none at all without window_frames (it would step a Play): it returns while
// meshes or textures arrive, for the caller to draw what streams them.
// changed: the frames would draw otherwise than those before, which are drawn
// again. False with the call failed, saying what was still pending and how
// long it waited.
@(private)
api_view_wait :: proc(s:^Session,call:^api.Call,dt:f32,started:time.Tick,wait:=API_VIEW_WAIT,window_frames:=true) -> (ok,changed:bool) {
    manual:=true
    if st:=api_state(s);st!=nil {manual=st.manual}
    for {
        if s.build!=nil {programs_poll(s)}
        if s.app.renderer!=nil {host.app_shaders_poll(s.app)}
        pending:=view_pending(s)
        if pending=={} {return true,changed}
        waited:=time.tick_since(started)
        if waited>wait || s.quit {
            api.call_failf(call,api.SERVER_ERROR,"After %.0f s the frames still draw stand-ins for what is being made: %s. engine.status gives it as pending; call %s again once it is 0",time.duration_seconds(waited),api_pending_text(pending),call.method.name)
            return false,changed
        }
        changed=true
        if pending.pipelines>0 {
            gpu.renderer_pipelines_wait(s.app.renderer)
            continue
        }
        if manual && !window_frames && pending.assets>0 {return true,changed}
        if (!manual || pending.assets>0) && api_frames(s,1,dt)>0 {continue}
        time.sleep(API_VIEW_POLL)
    }
}

// What view_pending counted, in words.
@(private)
api_pending_text :: proc(pending:host.App_Pending) -> string {
    parts:=make([dynamic]string,context.temp_allocator)
    if pending.programs>0 {append(&parts,fmt.tprintf("%d compilation(s) of the material programs of the project",pending.programs))}
    if pending.pipelines>0 {append(&parts,fmt.tprintf("%d pipeline(s) of programs or passes",pending.pipelines))}
    if pending.assets>0 {append(&parts,fmt.tprintf("%d mesh(es) or texture(s) arriving",pending.assets))}
    return strings.join(parts[:],", ",context.temp_allocator)
}

// What the renderer counted of the image just read from it.
@(private)
api_capture_seen :: proc(app:^host.App) -> Api_Capture_Seen {
    stats:=gpu.renderer_stats_of_last_frame(app.renderer)
    return {int(stats.textures_pending),int(stats.visible_instances),int(stats.culled_instances),int(stats.occluded_instances)}
}

// What capture answers for one image; shown: MCP also gives the image. path
// is copied: the answer is written after whoever made it lets go of it.
@(private)
api_capture_reply :: proc(call:^api.Call,path:string,width,height:int,shown:bool,seen:=Api_Capture_Seen{}) {
    api.call_result(call,Api_Capture_Result)^={path=api.clone_text(call.allocator,path),width=width,height=height,seen=seen}
    if shown {api.call_image(call,path)}
}

// RGBA8 pixels at size, each the average of those of the source it covers,
// in allocator; the source stays. False when it does not fit in memory.
@(private)
api_pixels_scale :: proc(pixels:[]u8,width,height:int,size:[2]i32,allocator:runtime.Allocator) -> (scaled:[]u8,ok:bool) {
    w,h:=int(size.x),int(size.y)
    if w<=0 || h<=0 || width<=0 || height<=0 || len(pixels)<width*height*4 {return}
    memory:runtime.Allocator_Error
    if scaled,memory=make([]u8,w*h*4,allocator);memory!=nil {return nil,false}
    for y in 0..<h {
        y0,y1:=y*height/h,max((y+1)*height/h,y*height/h+1)
        for x in 0..<w {
            x0,x1:=x*width/w,max((x+1)*width/w,x*width/w+1)
            sum:[4]int
            for sy in y0..<y1 {
                for sx in x0..<x1 {
                    pixel:=pixels[(sy*width+sx)*4:][:4]
                    sum+={int(pixel[0]),int(pixel[1]),int(pixel[2]),int(pixel[3])}
                }
            }
            area:=(y1-y0)*(x1-x0)
            out:=scaled[(y*w+x)*4:][:4]
            for c in 0..<4 {out[c]=u8((sum[c]+area/2)/area)}
        }
    }
    return scaled,true
}

// The game of a run drawn now in pixels of the allocator of the application: off the screen
// through its camera, with the interfaces of the game and nothing of the editor; with window, the
// Play of the user as the next frames of the window. wait: as app_capture_world, off the screen.
@(private)
api_play_pixels :: proc(s:^Session,r:^Run,frames:int,window:=false,wait:=time.Duration(0),debug:[]gpu.Debug_Lines=nil) -> (pixels:[]u8,width,height:int,drawn:bool) {
    if r.owner==0 && window {
        before:=s.app.stats.frames_drawn
        api_frames(s,frames,0)
        if s.app.stats.frames_drawn!=before {pixels,width,height,drawn=host.app_capture_pixels(s.app,s.app.allocator)}
        return
    }
    input:=s.app.ui_input
    s.app.ui_input=run_ui_input(r,input)
    pixels,width,height,drawn=host.app_capture_world(s.app,r.world,frames,allocator=s.app.allocator,wait=wait,debug=debug)
    s.app.ui_input=input
    s.view_cut=true
    return
}

// Writes pixels of the allocator of the application as a PNG on a job; with a
// window the editor goes on drawing frames meanwhile, so it does not stop for
// the compression. A manual editor waits without advancing. Why path could
// not be written, "" when it was; path outlives the frames drawn.
@(private)
api_png_write :: proc(s:^Session,path:string,pixels:[]u8,width,height:int) -> (problem:string) {
    w:host.Png_Write
    host.app_png_write_start(s.app,&w,path,pixels,width,height)
    error:os.Error
    if st:=api_state(s);st==nil || st.manual {
        error=host.app_png_write_wait(s.app,&w)
    } else {
        for {
            finished:bool
            if finished,error=host.app_png_write_poll(s.app,&w);finished {break}
            if api_frames(s,1,0)==0 {error=host.app_png_write_wait(s.app,&w);break}
        }
    }
    if error!=nil {return fmt.tprintf("%s could not be written: %s",path,os.error_string(error))}
    return ""
}

@(private)
ai_snapshot_name_valid :: proc "contextless" (request:string) -> bool {
    split:=-1
    for byte,index in request {
        if byte=='-' && split<0 {split=index;continue}
        if byte<'0' || byte>'9' {return false}
    }
    return split>0 && split<len(request)-1 && request[0]!='0'
}

@(private)
api_view_viewport :: proc(s:^Session,call:^api.Call) {
    request:=base.text_get(api.call_params(call,Api_Viewport_Params).request[:])
    if request=="" {
        task:=ai_task_named(s.ai,call.client_tag)
        if task==nil {api.call_fail(call,api.INVALID_PARAMS,"view.viewport shows the message of a turn: outside one give request, the folder of its snapshot under .mirai/ai");return}
        request=base.text_get(task.name[:])
    }
    if !ai_snapshot_name_valid(request) {api.call_fail(call,api.INVALID_PARAMS,"request must identify a saved message snapshot");return}
    if s.project_root=="" {api.call_fail(call,api.SERVER_ERROR,"The editor has no project folder");return}
    for &task in ai_tasks(s.ai) {
        if base.text_get(task.name[:])==request {host.app_png_write_wait(s.app,&task.image_write)}
    }
    path:=project.path(s.project_root,fmt.tprintf(".mirai/ai/%s/%s",request,AI_FILE_IMAGE),allocator=context.temp_allocator)
    if !os.is_file(path) {api.call_fail(call,api.SERVER_ERROR,"The viewport snapshot for this message is unavailable");return}
    api.call_result(call,Api_Viewport_Result).path=path
    api.call_image(call,path)
}
