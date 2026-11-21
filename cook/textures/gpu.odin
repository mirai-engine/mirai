package textures

import "base:runtime"
import "core:log"
import "core:mem"
import "core:path/filepath"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:sync"
import "mirai:asset"
import "mirai:project"
import "mirai:render/abi"
import "mirai:rhi"
import "mirai:std/serial"

GPU_SHADER_FOLDER :: "cook"
GPU_GROUP :: 8
GPU_TILE :: 16

@(private="file")
GPU_BATCH_TEXELS :: 1<<20

@(private="file")
GPU_BUFFER_ALIGNMENT :: 256

@(private="file")
Gpu_Params :: struct {
    width,height,source_format,fast:u32,
    cutoff,lambda:f32,
    srgb,pad:u32,
}

@(private="file")
Gpu_Fit :: struct {
    endpoints,indices:[4]u32,
    mode,partition:u32,
    distortion,activity:f32,
}

@(private="file")
Gpu_Pass :: enum {Encode, Rdo}

@(private="file")
GPU_NAMES :: #partial [asset.Texture_Format][Gpu_Pass]string{
    .BC1={.Encode="bcn_encode.comp",.Rdo="bcn_rdo.comp"},
    .BC5={.Encode="bcn_encode_bc5.comp",.Rdo="bcn_rdo_bc5.comp"},
    .BC6H={.Encode="bcn_encode_bc6h.comp",.Rdo="bcn_rdo_bc6h.comp"},
    .BC7={.Encode="bcn_encode_bc7.comp",.Rdo="bcn_rdo_bc7.comp"},
}

GPU_ERROR :: "block texture encoding failed: check the GPU and rebuild the cook shaders " +
    "(mirai shaders)"

// Owns the pipelines and reusable buffers of a synchronous cook. A zero context
// opens a headless device on its first block encode.
Gpu_Context :: struct {
    engine_root:string,
    borrowed:bool,
    device:^rhi.Device,
    folder:string,
    allocator:mem.Allocator,
    lock:sync.Mutex,
    pipelines:[asset.Texture_Format][Gpu_Pass]rhi.Pipeline,
    params,input,fits,output:rhi.Buffer,
}

// The caller keeps device alive and reserves it for this context while encoding.
gpu_context_init :: proc(
    gpu:^Gpu_Context,device:^rhi.Device,engine_root:string,allocator:=context.allocator,
) -> Error {
    if gpu==nil || gpu.device!=nil || device==nil {return .Invalid}
    gpu.folder=gpu_shader_folder(engine_root,allocator) or_return
    gpu.device,gpu.allocator,gpu.borrowed=device,allocator,true
    return .None
}

@(private="file")
gpu_shader_folder :: proc(engine_root:string,allocator:mem.Allocator) -> (string,Error) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    root:=project.engine_root_find(engine_root,context.temp_allocator)
    if root=="" {return "",.Gpu}
    folder,err:=strings.clone(project.path(root,"shaders/build",GPU_SHADER_FOLDER,
        allocator=context.temp_allocator),allocator)
    return folder,.None if err==nil else .Out_Of_Memory
}

@(private="file")
gpu_open :: proc(gpu:^Gpu_Context) -> Error {
    if gpu.device!=nil {return .None}
    allocator:=runtime.heap_allocator()
    folder:=gpu_shader_folder(gpu.engine_root,allocator) or_return
    device,problem:=rhi.device_create({
        app_name="Mirai texture cook",allocator=allocator,on_message=rhi.message_print,
    })
    if device==nil {
        delete(folder,allocator)
        log.errorf("texture cook: %s",problem)
        return .Gpu
    }
    gpu.device,gpu.folder,gpu.allocator=device,folder,allocator
    return .None
}

gpu_context_destroy :: proc(gpu:^Gpu_Context) {
    if gpu==nil || gpu.device==nil {return}
    for by_pass in gpu.pipelines do for pipeline in by_pass {
        if pipeline!=0 {rhi.pipeline_destroy(gpu.device,pipeline)}
    }
    for buffer in ([4]rhi.Buffer{gpu.params,gpu.input,gpu.fits,gpu.output}) {
        if buffer!=0 {rhi.buffer_destroy(gpu.device,buffer)}
    }
    if !gpu.borrowed {rhi.device_destroy(gpu.device)}
    delete(gpu.folder,gpu.allocator)
    gpu^={}
}

@(private)
gpu_pipeline :: proc(
    gpu:^Gpu_Context,format:asset.Texture_Format,pass:Gpu_Pass,
) -> rhi.Pipeline {
    pipeline:=&gpu.pipelines[format][pass]
    if pipeline^!=0 {return pipeline^}
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    a:=context.temp_allocator
    file:=project.path(gpu.folder,abi.SHADER_MANIFEST,allocator=a)
    manifest_bytes,err:=os.read_entire_file(file,a)
    if err!=nil {return 0}
    manifest:abi.Shader_Manifest
    if serial.text_decode(string(manifest_bytes),&manifest,a)!="" || manifest.version!=1 {
        return 0
    }
    names:=GPU_NAMES
    shader:=names[format][pass]
    for item in manifest.shaders {
        if item.name!=shader {continue}
        if item.stage!=.Compute || item.group!=([3]int{GPU_GROUP,GPU_GROUP,1}) {return 0}
        name:=item.msl if rhi.SHADER_FORMAT==.Msl else item.spv
        if name=="" || name!=filepath.base(name) {return 0}
        if rhi.SHADER_FORMAT==.Msl && item.entry=="" {return 0}
        bytes,read_error:=os.read_entire_file(project.path(gpu.folder,name,allocator=a),a)
        if read_error!=nil || len(bytes)==0 {return 0}
        bindings: [4]rhi.Binding_Info
        if len(item.bindings)>len(bindings) {return 0}
        for b,i in item.bindings {
            kind,valid:=reflect.enum_from_name(rhi.Binding_Kind,b.kind)
            if !valid || b.slot<0 || b.slot>=len(bindings) ||
                !rhi.binding_slot_valid(u32(b.slot),kind) {return 0}
            bindings[i]={u32(b.slot),kind,{.Compute}}
        }
        code:=rhi.Shader_Code{name=shader,stage=.Compute,
            threadgroup={GPU_GROUP,GPU_GROUP,1},bindings=bindings[:len(item.bindings)]}
        rhi.shader_code_set(&code,bytes,item.entry)
        pipeline^=rhi.pipeline_create_compute(gpu.device,{shader=&code,name=shader})
        return pipeline^
    }
    return 0
}

@(private="file")
gpu_buffer :: proc(
    gpu:^Gpu_Context,handle:^rhi.Buffer,size:int,memory:rhi.Memory,
    usage:rhi.Buffer_Usage,name:string,
) -> bool {
    if rhi.buffer_size(gpu.device,handle^)>=u64(size) {return true}
    next:=rhi.buffer_create(gpu.device,{size=u64(size),memory=memory,
        usage=usage,name=name})
    if next==0 {return false}
    if handle^!=0 {rhi.buffer_destroy(gpu.device,handle^)}
    handle^=next
    return true
}

@(private="file")
Gpu_Batch :: struct {
    input_at, output_at: int,
    texels, destination: []u8,
    width, height: int,
}

@(private)
gpu_chain :: proc(
    gpu:^Gpu_Context,levels:[]Source,mips:[][]u8,format:asset.Texture_Format,
    options:Build_Options,allocator:mem.Allocator,
) -> Error {
    own:Gpu_Context
    defer gpu_context_destroy(&own)
    gpu:=gpu if gpu!=nil else &own
    sync.guard(&gpu.lock)
    gpu_open(gpu) or_return
    encode:=gpu_pipeline(gpu,format,.Encode)
    if encode==0 {return .Gpu}
    lambda:=rdo_lambda(options)
    rdo:rhi.Pipeline
    if lambda>0 {
        rdo=gpu_pipeline(gpu,format,.Rdo)
        if rdo==0 {return .Gpu}
    }
    batches:=make([dynamic]Gpu_Batch,0,0,runtime.heap_allocator())
    defer delete(batches)
    pixel_bytes:=SOURCE_TEXEL_BYTES
    input_size,output_size,fit_size:=0,0,size_of(Gpu_Fit)
    for level,i in levels {
        w,h:=level.width,level.height
        row_bytes:=w*pixel_bytes[level.format]
        block_row_bytes:=asset.texture_level_size(format,w,1)
        layer_size:=asset.texture_level_size(format,w,h)
        rows:=min(h,max(GPU_BATCH_TEXELS/(w*4*GPU_TILE),1)*4*GPU_TILE)
        alloc_error:mem.Allocator_Error
        if mips[i],alloc_error=make([]u8,layer_size*level.layers,allocator);alloc_error!=nil {
            return .Out_Of_Memory
        }
        for layer in 0..<level.layers {
            for y:=0;y<h;y+=rows {
                height:=min(rows,h-y)
                input_start:=(layer*h+y)*row_bytes
                output_start:=layer*layer_size+y/4*block_row_bytes
                bytes:=((height+3)/4)*block_row_bytes
                batch:=Gpu_Batch{
                    input_size,output_size,
                    level.texels[input_start:][:height*row_bytes],
                    mips[i][output_start:][:bytes],w,height,
                }
                if _,err:=append(&batches,batch);err!=nil {return .Out_Of_Memory}
                input_size=mem.align_forward_int(input_size+len(batch.texels),GPU_BUFFER_ALIGNMENT)
                output_size=mem.align_forward_int(output_size+bytes,GPU_BUFFER_ALIGNMENT)
                if rdo!=0 {
                    fit_size=max(fit_size,size_of(Gpu_Fit)*((w+3)/4)*((height+3)/4))
                }
            }
        }
    }
    d:=gpu.device
    if !gpu_buffer(gpu,&gpu.params,len(batches)*GPU_BUFFER_ALIGNMENT,.Upload,
        {.Uniform},"BCn parameters") ||
        !gpu_buffer(gpu,&gpu.input,input_size,.Upload,{.Storage},"BCn source") ||
        !gpu_buffer(gpu,&gpu.fits,fit_size,.GPU,{.Storage},"BCn block fits") ||
        !gpu_buffer(gpu,&gpu.output,output_size,.Readback,{.Storage},"BCn output") {
        return .Gpu
    }
    mapped:=cast([^]u8)rhi.buffer_mapped(d,gpu.output)
    if mapped==nil {return .Gpu}
    for batch,i in batches {
        params:=Gpu_Params{u32(batch.width),u32(batch.height),u32(levels[0].format),
            u32(options.speed==.Fast),options.alpha_coverage,f32(lambda),u32(options.srgb),0}
        if !rhi.buffer_upload(d,gpu.input,u64(batch.input_at),batch.texels) ||
            !rhi.buffer_upload(d,gpu.params,u64(i*GPU_BUFFER_ALIGNMENT),mem.ptr_to_bytes(&params)) {
            return .Gpu
        }
    }
    cmd:=rhi.immediate_begin(d)
    if cmd==nil {return .Gpu}
    for batch,i in batches {
        x:=u32((batch.width+4*GPU_GROUP-1)/(4*GPU_GROUP))
        y:=u32((batch.height+4*GPU_GROUP-1)/(4*GPU_GROUP))
        rhi.cmd_bind_buffer(cmd,0,gpu.params,u64(i*GPU_BUFFER_ALIGNMENT),size_of(Gpu_Params))
        rhi.cmd_bind_buffer(cmd,1,gpu.input,u64(batch.input_at),u64(len(batch.texels)))
        rhi.cmd_bind_buffer(cmd,2,gpu.fits)
        rhi.cmd_bind_buffer(cmd,3,gpu.output,u64(batch.output_at),u64(len(batch.destination)))
        rhi.cmd_bind_pipeline(cmd,encode)
        rhi.cmd_dispatch(cmd,x,y)
        if rdo!=0 {
            rhi.cmd_bind_pipeline(cmd,rdo)
            rhi.cmd_dispatch(cmd,x,y)
        }
    }
    rhi.cmd_barrier_buffer(cmd,gpu.output,.Host_Read)
    if !rhi.immediate_end(d,cmd) {return .Gpu}
    for batch in batches {
        copy(batch.destination,mapped[batch.output_at:][:len(batch.destination)])
    }
    return .None
}
