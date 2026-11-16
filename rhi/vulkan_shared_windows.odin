#+build windows
package rhi

import "core:fmt"
import "core:os"
import win "core:sys/windows"
import vk "vendor:vulkan"

// On Windows the memory travels as a named handle: Local\mirai-<pid>-<serial>.
// The process that draws keeps the handle open, which keeps the name; the
// one that shows imports by name.

VK_SHARED_EXTENSION :: "VK_KHR_external_memory_win32"
VK_SHARED_HANDLE :: vk.ExternalMemoryHandleTypeFlags{.OPAQUE_WIN32}

@(private) Vk_Shared_Name :: struct {info: vk.ExportMemoryWin32HandleInfoKHR, text: [64]u16}
@(private) Vk_Shared_Import :: struct {info: vk.ImportMemoryWin32HandleInfoKHR, text: [64]u16}

@(private)
vk_shared_name :: proc(text: ^[64]u16, pid, serial: u32) -> win.LPCWSTR {
	name := fmt.tprintf("Local\\mirai-%d-%d", pid, serial)
	n := 0
	for c in name {if n < len(text) - 1 {text[n] = u16(c); n += 1}}
	text[n] = 0
	return cast(win.LPCWSTR)&text[0]
}

@(private)
vk_shared_export_info :: proc(d: ^Device, export: ^vk.ExportMemoryAllocateInfo, name: ^Vk_Shared_Name, serial: u32) {
	name.info = {sType = .EXPORT_MEMORY_WIN32_HANDLE_INFO_KHR, dwAccess = 0x10000000, name = vk_shared_name(&name.text, u32(os.get_pid()), serial)} // GENERIC_ALL
	export.pNext = &name.info
}

@(private)
vk_shared_export :: proc(d: ^Device, memory: vk.DeviceMemory, serial: u32) -> (handle: uintptr, id: u32, ok: bool) {
	info := vk.MemoryGetWin32HandleInfoKHR{sType = .MEMORY_GET_WIN32_HANDLE_INFO_KHR, memory = memory, handleType = VK_SHARED_HANDLE}
	h: vk.HANDLE
	if !vk_check(d, d.dvk.GetMemoryWin32HandleKHR(d.handle, &info, &h), "vkGetMemoryWin32HandleKHR") {return}
	return uintptr(h), serial, true
}

@(private)
vk_shared_close :: proc(handle: uintptr) {win.CloseHandle(win.HANDLE(handle))}

@(private)
vk_shared_import_info :: proc(d: ^Device, imported: ^Vk_Shared_Import, pid, id: u32) -> bool {
	imported.info = {sType = .IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR, handleType = VK_SHARED_HANDLE, name = vk_shared_name(&imported.text, pid, id)}
	return true
}

@(private)
vk_shared_import_next :: proc(imported: ^Vk_Shared_Import) -> rawptr {return &imported.info}

@(private)
vk_shared_import_failed :: proc(imported: ^Vk_Shared_Import) {}
