package host

import "core:testing"
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

// Memory is sampled only by a recording that asks for it, inside the frame:
// its zone memory is a part of the frame, not time between frames.
@(test)
a_recording_samples_the_memory_only_when_asked_inside_the_frame :: proc(t:^testing.T) {
    app: App
    app.allocator = context.allocator
    defer profile_release(&app)
    for memory in ([]bool{true, false}) {
        if !testing.expect(t, profile_start(&app, 2, memory)) {return}
        for _ in 0 ..< 2 {
            profile_frame_open(&app)
            profile_frame_end(&app, false)
        }
        recording := profile_recording(&app)
        testing.expect_value(t, len(recording.frames), 2)
        sampled := false
        for zone in recording.zones {
            if zone.name == "memory" {
                sampled = true
                testing.expect_value(t, zone.depth, u16(1))
            }
        }
        testing.expect_value(t, sampled, memory)
        testing.expect_value(t, recording.frames[1].memory.process.private > 0, memory)
    }
}
