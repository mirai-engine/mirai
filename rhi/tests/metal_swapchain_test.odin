#+build darwin
package rhi_tests

import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import "core:sync"
import NS "core:sys/darwin/Foundation"
import CA "vendor:darwin/QuartzCore"

@(test)
metal_unpaced_frames_keep_rendering_until_a_drawable_is_ready :: proc(t:^testing.T) {
	NS.scoped_autoreleasepool()
	shared_device.hold(t)
	layer:=CA.MetalLayer.layer()
	d,error:=rhi.device_create({validation=true,upload_bytes_per_frame=1<<20,surface={metal_layer=layer,width=8,height=8}})
	testing.expect(t,d!=nil,error)
	if d==nil {return}
	defer rhi.device_destroy(d)
	// Holds the request until the GPU work without a drawable finishes.
	a:=&d.swapchain.acquire
	sync.mutex_lock(&a.mutex)
	a.state=.Pending
	sync.mutex_unlock(&a.mutex)
	input:=[4]f32{1,2,3,4}
	src:=rhi.buffer_create(d,{size=size_of(input),usage={.Storage},memory=.GPU})
	dst:=rhi.buffer_create(d,{size=size_of(input),usage={.Storage},memory=.GPU})
	pipeline:=rhi.pipeline_create_compute(d,{shader=rhi.test_shader("fill.comp")})
	testing.expect(t,src!=0 && dst!=0 && pipeline!=0,rhi.device_error(d))
	if src==0 || dst==0 || pipeline==0 {return}
	testing.expect(t,rhi.buffer_upload_slice(d,src,0,input[:]),rhi.device_error(d))
	Params :: struct {count:u32,scale,offset:f32,pad:u32}
	for i in 0..<8 {
		cmd,ok:=rhi.frame_begin(d)
		testing.expect(t,ok,rhi.device_error(d))
		if !ok {return}
		testing.expect_value(t,rhi.swapchain_texture(d),rhi.Texture(0))
		params:=Params{count=4,scale=2,offset=f32(i)}
		rhi.cmd_bind_pipeline(cmd,pipeline)
		rhi.cmd_set_constants(cmd,0,&params,size_of(params))
		rhi.cmd_bind_buffer(cmd,1,src)
		rhi.cmd_bind_buffer(cmd,2,dst)
		rhi.cmd_dispatch(cmd,1)
		testing.expect(t,rhi.frame_end(d,cmd),rhi.device_error(d))
	}
	echo:[4]f32
	testing.expect(t,rhi.buffer_read_slice(d,dst,0,echo[:]),rhi.device_error(d))
	testing.expect_value(t,echo,[4]f32{9,11,13,15})
	sync.sema_post(&a.wake)
	rhi.swapchain_set_vsync(d,true)
	cmd,ok:=rhi.frame_begin(d)
	testing.expect(t,ok,rhi.device_error(d))
	if ok {
		testing.expect(t,rhi.swapchain_texture(d)!=0)
		pass:=rhi.Render_Pass_Desc{color_count=1}
		pass.colors[0]={texture=rhi.swapchain_texture(d),load=.Clear,store=.Store,clear={0.2,0.3,0.4,1}}
		rhi.cmd_begin_render_pass(cmd,&pass)
		rhi.cmd_end_render_pass(cmd)
		testing.expect(t,rhi.frame_end(d,cmd),rhi.device_error(d))
	}
	rhi.swapchain_resize(d,0,0)
	_,ok=rhi.frame_begin(d)
	testing.expect(t,!ok)
	rhi.swapchain_resize(d,16,16)
	rhi.swapchain_set_vsync(d,false)
	cmd,ok=rhi.frame_begin(d)
	testing.expect(t,ok,rhi.device_error(d))
	if ok {testing.expect(t,rhi.frame_end(d,cmd),rhi.device_error(d))}
}
