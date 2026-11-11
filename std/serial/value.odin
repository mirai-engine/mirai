package serial

import "base:intrinsics"
import "core:math"
import "core:mem"
import "core:strings"
import "mirai:std/base"

// The saved form of a value is its image: the bytes it has in memory under
// its schema, with padding, transient fields and whatever follows the end of
// a text set to zero, so equal values are equal bytes. An image whose stored
// type has the layout hash of the type that reads it is copied whole, or
// used in place; any other is migrated field by field, matching names.

Run :: struct {offset,size:u32}

// Which bytes of a value of one type hold data.
Layout :: struct {
    size:int,
    dense:bool,         // every byte is data: values are copied whole
    runs:[dynamic]Run,  // data, in order
    texts:[dynamic]Run, // fields holding NUL-terminated text
}

// A type that is not of the schema has no bytes.
layout_init :: proc(l:^Layout,s:^Schema,type:Type_Index,allocator:=context.allocator) {
    l^={size=type_valid(s,type)?int(s.types[type].size):0}
    l.runs=make([dynamic]Run,allocator)
    l.texts=make([dynamic]Run,allocator)
    if type_valid(s,type) {layout_add(l,s,type,0)}
    l.dense=len(l.texts)==0 && len(l.runs)==1 && l.runs[0]==Run{0,u32(l.size)} || l.size==0
}
layout_destroy :: proc(l:^Layout) {
    delete(l.runs);delete(l.texts)
    l^={}
}

@(private="file")
layout_run :: proc(l:^Layout,offset,size:u32) {
    if size==0 {return}
    if count:=len(l.runs);count>0 && l.runs[count-1].offset+l.runs[count-1].size==offset {
        l.runs[count-1].size+=size
        return
    }
    append(&l.runs,Run{offset,size})
}

@(private="file")
layout_add :: proc(l:^Layout,s:^Schema,index:Type_Index,offset:u32) {
    type:=s.types[index]
    #partial switch type.kind {
    case .Struct:
        for field in s.fields[type.first:][:type.count] {
            if .Transient in field.flags {continue}
            if .Text in field.flags && type_is_bytes(s,field.type) {
                layout_run(l,offset+field.offset,s.types[field.type].size)
                append(&l.texts,Run{offset+field.offset,s.types[field.type].size})
                continue
            }
            layout_add(l,s,field.type,offset+field.offset)
        }
    case .Array:
        elem:=s.types[type.elem]
        // Elements without fields are one run.
        if elem.kind!=.Struct && elem.kind!=.Array {
            layout_run(l,offset,type.count*elem.size)
            return
        }
        for i in 0..<type.count {layout_add(l,s,type.elem,offset+i*elem.size)}
    case:
        layout_run(l,offset,type.size)
    }
}

// An array of one-byte integers: what a text field is.
// A fixed array of texts: a text field of this type is a list of strings.
type_is_texts :: proc(s:^Schema,index:Type_Index) -> bool {
    return type_valid(s,index) && s.types[index].kind==.Array && type_is_bytes(s,s.types[index].elem)
}

type_is_bytes :: proc(s:^Schema,index:Type_Index) -> bool {
    if !type_valid(s,index) {return false}
    type:=s.types[index]
    if type.kind!=.Array {return false}
    elem:=s.types[type.elem]
    return (elem.kind==.Uint || elem.kind==.Int) && elem.size==1
}

// Writes into dst the images of count values that start at src. Without
// room in dst for all of them, or without src, it writes nothing.
value_write :: proc(l:^Layout,dst:[]u8,src:rawptr,count:int) {
    if count<=0 || l.size==0 || src==nil || count>len(dst)/l.size {return}
    if l.dense {
        intrinsics.mem_copy_non_overlapping(raw_data(dst),src,count*l.size)
        return
    }
    mem.zero(raw_data(dst),count*l.size)
    from:=([^]u8)(src)
    for i in 0..<count {
        base:=i*l.size
        for run in l.runs {
            intrinsics.mem_copy_non_overlapping(&dst[base+int(run.offset)],&from[base+int(run.offset)],int(run.size))
        }
        for text in l.texts {
            bytes:=dst[base+int(text.offset):][:text.size]
            for b,at in bytes {
                if b==0 {mem.zero_slice(bytes[at:]);break}
            }
        }
    }
}

// --------------------------------------------------------------- migration

@(private="file")
Op_Kind :: enum u8 {
    Copy,   // size bytes
    Zero,   // size bytes of the destination
    Number, // one scalar, converted by value
    Enum,   // a value looked up in pairs
    Flags,  // bits moved one by one, by pairs
    Loop,   // the next `body` ops, `size` times
}

@(private="file")
Number_Class :: enum u8 {Bool,Signed,Unsigned,Float}

@(private="file")
Op :: struct {
    kind:Op_Kind,
    src_class,dst_class:Number_Class,
    src_size,dst_size:u8,
    src_offset,dst_offset:u32,
    size:u32,
    first,count:u32, // pairs
    body:u32,
    src_stride,dst_stride:u32,
    full:bool, // Flags between masks of integers: every bit set stays every bit set
}

@(private="file")
Pair :: struct {from,to:i64}

// How values of a stored type become values of another. Fields are matched by
// name, or by a name the destination field had (Field.was), so a renamed field
// keeps its value. Numbers convert by value and saturate at the range of the
// destination; enum values and bit set members move by member name, and so do
// the values and bits of an integer whose numbers are generated (by_name),
// where a mask with every bit set stays so; arrays
// keep the elements both lengths have. A destination field without a source,
// or whose source is of another shape, keeps what the destination had: the
// default the caller gives. Transient fields end as zero.
Migration :: struct {
    src_size,dst_size:int,
    identical:bool, // same layout and nothing transient: values are copied whole
    ops:[dynamic]Op,
    pairs:[dynamic]Pair,
    added:int,      // destination fields without a source field
    lacking:string, // the first of them, named by the destination schema
    // What the stored values lose, by the path of the field in the source: a
    // name of the source schema, or in temporary memory for a field inside
    // another. Fields the destination has under no name (transient ones aside):
    removed:[dynamic]string,
    incompatible:[dynamic]string, // fields of both whose types cannot be converted: the destination keeps its default
}

// With a type that is not of its schema, or without memory, the migration
// converts nothing and holds nothing.
migration_init :: proc(m:^Migration,src:^Schema,src_type:Type_Index,dst:^Schema,dst_type:Type_Index,allocator:=context.allocator) -> Schema_Error {
    m^={}
    m.ops=make([dynamic]Op,allocator)
    m.pairs=make([dynamic]Pair,allocator)
    m.removed=make([dynamic]string,allocator)
    m.incompatible=make([dynamic]string,allocator)
    if !type_valid(src,src_type) || !type_valid(dst,dst_type) {return .Invalid_Type}
    build:=Build{m=m,src=src,dst=dst}
    build.src_hashes=make([dynamic]u64,context.temp_allocator)
    build.dst_hashes=make([dynamic]u64,context.temp_allocator)
    defer delete(build.src_hashes)
    defer delete(build.dst_hashes)
    transient,error:=make([]bool,len(dst.types),context.temp_allocator)
    if error!=nil {return .Out_Of_Memory}
    build.transient=transient
    defer delete(transient,context.temp_allocator)
    if !schema_hashes_update(src,&build.src_hashes) || !schema_hashes_update(dst,&build.dst_hashes) {return .Out_Of_Memory}
    for type,index in dst.types {
        #partial switch type.kind {
        case .Struct:
            for field in dst.fields[type.first:][:type.count] {
                if .Transient in field.flags || build.transient[field.type] {build.transient[index]=true}
            }
        case .Array:
            build.transient[index]=build.transient[type.elem]
        }
    }
    m.src_size,m.dst_size=int(src.types[src_type].size),int(dst.types[dst_type].size)
    migration_build(&build,src_type,dst_type,0,0,"")
    if build.refused {
        migration_destroy(m)
        return .Out_Of_Memory
    }
    m.identical=len(m.ops)==1 && m.ops[0].kind==.Copy && int(m.ops[0].size)==m.dst_size && m.src_size==m.dst_size || m.src_size==0 && m.dst_size==0
    return .None
}
migration_destroy :: proc(m:^Migration) {
    delete(m.ops);delete(m.pairs);delete(m.removed);delete(m.incompatible)
    m^={}
}

// Converts count values. dst starts as copies of default when it is given
// (one value of the destination type), and as zeros otherwise. Without room
// for count values in dst or src, or with a shorter default, it converts
// nothing.
migration_apply :: proc(m:^Migration,dst:[]u8,src:[]u8,count:int,default:[]u8=nil) {
    if count<=0 || m.dst_size==0 || count>len(dst)/m.dst_size {return}
    if m.src_size>0 && count>len(src)/m.src_size {return}
    if default!=nil && len(default)<m.dst_size {return}
    if m.identical {
        intrinsics.mem_copy_non_overlapping(raw_data(dst),raw_data(src),count*m.dst_size)
        return
    }
    from,to:=raw_data(src),raw_data(dst)
    for i in 0..<count {
        target:=to[i*m.dst_size:]
        if default!=nil {intrinsics.mem_copy_non_overlapping(target,raw_data(default),m.dst_size)}
        else {mem.zero(target,m.dst_size)}
        migration_run(m,m.ops[:],from[i*m.src_size:],target)
    }
}

@(private="file")
Build :: struct {
    m:^Migration,
    src,dst:^Schema,
    src_hashes,dst_hashes:[dynamic]u64,
    transient:[]bool, // destination types with a transient field somewhere inside
    barrier:int,      // ops before this one belong to a finished loop: nothing merges into them
    refused:bool,     // an op or a pair found no memory
}

@(private="file")
build_copy :: proc(b:^Build,src_offset,dst_offset,size:u32) {
    if size==0 {return}
    ops:=&b.m.ops
    if count:=len(ops);count>b.barrier {
        last:=&ops[count-1]
        if last.kind==.Copy && last.src_offset+last.size==src_offset && last.dst_offset+last.size==dst_offset {
            last.size+=size
            return
        }
    }
    build_op(b,Op{kind=.Copy,src_offset=src_offset,dst_offset=dst_offset,size=size})
}

@(private="file")
build_op :: proc(b:^Build,op:Op) {
    if _,err:=append(&b.m.ops,op);err!=nil {b.refused=true}
}

@(private="file")
build_pair :: proc(b:^Build,pair:Pair) {
    if _,err:=append(&b.m.pairs,pair);err!=nil {b.refused=true}
}

@(private="file")
number_class :: proc(s:^Schema,index:Type_Index) -> (class:Number_Class,ok:bool) {
    type:=s.types[index]
    #partial switch type.kind {
    case .Bool: return .Bool,true
    case .Int: return .Signed,true
    case .Uint,.Bit_Set,.Entity,.Entity_Id: return .Unsigned,true
    case .Float: return .Float,true
    case .Enum:
        for choice in s.choices[type.first:][:type.count] {
            if choice.value<0 {return .Signed,true}
        }
        return .Unsigned,true
    }
    return .Bool,false
}

@(private="file")
migration_build :: proc(b:^Build,src_index,dst_index:Type_Index,src_offset,dst_offset:u32,path:string) {
    src_type,dst_type:=b.src.types[src_index],b.dst.types[dst_index]
    if dst_type.size==0 || src_type.size==0 {return}
    if b.src_hashes[src_index]==b.dst_hashes[dst_index] && !b.transient[dst_index] {
        build_copy(b,src_offset,dst_offset,dst_type.size)
        return
    }
    m:=b.m
    switch {
    case src_type.kind==.Struct && dst_type.kind==.Struct:
        src_fields:=b.src.fields[src_type.first:][:src_type.count]
        dst_fields:=b.dst.fields[dst_type.first:][:dst_type.count]
        // Large structs look their fields up through a map; small ones scan.
        lookup:map[u64]int
        if len(src_fields)>32 {
            lookup=make(map[u64]int,len(src_fields),context.temp_allocator)
            #reverse for field,at in src_fields {lookup[field.name_hash]=at}
        }
        used,no_used:=make([]bool,len(src_fields),context.temp_allocator)
        if no_used!=nil {
            b.refused=true
            return
        }
        for field in dst_fields {
            size:=b.dst.types[field.type].size
            at:=field_source(src_fields,lookup,field)
            if at>=0 {used[at]=true}
            if .Transient in field.flags {
                if size>0 {build_op(b,Op{kind=.Zero,dst_offset=dst_offset+field.offset,size=size})}
                continue
            }
            if at<0 || .Transient in src_fields[at].flags {
                if m.added==0 {m.lacking=field.name}
                m.added+=1
                continue
            }
            if .Text in field.flags && type_is_bytes(b.dst,field.type) && type_is_bytes(b.src,src_fields[at].type) {
                // A text keeps the bytes that fit; what follows them is zero, not the default.
                kept:=min(size,b.src.types[src_fields[at].type].size)
                build_copy(b,src_offset+src_fields[at].offset,dst_offset+field.offset,kept)
                if size>kept {build_op(b,Op{kind=.Zero,dst_offset=dst_offset+field.offset+kept,size=size-kept})}
                continue
            }
            migration_build(b,src_fields[at].type,field.type,src_offset+src_fields[at].offset,dst_offset+field.offset,field_path(path,src_fields[at].name))
        }
        for field,at in src_fields {
            if !used[at] && .Transient not_in field.flags {build_lost(b,&m.removed,field_path(path,field.name))}
        }
    case src_type.kind==.Array && dst_type.kind==.Array:
        count:=min(src_type.count,dst_type.count)
        src_elem,dst_elem:=b.src.types[src_type.elem],b.dst.types[dst_type.elem]
        if count==0 || src_elem.size==0 || dst_elem.size==0 {return}
        if b.src_hashes[src_type.elem]==b.dst_hashes[dst_type.elem] && !b.transient[dst_type.elem] {
            build_copy(b,src_offset,dst_offset,count*dst_elem.size)
            return
        }
        loop:=len(m.ops)
        build_op(b,Op{kind=.Loop,src_offset=src_offset,dst_offset=dst_offset,size=count,src_stride=src_elem.size,dst_stride=dst_elem.size})
        if b.refused {return}
        migration_build(b,src_type.elem,dst_type.elem,0,0,path)
        body:=len(m.ops)-loop-1
        if body==0 {pop(&m.ops)}
        else {m.ops[loop].body=u32(body);b.barrier=len(m.ops)}
    case src_type.kind==.Asset || dst_type.kind==.Asset || src_type.kind==.Struct || dst_type.kind==.Struct || src_type.kind==.Array || dst_type.kind==.Array:
        build_lost(b,&m.incompatible,path)
    case moves_values(dst_type) && names_values(src_type):
        first:=len(m.pairs)
        for from in b.src.choices[src_type.first:][:src_type.count] {
            for to in b.dst.choices[dst_type.first:][:dst_type.count] {
                if to.name==from.name {build_pair(b,Pair{from.value,to.value});break}
            }
        }
        class,_:=number_class(b.src,src_index)
        build_op(b,Op{kind=.Enum,src_class=class,src_size=u8(src_type.size),dst_size=u8(dst_type.size),src_offset=src_offset,dst_offset=dst_offset,first=u32(first),count=u32(len(m.pairs)-first)})
    case moves_values(dst_type):
        // A number becomes the member with its value, when there is one.
        class,_:=number_class(b.src,src_index)
        if class==.Float || class==.Bool {build_lost(b,&m.incompatible,path);return}
        first:=len(m.pairs)
        for to in b.dst.choices[dst_type.first:][:dst_type.count] {build_pair(b,Pair{to.value,to.value})}
        build_op(b,Op{kind=.Enum,src_class=class,src_size=u8(src_type.size),dst_size=u8(dst_type.size),src_offset=src_offset,dst_offset=dst_offset,first=u32(first),count=u32(len(m.pairs)-first)})
    case moves_bits(dst_type) && names_bits(src_type):
        first:=len(m.pairs)
        for from in b.src.choices[src_type.first:][:src_type.count] {
            for to in b.dst.choices[dst_type.first:][:dst_type.count] {
                if to.name==from.name {build_pair(b,Pair{from.value,to.value});break}
            }
        }
        full:=src_type.named==.Bits && dst_type.named==.Bits
        build_op(b,Op{kind=.Flags,src_size=u8(src_type.size),dst_size=u8(dst_type.size),src_offset=src_offset,dst_offset=dst_offset,first=u32(first),count=u32(len(m.pairs)-first),full=full})
    case:
        src_class,_:=number_class(b.src,src_index)
        dst_class,_:=number_class(b.dst,dst_index)
        if src_class==dst_class && src_type.size==dst_type.size {
            build_copy(b,src_offset,dst_offset,dst_type.size)
            return
        }
        build_op(b,Op{kind=.Number,src_class=src_class,dst_class=dst_class,src_size=u8(src_type.size),dst_size=u8(dst_type.size),src_offset=src_offset,dst_offset=dst_offset})
    }
}

// The source field a destination field reads: the one with its name, else the
// one with a name it had, else the one that had its name (a source newer than
// the destination); -1 for none.
@(private="file")
field_source :: proc(fields:[]Field,lookup:map[u64]int,field:Field) -> int {
    find :: proc(fields:[]Field,lookup:map[u64]int,hash:u64) -> int {
        if lookup!=nil {return lookup[hash] or_else -1}
        for candidate,i in fields {
            if candidate.name_hash==hash {return i}
        }
        return -1
    }
    if at:=find(fields,lookup,field.name_hash);at>=0 {return at}
    rest:=field.was
    for name in strings.fields_iterator(&rest) {
        if at:=find(fields,lookup,base.name_hash(name));at>=0 {return at}
    }
    for candidate,at in fields {
        if names_hold(candidate.was,field.name) {return at}
    }
    return -1
}

// Whether a list of names separated by spaces (was=) holds a name.
names_hold :: proc(names,name:string) -> bool {
    rest:=names
    for held in strings.fields_iterator(&rest) {
        if held==name {return true}
    }
    return false
}

@(private="file")
field_path :: proc(path,name:string) -> string {
    return path=="" ? name : strings.concatenate({path,".",name},context.temp_allocator)
}

@(private="file")
build_lost :: proc(b:^Build,list:^[dynamic]string,path:string) {
    if _,err:=append(list,path);err!=nil {b.refused=true}
}

// A type whose values have names, and one whose values move by them: an
// enum, or an integer @(names) whose numbers are generated.
@(private="file")
names_values :: proc "contextless" (type:Type) -> bool {return type.kind==.Enum || type.named==.Values}
@(private="file")
moves_values :: proc "contextless" (type:Type) -> bool {return type.kind==.Enum || type.named==.Values && type.by_name}

// The same of the bits: a bit set, or a mask of such an integer.
@(private="file")
names_bits :: proc "contextless" (type:Type) -> bool {return type.kind==.Bit_Set || type.named==.Bits}
@(private="file")
moves_bits :: proc "contextless" (type:Type) -> bool {return type.kind==.Bit_Set || type.named==.Bits && type.by_name}

// Whether the low size bytes of a mask have every bit set.
@(private="file")
mask_full :: #force_inline proc "contextless" (mask:[2]u64,size:u8) -> bool {
    switch size {
    case 16: return mask=={max(u64),max(u64)}
    case 8:  return mask[0]==max(u64)
    }
    return mask[0]==u64(1)<<(u64(size)*8)-1
}

@(private="file")
load_unsigned :: #force_inline proc "contextless" (p:[^]u8,size:u8) -> u64 {
    switch size {
    case 1: return u64(p[0])
    case 2: return u64(intrinsics.unaligned_load((^u16)(p)))
    case 4: return u64(intrinsics.unaligned_load((^u32)(p)))
    }
    return intrinsics.unaligned_load((^u64)(p)) // 16 bytes: the low half
}
@(private="file")
load_signed :: #force_inline proc "contextless" (p:[^]u8,size:u8) -> i64 {
    switch size {
    case 1: return i64(intrinsics.unaligned_load((^i8)(p)))
    case 2: return i64(intrinsics.unaligned_load((^i16)(p)))
    case 4: return i64(intrinsics.unaligned_load((^i32)(p)))
    }
    return intrinsics.unaligned_load((^i64)(p))
}
@(private="file")
load_float :: #force_inline proc "contextless" (p:[^]u8,size:u8) -> f64 {
    switch size {
    case 2: return f64(intrinsics.unaligned_load((^f16)(p)))
    case 4: return f64(intrinsics.unaligned_load((^f32)(p)))
    }
    return intrinsics.unaligned_load((^f64)(p))
}
// The low size bytes of value; a 16-byte integer is extended with fill.
@(private="file")
store_bits :: #force_inline proc "contextless" (p:[^]u8,size:u8,value:u64,fill:u64=0) {
    switch size {
    case 1: p[0]=u8(value)
    case 2: intrinsics.unaligned_store((^u16)(p),u16(value))
    case 4: intrinsics.unaligned_store((^u32)(p),u32(value))
    case 8: intrinsics.unaligned_store((^u64)(p),value)
    case 16:
        intrinsics.unaligned_store((^u64)(p),value)
        intrinsics.unaligned_store((^u64)(p[8:]),fill)
    }
}

// A number as the destination holds it. Out of range saturates; NaN is zero for an integer.
@(private)
number_store :: proc "contextless" (p:[^]u8,class:Number_Class,size:u8,signed:i64,unsigned:u64,float:f64,from:Number_Class) {
    bits:=min(uint(size),8)*8
    switch class {
    case .Bool:
        truth:=false
        switch from {
        case .Bool,.Unsigned: truth=unsigned!=0
        case .Signed: truth=signed!=0
        case .Float: truth=float!=0
        }
        store_bits(p,size,u64(truth))
    case .Signed:
        low,high:=i64(min(i64))>>(64-bits),i64(max(i64))>>(64-bits)
        value:i64
        switch from {
        case .Bool,.Unsigned: value=unsigned>u64(high)?high:i64(unsigned)
        case .Signed: value=clamp(signed,low,high)
        case .Float:
            switch {
            case float!=float: value=0
            case float>=9223372036854775808.0: value=high
            case float<=-9223372036854775808.0: value=low
            case: value=clamp(i64(float),low,high)
            }
        }
        store_bits(p,size,u64(value),value<0?max(u64):0)
    case .Unsigned:
        high:=max(u64)>>(64-bits)
        value:u64
        switch from {
        case .Bool,.Unsigned: value=min(unsigned,high)
        case .Signed: value=signed<0?0:min(u64(signed),high)
        case .Float:
            switch {
            case float!=float || float<=0: value=0
            case float>=18446744073709551616.0: value=high
            case: value=min(u64(float),high)
            }
        }
        store_bits(p,size,value)
    case .Float:
        value:f64
        switch from {
        case .Bool,.Unsigned: value=f64(unsigned)
        case .Signed: value=f64(signed)
        case .Float: value=float
        }
        switch size {
        case 2: intrinsics.unaligned_store((^f16)(p),f16(value))
        case 4: intrinsics.unaligned_store((^f32)(p),f32(value))
        case 8: intrinsics.unaligned_store((^f64)(p),value)
        }
    }
}

@(private="file")
migration_run :: proc(m:^Migration,ops:[]Op,src:[^]u8,dst:[^]u8) #no_bounds_check {
    for i:=0;i<len(ops);i+=1 {
        op:=&ops[i]
        from,to:=src[op.src_offset:],dst[op.dst_offset:]
        switch op.kind {
        case .Copy:
            intrinsics.mem_copy_non_overlapping(to,from,int(op.size))
        case .Zero:
            mem.zero(to,int(op.size))
        case .Number:
            signed:i64;unsigned:u64;float:f64
            switch op.src_class {
            case .Bool: unsigned=u64(load_unsigned(from,op.src_size)!=0)
            case .Unsigned: unsigned=load_unsigned(from,op.src_size)
            case .Signed: signed=load_signed(from,op.src_size)
            case .Float: float=load_float(from,op.src_size)
            }
            number_store(to,op.dst_class,op.dst_size,signed,unsigned,float,op.src_class)
        case .Enum:
            value:=op.src_class==.Signed?load_signed(from,op.src_size):i64(load_unsigned(from,op.src_size))
            for pair in m.pairs[op.first:][:op.count] {
                if pair.from==value {store_bits(to,op.dst_size,u64(pair.to));break}
            }
        case .Flags:
            source:[2]u64
            target:[2]u64
            intrinsics.mem_copy_non_overlapping(&source,from,int(op.src_size))
            intrinsics.mem_copy_non_overlapping(&target,to,int(op.dst_size))
            if op.full && mask_full(source,op.src_size) {
                // Every bit: also those of names the source did not have.
                target={max(u64),max(u64)}
            } else {
                for pair in m.pairs[op.first:][:op.count] {
                    bit:=u64(1)<<(u64(pair.to)&63)
                    if source[pair.from>>6]&(1<<(u64(pair.from)&63))!=0 {target[pair.to>>6]|=bit}
                    else {target[pair.to>>6]&~=bit}
                }
            }
            intrinsics.mem_copy_non_overlapping(to,&target,int(op.dst_size))
        case .Loop:
            body:=ops[i+1:][:op.body]
            for k in 0..<op.size {migration_run(m,body,from[k*op.src_stride:],to[k*op.dst_stride:])}
            i+=int(op.body)
        }
    }
}

// Reads count stored values into dst as values of another type. With a layout
// hash in common this is one copy.
value_read :: proc(m:^Migration,dst:rawptr,src:[]u8,count:int,default:rawptr=nil) {
    if dst==nil || count<=0 || m.dst_size==0 || count>max(int)/m.dst_size {return}
    migration_apply(m,([^]u8)(dst)[:count*m.dst_size],src,count,default==nil?nil:([^]u8)(default)[:m.dst_size])
}

// What value_check found wrong in a value.
Value_Fault :: enum u8 {
    None,
    Not_Finite,   // a float that is NaN or infinite
    Below_Min,    // a number under the min of its field
    Above_Max,    // a number over the max of its field
    Not_A_Choice, // a bool that is not 0 or 1, an enum that is none of its values, a bit set with a bit of no member
    Refused,      // a reference the visitor of value_check refused
}

Value_Problem :: struct {
    fault:Value_Fault,
    path:string,    // of the part, as value_get takes it, in the buffer value_check was given
    offset:u32,     // of the part in the value
    kind:Type_Kind, // of the part
    number:f64,     // the number, or the value of the choice
    limit:f64,      // Below_Min and Above_Max: the bound it broke
}

// Whether a reference of a value is acceptable: an Entity, Entity_Id or Asset
// of kind, its bytes in ref.
Value_Ref_Proc :: #type proc(user:rawptr,kind:Type_Kind,ref:[]u8) -> bool

// The first part of a value of a type of the schema that its schema does not
// allow: a float that is not finite, a number outside the min and max of its
// field (each element of an array field), a bool, enum or bit set that holds
// no value of its type, or a reference visit refuses. What the schema does not
// constrain (integers without a range, texts) passes. data holds one value;
// the path of the part is written in path, cut to its length.
value_check :: proc(s:^Schema,type:Type_Index,data:[]u8,path:[]u8,visit:Value_Ref_Proc=nil,user:rawptr=nil) -> Value_Problem {
    if !type_valid(s,type) || int(s.types[type].size)>len(data) {return {}}
    c:=Value_Check{s=s,data=data,path=path,visit=visit,user=user}
    value_check_part(&c,type,0,nil)
    return c.problem
}

@(private="file")
Value_Check :: struct {
    s:^Schema,
    data:[]u8,
    path:[]u8,
    length:int,
    visit:Value_Ref_Proc,
    user:rawptr,
    problem:Value_Problem,
}

@(private="file")
value_path_add :: proc(c:^Value_Check,parts:..string) {
    for part in parts {c.length+=copy(c.path[c.length:],part)}
}

@(private="file")
value_fail :: proc(c:^Value_Check,fault:Value_Fault,offset:u32,kind:Type_Kind,number:f64=0,limit:f64=0) -> bool {
    c.problem={fault,string(c.path[:c.length]),offset,kind,number,limit}
    return false
}

// field: the field the part is, or is an element of: its min and max hold.
@(private="file")
value_check_part :: proc(c:^Value_Check,index:Type_Index,offset:u32,field:^Field) -> bool {
    type:=c.s.types[index]
    bytes:=c.data[offset:][:type.size]
    #partial switch type.kind {
    case .Struct:
        mark:=c.length
        for &inner in c.s.fields[type.first:][:type.count] {
            if mark>0 {value_path_add(c,".")}
            value_path_add(c,inner.name)
            value_check_part(c,inner.type,offset+inner.offset,&inner) or_return
            c.length=mark
        }
    case .Array:
        size:=c.s.types[type.elem].size
        mark:=c.length
        digits:[20]u8
        for i in 0..<type.count {
            value_path_add(c,"[",index_text(int(i),digits[:]),"]")
            value_check_part(c,type.elem,offset+i*size,field) or_return
            c.length=mark
        }
    case .Float:
        number:=scalar_float(bytes)
        if math.is_nan(number) || math.is_inf(number) {return value_fail(c,.Not_Finite,offset,type.kind,number)}
        return value_range(c,field,offset,type.kind,number)
    case .Int:
        return value_range(c,field,offset,type.kind,f64(scalar_signed(bytes)))
    case .Uint:
        return value_range(c,field,offset,type.kind,f64(scalar_unsigned(bytes)))
    case .Bool:
        if value:=scalar_unsigned(bytes);value>1 {return value_fail(c,.Not_A_Choice,offset,type.kind,f64(value))}
    case .Enum:
        value:=enum_value(c.s,type,bytes)
        for choice in c.s.choices[type.first:][:type.count] {
            if choice.value==value {return true}
        }
        return value_fail(c,.Not_A_Choice,offset,type.kind,f64(value))
    case .Bit_Set:
        if type.size>8 {return true}
        members:u64
        for choice in c.s.choices[type.first:][:type.count] {
            if choice.value>=0 && choice.value<64 {members|=1<<u64(choice.value)}
        }
        if value:=scalar_unsigned(bytes);value&~members!=0 {return value_fail(c,.Not_A_Choice,offset,type.kind,f64(value))}
    case .Entity,.Entity_Id,.Asset:
        if c.visit!=nil && !c.visit(c.user,type.kind,bytes) {return value_fail(c,.Refused,offset,type.kind)}
    }
    return true
}

@(private="file")
value_range :: proc(c:^Value_Check,field:^Field,offset:u32,kind:Type_Kind,number:f64) -> bool {
    if field==nil {return true}
    if field.has_min && number<field.min {return value_fail(c,.Below_Min,offset,kind,number,field.min)}
    if field.has_max && number>field.max {return value_fail(c,.Above_Max,offset,kind,number,field.max)}
    return true
}

@(private="file")
index_text :: proc(i:int,buffer:[]u8) -> string {
    n,at:=i,len(buffer)
    for {
        at-=1
        buffer[at]=u8('0'+n%10)
        n/=10
        if n==0 || at==0 {break}
    }
    return string(buffer[at:])
}
