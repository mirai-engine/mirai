package ui_inspector_editor

import "core:fmt"
import "mirai:cook/author"
import "mirai:editor"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The look of a node by variant and state, in the Style card: the Variant row
// is the one the node shows and the card edits, and under the rows of its
// look a fold for each state. Normal of Default is the style itself; any
// other is a rule of the style that waits for that variant and state, which
// sets only the fields that differ from what the node has without it. A variant is a
// look a node, its screen or the game chooses by name; a state happens to the
// node by itself. What the node plays and sounds as things happen to it is
// the Events card.

Node_State :: enum u8 {Normal,Hovered,Focused,Pressed,Selected,Over,Disabled}

NODE_STATE_NAMES :: [Node_State]string{.Normal="Normal",.Hovered="Hovered",.Focused="Focused",.Pressed="Pressed",.Selected="Selected",.Over="Drag over",.Disabled="Disabled"}

// What the rows of Style and Text show: the style itself, or a rule of it.
@(private)
Look :: struct {
    rule:bool,              // the rows edit a rule, not the style
    at:int,                 // the rule in the list of variants; -1: none yet
    variant:string,
    states:ui.Style_States,
    patch:ui.Style_Patch,   // what the rule sets; the fields it does not, what the node has without it
    before:ui.Style_Patch,  // the rule when the rows began
    under:ui.Node_Style,    // what the node has in that state without the rule: what an arrow gives back
}

// The states of the style a rule of state waits for.
@(private)
state_rule_states :: proc(state:Node_State) -> ui.Style_States {
    switch state {
    case .Normal:
    case .Hovered:  return {.Hovered}
    case .Focused:  return {.Focused}
    case .Pressed:  return {.Pressed}
    case .Over:     return {.Over}
    case .Selected: return {.Selected}
    case .Disabled: return {.Disabled}
    }
    return {}
}

// The names of the variants of a style, in the order of their first rule.
@(private)
variant_names :: proc(list:[]ui.Tree_Style_Variant,style:int) -> []string {
    names:=make([dynamic]string,context.temp_allocator)
    for &v in list {
        name:=serial.text_field(v.variant[:])
        if int(v.style)!=style || name=="" || author.slice_has(names[:],name) {continue}
        append(&names,name)
    }
    return names[:]
}

// The rule of style for variant and states alone; -1: none yet.
@(private)
state_rule :: proc(list:[]ui.Tree_Style_Variant,style:int,variant:string,states:ui.Style_States) -> int {
    for &v,i in list {
        if int(v.style)==style && v.states==states && serial.text_field(v.variant[:])==variant {return i}
    }
    return -1
}

// What the rows edit for the variant of the node in states: none, one, or
// several together.
@(private)
look_begin :: proc(p:^Pane,n:^ui.Tree_Node,states:ui.Style_States) {
    u:=p.u
    p.look={at=-1}
    if p.style.row>=len(u.records.styles) {return}
    variant:=serial.text_field(n.variant[:])
    if variant=="" && states=={} {return}
    th:=&p.s.gui.ctx.theme
    st:=style_values(p)
    list:=style_variants(p)
    row:=p.style.row
    look:=&p.look
    look.rule,look.variant,look.states=true,variant,states
    // As ui.style_resolve: the style and every other rule that holds in
    // those states, in its order, under the rule edited.
    under:=st^
    if states!={} || variant!="" {
        rules:=make([dynamic]ui.Style_Variant,0,len(list),context.temp_allocator)
        for &v in list {
            if int(v.style)!=row || v.states==states && serial.text_field(v.variant[:])==variant {continue}
            append(&rules,ui.Style_Variant{style=v.style,variant=ui.style_variant(serial.text_field(v.variant[:])),states=v.states,patch=v.patch})
        }
        under=ui.style_resolve(th,st^,rules[:],u16(row),ui.style_variant(variant),states)
    }
    look.under=under
    look.at=state_rule(list[:],row,variant,states)
    if look.at>=0 {look.patch=list[look.at].patch}
    v:=&look.patch.values
    f:=look.patch.fields
    if .Fill not_in f {v.fill=under.fill}
    if .Fill2 not_in f {v.fill2=under.fill2}
    if .Stroke not_in f {v.stroke=under.stroke}
    if .Track not_in f {v.track=under.track}
    if .Knob not_in f {v.knob=under.knob}
    if .Mark not_in f {v.mark=under.mark}
    if .Radius not_in f {v.radius=under.radius}
    if .Stroke_Width not_in f {v.stroke_width=under.stroke_width}
    if .Shadow not_in f {v.shadow,v.shadow_color,v.shadow_blur,v.shadow_offset=under.shadow,under.shadow_color,under.shadow_blur,under.shadow_offset}
    if .Move not_in f {v.move=under.move}
    if .Scale not_in f {v.scale=under.scale}
    if .Text_Font not_in f {v.text.font=under.text.font}
    if .Text_Size not_in f {v.text.size=under.text.size}
    if .Text_Color not_in f {v.text.color=under.text.color}
    if .Text_Outline not_in f {v.text.outline,v.text.outline_color=under.text.outline,under.text.outline_color}
    if .Text_Shadow not_in f {v.text.shadow,v.text.shadow_color=under.text.shadow,under.text.shadow_color}
    look.before=look.patch
}

// The values the rows show and what their arrows give back.
@(private)
look_values :: proc(p:^Pane) -> (values:^ui.Node_Style,defaults:ui.Node_Style) {
    if p.look.rule {return &p.look.patch.values,p.look.under}
    return style_values(p),p.style.defaults
}

// A row changed field: the style, or whether the rule sets it.
@(private)
look_changed :: proc(p:^Pane,label:string,field:ui.Style_Field,changes:bool) {
    if !changes {return}
    if !p.look.rule {
        style_changed(p,label,true)
        return
    }
    look:=&p.look
    v,w:=&look.patch.values,&look.under
    differs:bool
    switch field {
    case .Fill:         differs=v.fill!=w.fill;look.patch.tokens.fill=.Literal
    case .Fill2:        differs=v.fill2!=w.fill2;look.patch.tokens.fill2=.Literal
    case .Stroke:       differs=v.stroke!=w.stroke;look.patch.tokens.stroke=.Literal
    case .Track:        differs=v.track!=w.track;look.patch.tokens.track=.Literal
    case .Knob:         differs=v.knob!=w.knob;look.patch.tokens.knob=.Literal
    case .Mark:         differs=v.mark!=w.mark;look.patch.tokens.mark=.Literal
    case .Radius:       differs=v.radius!=w.radius
    case .Stroke_Width: differs=v.stroke_width!=w.stroke_width
    case .Shadow:       differs=v.shadow!=w.shadow || v.shadow_color!=w.shadow_color || v.shadow_blur!=w.shadow_blur || v.shadow_offset!=w.shadow_offset
    case .Move:         differs=v.move!=w.move
    case .Scale:        differs=v.scale!=w.scale
    case .Text_Font:    differs=v.text.font!=w.text.font
    case .Text_Size:    differs=v.text.size!=w.text.size
    case .Text_Color:   differs=v.text.color!=w.text.color;look.patch.tokens.text=.Literal
    case .Text_Outline: differs=v.text.outline!=w.text.outline || v.text.outline_color!=w.text.outline_color
    case .Text_Shadow:  differs=v.text.shadow!=w.text.shadow || v.text.shadow_color!=w.text.shadow_color
    }
    if differs {look.patch.fields+={field}} else {look.patch.fields-={field}}
}

// The rule the rows changed goes into the variants of the style.
@(private)
look_end :: proc(p:^Pane) {
    look:=&p.look
    if !look.rule {return}
    if look.patch.fields==look.before.fields && look.patch.values==look.before.values && look.patch.tokens==look.before.tokens {return}
    list:=style_variants(p)
    switch {
    case look.at<0:
        if look.patch.fields=={} {return}
        append(list,ui.tree_variant_record(u16(p.style.row),look.variant,look.states,look.patch))
    case look.patch.fields=={} && (look.variant=="" || look.states!={}):
        // A rule that changes nothing goes; a variant keeps its rule of Normal, which names it.
        ordered_remove(list,look.at)
    case:
        list[look.at].patch=look.patch
    }
    style_changed(p,"State",true)
}

// The variant the node shows, and the state the cards show: the rows after
// them edit that look. A node without a variant of its own shows that of
// its box or screen.
@(private)
look_head :: proc(p:^Pane,n:^ui.Tree_Node) {
    s,u:=p.s,p.u
    ctx:=s.gui.ctx
    list:=style_variants(p)
    style:=p.style.row
    names:=variant_names(list[:],style)
    variant:=serial.text_field(n.variant[:])
    choices:=make([dynamic]string,context.temp_allocator)
    append(&choices,"Default")
    append(&choices,..names)
    if variant!="" && !author.slice_has(names,variant) {append(&choices,variant)}
    chosen:=0
    for name,i in choices[1:] {if name==variant {chosen=i+1}}
    icon :: proc(ctx:^ui.Context,name:string,icon:ui.Icon,tip:string,disabled:=false) -> bool {
        return ui.button(ctx,ui.id(ctx,name),{icon=icon,icon_size=14,icon_color=ctx.theme.text_muted,tip=tip,style=.Ghost,width=ctx.theme.row,height=ctx.theme.row,disabled=disabled}).clicked
    }
    about:="The look of its style it shows, by name, and the one this card edits; Default: the style itself, or the variant of its box or screen. Bound, a text or an enum of the game names it"
    if bindable(p,"Variant",n.bind_variant[:],.Name,about) {
        p.flush=true
        if row(p,"Variant",about) {
            if u.variant_rename && variant!="" {
                field:=ui.id(ctx,"variant_name")
                if ctx.edit.id!=field {ui.edit_request(ctx,field)}
                result:=ui.text_field(ctx,field,u.variant_name[:len(u.variant_name)-1],&u.variant_name_length,{width=ui.GROW})
                renamed:=string(u.variant_name[:u.variant_name_length])
                if result.committed && renamed!="" && renamed!=variant && !author.slice_has(names,renamed) {
                    // A copy of a named style becomes the override of this node alone.
                    if p.style.draft {
                        for &v in list {
                            if int(v.style)==style && serial.text_field(v.variant[:])==variant {ui.tree_text_set(v.variant[:],renamed)}
                        }
                        ui.tree_text_set(n.variant[:],renamed)
                    } else {author.records_variant_rename(&u.records,style,variant,renamed)}
                    style_changed(p,"Rename variant",true)
                }
                if result.committed || result.cancelled {u.variant_rename=false}
            } else if ui.dropdown(ctx,ui.id(ctx,"variant"),choices[:],&chosen,{width=-1}) {
                ui.tree_text_set(n.variant[:],choices[chosen] if chosen>0 else "")
                changed(u,"Variant")
            }
            if icon(ctx,"variant_add",.Plus,"New variant of the style, shown by this node") {
                name:=""
                for i:=len(names)+1;;i+=1 {
                    name=fmt.tprintf("variant%d",i)
                    if !author.slice_has(names,name) {break}
                }
                append(list,ui.tree_variant_record(u16(style),name,{},{}))
                ui.tree_text_set(n.variant[:],name)
                u.variant_rename=true
                u.variant_name_length=copy(u.variant_name[:len(u.variant_name)-1],name)
                style_changed(p,"Add variant",true)
            }
            if icon(ctx,"variant_rename",.Edit,"Rename the variant",variant=="" || !author.slice_has(names,variant)) {
                u.variant_rename=true
                u.variant_name_length=copy(u.variant_name[:len(u.variant_name)-1],variant)
            }
            if icon(ctx,"variant_remove",.Cross,"Remove the variant from the style",variant=="" || !author.slice_has(names,variant)) {
                for i:=len(list)-1;i>=0;i-=1 {
                    if int(list[i].style)==style && serial.text_field(list[i].variant[:])==variant {ordered_remove(list,i)}
                }
                for &b in n.variant {b=0}
                style_changed(p,"Remove variant",true)
            }
        }
    }
}

// ---------------------------------------------------------------- tokens

// The color of a theme a field of a rule takes, or Literal: its own value.
@(private)
rule_token :: proc(p:^Pane,field:ui.Style_Field) -> ^ui.Color_Token {
    t:=&p.look.patch.tokens
    #partial switch field {
    case .Fill:       return &t.fill
    case .Fill2:      return &t.fill2
    case .Stroke:     return &t.stroke
    case .Track:      return &t.track
    case .Knob:       return &t.knob
    case .Mark:       return &t.mark
    case .Text_Color: return &t.text
    }
    return nil
}

// A color of the look: in a rule, a color of the theme or its own, chosen
// after it; the style has its own colors.
@(private)
look_color :: proc(p:^Pane,label:string,field:ui.Style_Field,c:^ui.Color,default:ui.Color,about:="",group:="Style") {
    token:=rule_token(p,field)
    if !p.look.rule || token==nil {
        look_changed(p,group,field,color_row(p,label,c,default,about))
        return
    }
    if !shown(p,label) {return}
    ctx:=p.s.gui.ctx
    th:=&ctx.theme
    ui.id_push(ctx,ui.id(ctx,"token",int(field)+1))
    defer ui.id_pop(ctx)
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4,align_y=.Center}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
            if token^==.Literal {
                look_changed(p,group,field,color_row(p,label,c,default,about))
            } else {
                // The theme gives it: its color shows as the game will have it.
                p.flush=true
                if row(p,label,about) {
                    color:=ui.style_token(th,token^,c^)
                    _=ui.color_swatch(ctx,ui.id(ctx,"theme"),{f32(color.r)/255,f32(color.g)/255,f32(color.b)/255})
                }
            }
        }
        // A color of the theme instead of its own: a menu behind a small button, to keep the row narrow.
        picker,menu:=ui.id(ctx,"which"),ui.id(ctx,"which_menu")
        if ui.button(ctx,picker,{icon=.Palette,icon_size=13,icon_color=th.accent if token^!=.Literal else th.text_muted,tip=fmt.tprintf("Color of the theme: %v",token^),style=.Ghost,width=th.row,height=th.row,active=token^!=.Literal}).clicked {
            if r,found:=ui.widget_rect(ctx,picker);found {ui.popup_open(ctx,menu,r)}
        }
        if ui.popup(ctx,menu,{min_width=160}) {
            for name,i in ui.Color_Token {
                if ui.menu_item(ctx,ui.id(ctx,"token",i+1),"Own color" if name==.Literal else fmt.tprintf("%v",name),{checked=token^==name}) {
                    token^=name
                    if token^!=.Literal {p.look.patch.fields+={field}} else {look_changed(p,group,field,true)}
                }
            }
        }
    }
}

// ---------------------------------------------------------------- several states

// The name of states together: Hovered + Pressed.
@(private)
states_name :: proc(states:ui.Style_States) -> string {
    names:=NODE_STATE_NAMES
    b:=make([dynamic]u8,context.temp_allocator)
    for state in Node_State {
        if state==.Normal || state_rule_states(state)&states=={} {continue}
        if len(b)>0 {append(&b," + ")}
        append(&b,names[state])
    }
    return string(b[:])
}

// The rules of the style for the variant of the node that wait for several
// states together, as folds like those of one state, and the states a new
// one waits for.
@(private)
combo_rows :: proc(p:^Pane,a:^host.Assets,n:^ui.Tree_Node) {
    s,u:=p.s,p.u
    ctx:=s.gui.ctx
    th:=&ctx.theme
    x:=&u.ux
    list:=style_variants(p)
    variant:=serial.text_field(n.variant[:])
    combos:=make([dynamic]ui.Style_States,context.temp_allocator)
    for &v in list {
        if int(v.style)!=p.style.row || serial.text_field(v.variant[:])!=variant || card(v.states)<2 {continue}
        held:=false
        for c in combos {if c==v.states {held=true;break}}
        if !held {append(&combos,v.states)}
    }
    for open,bits in x.combo_open {
        states:=transmute(ui.Style_States)u8(bits)
        if !open || card(states)<2 {continue}
        held:=false
        for c in combos {if c==states {held=true;break}}
        if !held {append(&combos,states)}
    }
    for states in combos {
        bits:=transmute(u8)states
        ui.id_push(ctx,ui.id(ctx,"combo",int(bits)+1))
        open:=x.combo_open[bits] || p.needle!=""
        if p.needle=="" && editor.section_fold(s,ui.id(ctx,"fold"),states_name(states),open) {
            x.combo_open[bits]=!open
            open=!open
            x.combo_shown=states if open else {}
        }
        if open {
            if p.needle=="" {band_open(p,states_name(states))} else {p.band=states_name(states)}
            look_begin(p,n,states)
            style_rows(p,a,n)
            look_end(p)
            band_close(p)
        }
        ui.id_pop(ctx)
    }
    if p.needle!="" {return}
    // The states a new rule waits for together, and the button that opens it.
    p.flush=true
    if row(p,"Together","A look for when several states happen at once: choose them and open it") {
        // The states chosen, in a field that opens one box for each, to fit the width of the panel.
        picker,menu:=ui.id(ctx,"combo_pick"),ui.id(ctx,"combo_menu")
        chosen:=states_name(x.combo) if card(x.combo)>0 else "Choose states"
        if ui.button(ctx,picker,{label=chosen,icon=.Chevron_Down,icon_after=true,style=.Field,width=-1,height=th.row,size=th.font_small}).clicked {
            if r,found:=ui.widget_rect(ctx,picker);found {ui.popup_open(ctx,menu,r)}
        }
        if ui.popup(ctx,menu,{min_width=180,padding=12}) {
            names:=NODE_STATE_NAMES
            for state in Node_State {
                if state==.Normal {continue}
                bit:=state_rule_states(state)
                on:=bit&x.combo!={}
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=8,align_y=.Center}) {
                    if ui.checkbox(ctx,ui.id(ctx,"combo_state",int(state)),&on) {
                        if on {x.combo+=bit} else {x.combo-=bit}
                    }
                    ui.label(ctx,names[state],th.font_small,th.text)
                }
            }
            if ui.button(ctx,ui.id(ctx,"combo_add"),{label="Open",style=.Accent,width=-1,height=th.control,center=true,disabled=card(x.combo)<2}).clicked {
                x.combo_open[transmute(u8)x.combo]=true
                x.combo_shown=x.combo
                x.combo={}
                ui.popup_close(ctx,menu)
            }
        }
    }
}

// ---------------------------------------------------------------- events

// A sound chosen for a node whose look is a style with a name: whether it
// goes to the node, as a change of its own, or to the style, waits for the
// person to say.
@(private)
Sound_Choice :: struct {
    open:bool,
    row:int,           // the node it was chosen on
    cue:ui.Sound_Cue,
    sound:base.Asset_Id,
}

// What the node plays and its style sounds as things happen to it.
@(private)
section_events :: proc(p:^Pane,n:^ui.Tree_Node) {
    s,u:=p.s,p.u
    ctx:=s.gui.ctx
    r:=&u.records
    if p.style.row>=len(r.styles) {return}
    st:=style_values(p)
    d:=p.style.defaults
    names:=anim_names(r)
    set:ui.Anim_Set
    if n.anims!=0 && int(n.anims)<=len(r.anim_sets) {set=r.anim_sets[n.anims-1]}
    before:=set
    sound :: proc(p:^Pane,n:^ui.Tree_Node,st:^ui.Node_Style,d:^ui.Node_Style,cue:ui.Sound_Cue,about:string) {
        if !shown(p,"Sound") {return}
        u:=p.u
        r:=&u.records
        x:=&u.ux
        values:=Sound_Pick{st.sounds[cue]}
        none:=Sound_Pick{d.sounds[cue]}
        key:=base.hash_combine(u64(0x736f756e64),u64(n.style)<<8|u64(cue))|1
        // The style the node shares: it is asked whether the sound goes there.
        base_row:=author.records_style_base(r,p.style.row)
        shared:=base_row if base_row>=0 else p.style.row if p.style.draft && !p.style.own else -1
        if editor.held_field_row(p.s,{key=key,info=type_info_of(Sound_Pick),value=&values,defaults=&none},"sound","Sound",about) {
            if shared>=0 {
                x.sound={open=true,row=u.selected,cue=cue,sound=values.sound}
            } else {
                st.sounds[cue]=values.sound
                style_changed(p,"Sound",true)
            }
        }
        if !x.sound.open || x.sound.row!=u.selected || x.sound.cue!=cue || shared<0 {return}
        ctx:=p.s.gui.ctx
        th:=&ctx.theme
        p.flush=true
        if row(p,"Goes to","This node: a change of its own, marked * on its style until it is applied there. The style: every node that has it plays it") {
            if ui.button(ctx,ui.id(ctx,"sound_node"),{label="This node",style=.Field,width=-1,height=th.row,size=th.font_small}).clicked {
                st.sounds[cue]=x.sound.sound
                style_changed(p,"Sound",true)
                x.sound={}
            }
            if ui.button(ctx,ui.id(ctx,"sound_style"),{label=author.records_style_name(r,shared),style=.Field,width=-1,height=th.row,size=th.font_small}).clicked {
                r.styles[shared].sounds[cue]=x.sound.sound
                // An override that had what the style had follows it.
                if base_row>=0 && st.sounds[cue]==d.sounds[cue] {st.sounds[cue]=x.sound.sound}
                changed(u,"Sound")
                x.sound={}
            }
            if ui.button(ctx,ui.id(ctx,"sound_cancel"),{icon=.Cross,icon_size=11,icon_color=th.text_muted,tip="Cancel",style=.Ghost,width=th.row,height=th.row}).clicked {x.sound={}}
        }
    }
    // Each happening is a part that folds, as the states of the style.
    event :: proc(p:^Pane,title:string,id:int) -> bool {
        ctx:=p.s.gui.ctx
        ui.id_pop(ctx)
        ui.id_push(ctx,ui.id(ctx,"event",id))
        return subsection(p,ui.id(ctx,"fold"),title,&p.u.event_open[id])
    }
    ui.id_push(ctx,ui.id(ctx,"event",0))
    if event(p,"Shows",1) {
        list_row(p,"Animation",&set.shown,names)
        sound(p,n,st,&d,.Show,"What its style plays when it appears")
    }
    if event(p,"Hides",2) {
        list_row(p,"Animation",&set.hidden,names)
        sound(p,n,st,&d,.Hide,"What its style plays when it goes")
    }
    if event(p,"Hover",3) {
        list_row(p,"Animation",&set.hovered,names)
        list_row(p,"On leave",&set.unhovered,names)
        sound(p,n,st,&d,.Hover,"What its style plays when the pointer comes over it")
    }
    if event(p,"Press",4) {
        list_row(p,"Animation",&set.pressed,names)
        list_row(p,"On release",&set.released,names)
        list_row(p,"On click",&set.clicked,names)
        sound(p,n,st,&d,.Press,"What its style plays when it is clicked")
    }
    if (focusable(n.kind) || ui.node_kind_holds(n.kind)) && event(p,"Focus",5) {
        list_row(p,"Animation",&set.focused,names)
        list_row(p,"On blur",&set.unfocused,names)
        sound(p,n,st,&d,.Focus,"What its style plays when navigation comes to it")
    }
    if event(p,"Selected",7) {
        list_row(p,"Animation",&set.selected,names)
        list_row(p,"On unselect",&set.unselected,names)
    }
    if focusable(n.kind) && event(p,"Change",6) {
        sound(p,n,st,&d,.Change,"What its style plays when its value changes")
    }
    band_close(p)
    ui.id_pop(ctx)
    if set==before {return}
    if at:=author.records_anim_set(r,n);at>=0 {
        r.anim_sets[at]=set
        changed(u,"Animations")
    }
}

// ---------------------------------------------------------------- advanced

// The part at the end of a card with what few interfaces change; the search
// opens it. Its band closes with the card.
@(private)
advanced :: proc(p:^Pane) -> bool {
    return subsection(p,ui.id(p.s.gui.ctx,"advanced"),editor.ADVANCED_SECTION,&p.u.advanced[p.which])
}
