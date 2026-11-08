package ui_inspector_editor

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// A .ui, or the subtree of one of its nodes, as a document: what ui.inspect
// gives and ui.write takes back. Nodes nest by children and give what differs
// from a new node of their kind; a node names the named style it takes, keeps
// its own look inside it ("look"), and has both while it changes a named
// style until that is saved. ui.write declares what the document names: the
// nodes of the file, or of one node, become those of the document, matched by
// name so that what the file keeps of a node (its translations, the overrides
// of an instance) stays; the styles and animations it names become those, null
// takes one away, and those it does not name stay.

// What a node gives by keys of its own, or keeps: none of it goes in fields.
@(private) DOCUMENT_NODE_SKIP :: [?]string{"kind","parent","name","text","text_id","style","image","anims","component"}
@(private) DOCUMENT_NODE_KEYS :: [?]string{"name","kind","widget","text","style","look","image","events","fields","children"}
@(private) DOCUMENT_EVENTS :: [?]string{"shown","hidden","hovered","unhovered","pressed","released","focused","unfocused","selected","unselected","clicked"}
// The fields of ui.Node_Style each field of a rule sets; those of text inside its text.
@(private) DOCUMENT_RULE_FIELDS :: [ui.Style_Field][4]string{
    .Fill={"fill","","",""},.Fill2={"fill2","","",""},.Stroke={"stroke","","",""},.Track={"track","","",""},.Knob={"knob","","",""},.Mark={"mark","","",""},
    .Radius={"radius","","",""},.Stroke_Width={"stroke_width","","",""},.Shadow={"shadow","shadow_color","shadow_blur","shadow_offset"},
    .Text_Font={"font","","",""},.Text_Size={"size","","",""},.Text_Color={"color","","",""},.Text_Outline={"outline","outline_color","",""},.Text_Shadow={"shadow","shadow_color","",""},
}
@(private) DOCUMENT_TEXT_FIELDS :: ui.Style_Fields{.Text_Font,.Text_Size,.Text_Color,.Text_Outline,.Text_Shadow}

// ---------------------------------------------------------------- writing

// Writes the document of the records: every node, named style and animation,
// or with root>=0 that node with what it holds and the styles and animations
// they take.
document_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,root:int) {
    first,last:=0,len(r.nodes)
    if root>=0 {first,last=root,root+records_subtree(r.nodes[:],root)+1}
    styles:=make([]bool,len(r.styles),context.temp_allocator)
    anims:=make([]bool,len(r.anims),context.temp_allocator)
    if root<0 {
        for &s,i in styles {s=records_style_named(r,i) && records_style_base(r,i)<0}
        for &a in anims {a=true}
    } else {
        for &n in r.nodes[first:last] {
            s:=int(n.style)
            if base:=records_style_base(r,s);base>=0 {s=base}
            if s<len(styles) && records_style_named(r,s) {styles[s]=true}
            if n.anims==0 || int(n.anims)>len(r.anim_sets) {continue}
            set:=r.anim_sets[n.anims-1]
            for played in (^[len(DOCUMENT_EVENTS)]ui.Anim)(&set)^ {if played>0 && int(played)<=len(anims) {anims[played-1]=true}}
        }
        // The parts of a group go with it; a group plays animations made before it.
        for i:=len(anims)-1;i>=0;i-=1 {
            a:=r.anims[i]
            if !anims[i] || a.kind==.Clip || u64(a.first)+u64(a.count)>u64(len(r.parts)) {continue}
            for part in r.parts[a.first:][:a.count] {if part>0 && int(part)<=len(anims) {anims[part-1]=true}}
        }
    }
    serial.write_u8(out,'{')
    api.write_key(out,"styles",true);serial.write_u8(out,'{')
    written:=false
    for wanted,row in styles {
        if !wanted {continue}
        api.write_key(out,records_style_name(r,row),!written)
        written=true
        document_style_write(out,types,r,row,true)
    }
    serial.write_u8(out,'}')
    api.write_key(out,"animations");serial.write_u8(out,'{')
    written=false
    for wanted,row in anims {
        if !wanted {continue}
        api.write_key(out,serial.text_field(r.anims[row].name[:]),!written)
        written=true
        document_anim_write(out,r,row)
    }
    serial.write_u8(out,'}')
    api.write_key(out,"nodes");serial.write_u8(out,'[')
    written=false
    for &n,row in r.nodes[first:last] {
        if root<0 && n.parent>=0 || root>=0 && first+row!=root {continue}
        if written {serial.write_u8(out,',')}
        written=true
        document_node_write(out,types,r,first+row)
    }
    serial.write_u8(out,']')
    serial.write_u8(out,'}')
}

// A style: its family when it is named, the kinds whose new nodes take it,
// the fields of ui.Node_Style that are not zero and its rules.
@(private)
document_style_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,row:int,named:bool) {
    style_type,_:=asset.types_index(types,ui.Node_Style)
    tokens_type,_:=asset.types_index(types,ui.Style_Tokens)
    info:ui.Tree_Style_Info
    if row<len(r.style_infos) {info=r.style_infos[row]}
    serial.write_u8(out,'{')
    if named {api.write_text(out,"family",fmt.tprintf("%v",info.family),true)}
    if info.defaults!={} {
        api.write_key(out,"defaults",!named);serial.write_u8(out,'[')
        first:=true
        for kind in info.defaults {
            if !first {serial.write_u8(out,',')}
            first=false
            serial.text_write_string(out,fmt.tprintf("%v",kind))
        }
        serial.write_u8(out,']')
    }
    api.write_key(out,"fields",!named && info.defaults=={})
    zero:ui.Node_Style
    serial.text_write_changed(out,&types.schema,style_type,mem.ptr_to_bytes(&r.styles[row]),mem.ptr_to_bytes(&zero))
    rules:=false
    names:=DOCUMENT_RULE_FIELDS
    for &v in r.variants {
        if int(v.style)!=row {continue}
        if !rules {api.write_key(out,"rules");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        rules=true
        serial.write_u8(out,'{')
        api.write_text(out,"variant",serial.text_field(v.variant[:]),true)
        api.write_key(out,"states");serial.write_u8(out,'[')
        first:=true
        for state in v.states {
            if !first {serial.write_u8(out,',')}
            first=false
            serial.text_write_string(out,fmt.tprintf("%v",state))
        }
        serial.write_u8(out,']')
        // A field a color of the theme gives is in tokens alone.
        t:=v.patch.tokens
        given:=v.patch.fields
        if t.fill!=.Literal {given-={.Fill}}
        if t.fill2!=.Literal {given-={.Fill2}}
        if t.stroke!=.Literal {given-={.Stroke}}
        if t.text!=.Literal {given-={.Text_Color}}
        if t.track!=.Literal {given-={.Track}}
        if t.knob!=.Literal {given-={.Knob}}
        if t.mark!=.Literal {given-={.Mark}}
        api.write_key(out,"fields");serial.write_u8(out,'{')
        first=true
        values:=mem.ptr_to_bytes(&v.patch.values)
        for field in given-DOCUMENT_TEXT_FIELDS {
            for name in names[field] {if name!="" {document_field_write(out,types,style_type,values,name,&first)}}
        }
        if given&DOCUMENT_TEXT_FIELDS!={} {
            text_type,text_offset:=document_field_of(types,style_type,"text")
            api.write_key(out,"text",first);first=false
            serial.write_u8(out,'{')
            inner:=true
            for field in given&DOCUMENT_TEXT_FIELDS {
                for name in names[field] {if name!="" {document_field_write(out,types,text_type,values[text_offset:],name,&inner)}}
            }
            serial.write_u8(out,'}')
        }
        serial.write_u8(out,'}')
        if t!={} {
            none:ui.Style_Tokens
            api.write_key(out,"tokens")
            serial.text_write_changed(out,&types.schema,tokens_type,mem.ptr_to_bytes(&v.patch.tokens),mem.ptr_to_bytes(&none))
        }
        serial.write_u8(out,'}')
    }
    if rules {serial.write_u8(out,']')}
    serial.write_u8(out,'}')
}

// The type and offset of a field of a type, by name.
@(private)
document_field_of :: proc(types:^asset.Types,index:serial.Type_Index,name:string) -> (field:serial.Type_Index,offset:int) {
    t:=types.schema.types[index]
    for f in types.schema.fields[t.first:][:t.count] {if f.name==name {return f.type,int(f.offset)}}
    return serial.TYPE_NONE,0
}

// Writes the field of a value of a type as a key and its value.
@(private)
document_field_write :: proc(out:^serial.Writer,types:^asset.Types,index:serial.Type_Index,value:[]u8,name:string,first:^bool) {
    t:=types.schema.types[index]
    for f in types.schema.fields[t.first:][:t.count] {
        if f.name!=name {continue}
        api.write_key(out,name,first^)
        first^=false
        size:=int(types.schema.types[f.type].size)
        serial.text_write(out,&types.schema,f.type,value[f.offset:][:size],.Line,is_text=.Text in f.flags)
        return
    }
}

@(private)
document_anim_write :: proc(out:^serial.Writer,r:^Records,row:int) {
    anim:=r.anims[row]
    serial.write_u8(out,'{')
    api.write_text(out,"kind",fmt.tprintf("%v",anim.kind),true)
    api.write_text(out,"loop",fmt.tprintf("%v",anim.loop))
    if anim.kind==.Clip {
        api.write_key(out,"tracks");serial.write_u8(out,'[')
        if u64(anim.first)+u64(anim.count)<=u64(len(r.tracks)) {
            for t,ti in r.tracks[anim.first:][:anim.count] {
                if ti>0 {serial.write_u8(out,',')}
                serial.write_u8(out,'{')
                api.write_text(out,"property",fmt.tprintf("%v",t.property),true)
                api.write_key(out,"keys");serial.write_u8(out,'[')
                if u64(t.first_key)+u64(t.key_count)<=u64(len(r.keys)) {
                    for &k,ki in r.keys[t.first_key:][:t.key_count] {
                        if ki>0 {serial.write_u8(out,',')}
                        serial.write_u8(out,'{')
                        api.write_key(out,"time",true);api.write_number(out,k.time)
                        api.write_key(out,"value");api.write_list(out,k.value[:])
                        api.write_text(out,"ease",fmt.tprintf("%v",k.ease))
                        serial.write_u8(out,'}')
                    }
                }
                serial.text_write_raw(out,"]}")
            }
        }
        serial.write_u8(out,']')
    } else if u64(anim.first)+u64(anim.count)<=u64(len(r.parts)) {
        api.write_key(out,"parts");serial.write_u8(out,'[')
        for part,pi in r.parts[anim.first:][:anim.count] {
            if pi>0 {serial.write_u8(out,',')}
            name:=serial.text_field(r.anims[part-1].name[:]) if part>0 && int(part)<=len(r.anims) else ""
            serial.text_write_string(out,name)
        }
        serial.write_u8(out,']')
    }
    serial.write_u8(out,'}')
}

@(private)
document_node_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,row:int) {
    n:=r.nodes[row]
    node_type,_:=asset.types_index(types,ui.Tree_Node)
    image_type,_:=asset.types_index(types,ui.Tree_Image)
    serial.write_u8(out,'{')
    api.write_text(out,"name",serial.text_field(n.name[:]),true)
    template:=int(n.component)-1
    if n.kind==.Component && template>=0 && template<len(r.templates) && r.templates[template].component.widget!={} {
        api.write_key(out,"widget");serial.write_u8(out,'"');serial.text_write_asset_id(out,r.templates[template].component.widget);serial.write_u8(out,'"')
    } else {
        api.write_text(out,"kind",fmt.tprintf("%v",n.kind))
    }
    if text:=records_text(r,n.text);text!="" {api.write_text(out,"text",text)}
    style:=int(n.style)
    if style==0 {
        // None, where a node without a style would take the one of its kind.
        if _,has:=node_default_look(n.kind);has || records_kind_style(r,n.kind)>=0 {api.write_text(out,"style","")}
    } else if style<len(r.styles) {
        base:=records_style_base(r,style)
        if base>=0 {
            api.write_text(out,"style",records_style_name(r,base))
            api.write_key(out,"look");document_style_write(out,types,r,style,false)
        } else if records_style_named(r,style) {
            api.write_text(out,"style",records_style_name(r,style))
        } else {
            api.write_key(out,"look");document_style_write(out,types,r,style,false)
        }
    }
    if n.image!=0 && int(n.image)<=len(r.images) {
        api.write_key(out,"image")
        serial.text_write(out,&types.schema,image_type,mem.ptr_to_bytes(&r.images[n.image-1]),.Line)
    }
    if n.anims!=0 && int(n.anims)<=len(r.anim_sets) {
        set:=r.anim_sets[n.anims-1]
        api.write_key(out,"events");serial.write_u8(out,'{')
        names:=DOCUMENT_EVENTS
        first:=true
        for played,i in (^[len(DOCUMENT_EVENTS)]ui.Anim)(&set)^ {
            if played==0 || int(played)>len(r.anims) {continue}
            api.write_text(out,names[i],serial.text_field(r.anims[played-1].name[:]),first)
            first=false
        }
        serial.write_u8(out,'}')
    }
    defaults:=node_default(n.kind)
    defaults.parent=n.parent
    shown:=n
    shown.flags-={.Localized}
    skip:=DOCUMENT_NODE_SKIP
    api.write_key(out,"fields")
    serial.text_write_changed(out,&types.schema,node_type,mem.ptr_to_bytes(&shown),mem.ptr_to_bytes(&defaults),skip=skip[:])
    end:=row+records_subtree(r.nodes[:],row)
    children:=false
    for child in row+1..=end {
        if int(r.nodes[child].parent)!=row {continue}
        if !children {api.write_key(out,"children");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        children=true
        document_node_write(out,types,r,child)
    }
    if children {serial.write_u8(out,']')}
    serial.write_u8(out,'}')
}

// ---------------------------------------------------------------- reading

// A node of a document, read in pre-order.
@(private)
Document_Node :: struct {
    keys,values:[dynamic]string,
    path:string,  // where it is in the document, for errors
    name:string,  // as declared; empty: none
    kind:ui.Node_Kind,
    widget:base.Asset_Id,
    parent:int,   // index of the node that holds it; -1: one of the top
    row:int,      // of the node of the file it is matched to; -1: a new one
    current:string, // its name in the file while it is placed
}

// Prefixes the error of the call with where it happened; false.
@(private)
document_failed :: proc(call:^api.Call,what:string) -> bool {
    call.error.message=api.format_text(call.allocator,"%s: %s",what,call.error.message)
    return false
}

@(private)
document_row_of :: proc(r:^Records,name:string) -> int {
    for &n,i in r.nodes {if serial.text_field(n.name[:])==name {return i}}
    return -1
}

// Makes the records say what the document declares: with root>=0, that node
// and what it holds, and otherwise the whole file. Styles and animations go
// first, since nodes take them by name; those it takes away, last. False
// after failing the call, with where in the document.
document_apply :: proc(args:^Tree_Args,r:^Records,root:int,text:string) -> (made,removed:int,ok:bool) {
    call:=args.call
    keys,values:=tree_object(call,text,"document") or_return
    styles,anims,nodes:string
    for key,i in keys {
        switch key {
        case "styles":     styles=values[i]
        case "animations": anims=values[i]
        case "nodes":      nodes=values[i]
        case "widgets","fonts":
            api.call_failf(call,api.INVALID_PARAMS,"document.%s is what ui.inspect says beside the document; write back its document alone",key)
            return
        case:
            api.call_failf(call,api.INVALID_PARAMS,"document has no '%s'; it has styles, animations and nodes",key)
            return
        }
    }
    gone_styles:=make([dynamic]string,call.allocator)
    gone_anims:=make([dynamic]string,call.allocator)
    if styles!="" {
        style_keys,style_values:=tree_object(call,styles,"styles") or_return
        for name,i in style_keys {
            what:=fmt.tprintf("styles.%s",name)
            if strings.trim_space(style_values[i])=="null" {append(&gone_styles,name);continue}
            style_args:=args^
            style_args.keys,style_args.values,ok=tree_object(call,style_values[i],what)
            if !ok {return}
            row:=tree_style_row(r,name)
            if row<0 {
                if name=="" || len(name)>=ui.TREE_NAME_CAPACITY {api.call_failf(call,api.INVALID_PARAMS,"%s: a style has a name shorter than %d bytes",what,ui.TREE_NAME_CAPACITY);return}
                info:=ui.Tree_Style_Info{}
                ui.tree_text_set(info.name[:],name)
                row=records_style_add(r,{},{},info)
                if row<0 {api.call_fail(call,api.SERVER_ERROR,"the .ui holds no more styles");return}
            }
            if !document_style_apply(&style_args,r,row,true) {ok=document_failed(call,what);return}
        }
    }
    if anims!="" {
        anim_keys,anim_values:=tree_object(call,anims,"animations") or_return
        for name,i in anim_keys {
            what:=fmt.tprintf("animations.%s",name)
            if strings.trim_space(anim_values[i])=="null" {append(&gone_anims,name);continue}
            if !document_anim_apply(args,r,name,anim_values[i]) {ok=document_failed(call,what);return}
        }
    }
    if nodes!="" {
        made,removed=document_nodes_apply(args,r,root,nodes) or_return
    }
    for name in gone_anims {
        row:=-1
        for &a,i in r.anims {if serial.text_field(a.name[:])==name {row=i;break}}
        if row>=0 {records_anim_remove(r,row)}
    }
    for name in gone_styles {
        row:=tree_style_row(r,name)
        if row>=0 && !records_style_delete(r,row) {
            api.call_failf(call,api.INVALID_PARAMS,"styles.%s: nodes still take it or change it; give them another style in the same document",name)
            return
        }
    }
    return made,removed,true
}

// A style as the document declares it, at row: its family when it is
// named, the kinds whose new nodes take it, its fields and its rules.
@(private)
document_style_apply :: proc(args:^Tree_Args,r:^Records,row:int,named:bool) -> bool {
    call:=args.call
    if row>=len(r.style_infos) {resize(&r.style_infos,len(r.styles))}
    info:=&r.style_infos[row]
    r.styles[row]={}
    info.defaults={}
    for i:=len(r.variants)-1;i>=0;i-=1 {if int(r.variants[i].style)==row {ordered_remove(&r.variants,i)}}
    for key,i in args.keys {
        switch key {
        case "family":
            if !named {api.call_fail(call,api.INVALID_PARAMS,"family: a look is of the family of its node");return false}
            text,_,read:=tree_arg_string(args,"family")
            if !read {return false}
            known:=false
            for f in ui.Style_Family {if fmt.tprintf("%v",f)==text {info.family,known=f,true}}
            if !known {api.call_failf(call,api.INVALID_PARAMS,"family '%s' is none of Box, Text, Control",text);return false}
        case "fields":
            if !tree_fields_read(call,args.types,ui.Node_Style,&r.styles[row],args.values[i],"fields") {return false}
        case "defaults","rules":
        case:
            api.call_failf(call,api.INVALID_PARAMS,"a style has no '%s'; it has family, defaults, fields and rules",key)
            return false
        }
    }
    if text,found:=tree_arg(args,"defaults");found {
        kinds,read:=tree_kinds_read(call,text,info.family)
        if !read {return false}
        records_kind_style_set(r,row,kinds)
    }
    if text,found:=tree_arg(args,"rules");found {
        list:serial.Text_Reader
        serial.text_reader_init(&list,text,call.allocator)
        if !serial.text_accept(&list,'[') {api.call_fail(call,api.INVALID_PARAMS,"rules must be an array of {variant, states, fields, tokens}");return false}
        for at:=0;!serial.text_accept(&list,']');at+=1 {
            if at>0 && !serial.text_accept(&list,',') {return tree_malformed(call,&list)}
            serial.text_space(&list)
            start:=list.offset
            if !serial.text_skip(&list) {return tree_malformed(call,&list)}
            what:=fmt.tprintf("rules[%d]",at)
            rule:=args^
            ok:bool
            rule.keys,rule.values,ok=tree_object(call,text[start:list.offset],what)
            if !ok {return false}
            for key in rule.keys {
                switch key {
                case "variant","states","fields","tokens":
                case:
                    api.call_failf(call,api.INVALID_PARAMS,"%s has no '%s'; a rule has variant, states, fields and tokens",what,key)
                    return false
                }
            }
            if !tree_rule_apply(&rule,r,row) {return document_failed(call,what)}
        }
    }
    return true
}

// An animation as the document declares it: one the file has keeps its row,
// so the events that play it still do.
@(private)
document_anim_apply :: proc(args:^Tree_Args,r:^Records,name,text:string) -> bool {
    call:=args.call
    anim:=args^
    keys,values:=tree_object(call,text,"the animation") or_return
    for key in keys {
        switch key {
        case "kind","loop","tracks","parts":
        case:
            api.call_failf(call,api.INVALID_PARAMS,"an animation has no '%s'; it has kind, loop, and tracks or parts",key)
            return false
        }
    }
    for &a in r.anims {
        if serial.text_field(a.name[:])==name {a={name=a.name}}
    }
    anim.keys,anim.values=keys,values
    append(&anim.keys,"name")
    append(&anim.values,fmt.tprintf("%q",name))
    return tree_anim_apply(&anim,r)>=0
}

// Reads the nodes of an array in pre-order, each after the node that holds it.
@(private)
document_nodes_read :: proc(args:^Tree_Args,text:string,parent:int,path:string,out:^[dynamic]Document_Node) -> bool {
    call:=args.call
    list:serial.Text_Reader
    serial.text_reader_init(&list,text,call.allocator)
    if !serial.text_accept(&list,'[') {api.call_failf(call,api.INVALID_PARAMS,"%s must be an array of nodes",path);return false}
    for at:=0;!serial.text_accept(&list,']');at+=1 {
        if at>0 && !serial.text_accept(&list,',') {return tree_malformed(call,&list)}
        serial.text_space(&list)
        start:=list.offset
        if !serial.text_skip(&list) {return tree_malformed(call,&list)}
        d:=Document_Node{path=fmt.aprintf("%s[%d]",path,at,allocator=call.allocator),parent=parent,row=-1}
        ok:bool
        d.keys,d.values,ok=tree_object(call,text[start:list.offset],d.path)
        if !ok {return false}
        node_args:=args^
        node_args.keys,node_args.values=d.keys,d.values
        refused:=DOCUMENT_NODE_KEYS
        for key in d.keys {
            if _,known:=slice.linear_search(refused[:],key);!known {
                api.call_failf(call,api.INVALID_PARAMS,"%s has no '%s'; a node has name, kind or widget, text, style, look, image, events, fields and children",d.path,key)
                return false
            }
        }
        name,_,named:=tree_arg_string(&node_args,"name")
        if !named {return document_failed(call,d.path)}
        d.name=name
        if text,has_widget,widget_ok:=tree_arg_string(&node_args,"widget");!widget_ok {
            return document_failed(call,d.path)
        } else if has_widget {
            widget,problem:=editor.asset_resolve(args.session,text,".ui")
            is_ui:=false
            if args.registry!=nil {if record,found:=asset.registry_find(args.registry,widget);found {is_ui=record.kind==asset.KIND_UI}}
            if problem!="" || !is_ui || widget==args.asset {api.call_failf(call,api.INVALID_PARAMS,"%s.widget: '%s' is not another .ui of the project",d.path,text);return false}
            d.kind,d.widget=.Component,widget
        } else {
            kind_text,has_kind,kind_ok:=tree_arg_string(&node_args,"kind")
            if !kind_ok {return document_failed(call,d.path)}
            if !has_kind {api.call_failf(call,api.INVALID_PARAMS,"%s: kind is required, or widget for an instance of another .ui",d.path);return false}
            if kind_text=="Component" {
                d.kind=.Component
            } else {
                known:bool
                d.kind,known=tree_kind(call,kind_text)
                if !known {return document_failed(call,d.path)}
            }
        }
        index:=len(out)
        append(out,d)
        if children,found:=tree_arg(&node_args,"children");found {
            if !document_nodes_read(args,children,index,fmt.tprintf("%s.children",d.path),out) {return false}
        }
    }
    return true
}

// Whether the node at row is of what a document node declares.
@(private)
document_same_kind :: proc(r:^Records,row:int,d:^Document_Node) -> bool {
    n:=&r.nodes[row]
    if n.kind!=d.kind {return false}
    if n.kind!=.Component || d.widget=={} {return true}
    template:=int(n.component)-1
    return template>=0 && template<len(r.templates) && r.templates[template].component.widget==d.widget
}

// The nodes of the file, or of root, become those of the document: matched
// by name and kind they are moved, the others are made, and what is left of
// the part declared is taken away; then each becomes what it declares.
@(private)
document_nodes_apply :: proc(args:^Tree_Args,r:^Records,root:int,text:string) -> (made,removed:int,ok:bool) {
    call:=args.call
    decls:=make([dynamic]Document_Node,call.allocator)
    if !document_nodes_read(args,text,-1,"nodes",&decls) {return}
    first,last:=0,len(r.nodes)
    top:=-1 // the parent of the nodes at the top of the document
    if root>=0 {
        first,last=root,root+records_subtree(r.nodes[:],root)+1
        tops:=0
        for &d in decls {tops+=int(d.parent<0)}
        if tops!=1 {api.call_fail(call,api.INVALID_PARAMS,"nodes: with node, the document declares that node alone, and what it holds as its children");return}
        top=int(r.nodes[root].parent)
    }
    inside :: proc(row,first,last:int) -> bool {return row>=first && row<last}
    for &d,i in decls {
        if d.name=="" {continue}
        for &other in decls[:i] {
            if other.name==d.name {api.call_failf(call,api.INVALID_PARAMS,"%s.name: '%s' is declared twice; names are unique in a file",d.path,d.name);return}
        }
        if row:=document_row_of(r,d.name);row>=0 && !inside(row,first,last) {
            api.call_failf(call,api.INVALID_PARAMS,"%s.name: the node '%s' is outside the part this write declares; names are unique in a file",d.path,d.name)
            return
        }
    }
    // Matched by name and kind; the node of root is the top of the document whatever its name.
    for &d in decls {
        if root>=0 && d.parent<0 {
            if !document_same_kind(r,root,&d) {api.call_failf(call,api.INVALID_PARAMS,"%s.kind: a node keeps its kind; write the node that holds it to put another in its place",d.path);return}
            d.row=root
            continue
        }
        if d.name=="" {continue}
        if row:=document_row_of(r,d.name);row>=0 && row!=root && document_same_kind(r,row,&d) {d.row=row}
    }
    // While the write runs, every node of the part has a name: one whose name
    // the document gives to a node of another kind takes one that nothing
    // declares, and is taken away below; one without a name takes one of its
    // own, and goes back to none at the end.
    for row in first..<last {
        name:=serial.text_field(r.nodes[row].name[:])
        if name=="" || row==root {continue}
        claimed,matched:=false,false
        for &d in decls {
            if d.name==name {claimed=true;matched=d.row==row}
        }
        if claimed && !matched {ui.tree_text_set(r.nodes[row].name[:],fmt.tprintf("\x02%d",row))}
    }
    for row in first..<last {
        if row!=root && r.nodes[row].name[0]==0 {ui.tree_text_set(r.nodes[row].name[:],fmt.tprintf("\x01%d",row))}
    }
    // A node without a name is matched by place: it takes the first node
    // without a name and of its kind left in the node that holds it.
    taken:=make([]bool,last-first,call.allocator)
    for &d in decls {
        if d.name!="" || d.row>=0 {continue}
        holder:=-1
        if d.parent>=0 {
            holder=decls[d.parent].row
            if holder<0 {continue}
        }
        for row in first..<last {
            if taken[row-first] || int(r.nodes[row].parent)!=holder || !document_same_kind(r,row,&d) {continue}
            if !strings.has_prefix(serial.text_field(r.nodes[row].name[:]),"\x01") {continue}
            d.row=row
            taken[row-first]=true
            break
        }
    }
    // Names are copied: rows move under them.
    for &d in decls {if d.row>=0 {d.current=strings.clone(serial.text_field(r.nodes[d.row].name[:]),call.allocator)}}
    // Each in order, last inside the node that holds it. Rows move as nodes
    // do: placed nodes are found by name, the node of root keeps its row.
    for &d in decls {
        if d.row==root && root>=0 {continue}
        parent:=top
        if d.parent>=0 {
            holder:=&decls[d.parent]
            parent=root if holder.row==root && root>=0 else document_row_of(r,holder.current)
        }
        if parent>=0 && !tree_takes(call,r,parent) {ok=document_failed(call,d.path);return}
        if d.row>=0 {
            row:=document_row_of(r,d.current)
            if records_place(r,row,parent,-1)<0 {api.call_failf(call,api.INVALID_PARAMS,"%s: a node cannot go inside itself or what it holds",d.path);return}
            continue
        }
        row:int
        if d.kind==.Component {
            if d.widget=={} {api.call_failf(call,api.INVALID_PARAMS,"%s: a new Component is an instance of another .ui: give its widget",d.path);return}
            row=records_widget(r,-1,parent,d.widget,d.name if d.name!="" else "widget")
        } else {
            row=records_insert(r,-1,parent,d.kind)
        }
        if row<0 {api.call_failf(call,api.SERVER_ERROR,"%s: the node could not be made",d.path);return}
        if d.name!="" {ui.tree_text_set(r.nodes[row].name[:],d.name)}
        d.current=strings.clone(serial.text_field(r.nodes[row].name[:]),call.allocator)
        made+=1
    }
    // What the part held and the document does not declare goes.
    end:=len(r.nodes) if root<0 else root+records_subtree(r.nodes[:],root)+1
    for row:=end-1;row>=first;row-=1 {
        if row>=len(r.nodes) || row==root {continue}
        name:=serial.text_field(r.nodes[row].name[:])
        kept:=false
        for &d in decls {if name!="" && d.current==name {kept=true;break}}
        if !kept {
            removed+=1+records_subtree(r.nodes[:],row)
            records_delete(r,-1,row)
        }
    }
    for &d in decls {
        row:=root if d.row==root && root>=0 else document_row_of(r,d.current)
        if !document_node_apply(args,r,row,&d) {ok=document_failed(call,d.path);return}
    }
    for &d in decls {
        if d.name=="" && !(d.row==root && root>=0) {r.nodes[document_row_of(r,d.current)].name={}}
    }
    return made,removed,true
}

// The node at row becomes what d declares: what it does not give is that of a
// new node of its kind. It keeps what ties it to the file: its translations
// and, as an instance, its widget and the overrides of it.
@(private)
document_node_apply :: proc(args:^Tree_Args,r:^Records,row:int,d:^Document_Node) -> bool {
    call:=args.call
    n:=&r.nodes[row]
    old:=n^
    fresh:=node_default(old.kind)
    fresh.parent,fresh.name,fresh.text_id,fresh.component=old.parent,old.name,old.text_id,old.component
    n^=fresh
    if d.name!="" && d.name!=serial.text_field(old.name[:]) {
        if !tree_name_free(call,r,row,d.name) {return false}
        ui.tree_text_set(n.name[:],d.name)
    }
    node_args:=args^
    node_args.keys,node_args.values=d.keys,d.values
    if !tree_node_apply(&node_args,r,row) {return false}
    n=&r.nodes[row]
    n.flags=n.flags-{.Localized}+old.flags&{.Localized}
    _,has_style:=tree_arg(&node_args,"style")
    if look,found:=tree_arg(&node_args,"look");found {
        info:=ui.Tree_Style_Info{family=style_family(n.kind)}
        if n.style!=0 {info.base=n.style+1}
        style:=records_style_add(r,{},{},info)
        if style<0 {api.call_fail(call,api.SERVER_ERROR,"the .ui holds no more styles");return false}
        look_args:=args^
        ok:bool
        look_args.keys,look_args.values,ok=tree_object(call,look,"look")
        if !ok {return false}
        if !document_style_apply(&look_args,r,style,false) {return document_failed(call,"look")}
        r.nodes[row].style=u16(style)
    } else if !has_style {
        r.nodes[row].style=records_kind_look(r,n.kind)
    }
    return true
}
