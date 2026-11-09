package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:project"

// The runtime packages that already receive every allocation error, while
// the rest are cleaned: mirai check runs the lint on these only. When every
// runtime package is here the list goes away and alloc_lint_applies answers
// by what a game binary contains.
ALLOC_LINT_PACKAGES :: [?]string{}

Alloc_Finding :: struct {line,column:int,call:string}

// Whether mirai check runs the lint on folder, a package of the engine at root.
alloc_lint_applies :: proc(root,folder:string) -> bool {
    inside:=project.path_absolute(folder,context.temp_allocator)
    engine:=strings.trim_right(project.path_absolute(root,context.temp_allocator),"/")
    if !path_inside(inside,engine) {return false}
    packages:=ALLOC_LINT_PACKAGES
    for name in packages {
        if path_same(inside[len(engine)+1:],name) {return true}
    }
    return false
}

// Prints the allocations of the sources of a package, its tests aside, whose
// allocator error nothing receives. False when there is one or a source does
// not parse.
alloc_lint_package :: proc(folder:string) -> bool {
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    clean:=true
    for entry in entries {
        if entry.type!=.Regular || !strings.has_suffix(entry.name,".odin") || strings.has_suffix(entry.name,"_test.odin") {continue}
        data,error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if error!=nil {fmt.eprintfln("mirai check: could not read %s",entry.fullpath);clean=false;continue}
        findings:=make([dynamic]Alloc_Finding,context.temp_allocator)
        if !alloc_lint_source(entry.fullpath,string(data),&findings) {clean=false}
        for f in findings {
            clean=false
            fmt.eprintfln("%s(%d:%d) Error: the allocator error of `%s` is dropped. %s",entry.fullpath,f.line,f.column,f.call,alloc_fix(f.call))
        }
    }
    return clean
}

@(private="file")
alloc_fix :: proc(call:string) -> string {
    name:=call[:max(strings.index_byte(call,'('),0)]
    if alloc_call(name)==.One_Result {
        return fmt.tprintf("Receive it and return the memory error of the package: `if %s(&x,n)!=nil {{return .Out_Of_Memory}}`; to only shorten the array, base.truncate.",name)
    }
    return fmt.tprintf("Receive it, release what was already taken and return the memory error of the package: `x,err:=%s(...)`.",name)
}

// What a call that allocates asks for, by its name. One_Result: the error is
// its only result, so a call drops it when it stands alone as a statement or
// is assigned to _.
@(private="file")
Alloc_Call :: enum {None,Make,New,Sized,One_Result}

@(private="file")
alloc_call :: proc(name:string) -> Alloc_Call {
    switch name {
    case "make": return .Make
    case "new","new_clone","new_aligned": return .New
    case "make_slice","make_multi_pointer","make_dynamic_array_len","make_dynamic_array_len_cap","make_map_cap","make_soa","make_soa_slice","make_soa_dynamic_array_len","make_soa_dynamic_array_len_cap": return .Sized
    case "resize","reserve","non_zero_resize","non_zero_reserve","resize_soa","reserve_soa","non_zero_resize_soa","non_zero_reserve_soa": return .One_Result
    }
    return .None
}

// What a procedure literal declares that decides about its allocations.
@(private="file")
Alloc_Scope :: struct {
    results:int,
    allocators:[dynamic]string, // names that hold an allocator
    temporary:[dynamic]string,  // names that hold context.temp_allocator, and the dynamic arrays made with it
}

@(private="file")
Alloc_Scan :: struct {
    text:string,
    findings:^[dynamic]Alloc_Finding,
    received:map[rawptr]bool, // calls whose error has a receiver
    alone:map[rawptr]bool,    // calls that are a whole statement
    open:[dynamic]^ast.Node,
    scopes:[dynamic]Alloc_Scope,
}

// The findings of one source. False when it does not parse: the parser has
// printed where.
alloc_lint_source :: proc(path,text:string,findings:^[dynamic]Alloc_Finding) -> bool {
    context.allocator=context.temp_allocator
    file:=ast.File{src=text,fullpath=path}
    p:=parser.default_parser()
    if !parser.parse_file(&p,&file) || file.syntax_error_count>0 {return false}
    scan:=Alloc_Scan{text=text,findings=findings}
    visitor:=ast.Visitor{visit=alloc_visit,data=&scan}
    for decl in file.decls {ast.walk(&visitor,decl)}
    return true
}

@(private="file")
alloc_visit :: proc(visitor:^ast.Visitor,node:^ast.Node) -> ^ast.Visitor {
    s:=(^Alloc_Scan)(visitor.data)
    if node==nil {
        closed:=pop(&s.open)
        if _,is_proc:=closed.derived.(^ast.Proc_Lit);is_proc {pop(&s.scopes)}
        return visitor
    }
    append(&s.open,node)
    #partial switch n in node.derived {
    case ^ast.Proc_Lit:
        scope:Alloc_Scope
        if n.type!=nil && n.type.results!=nil {
            for field in n.type.results.list {scope.results+=max(1,len(field.names))}
        }
        if n.type!=nil && n.type.params!=nil {
            for field in n.type.params.list {
                typed:=field.type!=nil && strings.has_suffix(alloc_text(s,field.type),"Allocator")
                if !typed && (field.default_value==nil || !allocator_expression(s,field.default_value)) {continue}
                for name in field.names {
                    if id,ok:=name.derived.(^ast.Ident);ok {append(&scope.allocators,id.name)}
                }
            }
        }
        append(&s.scopes,scope)
    case ^ast.Value_Decl:
        if len(n.values)==1 && len(n.names)==2 {alloc_receive(s,n.values[0],n.names[1])}
        if len(s.scopes)>0 && len(n.values)==len(n.names) {
            for value,i in n.values {alloc_declare(s,n.names[i],value)}
        } else if len(s.scopes)>0 && len(n.values)==1 && len(n.names)==2 {
            alloc_declare(s,n.names[0],n.values[0])
        }
    case ^ast.Assign_Stmt:
        if len(n.rhs)==1 && len(n.lhs)==2 {alloc_receive(s,n.rhs[0],n.lhs[1])}
        if len(n.rhs)==1 && len(n.lhs)==1 && alloc_blank(n.lhs[0]) {
            if call:=alloc_unwrap(n.rhs[0]);call!=nil {s.alone[rawptr(call)]=true}
        }
    case ^ast.Or_Return_Expr:
        alloc_receive(s,n.expr,nil)
    case ^ast.Or_Branch_Expr:
        alloc_receive(s,n.expr,nil)
    case ^ast.Return_Stmt:
        if len(n.results)==1 && len(s.scopes)>0 && s.scopes[len(s.scopes)-1].results>=2 {alloc_receive(s,n.results[0],nil)}
    case ^ast.Expr_Stmt:
        if call:=alloc_unwrap(n.expr);call!=nil {s.alone[rawptr(call)]=true}
    case ^ast.Call_Expr:
        alloc_check(s,n)
    }
    return visitor
}

@(private="file")
alloc_text :: proc(s:^Alloc_Scan,node:^ast.Node) -> string {
    return s.text[node.pos.offset:node.end.offset]
}

// The call an expression is, parentheses aside; nil when it is something else.
@(private="file")
alloc_unwrap :: proc(expr:^ast.Expr) -> ^ast.Call_Expr {
    at:=expr
    for at!=nil {
        paren,wrapped:=at.derived.(^ast.Paren_Expr)
        if !wrapped {break}
        at=paren.expr
    }
    if at==nil {return nil}
    call,_:=at.derived.(^ast.Call_Expr)
    return call
}

// A second name takes the error unless it is _, which drops it as no name does.
@(private="file")
alloc_receive :: proc(s:^Alloc_Scan,value,receiver:^ast.Expr) {
    call:=alloc_unwrap(value)
    if call==nil {return}
    if receiver!=nil && alloc_blank(receiver) {return}
    s.received[rawptr(call)]=true
}

@(private="file")
alloc_blank :: proc(expr:^ast.Expr) -> bool {
    id,ok:=expr.derived.(^ast.Ident)
    return ok && id.name=="_"
}

@(private="file")
alloc_declare :: proc(s:^Alloc_Scan,name,value:^ast.Expr) {
    id,ok:=name.derived.(^ast.Ident)
    if !ok {return}
    scope:=&s.scopes[len(s.scopes)-1]
    if allocator_expression(s,value) {
        append(&scope.allocators,id.name)
        if allocator_temporary(s,value) {append(&scope.temporary,id.name)}
        return
    }
    call:=alloc_unwrap(value)
    if call==nil {return}
    callee,named:=call.expr.derived.(^ast.Ident)
    if !named || alloc_call(callee.name)!=.Make {return}
    if _,allocator:=make_request(s,call);allocator!=nil && allocator_temporary(s,allocator) {append(&scope.temporary,id.name)}
}

@(private="file")
alloc_known :: proc(s:^Alloc_Scan,name:string,temporary:bool) -> bool {
    if len(s.scopes)==0 {return false}
    scope:=s.scopes[len(s.scopes)-1]
    return slice.contains(scope.temporary[:] if temporary else scope.allocators[:],name)
}

// Whether an expression names an allocator and not a count: the two share a
// position in make([dynamic]T,x). An allocator is context.allocator, a name
// its procedure declares as one, a name with "alloc" in it, or a call to a
// procedure named as returning one.
@(private="file")
allocator_expression :: proc(s:^Alloc_Scan,expr:^ast.Expr) -> bool {
    #partial switch e in expr.derived {
    case ^ast.Paren_Expr: return allocator_expression(s,e.expr)
    case ^ast.Ident: return strings.contains(e.name,"alloc") || alloc_known(s,e.name,false)
    case ^ast.Selector_Expr: return e.field!=nil && strings.contains(e.field.name,"alloc")
    case ^ast.Call_Expr:
        #partial switch callee in e.expr.derived {
        case ^ast.Ident: return strings.has_suffix(callee.name,"allocator")
        case ^ast.Selector_Expr: return callee.field!=nil && strings.has_suffix(callee.field.name,"allocator")
        }
    }
    return false
}

// context.temp_allocator, or a name the procedure gave it.
@(private="file")
allocator_temporary :: proc(s:^Alloc_Scan,expr:^ast.Expr) -> bool {
    #partial switch e in expr.derived {
    case ^ast.Paren_Expr: return allocator_temporary(s,e.expr)
    case ^ast.Ident: return alloc_known(s,e.name,true)
    case ^ast.Selector_Expr:
        owner,ok:=e.expr.derived.(^ast.Implicit)
        return ok && owner.tok.kind==.Context && e.field!=nil && e.field.name=="temp_allocator"
    }
    return false
}

@(private="file")
literal_zero :: proc(expr:^ast.Expr) -> bool {
    literal,ok:=expr.derived.(^ast.Basic_Lit)
    return ok && literal.tok.text=="0"
}

// Whether a make asks for memory, and the allocator it names (nil: the one of
// the context). make(T), make(T,allocator) and a length and capacity of 0 ask
// for none.
@(private="file")
make_request :: proc(s:^Alloc_Scan,call:^ast.Call_Expr) -> (sized:bool,allocator:^ast.Expr) {
    slice_type:=false
    if len(call.args)>0 {
        #partial switch type in call.args[0].derived {
        case ^ast.Array_Type,^ast.Multi_Pointer_Type: slice_type=true
        }
    }
    counts:[2]^ast.Expr
    positional:=0
    for arg,i in call.args {
        if i==0 {continue}
        if pair,named:=arg.derived.(^ast.Field_Value);named {
            if field,ok:=pair.field.derived.(^ast.Ident);ok {
                switch field.name {
                case "allocator": allocator=pair.value
                case "len": counts[0]=pair.value
                case "cap","capacity": counts[1]=pair.value
                }
            }
            continue
        }
        if positional<2 {counts[positional]=arg} else if positional==2 {allocator=arg}
        positional+=1
    }
    // A slice has a length and then its allocator. In the others the last of
    // one or two arguments is the allocator when it reads as one:
    // make([dynamic]T,allocator), make([dynamic]T,n,allocator).
    if allocator==nil && positional>0 && positional<=2 {
        last:=counts[positional-1]
        if (slice_type && positional==2) || (!slice_type && allocator_expression(s,last)) {allocator=last;counts[positional-1]=nil}
    }
    for count in counts {
        if count!=nil && !literal_zero(count) {sized=true}
    }
    return
}

@(private="file")
alloc_check :: proc(s:^Alloc_Scan,call:^ast.Call_Expr) {
    callee,named:=call.expr.derived.(^ast.Ident)
    if !named {return}
    kind:=alloc_call(callee.name)
    if kind==.None {return}
    if kind==.One_Result {
        if !s.alone[rawptr(call)] {return}
        // An array the procedure made with the temporary allocator grows in it.
        if len(call.args)>0 {
            if address,ok:=call.args[0].derived.(^ast.Unary_Expr);ok {
                if id,is_name:=address.expr.derived.(^ast.Ident);is_name && alloc_known(s,id.name,true) {return}
            }
        }
    } else {
        if s.received[rawptr(call)] {return}
        allocator:^ast.Expr
        if kind==.Make {
            sized:bool
            sized,allocator=make_request(s,call)
            if !sized {return}
        } else {
            // new(T,allocator), new_clone(value,allocator), new_aligned(T,alignment,allocator);
            // the others end with it.
            place:=2 if callee.name=="new_aligned" else 1 if kind==.New else len(call.args)-1
            for arg,i in call.args {
                if pair,is_pair:=arg.derived.(^ast.Field_Value);is_pair {
                    if field,ok:=pair.field.derived.(^ast.Ident);ok && field.name=="allocator" {allocator=pair.value}
                } else if i==place && (kind==.New || allocator_expression(s,arg)) {
                    allocator=arg
                }
            }
        }
        if allocator!=nil && allocator_temporary(s,allocator) {return}
    }
    text,_:=strings.replace_all(alloc_text(s,call),"\n"," ",context.temp_allocator)
    text=strings.join(strings.fields(text,context.temp_allocator)," ",s.findings.allocator)
    append(s.findings,Alloc_Finding{line=call.pos.line,column=call.pos.column,call=text})
}
