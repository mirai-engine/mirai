#+build linux, windows
package rhi

import "core:os"
import "mirai:std/base"
import vk "vendor:vulkan"

// Shared textures: an image whose memory another process imports, with the
// external memory of the system (VK_SHARED_EXTENSION). Both processes create
// the same image on the same device; the one that draws leaves it ready to be
// sampled at the end of each frame, so the one that imports takes it in that
// layout.
//
// A Shared_Texture is the pid of the process that draws, a check of the image
// it created and what names the memory (the descriptor on Linux, the serial on
// Windows), 16 bits each: the memory carries no size, so a driver would take
// an image of another size over it, and the check is what refuses it.

// The device has the external memory of the system: textures can be shared.
device_shares_textures :: proc "contextless" (d: ^Device) -> bool {return d != nil && d.shared_memory}

texture_create_shared :: proc(d: ^Device, desc: Texture_Desc) -> (Texture, Shared_Texture) {
	t, ok := vk_shared_image(d, desc)
	if !ok {return 0, 0}
	export := vk.ExportMemoryAllocateInfo{sType = .EXPORT_MEMORY_ALLOCATE_INFO, handleTypes = VK_SHARED_HANDLE}
	name: Vk_Shared_Name
	d.shared_serial = d.shared_serial % 0xFFFF + 1
	vk_shared_export_info(d, &export, &name, d.shared_serial)
	if !vk_shared_memory(d, &t, &export) {return 0, 0}
	handle, id, exported := vk_shared_export(d, t.memory.handle, d.shared_serial)
	if !exported {vk_release_texture(d, &t); return 0, 0}
	if id > 0xFFFF {
		vk_shared_close(handle)
		vk_release_texture(d, &t)
		set_error(d, "shared texture %s: its handle %d does not fit in 16 bits", desc.name, id)
		return 0, 0
	}
	t.shared = handle
	return vk_shared_finish(d, &t, desc), Shared_Texture(u64(u32(os.get_pid())) << 32 | u64(vk_shared_check(desc)) << 16 | u64(id))
}

texture_open_shared :: proc(d: ^Device, desc: Texture_Desc, shared: Shared_Texture) -> Texture {
	if u16(u64(shared) >> 16) != vk_shared_check(desc) {
		set_error(d, "shared texture %s: it is not an image of %dx%d and that format", desc.name, desc.width, desc.height)
		return 0
	}
	t, ok := vk_shared_image(d, desc)
	if !ok {return 0}
	imported: Vk_Shared_Import
	if !vk_shared_import_info(d, &imported, u32(u64(shared) >> 32), u32(u16(shared))) {vk_release_texture(d, &t); return 0}
	if !vk_shared_memory(d, &t, vk_shared_import_next(&imported)) {
		vk_shared_import_failed(&imported)
		return 0
	}
	// The one that draws leaves it ready to be sampled.
	t.layout = .SHADER_READ_ONLY_OPTIMAL
	t.reads = {.Shader_Read}
	return vk_shared_finish(d, &t, desc)
}

// What the image both processes create alike must agree on, folded to 16 bits.
@(private)
vk_shared_check :: proc "contextless" (desc: Texture_Desc) -> u16 {
	h := desc.width * 0x9E3779B1 ~ desc.height * 0x85EBCA6B ~ u32(desc.format) * 0xC2B2AE35
	h ~= h >> 15
	h *= 0x2C1B3C6D
	return u16(h >> 16)
}

// The image both processes create alike: one level of a format of four bytes per texel.
@(private)
vk_shared_image :: proc(d: ^Device, desc: Texture_Desc) -> (t: Vk_Texture, ok: bool) {
	if !d.shared_memory {set_error(d, "shared texture %s: the device has no %s", desc.name, VK_SHARED_EXTENSION); return}
	if format_size(desc.format) != 4 || desc.width == 0 || desc.height == 0 || max(desc.mip_levels, 1) > 1 {
		set_error(d, "shared texture %s: one level of a format of four bytes per texel", desc.name)
		return
	}
	if !device_room(d, &d.textures, "textures") {return}
	t = Vk_Texture{desc = desc}
	t.desc.name = ""
	t.desc.mip_levels = 1
	t.vk_format = vk_format(desc.format)
	t.aspect = {.COLOR}
	usage: vk.ImageUsageFlags = {.TRANSFER_DST, .TRANSFER_SRC}
	if .Sampled in desc.usage {usage += {.SAMPLED}}
	if .Storage in desc.usage {usage += {.STORAGE}}
	if .Color_Target in desc.usage {usage += {.COLOR_ATTACHMENT}}
	external := vk.ExternalMemoryImageCreateInfo{sType = .EXTERNAL_MEMORY_IMAGE_CREATE_INFO, handleTypes = VK_SHARED_HANDLE}
	info := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO, pNext = &external, imageType = .D2, format = t.vk_format,
		extent = {desc.width, desc.height, 1}, mipLevels = 1, arrayLayers = 1, samples = {._1}, tiling = .OPTIMAL,
		usage = usage, sharingMode = .EXCLUSIVE, initialLayout = .UNDEFINED,
	}
	if !vk_check(d, d.dvk.CreateImage(d.handle, &info, nil, &t.image), "vkCreateImage") {return}
	t.layout = .UNDEFINED
	return t, true
}

// Dedicated memory for the image, exported or imported by what next chains.
@(private)
vk_shared_memory :: proc(d: ^Device, t: ^Vk_Texture, next: rawptr) -> bool {
	requirements: vk.MemoryRequirements
	d.dvk.GetImageMemoryRequirements(d.handle, t.image, &requirements)
	types, count := vk_memory_candidates(d, requirements.memoryTypeBits, {.DEVICE_LOCAL}, {})
	if count == 0 {types, count = vk_memory_candidates(d, requirements.memoryTypeBits, {}, {})}
	dedicated := vk.MemoryDedicatedAllocateInfo{sType = .MEMORY_DEDICATED_ALLOCATE_INFO, pNext = next, image = t.image}
	if !vk_memory_room(&d.memory) {
		set_error(d, "shared texture: the driver gives %d memory allocations at once (maxMemoryAllocationCount) and all are taken", d.memory.limit)
		vk_release_texture(d, t)
		return false
	}
	result := vk.Result.ERROR_OUT_OF_DEVICE_MEMORY
	memory: vk.DeviceMemory
	for i in 0 ..< count {
		info := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, pNext = &dedicated, allocationSize = requirements.size, memoryTypeIndex = types[i]}
		if result = d.dvk.AllocateMemory(d.handle, &info, nil, &memory); result == .SUCCESS {break}
	}
	if result != .SUCCESS {
		set_error(d, "shared texture: vkAllocateMemory failed for %d bytes: %v", requirements.size, result)
		vk_release_texture(d, t)
		return false
	}
	t.memory = vk_memory_adopt(&d.memory, memory, u64(requirements.size))
	if !vk_check(d, d.dvk.BindImageMemory(d.handle, t.image, memory, 0), "binding memory") {
		vk_release_texture(d, t)
		return false
	}
	return true
}

@(private)
vk_shared_finish :: proc(d: ^Device, t: ^Vk_Texture, desc: Texture_Desc) -> Texture {
	view_info := vk.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO, image = t.image, viewType = .D2, format = t.vk_format,
		subresourceRange = {aspectMask = t.aspect, levelCount = 1, layerCount = 1},
	}
	d.dvk.CreateImageView(d.handle, &view_info, nil, &t.view)
	vk_set_name(d, .IMAGE, u64(t.image), desc.name)
	return Texture(pool_add(&d.textures, t^))
}
