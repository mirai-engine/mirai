package importer

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"

// A build of Fast textures is named apart from the Final builds, where only a
// refresh that takes Fast looks, while the machine chooses it for the package.
@(test)
a_fast_build_is_named_apart_from_the_final_builds :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t)
    if device==nil {return}
    gpu:textures.Gpu_Context
    if !testing.expect_value(t,textures.gpu_context_init(&gpu,device,""),textures.Error.None) {
        return
    }
    defer textures.gpu_context_destroy(&gpu)
    folder:=base.test_folder(t,"outputs-fast")
    if folder=="" {return}
    s:=test_store(t,fmt.tprintf("%s/store",folder))
    if s==nil {return}
    model:=model_source(t,folder,"crate",import_version(0))
    report,error:=import_write(&model,{store=s,fast_textures=true,gpu=&gpu},context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    testing.expect(t,!report.final,"its texture is Fast")
    digits:[64]u8
    _,shared:=store.ref_get(s,asset.REF_IMPORTS,store.hex(report.key,&digits))
    fast,local:=store.ref_get(s,asset.REF_IMPORTS_FAST,store.hex(report.key,&digits))
    testing.expect(t,shared==.Missing && local==.None && fast==report.build,"published under the namespace of Fast builds alone")
    p,_,_:=test_package(t,s,report)
    chosen,_:=store.ref_get(s,asset.REF_BUILDS,store.hex(asset.build_select(report.manifest,&p),&digits))
    testing.expect(t,chosen==report.build,"the build this machine chose")
    list:=asset.Packages{packages=make([dynamic]asset.Project_Package,context.temp_allocator)}
    append(&list.packages,asset.Project_Package{id=p.id,manifest=report.manifest})
    resolved,resolve_error:=asset.packages_resolve(s,"",&list,context.temp_allocator)
    testing.expect(t,resolve_error==.None && len(resolved.problems)==0 && len(resolved.listed)==2,"a project lists the mesh and the texture of the package")
    for l in resolved.listed {testing.expectf(t,l.state==.Built && asset.object_whole(s,l.object) && l.header.id==l.id,"%s is built",l.path)}
}

@(test)
finalizing_a_fast_build_uses_bounded_jobs_and_publishes_in_output_order :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t)
    if device==nil {return}
    gpu:textures.Gpu_Context
    if !testing.expect_value(t,textures.gpu_context_init(&gpu,device,""),textures.Error.None) {
        return
    }
    defer textures.gpu_context_destroy(&gpu)
    folder:=base.test_folder(t,"final-textures")
    if folder=="" {return}
    s:=test_store(t,folder)
    if s==nil {return}
    defer store.close(s)
    model:=model_source(t,folder,"crate",import_version(0))
    model.images=make([]Imported_Image,24,context.temp_allocator)
    for &image,i in model.images {
        pixels:=make([]u8,8*8*4,context.temp_allocator)
        for &texel,j in pixels {texel=u8(j*7+i) if j%4!=3 else 255}
        image={name=fmt.tprintf("texture-%d",i),made=textures.rgba8(pixels,8,8),srgb=true}
    }
    report,import_error:=import_write(&model,{store=s,fast_textures=true,gpu=&gpu},context.temp_allocator)
    if !testing.expectf(t,import_error.code==.None,"%s",import_error.message) {return}
    _,fast,read:=test_package(t,s,report)
    if !read || !testing.expect(t,!fast.final) {return}
    textures_at:=make([dynamic]int,context.temp_allocator)
    for output,i in fast.outputs {
        if output.kind==asset.KIND_TEXTURE {append(&textures_at,i)}
    }
    if !testing.expect_value(t,len(textures_at),len(model.images)) {return}

    heap:=runtime.heap_allocator()
    tracking:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracking,heap,heap)
    defer mem.tracking_allocator_destroy(&tracking)
    tracked:=mem.tracking_allocator(&tracking)
    js:jobs.Job_System
    if !testing.expect(t,jobs.system_init(&js,{threads=2,allocator=tracked})) {return}
    defer jobs.system_destroy(&js)
    on:=jobs.Worker_Ref{system=&js}
    baseline:=tracking.current_memory_allocated

    first:=fast
    first.key=store.address_of_bytes(transmute([]u8)string("one texture"))
    first.outputs=make([dynamic]asset.Build_Output,1,context.temp_allocator)
    copy(first.outputs[:],fast.outputs[textures_at[0]:][:1])
    {
        context.allocator=tracked
        _,error:=finalize_build(s,&first,on,&gpu)
        if !testing.expect_value(t,error,asset.Error.None) {return}
    }
    single_peak:=tracking.peak_memory_allocated-baseline
    testing.expect_value(t,tracking.current_memory_allocated,baseline)

    // The first Fast texture has a cached Final encode. The others have only their inputs.
    final:=fast
    address:store.Hash
    {
        context.allocator=tracked
        error:asset.Error
        address,error=finalize_build(s,&final,on,&gpu)
        if !testing.expect_value(t,error,asset.Error.None) {return}
    }
    testing.expect(t,jobs.system_stats(&js).stolen>0,"other workers finalized textures")
    testing.expect_value(t,tracking.current_memory_allocated,baseline)
    testing.expect(t,tracking.peak_memory_allocated-baseline<=i64(jobs.worker_count(&js)+1)*single_peak,
        "texture scratch grows with the job window")
    testing.expect_value(t,final.outputs[textures_at[0]].object,first.outputs[0].object)
    digits:[64]u8
    ref,ref_error:=store.ref_get(s,asset.REF_IMPORTS,store.hex(fast.key,&digits))
    testing.expect(t,ref_error==.None && ref==address)
    saved,error:=asset.build_get(s,address,context.temp_allocator)
    if !testing.expect(t,error==.None && saved.final && len(saved.outputs)==len(fast.outputs)) {return}
    for &output,i in fast.outputs {
        if output.kind==asset.KIND_TEXTURE {
            testing.expect(t,saved.outputs[i].object!=output.object && saved.outputs[i].id==output.id)
        } else {
            testing.expect_value(t,saved.outputs[i],output)
        }
    }
    serial:=fast
    serial_hash,serial_error:=finalize_build(s,&serial,{},&gpu)
    testing.expect(t,serial_error==.None && serial_hash==address)

    // A bad texture in a later batch leaves the build and the published ref intact.
    failed:=fast
    failed.outputs=make([dynamic]asset.Build_Output,len(fast.outputs),context.temp_allocator)
    copy(failed.outputs[:],fast.outputs[:])
    failed.outputs[textures_at[len(textures_at)-1]].id={99,99}
    snapshot:=slice.clone(failed.outputs[:],context.temp_allocator)
    {
        context.allocator=tracked
        object,error:=finalize_build(s,&failed,on,&gpu)
        testing.expect(t,error==.Corrupt && object=={})
    }
    ref,ref_error=store.ref_get(s,asset.REF_IMPORTS,store.hex(fast.key,&digits))
    testing.expect(t,ref_error==.None && ref==address)
    testing.expect(t,!failed.final && slice.equal(failed.outputs[:],snapshot))
    testing.expect_value(t,tracking.current_memory_allocated,baseline)
    {
        context.temp_allocator=runtime.nil_allocator()
        _,error:=finalize_build(s,&failed,on,&gpu)
        testing.expect_value(t,error,asset.Error.Out_Of_Memory)
    }
}
