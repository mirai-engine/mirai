#+build darwin
package rhi_tests

import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"

@(test)
rhi_metal_shader_functions_share_ownership_and_release_after_failed_pipeline :: proc(t:^testing.T) {
    shared_device.hold(t)
    device,error:=rhi.device_create({on_message = rhi.message_print, app_name="shader cache test",validation=true})
    testing.expect(t,device!=nil,error);if device==nil {return}
    defer rhi.device_destroy(device)
    desc:=rhi.Graphics_Pipeline_Desc{vertex=rhi.test_shader("triangle.vert"),fragment=rhi.test_shader("triangle.frag"),color_formats={0=.RGBA8_Unorm},color_count=1}
    first:=rhi.pipeline_create_graphics(device,desc)
    testing.expect(t,first!=0,rhi.device_error(device));if first==0 {return}
    desc.color_formats[0]=.RGBA16_Float
    second:=rhi.pipeline_create_graphics(device,desc)
    testing.expect(t,second!=0,rhi.device_error(device));if second==0 {return}
    testing.expect_value(t,device.shaders.count,2)
    for shader,i in device.shaders.items {if device.shaders.alive[i] {testing.expect_value(t,shader.users,u32(2))}}
    bad:=rhi.test_shader("triangle.frag")^;bad.msl_entry="missing_entry"
    desc.fragment=&bad
    testing.expect_value(t,rhi.pipeline_create_graphics(device,desc),rhi.Pipeline(0))
    testing.expect_value(t,device.shaders.count,2)
    for shader,i in device.shaders.items {if device.shaders.alive[i] {testing.expect_value(t,shader.users,u32(2))}}
    // Identical source in another generation shares both functions. The cache
    // owns its identity: caller buffers can change and be freed immediately.
    vertex,fragment:=rhi.test_shader("triangle.vert")^,rhi.test_shader("triangle.frag")^
    vertex_bytes:=make([]u8,len(vertex.msl)+32);fragment_bytes:=make([]u8,len(fragment.msl)+32)
    vertex_length:=copy(vertex_bytes,vertex.msl);fragment_length:=copy(fragment_bytes,fragment.msl)
    vertex.msl=string(vertex_bytes[:vertex_length]);fragment.msl=string(fragment_bytes[:fragment_length])
    desc.vertex=&vertex;desc.fragment=&fragment
    candidate:=rhi.pipeline_create_graphics(device,desc)
    testing.expect(t,candidate!=0,rhi.device_error(device));if candidate==0 {return}
    testing.expect_value(t,device.shaders.count,2)
    vertex_length+=copy(vertex_bytes[vertex_length:],"\n// changed source\n")
    fragment_length+=copy(fragment_bytes[fragment_length:],"\n// changed source\n")
    vertex.msl=string(vertex_bytes[:vertex_length]);fragment.msl=string(fragment_bytes[:fragment_length])
    changed:=rhi.pipeline_create_graphics(device,desc)
    delete(vertex_bytes);delete(fragment_bytes)
    testing.expect(t,changed!=0,rhi.device_error(device));if changed==0 {return}
    testing.expect_value(t,device.shaders.count,4)
    rhi.pipeline_destroy(device,first);rhi.pipeline_destroy(device,second)
    testing.expect_value(t,device.shaders.count,4)
    rhi.pipeline_destroy(device,candidate)
    testing.expect_value(t,device.shaders.count,2)
    rhi.pipeline_destroy(device,changed)
    testing.expect_value(t,device.shaders.count,0)
    testing.expect_value(t,rhi.device_validation_errors(device),0)
}
