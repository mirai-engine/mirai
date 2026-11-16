package ui

import "core:mem"
import "mirai:std/base"

// Subtrees the context draws again from what they drew, without building
// them: an interface whose values, size and asset did not change and that no
// input reaches. retained_begin says whether to build it; when it does not,
// the geometry, the shapes and the widgets of its last build come back in
// the layers it drew them in, and the pointer and navigation find its widgets
// where they were. Only what floats can be kept: a subtree that lays out in
// the flow of another, or uses composition layers, transforms, effects or
// world panels, is built every frame.

RETAINED_CAPACITY :: 32

@(private)
Retained_Command :: struct {count:u32,scissor:Rect}
// What one floating root of the subtree drew, in the layer it was drawn in.
@(private)
Retained_Segment :: struct {
    layer:i16,
    first_command,commands:int,
    first_vertex,first_shape,shapes:int,
}
@(private)
Retained :: struct {
    id:Id,
    key:u64,
    valid:bool,      // what it holds can be drawn again
    capturable:bool, // its build this frame can be kept
    built:bool,      // built this frame: frame_end keeps what it drew
    frame:u64,       // the last frame it was built or drawn again
    size:[2]f32,
    scale,density:f32,
    atlas:[2]int,    // of the font, when it was kept: glyphs move when it grows
    vertices:[dynamic]Vertex,  // quads of shapes name them from the first shape of their segment
    shapes:[dynamic]Shape,
    commands:[dynamic]Retained_Command,
    segments:[dynamic]Retained_Segment,
    widgets:[dynamic]Widget,
    links:[dynamic]Focus_Link,
    groups:[dynamic]Focus_Group,
    widget_first,link_first,group_first:int, // where its entries began in this frame
    widget_last,link_last,group_last:int,    // and ended
    hot,focus:Id,    // as they were when it was built: hovered or focused, it was kept that way
}

@(private)
retained_find :: proc(ctx:^Context,id:Id) -> ^Retained {
    free:^Retained
    for &r in ctx.retained {
        if r.id==id {return &r}
        if free==nil && (r.id==0 || r.frame+2<ctx.stats.frame) {free=&r}
    }
    if free==nil {return nil}
    vertices,shapes,commands,segments,widgets,links,groups:=free.vertices,free.shapes,free.commands,free.segments,free.widgets,free.links,free.groups
    clear(&vertices);clear(&shapes);clear(&commands);clear(&segments);clear(&widgets);clear(&links);clear(&groups)
    free^={id=id,vertices=vertices,shapes=shapes,commands=commands,segments=segments,widgets=widgets,links=links,groups=groups}
    return free
}

retained_destroy :: proc(ctx:^Context) {
    for &r in ctx.retained {
        delete(r.vertices);delete(r.shapes);delete(r.commands);delete(r.segments);delete(r.widgets);delete(r.links);delete(r.groups)
        r={}
    }
}

// Whether what was kept reaches the input of this frame: the pointer comes
// over one of its widgets or leaves it, a press or the wheel over them, the
// focus moves in or out of it, or keys that may bring it.
@(private)
retained_touched :: proc(ctx:^Context,r:^Retained) -> bool {
    if ctx.drag.id!=0 || ctx.popup.count>0 {return true}
    in_:=&ctx.input
    keys:=in_.keys_pressed!={} || in_.keys_repeated!={} || in_.pad!={} || in_.text_count>0
    pointer:=!in_.pointer_absent && (in_.pressed!={} || in_.released!={} || in_.wheel!={})
    focus:=ctx.focus if ctx.focus_ring else 0
    for &w in r.widgets {
        if (w.id==ctx.hot)!=(w.id==r.hot) || (w.id==focus)!=(w.id==r.focus) {return true}
        if w.id==ctx.active || w.id==ctx.edit.id || w.id==ctx.tooltip_hot || w.id==ctx.activate {return true}
        if keys && .Focusable in w.flags {return true}
        if pointer && rect_contains(w.area,ctx.screen_pointer) {return true}
    }
    return false
}

// Whether to build the subtree id: false when what it drew with this key is
// drawn again instead. A subtree is not kept inside another. Call
// retained_end after building it.
retained_begin :: proc(ctx:^Context,id:Id,key:u64) -> (build:bool) {
    if ctx.retaining!=0 {return true}
    r:=retained_find(ctx,id)
    if r==nil {return true}
    same:=r.valid && r.key==key && r.size==ctx.size && r.scale==ctx.scale && r.density==ctx.font.density && r.atlas=={ctx.font.width,ctx.font.height}
    if same && !retained_touched(ctx,r) {
        r.frame=ctx.stats.frame
        retained_replay(ctx,r)
        return false
    }
    r.key,r.valid,r.built,r.capturable=key,false,true,true
    r.frame=ctx.stats.frame
    r.size,r.scale,r.density,r.atlas=ctx.size,ctx.scale,ctx.font.density,{ctx.font.width,ctx.font.height}
    r.widget_first,r.link_first,r.group_first=ctx.widget_count,ctx.link_count,ctx.group_count
    r.hot,r.focus=ctx.hot,ctx.focus if ctx.focus_ring else 0
    ctx.retaining=u8(mem.ptr_sub(r,&ctx.retained[0]))+1
    return true
}

retained_end :: proc(ctx:^Context,id:Id) {
    if ctx.retaining==0 {return}
    r:=&ctx.retained[ctx.retaining-1]
    ctx.retaining=0
    if r.id!=id {return}
    r.widget_last,r.link_last,r.group_last=ctx.widget_count,ctx.link_count,ctx.group_count
    clear(&r.vertices);clear(&r.shapes);clear(&r.commands);clear(&r.segments)
}

// Its widgets and its drawings again: an element of no size where each of
// its roots was, in the same layer, draws what that root drew.
@(private)
retained_replay :: proc(ctx:^Context,r:^Retained) {
    index:=u64(mem.ptr_sub(r,&ctx.retained[0]))
    for &w in r.widgets {
        if ctx.widget_count>=len(ctx.widgets) {ctx.stats.dropped_widgets+=1;break}
        kept:=w
        kept.flags+={.Kept}
        ctx.widgets[ctx.widget_count]=kept
        ctx.widget_count+=1
    }
    for link in r.links {
        if ctx.link_count<len(ctx.links) {ctx.links[ctx.link_count]=link;ctx.link_count+=1}
    }
    for group in r.groups {
        if ctx.group_count<len(ctx.groups) {ctx.groups[ctx.group_count]=group;ctx.group_count+=1}
    }
    for &segment,i in r.segments {
        paint:=paint_add(ctx,{kind=.Replay,user_data=index<<32|u64(i)})
        element_leaf(ctx,{layout={width=fixed(0),height=fixed(0)},float={to=.Surface,layer=segment.layer},custom=paint})
    }
}

// Draws a segment of what was kept.
@(private)
retained_draw :: proc(ctx:^Context,data:u64) {
    r:=&ctx.retained[data>>32]
    if int(data&0xffffffff)>=len(r.segments) {return}
    segment:=r.segments[data&0xffffffff]
    d:=&ctx.draw
    first_shape:=d.shape_count
    if d.shape_count+segment.shapes>len(d.shapes) {d.dropped_shapes+=u32(segment.shapes);return}
    copy(d.shapes[d.shape_count:],r.shapes[segment.first_shape:][:segment.shapes])
    d.shape_count+=segment.shapes
    at:=segment.first_vertex
    for c in r.commands[segment.first_command:][:segment.commands] {
        n:=int(c.count)
        if d.count+n>len(d.vertices) || d.region.data!=nil && !base_region_commit(d,n) || d.command_count>=len(d.commands)-d.accepted_layers {
            d.dropped_vertices+=u32(n)
            at+=n
            continue
        }
        d.commands[d.command_count]={first=u32(d.count),count=c.count,scissor=c.scissor,surface=0}
        d.command_count+=1
        out:=d.vertices[d.count:][:n]
        copy(out,r.vertices[at:][:n])
        for &v in out {
            if kind:=quad_kind(v.quad);kind==.Shape || kind==.Program {v.quad=quad_pack(kind,quad_data(v.quad)+u32(first_shape))}
        }
        d.count+=n
        at+=n
    }
    d.dirty,d.split=true,true
}

// What a root of the subtree being kept drew, from where the draw was when
// the root began: its vertices with their shapes counted from its first.
@(private)
retained_capture :: proc(ctx:^Context,retained:u8,layer:i16,first_command,first_shape,first_layer:int) {
    r:=&ctx.retained[retained-1]
    if !r.built || !r.capturable {return}
    d:=&ctx.draw
    if d.layer_count!=first_layer {r.capturable=false;return}
    segment:=Retained_Segment{layer=layer,first_command=len(r.commands),first_vertex=len(r.vertices),first_shape=len(r.shapes),shapes=d.shape_count-first_shape}
    append(&r.shapes,..d.shapes[first_shape:d.shape_count])
    for &c in d.commands[first_command:d.command_count] {
        if c.kind!=.Triangles || c.surface!=0 {r.capturable=false;return}
        append(&r.commands,Retained_Command{c.count,c.scissor})
        start:=len(r.vertices)
        append(&r.vertices,..d.vertices[c.first:][:c.count])
        for &v in r.vertices[start:] {
            if kind:=quad_kind(v.quad);kind==.Shape || kind==.Program {v.quad=quad_pack(kind,quad_data(v.quad)-u32(first_shape))}
        }
    }
    segment.commands=len(r.commands)-segment.first_command
    append(&r.segments,segment)
}

// After the frame is drawn: what was built and could be kept is valid, with
// its widgets where the layout placed them.
@(private)
retained_frame_end :: proc(ctx:^Context) {
    for &r in ctx.retained {
        if !r.built {continue}
        r.built=false
        clear(&r.widgets);clear(&r.links);clear(&r.groups)
        for w in ctx.widgets[r.widget_first:r.widget_last] {
            // Hit testing inside a transform or an effect needs what only a build has.
            if w.scope!=0 || w.effect_clip!=0 || w.surface!=0 {r.capturable=false;break}
            append(&r.widgets,w)
        }
        // The pieces of its texts that took the pointer on other lines than their first.
        for w in ctx.widgets[ctx.widget_pieces:ctx.widget_count] {
            if r.capturable && int(w.piece_of)>r.widget_first && int(w.piece_of)<=r.widget_last {append(&r.widgets,w)}
        }
        append(&r.links,..ctx.links[r.link_first:r.link_last])
        append(&r.groups,..ctx.groups[r.group_first:r.group_last])
        r.valid=r.capturable && len(r.segments)>0
    }
}

@(private)
base_region_commit :: proc(d:^Draw,n:int) -> bool {
    return base.region_commit(&d.region,(d.count+n)*size_of(Vertex))
}
