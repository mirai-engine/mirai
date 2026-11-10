package ui

import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "mirai:std/base"

// What each kind of node of a tree builds when it holds no other nodes, how
// a node takes part in navigation and how it is dragged and dropped. The
// controls are those of the package, with the style the node resolves to as
// their look.

// A Text: what its style fills, strokes or shades goes behind it as on a Box, a
// box of the size of the node with its padding around the text.
@(private)
tree_build_text :: proc(ctx:^Context,node:^Node,style:^Node_Style,node_id:Id,content:string,reveal:f32) {
    width,height:=node.layout.width,node.layout.height
    if style.fill[3]==0 && style.fill2[3]==0 && style.stroke[3]==0 && !style.shadow {
        text(ctx,content,style.text,width,height,node_id,reveal)
        return
    }
    box:=tree_box(node,style,node_id)
    box.float={}
    padding:=node.layout.padding
    if width.kind==.Fixed {width=fixed(max(width.value-padding[0]-padding[2],0))} else if width.kind!=.Fit {width=GROW}
    if height.kind==.Fixed {height=fixed(max(height.value-padding[1]-padding[3],0))} else if height.kind!=.Fit {height=GROW}
    widget_add(ctx,node_id,{.Passive})
    box_begin(ctx,box)
    text(ctx,content,style.text,width,height,0,reveal)
    box_end(ctx,box)
}

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
            b.animating=true // this frame built it without its focus: the next shows it
        }
    }
    if .Draggable in node.flags {tree_drag_source(ctx,b,node,index,node_id,item)}
    defer if .Draggable in node.flags {tree_drag_ghost(ctx,b,node,index,node_id,values,slot-int(instance.slots[index]),item)}
    changed :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index:int,item:i32,style:^Node_Style,value:f64,on:=false,text:="") {
        event:=Tree_Event{name=node.name,node=i32(index),kind=.Changed,item=item,value=value,on=on}
        base.text_set(event.text[:],text)
        tree_emit(b,event)
        tree_sound(ctx,style,.Change)
    }
    control:=Game_Control{style=style,width=node.layout.width,height=node.layout.height,disabled=disabled}
    // What a Progress, a Slider or a Number shows: its value, or that of its animation.
    current:=bound_number(values,bound.value) if bound.value.bound else 0
    shown:=f64(anim.value) if anim!=nil && .Value in anim.set else current
    reveal:=anim.reveal if anim!=nil && .Reveal in anim.set else 1
    #partial switch node.kind {
    case .Text:
        tree_build_text(ctx,node,style,node_id,content,reveal)
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
        if checkbox(ctx,node_id,&value,disabled,style,node.layout.width,node.layout.height) {
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
        if node.kind==.Slider {
            moved=slider(ctx,node_id,&value,{min=lo,max=hi,step=step,width=node.layout.width,height=node.layout.height,look=style,disabled=disabled}).changed
        } else {
            height:=node.layout.height
            moved=number_field(ctx,node_id,&value,{width=node.layout.width,height=height.value if height.kind==.Fixed else 0,decimals=number_decimals(step),
                min=lo,max=hi,has_min=hi>lo,has_max=hi>lo,step=step,stepper=true,look=style,disabled=disabled}).changed
        }
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
        spec:=string(tree.strings[node.text_offset:][:node.text_length])
        valued:=bound.value.bound && !bound.options.bound && strings.index_byte(spec,'=')>=0
        chosen:=tree_option_chosen(values,bound.value,spec) if valued else int(current) if bound.value.bound else int(instance.slot[slot].held)
        next:=chosen
        if node.kind==.Selector {game_selector(ctx,node_id,options,&next,control)} else {
            dropdown(ctx,node_id,options,&next,{look=style,layout=&node.layout,disabled=disabled})
            if popup_is_open(ctx,id_derive(ctx,node_id,"list")) {b.animating=true}
        }
        if next!=chosen {
            written,text:=f64(next),""
            if valued {
                value:=option_value(spec,next)
                if bound.value.text {text=value} else {written=bound_option_number(bound.value,value)}
            }
            switch {
            case bound.value.text:  bound_write_text(values,bound.value,text)
            case bound.value.bound: bound_write(values,bound.value,written)
            case:                   instance.slot[slot].held=f32(next)
            }
            changed(ctx,b,node,index,item,base_style,written,text=text)
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
    it:=button(ctx,node_id,{label=content,look=style,layout=&node.layout,image=image_ref,block=true,disabled=disabled})
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
                bar:=max(control_em(ctx,style)*0.2,1)
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

// Text whose words take the styles, links, images and prompts its markup
// gives them: one text (text.odin) the layout breaks into lines at the width
// it gives the element. images: what <img=name> names, by Node_Image.name, as
// tall as a line of its text; link: the color of links (the text's when
// transparent), underlined while the pointer is over one; reveal: the part of
// its characters shown, 0 to 1. Returns the name of the link clicked; 0: none.
rich_text :: proc(ctx:^Context,id:Id,content:string,style:Text_Style,layout:Layout,images:[]Node_Image={},link:Color={},reveal:f32=1) -> (clicked:u64) {
    spans:[RICH_SPANS]Rich_Span
    count,lost:=rich_parse(content,style,spans[:])
    if lost {ctx.stats.dropped_tree+=1}
    whole:=style
    whole.wrap=.Words
    if !text_begin(ctx,whole) {return}
    for &span in spans[:count] {
        look:=Text_Span{font=span.style.font,size=span.style.size,color=span.style.color,decoration=span.decoration}
        if span.style.font==style.font && span.style.size==style.size && span.style.color==style.color && span.decoration=={} {look={}}
        named:Id
        hot:=false
        if span.link!=0 {
            named=id_derive(ctx,id,"link",int(u32(span.link))+1)
            hot=ctx.hot==named
            if link[3]>0 {look.font,look.size,look.color=span.style.font,span.style.size,link}
            if hot {
                look.font,look.size=span.style.font,span.style.size
                if look.color=={} {look.color=span.style.color}
                look.decoration+={.Underline}
            }
        }
        switch {
        case span.prompt!=0:
            prompt_boxes(ctx,span.prompt,span.style.size*1.3)
        case span.image!=0:
            high:=span.style.size*TEXT_LINE
            width:=high
            paint:Paint
            for image in images {
                if image.name!=span.image {continue}
                frame:=image_frame(image,0)
                paint=image_paint({quad=frame.quad,fit=.Contain,size=frame.size})
                if image.size.x>0 && image.size.y>0 {width=high*image.size.x/image.size.y}
                break
            }
            if named!=0 && interact(ctx,named).clicked {clicked=span.link}
            text_box(ctx,width,high,paint,named)
        case named!=0:
            if text_link(ctx,named,span.text,look).clicked {clicked=span.link}
        case:
            text_span(ctx,span.text,look)
        }
    }
    rest:=layout
    rest.direction,rest.padding,rest.gap={},{},0
    text_end(ctx,rest,id,reveal)
    return
}
