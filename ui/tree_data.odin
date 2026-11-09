package ui

import "base:runtime"
import "core:reflect"
import "mirai:std/base"
import "mirai:std/serial"

// A tree as records: what a .ui asset stores and what a tool edits. Names
// and texts are written out, images name their texture by asset id and
// animations are rows that refer to rows, so every value can be read and
// changed without the program that built it. tree_load turns the records
// into the Widget_Tree the widgets are built from.

TREE_NAME_CAPACITY :: 64
TREE_TEXT_FIELDS :: 4 // names in braces a text shows
TREE_CLIP_TRACKS :: 16 // tracks of one clip

// A text of the records: bytes of Tree_Data.text, UTF-8.
Tree_String :: struct {offset,length:u32}

Tree_Node :: struct {
    kind:Node_Kind,
    parent:i32, // row of the Box that holds it; -1: a root. Rows go in pre-order
    name:[TREE_NAME_CAPACITY]u8 `mirai:"text"`,
    text:Tree_String, // Localized: in the language the interface is written in
    text_id:u64, // Localized: its text among the translations of the file; unique in the project
    fields:[TREE_TEXT_FIELDS]Tree_Text_Field, // what the names in braces of its text show
    layout:Layout,
    float:Float,
    clip:bool,
    block:bool,
    layer:Layer_Style,
    selected,disabled:bool,
    variant:[TREE_NAME_CAPACITY]u8 `mirai:"text"`,
    component:u16, // component row plus one; Component nodes only
    component_fields:Node_Fields,
    data:[TREE_PATH_CAPACITY]u8 `mirai:"text"`, // Component: the path the paths of its widget that start with @ start at
    style:u16, // row of styles
    image:u16, // row of images plus one; 0: none
    anims:u16, // row of anim_sets plus one; 0: none
    // Paths of the data of the game (tree_bind): what the node shows and does by them.
    bind_text:[TREE_PATH_CAPACITY]u8 `mirai:"text"`,
    bind_value:[TREE_PATH_CAPACITY]u8 `mirai:"text"`,
    bind_visible:[TREE_PATH_CAPACITY]u8 `mirai:"text"`,
    bind_selected,bind_disabled:[TREE_PATH_CAPACITY]u8 `mirai:"text"`,
    bind_items:[TREE_PATH_CAPACITY]u8 `mirai:"text"`, // a List: an array of structs or of entities, whose elements the node it holds binds
    bind_image:[TREE_PATH_CAPACITY]u8 `mirai:"text"`, // an Image: a texture, as an asset id
    bind_tint:[TREE_PATH_CAPACITY]u8 `mirai:"text"`,  // a color in place of its fill, linear RGBA in floats or display RGBA in bytes
    bind_variant:[TREE_PATH_CAPACITY]u8 `mirai:"text"`, // a text or an enum: the name of the variant
    index:u16,  // what a Switcher or a Tabs builds when it binds no value
    count:u16,  // how many times a List builds its node when it binds no array
    choice:u16, // what a Radio writes
    limit:u16,  // bytes a Field takes; 0: as many as its value holds
    delay:f32,  // seconds a Tooltip waits; 0: TOOLTIP_DELAY
    tag,accepts:[TREE_NAME_CAPACITY]u8 `mirai:"text"`, // what a Draggable carries; what a Drop takes, empty for anything
    ghost:[TREE_NAME_CAPACITY]u8 `mirai:"text"`, // the node built under the pointer while it is dragged; empty: a copy of it
    particle:base.Asset_Id, // the .particle a Particles plays
    flags:Node_Flags,
    action:[TREE_NAME_CAPACITY]u8 `mirai:"text"`, // the input action a Button takes or a Prompt shows
    hold:f32,
    range:[3]f32,
    nav:[4][TREE_NAME_CAPACITY]u8 `mirai:"text"`, // up, right, down, left
    order:i16,
}
// A name in braces of the text of a node, "{coins}" or "{time:mm:ss}", and
// the path of the game it shows: translations name it as the text does.
Tree_Text_Field :: struct {
    name:[TREE_FIELD_NAME_CAPACITY]u8 `mirai:"text"`,
    path:[TREE_PATH_CAPACITY]u8 `mirai:"text"`,
}
TREE_FIELD_NAME_CAPACITY :: 32

// The text of a localized node in a language other than the one it is written in.
Tree_Translation :: struct {
    id:u64, // the text_id of the node
    language:[16]u8 `mirai:"text"`, // its code: "es", "pt-BR"
    text:Tree_String,
}

// The nodes a named style is for: a node is offered the styles of its family.
Style_Family :: enum u8 {Box, Text, Control}

// What the editor knows of a style, by its row: none of it builds the tree.
Tree_Style_Info :: struct {
    name:[TREE_NAME_CAPACITY]u8 `mirai:"text"`, // empty: no style, the own look of the node that has it
    base:u16, // row plus one of the style a node overrides with this one until it saves it there; 0: none
    family:Style_Family,
    defaults:Node_Kinds, // the kinds whose new nodes take this style; a kind is in one style of a file at most
    from:u16, // row plus one of the component whose file has the style of this name: this row is that style once linked; 0: its own
}
Tree_Font :: struct {
    font:base.Asset_Id, // a .font
}
Tree_Image :: struct {
    name:[TREE_NAME_CAPACITY]u8 `mirai:"text"`, // what <img=name> of a Rich_Text shows
    texture:base.Asset_Id,
    uv:Rect, // the part of the texture shown; all zero: the whole
    border,border_uv:[4]f32,
    fit:Image_Fit,
    frames:[2]u16, // columns and rows of a sheet of sprites; 0: one
}
Tree_Track :: struct {
    property:Anim_Property,
    first_key,key_count:u32, // rows of keys, in time order
}
Tree_Anim :: struct {
    kind:Anim_Kind,
    loop:Anim_Loop,
    first,count:u32, // rows of tracks for a Clip, of parts for a Sequence or a Parallel
    name:[TREE_NAME_CAPACITY]u8 `mirai:"text"`, // what the game names to play it on a node
}

// A style whose text has a font of FONT_TREE or more takes the font of row
// font-FONT_TREE of fonts.
FONT_TREE :: 16
Tree_Data :: struct {
    nodes:[]Tree_Node,
    styles:[]Node_Style,
    variants:[]Tree_Style_Variant,
    components:[]Tree_Component,
    component_nodes:[]Tree_Node,
    overrides:[]Tree_Override,
    images:[]Tree_Image,
    anims:[]Tree_Anim,     // an Anim is its row plus one
    tracks:[]Tree_Track,
    keys:[]Keyframe,
    parts:[]Anim,          // what the groups play: animations of earlier rows
    anim_sets:[]Anim_Set,
    fonts:[]Tree_Font,
    style_infos:[]Tree_Style_Info, // by row of styles; fewer rows: the rest have none
    translations:[]Tree_Translation,
    grid_tracks:[]Grid_Tracks, // the columns a Grid names by Layout.tracks
    text:[]u8, // the texts of nodes and translations
}

// A text of the records; empty when it is outside them.
tree_string :: proc "contextless" (text:[]u8,s:Tree_String) -> string {
    if u64(s.offset)+u64(s.length)>u64(len(text)) {return ""}
    return string(text[s.offset:][:s.length])
}
// Adds a text to the texts of records under construction.
tree_string_add :: proc(text:^[dynamic]u8,s:string) -> Tree_String {
    if s=="" {return {}}
    at:=len(text)
    append(text,s)
    return {u32(at),u32(len(s))}
}

// What the records name and the renderer holds, by row: for each image, what
// Quad.data is for its texture and the size of that texture in texels (none:
// unknown, as a fit that keeps proportions then stretches); for each font, the
// index of its face in the font of the context; for each style, the id of the
// ui program its fill names (0: none, or not found).
Tree_Resources :: struct {
    textures:[]u32,
    sizes:[][2]f32,
    fonts:[]u8,
    programs:[]u32,
}

// Fills a text field of a record, cut at a character boundary when longer.
tree_text_set :: proc "contextless" (field:[]u8,text:string) {
    for &b in field {b=0}
    count:=min(len(text),len(field)-1)
    for count>0 && count<len(text) && text[count]&0xc0==0x80 {count-=1}
    copy(field,text[:count])
}

@(private)
tree_finite :: proc "contextless" (values:..f32) -> bool {
    for value in values {if value-value!=0 {return false}}
    return true
}
@(private)
tree_layout_finite :: proc "contextless" (l:Layout,f:Float) -> bool {
    return tree_finite(l.width.value,l.width.min,l.width.max,l.height.value,l.height.min,l.height.max,l.gap,
        l.padding[0],l.padding[1],l.padding[2],l.padding[3],f.offset.x,f.offset.y)
}

// Whether every enum inside a value of the type holds one of its named
// values: a file holds any number where its record has an enum.
@(private)
tree_enums_named :: proc(value:rawptr,type:^runtime.Type_Info) -> bool {
    #partial switch variant in runtime.type_info_base(type).variant {
    case runtime.Type_Info_Enum:
        _,named:=reflect.enum_name_from_value_any(any{value,type.id})
        return named
    case runtime.Type_Info_Struct:
        for i in 0..<variant.field_count {
            if !tree_enums_named(rawptr(uintptr(value)+variant.offsets[i]),variant.types[i]) {return false}
        }
    case runtime.Type_Info_Array:
        #partial switch _ in runtime.type_info_base(variant.elem).variant {
        case runtime.Type_Info_Enum,runtime.Type_Info_Struct,runtime.Type_Info_Array:
            for i in 0..<variant.count {
                if !tree_enums_named(rawptr(uintptr(value)+uintptr(i*variant.elem_size)),variant.elem) {return false}
            }
        }
    }
    return true
}
@(private)
tree_rows_named :: proc(rows:[]$T) -> bool {
    for &row in rows {if !tree_enums_named(&row,type_info_of(T)) {return false}}
    return true
}

// Builds the tree the records describe, sized to hold exactly them.
// textures: for each row of images, what Quad.data is for its texture in the
// renderer that will draw the tree. A transaction: false, leaving no tree,
// when a row refers outside its table, the rows of nodes are not in
// pre-order, an enum holds a value without a name, a number is not finite, a
// text is not terminated, a style names a font fonts does not have or memory
// runs out.
tree_load :: proc(tree:^Widget_Tree,data:Tree_Data,resources:Tree_Resources,allocator:=context.allocator) -> bool {
    data:=data
    tree^={}
    if len(resources.textures)!=len(data.images) || len(resources.fonts)!=len(data.fonts) || len(data.anims)>=int(max(u16)) {return false}
    if len(resources.programs)!=0 && len(resources.programs)!=len(data.styles) {return false}
    if !tree_rows_named(data.nodes) || !tree_rows_named(data.styles) || !tree_rows_named(data.images) || !tree_rows_named(data.anims) {return false}
    if !tree_rows_named(data.variants) || !tree_rows_named(data.components) || !tree_rows_named(data.component_nodes) || !tree_rows_named(data.overrides) {return false}
    if !tree_rows_named(data.tracks) || !tree_rows_named(data.keys) || !tree_rows_named(data.anim_sets) {return false}
    for font in data.fonts {if font.font=={} {return false}}
    // An info is that of a style and names as its base another style.
    if len(data.style_infos)>len(data.styles) {return false}
    for info,row in data.style_infos {if int(info.base)>len(data.styles) || int(info.base)==row+1 || info.from!=0 {return false}}
    expanded,ok:=tree_expand(data,allocator)
    if !ok {return false}
    defer delete(expanded,allocator)
    data.nodes=expanded
    strings:=0
    for &node in data.nodes {
        fields:=tree_node_texts(&node)
        for field in fields {if len(serial.text_field(field))>=len(field) {return false}}
        if u64(node.text.offset)+u64(node.text.length)>u64(len(data.text)) || int(node.layout.tracks)>len(data.grid_tracks) {return false}
        strings+=int(node.text.length)
        // The text and the names it binds: tree_node keeps them in strings.
        for field in ([8][]u8{node.bind_text[:],node.bind_value[:],node.bind_visible[:],node.bind_selected[:],node.bind_disabled[:],node.bind_items[:],node.bind_image[:],node.bind_tint[:]}) {strings+=len(serial.text_field(field))}
        strings+=len(serial.text_field(node.bind_variant[:]))+len(serial.text_field(node.action[:]))
        for &f in node.fields {strings+=len(serial.text_field(f.path[:]))}
        if parent:=int(node.parent);parent>=0 && parent<len(data.nodes) && data.nodes[parent].kind==.Tabs {strings+=len(serial.text_field(node.name[:]))}
    }
    for &t in data.translations {
        if u64(t.text.offset)+u64(t.text.length)>u64(len(data.text)) || len(serial.text_field(t.language[:]))>=len(t.language) {return false}
        strings+=int(t.text.length)
    }
    groups:=0
    for a in data.anims {if a.kind!=.Clip {groups+=1}}
    desc:=Widget_Tree_Desc{
        allocator=allocator,max_nodes=max(len(data.nodes),1),max_styles=max(len(data.styles),1),max_images=max(len(data.images),1),
        max_anim_sets=max(len(data.anim_sets),1),max_strings=max(strings,1),max_variants=max(len(data.variants),1),max_translations=max(len(data.translations),1),max_grid_tracks=max(len(data.grid_tracks),1),
        anims={max_keys=max(len(data.keys),1),max_tracks=max(len(data.tracks),1),max_anims=max(len(data.anims),1),max_children=max(len(data.parts),1)},
    }
    if !tree_init(tree,desc) {return false}
    if !tree_fill(tree,data,resources) {
        tree_destroy(tree)
        return false
    }
    return true
}

@(private)
tree_fill :: proc(tree:^Widget_Tree,data:Tree_Data,resources:Tree_Resources) -> bool {
    textures:=resources.textures
    // A font of the tree becomes the face the resources give it.
    font_of :: proc(font:^u8,fonts:[]u8) -> bool {
        if font^<FONT_TREE {return int(font^)<FONT_CAPACITY}
        row:=int(font^)-FONT_TREE
        if row>=len(fonts) {return false}
        font^=fonts[row]
        return true
    }
    for &style,i in data.styles {
        if !tree_style_finite(style) || len(serial.text_field(style.program[:]))>=len(style.program) {return false}
        added:=style
        if !font_of(&added.text.font,resources.fonts) {return false}
        _=tree_style(tree,added) or_return
        if len(resources.programs)>0 {tree.programs[i]=resources.programs[i]}
    }
    for &rule in data.variants {
        if int(rule.style)>=max(len(data.styles),1) || !tree_style_finite(rule.patch.values) || len(serial.text_field(rule.variant[:]))>=len(rule.variant) || !tree_style_patch_valid(rule.patch) || (transmute(u8)rule.states)&~STYLE_STATES_NAMED!=0 {return false}
        patch:=rule.patch
        if !font_of(&patch.values.text.font,resources.fonts) {return false}
        if !tree_style_variant(tree,{style=rule.style,variant=style_variant(serial.text_field(rule.variant[:])),states=rule.states,patch=patch}) {return false}
    }
    for &image,i in data.images {
        if !tree_finite(image.uv.x,image.uv.y,image.uv.w,image.uv.h) || len(serial.text_field(image.name[:]))>=len(image.name) {return false}
        for side in 0..<4 {if !tree_finite(image.border[side],image.border_uv[side]) {return false}}
        named:=serial.text_field(image.name[:])
        stored:=Node_Image{name=base.name_hash(named) if named!="" else 0,border=image.border,border_uv=image.border_uv,fit=image.fit,frames=image.frames}
        if i<len(resources.sizes) {
            uv:=image.uv if image.uv!={} else Rect{0,0,1,1}
            stored.size=resources.sizes[i]*{uv.w,uv.h}
        }
        if image.texture!={} {stored.quad={.Image,textures[i],image.uv if image.uv!={} else Rect{0,0,1,1}}}
        _=tree_image(tree,stored) or_return
    }
    lib:=&tree.anims
    for &a,i in data.anims {
        if u64(a.first)+u64(a.count)>u64(len(data.tracks) if a.kind==.Clip else len(data.parts)) {return false}
        added:Anim
        switch a.kind {
        case .Clip:
            if a.count>TREE_CLIP_TRACKS {return false}
            tracks:[TREE_CLIP_TRACKS]Track
            for track,at in data.tracks[a.first:][:a.count] {
                if u64(track.first_key)+u64(track.key_count)>u64(len(data.keys)) {return false}
                keys:=data.keys[track.first_key:][:track.key_count]
                for key,k in keys {
                    if !tree_finite(key.time,key.value[0],key.value[1],key.value[2],key.value[3]) || key.time<0 {return false}
                    if k>0 && key.time<keys[k-1].time {return false}
                }
                tracks[at]={track.property,keys}
            }
            added=anim_clip(lib,tracks[:a.count],a.loop)
        case .Sequence,.Parallel:
            parts:=data.parts[a.first:][:a.count]
            for part in parts {if part==0 || int(part)>i {return false}}
            added=anim_group(lib,a.kind,parts,a.loop)
        case:
            return false
        }
        if int(added)!=i+1 {return false}
        if len(serial.text_field(a.name[:]))>=len(a.name) {return false}
        if name:=serial.text_field(a.name[:]);name!="" {tree.anim_names[i]=base.name_hash(name)}
    }
    for set in data.anim_sets {
        states:=transmute([size_of(Anim_Set)/size_of(Anim)]Anim)set
        for state in states {if int(state)>len(data.anims) {return false}}
        _=tree_anim_set(tree,set) or_return
    }
    for &node,i in data.nodes {
        if int(node.style)>=max(len(data.styles),1) || int(node.image)>len(data.images) || int(node.anims)>len(data.anim_sets) {return false}
        if !tree_layout_finite(node.layout,node.float) || !tree_finite(node.layer.opacity,node.layer.radius,node.layer.backdrop_blur) {return false}
        if !tree_finite(node.hold,node.range[0],node.range[1],node.range[2],node.delay) || node.hold<0 || node.delay<0 {return false}
        added:=tree_node(tree,node.parent,{
            kind=node.kind,name=serial.text_field(node.name[:]),layout=node.layout,float=node.float,clip=node.clip,block=node.block,
            style=node.style,image=node.image,anims=node.anims,text=tree_string(data.text,node.text),text_id=node.text_id,fields=tree_text_fields(&node),layer=node.layer,variant=serial.text_field(node.variant[:]),selected=node.selected,disabled=node.disabled,
            bind_text=serial.text_field(node.bind_text[:]),bind_value=serial.text_field(node.bind_value[:]),bind_visible=serial.text_field(node.bind_visible[:]),bind_selected=serial.text_field(node.bind_selected[:]),bind_disabled=serial.text_field(node.bind_disabled[:]),
            bind_items=serial.text_field(node.bind_items[:]),bind_image=serial.text_field(node.bind_image[:]),bind_tint=serial.text_field(node.bind_tint[:]),bind_variant=serial.text_field(node.bind_variant[:]),
            index=node.index,count=node.count,choice=node.choice,limit=node.limit,delay=node.delay,particle=node.particle,
            tag=serial.text_field(node.tag[:]),accepts=serial.text_field(node.accepts[:]),ghost=serial.text_field(node.ghost[:]),
            flags=node.flags,action=serial.text_field(node.action[:]),hold=node.hold,range=node.range,order=node.order,
            nav={serial.text_field(node.nav[0][:]),serial.text_field(node.nav[1][:]),serial.text_field(node.nav[2][:]),serial.text_field(node.nav[3][:])},
        })
        if int(added)!=i {return false}
    }
    for &t in data.translations {
        if !tree_translation_add(tree,t.id,base.name_hash(serial.text_field(t.language[:])),tree_string(data.text,t.text)) {return false}
    }
    for tracks in data.grid_tracks {
        if int(tracks.count)>GRID_TRACKS {return false}
        for column in tracks.columns {if !tree_finite(column.value,column.min,column.max) {return false}}
        tree.grid_tracks[tree.grid_track_count]=tracks
        tree.grid_track_count+=1
    }
    // A List builds the one node it holds.
    for node,i in data.nodes {
        if node.kind!=.List {continue}
        if i+1>=len(data.nodes) || data.nodes[i+1].parent!=i32(i) {return false}
        for later in data.nodes[i+2:] {if later.parent==i32(i) {return false}}
    }
    // tree_build opens no box deeper than TREE_DEPTH.
    for node in data.nodes {
        depth:=0
        for parent:=node.parent;parent>=0;parent=data.nodes[parent].parent {
            depth+=1
            if depth>=TREE_DEPTH {return false}
        }
    }
    return true
}

// Changes what the images of a loaded tree sample, after their textures moved
// in the renderer. textures: as in tree_load.
tree_textures_set :: proc(tree:^Widget_Tree,textures:[]u32) {
    for &image,i in tree.images[:min(tree.image_count,len(textures))] {
        if image.quad.kind==.Image {image.quad.data=textures[i]}
    }
}

// Changes the ui programs the styles of a loaded tree color with, after the
// shaders of the renderer changed. programs: as Tree_Resources.programs.
tree_programs_set :: proc(tree:^Widget_Tree,programs:[]u32) {
    copy(tree.programs[:min(tree.style_count,len(tree.programs))],programs)
}

// The lowest and the highest layer of the nodes of a tree that float, counted
// from the layer it is built in: 0 and 0 when none floats.
tree_layers :: proc "contextless" (tree:^Widget_Tree) -> (low,high:i16) {
    for node in tree.nodes[:tree.node_count] {
        if node.float.to!=.None {low,high=min(low,node.float.layer),max(high,node.float.layer)}
    }
    return
}

// A node record, as tree_node takes it, with its text added to text.
tree_node_record :: proc(text:^[dynamic]u8,parent:i32,desc:Node_Desc) -> (node:Tree_Node) {
    node={kind=desc.kind,parent=parent,layout=desc.layout,float=desc.float,clip=desc.clip,block=desc.block,style=desc.style,image=desc.image,anims=desc.anims,layer=desc.layer,selected=desc.selected,disabled=desc.disabled,component=desc.component,component_fields=desc.component_fields,
        index=desc.index,count=desc.count,choice=desc.choice,limit=desc.limit,delay=desc.delay,particle=desc.particle,
        flags=desc.flags,hold=desc.hold,range=desc.range,order=desc.order,text_id=desc.text_id}
    node.text=tree_string_add(text,desc.text)
    tree_text_set(node.tag[:],desc.tag);tree_text_set(node.accepts[:],desc.accepts);tree_text_set(node.ghost[:],desc.ghost)
    for f,i in desc.fields {tree_text_set(node.fields[i].name[:],f.name);tree_text_set(node.fields[i].path[:],f.path)}
    tree_text_set(node.data[:],desc.data);tree_text_set(node.bind_items[:],desc.bind_items);tree_text_set(node.bind_image[:],desc.bind_image);tree_text_set(node.bind_tint[:],desc.bind_tint);tree_text_set(node.bind_variant[:],desc.bind_variant)
    tree_text_set(node.action[:],desc.action)
    for side in 0..<4 {tree_text_set(node.nav[side][:],desc.nav[side])}
    tree_text_set(node.name[:],desc.name);tree_text_set(node.variant[:],desc.variant)
    tree_text_set(node.bind_text[:],desc.bind_text);tree_text_set(node.bind_value[:],desc.bind_value);tree_text_set(node.bind_visible[:],desc.bind_visible);tree_text_set(node.bind_selected[:],desc.bind_selected);tree_text_set(node.bind_disabled[:],desc.bind_disabled)
    return
}


// The text fields of a record, each of which must end in a zero.
@(private)
tree_node_texts :: proc "contextless" (node:^Tree_Node) -> [28][]u8 {
    f:=&node.fields
    return {node.name[:],node.tag[:],node.accepts[:],node.ghost[:],node.variant[:],node.data[:],node.bind_text[:],node.bind_value[:],node.bind_visible[:],node.bind_selected[:],node.bind_disabled[:],
        node.bind_items[:],node.bind_image[:],node.bind_tint[:],node.bind_variant[:],node.action[:],node.nav[0][:],node.nav[1][:],node.nav[2][:],node.nav[3][:],
        f[0].name[:],f[0].path[:],f[1].name[:],f[1].path[:],f[2].name[:],f[2].path[:],f[3].name[:],f[3].path[:]}
}

// The fields of the text of a record, as tree_node takes them.
@(private)
tree_text_fields :: proc(node:^Tree_Node) -> (fields:[TREE_TEXT_FIELDS]Node_Field_Desc) {
    for &f,i in node.fields {fields[i]={serial.text_field(f.name[:]),serial.text_field(f.path[:])}}
    return
}

@(private)
tree_style_finite :: proc "contextless" (s:Node_Style) -> bool {
    return tree_finite(s.radius[0],s.radius[1],s.radius[2],s.radius[3],s.transition,s.stroke_width,s.shadow_blur,s.shadow_offset.x,s.shadow_offset.y,s.text.size,s.text.line_height,s.text.outline,s.text.shadow.x,s.text.shadow.y,s.move.x,s.move.y,s.scale,
        s.program_values[0],s.program_values[1],s.program_values[2],s.program_values[3])
}
@(private)
tree_style_patch_valid :: proc "contextless" (p:Style_Patch) -> bool {return (transmute(u16)p.fields)&~u16(1<<len(Style_Field)-1)==0}
