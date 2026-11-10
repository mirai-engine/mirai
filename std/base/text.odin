package base

import "core:strings"
import "core:fmt"

// Text stored inline in a fixed byte array, the form the schema flag .Text
// describes: UTF-8 followed by NULs up to the end of the array. The last byte
// is always a NUL, so an array of N bytes holds at most N-1 bytes of text.
// The padding is all zeros: equal texts are equal arrays, byte for byte.

// Largest prefix of the text that fits in `room` bytes without splitting a code point.
@(private)
text_fit :: proc "contextless" (text:string,room:int) -> int {
    if len(text)<=room {return len(text)}
    cut:=max(room,0)
    for cut>0 && text[cut]&0xc0==0x80 {cut-=1}
    return cut
}
// False when the text had to be cut to fit.
text_set :: proc "contextless" (buffer:[]u8,text:string) -> bool {
    kept:=text_fit(text,len(buffer)-1)
    copy(buffer,text[:kept])
    for &b in buffer[kept:] {b=0}
    return kept==len(text)
}
// The text in the array; it points into it.
text_get :: proc "contextless" (buffer:[]u8) -> string {return string(buffer[:text_len(buffer)])}
text_len :: proc "contextless" (buffer:[]u8) -> int {
    for b,i in buffer {if b==0 {return i}}
    return len(buffer)
}
text_clear :: proc "contextless" (buffer:[]u8) {
    for &b in buffer {b=0}
}
text_equal :: proc "contextless" (buffer:[]u8,text:string) -> bool {return text_get(buffer)==text}
// -1, 0 or 1: the order of the two texts byte by byte.
text_compare :: proc "contextless" (a,b:[]u8) -> int {
    x,y:=text_get(a),text_get(b)
    for i in 0..<min(len(x),len(y)) {
        if x[i]!=y[i] {return -1 if x[i]<y[i] else 1}
    }
    return -1 if len(x)<len(y) else 1 if len(x)>len(y) else 0
}
// False when the addition had to be cut to fit.
text_append :: proc "contextless" (buffer:[]u8,text:string) -> bool {
    used:=text_len(buffer)
    if used>=len(buffer) {return len(text)==0}
    return text_set(buffer[used:],text)
}
// Writes the formatted text; false when it had to be cut to fit.
text_format :: proc(buffer:[]u8,format:string,args:..any) -> bool {
    if len(buffer)==0 {return false}
    written:=len(fmt.bprintf(buffer,format,..args))
    // fmt stops at the end of the array: reaching it means there was more to write, or no room for the NUL.
    complete:=written<len(buffer)
    kept:=written if complete else text_valid_prefix(buffer[:len(buffer)-1])
    for &b in buffer[kept:] {b=0}
    return complete
}

// Length of the longest prefix that does not end inside a code point.
@(private)
text_valid_prefix :: proc "contextless" (bytes:[]u8) -> int {
    end:=len(bytes)
    start:=end
    for start>0 && bytes[start-1]&0xc0==0x80 {start-=1}
    if start==0 {return end if end==0 else 0}
    lead:=bytes[start-1]
    needed:=1
    switch {
    case lead>=0xf0: needed=4
    case lead>=0xe0: needed=3
    case lead>=0xc0: needed=2
    }
    return end if end-(start-1)==needed else start-1
}

// True when text holds part, without minding upper and lower case.
contains_fold :: proc(text,part:string) -> bool {
    if len(part)>len(text) {return false}
    for i in 0..=len(text)-len(part) {
        if strings.equal_fold(text[i:][:len(part)],part) {return true}
    }
    return false
}
