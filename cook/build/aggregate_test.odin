package build

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/subprocess"

// A multiple assignment of a value of more than 64 bytes leaves in the IR a
// store of the whole aggregate, which LLVM optimizes for seconds or minutes
// (odin-lang/Odin#7937). The IR of -o:minimal of the libraries of the engine,
// staged as engine_build stages them, of the editor library of the demo,
// with its generated world, and of the library of each plugin it activates
// has none.
@(test)
no_store_of_an_aggregate_of_more_than_64_bytes :: proc(t:^testing.T) {
    // The parser of declare keeps its trees in the allocator of the context.
    context.allocator=context.temp_allocator
    root:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    compiler,found:=compiler_find(root,context.temp_allocator)
    if !testing.expect(t,found,"no Odin compiler") {return}
    folder,folder_error:=os.make_directory_temp("","mirai-aggregates-*",context.temp_allocator)
    if !testing.expect(t,folder_error==nil) {return}
    folder=slashes(project.path_absolute(folder,context.temp_allocator),context.temp_allocator)
    defer os.remove_all(folder)
    flags:=engine_flags(root,true)
    ir :: proc(t:^testing.T,root,compiler,package_folder,out:string,flags:[]string,collections:..string) -> bool {
        command:=make([dynamic]string,context.temp_allocator)
        append(&command,compiler,"build",package_folder,"-build-mode:llvm-ir",fmt.tprintf("-out:%s",out))
        append(&command,..collections)
        for flag in flags {
            if flag!="-debug" {append(&command,flag)}
        }
        _=os.make_directory_all(out)
        memory,_:=compiler_memory()
        state,_,errors,error:=subprocess.exec({command=command[:],env=child_environment(root,context.temp_allocator)},context.temp_allocator,{memory=memory})
        return testing.expectf(t,error==nil && state.exit_code==0,"%s does not compile to IR:\n%s",package_folder,string(errors))
    }

    stage_runtime,stage_editor,decl:=project.path(folder,"stage-runtime"),project.path(folder,"stage-editor"),project.path(folder,"decl")
    runtime_packages,editor_packages:=ENGINE_RUNTIME_PACKAGES,ENGINE_EDITOR_PACKAGES
    errors,_:=declare({root=root,packages=runtime_packages[:],binary="mirai",library=project.path(folder,"runtime.lib"),stage=stage_runtime,decl=decl})
    if !testing.expectf(t,len(errors)==0,"%v",errors) {return}
    entry_write(stage_runtime,"__mirai_runtime",entry_imports("mirai",runtime_packages[:])[:])
    if !ir(t,root,compiler,project.path(stage_runtime,"__mirai_runtime"),project.path(folder,"ir/runtime"),flags[:],fmt.tprintf("-collection:mirai=%s",stage_runtime)) {return}
    if !testing.expect(t,os.copy_directory_all(stage_editor,decl)==nil) {return}
    errors,_=declare({root=root,packages=editor_packages[:],binary="mirai",library=project.path(folder,"editor.lib"),stage=stage_editor,decl=decl})
    if !testing.expectf(t,len(errors)==0,"%v",errors) {return}
    entry_write(stage_editor,"__mirai_editor",entry_imports("mirai",editor_packages[:])[:])
    if !ir(t,root,compiler,project.path(stage_editor,"__mirai_editor"),project.path(folder,"ir/editor"),flags[:],fmt.tprintf("-collection:mirai=%s",stage_editor)) {return}

    p,open_error:=project.open(project.path(root,"demo"),root)
    defer project.close(&p)
    if !testing.expect_value(t,open_error.code,project.Error_Code.None) {return}
    generated,written:=generated_write(&p,.Editor)
    if !testing.expectf(t,written,"the demo generates no world: %v",generated.errors) {return}
    for &lib in plugin_libraries(&p,.Editor,true,context.temp_allocator) {
        lib.stage=project.path(folder,"plugins",lib.stage[strings.last_index_byte(lib.stage,'/')+1:])
        // A name for the import library its stage links: IR links nothing.
        plugin_library_name(p.root,&lib,0,context.temp_allocator)
        failed:=plugin_library_prepare(&p,&lib)
        if !testing.expectf(t,len(failed)==0,"%v",failed) {return}
        if !ir(t,root,compiler,project.path(lib.stage,PLUGIN_ENTRY),project.path(folder,"ir",lib.family),flags[:],fmt.tprintf("-collection:mirai=%s",decl),fmt.tprintf("-collection:plugins=%s",lib.stage)) {return}
    }
    // The project sees the plugins through the declarations of their libraries, as it builds.
    extra:=generated_flags(p.root,context.temp_allocator)
    if !ir(t,root,compiler,generated_folder(p.root,.Editor,context.temp_allocator),project.path(folder,"ir/demo"),flags[:],
        fmt.tprintf("-collection:mirai=%s",decl),fmt.tprintf("-collection:project=%s",p.root),fmt.tprintf("-collection:plugins=%s",project.path(folder,"plugins","decl")),extra[0]) {return}

    large:=0
    walker:=os.walker_create(project.path(folder,"ir"))
    defer os.walker_destroy(&walker)
    for info in os.walker_walk(&walker) {
        if info.type!=.Regular || !strings.has_suffix(info.name,".ll") {continue}
        data,read_error:=os.read_entire_file(info.fullpath,context.temp_allocator)
        if !testing.expect(t,read_error==nil) {continue}
        for store in ir_aggregate_stores(string(data),64,context.temp_allocator) {
            large+=1
            if large<=20 {testing.expectf(t,false,"%s: %s stores %s (%d bytes) at once",info.name,store.function,store.type,store.size)}
        }
        for split in ir_split_aggregates(string(data),IR_SPLIT_LIMIT,context.temp_allocator) {
            large+=1
            if large<=20 {testing.expectf(t,false,"%s: %s copies an aggregate element by element in %d lines",info.name,split.function,split.lines)}
        }
    }
    testing.expectf(t,large==0,"%d stores of aggregates of more than 64 bytes; write one value per assignment (ODIN_WORKAROUNDS, odin-lang/Odin#7937)",large)
}

// How many lines of a function copy aggregates element by element before it
// counts as the split form of the defect: the largest function that is not
// one has 3806, and those that were had from 9930 to 45469.
IR_SPLIT_LIMIT :: 5000

// A value that comes out of a call into a temporary leaves no store of the
// aggregate at -o:minimal: it is already split, one %.fca. line per element.
@(test)
ir_split_aggregates_counts_the_lines_of_each_function :: proc(t:^testing.T) {
    text:=`define void @"p::split"(ptr %0) {
decls:
  %.fca.0.extract = extractvalue %"p::Big" %x, 0
  %.fca.1.extract = extractvalue %"p::Big" %x, 1
  store i64 %.fca.1.extract, ptr %0, align 8
  ret void
}

define void @"p::small"(ptr %0) {
decls:
  %.fca.0.extract = extractvalue %"p::Big" %x, 0
  ret void
}
`
    splits:=ir_split_aggregates(text,2,context.temp_allocator)
    if !testing.expect_value(t,len(splits),1) {return}
    testing.expect_value(t,splits[0].function,"p::split")
    testing.expect_value(t,splits[0].lines,3)
}

Ir_Split :: struct {function:string,lines:int}

// The functions of a module of LLVM IR with more than limit lines that copy
// an aggregate element by element.
ir_split_aggregates :: proc(text:string,limit:int,allocator:=context.allocator) -> []Ir_Split {
    splits:=make([dynamic]Ir_Split,allocator)
    function:=""
    lines:=0
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        if strings.has_prefix(line,"define ") {
            at:=strings.index_byte(line,'@')
            if at<0 {continue}
            name:=line[at+1:]
            if strings.has_prefix(name,`"`) {
                name=name[1:]
                name=name[:max(strings.index_byte(name,'"'),0)]
            } else {
                name=name[:max(strings.index_byte(name,'('),0)]
            }
            function,lines=name,0
            continue
        }
        if strings.contains(line,".fca.") {lines+=1}
        if strings.has_prefix(line,"}") && function!="" {
            if lines>limit {append(&splits,Ir_Split{strings.clone(function,allocator),lines})}
            function=""
        }
    }
    return splits[:]
}

// A function and the stores the IR shows in it.
@(test)
ir_aggregate_stores_finds_only_the_large_ones :: proc(t:^testing.T) {
    text:=`%"p::Big" = type { [60 x float], i64 }
%"p::Small" = type { i16, [6 x i8], double }
%"p::U" = type <{ [5 x i64], i64 }>
%..string = type { ptr, i64 }

define dllexport void @call_rhs(ptr %0, ptr noalias nocapture nonnull %__.context_ptr) {
decls:
  store %"p::Big" %.fca.1.insert, ptr %0, align 8
  store %"p::Small" %x, ptr %0, align 8
  store %..string %s, ptr %1, align 8
  store i64 0, ptr %2, align 8
  store <16 x float> %v, ptr %3, align 64
  ret void
}

define void @"p::other"(ptr %0) {
decls:
  store volatile [9 x i64] %a, ptr %0, align 8
  store %"p::U" %u, ptr %0, align 1
  ret void
}
`
    stores:=ir_aggregate_stores(text,64,context.temp_allocator)
    if !testing.expect_value(t,len(stores),2) {return}
    testing.expect_value(t,stores[0].function,"call_rhs")
    testing.expect_value(t,stores[0].size,248)
    testing.expect_value(t,stores[1].function,"p::other")
    testing.expect_value(t,stores[1].type,`[9 x i64]`)
    testing.expect_value(t,stores[1].size,72)
}

Ir_Store :: struct {function,type:string,size:int}

// The stores of aggregates of more than limit bytes in a module of LLVM IR,
// with the function each one is in, sized with the layout of a 64-bit target.
ir_aggregate_stores :: proc(text:string,limit:int,allocator:=context.allocator) -> []Ir_Store {
    Scan :: struct {definitions:map[string]string,layouts:map[string][2]int}
    scan:Scan
    scan.definitions=make(map[string]string,context.temp_allocator)
    scan.layouts=make(map[string][2]int,context.temp_allocator)
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        if !strings.has_prefix(line,"%") {continue}
        cut:=strings.index(line," = type ")
        if cut<0 {continue}
        scan.definitions[line[:cut]]=line[cut+len(" = type "):]
    }
    // size and alignment of the type at the start of text, and what follows it
    layout :: proc(scan:^Scan,text:string) -> (size,align:int,rest:string,ok:bool) {
        text:=strings.trim_left_space(text)
        fields :: proc(scan:^Scan,text,close:string,packed:bool) -> (size,align:int,rest:string,ok:bool) {
            rest=strings.trim_left_space(text)
            align=1
            for !strings.has_prefix(rest,close) {
                field_size,field_align,after,field_ok:=layout(scan,rest)
                if !field_ok {return}
                if !packed {
                    size=(size+field_align-1)/field_align*field_align
                    align=max(align,field_align)
                }
                size+=field_size
                rest=strings.trim_left_space(after)
                if strings.has_prefix(rest,",") {rest=strings.trim_left_space(rest[1:])}
            }
            if !packed {size=(size+align-1)/align*align}
            return size,packed?1:align,rest[len(close):],true
        }
        switch {
        case strings.has_prefix(text,"<{"): return fields(scan,text[2:],"}>",true)
        case strings.has_prefix(text,"{"):  return fields(scan,text[1:],"}",false)
        case strings.has_prefix(text,"[") || strings.has_prefix(text,"<"):
            close:=text[0]=='['?"]":">"
            count_end:=strings.index(text," x ")
            if count_end<0 {return}
            count:=strconv.parse_int(strings.trim_space(text[1:count_end])) or_return
            element_size,element_align,after,element_ok:=layout(scan,text[count_end+len(" x "):])
            if !element_ok {return}
            after=strings.trim_left_space(after)
            if !strings.has_prefix(after,close) {return}
            size=count*element_size
            align=element_align
            // A vector is aligned to its size, a power of two.
            if close==">" {
                align=1
                for align<size {align*=2}
                size=(size+align-1)/align*align
            }
            return size,align,after[1:],true
        case strings.has_prefix(text,"%"):
            end:=1
            if strings.has_prefix(text,`%"`) {
                quote:=strings.index_byte(text[2:],'"')
                if quote<0 {return}
                end=2+quote+1
            } else {
                for end<len(text) && (text[end]=='.' || text[end]=='_' || text[end]=='$' || text[end]=='-' || text[end]>='0' && text[end]<='9' || text[end]>='a' && text[end]<='z' || text[end]>='A' && text[end]<='Z') {end+=1}
            }
            name:=text[:end]
            if known,cached:=scan.layouts[name];cached {return known[0],known[1],text[end:],true}
            definition,defined:=scan.definitions[name]
            if !defined || strings.has_prefix(definition,"opaque") {return 0,1,text[end:],true}
            size,align,_,ok=layout(scan,definition)
            if !ok {return}
            scan.layouts[name]={size,align}
            return size,align,text[end:],true
        case strings.has_prefix(text,"ptr"): return 8,8,text[3:],true
        case strings.has_prefix(text,"double"): return 8,8,text[6:],true
        case strings.has_prefix(text,"float"): return 4,4,text[5:],true
        case strings.has_prefix(text,"half"): return 2,2,text[4:],true
        case strings.has_prefix(text,"bfloat"): return 2,2,text[6:],true
        case strings.has_prefix(text,"fp128"): return 16,16,text[5:],true
        case strings.has_prefix(text,"x86_fp80"): return 16,16,text[8:],true
        case strings.has_prefix(text,"i"):
            end:=1
            for end<len(text) && text[end]>='0' && text[end]<='9' {end+=1}
            bits:=strconv.parse_int(text[1:end]) or_return
            size=1
            for size*8<bits {size*=2}
            return size,size,text[end:],true
        }
        return
    }
    stores:=make([dynamic]Ir_Store,allocator)
    function:string
    rest=text
    for line in strings.split_lines_iterator(&rest) {
        if strings.has_prefix(line,"define ") {
            at:=strings.index_byte(line,'@')
            if at<0 {continue}
            name:=line[at+1:]
            if strings.has_prefix(name,`"`) {
                name=name[1:]
                name=name[:max(strings.index_byte(name,'"'),0)]
            } else {
                name=name[:max(strings.index_byte(name,'('),0)]
            }
            function=name
            continue
        }
        body:=strings.trim_left_space(line)
        if !strings.has_prefix(body,"store ") {continue}
        body=body[len("store "):]
        for prefix in ([2]string{"atomic ","volatile "}) {
            if strings.has_prefix(body,prefix) {body=body[len(prefix):]}
        }
        if !strings.has_prefix(body,"%") && !strings.has_prefix(body,"{") && !strings.has_prefix(body,"[") && !strings.has_prefix(body,"<{") {continue}
        size,_,after,ok:=layout(&scan,body)
        if !ok || size<=limit {continue}
        append(&stores,Ir_Store{strings.clone(function,allocator),strings.clone(strings.trim_space(body[:len(body)-len(after)]),allocator),size})
    }
    return stores[:]
}
