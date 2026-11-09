package ui_inspector_editor

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// A .ui, or the subtree of one of its nodes, as a document: what ui.inspect
// gives and ui.write takes back. It is the one way an agent writes a .ui:
// tokens, styles with extends, states and layouts inline, named animations,
// the files it uses, the parameters the widget of this file takes, and nodes
// nested that say what differs from a new node of their kind. Every
// name stays in the file (ui.tree_settle resolves them), so ui.inspect gives
// them back and ui.write of what it gave changes nothing. ui.write declares
// what the document names: the nodes of the file, or of one node, become
// those of the document, matched by name; what the file keeps of a node (its
// translations, the overrides of an instance) stays; the styles and
// animations it names become those, null takes one away, and those it does
// not name stay.

// A .ui a document takes names from.
Doc_Lib :: struct {
    id:base.Asset_Id,
    records:Records,
    linked:ui.Tree_Data, // linked with what it uses: its parameters, flat
}

// What a node gives by keys of its own, or keeps: none of it goes flat.
@(private) DOCUMENT_NODE_SKIP :: [?]string{"kind","parent","name","text","text_id","style","image","anims","component","component_fields","layout","layout_own"}
@(private) DOCUMENT_NODE_KEYS :: [?]string{"name","kind","text","style","look","image","events","children","slot"}
@(private) DOCUMENT_EVENTS :: [?]string{"shown","hidden","hovered","unhovered","pressed","released","focused","unfocused","selected","unselected","clicked"}

// The keys of a style in a document, in the order they are written.
@(private) Doc_Key :: struct {key:string,which:ui.Style_Key}
@(private) DOC_KEYS :: [?]Doc_Key{
    {"fill",.Fill},{"fill2",.Fill2},{"stroke",.Stroke},{"border",.Border},{"radius",.Radius},
    {"track",.Track},{"knob",.Knob},{"mark",.Mark},
    {"size",.Size},{"color",.Color},{"font",.Font},{"outline",.Outline},{"outline_color",.Outline_Color},
    {"text_x",.Text_Align_X},{"text_y",.Text_Align_Y},{"wrap",.Text_Wrap},{"ellipsis",.Ellipsis},{"line_height",.Line_Height},
    {"move_x",.Move_X},{"move_y",.Move_Y},{"scale",.Scale},
    {"fill_mode",.Fill_Mode},{"transition",.Transition},{"blur",.Blur},{"program",.Program},{"program_values",.Program_Values},
    {"width",.Width},{"height",.Height},{"direction",.Direction},{"padding",.Padding},{"gap",.Gap},
    {"align_x",.Align_X},{"align_y",.Align_Y},{"columns",.Columns},{"span",.Span},{"self_x",.Self_X},{"self_y",.Self_Y},{"aspect",.Aspect},
}
@(private) DOC_STATES :: [?]struct{key:string,states:ui.Style_States}{{"hover",{.Hovered}},{"focus",{.Focused}},{"pressed",{.Pressed}},{"disabled",{.Disabled}},{"selected",{.Selected}},{"over",{.Over}}}
// The fields a parameter of a widget can go to.
@(private) DOC_PARAM_FIELDS :: [ui.Tree_Param_Field]string{.Text="text",.Style="style",.Data="data",.Bind_Text="bind_text",.Bind_Value="bind_value",.Bind_Visible="bind_visible",.Bind_Selected="bind_selected",.Bind_Disabled="bind_disabled",.Bind_Items="bind_items",.Bind_Image="bind_image",.Bind_Tint="bind_tint",.Bind_Variant="bind_variant",.Variant="variant",.Action="action",.Tag="tag",.Accepts="accepts"}

@(private)
doc_failed :: proc(call:^api.Call,format:string,args:..any) -> bool {
    api.call_failf(call,api.INVALID_PARAMS,format,..args)
    return false
}

// A Node_Style of no value: what a value is compared to.
@(private)
doc_no_style :: proc() -> ui.Node_Style {return {}}

// ---------------------------------------------------------------- values

@(private)
doc_color_text :: proc(c:ui.Color) -> string {
    if c[3]==255 {return fmt.tprintf("#%02x%02x%02x",c[0],c[1],c[2])}
    return fmt.tprintf("#%02x%02x%02x%02x",c[0],c[1],c[2],c[3])
}
@(private)
doc_color_parse :: proc(text:string) -> (color:ui.Color,ok:bool) {
    digits:=len(text)-1
    if len(text)<2 || text[0]!='#' || digits!=6 && digits!=8 {return}
    value,parsed:=strconv.parse_u64_of_base(text[1:],16)
    if !parsed {return}
    if digits==6 {value=value<<8|0xff}
    return ui.Color{u8(value>>24),u8(value>>16),u8(value>>8),u8(value)},true
}

// The text of a JSON string, or empty and false.
@(private)
doc_string :: proc(call:^api.Call,text:string) -> (value:string,ok:bool) {
    trimmed:=strings.trim_space(text)
    if trimmed=="" || trimmed[0]!='"' {return "",false}
    r:serial.Text_Reader
    serial.text_reader_init(&r,trimmed,call.allocator)
    read:string
    read,ok=serial.text_string(&r)
    if !ok {return "",false}
    return strings.clone(read,call.allocator),true
}

@(private)
doc_number :: proc(text:string) -> (value:f32,ok:bool) {
    return strconv.parse_f32(strings.trim_space(text))
}

@(private)
doc_bool :: proc(text:string) -> (value,ok:bool) {
    switch strings.trim_space(text) {
    case "true":  return true,true
    case "false": return false,true
    }
    return false,false
}

// The items of a JSON array, each the text of its value. of: what it is an
// array of, for the error.
@(private)
doc_items :: proc(call:^api.Call,text,what:string,of:="") -> (items:[dynamic]string,ok:bool) {
    items=make([dynamic]string,call.allocator)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,call.allocator)
    if !serial.text_accept(&r,'[') {return items,doc_failed(call,"%s must be an array%s%s",what," of " if of!="" else "",of)}
    for at:=0;!serial.text_accept(&r,']');at+=1 {
        if at>0 && !serial.text_accept(&r,',') {return items,tree_malformed(call,&r)}
        serial.text_space(&r)
        start:=r.offset
        if !serial.text_skip(&r) {return items,tree_malformed(call,&r)}
        append(&items,text[start:r.offset])
    }
    return items,true
}

// A number or a size in a style or a node: "grow", "fit", "50%", a number
// for fixed, or the object of a ui.Size. A style may give the name of a token
// (token not empty).
@(private)
doc_size_read :: proc(args:^Tree_Args,text,what:string,size:^ui.Size) -> (token:string,ok:bool) {
    trimmed:=strings.trim_space(text)
    if value,is_number:=doc_number(trimmed);is_number {
        size^=ui.fixed(value)
        return "",true
    }
    if word,is_text:=doc_string(args.call,trimmed);is_text {
        switch word {
        case "grow":  size^=ui.GROW;return "",true
        case "fit":   size^=ui.FIT;return "",true
        }
        if strings.has_suffix(word,"%") {
            value,parsed:=doc_number(word[:len(word)-1])
            if !parsed {return "",doc_failed(args.call,"%s: '%s' is no size: give a number for fixed, \"grow\", \"fit\" or \"50%%\"",what,word)}
            size^=ui.percent(value/100)
            return "",true
        }
        return word,true
    }
    return "",tree_fields_read(args.call,args.types,ui.Size,size,trimmed,what)
}
@(private)
doc_size_write :: proc(out:^serial.Writer,types:^asset.Types,size:ui.Size) {
    size:=size
    plain:=size.min==0 && size.max==0
    switch {
    case size.kind==.Fixed && plain:              api.write_number(out,size.value)
    case size.kind==.Grow && plain && size.value==0: serial.text_write_string(out,"grow")
    case size.kind==.Fit && plain:                serial.text_write_string(out,"fit")
    case size.kind==.Percent && plain:            serial.text_write_string(out,fmt.tprintf("%g%%",size.value*100))
    case:
        index,_:=asset.types_index(types,ui.Size)
        zero:ui.Size
        serial.text_write_changed(out,&types.schema,index,mem.ptr_to_bytes(&size),mem.ptr_to_bytes(&zero))
    }
}

// An enum of a document: its name in any case.
@(private)
doc_enum_read :: proc(call:^api.Call,text,what:string,$E:typeid,value:^E) -> bool {
    word,is_text:=doc_string(call,text)
    if is_text {
        for member in E {
            if strings.equal_fold(fmt.tprintf("%v",member),word) {value^=member;return true}
        }
    }
    names:=make([dynamic]string,context.temp_allocator)
    for member in E {append(&names,strings.to_lower(fmt.tprintf("%v",member),context.temp_allocator))}
    return doc_failed(call,"%s: give one of %s",what,strings.join(names[:],", ",context.temp_allocator))
}
@(private)
doc_enum_text :: proc(value:$E) -> string {return strings.to_lower(fmt.tprintf("%v",value),context.temp_allocator)}

// The sides of a padding: a number, [x, y] or [left, top, right, bottom].
@(private)
doc_padding_read :: proc(call:^api.Call,text,what:string,padding:^[4]f32) -> (token:string,ok:bool) {
    trimmed:=strings.trim_space(text)
    if value,is_number:=doc_number(trimmed);is_number {padding^=ui.padding_all(value);return "",true}
    if word,is_text:=doc_string(call,trimmed);is_text {return word,true}
    items:=doc_items(call,trimmed,what) or_return
    values:[4]f32
    for item,i in items {
        if i>=4 {return "",doc_failed(call,"%s: at most four numbers: left, top, right and bottom",what)}
        values[i],ok=doc_number(item)
        if !ok {return "",doc_failed(call,"%s: give numbers",what)}
    }
    switch len(items) {
    case 2: padding^=ui.padding_xy(values[0],values[1])
    case 4: padding^=values
    case:   return "",doc_failed(call,"%s: give a number, [x, y] or [left, top, right, bottom]",what)
    }
    return "",true
}
@(private)
doc_padding_write :: proc(out:^serial.Writer,p:[4]f32) {
    p:=p
    switch {
    case p[0]==p[1] && p[1]==p[2] && p[2]==p[3]: api.write_number(out,p[0])
    case p[0]==p[2] && p[1]==p[3]: api.write_list(out,p[:2])
    case: api.write_list(out,p[:])
    }
}

// ---------------------------------------------------------------- names

// A .ui as a document takes names from it, linked with what it uses.
doc_lib_read :: proc(a:^host.Assets,id:base.Asset_Id,allocator:mem.Allocator) -> (lib:Doc_Lib,ok:bool) {
    lib.id=id
    if !records_read(a,id,&lib.records,allocator) {return}
    data:=records_data(&lib.records)
    lib.linked=data
    imports,imported:=host.ui_tree_imports(a,data,nil,allocator)
    if !imported {return lib,true} // ui.check says why
    if linked,linked_ok:=ui.tree_link(data,imports,allocator);linked_ok {lib.linked=linked}
    return lib,true
}

// The files a document takes names from: those the records already name, and
// those its "use" adds.
@(private)
doc_libs :: proc(args:^Tree_Args,r:^Records,extra:[]base.Asset_Id={}) -> [dynamic]Doc_Lib {
    libs:=make([dynamic]Doc_Lib,context.temp_allocator) // what a call allocates is bounded; these are whole files
    if args.assets==nil {return libs}
    add :: proc(libs:^[dynamic]Doc_Lib,a:^host.Assets,id:base.Asset_Id,allocator:mem.Allocator) {
        if id=={} {return}
        for &lib in libs {if lib.id==id {return}}
        if lib,read:=doc_lib_read(a,id,allocator);read {append(libs,lib)}
    }
    for &c in r.components {add(&libs,args.assets,c.widget,context.temp_allocator)}
    for id in extra {add(&libs,args.assets,id,context.temp_allocator)}
    return libs
}

@(private)
doc_lib_of :: proc(libs:[]Doc_Lib,id:base.Asset_Id) -> ^Doc_Lib {
    for &lib in libs {if lib.id==id {return &lib}}
    return nil
}

// The name a file goes by: its name without folder or extension.
@(private)
doc_use_name :: proc(a:^host.Assets,id:base.Asset_Id,fallback:string) -> string {
    if a==nil {return fallback}
    file,found:=asset.registry_find(&a.registry,id)
    if !found {return fallback}
    path:=file.path
    path=path[strings.last_index_byte(path,'/')+1:]
    if dot:=strings.last_index_byte(path,'.');dot>0 {path=path[:dot]}
    return path
}

// The file a kind names, of those a document takes names from; none: no kind.
@(private)
doc_use_find :: proc(args:^Tree_Args,name:string) -> base.Asset_Id {
    if args.libs==nil {return {}}
    for &lib in args.libs {if doc_use_name(args.assets,lib.id,"")==name {return lib.id}}
    return {}
}

// The id of a .ui a document names by its path.
@(private)
doc_use_resolve :: proc(args:^Tree_Args,path,what:string) -> (id:base.Asset_Id,ok:bool) {
    call:=args.call
    if args.assets==nil {api.call_failf(call,api.INVALID_PARAMS,"%s: no project to read '%s' from",what,path);return}
    if args.session!=nil {
        problem:string
        if id,problem=editor.asset_resolve(args.session,path,".ui");problem!="" {api.call_failf(call,api.INVALID_PARAMS,"%s: %s",what,problem);return}
    } else {
        file,found:=asset.registry_find_path(&args.assets.registry,path)
        if !found {api.call_failf(call,api.INVALID_PARAMS,"%s: no .ui at '%s'",what,path);return}
        id=file.id
    }
    return id,true
}

// A file that names, itself or through what it uses, target: how it does it,
// the files from the first to target; empty: it does not.
@(private)
doc_reaches :: proc(a:^host.Assets,from,target:base.Asset_Id) -> string {
    used,read:=widget_uses_of_file(a,from)
    if !read {return ""}
    w:=widget_walk(used,from,target,widget_uses_of_file,a)
    if !w.reached {return ""}
    chain:=make([dynamic]string,context.temp_allocator)
    for id in w.chain {append(&chain,doc_path(a,id))}
    return strings.join(chain[:]," -> ",context.temp_allocator)
}

@(private)
doc_token_find :: proc(r:^Records,libs:[]Doc_Lib,name:string) -> (token:^ui.Tree_Token) {
    for &t in r.tokens {if serial.text_field(t.name[:])==name {return &t}}
    for &lib in libs {
        for &t in lib.records.tokens {if serial.text_field(t.name[:])==name {return &t}}
    }
    return nil
}

// The row of the style called name: of this file, one that names a file it
// takes styles from (made the first time), or -1.
@(private)
doc_style_row :: proc(args:^Tree_Args,r:^Records,name:string) -> int {
    if row:=tree_style_row(r,name);row>=0 {return row}
    if args.libs==nil {return -1}
    for &lib in args.libs {
        for &info in lib.records.style_infos {
            if serial.text_field(info.name[:])!=name {continue}
            row:=records_style_add(r,{},{},{from=u16(records_use_row(r,lib.id,doc_use_name(args.assets,lib.id,"widget"))+1)})
            if row<0 {return -1}
            ui.tree_text_set(r.style_infos[row].name[:],name)
            return row
        }
    }
    return -1
}

// A value of a style names a token: the one for that key, replaced. An empty
// token takes it away.
records_token_use :: proc(r:^Records,style:int,variant:string,states:ui.Style_States,key:ui.Style_Key,token:string) {
    for i:=len(r.token_uses)-1;i>=0;i-=1 {
        u:=&r.token_uses[i]
        if int(u.style)==style && u.states==states && u.key==key && serial.text_field(u.variant[:])==variant {ordered_remove(&r.token_uses,i)}
    }
    if token=="" {return}
    use:=ui.Tree_Token_Use{style=u16(style),states=states,key=key}
    ui.tree_text_set(use.variant[:],variant)
    ui.tree_text_set(use.token[:],token)
    append(&r.token_uses,use)
}
@(private)
doc_token_of :: proc(r:^Records,style:int,variant:string,states:ui.Style_States,key:ui.Style_Key) -> string {
    for &u in r.token_uses {
        if int(u.style)==style && u.states==states && u.key==key && serial.text_field(u.variant[:])==variant {return serial.text_field(u.token[:])}
    }
    return ""
}

// The color a key gives: #rrggbb, #rrggbbaa, or the name of a token of a color.
@(private)
doc_color_value :: proc(args:^Tree_Args,r:^Records,text,what:string) -> (color:ui.Color,token:string,ok:bool) {
    call:=args.call
    word,is_text:=doc_string(call,text)
    if !is_text {return {},"",doc_failed(call,"%s must be a color: #rrggbb, #rrggbbaa or the name of a token",what)}
    if len(word)>0 && word[0]=='#' {
        parsed:bool
        color,parsed=doc_color_parse(word)
        if !parsed {return {},"",doc_failed(call,"%s: '%s' is no color: write #rrggbb or #rrggbbaa",what,word)}
        return color,"",true
    }
    t:=doc_token_find(r,doc_libs_slice(args),word)
    if t==nil {return {},"",doc_failed(call,"%s names the token '%s', which is not declared in tokens or in a file this one uses",what,word)}
    if t.numeric {return {},"",doc_failed(call,"%s names '%s', a token of a number",what,word)}
    return t.color,word,true
}

// The value of the token of a number that a key names.
@(private)
doc_number_token :: proc(args:^Tree_Args,r:^Records,word,what:string) -> (number:f32,ok:bool) {
    t:=doc_token_find(r,doc_libs_slice(args),word)
    if t==nil || !t.numeric {return 0,doc_failed(args.call,"%s names '%s', which is no number token",what,word)}
    return t.number,true
}

// The number a key gives; a style (r) can give the name of a token of a
// number, a node (r nil) cannot.
@(private)
doc_number_value :: proc(args:^Tree_Args,r:^Records,text,what:string) -> (number:f32,token:string,ok:bool) {
    if value,is_number:=doc_number(text);is_number {return value,"",true}
    if r==nil {return 0,"",doc_failed(args.call,"%s must be a number",what)}
    word,is_text:=doc_string(args.call,text)
    if !is_text {return 0,"",doc_failed(args.call,"%s must be a number or the name of a token",what)}
    number,ok=doc_number_token(args,r,word,what)
    return number,word,ok
}

// ---------------------------------------------------------------- writing

@(private)
doc_path :: proc(a:^host.Assets,id:base.Asset_Id) -> string {
    if a!=nil {
        if file,found:=asset.registry_find(&a.registry,id);found {return file.path}
    }
    return fmt.tprintf("%016x%016x",id[0],id[1])
}

// Writes the document of the records: every token, named style, component and
// animation, or with root>=0 that node with what it holds and the styles and
// animations they take.
document_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,root:int,libs:[]Doc_Lib={},a:^host.Assets=nil) {
    first,last:=0,len(r.nodes)
    if root>=0 {first,last=root,root+records_subtree(r.nodes[:],root)+1}
    styles:=make([]bool,len(r.styles),context.temp_allocator)
    anims:=make([]bool,len(r.anims),context.temp_allocator)
    if root<0 {
        for &s,i in styles {s=records_style_named(r,i)}
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
    comma:=false
    key :: proc(out:^serial.Writer,name:string,comma:^bool) {api.write_key(out,name,!comma^);comma^=true}
    if root<0 {
        if len(r.components)>0 {
            key(out,"use",&comma);serial.write_u8(out,'[')
            for &c,i in r.components {
                if i>0 {serial.write_u8(out,',')}
                serial.text_write_string(out,doc_path(a,c.widget))
            }
            serial.write_u8(out,']')
        }
        if len(r.params)>0 {
            key(out,"params",&comma);serial.write_u8(out,'{')
            fields:=DOC_PARAM_FIELDS
            for &p,i in r.params {
                if i>0 {serial.write_u8(out,',')}
                api.write_key(out,serial.text_field(p.name[:]),true)
                node,param:=serial.text_field(p.node[:]),serial.text_field(p.param[:])
                switch {
                case param!="": serial.text_write_string(out,fmt.tprintf("%s.%s",node,param))
                case node=="":  serial.text_write_string(out,fields[p.field])
                case:           serial.text_write_string(out,fmt.tprintf("%s.%s",node,fields[p.field]))
                }
            }
            serial.write_u8(out,'}')
        }
        if len(r.tokens)>0 {
            key(out,"tokens",&comma);serial.write_u8(out,'{')
            for &t,i in r.tokens {
                if i>0 {serial.write_u8(out,',')}
                api.write_key(out,serial.text_field(t.name[:]),true)
                if t.numeric {api.write_number(out,t.number)} else {serial.text_write_string(out,doc_color_text(t.color))}
            }
            serial.write_u8(out,'}')
        }
    }
    key(out,"styles",&comma);serial.write_u8(out,'{')
    written:=false
    for wanted,row in styles {
        if !wanted || row<len(r.style_infos) && r.style_infos[row].from!=0 {continue}
        api.write_key(out,records_style_name(r,row),!written)
        written=true
        document_style_write(out,types,r,row,true,a)
    }
    serial.write_u8(out,'}')
    key(out,"animations",&comma);serial.write_u8(out,'{')
    written=false
    for wanted,row in anims {
        if !wanted || r.anims[row].name[0]==0 {continue}
        api.write_key(out,serial.text_field(r.anims[row].name[:]),!written)
        written=true
        document_anim_write(out,r,row)
    }
    serial.write_u8(out,'}')
    key(out,"nodes",&comma);serial.write_u8(out,'[')
    written=false
    w:=Doc_Write{out=out,types=types,r=r,libs=libs,assets=a,list=r.nodes[:]}
    for &n,row in r.nodes[first:last] {
        if root<0 && n.parent>=0 || root>=0 && first+row!=root {continue}
        if written {serial.write_u8(out,',')}
        written=true
        document_node_write(&w,first+row)
    }
    serial.write_u8(out,']')
    serial.write_u8(out,'}')
}

// What the writer of a node needs.
@(private)
Doc_Write :: struct {
    out:^serial.Writer,
    types:^asset.Types,
    r:^Records,
    libs:[]Doc_Lib,
    assets:^host.Assets,
    list:[]ui.Tree_Node,
}

// A style: what it extends, each key it sets, its states, variants and rules.
// With no extends every value it has that is not zero; with extends, what it
// sets itself.
@(private)
document_style_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,row:int,named:bool,a:^host.Assets=nil) {
    info:ui.Tree_Style_Info
    if row<len(r.style_infos) {info=r.style_infos[row]}
    style:=&r.styles[row]
    serial.write_u8(out,'{')
    first:=true
    comma :: proc(out:^serial.Writer,first:^bool) {if !first^ {serial.write_u8(out,',')};first^=false}
    if ext:=serial.text_field(info.extends[:]);ext!="" {
        comma(out,&first);api.write_text(out,"extends",ext,true)
    }
    if named {
        // A style a node of the file takes: its kind says its family.
        used:=records_style_users(r,row)>0
        if info.family!=.Box && !used {comma(out,&first);api.write_text(out,"family",fmt.tprintf("%v",info.family),true)}
    }
    if info.defaults!={} {
        comma(out,&first)
        api.write_key(out,"defaults",true);serial.write_u8(out,'[')
        once:=true
        for kind in info.defaults {
            if !once {serial.write_u8(out,',')}
            once=false
            serial.text_write_string(out,fmt.tprintf("%v",kind))
        }
        serial.write_u8(out,']')
    }
    doc_look_write(out,types,r,style,&info,ui.style_own_keys(&info),row,"",{},named,a,&first)
    // Rules: a state alone, a variant alone, and the rest as they are.
    rules:=make([dynamic]^ui.Tree_Style_Variant,context.temp_allocator)
    for &v in r.variants {
        if int(v.style)!=row || v.inherited {continue}
        name:=serial.text_field(v.variant[:])
        single:=name=="" && card(v.states)==1 && v.patch.tokens=={}
        if !single {append(&rules,&v);continue}
        key:=""
        for s in DOC_STATES {if s.states==v.states {key=s.key}}
        comma(out,&first)
        api.write_key(out,key,true)
        doc_rule_body_write(out,types,r,&v,row,a)
    }
    variants:=false
    for v in rules {
        name:=serial.text_field(v.variant[:])
        if name=="" || v.states!={} || v.patch.tokens!={} {continue}
        if !variants {comma(out,&first);api.write_key(out,"variants",true);serial.write_u8(out,'{')} else {serial.write_u8(out,',')}
        variants=true
        api.write_key(out,name,true)
        doc_rule_body_write(out,types,r,v,row,a)
    }
    if variants {serial.write_u8(out,'}')}
    list:=false
    for v in rules {
        name:=serial.text_field(v.variant[:])
        if name!="" && v.states=={} && v.patch.tokens=={} {continue}
        if !list {comma(out,&first);api.write_key(out,"rules",true);serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        list=true
        serial.write_u8(out,'{')
        inner:=true
        if name!="" {api.write_text(out,"variant",name,true);inner=false}
        if v.states!={} {
            api.write_key(out,"states",inner);inner=false
            serial.write_u8(out,'[')
            once:=true
            for state in v.states {
                if !once {serial.write_u8(out,',')}
                once=false
                serial.text_write_string(out,fmt.tprintf("%v",state))
            }
            serial.write_u8(out,']')
        }
        if v.patch.tokens!={} {
            none:ui.Style_Tokens
            tokens_type,_:=asset.types_index(types,ui.Style_Tokens)
            api.write_key(out,"tokens",inner);inner=false
            serial.text_write_changed(out,&types.schema,tokens_type,mem.ptr_to_bytes(&v.patch.tokens),mem.ptr_to_bytes(&none))
        }
        doc_look_write(out,types,r,&v.patch.values,nil,ui.rule_own_keys(v),row,name,v.states,false,a,&inner)
        serial.write_u8(out,'}')
    }
    if list {serial.write_u8(out,']')}
    serial.write_u8(out,'}')
}

@(private)
doc_rule_body_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,v:^ui.Tree_Style_Variant,row:int,a:^host.Assets) {
    serial.write_u8(out,'{')
    first:=true
    if v.extends!={} {
        name:=""
        for s in DOC_STATES {if s.states==v.extends {name=s.key}}
        api.write_text(out,"extends",name,true)
        first=false
    }
    doc_look_write(out,types,r,&v.patch.values,nil,ui.rule_own_keys(v),row,serial.text_field(v.variant[:]),v.states,false,a,&first)
    serial.write_u8(out,'}')
}

// The keys of a look a style or a rule sets, each one by the token that gives
// it or written out.
@(private)
doc_look_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,style:^ui.Node_Style,info:^ui.Tree_Style_Info,own:ui.Style_Keys,row:int,variant:string,states:ui.Style_States,any_zero:bool,a:^host.Assets,first:^bool) {
    zero:=doc_no_style()
    keep :: proc(style:^ui.Node_Style,zero:^ui.Node_Style,own:ui.Style_Keys,key:ui.Style_Key,by_sets:bool) -> bool {
        if key not_in own {return false}
        return by_sets || ui.style_key_differs(style,zero,key)
    }
    // A style with an extends writes what it sets even when zero; without, only what is not.
    by_sets:=own!=~ui.Style_Keys{}
    k:Doc_Key
    keys:=DOC_KEYS
    for k in keys {
        which:=k.which
        if which in ui.LAYOUT_KEYS || which==.Blur {
            if info==nil || which not_in info.sets {continue}
            doc_first(out,first,k.key)
            doc_layout_value_write(out,types,r,info,row,variant,states,which)
            continue
        }
        if !keep(style,&zero,own,which,by_sets) {continue}
        if which==.Font {
            doc_first(out,first,k.key)
            doc_font_write(out,r,style.text.font,a)
            continue
        }
        if which==.Radius {
            doc_first(out,first,k.key)
            token:=doc_token_of(r,row,variant,states,which)
            if token!="" {serial.text_write_string(out,token)} else {
                radius:=style.radius
                if radius[0]==radius[1] && radius[1]==radius[2] && radius[2]==radius[3] {api.write_number(out,radius[0])} else {api.write_list(out,radius[:])}
            }
            continue
        }
        doc_first(out,first,k.key)
        doc_style_value_write(out,r,style,row,variant,states,which)
    }
    // A shadow, a text shadow: the parts it sets.
    group :: proc(out:^serial.Writer,r:^Records,style,zero:^ui.Node_Style,own:ui.Style_Keys,by_sets:bool,name:string,parts:[]struct{key:string,which:ui.Style_Key},row:int,variant:string,states:ui.Style_States,first:^bool) {
        wrote:=false
        for p in parts {
            if p.which not_in own || !by_sets && !ui.style_key_differs(style,zero,p.which) {continue}
            if !wrote {doc_first(out,first,name);serial.write_u8(out,'{')} else {serial.write_u8(out,',')}
            wrote=true
            api.write_key(out,p.key,true)
            doc_style_value_write(out,r,style,row,variant,states,p.which)
        }
        if wrote {serial.write_u8(out,'}')}
    }
    shadow:=[?]struct{key:string,which:ui.Style_Key}{{"color",.Shadow_Color},{"blur",.Shadow_Blur},{"x",.Shadow_X},{"y",.Shadow_Y}}
    text_shadow:=[?]struct{key:string,which:ui.Style_Key}{{"color",.Text_Shadow_Color},{"x",.Text_Shadow_X},{"y",.Text_Shadow_Y}}
    group(out,r,style,&zero,own,by_sets,"shadow",shadow[:],row,variant,states,first)
    group(out,r,style,&zero,own,by_sets,"text_shadow",text_shadow[:],row,variant,states,first)
    if .Sounds in own && style.sounds!=zero.sounds {
        doc_first(out,first,"sounds");serial.write_u8(out,'{')
        once:=true
        for cue in ui.Sound_Cue {
            if style.sounds[cue]=={} {continue}
            api.write_text(out,strings.to_lower(fmt.tprintf("%v",cue),context.temp_allocator),doc_path(a,style.sounds[cue]),once)
            once=false
        }
        serial.write_u8(out,'}')
    }
}

@(private)
doc_first :: proc(out:^serial.Writer,first:^bool,key:string) {
    api.write_key(out,key,first^)
    first^=false
}

@(private)
doc_font_write :: proc(out:^serial.Writer,r:^Records,font:u8,a:^host.Assets) {
    switch {
    case font==ui.FONT_MEDIUM:   serial.text_write_string(out,"medium")
    case font==ui.FONT_SEMIBOLD: serial.text_write_string(out,"semibold")
    case int(font)>=ui.FONT_TREE && int(font)-ui.FONT_TREE<len(r.fonts): serial.text_write_string(out,doc_path(a,r.fonts[int(font)-ui.FONT_TREE].font))
    case: serial.text_write_string(out,"regular")
    }
}

// A value of a style: the token that gives it, or written out.
@(private)
doc_style_value_write :: proc(out:^serial.Writer,r:^Records,style:^ui.Node_Style,row:int,variant:string,states:ui.Style_States,which:ui.Style_Key) {
    if token:=doc_token_of(r,row,variant,states,which);token!="" {serial.text_write_string(out,token);return}
    color :: proc(out:^serial.Writer,c:ui.Color) {serial.text_write_string(out,doc_color_text(c))}
    #partial switch which {
    case .Fill: color(out,style.fill)
    case .Fill2: color(out,style.fill2)
    case .Stroke: color(out,style.stroke)
    case .Track: color(out,style.track)
    case .Knob: color(out,style.knob)
    case .Mark: color(out,style.mark)
    case .Color: color(out,style.text.color)
    case .Outline_Color: color(out,style.text.outline_color)
    case .Shadow_Color: color(out,style.shadow_color)
    case .Text_Shadow_Color: color(out,style.text.shadow_color)
    case .Border: api.write_number(out,style.stroke_width)
    case .Size: api.write_number(out,style.text.size)
    case .Outline: api.write_number(out,style.text.outline)
    case .Shadow_Blur: api.write_number(out,style.shadow_blur)
    case .Shadow_X: api.write_number(out,style.shadow_offset.x)
    case .Shadow_Y: api.write_number(out,style.shadow_offset.y)
    case .Text_Shadow_X: api.write_number(out,style.text.shadow.x)
    case .Text_Shadow_Y: api.write_number(out,style.text.shadow.y)
    case .Move_X: api.write_number(out,style.move.x)
    case .Move_Y: api.write_number(out,style.move.y)
    case .Scale: api.write_number(out,style.scale)
    case .Line_Height: api.write_number(out,style.text.line_height)
    case .Transition: api.write_number(out,style.transition)
    case .Text_Align_X: serial.text_write_string(out,doc_enum_text(style.text.align_x))
    case .Text_Align_Y: serial.text_write_string(out,doc_enum_text(style.text.align_y))
    case .Text_Wrap: serial.text_write_string(out,doc_enum_text(style.text.wrap))
    case .Ellipsis: api.write_flag(out,style.text.ellipsis)
    case .Fill_Mode: serial.text_write_string(out,doc_enum_text(style.fill_mode))
    case .Program: serial.text_write_string(out,serial.text_field(style.program[:]))
    case .Program_Values: values:=style.program_values;api.write_list(out,values[:])
    }
}

// A value of the layout or the blur of a style.
@(private)
doc_layout_value_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,info:^ui.Tree_Style_Info,row:int,variant:string,states:ui.Style_States,which:ui.Style_Key) {
    if token:=doc_token_of(r,row,variant,states,which);token!="" {serial.text_write_string(out,token);return}
    if which==.Blur {api.write_number(out,info.blur);return}
    doc_layout_write(out,types,&info.layout,which)
}

@(private)
doc_vector_write :: proc(out:^serial.Writer,property:ui.Anim_Property,v:[4]f32) {
    v:=v
    #partial switch property {
    case .Scale: if v[0]==v[1] {api.write_number(out,v[0])} else {api.write_list(out,v[:2])}
    case .Offset: api.write_list(out,v[:2])
    case .Color: api.write_list(out,v[:4])
    case: api.write_number(out,v[0])
    }
}

@(private)
document_anim_write :: proc(out:^serial.Writer,r:^Records,row:int) {
    anim:=r.anims[row]
    short:=doc_anim_short(r,row)
    serial.write_u8(out,'{')
    first:=true
    if anim.kind!=.Clip {api.write_text(out,"kind",fmt.tprintf("%v",anim.kind),first);first=false}
    if short {
        tracks:=r.tracks[anim.first:][:anim.count]
        seconds:=r.keys[tracks[0].first_key+1].time
        ease:=r.keys[tracks[0].first_key+1].ease
        for t in tracks {
            api.write_key(out,strings.to_lower(fmt.tprintf("%v",t.property),context.temp_allocator),first);first=false
            serial.write_u8(out,'[')
            doc_vector_write(out,t.property,r.keys[t.first_key].value)
            serial.write_u8(out,',')
            doc_vector_write(out,t.property,r.keys[t.first_key+1].value)
            serial.write_u8(out,']')
        }
        api.write_key(out,"seconds");api.write_number(out,seconds)
        if ease!=.Linear {api.write_text(out,"ease",fmt.tprintf("%v",ease))}
    } else if anim.kind==.Clip {
        api.write_key(out,"tracks",first);first=false
        serial.write_u8(out,'[')
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
        api.write_key(out,"parts",first);first=false
        serial.write_u8(out,'[')
        for part,pi in r.parts[anim.first:][:anim.count] {
            if pi>0 {serial.write_u8(out,',')}
            name:=serial.text_field(r.anims[part-1].name[:]) if part>0 && int(part)<=len(r.anims) else ""
            serial.text_write_string(out,name)
        }
        serial.write_u8(out,']')
    }
    if anim.loop!=.Once {api.write_text(out,"loop",fmt.tprintf("%v",anim.loop),first);first=false}
    serial.write_u8(out,'}')
}

// Whether an animation is a few fields: a clip whose tracks each go from a
// value at 0 to one at the same time, with the same ease.
@(private)
doc_anim_short :: proc(r:^Records,row:int) -> bool {
    a:=r.anims[row]
    if a.kind!=.Clip || a.count==0 || u64(a.first)+u64(a.count)>u64(len(r.tracks)) {return false}
    seconds:f32
    ease:ui.Ease
    for t,i in r.tracks[a.first:][:a.count] {
        if t.key_count!=2 || u64(t.first_key)+2>u64(len(r.keys)) {return false}
        from,to:=r.keys[t.first_key],r.keys[t.first_key+1]
        if from.time!=0 || from.ease!=.Linear {return false}
        if i==0 {seconds,ease=to.time,to.ease} else if to.time!=seconds || to.ease!=ease {return false}
    }
    return true
}

// A node as its parent writes it: {name, kind, ... , children}.
@(private)
document_node_write :: proc(w:^Doc_Write,row:int) {
    serial.write_u8(w.out,'{')
    document_node_body_write(w,row)
    serial.write_u8(w.out,'}')
}

// What a node says, without its braces.
@(private)
document_node_body_write :: proc(w:^Doc_Write,row:int) {
    out:=w.out
    r:=w.r
    n:=w.list[row]
    first:=false
    api.write_text(out,"name",serial.text_field(n.name[:]),true)
    template:=int(n.component)-1
    widget:base.Asset_Id
    if n.kind==.Component {
        component_name:=""
        if template>=0 && template<len(r.components) {
            c:=&r.components[template]
            widget=c.widget
            component_name=doc_use_name(w.assets,c.widget,serial.text_field(c.name[:]))
        }
        api.write_text(out,"kind",component_name,first)
    } else {
        api.write_text(out,"kind",fmt.tprintf("%v",n.kind),first)
    }
    if text:=records_text(r,n.text);text!="" {api.write_text(out,"text",text)}
    style:=int(n.style)
    if style==0 {
        // None, where a node without a style would take the one of its kind.
        if _,has:=node_default_look(n.kind);has || records_kind_style(r,n.kind)>=0 {api.write_text(out,"style","")}
    } else if style<len(r.styles) {
        if records_style_named(r,style) {
            api.write_text(out,"style",records_style_name(r,style))
        } else if !doc_is_kind_look(r,style,n.kind) {
            api.write_key(out,"look");document_style_write(out,w.types,r,style,false,w.assets)
        }
    }
    if n.image!=0 && int(n.image)<=len(r.images) {doc_image_write(w,&r.images[n.image-1])}
    if n.anims!=0 && int(n.anims)<=len(r.anim_sets) {
        set:=r.anim_sets[n.anims-1]
        api.write_key(out,"events");serial.write_u8(out,'{')
        names:=DOCUMENT_EVENTS
        once:=true
        for played,i in (^[len(DOCUMENT_EVENTS)]ui.Anim)(&set)^ {
            if played==0 || int(played)>len(r.anims) {continue}
            api.write_text(out,names[i],serial.text_field(r.anims[played-1].name[:]),once)
            once=false
        }
        serial.write_u8(out,'}')
    }
    // The values of the parameters of a use, by their names.
    root_fields:=make([dynamic]string,context.temp_allocator)
    fields:=DOC_PARAM_FIELDS
    if lib:=doc_lib_of(w.libs,widget);lib!=nil {
        for &p in lib.linked.params {
            if value,has:=doc_param_value(w,row,&p);has {api.write_text(out,serial.text_field(p.name[:]),value)}
            if serial.text_field(p.node[:])=="" {append(&root_fields,fields[p.field])}
        }
    }
    doc_node_fields_write(w,row,&n,root_fields[:])
    if .Slot in n.flags {api.write_bool(out,"slot",true)}
    end:=row+records_subtree(w.list,row)
    children:=false
    for child in row+1..=end {
        if int(w.list[child].parent)!=row {continue}
        if !children {api.write_key(out,"children");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        children=true
        document_node_write(w,child)
    }
    if children {serial.write_u8(out,']')}
}

// The group of fields of an instance or an override a field of a parameter is in.
@(private)
doc_param_group :: proc(field:ui.Tree_Param_Field) -> ui.Node_Field {
    #partial switch field {
    case .Text:    return .Text
    case .Style:   return .Style
    case .Variant: return .Variant
    case .Action:  return .Action
    case .Tag,.Accepts: return .Drag
    }
    return .Bindings
}

// The text field of a node that a parameter of bind or data goes to; nil for text and style.
@(private)
doc_param_slot :: proc(n:^ui.Tree_Node,field:ui.Tree_Param_Field) -> []u8 {
    #partial switch field {
    case .Data:          return n.data[:]
    case .Bind_Text:     return n.bind_text[:]
    case .Bind_Value:    return n.bind_value[:]
    case .Bind_Visible:  return n.bind_visible[:]
    case .Bind_Selected: return n.bind_selected[:]
    case .Bind_Disabled: return n.bind_disabled[:]
    case .Bind_Items:    return n.bind_items[:]
    case .Bind_Image:    return n.bind_image[:]
    case .Bind_Tint:     return n.bind_tint[:]
    case .Bind_Variant:  return n.bind_variant[:]
    case .Variant:       return n.variant[:]
    case .Action:        return n.action[:]
    case .Tag:           return n.tag[:]
    case .Accepts:       return n.accepts[:]
    }
    return nil
}

// What a use says of a parameter: what the instance or its override has.
@(private)
doc_param_value :: proc(w:^Doc_Write,row:int,p:^ui.Tree_Param) -> (value:string,has:bool) {
    r:=w.r
    n:=&w.list[row]
    target:^ui.Tree_Node
    group:=doc_param_group(p.field)
    if node:=serial.text_field(p.node[:]);node=="" {
        if group not_in n.component_fields {return "",false}
        target=n
    } else {
        for &o in r.overrides {
            if int(o.instance)==row && serial.text_field(o.node[:])==node && group in o.fields {target=&o.values;break}
        }
        if target==nil {return "",false}
    }
    switch p.field {
    case .Text:  return records_text(r,target.text),true
    case .Style:
        if int(target.style)<len(r.styles) && records_style_named(r,int(target.style)) {return records_style_name(r,int(target.style)),true}
        return "",false
    case .Data,.Bind_Text,.Bind_Value,.Bind_Visible,.Bind_Selected,.Bind_Disabled,.Bind_Items,.Bind_Image,.Bind_Tint,.Bind_Variant,.Variant,.Action,.Tag,.Accepts:
        return serial.text_field(doc_param_slot(target,p.field)),true
    }
    return "",false
}

// Whether a style without a name is the look a new node of the kind takes:
// what a node that says no style gets when it is written.
@(private)
doc_is_kind_look :: proc(r:^Records,row:int,kind:ui.Node_Kind) -> bool {
    look,has:=node_default_look(kind)
    if !has || row>=len(r.styles) || r.styles[row]!=look || row<len(r.style_infos) && r.style_infos[row].extends[0]!=0 {return false}
    for &v in r.variants {if int(v.style)==row {return false}}
    return true
}

// Its image, with the texture by its path.
@(private)
doc_image_write :: proc(w:^Doc_Write,image:^ui.Tree_Image) {
    out:=w.out
    api.write_key(out,"image");serial.write_u8(out,'{')
    api.write_text(out,"texture",doc_path(w.assets,image.texture),true)
    image_type,_:=asset.types_index(w.types,ui.Tree_Image)
    defaults:=ui.Tree_Image{texture=image.texture}
    doc_changed_write(w,image_type,mem.ptr_to_bytes(image),mem.ptr_to_bytes(&defaults),{"texture"})
    serial.write_u8(out,'}')
}

// The fields of a value that differ from defaults as keys of the object
// being written; each after a comma.
@(private)
doc_changed_write :: proc(w:^Doc_Write,type:serial.Type_Index,data,defaults:[]u8,skip:[]string) {
    buffer:=make([]u8,1<<14,context.temp_allocator)
    temp:serial.Writer
    serial.writer_init_fixed(&temp,buffer)
    serial.text_write_changed(&temp,&w.types.schema,type,data,defaults,skip=skip)
    text:=string(serial.writer_bytes(&temp))
    inner:=text[1:len(text)-1]
    if inner=="" {return}
    serial.write_u8(w.out,',')
    serial.text_write_raw(w.out,inner)
}

// What the node sets flat: its fields that differ from a new node of its
// kind, and of its layout what is its own or its style does not give it.
@(private)
doc_node_fields_write :: proc(w:^Doc_Write,row:int,n:^ui.Tree_Node,root_params:[]string) {
    r:=w.r
    defaults:=node_default(n.kind)
    defaults.parent=n.parent
    shown:=n^
    shown.flags-={.Localized,.Slot}
    node_type,_:=asset.types_index(w.types,ui.Tree_Node)
    skip:=make([dynamic]string,context.temp_allocator)
    base_skip:=DOCUMENT_NODE_SKIP
    append(&skip,..base_skip[:])
    append(&skip,..root_params)
    if n.kind==.Component {
        // The instance says only what it sets of its template.
        groups:=n.component_fields
        for group in ui.Node_Field {
            if group in groups {continue}
            #partial switch group {
            case .Bindings:   append(&skip,"bind_text","bind_value","bind_visible","bind_selected","bind_disabled","bind_items","bind_image","bind_tint","bind_variant","data")
            case .Visibility: append(&skip,"selected","disabled")
            case .Variant:    append(&skip,"variant")
            case .Layer:      append(&skip,"layer")
            case .Clip:       append(&skip,"clip")
            case .Block:      append(&skip,"block")
            case .Values:     append(&skip,"index","count","choice","limit","delay","range","particle")
            case .Action:     append(&skip,"action","hold")
            case .Focus:      append(&skip,"nav","order","flags")
            case .Drag:       append(&skip,"tag","accepts","ghost")
            case .Float:      append(&skip,"float")
            }
        }
    }
    doc_changed_write(w,node_type,mem.ptr_to_bytes(&shown),mem.ptr_to_bytes(&defaults),skip[:])
    if n.kind==.Component && .Layout not_in n.component_fields {return}
    info:ui.Tree_Style_Info
    if int(n.style)<len(r.style_infos) {info=r.style_infos[n.style]}
    d:=defaults.layout
    keys:=DOC_KEYS
    out:=w.out
    for k in keys {
        which:=k.which
        if which not_in ui.LAYOUT_KEYS {continue}
        given:=which in info.layout_keys && which not_in n.layout_own
        if given {continue}
        probe:=n.layout
        ui.layout_key_copy(&probe,&d,which)
        same:=probe==n.layout
        if which not_in n.layout_own && same {continue}
        api.write_key(out,k.key)
        doc_layout_write(out,w.types,&n.layout,which)
    }
}

// A key of a layout as a document says it.
@(private)
doc_layout_write :: proc(out:^serial.Writer,types:^asset.Types,l:^ui.Layout,which:ui.Style_Key) {
    #partial switch which {
    case .Width:     doc_size_write(out,types,l.width)
    case .Height:    doc_size_write(out,types,l.height)
    case .Direction: serial.text_write_string(out,doc_enum_text(l.direction))
    case .Padding:   doc_padding_write(out,l.padding)
    case .Gap:       api.write_number(out,l.gap)
    case .Align_X:   serial.text_write_string(out,doc_enum_text(l.align_x))
    case .Align_Y:   serial.text_write_string(out,doc_enum_text(l.align_y))
    case .Columns:   api.write_number(out,f32(l.columns))
    case .Span:      api.write_number(out,f32(l.span))
    case .Self_X:    serial.text_write_string(out,doc_enum_text(l.self_x))
    case .Self_Y:    serial.text_write_string(out,doc_enum_text(l.self_y))
    case .Aspect:    api.write_number(out,l.aspect)
    }
}

// ---------------------------------------------------------------- reading

// A node of a document, read in pre-order.
@(private)
Document_Node :: struct {
    keys,values:[dynamic]string,
    path:string,  // where it is in the document, for errors
    name:string,  // as declared; empty: none
    kind:ui.Node_Kind,
    widget:base.Asset_Id, // the file of a use
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
// and what it holds, and otherwise the whole file. Tokens and styles go
// first, since nodes take them by name; those it takes away, last. False
// after failing the call, with where in the document.
document_apply :: proc(args:^Tree_Args,r:^Records,root:int,text:string) -> (made,removed:int,ok:bool) {
    call:=args.call
    keys,values:=tree_object(call,text,"document") or_return
    use,params,tokens,styles,anims,nodes:string
    for key,i in keys {
        switch key {
        case "use":        use=values[i]
        case "params":     params=values[i]
        case "tokens":     tokens=values[i]
        case "styles":     styles=values[i]
        case "animations": anims=values[i]
        case "nodes":      nodes=values[i]
        case "components":
            api.call_fail(call,api.INVALID_PARAMS,"document has no 'components': a component is a widget, a .ui of its own; write it as a file and name it in use")
            return
        case:
            api.call_failf(call,api.INVALID_PARAMS,"document has no '%s'; it has use, params, tokens, styles, animations and nodes",key)
            return
        }
    }
    // What the document takes from other files, before any name is read.
    used:=make([dynamic]base.Asset_Id,call.allocator)
    if use!="" {
        items,items_ok:=doc_items(call,use,"use")
        if !items_ok {return}
        for item,i in items {
            path,is_text:=doc_string(call,item)
            if !is_text {api.call_failf(call,api.INVALID_PARAMS,"use[%d] must be the path of a .ui",i);return}
            what:=fmt.tprintf("use[%d]",i)
            id:=doc_use_resolve(args,path,what) or_return
            if id==args.asset {api.call_failf(call,api.INVALID_PARAMS,"use[%d]: a .ui takes names from other files, not from itself",i);return}
            if chain:=doc_reaches(args.assets,id,args.asset);chain!="" {api.call_failf(call,api.INVALID_PARAMS,"use[%d]: '%s' uses this file back, a cycle: %s",i,path,chain);return}
            name:=doc_use_name(args.assets,id,"")
            for k in ui.Node_Kind {if fmt.tprintf("%v",k)==name {api.call_failf(call,api.INVALID_PARAMS,"use[%d]: a node kind goes by the name '%s'; give the file another",i,name);return}}
            for other,j in used {
                if other!=id && doc_use_name(args.assets,other,"")==name {api.call_failf(call,api.INVALID_PARAMS,"use[%d]: '%s' goes by the name of use[%d]; a use names a widget by its file: give one another name",i,path,j);return}
            }
            append(&used,id)
            records_use_row(r,id,name)
        }
    }
    libs:=doc_libs(args,r,used[:])
    args.libs=&libs
    defer args.libs=nil
    if tokens!="" && !doc_tokens_apply(call,r,tokens) {return}
    gone_styles:=make([dynamic]string,call.allocator)
    gone_anims:=make([dynamic]string,call.allocator)
    if styles!="" {
        style_keys,style_values:=tree_object(call,styles,"styles") or_return
        // Every name first, so that a style can extend one declared after it.
        for name,i in style_keys {
            if strings.trim_space(style_values[i])=="null" {continue}
            if tree_style_row(r,name)>=0 && r.style_infos[tree_style_row(r,name)].from==0 {continue}
            if name=="" || len(name)>=ui.TREE_NAME_CAPACITY {api.call_failf(call,api.INVALID_PARAMS,"styles.%s: a style has a name shorter than %d bytes",name,ui.TREE_NAME_CAPACITY);return}
            info:=ui.Tree_Style_Info{}
            ui.tree_text_set(info.name[:],name)
            // A style of this name that was another file's becomes this one.
            if row:=tree_style_row(r,name);row>=0 {
                r.style_infos[row].from=0
            } else if records_style_add(r,{},{},info)<0 {
                api.call_fail(call,api.SERVER_ERROR,"the .ui holds no more styles");return
            }
        }
        for name,i in style_keys {
            what:=fmt.tprintf("styles.%s",name)
            if strings.trim_space(style_values[i])=="null" {append(&gone_styles,name);continue}
            style_args:=args^
            style_args.keys,style_args.values,ok=tree_object(call,style_values[i],what)
            if !ok {return}
            if !document_style_apply(&style_args,r,tree_style_row(r,name),true) {ok=document_failed(call,what);return}
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
    // An animation without a name nothing plays is of a file written before names: it goes.
    if root<0 {
        for i:=len(r.anims)-1;i>=0;i-=1 {
            if r.anims[i].name[0]!=0 {continue}
            used:=false
            for &set in r.anim_sets {for played in (^[len(DOCUMENT_EVENTS)]ui.Anim)(&set)^ {used||=int(played)==i+1}}
            if !used {records_anim_remove(r,i)}
        }
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
    // A file the whole document no longer uses goes; while a node or a style
    // takes from it, that says so.
    if root<0 && use!="" {
        for i:=len(r.components)-1;i>=0;i-=1 {
            id:=r.components[i].widget
            if slice.contains(used[:],id) {continue}
            if !records_use_remove(r,i) {
                api.call_failf(call,api.INVALID_PARAMS,"use: '%s' is not listed, but a node is a use of it or a style takes from it; change them in the same document",doc_path(args.assets,id))
                return
            }
        }
    }
    // A named style a node of the file takes is of the family of that node.
    if root<0 {
        for &n in r.nodes {doc_style_family(r,&n)}
        if params!="" && !document_params_apply(args,r,params) {return made,removed,false}
        if !document_widget_shape(call,r) {return made,removed,false}
    }
    if nodes!="" && !document_paths_check(args,r,root) {return made,removed,false}
    return made,removed,true
}

@(private)
doc_style_family :: proc(r:^Records,n:^ui.Tree_Node) {
    if int(n.style)>0 && int(n.style)<len(r.style_infos) && records_style_named(r,int(n.style)) {r.style_infos[n.style].family=style_family(n.kind)}
}

@(private)
doc_tokens_apply :: proc(call:^api.Call,r:^Records,text:string) -> bool {
    keys,values:=tree_object(call,text,"tokens") or_return
    for name,i in keys {
        row:=-1
        for &t,j in r.tokens {if serial.text_field(t.name[:])==name {row=j;break}}
        value:=strings.trim_space(values[i])
        if value=="null" {
            if row>=0 {ordered_remove(&r.tokens,row)}
            continue
        }
        token:ui.Tree_Token
        if name=="" || len(name)>=ui.TREE_NAME_CAPACITY {api.call_failf(call,api.INVALID_PARAMS,"tokens.%s: a token has a name shorter than %d bytes",name,ui.TREE_NAME_CAPACITY);return false}
        ui.tree_text_set(token.name[:],name)
        if number,is_number:=doc_number(value);is_number {
            token.numeric,token.number=true,number
        } else if word,is_text:=doc_string(call,value);is_text {
            color,parsed:=doc_color_parse(word)
            if !parsed {api.call_failf(call,api.INVALID_PARAMS,"tokens.%s: '%s' is no color: write #rrggbb or #rrggbbaa",name,word);return false}
            token.color=color
        } else {
            api.call_failf(call,api.INVALID_PARAMS,"tokens.%s must be a number or a color, #rrggbb or #rrggbbaa",name)
            return false
        }
        if row>=0 {r.tokens[row]=token} else {append(&r.tokens,token)}
    }
    return true
}

// A style as the document declares it, at row: what it extends, its values,
// states, variants and rules. named false for a look of a node.
@(private)
document_style_apply :: proc(args:^Tree_Args,r:^Records,row:int,named:bool) -> bool {
    call:=args.call
    if row>=len(r.style_infos) {resize(&r.style_infos,len(r.styles))}
    info:=&r.style_infos[row]
    r.styles[row]={}
    info.defaults,info.extends,info.sets,info.layout,info.layout_keys,info.blur={},{},{},{},{},0
    for i:=len(r.variants)-1;i>=0;i-=1 {if int(r.variants[i].style)==row {ordered_remove(&r.variants,i)}}
    for i:=len(r.token_uses)-1;i>=0;i-=1 {if int(r.token_uses[i].style)==row {ordered_remove(&r.token_uses,i)}}
    style:=&r.styles[row]
    for key,i in args.keys {
        value:=args.values[i]
        switch key {
        case "family":
            if !named {api.call_fail(call,api.INVALID_PARAMS,"family: a look is of the family of its node");return false}
            text,_,read:=tree_arg_string(args,"family")
            if !read {return false}
            known:=false
            for f in ui.Style_Family {if fmt.tprintf("%v",f)==text {info.family,known=f,true}}
            if !known {api.call_failf(call,api.INVALID_PARAMS,"family '%s' is none of Box, Text, Control",text);return false}
        case "extends":
            word,is_text:=doc_string(call,value)
            if !is_text {api.call_fail(call,api.INVALID_PARAMS,"extends must be the name of a style");return false}
            ui.tree_text_set(info.extends[:],word)
        case "defaults","hover","focus","pressed","disabled","selected","over","variants","rules":
        case:
            if !doc_style_value_apply(args,r,row,style,info,&info.sets,"",{},key,value) {return false}
        }
    }
    if ext:=serial.text_field(info.extends[:]);ext!="" {
        if doc_style_known(args,r,ext)<0 {api.call_failf(call,api.INVALID_PARAMS,"extends: '%s' is no style of this file or of a file it uses",ext);return false}
        // A look is the override of a style of the file: one another file
        // lends has a row here too, made the first time.
        if !named {
            if doc_style_row(args,r,ext)<0 {api.call_failf(call,api.SERVER_ERROR,"the .ui holds no more styles");return false}
            info=&r.style_infos[row]
        }
    }
    if text,found:=tree_arg(args,"defaults");found {
        kinds,read:=tree_kinds_read(call,text,info.family)
        if !read {return false}
        records_kind_style_set(r,row,kinds)
    }
    for s in DOC_STATES {
        text,found:=tree_arg(args,s.key)
        if !found {continue}
        rule_keys,rule_values:=tree_object(call,text,s.key) or_return
        rule:=doc_rule_row(r,row,"",s.states)
        if !doc_rule_apply(args,r,row,rule,rule_keys,rule_values,s.key) {return document_failed(call,s.key)}
    }
    if text,found:=tree_arg(args,"variants");found {
        keys,values:=tree_object(call,text,"variants") or_return
        for name,i in keys {
            what:=fmt.tprintf("variants.%s",name)
            rule_keys,rule_values:=tree_object(call,values[i],what) or_return
            rule:=doc_rule_row(r,row,name,{})
            if !doc_rule_apply(args,r,row,rule,rule_keys,rule_values,what) {return document_failed(call,what)}
        }
    }
    if text,found:=tree_arg(args,"rules");found {
        items:=doc_items(call,text,"rules") or_return
        for item,at in items {
            what:=fmt.tprintf("rules[%d]",at)
            rule_keys,rule_values:=tree_object(call,item,what) or_return
            rule_args:=args^
            rule_args.keys,rule_args.values=rule_keys,rule_values
            variant,_,variant_ok:=tree_arg_string(&rule_args,"variant")
            if !variant_ok {return false}
            states:ui.Style_States
            if states_text,has:=tree_arg(&rule_args,"states");has {
                names:=doc_items(call,states_text,what) or_return
                for name_item in names {
                    state_name,is_text:=doc_string(call,name_item)
                    known:=false
                    for state in ui.Style_State {if is_text && fmt.tprintf("%v",state)==state_name {states+={state};known=true}}
                    if !known {api.call_failf(call,api.INVALID_PARAMS,"%s.states: '%s' is none of Selected, Hovered, Focused, Over, Pressed, Disabled",what,state_name);return false}
                }
            }
            look_keys:=make([dynamic]string,call.allocator)
            look_values:=make([dynamic]string,call.allocator)
            tokens_text:=""
            for key,i in rule_keys {
                switch key {
                case "variant","states":
                case "tokens": tokens_text=rule_values[i]
                case: append(&look_keys,key);append(&look_values,rule_values[i])
                }
            }
            rule:=doc_rule_row(r,row,variant,states)
            if !doc_rule_apply(args,r,row,rule,look_keys,look_values,what) {return document_failed(call,what)}
            if tokens_text!="" {
                v:=&r.variants[rule]
                if !tree_fields_read(call,args.types,ui.Style_Tokens,&v.patch.tokens,tokens_text,"tokens") {return false}
                t:=v.patch.tokens
                if t.fill!=.Literal {v.patch.fields+={.Fill}}
                if t.fill2!=.Literal {v.patch.fields+={.Fill2}}
                if t.stroke!=.Literal {v.patch.fields+={.Stroke}}
                if t.text!=.Literal {v.patch.fields+={.Text_Color}}
                if t.track!=.Literal {v.patch.fields+={.Track}}
                if t.knob!=.Literal {v.patch.fields+={.Knob}}
                if t.mark!=.Literal {v.patch.fields+={.Mark}}
            }
        }
    }
    return true
}

// Whether a style of this name exists; -1: none.
@(private)
doc_style_known :: proc(args:^Tree_Args,r:^Records,name:string) -> int {
    if row:=tree_style_row(r,name);row>=0 {return row}
    if args.libs==nil {return -1}
    for &lib in args.libs {
        for &info,i in lib.records.style_infos {if serial.text_field(info.name[:])==name {return i}}
    }
    return -1
}

// The rule of a style for a variant and states, made the first time.
@(private)
doc_rule_row :: proc(r:^Records,style:int,variant:string,states:ui.Style_States) -> int {
    for &v,i in r.variants {
        if int(v.style)==style && v.states==states && serial.text_field(v.variant[:])==variant {return i}
    }
    rule:=ui.Tree_Style_Variant{style=u16(style),states=states}
    ui.tree_text_set(rule.variant[:],variant)
    append(&r.variants,rule)
    return len(r.variants)-1
}

// The keys of a state, a variant or a rule of the style at row.
@(private)
doc_rule_apply :: proc(args:^Tree_Args,r:^Records,style,rule:int,keys,values:[dynamic]string,what:string) -> bool {
    call:=args.call
    rule_args:=args^
    rule_args.keys,rule_args.values=keys,values
    own:ui.Style_Keys
    v:=&r.variants[rule]
    variant:=strings.clone(serial.text_field(v.variant[:]),call.allocator)
    states:=v.states
    for key,i in keys {
        if key=="extends" {
            word,is_text:=doc_string(call,values[i])
            found:ui.Style_States
            ok:=false
            for s in DOC_STATES {if is_text && s.key==word {found,ok=s.states,true}}
            if !ok {api.call_failf(call,api.INVALID_PARAMS,"extends: '%s' is no state; it has hover, focus, pressed, disabled, selected and over",word);return false}
            r.variants[rule].extends=found
            continue
        }
        if !doc_style_value_apply(&rule_args,r,style,&r.variants[rule].patch.values,nil,&own,variant,states,key,values[i]) {return false}
    }
    v=&r.variants[rule]
    if v.extends!={} {
        found:=false
        for &other in r.variants {found||=int(other.style)==style && other.states==v.extends && other.variant==v.variant}
        if !found {api.call_failf(call,api.INVALID_PARAMS,"extends: the style has no rule for that state; declare it in the same document");return false}
    }
    v.own=own
    v.patch.fields=ui.style_keys_fields(own)
    return true
}

// One key of a look: a color, a number, or their names. own gets what it sets.
@(private)
doc_style_value_apply :: proc(args:^Tree_Args,r:^Records,row:int,style:^ui.Node_Style,info:^ui.Tree_Style_Info,own:^ui.Style_Keys,variant:string,states:ui.Style_States,key,value:string) -> bool {
    call:=args.call
    is_rule:=info==nil
    which:ui.Style_Key
    found:=false
    table:=DOC_KEYS
    for k in table {
        if k.key==key {which,found=k.which,true;break}
    }
    if !found {
        switch key {
        case "shadow":
            return doc_shadow_read(args,r,row,style,own,variant,states,value,{{"color",.Shadow_Color},{"blur",.Shadow_Blur},{"x",.Shadow_X},{"y",.Shadow_Y}},"shadow")
        case "text_shadow":
            return doc_shadow_read(args,r,row,style,own,variant,states,value,{{"color",.Text_Shadow_Color},{"x",.Text_Shadow_X},{"y",.Text_Shadow_Y}},"text_shadow")
        case "sounds":
            if is_rule {api.call_failf(call,api.INVALID_PARAMS,"sounds: a state does not change them");return false}
            own^+={.Sounds}
            cues:=DOC_SOUND_CUES
            keys,values:=tree_object(call,value,"sounds") or_return
            for cue_name,i in keys {
                cue:ui.Sound_Cue
                known:=false
                for c,j in cues {if c==cue_name {cue=ui.Sound_Cue(j);known=true}}
                if !known {api.call_failf(call,api.INVALID_PARAMS,"sounds has no '%s'; it has show, hide, hover, focus, press and change",cue_name);return false}
                path,_:=doc_string(call,values[i])
                id,problem:=editor.asset_resolve(args.session,path,".sound")
                if problem!="" {api.call_failf(call,api.INVALID_PARAMS,"sounds.%s: %s",cue_name,problem);return false}
                style.sounds[cue]=id
            }
            return true
        }
        names:=make([dynamic]string,context.temp_allocator)
        for k in table {append(&names,k.key)}
        append(&names,"shadow","text_shadow")
        if is_rule {
            api.call_failf(call,api.INVALID_PARAMS,"a state has no '%s'; it has %s and extends",key,strings.join(names[:],", ",context.temp_allocator))
            return false
        }
        api.call_failf(call,api.INVALID_PARAMS,"a style has no '%s'; it has extends, %s, sounds, hover, focus, pressed, disabled, selected, over, variants and rules",key,strings.join(names[:],", ",context.temp_allocator))
        return false
    }
    if is_rule && which not_in ui.RULE_KEYS {
        api.call_failf(call,api.INVALID_PARAMS,"a state does not set %s: it goes in the style",key)
        return false
    }
    own^+={which}
    trimmed:=strings.trim_space(value)
    token:string
    set:=false
    switch {
    case ui.style_key_color(which):
        color:ui.Color
        color,token=doc_color_value(args,r,trimmed,key) or_return
        ui.style_key_color_set(style,which,color)
        set=true
    case which==.Radius:
        if number,is_number:=doc_number(trimmed);is_number {
            style.radius={number,number,number,number}
            set=true
        } else if word,is_text:=doc_string(call,trimmed);is_text {
            number:=doc_number_token(args,r,word,"radius") or_return
            style.radius={number,number,number,number}
            token,set=word,true
        } else {
            items:=doc_items(call,trimmed,"radius") or_return
            if len(items)!=4 {api.call_fail(call,api.INVALID_PARAMS,"radius: give a number, a token or four numbers");return false}
            for item,i in items {
                n,ok:=doc_number(item)
                if !ok {api.call_fail(call,api.INVALID_PARAMS,"radius: give numbers");return false}
                style.radius[i]=n
            }
            set=true
        }
    case which==.Font:
        word,is_text:=doc_string(call,trimmed)
        if !is_text {api.call_fail(call,api.INVALID_PARAMS,"font must be regular, medium, semibold, or the path of a .font");return false}
        switch word {
        case "regular":  style.text.font=ui.FONT_REGULAR
        case "medium":   style.text.font=ui.FONT_MEDIUM
        case "semibold": style.text.font=ui.FONT_SEMIBOLD
        case:
            if args.session==nil {api.call_failf(call,api.INVALID_PARAMS,"font: no project to read '%s' from",word);return false}
            id,problem:=editor.asset_resolve(args.session,word,".font")
            if problem!="" {api.call_failf(call,api.INVALID_PARAMS,"font: %s",problem);return false}
            at:=-1
            for &f,i in r.fonts {if f.font==id {at=i}}
            if at<0 {append(&r.fonts,ui.Tree_Font{font=id});at=len(r.fonts)-1}
            style.text.font=u8(ui.FONT_TREE+at)
        }
        set=true
    case which in ui.LAYOUT_KEYS:
        token=doc_layout_read(args,r,&info.layout,which,key,trimmed) or_return
        set=true
    case which==.Text_Align_X:
        if !doc_enum_read(call,trimmed,"text_x",ui.Align,&style.text.align_x) {return false}
        set=true
    case which==.Text_Align_Y:
        if !doc_enum_read(call,trimmed,"text_y",ui.Align,&style.text.align_y) {return false}
        set=true
    case which==.Text_Wrap:
        if !doc_enum_read(call,trimmed,"wrap",ui.Text_Wrap,&style.text.wrap) {return false}
        set=true
    case which==.Fill_Mode:
        if !doc_enum_read(call,trimmed,"fill_mode",ui.Progress_Fill,&style.fill_mode) {return false}
        set=true
    case which==.Ellipsis:
        b,is_bool:=doc_bool(trimmed)
        if !is_bool {api.call_fail(call,api.INVALID_PARAMS,"ellipsis must be true or false");return false}
        style.text.ellipsis=b
        set=true
    case which==.Program:
        word,is_text:=doc_string(call,trimmed)
        if !is_text {api.call_fail(call,api.INVALID_PARAMS,"program must be the name of a ui program");return false}
        ui.tree_text_set(style.program[:],word)
        set=true
    case which==.Program_Values:
        items:=doc_items(call,trimmed,"program_values") or_return
        for item,i in items {
            if i>=4 {break}
            n,ok:=doc_number(item)
            if !ok {api.call_fail(call,api.INVALID_PARAMS,"program_values: give numbers");return false}
            style.program_values[i]=n
        }
        set=true
    case which==.Blur || ui.style_key_number(which):
        number:f32
        number,token=doc_number_value(args,r,trimmed,key) or_return
        if which==.Blur {info.blur=number} else {ui.style_key_number_set(style,info,which,number)}
        set=true
    }
    if !set {api.call_failf(call,api.INVALID_PARAMS,"%s cannot be set",key);return false}
    if which==.Shadow_Color && !is_rule {style.shadow=style.shadow_color[3]>0}

    if token!="" {records_token_use(r,row,variant,states,which,token)}
    return true
}

@(private)
DOC_SOUND_CUES :: [?]string{"show","hide","hover","focus","press","change"}

@(private)
doc_libs_slice :: proc(args:^Tree_Args) -> []Doc_Lib {
    if args.libs==nil {return nil}
    return args.libs[:]
}

// The object of a shadow: color, blur, x and y; the parts it does not name
// stay as the base has them.
@(private)
doc_shadow_read :: proc(args:^Tree_Args,r:^Records,row:int,style:^ui.Node_Style,own:^ui.Style_Keys,variant:string,states:ui.Style_States,value:string,parts:[]struct{key:string,which:ui.Style_Key},what:string) -> bool {
    call:=args.call
    keys,values:=tree_object(call,value,what) or_return
    for key,i in keys {
        which:ui.Style_Key
        found:=false
        for p in parts {if p.key==key {which,found=p.which,true}}
        if !found {
            names:=make([dynamic]string,context.temp_allocator)
            for p in parts {append(&names,p.key)}
            api.call_failf(call,api.INVALID_PARAMS,"%s has no '%s'; it has %s",what,key,strings.join(names[:],", ",context.temp_allocator))
            return false
        }
        own^+={which}
        trimmed:=strings.trim_space(values[i])
        field:=fmt.tprintf("%s.%s",what,key)
        token:string
        if ui.style_key_color(which) {
            color:ui.Color
            color,token=doc_color_value(args,r,trimmed,field) or_return
            ui.style_key_color_set(style,which,color)
        } else {
            number:f32
            number,token=doc_number_value(args,r,trimmed,field) or_return
            ui.style_key_number_set(style,nil,which,number)
        }
        if token!="" {records_token_use(r,row,variant,states,which,token)}
    }
    return true
}

// An animation as the document declares it: a few fields (a property from one
// value to another), or its tracks or parts. One the file has keeps its row,
// so the events that play it still do.
@(private)
document_anim_apply :: proc(args:^Tree_Args,r:^Records,name,text:string) -> bool {
    call:=args.call
    anim:=args^
    keys,values:=tree_object(call,text,"the animation") or_return
    properties:=[ui.Anim_Property]string{.Offset="offset",.Scale="scale",.Rotation="rotation",.Opacity="opacity",.Color="color",.Width="width",.Height="height",.Value="value",.Frame="frame",.Reveal="reveal"}
    short_tracks:=strings.builder_make(call.allocator)
    seconds:=f32(-1)
    ease:="Linear"
    short:=false
    fixed_keys:=make([dynamic]string,call.allocator)
    fixed_values:=make([dynamic]string,call.allocator)
    for key,i in keys {
        property:ui.Anim_Property
        known:=false
        for member in ui.Anim_Property {if properties[member]==key {property,known=member,true}}
        switch {
        case known:
            short=true
            items:=doc_items(call,values[i],key) or_return
            if len(items)!=2 {api.call_failf(call,api.INVALID_PARAMS,"%s must be [from, to]",key);return false}
            if strings.builder_len(short_tracks)>0 {strings.write_byte(&short_tracks,',')}
            from:=doc_vector_read(call,items[0],property) or_return
            to:=doc_vector_read(call,items[1],property) or_return
            fmt.sbprintf(&short_tracks,`{{"property":"%v","keys":[{{"time":0,"value":[%g,%g,%g,%g]}},{{"time":%%SECONDS%%,"value":[%g,%g,%g,%g],"ease":"%%EASE%%"}}]}}`,property,from[0],from[1],from[2],from[3],to[0],to[1],to[2],to[3])
        case key=="seconds":
            number,ok:=doc_number(values[i])
            if !ok {api.call_fail(call,api.INVALID_PARAMS,"seconds must be a number");return false}
            seconds=number
        case key=="ease":
            word,is_text:=doc_string(call,values[i])
            if !is_text {api.call_fail(call,api.INVALID_PARAMS,"ease must be the name of a ui.Ease");return false}
            ease=word
        case key=="kind" || key=="loop" || key=="tracks" || key=="parts":
            append(&fixed_keys,key);append(&fixed_values,values[i])
        case:
            api.call_failf(call,api.INVALID_PARAMS,"an animation has no '%s'; it has offset, scale, rotation, opacity, color, width, height, value, frame, reveal, seconds, ease, kind, loop, tracks and parts",key)
            return false
        }
    }
    for &a,row in r.anims {
        if serial.text_field(a.name[:])==name {
            records_anim_contents_drop(r,row)
            r.anims[row]={name=r.anims[row].name}
            break
        }
    }
    anim.keys,anim.values=fixed_keys,fixed_values
    append(&anim.keys,"name")
    append(&anim.values,fmt.tprintf("%q",name))
    if short {
        if seconds<0 {seconds=0.2}
        text:=strings.to_string(short_tracks)
        text,_=strings.replace_all(text,"%SECONDS%",fmt.tprintf("%g",seconds),call.allocator)
        text,_=strings.replace_all(text,"%EASE%",ease,call.allocator)
        append(&anim.keys,"tracks")
        append(&anim.values,fmt.tprintf("[%s]",text))
    }
    return tree_anim_apply(&anim,r)>=0
}

@(private)
doc_vector_read :: proc(call:^api.Call,text:string,property:ui.Anim_Property) -> (v:[4]f32,ok:bool) {
    trimmed:=strings.trim_space(text)
    if number,is_number:=doc_number(trimmed);is_number {
        v={number,0,0,0}
        if property==.Scale {v[1]=number}
        return v,true
    }
    items:=doc_items(call,trimmed,"the value") or_return
    for item,i in items {
        if i>=4 {break}
        n,parsed:=doc_number(item)
        if !parsed {api.call_fail(call,api.INVALID_PARAMS,"give numbers");return v,false}
        v[i]=n
    }
    return v,true
}

// Reads the nodes of an array in pre-order, each after the node that holds it.
@(private)
document_nodes_read :: proc(args:^Tree_Args,r:^Records,text:string,parent:int,path:string,out:^[dynamic]Document_Node) -> bool {
    call:=args.call
    items:=doc_items(call,text,path,"nodes") or_return
    for item,at in items {
        d:=Document_Node{path=fmt.aprintf("%s[%d]",path,at,allocator=call.allocator),parent=parent,row=-1}
        ok:bool
        d.keys,d.values,ok=tree_object(call,item,d.path)
        if !ok {return false}
        node_args:=args^
        node_args.keys,node_args.values=d.keys,d.values
        name,_,named:=tree_arg_string(&node_args,"name")
        if !named {return document_failed(call,d.path)}
        d.name=name
        if _,has_widget:=tree_arg(&node_args,"widget");has_widget {api.call_failf(call,api.INVALID_PARAMS,"%s.widget: name the file in use and the widget by the name of its file in kind",d.path);return false}
        kind_text,has_kind,kind_ok:=tree_arg_string(&node_args,"kind")
        if !kind_ok {return document_failed(call,d.path)}
        if !has_kind {api.call_failf(call,api.INVALID_PARAMS,"%s: kind is required: a Node_Kind or the name of a widget the document uses",d.path);return false}
        known:bool
        for k in ui.Node_Kind {if k!=.Component && fmt.tprintf("%v",k)==kind_text {d.kind,known=k,true}}
        if !known {
            d.widget=doc_use_find(args,kind_text)
            if d.widget=={} {
                api.call_failf(call,api.INVALID_PARAMS,"%s: kind '%s' is no Node_Kind and no widget of a file this one uses; use names a file, and its name without folder or extension is the kind",d.path,kind_text)
                return false
            }
            d.kind=.Component
        }
        if children,found:=tree_arg(&node_args,"children");found {
            index:=len(out)
            append(out,d)
            if !document_nodes_read(args,r,children,index,fmt.tprintf("%s.children",d.path),out) {return false}
            continue
        }
        append(out,d)
    }
    return true
}

// Whether the node at row is of what a document node declares.
@(private)
document_same_kind :: proc(args:^Tree_Args,r:^Records,row:int,d:^Document_Node) -> bool {
    n:=&r.nodes[row]
    if n.kind!=d.kind {return false}
    if n.kind!=.Component {return true}
    template:=int(n.component)-1
    if template<0 || template>=len(r.components) {return false}
    return r.components[template].widget==d.widget
}

// The nodes of the file, or of root, become those of the document: matched
// by name and kind they are moved, the others are made, and what is left of
// the part declared is taken away; then each becomes what it declares.
@(private)
document_nodes_apply :: proc(args:^Tree_Args,r:^Records,root:int,text:string) -> (made,removed:int,ok:bool) {
    call:=args.call
    decls:=make([dynamic]Document_Node,call.allocator)
    if !document_nodes_read(args,r,text,-1,"nodes",&decls) {return}
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
            if !document_same_kind(args,r,root,&d) {api.call_failf(call,api.INVALID_PARAMS,"%s.kind: a node keeps its kind; write the node that holds it to put another in its place",d.path);return}
            d.row=root
            continue
        }
        if d.name=="" {continue}
        if row:=document_row_of(r,d.name);row>=0 && row!=root && document_same_kind(args,r,row,&d) {d.row=row}
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
            if taken[row-first] || int(r.nodes[row].parent)!=holder || !document_same_kind(args,r,row,&d) {continue}
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
        // A node that stays in what holds it takes no more room there: the one a List holds.
        held:=d.row>=0 && int(r.nodes[document_row_of(r,d.current)].parent)==parent
        if parent>=0 && !held && !doc_takes(call,r,parent) {ok=document_failed(call,d.path);return}
        if d.row>=0 {
            row:=document_row_of(r,d.current)
            if records_place(r,row,parent,-1)<0 {api.call_failf(call,api.INVALID_PARAMS,"%s: a node cannot go inside itself or what it holds",d.path);return}
            continue
        }
        row:int
        if d.kind==.Component {
            file:=doc_use_name(args.assets,d.widget,"widget")
            row=records_widget(r,parent,d.widget,d.name if d.name!="" else file,file)
        } else {
            row=records_insert(r,parent,d.kind)
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
            records_delete(r,row)
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

// A use holds what the Slot of its widget holds; a Box and the other
// containers hold their own.
@(private)
doc_takes :: proc(call:^api.Call,r:^Records,parent:int) -> bool {
    if parent>=0 && r.nodes[parent].kind==.Component {return true}
    return tree_takes(call,r,parent)
}

// The Node_Field a flat key of an instance sets.
@(private)
doc_instance_field :: proc(key:string) -> (field:ui.Node_Field,ok:bool) {
    switch key {
    case "text","fields":  return .Text,true
    case "style","look":   return .Style,true
    case "image":          return .Image,true
    case "events":         return .Animations,true
    case "float":          return .Float,true
    case "layer":          return .Layer,true
    case "clip":           return .Clip,true
    case "block":          return .Block,true
    case "selected","disabled": return .Visibility,true
    case "variant":        return .Variant,true
    case "index","count","choice","limit","delay","range","particle": return .Values,true
    case "action","hold":  return .Action,true
    case "nav","order","flags": return .Focus,true
    case "tag","accepts","ghost": return .Drag,true
    case "bind_text","bind_value","bind_visible","bind_selected","bind_disabled","bind_items","bind_image","bind_tint","bind_variant","data": return .Bindings,true
    }
    if _,is_layout:=doc_layout_key(key);is_layout {return .Layout,true}
    return .Text,false
}

// The key of a layout a name is: width and the others, of a node or a style.
@(private)
doc_layout_key :: proc(name:string) -> (which:ui.Style_Key,ok:bool) {
    keys:=DOC_KEYS
    for k in keys {if k.key==name && k.which in ui.LAYOUT_KEYS {return k.which,true}}
    return
}

// One key of a layout, into l: of a style (r), which can give the name of a
// token of a number and says so in token, or of a node (r nil), which cannot.
// False after failing the call.
@(private)
doc_layout_read :: proc(args:^Tree_Args,r:^Records,l:^ui.Layout,which:ui.Style_Key,key,value:string) -> (token:string,ok:bool) {
    call:=args.call
    trimmed:=strings.trim_space(value)
    #partial switch which {
    case .Width,.Height:
        size:ui.Size
        word:=doc_size_read(args,trimmed,key,&size) or_return
        if word!="" {
            if r==nil {return "",doc_failed(call,"%s: '%s' is no size: on a node give a number, \"grow\", \"fit\" or \"50%%\"; a token goes in a style",key,word)}
            number:=doc_number_token(args,r,word,key) or_return
            size,token=ui.fixed(number),word
        }
        if which==.Width {l.width=size} else {l.height=size}
    case .Padding:
        word:=doc_padding_read(call,trimmed,key,&l.padding) or_return
        if word!="" {
            if r==nil {return "",doc_failed(call,"padding: '%s': on a node give numbers; a token goes in a style",word)}
            number:=doc_number_token(args,r,word,key) or_return
            l.padding,token=ui.padding_all(number),word
        }
    case .Gap,.Aspect:
        number:f32
        number,token=doc_number_value(args,r,trimmed,key) or_return
        if which==.Gap {l.gap=number} else {l.aspect=number}
    case .Columns,.Span:
        number,is_number:=doc_number(trimmed)
        if !is_number {return "",doc_failed(call,"%s must be a whole number",key)}
        if which==.Columns {l.columns=u16(number)} else {l.span=u8(number)}
    case .Direction: return "",doc_enum_read(call,trimmed,key,ui.Direction,&l.direction)
    case .Align_X:   return "",doc_enum_read(call,trimmed,key,ui.Align,&l.align_x)
    case .Align_Y:   return "",doc_enum_read(call,trimmed,key,ui.Align,&l.align_y)
    case .Self_X:    return "",doc_enum_read(call,trimmed,key,ui.Self_Align,&l.self_x)
    case .Self_Y:    return "",doc_enum_read(call,trimmed,key,ui.Self_Align,&l.self_y)
    }
    return token,true
}

// The node at row (of the records' tree) becomes what d declares: what it
// does not give is that of a new node of its kind. It keeps what ties it to
// the file: its translations and, as an instance, the overrides of it.
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
    if !doc_node_keys_apply(args,r,n,row,d) {return false}
    n=&r.nodes[row]
    n.flags=n.flags-{.Localized}+old.flags&{.Localized}
    node_args:=args^
    node_args.keys,node_args.values=d.keys,d.values
    _,has_style:=tree_arg(&node_args,"style")
    if look,found:=tree_arg(&node_args,"look");found {
        if has_style {return doc_failed(call,"look: a node has a style or a look; a look that changes a style names it in extends")}
        info:=ui.Tree_Style_Info{family=style_family(n.kind)}
        style:=records_style_add(r,{},{},info)
        if style<0 {api.call_fail(call,api.SERVER_ERROR,"the .ui holds no more styles");return false}
        look_args:=args^
        ok:bool
        look_args.keys,look_args.values,ok=tree_object(call,look,"look")
        if !ok {return false}
        if !document_style_apply(&look_args,r,style,false) {return document_failed(call,"look")}
        r.nodes[row].style=u16(style)
    } else if !has_style && n.kind!=.Component {
        r.nodes[row].style=records_kind_look(r,n.kind)
    }
    return true
}

// What a node declares, written into n: its text, style name, image, events
// and flat fields; a use of a widget also its parameters.
@(private)
doc_node_keys_apply :: proc(args:^Tree_Args,r:^Records,n:^ui.Tree_Node,row:int,d:^Document_Node) -> bool {
    call:=args.call
    n_args:=args^
    n_args.keys,n_args.values=d.keys,d.values
    lib:=doc_lib_of(doc_libs_slice(args),d.widget)
    params:=lib.linked.params if lib!=nil else nil
    use_name:=doc_use_name(args.assets,d.widget,"") if d.widget!={} else ""
    flat:=make([dynamic]string,call.allocator)
    param_values:=make([dynamic]string,call.allocator)
    reserved:=DOCUMENT_NODE_KEYS
    is_instance:=n.kind==.Component
    slot:=false
    for key,i in d.keys {
        if key=="slot" {
            on,is_bool:=doc_bool(d.values[i])
            if !is_bool {return doc_failed(call,"slot must be true or false")}
            slot=on
            continue
        }
        if slice.contains(reserved[:],key) {continue}
        is_param:=false
        for &p in params {
            if serial.text_field(p.name[:])==key {is_param=true;break}
        }
        if is_param {append(&param_values,key);continue}
        if which,is_layout:=doc_layout_key(key);is_layout {
            n.layout_own+={which}
            if _,read:=doc_layout_read(args,nil,&n.layout,which,key,d.values[i]);!read {return false}
            if is_instance {n.component_fields+={.Layout}}
            continue
        }
        if is_instance {
            field,known:=doc_instance_field(key)
            if !known {
                names:=make([dynamic]string,context.temp_allocator)
                for &p in params {append(&names,serial.text_field(p.name[:]))}
                return doc_failed(call,"%s has no parameter '%s'; it has %s, and the keys of a node",use_name,key,strings.join(names[:],", ",context.temp_allocator))
            }
            n.component_fields+={field}
        }
        append(&flat,key)
    }
    // Text, style, image and events by the keys that say them.
    if text,found,ok:=tree_arg_string(&n_args,"text");!ok {return false} else if found {
        records_text_set(r,&n.text,text)
        if is_instance {n.component_fields+={.Text}}
    }
    if style,found,ok:=tree_arg_string(&n_args,"style");!ok {return false} else if found {
        if style=="" {
            n.style=0
        } else {
            at:=doc_style_row(args,r,style)
            if at<0 {return doc_failed(call,"style: '%s' is no style of this file or of a file it uses; styles declares one, and use takes a file",style)}
            n.style=u16(at)
        }
        if is_instance {n.component_fields+={.Style}}
    }
    if _,has_look:=tree_arg(&n_args,"look");has_look && is_instance {n.component_fields+={.Style}}
    if image,found:=tree_arg(&n_args,"image");found && !is_instance || found {
        if strings.trim_space(image)=="null" {
            n.image=0
        } else {
            at:=records_image(r,n)
            if at<0 {api.call_fail(call,api.SERVER_ERROR,"the .ui holds no more images");return false}
            if !doc_image_read(args,&r.images[at],image) {return false}
        }
        if is_instance {n.component_fields+={.Image}}
    }
    if events,found:=tree_arg(&n_args,"events");found {
        if !doc_node_events_apply(args,r,n,events) {return false}
        if is_instance {n.component_fields+={.Animations}}
    }
    // The rest flat, by the names of ui.Tree_Node.
    if len(flat)>0 {
        b:=strings.builder_make(call.allocator)
        strings.write_byte(&b,'{')
        for key,i in flat {
            if i>0 {strings.write_byte(&b,',')}
            fmt.sbprintf(&b,"%q:%s",key,doc_value_of(d,key))
        }
        strings.write_byte(&b,'}')
        refused,why:=TREE_NODE_REFUSED,TREE_NODE_WHY
        if !tree_fields_read(call,args.types,ui.Tree_Node,n,strings.to_string(b),"the node",refused[:],why[:]) {return false}
    }
    if slot {n.flags+={.Slot}}
    if is_instance {
        if !doc_params_apply(args,r,row,params,d,param_values[:]) {return false}
    } else if len(param_values)>0 {
        return doc_failed(call,"this node takes no parameters")
    }
    return true
}

@(private)
doc_value_of :: proc(d:^Document_Node,key:string) -> string {
    for k,i in d.keys {if k==key {return d.values[i]}}
    return ""
}

// An image: its texture by path and the fields of ui.Tree_Image.
@(private)
doc_image_read :: proc(args:^Tree_Args,image:^ui.Tree_Image,text:string) -> bool {
    keys,values:=tree_object(args.call,text,"image") or_return
    b:=strings.builder_make(args.call.allocator)
    strings.write_byte(&b,'{')
    first:=true
    for key,i in keys {
        if key=="texture" {
            path,is_text:=doc_string(args.call,values[i])
            if is_text && args.session!=nil {
                id,problem:=editor.asset_resolve(args.session,path,".tex")
                if problem!="" {return doc_failed(args.call,"image.texture: %s",problem)}
                image.texture=id
                continue
            }
            if is_text {
                if id,is_id:=serial.text_parse_asset_id(path);is_id {image.texture=id;continue}
                return doc_failed(args.call,"image.texture: no project to read '%s' from",path)
            }
        }
        if !first {strings.write_byte(&b,',')}
        first=false
        fmt.sbprintf(&b,"%q:%s",key,values[i])
    }
    strings.write_byte(&b,'}')
    return tree_fields_read(args.call,args.types,ui.Tree_Image,image,strings.to_string(b),"image")
}

// What plays on the triggers of a node, by the names of the animations.
@(private)
doc_node_events_apply :: proc(args:^Tree_Args,r:^Records,n:^ui.Tree_Node,events:string) -> bool {
    call:=args.call
    keys,values:=tree_object(call,events,"events") or_return
    at:=records_anim_set(r,n)
    if at<0 {api.call_fail(call,api.SERVER_ERROR,"the .ui holds no more sets of events");return false}
    set:=&r.anim_sets[at]
    names:=DOCUMENT_EVENTS
    slots:=(^[len(DOCUMENT_EVENTS)]ui.Anim)(set)
    for key,i in keys {
        name,read:=doc_string(call,values[i])
        if !read {return doc_failed(call,"events.%s must be the name of an animation",key)}
        played:ui.Anim
        if name!="" {
            for &a,row in r.anims {if serial.text_field(a.name[:])==name {played=ui.Anim(row+1);break}}
            if played==0 {return doc_failed(call,"events.%s: the .ui has no animation named '%s'; animations declares it",key,name)}
        }
        slot:=-1
        for event,j in names {if event==key {slot=j}}
        if slot<0 {return doc_failed(call,"events has no trigger '%s'; it has shown, hidden, hovered, unhovered, pressed, released, focused, unfocused, selected, unselected and clicked",key)}
        slots[slot]=played
    }
    return true
}

// The values of the parameters a use gives, into its instance or the
// overrides of the nodes they go to; those it does not give are taken away.
@(private)
doc_params_apply :: proc(args:^Tree_Args,r:^Records,row:int,params:[]ui.Tree_Param,d:^Document_Node,given:[]string) -> bool {
    call:=args.call
    // What a parameter set before and this use does not name goes.
    for &p in params {
        node:=serial.text_field(p.node[:])
        if node=="" {continue}
        group:=doc_param_group(p.field)
        for &o in r.overrides {
            if int(o.instance)==row && serial.text_field(o.node[:])==node {o.fields-={group}}
        }
    }
    for i:=len(r.overrides)-1;i>=0;i-=1 {
        if int(r.overrides[i].instance)==row && r.overrides[i].fields=={} {ordered_remove(&r.overrides,i)}
    }
    for key in given {
        value_text:=doc_value_of(d,key)
        value,is_text:=doc_string(call,value_text)
        if !is_text {return doc_failed(call,"%s must be a string",key)}
        p:ui.Tree_Param
        for &each in params {if serial.text_field(each.name[:])==key {p=each}}
        node:=serial.text_field(p.node[:])
        template:ui.Tree_Node
        source:^Records
        if node!="" {
            found:^ui.Tree_Node
            found,source=doc_widget_node(args,d.widget,node)
            if found==nil {return doc_failed(call,"%s goes to node '%s', which its widget does not have",key,node)}
            template=found^
        }
        style:=0
        if p.field==.Style {
            style=doc_style_row(args,r,value)
            if style<0 {return doc_failed(call,"%s: '%s' is no style of this file or of a file it uses",key,value)}
        }
        records_param_set(r,row,&p,value,style,source,template)
    }
    return true
}

// The node a path of names reaches in a widget as a use expands it, and the
// records its rows are of.
@(private)
doc_widget_node :: proc(args:^Tree_Args,widget:base.Asset_Id,path:string) -> (found:^ui.Tree_Node,source:^Records) {
    lib:=doc_lib_of(doc_libs_slice(args),widget)
    if lib==nil {return}
    expanded,expanded_ok:=ui.tree_expand(lib.linked,context.temp_allocator)
    if !expanded_ok {return}
    for &n in expanded {
        if serial.text_field(n.name[:])!=path {continue}
        source=new(Records,context.temp_allocator)
        if !records_load(source,lib.linked,context.temp_allocator) {return nil,nil}
        return &n,source
    }
    return
}

// The parameters the widget of this file takes, as the document declares
// them; what the keys of a node name goes by another: each says where it
// goes, a field of a node or, past a use, a parameter of its widget.
@(private)
document_params_apply :: proc(args:^Tree_Args,r:^Records,text:string) -> bool {
    call:=args.call
    keys,values:=tree_object(call,text,"params") or_return
    clear(&r.params)
    fields:=DOC_PARAM_FIELDS
    for param,i in keys {
        place:=fmt.tprintf("params.%s",param)
        if len(param)>=ui.TREE_NAME_CAPACITY || param=="" {return doc_failed(call,"%s: give a name shorter than %d bytes",place,ui.TREE_NAME_CAPACITY)}
        target,is_text:=doc_string(call,values[i])
        if !is_text {return doc_failed(call,"%s must say where it goes: node.field, node.parameter of a use, or field for its root",place)}
        node,last:=target,""
        if dot:=strings.last_index_byte(target,'.');dot>=0 {node,last=target[:dot],target[dot+1:]} else {node,last="",target}
        field:ui.Tree_Param_Field
        is_field:=false
        for f in ui.Tree_Param_Field {if fields[f]==last {field,is_field=f,true}}
        p:ui.Tree_Param
        ui.tree_text_set(p.name[:],param)
        if node!="" {
            n:=records_node_named(r,node)
            if n==nil {
                names:=make([dynamic]string,context.temp_allocator)
                for &each in r.nodes {if name:=serial.text_field(each.name[:]);name!="" {append(&names,name)}}
                return doc_failed(call,"%s: this file has no node '%s'; it has %s. To reach inside a use give its parameter: node.parameter",place,node,strings.join(names[:],", ",context.temp_allocator))
            }
            ui.tree_text_set(p.node[:],node)
            if !is_field {
                inner:=doc_lib_of(doc_libs_slice(args),r.components[n.component-1].widget) if n.kind==.Component && int(n.component)>0 && int(n.component)<=len(r.components) else nil
                found:=false
                names:=make([dynamic]string,context.temp_allocator)
                if inner!=nil {for &q in inner.linked.params {append(&names,serial.text_field(q.name[:]));found||=serial.text_field(q.name[:])==last}}
                if !found {return doc_failed(call,"%s: '%s' is no field a parameter can give and no parameter of '%s' (it has %s)",place,last,node,strings.join(names[:],", ",context.temp_allocator))}
                ui.tree_text_set(p.param[:],last)
                is_field=true
            }
        }
        if !is_field {
            names:=make([dynamic]string,context.temp_allocator)
            for f in ui.Tree_Param_Field {append(&names,fields[f])}
            return doc_failed(call,"%s: '%s' is no field a parameter can give: %s",place,last,strings.join(names[:],", ",context.temp_allocator))
        }
        p.field=field
        append(&r.params,p)
        if why:=records_param_valid_name(r,len(r.params)-1);why!="" {return doc_failed(call,"%s: %s; give the parameter another",place,why)}
    }
    return true
}

// A file that declares parameters or a slot is a widget: one root, and the
// slot the last node of it.
@(private)
document_widget_shape :: proc(call:^api.Call,r:^Records) -> bool {
    slot:=records_slot_row(r)
    if len(r.params)==0 && slot<0 {return true}
    roots:=0
    for &n in r.nodes {roots+=int(n.parent<0)}
    if roots!=1 {return doc_failed(call,"nodes: a file with params or a slot is a widget: it has one root and has %d",roots)}
    if slot>=0 {
        if slot+records_subtree(r.nodes[:],slot)!=len(r.nodes)-1 {return doc_failed(call,"nodes: a node after the slot; the slot is the last of its file")}
        for &n,i in r.nodes {if i!=slot && .Slot in n.flags {return doc_failed(call,"nodes: two nodes are slots; a widget has one")}}
    }
    return true
}

// ---------------------------------------------------------------- paths

// Where a node of the records is in the document of the file, or of root.
@(private)
doc_place :: proc(r:^Records,row,root:int) -> string {
    if row==root {return "nodes[0]"}
    parent:=int(r.nodes[row].parent)
    at:=0
    for &n in r.nodes[:row] {at+=int(int(n.parent)==parent)}
    if parent<0 {return fmt.tprintf("nodes[%d]",at)}
    return fmt.tprintf("%s.children[%d]",doc_place(r,parent,root),at)
}

// What a use says, by the key of the document, that makes a node of its
// widget bind path: a parameter that gives it, or the data its @ paths start
// at. Empty: the widget binds it by itself.
@(private)
doc_use_key :: proc(args:^Tree_Args,r:^Records,use:int,path:string) -> string {
    n:=&r.nodes[use]
    lib:=doc_lib_of(doc_libs_slice(args),r.components[n.component-1].widget) if int(n.component)>0 && int(n.component)<=len(r.components) else nil
    data:=serial.text_field(n.data[:])
    from_data:=data!="" && (path==data || strings.has_prefix(path,fmt.tprintf("%s.",data)))
    if lib!=nil {
        for &p in lib.linked.params {
            if p.field<.Data || p.field>.Bind_Variant {continue}
            target:=n
            if node:=serial.text_field(p.node[:]);node!="" {
                target=nil
                for &o in r.overrides {
                    if int(o.instance)==use && serial.text_field(o.node[:])==node {target=&o.values;break}
                }
            }
            if target==nil {continue}
            given:=serial.text_field(doc_param_slot(target,p.field))
            if given==path || from_data && p.field==.Data && given==data {return serial.text_field(p.name[:])}
        }
    }
    return "data" if from_data else ""
}

// Whether the game has every path the nodes of the records bind (root>=0:
// that node and what it holds), as the game resolves them when it makes the
// interface (bind_check). False after failing the call with each it lacks:
// where, the key, the path, what the game does not have there and what it
// has. Not checked, because only a use knows them: the paths that start with
// @, what a List of one holds and a text with one in its braces; and nothing
// is while the editor has the types of no game.
@(private)
document_paths_check :: proc(args:^Tree_Args,r:^Records,root:int) -> bool {
    info,a:=args.info,args.assets
    if info==nil || a==nil {return true}
    data:=records_data(r)
    imports,imported:=host.ui_tree_imports(a,data)
    if !imported {return true}
    types:Bind_Types
    defer bind_types_free(&types)
    found:[BIND_PROBLEMS]Bind_Problem
    count:=bind_check(&types,context.allocator,a,info,data,imports,imported,found[:])
    last:=root+records_subtree(r.nodes[:],root) if root>=0 else len(r.nodes)-1
    b:=strings.builder_make(args.call.allocator)
    failed:=0
    for &problem in found[:count] {
        if problem.fault!=.Path && problem.fault!=.Template {continue}
        row:=problem.row if problem.row>=0 else problem.use
        if row<0 || row>=len(r.nodes) || root>=0 && (row<root || row>last) {continue}
        n:=&r.nodes[row]
        path:=serial.text_field(problem.path[:])
        key:=fmt.tprintf("bind_%s",doc_enum_text(problem.binding))
        scope,scoped:=node_scope(info,r.nodes[:],row)
        why:=path_why(info,scope,path,problem.takes) if scoped else "the game does not have it"
        if failed>0 {strings.write_string(&b,"; ")}
        failed+=1
        fmt.sbprintf(&b,"%s '%s': ",doc_place(r,row,root),serial.text_field(n.name[:]))
        inner:=strings.trim_prefix(strings.trim_prefix(serial.text_field(problem.name[:]),serial.text_field(n.name[:])),"/")
        file:=doc_path(a,r.components[n.component-1].widget) if problem.use>=0 && int(n.component)>0 && int(n.component)<=len(r.components) else ""
        switch {
        case problem.fault==.Template && problem.use>=0:
            fmt.sbprintf(&b,"the text of node '%s' of its widget %s names in braces a path the game does not have or cannot show",inner,file)
            if given:=serial.text_field(n.data[:]);given!="" {
                fmt.sbprintf(&b," from the data '%s' this use gives its @ paths",given)
            } else {
                strings.write_string(&b,"; write that file with fields that name what the game has")
            }
        case problem.fault==.Template:
            text:=records_text(r,n.text)
            fmt.sbprintf(&b,"text '%s': ",text)
            said:=false
            for name in text_field_names(text) {
                at:=text_field_of(r,n,name)
                field:=serial.text_field(n.fields[at].path[:]) if at>=0 else ""
                switch {
                case field=="":
                    fmt.sbprintf(&b,"%s{{%s}} has no path: fields gives one, as {{\"name\":\"%s\",\"path\":\"Component.field\"}}","; " if said else "",name,name)
                    said=true
                case scoped:
                    _,leaf,walked:=path_walk(info,scope,field)
                    if walked && type_fits(leaf,.Shown) {continue}
                    fmt.sbprintf(&b,"%sfields {{%s}} '%s': %s","; " if said else "",name,field,path_why(info,scope,field,.Shown))
                    said=true
                }
            }
            if !said {strings.write_string(&b,"a name in braces has a format after its colon that its value does not take")}
        case problem.use>=0:
            if given:=doc_use_key(args,r,row,path);given!="" {
                fmt.sbprintf(&b,"%s gives node '%s' of %s the %s '%s': %s",given,inner,file,key,path,why)
            } else {
                fmt.sbprintf(&b,"node '%s' of its widget %s has %s '%s': %s; write that file with a path the game has",inner,file,key,path,why)
            }
        case:
            fmt.sbprintf(&b,"%s '%s': %s",key,path,why)
        }
    }
    if failed==0 {return true}
    api.call_failf(args.call,api.INVALID_PARAMS,"%s. Nothing changed. A path names a component or a storage of the game, then its fields; inside a List it starts at the element. ui.paths lists what a binding of a node takes, and what the code of the game declares is here after the game is built",strings.to_string(b))
    return false
}
