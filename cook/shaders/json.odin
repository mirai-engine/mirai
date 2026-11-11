package shaders

import "core:math"
import "core:strconv"
import "core:strings"

// Writes JSON as the manifests and catalogs are stored: two spaces of
// indentation, one member or element per line, ASCII only.
@(private)
Json_Writer :: struct {
    builder:strings.Builder,
    depth:  int,
    counts: [16]int, // members written at each depth
    after_key:bool,
}

@(private)
json_writer :: proc(allocator:=context.allocator) -> Json_Writer {
    return {builder=strings.builder_make(allocator)}
}

// The document, ended by a line feed.
@(private)
json_finish :: proc(writer:^Json_Writer) -> []u8 {
    strings.write_byte(&writer.builder,'\n')
    return writer.builder.buf[:]
}

@(private="file")
json_separate :: proc(writer:^Json_Writer) {
    if writer.after_key {writer.after_key=false;return}
    if writer.depth==0 {return}
    if writer.counts[writer.depth]>0 {strings.write_byte(&writer.builder,',')}
    writer.counts[writer.depth]+=1
    json_line(writer)
}

@(private="file")
json_line :: proc(writer:^Json_Writer) {
    strings.write_byte(&writer.builder,'\n')
    for _ in 0..<writer.depth {strings.write_string(&writer.builder,"  ")}
}

@(private="file")
json_open :: proc(writer:^Json_Writer,bracket:u8) {
    json_separate(writer)
    strings.write_byte(&writer.builder,bracket)
    writer.depth+=1
    writer.counts[writer.depth]=0
}

@(private="file")
json_close :: proc(writer:^Json_Writer,bracket:u8) {
    empty:=writer.counts[writer.depth]==0
    writer.depth-=1
    if !empty {json_line(writer)}
    strings.write_byte(&writer.builder,bracket)
}

@(private)
json_object_begin :: proc(writer:^Json_Writer) {json_open(writer,'{')}
@(private)
json_object_end :: proc(writer:^Json_Writer) {json_close(writer,'}')}
@(private)
json_array_begin :: proc(writer:^Json_Writer) {json_open(writer,'[')}
@(private)
json_array_end :: proc(writer:^Json_Writer) {json_close(writer,']')}

@(private)
json_key :: proc(writer:^Json_Writer,key:string) {
    json_separate(writer)
    json_quote(&writer.builder,key)
    strings.write_string(&writer.builder,": ")
    writer.after_key=true
}

@(private)
json_string :: proc(writer:^Json_Writer,value:string) {
    json_separate(writer)
    json_quote(&writer.builder,value)
}

@(private)
json_integer :: proc(writer:^Json_Writer,value:i64) {
    json_separate(writer)
    strings.write_i64(&writer.builder,value)
}

@(private)
json_bool :: proc(writer:^Json_Writer,value:bool) {
    json_separate(writer)
    strings.write_string(&writer.builder,"true" if value else "false")
}

@(private)
json_float :: proc(writer:^Json_Writer,value:f64) {
    json_separate(writer)
    float_text(&writer.builder,value)
}

@(private)
json_number :: proc(writer:^Json_Writer,value:Number) {
    if value.is_float {json_float(writer,value.float)} else {json_integer(writer,value.integer)}
}

@(private="file")
json_quote :: proc(builder:^strings.Builder,text:string) {
    DIGITS:="0123456789abcdef"
    escape :: proc(builder:^strings.Builder,unit:u16,digits:string) {
        strings.write_string(builder,"\\u")
        for shift:=uint(12);;shift-=4 {
            strings.write_byte(builder,digits[(unit>>shift)&15])
            if shift==0 {break}
        }
    }
    strings.write_byte(builder,'"')
    for r in text {
        switch r {
        case '"': strings.write_string(builder,"\\\"")
        case '\\': strings.write_string(builder,"\\\\")
        case '\n': strings.write_string(builder,"\\n")
        case '\r': strings.write_string(builder,"\\r")
        case '\t': strings.write_string(builder,"\\t")
        case '\b': strings.write_string(builder,"\\b")
        case '\f': strings.write_string(builder,"\\f")
        case:
            if r>=0x20 && r<0x7f {
                strings.write_byte(builder,u8(r))
            } else if r<0x10000 {
                escape(builder,u16(r),DIGITS)
            } else {
                // Outside the basic plane: a surrogate pair.
                v:=u32(r)-0x10000
                escape(builder,u16(0xd800+(v>>10)),DIGITS)
                escape(builder,u16(0xdc00+(v&0x3ff)),DIGITS)
            }
        }
    }
    strings.write_byte(builder,'"')
}

// A number as its source wrote it: 1 stays an integer and 1.0 a float.
Number :: struct {is_float:bool,integer:i64,float:f64}

@(private)
number_value :: proc(n:Number) -> f64 {return n.float if n.is_float else f64(n.integer)}

// The shortest decimal that reads back as the same float of `bits` bits:
// "0.5", "100.0", "1e+20", "1e-05". Exponents below -4 or from 16 use
// scientific notation.
@(private)
float_text :: proc(builder:^strings.Builder,value:f64,bits:=64) {
    if math.is_nan(value) {strings.write_string(builder,"NaN");return}
    if math.is_inf(value) {strings.write_string(builder,"-Infinity" if value<0 else "Infinity");return}
    if value==0 {strings.write_string(builder,"-0.0" if math.sign_bit(value) else "0.0");return}
    buffer:[64]u8
    // "+d.ddddde+XX": the shortest digits, one of them before the point.
    scientific:=string(strconv.generic_ftoa(buffer[:],value,'e',-1,bits,{.Plus}))
    negative:=scientific[0]=='-'
    scientific=scientific[1:]
    at:=strings.index_byte(scientific,'e')
    exponent,_:=strconv.parse_int(scientific[at+1:],10)
    digits_buffer:[32]u8
    count:=0
    for c in transmute([]u8)scientific[:at] {
        if c!='.' {digits_buffer[count]=c;count+=1}
    }
    for count>1 && digits_buffer[count-1]=='0' {count-=1}
    digits:=string(digits_buffer[:count])
    if negative {strings.write_byte(builder,'-')}
    switch {
    case exponent< -4 || exponent>=16:
        strings.write_string(builder,digits[:1])
        if count>1 {strings.write_byte(builder,'.');strings.write_string(builder,digits[1:])}
        strings.write_byte(builder,'e')
        strings.write_byte(builder,'-' if exponent<0 else '+')
        magnitude:=abs(exponent)
        if magnitude<10 {strings.write_byte(builder,'0')}
        strings.write_int(builder,magnitude)
    case exponent<0:
        strings.write_string(builder,"0.")
        for _ in 0..<(-exponent-1) {strings.write_byte(builder,'0')}
        strings.write_string(builder,digits)
    case count<=exponent+1:
        strings.write_string(builder,digits)
        for _ in 0..<(exponent+1-count) {strings.write_byte(builder,'0')}
        strings.write_string(builder,".0")
    case:
        strings.write_string(builder,digits[:exponent+1])
        strings.write_byte(builder,'.')
        strings.write_string(builder,digits[exponent+1:])
    }
}
