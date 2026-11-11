package api

import "core:fmt"
import "core:strconv"
import "core:strings"
import "mirai:std/serial"

// A JSON Schema of the params or the result of a method as a few lines, what
// `mirai rpc describe` prints and an invalid-params error carries.

// The params of an object schema, a line per field, in the text the methods describe them.
describe_params :: proc(b:^strings.Builder,params:string) {
    properties:=json_member(params,"properties")
    switch {
    case properties=="": strings.write_string(b,"  params: no schema; the summary says which it reads, if any\n")
    case !describe_params_own(properties): strings.write_string(b,"  params: none\n")
    case:
        strings.write_string(b,"  params:\n")
        describe_fields(b,params,"",false,0)
    }
}

// The line with valid params of a method: key=value arguments, and JSON only
// when they cannot write them.
describe_example :: proc(b:^strings.Builder,method,params:string) {
    example:=strings.builder_make(context.temp_allocator)
    describe_value(&example,params,0)
    arguments:=strings.builder_make(context.temp_allocator)
    if describe_arguments(&arguments,strings.to_string(example),"") {
        fmt.sbprintf(b,"  example: mirai rpc %s%s\n",method,strings.to_string(arguments))
    } else {
        fmt.sbprintf(b,"  example: mirai rpc %s '%s'\n",method,strings.to_string(example))
    }
}

// Writes a JSON object of an example as key=value arguments, a space before
// each one, with dots for the objects inside; false when a value needs the
// JSON form: a list with texts, or a text a shell or key=value would change.
@(private="file")
describe_arguments :: proc(b:^strings.Builder,object,prefix:string) -> bool {
    members,_:=json_members(object)
    for member in members {
        path:=prefix==""?member.name:fmt.tprintf("%s.%s",prefix,member.name)
        switch {
        case member.value[0]=='{':
            if !describe_arguments(b,member.value,path) {return false}
            continue
        case member.value[0]=='"':
            text,_:=json_string(member.value)
            if !describe_plain(text) {return false}
            fmt.sbprintf(b," %s=%s",path,text)
            continue
        case member.value[0]=='[' && strings.contains_any(member.value,"\" "):
            return false
        }
        fmt.sbprintf(b," %s=%s",path,member.value)
    }
    return true
}

// Whether a text reaches its field as it is when written bare after key=.
@(private="file")
describe_plain :: proc(text:string) -> bool {
    if text=="" || text=="null" || text[0]=='{' || text[0]=='[' {return false}
    return !strings.contains_any(text," \t\n\"'`$&|;<>()*?!#~\\")
}

// Whether the properties of a schema of params have some besides those every method takes.
@(private="file")
describe_params_own :: proc(properties:string) -> bool {
    members,_:=json_members(properties)
    for member in members {
        if !param_reserved(member.name) {return true}
    }
    return false
}

// A line per field of an object schema, after it those of an object inside,
// with their path (a.b, or a[].b for the objects of an array).
describe_fields :: proc(b:^strings.Builder,schema,prefix:string,result:bool,depth:int,brief:=false) {
    properties,_:=json_members(json_member(schema,"properties"))
    required,_:=json_elements(json_member(schema,"required"))
    for property in properties {
        if !result && param_reserved(property.name) {continue}
        path:=prefix==""?property.name:fmt.tprintf("%s.%s",prefix,property.name)
        if !brief {strings.write_string(b,"    ")}
        fmt.sbprintf(b,"%s: %s",path,describe_type(property.value))
        if !result {
            needed:=false
            for field in required {
                if text,_:=json_string(field);text==property.name {needed=true}
            }
            if needed {
                strings.write_string(b,", required")
            } else if brief {
            } else if default:=json_member(property.value,"default");default!="" {
                fmt.sbprintf(b,", default %s",json_compact(default))
            } else if each:=json_member(json_member(property.value,"items"),"default");each!="" {
                fmt.sbprintf(b,", default %s each",json_compact(each))
            }
        }
        if description,_:=json_string(json_member(property.value,"description"));description!="" && !brief {fmt.sbprintf(b,". %s",description)}
        strings.write_byte(b,'\n')
        if brief || depth>=4 {continue}
        if json_member(property.value,"properties")!="" {
            describe_fields(b,property.value,path,result,depth+1,brief)
        } else if items:=json_member(property.value,"items");json_member(items,"properties")!="" {
            describe_fields(b,items,fmt.tprintf("%s[]",path),result,depth+1,brief)
        }
    }
}

// The type of a JSON Schema in a few words, with its unit: integer 0..3600,
// number[3] m, string up to 64, list of A|B, entity id.
describe_type :: proc(schema:string) -> string {
    text:=describe_words(schema)
    unit,_:=json_string(json_member(schema,"x-unit"))
    return unit==""?text:fmt.tprintf("%s %s",text,unit)
}

@(private="file")
describe_words :: proc(schema:string) -> string {
    if names,_:=json_elements(json_member(schema,"enum"));len(names)>0 {return describe_names(names[:])}
    if constant:=json_member(schema,"const");constant!="" {return json_compact(constant)}
    type:=json_member(schema,"type")
    kind,_:=json_string(type)
    switch kind {
    case "integer","number":
        lo,hi:=json_member(schema,"minimum"),json_member(schema,"maximum")
        switch {
        case kind=="integer" && describe_integer_natural(lo,hi): return kind
        case lo!="" && hi!="": return fmt.tprintf("%s %s..%s",kind,lo,hi)
        case lo!="": return fmt.tprintf("%s >= %s",kind,lo)
        case hi!="": return fmt.tprintf("%s <= %s",kind,hi)
        }
        return kind
    case "string":
        if asset,is_asset:=json_string(json_member(schema,"x-asset"));is_asset {
            return asset=="any"?"asset path or id":fmt.tprintf("asset path or id (%s)",asset)
        }
        if json_member(schema,"x-entity")!="" {return "entity name, path or id"}
        pattern,_:=json_string(json_member(schema,"pattern"))
        switch pattern {
        case PATTERN_ENTITY_ID: return "entity id (up to 16 hex)"
        case PATTERN_WIDE:      return "128-bit integer (0x and 32 hex)"
        }
        if size:=json_member(schema,"maxLength");size!="" {return fmt.tprintf("string up to %s",size)}
        return "string"
    case "boolean","null":
        return kind
    case "object":
        return "object"
    case "array":
        items:=json_member(schema,"items")
        item:=items!=""?describe_type(items):"JSON"
        lo,hi:=json_member(schema,"minItems"),json_member(schema,"maxItems")
        switch {
        case lo!="" && lo==hi: return strings.contains(item," ")?fmt.tprintf("(%s)[%s]",item,lo):fmt.tprintf("%s[%s]",item,lo)
        case hi!="": return fmt.tprintf("list of %s, up to %s",item,hi)
        }
        return fmt.tprintf("list of %s",item)
    }
    if kinds,is_list:=json_elements(type);is_list && len(kinds)>0 {return describe_names(kinds[:])}
    return "JSON"
}

// Names of an enum or of the types of a schema as A|B|C; past 16, how many there are.
@(private="file")
describe_names :: proc(values:[]string) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for value in values[:min(len(values),16)] {
        text,is_text:=json_string(value)
        append(&names,is_text?text:json_compact(value))
    }
    joined:=strings.join(names[:],"|",context.temp_allocator)
    return len(values)>16?fmt.tprintf("%s|... (%d in all)",joined,len(values)):joined
}

// Whether lo..hi is the whole range of an integer type, which says nothing.
@(private="file")
describe_integer_natural :: proc(lo,hi:string) -> bool {
    ranges:=[?][2]string{
        {"-128","127"},{"0","255"},{"-32768","32767"},{"0","65535"},
        {"-2147483648","2147483647"},{"0","4294967295"},
        {"-9223372036854775808","9223372036854775807"},{"0","18446744073709551615"},
    }
    for range in ranges {
        if range[0]==lo && range[1]==hi {return true}
    }
    return false
}

// Valid JSON for a schema: its default, its first name, or the least value
// of its type its bounds allow; for an object, its required fields.
@(private="file")
describe_value :: proc(b:^strings.Builder,schema:string,depth:int) {
    if default:=json_member(schema,"default");default!="" {strings.write_string(b,json_compact(default));return}
    if names,_:=json_elements(json_member(schema,"enum"));len(names)>0 {strings.write_string(b,json_compact(names[0]));return}
    if constant:=json_member(schema,"const");constant!="" {strings.write_string(b,json_compact(constant));return}
    kind,_:=json_string(json_member(schema,"type"))
    switch kind {
    case "boolean": strings.write_string(b,"false")
    case "null":    strings.write_string(b,"null")
    case "integer","number":
        lo,hi:=json_member(schema,"minimum"),json_member(schema,"maximum")
        value:="0"
        if low,valid:=strconv.parse_f64(lo);valid && low>0 {
            value=lo
        } else if high,high_valid:=strconv.parse_f64(hi);high_valid && high<0 {
            value=hi
        }
        strings.write_string(b,value)
    case "string":
        if json_member(schema,"x-entity")!="" {strings.write_string(b,`"Floor"`);break}
        pattern,_:=json_string(json_member(schema,"pattern"))
        switch pattern {
        case PATTERN_ENTITY_ID: strings.write_string(b,`"0000000000000001"`)
        case PATTERN_WIDE:      strings.write_string(b,`"0x00000000000000000000000000000000"`)
        case:                   strings.write_string(b,`"x"`)
        }
    case "array":
        count,_:=strconv.parse_int(json_member(schema,"minItems"),10)
        strings.write_byte(b,'[')
        for i in 0..<count {
            if i>0 {strings.write_byte(b,',')}
            describe_value(b,json_member(schema,"items"),depth+1)
        }
        strings.write_byte(b,']')
    case:
        strings.write_byte(b,'{')
        properties,_:=json_members(json_member(schema,"properties"))
        required,_:=json_elements(json_member(schema,"required"))
        first:=true
        for field in required {
            if depth>=8 {break}
            name,_:=json_string(field)
            for property in properties {
                if property.name!=name {continue}
                if !first {strings.write_byte(b,',')}
                first=false
                fmt.sbprintf(b,"%s:",serial.text_quote(name))
                describe_value(b,property.value,depth+1)
            }
        }
        strings.write_byte(b,'}')
    }
}
