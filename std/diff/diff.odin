// Line diff of texts and their three-way merge. Lines are interned to ids in
// one table sized to the inputs and compared with the histogram search: a
// match anchors on the rarest line two ranges share and the ranges around it
// are compared the same way. Lines more frequent than MAX_CHAIN in a range do
// not anchor, so such a range becomes one replace hunk; memory is linear in the
// lines and the search stops refining past WORK_PER_LINE steps per line.
package diff

import "base:runtime"
import "core:hash/xxhash"
import "core:slice"

Op :: enum u8 {Same,Add,Remove}
Line :: struct {
    op:Op,
    old,new:i32, // line numbers from 1 in each text; 0 where the line is not in it
    start,end:i32, // bytes of the line in the text it comes from (old for Remove; new for Same and Add), without its line break
}
Stats :: struct {added,removed:int}
Row :: struct {
    line:i32, // index into the lines; -1 for a fold
    skipped:i32, // lines of Same a fold stands for
}

Text :: enum u8 {Base,Ours,Theirs}
Range :: struct {start,end:i32} // bytes
Hunk :: struct {
    bytes:[Text]Range, // the hunk in each text: whole lines with their line breaks
    conflict:bool,     // ours and theirs change these lines of base differently
    take:Text,         // without a conflict: the text whose bytes the merge keeps
}

Error :: enum u8 {
    None,
    Out_Of_Memory,
    Too_Large,    // the texts of one call add up to more than MAX_BYTES
    Conflict,     // merged: a hunk is a conflict, which only the caller can resolve
    Invalid_Hunk, // merged: a hunk names bytes outside its text or a text that does not exist
}

MAX_BYTES :: int(max(i32))

@(private)
MAX_CHAIN :: 63 // occurrences in a range of old above which a line does not anchor a match
@(private)
WORK_PER_LINE :: 256 // search steps per line of the inputs; past them each range left is replaced whole

@(private)
Split :: struct {
    starts:[]i32, // the byte each line starts at, then the length of the text
    ids:[]u32,    // the interned id of each line
}

@(private)
Ranges :: struct {a0,a1,b0,b1:int}

@(private)
split_delete :: proc(splits:[]Split,allocator:runtime.Allocator) {
    for s in splits {delete(s.starts,allocator);delete(s.ids,allocator)}
}

// A line with its break when whole, else without "\n" or "\r\n".
@(private)
line_text :: proc(text:string,starts:[]i32,i:int,whole:bool) -> string {
    s,e:=int(starts[i]),int(starts[i+1])
    if !whole&&e>s&&text[e-1]=='\n' {
        e-=1
        if e>s&&text[e-1]=='\r' {e-=1}
    }
    return text[s:e]
}

// Splits the texts into lines and gives each distinct line one id across all
// of them. tokens is the count of ids.
@(private)
prepare :: proc(texts:[]string,whole:bool,out:[]Split,allocator:runtime.Allocator) -> (tokens:int,err:runtime.Allocator_Error) {
    total:=0
    for text,k in texts {
        n:=0
        for i in 0..<len(text) {if text[i]=='\n' {n+=1}}
        if len(text)>0&&text[len(text)-1]!='\n' {n+=1}
        out[k].starts=make([]i32,n+1,allocator) or_return
        out[k].ids=make([]u32,n,allocator) or_return
        at,start:=0,0
        for i in 0..<len(text) {
            if text[i]=='\n' {out[k].starts[at]=i32(start);at+=1;start=i+1}
        }
        if start<len(text) {out[k].starts[at]=i32(start)}
        out[k].starts[n]=i32(len(text))
        total+=n
    }
    capacity:=16
    for capacity<2*total {capacity*=2}
    slots:=make([]u32,capacity,allocator) or_return // id+1 of the line at each slot; 0 when free
    defer delete(slots,allocator)
    keys:=make([]string,total,allocator) or_return
    defer delete(keys,allocator)
    hashes:=make([]u64,total,allocator) or_return
    defer delete(hashes,allocator)
    mask:=u64(capacity-1)
    for text,k in texts {
        s:=out[k]
        for i in 0..<len(s.ids) {
            key:=line_text(text,s.starts,i,whole)
            h:=xxhash.XXH3_64_default(transmute([]u8)key)
            at:=h&mask
            for {
                slot:=slots[at]
                if slot==0 {
                    slots[at]=u32(tokens)+1
                    keys[tokens],hashes[tokens]=key,h
                    s.ids[i]=u32(tokens)
                    tokens+=1
                    break
                }
                if hashes[slot-1]==h&&keys[slot-1]==key {s.ids[i]=slot-1;break}
                at=(at+1)&mask
            }
        }
    }
    return
}

// Marks the lines of a and of b that are outside the common subsequence the
// histogram search finds.
@(private)
compare :: proc(a,b:[]u32,tokens:int,removed,added:[]bool,allocator:runtime.Allocator) -> runtime.Allocator_Error {
    count:=make([]u32,tokens,allocator) or_return // occurrences of each id in the range of a being searched
    defer delete(count,allocator)
    head:=make([]i32,tokens,allocator) or_return // first occurrence of each id in that range; -1 when none
    defer delete(head,allocator)
    next:=make([]i32,len(a),allocator) or_return // next occurrence of the id of each line of a; -1 when none
    defer delete(next,allocator)
    stack:=make([dynamic]Ranges,0,64,allocator) or_return
    defer delete(stack)
    for &h in head {h=-1}
    budget:=WORK_PER_LINE*(len(a)+len(b))
    if _,e:=append(&stack,Ranges{0,len(a),0,len(b)});e!=nil {return e}
    for len(stack)>0 {
        r:=pop(&stack)
        a0,a1,b0,b1:=r.a0,r.a1,r.b0,r.b1
        for a0<a1&&b0<b1&&a[a0]==b[b0] {a0+=1;b0+=1}
        for a0<a1&&b0<b1&&a[a1-1]==b[b1-1] {a1-=1;b1-=1}
        length,rarest,at_a,at_b:=0,MAX_CHAIN+1,0,0
        if a0<a1&&b0<b1&&budget>0 {
            budget-=(a1-a0)+(b1-b0)
            for i:=a1-1;i>=a0;i-=1 {t:=a[i];next[i]=head[t];head[t]=i32(i);count[t]+=1}
            for j:=b0;j<b1; {
                step:=j+1
                if c:=int(count[b[j]]);c>0&&c<=min(rarest,MAX_CHAIN) {
                    for i:=int(head[b[j]]);i>=0;i=int(next[i]) {
                        s,u:=i,j
                        for s>a0&&u>b0&&a[s-1]==b[u-1] {s-=1;u-=1}
                        e,v:=i+1,j+1
                        for e<a1&&v<b1&&a[e]==b[v] {e+=1;v+=1}
                        low:=c
                        for k in s..<e {low=min(low,int(count[a[k]]))}
                        budget-=e-s
                        if e-s>length||low<rarest {length,rarest,at_a,at_b=e-s,low,s,u}
                        step=max(step,v)
                    }
                }
                j=step
            }
            for i in a0..<a1 {head[a[i]]=-1;count[a[i]]=0}
        }
        if length==0 {
            for i in a0..<a1 {removed[i]=true}
            for j in b0..<b1 {added[j]=true}
            continue
        }
        if _,e:=append(&stack,Ranges{a0,at_a,b0,at_b});e!=nil {return e}
        if _,e:=append(&stack,Ranges{at_a+length,a1,at_b+length,b1});e!=nil {return e}
    }
    return nil
}

// The lines of new as edits of old, in order. A line break is not part of a
// line, so "\r\n" and "\n" compare equal. allocator is for the work.
lines :: proc(old,new:string,out:^[dynamic]Line,allocator:=context.allocator) -> (stats:Stats,err:Error) {
    clear(out)
    if len(old)+len(new)>MAX_BYTES {return {},.Too_Large}
    split:[2]Split
    defer split_delete(split[:],allocator)
    tokens,e:=prepare([]string{old,new},false,split[:],allocator)
    if e!=nil {return {},.Out_Of_Memory}
    a,b:=split[0],split[1]
    n,m:=len(a.ids),len(b.ids)
    removed,e1:=make([]bool,n,allocator)
    defer delete(removed,allocator)
    added,e2:=make([]bool,m,allocator)
    defer delete(added,allocator)
    if e1!=nil||e2!=nil||compare(a.ids,b.ids,tokens,removed,added,allocator)!=nil {return {},.Out_Of_Memory}
    same:=0
    for r in removed {if !r {same+=1}}
    if resize(out,n+m-same)!=nil {return {},.Out_Of_Memory}
    i,j:=0,0
    for &line in out {
        if i<n&&j<m&&!removed[i]&&!added[j] {
            line={.Same,i32(i+1),i32(j+1),0,0}
            i+=1;j+=1
        } else if i<n&&(removed[i]||j==m) {
            s:=line_text(old,a.starts,i,false)
            line={.Remove,i32(i+1),0,a.starts[i],a.starts[i]+i32(len(s))}
            i+=1;stats.removed+=1
            continue
        } else {
            line={.Add,0,i32(j+1),0,0}
            j+=1;stats.added+=1
        }
        s:=line_text(new,b.starts,j-1,false)
        line.start,line.end=b.starts[j-1],b.starts[j-1]+i32(len(s))
    }
    return
}

// What a view shows: every Add and Remove with up to context lines of Same around each run; longer runs of Same between them fold into one row.
rows :: proc(lines:[]Line,context_lines:int,out:^[dynamic]Row) -> Error {
    clear(out)
    if resize(out,len(lines))!=nil {return .Out_Of_Memory}
    around:=max(context_lines,0)
    at:=0
    for i:=0;i<len(lines); {
        if lines[i].op!=.Same {out[at]={line=i32(i)};at+=1;i+=1;continue}
        end:=i
        for end<len(lines)&&lines[end].op==.Same {end+=1}
        head:=0 if i==0 else around
        tail:=0 if end==len(lines) else around
        if end-i<=head+tail {
            for j in i..<end {out[at]={line=i32(j)};at+=1}
        } else {
            for j in i..<i+head {out[at]={line=i32(j)};at+=1}
            out[at]={line=-1,skipped=i32(end-i-head-tail)};at+=1
            for j in end-tail..<end {out[at]={line=i32(j)};at+=1}
        }
        i=end
    }
    if resize(out,at)!=nil {return .Out_Of_Memory}
    return .None
}

// Merges the changes ours and theirs make to base. The hunks cover each text
// in order, whole lines with their bytes as they are (line breaks included);
// where ours and theirs change the same lines differently a hunk is a conflict.
// allocator is for the work.
merge3 :: proc(base,ours,theirs:string,out:^[dynamic]Hunk,allocator:=context.allocator) -> (conflicts:int,err:Error) {
    clear(out)
    if len(base)+len(ours)+len(theirs)>MAX_BYTES {return 0,.Too_Large}
    split:[Text]Split
    defer split_delete(slice.enumerated_array(&split),allocator)
    tokens,e:=prepare([]string{base,ours,theirs},true,slice.enumerated_array(&split),allocator)
    if e!=nil {return 0,.Out_Of_Memory}
    nb:=len(split[.Base].ids)
    // Per line of base, its line in ours and in theirs; -1 when it is not there.
    match:[2][]i32
    defer for m in match {delete(m,allocator)}
    for side in 0..<2 {
        other:=split[Text(side+1)].ids
        removed,e1:=make([]bool,nb,allocator)
        added,e2:=make([]bool,len(other),allocator)
        m,e3:=make([]i32,nb,allocator)
        match[side]=m
        failed:=e1!=nil||e2!=nil||e3!=nil||compare(split[.Base].ids,other,tokens,removed,added,allocator)!=nil
        if !failed {
            j:=0
            for i in 0..<nb {
                if removed[i] {m[i]=-1;continue}
                for j<len(other)&&added[j] {j+=1}
                m[i]=i32(j)
                j+=1
            }
        }
        delete(removed,allocator)
        delete(added,allocator)
        if failed {return 0,.Out_Of_Memory}
    }
    push :: proc(out:^[dynamic]Hunk,split:^[Text]Split,from,to:[Text]int,conflict:bool,take:Text) -> bool {
        h:=Hunk{conflict=conflict,take=take}
        for k in Text {h.bytes[k]={split[k].starts[from[k]],split[k].starts[to[k]]}}
        _,e:=append(out,h)
        return e==nil
    }
    ends:=[Text]int{.Base=nb,.Ours=len(split[.Ours].ids),.Theirs=len(split[.Theirs].ids)}
    at:[Text]int
    for {
        from:=at
        for at[.Base]<nb&&int(match[0][at[.Base]])==at[.Ours]&&int(match[1][at[.Base]])==at[.Theirs] {
            for &k in at {k+=1}
        }
        if at!=from&&!push(out,&split,from,at,false,.Base) {return 0,.Out_Of_Memory}
        if at==ends {break}
        to:=ends
        for k in at[.Base]..<nb {
            if match[0][k]>=0&&match[1][k]>=0 {to={.Base=k,.Ours=int(match[0][k]),.Theirs=int(match[1][k])};break}
        }
        side:[Text][]u32
        for k in Text {side[k]=split[k].ids[at[k]:to[k]]}
        conflict,take:=false,Text.Base
        switch {
        case slice.equal(side[.Ours],side[.Base]):take=.Theirs
        case slice.equal(side[.Theirs],side[.Base])||slice.equal(side[.Ours],side[.Theirs]):take=.Ours
        case:conflict=true;conflicts+=1
        }
        if !push(out,&split,at,to,conflict,take) {return 0,.Out_Of_Memory}
        at=to
    }
    return
}

// Appends to out the text the hunks of a merge without conflicts make.
merged :: proc(base,ours,theirs:string,hunks:[]Hunk,out:^[dynamic]u8) -> Error {
    texts:=[Text]string{.Base=base,.Ours=ours,.Theirs=theirs}
    size:=0
    for h in hunks {
        if h.take>max(Text) {return .Invalid_Hunk}
        for r,k in h.bytes {
            if r.start<0||r.start>r.end||int(r.end)>len(texts[k]) {return .Invalid_Hunk}
        }
        if h.conflict {return .Conflict}
        size+=int(h.bytes[h.take].end-h.bytes[h.take].start)
    }
    at:=len(out)
    if resize(out,at+size)!=nil {return .Out_Of_Memory}
    for h in hunks {
        r:=h.bytes[h.take]
        at+=copy(out[at:],texts[h.take][r.start:r.end])
    }
    return .None
}
