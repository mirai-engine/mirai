// Package shaders compiles Mirai's single-source Slang shaders to SPIR-V and
// Metal, and builds the catalog of material programs.
//
// SPIR-V comes from Slang; the Metal source from that SPIR-V through spirv-opt
// and SPIRV-Cross, which keeps the explicit slot ABI of the RHI. The bindings
// and threadgroup sizes of the manifest and of the Odin tables are the ones
// Slang reflects.
//
// A generation is a transaction: everything is compiled into a staging folder
// and the output is replaced only when all of it succeeded. Fingerprints are
// taken from names relative to the engine or the project and from sources with
// their line endings normalized, so they are the same on every machine and
// checkout.
package shaders

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "mirai:cook/workspace"
import "mirai:rhi"
import "mirai:std/base"
import job_system "mirai:std/jobs"
import "mirai:render/abi"
import "mirai:std/serial"

// Names what the generator produces from a given source and compiler. It is
// part of every fingerprint: raise it when the outputs change for a reason the
// fingerprints do not see (another flag is already seen, as are the tools).
GENERATOR_CONTRACT :: "mirai-shaders/6"

// The folders of the engine every stage includes, under its root: the shaders
// of the renderer and those engine/render gives the plugins that extend it.
ENGINE_INCLUDES :: [?]string{"shaders/include","engine/render/shaders"}

@(private)
TABLE_SLOT :: rhi.TEXTURE_TABLE_SLOT
@(private)
TABLE_METAL_BUFFER :: rhi.TEXTURE_TABLE_METAL_BUFFER
@(private)
BUFFER_SLOTS :: rhi.MAX_BUFFER_BINDING_SLOTS
@(private)
SAMPLER_SLOTS :: rhi.MAX_SAMPLER_BINDING_SLOTS

@(private)
SLANG_FLAGS :: []string{
    "-entry","main","-matrix-layout-column-major","-line-directive-mode","none",
    // 41035: the stack of a BVH walk is written before it is read, and
    // initializing it for every ray is work no ray needs.
    "-warnings-disable","40100,41035",
}
// The passes of spirv-opt that Slang runs at -O3 (its -O), but for the first
// redundancy elimination: on the function the inliner makes of a whole call
// tree, before the dead code goes, it takes most of the time of a large stage.
// The one after the dead code goes stays. -O0 leaves
// Slang only these.
@(private)
SLANG_OPTIMIZATION :: []string{
    "-O0","-Xspirv-opt...",
    "--wrap-opkill","--eliminate-dead-branches","--merge-return","--inline-entry-points-exhaustive",
    "--eliminate-dead-functions","--eliminate-dead-code-aggressive","--private-to-local",
    "--eliminate-local-single-block","--eliminate-local-single-store","--eliminate-dead-code-aggressive",
    "--scalar-replacement=0","--convert-local-access-chains","--eliminate-local-single-block",
    "--eliminate-local-single-store","--eliminate-dead-code-aggressive","--compact-ids",
    "--eliminate-local-multi-store","--eliminate-dead-code-aggressive","--ccp","--eliminate-dead-code-aggressive",
    "--loop-unroll","--eliminate-dead-branches","--combine-access-chains","--simplify-instructions",
    "--scalar-replacement=0","--convert-local-access-chains","--eliminate-local-single-block",
    "--eliminate-local-single-store","--eliminate-dead-code-aggressive","--ssa-rewrite",
    "--eliminate-dead-code-aggressive","--vector-dce","--eliminate-dead-inserts","--eliminate-dead-branches",
    "--simplify-instructions","--if-conversion","--copy-propagate-arrays","--reduce-load-size",
    "--eliminate-dead-code-aggressive","--merge-blocks","--redundancy-elimination","--eliminate-dead-branches",
    "--merge-blocks","--simplify-instructions","--compact-ids",
    "-X.",
}
@(private)
SPIRV_FLAGS :: []string{"-target","spirv","-profile","sm_6_5","-fvk-use-scalar-layout","-capability","spirv_1_5"}
@(private)
VALIDATE_FLAGS :: []string{"--target-env","vulkan1.2","--scalar-block-layout"}
// Numeric names avoid Metal keywords such as the DDGI resource ray_data.
@(private)
OPTIMIZE_FLAGS :: []string{"--target-env=vulkan1.2","--scalar-block-layout","-O","--strip-debug"}
// Descriptor set 1, the texture table, is an argument buffer in device memory,
// where an array without a size may live; set 0 keeps the slots.
@(private)
METAL_FLAGS :: []string{"--msl","--msl-version","20400","--msl-decoration-binding","--msl-argument-buffers","--msl-argument-buffer-tier","1","--msl-discrete-descriptor-set","0","--msl-device-argument-buffer","1"}
// Before MSL 3.1 SPIRV-Cross emulates the atomics of an image with a linear
// texture over a buffer, which the RHI does not make; 3.1 has them on textures.
@(private)
METAL_ATOMICS_VERSION :: "30100"

// A folder of Slang programs besides the project's own: the shaders/ of a plugin.
Source :: struct {
    name:  string, // of the plugin: its programs are copied under include/programs/plugins/<name>
    folder:string,
}

// Where the generation of a project is published unless Options.output says otherwise.
PROJECT_OUTPUT :: ".mirai/shaders"

Options :: struct {
    root:    string, // the engine: shaders/, render/, rhi/ and the tools under .deps/
    project: string, // its shaders/ programs join the catalog; "" generates for the engine alone
    sources: []Source, // more folders of programs, after those of the project
    output:  string, // "": <project>/.mirai/shaders, or <root>/shaders/build without a project
    cache:   string, // the stamp of the last generation into output; "": .mirai/shader-cache of the project, or of the engine without one
    odin:    bool,   // also compile the shaders of the RHI tests and write the Odin tables of render and rhi; never for a project
    ship:    bool,   // with odin: the code render embeds is encoded for an executable to ship, which takes longer (EMBED_SHIP)
    workers: int,    // compilations at once; 0: one per logical processor
    tools:   [Tool]string, // "": looked up with tool_find
    backends:Backends, // {}: HOST_BACKEND, the one this system runs
    first:   []string, // stages compiled before the others, by their names in the manifest ("thumbnail.frag"), with those of each program of them
    first_output:string, // "": none. Once the first stages compile, a generation that loads alone is written there: the catalog and the first stages of this one, the others as the output has them
    idle:    []string, // stages compiled after the others, by their names in the manifest: those whose code the one who loads the generation does not run now
    active_output:string, // "": none. Once every stage but the idle ones compiles, a generation that loads alone is written there: the catalog and those stages of this one, the idle ones as the output has them. Not without an idle stage
    progress:^Progress, // nil: none. One for each generation
}

// What the thread that started a generation follows of it, and how it stops it.
Progress :: struct {
    first: bool, // atomic: Options.first_output has the first stages
    active:bool, // atomic: Options.active_output has every stage but the idle ones
    runner:Runner,
}

// Stops a running generation from another thread: no stage starts any more
// and the tools that run are killed. It ends with Result.cancelled and
// publishes nothing.
cancel :: proc(progress:^Progress) {
    runner_cancel(&progress.runner)
}

// What the code of a stage is for: SPIR-V for Vulkan, Metal source for Metal.
Backend :: enum u8 {Vulkan,Metal}
Backends :: bit_set[Backend;u8]
HOST_BACKEND :: Backend.Metal when rhi.SHADER_FORMAT==.Msl else Backend.Vulkan

Result :: struct {
    shaders,tests,programs:int,
    compiled,reused:int, // stages run through the compilers, and taken from the shared cache or the previous output
    changed: bool,       // the published generation is another one: its manifest was written
    current: bool,       // nothing changed since the last generation: no stage was looked at and no tool was run
    engine:  string,     // identity of what its engine stages share with a build of the engine (engine_interface)
    warnings:string,     // what the compilers said of the stages that compiled
    refused: string,     // the programs left out of the catalog and why, one a line: the others were published
    error:   string,     // "": the generation was published
    diagnostics:[]Diagnostic, // of the stage that failed, by the sources it was compiled from
    cancelled:bool,      // cancel stopped it before it was published
    slowest:[SLOWEST]Stage_Time, // the stages that took longest to compile, longest first; seconds 0 past the last
    reflection:f64,      // seconds the reflection of the programs took
    compiling:f64,       // seconds the stages compiled took, added up
}

// What a stage took to compile, in seconds.
Stage_Time :: struct {name:string,seconds:f64}
SLOWEST :: 8

result_destroy :: proc(result:^Result,allocator:=context.allocator) {
    delete(result.engine,allocator)
    delete(result.warnings,allocator)
    delete(result.refused,allocator)
    delete(result.error,allocator)
    diagnostics_destroy(result.diagnostics,allocator)
    for each in result.slowest {delete(each.name,allocator)}
    result^={}
}

@(private)
Generation :: struct {
    root,project,output,cache:string,
    shared:       string, // the cache every checkout of the repository shares (CACHE_NAME)
    backends:     Backends,
    sources:      Sources,
    tools:        [Tool]string,
    runner:       ^Runner, // of Options.progress, or own_runner
    own_runner:   Runner,
    version:      string, // of Slang
    metal_tools:  string, // of spirv-opt and SPIRV-Cross
    configuration:[]u8,
    includes:     []string,
    bases:        []Base,
    features:     Extension_Features, // what the extensions.slang of the generation defines
    tests_folder: string,
    engine_build: string, // <root>/shaders/build when the output is another folder; "" otherwise
    jobs:         []Job,
    order:        []int, // the jobs by when they run (jobs_order)
    first_left:   int, // atomic: first stages still to compile
    first_output: string,
    active_left:  int, // atomic: stages that are not idle still to compile
    active_output:string,
    progress:     ^Progress,
    shader_jobs,extension_jobs:[]Job,
    program_jobs: []Job, // the stages of the engine compiled for one program each, by name outside Shader_Id
    identity:     string, // of what its engine stages share with the engine (engine_interface), as the manifest names it
    catalog:      string, // its fingerprint
    vfx:          []string, // the Vfx programs: a stage marked `//! per vfx program` is compiled once for each
    surface:      []string, // the Surface programs: a stage marked `//! per surface program` is compiled once for each
    vertex:       []string, // those of them with a function vertex: a stage marked `//! per vertex program` is compiled once for each
    staging:      string,
    warnings:     strings.Builder,
    layouts:      []Shared_Layout, // of the structs shaders share with the CPU, from the probe
    copies:       []Base,          // the folders of programs staged under include/programs (path), by the folder they copy (label)
    warnings_lock:sync.Mutex,
}

@(private)
Job :: struct {
    source:   string,
    name:     string, // in the manifest: thumbnail_values.frag
    stage:    string, // of the stage it is a program of (thumbnail__Ocean_values.frag: thumbnail_values.frag), else name
    first:    bool,
    idle:     bool,
    active:   bool, // a stage of the engine or of an extension that is not idle: Options.active_output waits for it
    defines:  []string, // of its variant, then each of its constants as the constant of native.slang it reads
    constants:[]string, // the names of its constants, by id
    includes: []string, // those of the generation, or before them a folder with the extensions.slang of the stage
    bases:    []Base,
    out,staging:string,
    reduced:  bool, // compiled with -O1 instead of SLANG_OPTIMIZATION: a SPIRV-Tools bug needs it
    backends: Backends, // of the generation, without Metal for a stage of the rays traced by software (software_rays)
    prior:    Shader, // the stage as the previous output has it
    has_prior:bool,
    engine:   Shader, // the stage as the build of the engine has it: what first_write shows of a stage the output lacks
    has_engine:bool,
    result:   Shader,
    reused:   bool,
    seconds:  f64, // what compiling it took
    error:    string,
    diagnostics:[]Diagnostic,
}

@(private)
STAGE_SUFFIXES :: [Stage]string{.Vertex=".vert",.Fragment=".frag",.Compute=".comp"}
@(private)
SLANG_STAGES :: [Stage]string{.Vertex="vertex",.Fragment="fragment",.Compute="compute"}

// shader.comp.slang -> ("shader", .Compute); false for a source that is not a stage.
@(private)
stage_of :: proc(file_name:string) -> (stem:string,stage:Stage,ok:bool) {
    if !strings.has_suffix(file_name,".slang") {return}
    name:=file_name[:len(file_name)-len(".slang")]
    for suffix,candidate in STAGE_SUFFIXES {
        if strings.has_suffix(name,suffix) && len(name)>len(suffix) {return name[:len(name)-len(suffix)],candidate,true}
    }
    return
}

// blit.frag -> Blit_Frag
@(private)
identifier :: proc(name:string,allocator:=context.allocator) -> string {
    builder:=strings.builder_make(allocator)
    start:=true
    for c in transmute([]u8)name {
        alphanumeric:=(c>='0' && c<='9') || (c>='a' && c<='z') || (c>='A' && c<='Z')
        if !alphanumeric {start=true;continue}
        if start && strings.builder_len(builder)>0 {strings.write_byte(&builder,'_')}
        strings.write_byte(&builder,c-32 if start && c>='a' && c<='z' else c)
        start=false
    }
    return strings.to_string(builder)
}

Variant :: struct {name:string,defines:[]string}

// The source itself and one compilation more for each `//! variant name DEFINE...` line:
// what a constant cannot choose, because it changes what the stage declares to the
// device (a capability, its outputs, the kind of a slot).
@(private)
variants :: proc(text:string,allocator:=context.allocator) -> []Variant {
    found:=make([dynamic]Variant,allocator)
    append(&found,Variant{})
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        if !strings.has_prefix(line,"//!") {continue}
        words:=strings.fields(line[3:],allocator)
        if len(words)>=2 && words[0]=="variant" {append(&found,Variant{words[1],words[2:]})}
    }
    return found[:]
}

// Whether a stage serves only the rays traced by software: the source itself
// of one with the variant hw, or one that says so (`//! software rays`).
// Metal traces rays by hardware alone, so it gets no code of these.
@(private)
software_rays :: proc(text:string,variant:Variant) -> bool {
    if variant.name!="" {return false}
    for other in variants(text,context.temp_allocator) {if other.name=="hw" {return true}}
    return strings.contains(text,"//! software rays")
}

// A boolean a pipeline of the stage chooses (rhi.Shader_Constants), false
// unless it says so: the code reads it as `if (DEFINE)`.
Constant :: struct {name,define:string}

// The constant of native.slang a stage reads its constant of that id as.
@(private)
CONSTANT_SYMBOL :: "mirai_constant_%d"

// The constants of a source, by id: one for each `//! constant name DEFINE` line.
@(private)
constants :: proc(text:string,allocator:=context.allocator) -> []Constant {
    found:=make([dynamic]Constant,allocator)
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        if !strings.has_prefix(line,"//!") {continue}
        words:=strings.fields(line[3:],allocator)
        if len(words)==3 && words[0]=="constant" {append(&found,Constant{words[1],words[2]})}
    }
    return found[:]
}

// Why the constants of a source cannot be compiled; "" when they can.
@(private)
constants_problem :: proc(declared:[]Constant,allocator:=context.allocator) -> string {
    if len(declared)>rhi.MAX_SHADER_CONSTANTS {
        return fmt.aprintf("it declares %d constants (`//! constant`) and a stage has at most %d: make one of them a variant, or drop one",len(declared),rhi.MAX_SHADER_CONSTANTS,allocator=allocator)
    }
    for constant,i in declared {
        for other in declared[:i] {
            if other.name==constant.name || other.define==constant.define {
                return fmt.aprintf("it declares the constant %s %s twice: each `//! constant` line names another constant and another define",constant.name,constant.define,allocator=allocator)
            }
        }
    }
    return ""
}

// The resources an entry point uses, by slot, checked against the portable
// binding ABI.
@(private)
reflected_resources :: proc(data:json.Object,allocator:=context.allocator) -> (resources:[]Binding,error:string) {
    entries,_:=data["entryPoints"].(json.Array)
    if len(entries)==0 {return nil,strings.clone("the reflection has no entry point",allocator)}
    entry,_:=entries[0].(json.Object)
    entry_bindings,_:=entry["bindings"].(json.Array)
    used:=make(map[string]bool,context.temp_allocator)
    for value in entry_bindings {
        binding,_:=value.(json.Object)
        state,_:=binding["binding"].(json.Object)
        if json_truthy(state["used"]) {used[json_text(binding["name"])]=true}
    }
    found:=make([dynamic]Binding,allocator)
    parameters,_:=data["parameters"].(json.Array)
    for value in parameters {
        parameter,_:=value.(json.Object)
        name:=json_text(parameter["name"])
        if !used[name] {continue}
        binding,_:=parameter["binding"].(json.Object)
        // A constant of the stage (`//! constant`) binds nothing.
        if json_text(binding["kind"])=="specializationConstant" {continue}
        if json_text(binding["kind"])!="descriptorTableSlot" {return nil,fmt.aprintf("%s: parameters need an explicit descriptor binding",name,allocator=allocator)}
        slot,_:=json_int(binding["index"])
        space,_:=json_int(binding["space"])
        type,_:=parameter["type"].(json.Object)
        type_kind:=json_text(type["kind"])
        kind:string
        switch {
        case space==1:
            count,_:=json_int(type["elementCount"])
            // The table has no size: it grows (rhi.texture_table_set).
            if slot!=TABLE_SLOT || type_kind!="array" || count!=0 {return nil,fmt.aprintf("set 1 holds only the texture table, an array without a size, at slot %d",TABLE_SLOT,allocator=allocator)}
            element,_:=type["elementType"].(json.Object)
            if json_text(element["baseShape"])!="texture2D" {return nil,strings.clone("texture-table entries must be Texture2D",allocator)}
            kind="Texture_Table"
        case space!=0 || type_kind=="array":
            return nil,strings.clone("only set 0 scalar resources and set 1 texture table are supported",allocator)
        case type_kind=="constantBuffer": kind="Uniform_Buffer"
        case type_kind=="samplerState": kind="Sampler"
        case type_kind=="resource":
            read_write:=json_text(type["access"])=="readWrite"
            switch json_text(type["baseShape"]) {
            case "structuredBuffer","byteAddressBuffer": kind="Storage_Buffer_RW" if read_write else "Storage_Buffer"
            case "texture2D","texture3D": kind="Storage_Texture" if read_write else "Sampled_Texture"
            case "accelerationStructure": kind="Accel"
            case: return nil,fmt.aprintf("unsupported resource type: %s",json_text(type["baseShape"]),allocator=allocator)
            }
        case: return nil,fmt.aprintf("unsupported parameter type: %s",type_kind,allocator=allocator)
        }
        switch kind {
        case "Uniform_Buffer","Storage_Buffer","Storage_Buffer_RW","Accel":
            if slot>=BUFFER_SLOTS {return nil,fmt.aprintf("binding %d exceeds the %d portable slots",slot,BUFFER_SLOTS,allocator=allocator)}
        case "Sampler":
            if slot>=SAMPLER_SLOTS {return nil,fmt.aprintf("sampler binding %d exceeds %d Metal indices",slot,SAMPLER_SLOTS,allocator=allocator)}
        case "Sampled_Texture","Storage_Texture":
            if slot>=TABLE_SLOT {return nil,fmt.aprintf("texture binding %d overlaps the texture table at %d",slot,TABLE_SLOT,allocator=allocator)}
        }
        for other in found {if other.slot==slot {return nil,strings.clone("two resources share one portable binding slot",allocator)}}
        // Kept sorted by slot.
        at:=len(found)
        for at>0 && found[at-1].slot>slot {at-=1}
        inject_at(&found,at,Binding{slot,kind})
    }
    return found[:],""
}

// The name SPIRV-Cross gave the entry point: `kernel void main0(`.
@(private)
metal_entry :: proc(source:string) -> (name:string,ok:bool) {
    word_end :: proc(text:string) -> int {
        end:=0
        for end<len(text) && is_word(text[end]) {end+=1}
        return end
    }
    space_end :: proc(text:string) -> int {
        end:=0
        for end<len(text) && (is_space(text[end]) || text[end]=='\n') {end+=1}
        return end
    }
    for keyword in ([]string{"kernel","vertex","fragment"}) {
        rest,offset:=source,0
        for {
            at:=strings.index(rest,keyword)
            if at<0 {break}
            before_ok:=offset+at==0 || !is_word(source[offset+at-1])
            text:=rest[at+len(keyword):]
            offset+=at+len(keyword)
            rest=text
            if !before_ok {continue}
            spaces:=space_end(text)
            if spaces==0 {continue}
            text=text[spaces:]
            type_length:=word_end(text)
            if type_length==0 {continue}
            text=text[type_length:]
            spaces=space_end(text)
            if spaces==0 {continue}
            text=text[spaces:]
            name_length:=word_end(text)
            if name_length==0 || name_length>=len(text) || text[name_length]!='(' {continue}
            return text[:name_length],true
        }
    }
    return
}

// Every line without its trailing spaces, and one line feed at the end.
@(private)
// SPIRV-Cross gives the argument buffer of descriptor set 1, the texture
// table, the buffer index of its set, among the slots; it moves to the one
// the RHI binds it at. Until the SPIRV-Cross of the SDK has
// --msl-resource-binding (KhronosGroup/SPIRV-Cross, 2026-10-17), which would
// place it. False for a source with another argument buffer.
metal_table_buffer :: proc(source:string,allocator:=context.allocator) -> (moved:string,ok:bool) {
    PLACED :: "spvDescriptorSet1 [[buffer(1)]]"
    sets:=strings.count(source,"spvDescriptorSet")
    if sets==0 {return source,true}
    // The struct (spvDescriptorSetBuffer1), its argument and its uses name set 1 and no other.
    if strings.count(source,"spvDescriptorSet1")+strings.count(source,"spvDescriptorSetBuffer1")!=sets || strings.count(source,PLACED)!=1 {return source,false}
    moved,_=strings.replace(source,PLACED,fmt.tprintf("spvDescriptorSet1 [[buffer(%d)]]",TABLE_METAL_BUFFER),1,allocator)
    return moved,true
}

metal_normalize :: proc(source:string,allocator:=context.allocator) -> []u8 {
    builder:=strings.builder_make(allocator)
    rest:=source
    for line in strings.split_lines_iterator(&rest) {
        strings.write_string(&builder,strings.trim_right(line," \t\r\v\f"))
        strings.write_byte(&builder,'\n')
    }
    text:=builder.buf[:]
    end:=len(text)
    for end>0 && (text[end-1]=='\n' || is_space(text[end-1])) {end-=1}
    resize(&builder.buf,end)
    strings.write_byte(&builder,'\n')
    return builder.buf[:]
}

@(private)
job_fail :: proc(job:^Job,allocator:runtime.Allocator,format:string,args:..any) {
    job.error=fmt.aprintf(format,..args,allocator=allocator)
}

// Compiles one stage for the backends of the generation, or takes it from the
// shared cache when it was compiled from the same sources with the same tools
// in any checkout. The previous output gives back what the cache lost.
@(private)
job_run :: proc(g:^Generation,job:^Job,allocator:runtime.Allocator) {
    slang_stages:=SLANG_STAGES
    _,stage,_:=stage_of(path_name(job.source))
    name:=job.name
    if job.error!="" {return}
    configuration:=make([dynamic]u8,context.temp_allocator)
    append(&configuration,..g.configuration)
    append(&configuration,..transmute([]u8)strings.join(job.defines,"\n",context.temp_allocator))
    if job.reduced {append(&configuration,"-O1")}
    digest:=fingerprint(job.source,job.includes,job.bases,configuration[:],allocator,&g.sources)
    backends:=job.backends
    vulkan,metal:=.Vulkan in backends,.Metal in backends
    spv_name:=strings.concatenate({name,".spv"},allocator) if vulkan else ""
    msl_name:=strings.concatenate({name,".metal"},allocator) if metal else ""
    names:=[Backend]string{.Vulkan=spv_name,.Metal=msl_name}
    if stored,files,found:=cache_stage_read(g.shared,digest,backends,allocator);found && artifacts_stage(files,names,job.staging,backends) {
        stored.id,stored.name,stored.spv,stored.msl=identifier(name,allocator),name,spv_name,msl_name
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        job.result=shader_trim(stored,backends)
        job.reused=true
        job.result.staged=true
        job.result.constants=job.constants
        return
    }
    if job.has_prior {
        if files,found:=artifacts_read(job.prior,digest,job.out,backends);found && artifacts_stage(files,names,job.staging,backends) {
            // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
            job.result=shader_trim(job.prior,backends)
            job.reused=true
            job.result.staged=true
            job.result.constants=job.constants
            cache_stage_write(g.shared,job.result,files,backends)
            return
        }
    }

    spv:=path_join(job.staging,spv_name,allocator=context.temp_allocator)
    msl:=path_join(job.staging,msl_name,allocator=context.temp_allocator)
    temporary,temporary_error:=os.make_directory_temp("","mirai-shader-*",context.temp_allocator)
    if temporary_error!=nil {job_fail(job,allocator,"%s: could not create a temporary folder",name);return}
    temporary=path_clean(temporary,context.temp_allocator)
    defer base.remove_all(temporary)
    reflection:=path_join(temporary,"reflection.json",allocator=context.temp_allocator)
    metal_spv:=path_join(temporary,"metal.spv",allocator=context.temp_allocator)
    optimized:=path_join(temporary,"metal.optimized.spv",allocator=context.temp_allocator)

    run :: proc(g:^Generation,job:^Job,allocator:runtime.Allocator,command:[]string) -> (output:string,ok:bool) {
        output,ok=tool_run(g.runner,command,context.temp_allocator)
        if !ok {job_fail(job,allocator,"%s: command failed: %s\n%s",job.name,strings.join(command," ",context.temp_allocator),output)}
        return
    }
    // warn: what the compiler says is reported.
    slang :: proc(g:^Generation,job:^Job,allocator:runtime.Allocator,name,stage:string,output,reflection:string,warn:bool) -> bool {
        command:=make([dynamic]string,context.temp_allocator)
        append(&command,g.tools[.Slangc],job.source)
        append(&command,..SLANG_FLAGS)
        if job.reduced {append(&command,"-O1")} else {append(&command,..SLANG_OPTIMIZATION)}
        append(&command,SLANG_DIAGNOSTICS_FLAG)
        append(&command,"-stage",stage)
        for directory in job.includes {append(&command,"-I",directory)}
        for define in job.defines {append(&command,strings.concatenate({"-D",define},context.temp_allocator))}
        append(&command,..SPIRV_FLAGS)
        append(&command,"-o",output,"-reflection-json",reflection)
        said,compiled:=tool_run(g.runner,command[:],context.temp_allocator)
        diagnostics:=slang_diagnostics(said,context.temp_allocator)
        diagnostics_place(diagnostics,g.copies,{g.project,g.root},context.temp_allocator)
        if !compiled {
            job.diagnostics=diagnostics_clone(diagnostics,allocator)
            job_fail(job,allocator,"%s:\n%s",name,diagnostics_text(diagnostics,context.temp_allocator))
            return false
        }
        if warn && len(diagnostics)>0 {
            sync.guard(&g.warnings_lock)
            fmt.sbprintf(&g.warnings,"%s:\n%s\n",name,diagnostics_text(diagnostics,context.temp_allocator))
        }
        return true
    }
    validate :: proc(g:^Generation,job:^Job,allocator:runtime.Allocator,module:string) -> bool {
        command:=make([dynamic]string,context.temp_allocator)
        append(&command,g.tools[.Spirv_Val])
        append(&command,..VALIDATE_FLAGS)
        append(&command,module)
        _,ok:=run(g,job,allocator,command[:])
        return ok
    }
    reflect :: proc(g:^Generation,job:^Job,allocator:runtime.Allocator,name,reflection:string,shared:bool) -> (data:json.Object,resources:[]Binding,ok:bool) {
        readable:bool
        data,readable=read_json(reflection,context.temp_allocator)
        if !readable {job_fail(job,allocator,"%s: Slang did not write its reflection",name);return}
        if shared {
            if problem:=layouts_compare(layouts_reflected(data,context.temp_allocator),g.layouts,context.temp_allocator);problem!="" {job_fail(job,allocator,"%s: %s",name,problem);return}
        }
        problem:string
        resources,problem=reflected_resources(data,allocator)
        if problem!="" {job_fail(job,allocator,"%s: %s",name,problem);return}
        return data,resources,true
    }

    // Both backends translate the same SPIR-V: Metal optimizes it on its own.
    shared:=path_parent(job.source)!=g.tests_folder
    module:=spv if vulkan else metal_spv
    if !slang(g,job,allocator,name,slang_stages[stage],module,reflection,true) {return}
    if !validate(g,job,allocator,module) {return}
    data,resources,reflected:=reflect(g,job,allocator,name,reflection,shared)
    if !reflected {return}
    entry:string
    metal_bytes:[]u8
    if metal {
        {
            command:=make([dynamic]string,context.temp_allocator)
            append(&command,g.tools[.Spirv_Opt])
            append(&command,..OPTIMIZE_FLAGS)
            append(&command,module,"-o",optimized)
            if _,ok:=run(g,job,allocator,command[:]);!ok {return}
        }
        if !validate(g,job,allocator,optimized) {return}
        {
            command:=make([dynamic]string,context.temp_allocator)
            append(&command,g.tools[.Spirv_Cross],optimized)
            flags:=make([]string,len(METAL_FLAGS),context.temp_allocator)
            copy(flags,METAL_FLAGS)
            if spirv,spirv_error:=os.read_entire_file(optimized,context.temp_allocator);spirv_error==nil && spirv_image_atomics(spirv) {flags[2]=METAL_ATOMICS_VERSION}
            append(&command,..flags)
            append(&command,"--output",msl)
            if _,ok:=run(g,job,allocator,command[:]);!ok {return}
        }
        metal_raw,read_error:=os.read_entire_file(msl,context.temp_allocator)
        if read_error!=nil {job_fail(job,allocator,"%s: SPIRV-Cross did not write the Metal source",name);return}
        metal_source,table_moved:=metal_table_buffer(string(lf_bytes(metal_raw)),context.temp_allocator)
        if !table_moved {job_fail(job,allocator,"%s: SPIRV-Cross placed an argument buffer other than the texture table's",name);return}
        has_entry:bool
        if entry,has_entry=metal_entry(metal_source);!has_entry {job_fail(job,allocator,"%s: SPIRV-Cross did not emit a Metal entry point",name);return}
        metal_bytes=metal_normalize(metal_source,context.temp_allocator)
        if !write_file(msl,metal_bytes) {job_fail(job,allocator,"%s: could not write %s",name,msl);return}
    }
    spv_bytes:[]u8
    if vulkan {
        spv_error:os.Error
        if spv_bytes,spv_error=os.read_entire_file(spv,context.temp_allocator);spv_error!=nil {job_fail(job,allocator,"%s: Slang did not write the SPIR-V",name);return}
    }
    group:[3]int
    if stage==.Compute {
        entries,_:=data["entryPoints"].(json.Array)
        entry_point,_:=entries[0].(json.Object)
        sizes,_:=entry_point["threadGroupSize"].(json.Array)
        if len(sizes)==3 {for value,i in sizes {group[i],_=json_int(value)}}
    }
    job.result={
        id=identifier(name,allocator),name=name,stage=stage,spv=spv_name,msl=msl_name,entry=strings.clone(entry,allocator),
        bindings=resources,constants=job.constants,group=group,fingerprint=digest,staged=true,
        spv_hash=sha_of(spv_bytes,allocator) if vulkan else "",msl_hash=sha_of(metal_bytes,allocator) if metal else "",
    }
    cache_stage_write(g.shared,job.result,{.Vulkan=spv_bytes,.Metal=metal_bytes},backends)
}

// Identity of what the engine's own stages share with a build of the engine:
// how the generator binds and lays out, the structs both sides read as Slang
// lays them out, and of each stage its kind, its workgroup, its bindings and
// its constants, which are what render compiles in (shaders_gen.odin). The
// code of a stage is no part of it: a generation that changes only code loads
// into an engine that is already built and running. shaders are the stages
// as the generation of the engine compiles them: one for a project compiles
// some against what it adds, so it names the identity the generation of the
// engine of the same sources gave (generate_staged).
@(private)
engine_interface :: proc(g:^Generation,shaders:[]Shader,allocator:=context.allocator) -> string {
    hash:Sha256
    sha_begin(&hash)
    for text in ([]string{GENERATOR_CONTRACT,abi_text(),material_schema(),shared_constants()}) {sha_text(&hash,text);sha_text(&hash,"\n")}
    // A struct under a define is of the generations that define it.
    for shared in SHARED_STRUCTS {
        if shared.guard!="" {continue}
        for layout in g.layouts {
            if layout.name!=shared.slang {continue}
            sha_text(&hash,fmt.tprintf("%s %d",layout.name,layout.size))
            for field in layout.fields {sha_text(&hash,fmt.tprintf(" %s %d %d",field.name,field.offset,field.size))}
            sha_text(&hash,"\n")
        }
    }
    for shader in shaders {
        sha_text(&hash,fmt.tprintf("%s %v %v",shader.name,shader.stage,shader.group))
        for binding in shader.bindings {sha_text(&hash,fmt.tprintf(" %d %v",binding.slot,binding.kind))}
        for constant in shader.constants {sha_text(&hash,fmt.tprintf(" %s",constant))}
        sha_text(&hash,"\n")
    }
    return sha_hex(&hash,allocator)
}

// The limits of the binding ABI the shaders are checked against.
@(private)
abi_text :: proc() -> string {
    return fmt.tprintf("%d;table;%d;%d;%d",TABLE_SLOT,TABLE_METAL_BUFFER,BUFFER_SLOTS,SAMPLER_SLOTS)
}

// The spirv-opt -O of SPIRV-Tools 2026.3 and 2026.4, which only the Metal
// build runs, falls with an invalid access on the SPIR-V of these stages: its
// loop unrolling uses a value before defining it and merge-blocks crashes on
// that. Compiled with -O1 they go through; remove the workaround when the SDK
// brings a fixed tool (KhronosGroup/SPIRV-Tools#7005).
@(private)
shader_reduced :: proc(name:string) -> bool {
    return strings.has_prefix(name,"fsr3_prepare_reactivity.") || strings.has_prefix(name,"fsr3_shading_change.") || strings.has_prefix(name,"direct_spread.")
}

// Whether the SPIR-V takes a pointer to a texel of an image (OpImageTexelPointer),
// which only atomics do.
@(private)
spirv_image_atomics :: proc(spirv:[]u8) -> bool {
    OP_IMAGE_TEXEL_POINTER :: 60
    words:=slice.reinterpret([]u32,spirv[:len(spirv)&~3])
    for i:=5;i<len(words); {
        count:=int(words[i]>>16)
        if words[i]&0xffff==OP_IMAGE_TEXEL_POINTER {return true}
        if count==0 {return false}
        i+=count
    }
    return false
}

// Which stages of a folder jobs_collect takes: all, those compiled for no
// program, or those compiled for one each.
@(private)
Collected :: enum u8 {All,Plain,Programs}

@(private)
jobs_collect :: proc(g:^Generation,jobs:^[dynamic]Job,source_dir,out,staging:string,previous:[]Shader,allocator:runtime.Allocator,engine:[]Shader=nil,collected:=Collected.All) -> (first,count:int) {
    first=len(jobs)
    for source in sources_in(&g.sources,source_dir,".slang",allocator) {
        stem,stage,is_stage:=stage_of(path_name(source))
        if !is_stage {continue}
        suffixes:=STAGE_SUFFIXES
        text:=string(sources_file(&g.sources,source).data)
        // A stage that runs Vfx or Surface programs: the stage itself, then once for each program
        // (<stem>__<program>), with the include of that program before those of the generation.
        // The stage itself of one per Surface program evaluates none (the include of the
        // generation): it is that of the materials without a program, unless the source
        // says it has none (`//! per surface program only`). One per vertex program is compiled
        // only for the Surface programs with a function vertex, with their include.
        Of :: struct {name,folder:string}
        per_surface:=strings.contains(text,"//! per surface program")
        per_vertex:=strings.contains(text,"//! per vertex program")
        only:=per_vertex || strings.contains(text,"//! per surface program only")
        programs:=make([dynamic]Of,context.temp_allocator)
        if collected!=.Programs && !only {append(&programs,Of{"",""})}
        if collected!=.Plain {
            if strings.contains(text,"//! per vfx program") {for name in g.vfx {append(&programs,Of{name,VFX_FOLDER})}}
            if per_surface {for name in g.surface {append(&programs,Of{name,SURFACE_FOLDER})}}
            if per_vertex {for name in g.vertex {append(&programs,Of{name,SURFACE_FOLDER})}}
        }
        declared:=constants(text,allocator)
        problem:=constants_problem(declared,allocator)
        constant_names:=make([]string,len(declared),allocator)
        constant_defines:=make([]string,len(declared),allocator)
        for constant,id in declared {
            constant_names[id]=constant.name
            constant_defines[id]=fmt.aprintf("%s="+CONSTANT_SYMBOL,constant.define,id,allocator=allocator)
        }
        for program in programs do for variant in variants(text,allocator) {
            named:=stem if program.name=="" else fmt.tprintf("%s__%s",stem,program.name)
            name:=fmt.aprintf("%s%s%s%s",named,"_" if variant.name!="" else "",variant.name,suffixes[stage],allocator=allocator)
            itself:=name if program.name=="" else fmt.aprintf("%s%s%s%s",stem,"_" if variant.name!="" else "",variant.name,suffixes[stage],allocator=allocator)
            includes:=g.includes
            if program.folder!="" {
                own:=make([dynamic]string,allocator)
                append(&own,path_join(g.includes[0],program.folder,allocator=allocator) if program.name=="" else path_join(g.includes[0],program.folder,program.name,allocator=allocator))
                append(&own,..g.includes)
                includes=own[:]
            }
            defines:=make([dynamic]string,allocator)
            append(&defines,..variant.defines)
            append(&defines,..constant_defines)
            job:=Job{source=source,name=name,stage=itself,defines=defines[:],constants=constant_names,includes=includes,bases=g.bases,out=out,staging=staging,reduced=shader_reduced(name),backends=g.backends}
            if software_rays(text,variant) {job.backends-={.Metal}}
            if problem!="" {job.error=fmt.aprintf("%s: %s",name,problem,allocator=allocator)}
            for &built in engine {
                if built.name!=name {continue}
                // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
                job.engine=built
                job.has_engine=shader_valid(built)
            }
            for &prior in previous {
                if prior.name!=name {continue}
                // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
                job.prior=prior
                job.has_prior=shader_valid(prior)
            }
            append(jobs,job)
        }
    }
    return first,len(jobs)-first
}

// Each stage is compiled against an extensions.slang with only the features
// of the generation its sources name, and the frame fields of the extensions
// when a source of the project or a plugin is one of them, in a folder of its
// own before the include folder of the generation, named as the one it
// replaces. A stage with none of them has the digest it has in a generation
// without extensions. Before the stages run: it writes into staging.
@(private)
jobs_tailor :: proc(g:^Generation,extensions:Extensions,staging:string,allocator:runtime.Allocator) -> bool {
    Tailored :: struct {includes:[]string,bases:[]Base}
    tailored:[1<<len(Extension_Feature)]Tailored
    generated:=path_clean(path_join(g.includes[0],EXTENSIONS_INCLUDE,allocator=context.temp_allocator),allocator)
    // The folders of the project and its plugins, as they are and as staged.
    extension_folders:=make([dynamic]string,context.temp_allocator)
    for copy in g.copies[1:] {append(&extension_folders,copy.label,copy.path)}
    theirs :: proc(folders:[]string,path:string) -> bool {
        for folder in folders {
            if strings.has_prefix(path,folder) && (len(path)==len(folder) || path[len(folder)]=='/') {return true}
        }
        return false
    }
    // What extensions.slang includes: the sources of the frame fields, which
    // every stage that reads it reaches.
    declared:=make(map[string]bool,context.temp_allocator)
    for path in dependencies(generated,g.includes,context.temp_allocator,&g.sources) {declared[path]=true}
    for &job in g.jobs {
        features:Extension_Features
        reads:=false
        extended:=theirs(extension_folders[:],job.source)
        // Through its own includes: those of the program of a stage of one come first.
        for path in dependencies(job.source,job.includes,context.temp_allocator,&g.sources) {
            if path==generated {reads=true;continue}
            if path in declared {continue}
            features+=sources_file(&g.sources,path).macros
            extended||=theirs(extension_folders[:],path)
        }
        if extended {features+={.Frame_Extensions}}
        features&=g.features
        if !reads || features==g.features {continue}
        // A stage of a Vfx program keeps the include of its program before the tailored one.
        if len(job.includes)!=len(g.includes) {
            folder:=fmt.aprintf("%s/extensions-%d",staging,transmute(u8)features,allocator=allocator)
            os.make_directory_all(folder)
            if !write_file(path_join(folder,EXTENSIONS_INCLUDE,allocator=context.temp_allocator),extensions_text(extensions,features,context.temp_allocator)) {return false}
            includes:=make([dynamic]string,allocator)
            append(&includes,job.includes[0],folder)
            append(&includes,..g.includes)
            bases:=make([dynamic]Base,allocator)
            append(&bases,Base{"generated/include",folder})
            append(&bases,..g.bases)
            job.includes,job.bases=includes[:],bases[:]
            continue
        }
        slot:=&tailored[transmute(u8)features]
        if slot.includes==nil {
            folder:=fmt.aprintf("%s/extensions-%d",staging,transmute(u8)features,allocator=allocator)
            os.make_directory_all(folder)
            if !write_file(path_join(folder,EXTENSIONS_INCLUDE,allocator=context.temp_allocator),extensions_text(extensions,features,context.temp_allocator)) {return false}
            includes:=make([dynamic]string,allocator)
            append(&includes,folder)
            append(&includes,..g.includes)
            bases:=make([dynamic]Base,allocator)
            append(&bases,Base{"generated/include",folder})
            append(&bases,..g.bases)
            slot^={includes[:],bases[:]}
        }
        job.includes,job.bases=slot.includes,slot.bases
    }
    return true
}

// The jobs by when they run: the first stages, the others that are not idle,
// the idle ones and the tests. In each the costliest go first, by the bytes
// of the code of the stage the last time: the generation ends sooner.
@(private)
jobs_order :: proc(g:^Generation,allocator:runtime.Allocator) -> []int {
    Ranked :: struct {job:int,cost:i64}
    group :: proc(job:Job) -> int {
        switch {
        case job.first: return 0
        case job.active: return 1
        case job.idle: return 2
        }
        return 3
    }
    ranked:=make([]Ranked,len(g.jobs),context.temp_allocator)
    for &job,i in g.jobs {ranked[i]={i,job_cost(g,&job)}}
    slice.stable_sort_by(ranked,proc(a,b:Ranked) -> bool {return a.cost>b.cost})
    order:=make([]int,len(g.jobs),allocator)
    at:=0
    for each in 0..<4 {
        for rank in ranked {
            if group(g.jobs[rank.job])==each {order[at]=rank.job;at+=1}
        }
    }
    return order
}

// The bytes of the code of a stage as the output, or the build of the engine,
// has it; the most for one that neither has.
@(private)
job_cost :: proc(g:^Generation,job:^Job) -> i64 {
    entry,folder:=job.prior,job.out
    if !job.has_prior {entry,folder=job.engine,g.engine_build}
    name:=entry.spv if .Vulkan in job.backends else entry.msl
    if !job.has_prior && !job.has_engine || folder=="" || name=="" {return max(i64)}
    info,error:=os.stat(path_join(folder,name,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return max(i64)}
    return info.size
}

// The stages a job system compiles, in their order: each worker keeps what it
// made in an arena of its own until the generation ends.
@(private)
Stages_Work :: struct {
    generation:^Generation,
    arenas:    []virtual.Arena, // by worker
}

// Compiles the stages of the range unless the generation is cancelled. A
// stage that fails does not stop the others: what compiles is in the cache
// for the next generation.
@(private)
stages_run :: proc(work:^Stages_Work,first,last:int,worker:int) {
    g:=work.generation
    allocator:=virtual.arena_allocator(&work.arenas[worker])
    for at in first..<last {
        if runner_cancelled(g.runner) {return}
        job:=&g.jobs[g.order[at]]
        started:=time.tick_now()
        job_run(g,job,allocator)
        job.seconds=time.duration_seconds(time.tick_since(started))
        if job.first && sync.atomic_sub(&g.first_left,1)==1 && g.first_output!="" {early_write(g,g.first_output,&g.progress.first,false)}
        if job.active && sync.atomic_sub(&g.active_left,1)==1 && g.active_output!="" {early_write(g,g.active_output,&g.progress.active,true)}
    }
}

// The first stages compiled, or every stage but the idle ones (active): the
// folder gets a generation that loads alone, with the catalog and those
// stages of this one and every other stage as the output has it (or the build
// of the engine, for a stage the output does not have yet). Nothing is
// written without them all, but for a stage of a program that has none yet:
// its program draws once the whole generation is published. written marks it.
@(private)
early_write :: proc(g:^Generation,folder:string,written:^bool,active:bool) {
    if runner_cancelled(g.runner) {return}
    if os.exists(folder) && base.remove_all(folder)!=nil {return}
    if os.make_directory_all(folder)!=nil {return}
    entries:[3][dynamic]Shader
    for jobs,i in ([3][]Job{g.shader_jobs,g.program_jobs,g.extension_jobs}) {
        entries[i]=make([dynamic]Shader,0,len(jobs),context.temp_allocator)
        for job in jobs {
            entry:Shader
            source:string
            switch {
            case job.first || active && !job.idle: entry,source=job.result,job.staging
            case job.has_prior:  entry,source=shader_trim(job.prior,job.backends),job.out
            case job.has_engine: entry,source=shader_trim(job.engine,job.backends),g.engine_build
            case i==1: continue
            case: return
            }
            files,found:=artifacts_read(entry,entry.fingerprint,source,job.backends)
            if !found || !artifacts_stage(files,{.Vulkan=entry.spv,.Metal=entry.msl},folder,job.backends) {return}
            entry.staged=false
            append(&entries[i],entry)
        }
    }
    catalog,read_error:=os.read_entire_file(path_join(g.staging,abi.SHADER_CATALOG,allocator=context.temp_allocator),context.temp_allocator)
    if read_error!=nil || !write_file(path_join(folder,abi.SHADER_CATALOG,allocator=context.temp_allocator),catalog) {return}
    if !write_file(path_join(folder,abi.SHADER_MANIFEST,allocator=context.temp_allocator),manifest_text(g,entries[0][:],entries[1][:],entries[2][:],nil)) {return}
    sync.atomic_store(written,true)
}

// The manifest of a generation of these stages.
@(private)
manifest_text :: proc(g:^Generation,shaders,programs,extensions,tests:[]Shader) -> []u8 {
    manifest:=abi.Shader_Manifest{version=1,compiler=fmt.tprintf("%s; %s",g.version,g.metal_tools),engine=g.identity,catalog=g.catalog,shaders=shaders,program_stages=programs,extensions=extensions,tests=tests}
    text,_:=serial.text_encode(manifest,.Pretty,context.temp_allocator)
    return text
}

// The manifest of the generation in a folder; empty without one.
@(private)
manifest_read :: proc(folder:string,allocator:runtime.Allocator) -> (manifest:abi.Shader_Manifest) {
    data,error:=os.read_entire_file(path_join(folder,abi.SHADER_MANIFEST,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil || serial.text_decode(string(data),&manifest,allocator)!="" {return {}}
    return
}

@(private)
Publication :: struct {source,target,backup:string,saved,installed:bool}
@(private)
Publish_Move :: proc(old_path,new_path:string,user_data:rawptr) -> os.Error

// Each replacement is complete before it is visible. Keep the old output
// and tables until every rename succeeded, so a failed publish can roll back.
@(private)
publish :: proc(replacements:[]Publication,move:Publish_Move=nil,user_data:rawptr=nil) -> (published,recovered:bool) {
    rename :: proc(old_path,new_path:string,move:Publish_Move,user_data:rawptr) -> os.Error {
        if move!=nil {return move(old_path,new_path,user_data)}
        return os.rename(old_path,new_path)
    }
    failed:=false
    for &replacement in replacements {
        if os.exists(replacement.target) {
            if rename(replacement.target,replacement.backup,move,user_data)!=nil {failed=true;break}
            replacement.saved=true
        }
        if rename(replacement.source,replacement.target,move,user_data)!=nil {failed=true;break}
        replacement.installed=true
    }
    if !failed {return true,true}
    recovered=true
    for i:=len(replacements)-1;i>=0;i-=1 {
        replacement:=&replacements[i]
        if replacement.installed && base.remove_all(replacement.target)!=nil {recovered=false;continue}
        if replacement.saved && os.rename(replacement.backup,replacement.target)!=nil {recovered=false}
    }
    return false,recovered
}

// Generates the shaders of the engine, with the programs of a project when one
// is given. On failure the output keeps the previous generation whole and
// Result.error says why. The strings of the result are in `allocator`.
generate :: proc(options:Options,allocator:=context.allocator) -> (result:Result) {
    arena:virtual.Arena
    if virtual.arena_init_growing(&arena)!=nil {result.error=strings.clone("out of memory to generate shaders",allocator);return}
    defer virtual.arena_destroy(&arena)
    {
        // The scratch memory of the generation goes when it ends, before the
        // result is copied to an allocator that may be the temporary one.
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
        result=generate_staged(options,virtual.arena_allocator(&arena))
    }
    // What a cancelled tool said is not why the generation ended.
    if result.error!="" && options.progress!=nil && runner_cancelled(&options.progress.runner) {
        result.error,result.diagnostics,result.cancelled="the generation was cancelled",nil,true
    }
    result.engine=strings.clone(result.engine,allocator)
    result.warnings=strings.clone(result.warnings,allocator)
    result.refused=strings.clone(result.refused,allocator)
    result.error=strings.clone(result.error,allocator)
    result.diagnostics=diagnostics_clone(result.diagnostics,allocator)
    for &each in result.slowest {each.name=strings.clone(each.name,allocator)}
    return
}

// Whether generate(options) would find the published generation current: the
// same request, tools and sources as its stamp says. It takes no lock, runs
// no tool and writes nothing.
current :: proc(options:Options) -> bool {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    g:=new(Generation,context.temp_allocator)
    odin,request,problem:=generation_setup(g,options,context.temp_allocator)
    if problem!="" {return false}
    stamp,is_current:=stamp_current(g,request,context.temp_allocator)
    return is_current && (stamp.shipped || !options.ship || !odin)
}

// The folders, backends and tools of a generation, and the digest of what it
// is asked for. problem: why it cannot run.
@(private)
generation_setup :: proc(g:^Generation,options:Options,scratch:runtime.Allocator) -> (odin:bool,request,problem:string) {
    sources_init(&g.sources,scratch)
    g.root=path_clean(options.root,scratch)
    g.project=path_clean(options.project,scratch) if options.project!="" else ""
    switch {
    case options.output!="": g.output=path_clean(options.output,scratch)
    case g.project!="": g.output=path_join(g.project,PROJECT_OUTPUT,allocator=scratch)
    case: g.output=path_join(g.root,"shaders/build",allocator=scratch)
    }
    if engine_build:=path_join(g.root,"shaders/build",allocator=scratch);g.output!=engine_build {g.engine_build=engine_build}
    odin=options.odin && g.project=="" && len(options.sources)==0
    g.backends=options.backends if options.backends!={} else Backends{HOST_BACKEND}
    switch {
    case options.cache!="": g.cache=path_clean(options.cache,scratch)
    case g.project!="": g.cache=path_join(g.project,".mirai/shader-cache",allocator=scratch)
    case: g.cache=path_join(g.root,".mirai/shader-cache",allocator=scratch)
    }
    g.shared=workspace.cache_folder(g.root,CACHE_NAME,scratch)
    names:=TOOL_NAMES
    for &path,tool in g.tools {
        if options.tools[tool]!="" {path=path_clean(options.tools[tool],scratch);continue}
        found:bool
        path,found=tool_find(g.root,tool,scratch)
        if !found {
            hint:="run `mirai setup slang`" if tool==.Slangc else "install the Vulkan SDK or the prebuilt spirv-tools and spirv-cross packages"
            return odin,"",fmt.aprintf("%s not found: %s",names[tool],hint,allocator=scratch)
        }
    }
    return odin,request_digest(g,options.sources,odin,scratch),""
}

// The strings of the result are in `scratch`, as is everything the generation holds.
@(private)
generate_staged :: proc(options:Options,scratch:runtime.Allocator) -> (result:Result) {
    allocator:=scratch
    fail :: proc(result:^Result,allocator:runtime.Allocator,format:string,args:..any) {
        result.error=fmt.aprintf(format,..args,allocator=allocator)
    }

    g:=new(Generation,scratch)
    odin,request,setup_error:=generation_setup(g,options,scratch)
    if setup_error!="" {result.error=setup_error;return}
    // What the engine stages share with the engine is what the tables of the
    // engine say, and only its own generation writes them: any other is made
    // beside one of the same sources, which this leaves current, and names it.
    // Before its own turn: one into another folder of the engine has the same.
    if g.engine_build!="" {
        engine:=generate_staged({root=options.root,odin=true,workers=options.workers,tools=options.tools},scratch)
        if engine.error!="" {fail(&result,allocator,"the shaders of the engine: %s",engine.error);return}
        g.identity=engine.engine
    }
    g.progress=options.progress
    g.runner=&g.progress.runner if g.progress!=nil else &g.own_runner
    // Generations with one stamp publish into one output: they take turns.
    lock,locked:=workspace.lock_acquire(strings.concatenate({g.cache,".lock"},scratch),fmt.tprintf("pid %d",os.get_pid()))
    if !locked {fail(&result,allocator,"could not create %s",g.cache);return}
    defer workspace.lock_release(&lock)
    // A compiler older than the pinned one is replaced here: a generation with
    // it either fails with a reflection that says nothing of the cause, or
    // writes shaders the engine does not expect.
    if compiler,compiler_version,problem:=slang_ensure(g.root,g.tools[.Slangc],options.tools,g.runner,scratch);problem!="" {
        fail(&result,allocator,"%s",problem)
        return
    } else {
        g.tools[.Slangc],g.version=compiler,compiler_version
    }
    workers:=min(options.workers if options.workers>0 else max(os.get_processor_core_count(),1),RUNNER_CAPACITY)
    // A generation asked to ship goes on when the code it embeds was not encoded so.
    if stamp,is_current:=stamp_current(g,request,scratch);is_current && (stamp.shipped || !options.ship || !odin) {
        result.shaders,result.tests,result.programs=stamp.shaders,stamp.tests,stamp.programs
        result.reused,result.current=stamp.shaders+stamp.tests,true
        result.engine=stamp.engine
        return
    }
    strings.builder_init(&g.warnings,scratch)
    optimizer,optimizer_ran:=tool_run(g.runner,{g.tools[.Spirv_Opt],"--version"},scratch)
    cross,cross_ran:=tool_run(g.runner,{g.tools[.Spirv_Cross],"--revision"},scratch)
    if !optimizer_ran || !cross_ran {fail(&result,allocator,"could not run spirv-opt and spirv-cross");return}
    optimizer=strings.trim_space(optimizer)
    if line_end:=strings.index_byte(optimizer,'\n');line_end>=0 {optimizer=optimizer[:line_end]}
    g.metal_tools=fmt.aprintf("%s; SPIRV-Cross %s",strings.trim_right_space(optimizer),strings.trim_space(cross),allocator=scratch)

    if os.make_directory_all(g.output)!=nil && !os.is_directory(g.output) {fail(&result,allocator,"could not create %s",g.output);return}
    previous:=manifest_read(g.output,scratch)
    staging,staging_error:=os.make_directory_temp(path_parent(g.output),".mirai-shaders-*",scratch)
    if staging_error!=nil {fail(&result,allocator,"could not create the staging folder next to %s",g.output);return}
    staging=path_clean(staging,scratch)
    g.staging=staging
    cleanup:=true
    defer if cleanup {base.remove_all(staging)}

    copies:=make([dynamic]Base,scratch)
    programs_folder:=path_join(staging,"include/programs",allocator=scratch)
    append(&copies,Base{path_join(g.root,"shaders/materials",allocator=scratch),path_join(programs_folder,"builtin",allocator=scratch)})
    if g.project!="" {append(&copies,Base{path_join(g.project,"shaders",allocator=scratch),path_join(programs_folder,"project",allocator=scratch)})}
    for source in options.sources {append(&copies,Base{path_clean(source.folder,scratch),path_join(programs_folder,"plugins",source.name,allocator=scratch)})}
    g.copies=copies[:]
    reflection_started:=time.tick_now()
    catalog,catalog_error:=programs_generate(g.runner,g.root,g.project,staging,g.tools[.Slangc],g.version,path_join(g.shared,CACHE_REFLECTION,allocator=scratch),options.sources,scratch,&g.sources,workers)
    if catalog_error!="" {
        diagnostics_place(result.diagnostics,g.copies,{g.project,g.root},scratch)
        fail(&result,allocator,"%s",len(result.diagnostics)>0?diagnostics_text(result.diagnostics,scratch):catalog_error)
        return
    }
    result.reflection=time.duration_seconds(time.tick_since(reflection_started))
    extensions,extensions_error:=extensions_generate(g.runner,g.root,g.project,staging,g.tools[.Slangc],options.sources,&g.sources,scratch)
    if extensions_error!="" {fail(&result,allocator,"%s",extensions_error);return}
    catalog.extensions=extensions
    result.refused=strings.join(catalog.refused,"\n",allocator)
    g.features=extensions_features(extensions)
    if !write_file(path_join(staging,abi.SHADER_CATALOG,allocator=scratch),catalog_text(catalog)) {fail(&result,allocator,"could not write %s",abi.SHADER_CATALOG);return}
    includes:=make([dynamic]string,scratch)
    append(&includes,path_join(staging,"include",allocator=scratch))
    for folder in ENGINE_INCLUDES {append(&includes,path_join(g.root,folder,allocator=scratch))}
    bases:=make([dynamic]Base,scratch)
    append(&bases,Base{"generated",staging})
    if g.project!="" {
        append(&includes,path_join(g.project,"shaders",allocator=scratch))
        append(&bases,Base{"project",g.project})
    }
    for source in options.sources {
        folder:=path_clean(source.folder,scratch)
        if !os.is_directory(folder) {continue}
        append(&includes,folder)
        append(&bases,Base{strings.concatenate({"plugins/",source.name},scratch),folder})
    }
    append(&bases,Base{"engine",g.root})
    g.includes,g.bases=includes[:],bases[:]
    g.catalog,g.vfx,g.surface,g.vertex=catalog.fingerprint,catalog.vfx,catalog.surface,catalog.vertex
    // The tools after Slang shape the Metal output of a shader, not what a
    // generation shares with the engine: they are of each shader's digest.
    {
        hash:Sha256
        sha_begin(&hash)
        for text in ([]string{GENERATOR_CONTRACT,g.version,g.metal_tools,abi_text(),material_schema(),shared_constants()}) {sha_text(&hash,text);sha_text(&hash,"\n")}
        for flags in ([][]string{SLANG_FLAGS,SLANG_OPTIMIZATION,SPIRV_FLAGS,VALIDATE_FLAGS,OPTIMIZE_FLAGS,METAL_FLAGS}) {sha_text(&hash,strings.join(flags," ",context.temp_allocator));sha_text(&hash,"\n")}
        g.configuration=transmute([]u8)sha_hex(&hash,scratch)
    }
    g.tests_folder=path_join(g.root,"shaders/tests",allocator=scratch)
    jobs:=make([dynamic]Job,scratch)
    tests_out:=path_join(g.output,"tests",allocator=scratch)
    staging_shaders:=path_join(staging,"shaders",allocator=scratch)
    staging_tests:=path_join(staging_shaders,"tests",allocator=scratch)
    os.make_directory_all(staging_shaders)
    engine_manifest:abi.Shader_Manifest
    if g.engine_build!="" {engine_manifest=manifest_read(g.engine_build,scratch)}
    engine_shaders:=path_join(g.root,"shaders",allocator=scratch)
    shader_first,shader_count:=jobs_collect(g,&jobs,engine_shaders,g.output,staging_shaders,previous.shaders,scratch,engine_manifest.shaders,.Plain)
    // The stages of the engine compiled for each program, which the renderer finds by name.
    program_first,program_count:=jobs_collect(g,&jobs,engine_shaders,g.output,staging_shaders,previous.program_stages,scratch,engine_manifest.program_stages,.Programs)
    // The stages the project and its plugins bring.
    extension_first:=len(jobs)
    for entry in extension_folders(&g.sources,g.project,options.sources,scratch) {
        jobs_collect(g,&jobs,entry.folder,g.output,staging_shaders,previous.extensions,scratch)
    }
    extension_count:=len(jobs)-extension_first
    test_first,test_count:=0,0
    if odin {
        os.make_directory_all(staging_tests)
        test_first,test_count=jobs_collect(g,&jobs,g.tests_folder,tests_out,staging_tests,previous.tests,scratch)
    }
    g.jobs=jobs[:]
    if g.features!={} && !jobs_tailor(g,extensions,staging,scratch) {fail(&result,allocator,"could not write %s of the stages",EXTENSIONS_INCLUDE);return}
    shader_jobs:=g.jobs[shader_first:][:shader_count]
    program_jobs:=g.jobs[program_first:][:program_count]
    extension_jobs:=g.jobs[extension_first:][:extension_count]
    test_jobs:=g.jobs[test_first:][:test_count]
    g.shader_jobs,g.program_jobs,g.extension_jobs=shader_jobs,program_jobs,extension_jobs
    idle:=0
    // A stage of a program is first or idle with the stage it is of.
    for &job in g.jobs[:extension_first+extension_count] {
        for name in options.first {job.first||=job.stage==name}
        for name in options.idle {job.idle||=!job.first && job.stage==name}
        job.active=!job.idle
        if job.first {g.first_left+=1}
        if job.active {g.active_left+=1} else {idle+=1}
    }
    g.order=jobs_order(g,scratch)
    if g.first_left>0 && options.first_output!="" {g.first_output=path_clean(options.first_output,scratch)}
    if idle>0 && options.active_output!="" {g.active_output=path_clean(options.active_output,scratch)}
    // How Slang lays out the structs shaders share with the CPU.
    {
        probe:=path_join(staging,"layouts_probe.slang",allocator=scratch)
        reflection:=path_join(staging,"layouts_probe.json",allocator=scratch)
        if !write_file(probe,transmute([]u8)layouts_probe_source(scratch)) {fail(&result,allocator,"could not write the probe of the shared structs");return}
        command:=make([dynamic]string,scratch)
        append(&command,g.tools[.Slangc],probe)
        append(&command,..SLANG_FLAGS)
        append(&command,"-stage","compute")
        for directory in g.includes {append(&command,"-I",directory)}
        append(&command,..SPIRV_FLAGS)
        append(&command,"-o",path_join(staging,"layouts_probe.spv",allocator=scratch),"-reflection-json",reflection)
        output,ran:=tool_run(g.runner,command[:],scratch)
        data,readable:=read_json(reflection,scratch)
        if !ran || !readable {fail(&result,allocator,"could not compile the probe of the shared structs: %s",output);return}
        g.layouts=layouts_reflected(data,scratch)
    }

    // What a worker made lives in its arena, which goes with the generation.
    stage_arenas:[]virtual.Arena
    defer for &arena in stage_arenas {virtual.arena_destroy(&arena)}
    {
        js:job_system.Job_System
        if !job_system.system_init(&js,{threads=min(workers,max(len(g.jobs),1))-1}) {fail(&result,allocator,"could not start the threads that compile the stages");return}
        defer job_system.system_destroy(&js)
        stage_arenas=make([]virtual.Arena,len(js.workers),scratch)
        for &arena in stage_arenas {
            if virtual.arena_init_growing(&arena)!=nil {fail(&result,allocator,"could not reserve the memory the stages are compiled in");return}
        }
        work:=Stages_Work{g,stage_arenas}
        job_system.parallel_for(&js,job_system.OWNER,len(g.order),1,stages_run,&work)
    }
    result.warnings=strings.clone(strings.to_string(g.warnings),allocator)
    if runner_cancelled(g.runner) {fail(&result,allocator,"the generation was cancelled");return}
    for job in g.jobs {
        if job.error!="" {fail(&result,allocator,"%s",job.error);result.diagnostics=diagnostics_clone(job.diagnostics,allocator);return}
        if job.result.name=="" {fail(&result,allocator,"%s: was not compiled",job.source);return}
        if job.reused {result.reused+=1;continue}
        result.compiled+=1
        result.compiling+=job.seconds
        // Kept longest first.
        at:=SLOWEST
        for at>0 && result.slowest[at-1].seconds<job.seconds {at-=1}
        if at==SLOWEST {continue}
        copy(result.slowest[at+1:],result.slowest[at:SLOWEST-1])
        result.slowest[at]={job.name,job.seconds}
    }

    for job,i in extension_jobs {
        for other in shader_jobs {if other.result.name==job.result.name {fail(&result,allocator,"%s: the engine has a stage of that name",job.source);return}}
        for other in program_jobs {if other.result.name==job.result.name {fail(&result,allocator,"%s: the engine has a stage of that name",job.source);return}}
        for other in extension_jobs[:i] {if other.result.name==job.result.name {fail(&result,allocator,"%s: another extension has a stage of that name",job.source);return}}
    }
    out_include:=path_join(g.output,"include",allocator=scratch)
    if os.rename(path_join(staging,"include",allocator=scratch),path_join(staging_shaders,"include",allocator=scratch))!=nil || os.rename(path_join(staging,abi.SHADER_CATALOG,allocator=scratch),path_join(staging_shaders,abi.SHADER_CATALOG,allocator=scratch))!=nil {
        fail(&result,allocator,"could not prepare the catalog in %s",staging)
        return
    }
    outputs:=make([dynamic]string,scratch)
    replacements:=make([dynamic]Publication,scratch)
    tables_folder:string
    defer if cleanup && tables_folder!="" {base.remove_all(tables_folder)}
    shipped:=false
    compiled:[4][]Shader
    for jobs,i in ([4][]Job{shader_jobs,program_jobs,extension_jobs,test_jobs}) {
        compiled[i]=make([]Shader,len(jobs),scratch)
        for job,at in jobs {compiled[i][at]=job.result}
    }
    if g.engine_build=="" {g.identity=engine_interface(g,compiled[0],scratch)}
    identity:=g.identity
    if odin {
        assertions:=strings.builder_make(scratch)
        if problem:=layouts_assertions(&assertions,g.layouts);problem!="" {fail(&result,allocator,"%s",problem);return}
        shipped=true
        names:=EMBEDDED_NAMES
        for backend in g.backends {
            packed,packed_shipped,problem:=embedded_pack(g,{shader_jobs,program_jobs},backend,options.ship,scratch)
            if problem!="" {fail(&result,allocator,"%s",problem);return}
            if !write_file(path_join(staging_shaders,names[backend],allocator=scratch),packed) {fail(&result,allocator,"could not write %s",names[backend]);return}
            shipped&&=packed_shipped
        }
        render_table:=odin_table(shader_jobs,g.backends,g.output,path_join(g.root,"render",allocator=scratch),"mirai_render","mirai:rhi",identity,"",strings.to_string(assertions),scratch,program_jobs,true,true)
        rhi_table:=odin_table(test_jobs,g.backends,tests_out,path_join(g.root,"rhi",allocator=scratch),"rhi","","","TEST_SHADERS","",scratch)
        tables:=[2]string{path_join(g.root,"render/shaders_gen.odin",allocator=scratch),path_join(g.root,"rhi/shaders_gen_test.odin",allocator=scratch)}
        for bytes,i in ([2][]u8{render_table,rhi_table}) {
            if written,read_error:=os.read_entire_file(tables[i],scratch);read_error==nil && string(written)==string(bytes) {continue}
            if tables_folder=="" {
                folder,err:=os.make_directory_temp(g.root,".mirai-shader-tables-*",scratch)
                if err!=nil {fail(&result,allocator,"could not prepare the Odin tables");return}
                tables_folder=path_clean(folder,scratch)
            }
            name:=fmt.tprintf("table-%d",i)
            source,backup:=path_join(tables_folder,name,allocator=scratch),path_join(tables_folder,strings.concatenate({name,".previous"},scratch),allocator=scratch)
            if !write_file(source,bytes) {fail(&result,allocator,"could not write the Odin table %s",tables[i]);return}
            append(&replacements,Publication{source=source,target=tables[i],backup=backup})
        }
        append(&outputs,..tables[:])
    }
    // A generation equal to the published one leaves its manifest alone: whoever watches it sees no change.
    manifest_path:=path_join(g.output,abi.SHADER_MANIFEST,allocator=scratch)
    manifest:=manifest_text(g,compiled[0],compiled[1],compiled[2],compiled[3])
    if !write_file(path_join(staging_shaders,abi.SHADER_MANIFEST,allocator=scratch),manifest) {fail(&result,allocator,"could not prepare the manifest of %s",g.output);return}
    if !generation_matches(staging_shaders,g.output) {
        inject_at(&replacements,0,Publication{source=staging_shaders,target=g.output,backup=path_join(staging,"previous",allocator=scratch)})
        result.changed=true
    }
    if ready,recovered:=publish(replacements[:]);!ready {
        cleanup=recovered
        result.changed=false
        if recovered {fail(&result,allocator,"could not publish the generation in %s: the previous one was restored",g.output)}
        else {fail(&result,allocator,"could not restore the generation: the previous copies are in %s and %s",staging,tables_folder)}
        return
    }
    result.shaders,result.tests,result.programs=shader_count+program_count+extension_count,test_count,len(catalog.programs)
    result.engine=strings.clone(identity,allocator)
    append(&outputs,manifest_path,path_join(g.output,abi.SHADER_CATALOG,allocator=scratch))
    for name in ([]string{SURFACE_INCLUDE,SURFACE_COVERAGE_INCLUDE,POSTPROCESS_INCLUDE,VFX_INCLUDE,UI_INCLUDE,EXTENSIONS_INCLUDE,HOOKS_INCLUDE,SCHEMA_INCLUDE,CONSTANTS_INCLUDE}) {append(&outputs,path_join(out_include,name,allocator=scratch))}
    for job,at in g.jobs {
        folder:=tests_out if at>=test_first && at<test_first+test_count else g.output
        for name in ([]string{job.result.spv,job.result.msl}) {
            if name!="" {append(&outputs,path_join(folder,name,allocator=scratch))}
        }
    }
    if odin {
        names:=EMBEDDED_NAMES
        for backend in g.backends {append(&outputs,path_join(g.output,names[backend],allocator=scratch))}
    }
    // Without a stamp the next generation looks at every stage again.
    stamp_write(g,request,staging,outputs[:],{slang=g.version,metal_tools=g.metal_tools,shaders=shader_count+program_count+extension_count,tests=test_count,programs=len(catalog.programs),engine=identity,shipped=shipped})
    if result.compiled>0 {cache_prune(g.shared,time.now())}
    return
}

@(private)
generation_matches :: proc(staging,output:string) -> bool {
    next:=listing_read(staging,true,context.temp_allocator)
    current:=listing_read(output,true,context.temp_allocator)
    if len(next.files)!=len(current.files) {return false}
    for source,i in next.files {
        relative,_:=path_relative(source,staging)
        previous,_:=path_relative(current.files[i],output)
        if relative!=previous {return false}
        a,a_error:=os.read_entire_file(source,context.temp_allocator)
        b,b_error:=os.read_entire_file(current.files[i],context.temp_allocator)
        if a_error!=nil || b_error!=nil || string(a)!=string(b) {return false}
    }
    return true
}

// The Odin table of a set of shaders: an enum of their names and, for each
// backend compiled, their embedded code with the bindings Slang reflected. The
// system of a backend that was not compiled gets a compile-time error that
// says how to have it. guard: the constant without which the package builds
// without the table. appended: text after the table (the layout assertions
// of the shared structs). programs: with program_table, the stages compiled
// for one program each, in PROGRAM_SHADERS, which the renderer finds by name.
// packed: the code of the stages of jobs and then of programs is the file
// EMBEDDED_NAMES names, which says the size of each and which a procedure of
// the package returns (shaders_packed): a value would be in the declarations
// of the package, and whatever compiles against them would follow the code.
// Nothing in the table follows the code of a stage then: it is their
// interface, which engine names (engine_interface).
@(private)
odin_table :: proc(jobs:[]Job,backends:Backends,out,target_folder,package_name,rhi_import,engine,guard,appended:string,allocator:=context.allocator,programs:[]Job=nil,program_table:=false,packed:=false) -> []u8 {
    relative:=path_from(out,target_folder,context.temp_allocator)
    prefix:="rhi." if rhi_import!="" else ""
    code :: proc(b:^strings.Builder,shader:Shader,metal:bool,relative,prefix:string,packed:bool) {
        switch {
        case packed && metal: fmt.sbprintf(b,"{{binary = {{msl_entry = \"%s\"}}, ",shader.entry)
        case packed, metal && shader.msl=="": strings.write_string(b,"{")
        case metal: fmt.sbprintf(b,"{{binary = {{msl = #load(\"%s/%s\", string), msl_entry = \"%s\"}}, ",relative,shader.msl,shader.entry)
        case: fmt.sbprintf(b,"{{binary = {{spirv = #load(\"%s/%s\")}}, ",relative,shader.spv)
        }
        fmt.sbprintf(b,"name = \"%s\", stage = .%v,\n",shader.name,shader.stage)
        fmt.sbprintf(b,"\t\t\tthreadgroup = {{%d, %d, %d}}, bindings = []%sBinding_Info{{",shader.group[0],shader.group[1],shader.group[2],prefix)
        for binding,i in shader.bindings {
            if i>0 {strings.write_string(b,", ")}
            fmt.sbprintf(b,"{{slot = %d, kind = .%s, stages = {{.%v}}}}",binding.slot,binding.kind,shader.stage)
        }
        strings.write_string(b,"}")
        if len(shader.constants)>0 {
            strings.write_string(b,", constants = []string{")
            for constant,i in shader.constants {fmt.sbprintf(b,"%s\"%s\"",", " if i>0 else "",constant)}
            strings.write_string(b,"}")
        }
        strings.write_string(b,"},\n")
    }
    b:=strings.builder_make(allocator)
    fmt.sbprintf(&b,"// Code generated by mirai shaders. DO NOT EDIT.\npackage %s\n\n",package_name)
    if rhi_import!="" {fmt.sbprintf(&b,"import \"%s\"\n\n",rhi_import)}
    if guard!="" {fmt.sbprintf(&b,"when %s {{\n\n",guard)}
    if engine!="" {
        strings.write_string(&b,"// Of what these stages share with the engine: their bindings, their constants and\n// the structs both read. A shader generation is loaded only while its manifest\n// names the same one, whatever the code of its stages.\n")
        fmt.sbprintf(&b,"SHADERS_INTERFACE :: \"%s\"\n\n",engine)
    }
    strings.write_string(&b,"Shader_Id :: enum u8 {\n")
    for job in jobs {fmt.sbprintf(&b,"\t%s,\n",job.result.id)}
    strings.write_string(&b,"}\n\n")
    // The constants of each source, which its variants and the stages of its programs share.
    {
        seen:=make(map[string]bool,context.temp_allocator)
        any:=false
        for job in jobs {
            if len(job.constants)==0 || job.source in seen {continue}
            seen[job.source]=true
            if !any {strings.write_string(&b,"// The ids of the constants of the stages (`//! constant`), for the constants of a pipeline.\n")}
            any=true
            stem,stage,_:=stage_of(path_name(job.source))
            suffixes:=STAGE_SUFFIXES
            for constant,id in job.constants {
                fmt.sbprintf(&b,"%s_%s :: %d\n",strings.to_upper(identifier(strings.concatenate({stem,suffixes[stage]},context.temp_allocator),context.temp_allocator),context.temp_allocator),strings.to_upper(identifier(constant,context.temp_allocator),context.temp_allocator),id)
            }
        }
        if any {strings.write_string(&b,"\n")}
    }
    fmt.sbprintf(&b,"when %sSHADER_FORMAT == .Msl {{\n",prefix)
    names:=EMBEDDED_NAMES
    for metal in ([]bool{true,false}) {
        if !metal {strings.write_string(&b,"} else {\n")}
        backend:=Backend.Metal if metal else Backend.Vulkan
        if backend not_in backends {
            fmt.sbprintf(&b,"\t#panic(\"the shaders were generated without %s code: run `mirai shaders --backends all`\")\n","Metal" if metal else "SPIR-V")
            continue
        }
        if packed {fmt.sbprintf(&b,"\t@(private)\n\tshaders_packed :: proc \"contextless\" () -> []u8 {{return #load(\"%s/%s\")}}\n",relative,names[backend])}
        fmt.sbprintf(&b,"\t@(rodata)\n\tSHADERS := [Shader_Id]%sShader_Code{{\n",prefix)
        for job in jobs {
            fmt.sbprintf(&b,"\t\t.%s = ",job.result.id)
            code(&b,job.result,metal,relative,prefix,packed)
        }
        strings.write_string(&b,"\t}\n")
        if program_table {
            fmt.sbprintf(&b,"\t@(rodata)\n\tPROGRAM_SHADERS := [%d]%sShader_Code{{\n",len(programs),prefix)
            for job in programs {
                strings.write_string(&b,"\t\t")
                code(&b,job.result,metal,relative,prefix,packed)
            }
            strings.write_string(&b,"\t}\n")
        }
    }
    strings.write_string(&b,"}\n")
    if guard!="" {strings.write_string(&b,"}\n")}
    strings.write_string(&b,appended)
    return b.buf[:]
}
