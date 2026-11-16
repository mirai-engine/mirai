#+build linux, windows
package rhi

import "core:testing"
import vk "vendor:vulkan"

// With a window, a device is chosen only through a graphics+compute queue
// family that presents to its surface, even against a better type or the
// preferred name; without one the type and the name decide.
@(test)
vk_pick_chooses_a_device_that_presents_to_the_window :: proc(t: ^testing.T) {
	both := vk.QueueFamilyProperties{queueFlags = {.GRAPHICS, .COMPUTE, .TRANSFER}}
	compute := vk.QueueFamilyProperties{queueFlags = {.COMPUTE}}
	Device :: struct {type: vk.PhysicalDeviceType, name: string, families: []vk.QueueFamilyProperties, presents: []b32}
	discrete := Device{.DISCRETE_GPU, "Discrete RTX", {both, compute}, {false, true}}
	integrated := Device{.INTEGRATED_GPU, "Integrated Xe", {compute, both}, {true, true}}
	silent := Device{.INTEGRATED_GPU, "Integrated Xe", {compute, both}, {true, false}}
	presenting := Device{.DISCRETE_GPU, "Discrete RTX", {both}, {true}}
	Case :: struct {name: string, window: bool, preferred: string, devices: []Device, chosen: int}
	cases := []Case {
		{"without a window the discrete one", false, "", {integrated, discrete}, 1},
		{"with a window the one that presents", true, "", {discrete, integrated}, 1},
		{"the preferred name that cannot present is passed over", true, "rtx", {discrete, integrated}, 1},
		{"of two that present the discrete one", true, "", {integrated, presenting}, 1},
		{"of two that present the preferred name", true, "xe", {presenting, integrated}, 1},
		{"a family that presents without graphics does not count", true, "", {silent, discrete}, -1},
		{"without a window the preferred name wins", false, "xe", {discrete, integrated}, 1},
	}
	for c in cases {
		candidates := make([]Vk_Candidate, len(c.devices), context.temp_allocator)
		for device, i in c.devices {
			candidates[i] = {type = device.type, name = device.name, family = vk_queue_family(device.families, device.presents if c.window else nil)}
		}
		chosen := vk_pick(candidates, c.preferred)
		testing.expectf(t, chosen == c.chosen, "%s: device %d chosen, not %d", c.name, chosen, c.chosen)
		if chosen >= 0 && c.window {testing.expect(t, bool(c.devices[chosen].presents[candidates[chosen].family]), c.name)}
	}
	testing.expect_value(t, vk_queue_family({}, nil), -1)
	testing.expect_value(t, vk_queue_family({both, both}, {false}), -1)
}
