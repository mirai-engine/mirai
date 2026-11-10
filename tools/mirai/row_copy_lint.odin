package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strings"

// core.get and core.at give the value of a row, on a table received to write
// too: a local bound from one is a copy, and writing it writes no row. The
// lint reports the write of such a local that reaches nothing: one after
// which the local is never used whole.
//
// The rule, inside one procedure:
//   - A row copy is a local bound, by := or by =, from a call of core.get or
//     core.at (get and at inside package core), alone or under or_else,
//     or_return, or_continue or or_break; of the two values of get, the first.
//     A field of the call (core.at(t,row).position) is no row copy.
//   - It is written where a field or an element of it is assigned, where it
//     is assigned whole from anything but another such read, where the
//     address of a field or element of it is kept (taken anywhere but as an
//     argument of a call) and where a loop goes through one of them by
//     reference. Under `if !found`, found being the second value of its get,
//     nothing is a write: there is no row, and the copy is given a default.
//   - It is used whole where it stands by itself and not under a field or an
//     index: given to a procedure (core.set, core.add, any other), returned,
//     stored, compared, or its own address taken.
//   - A write is reported unless the local is used whole after it: later in
//     the procedure, in a defer, or anywhere in a loop that holds both and
//     began after the local was declared. Reading its fields is no such use.
CORE_IMPORT :: "mirai:core"

ROW_COPY_FIX :: "this writes a copy of the row: use core.edit to write it, or core.set to put the changed value back"

Row_Copy_Finding :: struct {line,column:int,name:string}

// Prints the writes of the sources of a package, its tests included, that
// write a copy of a row and nothing else. False when there is one or a source
// does not parse.
row_copy_lint_package :: proc(folder:string) -> bool {
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    clean:=true
    for entry in entries {
        if entry.type!=.Regular || !strings.has_suffix(entry.name,".odin") {continue}
        data,error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if error!=nil {fmt.eprintfln("mirai check: could not read %s",entry.fullpath);clean=false;continue}
        findings:=make([dynamic]Row_Copy_Finding,context.temp_allocator)
        if !row_copy_lint_source(entry.fullpath,string(data),&findings) {clean=false}
        for f in findings {
            clean=false
            fmt.eprintfln("%s(%d:%d) Error: `%s` is the value core.get or core.at read: %s.",entry.fullpath,f.line,f.column,f.name,ROW_COPY_FIX)
        }
    }
    return clean
}

@(private="file")
Copy_Event :: struct {
    write:bool,
    order:int,
    line,column:int,
    loops:[]int, // the loops around it, outermost first
}

@(private="file")
Copy_Var :: struct {
    name:string,
    copy:bool,
    found:string, // the second value of its get
    absent:int,   // the `if !found` open around what is read now
    depth:int,    // the loops around its declaration
    events:[dynamic]Copy_Event,
}

@(private="file")
Copy_Scope :: struct {names,vars:int,procedure:bool}

@(private="file")
Copy_Scan :: struct {
    core:string,   // the name the source imports core by; empty without the import
    in_core:bool,
    findings:^[dynamic]Row_Copy_Finding,
    open:[dynamic]^ast.Node,
    scopes:[dynamic]Copy_Scope,
    names:[dynamic]^Copy_Var, // those in scope, innermost last
    vars:[dynamic]^Copy_Var,  // those of the procedures open
    loops:[dynamic]int,
    loop_ids,order,deferred:int,
}

// The findings of one source. False when it does not parse: the parser has
// printed where.
row_copy_lint_source :: proc(path,text:string,findings:^[dynamic]Row_Copy_Finding) -> bool {
    context.allocator=context.temp_allocator
    file:=ast.File{src=text,fullpath=path}
    p:=parser.default_parser()
    if !parser.parse_file(&p,&file) || file.syntax_error_count>0 {return false}
    scan:=Copy_Scan{findings=findings,in_core=file.pkg_name=="core"}
    for decl in file.imports {
        if strings.trim(decl.fullpath,"\"`")!=CORE_IMPORT {continue}
        scan.core=decl.name.text!=""?decl.name.text:"core"
    }
    if scan.core=="" && !scan.in_core {return true}
    visitor:=ast.Visitor{visit=copy_visit,data=&scan}
    for decl in file.decls {ast.walk(&visitor,decl)}
    slice.stable_sort_by(findings[:],proc(a,b:Row_Copy_Finding) -> bool {return a.line<b.line || (a.line==b.line && a.column<b.column)})
    return true
}

@(private="file")
copy_visit :: proc(visitor:^ast.Visitor,node:^ast.Node) -> ^ast.Visitor {
    s:=(^Copy_Scan)(visitor.data)
    if node==nil {
        copy_close(s,pop(&s.open))
        return visitor
    }
    parent:=len(s.open)>0?s.open[len(s.open)-1]:nil
    append(&s.open,node)
    #partial switch n in node.derived {
    case ^ast.Proc_Lit:
        append(&s.scopes,Copy_Scope{len(s.names),len(s.vars),true})
    case ^ast.Block_Stmt,^ast.Switch_Stmt,^ast.Type_Switch_Stmt,^ast.Case_Clause:
        append(&s.scopes,Copy_Scope{len(s.names),len(s.vars),false})
    case ^ast.If_Stmt:
        append(&s.scopes,Copy_Scope{len(s.names),len(s.vars),false})
        if n.init!=nil {ast.walk(visitor,n.init)}
        if n.cond!=nil {ast.walk(visitor,n.cond)}
        absent:=copy_absent(s,n.cond)
        if absent!=nil {absent.absent+=1}
        if n.body!=nil {ast.walk(visitor,n.body)}
        if absent!=nil {absent.absent-=1}
        if n.else_stmt!=nil {ast.walk(visitor,n.else_stmt)}
        copy_close(s,pop(&s.open))
        return nil
    case ^ast.For_Stmt:
        append(&s.scopes,Copy_Scope{len(s.names),len(s.vars),false})
        s.loop_ids+=1
        append(&s.loops,s.loop_ids)
    case ^ast.Defer_Stmt:
        s.deferred+=1
    case ^ast.Range_Stmt:
        append(&s.scopes,Copy_Scope{len(s.names),len(s.vars),false})
        s.loop_ids+=1
        append(&s.loops,s.loop_ids)
        if n.expr!=nil {ast.walk(visitor,n.expr)}
        by_reference:=false
        for val in n.vals {
            name:=val
            if address,ok:=val.derived.(^ast.Unary_Expr);ok && address.expr!=nil {
                by_reference=true
                name=address.expr
            }
            if id,ok:=name.derived.(^ast.Ident);ok {copy_declare(s,id.name,false)}
        }
        if by_reference && n.expr!=nil {
            if root,_:=copy_root(n.expr);root!=nil {copy_event(s,copy_resolve(s,root.name),true,n.expr)}
        }
        if n.body!=nil {ast.walk(visitor,n.body)}
        copy_close(s,pop(&s.open))
        return nil
    case ^ast.Value_Decl:
        if n.type!=nil {ast.walk(visitor,n.type)}
        for value in n.values {ast.walk(visitor,value)}
        for name,i in n.names {
            id,ok:=name.derived.(^ast.Ident)
            if !ok {continue}
            v:=copy_declare(s,id.name,n.is_mutable && copy_reads(s,n.values,len(n.names),i))
            if v!=nil && v.copy && i==0 && len(n.names)==2 && len(n.values)==1 {
                if found,named:=n.names[1].derived.(^ast.Ident);named {v.found=found.name}
            }
        }
        pop(&s.open)
        return nil
    case ^ast.Assign_Stmt:
        for rhs in n.rhs {ast.walk(visitor,rhs)}
        for lhs,i in n.lhs {
            if n.op.kind==.In {
                if id,ok:=lhs.derived.(^ast.Ident);ok {copy_declare(s,id.name,false)}
                continue
            }
            root,bare:=copy_root(lhs)
            v:=root!=nil?copy_resolve(s,root.name):nil
            if v==nil {
                ast.walk(visitor,lhs)
                continue
            }
            if bare && n.op.kind==.Eq && copy_reads(s,n.rhs,len(n.lhs),i) {
                v.copy,v.found=true,""
                if i==0 && len(n.lhs)==2 && len(n.rhs)==1 {
                    if found,named:=n.lhs[1].derived.(^ast.Ident);named {v.found=found.name}
                }
                continue
            }
            // Its indices are read; the local under them is no use of it whole.
            if !bare {ast.walk(visitor,lhs)}
            copy_event(s,v,true,lhs)
        }
        pop(&s.open)
        return nil
    case ^ast.Unary_Expr:
        if n.op.kind==.And && n.expr!=nil && !copy_argument(parent) {
            if root,bare:=copy_root(n.expr);root!=nil && !bare {copy_event(s,copy_resolve(s,root.name),true,node)}
        }
    case ^ast.Ident:
        if copy_whole(parent,n) {copy_event(s,copy_resolve(s,n.name),false,node)}
    }
    return visitor
}

@(private="file")
copy_close :: proc(s:^Copy_Scan,closed:^ast.Node) {
    #partial switch _ in closed.derived {
    case ^ast.Proc_Lit:
        scope:=pop(&s.scopes)
        copy_judge(s,s.vars[scope.vars:])
        resize(&s.names,scope.names)
        resize(&s.vars,scope.vars)
    case ^ast.Block_Stmt,^ast.If_Stmt,^ast.Switch_Stmt,^ast.Type_Switch_Stmt,^ast.Case_Clause:
        resize(&s.names,pop(&s.scopes).names)
    case ^ast.For_Stmt,^ast.Range_Stmt:
        resize(&s.names,pop(&s.scopes).names)
        pop(&s.loops)
    case ^ast.Defer_Stmt:
        s.deferred-=1
    }
}

// Whether value i of a declaration or an assignment of count names is a read
// of a row: its own value, or the first of the two a lone get gives.
@(private="file")
copy_reads :: proc(s:^Copy_Scan,values:[]^ast.Expr,count,i:int) -> bool {
    if len(values)==count {return copy_read(s,values[i])}
    return i==0 && len(values)==1 && copy_read(s,values[0])
}

@(private="file")
copy_read :: proc(s:^Copy_Scan,expr:^ast.Expr) -> bool {
    at:=expr
    for at!=nil {
        #partial switch e in at.derived {
        case ^ast.Paren_Expr:     at=e.expr
        case ^ast.Or_Else_Expr:   at=e.x
        case ^ast.Or_Return_Expr: at=e.expr
        case ^ast.Or_Branch_Expr: at=e.expr
        case ^ast.Call_Expr:
            #partial switch callee in e.expr.derived {
            case ^ast.Selector_Expr:
                owner,ok:=callee.expr.derived.(^ast.Ident)
                return ok && s.core!="" && owner.name==s.core && callee.field!=nil && (callee.field.name=="get" || callee.field.name=="at")
            case ^ast.Ident:
                return s.in_core && (callee.name=="get" || callee.name=="at")
            }
            return false
        case:
            return false
        }
    }
    return false
}

// The row copy a condition says has no row: that of `!found`.
@(private="file")
copy_absent :: proc(s:^Copy_Scan,cond:^ast.Expr) -> ^Copy_Var {
    at:=cond
    for at!=nil {
        paren,wrapped:=at.derived.(^ast.Paren_Expr)
        if !wrapped {break}
        at=paren.expr
    }
    if at==nil {return nil}
    negation,negated:=at.derived.(^ast.Unary_Expr)
    if !negated || negation.op.kind!=.Not || negation.expr==nil {return nil}
    flag,named:=negation.expr.derived.(^ast.Ident)
    if !named {return nil}
    #reverse for v in s.names[copy_floor(s):] {
        if v.copy && v.found==flag.name {return v}
    }
    return nil
}

// Where the names of the procedure being read begin.
@(private="file")
copy_floor :: proc(s:^Copy_Scan) -> int {
    #reverse for scope in s.scopes {
        if scope.procedure {return scope.names}
    }
    return 0
}

// Whether what a node holds is an argument of a call.
@(private="file")
copy_argument :: proc(parent:^ast.Node) -> bool {
    if parent==nil {return false}
    #partial switch _ in parent.derived {
    case ^ast.Call_Expr,^ast.Field_Value: return true
    }
    return false
}

// The local an expression is of, and whether it is the local by itself.
@(private="file")
copy_root :: proc(expr:^ast.Expr) -> (root:^ast.Ident,bare:bool) {
    at:=expr
    bare=true
    for at!=nil {
        #partial switch e in at.derived {
        case ^ast.Ident:             return e,bare
        case ^ast.Paren_Expr:        at=e.expr
        case ^ast.Selector_Expr:     at,bare=e.expr,false
        case ^ast.Index_Expr:        at,bare=e.expr,false
        case ^ast.Slice_Expr:        at,bare=e.expr,false
        case ^ast.Matrix_Index_Expr: at,bare=e.expr,false
        case ^ast.Deref_Expr:        at,bare=e.expr,false
        case:                        return nil,false
        }
    }
    return nil,false
}

// Whether a name stands for its value whole: not the name of a field, a
// label or an argument, and not what a field or an element is taken of.
@(private="file")
copy_whole :: proc(parent:^ast.Node,id:^ast.Ident) -> bool {
    if parent==nil {return true}
    it:=rawptr(id)
    #partial switch p in parent.derived {
    case ^ast.Selector_Expr,^ast.Implicit_Selector_Expr,^ast.Branch_Stmt: return false
    case ^ast.Index_Expr:        return rawptr(p.expr)!=it
    case ^ast.Slice_Expr:        return rawptr(p.expr)!=it
    case ^ast.Matrix_Index_Expr: return rawptr(p.expr)!=it
    case ^ast.Field_Value:       return rawptr(p.field)!=it
    case ^ast.Or_Branch_Expr:    return rawptr(p.label)!=it
    case ^ast.Block_Stmt:        return rawptr(p.label)!=it
    case ^ast.If_Stmt:           return rawptr(p.label)!=it
    case ^ast.For_Stmt:          return rawptr(p.label)!=it
    case ^ast.Switch_Stmt:       return rawptr(p.label)!=it
    case ^ast.Type_Switch_Stmt:  return rawptr(p.label)!=it
    }
    return true
}

@(private="file")
copy_declare :: proc(s:^Copy_Scan,name:string,copy:bool) -> ^Copy_Var {
    if name=="_" || len(s.scopes)==0 {return nil}
    v:=new(Copy_Var)
    v^={name=name,copy=copy,depth=len(s.loops)}
    append(&s.names,v)
    append(&s.vars,v)
    return v
}

// The local a name is in the procedure being read; nil for any other name.
@(private="file")
copy_resolve :: proc(s:^Copy_Scan,name:string) -> ^Copy_Var {
    #reverse for v in s.names[copy_floor(s):] {
        if v.name==name {return v}
    }
    return nil
}

@(private="file")
copy_event :: proc(s:^Copy_Scan,v:^Copy_Var,write:bool,node:^ast.Node) {
    if v==nil || !v.copy || write && v.absent>0 {return}
    s.order+=1
    // What a defer does comes after everything else.
    order:=s.deferred>0 && !write?max(int):s.order
    append(&v.events,Copy_Event{write,order,node.pos.line,node.pos.column,slice.clone(s.loops[:])})
}

@(private="file")
copy_judge :: proc(s:^Copy_Scan,vars:[]^Copy_Var) {
    for v in vars {
        if !v.copy {continue}
        for w in v.events {
            if !w.write {continue}
            reaches:=false
            for u in v.events {
                if u.write {continue}
                if u.order>w.order || len(w.loops)>v.depth && len(u.loops)>v.depth && w.loops[v.depth]==u.loops[v.depth] {
                    reaches=true
                    break
                }
            }
            if !reaches {
                append(s.findings,Row_Copy_Finding{w.line,w.column,v.name})
                break
            }
        }
    }
}
