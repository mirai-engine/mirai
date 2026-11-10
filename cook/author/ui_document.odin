package author

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:engine/gui"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
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
// those of the document, matched by name; a node with a key shows what that
// key of the texts of the game says (texts.odin), which its text sets in the
// language they are written in, and what the file keeps of an
// instance (its overrides) stays; the styles and animations it names become
// those, null takes one away, and those it does not name stay.

// A .ui a document takes names from.
Doc_Lib :: struct {
    id:base.Asset_Id,
    records:Records,
    linked:ui.Tree_Data, // linked with what it uses: its parameters, flat
}

// What a node gives by keys of its own, or keeps: none of it goes flat.
DOCUMENT_NODE_SKIP :: [?]string{"kind","parent","name","text","style","image","anims","component","component_fields","layout","layout_own"}
DOCUMENT_NODE_KEYS :: [?]string{"name","kind","text","key","style","look","image","events","children","slot"}
DOCUMENT_EVENTS :: [?]string{"shown","hidden","clicked"}

DOC_STATES :: [?]struct{key:string,states:ui.Style_States}{{"hover",{.Hovered}},{"focus",{.Focused}},{"pressed",{.Pressed}},{"disabled",{.Disabled}},{"selected",{.Selected}},{"over",{.Over}}}
// The fields a parameter of a widget can go to.
DOC_PARAM_FIELDS :: [ui.Tree_Param_Field]string{.Text="text",.Style="style",.Data="data",.Bind_Text="bind_text",.Bind_Value="bind_value",.Bind_Visible="bind_visible",.Bind_Selected="bind_selected",.Bind_Disabled="bind_disabled",.Bind_Items="bind_items",.Bind_Image="bind_image",.Bind_Tint="bind_tint",.Bind_Variant="bind_variant",.Variant="variant",.Action="action",.Tag="tag",.Accepts="accepts"}

doc_failed :: proc(reading:^Reading,format:string,args:..any) -> bool {
    reading_failf(reading,format,..args)
    return false
}

// A Node_Style of no value: what a value is compared to.
doc_no_style :: proc() -> ui.Node_Style {return {}}

// ---------------------------------------------------------------- values

doc_color_text :: proc(c:ui.Color) -> string {
    if c[3]==255 {return fmt.tprintf("#%02x%02x%02x",c[0],c[1],c[2])}
    return fmt.tprintf("#%02x%02x%02x%02x",c[0],c[1],c[2],c[3])
}
doc_color_parse :: proc(text:string) -> (color:ui.Color,ok:bool) {
    digits:=len(text)-1
    if len(text)<2 || text[0]!='#' || digits!=6 && digits!=8 {return}
    value,parsed:=strconv.parse_u64_of_base(text[1:],16)
    if !parsed {return}
    if digits==6 {value=value<<8|0xff}
    return ui.Color{u8(value>>24),u8(value>>16),u8(value>>8),u8(value)},true
}

// The text of a JSON string, or empty and false.
doc_string :: proc(reading:^Reading,text:string) -> (value:string,ok:bool) {
    trimmed:=strings.trim_space(text)
    if trimmed=="" || trimmed[0]!='"' {return "",false}
    r:serial.Text_Reader
    serial.text_reader_init(&r,trimmed,reading.allocator)
    read:string
    read,ok=serial.text_string(&r)
    if !ok {return "",false}
    return strings.clone(read,reading.allocator),true
}

doc_number :: proc(text:string) -> (value:f32,ok:bool) {
    return strconv.parse_f32(strings.trim_space(text))
}

doc_bool :: proc(text:string) -> (value,ok:bool) {
    switch strings.trim_space(text) {
    case "true":  return true,true
    case "false": return false,true
    }
    return false,false
}

// The items of a JSON array, each the text of its value. of: what it is an
// array of, for the error.
doc_items :: proc(reading:^Reading,text,what:string,of:="") -> (items:[dynamic]string,ok:bool) {
    items=make([dynamic]string,reading.allocator)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,reading.allocator)
    if !serial.text_accept(&r,'[') {return items,doc_failed(reading,"%s must be an array%s%s",what," of " if of!="" else "",of)}
    for at:=0;!serial.text_accept(&r,']');at+=1 {
        if at>0 && !serial.text_accept(&r,',') {return items,tree_malformed(reading,&r)}
        serial.text_space(&r)
        start:=r.offset
        if !serial.text_skip(&r) {return items,tree_malformed(reading,&r)}
        append(&items,text[start:r.offset])
    }
    return items,true
}

// A number or a size in a style or a node: "grow", "fit", "50%", a number
// for fixed, or the object of a ui.Size. A style may give the name of a token
// (token not empty).
doc_size_read :: proc(args:^Tree_Args,text,what:string,size:^ui.Size) -> (token:string,ok:bool) {
    trimmed:=strings.trim_space(text)
    if value,is_number:=doc_number(trimmed);is_number {
        size^=ui.fixed(value)
        return "",true
    }
    if word,is_text:=doc_string(args.reading,trimmed);is_text {
        switch word {
        case "grow":  size^=ui.GROW;return "",true
        case "fit":   size^=ui.FIT;return "",true
        }
        if strings.has_suffix(word,"%") {
            value,parsed:=doc_number(word[:len(word)-1])
            if !parsed {return "",doc_failed(args.reading,"%s: '%s' is no size: give a number for fixed, \"grow\", \"fit\" or \"50%%\"",what,word)}
            size^=ui.percent(value/100)
            return "",true
        }
        return word,true
    }
    return "",tree_fields_read(args.reading,args.types,ui.Size,size,trimmed,what)
}
doc_size_write :: proc(out:^serial.Writer,types:^asset.Types,size:ui.Size) {
    size:=size
    plain:=size.min==0 && size.max==0
    switch {
    case size.kind==.Fixed && plain:              serial.json_number(out,size.value)
    case size.kind==.Grow && plain && size.value==0: serial.text_write_string(out,"grow")
    case size.kind==.Fit && plain:                serial.text_write_string(out,"fit")
    case size.kind==.Percent && plain:            serial.text_write_string(out,fmt.tprintf("%g%%",size.value*100))
    case:
        index,_:=asset.types_index(types,ui.Size)
        zero:ui.Size
        serial.text_write_changed(out,&types.schema,index,mem.ptr_to_bytes(&size),mem.ptr_to_bytes(&zero))
    }
}

// An enum of a document: the name of a member of type, in any case, into
// the byte of value.
doc_enum_read :: proc(reading:^Reading,text,what:string,type:typeid,value:rawptr) -> bool {
    names:=reflect.enum_field_names(type)
    if word,is_text:=doc_string(reading,text);is_text {
        values:=reflect.enum_field_values(type)
        for name,i in names {
            if strings.equal_fold(name,word) {(^u8)(value)^=u8(values[i]);return true}
        }
    }
    lower:=make([dynamic]string,context.temp_allocator)
    for name in names {append(&lower,strings.to_lower(name,context.temp_allocator))}
    return doc_failed(reading,"%s: give one of %s",what,strings.join(lower[:],", ",context.temp_allocator))
}
doc_enum_text :: proc(value:$E) -> string {return strings.to_lower(fmt.tprintf("%v",value),context.temp_allocator)}

// The sides of a padding: a number, [x, y] or [left, top, right, bottom].
doc_padding_read :: proc(reading:^Reading,text,what:string,padding:^[4]f32) -> (token:string,ok:bool) {
    trimmed:=strings.trim_space(text)
    if value,is_number:=doc_number(trimmed);is_number {padding^=ui.padding_all(value);return "",true}
    if word,is_text:=doc_string(reading,trimmed);is_text {return word,true}
    items:=doc_items(reading,trimmed,what) or_return
    values:[4]f32
    for item,i in items {
        if i>=4 {return "",doc_failed(reading,"%s: at most four numbers: left, top, right and bottom",what)}
        values[i],ok=doc_number(item)
        if !ok {return "",doc_failed(reading,"%s: give numbers",what)}
    }
    switch len(items) {
    case 2: padding^=ui.padding_xy(values[0],values[1])
    case 4: padding^=values
    case:   return "",doc_failed(reading,"%s: give a number, [x, y] or [left, top, right, bottom]",what)
    }
    return "",true
}
doc_padding_write :: proc(out:^serial.Writer,p:[4]f32) {
    p:=p
    switch {
    case p[0]==p[1] && p[1]==p[2] && p[2]==p[3]: serial.json_number(out,p[0])
    case p[0]==p[2] && p[1]==p[3]: serial.json_list(out,p[:2])
    case: serial.json_list(out,p[:])
    }
}

// ---------------------------------------------------------------- names

// A .ui as a document takes names from it, linked with what it uses.
doc_lib_read :: proc(a:Assets,id:base.Asset_Id,allocator:mem.Allocator) -> (lib:Doc_Lib,ok:bool) {
    lib.id=id
    if !records_read(a,id,&lib.records,allocator) {return}
    data:=records_data(&lib.records)
    lib.linked=data
    imports,imported:=tree_imports(a,data,nil,allocator)
    if !imported {return lib,true} // ui.check says why
    if linked,linked_ok:=ui.tree_link(data,imports,allocator);linked_ok {lib.linked=linked}
    return lib,true
}

// The files a document takes names from: those the records already name, and
// those its "use" adds.
doc_libs :: proc(args:^Tree_Args,r:^Records,extra:[]base.Asset_Id={}) -> [dynamic]Doc_Lib {
    libs:=make([dynamic]Doc_Lib,context.temp_allocator) // what a reading allocates is bounded; these are whole files
    if args.assets.registry==nil {return libs}
    add :: proc(libs:^[dynamic]Doc_Lib,a:Assets,id:base.Asset_Id,allocator:mem.Allocator) {
        if id=={} {return}
        for &lib in libs {if lib.id==id {return}}
        if lib,read:=doc_lib_read(a,id,allocator);read {append(libs,lib)}
    }
    for &c in r.components {add(&libs,args.assets,c.widget,context.temp_allocator)}
    for id in extra {add(&libs,args.assets,id,context.temp_allocator)}
    return libs
}

doc_lib_of :: proc(libs:[]Doc_Lib,id:base.Asset_Id) -> ^Doc_Lib {
    for &lib in libs {if lib.id==id {return &lib}}
    return nil
}

// The name a file goes by: its name without folder or extension.
doc_use_name :: proc(a:Assets,id:base.Asset_Id,fallback:string) -> string {
    if a.registry==nil {return fallback}
    file,found:=asset.registry_find(a.registry,id)
    if !found {return fallback}
    path:=file.path
    path=path[strings.last_index_byte(path,'/')+1:]
    if dot:=strings.last_index_byte(path,'.');dot>0 {path=path[:dot]}
    return path
}

// The file a kind names, of those a document takes names from; none: no kind.
doc_use_find :: proc(args:^Tree_Args,name:string) -> base.Asset_Id {
    if args.libs==nil {return {}}
    for &lib in args.libs {if doc_use_name(args.assets,lib.id,"")==name {return lib.id}}
    return {}
}

// The id of a .ui a document names by its path.
doc_use_resolve :: proc(args:^Tree_Args,path,what:string) -> (id:base.Asset_Id,ok:bool) {
    reading:=args.reading
    if args.assets.registry==nil {reading_failf(reading,"%s: no project to read '%s' from",what,path);return}
    if named:=reading.assets;named.resolve!=nil {
        problem:string
        if id,problem=named.resolve(named.user,path,".ui");problem!="" {reading_failf(reading,"%s: %s",what,problem);return}
    } else {
        file,found:=asset.registry_find_path(args.assets.registry,path)
        if !found {reading_failf(reading,"%s: no .ui at '%s'",what,path);return}
        id=file.id
    }
    return id,true
}

// A file that names, itself or through what it uses, target: how it does it,
// the files from the first to target; empty: it does not.
doc_reaches :: proc(a:Assets,from,target:base.Asset_Id) -> string {
    a:=a
    used,read:=widget_uses_of_file(&a,from)
    if !read {return ""}
    w:=widget_walk(used,from,target,widget_uses_of_file,&a)
    if !w.reached {return ""}
    chain:=make([dynamic]string,context.temp_allocator)
    for id in w.chain {append(&chain,doc_path(a,id))}
    return strings.join(chain[:]," -> ",context.temp_allocator)
}

doc_token_find :: proc(r:^Records,libs:[]Doc_Lib,name:string) -> (token:^ui.Tree_Token) {
    for &t in r.tokens {if serial.text_field(t.name[:])==name {return &t}}
    for &lib in libs {
        for &t in lib.records.tokens {if serial.text_field(t.name[:])==name {return &t}}
    }
    return nil
}

// The row of the style called name: of this file, one that names a file it
// takes styles from (made the first time), or -1.
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
doc_token_of :: proc(r:^Records,style:int,variant:string,states:ui.Style_States,key:ui.Style_Key) -> string {
    for &u in r.token_uses {
        if int(u.style)==style && u.states==states && u.key==key && serial.text_field(u.variant[:])==variant {return serial.text_field(u.token[:])}
    }
    return ""
}

// The color a key gives: #rrggbb, #rrggbbaa, or the name of a token of a color.
doc_color_value :: proc(args:^Tree_Args,r:^Records,text,what:string) -> (color:ui.Color,token:string,ok:bool) {
    reading:=args.reading
    word,is_text:=doc_string(reading,text)
    if !is_text {return {},"",doc_failed(reading,"%s must be a color: #rrggbb, #rrggbbaa or the name of a token",what)}
    if len(word)>0 && word[0]=='#' {
        parsed:bool
        color,parsed=doc_color_parse(word)
        if !parsed {return {},"",doc_failed(reading,"%s: '%s' is no color: write #rrggbb or #rrggbbaa",what,word)}
        return color,"",true
    }
    t:=doc_token_find(r,doc_libs_slice(args),word)
    if t==nil {return {},"",doc_failed(reading,"%s names the token '%s', which is not declared in tokens or in a file this one uses",what,word)}
    if t.numeric {return {},"",doc_failed(reading,"%s names '%s', a token of a number",what,word)}
    return t.color,word,true
}

// The value of the token of a number that a key names.
doc_number_token :: proc(args:^Tree_Args,r:^Records,word,what:string) -> (number:f32,ok:bool) {
    t:=doc_token_find(r,doc_libs_slice(args),word)
    if t==nil || !t.numeric {return 0,doc_failed(args.reading,"%s names '%s', which is no number token",what,word)}
    return t.number,true
}

// The number a key gives; a style (r) can give the name of a token of a
// number, a node (r nil) cannot.
doc_number_value :: proc(args:^Tree_Args,r:^Records,text,what:string) -> (number:f32,token:string,ok:bool) {
    if value,is_number:=doc_number(text);is_number {return value,"",true}
    if r==nil {return 0,"",doc_failed(args.reading,"%s must be a number",what)}
    word,is_text:=doc_string(args.reading,text)
    if !is_text {return 0,"",doc_failed(args.reading,"%s must be a number or the name of a token",what)}
    number,ok=doc_number_token(args,r,word,what)
    return number,word,ok
}

// ---------------------------------------------------------------- writing

doc_path :: proc(a:Assets,id:base.Asset_Id) -> string {
    if a.registry!=nil {
        if file,found:=asset.registry_find(a.registry,id);found {return file.path}
    }
    return fmt.tprintf("%016x%016x",id[0],id[1])
}

// Writes the document of the records: every token, named style, component and
// animation, or with root>=0 that node with what it holds and the styles and
// animations they take.
document_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,root:int,libs:[]Doc_Lib={},a:Assets={},texts:^Texts=nil) {
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
    key :: proc(out:^serial.Writer,name:string,comma:^bool) {serial.json_key(out,name,!comma^);comma^=true}
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
                serial.json_key(out,serial.text_field(p.name[:]),true)
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
                serial.json_key(out,serial.text_field(t.name[:]),true)
                if t.numeric {serial.json_number(out,t.number)} else {serial.text_write_string(out,doc_color_text(t.color))}
            }
            serial.write_u8(out,'}')
        }
    }
    key(out,"styles",&comma);serial.write_u8(out,'{')
    written:=false
    for wanted,row in styles {
        if !wanted || row<len(r.style_infos) && r.style_infos[row].from!=0 {continue}
        serial.json_key(out,records_style_name(r,row),!written)
        written=true
        document_style_write(out,types,r,row,true,a)
    }
    serial.write_u8(out,'}')
    key(out,"animations",&comma);serial.write_u8(out,'{')
    written=false
    for wanted,row in anims {
        if !wanted || r.anims[row].name[0]==0 {continue}
        serial.json_key(out,serial.text_field(r.anims[row].name[:]),!written)
        written=true
        document_anim_write(out,r,row)
    }
    serial.write_u8(out,'}')
    key(out,"nodes",&comma);serial.write_u8(out,'[')
    written=false
    w:=Doc_Write{out=out,types=types,r=r,libs=libs,assets=a,list=r.nodes[:],texts=texts}
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
Doc_Write :: struct {
    out:^serial.Writer,
    types:^asset.Types,
    r:^Records,
    libs:[]Doc_Lib,
    assets:Assets,
    list:[]ui.Tree_Node,
    texts:^Texts, // what the keys of its localized nodes say; nil: a document gives only their keys
}

// A style: what it extends, each key it sets, its states, variants and rules.
// With no extends every value it has that is not zero; with extends, what it
// sets itself.
document_style_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,row:int,named:bool,a:Assets={}) {
    info:ui.Tree_Style_Info
    if row<len(r.style_infos) {info=r.style_infos[row]}
    style:=&r.styles[row]
    serial.write_u8(out,'{')
    first:=true
    comma :: proc(out:^serial.Writer,first:^bool) {if !first^ {serial.write_u8(out,',')};first^=false}
    if ext:=serial.text_field(info.extends[:]);ext!="" {
        comma(out,&first);serial.json_text(out,"extends",ext,true)
    }
    if named {
        // A style a node of the file takes: its kind says its family.
        used:=records_style_users(r,row)>0
        if info.family!=.Box && !used {comma(out,&first);serial.json_text(out,"family",fmt.tprintf("%v",info.family),true)}
    }
    if info.defaults!={} {
        comma(out,&first)
        serial.json_key(out,"defaults",true);serial.write_u8(out,'[')
        once:=true
        for kind in info.defaults {
            if !once {serial.write_u8(out,',')}
            once=false
            serial.text_write_string(out,fmt.tprintf("%v",kind))
        }
        serial.write_u8(out,']')
    }
    doc_look_write(out,types,r,style,&info,ui.style_own_keys(&info),row,"",{},a,&first)
    // Rules: a state alone, a variant alone, and the rest as they are.
    rules:=make([dynamic]^ui.Tree_Style_Variant,context.temp_allocator)
    for &v in r.variants {
        if int(v.style)!=row || v.inherited {continue}
        name:=serial.text_field(v.variant[:])
        single:=name=="" && card(v.states)==1
        if !single {append(&rules,&v);continue}
        key:=""
        for s in DOC_STATES {if s.states==v.states {key=s.key}}
        comma(out,&first)
        serial.json_key(out,key,true)
        doc_rule_body_write(out,types,r,&v,row,a)
    }
    variants:=false
    for v in rules {
        name:=serial.text_field(v.variant[:])
        if name=="" || v.states!={} {continue}
        if !variants {comma(out,&first);serial.json_key(out,"variants",true);serial.write_u8(out,'{')} else {serial.write_u8(out,',')}
        variants=true
        serial.json_key(out,name,true)
        doc_rule_body_write(out,types,r,v,row,a)
    }
    if variants {serial.write_u8(out,'}')}
    list:=false
    for v in rules {
        name:=serial.text_field(v.variant[:])
        if name!="" && v.states=={} {continue}
        if !list {comma(out,&first);serial.json_key(out,"rules",true);serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        list=true
        serial.write_u8(out,'{')
        inner:=true
        if name!="" {serial.json_text(out,"variant",name,true);inner=false}
        if v.states!={} {
            serial.json_key(out,"states",inner);inner=false
            serial.write_u8(out,'[')
            once:=true
            for state in v.states {
                if !once {serial.write_u8(out,',')}
                once=false
                serial.text_write_string(out,fmt.tprintf("%v",state))
            }
            serial.write_u8(out,']')
        }
        doc_look_write(out,types,r,&v.patch.values,nil,ui.rule_own_keys(v),row,name,v.states,a,&inner)
        serial.write_u8(out,'}')
    }
    if list {serial.write_u8(out,']')}
    serial.write_u8(out,'}')
}

doc_rule_body_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,v:^ui.Tree_Style_Variant,row:int,a:Assets) {
    serial.write_u8(out,'{')
    first:=true
    if v.extends!={} {
        name:=""
        for s in DOC_STATES {if s.states==v.extends {name=s.key}}
        serial.json_text(out,"extends",name,true)
        first=false
    }
    doc_look_write(out,types,r,&v.patch.values,nil,ui.rule_own_keys(v),row,serial.text_field(v.variant[:]),v.states,a,&first)
    serial.write_u8(out,'}')
}

// The key a name is: by itself, or with group a part of that object.
doc_key_find :: proc(group,name:string) -> (key:ui.Style_Key,ok:bool) {
    for k,which in ui.STYLE_KEYS {
        if k.group==group && k.name==name {return which,true}
    }
    return
}

// The names a document has for the values of a style, or with rule of a
// state: its keys and the objects of the others; with group, the parts of it.
doc_key_names :: proc(group:string,rule:bool) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for k in ui.STYLE_KEYS {
        if rule && !k.rule {continue}
        name:=k.name if k.group==group else k.group if group=="" else ""
        if name!="" && !slice.contains(names[:],name) {append(&names,name)}
    }
    return strings.join(names[:],", ",context.temp_allocator)
}

// The keys of a look a style or a rule sets, each one by the token that gives
// it or written out; the parts of a shadow go in its object.
doc_look_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,style:^ui.Node_Style,info:^ui.Tree_Style_Info,own:ui.Style_Keys,row:int,variant:string,states:ui.Style_States,a:Assets,first:^bool) {
    zero:=doc_no_style()
    // A style with an extends writes what it sets even when zero; without, only what is not.
    by_sets:=own!=~ui.Style_Keys{}
    group:=""
    part:=false
    for key in ui.Style_Key {
        k:=ui.STYLE_KEYS[key]
        if k.place==.Style {
            if key not_in own || !by_sets && !ui.style_key_differs(style,&zero,key) {continue}
        } else if info==nil || key not_in info.sets {continue}
        if k.group!=group {
            if group!="" {serial.write_u8(out,'}')}
            group,part=k.group,false
            if group!="" {doc_first(out,first,group);serial.write_u8(out,'{')}
        }
        if group!="" {serial.json_key(out,k.name,!part);part=true} else {doc_first(out,first,k.name)}
        if token:=doc_token_of(r,row,variant,states,key);token!="" {serial.text_write_string(out,token);continue}
        doc_key_write(out,types,r,a,key,ui.style_value(style,info,key))
    }
    if group!="" {serial.write_u8(out,'}')}
}

doc_first :: proc(out:^serial.Writer,first:^bool,key:string) {
    serial.json_key(out,key,first^)
    first^=false
}

doc_font_write :: proc(out:^serial.Writer,r:^Records,font:u8,a:Assets) {
    switch {
    case font==ui.FONT_MEDIUM:   serial.text_write_string(out,"medium")
    case font==ui.FONT_SEMIBOLD: serial.text_write_string(out,"semibold")
    case int(font)>=ui.FONT_TREE && int(font)-ui.FONT_TREE<len(r.fonts): serial.text_write_string(out,doc_path(a,r.fonts[int(font)-ui.FONT_TREE].font))
    case: serial.text_write_string(out,"regular")
    }
}

// A value as a document says it, from its bytes.
doc_key_write :: proc(out:^serial.Writer,types:^asset.Types,r:^Records,a:Assets,key:ui.Style_Key,value:[]u8) {
    k:=ui.STYLE_KEYS[key]
    p:=raw_data(value)
    switch k.kind {
    case .Number:  serial.json_number(out,(^f32)(p)^)
    case .Color:   serial.text_write_string(out,doc_color_text((^ui.Color)(p)^))
    case .Enum:    serial.text_write_string(out,doc_enum_text(any{p,k.type}))
    case .Flag:    serial.json_flag(out,(^bool)(p)^)
    case .Count:   serial.json_number(out,f32((^u16)(p)^) if k.size==size_of(u16) else f32((^u8)(p)^))
    case .Corners:
        v:=(^[4]f32)(p)^
        if v[0]==v[1] && v[1]==v[2] && v[2]==v[3] {serial.json_number(out,v[0])} else {serial.json_list(out,v[:])}
    case .Sides:   doc_padding_write(out,(^[4]f32)(p)^)
    case .Size:    doc_size_write(out,types,(^ui.Size)(p)^)
    case .Font:    doc_font_write(out,r,(^u8)(p)^,a)
    case .Program: serial.text_write_string(out,serial.text_field(value))
    case .Numbers: v:=(^[4]f32)(p)^;serial.json_list(out,v[:])
    case .Sounds:
        sounds:=(^[ui.Sound_Cue]base.Asset_Id)(p)
        serial.write_u8(out,'{')
        once:=true
        for cue in ui.Sound_Cue {
            if sounds[cue]=={} {continue}
            serial.json_text(out,doc_enum_text(cue),doc_path(a,sounds[cue]),once)
            once=false
        }
        serial.write_u8(out,'}')
    }
}

doc_vector_write :: proc(out:^serial.Writer,property:ui.Anim_Property,v:[4]f32) {
    v:=v
    #partial switch property {
    case .Scale: if v[0]==v[1] {serial.json_number(out,v[0])} else {serial.json_list(out,v[:2])}
    case .Offset: serial.json_list(out,v[:2])
    case .Color: serial.json_list(out,v[:4])
    case: serial.json_number(out,v[0])
    }
}

document_anim_write :: proc(out:^serial.Writer,r:^Records,row:int) {
    anim:=r.anims[row]
    short:=doc_anim_short(r,row)
    serial.write_u8(out,'{')
    first:=true
    if anim.kind!=.Clip {serial.json_text(out,"kind",fmt.tprintf("%v",anim.kind),first);first=false}
    if short {
        tracks:=r.tracks[anim.first:][:anim.count]
        seconds:=r.keys[tracks[0].first_key+1].time
        ease:=r.keys[tracks[0].first_key+1].ease
        for t in tracks {
            serial.json_key(out,strings.to_lower(fmt.tprintf("%v",t.property),context.temp_allocator),first);first=false
            serial.write_u8(out,'[')
            doc_vector_write(out,t.property,r.keys[t.first_key].value)
            serial.write_u8(out,',')
            doc_vector_write(out,t.property,r.keys[t.first_key+1].value)
            serial.write_u8(out,']')
        }
        serial.json_key(out,"seconds");serial.json_number(out,seconds)
        if ease!=.Linear {serial.json_text(out,"ease",fmt.tprintf("%v",ease))}
    } else if anim.kind==.Clip {
        serial.json_key(out,"tracks",first);first=false
        serial.write_u8(out,'[')
        if u64(anim.first)+u64(anim.count)<=u64(len(r.tracks)) {
            for t,ti in r.tracks[anim.first:][:anim.count] {
                if ti>0 {serial.write_u8(out,',')}
                serial.write_u8(out,'{')
                serial.json_text(out,"property",fmt.tprintf("%v",t.property),true)
                serial.json_key(out,"keys");serial.write_u8(out,'[')
                if u64(t.first_key)+u64(t.key_count)<=u64(len(r.keys)) {
                    for &k,ki in r.keys[t.first_key:][:t.key_count] {
                        if ki>0 {serial.write_u8(out,',')}
                        serial.write_u8(out,'{')
                        serial.json_key(out,"time",true);serial.json_number(out,k.time)
                        serial.json_key(out,"value");serial.json_list(out,k.value[:])
                        serial.json_text(out,"ease",fmt.tprintf("%v",k.ease))
                        if k.interpolation!=.Linear {serial.json_text(out,"interpolation",fmt.tprintf("%v",k.interpolation))}
                        if k.tangents {
                            serial.json_key(out,"tangents");serial.text_write_raw(out,"true")
                            serial.json_key(out,"in_slope");serial.json_list(out,k.in_slope[:])
                            serial.json_key(out,"out_slope");serial.json_list(out,k.out_slope[:])
                        }
                        serial.write_u8(out,'}')
                    }
                }
                serial.text_write_raw(out,"]}")
            }
        }
        serial.write_u8(out,']')
    } else if u64(anim.first)+u64(anim.count)<=u64(len(r.parts)) {
        serial.json_key(out,"parts",first);first=false
        serial.write_u8(out,'[')
        for part,pi in r.parts[anim.first:][:anim.count] {
            if pi>0 {serial.write_u8(out,',')}
            name:=serial.text_field(r.anims[part-1].name[:]) if part>0 && int(part)<=len(r.anims) else ""
            serial.text_write_string(out,name)
        }
        serial.write_u8(out,']')
    }
    if anim.loop!=.Once {serial.json_text(out,"loop",fmt.tprintf("%v",anim.loop),first);first=false}
    serial.write_u8(out,'}')
}

// Whether an animation is a few fields: a clip whose tracks each go in a
// line from a value at 0 to one at the same time, with the same ease.
doc_anim_short :: proc(r:^Records,row:int) -> bool {
    a:=r.anims[row]
    if a.kind!=.Clip || a.count==0 || u64(a.first)+u64(a.count)>u64(len(r.tracks)) {return false}
    seconds:f32
    ease:mm.Ease
    for t,i in r.tracks[a.first:][:a.count] {
        if t.key_count!=2 || u64(t.first_key)+2>u64(len(r.keys)) {return false}
        from,to:=r.keys[t.first_key],r.keys[t.first_key+1]
        if from.time!=0 || from.ease!=.Linear || from.interpolation!=.Linear || to.interpolation!=.Linear || from.tangents || to.tangents {return false}
        if i==0 {seconds,ease=to.time,to.ease} else if to.time!=seconds || to.ease!=ease {return false}
    }
    return true
}

// A node as its parent writes it: {name, kind, ... , children}.
document_node_write :: proc(w:^Doc_Write,row:int) {
    serial.write_u8(w.out,'{')
    document_node_body_write(w,row)
    serial.write_u8(w.out,'}')
}

// What a node says, without its braces.
document_node_body_write :: proc(w:^Doc_Write,row:int) {
    out:=w.out
    r:=w.r
    n:=w.list[row]
    first:=false
    serial.json_text(out,"name",serial.text_field(n.name[:]),true)
    template:=int(n.component)-1
    widget:base.Asset_Id
    if n.kind==.Component {
        component_name:=""
        if template>=0 && template<len(r.components) {
            c:=&r.components[template]
            widget=c.widget
            component_name=doc_use_name(w.assets,c.widget,serial.text_field(c.name[:]))
        }
        serial.json_text(out,"kind",component_name,first)
    } else {
        serial.json_text(out,"kind",fmt.tprintf("%v",n.kind),first)
    }
    // A localized node says what its key says in the language texts are written in, and its key.
    text:=records_text(r,n.text)
    if .Localized in n.flags {
        if said:=texts_text(w.texts,text,w.texts.languages[0]) if w.texts!=nil else "";said!="" {serial.json_text(out,"text",said)}
        serial.json_text(out,"key",text)
    } else if text!="" {serial.json_text(out,"text",text)}
    style:=int(n.style)
    if style==0 {
        // None, where a node without a style would take the one of its kind.
        if _,has:=node_default_look(n.kind);has || records_kind_style(r,n.kind)>=0 {serial.json_text(out,"style","")}
    } else if style<len(r.styles) {
        if records_style_named(r,style) {
            serial.json_text(out,"style",records_style_name(r,style))
        } else if !doc_is_kind_look(r,style,n.kind) {
            serial.json_key(out,"look");document_style_write(out,w.types,r,style,false,w.assets)
        }
    }
    if n.image!=0 && int(n.image)<=len(r.images) {doc_image_write(w,&r.images[n.image-1])}
    if n.anims!=0 && int(n.anims)<=len(r.anim_sets) {
        set:=r.anim_sets[n.anims-1]
        serial.json_key(out,"events");serial.write_u8(out,'{')
        names:=DOCUMENT_EVENTS
        once:=true
        for played,i in (^[len(DOCUMENT_EVENTS)]ui.Anim)(&set)^ {
            // An animation without a name is of the file alone: no document names it, and its trigger stays.
            if played==0 || int(played)>len(r.anims) || r.anims[played-1].name[0]==0 {continue}
            serial.json_text(out,names[i],serial.text_field(r.anims[played-1].name[:]),once)
            once=false
        }
        serial.write_u8(out,'}')
    }
    // The values of the parameters of a use, by their names.
    root_fields:=make([dynamic]string,context.temp_allocator)
    fields:=DOC_PARAM_FIELDS
    if lib:=doc_lib_of(w.libs,widget);lib!=nil {
        for &p in lib.linked.params {
            if value,has:=doc_param_value(w,row,&p);has {serial.json_text(out,serial.text_field(p.name[:]),value)}
            if serial.text_field(p.node[:])=="" {append(&root_fields,fields[p.field])}
        }
    }
    doc_node_fields_write(w,row,&n,root_fields[:])
    if .Slot in n.flags {serial.json_bool(out,"slot",true)}
    end:=row+records_subtree(w.list,row)
    children:=false
    for child in row+1..=end {
        if int(w.list[child].parent)!=row {continue}
        if !children {serial.json_key(out,"children");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        children=true
        document_node_write(w,child)
    }
    if children {serial.write_u8(out,']')}
}

// The group of fields of an instance or an override a field of a parameter is in.
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
doc_is_kind_look :: proc(r:^Records,row:int,kind:ui.Node_Kind) -> bool {
    look,has:=node_default_look(kind)
    if !has || row>=len(r.styles) || r.styles[row]!=look || row<len(r.style_infos) && r.style_infos[row].extends[0]!=0 {return false}
    for &v in r.variants {if int(v.style)==row {return false}}
    return true
}

// Its image, with the texture by its path.
doc_image_write :: proc(w:^Doc_Write,image:^ui.Tree_Image) {
    out:=w.out
    serial.json_key(out,"image");serial.write_u8(out,'{')
    serial.json_text(out,"texture",doc_path(w.assets,image.texture),true)
    image_type,_:=asset.types_index(w.types,ui.Tree_Image)
    defaults:=ui.Tree_Image{texture=image.texture}
    doc_changed_write(w,image_type,mem.ptr_to_bytes(image),mem.ptr_to_bytes(&defaults),{"texture"})
    serial.write_u8(out,'}')
}

// The fields of a value that differ from defaults as keys of the object
// being written; each after a comma.
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
            case .Values:     append(&skip,"index","count","choice","limit","delay","range","particle","draw")
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
    out:=w.out
    for which in ui.LAYOUT_KEYS {
        given:=which in info.layout_keys && which not_in n.layout_own
        if given {continue}
        probe:=n.layout
        ui.layout_key_copy(&probe,&d,which)
        if which not_in n.layout_own && probe==n.layout {continue}
        serial.json_key(out,ui.STYLE_KEYS[which].name)
        doc_key_write(out,w.types,r,w.assets,which,ui.layout_key_value(&n.layout,which))
    }
}

// ---------------------------------------------------------------- reading

// A node of a document, read in pre-order.
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

// Prefixes the error of the reading with where it happened; false.
document_failed :: proc(reading:^Reading,what:string) -> bool {
    reading.problem=fmt.aprintf("%s: %s",what,reading.problem,allocator=reading.allocator)
    return false
}

document_row_of :: proc(r:^Records,name:string) -> int {
    for &n,i in r.nodes {if serial.text_field(n.name[:])==name {return i}}
    return -1
}

// Makes the records say what the document declares: with root>=0, that node
// and what it holds, and otherwise the whole file. Tokens and styles go
// first, since nodes take them by name; those it takes away, last. False
// after failing the reading, with where in the document.
document_apply :: proc(args:^Tree_Args,r:^Records,root:int,text:string) -> (made,removed:int,ok:bool) {
    reading:=args.reading
    keys,values:=tree_object(reading,text,"document") or_return
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
            reading_fail(reading,"document has no 'components': a component is a widget, a .ui of its own; write it as a file and name it in use")
            return
        case:
            reading_failf(reading,"document has no '%s'; it has use, params, tokens, styles, animations and nodes",key)
            return
        }
    }
    // What the document takes from other files, before any name is read.
    used:=make([dynamic]base.Asset_Id,reading.allocator)
    if use!="" {
        items,items_ok:=doc_items(reading,use,"use")
        if !items_ok {return}
        for item,i in items {
            path,is_text:=doc_string(reading,item)
            if !is_text {reading_failf(reading,"use[%d] must be the path of a .ui",i);return}
            what:=fmt.tprintf("use[%d]",i)
            id:=doc_use_resolve(args,path,what) or_return
            if id==args.asset {reading_failf(reading,"use[%d]: a .ui takes names from other files, not from itself",i);return}
            if chain:=doc_reaches(args.assets,id,args.asset);chain!="" {reading_failf(reading,"use[%d]: '%s' uses this file back, a cycle: %s",i,path,chain);return}
            name:=doc_use_name(args.assets,id,"")
            for k in ui.Node_Kind {if fmt.tprintf("%v",k)==name {reading_failf(reading,"use[%d]: a node kind goes by the name '%s'; give the file another",i,name);return}}
            for other,j in used {
                if other!=id && doc_use_name(args.assets,other,"")==name {reading_failf(reading,"use[%d]: '%s' goes by the name of use[%d]; a use names a widget by its file: give one another name",i,path,j);return}
            }
            append(&used,id)
            records_use_row(r,id,name)
        }
    }
    libs:=doc_libs(args,r,used[:])
    args.libs=&libs
    defer args.libs=nil
    if tokens!="" && !doc_tokens_apply(reading,r,tokens) {return}
    gone_styles:=make([dynamic]string,reading.allocator)
    gone_anims:=make([dynamic]string,reading.allocator)
    if styles!="" {
        style_keys,style_values:=tree_object(reading,styles,"styles") or_return
        // Every name first, so that a style can extend one declared after it.
        for name,i in style_keys {
            if strings.trim_space(style_values[i])=="null" {continue}
            if tree_style_row(r,name)>=0 && r.style_infos[tree_style_row(r,name)].from==0 {continue}
            if name=="" || len(name)>=ui.TREE_NAME_CAPACITY {reading_failf(reading,"styles.%s: a style has a name shorter than %d bytes",name,ui.TREE_NAME_CAPACITY);return}
            info:=ui.Tree_Style_Info{}
            ui.tree_text_set(info.name[:],name)
            // A style of this name that was another file's becomes this one.
            if row:=tree_style_row(r,name);row>=0 {
                r.style_infos[row].from=0
            } else if records_style_add(r,{},{},info)<0 {
                reading_broke(reading,"the .ui holds no more styles");return
            }
        }
        for name,i in style_keys {
            what:=fmt.tprintf("styles.%s",name)
            if strings.trim_space(style_values[i])=="null" {append(&gone_styles,name);continue}
            style_args:=args^
            style_args.keys,style_args.values,ok=tree_object(reading,style_values[i],what)
            if !ok {return}
            if !document_style_apply(&style_args,r,tree_style_row(r,name),true) {ok=document_failed(reading,what);return}
        }
    }
    if anims!="" {
        anim_keys,anim_values:=tree_object(reading,anims,"animations") or_return
        for name,i in anim_keys {
            what:=fmt.tprintf("animations.%s",name)
            if strings.trim_space(anim_values[i])=="null" {append(&gone_anims,name);continue}
            if !document_anim_apply(args,r,name,anim_values[i]) {ok=document_failed(reading,what);return}
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
            reading_failf(reading,"styles.%s: nodes still take it or change it; give them another style in the same document",name)
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
                reading_failf(reading,"use: '%s' is not listed, but a node is a use of it or a style takes from it; change them in the same document",doc_path(args.assets,id))
                return
            }
        }
    }
    // A named style a node of the file takes is of the family of that node.
    if root<0 {
        for &n in r.nodes {doc_style_family(r,&n)}
        if params!="" && !document_params_apply(args,r,params) {return made,removed,false}
        if !document_widget_shape(reading,r) {return made,removed,false}
    }
    if nodes!="" && !document_paths_check(args,r,root) {return made,removed,false}
    return made,removed,true
}

doc_style_family :: proc(r:^Records,n:^ui.Tree_Node) {
    if int(n.style)>0 && int(n.style)<len(r.style_infos) && records_style_named(r,int(n.style)) {r.style_infos[n.style].family=style_family(n.kind)}
}

doc_tokens_apply :: proc(reading:^Reading,r:^Records,text:string) -> bool {
    keys,values:=tree_object(reading,text,"tokens") or_return
    for name,i in keys {
        row:=-1
        for &t,j in r.tokens {if serial.text_field(t.name[:])==name {row=j;break}}
        value:=strings.trim_space(values[i])
        if value=="null" {
            if row>=0 {ordered_remove(&r.tokens,row)}
            continue
        }
        token:ui.Tree_Token
        if name=="" || len(name)>=ui.TREE_NAME_CAPACITY {reading_failf(reading,"tokens.%s: a token has a name shorter than %d bytes",name,ui.TREE_NAME_CAPACITY);return false}
        ui.tree_text_set(token.name[:],name)
        if number,is_number:=doc_number(value);is_number {
            token.numeric,token.number=true,number
        } else if word,is_text:=doc_string(reading,value);is_text {
            color,parsed:=doc_color_parse(word)
            if !parsed {reading_failf(reading,"tokens.%s: '%s' is no color: write #rrggbb or #rrggbbaa",name,word);return false}
            token.color=color
        } else {
            reading_failf(reading,"tokens.%s must be a number or a color, #rrggbb or #rrggbbaa",name)
            return false
        }
        if row>=0 {r.tokens[row]=token} else {append(&r.tokens,token)}
    }
    return true
}

// A style as the document declares it, at row: what it extends, its values,
// states, variants and rules. named false for a look of a node.
document_style_apply :: proc(args:^Tree_Args,r:^Records,row:int,named:bool) -> bool {
    reading:=args.reading
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
            if !named {reading_fail(reading,"family: a look is of the family of its node");return false}
            text,_,read:=tree_arg_string(args,"family")
            if !read {return false}
            known:=false
            for f in ui.Style_Family {if fmt.tprintf("%v",f)==text {info.family,known=f,true}}
            if !known {reading_failf(reading,"family '%s' is none of Box, Text, Control",text);return false}
        case "extends":
            word,is_text:=doc_string(reading,value)
            if !is_text {reading_fail(reading,"extends must be the name of a style");return false}
            ui.tree_text_set(info.extends[:],word)
        case "defaults","hover","focus","pressed","disabled","selected","over","variants","rules":
        case:
            if !doc_style_value_apply(args,r,row,style,info,&info.sets,"",{},key,value) {return false}
        }
    }
    if ext:=serial.text_field(info.extends[:]);ext!="" {
        if doc_style_known(args,r,ext)<0 {reading_failf(reading,"extends: '%s' is no style of this file or of a file it uses",ext);return false}
        // A look is the override of a style of the file: one another file
        // lends has a row here too, made the first time.
        if !named {
            if doc_style_row(args,r,ext)<0 {reading_brokef(reading,"the .ui holds no more styles");return false}
            info=&r.style_infos[row]
        }
    }
    if text,found:=tree_arg(args,"defaults");found {
        kinds,read:=tree_kinds_read(reading,text,info.family)
        if !read {return false}
        records_kind_style_set(r,row,kinds)
    }
    for s in DOC_STATES {
        text,found:=tree_arg(args,s.key)
        if !found {continue}
        rule_keys,rule_values:=tree_object(reading,text,s.key) or_return
        rule:=doc_rule_row(r,row,"",s.states)
        if !doc_rule_apply(args,r,row,rule,rule_keys,rule_values,s.key) {return document_failed(reading,s.key)}
    }
    if text,found:=tree_arg(args,"variants");found {
        keys,values:=tree_object(reading,text,"variants") or_return
        for name,i in keys {
            what:=fmt.tprintf("variants.%s",name)
            rule_keys,rule_values:=tree_object(reading,values[i],what) or_return
            rule:=doc_rule_row(r,row,name,{})
            if !doc_rule_apply(args,r,row,rule,rule_keys,rule_values,what) {return document_failed(reading,what)}
        }
    }
    if text,found:=tree_arg(args,"rules");found {
        items:=doc_items(reading,text,"rules") or_return
        for item,at in items {
            what:=fmt.tprintf("rules[%d]",at)
            rule_keys,rule_values:=tree_object(reading,item,what) or_return
            rule_args:=args^
            rule_args.keys,rule_args.values=rule_keys,rule_values
            variant,_,variant_ok:=tree_arg_string(&rule_args,"variant")
            if !variant_ok {return false}
            states:ui.Style_States
            if states_text,has:=tree_arg(&rule_args,"states");has {
                names:=doc_items(reading,states_text,what) or_return
                for name_item in names {
                    state_name,is_text:=doc_string(reading,name_item)
                    known:=false
                    for state in ui.Style_State {if is_text && fmt.tprintf("%v",state)==state_name {states+={state};known=true}}
                    if !known {reading_failf(reading,"%s.states: '%s' is none of Selected, Hovered, Focused, Over, Pressed, Disabled",what,state_name);return false}
                }
            }
            look_keys:=make([dynamic]string,reading.allocator)
            look_values:=make([dynamic]string,reading.allocator)
            for key,i in rule_keys {
                switch key {
                case "variant","states":
                case: append(&look_keys,key);append(&look_values,rule_values[i])
                }
            }
            rule:=doc_rule_row(r,row,variant,states)
            if !doc_rule_apply(args,r,row,rule,look_keys,look_values,what) {return document_failed(reading,what)}
        }
    }
    return true
}

// Whether a style of this name exists; -1: none.
doc_style_known :: proc(args:^Tree_Args,r:^Records,name:string) -> int {
    if row:=tree_style_row(r,name);row>=0 {return row}
    if args.libs==nil {return -1}
    for &lib in args.libs {
        for &info,i in lib.records.style_infos {if serial.text_field(info.name[:])==name {return i}}
    }
    return -1
}

// The rule of a style for a variant and states, made the first time.
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
doc_rule_apply :: proc(args:^Tree_Args,r:^Records,style,rule:int,keys,values:[dynamic]string,what:string) -> bool {
    reading:=args.reading
    rule_args:=args^
    rule_args.keys,rule_args.values=keys,values
    own:ui.Style_Keys
    v:=&r.variants[rule]
    variant:=strings.clone(serial.text_field(v.variant[:]),reading.allocator)
    states:=v.states
    for key,i in keys {
        if key=="extends" {
            word,is_text:=doc_string(reading,values[i])
            found:ui.Style_States
            ok:=false
            for s in DOC_STATES {if is_text && s.key==word {found,ok=s.states,true}}
            if !ok {reading_failf(reading,"extends: '%s' is no state; it has hover, focus, pressed, disabled, selected and over",word);return false}
            r.variants[rule].extends=found
            continue
        }
        if !doc_style_value_apply(&rule_args,r,style,&r.variants[rule].patch.values,nil,&own,variant,states,key,values[i]) {return false}
    }
    v=&r.variants[rule]
    if v.extends!={} {
        found:=false
        for &other in r.variants {found||=int(other.style)==style && other.states==v.extends && other.variant==v.variant}
        if !found {reading_failf(reading,"extends: the style has no rule for that state; declare it in the same document");return false}
    }
    v.own=own
    v.patch.fields=ui.style_keys_fields(own)
    return true
}

// One key of a look by the name a document gives it, or the object of its
// parts: those it does not name stay as the base has them. own gets what it sets.
doc_style_value_apply :: proc(args:^Tree_Args,r:^Records,row:int,style:^ui.Node_Style,info:^ui.Tree_Style_Info,own:^ui.Style_Keys,variant:string,states:ui.Style_States,key,value:string) -> bool {
    reading:=args.reading
    is_rule:=info==nil
    if which,found:=doc_key_find("",key);found {
        return doc_style_key_apply(args,r,row,style,info,own,variant,states,which,key,value)
    }
    parts:=doc_key_names(key,false)
    if parts=="" {
        if is_rule {
            reading_failf(reading,"a state has no '%s'; it has %s and extends",key,doc_key_names("",true))
            return false
        }
        reading_failf(reading,"a style has no '%s'; it has extends, %s, hover, focus, pressed, disabled, selected, over, variants and rules",key,doc_key_names("",false))
        return false
    }
    keys,values:=tree_object(reading,value,key) or_return
    for part,i in keys {
        which,found:=doc_key_find(key,part)
        if !found {
            reading_failf(reading,"%s has no '%s'; it has %s",key,part,parts)
            return false
        }
        if !doc_style_key_apply(args,r,row,style,info,own,variant,states,which,fmt.tprintf("%s.%s",key,part),values[i]) {return false}
    }
    return true
}

// One value of a look, by its key. what: where the document says it.
doc_style_key_apply :: proc(args:^Tree_Args,r:^Records,row:int,style:^ui.Node_Style,info:^ui.Tree_Style_Info,own:^ui.Style_Keys,variant:string,states:ui.Style_States,key:ui.Style_Key,what,value:string) -> bool {
    if info==nil && !ui.STYLE_KEYS[key].rule {
        reading_failf(args.reading,"a state does not set %s: it goes in the style",what)
        return false
    }
    own^+={key}
    token:=doc_key_read(args,r,key,what,value,ui.style_value(style,info,key)) or_return
    if key==.Shadow_Color {style.shadow=style.shadow_color[3]>0}
    if token!="" {records_token_use(r,row,variant,states,key,token)}
    return true
}

// One value by its key, into its bytes: of a style (r), which can give the
// name of a token of a number or of a color and says so in token, or of a
// node (r nil), which cannot. False after failing the reading.
doc_key_read :: proc(args:^Tree_Args,r:^Records,key:ui.Style_Key,what,text:string,value:[]u8) -> (token:string,ok:bool) {
    reading:=args.reading
    k:=ui.STYLE_KEYS[key]
    p:=raw_data(value)
    trimmed:=strings.trim_space(text)
    switch k.kind {
    case .Number:
        number:f32
        number,token=doc_number_value(args,r,trimmed,what) or_return
        (^f32)(p)^=number
    case .Color:
        color:ui.Color
        color,token=doc_color_value(args,r,trimmed,what) or_return
        (^ui.Color)(p)^=color
    case .Enum:
        return "",doc_enum_read(reading,trimmed,what,k.type,p)
    case .Flag:
        on,is_bool:=doc_bool(trimmed)
        if !is_bool {return "",doc_failed(reading,"%s must be true or false",what)}
        (^bool)(p)^=on
    case .Count:
        most:=f32(max(u16)) if k.size==size_of(u16) else f32(max(u8))
        number,is_number:=doc_number(trimmed)
        if !is_number || number<0 || number>most || number!=f32(int(number)) {return "",doc_failed(reading,"%s must be a whole number from 0 to %g",what,most)}
        if k.size==size_of(u16) {(^u16)(p)^=u16(number)} else {(^u8)(p)^=u8(number)}
    case .Corners:
        corners:=(^[4]f32)(p)
        if number,is_number:=doc_number(trimmed);is_number {
            corners^={number,number,number,number}
        } else if word,is_text:=doc_string(reading,trimmed);is_text {
            number:=doc_number_token(args,r,word,what) or_return
            corners^,token={number,number,number,number},word
        } else {
            items:=doc_items(reading,trimmed,what) or_return
            if len(items)!=4 {return "",doc_failed(reading,"%s: give a number, a token or four numbers",what)}
            for item,i in items {
                number,is_number:=doc_number(item)
                if !is_number {return "",doc_failed(reading,"%s: give numbers",what)}
                corners[i]=number
            }
        }
    case .Sides:
        sides:=(^[4]f32)(p)
        word:=doc_padding_read(reading,trimmed,what,sides) or_return
        if word!="" {
            if r==nil {return "",doc_failed(reading,"%s: '%s': on a node give numbers; a token goes in a style",what,word)}
            number:=doc_number_token(args,r,word,what) or_return
            sides^,token=ui.padding_all(number),word
        }
    case .Size:
        size:=(^ui.Size)(p)
        word:=doc_size_read(args,trimmed,what,size) or_return
        if word!="" {
            if r==nil {return "",doc_failed(reading,"%s: '%s' is no size: on a node give a number, \"grow\", \"fit\" or \"50%%\"; a token goes in a style",what,word)}
            number:=doc_number_token(args,r,word,what) or_return
            size^,token=ui.fixed(number),word
        }
    case .Font:
        word,is_text:=doc_string(reading,trimmed)
        if !is_text {return "",doc_failed(reading,"%s must be regular, medium, semibold, or the path of a .font",what)}
        font:=(^u8)(p)
        switch word {
        case "regular":  font^=ui.FONT_REGULAR
        case "medium":   font^=ui.FONT_MEDIUM
        case "semibold": font^=ui.FONT_SEMIBOLD
        case:
            named:=reading.assets
            if named.resolve==nil {return "",doc_failed(reading,"%s: no project to read '%s' from",what,word)}
            id,problem:=named.resolve(named.user,word,".font")
            if problem!="" {return "",doc_failed(reading,"%s: %s",what,problem)}
            at:=-1
            for &f,i in r.fonts {if f.font==id {at=i}}
            if at<0 {append(&r.fonts,ui.Tree_Font{font=id});at=len(r.fonts)-1}
            font^=u8(ui.FONT_TREE+at)
        }
    case .Program:
        word,is_text:=doc_string(reading,trimmed)
        if !is_text {return "",doc_failed(reading,"%s must be the name of a ui program",what)}
        ui.tree_text_set(value,word)
    case .Numbers:
        numbers:=(^[4]f32)(p)
        items:=doc_items(reading,trimmed,what) or_return
        for item,i in items {
            if i>=len(numbers) {break}
            number,is_number:=doc_number(item)
            if !is_number {return "",doc_failed(reading,"%s: give numbers",what)}
            numbers[i]=number
        }
    case .Sounds:
        sounds:=(^[ui.Sound_Cue]base.Asset_Id)(p)
        cues,paths:=tree_object(reading,trimmed,what) or_return
        for name,i in cues {
            cue:ui.Sound_Cue
            known:=false
            for c in ui.Sound_Cue {if doc_enum_text(c)==name {cue,known=c,true}}
            if !known {return "",doc_failed(reading,"%s has no '%s'; it has show, hide, hover, focus, press and change",what,name)}
            path,_:=doc_string(reading,paths[i])
            named:=reading.assets
            if named.resolve==nil {return "",doc_failed(reading,"%s.%s: no project to read '%s' from",what,name,path)}
            id,problem:=named.resolve(named.user,path,".sound")
            if problem!="" {return "",doc_failed(reading,"%s.%s: %s",what,name,problem)}
            sounds[cue]=id
        }
    }
    return token,true
}

doc_libs_slice :: proc(args:^Tree_Args) -> []Doc_Lib {
    if args.libs==nil {return nil}
    return args.libs[:]
}

// An animation as the document declares it: a few fields (a property from one
// value to another), or its tracks or parts. One the file has keeps its row,
// so the events that play it still do.
document_anim_apply :: proc(args:^Tree_Args,r:^Records,name,text:string) -> bool {
    reading:=args.reading
    anim:=args^
    keys,values:=tree_object(reading,text,"the animation") or_return
    properties:=[ui.Anim_Property]string{.Offset="offset",.Scale="scale",.Rotation="rotation",.Opacity="opacity",.Color="color",.Width="width",.Height="height",.Value="value",.Frame="frame",.Reveal="reveal"}
    short_tracks:=strings.builder_make(reading.allocator)
    seconds:=f32(-1)
    ease:="Linear"
    short:=false
    fixed_keys:=make([dynamic]string,reading.allocator)
    fixed_values:=make([dynamic]string,reading.allocator)
    for key,i in keys {
        property:ui.Anim_Property
        known:=false
        for member in ui.Anim_Property {if properties[member]==key {property,known=member,true}}
        switch {
        case known:
            short=true
            items:=doc_items(reading,values[i],key) or_return
            if len(items)!=2 {reading_failf(reading,"%s must be [from, to]",key);return false}
            if strings.builder_len(short_tracks)>0 {strings.write_byte(&short_tracks,',')}
            from:=doc_vector_read(reading,items[0],property) or_return
            to:=doc_vector_read(reading,items[1],property) or_return
            fmt.sbprintf(&short_tracks,`{{"property":"%v","keys":[{{"time":0,"value":[%g,%g,%g,%g]}},{{"time":%%SECONDS%%,"value":[%g,%g,%g,%g],"ease":"%%EASE%%"}}]}}`,property,from[0],from[1],from[2],from[3],to[0],to[1],to[2],to[3])
        case key=="seconds":
            number,ok:=doc_number(values[i])
            if !ok {reading_fail(reading,"seconds must be a number");return false}
            seconds=number
        case key=="ease":
            word,is_text:=doc_string(reading,values[i])
            if !is_text {reading_fail(reading,"ease must be the name of an ease of std/math, as Linear, Cubic_Out or Back_Out");return false}
            ease=word
        case key=="kind" || key=="loop" || key=="tracks" || key=="parts":
            append(&fixed_keys,key);append(&fixed_values,values[i])
        case:
            reading_failf(reading,"an animation has no '%s'; it has offset, scale, rotation, opacity, color, width, height, value, frame, reveal, seconds, ease, kind, loop, tracks and parts",key)
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
        text,_=strings.replace_all(text,"%SECONDS%",fmt.tprintf("%g",seconds),reading.allocator)
        text,_=strings.replace_all(text,"%EASE%",ease,reading.allocator)
        append(&anim.keys,"tracks")
        append(&anim.values,fmt.tprintf("[%s]",text))
    }
    return tree_anim_apply(&anim,r)>=0
}

doc_vector_read :: proc(reading:^Reading,text:string,property:ui.Anim_Property) -> (v:[4]f32,ok:bool) {
    trimmed:=strings.trim_space(text)
    if number,is_number:=doc_number(trimmed);is_number {
        v={number,0,0,0}
        if property==.Scale {v[1]=number}
        return v,true
    }
    items:=doc_items(reading,trimmed,"the value") or_return
    for item,i in items {
        if i>=4 {break}
        n,parsed:=doc_number(item)
        if !parsed {reading_fail(reading,"give numbers");return v,false}
        v[i]=n
    }
    return v,true
}

// Reads the nodes of an array in pre-order, each after the node that holds it.
document_nodes_read :: proc(args:^Tree_Args,r:^Records,text:string,parent:int,path:string,out:^[dynamic]Document_Node) -> bool {
    reading:=args.reading
    items:=doc_items(reading,text,path,"nodes") or_return
    for item,at in items {
        d:=Document_Node{path=fmt.aprintf("%s[%d]",path,at,allocator=reading.allocator),parent=parent,row=-1}
        ok:bool
        d.keys,d.values,ok=tree_object(reading,item,d.path)
        if !ok {return false}
        node_args:=args^
        node_args.keys,node_args.values=d.keys,d.values
        name,_,named:=tree_arg_string(&node_args,"name")
        if !named {return document_failed(reading,d.path)}
        d.name=name
        if _,has_widget:=tree_arg(&node_args,"widget");has_widget {reading_failf(reading,"%s.widget: name the file in use and the widget by the name of its file in kind",d.path);return false}
        kind_text,has_kind,kind_ok:=tree_arg_string(&node_args,"kind")
        if !kind_ok {return document_failed(reading,d.path)}
        if !has_kind {reading_failf(reading,"%s: kind is required: a Node_Kind or the name of a widget the document uses",d.path);return false}
        known:bool
        for k in ui.Node_Kind {if k!=.Component && fmt.tprintf("%v",k)==kind_text {d.kind,known=k,true}}
        if !known {
            d.widget=doc_use_find(args,kind_text)
            if d.widget=={} {
                reading_failf(reading,"%s: kind '%s' is no Node_Kind and no widget of a file this one uses; use names a file, and its name without folder or extension is the kind",d.path,kind_text)
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
document_nodes_apply :: proc(args:^Tree_Args,r:^Records,root:int,text:string) -> (made,removed:int,ok:bool) {
    reading:=args.reading
    decls:=make([dynamic]Document_Node,reading.allocator)
    if !document_nodes_read(args,r,text,-1,"nodes",&decls) {return}
    first,last:=0,len(r.nodes)
    top:=-1 // the parent of the nodes at the top of the document
    if root>=0 {
        first,last=root,root+records_subtree(r.nodes[:],root)+1
        tops:=0
        for &d in decls {tops+=int(d.parent<0)}
        if tops!=1 {reading_fail(reading,"nodes: with node, the document declares that node alone, and what it holds as its children");return}
        top=int(r.nodes[root].parent)
    }
    inside :: proc(row,first,last:int) -> bool {return row>=first && row<last}
    for &d,i in decls {
        if d.name=="" {continue}
        for &other in decls[:i] {
            if other.name==d.name {reading_failf(reading,"%s.name: '%s' is declared twice; names are unique in a file",d.path,d.name);return}
        }
        if row:=document_row_of(r,d.name);row>=0 && !inside(row,first,last) {
            reading_failf(reading,"%s.name: the node '%s' is outside the part this write declares; names are unique in a file",d.path,d.name)
            return
        }
    }
    // Matched by name and kind; the node of root is the top of the document whatever its name.
    for &d in decls {
        if root>=0 && d.parent<0 {
            if !document_same_kind(args,r,root,&d) {reading_failf(reading,"%s.kind: a node keeps its kind; write the node that holds it to put another in its place",d.path);return}
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
    taken:=make([]bool,last-first,reading.allocator)
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
    for &d in decls {if d.row>=0 {d.current=strings.clone(serial.text_field(r.nodes[d.row].name[:]),reading.allocator)}}
    // Each in order, last inside the node that holds it. Rows move as nodes
    // do: placed nodes are found by name, the node of root keeps its row.
    for &d in decls {
        if d.row==root && root>=0 {continue}
        parent:=top
        if d.parent>=0 {
            holder:=&decls[d.parent]
            parent=root if holder.row==root && root>=0 else document_row_of(r,holder.current)
        }
        // A List takes the one node the document declares for it: what it held
        // is that node, or goes below.
        if parent>=0 && r.nodes[parent].kind==.List {
            declared:=0
            for &other in decls {declared+=int(other.parent==d.parent)}
            if declared>1 {
                reading_fail(reading,"parent: a List holds one node, the one it builds per element; put a Box there to hold more")
                ok=document_failed(reading,d.path)
                return
            }
        } else if parent>=0 && !doc_takes(reading,r,parent) {ok=document_failed(reading,d.path);return}
        if d.row>=0 {
            row:=document_row_of(r,d.current)
            if records_place(r,row,parent,-1,true)<0 {reading_failf(reading,"%s: a node cannot go inside itself or what it holds",d.path);return}
            continue
        }
        row:int
        if d.kind==.Component {
            file:=doc_use_name(args.assets,d.widget,"widget")
            row=records_widget(r,parent,d.widget,d.name if d.name!="" else file,file)
        } else {
            row=records_insert(r,parent,d.kind,true)
        }
        if row<0 {reading_brokef(reading,"%s: the node could not be made",d.path);return}
        if d.name!="" {ui.tree_text_set(r.nodes[row].name[:],d.name)}
        d.current=strings.clone(serial.text_field(r.nodes[row].name[:]),reading.allocator)
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
        if !document_node_apply(args,r,row,&d) {ok=document_failed(reading,d.path);return}
    }
    for &d in decls {
        if d.name=="" && !(d.row==root && root>=0) {r.nodes[document_row_of(r,d.current)].name={}}
    }
    return made,removed,true
}

// A node with a key is Localized: its text in the file is the key, and the
// text the document gives is what the key says in the language texts are
// written in, set in the texts of the reading. An empty key is made from
// that text (texts_key).
doc_node_key_apply :: proc(args:^Tree_Args,r:^Records,n:^ui.Tree_Node,d:^Document_Node) -> bool {
    node_args:=args^
    node_args.keys,node_args.values=d.keys,d.values
    key,localized,read:=tree_arg_string(&node_args,"key")
    if !read || !localized {return read}
    if args.texts==nil {reading_broke(args.reading,"key: the document is read without the texts of the game");return false}
    text:=records_text(r,n.text)
    if key=="" {
        if text=="" {return doc_failed(args.reading,"key: \"\" makes the key from the text of the node, and it has none; give text, or the key")}
        key=texts_key(args.texts,text)
    }
    if text!="" {
        if problem:=texts_set(args.texts,key,args.texts.languages[0],text);problem!="" {return doc_failed(args.reading,"key: %s",problem)}
    }
    records_text_set(r,&n.text,key)
    n.flags+={.Localized}
    return true
}

// A use holds what the Slot of its widget holds; a Box and the other
// containers hold their own.
doc_takes :: proc(reading:^Reading,r:^Records,parent:int) -> bool {
    if parent>=0 && r.nodes[parent].kind==.Component {return true}
    return tree_takes(reading,r,parent)
}

// The Node_Field a flat key of an instance sets.
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
    case "index","count","choice","limit","delay","range","particle","draw": return .Values,true
    case "action","hold":  return .Action,true
    case "nav","order","flags": return .Focus,true
    case "tag","accepts","ghost": return .Drag,true
    case "bind_text","bind_value","bind_visible","bind_selected","bind_disabled","bind_items","bind_image","bind_tint","bind_variant","data": return .Bindings,true
    }
    if _,is_layout:=doc_layout_key(key);is_layout {return .Layout,true}
    return .Text,false
}

// The key of a layout a name is: width and the others, of a node or a style.
doc_layout_key :: proc(name:string) -> (which:ui.Style_Key,ok:bool) {
    which=doc_key_find("",name) or_return
    return which,which in ui.LAYOUT_KEYS
}

// The node at row (of the records' tree) becomes what d declares: what it
// does not give is that of a new node of its kind. It keeps what ties it to
// the file: as an instance, the overrides of it.
document_node_apply :: proc(args:^Tree_Args,r:^Records,row:int,d:^Document_Node) -> bool {
    reading:=args.reading
    n:=&r.nodes[row]
    old:=n^
    fresh:=node_default(old.kind)
    fresh.parent,fresh.name,fresh.component=old.parent,old.name,old.component
    n^=fresh
    if d.name!="" && d.name!=serial.text_field(old.name[:]) {
        if !tree_name_free(reading,r,row,d.name) {return false}
        ui.tree_text_set(n.name[:],d.name)
    }
    if !doc_node_keys_apply(args,r,n,row,d) {return false}
    n=&r.nodes[row]
    // A trigger that played an animation without a name stays: no document names one.
    if old.anims!=0 && int(old.anims)<=len(r.anim_sets) {
        kept:=r.anim_sets[old.anims-1]
        for played,i in (^[len(DOCUMENT_EVENTS)]ui.Anim)(&kept)^ {
            if played==0 || int(played)>len(r.anims) || r.anims[played-1].name[0]!=0 {continue}
            at:=records_anim_set(r,n)
            if at<0 {break}
            if slots:=(^[len(DOCUMENT_EVENTS)]ui.Anim)(&r.anim_sets[at]);slots[i]==0 {slots[i]=played}
        }
    }
    if .Localized in n.flags {return doc_failed(reading,"flags: a node is Localized by its key; give key, the key of the texts of the game it shows (\"\" makes one from its text), and leave Localized out")}
    if !doc_node_key_apply(args,r,n,d) {return false}
    node_args:=args^
    node_args.keys,node_args.values=d.keys,d.values
    _,has_style:=tree_arg(&node_args,"style")
    if look,found:=tree_arg(&node_args,"look");found {
        if has_style {return doc_failed(reading,"look: a node has a style or a look; a look that changes a style names it in extends")}
        info:=ui.Tree_Style_Info{family=style_family(n.kind)}
        style:=records_style_add(r,{},{},info)
        if style<0 {reading_broke(reading,"the .ui holds no more styles");return false}
        look_args:=args^
        ok:bool
        look_args.keys,look_args.values,ok=tree_object(reading,look,"look")
        if !ok {return false}
        if !document_style_apply(&look_args,r,style,false) {return document_failed(reading,"look")}
        r.nodes[row].style=u16(style)
    } else if !has_style && n.kind!=.Component {
        r.nodes[row].style=records_kind_look(r,n.kind)
    }
    return true
}

// What a node declares, written into n: its text, style name, image, events
// and flat fields; a use of a widget also its parameters.
doc_node_keys_apply :: proc(args:^Tree_Args,r:^Records,n:^ui.Tree_Node,row:int,d:^Document_Node) -> bool {
    reading:=args.reading
    n_args:=args^
    n_args.keys,n_args.values=d.keys,d.values
    lib:=doc_lib_of(doc_libs_slice(args),d.widget)
    params:=lib.linked.params if lib!=nil else nil
    use_name:=doc_use_name(args.assets,d.widget,"") if d.widget!={} else ""
    flat:=make([dynamic]string,reading.allocator)
    param_values:=make([dynamic]string,reading.allocator)
    reserved:=DOCUMENT_NODE_KEYS
    is_instance:=n.kind==.Component
    slot:=false
    for key,i in d.keys {
        if key=="slot" {
            on,is_bool:=doc_bool(d.values[i])
            if !is_bool {return doc_failed(reading,"slot must be true or false")}
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
            if _,read:=doc_key_read(args,nil,which,key,d.values[i],ui.layout_key_value(&n.layout,which));!read {return false}
            if is_instance {n.component_fields+={.Layout}}
            continue
        }
        if is_instance {
            field,known:=doc_instance_field(key)
            if !known {
                names:=make([dynamic]string,context.temp_allocator)
                for &p in params {append(&names,serial.text_field(p.name[:]))}
                return doc_failed(reading,"%s has no parameter '%s'; it has %s, and the keys of a node",use_name,key,strings.join(names[:],", ",context.temp_allocator))
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
    if _,localized:=tree_arg(&n_args,"key");localized && is_instance {n.component_fields+={.Text}}
    if style,found,ok:=tree_arg_string(&n_args,"style");!ok {return false} else if found {
        if style=="" {
            n.style=0
        } else {
            at:=doc_style_row(args,r,style)
            if at<0 {return doc_failed(reading,"style: '%s' is no style of this file or of a file it uses; styles declares one, and use takes a file",style)}
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
            if at<0 {reading_broke(reading,"the .ui holds no more images");return false}
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
        b:=strings.builder_make(reading.allocator)
        strings.write_byte(&b,'{')
        for key,i in flat {
            if i>0 {strings.write_byte(&b,',')}
            fmt.sbprintf(&b,"%q:%s",key,doc_value_of(d,key))
        }
        strings.write_byte(&b,'}')
        refused,why:=TREE_NODE_REFUSED,TREE_NODE_WHY
        if !tree_fields_read(reading,args.types,ui.Tree_Node,n,strings.to_string(b),"the node",refused[:],why[:]) {return false}
    }
    if slot {n.flags+={.Slot}}
    if is_instance {
        if !doc_params_apply(args,r,row,params,d,param_values[:]) {return false}
    } else if len(param_values)>0 {
        return doc_failed(reading,"this node takes no parameters")
    }
    return true
}

doc_value_of :: proc(d:^Document_Node,key:string) -> string {
    for k,i in d.keys {if k==key {return d.values[i]}}
    return ""
}

// An image: its texture by path and the fields of ui.Tree_Image.
doc_image_read :: proc(args:^Tree_Args,image:^ui.Tree_Image,text:string) -> bool {
    keys,values:=tree_object(args.reading,text,"image") or_return
    b:=strings.builder_make(args.reading.allocator)
    strings.write_byte(&b,'{')
    first:=true
    for key,i in keys {
        if key=="texture" {
            path,is_text:=doc_string(args.reading,values[i])
            if named:=args.reading.assets;is_text && named.resolve!=nil {
                id,problem:=named.resolve(named.user,path,".tex")
                if problem!="" {return doc_failed(args.reading,"image.texture: %s",problem)}
                image.texture=id
                continue
            }
            if is_text {
                if id,is_id:=serial.text_parse_asset_id(path);is_id {image.texture=id;continue}
                return doc_failed(args.reading,"image.texture: no project to read '%s' from",path)
            }
        }
        if !first {strings.write_byte(&b,',')}
        first=false
        fmt.sbprintf(&b,"%q:%s",key,values[i])
    }
    strings.write_byte(&b,'}')
    return tree_fields_read(args.reading,args.types,ui.Tree_Image,image,strings.to_string(b),"image")
}

// What plays on the triggers of a node, by the names of the animations.
doc_node_events_apply :: proc(args:^Tree_Args,r:^Records,n:^ui.Tree_Node,events:string) -> bool {
    reading:=args.reading
    keys,values:=tree_object(reading,events,"events") or_return
    at:=records_anim_set(r,n)
    if at<0 {reading_broke(reading,"the .ui holds no more sets of events");return false}
    set:=&r.anim_sets[at]
    names:=DOCUMENT_EVENTS
    slots:=(^[len(DOCUMENT_EVENTS)]ui.Anim)(set)
    for key,i in keys {
        name,read:=doc_string(reading,values[i])
        if !read {return doc_failed(reading,"events.%s must be the name of an animation",key)}
        played:ui.Anim
        if name!="" {
            for &a,row in r.anims {if serial.text_field(a.name[:])==name {played=ui.Anim(row+1);break}}
            if played==0 {return doc_failed(reading,"events.%s: the .ui has no animation named '%s'; animations declares it",key,name)}
        }
        slot:=-1
        for event,j in names {if event==key {slot=j}}
        if slot<0 {return doc_failed(reading,"events has no trigger '%s'; it has shown, hidden and clicked; what a node looks like hovered, pressed, focused or selected is a state of its style, with its transition",key)}
        slots[slot]=played
    }
    return true
}

// The values of the parameters a use gives, into its instance or the
// overrides of the nodes they go to; those it does not give are taken away.
doc_params_apply :: proc(args:^Tree_Args,r:^Records,row:int,params:[]ui.Tree_Param,d:^Document_Node,given:[]string) -> bool {
    reading:=args.reading
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
        value,is_text:=doc_string(reading,value_text)
        if !is_text {return doc_failed(reading,"%s must be a string",key)}
        p:ui.Tree_Param
        for &each in params {if serial.text_field(each.name[:])==key {p=each}}
        node:=serial.text_field(p.node[:])
        template:ui.Tree_Node
        source:^Records
        if node!="" {
            found:^ui.Tree_Node
            found,source=doc_widget_node(args,d.widget,node)
            if found==nil {return doc_failed(reading,"%s goes to node '%s', which its widget does not have",key,node)}
            template=found^
        }
        style:=0
        if p.field==.Style {
            style=doc_style_row(args,r,value)
            if style<0 {return doc_failed(reading,"%s: '%s' is no style of this file or of a file it uses",key,value)}
        }
        records_param_set(r,row,&p,value,style,source,template)
    }
    return true
}

// The node a path of names reaches in a widget as a use expands it, and the
// records its rows are of.
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
document_params_apply :: proc(args:^Tree_Args,r:^Records,text:string) -> bool {
    reading:=args.reading
    keys,values:=tree_object(reading,text,"params") or_return
    clear(&r.params)
    fields:=DOC_PARAM_FIELDS
    for param,i in keys {
        place:=fmt.tprintf("params.%s",param)
        if len(param)>=ui.TREE_NAME_CAPACITY || param=="" {return doc_failed(reading,"%s: give a name shorter than %d bytes",place,ui.TREE_NAME_CAPACITY)}
        target,is_text:=doc_string(reading,values[i])
        if !is_text {return doc_failed(reading,"%s must say where it goes: node.field, node.parameter of a use, or field for its root",place)}
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
                return doc_failed(reading,"%s: this file has no node '%s'; it has %s. To reach inside a use give its parameter: node.parameter",place,node,strings.join(names[:],", ",context.temp_allocator))
            }
            ui.tree_text_set(p.node[:],node)
            if !is_field {
                inner:=doc_lib_of(doc_libs_slice(args),r.components[n.component-1].widget) if n.kind==.Component && int(n.component)>0 && int(n.component)<=len(r.components) else nil
                found:=false
                names:=make([dynamic]string,context.temp_allocator)
                if inner!=nil {for &q in inner.linked.params {append(&names,serial.text_field(q.name[:]));found||=serial.text_field(q.name[:])==last}}
                if !found {return doc_failed(reading,"%s: '%s' is no field a parameter can give and no parameter of '%s' (it has %s)",place,last,node,strings.join(names[:],", ",context.temp_allocator))}
                ui.tree_text_set(p.param[:],last)
                is_field=true
            }
        }
        if !is_field {
            names:=make([dynamic]string,context.temp_allocator)
            for f in ui.Tree_Param_Field {append(&names,fields[f])}
            return doc_failed(reading,"%s: '%s' is no field a parameter can give: %s",place,last,strings.join(names[:],", ",context.temp_allocator))
        }
        p.field=field
        append(&r.params,p)
        if why:=records_param_valid_name(r,len(r.params)-1);why!="" {return doc_failed(reading,"%s: %s; give the parameter another",place,why)}
    }
    return true
}

// A file that declares parameters or a slot is a widget: one root, and the
// slot the last node of it.
document_widget_shape :: proc(reading:^Reading,r:^Records) -> bool {
    slot:=records_slot_row(r)
    if len(r.params)==0 && slot<0 {return true}
    roots:=0
    for &n in r.nodes {roots+=int(n.parent<0)}
    if roots!=1 {return doc_failed(reading,"nodes: a file with params or a slot is a widget: it has one root and has %d",roots)}
    if slot>=0 {
        if slot+records_subtree(r.nodes[:],slot)!=len(r.nodes)-1 {return doc_failed(reading,"nodes: a node after the slot; the slot is the last of its file")}
        for &n,i in r.nodes {if i!=slot && .Slot in n.flags {return doc_failed(reading,"nodes: two nodes are slots; a widget has one")}}
    }
    return true
}

// ---------------------------------------------------------------- paths

// Where a node of the records is in the document of the file, or of root.
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
// interface (bind_check). False after failing the reading with each it lacks:
// where, the key, the path, what the game does not have there and what it
// has. Not checked, because only a use knows them: the paths that start with
// @, what a List of one holds and a text with one in its braces; and nothing
// is while the editor has the types of no game.
document_paths_check :: proc(args:^Tree_Args,r:^Records,root:int) -> bool {
    info,a:=args.info,args.assets
    if info==nil || a.registry==nil {return true}
    data:=records_data(r)
    imports,imported:=tree_imports(a,data)
    if !imported {return true}
    types:Bind_Types
    defer bind_types_free(&types)
    found:[BIND_PROBLEMS]Bind_Problem
    count:=bind_check(&types,context.allocator,a,info,data,imports,imported,found[:])
    last:=root+records_subtree(r.nodes[:],root) if root>=0 else len(r.nodes)-1
    b:=strings.builder_make(args.reading.allocator)
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
    reading_failf(args.reading,"%s. Nothing changed. A path names a component or a storage of the game, then its fields; inside a List it starts at the element. ui.paths lists what a binding of a node takes, and what the code of the game declares is here after the game is built",strings.to_string(b))
    return false
}
