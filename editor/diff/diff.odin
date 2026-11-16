package diff

import "core:hash"
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

@(private)
Span :: struct {start,end:i32,hash:u64}

@(private)
split :: proc(text:string,spans:^[dynamic]Span) {
    span :: proc(text:string,start,end:int) -> Span {
        return {i32(start),i32(end),hash.fnv64a(transmute([]u8)text[start:end])}
    }
    start:=0
    for i in 0..<len(text) {
        if text[i]!='\n' {continue}
        end:=i
        if end>start&&text[end-1]=='\r' {end-=1}
        append(spans,span(text,start,end))
        start=i+1
    }
    if start<len(text) {append(spans,span(text,start,len(text)))}
}

@(private)
same :: proc(old,new:string,a,b:Span) -> bool {
    return a.hash==b.hash&&old[a.start:a.end]==new[b.start:b.end]
}

// Step d of the trace keeps the furthest x of each diagonal k in -d..d (step 2) at d*(d+1)/2+(k+d)/2; -1 when no path of d edits ends on it inside the grid.
@(private)
pick :: proc(trace:[]i32,d,k,n,m:int) -> (x,from:int) {
    if d==0 {return 0,0}
    prev:=d*(d-1)/2
    x,from=-1,0
    if k<d {if p:=int(trace[prev+(k+d)/2]);p>=0&&p-k-1<m {x,from=p,k+1}}
    if k>-d {if p:=int(trace[prev+(k+d-2)/2]);p>=0&&p<n&&p+1>x {x,from=p+1,k-1}}
    return
}

@(private)
script :: proc(old,new:string,a,b:[]Span,max_edits:int,ops:^[dynamic]Op) -> bool {
    n,m:=len(a),len(b)
    if n==0||m==0 {return false}
    trace:[dynamic]i32
    defer delete(trace)
    end:=-1
    search: for d in 0..=min(max_edits,n+m) {
        base:=len(trace)
        resize(&trace,base+d+1)
        for k:=-d;k<=d;k+=2 {
            x,_:=pick(trace[:],d,k,n,m)
            if x>=0 {for x<n&&x-k<m&&same(old,new,a[x],b[x-k]) {x+=1}}
            trace[base+(k+d)/2]=i32(x)
            if x==n&&x-k==m {end=d;break search}
        }
    }
    if end<0 {return false}
    x,y:=n,m
    for d:=end;d>0;d-=1 {
        k:=x-y
        mx,from:=pick(trace[:],d,k,n,m)
        for ;x>mx;x-=1 {append(ops,Op.Same)}
        if from==k+1 {append(ops,Op.Add);x,y=mx,mx-k-1} else {append(ops,Op.Remove);x,y=mx-1,mx-k}
    }
    for ;x>0;x-=1 {append(ops,Op.Same)}
    slice.reverse(ops[:])
    return true
}

// The lines of new as edits of old, in order.
lines :: proc(old,new:string,out:^[dynamic]Line,max_edits:=2048) -> Stats {
    clear(out)
    a,b:[dynamic]Span
    ops:[dynamic]Op
    defer {delete(a);delete(b);delete(ops)}
    split(old,&a);split(new,&b)
    prefix,suffix:=0,0
    for prefix<len(a)&&prefix<len(b)&&same(old,new,a[prefix],b[prefix]) {prefix+=1}
    for suffix<len(a)-prefix&&suffix<len(b)-prefix&&same(old,new,a[len(a)-1-suffix],b[len(b)-1-suffix]) {suffix+=1}
    middle_a,middle_b:=a[prefix:len(a)-suffix],b[prefix:len(b)-suffix]
    if !script(old,new,middle_a,middle_b,max_edits,&ops) {
        clear(&ops)
        for _ in middle_a {append(&ops,Op.Remove)}
        for _ in middle_b {append(&ops,Op.Add)}
    }
    stats:Stats
    i,j:=0,0
    emit :: proc(out:^[dynamic]Line,stats:^Stats,op:Op,a,b:[]Span,i,j:^int) {
        switch op {
        case .Same:append(out,Line{.Same,i32(i^+1),i32(j^+1),b[j^].start,b[j^].end});i^+=1;j^+=1
        case .Add:append(out,Line{.Add,0,i32(j^+1),b[j^].start,b[j^].end});j^+=1;stats.added+=1
        case .Remove:append(out,Line{.Remove,i32(i^+1),0,a[i^].start,a[i^].end});i^+=1;stats.removed+=1
        }
    }
    for _ in 0..<prefix {emit(out,&stats,.Same,a[:],b[:],&i,&j)}
    for k:=0;k<len(ops); {
        run:=k
        for run<len(ops)&&ops[run]!=.Same {run+=1}
        if run==k {emit(out,&stats,.Same,a[:],b[:],&i,&j);k+=1;continue}
        removed:=slice.count(ops[k:run],Op.Remove)
        for _ in 0..<removed {emit(out,&stats,.Remove,a[:],b[:],&i,&j)}
        for _ in 0..<run-k-removed {emit(out,&stats,.Add,a[:],b[:],&i,&j)}
        k=run
    }
    for _ in 0..<suffix {emit(out,&stats,.Same,a[:],b[:],&i,&j)}
    return stats
}

// What a view shows: every Add and Remove with up to context lines of Same around each run; longer runs of Same between them fold into one row.
rows :: proc(lines:[]Line,context_lines:int,out:^[dynamic]Row) {
    clear(out)
    around:=max(context_lines,0)
    for i:=0;i<len(lines); {
        if lines[i].op!=.Same {append(out,Row{line=i32(i)});i+=1;continue}
        end:=i
        for end<len(lines)&&lines[end].op==.Same {end+=1}
        head:=0 if i==0 else around
        tail:=0 if end==len(lines) else around
        if end-i<=head+tail {
            for j in i..<end {append(out,Row{line=i32(j)})}
        } else {
            for j in i..<i+head {append(out,Row{line=i32(j)})}
            append(out,Row{line=-1,skipped=i32(end-i-head-tail)})
            for j in end-tail..<end {append(out,Row{line=i32(j)})}
        }
        i=end
    }
}
