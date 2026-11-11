package ui

// A container as the layout reads it. Widgets describe their element with one
// of these; the layout of the frame (layout_tree.odin) places it.
Element :: struct {
    id:Id,
    layout:Layout,
    float:Float,
    contain:bool,     // floating: kept inside its surface (Box.contain)
    clip:Element_Clip,
    custom:rawptr,    // the Paint drawn for the container
    user_data:rawptr, // the Clip that closes its scissor, or the paint of its end marker
    border:u16,       // width of the transparent border that marks the end of a layer
}

// A container that clips what overflows it, and how far its content is moved
// inside: the offset a scroll area holds.
Element_Clip :: struct {x,y:bool,scroll:[2]f32,floats:bool}

// The first element of a frame starts its layout: a frame that only draws
// lays nothing out.
@(private)
layout_start :: proc(ctx:^Context) {
    if ctx.layout_started {return}
    layout_begin(&ctx.layout,ctx.size)
    ctx.layout_started=true
}

@(private)
element_open :: proc(ctx:^Context,e:Element) -> bool {
    // What a retained subtree lays out in the flow of the surface cannot be drawn apart.
    if ctx.retaining!=0 && e.float.to==.None && ctx.layout.open_len<=1 {ctx.retained[ctx.retaining-1].capturable=false}
    refused:=ctx.skipped>0 || ctx.elements+ELEMENT_RESERVE>=ctx.max_elements
    if !refused {
        layout_start(ctx)
        refused=!layout_open(&ctx.layout,e,element_float(ctx,e.float,e.contain))
    }
    if refused {
        if ctx.skipped==0 {ctx.stats.dropped_elements+=1}
        ctx.skipped+=1
        return false
    }
    ctx.elements+=1
    return true
}
@(private)
element_close :: proc(ctx:^Context) {
    if ctx.skipped>0 {ctx.skipped-=1;return}
    layout_close(&ctx.layout)
}
// An element without children.
@(private)
element_leaf :: proc(ctx:^Context,e:Element) {
    element_open(ctx,e)
    element_close(ctx)
}
// A run of text the layout measures and breaks into lines, drawn with paint.
@(private)
element_text :: proc(ctx:^Context,paint:^Paint,text:string,size:f32) {
    layout_start(ctx)
    if !layout_text(&ctx.layout,&ctx.font,text,size,paragraph_line(size,paint.style.line_height),u8(paint.style.font),paint) {ctx.stats.dropped_elements+=1;return}
    ctx.elements+=1
}

// What a floating container hangs from. A world panel is a surface of its
// own: what floats on its surface hangs from the panel. Root is the root of
// the layout, the one a world panel itself hangs from. The safe area is the
// surface less its insets, so what hangs from it hangs from the same point of
// the surface, moved by the inset of that side.
@(private)
element_float :: proc "contextless" (ctx:^Context,f:Float,contain:bool) -> Layout_Float {
    if f.to==.None {return {}}
    out:=Layout_Float{to=.Root,anchor=f.anchor,pivot=f.pivot,offset=f.offset,layer=float_layer(f,ctx.layer),retained=ctx.retaining,contain=contain}
    // What stays inside its surface stays inside the panel, or the part of the window of a player.
    if contain {out.within=ctx.panels[ctx.surface-1].id if ctx.surface!=0 else ctx.area}
    switch {
    case f.to==.Parent:
        out.to=.Parent
    case ctx.surface!=0 && (f.to==.Surface || f.to==.Safe):
        out.to=.Parent
        out.parent=ctx.panels[ctx.surface-1].id
    case ctx.area!=0 && (f.to==.Surface || f.to==.Safe):
        out.to=.Parent
        out.parent=ctx.area
        if f.to==.Safe {
            // The safe area inside the area, from its corner.
            a,s:=ctx.area_rect,ctx.safe
            x0,y0:=max(s.x,a.x)-a.x,max(s.y,a.y)-a.y
            w,h:=max(min(s.x+s.w,a.x+a.w)-a.x-x0,0),max(min(s.y+s.h,a.y+a.h)-a.y-y0,0)
            column,row:=int(f.anchor)/3,int(f.anchor)%3
            out.offset.x+=[3]f32{x0,x0+w*0.5-a.w*0.5,x0+w-a.w}[column]
            out.offset.y+=[3]f32{y0,y0+h*0.5-a.h*0.5,y0+h-a.h}[row]
        }
    case f.to==.Safe:
        column,row:=int(f.anchor)/3,int(f.anchor)%3
        s:=ctx.safe
        out.offset.x+=[3]f32{s.x,s.x+s.w*0.5-ctx.size.x*0.5,s.x+s.w-ctx.size.x}[column]
        out.offset.y+=[3]f32{s.y,s.y+s.h*0.5-ctx.size.y*0.5,s.y+s.h-ctx.size.y}[row]
    }
    return out
}

// What a scissor command of the layout became: a scissor on screen, or a clip
// of the geometry of a world panel, which has no scissor of its own.
@(private)
Scissor_Kind :: enum u8 {None,Scissor,Clip}

// Turns what the layout lists into geometry, in the order it is drawn.
@(private)
layout_paint :: proc(ctx:^Context) {
    kinds:[SCISSOR_DEPTH]Scissor_Kind
    depth:=0
    excess:=0 // scissors nested deeper than SCISSOR_DEPTH, which are not applied
    t:=&ctx.layout
    // Where the draw was when the root being drawn began, for a retained subtree.
    root_cursor:=0
    current:Layout_Root
    clipped:=false // the root drawn is cut by the box it floats in
    started:[3]int
    for command,command_index in t.commands[:t.command_count] {
        for root_cursor<t.root_count && int(t.roots[root_cursor].first_command)<=command_index {
            // A retained root draws in commands of its own.
            if current.retained!=0 || t.roots[root_cursor].retained!=0 {ctx.draw.dirty,ctx.draw.split=true,true}
            if current.retained!=0 {retained_capture(ctx,current.retained,current.layer,started[0],started[1],started[2])}
            if clipped {scissor_pop(ctx);clipped=false}
            current=t.roots[root_cursor]
            root_cursor+=1
            // A root that floats inside a box that cuts what floats in it is cut by that box.
            // Each box around it that cuts what floats cuts it too: the box it
            // floats in may reach past the one that holds that box.
            if current.clip>0 {
                if clip:=cast(^Clip)t.nodes[current.clip].user_data;clip!=nil && clip.surface==0 {
                    paint_select(ctx,clip.surface,clip.scope)
                    cut:=t.nodes[current.clip].box
                    for outer:=t.nodes[current.clip].clip_outer;outer>0;outer=t.nodes[outer].clip_outer {cut=rect_intersect(cut,t.nodes[outer].box)}
                    scissor_push(ctx,cut)
                    clipped=true
                }
            }
            started={ctx.draw.command_count,ctx.draw.shape_count,ctx.draw.layer_count}
        }
        n:=&t.nodes[command.node]
        r:=n.box
        switch command.kind {
        case .Custom:
            p:=cast(^Paint)n.custom
            if p.hidden {continue}
            paint_select(ctx,p.surface,p.scope)
            if p.layer.enabled {
                composition_begin(ctx,r,p.layer)
                if p.effect_clip!=0 {ctx.effects[p.effect_clip].suppressed=ctx.draw.suppressed>0}
            }
            paint_draw(ctx,r,p)
        case .Border:
            // The end marker of a composition layer, listed after its content.
            if data:=cast(^Clip)n.user_data;data!=nil && data.paint!=nil && data.paint.layer.enabled {
                focus_ring_draw(ctx,data.paint.effect_clip)
                composition_end(ctx)
            }
        case .Text:
            text,line,run:=layout_line(t,command)
            if p:=cast(^Paint)n.custom;p!=nil && !p.hidden {
                paint_select(ctx,p.surface,p.scope)
                draw_text_decorated(ctx,text,line.x,line.y+text_leading(run.size,run.line_height),p.style)
            }
        case .Scissor_Start:
            if depth>=SCISSOR_DEPTH {excess+=1;ctx.stats.dropped_clips+=1;continue}
            kinds[depth]=.None
            if clip:=cast(^Clip)n.user_data;clip!=nil {
                paint_select(ctx,clip.surface,clip.scope)
                if clip.surface==0 {scissor_push(ctx,r);kinds[depth]=.Scissor} else {clip_push(ctx,r);kinds[depth]=.Clip}
            }
            depth+=1
        case .Scissor_End:
            if excess>0 {excess-=1;continue}
            if depth<=0 {continue}
            depth-=1
            layout_paint_unclip(ctx,kinds[depth])
        }
    }
    // A layer whose end marker did not fit in the commands of the layout.
    compositions_close(ctx)
    for depth>0 {
        depth-=1
        layout_paint_unclip(ctx,kinds[depth])
    }
    if clipped {scissor_pop(ctx)}
    if current.retained!=0 {
        retained_capture(ctx,current.retained,current.layer,started[0],started[1],started[2])
        ctx.draw.dirty,ctx.draw.split=true,true
    }
}
@(private)
layout_paint_unclip :: proc(ctx:^Context,kind:Scissor_Kind) {
    #partial switch kind {
    case .Scissor: scissor_pop(ctx)
    case .Clip: clip_pop(ctx)
    }
}
