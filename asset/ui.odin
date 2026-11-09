package asset

import "mirai:std/base"
import "mirai:std/serial"

// .ui: a tree of widgets as records.
//
//   nodes       the widgets in pre-order: kind, parent, name, text, layout, style, image, animations and bindings
//   styles      colors, radius and the style of the text of a node
//   images      texture (an asset id), the part of it shown and the borders of its nine slice
//   anims       animations: tracks that play together, or other animations in sequence or in parallel
//   tracks      a property and its keys
//   keys        time, value and ease
//   parts       the animations a sequence or a parallel plays
//   anim_sets   the animation a node plays when it is shown, hidden, hovered or pressed
//   fonts       the .font assets the styles name
//   translations the text of a localized node in the other languages of the game, by its text_id
//   grid_tracks  the widths of the columns of the grids that name them
//   tokens       values by name that styles and other files take
//   token_uses   which values of styles name them
//   params       the parameters of the widget this file is, and where each goes
//   text        bulk u8: the texts of nodes and translations, UTF-8, by offset and length
//
// A component names another .ui, once: nodes are uses of the widget that file
// is, and a style or a token can come from it. What a use expands into joins
// the records when they are loaded; no file holds it.
//
// The rows are the records of ui.Tree_Data: the ui package declares and
// loads them, and this one stores them as it does any typed table. A program
// that links both reads and writes the file: runtime.ui_tree_document and
// runtime.ui_tree_view.

UI_VERSION :: 5

UI_TABLE_NODES :: "nodes"
UI_TABLE_STYLES :: "styles"
UI_TABLE_VARIANTS :: "variants"
UI_TABLE_COMPONENTS :: "components"
UI_TABLE_OVERRIDES :: "overrides"
UI_TABLE_IMAGES :: "images"
UI_TABLE_ANIMS :: "anims"
UI_TABLE_TRACKS :: "tracks"
UI_TABLE_KEYS :: "keys"
UI_TABLE_PARTS :: "parts"
UI_TABLE_ANIM_SETS :: "anim_sets"
UI_TABLE_FONTS :: "fonts"
UI_TABLE_STYLE_INFOS :: "style_infos"
UI_TABLE_TRANSLATIONS :: "translations"
UI_TABLE_GRID_TRACKS :: "grid_tracks"
UI_TABLE_TOKENS :: "tokens"
UI_TABLE_TOKEN_USES :: "token_uses"
UI_TABLE_PARAMS :: "params"
UI_TABLE_TEXT :: "text"

// As ui.TREE_DEPTH and ui.TREE_CLIP_TRACKS: the limits of the tree the records are built into.
UI_TREE_DEPTH :: 32
UI_CLIP_TRACKS :: 16

// The fields of the records that refer to other rows, read by name whatever
// the layout of the file.
@(private="file") Ui_String_Links :: struct {offset,length:u32}
@(private="file") Ui_Layout_Links :: struct {tracks:u16}
@(private="file") Ui_Node_Links :: struct {kind:u8,parent:i32,style,image,anims,component:u16,component_fields:u32,name:[64]u8 `mirai:"text"`,text:Ui_String_Links,layout:Ui_Layout_Links,flags:u16}
@(private="file") Ui_Translation_Links :: struct {text:Ui_String_Links}
@(private="file") Ui_Component_Links :: struct {name:[64]u8 `mirai:"text"`,widget:base.Asset_Id}
@(private="file") Ui_Override_Links :: struct {instance:u32,node:[64]u8 `mirai:"text"`,fields:u32,values:Ui_Node_Links}
@(private="file") Ui_Font_Links :: struct {font:u8}
@(private="file") Ui_Font_Row :: struct {font:base.Asset_Id}
@(private="file") Ui_Style_Links :: struct {text:Ui_Font_Links}
@(private="file") Ui_Patch_Links :: struct {values:Ui_Style_Links}
@(private="file") Ui_Variant_Links :: struct {style:u16,patch:Ui_Patch_Links}
@(private="file") Ui_Style_Info_Links :: struct {from:u16}

// As ui.FONT_TREE and ui.FONT_CAPACITY: a style font from UI_FONT_TREE on is a
// row of fonts; below UI_FONT_CAPACITY, a font of the context.
UI_FONT_TREE :: 16
UI_FONT_CAPACITY :: 16
// As ui.node_kind_holds: Box, Scroll, Switcher, List, Tooltip, Tabs, Popup, Modal, Context_Menu and Radial.
@(private="file") ui_holds :: proc "contextless" (kind:u8) -> bool {return kind==0 || kind==8 || kind==9 || kind==10 || kind==17 || kind>=22 && kind<=26}
@(private="file") UI_KIND_COMPONENT :: 7
@(private="file") UI_KIND_LIST :: 10
// As ui.NODE_FIELDS_UNKNOWN.
@(private="file") UI_FIELDS_UNKNOWN :: ~u32(0xffff)
@(private="file") Ui_Anim_Links :: struct {kind:u8,first,count:u32}
@(private="file") Ui_Track_Links :: struct {first_key,key_count:u32}
@(private="file") Ui_Key_Time :: struct {time:f32}
@(private="file") Ui_Set_Links :: struct {shown,hidden,hovered,unhovered,pressed,released,focused,unfocused,selected,unselected,clicked:u16}

// Whether the records of a .ui are a tree that can be built (ui.tree_load
// asks the same): the nodes come in pre-order under boxes, no deeper than
// UI_TREE_DEPTH, and a List holds one node; a node built names a style, an
// image, a set of animations, a text and grid tracks that exist; a clip names
// tracks and a track keys that exist, in time order; a sequence or a parallel
// plays animations of earlier rows; the clips together name no more tracks
// and keys, and the groups no more parts, than their tables hold; and a set
// names animations that exist. The values themselves (enums, numbers, texts)
// are for whoever checks them against the schema.
ui_check :: proc(a:^Asset,types:^Types) -> bool {
    if kind_check(a,KIND_UI,UI_VERSION)!=.None {return false}
    rows :: proc(a:^Asset,types:^Types,name:string,$T:typeid) -> (list:[]T,ok:bool) {
        if _,found:=asset_table(a,name);!found {return nil,true}
        error:Error
        list,error=asset_rows(a,types,name,"",T)
        return list,error==.None
    }
    count :: proc(a:^Asset,name:string) -> int {
        table,found:=asset_table(a,name)
        return found?table.rows:0
    }
    nodes:=rows(a,types,UI_TABLE_NODES,Ui_Node_Links) or_return
    anims:=rows(a,types,UI_TABLE_ANIMS,Ui_Anim_Links) or_return
    tracks:=rows(a,types,UI_TABLE_TRACKS,Ui_Track_Links) or_return
    keys:=rows(a,types,UI_TABLE_KEYS,Ui_Key_Time) or_return
    parts:=rows(a,types,UI_TABLE_PARTS,u16) or_return
    sets:=rows(a,types,UI_TABLE_ANIM_SETS,Ui_Set_Links) or_return
    components:=rows(a,types,UI_TABLE_COMPONENTS,Ui_Component_Links) or_return
    overrides:=rows(a,types,UI_TABLE_OVERRIDES,Ui_Override_Links) or_return
    variants:=rows(a,types,UI_TABLE_VARIANTS,Ui_Variant_Links) or_return
    styled:=rows(a,types,UI_TABLE_STYLES,Ui_Style_Links) or_return
    infos:=rows(a,types,UI_TABLE_STYLE_INFOS,Ui_Style_Info_Links) or_return
    translations:=rows(a,types,UI_TABLE_TRANSLATIONS,Ui_Translation_Links) or_return
    font_rows:=rows(a,types,UI_TABLE_FONTS,Ui_Font_Row) or_return
    styles,images,fonts:=count(a,UI_TABLE_STYLES),count(a,UI_TABLE_IMAGES),len(font_rows)
    text,grids:=u64(count(a,UI_TABLE_TEXT)),count(a,UI_TABLE_GRID_TRACKS)
    for t in translations {if !ui_inside(t.text,text) {return false}}
    for font in font_rows {if font.font=={} {return false}}
    font_ok :: proc "contextless" (font:u8,fonts:int) -> bool {return font<UI_FONT_CAPACITY || font>=UI_FONT_TREE && int(font-UI_FONT_TREE)<fonts}
    for variant in variants {if int(variant.style)>=max(styles,1) || !font_ok(variant.patch.values.text.font,fonts) {return false}}
    for style in styled {if !font_ok(style.text.font,fonts) {return false}}
    if len(infos)>styles {return false}
    for info in infos {if int(info.from)>len(components) {return false}}
    if !ui_components_check(nodes,components,overrides,styles,images,len(sets),text,grids) {return false}
    if len(anims)>=int(max(u16)) {return false}
    clip_tracks,clip_keys,group_parts:=0,0,0
    for anim,at in anims {
        switch anim.kind {
        case 0: // Clip
            if u64(anim.first)+u64(anim.count)>u64(len(tracks)) || anim.count>UI_CLIP_TRACKS {return false}
            clip_tracks+=int(anim.count)
            for track in tracks[anim.first:][:anim.count] {
                if u64(track.first_key)+u64(track.key_count)>u64(len(keys)) {return false}
                run:=keys[track.first_key:][:track.key_count]
                for key,k in run {
                    if !finite(key.time) || key.time<0 || k>0 && key.time<run[k-1].time {return false}
                }
                clip_keys+=len(run)
            }
        case 1,2: // Sequence, Parallel
            if u64(anim.first)+u64(anim.count)>u64(len(parts)) {return false}
            group_parts+=int(anim.count)
            for part in parts[anim.first:][:anim.count] {
                if part==0 || int(part)>at {return false}
            }
        case:
            return false
        }
    }
    // ui.tree_load sizes the library the animations are copied into by these tables.
    if clip_tracks>max(len(tracks),1) || clip_keys>max(len(keys),1) || group_parts>max(len(parts),1) {return false}
    for set in sets {
        set:=set
        for state in (^[size_of(Ui_Set_Links)/size_of(u16)]u16)(&set) {
            if int(state)>len(anims) {return false}
        }
    }
    return true
}

// Texts are bytes of the text table.
@(private="file")
ui_inside :: proc "contextless" (s:Ui_String_Links,text:u64) -> bool {return u64(s.offset)+u64(s.length)<=text}

@(private="file")
ui_components_check :: proc(nodes:[]Ui_Node_Links,components:[]Ui_Component_Links,overrides:[]Ui_Override_Links,styles,images,sets:int,text:u64,grids:int) -> bool {
    if len(components)>=int(max(u16)) || len(nodes)>65535 {return false}
    for &component,i in components {
        name:=serial.text_field(component.name[:])
        if name=="" || len(name)>=len(component.name) || component.widget=={} {return false}
        for &earlier in components[:i] {if serial.text_field(earlier.name[:])==name {return false}}
    }
    for &override in overrides {
        if int(override.instance)>=len(nodes) || nodes[override.instance].kind!=UI_KIND_COMPONENT || override.fields&UI_FIELDS_UNKNOWN!=0 {return false}
        name:=serial.text_field(override.node[:])
        if name=="" || len(name)>=len(override.node) {return false}
    }
    subtree:=make([]i32,len(nodes),context.temp_allocator)
    depths:=make([]int,len(nodes),context.temp_allocator)
    for &source,at in nodes {
        if source.parent<-1 || int(source.parent)>=at {return false}
        if source.parent>=0 && (!ui_holds(nodes[source.parent].kind) && nodes[source.parent].kind!=UI_KIND_COMPONENT || int(source.parent+subtree[source.parent])+1!=at) {return false}
        // A List holds one node: the first after it.
        if source.parent>=0 && nodes[source.parent].kind==UI_KIND_LIST && int(source.parent)+1!=at {return false}
        if source.kind==UI_KIND_LIST && (at+1>=len(nodes) || int(nodes[at+1].parent)!=at) {return false}
        for ancestor:=source.parent;ancestor>=0;ancestor=nodes[ancestor].parent {subtree[ancestor]+=1}
        depth:=depths[source.parent]+1 if source.parent>=0 else 0
        if depth>=UI_TREE_DEPTH || source.component_fields&UI_FIELDS_UNKNOWN!=0 {return false}
        depths[at]=depth
        name:=serial.text_field(source.name[:])
        if len(name)>=len(source.name) {return false}
        if source.kind==UI_KIND_COMPONENT {
            // Its nodes, what overrides them and the Slot that takes what it holds are checked when the two load together.
            if source.component==0 || int(source.component)>len(components) || name=="" {return false}
            continue
        }
        if source.component!=0 || int(source.style)>=max(styles,1) || int(source.image)>images || int(source.anims)>sets {return false}
        if !ui_inside(source.text,text) || int(source.layout.tracks)>grids {return false}
    }
    return true
}
