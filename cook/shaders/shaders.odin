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
import "core:thread"
import "core:time"
import "mirai:cook/workspace"
import "mirai:rhi"

// Names what the generator produces from a given source and compiler. It is
// part of every fingerprint: raise it when the outputs change for a reason the
// fingerprints do not see (another flag is already seen, as are the tools).
GENERATOR_CONTRACT :: "mirai-shaders/5"

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

// A source read from memory instead of its file: what an editor changed and
// did not save. It keeps the name of its file, so what it compiles to is what
// the file compiles to once it holds the same.
Overlay :: struct {
    path:   string, // of the file
    data:   []u8,
    removed:bool,   // there is no such file now
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
    overlay: []Overlay, // sources read from memory instead of their files; a stage that reads one from its folder fails
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
    engine:  string,     // identity of the engine sources the generation was compiled from
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
    next_job:     int, // atomic, into order
    first_left:   int, // atomic: first stages still to compile
    first_output: string,
    active_left:  int, // atomic: stages that are not idle still to compile
    active_output:string,
    progress:     ^Progress,
    shader_jobs,extension_jobs:[]Job,
    program_jobs: []Job, // the stages of the engine compiled for one program each, by name outside Shader_Id
    identity:     string, // of the engine sources, as the manifest names it
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
    variant:  string,
    defines:  []string,
    includes: []string, // those of the generation, or before them a folder with the extensions.slang of the stage
    bases:    []Base,
    out,staging:string,
    reduced:  bool, // compiled with -O1 instead of SLANG_OPTIMIZATION: a SPIRV-Tools bug needs it
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

// The source itself and one compilation more for each `//! variant name DEFINE...` line.
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
    configuration:=make([dynamic]u8,context.temp_allocator)
    append(&configuration,..g.configuration)
    append(&configuration,..transmute([]u8)strings.join(job.defines,"\n",context.temp_allocator))
    if job.reduced {append(&configuration,"-O1")}
    digest:=fingerprint(job.source,job.includes,job.bases,configuration[:],allocator,&g.sources)
    vulkan,metal:=.Vulkan in g.backends,.Metal in g.backends
    spv_name:=strings.concatenate({name,".spv"},allocator) if vulkan else ""
    msl_name:=strings.concatenate({name,".metal"},allocator) if metal else ""
    names:=[Backend]string{.Vulkan=spv_name,.Metal=msl_name}
    if stored,files,found:=cache_stage_read(g.shared,digest,g.backends,allocator);found && artifacts_stage(files,names,job.staging,g.backends) {
        stored.id,stored.name,stored.spv,stored.msl=identifier(name,allocator),name,spv_name,msl_name
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        job.result=shader_trim(stored,g.backends)
        job.reused=true
        job.result.staged=true
        return
    }
    if job.has_prior {
        if files,found:=artifacts_read(job.prior,digest,job.out,g.backends);found && artifacts_stage(files,names,job.staging,g.backends) {
            // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
            job.result=shader_trim(job.prior,g.backends)
            job.reused=true
            job.result.staged=true
            cache_stage_write(g.shared,job.result,files,g.backends)
            return
        }
    }

    if read:=overlay_read(g,job);read!="" {
        job_fail(job,allocator,"%s: it includes %s, which has unsaved changes that Slang would not see in its file; save it first",name,read)
        return
    }
    spv:=path_join(job.staging,spv_name,allocator=context.temp_allocator)
    msl:=path_join(job.staging,msl_name,allocator=context.temp_allocator)
    temporary,temporary_error:=os.make_directory_temp("","mirai-shader-*",context.temp_allocator)
    if temporary_error!=nil {job_fail(job,allocator,"%s: could not create a temporary folder",name);return}
    temporary=path_clean(temporary,context.temp_allocator)
    defer os.remove_all(temporary)
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
        bindings=resources,group=group,fingerprint=digest,staged=true,
        spv_hash=sha_of(spv_bytes,allocator) if vulkan else "",msl_hash=sha_of(metal_bytes,allocator) if metal else "",
    }
    cache_stage_write(g.shared,job.result,{.Vulkan=spv_bytes,.Metal=metal_bytes},g.backends)
}

// A source of the overlay that Slang would read from its file to compile a
// stage: the stage itself, or what its literal includes and imports reach
// outside the copies of the programs. Compiled, it would be stored under what
// the overlay holds. "" when there is none.
@(private)
overlay_read :: proc(g:^Generation,job:^Job) -> string {
    if len(g.sources.overlay)==0 {return ""}
    disk:Sources
    sources_init(&disk,context.temp_allocator)
    for path in dependencies(job.source,job.includes,context.temp_allocator,&disk,literal=true) {
        if path in g.sources.overlay {return stable_name(path,g.bases,context.temp_allocator)}
    }
    return ""
}

// Identity of the engine's own shader sources, the compiler and the generator:
// what the structures and passes of a build of the engine go with. It does not
// depend on the programs of a project or on the folder a generation is staged in.
engine_fingerprint :: proc(root,version:string,include_dirs:[]string,allocator:=context.allocator,sources:^Sources=nil) -> string {
    local:Sources
    s:=sources
    if s==nil {
        sources_init(&local,context.temp_allocator)
        s=&local
    }
    shader_root:=path_join(root,"shaders",allocator=context.temp_allocator)
    build:=path_join(shader_root,"build",allocator=context.temp_allocator)
    generated:=path_clean(include_dirs[0],context.temp_allocator) if len(include_dirs)>0 else ""
    found:=make(map[string]bool,context.temp_allocator)
    top:=sources_in(s,shader_root,".slang",context.temp_allocator)
    for path in top {found[path]=true}
    for folder in ([]string{"include","materials"}) {
        for path in sources_below(s,path_join(shader_root,folder,allocator=context.temp_allocator)) {found[path]=true}
    }
    for source in top {
        for path in dependencies(source,include_dirs,context.temp_allocator,s) {
            if path_inside(path,shader_root) && !path_inside(path,build) && !(generated!="" && path_inside(path,generated)) {found[path]=true}
        }
    }
    ordered:=make([dynamic]string,context.temp_allocator)
    for path in found {append(&ordered,path)}
    sort_paths(ordered[:])
    hash:Sha256
    sha_begin(&hash)
    sha_text(&hash,GENERATOR_CONTRACT)
    sha_text(&hash,abi_text())
    sha_text(&hash,material_schema())
    sha_text(&hash,strings.join(SLANG_FLAGS," ",context.temp_allocator))
    sha_text(&hash,strings.join(SLANG_OPTIMIZATION," ",context.temp_allocator))
    sha_text(&hash,strings.join(SPIRV_FLAGS," ",context.temp_allocator))
    sha_text(&hash,version)
    for path in ordered {
        relative,_:=path_relative(path,root)
        sha_text(&hash,relative)
        sha_bytes(&hash,sources_file(s,path).data)
    }
    return sha_hex(&hash,allocator)
}

// The limits of the binding ABI the shaders are checked against.
@(private)
abi_text :: proc() -> string {
    return fmt.tprintf("%d;table;%d;%d;%d",TABLE_SLOT,TABLE_METAL_BUFFER,BUFFER_SLOTS,SAMPLER_SLOTS)
}

@(private)
sort_paths :: proc(paths:[]string) {
    // Insertion by component order; the lists are a few hundred paths.
    for i in 1..<len(paths) {
        for j:=i;j>0 && path_less(paths[j],paths[j-1]);j-=1 {paths[j],paths[j-1]=paths[j-1],paths[j]}
    }
}

// SPIRV-Tools 2026.3 and 2026.4 fall with an invalid access when they
// optimize the SPIR-V of these two FSR 3.1 passes with -O2 or above. -O1 keeps
// the Metal build working; remove the workaround when the SDK brings a fixed
// tool (KhronosGroup/SPIRV-Tools#7005).
@(private)
shader_reduced :: proc(name:string) -> bool {
    return strings.has_prefix(name,"fsr3_prepare_reactivity.") || strings.has_prefix(name,"fsr3_shading_change.")
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
jobs_collect :: proc(g:^Generation,jobs:^[dynamic]Job,source_dir,out,staging:string,previous:json.Object,key:string,allocator:runtime.Allocator,engine:json.Object=nil,collected:=Collected.All) -> (first,count:int) {
    first=len(jobs)
    entries,_:=previous[key].(json.Array)
    engine_entries,_:=engine[key].(json.Array)
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
            job:=Job{source=source,name=name,stage=itself,variant=strings.clone(variant.name,allocator),defines=variant.defines,includes=includes,bases=g.bases,out=out,staging=staging,reduced=shader_reduced(name)}
            for value in engine_entries {
                object,is_object:=value.(json.Object)
                if !is_object || json_text(object["name"])!=name {continue}
                built,valid:=shader_from_json(object,allocator)
                // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
                job.engine=built
                job.has_engine=valid
            }
            for value in entries {
                object,is_object:=value.(json.Object)
                if !is_object || json_text(object["name"])!=name {continue}
                prior,valid:=shader_from_json(object,allocator)
                // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
                job.prior=prior
                job.has_prior=valid
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
    name:=entry.spv if .Vulkan in g.backends else entry.msl
    if !job.has_prior && !job.has_engine || folder=="" || name=="" {return max(i64)}
    info,error:=os.stat(path_join(folder,name,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return max(i64)}
    return info.size
}

@(private)
Worker :: struct {
    generation:^Generation,
    arena:     virtual.Arena,
    thread:    ^thread.Thread,
}

// Takes the next stage until there are none or the generation is cancelled.
// A stage that fails does not stop the others: what compiles is in the
// cache for the next generation.
@(private)
worker_run :: proc(worker:^Worker) {
    g:=worker.generation
    allocator:=virtual.arena_allocator(&worker.arena)
    for {
        if runner_cancelled(g.runner) {return}
        at:=sync.atomic_add(&g.next_job,1)
        if at>=len(g.order) {return}
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
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
    if os.exists(folder) && os.remove_all(folder)!=nil {return}
    if os.make_directory_all(folder)!=nil {return}
    entries:[3][dynamic]Shader
    for jobs,i in ([3][]Job{g.shader_jobs,g.program_jobs,g.extension_jobs}) {
        entries[i]=make([dynamic]Shader,0,len(jobs),context.temp_allocator)
        for job in jobs {
            entry:Shader
            source:string
            switch {
            case job.first || active && !job.idle: entry,source=job.result,job.staging
            case job.has_prior:  entry,source=shader_trim(job.prior,g.backends),job.out
            case job.has_engine: entry,source=shader_trim(job.engine,g.backends),g.engine_build
            case i==1: continue
            case: return
            }
            files,found:=artifacts_read(entry,entry.fingerprint,source,g.backends)
            if !found || !artifacts_stage(files,{.Vulkan=entry.spv,.Metal=entry.msl},folder,g.backends) {return}
            entry.staged=false
            append(&entries[i],entry)
        }
    }
    catalog,read_error:=os.read_entire_file(path_join(g.staging,"catalog.json",allocator=context.temp_allocator),context.temp_allocator)
    if read_error!=nil || !write_file(path_join(folder,"catalog.json",allocator=context.temp_allocator),catalog) {return}
    if !write_file(path_join(folder,"manifest.json",allocator=context.temp_allocator),manifest_json(g,entries[0][:],entries[1][:],entries[2][:],nil,context.temp_allocator)) {return}
    sync.atomic_store(written,true)
}

// The manifest of a generation of these stages.
@(private)
manifest_json :: proc(g:^Generation,shaders,programs,extensions,tests:[]Shader,allocator:=context.allocator) -> []u8 {
    writer:=json_writer(allocator)
    json_object_begin(&writer)
    json_key(&writer,"version");json_integer(&writer,1)
    json_key(&writer,"compiler");json_string(&writer,fmt.tprintf("%s; %s",g.version,g.metal_tools))
    json_key(&writer,"engine");json_string(&writer,g.identity)
    json_key(&writer,"catalog");json_string(&writer,g.catalog)
    json_key(&writer,"shaders");json_array_begin(&writer)
    for shader in shaders {shader_to_json(&writer,shader)}
    json_array_end(&writer)
    if len(programs)>0 {
        json_key(&writer,"program_stages");json_array_begin(&writer)
        for shader in programs {shader_to_json(&writer,shader)}
        json_array_end(&writer)
    }
    if len(extensions)>0 {
        json_key(&writer,"extensions");json_array_begin(&writer)
        for shader in extensions {shader_to_json(&writer,shader)}
        json_array_end(&writer)
    }
    json_key(&writer,"tests");json_array_begin(&writer)
    for shader in tests {shader_to_json(&writer,shader)}
    json_array_end(&writer)
    json_object_end(&writer)
    return json_finish(&writer)
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
        // POSIX remove_all opens the path as a directory: a table is a file.
        remove:=os.remove_all if os.is_dir(replacement.target) else os.remove
        if replacement.installed && remove(replacement.target)!=nil {recovered=false;continue}
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
    sources_init(&g.sources,scratch,options.overlay)
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
    previous,_:=read_json(path_join(g.output,"manifest.json",allocator=scratch),scratch)
    staging,staging_error:=os.make_directory_temp(path_parent(g.output),".mirai-shaders-*",scratch)
    if staging_error!=nil {fail(&result,allocator,"could not create the staging folder next to %s",g.output);return}
    staging=path_clean(staging,scratch)
    g.staging=staging
    cleanup:=true
    defer if cleanup {os.remove_all(staging)}

    // Programs and the frame constants of extensions see the schema too.
    os.make_directory_all(path_join(staging,"include",allocator=scratch))
    if !write_file(path_join(staging,"include",SCHEMA_INCLUDE,allocator=scratch),transmute([]u8)material_schema(scratch)) {fail(&result,allocator,"could not write %s",SCHEMA_INCLUDE);return}
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
    if !write_file(path_join(staging,"catalog.json",allocator=scratch),catalog_json(catalog,scratch)) {fail(&result,allocator,"could not write catalog.json");return}
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
    // What the engine's own shaders are compiled from. A generation built for
    // a project names it, and the engine loads it only while it is its own.
    identity:=engine_fingerprint(g.root,g.version,g.includes,scratch,&g.sources)
    g.identity,g.catalog,g.vfx,g.surface,g.vertex=identity,catalog.fingerprint,catalog.vfx,catalog.surface,catalog.vertex
    // The tools after Slang shape the Metal output of a shader, not what a
    // generation shares with the engine: they are of each shader's digest.
    {
        hash:Sha256
        sha_begin(&hash)
        for text in ([]string{GENERATOR_CONTRACT,g.version,g.metal_tools,abi_text(),material_schema()}) {sha_text(&hash,text);sha_text(&hash,"\n")}
        for flags in ([][]string{SLANG_FLAGS,SLANG_OPTIMIZATION,SPIRV_FLAGS,VALIDATE_FLAGS,OPTIMIZE_FLAGS,METAL_FLAGS}) {sha_text(&hash,strings.join(flags," ",context.temp_allocator));sha_text(&hash,"\n")}
        g.configuration=transmute([]u8)sha_hex(&hash,scratch)
    }
    g.tests_folder=path_join(g.root,"shaders/tests",allocator=scratch)
    jobs:=make([dynamic]Job,scratch)
    tests_out:=path_join(g.output,"tests",allocator=scratch)
    staging_shaders:=path_join(staging,"shaders",allocator=scratch)
    staging_tests:=path_join(staging_shaders,"tests",allocator=scratch)
    os.make_directory_all(staging_shaders)
    engine_manifest:json.Object
    if g.engine_build!="" {engine_manifest,_=read_json(path_join(g.engine_build,"manifest.json",allocator=scratch),scratch)}
    engine_shaders:=path_join(g.root,"shaders",allocator=scratch)
    shader_first,shader_count:=jobs_collect(g,&jobs,engine_shaders,g.output,staging_shaders,previous,"shaders",scratch,engine_manifest,.Plain)
    // The stages of the engine compiled for each program, which the renderer finds by name.
    program_first,program_count:=jobs_collect(g,&jobs,engine_shaders,g.output,staging_shaders,previous,"program_stages",scratch,engine_manifest,.Programs)
    // The stages the project and its plugins bring.
    extension_first:=len(jobs)
    for entry in extension_folders(&g.sources,g.project,options.sources,scratch) {
        jobs_collect(g,&jobs,entry.folder,g.output,staging_shaders,previous,"extensions",scratch)
    }
    extension_count:=len(jobs)-extension_first
    test_first,test_count:=0,0
    if odin {
        os.make_directory_all(staging_tests)
        test_first,test_count=jobs_collect(g,&jobs,g.tests_folder,tests_out,staging_tests,previous,"tests",scratch)
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

    pool:=make([]Worker,min(workers,max(len(g.jobs),1)),scratch)
    for &worker in pool {
        worker.generation=g
        if virtual.arena_init_growing(&worker.arena)!=nil {continue}
        worker.thread=thread.create_and_start_with_poly_data(&worker,worker_run)
    }
    for &worker in pool {
        if worker.thread!=nil {thread.join(worker.thread);thread.destroy(worker.thread)}
    }
    defer for &worker in pool {virtual.arena_destroy(&worker.arena)}
    result.warnings=strings.clone(strings.to_string(g.warnings),allocator)
    if runner_cancelled(g.runner) {fail(&result,allocator,"the generation was cancelled");return}
    for job in g.jobs {
        // What a worker made lives in its arena, which goes with the pool.
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
    if os.rename(path_join(staging,"include",allocator=scratch),path_join(staging_shaders,"include",allocator=scratch))!=nil || os.rename(path_join(staging,"catalog.json",allocator=scratch),path_join(staging_shaders,"catalog.json",allocator=scratch))!=nil {
        fail(&result,allocator,"could not prepare the catalog in %s",staging)
        return
    }
    outputs:=make([dynamic]string,scratch)
    replacements:=make([dynamic]Publication,scratch)
    tables_folder:string
    defer if cleanup && tables_folder!="" {os.remove_all(tables_folder)}
    shipped:=false
    if odin {
        assertions:=strings.builder_make(scratch)
        if problem:=layouts_assertions(&assertions,g.layouts);problem!="" {fail(&result,allocator,"%s",problem);return}
        shipped=true
        names:=EMBEDDED_NAMES
        sizes:[Backend][]int
        for backend in g.backends {
            packed:[]u8;packed_shipped:bool;problem:string
            packed,sizes[backend],packed_shipped,problem=embedded_pack(g,{shader_jobs,program_jobs},backend,options.ship,scratch)
            if problem!="" {fail(&result,allocator,"%s",problem);return}
            if !write_file(path_join(staging_shaders,names[backend],allocator=scratch),packed) {fail(&result,allocator,"could not write %s",names[backend]);return}
            shipped&&=packed_shipped
        }
        render_table:=odin_table(shader_jobs,g.backends,g.output,path_join(g.root,"render",allocator=scratch),"mirai_render","mirai:rhi",identity,"",strings.to_string(assertions),scratch,program_jobs,true,sizes)
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
    compiled:[4][]Shader
    for jobs,i in ([4][]Job{shader_jobs,program_jobs,extension_jobs,test_jobs}) {
        compiled[i]=make([]Shader,len(jobs),scratch)
        for job,at in jobs {compiled[i][at]=job.result}
    }
    // A generation equal to the published one leaves its manifest alone: whoever watches it sees no change.
    manifest_path:=path_join(g.output,"manifest.json",allocator=scratch)
    manifest:=manifest_json(g,compiled[0],compiled[1],compiled[2],compiled[3],scratch)
    if !write_file(path_join(staging_shaders,"manifest.json",allocator=scratch),manifest) {fail(&result,allocator,"could not prepare the manifest of %s",g.output);return}
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
    append(&outputs,manifest_path,path_join(g.output,"catalog.json",allocator=scratch))
    for name in ([]string{SURFACE_INCLUDE,SURFACE_COVERAGE_INCLUDE,POSTPROCESS_INCLUDE,VFX_INCLUDE,UI_INCLUDE,EXTENSIONS_INCLUDE,HOOKS_INCLUDE,SCHEMA_INCLUDE}) {append(&outputs,path_join(out_include,name,allocator=scratch))}
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
// packed: for each backend, the size of the code of each stage of jobs and
// then of programs; the code is then the stream EMBEDDED_NAMES names
// (SHADERS_PACKED) and each stage an Embedded_Shader of render.
@(private)
odin_table :: proc(jobs:[]Job,backends:Backends,out,target_folder,package_name,rhi_import,engine,guard,appended:string,allocator:=context.allocator,programs:[]Job=nil,program_table:=false,packed:[Backend][]int={}) -> []u8 {
    stages:=STAGE_NAMES
    relative:=path_from(out,target_folder,context.temp_allocator)
    prefix:="rhi." if rhi_import!="" else ""
    // size<0: the code is loaded as it is.
    code :: proc(b:^strings.Builder,shader:Shader,metal:bool,relative,prefix:string,stages:[Stage]string,size:int) {
        switch {
        case size>=0 && metal: fmt.sbprintf(b,"{{size = %d, code = {{binary = {{msl_entry = \"%s\"}}, ",size,shader.entry)
        case size>=0: fmt.sbprintf(b,"{{size = %d, code = {{",size)
        case metal: fmt.sbprintf(b,"{{binary = {{msl = #load(\"%s/%s\", string), msl_entry = \"%s\"}}, ",relative,shader.msl,shader.entry)
        case: fmt.sbprintf(b,"{{binary = {{spirv = #load(\"%s/%s\")}}, ",relative,shader.spv)
        }
        fmt.sbprintf(b,"name = \"%s\", stage = .%s,\n",shader.name,stages[shader.stage])
        fmt.sbprintf(b,"\t\t\tthreadgroup = {{%d, %d, %d}}, bindings = []%sBinding_Info{{",shader.group[0],shader.group[1],shader.group[2],prefix)
        for binding,i in shader.bindings {
            if i>0 {strings.write_string(b,", ")}
            fmt.sbprintf(b,"{{slot = %d, kind = .%s, stages = {{.%s}}}}",binding.slot,binding.kind,stages[shader.stage])
        }
        strings.write_string(b,"}}},\n" if size>=0 else "}},\n")
    }
    b:=strings.builder_make(allocator)
    fmt.sbprintf(&b,"// Code generated by mirai shaders. DO NOT EDIT.\npackage %s\n\n",package_name)
    if rhi_import!="" {fmt.sbprintf(&b,"import \"%s\"\n\n",rhi_import)}
    if guard!="" {fmt.sbprintf(&b,"when %s {{\n\n",guard)}
    if engine!="" {
        strings.write_string(&b,"// Of the engine's shader sources these were compiled from. A shader generation\n// built for a project is loaded only while its manifest names the same one.\n")
        fmt.sbprintf(&b,"SHADERS_FINGERPRINT :: \"%s\"\n\n",engine)
    }
    strings.write_string(&b,"Shader_Id :: enum u8 {\n")
    for job in jobs {fmt.sbprintf(&b,"\t%s,\n",job.result.id)}
    fmt.sbprintf(&b,"}}\n\nwhen %sSHADER_FORMAT == .Msl {{\n",prefix)
    names:=EMBEDDED_NAMES
    for metal in ([]bool{true,false}) {
        if !metal {strings.write_string(&b,"} else {\n")}
        backend:=Backend.Metal if metal else Backend.Vulkan
        if backend not_in backends {
            fmt.sbprintf(&b,"\t#panic(\"the shaders were generated without %s code: run `mirai shaders --backends all`\")\n","Metal" if metal else "SPIR-V")
            continue
        }
        sizes:=packed[backend]
        kind:="Embedded_Shader" if sizes!=nil else strings.concatenate({prefix,"Shader_Code"},context.temp_allocator)
        size :: proc(sizes:[]int,at:int) -> int {return sizes[at] if at<len(sizes) else -1}
        if sizes!=nil {fmt.sbprintf(&b,"\t@(rodata)\n\tSHADERS_PACKED := #load(\"%s/%s\")\n",relative,names[backend])}
        fmt.sbprintf(&b,"\t@(rodata)\n\tSHADERS := [Shader_Id]%s{{\n",kind)
        for job,at in jobs {
            fmt.sbprintf(&b,"\t\t.%s = ",job.result.id)
            code(&b,job.result,metal,relative,prefix,stages,size(sizes,at))
        }
        strings.write_string(&b,"\t}\n")
        if program_table {
            fmt.sbprintf(&b,"\t@(rodata)\n\tPROGRAM_SHADERS := [%d]%s{{\n",len(programs),kind)
            for job,at in programs {
                strings.write_string(&b,"\t\t")
                code(&b,job.result,metal,relative,prefix,stages,size(sizes,len(jobs)+at))
            }
            strings.write_string(&b,"\t}\n")
        }
    }
    strings.write_string(&b,"}\n")
    if guard!="" {strings.write_string(&b,"}\n")}
    strings.write_string(&b,appended)
    return b.buf[:]
}
