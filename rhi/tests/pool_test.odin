package rhi_tests

import "core:fmt"
import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:std/base"

@(private="file")
small_device :: proc(t:^testing.T,capacities:rhi.Device_Capacities,upload:u64=1<<20) -> ^rhi.Device {
    shared_device.hold(t)
    d,err:=rhi.device_create({app_name="mirai rhi capacity tests",validation=true,upload_bytes_per_frame=upload,capacities=capacities})
    if d==nil {
        if rhi.gpu_skip_allowed() {fmt.eprintln("rhi tests skipped:",err)} else {testing.expectf(t,false,"no GPU device: %s (set MIRAI_ALLOW_GPU_SKIP=1 to skip)",err)}
    }
    return d
}

@(test)
rhi_full_pool_refuses_a_resource_and_counts_it :: proc(t:^testing.T) {
    d:=small_device(t,{samplers=2})
    if d==nil {return}
    defer rhi.device_destroy(d)
    a:=rhi.sampler_create(d,{filter=.Linear})
    b:=rhi.sampler_create(d,{filter=.Nearest})
    testing.expect(t,a!=0 && b!=0,rhi.device_error(d))
    testing.expect_value(t,rhi.device_stats(d).exhausted,0)
    testing.expect_value(t,rhi.sampler_create(d,{filter=.Linear}),rhi.Sampler(0))
    stats:=rhi.device_stats(d)
    testing.expect_value(t,stats.exhausted,1)
    testing.expect_value(t,stats.samplers,2)
    testing.expect(t,rhi.device_error(d)!="","a refused resource leaves a message")
    rhi.sampler_destroy(d,a)
    c:=rhi.sampler_create(d,{filter=.Linear})
    testing.expect(t,c!=0,rhi.device_error(d))
    testing.expect(t,c!=a,"the slot of a destroyed sampler comes back under another handle")
    testing.expect_value(t,rhi.device_stats(d).exhausted,1)
    testing.expect_value(t,rhi.device_validation_errors(d),0)
}

@(test)
rhi_device_reports_what_is_alive :: proc(t:^testing.T) {
    d:=small_device(t,{})
    if d==nil {return}
    defer rhi.device_destroy(d)
    before:=rhi.device_stats(d)
    buffer:=rhi.buffer_create(d,{size=64,usage={.Storage},name="counted"})
    texture:=rhi.texture_create(d,{width=4,height=4,format=.RGBA8_Unorm,usage={.Sampled},name="counted"})
    testing.expect(t,buffer!=0 && texture!=0,rhi.device_error(d))
    after:=rhi.device_stats(d)
    testing.expect_value(t,after.buffers,before.buffers+1)
    testing.expect_value(t,after.textures,before.textures+1)
    rhi.buffer_destroy(d,buffer)
    rhi.texture_destroy(d,texture)
    testing.expect_value(t,rhi.device_stats(d).buffers,before.buffers)
    testing.expect_value(t,rhi.device_stats(d).textures,before.textures)
    testing.expect(t,rhi.buffer_mapped(d,buffer)==nil && rhi.buffer_size(d,buffer)==0,"a destroyed buffer is no buffer")
    testing.expect_value(t,rhi.device_validation_errors(d),0)
}

@(test)
rhi_destroying_more_than_a_frame_slot_holds_between_frames_releases_them :: proc(t:^testing.T) {
    d:=small_device(t,{deletions=4})
    if d==nil {return}
    defer rhi.device_destroy(d)
    for _ in 0..<3 {
        for _ in 0..<10 {
            buffer:=rhi.buffer_create(d,{size=256,usage={.Storage},name="short lived"})
            testing.expect(t,buffer!=0,rhi.device_error(d))
            rhi.buffer_destroy(d,buffer)
        }
        cmd,ok:=rhi.frame_begin(d)
        testing.expect(t,ok,rhi.device_error(d));if !ok {return}
        testing.expect(t,rhi.frame_end(d,cmd),rhi.device_error(d))
    }
    stats:=rhi.device_stats(d)
    testing.expect(t,stats.deletion_overflows>0,"the slots were filled")
    for f in d.frames {testing.expectf(t,cap(f.deletions)==4,"a slot filled between frames is emptied, not grown: %d",cap(f.deletions))}
    testing.expect_value(t,rhi.device_validation_errors(d),0)
}

@(test)
rhi_frame_ring_without_room_returns_no_memory_and_counts_it :: proc(t:^testing.T) {
    d:=small_device(t,{},upload=4096)
    if d==nil {return}
    defer rhi.device_destroy(d)
    cmd,ok:=rhi.frame_begin(d)
    testing.expect(t,ok,rhi.device_error(d));if !ok {return}
    fits:=rhi.frame_alloc(d,1024)
    testing.expect(t,fits.ptr!=nil && fits.size==1024,rhi.device_error(d))
    refused:=rhi.frame_alloc(d,8192)
    testing.expect(t,refused.ptr==nil && refused.buffer==0)
    testing.expect_value(t,rhi.device_stats(d).exhausted,1)
    testing.expect(t,rhi.frame_end(d,cmd),rhi.device_error(d))
    // The ring of the next frame slot starts empty.
    cmd,ok=rhi.frame_begin(d)
    testing.expect(t,ok,rhi.device_error(d));if !ok {return}
    testing.expect(t,rhi.frame_alloc(d,2048).ptr!=nil,rhi.device_error(d))
    testing.expect(t,rhi.frame_end(d,cmd),rhi.device_error(d))
    testing.expect_value(t,rhi.device_validation_errors(d),0)
}

@(private="file")
Messages :: struct {errors,validation:int}

@(test)
rhi_messages_reach_the_presenter_the_device_was_given :: proc(t:^testing.T) {
    messages:Messages
    shared_device.hold(t)
    d,err:=rhi.device_create({app_name="mirai rhi message test",validation=true,upload_bytes_per_frame=1<<20,message_user=&messages,
        on_message=proc(kind:rhi.Message_Kind,text:string,user:rawptr) {
            messages:=cast(^Messages)user
            if kind==.Error {messages.errors+=1} else if kind==.Validation_Error {messages.validation+=1}
        }})
    if d==nil {
        if !rhi.gpu_skip_allowed() {testing.expectf(t,false,"no GPU device: %s",err)}
        return
    }
    defer rhi.device_destroy(d)
    testing.expect(t,!rhi.texture_table_set(d,u32(rhi.texture_table_limit(d)),0))
    testing.expect_value(t,messages.errors,1)
    testing.expect(t,rhi.device_error(d)!="")
    testing.expect_value(t,messages.validation,0)
}
