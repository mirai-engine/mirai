package textures

import "base:runtime"
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

// Owns the pipelines and reusable buffers of a synchronous cook. The caller keeps
// the device alive and reserves it for this context while encoding.
Gpu_Context :: struct {
    device:^rhi.Device,
    folder:string,
    allocator:mem.Allocator,
    lock:sync.Mutex,
    pipelines:[asset.Texture_Format][Gpu_Pass]rhi.Pipeline,
    params,input,fits,output,readback:rhi.Buffer,
}

// A nil device selects the CPU path. With a device, engine_root supplies the
// cook shaders published by mirai shaders. The context must start zeroed.
gpu_context_init :: proc(
    gpu:^Gpu_Context,device:^rhi.Device,engine_root:string,allocator:=context.allocator,
) -> Error {
    if gpu==nil || gpu.device!=nil {return .Invalid}
    if device==nil {return .None}
    folder,err:=strings.clone(project.path(engine_root,"shaders/build",GPU_SHADER_FOLDER,
        allocator=context.temp_allocator),allocator)
    if err!=nil {return .Out_Of_Memory}
    gpu.device,gpu.folder,gpu.allocator=device,folder,allocator
    return .None
}

gpu_context_destroy :: proc(gpu:^Gpu_Context) {
    if gpu==nil || gpu.device==nil {return}
    for by_pass in gpu.pipelines do for pipeline in by_pass {
        if pipeline!=0 {rhi.pipeline_destroy(gpu.device,pipeline)}
    }
    for buffer in ([5]rhi.Buffer{gpu.params,gpu.input,gpu.fits,gpu.output,gpu.readback}) {
        if buffer!=0 {rhi.buffer_destroy(gpu.device,buffer)}
    }
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

@(private)
gpu_level :: proc(
    gpu:^Gpu_Context,level:Source,format:asset.Texture_Format,options:Build_Options,
    allocator:mem.Allocator,
) -> (out:[]u8,error:Error) {
    sync.guard(&gpu.lock)
    encode:=gpu_pipeline(gpu,format,.Encode)
    if encode==0 {return nil,.Gpu}
    lambda:=rdo_lambda(options)
    rdo:rhi.Pipeline
    if lambda>0 {
        rdo=gpu_pipeline(gpu,format,.Rdo)
        if rdo==0 {return nil,.Gpu}
    }
    d:=gpu.device
    w,h:=level.width,level.height
    block_width:=(w+3)/4
    pixel_bytes:=SOURCE_TEXEL_BYTES
    row_bytes:=w*pixel_bytes[level.format]
    block_row_bytes:=asset.texture_level_size(format,w,1)
    rows:=min(h,max(GPU_BATCH_TEXELS/(w*4*GPU_TILE),1)*4*GPU_TILE)
    block_rows:=(rows+3)/4
    fits_size:=size_of(Gpu_Fit)*(block_rows*block_width if rdo!=0 else 1)
    output_bytes:=block_row_bytes*block_rows
    if !gpu_buffer(gpu,&gpu.params,size_of(Gpu_Params),.Upload,{.Uniform},"BCn parameters") ||
        !gpu_buffer(gpu,&gpu.input,row_bytes*rows,.Upload,{.Storage},"BCn source") ||
        !gpu_buffer(gpu,&gpu.fits,fits_size,.GPU,{.Storage},"BCn block fits") ||
        !gpu_buffer(gpu,&gpu.output,output_bytes,.GPU,{.Storage,.Transfer_Src},"BCn output") ||
        !gpu_buffer(gpu,&gpu.readback,output_bytes,.Readback,{.Transfer_Dst},"BCn readback") {
        return nil,.Gpu
    }
    size:=asset.texture_level_size(format,w,h)
    alloc_error:mem.Allocator_Error
    if out,alloc_error=make([]u8,size*level.layers,allocator);alloc_error!=nil {
        return nil,.Out_Of_Memory
    }
    allocated:=out
    committed:=false
    defer if !committed {delete(allocated,allocator)}
    for layer in 0..<level.layers {
        for y:=0;y<h;y+=rows {
            height:=min(rows,h-y)
            input_at:=(layer*h+y)*row_bytes
            input:=level.texels[input_at:][:height*row_bytes]
            if !rhi.buffer_upload(d,gpu.input,0,input) {return nil,.Gpu}
            params:=Gpu_Params{u32(w),u32(height),u32(level.format),u32(options.speed==.Fast),
                options.alpha_coverage,f32(lambda),u32(options.srgb),0}
            if !rhi.buffer_upload(d,gpu.params,0,mem.ptr_to_bytes(&params)) {return nil,.Gpu}
            cmd:=rhi.immediate_begin(d)
            if cmd==nil {return nil,.Gpu}
            groups_x:=u32((block_width+GPU_GROUP-1)/GPU_GROUP)
            groups_y:=u32(((height+3)/4+GPU_GROUP-1)/GPU_GROUP)
            gpu_dispatch(cmd,gpu,encode,groups_x,groups_y)
            if rdo!=0 {gpu_dispatch(cmd,gpu,rdo,groups_x,groups_y)}
            written:=((height+3)/4)*block_row_bytes
            rhi.cmd_copy_buffer(cmd,gpu.output,0,gpu.readback,0,u64(written))
            if !rhi.immediate_end(d,cmd) {return nil,.Gpu}
            at:=layer*size+y/4*block_row_bytes
            if !rhi.buffer_read(d,gpu.readback,0,out[at:][:written]) {return nil,.Gpu}
        }
    }
    committed=true
    return out,.None
}

@(private="file")
gpu_dispatch :: proc(
    cmd:^rhi.Command_List,gpu:^Gpu_Context,pipeline:rhi.Pipeline,x,y:u32,
) {
    rhi.cmd_bind_pipeline(cmd,pipeline)
    rhi.cmd_bind_buffer(cmd,0,gpu.params)
    rhi.cmd_bind_buffer(cmd,1,gpu.input)
    rhi.cmd_bind_buffer(cmd,2,gpu.fits)
    rhi.cmd_bind_buffer(cmd,3,gpu.output)
    rhi.cmd_dispatch(cmd,x,y)
}
