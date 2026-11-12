package serial

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "mirai:std/base"

// Text form of a value, as JSON driven by its schema: fields in the order of
// the schema, enums by member name, bit sets as lists of member names, ids in
// hexadecimal and text fields as strings. Reading what was written gives the
// same bytes back: floats are written with the fewest digits that read as
// the same bits, a text field of an array of byte arrays as a list of strings,
// and whatever JSON cannot say exactly (a NaN, an enum value
// without a member, a text that is not UTF-8) has an exact spelling of its own:
//   float      "nan", "inf", "-inf", or "bits:0x7ff8000000000001"
//   enum       its number when no member has that value
//   bit set    the index of a bit when no member is that bit
//   text       a list of its bytes
// Transient fields are omitted unless explicitly requested for inspection.

Text_Format :: enum u8 {
    Pretty, // a field or an element per line, indented two spaces per level
    Line,   // the whole value on one line
}

// is_text: the value is a text field, written as a string.
// A type that is not of the schema, or data shorter than it, writes nothing.
text_write :: proc(w:^Writer,s:^Schema,type:Type_Index,data:[]u8,format:=Text_Format.Pretty,depth:=0,is_text:=false,omit_fields:Field_Flags={.Transient}) {
    if !type_valid(s,type) || len(data)<int(s.types[type].size) {return}
    text_write_value(w,s,type,data[:s.types[type].size],is_text && (type_is_bytes(s,type) || type_is_texts(s,type)),format,depth,omit_fields)
}

// The text of a value, of any type an unsized schema takes: the form of a
// file or a message Mirai defines, which text_decode reads back. In
// allocator; ok is false when it is not of such a type or there is no memory.
// sparse leaves out a field tagged optional that holds nothing, which a value
// read over a zero one gets back.
text_encode :: proc(value:any,format:=Text_Format.Pretty,allocator:=context.allocator,sparse:=false) -> (text:[]u8,ok:bool) {
    if value.data==nil {return nil,false}
    s:Schema
    schema_init(&s,context.temp_allocator)
    defer schema_destroy(&s)
    s.unsized,s.sparse=true,sparse
    type:=schema_add_type_info(&s,type_info_of(value.id)) or_return
    w:Writer
    writer_init(&w,256,allocator)
    text_write(&w,&s,type,mem.byte_slice(value.data,int(s.types[type].size)),format)
    if w.overflow>0 {
        writer_destroy(&w)
        return nil,false
    }
    return writer_take(&w),true
}

// Reads text into a value of T, of any type an unsized schema takes. What
// the value holds of any length goes in allocator, and a Json field is a view
// of text. A field text does not have keeps what value had; one T does not
// have is an error, or is skipped with skip_unknown, for whoever reads part
// of what another wrote. problem, in temporary memory, says what is wrong and
// where: its field, line and column; "" when it read.
text_decode :: proc(text:string,value:^$T,allocator:=context.allocator,skip_unknown:=false) -> (problem:string) {
    s:Schema
    schema_init(&s,context.temp_allocator)
    defer schema_destroy(&s)
    s.unsized=true
    type,added:=schema_add(&s,T)
    if !added {return s.error!=""?strings.clone(s.error,context.temp_allocator):"not enough memory to read it"}
    r:Text_Reader
    text_reader_init(&r,text,context.temp_allocator)
    defer text_reader_destroy(&r)
    r.values,r.skip_unknown=allocator,skip_unknown
    if text_read(&r,&s,type,mem.ptr_to_bytes(value)) && text_end(&r) {return ""}
    line,column:=text_position(text,r.error.offset)
    return fmt.tprintf("%s at line %d column %d",text_error_message(&r,allocator=context.temp_allocator),line,column)
}

text_write_raw :: #force_inline proc(w:^Writer,text:string) {write_bytes(w,transmute([]u8)text)}

// A line break and the indentation of a level.
text_write_break :: proc(w:^Writer,depth:int) {
    if out,ok:=writer_grow(w,1+clamp(depth,0,TEXT_MAX_DEPTH)*2);ok {
        out[0]='\n'
        for &b in out[1:] {b=' '}
    }
}

text_write_string :: proc(w:^Writer,text:string) {
    HEX:="0123456789abcdef"
    write_u8(w,'"')
    start:=0
    for i in 0..<len(text) {
        c:=text[i]
        if c>=0x20 && c!='"' && c!='\\' {continue}
        text_write_raw(w,text[start:i])
        start=i+1
        switch c {
        case '"': text_write_raw(w,`\"`)
        case '\\': text_write_raw(w,`\\`)
        case '\n': text_write_raw(w,`\n`)
        case '\r': text_write_raw(w,`\r`)
        case '\t': text_write_raw(w,`\t`)
        case:
            text_write_raw(w,`\u00`)
            write_u8(w,HEX[c>>4]);write_u8(w,HEX[c&15])
        }
    }
    text_write_raw(w,text[start:])
    write_u8(w,'"')
}

// The JSON string of a text, as text_write_string writes it.
text_quote :: proc(text:string,allocator:=context.temp_allocator) -> string {
    w:Writer
    writer_init(&w,len(text)+8,allocator)
    text_write_string(&w,text)
    return string(writer_take(&w))
}

text_write_int :: proc(w:^Writer,value:i64) {
    buffer:[32]u8
    text_write_raw(w,strconv.write_int(buffer[:],value,10))
}
text_write_uint :: proc(w:^Writer,value:u64) {
    buffer:[32]u8
    text_write_raw(w,strconv.write_uint(buffer[:],value,10))
}
// "0x" and digits hexadecimal digits.
text_write_hex :: proc(w:^Writer,value:u64,digits:=16,prefix:=true) {
    HEX:="0123456789abcdef"
    digits:=clamp(digits,0,16)
    if prefix {text_write_raw(w,"0x")}
    if out,ok:=writer_grow(w,digits);ok {
        for i in 0..<digits {out[i]=HEX[(value>>(uint(digits-1-i)*4))&15]}
    }
}
// 32 hexadecimal digits: the first word, then the second.
text_write_asset_id :: proc(w:^Writer,id:base.Asset_Id) {
    text_write_hex(w,id[0],16,false)
    text_write_hex(w,id[1],16,false)
}
text_parse_asset_id :: proc(text:string) -> (id:base.Asset_Id,ok:bool) {
    if len(text)!=32 {return {},false}
    id[0]=text_parse_hex(text[:16]) or_return
    id[1]=text_parse_hex(text[16:]) or_return
    return id,true
}
// Hexadecimal digits, with or without "0x".
text_parse_hex :: proc(text:string) -> (value:u64,ok:bool) {
    digits:=text
    if len(digits)>=2 && digits[0]=='0' && (digits[1]=='x' || digits[1]=='X') {digits=digits[2:]}
    if len(digits)==0 || len(digits)>16 {return 0,false}
    for c in transmute([]u8)digits {
        switch c {
        case '0'..='9': value=value<<4|u64(c-'0')
        case 'a'..='f': value=value<<4|u64(c-'a'+10)
        case 'A'..='F': value=value<<4|u64(c-'A'+10)
        case: return 0,false
        }
    }
    return value,true
}

// The bits of a float of size bytes out of a number.
@(private)
text_float_bits :: proc(token:string,size:int) -> (bits:u64,ok:bool) {
    value:=strconv.parse_f64(token) or_return
    switch size {
    case 2: return u64(transmute(u16)f16(value)),true
    case 4: return u64(transmute(u32)f32(value)),true
    }
    return transmute(u64)value,true
}

// A float given by its bits, of size bytes: 2, 4 or 8; any other writes nothing.
text_write_float :: proc(w:^Writer,bits:u64,size:int) {
    if size!=2 && size!=4 && size!=8 {return}
    value:f64
    exponent_mask,mantissa_mask:u64
    switch size {
    case 2: value=f64(transmute(f16)u16(bits));exponent_mask,mantissa_mask=0x7c00,0x03ff
    case 4: value=f64(transmute(f32)u32(bits));exponent_mask,mantissa_mask=0x7f800000,0x007fffff
    case: value=transmute(f64)bits;exponent_mask,mantissa_mask=0x7ff0000000000000,0x000fffffffffffff
    }
    sign:=bits>>(uint(size)*8-1)!=0
    if bits&exponent_mask==exponent_mask {
        quiet:=(mantissa_mask+1)>>1
        switch {
        case bits&mantissa_mask==0: text_write_raw(w,sign?`"-inf"`:`"inf"`)
        case !sign && bits&mantissa_mask==quiet: text_write_raw(w,`"nan"`)
        case:
            text_write_raw(w,`"bits:`)
            text_write_hex(w,bits,size*2)
            write_u8(w,'"')
        }
        return
    }
    buffer:[64]u8
    for precision in ([]int{-1,size==8?16:8}) {
        text:=strconv.write_float(buffer[:],value,precision<0?'g':'e',precision,size*8)
        if len(text)>0 && text[0]=='+' {text=text[1:]}
        if back,ok:=text_float_bits(text,size);ok && back==bits {
            text_write_raw(w,text)
            return
        }
    }
    text_write_raw(w,`"bits:`)
    text_write_hex(w,bits,size*2)
    write_u8(w,'"')
}

// A text field that a JSON string holds exactly: UTF-8 up to its first NUL, zeros after it.
@(private="file")
text_is_exact :: proc(bytes:[]u8) -> bool {
    end:=len(bytes)
    for b,i in bytes {
        if b==0 {end=i;break}
    }
    for b in bytes[end:] {
        if b!=0 {return false}
    }
    return utf8.valid_string(string(bytes[:end]))
}

@(private="file")
text_write_value :: proc(w:^Writer,s:^Schema,index:Type_Index,bytes:[]u8,is_text:bool,format:Text_Format,depth:int,omit_fields:Field_Flags) {
    type:=s.types[index]
    switch text_kind(type) {
    case .Bool:
        text_write_raw(w,scalar_unsigned(bytes)!=0?"true":"false")
    case .Int:
        if type.size==16 {text_write_wide(w,bytes)}
        else {text_write_int(w,scalar_signed(bytes))}
    case .Uint:
        if type.size==16 {text_write_wide(w,bytes)}
        else {text_write_uint(w,scalar_unsigned(bytes))}
    case .Float:
        text_write_float(w,scalar_unsigned(bytes),int(type.size))
    case .Enum:
        number:=enum_value(s,type,bytes)
        for choice in s.choices[type.first:][:type.count] {
            if choice.value==number {text_write_string(w,choice.name);return}
        }
        text_write_int(w,number)
    case .Bit_Set:
        bits:[2]u64
        intrinsics.mem_copy_non_overlapping(&bits,raw_data(bytes),len(bytes))
        // A mask of names with every bit set is all of them, those declared later too.
        if type.named==.Bits && len(bytes)<=8 && bits[0]==max(u64)>>uint(64-len(bytes)*8) {text_write_raw(w,`["*"]`);return}
        write_u8(w,'[')
        first:=true
        for choice in s.choices[type.first:][:type.count] {
            mask:=u64(1)<<uint(choice.value&63)
            if bits[choice.value>>6]&mask==0 {continue}
            bits[choice.value>>6]&~=mask
            if !first {text_write_raw(w,", ")}
            first=false
            text_write_string(w,choice.name)
        }
        for bit in 0..<len(bytes)*8 {
            if bits[bit>>6]&(1<<uint(bit&63))==0 {continue}
            if !first {text_write_raw(w,", ")}
            first=false
            text_write_int(w,i64(bit))
        }
        write_u8(w,']')
    case .Entity,.Entity_Id:
        write_u8(w,'"');text_write_hex(w,scalar_unsigned(bytes));write_u8(w,'"')
    case .Asset:
        write_u8(w,'"');text_write_asset_id(w,intrinsics.unaligned_load((^base.Asset_Id)(raw_data(bytes))));write_u8(w,'"')
    case .Struct:
        first:=true
        for field in s.fields[type.first:][:type.count] {
            if field.flags & omit_fields != (Field_Flags{}) {continue}
            if s.sparse && .Optional in field.hints && slice.all_of(bytes[field.offset:][:s.types[field.type].size],0) {continue}
            text_write_key(w,field.name,first,format,depth+1)
            first=false
            text_write_field(w,s,field,bytes[field.offset:][:s.types[field.type].size],format,depth+1,omit_fields)
        }
        if first {text_write_raw(w,"{}");return}
        if format==.Pretty {text_write_break(w,depth)}
        write_u8(w,'}')
    case .Array:
        if is_text && type_is_bytes(s,index) && text_is_exact(bytes) {
            text_write_string(w,text_field(bytes))
            return
        }
        text_write_array(w,s,index,bytes,int(type.count),format,depth,omit_fields,is_text && type_is_texts(s,index))
    case .Slice:
        held:=intrinsics.unaligned_load((^runtime.Raw_Slice)(raw_data(bytes)))
        count:=held.data==nil?0:max(held.len,0)
        text_write_array(w,s,index,mem.byte_slice(held.data,count*int(s.types[type.elem].size)),count,format,depth,omit_fields,is_text && type_is_bytes(s,type.elem))
    case .String:
        text_write_string(w,intrinsics.unaligned_load((^string)(raw_data(bytes))))
    case .Json:
        text:=intrinsics.unaligned_load((^string)(raw_data(bytes)))
        text_write_raw(w,text!=""?text:"null")
    }
}

// The fields of a struct whose bytes differ from those of base, as an object:
// a struct field gives only its own fields that differ, so reading the text
// over base gives data back. skip names fields of the top struct to leave out.
text_write_changed :: proc(w:^Writer,s:^Schema,type:Type_Index,data,base:[]u8,format:=Text_Format.Line,depth:=0,omit_fields:Field_Flags={.Transient},skip:[]string=nil) {
    if !type_valid(s,type) || s.types[type].kind!=.Struct {return}
    t:=s.types[type]
    if len(data)<int(t.size) || len(base)<int(t.size) {return}
    first:=true
    for field in s.fields[t.first:][:t.count] {
        if field.flags & omit_fields != (Field_Flags{}) || slice.contains(skip,field.name) {continue}
        size:=s.types[field.type].size
        part,from:=data[field.offset:][:size],base[field.offset:][:size]
        if mem.compare(part,from)==0 {continue}
        text_write_key(w,field.name,first,format,depth+1)
        first=false
        if s.types[field.type].kind==.Struct {
            text_write_changed(w,s,field.type,part,from,format,depth+1,omit_fields)
        } else {
            text_write_field(w,s,field,part,format,depth+1,omit_fields)
        }
    }
    if first {text_write_raw(w,"{}");return}
    if format==.Pretty {text_write_break(w,depth)}
    write_u8(w,'}')
}

// Opens an object with the key of a field, or goes on to it.
@(private="file")
text_write_key :: proc(w:^Writer,name:string,first:bool,format:Text_Format,depth:int) {
    write_u8(w,first?'{':',')
    if format==.Pretty {text_write_break(w,depth)}
    else if !first {write_u8(w,' ')}
    text_write_string(w,name)
    text_write_raw(w,": ")
}

// The value of a field of a struct, its bytes in part.
@(private="file")
text_write_field :: proc(w:^Writer,s:^Schema,field:Field,part:[]u8,format:Text_Format,depth:int,omit_fields:Field_Flags) {
    if .Trim in field.hints && s.types[field.type].kind==.Array {
        array:=s.types[field.type]
        size:=int(s.types[array.elem].size)
        used:=int(array.count)
        for used>0 && slice.all_of(part[(used-1)*size:][:size],0) {used-=1}
        text_write_array(w,s,field.type,part,used,format,depth,omit_fields,.Text in field.flags && type_is_texts(s,field.type))
        return
    }
    text_write_value(w,s,field.type,part,.Text in field.flags && (type_is_bytes(s,field.type) || type_is_texts(s,field.type)),format,depth,omit_fields)
}

// The first count elements of an array or of what a slice holds; texts: they are text fields.
@(private="file")
text_write_array :: proc(w:^Writer,s:^Schema,index:Type_Index,bytes:[]u8,count:int,format:Text_Format,depth:int,omit_fields:Field_Flags,texts:=false) {
    type:=s.types[index]
    if count==0 {text_write_raw(w,"[]");return}
    elem:=s.types[type.elem]
    broken:=format==.Pretty && (elem.kind==.Struct || elem.kind==.Array)
    write_u8(w,'[')
    for i in 0..<count {
        if i>0 {text_write_raw(w,broken?",":", ")}
        if broken {text_write_break(w,depth+1)}
        text_write_value(w,s,type.elem,bytes[i*int(elem.size):][:elem.size],texts,format,depth+1,omit_fields)
    }
    if broken {text_write_break(w,depth)}
    write_u8(w,']')
}

// A 16-byte integer: "0x" and 32 digits.
@(private="file")
text_write_wide :: proc(w:^Writer,bytes:[]u8) {
    write_u8(w,'"')
    text_write_hex(w,scalar_unsigned(bytes[8:]),16)
    text_write_hex(w,scalar_unsigned(bytes[:8]),16,false)
    write_u8(w,'"')
}

// ------------------------------------------------------------------ reading

Text_Error_Code :: enum u8 {
    None,
    Syntax,
    Expected_Object,
    Expected_Array,
    Expected_String,
    Expected_Number,
    Expected_Integer,
    Expected_Bool,
    Unknown_Field,
    Unknown_Member,
    Out_Of_Range,      // a number its field cannot hold
    Too_Many_Elements,
    Text_Too_Long,
    Invalid_Id,
    Unknown_Asset,     // a text a reader with assets could not take for one: names says why
    Unknown_Entity,    // a text a reader with entities could not take for one: names says why
    Too_Deep,
    Invalid_Type,      // the type is not of the schema, or the destination is shorter than it
    Out_Of_Memory,     // no memory for what a slice or a string holds
}

Text_Error :: struct {
    code:Text_Error_Code,
    offset:int,   // into the text
    names:string, // Unknown_Field, Unknown_Member: the names the struct, enum or bit set has, as `a, b, c`; a view of Text_Reader.names
    whole:bool,   // names is the whole of what is wrong
    path:[TEXT_PATH_BYTES]u8, // where in the value, from the outermost (text_error_within): `exposure.adaptation_mode`, `parts[1].shape`
    path_length:int,
}

TEXT_MAX_DEPTH :: 64
// What the path of an error holds: its outer parts are left out when it is longer.
TEXT_PATH_BYTES :: 96
// The most of a name of the text a message repeats.
TEXT_ECHO_BYTES :: 64

// A JSON reader that keeps its first error. Strings come back as views of
// the text, or of scratch when they have escapes: valid until the next one.
Text_Reader :: struct {
    text:string,
    offset:int,
    error:Text_Error,
    scratch:[dynamic]u8,
    names:[dynamic]u8, // of the error
    assets:Text_Assets,
    asset_kinds:string, // of the field being read
    values:runtime.Allocator, // where what a slice or a string read holds goes: the allocator of the reader
    loose_names:bool,   // text a person or an agent wrote: members of enums and bit sets as base.name_find takes them
    loosened:bool,      // it took a member by a name that is not written as the type has it
    nulls:bool,         // null where a value goes leaves what the destination had, as a field left out does
    skip_unknown:bool,  // a field the type does not have is skipped: whoever reads part of what another wrote
}

// How a reader that knows the assets takes a name for one where an Asset_Id
// goes, besides its id. kinds: the extensions the field holds, separated by
// spaces; "": any. problem says what is wrong with the name; "": found.
Text_Assets :: struct {
    user:rawptr,
    resolve:proc(user:rawptr,name,kinds:string) -> (id:base.Asset_Id,problem:string),
}

text_reader_init :: proc(r:^Text_Reader,text:string,allocator:=context.allocator) {
    r^={text=text,values=allocator}
    r.scratch=make([dynamic]u8,allocator)
    r.names=make([dynamic]u8,allocator)
}
text_reader_destroy :: proc(r:^Text_Reader) {
    delete(r.scratch)
    delete(r.names)
    r^={}
}

// Puts `name`, a field or a section that held the value, in front of the
// path of the error of r.
text_error_within :: proc(r:^Text_Reader,name:string) {
    e:=&r.error
    if e.code==.None {return}
    text_error_prefix(e,name,e.path_length>0 && e.path[0]!='[' ? "." : "")
}

// Puts the index of an element that held the value in front of the path of
// the error of r.
text_error_within_index :: proc(r:^Text_Reader,index:int) {
    e:=&r.error
    if e.code==.None {return}
    digits:[24]u8
    at:=len(digits)-1
    digits[at]=']'
    value:=index
    for {
        at-=1;digits[at]=u8('0'+value%10)
        value/=10
        if value==0 {break}
    }
    at-=1;digits[at]='['
    text_error_prefix(e,string(digits[at:]),e.path_length>0 && e.path[0]!='[' ? "." : "")
}

@(private="file")
text_error_prefix :: proc(e:^Text_Error,head,joint:string) {
    total:=len(head)+len(joint)+e.path_length
    if total>len(e.path) {return}
    copy(e.path[len(head)+len(joint):],e.path[:e.path_length])
    copy(e.path[:],head)
    copy(e.path[len(head):],joint)
    e.path_length=total
}

// Fails with what the reader of a name said of it, for whoever wrote it.
@(private="file")
text_fail_problem :: proc(r:^Text_Reader,code:Text_Error_Code,offset:int,problem:string) -> bool {
    if r.error.code!=.None {return false}
    clear(&r.names)
    append(&r.names,problem)
    r.error={code=code,offset=offset,names=string(r.names[:]),whole=true}
    return false
}

// Fails with the names of the members or fields a type has, for a name it
// does not have.
text_fail_names :: proc(r:^Text_Reader,code:Text_Error_Code,offset:int,choices:[]Choice,fields:[]Field) -> bool {
    if r.error.code!=.None {return false}
    r.error={code=code,offset=offset}
    clear(&r.names)
    for choice in choices {
        if len(r.names)>0 {append(&r.names,", ")}
        append(&r.names,choice.name)
    }
    for field in fields {
        if len(r.names)>0 {append(&r.names,", ")}
        append(&r.names,field.name)
    }
    r.error.names=string(r.names[:])
    return false
}

// The value of a member of an enum or a bit set by its name.
@(private="file")
text_member :: proc(r:^Text_Reader,choices:[]Choice,name:string) -> (value:i64,found:bool) {
    for choice in choices {
        if choice.name==name {return choice.value,true}
    }
    if !r.loose_names {return}
    index,_:=base.name_find(name,text_choice_names(choices))
    if index<0 {return}
    r.loosened=true
    return choices[index].value,true
}

// In temporary memory; without it, no names.
@(private="file")
text_choice_names :: proc(choices:[]Choice) -> []string {
    names,error:=make([]string,len(choices),context.temp_allocator)
    if error!=nil {return nil}
    for choice,i in choices {names[i]=choice.name}
    return names
}

// Fails for a name that is no member; loose names are told the nearest ones.
@(private="file")
text_fail_member :: proc(r:^Text_Reader,offset:int,choices:[]Choice,name:string) -> bool {
    if !r.loose_names {return text_fail_names(r,.Unknown_Member,offset,choices,nil)}
    if r.error.code!=.None {return false}
    problem:=base.name_problem(name,"one of its names",text_choice_names(choices))
    clear(&r.names)
    append(&r.names,problem)
    r.error={code=.Unknown_Member,offset=offset,names=string(r.names[:]),whole=true}
    return false
}

// What is wrong with what r read, for whoever wrote it: where in the value,
// after `prefix`, the name the caller gives the whole of it, and what; for a
// name the type does not have, the names it has. Where in the text is
// text_position.
text_error_message :: proc(r:^Text_Reader,prefix:="",allocator:=context.allocator) -> string {
    e:=&r.error
    out:=make([dynamic]u8,allocator)
    path:=string(e.path[:e.path_length])
    append(&out,prefix)
    if prefix!="" && path!="" && path[0]!='[' {append(&out,".")}
    append(&out,path)
    if len(out)>0 {append(&out,": ")}
    given:Text_Reader
    text_reader_init(&given,r.text,allocator)
    defer text_reader_destroy(&given)
    given.offset=e.offset
    name,named:=text_string(&given)
    if len(name)>TEXT_ECHO_BYTES {
        cut:=TEXT_ECHO_BYTES
        for cut>0 && !utf8.rune_start(name[cut]) {cut-=1}
        name=name[:cut]
    }
    parts:[]string
    switch {
    case e.whole:                                         parts={e.names}
    case e.code==.Unknown_Member && named && e.names!="": parts={`"`,name,`" is not one of `,e.names}
    case e.code==.Unknown_Field && named && e.names!="":  parts={`"`,name,`" is not a field: the fields are `,e.names}
    case:                                                 parts={text_error_words(e.code)}
    }
    for part in parts {append(&out,part)}
    return string(out[:])
}

// The field an Unknown_Field error of r names, with where it is in the value
// (`parts[1].nope`); "" for any other error or without the memory for it.
text_error_field :: proc(r:^Text_Reader,allocator:=context.allocator) -> string {
    if r.error.code!=.Unknown_Field {return ""}
    given:Text_Reader
    text_reader_init(&given,r.text,allocator)
    defer text_reader_destroy(&given)
    given.offset=r.error.offset
    name,named:=text_string(&given)
    if !named {return ""}
    path:=string(r.error.path[:r.error.path_length])
    joint:=path==""?"":"."
    out,failed:=make([]u8,len(path)+len(joint)+len(name),allocator)
    if failed!=nil {return ""}
    copy(out,path)
    copy(out[len(path):],joint)
    copy(out[len(path)+len(joint):],name)
    return string(out)
}

// What a code of the reader means, in words.
text_error_words :: proc(code:Text_Error_Code) -> string {
    switch code {
    case .None: return "no error"
    case .Syntax: return "malformed JSON"
    case .Expected_Object: return "expected an object"
    case .Expected_Array: return "expected an array"
    case .Expected_String: return "expected a string"
    case .Expected_Number: return "expected a number"
    case .Expected_Integer: return "expected an integer"
    case .Expected_Bool: return "expected true or false"
    case .Unknown_Field: return "unknown field"
    case .Unknown_Member: return "unknown enum or bit set member"
    case .Out_Of_Range: return "number out of range"
    case .Too_Many_Elements: return "too many elements"
    case .Text_Too_Long: return "text too long"
    case .Invalid_Id: return "invalid id"
    case .Unknown_Asset: return "no such asset"
    case .Unknown_Entity: return "no such entity"
    case .Too_Deep: return "nesting too deep"
    case .Invalid_Type: return "a type that is not of the schema, or a destination shorter than it"
    case .Out_Of_Memory: return "not enough memory for the value"
    }
    return "invalid"
}

// Line and column of an offset, from one.
text_position :: proc(text:string,offset:int) -> (line,column:int) {
    line,column=1,1
    for i in 0..<min(offset,len(text)) {
        if text[i]=='\n' {line+=1;column=1}
        else {column+=1}
    }
    return
}

text_fail :: proc(r:^Text_Reader,code:Text_Error_Code,offset:=-1) -> bool {
    if r.error.code==.None {r.error={code=code,offset=offset<0?r.offset:offset}}
    return false
}
text_space :: proc(r:^Text_Reader) {
    for r.offset<len(r.text) {
        switch r.text[r.offset] {
        case ' ','\t','\n','\r': r.offset+=1
        case: return
        }
    }
}
// The next character that is not space; 0 at the end.
text_peek :: proc(r:^Text_Reader) -> u8 {
    text_space(r)
    return r.offset<len(r.text)?r.text[r.offset]:0
}
text_accept :: proc(r:^Text_Reader,c:u8) -> bool {
    if r.error.code!=.None || text_peek(r)!=c {return false}
    r.offset+=1
    return true
}
text_expect :: proc(r:^Text_Reader,c:u8) -> bool {
    if text_accept(r,c) {return true}
    return text_fail(r,.Syntax)
}
// Nothing but space is left.
text_end :: proc(r:^Text_Reader) -> bool {
    if r.error.code!=.None {return false}
    if text_peek(r)!=0 {return text_fail(r,.Syntax)}
    return true
}
text_keyword :: proc(r:^Text_Reader,word:string) -> bool {
    text_space(r)
    if r.error.code!=.None || len(r.text)-r.offset<len(word) || r.text[r.offset:][:len(word)]!=word {return false}
    r.offset+=len(word)
    return true
}

@(private="file")
text_hex4 :: proc(r:^Text_Reader) -> (value:rune,ok:bool) {
    if len(r.text)-r.offset<4 {return 0,false}
    parsed:=text_parse_hex(r.text[r.offset:][:4]) or_return
    r.offset+=4
    return rune(parsed),true
}

text_string :: proc(r:^Text_Reader) -> (value:string,ok:bool) {
    if r.error.code!=.None {return "",false}
    if text_peek(r)!='"' {return "",text_fail(r,.Expected_String)}
    start:=r.offset
    r.offset+=1
    begin:=r.offset
    escaped:=false
    clear(&r.scratch)
    for {
        if r.offset>=len(r.text) {return "",text_fail(r,.Syntax,start)}
        c:=r.text[r.offset]
        if c=='"' {break}
        if c<0x20 {return "",text_fail(r,.Syntax)}
        if c!='\\' {
            if escaped {append(&r.scratch,c)}
            r.offset+=1
            continue
        }
        if !escaped {
            escaped=true
            append(&r.scratch,r.text[begin:r.offset])
        }
        r.offset+=1
        if r.offset>=len(r.text) {return "",text_fail(r,.Syntax,start)}
        code:=r.text[r.offset]
        r.offset+=1
        switch code {
        case '"','\\','/': append(&r.scratch,code)
        case 'b': append(&r.scratch,'\b')
        case 'f': append(&r.scratch,'\f')
        case 'n': append(&r.scratch,'\n')
        case 'r': append(&r.scratch,'\r')
        case 't': append(&r.scratch,'\t')
        case 'u':
            point,valid:=text_hex4(r)
            if !valid {return "",text_fail(r,.Syntax)}
            if point>=0xd800 && point<0xdc00 {
                if len(r.text)-r.offset<6 || r.text[r.offset]!='\\' || r.text[r.offset+1]!='u' {return "",text_fail(r,.Syntax)}
                r.offset+=2
                low,low_valid:=text_hex4(r)
                if !low_valid || low<0xdc00 || low>=0xe000 {return "",text_fail(r,.Syntax)}
                point=0x10000+(point-0xd800)<<10+(low-0xdc00)
            } else if point>=0xdc00 && point<0xe000 {
                return "",text_fail(r,.Syntax)
            }
            encoded,size:=utf8.encode_rune(point)
            append(&r.scratch,..encoded[:size])
        case:
            return "",text_fail(r,.Syntax,r.offset-2)
        }
    }
    value=escaped?string(r.scratch[:]):r.text[begin:r.offset]
    r.offset+=1
    return value,true
}

// The characters of a number: -?digits(.digits)?([eE][+-]?digits)?
text_number :: proc(r:^Text_Reader) -> (token:string,ok:bool) {
    if r.error.code!=.None {return "",false}
    text_space(r)
    start:=r.offset
    at:=start
    digits :: proc(text:string,at:^int) -> bool {
        begin:=at^
        for at^<len(text) && text[at^]>='0' && text[at^]<='9' {at^+=1}
        return at^>begin
    }
    if at<len(r.text) && r.text[at]=='-' {at+=1}
    if !digits(r.text,&at) {return "",text_fail(r,.Expected_Number,start)}
    if at<len(r.text) && r.text[at]=='.' {
        at+=1
        if !digits(r.text,&at) {return "",text_fail(r,.Syntax,at)}
    }
    if at<len(r.text) && (r.text[at]=='e' || r.text[at]=='E') {
        at+=1
        if at<len(r.text) && (r.text[at]=='+' || r.text[at]=='-') {at+=1}
        if !digits(r.text,&at) {return "",text_fail(r,.Syntax,at)}
    }
    r.offset=at
    return r.text[start:at],true
}

// A number without fraction or exponent, as its sign and magnitude.
text_integer :: proc(r:^Text_Reader) -> (negative:bool,magnitude:u64,ok:bool) {
    text_space(r)
    start:=r.offset
    token:=text_number(r) or_return
    digits:=token
    if digits[0]=='-' {negative=true;digits=digits[1:]}
    for c in transmute([]u8)digits {
        if c<'0' || c>'9' {return false,0,text_fail(r,.Expected_Integer,start)}
        if magnitude>(max(u64)-u64(c-'0'))/10 {return false,0,text_fail(r,.Out_Of_Range,start)}
        magnitude=magnitude*10+u64(c-'0')
    }
    if negative && magnitude>1<<63 {return false,0,text_fail(r,.Out_Of_Range,start)}
    return negative,magnitude,true
}

// Skips one value of any kind.
text_skip :: proc(r:^Text_Reader,depth:=0) -> bool {
    depth:=max(depth,0)
    if r.error.code!=.None {return false}
    if depth>TEXT_MAX_DEPTH {return text_fail(r,.Too_Deep)}
    switch text_peek(r) {
    case '{':
        r.offset+=1
        if text_accept(r,'}') {return true}
        for {
            text_string(r) or_return
            text_expect(r,':') or_return
            text_skip(r,depth+1) or_return
            if text_accept(r,',') {continue}
            return text_expect(r,'}')
        }
    case '[':
        r.offset+=1
        if text_accept(r,']') {return true}
        for {
            text_skip(r,depth+1) or_return
            if text_accept(r,',') {continue}
            return text_expect(r,']')
        }
    case '"':
        _,ok:=text_string(r)
        return ok
    case 't': return text_keyword(r,"true") || text_fail(r,.Syntax)
    case 'f': return text_keyword(r,"false") || text_fail(r,.Syntax)
    case 'n': return text_keyword(r,"null") || text_fail(r,.Syntax)
    }
    _,ok:=text_number(r)
    return ok
}

// The bits of a float of size bytes, 2, 4 or 8: a number, or one of the
// spellings text_write_float gives what a number cannot say.
text_read_float :: proc(r:^Text_Reader,size:int) -> (bits:u64,ok:bool) {
    if r.error.code!=.None {return 0,false}
    if size!=2 && size!=4 && size!=8 {return 0,text_fail(r,.Invalid_Type)}
    text_space(r)
    start:=r.offset
    exponent:=size==8?u64(0x7ff0000000000000):(size==4?u64(0x7f800000):u64(0x7c00))
    if text_peek(r)=='"' {
        text:=text_string(r) or_return
        quiet:=u64(1)<<(uint(size)*8-1-(size==8?12:(size==4?9:6)))
        switch {
        case text=="nan": return exponent|quiet,true
        case text=="inf": return exponent,true
        case text=="-inf": return exponent|1<<(uint(size)*8-1),true
        case len(text)==7+size*2 && text[:5]=="bits:":
            parsed,valid:=text_parse_hex(text[5:])
            if valid {return parsed,true}
        }
        return 0,text_fail(r,.Expected_Number,start)
    }
    token:=text_number(r) or_return
    parsed,valid:=text_float_bits(token,size)
    if !valid || parsed&exponent==exponent {return 0,text_fail(r,.Out_Of_Range,start)}
    return parsed,true
}

// Reads a value of the type into dst. A field or an element that the text
// does not have keeps what dst had; a field that the type does not have is
// an error.
text_read :: proc(r:^Text_Reader,s:^Schema,type:Type_Index,dst:[]u8,is_text:=false) -> bool {
    if !type_valid(s,type) || len(dst)<int(s.types[type].size) {return text_fail(r,.Invalid_Type)}
    return text_read_value(r,s,type,dst[:s.types[type].size],is_text && (type_is_bytes(s,type) || type_is_texts(s,type)))
}

@(private="file")
text_read_value :: proc(r:^Text_Reader,s:^Schema,index:Type_Index,bytes:[]u8,is_text:bool) -> bool {
    if r.error.code!=.None {return false}
    type:=s.types[index]
    text_space(r)
    start:=r.offset
    if r.nulls && type.kind!=.Json && text_keyword(r,"null") {return true}
    switch text_kind(type) {
    case .Bool:
        if text_keyword(r,"true") {scalar_store(bytes,1);return true}
        if text_keyword(r,"false") {scalar_store(bytes,0);return true}
        return text_fail(r,.Expected_Bool)
    case .Int,.Uint:
        if type.size==16 && text_peek(r)=='"' {
            text:=text_string(r) or_return
            digits:=len(text)>2?text[2:]:""
            if len(digits)!=32 {return text_fail(r,.Invalid_Id,start)}
            high,high_ok:=text_parse_hex(digits[:16])
            low,low_ok:=text_parse_hex(digits[16:])
            if !high_ok || !low_ok {return text_fail(r,.Invalid_Id,start)}
            scalar_store(bytes[:8],low);scalar_store(bytes[8:],high)
            return true
        }
        negative,magnitude:=text_integer(r) or_return
        value:Value=negative?Value(-i64(magnitude-1)-1):Value(magnitude)
        number,error:=value_integer(value,type.kind==.Int,min(uint(type.size),8)*8)
        if error!=.None {return text_fail(r,.Out_Of_Range,start)}
        scalar_store(bytes,u64(number),type.kind==.Int && number<0)
        return true
    case .Float:
        bits:=text_read_float(r,int(type.size)) or_return
        scalar_store(bytes,bits)
        return true
    case .Enum:
        if text_peek(r)=='"' {
            name:=text_string(r) or_return
            if value,found:=text_member(r,s.choices[type.first:][:type.count],name);found {scalar_store(bytes,u64(value));return true}
            return text_fail_member(r,start,s.choices[type.first:][:type.count],name)
        }
        negative,magnitude:=text_integer(r) or_return
        scalar_store(bytes,negative?~magnitude+1:magnitude)
        return true
    case .Bit_Set:
        if !text_accept(r,'[') {return text_fail(r,.Expected_Array)}
        bits:[2]u64
        if !text_accept(r,']') {
            for {
                text_space(r)
                at:=r.offset
                bit:=-1
                if text_peek(r)=='"' {
                    name:=text_string(r) or_return
                    value,found:=text_member(r,s.choices[type.first:][:type.count],name)
                    if !found && name=="*" && type.named==.Bits {
                        bits=max(u64)
                        value,found=0,true
                    }
                    if !found {return text_fail_member(r,at,s.choices[type.first:][:type.count],name)}
                    bit=int(value)
                } else {
                    negative,magnitude:=text_integer(r) or_return
                    if negative || magnitude>=u64(type.size)*8 {return text_fail(r,.Out_Of_Range,at)}
                    bit=int(magnitude)
                }
                bits[bit>>6]|=1<<uint(bit&63)
                if text_accept(r,',') {continue}
                text_expect(r,']') or_return
                break
            }
        }
        intrinsics.mem_copy_non_overlapping(raw_data(bytes),&bits,len(bytes))
        return true
    case .Entity,.Entity_Id:
        if text_peek(r)=='"' {
            text:=text_string(r) or_return
            value,ok:=text_parse_hex(text)
            if !ok {return text_fail(r,.Invalid_Id,start)}
            scalar_store(bytes,value)
            return true
        }
        negative,magnitude:=text_integer(r) or_return
        if negative {return text_fail(r,.Out_Of_Range,start)}
        scalar_store(bytes,magnitude)
        return true
    case .Asset:
        text:=text_string(r) or_return
        id,ok:=text_parse_asset_id(text)
        if !ok && r.assets.resolve!=nil {
            problem:string
            if id,problem=r.assets.resolve(r.assets.user,text,r.asset_kinds);problem!="" {return text_fail_problem(r,.Unknown_Asset,start,problem)}
            ok=true
        }
        if !ok {return text_fail(r,.Invalid_Id,start)}
        intrinsics.unaligned_store((^base.Asset_Id)(raw_data(bytes)),id)
        return true
    case .Struct:
        if !text_accept(r,'{') {return text_fail(r,.Expected_Object)}
        if text_accept(r,'}') {return true}
        for {
            text_space(r)
            at:=r.offset
            name:=text_string(r) or_return
            found:^Field
            for &field in s.fields[type.first:][:type.count] {
                if field.name==name {found=&field;break}
            }
            if found==nil {
                if !r.skip_unknown {return text_fail_names(r,.Unknown_Field,at,nil,s.fields[type.first:][:type.count])}
                text_expect(r,':') or_return
                text_skip(r) or_return
                if text_accept(r,',') {continue}
                return text_expect(r,'}')
            }
            text_expect(r,':') or_return
            r.asset_kinds=found.asset_kinds
            part:=bytes[found.offset:][:s.types[found.type].size]
            if !text_read_value(r,s,found.type,part,.Text in found.flags && (type_is_bytes(s,found.type) || type_is_texts(s,found.type))) {
                text_error_within(r,found.name)
                return false
            }
            if text_accept(r,',') {continue}
            return text_expect(r,'}')
        }
    case .Array:
        if is_text && type_is_bytes(s,index) && text_peek(r)=='"' {
            text:=text_string(r) or_return
            if len(text)>len(bytes) {return text_fail(r,.Text_Too_Long,start)}
            mem.zero_slice(bytes)
            copy(bytes,text)
            return true
        }
        if !text_accept(r,'[') {return text_fail(r,.Expected_Array)}
        if text_accept(r,']') {return true}
        size:=int(s.types[type.elem].size)
        for i:=0;;i+=1 {
            if i>=int(type.count) {
                text_space(r)
                return text_fail(r,.Too_Many_Elements)
            }
            if !text_read_value(r,s,type.elem,bytes[i*size:][:size],is_text && type_is_bytes(s,type.elem)) {
                text_error_within_index(r,i)
                return false
            }
            if text_accept(r,',') {continue}
            return text_expect(r,']')
        }
    case .Slice:
        if !text_accept(r,'[') {return text_fail(r,.Expected_Array)}
        first:=r.offset
        count:=0
        if !text_accept(r,']') {
            for {
                text_skip(r) or_return
                count+=1
                if text_accept(r,',') {continue}
                text_expect(r,']') or_return
                break
            }
        }
        elem:=s.types[type.elem]
        held:runtime.Raw_Slice
        if count>0 && elem.size>0 {
            if count>max(int)/int(elem.size) {return text_fail(r,.Out_Of_Memory,start)}
            data,error:=mem.alloc_bytes(count*int(elem.size),int(elem.align),r.values)
            if error!=nil || len(data)<count*int(elem.size) {return text_fail(r,.Out_Of_Memory,start)}
            r.offset=first
            for i in 0..<count {
                if !text_read_value(r,s,type.elem,data[i*int(elem.size):][:elem.size],is_text && type_is_bytes(s,type.elem)) {
                    text_error_within_index(r,i)
                    return false
                }
                text_accept(r,',')
            }
            text_expect(r,']') or_return
            held.data=raw_data(data)
        }
        held.len=count
        if len(bytes)>=size_of(runtime.Raw_Dynamic_Array) {
            // A dynamic array, which grows in the allocator its elements were read into.
            intrinsics.unaligned_store((^runtime.Raw_Dynamic_Array)(raw_data(bytes)),runtime.Raw_Dynamic_Array{held.data,count,count,r.values})
            return true
        }
        intrinsics.unaligned_store((^runtime.Raw_Slice)(raw_data(bytes)),held)
        return true
    case .String:
        text:=text_string(r) or_return
        copied:string
        if text!="" {
            data,error:=mem.alloc_bytes(len(text),1,r.values)
            if error!=nil || len(data)<len(text) {return text_fail(r,.Out_Of_Memory,start)}
            copy(data,text)
            copied=string(data)
        }
        intrinsics.unaligned_store((^string)(raw_data(bytes)),copied)
        return true
    case .Json:
        text_skip(r) or_return
        intrinsics.unaligned_store((^string)(raw_data(bytes)),r.text[start:r.offset])
        return true
    }
    return false
}
