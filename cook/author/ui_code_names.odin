package author

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The names game code and the interfaces say to each other, checked before
// the game runs: the node a step asks an interface for by a literal
// (gui.clicked(events,screen,"menu_play")) is a node of some .ui of the
// project, and the procedure a Draw node names is one the game declares with
// @(draw="name"). The events of a node carry the hash of its name, so a name
// no interface has never comes, silently.

GUI_PACKAGE :: "mirai:engine/gui"

// The procedures of engine/gui that take the name of a node, and where.
@(private="file")
Asked_Proc :: struct {name:string,node:int}
@(private="file")
ASKED_PROCS :: [?]Asked_Proc{
    {"clicked",2},{"clicked_item",2},{"changed",2},{"changed_value",2},{"changed_text",2},{"submitted",2},{"dropped",2},
    {"ui_event",2},{"finished",2},{"play_animation",2},{"focus",2},
}

// A node name a source asks an interface for by a literal.
Asked_Literal :: struct {
    name:string,
    call:string, // the procedure of gui
    file:string,
    line:int,
}

// The literals of a source of Odin that name nodes: the arguments of the
// calls of ASKED_PROCS through the name the file imports engine/gui by. A
// name built at run time is not seen. False: the source does not parse.
code_names_of :: proc(path,source:string,out:^[dynamic]Asked_Literal) -> bool {
    context.allocator=context.temp_allocator
    p:=parser.default_parser()
    p.err,p.warn=proc(pos:tokenizer.Pos,format:string,args:..any) {},proc(pos:tokenizer.Pos,format:string,args:..any) {}
    file:=ast.File{src=source,fullpath=path}
    if !parser.parse_file(&p,&file) || file.syntax_error_count>0 {return false}
    alias:=""
    for stmt in file.decls {
        decl,is_import:=stmt.derived.(^ast.Import_Decl)
        if !is_import || strings.trim(decl.fullpath,"\"`")!=GUI_PACKAGE {continue}
        alias=decl.name.text if decl.name.text!="" else "gui"
    }
    if alias=="" {return true}
    Walk :: struct {alias,path:string,out:^[dynamic]Asked_Literal}
    walk:=Walk{alias,path,out}
    visitor:=ast.Visitor{data=&walk,visit=proc(v:^ast.Visitor,node:^ast.Node) -> ^ast.Visitor {
        if node==nil {return nil}
        walk:=(^Walk)(v.data)
        call,is_call:=node.derived.(^ast.Call_Expr)
        if !is_call {return v}
        selector,is_selector:=call.expr.derived.(^ast.Selector_Expr)
        if !is_selector || selector.field==nil {return v}
        owner,is_ident:=selector.expr.derived.(^ast.Ident)
        if !is_ident || owner.name!=walk.alias {return v}
        for asked in ASKED_PROCS {
            if asked.name!=selector.field.name || asked.node>=len(call.args) {continue}
            literal,is_literal:=call.args[asked.node].derived.(^ast.Basic_Lit)
            if !is_literal || literal.tok.kind!=.String || len(literal.tok.text)<2 {continue}
            name:=literal.tok.text[1:len(literal.tok.text)-1]
            if name=="" || strings.index_byte(name,'\\')>=0 {continue}
            append(walk.out,Asked_Literal{name=strings.clone(name,context.temp_allocator),call=asked.name,file=walk.path,line=call.pos.line})
        }
        return v
    }}
    for decl in file.decls {ast.walk(&visitor,decl)}
    return true
}

// The names of the nodes of every .ui of the assets, as their events carry
// them: by hash, a node inside a widget as use/node, and written out for
// those of the files themselves.
Node_Names :: struct {
    hashes:map[u64]bool,
    plain:[dynamic]string,
}

node_names_of :: proc(a:Assets,allocator:=context.temp_allocator) -> (names:Node_Names) {
    names.hashes=make(map[u64]bool,allocator)
    names.plain=make([dynamic]string,allocator)
    if a.registry==nil {return}
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} {continue}
        records:Records
        if !records_read(a,file.id,&records,context.temp_allocator) {continue}
        for &n in records.nodes {
            if name:=serial.text_field(n.name[:]);name!="" {
                names.hashes[base.name_hash(name)]=true
                append(&names.plain,strings.clone(name,allocator))
            }
        }
        data:=records_data(&records)
        imports,imported:=tree_imports(a,data)
        if !imported {continue}
        linked,linked_ok:=ui.tree_link(data,imports)
        if !linked_ok {continue}
        tree:ui.Widget_Tree
        textures:=make([]u32,len(linked.images),context.temp_allocator)
        fonts:=make([]u8,len(linked.fonts),context.temp_allocator)
        if !ui.tree_load(&tree,linked,{textures=textures,fonts=fonts},context.temp_allocator) {continue}
        for &node in tree.nodes[:tree.node_count] {if node.name!=0 {names.hashes[node.name]=true}}
        ui.tree_destroy(&tree)
    }
    return
}

// The name of names nearest to name, when a slip of the hand tells them apart.
@(private="file")
name_nearest :: proc(names:[]string,name:string) -> string {
    distance :: proc(a,b:string) -> int {
        if abs(len(a)-len(b))>2 || len(a)>ui.TREE_NAME_CAPACITY || len(b)>ui.TREE_NAME_CAPACITY {return 3}
        row:[ui.TREE_NAME_CAPACITY+1]int
        for j in 0..=len(b) {row[j]=j}
        for i in 1..=len(a) {
            diagonal:=row[0]
            row[0]=i
            for j in 1..=len(b) {
                above:=row[j]
                row[j]=min(row[j]+1,row[j-1]+1,diagonal+int(a[i-1]!=b[j-1]))
                diagonal=above
            }
        }
        return row[len(b)]
    }
    best,found:=3,""
    for other in names {
        if d:=distance(other,name);d<best {best,found=d,other}
    }
    return found
}

// Checks the sources of Odin under folders (their tests aside) against the
// names of the interfaces of the assets: a literal no .ui has is a problem
// with the file, the line and what to write.
code_names_check :: proc(problems:^[dynamic]Bind_Problem,a:Assets,folders:[]string) {
    asked:=make([dynamic]Asked_Literal,context.temp_allocator)
    unread:=make([dynamic]string,context.temp_allocator)
    sources_walk :: proc(folder:string,asked:^[dynamic]Asked_Literal,unread:^[dynamic]string) {
        entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
        if error!=nil {return}
        slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
        for entry in entries {
            path,_:=strings.replace_all(entry.fullpath,"\\","/",context.temp_allocator)
            if entry.type==.Directory {
                if !strings.has_prefix(entry.name,".") {sources_walk(path,asked,unread)}
                continue
            }
            if !strings.has_suffix(entry.name,".odin") || strings.has_suffix(entry.name,"_test.odin") {continue}
            data,read:=os.read_entire_file(path,context.temp_allocator)
            if read!=nil || !code_names_of(path,string(data),asked) {append(unread,path)}
        }
    }
    for folder in folders {sources_walk(folder,&asked,&unread)}
    report :: proc(problems:^[dynamic]Bind_Problem,format:string,args:..any) {
        problem:=Bind_Problem{row=-1,use=-1,node=-1,fault=.Code}
        ui.tree_text_set(problem.path[:],fmt.tprintf(format,..args))
        append(problems,problem)
    }
    for path in unread {report(problems,"%s does not read as Odin, so the names it asks the interfaces for were not checked",path)}
    if len(asked)==0 {return}
    names:=node_names_of(a)
    for literal in asked {
        if names.hashes[base.name_hash(literal.name)] {continue}
        near:=name_nearest(names.plain[:],literal.name)
        hint:=fmt.tprintf("; '%s' is one",near) if near!="" else ""
        report(problems,"%s(%d): gui.%s asks for the node '%s', which no .ui of the project has, so that event never comes; name a node of the interface the screen shows%s",literal.file,literal.line,literal.call,literal.name,hint)
    }
}

// The Draw nodes of the records of a .ui whose procedure the game does not
// declare: without it the node shows nothing. How many went to out.
draw_names_check :: proc(info:^core.World_Info,r:^Records,out:[]Bind_Problem) -> (count:int) {
    if info==nil {return}
    for &n in r.nodes {
        if n.kind!=.Draw || count>=len(out) {continue}
        name:=serial.text_field(n.draw[:])
        known:=false
        for d in info.draws {known||=d.name==name}
        if known {continue}
        has:=strings.builder_make(context.temp_allocator)
        for d,i in info.draws {fmt.sbprintf(&has,"%s%s",", " if i>0 else "",d.name)}
        declared:=strings.to_string(has) if len(info.draws)>0 else "none"
        out[count]={row=-1,use=-1,node=-1,fault=.Name}
        node:=serial.text_field(n.name[:])
        if name=="" {
            ui.tree_text_set(out[count].path[:],fmt.tprintf("node '%s' is a Draw without a draw, so it shows nothing: say in draw the name of the procedure of the game that draws it; the game declares: %s",node,declared))
        } else {
            ui.tree_text_set(out[count].path[:],fmt.tprintf("node '%s' is drawn by '%s', which the game does not declare; it declares: %s. Write @(draw=\"%s\") on a proc(ctx:^ui.Context,node:ui.Draw_Node) of game/ and build",node,name,declared,name))
        }
        count+=1
    }
    return
}
