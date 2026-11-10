package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:cook/build"
import "mirai:project"

Alloc_Finding :: struct {line,column:int,call:string}

// Whether mirai check runs the lint on folder: a package a game binary
// contains, of the engine at root. Those are its runtime packages, the runtime
// part of its plugins and the game of its demo and of its templates.
alloc_lint_applies :: proc(root,folder:string) -> bool {
    inside:=project.path_absolute(folder,context.temp_allocator)
    engine:=strings.trim_right(project.path_absolute(root,context.temp_allocator),"/")
    if !path_inside(inside,engine) || len(inside)<=len(engine) {return false}
    relative:=inside[len(engine)+1:]
    packages:=build.ENGINE_RUNTIME_PACKAGES
    for name in packages {
        if !strings.has_prefix(name,"third_party/") && path_same(relative,name) {return true}
    }
    parts:=strings.split(relative,"/",context.temp_allocator)
    if len(parts)>=3 && parts[0]=="plugins" && parts[2]=="runtime" {return true}
    return len(parts)>=2 && parts[len(parts)-1]=="game" && (parts[0]=="demo" || parts[0]=="templates")
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
    if adds,_:=append_call(name);adds {
        return fmt.tprintf("Without memory it adds nothing, and here the element is read as if it had: it is indexed afterwards, or the code runs under #no_bounds_check. Receive it: `if _,err:=%s(&x,v);err!=nil {{return .Out_Of_Memory}}`, or take the room first with a checked `reserve(&x,len(x)+N)`, N being a number that covers the appends after it, none of them in a loop the reserve is outside of.",name)
    }
    if library_call(name)==.No_Error {
        return fmt.tprintf("%s has no error to give: write the text with fmt.tprintf, or with fmt.bprintf in a buffer, and copy it with strings.clone, receiving its error.",name)
    }
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

// What a library procedure that copies gives back, by its package and name.
// Copy: the copy and the allocator error. No_Error: the copy alone, so the
// error is dropped whoever receives the result.
@(private="file")
Library_Call :: enum {None,Copy,No_Error}

@(private="file")
library_call :: proc(name:string) -> Library_Call {
    switch name {
    case "strings.clone","strings.clone_to_cstring","strings.clone_from","strings.clone_from_bytes","strings.clone_from_cstring","strings.clone_from_cstring_bounded","strings.clone_from_ptr",
         "strings.concatenate","strings.join","strings.repeat","strings.split","strings.split_n","strings.split_after","strings.split_lines","strings.fields","strings.fields_proc",
         "strings.to_lower","strings.to_upper","slice.clone","slice.clone_to_dynamic","slice.concatenate","slice.repeat",
         "bytes.clone_safe","bytes.join_safe","bytes.concatenate_safe","filepath.join":
        return .Copy
    case "fmt.aprint","fmt.aprintln","fmt.aprintf","fmt.aprintfln","fmt.caprint","fmt.caprintf","fmt.caprintfln",
         "bytes.clone","bytes.join","bytes.concatenate","bytes.repeat","strings.replace","strings.replace_all","strings.remove","strings.remove_all":
        return .No_Error
    }
    return .None
}

// What grows a dynamic array by its length, by its name. counted: it adds one
// element per argument; the others add what the lint cannot count.
@(private="file")
append_call :: proc(name:string) -> (adds,counted:bool) {
    switch name {
    case "append","append_elem","append_elems","non_zero_append","non_zero_append_elem","non_zero_append_elems":
        return true,true
    case "append_string","append_elem_string","non_zero_append_elem_string","append_nothing",
         "inject_at","inject_at_elem","inject_at_elems","inject_at_elem_string","assign_at","assign_at_elem","assign_at_elems","assign_at_elem_string":
        return true,false
    }
    return false,false
}

// What a procedure does to a dynamic array, in the order of its source.
@(private="file")
Array_Event :: struct {
    kind:enum {Append,Room,Name,Index},
    array:string,        // as array_name writes it; Name: "" when the name takes something else
    offset:int,
    call:^ast.Call_Expr, // Append: the call; Name: the append whose result the name takes
    dropped:bool,        // Append: nothing receives its error
    unchecked:bool,      // Append: under #no_bounds_check
    count:int,           // Append: the elements it adds, -1 when the lint cannot count them; Room: those it leaves room for past the length
    block:[2]int,        // Append, Room: the block it is in
    loop:[2]int,         // Append: its innermost loop, {0,0} outside one
    name:string,         // Name: what holds len(array) or the result of the append; Index: what indexes
    last:bool,           // Index: at len(array)-1
}

// What a procedure literal declares that decides about its allocations.
@(private="file")
Alloc_Scope :: struct {
    results:int,
    allocators:[dynamic]string, // names that hold an allocator
    temporary:[dynamic]string,  // names that hold context.temp_allocator, and the dynamic arrays made with it
    events:[dynamic]Array_Event,
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
    slice.stable_sort_by(findings[:],proc(a,b:Alloc_Finding) -> bool {return a.line<b.line || (a.line==b.line && a.column<b.column)})
    return true
}

@(private="file")
alloc_visit :: proc(visitor:^ast.Visitor,node:^ast.Node) -> ^ast.Visitor {
    s:=(^Alloc_Scan)(visitor.data)
    if node==nil {
        closed:=pop(&s.open)
        if _,is_proc:=closed.derived.(^ast.Proc_Lit);is_proc {
            scope:=pop(&s.scopes)
            append_judge(s,scope.events[:])
        }
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
        names_note(s,n.names,n.values)
    case ^ast.Assign_Stmt:
        names_note(s,n.lhs,n.rhs if n.op.kind==.Eq else nil)
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
    case ^ast.Binary_Expr:
        // The count an append returns tells as much as its error.
        #partial switch n.op.kind {
        case .Cmp_Eq,.Not_Eq,.Lt,.Gt,.Lt_Eq,.Gt_Eq:
            for side in ([2]^ast.Expr{n.left,n.right}) {
                call:=alloc_unwrap(side)
                if call==nil {continue}
                if callee,named:=call.expr.derived.(^ast.Ident);named {
                    if adds,_:=append_call(callee.name);adds {s.received[rawptr(call)]=true}
                }
            }
        }
    case ^ast.Range_Stmt:
        names_note(s,n.vals,nil)
    case ^ast.Index_Expr:
        index_note(s,n)
    case ^ast.Call_Expr:
        alloc_check(s,n)
        array_note(s,n)
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
    if _,allocator,_:=make_request(s,call);allocator!=nil && allocator_temporary(s,allocator) {append(&scope.temporary,id.name)}
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
make_request :: proc(s:^Alloc_Scan,call:^ast.Call_Expr) -> (sized:bool,allocator:^ast.Expr,counts:[2]^ast.Expr) {
    slice_type:=false
    if len(call.args)>0 {
        #partial switch type in call.args[0].derived {
        case ^ast.Array_Type,^ast.Multi_Pointer_Type: slice_type=true
        }
    }
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

// A copy of a library is dropped like a make; its allocator is whichever
// argument is one, and in a formatter only the named one, the others being
// what it writes.
@(private="file")
library_dropped :: proc(s:^Alloc_Scan,call:^ast.Call_Expr) -> bool {
    selector,ok:=call.expr.derived.(^ast.Selector_Expr)
    if !ok {return false}
    name:=alloc_text(s,selector)
    kind:=library_call(name)
    if kind==.None || (kind==.Copy && s.received[rawptr(call)]) {return false}
    formatter:=strings.has_prefix(name,"fmt.")
    for arg in call.args {
        if pair,is_pair:=arg.derived.(^ast.Field_Value);is_pair {
            if field,is_name:=pair.field.derived.(^ast.Ident);is_name && field.name=="allocator" && allocator_temporary(s,pair.value) {return false}
        } else if !formatter && allocator_temporary(s,arg) {
            return false
        }
    }
    return true
}

@(private="file")
alloc_check :: proc(s:^Alloc_Scan,call:^ast.Call_Expr) {
    callee,named:=call.expr.derived.(^ast.Ident)
    kind:=alloc_call(callee.name) if named else .None
    if kind==.None {
        if !library_dropped(s,call) {return}
    } else if kind==.One_Result {
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
            sized,allocator,_=make_request(s,call)
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
    alloc_flag(s,call)
}

@(private="file")
alloc_flag :: proc(s:^Alloc_Scan,call:^ast.Call_Expr) {
    text,_:=strings.replace_all(alloc_text(s,call),"\n"," ",context.temp_allocator)
    text=strings.join(strings.fields(text,context.temp_allocator)," ",s.findings.allocator)
    append(s.findings,Alloc_Finding{line=call.pos.line,column=call.pos.column,call=text})
}

// An expression without its parentheses and its conversions to an integer;
// that of an array, without the & and the ^ around it.
@(private="file")
bare :: proc(expr:^ast.Expr,array:=false) -> ^ast.Expr {
    at:=expr
    for at!=nil {
        inner:^ast.Expr
        #partial switch e in at.derived {
        case ^ast.Paren_Expr: inner=e.expr
        case ^ast.Unary_Expr: if array && e.op.kind==.And {inner=e.expr}
        case ^ast.Deref_Expr: if array {inner=e.expr}
        case ^ast.Call_Expr:
            if id,named:=e.expr.derived.(^ast.Ident);!array && named && len(e.args)==1 {
                switch id.name {
                case "int","uint","i8","u8","i16","u16","i32","u32","i64","u64","uintptr": inner=e.args[0]
                }
            }
        }
        if inner==nil {break}
        at=inner
    }
    return at
}

@(private="file")
array_name :: proc(s:^Alloc_Scan,expr:^ast.Expr) -> string {
    at:=bare(expr,true)
    if at==nil {return ""}
    return strings.join(strings.fields(alloc_text(s,at)),"")
}

// The array whose length an expression is; "" when it is something else.
@(private="file")
length_of :: proc(s:^Alloc_Scan,expr:^ast.Expr) -> string {
    at:=bare(expr)
    if at==nil {return ""}
    call,is_call:=at.derived.(^ast.Call_Expr)
    if !is_call || len(call.args)!=1 {return ""}
    if id,named:=call.expr.derived.(^ast.Ident);!named || id.name!="len" {return ""}
    return array_name(s,call.args[0])
}

@(private="file")
literal_count :: proc(expr:^ast.Expr) -> int {
    at:=bare(expr)
    if at==nil {return -1}
    literal,ok:=at.derived.(^ast.Basic_Lit)
    if !ok || literal.tok.kind!=.Integer {return -1}
    value,parsed:=strconv.parse_int(literal.tok.text)
    return value if parsed && value>=0 else -1
}

// The innermost node of a kind the visit is inside of, within its procedure.
@(private="file")
enclosing :: proc(s:^Alloc_Scan,loop:bool) -> [2]int {
    #reverse for node in s.open[:len(s.open)-1] {
        #partial switch _ in node.derived {
        case ^ast.For_Stmt,^ast.Range_Stmt,^ast.Unroll_Range_Stmt: if loop {return {node.pos.offset,node.end.offset}}
        case ^ast.Block_Stmt: if !loop {return {node.pos.offset,node.end.offset}}
        case ^ast.Proc_Lit: return {}
        }
    }
    return {}
}

@(private="file")
names_note :: proc(s:^Alloc_Scan,names,values:[]^ast.Expr) {
    if len(s.scopes)==0 {return}
    events:=&s.scopes[len(s.scopes)-1].events
    for name,i in names {
        id,ok:=name.derived.(^ast.Ident)
        if !ok {continue}
        event:=Array_Event{kind=.Name,name=id.name,offset=name.pos.offset}
        if len(values)==len(names) {
            event.array=length_of(s,values[i])
            if call:=alloc_unwrap(values[i]);event.array=="" && call!=nil && len(call.args)>0 {
                if callee,named:=call.expr.derived.(^ast.Ident);named {
                    if adds,_:=append_call(callee.name);adds {event.call=call;event.array=array_name(s,call.args[0])}
                }
            }
        }
        append(events,event)
    }
}

@(private="file")
index_note :: proc(s:^Alloc_Scan,index:^ast.Index_Expr) {
    if len(s.scopes)==0 || index.index==nil {return}
    event:=Array_Event{kind=.Index,array=array_name(s,index.expr),offset=index.pos.offset}
    #partial switch e in bare(index.index).derived {
    case ^ast.Ident: event.name=e.name
    case ^ast.Binary_Expr: event.last=e.op.kind==.Sub && literal_count(e.right)==1 && length_of(s,e.left)==event.array
    }
    if event.last || event.name!="" {append(&s.scopes[len(s.scopes)-1].events,event)}
}

// The appends of a call, and the room a checked reserve of len(array)+N or a
// checked make of length 0 and capacity N takes for them.
@(private="file")
array_note :: proc(s:^Alloc_Scan,call:^ast.Call_Expr) {
    callee,named:=call.expr.derived.(^ast.Ident)
    if !named || len(s.scopes)==0 || len(call.args)==0 {return}
    events:=&s.scopes[len(s.scopes)-1].events
    event:=Array_Event{array=array_name(s,call.args[0]),offset=call.pos.offset,call=call,count=-1,block=enclosing(s,false)}
    if adds,counted:=append_call(callee.name);adds {
        // An array the procedure made with the temporary allocator grows in it.
        if id,is_name:=bare(call.args[0],true).derived.(^ast.Ident);is_name && alloc_known(s,id.name,true) {return}
        event.kind=.Append
        event.dropped=!s.received[rawptr(call)]
        event.loop=enclosing(s,true)
        if counted && call.ellipsis.kind!=.Ellipsis {
            event.count=0
            for arg in call.args[1:] {
                #partial switch a in arg.derived {
                case ^ast.Field_Value: continue
                case ^ast.Ellipsis: event.count=-1
                case ^ast.Basic_Lit: if a.tok.kind==.String {event.count=-1}
                }
                if event.count<0 {break}
                event.count+=1
            }
        }
        #reverse for node in s.open[:len(s.open)-1] {
            literal,is_proc:=node.derived.(^ast.Proc_Lit)
            if .No_Bounds_Check in node.state_flags || (is_proc && .No_Bounds_Check in literal.tags) {event.unchecked=true}
            if is_proc || node.state_flags&{.Bounds_Check,.No_Bounds_Check}!={} {break}
        }
        append(events,event)
        return
    }
    kind:=alloc_call(callee.name)
    if kind==.One_Result && strings.contains(callee.name,"reserve") && len(call.args)>=2 && !s.alone[rawptr(call)] {
        if sum,is_sum:=bare(call.args[1]).derived.(^ast.Binary_Expr);is_sum && sum.op.kind==.Add {
            if length_of(s,sum.left)==event.array {event.count=literal_count(sum.right)}
            else if length_of(s,sum.right)==event.array {event.count=literal_count(sum.left)}
        }
    } else if kind==.Make && s.received[rawptr(call)] {
        // The array is the first name the make is given to.
        event.array=""
        #reverse for node in s.open[:len(s.open)-1] {
            #partial switch n in node.derived {
            case ^ast.Paren_Expr,^ast.Or_Return_Expr: continue
            case ^ast.Value_Decl: if len(n.values)==1 {event.array=array_name(s,n.names[0])}
            case ^ast.Assign_Stmt: if len(n.rhs)==1 {event.array=array_name(s,n.lhs[0])}
            }
            break
        }
        if _,_,counts:=make_request(s,call);counts[0]!=nil && counts[1]!=nil && literal_zero(counts[0]) {event.count=literal_count(counts[1])}
    }
    if event.count<0 || event.array=="" {return}
    event.kind=.Room
    append(events,event)
}

// Flags the dropped appends of a procedure that are dangerous: one under
// #no_bounds_check, and one whose element is indexed afterwards, at
// len(array)-1, by a name that took len(array) before it, or by the name that
// took its result. A room that covers it spares it.
@(private="file")
append_judge :: proc(s:^Alloc_Scan,events:[]Array_Event) {
    for e,at in events {
        if e.kind!=.Append || !e.dropped || !(e.unchecked || append_indexed(events,at)) || append_covered(events,at) {continue}
        alloc_flag(s,e.call)
    }
}

@(private="file")
append_indexed :: proc(events:[]Array_Event,at:int) -> bool {
    e:=events[at]
    for index,i in events[at+1:] {
        if index.kind!=.Index || index.array!=e.array {continue}
        #reverse for before,j in events[:at+1+i] {
            if index.last {
                // The last element is that of the append before the index, and of
                // those before it up to one whose block the index is in.
                if before.kind!=.Append || before.array!=e.array {continue}
                if j==at {return true}
                if j<at || (before.block[0]<=index.offset && index.offset<before.block[1]) {break}
            } else if before.kind==.Name && before.name==index.name {
                if before.array==e.array && (before.call==e.call if before.call!=nil else j<at) {return true}
                break
            }
        }
    }
    return false
}

// Whether the last room taken for the array before the append, in a block the
// append is in, holds every element appended since: each append a number of
// them, none in a loop the room is outside of.
@(private="file")
append_covered :: proc(events:[]Array_Event,at:int) -> bool {
    e:=events[at]
    #reverse for room,i in events[:at] {
        if room.kind!=.Room || room.array!=e.array || e.offset<room.block[0] || e.offset>=room.block[1] {continue}
        total:=0
        for added in events[i+1:at+1] {
            if added.kind!=.Append || added.array!=e.array {continue}
            looped:=added.loop[1]>0 && (room.offset<added.loop[0] || room.offset>=added.loop[1])
            if added.count<0 || looped {return false}
            total+=added.count
        }
        return total<=room.count
    }
    return false
}
