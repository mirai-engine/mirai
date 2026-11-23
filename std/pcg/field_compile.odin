package mirai_pcg

import "base:intrinsics"
import "base:runtime"
import "core:simd"
import "core:strconv"

// Compiles a field expression:
//
//     let warped_x = warp2x(x, z, 8, 0.02);   # bindings end with ';', '#' starts a comment
//     let warped_z = warp2z(x, z, 8, 0.02);
//     fbm2(warped_x*0.01, warped_z*0.01, 5, 2, 0.5) * 40 + height
//
// Values: numbers, x, y, z, height, slope, occupancy, mask(i), ecotope(i) and let names.
// Operators: unary -, + - * / with the usual precedence and parentheses. Functions: min, max,
// abs, clamp(x,lo,hi), remap(x,in0,in1,out0,out1), smoothstep(e0,e1,x), lerp(a,b,t),
// select(cond,a,b) (cond>0 ? a : b), pow2, sqrt; noises with an optional constant integer seed:
// value2(x,z), value3(x,y,z), perlin2, perlin3, cellular2, cellular3; fractals of Perlin noise
// fbm2(x,z,octaves,lacunarity,gain), fbm3(x,y,z,...), ridged2, ridged3, turbulence2,
// turbulence3, each octave seeded seed+octave; domain warp warp2x(x,z,amp,freq), warp2z,
// warp3x(x,y,z,amp,freq), warp3y, warp3z, the coordinate moved by amp times Perlin noise at
// coordinate times freq (axis k of a warp uses seed+k).
//
// The expression becomes a graph where equal operations are one node, constant parts are
// computed with the evaluator's kernels, fractals are unrolled, and what the result does not use
// is dropped; then each value takes the lowest free slot from the operation that makes it to its
// last use. The memory of the program comes from `allocator`; the work memory is returned to it.
field_compile :: proc(source:string,allocator:runtime.Allocator) -> (program:Field_Program,err:Field_Error) {
    if len(source)>MAX_SOURCE {return {},{.Too_Large,MAX_SOURCE,len(source)-MAX_SOURCE,"the expression is longer than MAX_SOURCE bytes"}}
    c:Compiler
    c.source=source
    ok:bool
    if c.nodes,ok=slice_alloc([]Node,MAX_NODES,allocator);!ok {return {},{kind=.Out_Of_Memory,message="out of memory"}}
    defer delete(c.nodes,allocator)
    if c.table,ok=slice_alloc([]i32,CSE_TABLE,allocator);!ok {return {},{kind=.Out_Of_Memory,message="out of memory"}}
    defer delete(c.table,allocator)
    root:=parse_program(&c)
    if root<0 {fail(&c,.Syntax,c.pos,0,"expected an expression")}
    if c.err.kind!=.None {return {},c.err}
    program=emit(&c,root,allocator)
    if c.err.kind!=.None {return {},c.err}
    return program,{}
}

@(private) CSE_TABLE :: 2*MAX_NODES // power of two
@(private) MAX_ARGS :: 7

@(private)
Node :: struct {
    op:Field_Op,
    input:Field_Input,
    index:u8,
    live:bool,
    seed:u32,
    args:[3]i32, // -1 when unused
    value:f32,   // of a Const
    offset,length:i32, // source of the expression that first made it
    last:i32,    // last node that reads it
    slot:i32,
}

@(private)
Let :: struct {name:string,node:i32}

@(private)
Compiler :: struct {
    source:string,
    pos:int,
    nodes:[]Node,
    count:int,
    table:[]i32, // node+1 in open addressing, 0 when empty
    lets:[MAX_LETS]Let,
    let_count:int,
    depth:int,
    err:Field_Error,
}

@(private)
fail :: proc(c:^Compiler,kind:Field_Error_Kind,offset,length:int,message:string) -> i32 {
    if c.err.kind==.None {c.err={kind,offset,length,message}}
    return -1
}

// Lexer

@(private)
Token_Kind :: enum u8 {End,Number,Ident,Punct,Bad}
@(private)
Token :: struct {kind:Token_Kind,start,end:int}

@(private)
is_alpha :: proc "contextless" (ch:u8) -> bool {return ch>='a' && ch<='z' || ch>='A' && ch<='Z' || ch=='_'}
@(private)
is_digit :: proc "contextless" (ch:u8) -> bool {return ch>='0' && ch<='9'}

@(private)
peek :: proc(c:^Compiler) -> Token {
    s:=c.source
    i:=c.pos
    for i<len(s) {
        ch:=s[i]
        if ch==' ' || ch=='\t' || ch=='\n' || ch=='\r' {i+=1;continue}
        if ch=='#' {for i<len(s) && s[i]!='\n' {i+=1};continue}
        break
    }
    if i>=len(s) {return {.End,i,i}}
    start:=i
    ch:=s[i]
    switch {
    case is_digit(ch) || ch=='.' && i+1<len(s) && is_digit(s[i+1]):
        for i<len(s) && is_digit(s[i]) {i+=1}
        if i<len(s) && s[i]=='.' {i+=1;for i<len(s) && is_digit(s[i]) {i+=1}}
        if i<len(s) && (s[i]=='e' || s[i]=='E') {
            j:=i+1
            if j<len(s) && (s[j]=='+' || s[j]=='-') {j+=1}
            if j<len(s) && is_digit(s[j]) {
                i=j
                for i<len(s) && is_digit(s[i]) {i+=1}
            }
        }
        return {.Number,start,i}
    case is_alpha(ch):
        for i<len(s) && (is_alpha(s[i]) || is_digit(s[i])) {i+=1}
        return {.Ident,start,i}
    case ch=='(' || ch==')' || ch=='+' || ch=='-' || ch=='*' || ch=='/' || ch==',' || ch=='=' || ch==';':
        return {.Punct,start,i+1}
    }
    return {.Bad,start,i+1}
}
@(private)
next :: proc(c:^Compiler) -> Token {t:=peek(c);c.pos=t.end;return t}
@(private)
text :: proc(c:^Compiler,t:Token) -> string {return c.source[t.start:t.end]}
@(private)
is_punct :: proc(c:^Compiler,t:Token,ch:u8) -> bool {return t.kind==.Punct && c.source[t.start]==ch}
@(private)
expect :: proc(c:^Compiler,ch:u8,message:string) -> bool {
    t:=peek(c)
    if !is_punct(c,t,ch) {fail(c,.Syntax,t.start,t.end-t.start,message);return false}
    c.pos=t.end
    return true
}

// Parser

@(private)
parse_program :: proc(c:^Compiler) -> i32 {
    for {
        t:=peek(c)
        if t.kind!=.Ident || text(c,t)!="let" {break}
        c.pos=t.end
        name:=next(c)
        if name.kind!=.Ident {return fail(c,.Syntax,name.start,name.end-name.start,"expected a name after let")}
        word:=text(c,name)
        if word=="let" || builtin_input(word)!=nil || function_known(word) {
            return fail(c,.Syntax,name.start,name.end-name.start,"a let name cannot be a built-in name or function")
        }
        for l in c.lets[:c.let_count] {
            if l.name==word {return fail(c,.Syntax,name.start,name.end-name.start,"the name is already bound")}
        }
        if c.let_count>=MAX_LETS {return fail(c,.Too_Large,name.start,name.end-name.start,"more than MAX_LETS bindings")}
        if !expect(c,'=',"expected '=' after the let name") {return -1}
        value:=parse_expr(c)
        if value<0 {return -1}
        if !expect(c,';',"expected ';' after the let value") {return -1}
        c.lets[c.let_count]={word,value}
        c.let_count+=1
    }
    t:=peek(c)
    if t.kind==.End {return fail(c,.Syntax,t.start,0,"expected an expression")}
    root:=parse_expr(c)
    if root<0 {return -1}
    if t=peek(c);is_punct(c,t,';') {c.pos=t.end}
    if t=peek(c);t.kind!=.End {return fail(c,.Syntax,t.start,t.end-t.start,"expected the end of the expression")}
    return root
}

@(private)
parse_expr :: proc(c:^Compiler) -> i32 {
    start:=peek(c).start
    left:=parse_term(c)
    for left>=0 {
        t:=peek(c)
        op:Field_Op
        if is_punct(c,t,'+') {op=.Add} else if is_punct(c,t,'-') {op=.Sub} else {break}
        c.pos=t.end
        right:=parse_term(c)
        if right<0 {return -1}
        left=node_op(c,op,{left,right,-1},start,c.pos)
    }
    return left
}

@(private)
parse_term :: proc(c:^Compiler) -> i32 {
    start:=peek(c).start
    left:=parse_unary(c)
    for left>=0 {
        t:=peek(c)
        op:Field_Op
        if is_punct(c,t,'*') {op=.Mul} else if is_punct(c,t,'/') {op=.Div} else {break}
        c.pos=t.end
        right:=parse_unary(c)
        if right<0 {return -1}
        left=node_op(c,op,{left,right,-1},start,c.pos)
    }
    return left
}

@(private)
parse_unary :: proc(c:^Compiler) -> i32 {
    t:=peek(c)
    if c.depth>=MAX_DEPTH {return fail(c,.Too_Large,t.start,t.end-t.start,"the expression nests deeper than MAX_DEPTH")}
    c.depth+=1
    defer c.depth-=1
    if is_punct(c,t,'-') {
        c.pos=t.end
        a:=parse_unary(c)
        if a<0 {return -1}
        return node_op(c,.Neg,{a,-1,-1},t.start,c.pos)
    }
    return parse_primary(c)
}

@(private)
parse_primary :: proc(c:^Compiler) -> i32 {
    t:=next(c)
    switch t.kind {
    case .End: return fail(c,.Syntax,t.start,0,"expected a value")
    case .Bad: return fail(c,.Syntax,t.start,1,"unexpected character")
    case .Number:
        value,ok:=strconv.parse_f32(text(c,t))
        if !ok {
            if _,in_f64:=strconv.parse_f64(text(c,t));in_f64 {return fail(c,.Non_Finite,t.start,t.end-t.start,"the number is not finite")}
            return fail(c,.Syntax,t.start,t.end-t.start,"malformed number")
        }
        return node_const(c,value,t.start,t.end)
    case .Punct:
        if c.source[t.start]!='(' {return fail(c,.Syntax,t.start,1,"expected a value")}
        inner:=parse_expr(c)
        if inner<0 {return -1}
        if !expect(c,')',"expected ')'") {return -1}
        return inner
    case .Ident:
        word:=text(c,t)
        if after:=peek(c);is_punct(c,after,'(') {
            c.pos=after.end
            return parse_call(c,t)
        }
        for l in c.lets[:c.let_count] {if l.name==word {return l.node}}
        if input,ok:=builtin_input(word).?;ok {
            return node_add(c,{op=.Input,input=input,args={-1,-1,-1}},t.start,t.end)
        }
        if function_known(word) {return fail(c,.Syntax,t.end,0,"expected '(' after the function name")}
        return fail(c,.Unknown_Identifier,t.start,t.end-t.start,"unknown identifier")
    }
    return -1
}

@(private)
builtin_input :: proc(word:string) -> Maybe(Field_Input) {
    switch word {
    case "x":         return .X
    case "y":         return .Y
    case "z":         return .Z
    case "height":    return .Height
    case "slope":     return .Slope
    case "occupancy": return .Occupancy
    }
    return nil
}

@(private)
Function :: struct {name:string,min,max:int}
@(private)
FUNCTIONS :: [?]Function{
    {"min",2,2},{"max",2,2},{"abs",1,1},{"clamp",3,3},{"remap",5,5},{"smoothstep",3,3},
    {"lerp",3,3},{"select",3,3},{"pow2",1,1},{"sqrt",1,1},{"mask",1,1},{"ecotope",1,1},
    {"value2",2,3},{"value3",3,4},{"perlin2",2,3},{"perlin3",3,4},{"cellular2",2,3},
    {"cellular3",3,4},{"fbm2",5,6},{"fbm3",6,7},{"ridged2",5,6},{"ridged3",6,7},
    {"turbulence2",5,6},{"turbulence3",6,7},{"warp2x",4,5},{"warp2z",4,5},{"warp3x",5,6},
    {"warp3y",5,6},{"warp3z",5,6},
}
@(private)
function_find :: proc(word:string) -> (Function,bool) {
    functions:=FUNCTIONS
    for f in functions {if f.name==word {return f,true}}
    return {},false
}
@(private)
function_known :: proc(word:string) -> bool {_,ok:=function_find(word);return ok}

@(private)
Args :: struct {node:[MAX_ARGS]i32,start,end:[MAX_ARGS]int,count:int}

@(private)
parse_call :: proc(c:^Compiler,name:Token) -> i32 {
    if c.depth>=MAX_DEPTH {return fail(c,.Too_Large,name.start,name.end-name.start,"the expression nests deeper than MAX_DEPTH")}
    c.depth+=1
    defer c.depth-=1
    word:=text(c,name)
    args:Args
    if t:=peek(c);is_punct(c,t,')') {
        c.pos=t.end
    } else {
        for {
            if args.count>=MAX_ARGS {return fail(c,.Arity,name.start,name.end-name.start,"too many arguments")}
            args.start[args.count]=peek(c).start
            arg:=parse_expr(c)
            if arg<0 {return -1}
            args.node[args.count]=arg
            args.end[args.count]=c.pos
            args.count+=1
            t:=next(c)
            if is_punct(c,t,')') {break}
            if !is_punct(c,t,',') {return fail(c,.Syntax,t.start,t.end-t.start,"expected ',' or ')'")}
        }
    }
    f,known:=function_find(word)
    if !known {return fail(c,.Unknown_Function,name.start,name.end-name.start,"unknown function")}
    if args.count<f.min || args.count>f.max {return fail(c,.Arity,name.start,c.pos-name.start,"wrong number of arguments")}
    start,end:=name.start,c.pos
    a:=args.node
    switch word {
    case "min":        return node_op(c,.Min,{a[0],a[1],-1},start,end)
    case "max":        return node_op(c,.Max,{a[0],a[1],-1},start,end)
    case "abs":        return node_op(c,.Abs,{a[0],-1,-1},start,end)
    case "sqrt":       return node_op(c,.Sqrt,{a[0],-1,-1},start,end)
    case "pow2":       return node_op(c,.Mul,{a[0],a[0],-1},start,end)
    case "clamp":      return node_op(c,.Clamp,{a[0],a[1],a[2]},start,end)
    case "lerp":       return node_op(c,.Lerp,{a[0],a[1],a[2]},start,end)
    case "smoothstep": return node_op(c,.Smoothstep,{a[0],a[1],a[2]},start,end)
    case "select":     return node_op(c,.Select,{a[0],a[1],a[2]},start,end)
    case "remap":
        // out0 + (x-in0)*((out1-out0)/(in1-in0))
        shift:=node_op(c,.Sub,{a[0],a[1],-1},start,end)
        span:=node_op(c,.Sub,{a[4],a[3],-1},start,end)
        range:=node_op(c,.Sub,{a[2],a[1],-1},start,end)
        if shift<0 || span<0 || range<0 {return -1}
        scale:=node_op(c,.Div,{span,range,-1},start,end)
        if scale<0 {return -1}
        moved:=node_op(c,.Mul,{shift,scale,-1},start,end)
        if moved<0 {return -1}
        return node_op(c,.Add,{a[3],moved,-1},start,end)
    case "mask", "ecotope":
        index,ok:=const_integer(c,&args,0,0,MAX_INPUT_INDEX,"the index must be a constant integer from 0 to 255")
        if !ok {return -1}
        return node_add(c,{op=.Input,input=word=="mask" ? Field_Input.Mask : Field_Input.Ecotope,index=u8(index),args={-1,-1,-1}},start,end)
    case "value2", "perlin2", "cellular2":
        seed,ok:=seed_arg(c,&args,2)
        if !ok {return -1}
        op:Field_Op=word=="value2" ? .Value2 : word=="perlin2" ? .Perlin2 : .Cellular2
        return node_noise(c,op,{a[0],a[1],-1},seed,start,end)
    case "value3", "perlin3", "cellular3":
        seed,ok:=seed_arg(c,&args,3)
        if !ok {return -1}
        op:Field_Op=word=="value3" ? .Value3 : word=="perlin3" ? .Perlin3 : .Cellular3
        return node_noise(c,op,{a[0],a[1],a[2]},seed,start,end)
    case "fbm2", "ridged2", "turbulence2", "fbm3", "ridged3", "turbulence3":
        dims:=word[len(word)-1]=='2' ? 2 : 3
        shape:Fractal_Shape=word[0]=='f' ? .Sum : word[0]=='r' ? .Ridged : .Turbulence
        return fractal(c,&args,dims,shape,start,end)
    case "warp2x", "warp2z", "warp3x", "warp3y", "warp3z":
        dims:=word[4]=='2' ? 2 : 3
        axis:=word[5]=='x' ? 0 : word[5]=='y' ? 1 : (dims==2 ? 1 : 2)
        return warp(c,&args,dims,axis,start,end)
    }
    return fail(c,.Unknown_Function,name.start,name.end-name.start,"unknown function")
}

@(private)
Fractal_Shape :: enum u8 {Sum,Ridged,Turbulence}

@(private)
const_of :: proc(c:^Compiler,node:i32) -> (f32,bool) {
    n:=c.nodes[node]
    return n.value,n.op==.Const
}

@(private)
const_number :: proc(c:^Compiler,args:^Args,i:int,message:string) -> (f32,bool) {
    value,ok:=const_of(c,args.node[i])
    if !ok {fail(c,.Not_Constant,args.start[i],args.end[i]-args.start[i],message);return 0,false}
    return value,true
}

@(private)
const_integer :: proc(c:^Compiler,args:^Args,i:int,low,high:i64,message:string) -> (i64,bool) {
    value,ok:=const_number(c,args,i,message)
    if !ok {return 0,false}
    if !(f64(value)>=f64(low) && f64(value)<=f64(high)) || f32(i64(value))!=value {
        fail(c,.Out_Of_Range,args.start[i],args.end[i]-args.start[i],message)
        return 0,false
    }
    return i64(value),true
}

// The optional seed at argument i: a constant integer from -2^31 to 2^32-1, wrapped to u32.
@(private)
seed_arg :: proc(c:^Compiler,args:^Args,i:int) -> (u32,bool) {
    if args.count<=i {return 0,true}
    seed,ok:=const_integer(c,args,i,-(1<<31),(1<<32)-1,"the seed must be a constant integer from -2147483648 to 4294967295")
    return u32(seed),ok
}

@(private)
fractal :: proc(c:^Compiler,args:^Args,dims:int,shape:Fractal_Shape,start,end:int) -> i32 {
    octaves,ok:=const_integer(c,args,dims,1,MAX_OCTAVES,"the octaves must be a constant integer from 1 to 8")
    if !ok {return -1}
    lacunarity,gain:f32
    if lacunarity,ok=const_number(c,args,dims+1,"the lacunarity must be a constant");!ok {return -1}
    if gain,ok=const_number(c,args,dims+2,"the gain must be a constant");!ok {return -1}
    seed:u32
    if seed,ok=seed_arg(c,args,dims+3);!ok {return -1}
    noise:Field_Op=dims==2 ? .Perlin2 : .Perlin3
    sum:i32=-1
    amplitude,frequency,range:f32=1,1,0
    for octave in 0..<int(octaves) {
        coords:=[3]i32{-1,-1,-1}
        for d in 0..<dims {
            coords[d]=args.node[d]
            if frequency!=1 {
                k:=node_const(c,frequency,start,end)
                if k<0 {return -1}
                coords[d]=node_op(c,.Mul,{args.node[d],k,-1},start,end)
                if coords[d]<0 {return -1}
            }
        }
        value:=node_noise(c,noise,coords,seed+u32(octave),start,end)
        switch shape {
        case .Sum:
        case .Ridged:
            one:=node_const(c,1,start,end)
            crest:=node_op(c,.Abs,{value,-1,-1},start,end)
            if one<0 || crest<0 {return -1}
            crest=node_op(c,.Sub,{one,crest,-1},start,end)
            if crest<0 {return -1}
            value=node_op(c,.Mul,{crest,crest,-1},start,end)
        case .Turbulence:
            value=node_op(c,.Abs,{value,-1,-1},start,end)
        }
        if value<0 {return -1}
        if amplitude!=1 {
            k:=node_const(c,amplitude,start,end)
            if k<0 {return -1}
            value=node_op(c,.Mul,{value,k,-1},start,end)
            if value<0 {return -1}
        }
        sum=octave==0 ? value : node_op(c,.Add,{sum,value,-1},start,end)
        if sum<0 {return -1}
        range+=amplitude
        amplitude*=gain
        frequency*=lacunarity
    }
    if range==1 {return sum}
    if !(range-range==0) || range==0 {return fail(c,.Out_Of_Range,start,end-start,"the amplitudes of the octaves must add up to a finite number other than 0")}
    k:=node_const(c,range,start,end)
    if k<0 {return -1}
    return node_op(c,.Div,{sum,k,-1},start,end)
}

// coordinate[axis] + amp*perlin(coordinates*freq, seed+axis)
@(private)
warp :: proc(c:^Compiler,args:^Args,dims,axis:int,start,end:int) -> i32 {
    seed,ok:=seed_arg(c,args,dims+2)
    if !ok {return -1}
    amp,freq:=args.node[dims],args.node[dims+1]
    coords:=[3]i32{-1,-1,-1}
    for d in 0..<dims {
        coords[d]=node_op(c,.Mul,{args.node[d],freq,-1},start,end)
        if coords[d]<0 {return -1}
    }
    noise:=node_noise(c,dims==2 ? .Perlin2 : .Perlin3,coords,seed+u32(axis),start,end)
    if noise<0 {return -1}
    offset:=node_op(c,.Mul,{amp,noise,-1},start,end)
    if offset<0 {return -1}
    return node_op(c,.Add,{args.node[axis],offset,-1},start,end)
}

// Graph

@(private)
node_const :: proc(c:^Compiler,value:f32,start,end:int) -> i32 {
    if !(value-value==0) {return fail(c,.Non_Finite,start,end-start,"the number is not finite")}
    return node_add(c,{op=.Const,value=value,args={-1,-1,-1}},start,end)
}

@(private)
node_noise :: proc(c:^Compiler,op:Field_Op,args:[3]i32,seed:u32,start,end:int) -> i32 {
    for i in 0..<op_arity(op) {if args[i]<0 {return -1}}
    return node_op(c,op,args,start,end,seed)
}

// An operation on nodes, simplified and folded when its arguments are constant.
@(private)
node_op :: proc(c:^Compiler,op:Field_Op,args:[3]i32,start,end:int,seed:u32=0) -> i32 {
    arity:=op_arity(op)
    constant:=true
    for i in 0..<arity {
        if args[i]<0 {return -1}
        if c.nodes[args[i]].op!=.Const {constant=false}
    }
    if constant {
        v:[3]V4
        for i in 0..<arity {v[i]=V4(c.nodes[args[i]].value)}
        value:=simd.to_array(kernel_apply(op,v[0],v[1],v[2],seed))[0]
        if !(value-value==0) {return fail(c,.Non_Finite,start,end-start,"this constant part of the expression is not finite")}
        return node_add(c,{op=.Const,value=value,args={-1,-1,-1}},start,end)
    }
    is_one :: proc(c:^Compiler,node:i32) -> bool {return c.nodes[node].op==.Const && c.nodes[node].value==1}
    is_zero :: proc(c:^Compiler,node:i32) -> bool {return c.nodes[node].op==.Const && transmute(u32)c.nodes[node].value==0}
    // Only rewrites that keep every bit: x*1, x/1, x-0 and -(-x).
    #partial switch op {
    case .Mul:
        if is_one(c,args[1]) {return args[0]}
        if is_one(c,args[0]) {return args[1]}
    case .Div:
        if is_one(c,args[1]) {return args[0]}
    case .Sub:
        if is_zero(c,args[1]) {return args[0]}
    case .Neg:
        if inner:=c.nodes[args[0]];inner.op==.Neg {return inner.args[0]}
    }
    n:=Node{op=op,seed=op>=.Value2 ? seed : 0,args={-1,-1,-1}}
    for i in 0..<arity {n.args[i]=args[i]}
    // IEEE sums and products do not depend on the order of their terms.
    if (op==.Add || op==.Mul) && n.args[1]<n.args[0] {n.args[0],n.args[1]=n.args[1],n.args[0]}
    return node_add(c,n,start,end)
}

@(private)
node_key :: proc "contextless" (n:Node) -> u64 {
    h:=mix64(u64(n.op)|u64(n.input)<<8|u64(n.index)<<16|u64(n.seed)<<32,u64(transmute(u32)n.value))
    return mix64(h,u64(u32(n.args[0]))|u64(u32(n.args[1]))<<32)~mix64(u64(u32(n.args[2])),0x5bd1e995)
}
@(private)
node_same :: proc "contextless" (a,b:Node) -> bool {
    return a.op==b.op && a.input==b.input && a.index==b.index && a.seed==b.seed && a.args==b.args &&
        transmute(u32)a.value==transmute(u32)b.value
}

// The node equal to n, made if there is none.
@(private)
node_add :: proc(c:^Compiler,n:Node,start,end:int) -> i32 {
    mask:=u64(len(c.table)-1)
    at:=node_key(n)&mask
    for c.table[at]!=0 {
        found:=c.table[at]-1
        if node_same(c.nodes[found],n) {return found}
        at=(at+1)&mask
    }
    if c.count>=len(c.nodes) {return fail(c,.Too_Large,start,end-start,"the expression has more than MAX_NODES operations")}
    index:=i32(c.count)
    node:=n
    node.offset,node.length=i32(start),i32(end-start)
    node.slot=-1
    c.nodes[index]=node
    c.count+=1
    c.table[at]=index+1
    return index
}

// Bytecode

@(private)
emit :: proc(c:^Compiler,root:i32,allocator:runtime.Allocator) -> Field_Program {
    nodes:=c.nodes[:c.count]
    if nodes[root].op==.Const {
        code,ok:=slice_alloc([]Field_Instr,1,allocator)
        if !ok {fail(c,.Out_Of_Memory,0,0,"out of memory");return {}}
        code[0]={op=.Const,imm={nodes[root].value,0,0},imm_mask=1}
        return {code=code,output=0,slots=1,hash=field_program_hash(code,0,1),allocator=allocator}
    }
    // What the result reads, and the last node that reads each value.
    nodes[root].live=true
    for i:=root;i>=0;i-=1 {
        if !nodes[i].live {continue}
        for arg in nodes[i].args[:op_arity(nodes[i].op)] {
            if nodes[arg].op!=.Const {nodes[arg].live=true}
        }
    }
    instructions:=0
    for i in 0..=root {
        if !nodes[i].live {continue}
        instructions+=1
        for arg in nodes[i].args[:op_arity(nodes[i].op)] {nodes[arg].last=i32(i)}
    }
    nodes[root].last=max(i32)
    if instructions>MAX_CODE {fail(c,.Too_Large,0,len(c.source),"the expression has more than MAX_CODE instructions");return {}}
    code,ok:=slice_alloc([]Field_Instr,instructions,allocator)
    if !ok {fail(c,.Out_Of_Memory,0,0,"out of memory");return {}}
    free:=u32((1<<MAX_SLOTS)-1)
    used:u32
    at:=0
    for i in 0..=root {
        n:=&nodes[i]
        if !n.live {continue}
        arity:=op_arity(n.op)
        instr:=Field_Instr{op=n.op,input=n.input,index=n.index,seed=n.seed}
        for k in 0..<arity {
            arg:=&nodes[n.args[k]]
            if arg.op==.Const {
                instr.imm_mask|=1<<u32(k)
                instr.imm[k]=arg.value
            } else {
                instr.args[k]=u8(arg.slot)
                if arg.last==i32(i) {free|=1<<u32(arg.slot)}
            }
        }
        if free==0 {
            delete(code,allocator)
            fail(c,.Slot_Overflow,int(n.offset),int(n.length),"more than MAX_SLOTS values are needed at once; bind fewer values with let or split the expression")
            return {}
        }
        slot:=intrinsics.count_trailing_zeros(free)
        free&=~(1<<slot)
        used|=1<<slot
        n.slot=i32(slot)
        instr.dst=u8(slot)
        code[at]=instr
        at+=1
    }
    slots:=u8(32-intrinsics.count_leading_zeros(used))
    output:=u8(nodes[root].slot)
    return {code=code,output=output,slots=slots,hash=field_program_hash(code,output,slots),allocator=allocator}
}
