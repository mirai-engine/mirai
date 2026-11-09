package api

import "core:strconv"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// What a caller writes that the schema of a method can only mean one way,
// made into what the schema declares, before anything reads it: a key in the
// singular or the plural of a field, a single value where a list goes, a list
// of one where a single value goes, a number or a boolean as its text where
// only a string goes, and an enum name as base.name_find takes it. One rule
// over the JSON Schema of the params, so a method whose handler reads them by
// hand gets it too.

@(private="file")
SHAPE_DEPTH :: 16

@(private="file")
Shape_Field :: struct {name:string,node:^Shape_Node}

// A schema as this needs it. Unknown: it does not say which types it takes.
@(private="file")
Shape_Node :: struct {
    known,list,other,vector,text:bool, // list: takes an array; other: takes something else; vector: an array of a fixed length over one; text: takes a string and nothing else
    items:^Shape_Node,
    fields:[]Shape_Field,
    names:[]string,
}

@(private="file")
Shape_Edit :: struct {from,to:int,text:string}

@(private="file")
Shaper :: struct {
    checker:Checker,
    r:serial.Text_Reader,
    edits:[dynamic]Shape_Edit,
    names:bool, // enum names too: their reader does not take them as an agent writes them
}

@(private="file")
shape_node :: proc(schema:string,c:^Shaper,depth:int) -> ^Shape_Node {
    if schema=="" || depth>=SHAPE_DEPTH {return nil}
    members,_:=json_members(schema,c.checker.allocator)
    node:=new(Shape_Node,c.checker.allocator)
    if node==nil {return nil}
    for member in members {
        switch member.name {
        case "type":
            node.known=true
            if kind,single:=json_string(member.value);single {
                if kind=="array" {node.list=true} else {node.other=true}
                node.text=kind=="string"
                continue
            }
            kinds,_:=json_elements(member.value)
            for each in kinds {
                kind,_:=json_string(each)
                if kind=="array" {node.list=true} else {node.other=true}
            }
        case "enum":
            node.known,node.other=true,true
            names,_:=json_elements(member.value)
            node.names=make([]string,len(names),c.checker.allocator)
            for each,i in names {
                text,is_text:=json_string(each)
                if !is_text {node.names=nil;break}
                node.names[i]=strings.clone(text,c.checker.allocator)
            }
        case "minItems":
            least,_:=strconv.parse_int(member.value,10)
            node.vector=least>1
        case "items":
            node.items=shape_node(member.value,c,depth+1)
        case "properties":
            properties,_:=json_members(member.value,c.checker.allocator)
            node.fields=make([]Shape_Field,len(properties),c.checker.allocator)
            for each,i in properties {node.fields[i]={each.name,shape_node(each.value,c,depth+1)}}
        }
    }
    return node
}

// Whether a word is the plural of another: x and xs, xes, or y and ies.
@(private="file")
word_plural :: proc(plural,single:string) -> bool {
    if single=="" || !strings.has_prefix(plural,single[:len(single)-1]) {return false}
    rest:=plural[len(single)-1:]
    last:=single[len(single)-1]
    return last=='y' && rest=="ies" || len(rest)>1 && rest[0]==last && (rest[1:]=="s" || rest[1:]=="es")
}

// Whether a key can only be meant for a field: its singular or plural, or an
// id for a field that names an entity, which takes it.
@(private="file")
key_means :: proc(key,field:string) -> bool {
    if word_plural(key,field) || word_plural(field,key) {return true}
    return (key=="id" || key=="ids") && (field=="entity" || field=="entities")
}

// The field a key that is not one means, which the object does not give
// itself; nil when that is none or several.
@(private="file")
shape_field_meant :: proc(c:^Shaper,node:^Shape_Node,key:string,object:int) -> ^Shape_Field {
    meant:^Shape_Field
    for &field in node.fields {
        if !key_means(key,field.name) {continue}
        if meant!=nil {return nil}
        meant=&field
    }
    if meant==nil {return nil}
    members,_:=json_members(c.r.text[object:],c.checker.allocator)
    for member in members {
        if member.name==meant.name {return nil}
    }
    return meant
}

@(private="file")
shape_object :: proc(c:^Shaper,node:^Shape_Node) -> bool {
    r:=&c.r
    serial.text_peek(r)
    object:=r.offset
    if !serial.text_accept(r,'{') {return false}
    if serial.text_accept(r,'}') {return true}
    for {
        serial.text_peek(r)
        at:=r.offset
        key:=serial.text_string(r) or_return
        end:=r.offset
        field:^Shape_Field
        for &each in node.fields {
            if each.name==key {field=&each;break}
        }
        if field==nil {
            field=shape_field_meant(c,node,key,object)
            if field!=nil {append(&c.edits,Shape_Edit{at,end,serial.text_quote(field.name,c.checker.allocator)})}
        }
        serial.text_expect(r,':') or_return
        if field!=nil {
            mark:=c.checker.path_len
            path_name(&c.checker,field.name)
            shape_value(c,field.node) or_return
            c.checker.path_len=mark
        } else {
            serial.text_skip(r) or_return
        }
        if serial.text_accept(r,',') {continue}
        return serial.text_expect(r,'}')
    }
}

@(private="file")
shape_list :: proc(c:^Shaper,node:^Shape_Node) -> bool {
    r:=&c.r
    if node.items==nil {return serial.text_skip(r)}
    if !serial.text_accept(r,'[') {return false}
    if serial.text_accept(r,']') {return true}
    for i:=0;;i+=1 {
        mark:=c.checker.path_len
        path_index(&c.checker,i)
        shape_value(c,node.items) or_return
        c.checker.path_len=mark
        if serial.text_accept(r,',') {continue}
        return serial.text_expect(r,']')
    }
}

// A list given for a single value: its one element is that value.
@(private="file")
shape_unwrap :: proc(c:^Shaper,node:^Shape_Node) -> bool {
    r:=&c.r
    at:=r.offset
    if !serial.text_accept(r,'[') {return false}
    if serial.text_accept(r,']') {return true}
    inner:=serial.text_peek(r)
    first:=r.offset
    append(&c.edits,Shape_Edit{at,first,""})
    if inner=='[' {serial.text_skip(r) or_return} else {shape_value(c,node) or_return}
    end:=r.offset
    if serial.text_accept(r,',') {return check_fail(&c.checker,"takes one value, not a list of several")}
    serial.text_expect(r,']') or_return
    append(&c.edits,Shape_Edit{end,r.offset,""})
    return true
}

@(private="file")
shape_name :: proc(c:^Shaper,node:^Shape_Node) -> bool {
    r:=&c.r
    at:=r.offset
    name:=serial.text_string(r) or_return
    index,_:=base.name_find(name,node.names)
    if index<0 {return check_fail(&c.checker,"%s",base.name_problem(name,"one of its names",node.names,c.checker.allocator))}
    if node.names[index]!=name {append(&c.edits,Shape_Edit{at,r.offset,serial.text_quote(node.names[index],c.checker.allocator)})}
    return true
}

@(private="file")
shape_value :: proc(c:^Shaper,node:^Shape_Node) -> bool {
    r:=&c.r
    kind:=serial.text_peek(r)
    if node==nil {return serial.text_skip(r)}
    switch {
    case kind=='[' && node.known && !node.list:
        return shape_unwrap(c,node)
    case kind!='[' && kind!='n' && node.list && !node.other && !node.vector:
        at:=r.offset
        append(&c.edits,Shape_Edit{at,at,"["})
        shape_value(c,node.items) or_return
        append(&c.edits,Shape_Edit{r.offset,r.offset,"]"})
        return true
    case kind=='[':
        return shape_list(c,node)
    case kind=='{' && len(node.fields)>0:
        return shape_object(c,node)
    case kind=='"' && len(node.names)>0 && c.names:
        return shape_name(c,node)
    case node.text && len(node.names)==0 && (kind=='t' || kind=='f' || kind=='-' || kind>='0' && kind<='9'):
        at:=r.offset
        serial.text_skip(r) or_return
        append(&c.edits,Shape_Edit{at,r.offset,serial.text_quote(r.text[at:r.offset],c.checker.allocator)})
        return true
    }
    return serial.text_skip(r)
}

// The JSON Schema of the params of a method: the one written by hand, or that
// of its type, in the scratch of the server.
params_schema_text :: proc(s:^Server,method:^Method) -> string {
    if method.params==serial.TYPE_NONE {return method.params_schema}
    w:serial.Writer
    serial.writer_init(&w,4096,base.arena_allocator(&s.scratch))
    method_schema_write(&w,s,method,false)
    return w.overflow>0?"":string(serial.writer_bytes(&w))
}

// The params made into what schema declares; the same text when nothing
// changes or the schema says nothing of them. problem: what they ask that
// cannot be made valid. Text that is not JSON stays for its reader to report.
params_shape :: proc(s:^Server,schema,params:string,names:=true) -> (shaped,problem:string) {
    shaped=params
    if schema=="" || params=="{}" {return}
    allocator:=base.arena_allocator(&s.scratch)
    c:=Shaper{checker={allocator=allocator},edits=make([dynamic]Shape_Edit,allocator),names=names}
    root:=shape_node(schema,&c,0)
    if root==nil || len(root.fields)==0 {return}
    serial.text_reader_init(&c.r,params,allocator)
    if serial.text_peek(&c.r)!='{' || !shape_object(&c,root) {return params,c.checker.message}
    if len(c.edits)==0 {return}
    b:=strings.builder_make(allocator)
    at:=0
    for edit in c.edits {
        strings.write_string(&b,params[at:edit.from])
        strings.write_string(&b,edit.text)
        at=edit.to
    }
    strings.write_string(&b,params[at:])
    return strings.to_string(b),""
}

// What the params of a method are, by name and type, with an example, for the
// data of an error; "" when it has no schema or the answer could not take it.
// Long ones keep their first fields and their example.
params_usage :: proc(s:^Server,method:^Method) -> string {
    if s.out.count+2*USAGE_BYTES>len(s.out.data) {return ""}
    schema:=params_schema_text(s,method)
    if json_member(schema,"properties")=="" {return ""}
    allocator:=base.arena_allocator(&s.scratch)
    fields:=strings.builder_make(allocator)
    example:=strings.builder_make(allocator)
    describe_fields(&fields,schema,"",false,0,brief=true)
    describe_example(&example,method.name,schema)
    text:=strings.to_string(fields)
    room:=USAGE_BYTES-strings.builder_len(example)-len(USAGE_CUT)
    if len(text)>room {
        text=text[:max(strings.last_index_byte(text[:max(room,0)],'\n')+1,0)]
        text=strings.concatenate({text,USAGE_CUT},allocator)
    }
    return format_text(allocator,`{{"usage":%s}}`,serial.text_quote(strings.concatenate({text,strings.to_string(example)},allocator),allocator))
}

// The most an invalid-params error carries of what its method takes.
USAGE_BYTES :: 8192
@(private="file") USAGE_CUT :: "    ... mirai rpc describe gives the rest\n"
