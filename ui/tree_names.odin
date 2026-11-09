package ui

import "mirai:std/serial"

// What the names of a .ui leave in its records. A document names tokens and
// styles (extends, states that extend others, layouts in a style); what the
// frame reads stays Node_Style, Tree_Style_Variant and Tree_Node.layout, flat.
// tree_settle puts the values there when a file is written and when it links
// another: a change of a token or a style reaches what names it, and nothing
// of it runs per frame.

// Every value a style or a state can set by itself.
Style_Key :: enum u8 {
    Fill, Fill2, Stroke, Track, Knob, Mark, Radius, Border,
    Shadow_Color, Shadow_Blur, Shadow_X, Shadow_Y,
    Font, Size, Color, Outline, Outline_Color,
    Text_Shadow_Color, Text_Shadow_X, Text_Shadow_Y,
    Move_X, Move_Y, Scale,
    Text_Align_X, Text_Align_Y, Text_Wrap, Ellipsis, Line_Height,
    Fill_Mode, Program, Program_Values, Sounds, Transition, Blur,
    Width, Height, Direction, Padding, Gap, Align_X, Align_Y, Columns, Span, Self_X, Self_Y, Aspect,
}
Style_Keys :: bit_set[Style_Key;u64]

LAYOUT_KEYS :: Style_Keys{.Width,.Height,.Direction,.Padding,.Gap,.Align_X,.Align_Y,.Columns,.Span,.Self_X,.Self_Y,.Aspect}
// What a state (a rule of a style) can set.
RULE_KEYS :: Style_Keys{.Fill,.Fill2,.Stroke,.Track,.Knob,.Mark,.Radius,.Border,.Shadow_Color,.Shadow_Blur,.Shadow_X,.Shadow_Y,.Font,.Size,.Color,.Outline,.Outline_Color,.Text_Shadow_Color,.Text_Shadow_X,.Text_Shadow_Y,.Move_X,.Move_Y,.Scale}

@(private)
SHADOW_KEYS :: Style_Keys{.Shadow_Color,.Shadow_Blur,.Shadow_X,.Shadow_Y}
@(private)
OUTLINE_KEYS :: Style_Keys{.Outline,.Outline_Color}
@(private)
TEXT_SHADOW_KEYS :: Style_Keys{.Text_Shadow_Color,.Text_Shadow_X,.Text_Shadow_Y}
@(private)
MOVE_KEYS :: Style_Keys{.Move_X,.Move_Y}

// Whether a color key: what a token of color may give it.
style_key_color :: proc "contextless" (key:Style_Key) -> bool {
    #partial switch key {
    case .Fill,.Fill2,.Stroke,.Track,.Knob,.Mark,.Shadow_Color,.Color,.Outline_Color,.Text_Shadow_Color: return true
    }
    return false
}
// Whether a token of number may give it.
style_key_number :: proc "contextless" (key:Style_Key) -> bool {
    #partial switch key {
    case .Radius,.Border,.Shadow_Blur,.Shadow_X,.Shadow_Y,.Size,.Outline,.Text_Shadow_X,.Text_Shadow_Y,.Move_X,.Move_Y,.Scale,.Line_Height,.Transition,.Blur,.Width,.Height,.Padding,.Gap: return true
    }
    return false
}

// Writes a token into a value of a style (and, for a layout key, its layout).
style_key_number_set :: proc "contextless" (s:^Node_Style,info:^Tree_Style_Info,key:Style_Key,n:f32) {
    #partial switch key {
    case .Radius:        s.radius={n,n,n,n}
    case .Border:        s.stroke_width=n
    case .Shadow_Blur:   s.shadow_blur=n
    case .Shadow_X:      s.shadow_offset.x=n
    case .Shadow_Y:      s.shadow_offset.y=n
    case .Size:          s.text.size=n
    case .Outline:       s.text.outline=n
    case .Text_Shadow_X: s.text.shadow.x=n
    case .Text_Shadow_Y: s.text.shadow.y=n
    case .Move_X:        s.move.x=n
    case .Move_Y:        s.move.y=n
    case .Scale:         s.scale=n
    case .Line_Height:   s.text.line_height=n
    case .Transition:    s.transition=n
    case .Blur:          if info!=nil {info.blur=n}
    case .Width:         if info!=nil {info.layout.width=fixed(n)}
    case .Height:        if info!=nil {info.layout.height=fixed(n)}
    case .Padding:       if info!=nil {info.layout.padding=padding_all(n)}
    case .Gap:           if info!=nil {info.layout.gap=n}
    }
}
style_key_color_set :: proc "contextless" (s:^Node_Style,key:Style_Key,c:Color) {
    #partial switch key {
    case .Fill:              s.fill=c
    case .Fill2:             s.fill2=c
    case .Stroke:            s.stroke=c
    case .Track:             s.track=c
    case .Knob:              s.knob=c
    case .Mark:              s.mark=c
    case .Shadow_Color:      s.shadow_color=c;s.shadow=c[3]>0
    case .Color:             s.text.color=c
    case .Outline_Color:     s.text.outline_color=c
    case .Text_Shadow_Color: s.text.shadow_color=c
    }
}

// Copies one value of a style to another (a key of its layout is in the infos).
style_key_copy :: proc "contextless" (to,from:^Node_Style,key:Style_Key) {
    #partial switch key {
    case .Fill:              to.fill=from.fill
    case .Fill2:             to.fill2=from.fill2
    case .Stroke:            to.stroke=from.stroke
    case .Track:             to.track=from.track
    case .Knob:              to.knob=from.knob
    case .Mark:              to.mark=from.mark
    case .Radius:            to.radius=from.radius
    case .Border:            to.stroke_width=from.stroke_width
    case .Shadow_Color:      to.shadow_color=from.shadow_color;to.shadow=from.shadow
    case .Shadow_Blur:       to.shadow_blur=from.shadow_blur
    case .Shadow_X:          to.shadow_offset.x=from.shadow_offset.x
    case .Shadow_Y:          to.shadow_offset.y=from.shadow_offset.y
    case .Font:              to.text.font=from.text.font
    case .Size:              to.text.size=from.text.size
    case .Color:             to.text.color=from.text.color
    case .Outline:           to.text.outline=from.text.outline
    case .Outline_Color:     to.text.outline_color=from.text.outline_color
    case .Text_Shadow_Color: to.text.shadow_color=from.text.shadow_color
    case .Text_Shadow_X:     to.text.shadow.x=from.text.shadow.x
    case .Text_Shadow_Y:     to.text.shadow.y=from.text.shadow.y
    case .Move_X:            to.move.x=from.move.x
    case .Move_Y:            to.move.y=from.move.y
    case .Scale:             to.scale=from.scale
    case .Text_Align_X:      to.text.align_x=from.text.align_x
    case .Text_Align_Y:      to.text.align_y=from.text.align_y
    case .Text_Wrap:         to.text.wrap=from.text.wrap
    case .Ellipsis:          to.text.ellipsis=from.text.ellipsis
    case .Line_Height:       to.text.line_height=from.text.line_height
    case .Fill_Mode:         to.fill_mode=from.fill_mode
    case .Program:           to.program=from.program
    case .Program_Values:    to.program_values=from.program_values
    case .Sounds:            to.sounds=from.sounds
    case .Transition:        to.transition=from.transition
    }
}
// Whether one value of a style differs from another.
style_key_differs :: proc "contextless" (a,b:^Node_Style,key:Style_Key) -> bool {
    x:=a^
    style_key_copy(&x,b,key)
    return x!=a^
}

// Copies one part of a layout to another.
layout_key_copy :: proc "contextless" (to,from:^Layout,key:Style_Key) {
    #partial switch key {
    case .Width:     to.width=from.width
    case .Height:    to.height=from.height
    case .Direction: to.direction=from.direction
    case .Padding:   to.padding=from.padding
    case .Gap:       to.gap=from.gap
    case .Align_X:   to.align_x=from.align_x
    case .Align_Y:   to.align_y=from.align_y
    case .Columns:   to.columns=from.columns
    case .Span:      to.span=from.span
    case .Self_X:    to.self_x=from.self_x
    case .Self_Y:    to.self_y=from.self_y
    case .Aspect:    to.aspect=from.aspect
    }
}

// The fields of a patch the keys of a state set; a shadow, an outline, a text
// shadow or a move is one field whatever of it the state names.
style_keys_fields :: proc "contextless" (keys:Style_Keys) -> (fields:Style_Fields) {
    if .Fill in keys {fields+={.Fill}}
    if .Fill2 in keys {fields+={.Fill2}}
    if .Stroke in keys {fields+={.Stroke}}
    if .Track in keys {fields+={.Track}}
    if .Knob in keys {fields+={.Knob}}
    if .Mark in keys {fields+={.Mark}}
    if .Radius in keys {fields+={.Radius}}
    if .Border in keys {fields+={.Stroke_Width}}
    if keys&SHADOW_KEYS!={} {fields+={.Shadow}}
    if .Font in keys {fields+={.Text_Font}}
    if .Size in keys {fields+={.Text_Size}}
    if .Color in keys {fields+={.Text_Color}}
    if keys&OUTLINE_KEYS!={} {fields+={.Text_Outline}}
    if keys&TEXT_SHADOW_KEYS!={} {fields+={.Text_Shadow}}
    if keys&MOVE_KEYS!={} {fields+={.Move}}
    if .Scale in keys {fields+={.Scale}}
    return
}
// The keys of the fields of a patch: every part of each.
style_fields_keys :: proc "contextless" (fields:Style_Fields) -> (keys:Style_Keys) {
    if .Fill in fields {keys+={.Fill}}
    if .Fill2 in fields {keys+={.Fill2}}
    if .Stroke in fields {keys+={.Stroke}}
    if .Track in fields {keys+={.Track}}
    if .Knob in fields {keys+={.Knob}}
    if .Mark in fields {keys+={.Mark}}
    if .Radius in fields {keys+={.Radius}}
    if .Stroke_Width in fields {keys+={.Border}}
    if .Shadow in fields {keys+=SHADOW_KEYS}
    if .Text_Font in fields {keys+={.Font}}
    if .Text_Size in fields {keys+={.Size}}
    if .Text_Color in fields {keys+={.Color}}
    if .Text_Outline in fields {keys+=OUTLINE_KEYS}
    if .Text_Shadow in fields {keys+=TEXT_SHADOW_KEYS}
    if .Move in fields {keys+=MOVE_KEYS}
    if .Scale in fields {keys+={.Scale}}
    return
}

// The keys a rule sets itself: without a mask, all it has.
rule_own_keys :: proc "contextless" (rule:^Tree_Style_Variant) -> Style_Keys {
    if rule.inherited {return {}}
    return rule.own if rule.own!={} else style_fields_keys(rule.patch.fields)
}

// The keys a style sets itself: with no extends, all it has.
style_own_keys :: proc "contextless" (info:^Tree_Style_Info) -> Style_Keys {
    if info.extends[0]==0 {return ~Style_Keys{}}
    return info.sets
}

// The layout and the blur a node takes from its style: what the style gives
// that the node does not have as its own.
tree_node_take_style :: proc "contextless" (node:^Tree_Node,info:^Tree_Style_Info) {
    for key in info.layout_keys&LAYOUT_KEYS {
        if key not_in node.layout_own {layout_key_copy(&node.layout,&info.layout,key)}
    }
    if info.blur>0 && node.layer=={} {node.layer={enabled=true,opacity=1,backdrop_blur=info.blur}}
}

tree_nodes_take_styles :: proc(nodes:[]Tree_Node,infos:[]Tree_Style_Info) {
    if len(infos)==0 {return}
    for &node in nodes {
        if int(node.style)<len(infos) {tree_node_take_style(&node,&infos[node.style])}
    }
}

// The first control of each page (a tree, a page of a Switcher or a Tabs, a
// Modal or a Popup) takes the focus when it shows, unless a node of that page
// asks for it: a flag the frame reads as ever, set the first time a tree is
// built. A List is passed over: its elements come and go.
tree_pages_focus :: proc "contextless" (nodes:[]Node) {
    focusable :: proc "contextless" (kind:Node_Kind) -> bool {
        #partial switch kind {
        case .Button,.Checkbox,.Slider,.Number,.Field,.Selector,.Dropdown,.Radio:return true
        }
        return false
    }
    page :: proc "contextless" (nodes:[]Node,row:int) -> bool {
        parent:=nodes[row].parent
        if parent<0 {return true}
        #partial switch nodes[parent].kind {
        case .Switcher,.Tabs,.Modal,.Popup:return true
        }
        return false
    }
    for _,row in nodes {
        if !page(nodes,row) {continue}
        first:=-1
        asked:=false
        end:=row+1
        for end<len(nodes) && tree_inside(nodes,end,row) {end+=1}
        // The nodes of the page, without those of a page inside it.
        for at:=row;at<end;at+=1 {
            if at>row && page(nodes,at) {
                root:=at
                for at+1<end && tree_inside(nodes,at+1,root) {at+=1}
                continue
            }
            n:=&nodes[at]
            if n.kind==.List {
                root:=at
                for at+1<end && tree_inside(nodes,at+1,root) {at+=1}
                continue
            }
            if !focusable(n.kind) || .Skip in n.flags {continue}
            asked||=.Focus_First in n.flags
            if first<0 {first=at}
        }
        if first>=0 && !asked {nodes[first].flags+={.Focus_First}}
    }
}

@(private)
tree_inside :: proc "contextless" (nodes:[]Node,row,ancestor:int) -> bool {
    for parent:=nodes[row].parent;parent>=0;parent=nodes[parent].parent {
        if int(parent)==ancestor {return true}
    }
    return false
}

// ---------------------------------------------------------------- settle

// Resolves the names of a file, in place: the values tokens give, what styles
// and rules take from the styles they extend and the states their states
// extend. A name that does not resolve changes nothing (ui.check says so).
tree_settle :: proc(styles:[]Node_Style,infos:[]Tree_Style_Info,variants:^[dynamic]Tree_Style_Variant,tokens:[]Tree_Token,uses:[]Tree_Token_Use) {
    for &use in uses {
        name:=serial.text_field(use.token[:])
        at:=-1
        for &t,i in tokens {if serial.text_field(t.name[:])==name {at=i;break}}
        if at<0 || int(use.style)>=len(styles) {continue}
        token:=&tokens[at]
        info:=&infos[use.style] if int(use.style)<len(infos) else nil
        if use.variant[0]==0 && use.states=={} {
            if token.numeric {style_key_number_set(&styles[use.style],info,use.key,token.number)} else {style_key_color_set(&styles[use.style],use.key,token.color)}
            continue
        }
        for &rule in variants {
            if rule.style!=use.style || rule.states!=use.states || rule.variant!=use.variant {continue}
            if token.numeric {style_key_number_set(&rule.patch.values,nil,use.key,token.number)} else {style_key_color_set(&rule.patch.values,use.key,token.color)}
        }
    }
    done:=make([]bool,len(styles),context.temp_allocator)
    for row in 0..<len(styles) {settle_style(styles,infos,variants,done,row)}
}

@(private)
settle_style :: proc(styles:[]Node_Style,infos:[]Tree_Style_Info,variants:^[dynamic]Tree_Style_Variant,done:[]bool,row:int) {
    if row>=len(infos) || done[row] {return}
    done[row]=true
    info:=&infos[row]
    name:=serial.text_field(info.extends[:])
    parent:=-1
    if name!="" {
        for &other,i in infos {
            if i!=row && serial.text_field(other.name[:])==name {parent=i;break}
        }
    }
    own_layout:=info.sets&LAYOUT_KEYS
    if parent<0 {
        // A style a file lends keeps what its file said it gives.
        if info.sets!={} || name!="" {info.layout_keys=own_layout}
        settle_rules(styles,variants,row,row,false)
        return
    }
    settle_style(styles,infos,variants,done,parent)
    up:=&infos[parent]
    for key in Style_Key {
        if key in info.sets {continue}
        switch {
        case key==.Blur:        info.blur=up.blur
        case key in LAYOUT_KEYS: layout_key_copy(&info.layout,&up.layout,key)
        case: style_key_copy(&styles[row],&styles[parent],key)
        }
    }
    info.layout_keys=own_layout|up.layout_keys
    settle_rules(styles,variants,row,parent,true)
}

// The rules of the style at row: those it inherits from the style at parent
// and what each takes from a state of its style it extends.
@(private)
settle_rules :: proc(styles:[]Node_Style,variants:^[dynamic]Tree_Style_Variant,row,parent:int,inherits:bool) {
    if inherits {
        for i:=len(variants)-1;i>=0;i-=1 {
            if int(variants[i].style)==row && variants[i].inherited {ordered_remove(variants,i)}
        }
        count:=len(variants)
        for i in 0..<count {
            from:=variants[i]
            if int(from.style)!=parent {continue}
            at:=-1
            for &rule,j in variants[:count] {
                if int(rule.style)==row && rule.states==from.states && rule.variant==from.variant {at=j;break}
            }
            if at<0 {
                copied:=from
                copied.style,copied.inherited,copied.own,copied.extends=u16(row),true,{},{}
                append(variants,copied)
                continue
            }
            rule:=&variants[at]
            own:=rule_own_keys(rule)
            keys:=style_fields_keys(from.patch.fields)
            for key in keys-own {style_key_copy(&rule.patch.values,&from.patch.values,key)}
            rule.patch.fields=style_keys_fields(own|keys)
        }
    }
    // A state starts from a state of its style and variant: over the rounds a
    // chain resolves and a cycle stops changing.
    for round in 0..<len(Style_State) {
        _=round
        for &rule in variants {
            if int(rule.style)!=row || rule.inherited || rule.extends=={} {continue}
            for &from in variants {
                if int(from.style)!=row || from.states!=rule.extends || from.variant!=rule.variant {continue}
                own:=rule_own_keys(&rule)
                keys:=style_fields_keys(from.patch.fields)
                for key in keys-own {style_key_copy(&rule.patch.values,&from.patch.values,key)}
                rule.patch.fields=style_keys_fields(own|keys)
                break
            }
        }
    }
    // What a state leaves out of a shadow, an outline, a text shadow or a
    // move is what its style has.
    for &rule in variants {
        if int(rule.style)!=row || rule.inherited {continue}
        own:=rule_own_keys(&rule)
        for group in ([4]Style_Keys{SHADOW_KEYS,OUTLINE_KEYS,TEXT_SHADOW_KEYS,MOVE_KEYS}) {
            if own&group=={} || own&group==group {continue}
            for key in group-own {style_key_copy(&rule.patch.values,&styles[row],key)}
        }
        if rule.own!={} && own&SHADOW_KEYS!={} {rule.patch.values.shadow=rule.patch.values.shadow_color[3]>0}
    }
}
