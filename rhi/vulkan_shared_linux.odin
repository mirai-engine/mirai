#+build linux
package rhi

import "core:sys/linux"
import vk "vendor:vulkan"

// On Linux the memory travels as a file descriptor. The process that draws
// keeps it open; the one that shows takes its own copy with pidfd_getfd,
// which needs it to be the parent (the editor of its players) or allowed to
// trace the other.

VK_SHARED_EXTENSION :: "VK_KHR_external_memory_fd"
VK_SHARED_HANDLE :: vk.ExternalMemoryHandleTypeFlags{.OPAQUE_FD}

@(private) Vk_Shared_Name :: struct {}
@(private) Vk_Shared_Import :: struct {info: vk.ImportMemoryFdInfoKHR}

@(private)
vk_shared_export_info :: proc(d: ^Device, export: ^vk.ExportMemoryAllocateInfo, name: ^Vk_Shared_Name, serial: u32) {}

// The descriptor of the memory, which is also what names it to the process that imports.
@(private)
vk_shared_export :: proc(d: ^Device, memory: vk.DeviceMemory, serial: u32) -> (handle: uintptr, id: u32, ok: bool) {
	info := vk.MemoryGetFdInfoKHR{sType = .MEMORY_GET_FD_INFO_KHR, memory = memory, handleType = VK_SHARED_HANDLE}
	fd: i32
	if !vk_check(d, d.dvk.GetMemoryFdKHR(d.handle, &info, &fd), "vkGetMemoryFdKHR") {return}
	return uintptr(fd) + 1, u32(fd), true
}

@(private)
vk_shared_close :: proc(handle: uintptr) {linux.close(linux.Fd(handle - 1))}

@(private)
vk_shared_import_info :: proc(d: ^Device, imported: ^Vk_Shared_Import, pid, id: u32) -> bool {
	pidfd, open_error := linux.pidfd_open(linux.Pid(pid), {})
	if open_error != .NONE {set_error(d, "shared texture: pidfd_open failed: %v", open_error); return false}
	defer linux.close(linux.Fd(pidfd))
	fd, get_error := linux.pidfd_getfd(pidfd, linux.Fd(id), 0)
	if get_error != .NONE {set_error(d, "shared texture: pidfd_getfd failed: %v", get_error); return false}
	imported.info = {sType = .IMPORT_MEMORY_FD_INFO_KHR, handleType = VK_SHARED_HANDLE, fd = i32(fd)}
	return true
}

@(private)
vk_shared_import_next :: proc(imported: ^Vk_Shared_Import) -> rawptr {return &imported.info}

// Vulkan owns the descriptor only once the memory is allocated.
@(private)
vk_shared_import_failed :: proc(imported: ^Vk_Shared_Import) {linux.close(linux.Fd(imported.info.fd))}
