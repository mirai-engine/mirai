package mirai_pcg

import "base:runtime"
import "core:math"
import "core:mem"
import "mirai:std/base"
import mm "mirai:std/math"

// 1-D shape grammar of scalable modules: a compiled program splits a length
// (a fence, wall, bridge or facade span along a spline or a polygon edge)
// into placed symbols. grammar_compile parses the source once:
//   [A, B]      sequence              [A, B]3   repeated 3 times
//   [A, B]*     as many as fit        [A, B]+   once, then as many as fit
//   <A, B>      the first child whose least length fits the length left
//   {A:3, B:1}  a weighted choice among the children that fit (weight 1 when omitted)
// Any item takes a suffix. After an identifier a count needs a space (`A 3`),
// since digits belong to identifiers (`Window2`). Whitespace is ignored.
// The repetitions are greedy: a `*` takes what its later siblings leave, and
// the length left over stretches the scalable modules in proportion.

GRAMMAR_MAX_DEPTH :: 32 // modules on the longest path from the root, the frames a solve needs at most
GRAMMAR_MAX_MODULES :: int(max(u16))
GRAMMAR_MAX_SYMBOLS :: 4096
GRAMMAR_REPEAT_FIT :: i16(-1) // `*`
GRAMMAR_REPEAT_SOME :: i16(-2) // `+`
GRAMMAR_FIT_TOLERANCE :: 1e-6 // of the length: the rounding a fit forgives

Grammar_Symbol :: struct {
    name:string,
    unit_size:f32, // length of one module before stretching
    scalable:bool,
}
Grammar_Op :: enum u8 {Literal,Sequence,Stochastic,Priority}
Grammar_Module :: struct {
    op:Grammar_Op,
    sym:u16, // Literal: index in Grammar_Program.symbols
    child_first,child_count:u16, // groups: range of Grammar_Program.children
    reps:i16, // > 0 a fixed count, GRAMMAR_REPEAT_FIT or GRAMMAR_REPEAT_SOME
    weight:u8, // in a Stochastic parent
    min_size:f32, // least length of one repetition
}
// modules[0] is the root. One allocation holds every slice.
Grammar_Program :: struct {
    symbols:[]Grammar_Symbol,
    modules:[]Grammar_Module,
    children:[]u16, // module indices, contiguous for each group
    depth:int, // frames grammar_subdivide needs
    hash:u64, // of the symbols and the structure
    allocator:runtime.Allocator,
}

Grammar_Error_Kind :: enum u8 {
    None,Out_Of_Memory,Unexpected_Character,Unexpected_End,Unknown_Symbol,Empty_Group,Bad_Repeat,
    Bad_Weight,Too_Deep,Too_Many_Modules,Too_Large,Empty_Symbol_Name,Bad_Symbol_Name,
    Duplicate_Symbol,Bad_Unit_Size,Too_Many_Symbols,
}
Grammar_Error :: struct {
    kind:Grammar_Error_Kind,
    offset:int, // byte of the source
    symbol:int, // index in the symbols for their errors, else -1
}
Grammar_Solve_Error :: enum u8 {None,Bad_Length,Bad_Program,Too_Short,Capacity_Exceeded}

Grammar_Placed :: struct {
    start,size:f32,
    scale:f32, // size over unit_size; 1 for modules that do not scale
    sym,module:u16,
    ordinal:u32, // place in the span
    is_first,is_final:bool,
}
// Expansion state of one module. A Grammar_Scratch backed by
// [GRAMMAR_MAX_DEPTH]Grammar_Frame solves any compiled program.
Grammar_Frame :: struct {
    budget,used:f64, // length the module may take and has taken
    ceiling:f64, // what used may reach in this repetition
    tail:f64, // least length of the sequence children not yet started
    iteration,placed:int, // repetitions done, placements when the last one began
    module,cursor:u16,
    open:bool,
}
Grammar_Scratch :: struct {frames:[]Grammar_Frame}

@(private="file")
Parser :: struct {
    source:string,
    at:int,
    symbols:[]Grammar_Symbol,
    modules:[]Grammar_Module, // empty while counting
    children:[]u16,
    fill_children:bool,
    count,depth:int,
    err:Grammar_Error,
}

grammar_compile :: proc(source:string,symbols:[]Grammar_Symbol,allocator:=context.allocator) -> (program:Grammar_Program,err:Grammar_Error) {
    err.symbol=-1
    if len(symbols)>GRAMMAR_MAX_SYMBOLS {return {},{.Too_Many_Symbols,0,GRAMMAR_MAX_SYMBOLS}}
    names_size:=0
    for s,i in symbols {
        kind:=Grammar_Error_Kind.None
        switch {
        case s.name=="": kind=.Empty_Symbol_Name
        case !is_identifier(s.name): kind=.Bad_Symbol_Name
        case !(s.unit_size>0) || math.is_inf(s.unit_size): kind=.Bad_Unit_Size
        }
        for other in symbols[:i] {if kind==.None && other.name==s.name {kind=.Duplicate_Symbol}}
        if kind!=.None {return {},{kind,0,i}}
        names_size+=len(s.name)
    }
    p:=Parser{source=source,symbols=symbols,err={symbol=-1}}
    if !parse_root(&p) {return {},p.err}
    module_count:=p.count
    symbols_size:=len(symbols)*size_of(Grammar_Symbol)
    modules_size:=module_count*size_of(Grammar_Module)
    children_size:=(module_count-1)*size_of(u16)
    block,alloc_err:=mem.alloc_bytes(symbols_size+modules_size+children_size+names_size,align_of(Grammar_Symbol),allocator)
    if alloc_err!=nil {return {},{.Out_Of_Memory,0,-1}}
    at:=raw_data(block)
    program.symbols=([^]Grammar_Symbol)(at)[:len(symbols)]
    program.modules=([^]Grammar_Module)(&at[symbols_size])[:module_count]
    program.children=([^]u16)(&at[symbols_size+modules_size])[:module_count-1]
    names:=block[symbols_size+modules_size+children_size:]
    program.allocator=allocator
    for s,i in symbols {
        copy(names,s.name)
        program.symbols[i]={string(names[:len(s.name)]),s.unit_size,s.scalable}
        names=names[len(s.name):]
    }
    p=Parser{source=source,symbols=symbols,modules=program.modules}
    parse_root(&p)
    first:=0
    for &m in program.modules {
        if m.op==.Literal {continue}
        m.child_first=u16(first)
        first+=int(m.child_count)
    }
    p=Parser{source=source,symbols=symbols,modules=program.modules,children=program.children,fill_children=true}
    parse_root(&p)
    program.depth=p.depth
    h:=base.HASH_SEED
    for s in program.symbols {
        h=base.hash_mix(h,base.name_hash(s.name))
        h=base.hash_mix(h,u64(transmute(u32)s.unit_size)|u64(s.scalable)<<32)
    }
    for m in program.modules {
        h=base.hash_mix(h,u64(m.op)|u64(m.sym)<<8|u64(m.child_count)<<24|u64(u16(m.reps))<<40|u64(m.weight)<<56)
    }
    for c in program.children {h=base.hash_mix(h,u64(c))}
    program.hash=h
    return
}

grammar_destroy :: proc(program:^Grammar_Program) {
    if program.symbols!=nil {free(raw_data(program.symbols),program.allocator)}
    program^={}
}

// The least length the module takes with its repetitions.
grammar_module_min :: proc "contextless" (m:Grammar_Module) -> f64 {
    if m.reps>0 {return f64(m.min_size)*f64(m.reps)}
    return f64(m.min_size) if m.reps==GRAMMAR_REPEAT_SOME else 0
}

// Splits length into out, in order. The same program, length and seed give
// the same placements. When some placed module scales, the last one ends at
// length; otherwise the length left over stays after it. A full out or scratch
// returns the placements made so far, unstretched, with .Capacity_Exceeded.
grammar_subdivide :: proc "contextless" (program:Grammar_Program,length:f32,seed:u64,scratch:^Grammar_Scratch,out:[]Grammar_Placed) -> (count:int,err:Grammar_Solve_Error) {
    if len(program.modules)==0 || len(program.modules)>GRAMMAR_MAX_MODULES {return 0,.Bad_Program}
    if !(length>=0) || math.is_inf(length) {return 0,.Bad_Length}
    total:=f64(length)
    slack:=total*GRAMMAR_FIT_TOLERANCE
    if grammar_module_min(program.modules[0])>total+slack {return 0,.Too_Short}
    frames:=scratch.frames if scratch!=nil else nil
    if len(frames)==0 {return 0,.Capacity_Exceeded}
    rng:=mm.rng_make(seed)
    frames[0]={budget=total}
    depth:=1
    for depth>0 {
        f:=&frames[depth-1]
        m:=program.modules[f.module]
        if !f.open {
            rest:=f.budget-f.used
            done:=false
            if m.reps==GRAMMAR_REPEAT_FIT || m.reps==GRAMMAR_REPEAT_SOME {
                stalled:=f.iteration>0 && count==f.placed
                first:=f.iteration==0 && m.reps==GRAMMAR_REPEAT_SOME
                done=stalled || !first && f64(m.min_size)>rest+slack
            } else if m.reps>0 {
                done=f.iteration>=int(m.reps)
            } else {
                return 0,.Bad_Program
            }
            if done {
                depth-=1
                if depth>0 {frames[depth-1].used+=f.used}
                continue
            }
            reserve:=f64(int(m.reps)-f.iteration-1)*f64(m.min_size) if m.reps>0 else 0
            f.open,f.cursor,f.placed,f.ceiling,f.tail=true,0,count,f.budget-reserve,0
            if m.op==.Sequence {
                for k in 0..<m.child_count {
                    child:=grammar_child(program,m,k) or_return
                    f.tail+=grammar_module_min(program.modules[child])
                }
            }
            continue
        }
        child:u16
        switch m.op {
        case .Literal:
            if int(m.sym)>=len(program.symbols) {return 0,.Bad_Program}
            unit:=program.symbols[m.sym].unit_size
            if !(unit>0) || math.is_inf(unit) {return 0,.Bad_Program}
            if count>=len(out) {return grammar_finish(program,out[:count],length,false),.Capacity_Exceeded}
            out[count]={size=unit,sym=m.sym,module=f.module}
            count+=1
            f.used+=f64(unit)
            f.open=false;f.iteration+=1
            continue
        case .Sequence:
            if f.cursor>=m.child_count {f.open=false;f.iteration+=1;continue}
            child=grammar_child(program,m,f.cursor) or_return
            f.tail-=grammar_module_min(program.modules[child])
        case .Priority,.Stochastic:
            if f.cursor>0 {f.open=false;f.iteration+=1;continue}
            room:=f.ceiling-f.used+slack
            weights:u32=0
            found:=false
            for k in 0..<m.child_count {
                c:=grammar_child(program,m,k) or_return
                cm:=program.modules[c]
                if grammar_module_min(cm)>room {continue}
                if m.op==.Priority {child,found=c,true;break}
                weights+=u32(cm.weight)
            }
            if m.op==.Stochastic && weights>0 {
                pick:=mm.random_below(&rng,weights)
                for k in 0..<m.child_count {
                    c,_:=grammar_child(program,m,k)
                    cm:=program.modules[c]
                    if grammar_module_min(cm)>room {continue}
                    if pick<u32(cm.weight) {child,found=c,true;break}
                    pick-=u32(cm.weight)
                }
            }
            if !found {return 0,.Bad_Program}
        }
        if depth>=len(frames) {return grammar_finish(program,out[:count],length,false),.Capacity_Exceeded}
        f.cursor+=1
        frames[depth]={budget=f.ceiling-f.used-f.tail,module=child}
        depth+=1
    }
    return grammar_finish(program,out[:count],length,true),.None
}

// Identity of a module placed on a span, from the identity of the spline or
// polygon, the span's index and the module's ordinal: moving a point changes
// neither it nor that of the other spans. Ordinal 0 also seeds the span's solve.
grammar_span_id :: proc "contextless" (spline_entity_id:u64,span_index:u32,module_ordinal:u32) -> u64 {
    return base.hash_mix(base.hash_mix(base.HASH_SEED,spline_entity_id),u64(span_index)<<32|u64(module_ordinal))
}

@(private="file")
grammar_child :: proc "contextless" (program:Grammar_Program,m:Grammar_Module,k:u16) -> (u16,Grammar_Solve_Error) {
    at:=int(m.child_first)+int(k)
    if at>=len(program.children) || int(program.children[at])>=len(program.modules) {return 0,.Bad_Program}
    return program.children[at],.None
}

// Lays the placements end to end; stretched, the scalable ones share what
// their unit sizes leave of the length.
@(private="file")
grammar_finish :: proc "contextless" (program:Grammar_Program,placed:[]Grammar_Placed,length:f32,stretch:bool) -> int {
    used,scalable:f64
    for p in placed {
        used+=f64(p.size)
        if program.symbols[p.sym].scalable {scalable+=f64(p.size)}
    }
    stretch:=stretch && scalable>0
    scale:=1+(f64(length)-used)/scalable if stretch else 1
    cursor:f64
    for &p,i in placed {
        s:=scale if program.symbols[p.sym].scalable else 1
        start:=f32(cursor)
        cursor+=f64(p.size)*s
        end:=length if stretch && i==len(placed)-1 else f32(cursor)
        p.start,p.size,p.scale=start,end-start,f32(s)
        p.ordinal,p.is_first,p.is_final=u32(i),i==0,i==len(placed)-1
    }
    return len(placed)
}

@(private="file")
is_identifier :: proc(name:string) -> bool {
    for i in 0..<len(name) {if !identifier_byte(name[i],i>0) {return false}}
    return len(name)>0
}
@(private="file")
identifier_byte :: proc(c:u8,later:bool) -> bool {
    return c=='_' || c>='a' && c<='z' || c>='A' && c<='Z' || later && c>='0' && c<='9'
}
@(private="file")
skip_space :: proc(p:^Parser) {
    for p.at<len(p.source) && (p.source[p.at]==' ' || p.source[p.at]=='\t' || p.source[p.at]=='\n' || p.source[p.at]=='\r') {p.at+=1}
}
@(private="file")
fail :: proc(p:^Parser,kind:Grammar_Error_Kind,offset:int) -> (int,f64,bool) {
    p.err={kind,offset,-1}
    return 0,0,false
}
// A count from 1 to limit; every digit is consumed.
@(private="file")
parse_count :: proc(p:^Parser,limit:int) -> (value:int,ok:bool) {
    ok=true
    for p.at<len(p.source) && p.source[p.at]>='0' && p.source[p.at]<='9' {
        value=value*10+int(p.source[p.at]-'0')
        if value>limit {ok=false;value=limit}
        p.at+=1
    }
    return value,ok && value>0
}
@(private="file")
parse_root :: proc(p:^Parser) -> bool {
    _,_,ok:=parse_item(p,1)
    if !ok {return false}
    skip_space(p)
    if p.at<len(p.source) {fail(p,.Unexpected_Character,p.at);return false}
    return true
}
// Returns the module and its least length with its repetitions.
@(private="file")
parse_item :: proc(p:^Parser,depth:int) -> (index:int,total:f64,ok:bool) {
    skip_space(p)
    if depth>GRAMMAR_MAX_DEPTH {return fail(p,.Too_Deep,p.at)}
    if p.count>=GRAMMAR_MAX_MODULES {return fail(p,.Too_Many_Modules,p.at)}
    if p.at>=len(p.source) {return fail(p,.Unexpected_End,p.at)}
    p.depth=max(p.depth,depth)
    index=p.count
    p.count+=1
    m:=Grammar_Module{reps=1,weight=1}
    body:f64
    start:=p.at
    switch p.source[p.at] {
    case '[','<','{':
        close:u8
        switch p.source[p.at] {
        case '[': m.op,close=.Sequence,']'
        case '<': m.op,close=.Priority,'>'
        case: m.op,close=.Stochastic,'}'
        }
        p.at+=1
        skip_space(p)
        if p.at<len(p.source) && p.source[p.at]==close {return fail(p,.Empty_Group,start)}
        body=0 if m.op==.Sequence else math.inf_f64(1)
        for {
            child,child_total:=parse_item(p,depth+1) or_return
            skip_space(p)
            weight:=1
            if m.op==.Stochastic && p.at<len(p.source) && p.source[p.at]==':' {
                p.at+=1
                skip_space(p)
                at:=p.at
                weight_ok:bool
                weight,weight_ok=parse_count(p,int(max(u8)))
                if !weight_ok {return fail(p,.Bad_Weight,at)}
                skip_space(p)
            }
            if p.fill_children {
                p.children[int(p.modules[index].child_first)+int(m.child_count)]=u16(child)
            } else if len(p.modules)>0 {
                p.modules[child].weight=u8(weight)
            }
            m.child_count+=1
            body=body+child_total if m.op==.Sequence else min(body,child_total)
            if p.at>=len(p.source) {return fail(p,.Unexpected_End,p.at)}
            if p.source[p.at]==close {p.at+=1;break}
            if p.source[p.at]!=',' {return fail(p,.Unexpected_Character,p.at)}
            p.at+=1
        }
    case:
        for p.at<len(p.source) && identifier_byte(p.source[p.at],p.at>start) {p.at+=1}
        if p.at==start {return fail(p,.Unexpected_Character,start)}
        name:=p.source[start:p.at]
        found:=false
        for s,i in p.symbols {
            if s.name!=name {continue}
            m.op,m.sym,body,found=.Literal,u16(i),f64(s.unit_size),true
            break
        }
        if !found {return fail(p,.Unknown_Symbol,start)}
    }
    skip_space(p)
    if p.at<len(p.source) {
        switch p.source[p.at] {
        case '*': m.reps=GRAMMAR_REPEAT_FIT;p.at+=1
        case '+': m.reps=GRAMMAR_REPEAT_SOME;p.at+=1
        case '0'..='9':
            at:=p.at
            reps,reps_ok:=parse_count(p,int(max(i16)))
            if !reps_ok {return fail(p,.Bad_Repeat,at)}
            m.reps=i16(reps)
        }
    }
    if body>f64(max(f32)) {return fail(p,.Too_Large,start)}
    m.min_size=f32(body)
    total=grammar_module_min(m)
    if total>f64(max(f32)) {return fail(p,.Too_Large,start)}
    if len(p.modules)>0 && !p.fill_children {p.modules[index]=m}
    return index,total,true
}
