package shaders

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// A program read as what each of its values is made from: the editor shows
// it as a graph and the check reads it. The source is the only truth:
// the graph is derived again for every revision, never stored or edited.
//
// It covers the subset programs are written in (namespace, struct
// Parameters, functions with declarations, assignments, if, for, while,
// return and calls); a statement it does not understand becomes an opaque
// code node over its lines, with what it reads and writes.
//
// Node ids are stable across revisions: Program/function/variable, the n-th
// write of a value with #n from the second on (Ocean/evaluate/out.roughness#2),
// inputs as ctx.field and p.field, constants as const:text.

Token_Kind :: enum u8 {End,Identifier,Number,String,Symbol,Directive}
Token :: struct {kind:Token_Kind,text:string,line,column,offset:i32}

Expr_Kind :: enum u8 {Name,Number,Call,Member,Index,Unary,Binary,Ternary,List}
// text: the name, literal, member or operator; kids: callee and arguments,
// base and index, operands.
Expr :: struct {kind:Expr_Kind,text:string,kids:[]int,first,last:int}

Stmt_Kind :: enum u8 {Declare,Assign,If,For,While,Return,Expression,Block,Opaque}
Stmt :: struct {
    kind:Stmt_Kind,
    type,name,op:string, // Declare: type and name; Assign: the operator
    target,value:int,    // expressions, -1 without one
    body,other:[]int,    // statements: then and else, or the body of a loop
    init,step:int,       // For: statements, -1 without one
    first,last:int,      // tokens
}

Surface_Param :: struct {name,type:string,out,inout:bool} // out: the function writes it; inout: it reads it too
Surface_Function :: struct {name,type:string,params:[]Surface_Param,body:[]int,first,last:int}
Surface_Field :: struct {name,type:string,line,column:i32}
Surface_Metadata :: struct {field,value:string,line:i32}

Surface_Source :: struct {
    text:string,
    tokens:[]Token,
    exprs:[dynamic]Expr,
    stmts:[dynamic]Stmt,
    domain:Program_Domain, // of the //! mirai line
    name:string,
    declared_line:i32,
    namespace_name:string,
    namespace_line:i32,
    has_parameters:bool,
    parameters_line:i32,
    parameters:[]Surface_Field,
    functions:[]Surface_Function,
    metadata:[]Surface_Metadata,
    constants:map[string]int, // namespace constants: their value
    structs:map[string][]Surface_Field, // every struct the text declares, Parameters too
}

Graph_Node_Kind :: enum u8 {Input,Parameter,Texture,Constant,Local,Call,Branch,Loop,Output,Surface,Return,Code}
GRAPH_NODE_KINDS :: [Graph_Node_Kind]string{.Input="input",.Parameter="parameter",.Texture="texture",.Constant="constant",.Local="local",.Call="call",.Branch="if",.Loop="loop",.Output="output",.Surface="surface",.Return="return",.Code="code"}

// What the value of a node can be, as far as the source says: an upper bound
// of its components (infinity when unknown) and where it comes from.
Facts :: struct {
    upper:f64,
    constant:bool,
    value:[4]f64,
    components:int,
    normalized,textured,tangent:bool,
}

Graph_Node :: struct {
    id,label,function:string,
    type:string, // of its value, as the source and the contract declare it; empty when unknown
    kind:Graph_Node_Kind,
    first_line,last_line:i32,
    text:string,
    expr:int, // the expression of its value, -1 without one
    facts:Facts,
}
Graph_Edge :: struct {from,to:int,control:bool}
Surface_Graph :: struct {nodes:[dynamic]Graph_Node,edges:[dynamic]Graph_Edge}

// ---------------------------------------------------------------- tokens

@(private="file")
SYMBOLS :: [?]string{"<<=",">>=","::","->","==","!=","<=",">=","&&","||","+=","-=","*=","/=","%=","&=","|=","^=","++","--","<<",">>"}

surface_tokens :: proc(text:string,allocator:=context.allocator) -> []Token {
    tokens:=make([dynamic]Token,allocator)
    line,column:i32=1,1
    i:=0
    advance :: proc(text:string,i:^int,line,column:^i32,count:int) {
        for _ in 0..<count {
            if i^>=len(text) {return}
            if text[i^]=='\n' {line^+=1;column^=1} else {column^+=1}
            i^+=1
        }
    }
    line_start:=true
    for i<len(text) {
        c:=text[i]
        if c=='\n' {advance(text,&i,&line,&column,1);line_start=true;continue}
        if is_space(c) {advance(text,&i,&line,&column,1);continue}
        start,start_line,start_column:=i,line,column
        switch {
        case c=='/' && i+1<len(text) && text[i+1]=='/':
            for i<len(text) && text[i]!='\n' {advance(text,&i,&line,&column,1)}
            continue
        case c=='/' && i+1<len(text) && text[i+1]=='*':
            advance(text,&i,&line,&column,2)
            for i<len(text) && !(text[i]=='*' && i+1<len(text) && text[i+1]=='/') {advance(text,&i,&line,&column,1)}
            advance(text,&i,&line,&column,2)
            continue
        case c=='#' && line_start:
            for i<len(text) && text[i]!='\n' {
                if text[i]=='\\' && i+1<len(text) && text[i+1]=='\n' {advance(text,&i,&line,&column,2);continue}
                advance(text,&i,&line,&column,1)
            }
            append(&tokens,Token{.Directive,text[start:i],start_line,start_column,i32(start)})
        case c=='"':
            advance(text,&i,&line,&column,1)
            for i<len(text) && text[i]!='"' && text[i]!='\n' {advance(text,&i,&line,&column,text[i]=='\\'?2:1)}
            advance(text,&i,&line,&column,1)
            append(&tokens,Token{.String,text[start:min(i,len(text))],start_line,start_column,i32(start)})
        case c>='0' && c<='9' || c=='.' && i+1<len(text) && text[i+1]>='0' && text[i+1]<='9':
            for i<len(text) && (is_word(text[i]) || text[i]=='.' || (text[i]=='+' || text[i]=='-') && (text[i-1]=='e' || text[i-1]=='E') && !(text[start]=='0' && start+1<len(text) && (text[start+1]=='x' || text[start+1]=='X'))) {advance(text,&i,&line,&column,1)}
            append(&tokens,Token{.Number,text[start:i],start_line,start_column,i32(start)})
        case is_word(c):
            for i<len(text) && is_word(text[i]) {advance(text,&i,&line,&column,1)}
            append(&tokens,Token{.Identifier,text[start:i],start_line,start_column,i32(start)})
        case:
            length:=1
            for symbol in SYMBOLS {if strings.has_prefix(text[i:],symbol) {length=len(symbol);break}}
            advance(text,&i,&line,&column,length)
            append(&tokens,Token{.Symbol,text[start:i],start_line,start_column,i32(start)})
        }
        line_start=false
    }
    append(&tokens,Token{.End,"",line,column,i32(len(text))})
    return tokens[:]
}

// ---------------------------------------------------------------- parsing

@(private="file")
Parser :: struct {src:^Surface_Source,at:int,allocator:runtime.Allocator}

@(private="file")
peek :: proc(p:^Parser,ahead:=0) -> Token {return p.src.tokens[min(p.at+ahead,len(p.src.tokens)-1)]}
@(private="file")
next :: proc(p:^Parser) -> Token {
    t:=peek(p)
    if t.kind!=.End {p.at+=1}
    return t
}
@(private="file")
is :: proc(p:^Parser,text:string,ahead:=0) -> bool {t:=peek(p,ahead);return t.kind!=.End && t.kind!=.String && t.text==text}
@(private="file")
accept :: proc(p:^Parser,text:string) -> bool {
    if is(p,text) {p.at+=1;return true}
    return false
}

// The token after the one that closes the bracket opened at `at`.
@(private="file")
skip_balanced :: proc(p:^Parser) {
    open:=peek(p).text
    close:=open=="("?")":open=="["?"]":"}"
    depth:=0
    for t:=next(p);t.kind!=.End;t=next(p) {
        if t.kind!=.Symbol {continue}
        if t.text==open {depth+=1}
        if t.text==close {depth-=1;if depth==0 {return}}
    }
}

@(private="file")
expr_add :: proc(p:^Parser,e:Expr) -> int {
    append(&p.src.exprs,e)
    return len(p.src.exprs)-1
}

@(private="file")
kids :: proc(p:^Parser,values:..int) -> []int {
    out:=make([]int,len(values),p.allocator)
    copy(out,values)
    return out
}

@(private="file")
BINARY :: [?]struct{op:string,precedence:int}{
    {"||",1},{"&&",2},{"|",3},{"^",4},{"&",5},{"==",6},{"!=",6},{"<",7},{">",7},{"<=",7},{">=",7},
    {"<<",8},{">>",8},{"+",9},{"-",9},{"*",10},{"/",10},{"%",10},
}

@(private="file")
binary_precedence :: proc(t:Token) -> int {
    if t.kind!=.Symbol {return 0}
    for b in BINARY {if b.op==t.text {return b.precedence}}
    return 0
}

// An expression, or -1 when what follows is not one.
@(private="file")
parse_expr :: proc(p:^Parser) -> int {
    first:=p.at
    cond:=parse_binary(p,1)
    if cond<0 {return -1}
    if accept(p,"?") {
        a:=parse_expr(p)
        if a<0 || !accept(p,":") {return -1}
        b:=parse_expr(p)
        if b<0 {return -1}
        return expr_add(p,{kind=.Ternary,text="?",kids=kids(p,cond,a,b),first=first,last=p.at-1})
    }
    return cond
}

@(private="file")
parse_binary :: proc(p:^Parser,minimum:int) -> int {
    first:=p.at
    left:=parse_unary(p)
    if left<0 {return -1}
    for {
        t:=peek(p)
        precedence:=binary_precedence(t)
        if precedence==0 || precedence<minimum {return left}
        next(p)
        right:=parse_binary(p,precedence+1)
        if right<0 {return -1}
        left=expr_add(p,{kind=.Binary,text=t.text,kids=kids(p,left,right),first=first,last=p.at-1})
    }
}

@(private="file")
parse_unary :: proc(p:^Parser) -> int {
    first:=p.at
    t:=peek(p)
    if t.kind==.Symbol && (t.text=="-" || t.text=="+" || t.text=="!" || t.text=="~" || t.text=="++" || t.text=="--") {
        next(p)
        operand:=parse_unary(p)
        if operand<0 {return -1}
        return expr_add(p,{kind=.Unary,text=t.text,kids=kids(p,operand),first=first,last=p.at-1})
    }
    // A cast: (float3)x.
    if t.text=="(" && peek(p,1).kind==.Identifier && is(p,")",2) && peek(p,3).kind!=.Symbol {
        type:=expr_add(p,{kind=.Name,text=peek(p,1).text,first=first+1,last=first+1})
        p.at+=3
        operand:=parse_unary(p)
        if operand<0 {return -1}
        return expr_add(p,{kind=.Call,kids=kids(p,type,operand),first=first,last=p.at-1})
    }
    return parse_postfix(p)
}

@(private="file")
parse_postfix :: proc(p:^Parser) -> int {
    first:=p.at
    value:=parse_primary(p)
    if value<0 {return -1}
    for {
        switch {
        case is(p,"("):
            next(p)
            args:=make([dynamic]int,p.allocator)
            append(&args,value)
            if !accept(p,")") {
                for {
                    arg:=parse_expr(p)
                    if arg<0 {return -1}
                    append(&args,arg)
                    if accept(p,")") {break}
                    if !accept(p,",") {return -1}
                }
            }
            value=expr_add(p,{kind=.Call,kids=args[:],first=first,last=p.at-1})
        case is(p,"."):
            next(p)
            field:=next(p)
            if field.kind!=.Identifier {return -1}
            value=expr_add(p,{kind=.Member,text=field.text,kids=kids(p,value),first=first,last=p.at-1})
        case is(p,"["):
            next(p)
            index:=parse_expr(p)
            if index<0 || !accept(p,"]") {return -1}
            value=expr_add(p,{kind=.Index,kids=kids(p,value,index),first=first,last=p.at-1})
        case is(p,"++") || is(p,"--"):
            t:=next(p)
            value=expr_add(p,{kind=.Unary,text=t.text,kids=kids(p,value),first=first,last=p.at-1})
        case:
            return value
        }
    }
}

@(private="file")
parse_primary :: proc(p:^Parser) -> int {
    first:=p.at
    t:=peek(p)
    switch t.kind {
    case .Identifier:
        next(p)
        name:=t.text
        // A qualified name: Namespace::function.
        for is(p,"::") && peek(p,1).kind==.Identifier {next(p);name=next(p).text}
        return expr_add(p,{kind=.Name,text=name,first=first,last=p.at-1})
    case .Number:
        next(p)
        return expr_add(p,{kind=.Number,text=t.text,first=first,last=first})
    case .Symbol:
        if t.text=="(" {
            next(p)
            inner:=parse_expr(p)
            if inner<0 || !accept(p,")") {return -1}
            return inner
        }
        if t.text=="{" {
            next(p)
            items:=make([dynamic]int,p.allocator)
            if !accept(p,"}") {
                for {
                    item:=parse_expr(p)
                    if item<0 {return -1}
                    append(&items,item)
                    accept(p,",")
                    if accept(p,"}") {break}
                }
            }
            return expr_add(p,{kind=.List,kids=items[:],first=first,last=p.at-1})
        }
    case .End,.String,.Directive:
    }
    return -1
}

@(private="file")
TYPE_QUALIFIERS :: [?]string{"const","static","in","out","inout","uniform","precise","let","var"}

// A type at the cursor: an identifier with template arguments, after its qualifiers.
@(private="file")
parse_type :: proc(p:^Parser) -> (type:string,out,inout,ok:bool) {
    for {
        qualified:=false
        for q in TYPE_QUALIFIERS {
            if is(p,q) && peek(p,1).kind==.Identifier {
                if q=="out" || q=="inout" {out=true}
                if q=="inout" {inout=true}
                next(p);qualified=true;break
            }
        }
        if !qualified {break}
    }
    t:=peek(p)
    if t.kind!=.Identifier {return}
    first:=p.at
    next(p)
    if is(p,"<") {
        depth:=0
        for t:=next(p);t.kind!=.End;t=next(p) {
            if t.text=="<" {depth+=1}
            if t.text==">" {depth-=1;if depth==0 {break}}
        }
    }
    a:=p.src.tokens[first]
    b:=p.src.tokens[p.at-1]
    return p.src.text[a.offset:int(b.offset)+len(b.text)],out,inout,true
}

@(private="file")
stmt_add :: proc(p:^Parser,s:Stmt) -> int {
    append(&p.src.stmts,s)
    return len(p.src.stmts)-1
}

// Statements until the closing brace of a block, which it takes.
@(private="file")
parse_block :: proc(p:^Parser) -> []int {
    list:=make([dynamic]int,p.allocator)
    for !is(p,"}") && peek(p).kind!=.End {
        before:=p.at
        for statement in parse_statement(p) {append(&list,statement)}
        if p.at==before {next(p)}
    }
    accept(p,"}")
    return list[:]
}

// The statements one statement of the source gives (a declaration of
// several names gives one per name); an opaque one when it is not understood.
@(private="file")
parse_statement :: proc(p:^Parser) -> []int {
    first:=p.at
    opaque :: proc(p:^Parser,first:int) -> []int {
        p.at=first
        depth:=0
        for t:=peek(p);t.kind!=.End;t=peek(p) {
            if t.text=="{" && t.kind==.Symbol {skip_balanced(p);if depth==0 {break};continue}
            next(p)
            if t.kind!=.Symbol {continue}
            if t.text=="(" || t.text=="[" {depth+=1}
            if t.text==")" || t.text=="]" {depth-=1}
            if t.text==";" && depth<=0 {break}
            if t.text=="}" {p.at-=1;break}
        }
        if p.at==first {next(p)}
        return single(p,stmt_add(p,{kind=.Opaque,target=-1,value=-1,init=-1,step=-1,first=first,last=p.at-1}))
    }
    single :: proc(p:^Parser,statement:int) -> []int {
        out:=make([]int,1,p.allocator)
        out[0]=statement
        return out
    }
    t:=peek(p)
    if t.kind==.Directive {next(p);return single(p,stmt_add(p,{kind=.Opaque,target=-1,value=-1,init=-1,step=-1,first=first,last=first}))}
    if t.text=="[" && t.kind==.Symbol {skip_balanced(p);first=p.at;t=peek(p)} // attributes: [unroll]
    switch {
    case t.text==";" && t.kind==.Symbol:
        next(p)
        return nil
    case t.text=="{" && t.kind==.Symbol:
        next(p)
        body:=parse_block(p)
        return single(p,stmt_add(p,{kind=.Block,body=body,target=-1,value=-1,init=-1,step=-1,first=first,last=p.at-1}))
    case t.text=="if":
        next(p)
        if !accept(p,"(") {return opaque(p,first)}
        cond:=parse_expr(p)
        if cond<0 || !accept(p,")") {return opaque(p,first)}
        then:=parse_statement(p)
        other:[]int
        if accept(p,"else") {other=parse_statement(p)}
        return single(p,stmt_add(p,{kind=.If,value=cond,body=then,other=other,target=-1,init=-1,step=-1,first=first,last=p.at-1}))
    case t.text=="for":
        next(p)
        if !accept(p,"(") {return opaque(p,first)}
        init:=-1
        if !accept(p,";") {
            list:=parse_statement(p)
            if len(list)!=1 {return opaque(p,first)}
            init=list[0]
        }
        cond:=-1
        if !is(p,";") {cond=parse_expr(p);if cond<0 {return opaque(p,first)}}
        if !accept(p,";") {return opaque(p,first)}
        step:=-1
        if !is(p,")") {
            at:=p.at
            value:=parse_expr(p)
            if value<0 {return opaque(p,first)}
            op:=""
            if peek(p).kind==.Symbol && strings.has_suffix(peek(p).text,"=") && peek(p).text!="==" {op=next(p).text}
            target:=-1
            if op!="" {target=value;value=parse_expr(p);if value<0 {return opaque(p,first)}}
            step=stmt_add(p,{kind=op!=""?.Assign:.Expression,op=op,target=target,value=value,init=-1,step=-1,first=at,last=p.at-1})
        }
        if !accept(p,")") {return opaque(p,first)}
        body:=parse_statement(p)
        return single(p,stmt_add(p,{kind=.For,init=init,value=cond,step=step,body=body,target=-1,first=first,last=p.at-1}))
    case t.text=="while":
        next(p)
        if !accept(p,"(") {return opaque(p,first)}
        cond:=parse_expr(p)
        if cond<0 || !accept(p,")") {return opaque(p,first)}
        body:=parse_statement(p)
        return single(p,stmt_add(p,{kind=.While,value=cond,body=body,target=-1,init=-1,step=-1,first=first,last=p.at-1}))
    case t.text=="return":
        next(p)
        value:=-1
        if !is(p,";") {value=parse_expr(p);if value<0 {return opaque(p,first)}}
        if !accept(p,";") {return opaque(p,first)}
        return single(p,stmt_add(p,{kind=.Return,value=value,target=-1,init=-1,step=-1,first=first,last=p.at-1}))
    case t.text=="switch" || t.text=="do" || t.text=="struct" || t.text=="break" || t.text=="continue" || t.text=="discard":
        return opaque(p,first)
    }
    // A declaration: a type followed by a name.
    if type,_,_,typed:=parse_type(p);typed && peek(p).kind==.Identifier && !(peek(p,1).text=="(" && peek(p,1).kind==.Symbol) {
        list:=make([dynamic]int,p.allocator)
        for {
            name:=next(p)
            if name.kind!=.Identifier {return opaque(p,first)}
            if is(p,"[") {skip_balanced(p)}
            value:=-1
            if accept(p,"=") {value=parse_expr(p);if value<0 {return opaque(p,first)}}
            append(&list,stmt_add(p,{kind=.Declare,type=type,name=name.text,value=value,target=-1,init=-1,step=-1,first=first,last=p.at-1}))
            if accept(p,",") {continue}
            if accept(p,";") {break}
            return opaque(p,first)
        }
        for statement in list {p.src.stmts[statement].last=p.at-1}
        return list[:]
    }
    p.at=first
    value:=parse_expr(p)
    if value<0 {return opaque(p,first)}
    if peek(p).kind==.Symbol && strings.has_suffix(peek(p).text,"=") && peek(p).text!="==" && peek(p).text!="!=" && peek(p).text!="<=" && peek(p).text!=">=" {
        op:=next(p).text
        target:=value
        value=parse_expr(p)
        if value<0 || !accept(p,";") {return opaque(p,first)}
        return single(p,stmt_add(p,{kind=.Assign,op=op,target=target,value=value,init=-1,step=-1,first=first,last=p.at-1}))
    }
    if !accept(p,";") {return opaque(p,first)}
    return single(p,stmt_add(p,{kind=.Expression,value=value,target=-1,init=-1,step=-1,first=first,last=p.at-1}))
}

// Reads a program: its declaration and metadata lines, its namespace with
// struct Parameters and its functions. What does not parse stays opaque.
surface_parse :: proc(text:string,allocator:=context.allocator) -> (src:Surface_Source) {
    src.text=text
    src.tokens=surface_tokens(text,allocator)
    src.exprs=make([dynamic]Expr,allocator)
    src.stmts=make([dynamic]Stmt,allocator)
    src.constants=make(map[string]int,allocator)
    src.structs=make(map[string][]Surface_Field,allocator)
    metadata:=make([dynamic]Surface_Metadata,allocator)
    rest:=text
    line:i32=0
    for raw in strings.split_lines_iterator(&rest) {
        line+=1
        trimmed:=strings.trim_space(raw)
        if field,value,found:=parameter_metadata(trimmed);found {append(&metadata,Surface_Metadata{field,value,line})}
    }
    if said:=program_directives(text);said.name!="" {
        src.domain,_=program_domain(said.domain)
        src.name,src.declared_line=strings.clone(said.name,allocator),i32(said.line)
    }
    src.metadata=metadata[:]
    p:=Parser{src=&src,allocator=allocator}
    functions:=make([dynamic]Surface_Function,allocator)
    fields:=make([dynamic]Surface_Field,allocator)
    // Namespaces may nest the program; functions and Parameters are read where they are.
    depth:=0
    for peek(&p).kind!=.End {
        t:=peek(&p)
        if t.kind==.Directive {next(&p);continue}
        if t.text=="namespace" && peek(&p,1).kind==.Identifier && is(&p,"{",2) {
            if src.namespace_name=="" {src.namespace_name,src.namespace_line=peek(&p,1).text,peek(&p,1).line}
            p.at+=3
            depth+=1
            continue
        }
        if t.text=="}" && t.kind==.Symbol {next(&p);depth-=1;continue}
        if t.text=="struct" && peek(&p,1).kind==.Identifier {
            name:=peek(&p,1)
            p.at+=2
            if !is(&p,"{") {continue}
            // Its fields, inside its braces; a method is skipped.
            start:=p.at
            skip_balanced(&p)
            end:=p.at
            p.at=start+1
            members:=make([dynamic]Surface_Field,allocator)
            for p.at<end-1 {
                type,_,_,typed:=parse_type(&p)
                if !typed {next(&p);continue}
                for p.at<end-1 {
                    field:=next(&p)
                    if field.kind!=.Identifier {break}
                    if is(&p,"(") {
                        skip_balanced(&p)
                        if is(&p,"{") {skip_balanced(&p)}
                        break
                    }
                    if is(&p,"[") {skip_balanced(&p)}
                    if is(&p,":") {next(&p);next(&p)} // a semantic
                    append(&members,Surface_Field{field.text,type,field.line,field.column})
                    if !accept(&p,",") {break}
                }
                accept(&p,";")
            }
            p.at=end
            accept(&p,";")
            src.structs[name.text]=members[:]
            if name.text=="Parameters" {
                src.has_parameters,src.parameters_line=true,name.line
                append(&fields,..members[:])
            }
            continue
        }
        // A function or a constant: a type, a name and ( or =.
        start:=p.at
        if t.text=="[" && t.kind==.Symbol {skip_balanced(&p);continue}
        type,_,_,typed:=parse_type(&p)
        if !typed || peek(&p).kind!=.Identifier {p.at=start+1;continue}
        name:=next(&p)
        if accept(&p,"=") {
            value:=parse_expr(&p)
            if value>=0 {src.constants[name.text]=value}
            for !is(&p,";") && peek(&p).kind!=.End {next(&p)}
            accept(&p,";")
            continue
        }
        if !is(&p,"(") {p.at=start+1;continue}
        next(&p)
        params:=make([dynamic]Surface_Param,allocator)
        for !accept(&p,")") && peek(&p).kind!=.End {
            param_type,out,inout,param_typed:=parse_type(&p)
            if !param_typed {next(&p);continue}
            param:=next(&p)
            if is(&p,":") {next(&p);next(&p)}
            if accept(&p,"=") {parse_expr(&p)}
            append(&params,Surface_Param{param.text,param_type,out,inout})
            accept(&p,",")
        }
        if is(&p,":") {next(&p);next(&p)} // a semantic of the result
        if !is(&p,"{") {accept(&p,";");continue}
        next(&p)
        body:=parse_block(&p)
        append(&functions,Surface_Function{name=name.text,type=type,params=params[:],body=body,first=start,last=p.at-1})
    }
    src.functions=functions[:]
    src.parameters=fields[:]
    return
}

// ---------------------------------------------------------------- the graph

@(private="file")
Builder :: struct {
    src:^Surface_Source,
    graph:^Surface_Graph,
    meta:map[string]json.Object,
    program,function:string,
    fn:^Surface_Function,
    current:map[string]int, // a variable, or out.field: the node of its value
    writes:map[string]int,  // an id: how many nodes have it
    types:map[string]string, // a variable: the type it was declared with
    out_name:string,        // the variable the function returns
    control:[dynamic]int,   // the branches and loops around the statement
    contract:^Surface_Source, // what declares Mirai_Surface and its context; nil without it
    allocator:runtime.Allocator,
}

// The type of a field of a struct of the program, or of the contract.
@(private="file")
field_type :: proc(b:^Builder,structure,field:string) -> string {
    for source in ([2]^Surface_Source{b.src,b.contract}) {
        if source==nil {continue}
        for f in source.structs[structure] {if f.name==field {return f.type}}
    }
    return ""
}

// A node takes its type: the one declared, or what its value has of a vector.
@(private="file")
node_typed :: proc(b:^Builder,node:int,type:string) {
    n:=&b.graph.nodes[node]
    if type!="" {n.type=type;return}
    switch n.facts.components {
    case 1: n.type="float"
    case 2: n.type="float2"
    case 3: n.type="float3"
    case 4: n.type="float4"
    }
}

@(private="file")
node_id :: proc(b:^Builder,name:string) -> string {
    base:=fmt.aprintf("%s/%s/%s",b.program,b.function,name,allocator=b.allocator)
    count:=b.writes[base]+1
    b.writes[base]=count
    if count==1 {return base}
    return fmt.aprintf("%s#%d",base,count,allocator=b.allocator)
}

@(private="file")
tokens_text :: proc(src:^Surface_Source,first,last:int) -> string {
    if first<0 || last<first || last>=len(src.tokens) {return ""}
    a,z:=src.tokens[first],src.tokens[last]
    return strings.trim_space(src.text[a.offset:int(z.offset)+len(z.text)])
}

@(private="file")
node_add :: proc(b:^Builder,kind:Graph_Node_Kind,name,label:string,first,last,expr:int,facts:Facts,sources:[]int) -> int {
    src:=b.src
    line_a:=first>=0?src.tokens[first].line:0
    line_z:=last>=0?src.tokens[last].line:line_a
    append(&b.graph.nodes,Graph_Node{id=node_id(b,name),label=label,function=b.function,kind=kind,first_line=line_a,last_line=line_z,text=tokens_text(src,first,last),expr=expr,facts=facts})
    index:=len(b.graph.nodes)-1
    seen:=make(map[int]bool,context.temp_allocator)
    for source in sources {
        if source<0 || source==index || seen[source] {continue}
        seen[source]=true
        append(&b.graph.edges,Graph_Edge{source,index,false})
    }
    if len(b.control)>0 {append(&b.graph.edges,Graph_Edge{b.control[len(b.control)-1],index,true})}
    return index
}

// An input of the function: made the first time it is read.
@(private="file")
input :: proc(b:^Builder,key:string,kind:Graph_Node_Kind,first:int,facts:Facts) -> int {
    if node,known:=b.current[key];known {return node}
    saved:=b.control
    b.control=nil
    line:=first
    node:=node_add(b,kind,key,key,line,line,-1,facts,nil)
    b.control=saved
    if kind==.Parameter && strings.has_prefix(key,"p.") {
        name:=key[len("p."):]
        for field in b.src.parameters {if field.name==name {b.graph.nodes[node].first_line,b.graph.nodes[node].last_line=field.line,field.line}}
    }
    type:string
    switch {
    case key=="ctx": type="Mirai_Surface_Context"
    case key=="p":   type="Parameters"
    case strings.has_prefix(key,"ctx."): type=field_type(b,"Mirai_Surface_Context",key[len("ctx."):])
    case strings.has_prefix(key,"p."):   type=field_type(b,"Parameters",key[len("p."):])
    case kind==.Input:
        if param,found:=param_of(b,key);found {type=param.type}
    }
    node_typed(b,node,type)
    b.current[key]=node
    return node
}

@(private="file")
UNKNOWN :: Facts{upper=math.INF_F64}

@(private="file")
param_of :: proc(b:^Builder,name:string) -> (Surface_Param,bool) {
    for param in b.fn.params {if param.name==name {return param,true}}
    return {},false
}

// The variable an expression names and the field of the returned surface it
// reaches: s.normal.xy is s and normal.
@(private="file")
lvalue :: proc(b:^Builder,e:int) -> (variable,field:string,ok:bool) {
    expr:=b.src.exprs[e]
    #partial switch expr.kind {
    case .Name: return expr.text,"",true
    case .Member,.Index:
        inner,inner_field,found:=lvalue(b,expr.kids[0])
        if !found {return}
        if inner==b.out_name && inner_field=="" && expr.kind==.Member {return inner,expr.text,true}
        return inner,inner_field,true
    }
    return
}

@(private="file")
key_of :: proc(b:^Builder,variable,field:string) -> string {
    if variable==b.out_name && field!="" {return fmt.aprintf("out.%s",field,allocator=b.allocator)}
    if variable==b.out_name {return "out"}
    return variable
}

@(private)
literal :: proc(text:string) -> (value:f64,ok:bool) {
    trimmed:=strings.trim_right(text,"fFhHlLuU")
    return strconv.parse_f64(trimmed)
}

@(private="file")
VECTOR_TYPES :: [?]string{"float","float2","float3","float4","half","half2","half3","half4","int","int2","int3","int4","uint","uint2","uint3","uint4","double"}

@(private="file")
is_vector_type :: proc(name:string) -> bool {
    for t in VECTOR_TYPES {if t==name {return true}}
    return false
}

@(private="file")
SAMPLERS :: [?]string{"mirai_sample_texture","mirai_sample_texture_level","mirai_sample_texture_grad"}

@(private="file")
function_find :: proc(src:^Surface_Source,name:string) -> ^Surface_Function {
    for &f in src.functions {if f.name==name {return &f}}
    return nil
}

// What an expression is made from: the nodes it reads, made when they are
// inputs, and what the source says of its value.
@(private="file")
sources_of :: proc(b:^Builder,e:int,out:^[dynamic]int) -> (facts:Facts) {
    facts=UNKNOWN
    if e<0 {return}
    src:=b.src
    expr:=src.exprs[e]
    first:=expr.first
    switch expr.kind {
    case .Number:
        value,ok:=literal(expr.text)
        facts={upper=ok?value:math.INF_F64,constant=ok,components=1}
        facts.value={value,value,value,value}
        append(out,input(b,fmt.aprintf("const:%s",expr.text,allocator=b.allocator),.Constant,first,facts))
    case .Name:
        if node,known:=b.current[expr.text];known {append(out,node);return b.graph.nodes[node].facts}
        if param,found:=param_of(b,expr.text);found {
            switch param.type {
            case "Mirai_Surface_Context": append(out,input(b,"ctx",.Input,first,UNKNOWN))
            case "Parameters":            append(out,input(b,"p",.Parameter,first,UNKNOWN))
            case:                         append(out,input(b,expr.text,.Input,first,UNKNOWN))
            }
            return
        }
        if value,constant:=src.constants[expr.text];constant {
            inner:=make([dynamic]int,context.temp_allocator)
            facts=sources_of(b,value,&inner)
            append(out,input(b,fmt.aprintf("const:%s",expr.text,allocator=b.allocator),.Constant,first,facts))
        }
    case .Member:
        base:=src.exprs[expr.kids[0]]
        if base.kind==.Name {
            if param,found:=param_of(b,base.text);found {
                switch param.type {
                case "Mirai_Surface_Context":
                    f:=UNKNOWN
                    switch expr.text {
                    case "normal","vertex_normal": f={upper=1,normalized=true,components=3}
                    case "tangent": f={upper=1,tangent=true,components=4}
                    }
                    node:=input(b,fmt.aprintf("ctx.%s",expr.text,allocator=b.allocator),.Input,first,f)
                    append(out,node)
                    return b.graph.nodes[node].facts
                case "Parameters":
                    f:=UNKNOWN
                    if meta,has:=b.meta[expr.text];has {
                        if bound,bounded:=json_bound(meta["max"]);bounded {f.upper=bound}
                    }
                    node:=input(b,fmt.aprintf("p.%s",expr.text,allocator=b.allocator),.Parameter,first,f)
                    append(out,node)
                    return b.graph.nodes[node].facts
                }
            }
            if base.text==b.out_name {
                key:=fmt.aprintf("out.%s",expr.text,allocator=b.allocator)
                node,known:=b.current[key]
                if !known {node,known=b.current["out"]}
                if known {append(out,node);return b.graph.nodes[node].facts}
                return
            }
        }
        inner:=sources_of(b,expr.kids[0],out)
        // A swizzle keeps what its vector is; a member of anything else is unknown.
        swizzle:=len(expr.text)<=4
        for c in transmute([]u8)expr.text {swizzle&&=strings.index_byte("xyzwrgba",c)>=0}
        if swizzle {inner.components=len(expr.text);if len(expr.text)<3 {inner.normalized=false};return inner}
        return {upper=math.INF_F64,textured=inner.textured,tangent=inner.tangent}
    case .Call:
        callee:=src.exprs[expr.kids[0]]
        args:=expr.kids[1:]
        name:=callee.kind==.Name?callee.text:""
        arg_facts:=make([dynamic]Facts,context.temp_allocator)
        collect :: proc(b:^Builder,args:[]int,out:^[dynamic]int,facts:^[dynamic]Facts) {
            for arg in args {append(facts,sources_of(b,arg,out))}
        }
        for sampler in SAMPLERS {
            if name!=sampler {continue}
            inner:=make([dynamic]int,context.temp_allocator)
            for arg in args {
                a:=src.exprs[arg]
                if a.kind==.Name && a.text!="" {if param,found:=param_of(b,a.text);found && param.type=="Mirai_Surface_Context" {continue}}
                sources_of(b,arg,&inner)
            }
            label:=len(args)>1 && name=="mirai_sample_texture"?tokens_text(src,src.exprs[args[1]].first,src.exprs[args[1]].last):tokens_text(src,src.exprs[args[0]].first,src.exprs[args[0]].last)
            f:=Facts{upper=1,textured=true,components=4}
            node:=node_add(b,.Texture,"texture",fmt.aprintf("texture %s",label,allocator=b.allocator),expr.first,expr.last,e,f,inner[:])
            node_typed(b,node,"float4")
            append(out,node)
            return f
        }
        if is_vector_type(name) && len(args)>0 {
            literals:=true
            for arg in args {literals&&=src.exprs[arg].kind==.Number}
            if literals {
                ignored:=make([dynamic]int,context.temp_allocator)
                collect(b,args,&ignored,&arg_facts)
                f:=call_facts(name,arg_facts[:])
                text,_:=strings.remove_all(tokens_text(src,expr.first,expr.last)," ",context.temp_allocator)
                append(out,input(b,fmt.aprintf("const:%s",text,allocator=b.allocator),.Constant,first,f))
                return f
            }
        }
        if own:=function_find(src,name);own!=nil && name!="" {
            inner:=make([dynamic]int,context.temp_allocator)
            for arg,i in args {
                // An out argument is written, not read; inout reads it too.
                if i<len(own.params) && own.params[i].out && !own.params[i].inout {continue}
                sources_of(b,arg,&inner)
            }
            f:=UNKNOWN
            if own.type=="Mirai_Surface" {f.normalized=true}
            node:=node_add(b,.Call,name,fmt.aprintf("%s()",name,allocator=b.allocator),expr.first,expr.last,e,f,inner[:])
            node_typed(b,node,own.type)
            // What an out argument takes is a write of its own, of the type of
            // its parameter: who reads it reads that, not what the call returns.
            for arg,i in args {
                if i>=len(own.params) || !own.params[i].out {continue}
                variable,field,named:=lvalue(b,arg)
                if !named {continue}
                key:=key_of(b,variable,field)
                written:=[2]int{node,-1}
                if a:=src.exprs[arg];a.kind!=.Name {
                    // A partial write keeps what was there.
                    if previous,known:=b.current[key];known {written[1]=previous}
                }
                kind:=Graph_Node_Kind.Local
                if variable==b.out_name {kind=field==""?.Surface:.Output}
                at:=src.exprs[arg]
                b.current[key]=node_add(b,kind,key,key,at.first,at.last,arg,UNKNOWN,written[:])
                node_typed(b,b.current[key],own.params[i].type)
            }
            append(out,node)
            return f
        }
        collect(b,args,out,&arg_facts)
        if name=="" {
            // A method: x.Sample(...) reads what x is.
            sources_of(b,expr.kids[0],out)
            return
        }
        return call_facts(name,arg_facts[:])
    case .Index:
        f:=sources_of(b,expr.kids[0],out)
        sources_of(b,expr.kids[1],out)
        return {upper=f.upper,textured=f.textured,tangent=f.tangent,components=1}
    case .Unary:
        f:=sources_of(b,expr.kids[0],out)
        if expr.text=="-" {
            if f.constant {for &v in f.value {v=-v};f.upper=max(f.value[0],f.value[1],f.value[2],f.value[3])} else {f.upper=math.INF_F64}
            return f
        }
        return {upper=math.INF_F64,textured=f.textured,tangent=f.tangent}
    case .Binary:
        a:=sources_of(b,expr.kids[0],out)
        z:=sources_of(b,expr.kids[1],out)
        facts={upper=math.INF_F64,textured=a.textured||z.textured,tangent=a.tangent||z.tangent,components=max(a.components,z.components)}
        bounded:=a.upper>=0 && z.upper>=0 && a.upper<math.INF_F64 && z.upper<math.INF_F64
        switch expr.text {
        case "*": if bounded {facts.upper=a.upper*z.upper}
        case "+": if bounded {facts.upper=a.upper+z.upper}
        case "-": if a.upper<math.INF_F64 && z.constant && z.value[0]>=0 {facts.upper=a.upper}
        }
        if a.constant && z.constant {
            facts.constant=true
            for i in 0..<4 {
                switch expr.text {
                case "*": facts.value[i]=a.value[i]*z.value[i]
                case "+": facts.value[i]=a.value[i]+z.value[i]
                case "-": facts.value[i]=a.value[i]-z.value[i]
                case "/": facts.value[i]=z.value[i]!=0?a.value[i]/z.value[i]:math.INF_F64
                case: facts.constant=false
                }
            }
            if facts.constant {facts.upper=max(facts.value[0],facts.value[1],facts.value[2],facts.value[3])}
        }
    case .Ternary:
        sources_of(b,expr.kids[0],out)
        a:=sources_of(b,expr.kids[1],out)
        z:=sources_of(b,expr.kids[2],out)
        return {upper=max(a.upper,z.upper),normalized=a.normalized&&z.normalized,textured=a.textured||z.textured,tangent=a.tangent||z.tangent,components=max(a.components,z.components)}
    case .List:
        for kid in expr.kids {sources_of(b,kid,out)}
    }
    return
}

// What an intrinsic or a constructor gives from what its arguments are.
@(private="file")
call_facts :: proc(name:string,args:[]Facts) -> (facts:Facts) {
    facts=UNKNOWN
    textured,tangent:=false,false
    for a in args {textured||=a.textured;tangent||=a.tangent}
    facts.textured,facts.tangent=textured,tangent
    upper_of :: proc(args:[]Facts,i:int) -> f64 {return i<len(args)?args[i].upper:math.INF_F64}
    switch {
    case name=="normalize": facts.upper,facts.normalized=1,true
    case name=="saturate": facts.upper=min(1,upper_of(args,0))
    case name=="sin" || name=="cos" || name=="smoothstep" || name=="step": facts.upper=1
    case name=="lerp" || name=="max": facts.upper=max(upper_of(args,0),upper_of(args,1))
    case name=="min": facts.upper=min(upper_of(args,0),upper_of(args,1))
    case name=="clamp": facts.upper=upper_of(args,2)
    case name=="sqrt": if u:=upper_of(args,0);u<math.INF_F64 && u>=0 {facts.upper=math.sqrt(u)}
    case name=="pow": if len(args)==2 && upper_of(args,0)<=1 && args[1].constant && args[1].value[0]>0 {facts.upper=1}
    case name=="mirai_surface_mix" || name=="mirai_surface_default": facts.normalized=true
    case is_vector_type(name):
        facts.upper=0
        constant:=true
        components:=0
        for a in args {
            facts.upper=max(facts.upper,a.upper)
            constant&&=a.constant
            for c in 0..<max(a.components,1) {if components<4 {facts.value[components]=a.value[c];components+=1}}
        }
        if len(args)==1 && components<4 {for i in components..<4 {facts.value[i]=facts.value[0]}}
        facts.constant=constant && len(args)>0
        facts.components=components
        if len(args)==1 {facts.normalized=args[0].normalized}
    }
    return
}

@(private="file")
build_statements :: proc(b:^Builder,list:[]int) {
    for statement in list {build_statement(b,statement)}
}

@(private="file")
build_statement :: proc(b:^Builder,index:int) {
    src:=b.src
    s:=src.stmts[index]
    switch s.kind {
    case .Declare:
        inner:=make([dynamic]int,context.temp_allocator)
        facts:=sources_of(b,s.value,&inner)
        kind:=Graph_Node_Kind.Local
        key:=s.name
        label:=s.name
        if s.name==b.out_name {kind,key,label=.Surface,"out","out"}
        if s.value<0 {facts=UNKNOWN}
        b.current[key]=node_add(b,kind,key,label,s.first,s.last,s.value,facts,inner[:])
        b.types[s.name]=s.type
        node_typed(b,b.current[key],s.type)
    case .Assign:
        variable,field,named:=lvalue(b,s.target)
        if !named {build_opaque(b,s.first,s.last);return}
        key:=key_of(b,variable,field)
        inner:=make([dynamic]int,context.temp_allocator)
        target:=src.exprs[s.target]
        whole:=target.kind==.Name || variable==b.out_name && target.kind==.Member && src.exprs[target.kids[0]].kind==.Name
        if s.op!="=" || !whole {
            // A compound or partial write reads what was there.
            if node,known:=b.current[key];known {append(&inner,node)} else if node,whole:=b.current[key_of(b,variable,"")];whole {append(&inner,node)}
        }
        facts:=sources_of(b,s.value,&inner)
        if s.op!="=" {facts=UNKNOWN}
        kind:=Graph_Node_Kind.Local
        type:=b.types[variable]
        if variable==b.out_name {
            kind=field==""?.Surface:.Output
            type=field==""?"Mirai_Surface":field_type(b,"Mirai_Surface",field)
        }
        b.current[key]=node_add(b,kind,key,key,s.first,s.last,s.value,facts,inner[:])
        node_typed(b,b.current[key],type)
    case .If:
        inner:=make([dynamic]int,context.temp_allocator)
        sources_of(b,s.value,&inner)
        branch:=node_add(b,.Branch,"if",fmt.aprintf("if %s",tokens_text(src,src.exprs[s.value].first,src.exprs[s.value].last),allocator=b.allocator),s.first,src.exprs[s.value].last+1,s.value,UNKNOWN,inner[:])
        append(&b.control,branch)
        build_statements(b,s.body)
        build_statements(b,s.other)
        pop(&b.control)
    case .For,.While:
        if s.init>=0 {build_statement(b,s.init)}
        inner:=make([dynamic]int,context.temp_allocator)
        sources_of(b,s.value,&inner)
        header:=s.value>=0?src.exprs[s.value].last+1:s.first
        loop:=node_add(b,.Loop,s.kind==.For?"for":"while",tokens_text(src,s.first,header),s.first,header,s.value,UNKNOWN,inner[:])
        append(&b.control,loop)
        build_statements(b,s.body)
        if s.step>=0 {build_statement(b,s.step)}
        pop(&b.control)
    case .Return:
        if s.value<0 {return}
        e:=src.exprs[s.value]
        if e.kind==.Name && e.text==b.out_name {return}
        inner:=make([dynamic]int,context.temp_allocator)
        facts:=sources_of(b,s.value,&inner)
        node_typed(b,node_add(b,.Return,"return","return",s.first,s.last,s.value,facts,inner[:]),b.fn.type)
    case .Expression:
        e:=src.exprs[s.value]
        if e.kind==.Unary && (e.text=="++" || e.text=="--") {
            if variable,field,named:=lvalue(b,e.kids[0]);named {
                key:=key_of(b,variable,field)
                inner:=make([dynamic]int,context.temp_allocator)
                if node,known:=b.current[key];known {append(&inner,node)}
                b.current[key]=node_add(b,.Local,key,key,s.first,s.last,s.value,UNKNOWN,inner[:])
                node_typed(b,b.current[key],b.types[variable])
            }
            return
        }
        inner:=make([dynamic]int,context.temp_allocator)
        sources_of(b,s.value,&inner)
    case .Block:
        build_statements(b,s.body)
    case .Opaque:
        build_opaque(b,s.first,s.last)
    }
}

// Code the reader does not understand: a node over its tokens that reads the
// values it names and gives those it assigns.
@(private="file")
build_opaque :: proc(b:^Builder,first,last:int) {
    src:=b.src
    if first<0 || last<first || src.tokens[first].kind==.Directive {return}
    inner:=make([dynamic]int,context.temp_allocator)
    for i in first..=last {
        t:=src.tokens[i]
        if t.kind!=.Identifier || i>first && src.tokens[i-1].text=="." {continue}
        if node,known:=b.current[t.text];known {append(&inner,node)}
    }
    node:=node_add(b,.Code,"code","code",first,last,-1,UNKNOWN,inner[:])
    for i in first..<last {
        t:=src.tokens[i]
        if t.kind!=.Identifier || i>first && src.tokens[i-1].text=="." {continue}
        j:=i+1
        field:=""
        if j+1<=last && src.tokens[j].text=="." && src.tokens[j+1].kind==.Identifier {field=src.tokens[j+1].text;j+=2}
        for j+1<=last && src.tokens[j].text=="." {j+=2}
        if j<=last && src.tokens[j].kind==.Symbol && strings.has_suffix(src.tokens[j].text,"=") && src.tokens[j].text!="==" {
            if t.text in b.current || t.text==b.out_name {b.current[key_of(b,t.text,t.text==b.out_name?field:"")]=node}
        }
    }
}

// The graph of every function of a program, evaluate and its helpers. The
// contract (mirai_material.slang read with surface_parse) gives the types of
// the context and of the surface; without it they are those the values show.
surface_graph :: proc(src:^Surface_Source,allocator:=context.allocator,contract:^Surface_Source=nil) -> (graph:Surface_Graph) {
    graph.nodes=make([dynamic]Graph_Node,allocator)
    graph.edges=make([dynamic]Graph_Edge,allocator)
    meta:=make(map[string]json.Object,context.temp_allocator)
    for m in src.metadata {
        parsed,error:=json.parse_string(m.value,parse_integers=true,allocator=context.temp_allocator)
        if object,is_object:=parsed.(json.Object);error==.None && is_object {meta[m.field]=object}
    }
    program:=src.namespace_name!=""?src.namespace_name:src.name
    for &f in src.functions {
        b:=Builder{src=src,graph=&graph,meta=meta,program=program,function=f.name,fn=&f,contract=contract,allocator=allocator}
        b.current=make(map[string]int,context.temp_allocator)
        b.writes=make(map[string]int,context.temp_allocator)
        b.types=make(map[string]string,context.temp_allocator)
        b.control=make([dynamic]int,context.temp_allocator)
        // The surface the function returns is its output.
        if f.type=="Mirai_Surface" {for statement in f.body {surface_out_name(src,statement,&b.out_name)}}
        build_statements(&b,f.body)
    }
    return
}

@(private="file")
surface_out_name :: proc(src:^Surface_Source,index:int,name:^string) {
    s:=src.stmts[index]
    #partial switch s.kind {
    case .Return:
        if s.value>=0 && src.exprs[s.value].kind==.Name && name^=="" {name^=src.exprs[s.value].text}
    case .If,.For,.While,.Block:
        for kid in s.body {surface_out_name(src,kid,name)}
        for kid in s.other {surface_out_name(src,kid,name)}
    }
}

// The node of a line: the one whose lines are fewest among those that hold it.
surface_node_at :: proc(graph:^Surface_Graph,line:i32) -> int {
    best:=-1
    for node,i in graph.nodes {
        if node.kind==.Input || node.kind==.Parameter || node.kind==.Constant || line<node.first_line || line>node.last_line {continue}
        if best<0 || node.last_line-node.first_line<graph.nodes[best].last_line-graph.nodes[best].first_line {best=i}
    }
    return best
}
