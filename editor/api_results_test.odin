package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// A handler answers with the result its method registers. api.call_result
// asserts it when a handler runs; this reads it from the sources, so a method
// no test calls is checked too. A handler answers through the procedures it
// gives its call to: those of its package, of the editor and of editor/api.

@(private="file")
Source_Proc :: struct {
    results:[dynamic]string, // the types it asks api.call_result for
    gives:[dynamic]string,   // the procedures it gives the call to, as it names them
}

@(private="file")
Source_Method :: struct {
    name,result:string,
    handler:string,      // the procedure it names; empty for one written in place
    in_place:Source_Proc,
}

@(private="file")
Source_Package :: struct {
    procs:map[string]Source_Proc,
    methods:[dynamic]Source_Method,
}

@(private="file")
source_ident :: proc(c:u8) -> bool {
    return c=='_' || c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9'
}

// The source with its strings, characters and comments blanked, byte for byte.
@(private="file")
source_blank :: proc(text:string) -> string {
    out:=make([]u8,len(text))
    copy(out,text)
    i:=0
    for i<len(out) {
        switch {
        case out[i]=='"' || out[i]=='\'':
            quote:=out[i]
            i+=1
            for i<len(out) && out[i]!=quote {
                if out[i]=='\\' && i+1<len(out) {out[i]=' ';i+=1}
                if out[i]!='\n' {out[i]=' '}
                i+=1
            }
            i+=1
        case out[i]=='`':
            i+=1
            for i<len(out) && out[i]!='`' {
                if out[i]!='\n' {out[i]=' '}
                i+=1
            }
            i+=1
        case out[i]=='/' && i+1<len(out) && out[i+1]=='/':
            for i<len(out) && out[i]!='\n' {out[i]=' ';i+=1}
        case: i+=1
        }
    }
    return string(out)
}

// The arguments of the call whose parenthesis opens at open, and where it closes.
@(private="file")
source_args :: proc(text:string,open:int) -> (args:[dynamic]string,close:int) {
    depth,start:=0,open+1
    for i in open..<len(text) {
        switch text[i] {
        case '(','[','{': depth+=1
        case ')',']','}':
            depth-=1
            if depth==0 {
                append(&args,text[start:i])
                return args,i
            }
        case ',':
            if depth==1 {
                append(&args,text[start:i])
                start=i+1
            }
        }
    }
    return args,len(text)
}

// What a body asks api.call_result for and the procedures it gives the call to.
@(private="file")
source_body_read :: proc(body:string,p:^Source_Proc) {
    for i in 0..<len(body) {
        if body[i]!='(' {continue}
        start:=i
        for start>0 && (source_ident(body[start-1]) || body[start-1]=='.') {start-=1}
        callee:=body[start:i]
        if callee=="" {continue}
        args,_:=source_args(body,i)
        if callee[strings.last_index_byte(callee,'.')+1:]=="call_result" && len(args)==2 {
            append(&p.results,strings.trim_space(args[1]))
            continue
        }
        for arg in args {
            if given:=strings.trim_space(arg);given=="call" || given=="&call" {
                append(&p.gives,callee)
                break
            }
        }
    }
}

// The value of key= in a blanked descriptor: up to the comma, the brace or the parenthesis that ends it.
@(private="file")
source_field :: proc(desc,key:string) -> string {
    at:=0
    for {
        found:=strings.index(desc[at:],key)
        if found<0 {return ""}
        at+=found
        if at==0 || !source_ident(desc[at-1]) {break}
        at+=len(key)
    }
    value:=desc[at+len(key):]
    end:=0
    for end<len(value) && (source_ident(value[end]) || value[end]=='.') {end+=1}
    return value[:end]
}

// The procedures and the methods a source declares, into its package.
@(private="file")
source_read :: proc(pkg:^Source_Package,raw:string) {
    text:=source_blank(raw)
    // Procedures start at the first column.
    starts:=make([dynamic]int)
    names:=make([dynamic]string)
    line:=0
    for line<len(text) {
        end:=strings.index_byte(text[line:],'\n')
        end=len(text) if end<0 else line+end
        row:=text[line:end]
        if len(row)>0 && source_ident(row[0]) {
            if at:=strings.index(row," :: ");at>0 {
                rest:=strings.trim_prefix(row[at+4:],"#force_inline ")
                if strings.has_prefix(rest,"proc") {
                    append(&starts,line)
                    append(&names,row[:at])
                }
            }
        }
        line=end+1
    }
    for start,i in starts {
        p:Source_Proc
        end:=len(text)
        if i+1<len(starts) {end=starts[i+1]}
        source_body_read(text[start:end],&p)
        pkg.procs[names[i]]=p
    }
    for i in 0..<len(text) {
        if text[i]!='(' {continue}
        start:=i
        for start>0 && source_ident(text[start-1]) {start-=1}
        if callee:=text[start:i];callee!="api_register" && callee!="api_method_register" {continue}
        args,close:=source_args(text,i)
        if len(args)==0 {continue}
        desc:=args[len(args)-1]
        if strings.contains(desc,"writes_result=true") {continue}
        method:Source_Method
        if named:=strings.index(raw[i:close],`name="`);named>=0 {
            name:=raw[i+named+len(`name="`):close]
            method.name=name[:max(strings.index_byte(name,'"'),0)]
        }
        if strings.contains(desc,"result=type_info_of(") {
            result:=desc[strings.index(desc,"result=type_info_of(")+len("result=type_info_of("):]
            method.result=strings.trim_space(result[:max(strings.index_byte(result,')'),0)])
        }
        method.handler=source_field(desc,"run=")
        if method.handler=="proc" {
            method.handler=""
            source_body_read(desc[strings.index(desc,"run=proc"):],&method.in_place)
        }
        if method.name!="" {append(&pkg.methods,method)}
    }
}

// The types a procedure answers with, through the procedures it gives its call to.
@(private="file")
source_reach :: proc(packages:^map[string]Source_Package,folder,callee:string,seen:^map[string]bool,out:^[dynamic]string) {
    target,name:=folder,callee
    if dot:=strings.last_index_byte(callee,'.');dot>=0 {
        name=callee[dot+1:]
        switch callee[:dot] {
        case "api":    target="editor/api"
        case "editor": target="editor"
        case: return
        }
    }
    pkg,known:=&packages[target]
    if !known {return}
    p,declared:=pkg.procs[name]
    if !declared {return}
    key:=strings.concatenate({target,":",name})
    if key in seen^ {return}
    seen[key]=true
    append(out,..p.results[:])
    for given in p.gives {source_reach(packages,target,given,seen,out)}
}

// Each method whose handler answers with a type other than the one it registers, or with none.
@(private="file")
source_mismatches :: proc(packages:^map[string]Source_Package) -> (problems:[dynamic]string,methods:int) {
    for folder,&pkg in packages {
        for &method in pkg.methods {
            methods+=1
            answered:=make([dynamic]string)
            seen:=make(map[string]bool)
            if method.handler!="" {
                source_reach(packages,folder,method.handler,&seen,&answered)
            } else {
                append(&answered,..method.in_place.results[:])
                for given in method.in_place.gives {source_reach(packages,folder,given,&seen,&answered)}
            }
            registered:=method.result[strings.last_index_byte(method.result,'.')+1:]
            if registered!="" && len(answered)==0 {
                append(&problems,fmt.aprintf("%s of %s registers %s and its handler asks api.call_result for nothing",method.name,folder,registered))
            }
            for type in answered {
                if type[strings.last_index_byte(type,'.')+1:]!=registered {
                    append(&problems,fmt.aprintf("%s of %s registers %s and its handler answers with %s",method.name,folder,registered==""?"no result":registered,type))
                }
            }
        }
    }
    return
}

@(test)
every_handler_answers_with_the_result_its_method_registers :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    // The reading finds a handler that answers with another type, also through a procedure it gives its call to.
    made:=make(map[string]Source_Package)
    sample:Source_Package
    source_read(&sample,"register :: proc(s:^Session) {\n"+
        "    api_register(s,st,{name=\"good.one\",summary=\"run=bad_handler, result=type_info_of(Wrong)\",result=type_info_of(Good),run=good_handler})\n"+
        "    api_register(s,st,{name=\"bad.one\",result=type_info_of(Good),run=bad_handler})\n"+
        "    api_register(s,st,{name=\"bad.none\",result=type_info_of(Good),run=proc(s:^Session,call:^api.Call) {}})\n}\n"+
        "good_handler :: proc(s:^Session,call:^api.Call) {\n    helper(s,call)\n}\n"+
        "helper :: proc(s:^Session,call:^api.Call) {\n    api.call_result(call,Good).value=1 // api.call_result(call,Comment)\n}\n"+
        "bad_handler :: proc(s:^Session,call:^api.Call) {\n    helper(s,call)\n    r:=api.call_result(call,Other)\n}\n")
    made["editor"]=sample
    wrong,sampled:=source_mismatches(&made)
    testing.expect_value(t,sampled,3)
    if testing.expect_value(t,len(wrong),2) {
        testing.expect(t,strings.contains(wrong[0],"bad.one") && strings.contains(wrong[0],"Other"),wrong[0])
        testing.expect(t,strings.contains(wrong[1],"bad.none") && strings.contains(wrong[1],"nothing"),wrong[1])
    }

    root,_:=filepath.join({#directory,".."})
    folders:=make([dynamic]string)
    append(&folders,"editor","editor/api")
    plugins,_:=filepath.join({root,"plugins"})
    entries,_:=os.read_all_directory_by_path(plugins,context.allocator)
    for entry in entries {
        if entry.type!=.Directory {continue}
        if part,_:=filepath.join({entry.fullpath,"editor"});os.is_dir(part) {append(&folders,fmt.aprintf("plugins/%s/editor",entry.name))}
    }
    packages:=make(map[string]Source_Package)
    for folder in folders {
        pkg:Source_Package
        path,_:=filepath.join({root,folder})
        files,_:=os.read_all_directory_by_path(path,context.allocator)
        for file in files {
            if file.type==.Directory || !strings.has_suffix(file.name,".odin") || strings.has_suffix(file.name,"_test.odin") {continue}
            if data,error:=os.read_entire_file(file.fullpath,context.allocator);error==nil {source_read(&pkg,string(data))}
        }
        packages[folder]=pkg
    }
    problems,methods:=source_mismatches(&packages)
    testing.expectf(t,methods>250,"%d methods found in the sources of the editor and its plugins",methods)
    for problem in problems {testing.expect(t,false,problem)}
}
