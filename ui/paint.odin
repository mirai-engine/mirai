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
    Box,        // fill and stroke around an icon, a quad, a text and a right aligned detail
    Card,       // an icon over a centered label
    Text,       // one line clipped to its box
    Text_Block, // lines wrapped and aligned inside the box, with style
    Field,      // a text or number field, edited or not
    Swatch,     // a color
    Sat_Value,  // the square of saturation and value of a color picker
    Hue,        // its bar of hues
    Icon,
    Image,      // quad tinted by fill
    Nine_Slice, // quad with borders that keep their size
    Progress,   // a bar filled up to value over its track
    Slider,
    Switch,     // a track of fill with a knob of stroke, at its right end while value is 1
    User,       // Context_Desc.draw_user
    Prompt,     // an input of an action
    Checker,    // squares of fill and fill2, value units wide: what shows through transparency
    Replay,     // what a retained subtree drew, user_data says which (retain.odin)
    Arrow,      // a triangle of fill, size units wide, pointing left, right, up or down as value is 0 to 3
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
    line_height:f32,     // in sizes; 0 means TEXT_LINE, or PARAGRAPH_LINE in a paragraph
    outline:f32,         // width, in layout units
    outline_color:Color,
    shadow:[2]f32,       // offset of the shadow
    shadow_color:Color,
}

Paint :: struct {
    kind:Paint_Kind,
    surface,scope:u16,
    fill,fill2,stroke:Color,
    radius,stroke_width:f32,
    corners:[4]f32,          // of Rect and Panel: of each corner instead of radius when any is set
    shadow_color:Color,
    shadow_blur:f32,
    shadow_offset:[2]f32,
    layer:Layer_Style,
    effect_clip:u16,
    clip_data:Clip,
    shadow:bool,
    text,detail:string,      // detail is right aligned (shortcuts, counts)
    text_color,detail_color:Color,
    size:f32,
    center:bool,
    padding:f32,
    icon:Icon,
    icon_color:Color,
    icon_size:f32,
    icon_after:bool,         // the icon follows the text instead of leading it
    fade:bool,               // a Text wider than its rectangle fades out at its end
    hidden:bool,             // it keeps its place in the layout and draws nothing (Context.invisible)
    quad,quad2:Quad,         // preview or image; quad2: the track of a progress bar
    label:string,            // axis letter of a number field
    strip:Color,             // axis color of a number field
    caret:int,               // caret index in text, -1 when not editing
    caret_hidden:bool,
    multiline:bool,          // the text wraps and keeps its line breaks
    selection:[2]int,        // selected byte range of the edited text (empty when equal)
    scroll:f32,              // units the edited text is shifted left
    scroll_y:f32,            // units the edited text is shifted up
    placeholder:string,
    hsv:[3]f32,
    style:Text_Style,
    border,border_uv:[4]f32, // nine slice
    value:f32,               // progress, 0 to 1
    program:u32,             // of Rect, Panel, Bar and the bar of Progress: a ui program that colors the fill
    program_values:[4]f32,
    user_kind:u32,
    user_data:u64,
    prompt:Prompt,
    fill_mode:Progress_Fill, // of a Progress
    faint:Color,             // the placeholder of a Field; the theme's text_faint when transparent
    fit:Image_Fit,           // of an Image, keeping image_size
    image_size:[2]f32,       // of the part of the image shown, in texels; zero: unknown, it stretches
    decoration:Text_Decorations, // of a Text_Block
    revealed:i32,            // of a Text_Block: the characters it draws plus one; 0: all
}

FIELD_UNIT :: f32(9.5) // size of the unit at the right end of a number field

// Where the text of a field starts and how much room it has. marked: the
// field has the mark of its axis on its left edge. pad: units between each
// side and the text; 0: those of the editor. icon: drawn instead of the label.
field_text_span :: proc(ctx:^Context,r:Rect,label:string,marked:=false,pad:f32=0,icon:=Icon.None) -> (x,room:f32) {
    x=r.x+(pad if pad>0 else 11 if marked else 8)
    if icon!=.None {x+=FIELD_ICON+4} else if label!="" {x+=text_width(&ctx.font,label,ctx.theme.font_axis,FONT_MEDIUM)+6}
    return x,max(r.x+r.w-(pad if pad>0 else 8)-x,0)
}
FIELD_ICON :: f32(10) // side of the icon inside a field, before its value

// Where the text of a field lives: one line sits centered, a multiline field
// starts at the top and keeps the height of its rows.
Text_Area :: struct {x,y,w,h,line:f32}
field_text_area :: proc(ctx:^Context,r:Rect,label:string,size:f32,multiline:bool,marked:=false,pad:f32=0,icon:=Icon.None) -> (a:Text_Area) {
    a.x,a.w=field_text_span(ctx,r,label,marked,pad,icon)
    a.line=size*TEXT_LINE
    top:=pad if pad>0 else 5
    a.y=r.y+top if multiline else r.y+text_leading(size,r.h)
    a.h=max(r.h-2*top,a.line) if multiline else size*TEXT_LINE
    return
}

// The lines of a field that wraps: its selection, its text and its caret,
// which belongs to the first line that ends where it is. Only the lines in
// sight are drawn.
@(private)
paint_text_wrapped :: proc(ctx:^Context,p:^Paint,a:Text_Area,editing:bool,selection:Color) {
    font:=&ctx.font
    lo,hi:=clamp(p.selection[0],0,len(p.text)),clamp(p.selection[1],0,len(p.text))
    caret:=clamp(p.caret,0,len(p.text))
    drawn:=false
    f:=int(p.style.font)
    it:=text_lines(font,p.text,p.size,a.w,.Words,f)
    for {
        start,end,ok:=text_lines_next(&it)
        if !ok {break}
        y:=a.y+f32(it.row)*a.line-p.scroll_y
        if y>a.y+a.h {break}
        if y+a.line<a.y {
            drawn|=caret<=end
            continue
        }
        line:=p.text[start:end]
        if editing && hi>lo && hi>start && lo<=end {
            from:=text_width(font,p.text[start:clamp(lo,start,end)],p.size,f)
            to:=text_width(font,p.text[start:clamp(hi,start,end)],p.size,f)
            if hi>end {to=text_width(font,line,p.size,f)+p.size*0.3}
            draw_rect(ctx,{a.x+from,y,max(to-from,1),a.line},selection)
        }
        draw_text(ctx,line,a.x,y,p.size,p.text_color,f)
        if editing && hi<=lo && !p.caret_hidden && !drawn && caret<=end {
            draw_rect(ctx,{math.round(a.x+text_width(font,p.text[start:clamp(caret,start,end)],p.size,f)),y,1,p.size*TEXT_LINE},p.text_color)
        }
        drawn|=caret<=end
    }
}

@(private)
paint_text_line :: proc(ctx:^Context,p:^Paint,r:Rect,x:f32,color:Color) {
    draw_text(ctx,p.text,x,r.y+text_leading(p.size,r.h),p.size,color,int(p.style.font))
}

// A line that ends at end when it does not fit: it fades out over the last
// TEXT_FADE units before it.
@(private)
paint_text_faded :: proc(ctx:^Context,p:^Paint,r:Rect,x,end:f32,color:Color) {
    d:=&ctx.draw
    before:=d.fade
    d.fade={end-TEXT_FADE,end}
    clip_push(ctx,{r.x,r.y,max(end-r.x,0),r.h})
    paint_text_line(ctx,p,r,x,color)
    clip_pop(ctx)
    d.fade=before
}

TEXT_FADE :: 12

@(private)
paint_background :: proc(ctx:^Context,r:Rect,p:^Paint) {
    radii:=p.corners if p.corners!={} else [4]f32{p.radius,p.radius,p.radius,p.radius}
    if p.shadow {
        color:=p.shadow_color if p.shadow_color[3]>0 else ctx.theme.shadow
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
    draw_shape(ctx,r,{fill=p.fill,fill2=p.fill2,stroke=p.stroke,radii=radii,stroke_width=p.stroke_width if p.stroke_width>0 else 1,gradient=.Vertical if p.fill2[3]>0 else .Solid})
}

@(private)
paint_draw :: proc(ctx:^Context,r:Rect,p:^Paint) {
    th:=&ctx.theme
    font:=&ctx.font
    switch p.kind {
    case .None:
    case .Rect,.Panel:
        paint_background(ctx,r,p)
    case .Bar:
        if p.program!=0 {draw_program(ctx,r,p.program,p.program_values,p.fill,{})} else {draw_rect_gradient(ctx,r,p.fill,p.fill2)}
        draw_rect(ctx,{r.x,r.y+r.h-1,r.w,1},p.stroke)
    case .Card:
        paint_background(ctx,r,p)
        icon:=p.icon_size
        center_y:=r.y+r.h*(0.5 if p.text=="" else 0.42)
        if p.quad.kind!=.Solid {
            draw_image(ctx,{r.x+(r.w-icon)*0.5,center_y-icon*0.5,icon,icon},p.quad)
        } else {
            draw_icon(ctx,p.icon,{r.x+(r.w-icon)*0.5,center_y-icon*0.5,icon,icon},p.icon_color)
        }
        clip_push(ctx,r)
        draw_text(ctx,p.text,r.x+(r.w-text_width(font,p.text,p.size,int(p.style.font)))*0.5,r.y+r.h-p.size*TEXT_LINE-10,p.size,p.text_color,int(p.style.font))
        clip_pop(ctx)
    case .Box:
        paint_background(ctx,r,p)
        clip_push(ctx,r)
        x:=r.x+p.padding
        width:=text_width(font,p.text,p.size,int(p.style.font))
        icon_width:=f32(0)
        if p.icon!=.None {icon_width=p.icon_size+(6 if p.text!="" else 0)}
        // A preview next to a text keeps a margin; alone it takes the box.
        inset:=f32(4) if p.text!="" else f32(2)
        preview_size:=max(r.h-2*inset,0)
        preview_width:=preview_size+(6 if p.text!="" else 0) if p.quad.kind!=.Solid else 0
        if p.center {x=r.x+(r.w-icon_width-preview_width-width)*0.5}
        if p.icon!=.None && !p.icon_after {
            draw_icon(ctx,p.icon,{x,r.y+(r.h-p.icon_size)*0.5,p.icon_size,p.icon_size},p.icon_color)
            x+=icon_width
        }
        if p.quad.kind!=.Solid {
            draw_image(ctx,{x,r.y+inset,preview_size,preview_size},p.quad)
            x+=preview_width
        }
        // A detail takes at most half of what follows the start of the text,
        // and shows its end when it does not fit.
        right:=r.x+r.w-p.padding
        detail_x:=right
        if p.detail!="" && !p.center {detail_x-=min(text_width(font,p.detail,th.font_small),max(right-x,0)*0.5)}
        if p.text!="" {
            // A text that reaches the icon after it or the detail fades out before it.
            end:=r.x+r.w-p.padding-icon_width if p.icon_after else right
            if p.detail!="" && !p.center {end=min(end,detail_x-8)}
            if (p.icon_after || p.detail!="") && !p.center && x+width>end {paint_text_faded(ctx,p,r,x,end,p.text_color)} else {paint_text_line(ctx,p,r,x,p.text_color)}
        }
        // After the text: next to it when centered, else at the right end.
        if p.icon!=.None && p.icon_after {
            icon_x:=x+width+icon_width-p.icon_size if p.center else r.x+r.w-p.padding-p.icon_size
            draw_icon(ctx,p.icon,{icon_x,r.y+(r.h-p.icon_size)*0.5,p.icon_size,p.icon_size},p.icon_color)
        }
        if p.detail!="" {
            w:=text_width(font,p.detail,th.font_small)
            if detail_x>right-w {clip_push(ctx,{detail_x,r.y,r.x+r.w-detail_x,r.h})}
            draw_text(ctx,p.detail,right-w,r.y+text_leading(th.font_small,r.h),th.font_small,p.detail_color)
            if detail_x>right-w {clip_pop(ctx)}
        }
        clip_pop(ctx)
    case .Text:
        clip_push(ctx,r)
        x:=r.x
        if p.center {x=r.x+(r.w-text_width(font,p.text,p.size,int(p.style.font)))*0.5}
        if p.fade && text_width(font,p.text,p.size,int(p.style.font))>r.w {paint_text_faded(ctx,p,r,x,r.x+r.w,p.text_color)} else {paint_text_line(ctx,p,r,x,p.text_color)}
        clip_pop(ctx)
    case .Text_Block:
        draw_text_block(ctx,p.text,r,p.style,p.decoration,int(p.revealed)-1)
    case .Field:
        // A field of a game gives its corners, its selection and its placeholder; one of the editor takes the theme.
        radii:=p.corners if p.corners!={} else [4]f32{th.radius_control,th.radius_control,th.radius_control,th.radius_control}
        selection:=p.fill2 if p.fill2[3]>0 else th.text_select
        faint:=p.faint if p.faint[3]>0 else th.text_faint
        draw_rounded_corners(ctx,r,radii,p.fill)
        editing:=p.caret>=0
        marked:=p.strip[3]>0
        if marked {draw_rounded(ctx,{r.x+3,r.y+4,3,max(r.h-8,2)},1.5,p.strip)}
        // The unit keeps the right end; the value is clipped before it.
        unit:=text_width(font,p.detail,FIELD_UNIT)+5 if p.detail!="" else 0
        if unit>0 {draw_text(ctx,p.detail,r.x+r.w-unit,r.y+text_leading(FIELD_UNIT,r.h),FIELD_UNIT,th.text_faint if p.text_color==th.text_faint else th.text_muted)}
        clip_push(ctx,{r.x+1,r.y,r.w-2-unit,r.h})
        if p.icon!=.None {
            draw_icon(ctx,p.icon,{r.x+(11 if marked else 8),r.y+(r.h-FIELD_ICON)*0.5,FIELD_ICON,FIELD_ICON},th.text_muted)
        } else if p.label!="" {draw_text(ctx,p.label,r.x+(11 if marked else 8),r.y+text_leading(th.font_axis,r.h),th.font_axis,th.text,FONT_MEDIUM)}
        x,room:=field_text_span(ctx,r,p.label,marked,p.padding,p.icon)
        // The placeholder sits where the first line of text and the caret go.
        if p.text=="" && p.placeholder!="" {
            a:=field_text_area(ctx,r,p.label,p.size,p.multiline,marked,p.padding,p.icon)
            draw_text(ctx,p.placeholder,a.x+(2 if editing && !p.multiline else 0),a.y,p.size,faint,int(p.style.font))
        }
        if p.multiline {
            a:=field_text_area(ctx,r,p.label,p.size,true,marked,p.padding,p.icon)
            clip_push(ctx,{a.x-1,a.y,a.w+2,a.h})
            paint_text_wrapped(ctx,p,a,editing,selection)
            clip_pop(ctx)
        } else if editing {
            // Long text scrolls inside its own clip, so it never covers the label or the unit.
            clip_push(ctx,{x-1,r.y,max(room+2-unit,0),r.h})
            x-=p.scroll
            lo,hi:=clamp(p.selection[0],0,len(p.text)),clamp(p.selection[1],0,len(p.text))
            if hi>lo {
                from,to:=text_width(font,p.text[:lo],p.size,int(p.style.font)),text_width(font,p.text[:hi],p.size,int(p.style.font))
                draw_rect(ctx,{x+from,r.y+4,to-from,r.h-8},selection)
            }
            paint_text_line(ctx,p,r,x,p.text_color)
            if hi<=lo && !p.caret_hidden {
                caret_height:=min(p.size*TEXT_LINE,max(r.h-4,0))
                draw_rect(ctx,{math.round(x+text_width(font,p.text[:clamp(p.caret,0,len(p.text))],p.size,int(p.style.font))),r.y+(r.h-caret_height)*0.5,1,caret_height},p.text_color)
            }
            clip_pop(ctx)
        } else if p.text!="" {paint_text_line(ctx,p,r,x,p.text_color)}
        clip_pop(ctx)
        if p.stroke[3]>0 {draw_shape(ctx,r,{stroke=p.stroke,stroke_width=p.stroke_width if p.stroke_width>0 else 1,radii=radii})}
    case .Swatch:
        draw_rounded(ctx,r,th.radius_control,p.fill)
        draw_rounded_stroke(ctx,r,th.radius_control,1,p.stroke)
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
        draw_rect_lines(ctx,r,1,th.border)
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
    case .User:
        if ctx.draw_user!=nil {ctx.draw_user(ctx,r,p.user_kind,p.user_data,p.fill)}
    case .Prompt:
        prompt_paint(ctx,r,p.prompt)
    case .Replay:
        retained_draw(ctx,p.user_data)
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

// Text wrapped, aligned and clipped inside r. limit: how many of its
// characters are drawn, each line where all of them would go; negative: all.
draw_text_block :: proc(ctx:^Context,text:string,r:Rect,style:Text_Style,decoration:Text_Decorations={},limit:=-1) {
    if style.size<=0 || text=="" || limit==0 {return}
    font:=&ctx.font
    f:=int(style.font)
    line_height:=style.size*(style.line_height if style.line_height>0 else TEXT_LINE)
    leading:=text_leading(style.size,line_height)
    lines:=text_line_count(font,text,style.size,r.w,style.wrap,f)
    // Lines whose text fits; at least one is drawn.
    visible:=max(min(lines,int((r.h-leading-style.size*TEXT_LINE)/line_height)+1),1) if r.h>0 else lines
    height:=f32(visible)*line_height
    y:=r.y
    switch style.align_y {
    case .Start:
    case .Center:y=r.y+(r.h-height)*0.5
    case .End:y=r.y+r.h-height
    }
    margin:=style.outline+max(abs(style.shadow.x),abs(style.shadow.y))+(style.size*TEXT_ITALIC if .Italic in decoration else 0)
    clip_push(ctx,{r.x-margin,r.y-margin,r.w+2*margin,r.h+2*margin})
    rest:=text
    left:=limit
    for index in 0..<visible {
        line:string;width:f32
        before:=rest
        line,rest,width=text_line(font,rest,style.size,r.w,style.wrap,f)
        cut:=false
        // A line too wide, or the last one in sight of more text, ends in an ellipsis.
        if style.ellipsis && (width>r.w+0.01 || (index==visible-1 && rest!="")) {
            line=text_cut(font,line,style.size,r.w,f)
            cut=true
            width=text_width(font,line,style.size,f)+text_width(font,ELLIPSIS,style.size,f)
        }
        x:=r.x
        switch style.align_x {
        case .Start:
        case .Center:x=r.x+(r.w-width)*0.5
        case .End:x=r.x+r.w-width
        }
        shown:=line
        if left>=0 {
            count:=0
            for _,i in line {
                if count==left {shown=line[:i];break}
                count+=1
            }
            // The spaces or the break the line ended at count as characters too.
            left=max(left-count-(len(before)-len(line)-len(rest)),0)
        }
        draw_text_decorated(ctx,shown,x,y+leading,style,decoration)
        if cut && len(shown)==len(line) {draw_text_decorated(ctx,ELLIPSIS,x+text_width(font,line,style.size,f),y+leading,style,decoration)}
        if left==0 {break}
        y+=line_height
    }
    clip_pop(ctx)
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
