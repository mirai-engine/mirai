package build

import "core:fmt"
import "core:hash/xxhash"
import "core:odin/ast"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:project"
import "mirai:std/base"

// A binary of the engine is built from a copy of its packages, the stage,
// where every source file ends exporting its procedures under names of their
// own. Whoever links against the binary compiles, instead of those sources,
// their declarations: the same files with the types and the constants as
// they are, the procedures that must be compiled where they are called
// (generic, inline, with a deferred procedure, with an `any`) too, and the
// rest declared foreign in the binary. Nothing of the engine is compiled again with what
// uses it. A private procedure is declared and exported only when the
// declarations name it (privates_named): no other package can, so the rest of
// them stay in the binary and move no declaration when they change.
// A file is written only when its text changes: a declaration that
// comes out the same leaves the stage and the declarations as they were, and
// the libraries of the engine follow each folder by itself.
//
// With Declare_Desc.names a package also says, in DECLARED_NAMES beside its
// declarations, what each of them is and which others it names: what compiles
// against a declaration follows that one and the ones it reaches, not its
// whole package (declared.odin).

Declare_Desc :: struct {
    root:string,       // where the packages are
    packages:[]string, // relative to root and to the collection: core, engine/scene
    binary:string,     // prefix of the link names
    library:string,    // what the declarations link against: the import library, the .so, the .dylib
    stage:string,      // the copy the binary is built from
    decl:string,       // the declarations
    staged:string,     // the collection the stage is compiled as, through which its packages import each other while every other package is its declarations. "": they import each other as written
    names:bool,        // each package writes DECLARED_NAMES
}

// What the call wrote: of each folder, whether any file was written, or
// removed. The stage is what the library is compiled from; the declarations
// are what the libraries that compile against it read.
@(private)
Declare_Changed :: struct {
    stage,decl:bool,
}

@(private="file")
Declare :: struct {
    desc:Declare_Desc,
    changed:Declare_Changed,
    errors:[dynamic]string,
}

@(private="file")
Output :: struct {
    head,decl,exports:strings.Builder,
    foreign_count,export_count:int,
    names:^strings.Builder, // of the package: a line per declaration (DECLARED_NAMES); nil: not asked for
}

@(private="file")
File_Scope :: struct {
    file:^ast.File,
    src:string,
    folder:string,     // of the source file: what relative paths are relative to
    stage_folder:string, // of its copy: what the paths of its foreign imports are made relative to
    decl_folder:string,  // of its declarations: what the paths of their #load are made relative to
    link_prefix:string,
    private_file,private_package:bool,
    named:map[^ast.Value_Decl]bool, // the private procedures of its package that are declared
    desc:^Declare_Desc,
    imports:map[string]string,      // the packages of the collection of the binary it imports, by the name it gives each
    conditions:[dynamic]^ast.Expr,  // of the when blocks around what is being declared
    tags:u64,                       // the hash of the tags of the file: what it declares, it declares under them
}

// How a declaration of a source reaches the declarations.
@(private="file")
Value_Kind :: enum u8 {
    Skipped,
    Copied,  // as text
    Foreign, // a procedure the binary exports
}

// The names in the text the declarations of a package carry: those of one
// file, where what is private to a file is looked up, and those of them all.
@(private="file")
Names :: struct {
    file,all:^map[string]bool,
    imports:^map[string]string, // given: what is selected of a package the file imports counts, as `<package>.<name>`
}

// A private procedure that is declared foreign if the declarations name it.
@(private="file")
Private_Proc :: struct {
    decl:^ast.Value_Decl,
    type:^ast.Proc_Type,
    file:int,
    of_file:bool,
}

// Writes the stage and the declarations of the packages. The errors say what
// in a source keeps it from being declared. changed: which of the two folders
// a file was written to or removed from, so what compiles against it is built
// again.
declare :: proc(desc:Declare_Desc) -> (errors:[]string,changed:Declare_Changed) {
    d:Declare
    d.desc=desc
    for path in desc.packages {declare_package(&d,path)}
    return d.errors[:],d.changed
}

@(private="file")
declare_package :: proc(d:^Declare,path:string) {
    folder:=project.path(d.desc.root,path,allocator=context.temp_allocator)
    _,files,ok:=sources_read(folder,&d.errors,context.temp_allocator)
    if !ok {return}
    stage:=project.path(d.desc.stage,path,allocator=context.temp_allocator)
    decl:=project.path(d.desc.decl,path,allocator=context.temp_allocator)
    for target in ([]string{stage,decl}) {
        if os.make_directory_all(target)!=nil && !os.is_dir(target) {
            append(&d.errors,fmt.aprintf("%s: the folder could not be made",target))
            return
        }
    }
    written:=make(map[string]bool,context.temp_allocator)
    names:=strings.builder_make(context.temp_allocator)
    link_prefix:=fmt.aprintf("%s.%s",d.desc.binary,strings.join(strings.split(path,"/",context.temp_allocator),".",context.temp_allocator),allocator=context.temp_allocator)
    scopes:=make([]File_Scope,len(files),context.temp_allocator)
    for file,index in files {
        scope:=&scopes[index]
        scope^={file=file,src=file.src,folder=filepath.dir(file.fullpath),stage_folder=stage,decl_folder=decl,link_prefix=link_prefix,desc=&d.desc}
        scope.imports=make(map[string]string,context.temp_allocator)
        scope.conditions=make([dynamic]^ast.Expr,context.temp_allocator)
        for stmt in file.decls {
            imp,is_import:=stmt.derived.(^ast.Import_Decl)
            if !is_import {continue}
            path,ours:=import_package(&d.desc,imp)
            if !ours {continue}
            name:=imp.name.text!=""?imp.name.text:path[strings.last_index_byte(path,'/')+1:]
            scope.imports[name]=path
        }
        for tag in file.tags {
            text:=strings.trim_space(tag.text)
            scope.tags=base.hash_combine(scope.tags,xxhash.XXH3_64_default(transmute([]u8)text))
            if strings.has_prefix(text,"#+private") {
                if strings.contains(text,"file") {scope.private_file=true} else {scope.private_package=true}
            }
        }
    }
    named:=privates_named(scopes)
    for &scope in scopes {
        scope.named=named
        file:=scope.file
        name:=filepath.base(file.fullpath)
        written[name]=true
        out:Output
        if d.desc.names {out.names=&names}
        strings.builder_init(&out.head,context.temp_allocator)
        strings.builder_init(&out.decl,context.temp_allocator)
        strings.builder_init(&out.exports,context.temp_allocator)
        header(d,&scope,&out)
        decls_write(d,&scope,&out,file.decls[:],"")
        staged:=rewrite_paths(&scope,file.src,file.decls[:])
        // After the last line, so that the lines of the source keep their numbers.
        if out.export_count>0 {staged=strings.concatenate({staged,"\n",strings.to_string(out.exports)},context.temp_allocator)}
        write(d,project.path(stage,name,allocator=context.temp_allocator),staged,&d.changed.stage)
        if out.foreign_count>0 {fmt.sbprintfln(&out.head,"foreign import __mirai %q\n",relative(decl,d.desc.library))}
        write(d,project.path(decl,name,allocator=context.temp_allocator),strings.concatenate({strings.to_string(out.head),strings.to_string(out.decl)},context.temp_allocator),&d.changed.decl)
    }
    // What a source no longer produces does not stay in either folder.
    sweep(stage,written,&d.changed.stage)
    sweep(decl,written,&d.changed.decl)
    if d.desc.names {
        // The files come sorted, so the same declarations write the same lines.
        write(d,project.path(decl,DECLARED_NAMES,allocator=context.temp_allocator),strings.to_string(names),&d.changed.decl)
    }
}

// The package of the collection of the binary an import names; false for one of another collection.
@(private="file")
import_package :: proc(desc:^Declare_Desc,imp:^ast.Import_Decl) -> (path:string,ok:bool) {
    literal:=strings.trim(imp.relpath.text,"\"`")
    if !strings.has_prefix(literal,desc.binary) || len(literal)<=len(desc.binary)+1 || literal[len(desc.binary)]!=':' {return}
    return literal[len(desc.binary)+1:],true
}

// The line of DECLARED_NAMES of what was declared as text under names: its
// hash, with the tags of its file and the conditions of the when blocks around it, and the names it
// and they carry: one of its package bare, one of a package its file imports
// with the path of that package.
@(private="file")
names_line :: proc(scope:^File_Scope,out:^Output,names:[]string,text:string,nodes:..^ast.Node) {
    if out.names==nil {return}
    hash:=base.hash_combine(scope.tags,xxhash.XXH3_64_default(transmute([]u8)text))
    carried:=make(map[string]bool,context.temp_allocator)
    found:=Names{file=&carried,all=&carried,imports=&scope.imports}
    for condition in scope.conditions {
        hash=base.hash_combine(hash,xxhash.XXH3_64_default(transmute([]u8)node_text(scope,condition)))
        names_add(&found,condition)
    }
    for node in nodes {names_add(&found,node)}
    sorted,_:=slice.map_keys(carried,context.temp_allocator)
    slice.sort(sorted)
    for name in names {
        if name!="" && name!="_" {fmt.sbprintfln(out.names,"%s %x %s",name,hash,strings.join(sorted," ",context.temp_allocator))}
    }
}

// Removes the files of a folder of the package that this declaration did not
// write: a file taken out of the package goes, and what a source no longer
// declares does not stay declared. The folder of a package can hold the
// folders of others: only its own files are looked at. changed: a file went.
@(private="file")
sweep :: proc(folder:string,written:map[string]bool,changed:^bool) {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        if entry.type==.Directory || !strings.has_suffix(entry.name,".odin") || written[entry.name] {continue}
        if os.remove(entry.fullpath)==nil {changed^=true}
    }
}

// The tags of the file, its package clause and its imports, in the declarations.
@(private="file")
header :: proc(d:^Declare,scope:^File_Scope,out:^Output) {
    for tag in scope.file.tags {fmt.sbprintln(&out.head,strings.trim_space(tag.text))}
    fmt.sbprintfln(&out.head,"package %s\n",scope.file.pkg_name)
    for stmt in scope.file.decls {
        imp,is_import:=stmt.derived.(^ast.Import_Decl)
        if !is_import {continue}
        fmt.sbprintln(&out.head,node_text(scope,imp))
    }
    fmt.sbprintln(&out.head)
}

@(private="file")
decls_write :: proc(d:^Declare,scope:^File_Scope,out:^Output,stmts:[]^ast.Stmt,indent:string) {
    for stmt in stmts {
        #partial switch s in stmt.derived {
        case ^ast.Import_Decl, ^ast.Foreign_Import_Decl, ^ast.Package_Decl:
        case ^ast.When_Stmt:
            when_write(d,scope,out,s,indent,false)
        case ^ast.Foreign_Block_Decl:
            foreign_block_write(d,scope,out,s,indent)
        case ^ast.Value_Decl:
            value_write(d,scope,out,s,indent)
        case ^ast.Expr_Stmt:
            fmt.sbprintfln(&out.decl,"%s%s",indent,rewritten_text(scope,s))
        case:
            append(&d.errors,fmt.aprintf("%s(%d): a declaration of a kind that cannot be declared",scope.file.fullpath,stmt.pos.line))
        }
    }
}

@(private="file")
when_write :: proc(d:^Declare,scope:^File_Scope,out:^Output,s:^ast.When_Stmt,indent:string,chained:bool) {
    cond:=node_text(scope,s.cond)
    opening:=chained?fmt.tprintf(" else when %s {{\n",cond):fmt.tprintf("%swhen %s {{\n",indent,cond)
    strings.write_string(&out.decl,opening)
    strings.write_string(&out.exports,opening)
    inner:=strings.concatenate({indent,"    "},context.temp_allocator)
    // What a branch declares is what it is under its condition, and what the
    // branches after it declare, under that one too.
    append(&scope.conditions,s.cond)
    defer pop(&scope.conditions)
    if body,ok:=s.body.derived.(^ast.Block_Stmt);ok {decls_write(d,scope,out,body.stmts[:],inner)}
    strings.write_string(&out.decl,fmt.tprintf("%s}",indent))
    strings.write_string(&out.exports,fmt.tprintf("%s}",indent))
    if s.else_stmt!=nil {
        #partial switch e in s.else_stmt.derived {
        case ^ast.When_Stmt:
            when_write(d,scope,out,e,indent,true)
            return
        case ^ast.Block_Stmt:
            strings.write_string(&out.decl," else {\n")
            strings.write_string(&out.exports," else {\n")
            decls_write(d,scope,out,e.stmts[:],inner)
            strings.write_string(&out.decl,fmt.tprintf("%s}",indent))
            strings.write_string(&out.exports,fmt.tprintf("%s}",indent))
        }
    }
    strings.write_string(&out.decl,"\n")
    strings.write_string(&out.exports,"\n")
}

// Procedures of C stay in the binary; the binary exports each one under its
// own name with the calling convention of its block. An LLVM intrinsic has no
// symbol to export: its declaration is copied as it is.
@(private="file")
foreign_block_write :: proc(d:^Declare,scope:^File_Scope,out:^Output,s:^ast.Foreign_Block_Decl,indent:string) {
    convention:="c"
    private_file:=false
    for attribute in s.attributes {
        for elem in attribute.elems {
            key,value:=attribute_key(elem)
            switch key {
            case "default_calling_convention": convention=value
            case "private": private_file=value=="file"
            }
        }
    }
    body,ok:=s.body.derived.(^ast.Block_Stmt)
    if !ok {return}
    intrinsics:=0
    for stmt in body.stmts {
        decl,is_value:=stmt.derived.(^ast.Value_Decl)
        if !is_value {continue}
        kind,lit,private,_:=value_kind(scope,decl,s)
        switch kind {
        case .Skipped:
        case .Copied:
            if intrinsics==0 {
                fmt.sbprintfln(&out.decl,"%s@(default_calling_convention=%q%s)",indent,convention,private_file?",private=\"file\"":"")
                fmt.sbprintfln(&out.decl,"%sforeign _ {{",indent)
            }
            text:=decl_text(scope,decl)
            fmt.sbprintfln(&out.decl,"%s    %s",indent,text)
            names_line(scope,out,{ident_text(decl.names[0])},fmt.tprintf("%s %s",convention,text),decl)
            intrinsics+=1
        case .Foreign:
            if private && !scope.named[decl] {continue}
            proc_declare(d,scope,out,decl,lit,ident_text(decl.names[0]),convention,indent)
        }
    }
    if intrinsics>0 {fmt.sbprintfln(&out.decl,"%s}}",indent)}
}

// How a declaration reaches the declarations, and whether its package or its
// file keeps it private. block: the foreign block it is in.
@(private="file")
value_kind :: proc(scope:^File_Scope,decl:^ast.Value_Decl,block:^ast.Foreign_Block_Decl=nil) -> (kind:Value_Kind,lit:^ast.Proc_Lit,private,private_file:bool) {
    if len(decl.values)==1 {lit,_=decl.values[0].derived.(^ast.Proc_Lit)}
    private_file=scope.private_file
    private=scope.private_package || private_file
    rodata:=false
    lists:=[2][]^ast.Attribute{decl.attributes[:],block!=nil?block.attributes[:]:nil}
    for attributes in lists {
        for attribute in attributes {
            for elem in attribute.elems {
                key,value:=attribute_key(elem)
                switch key {
                case "private":
                    private=true
                    private_file||=value=="file"
                case "rodata":
                    rodata=true
                case "init","fini":
                    return
                }
            }
        }
    }
    switch {
    case block!=nil:
        // An LLVM intrinsic has no symbol to export, and the arguments of a
        // C variadic one cannot be passed on.
        switch {
        case lit==nil || len(decl.names)!=1:
        case intrinsic(decl): kind=.Copied
        case !c_vararg(lit.type): kind=.Foreign
        }
    case lit==nil:
        // Types, constants and groups of procedures are the same here; a
        // variable of the package only when the rest can see it, and a
        // read-only table always, which the inline bodies copied here read.
        if !decl.is_mutable || !private || rodata {kind=.Copied}
    // A procedure with a deferred one runs it in the scope of its caller: a
    // call through the binary would run it on leaving the export as well.
    // An `any` carries a typeid that only the type table of the module that
    // made it knows: through the binary, fmt would find no type for an enum
    // or a struct of the caller and print nothing.
    case generic(lit.type) || lit.inlining==.Inline || len(lit.where_clauses)>0 || deferred(decl) || takes_any(lit.type):
        kind=.Copied
    case:
        kind=.Foreign
    }
    return
}

// The private procedures of a package that its declarations name: the ones a
// body or a value copied into them calls or takes, the ones in the default
// values of what is declared, and the ones those name in turn. A name counts
// wherever it is written, so one that a local variable shadows declares its
// procedure too: more is declared, never less.
@(private="file")
privates_named :: proc(scopes:[]File_Scope) -> (named:map[^ast.Value_Decl]bool) {
    named=make(map[^ast.Value_Decl]bool,context.temp_allocator)
    files:=make([]map[string]bool,len(scopes),context.temp_allocator)
    all:=make(map[string]bool,context.temp_allocator)
    privates:=make([dynamic]Private_Proc,context.temp_allocator)
    for &scope,index in scopes {
        files[index]=make(map[string]bool,context.temp_allocator)
        names:=Names{file=&files[index],all=&all}
        names_collect(&scope,index,&names,&privates,scope.file.decls[:])
    }
    for found:=true;found; {
        found=false
        for private in privates {
            name:=ident_text(private.decl.names[0])
            if named[private.decl] || !(private.of_file?files[private.file][name]:all[name]) {continue}
            named[private.decl]=true
            names:=Names{file=&files[private.file],all=&all}
            names_add(&names,private.type)
            found=true
        }
    }
    return
}

// Follows decls_write: what it would copy adds its names, and what it would
// declare foreign adds those of its signature, or waits to be named if private.
@(private="file")
names_collect :: proc(scope:^File_Scope,file:int,names:^Names,privates:^[dynamic]Private_Proc,stmts:[]^ast.Stmt) {
    value :: proc(scope:^File_Scope,file:int,names:^Names,privates:^[dynamic]Private_Proc,decl:^ast.Value_Decl,block:^ast.Foreign_Block_Decl) {
        kind,lit,private,private_file:=value_kind(scope,decl,block)
        switch kind {
        case .Skipped:
        case .Copied:
            names_add(names,decl)
        case .Foreign:
            if len(decl.names)!=1 {return}
            if private {append(privates,Private_Proc{decl=decl,type=lit.type,file=file,of_file=private_file})}
            else {names_add(names,lit.type)}
        }
    }
    for stmt in stmts {
        if stmt==nil {continue}
        #partial switch s in stmt.derived {
        case ^ast.When_Stmt:
            names_add(names,s.cond)
            names_collect(scope,file,names,privates,{s.body,s.else_stmt})
        case ^ast.Block_Stmt:
            names_collect(scope,file,names,privates,s.stmts)
        case ^ast.Foreign_Block_Decl:
            body,ok:=s.body.derived.(^ast.Block_Stmt)
            if !ok {continue}
            for inner in body.stmts {
                if decl,is_value:=inner.derived.(^ast.Value_Decl);is_value {value(scope,file,names,privates,decl,s)}
            }
        case ^ast.Value_Decl:
            value(scope,file,names,privates,s,nil)
        case ^ast.Expr_Stmt:
            names_add(names,s)
        }
    }
}

@(private="file")
names_add :: proc(names:^Names,node:^ast.Node) {
    visit :: proc(v:^ast.Visitor,node:^ast.Node) -> ^ast.Visitor {
        if node==nil {return nil}
        names:=cast(^Names)v.data
        #partial switch n in node.derived {
        case ^ast.Ident:
            names.file[n.name]=true
            names.all[n.name]=true
        // What is selected is a field or a name of another package, the names
        // of a field with a type or a value are its own, and the key of an
        // attribute is no name: none is a procedure of this package.
        case ^ast.Selector_Expr:
            if of,is_name:=n.expr.derived.(^ast.Ident);is_name && names.imports!=nil && n.field!=nil {
                if path,imported:=names.imports[of.name];imported {
                    names.file[fmt.tprintf("%s.%s",path,n.field.name)]=true
                    return nil
                }
            }
            ast.walk(v,n.expr)
            return nil
        case ^ast.Implicit_Selector_Expr:
            return nil
        case ^ast.Field:
            if n.type==nil && n.default_value==nil {break}
            ast.walk(v,n.type)
            ast.walk(v,n.default_value)
            return nil
        case ^ast.Attribute:
            for elem in n.elems {
                if pair,is_pair:=elem.derived.(^ast.Field_Value);is_pair {ast.walk(v,pair.value)}
            }
            return nil
        }
        return v
    }
    v:=ast.Visitor{visit=visit,data=names}
    ast.walk(&v,node)
}

// Whether a foreign procedure is an LLVM intrinsic, by its link name.
@(private="file")
intrinsic :: proc(decl:^ast.Value_Decl) -> bool {
    for attribute in decl.attributes {
        for elem in attribute.elems {
            if key,value:=attribute_key(elem);key=="link_name" && strings.has_prefix(value,"llvm.") {return true}
        }
    }
    return false
}

@(private="file")
value_write :: proc(d:^Declare,scope:^File_Scope,out:^Output,decl:^ast.Value_Decl,indent:string) {
    kind,lit,private,private_file:=value_kind(scope,decl)
    switch kind {
    case .Skipped:
    case .Copied:
        text:=decl_text(scope,decl)
        fmt.sbprintfln(&out.decl,"%s%s",indent,text)
        if out.names!=nil {
            names:=make([dynamic]string,0,len(decl.names),context.temp_allocator)
            for name in decl.names {append(&names,ident_text(name))}
            names_line(scope,out,names[:],text,decl)
        }
    case .Foreign:
        if len(decl.names)!=1 {
            append(&d.errors,fmt.aprintf("%s(%d): one procedure per declaration",scope.file.fullpath,decl.pos.line))
            return
        }
        if private && !scope.named[decl] {return}
        // One private to its file goes under a link name of its file, which
        // may repeat its name.
        proc_declare(d,scope,out,decl,lit,ident_text(decl.names[0]),"",indent,private_file)
    }
}

// The foreign declaration of a procedure, and its export in the stage.
@(private="file")
proc_declare :: proc(d:^Declare,scope:^File_Scope,out:^Output,decl:^ast.Value_Decl,lit:^ast.Proc_Lit,name,convention:string,indent:string,private_file:=false) {
    link:=fmt.tprintf("%s.%s",scope.link_prefix,name)
    if private_file {link=fmt.tprintf("%s.%s.%s",scope.link_prefix,filepath.stem(scope.file.fullpath),name)}
    type:=lit.type
    params,_:=params_text(scope,type,false)
    renamed,arguments:=params_text(scope,type,true)
    open,close:=parens(scope.src,type.pos.offset,type.end.offset)
    if open<0 {
        append(&d.errors,fmt.aprintf("%s(%d): the parameters of %s could not be read",scope.file.fullpath,decl.pos.line,name))
        return
    }
    before:=scope.src[type.pos.offset:open+1]
    if convention!="" && type.calling_convention==nil {before=fmt.tprintf("proc %q (",convention)}
    else if _,is_default:=type.calling_convention.(ast.Proc_Calling_Convention_Extra);is_default && convention!="" {before=fmt.tprintf("proc %q (",convention)}
    after:=scope.src[close:type.end.offset]
    tags:=strings.contains(after,"#optional")?"":tags_text(lit.tags|type.tags)
    kept:=strings.builder_make(context.temp_allocator)
    for attribute in decl.attributes {
        for elem in attribute.elems {
            key,_:=attribute_key(elem)
            switch key {
            case "private","require_results","deprecated","warning","disabled":
                fmt.sbprintf(&kept,",%s",node_text(scope,elem))
            }
        }
    }
    signature:=fmt.tprintf("%s%s%s%s",before,inner_procs_odin(params),inner_procs_odin(after),tags)
    // Its parameters renamed: one could have the name of the procedure it calls.
    wrapper:=fmt.tprintf("%s%s%s%s",before,renamed,after,tags)
    declared:=fmt.tprintf("foreign __mirai {{ @(link_name=%q%s) %s :: %s --- }}",link,strings.to_string(kept),name,signature)
    fmt.sbprintfln(&out.decl,"%s@(default_calling_convention=\"odin\")",indent)
    fmt.sbprintfln(&out.decl,"%s%s",indent,declared)
    names_line(scope,out,{name},declared,type)
    out.foreign_count+=1
    call:=fmt.tprintf("%s(%s)",name,arguments)
    if type.results!=nil && !type.diverging {call=fmt.tprintf("return %s",call)}
    fmt.sbprintfln(&out.exports,"%s@(export,link_name=%q%s) __mirai_export_%s :: %s {{%s}}",indent,link,private_file?",private=\"file\"":"",name,wrapper,call)
    out.export_count+=1
}

// A procedure type among what a foreign block declares takes "cdecl" and not
// the default_calling_convention of the block (see Odin workarounds): the
// conventionless ones are the Odin ones the engine and a plugin pass each other.
@(private="file")
inner_procs_odin :: proc(text:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    rest:=text
    for {
        at:=strings.index(rest,"proc(")
        if at<0 {strings.write_string(&b,rest);return strings.to_string(b)}
        strings.write_string(&b,rest[:at])
        before:=u8(0) if at==0 else rest[at-1]
        word:=!(before=='_' || before>='0' && before<='9' || before>='a' && before<='z' || before>='A' && before<='Z')
        strings.write_string(&b,word?`proc "odin" (`:"proc(")
        rest=rest[at+len("proc("):]
    }
}

// The parentheses of the parameters of a procedure type, skipping what is
// inside strings and nested parentheses.
@(private="file")
parens :: proc(src:string,start,end:int) -> (open,close:int) {
    open,close=-1,-1
    depth:=0
    for i:=start;i<end;i+=1 {
        switch src[i] {
        case '"','\'','`':
            quote:=src[i]
            i+=1
            for i<end && src[i]!=quote {
                if src[i]=='\\' && quote!='`' {i+=1}
                i+=1
            }
        case '(':
            if depth==0 && open<0 {open=i}
            depth+=1
        case ')':
            depth-=1
            if depth==0 && open>=0 {return open,i}
        }
    }
    return -1,-1
}

// The parameters with a name each, and the arguments that pass them on.
@(private="file")
params_text :: proc(scope:^File_Scope,type:^ast.Proc_Type,rename:bool) -> (params,arguments:string) {
    p:=strings.builder_make(context.temp_allocator)
    a:=strings.builder_make(context.temp_allocator)
    generated:=0
    after_variadic:=false
    argument :: proc(a:^strings.Builder,name,original:string,variadic,after_variadic:bool) {
        if strings.builder_len(a^)>0 {strings.write_string(a,", ")}
        switch {
        case variadic:       fmt.sbprintf(a,"..%s",name)
        case after_variadic: fmt.sbprintf(a,"%s=%s",original,name)
        case:                strings.write_string(a,name)
        }
    }
    for field,i in type.params.list {
        if i>0 {strings.write_string(&p,", ")}
        prefixes:=[?]struct{flag:ast.Field_Flag,text:string}{
            {.Using,"using "},{.No_Alias,"#no_alias "},{.C_Vararg,"#c_vararg "},{.Const,"#const "},{.Any_Int,"#any_int "},
            {.Subtype,"#subtype "},{.By_Ptr,"#by_ptr "},{.No_Broadcast,"#no_broadcast "},{.No_Capture,"#no_capture "},
        }
        for prefix in prefixes {
            if prefix.flag in field.flags {strings.write_string(&p,prefix.text)}
        }
        if field.type==nil && field.default_value==nil {
            // Types without names.
            for name,j in field.names {
                if j>0 {strings.write_string(&p,", ")}
                text:=fmt.tprintf("__p%d",generated)
                generated+=1
                fmt.sbprintf(&p,"%s:%s",text,rewritten_text(scope,name))
                argument(&a,text,text,false,after_variadic)
            }
            continue
        }
        variadic:=.Ellipsis in field.flags
        type_text:=""
        if field.type!=nil {
            if _,is_ellipsis:=field.type.derived.(^ast.Ellipsis);is_ellipsis {variadic=true}
            type_text=rewritten_text(scope,field.type)
            if variadic && !strings.has_prefix(type_text,"..") {type_text=strings.concatenate({"..",type_text},context.temp_allocator)}
        }
        names:=make([dynamic]string,context.temp_allocator)
        originals:=make([dynamic]string,context.temp_allocator)
        for name in field.names {
            text:=ident_text(name)
            append(&originals,text)
            if text=="" || text=="_" || rename {
                text=fmt.tprintf("__p%d",generated)
                generated+=1
            }
            append(&names,text)
        }
        if len(names)==0 {
            append(&names,fmt.tprintf("__p%d",generated))
            append(&originals,names[0])
            generated+=1
        }
        fmt.sbprintf(&p,"%s:%s",strings.join(names[:],", ",context.temp_allocator),type_text)
        if field.default_value!=nil {fmt.sbprintf(&p,"=%s",rewritten_text(scope,field.default_value))}
        for name,j in names {argument(&a,name,originals[j],variadic,after_variadic)}
        if variadic {after_variadic=true}
    }
    return strings.to_string(p),strings.to_string(a)
}

@(private="file")
tags_text :: proc(tags:ast.Proc_Tags) -> string {
    text:=""
    if .Optional_Ok in tags {text=strings.concatenate({text," #optional_ok"},context.temp_allocator)}
    if .Optional_Allocator_Error in tags {text=strings.concatenate({text," #optional_allocator_error"},context.temp_allocator)}
    return text
}

@(private="file")
deferred :: proc(decl:^ast.Value_Decl) -> bool {
    for attribute in decl.attributes {
        for elem in attribute.elems {
            key,_:=attribute_key(elem)
            if strings.has_prefix(key,"deferred_") {return true}
        }
    }
    return false
}

// A procedure with a parameter of a type to be given: $T anywhere in a parameter.
@(private="file")
generic :: proc(type:^ast.Proc_Type) -> bool {
    if type.generic {return true}
    if type.params==nil {return false}
    found:=false
    visit :: proc(v:^ast.Visitor,node:^ast.Node) -> ^ast.Visitor {
        if node==nil {return nil}
        found:=cast(^bool)v.data
        #partial switch n in node.derived {
        case ^ast.Poly_Type: found^=true
        case ^ast.Typeid_Type:
            if n.specialization!=nil {found^=true}
        }
        return found^?nil:v
    }
    v:=ast.Visitor{visit=visit,data=&found}
    for field in type.params.list {
        for name in field.names {ast.walk(&v,name)}
        if field.type!=nil {ast.walk(&v,field.type)}
        if found {return true}
    }
    return false
}

// A procedure with an `any` in its parameters or its results, alone or
// inside another type (..any, []any).
@(private="file")
takes_any :: proc(type:^ast.Proc_Type) -> bool {
    found:=false
    visit :: proc(v:^ast.Visitor,node:^ast.Node) -> ^ast.Visitor {
        if node==nil {return nil}
        found:=cast(^bool)v.data
        if id,ok:=node.derived.(^ast.Ident);ok && id.name=="any" {found^=true}
        return found^?nil:v
    }
    v:=ast.Visitor{visit=visit,data=&found}
    for fields in ([]^ast.Field_List{type.params,type.results}) {
        if fields==nil {continue}
        for field in fields.list {
            if field.type!=nil {ast.walk(&v,field.type)}
            if found {return true}
        }
    }
    return false
}

@(private="file")
c_vararg :: proc(type:^ast.Proc_Type) -> bool {
    if type.params==nil {return false}
    for field in type.params.list {
        if .C_Vararg in field.flags {return true}
    }
    return false
}

@(private="file")
attribute_key :: proc(elem:^ast.Expr) -> (key,value:string) {
    #partial switch e in elem.derived {
    case ^ast.Ident:
        return e.name,""
    case ^ast.Field_Value:
        if k,ok:=e.field.derived.(^ast.Ident);ok {key=k.name}
        if v,ok:=e.value.derived.(^ast.Basic_Lit);ok {value=strings.trim(v.tok.text,"\"")}
        if v,ok:=e.value.derived.(^ast.Ident);ok {value=v.name}
    }
    return
}

@(private="file")
ident_text :: proc(e:^ast.Expr) -> string {
    if id,ok:=e.derived.(^ast.Ident);ok {return id.name}
    return ""
}

@(private="file")
node_text :: proc(scope:^File_Scope,node:^ast.Node) -> string {
    return scope.src[node.pos.offset:node.end.offset]
}

// A declaration with its attributes, as written, with relative paths made
// relative to the folder of the declarations.
@(private="file")
decl_text :: proc(scope:^File_Scope,decl:^ast.Value_Decl) -> string {
    start:=decl.pos.offset
    if len(decl.attributes)>0 {start=min(start,decl.attributes[0].pos.offset)}
    return rewrite_range(scope,start,decl.end.offset)
}

@(private="file")
rewritten_text :: proc(scope:^File_Scope,node:^ast.Node) -> string {
    // The parser leaves no end on a typeid without specialization.
    if t,is_typeid:=node.derived.(^ast.Typeid_Type);is_typeid && t.specialization==nil {return "typeid"}
    return rewrite_range(scope,node.pos.offset,node.end.offset)
}

// The text between two offsets with the paths of #load and its kin made
// relative to the folder of the declarations: the shared cache of the engine
// copies them into other checkouts.
@(private="file")
rewrite_range :: proc(scope:^File_Scope,start,end:int) -> string {
    text:=scope.src[start:end]
    b:=strings.builder_make(context.temp_allocator)
    rest:=text
    for {
        at:=directive_path(rest)
        if at.start<0 {break}
        strings.write_string(&b,rest[:at.start])
        strings.write_string(&b,declared_path(scope,rest[at.start:at.end]))
        rest=rest[at.end:]
    }
    strings.write_string(&b,rest)
    return strings.to_string(b)
}

// The copy of a source for the stage: the same lines, with the paths of
// #load and of foreign imports absolute.
@(private="file")
rewrite_paths :: proc(scope:^File_Scope,src:string,decls:[]^ast.Stmt) -> string {
    edits:=make([dynamic][3]int,context.temp_allocator) // start, end, index of replacement
    replacements:=make([dynamic]string,context.temp_allocator)
    collect_foreign :: proc(stmts:[]^ast.Stmt,edits:^[dynamic][3]int,replacements:^[dynamic]string,scope:^File_Scope) {
        for stmt in stmts {
            #partial switch s in stmt.derived {
            case ^ast.Import_Decl:
                // A package of the same binary is compiled with this one, from the stage.
                path,ours:=import_package(scope.desc,s)
                if !ours || scope.desc.staged=="" || !slice.contains(scope.desc.packages,path) {continue}
                append(edits,[3]int{s.relpath.pos.offset,s.relpath.pos.offset+len(s.relpath.text),len(replacements)})
                append(replacements,fmt.tprintf("%q",fmt.tprintf("%s:%s",scope.desc.staged,path)))
            case ^ast.Foreign_Import_Decl:
                for path in s.fullpaths {
                    lit,ok:=path.derived.(^ast.Basic_Lit)
                    if !ok {continue}
                    value:=strings.trim(lit.tok.text,"\"`")
                    if strings.contains(value,":") || filepath.is_abs(value) {continue}
                    append(edits,[3]int{lit.pos.offset,lit.end.offset,len(replacements)})
                    joined,_:=filepath.join({scope.folder,value},context.temp_allocator)
                    append(replacements,fmt.tprintf("%q",relative(scope.stage_folder,joined)))
                }
            case ^ast.When_Stmt:
                if body,ok:=s.body.derived.(^ast.Block_Stmt);ok {collect_foreign(body.stmts[:],edits,replacements,scope)}
                if s.else_stmt!=nil {
                    #partial switch e in s.else_stmt.derived {
                    case ^ast.Block_Stmt: collect_foreign(e.stmts[:],edits,replacements,scope)
                    case ^ast.When_Stmt: collect_foreign({e},edits,replacements,scope)
                    }
                }
            }
        }
    }
    collect_foreign(decls,&edits,&replacements,scope)
    rest:=0
    for {
        at:=directive_path(src[rest:])
        if at.start<0 {break}
        append(&edits,[3]int{rest+at.start,rest+at.end,len(replacements)})
        append(&replacements,absolute_path(scope,src[rest+at.start:rest+at.end]))
        rest+=at.end
    }
    if len(edits)==0 {return src}
    slice.sort_by(edits[:],proc(a,b:[3]int) -> bool {return a[0]<b[0]})
    b:=strings.builder_make(context.temp_allocator)
    at:=0
    for edit in edits {
        strings.write_string(&b,src[at:edit[0]])
        strings.write_string(&b,replacements[edit[2]])
        at=edit[1]
    }
    strings.write_string(&b,src[at:])
    return strings.to_string(b)
}

// The string literal right after the next #load, #load_hash or #load_directory.
@(private)
directive_path :: proc(text:string) -> (at:struct{start,end:int}) {
    at={-1,-1}
    search:=0
    for {
        found:=strings.index(text[search:],"#load")
        if found<0 {return}
        open:=strings.index_byte(text[search+found:],'(')
        if open<0 {return}
        quote:=search+found+open+1
        for quote<len(text) && (text[quote]==' ' || text[quote]=='\t') {quote+=1}
        if quote<len(text) && text[quote]=='"' {
            close:=strings.index_byte(text[quote+1:],'"')
            if close<0 {return}
            return {quote,quote+1+close+1}
        }
        search=quote
    }
}

@(private="file")
absolute_path :: proc(scope:^File_Scope,literal:string) -> string {
    value:=literal[1:len(literal)-1]
    if strings.contains(value,":") || filepath.is_abs(value) {return literal}
    joined,_:=filepath.join({scope.folder,value},context.temp_allocator)
    return fmt.tprintf("%q",slashes(joined,context.temp_allocator))
}

@(private="file")
declared_path :: proc(scope:^File_Scope,literal:string) -> string {
    value:=literal[1:len(literal)-1]
    if strings.contains(value,":") || filepath.is_abs(value) {return literal}
    joined,_:=filepath.join({scope.folder,value},context.temp_allocator)
    return fmt.tprintf("%q",relative(scope.decl_folder,joined))
}

// A path as seen from a folder, with forward slashes: foreign imports take no absolute ones.
@(private="file")
relative :: proc(folder,target:string) -> string {
    rel,error:=filepath.rel(folder,target,context.temp_allocator)
    if error!=nil {return slashes(target,context.temp_allocator)}
    return slashes(rel,context.temp_allocator)
}

@(private="file")
write :: proc(d:^Declare,path,text:string,changed:^bool) {
    written,error:=write_changed(path,text)
    if error!=nil {append(&d.errors,fmt.aprintf("%s: could not be written",path));return}
    if written {changed^=true}
}
