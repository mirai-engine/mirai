package ui

import "mirai:std/base"

Color_Token :: enum u8 {
    Literal, Backdrop, Panel, Popup, Raised, Field, Field_Hover, Field_Active,
    Border, Divider, Text, Text_Muted, Text_Faint, Accent, Accent_Hover,
    Accent_Soft, On_Accent, Danger, Shadow, Focus,
}
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
Style_Tokens :: struct {fill,fill2,stroke,text,track,knob,mark:Color_Token}
Style_Patch :: struct {
    fields:Style_Fields,
    values:Node_Style,
    tokens:Style_Tokens,
}
Style_Variant :: struct {
    style:u16,
    variant:u64, // zero matches every named variant
    states:Style_States, // all named states must be active
    patch:Style_Patch,
}

style_token :: proc "contextless" (theme:^Theme,token:Color_Token,literal:Color) -> Color {
    switch token {
    case .Literal:return literal
    case .Backdrop:return theme.backdrop
    case .Panel:return theme.panel
    case .Popup:return theme.popup
    case .Raised:return theme.raised
    case .Field:return theme.field
    case .Field_Hover:return theme.field_hover
    case .Field_Active:return theme.field_active
    case .Border:return theme.border
    case .Divider:return theme.divider
    case .Text:return theme.text
    case .Text_Muted:return theme.text_muted
    case .Text_Faint:return theme.text_faint
    case .Accent:return theme.accent
    case .Accent_Hover:return theme.accent_hover
    case .Accent_Soft:return theme.accent_soft
    case .On_Accent:return theme.on_accent
    case .Danger:return theme.danger
    case .Shadow:return theme.shadow
    case .Focus:return theme.focus
    }
    return literal
}

style_patch :: proc "contextless" (theme:^Theme,style:Node_Style,patch:Style_Patch) -> (result:Node_Style) {
    result=style
    v:=patch.values;t:=patch.tokens
    if .Text_Font in patch.fields {result.text.font=v.text.font}
    if .Text_Size in patch.fields {result.text.size=v.text.size}
    if .Text_Color in patch.fields {result.text.color=style_token(theme,t.text,v.text.color)}
    if .Text_Outline in patch.fields {result.text.outline,result.text.outline_color=v.text.outline,v.text.outline_color}
    if .Text_Shadow in patch.fields {result.text.shadow,result.text.shadow_color=v.text.shadow,v.text.shadow_color}
    if .Fill in patch.fields {result.fill=style_token(theme,t.fill,v.fill)}
    if .Fill2 in patch.fields {result.fill2=style_token(theme,t.fill2,v.fill2)}
    if .Stroke in patch.fields {result.stroke=style_token(theme,t.stroke,v.stroke)}
    if .Track in patch.fields {result.track=style_token(theme,t.track,v.track)}
    if .Knob in patch.fields {result.knob=style_token(theme,t.knob,v.knob)}
    if .Mark in patch.fields {result.mark=style_token(theme,t.mark,v.mark)}
    if .Radius in patch.fields {result.radius=v.radius}
    if .Stroke_Width in patch.fields {result.stroke_width=v.stroke_width}
    if .Shadow in patch.fields {result.shadow=v.shadow;result.shadow_color=v.shadow_color;result.shadow_blur=v.shadow_blur;result.shadow_offset=v.shadow_offset}
    if .Move in patch.fields {result.move=v.move}
    if .Scale in patch.fields {result.scale=v.scale}
    return
}

// Table order wins within a state; a named variant wins over an unnamed rule.
// The rule of the latest active state in Style_State has precedence.
style_resolve :: proc "contextless" (theme:^Theme,base:Node_Style,rules:[]Style_Variant,style:u16=0,variant:u64=0,states:Style_States={}) -> (result:Node_Style) {
    result=base
    for priority in 0..=len(Style_State) {
        for named in 0..<2 {
            for rule in rules {
                if rule.style!=style || (rule.variant!=0 && rule.variant!=variant) || int(rule.variant!=0)!=named || rule.states&states!=rule.states {continue}
                rank:=0
                for state in Style_State {if state in rule.states {rank=int(state)+1}}
                if rank!=priority {continue}
                result=style_patch(theme,result,rule.patch)
            }
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
