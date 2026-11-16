#+build linux, windows
package rhi

import "core:fmt"
import "core:testing"
import "mirai:std/base"
import vk "vendor:vulkan"

@(test)
rhi_loader_errors_are_not_validation_errors :: proc(t: ^testing.T) {
	d := new(Device)
	defer free(d)
	loaded_count := 0
	d.message_user = &loaded_count
	d.on_message = proc(kind: Message_Kind, text: string, user: rawptr) {
		n := cast(^int)user
		n^ += 1
	}
	data := vk.DebugUtilsMessengerCallbackDataEXT{pMessage = "loader: broken implicit layer"}
	vk_debug_callback({.ERROR}, {.GENERAL}, &data, d)
	testing.expect_value(t, device_validation_errors(d), 0)
	testing.expect_value(t, device_loader_errors(d), 1)
	testing.expect_value(t, device_validation_message(d), "")
	for i in 0 ..< VALIDATION_HISTORY + 3 {
		text := fmt.ctprintf("hazard %d", i)
		data.pMessage = text
		vk_debug_callback({.ERROR}, {.VALIDATION}, &data, d)
	}
	testing.expect_value(t, device_validation_errors(d), VALIDATION_HISTORY + 3)
	testing.expect_value(t, device_loader_errors(d), 1)
	testing.expect_value(t, loaded_count, VALIDATION_HISTORY + 4)
	testing.expect_value(t, device_validation_message(d), fmt.tprintf("hazard %d", VALIDATION_HISTORY + 2))
	history: [VALIDATION_HISTORY + 4]string
	n := device_validation_messages(d, history[:])
	testing.expect_value(t, n, VALIDATION_HISTORY)
	testing.expect_value(t, history[0], "hazard 3")
	testing.expect_value(t, history[n - 1], fmt.tprintf("hazard %d", VALIDATION_HISTORY + 2))
}
