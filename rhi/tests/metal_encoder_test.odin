#+build darwin
package rhi_tests

import "core:testing"
import NS "core:sys/darwin/Foundation"
import "mirai:rhi"
import "mirai:rhi/shared_device"

@(private="file")
fill_inside_pool :: proc(cmd:^rhi.Command_List,buffer:rhi.Buffer) {
	NS.scoped_autoreleasepool()
	rhi.cmd_fill_buffer(cmd,buffer,0,16,0xAB)
}

@(test)
metal_command_encoder_survives_nested_autorelease_pool :: proc(t:^testing.T) {
	shared_device.hold(t)
	d,err:=rhi.device_create({on_message=rhi.message_print,app_name="nested encoder",validation=true})
	if !testing.expectf(t,d!=nil,"device: %s",err) {return}
	defer rhi.device_destroy(d)
	buffer:=rhi.buffer_create(d,{size=16,usage={.Storage},memory=.GPU,name="nested pool"})
	if !testing.expect(t,buffer!=0,rhi.device_error(d)) {return}
	defer rhi.buffer_destroy(d,buffer)
	cmd,ok:=rhi.frame_begin(d)
	if !testing.expect(t,ok,rhi.device_error(d)) {return}
	fill_inside_pool(cmd,buffer)
	testing.expect(t,rhi.frame_end(d,cmd),rhi.device_error(d))
	testing.expect(t,rhi.device_wait_idle(d),rhi.device_error(d))
	data:[4]u32
	testing.expect(t,rhi.buffer_read_slice(d,buffer,0,data[:]),rhi.device_error(d))
	testing.expect_value(t,data,[4]u32{0xABABABAB,0xABABABAB,0xABABABAB,0xABABABAB})
	testing.expect_value(t,rhi.device_validation_errors(d),0)
}
