package ui

import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "mirai:std/base"

// What each kind of node of a tree builds when it holds no other nodes, how
// a node takes part in navigation and how it is dragged and dropped. The
// controls are those of a game (game.odin), in the parts of the style the
// node resolves to.

@(private)
tree_build_leaf :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,slot:int,node_id:Id,values:rawptr,item:i32,base_style,style:^Node_Style,variant:u64,image_ref:Node_Image,content:string,selected,disabled:bool,anim:^Anim_Value) {
    tree,instance:=b.tree,b.instance
    bound:=&instance.bounds[index]
    ctx.order=node.order
    defer ctx.order=0
    focusable:=false
    #partial switch node.kind {
    case .Button,.Checkbox,.Slider,.Number,.Field,.Selector,.Dropdown,.Radio:focusable=true
    }
    if focusable && .Focus_First in node.flags && !b.desc.passive && !disabled {
        if _,held:=widget_rect(ctx,ctx.focus);ctx.focus==0 || !held || b.turned {
            ctx.focus,ctx.focus_ring=node_id,true
            b.turned=false
        }
    }
    if .Draggable in node.flags {tree_drag_source(ctx,b,node,index,node_id,item)}
    defer if .Draggable in node.flags {tree_drag_ghost(ctx,b,node,index,node_id,values,slot-int(instance.slots[index]),item)}
    changed :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index:int,item:i32,style:^Node_Style,value:f64,on:=false) {
        tree_emit(b,{name=node.name,node=i32(index),kind=.Changed,item=item,value=value,on=on})
        tree_sound(ctx,style,.Change)
    }
    control:=Game_Control{style=style,width=node.layout.width,height=node.layout.height,disabled=disabled}
    // What a Progress, a Slider or a Number shows: its value, or that of its animation.
    current:=bound_number(values,bound.value) if bound.value.bound else 0
    shown:=f64(anim.value) if anim!=nil && .Value in anim.set else current
    reveal:=anim.reveal if anim!=nil && .Reveal in anim.set else 1
    #partial switch node.kind {
    case .Text:
        text(ctx,content,style.text,node.layout.width,node.layout.height,node_id,reveal)
    case .Image:
        image(ctx,{id=node_id,quad=image_ref.quad,tint=style.fill,width=node.layout.width,height=node.layout.height,border=image_ref.border,border_uv=image_ref.border_uv,fit=image_ref.fit,size=image_ref.size})
    case .Progress:
        progress(ctx,{id=node_id,value=f32(shown),width=node.layout.width,height=node.layout.height,
            fill=style.fill,track=style.track,stroke=style.stroke,corners=style.radius,quad=image_ref.quad,border=image_ref.border,border_uv=image_ref.border_uv,
            fill_mode=style.fill_mode,stroke_width=style.stroke_width,program=tree.programs[node.style] if int(node.style)<len(tree.programs) else 0,program_values=style.program_values})
    case .Button:
        tree_button(ctx,b,node,index,slot,node_id,item,base_style,style,image_ref,content,selected,disabled)
    case .Checkbox:
        value:=bound.value.bound && current!=0
        if game_checkbox(ctx,node_id,&value,control) {
            bound_write(values,bound.value,1 if value else 0)
            changed(ctx,b,node,index,item,base_style,1 if value else 0,value)
        }
    case .Spacer:
        element_leaf(ctx,{layout={width=node.layout.width,height=node.layout.height}})
    case .Prompt:
        prompt(ctx,node_id,node.action,style.text,node.layout)
    case .Slider,.Number:
        lo,hi,step:=f64(node.range[0]),f64(node.range[1]),f64(node.range[2])
        if !bound.value.bound && hi>lo {current=lo}
        value:=f64(anim.value) if anim!=nil && .Value in anim.set else current
        moved:bool
        if node.kind==.Slider {moved=game_slider(ctx,node_id,&value,{lo,hi,step},control)} else {moved=game_number(ctx,node_id,&value,{lo,hi,step},control)}
        if bound.value.kind==.Int || bound.value.kind==.Uint {value=math.round(value)}
        if moved && value!=current {
            bound_write(values,bound.value,value)
            changed(ctx,b,node,index,item,base_style,value)
        }
        if ctx.active==node_id || ctx.edit.id==node_id {b.animating=true}
    case .Field:
        tree_field(ctx,b,node,index,node_id,values,item,base_style,control)
    case .Selector,.Dropdown:
        options:=tree_options(b,index,values,content)
        chosen:=int(current) if bound.value.bound else int(instance.slot[slot].held)
        next:=chosen
        if node.kind==.Selector {game_selector(ctx,node_id,options,&next,control)} else {
            game_dropdown(ctx,node_id,options,&next,control)
            if popup_is_open(ctx,id_derive(ctx,node_id,"list")) {b.animating=true}
        }
        if next!=chosen {
            if bound.value.bound {bound_write(values,bound.value,f64(next))} else {instance.slot[slot].held=f32(next)}
            changed(ctx,b,node,index,item,base_style,f64(next))
        }
    case .Radio:
        chosen:=bound.value.bound && int(current)==int(node.choice) || !bound.value.bound && selected
        if game_radio(ctx,node_id,chosen,control) && !chosen {
            bound_write(values,bound.value,f64(node.choice))
            changed(ctx,b,node,index,item,base_style,f64(node.choice))
        }
    case .Rich_Text:
        if link:=rich_text(ctx,node_id,content,style.text,node.layout,tree.images[:tree.image_count],style.mark,reveal);link!=0 {
            tree_emit(b,{name=node.name,node=i32(index),kind=.Link,item=item,from=link})
        }
    case .View:
        quad:Quad
        size:=[2]f32{node.layout.width.value,node.layout.height.value}
        if r,found:=widget_rect(ctx,node_id);found {size={r.w,r.h}}
        if bound.value.bound && ctx.game.view!=nil {
            if camera:=bound_entity(values,bound.value);camera!={} && size.x>0 && size.y>0 {quad=ctx.game.view(ctx.game.user,camera,size)}
        }
        image(ctx,{id=node_id,quad=quad,tint=style.fill if style.fill[3]>0 else {255,255,255,255},width=node.layout.width,height=node.layout.height})
    case .Action_Bar:
        tree_action_bar(ctx,instance,node_id,style.text,node.layout)
    case .Particles:
        quad:Quad
        size:=[2]f32{node.layout.width.value,node.layout.height.value}
        if r,found:=widget_rect(ctx,node_id);found {size={r.w,r.h}}
        if node.particle!={} && ctx.game.particles!=nil && size.x>0 && size.y>0 {quad=ctx.game.particles(ctx.game.user,node_id,node.particle,size)}
        tint:=style.fill if style.fill[3]>0 else Color{255,255,255,255}
        image(ctx,{id=node_id,quad=quad,tint=tint if quad!={} else {},width=node.layout.width,height=node.layout.height})
    }
    tree_drop_target(ctx,b,node,index,node_id,item)
}

// The options of a Selector or a Dropdown: the elements of the array its
// items bind, whose enums its text maps to what they show, or its text
// separated by '|', each a translation when the node is localized.
@(private)
tree_options :: proc(b:^Tree_Build,index:int,values:rawptr,content:string) -> Options {
    o:=&b.instance.bounds[index].options
    if !o.bound {return {joined=content}}
    options:=Options{array=rawptr(uintptr(values)+uintptr(o.offset)),count=int(o.count),stride=int(o.stride)}
    if o.elem==.Enum {options.size,options.names,options.joined=int(o.stride),bound_choices(o^),content}
    return options
}

// The text of the node itself, in the language of now, whatever it binds:
// the placeholder of a Field.
@(private)
tree_own_text :: proc(b:^Tree_Build,node:^Node,index:int) -> string {
    tree,instance:=b.tree,b.instance
    if .Localized in node.flags && index<len(instance.texts) {
        shown:=instance.texts[index]
        return string(tree.strings[shown.offset:][:shown.length])
    }
    return string(tree.strings[node.text_offset:][:node.text_length])
}

// A Button: clicked by the pointer, by navigation or by its action; with a
// hold, only once the pointer or the action has held it that long, while a
// bar of mark a fifth of its text tall fills along its bottom.
@(private)
tree_button :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,slot:int,node_id:Id,item:i32,base_style,style:^Node_Style,image_ref:Node_Image,content:string,selected,disabled:bool) {
    instance:=b.instance
    state:=&instance.slot[slot]
    it:=styled_button(ctx,node_id,content,style^,layout=node.layout,selected=selected,disabled=disabled,image_ref=image_ref)
    takes:=node.action!=0 && !b.desc.passive && !disabled
    down,pressed:bool
    if takes && ctx.game.action!=nil {down,pressed=ctx.game.action(ctx.game.user,node.action)}
    // A press of a fixed tick lasts for the frames of that tick: one clicks, and the button waits
    // for a frame with the action neither down nor pressed.
    if !down && !pressed {state.armed=true}
    if !state.armed {down,pressed=false,false}
    clicked:=false
    if node.hold>0 {
        holding:=down || it.active
        if !holding {state.held,state.latched=0,false}
        if holding && !state.latched {
            state.held+=ctx.input.dt
            b.animating=true
            if state.held>=node.hold {clicked,state.latched=true,true}
        }
        if state.held>0 && !state.latched {
            if r,found:=widget_rect(ctx,node_id);found {
                bar:=max(game_em(ctx,style)*0.2,1)
                element_leaf(ctx,{layout={width=fixed(r.w*clamp(state.held/node.hold,0,1)),height=fixed(bar)},float={to=.Surface,offset={r.x,r.y+r.h-bar},layer=ctx.layer+1},custom=paint_add(ctx,{kind=.Rect,fill=style.mark})})
            }
        }
    } else {
        clicked=it.clicked || pressed
        if pressed {state.armed=false}
    }
    if clicked {
        tree_emit(b,{name=node.name,node=i32(index),kind=.Clicked,item=item})
        tree_sound(ctx,base_style,.Press)
        state.clicked=true
    }
    if !takes {return}
    if instance.bar_next_count>=TREE_BAR {ctx.stats.dropped_tree+=1;return}
    entry:=&instance.bar_next[instance.bar_next_count]
    entry.action=node.action
    kept:=content
    if len(kept)>len(entry.text) {
        // Cut where a character starts.
        cut:=len(entry.text)
        for cut>0 && kept[cut]&0xc0==0x80 {cut-=1}
        kept=kept[:cut]
        ctx.stats.dropped_tree+=1
    }
    entry.length=u16(copy(entry.text[:],kept))
    instance.bar_next_count+=1
}

// A Field: its bound text, typed as an ASCII keyboard types, with its own
// text as the placeholder while it is empty.
@(private)
tree_field :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index:int,node_id:Id,values:rawptr,item:i32,base_style:^Node_Style,control:Game_Control) {
    bound:=b.instance.bounds[index].text
    buffer:[]u8
    if bound.bound && bound.text && values!=nil {buffer=([^]u8)(rawptr(uintptr(values)+uintptr(bound.offset)))[:bound.size]}
    scratch:[1]u8
    if buffer==nil {buffer=scratch[:]}
    length:=len(bound_bytes(values,bound)) if bound.bound && values!=nil else 0
    // The text keeps a zero after it.
    room:=buffer[:max(len(buffer)-1,0)]
    field:=Game_Field{control=control,placeholder=tree_own_text(b,node,index),limit=int(node.limit),multiline=.Multiline in node.flags,password=.Password in node.flags}
    field.disabled||=len(room)==0
    result:=game_field(ctx,node_id,room,&length,field)
    if result.editing {b.animating=true}
    if length<len(buffer) {buffer[length]=0}
    submitted:=result.committed && .Enter in ctx.input.keys_pressed
    if result.changed || submitted {
        event:=Tree_Event{name=node.name,node=i32(index),kind=.Changed,item=item}
        copy(event.text[:len(event.text)-1],string(buffer[:length]))
        if result.changed {
            tree_emit(b,event)
            tree_sound(ctx,base_style,.Change)
        }
        if submitted {
            event.kind=.Submitted
            tree_emit(b,event)
        }
    }
}

// The buttons of the tree its action clicks, as the last build found them:
// the prompt of each action and the text of its button.
@(private)
tree_action_bar :: proc(ctx:^Context,instance:^Tree_Instance,node_id:Id,style:Text_Style,layout:Layout) {
    row:=layout
    if row.gap==0 {row.gap=max(style.size,12)}
    if row.direction==.Column && layout.direction!=.Column {row.direction=.Row}
    row.align_y=.Center
    widget_add(ctx,node_id,{.Passive})
    if element_open(ctx,{id=node_id,layout=row}) {
        for &entry,i in instance.bar[:instance.bar_count] {
            if box(ctx,{layout={direction=.Row,gap=max(style.size,12)*0.4,align_y=.Center}}) {
                prompt(ctx,id_derive(ctx,node_id,"prompt",i+1),entry.action,style,{height=fixed(max(style.size,12)*1.5)})
                label:=text_store(ctx,string(entry.text[:entry.length]))
                text(ctx,label,style)
            }
        }
    }
    element_close(ctx)
}

// ---------------------------------------------------------------- navigation

// Where the focus goes from the node, by its links.
@(private)
tree_focus_links :: proc(ctx:^Context,node:^Node,node_id:Id) {
    if node.nav=={} || ctx.link_count>=len(ctx.links) {return}
    link:=Focus_Link{from=node_id}
    for name,side in node.nav {if name!=0 {link.to[side]=tree_name_id(ctx,name)}}
    ctx.links[ctx.link_count]=link
    ctx.link_count+=1
}

@(private)
tree_focus_group :: proc(ctx:^Context,node:^Node,node_id:Id) {
    if .Wrap_X not_in node.flags && .Wrap_Y not_in node.flags || ctx.group_count>=len(ctx.groups) {return}
    ctx.groups[ctx.group_count]={node_id,.Wrap_X in node.flags,.Wrap_Y in node.flags}
    ctx.group_count+=1
}

// ---------------------------------------------------------------- drag and drop

DRAG_DISTANCE :: f32(6) // layout units the pointer moves with the button down before a drag starts

// A node the pointer can drag: past DRAG_DISTANCE from where it was pressed
// on it, it is dragged with its tag and the tree reports Dragged.
@(private)
tree_drag_source :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index:int,node_id:Id,item:i32) {
    if b.desc.passive {return}
    it:=interact(ctx,node_id,{})
    if !it.active || ctx.drag.id!=0 {return}
    d:=ctx.pointer-ctx.press
    if d.x*d.x+d.y*d.y<DRAG_DISTANCE*DRAG_DISTANCE {return}
    r,_:=widget_rect(ctx,node_id)
    ctx.drag={id=node_id,name=node.name,tag=node.tag,item=item,owner=ctx.owner,node=i32(index),offset=ctx.press-{r.x,r.y},rect=r}
    tree_emit(b,{name=node.name,node=i32(index),kind=.Dragged,item=item})
}

// What follows the pointer while the node is dragged, built where the node
// is built: the node its ghost names, as it is even where the tree hides it,
// or a copy of the node at 80% of its opacity.
@(private)
tree_drag_ghost :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index:int,node_id:Id,values:rawptr,copy:int,item:i32) {
    if ctx.drag.id!=node_id || ctx.drag.owner!=ctx.owner || ctx.drag.dropped || b.ghost>=0 {return}
    b.animating=true
    tree:=b.tree
    built,at,at_copy,at_item:=index,values,copy,item
    if node.ghost!=0 {
        built=-1
        for &n,i in tree.nodes[:tree.node_count] {if n.name==node.ghost {built=i;break}}
        if built<0 {return}
        // Outside the node it reads from the root.
        if built<index || built>index+int(node.subtree) {at,at_copy,at_item=raw_data(b.instance.values),0,-1}
    }
    ghost:=id(ctx,"drag")
    offset:=ctx.pointer-ctx.drag.offset
    box:=Box{id=ghost,float={to=.Surface,offset=offset,layer=LAYER_TOOLTIP+1}}
    if node.ghost==0 {box.layout={width=fixed(ctx.drag.rect.w),height=fixed(ctx.drag.rect.h)};box.layer={enabled=true,opacity=0.8}}
    box_begin(ctx,box)
    id_push(ctx,ghost)
    unfocusable:=ctx.unfocusable
    ctx.unfocusable+=1
    b.ghost=built
    tree_build_node(ctx,b,built,at,at_copy,at_item)
    b.ghost=-1
    ctx.unfocusable=unfocusable
    id_pop(ctx)
    box_end(ctx,{id=ghost,float={to=.Surface}})
}

// Whether something dragged that the node accepts is over it.
@(private)
tree_drag_over :: proc(ctx:^Context,node:^Node,node_id:Id) -> bool {
    if ctx.drag.id==0 || ctx.drag.dropped || ctx.drag.id==node_id || node.accepts!=0 && node.accepts!=ctx.drag.tag {return false}
    r,found:=widget_rect(ctx,node_id)
    return found && rect_contains(r,ctx.pointer)
}

// A node that takes what is let go over it, when it accepts its tag, reports
// Dropped with what it was.
@(private)
tree_drop_target :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index:int,node_id:Id,item:i32) {
    if .Drop not_in node.flags || ctx.drag.id==0 || !ctx.drag.dropped || ctx.drag.id==node_id {return}
    if node.accepts!=0 && node.accepts!=ctx.drag.tag {return}
    r,found:=widget_rect(ctx,node_id)
    if !found || !rect_contains(r,ctx.pointer) {return}
    tree_emit(b,{name=node.name,node=i32(index),kind=.Dropped,item=item,from=ctx.drag.name,from_item=ctx.drag.item,from_owner=ctx.drag.owner})
    // The innermost target takes it: it is built before those that hold it.
    ctx.drag.id=0
}

// ---------------------------------------------------------------- rich text

RICH_SPANS :: 128 // spans of a rich text; the text past them is left out and counted in Stats.dropped_tree

@(private)
Rich_Span :: struct {
    text:string,
    style:Text_Style,
    decoration:Text_Decorations,
    prompt:u64, // an action: its prompts instead of text
    image:u64,  // the name of an image instead of text
    link:u64,   // the name a click on it reports
}

// Reads the markup of a rich text into spans: <b>, <i>, <u>, <s>,
// <color=#rrggbb[aa]>, <size=n> and <link=name> with their closing tags,
// <prompt=action> and <img=name>. What is not one of them is text. <b> takes
// the semibold face of the font of the application (FONT_SEMIBOLD) when the
// text is in a lighter one of it, and draws a synthetic bold in any other
// font. lost: the spans did not hold all of it.
@(private)
rich_parse :: proc(content:string,base_style:Text_Style,out:[]Rich_Span) -> (count:int,lost:bool) {
    Level :: struct {style:Text_Style,decoration:Text_Decorations,link:u64}
    stack:[8]Level
    depth:=0
    at:=Level{style=base_style}
    rest:=content
    add :: proc(out:[]Rich_Span,count:^int,span:Rich_Span) -> bool {
        if count^>=len(out) {return false}
        out[count^]=span;count^+=1
        return true
    }
    push :: proc(stack:^[8]Level,depth:^int,at:Level) {
        if depth^<len(stack) {stack[depth^]=at;depth^+=1}
    }
    for rest!="" {
        open:=strings.index_byte(rest,'<')
        if open!=0 {
            run:=rest if open<0 else rest[:open]
            if !add(out,&count,{text=run,style=at.style,decoration=at.decoration,link=at.link}) {return count,true}
            if open<0 {break}
            rest=rest[open:]
            continue
        }
        close:=strings.index_byte(rest,'>')
        if close<0 {
            if !add(out,&count,{text=rest,style=at.style,decoration=at.decoration,link=at.link}) {return count,true}
            break
        }
        tag:=rest[1:close]
        known:=true
        switch {
        case tag=="b":
            push(&stack,&depth,at)
            if at.style.font<FONT_SEMIBOLD {at.style.font=FONT_SEMIBOLD} else {at.decoration+={.Bold}}
        case tag=="i" || tag=="u" || tag=="s":
            push(&stack,&depth,at)
            at.decoration+={.Italic if tag=="i" else .Underline if tag=="u" else .Strike}
        case strings.has_prefix(tag,"color=#"):
            hex:=tag[len("color=#"):]
            value,ok:=strconv.parse_u64_of_base(hex,16)
            if !ok || len(hex)!=6 && len(hex)!=8 {known=false;break}
            push(&stack,&depth,at)
            if len(hex)==6 {value=value<<8|0xff}
            at.style.color={u8(value>>24),u8(value>>16),u8(value>>8),u8(value)}
        case strings.has_prefix(tag,"size="):
            size,ok:=strconv.parse_f32(tag[len("size="):])
            if !ok || size<=0 || size>512 {known=false;break}
            push(&stack,&depth,at)
            at.style.size=size
        case strings.has_prefix(tag,"link=") && len(tag)>len("link="):
            push(&stack,&depth,at)
            at.link=base.name_hash(tag[len("link="):])
        case strings.has_prefix(tag,"prompt="):
            if !add(out,&count,{style=at.style,prompt=base.name_hash(tag[len("prompt="):])}) {return count,true}
        case strings.has_prefix(tag,"img=") && len(tag)>len("img="):
            if !add(out,&count,{style=at.style,image=base.name_hash(tag[len("img="):]),link=at.link}) {return count,true}
        case tag=="/b" || tag=="/i" || tag=="/u" || tag=="/s" || tag=="/color" || tag=="/size" || tag=="/link":
            if depth>0 {depth-=1;at=stack[depth]}
        case:
            known=false
        }
        if !known {
            if !add(out,&count,{text=rest[:close+1],style=at.style,decoration=at.decoration,link=at.link}) {return count,true}
        }
        rest=rest[close+1:]
    }
    return count,false
}

// A run of a span on a line: its bytes, or its prompt or image.
@(private)
Rich_Piece :: struct {span,start,end:int,width:f32}
@(private)
Rich_Build :: struct {
    id:Id,
    spans:[]Rich_Span,
    line:[RICH_SPANS]Rich_Piece,
    pieces:int,
    used:f32,
    align:Align,
    height:f32,              // of an empty line
    images:[]Node_Image,
    link:Color,
    left:int,                // characters still shown; negative: all
    links:[RICH_SPANS]^Paint, // the pieces of links, which the pointer over any piece of theirs underlines
    named:[RICH_SPANS]u64,
    link_count:int,
    hot,clicked:u64,
}

// Text whose words take the styles, links, images and prompts its markup
// gives them, broken into lines as wide as the element as the layout breaks
// its text (at the width the last frame gave it when it grows); lines align
// as its style says. images: what <img=name> names, by Node_Image.name, as
// tall as a line of its text; link: the color of links (the text's when
// transparent), underlined while the pointer is over one; reveal: the part of
// its characters shown, 0 to 1. Returns the name of the link clicked; 0: none.
rich_text :: proc(ctx:^Context,id:Id,content:string,style:Text_Style,layout:Layout,images:[]Node_Image={},link:Color={},reveal:f32=1) -> (clicked:u64) {
    spans:[RICH_SPANS]Rich_Span
    count,lost:=rich_parse(content,style,spans[:])
    if lost {ctx.stats.dropped_tree+=1}
    width:=layout.width.value if layout.width.kind==.Fixed else ctx.size.x
    if layout.width.kind!=.Fixed {if r,found:=widget_rect(ctx,id);found {width=r.w}}
    widget_add(ctx,id,{.Passive})
    if !element_open(ctx,{id=id,layout={width=layout.width if layout.width!={} else fixed(width),height=layout.height,direction=.Column}}) {
        element_close(ctx)
        return
    }
    r:=Rich_Build{id=id,spans=spans[:count],align=style.align_x,height=style.size*TEXT_LINE,images=images,link=link,left=-1}
    if reveal<1 {
        total:=0
        for &span in r.spans {total+=utf8.rune_count_in_string(span.text) if span.prompt==0 && span.image==0 else 1}
        r.left=int(math.round(f32(total)*max(reveal,0)))
    }
    font:=&ctx.font
    for &span,index in r.spans {
        if span.prompt!=0 || span.image!=0 {
            w:=rich_inline_width(&r,&span)
            if r.pieces>0 && r.used+w>width {rich_flush(ctx,&r)}
            r.line[r.pieces]={span=index,width=w}
            r.pieces+=1
            r.used+=w
            continue
        }
        face:=int(span.style.font)
        walk:=Layout_Walk{font=font,text=span.text,size=span.style.size,face=face,space=text_width(font," ",span.style.size,face)}
        for {
            word,_,more:=layout_walk(&walk)
            if !more {break}
            if word.length==0 {rich_flush(ctx,&r);continue}
            // A word that does not fit starts the next line, as the layout breaks its text.
            if r.pieces>0 && r.used+word.width>width {rich_flush(ctx,&r)}
            start,end:=int(word.start),int(word.start+word.length)
            if last:=&r.line[max(r.pieces-1,0)];r.pieces>0 && last.span==index {
                last.end,last.width=end,last.width+word.width
            } else {
                r.line[r.pieces]={span=index,start=start,end=end,width=word.width}
                r.pieces+=1
            }
            r.used+=word.width
        }
    }
    if r.pieces>0 {rich_flush(ctx,&r)}
    element_close(ctx)
    for paint,i in r.links[:r.link_count] {
        if r.named[i]==r.hot && paint!=nil {paint.decoration+={.Underline}}
    }
    return r.clicked
}

// The width of a prompt or an image of a rich text.
@(private)
rich_inline_width :: proc(r:^Rich_Build,span:^Rich_Span) -> f32 {
    if span.prompt!=0 {return span.style.size*1.3*1.2}
    high:=span.style.size*TEXT_LINE
    for image in r.images {
        if image.name==span.image && image.size.x>0 && image.size.y>0 {return high*image.size.x/image.size.y}
    }
    return high
}

// Builds the pieces of a line of a rich text in a row as tall as its
// tallest; a space that ends the line takes no room.
@(private)
rich_flush :: proc(ctx:^Context,r:^Rich_Build) {
    line:=r.line[:r.pieces]
    high:=r.height if len(line)==0 else 0
    for piece in line {high=max(high,r.spans[piece.span].style.size*TEXT_LINE)}
    if len(line)>0 {
        last:=&line[len(line)-1]
        span:=&r.spans[last.span]
        if span.prompt==0 && span.image==0 && last.end>last.start && span.text[last.end-1]==' ' {
            last.end-=1
            last.width-=text_width(&ctx.font," ",span.style.size,int(span.style.font))
        }
    }
    box_begin(ctx,{layout={width=GROW,height=fixed(max(high,1)),direction=.Row,align_x=r.align,align_y=.Center}})
    for &piece in line {
        span:=&r.spans[piece.span]
        shown:=r.left!=0
        if span.prompt!=0 || span.image!=0 {
            if r.left>0 {r.left-=1}
            if span.prompt!=0 {
                if shown {prompt(ctx,0,span.prompt,span.style,{height=fixed(span.style.size*1.3)})} else {element_leaf(ctx,{layout={width=fixed(piece.width),height=fixed(span.style.size*1.3)}})}
                continue
            }
            paint:Paint
            for image in r.images {
                if image.name!=span.image {continue}
                frame:=image_frame(image,0)
                paint=image_paint({quad=frame.quad,fit=.Contain,size=frame.size})
                break
            }
            paint.hidden=!shown
            rich_piece(ctx,r,span,{layout={width=fixed(piece.width),height=fixed(span.style.size*TEXT_LINE)}},paint)
            continue
        }
        text:=span.text[piece.start:piece.end]
        style:=span.style
        style.align_x,style.align_y,style.wrap,style.ellipsis=.Start,.Start,.None,false
        if span.link!=0 && r.link[3]>0 {style.color=r.link}
        paint:=Paint{kind=.Text_Block,text=text,style=style,decoration=span.decoration}
        if r.left>=0 {
            count:=utf8.rune_count_in_string(text)
            paint.revealed=i32(min(r.left,count))+1
            r.left=max(r.left-count,0)
        }
        rich_piece(ctx,r,span,{layout={width=fixed(piece.width),height=fixed(span.style.size*TEXT_LINE)}},paint)
    }
    box_end(ctx,{})
    r.pieces,r.used=0,0
}

// A piece of a rich text: one of a link takes the pointer.
@(private)
rich_piece :: proc(ctx:^Context,r:^Rich_Build,span:^Rich_Span,e:Element,paint:Paint) {
    e:=e
    if span.link!=0 && r.link_count<len(r.links) {
        e.id=id_derive(ctx,r.id,"link",r.link_count+1)
        it:=interact(ctx,e.id,{})
        if it.hot {r.hot=span.link}
        if it.clicked {r.clicked=span.link}
    }
    p:=paint_add(ctx,paint)
    if span.link!=0 && r.link_count<len(r.links) {
        r.links[r.link_count],r.named[r.link_count]=p,span.link
        r.link_count+=1
    }
    e.custom=p
    element_leaf(ctx,e)
}
