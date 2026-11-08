package host

import "core:testing"
import "mirai:rhi"
import "mirai:std/base"

// A request reserves only the rings, not the ~13 MB of buffers that only an
// editor recording reads, and lasts through the next frame.
@(test)
a_request_reserves_the_rings_and_lasts_a_frame :: proc(t:^testing.T) {
    app: App
    app.allocator = context.allocator
    defer profile_release(&app)

    testing.expect(t, !profile_active(&app))
    if !testing.expect(t, profile_request(&app)) {return}
    testing.expect(t, app.profiler.rings_ready)
    testing.expect(t, !app.profiler.reserved)
    testing.expect_value(t, len(app.profiler.zones), 0)
    testing.expect_value(t, profile_threads(&app), 1)
    for frame in 0 ..< 2 {
        testing.expectf(t, profile_active(&app), "frame %d after the request records", frame)
        profile_frame_open(&app)
        zone := profile_part(&app, "work")
        base.profile_end(zone)
        profile_frame_end(&app, false)
    }
    testing.expect(t, !profile_active(&app), "without a new request the frame after the next records nothing")
    zones: [8]base.Profile_Zone
    count, _, _ := profile_read(&app, 0, 0, zones[:])
    testing.expect_value(t, count, 4)
}

// The rings are reserved once; starting a recording adds its buffers without
// initializing or leaking the rings.
@(test)
a_recording_adds_its_buffers_to_ready_rings :: proc(t:^testing.T) {
    app: App
    app.allocator = context.allocator
    defer profile_release(&app)

    if !testing.expect(t, profile_reserve_rings(&app)) {return}
    profile := &app.profiler.profile
    if !testing.expect(t, profile_reserve(&app)) {return}
    testing.expect(t, &app.profiler.profile == profile)
    testing.expect(t, app.profiler.reserved)
    testing.expect_value(t, len(app.profiler.frames), PROFILE_FRAMES_MAX)
    testing.expect_value(t, len(app.profiler.zones), PROFILE_ZONES)
    testing.expect_value(t, len(app.profiler.passes), PROFILE_PASSES)
    testing.expect_value(t, len(app.profiler.cursors), 1)
}

// The GPU times of an rhi frame come back frames after it, and go to the
// recorded frame that submitted it, once, on the clock of the zones.
@(test)
gpu_times_go_to_the_frame_that_submitted_them :: proc(t:^testing.T) {
    app: App
    app.allocator = context.allocator
    defer profile_release(&app)
    if !testing.expect(t, profile_reserve(&app)) {return}
    p := &app.profiler
    p.frames[0] = {device_first = 10, device_end = 11}
    p.frames[1] = {device_first = 11, device_end = 13} // two submissions in one frame
    p.frame_count = 2
    testing.expect(t, !profile_gpu_done(p))

    before := [1]rhi.Gpu_Timing{{name = "frame", ms = 1, start_ns = 100, end_ns = 1100}}
    profile_gpu_add(p, before[:], 9, 0)
    testing.expect_value(t, p.pass_count, 0)

    first := [2]rhi.Gpu_Timing{{name = "shadow", ms = 2, start_ns = 1000, end_ns = 3000}, {name = "main", ms = 3, start_ns = 3000, end_ns = 6000}}
    profile_gpu_add(p, first[:], 10, 500)
    profile_gpu_add(p, first[:], 10, 500) // the renderer keeps them until the next ones
    testing.expect(t, p.frames[0].gpu)
    testing.expect_value(t, p.frames[0].pass_first, 0)
    testing.expect_value(t, p.frames[0].pass_count, 2)
    testing.expect_value(t, p.frames[0].gpu_ms, 5)
    testing.expect_value(t, p.passes[0].start_ns, 500)
    testing.expect_value(t, p.passes[1].end_ns, 5500)
    testing.expect_value(t, profile_pass_name(&app, p.passes[1].name), "main")

    second := [1]rhi.Gpu_Timing{{name = "main", ms = 4, start_ns = 7000, end_ns = 11000}}
    profile_gpu_add(p, second[:], 11, 500)
    testing.expect(t, p.frames[1].gpu)
    testing.expect(t, !profile_gpu_done(p))
    profile_gpu_add(p, second[:], 12, 500)
    testing.expect_value(t, p.frames[1].pass_first, 2)
    testing.expect_value(t, p.frames[1].pass_count, 2)
    testing.expect_value(t, p.frames[1].gpu_ms, 8)
    testing.expect(t, profile_gpu_done(p))
}
