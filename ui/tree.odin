package ui

import "base:runtime"
import "core:hash"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// An interface as data: a flat array of nodes in pre-order (every node is
// followed by what it contains) with styles, images, texts and animations in
// arrays beside it. Nothing in it is a pointer, so the same bytes can be built
// in code or come from an asset. Nodes read and write the fields of a value
// described by a serial.Schema, matched by name_hash. Building a tree calls
// the same widget procedures as code does.

Node_Flag :: enum u8 {
    Localized,   // its text is a key of the texts of the game (Game_Source.texts): it shows what the key says in the language of now
    Draggable,   // the pointer drags it: Dragged, and Dropped on the node it is let go over
    Drop,        // takes what is let go over it
    Focus_First, // takes the focus when its tree takes input and nothing there has it, or when the page of a Switcher that had it gives way to its own
    Wrap_X,      // a container: the focus that leaves it by a side comes back by the other
    Wrap_Y,
    Skip,        // navigation passes over it
    Collapsed,   // it is not built and takes no room; with a Visible binding, what false does
    Invisible,   // it keeps its room but draws nothing and takes no input; with a Visible binding, what false does
    Multiline,   // a Field: its text keeps line breaks and wraps
    Password,    // a Field: shows a mark for each character
    Slot,        // a template: what its instance holds goes in this node, the last of the template
}
Node_Flags :: bit_set[Node_Flag;u16]

// How a Progress fills: Right grows from the left edge toward the right.
Progress_Fill :: enum u8 {Right,Left,Down,Up,Center,Radial}

// When a node plays the sounds of its style.
Sound_Cue :: enum u8 {
    Show,   // it appears
    Hide,
    Hover,  // the pointer comes over it
    Focus,  // navigation comes to it
    Press,  // it is clicked
    Change, // its value changes
}

Node_Style :: struct {
    text:Text_Style,
    fill,stroke:Color, // background of a Box or a control, bar of a Progress, tint of an Image; its edge
    track:Color,       // of a Progress or a Slider
    knob:Color,        // of a Slider
    mark:Color,        // the filled part of a Slider, the dot of a Radio, the tick of a Checkbox, the arrows of a Selector and a Number, the accent of a Dropdown, the bar of a held Button
    radius:[4]f32,     // of the corners: top left, top right, bottom right, bottom left
    fill2:Color,
    stroke_width:f32,
    shadow:bool,
    shadow_color:Color,
    shadow_blur:f32,
    shadow_offset:[2]f32,
    fill_mode:Progress_Fill,
    program:[TREE_NAME_CAPACITY]u8 `mirai:"text"`, // a ui program that colors the fill
    program_values:[4]f32,                         // the first parameters of that program
    sounds:[Sound_Cue]base.Asset_Id,
    transition:f32, // seconds its colors, its shadow and how it moves take to go from one state to the next
    layout_transition:f32, // seconds its rectangle takes to go to a new place or size the layout gives it
    move:[2]f32,    // drawn this far from where the layout put it; the layout and the pointer stay
    scale:f32,      // drawn this size around its center, as move; 0: 1
}
// How an image takes the rectangle of its node.
Image_Fit :: enum u8 {
    Stretch, // fills it
    Contain, // as large as fits, keeping its proportions
    Cover,   // fills it keeping its proportions, cut where it does not fit
    Center,  // at its own size, centered
}
Node_Image :: struct {
    name:u64,      // name_hash of what <img=name> of a Rich_Text names
    quad:Quad,
    border,border_uv:[4]f32,
    fit:Image_Fit,
    frames:[2]u16, // columns and rows of a sheet of sprites; 0: one
    size:[2]f32,   // of the part shown, in texels: what Contain, Cover and Center keep
}

Node :: struct {
    kind:Node_Kind,
    name:u64,         // name_hash: its identity, and what its events carry
    parent:i32,       // -1: a root
    subtree:i32,      // nodes inside it
    layout:Layout,
    float:Float,
    clip:bool,
    layer:Layer_Style,
    selected,disabled:bool,
    variant:u64,
    block:bool,       // takes the pointer
    style:u16,        // index in styles
    image:u16,        // index in images plus one; 0: none
    anims:u16,        // index in anim_sets plus one; 0: none
    text_offset,text_length:u32, // in strings
    tab:Name_Ref,     // of a node a Tabs holds: its name, in strings, which its tab shows when it has no text
    binds:[Binding]Name_Ref, // the fields it binds, by their names in strings
    fields:[TREE_TEXT_FIELDS]Node_Field_Ref, // what the names in braces of its text show
    index:u16,        // what a Switcher or a Tabs builds when it binds no value
    count:u16,        // elements a List builds when it binds no array; of one that binds a table, the most rows it shows (TREE_TABLE_ROWS when 0)
    choice:u16,       // what a Radio writes, and a Button that binds a value when it is clicked
    limit:u16,        // bytes a Field takes; 0: as many as its value holds
    delay:f32,        // seconds a Tooltip waits; 0: TOOLTIP_DELAY
    tag,accepts:u64,  // name_hash of what a Draggable carries and of what a Drop takes; 0: anything
    ghost:u64,        // name of the node built under the pointer while it is dragged; 0: a copy of it
    particle:base.Asset_Id, // what a Particles plays
    draw:u64,         // name_hash of the procedure of the game that draws a Draw
    flags:Node_Flags,
    action:u64,       // name_hash of the input action a Button takes or a Prompt shows
    action_name:Name_Ref, // that name, in strings
    hold:f32,         // seconds the action or the pointer holds a Button before it clicks
    range:[3]f32,     // of a Slider or a Number: least, most and step (0: any)
    nav:[4]u64,       // names of the nodes the focus goes to up, right, down and left
    order:i16,        // where Tab reaches it among the others; 0: in the order of the tree
}

Widget_Tree :: struct {
    nodes:[]Node,node_count:int,
    styles:[]Node_Style,style_count:int,
    variants:[]Style_Variant,variant_count:int, // by style and, within one, in the order style_resolve applies them
    style_rules:[]Style_Rules, // of each style: its rules in variants
    images:[]Node_Image,image_count:int,
    anim_sets:[]Anim_Set,anim_set_count:int,
    strings:[]u8,string_length:int,
    anims:Anim_Library,
    grid_tracks:[]Grid_Tracks,grid_track_count:int,
    anim_names:[]u64,  // name_hash of each animation, by Anim minus one: what tree_play finds
    programs:[]u32,    // of each style: the ui program of its fill; 0: none
    pages_focused:bool, // tree_pages_focus went over its nodes: the first build does it
    allocator:runtime.Allocator,
}
// The rules of a style, in Widget_Tree.variants.
Style_Rules :: struct {first,count:u32}
Widget_Tree_Desc :: struct {
    allocator:runtime.Allocator, // context.allocator when unset
    max_nodes,max_styles,max_images,max_anim_sets,max_strings:int, // 256, 64, 64, 32 and 4096 when 0
    max_variants:int,
    max_grid_tracks:int,  // 8 when 0
    anims:Anim_Library_Desc,
}

tree_init :: proc(tree:^Widget_Tree,desc:Widget_Tree_Desc={}) -> bool {
    a:=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    tree^={allocator=a}
    e:[7]runtime.Allocator_Error
    tree.nodes,e[0]=make([]Node,desc.max_nodes if desc.max_nodes>0 else 256,a)
    tree.styles,e[1]=make([]Node_Style,desc.max_styles if desc.max_styles>0 else 64,a)
    tree.images,e[2]=make([]Node_Image,desc.max_images if desc.max_images>0 else 64,a)
    tree.anim_sets,e[3]=make([]Anim_Set,desc.max_anim_sets if desc.max_anim_sets>0 else 32,a)
    tree.strings,e[4]=make([]u8,desc.max_strings if desc.max_strings>0 else 4096,a)
    tree.variants,e[5]=make([]Style_Variant,desc.max_variants if desc.max_variants>0 else 64,a)
    tree.grid_tracks,e[6]=make([]Grid_Tracks,desc.max_grid_tracks if desc.max_grid_tracks>0 else 8,a)
    anims:=desc.anims
    if anims.allocator.procedure==nil {anims.allocator=a}
    e2:[3]runtime.Allocator_Error
    tree.anim_names,e2[0]=make([]u64,anims.max_anims if anims.max_anims>0 else 128,a)
    tree.programs,e2[1]=make([]u32,len(tree.styles),a)
    tree.style_rules,e2[2]=make([]Style_Rules,len(tree.styles),a)
    if e!={} || e2!={} || !anim_library_init(&tree.anims,anims) {tree_destroy(tree);return false}
    return true
}
tree_destroy :: proc(tree:^Widget_Tree) {
    a:=tree.allocator
    delete(tree.nodes,a);delete(tree.styles,a);delete(tree.variants,a);delete(tree.images,a);delete(tree.anim_sets,a);delete(tree.strings,a);delete(tree.grid_tracks,a)
    delete(tree.anim_names,a);delete(tree.programs,a);delete(tree.style_rules,a)
    if tree.anims.allocator.procedure!=nil {anim_library_destroy(&tree.anims)}
    tree^={}
}

// Each returns the reference a Node_Desc takes, or ok false when the tree is full.
tree_style :: proc(tree:^Widget_Tree,style:Node_Style) -> (index:u16,ok:bool) {
    if tree.style_count>=len(tree.styles) {return 0,false}
    tree.styles[tree.style_count]=style;tree.style_count+=1
    return u16(tree.style_count-1),true
}
tree_style_variant :: proc(tree:^Widget_Tree,variant:Style_Variant) -> bool {
    tree_rule_add(tree,variant) or_return
    tree_rules_order(tree)
    return true
}
@(private)
tree_rule_add :: proc(tree:^Widget_Tree,variant:Style_Variant) -> bool {
    if tree.variant_count>=len(tree.variants) || int(variant.style)>=len(tree.style_rules) {return false}
    tree.variants[tree.variant_count]=variant;tree.variant_count+=1
    return true
}
// Puts the rules by style and, within one, in the order style_resolve applies
// them, keeping the order of the table among those of one place.
@(private)
tree_rules_order :: proc(tree:^Widget_Tree) {
    rules:=tree.variants[:tree.variant_count]
    slice.stable_sort_by(rules,proc(a,b:Style_Variant) -> bool {
        return a.style<b.style || a.style==b.style && style_rule_order(a.states,a.variant)<style_rule_order(b.states,b.variant)
    })
    for &r in tree.style_rules {r={}}
    for &rule,i in rules {
        r:=&tree.style_rules[rule.style]
        if r.count==0 {r.first=u32(i)}
        r.count+=1
    }
}
// The rules of a style, in the order style_resolve applies them.
tree_style_rules :: proc "contextless" (tree:^Widget_Tree,style:u16) -> []Style_Variant {
    if int(style)>=len(tree.style_rules) {return nil}
    r:=tree.style_rules[style]
    return tree.variants[r.first:][:r.count]
}
tree_image :: proc(tree:^Widget_Tree,image:Node_Image) -> (reference:u16,ok:bool) {
    if tree.image_count>=len(tree.images) {return 0,false}
    tree.images[tree.image_count]=image;tree.image_count+=1
    return u16(tree.image_count),true
}
tree_anim_set :: proc(tree:^Widget_Tree,set:Anim_Set) -> (reference:u16,ok:bool) {
    if tree.anim_set_count>=len(tree.anim_sets) {return 0,false}
    tree.anim_sets[tree.anim_set_count]=set;tree.anim_set_count+=1
    return u16(tree.anim_set_count),true
}

Node_Desc :: struct {
    kind:Node_Kind,
    name:string,
    layout:Layout,
    float:Float,
    clip,block:bool,
    layer:Layer_Style,
    selected,disabled:bool,
    variant:string,
    component:u16,
    component_fields:Node_Fields,
    data:string, // a Component: the path its widget reads with @ (records only)
    style:u16,
    image:u16,
    anims:u16,
    text:string,
    fields:[TREE_TEXT_FIELDS]Node_Field_Desc, // the names in braces of its text and the paths they show
    bind_text,bind_value,bind_visible,bind_selected,bind_disabled:string, // names of fields of the bound value
    bind_items:string, // of a List: an array; the nodes it holds bind fields of its elements
    bind_image,bind_tint,bind_variant:string,
    index,count,choice,limit:u16,
    delay:f32,
    tag,accepts,ghost:string,
    particle:base.Asset_Id,
    draw:string,
    flags:Node_Flags,
    action:string,
    hold:f32,
    range:[3]f32,
    nav:[4]string,
    order:i16,
}

// The bytes of strings a node takes: its text, the names it binds and, held
// by a Tabs, its own.
@(private)
tree_node_strings :: proc "contextless" (desc:^Node_Desc,tab:bool) -> int {
    fields:=len(desc.name) if tab else 0
    for f in desc.fields {fields+=len(f.path)}
    return len(desc.text)+len(desc.bind_text)+len(desc.bind_value)+len(desc.bind_visible)+len(desc.bind_selected)+len(desc.bind_disabled)+
        len(desc.bind_items)+len(desc.bind_image)+len(desc.bind_tint)+len(desc.bind_variant)+len(desc.action)+fields
}

// The path a name in braces of the text of a node shows; empty for none.
tree_field_path :: proc(tree:^Widget_Tree,node:^Node,name:string) -> string {
    named:=base.name_hash(name)
    for f in node.fields {
        if f.name==named && int(f.path.offset+f.path.length)<=len(tree.strings) {return string(tree.strings[f.path.offset:][:f.path.length])}
    }
    return ""
}

// The name of the input action a node takes or shows; empty for none.
tree_action_name :: proc(tree:^Widget_Tree,node:^Node) -> string {
    ref:=node.action_name
    if ref.length==0 || int(ref.offset+ref.length)>len(tree.strings) {return ""}
    return string(tree.strings[ref.offset:][:ref.length])
}

// Adds a node inside parent (-1: at the root). Nodes go in pre-order: parent
// is the node added last or one of the containers that hold it. Returns its
// index, or -1 when the tree is full or the order is broken.
tree_node :: proc(tree:^Widget_Tree,parent:i32,desc:Node_Desc) -> i32 {
    desc:=desc
    if desc.kind==.Component {return -1}
    count:=i32(tree.node_count)
    if parent<-1 || parent>=count {return -1}
    tab:=parent>=0 && tree.nodes[parent].kind==.Tabs
    if int(count)>=len(tree.nodes) || tree.string_length+tree_node_strings(&desc,tab)>len(tree.strings) {return -1}
    if parent>=0 && (!node_kind_holds(tree.nodes[parent].kind) || parent+tree.nodes[parent].subtree+1!=count) {return -1}
    hashed :: proc(name:string) -> u64 {return base.name_hash(name) if name!="" else 0}
    keep :: proc(tree:^Widget_Tree,text:string) -> Name_Ref {
        ref:=Name_Ref{u32(tree.string_length),u32(len(text))}
        copy(tree.strings[tree.string_length:],text)
        tree.string_length+=len(text)
        return ref
    }
    node:=Node{kind=desc.kind,name=hashed(desc.name),parent=parent,layout=desc.layout,float=desc.float,clip=desc.clip,block=desc.block,
        style=desc.style,image=desc.image,anims=desc.anims,layer=desc.layer,variant=style_variant(desc.variant),selected=desc.selected,disabled=desc.disabled,
        index=desc.index,count=desc.count,choice=desc.choice,limit=desc.limit,delay=desc.delay,tag=hashed(desc.tag),accepts=hashed(desc.accepts),ghost=hashed(desc.ghost),particle=desc.particle,draw=hashed(desc.draw),
        flags=desc.flags,action=hashed(desc.action),hold=desc.hold,range=desc.range,
        nav={hashed(desc.nav[0]),hashed(desc.nav[1]),hashed(desc.nav[2]),hashed(desc.nav[3])},order=desc.order}
    text:=keep(tree,desc.text)
    node.text_offset,node.text_length=text.offset,text.length
    names:=[Binding]string{.Text=desc.bind_text,.Value=desc.bind_value,.Visible=desc.bind_visible,.Selected=desc.bind_selected,.Disabled=desc.bind_disabled,
        .Items=desc.bind_items,.Image=desc.bind_image,.Tint=desc.bind_tint,.Variant=desc.bind_variant}
    for name,binding in names {node.binds[binding]=keep(tree,name)}
    for f,i in desc.fields {
        if f.name=="" {continue}
        node.fields[i]={base.name_hash(f.name),keep(tree,f.path)}
    }
    node.action_name=keep(tree,desc.action)
    if tab {node.tab=keep(tree,desc.name)}
    tree.nodes[count]=node;tree.node_count+=1
    for ancestor:=parent;ancestor>=0;ancestor=tree.nodes[ancestor].parent {tree.nodes[ancestor].subtree+=1}
    return count
}

TREE_SLOTS :: 1<<16 // states one instance keeps: a node inside lists has one per element of each
TREE_BAR :: 32      // buttons with an action an Action_Bar shows; the others are counted in Stats.dropped_tree
TREE_TABLE_ROWS :: 256 // rows of a table a List shows when its count does not say
TREE_LIST_PROBE :: 32  // elements a List that builds only those in sight builds while it does not know their size
TREE_TAB_PADDING :: [4]f32{10,4,10,4} // around the text of a tab of a Tabs

// What a node was in the last build, for the events and sounds of its changes.
@(private)
Slot :: struct {
    shown,hovered,focused,latched:bool,
    armed:bool,         // a Button saw its action up: the press that showed it does not click it
    page:i32,           // 1 + the node a Switcher built
    page_focused:bool,  // the focus was on a widget of that node
    held:f32,           // seconds its action or the pointer has held a Button
    tip:f32,            // seconds the pointer or the focus has been in it: what its Tooltip waits
    played:Anim_Player, // what tree_play started
    clicked:bool,       // a Button clicked in the last build: what its set plays as clicked
    pressing:bool,      // the pointer went down on it and is still down
    over:bool,          // something dragged that it accepts is over it
    look:Style_Transition, // the colors it shows on the way from one state to another
    plain:Slot_Plain,   // the states and variant it was last built in, when no rule of its style held
    first,built:i32,    // a List that builds what is in sight: the elements it built
}
// What a node was built in when it showed its style as it is: while it stays,
// no rule is looked at.
@(private)
Slot_Plain :: struct {
    variant:u64,
    rules:u32, // those its style had
    states:Style_States,
    seen:bool,
    _:u16,
}
// A button of the tree that an action clicks, for an Action_Bar: its text as
// a node keeps it, longer ones cut and counted in Stats.dropped_tree.
@(private)
Bar_Entry :: struct {
    action:u64,
    text:[TREE_TEXT_KEPT]u8,
    length:u16,
}

// What one use of a tree owns: where its nodes read their values and what
// each of them is playing. A node inside a List has a slot per element of
// the list, and per element of each list around it.
Tree_Instance :: struct {
    bounds:[]Node_Bound,
    items:[]Node_Items,       // of each List
    templates:[]Template,     // of each node: the parts of its text, when it has fields in braces
    parts:[dynamic]Template_Part,
    scopes:[]Bind_Scope,      // of each node: where the paths of the nodes it holds start
    schema:^serial.Schema,
    host:^Bind_Host,          // while the plan is made
    regions:[dynamic]Bind_Region,
    ranges:[dynamic]Bind_Range,
    values:[]u8,              // the copy of what the tree reads of the game, packed: what it is built with
    sources:[]rawptr,         // by region, while the copy is refreshed: where its bytes are in the game
    dirty:[]bool,             // by range: it changed since the last build
    dirty_any:bool,
    failure:Bind_Failure,     // why the tree was not taken
    replan:bool,              // a localized text names a path the plan does not read: make the instance again
    language:u64,             // Game_Source.language the localized texts were read in
    texts_generation:u32,     // of Game_Source.texts then
    texts:[]string,           // of each node: the text it shows by itself, in that language
    slots:[]u32,              // of each node: its first slot
    states:[]Anim_State,      // by slot
    scrolls:[][2]f32,         // by slot: how far a Scroll or a List that clips moved its content, left and up
    slot:[]Slot,              // by slot
    kept:[]Kept_Text,         // by slot: the text it formatted, while values do not change
    kept_bytes:[]u8,
    bar,bar_next:[TREE_BAR]Bar_Entry,
    bar_count,bar_next_count:int,
    allocator:runtime.Allocator,
}

// The text a node shows by itself: its own, or for a Localized one what its
// key says in a language (base.text); a key the texts lack shows as it is.
tree_text :: proc "contextless" (tree:^Widget_Tree,node:^Node,texts:^base.Texts,language:u64) -> string {
    own:=string(tree.strings[node.text_offset:][:node.text_length])
    if .Localized not_in node.flags {return own}
    return base.text(texts,own,language) or_else own
}

// Resolves the paths of the tree against what host gives and makes the plan
// of the copy (tree_bind); what a List holds binds the elements of its
// array. texts and language: what the localized nodes read their keys in
// (Game_Source.texts and Game_Source.language). A transaction: fails, leaving nothing but failure, when a node
// names a path the game does not have or one it cannot show, or the lists
// need more than TREE_SLOTS slots. Without a host a path binds nothing.
tree_instance_init :: proc(instance:^Tree_Instance,tree:^Widget_Tree,host:^Bind_Host,texts:^base.Texts=nil,language:u64=0,allocator:=context.allocator) -> bool {
    instance^={allocator=allocator,host=host,failure={node=-1},language=language,texts_generation=texts.generation if texts!=nil else 0}
    if host!=nil {instance.schema=host.schema}
    count:=tree.node_count
    e:[6]runtime.Allocator_Error
    instance.texts,e[5]=make([]string,count,allocator)
    instance.bounds,e[0]=make([]Node_Bound,count,allocator)
    instance.items,e[1]=make([]Node_Items,count,allocator)
    instance.slots,e[2]=make([]u32,count,allocator)
    instance.templates,e[3]=make([]Template,count,allocator)
    instance.scopes,e[4]=make([]Bind_Scope,count,allocator)
    instance.parts=make([dynamic]Template_Part,allocator)
    instance.regions=make([dynamic]Bind_Region,allocator)
    instance.ranges=make([dynamic]Bind_Range,allocator)
    ok:=e=={}
    if !ok {instance.failure.capacity=true}
    copies:=make([]int,count,context.temp_allocator) // slots of a node: the product of the elements of the lists around it
    kept:=make([]bool,count,context.temp_allocator)  // the node formats a text its instance keeps
    slots,kept_slots:=0,0
    for &node,i in tree.nodes[:count] {
        if !ok {break}
        scope,copy:=Bind_Scope{},1
        if parent:=int(node.parent);parent>=0 {
            scope,copy=instance.scopes[parent],copies[parent]
            if tree.nodes[parent].kind==.List {copy*=max(int(instance.items[parent].count),1)}
        }
        instance.scopes[i],copies[i]=scope,copy
        instance.slots[i]=u32(slots)
        slots+=copy
        if slots>TREE_SLOTS {ok=false;instance.failure={node=i,capacity=true};break}
        name :: proc(tree:^Widget_Tree,node:^Node,binding:Binding) -> string {return tree_binding(tree,node,binding)}
        if node.kind==.List {
            if path:=name(tree,&node,.Items);path!="" {
                instance.items[i],instance.scopes[i],ok=tree_bind_items(instance,scope,path,u32(node.count) if node.count>0 else TREE_TABLE_ROWS)
                if !ok {instance.failure={node=i,binding=.Items};break}
            } else {instance.items[i].count=u32(node.count)}
        }
        b:=&instance.bounds[i]
        o:[Binding]bool
        o[.Items]=true
        b.text,o[.Text]=tree_bind_field(instance,scope,name(tree,&node,.Text),.Shown)
        b.value,o[.Value]=tree_bind_field(instance,scope,name(tree,&node,.Value),tree_value_want(node.kind))
        if b.value.text && node.kind!=.Switcher && strings.index_byte(string(tree.strings[node.text_offset:][:node.text_length]),'=')<0 {o[.Value]=false}
        b.visible,o[.Visible]=tree_bind_field(instance,scope,name(tree,&node,.Visible),.Number)
        b.selected,o[.Selected]=tree_bind_field(instance,scope,name(tree,&node,.Selected),.Number)
        b.disabled,o[.Disabled]=tree_bind_field(instance,scope,name(tree,&node,.Disabled),.Number)
        b.image,o[.Image]=tree_bind_field(instance,scope,name(tree,&node,.Image),.Asset)
        b.tint,o[.Tint]=tree_bind_field(instance,scope,name(tree,&node,.Tint),.Color)
        b.variant,o[.Variant]=tree_bind_field(instance,scope,name(tree,&node,.Variant),.Name)
        if node.kind==.Selector || node.kind==.Dropdown || node.kind==.Tabs {b.options,o[.Items]=tree_bind_options(instance,scope,name(tree,&node,.Items))}
        for bound,binding in o {
            if !bound {ok=false;instance.failure={node=i,binding=binding};break}
        }
        if !ok {break}
        // A localized text is read in the language of now, and its paths with it.
        instance.texts[i]=tree_text(tree,&node,texts,language)
        first:=len(instance.parts)
        template,parsed:=tree_template_parse(&instance.parts,instance.texts[i],instance,scope,tree,&node)
        if !parsed {ok=false;instance.failure={node=i,binding=.Text,template=true};break}
        if template {instance.templates[i]={u32(first),u32(len(instance.parts)-first),true}}
        kept[i]=b.text.bound || instance.templates[i].template || .Localized in node.flags
        if kept[i] {kept_slots+=copy}
    }
    if ok && host!=nil {
        ok=bind_plan(instance)
        if !ok {instance.failure.capacity=true}
    }
    instance.host=nil
    if ok {
        e2:[5]runtime.Allocator_Error
        instance.states,e2[0]=make([]Anim_State,slots,allocator)
        instance.scrolls,e2[1]=make([][2]f32,slots,allocator)
        instance.slot,e2[2]=make([]Slot,slots,allocator)
        instance.kept,e2[3]=make([]Kept_Text,slots,allocator)
        instance.kept_bytes,e2[4]=make([]u8,kept_slots*TREE_TEXT_KEPT,allocator)
        ok=e2=={}
        if !ok {instance.failure.capacity=true}
        at:=0
        for i in 0..<count {
            if !ok || !kept[i] {continue}
            first:=int(instance.slots[i])
            for s in first..<first+copies[i] {instance.kept[s].offset=u32(at);at+=TREE_TEXT_KEPT}
        }
    }
    if !ok {
        failure:=instance.failure
        tree_instance_destroy(instance)
        instance.failure=failure
    }
    return ok
}
tree_instance_destroy :: proc(instance:^Tree_Instance) {
    a:=instance.allocator
    delete(instance.bounds,a);delete(instance.items,a);delete(instance.slots,a);delete(instance.states,a);delete(instance.scrolls,a)
    delete(instance.templates,a);delete(instance.scopes,a);delete(instance.parts);delete(instance.slot,a);delete(instance.kept,a);delete(instance.kept_bytes,a);delete(instance.texts,a)
    delete(instance.regions);delete(instance.ranges);delete(instance.values,a);delete(instance.sources,a);delete(instance.dirty,a)
    instance^={}
}

// The texts of the localized nodes, and their templates, read again in the
// language and from the texts of now. A path the plan does not read asks for
// the instance again (replan).
@(private)
tree_instance_texts :: proc(ctx:^Context,tree:^Widget_Tree,instance:^Tree_Instance) {
    generation:=ctx.game.texts.generation if ctx.game.texts!=nil else 0
    if instance.language==ctx.game.language && instance.texts_generation==generation || len(instance.texts)<tree.node_count {return}
    instance.language,instance.texts_generation=ctx.game.language,generation
    for &kept in instance.kept {kept.valid=false}
    for &node,i in tree.nodes[:tree.node_count] {
        if .Localized not_in node.flags {continue}
        instance.templates[i]={}
        instance.texts[i]=tree_text(tree,&node,ctx.game.texts,instance.language)
        found:=instance.texts[i]
        first:=len(instance.parts)
        scope:=instance.scopes[node.parent] if node.parent>=0 else Bind_Scope{}
        template,parsed:=tree_template_parse(&instance.parts,found,instance,scope,tree,&node)
        if template && parsed {instance.templates[i]={u32(first),u32(len(instance.parts)-first),true}} else {base.truncate(&instance.parts,first)}
        if !parsed {instance.replan=true}
    }
}

Tree_Event_Kind :: enum u8 {
    Clicked,   // a Button, by the pointer, by navigation or by its action
    Changed,   // a Checkbox, Slider, Number, Field, Selector, Dropdown or Radio wrote its bound value, or a Button its choice
    Submitted, // Enter in a Field
    Hovered,   // the pointer came over the node
    Unhovered,
    Focused,   // navigation came to it
    Unfocused,
    Dragged,   // the pointer started dragging it
    Dropped,   // what was dragged was let go over it: from names it, if its tag is what the node accepts
    Finished,  // an animation tree_play started ended: from names it
    Right_Clicked,
    Double_Clicked,
    Pressed,   // the pointer went down on it
    Released,  // the pointer that went down on it went up
    Drag_Entered, // something dragged that a Drop accepts came over it
    Drag_Left,
    Opened,    // a Popup, a Modal or a Context_Menu opened
    Closed,
    Link,      // a <link=name> of a Rich_Text was clicked: from names it
}
Tree_Event :: struct {
    name:u64,  // name_hash of the node
    node:i32,
    kind:Tree_Event_Kind,
    on:bool,   // Changed: what a checkbox holds now
    item:i32,  // the element of the List the node is in; -1: in none
    value:f64, // Changed: the number written, or the index of the option chosen (of one written Label=Value: its value)
    from:u64,  // Dropped: the name of the node dragged; Finished: of the animation
    from_item:i32,
    from_owner:u64, // Dropped: Context.owner while the tree of the node dragged was built
    text:[TREE_EVENT_TEXT]u8, // Changed and Submitted by a Field: what it holds; Changed by an option of a text field: its value
    rect:Rect, // where the node was laid out in the last frame, in layout units of its surface; zero before
}
TREE_EVENT_TEXT :: 256

// How a tree is built in one frame.
Tree_Build_Desc :: struct {
    events:[]Tree_Event, // what its widgets did; those that do not fit are counted
    hidden:bool,         // it is going away: it plays what its nodes play when they hide
    passive:bool,        // it takes no keys, no actions and no focus: a HUD, or what is under the screen on top
    variant:u64,         // style_variant of what its nodes take when they choose none
    changed:bool,        // values changed that tree_values_refresh did not copy: every text that binds them is made again
    track:bool,          // every container keeps its rectangle, as leaves do: for a tool that finds nodes under the pointer
    shown:i32,           // index+1 of a node a tool shows in shown_states whatever the pointer does; 0: none
    shown_states:Style_States,
    // An element whose rectangle (area_rect, in layout units) the Surface and
    // Safe floats of the nodes hang from instead of the surface: the part of
    // the window of a player. 0: the surface.
    area:Id,
    area_rect:Rect,
}

Tree_Build_Result :: struct {
    count,dropped:int, // events written, and those that did not fit
    present:bool,      // something was built: a tree that hides is gone once what its nodes play as they hide ends
    animating:bool,    // something plays, is held, dragged or edited: the next frame differs even with the same values
}

@(private)
tree_node_id :: proc(ctx:^Context,node:^Node,index:int) -> Id {
    if node.name==0 {return id(ctx,"node",index+1)}
    return tree_name_id(ctx,node.name)
}
@(private)
tree_name_id :: proc(ctx:^Context,name:u64) -> Id {
    name:=name
    seed:=ctx.id_stack[ctx.id_depth-1] if ctx.id_depth>0 else ID_SEED
    value:=hash.fnv32a(mem.ptr_to_bytes(&name),seed)
    return Id(value) if value!=0 else Id(1)
}
@(private)
tree_box :: proc(node:^Node,style:^Node_Style,id:Id) -> Box {
    return {id=id,layout=node.layout,float=node.float,clip_x=node.clip,clip_y=node.clip,fill=style.fill,fill2=style.fill2,stroke=style.stroke,corners=style.radius,stroke_width=style.stroke_width if style.stroke_width>0 || style.stroke[3]==0 else 1,shadow=style.shadow,shadow_color=style.shadow_color,shadow_blur=style.shadow_blur,shadow_offset=style.shadow_offset,layer=node.layer,block=node.block}
}

@(private)
Tree_Build :: struct {
    ctx:^Context,
    element:Id, // of the node being built: what its events say where it is
    tree:^Widget_Tree,
    instance:^Tree_Instance,
    desc:Tree_Build_Desc,
    count,dropped:int,
    floor:int, // the layer the tree is built in
    built:int, // nodes built
    turned:bool, // a Switcher left the page with the focus for this one: its Focus_First takes it
    animating:bool,
    ghost:int, // the node built under the pointer for a drag, whatever it shows; -1: none
    tracks,tracks_end:int, // the rows of the grid tracks of the frame its own start after, and where they end
}

// Builds the widgets of a tree where the call is made. The layer of a node
// that floats counts from the layer the tree is built in.
tree_build :: proc(ctx:^Context,tree:^Widget_Tree,instance:^Tree_Instance,desc:Tree_Build_Desc) -> Tree_Build_Result {
    b:=Tree_Build{ctx=ctx,tree=tree,instance=instance,desc=desc,floor=int(ctx.layer),ghost=-1}
    tree_instance_texts(ctx,tree,instance)
    tree_kept_invalidate(tree,instance,desc.changed)
    b.tracks=ctx.layout.track_count
    for g in tree.grid_tracks[:tree.grid_track_count] {if grid_tracks_add(ctx,g)==0 {break}}
    b.tracks_end=ctx.layout.track_count
    instance.bar_next_count=0
    if !tree.pages_focused {
        tree_pages_focus(tree.nodes[:tree.node_count])
        tree.pages_focused=true
    }
    if desc.passive {ctx.unfocusable+=1}
    for index:=0;index<tree.node_count; {index=tree_build_node(ctx,&b,index,raw_data(instance.values),0,-1)}
    if desc.passive {ctx.unfocusable-=1}
    // An Action_Bar showed the buttons the last build found: when this one
    // found others, or other texts (another language), the next frame shows them.
    bar_changed:=instance.bar_next_count!=instance.bar_count
    for i in 0..<instance.bar_next_count {
        if bar_changed {break}
        was,found:=&instance.bar[i],&instance.bar_next[i]
        bar_changed=was.action!=found.action || string(was.text[:was.length])!=string(found.text[:found.length])
    }
    if bar_changed {b.animating=true}
    instance.bar,instance.bar_count=instance.bar_next,instance.bar_next_count
    if ctx.drag.id!=0 && ctx.drag.owner==ctx.owner {b.animating=true}
    return {count=b.count,dropped=b.dropped,present=b.built>0,animating=b.animating}
}

// The texts an instance keeps that read what changed since the last build
// are made again: all of them with every.
@(private)
tree_kept_invalidate :: proc(tree:^Widget_Tree,instance:^Tree_Instance,every:bool) {
    defer if instance.dirty_any {
        for &d in instance.dirty {d=false}
        instance.dirty_any=false
    }
    if every {
        for &kept in instance.kept {kept.valid=false}
        return
    }
    if !instance.dirty_any || len(instance.slots)<tree.node_count {return}
    for i in 0..<tree.node_count {
        dirty:=bound_dirty(instance,instance.bounds[i].text)
        if t:=instance.templates[i];!dirty && t.template {
            for part in instance.parts[t.first:][:t.count] {
                if dirty=bound_dirty(instance,part.bound);dirty {break}
            }
        }
        if !dirty {continue}
        end:=int(instance.slots[i+1]) if i+1<tree.node_count else len(instance.kept)
        for &kept in instance.kept[int(instance.slots[i]):end] {kept.valid=false}
    }
}

// Plays the animation of the tree called anim (name_hash) on the node called
// node, instead of what its set plays, until it ends: then the tree reports
// Finished. item: for a node inside lists, which of its copies, counted as
// the elements of its list (of the lists inside lists, the outer ones first);
// -1 or 0: the first. False when the tree has no such node or animation.
tree_play :: proc(tree:^Widget_Tree,instance:^Tree_Instance,node,anim:u64,item:i32=-1) -> bool {
    played:Anim
    for name,i in tree.anim_names[:min(tree.anims.node_count,len(tree.anim_names))] {
        if name==anim && name!=0 {played=Anim(i+1);break}
    }
    if played==0 {return false}
    for &n,i in tree.nodes[:tree.node_count] {
        if n.name!=node {continue}
        first:=int(instance.slots[i])
        // The slots of a node follow one another, one per copy, up to those of the next node.
        end:=int(instance.slots[i+1]) if i+1<tree.node_count else len(instance.slot)
        slot:=first+max(int(item),0)
        if slot>=end {return false}
        anim_play(&instance.slot[slot].played,played)
        return true
    }
    return false
}

@(private)
tree_emit :: proc(b:^Tree_Build,event:Tree_Event) {
    if b.count>=len(b.desc.events) {b.dropped+=1;return}
    b.desc.events[b.count]=event
    if b.ctx!=nil && b.element!=0 {b.desc.events[b.count].rect,_=widget_rect(b.ctx,b.element)}
    b.count+=1
}

@(private)
tree_sound :: proc(ctx:^Context,style:^Node_Style,cue:Sound_Cue) {
    if id:=style.sounds[cue];id!={} && ctx.game.sound!=nil {ctx.game.sound(ctx.game.user,id)}
}

// The text a node shows: its own or what its key says in the language of
// now, its bound field or its template, kept while the values do not change.
@(private)
tree_node_text :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,slot:int,values:rawptr) -> string {
    instance:=b.instance
    bound:=&instance.bounds[index]
    template:=instance.templates[index]
    if !bound.text.bound && !template.template {return instance.texts[index]}
    kept:=&instance.kept[slot]
    if kept.valid {return string(instance.kept_bytes[kept.offset:][:kept.length])}
    made:string
    if template.template {made=template_text(ctx,values,instance.parts[template.first:][:template.count])} else {made=bound_text(ctx,values,bound.text)}
    if len(made)<=TREE_TEXT_KEPT && slot<len(instance.kept) && int(kept.offset)+TREE_TEXT_KEPT<=len(instance.kept_bytes) {
        copy(instance.kept_bytes[kept.offset:],made)
        kept.length,kept.valid=u16(len(made)),true
        return string(instance.kept_bytes[kept.offset:][:kept.length])
    }
    return made
}

// Builds the node at index with what it holds and returns the index past
// them. copy: which of the slots of the node, from the elements of the lists
// around it; item: the element of the innermost one.
@(private)
tree_build_node :: proc(ctx:^Context,b:^Tree_Build,index:int,values:rawptr,copy:int,item:i32) -> int {
    tree,instance:=b.tree,b.instance
    node:=&tree.nodes[index]
    next:=index+int(node.subtree)+1
    bound:=instance.bounds[index]
    slot:=int(instance.slots[index])+copy
    state:=&instance.slot[slot]
    node_id:=tree_node_id(ctx,node,index)
    outer:=b.element
    b.element=node_id
    defer b.element=outer
    shown:=bound_number(values,bound.visible)!=0 if bound.visible.bound else node.flags&{.Collapsed,.Invisible}=={}
    // The ghost of a drag is built as it is: it can be a node the tree hides.
    if index==b.ghost {shown=true}
    visible:=!b.desc.hidden && shown
    // Hidden keeps its room: it is built, but draws nothing and takes no input.
    room:=!b.desc.hidden && !shown && .Invisible in node.flags
    // A Text takes no input: it is hovered and pressed while the pointer is over it, as its box.
    under:=node.kind==.Text && !b.desc.passive && widget_under(ctx,node_id)
    hovered:=ctx.hot==node_id || under
    // The focus of navigation, or a field being typed.
    focused:=ctx.focus==node_id && (ctx.focus_ring || ctx.edit.id==node_id)
    selected:=bound_number(values,bound.selected)!=0 if bound.selected.bound else node.selected
    base_style:=tree.styles[node.style] if int(node.style)<tree.style_count else Node_Style{}
    if visible!=state.shown {
        tree_sound(ctx,&base_style,.Show if visible else .Hide)
        state.shown=visible
    }
    clicked:=state.clicked
    state.clicked=false
    animated:=false
    value:Anim_Value // what its animation gives it, while playing
    playing:=false
    if state.played.anim!=0 {
        if !anim_update(&tree.anims,&state.played,ctx.input.dt) {
            tree_emit(b,{name=node.name,node=i32(index),kind=.Finished,item=item,from=tree.anim_names[state.played.anim-1]})
            state.played={}
        } else {b.animating=true}
        if state.played.anim!=0 && visible {
            value,playing=state.played.value,true
            animated=animated_begin(ctx,node_id,value)
        }
    }
    if !playing && node.anims!=0 && int(node.anims)<=tree.anim_set_count {
        anim:=&instance.states[slot]
        set:=tree.anim_sets[node.anims-1]
        flags:=Anim_Flags{shown=visible,clicked=clicked}
        present:=anim_react(&tree.anims,anim,set,flags,ctx.input.dt)
        if !present && !room {return next}
        if anim.playing {b.animating=true}
        if present {
            value,playing=anim.value,true
            animated=animated_begin(ctx,node_id,value)
        }
    } else if !playing && !visible && !room {return next}
    defer if animated {animated_end(ctx)}
    unseen:=room && !animated
    if unseen {ctx.invisible+=1}
    defer if unseen {ctx.invisible-=1}
    b.built+=1
    event :: proc(b:^Tree_Build,node:^Node,index:int,item:i32,kind:Tree_Event_Kind) {tree_emit(b,{name=node.name,node=i32(index),kind=kind,item=item})}
    if hovered!=state.hovered {
        event(b,node,index,item,.Hovered if hovered else .Unhovered)
        if hovered {tree_sound(ctx,&base_style,.Hover)}
        state.hovered=hovered
    }
    if focused!=state.focused {
        event(b,node,index,item,.Focused if focused else .Unfocused)
        if focused {tree_sound(ctx,&base_style,.Focus)}
        state.focused=focused
    }
    // The buttons of the pointer on it, before what it builds takes the press.
    in_:=&ctx.input
    if hovered && .Left in in_.pressed && !ctx.press_used {
        event(b,node,index,item,.Pressed)
        if in_.clicks>=2 {event(b,node,index,item,.Double_Clicked)}
        state.pressing=true
    } else if state.pressing && (.Left in in_.released || .Left not_in in_.down) {
        event(b,node,index,item,.Released)
        state.pressing=false
    }
    if hovered && .Right in in_.pressed && !ctx.right_press_used {event(b,node,index,item,.Right_Clicked)}
    over:=.Drop in node.flags && tree_drag_over(ctx,node,node_id)
    if over!=state.over {
        event(b,node,index,item,.Drag_Entered if over else .Drag_Left)
        state.over=over
    }
    disabled:=(bound_number(values,bound.disabled)!=0 if bound.disabled.bound else node.disabled) || ctx.disabled_depth>0
    variant:=node.variant
    if bound.variant.bound {variant=bound_variant(values,bound.variant)}
    if variant==0 {variant=b.desc.variant}
    states:=style_states({hot=hovered,focused=focused,active=ctx.active==node_id || (under && .Left in ctx.input.down)},selected,disabled,over)
    if b.desc.shown==i32(index)+1 {states=b.desc.shown_states}
    resolved:=base_style
    if rules:=tree_style_rules(tree,node.style);len(rules)>0 {
        plain:=Slot_Plain{variant=variant,rules=u32(len(rules)),states=states,seen=true}
        if state.plain!=plain {
            held,_:=style_rules_apply(&ctx.theme,&resolved,rules,node.style,variant,states)
            state.plain=plain if !held else {}
        }
    }
    if bound.tint.bound {resolved.fill=bound_color(values,bound.tint)}
    if base_style.transition>0 && style_transition(&state.look,&resolved,base_style.transition,ctx.input.dt) {b.animating=true}
    if base_style.layout_transition>0 && !layout_transition_ask(&ctx.layout,node_id,base_style.layout_transition,ctx.stats.frame) {ctx.stats.dropped_transitions+=1}
    style:=&resolved
    // A style moves what its node draws, not where the layout or the pointer find it.
    moved:=false
    if style.move!={} || style.scale!=0 && style.scale!=1 {
        look:=ANIM_IDENTITY
        look.offset=style.move
        if style.scale!=0 {look.scale={style.scale,style.scale}}
        moved=animated_begin(ctx,node_id,look,still=true)
    }
    defer if moved {animated_end(ctx)}
    image_ref:Node_Image
    if node.image!=0 && int(node.image)<=tree.image_count {image_ref=tree.images[node.image-1]}
    if bound.image.bound && ctx.game.texture!=nil {
        if id:=bound_asset(values,bound.image);id!={} {image_ref.quad=ctx.game.texture(ctx.game.user,id)} else {image_ref.quad={}}
    }
    image_ref=image_frame(image_ref,value.frame if playing && .Frame in value.set else 0)
    skip:=.Skip in node.flags
    if skip {ctx.unfocusable+=1}
    defer if skip {ctx.unfocusable-=1}
    if node_kind_holds(node.kind) {
        tree_build_container(ctx,b,node,index,next,slot,node_id,values,copy,item,style,image_ref,disabled)
        return next
    }
    content:=tree_node_text(ctx,b,node,index,slot,values)
    // A node that holds none floats in a box of its size that hangs as its float says.
    holder:Box
    if node.float.to!=.None {
        holder={id=id(ctx,"floating",int(u32(node_id))),float=node.float}
        holder.float.layer=i16(clamp(b.floor+int(node.float.layer),int(min(i16)),int(max(i16))))
        box_begin(ctx,holder)
    }
    tree_build_leaf(ctx,b,node,index,slot,node_id,values,item,&base_style,style,variant,image_ref,content,selected,disabled,&value if playing else nil)
    if node.float.to!=.None {box_end(ctx,holder)}
    tree_focus_links(ctx,node,node_id)
    // Only containers hold nodes: what hangs from any other kind is not built.
    return next
}

@(private)
tree_build_container :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,next,slot:int,node_id:Id,values:rawptr,copy:int,item:i32,style:^Node_Style,image_ref:Node_Image,disabled:bool) {
    tree:=b.tree
    box:=tree_box(node,style,node_id)
    box.float.layer=i16(clamp(b.floor+int(node.float.layer),int(min(i16)),int(max(i16))))
    box.image,box.image_border,box.image_border_uv,box.image_fit,box.image_size=image_ref.quad,image_ref.border,image_ref.border_uv,image_ref.fit,image_ref.size
    if int(node.style)<len(tree.programs) {box.program,box.program_values=tree.programs[node.style],style.program_values}
    // The rows of the grid tracks of the tree follow those the frame had when it began to build it.
    if box.tracks!=0 {box.tracks=u16(b.tracks+int(box.tracks)) if b.tracks+int(box.tracks)<=b.tracks_end else 0}
    // What wraps the focus, holds a float or takes a drop keeps its rectangle, and so does a Radial.
    box.track=(b.desc.track || node.kind==.Radial || .Wrap_X in node.flags || .Wrap_Y in node.flags || .Drop in node.flags || tree_holds_float(tree,index,next)) && .Draggable not_in node.flags
    if disabled {disabled_begin(ctx)}
    if .Draggable in node.flags {tree_drag_source(ctx,b,node,index,node_id,item)}
    #partial switch node.kind {
    case .Popup,.Context_Menu: tree_build_popup(ctx,b,node,index,next,slot,node_id,values,copy,item,&box)
    case .Modal:               tree_build_modal(ctx,b,node,index,next,node_id,values,copy,item,&box)
    case:                      tree_build_box(ctx,b,node,index,next,slot,node_id,values,copy,item,&box)
    }
    if disabled {disabled_end(ctx)}
    if .Draggable in node.flags {tree_drag_ghost(ctx,b,node,index,node_id,values,copy,item)}
    tree_drop_target(ctx,b,node,index,node_id,item)
    tree_focus_group(ctx,node,node_id)
}

// A container in the flow of its parent (a Box, a Scroll, a Switcher, a
// List, a Tabs or a Radial), or a Tooltip, which floats under the node that
// holds it and stays inside the surface.
@(private)
tree_build_box :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,next,slot:int,node_id:Id,values:rawptr,copy:int,item:i32,box:^Box) {
    tree,instance:=b.tree,b.instance
    if node.kind==.Tooltip {
        // Under the node, or where its float puts it against the node.
        box.float={to=.Parent,anchor=.Bottom_Center,pivot=.Top_Center,offset={0,6},layer=LAYER_TOOLTIP}
        if node.float.to!=.None {box.float.anchor,box.float.pivot,box.float.offset=node.float.anchor,node.float.pivot,node.float.offset}
        box.block,box.contain=false,true
    }
    if node.kind==.Tabs {box.direction=.Column}
    scrolls:=node.kind==.Scroll || node.kind==.List && node.clip
    axes:=tree_scroll_axes(node)
    inner:=box.layout
    if scrolls {
        // The style and the size are those of the area; how its content
        // is laid out is that of a box inside it that scrolls. It takes the
        // pointer, which brings it the wheel.
        box.direction,box.padding,box.gap,box.clip_x,box.clip_y,box.block=.Column,{},0,false,false,true
        inner.width,inner.height=GROW,GROW if axes==.Horizontal else FIT
    }
    // A List that builds what is in sight lays out its elements in a box of
    // its own layout, between the room of those before and after them.
    axis,virtual:=tree_list_axis(tree,node)
    items:Layout
    if virtual {
        holder:=&inner if scrolls else &box.layout
        items=holder^
        items.padding={}
        items.width,items.height=GROW,FIT
        if axis==0 {items.width,items.height=FIT,GROW}
        holder.direction=.Column if axis==1 else .Row
        holder.gap,holder.columns,holder.tracks=0,0,0
    }
    area:=id(ctx,"scroll",index+1)
    // Only the float of the node hangs from the area: what widgets float, such as popups, stays on the surface.
    if b.desc.area!=0 {ctx.area,ctx.area_rect=b.desc.area,b.desc.area_rect}
    box_begin(ctx,box^)
    ctx.area=0
    if scrolls {
        scroll_begin(ctx,area,&instance.scrolls[slot],{width=GROW,height=GROW,axes=axes})
        box_begin(ctx,{layout=inner})
    }
    #partial switch node.kind {
    case .Switcher:
        shown:=tree_switcher_page(tree,node,index,next,instance.bounds[index].value,values)
        state:=&instance.slot[slot]
        outer:=b.turned
        b.turned||=state.page_focused && state.page!=i32(shown+1)
        state.page=i32(shown+1)
        first:=ctx.widget_count
        tree_build_child(ctx,b,index,next,shown,values,copy,item)
        b.turned=outer
        state.page_focused=false
        for &w in ctx.widgets[first:ctx.widget_count] {
            if w.id==ctx.focus {state.page_focused=true;break}
        }
    case .List:
        tree_build_list(ctx,b,node,index,slot,values,copy,axis,virtual,items,area)
    case .Tabs:
        tree_build_tabs(ctx,b,node,index,next,slot,node_id,values,copy,item)
    case .Radial:
        tree_build_radial(ctx,b,node,index,next,node_id,values,copy,item)
    case:
        for child:=index+1;child<next; {
            if c:=&tree.nodes[child];c.kind==.Tooltip && !tree_tooltip_shown(ctx,b,node_id,slot,c.delay) {
                child+=int(c.subtree)+1
                continue
            }
            child=tree_build_node(ctx,b,child,values,copy,item)
        }
    }
    if scrolls {
        box_end(ctx,{layout=inner})
        scroll_end(ctx,area,&instance.scrolls[slot])
    }
    box_end(ctx,box^)
}

// What the bound value of a node of this kind must hold.
@(private)
tree_value_want :: proc "contextless" (kind:Node_Kind) -> Bound_Want {
    #partial switch kind {
    case .View:              return .Entity
    case .Switcher:          return .Shown
    case .Selector,.Dropdown:return .Option
    case .Draw:              return .Data
    }
    return .Number
}

// The position of the node a Switcher builds: by name when it binds an enum or
// a text (the child called as its value; -1, none, when it has no such child),
// else by index.
@(private)
tree_switcher_page :: proc(tree:^Widget_Tree,node:^Node,index,next:int,bound:Bound,values:rawptr) -> int {
    if !bound.bound {return int(node.index)}
    if bound.choices_of==nil && !bound.text {return int(bound_number(values,bound))}
    name:=bound_name(values,bound)
    if name=="" {return -1}
    wanted:=base.name_hash(name)
    for child,i:=index+1,0;child<next;i+=1 {
        if tree.nodes[child].name==wanted {return i}
        child+=int(tree.nodes[child].subtree)+1
    }
    return -1
}

// Builds the node held at position at of the node at index, and no other.
@(private)
tree_build_child :: proc(ctx:^Context,b:^Tree_Build,index,next,at:int,values:rawptr,copy:int,item:i32) {
    for child,i:=index+1,0;child<next;i+=1 {
        if i==at {tree_build_node(ctx,b,child,values,copy,item);return}
        child+=int(b.tree.nodes[child].subtree)+1
    }
}

// The axes a Scroll moves: those of the direction of its content, Row
// across and any other down, and both while it clips. A List that clips
// moves along its direction.
@(private)
tree_scroll_axes :: proc "contextless" (node:^Node) -> Scroll_Axes {
    if node.kind==.Scroll && node.clip {return .Both}
    return .Horizontal if node.layout.direction==.Row else .Vertical
}

// The axis a List builds only what is in sight along (0 across, 1 down):
// the one it scrolls when it clips, or the one the Scroll that holds it
// scrolls when they go the same way. A wrap or a stack builds all of it.
@(private)
tree_list_axis :: proc(tree:^Widget_Tree,node:^Node) -> (axis:int,virtual:bool) {
    if node.kind!=.List {return}
    #partial switch node.layout.direction {
    case .Column,.Grid: axis=1
    case .Row:          axis=0
    case:               return
    }
    if node.clip {return axis,true}
    if node.parent<0 || tree.nodes[node.parent].kind!=.Scroll {return}
    return axis,scroll_moves(tree_scroll_axes(&tree.nodes[node.parent]))[axis]
}

// The elements of a List: one per element of its array, or row of its
// table, up to what its bound value says. One that builds only what is in
// sight builds those, with the room of the others before and after them.
@(private)
tree_build_list :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,slot:int,values:rawptr,copy:int,axis:int,virtual:bool,layout:Layout,area:Id) {
    instance:=b.instance
    items:=instance.items[index]
    count:=int(items.count)
    if items.rows {count=min(count,int(instance.regions[instance.regions[items.region].parent].count))}
    if value:=instance.bounds[index].value;value.bound {count=clamp(int(bound_number(values,value)),0,count)}
    first,last:=0,count
    holder:=id(ctx,"items",index+1)
    columns,rows:=1,count
    pitch:f32
    if virtual {
        layout:=layout
        if layout.direction==.Grid {columns=grid_columns(&ctx.layout,&layout)}
        rows=(count+columns-1)/columns
        first,last,pitch=tree_list_window(ctx,b,node,index,slot,copy,axis,holder,columns,count,area)
        tree_list_room(ctx,axis,f32(first/columns)*pitch)
        box_begin(ctx,{id=holder,layout=layout,track=true})
    }
    for element in first..<last {
        at:=values
        if items.bound {at=rawptr(uintptr(values)+uintptr(items.offset)+uintptr(element)*uintptr(items.stride))}
        id_push(ctx,id(ctx,"item",element+1))
        tree_build_node(ctx,b,index+1,at,copy*int(max(items.count,1))+element,i32(element))
        id_pop(ctx)
    }
    if virtual {
        box_end(ctx,{id=holder})
        tree_list_room(ctx,axis,f32(rows-(last+columns-1)/columns)*pitch)
        state:=&instance.slot[slot]
        state.first,state.built=i32(first),i32(last-first)
    }
}

@(private)
tree_list_room :: proc(ctx:^Context,axis:int,room:f32) {
    if room<=0 {return}
    element_leaf(ctx,{layout={width=fixed(0),height=fixed(room)} if axis==1 else {width=fixed(room),height=fixed(0)}})
}

// The elements of a List in sight, with a row more on each side that
// navigation reaches, and the pitch of its rows (a row and its gap): from
// what the last frame built, and the offset of the area it is seen through
// now. While it does not know them, the first few. An element the code just
// gave the focus to, out of sight, is brought into it the next frame.
@(private)
tree_list_window :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,slot,copy,axis:int,holder:Id,columns,count:int,area:Id) -> (first,last:int,pitch:f32) {
    instance:=b.instance
    state:=&instance.slot[slot]
    view_id,scroll:=area,&instance.scrolls[slot]
    if !node.clip {
        parent:=int(node.parent)
        view_id,scroll=id(ctx,"scroll",parent+1),&instance.scrolls[int(instance.slots[parent])+copy]
    }
    offset:=scroll^
    view,seen:=widget_rect(ctx,view_id)
    content,_:=widget_rect(ctx,scroll_content_id(ctx,view_id))
    built,held:=widget_rect(ctx,holder)
    probe:=min(count,TREE_LIST_PROBE)
    rows:=(int(state.built)+columns-1)/columns
    if !seen || !held || rows<=0 {
        if count>0 {b.animating=true}
        return 0,probe,0
    }
    pitch=((built.h if axis==1 else built.w)+node.layout.gap)/f32(rows)
    if pitch<=0 {return 0,probe,0}
    // Where the first element is, in the content of the area, and what of it is in sight.
    start:=(built.y-content.y if axis==1 else built.x-content.x)-f32(int(state.first)/columns)*pitch
    at:=offset[axis]-start
    room:=view.h if axis==1 else view.w
    total:=(count+columns-1)/columns
    top:=clamp(int(math.floor(at/pitch))-1,0,total)
    bottom:=clamp(int(math.ceil((at+room)/pitch))+1,top,total)
    if _,shown:=widget_rect(ctx,ctx.focus);ctx.focus!=0 && ctx.focus!=ctx.focus_seen && !shown {
        // The focus may be on any node of the element, other than those inside a List of its own.
        nodes:=b.tree.nodes[index+1:][:int(node.subtree)]
        for element in 0..<count {
            id_push(ctx,id(ctx,"item",element+1))
            focused:=false
            for at:=0;at<len(nodes) && !focused; {
                focused=tree_node_id(ctx,&nodes[at],index+1+at)==ctx.focus
                at+=int(nodes[at].subtree)+1 if nodes[at].kind==.List else 1
            }
            id_pop(ctx)
            if !focused {continue}
            row:=start+f32(element/columns)*pitch
            scroll_reveal(&scroll[axis],row,row+pitch-node.layout.gap,room)
            b.animating=true
            break
        }
    }
    return top*columns,min(bottom*columns,count),pitch
}

// The variant a node takes: its own, its bound one or that of the tree.
@(private)
tree_node_variant :: proc(b:^Tree_Build,node:^Node,index:int,values:rawptr) -> u64 {
    variant:=node.variant
    if bound:=b.instance.bounds[index].variant;bound.bound {variant=bound_variant(values,bound)}
    return variant if variant!=0 else b.desc.variant
}

// A strip of tabs, one per node held and labeled by its text (its number
// without one), over the page of the one chosen: the bound value, or what
// the strip chose last (index at first). A tab chosen says Changed with its
// index; one the keys or the gamepad move the focus to is chosen.
@(private)
tree_build_tabs :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,next,slot:int,node_id:Id,values:rawptr,copy:int,item:i32) {
    tree,instance:=b.tree,b.instance
    bound:=instance.bounds[index].value
    state:=&instance.slot[slot]
    chosen:=int(node.index)
    if bound.bound {chosen=int(bound_number(values,bound))} else if state.held>0 {chosen=int(state.held)-1}
    base_style:=tree.styles[node.style] if int(node.style)<tree.style_count else Node_Style{}
    variant:=tree_node_variant(b,node,index,values)
    picked:=chosen
    // A tab shows its option, as a Selector has them, or else the text of its node, its name or its number.
    options:=tree_options(b,index,values,tree_node_text(ctx,b,node,index,slot,values))
    if box(ctx,{id=id_derive(ctx,node_id,"strip"),width=GROW,height=FIT,gap=node.layout.gap}) {
        for child,at:=index+1,0;child<next;at+=1 {
            c:=&tree.nodes[child]
            tab:=id_derive(ctx,node_id,"tab",at+1)
            label:=option(options,at)
            if label=="" {label=tree_node_text(ctx,b,c,child,int(instance.slots[child])+copy,values)}
            if label=="" {label=string(tree.strings[c.tab.offset:][:c.tab.length])}
            if label=="" {label=number_text(ctx,f64(at+1),0)}
            look:=style_resolve(&ctx.theme,base_style,tree_style_rules(tree,node.style),node.style,variant,widget_states(ctx,tab,at==chosen))
            if button(ctx,tab,{label=label,look=&look,layout=&Layout{padding=TREE_TAB_PADDING},block=true}).clicked {picked=at}
            if ctx.focus==tab && ctx.focus_moved {picked=at}
            child+=int(c.subtree)+1
        }
    }
    if picked!=chosen {
        if bound.bound {bound_write(values,bound,f64(picked))} else {state.held=f32(picked+1)}
        tree_emit(b,{name=node.name,node=i32(index),kind=.Changed,item=item,value=f64(picked)})
        tree_sound(ctx,&base_style,.Change)
        chosen=picked
    }
    tree_build_child(ctx,b,index,next,chosen,values,copy,item)
}

RADIAL_DEAD :: f32(0.5) // of the travel of the left stick, or of the radius for the pointer, past which a direction chooses

// The nodes a Radial holds on a circle as large as its box leaves room for,
// the first at the top and on clockwise. The one in the direction of the
// left stick, the arrows or the pointer from the center takes the focus, and
// Accept clicks it.
@(private)
tree_build_radial :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,next:int,node_id:Id,values:rawptr,copy:int,item:i32) {
    tree:=b.tree
    count:=0
    for child:=index+1;child<next;child+=int(tree.nodes[child].subtree)+1 {count+=1}
    if count==0 {return}
    rect,seen:=widget_rect(ctx,node_id)
    if !seen {b.animating=true}
    extent:f32
    for at in 0..<count {
        if r,found:=widget_rect(ctx,id_derive(ctx,node_id,"spoke",at+1));found {extent=max(extent,r.w,r.h)}
    }
    radius:=max(min(rect.w,rect.h)*0.5-extent*0.5,0)
    step:=2*math.PI/f32(count)
    in_:=&ctx.input
    direction:=in_.aim
    if direction.x*direction.x+direction.y*direction.y<RADIAL_DEAD*RADIAL_DEAD {
        direction={}
        keys,pads:=in_.keys_repeated,in_.pad
        if .Left in keys || .Left in pads {direction.x-=1}
        if .Right in keys || .Right in pads {direction.x+=1}
        if .Up in keys || .Up in pads {direction.y-=1}
        if .Down in keys || .Down in pads {direction.y+=1}
        if direction=={} && seen && !in_.pointer_absent && ctx.pointer_moved && rect_contains(rect,ctx.pointer) {
            if d:=ctx.pointer-rect_center(rect);d.x*d.x+d.y*d.y>=radius*radius*RADIAL_DEAD*RADIAL_DEAD {direction=d}
        }
    }
    chosen:=-1
    if direction!={} {
        turn:=math.atan2(direction.y,direction.x)+math.PI*0.5
        if turn<0 {turn+=2*math.PI}
        chosen=int(math.round(turn/step))%count
    }
    for child,at:=index+1,0;child<next;at+=1 {
        angle:=f32(at)*step-math.PI*0.5
        spoke:=id_derive(ctx,node_id,"spoke",at+1)
        box_begin(ctx,{id=spoke,float={to=.Parent,anchor=.Center,pivot=.Center,offset=[2]f32{math.cos(angle),math.sin(angle)}*radius},track=true})
        first:=ctx.widget_count
        child=tree_build_node(ctx,b,child,values,copy,item)
        if at==chosen {
            for &w in ctx.widgets[first:ctx.widget_count] {
                if .Focusable in w.flags && .Disabled not_in w.flags {ctx.focus,ctx.focus_ring=w.id,true;break}
            }
        }
        box_end(ctx,{id=spoke,float={to=.Parent}})
    }
}

// A Popup hangs under the node that holds it, or over it when there is no
// room below, and opens while its bound value is true, or when that node is
// clicked or activated if it binds none. A Context_Menu opens at the pointer
// when the node that holds it is clicked with the right button, and a Button
// chosen in it closes it. A press outside them or Escape closes them, and
// they say when they open and close. A Popup the player closed while the
// game shows it stays shut until the game hides it.
@(private)
tree_build_popup :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,next,slot:int,node_id:Id,values:rawptr,copy:int,item:i32,box:^Box) {
    tree,instance:=b.tree,b.instance
    state:=&instance.slot[slot]
    menu:=node.kind==.Context_Menu
    _,was:=widget_rect(ctx,node_id)
    parent:Rect
    holder:=false
    if node.parent>=0 {parent,holder=widget_rect(ctx,tree_node_id(ctx,&tree.nodes[node.parent],int(node.parent)))}
    open:=popup_is_open(ctx,node_id)
    bound:=instance.bounds[index].value
    if bound.bound && !menu {
        want:=bound_number(values,bound)!=0
        if want && was && !open {state.latched=true}
        if !want {state.latched=false}
        if !want && open {popup_close(ctx,node_id);open=false}
        if want && !open && !state.latched {open=tree_popup_open(ctx,node_id,parent)}
    } else if !open && holder && ctx.popup.closed!=ctx.stats.frame {
        in_:=&ctx.input
        over:=!in_.pointer_absent && rect_contains(parent,ctx.pointer) && (ctx.hot==0 || ctx.hot_layer<LAYER_POPUP)
        if menu && over && .Right in in_.pressed {open=tree_popup_open(ctx,node_id,{ctx.pointer.x,ctx.pointer.y,0,0})}
        if !menu {
            activated:=false
            if r,found:=widget_rect(ctx,ctx.activate);ctx.activate!=0 && found {activated=rect_contains(parent,rect_center(r))}
            if over && .Left in in_.pressed || activated {open=tree_popup_open(ctx,node_id,parent)}
        }
    }
    if open!=was {tree_emit(b,{name=node.name,node=i32(index),kind=.Opened if open else .Closed,item=item})}
    entry:=popup_find(ctx,node_id)
    if entry==nil {return}
    box.block,box.contain=true,true
    if menu {
        // At the pointer, on the side of it that has room.
        size:=surface_size(ctx)
        last,_:=widget_rect(ctx,node_id)
        at:=[2]f32{entry.anchor.x,entry.anchor.y}
        if at.x+last.w>size.x {at.x-=last.w}
        if at.y+last.h>size.y {at.y-=last.h}
        box.float={to=.Surface,offset=at,layer=entry.layer}
    } else {
        box.float={to=.Parent,anchor=.Bottom_Left,pivot=.Top_Left,offset=node.float.offset+{0,4},layer=entry.layer}
    }
    popup_enter(ctx,entry)
    box_begin(ctx,box^)
    events:=b.count
    for child:=index+1;child<next; {child=tree_build_node(ctx,b,child,values,copy,item)}
    box_end(ctx,box^)
    popup_leave(ctx,entry)
    if menu {
        for e in b.desc.events[events:b.count] {
            if e.kind==.Clicked && e.node>i32(index) && e.node<i32(next) {popup_close(ctx,node_id);break}
        }
    }
}
@(private)
tree_popup_open :: proc(ctx:^Context,id:Id,anchor:Rect) -> bool {
    popup_open(ctx,id,anchor)
    return popup_is_open(ctx,id)
}

// A Modal is centered over a backdrop that takes all input while it shows,
// with navigation kept inside it; Escape says Closed for the game to hide it.
@(private)
tree_build_modal :: proc(ctx:^Context,b:^Tree_Build,node:^Node,index,next:int,node_id:Id,values:rawptr,copy:int,item:i32,box:^Box) {
    if _,was:=widget_rect(ctx,node_id);!was {tree_emit(b,{name=node.name,node=i32(index),kind=.Opened,item=item})}
    size:=surface_size(ctx)
    if b.desc.area!=0 {
        ctx.area,ctx.area_rect=b.desc.area,b.desc.area_rect
        size={b.desc.area_rect.w,b.desc.area_rect.h}
    }
    backdrop:=id_derive(ctx,node_id,"backdrop")
    // Nothing it was built in clips it.
    clips_suspend(ctx)
    box_begin(ctx,{id=backdrop,width=fixed(size.x),height=fixed(size.y),float={to=.Surface,layer=LAYER_MODAL},fill=ctx.theme.backdrop,block=true})
    box_end(ctx,{id=backdrop,float={to=.Surface}})
    box.float={to=.Surface,anchor=.Center,pivot=.Center,offset=node.float.offset,layer=LAYER_MODAL+1}
    box.block=true
    box_begin(ctx,box^)
    ctx.area=0
    for child:=index+1;child<next; {child=tree_build_node(ctx,b,child,values,copy,item)}
    box_end(ctx,box^)
    clips_resume(ctx)
    ctx.modal_open,ctx.modal_layer=true,LAYER_MODAL
    if escape(ctx) {tree_emit(b,{name=node.name,node=i32(index),kind=.Closed,item=item})}
}

@(private)
tree_holds_float :: proc(tree:^Widget_Tree,index,next:int) -> bool {
    for child:=index+1;child<next;child+=int(tree.nodes[child].subtree)+1 {
        #partial switch tree.nodes[child].kind {
        case .Tooltip,.Popup,.Context_Menu: return true
        }
    }
    return false
}

// Whether the Tooltip of the container shows: the pointer has been over it,
// or the focus inside it, for delay seconds (TOOLTIP_DELAY when 0).
@(private)
tree_tooltip_shown :: proc(ctx:^Context,b:^Tree_Build,container:Id,slot:int,delay:f32) -> bool {
    r,found:=widget_rect(ctx,container)
    if !found {return false}
    wait:=delay if delay>0 else f32(TOOLTIP_DELAY)
    over:=!ctx.input.pointer_absent && rect_contains(r,ctx.pointer)
    if ctx.focus!=0 && ctx.focus_ring {
        if focused,has:=widget_rect(ctx,ctx.focus);has && rect_contains(r,{focused.x+focused.w*0.5,focused.y+focused.h*0.5}) {over=true}
    }
    state:=&b.instance.slot[slot]
    if over {state.tip+=ctx.input.dt} else {state.tip=0}
    if over && state.tip<wait {b.animating=true}
    return over && state.tip>=wait
}

// The id the node called name gets where its tree is built: for widget_rect,
// or to animate it from code.
tree_element_id :: proc(ctx:^Context,name:string) -> Id {
    return tree_name_id(ctx,base.name_hash(name))
}

// The id of the node at index where its tree is built, as the node is for
// element 0 of the lists around it.
tree_node_element :: proc(ctx:^Context,tree:^Widget_Tree,index:int) -> Id {
    if index<0 || index>=tree.node_count {return 0}
    // The lists around the node push the scope of their first element.
    lists:[TREE_DEPTH]bool
    depth:=0
    for parent:=tree.nodes[index].parent;parent>=0 && depth<TREE_DEPTH;parent=tree.nodes[parent].parent {
        lists[depth]=tree.nodes[parent].kind==.List
        depth+=1
    }
    pushed:=0
    for i:=depth-1;i>=0;i-=1 {
        if lists[i] {id_push(ctx,id(ctx,"item",1));pushed+=1}
    }
    element:=tree_node_id(ctx,&tree.nodes[index],index)
    for _ in 0..<pushed {id_pop(ctx)}
    return element
}

// What the node at index showed in the last build of an instance: whether a
// copy of it was shown, hovered or focused, whether it is disabled by itself
// for element 0 of the lists around it (a container that disables it is not
// counted), and the text that copy showed when the build kept it or the node
// shows its own; empty when it would have to be formatted again.
Tree_Node_State :: struct {
    shown,hovered,focused,disabled:bool,
    text:string,
}

tree_node_state :: proc(tree:^Widget_Tree,instance:^Tree_Instance,index:int) -> (state:Tree_Node_State,ok:bool) {
    count:=tree.node_count
    if index<0 || index>=count || len(instance.slots)<count || len(instance.bounds)<count || len(instance.templates)<count || len(instance.items)<count {return}
    first:=int(instance.slots[index])
    end:=int(instance.slots[index+1]) if index+1<count else len(instance.slot)
    if first>end || end>len(instance.slot) {return}
    for &slot in instance.slot[first:end] {
        state.shown||=slot.shown
        state.hovered||=slot.hovered
        state.focused||=slot.focused
    }
    node:=&tree.nodes[index]
    state.disabled=node.disabled
    // The values of element 0: each list around the node moves them to its first element.
    values:=rawptr(raw_data(instance.values))
    present:=true
    lists:[TREE_DEPTH]i32
    depth:=0
    for parent:=node.parent;parent>=0 && depth<TREE_DEPTH;parent=tree.nodes[parent].parent {
        if tree.nodes[parent].kind==.List {lists[depth]=parent;depth+=1}
    }
    for i:=depth-1;i>=0;i-=1 {
        items:=instance.items[lists[i]]
        if !items.bound {continue}
        if items.count==0 {present=false;break}
        values=rawptr(uintptr(values)+uintptr(items.offset))
    }
    bound:=&instance.bounds[index]
    if present && bound.disabled.bound {state.disabled=bound_number(values,bound.disabled)!=0}
    if first<end && first<len(instance.kept) {
        if kept:=instance.kept[first];kept.valid && int(kept.offset)+int(kept.length)<=len(instance.kept_bytes) {
            state.text=string(instance.kept_bytes[kept.offset:][:kept.length])
            return state,true
        }
    }
    if bound.text.bound || instance.templates[index].template {return state,true}
    state.text=instance.texts[index]
    return state,true
}

// The deepest node of the tree whose element held point when the last frame
// was laid out, built with Tree_Build_Desc.track; -1 for none.
tree_hit :: proc(ctx:^Context,tree:^Widget_Tree,point:[2]f32) -> int {
    best:=-1
    for i in 0..<tree.node_count {
        r,found:=widget_rect(ctx,tree_node_element(ctx,tree,i))
        if !found || !rect_contains(r,point) {continue}
        // Later nodes in pre-order are inside or after earlier ones.
        best=i
    }
    return best
}
