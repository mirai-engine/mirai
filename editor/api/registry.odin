package api

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

MAX_NAME :: 64
MAX_STRUCT_FIELDS :: 128

clone_text :: proc(allocator:runtime.Allocator,text:string) -> string {
    if text=="" {return ""}
    copy,_:=strings.clone(text,allocator)
    return copy
}
format_text :: proc(allocator:runtime.Allocator,format:string,args:..any) -> string {
    return fmt.aprintf(format,..args,allocator=allocator)
}

name_valid :: proc(name:string) -> bool {
    if len(name)==0 || len(name)>MAX_NAME {return false}
    for c,i in transmute([]u8)name {
        switch c {
        case 'a'..='z','A'..='Z': continue
        case '0'..='9','_','.','-': if i==0 {return false}
        case: return false
        }
    }
    return true
}

// Method names have dots; their MCP tools have underscores.
tool_equal :: proc(a,b:string) -> bool {
    if len(a)!=len(b) {return false}
    for i in 0..<len(a) {
        x,y:=a[i],b[i]
        if x=='.' {x='_'}
        if y=='.' {y='_'}
        if x!=y {return false}
    }
    return true
}
tool_find :: proc(s:^Server,name:string) -> ^Method {
    for &method in s.methods[:s.method_count] {
        if tool_equal(method.name,name) {return &method}
    }
    return nil
}

// Adds the params or the result type of a method to the schema: a struct. A
// result may also be serial.Json, when only the world knows its shape.
schema_register :: proc(s:^Server,info:^runtime.Type_Info,result:=false) -> (index:serial.Type_Index,ok:bool) {
    if info==nil {return serial.TYPE_NONE,true}
    root:=info
    first_type:=len(s.schema.types)
    index=serial.schema_add_type_info(&s.schema,root) or_return
    for type in s.schema.types[first_type:] {
        if type.kind==.Struct && type.count>MAX_STRUCT_FIELDS {
            delete(s.schema.error,s.schema.allocator)
            s.schema.error=format_text(s.schema.allocator,"%s has more than %d fields",type.name,MAX_STRUCT_FIELDS)
            return serial.TYPE_NONE,false
        }
    }
    kind:=s.schema.types[index].kind
    if kind!=.Struct && !(result && kind==.Json) {
        delete(s.schema.error,s.schema.allocator)
        s.schema.error=format_text(s.schema.allocator,"%v is not a struct",info.id)
        return serial.TYPE_NONE,false
    }
    return index,true
}

field_visible :: #force_inline proc(field:^serial.Field) -> bool {
    return .Transient not_in field.flags
}

method_register :: proc(s:^Server,desc:Method_Desc) -> Register_Error {
    if !name_valid(desc.name) {return .Invalid_Name}
    if desc.handler==nil {return .Invalid_Handler}
    if s.method_count>=len(s.methods) {s.stats.methods_refused+=1;return .Full}
    if method_find(s,desc.name)!=nil || tool_find(s,desc.name)!=nil {return .Duplicate}
    if desc.writes_result && desc.result==nil {return .Invalid_Type}
    method:=Method{name_hash=base.name_hash(desc.name),handler=desc.handler,user=desc.user,flags=desc.flags,writes_result=desc.writes_result}
    ok:bool
    if desc.params!=nil {method.params_id=desc.params.id}
    if desc.result!=nil {method.result_id=desc.result.id}
    method.params,ok=schema_register(s,desc.params)
    if !ok {return .Invalid_Type}
    method.clamps=type_clamps(s,method.params)
    method.result,ok=schema_register(s,desc.result,result=true)
    if !ok {return .Invalid_Type}
    limit:=u32(s.scratch.arena.data!=nil?len(s.scratch.arena.data)/4:0)
    if method.params!=serial.TYPE_NONE && s.schema.types[method.params].size>limit {return .Too_Large}
    if method.result!=serial.TYPE_NONE && !method.writes_result && s.schema.types[method.result].size>limit {return .Too_Large}
    if desc.defaults!=nil {
        if method.params==serial.TYPE_NONE {return .Invalid_Type}
        method.defaults=make([]u8,int(s.schema.types[method.params].size),s.allocator)
        mem.copy(raw_data(method.defaults),desc.defaults,len(method.defaults))
    }
    method.name=clone_text(s.allocator,desc.name)
    method.summary=clone_text(s.allocator,desc.summary)
    method.plugin=clone_text(s.allocator,desc.plugin)
    s.methods[s.method_count]=method
    s.method_count+=1
    return .None
}

// Whether a field of the type, at any depth, is tagged clamp.
@(private)
type_clamps :: proc(s:^Server,index:serial.Type_Index) -> bool {
    if index==serial.TYPE_NONE {return false}
    type:=s.schema.types[index]
    #partial switch type.kind {
    case .Array: return type_clamps(s,type.elem)
    case .Struct:
        for &f in s.schema.fields[type.first:][:type.count] {
            if .Clamp in f.hints || type_clamps(s,f.type) {return true}
        }
    }
    return false
}
