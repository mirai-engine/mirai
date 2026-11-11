package serial

import "base:intrinsics"
import "core:math"
import "core:mem"
import "mirai:std/base"

// Access to a part of a value by path: field names joined by dots and array
// indices in brackets, "a.b[2].c". A name after a bit set is one of its
// members, read and written as a bool. The empty path is the value itself.

Value :: union {
    bool,
    i64,
    u64,
    f64,
    string, // an enum member, or the text of a text field
    base.Entity,
    base.Entity_Id,
    base.Asset_Id,
}

Path_Error :: enum u8 {
    None,
    Syntax,
    Unknown_Field,
    Not_A_Struct,   // a name after something without fields
    Not_An_Array,   // an index after something that is not an array
    Out_Of_Range,   // an index past its array, or a number its field cannot hold
    Not_A_Value,    // the path ends on a struct or an array
    Wrong_Type,     // the value is not of the kind of the field
    Unknown_Member, // a name that the enum or bit set does not have
    Too_Long,       // a text longer than its field
    Not_A_Type,     // the type is not of the schema
}

Path_Target :: struct {
    type:Type_Index,
    offset:int,
    field:^Field, // the last field named; nil for the root and for an element
    text:bool,    // a text field: read and written as a string
    bit:int,      // >=0: one member of a bit set
}

// at: where in the path the error is.
path_resolve :: proc(s:^Schema,type:Type_Index,path:string) -> (target:Path_Target,error:Path_Error,at:int) {
    target={type=type,bit=-1}
    if !type_valid(s,type) {return target,.Not_A_Type,0}
    i:=0
    for i<len(path) {
        current:=s.types[target.type]
        if target.bit>=0 {return target,.Not_A_Struct,i}
        if path[i]=='[' {
            start:=i
            i+=1
            index,digits:=u64(0),0
            for i<len(path) && path[i]>='0' && path[i]<='9' {
                index=index*10+u64(path[i]-'0')
                if index>u64(max(u32)) {return target,.Out_Of_Range,start}
                i+=1;digits+=1
            }
            if digits==0 || i>=len(path) || path[i]!=']' {return target,.Syntax,i}
            i+=1
            if current.kind!=.Array {return target,.Not_An_Array,start}
            if index>=u64(current.count) {return target,.Out_Of_Range,start}
            target.offset+=int(index)*int(s.types[current.elem].size)
            target.type,target.field=current.elem,nil
            continue
        }
        if path[i]=='.' {
            if i==0 {return target,.Syntax,i}
            i+=1
        } else if i!=0 {
            return target,.Syntax,i
        }
        start:=i
        for i<len(path) && path[i]!='.' && path[i]!='[' {i+=1}
        name:=path[start:i]
        if name=="" {return target,.Syntax,start}
        #partial switch text_kind(current) {
        case .Struct:
            // A path written before a field was renamed names it by a name it had (was=).
            found:^Field
            fields:=s.fields[current.first:][:current.count]
            for &field in fields {
                if field.name==name {found=&field;break}
            }
            for &field in fields {
                if found==nil && names_hold(field.was,name) {found=&field}
            }
            if found==nil {return target,.Unknown_Field,start}
            target.offset+=int(found.offset)
            target.type,target.field=found.type,found
        case .Bit_Set:
            target.bit=-1
            for choice in s.choices[current.first:][:current.count] {
                if choice.name==name {target.bit=int(choice.value);break}
            }
            if target.bit<0 {return target,.Unknown_Member,start}
        case:
            return target,.Not_A_Struct,start
        }
    }
    target.text=target.field!=nil && .Text in target.field.flags && type_is_bytes(s,target.type)
    return target,.None,0
}

// The bytes of the part of a value a path names, and its type.
value_slice :: proc(s:^Schema,type:Type_Index,data:[]u8,path:string) -> (part:Type_Index,bytes:[]u8,error:Path_Error) {
    target,resolve_error,_:=path_resolve(s,type,path)
    if resolve_error!=.None {return TYPE_NONE,nil,resolve_error}
    if target.bit>=0 {return TYPE_NONE,nil,.Not_A_Value}
    size:=int(s.types[target.type].size)
    if target.offset+size>len(data) {return TYPE_NONE,nil,.Out_Of_Range}
    return target.type,data[target.offset:][:size],.None
}

// The text of a text field: its bytes up to the first NUL.
text_field :: proc(bytes:[]u8) -> string {
    for b,i in bytes {
        if b==0 {return string(bytes[:i])}
    }
    return string(bytes)
}

@(private)
scalar_unsigned :: proc(bytes:[]u8) -> u64 {
    value:u64
    intrinsics.mem_copy_non_overlapping(&value,raw_data(bytes),min(len(bytes),8))
    return value
}
@(private)
scalar_signed :: proc(bytes:[]u8) -> i64 {
    switch len(bytes) {
    case 1: return i64(intrinsics.unaligned_load((^i8)(raw_data(bytes))))
    case 2: return i64(intrinsics.unaligned_load((^i16)(raw_data(bytes))))
    case 4: return i64(intrinsics.unaligned_load((^i32)(raw_data(bytes))))
    }
    return intrinsics.unaligned_load((^i64)(raw_data(bytes)))
}
@(private)
scalar_float :: proc(bytes:[]u8) -> f64 {
    switch len(bytes) {
    case 2: return f64(intrinsics.unaligned_load((^f16)(raw_data(bytes))))
    case 4: return f64(intrinsics.unaligned_load((^f32)(raw_data(bytes))))
    }
    return intrinsics.unaligned_load((^f64)(raw_data(bytes)))
}
// An enum reads its value signed when it has a negative member.
@(private)
enum_value :: proc(s:^Schema,type:Type,bytes:[]u8) -> i64 {
    for choice in s.choices[type.first:][:type.count] {
        if choice.value<0 {return scalar_signed(bytes)}
    }
    return i64(scalar_unsigned(bytes))
}
// Sets the low bytes of an integer and extends a 16-byte one with its sign.
scalar_store :: proc(bytes:[]u8,value:u64,negative:=false) {
    value:=value
    mem.set(raw_data(bytes),negative?0xff:0,len(bytes))
    intrinsics.mem_copy_non_overlapping(raw_data(bytes),&value,min(len(bytes),8))
}

// The value at a path. A string points into data. An enum whose value is not
// one of its members comes back as its number, and a bit set as its bits.
value_get :: proc(s:^Schema,type:Type_Index,data:[]u8,path:string) -> (value:Value,error:Path_Error) {
    target,resolve_error,_:=path_resolve(s,type,path)
    if resolve_error!=.None {return nil,resolve_error}
    part:=s.types[target.type]
    if target.offset+int(part.size)>len(data) {return nil,.Out_Of_Range}
    bytes:=data[target.offset:][:part.size]
    if target.bit>=0 {return bytes[target.bit>>3]&(1<<uint(target.bit&7))!=0,.None}
    if target.text {return text_field(bytes),.None}
    switch text_kind(part) {
    case .Bool: return scalar_unsigned(bytes)!=0,.None
    case .Int: return scalar_signed(bytes),.None
    case .Uint,.Bit_Set: return scalar_unsigned(bytes),.None
    case .Float: return scalar_float(bytes),.None
    case .Enum:
        number:=enum_value(s,part,bytes)
        for choice in s.choices[part.first:][:part.count] {
            if choice.value==number {return choice.name,.None}
        }
        return number,.None
    case .Entity: return base.Entity(scalar_unsigned(bytes)),.None
    case .Entity_Id: return base.Entity_Id(scalar_unsigned(bytes)),.None
    case .Asset: return intrinsics.unaligned_load((^base.Asset_Id)(raw_data(bytes))),.None
    case .Struct,.Array,.Slice,.String,.Json:
    }
    return nil,.Not_A_Value
}

// Writes the value at a path. A number has to fit its field exactly: there is
// no rounding of a fraction into an integer and no saturation.
value_set :: proc(s:^Schema,type:Type_Index,data:[]u8,path:string,value:Value) -> Path_Error {
    target,resolve_error,_:=path_resolve(s,type,path)
    if resolve_error!=.None {return resolve_error}
    part:=s.types[target.type]
    if target.offset+int(part.size)>len(data) {return .Out_Of_Range}
    bytes:=data[target.offset:][:part.size]
    if target.bit>=0 {
        flag,is_bool:=value.(bool)
        if !is_bool {return .Wrong_Type}
        if flag {bytes[target.bit>>3]|=1<<uint(target.bit&7)}
        else {bytes[target.bit>>3]&~=1<<uint(target.bit&7)}
        return .None
    }
    if target.text {
        text,is_string:=value.(string)
        if !is_string {return .Wrong_Type}
        if len(text)>len(bytes) {return .Too_Long}
        mem.zero_slice(bytes)
        copy(bytes,text)
        return .None
    }
    switch text_kind(part) {
    case .Bool:
        flag,is_bool:=value.(bool)
        if !is_bool {return .Wrong_Type}
        scalar_store(bytes,u64(flag))
    case .Int:
        number,error:=value_integer(value,true,min(uint(part.size),8)*8)
        if error!=.None {return error}
        scalar_store(bytes,u64(number),number<0)
    case .Uint:
        number,error:=value_integer(value,false,min(uint(part.size),8)*8)
        if error!=.None {return error}
        scalar_store(bytes,u64(number))
    case .Bit_Set:
        bits,is_bits:=value.(u64)
        if !is_bits {return .Wrong_Type}
        if part.size<8 && bits>>(part.size*8)!=0 {return .Out_Of_Range}
        scalar_store(bytes,bits)
    case .Float:
        number:f64
        #partial switch v in value {
        case f64: number=v
        case i64: number=f64(v)
        case u64: number=f64(v)
        case: return .Wrong_Type
        }
        switch part.size {
        case 2:
            narrow:=f16(number)
            if f64(narrow)-f64(narrow)!=0 && number-number==0 {return .Out_Of_Range}
            intrinsics.unaligned_store((^f16)(raw_data(bytes)),narrow)
        case 4:
            narrow:=f32(number)
            if f64(narrow)-f64(narrow)!=0 && number-number==0 {return .Out_Of_Range}
            intrinsics.unaligned_store((^f32)(raw_data(bytes)),narrow)
        case 8:
            intrinsics.unaligned_store((^f64)(raw_data(bytes)),number)
        }
    case .Enum:
        #partial switch v in value {
        case string:
            for choice in s.choices[part.first:][:part.count] {
                if choice.name==v {scalar_store(bytes,u64(choice.value));return .None}
            }
            return .Unknown_Member
        case i64,u64:
            number:=i64(0)
            if signed,is_signed:=v.(i64);is_signed {number=signed}
            else {number=i64(v.(u64))}
            for choice in s.choices[part.first:][:part.count] {
                if choice.value==number {scalar_store(bytes,u64(number));return .None}
            }
            return .Unknown_Member
        case:
            return .Wrong_Type
        }
    case .Entity:
        entity,ok:=value.(base.Entity)
        if !ok {return .Wrong_Type}
        scalar_store(bytes,u64(entity))
    case .Entity_Id:
        id,ok:=value.(base.Entity_Id)
        if !ok {return .Wrong_Type}
        scalar_store(bytes,u64(id))
    case .Asset:
        id,ok:=value.(base.Asset_Id)
        if !ok {return .Wrong_Type}
        intrinsics.unaligned_store((^base.Asset_Id)(raw_data(bytes)),id)
    case .Struct,.Array,.Slice,.String,.Json:
        return .Not_A_Value
    }
    return .None
}

// An integer of the width given out of a number, when it holds one exactly.
// The result carries the bits of a u64 when signed is false.
@(private)
value_integer :: proc(value:Value,signed:bool,bits:uint) -> (number:i64,error:Path_Error) {
    #partial switch v in value {
    case i64:
        if signed {
            if v<min(i64)>>(64-bits) || v>max(i64)>>(64-bits) {return 0,.Out_Of_Range}
        } else if v<0 || u64(v)>max(u64)>>(64-bits) {
            return 0,.Out_Of_Range
        }
        return v,.None
    case u64:
        if v>(signed?u64(max(i64)>>(64-bits)):max(u64)>>(64-bits)) {return 0,.Out_Of_Range}
        return i64(v),.None
    case f64:
        if v!=v || v<-9223372036854775808.0 || v>=18446744073709551616.0 || v!=math.trunc(v) {return 0,.Out_Of_Range}
        if v<0 {return value_integer(i64(v),signed,bits)}
        return value_integer(u64(v),signed,bits)
    }
    return 0,.Wrong_Type
}
