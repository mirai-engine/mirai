#+build windows
package rhi

import win "core:sys/windows"
import vk "vendor:vulkan"

// The clock of time.tick_now.
VK_HOST_TIME_DOMAIN :: vk.TimeDomainKHR.QUERY_PERFORMANCE_COUNTER

@(private)
vk_host_clock_rate :: proc() -> i64 {
	frequency: win.LARGE_INTEGER
	win.QueryPerformanceFrequency(&frequency)
	return i64(frequency)
}
