package mirai_render

import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "mirai:asset"
import "mirai:render/abi"
import "mirai:rhi"
import "mirai:std/compressor"
import "mirai:std/serial"

// A generation of the shaders loaded from disk; owned: its codes are memory of allocator.
Shader_Assets :: struct {
    codes:[Shader_Id]rhi.Shader_Code,
    extensions:[]rhi.Shader_Code, // the stages the extensions of the generation bring, by name
    programs:[]rhi.Shader_Code,   // the stages of the engine compiled for one material program each, by name
    catalog:[]u8, // catalog.json of the generation: its material programs and the layout of its frame constants; empty when it has none
    owned:bool,allocator:runtime.Allocator,
}
@(private)
shader_code_destroy :: proc(c:rhi.Shader_Code,allocator:runtime.Allocator) {
    delete(c.name,allocator);delete(c.bindings,allocator)
    for constant in c.constants {delete(constant,allocator)}
    delete(c.constants,allocator)
    delete(rhi.shader_code_bytes(c),allocator);delete(rhi.shader_code_entry(c),allocator)
}
shader_assets_destroy :: proc(assets:^Shader_Assets) {
    if assets.owned {
        for c in assets.codes {shader_code_destroy(c,assets.allocator)}
        for c in assets.extensions {shader_code_destroy(c,assets.allocator)}
        for c in assets.programs {shader_code_destroy(c,assets.allocator)}
        delete(assets.extensions,assets.allocator)
        delete(assets.programs,assets.allocator)
        delete(assets.catalog,assets.allocator)
    }
    assets^={}
}

// Decodes the code the executable embeds into bytes, which the stages it fills
// in codes (SHADERS) and programs (PROGRAM_SHADERS) point into. What is
// embedded (shaders_packed) says how many stages it holds and the size of the
// code of each (u32, little endian), in the order of SHADERS and then of
// PROGRAM_SHADERS, before their code packed: the tables say nothing of the
// code. It allocates bytes alone, and nothing when it fails.
embedded_shaders_decode :: proc(codes:^[Shader_Id]rhi.Shader_Code,programs:^[len(PROGRAM_SHADERS)]rhi.Shader_Code,allocator:=context.allocator)->(bytes:[]u8,error:string) {
    count:=len(Shader_Id)+len(PROGRAM_SHADERS)
    packed:=shaders_packed()
    if len(packed)<4*(count+1) || int(endian.unchecked_get_u32le(packed))!=count {return nil,"the embedded shaders are of other stages than this engine has: build the engine again"}
    sizes:=packed[4:]
    total:=0
    for stage in 0..<count {total+=int(endian.unchecked_get_u32le(sizes[4*stage:]))}
    if total>0 {
        allocation_error:runtime.Allocator_Error
        if bytes,allocation_error=make([]u8,total,allocator);allocation_error!=nil {return nil,"out of memory for the embedded shaders"}
        decoder:compressor.Decoder
        if compressor.decoder_init(&decoder,allocator)!=.None {delete(bytes,allocator);return nil,"out of memory for the embedded shaders"}
        unpack_error:=asset.unpack(&decoder,sizes[4*count:],bytes)
        compressor.decoder_destroy(&decoder)
        if unpack_error!=.None {delete(bytes,allocator);return nil,"the embedded shaders do not decode: build the engine again"}
    }
    at:=0
    place :: proc(code:^rhi.Shader_Code,shader:rhi.Shader_Code,bytes:[]u8,at:^int,size:u32) {
        code^=shader
        rhi.shader_code_set(code,bytes[at^:][:size],rhi.shader_code_entry(shader))
        at^+=int(size)
    }
    for &code,id in codes^ {place(&code,SHADERS[id],bytes,&at,endian.unchecked_get_u32le(sizes[4*int(id):]))}
    for &code,i in programs^ {place(&code,PROGRAM_SHADERS[i],bytes,&at,endian.unchecked_get_u32le(sizes[4*(len(Shader_Id)+i):]))}
    return
}

FRAME_EXTENSION_CAPACITY :: 8

// What an extension keeps in the constants of every view: the struct it
// declared for them. Its name is in the catalog the layout was read from.
Frame_Extension :: abi.Frame_Extension

// The constants of a view in a generation of the shaders: Gpu_Frame, then the
// nested views when the generation has them, then what each extension declared.
Frame_Layout :: struct {
    size:int,
    nested:bool,
    instance_ids:bool, // the G-buffer keeps the instance that drew each pixel (Surface_Source.Instance)
    extensions:[FRAME_EXTENSION_CAPACITY]Frame_Extension,
    extension_count:int,
}

// The layout the catalog of a generation declares; that of the engine alone without one.
@(private)
frame_layout_of :: proc(assets:^Shader_Assets) -> Frame_Layout {
    layout:=Frame_Layout{size=size_of(Gpu_Frame)}
    catalog:abi.Shader_Catalog
    if len(assets.catalog)==0 || serial.text_decode(string(assets.catalog),&catalog,context.temp_allocator)!="" {return layout}
    frame:=catalog.frame
    core:=size_of(Gpu_Frame)+(NESTED_VIEW_CAPACITY*size_of(Gpu_Nested) if frame.nested else 0)
    size:=frame.size
    if size==0 && !frame.nested {size=core}
    if size<core || size>65536 || len(frame.extensions)>FRAME_EXTENSION_CAPACITY {return layout}
    for extension,i in frame.extensions {
        // The name lives as long as the catalog of the generation: find it there.
        at:=strings.index(string(assets.catalog),extension.name)
        if extension.name=="" || at<0 || extension.offset<core || extension.size<=0 || extension.offset+extension.size>size {return {size=size_of(Gpu_Frame)}}
        layout.extensions[i]={string(assets.catalog[at:][:len(extension.name)]),extension.offset,extension.size}
    }
    layout.size,layout.nested,layout.instance_ids,layout.extension_count=size,frame.nested,frame.instance_ids,len(frame.extensions)
    return layout
}

// A stage an extension of the generation brings, to make a pipeline from; nil
// when the shaders in use have none with that name. It lasts until the shaders
// are loaded again.
@(private)
extension_shader :: proc(r:^Renderer,name:string) -> ^rhi.Shader_Code {
    for &code in r.shader_assets.extensions {if code.name==name {return &code}}
    return nil
}
// A stage of the engine compiled for one material program (<stage>__<program>),
// from the generation in use or, without one, from those the executable
// embeds; nil when it has none. It lasts until the shaders are loaded again.
@(private)
program_shader :: proc(r:^Renderer,name:string) -> ^rhi.Shader_Code {
    if !r.shader_assets.owned {
        for &code in r.embedded_programs {if code.name==name {return &code}}
        return nil
    }
    for &code in r.shader_assets.programs {if code.name==name {return &code}}
    return nil
}
// Pipeline creation consumes the code; generations compare by content, not
// storage. Authoring metadata is published even when GPU code is unchanged.
shader_assets_match_codes :: proc(assets:^Shader_Assets,codes:^[Shader_Id]rhi.Shader_Code)->bool {
    for next,id in assets.codes {
        if !shader_code_matches(next,codes[id]) {return false}
    }
    return true
}
@(private)
shader_code_matches :: proc(next,current:rhi.Shader_Code)->bool {
    if next.name!=current.name || next.stage!=current.stage || next.threadgroup!=current.threadgroup || len(next.bindings)!=len(current.bindings) {return false}
    for binding,i in next.bindings {if binding!=current.bindings[i] {return false}}
    if len(next.constants)!=len(current.constants) {return false}
    for constant,i in next.constants {if constant!=current.constants[i] {return false}}
    return string(rhi.shader_code_bytes(next))==string(rhi.shader_code_bytes(current)) && rhi.shader_code_entry(next)==rhi.shader_code_entry(current)
}
// Whether two generations bring the same stages of extensions, or of programs.
@(private)
shader_stages_match :: proc(next,current:[]rhi.Shader_Code)->bool {
    if len(next)!=len(current) {return false}
    for code,i in next {if !shader_code_matches(code,current[i]) {return false}}
    return true
}
// Whether the engine stages of a folder of compiled shaders share with the
// engine what this executable was built with (SHADERS_INTERFACE): the
// bindings and the constants of each stage and the structs both sides read.
// Their code may be any: a generation whose engine shaders changed only in
// code loads into the engine that runs.
shader_generation_current :: proc(directory:string)->bool {
    manifest,read:=shader_manifest_read(directory)
    return read && manifest.engine==SHADERS_INTERFACE
}
@(private)
shader_manifest_read :: proc(directory:string)->(manifest:abi.Shader_Manifest,ok:bool) {
    path,_:=filepath.join({directory,abi.SHADER_MANIFEST},context.temp_allocator)
    bytes,read_error:=os.read_entire_file(path,context.temp_allocator)
    return manifest,read_error==nil && serial.text_decode(string(bytes),&manifest,context.temp_allocator)==""
}
// On failure nothing is loaded: assets is empty and error is a message, in
// context.temp_allocator when it names a file.
shader_assets_load :: proc(directory:string,allocator:=context.allocator)->(assets:Shader_Assets,error:string) {
    assets.owned=true;assets.allocator=allocator
    manifest,read:=shader_manifest_read(directory)
    if !read {return {},"invalid shader manifest: it does not read as one"}
    if manifest.engine!=SHADERS_INTERFACE {
        return {},"the engine stages of these shaders bind or lay out otherwise than this executable does: build the engine again"
    }
    extensions_error,programs_error:runtime.Allocator_Error
    assets.extensions,extensions_error=make([]rhi.Shader_Code,len(manifest.extensions),allocator)
    assets.programs,programs_error=make([]rhi.Shader_Code,len(manifest.program_stages),allocator)
    if extensions_error!=nil || programs_error!=nil {
        shader_assets_destroy(&assets)
        return assets,"out of memory for the shaders of the manifest"
    }
    shaders,programs:=len(manifest.shaders),len(manifest.program_stages)
    for at in 0..<shaders+programs+len(manifest.extensions) {
        item:abi.Shader_Entry
        code:^rhi.Shader_Code
        switch {
        case at>=shaders+programs:
            item,code=manifest.extensions[at-shaders-programs],&assets.extensions[at-shaders-programs]
        case at>=shaders:
            item,code=manifest.program_stages[at-shaders],&assets.programs[at-shaders]
        case:
            item=manifest.shaders[at]
            id,valid:=reflect.enum_from_name(Shader_Id,item.id);if !valid {error=fmt.tprintf("unknown shader %s",item.id);break}
            if assets.codes[id].name!="" {error="duplicate shader id";break}
            code=&assets.codes[id]
        }
        if error!="" {break}
        no_name:runtime.Allocator_Error
        if code.name,no_name=strings.clone(item.name,allocator);no_name!=nil {error="out of memory for the name of a shader";break}
        code.stage=rhi.Shader_Stage(u8(item.stage)) // the same members in the same order
        // A stage of the rays traced by software has no Metal code.
        if name:=item.msl if rhi.SHADER_FORMAT==.Msl else item.spv;name!="" || SOFTWARE_TRACER {
            file,_:=filepath.join({directory,name},context.temp_allocator)
            data,problem:=os.read_entire_file(file,allocator);if problem!=nil {error=fmt.tprintf("cannot read %s",file);break}
            rhi.shader_code_set(code,data,"")
            if rhi.SHADER_FORMAT==.Msl {
                entry,no_entry:=strings.clone(item.entry,allocator)
                if no_entry!=nil {error=fmt.tprintf("out of memory for the entry point of shader %s",code.name);break}
                rhi.shader_code_set(code,data,entry)
                if entry=="" {error="shader has no Metal entry point";break}
            }
        }
        for n,i in item.group {
            if n<0 || n>int(max(u32)) {error="invalid workgroup";break}
            code.threadgroup[i]=u32(n)
        }
        if error!="" {break}
        bindings_error:runtime.Allocator_Error
        code.bindings,bindings_error=make([]rhi.Binding_Info,len(item.bindings),allocator)
        if bindings_error!=nil {error=fmt.tprintf("out of memory for the bindings of shader %s",code.name);break}
        for b,i in item.bindings {
            kind,valid_kind:=reflect.enum_from_name(rhi.Binding_Kind,b.kind);if !valid_kind {error="invalid binding kind";break}
            if b.slot<0 || b.slot>int(max(u32)) || !rhi.binding_slot_valid(u32(b.slot),kind) {error="invalid binding slot";break}
            code.bindings[i]={slot=u32(b.slot),kind=kind,stages={code.stage}}
        }
        if error!="" {break}
        if len(item.constants)>rhi.MAX_SHADER_CONSTANTS {error=fmt.tprintf("shader %s declares more constants than a pipeline sets",code.name);break}
        constants_error:runtime.Allocator_Error
        code.constants,constants_error=make([]string,len(item.constants),allocator)
        if constants_error!=nil {error=fmt.tprintf("out of memory for the constants of shader %s",code.name);break}
        for constant,i in item.constants {
            if constant=="" {error="invalid shader constant";break}
            no_constant:runtime.Allocator_Error
            if code.constants[i],no_constant=strings.clone(constant,allocator);no_constant!=nil {error=fmt.tprintf("out of memory for the constants of shader %s",code.name);break}
        }
        if error!="" {break}
    }
    if error=="" {for c in assets.codes {if c.name=="" {error="shader catalog is incomplete";break}}}
    if error=="" {
        catalog,_:=filepath.join({directory,abi.SHADER_CATALOG},context.temp_allocator)
        assets.catalog,_=os.read_entire_file(catalog,allocator)
    }
    if error!="" {shader_assets_destroy(&assets)}
    return
}
// A reload in three steps, while the active generation goes on drawing:
// renderer_shader_reload_begin on the render thread takes what the pipelines
// of a generation are made from, renderer_shader_reload_build makes them on
// any thread (the driver compiles them for seconds), and
// renderer_publish_shader_reload or renderer_abort_shader_reload ends it
// between frames. The assets stay with the caller until it publishes them.
// stop: once set from any thread, the build makes no more pipelines and fails.
renderer_shader_reload_begin :: proc(r:^Renderer,assets:^Shader_Assets,stop:^bool=nil)->^Renderer {
    if !assets.owned {return nil}
    candidate,candidate_error:=new(Renderer,r.allocator)
    if candidate_error!=nil {set_error(r,"shader reload: out of memory for its renderer");return nil}
    candidate^=r^
    candidate.shader_codes=assets.codes;candidate.pipelines={};candidate.variant_count=0;candidate.overlay_pipelines={};candidate.overlay_hw_pipelines={};candidate.program_graphics={};candidate.pipeline_thread=nil
    candidate.reload_stop=stop
    candidate.frame_layout=frame_layout_of(assets)
    return candidate
}
// Makes the pipelines of the tracer the renderer used when the reload began.
// False when a pipeline is refused: candidate.error says which. And for the
// candidate renderer_shader_reload_begin had no memory for.
renderer_shader_reload_build :: proc(candidate:^Renderer)->bool {
    if candidate==nil {return false}
    tracer:=Pipeline_Rays.Hardware if candidate.hardware_rt else .Software
    if !create_pipelines(candidate,{.Any,tracer}) {return false}
    if missing:=tracer_missing(candidate,tracer);missing!="" {set_error(candidate,"pipeline %s: %s",missing,rhi.device_error(candidate.device));return false}
    return true
}
renderer_abort_shader_reload :: proc(candidate:^Renderer) {
    if candidate==nil {return}
    pipelines_destroy(candidate)
    for p in candidate.overlay_pipelines {if p!=0 {rhi.pipeline_destroy(candidate.device,p)}}
    for p in candidate.overlay_hw_pipelines {if p!=0 {rhi.pipeline_destroy(candidate.device,p)}}
    free(candidate,candidate.allocator)
}
// The stages only the previews of assets draw with: a generation that changes
// these alone, or these and idle ones (renderer_shaders_idle), leaves the
// image of the scene and its histories as they are.
// A switch and not a bit_set: ranging over a constant one of Shader_Id, past
// 128, fails in the backend of Odin (odin-lang/Odin#8047).
preview_shader :: proc "contextless" (id:Shader_Id) -> bool {
    #partial switch id {case .Thumbnail_Vert,.Thumbnail_Frag,.Thumbnail_Values_Frag,.Preview_Backdrop_Frag: return true}
    return false
}

// False, with r.error, when the pipelines of a tracer the renderer switched
// to while the candidate was made are not made: the generation is not taken.
renderer_publish_shader_reload :: proc(r:^Renderer,assets:^Shader_Assets,candidate:^Renderer)->bool {
    tracer:=Pipeline_Rays.Hardware if r.hardware_rt else .Software
    if tracer_missing(candidate,tracer)!="" {create_pipelines(candidate,{tracer})}
    if missing:=tracer_missing(candidate,tracer);missing!="" {
        set_error(r,"the new shaders lack the pipeline %s of the tracer in use, which the device did not make (%s); loading them again retries it",missing,rhi.device_error(r.device))
        return false
    }
    scene:=false
    idle:=renderer_shaders_idle(r)
    for code,id in candidate.shader_codes {
        if !preview_shader(id) && !idle[id] && !shader_code_matches(code,r.shader_codes[id]) {scene=true;break}
    }
    rhi.device_wait_idle(r.device)
    pipelines_drop(r)
    pipelines_destroy(r)
    for p in r.overlay_pipelines {if p!=0 {rhi.pipeline_destroy(r.device,p)}}
    for p in r.overlay_hw_pipelines {if p!=0 {rhi.pipeline_destroy(r.device,p)}}
    shader_assets_destroy(&r.shader_assets)
    r.shader_assets=assets^;assets^={}
    r.frame_layout=frame_layout_of(&r.shader_assets)
    stage_pipelines_destroy(r)
    points_pipelines_destroy(r)
    program_graphics_destroy(r)
    program_catalog_destroy(&r.programs)
    r.shader_codes=candidate.shader_codes;r.pipelines=candidate.pipelines;r.overlay_pipelines=candidate.overlay_pipelines
    r.variants,r.variant_count=candidate.variants,candidate.variant_count
    r.overlay_hw_pipelines=candidate.overlay_hw_pipelines
    candidate.pipelines={};candidate.overlay_pipelines={};candidate.overlay_hw_pipelines={};candidate.variant_count=0
    if !scene {return true}
    r.targets.taa_valid=false;r.targets.glass_valid=false
    renderer_camera_cut(r)
    world_light_stale(r)
    return true
}
renderer_reload_shaders :: proc(r:^Renderer,assets:^Shader_Assets)->bool {
    if !assets.owned {return false}
    catalog,valid:=program_catalog_parse(assets.catalog,r.allocator)
    if !valid {set_error(r,"invalid material program catalog");return false}
    defer program_catalog_destroy(&catalog)
    if shader_assets_match_codes(assets,&r.shader_codes) {
        renderer_publish_shader_metadata(r,assets)
        r.programs=catalog;r.programs.loaded=true;catalog={}
        displaced_programs_changed(r)
        return true
    }
    candidate:=renderer_shader_reload_begin(r,assets)
    if candidate==nil {return false}
    defer renderer_abort_shader_reload(candidate)
    if !renderer_shader_reload_build(candidate) {set_error(r,"%s",candidate.error);return false}
    if !renderer_publish_shader_reload(r,assets,candidate) {return false}
    r.programs=catalog;r.programs.loaded=true;catalog={}
    displaced_programs_changed(r)
    return true
}

renderer_publish_shader_metadata :: proc(r:^Renderer,assets:^Shader_Assets) {
    // The stages of an extension or of a program changed alone: their pipelines are made again, those of the engine stay.
    extensions:=shader_stages_match(assets.extensions,r.shader_assets.extensions)
    programs:=shader_stages_match(assets.programs,r.shader_assets.programs)
    if !extensions || !programs {
        rhi.device_wait_idle(r.device)
        pipelines_drop(r)
        if !extensions {stage_pipelines_destroy(r)}
        program_stages_publish(r,assets.programs)
    }
    shader_assets_destroy(&r.shader_assets)
    r.shader_assets=assets^;assets^={}
    r.shader_codes=r.shader_assets.codes
    r.frame_layout=frame_layout_of(&r.shader_assets)
    program_catalog_destroy(&r.programs)
}
