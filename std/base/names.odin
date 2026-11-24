package base

import "base:runtime"
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
name_fold_into :: proc "contextless" (name:string,out:[]u8) -> string {
    count:=0
    for c in transmute([]u8)name {
        if name_separator(c) {continue}
        if count>=len(out) {break}
        out[count]=name_lower(c)
        count+=1
    }
    return string(out[:count])
}

@(private="file")
name_fold :: proc(name:string,allocator:runtime.Allocator) -> string {
    out,error:=make([]u8,len(name),allocator)
    if error!=nil {return ""}
    return name_fold_into(name,out)
}

// ASCII byte edit distance in one reusable row of len(a)+1 ints (or stack for <= 63 bytes).
@(private="file")
name_edit_distance :: proc "contextless" (a,b:string,row:[]int) -> int {
    m,n:=len(a),len(b)
    if m==0 {return n}
    if n==0 {return m}
    if len(row)<m+1 {return max(m,n)}
    for i in 0..=m {row[i]=i}
    for j in 0..<n {
        prev:=row[0]
        row[0]=j+1
        bj:=b[j]
        for i in 0..<m {
            above:=row[i+1]
            cost:=prev+(0 if a[i]==bj else 1)
            del:=above+1
            ins:=row[i]+1
            if del<cost {cost=del}
            if ins<cost {cost=ins}
            prev=above
            row[i+1]=cost
        }
    }
    return row[m]
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

Name_Near :: struct {index,kind,distance:int}

// Streaming top-K nearest matcher: keeps O(len(out)) memory regardless of candidate count.
Name_Nearest :: struct {
    wanted:string,
    room:int,
    best:[]Name_Near,
    count:int,
    fold_buf:[]u8,
    row_buf:[]int,
    allocator:runtime.Allocator,
    ok:bool,
}

name_nearest_init :: proc(n:^Name_Nearest,name:string,limit:int,allocator:=context.temp_allocator) -> bool {
    n^={allocator=allocator}
    if limit<=0 {return false}
    best,e1:=make([]Name_Near,limit,allocator)
    if e1!=nil {return false}
    wanted:=name_fold(name,allocator)
    if len(name)>0 && wanted=="" {return false}
    row,e2:=make([]int,len(wanted)+1,allocator)
    if e2!=nil {return false}
    n.wanted=wanted
    n.room=max(len(wanted)/3,1)
    n.best=best
    n.row_buf=row
    n.ok=true
    return true
}

name_nearest_add :: proc(n:^Name_Nearest,index:int,candidate:string) {
    if !n.ok {return}
    stack_fold:[256]u8
    buf:=stack_fold[:]
    if len(candidate)>len(stack_fold) {
        if len(n.fold_buf)<len(candidate) {
            grown,err:=make([]u8,len(candidate),n.allocator)
            if err!=nil {return}
            n.fold_buf=grown
        }
        buf=n.fold_buf
    }
    folded:=name_fold_into(candidate,buf)
    last:=folded[strings.last_index_byte(folded,'/')+1:]
    wanted:=n.wanted
    kind:=-1
    switch {
    case len(wanted)>=3 && strings.contains(folded,wanted):    kind=0
    case len(wanted)*3>=len(last) && name_inside(wanted,last): kind=1
    }
    distance:int
    if kind<0 {
        if abs(len(wanted)-len(last))>n.room {return}
        distance=name_edit_distance(wanted,last,n.row_buf)
        if distance>n.room {return}
        kind=2
    } else {
        distance=name_edit_distance(wanted,last,n.row_buf)
    }
    entry:=Name_Near{index,kind,distance}
    limit:=len(n.best)
    if n.count==limit {
        worst:=n.best[limit-1]
        if entry.kind>worst.kind || (entry.kind==worst.kind && entry.distance>=worst.distance) {return}
    } else {
        n.count+=1
    }
    at:=n.count-1
    for at>0 {
        prev:=n.best[at-1]
        if prev.kind<entry.kind || (prev.kind==entry.kind && prev.distance<=entry.distance) {break}
        n.best[at]=prev
        at-=1
    }
    n.best[at]=entry
}

name_nearest_finish :: proc "contextless" (n:^Name_Nearest,out:[]int) -> int {
    count:=min(n.count,len(out))
    for i in 0..<count {out[i]=n.best[i].index}
    return count
}

// The indices of the candidates near a name in out, the nearest first; how
// many. A candidate with slashes is compared by its last part. Near is holding
// the name, having its letters in order and being at most three times as
// long, or an edit distance small for its length; nothing near lists nothing.
names_nearest :: proc(name:string,candidates:[]string,out:[]int,allocator:=context.temp_allocator) -> int {
    n:Name_Nearest
    if !name_nearest_init(&n,name,min(len(out),len(candidates)),allocator) {return 0}
    for candidate,i in candidates {name_nearest_add(&n,i,candidate)}
    return name_nearest_finish(&n,out)
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
        for fit,i in fits {
            if i>0 {strings.write_string(&b,", ")}
            strings.write_string(&b,fit)
        }
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
