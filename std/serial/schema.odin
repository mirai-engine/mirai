package serial

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:slice"
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
    // Only in a schema that takes them (Schema.unsized): values that live in
    // memory and in text, with no image, no binary schema and no migration.
    Slice,     // []T or [dynamic]T: any number of elements of type elem
    String,    // string
    Json,      // serial.Json
}

// Any JSON value, as its text: what a field holds when only whoever reads it
// knows its shape (the values of a component, by the schema of the world).
// Empty is null. Read, it is a view of the text it was read from.
Json :: distinct string

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
    was:string,      // Struct: the names it had, separated by spaces (@(component,was=)): a table of a document under one of them is its table
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

// What the tag of a field says besides its flags. Not in the binary schema.
Field_Hint :: enum u8 {
    Trim,     // a fixed array the text writes up to its last element with a byte set
    Keyed,    // a fixed array of structs whose first field, a text, names each entry (empty: none): a layer of settings replaces the entries it names
    Entity,   // a text that names an entity: the API says so in its schema
    Optional, // a param a caller may leave out, or a part of a result that is not always there
    Clamp,    // an integer param that only bounds how much a method answers: past its max it takes the max
    Advanced, // the inspector shows it with the advanced fields of its component
    Owned,    // an asset the component makes and owns: a copy of the entity takes a copy of it
    Game,     // a table or a storage of a test world that the game of a project declares
    Hex,      // a u64 the inspector edits as exact hexadecimal
    Data,     // a text that names a component or a storage of the world
    Inline,   // a struct whose fields stand in place of it (field_inlined): no field of a schema has it
}
Field_Hints :: bit_set[Field_Hint;u16]

Field :: struct {
    name:string,
    name_hash:u64,
    type:Type_Index,
    offset:u32,
    flags:Field_Flags,
    hints:Field_Hints,
    has_min,has_max:bool,
    min,max,step:f64,
    precision:f32, // replication quantum of a float; 0 sends it whole
    bits:u8,       // replication width of an integer; 0 sends it whole
    label,unit:string,
    required_component:u64,
    // Not in the binary schema:
    description:string, // what the comment on the line of the field says
    asset_kinds:string, // the extensions an Asset_Id field holds, separated by spaces (kind=)
    section:string,     // the title the inspector opens over the field and those after it
    icons:string,       // the icons of the members of an enum, in their order, separated by spaces
    axes:string,        // the letters of the cells of a vector, one each
    graphics:string,    // the label of the field in the graphics popup of the viewport
    choices:string,     // what the graphics popup offers: labels separated by |, each label:value or a label that is its value
    was:string,         // the names the field had before, separated by spaces (was=): a migration reads a stored field by any of them
    mode:string,        // the values of the field mode of its struct the inspector shows it with, separated by |
}

// The texts a field owns in its schema.
@(private)
field_texts :: #force_inline proc "contextless" (field:^Field) -> [11]^string {
    return {&field.name,&field.label,&field.unit,&field.description,&field.asset_kinds,&field.section,&field.icons,&field.axes,&field.graphics,&field.was,&field.mode}
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
    error:string, // set when schema_add fails: the path of the field that is not plain data; empty when it had no memory
    unsized:bool, // its types may hold slices, strings and Json; whoever builds it sets it before adding types
    sparse:bool,  // text leaves out a field tagged optional that holds nothing: all its bytes are zero
    adding:[dynamic]typeid, // the structs schema_add is inside of: one that holds itself is not added
    allocator:runtime.Allocator,
}

schema_init :: proc(s:^Schema,allocator:=context.allocator) {
    s^={allocator=allocator}
    s.types=make([dynamic]Type,allocator)
    s.fields=make([dynamic]Field,allocator)
    s.choices=make([dynamic]Choice,allocator)
    s.lookup=make(map[typeid]Type_Index,allocator)
    s.adding=make([dynamic]typeid,allocator)
}

schema_destroy :: proc(s:^Schema) {
    for type in s.types {delete(type.name,s.allocator);delete(type.was,s.allocator)}
    for field in s.fields {schema_field_free(s,field)}
    for choice in s.choices {delete(choice.name,s.allocator)}
    delete(s.error,s.allocator)
    delete(s.types);delete(s.fields);delete(s.choices);delete(s.lookup);delete(s.adding)
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
// Gives a field of a struct the description of its line in the source. False,
// with the field without one, when there is no memory for it.
schema_describe :: proc(s:^Schema,index:Type_Index,name,text:string) -> bool {
    field:=schema_field(s,index,base.name_hash(name))
    if field==nil || text=="" {return true}
    return schema_text_keep(s,&field.description,text)
}

// Puts a copy of text in target, which lets go of what it held.
@(private)
schema_text_keep :: proc(s:^Schema,target:^string,text:string) -> bool {
    delete(target^,s.allocator)
    error:runtime.Allocator_Error
    target^,error=strings.clone(text,s.allocator)
    return error==nil
}

@(private)
schema_field_free :: proc(s:^Schema,field:Field) {
    field:=field
    for text in field_texts(&field) {delete(text^,s.allocator)}
}

// Gives a field copies in the schema of its texts, which were views or the
// texts of another schema. False without memory for one: the field then
// holds the copies it got and no other text.
@(private)
schema_field_keep :: proc(s:^Schema,field:^Field) -> bool {
    whole:=true
    for text in field_texts(field) {
        if text^=="" {text^="";continue}
        copied,error:=strings.clone(text^,s.allocator)
        text^=error==nil?copied:""
        whole&&=error==nil
    }
    return whole
}

// A choice with a copy of its name, after the others. False without memory for it.
@(private)
schema_choice_add :: proc(s:^Schema,name:string,value:i64) -> bool {
    copied,error:=strings.clone(name,s.allocator)
    if error!=nil {return false}
    if _,no_room:=append(&s.choices,Choice{copied,value});no_room!=nil {
        delete(copied,s.allocator)
        return false
    }
    return true
}

// Lets go of what a type that was not added took: its name, and its fields
// or its choices, which are the last of the schema.
@(private)
schema_type_drop :: proc(s:^Schema,type:Type) {
    delete(type.name,s.allocator)
    delete(type.was,s.allocator)
    if type.kind==.Struct && int(type.first)<=len(s.fields) {
        for field in s.fields[type.first:] {schema_field_free(s,field)}
        base.truncate(&s.fields,type.first)
    } else if (type.kind==.Enum || type.kind==.Bit_Set || type.named!=.None) && int(type.first)<=len(s.choices) {
        for choice in s.choices[type.first:] {delete(choice.name,s.allocator)}
        base.truncate(&s.choices,type.first)
    }
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
// anything that is not plain data: pointers, slices, strings, maps, unions;
// and without memory, with the types it had added before kept whole. A
// schema that is unsized also takes slices, strings and Json, in types that do not
// hold themselves.
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
    case .Array,.Slice:
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
    if s.error=="" {
        if text,error:=strings.clone(fmt.tprintf("%s: %s is not plain data",path==""?"<root>":path,type_label(info)),s.allocator);error==nil {s.error=text}
    }
    return TYPE_NONE,false
}

// Adds a type, which owns its name and the fields or choices it put last in
// the schema; without memory for it they go with it.
@(private)
schema_push :: proc(s:^Schema,id:typeid,type:Type) -> (Type_Index,bool) {
    index:=Type_Index(len(s.types))
    // The type goes in first and comes out when the map has no room for it:
    // delete_key on a map[typeid] keeps odin -o:speed from ending (ODIN_WORKAROUNDS).
    if _,error:=append(&s.types,type);error==nil {
        s.lookup[id]=index
        if id in s.lookup {return index,true}
        pop(&s.types)
    }
    schema_type_drop(s,type)
    return TYPE_NONE,false
}

@(private)
schema_add_info :: proc(s:^Schema,info:^runtime.Type_Info,path:string) -> (Type_Index,bool) {
    if index,found:=s.lookup[info.id];found {return index,true}
    size,align:=u32(info.size),u32(info.align)
    switch info.id {
    case base.Entity:    return schema_push(s,info.id,{kind=.Entity,size=size,align=align,elem=TYPE_NONE})
    case base.Entity_Id: return schema_push(s,info.id,{kind=.Entity_Id,size=size,align=align,elem=TYPE_NONE})
    case base.Asset_Id:  return schema_push(s,info.id,{kind=.Asset,size=size,align=align,elem=TYPE_NONE})
    case Json:
        if !s.unsized {return schema_fail(s,path,info)}
        return schema_push(s,info.id,{kind=.Json,size=size,align=align,elem=TYPE_NONE})
    }
    type:=Type{size=size,align=align,elem=TYPE_NONE}
    if named,is_named:=info.variant.(runtime.Type_Info_Named);is_named {
        no_name:runtime.Allocator_Error
        if type.name,no_name=strings.clone(named.name,s.allocator);no_name!=nil {return TYPE_NONE,false}
        type.name_hash=base.name_hash(named.name)
    }
    listed:=true
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
            for choice in names.choices {listed&&=schema_choice_add(s,choice.name,choice.value)}
        }
    case runtime.Type_Info_Float:
        type.kind=.Float
    case runtime.Type_Info_Enum:
        type.kind=.Enum
        type.first,type.count=u32(len(s.choices)),u32(len(variant.names))
        for name,i in variant.names {listed&&=schema_choice_add(s,name,i64(variant.values[i]))}
    case runtime.Type_Info_Bit_Set:
        type.kind=.Bit_Set
        type.first=u32(len(s.choices))
        if elem:=runtime.type_info_base(variant.elem);elem!=nil {
            if enumeration,is_enum:=elem.variant.(runtime.Type_Info_Enum);is_enum {
                for name,i in enumeration.names {listed&&=schema_choice_add(s,name,i64(enumeration.values[i])-variant.lower)}
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
    case runtime.Type_Info_String:
        if !s.unsized || variant.is_cstring || variant.encoding!=.UTF_8 {
            delete(type.name,s.allocator)
            return schema_fail(s,path,info)
        }
        type.kind=.String
    case runtime.Type_Info_Slice:
        if !s.unsized {
            delete(type.name,s.allocator)
            return schema_fail(s,path,info)
        }
        elem_type,ok:=schema_add_info(s,variant.elem,path)
        if !ok {delete(type.name,s.allocator);return TYPE_NONE,false}
        type.kind,type.elem=.Slice,elem_type
    case runtime.Type_Info_Dynamic_Array:
        if !s.unsized {
            delete(type.name,s.allocator)
            return schema_fail(s,path,info)
        }
        elem_type,ok:=schema_add_info(s,variant.elem,path)
        if !ok {delete(type.name,s.allocator);return TYPE_NONE,false}
        type.kind,type.elem=.Slice,elem_type
    case runtime.Type_Info_Struct:
        if .raw_union in variant.flags || variant.soa_kind!=.None || slice.contains(s.adding[:],info.id) {
            delete(type.name,s.allocator)
            return schema_fail(s,path,info)
        }
        fields:=make([dynamic]Field,0,int(variant.field_count),context.temp_allocator)
        if _,no_room:=append(&s.adding,info.id);no_room!=nil {
            delete(type.name,s.allocator)
            return TYPE_NONE,false
        }
        added:=schema_fields_add(s,variant,0,path,&fields)
        pop(&s.adding)
        if !added || reserve(&s.fields,len(s.fields)+len(fields))!=nil {
            for added in fields {schema_field_free(s,added)}
            delete(type.name,s.allocator)
            return TYPE_NONE,false
        }
        if clash:=was_clash(fields[:]);clash!="" {
            for added in fields {schema_field_free(s,added)}
            delete(type.name,s.allocator)
            if s.error=="" {
                if text,error:=strings.clone(fmt.tprintf("%s: %s",path==""?type_label(info):path,clash),s.allocator);error==nil {s.error=text}
            }
            return TYPE_NONE,false
        }
        type.kind=.Struct
        type.first,type.count=u32(len(s.fields)),u32(len(fields))
        append(&s.fields,..fields[:])
    case:
        delete(type.name,s.allocator)
        return schema_fail(s,path,info)
    }
    if !listed {
        schema_type_drop(s,type)
        return TYPE_NONE,false
    }
    return schema_push(s,info.id,type)
}

// A field tagged inline holds a struct whose fields stand in place of it, as
// if they were declared there: what an API answers flat and shares with other
// answers. No struct with saved data is tagged: its fields would move.
field_inlined :: proc(variant:runtime.Type_Info_Struct,i:int) -> (nested:runtime.Type_Info_Struct,inlined:bool) {
    if tagged,_:=field_tag(variant.tags[i]);.Inline not_in tagged.hints {return}
    return runtime.type_info_base(variant.types[i]).variant.(runtime.Type_Info_Struct)
}

// A field whose earlier name (was=) is the name of a field of the struct: a
// stored value would go to both. "" when there is none.
@(private)
was_clash :: proc(fields:[]Field) -> string {
    for field in fields {
        rest:=field.was
        for name in strings.fields_iterator(&rest) {
            for other in fields {
                if other.name==name {return fmt.tprintf("field %s: was=%s is the name of a field the struct has, and a stored value would go to both; give the earlier name to one field only",field.name,name)}
            }
        }
    }
    return ""
}

// The fields of a struct at offset of the one that holds them, in order.
@(private)
schema_fields_add :: proc(s:^Schema,variant:runtime.Type_Info_Struct,offset:uintptr,path:string,fields:^[dynamic]Field) -> bool {
    for i in 0..<int(variant.field_count) {
        at:=offset+variant.offsets[i]
        field_path:=path==""?variant.names[i]:fmt.tprintf("%s.%s",path,variant.names[i])
        field,problem:=field_tag(variant.tags[i])
        if problem!="" {
            if s.error=="" {
                if text,error:=strings.clone(fmt.tprintf("%s: %s",field_path,problem),s.allocator);error==nil {s.error=text}
            }
            return false
        }
        if .Inline in field.hints {
            nested,is_struct:=runtime.type_info_base(variant.types[i]).variant.(runtime.Type_Info_Struct)
            if !is_struct {
                schema_fail(s,field_path,variant.types[i])
                return false
            }
            schema_fields_add(s,nested,at,path,fields) or_return
            continue
        }
        field.type=schema_add_info(s,variant.types[i],field_path) or_return
        field.offset=u32(at)
        if field.name=="" {field.name=variant.names[i]}
        field.name_hash=base.name_hash(field.name)
        if _,is_quaternion:=runtime.type_info_base(variant.types[i]).variant.(runtime.Type_Info_Quaternion);is_quaternion {field.flags+={.Rotation}}
        if schema_field_keep(s,&field) {
            if _,no_room:=append(fields,field);no_room==nil {continue}
        }
        schema_field_free(s,field)
        return false
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

// The options a tag takes, as an error names them.
FIELD_TAGS :: "transient, local, readonly, hidden, color, angle, text, trim, keyed, entity, inline, optional, clamp, advanced, owned, game, hex, data, min=, max=, step=, precision=, bits=, unit=, name=, kind=, requires=, was=, section=, icons=, axes=, graphics=, choices=, mode= and, last, label="

// What the tag of a field says: the only reader of `mirai:"..."`, for the
// schema and for whoever walks the type information of a struct itself. The
// tag is a list of options separated by commas: flags, and key=value pairs.
// label= is the last one and takes the rest of the tag, commas included;
// name= is the name the field goes by in text when its word is reserved in
// Odin. The texts of the field are views of the tag, and its type and offset
// are not set. problem, in temporary memory, says which option is not one
// and the ones there are; the field then holds the options before it.
field_tag :: proc(tag:string) -> (field:Field,problem:string) {
    options,found:=reflect.struct_tag_lookup(reflect.Struct_Tag(tag),"mirai")
    if !found {return}
    rest:=options
    for rest!="" {
        option:=rest
        if strings.has_prefix(strings.trim_left_space(rest),"label=") {
            rest=""
        } else if comma:=strings.index_byte(rest,',');comma>=0 {
            option,rest=rest[:comma],rest[comma+1:]
        } else {
            rest=""
        }
        key,value:=strings.trim_space(option),""
        equals:=strings.index_byte(key,'=')
        if equals>=0 {key,value=strings.trim_space(key[:equals]),strings.trim_space(key[equals+1:])}
        if key=="" && equals<0 {continue}
        flag:=true
        switch key {
        case "transient": field.flags+={.Transient}
        case "local":     field.flags+={.Local}
        case "readonly":  field.flags+={.Read_Only}
        case "hidden":    field.flags+={.Hidden}
        case "color":     field.flags+={.Color}
        case "angle":     field.flags+={.Angle}
        case "text":      field.flags+={.Text}
        case "trim":      field.hints+={.Trim}
        case "keyed":     field.hints+={.Keyed}
        case "entity":    field.hints+={.Entity}
        case "inline":    field.hints+={.Inline}
        case "optional":  field.hints+={.Optional}
        case "clamp":     field.hints+={.Clamp}
        case "advanced":  field.hints+={.Advanced}
        case "owned":     field.hints+={.Owned}
        case "game":      field.hints+={.Game}
        case "hex":       field.hints+={.Hex}
        case "data":      field.hints+={.Data}
        case: flag=false
        }
        if flag {
            if equals>=0 {return field,fmt.tprintf("the tag %q takes no value",key)}
            continue
        }
        number,is_number:=strconv.parse_f64(value)
        numeric:=true
        switch key {
        case "min":       field.min,field.has_min=number,is_number
        case "max":       field.max,field.has_max=number,is_number
        case "step":      field.step=number
        case "precision": field.precision=f32(number)
        case "bits":
            is_number&&=number>=0 && number<=64 && number==f64(int(number))
            if is_number {field.bits=u8(number)}
        case: numeric=false
        }
        if numeric {
            if !is_number {return field,fmt.tprintf("the tag %s=%q is not a number it takes",key,value)}
            continue
        }
        switch key {
        case "label":    field.label=value
        case "unit":     field.unit=value
        case "name":     field.name=value
        case "kind":     field.asset_kinds=value
        case "section":  field.section=value
        case "icons":    field.icons=value
        case "axes":     field.axes=value
        case "graphics": field.graphics=value
        case "choices":  field.choices=value
        case "was":      field.was=value
        case "mode":     field.mode=value
        case "requires": field.required_component=value!=""?base.name_hash(value):0
        case:
            return field,fmt.tprintf("%q is not a tag of a field: the tags are %s",key,FIELD_TAGS)
        }
        if value=="" && key!="label" {return field,fmt.tprintf("the tag %s= has no value",key)}
    }
    return
}
