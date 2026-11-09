package ui

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "mirai:std/base"
import "mirai:std/serial"

// An interface written by names: a content tool declares tokens and styles,
// styles extend others and list what each state changes, and nodes name the
// style they take. A Sheet compiles into the records of a Tree_Data: the
// frame reads the same Node_Style and Style_Variant tables as ever and a
// sheet exists only while the tool runs. Allocates in its allocator, the temp
// one by default, and never fails while it builds: the first thing wrong is
// kept for sheet_problem.

// A color: the name of a token, "#rrggbb", "#rrggbbaa", or a Color.
Sheet_Color :: union {string,Color}
// A size: a number, or the name of a token.
Sheet_Number :: union {f32,string}
Sheet_Token :: struct {name:string,value:union {f32,string,Color}}

// A shadow: blurred with blur, a hard edge of its shape without. Without a
// color it has none.
Sheet_Shadow :: struct {color:Sheet_Color,blur,x,y:Sheet_Number}

// What a state can change: every field left out stays as the base has it.
Sheet_Look :: struct {
    fill,fill2,stroke,track,knob,mark:Sheet_Color,
    radius:Sheet_Number,     // of every corner, or
    radii:Maybe([4]f32),     // of each one: top left, top right, bottom right, bottom left
    border:Sheet_Number,     // stroke width
    shadow:Sheet_Shadow,
    font:Maybe(u8),          // FONT_MEDIUM, FONT_SEMIBOLD or what sheet_font gives
    size:Sheet_Number,       // of its text
    color:Sheet_Color,       // of its text
    outline:Sheet_Number,    // around its text
    outline_color:Sheet_Color,
    text_shadow:Sheet_Shadow, // of its text: x, y and color
    move_x,move_y:Sheet_Number, // drawn this far from where the layout put it
    scale:Sheet_Number,      // drawn this size around its center
}
// A named variant a node picks with variant or bind_variant.
Sheet_Variant :: struct {
    name:string,
    using look:Sheet_Look,
}
// A style: its look, what it adds to the styles it extends (in order, each
// over the last) and what each state changes.
Sheet_Style :: struct {
    name:string,
    extends:[]string,
    using look:Sheet_Look,
    align_x,align_y:Maybe(Align),
    wrap:Maybe(Text_Wrap),
    ellipsis:Maybe(bool),
    line_height:Sheet_Number,
    transition:Sheet_Number, // seconds it takes between states
    blur:Sheet_Number,       // of what is behind a node that takes it
    fill_mode:Maybe(Progress_Fill),
    program:string,          // a ui program that colors the fill
    program_values:Maybe([4]f32),
    sounds:[Sound_Cue]base.Asset_Id,
    selected,hover,focus,over,pressed,disabled:Sheet_Look,
    variants:[]Sheet_Variant,
}
// What a use of a component changes in a node of the component, by its name.
Sheet_Set :: struct {
    node:string,
    using desc:Node_Desc,
    look:string, // over the style of that node
}

@(private)
Sheet_Entry :: struct {
    style:Sheet_Style,
    row:u16,
    linked:bool, // of a sheet taken: row names it by name when the records are linked
}
@(private)
Sheet_Taken :: struct {
    file:base.Asset_Id,
    sheet:^Sheet,
    row:u16, // component row plus one of the library of the file; 0: none yet
}

Sheet :: struct {
    name:string,
    tokens:[dynamic]Sheet_Token,
    styles:[dynamic]Sheet_Entry,
    taken:[dynamic]Sheet_Taken,
    problem:string,
    building:bool,             // sheet_node writes the component open
    first:int,                 // of the component open, in component_nodes
    // The records. What has no authoring of its own is filled as it is.
    text:[dynamic]u8,
    nodes,component_nodes:[dynamic]Tree_Node,
    rows:[dynamic]Node_Style,
    infos:[dynamic]Tree_Style_Info,
    variants:[dynamic]Tree_Style_Variant,
    components:[dynamic]Tree_Component,
    overrides:[dynamic]Tree_Override,
    images:[dynamic]Tree_Image,
    fonts:[dynamic]Tree_Font,
    grid_tracks:[dynamic]Grid_Tracks,
    translations:[dynamic]Tree_Translation,
    anims:[]Tree_Anim,
    tracks:[]Tree_Track,
    keys:[]Keyframe,
    parts:[]Anim,
    anim_sets:[]Anim_Set,
    allocator:runtime.Allocator,
}

sheet_make :: proc(name:string,allocator:=context.temp_allocator) -> (s:Sheet) {
    s.name,s.allocator=name,allocator
    s.tokens=make([dynamic]Sheet_Token,allocator)
    s.styles=make([dynamic]Sheet_Entry,allocator)
    s.taken=make([dynamic]Sheet_Taken,allocator)
    s.text=make([dynamic]u8,allocator)
    s.nodes=make([dynamic]Tree_Node,allocator)
    s.component_nodes=make([dynamic]Tree_Node,allocator)
    s.rows=make([dynamic]Node_Style,allocator)
    s.infos=make([dynamic]Tree_Style_Info,allocator)
    s.variants=make([dynamic]Tree_Style_Variant,allocator)
    s.components=make([dynamic]Tree_Component,allocator)
    s.overrides=make([dynamic]Tree_Override,allocator)
    s.images=make([dynamic]Tree_Image,allocator)
    s.fonts=make([dynamic]Tree_Font,allocator)
    s.grid_tracks=make([dynamic]Grid_Tracks,allocator)
    s.translations=make([dynamic]Tree_Translation,allocator)
    append(&s.rows,Node_Style{}) // style 0: what a node without a style takes
    append(&s.infos,Tree_Style_Info{})
    return
}

// What the sheet got wrong first and how to fix it; empty when nothing did.
sheet_problem :: proc(s:^Sheet) -> string {return s.problem}

@(private)
sheet_fail :: proc(s:^Sheet,format:string,args:..any) {
    if s.problem=="" {s.problem=fmt.aprintf(format,..args,allocator=s.allocator)}
}

// Takes the tokens, styles and components of another sheet, which is written
// to file: styles and tokens are named here as there, and what a node here
// takes comes from file when the records are linked. other must outlive s.
sheet_take :: proc(s:^Sheet,file:base.Asset_Id,other:^Sheet) {
    if file=={} {sheet_fail(s,"sheet '%s' takes sheet '%s' with no file: pass the id of the .ui it is written to",s.name,other.name);return}
    append(&s.taken,Sheet_Taken{file=file,sheet=other})
}

// Adds tokens: a later one of the same name replaces an earlier one, and a
// token may name another.
sheet_tokens :: proc(s:^Sheet,tokens:[]Sheet_Token) {
    for token in tokens {
        value:=token
        if text,named:=token.value.(string);named && text!="" && text[0]!='#' {
            found,ok:=sheet_token(s,text)
            if !ok {sheet_fail(s,"token '%s' names '%s', which is no token here: declare it first",token.name,text);continue}
            value.value=found
        }
        append(&s.tokens,value)
    }
}

@(private)
sheet_token :: proc(s:^Sheet,name:string) -> (value:union {f32,string,Color},ok:bool) {
    #reverse for &t in s.tokens {if t.name==name {return t.value,true}}
    for &taken in s.taken {
        if value,ok=sheet_token(taken.sheet,name);ok {return}
    }
    return nil,false
}

@(private)
sheet_parse :: proc(text:string) -> (color:Color,ok:bool) {
    digits:=len(text)-1
    if len(text)<2 || text[0]!='#' || digits!=6 && digits!=8 {return}
    value,parsed:=strconv.parse_u64_of_base(text[1:],16)
    if !parsed {return}
    if digits==6 {value=value<<8|0xff}
    return Color{u8(value>>24),u8(value>>16),u8(value>>8),u8(value)},true
}

@(private)
sheet_color :: proc(s:^Sheet,color:^Sheet_Color,style,part:string) {
    text,named:=color.(string)
    if !named {return}
    if text!="" && text[0]=='#' {
        parsed,ok:=sheet_parse(text)
        if !ok {sheet_fail(s,"style '%s': %s '%s' is no color: write #rrggbb or #rrggbbaa",style,part,text);return}
        color^=parsed
        return
    }
    token,found:=sheet_token(s,text)
    if !found {sheet_fail(s,"style '%s': %s names the token '%s', which is not declared",style,part,text);return}
    switch v in token {
    case Color:  color^=v
    case string:
        parsed,ok:=sheet_parse(v)
        if !ok {sheet_fail(s,"style '%s': token '%s' for %s is no color: write #rrggbb or #rrggbbaa",style,text,part);return}
        color^=parsed
    case f32:
        sheet_fail(s,"style '%s': %s names the token '%s', which is a size",style,part,text)
    }
}
@(private)
sheet_number :: proc(s:^Sheet,number:^Sheet_Number,style,part:string) {
    text,named:=number.(string)
    if !named {return}
    token,found:=sheet_token(s,text)
    if !found {sheet_fail(s,"style '%s': %s names the token '%s', which is not declared",style,part,text);return}
    value,size:=token.(f32)
    if !size {sheet_fail(s,"style '%s': %s names the token '%s', which is a color",style,part,text);return}
    number^=value
}

@(private)
sheet_look_resolve :: proc(s:^Sheet,l:^Sheet_Look,name:string) {
    sheet_color(s,&l.fill,name,"fill");sheet_color(s,&l.fill2,name,"fill2");sheet_color(s,&l.stroke,name,"stroke")
    sheet_color(s,&l.track,name,"track");sheet_color(s,&l.knob,name,"knob");sheet_color(s,&l.mark,name,"mark")
    sheet_number(s,&l.radius,name,"radius");sheet_number(s,&l.border,name,"border")
    sheet_shadow_resolve(s,&l.shadow,name,"shadow")
    sheet_number(s,&l.size,name,"size");sheet_color(s,&l.color,name,"color")
    sheet_number(s,&l.outline,name,"outline");sheet_color(s,&l.outline_color,name,"outline_color")
    sheet_shadow_resolve(s,&l.text_shadow,name,"text_shadow")
    sheet_number(s,&l.move_x,name,"move_x");sheet_number(s,&l.move_y,name,"move_y");sheet_number(s,&l.scale,name,"scale")
}
@(private)
sheet_shadow_resolve :: proc(s:^Sheet,shadow:^Sheet_Shadow,name,part:string) {
    sheet_color(s,&shadow.color,name,part)
    sheet_number(s,&shadow.blur,name,part);sheet_number(s,&shadow.x,name,part);sheet_number(s,&shadow.y,name,part)
}

@(private)
sheet_shadow_over :: proc(to:^Sheet_Shadow,from:Sheet_Shadow) {
    if from.color!=nil {to.color=from.color}
    if from.blur!=nil {to.blur=from.blur}
    if from.x!=nil {to.x=from.x}
    if from.y!=nil {to.y=from.y}
}
@(private)
sheet_look_over :: proc(to:^Sheet_Look,from:Sheet_Look) {
    if from.fill!=nil {to.fill=from.fill}
    if from.fill2!=nil {to.fill2=from.fill2}
    if from.stroke!=nil {to.stroke=from.stroke}
    if from.track!=nil {to.track=from.track}
    if from.knob!=nil {to.knob=from.knob}
    if from.mark!=nil {to.mark=from.mark}
    if from.radius!=nil {to.radius,to.radii=from.radius,nil}
    if from.radii!=nil {to.radii,to.radius=from.radii,nil}
    if from.border!=nil {to.border=from.border}
    sheet_shadow_over(&to.shadow,from.shadow)
    if from.font!=nil {to.font=from.font}
    if from.size!=nil {to.size=from.size}
    if from.color!=nil {to.color=from.color}
    if from.outline!=nil {to.outline=from.outline}
    if from.outline_color!=nil {to.outline_color=from.outline_color}
    sheet_shadow_over(&to.text_shadow,from.text_shadow)
    if from.move_x!=nil {to.move_x=from.move_x}
    if from.move_y!=nil {to.move_y=from.move_y}
    if from.scale!=nil {to.scale=from.scale}
}
@(private)
sheet_style_over :: proc(s:^Sheet,to:^Sheet_Style,from:Sheet_Style) {
    sheet_look_over(&to.look,from.look)
    if from.align_x!=nil {to.align_x=from.align_x}
    if from.align_y!=nil {to.align_y=from.align_y}
    if from.wrap!=nil {to.wrap=from.wrap}
    if from.ellipsis!=nil {to.ellipsis=from.ellipsis}
    if from.line_height!=nil {to.line_height=from.line_height}
    if from.transition!=nil {to.transition=from.transition}
    if from.blur!=nil {to.blur=from.blur}
    if from.fill_mode!=nil {to.fill_mode=from.fill_mode}
    if from.program!="" {to.program=from.program}
    if from.program_values!=nil {to.program_values=from.program_values}
    for cue in Sound_Cue {if from.sounds[cue]!={} {to.sounds[cue]=from.sounds[cue]}}
    sheet_look_over(&to.selected,from.selected)
    sheet_look_over(&to.hover,from.hover)
    sheet_look_over(&to.focus,from.focus)
    sheet_look_over(&to.over,from.over)
    sheet_look_over(&to.pressed,from.pressed)
    sheet_look_over(&to.disabled,from.disabled)
    // A variant of the same name is written over; the others are kept.
    kept:=make([dynamic]Sheet_Variant,0,len(to.variants)+len(from.variants),s.allocator)
    append(&kept,..to.variants)
    outer: for variant in from.variants {
        for &earlier in kept {
            if earlier.name==variant.name {sheet_look_over(&earlier.look,variant.look);continue outer}
        }
        append(&kept,variant)
    }
    to.variants=kept[:]
}

@(private)
sheet_shadow_set :: proc "contextless" (shadow:Sheet_Shadow) -> bool {
    return shadow.color!=nil || shadow.blur!=nil || shadow.x!=nil || shadow.y!=nil
}
@(private)
sheet_num :: proc "contextless" (number:Sheet_Number) -> f32 {
    v,_:=number.(f32)
    return v
}
@(private)
sheet_col :: proc "contextless" (color:Sheet_Color) -> Color {
    v,_:=color.(Color)
    return v
}

// The rule of a look over base: the fields the look sets. What a shadow, an
// outline or a text shadow does not set stays as base has it.
@(private)
sheet_patch :: proc(base:^Sheet_Look,l:^Sheet_Look) -> (patch:Style_Patch) {
    v:=&patch.values
    set :: proc "contextless" (patch:^Style_Patch,on:bool,field:Style_Field) {if on {patch.fields+={field}}}
    v.fill,v.fill2,v.stroke,v.track,v.knob,v.mark=sheet_col(l.fill),sheet_col(l.fill2),sheet_col(l.stroke),sheet_col(l.track),sheet_col(l.knob),sheet_col(l.mark)
    set(&patch,l.fill!=nil,.Fill);set(&patch,l.fill2!=nil,.Fill2);set(&patch,l.stroke!=nil,.Stroke)
    set(&patch,l.track!=nil,.Track);set(&patch,l.knob!=nil,.Knob);set(&patch,l.mark!=nil,.Mark)
    if radii,ok:=l.radii.?;ok {v.radius=radii;patch.fields+={.Radius}} else if l.radius!=nil {
        r:=sheet_num(l.radius)
        v.radius={r,r,r,r}
        patch.fields+={.Radius}
    }
    v.stroke_width=sheet_num(l.border);set(&patch,l.border!=nil,.Stroke_Width)
    if sheet_shadow_set(l.shadow) {
        merged:=base.shadow
        sheet_shadow_over(&merged,l.shadow)
        v.shadow_color=sheet_col(merged.color)
        v.shadow,v.shadow_blur,v.shadow_offset=v.shadow_color[3]>0,sheet_num(merged.blur),{sheet_num(merged.x),sheet_num(merged.y)}
        patch.fields+={.Shadow}
    }
    if l.font!=nil {v.text.font=l.font.?;patch.fields+={.Text_Font}}
    v.text.size=sheet_num(l.size);set(&patch,l.size!=nil,.Text_Size)
    v.text.color=sheet_col(l.color);set(&patch,l.color!=nil,.Text_Color)
    if l.outline!=nil || l.outline_color!=nil {
        width:=l.outline if l.outline!=nil else base.outline
        color:=l.outline_color if l.outline_color!=nil else base.outline_color
        v.text.outline,v.text.outline_color=sheet_num(width),sheet_col(color)
        patch.fields+={.Text_Outline}
    }
    if sheet_shadow_set(l.text_shadow) {
        merged:=base.text_shadow
        sheet_shadow_over(&merged,l.text_shadow)
        v.text.shadow,v.text.shadow_color={sheet_num(merged.x),sheet_num(merged.y)},sheet_col(merged.color)
        patch.fields+={.Text_Shadow}
    }
    if l.move_x!=nil || l.move_y!=nil {
        x:=l.move_x if l.move_x!=nil else base.move_x
        y:=l.move_y if l.move_y!=nil else base.move_y
        v.move={sheet_num(x),sheet_num(y)}
        patch.fields+={.Move}
    }
    v.scale=sheet_num(l.scale);set(&patch,l.scale!=nil,.Scale)
    return
}

// The rows of a style: a style for the base, a rule for each state it changes
// and for each of its variants.
@(private)
sheet_compile :: proc(s:^Sheet,style:^Sheet_Style) -> u16 {
    row:=u16(len(s.rows))
    base:=&style.look
    compiled:=style_patch(nil,Node_Style{},sheet_patch(base,base))
    compiled.text.align_x=style.align_x.? or_else .Start
    compiled.text.align_y=style.align_y.? or_else .Start
    compiled.text.wrap=style.wrap.? or_else {}
    compiled.text.ellipsis=style.ellipsis.? or_else false
    compiled.text.line_height=sheet_num(style.line_height)
    compiled.transition=sheet_num(style.transition)
    compiled.fill_mode=style.fill_mode.? or_else .Right
    compiled.program_values=style.program_values.? or_else {}
    compiled.sounds=style.sounds
    tree_text_set(compiled.program[:],style.program)
    if len(style.program)>=len(compiled.program) {sheet_fail(s,"style '%s': the name of its program is too long",style.name)}
    append(&s.rows,compiled)
    info:Tree_Style_Info
    if len(style.name)>=len(info.name) {sheet_fail(s,"style '%s': its name is too long",style.name)}
    tree_text_set(info.name[:],style.name)
    append(&s.infos,info)
    rule :: proc(s:^Sheet,row:u16,base,look:^Sheet_Look,variant:string,states:Style_States) {
        if mem.check_zero_ptr(look,size_of(Sheet_Look)) {return}
        append(&s.variants,tree_variant_record(row,variant,states,sheet_patch(base,look)))
    }
    rule(s,row,base,&style.selected,"",{.Selected})
    rule(s,row,base,&style.hover,"",{.Hovered})
    rule(s,row,base,&style.focus,"",{.Focused})
    rule(s,row,base,&style.over,"",{.Over})
    rule(s,row,base,&style.pressed,"",{.Pressed})
    rule(s,row,base,&style.disabled,"",{.Disabled})
    for &variant in style.variants {
        rule(s,row,base,&variant.look,variant.name,{})
    }
    return row
}

// Declares styles, in order: a style extends styles declared before it, here
// or in a sheet taken.
sheet_styles :: proc(s:^Sheet,styles:[]Sheet_Style) {
    for style in styles {
        merged:Sheet_Style
        for parent in style.extends {
            found,_:=sheet_style(s,parent)
            if found==nil {sheet_fail(s,"style '%s' extends '%s', which is not declared before it here or in a sheet taken",style.name,parent);continue}
            sheet_style_over(s,&merged,found.style)
        }
        sheet_style_over(s,&merged,style)
        merged.name=style.name
        merged.extends=nil
        name:=style.name
        sheet_look_resolve(s,&merged.look,name)
        sheet_number(s,&merged.line_height,name,"line_height");sheet_number(s,&merged.transition,name,"transition");sheet_number(s,&merged.blur,name,"blur")
        sheet_look_resolve(s,&merged.selected,name);sheet_look_resolve(s,&merged.hover,name);sheet_look_resolve(s,&merged.focus,name)
        sheet_look_resolve(s,&merged.over,name);sheet_look_resolve(s,&merged.pressed,name);sheet_look_resolve(s,&merged.disabled,name)
        for &variant in merged.variants {sheet_look_resolve(s,&variant.look,name)}
        for &earlier in s.styles {
            if earlier.style.name==name && !earlier.linked {sheet_fail(s,"style '%s' is declared twice",name)}
        }
        append(&s.styles,Sheet_Entry{style=merged,row=sheet_compile(s,&merged)})
    }
}

// The style called name: here, or in a sheet taken and joined to this one the
// first time it is named. nil when there is none.
@(private)
sheet_style :: proc(s:^Sheet,name:string) -> (entry:^Sheet_Entry,taken:^Sheet_Taken) {
    for &e in s.styles {if e.style.name==name {return &e,nil}}
    for &t in s.taken {
        if found,_:=sheet_style(t.sheet,name);found!=nil {return found,&t}
    }
    return nil,nil
}

// The row of styles of a style named by a node: a row of its own, or one that
// names the file of the sheet taken it comes from.
@(private)
sheet_style_row :: proc(s:^Sheet,name:string,where_:string) -> (row:u16,entry:^Sheet_Entry) {
    if name=="" {return 0,nil}
    found,taken:=sheet_style(s,name)
    if found==nil {sheet_fail(s,"%s takes the style '%s', which is not declared here or in a sheet taken: declare it or take its sheet",where_,name);return 0,nil}
    if taken==nil {return found.row,found}
    for &e in s.styles {
        if e.linked && e.style.name==name {return e.row,&e}
    }
    if taken.row==0 {
        library:=tree_component_record(fmt.tprintf("sheet:%s",taken.sheet.name),0,0)
        library.widget,library.library=taken.file,true
        append(&s.components,library)
        taken.row=u16(len(s.components))
    }
    row=u16(len(s.rows))
    append(&s.rows,Node_Style{})
    info:Tree_Style_Info
    tree_text_set(info.name[:],name)
    info.from=taken.row
    append(&s.infos,info)
    append(&s.styles,Sheet_Entry{style=found.style,row=row,linked=true})
    return row,&s.styles[len(s.styles)-1]
}

// Adds a texture; the value goes in Node_Desc.image.
sheet_image :: proc(s:^Sheet,image:Tree_Image) -> u16 {
    append(&s.images,image)
    return u16(len(s.images))
}

// Adds a .font; the value goes in Sheet_Look.font.
sheet_font :: proc(s:^Sheet,font:base.Asset_Id) -> u8 {
    append(&s.fonts,Tree_Font{font})
    return u8(FONT_TREE+len(s.fonts)-1)
}

// What a node of this kind needs its style to say so that it can be seen.
@(private)
sheet_node_check :: proc(s:^Sheet,desc:^Node_Desc,entry:^Sheet_Entry) {
    named:=desc.name if desc.name!="" else "a node"
    #partial switch desc.kind {
    case .Text,.Rich_Text,.Prompt,.Action_Bar,.Button,.Selector,.Dropdown,.Number,.Field:
        if entry==nil {sheet_fail(s,"%s (%v) has no style, so its text draws in no color: give it a style with size and color",named,desc.kind);return}
        if entry.style.size==nil {sheet_fail(s,"style '%s' is on %s (%v) with no size: its text would not show",entry.style.name,named,desc.kind)}
        if entry.style.color==nil {sheet_fail(s,"style '%s' is on %s (%v) with no color: its text would not show",entry.style.name,named,desc.kind)}
    }
}

@(private)
sheet_family :: proc "contextless" (kind:Node_Kind) -> Style_Family {
    #partial switch kind {
    case .Text,.Rich_Text,.Prompt,.Action_Bar:return .Text
    case .Button,.Checkbox,.Slider,.Field,.Number,.Selector,.Dropdown,.Radio:return .Control
    }
    return .Box
}

// Adds a node inside parent (-1: at the root), with the style named style;
// empty: none. Returns what its children name as their parent.
sheet_node :: proc(s:^Sheet,parent:i32,style:string,desc:Node_Desc) -> i32 {
    desc:=desc
    row,entry:=sheet_style_row(s,style,desc.name if desc.name!="" else fmt.tprintf("a %v",desc.kind))
    desc.style=row
    if entry!=nil {
        if row<u16(len(s.infos)) {s.infos[row].family=sheet_family(desc.kind)}
        if blur:=sheet_num(entry.style.blur);blur>0 && desc.layer=={} {
            desc.layer={enabled=true,opacity=1,backdrop_blur=blur}
        }
    }
    sheet_node_check(s,&desc,entry)
    list:=&s.component_nodes if s.building else &s.nodes
    return sheet_append(s,list,tree_node_record(&s.text,parent,desc))
}
@(private)
sheet_append :: proc(s:^Sheet,list:^[dynamic]Tree_Node,node:Tree_Node) -> i32 {
    append(list,node)
    return i32(len(list)-1-(s.first if s.building else 0))
}

// Opens a template: until the block ends sheet_node and sheet_use write it,
// counting parents from its root (-1). A node flagged Slot, the last of the
// template, holds what an instance of it holds.
@(deferred_in=sheet_component_end)
sheet_component :: proc(s:^Sheet,name:string) -> bool {
    if s.building {sheet_fail(s,"component '%s' opens inside another: close it first",name)}
    s.building=true
    s.first=len(s.component_nodes)
    return true
}
@(private)
sheet_component_end :: proc(s:^Sheet,name:string) {
    s.building=false
    run:=s.component_nodes[s.first:]
    if len(run)==0 || run[0].parent!=-1 {sheet_fail(s,"component '%s' has no root node: its first sheet_node names parent -1",name);return}
    for node,at in run[1:] {
        if node.parent<0 {sheet_fail(s,"component '%s' has two roots: node %d names parent -1",name,at+1)}
    }
    for node,at in run {
        if .Slot not_in node.flags {continue}
        // What an instance holds goes after everything in the template.
        if end:=sheet_subtree_end(run,at);end!=len(run) {sheet_fail(s,"component '%s' has a node after its Slot: the Slot is the last of the template",name)}
    }
    for &c in s.components {
        if serial.text_field(c.name[:])==name {sheet_fail(s,"component '%s' is declared twice",name)}
    }
    append(&s.components,tree_component_record(name,u32(s.first),u32(len(run))))
}
@(private)
sheet_subtree_end :: proc(run:[]Tree_Node,at:int) -> int {
    end:=at+1
    for end<len(run) {
        node:=run[end]
        inside:=false
        for parent:=node.parent;parent>=0;parent=run[parent].parent {
            if int(parent)==at {inside=true;break}
        }
        if !inside {break}
        end+=1
    }
    return end
}

// The fields of an instance or a set of a use that it writes.
@(private)
sheet_fields :: proc "contextless" (d:^Node_Desc) -> (f:Node_Fields) {
    if d.text!="" || d.text_id!=0 || d.fields!={} {f+={.Text}}
    if d.layout!={} {f+={.Layout}}
    if d.float!={} {f+={.Float}}
    if d.image!=0 {f+={.Image}}
    if d.anims!=0 {f+={.Animations}}
    if d.bind_text!="" || d.bind_value!="" || d.bind_visible!="" || d.bind_selected!="" || d.bind_disabled!="" || d.bind_items!="" || d.bind_image!="" || d.bind_tint!="" || d.bind_variant!="" || d.data!="" {f+={.Bindings}}
    if d.selected || d.disabled {f+={.Visibility}}
    if d.variant!="" {f+={.Variant}}
    if d.layer!={} {f+={.Layer}}
    if d.clip {f+={.Clip}}
    if d.block {f+={.Block}}
    if d.index!=0 || d.count!=0 || d.choice!=0 || d.limit!=0 || d.delay!=0 || d.range!={} || d.particle!={} {f+={.Values}}
    if d.action!="" || d.hold!=0 {f+={.Action}}
    if d.nav!={} || d.order!=0 || d.flags!={} {f+={.Focus}}
    if d.tag!="" || d.accepts!="" || d.ghost!="" {f+={.Drag}}
    return
}

// Adds an instance of the component called component, inside parent. desc
// says what its root changes (fields left out stay as the template has
// them), set what a node of it does by its name. Returns what the nodes it
// holds name as their parent: they go in its Slot. Without a name in desc it
// takes the name of the component and its place.
sheet_use :: proc(s:^Sheet,parent:i32,component:string,desc:Node_Desc,set:[]Sheet_Set={},style:="") -> i32 {
    desc:=desc
    if s.building && len(set)>0 {sheet_fail(s,"a use of '%s' inside a template sets nodes of it: set them on the template",component)}
    desc.kind=.Component
    desc.component=sheet_component_row(s,component,desc.name)
    if desc.component==0 {return 0}
    list:=&s.component_nodes if s.building else &s.nodes
    if desc.name=="" {desc.name=fmt.tprintf("%s_%d",component,len(list))}
    desc.component_fields=sheet_fields(&desc)
    if style!="" {
        row,_:=sheet_style_row(s,style,desc.name)
        desc.style=row
        desc.component_fields+={.Style}
    }
    at:=sheet_append(s,list,tree_node_record(&s.text,parent,desc))
    instance:=len(list)-1
    template,count:=sheet_component_template(s,component)
    for &change in set {
        found:=count==0 // a template of a file not known here is checked when it loads
        for &node in template {
            if serial.text_field(node.name[:])==change.node {found=true;break}
        }
        if !found {
            sheet_fail(s,"a use of '%s' sets the node '%s', which the template does not have",component,change.node)
            continue
        }
        d:=change.desc
        fields:=sheet_fields(&d)
        if change.look!="" {
            row,_:=sheet_style_row(s,change.look,change.node)
            d.style=row
            fields+={.Style}
        }
        append(&s.overrides,tree_override_record(&s.text,u32(instance),change.node,fields,d))
    }
    return at
}

@(private)
sheet_component_row :: proc(s:^Sheet,component,instance:string) -> u16 {
    for &c,row in s.components {
        if !c.library && serial.text_field(c.name[:])==component {return u16(row+1)}
    }
    for &taken in s.taken {
        for &c in taken.sheet.components {
            if c.library || serial.text_field(c.name[:])!=component {continue}
            linked:=tree_component_record(component,0,0)
            linked.widget,linked.named=taken.file,true
            append(&s.components,linked)
            return u16(len(s.components))
        }
    }
    sheet_fail(s,"%s is a use of the component '%s', which is not declared here or in a sheet taken: open it with sheet_component first",instance if instance!="" else "a node",component)
    return 0
}

// The nodes of a template known here (of this sheet or a sheet taken) and
// their count; 0 when it is not known.
@(private)
sheet_component_template :: proc(s:^Sheet,component:string) -> (nodes:[]Tree_Node,count:int) {
    for &c in s.components {
        if serial.text_field(c.name[:])==component && c.widget=={} {return s.component_nodes[c.first:][:c.count],int(c.count)}
    }
    for &taken in s.taken {
        if nodes,count=sheet_component_template(taken.sheet,component);count>0 {return}
    }
    return nil,0
}

// The records of the sheet, and by row of components what tree_link and
// host.ui_tree_save take as the imports of its widgets.
sheet_data :: proc(s:^Sheet) -> (data:Tree_Data,imports:[]Tree_Data) {
    data={nodes=s.nodes[:],styles=s.rows[:],variants=s.variants[:],components=s.components[:],component_nodes=s.component_nodes[:],overrides=s.overrides[:],
        images=s.images[:],fonts=s.fonts[:],style_infos=s.infos[:],translations=s.translations[:],grid_tracks=s.grid_tracks[:],text=s.text[:],
        anims=s.anims,tracks=s.tracks,keys=s.keys,parts=s.parts,anim_sets=s.anim_sets}
    needs:=false
    for &c in s.components {if c.widget!={} {needs=true;break}}
    if !needs {return}
    imports=make([]Tree_Data,len(s.components),s.allocator)
    for &c,row in s.components {
        if c.widget=={} {continue}
        for &taken in s.taken {
            if taken.file!=c.widget {continue}
            other,other_imports:=sheet_data(taken.sheet)
            linked,ok:=tree_link(other,other_imports,s.allocator)
            if !ok {sheet_fail(s,"the sheet '%s' it takes does not link: %s",taken.sheet.name,sheet_problem(taken.sheet))}
            imports[row]=linked
            break
        }
    }
    return
}
