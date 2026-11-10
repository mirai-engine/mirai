package author

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// ---------------------------------------------------------------- reading params

// The params of a reading, each key with the text of its value, and what they
// are read against.
Tree_Args :: struct {
    reading:^Reading,
    keys:[dynamic]string,
    values:[dynamic]string,
    types:^asset.Types,
    registry:^asset.Registry,
    asset:base.Asset_Id, // the .ui edited
    assets:Assets,
    info:^core.World_Info,  // the types of the game the paths of a document are checked against; nil: none are
    texts:^Texts,           // of the assets: what a node with a key sets; whoever writes the document writes texts_written
    libs:^[dynamic]Doc_Lib, // the files a document takes names from
}

tree_malformed :: proc(reading:^Reading,r:^serial.Text_Reader) -> bool {
    line,column:=serial.text_position(reading.raw,r.offset)
    reading_failf(reading,"malformed JSON at line %d column %d",line,column)
    return false
}

// The keys of an object and the texts of their values.
tree_object :: proc(reading:^Reading,text:string,what:string) -> (keys,values:[dynamic]string,ok:bool) {
    keys,values=make([dynamic]string,reading.allocator),make([dynamic]string,reading.allocator)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,reading.allocator)
    if !serial.text_accept(&r,'{') {reading_failf(reading,"%s must be an object",what);return}
    if serial.text_accept(&r,'}') {return keys,values,true}
    for {
        key,read:=serial.text_string(&r)
        if !read || !serial.text_accept(&r,':') {return keys,values,tree_malformed(reading,&r)}
        serial.text_space(&r)
        start:=r.offset
        if !serial.text_skip(&r) {return keys,values,tree_malformed(reading,&r)}
        append(&keys,strings.clone(key,reading.allocator))
        append(&values,text[start:r.offset])
        if serial.text_accept(&r,',') {continue}
        if !serial.text_accept(&r,'}') {return keys,values,tree_malformed(reading,&r)}
        return keys,values,true
    }
}

// The params of a reading, read against the assets, the types of the game
// and its texts.
tree_args :: proc(reading:^Reading,a:Assets,info:^core.World_Info,texts:^Texts) -> (args:Tree_Args,ok:bool) {
    args.reading,args.info,args.texts=reading,info,texts
    if a.registry!=nil {args.types,args.registry,args.assets=a.types,a.registry,a}
    args.keys,args.values,ok=tree_object(reading,reading.raw,"params")
    return
}

// The text of the value of a key; empty and false when the params lack it.
tree_arg :: proc(args:^Tree_Args,key:string) -> (text:string,found:bool) {
    for k,i in args.keys {if k==key {return args.values[i],true}}
    return
}

// A string value of a key; found false when absent, ok false after failing the reading.
tree_arg_string :: proc(args:^Tree_Args,key:string) -> (value:string,found,ok:bool) {
    text,present:=tree_arg(args,key)
    if !present {return "",false,true}
    read:bool
    value,read=doc_string(args.reading,text)
    if !read {reading_failf(args.reading,"%s must be a string",key);return "",true,false}
    return value,true,true
}

tree_arg_bool :: proc(args:^Tree_Args,key:string) -> (value,ok:bool) {
    text,present:=tree_arg(args,key)
    if !present {return false,true}
    value,ok=doc_bool(text)
    if !ok {reading_failf(args.reading,"%s must be true or false",key)}
    return
}

// The row of the node a name or "#row" names; -1 after failing the reading.
tree_row :: proc(reading:^Reading,r:^Records,name,what:string) -> int {
    if len(name)>1 && name[0]=='#' {
        row:=0
        for c in name[1:] {
            if c<'0' || c>'9' {row=-1;break}
            row=row*10+int(c-'0')
        }
        if row>=0 && row<len(r.nodes) {return row}
        reading_failf(reading,"%s: the .ui has %d nodes; #row counts from #0",what,len(r.nodes))
        return -1
    }
    for &n,i in r.nodes {if serial.text_field(n.name[:])==name {return i}}
    reading_failf(reading,"%s: the .ui has no node named '%s'; ui.inspect lists them, and #row names one without a name",what,name)
    return -1
}

// The row of the node a key names; -1 when absent (or failed: ok false).
tree_arg_row :: proc(args:^Tree_Args,r:^Records,key:string) -> (row:int,ok:bool) {
    name,found,read:=tree_arg_string(args,key)
    if !read {return -1,false}
    if !found || name=="" {return -1,true}
    row=tree_row(args.reading,r,name,key)
    return row,row>=0
}

// The names of the fields of a type, for an error.
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
// not name stays. refused: names a reading gives by other keys, with why. False
// after failing the reading with what is wrong.
tree_fields_read :: proc(reading:^Reading,types:^asset.Types,$T:typeid,value:^T,text,what:string,refused:[]string={},why:[]string={}) -> bool {
    index,known:=asset.types_index(types,T)
    if !known {reading_brokef(reading,"the types of the assets have no %v",typeid_of(T));return false}
    keys,values:=tree_object(reading,text,what) or_return
    t:=types.schema.types[index]
    bytes:=mem.ptr_to_bytes(value)
    for key,i in keys {
        if at,taken:=slice.linear_search(refused,key);taken {
            reading_failf(reading,"%s.%s: %s",what,key,why[at])
            return false
        }
        field:^serial.Field
        for &f in types.schema.fields[t.first:][:t.count] {if f.name==key {field=&f;break}}
        if field==nil {
            reading_failf(reading,"%s has no field '%s'; it has %s",what,key,tree_field_names(types,index,refused))
            return false
        }
        r:serial.Text_Reader
        reading_reader(reading,&r,tree_broadcast(types,field.type,values[i]))
        if !serial.text_read(&r,&types.schema,field.type,bytes[field.offset:],.Text in field.flags) {
            reading_failf(reading,"%s",serial.text_error_message(&r,fmt.tprintf("%s.%s",what,key),reading.allocator))
            return false
        }
    }
    return true
}

// A number given for an array of numbers stands for each of them: radius 8
// is [8,8,8,8].
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
TREE_NODE_REFUSED :: [?]string{"parent","anims","component"}
TREE_NODE_WHY :: [?]string{
    "what a node holds goes in its children",
    "give what it plays with the key events",
    "a use names its widget by the name of its file in kind",
}

// Whether no other node of the file has name.
tree_name_free :: proc(reading:^Reading,r:^Records,row:int,name:string) -> bool {
    if name=="" {return true}
    for &other,i in r.nodes {
        if i!=row && serial.text_field(other.name[:])==name {
            reading_failf(reading,"name: node #%d is named '%s' already; names are unique in a file",i,name)
            return false
        }
    }
    return true
}

// The kinds an array of names gives, each taking a style of family; false
// after failing the reading.
tree_kinds_read :: proc(reading:^Reading,text:string,family:ui.Style_Family) -> (kinds:ui.Node_Kinds,ok:bool) {
    items:=doc_items(reading,text,"defaults",`kinds of node, as ["Button"]`) or_return
    for item in items {
        name,read:=doc_string(reading,item)
        if !read {reading_fail(reading,"defaults must be an array of kinds of node, as [\"Button\"]");return}
        kind:=tree_kind(reading,name) or_return
        if style_family(kind)!=family {reading_failf(reading,"defaults: a %s takes a style of family %s, and this style is of family %s",fmt.tprintf("%v",kind),fmt.tprintf("%v",style_family(kind)),fmt.tprintf("%v",family));return}
        kinds+={kind}
    }
    return kinds,true
}

tree_kind :: proc(reading:^Reading,name:string) -> (kind:ui.Node_Kind,ok:bool) {
    for k in ui.Node_Kind {if k!=.Component && fmt.tprintf("%v",k)==name {return k,true}}
    reading_failf(reading,"kind '%s' is none of Box, Text, Image, Button, Progress, Checkbox, Slider, Field, Number, Selector, Dropdown, Radio, Rich_Text, Prompt, Action_Bar, Scroll, List, Switcher, Tabs, Popup, Modal, Context_Menu, Radial, Tooltip, View, Particles, Draw, Spacer, or the name of the file of a widget the document uses",name)
    return
}

// Whether parent (-1: the root) takes one more node.
tree_takes :: proc(reading:^Reading,r:^Records,parent:int) -> bool {
    if parent<0 {return true}
    p:=&r.nodes[parent]
    if !ui.node_kind_holds(p.kind) {
        reading_failf(reading,"parent: a %v holds no nodes; Box, Scroll, Switcher, List, Tooltip, Tabs, Popup, Modal, Context_Menu and Radial do",p.kind)
        return false
    }
    if p.kind==.List && records_subtree(r.nodes[:],parent)>0 {
        reading_fail(reading,"parent: a List holds one node, the one it builds per element; put a Box there to hold more")
        return false
    }
    return true
}

// ---------------------------------------------------------------- styles

// The row of the style named name; -1: none.
tree_style_row :: proc(r:^Records,name:string) -> int {
    for &info,i in r.style_infos {if serial.text_field(info.name[:])==name {return i}}
    return -1
}

// ---------------------------------------------------------------- animations

tree_anim_apply :: proc(args:^Tree_Args,r:^Records) -> int {
    reading:=args.reading
    name,_,ok:=tree_arg_string(args,"name")
    if !ok {return -1}
    if name=="" || len(name)>=ui.TREE_NAME_CAPACITY {reading_failf(reading,"name is required, shorter than %d bytes",ui.TREE_NAME_CAPACITY);return -1}
    row:=-1
    for &a,i in r.anims {if serial.text_field(a.name[:])==name {row=i;break}}
    anim:ui.Tree_Anim
    if row>=0 {anim=r.anims[row]} else {ui.tree_text_set(anim.name[:],name)}
    if text,found,kind_ok:=tree_arg_string(args,"kind");!kind_ok {return -1} else if found {
        known:=false
        for k in ui.Anim_Kind {if fmt.tprintf("%v",k)==text {anim.kind,known=k,true}}
        if !known {reading_failf(reading,"kind '%s' is none of Clip, Sequence, Parallel",text);return -1}
    }
    if text,found,loop_ok:=tree_arg_string(args,"loop");!loop_ok {return -1} else if found {
        known:=false
        for l in ui.Anim_Loop {if fmt.tprintf("%v",l)==text {anim.loop,known=l,true}}
        if !known {reading_failf(reading,"loop '%s' is none of Once, Loop, Ping_Pong",text);return -1}
    }
    types:=args.types
    switch anim.kind {
    case .Clip:
        text,found:=tree_arg(args,"tracks")
        if !found && row<0 {reading_fail(reading,"tracks is required for a new Clip");return -1}
        if found {
            tracks:=make([dynamic]ui.Tree_Track,reading.allocator)
            keys:=make([dynamic]ui.Keyframe,reading.allocator)
            if !tree_tracks_read(reading,types,text,&tracks,&keys) {return -1}
            anim.first,anim.count=u32(len(r.tracks)),u32(len(tracks))
            for &t in tracks {t.first_key+=u32(len(r.keys))}
            append(&r.tracks,..tracks[:])
            append(&r.keys,..keys[:])
        }
    case .Sequence,.Parallel:
        text,found:=tree_arg(args,"parts")
        if !found && row<0 {reading_fail(reading,"parts is required for a new Sequence or Parallel");return -1}
        if found {
            items,listed:=doc_items(reading,text,"parts","names")
            if !listed {return -1}
            first:=u32(len(r.parts))
            for item in items {
                part,read:=doc_string(reading,item)
                found_row:=-1
                for &a,i in r.anims {if read && serial.text_field(a.name[:])==part {found_row=i;break}}
                limit:=row if row>=0 else len(r.anims)
                if found_row<0 || found_row>=limit {reading_failf(reading,"parts: '%s' is not an animation made before '%s'",part,name);return -1}
                append(&r.parts,ui.Anim(found_row+1))
            }
            anim.first,anim.count=first,u32(len(r.parts))-first
        }
    }
    if row>=0 {r.anims[row]=anim} else {append(&r.anims,anim);row=len(r.anims)-1}
    return row
}

// Reads the tracks of a clip: each a property and its keys, put in time order.
tree_tracks_read :: proc(reading:^Reading,types:^asset.Types,text:string,tracks:^[dynamic]ui.Tree_Track,keys:^[dynamic]ui.Keyframe) -> bool {
    items:=doc_items(reading,text,"tracks","{property, keys}") or_return
    for item,count in items {
        if count>=ui.TREE_CLIP_TRACKS {reading_failf(reading,"a clip has at most %d tracks",ui.TREE_CLIP_TRACKS);return false}
        what:=fmt.tprintf("tracks[%d]",count)
        object_keys,object_values:=tree_object(reading,item,what) or_return
        track:=ui.Tree_Track{first_key=u32(len(keys))}
        has_property:=false
        for key,i in object_keys {
            switch key {
            case "property":
                name,_:=doc_string(reading,object_values[i])
                for p in ui.Anim_Property {if fmt.tprintf("%v",p)==name {track.property,has_property=p,true}}
                if !has_property {reading_failf(reading,"%s.property '%s' is none of Offset, Scale, Rotation, Opacity, Color, Width, Height, Value, Frame, Reveal",what,name);return false}
            case "keys":
                key_items:=doc_items(reading,object_values[i],fmt.tprintf("%s.keys",what),"{time, value, ease}") or_return
                for key_item,k in key_items {
                    key:ui.Keyframe
                    if !tree_fields_read(reading,types,ui.Keyframe,&key,key_item,fmt.tprintf("%s.keys[%d]",what,k)) {return false}
                    if key.time<0 || key.time-key.time!=0 {reading_failf(reading,"%s.keys[%d].time must be a finite number of seconds, 0 or more",what,k);return false}
                    append(keys,key)
                }
            case:
                reading_failf(reading,"%s has no '%s'; a track has property and keys",what,key)
                return false
            }
        }
        if !has_property {reading_failf(reading,"%s.property is required",what);return false}
        track.key_count=u32(len(keys))-track.first_key
        run:=keys[track.first_key:]
        slice.sort_by(run,proc(a,b:ui.Keyframe) -> bool {return a.time<b.time})
        append(tracks,track)
    }
    return true
}
