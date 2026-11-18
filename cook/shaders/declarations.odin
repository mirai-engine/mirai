package shaders

import "core:strings"

// The fingerprint of a stage takes of each source it includes only what the
// stage can reach, read from the text alone: a function or a type defined
// with a body and a macro are named declarations, which a stage takes when
// a name it reaches names them, and then what they name; everything else (a
// global, a resource, a directive, an operator, an extension, what a macro
// expands at the top level) every stage that includes the source takes. A
// stage takes its own source whole. So an edit to a function or a macro (a
// shared constant is one) no stage names leaves every fingerprint as it was,
// and one to a declaration recompiles only the stages that reach it. A name
// made by pasting tokens (`##`) is not followed: the engine pastes only the
// registers of its bindings.

// A top-level piece of a source.
@(private)
Declaration :: struct {
    name: string,   // "" for one every stage that includes the source takes
    hash: string,   // of its text
    names:[]string, // the identifiers it names, each once
}

// The declarations of a source, in its order. One whose value may follow the
// line it is on (__LINE__, __COUNTER__) or whose text the scan cannot follow
// (a raw string) is one unnamed declaration: every stage that includes it
// takes it whole.
@(private)
declarations_of :: proc(text:string,allocator:=context.allocator) -> []Declaration {
    found:=make([dynamic]Declaration,allocator)
    if strings.contains(text,"__LINE__") || strings.contains(text,"__COUNTER__") || strings.contains(text,"R\"") {
        append(&found,declaration_make(text,"",allocator))
        return found[:]
    }
    start,depth,i:=0,0,0
    blank:=true // nothing but spaces and comments since start
    line_start:=true
    end_item :: proc(found:^[dynamic]Declaration,text:string,start,end:int,allocator:=context.allocator) {
        item:=text[start:end]
        append(found,declaration_make(item,declaration_name(item),allocator))
    }
    for i<len(text) {
        c:=text[i]
        switch {
        case c=='\n':
            line_start=true
            i+=1
            continue
        case is_space(c):
            i+=1
            continue
        case c=='#' && line_start:
            // A directive to the end of its line and of the lines it continues.
            end:=i
            for end<len(text) && (text[end]!='\n' || end>0 && text[end-1]=='\\') {end+=1}
            if depth==0 && blank {
                directive:=text[start:end]
                append(&found,declaration_make(directive,directive_name(text[i:end]),allocator))
                start=end
            }
            i=end
            continue
        }
        line_start=false
        switch {
        case c=='/' && i+1<len(text) && text[i+1]=='/':
            for i<len(text) && text[i]!='\n' {i+=1}
            continue
        case c=='/' && i+1<len(text) && text[i+1]=='*':
            end:=strings.index(text[i+2:],"*/")
            i=len(text) if end<0 else i+2+end+2
            continue
        case c=='"' || c=='\'':
            i+=1
            for i<len(text) && text[i]!=c && text[i]!='\n' {i+=2 if text[i]=='\\' else 1}
            i+=1
            blank=false
            continue
        }
        blank=false
        switch c {
        case '{': depth+=1
        case '}':
            depth-=1
            if depth==0 {
                end:=i+1
                // struct S {...};
                after:=end
                for after<len(text) && (is_space(text[after]) || text[after]=='\n') {after+=1}
                if after<len(text) && text[after]==';' {end=after+1}
                end_item(&found,text,start,end,allocator)
                start,blank,i=end,true,end
                continue
            }
            depth=max(depth,0)
        case ';':
            if depth==0 {
                end_item(&found,text,start,i+1,allocator)
                start,blank=i+1,true
            }
        }
        i+=1
    }
    if start<len(text) && strings.trim_space(text[start:])!="" {append(&found,declaration_make(text[start:],"",allocator))}
    return found[:]
}

@(private)
declaration_make :: proc(text,name:string,allocator:=context.allocator) -> Declaration {
    names:=make([dynamic]string,allocator)
    seen:=make(map[string]bool,context.temp_allocator)
    for i:=0;i<len(text); {
        if !is_word(text[i]) || (text[i]>='0' && text[i]<='9') {
            // A number, with what follows its digits (1.0f, 0x1u), is no name.
            if text[i]>='0' && text[i]<='9' {for i<len(text) && is_word(text[i]) {i+=1}} else {i+=1}
            continue
        }
        end:=i
        for end<len(text) && is_word(text[end]) {end+=1}
        word:=text[i:end]
        if !seen[word] {
            seen[word]=true
            append(&names,strings.clone(word,allocator))
        }
        i=end
    }
    return {name=strings.clone(name,allocator),hash=sha_of(transmute([]u8)text,allocator),names=names[:]}
}

// The macro a `#define` names; "" for another directive.
@(private)
directive_name :: proc(directive:string) -> string {
    text:=skip_spaces(directive[1:])
    if !strings.has_prefix(text,"define") || len(text)<=6 || !is_space(text[6]) {return ""}
    text=skip_spaces(text[6:])
    end:=0
    for end<len(text) && is_word(text[end]) {end+=1}
    return text[:end]
}

// The name of a top-level piece with a body: of the type a struct, an
// interface, an enum or a namespace defines, or of the function it defines.
// "" for one without a body or another (an extension, an operator, an
// initializer).
@(private)
declaration_name :: proc(item:string) -> string {
    body:=declaration_code_index(item,'{')
    if body<0 {return ""}
    header:=declaration_uncommented(item[:body])
    // Attributes before it.
    for {
        header=strings.trim_left_space(header)
        if !strings.has_prefix(header,"[") {break}
        close:=declaration_close(header,'[',']')
        if close<0 {return ""}
        header=header[close+1:]
    }
    word,rest:=declaration_word(header)
    switch word {
    case "struct","interface","namespace","class":
        name,_:=declaration_word(rest)
        return name
    case "enum":
        name,after:=declaration_word(rest)
        if name=="class" {name,_=declaration_word(after)}
        return name
    case "extension","":
        return ""
    }
    call:=strings.index_byte(header,'(')
    if call<0 {return ""}
    end:=call
    for end>0 && (is_space(header[end-1]) || header[end-1]=='\n') {end-=1}
    // A generic function: foo<T>(...).
    if end>0 && header[end-1]=='>' {
        level:=0
        for end>0 {
            end-=1
            if header[end]=='>' {level+=1} else if header[end]=='<' {level-=1;if level==0 {break}}
        }
        for end>0 && (is_space(header[end-1]) || header[end-1]=='\n') {end-=1}
    }
    begin:=end
    for begin>0 && is_word(header[begin-1]) {begin-=1}
    name:=header[begin:end]
    if name=="" || name=="operator" || name=="__init" || name=="__subscript" || (name[0]>='0' && name[0]<='9') {return ""}
    return name
}

// The first identifier of text and what follows it.
@(private)
declaration_word :: proc(text:string) -> (word,rest:string) {
    text:=strings.trim_left_space(text)
    end:=0
    for end<len(text) && is_word(text[end]) {end+=1}
    return text[:end],text[end:]
}

// Where the bracket that closes the one text starts with is; -1 without one.
@(private)
declaration_close :: proc(text:string,open,close:u8) -> int {
    level:=0
    for c,i in transmute([]u8)text {
        if c==open {level+=1} else if c==close {level-=1;if level==0 {return i}}
    }
    return -1
}

// Text without its comments and strings, each a space: what the code is.
@(private)
declaration_uncommented :: proc(text:string) -> string {
    out:=make([]u8,len(text),context.temp_allocator)
    copy(out,text)
    for i:=0;i<len(out); {
        switch {
        case out[i]=='/' && i+1<len(out) && out[i+1]=='/':
            for i<len(out) && out[i]!='\n' {out[i]=' ';i+=1}
        case out[i]=='/' && i+1<len(out) && out[i+1]=='*':
            for i<len(out) && !(out[i]=='*' && i+1<len(out) && out[i+1]=='/') {out[i]=' ';i+=1}
            for _ in 0..<2 {if i<len(out) {out[i]=' ';i+=1}}
        case out[i]=='"':
            out[i]=' ';i+=1
            for i<len(out) && out[i]!='"' && out[i]!='\n' {out[i]=' ';i+=1}
            if i<len(out) {out[i]=' ';i+=1}
        case out[i]=='#' && (i==0 || out[i-1]=='\n'):
            for i<len(out) && out[i]!='\n' {out[i]=' ';i+=1}
        case: i+=1
        }
    }
    return string(out)
}

// Where the first c of the code of text is, outside comments and strings; -1 without one.
@(private)
declaration_code_index :: proc(text:string,c:u8) -> int {
    return strings.index_byte(declaration_uncommented(text),c)
}
