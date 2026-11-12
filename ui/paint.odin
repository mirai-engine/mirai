package ui

import "core:math"
import mm "mirai:std/math"

// What an element draws once the layout has placed it. Widgets fill one of these
// records while the frame is built; frame_end turns them into geometry with
// the final rectangles. One procedure draws every kind: no widget owns code
// that runs later.

Paint_Kind :: enum u8 {
    None,
    Rect,       // fill, radius
    Panel,      // shadow, fill and a one unit stroke
    Bar,        // vertical gradient from fill to fill2 over a line of stroke
    Box,        // fill and stroke, or quad2 tinted by fill: a button or a row, whose content are its children
    Field,      // the well of a text or number field and the mark of its axis
    Caret,      // a line of fill one unit wide at the left edge: where an edited text is typed
    Swatch,     // a color
    Sat_Value,  // the square of saturation and value of a color picker
    Hue,        // its bar of hues
    Icon,
    Image,      // quad tinted by fill
    Nine_Slice, // quad with borders that keep their size
    Progress,   // a bar filled up to value over its track
    Slider,
    Switch,     // a track of fill with a knob of stroke, at its right end while value is 1
    Prompt,     // an input of an action
    Checker,    // squares of fill and fill2, value units wide: what shows through transparency
    Replay,     // what a retained subtree drew, user_data says which (retain.odin)
    Arrow,      // a triangle of fill, size units wide, pointing left, right, up or down as value is 0 to 3
    Draw,       // a canvas or a Draw node: Context.draw_user, with draw
}

// What a run of text adds to its glyphs. Bold is synthetic: the run drawn
// again TEXT_BOLD of its size to the right, for a font without a bold face.
Text_Decoration :: enum u8 {Bold,Italic,Underline,Strike}
Text_Decorations :: bit_set[Text_Decoration;u8]

Text_Style :: struct {
    font:u8,
    size:f32,
    color:Color,
    align_x,align_y:Align,
    wrap:Text_Wrap,
    ellipsis:bool,       // text that does not fit ends in an ellipsis
    italic:bool,         // its glyphs lean as synthetic italics
    line_height:f32,     // in sizes; 0 means TEXT_LINE
    outline:f32,         // width, in layout units
    outline_color:Color,
    shadow:[2]f32,       // offset of the shadow
    shadow_color:Color,
}

Paint :: struct {
    kind:Paint_Kind,
    surface,scope:u16,
    fill,fill2,stroke:Color,
    gradient:Fill_Gradient,  // of Rect, Panel, Bar and Box: the way fill goes to fill2
    radius,stroke_width:f32,
    corners:[4]f32,          // of Rect and Panel: of each corner instead of radius when any is set
    shadow_color:Color,
    shadow_blur:f32,
    shadow_offset:[2]f32,
    layer:Layer_Style,
    effect_clip:u16,
    clip_data:Clip,
    shadow:bool,
    text:string,             // of a text whose words are one span: what it says
    size:f32,
    icon:Icon,
    icon_color:Color,
    icon_size:f32,
    fade:bool,               // of a text: a line wider than its rectangle fades out at its end
    hidden:bool,             // it keeps its place in the layout and draws nothing (Context.invisible)
    quad,quad2:Quad,         // preview or image; quad2: the track of a progress bar
    strip:Color,             // axis color of a number field
    hsv:[3]f32,
    style:Text_Style,
    border,border_uv:[4]f32, // nine slice
    value:f32,               // progress, 0 to 1
    program:u32,             // of Rect, Panel, Bar and the bar of Progress: a ui program that colors the fill
    program_values:[4]f32,
    user_data:u64,           // of Replay: the retained subtree
    draw:Draw_Node,          // of Draw: what Context.draw_user is handed, but its rect
    prompt:Prompt,
    fill_mode:Progress_Fill, // of a Progress
    fit:Image_Fit,           // of an Image, keeping image_size
    image_size:[2]f32,       // of the part of the image shown, in texels; zero: unknown, it stretches
    decoration:Text_Decorations, // of a text
    revealed:i32,            // of a text: the characters it draws plus one; 0: all
}

FIELD_UNIT :: f32(9.5) // size of the unit at the right end of a number field
FIELD_ICON :: f32(10)  // side of the icon inside a field, before its value

TEXT_FADE :: 12

@(private)
paint_background :: proc(ctx:^Context,r:Rect,p:^Paint) {
    radii:=p.corners if p.corners!={} else [4]f32{p.radius,p.radius,p.radius,p.radius}
    if p.shadow {
        color:=p.shadow_color if p.shadow_color[3]>0 else tone(ctx,"shadow")
        radius:=max(radii[0],radii[1],radii[2],radii[3])
        // Without blur an offset is a hard edge of its shape, a default shadow without one.
        switch {
        case p.shadow_blur>0:     draw_blurred_shadow(ctx,r,radius,p.shadow_blur,p.shadow_offset,color)
        case p.shadow_offset!={}: draw_shape(ctx,{r.x+p.shadow_offset.x,r.y+p.shadow_offset.y,r.w,r.h},{fill=color,radii=radii})
        case:                     draw_shadow(ctx,r,radius,color)
        }
    }
    if p.program!=0 {
        draw_program(ctx,r,p.program,p.program_values,p.fill,radii)
        draw_shape(ctx,r,{stroke=p.stroke,radii=radii,stroke_width=p.stroke_width if p.stroke_width>0 else 1})
        return
    }
    gradient:=Gradient.Solid if p.fill2[3]==0 else .Horizontal if p.gradient==.Right else .Vertical
    draw_shape(ctx,r,{fill=p.fill,fill2=p.fill2,stroke=p.stroke,radii=radii,stroke_width=p.stroke_width if p.stroke_width>0 else 1,gradient=gradient})
}

@(private)
paint_draw :: proc(ctx:^Context,r:Rect,p:^Paint) {
    switch p.kind {
    case .None:
    case .Rect,.Panel:
        paint_background(ctx,r,p)
    case .Bar:
        switch {
        case p.program!=0:        draw_program(ctx,r,p.program,p.program_values,p.fill,{})
        case p.gradient==.Right: draw_quad_colors(ctx,{{r.x,r.y},{r.x+r.w,r.y},{r.x+r.w,r.y+r.h},{r.x,r.y+r.h}},{p.fill,p.fill2,p.fill2,p.fill})
        case:                     draw_rect_gradient(ctx,r,p.fill,p.fill2)
        }
        draw_rect(ctx,{r.x,r.y+r.h-1,r.w,1},p.stroke)
    case .Box:
        switch {
        case p.quad2.kind==.Solid: paint_background(ctx,r,p)
        case p.border!={}:         draw_nine_slice(ctx,r,p.quad2,p.border,p.border_uv,p.fill)
        case:                      draw_image(ctx,r,p.quad2,p.fill)
        }
    case .Field:
        draw_rounded_corners(ctx,r,p.corners,p.fill)
        if p.strip[3]>0 {draw_rounded(ctx,{r.x+3,r.y+4,3,max(r.h-8,2)},1.5,p.strip)}
        if p.stroke[3]>0 {draw_shape(ctx,r,{stroke=p.stroke,stroke_width=p.stroke_width if p.stroke_width>0 else 1,radii=p.corners})}
    case .Caret:
        draw_rect(ctx,{math.round(r.x),r.y,1,r.h},p.fill)
    case .Swatch:
        draw_rounded(ctx,r,metric(ctx,"radius_control"),p.fill)
        draw_rounded_stroke(ctx,r,metric(ctx,"radius_control"),1,p.stroke)
    case .Sat_Value:
        // Exact colors on a grid of quads: Gouraud shading between them is
        // indistinguishable from the true saturation/value ramp.
        N :: 8
        for j in 0..<N {for i in 0..<N {
            x0,x1:=r.x+r.w*f32(i)/N,r.x+r.w*f32(i+1)/N
            y0,y1:=r.y+r.h*f32(j)/N,r.y+r.h*f32(j+1)/N
            s0,s1:=f32(i)/N,f32(i+1)/N;v0,v1:=1-f32(j)/N,1-f32(j+1)/N
            h:=p.hsv[0]
            draw_quad_colors(ctx,{{x0,y0},{x1,y0},{x1,y1},{x0,y1}},{
                rgb_color(mm.hsv_to_rgb({h,s0,v0})),rgb_color(mm.hsv_to_rgb({h,s1,v0})),
                rgb_color(mm.hsv_to_rgb({h,s1,v1})),rgb_color(mm.hsv_to_rgb({h,s0,v1}))})
        }}
        point:=[2]f32{r.x+p.hsv[1]*r.w,r.y+(1-p.hsv[2])*r.h}
        clip_push(ctx,r)
        draw_ring(ctx,point,6,2,{255,255,255,255})
        draw_ring(ctx,point,8,1,{0,0,0,160})
        clip_pop(ctx)
        draw_rect_lines(ctx,r,1,tone(ctx,"border"))
    case .Hue:
        for i in 0..<6 {
            x0,x1:=r.x+r.w*f32(i)/6,r.x+r.w*f32(i+1)/6
            c0:=rgb_color(mm.hsv_to_rgb({f32(i)/6,1,1}));c1:=rgb_color(mm.hsv_to_rgb({f32(i+1)/6-1e-4,1,1}))
            draw_quad_colors(ctx,{{x0,r.y},{x1,r.y},{x1,r.y+r.h},{x0,r.y+r.h}},{c0,c1,c1,c0})
        }
        x:=r.x+p.hsv[0]*r.w
        draw_rect(ctx,{x-2.5,r.y-3,5,r.h+6},{0,0,0,170})
        draw_rect(ctx,{x-1.5,r.y-2,3,r.h+4},{255,255,255,255})
    case .Icon:
        draw_icon(ctx,p.icon,r,p.icon_color)
    case .Image:
        if p.fit==.Stretch || p.image_size.x<=0 || p.image_size.y<=0 {
            draw_image(ctx,r,p.quad,p.fill)
            break
        }
        place,uv:=image_fit(r,p.quad.uv,p.image_size,p.fit)
        quad:=p.quad
        quad.uv=uv
        clip_push(ctx,r)
        draw_image(ctx,place,quad,p.fill)
        clip_pop(ctx)
    case .Nine_Slice:
        draw_nine_slice(ctx,r,p.quad,p.border,p.border_uv,p.fill)
    case .Slider:
        // radius: of the knob; stroke_width: the thickness of the track; corners: of the track. 6, 4 and round when 0.
        diameter:=p.radius*2 if p.radius>0 else 12
        thickness:=p.stroke_width if p.stroke_width>0 else 4
        track:=Rect{r.x+diameter*0.5,r.y+(r.h-thickness)*0.5,max(r.w-diameter,0),thickness}
        radii:=p.corners if p.corners!={} else [4]f32{thickness*0.5,thickness*0.5,thickness*0.5,thickness*0.5}
        draw_rounded_corners(ctx,track,radii,p.fill)
        fraction:=clamp(p.value,0,1)
        if fraction>0 {draw_rounded_corners(ctx,{track.x,track.y,track.w*fraction,track.h},radii,p.fill2)}
        x:=track.x+track.w*fraction
        draw_rounded(ctx,{x-diameter*0.5,r.y+(r.h-diameter)*0.5,diameter,diameter},diameter*0.5,p.stroke)
    case .Switch:
        draw_rounded(ctx,r,r.h*0.5,p.fill)
        knob:=r.h-5
        x:=r.x+r.w-knob-2.5 if p.value>0 else r.x+2.5
        draw_rounded(ctx,{x,r.y+2.5,knob,knob},knob*0.5,p.stroke)
    case .Progress:
        value:=clamp(p.value,0,1)
        if p.fill_mode==.Radial {
            progress_radial(ctx,r,value,p)
            break
        }
        radii:=p.corners if p.corners!={} else [4]f32{p.radius,p.radius,p.radius,p.radius}
        if p.quad2.kind!=.Solid {draw_nine_slice(ctx,r,p.quad2,p.border,p.border_uv,p.fill2)} else {draw_rounded_corners(ctx,r,radii,p.fill2)}
        if value>0 {
            // The bar is the whole shape cut at its value, so its ends keep their form.
            cut:Rect
            switch p.fill_mode {
            case .Right,.Radial: cut={r.x,r.y,r.w*value,r.h}
            case .Left:          cut={r.x+r.w*(1-value),r.y,r.w*value,r.h}
            case .Down:          cut={r.x,r.y,r.w,r.h*value}
            case .Up:            cut={r.x,r.y+r.h*(1-value),r.w,r.h*value}
            case .Center:        cut={r.x+r.w*(1-value)*0.5,r.y,r.w*value,r.h}
            }
            clip_push(ctx,cut)
            if p.quad.kind!=.Solid {
                draw_nine_slice(ctx,r,p.quad,p.border,p.border_uv,p.fill)
            } else if p.program!=0 {
                draw_program(ctx,r,p.program,p.program_values,p.fill,radii)
            } else {draw_rounded_corners(ctx,r,radii,p.fill)}
            clip_pop(ctx)
        }
        if p.stroke[3]>0 {draw_shape(ctx,r,{stroke=p.stroke,stroke_width=1,radii=radii})}
    case .Prompt:
        prompt_paint(ctx,r,p.prompt)
    case .Replay:
        retained_draw(ctx,p.user_data)
    case .Draw:
        if ctx.draw_user!=nil {
            node:=p.draw
            node.rect=r
            ctx.draw_user(ctx.draw_user_data,ctx,node)
        }
    case .Arrow:
        // A chevron whose lines are an eighth of its size thick.
        c:=rect_center(r)
        h:=p.size*0.5
        point:[3][2]f32
        switch int(p.value) {
        case 0: point={{c.x+h*0.5,c.y-h},{c.x-h*0.5,c.y},{c.x+h*0.5,c.y+h}}
        case 1: point={{c.x-h*0.5,c.y-h},{c.x+h*0.5,c.y},{c.x-h*0.5,c.y+h}}
        case 2: point={{c.x-h,c.y+h*0.5},{c.x,c.y-h*0.5},{c.x+h,c.y+h*0.5}}
        case:   point={{c.x-h,c.y-h*0.5},{c.x,c.y+h*0.5},{c.x+h,c.y-h*0.5}}
        }
        draw_polyline(ctx,point[:],max(p.size*0.125,ctx.draw.pixel),p.fill)
    case .Checker:
        draw_rect(ctx,r,p.fill)
        side:=max(p.value,2)
        clip_push(ctx,r)
        for row:=0;f32(row)*side<r.h;row+=1 {
            for column:=row%2;f32(column)*side<r.w;column+=2 {
                draw_rect(ctx,{r.x+f32(column)*side,r.y+f32(row)*side,side,side},p.fill2)
            }
        }
        clip_pop(ctx)
    }
}

TEXT_ITALIC :: f32(0.2) // the shear of synthetic italics: units to the right per unit above the baseline
TEXT_BOLD :: f32(0.04)  // how far synthetic bold draws its run again, in sizes
TEXT_RULE :: f32(0.07)  // the thickness of an underline or a strike, in sizes

// One line with its shadow and outline, top-left corner at (x, y), and the
// decorations of its run: italics shear its glyphs around the baseline, bold
// draws it again a little to the right, an underline goes under the baseline
// and a strike across the lowercase letters.
draw_text_decorated :: proc(ctx:^Context,text:string,x,y:f32,style:Text_Style,decoration:Text_Decorations={}) {
    f:=int(style.font)
    d:=&ctx.draw
    shear:=d.shear
    if .Italic in decoration {d.shear=TEXT_ITALIC}
    defer d.shear=shear
    bold:=max(style.size*TEXT_BOLD,d.pixel) if .Bold in decoration else 0
    run :: proc(ctx:^Context,text:string,x,y,size,bold:f32,color:Color,f:int) {
        draw_text(ctx,text,x,y,size,color,f)
        if bold>0 {draw_text(ctx,text,x+bold,y,size,color,f)}
    }
    if style.shadow_color[3]>0 && style.shadow!={} {run(ctx,text,x+style.shadow.x,y+style.shadow.y,style.size,bold,style.shadow_color,f)}
    if style.outline>0 && style.outline_color[3]>0 {
        o:=style.outline;e:=o*0.70710678
        for offset in ([8][2]f32{{o,0},{-o,0},{0,o},{0,-o},{e,e},{-e,e},{e,-e},{-e,-e}}) {
            run(ctx,text,x+offset.x,y+offset.y,style.size,bold,style.outline_color,f)
        }
    }
    run(ctx,text,x,y,style.size,bold,style.color,f)
    if decoration&{.Underline,.Strike}=={} || text=="" {return}
    ascent:=ctx.font.metrics[f].ascent if ctx.font.ready && f>=0 && f<ctx.font.font_count else f32(0.97)
    width:=text_width(&ctx.font,text,style.size,f)+bold
    thickness:=max(style.size*TEXT_RULE,d.pixel)
    baseline:=y+ascent*style.size
    if .Underline in decoration {draw_rect(ctx,{x,baseline+thickness,width,thickness},style.color)}
    if .Strike in decoration {draw_rect(ctx,{x,baseline-style.size*0.3-thickness*0.5,width,thickness},style.color)}
}

// Where an image whose part shown is size texels goes in r as fit says, and
// the part of uv it shows there: Cover cuts what does not fit.
image_fit :: proc "contextless" (r:Rect,uv:Rect,size:[2]f32,fit:Image_Fit) -> (place,part:Rect) {
    place,part=r,uv
    if size.x<=0 || size.y<=0 || r.w<=0 || r.h<=0 {return}
    switch fit {
    case .Stretch:
    case .Contain:
        scale:=min(r.w/size.x,r.h/size.y)
        place={r.x+(r.w-size.x*scale)*0.5,r.y+(r.h-size.y*scale)*0.5,size.x*scale,size.y*scale}
    case .Cover:
        scale:=max(r.w/size.x,r.h/size.y)
        fx,fy:=r.w/(size.x*scale),r.h/(size.y*scale)
        part={uv.x+uv.w*(1-fx)*0.5,uv.y+uv.h*(1-fy)*0.5,uv.w*fx,uv.h*fy}
    case .Center:
        place={r.x+(r.w-size.x)*0.5,r.y+(r.h-size.y)*0.5,size.x,size.y}
    }
    return
}

// A Progress that fills clockwise from the top: a ring of its stroke width, or
// a disc without one, over a track of the same shape.
@(private)
progress_radial :: proc(ctx:^Context,r:Rect,value:f32,p:^Paint) {
    center:=[2]f32{r.x+r.w*0.5,r.y+r.h*0.5}
    radius:=min(r.w,r.h)*0.5
    width:=p.stroke_width
    if width>0 {
        draw_ring(ctx,center,radius-width*0.5,width,p.fill2)
    } else {draw_circle(ctx,center,radius,p.fill2)}
    if width>0 {draw_arc(ctx,center,radius-width*0.5,width,value,p.fill)} else {draw_arc(ctx,center,radius,0,value,p.fill)}
    if p.stroke[3]>0 {draw_ring(ctx,center,radius,1,p.stroke)}
}
