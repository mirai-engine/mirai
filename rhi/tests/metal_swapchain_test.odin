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
	d,error:=rhi.device_create({validation=true,on_message=rhi.message_print,upload_bytes_per_frame=1<<20,surface={metal_layer=layer,width=8,height=8}})
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
		swap:=rhi.swapchain_texture(d)
		testing.expect(t,swap!=0)
		pass:=rhi.Render_Pass_Desc{color_count=1}
		pass.colors[0]={texture=swap,load=.Clear,store=.Store,clear={0.2,0.3,0.4,1}}
		rhi.cmd_begin_render_pass(cmd,&pass)
		rhi.cmd_end_render_pass(cmd)
		upload:=rhi.frame_alloc(d,8*4)
		if testing.expect(t,upload.ptr!=nil) {
			pixels:=([^]u32)(upload.ptr)[:8]
			for &pixel in pixels {pixel=0xff8855cc}
			readback:=rhi.buffer_create(d,{size=8*8*4,memory=.Readback})
			if testing.expect(t,readback!=0,rhi.device_error(d)) {
				rhi.cmd_copy_buffer_to_texture(cmd,upload.buffer,upload.offset,swap,0,{0,3,8,1})
				rhi.cmd_copy_texture_to_buffer(cmd,swap,readback,0)
			}
			recorded:=rhi.frame_end(d,cmd)
			testing.expect(t,recorded,rhi.device_error(d))
			if readback!=0 {
				defer rhi.buffer_destroy(d,readback)
				testing.expect(t,rhi.device_wait_idle(d),rhi.device_error(d))
				echo:[64]u32
				testing.expect(t,rhi.buffer_read_slice(d,readback,0,echo[:]),rhi.device_error(d))
				testing.expect_value(t,echo[3*8],pixels[0])
				testing.expect(t,echo[2*8]!=echo[3*8])
			}
		} else {
			rhi.frame_end(d,cmd)
		}
	}
	rhi.swapchain_resize(d,0,0)
	_,ok=rhi.frame_begin(d)
	testing.expect(t,!ok)
	rhi.swapchain_resize(d,16,16)
	rhi.swapchain_set_vsync(d,false)
	cmd,ok=rhi.frame_begin(d)
	testing.expect(t,ok,rhi.device_error(d))
	if ok {testing.expect(t,rhi.frame_end(d,cmd),rhi.device_error(d))}
	testing.expect_value(t,rhi.device_validation_errors(d),0)
}
