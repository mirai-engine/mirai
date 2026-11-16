#+build linux, windows
package rhi

import "core:reflect"
import vk "vendor:vulkan"

// Every device has the Vulkan procedures of its own instance and device. The
// package-level pointers of vendor:vulkan are one set per process: a second
// device would load them over the first, with nil for whatever extension the
// second one does not enable.

// Instance-level procedures the backend calls, loaded with vkGetInstanceProcAddr.
@(private)
Vk_Instance_Procs :: struct {
	// Available before an instance exists.
	CreateInstance:                          vk.ProcCreateInstance,
	EnumerateInstanceExtensionProperties:    vk.ProcEnumerateInstanceExtensionProperties,
	EnumerateInstanceLayerProperties:        vk.ProcEnumerateInstanceLayerProperties,
	// Of the instance.
	DestroyInstance:                         vk.ProcDestroyInstance,
	EnumeratePhysicalDevices:                vk.ProcEnumeratePhysicalDevices,
	EnumerateDeviceExtensionProperties:      vk.ProcEnumerateDeviceExtensionProperties,
	GetPhysicalDeviceFeatures2:              vk.ProcGetPhysicalDeviceFeatures2,
	GetPhysicalDeviceFormatProperties:       vk.ProcGetPhysicalDeviceFormatProperties,
	GetPhysicalDeviceMemoryProperties:       vk.ProcGetPhysicalDeviceMemoryProperties,
	GetPhysicalDeviceMemoryProperties2:      vk.ProcGetPhysicalDeviceMemoryProperties2,
	GetPhysicalDeviceProperties:             vk.ProcGetPhysicalDeviceProperties,
	GetPhysicalDeviceProperties2:            vk.ProcGetPhysicalDeviceProperties2,
	GetPhysicalDeviceQueueFamilyProperties:  vk.ProcGetPhysicalDeviceQueueFamilyProperties,
	GetPhysicalDeviceSurfaceCapabilitiesKHR: vk.ProcGetPhysicalDeviceSurfaceCapabilitiesKHR,
	GetPhysicalDeviceSurfaceFormatsKHR:      vk.ProcGetPhysicalDeviceSurfaceFormatsKHR,
	GetPhysicalDeviceSurfacePresentModesKHR: vk.ProcGetPhysicalDeviceSurfacePresentModesKHR,
	GetPhysicalDeviceSurfaceSupportKHR:      vk.ProcGetPhysicalDeviceSurfaceSupportKHR,
	CreateDevice:                            vk.ProcCreateDevice,
	GetDeviceProcAddr:                       vk.ProcGetDeviceProcAddr,
	CreateDebugUtilsMessengerEXT:            vk.ProcCreateDebugUtilsMessengerEXT,
	DestroyDebugUtilsMessengerEXT:           vk.ProcDestroyDebugUtilsMessengerEXT,
	DestroySurfaceKHR:                       vk.ProcDestroySurfaceKHR,
	GetPhysicalDeviceCalibrateableTimeDomainsKHR: vk.ProcGetPhysicalDeviceCalibrateableTimeDomainsKHR,
	GetPhysicalDeviceCalibrateableTimeDomainsEXT: vk.ProcGetPhysicalDeviceCalibrateableTimeDomainsEXT,
}

// Fills a struct whose fields are procedure pointers named after the Vulkan
// procedure without its "vk". A procedure the driver does not have stays nil.
@(private)
vk_load_procs :: proc(table: rawptr, type: typeid, get_instance: vk.ProcGetInstanceProcAddr, instance: vk.Instance, get_device: vk.ProcGetDeviceProcAddr, device: vk.Device) {
	names := reflect.struct_field_names(type)
	offsets := reflect.struct_field_offsets(type)
	for name, i in names {
		buffer: [128]u8
		buffer[0], buffer[1] = 'v', 'k'
		if len(name) + 3 > len(buffer) {continue}
		copy(buffer[2:], name)
		symbol := cstring(&buffer[0])
		address: vk.ProcVoidFunction
		if get_device != nil {address = get_device(device, symbol)} else {address = get_instance(instance, symbol)}
		slot := cast(^rawptr)(uintptr(table) + offsets[i])
		// Loading the instance procedures keeps the ones loaded before it existed.
		if address != nil || get_device != nil {slot^ = rawptr(address)}
	}
}
