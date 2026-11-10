package api

import "core:math"
import "core:fmt"
import "core:slice"
import "mirai:std/serial"

// JSON Schema (2020-12) of a type of the registry. Types are written inline:
// plain data has no cycles. Integers carry the range of their type narrowed by
// the field's min and max; enums are their member names; bit sets are lists of
// names; ids are strings, and a param that names an entity is a string that
// says with x-entity how it names the entity; an asset is a string, its id or
// its path, with x-asset the extensions its field holds; a text field is a
// string of at most N bytes; an
// array of numbers has exactly its length and any other array at most that.
// An array has no default of its own: its items carry the default of an
// element when every element has the same one. A list (an array tagged list)
// has no bounds on its length and its texts may be empty, and a field tagged
// any takes any JSON value.

@(private)
raw :: #force_inline proc(w:^serial.Writer,text:string) {serial.text_write_raw(w,text)}

@(private)
entry :: proc(w:^serial.Writer,count:^int,key:string) {
    if count^>0 {raw(w,",")}
    count^+=1
    serial.text_write_string(w,key)
    raw(w,":")
}

@(private)
write_bound :: proc(w:^serial.Writer,count:^int,key:string,value:i128) {
    entry(w,count,key)
    if value<0 {serial.text_write_int(w,i64(value))} else {serial.text_write_uint(w,u64(value))}
}

@(private)
write_f64 :: proc(w:^serial.Writer,value:f64) {serial.text_write_float(w,transmute(u64)value,8)}

@(private)
integer_bounds :: proc(type:serial.Type,field:^serial.Field) -> (lo,hi:i128) {
    bits:=uint(type.size)*8
    if type.kind==.Int {
        lo,hi=-(i128(1)<<(bits-1)),(i128(1)<<(bits-1))-1
    } else {
        lo,hi=0,(i128(1)<<bits)-1
    }
    if field!=nil {
        if field.has_min && field.min>f64(lo) && field.min<=f64(hi) {lo=i128(math.ceil(field.min))}
        if field.has_max && field.max<f64(hi) && field.max>=f64(lo) {hi=i128(math.floor(field.max))}
    }
    return
}

@(private)
all_zero :: proc(bytes:[]u8) -> bool {
    for b in bytes {if b!=0 {return false}}
    return true
}

@(private)
write_decor :: proc(w:^serial.Writer,count:^int,field:^serial.Field) {
    if field.label!="" {entry(w,count,"description");serial.text_write_string(w,field.label)}
    if field.unit!="" {entry(w,count,"x-unit");serial.text_write_string(w,field.unit)}
    if field.required_component!=0 {entry(w,count,"x-required-component");serial.text_write_string(w,fmt.tprintf("0x%016x",field.required_component))}
}

// The value of every element of an array, when they all hold the same one.
@(private)
array_element :: proc(sc:^serial.Schema,type:serial.Type,image:[]u8) -> []u8 {
    if image==nil || type.count==0 {return nil}
    size:=int(sc.types[type.elem].size)
    first:=image[:size]
    for i in 1..<int(type.count) {
        if !slice.equal(image[i*size:][:size],first) {return nil}
    }
    return first
}

// field: the field that holds the value; it gives the bounds, the text flag
// and, when decor is set, the description. image: the value of a struct or
// an array as the defaults hold it. default: the value to show as the
// default of an optional field. list: an array of any length. params: the
// value is of the params of a method.
schema_write :: proc(w:^serial.Writer,s:^Server,index:serial.Type_Index,field:^serial.Field=nil,image:[]u8=nil,decor:=false,default:[]u8=nil,list:=false,params:=false) {
    sc:=&s.schema
    type:=sc.types[index]
    count:=0
    shown:=default
    raw(w,"{")
    switch type.kind {
    case .Bool:
        entry(w,&count,"type");raw(w,`"boolean"`)
    case .Int,.Uint:
        if type.named!=.None {
            items:=sc.choices[type.first:][:type.count]
            if type.named==.Bits {
                entry(w,&count,"type");raw(w,`"array"`)
                entry(w,&count,"items");raw(w,`{"type":["string","integer"],"enum":`);write_names(w,items);raw(w,"}")
            } else {
                entry(w,&count,"type");raw(w,`["string","integer"]`)
                entry(w,&count,"enum");write_names(w,items)
            }
        } else if type.size==16 {
            entry(w,&count,"type");raw(w,`"string"`)
            entry(w,&count,"pattern");raw(w,`"^0x[0-9a-fA-F]{32}$"`)
        } else {
            lo,hi:=integer_bounds(type,field)
            entry(w,&count,"type");raw(w,`"integer"`)
            write_bound(w,&count,"minimum",lo)
            write_bound(w,&count,"maximum",hi)
        }
    case .Float:
        entry(w,&count,"type");raw(w,`"number"`)
        if field!=nil && field.has_min {entry(w,&count,"minimum");write_f64(w,field.min)}
        if field!=nil && field.has_max {entry(w,&count,"maximum");write_f64(w,field.max)}
    case .Enum:
        entry(w,&count,"type");raw(w,`"string"`)
        entry(w,&count,"enum");write_names(w,sc.choices[type.first:][:type.count])
    case .Bit_Set:
        entry(w,&count,"type");raw(w,`"array"`)
        entry(w,&count,"items")
        raw(w,`{"type":"string","enum":`);write_names(w,sc.choices[type.first:][:type.count]);raw(w,"}")
        entry(w,&count,"uniqueItems");raw(w,"true")
    case .Entity,.Entity_Id:
        entry(w,&count,"type");raw(w,`"string"`)
        entry(w,&count,"pattern");raw(w,`"^(0x)?[0-9a-fA-F]{1,16}$"`)
    case .Asset:
        entry(w,&count,"type");raw(w,`"string"`)
        entry(w,&count,"x-asset");serial.text_write_string(w,field!=nil && field.asset_kinds!=""?field.asset_kinds:"any")
    case .Struct:
        entry(w,&count,"type");raw(w,`"object"`)
        fields:=sc.fields[type.first:][:type.count]
        entry(w,&count,"properties");raw(w,"{")
        emitted:=0
        for &f in fields {
            if !field_visible(&f) {continue}
            if emitted>0 {raw(w,",")}
            emitted+=1
            serial.text_write_string(w,f.name);raw(w,":")
            tags:=f.hints
            if .Any in tags {
                described:=0
                raw(w,"{");write_decor(w,&described,&f);raw(w,"}")
                continue
            }
            part:[]u8
            if image!=nil {part=image[f.offset:][:sc.types[f.type].size]}
            value:[]u8
            if part!=nil && .Optional in tags && sc.types[f.type].kind!=.Struct && !all_zero(part) {value=part}
            schema_write(w,s,f.type,&f,part,true,value,.List in tags,params)
        }
        raw(w,"}")
        required:=0
        for &f in fields {
            if !field_visible(&f) || .Optional in f.hints {continue}
            if required==0 {entry(w,&count,"required");raw(w,"[")} else {raw(w,",")}
            required+=1
            serial.text_write_string(w,f.name)
        }
        if required>0 {raw(w,"]")}
        entry(w,&count,"additionalProperties");raw(w,"false")
    case .Array:
        if decor && field!=nil && .Text in field.flags && serial.type_is_bytes(sc,index) {
            entry(w,&count,"type");raw(w,`"string"`)
            if .Entity in field.hints {entry(w,&count,"x-entity");raw(w,ENTITY_NAMES)}
            entry(w,&count,"maxLength");serial.text_write_uint(w,u64(type.count))
        } else if field!=nil && .Text in field.flags && serial.type_is_texts(sc,index) {
            shown=nil
            entry(w,&count,"type");raw(w,`"array"`)
            entry(w,&count,"items");raw(w,list?`{"type":"string","maxLength":`:`{"type":"string","minLength":1,"maxLength":`);serial.text_write_uint(w,u64(sc.types[type.elem].count));raw(w,"}")
            if !list {entry(w,&count,"maxItems");serial.text_write_uint(w,u64(type.count))}
        } else {
            shown=nil
            elem:=sc.types[type.elem]
            value:=array_element(sc,type,image)
            element_default:[]u8
            if default!=nil && elem.kind!=.Struct && value!=nil && !all_zero(value) {element_default=value}
            entry(w,&count,"type");raw(w,`"array"`)
            entry(w,&count,"items");schema_write(w,s,type.elem,field,value,false,element_default,false,params)
            if !list {
                if elem.kind==.Float || elem.kind==.Int || elem.kind==.Uint {
                    entry(w,&count,"minItems");serial.text_write_uint(w,u64(type.count))
                }
                entry(w,&count,"maxItems");serial.text_write_uint(w,u64(type.count))
            }
        }
    }
    if decor && field!=nil {write_decor(w,&count,field)}
    if shown!=nil {
        entry(w,&count,"default")
        serial.text_write(w,&s.schema,index,shown,.Line)
    }
    raw(w,"}")
}

@(private)
write_names :: proc(w:^serial.Writer,choices:[]serial.Choice) {
    raw(w,"[")
    for choice,i in choices {
        if i>0 {raw(w,",")}
        serial.text_write_string(w,choice.name)
    }
    raw(w,"]")
}

// The schema of the params or result of a method; free-form JSON when there is no type.
method_schema_write :: proc(w:^serial.Writer,s:^Server,method:^Method,result:bool) {
    start:=w.count
    defer if !result {
        properties_add(w,start,.Read_Only in method.flags?SELECT_SCHEMA+","+WAIT_SCHEMA:SELECT_SCHEMA)
    } else if method.clamps {
        properties_add(w,start,CLAMPED_SCHEMA)
    }
    index:=result?method.result:method.params
    if index==serial.TYPE_NONE {
        written:=result?method.result_schema:method.params_schema
        raw(w,written!=""?written:result?"{}":`{"type":"object"}`)
        return
    }
    schema_write(w,s,index,nil,result?nil:method.defaults,params=!result)
}

// x-entity says of a param what it takes; a schema written by hand spreads
// ENTITY_SCHEMA into the object of the param.
@(private="file") ENTITY_NAMES :: `"a name, a path Parent/Child or an id"`
ENTITY_SCHEMA :: `"type":"string","x-entity":` + ENTITY_NAMES

// The key of a result that says which params took their maximum.
@(private) CLAMPED_SCHEMA :: `"_clamped":{"type":"object","description":"The params past their maximum by name: what was asked and what was used"}`

// Adds members to the properties of the object schema written from start. One
// without properties takes anything already.
@(private)
properties_add :: proc(w:^serial.Writer,start:int,members:string) {
    if w.overflow>0 {return}
    r:serial.Text_Reader
    serial.text_reader_init(&r,string(w.data[start:w.count]),context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    if !serial.text_accept(&r,'{') {return}
    at:=-1
    for at<0 && !serial.text_accept(&r,'}') {
        key,ok:=serial.text_string(&r)
        if !ok || !serial.text_expect(&r,':') {return}
        serial.text_peek(&r)
        if key=="properties" {at=start+r.offset+1}
        if !serial.text_skip(&r) {return}
        if !serial.text_accept(&r,',') {break}
    }
    if at<0 {return}
    end:=w.count
    empty:=w.data[at]=='}'
    raw(w,members)
    if !empty {raw(w,",")}
    if w.overflow>0 {return}
    slice.rotate_left(w.data[at:w.count],end-at)
}
