package asset

import "base:runtime"
import "mirai:std/serial"

// The types a program reads and writes as records, described once. Every
// load and save compares or converts against this schema, so a kind adds its
// types when the program starts and shares the context from then on. It is
// not thread-safe while a type is being added; after that it is only read.
Types :: struct {
    schema:serial.Schema,
    hashes:[dynamic]u64,             // layout hash of every type
    transient:[dynamic]bool,         // types with a transient field somewhere inside
    layouts:[dynamic]^serial.Layout, // how to save each type, built when first needed
    allocator:runtime.Allocator,
    error:Error,
}

types_init :: proc(types:^Types,allocator:=context.allocator) {
    types^={allocator=allocator}
    serial.schema_init(&types.schema,allocator)
    types.hashes=make([dynamic]u64,allocator)
    types.transient=make([dynamic]bool,allocator)
    types.layouts=make([dynamic]^serial.Layout,allocator)
}

types_destroy :: proc(types:^Types) {
    for layout in types.layouts {
        if layout!=nil {
            serial.layout_destroy(layout)
            free(layout,types.allocator)
        }
    }
    serial.schema_destroy(&types.schema)
    delete(types.hashes);delete(types.transient);delete(types.layouts)
    types^={}
}

// The index of T in the schema, adding it the first time. Fails for a type
// that is not plain data; types.schema.error says which field.
types_index :: proc(types:^Types,$T:typeid) -> (index:serial.Type_Index,ok:bool) {
    return types_index_info(types,type_info_of(T))
}

types_index_info :: proc(types:^Types,info:^runtime.Type_Info) -> (index:serial.Type_Index,ok:bool) {
    types.error=.None
    known:bool
    index,known=types.schema.lookup[info.id]
    if !known {
        index,known=serial.schema_add_type_info(&types.schema,info)
        if !known {types.error=.Invalid;return serial.TYPE_NONE,false}
    }
    if !types_update(types) {types.error=.Out_Of_Memory;return serial.TYPE_NONE,false}
    return index,true
}

@(private)
types_update :: proc(types:^Types) -> bool {
    s:=&types.schema
    if reserve(&types.transient,len(s.types))!=nil || reserve(&types.layouts,len(s.types))!=nil || !serial.schema_hashes_update(s,&types.hashes) {return false}
    for at in len(types.transient)..<len(s.types) {
        type:=s.types[at]
        transient:=false
        #partial switch type.kind {
        case .Struct:
            for field in s.fields[type.first:][:type.count] {
                if .Transient in field.flags || types.transient[field.type] {transient=true;break}
            }
        case .Array:
            transient=types.transient[type.elem]
        }
        append(&types.transient,transient)
        append(&types.layouts,nil)
    }
    return true
}

// How a type is saved. nil, with Out_Of_Memory in types.error, without memory for it.
types_layout :: proc(types:^Types,index:serial.Type_Index) -> ^serial.Layout {
    if types.layouts[index]==nil {
        layout,no_layout:=new(serial.Layout,types.allocator)
        if no_layout!=nil {
            types.error=.Out_Of_Memory
            return nil
        }
        serial.layout_init(layout,&types.schema,index,types.allocator)
        types.layouts[index]=layout
    }
    return types.layouts[index]
}
