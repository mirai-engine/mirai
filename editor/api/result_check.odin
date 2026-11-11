package api

import "core:fmt"
import "core:strings"
import "mirai:std/serial"

// Where the JSON a handler wrote leaves the shape of its result type, or ""
// when it keeps it: a key the type lacks, a required field missing, or a value
// whose JSON type, length or name its field does not take.
result_mismatch :: proc(T:typeid,text:string) -> string {
    context.allocator=context.temp_allocator
    server:Server
    server.allocator=context.temp_allocator
    serial.schema_init(&server.schema,context.temp_allocator)
    server.schema.unsized=true
    index,ok:=schema_register(&server,type_info_of(T),result=true)
    if !ok {return "the type does not register"}
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    if problem:=result_value(&server,&r,index,nil,"result");problem!="" {return problem}
    return "" if serial.text_end(&r) else "result: text after the value"
}

@(private="file")
result_value :: proc(s:^Server,r:^serial.Text_Reader,index:serial.Type_Index,field:^serial.Field,at:string,nonempty:=false) -> string {
    sc:=&s.schema
    type:=sc.types[index]
    next:=serial.text_peek(r)
    number:=next=='-' || next>='0' && next<='9'
    hex :: proc(text:string) -> bool {
        for c in text {if !(c>='0' && c<='9' || c>='a' && c<='f' || c>='A' && c<='F') {return false}}
        return true
    }
    switch type.kind {
    case .Bool:
        if serial.text_keyword(r,"true") || serial.text_keyword(r,"false") {return ""}
        return fmt.tprintf("%s is not a boolean",at)
    case .Int,.Uint:
        switch {
        case type.named==.Bits: if next!='[' {return fmt.tprintf("%s is not a list of names",at)}
        case type.named==.Values: if next!='"' && !number {return fmt.tprintf("%s is not a name",at)}
        case type.size==16: if next!='"' {return fmt.tprintf("%s is not a string",at)}
        case: if !number {return fmt.tprintf("%s is not an integer",at)}
        }
    case .Float:
        if !number {return fmt.tprintf("%s is not a number",at)}
    case .Bit_Set:
        if next!='[' {return fmt.tprintf("%s is not a list of names",at)}
    case .Enum:
        name,ok:=serial.text_string(r)
        if !ok {return fmt.tprintf("%s is not a string",at)}
        for choice in sc.choices[type.first:][:type.count] {if choice.name==name {return ""}}
        return fmt.tprintf("%s is %s, which is none of its names",at,name)
    case .Entity,.Entity_Id:
        text,ok:=serial.text_string(r)
        digits:=strings.trim_prefix(text,"0x")
        if !ok || len(digits)<1 || len(digits)>16 || !hex(digits) {return fmt.tprintf("%s is not an entity id",at)}
        return ""
    case .Asset:
        text,ok:=serial.text_string(r)
        if !ok || len(text)!=32 || !hex(text) {return fmt.tprintf("%s is not an asset id",at)}
        return ""
    case .Struct:
        if !serial.text_accept(r,'{') {return fmt.tprintf("%s is not an object",at)}
        fields:=sc.fields[type.first:][:type.count]
        seen:=make([]bool,len(fields),context.temp_allocator)
        if !serial.text_accept(r,'}') {
            for {
                key,ok:=serial.text_string(r)
                if !ok || !serial.text_expect(r,':') {return fmt.tprintf("%s is not JSON",at)}
                found:=-1
                for &f,i in fields {if f.name==key && field_visible(&f) {found=i;break}}
                if found<0 {return fmt.tprintf("%s has %s, which its type lacks",at,key)}
                seen[found]=true
                inner:=fmt.tprintf("%s.%s",at,key)
                if problem:=result_value(s,r,fields[found].type,&fields[found],inner);problem!="" {return problem}
                if serial.text_accept(r,',') {continue}
                if !serial.text_expect(r,'}') {return fmt.tprintf("%s is not JSON",at)}
                break
            }
        }
        for &f,i in fields {
            if field_visible(&f) && !seen[i] && .Optional not_in f.hints {return fmt.tprintf("%s lacks %s",at,f.name)}
        }
        return ""
    case .String:
        if _,ok:=serial.text_string(r);!ok {return fmt.tprintf("%s is not a string",at)}
        return ""
    case .Json:
    case .Array,.Slice:
        list:=type.kind==.Slice
        text_field:=field!=nil && .Text in field.flags
        if !list && text_field && serial.type_is_bytes(sc,index) {
            text,ok:=serial.text_string(r)
            if !ok {return fmt.tprintf("%s is not a string",at)}
            if len(text)>int(type.count) {return fmt.tprintf("%s holds %d bytes; its field %d",at,len(text),type.count)}
            if nonempty && text=="" {return fmt.tprintf("%s is empty",at)}
            return ""
        }
        if !serial.text_accept(r,'[') {return fmt.tprintf("%s is not a list",at)}
        count:=0
        if !serial.text_accept(r,']') {
            for {
                inner:=fmt.tprintf("%s[%d]",at,count)
                if problem:=result_value(s,r,type.elem,field,inner,text_field && !list);problem!="" {return problem}
                count+=1
                if serial.text_accept(r,',') {continue}
                if !serial.text_expect(r,']') {return fmt.tprintf("%s is not JSON",at)}
                break
            }
        }
        elem:=sc.types[type.elem].kind
        if !list && count>int(type.count) {return fmt.tprintf("%s has %d elements; at most %d",at,count,type.count)}
        if !list && (elem==.Float || elem==.Int || elem==.Uint) && !text_field && count!=int(type.count) {return fmt.tprintf("%s has %d numbers; not %d",at,count,type.count)}
        return ""
    }
    if !serial.text_skip(r) {return fmt.tprintf("%s is not JSON",at)}
    return ""
}
