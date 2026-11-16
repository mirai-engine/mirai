#+build linux
package rhi

import vk "vendor:vulkan"

// The clock of time.tick_now.
VK_HOST_TIME_DOMAIN :: vk.TimeDomainKHR.CLOCK_MONOTONIC_RAW

@(private)
vk_host_clock_rate :: proc() -> i64 {return 1e9}
