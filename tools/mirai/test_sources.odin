package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:project"

// A test the sources of a package declare. here: its file builds for this
// system. device: it reaches the device of the GPU tests (device_mark), told
// only when asked.
Test_Declared :: struct {name,file:string,here,device:bool}

// The tests the sources of a folder declare, by file in the order of their
// names; only those of files when some are given.
test_declared :: proc(folder:string,files:[]string={},device:=false,allocator:=context.allocator) -> [dynamic]Test_Declared {
    declared:=make([dynamic]Test_Declared,allocator)
    declarations:=make([dynamic]Declaration,context.temp_allocator)
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    for entry in entries {
        if entry.type!=.Regular || !strings.has_suffix(entry.name,".odin") {continue}
        listed:=len(files)==0 || test_file_among(files,entry.name)
        if !listed && !device {continue}
        data,error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if error!=nil {continue}
        here:=source_for_system(entry.name,string(data))
        if device && here && strings.has_suffix(entry.name,"_test.odin") {declarations_add(&declarations,code_only(string(data)))}
        if !listed {continue}
        for name in test_procedures(string(data),context.temp_allocator) {
            append(&declared,Test_Declared{name=strings.clone(name,allocator),file=strings.clone(entry.name,allocator),here=here})
        }
    }
    if device {device_mark(declared[:],declarations[:])}
    return declared
}

// Whether a file of a package is one of those asked, as the system tells names apart.
test_file_among :: proc(files:[]string,name:string) -> bool {
    for file in files {
        if project.path_same(file,name) {return true}
    }
    return false
}

// The procedures of an Odin source with the attribute test: @(test), @test or
// a list of attributes with test, on the line of the procedure or above it.
test_procedures :: proc(text:string,allocator:=context.allocator) -> [dynamic]string {
    names:=make([dynamic]string,allocator)
    marked:=false
    rest:=code_only(text)
    for line in strings.split_lines_iterator(&rest) {
        code,test:=attributes_skip(strings.trim_space(line))
        marked||=test
        if !marked || code=="" || strings.has_prefix(code,"//") {continue}
        marked=false
        name,_,declaration:=strings.partition(code,"::")
        name=strings.trim_space(name)
        if name!="" && strings.has_prefix(strings.trim_space(declaration),"proc") && identifier(name) {append(&names,strings.clone(name,allocator))}
    }
    return names
}

// A line of code without the attributes it begins with. test: one of them is test.
@(private="file")
attributes_skip :: proc(line:string) -> (code:string,test:bool) {
    code=line
    for strings.has_prefix(code,"@") {
        attributes:string
        if strings.has_prefix(code,"@(") {
            close:=strings.index_byte(code,')')
            if close<0 {break}
            attributes,code=code[2:close],code[close+1:]
        } else {
            end:=1
            for end<len(code) && identifier_byte(code[end]) {end+=1}
            attributes,code=code[1:end],code[end:]
        }
        for attribute in strings.split_iterator(&attributes,",") {
            if strings.trim_space(attribute)=="test" {test=true}
        }
        code=strings.trim_space(code)
    }
    return
}

// What a source names to reach the device of the GPU tests: the package of
// the one they share, and the procedure of rhi that makes one.
DEVICE_PACKAGE :: "shared_device"
DEVICE_CREATE :: "device_create"

// A declaration at the top of a source and its code, from the attributes
// above its name to the next declaration.
@(private="file")
Declaration :: struct {name,code:string}

// Adds the declarations at the top of a source, and those of the when blocks
// there. code: the source with its comments and literals blanked.
@(private="file")
declarations_add :: proc(declarations:^[dynamic]Declaration,code:string) {
    // whens: the when blocks at the top that are open; a declaration is at their depth.
    depth,whens:=0,0
    name:=""
    start:=-1
    at:=0
    for at<len(code) {
        end:=strings.index_byte(code[at:],'\n')
        end=len(code) if end<0 else at+end+1
        line:=strings.trim_space(code[at:end])
        opens:=false
        if depth==whens {
            declared:=""
            if rest,_:=attributes_skip(line);rest!="" {
                size:=0
                for size<len(rest) && identifier_byte(rest[size]) {size+=1}
                if identifier(rest[:size]) && strings.has_prefix(strings.trim_space(rest[size:]),":") {declared=rest[:size]}
            }
            switch {
            case strings.has_prefix(line,"when "):
                opens=true
            case whens>0 && strings.has_prefix(line,"}"):
                whens-=1
                opens=strings.has_suffix(line,"{")
            case declared!="" || strings.has_prefix(line,"@"):
                if name!="" {
                    append(declarations,Declaration{name,code[start:at]})
                    name,start="",-1
                }
                if start<0 {start=at}
                name=declared
            }
        }
        for c in transmute([]u8)line {
            switch c {
            case '{','(','[': depth+=1
            case '}',')',']': depth-=1
            }
        }
        if opens && depth==whens+1 {whens+=1}
        at=end
    }
    if name!="" {append(declarations,Declaration{name,code[start:]})}
}

// Marks the tests that reach the device of the GPU tests: those whose
// declaration names DEVICE_PACKAGE or DEVICE_CREATE, or a declaration of the
// test files of their folder that does. What is no test file does not count:
// a program makes a device or not by what it is asked at run time, and a test
// that asks it for one holds the shared one. Told from the text, like the
// tests themselves: a name stands for every declaration with it, and a member
// of something else (x.name) names none.
@(private="file")
device_mark :: proc(declared:[]Test_Declared,declarations:[]Declaration) {
    reaching:=make(map[string]bool,context.temp_allocator)
    reaching[DEVICE_PACKAGE]=true
    reaching[DEVICE_CREATE]=true
    for grew:=true;grew; {
        grew=false
        for declaration in declarations {
            if declaration.name in reaching || !code_names(declaration.code,reaching) {continue}
            reaching[declaration.name]=true
            grew=true
        }
    }
    for &test in declared {test.device=test.name in reaching}
}

// Whether code names one of names, or the procedure of rhi that makes a device.
@(private="file")
code_names :: proc(code:string,names:map[string]bool) -> bool {
    i:=0
    for i<len(code) {
        if !identifier_byte(code[i]) {i+=1;continue}
        start:=i
        for i<len(code) && identifier_byte(code[i]) {i+=1}
        token:=code[start:i]
        if start>0 && code[start-1]=='.' {
            if token==DEVICE_CREATE && strings.has_suffix(code[:start],"rhi.") {return true}
            continue
        }
        if token in names {return true}
    }
    return false
}

// An Odin source with what is inside its comments and literals blanked and
// its lines kept: what is left is code.
@(private="file")
code_only :: proc(text:string) -> string {
    code:=transmute([]u8)strings.clone(text,context.temp_allocator)
    blank :: proc(c:^u8) {if c^!='\n' {c^=' '}}
    i:=0
    for i<len(code) {
        next:=code[i+1] if i+1<len(code) else 0
        switch {
        case code[i]=='/' && next=='/':
            for i<len(code) && code[i]!='\n' {blank(&code[i]);i+=1}
        case code[i]=='/' && next=='*':
            // Block comments nest.
            depth:=0
            for i<len(code) {
                pair:=string(code[i:min(i+2,len(code))])
                if pair=="/*" || pair=="*/" {
                    depth+=1 if pair=="/*" else -1
                    blank(&code[i]);blank(&code[i+1])
                    i+=2
                    if depth==0 {break}
                    continue
                }
                blank(&code[i])
                i+=1
            }
        case code[i]=='"' || code[i]=='\'' || code[i]=='`':
            quote:=code[i]
            i+=1
            // A raw string goes on across lines; another literal ends with its line.
            for i<len(code) && code[i]!=quote && (quote=='`' || code[i]!='\n') {
                if quote!='`' && code[i]=='\\' && i+1<len(code) && code[i+1]!='\n' {blank(&code[i]);i+=1}
                blank(&code[i])
                i+=1
            }
            i+=1
        case:
            i+=1
        }
    }
    return string(code)
}

@(private="file")
identifier_byte :: proc(c:u8) -> bool {
    return c=='_' || (c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9')
}

@(private="file")
identifier :: proc(text:string) -> bool {
    if text=="" || (text[0]>='0' && text[0]<='9') {return false}
    for i in 0..<len(text) {
        if !identifier_byte(text[i]) {return false}
    }
    return true
}

// Whether an Odin source builds for system, by the end of its name
// (x_windows.odin, x_linux_test.odin) and by its #+build lines. Only the
// system is looked at, not the architecture.
source_for_system :: proc(name,text:string,system:=ODIN_OS) -> bool {
    stem:=strings.trim_suffix(strings.trim_suffix(name,".odin"),"_test")
    if cut:=strings.last_index_byte(stem,'_');cut>=0 {
        if named,known:=system_named(stem[cut+1:]);known && named!=system {return false}
    }
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        trimmed:=strings.trim_space(line)
        if strings.has_prefix(trimmed,"package ") {break}
        if !strings.has_prefix(trimmed,"#+build ") {continue}
        // Alternatives apart by commas; within one, every term holds.
        any:=false
        alternatives:=trimmed[len("#+build "):]
        for alternative in strings.split_iterator(&alternatives,",") {
            all:=true
            terms:=alternative
            for term in strings.fields_iterator(&terms) {
                negated:=strings.has_prefix(term,"!")
                if named,known:=system_named(term[1:] if negated else term);known && (named==system)==negated {all=false}
            }
            any||=all
        }
        if !any {return false}
    }
    return true
}

// The system an Odin build tag names.
@(private="file")
system_named :: proc(tag:string) -> (system:runtime.Odin_OS_Type,known:bool) {
    for candidate in runtime.Odin_OS_Type {
        if candidate!=.Unknown && strings.equal_fold(fmt.tprint(candidate),tag) {return candidate,true}
    }
    return
}

// The name of a test without its package (pkg.name).
test_bare :: proc(name:string) -> string {
    return name[strings.last_index_byte(name,'.')+1:]
}

// The tests of names most like asked, at most five: first those that share
// more of its words, then those nearer in letters.
test_similar :: proc(asked:string,names:[]string,allocator:=context.allocator) -> []string {
    Candidate :: struct {name:string,shared,distance:int}
    candidates:=make([dynamic]Candidate,context.temp_allocator)
    words:=strings.split(asked,"_",context.temp_allocator)
    for name in names {
        shared:=0
        own:=strings.split(name,"_",context.temp_allocator)
        for word in words {
            if len(word)>3 && slice.contains(own,word) {shared+=1}
        }
        distance:=strings.levenshtein_distance(asked,name,context.temp_allocator)
        if shared>0 || distance<=max(2,len(asked)/4) || strings.contains(name,asked) {append(&candidates,Candidate{name,shared,distance})}
    }
    slice.sort_by(candidates[:],proc(a,b:Candidate) -> bool {return a.shared>b.shared || (a.shared==b.shared && a.distance<b.distance)})
    similar:=make([dynamic]string,allocator)
    for candidate in candidates[:min(len(candidates),5)] {append(&similar,candidate.name)}
    return similar[:]
}
