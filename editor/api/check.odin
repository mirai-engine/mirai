package api

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"
import "mirai:std/serial"

// What reading params into a struct does not prove: required fields, the
// length of arrays of numbers, finite floats, ranges, and members of enums and
// bit sets. Both passes run on params that serial.text_read already accepted.

@(private)
Checker :: struct {
    server:^Server,
    schema:^serial.Schema, // of the value being checked
    allocator:runtime.Allocator,
    path:[128]u8,
    path_len:int,
    message:string,
    clamped:string, // what the params asked past a maximum, as members of _clamped
}

@(private)
path_name :: proc(c:^Checker,name:string) {
    if c.path_len>0 && c.path_len<len(c.path) {c.path[c.path_len]='.';c.path_len+=1}
    n:=min(len(name),len(c.path)-c.path_len)
    copy(c.path[c.path_len:],name[:n])
    c.path_len+=n
}
@(private)
path_index :: proc(c:^Checker,index:int) {
    digits:[20]u8
    n:=len(digits)
    for value:=index;;value/=10 {
        n-=1
        digits[n]=u8('0'+value%10)
        if value<10 {break}
    }
    if c.path_len+2+len(digits)-n>len(c.path) {return}
    c.path[c.path_len]='[';c.path_len+=1
    copy(c.path[c.path_len:],digits[n:])
    c.path_len+=len(digits)-n
    c.path[c.path_len]=']';c.path_len+=1
}
@(private)
check_fail :: proc(c:^Checker,format:string,args:..any) -> bool {
    what:=format_text(c.allocator,format,..args)
    where_:=c.path_len>0?string(c.path[:c.path_len]):"params"
    c.message=format_text(c.allocator,"%s %s",where_,what)
    return false
}

@(private)
is_number_kind :: #force_inline proc(kind:serial.Type_Kind) -> bool {return kind==.Float || kind==.Int || kind==.Uint}

@(private)
check_required :: proc(c:^Checker,r:^serial.Text_Reader,index:serial.Type_Index) -> bool {
    s:=c.schema
    type:=s.types[index]
    #partial switch type.kind {
    case .Struct:
        if !serial.text_accept(r,'{') {return serial.text_skip(r)}
        seen:bit_set[0..<MAX_STRUCT_FIELDS;u128]
        fields:=s.fields[type.first:][:type.count]
        if !serial.text_accept(r,'}') {
            for {
                name,_:=serial.text_string(r)
                found:=-1
                for &f,i in fields {if f.name==name {found=i;break}}
                serial.text_expect(r,':')
                if found<0 {
                    serial.text_skip(r) or_return
                } else {
                    seen+={found}
                    f:=&fields[found]
                    mark:=c.path_len
                    path_name(c,f.name)
                    ok:=false
                    if .Text in f.flags && serial.type_is_bytes(s,f.type) {ok=serial.text_skip(r)} else {ok=check_required(c,r,f.type)}
                    c.path_len=mark
                    if !ok {return false}
                }
                if serial.text_accept(r,',') {continue}
                serial.text_expect(r,'}') or_return
                break
            }
        }
        for &f,i in fields {
            if field_visible(&f) && .Optional not_in f.hints && i not_in seen {
                path_name(c,f.name)
                return check_fail(c,"is required")
            }
        }
        return true
    case .Array:
        if !serial.text_accept(r,'[') {return serial.text_skip(r)}
        elem:=s.types[type.elem]
        nested:=elem.kind==.Struct || elem.kind==.Array
        n:=0
        if !serial.text_accept(r,']') {
            for {
                mark:=c.path_len
                path_index(c,n)
                ok:=nested?check_required(c,r,type.elem):serial.text_skip(r)
                c.path_len=mark
                if !ok {return false}
                n+=1
                if serial.text_accept(r,',') {continue}
                serial.text_expect(r,']') or_return
                break
            }
        }
        if is_number_kind(elem.kind) && n!=int(type.count) {return check_fail(c,"must have %d elements, not %d",type.count,n)}
        return true
    case .Slice:
        if !serial.text_accept(r,'[') {return serial.text_skip(r)}
        elem:=s.types[type.elem]
        if elem.kind!=.Struct && elem.kind!=.Array && elem.kind!=.Slice {
            r.offset-=1
            return serial.text_skip(r)
        }
        if serial.text_accept(r,']') {return true}
        for n:=0;;n+=1 {
            mark:=c.path_len
            path_index(c,n)
            ok:=check_required(c,r,type.elem)
            c.path_len=mark
            if !ok {return false}
            if serial.text_accept(r,',') {continue}
            return serial.text_expect(r,']')
        }
    }
    return serial.text_skip(r)
}

@(private)
load_u64 :: proc(bytes:[]u8) -> u64 {
    value:u64
    intrinsics.mem_copy_non_overlapping(&value,raw_data(bytes),min(len(bytes),8))
    return value
}
@(private)
load_i64 :: proc(bytes:[]u8) -> i64 {
    switch len(bytes) {
    case 1: return i64(intrinsics.unaligned_load((^i8)(raw_data(bytes))))
    case 2: return i64(intrinsics.unaligned_load((^i16)(raw_data(bytes))))
    case 4: return i64(intrinsics.unaligned_load((^i32)(raw_data(bytes))))
    }
    return intrinsics.unaligned_load((^i64)(raw_data(bytes)))
}
@(private)
load_f64 :: proc(bytes:[]u8) -> f64 {
    switch len(bytes) {
    case 2: return f64(intrinsics.unaligned_load((^f16)(raw_data(bytes))))
    case 4: return f64(intrinsics.unaligned_load((^f32)(raw_data(bytes))))
    }
    return intrinsics.unaligned_load((^f64)(raw_data(bytes)))
}

// An integer tagged clamp comes with its bytes: past its max it takes the max.
@(private)
check_bounds :: proc(c:^Checker,value:f64,field:^serial.Field,clamp:[]u8=nil) -> bool {
    if field==nil {return true}
    if field.has_min && value<field.min {return check_fail(c,"must be at least %v",field.min)}
    if field.has_max && value>field.max {
        if clamp==nil {return check_fail(c,"must be at most %v",field.max)}
        serial.scalar_store(clamp,transmute(u64)i64(field.max),field.max<0)
        c.clamped=format_text(c.allocator,`%s%s%q:{{"asked":%v,"used":%v}}`,c.clamped,c.clamped!=""?",":"",string(c.path[:c.path_len]),i64(value),i64(field.max))
    }
    return true
}

@(private)
check_value :: proc(c:^Checker,index:serial.Type_Index,bytes:[]u8,field:^serial.Field,clamp:=false) -> bool {
    s:=c.schema
    type:=s.types[index]
    switch type.kind {
    case .Bool,.Entity,.Entity_Id,.Asset:
    case .Int:
        if type.size<=8 {return check_bounds(c,f64(load_i64(bytes)),field,clamp?bytes:nil)}
    case .Uint:
        if type.size<=8 {return check_bounds(c,f64(load_u64(bytes)),field,clamp?bytes:nil)}
    case .Float:
        value:=load_f64(bytes)
        if math.is_nan(value) || math.is_inf(value) {return check_fail(c,"must be finite")}
        return check_bounds(c,value,field)
    case .Enum:
        signed,unsigned:=load_i64(bytes),i64(load_u64(bytes))
        for choice in s.choices[type.first:][:type.count] {
            if choice.value==signed || choice.value==unsigned {return true}
        }
        return check_fail(c,"is not a member of its enum")
    case .Bit_Set:
        if type.size>8 {return true}
        mask:u64
        for choice in s.choices[type.first:][:type.count] {mask|=1<<uint(choice.value)}
        if load_u64(bytes)&~mask!=0 {return check_fail(c,"has bits that are not members of its set")}
    case .Struct:
        for &f in s.fields[type.first:][:type.count] {
            if !field_visible(&f) {continue}
            mark:=c.path_len
            path_name(c,f.name)
            ok:=check_value(c,f.type,bytes[f.offset:][:s.types[f.type].size],&f,c.server!=nil && .Clamp in f.hints)
            c.path_len=mark
            if !ok {return false}
        }
    case .Array:
        if field!=nil && .Text in field.flags && serial.type_is_bytes(s,index) {return true}
        elem:=int(s.types[type.elem].size)
        for i in 0..<int(type.count) {
            mark:=c.path_len
            path_index(c,i)
            ok:=check_value(c,type.elem,bytes[i*elem:][:elem],field,clamp)
            c.path_len=mark
            if !ok {return false}
        }
    case .Slice:
        if field!=nil && .Text in field.flags && serial.type_is_bytes(s,type.elem) {return true}
        held:=(^runtime.Raw_Slice)(raw_data(bytes))^
        elem:=int(s.types[type.elem].size)
        for i in 0..<(held.data==nil?0:held.len) {
            mark:=c.path_len
            path_index(c,i)
            ok:=check_value(c,type.elem,mem.byte_slice(rawptr(uintptr(held.data)+uintptr(i*elem)),elem),field,clamp)
            c.path_len=mark
            if !ok {return false}
        }
    case .String,.Json:
    }
    return true
}

// Checks a value that serial.text_read accepted against what its schema says
// of it, for values described by a schema other than the server's: finite
// floats, ranges, and members of enums and bit sets. message, in allocator,
// names the field that fails after path.
value_check :: proc(schema:^serial.Schema,type:serial.Type_Index,bytes:[]u8,path:string,allocator:runtime.Allocator) -> (message:string,ok:bool) {
    checker:=Checker{schema=schema,allocator=allocator}
    path_name(&checker,path)
    if check_value(&checker,type,bytes[:schema.types[type].size],nil) {return "",true}
    return checker.message,false
}
