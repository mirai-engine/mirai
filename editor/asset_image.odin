package editor

import "core:math"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:ui"

// The images of the asset documents: entries of the texture table that the
// renderer draws inside the frame (renderer_preview) or the CPU fills, shown
// filling their area; and the camera the pointer moves on one.

// The light of a prefab and of the previews of the documents that show a
// subject: a sun and a sky over the ground grid.
PREVIEW_SUN :: gpu.Sun_Desc{direction={-erender.SUN_DIRECTION.x,erender.SUN_DIRECTION.y,-erender.SUN_DIRECTION.z},color={1,0.97,0.92},illuminance=100000,enabled=true}
PREVIEW_ENVIRONMENT :: gpu.Environment{sky={3500,3850,4550},background={440,510,620},use_background=true,ground_grid=true}

Asset_Image :: struct {
    key:u64, // of its entry of the texture table
    name:string,
    target:gpu.Preview_GPU,
    renderer:^gpu.Renderer, // that owns target
    texture:gpu.Texture_Handle,
    signature:u64, // of what it shows; 0: nothing yet
    frame:u64,     // of the editor when it was last drawn
    ready:bool,    // the last draw showed something
    side:u32,      // texels of a side of its entry of the table
    size:[2]u32,   // texels the last draw filled from the top left corner; zero: all
    stretch:bool,  // its whole texture fills the area, as asset_image_pixels leaves it
    area:[2]f32,   // points of what showed it in the last frame
    made:u64,      // gpu.renderer_pipelines_made when it was last drawn
}

// The texels an image draws for the shape of its area: two per point, as many
// as its side holds.
asset_image_size :: proc(image:^Asset_Image,side:u32) -> [2]u32 {
    area:=image.area
    if area.x<1 || area.y<1 {return {side,side}}
    scale:=min(2,f32(side)/max(area.x,area.y))
    return {clamp(u32(area.x*scale+0.5),1,side),clamp(u32(area.y*scale+0.5),1,side)}
}

asset_image_free :: proc(image:^Asset_Image) {
    if image.renderer!=nil {gpu.preview_destroy(image.renderer.device,&image.target)}
    image.renderer,image.texture,image.signature,image.ready=nil,0,0,false
}

// Shows pixels made on the CPU, width by height and opaque, stretched over the area that shows them.
asset_image_pixels :: proc(s:^Session,image:^Asset_Image,pixels:[]u8,width,height:int,signature:u64) {
    image.signature,image.stretch,image.ready=signature,true,false
    a:=s.app.assets
    if a==nil || a.renderer==nil {return}
    image.renderer=a.renderer
    image.texture,image.ready=gpu.texture_image(a.renderer,image.key,pixels,width,height,image.name)
}

// Whether an image must be drawn again: what it shows or the shape of its
// area changed, or the renderer made pipelines of programs since it drew it
// (a program it showed as its rows), and it was not drawn in this frame.
asset_image_due :: proc(s:^Session,image:^Asset_Image,signature:u64) -> bool {
    changed:=signature!=image.signature || image.side!=0 && asset_image_size(image,image.side)!=image.size
    changed||=!image.stretch && image.renderer!=nil && gpu.renderer_pipelines_made(image.renderer)!=image.made
    return changed && image.frame!=s.frame+1
}

// Hands the triangles to the next frame, which draws them into the image, an
// entry side texels square, in the shape of its area, over the color of a
// field in the studio, lit or showing channel. They must stay as they are
// until that frame is drawn.
asset_image_draw :: proc(s:^Session,image:^Asset_Image,side:u32,signature:u64,vertices:[]gpu.Thumbnail_Vertex,materials:[]gpu.Material_Desc,fit:[2][3]f32,view:=gpu.Preview_View{},light:=gpu.Preview_Light{},channel:=gpu.Debug_View.None) {
    image.signature,image.frame=signature,s.frame+1
    image.ready=false
    image.side,image.size,image.stretch=side,asset_image_size(image,side),false
    a:=s.app.assets
    if len(vertices)<3 || a==nil || a.renderer==nil {return}
    host.assets_commit(a)
    image.renderer=a.renderer
    image.made=gpu.renderer_pipelines_made(a.renderer)
    field:=ui.tone(s.gui.ctx,"field")
    handle,ok:=gpu.renderer_preview(a.renderer,&image.target,image.key,image.name,vertices,materials,side,image.size,{f32(field.r)/255,f32(field.g)/255,f32(field.b)/255},fit,view,light,channel)
    image.texture,image.ready=handle,ok
    // A frame takes a few images: one that found no room asks again in the next.
    if !ok {image.signature=0}
}

// The image over the color of a field: one the renderer draws fills its area,
// and one the CPU fills is square, as large as the area allows. The area is
// as wide as its parent and height tall; the pointer on it is its
// interaction, and rect where it was in the last frame.
asset_image_show :: proc(s:^Session,image:^Asset_Image,height:=ui.GROW) -> (it:ui.Interaction,rect:ui.Rect) {
    ctx:=s.gui.ctx
    area:=ui.id(ctx,"image_area")
    found:bool
    if rect,found=ui.widget_rect(ctx,area);found {image.area={rect.w,rect.h}}
    it=ui.interact(ctx,area,{.Scroll})
    if ui.box(ctx,{id=area,width=ui.GROW,height=height,align_x=.Center,align_y=.Center,fill=ui.tone(ctx,"field"),track=true}) {
        a:=s.app.assets
        if !image.ready || image.texture==0 || a==nil || a.renderer==nil {return}
        index:=gpu.ui_image(a.renderer,image.texture)
        if index==0 {return}
        quad:=ui.quad_whole(.Image,index&~gpu.UI_MATERIAL_IMAGE_BIT)
        if image.stretch {
            ui.image(ctx,{quad=quad,width=ui.GROW,height=ui.GROW})
        } else if image.side>0 && image.size!={} {
            quad.uv={0,0,f32(image.size.x)/f32(image.side),f32(image.size.y)/f32(image.side)}
            ui.image(ctx,{quad=quad,width=ui.GROW,height=ui.GROW})
        } else {
            side:=found?max(min(rect.w,rect.h)-24,32):160
            ui.image(ctx,{quad=quad,width=ui.fixed(side),height=ui.fixed(side)})
        }
    }
    return
}

// The camera of an image and the gesture that moves it: a drag orbits what it
// frames, the middle or right button moves across, the wheel comes closer and
// a double click frames it whole again.
Asset_View :: struct {
    view:gpu.Preview_View,
    drag:enum u8 {None,Orbit,Pan},
    from:[2]f32,
}

asset_view_input :: proc(ctx:^ui.Context,v:^Asset_View,it:ui.Interaction,area:ui.Rect) {
    input:=&ctx.input
    pointer:=input.pointer
    if it.double {
        v^={}
        return
    }
    if it.pressed {v.drag,v.from=.Orbit,pointer}
    if it.hot && (.Middle in input.pressed || .Right in input.pressed) {v.drag,v.from=.Pan,pointer}
    if v.view.zoom<=0 && (v.drag!=.None || it.hot && input.wheel.y!=0) {v.view={zoom=1,orbit=gpu.PREVIEW_ORBIT}}
    if v.drag!=.None {
        if input.down&{.Left,.Middle,.Right}=={} {v.drag=.None} else {
            delta:=pointer-v.from
            v.from=pointer
            switch v.drag {
            case .None:
            case .Orbit:
                v.view.orbit.x-=delta.x*0.01
                v.view.orbit.y=clamp(v.view.orbit.y+delta.y*0.01,-gpu.PREVIEW_ELEVATION,gpu.PREVIEW_ELEVATION)
            case .Pan:
                v.view.pan+=delta/max(area.h,1)/v.view.zoom
            }
        }
    }
    if it.hot && input.wheel.y!=0 {v.view.zoom=clamp(v.view.zoom*math.exp(input.wheel.y*0.12),0.25,8)}
}

// The bits of a view, for the signature of what an image shows.
asset_view_bits :: proc(v:^Asset_View) -> [5]u32 {return transmute([5]u32)v.view}
