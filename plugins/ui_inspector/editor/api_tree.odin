package ui_inspector_editor

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// Agents author interfaces as the document does: ui.inspect gives a .ui, or
// one of its nodes, as a document (api_document.odin) and ui.write makes the
// file say what a document declares; ui.node.add, set, move, duplicate and
// delete change one node, ui.style.set and ui.variant.set a look and
// ui.anim.set an animation, and what such a call does not name stays. Fields
// go by the names of ui.Tree_Node, ui.Node_Style and ui.Tree_Image. A node is
// named by its name, or by "#row". Each call is one step of the history of
// the file, which waits for Save; a call that would leave a tree that does
// not load changes nothing and says why.

@(storage)
Ui_Tree_Api :: struct {provider:editor.Api_Provider}
ui_tree_api_default :: proc() -> Ui_Tree_Api {return {provider={register=tree_api_register}}}

@(private) TREE_ASSET_SCHEMA :: `"asset":{"type":"string","description":"id of a .ui of the project"}`
@(private) TREE_NODE_KEYS :: `"text":{"type":"string","description":"its text, in the language interfaces are written in (ui.text.set gives the others)"},"style":{"type":"string","description":"the name of a style of the file (ui.style.set makes one); empty: its own look"},"fields":{"type":"object","description":"fields of ui.Tree_Node by name, partially: {\"layout\":{\"width\":{\"kind\":\"Fixed\",\"value\":200}},\"float\":{\"to\":\"Safe\"},\"bind_value\":\"Player.health\"}; engine.describe has the types"},"image":{"type":["object","null"],"description":"fields of ui.Tree_Image (texture, uv, border, border_uv, fit, frames, name); null: none"},"events":{"type":"object","description":"by trigger (shown, hidden, hovered, unhovered, pressed, released, focused, unfocused, selected, unselected, clicked), the name of the animation it plays; empty: none"}`
@(private) TREE_INSPECT_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset"],"properties":{` + TREE_ASSET_SCHEMA + `,"node":{"type":"string","description":"name or #row: that node and what it holds, with the styles and animations they take; absent: the whole file"}}}`
@(private) TREE_WRITE_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset","document"],"properties":{` + TREE_ASSET_SCHEMA + `,"node":{"type":"string","description":"name or #row: the document declares that node and what it holds, and nothing else of the file changes; absent: the whole file"},"document":{"type":"object","description":"as ui.inspect gives it. styles and animations by name: those it names become what it says, null takes one away, the others stay. nodes, each {name, kind or widget, text, style or look, image, events, fields, children}: the nodes of the file, or of node, become these, matched by name and kind so a node keeps its translations; those it does not declare are taken away, and what a node does not give is that of a new node of its kind. Without nodes, no node changes"}}}`
@(private) TREE_ADD_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset"],"properties":{` + TREE_ASSET_SCHEMA + `,"kind":{"type":"string","description":"Box, Text, Image, Button, Progress, Checkbox, Slider, Field, Number, Selector, Dropdown, Radio, Rich_Text, Prompt, Action_Bar, Scroll, List, Switcher, Tabs, Popup, Modal, Context_Menu, Radial, Tooltip, View, Particles or Spacer; absent with widget"},"widget":{"type":"string","description":"id of another .ui: the node is an instance of it"},"name":{"type":"string"},"parent":{"type":"string","description":"the container it goes in; absent: a root"},"before":{"type":"string","description":"the node of parent it goes before; absent: last"},"children":{"type":"array","description":"the nodes it holds, in order, each with the keys of ui.node.add but asset, parent and before: a whole tree in one call","items":{"type":"object"}},` + TREE_NODE_KEYS + `}}`
@(private) TREE_SET_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset","node"],"properties":{` + TREE_ASSET_SCHEMA + `,"node":{"type":"string","description":"name or #row"},"name":{"type":"string","description":"a new name, unique in the file"},` + TREE_NODE_KEYS + `}}`
@(private) TREE_MOVE_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset","node"],"properties":{` + TREE_ASSET_SCHEMA + `,"node":{"type":"string"},"parent":{"type":"string","description":"absent: a root"},"before":{"type":"string","description":"absent: last"}}}`
@(private) TREE_NODE_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset","node"],"properties":{` + TREE_ASSET_SCHEMA + `,"node":{"type":"string","description":"name or #row"}}}`
@(private) TREE_STYLE_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset","style"],"properties":{` + TREE_ASSET_SCHEMA + `,"style":{"type":"string","description":"its name; a style the file lacks is made"},"family":{"type":"string","enum":["Box","Text","Control"],"description":"the nodes it is offered to, when it is made"},"rename":{"type":"string"},"defaults":{"type":"array","items":{"type":"string"},"description":"the kinds whose new nodes take it (Button, Text, ...), its family alone, and no other style of the file; []: none"},"fields":{"type":"object","description":"fields of ui.Node_Style by name, partially: {\"fill\":[30,36,52,255],\"radius\":[6,6,6,6],\"text\":{\"size\":15}}"}}}`
@(private) TREE_VARIANT_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset","style"],"properties":{` + TREE_ASSET_SCHEMA + `,"style":{"type":"string"},"variant":{"type":"string","description":"the name a node, its screen or the game chooses; empty: every variant"},"states":{"type":"array","items":{"type":"string","enum":["Selected","Hovered","Focused","Over","Pressed","Disabled"]},"description":"all of them active"},"fields":{"type":"object","description":"what the rule sets, by the names of ui.Node_Style: fill, fill2, stroke, track, knob, mark, radius, stroke_width, shadow (with shadow_color, shadow_blur, shadow_offset) and text {font, size, color, outline, outline_color, shadow, shadow_color}"},"tokens":{"type":"object","description":"colors of the theme instead of literals: fill, fill2, stroke, text, track, knob, mark (Accent, Text, Field, ...)"},"remove":{"type":"boolean"}}}`
@(private) TREE_ANIM_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset","name"],"properties":{` + TREE_ASSET_SCHEMA + `,"name":{"type":"string","description":"what events and the game name it by; one the file lacks is made"},"kind":{"type":"string","enum":["Clip","Sequence","Parallel"]},"loop":{"type":"string","enum":["Once","Loop","Ping_Pong"]},"tracks":{"type":"array","description":"of a Clip","items":{"type":"object","properties":{"property":{"type":"string","enum":["Offset","Scale","Rotation","Opacity","Color","Width","Height","Value","Frame","Reveal"]},"keys":{"type":"array","items":{"type":"object","properties":{"time":{"type":"number"},"value":{"type":"array","items":{"type":"number"},"minItems":4,"maxItems":4},"ease":{"type":"string"}}}}}}},"parts":{"type":"array","items":{"type":"string"},"description":"of a Sequence or a Parallel: names of animations made before it"}}}`

// Bytes of a text of a result that no capacity of its own bounds.
@(private) RESULT_TEXT_BYTES :: 256*1024

Ui_Ok :: struct {ok:bool}
Tree_Node_Answer :: struct {
    ok:bool,
    row:int `mirai:"label=The row the node is at now (the copy for a duplicate); #row names it"`,
    name:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text"`,
}
Tree_Row_Answer :: struct {
    ok:bool,
    row:int `mirai:"label=Its row among the styles or the animations of the file"`,
}

Tree_Inspect :: struct {
    document:Tree_Document `mirai:"label=What ui.write takes back"`,
    widgets:[1]Tree_Inspect_Widget `mirai:"list,label=The other .ui its instances are of"`,
    fonts:[1]base.Asset_Id `mirai:"list,label=The .font its styles take"`,
}
Tree_Document :: struct {
    styles:u8 `mirai:"any,label=The named styles, or those its nodes take, by name: family, defaults (the kinds whose new nodes take it), fields of ui.Node_Style that are not zero, and rules {variant, states, fields, tokens}"`,
    animations:u8 `mirai:"any,label=By name: kind, loop, and tracks of a Clip or parts of a Sequence or a Parallel"`,
    nodes:[1]Tree_Document_Node `mirai:"list,label=The roots in order; with node, that node alone"`,
}
Tree_Document_Node :: struct {
    name:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,label=What ui.write matches it by"`,
    kind:ui.Node_Kind `mirai:"optional"`,
    widget:base.Asset_Id `mirai:"optional,label=Of an instance of another .ui, instead of kind"`,
    text:[RESULT_TEXT_BYTES]u8 `mirai:"text,optional,label=In the language interfaces are written in"`,
    style:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,optional,label=The named style it takes; empty: none, where its kind would take one; absent: the one its kind takes"`,
    look:u8 `mirai:"any,optional,label=Its own look, as a style without family; with style, what it changes of that style until it is saved there"`,
    image:ui.Tree_Image `mirai:"optional"`,
    events:u8 `mirai:"any,optional,label=By trigger (shown, hovered, clicked, ...): the animation it plays"`,
    fields:u8 `mirai:"any,label=The fields of ui.Tree_Node that differ from a new node of its kind"`,
    children:u8 `mirai:"any,optional,label=The nodes it holds, in order, as this one"`,
}
Tree_Inspect_Widget :: struct {
    name:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text"`,
    asset:base.Asset_Id,
    title:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The name of its file"`,
}

@(private)
tree_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="ui.inspect",summary="A .ui, or one of its nodes, as the document ui.write takes back: its nodes nested, each with what differs from a new node of its kind, and the styles and animations they take.",params_schema=TREE_INSPECT_SCHEMA,result=Tree_Inspect,result_info=type_info_of(Tree_Inspect),writes_result=true,flags={.Read_Only},run=api_tree_inspect})
    editor.api_method_register(s,{name="ui.node.add",summary="Adds a node of a kind, or an instance of another .ui, to a .ui. One step of history; the file waits for Save.",params_schema=TREE_ADD_SCHEMA,result=Tree_Node_Answer,result_info=type_info_of(Tree_Node_Answer),run=api_tree_add})
    editor.api_method_register(s,{name="ui.node.set",summary="Changes a node of a .ui; what the call does not name stays. One step of history; the file waits for Save.",params_schema=TREE_SET_SCHEMA,result=Tree_Node_Answer,result_info=type_info_of(Tree_Node_Answer),run=api_tree_set})
    editor.api_method_register(s,{name="ui.node.move",summary="Moves a node of a .ui with what it holds to another container or place among its siblings. One step of history; the file waits for Save.",params_schema=TREE_MOVE_SCHEMA,result=Tree_Node_Answer,result_info=type_info_of(Tree_Node_Answer),run=api_tree_move})
    editor.api_method_register(s,{name="ui.node.duplicate",summary="Copies a node of a .ui with what it holds right after it, each copy with a name of its own. One step of history; the file waits for Save.",params_schema=TREE_NODE_SCHEMA,result=Tree_Node_Answer,result_info=type_info_of(Tree_Node_Answer),run=api_tree_duplicate})
    editor.api_method_register(s,{name="ui.node.delete",summary="Removes a node of a .ui with what it holds and their translations. One step of history; the file waits for Save.",params_schema=TREE_NODE_SCHEMA,result=Ui_Ok,result_info=type_info_of(Ui_Ok),flags={.Destructive},run=api_tree_delete})
    editor.api_method_register(s,{name="ui.style.set",summary="Makes or changes a named style of a .ui; what the call does not name stays. Nodes take it with the key style of ui.node.set.",params_schema=TREE_STYLE_SCHEMA,result=Tree_Row_Answer,result_info=type_info_of(Tree_Row_Answer),run=api_tree_style})
    editor.api_method_register(s,{name="ui.variant.set",summary="Makes, changes or removes the rule of a style for a variant and states: what it sets over the style while a node shows that variant with those states active.",params_schema=TREE_VARIANT_SCHEMA,result=Ui_Ok,result_info=type_info_of(Ui_Ok),run=api_tree_variant})
    editor.api_method_register(s,{name="ui.anim.set",summary="Makes or replaces a named animation of a .ui. Nodes play it by their events; the game by tree_play.",params_schema=TREE_ANIM_SCHEMA,result=Tree_Row_Answer,result_info=type_info_of(Tree_Row_Answer),run=api_tree_anim})
    editor.api_method_register(s,{name="ui.write",summary="Makes a .ui, or one of its nodes, say what a document declares, as ui.inspect gives it: nodes matched by name keep their translations, the others are made, and those it does not declare go. One step of history; the file waits for Save.",params_schema=TREE_WRITE_SCHEMA,result=Tree_Write_Answer,result_info=type_info_of(Tree_Write_Answer),run=api_tree_write})
    capture_api_register(s)
}

// The operations that change one part of a .ui.
@(private)
Tree_Op :: enum u8 {Add,Set,Move,Duplicate,Delete,Style,Variant,Anim}
@(private) TREE_OP_LABELS :: [Tree_Op]string{.Add="Add node",.Set="Edit node",.Move="Move node",.Duplicate="Duplicate node",.Delete="Delete node",.Style="Style",.Variant="Variant",.Anim="Animation"}

@(private) api_tree_add :: proc(s:^editor.Session,call:^api.Call) {tree_run(s,call,.Add)}
@(private) api_tree_set :: proc(s:^editor.Session,call:^api.Call) {tree_run(s,call,.Set)}
@(private) api_tree_move :: proc(s:^editor.Session,call:^api.Call) {tree_run(s,call,.Move)}
@(private) api_tree_duplicate :: proc(s:^editor.Session,call:^api.Call) {tree_run(s,call,.Duplicate)}
@(private) api_tree_delete :: proc(s:^editor.Session,call:^api.Call) {tree_run(s,call,.Delete)}
@(private) api_tree_style :: proc(s:^editor.Session,call:^api.Call) {tree_run(s,call,.Style)}
@(private) api_tree_variant :: proc(s:^editor.Session,call:^api.Call) {tree_run(s,call,.Variant)}
@(private) api_tree_anim :: proc(s:^editor.Session,call:^api.Call) {tree_run(s,call,.Anim)}

// Runs an operation on the records: the row of the node, style or animation
// it leaves, -1 for none. ok false after failing the call.
@(private)
tree_apply :: proc(op:Tree_Op,args:^Tree_Args,r:^Records) -> (row:int,ok:bool) {
    switch op {
    case .Add:       row=tree_add_apply(args,r);return row,row>=0
    case .Set:       row=tree_set_apply(args,r);return row,row>=0
    case .Move:      row=tree_move_apply(args,r);return row,row>=0
    case .Duplicate: row=tree_duplicate_apply(args,r);return row,row>=0
    case .Delete:    return -1,tree_delete_apply(args,r)
    case .Style:     row=tree_style_apply(args,r);return row,row>=0
    case .Variant:   return -1,tree_variant_apply(args,r)
    case .Anim:      row=tree_anim_apply(args,r);return row,row>=0
    }
    return -1,false
}

// One operation as a call of its own: one step of history.
@(private)
tree_run :: proc(s:^editor.Session,call:^api.Call,op:Tree_Op) {
    args,args_ok:=tree_args(s,call)
    if !args_ok {return}
    r:Records
    id,opened:=tree_open(s,&args,&r)
    if !opened {return}
    row,ok:=tree_apply(op,&args,&r)
    if !ok {return}
    labels:=TREE_OP_LABELS
    switch op {
    case .Add,.Set,.Move,.Duplicate: tree_answer(s,call,id,&r,labels[op],row)
    case .Delete,.Variant:
        if tree_write(s,call,id,&r,labels[op]) {api.call_result(call,Ui_Ok).ok=true}
    case .Style,.Anim:
        if tree_write(s,call,id,&r,labels[op]) {api.call_result(call,Tree_Row_Answer)^={ok=true,row=row}}
    }
}

// ---------------------------------------------------------------- reading params

// The params of a call, each key with the text of its value, and what they
// are read against.
@(private)
Tree_Args :: struct {
    call:^api.Call,
    keys:[dynamic]string,
    values:[dynamic]string,
    types:^asset.Types,
    registry:^asset.Registry,
    asset:base.Asset_Id, // the .ui edited; tree_open sets it
    session:^editor.Session,
}

@(private)
tree_malformed :: proc(call:^api.Call,r:^serial.Text_Reader) -> bool {
    line,column:=serial.text_position(call.raw,r.offset)
    api.call_failf(call,api.INVALID_PARAMS,"malformed JSON at line %d column %d",line,column)
    return false
}

// The keys of an object and the texts of their values.
@(private)
tree_object :: proc(call:^api.Call,text:string,what:string) -> (keys,values:[dynamic]string,ok:bool) {
    keys,values=make([dynamic]string,call.allocator),make([dynamic]string,call.allocator)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,call.allocator)
    if !serial.text_accept(&r,'{') {api.call_failf(call,api.INVALID_PARAMS,"%s must be an object",what);return}
    if serial.text_accept(&r,'}') {return keys,values,true}
    for {
        key,read:=serial.text_string(&r)
        if !read || !serial.text_accept(&r,':') {return keys,values,tree_malformed(call,&r)}
        serial.text_space(&r)
        start:=r.offset
        if !serial.text_skip(&r) {return keys,values,tree_malformed(call,&r)}
        append(&keys,strings.clone(key,call.allocator))
        append(&values,text[start:r.offset])
        if serial.text_accept(&r,',') {continue}
        if !serial.text_accept(&r,'}') {return keys,values,tree_malformed(call,&r)}
        return keys,values,true
    }
}

@(private)
tree_args :: proc(s:^editor.Session,call:^api.Call) -> (args:Tree_Args,ok:bool) {
    args.call,args.session=call,s
    if a:=s.app.assets;a!=nil {args.types,args.registry=&a.types,&a.registry}
    args.keys,args.values,ok=tree_object(call,call.raw,"params")
    return
}

// The text of the value of a key; empty and false when the params lack it.
@(private)
tree_arg :: proc(args:^Tree_Args,key:string) -> (text:string,found:bool) {
    for k,i in args.keys {if k==key {return args.values[i],true}}
    return
}

// A string value of a key; found false when absent, ok false after failing the call.
@(private)
tree_arg_string :: proc(args:^Tree_Args,key:string) -> (value:string,found,ok:bool) {
    text,present:=tree_arg(args,key)
    if !present {return "",false,true}
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,args.call.allocator)
    read:bool
    value,read=serial.text_string(&r)
    if !read {api.call_failf(args.call,api.INVALID_PARAMS,"%s must be a string",key);return "",true,false}
    return strings.clone(value,args.call.allocator),true,true
}

@(private)
tree_arg_bool :: proc(args:^Tree_Args,key:string) -> (value,ok:bool) {
    text,present:=tree_arg(args,key)
    if !present {return false,true}
    switch strings.trim_space(text) {
    case "true":  return true,true
    case "false": return false,true
    }
    api.call_failf(args.call,api.INVALID_PARAMS,"%s must be true or false",key)
    return false,false
}

// The records of the .ui the params name.
@(private)
tree_open :: proc(s:^editor.Session,args:^Tree_Args,records:^Records) -> (id:base.Asset_Id,ok:bool) {
    text,found,read:=tree_arg_string(args,"asset")
    if !read {return}
    if !found {api.call_fail(args.call,api.INVALID_PARAMS,"asset is required: the path of a .ui of the project or its id");return}
    problem:string
    if id,problem=editor.asset_resolve(s,text,".ui");problem!="" {api.call_failf(args.call,api.INVALID_PARAMS,"asset: %s",problem);return}
    a:=s.app.assets
    if a==nil || !records_read(a,id,records,args.call.allocator) {
        api.call_failf(args.call,api.INVALID_PARAMS,"asset %s is not a .ui that loads; pass the path of a .ui of the project or its id",text)
        return
    }
    args.asset=id
    return id,true
}

// The row of the node a name or "#row" names; -1 after failing the call.
@(private)
tree_row :: proc(call:^api.Call,r:^Records,name,what:string) -> int {
    if len(name)>1 && name[0]=='#' {
        row:=0
        for c in name[1:] {
            if c<'0' || c>'9' {row=-1;break}
            row=row*10+int(c-'0')
        }
        if row>=0 && row<len(r.nodes) {return row}
        api.call_failf(call,api.INVALID_PARAMS,"%s: the .ui has %d nodes; #row counts from #0",what,len(r.nodes))
        return -1
    }
    for &n,i in r.nodes {if serial.text_field(n.name[:])==name {return i}}
    api.call_failf(call,api.INVALID_PARAMS,"%s: the .ui has no node named '%s'; ui.inspect lists them, and #row names one without a name",what,name)
    return -1
}

// The row of the node a key names; -1 when absent (or failed: ok false).
@(private)
tree_arg_row :: proc(args:^Tree_Args,r:^Records,key:string) -> (row:int,ok:bool) {
    name,found,read:=tree_arg_string(args,key)
    if !read {return -1,false}
    if !found || name=="" {return -1,true}
    row=tree_row(args.call,r,name,key)
    return row,row>=0
}

// The names of the fields of a type, for an error.
@(private)
tree_field_names :: proc(types:^asset.Types,index:serial.Type_Index,skip:[]string) -> string {
    t:=types.schema.types[index]
    b:=strings.builder_make(context.temp_allocator)
    for f in types.schema.fields[t.first:][:t.count] {
        if slice.contains(skip,f.name) {continue}
        if strings.builder_len(b)>0 {strings.write_string(&b,", ")}
        strings.write_string(&b,f.name)
    }
    return strings.to_string(b)
}

// Reads an object of fields of a T into value by their names: what it does
// not name stays. refused: names a call gives by other keys, with why. False
// after failing the call with what is wrong.
@(private)
tree_fields_read :: proc(call:^api.Call,types:^asset.Types,$T:typeid,value:^T,text,what:string,refused:[]string={},why:[]string={}) -> bool {
    index,known:=asset.types_index(types,T)
    if !known {api.call_failf(call,api.SERVER_ERROR,"the types of the assets have no %v",typeid_of(T));return false}
    keys,values:=tree_object(call,text,what) or_return
    t:=types.schema.types[index]
    bytes:=mem.ptr_to_bytes(value)
    for key,i in keys {
        if at,taken:=slice.linear_search(refused,key);taken {
            api.call_failf(call,api.INVALID_PARAMS,"%s.%s: %s",what,key,why[at])
            return false
        }
        field:^serial.Field
        for &f in types.schema.fields[t.first:][:t.count] {if f.name==key {field=&f;break}}
        if field==nil {
            api.call_failf(call,api.INVALID_PARAMS,"%s has no field '%s'; it has %s",what,key,tree_field_names(types,index,refused))
            return false
        }
        r:serial.Text_Reader
        api.call_reader_init(call,&r,tree_broadcast(types,field.type,values[i]))
        if !serial.text_read(&r,&types.schema,field.type,bytes[field.offset:],.Text in field.flags) {
            api.call_failf(call,api.INVALID_PARAMS,"%s",serial.text_error_message(&r,fmt.tprintf("%s.%s",what,key),call.allocator))
            return false
        }
    }
    return true
}

// A number given for an array of numbers stands for each of them: radius 8
// is [8,8,8,8].
@(private)
tree_broadcast :: proc(types:^asset.Types,index:serial.Type_Index,text:string) -> string {
    t:=types.schema.types[index]
    value:=strings.trim_space(text)
    if t.kind!=.Array || t.count==0 || value=="" || !(value[0]=='-' || value[0]>='0' && value[0]<='9') {return text}
    #partial switch types.schema.types[t.elem].kind {
    case .Float,.Int,.Uint:
    case: return text
    }
    b:=strings.builder_make(context.temp_allocator)
    strings.write_byte(&b,'[')
    for i in 0..<t.count {
        if i>0 {strings.write_byte(&b,',')}
        strings.write_string(&b,value)
    }
    strings.write_byte(&b,']')
    return strings.to_string(b)
}

// ---------------------------------------------------------------- nodes

@(private) TREE_NODE_REFUSED :: [?]string{"parent","kind","text","text_id","style","image","anims","component"}
@(private) TREE_NODE_WHY :: [?]string{
    "ui.node.move puts a node in another container",
    "a node keeps its kind: delete it and add one of the other kind",
    "give it with the key text of the params",
    "the translations of a node are its own: ui.text.set sets them",
    "give the name of a style with the key style of the params",
    "give the fields of its image with the key image of the params",
    "give what it plays with the key events of the params",
    "ui.node.add with widget makes an instance of another .ui",
}

// The text, style, fields, image and events the params give a node.
@(private)
tree_node_apply :: proc(args:^Tree_Args,r:^Records,row:int) -> bool {
    call:=args.call
    types:=args.types
    n:=&r.nodes[row]
    if text,found,ok:=tree_arg_string(args,"text");!ok {return false} else if found {records_text_set(r,&n.text,text)}
    if style,found,ok:=tree_arg_string(args,"style");!ok {return false} else if found {
        if style=="" {
            n.style=0
        } else {
            at:=tree_style_row(r,style)
            if at<0 {api.call_failf(call,api.INVALID_PARAMS,"style: the .ui has no style named '%s'; ui.style.set makes it",style);return false}
            n.style=u16(at)
        }
    }
    if fields,found:=tree_arg(args,"fields");found {
        refused,why:=TREE_NODE_REFUSED,TREE_NODE_WHY
        before:=n^
        if !tree_fields_read(call,types,ui.Tree_Node,n,fields,"fields",refused[:],why[:]) {return false}
        if name:=serial.text_field(n.name[:]);name!=serial.text_field(before.name[:]) {
            if !tree_name_free(call,r,row,name) {return false}
        }
    }
    if image,found:=tree_arg(args,"image");found {
        if strings.trim_space(image)=="null" {
            n.image=0
        } else {
            at:=records_image(r,n)
            if at<0 {api.call_fail(call,api.SERVER_ERROR,"the .ui holds no more images");return false}
            if !tree_fields_read(call,types,ui.Tree_Image,&r.images[at],image,"image") {return false}
        }
    }
    if events,found:=tree_arg(args,"events");found {
        keys,values:=tree_object(call,events,"events") or_return
        at:=records_anim_set(r,&r.nodes[row])
        if at<0 {api.call_fail(call,api.SERVER_ERROR,"the .ui holds no more sets of events");return false}
        set:=&r.anim_sets[at]
        for key,i in keys {
            sr:serial.Text_Reader
            serial.text_reader_init(&sr,values[i],call.allocator)
            name,read:=serial.text_string(&sr)
            if !read {api.call_failf(call,api.INVALID_PARAMS,"events.%s must be the name of an animation",key);return false}
            played:ui.Anim
            if name!="" {
                for &a,a_row in r.anims {if serial.text_field(a.name[:])==name {played=ui.Anim(a_row+1);break}}
                if played==0 {api.call_failf(call,api.INVALID_PARAMS,"events.%s: the .ui has no animation named '%s'; ui.anim.set makes it",key,name);return false}
            }
            slot:^ui.Anim
            switch key {
            case "shown":      slot=&set.shown
            case "hidden":     slot=&set.hidden
            case "hovered":    slot=&set.hovered
            case "unhovered":  slot=&set.unhovered
            case "pressed":    slot=&set.pressed
            case "released":   slot=&set.released
            case "focused":    slot=&set.focused
            case "unfocused":  slot=&set.unfocused
            case "selected":   slot=&set.selected
            case "unselected": slot=&set.unselected
            case "clicked":    slot=&set.clicked
            case:
                api.call_failf(call,api.INVALID_PARAMS,"events has no trigger '%s'; it has shown, hidden, hovered, unhovered, pressed, released, focused, unfocused, selected, unselected and clicked",key)
                return false
            }
            slot^=played
        }
    }
    return true
}

// Whether no other node of the file has name.
@(private)
tree_name_free :: proc(call:^api.Call,r:^Records,row:int,name:string) -> bool {
    if name=="" {return true}
    for &other,i in r.nodes {
        if i!=row && serial.text_field(other.name[:])==name {
            api.call_failf(call,api.INVALID_PARAMS,"name: node #%d is named '%s' already; names are unique in a file",i,name)
            return false
        }
    }
    return true
}

// Writes the records and answers with the row and name of a node.
@(private)
tree_answer :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,r:^Records,label:string,row:int) {
    name:=r.nodes[row].name
    if !tree_write(s,call,id,r,label) {return}
    api.call_result(call,Tree_Node_Answer)^={ok=true,row=row,name=name}
}

// Writes the records as one step of history; false after failing the call.
@(private)
tree_write :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,r:^Records,label:string) -> bool {
    message,written:=records_write(s,id,r,label)
    if written {return true}
    api.call_failf(call,api.INVALID_PARAMS,"%s. Nothing changed. A tree loads when containers (Box, Scroll, Switcher, List, Tooltip, Tabs, Popup, Modal, Context_Menu, Radial) hold the nodes, a List holds one node, numbers are finite, keys go in time order and every row it names exists",message)
    return false
}

// The kinds an array of names gives, each taking a style of family; false
// after failing the call.
@(private)
tree_kinds_read :: proc(call:^api.Call,text:string,family:ui.Style_Family) -> (kinds:ui.Node_Kinds,ok:bool) {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,call.allocator)
    if !serial.text_accept(&r,'[') {api.call_fail(call,api.INVALID_PARAMS,"defaults must be an array of kinds of node, as [\"Button\"]");return}
    for count:=0;!serial.text_accept(&r,']');count+=1 {
        if count>0 && !serial.text_accept(&r,',') {tree_malformed(call,&r);return}
        name,read:=serial.text_string(&r)
        if !read {api.call_fail(call,api.INVALID_PARAMS,"defaults must be an array of kinds of node, as [\"Button\"]");return}
        kind:=tree_kind(call,name) or_return
        if style_family(kind)!=family {api.call_failf(call,api.INVALID_PARAMS,"defaults: a %s takes a style of family %s, and this style is of family %s",fmt.tprintf("%v",kind),fmt.tprintf("%v",style_family(kind)),fmt.tprintf("%v",family));return}
        kinds+={kind}
    }
    return kinds,true
}

@(private)
tree_kind :: proc(call:^api.Call,name:string) -> (kind:ui.Node_Kind,ok:bool) {
    for k in ui.Node_Kind {if k!=.Component && fmt.tprintf("%v",k)==name {return k,true}}
    api.call_failf(call,api.INVALID_PARAMS,"kind '%s' is none of Box, Text, Image, Button, Progress, Checkbox, Slider, Field, Number, Selector, Dropdown, Radio, Rich_Text, Prompt, Action_Bar, Scroll, List, Switcher, Tabs, Popup, Modal, Context_Menu, Radial, Tooltip, View, Particles, Spacer; a widget of another .ui goes with widget",name)
    return
}

// Whether parent (-1: the root) takes one more node.
@(private)
tree_takes :: proc(call:^api.Call,r:^Records,parent:int) -> bool {
    if parent<0 {return true}
    p:=&r.nodes[parent]
    if !ui.node_kind_holds(p.kind) {
        api.call_failf(call,api.INVALID_PARAMS,"parent: a %v holds no nodes; Box, Scroll, Switcher, List, Tooltip, Tabs, Popup, Modal, Context_Menu and Radial do",p.kind)
        return false
    }
    if p.kind==.List && records_subtree(r.nodes[:],parent)>0 {
        api.call_fail(call,api.INVALID_PARAMS,"parent: a List holds one node, the one it builds per element; put a Box there to hold more")
        return false
    }
    return true
}

// The keys a child of ui.node.add does not take: it goes inside its node.
@(private) TREE_CHILD_REFUSED :: [?]string{"asset","parent","before"}

// Adds the node the args give inside parent (-1: a root), before the node at
// row before (-1: last), and the nodes its children give inside it. Its row;
// -1 after failing the call.
@(private)
tree_node_add :: proc(args:^Tree_Args,r:^Records,parent,before:int) -> int {
    call:=args.call
    name,named,name_ok:=tree_arg_string(args,"name")
    if !name_ok {return -1}
    if named && !tree_name_free(call,r,-1,name) {return -1}
    row:int
    if widget_text,has_widget,widget_ok:=tree_arg_string(args,"widget");!widget_ok {return -1} else if has_widget {
        widget,problem:=editor.asset_resolve(args.session,widget_text,".ui")
        record,found:=asset.registry_find(args.registry,widget)
        if problem!="" || !found || record.kind!=asset.KIND_UI || widget==args.asset {api.call_failf(call,api.INVALID_PARAMS,"widget '%s' is not another .ui of the project",widget_text);return -1}
        row=records_widget(r,-1,parent,widget,name if named else "widget")
    } else {
        kind_text,has_kind,kind_ok:=tree_arg_string(args,"kind")
        if !kind_ok {return -1}
        if !has_kind {api.call_fail(call,api.INVALID_PARAMS,"kind is required, or widget for an instance of another .ui");return -1}
        kind,known:=tree_kind(call,kind_text)
        if !known {return -1}
        row=records_insert(r,-1,parent,kind)
        if row>=0 && named {ui.tree_text_set(r.nodes[row].name[:],name)}
    }
    if row<0 {api.call_fail(call,api.SERVER_ERROR,"the node could not be added");return -1}
    if before>=0 {
        row=records_place(r,row,parent,before)
        if row<0 {api.call_fail(call,api.SERVER_ERROR,"the node could not be placed before that one");return -1}
    }
    if !tree_node_apply(args,r,row) {return -1}
    text,found:=tree_arg(args,"children")
    if !found {return row}
    list:serial.Text_Reader
    serial.text_reader_init(&list,text,call.allocator)
    if !serial.text_accept(&list,'[') {api.call_fail(call,api.INVALID_PARAMS,"children must be an array of nodes, each with the keys of ui.node.add but asset, parent and before");return -1}
    for at:=0;!serial.text_accept(&list,']');at+=1 {
        if at>0 && !serial.text_accept(&list,',') {tree_malformed(call,&list);return -1}
        serial.text_space(&list)
        start:=list.offset
        if !serial.text_skip(&list) {tree_malformed(call,&list);return -1}
        child:=args^
        ok:bool
        child.keys,child.values,ok=tree_object(call,text[start:list.offset],fmt.tprintf("children[%d]",at))
        if !ok {return -1}
        for key in TREE_CHILD_REFUSED {
            if _,given:=tree_arg(&child,key);given {
                api.call_failf(call,api.INVALID_PARAMS,"children[%d].%s: a child goes last inside the node that holds it",at,key)
                return -1
            }
        }
        // A child goes after what row already holds, so row stays where it is.
        if !tree_takes(call,r,row) || tree_node_add(&child,r,row,-1)<0 {
            call.error.message=api.format_text(call.allocator,"children[%d]: %s",at,call.error.message)
            return -1
        }
    }
    return row
}

@(private)
tree_add_apply :: proc(args:^Tree_Args,r:^Records) -> int {
    call:=args.call
    parent,parent_ok:=tree_arg_row(args,r,"parent")
    if !parent_ok || !tree_takes(call,r,parent) {return -1}
    before,before_ok:=tree_arg_row(args,r,"before")
    if !before_ok {return -1}
    if before>=0 && int(r.nodes[before].parent)!=parent {api.call_failf(call,api.INVALID_PARAMS,"before: node #%d is not inside parent",before);return -1}
    return tree_node_add(args,r,parent,before)
}

// The row of the node the key node names; -1 after failing the call.
@(private)
tree_arg_node :: proc(args:^Tree_Args,r:^Records) -> int {
    row,ok:=tree_arg_row(args,r,"node")
    if !ok {return -1}
    if row<0 {api.call_fail(args.call,api.INVALID_PARAMS,"node is required: its name or #row")}
    return row
}

@(private)
tree_set_apply :: proc(args:^Tree_Args,r:^Records) -> int {
    row:=tree_arg_node(args,r)
    if row<0 {return -1}
    if name,named,name_ok:=tree_arg_string(args,"name");!name_ok {return -1} else if named {
        if !tree_name_free(args.call,r,row,name) {return -1}
        ui.tree_text_set(r.nodes[row].name[:],name)
    }
    if !tree_node_apply(args,r,row) {return -1}
    return row
}

@(private)
tree_move_apply :: proc(args:^Tree_Args,r:^Records) -> int {
    call:=args.call
    row:=tree_arg_node(args,r)
    if row<0 {return -1}
    parent,parent_ok:=tree_arg_row(args,r,"parent")
    if !parent_ok || parent!=int(r.nodes[row].parent) && !tree_takes(call,r,parent) {return -1}
    before,before_ok:=tree_arg_row(args,r,"before")
    if !before_ok {return -1}
    if before>=0 && int(r.nodes[before].parent)!=parent {api.call_failf(call,api.INVALID_PARAMS,"before: node #%d is not inside parent",before);return -1}
    moved:=records_place(r,row,parent,before)
    if moved<0 {api.call_fail(call,api.INVALID_PARAMS,"a node cannot go inside itself or what it holds")}
    return moved
}

@(private)
tree_duplicate_apply :: proc(args:^Tree_Args,r:^Records) -> int {
    row:=tree_arg_node(args,r)
    if row<0 {return -1}
    if r.nodes[row].parent>=0 && !tree_takes(args.call,r,int(r.nodes[row].parent)) {return -1}
    copy:=records_duplicate(r,-1,row)
    if copy<0 {api.call_fail(args.call,api.SERVER_ERROR,"the node could not be copied")}
    return copy
}

@(private)
tree_delete_apply :: proc(args:^Tree_Args,r:^Records) -> bool {
    row:=tree_arg_node(args,r)
    if row<0 {return false}
    records_delete(r,-1,row)
    return true
}

// ---------------------------------------------------------------- styles

// The row of the style named name; -1: none.
@(private)
tree_style_row :: proc(r:^Records,name:string) -> int {
    for &info,i in r.style_infos {if serial.text_field(info.name[:])==name {return i}}
    return -1
}

@(private)
tree_style_apply :: proc(args:^Tree_Args,r:^Records) -> int {
    call:=args.call
    name,_,ok:=tree_arg_string(args,"style")
    if !ok {return -1}
    if name=="" {api.call_fail(call,api.INVALID_PARAMS,"style is required: a name; a node takes its own look with style empty in ui.node.set");return -1}
    row:=tree_style_row(r,name)
    if row<0 {
        family:=ui.Style_Family.Box
        if text,found,family_ok:=tree_arg_string(args,"family");!family_ok {return -1} else if found {
            known:=false
            for f in ui.Style_Family {if fmt.tprintf("%v",f)==text {family,known=f,true}}
            if !known {api.call_failf(call,api.INVALID_PARAMS,"family '%s' is none of Box, Text, Control",text);return -1}
        }
        append(&r.styles,ui.Node_Style{})
        info:=ui.Tree_Style_Info{family=family}
        ui.tree_text_set(info.name[:],name)
        append(&r.style_infos,info)
        row=len(r.styles)-1
    }
    if rename,found,rename_ok:=tree_arg_string(args,"rename");!rename_ok {return -1} else if found {
        if rename=="" || tree_style_row(r,rename)>=0 && tree_style_row(r,rename)!=row {api.call_failf(call,api.INVALID_PARAMS,"rename: '%s' is empty or the name of another style",rename);return -1}
        ui.tree_text_set(r.style_infos[row].name[:],rename)
    }
    if text,found:=tree_arg(args,"defaults");found {
        kinds,read:=tree_kinds_read(call,text,r.style_infos[row].family)
        if !read {return -1}
        r.style_infos[row].defaults={}
        records_kind_style_set(r,row,kinds)
    }
    if fields,found:=tree_arg(args,"fields");found {
        if !tree_fields_read(call,args.types,ui.Node_Style,&r.styles[row],fields,"fields") {return -1}
    }
    return row
}

// What fields of a patch the keys of an object of fields of a Node_Style set.
@(private)
tree_patch_fields :: proc(call:^api.Call,text:string) -> (fields:ui.Style_Fields,ok:bool) {
    keys,values:=tree_object(call,text,"fields") or_return
    for key,i in keys {
        switch key {
        case "fill":         fields+={.Fill}
        case "fill2":        fields+={.Fill2}
        case "stroke":       fields+={.Stroke}
        case "track":        fields+={.Track}
        case "knob":         fields+={.Knob}
        case "mark":         fields+={.Mark}
        case "radius":       fields+={.Radius}
        case "stroke_width": fields+={.Stroke_Width}
        case "shadow","shadow_color","shadow_blur","shadow_offset": fields+={.Shadow}
        case "text":
            text_keys,_:=tree_object(call,values[i],"fields.text") or_return
            for t in text_keys {
                switch t {
                case "font":                    fields+={.Text_Font}
                case "size":                    fields+={.Text_Size}
                case "color":                   fields+={.Text_Color}
                case "outline","outline_color": fields+={.Text_Outline}
                case "shadow","shadow_color":   fields+={.Text_Shadow}
                case:
                    api.call_failf(call,api.INVALID_PARAMS,"fields.text.%s stays as the style has it: a rule sets font, size, color, outline, outline_color, shadow and shadow_color",t)
                    return
                }
            }
        case:
            api.call_failf(call,api.INVALID_PARAMS,"fields.%s stays as the style has it: a rule sets fill, fill2, stroke, track, knob, mark, radius, stroke_width, shadow, shadow_color, shadow_blur, shadow_offset and text",key)
            return
        }
    }
    return fields,true
}

@(private)
tree_variant_apply :: proc(args:^Tree_Args,r:^Records) -> bool {
    call:=args.call
    style_name,_,ok:=tree_arg_string(args,"style")
    if !ok {return false}
    style:=tree_style_row(r,style_name)
    if style<0 {api.call_failf(call,api.INVALID_PARAMS,"style: the .ui has no style named '%s'; ui.style.set makes it",style_name);return false}
    return tree_rule_apply(args,r,style)
}

// Makes, changes or removes the rule of the style at row for the variant and
// states the args give.
@(private)
tree_rule_apply :: proc(args:^Tree_Args,r:^Records,style:int) -> bool {
    call:=args.call
    variant,_,variant_ok:=tree_arg_string(args,"variant")
    if !variant_ok {return false}
    states:ui.Style_States
    if text,found:=tree_arg(args,"states");found {
        r_states:serial.Text_Reader
        serial.text_reader_init(&r_states,text,call.allocator)
        if !serial.text_accept(&r_states,'[') {api.call_fail(call,api.INVALID_PARAMS,"states must be an array of names");return false}
        for count:=0;!serial.text_accept(&r_states,']');count+=1 {
            if count>0 && !serial.text_accept(&r_states,',') {tree_malformed(call,&r_states);return false}
            name,read:=serial.text_string(&r_states)
            known:=false
            for state in ui.Style_State {if read && fmt.tprintf("%v",state)==name {states+={state};known=true}}
            if !known {api.call_failf(call,api.INVALID_PARAMS,"states: '%s' is none of Selected, Hovered, Focused, Over, Pressed, Disabled",name);return false}
        }
    }
    at:=-1
    for &v,i in r.variants {
        if int(v.style)==style && v.states==states && serial.text_field(v.variant[:])==variant {at=i;break}
    }
    remove,remove_ok:=tree_arg_bool(args,"remove")
    if !remove_ok {return false}
    if remove {
        if at<0 {api.call_fail(call,api.INVALID_PARAMS,"the style has no rule for that variant and those states");return false}
        ordered_remove(&r.variants,at)
    } else {
        if at<0 {
            rule:=ui.Tree_Style_Variant{style=u16(style),states=states}
            ui.tree_text_set(rule.variant[:],variant)
            append(&r.variants,rule)
            at=len(r.variants)-1
        }
        rule:=&r.variants[at]
        if fields,found:=tree_arg(args,"fields");found {
            set,set_ok:=tree_patch_fields(call,fields)
            if !set_ok {return false}
            if !tree_fields_read(call,args.types,ui.Node_Style,&rule.patch.values,fields,"fields") {return false}
            rule.patch.fields+=set
        }
        if tokens,found:=tree_arg(args,"tokens");found {
            if !tree_fields_read(call,args.types,ui.Style_Tokens,&rule.patch.tokens,tokens,"tokens") {return false}
            t:=rule.patch.tokens
            if t.fill!=.Literal {rule.patch.fields+={.Fill}}
            if t.fill2!=.Literal {rule.patch.fields+={.Fill2}}
            if t.stroke!=.Literal {rule.patch.fields+={.Stroke}}
            if t.text!=.Literal {rule.patch.fields+={.Text_Color}}
            if t.track!=.Literal {rule.patch.fields+={.Track}}
            if t.knob!=.Literal {rule.patch.fields+={.Knob}}
            if t.mark!=.Literal {rule.patch.fields+={.Mark}}
        }
    }
    return true
}

// ---------------------------------------------------------------- animations

@(private)
tree_anim_apply :: proc(args:^Tree_Args,r:^Records) -> int {
    call:=args.call
    name,_,ok:=tree_arg_string(args,"name")
    if !ok {return -1}
    if name=="" || len(name)>=ui.TREE_NAME_CAPACITY {api.call_failf(call,api.INVALID_PARAMS,"name is required, shorter than %d bytes",ui.TREE_NAME_CAPACITY);return -1}
    row:=-1
    for &a,i in r.anims {if serial.text_field(a.name[:])==name {row=i;break}}
    anim:ui.Tree_Anim
    if row>=0 {anim=r.anims[row]} else {ui.tree_text_set(anim.name[:],name)}
    if text,found,kind_ok:=tree_arg_string(args,"kind");!kind_ok {return -1} else if found {
        known:=false
        for k in ui.Anim_Kind {if fmt.tprintf("%v",k)==text {anim.kind,known=k,true}}
        if !known {api.call_failf(call,api.INVALID_PARAMS,"kind '%s' is none of Clip, Sequence, Parallel",text);return -1}
    }
    if text,found,loop_ok:=tree_arg_string(args,"loop");!loop_ok {return -1} else if found {
        known:=false
        for l in ui.Anim_Loop {if fmt.tprintf("%v",l)==text {anim.loop,known=l,true}}
        if !known {api.call_failf(call,api.INVALID_PARAMS,"loop '%s' is none of Once, Loop, Ping_Pong",text);return -1}
    }
    types:=args.types
    switch anim.kind {
    case .Clip:
        text,found:=tree_arg(args,"tracks")
        if !found && row<0 {api.call_fail(call,api.INVALID_PARAMS,"tracks is required for a new Clip");return -1}
        if found {
            tracks:=make([dynamic]ui.Tree_Track,call.allocator)
            keys:=make([dynamic]ui.Keyframe,call.allocator)
            if !tree_tracks_read(call,types,text,&tracks,&keys) {return -1}
            anim.first,anim.count=u32(len(r.tracks)),u32(len(tracks))
            for &t in tracks {t.first_key+=u32(len(r.keys))}
            append(&r.tracks,..tracks[:])
            append(&r.keys,..keys[:])
        }
    case .Sequence,.Parallel:
        text,found:=tree_arg(args,"parts")
        if !found && row<0 {api.call_fail(call,api.INVALID_PARAMS,"parts is required for a new Sequence or Parallel");return -1}
        if found {
            pr:serial.Text_Reader
            serial.text_reader_init(&pr,text,call.allocator)
            if !serial.text_accept(&pr,'[') {api.call_fail(call,api.INVALID_PARAMS,"parts must be an array of names");return -1}
            first:=u32(len(r.parts))
            for count:=0;!serial.text_accept(&pr,']');count+=1 {
                if count>0 && !serial.text_accept(&pr,',') {tree_malformed(call,&pr);return -1}
                part,read:=serial.text_string(&pr)
                found_row:=-1
                for &a,i in r.anims {if read && serial.text_field(a.name[:])==part {found_row=i;break}}
                limit:=row if row>=0 else len(r.anims)
                if found_row<0 || found_row>=limit {api.call_failf(call,api.INVALID_PARAMS,"parts: '%s' is not an animation made before '%s'",part,name);return -1}
                append(&r.parts,ui.Anim(found_row+1))
            }
            anim.first,anim.count=first,u32(len(r.parts))-first
        }
    }
    if row>=0 {r.anims[row]=anim} else {append(&r.anims,anim);row=len(r.anims)-1}
    return row
}

// Reads the tracks of a clip: each a property and its keys, put in time order.
@(private)
tree_tracks_read :: proc(call:^api.Call,types:^asset.Types,text:string,tracks:^[dynamic]ui.Tree_Track,keys:^[dynamic]ui.Keyframe) -> bool {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,call.allocator)
    if !serial.text_accept(&r,'[') {api.call_fail(call,api.INVALID_PARAMS,"tracks must be an array of {property, keys}");return false}
    for count:=0;!serial.text_accept(&r,']');count+=1 {
        if count>0 && !serial.text_accept(&r,',') {return tree_malformed(call,&r)}
        if count>=ui.TREE_CLIP_TRACKS {api.call_failf(call,api.INVALID_PARAMS,"a clip has at most %d tracks",ui.TREE_CLIP_TRACKS);return false}
        serial.text_space(&r)
        start:=r.offset
        if !serial.text_skip(&r) {return tree_malformed(call,&r)}
        what:=fmt.tprintf("tracks[%d]",count)
        object_keys,object_values:=tree_object(call,text[start:r.offset],what) or_return
        track:=ui.Tree_Track{first_key=u32(len(keys))}
        has_property:=false
        for key,i in object_keys {
            switch key {
            case "property":
                pr:serial.Text_Reader
                serial.text_reader_init(&pr,object_values[i],call.allocator)
                name,_:=serial.text_string(&pr)
                for p in ui.Anim_Property {if fmt.tprintf("%v",p)==name {track.property,has_property=p,true}}
                if !has_property {api.call_failf(call,api.INVALID_PARAMS,"%s.property '%s' is none of Offset, Scale, Rotation, Opacity, Color, Width, Height, Value, Frame, Reveal",what,name);return false}
            case "keys":
                kr:serial.Text_Reader
                serial.text_reader_init(&kr,object_values[i],call.allocator)
                if !serial.text_accept(&kr,'[') {api.call_failf(call,api.INVALID_PARAMS,"%s.keys must be an array of {time, value, ease}",what);return false}
                for k:=0;!serial.text_accept(&kr,']');k+=1 {
                    if k>0 && !serial.text_accept(&kr,',') {return tree_malformed(call,&kr)}
                    serial.text_space(&kr)
                    key_start:=kr.offset
                    if !serial.text_skip(&kr) {return tree_malformed(call,&kr)}
                    key:ui.Keyframe
                    if !tree_fields_read(call,types,ui.Keyframe,&key,object_values[i][key_start:kr.offset],fmt.tprintf("%s.keys[%d]",what,k)) {return false}
                    if key.time<0 || key.time-key.time!=0 {api.call_failf(call,api.INVALID_PARAMS,"%s.keys[%d].time must be a finite number of seconds, 0 or more",what,k);return false}
                    append(keys,key)
                }
            case:
                api.call_failf(call,api.INVALID_PARAMS,"%s has no '%s'; a track has property and keys",what,key)
                return false
            }
        }
        if !has_property {api.call_failf(call,api.INVALID_PARAMS,"%s.property is required",what);return false}
        track.key_count=u32(len(keys))-track.first_key
        run:=keys[track.first_key:]
        slice.sort_by(run,proc(a,b:ui.Keyframe) -> bool {return a.time<b.time})
        append(tracks,track)
    }
    return true
}

// ---------------------------------------------------------------- inspect

@(private)
api_tree_inspect :: proc(s:^editor.Session,call:^api.Call) {
    args,args_ok:=tree_args(s,call)
    if !args_ok {return}
    r:Records
    _,opened:=tree_open(s,&args,&r)
    if !opened {return}
    root,root_ok:=tree_arg_row(&args,&r,"node")
    if !root_ok {return}
    a:=s.app.assets
    out:=call.out
    serial.write_u8(out,'{')
    api.write_key(out,"document",true)
    document_write(out,&a.types,&r,root)
    api.write_key(out,"widgets");serial.write_u8(out,'[')
    first:=true
    for &template in r.templates {
        if template.component.widget=={} {continue}
        if !first {serial.write_u8(out,',')}
        first=false
        serial.write_u8(out,'{')
        api.write_text(out,"name",serial.text_field(template.component.name[:]),true)
        api.write_key(out,"asset");serial.write_u8(out,'"');serial.text_write_asset_id(out,template.component.widget);serial.write_u8(out,'"')
        api.write_text(out,"title",editor.asset_name_of(a,template.component.widget,"missing"))
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    api.write_key(out,"fonts");serial.write_u8(out,'[')
    for font,i in r.fonts {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'"');serial.text_write_asset_id(out,font.font);serial.write_u8(out,'"')
    }
    serial.write_u8(out,']')
    serial.write_u8(out,'}')
}

Tree_Write_Answer :: struct {
    ok:bool,
    made:int `mirai:"label=Nodes the document made"`,
    removed:int `mirai:"label=Nodes it took away, with what they held"`,
}

@(private)
api_tree_write :: proc(s:^editor.Session,call:^api.Call) {
    args,args_ok:=tree_args(s,call)
    if !args_ok {return}
    for key in args.keys {
        if key!="asset" && key!="node" && key!="document" {api.call_failf(call,api.INVALID_PARAMS,"ui.write has no '%s'; it has asset, node and document",key);return}
    }
    text,found:=tree_arg(&args,"document")
    if !found {api.call_fail(call,api.INVALID_PARAMS,"document is required: as ui.inspect gives it, with what it declares");return}
    r:Records
    id,opened:=tree_open(s,&args,&r)
    if !opened {return}
    root,root_ok:=tree_arg_row(&args,&r,"node")
    if !root_ok {return}
    made,removed,applied:=document_apply(&args,&r,root,text)
    if !applied || !tree_write(s,call,id,&r,"Write") {return}
    api.call_result(call,Tree_Write_Answer)^={ok=true,made=made,removed=removed}
}
