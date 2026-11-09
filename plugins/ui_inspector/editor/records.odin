package ui_inspector_editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The records of the .ui of the document, as the document edits them, the
// tables of the file. Adding, moving or removing nodes keeps them in
// pre-order and fixes the rows that refer to them.

Records :: struct {
    nodes:[dynamic]ui.Tree_Node,
    components:[dynamic]ui.Tree_Component, // the .ui it names: a widget it uses, a library it takes names from
    styles:[dynamic]ui.Node_Style,
    style_infos:[dynamic]ui.Tree_Style_Info, // one by style
    variants:[dynamic]ui.Tree_Style_Variant,
    overrides:[dynamic]ui.Tree_Override,
    images:[dynamic]ui.Tree_Image,
    anims:[dynamic]ui.Tree_Anim,
    tracks:[dynamic]ui.Tree_Track,
    keys:[dynamic]ui.Keyframe,
    parts:[dynamic]ui.Anim,
    anim_sets:[dynamic]ui.Anim_Set,
    fonts:[dynamic]ui.Tree_Font,
    translations:[dynamic]ui.Tree_Translation,
    grid_tracks:[dynamic]ui.Grid_Tracks,
    text:[dynamic]u8, // what the texts of the records name; an edited text goes at its end, until records_text_compact
    tokens:[dynamic]ui.Tree_Token,
    token_uses:[dynamic]ui.Tree_Token_Use,
    params:[dynamic]ui.Tree_Param,
    allocator:runtime.Allocator,
}

// Copies the records of a tree. A transaction: false, leaving nothing, when
// memory runs out.
records_load :: proc(r:^Records,data:ui.Tree_Data,allocator:runtime.Allocator) -> bool {
    r^={allocator=allocator}
    ok:=true
    list :: proc(to:^[dynamic]$T,from:[]T,ok:^bool,allocator:runtime.Allocator) {
        to^=make([dynamic]T,0,len(from),allocator)
        if _,error:=append(to,..from);error!=nil {ok^=false}
    }
    list(&r.nodes,data.nodes,&ok,allocator)
    list(&r.styles,data.styles,&ok,allocator)
    list(&r.style_infos,data.style_infos[:min(len(data.style_infos),len(data.styles))],&ok,allocator)
    list(&r.variants,data.variants,&ok,allocator)
    list(&r.overrides,data.overrides,&ok,allocator)
    list(&r.images,data.images,&ok,allocator)
    list(&r.anims,data.anims,&ok,allocator)
    list(&r.tracks,data.tracks,&ok,allocator)
    list(&r.keys,data.keys,&ok,allocator)
    list(&r.parts,data.parts,&ok,allocator)
    list(&r.anim_sets,data.anim_sets,&ok,allocator)
    list(&r.fonts,data.fonts,&ok,allocator)
    list(&r.translations,data.translations,&ok,allocator)
    list(&r.grid_tracks,data.grid_tracks,&ok,allocator)
    list(&r.text,data.text,&ok,allocator)
    list(&r.tokens,data.tokens,&ok,allocator)
    list(&r.token_uses,data.token_uses,&ok,allocator)
    list(&r.params,data.params,&ok,allocator)
    list(&r.components,data.components,&ok,allocator)
    // Style 0 is what nodes without a style take: there is always one.
    if ok && len(r.styles)==0 {append(&r.styles,ui.Node_Style{})}
    if ok {resize(&r.style_infos,len(r.styles))}
    if !ok {records_destroy(r)}
    return ok
}

records_destroy :: proc(r:^Records) {
    if r.allocator.procedure==nil {return}
    delete(r.nodes);delete(r.styles);delete(r.style_infos);delete(r.variants);delete(r.overrides);delete(r.images)
    delete(r.anims);delete(r.tracks);delete(r.keys);delete(r.parts);delete(r.anim_sets);delete(r.fonts);delete(r.translations);delete(r.grid_tracks);delete(r.text)
    delete(r.tokens);delete(r.token_uses);delete(r.params)
    delete(r.components)
    r^={}
}

// The records as a tree takes them, joined in the temporary allocator.
records_data :: proc(r:^Records) -> ui.Tree_Data {
    return {nodes=r.nodes[:],styles=r.styles[:],variants=r.variants[:],components=r.components[:],
        overrides=r.overrides[:],images=r.images[:],anims=r.anims[:],tracks=r.tracks[:],keys=r.keys[:],parts=r.parts[:],anim_sets=r.anim_sets[:],fonts=r.fonts[:],style_infos=r.style_infos[:],translations=r.translations[:],
        grid_tracks=r.grid_tracks[:],text=r.text[:],tokens=r.tokens[:],token_uses=r.token_uses[:],params=r.params[:]}
}

// A text of the records.
records_text :: proc(r:^Records,s:ui.Tree_String) -> string {return ui.tree_string(r.text[:],s)}

// Makes s name text, added at the end of the texts unless it already does.
records_text_set :: proc(r:^Records,s:^ui.Tree_String,text:string) {
    if records_text(r,s^)==text {return}
    s^=ui.tree_string_add(&r.text,text)
}

// Keeps in the texts only what nodes, overrides and translations name, in that order: what an edit left behind goes.
records_text_compact :: proc(r:^Records) {
    kept:=make([dynamic]u8,0,len(r.text),r.allocator)
    keep :: proc(r:^Records,kept:^[dynamic]u8,s:^ui.Tree_String) {s^=ui.tree_string_add(kept,records_text(r,s^))}
    for &n in r.nodes {keep(r,&kept,&n.text)}
    for &o in r.overrides {keep(r,&kept,&o.values.text)}
    for &t in r.translations {keep(r,&kept,&t.text)}
    delete(r.text)
    r.text=kept
}

// What a write leaves: the keys of each track in time order, no row nothing
// uses and only the texts something names.
records_tidy :: proc(r:^Records) {
    records_keys_sort(r)
    records_collect(r)
    records_texts_prune(r)
    slice.stable_sort_by(r.token_uses[:],proc(a,b:ui.Tree_Token_Use) -> bool {
        if a.style!=b.style {return a.style<b.style}
        if a.states!=b.states {return transmute(u8)a.states<transmute(u8)b.states}
        if a.variant!=b.variant {
            x,y:=a.variant,b.variant
            return strings.compare(serial.text_field(x[:]),serial.text_field(y[:]))<0
        }
        return a.key<b.key
    })
    records_text_compact(r)
}

// Puts what the names of the records say in their values: what tokens give,
// what styles take from those they extend and from the files they link
// (imports, as host.ui_tree_imports gives them), and the layouts nodes take
// from their styles. Only an edit calls it: nothing of it runs per frame.
records_settle :: proc(r:^Records,imports:[]ui.Tree_Data) {
    ui.tree_settle(r.styles[:],r.style_infos[:],&r.variants,r.tokens[:],r.token_uses[:])
    infos:=r.style_infos[:]
    if imports!=nil {
        linked,ok:=ui.tree_link(records_data(r),imports,context.temp_allocator)
        if !ok {return} // ui_tree_document says why
        for &info,row in r.style_infos {
            if info.from==0 && info.extends[0]==0 {continue}
            if row>=len(linked.styles) {continue}
            r.styles[row]=linked.styles[row]
            if row<len(linked.style_infos) {info.layout,info.layout_keys,info.blur=linked.style_infos[row].layout,linked.style_infos[row].layout_keys,linked.style_infos[row].blur}
            for i:=len(r.variants)-1;i>=0;i-=1 {
                v:=&r.variants[i]
                if int(v.style)==row && (info.from!=0 || v.inherited) {ordered_remove(&r.variants,i)}
            }
            for v in linked.variants {
                if int(v.style)!=row || (info.from==0 && !v.inherited) {continue}
                kept:=v
                kept.inherited=true
                append(&r.variants,kept)
            }
        }
        infos=linked.style_infos
    }
    ui.tree_nodes_take_styles(r.nodes[:],infos)
}

// What both routes of an edit write, the API and the visual editor: records
// settled against the widgets they use and made the bytes of their file.
records_commit :: proc(types:^asset.Types,id:base.Asset_Id,r:^Records,imports:[]ui.Tree_Data) -> (bytes:[]u8,error:asset.Error) {
    records_settle(r,imports)
    return host.ui_tree_bytes(types,id,records_data(r),imports,context.temp_allocator)
}

// Rows of nodes inside row, which follow it in pre-order.
records_subtree :: proc(nodes:[]ui.Tree_Node,row:int) -> int {
    end:=row+1
    for end<len(nodes) {
        parent:=int(nodes[end].parent)
        for parent>row {parent=int(nodes[parent].parent)}
        if parent!=row {break}
        end+=1
    }
    return end-row-1
}

// Levels of containers above a row.
records_depth :: proc(nodes:[]ui.Tree_Node,row:int) -> int {
    depth:=0
    for parent:=nodes[row].parent;parent>=0;parent=nodes[parent].parent {depth+=1}
    return depth
}

// The rows the instances of the overrides follow when rows from at move by
// count (count negative: they went away).
@(private)
records_shift :: proc(r:^Records,at,count:int) {
    for i:=len(r.overrides)-1;i>=0;i-=1 {
        o:=&r.overrides[i]
        switch {
        case count<0 && int(o.instance)>=at && int(o.instance)<at-count: ordered_remove(&r.overrides,i)
        case int(o.instance)>=at:                                         o.instance=u32(int(o.instance)+count)
        }
    }
}

// Inserts copies of nodes (a subtree, parents relative to it, the first a
// root) at row at inside parent, and fixes the rows after them.
@(private)
records_put :: proc(r:^Records,at,parent:int,subtree:[]ui.Tree_Node) -> bool {
    if len(subtree)==0 {return false}
    if _,error:=inject_at(&r.nodes,at,..subtree);error!=nil {return false}
    count:=len(subtree)
    for &n in r.nodes[at+count:] {if int(n.parent)>=at {n.parent+=i32(count)}}
    for &n,i in r.nodes[at:at+count] {
        n.parent=i32(parent) if i==0 else n.parent+i32(at)
    }
    records_shift(r,at,count)
    return true
}

// A node of a kind as Add makes it: what its arrows in Properties give back.
node_default :: proc(kind:ui.Node_Kind) -> ui.Tree_Node {
    node:=ui.Tree_Node{kind=kind,parent=-1}
    #partial switch kind {
    case .Progress:                node.layout.width,node.layout.height=ui.fixed(120),ui.fixed(8)
    case .Image,.View:             node.layout.width,node.layout.height=ui.fixed(64),ui.fixed(64)
    case .Slider:                  node.layout.width,node.layout.height,node.range=ui.fixed(160),ui.fixed(20),{0,1,0}
    case .Field:                   node.layout.width,node.layout.height=ui.fixed(160),ui.fixed(24)
    case .Prompt:                  ui.tree_text_set(node.action[:],"jump");node.layout.height=ui.fixed(28)
    case .List:                    node.count=3
    case .Scroll:                  node.layout.width,node.layout.height,node.layout.direction=ui.fixed(240),ui.fixed(160),.Column
    case .Tooltip:                 node.layout.padding,node.layout.direction=ui.padding_all(6),.Column
    }
    return node
}
// The look a node of a kind takes as Add makes it when no node of its kind
// before it has one; none for what shows nothing of its own (a Box).
node_default_look :: proc(kind:ui.Node_Kind) -> (look:ui.Node_Style,has:bool) {
    text:=ui.Text_Style{size=16,color={235,238,245,255}}
    #partial switch kind {
    case .Text,.Rich_Text,.Prompt,.Action_Bar:
        return {text=text},true
    case .Image,.View,.Particles:
        return {fill={255,255,255,255}},true
    case .Progress:
        return {fill={120,160,255,255},track={44,48,62,255},radius=4},true
    case .Button,.Checkbox,.Slider,.Field,.Number,.Selector,.Dropdown,.Radio:
        return {text=text,fill={30,36,52,255},stroke={90,110,150,255},stroke_width=1,track={52,58,76,255},knob={235,240,250,255},mark={120,160,255,255},radius=6},true
    }
    return
}

// The text a node of a kind has as Add makes it.
node_default_text :: proc(kind:ui.Node_Kind) -> string {
    #partial switch kind {
    case .Text,.Rich_Text:    return "Text"
    case .Button:             return "Button"
    case .Selector,.Dropdown: return "Low|Medium|High"
    }
    return ""
}

// The row of the style new nodes of a kind take; -1: none.
records_kind_style :: proc(r:^Records,kind:ui.Node_Kind) -> int {
    for &info,i in r.style_infos {if kind in info.defaults && i<len(r.styles) {return i}}
    return -1
}

// Makes the style at row the one new nodes of kinds take, and no other.
records_kind_style_set :: proc(r:^Records,row:int,kinds:ui.Node_Kinds) {
    if row>=len(r.style_infos) {resize(&r.style_infos,len(r.styles))}
    for &info in r.style_infos {info.defaults-=kinds}
    r.style_infos[row].defaults+=kinds
}

// The style new nodes of a kind take: the one the file names, or the look of
// the kind, which the file names from then on (style 0 may not show it, and a
// control draws only the parts its style colors); 0 for a kind without a look.
records_kind_look :: proc(r:^Records,kind:ui.Node_Kind) -> u16 {
    if at:=records_kind_style(r,kind);at>=0 {return u16(at)}
    look,has:=node_default_look(kind)
    if !has || len(r.styles)>=int(max(u16)) {return 0}
    append(&r.styles,look)
    resize(&r.style_infos,len(r.styles))
    r.style_infos[len(r.styles)-1]={family=style_family(kind),defaults={kind}}
    return u16(len(r.styles)-1)
}

// Adds a node of a kind as the last one inside parent (-1: the last root) and
// returns its row; -1 when parent holds nothing or there is no memory.
records_insert :: proc(r:^Records,parent:int,kind:ui.Node_Kind) -> int {
    list:=&r.nodes
    if parent<-1 || parent>=len(list) || kind==.Component {return -1}
    if parent>=0 && !ui.node_kind_holds(list[parent].kind) && list[parent].kind!=.Component {return -1}
    // A List holds one node.
    if parent>=0 && list[parent].kind==.List && records_subtree(list[:],parent)>0 {return -1}
    at:=len(list) if parent<0 else parent+records_subtree(list[:],parent)+1
    node:=node_default(kind)
    records_text_set(r,&node.text,node_default_text(kind))
    if kind==.Box && parent<0 {node.float={to=.Safe,anchor=.Center,pivot=.Center}}
    node.style=records_kind_look(r,kind)
    nodes:=[1]ui.Tree_Node{node}
    if !records_put(r,at,parent,nodes[:]) {return -1}
    names:=KIND_NAMES
    records_name_unique(r,at,names[kind])
    return at
}

// Adds a use of the widget of a .ui as the last node inside parent, called
// name; the component that names the file, called as it, is made the first
// time.
records_widget :: proc(r:^Records,parent:int,widget:base.Asset_Id,name,file:string) -> int {
    list:=&r.nodes
    if widget=={} || parent<-1 || parent>=len(list) {return -1}
    if parent>=0 && !ui.node_kind_holds(list[parent].kind) && list[parent].kind!=.Component {return -1}
    component:=records_use_row(r,widget,file)
    at:=len(list) if parent<0 else parent+records_subtree(list[:],parent)+1
    node:=ui.Tree_Node{kind=.Component,parent=-1,component=u16(component+1)}
    ui.tree_text_set(node.name[:],name)
    nodes:=[1]ui.Tree_Node{node}
    if !records_put(r,at,parent,nodes[:]) {return -1}
    records_name_free(r,at)
    return at
}

// The row of the component of the uses of a widget: the one that is not a
// library, made the first time.
records_use_row :: proc(r:^Records,widget:base.Asset_Id,file:string) -> int {
    for &c,i in r.components {if c.widget==widget && !c.library {return i}}
    component:=ui.Tree_Component{widget=widget}
    ui.tree_text_set(component.name[:],records_component_name(r,file))
    append(&r.components,component)
    return len(r.components)-1
}

// A name for a component no other has.
@(private)
records_component_name :: proc(r:^Records,name:string) -> string {
    for n in 1..=len(r.components)+1 {
        candidate:=name if n==1 else fmt.tprintf("%s%d",name,n)
        taken:=false
        for &c in r.components {if serial.text_field(c.name[:])==candidate {taken=true;break}}
        if !taken {return candidate}
    }
    return name
}

// Takes a node and what it holds out of the rows of its scope.
@(private)
records_remove :: proc(r:^Records,row:int) {
    if row<0 || row>=len(r.nodes) {return}
    count:=records_subtree(r.nodes[:],row)+1
    end:=row+count
    remove_range(&r.nodes,row,end)
    for &n in r.nodes[row:] {if int(n.parent)>=end {n.parent-=i32(count)}}
    records_shift(r,row,-count)
}

// Removes a node and what it holds, with their translations; the focus and
// the ghost of the other nodes that named them name nothing.
records_delete :: proc(r:^Records,row:int) {
    list:=&r.nodes
    if row<0 || row>=len(list) {return}
    names:=make([dynamic]string,context.temp_allocator)
    for &n in list[row:row+records_subtree(list[:],row)+1] {
        if name:=serial.text_field(n.name[:]);name!="" {append(&names,strings.clone(name,context.temp_allocator))}
    }
    records_remove(r,row)
    for &n in list {
        for &nav in n.nav {if slice_has(names[:],serial.text_field(nav[:])) {nav={}}}
        if slice_has(names[:],serial.text_field(n.ghost[:])) {n.ghost={}}
    }
    records_texts_prune(r)
}

// Copies a node and what it holds right after it, with the overrides of its
// instances and an image and animations of its own; returns the copy.
records_duplicate :: proc(r:^Records,row:int) -> int {
    list:=&r.nodes
    if row<0 || row>=len(list) {return -1}
    count:=records_subtree(list[:],row)+1
    at,parent:=row+count,int(list[row].parent)
    block:=records_block(r,row)
    if !records_block_put(r,block,at,parent) {return -1}
    for i in at..<at+count {
        if name:=serial.text_field(list[i].name[:]);name!="" {records_name_unique(r,i,name)}
        records_rows_own(r,&list[i],{.Image,.Animations})
    }
    for &o in r.overrides {if int(o.instance)>=at && int(o.instance)<at+count {records_rows_own(r,&o.values,o.fields)}}
    records_texts_renew(r,list[at:at+count],r.translations[:])
    return at
}

// Gives a node rows of its own of the image and of the animations it shares
// with the node it was copied from: a copy edits only itself.
@(private)
records_rows_own :: proc(r:^Records,n:^ui.Tree_Node,fields:ui.Node_Fields) {
    if .Image in fields && n.image!=0 && int(n.image)<=len(r.images) && len(r.images)<int(max(u16)) {
        image:=r.images[n.image-1]
        append(&r.images,image)
        n.image=u16(len(r.images))
    }
    if .Animations in fields && n.anims!=0 && int(n.anims)<=len(r.anim_sets) && len(r.anim_sets)<int(max(u16)) {
        set:=r.anim_sets[n.anims-1]
        append(&r.anim_sets,set)
        n.anims=u16(len(r.anim_sets))
    }
}

// A new id for a localized text, unique in the project: the moment it is
// made, the file and the row it is made for.
records_text_id :: proc(r:^Records,salt:int) -> u64 {
    id:=base.hash_combine(u64(time.now()._nsec),base.hash_combine(u64(uintptr(r)),u64(salt)))
    return id if id!=0 else 1
}

// Gives the localized nodes of a copy ids of their own, with copies of the
// translations they had in from: a copy is another text, not the same one.
records_texts_renew :: proc(r:^Records,nodes:[]ui.Tree_Node,from:[]ui.Tree_Translation) {
    from:=slice.clone(from,context.temp_allocator)
    for &n,i in nodes {
        if n.text_id==0 {continue}
        old:=n.text_id
        n.text_id=records_text_id(r,i)
        for t in from {
            if t.id!=old {continue}
            copied:=t
            copied.id=n.text_id
            append(&r.translations,copied)
        }
    }
}

// The translations no node or override names any more go.
records_texts_prune :: proc(r:^Records) {
    used :: proc(r:^Records,id:u64) -> bool {
        for &n in r.nodes {if n.text_id==id {return true}}
        for &o in r.overrides {if o.values.text_id==id {return true}}
        return false
    }
    for i:=len(r.translations)-1;i>=0;i-=1 {
        if !used(r,r.translations[i].id) {ordered_remove(&r.translations,i)}
    }
}

// The text of a node in a language: its translation, or -1.
records_translation :: proc(r:^Records,id:u64,code:string) -> int {
    if id==0 {return -1}
    for &t,i in r.translations {
        if t.id==id && serial.text_field(t.language[:])==code {return i}
    }
    return -1
}

KIND_NAMES :: [ui.Node_Kind]string{.Box="box",.Text="text",.Image="image",.Progress="progress",.Button="button",.Checkbox="checkbox",.Spacer="spacer",.Component="component",
    .Scroll="scroll",.Switcher="switcher",.List="list",.Prompt="prompt",.Slider="slider",.Field="field",.Selector="selector",.Dropdown="dropdown",.Radio="radio",
    .Tooltip="tooltip",.Rich_Text="rich_text",.View="view",.Action_Bar="action_bar",.Number="number",.Tabs="tabs",.Popup="popup",.Modal="modal",
    .Context_Menu="context_menu",.Radial="radial",.Particles="particles"}

// Names a node after base_name and the first number no other node of its scope uses.
@(private)
records_name_unique :: proc(r:^Records,row:int,base_name:string) {
    list:=&r.nodes
    buffer:[ui.TREE_NAME_CAPACITY]u8
    for n in 1..<len(list)+2 {
        name:=serial_name(buffer[:],base_name,n)
        if !records_name_taken(list[:],row,name) {ui.tree_text_set(list[row].name[:],name);return}
    }
}

// Whether a node other than row has name.
@(private)
records_name_taken :: proc(nodes:[]ui.Tree_Node,row:int,name:string) -> bool {
    for &other,i in nodes {if i!=row && serial.text_field(other.name[:])==name {return true}}
    return false
}

// Keeps the name of a node when no other node of its scope has it; gives it a
// number otherwise.
@(private)
records_name_free :: proc(r:^Records,row:int) {
    list:=&r.nodes
    if name:=serial.text_field(list[row].name[:]);name!="" && records_name_taken(list[:],row,name) {records_name_unique(r,row,name)}
}

@(private)
serial_name :: proc(buffer:[]u8,base_name:string,n:int) -> string {
    at:=copy(buffer,base_name)
    // The digits a name ends in are replaced by the number.
    for at>0 && buffer[at-1]>='0' && buffer[at-1]<='9' {at-=1}
    digits:[20]u8
    count:=0
    for value:=n;value>0 || count==0;value/=10 {digits[count]=u8('0'+value%10);count+=1}
    for i:=count-1;i>=0 && at<len(buffer)-1;i-=1 {buffer[at]=digits[i];at+=1}
    return string(buffer[:at])
}

// Gives the node of a row the name its field has now, or that name with a
// number when another node has it, and points at it what named it by from:
// the focus and the ghost of the nodes and the parameters that go to it.
// Returns the name it has.
records_rename :: proc(r:^Records,row:int,from:string) -> string {
    list:=&r.nodes
    if row<0 || row>=len(list) {return ""}
    from:=strings.clone(from,context.temp_allocator)
    records_name_free(r,row)
    name:=strings.clone(serial.text_field(list[row].name[:]),context.temp_allocator)
    if from=="" || from==name {return name}
    for &n in list {
        for &nav in n.nav {if serial.text_field(nav[:])==from {ui.tree_text_set(nav[:],name)}}
        if serial.text_field(n.ghost[:])==from {ui.tree_text_set(n.ghost[:],name)}
    }
    for &p in r.params {path_part_rename(p.node[:],0,from,name)}
    return name
}

// Renames the part of a path of names ("slot/icon") that starts at byte
// start when it is from; false when it is not, or the path would not fit.
path_part_rename :: proc(field:[]u8,start:int,from,to:string) -> bool {
    path:=serial.text_field(field)
    end:=start+len(from)
    if end>len(path) || path[start:end]!=from || end<len(path) && path[end]!='/' {return false}
    renamed:=strings.concatenate({path[:start],to,path[end:]},context.temp_allocator)
    if len(renamed)>=len(field) {return false}
    ui.tree_text_set(field,renamed)
    return true
}

@(private="file")
records_same :: proc(x,y:^$T) -> bool {return mem.compare_ptrs(x,y,size_of(T))==0}

// The row of the scope whose node differs between two reads of the file
// (an undo, a redo): the first node that changed, or that was added or
// removed there, or else one that takes a style, a variant or an image that
// changed; the node chosen when it takes it. -1: no node changed.
records_changed_row :: proc(before,after:^Records,chosen:int) -> int {
    a,b:=before.nodes,after.nodes
    if len(b)==0 {return -1}
    for i in 0..<min(len(a),len(b)) {
        if !records_same(&a[i],&b[i]) {return i}
    }
    if len(a)!=len(b) {return min(len(a),len(b)-1)}
    // A node that takes what changed: the one chosen first.
    taker :: proc(nodes:[]ui.Tree_Node,chosen:int,takes:proc(n:^ui.Tree_Node,row:int) -> bool,row:int) -> int {
        if chosen>=0 && chosen<len(nodes) && takes(&nodes[chosen],row) {return chosen}
        for &n,i in nodes {if takes(&n,row) {return i}}
        return -1
    }
    style :: proc(n:^ui.Tree_Node,row:int) -> bool {return int(n.style)==row}
    image :: proc(n:^ui.Tree_Node,row:int) -> bool {return int(n.image)==row+1}
    for i in 0..<min(len(before.styles),len(after.styles)) {
        if !records_same(&before.styles[i],&after.styles[i]) {return taker(b[:],chosen,style,i)}
    }
    for i in 0..<min(len(before.variants),len(after.variants)) {
        if !records_same(&before.variants[i],&after.variants[i]) {return taker(b[:],chosen,style,int(after.variants[i].style))}
    }
    for i in 0..<min(len(before.images),len(after.images)) {
        if !records_same(&before.images[i],&after.images[i]) {return taker(b[:],chosen,image,i)}
    }
    // A translation: the node whose text it is.
    changed:=u64(0)
    for i in 0..<max(len(before.translations),len(after.translations)) {
        if i>=len(before.translations) {changed=after.translations[i].id;break}
        if i>=len(after.translations) {changed=before.translations[i].id;break}
        if !records_same(&before.translations[i],&after.translations[i]) {changed=after.translations[i].id;break}
    }
    if changed!=0 {for &n,i in b {if n.text_id==changed {return i}}}
    return -1
}

// ---------------------------------------------------------------- styles

// A style is named, or overrides a style for the node that uses it until it
// is saved there; the other styles show as their rows.

// A style at the end of the styles, with the variants given (theirs is set
// to it) and its info; its row.
records_style_add :: proc(r:^Records,style:ui.Node_Style,variants:[]ui.Tree_Style_Variant,info:ui.Tree_Style_Info) -> int {
    if len(r.styles)>=int(max(u16)) {return -1}
    append(&r.styles,style)
    append(&r.style_infos,info)
    row:=len(r.styles)-1
    for v in variants {
        copied:=v
        copied.style=u16(row)
        append(&r.variants,copied)
    }
    return row
}

// The variants of a style, copied in the temporary allocator.
records_style_variants :: proc(r:^Records,row:int) -> []ui.Tree_Style_Variant {
    list:=make([dynamic]ui.Tree_Style_Variant,context.temp_allocator)
    for v in r.variants {if int(v.style)==row {append(&list,v)}}
    return list[:]
}

// The name a style shows: its own, or its row.
records_style_name :: proc(r:^Records,row:int) -> string {
    if row>=0 && row<len(r.style_infos) {
        if name:=serial.text_field(r.style_infos[row].name[:]);name!="" {return name}
    }
    return fmt.tprintf("Style %d",row)
}

// Whether a row is a style with a name, which nodes share; one without is the own look of a node.
records_style_named :: proc(r:^Records,row:int) -> bool {
    return row>=0 && row<len(r.style_infos) && r.style_infos[row].name[0]!=0
}

// The family of styles a node of kind takes.
style_family :: proc(kind:ui.Node_Kind) -> ui.Style_Family {
    #partial switch kind {
    case .Text,.Rich_Text,.Prompt,.Action_Bar:                        return .Text
    case .Button,.Checkbox,.Slider,.Field,.Number,.Selector,.Dropdown,.Radio: return .Control
    }
    return .Box
}

// The row of the style a style overrides; -1 when it overrides none.
records_style_base :: proc(r:^Records,row:int) -> int {
    if row<0 || row>=len(r.style_infos) {return -1}
    base:=int(r.style_infos[row].base)-1
    return base if base>=0 && base<len(r.styles) && base!=row else -1
}

// How many nodes of the file and overrides of instances use a style.
records_style_users :: proc(r:^Records,row:int) -> (users:int) {
    for &n in r.nodes {users+=int(int(n.style)==row)}
    for &o in r.overrides {users+=int(.Style in o.fields && int(o.values.style)==row)}
    return
}

// A name for a new style that no other style has.
records_style_name_unique :: proc(r:^Records) -> string {
    for n:=len(r.styles);;n+=1 {
        name:=fmt.tprintf("Style %d",n)
        taken:=false
        for &info in r.style_infos {taken|=serial.text_field(info.name[:])==name}
        if !taken {return name}
    }
}

// Saves the override row into the style it overrides: its values and
// variants become those of that style, the nodes that used it use that
// style, and it goes. Returns the row of that style; -1 when row overrides none.
records_style_save :: proc(r:^Records,row:int) -> int {
    base:=records_style_base(r,row)
    if base<0 {return -1}
    // What the override changes is the style's own, and no token gives it any more.
    if base<len(r.style_infos) {
        info:=&r.style_infos[base]
        had:=ui.style_own_keys(info)
        for key in ui.Style_Key {
            if key in ui.LAYOUT_KEYS || key==.Blur || !ui.style_key_differs(&r.styles[base],&r.styles[row],key) {continue}
            info.sets+={key}
            if key not_in had || info.extends[0]==0 {records_token_use(r,base,"",{},key,"")}
        }
    }
    r.styles[base]=r.styles[row]
    for i:=len(r.variants)-1;i>=0;i-=1 {
        if int(r.variants[i].style)==base {ordered_remove(&r.variants,i)}
    }
    // The rules take the place of those of the style, and say what they set themselves.
    for &v in r.variants {
        if int(v.style)!=row {continue}
        v.style=u16(base)
        v.own,v.inherited,v.extends={},false,{}
        name:=serial.text_field(v.variant[:])
        for i:=len(r.token_uses)-1;i>=0;i-=1 {
            u:=r.token_uses[i]
            if int(u.style)==base && u.states==v.states && serial.text_field(u.variant[:])==name {ordered_remove(&r.token_uses,i)}
        }
    }
    records_style_retarget(r,row,base)
    return records_style_remove(r,row,base)
}

// Points what uses the style from at the style to.
records_style_retarget :: proc(r:^Records,from,to:int) {
    for &n in r.nodes {if int(n.style)==from {n.style=u16(to)}}
    for &o in r.overrides {if int(o.values.style)==from {o.values.style=u16(to)}}
}

// Takes away a style nothing uses, and its variants: the rows after it move
// up. Returns where the style of row keep ends up.
records_style_remove :: proc(r:^Records,row,keep:int) -> int {
    if row<=0 || row>=len(r.styles) || records_style_users(r,row)>0 {return keep}
    ordered_remove(&r.styles,row)
    ordered_remove(&r.style_infos,row)
    for i:=len(r.variants)-1;i>=0;i-=1 {
        if int(r.variants[i].style)==row {ordered_remove(&r.variants,i)}
    }
    shift :: proc(style:^u16,row:int) {if int(style^)>row {style^-=1}}
    for &v in r.variants {shift(&v.style,row)}
    for &n in r.nodes {shift(&n.style,row)}
    for &o in r.overrides {shift(&o.values.style,row)}
    for i:=len(r.token_uses)-1;i>=0;i-=1 {
        if int(r.token_uses[i].style)==row {ordered_remove(&r.token_uses,i)} else {shift(&r.token_uses[i].style,row)}
    }
    for &info in r.style_infos {
        if int(info.base)==row+1 {info.base=0} else if int(info.base)>row+1 {info.base-=1}
    }
    return keep-1 if keep>row else keep
}

// Takes away a named style no node uses, with its variants; false when a
// node uses it or changes it (an override of it).
records_style_delete :: proc(r:^Records,row:int) -> bool {
    if row<=0 || row>=len(r.styles) || !records_style_named(r,row) || records_style_users(r,row)>0 {return false}
    for &info in r.style_infos {if int(info.base)==row+1 {return false}}
    records_style_remove(r,row,0)
    return true
}

// Renames a variant of a style: its rules, and the variant the nodes and the
// overrides that take that style show.
records_variant_rename :: proc(r:^Records,style:int,from,to:string) {
    from:=strings.clone(from,context.temp_allocator)
    for &v in r.variants {
        if int(v.style)==style && serial.text_field(v.variant[:])==from {ui.tree_text_set(v.variant[:],to)}
    }
    rename :: proc(n:^ui.Tree_Node,style:int,from,to:string) {
        if int(n.style)==style && serial.text_field(n.variant[:])==from {ui.tree_text_set(n.variant[:],to)}
    }
    for &n in r.nodes {rename(&n,style,from,to)}
    for &o in r.overrides {if .Style in o.fields && .Variant in o.fields {rename(&o.values,style,from,to)}}
}

// How many nodes and overrides that set it take an image
// (field .Image) or a set of animations (.Animations), by row plus one.
@(private)
records_row_users :: proc(r:^Records,field:ui.Node_Field,row:u16) -> (users:int) {
    takes :: proc(n:^ui.Tree_Node,field:ui.Node_Field,row:u16) -> bool {return (n.image if field==.Image else n.anims)==row}
    for &n in r.nodes {users+=int(takes(&n,field,row))}
    for &o in r.overrides {users+=int(field in o.fields && takes(&o.values,field,row))}
    return
}

// The image row of a node, made the first time and copied when other nodes
// take it too; -1 when there is no room.
records_image :: proc(r:^Records,node:^ui.Tree_Node) -> int {
    if node.image!=0 && int(node.image)<=len(r.images) {
        if records_row_users(r,.Image,node.image)>1 {records_rows_own(r,node,{.Image})}
        return int(node.image)-1
    }
    if len(r.images)>=int(max(u16)) {return -1}
    append(&r.images,ui.Tree_Image{})
    node.image=u16(len(r.images))
    return len(r.images)-1
}

// The set of animations of a node, made the first time and copied when
// other nodes take it too.
records_anim_set :: proc(r:^Records,node:^ui.Tree_Node) -> int {
    if node.anims!=0 && int(node.anims)<=len(r.anim_sets) {
        if records_row_users(r,.Animations,node.anims)>1 {records_rows_own(r,node,{.Animations})}
        return int(node.anims)-1
    }
    if len(r.anim_sets)>=int(max(u16)) {return -1}
    append(&r.anim_sets,ui.Anim_Set{})
    node.anims=u16(len(r.anim_sets))
    return len(r.anim_sets)-1
}

// What a property holds when nothing animates it.
property_default :: proc "contextless" (property:ui.Anim_Property) -> [4]f32 {
    switch property {
    case .Offset,.Rotation: return {}
    case .Scale:            return {1,1,0,0}
    case .Opacity:          return {1,0,0,0}
    case .Color:            return {1,1,1,1}
    case .Width,.Height,.Value,.Frame,.Reveal: return {}
    }
    return {}
}

// A clip of one track of a property from one value to another in duration
// seconds; returns its row.
records_clip :: proc(r:^Records,name:string,property:ui.Anim_Property,from,to:[4]f32,duration:f32) -> int {
    first_key:=u32(len(r.keys))
    append(&r.keys,ui.Keyframe{time=0,value=from},ui.Keyframe{time=duration,value=to,ease=.Out_Cubic})
    append(&r.tracks,ui.Tree_Track{property=property,first_key=first_key,key_count=2})
    a:=ui.Tree_Anim{kind=.Clip,first=u32(len(r.tracks)-1),count=1}
    ui.tree_text_set(a.name[:],name)
    append(&r.anims,a)
    return len(r.anims)-1
}

// Adds a track to a clip, with one key; false when the clip has the most tracks.
records_track_add :: proc(r:^Records,anim:int,property:ui.Anim_Property) -> bool {
    a:=&r.anims[anim]
    if a.kind!=.Clip || a.count>=ui.TREE_CLIP_TRACKS {return false}
    at:=int(a.first+a.count)
    key:=u32(len(r.keys))
    append(&r.keys,ui.Keyframe{value=property_default(property)})
    inject_at(&r.tracks,at,ui.Tree_Track{property=property,first_key=key,key_count=1})
    // Clips whose tracks come after it move by one.
    for &other,i in r.anims {
        if i!=anim && other.kind==.Clip && int(other.first)>=at {other.first+=1}
    }
    a.count+=1
    return true
}

// Removes a track of a clip with its keys; a clip keeps one.
records_track_remove :: proc(r:^Records,anim,track:int) {
    a:=&r.anims[anim]
    if a.kind!=.Clip || track<0 || track>=int(a.count) || a.count<=1 {return}
    at:=int(a.first)+track
    t:=r.tracks[at]
    records_keys_remove(r,int(t.first_key),int(t.key_count))
    ordered_remove(&r.tracks,at)
    for &other,i in r.anims {
        if i!=anim && other.kind==.Clip && int(other.first)>at {other.first-=1}
    }
    a.count-=1
}

// Adds a key to a track, a second after its last.
records_key_add :: proc(r:^Records,track:int) {
    t:=&r.tracks[track]
    at:=int(t.first_key+t.key_count)
    key:=ui.Keyframe{}
    if t.key_count>0 {key=r.keys[at-1];key.time+=1}
    inject_at(&r.keys,at,key)
    for &other,i in r.tracks {
        if i!=track && int(other.first_key)>=at {other.first_key+=1}
    }
    t.key_count+=1
}

// Removes a key of a track; a track keeps one.
records_key_remove :: proc(r:^Records,track,key:int) {
    t:=&r.tracks[track]
    if key<0 || key>=int(t.key_count) || t.key_count<=1 {return}
    records_keys_remove(r,int(t.first_key)+key,1)
    t.key_count-=1
}

@(private)
records_keys_remove :: proc(r:^Records,at,count:int) {
    remove_range(&r.keys,at,at+count)
    for &other in r.tracks {
        if int(other.first_key)>=at+count {other.first_key-=u32(count)}
    }
}

// Puts the keys of each track in time order, as the tree takes them: a key
// whose time was edited past another goes after it.
records_keys_sort :: proc(r:^Records) {
    for t in r.tracks {
        if u64(t.first_key)+u64(t.key_count)>u64(len(r.keys)) {continue}
        slice.stable_sort_by(r.keys[t.first_key:][:t.key_count],proc(a,b:ui.Keyframe) -> bool {return a.time<b.time})
    }
}

// Writes what a parameter of the use at row gives: on the instance when it
// goes to its root, or on the override of the node it goes to, node as the
// widget has it and its rows those of source. style: the row a parameter of a
// style goes by.
records_param_set :: proc(r:^Records,row:int,p:^ui.Tree_Param,value:string,style:int,source:^Records,node:ui.Tree_Node) {
    path:=serial.text_field(p.node[:])
    group:=doc_param_group(p.field)
    target:^ui.Tree_Node
    if path=="" {
        target=&r.nodes[row]
        r.nodes[row].component_fields+={group}
    } else {
        at:=records_override(r,row,path,{})
        if group not_in r.overrides[at].fields {records_override_field(r,at,group,true,source,node)}
        target=&r.overrides[at].values
    }
    #partial switch p.field {
    case .Text:
        records_text_set(r,&target.text,value)
        target.text_id=0
    case .Style:
        target.style=u16(style)
    case:
        ui.tree_text_set(doc_param_slot(target,p.field),value)
    }
}

// records_param_set with a style by its name, of the file or of a file it
// uses. False when that name does not resolve.
records_param_give :: proc(a:^host.Assets,r:^Records,row:int,p:^ui.Tree_Param,value:string,source:^Records,node:ui.Tree_Node) -> bool {
    style:=0
    if p.field==.Style {
        args:=Tree_Args{assets=a}
        libs:=doc_libs(&args,r)
        args.libs=&libs
        style=doc_style_row(&args,r,value)
        if style<0 {return false}
    }
    records_param_set(r,row,p,value,style,source,node)
    return true
}

// The row of the node that holds what a use holds; -1: none.
records_slot_row :: proc(r:^Records) -> int {
    for &n,i in r.nodes {if .Slot in n.flags {return i}}
    return -1
}

// The overrides of an instance of the tree, by row.
records_overrides :: proc(r:^Records,instance:int,allocator:=context.temp_allocator) -> []int {
    rows:=make([dynamic]int,allocator)
    for o,i in r.overrides {if int(o.instance)==instance {append(&rows,i)}}
    return rows[:]
}

// The override of node (its name in its widget) of an instance: the one it
// has, or one made with values.
records_override :: proc(r:^Records,instance:int,node:string,values:ui.Tree_Node) -> int {
    for &o,i in r.overrides {
        if int(o.instance)==instance && serial.text_field(o.node[:])==node {return i}
    }
    o:=ui.Tree_Override{instance=u32(instance),values=values}
    ui.tree_text_set(o.node[:],node)
    append(&r.overrides,o)
    return len(r.overrides)-1
}

// Turns a field of an override on or off. On, it takes the values the node
// of the widget has (node, whose rows are of source), so it changes nothing
// until one of them changes.
records_override_field :: proc(r:^Records,override:int,field:ui.Node_Field,on:bool,source:^Records,node:ui.Tree_Node) {
    if override<0 || override>=len(r.overrides) {return}
    o:=&r.overrides[override]
    if !on || field in o.fields {
        if !on {o.fields-={field}}
        return
    }
    o.fields+={field}
    v,n:=&o.values,node
    m:Merge
    if source!=nil {m=merge_begin(r,source,false)}
    switch field {
    case .Text:
        v.text_id=n.text_id
        v.fields=n.fields
        v.text=merge_text(&m,n.text) if source!=nil else n.text
    case .Style:      v.style=merge_style(&m,int(n.style)) if source!=nil else n.style
    case .Layout:
        v.layout=n.layout
        if source!=nil {v.layout.tracks=merge_grid(&m,n.layout.tracks)}
    case .Float:      v.float=n.float
    case .Image:      v.image=merge_image(&m,n.image) if source!=nil else n.image
    case .Animations: v.anims=merge_set(&m,n.anims) if source!=nil else n.anims
    case .Bindings:
        v.bind_text=n.bind_text;v.bind_value=n.bind_value;v.bind_visible=n.bind_visible;v.bind_selected=n.bind_selected;v.bind_disabled=n.bind_disabled
        v.bind_items=n.bind_items;v.bind_image=n.bind_image;v.bind_tint=n.bind_tint;v.bind_variant=n.bind_variant;v.data=n.data
    case .Visibility: v.selected,v.disabled=n.selected,n.disabled
    case .Variant:    v.variant=n.variant
    case .Layer:      v.layer=n.layer
    case .Clip:       v.clip=n.clip
    case .Block:      v.block=n.block
    case .Values:     v.index,v.count,v.choice,v.range,v.limit,v.delay,v.particle=n.index,n.count,n.choice,n.range,n.limit,n.delay,n.particle
    case .Action:     v.action,v.hold=n.action,n.hold
    case .Focus:      v.nav=n.nav;v.order,v.flags=n.order,n.flags
    case .Drag:       v.tag,v.accepts,v.ghost=n.tag,n.accepts,n.ghost
    }
}

// ---------------------------------------------------------------- blocks

// A node and what it holds, copied: parents relative to the first, the
// overrides of its instances relative to it too, with the rows of r.
@(private)
Block :: struct {
    nodes:[dynamic]ui.Tree_Node,
    overrides:[dynamic]ui.Tree_Override,
}

// The subtree of a row of a scope, with the overrides of its instances.
@(private)
records_block :: proc(r:^Records,row:int) -> (block:Block) {
    list:=&r.nodes
    block.nodes=make([dynamic]ui.Tree_Node,context.temp_allocator)
    block.overrides=make([dynamic]ui.Tree_Override,context.temp_allocator)
    count:=records_subtree(list[:],row)+1
    for n,i in list[row:row+count] {
        moved:=n
        moved.parent=-1 if i==0 else n.parent-i32(row)
        append(&block.nodes,moved)
    }
    for o in r.overrides {
        if int(o.instance)<row || int(o.instance)>=row+count {continue}
        moved:=o
        moved.instance=u32(int(o.instance)-row)
        append(&block.overrides,moved)
    }
    return
}

// Puts a block at row at of a scope inside parent, with its overrides.
@(private)
records_block_put :: proc(r:^Records,block:Block,at,parent:int) -> bool {
    if !records_put(r,at,parent,block.nodes[:]) {return false}
    for o in block.overrides {
        moved:=o
        moved.instance=u32(int(o.instance)+at)
        append(&r.overrides,moved)
    }
    return true
}

// Whether parent (-1: the root) may take one more node.
@(private)
records_takes :: proc(nodes:[]ui.Tree_Node,parent:int) -> bool {
    if parent<0 || nodes[parent].kind==.Component {return true}
    if !ui.node_kind_holds(nodes[parent].kind) {return false}
    return nodes[parent].kind!=.List || records_subtree(nodes,parent)==0
}

// Moves a node of the tree and what it holds inside parent (-1: a root),
// before the node at row before, or last when before is -1, with its
// overrides and translations. Returns where it went; -1 when it cannot: into
// itself or into what takes no other node.
records_place :: proc(r:^Records,row,parent,before:int) -> int {
    list:=r.nodes[:]
    if row<0 || row>=len(list) || parent>=len(list) || before>=len(list) {return -1}
    count:=records_subtree(list,row)+1
    inside :: proc(at,row,count:int) -> bool {return at>=row && at<row+count}
    if parent>=0 && inside(parent,row,count) || before>=0 && inside(before,row,count) {return -1}
    if int(list[row].parent)!=parent && !records_takes(list,parent) {return -1}
    block:=records_block(r,row)
    records_remove(r,row)
    after :: proc(at,row,count:int) -> int {return at-count if at>row else at}
    parent,before:=after(parent,row,count) if parent>=0 else -1,after(before,row,count) if before>=0 else -1
    at:=before
    if at<0 {at=len(r.nodes) if parent<0 else parent+records_subtree(r.nodes[:],parent)+1}
    if !records_block_put(r,block,at,parent) {return -1}
    return at
}

// What Copy took: a node of the tree and what it holds as records of their
// own, with only the rows they use and their texts, so that they paste into
// any .ui; source is the .ui they come from.
Clip_Nodes :: struct {
    records:Records,
    source:base.Asset_Id,
}

clip_destroy :: proc(clip:^Clip_Nodes) {
    records_destroy(&clip.records)
    clip^={}
}

// Copies a node of the tree and what it holds into clip, in allocator.
records_copy :: proc(r:^Records,row:int,clip:^Clip_Nodes,allocator:=context.allocator) {
    if row<0 || row>=len(r.nodes) {return}
    clip_destroy(clip)
    records_extract(r,row,&clip.records,allocator,false)
}

// Puts a copy of what clip holds inside the row chosen when it holds nodes,
// after it otherwise, or last at the root (-1), with copies of the rows of
// its file it uses: a named style, an animation by its name, a font and a
// widget are those of r when it has them. Returns the copy; -1 when there is
// nothing to paste or no room there.
records_paste :: proc(r:^Records,row:int,clip:^Clip_Nodes) -> int {
    pasted:=records_paste_rows(r,row,clip)
    return pasted[0] if len(pasted)>0 else -1
}

// The records of a .ui made of a Box of the tree and what it holds, in
// allocator: only the rows they use, with texts of their own. False for a
// node of another kind.
records_widget_data :: proc(r:^Records,row:int,out:^Records,allocator:runtime.Allocator) -> bool {
    if row<0 || row>=len(r.nodes) || r.nodes[row].kind!=.Box || !records_extract(r,row,out,allocator,true) {return false}
    // The root of a widget lays out where its instance puts it.
    out.nodes[0].float={}
    records_widget_params(out)
    return true
}

// A node of the tree and what it holds as records of their own.
@(private)
records_extract :: proc(r:^Records,row:int,out:^Records,allocator:runtime.Allocator,renew:bool) -> bool {
    style:=[1]ui.Node_Style{r.styles[0]}
    if !records_load(out,{styles=style[:]},allocator) {return false}
    block:=records_block(r,row)
    m:=merge_begin(out,r,renew)
    if merge_put(&m,block.nodes[:],block.overrides[:],0,-1)<0 {
        records_destroy(out)
        return false
    }
    return true
}

// ---------------------------------------------------------------- merge

// Copies of nodes of src in dst, with the rows of src they use: each table
// of src maps its rows to those of dst, plus one (0: none yet). A named
// style, an animation by its name, a font and a widget by their assets are
// those dst has when it has them, an own look one just like it; images and
// sets of animations are copied for each node, as nodes edit them in place.
@(private)
Merge :: struct {
    dst,src:^Records,
    styles,anims,fonts,components:[]int,
    renew:bool,  // localized texts get ids of their own
    salt:int,    // of the ids it made
    named:bool,  // the images of src with a name, which <img=...> shows, are in dst
    failed:bool, // a table of dst is full
}

@(private)
merge_begin :: proc(dst,src:^Records,renew:bool) -> Merge {
    return {dst=dst,src=src,renew=renew,styles=make([]int,len(src.styles),context.temp_allocator),anims=make([]int,len(src.anims),context.temp_allocator),
        fonts=make([]int,len(src.fonts),context.temp_allocator),components=make([]int,len(src.components),context.temp_allocator)}
}

// Puts copies of nodes of src (a subtree: parents relative to it, the first
// a root) and the overrides of their instances (relative to it too) at row
// at of the tree of dst inside parent. Returns at; -1 when dst is full.
@(private)
merge_put :: proc(m:^Merge,nodes:[]ui.Tree_Node,overrides:[]ui.Tree_Override,at,parent:int) -> int {
    copied:=make([]ui.Tree_Node,len(nodes),context.temp_allocator)
    for n,i in nodes {
        copied[i]=n
        merge_node(m,&copied[i])
    }
    if m.failed || !records_put(m.dst,at,parent,copied) {return -1}
    for o in overrides {
        moved:=o
        merge_override(m,&moved)
        moved.instance+=u32(at)
        append(&m.dst.overrides,moved)
    }
    return at
}

@(private)
merge_node :: proc(m:^Merge,n:^ui.Tree_Node) {
    n.text=merge_text(m,n.text)
    merge_translations(m,n)
    n.style=merge_style(m,int(n.style))
    n.image=merge_image(m,n.image)
    n.anims=merge_set(m,n.anims)
    n.component=merge_component(m,n.component)
    n.layout.tracks=merge_grid(m,n.layout.tracks)
    if n.kind!=.Rich_Text || m.named {return}
    m.named=true
    for &image in m.src.images {
        name:=serial.text_field(image.name[:])
        if name=="" {continue}
        found:=false
        for &other in m.dst.images {found|=serial.text_field(other.name[:])==name}
        if !found {append(&m.dst.images,image)}
    }
}

// The values of an override, those of the fields it sets: the rows of the
// others name nothing.
@(private)
merge_override :: proc(m:^Merge,o:^ui.Tree_Override) {
    v:=&o.values
    if .Text in o.fields {
        v.text=merge_text(m,v.text)
        merge_translations(m,v)
    } else {v.text,v.text_id={},0}
    v.style=merge_style(m,int(v.style)) if .Style in o.fields else 0
    v.image=merge_image(m,v.image) if .Image in o.fields else 0
    v.anims=merge_set(m,v.anims) if .Animations in o.fields else 0
    v.layout.tracks=merge_grid(m,v.layout.tracks) if .Layout in o.fields else 0
    v.component=0
}

@(private)
merge_text :: proc(m:^Merge,s:ui.Tree_String) -> ui.Tree_String {return ui.tree_string_add(&m.dst.text,records_text(m.src,s))}

// The translations of a localized node go with it, under an id of its own when renew.
@(private)
merge_translations :: proc(m:^Merge,n:^ui.Tree_Node) {
    if n.text_id==0 {return}
    old:=n.text_id
    if m.renew {
        m.salt+=1
        n.text_id=records_text_id(m.dst,m.salt)
    }
    for t in m.src.translations {
        if t.id!=old {continue}
        copied:=t
        copied.id,copied.text=n.text_id,merge_text(m,t.text)
        append(&m.dst.translations,copied)
    }
}

@(private)
merge_font :: proc(m:^Merge,font:u8) -> u8 {
    if int(font)<ui.FONT_TREE {return font}
    row:=int(font)-ui.FONT_TREE
    if row>=len(m.src.fonts) {return ui.FONT_REGULAR}
    if m.fonts[row]==0 {
        to:=-1
        for f,i in m.dst.fonts {if f.font==m.src.fonts[row].font {to=i;break}}
        if to<0 {
            append(&m.dst.fonts,m.src.fonts[row])
            to=len(m.dst.fonts)-1
        }
        m.fonts[row]=to+1
    }
    at:=ui.FONT_TREE+m.fonts[row]-1
    if at>int(max(u8)) {m.failed=true;return ui.FONT_REGULAR}
    return u8(at)
}

@(private)
merge_style :: proc(m:^Merge,row:int) -> u16 {
    src,dst:=m.src,m.dst
    if row<0 || row>=len(src.styles) {return 0}
    if m.styles[row]>0 {return u16(m.styles[row]-1)}
    style:=src.styles[row]
    style.text.font=merge_font(m,style.text.font)
    variants:=records_style_variants(src,row)
    for &v in variants {v.patch.values.text.font=merge_font(m,v.patch.values.text.font)}
    info:=src.style_infos[row] if row<len(src.style_infos) else {}
    info.defaults={} // which styles its new nodes take is said by the file pasted into
    base:=records_style_base(src,row)
    info.base=merge_style(m,base)+1 if base>=0 else 0
    named:=records_style_named(src,row)
    to:=-1
    // An override is of its node alone; a named style is the one of that name, an own look one alike.
    if base<0 {
        for i in 0..<len(dst.styles) {
            if records_style_named(dst,i)!=named || records_style_base(dst,i)>=0 {continue}
            if named {
                if dst.style_infos[i].family==info.family && serial.text_field(dst.style_infos[i].name[:])==serial.text_field(info.name[:]) {to=i;break}
            } else if records_same(&dst.styles[i],&style) && variants_same(records_style_variants(dst,i),variants) {to=i;break}
        }
    }
    if to<0 {to=records_style_add(dst,style,variants,info)}
    if to<0 {m.failed=true;return 0}
    m.styles[row]=to+1
    return u16(to)
}

// Whether two styles have the same rules.
@(private)
variants_same :: proc(a,b:[]ui.Tree_Style_Variant) -> bool {
    if len(a)!=len(b) {return false}
    for i in 0..<len(a) {
        x,y:=a[i],b[i]
        x.style,y.style=0,0
        if !records_same(&x,&y) {return false}
    }
    return true
}

@(private)
merge_image :: proc(m:^Merge,image:u16) -> u16 {
    if image==0 || int(image)>len(m.src.images) {return 0}
    if len(m.dst.images)>=int(max(u16)) {m.failed=true;return 0}
    append(&m.dst.images,m.src.images[image-1])
    return u16(len(m.dst.images))
}

@(private)
merge_set :: proc(m:^Merge,anims:u16) -> u16 {
    if anims==0 || int(anims)>len(m.src.anim_sets) {return 0}
    if len(m.dst.anim_sets)>=int(max(u16)) {m.failed=true;return 0}
    set:=m.src.anim_sets[anims-1]
    for &played in (^[size_of(ui.Anim_Set)/size_of(ui.Anim)]ui.Anim)(&set) {played=merge_anim(m,played)}
    append(&m.dst.anim_sets,set)
    return u16(len(m.dst.anim_sets))
}

@(private)
merge_anim :: proc(m:^Merge,played:ui.Anim) -> ui.Anim {
    src,dst:=m.src,m.dst
    row:=int(played)-1
    if row<0 || row>=len(src.anims) {return 0}
    if m.anims[row]>0 {return ui.Anim(m.anims[row])}
    anim:=src.anims[row]
    to:=-1
    if name:=serial.text_field(anim.name[:]);name!="" {
        for &other,i in dst.anims {if serial.text_field(other.name[:])==name {to=i;break}}
    }
    if to<0 {
        switch anim.kind {
        case .Clip:
            if u64(anim.first)+u64(anim.count)>u64(len(src.tracks)) {return 0}
            first:=len(dst.tracks)
            for t in src.tracks[anim.first:][:anim.count] {
                if u64(t.first_key)+u64(t.key_count)>u64(len(src.keys)) {return 0}
                track:=t
                track.first_key=u32(len(dst.keys))
                append(&dst.keys,..src.keys[t.first_key:][:t.key_count])
                append(&dst.tracks,track)
            }
            anim.first=u32(first)
        case .Sequence,.Parallel:
            if u64(anim.first)+u64(anim.count)>u64(len(src.parts)) {return 0}
            // What a group plays comes before it.
            parts:=make([]ui.Anim,anim.count,context.temp_allocator)
            for part,i in src.parts[anim.first:][:anim.count] {parts[i]=merge_anim(m,part)}
            anim.first=u32(len(dst.parts))
            append(&dst.parts,..parts)
        }
        if len(dst.anims)>=int(max(u16))-1 {m.failed=true;return 0}
        append(&dst.anims,anim)
        to=len(dst.anims)-1
    }
    m.anims[row]=to+1
    return ui.Anim(to+1)
}

@(private)
merge_component :: proc(m:^Merge,component:u16) -> u16 {
    src,dst:=m.src,m.dst
    row:=int(component)-1
    if row<0 || row>=len(src.components) {return 0}
    if m.components[row]>0 {return u16(m.components[row])}
    if len(dst.components)>=int(max(u16))-1 {m.failed=true;return 0}
    c:=&src.components[row]
    if c.library {
        m.components[row]=int(records_library(dst,c.widget))
    } else {
        m.components[row]=records_use_row(dst,c.widget,serial.text_field(c.name[:]))+1
    }
    return u16(m.components[row])
}

@(private)
merge_grid :: proc(m:^Merge,tracks:u16) -> u16 {
    if tracks==0 || int(tracks)>len(m.src.grid_tracks) {return 0}
    grid:=m.src.grid_tracks[tracks-1]
    for &other,i in m.dst.grid_tracks {if records_same(&other,&grid) {return u16(i+1)}}
    if len(m.dst.grid_tracks)>=int(max(u16)) {m.failed=true;return 0}
    append(&m.dst.grid_tracks,grid)
    return u16(len(m.dst.grid_tracks))
}

// ---------------------------------------------------------------- garbage

@(private="file")
Collect :: struct {styles,images,sets,grids,components:[]int} // by row: kept, then its new row plus one; 0: it goes

@(private="file")
collect_mark :: proc(c:^Collect,n:^ui.Tree_Node,fields:ui.Node_Fields) {
    mark :: proc(keep:[]int,row:int) {if row>=0 && row<len(keep) {keep[row]=1}}
    if .Style in fields {mark(c.styles,int(n.style))}
    if .Image in fields {mark(c.images,int(n.image)-1)}
    if .Animations in fields {mark(c.sets,int(n.anims)-1)}
    if .Layout in fields {mark(c.grids,int(n.layout.tracks)-1)}
    if n.kind==.Component {mark(c.components,int(n.component)-1)}
}

@(private="file")
collect_move :: proc(c:^Collect,n:^ui.Tree_Node) {
    at :: proc(keep:[]int,row:int) -> int {return keep[row] if row>=0 && row<len(keep) else 0}
    n.style=u16(max(at(c.styles,int(n.style))-1,0))
    n.image=u16(at(c.images,int(n.image)-1))
    n.anims=u16(at(c.sets,int(n.anims)-1))
    n.layout.tracks=u16(at(c.grids,int(n.layout.tracks)-1))
    if n.component!=0 {n.component=u16(at(c.components,int(n.component)-1))}
}

// The rows kept, numbered; the others go.
@(private="file")
collect_compact :: proc(list:^[dynamic]$T,keep:[]int) {
    next:=0
    for &k,i in keep {
        if k==0 {continue}
        list[next]=list[i]
        next+=1
        k=next
    }
    resize(list,next)
}

// Takes away the rows nothing uses, and what refers to the rows after them
// follows: own looks and overrides of styles no node or override takes (named styles and row 0 stay), images (one with a name stays, for
// <img=...>), sets of animations and tracks of grids, and the widgets no
// instance is of.
records_collect :: proc(r:^Records) {
    c:=Collect{styles=make([]int,len(r.styles),context.temp_allocator),images=make([]int,len(r.images),context.temp_allocator),sets=make([]int,len(r.anim_sets),context.temp_allocator),
        grids=make([]int,len(r.grid_tracks),context.temp_allocator),components=make([]int,len(r.components),context.temp_allocator)}
    every:=~ui.Node_Fields{}
    for &n in r.nodes {collect_mark(&c,&n,every)}
    for &component,i in r.components {if component.library {c.components[i]=1}}
    for &info in r.style_infos {if int(info.from)>0 && int(info.from)<=len(c.components) {c.components[info.from-1]=1}}
    for &o in r.overrides {collect_mark(&c,&o.values,o.fields)}
    if len(c.styles)>0 {c.styles[0]=1}
    for i in 0..<len(r.styles) {if records_style_named(r,i) {c.styles[i]=1}}
    for i in 0..<len(r.styles) {if base:=records_style_base(r,i);c.styles[i]>0 && base>=0 {c.styles[base]=1}}
    for &image,i in r.images {if image.name[0]!=0 {c.images[i]=1}}
    for i:=len(r.variants)-1;i>=0;i-=1 {
        if int(r.variants[i].style)>=len(c.styles) || c.styles[r.variants[i].style]==0 {ordered_remove(&r.variants,i)}
    }
    for i:=len(r.token_uses)-1;i>=0;i-=1 {
        if int(r.token_uses[i].style)>=len(c.styles) || c.styles[r.token_uses[i].style]==0 {ordered_remove(&r.token_uses,i)}
    }
    collect_compact(&r.styles,c.styles)
    collect_compact(&r.style_infos,c.styles)
    collect_compact(&r.images,c.images)
    collect_compact(&r.anim_sets,c.sets)
    collect_compact(&r.grid_tracks,c.grids)
    collect_compact(&r.components,c.components)
    for &v in r.variants {v.style=u16(c.styles[v.style]-1)}
    for &u in r.token_uses {u.style=u16(c.styles[u.style]-1)}
    for &info in r.style_infos {
        if info.base>0 && int(info.base)<=len(c.styles) {info.base=u16(c.styles[info.base-1])} else {info.base=0}
        if int(info.from)>0 && int(info.from)<=len(c.components) {info.from=u16(c.components[info.from-1])} else {info.from=0}
    }
    for &n in r.nodes {collect_move(&c,&n)}
    for &o in r.overrides {collect_move(&c,&o.values)}
}
