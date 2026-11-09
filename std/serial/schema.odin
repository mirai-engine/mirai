package serial

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "mirai:std/base"

// Description of plain data types obtained by reflection. It is the single
// contract behind scene serialization, the inspector, replication and the
// agent API: they all match types and fields by name_hash, never by typeid.

Type_Index :: distinct u16
TYPE_NONE :: Type_Index(0xffff)

Type_Kind :: enum u8 {
    Bool,
    Int,
    Uint,
    Float,
    Enum,      // choices hold every named value
    Bit_Set,   // choices hold the bit index of every member
    Entity,    // base.Entity, remapped when a world is cloned, loaded or replicated
    Entity_Id, // base.Entity_Id
    Asset,     // base.Asset_Id
    Struct,    // fields
    Array,     // count elements of type elem; vectors, quaternions and matrices are arrays of floats
}

// An integer whose values have names (core @(names)) or whose bits do: text
// and paths read and write it by those names. Saved data keeps the number and
// its layout does not depend on the names, unless its numbers are generated
// (by_name): then the names are its layout and a value moves by name, as the
// member of an enum does.
Named_Kind :: enum u8 {None,Values,Bits}

Type :: struct {
    kind:Type_Kind,
    named:Named_Kind, // Int and Uint: choices name its values or its bits
    by_name:bool,     // named: saved data moves its values by name
    size,align:u32,
    name:string,     // "" for anonymous types
    name_hash:u64,
    first,count:u32, // Struct: fields; Enum, Bit_Set and a named integer: choices; Array: count is its length
    elem:Type_Index, // Array
}

Field_Flag :: enum u8 {
    Transient, // not saved
    Local,     // not replicated
    Read_Only,
    Hidden,
    Color,     // linear RGB or RGBA
    Angle,     // radians, shown in degrees
    Text,      // [N]u8 holding NUL-terminated UTF-8
    Rotation,  // quaternion
}
Field_Flags :: bit_set[Field_Flag;u8]

Field :: struct {
    name:string,
    name_hash:u64,
    type:Type_Index,
    offset:u32,
    flags:Field_Flags,
    has_min,has_max:bool,
    min,max,step:f64,
    precision:f32, // replication quantum of a float; 0 sends it whole
    bits:u8,       // replication width of an integer; 0 sends it whole
    label,unit:string,
    description:string, // what the comment on the line of the field says; not in the binary schema
    asset_kinds:string, // the extensions an Asset_Id field holds, separated by spaces (kind=); not in the binary schema
    required_component:u64,
    trim:bool, // a fixed array the text writes up to its last element with a byte set; not in the binary schema
    any_value:bool, // tagged any: text_read takes any JSON there and leaves the bytes, for whoever reads it from the text; not in the binary schema
}

Choice :: struct {name:string,value:i64}

// The names an integer type takes when it is added: of its values, or of its bits.
Named :: struct {
    choices:[]Choice,
    bits:bool,
    by_name:bool, // the numbers are generated, so the names are what stays
}

// A closed set of types. Names are owned by the schema, so it outlives the
// module whose type information produced it.
Schema :: struct {
    types:[dynamic]Type,
    fields:[dynamic]Field,
    choices:[dynamic]Choice,
    lookup:map[typeid]Type_Index,
    named:map[typeid]Named, // whoever builds it sets and keeps it before adding types; the schema copies the names it takes
    error:string, // set when schema_add fails: the path of the field that is not plain data
    allocator:runtime.Allocator,
}

schema_init :: proc(s:^Schema,allocator:=context.allocator) {
    s^={allocator=allocator}
    s.types=make([dynamic]Type,allocator)
    s.fields=make([dynamic]Field,allocator)
    s.choices=make([dynamic]Choice,allocator)
    s.lookup=make(map[typeid]Type_Index,allocator)
}

schema_destroy :: proc(s:^Schema) {
    for type in s.types {delete(type.name,s.allocator)}
    for field in s.fields {delete(field.name,s.allocator);delete(field.label,s.allocator);delete(field.unit,s.allocator);delete(field.description,s.allocator);delete(field.asset_kinds,s.allocator)}
    for choice in s.choices {delete(choice.name,s.allocator)}
    delete(s.error,s.allocator)
    delete(s.types);delete(s.fields);delete(s.choices);delete(s.lookup)
    s^={}
}

// The type is one of the schema. The procedures that take a Type_Index
// treat any other as a type without fields, choices or bytes.
type_valid :: #force_inline proc "contextless" (s:^Schema,index:Type_Index) -> bool {return int(index)<len(s.types)}

schema_type :: #force_inline proc(s:^Schema,index:Type_Index) -> ^Type {return type_valid(s,index)?&s.types[index]:nil}
schema_fields :: proc(s:^Schema,index:Type_Index) -> []Field {
    if !type_valid(s,index) {return nil}
    type:=s.types[index]
    if type.kind!=.Struct {return nil}
    return s.fields[type.first:][:type.count]
}
schema_choices :: proc(s:^Schema,index:Type_Index) -> []Choice {
    if !type_valid(s,index) {return nil}
    type:=s.types[index]
    if type.kind!=.Enum && type.kind!=.Bit_Set {return nil}
    return s.choices[type.first:][:type.count]
}
schema_field :: proc(s:^Schema,index:Type_Index,name_hash:u64) -> ^Field {
    if !type_valid(s,index) {return nil}
    type:=s.types[index]
    if type.kind!=.Struct {return nil}
    for &field in s.fields[type.first:][:type.count] {
        if field.name_hash==name_hash {return &field}
    }
    return nil
}
// Gives a field of a struct the description of its line in the source.
schema_describe :: proc(s:^Schema,index:Type_Index,name,text:string) {
    field:=schema_field(s,index,base.name_hash(name))
    if field==nil || text=="" {return}
    delete(field.description,s.allocator)
    field.description=strings.clone(text,s.allocator)
}
schema_find :: proc(s:^Schema,name_hash:u64) -> (Type_Index,bool) {
    for type,index in s.types {
        if type.name_hash==name_hash && type.name!="" {return Type_Index(index),true}
    }
    return TYPE_NONE,false
}

// Renames the choice old as name in every type that moves by name and has no
// choice name yet: what data saved with a renamed action keeps of it. How
// many types it renamed it in; it stops without memory.
schema_choice_rename :: proc(s:^Schema,old,name:string) -> (renamed:int) {
    if old==name || name=="" {return}
    for type in s.types {
        if type.named==.None || !type.by_name {continue}
        choices:=s.choices[type.first:][:type.count]
        at,taken:=-1,false
        for choice,i in choices {
            if choice.name==old {at=i}
            taken||=choice.name==name
        }
        if at<0 || taken {continue}
        copied,error:=strings.clone(name,s.allocator)
        if error!=nil {return}
        delete(choices[at].name,s.allocator)
        choices[at].name=copied
        renamed+=1
    }
    return
}

// Adds T and every type it contains. Fails, with s.error set, when T holds
// anything that is not plain data: pointers, slices, strings, maps, unions.
schema_add :: proc(s:^Schema,$T:typeid) -> (index:Type_Index,ok:bool) {
    return schema_add_type_info(s,type_info_of(T))
}

// schema_add from the type information itself: the one of a type another
// binary declares, which type_info_of here does not know.
schema_add_type_info :: proc(s:^Schema,info:^runtime.Type_Info) -> (index:Type_Index,ok:bool) {
    delete(s.error,s.allocator);s.error=""
    return schema_add_info(s,info,"")
}

// Changes when a name, kind, offset or size of the type or of anything inside
// it changes. Equal hashes mean equal bytes: values can be copied whole.
schema_layout_hash :: proc(s:^Schema,index:Type_Index) -> u64 {
    if !type_valid(s,index) {return 0}
    type:=s.types[index]
    hash:=base.hash_combine(u64(type.kind),u64(type.size)<<32|u64(layout_count(type)))
    #partial switch type.kind {
    case .Struct:
        for field in s.fields[type.first:][:type.count] {
            hash=base.hash_combine(hash,field.name_hash)
            hash=base.hash_combine(hash,u64(field.offset))
            hash=base.hash_combine(hash,schema_layout_hash(s,field.type))
        }
    case .Array:
        hash=base.hash_combine(hash,schema_layout_hash(s,type.elem))
    }
    if layout_named(type) {hash=layout_choices(s,type,hash)}
    return hash
}

// What the layout of a type counts: how many names an integer has is not its
// layout; layout_named says when the names themselves are.
@(private)
layout_count :: proc "contextless" (type:Type) -> u32 {
    return type.kind==.Int || type.kind==.Uint?0:type.count
}

// Whether the names of a type are its layout: an enum's, a bit set's and
// those of an integer that moves by name.
@(private)
layout_named :: proc "contextless" (type:Type) -> bool {
    return type.kind==.Enum || type.kind==.Bit_Set || type.named!=.None && type.by_name
}

@(private)
layout_choices :: proc(s:^Schema,type:Type,hash:u64) -> u64 {
    hash:=hash
    if type.by_name {hash=base.hash_combine(hash,u64(type.named))}
    for choice in s.choices[type.first:][:type.count] {
        hash=base.hash_combine(hash,base.name_hash(choice.name))
        hash=base.hash_combine(hash,u64(choice.value))
    }
    return hash
}

// How text and paths take a type: a named integer as its enum or its bit set.
@(private)
text_kind :: proc "contextless" (type:Type) -> Type_Kind {
    switch type.named {
    case .None:
    case .Values: return .Enum
    case .Bits:   return .Bit_Set
    }
    return type.kind
}

// The name of a type from its information: fmt would look the typeid up in this binary.
type_label :: proc(info:^runtime.Type_Info) -> string {
    b:strings.Builder
    strings.builder_init(&b,context.temp_allocator)
    reflect.write_type_builder(&b,info)
    return strings.to_string(b)
}

@(private)
schema_fail :: proc(s:^Schema,path:string,info:^runtime.Type_Info) -> (Type_Index,bool) {
    if s.error=="" {s.error=fmt.aprintf("%s: %s is not plain data",path==""?"<root>":path,type_label(info),allocator=s.allocator)}
    return TYPE_NONE,false
}

@(private)
schema_push :: proc(s:^Schema,id:typeid,type:Type) -> (Type_Index,bool) {
    index:=Type_Index(len(s.types))
    append(&s.types,type)
    s.lookup[id]=index
    return index,true
}

@(private)
schema_add_info :: proc(s:^Schema,info:^runtime.Type_Info,path:string) -> (Type_Index,bool) {
    if index,found:=s.lookup[info.id];found {return index,true}
    size,align:=u32(info.size),u32(info.align)
    switch info.id {
    case base.Entity:    return schema_push(s,info.id,{kind=.Entity,size=size,align=align,elem=TYPE_NONE})
    case base.Entity_Id: return schema_push(s,info.id,{kind=.Entity_Id,size=size,align=align,elem=TYPE_NONE})
    case base.Asset_Id:  return schema_push(s,info.id,{kind=.Asset,size=size,align=align,elem=TYPE_NONE})
    }
    type:=Type{size=size,align=align,elem=TYPE_NONE}
    if named,is_named:=info.variant.(runtime.Type_Info_Named);is_named {
        type.name=strings.clone(named.name,s.allocator)
        type.name_hash=base.name_hash(named.name)
    }
    core:=runtime.type_info_base(info)
    #partial switch variant in core.variant {
    case runtime.Type_Info_Boolean:
        type.kind=.Bool
    case runtime.Type_Info_Integer:
        type.kind=variant.signed?.Int:.Uint
        if names,is_named:=s.named[info.id];is_named {
            type.named=names.bits?.Bits:.Values
            type.by_name=names.by_name
            type.first,type.count=u32(len(s.choices)),u32(len(names.choices))
            for choice in names.choices {append(&s.choices,Choice{strings.clone(choice.name,s.allocator),choice.value})}
        }
    case runtime.Type_Info_Float:
        type.kind=.Float
    case runtime.Type_Info_Enum:
        type.kind=.Enum
        type.first,type.count=u32(len(s.choices)),u32(len(variant.names))
        for name,i in variant.names {append(&s.choices,Choice{strings.clone(name,s.allocator),i64(variant.values[i])})}
    case runtime.Type_Info_Bit_Set:
        type.kind=.Bit_Set
        type.first=u32(len(s.choices))
        if elem:=runtime.type_info_base(variant.elem);elem!=nil {
            if enumeration,is_enum:=elem.variant.(runtime.Type_Info_Enum);is_enum {
                for name,i in enumeration.names {
                    append(&s.choices,Choice{strings.clone(name,s.allocator),i64(enumeration.values[i])-variant.lower})
                }
            }
        }
        type.count=u32(len(s.choices))-type.first
    case runtime.Type_Info_Quaternion:
        return schema_add_floats(s,info,type,4,path)
    case runtime.Type_Info_Matrix:
        if variant.elem_stride!=variant.row_count {
            delete(type.name,s.allocator)
            return schema_fail(s,path,info)
        }
        return schema_add_elements(s,info,type,variant.elem,variant.row_count*variant.column_count,path)
    case runtime.Type_Info_Array:
        return schema_add_elements(s,info,type,variant.elem,variant.count,path)
    case runtime.Type_Info_Enumerated_Array:
        if variant.is_sparse {
            delete(type.name,s.allocator)
            return schema_fail(s,path,info)
        }
        return schema_add_elements(s,info,type,variant.elem,variant.count,path)
    case runtime.Type_Info_Struct:
        if .raw_union in variant.flags || variant.soa_kind!=.None {
            delete(type.name,s.allocator)
            return schema_fail(s,path,info)
        }
        fields:=make([dynamic]Field,0,int(variant.field_count),context.temp_allocator)
        if !schema_fields_add(s,variant,0,path,&fields) {
            for added in fields {delete(added.name,s.allocator);delete(added.label,s.allocator);delete(added.unit,s.allocator)}
            delete(type.name,s.allocator)
            return TYPE_NONE,false
        }
        type.kind=.Struct
        type.first,type.count=u32(len(s.fields)),u32(len(fields))
        append(&s.fields,..fields[:])
    case:
        delete(type.name,s.allocator)
        return schema_fail(s,path,info)
    }
    return schema_push(s,info.id,type)
}

// A field tagged inline holds a struct whose fields stand in place of it, as
// if they were declared there: what an API answers flat and shares with other
// answers. No struct with saved data is tagged: its fields would move.
field_inlined :: proc(variant:runtime.Type_Info_Struct,i:int) -> (nested:runtime.Type_Info_Struct,inlined:bool) {
    options,found:=reflect.struct_tag_lookup(reflect.Struct_Tag(variant.tags[i]),"mirai")
    if !found {return}
    rest:=options
    for option in strings.split_iterator(&rest,",") {
        if strings.trim_space(option)=="inline" {
            nested,inlined=runtime.type_info_base(variant.types[i]).variant.(runtime.Type_Info_Struct)
            return
        }
    }
    return
}

// The fields of a struct at offset of the one that holds them, in order.
@(private)
schema_fields_add :: proc(s:^Schema,variant:runtime.Type_Info_Struct,offset:uintptr,path:string,fields:^[dynamic]Field) -> bool {
    for i in 0..<int(variant.field_count) {
        at:=offset+variant.offsets[i]
        if nested,inlined:=field_inlined(variant,i);inlined {
            schema_fields_add(s,nested,at,path,fields) or_return
            continue
        }
        field_path:=path==""?variant.names[i]:fmt.tprintf("%s.%s",path,variant.names[i])
        field_type:=schema_add_info(s,variant.types[i],field_path) or_return
        field:=Field{name=strings.clone(variant.names[i],s.allocator),name_hash=base.name_hash(variant.names[i]),type=field_type,offset=u32(at)}
        if _,is_quaternion:=runtime.type_info_base(variant.types[i]).variant.(runtime.Type_Info_Quaternion);is_quaternion {field.flags+={.Rotation}}
        schema_field_tag(s,&field,variant.tags[i])
        append(fields,field)
    }
    return true
}

@(private)
schema_add_elements :: proc(s:^Schema,info:^runtime.Type_Info,type:Type,elem:^runtime.Type_Info,count:int,path:string) -> (Type_Index,bool) {
    type:=type
    elem_type,ok:=schema_add_info(s,elem,path)
    if !ok {delete(type.name,s.allocator);return TYPE_NONE,false}
    type.kind,type.elem,type.count=.Array,elem_type,u32(count)
    return schema_push(s,info.id,type)
}

@(private)
schema_add_floats :: proc(s:^Schema,info:^runtime.Type_Info,type:Type,count:int,path:string) -> (Type_Index,bool) {
    switch info.size/count {
    case 2: return schema_add_elements(s,info,type,type_info_of(f16),count,path)
    case 4: return schema_add_elements(s,info,type,type_info_of(f32),count,path)
    case 8: return schema_add_elements(s,info,type,type_info_of(f64),count,path)
    }
    delete(type.name,s.allocator)
    return schema_fail(s,path,info)
}

// Field options come from the struct tag `mirai:"..."`: a comma separated
// list of flags (transient, local, readonly, hidden, color, angle, text, trim, any, inline) and
// of key=value pairs (min, max, step, precision, bits, label, unit).
@(private)
schema_field_tag :: proc(s:^Schema,field:^Field,tag:string) {
    options,found:=reflect.struct_tag_lookup(reflect.Struct_Tag(tag),"mirai")
    if !found {return}
    rest:=options
    for option in strings.split_iterator(&rest,",") {
        key,value:=strings.trim_space(option),""
        if equals:=strings.index_byte(key,'=');equals>=0 {key,value=strings.trim_space(key[:equals]),strings.trim_space(key[equals+1:])}
        switch key {
        case "transient": field.flags+={.Transient}
        case "local":     field.flags+={.Local}
        case "readonly":  field.flags+={.Read_Only}
        case "hidden":    field.flags+={.Hidden}
        case "color":     field.flags+={.Color}
        case "angle":     field.flags+={.Angle}
        case "text":      field.flags+={.Text}
        case "trim":      field.trim=true
        case "any":       field.any_value=true
        case "min":       field.min,field.has_min=strconv.parse_f64(value)
        case "max":       field.max,field.has_max=strconv.parse_f64(value)
        case "step":      field.step,_=strconv.parse_f64(value)
        case "precision": precision,_:=strconv.parse_f64(value);field.precision=f32(precision)
        case "bits":      bits,_:=strconv.parse_int(value);field.bits=u8(bits)
        case "label":     field.label=strings.clone(value,s.allocator)
        case "unit":      field.unit=strings.clone(value,s.allocator)
        case "kind":      field.asset_kinds=strings.clone(value,s.allocator)
        case "requires":  if value!="" {field.required_component=base.name_hash(value)}
        }
    }
}
