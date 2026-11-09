package host

import "core:math/linalg"
import "mirai:core"
import "mirai:platform"
import render "mirai:render"
import "mirai:std/base"
import "mirai:std/math"
import "mirai:ui"

// Between ui and render, which do not know each other: the input of the
// platform becomes a ui.Input, and the draw list of a ui frame becomes a
// screen layer and world panels of the renderer. Whoever owns a context does it for its
// own UI; whoever owns another context uses the same procedures.

// The two vertices are one layout: a draw list is handed over without a copy.
#assert(size_of(ui.Vertex)==size_of(render.Ui_Vertex))
#assert(offset_of(ui.Vertex,position)==offset_of(render.Ui_Vertex,position))
#assert(offset_of(ui.Vertex,color)==offset_of(render.Ui_Vertex,color))
#assert(offset_of(ui.Vertex,quad)==offset_of(render.Ui_Vertex,material))
#assert(offset_of(ui.Vertex,uv)==offset_of(render.Ui_Vertex,uv))
#assert(size_of(ui.Shape)==size_of(render.Ui_Shape))
#assert(offset_of(ui.Shape,bounds)==offset_of(render.Ui_Shape,bounds))
#assert(offset_of(ui.Shape,radii)==offset_of(render.Ui_Shape,radii))
#assert(offset_of(ui.Shape,fill)==offset_of(render.Ui_Shape,fill))
#assert(offset_of(ui.Shape,fill2)==offset_of(render.Ui_Shape,fill2))
#assert(offset_of(ui.Shape,stroke)==offset_of(render.Ui_Shape,stroke))
#assert(offset_of(ui.Shape,params)==offset_of(render.Ui_Shape,params))
#assert(size_of(ui.Layer)==size_of(render.Ui_Effect))
#assert(offset_of(ui.Layer,bounds)==offset_of(render.Ui_Effect,bounds))
#assert(offset_of(ui.Layer,radius)==offset_of(render.Ui_Effect,radius))
#assert(offset_of(ui.Layer,opacity)==offset_of(render.Ui_Effect,opacity))
#assert(offset_of(ui.Layer,backdrop_blur)==offset_of(render.Ui_Effect,backdrop_blur))

UI_COMMAND_CAPACITY :: 256

// Quad kinds of the host for what the renderer draws besides colors, glyphs
// and images: the asset thumbnails, and the studio preview of a row of the
// material table (the row in the data).
UI_QUAD_THUMBNAIL :: ui.Quad_Kind(16)
UI_QUAD_MATERIAL_PREVIEW :: ui.Quad_Kind(17)
#assert(u8(ui.Quad_Kind.User)==16)

// The desc every UI context of the application starts from: its allocator,
// the density of its window and the font of the application, which the first
// context creates and all of them borrow. The renderer holds its atlas once.
app_ui_context_desc :: proc(app:^App) -> ui.Context_Desc {
    app_ui_font_ready(app)
    return {
        allocator=app.allocator,density=app.density,font_sizes=app.ui_font_sizes,
        font=&app.ui_font if app.ui_font.ready else nil,font_ask=ui_font_ask,font_user=app,
        max_commands=UI_COMMAND_CAPACITY,no_font=app.renderer==nil,
        clipboard_get=ui_clipboard_get,clipboard_set=ui_clipboard_set,clipboard_user=app,
    }
}

// Creates the font of the application the first time, with a renderer to draw it.
app_ui_font_ready :: proc(app:^App) -> bool {
    if app.renderer!=nil && !app.ui_font.ready {
        _=ui.font_init(&app.ui_font,nil,app.ui_font_sizes,app.density,app.allocator,on_demand=true)
    }
    return app.ui_font.ready
}

// The system clipboard of the window, for the text and number fields of every
// context of the application.
@(private)
ui_clipboard_get :: proc(user:rawptr,buffer:[]u8) -> int {
    app:=(^App)(user)
    if app==nil || app.platform==nil {return 0}
    text,ok:=platform.clipboard_get(app.platform,context.temp_allocator)
    if !ok {return 0}
    return copy(buffer,text)
}
@(private)
ui_clipboard_set :: proc(user:rawptr,text:string) {
    app:=(^App)(user)
    if app==nil || app.platform==nil {return}
    _=platform.clipboard_set(app.platform,text)
}

// A context asks for glyphs while it draws: they are drawn in the same frame
// when the atlas has room; it grows after the frame.
@(private)
ui_font_ask :: proc(user:rawptr) {
    app:=(^App)(user)
    if app!=nil {ui.font_update(&app.ui_font,grow=false)}
}

// After the frame of a context that borrows the font of the application:
// rasterizes the glyphs it asked for and uploads the atlas when the renderer
// does not hold it yet. A transaction, between frames.
app_ui_font_sync :: proc(app:^App,ctx:^ui.Context) -> bool {
    font:=&app.ui_font
    if app.renderer==nil || !font.ready {return false}
    zone:=profile_part(app,"ui font")
    defer base.profile_end(zone)
    ui.font_update(font)
    key:=Font_Key{font.revision,true}
    if key==app.font {return true}
    // The renderer writes only the texels that changed; a new size takes them all.
    if dirty:=font.dirty;dirty[2]>dirty[0] && dirty[3]>dirty[1] {
        changed:=[4]u32{u32(dirty[0]),u32(dirty[1]),u32(dirty[2]-dirty[0]),u32(dirty[3]-dirty[1])}
        if !render.renderer_set_font(app.renderer,font.pixels,font.width,font.height,{changed.x,changed.y,changed.z,changed.w}) {return false}
        font.dirty={}
    }
    app.font=key
    return true
}

// What the renderer's Ui_Vertex.material is for a quad of ui.
ui_material :: proc "contextless" (quad:u32) -> u32 {
    data:=ui.quad_data(quad)
    #partial switch ui.quad_kind(quad) {
    case .Glyph:                   return 1
    case .Image:                   return render.UI_MATERIAL_IMAGE_BIT|data
    case .Shape:                   return render.UI_MATERIAL_SHAPE_BIT|data
    case .Program:                 return render.UI_MATERIAL_PROGRAM_BIT|data
    case UI_QUAD_THUMBNAIL:        return render.UI_MATERIAL_THUMBNAIL
    case UI_QUAD_MATERIAL_PREVIEW: return render.UI_MATERIAL_PREVIEW_BIT|data
    }
    return 0
}

// The commands of a world panel drawn into a texture (ui.World_Panel.offscreen):
// what the owner of the context draws there instead of in the scene, as the
// layer of a render.Ui_Texture_Draw, isolated layers included.
Ui_Offscreen :: struct {
    id:ui.Id,
    layer:render.Ui_Layer, // in layout units of the panel
    size:[2]f32,           // of the panel, in layout units
}

// What ui_frame_split made of a frame.
Ui_Converted :: struct {
    layer:render.Ui_Layer,
    draw_count,panel_count,offscreen_count:int,
    dropped:int, // commands that did not fit, or of a layer that was not closed
}

// Turns a frame of ui into what the renderer draws, in place: the vertices
// of the frame get their material, the commands of the screen go to draws as
// one layer and the commands of each visible world panel become panels, those
// of an offscreen panel offscreen runs, whose draws go to offscreen_draws.
// Consecutive commands of one panel are one, those of a panel in the scene
// when their vertices follow each other. view: the view of the window the
// panels are seen in (render.World_Panel.view). Convert a frame once; the
// result lasts as long as the frame. Commands that do not fit are left out
// and counted.
ui_frame_split :: proc(frame:ui.Frame,draws:[]render.Ui_Draw,panels:[]render.World_Panel,offscreen:[]Ui_Offscreen,offscreen_draws:[]render.Ui_Draw,view:u8=0) -> (out:Ui_Converted) {
    for &vertex in frame.vertices {vertex.quad=ui_material(vertex.quad)}
    vertices:=(cast([^]render.Ui_Vertex)raw_data(frame.vertices))[:len(frame.vertices)]
    shapes:=(cast([^]render.Ui_Shape)raw_data(frame.shapes))[:len(frame.shapes)]
    effects:=(cast([^]render.Ui_Effect)raw_data(frame.layers))[:len(frame.layers)]
    depth,skipped:=0,0
    Layer_Entry :: struct {start:int,id:u16}
    stack:[render.UI_LAYER_DEPTH_CAPACITY]Layer_Entry
    // The run the last command of a panel went to: one that follows it joins it.
    last_surface,last_first,last_end:=u32(0),u32(0),u32(0)
    run_start,run_end:=0,0 // of the draws of the last offscreen run in offscreen_draws
    for command in frame.commands {
        if command.count==0 && command.kind==.Triangles {continue}
        if command.surface==0 {
            last_surface=0
            if skipped>0 {
                if command.kind==.Begin_Layer {skipped+=1}
                if command.kind==.End_Layer {skipped-=1}
                out.dropped+=1
                continue
            }
            switch command.kind {
            case .Begin_Layer:
                if depth==len(stack) || out.draw_count+depth+2>len(draws) || int(command.layer)>=len(effects) {skipped=1;out.dropped+=1;continue}
                stack[depth]={out.draw_count,command.layer}
                depth+=1
            case .End_Layer:
                if depth==0 || stack[depth-1].id!=command.layer {out.dropped+=1;continue}
                depth-=1
            case .Triangles:
                if out.draw_count+depth>=len(draws) {out.dropped+=1;continue}
            }
            draws[out.draw_count]={first=command.first,count=command.count,scissor={command.scissor.x,command.scissor.y,command.scissor.w,command.scissor.h},kind=render.Ui_Draw_Kind(command.kind),layer=command.layer}
            out.draw_count+=1
            continue
        }
        if int(command.surface)>len(frame.placements) {out.dropped+=1;last_surface=0;continue}
        placement:=frame.placements[command.surface-1]
        if placement.offscreen {
            if command.surface!=last_surface {
                if out.offscreen_count>=len(offscreen) {out.dropped+=1;last_surface=0;continue}
                run_start=run_end
                offscreen[out.offscreen_count]={id=placement.id,size=placement.size,layer={vertices=vertices,shapes=shapes,effects=effects}}
                out.offscreen_count+=1
                last_surface=command.surface
            }
            if run_end>=len(offscreen_draws) {out.dropped+=1;continue}
            offscreen_draws[run_end]={first=command.first,count=command.count,scissor={command.scissor.x,command.scissor.y,command.scissor.w,command.scissor.h},kind=render.Ui_Draw_Kind(command.kind),layer=command.layer}
            run_end+=1
            offscreen[out.offscreen_count-1].layer.draws=offscreen_draws[run_start:run_end]
            continue
        }
        if command.kind!=.Triangles {out.dropped+=1;last_surface=0;continue}
        if !placement.visible {last_surface=0;continue}
        joined:=command.surface==last_surface && command.first==last_end
        run:=vertices[command.first:][:command.count]
        if joined {run=vertices[last_first:][:command.first+command.count-last_first]}
        last_end=command.first+command.count
        if joined {panels[out.panel_count-1].vertices=run;continue}
        if out.panel_count>=len(panels) {out.dropped+=1;last_surface=0;continue}
        m:=placement.transform
        panels[out.panel_count]={
            vertices=run,shapes=shapes,
            origin=placement.position,right={m[0,0],m[1,0],m[2,0]},down={m[0,1],m[1,1],m[2,1]},pivot=placement.pivot,
            billboard=placement.billboard,depth_test=placement.depth_test,view=view,
        }
        out.panel_count+=1
        last_surface,last_first=command.surface,command.first
    }
    if depth>0 {out.dropped+=out.draw_count-stack[0].start;out.draw_count=stack[0].start}
    if out.draw_count==0 {vertices=nil}
    out.layer={vertices=vertices,draws=draws[:out.draw_count],shapes=shapes,effects=effects}
    return
}

// ui_frame_split of a context without offscreen panels, seen in every view.
ui_frame_convert :: proc(frame:ui.Frame,draws:[]render.Ui_Draw,panels:[]render.World_Panel) -> (layer:render.Ui_Layer,draw_count,panel_count,dropped:int) {
    out:=ui_frame_split(frame,draws,panels,nil,nil)
    return out.layer,out.draw_count,out.panel_count,out.dropped
}

@(private)
UI_KEYS :: [ui.Key]platform.Key{
    .Left=.Left,.Right=.Right,.Up=.Up,.Down=.Down,.Home=.Home,.End=.End,.Page_Up=.Page_Up,.Page_Down=.Page_Down,
    .Backspace=.Backspace,.Delete=.Delete,.Enter=.Enter,.Escape=.Escape,.Tab=.Tab,.Space=.Space,.A=.A,.C=.C,.V=.V,.X=.X,
}

// The input of a tick as the frame of a window that held it, for what reads the
// UI of a game without a window: a script of the player or a step of the API.
input_frame_of :: proc "contextless" (given:core.Input) -> (frame:platform.Input_Frame) {
    frame.keys_down,frame.keys_pressed,frame.keys_released=given.keys_down,given.keys_pressed,given.keys_released
    frame.keys_repeated=given.keys_pressed
    frame.mouse_down,frame.mouse_pressed,frame.mouse_released=given.mouse_down,given.mouse_pressed,given.mouse_released
    if .Left in given.mouse_pressed {frame.mouse_clicks[.Left]=1}
    frame.mouse_position,frame.mouse_inside,frame.wheel=given.mouse_position,true,given.wheel
    frame.gamepads=given.gamepads
    return
}

// The input of a drawn frame as a UI surface that covers the window sees it.
// The first gamepad navigates: d-pad, South accepts, East cancels and the
// shoulders go to the next and previous widget.
ui_input_from_platform :: proc "contextless" (frame:^platform.Input_Frame) -> (input:ui.Input) {
    input.size={f32(frame.window.size.x),f32(frame.window.size.y)}
    input.dt=frame.dt
    input.pointer=frame.mouse_position
    input.pointer_absent=!frame.mouse_inside
    buttons:=[ui.Mouse_Button]platform.Mouse_Button{.Left=.Left,.Right=.Right,.Middle=.Middle,.Back=.X1}
    for button,target in buttons {
        if button in frame.mouse_down {input.down+={target}}
        if button in frame.mouse_pressed {input.pressed+={target}}
        if button in frame.mouse_released {input.released+={target}}
    }
    input.clicks=frame.mouse_clicks[.Left]
    input.wheel=frame.wheel
    keys:=UI_KEYS
    for key,target in keys {
        if key in frame.keys_down {input.keys_down+={target}}
        if key in frame.keys_pressed {input.keys_pressed+={target}}
        if key in frame.keys_repeated {input.keys_repeated+={target}}
    }
    held:=frame.keys_down
    if .Left_Shift in held || .Right_Shift in held {input.modifiers+={.Shift}}
    if .Left_Alt in held || .Right_Alt in held {input.modifiers+={.Alt}}
    when ODIN_OS==.Darwin {
        if .Left_Super in held || .Right_Super in held {input.modifiers+={.Primary}}
    } else {
        if .Left_Control in held || .Right_Control in held {input.modifiers+={.Primary}}
    }
    for character in frame.text[:frame.text_count] {ui.input_text(&input,character)}
    input.pad=ui_pad_buttons(frame.gamepads[0].pressed)
    g:=&frame.gamepads[0]
    input.scroll,input.aim=ui_stick(g.axes[.Right_X],g.axes[.Right_Y]),ui_stick(g.axes[.Left_X],g.axes[.Left_Y])
    return
}

UI_STICK_DEAD :: f32(0.2) // of the travel of a stick that the UI ignores

// A stick as ui.Input takes it: nothing inside the dead zone, and from 0
// there to 1 all the way over.
ui_stick :: proc "contextless" (x,y:f32) -> [2]f32 {
    length:=linalg.length([2]f32{x,y})
    if length<=UI_STICK_DEAD {return {}}
    return [2]f32{x,y}*(min((length-UI_STICK_DEAD)/(1-UI_STICK_DEAD),1)/length)
}


// The navigation the buttons of a gamepad give: the d-pad, South accepts,
// East cancels and the shoulders go to the next and the previous widget.
ui_pad_buttons :: proc "contextless" (buttons:platform.Gamepad_Buttons) -> (pads:ui.Pads) {
    PADS :: [?]struct {button:platform.Gamepad_Button,pad:ui.Pad}{
        {.Dpad_Up,.Up},{.Dpad_Down,.Down},{.Dpad_Left,.Left},{.Dpad_Right,.Right},
        {.South,.Accept},{.East,.Cancel},{.Right_Shoulder,.Next},{.Left_Shoulder,.Previous},
    }
    for entry in PADS {
        if entry.button in buttons {pads+={entry.pad}}
    }
    return
}

// Gives the input the camera world panels are placed for, in the part of the
// window rect (points; zero: all of it), and the ray world panels take: from
// the camera through the pointer while it is over that part, or through the
// center of the view with aim (a captured mouse, a gamepad).
ui_input_camera :: proc "contextless" (input:^ui.Input,camera:render.Camera,rect:[4]f32={},aim:=false) {
    input.ray={}
    size:=input.size
    pointer:=input.pointer
    if rect.z>0 && rect.w>0 {size=rect.zw;pointer-=rect.xy}
    forward:=camera.forward
    if linalg.length(forward)<1e-6 || size.x<=0 || size.y<=0 {return}
    fov:=camera.fov_y*math.RAD_PER_DEG
    input.view={
        position=camera.position,rotation=math.quat_look(linalg.normalize(forward),camera.up),
        fov_y=fov,viewport_height=size.y,
    }
    if aim {pointer=size*0.5} else if input.pointer_absent || pointer.x<0 || pointer.y<0 || pointer.x>=size.x || pointer.y>=size.y {return}
    // From the eye, and then where the eye is: far from the centre of the world a matrix with the place would round it.
    view:=math.look_at({},forward,camera.up)
    projection:=math.perspective(fov,size.x/size.y,max(camera.near,1e-3),max(camera.far,1))
    ray:=math.screen_ray(pointer,size,view,projection)
    input.ray={origin=camera.position+ray.origin,direction=ray.direction,valid=true}
}
