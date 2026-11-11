package ui

import "base:intrinsics"
import "core:slice"
import "mirai:std/base"
import "mirai:std/serial"

// In order of precedence: a later state wins over an earlier one.
Style_State :: enum u8 {
    Selected,
    Hovered,
    Focused, // navigation is on it, with its ring shown
    Over,    // something dragged is over a Drop
    Pressed,
    Disabled,
}
Style_States :: bit_set[Style_State; u8]
Style_Field :: enum u8 {
    Fill, Fill2, Stroke, Track, Knob, Mark, Radius, Stroke_Width,
    Shadow,       // with its color, blur and offset
    Text_Font, Text_Size, Text_Color,
    Text_Outline, // its width and color
    Text_Shadow,  // its offset and color
    Move,         // Node_Style.move: where it is drawn from where the layout put it
    Scale,        // Node_Style.scale, around its center
}
Style_Fields :: bit_set[Style_Field; u16]
Style_Patch :: struct {
    fields:Style_Fields,
    values:Node_Style,
}
Style_Variant :: struct {
    style:u16,
    variant:u64, // zero matches every named variant
    states:Style_States, // all named states must be active
    patch:Style_Patch,
}

// Sets in style what a patch gives.
style_patch :: proc "contextless" (style:^Node_Style,patch:^Style_Patch) {
    v:=&patch.values
    if .Text_Font in patch.fields {style.text.font=v.text.font}
    if .Text_Size in patch.fields {style.text.size=v.text.size}
    if .Text_Color in patch.fields {style.text.color=v.text.color}
    if .Text_Outline in patch.fields {style.text.outline,style.text.outline_color=v.text.outline,v.text.outline_color}
    if .Text_Shadow in patch.fields {style.text.shadow,style.text.shadow_color=v.text.shadow,v.text.shadow_color}
    if .Fill in patch.fields {style.fill=v.fill}
    if .Fill2 in patch.fields {style.fill2=v.fill2}
    if .Stroke in patch.fields {style.stroke=v.stroke}
    if .Track in patch.fields {style.track=v.track}
    if .Knob in patch.fields {style.knob=v.knob}
    if .Mark in patch.fields {style.mark=v.mark}
    if .Radius in patch.fields {style.radius=v.radius}
    if .Stroke_Width in patch.fields {style.stroke_width=v.stroke_width}
    if .Shadow in patch.fields {style.shadow=v.shadow;style.shadow_color=v.shadow_color;style.shadow_blur=v.shadow_blur;style.shadow_offset=v.shadow_offset}
    if .Move in patch.fields {style.move=v.move}
    if .Scale in patch.fields {style.scale=v.scale}
}

// Where a rule goes among those that hold: by the latest state it names, and
// within it an unnamed rule before a named variant.
style_rule_order :: #force_inline proc "contextless" (states:Style_States,variant:u64) -> u8 {
    rank:=8-u8(intrinsics.count_leading_zeros(transmute(u8)states))
    return rank<<1|u8(variant!=0)
}

@(private)
style_rule_holds :: #force_inline proc "contextless" (rule:^Style_Variant,style:u16,variant:u64,states:Style_States) -> bool {
    return rule.style==style && (rule.variant==0 || rule.variant==variant) && rule.states&states==rule.states
}

// Applies to result the rules that hold, as they come. held: one did.
// ordered false: one came before a rule it goes after, and result is not what
// they resolve to.
@(private)
style_rules_apply :: proc "contextless" (result:^Node_Style,rules:[]Style_Variant,style:u16,variant:u64,states:Style_States) -> (held,ordered:bool) {
    last:u8
    for &rule in rules {
        if !style_rule_holds(&rule,style,variant,states) {continue}
        order:=style_rule_order(rule.states,rule.variant)
        if order<last {return true,false}
        last=order
        held=true
        style_patch(result,&rule.patch)
    }
    return held,true
}

// Table order wins within a state; a named variant wins over an unnamed rule.
// The rule of the latest active state in Style_State has precedence. Rules
// that come in that order, as a tree keeps those of each style, take one pass.
style_resolve :: proc "contextless" (base:Node_Style,rules:[]Style_Variant,style:u16=0,variant:u64=0,states:Style_States={}) -> (result:Node_Style) {
    result=base
    if _,ordered:=style_rules_apply(&result,rules,style,variant,states);ordered {return}
    result=base
    orders:u32
    for &rule in rules {
        if style_rule_holds(&rule,style,variant,states) {orders|=1<<style_rule_order(rule.states,rule.variant)}
    }
    for orders!=0 {
        order:=u8(intrinsics.count_trailing_zeros(orders))
        orders&=orders-1
        for &rule in rules {
            if style_rule_holds(&rule,style,variant,states) && style_rule_order(rule.states,rule.variant)==order {style_patch(&result,&rule.patch)}
        }
    }
    return
}

style_variant :: proc "contextless" (name:string) -> u64 {return base.name_hash(name) if name!="" else 0}

@(private)
style_states :: proc "contextless" (it:Interaction,selected,disabled:bool,over:=false) -> (states:Style_States) {
    if selected {states+={.Selected}}
    if it.hot {states+={.Hovered}}
    if it.focused {states+={.Focused}}
    if over {states+={.Over}}
    if it.active {states+={.Pressed}}
    if disabled {states+={.Disabled}}
    return
}

// The bits of Style_States that name a state.
STYLE_STATES_NAMED :: u8(1<<len(Style_State)-1)

// What of a style Node_Style.transition carries from one state to the next.
Style_Look :: struct {
    fill,fill2,stroke,track,knob,mark,text,shadow_color:Color,
    shadow_offset,move:[2]f32,
    scale:f32,
}
// Where that look is on its way: from what was shown when the state changed
// to what the new one resolves to.
Style_Transition :: struct {
    from,to:Style_Look,
    time:f32, // seconds since the change
    seen:bool,
}

// Carries the look of style, resolved for the state of now, from what was
// shown before over seconds: a change on the way starts from where it was.
// Returns true while it is on its way.
style_transition :: proc "contextless" (t:^Style_Transition,style:^Node_Style,seconds,dt:f32) -> bool {
    s:=style
    target:=Style_Look{s.fill,s.fill2,s.stroke,s.track,s.knob,s.mark,s.text.color,s.shadow_color,s.shadow_offset,s.move,s.scale if s.scale>0 else 1}
    if !t.seen {t^={from=target,to=target,time=seconds,seen=true}}
    if target!=t.to {t.from,t.to,t.time=style_look_mix(t.from,t.to,min(t.time/seconds,1)),target,0}
    k:=min(t.time/seconds,1)
    c:=style_look_mix(t.from,t.to,k)
    s.fill,s.fill2,s.stroke,s.track,s.knob,s.mark,s.text.color,s.shadow_color=c.fill,c.fill2,c.stroke,c.track,c.knob,c.mark,c.text,c.shadow_color
    s.shadow_offset,s.move,s.scale=c.shadow_offset,c.move,c.scale
    t.time+=dt
    return k<1
}
@(private)
style_look_mix :: proc "contextless" (a,b:Style_Look,k:f32) -> (out:Style_Look) {
    // A transparent end takes the color of the other one: it only fades.
    mix :: proc "contextless" (a,b:Color,k:f32) -> (c:Color) {
        a,b:=a,b
        if a[3]==0 {a={b[0],b[1],b[2],0}}
        if b[3]==0 {b={a[0],a[1],a[2],0}}
        for i in 0..<4 {c[i]=u8(f32(a[i])+(f32(b[i])-f32(a[i]))*k+0.5)}
        return
    }
    out={mix(a.fill,b.fill,k),mix(a.fill2,b.fill2,k),mix(a.stroke,b.stroke,k),mix(a.track,b.track,k),mix(a.knob,b.knob,k),mix(a.mark,b.mark,k),mix(a.text,b.text,k),mix(a.shadow_color,b.shadow_color,k),{},{},0}
    out.shadow_offset=a.shadow_offset+(b.shadow_offset-a.shadow_offset)*k
    out.move=a.move+(b.move-a.move)*k
    out.scale=a.scale+(b.scale-a.scale)*k
    return
}

// ---------------------------------------------------------------- sheet

// The style file a context draws with what nothing else styles: its tokens
// by name and its styles, with their states and variants, by the name of the
// style. The editor's is its theme.ui; the controls of a game take their look
// from the nodes of its .ui, so its contexts have none, and a name a sheet
// lacks gives nothing: a transparent color, 0 or a look of no value.
@(private)
Sheet_Name :: struct {hash:u64,row:u16,token:bool}

// Takes the records of a style file as the sheet of ctx, in place of the one
// it had: a transaction that loads its styles as a tree does.
context_sheet_set :: proc(ctx:^Context,data:Tree_Data) -> bool {
    a:=ctx.allocator
    tree:Widget_Tree
    if !tree_load(&tree,{styles=data.styles,variants=data.variants,style_infos=data.style_infos},{},a) {return false}
    names,names_error:=make([]Sheet_Name,len(data.style_infos)+len(data.tokens),a)
    tokens,tokens_error:=make([]Tree_Token,len(data.tokens),a)
    if names_error!=nil || tokens_error!=nil {
        delete(names,a);delete(tokens,a);tree_destroy(&tree)
        return false
    }
    copy(tokens,data.tokens)
    count:=0
    for &info,row in data.style_infos {
        if name:=serial.text_field(info.name[:]);name!="" {names[count]={base.name_hash(name),u16(row),false};count+=1}
    }
    for &token,row in tokens {names[count]={base.name_hash(serial.text_field(token.name[:])),u16(row),true};count+=1}
    names=names[:count]
    slice.sort_by(names,proc(a,b:Sheet_Name) -> bool {return a.hash<b.hash})
    sheet_destroy(ctx)
    ctx.sheet,ctx.sheet_names,ctx.sheet_tokens=tree,names,tokens
    return true
}

@(private)
sheet_destroy :: proc(ctx:^Context) {
    if ctx.sheet.allocator.procedure!=nil {tree_destroy(&ctx.sheet)}
    delete(ctx.sheet_names,ctx.allocator)
    delete(ctx.sheet_tokens,ctx.allocator)
    ctx.sheet,ctx.sheet_names,ctx.sheet_tokens={},nil,nil
}

@(private)
sheet_find :: proc "contextless" (ctx:^Context,name:string,token:bool) -> (row:int,found:bool) {
    hash:=base.name_hash(name)
    names:=ctx.sheet_names
    low,high:=0,len(names)
    for low<high {
        middle:=(low+high)/2
        if names[middle].hash<hash {low=middle+1} else {high=middle}
    }
    for at:=low;at<len(names) && names[at].hash==hash;at+=1 {
        if names[at].token==token {return int(names[at].row),true}
    }
    return -1,false
}

// The color of a token of the sheet.
tone :: proc "contextless" (ctx:^Context,name:string) -> Color {
    if row,found:=sheet_find(ctx,name,true);found && !ctx.sheet_tokens[row].numeric {return ctx.sheet_tokens[row].color}
    return {}
}
// The number of a token of the sheet: a size in layout units.
metric :: proc "contextless" (ctx:^Context,name:string) -> f32 {
    if row,found:=sheet_find(ctx,name,true);found && ctx.sheet_tokens[row].numeric {return ctx.sheet_tokens[row].number}
    return 0
}
// Gives a number token of the sheet another value; returns the one it had.
metric_set :: proc "contextless" (ctx:^Context,name:string,value:f32) -> (previous:f32) {
    if row,found:=sheet_find(ctx,name,true);found && ctx.sheet_tokens[row].numeric {
        previous=ctx.sheet_tokens[row].number
        ctx.sheet_tokens[row].number=value
    }
    return
}

// A style of the sheet resolved for a variant and the states it is in.
sheet_look :: proc "contextless" (ctx:^Context,style:string,variant:string="",states:Style_States={}) -> Node_Style {
    row,found:=sheet_find(ctx,style,false)
    if !found || row>=ctx.sheet.style_count {return {}}
    return style_resolve(ctx.sheet.styles[row],tree_style_rules(&ctx.sheet,u16(row)),u16(row),style_variant(variant),states)
}
