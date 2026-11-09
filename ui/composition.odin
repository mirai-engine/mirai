package ui

// The list keeps the draw order. Each Begin/End pair is an isolated
// transparent surface: the opacity is applied once.
COMPOSITION_DEPTH :: 8
@(private)
Composition_Entry :: struct {accepted,suppressed:bool,layer:u16,scissor:Rect}

@(deferred_in=composition_scope_end)
composition :: proc(ctx:^Context,bounds:Rect,style:Layer_Style) -> bool {
    composition_begin(ctx,bounds,style)
    return true
}
@(private)
composition_scope_end :: proc(ctx:^Context,bounds:Rect,style:Layer_Style) {composition_end(ctx)}

// Always requires composition_end, even when dropped for capacity.
// A dropped subtree does not leak its draws into its parent.
composition_begin :: proc(ctx:^Context,bounds:Rect,style:Layer_Style) {
    d:=&ctx.draw
    if d.composition_depth>=COMPOSITION_DEPTH || d.skipped_layers>0 {
        d.skipped_layers+=1;d.suppressed+=1;d.dropped_layers+=1
        return
    }
    entry:=Composition_Entry{}
    if !style.enabled { // scope without effect: keeps the direct draw path
        entry.accepted=false
        d.composition_stack[d.composition_depth]=entry;d.composition_depth+=1
        return
    }
    valid:=d.layered && d.scope[0,1]==0 && d.scope[1,0]==0
    // Reserves the End of the open layers and the Begin/End of this one.
    if valid && d.suppressed==0 && d.layer_count<len(d.layers) && d.command_count+d.accepted_layers+2<=len(d.commands) {
        screen:=rect_through(d.m,bounds)
        s:=max(abs(d.m[0,0]),abs(d.m[1,1]))
        index:=u16(d.layer_count)
        d.layers[d.layer_count]={bounds=screen,radius=clamp(style.radius*s,0,min(screen.w,screen.h)*0.5),opacity=clamp(style.opacity,0,1),backdrop_blur=clamp(style.backdrop_blur*s,0,64)}
        d.layer_count+=1
        d.commands[d.command_count]={kind=.Begin_Layer,layer=index,first=u32(d.count),scissor=draw_scissor(d),surface=d.surface}
        d.command_count+=1;d.accepted_layers+=1;d.dirty=true
        entry={accepted=true,layer=index,scissor=draw_scissor(d)}
    } else {
        d.dropped_layers+=1;d.suppressed+=1;entry.suppressed=true
    }
    d.composition_stack[d.composition_depth]=entry;d.composition_depth+=1
}
composition_end :: proc(ctx:^Context) {
    d:=&ctx.draw
    if d.skipped_layers>0 {d.skipped_layers-=1;d.suppressed-=1;return}
    if d.composition_depth<=0 {return}
    d.composition_depth-=1
    entry:=d.composition_stack[d.composition_depth]
    if entry.accepted {
        d.commands[d.command_count]={kind=.End_Layer,layer=entry.layer,first=u32(d.count),scissor=entry.scissor,surface=d.surface}
        d.command_count+=1;d.accepted_layers-=1;d.dirty=true
    } else if entry.suppressed {d.suppressed-=1}
}
// Ends the layers still open: what a frame leaves without its end.
@(private)
compositions_close :: proc(ctx:^Context) {
    d:=&ctx.draw
    for d.composition_depth>0 || d.skipped_layers>0 {composition_end(ctx)}
}
