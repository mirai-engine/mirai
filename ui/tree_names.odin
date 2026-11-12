package ui

import "mirai:std/base"
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
    Fill_Mode, Program, Program_Values, Sounds, Transition, Layout_Transition, Blur,
    Width, Height, Direction, Padding, Gap, Align_X, Align_Y, Columns, Span, Self_X, Self_Y, Aspect,
    Italic, Gradient,
}
Style_Keys :: bit_set[Style_Key;u64]

LAYOUT_KEYS :: Style_Keys{.Width,.Height,.Direction,.Padding,.Gap,.Align_X,.Align_Y,.Columns,.Span,.Self_X,.Self_Y,.Aspect}

// What a value is to whoever reads or writes it by its key.
Style_Key_Kind :: enum u8 {
    Number,  // an f32
    Color,
    Enum,    // a member of type, in one byte
    Flag,    // a bool
    Count,   // a whole number, as wide as size
    Corners, // [4]f32: one number for the four, or each
    Sides,   // [4]f32: one number for the four, one for each axis, or each
    Size,
    Font,    // a face: FONT_REGULAR and the others, or FONT_TREE plus a row of the fonts of its file
    Program, // the name of a ui program
    Numbers, // [4]f32
    Sounds,  // a .sound for each Sound_Cue
}
// The struct a value is in.
Style_Key_Place :: enum u8 {
    Style,  // Node_Style
    Layout, // Layout: that of a style (Tree_Style_Info.layout) or of a node
    Info,   // Tree_Style_Info
}
Style_Key_Info :: struct {
    name:string,       // as a document says it; that of a part of a group, inside it
    group:string,      // the object of a document its parts go in; empty: by itself
    kind:Style_Key_Kind,
    place:Style_Key_Place,
    offset,size:u16,   // in the struct of its place
    type:typeid,       // of an Enum
    rule:bool,         // a state (a rule of a style) can set it
    field:Style_Field, // of the patch of a rule: what carries it there
}

// Every key: what reads, writes, copies and compares a value goes by its row.
@(rodata)
STYLE_KEYS := [Style_Key]Style_Key_Info{
    .Fill={name="fill",kind=.Color,offset=u16(offset_of(Node_Style,fill)),size=size_of(Color),rule=true,field=.Fill},
    .Fill2={name="fill2",kind=.Color,offset=u16(offset_of(Node_Style,fill2)),size=size_of(Color),rule=true,field=.Fill2},
    .Stroke={name="stroke",kind=.Color,offset=u16(offset_of(Node_Style,stroke)),size=size_of(Color),rule=true,field=.Stroke},
    .Track={name="track",kind=.Color,offset=u16(offset_of(Node_Style,track)),size=size_of(Color),rule=true,field=.Track},
    .Knob={name="knob",kind=.Color,offset=u16(offset_of(Node_Style,knob)),size=size_of(Color),rule=true,field=.Knob},
    .Mark={name="mark",kind=.Color,offset=u16(offset_of(Node_Style,mark)),size=size_of(Color),rule=true,field=.Mark},
    .Radius={name="radius",kind=.Corners,offset=u16(offset_of(Node_Style,radius)),size=size_of([4]f32),rule=true,field=.Radius},
    .Border={name="border",kind=.Number,offset=u16(offset_of(Node_Style,stroke_width)),size=size_of(f32),rule=true,field=.Stroke_Width},
    .Shadow_Color={name="color",group="shadow",kind=.Color,offset=u16(offset_of(Node_Style,shadow_color)),size=size_of(Color),rule=true,field=.Shadow},
    .Shadow_Blur={name="blur",group="shadow",kind=.Number,offset=u16(offset_of(Node_Style,shadow_blur)),size=size_of(f32),rule=true,field=.Shadow},
    .Shadow_X={name="x",group="shadow",kind=.Number,offset=u16(offset_of(Node_Style,shadow_offset)),size=size_of(f32),rule=true,field=.Shadow},
    .Shadow_Y={name="y",group="shadow",kind=.Number,offset=u16(offset_of(Node_Style,shadow_offset)+size_of(f32)),size=size_of(f32),rule=true,field=.Shadow},
    .Font={name="font",kind=.Font,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,font)),size=size_of(u8),rule=true,field=.Text_Font},
    .Size={name="size",kind=.Number,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,size)),size=size_of(f32),rule=true,field=.Text_Size},
    .Color={name="color",kind=.Color,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,color)),size=size_of(Color),rule=true,field=.Text_Color},
    .Outline={name="outline",kind=.Number,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,outline)),size=size_of(f32),rule=true,field=.Text_Outline},
    .Outline_Color={name="outline_color",kind=.Color,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,outline_color)),size=size_of(Color),rule=true,field=.Text_Outline},
    .Text_Shadow_Color={name="color",group="text_shadow",kind=.Color,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,shadow_color)),size=size_of(Color),rule=true,field=.Text_Shadow},
    .Text_Shadow_X={name="x",group="text_shadow",kind=.Number,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,shadow)),size=size_of(f32),rule=true,field=.Text_Shadow},
    .Text_Shadow_Y={name="y",group="text_shadow",kind=.Number,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,shadow)+size_of(f32)),size=size_of(f32),rule=true,field=.Text_Shadow},
    .Move_X={name="move_x",kind=.Number,offset=u16(offset_of(Node_Style,move)),size=size_of(f32),rule=true,field=.Move},
    .Move_Y={name="move_y",kind=.Number,offset=u16(offset_of(Node_Style,move)+size_of(f32)),size=size_of(f32),rule=true,field=.Move},
    .Scale={name="scale",kind=.Number,offset=u16(offset_of(Node_Style,scale)),size=size_of(f32),rule=true,field=.Scale},
    .Text_Align_X={name="text_x",kind=.Enum,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,align_x)),size=size_of(Align),type=Align},
    .Text_Align_Y={name="text_y",kind=.Enum,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,align_y)),size=size_of(Align),type=Align},
    .Text_Wrap={name="wrap",kind=.Enum,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,wrap)),size=size_of(Text_Wrap),type=Text_Wrap},
    .Ellipsis={name="ellipsis",kind=.Flag,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,ellipsis)),size=size_of(bool)},
    .Line_Height={name="line_height",kind=.Number,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,line_height)),size=size_of(f32)},
    .Fill_Mode={name="fill_mode",kind=.Enum,offset=u16(offset_of(Node_Style,fill_mode)),size=size_of(Progress_Fill),type=Progress_Fill},
    .Program={name="program",kind=.Program,offset=u16(offset_of(Node_Style,program)),size=TREE_NAME_CAPACITY},
    .Program_Values={name="program_values",kind=.Numbers,offset=u16(offset_of(Node_Style,program_values)),size=size_of([4]f32)},
    .Sounds={name="sounds",kind=.Sounds,offset=u16(offset_of(Node_Style,sounds)),size=size_of([Sound_Cue]base.Asset_Id)},
    .Transition={name="transition",kind=.Number,offset=u16(offset_of(Node_Style,transition)),size=size_of(f32)},
    .Layout_Transition={name="layout_transition",kind=.Number,offset=u16(offset_of(Node_Style,layout_transition)),size=size_of(f32)},
    .Blur={name="blur",kind=.Number,place=.Info,offset=u16(offset_of(Tree_Style_Info,blur)),size=size_of(f32)},
    .Width={name="width",kind=.Size,place=.Layout,offset=u16(offset_of(Layout,width)),size=size_of(Size)},
    .Height={name="height",kind=.Size,place=.Layout,offset=u16(offset_of(Layout,height)),size=size_of(Size)},
    .Direction={name="direction",kind=.Enum,place=.Layout,offset=u16(offset_of(Layout,direction)),size=size_of(Direction),type=Direction},
    .Padding={name="padding",kind=.Sides,place=.Layout,offset=u16(offset_of(Layout,padding)),size=size_of([4]f32)},
    .Gap={name="gap",kind=.Number,place=.Layout,offset=u16(offset_of(Layout,gap)),size=size_of(f32)},
    .Align_X={name="align_x",kind=.Enum,place=.Layout,offset=u16(offset_of(Layout,align_x)),size=size_of(Align),type=Align},
    .Align_Y={name="align_y",kind=.Enum,place=.Layout,offset=u16(offset_of(Layout,align_y)),size=size_of(Align),type=Align},
    .Columns={name="columns",kind=.Count,place=.Layout,offset=u16(offset_of(Layout,columns)),size=size_of(u16)},
    .Span={name="span",kind=.Count,place=.Layout,offset=u16(offset_of(Layout,span)),size=size_of(u8)},
    .Self_X={name="self_x",kind=.Enum,place=.Layout,offset=u16(offset_of(Layout,self_x)),size=size_of(Self_Align),type=Self_Align},
    .Self_Y={name="self_y",kind=.Enum,place=.Layout,offset=u16(offset_of(Layout,self_y)),size=size_of(Self_Align),type=Self_Align},
    .Aspect={name="aspect",kind=.Number,place=.Layout,offset=u16(offset_of(Layout,aspect)),size=size_of(f32)},
    .Italic={name="italic",kind=.Flag,offset=u16(offset_of(Node_Style,text)+offset_of(Text_Style,italic)),size=size_of(bool)},
    .Gradient={name="gradient",kind=.Enum,offset=u16(offset_of(Node_Style,gradient)),size=size_of(Fill_Gradient),type=Fill_Gradient},
}

// The bytes of a value of a style; none for a key of its layout or its blur.
style_key_value :: proc "contextless" (s:^Node_Style,key:Style_Key) -> []u8 {
    k:=STYLE_KEYS[key]
    if k.place!=.Style {return nil}
    return ([^]u8)(s)[k.offset:][:k.size]
}
// The bytes of a part of a layout; none for another key.
layout_key_value :: proc "contextless" (l:^Layout,key:Style_Key) -> []u8 {
    k:=STYLE_KEYS[key]
    if k.place!=.Layout {return nil}
    return ([^]u8)(l)[k.offset:][:k.size]
}
// The bytes of a value wherever a style keeps it: in its look, or in its info
// (its layout and its blur); none when the value is in an info that is nil.
style_value :: proc "contextless" (s:^Node_Style,info:^Tree_Style_Info,key:Style_Key) -> []u8 {
    k:=STYLE_KEYS[key]
    switch k.place {
    case .Style:  return style_key_value(s,key)
    case .Layout: if info!=nil {return layout_key_value(&info.layout,key)}
    case .Info:   if info!=nil {return ([^]u8)(info)[k.offset:][:k.size]}
    }
    return nil
}

// Whether a color key: what a token of color may give it.
style_key_color :: proc "contextless" (key:Style_Key) -> bool {return STYLE_KEYS[key].kind==.Color}
// Whether a token of number may give it.
style_key_number :: proc "contextless" (key:Style_Key) -> bool {
    #partial switch STYLE_KEYS[key].kind {
    case .Number,.Corners,.Sides,.Size: return true
    }
    return false
}

// Writes a token into a value of a style (and, for a layout key, its layout).
style_key_number_set :: proc "contextless" (s:^Node_Style,info:^Tree_Style_Info,key:Style_Key,n:f32) {
    value:=raw_data(style_value(s,info,key))
    if value==nil {return}
    #partial switch STYLE_KEYS[key].kind {
    case .Number:         (^f32)(value)^=n
    case .Corners,.Sides: (^[4]f32)(value)^={n,n,n,n}
    case .Size:           (^Size)(value)^=fixed(n)
    }
}
style_key_color_set :: proc "contextless" (s:^Node_Style,key:Style_Key,c:Color) {
    if !style_key_color(key) {return}
    (^Color)(raw_data(style_key_value(s,key)))^=c
    if key==.Shadow_Color {s.shadow=c[3]>0}
}

// Copies one value of a style to another (a key of its layout is in the infos).
style_key_copy :: proc "contextless" (to,from:^Node_Style,key:Style_Key) {
    copy(style_key_value(to,key),style_key_value(from,key))
    if key==.Shadow_Color {to.shadow=from.shadow}
}
// Whether one value of a style differs from another.
style_key_differs :: proc "contextless" (a,b:^Node_Style,key:Style_Key) -> bool {
    return string(style_key_value(a,key))!=string(style_key_value(b,key)) || key==.Shadow_Color && a.shadow!=b.shadow
}

// Copies one part of a layout to another.
layout_key_copy :: proc "contextless" (to,from:^Layout,key:Style_Key) {
    copy(layout_key_value(to,key),layout_key_value(from,key))
}

// The fields of a patch the keys of a state set; a shadow, an outline, a text
// shadow or a move is one field whatever of it the state names.
style_keys_fields :: proc "contextless" (keys:Style_Keys) -> (fields:Style_Fields) {
    for key in keys {
        if k:=STYLE_KEYS[key];k.rule {fields+={k.field}}
    }
    return
}
// The keys of the fields of a patch: every part of each.
style_fields_keys :: proc "contextless" (fields:Style_Fields) -> (keys:Style_Keys) {
    for key in Style_Key {
        if k:=STYLE_KEYS[key];k.rule && k.field in fields {keys+={key}}
    }
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
        for field in Style_Field {
            group:=style_fields_keys({field})
            if own&group=={} || own&group==group {continue}
            for key in group-own {style_key_copy(&rule.patch.values,&styles[row],key)}
        }
        if rule.own!={} && own&style_fields_keys({.Shadow})!={} {rule.patch.values.shadow=rule.patch.values.shadow_color[3]>0}
    }
}
