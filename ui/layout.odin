package ui

// What a container asks of the layout: its size along each axis, how it
// arranges its children and where it floats.

Size_Kind :: enum u8 {
    Fit,     // as large as its content, between min and max
    Grow,    // shares what its parent has left, between min and max, by value as its weight (0 is 1)
    Fixed,   // value
    Percent, // value (0 to 1) of its parent
}
Size :: struct {kind:Size_Kind,value,min,max:f32}
FIT :: Size{}
GROW :: Size{kind=.Grow}
fixed :: proc "contextless" (value:f32) -> Size {return {kind=.Fixed,value=value}}
fit :: proc "contextless" (min:f32=0,max:f32=0) -> Size {return {kind=.Fit,min=min,max=max}}
grow :: proc "contextless" (min:f32=0,max:f32=0) -> Size {return {kind=.Grow,min=min,max=max}}
percent :: proc "contextless" (value:f32) -> Size {return {kind=.Percent,value=value}}

Direction :: enum u8 {
    Row,
    Column,
    Grid,  // rows of columns cells, as wide as its tracks say or all the same; each row as high as its highest child
    Wrap,  // a row that goes on in another row below where the next child does not fit
    Stack, // children over one another, each placed by its alignment
}
// Baseline: of the children of a Row, down it: the first line of the text of
// each on one baseline, a child without text standing on it. Anywhere else it is Start.
Align :: enum u8 {Start,Center,End,Baseline}
// How a child places itself across the direction of its parent, or inside its
// cell or the stack: as its parent aligns its children, or on its own.
Self_Align :: enum u8 {Parent,Start,Center,End,Stretch}

// The widths of the columns of a Grid, or the heights of its first rows for
// the Grid that names it by Box.row_tracks: Fixed, Percent, Fit or Grow, whose
// value is its weight (0 is 1). The rows after them are as high as their highest child.
GRID_TRACKS :: 12
Grid_Tracks :: struct {
    count:u8,
    columns:[GRID_TRACKS]Size,
}

// A point of a rectangle: where a floating element hangs from, and which of
// its own points hangs there.
Anchor :: enum u8 {Top_Left,Center_Left,Bottom_Left,Top_Center,Center,Bottom_Center,Top_Right,Center_Right,Bottom_Right}

Float_To :: enum u8 {
    None,
    Surface, // the whole surface
    Safe,    // the safe area of the surface
    Parent,
    Root,    // the root of the surface: what a world panel and a tooltip hang from
}
// Takes a container out of the flow of its parent.
Float :: struct {
    to:Float_To,
    anchor:Anchor,   // the point of the target it hangs from
    pivot:Anchor,    // its own point placed there
    offset:[2]f32,
    layer:i16,       // floating surfaces of a higher layer cover the lower ones
}

Layout :: struct {
    width,height:Size,
    direction:Direction,
    padding:[4]f32, // left, top, right, bottom
    gap:f32,
    align_x,align_y:Align, // in a Grid, of each child inside its cell
    columns:u16,           // of a Grid; 0 is 1
    tracks:u16,            // of a Grid: row plus one of Context.grid_tracks with the width of each column; 0: all the same
    span:u8,               // columns of a Grid it takes; 0 is 1
    self_x,self_y:Self_Align,
    aspect:f32,            // width over height it keeps, the axis that fits giving the other; 0: none
}

Box :: struct {
    id:Id,
    using layout:Layout,
    row_span:u8,     // rows of a Grid it takes; 0 is 1
    row_tracks:u16,  // of a Grid: what grid_tracks_add gave for the heights of its first rows; 0: each as high as its highest child
    float:Float,
    contain:bool,    // floating: it stays inside its surface, on the other side of what it hangs from when it does not fit
    inset:[4]f32,    // contained: how far inside its surface it stays (left, top, right, bottom)
    from:Maybe(Rect),// floating: the rectangle it hangs from, in the units of the layout, instead of what float.to names
    clip_x,clip_y:bool,
    corners:[4]f32,  // of each corner, top left first clockwise, instead of radius when any is set
    clip_floats:bool,// what floats inside it is cut by its clip too, as its content is
    scroll:[2]f32,   // how far the content is moved up and left inside its clip
    // Background; nothing is drawn while fill and stroke are transparent.
    fill,stroke:Color,
    fill2:Color,     // when set: a gradient from fill to it, over a line of stroke
    gradient:Fill_Gradient,
    radius:f32,
    shadow:bool,
    stroke_width:f32,
    shadow_color:Color,
    shadow_blur:f32,
    shadow_offset:[2]f32,
    layer:Layer_Style, // isolated composition; enable with enabled=true, opacity=1
    image:Quad,      // drawn instead of the fill, tinted by it (white when transparent)
    image_border,image_border_uv:[4]f32, // nine slice: see draw_nine_slice
    image_fit:Image_Fit,  // without a nine slice: how the image takes the box, keeping image_size
    image_size:[2]f32,    // of the part of the image shown, in texels; zero: unknown, it stretches
    program:u32,     // a ui program that colors the fill instead, given fill: see draw_program
    program_values:[4]f32,
    block:bool,      // takes the pointer: what is behind does not see it
    track:bool,      // its rectangle is kept for widget_rect
}

padding_all :: proc "contextless" (value:f32) -> [4]f32 {return {value,value,value,value}}
padding_xy :: proc "contextless" (x,y:f32) -> [4]f32 {return {x,y,x,y}}

// The layer a floating container is placed in: its own, or the one it was
// declared in when it hangs from its parent or names no layer.
@(private)
float_layer :: proc "contextless" (f:Float,current:i16) -> i16 {
    if f.to==.None {return current}
    if f.to==.Parent && f.layer==0 {return current}
    return f.layer
}

// Opens a container; what is built until the matching box_end is inside it.
// As `if box(ctx,{...}) {...}` it closes itself at the end of the block.
@(deferred_in=box_scope_end)
box :: proc(ctx:^Context,b:Box) -> bool {
    box_begin(ctx,b)
    return true
}
@(private)
box_scope_end :: proc(ctx:^Context,b:Box) {box_end(ctx,b)}

box_begin :: proc(ctx:^Context,b:Box) {
    identifier:=b.id
    if b.layer.enabled && identifier==0 {identifier=id(ctx,"composition",ctx.elements+1)}
    element:=Element{id=identifier,layout=b.layout,row_span=b.row_span,row_tracks=b.row_tracks,float=b.float,contain=b.contain,inset=b.inset,from=b.from}
    if b.float.to!=.None {layer_push(ctx,float_layer(b.float,ctx.layer))}
    paint:Paint
    if b.image.kind!=.Solid {
        paint=image_paint({quad=b.image,tint=b.fill,border=b.image_border,border_uv=b.image_border_uv,fit=b.image_fit,size=b.image_size})
    } else {
        paint={kind=.Bar if b.fill2[3]>0 && b.radius==0 && b.corners=={} && b.stroke_width==0 && !b.shadow else .Panel if b.stroke[3]>0 || b.shadow else .Rect,fill=b.fill,fill2=b.fill2,gradient=b.gradient,stroke=b.stroke,radius=b.radius,corners=b.corners,shadow=b.shadow,stroke_width=b.stroke_width,shadow_color=b.shadow_color,shadow_blur=b.shadow_blur,shadow_offset=b.shadow_offset,
            program=b.program,program_values=b.program_values}
    }
    pp:^Paint
    if b.layer.enabled || b.image.kind!=.Solid || b.fill[3]>0 || b.fill2[3]>0 || b.stroke[3]>0 || b.shadow || b.program!=0 {
        paint.layer=b.layer
        pp=paint_add(ctx,paint)
        element.custom=pp
        if pp!=nil && b.layer.enabled {
            pp.clip_data.paint=pp
            element.user_data=&pp.clip_data
            // The transparent border is the end marker the implementation
            // places after the layer's content.
            element.border=1
        }
    }
    clips:=b.clip_x || b.clip_y
    if clips && b.id!=0 && ctx.skipped==0 {
        if ctx.clip_count>=len(ctx.clips) || ctx.clip_depth>=len(ctx.clip_stack) {
            ctx.stats.dropped_clips+=1
            clips=false
        } else {
            index:=u16(ctx.clip_count)
            ctx.clips[index]={id=b.id,parent=ctx.clip_stack[ctx.clip_depth-1] if ctx.clip_depth>0 else 0,surface=ctx.surface,scope=ctx.scope}
            ctx.clip_count+=1
            element.clip={x=b.clip_x,y=b.clip_y,scroll=b.scroll,floats=b.clip_floats && (b.clip_x || b.clip_y)}
            element.user_data=&ctx.clips[index]
            ctx.clips[index].paint=pp if b.layer.enabled else nil
        }
    } else {clips=false}
    own_effect:u16
    kept:=(b.layer.enabled || b.float.to!=.None) && effect_push(ctx)
    if kept && b.float.to!=.None {ctx.effect_clip=0;ctx.effect_refused=0}
    if kept && b.layer.enabled {
        if ctx.effect_count<len(ctx.effects) {
            index:=u16(ctx.effect_count);ctx.effect_count+=1
            ctx.effects[index]={id=identifier,parent=ctx.effect_clip,scope=ctx.scope,radius=b.layer.radius,opacity=b.layer.opacity,suppressed=ctx.surface!=0 || pp==nil}
            ctx.effect_clip=index;own_effect=index
        } else {ctx.effect_refused+=1}
    }
    if pp!=nil {pp.effect_clip=own_effect}
    opened:=false
    if b.layer.enabled && pp==nil {
        // Without a Paint the Begin/End markers cannot be emitted. Skips the
        // whole box so its children do not leak into the parent surface.
        ctx.skipped+=1;ctx.stats.dropped_layers+=1
    } else {
        if b.block || b.track {widget_add(ctx,b.id,{.Block} if b.block else {.Passive})}
        opened=element_open(ctx,element)
    }
    // A clip is pushed for a container that exists; box_end pops the same one.
    if clips {
        if opened {ctx.clip_stack[ctx.clip_depth]=u16(ctx.clip_count-1);ctx.clip_depth+=1} else {ctx.clip_count-=1}
    }
}
box_end :: proc(ctx:^Context,b:Box) {
    skipped:=ctx.skipped>0
    element_close(ctx)
    if (b.clip_x || b.clip_y) && b.id!=0 && !skipped && ctx.clip_depth>0 && ctx.clips[ctx.clip_stack[ctx.clip_depth-1]].id==b.id {ctx.clip_depth-=1}
    if b.float.to!=.None {layer_pop(ctx)}
    if b.layer.enabled || b.float.to!=.None {effect_pop(ctx)}
}

// Room between elements: a negative size grows to take what is left.
spacer :: proc(ctx:^Context,width:f32=-1,height:f32=-1) {
    element_leaf(ctx,{layout={width=GROW if width<0 else fixed(width),height=GROW if height<0 else fixed(height)}})
}
// A one unit line across its parent.
divider :: proc(ctx:^Context) {
    paint:=paint_add(ctx,{kind=.Rect,fill=tone(ctx,"divider")})
    element_leaf(ctx,{layout={width=GROW,height=fixed(1)},custom=paint})
}
