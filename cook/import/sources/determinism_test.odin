package sources

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:cook/build"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

// What an import writes is versioned and its bytes name it in the store, so the same sources give
// the same bytes on Windows, Linux and macOS. Two things round differently by target: the math of
// the C library (sin, pow...) and the products of matrices with an odd side, which the compiler
// fuses into one instruction on arm64 and not on x86-64 (ODIN_WORKAROUNDS, fused_matrix_product).
// The IR of the import program, as the build of the engine makes it, has neither in a procedure of
// the engine, nor in one of core it calls.
@(test)
the_import_program_computes_the_same_bits_on_every_target :: proc(t:^testing.T) {
    root:=slashes(project.path_absolute(#directory+"../../..",context.temp_allocator))
    compiler,found:=build.compiler_find(root,context.temp_allocator)
    if !testing.expect(t,found,"no Odin compiler") {return}
    folder:=base.test_folder(t,"determinism")
    if folder=="" {return}
    program:=project.path(folder,"main",allocator=context.temp_allocator)
    ir:=project.path(folder,"ir",allocator=context.temp_allocator)
    _=os.make_directory_all(program)
    _=os.make_directory_all(ir)
    main:=`package main

import "core:os"
import "mirai:cook/import/sources"

main :: proc() {os.exit(sources.command(os.args[1:],os.to_writer(os.stdout),os.to_writer(os.stderr),nil))}
`
    if !testing.expect(t,os.write_entire_file(project.path(program,"main.odin",allocator=context.temp_allocator),transmute([]u8)main)==nil) {return}
    command:=[]string{compiler,"build",program,fmt.tprintf("-collection:mirai=%s",root),"-ignore-unknown-attributes","-o:minimal","-build-mode:llvm-ir",fmt.tprintf("-out:%s",ir)}
    memory,_:=build.compiler_memory()
    state,_,errors,error:=subprocess.exec({command=command},context.temp_allocator,{memory=memory})
    if !testing.expectf(t,error==nil && state.exit_code==0,"the import program does not compile to IR:\n%s",string(errors)) {return}
    texts:=make([dynamic]string,context.temp_allocator)
    walker:=os.walker_create(ir)
    defer os.walker_destroy(&walker)
    for info in os.walker_walk(&walker) {
        if info.type!=.Regular || !strings.has_suffix(info.name,".ll") {continue}
        data,read_error:=os.read_entire_file(info.fullpath,context.temp_allocator)
        if testing.expect(t,read_error==nil) {append(&texts,string(data))}
    }
    for found in ir_platform_math(texts[:],context.temp_allocator) {
        if slice.contains(PLATFORM_MATH_PENDING,found.function) {continue}
        testing.expectf(t,false,"%s computes with %s, which rounds differently by target: use the math of mirai:std/math (sin_det, pow_det, mat3_mul_det...)",found.function,found.what)
    }
}

// The window of the lossless encoder of audio/ takes the cosine of the C library; its owner moves
// it to cos_det_f64.
@(private="file")
PLATFORM_MATH_PENDING :: []string{"mirai_audio::[lossless_encode.odin]::tukey"}

@(test)
ir_platform_math_names_the_procedures_of_the_engine_that_reach_it :: proc(t:^testing.T) {
    text:=`define internal float @"math::sin_f32"(float %0) {
  %2 = call float @llvm.sin.f32(float %0)
  ret float %2
}

define internal float @"linalg::turn"(float %0) {
  %2 = call float @"math::sin_f32"(float %0)
  ret float %2
}

define internal void @"importer::spin"(ptr %0) {
  %2 = call float @"linalg::turn"(float 1.0)
  ret void
}

define internal void @"importer::fused"(ptr %0) {
  %2 = call float @llvm.fma.f32(float %a, float %b, float %c)
  %3 = fmul contract float %2, %2
  ret void
}

define internal void @"importer::plain"(ptr %0) {
  %2 = fmul float %a, %b
  %3 = call float @llvm.sqrt.f32(float %2)
  ret void
}
`
    found:=ir_platform_math({text},context.temp_allocator)
    if !testing.expect_value(t,len(found),2) {return}
    testing.expect_value(t,found[0],Ir_Platform_Math{"importer::fused","@llvm.fma"})
    testing.expect_value(t,found[1],Ir_Platform_Math{"importer::spin","linalg::turn"})
}

Ir_Platform_Math :: struct {function,what:string}

// The procedures of the engine in modules of LLVM IR that fuse a product and a sum, compute with
// the math of the C library, or call a procedure of core that does, sorted by name.
ir_platform_math :: proc(texts:[]string,allocator:=context.allocator) -> []Ir_Platform_Math {
    CORE :: []string{"math::","linalg::","ease::"}
    BANNED :: []string{"@llvm.fma.","@llvm.fmuladd.","@llvm.sin.","@llvm.cos.","@llvm.tan.","@llvm.asin.","@llvm.acos.","@llvm.atan.","@llvm.atan2.","@llvm.sinh.","@llvm.cosh.","@llvm.tanh.","@llvm.sincos.","@llvm.pow.","@llvm.powi.","@llvm.exp.","@llvm.exp2.","@llvm.exp10.","@llvm.log.","@llvm.log2.","@llvm.log10.",
        "@sinf(","@sin(","@cosf(","@cos(","@tanf(","@tan(","@asinf(","@asin(","@acosf(","@acos(","@atanf(","@atan(","@atan2f(","@atan2(","@powf(","@pow(","@expf(","@exp(","@exp2f(","@exp2(","@logf(","@log(","@log2f(","@log2(","@log10f(","@log10(","@fmaf(","@fma(",
        " contract "," fast "," reassoc "}
    Function :: struct {banned:string,callees:[dynamic]string}
    functions:=make(map[string]Function,context.temp_allocator)
    for text in texts {
        rest:=text
        name:=""
        for line in strings.split_lines_iterator(&rest) {
            if strings.has_prefix(line,"}") {name="";continue}
            if strings.has_prefix(line,"define ") {
                name=ir_symbol(line[strings.index_byte(line,'@')+1:])
                if name not_in functions {functions[name]={callees=make([dynamic]string,context.temp_allocator)}}
                continue
            }
            if name=="" {continue}
            f:=&functions[name]
            if f.banned=="" {
                for banned in BANNED {
                    if !strings.contains(line,banned) {continue}
                    if banned[0]==' ' && !strings.contains(line," = f") {continue}
                    f.banned=strings.trim(banned," (.")
                    break
                }
            }
            if call:=strings.index(line,"call ");call>=0 {
                if at:=strings.index_byte(line[call:],'@');at>=0 {append(&f.callees,ir_symbol(line[call+at+1:]))}
            }
        }
    }
    is_core :: proc(name:string,core:[]string) -> bool {
        for prefix in core {if strings.has_prefix(name,prefix) {return true}}
        return false
    }
    // The procedures of core that compute with it, or call one that does.
    reaches:=make(map[string]bool,context.temp_allocator)
    for name,f in functions {if f.banned!="" && is_core(name,CORE) {reaches[name]=true}}
    for grown:=true;grown; {
        grown=false
        for name,f in functions {
            if reaches[name] || !is_core(name,CORE) {continue}
            for callee in f.callees {
                if reaches[callee] {reaches[name]=true;grown=true;break}
            }
        }
    }
    found:=make([dynamic]Ir_Platform_Math,allocator)
    for name,f in functions {
        if is_core(name,CORE) {continue}
        what:=f.banned
        if what=="" {
            for callee in f.callees {if reaches[callee] {what=callee;break}}
        }
        if what!="" {append(&found,Ir_Platform_Math{strings.clone(name,allocator),strings.clone(what,allocator)})}
    }
    slice.sort_by(found[:],proc(a,b:Ir_Platform_Math) -> bool {return a.function<b.function})
    return found[:]
}

// The name of a symbol of LLVM IR at the start of text, after its @: quoted or bare.
@(private="file")
ir_symbol :: proc(text:string) -> string {
    if strings.has_prefix(text,`"`) {
        end:=strings.index_byte(text[1:],'"')
        return text[1:][:max(end,0)]
    }
    end:=strings.index_any(text,"( ,")
    return text[:end] if end>=0 else text
}

@(private="file")
slashes :: proc(path:string) -> string {
    out,_:=strings.replace_all(path,"\\","/",context.temp_allocator)
    return out
}
