package serial

import "core:strings"
import "mirai:std/base"

// Binary form of a schema: what a file carries to describe its own values.
// A schema read from a file is validated whole, so every walk over its types
// ends and stays inside a value of the size the type declares:
//   - a type only refers to types before it, at most SCHEMA_MAX_DEPTH deep;
//   - fields follow one another without overlapping and end inside the struct;
//   - an array fits its type, and choices and scalar sizes are those of real types.
// The byte of the kind carries in its high nibble how a named integer names
// its values (two bits) and whether it moves by name (BY_NAME). A list of no
// fields or choices is written at 0, wherever it pointed, so that a schema
// read back writes the same bytes.

SCHEMA_FORMAT :: 1
SCHEMA_MAX_DEPTH :: 32
SCHEMA_MAX_ALIGN :: 4096
// Bytes of one value: every walk of a type is bounded by its bytes, since a
// struct or an array of no bytes has no fields or elements.
SCHEMA_MAX_SIZE :: 1<<24

Schema_Error :: enum u8 {
    None,
    Truncated,
    Version,
    Invalid_Type,
    Invalid_Field,
    Invalid_Choice,
    Too_Deep,
    Out_Of_Memory,
}

@(private="file") BY_NAME :: 0x40
@(private="file") HAS_MIN :: 1
@(private="file") HAS_MAX :: 2
@(private="file") HAS_STEP :: 4
@(private="file") HAS_PRECISION :: 8
@(private="file") HAS_BITS :: 16
@(private="file") HAS_LABEL :: 32
@(private="file") HAS_UNIT :: 64
@(private="file") HAS_REQUIRED_COMPONENT :: 128

schema_write :: proc(w:^Writer,s:^Schema) {
    write_varint(w,SCHEMA_FORMAT)
    write_varint(w,u64(len(s.types)))
    write_varint(w,u64(len(s.fields)))
    write_varint(w,u64(len(s.choices)))
    for type in s.types {
        write_u8(w,u8(type.kind)|u8(type.named)<<4|u8(type.by_name?BY_NAME:0))
        write_varint(w,u64(type.size))
        write_varint(w,u64(type.align))
        write_string(w,type.name)
        write_varint(w,type.count>0 && type.kind!=.Array?u64(type.first):0)
        write_varint(w,u64(type.count))
        write_varint(w,type.elem==TYPE_NONE?0:u64(type.elem)+1)
    }
    for field in s.fields {
        present:=u8(0)
        if field.has_min {present|=HAS_MIN}
        if field.has_max {present|=HAS_MAX}
        if field.step!=0 {present|=HAS_STEP}
        if field.precision!=0 {present|=HAS_PRECISION}
        if field.bits!=0 {present|=HAS_BITS}
        if field.label!="" {present|=HAS_LABEL}
        if field.unit!="" {present|=HAS_UNIT}
        if field.required_component!=0 {present|=HAS_REQUIRED_COMPONENT}
        write_string(w,field.name)
        write_varint(w,u64(field.type))
        write_varint(w,u64(field.offset))
        write_u8(w,transmute(u8)field.flags)
        write_u8(w,present)
        if field.has_min {write_f64(w,field.min)}
        if field.has_max {write_f64(w,field.max)}
        if field.step!=0 {write_f64(w,field.step)}
        if field.precision!=0 {write_f32(w,field.precision)}
        if field.bits!=0 {write_u8(w,field.bits)}
        if field.label!="" {write_string(w,field.label)}
        if field.unit!="" {write_string(w,field.unit)}
        if field.required_component!=0 {write_u64(w,field.required_component)}
    }
    for choice in s.choices {
        write_string(w,choice.name)
        write_svarint(w,choice.value)
    }
}

// Reads and validates a schema. s is initialized here and left empty on failure.
schema_read :: proc(r:^Reader,s:^Schema,allocator:=context.allocator) -> Schema_Error {
    schema_init(s,allocator)
    error:=schema_read_tables(r,s)
    if error==.None {error=schema_validate(s)}
    if error!=.None {schema_destroy(s)}
    return error
}

@(private="file")
schema_read_tables :: proc(r:^Reader,s:^Schema) -> Schema_Error {
    version:=read_varint(r)
    if r.failed {return .Truncated}
    if version!=SCHEMA_FORMAT {return .Version}
    type_count:=read_count(r,7)
    field_count:=read_count(r,5)
    choice_count:=read_count(r,2)
    if r.failed {return .Truncated}
    if type_count>=int(TYPE_NONE) {return .Invalid_Type}
    if resize(&s.types,type_count)!=nil || resize(&s.fields,field_count)!=nil || resize(&s.choices,choice_count)!=nil {return .Out_Of_Memory}
    for &type in s.types {
        kind_byte:=read_u8(r)
        kind,named:=kind_byte&0x0F,kind_byte>>4&0x03
        size,align:=read_varint(r),read_varint(r)
        name:=read_string(r)
        first,count,elem:=read_varint(r),read_varint(r),read_varint(r)
        if r.failed {return .Truncated}
        if kind>u8(max(Type_Kind)) || named>u8(max(Named_Kind)) || kind_byte&0x80!=0 || size>u64(max(u32)) || align>SCHEMA_MAX_ALIGN || first>u64(max(u32)) || count>u64(max(u32)) || elem>u64(TYPE_NONE) {return .Invalid_Type}
        type.kind,type.named,type.by_name=Type_Kind(kind),Named_Kind(named),kind_byte&BY_NAME!=0
        type.size,type.align=u32(size),u32(align)
        type.first,type.count=u32(first),u32(count)
        type.elem=elem==0?TYPE_NONE:Type_Index(elem-1)
        type.name=schema_string(s,name)
        if len(type.name)!=len(name) {return .Out_Of_Memory}
        if name!="" {type.name_hash=base.name_hash(name)}
    }
    for &field in s.fields {
        name:=read_string(r)
        type,offset:=read_varint(r),read_varint(r)
        flags,present:=read_u8(r),read_u8(r)
        if present&HAS_MIN!=0 {field.min,field.has_min=read_f64(r),true}
        if present&HAS_MAX!=0 {field.max,field.has_max=read_f64(r),true}
        if present&HAS_STEP!=0 {field.step=read_f64(r)}
        if present&HAS_PRECISION!=0 {field.precision=read_f32(r)}
        if present&HAS_BITS!=0 {field.bits=read_u8(r)}
        label:=present&HAS_LABEL!=0?read_string(r):""
        unit:=present&HAS_UNIT!=0?read_string(r):""
        if present&HAS_REQUIRED_COMPONENT!=0 {field.required_component=read_u64(r)}
        if r.failed {return .Truncated}
        if type>=u64(type_count) || offset>u64(max(u32)) {return .Invalid_Field}
        field.name=schema_string(s,name)
        if len(field.name)!=len(name) {return .Out_Of_Memory}
        field.name_hash=base.name_hash(name)
        field.type,field.offset=Type_Index(type),u32(offset)
        field.flags=transmute(Field_Flags)flags
        field.label,field.unit=schema_string(s,label),schema_string(s,unit)
        if len(field.label)!=len(label) || len(field.unit)!=len(unit) {return .Out_Of_Memory}
    }
    for &choice in s.choices {
        name:=read_string(r)
        value:=read_svarint(r)
        if r.failed {return .Truncated}
        choice.name=schema_string(s,name)
        if len(choice.name)!=len(name) {return .Out_Of_Memory}
        choice.value=value
    }
    return .None
}

@(private="file")
schema_string :: proc(s:^Schema,text:string) -> string {
    if text=="" {return ""}
    copied,error:=strings.clone(text,s.allocator)
    if error!=nil {return ""}
    return copied
}

// Checks what schema_read promises. Also true of every schema built by schema_add.
schema_validate :: proc(s:^Schema) -> Schema_Error {
    depths,error:=make([]u8,len(s.types),s.allocator)
    if error!=nil {return .Out_Of_Memory}
    defer delete(depths,s.allocator)
    for &type,index in s.types {
        if type.align==0 || type.align&(type.align-1)!=0 || type.align>SCHEMA_MAX_ALIGN || type.size>SCHEMA_MAX_SIZE {return .Invalid_Type}
        if type.kind!=.Array {type.elem=TYPE_NONE}
        if type.kind!=.Int && type.kind!=.Uint {type.named=.None}
        if type.named==.None {type.by_name=false}
        depth:=u8(0)
        switch type.kind {
        case .Bool:
            if !schema_size_in(type.size,{1,2,4,8}) {return .Invalid_Type}
            type.first,type.count=0,0
        case .Int,.Uint:
            if !schema_size_in(type.size,{1,2,4,8,16}) {return .Invalid_Type}
            if type.named==.None {type.first,type.count=0,0}
            if u64(type.first)+u64(type.count)>u64(len(s.choices)) {return .Invalid_Choice}
            if type.named==.Bits {
                for choice in s.choices[type.first:][:type.count] {
                    if choice.value<0 || choice.value>=i64(type.size)*8 {return .Invalid_Choice}
                }
            }
        case .Float:
            if !schema_size_in(type.size,{2,4,8}) {return .Invalid_Type}
            type.first,type.count=0,0
        case .Entity,.Entity_Id:
            if type.size!=8 {return .Invalid_Type}
            type.first,type.count=0,0
        case .Asset:
            if type.size!=16 {return .Invalid_Type}
            type.first,type.count=0,0
        case .Enum:
            if !schema_size_in(type.size,{1,2,4,8}) {return .Invalid_Type}
            if u64(type.first)+u64(type.count)>u64(len(s.choices)) {return .Invalid_Choice}
        case .Bit_Set:
            if !schema_size_in(type.size,{1,2,4,8,16}) {return .Invalid_Type}
            if u64(type.first)+u64(type.count)>u64(len(s.choices)) {return .Invalid_Choice}
            for choice in s.choices[type.first:][:type.count] {
                if choice.value<0 || choice.value>=i64(type.size)*8 {return .Invalid_Choice}
            }
        case .Struct:
            if u64(type.first)+u64(type.count)>u64(len(s.fields)) {return .Invalid_Field}
            if type.size==0 && type.count>0 {return .Invalid_Field}
            end:=u64(0)
            for field in s.fields[type.first:][:type.count] {
                if int(field.type)>=index {return .Invalid_Field}
                if u64(field.offset)<end {return .Invalid_Field}
                end=u64(field.offset)+u64(s.types[field.type].size)
                if end>u64(type.size) {return .Invalid_Field}
                if field.required_component!=0 && s.types[field.type].kind!=.Entity {return .Invalid_Field}
                depth=max(depth,depths[field.type])
            }
            depth+=1
        case .Array:
            if type.elem==TYPE_NONE || int(type.elem)>=index {return .Invalid_Type}
            if u64(type.count)*u64(s.types[type.elem].size)>u64(type.size) {return .Invalid_Type}
            if s.types[type.elem].size==0 && type.count>0 {return .Invalid_Type}
            type.first=0
            depth=depths[type.elem]+1
        }
        if depth>SCHEMA_MAX_DEPTH {return .Too_Deep}
        depths[index]=depth
    }
    return .None
}

@(private="file")
schema_size_in :: proc(size:u32,sizes:[]u32) -> bool {
    for candidate in sizes {if size==candidate {return true}}
    return false
}

// The layout hash of every type, in one pass. hashes grows to cover the types
// added since it was last brought up to date; values equal schema_layout_hash.
schema_hashes_update :: proc(s:^Schema,hashes:^[dynamic]u64) -> bool {
    if reserve(hashes,len(s.types))!=nil {return false}
    for index in len(hashes)..<len(s.types) {
        type:=s.types[index]
        hash:=base.hash_combine(u64(type.kind),u64(type.size)<<32|u64(layout_count(type)))
        #partial switch type.kind {
        case .Struct:
            for field in s.fields[type.first:][:type.count] {
                hash=base.hash_combine(hash,field.name_hash)
                hash=base.hash_combine(hash,u64(field.offset))
                hash=base.hash_combine(hash,hashes[field.type])
            }
        case .Array:
            hash=base.hash_combine(hash,hashes[type.elem])
        }
        if layout_named(type) {hash=layout_choices(s,type,hash)}
        append(hashes,hash)
    }
    return true
}

// Copies types of one schema into another, each one once: a type that the
// destination already has, with the same name and layout, is reused.
Schema_Import :: struct {
    dst,src:^Schema,
    dst_hashes:^[dynamic]u64, // of dst, kept up to date
    src_hashes:[dynamic]u64,
    remap:[dynamic]Type_Index, // src index -> dst index, TYPE_NONE until imported
}

schema_import_init :: proc(link:^Schema_Import,dst:^Schema,dst_hashes:^[dynamic]u64,src:^Schema,allocator:=context.allocator) {
    link^={dst=dst,src=src,dst_hashes=dst_hashes}
    link.src_hashes=make([dynamic]u64,allocator)
    link.remap=make([dynamic]Type_Index,allocator)
}
schema_import_destroy :: proc(link:^Schema_Import) {
    delete(link.src_hashes);delete(link.remap)
    link^={}
}

schema_import :: proc(link:^Schema_Import,type:Type_Index) -> Type_Index {
    dst,src:=link.dst,link.src
    if int(type)>=len(src.types) {return TYPE_NONE}
    if !schema_hashes_update(src,&link.src_hashes) || !schema_hashes_update(dst,link.dst_hashes) || reserve(&link.remap,len(src.types))!=nil {return TYPE_NONE}
    for len(link.remap)<len(src.types) {append(&link.remap,TYPE_NONE)}
    if link.remap[type]!=TYPE_NONE {return link.remap[type]}
    source:=src.types[type]
    hash:=link.src_hashes[type]
    for candidate,index in dst.types {
        if candidate.kind==source.kind && candidate.name_hash==source.name_hash && candidate.name==source.name && link.dst_hashes[index]==hash {
            link.remap[type]=Type_Index(index)
            return Type_Index(index)
        }
    }
    copied:=source
    #partial switch source.kind {
    case .Struct:
        fields,error:=make([dynamic]Field,0,int(source.count),context.temp_allocator)
        if error!=nil {return TYPE_NONE}
        defer delete(fields)
        for field in src.fields[source.first:][:source.count] {
            added:=field
            added.type=schema_import(link,field.type)
            if added.type==TYPE_NONE {return TYPE_NONE}
            append(&fields,added)
        }
        if reserve(&dst.fields,len(dst.fields)+len(fields))!=nil {return TYPE_NONE}
        whole:=true
        for &field in fields {
            from:=field
            field.name=schema_string(dst,from.name)
            field.label,field.unit=schema_string(dst,from.label),schema_string(dst,from.unit)
            field.description=schema_string(dst,from.description)
            field.asset_kinds,field.was=schema_string(dst,from.asset_kinds),schema_string(dst,from.was)
            whole&&=len(field.name)==len(from.name) && len(field.label)==len(from.label) && len(field.unit)==len(from.unit) && len(field.description)==len(from.description) && len(field.asset_kinds)==len(from.asset_kinds) && len(field.was)==len(from.was)
        }
        if !whole {
            for field in fields {schema_field_free(dst,field)}
            return TYPE_NONE
        }
        copied.first=u32(len(dst.fields))
        append(&dst.fields,..fields[:])
    case .Enum,.Bit_Set,.Int,.Uint:
        copied.first=u32(len(dst.choices))
        for choice in src.choices[source.first:][:source.count] {
            if schema_choice_add(dst,choice.name,choice.value) {continue}
            copied.name=""
            schema_type_drop(dst,copied)
            return TYPE_NONE
        }
    case .Array:
        copied.elem=schema_import(link,source.elem)
        if copied.elem==TYPE_NONE {return TYPE_NONE}
    }
    copied.name=schema_string(dst,source.name)
    index:=Type_Index(len(dst.types))
    if len(copied.name)!=len(source.name) || reserve(&dst.types,len(dst.types)+1)!=nil {
        schema_type_drop(dst,copied)
        return TYPE_NONE
    }
    append(&dst.types,copied)
    if !schema_hashes_update(dst,link.dst_hashes) {return TYPE_NONE}
    link.remap[type]=index
    return index
}

// An exact copy: the same types, fields and choices at the same indices.
// Without memory dst is left with nothing.
schema_clone :: proc(dst:^Schema,src:^Schema,allocator:=context.allocator) -> Schema_Error {
    schema_init(dst,allocator)
    if reserve(&dst.types,len(src.types))!=nil || reserve(&dst.fields,len(src.fields))!=nil || reserve(&dst.choices,len(src.choices))!=nil {
        schema_destroy(dst)
        return .Out_Of_Memory
    }
    whole:=true
    for type in src.types {
        copied:=type
        copied.name=schema_string(dst,type.name)
        append(&dst.types,copied)
        whole&&=len(copied.name)==len(type.name)
    }
    for field in src.fields {
        copied:=field
        copied.name=schema_string(dst,field.name)
        copied.label,copied.unit=schema_string(dst,field.label),schema_string(dst,field.unit)
        copied.description=schema_string(dst,field.description)
        copied.asset_kinds,copied.was=schema_string(dst,field.asset_kinds),schema_string(dst,field.was)
        append(&dst.fields,copied)
        whole&&=len(copied.name)==len(field.name) && len(copied.label)==len(field.label) && len(copied.unit)==len(field.unit) && len(copied.description)==len(field.description) && len(copied.asset_kinds)==len(field.asset_kinds) && len(copied.was)==len(field.was)
    }
    for choice in src.choices {
        name:=schema_string(dst,choice.name)
        append(&dst.choices,Choice{name,choice.value})
        whole&&=len(name)==len(choice.name)
    }
    if !whole {
        schema_destroy(dst)
        return .Out_Of_Memory
    }
    return .None
}
