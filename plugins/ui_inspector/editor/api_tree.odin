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
// file say what a document declares. A node is named by its name, or by
// "#row". Each call is one step of the history of the file, which waits for
// Save; a call that would leave a tree that does not load changes nothing and
// says why.

@(storage)
Ui_Tree_Api :: struct {provider:editor.Api_Provider}
ui_tree_api_default :: proc() -> Ui_Tree_Api {return {provider={register=tree_api_register}}}

@(private) TREE_ASSET_SCHEMA :: `"asset":{"type":"string","description":"the path of a .ui of the project (hud/hud.ui), or its id"}`
@(private) TREE_INSPECT_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset"],"properties":{` + TREE_ASSET_SCHEMA + `,"node":{"type":"string","description":"name or #row: that node and what it holds, with the styles and animations they take; absent: the whole file"}}}`
@(private) TREE_WRITE_SCHEMA :: `{"type":"object","additionalProperties":false,"required":["asset","document"],"properties":{` + TREE_ASSET_SCHEMA + `,"node":{"type":"string","description":"name or #row: the document declares that node and what it holds, and nothing else of the file changes; absent: the whole file"},"document":{"type":"object","description":"as ui.inspect gives it: use (paths of the .ui it takes styles and tokens from, and widgets), params of the widget this file is (name to node.field, node.parameter of a use, or field of its root), tokens, styles and animations by name, and nodes nested, each {name, kind (a Node_Kind, or the name of the file of a widget it uses), text, style, the keys of its layout (width, height, gap...), events, slot, children}; a use also the parameters of its widget. tokens, styles and animations it names become what it says, null takes one away, the others stay; the nodes of the file, or of node, become these, matched by name and kind. Without nodes, no node changes"},"save":{"type":"boolean","description":"writes the file now, as asset.save does, instead of leaving it for Save; a path that does not exist yet makes the .ui"}}}`

// Bytes of a text of a result that no capacity of its own bounds.
@(private) RESULT_TEXT_BYTES :: 256*1024

Ui_Ok :: struct {ok:bool}

Tree_Inspect :: struct {
    document:Tree_Document `mirai:"label=What ui.write takes back"`,
}
Tree_Document :: struct {
    use:u8 `mirai:"any,optional,label=The paths of the .ui it takes styles and tokens from and whose widgets its nodes name by the name of their file"`,
    params:u8 `mirai:"any,optional,label=What the widget of this file takes, by name: node.field, node.parameter of a use it holds, or the field of its root"`,
    tokens:u8 `mirai:"any,optional,label=By name: a color or a number that styles name"`,
    styles:u8 `mirai:"any,label=The named styles, or those its nodes take, by name: extends, family, defaults (the kinds whose new nodes take it), its keys (fill, size, width, shadow...), the states hover, focus, pressed, disabled, selected and over, variants by name, and rules {variant, states, tokens and the keys of a state}"`,
    animations:u8 `mirai:"any,label=By name: kind, loop, and from-to properties with seconds and ease, tracks of a Clip or parts of a Sequence or a Parallel"`,
    nodes:[1]Tree_Document_Node `mirai:"list,label=The roots in order, each also with the keys of ui.Tree_Node and of its layout that differ from a new node of its kind, and a use with the parameters of its widget; with node, that node alone"`,
}
Tree_Document_Node :: struct {
    name:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,label=What ui.write matches it by"`,
    kind:u8 `mirai:"any,optional,label=A ui.Node_Kind, or the name of the file of a widget it uses"`,
    text:[RESULT_TEXT_BYTES]u8 `mirai:"text,optional,label=In the language interfaces are written in"`,
    style:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,optional,label=The named style it takes; empty: none, where its kind would take one; absent: the one its kind takes"`,
    look:u8 `mirai:"any,optional,label=Its own look, instead of style: a style without family; with extends it says what it changes of that style, which it follows otherwise"`,
    image:ui.Tree_Image `mirai:"optional"`,
    events:u8 `mirai:"any,optional,label=By trigger (shown, hovered, clicked, ...): the animation it plays"`,
    slot:bool `mirai:"optional,label=Whether it takes what a use of this widget holds"`,
    children:u8 `mirai:"any,optional,label=The nodes it holds, in order, as this one"`,
}

@(private)
tree_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="ui.inspect",summary="A .ui, or one of its nodes, as the document ui.write takes back: its nodes nested, each with what differs from a new node of its kind, and the styles and animations they take.",params_schema=TREE_INSPECT_SCHEMA,result=Tree_Inspect,result_info=type_info_of(Tree_Inspect),writes_result=true,flags={.Read_Only},run=api_tree_inspect})
    editor.api_method_register(s,{name="ui.write",summary="Makes a .ui, or one of its nodes, say what a document declares, as ui.inspect gives it; a widget is a .ui of its own and another uses it by name through use. Nodes matched by name keep their translations, the others are made and those it does not declare go. One step of history; the file waits for Save, or for save:true. On the command line document=@file reads it from a file, and a path that does not exist yet makes the .ui.",params_schema=TREE_WRITE_SCHEMA,result=Tree_Write_Answer,result_info=type_info_of(Tree_Write_Answer),run=api_tree_write})
    capture_api_register(s)
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
    assets:^host.Assets,
    libs:^[dynamic]Doc_Lib, // the files a document takes names from
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
    if a:=s.app.assets;a!=nil {args.types,args.registry,args.assets=&a.types,&a.registry,a}
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
    read:bool
    value,read=doc_string(args.call,text)
    if !read {api.call_failf(args.call,api.INVALID_PARAMS,"%s must be a string",key);return "",true,false}
    return value,true,true
}

@(private)
tree_arg_bool :: proc(args:^Tree_Args,key:string) -> (value,ok:bool) {
    text,present:=tree_arg(args,key)
    if !present {return false,true}
    value,ok=doc_bool(text)
    if !ok {api.call_failf(args.call,api.INVALID_PARAMS,"%s must be true or false",key)}
    return
}

// The records of the .ui the params name.
@(private)
tree_open :: proc(s:^editor.Session,args:^Tree_Args,records:^Records) -> (id:base.Asset_Id,ok:bool) {
    text,found,read:=tree_arg_string(args,"asset")
    if !read {return}
    if !found {api.call_fail(args.call,api.INVALID_PARAMS,"asset is required: the path of a .ui of the project or its id");return}
    problem:string
    if id,problem=editor.asset_resolve(s,tree_asset_path(text),".ui");problem!="" {api.call_failf(args.call,api.INVALID_PARAMS,"asset: %s",problem);return}
    a:=s.app.assets
    if a==nil || !records_read(a,id,records,context.temp_allocator) {
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

// What a node does not give by the keys of a document, with where it goes instead.
@(private) TREE_NODE_REFUSED :: [?]string{"parent","text_id","anims","component"}
@(private) TREE_NODE_WHY :: [?]string{
    "what a node holds goes in its children",
    "the translations of a node are its own: ui.text.set sets them",
    "give what it plays with the key events",
    "a use names its widget by the name of its file in kind",
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
    items:=doc_items(call,text,"defaults",`kinds of node, as ["Button"]`) or_return
    for item in items {
        name,read:=doc_string(call,item)
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
    api.call_failf(call,api.INVALID_PARAMS,"kind '%s' is none of Box, Text, Image, Button, Progress, Checkbox, Slider, Field, Number, Selector, Dropdown, Radio, Rich_Text, Prompt, Action_Bar, Scroll, List, Switcher, Tabs, Popup, Modal, Context_Menu, Radial, Tooltip, View, Particles, Spacer, or the name of the file of a widget the document uses",name)
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

// ---------------------------------------------------------------- styles

// The row of the style named name; -1: none.
@(private)
tree_style_row :: proc(r:^Records,name:string) -> int {
    for &info,i in r.style_infos {if serial.text_field(info.name[:])==name {return i}}
    return -1
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
            items,listed:=doc_items(call,text,"parts","names")
            if !listed {return -1}
            first:=u32(len(r.parts))
            for item in items {
                part,read:=doc_string(call,item)
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
    items:=doc_items(call,text,"tracks","{property, keys}") or_return
    for item,count in items {
        if count>=ui.TREE_CLIP_TRACKS {api.call_failf(call,api.INVALID_PARAMS,"a clip has at most %d tracks",ui.TREE_CLIP_TRACKS);return false}
        what:=fmt.tprintf("tracks[%d]",count)
        object_keys,object_values:=tree_object(call,item,what) or_return
        track:=ui.Tree_Track{first_key=u32(len(keys))}
        has_property:=false
        for key,i in object_keys {
            switch key {
            case "property":
                name,_:=doc_string(call,object_values[i])
                for p in ui.Anim_Property {if fmt.tprintf("%v",p)==name {track.property,has_property=p,true}}
                if !has_property {api.call_failf(call,api.INVALID_PARAMS,"%s.property '%s' is none of Offset, Scale, Rotation, Opacity, Color, Width, Height, Value, Frame, Reveal",what,name);return false}
            case "keys":
                key_items:=doc_items(call,object_values[i],fmt.tprintf("%s.keys",what),"{time, value, ease}") or_return
                for key_item,k in key_items {
                    key:ui.Keyframe
                    if !tree_fields_read(call,types,ui.Keyframe,&key,key_item,fmt.tprintf("%s.keys[%d]",what,k)) {return false}
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
    libs:=doc_libs(&args,&r)
    serial.write_u8(out,'{')
    api.write_key(out,"document",true)
    document_write(out,&a.types,&r,root,libs[:],a)
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
        if key!="asset" && key!="node" && key!="document" && key!="save" {api.call_failf(call,api.INVALID_PARAMS,"ui.write has no '%s'; it has asset, node, document and save",key);return}
    }
    text,found:=tree_arg(&args,"document")
    if !found {api.call_fail(call,api.INVALID_PARAMS,"document is required: as ui.inspect gives it, with what it declares; on the command line document=@file reads it from a file");return}
    save,save_ok:=tree_arg_bool(&args,"save")
    if !save_ok {return}
    if save && !editor.api_guard(s,call) {return}
    // A path that names nothing yet makes the .ui.
    if !tree_asset_make(s,&args) {return}
    r:Records
    id,opened:=tree_open(s,&args,&r)
    if !opened {return}
    root,root_ok:=tree_arg_row(&args,&r,"node")
    if !root_ok {return}
    made,removed,applied:=document_apply(&args,&r,root,text)
    if !applied || !tree_write(s,call,id,&r,"Write") {return}
    if save {
        record,recorded:=asset.registry_find(&s.app.assets.registry,id)
        if !recorded {api.call_fail(call,api.SERVER_ERROR,"the .ui it wrote is not in the assets");return}
        if _,failures:=editor.assets_write(s,{record.path});failures!="" {api.call_failf(call,api.SERVER_ERROR,"the .ui stays unsaved: %s",failures);return}
    }
    api.call_result(call,Tree_Write_Answer)^={ok=true,made=made,removed=removed}
}

// Makes the empty .ui the path of the params names when it does not exist
// yet; false after failing the call.
@(private)
tree_asset_make :: proc(s:^editor.Session,args:^Tree_Args) -> bool {
    call:=args.call
    text,_,read:=tree_arg_string(args,"asset")
    if !read {return false}
    path:=tree_asset_path(text)
    if !strings.has_suffix(path,".ui") || strings.contains_rune(path,':') {return true}
    a:=s.app.assets
    if a==nil {return true}
    host.assets_scan(a)
    if _,exists:=asset.registry_find_path(&a.registry,path);exists {return true}
    id:=editor.asset_id_new(s)
    if problem:=editor.asset_create(s,asset.KIND_UI,path,id);problem!="" {
        api.call_failf(call,api.INVALID_PARAMS,"asset: %s",problem)
        return false
    }
    return true
}

// The path of a .ui as the registry names it: under the folder of the assets.
@(private)
tree_asset_path :: proc(path:string) -> string {return strings.trim_prefix(path,"assets/")}
