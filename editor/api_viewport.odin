package editor

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

Api_Viewport_Params :: struct {
    request:[64]u8 `mirai:"text,label=Message snapshot identifier provided in the editor prompt"`,
}

@(private)
API_VIEWPORT_RESULT :: `{"type":"object","properties":{"content":{"type":"array","items":{"type":"object","properties":{"type":{"const":"image"},"data":{"type":"string"},"mimeType":{"const":"image/png"}},"required":["type","data","mimeType"],"additionalProperties":false}},"isError":{"const":false}},"required":["content","isError"],"additionalProperties":false}`

Api_Play_Capture_Params :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"optional,text,label=PNG file to write; one under .mirai/captures when empty"`,
    frames:int `mirai:"optional,min=1,max=120,label=Frames drawn first so that what builds up over time settles"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
    every:int `mirai:"optional,min=0,max=3600,label=Filmstrip: the ticks the game runs between two cells of one image; 0: an image of now"`,
    count:int `mirai:"optional,min=0,max=64,label=Filmstrip: its cells; the first shows the game before the first tick"`,
    columns:int `mirai:"optional,min=0,max=64,label=Filmstrip: cells across; 0: as square as they fit"`,
    segments:[API_STEP_SEGMENTS]Api_Play_Segment `mirai:"optional,label=Filmstrip: the input along its ticks as play.step takes it; after them nothing is held"`,
    follow:[64]u8 `mirai:"optional,text,label=Filmstrip: every cell is centered on where this entity shows; by its name (the first in the order of play.inspect)"`,
    follow_id:base.Entity_Id `mirai:"optional,label=Filmstrip: the entity to follow by its id in the scene"`,
    follow_entity:[16]u8 `mirai:"optional,text,label=Filmstrip: the entity to follow by its handle as play.inspect gives it"`,
    size:[2]f32 `mirai:"optional,min=8,max=4096,label=Filmstrip that follows an entity: width and height of a cell in points of the image"`,
    region:[4]f32 `mirai:"optional,label=Filmstrip: x y width height in points of the image that every cell shows in place of following an entity; none: the whole image"`,
    ui:bool `mirai:"optional,label=The Play of the user: the whole window with the editor around the game, as the user sees it; false: the game alone through its camera, with its own interfaces"`,
}

@(private)
API_PLAY_CAPTURE_RESULT :: `{"type":"object","properties":{"content":{"type":"array","items":{"type":"object","properties":{"type":{"enum":["image","text"]},"data":{"type":"string"},"mimeType":{"const":"image/png"},"text":{"type":"string","description":"a filmstrip: structuredContent as JSON"}},"required":["type"],"additionalProperties":false}},"structuredContent":{"type":"object","description":"a filmstrip","properties":{"path":{"type":"string"},"width":{"type":"integer"},"height":{"type":"integer"},"columns":{"type":"integer"},"rows":{"type":"integer"},"cell":{"type":"array","items":{"type":"integer"},"description":"pixels of a cell"},"cells":{"type":"array","description":"from the top left row by row","items":{"type":"object","properties":{"tick":{"type":"integer","description":"the tick of the game it shows"},"at":{"type":["array","null"],"items":{"type":"number"},"description":"following an entity: where it shows in points of the image; null when it is behind the camera or gone"}},"required":["tick"],"additionalProperties":false}}},"required":["path","width","height","columns","rows","cell","cells"],"additionalProperties":false},"isError":{"const":false}},"required":["content","isError"],"additionalProperties":false}`

@(private)
api_viewport_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="view.viewport",summary="see what the user was looking at when sent this message",params=Api_Viewport_Params,result_schema=API_VIEWPORT_RESULT,flags={.Core,.Read_Only,.Idempotent},mcp_content=true,run=api_view_viewport})
    capture_default:=Api_Play_Capture_Params{frames=8,size={256,256}}
    api_register(s,st,{name="play.capture",summary="see the game of the caller as its camera shows it, alone with its own interfaces: the run of its turn, or the Play of the user outside a turn, drawn without showing it on the user's screen (ui shows the editor's window around the Play of the user instead). Also writes the PNG. With every and count it steps the game and writes one filmstrip of cells around an entity or a region with the tick of each.",params=Api_Play_Capture_Params,result_schema=API_PLAY_CAPTURE_RESULT,defaults=&capture_default,flags={.Core,.Read_Only},mcp_content=true,run=api_play_capture})
}

// The game of the caller as an image, drawn off the screen through its camera with its own
// interfaces; with ui, the Play of the user is the next frames of the window, editor and all.
@(private)
api_play_capture :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Capture_Params)
    r,own:=api_play_run(s,call,p.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,"No game is playing; play.start first");return}
    strip,ok:=api_filmstrip_read(s,call,r,own,p)
    if !ok {return}
    if s.app==nil || s.app.renderer==nil {api.call_fail(call,api.SERVER_ERROR,"play.capture requires a GPU; start without --no-gpu");return}
    if !api_rays_ready(s,call,"play.capture") {return}
    path:=base.text_get(p.path[:])
    if path=="" {
        if s.project_root=="" {api.call_fail(call,api.INVALID_PARAMS,"path is required without a project");return}
        path=fmt.tprintf(".mirai/captures/play-%d%s.png",r.owner,strip!=nil?"-strip":"")
    }
    // As editor.capture: relative to the project, its folder made. The frames drawn below free the temporary memory.
    writable:bool
    if path,writable=api_output_file(s,call,path,s.app.allocator);!writable {return}
    defer delete(path,s.app.allocator)
    if strip!=nil {api_filmstrip_run(s,call,strip,path);return}
    pixels,width,height,drawn:=api_play_pixels(s,r,p.frames,p.ui)
    if !drawn {api.call_fail(call,api.SERVER_ERROR,"The game could not be drawn");return}
    if !api_png_write(s,path,pixels,width,height) {api.call_fail(call,api.SERVER_ERROR,"The capture could not be written");return}
    api_png_content(call,path)
}

// The game of a run drawn now in pixels of the allocator of the application: off the screen
// through its camera, with the interfaces of the game and nothing of the editor; with window, the
// Play of the user as the next frames of the window.
@(private)
api_play_pixels :: proc(s:^Session,r:^Run,frames:int,window:=false) -> (pixels:[]u8,width,height:int,drawn:bool) {
    if r.owner==0 && window {
        before:=s.app.stats.frames_drawn
        api_frames(s,frames,0)
        if s.app.stats.frames_drawn!=before {pixels,width,height,drawn=host.app_capture_pixels(s.app,s.app.allocator)}
        return
    }
    input:=s.app.ui_input
    s.app.ui_input=run_ui_input(r,input)
    pixels,width,height,drawn=host.app_capture_world(s.app,r.world,frames,allocator=s.app.allocator)
    s.app.ui_input=input
    s.view_cut=true
    return
}

// Writes pixels of the allocator of the application as a PNG on a job; with a
// window the editor goes on drawing frames meanwhile, so it does not stop for
// the compression. A manual editor waits without advancing.
@(private)
api_png_write :: proc(s:^Session,path:string,pixels:[]u8,width,height:int) -> bool {
    w:host.Png_Write
    host.app_png_write_start(s.app,&w,path,pixels,width,height)
    if st:=api_state(s);st==nil || st.manual {return host.app_png_write_wait(s.app,&w)}
    for {
        if finished,written:=host.app_png_write_poll(s.app,&w);finished {return written}
        if api_frames(s,1,0)==0 {return host.app_png_write_wait(s.app,&w)}
    }
}

// A PNG file as the image content of an MCP tool; structured, JSON of what it
// shows, goes before it as text and as the structured content.
@(private)
api_png_content :: proc(call:^api.Call,path:string,structured:="") {
    file,open_error:=os.open(path)
    if open_error!=nil {api.call_fail(call,api.SERVER_ERROR,"The image is unavailable");return}
    defer os.close(file)
    size,size_error:=os.file_size(file)
    if size_error!=nil || size<=0 {api.call_fail(call,api.SERVER_ERROR,"The image could not be read");return}
    if size>i64(max(call.server.max_response-512-len(structured)*3,0)/4*3) {
        api.call_failf(call,api.SERVER_ERROR,"The image of %d bytes exceeds the MCP response limit; it is written at %s",size,path)
        return
    }
    image,read_error:=os.read_entire_file(file,context.allocator)
    if read_error!=nil {api.call_fail(call,api.SERVER_ERROR,"The image could not be read");return}
    defer delete(image)
    encoded,encode_error:=base64.encode(image,allocator=context.allocator)
    if encode_error!=.None {api.call_fail(call,api.INTERNAL_ERROR,"The image could not be encoded");return}
    defer delete(encoded)
    serial.text_write_raw(call.out,`{"content":[`)
    if structured!="" {
        serial.text_write_raw(call.out,`{"type":"text","text":`)
        serial.text_write_string(call.out,structured)
        serial.text_write_raw(call.out,`},`)
    }
    serial.text_write_raw(call.out,`{"type":"image","data":"`)
    serial.text_write_raw(call.out,encoded)
    serial.text_write_raw(call.out,`","mimeType":"image/png"}]`)
    if structured!="" {serial.text_write_raw(call.out,`,"structuredContent":`);serial.text_write_raw(call.out,structured)}
    serial.text_write_raw(call.out,`,"isError":false}`)
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
    if !ai_snapshot_name_valid(request) {api.call_fail(call,api.INVALID_PARAMS,"request must identify a saved message snapshot");return}
    if s.project_root=="" {api.call_fail(call,api.SERVER_ERROR,"The editor has no project folder");return}
    if s.ai!=nil {
        for &task in s.ai.tasks[:s.ai.task_count] {
            if base.text_get(task.name[:])==request {host.app_png_write_wait(s.app,&task.image_write)}
        }
    }
    path:=project.path(s.project_root,fmt.tprintf(".mirai/ai/%s/%s",request,AI_FILE_IMAGE),allocator=context.temp_allocator)
    if !os.is_file(path) {api.call_fail(call,api.SERVER_ERROR,"The viewport snapshot for this message is unavailable");return}
    api_png_content(call,path)
}
