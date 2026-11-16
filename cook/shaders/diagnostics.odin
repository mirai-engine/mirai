package shaders

import "core:fmt"
import "core:strconv"
import "core:strings"

// What the compilers and the check say of a source, one entry per problem:
// where it is, what it is and, when it is known, how to fix it. A generation
// and a check give them; the editor and `mirai shaders` show them.

Severity :: enum u8 {Error,Warning,Info}
SEVERITY_NAMES :: [Severity]string{.Error="error",.Warning="warning",.Info="info"}

Diagnostic :: struct {
    severity:Severity,
    code:string,     // Slang's (E30015) or a rule of the check (mirai.ray_derivatives)
    file:string,     // relative to the project or the engine, with forward slashes; or as the compiler named it
    line,column:int, // from 1; zero for what is not at a place
    end_line,end_column:int,
    stage:string,    // the compilation that said it: raster, ray, or both; empty for the rules of the check
    node:string,     // the node of the graph of the program at that line, for a program
    message,fix:string,
}

// The diagnostics a run of slangc wrote with -enable-machine-readable-diagnostics:
// a line per diagnostic, code, severity, file, line, column, end line, end
// column and message separated by tabs, and span lines with the detail of the
// one before. Lines of another shape are kept as messages without a place.
SLANG_DIAGNOSTICS_FLAG :: "-enable-machine-readable-diagnostics"

slang_diagnostics :: proc(output:string,allocator:=context.allocator) -> []Diagnostic {
    out:=make([dynamic]Diagnostic,allocator)
    detailed:=false
    rest:=output
    for raw in strings.split_lines_iterator(&rest) {
        line:=strings.trim_right(raw,"\r")
        if strings.trim_space(line)=="" {continue}
        fields:=strings.split(line,"\t",context.temp_allocator)
        if len(fields)<8 {
            append(&out,Diagnostic{severity=.Error,message=strings.clone(strings.trim_space(line),allocator)})
            detailed=false
            continue
        }
        message:=strings.join(fields[7:],"\t",context.temp_allocator)
        if fields[1]=="span" || fields[1]=="note" {
            if len(out)==0 || detailed {continue}
            last:=&out[len(out)-1]
            if strings.has_prefix(message,last.message) {
                last.message=strings.clone(message,allocator)
            } else if message!="" && message!=last.message {
                last.message=fmt.aprintf("%s: %s",last.message,message,allocator=allocator)
            }
            detailed=true
            continue
        }
        d:=Diagnostic{code=strings.clone(fields[0],allocator),file=strings.clone(fields[2],allocator),message=strings.clone(message,allocator)}
        switch fields[1] {
        case "error","fatal": d.severity=.Error
        case "warning":       d.severity=.Warning
        case:                 d.severity=.Info
        }
        d.line,_=strconv.parse_int(fields[3])
        d.column,_=strconv.parse_int(fields[4])
        d.end_line,_=strconv.parse_int(fields[5])
        d.end_column,_=strconv.parse_int(fields[6])
        append(&out,d)
        detailed=false
    }
    return out[:]
}

// A diagnostic as a line of text: file(line:column): severity code: message.
diagnostic_text :: proc(d:Diagnostic,allocator:=context.allocator) -> string {
    names:=SEVERITY_NAMES
    b:=strings.builder_make(allocator)
    if d.file!="" {
        strings.write_string(&b,d.file)
        if d.line>0 {fmt.sbprintf(&b,"(%d:%d)",d.line,max(d.column,1))}
        strings.write_string(&b,": ")
    }
    strings.write_string(&b,names[d.severity])
    if d.code!="" {fmt.sbprintf(&b," %s",d.code)}
    fmt.sbprintf(&b,": %s",d.message)
    if d.fix!="" {fmt.sbprintf(&b,"\n  fix: %s",d.fix)}
    return strings.to_string(b)
}

diagnostics_text :: proc(list:[]Diagnostic,allocator:=context.allocator) -> string {
    b:=strings.builder_make(allocator)
    for d,i in list {
        if i>0 {strings.write_byte(&b,'\n')}
        strings.write_string(&b,diagnostic_text(d,context.temp_allocator))
    }
    return strings.to_string(b)
}

diagnostics_clone :: proc(list:[]Diagnostic,allocator:=context.allocator) -> []Diagnostic {
    out:=make([]Diagnostic,len(list),allocator)
    for d,i in list {
        out[i]=d
        out[i].code=strings.clone(d.code,allocator)
        out[i].file=strings.clone(d.file,allocator)
        out[i].stage=strings.clone(d.stage,allocator)
        out[i].node=strings.clone(d.node,allocator)
        out[i].message=strings.clone(d.message,allocator)
        out[i].fix=strings.clone(d.fix,allocator)
    }
    return out
}

diagnostics_destroy :: proc(list:[]Diagnostic,allocator:=context.allocator) {
    for d in list {
        delete(d.code,allocator);delete(d.file,allocator);delete(d.stage,allocator)
        delete(d.node,allocator);delete(d.message,allocator);delete(d.fix,allocator)
    }
    delete(list,allocator)
}

// Names the files of diagnostics as the sources they come from: a copy staged
// for a compilation (path) by the folder it copies (label), and then relative
// to the first of roots (the project, the engine) that holds it.
@(private)
diagnostics_place :: proc(list:[]Diagnostic,copies:[]Base,roots:[]string,allocator:=context.allocator) {
    for &d in list {
        if d.file=="" {continue}
        path:=path_clean(d.file,context.temp_allocator)
        for copy in copies {
            if relative,inside:=path_relative(path,copy.path);inside {path=path_join(copy.label,relative,allocator=context.temp_allocator);break}
        }
        for root in roots {
            if root=="" {continue}
            if relative,inside:=path_relative(path,root);inside {path=relative;break}
        }
        d.file=strings.clone(path,allocator)
    }
}
