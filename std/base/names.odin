package base

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// How a name a person or an agent writes meets the names of a registry: case,
// underscores, spaces and hyphens do not count, and a name only resolves to
// the one candidate it can mean.

// The most candidates an error about a name repeats.
NAME_NEAREST :: 5
// The most of a name an error repeats.
NAME_ECHO_BYTES :: 64

@(private="file")
name_separator :: #force_inline proc "contextless" (c:u8) -> bool {return c=='_' || c==' ' || c=='-'}

@(private="file")
name_lower :: #force_inline proc "contextless" (c:u8) -> u8 {return c>='A' && c<='Z'?c+32:c}

// Whether two names differ only in case and separators. Nothing but
// separators names nothing.
name_same :: proc "contextless" (a,b:string) -> bool {
    i,j:=0,0
    letters:=false
    for {
        for i<len(a) && name_separator(a[i]) {i+=1}
        for j<len(b) && name_separator(b[j]) {j+=1}
        if i==len(a) || j==len(b) {return i==len(a) && j==len(b) && letters}
        if name_lower(a[i])!=name_lower(b[j]) {return false}
        i+=1;j+=1
        letters=true
    }
}

// The candidate a name means: the one written exactly so, or the only one
// name_same takes. index is -1 unless exactly one fits; matches says how many.
name_find :: proc "contextless" (name:string,candidates:[]string) -> (index,matches:int) {
    for candidate,i in candidates {
        if candidate==name {return i,1}
    }
    index=-1
    for candidate,i in candidates {
        if name_same(name,candidate) {index=i;matches+=1}
    }
    if matches!=1 {index=-1}
    return
}

@(private="file")
name_fold :: proc(name:string,allocator:runtime.Allocator) -> string {
    out,_:=make([]u8,len(name),allocator)
    if out==nil {return ""}
    count:=0
    for c in transmute([]u8)name {
        if name_separator(c) {continue}
        out[count]=name_lower(c)
        count+=1
    }
    return string(out[:count])
}

// Whether the bytes of a come in the same order in b.
@(private="file")
name_inside :: proc "contextless" (a,b:string) -> bool {
    at:=0
    for c in transmute([]u8)b {
        if at<len(a) && a[at]==c {at+=1}
    }
    return at==len(a)
}

// The indices of the candidates nearest to a name in out, the nearest first;
// how many. A candidate with slashes is compared by its last part, and one
// that holds the name anywhere comes before one that only resembles it.
names_nearest :: proc(name:string,candidates:[]string,out:[]int,allocator:=context.temp_allocator) -> int {
    Near :: struct {index,kind,distance:int}
    near,_:=make([]Near,len(candidates),allocator)
    if near==nil {return 0}
    wanted:=name_fold(name,allocator)
    for candidate,i in candidates {
        folded:=name_fold(candidate,allocator)
        last:=folded[strings.last_index_byte(folded,'/')+1:]
        near[i]={i,strings.contains(folded,wanted)?0:name_inside(wanted,last)?1:2,strings.levenshtein_distance(wanted,last,allocator)}
    }
    slice.stable_sort_by(near,proc(a,b:Near) -> bool {return a.kind!=b.kind?a.kind<b.kind:a.distance<b.distance})
    count:=min(len(near),len(out))
    for i in 0..<count {out[i]=near[i].index}
    return count
}

// What is wrong with a name name_find did not resolve, with the names it
// could mean or the nearest ones: `"Foo" is not <noun>; the nearest are A, B`.
name_problem :: proc(name,noun:string,candidates:[]string,allocator:=context.temp_allocator) -> string {
    shown:=name
    if len(shown)>NAME_ECHO_BYTES {
        cut:=NAME_ECHO_BYTES
        for cut>0 && !utf8.rune_start(shown[cut]) {cut-=1}
        shown=shown[:cut]
    }
    b:=strings.builder_make(allocator)
    strings.write_quoted_string(&b,shown)
    fits:=make([dynamic]string,allocator)
    for candidate in candidates {
        if name_same(name,candidate) {append(&fits,candidate)}
    }
    if len(fits)>1 {
        strings.write_string(&b," fits several: ")
        strings.write_string(&b,strings.join(fits[:],", ",allocator))
        strings.write_string(&b,"; write one of them as it is")
        return strings.to_string(b)
    }
    strings.write_string(&b," is not ")
    strings.write_string(&b,noun)
    nearest:[NAME_NEAREST]int
    count:=names_nearest(name,candidates,nearest[:],allocator)
    for at,i in nearest[:count] {
        strings.write_string(&b,i==0?"; the nearest are ":", ")
        strings.write_string(&b,candidates[at])
    }
    return strings.to_string(b)
}
