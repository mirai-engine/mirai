package shaders

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:std/subprocess"

// A Slang compiler that stays alive: the library of Slang in a process of its
// own (`mirai shaders compiler`), which takes one compilation after another on
// its input. Each is the command line of slangc and gives the same code and
// reflection, byte for byte: the compile request is made from those arguments,
// and only what a process of slangc starts with (loading the library and the
// core module of Slang) is not done again. A compilation that brings the
// library down ends that process alone.

// What a compiler and the generation say to each other; raise it when either changes.
@(private)
COMPILER_PROTOCOL :: "mirai-slang/1"

// What starts the lines of the compiler that the generation reads: Slang may
// write to the same stream.
@(private)
COMPILER_MARK :: "@@mirai-slang "

// How often a compiler looks at the memory it holds while it compiles.
@(private)
COMPILER_SAMPLE :: 2*time.Millisecond

@(private)
Slang_Global_Desc :: struct {structure_size,api_version,min_language_version:u32,enable_glsl:bool,reserved:[16]u32}

// SlangLanguageVersion 2025: what a global session has by default, as slangc makes it.
@(private)
SLANG_LANGUAGE_2025 :: 2025

// The C interface of the library that slangc itself runs.
@(private)
Slang_Library :: struct {
    global_session:  proc "c" (desc:^Slang_Global_Desc,session:^rawptr) -> i32 `dynlib:"slang_createGlobalSession2"`,
    request_create:  proc "c" (session:rawptr) -> rawptr `dynlib:"spCreateCompileRequest"`,
    request_destroy: proc "c" (request:rawptr) `dynlib:"spDestroyCompileRequest"`,
    search_path_add: proc "c" (request:rawptr,folder:cstring) `dynlib:"spAddSearchPath"`,
    arguments:       proc "c" (request:rawptr,arguments:[^]cstring,count:i32) -> i32 `dynlib:"spProcessCommandLineArguments"`,
    compile:         proc "c" (request:rawptr) -> i32 `dynlib:"spCompile"`,
    diagnostics:     proc "c" (request:rawptr) -> cstring `dynlib:"spGetDiagnosticOutput"`,
    entry_code:      proc "c" (request:rawptr,entry,target:i32,blob:^^Slang_Blob) -> i32 `dynlib:"spGetEntryPointCodeBlob"`,
    handle:          dynlib.Library `dynlib:"__handle"`,
}

// ISlangBlob: its table of methods, after those of ISlangUnknown.
@(private)
Slang_Blob :: struct {
    methods:^struct {
        query_interface:rawptr,
        add_ref:proc "system" (blob:^Slang_Blob) -> u32,
        release:proc "system" (blob:^Slang_Blob) -> u32,
        pointer:proc "system" (blob:^Slang_Blob) -> rawptr,
        size:   proc "system" (blob:^Slang_Blob) -> uint,
    },
}

// The memory the process held at its most while a compilation ran.
@(private)
Compiler_Sampler :: struct {
    running:bool, // atomic
    done:   bool, // atomic
    peak:   i64,  // atomic
}

// The process of `mirai shaders compiler <slangc>`: compilations on stdin, one
// answer on stdout for each, until stdin ends. The library is the one next to
// slangc. Exit 1 when it cannot be loaded.
compiler_serve :: proc(slangc:string) -> int {
    out:=os.stdout
    library:Slang_Library
    path:=compiler_library(slangc,context.temp_allocator)
    if _,loaded:=dynlib.initialize_symbols(&library,path);!loaded {
        fmt.fprintf(out,"%serror the library of Slang could not be loaded from %s\n",COMPILER_MARK,path)
        return 1
    }
    desc:=Slang_Global_Desc{structure_size=size_of(Slang_Global_Desc),min_language_version=SLANG_LANGUAGE_2025,enable_glsl=true}
    session:rawptr
    if library.global_session(&desc,&session)<0 || session==nil {
        fmt.fprintf(out,"%serror Slang did not start its session\n",COMPILER_MARK)
        return 1
    }
    fmt.fprintf(out,"%sready %s\n",COMPILER_MARK,COMPILER_PROTOCOL)
    // slangc searches its own folder first.
    own:=strings.clone_to_cstring(path_parent(slangc),context.allocator)
    sampler:Compiler_Sampler
    watcher:=thread.create_and_start_with_poly_data(&sampler,compiler_sample)
    defer if watcher!=nil {
        sync.atomic_store(&sampler.done,true)
        thread.join(watcher)
        thread.destroy(watcher)
    }
    input:=Line_Reader{file=os.stdin}
    for {
        free_all(context.temp_allocator)
        header,more:=line_read(&input,context.temp_allocator)
        if !more {return 0}
        count,parsed:=strconv.parse_int(header,10)
        if !parsed || count<1 {
            fmt.fprintf(out,"%serror a compilation starts with the number of its arguments, not %q\n",COMPILER_MARK,header)
            return 1
        }
        arguments:=make([]cstring,count,context.temp_allocator)
        output:=""
        for &argument,i in arguments {
            text,read:=line_read(&input,context.temp_allocator)
            if !read {return 0}
            if i>0 && arguments[i-1]=="-o" {output=text}
            argument=strings.clone_to_cstring(text,context.temp_allocator)
        }
        start,_,_:=subprocess.memory_held(os.get_pid())
        sync.atomic_store(&sampler.peak,start)
        sync.atomic_store(&sampler.running,true)
        request:=library.request_create(session)
        library.search_path_add(request,own)
        ok:=library.arguments(request,raw_data(arguments),i32(count))>=0 && library.compile(request)>=0
        said:=strings.clone(string(library.diagnostics(request)),context.temp_allocator)
        if ok && output!="" {
            blob:^Slang_Blob
            ok=library.entry_code(request,0,0,&blob)>=0 && blob!=nil
            if ok {
                ok=write_file(output,([^]u8)(blob.methods.pointer(blob))[:blob.methods.size(blob)])
                blob.methods.release(blob)
                if !ok {said=fmt.tprintf("%serror: could not write %s\n",said,output)}
            }
        }
        library.request_destroy(request)
        sync.atomic_store(&sampler.running,false)
        now,_,_:=subprocess.memory_held(os.get_pid())
        peak:=max(sync.atomic_load(&sampler.peak),now)
        fmt.fprintf(out,"%sdone %d %d %d\n%s",COMPILER_MARK,0 if ok else 1,peak,len(said),said)
    }
}

@(private)
compiler_sample :: proc(sampler:^Compiler_Sampler) {
    pid:=os.get_pid()
    for !sync.atomic_load(&sampler.done) {
        time.sleep(COMPILER_SAMPLE)
        if !sync.atomic_load(&sampler.running) {continue}
        if held,_,ok:=subprocess.memory_held(pid);ok && held>sync.atomic_load(&sampler.peak) {sync.atomic_store(&sampler.peak,held)}
    }
}

// Reads lines of a stream without a buffer of the system.
@(private)
Line_Reader :: struct {
    file:^os.File,
    buffer:[4096]u8,
    start,end:int,
}

// The next line, without its line feed; false at the end of the stream.
@(private)
line_read :: proc(reader:^Line_Reader,allocator:=context.allocator) -> (line:string,ok:bool) {
    collected:=make([dynamic]u8,allocator)
    for {
        for i in reader.start..<reader.end {
            if reader.buffer[i]!='\n' {continue}
            append(&collected,..reader.buffer[reader.start:i])
            reader.start=i+1
            return strings.trim_right(string(collected[:]),"\r"),true
        }
        append(&collected,..reader.buffer[reader.start:reader.end])
        reader.start,reader.end=0,0
        count,error:=os.read(reader.file,reader.buffer[:])
        if error!=nil || count<=0 {return string(collected[:]),len(collected)>0}
        reader.end=count
    }
}

// Exactly count bytes of a stream after what was read in lines; false when it ends before.
@(private)
bytes_read :: proc(reader:^Line_Reader,count:int,allocator:=context.allocator) -> (data:[]u8,ok:bool) {
    data=make([]u8,count,allocator)
    at:=copy(data,reader.buffer[reader.start:reader.end])
    reader.start+=at
    for at<count {
        read,error:=os.read(reader.file,data[at:])
        if error!=nil || read<=0 {return data[:at],false}
        at+=read
    }
    return data,true
}
