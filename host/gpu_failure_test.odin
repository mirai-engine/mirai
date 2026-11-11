package host

import "core:log"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// After a loss the frames go on without drawing or waiting for the GPU, and
// the failure is said once, with the call that found it. The frame whose
// submission reports it is not drawn either.
@(test)
a_lost_gpu_leaves_the_frames_running_without_drawing :: proc(t:^testing.T) {
    shared_device.hold(t)
    app,error:=app_create({gpu=true,gpu_validation=true,window_desc={size={64,48}},fixed_dt=1.0/60,threads=1})
    if app==nil {
        testing.expectf(t,rhi.gpu_skip_allowed(),"no application with a GPU: %v (set MIRAI_ALLOW_GPU_SKIP=1 to skip)",error)
        return
    }
    defer app_destroy(app)
    app_frame(app)
    testing.expect_value(t,app.stats.frames_drawn,u64(1))
    before,_:=app_gpu_failure(app)
    testing.expect_value(t,before,rhi.Device_Failure.None)
    rhi.device_lose(app.device)
    // The report goes to the log as an error, which the test runner takes as a failure.
    context.logger=log.nil_logger()
    app_frame(app)
    failure,text:=app_gpu_failure(app)
    testing.expect_value(t,failure,rhi.Device_Failure.Lost)
    testing.expectf(t,strings.has_prefix(text,"the GPU device stopped working (Lost)") && strings.contains(text,"provoked by device_lose"),"the failure names its call: %s",text)
    started:=time.tick_now()
    for _ in 0..<3 {testing.expect(t,app_frame(app),"the application goes on")}
    testing.expect(t,time.tick_since(started)<time.Second,"no frame waits for the GPU")
    testing.expect_value(t,app.stats.frames,u64(5))
    testing.expect_value(t,app.stats.frames_skipped,u64(4))
    _,again:=app_gpu_failure(app)
    testing.expect_value(t,raw_data(again),raw_data(text))
    testing.expectf(t,rhi.device_validation_errors(app.device)==0,"validation: %s",rhi.device_validation_message(app.device))
}
