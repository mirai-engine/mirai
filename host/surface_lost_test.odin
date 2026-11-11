#+build linux, windows
package host

import "core:strings"
import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"
import vk "vendor:vulkan"

// The platform callback that makes the window's surface, counted and able to refuse.
@(private = "file")
Counted_Surface :: struct {
	create: rhi.Vulkan_Surface_Proc,
	user:   rawptr,
	calls:  int,
	refuse: bool,
}

@(private = "file")
counted_surface :: proc(instance: rawptr, user: rawptr) -> (u64, bool) {
	c := cast(^Counted_Surface)user
	c.calls += 1
	if c.refuse {return 0, false}
	return c.create(instance, c.user)
}

// What the driver answers after a display change or a reset that lost the surface.
@(private = "file")
lost_acquire :: proc "system" (device: vk.Device, swapchain: vk.SwapchainKHR, timeout: u64, semaphore: vk.Semaphore, fence: vk.Fence, index: ^u32) -> vk.Result {
	return .ERROR_SURFACE_LOST_KHR
}

@(private = "file")
present_one :: proc(d: ^rhi.Device) -> bool {
	cmd, ok := rhi.frame_begin(d)
	return ok && rhi.frame_end(d, cmd)
}

// A frame that finds the window's surface lost (a test double of
// vkAcquireNextImageKHR: a display change cannot be forced) is skipped, and the
// next one makes the surface and the swapchain again from the window and
// presents. A surface the platform cannot make again leaves the window without
// images after VK_SURFACE_TRIES frames, with an error that says so.
@(test)
a_lost_window_surface_is_made_again_and_the_next_frame_presents :: proc(t: ^testing.T) {
	shared_device.hold(t)
	app, error := app_create({gpu = true, gpu_validation = true, window = true, window_desc = {size = {64, 48}, hidden = true}, fixed_dt = 1.0 / 60, threads = 1})
	if app == nil {
		testing.expectf(t, rhi.gpu_skip_allowed(), "no application with a GPU: %v (set MIRAI_ALLOW_GPU_SKIP=1 to skip)", error)
		return
	}
	defer app_destroy(app)
	d := app.device
	sc := &d.swapchain
	counted := Counted_Surface{create = sc.desc.vulkan_create, user = sc.desc.vulkan_user}
	sc.desc.vulkan_create, sc.desc.vulkan_user = counted_surface, &counted
	if !testing.expect(t, present_one(d), rhi.device_error(d)) {return}
	lose :: proc(d: ^rhi.Device) -> (began: bool) {
		acquire := d.dvk.AcquireNextImageKHR
		d.dvk.AcquireNextImageKHR = lost_acquire
		_, began = rhi.frame_begin(d)
		d.dvk.AcquireNextImageKHR = acquire
		return
	}
	testing.expect(t, !lose(d), "the frame the lost surface gave no image is skipped")
	before := rhi.present_stats(d).presented
	testing.expect(t, present_one(d), rhi.device_error(d))
	testing.expectf(t, counted.calls == 1 && rhi.present_stats(d).presented == before + 1, "the surface was made %d times and %d frames presented", counted.calls, rhi.present_stats(d).presented - before)
	testing.expect(t, present_one(d), rhi.device_error(d))
	testing.expectf(t, rhi.device_validation_errors(d) == 0, "validation: %s", rhi.device_validation_message(d))

	testing.expect(t, !lose(d))
	counted.refuse = true
	for _ in 0 ..< 2 * rhi.VK_SURFACE_TRIES {
		_, began := rhi.frame_begin(d)
		testing.expect(t, !began, "a window without a surface gives no frame")
	}
	testing.expectf(t, counted.calls == 1 + rhi.VK_SURFACE_TRIES, "the platform was asked %d times for the surface", counted.calls - 1)
	testing.expect(t, strings.contains(rhi.device_error(d), "lost its Vulkan surface"), rhi.device_error(d))
	failure, _ := rhi.device_failure(d)
	testing.expect_value(t, failure, rhi.Device_Failure.None)
}
