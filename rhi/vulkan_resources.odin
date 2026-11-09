#+build linux, windows
package rhi

import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import "mirai:std/base"
import vk "vendor:vulkan"

@(private)
vk_format :: proc "contextless" (f: Format) -> vk.Format {
	switch f {
	case .Undefined:     return .UNDEFINED
	case .R8_Unorm:      return .R8_UNORM
	case .RG8_Unorm:     return .R8G8_UNORM
	case .RGBA8_Unorm:   return .R8G8B8A8_UNORM
	case .RGBA8_Srgb:    return .R8G8B8A8_SRGB
	case .BGRA8_Unorm:   return .B8G8R8A8_UNORM
	case .BGRA8_Srgb:    return .B8G8R8A8_SRGB
	case .R16_Float:     return .R16_SFLOAT
	case .RG16_Float:    return .R16G16_SFLOAT
	case .RGBA16_Float:  return .R16G16B16A16_SFLOAT
	case .R32_Float:     return .R32_SFLOAT
	case .RG32_Float:    return .R32G32_SFLOAT
	case .RGBA32_Float:  return .R32G32B32A32_SFLOAT
	case .R32_Uint:      return .R32_UINT
	case .RG32_Uint:     return .R32G32_UINT
	case .RGBA32_Uint:   return .R32G32B32A32_UINT
	case .R8_Uint:       return .R8_UINT
	case .RG16_Sint:     return .R16G16_SINT
	case .RG11B10_Float: return .B10G11R11_UFLOAT_PACK32
	case .D32_Float:     return .D32_SFLOAT
	case .BC1_Unorm:     return .BC1_RGB_UNORM_BLOCK
	case .BC1_Srgb:      return .BC1_RGB_SRGB_BLOCK
	case .BC3_Unorm:     return .BC3_UNORM_BLOCK
	case .BC3_Srgb:      return .BC3_SRGB_BLOCK
	case .BC5_Unorm:     return .BC5_UNORM_BLOCK
	case .BC7_Unorm:     return .BC7_UNORM_BLOCK
	case .BC7_Srgb:      return .BC7_SRGB_BLOCK
	case .BC6H_Ufloat:   return .BC6H_UFLOAT_BLOCK
	case .RGBA16_Unorm:  return .R16G16B16A16_UNORM
	}
	return .UNDEFINED
}

@(private)
vk_set_name :: proc(d: ^Device, type: vk.ObjectType, handle: u64, name: string) {
	if !d.debug_utils || name == "" || d.dvk.SetDebugUtilsObjectNameEXT == nil {return}
	info := vk.DebugUtilsObjectNameInfoEXT{sType = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT, objectType = type, objectHandle = handle, pObjectName = strings.clone_to_cstring(name, context.temp_allocator)}
	// Naming an object goes through the table of every instance of the loader.
	vk_loader_lock(d)
	d.dvk.SetDebugUtilsObjectNameEXT(d.handle, &info)
	vk_loader_unlock(d)
}

// Memory types that satisfy `required`, those with every `preferred` flag
// and none of `avoided` first, so allocation can fall back when a preferred
// heap is exhausted (e.g. the 256 MiB device-local host-visible heap without
// resizable BAR).
@(private)
vk_memory_candidates :: proc(d: ^Device, bits: u32, required, preferred: vk.MemoryPropertyFlags, avoided: vk.MemoryPropertyFlags = {}) -> (types: [32]u32, count: int) {
	for pass in 0 ..< 2 {
		for i in 0 ..< d.memory_properties.memoryTypeCount {
			if bits & (1 << i) == 0 {continue}
			flags := d.memory_properties.memoryTypes[i].propertyFlags
			if required & flags != required {continue}
			has_preferred := preferred & flags == preferred && avoided & flags == {}
			if (pass == 0) != has_preferred {continue}
			types[count] = i
			count += 1
		}
	}
	return
}

@(private)
vk_allocate :: proc(d: ^Device, requirements: vk.MemoryRequirements, kind: Memory, device_address: bool) -> (vk.DeviceMemory, bool) {
	required, preferred: vk.MemoryPropertyFlags
	switch kind {
	case .GPU:      required = {.DEVICE_LOCAL}
	case .Upload:   required = {.HOST_VISIBLE, .HOST_COHERENT}; preferred = {.DEVICE_LOCAL}
	case .Readback: required = {.HOST_VISIBLE, .HOST_COHERENT}; preferred = {.HOST_CACHED}
	case .Staging:  required = {.HOST_VISIBLE, .HOST_COHERENT}
	}
	types, count := vk_memory_candidates(d, requirements.memoryTypeBits, required, preferred, {.DEVICE_LOCAL} if kind == .Staging else {})
	if count == 0 && kind == .GPU {types, count = vk_memory_candidates(d, requirements.memoryTypeBits, {}, {})}
	if count == 0 {set_error(d, "no Vulkan memory type for %v", kind); return 0, false}
	flags_info := vk.MemoryAllocateFlagsInfo{sType = .MEMORY_ALLOCATE_FLAGS_INFO, flags = {.DEVICE_ADDRESS}}
	last: vk.Result
	for i in 0 ..< count {
		// More than its heap holds is not a request the device may get.
		if requirements.size > d.memory_properties.memoryHeaps[d.memory_properties.memoryTypes[types[i]].heapIndex].size {
			last = .ERROR_OUT_OF_DEVICE_MEMORY
			continue
		}
		info := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = requirements.size, memoryTypeIndex = types[i]}
		if device_address {info.pNext = &flags_info}
		memory: vk.DeviceMemory
		last = d.dvk.AllocateMemory(d.handle, &info, nil, &memory)
		if last == .SUCCESS {return memory, true}
	}
	set_error(d, "vkAllocateMemory failed for %v (%d bytes): %v", kind, requirements.size, last)
	return 0, false
}

@(private)
vk_create_buffer :: proc(d: ^Device, desc: Buffer_Desc, extra_usage: vk.BufferUsageFlags = {}, zero := true) -> Buffer {
	if !device_room(d, &d.buffers, "buffers") {return 0}
	usage := extra_usage | {.TRANSFER_DST, .TRANSFER_SRC}
	if .Index in desc.usage {usage += {.INDEX_BUFFER}}
	if .Uniform in desc.usage {usage += {.UNIFORM_BUFFER}}
	if .Storage in desc.usage {usage += {.STORAGE_BUFFER}}
	if .Indirect in desc.usage {usage += {.INDIRECT_BUFFER}}
	device_address := d.info.features.ray_query && (.Accel_Input in desc.usage || .SHADER_DEVICE_ADDRESS in extra_usage)
	if d.info.features.ray_query && .Accel_Input in desc.usage {usage += {.ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR}}
	if device_address {usage += {.SHADER_DEVICE_ADDRESS}}
	size := max(desc.size, 16)
	info := vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = vk.DeviceSize(size), usage = usage, sharingMode = .EXCLUSIVE}
	b: Vk_Buffer
	if !vk_check(d, d.dvk.CreateBuffer(d.handle, &info, nil, &b.handle), "vkCreateBuffer") {return 0}
	requirements: vk.MemoryRequirements
	d.dvk.GetBufferMemoryRequirements(d.handle, b.handle, &requirements)
	memory, ok := vk_allocate(d, requirements, desc.memory, device_address)
	if !ok {d.dvk.DestroyBuffer(d.handle, b.handle, nil); return 0}
	b.memory = memory
	d.dvk.BindBufferMemory(d.handle, b.handle, b.memory, 0)
	if desc.memory != .GPU {
		if !vk_check(d, d.dvk.MapMemory(d.handle, b.memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &b.mapped), "vkMapMemory") {
			d.dvk.DestroyBuffer(d.handle, b.handle, nil)
			d.dvk.FreeMemory(d.handle, b.memory, nil)
			return 0
		}
		if zero {mem.zero(b.mapped, int(size))}
	}
	if device_address {
		address_info := vk.BufferDeviceAddressInfo{sType = .BUFFER_DEVICE_ADDRESS_INFO, buffer = b.handle}
		b.address = u64(d.dvk.GetBufferDeviceAddress(d.handle, &address_info))
	}
	b.size = size
	b.usage = desc.usage
	b.kind = desc.memory
	vk_set_name(d, .BUFFER, u64(b.handle), desc.name)
	return Buffer(pool_add(&d.buffers, b))
}

buffer_create :: proc(d: ^Device, desc: Buffer_Desc) -> Buffer {return vk_create_buffer(d, desc)}

// Staging buffers of a completed (fenced) transaction are released at once
// instead of waiting for frame slots that may never run (headless loads).
@(private)
vk_release_buffer_now :: proc(d: ^Device, buffer: Buffer) {
	b, ok := pool_remove(&d.buffers, base.Handle(buffer))
	if !ok {return}
	if b.mapped != nil {d.dvk.UnmapMemory(d.handle, b.memory)}
	d.dvk.DestroyBuffer(d.handle, b.handle, nil)
	d.dvk.FreeMemory(d.handle, b.memory, nil)
}

buffer_destroy :: proc(d: ^Device, buffer: Buffer) {
	b, ok := pool_remove(&d.buffers, base.Handle(buffer))
	if !ok {return}
	if b.mapped != nil {d.dvk.UnmapMemory(d.handle, b.memory)}
	vk_defer(d, {buffer = b.handle, memory = b.memory})
}

buffer_mapped :: proc(d: ^Device, buffer: Buffer) -> rawptr {
	b := pool_get(&d.buffers, base.Handle(buffer))
	return b.mapped if b != nil else nil
}

buffer_size :: proc(d: ^Device, buffer: Buffer) -> u64 {
	b := pool_get(&d.buffers, base.Handle(buffer))
	return b.size if b != nil else 0
}

texture_create :: proc(d: ^Device, desc: Texture_Desc) -> Texture {
	if desc.depth > 1 && (.Storage not_in desc.usage || .Color_Target in desc.usage || .Depth_Target in desc.usage) {set_error(d, "texture %s: a 3D texture needs the Storage usage and no target usage, since shaders write it", desc.name); return 0}
	if problem := texture_layers_problem(desc, d.info.max_texture_layers); problem != "" {set_error(d, "texture %s: %s", desc.name, problem); return 0}
	layers := max(desc.layers, 1)
	if desc.cube && layers > 6 && !d.cube_arrays {set_error(d, "texture %s: this device samples no arrays of cubes (imageCubeArray)", desc.name); return 0}
	if !device_room(d, &d.textures, "textures") {return 0}
	t := Vk_Texture{desc = desc}
	t.desc.name = ""
	t.desc.mip_levels = max(desc.mip_levels, 1)
	t.desc.layers = layers
	assert(t.desc.mip_levels <= MAX_TEXTURE_MIPS)
	t.vk_format = vk_format(desc.format)
	depth := format_is_depth(desc.format)
	t.aspect = {.DEPTH} if depth else {.COLOR}
	usage: vk.ImageUsageFlags = {.TRANSFER_DST, .TRANSFER_SRC}
	if .Sampled in desc.usage {usage += {.SAMPLED}}
	if .Storage in desc.usage {usage += {.STORAGE}}
	if .Color_Target in desc.usage {usage += {.COLOR_ATTACHMENT}}
	if .Depth_Target in desc.usage {usage += {.DEPTH_STENCIL_ATTACHMENT}}
	volume := desc.depth > 1
	info := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO, imageType = .D3 if volume else .D2, format = t.vk_format,
		extent = {max(desc.width, 1), max(desc.height, 1), max(desc.depth, 1)},
		mipLevels = t.desc.mip_levels, arrayLayers = layers, samples = {._1}, tiling = .OPTIMAL,
		usage = usage, sharingMode = .EXCLUSIVE, initialLayout = .UNDEFINED,
	}
	if desc.cube {info.flags = {.CUBE_COMPATIBLE}}
	view_type: vk.ImageViewType = .D3 if volume else .D2
	switch {
	case desc.cube:  view_type = .CUBE if layers == 6 else .CUBE_ARRAY
	case layers > 1: view_type = .D2_ARRAY
	}
	format_props: vk.FormatProperties
	d.ivk.GetPhysicalDeviceFormatProperties(d.physical, t.vk_format, &format_props)
	features := format_props.optimalTilingFeatures
	missing := ""
	if .Sampled in desc.usage && !(.SAMPLED_IMAGE in features) {missing = "sampling"}
	if .Storage in desc.usage && !(.STORAGE_IMAGE in features) {missing = "storage"}
	if .Color_Target in desc.usage && !(.COLOR_ATTACHMENT in features) {missing = "color attachment"}
	if .Depth_Target in desc.usage && !(.DEPTH_STENCIL_ATTACHMENT in features) {missing = "depth attachment"}
	if missing != "" {set_error(d, "texture %s: format %v does not support %s on this device", desc.name, desc.format, missing); return 0}
	if !vk_check(d, d.dvk.CreateImage(d.handle, &info, nil, &t.image), "vkCreateImage") {return 0}
	requirements: vk.MemoryRequirements
	d.dvk.GetImageMemoryRequirements(d.handle, t.image, &requirements)
	memory, ok := vk_allocate(d, requirements, .GPU, false)
	if !ok {d.dvk.DestroyImage(d.handle, t.image, nil); return 0}
	t.memory = memory
	d.dvk.BindImageMemory(d.handle, t.image, t.memory, 0)
	view_info := vk.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO, image = t.image, viewType = view_type, format = t.vk_format,
		subresourceRange = {aspectMask = t.aspect, levelCount = t.desc.mip_levels, layerCount = layers},
	}
	d.dvk.CreateImageView(d.handle, &view_info, nil, &t.view)
	if t.desc.mip_levels > 1 {
		for mip in 0 ..< t.desc.mip_levels {
			view_info.subresourceRange.baseMipLevel = mip
			view_info.subresourceRange.levelCount = 1
			d.dvk.CreateImageView(d.handle, &view_info, nil, &t.mip_views[mip])
		}
	}
	t.layout = .UNDEFINED
	vk_set_name(d, .IMAGE, u64(t.image), desc.name)
	return Texture(pool_add(&d.textures, t))
}

@(private)
vk_release_texture :: proc(d: ^Device, t: ^Vk_Texture) {
	for v in t.mip_views {if v != 0 {d.dvk.DestroyImageView(d.handle, v, nil)}}
	if t.view != 0 {d.dvk.DestroyImageView(d.handle, t.view, nil)}
	if t.image != 0 {d.dvk.DestroyImage(d.handle, t.image, nil)}
	if t.memory != 0 {d.dvk.FreeMemory(d.handle, t.memory, nil)}
}

texture_destroy :: proc(d: ^Device, texture: Texture) {
	if t := pool_get(&d.textures, base.Handle(texture)); t == nil || t.swapchain {return}
	for entry, index in d.table_textures {if entry == texture {texture_table_set(d, u32(index), 0)}}
	t, _ := pool_remove(&d.textures, base.Handle(texture))
	if t.shared != 0 {vk_shared_close(t.shared)}
	e := Vk_Deferred{image = t.image, memory = t.memory}
	e.views[0] = t.view
	for v, i in t.mip_views {e.views[i + 1] = v}
	vk_defer(d, e)
}

texture_desc :: proc(d: ^Device, texture: Texture) -> Texture_Desc {
	t := pool_get(&d.textures, base.Handle(texture))
	return t.desc if t != nil else {}
}

sampler_create :: proc(d: ^Device, desc: Sampler_Desc) -> Sampler {
	if !device_room(d, &d.samplers, "samplers") {return 0}
	filter: vk.Filter = .LINEAR if desc.filter == .Linear else .NEAREST
	mip: vk.SamplerMipmapMode = .LINEAR if desc.mip_filter == .Linear else .NEAREST
	address: vk.SamplerAddressMode = .REPEAT if desc.address == .Repeat else .CLAMP_TO_EDGE
	info := vk.SamplerCreateInfo{
		sType = .SAMPLER_CREATE_INFO, magFilter = filter, minFilter = filter, mipmapMode = mip,
		addressModeU = address, addressModeV = address, addressModeW = address,
		maxLod = desc.max_lod if desc.max_lod > 0 else 1000,
	}
	if desc.anisotropy > 1 && d.anisotropy {
		info.anisotropyEnable = true
		info.maxAnisotropy = min(desc.anisotropy, d.properties.limits.maxSamplerAnisotropy)
	}
	reduction := vk.SamplerReductionModeCreateInfo{sType = .SAMPLER_REDUCTION_MODE_CREATE_INFO}
	if desc.reduction != .Average {
		reduction.reductionMode = .MIN if desc.reduction == .Min else .MAX
		info.pNext = &reduction
	}
	sampler: vk.Sampler
	if !vk_check(d, d.dvk.CreateSampler(d.handle, &info, nil, &sampler), "vkCreateSampler") {return 0}
	vk_set_name(d, .SAMPLER, u64(sampler), desc.name)
	return Sampler(pool_add(&d.samplers, sampler))
}

sampler_destroy :: proc(d: ^Device, sampler: Sampler) {
	if s, ok := pool_remove(&d.samplers, base.Handle(sampler)); ok {vk_defer(d, {sampler = s})}
}

// ---------------------------------------------------------------- texture table

// The table is a descriptor set per copy (TEXTURE_TABLE_COPIES), each shared
// by every pipeline that declares it: one binding of sampled images whose
// count each set takes when it is allocated, up to table_limit. It starts
// with TEXTURE_TABLE_FIRST entries.
@(private)
vk_create_texture_table :: proc(d: ^Device) -> bool {
	binding := vk.DescriptorSetLayoutBinding{
		binding = TEXTURE_TABLE_SLOT, descriptorType = .SAMPLED_IMAGE, descriptorCount = u32(d.table_limit),
		stageFlags = {.VERTEX, .FRAGMENT, .COMPUTE},
	}
	flags := vk.DescriptorBindingFlags{.VARIABLE_DESCRIPTOR_COUNT}
	binding_flags := vk.DescriptorSetLayoutBindingFlagsCreateInfo{sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO, bindingCount = 1, pBindingFlags = &flags}
	layout_info := vk.DescriptorSetLayoutCreateInfo{sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO, pNext = &binding_flags, bindingCount = 1, pBindings = &binding}
	if !vk_check(d, d.dvk.CreateDescriptorSetLayout(d.handle, &layout_info, nil, &d.table_layout), "texture table layout") {return false}
	d.table_default = texture_create(d, {width = 1, height = 1, format = .RGBA8_Unorm, usage = {.Sampled}, name = "texture table default"})
	white := [4]u8{255, 255, 255, 255}
	if d.table_default == 0 || !texture_upload(d, d.table_default, white[:], 4) {return false}
	d.table_textures = make([dynamic]Texture, d.allocator)
	for &copy in d.table_changes {copy = make([dynamic]u64, d.allocator)}
	return vk_table_grow(d, TEXTURE_TABLE_FIRST)
}

// Makes the copies of the table with capacity entries, each with the texture
// of its entry or the default, and lets the ones before go once the GPU no
// longer reads them. Between frames.
@(private)
vk_table_grow :: proc(d: ^Device, capacity: int) -> bool {
	taken, taken_error := make([]u32, capacity, d.allocator)
	images, images_error := make([]vk.DescriptorImageInfo, capacity, d.allocator)
	defer delete(images, d.allocator)
	if taken_error != nil || images_error != nil {
		delete(taken, d.allocator)
		set_error(d, "texture table of %d entries: out of memory", capacity)
		return false
	}
	size := vk.DescriptorPoolSize{type = .SAMPLED_IMAGE, descriptorCount = u32(capacity * TEXTURE_TABLE_COPIES)}
	pool_info := vk.DescriptorPoolCreateInfo{sType = .DESCRIPTOR_POOL_CREATE_INFO, maxSets = TEXTURE_TABLE_COPIES, poolSizeCount = 1, pPoolSizes = &size}
	pool: vk.DescriptorPool
	if !vk_check(d, d.dvk.CreateDescriptorPool(d.handle, &pool_info, nil, &pool), "texture table pool") {delete(taken, d.allocator); return false}
	layouts: [TEXTURE_TABLE_COPIES]vk.DescriptorSetLayout
	counts: [TEXTURE_TABLE_COPIES]u32
	for i in 0 ..< TEXTURE_TABLE_COPIES {layouts[i], counts[i] = d.table_layout, u32(capacity)}
	variable := vk.DescriptorSetVariableDescriptorCountAllocateInfo{sType = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO, descriptorSetCount = TEXTURE_TABLE_COPIES, pDescriptorCounts = &counts[0]}
	alloc := vk.DescriptorSetAllocateInfo{sType = .DESCRIPTOR_SET_ALLOCATE_INFO, pNext = &variable, descriptorPool = pool, descriptorSetCount = TEXTURE_TABLE_COPIES, pSetLayouts = &layouts[0]}
	sets: [TEXTURE_TABLE_COPIES]vk.DescriptorSet
	if !vk_check(d, d.dvk.AllocateDescriptorSets(d.handle, &alloc, &sets[0]), "texture table sets") {
		d.dvk.DestroyDescriptorPool(d.handle, pool, nil)
		delete(taken, d.allocator)
		return false
	}
	resize(&d.table_textures, capacity)
	for &image, index in images {
		shown := d.table_textures[index] if index < len(d.table_textures) && d.table_textures[index] != 0 else d.table_default
		image = {imageView = pool_get(&d.textures, base.Handle(shown)).view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	}
	writes: [TEXTURE_TABLE_COPIES]vk.WriteDescriptorSet
	for &write, copy in writes {
		write = {
			sType = .WRITE_DESCRIPTOR_SET, dstSet = sets[copy], dstBinding = TEXTURE_TABLE_SLOT,
			descriptorCount = u32(capacity), descriptorType = .SAMPLED_IMAGE, pImageInfo = &images[0],
		}
	}
	d.dvk.UpdateDescriptorSets(d.handle, TEXTURE_TABLE_COPIES, &writes[0], 0, nil)
	if d.table_pool != 0 {vk_defer(d, {descriptor_pool = d.table_pool})}
	d.table_pool, d.table_sets = pool, sets
	delete(d.table_taken, d.allocator)
	d.table_taken = taken
	table_changes_reset(&d.table_changes, capacity)
	return true
}

// Puts a texture in an entry of the table; texture 0 gives the entry back to
// the white default. A transaction between frames that waits for nothing:
// each copy of the table takes it when its next list begins. The texture
// must have the Sampled usage alone and be uploaded already.
texture_table_set :: proc(d: ^Device, index: u32, texture: Texture) -> bool {
	assert(!d.in_frame, "rhi: the texture table changes between frames")
	if int(index) >= len(d.table_textures) {
		grown := table_grown(len(d.table_textures), int(index), d.table_limit)
		if grown == 0 {set_error(d, "texture table index %d out of range: the device holds %d entries", index, d.table_limit); return false}
		if !vk_table_grow(d, grown) {return false}
	}
	shown := texture if texture != 0 else d.table_default
	t := pool_get(&d.textures, base.Handle(shown))
	if t == nil || t.desc.usage != {.Sampled} || t.layout != .SHADER_READ_ONLY_OPTIMAL {
		set_error(d, "texture table entry %d needs an uploaded texture with the Sampled usage alone", index)
		return false
	}
	if t.desc.layers > 1 || t.desc.cube || t.desc.depth > 1 {
		set_error(d, "texture table entry %d: shaders read the table as 2D textures of one layer", index)
		return false
	}
	d.table_textures[index] = texture
	table_changed(&d.table_changes, index)
	return true
}

// Writes into a copy of the table the entries it has not taken, once the
// GPU no longer reads it.
@(private)
vk_table_take :: proc(d: ^Device, copy: int) {
	entries := d.table_taken
	count := table_take(&d.table_changes, copy, entries)
	BATCH :: 64
	images: [BATCH]vk.DescriptorImageInfo
	writes: [BATCH]vk.WriteDescriptorSet
	for first := 0; first < count; first += BATCH {
		n := min(count - first, BATCH)
		for i in 0 ..< n {
			index := entries[first + i]
			shown := d.table_textures[index] if d.table_textures[index] != 0 else d.table_default
			images[i] = {imageView = pool_get(&d.textures, base.Handle(shown)).view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
			writes[i] = {
				sType = .WRITE_DESCRIPTOR_SET, dstSet = d.table_sets[copy], dstBinding = TEXTURE_TABLE_SLOT, dstArrayElement = index,
				descriptorCount = 1, descriptorType = .SAMPLED_IMAGE, pImageInfo = &images[i],
			}
		}
		d.dvk.UpdateDescriptorSets(d.handle, u32(n), &writes[0], 0, nil)
	}
}

// ---------------------------------------------------------------- pipelines

@(private)
vk_descriptor_type :: proc "contextless" (kind: Binding_Kind) -> vk.DescriptorType {
	switch kind {
	case .Uniform_Buffer:                     return .UNIFORM_BUFFER
	case .Storage_Buffer, .Storage_Buffer_RW: return .STORAGE_BUFFER
	case .Sampled_Texture:                    return .SAMPLED_IMAGE
	case .Storage_Texture:                    return .STORAGE_IMAGE
	case .Sampler:                            return .SAMPLER
	case .Accel:                              return .ACCELERATION_STRUCTURE_KHR
	case .Texture_Table:                      return .SAMPLED_IMAGE
	}
	return .UNIFORM_BUFFER
}

@(private)
vk_stage_flags :: proc "contextless" (stages: Shader_Stages) -> vk.ShaderStageFlags {
	flags: vk.ShaderStageFlags
	if .Vertex in stages {flags += {.VERTEX}}
	if .Fragment in stages {flags += {.FRAGMENT}}
	if .Compute in stages {flags += {.COMPUTE}}
	return flags
}

@(private)
vk_shader_module :: proc(d: ^Device, code: ^Shader_Code) -> vk.ShaderModule {
	if len(code.spirv) == 0 || len(code.spirv) % 4 != 0 {set_error(d, "shader %s has no SPIR-V", code.name); return 0}
	// Vulkan requires u32 aligned code and #load data is byte aligned. The
	// copy is heap memory: every shader of the engine is megabytes, more than
	// the scratch memory of the caller may hold.
	words := cast([^]u32)raw_data(code.spirv)
	aligned: []u32
	defer delete(aligned, d.allocator)
	if uintptr(words) % align_of(u32) != 0 {
		aligned = make([]u32, len(code.spirv) / 4, d.allocator)
		if aligned == nil {set_error(d, "shader %s: out of memory", code.name); return 0}
		mem.copy(raw_data(aligned), raw_data(code.spirv), len(code.spirv))
		words = raw_data(aligned)
	}
	info := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(code.spirv), pCode = words}
	module: vk.ShaderModule
	if !vk_check(d, d.dvk.CreateShaderModule(d.handle, &info, nil, &module), "vkCreateShaderModule") {return 0}
	return module
}

@(private)
vk_merge_bindings :: proc(d: ^Device, p: ^Vk_Pipeline, stages: Shader_Stages, codes: ..^Shader_Code) -> bool {
	stage_mask: [MAX_BINDING_SLOTS]Shader_Stages
	for code in codes {
		if code == nil {continue}
		for b in code.bindings {
			if !binding_slot_valid(b.slot, b.kind) {set_error(d, "shader %s uses slot %d beyond the limit", code.name, b.slot); return false}
			if b.kind == .Texture_Table {p.uses_table = true; continue}
			slot := &p.slots[b.slot]
			if slot.used && slot.kind != b.kind {set_error(d, "shader %s redeclares slot %d with another kind", code.name, b.slot); return false}
			slot.used = true
			slot.kind = b.kind
			stage_mask[b.slot] += {code.stage}
			p.slot_mask |= 1 << b.slot
		}
	}
	entries: [MAX_BINDING_SLOTS]vk.DescriptorSetLayoutBinding
	count: u32
	for slot, i in p.slots {
		if !slot.used {continue}
		entries[count] = {binding = u32(i), descriptorType = vk_descriptor_type(slot.kind), descriptorCount = 1, stageFlags = vk_stage_flags(stage_mask[i])}
		count += 1
	}
	set_info := vk.DescriptorSetLayoutCreateInfo{sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO, flags = {.PUSH_DESCRIPTOR_KHR}, bindingCount = count, pBindings = &entries[0]}
	if !vk_check(d, d.dvk.CreateDescriptorSetLayout(d.handle, &set_info, nil, &p.set_layout), "descriptor set layout") {return false}
	set_layouts := [2]vk.DescriptorSetLayout{p.set_layout, d.table_layout}
	layout_info := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = 2 if p.uses_table else 1, pSetLayouts = &set_layouts[0]}
	return vk_check(d, d.dvk.CreatePipelineLayout(d.handle, &layout_info, nil, &p.layout), "pipeline layout")
}

@(private)
vk_release_pipeline :: proc(d: ^Device, p: ^Vk_Pipeline) {
	if p.handle != 0 {d.dvk.DestroyPipeline(d.handle, p.handle, nil)}
	if p.layout != 0 {d.dvk.DestroyPipelineLayout(d.handle, p.layout, nil)}
	if p.set_layout != 0 {d.dvk.DestroyDescriptorSetLayout(d.handle, p.set_layout, nil)}
}

// Holds a pipeline made on any thread; 0 when the pool is full.
@(private)
vk_pipeline_add :: proc(d: ^Device, p: ^Vk_Pipeline) -> Pipeline {
	sync.guard(&d.pipeline_lock)
	if !device_room(d, &d.pipelines, "pipelines") {vk_release_pipeline(d, p); return 0}
	return Pipeline(pool_add(&d.pipelines, p^))
}

@(private)
vk_pipeline_room :: proc(d: ^Device) -> bool {
	sync.guard(&d.pipeline_lock)
	return device_room(d, &d.pipelines, "pipelines")
}

pipeline_create_compute :: proc(d: ^Device, desc: Compute_Pipeline_Desc) -> Pipeline {
	if !vk_pipeline_room(d) {return 0}
	p := Vk_Pipeline{bind_point = .COMPUTE, name = desc.name}
	if desc.shader == nil || desc.shader.stage != .Compute {set_error(d, "compute pipeline %s needs a compute shader", desc.name); return 0}
	if !vk_merge_bindings(d, &p, {.Compute}, desc.shader) {vk_release_pipeline(d, &p); return 0}
	module := vk_shader_module(d, desc.shader)
	if module == 0 {vk_release_pipeline(d, &p); return 0}
	defer d.dvk.DestroyShaderModule(d.handle, module, nil)
	info := vk.ComputePipelineCreateInfo{
		sType = .COMPUTE_PIPELINE_CREATE_INFO,
		stage = {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.COMPUTE}, module = module, pName = "main"},
		layout = p.layout,
	}
	started := time.tick_now()
	if !vk_check(d, d.dvk.CreateComputePipelines(d.handle, d.pipeline_cache, 1, &info, nil, &p.handle), desc.name) {vk_release_pipeline(d, &p); return 0}
	vk_pipeline_made(d, time.tick_since(started))
	vk_set_name(d, .PIPELINE, u64(p.handle), desc.name)
	return vk_pipeline_add(d, &p)
}

@(private)
vk_compare :: proc "contextless" (c: Compare) -> vk.CompareOp {
	switch c {
	case .Never:         return .NEVER
	case .Less:          return .LESS
	case .Less_Equal:    return .LESS_OR_EQUAL
	case .Equal:         return .EQUAL
	case .Greater:       return .GREATER
	case .Greater_Equal: return .GREATER_OR_EQUAL
	case .Always:        return .ALWAYS
	}
	return .ALWAYS
}

pipeline_create_graphics :: proc(d: ^Device, desc: Graphics_Pipeline_Desc) -> Pipeline {
	if !vk_pipeline_room(d) {return 0}
	p := Vk_Pipeline{bind_point = .GRAPHICS, name = desc.name}
	if desc.vertex == nil || desc.fragment == nil {set_error(d, "graphics pipeline %s needs vertex and fragment shaders", desc.name); return 0}
	if !vk_merge_bindings(d, &p, {.Vertex, .Fragment}, desc.vertex, desc.fragment) {vk_release_pipeline(d, &p); return 0}
	vertex := vk_shader_module(d, desc.vertex)
	fragment := vk_shader_module(d, desc.fragment)
	defer if vertex != 0 {d.dvk.DestroyShaderModule(d.handle, vertex, nil)}
	defer if fragment != 0 {d.dvk.DestroyShaderModule(d.handle, fragment, nil)}
	if vertex == 0 || fragment == 0 {vk_release_pipeline(d, &p); return 0}
	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vertex, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fragment, pName = "main"},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .LINE_LIST if desc.topology == .Lines else .TRIANGLE_LIST}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	cull: vk.CullModeFlags
	switch desc.cull {
	case .None:
	case .Back:  cull = {.BACK}
	case .Front: cull = {.FRONT}
	}
	raster := vk.PipelineRasterizationStateCreateInfo{
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, cullMode = cull,
		frontFace = .COUNTER_CLOCKWISE, lineWidth = 1,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	depth := vk.PipelineDepthStencilStateCreateInfo{
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable = b32(desc.depth_test), depthWriteEnable = b32(desc.depth_write),
		depthCompareOp = vk_compare(desc.depth_compare) if desc.depth_test else .ALWAYS,
	}
	attachments: [MAX_COLOR_TARGETS]vk.PipelineColorBlendAttachmentState
	formats: [MAX_COLOR_TARGETS]vk.Format
	for i in 0 ..< desc.color_count {
		formats[i] = vk_format(desc.color_formats[i])
		a := &attachments[i]
		a.colorWriteMask = {.R, .G, .B, .A}
		switch desc.blend[i] {
		case .Opaque:
		case .Alpha:
			a^ = {blendEnable = true, srcColorBlendFactor = .SRC_ALPHA, dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA, colorBlendOp = .ADD,
				srcAlphaBlendFactor = .ONE, dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA, alphaBlendOp = .ADD, colorWriteMask = {.R, .G, .B, .A}}
		case .Premultiplied:
			a^ = {blendEnable = true, srcColorBlendFactor = .ONE, dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA, colorBlendOp = .ADD,
				srcAlphaBlendFactor = .ONE, dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA, alphaBlendOp = .ADD, colorWriteMask = {.R, .G, .B, .A}}
		case .Additive:
			a^ = {blendEnable = true, srcColorBlendFactor = .ONE, dstColorBlendFactor = .ONE, colorBlendOp = .ADD,
				srcAlphaBlendFactor = .ONE, dstAlphaBlendFactor = .ONE, alphaBlendOp = .ADD, colorWriteMask = {.R, .G, .B, .A}}
		case .Multiply:
			a^ = {blendEnable = true, srcColorBlendFactor = .DST_COLOR, dstColorBlendFactor = .ZERO, colorBlendOp = .ADD,
				srcAlphaBlendFactor = .DST_ALPHA, dstAlphaBlendFactor = .ZERO, alphaBlendOp = .ADD, colorWriteMask = {.R, .G, .B, .A}}
		case .Alpha_Color:
			a^ = {blendEnable = true, srcColorBlendFactor = .SRC_ALPHA, dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA, colorBlendOp = .ADD,
				srcAlphaBlendFactor = .ZERO, dstAlphaBlendFactor = .ONE, alphaBlendOp = .ADD, colorWriteMask = {.R, .G, .B, .A}}
		}
	}
	blend := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = u32(desc.color_count), pAttachments = &attachments[0]}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo{sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO, dynamicStateCount = 2, pDynamicStates = &dynamic_states[0]}
	rendering := vk.PipelineRenderingCreateInfo{
		sType = .PIPELINE_RENDERING_CREATE_INFO, colorAttachmentCount = u32(desc.color_count), pColorAttachmentFormats = &formats[0],
		depthAttachmentFormat = vk_format(desc.depth_format),
	}
	info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO, pNext = &rendering,
		stageCount = 2, pStages = &stages[0],
		pVertexInputState = &vertex_input, pInputAssemblyState = &assembly, pViewportState = &viewport,
		pRasterizationState = &raster, pMultisampleState = &multisample, pDepthStencilState = &depth,
		pColorBlendState = &blend, pDynamicState = &dynamic_info, layout = p.layout,
	}
	started := time.tick_now()
	if !vk_check(d, d.dvk.CreateGraphicsPipelines(d.handle, d.pipeline_cache, 1, &info, nil, &p.handle), desc.name) {vk_release_pipeline(d, &p); return 0}
	vk_pipeline_made(d, time.tick_since(started))
	vk_set_name(d, .PIPELINE, u64(p.handle), desc.name)
	return vk_pipeline_add(d, &p)
}

pipeline_destroy :: proc(d: ^Device, pipeline: Pipeline) {
	sync.lock(&d.pipeline_lock)
	p, ok := pool_remove(&d.pipelines, base.Handle(pipeline))
	sync.unlock(&d.pipeline_lock)
	if ok {vk_defer(d, {pipeline = p.handle, layout = p.layout, set_layout = p.set_layout})}
}

// ---------------------------------------------------------------- transactions

buffer_upload :: proc(d: ^Device, buffer: Buffer, offset: u64, data: []u8) -> bool {
	b := pool_get(&d.buffers, base.Handle(buffer))
	if b == nil || offset + u64(len(data)) > b.size {set_error(d, "buffer_upload out of range"); return false}
	if len(data) == 0 {return true}
	if b.mapped != nil && (b.kind == .Upload || b.kind == .Staging) {
		mem.copy(rawptr(uintptr(b.mapped) + uintptr(offset)), raw_data(data), len(data))
		return true
	}
	staging := vk_create_buffer(d, {size = u64(len(data)), memory = .Staging, name = "upload staging"}, zero = false)
	if staging == 0 {return false}
	mem.copy(buffer_mapped(d, staging), raw_data(data), len(data))
	cmd := immediate_begin(d)
	cmd_copy_buffer(cmd, staging, 0, buffer, offset, u64(len(data)))
	ok := immediate_end(d, cmd)
	vk_release_buffer_now(d, staging)
	return ok
}

// Writes a region of a mip (texture_region_resolve) of every layer, whose
// texels data holds in rows bytes_per_row apart, layer after layer.
texture_upload :: proc(d: ^Device, texture: Texture, data: []u8, bytes_per_row: u32, mip: u32 = 0, region := Texture_Region{}) -> bool {
	t := pool_get(&d.textures, base.Handle(texture))
	if t == nil {return false}
	if t.desc.depth > 1 {set_error(d, "texture_upload: a 3D texture is written by shaders"); return false}
	if mip >= t.desc.mip_levels {set_error(d, "texture_upload: mip %d out of range", mip); return false}
	area, inside := texture_region_resolve(t.desc, mip, region)
	if !inside {set_error(d, "texture_upload: the region %v is not inside mip %d or cuts its blocks", region, mip); return false}
	row, rows := format_rows(t.desc.format, area.width, area.height)
	rows *= u64(max(t.desc.layers, 1))
	if u64(bytes_per_row) < row || u64(len(data)) < u64(bytes_per_row) * (rows - 1) + row {
		set_error(d, "texture_upload: %d bytes do not cover %d layers of %dx%d", len(data), max(t.desc.layers, 1), area.width, area.height)
		return false
	}
	staging := vk_create_buffer(d, {size = row * rows, memory = .Staging, name = "texture staging"}, zero = false)
	if staging == 0 {return false}
	dst := cast([^]u8)buffer_mapped(d, staging)
	for y in 0 ..< rows {
		mem.copy(&dst[y * row], &data[y * u64(bytes_per_row)], int(row))
	}
	cmd := immediate_begin(d)
	cmd_copy_buffer_to_texture(cmd, staging, 0, texture, mip, area)
	if .Sampled in t.desc.usage {cmd_barrier_texture(cmd, texture, .Shader_Read)}
	ok := immediate_end(d, cmd)
	vk_release_buffer_now(d, staging)
	return ok
}

// The levels of a texture from its mip 0, tightly packed, in one transaction:
// one staging buffer and one submission for all of them. A load of thousands
// of textures would otherwise wait for the GPU once per level of each.
texture_upload_levels :: proc(d: ^Device, texture: Texture, levels: [][]u8) -> bool {
	t := pool_get(&d.textures, base.Handle(texture))
	if t == nil {return false}
	if t.desc.depth > 1 {set_error(d, "texture_upload_levels: a 3D texture is written by shaders"); return false}
	if u32(len(levels)) > t.desc.mip_levels {set_error(d, "texture_upload_levels: %d levels for %d mips", len(levels), t.desc.mip_levels); return false}
	total: u64
	for level, mip in levels {
		size := texture_level_bytes(t.desc, u32(mip))
		if u64(len(level)) < size {set_error(d, "texture_upload_levels: %d bytes do not cover mip %d", len(level), mip); return false}
		total = align_up(total, 16) + size
	}
	staging := vk_create_buffer(d, {size = total, memory = .Staging, name = "texture staging"}, zero = false)
	if staging == 0 {return false}
	dst := cast([^]u8)buffer_mapped(d, staging)
	cmd := immediate_begin(d)
	at: u64
	for level, mip in levels {
		at = align_up(at, 16)
		size := texture_level_bytes(t.desc, u32(mip))
		mem.copy(&dst[at], raw_data(level), int(size))
		cmd_copy_buffer_to_texture(cmd, staging, at, texture, u32(mip))
		at += size
	}
	if .Sampled in t.desc.usage {cmd_barrier_texture(cmd, texture, .Shader_Read)}
	ok := immediate_end(d, cmd)
	vk_release_buffer_now(d, staging)
	return ok
}

// Blocking readback of a whole buffer range into out.
buffer_read :: proc(d: ^Device, buffer: Buffer, offset: u64, out: []u8) -> bool {
	b := pool_get(&d.buffers, base.Handle(buffer))
	if b == nil || offset + u64(len(out)) > b.size {set_error(d, "buffer_read out of range"); return false}
	staging := vk_create_buffer(d, {size = u64(len(out)), memory = .Readback, name = "readback"}, zero = false)
	if staging == 0 {return false}
	defer vk_release_buffer_now(d, staging)
	cmd := immediate_begin(d)
	cmd_copy_buffer(cmd, buffer, offset, staging, 0, u64(len(out)))
	cmd_barrier_buffer(cmd, staging, .Host_Read)
	if !immediate_end(d, cmd) {return false}
	mem.copy(raw_data(out), buffer_mapped(d, staging), len(out))
	return true
}

// Blocking readback of mip 0 as tightly packed rows (width * format size).
texture_read :: proc(d: ^Device, texture: Texture, out: []u8) -> bool {
	t := pool_get(&d.textures, base.Handle(texture))
	if t == nil {return false}
	row := u64(t.desc.width) * u64(format_size(t.desc.format))
	size := row * u64(t.desc.height) * u64(max(t.desc.depth, 1))
	if u64(len(out)) < size {set_error(d, "texture_read output too small"); return false}
	staging := vk_create_buffer(d, {size = size, memory = .Readback, name = "texture readback"}, zero = false)
	if staging == 0 {return false}
	defer vk_release_buffer_now(d, staging)
	cmd := immediate_begin(d)
	cmd_copy_texture_to_buffer(cmd, texture, staging, 0)
	cmd_barrier_buffer(cmd, staging, .Host_Read)
	// A texture with the Sampled usage alone may be in the table, which every frame reads.
	if t.desc.usage == {.Sampled} {cmd_barrier_texture(cmd, texture, .Shader_Read)}
	if !immediate_end(d, cmd) {return false}
	mem.copy(raw_data(out), buffer_mapped(d, staging), int(size))
	return true
}
