package editor

import "core:math"
import "core:math/linalg"
import "core:strings"
import "mirai:asset"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// The editor's own assets, in the engine: the registry of every project
// mounts them under a prefix with a dot, which lists of the project leave out.
EDITOR_ASSETS :: "editor/assets"
EDITOR_ASSETS_PREFIX :: ".editor"

// Who works on the document stands in the scene as a pup with their color.
PRESENCE_MESH :: EDITOR_ASSETS_PREFIX+"/presence/pup.mesh"
PRESENCE_COLOR_SLOTS :: [4]u8{1,2,3,5}
PRESENCE_STARS_SLOT :: u8(5)
PRESENCE_OWNER :: u64(0x70726573656e6365)
PRESENCE_GLYPH :: f32(30)
PRESENCE_NAME :: f32(11)

// One color for each agent and each other editor of a session, from level
// AGENT_LEVEL of the outlines on.
AGENT_COLORS :: [8]ui.Color{{121,203,178,255},{182,160,237,255},{229,181,120,255},{129,185,233,255},{236,149,177,255},{194,207,122,255},{244,140,122,255},{112,206,222,255}}
AGENT_LEVEL :: u8(5)
// What a turn only looked at, after the levels of the colors.
AI_CONTEXT_LEVEL :: AGENT_LEVEL+u8(len(AGENT_COLORS))

// The figures stand in the scene while it is edited or simulated; a game,
// played, paused or watched, is seen alone.
presence_in_scene :: proc "contextless" (s:^Session) -> bool {return !play_shown(s) && s.mode!=.Watch}

agent_color :: proc "contextless" (index:int) -> ui.Color {colors:=AGENT_COLORS;return colors[index%len(colors)]}
agent_level :: proc "contextless" (index:int) -> u8 {return AGENT_LEVEL+u8(index%len(AGENT_COLORS))}

@(private)
Presence_Key :: struct {
    eyes:[3]f32,
    yaw:f32,
    color:ui.Color,
    level:u8,
    variant:u64,
    assets,appearance:u64,
}

// The instance of a figure, made again only when where it is, its color or
// the assets change.
@(private)
Presence :: struct {
    key:Presence_Key,
    instance:gpu.Instance_Desc,
    ready:bool,
    at:[3]f32,   // where it is shown: it follows where it is said to be,
    facing:f32,  // which arrives a few times a second, instead of jumping
    placed:bool,
}

// How fast a figure reaches where it is said to be: the share left after a
// second is e^-PRESENCE_FOLLOW. Farther than PRESENCE_SNAP meters it jumps.
PRESENCE_FOLLOW :: f32(12)
PRESENCE_SNAP :: f32(25)

// The figure a step closer to where it is said to be, for a frame of dt seconds.
@(private)
presence_follow :: proc(figure:^Presence,eyes:[3]f32,yaw,dt:f32) {
    if !figure.placed || linalg.length(eyes-figure.at)>PRESENCE_SNAP || dt<=0 {
        figure.at,figure.facing,figure.placed=eyes,yaw,true
        return
    }
    k:=1-math.exp(-dt*PRESENCE_FOLLOW)
    figure.at+=(eyes-figure.at)*k
    turn:=math.mod(yaw-figure.facing+3*math.PI,2*math.PI)-math.PI
    figure.facing+=turn*k
    if linalg.length(eyes-figure.at)<1e-4 && abs(turn)<1e-4 {figure.at,figure.facing=eyes,yaw}
}

// Where a figure is shown, or where it is said to be before it was.
@(private)
presence_shown :: proc(figure:^Presence,eyes:[3]f32) -> [3]f32 {return figure.at if figure.placed else eyes}

// The pup, with its bounds about the eyes; false while it is not loaded.
@(private)
presence_mesh :: proc(a:^host.Assets) -> (id:base.Asset_Id,low,high:[3]f32,ok:bool) {
    if a==nil {return}
    file,found:=asset.registry_find_path(&a.registry,PRESENCE_MESH)
    if !found {return}
    mesh:=host.assets_mesh(a,file.id)
    if mesh==nil || mesh.failed || mesh.handle==host.ASSETS_MESH_NONE {return}
    return file.id,mesh.bounds_min,mesh.bounds_max,true
}

// The figure with its eyes at `eyes`, turned by `yaw` about +Y from -Z.
@(private)
presence_prepare :: proc(s:^Session,figure:^Presence,eyes:[3]f32,yaw:f32,color:ui.Color,level:u8,variant:u64) -> bool {
    a:=s.app.assets
    if a==nil {return false}
    presence_follow(figure,eyes,yaw,s.viewport.dt)
    eyes,yaw:=figure.at,figure.facing
    key:=Presence_Key{eyes,yaw,color,level,variant,a.revision+a.structure,a.appearance}
    if figure.ready && figure.key==key {return true}
    figure.ready=false
    id,_,_,loaded:=presence_mesh(a)
    if !loaded {return false}
    linear:=mm.srgb_to_linear([3]f32{f32(color[0])/255,f32(color[1])/255,f32(color[2])/255})
    accent:=erender.MATERIAL_VALUES_DEFAULT
    for slot in PRESENCE_COLOR_SLOTS {erender.material_value(&accent,"base_color",{linear.x,linear.y,linear.z,1},int(slot))}
    erender.material_value(&accent,"emission",{linear.x,linear.y,linear.z,1},int(PRESENCE_STARS_SLOT))
    place:=mm.Transform{position=eyes,rotation=mm.quat_axis_angle({0,1,0},yaw),scale=1}
    instance,ok:=erender.mesh_instance(a,{mesh=id},mm.transform_matrix(place),accent)
    if !ok {return false}
    instance.copy_owner,instance.copy_variant=PRESENCE_OWNER,variant
    instance.highlight=level
    figure.key=key
    figure.instance=instance
    figure.ready=true
    return true
}

// The turn about +Y that faces -Z along `forward`.
@(private)
presence_yaw :: proc "contextless" (forward:[3]f32) -> f32 {
    if forward.x==0 && forward.z==0 {return 0}
    return mm.yaw_of_direction(forward)
}

// The outline colors of the agents and of the soft one of what a turn read.
@(private)
presence_style :: proc(s:^Session) {
    renderer:=s.app.renderer
    if renderer==nil {return}
    style:=renderer.highlight
    for color,index in AGENT_COLORS {
        style.colors[int(AGENT_LEVEL)+index-1]={f32(color[0])/255,f32(color[1])/255,f32(color[2])/255,1}
        style.fill[int(AGENT_LEVEL)+index-1]=0
    }
    // What a turn only read is outlined softly; what it changed keeps the
    // color of its agent, so one is told from the other at a glance.
    style.colors[AI_CONTEXT_LEVEL-1]={0.62,0.65,0.74,0.45}
    style.fill[AI_CONTEXT_LEVEL-1]=0
    if style!=renderer.highlight {gpu.renderer_set_highlight_style(renderer,style)}
}

// Over the head at `top`: where the glyph of who a figure stands for goes,
// with its name under it. False when the head is behind the camera or out of
// the part of the viewport the panels leave free.
@(private)
presence_glyph_rect :: proc(s:^Session,top:[3]f32,projection:mm.Mat4) -> (rect:ui.Rect,ok:bool) {
    screen,_,front:=mm.world_to_screen(top,s.viewport.size,projection)
    if !front {return}
    screen+=s.viewport.origin
    free:=free_region(s.gui,s.viewport.window)
    half:=PRESENCE_GLYPH*0.5
    rect={screen.x-half,screen.y-PRESENCE_NAME*2-PRESENCE_GLYPH-4,PRESENCE_GLYPH,PRESENCE_GLYPH}
    if screen.x<free.x+half || screen.x>free.x+free.w-half || rect.y<free.y || screen.y>free.y+free.h {return}
    return rect,true
}

// The name under the glyph, on a plate of its color.
@(private)
presence_name_draw :: proc(s:^Session,glyph:ui.Rect,name:string,color:ui.Color) {
    if name=="" {return}
    ctx:=s.gui.ctx
    width:=ui.text_width(&ctx.font,name,PRESENCE_NAME,ui.FONT_SEMIBOLD)
    plate:=ui.Rect{glyph.x+glyph.w*0.5-width*0.5-7,glyph.y+glyph.h+3,width+14,PRESENCE_NAME+7}
    ui.draw_rounded(ctx,plate,plate.h*0.5,ui.color_alpha(ui.tone(ctx,"panel"),215))
    ui.draw_rounded_stroke(ctx,plate,plate.h*0.5,1,ui.color_alpha(color,150))
    ui.draw_text(ctx,name,plate.x+7,plate.y+3,PRESENCE_NAME,ui.tone(ctx,"text"),ui.FONT_SEMIBOLD)
}

// The glyph of a figure over its head: a circle of its color, faint inside
// and full on its border, with the glyph of an agent or the initial of an
// editor in the color of the text, as the bar shows them.
PRESENCE_GLYPH_FILL :: u8(115)
PRESENCE_GLYPH_HOT :: u8(175) // the fill of a glyph of the bar under the pointer

@(private)
presence_disc_draw :: proc(s:^Session,rect:ui.Rect,color:ui.Color) {
    ctx:=s.gui.ctx
    center:=ui.rect_center(rect)
    radius:=rect.w*0.5
    ui.draw_circle(ctx,center,radius,ui.color_alpha(ui.tone(ctx,"panel"),235))
    ui.draw_circle(ctx,center,radius,ui.color_alpha(color,PRESENCE_GLYPH_FILL))
    ui.draw_ring(ctx,center,radius,2.2,color)
}

@(private)
presence_icon_draw :: proc(s:^Session,rect:ui.Rect,icon:ui.Icon,color:ui.Color) {
    presence_disc_draw(s,rect,color)
    inset:=rect.w*0.2
    ui.draw_icon(s.gui.ctx,icon,{rect.x+inset,rect.y+inset,rect.w-2*inset,rect.h-2*inset},ui.tone(s.gui.ctx,"text"))
}

@(private)
presence_initial_draw :: proc(s:^Session,rect:ui.Rect,name:string,color:ui.Color) {
    presence_disc_draw(s,rect,color)
    ctx:=s.gui.ctx
    center:=ui.rect_center(rect)
    initial:=strings.to_upper(name[:min(len(name),1)] if name!="" else "?",context.temp_allocator)
    size:=ui.metric(ctx,"font")
    ui.draw_text(ctx,initial,center.x-ui.text_width(&ctx.font,initial,size,ui.FONT_SEMIBOLD)*0.5,center.y-size*0.62,size,ui.tone(ctx,"text"),ui.FONT_SEMIBOLD)
}
