#+build darwin
package rhi

import "core:mem"
import "core:crypto/sha2"
import "core:sync"
import "mirai:std/base"
import CF "core:sys/darwin/CoreFoundation"
import CG "core:sys/darwin/CoreGraphics"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

@(private)
mtl_format :: proc "contextless" (f: Format) -> MTL.PixelFormat {
	switch f {
	case .Undefined:     return .Invalid
	case .R8_Unorm:      return .R8Unorm
	case .RG8_Unorm:     return .RG8Unorm
	case .RGBA8_Unorm:   return .RGBA8Unorm
	case .RGBA8_Srgb:    return .RGBA8Unorm_sRGB
	case .BGRA8_Unorm:   return .BGRA8Unorm
	case .BGRA8_Srgb:    return .BGRA8Unorm_sRGB
	case .R16_Float:     return .R16Float
	case .RG16_Float:    return .RG16Float
	case .RGBA16_Float:  return .RGBA16Float
	case .R32_Float:     return .R32Float
	case .RG32_Float:    return .RG32Float
	case .RGBA32_Float:  return .RGBA32Float
	case .R32_Uint:      return .R32Uint
	case .RG32_Uint:     return .RG32Uint
	case .RGBA32_Uint:   return .RGBA32Uint
	case .R8_Uint:       return .R8Uint
	case .RG16_Sint:     return .RG16Sint
	case .RG11B10_Float: return .RG11B10Float
	case .D32_Float:     return .Depth32Float
	case .BC1_Unorm:     return .BC1_RGBA
	case .BC1_Srgb:      return .BC1_RGBA_sRGB
	case .BC3_Unorm:     return .BC3_RGBA
	case .BC3_Srgb:      return .BC3_RGBA_sRGB
	case .BC5_Unorm:     return .BC5_RGUnorm
	case .BC7_Unorm:     return .BC7_RGBAUnorm
	case .BC7_Srgb:      return .BC7_RGBAUnorm_sRGB
	case .BC6H_Ufloat:   return .BC6H_RGBUfloat
	case .RGBA16_Unorm:  return .RGBA16Unorm
	}
	return .Invalid
}

// Every buffer uses tracked hazards, so Metal orders reads after writes across
// encoders and command buffers by itself.
@(private)
mtl_create_buffer :: proc(d: ^Device, desc: Buffer_Desc) -> Buffer {
	NS.scoped_autoreleasepool()
	if !device_room(d, &d.buffers, "buffers") {return 0}
	size := max(desc.size, 16)
	length := align_up(size, 16)
	options := MTL.ResourceOptions{.HazardTrackingModeTracked}
	switch desc.memory {
	case .GPU:      options += {.StorageModePrivate}
	case .Upload:   options += {.CPUCacheModeWriteCombined} // shared storage, CPU writes only
	case .Readback: // shared storage, default (cached) CPU access
	case .Staging:  options += {.CPUCacheModeWriteCombined} // shared storage: the memory of an Apple GPU is that of the host
	}
	b := Mtl_Buffer{size = size, length = length, usage = desc.usage, kind = desc.memory}
	b.handle = MTL.Device_newBufferWithLength(d.device, NS.UInteger(length), options)
	if b.handle == nil {set_error(d, "newBufferWithLength(%d) failed for %s", length, desc.name); return 0}
	if desc.memory != .GPU {
		b.mapped = MTL.Buffer_contents(b.handle)
		mem.zero(b.mapped, int(length))
	}
	mtl_set_label(b.handle, desc.name)
	return Buffer(pool_add(&d.buffers, b))
}

buffer_create :: proc(d: ^Device, desc: Buffer_Desc) -> Buffer {return mtl_create_buffer(d, desc)}

buffer_destroy :: proc(d: ^Device, buffer: Buffer) {
	b, ok := pool_remove(&d.buffers, base.Handle(buffer))
	if !ok {return}
	mtl_defer(d, b.handle)
}

// Staging buffers of a completed (waited) transaction are released at once
// instead of waiting for frame slots that may never run (headless loads).
@(private)
mtl_release_buffer_now :: proc(d: ^Device, buffer: Buffer) {
	if b, ok := pool_remove(&d.buffers, base.Handle(buffer)); ok {mtl_release(b.handle)}
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
	NS.scoped_autoreleasepool()
	if desc.depth > 1 && (.Storage not_in desc.usage || .Color_Target in desc.usage || .Depth_Target in desc.usage) {set_error(d, "texture %s: a 3D texture needs the Storage usage and no target usage, since shaders write it", desc.name); return 0}
	if problem := texture_layers_problem(desc, d.info.max_texture_layers); problem != "" {set_error(d, "texture %s: %s", desc.name, problem); return 0}
	layers := max(desc.layers, 1)
	if !device_room(d, &d.textures, "textures") {return 0}
	t := Mtl_Texture{desc = desc}
	t.desc.name = ""
	t.desc.mip_levels = max(desc.mip_levels, 1)
	t.desc.layers = layers
	assert(t.desc.mip_levels <= MAX_TEXTURE_MIPS)
	t.format = mtl_format(desc.format)
	if t.format == .Invalid {set_error(d, "texture %s has an undefined format", desc.name); return 0}
	usage: MTL.TextureUsage
	if .Sampled in desc.usage {usage += {.ShaderRead}}
	if .Storage in desc.usage {usage += {.ShaderRead, .ShaderWrite}}
	if .Storage in desc.usage && desc.format == .R32_Uint {usage += {.ShaderAtomic}}
	if .Color_Target in desc.usage || .Depth_Target in desc.usage {usage += {.RenderTarget}}
	td := MTL.TextureDescriptor.alloc()->init()
	defer mtl_release(td)
	volume := desc.depth > 1
	type: MTL.TextureType = ._3D if volume else ._2D
	switch {
	case desc.cube:  type = .Cube if layers == 6 else .CubeArray
	case layers > 1: type = ._2DArray
	}
	MTL.TextureDescriptor_setTextureType(td, type)
	MTL.TextureDescriptor_setPixelFormat(td, t.format)
	MTL.TextureDescriptor_setWidth(td, NS.UInteger(max(desc.width, 1)))
	MTL.TextureDescriptor_setHeight(td, NS.UInteger(max(desc.height, 1)))
	if volume {MTL.TextureDescriptor_setDepth(td, NS.UInteger(desc.depth))}
	// Metal counts the cubes of a cube texture, and the faces are its slices.
	if layers > 1 {MTL.TextureDescriptor_setArrayLength(td, NS.UInteger(layers / 6 if desc.cube else layers))}
	MTL.TextureDescriptor_setMipmapLevelCount(td, NS.UInteger(t.desc.mip_levels))
	MTL.TextureDescriptor_setUsage(td, usage)
	MTL.TextureDescriptor_setStorageMode(td, .Private)
	MTL.TextureDescriptor_setHazardTrackingMode(td, .Tracked)
	t.handle = MTL.Device_newTextureWithDescriptor(d.device, td)
	if t.handle == nil {set_error(d, "newTextureWithDescriptor failed for %s", desc.name); return 0}
	if t.desc.mip_levels > 1 {
		// Same-format views need no PixelFormatView usage.
		for mip in 0 ..< t.desc.mip_levels {
			t.mip_views[mip] = MTL.Texture_newTextureViewWithPixelFormat(t.handle, t.format, type, NS.Range{NS.UInteger(mip), 1}, NS.Range{0, NS.UInteger(layers)})
		}
	}
	mtl_set_label(t.handle, desc.name)
	return Texture(pool_add(&d.textures, t))
}

texture_destroy :: proc(d: ^Device, texture: Texture) {
	if t := pool_get(&d.textures, base.Handle(texture)); t == nil || t.swapchain {return}
	for entry, index in d.table_textures {if entry == texture {texture_table_set(d, u32(index), 0)}}
	t, _ := pool_remove(&d.textures, base.Handle(texture))
	for v in t.mip_views {mtl_defer(d, v)}
	mtl_defer(d, t.handle)
	mtl_defer(d, cast(^NS.Object)t.surface)
}

// ---------------------------------------------------------------- shared textures

// IOSurface, which a texture can live in and another process opens by its id.
// The surface is global so that IOSurfaceLookup finds it from another process.
foreign import iosurface "system:IOSurface.framework"

@(private, default_calling_convention = "c")
foreign iosurface {
	IOSurfaceCreate :: proc(properties: rawptr) -> rawptr ---
	IOSurfaceGetID :: proc(surface: rawptr) -> u32 ---
	IOSurfaceLookup :: proc(id: u32) -> rawptr ---
	IOSurfaceGetWidth :: proc(surface: rawptr) -> uint ---
	IOSurfaceGetHeight :: proc(surface: rawptr) -> uint ---
	IOSurfaceGetPixelFormat :: proc(surface: rawptr) -> u32 ---
	kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat, kIOSurfaceIsGlobal: rawptr
}

// The four character code of the surface for a format of four bytes per texel; 0 for the others.
@(private)
mtl_surface_format :: proc "contextless" (format: Format) -> u32 {
	#partial switch format {
	case .BGRA8_Unorm, .BGRA8_Srgb: return 0x42475241 // 'BGRA'
	case .RGBA8_Unorm, .RGBA8_Srgb: return 0x52474241 // 'RGBA'
	}
	return 0
}

// Every Metal device shares textures through IOSurface.
device_shares_textures :: proc "contextless" (d: ^Device) -> bool {return d != nil}

texture_create_shared :: proc(d: ^Device, desc: Texture_Desc) -> (Texture, Shared_Texture) {
	pixel := mtl_surface_format(desc.format)
	if pixel == 0 || desc.width == 0 || desc.height == 0 || max(desc.mip_levels, 1) > 1 {
		set_error(d, "shared texture %s: one level of a format of four bytes per texel", desc.name)
		return 0, 0
	}
	properties := CF.DictionaryCreateMutable(nil, 0, &CF.kTypeDictionaryKeyCallBacks, &CF.kTypeDictionaryValueCallBacks)
	defer CF.Release(properties)
	values := [4]i32{i32(desc.width), i32(desc.height), 4, i32(pixel)}
	keys := [4]rawptr{kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat}
	for &value, i in values {
		number := CF.NumberCreate(nil, .SInt32Type, &value)
		CF.DictionarySetValue(properties, keys[i], number)
		CF.Release(number)
	}
	CF.DictionarySetValue(properties, kIOSurfaceIsGlobal, CF.kBooleanTrue)
	surface := IOSurfaceCreate(properties)
	if surface == nil {set_error(d, "IOSurfaceCreate failed for %s", desc.name); return 0, 0}
	texture := mtl_texture_on_surface(d, desc, surface)
	if texture == 0 {return 0, 0}
	return texture, Shared_Texture(IOSurfaceGetID(surface))
}

texture_open_shared :: proc(d: ^Device, desc: Texture_Desc, shared: Shared_Texture) -> Texture {
	surface := IOSurfaceLookup(u32(shared))
	if surface == nil {set_error(d, "shared texture %s: no surface %d", desc.name, u32(shared)); return 0}
	if IOSurfaceGetWidth(surface) != uint(desc.width) || IOSurfaceGetHeight(surface) != uint(desc.height) ||
	   IOSurfaceGetPixelFormat(surface) != mtl_surface_format(desc.format) {
		CF.Release(surface)
		set_error(d, "shared texture %s: the surface is not an image of %dx%d and that format", desc.name, desc.width, desc.height)
		return 0
	}
	return mtl_texture_on_surface(d, desc, surface)
}

// A texture over a surface it takes ownership of; on failure the surface is released.
@(private)
mtl_texture_on_surface :: proc(d: ^Device, desc: Texture_Desc, surface: rawptr) -> Texture {
	NS.scoped_autoreleasepool()
	if !device_room(d, &d.textures, "textures") {CF.Release(surface); return 0}
	t := Mtl_Texture{desc = desc, surface = surface}
	t.desc.name = ""
	t.desc.mip_levels = 1
	t.format = mtl_format(desc.format)
	usage: MTL.TextureUsage
	if .Sampled in desc.usage {usage += {.ShaderRead}}
	if .Storage in desc.usage {usage += {.ShaderRead, .ShaderWrite}}
	if .Color_Target in desc.usage {usage += {.RenderTarget}}
	td := MTL.TextureDescriptor.alloc()->init()
	defer mtl_release(td)
	MTL.TextureDescriptor_setTextureType(td, ._2D)
	MTL.TextureDescriptor_setPixelFormat(td, t.format)
	MTL.TextureDescriptor_setWidth(td, NS.UInteger(desc.width))
	MTL.TextureDescriptor_setHeight(td, NS.UInteger(desc.height))
	MTL.TextureDescriptor_setUsage(td, usage)
	MTL.TextureDescriptor_setStorageMode(td, .Shared)
	t.handle = MTL.Device_newTextureWithDescriptor(d.device, td, cast(CG.IOSurfaceRef)surface, 0)
	if t.handle == nil {
		CF.Release(surface)
		set_error(d, "newTextureWithDescriptor:iosurface failed for %s", desc.name)
		return 0
	}
	mtl_set_label(t.handle, desc.name)
	return Texture(pool_add(&d.textures, t))
}

texture_desc :: proc(d: ^Device, texture: Texture) -> Texture_Desc {
	t := pool_get(&d.textures, base.Handle(texture))
	return t.desc if t != nil else {}
}

// Metal has no min/max reduction samplers: Reduction.Min/Max create an ordinary
// filtering sampler, so shaders that need a min/max pyramid must gather and
// reduce texels themselves on this backend.
sampler_create :: proc(d: ^Device, desc: Sampler_Desc) -> Sampler {
	NS.scoped_autoreleasepool()
	if !device_room(d, &d.samplers, "samplers") {return 0}
	sd := MTL.SamplerDescriptor.alloc()->init()
	defer mtl_release(sd)
	filter: MTL.SamplerMinMagFilter = .Linear if desc.filter == .Linear else .Nearest
	mip: MTL.SamplerMipFilter = .Linear if desc.mip_filter == .Linear else .Nearest
	address: MTL.SamplerAddressMode = .Repeat if desc.address == .Repeat else .ClampToEdge
	MTL.SamplerDescriptor_setMinFilter(sd, filter)
	MTL.SamplerDescriptor_setMagFilter(sd, filter)
	MTL.SamplerDescriptor_setMipFilter(sd, mip)
	MTL.SamplerDescriptor_setSAddressMode(sd, address)
	MTL.SamplerDescriptor_setTAddressMode(sd, address)
	MTL.SamplerDescriptor_setRAddressMode(sd, address)
	MTL.SamplerDescriptor_setLodMinClamp(sd, 0)
	MTL.SamplerDescriptor_setLodMaxClamp(sd, desc.max_lod if desc.max_lod > 0 else 1000)
	if desc.anisotropy > 1 {MTL.SamplerDescriptor_setMaxAnisotropy(sd, NS.UInteger(min(desc.anisotropy, 16)))}
	if desc.name != "" {
		label := mtl_string(desc.name)
		MTL.SamplerDescriptor_setLabel(sd, label)
		mtl_release(label)
	}
	sampler := MTL.Device_newSamplerStateWithDescriptor(d.device, sd)
	if sampler == nil {set_error(d, "newSamplerState failed for %s", desc.name); return 0}
	return Sampler(pool_add(&d.samplers, sampler))
}

sampler_destroy :: proc(d: ^Device, sampler: Sampler) {
	if s, ok := pool_remove(&d.samplers, base.Handle(sampler)); ok {mtl_defer(d, s)}
}

// ---------------------------------------------------------------- texture table

// Puts a texture in an entry of the table; texture 0 gives the entry back to
// the white default. A transaction between frames that waits for nothing:
// each copy of the table takes it when its next list begins. The texture
// must have the Sampled usage alone and be uploaded already.
texture_table_set :: proc(d: ^Device, index: u32, texture: Texture) -> bool {
	assert(!d.in_frame, "rhi: the texture table changes between frames")
	if int(index) >= len(d.table_textures) {
		grown := table_grown(len(d.table_textures), int(index), d.table_limit)
		if grown == 0 {set_error(d, "texture table index %d out of range: the device holds %d entries", index, d.table_limit); return false}
		if !mtl_table_grow(d, grown) {return false}
	}
	t := pool_get(&d.textures, base.Handle(texture if texture != 0 else d.table_default))
	if t == nil || t.swapchain || t.desc.usage != {.Sampled} {
		set_error(d, "texture table entry %d needs an uploaded texture with the Sampled usage alone", index)
		return false
	}
	if t.desc.layers > 1 || t.desc.cube || t.desc.depth > 1 {
		set_error(d, "texture table entry %d: shaders read the table as 2D textures of one layer", index)
		return false
	}
	d.table_textures[index] = texture
	d.table_views[index] = t.handle
	table_changed(&d.table_changes, index)
	mtl_table_resident(d)
	return true
}

// ---------------------------------------------------------------- pipelines

// Identical source and entry bytes compile once while any pipeline uses them,
// including an unchanged shader shared by active and candidate generations.
// Returns the entry point (+1) and a cache handle owned by the pipeline.
@(private)
mtl_function :: proc(d: ^Device, code: ^Shader_Code) -> (function:^MTL.Function,shader:base.Handle) {
	NS.scoped_autoreleasepool()
	if len(code.msl) == 0 || code.msl_entry=="" {set_error(d, "shader %s needs MSL and its entry point", code.name); return}
	hash:sha2.Context_256
	sha2.init_256(&hash)
	source_size:=u64(len(code.msl))
	sha2.update(&hash,mem.ptr_to_bytes(&source_size))
	sha2.update(&hash,transmute([]u8)code.msl)
	sha2.update(&hash,transmute([]u8)code.msl_entry)
	fingerprint:[32]u8
	sha2.final(&hash,fingerprint[:])
	if function,shader=mtl_function_cached(d,fingerprint);function!=nil {return}
	source := mtl_string(code.msl)
	defer mtl_release(source)
	options := MTL.CompileOptions.alloc()->init()
	defer mtl_release(options)
	// cook/shaders emits MSL 2.4 (inline ray queries need it), and 3.1 for the
	// stages with atomics on textures.
	MTL.CompileOptions_setLanguageVersion(options, ._3_1)
	library, err := MTL.Device_newLibraryWithSource(d.device, source, options)
	if library == nil {mtl_set_ns_error(d, err, "shader %s does not compile", code.name); return}
	entry := mtl_string(code.msl_entry)
	defer mtl_release(entry)
	function = MTL.Library_newFunctionWithName(library, entry)
	if function == nil {mtl_release(library);set_error(d, "shader %s has no entry point %s", code.name, code.msl_entry);return}
	// Another thread may have compiled the same code meanwhile: both entries serve.
	sync.guard(&d.pipeline_lock)
	if !device_room(d, &d.shaders, "shader functions") {mtl_release(function);mtl_release(library);return nil,0}
	shader=pool_add(&d.shaders,Mtl_Shader{fingerprint=fingerprint,library=library,function=function,users=1})
	mtl_retain(function)
	return
}

// The function of code compiled already, with one more user.
@(private)
mtl_function_cached :: proc(d:^Device,fingerprint:[32]u8) -> (function:^MTL.Function,shader:base.Handle) {
	sync.guard(&d.pipeline_lock)
	for &cached,i in d.shaders.items {
		if d.shaders.alive[i] && cached.fingerprint==fingerprint {
			cached.users+=1
			mtl_retain(cached.function)
			return cached.function,pool_handle(&d.shaders,i)
		}
	}
	return
}

@(private)
mtl_shader_release :: proc(d:^Device,handle:base.Handle) {
	sync.guard(&d.pipeline_lock)
	shader:=pool_get(&d.shaders,handle)
	if shader==nil {return}
	assert(shader.users>0)
	shader.users-=1
	if shader.users==0 {
		owned,_:=pool_remove(&d.shaders,handle)
		mtl_release(owned.function);mtl_release(owned.library)
	}
}

@(private)
mtl_merge_bindings :: proc(d: ^Device, p: ^Mtl_Pipeline, codes: ..^Shader_Code) -> bool {
	for code in codes {
		if code == nil {continue}
		for b in code.bindings {
			if !binding_slot_valid(b.slot, b.kind) {set_error(d, "shader %s uses slot %d beyond the limit", code.name, b.slot); return false}
			if b.kind == .Texture_Table {p.table += {code.stage}; continue}
			slot := &p.slots[b.slot]
			if slot.used && slot.kind != b.kind {set_error(d, "shader %s redeclares slot %d with another kind", code.name, b.slot); return false}
			slot.used = true
			slot.kind = b.kind
			slot.stages += {code.stage}
			p.slot_mask |= 1 << b.slot
		}
	}
	return true
}

@(private)
mtl_release_pipeline :: proc(d:^Device,p: ^Mtl_Pipeline) {
	mtl_release(p.compute)
	mtl_release(p.render)
	mtl_release(p.depth_state)
	p.compute = nil
	p.render = nil
	p.depth_state = nil
	for shader in p.shaders {mtl_shader_release(d,shader)}
	p.shaders={}
}

pipeline_create_compute :: proc(d: ^Device, desc: Compute_Pipeline_Desc) -> Pipeline {
	NS.scoped_autoreleasepool()
	if !mtl_pipeline_room(d) {return 0}
	p := Mtl_Pipeline{is_compute = true, name = desc.name}
	ready:=false
	defer {if !ready {mtl_release_pipeline(d,&p)}}
	if desc.shader == nil || desc.shader.stage != .Compute {set_error(d, "compute pipeline %s needs a compute shader", desc.name); return 0}
	if !mtl_merge_bindings(d, &p, desc.shader) {return 0}
	group := desc.shader.threadgroup
	p.threadgroup = {NS.UInteger(max(group.x, 1)), NS.UInteger(max(group.y, 1)), NS.UInteger(max(group.z, 1))}
	function:^MTL.Function
	function,p.shaders[0] = mtl_function(d, desc.shader)
	if function == nil {return 0}
	defer mtl_release(function)
	state, err := MTL.Device_newComputePipelineStateWithFunction(d.device, function)
	if state == nil {mtl_set_ns_error(d, err, "compute pipeline %s", desc.name); return 0}
	p.compute = state
	threads := p.threadgroup.width * p.threadgroup.height * p.threadgroup.depth
	if limit := MTL.ComputePipelineState_maxTotalThreadsPerThreadgroup(state); NS.UInteger(threads) > limit {
		set_error(d, "compute pipeline %s: threadgroup of %d threads exceeds the limit of %d", desc.name, threads, limit)
		return 0
	}
	pipeline := mtl_pipeline_add(d, p)
	ready = pipeline != 0
	return pipeline
}

@(private)
mtl_compare :: proc "contextless" (c: Compare) -> MTL.CompareFunction {
	switch c {
	case .Never:         return .Never
	case .Less:          return .Less
	case .Less_Equal:    return .LessEqual
	case .Equal:         return .Equal
	case .Greater:       return .Greater
	case .Greater_Equal: return .GreaterEqual
	case .Always:        return .Always
	}
	return .Always
}

pipeline_create_graphics :: proc(d: ^Device, desc: Graphics_Pipeline_Desc) -> Pipeline {
	NS.scoped_autoreleasepool()
	if !mtl_pipeline_room(d) {return 0}
	p := Mtl_Pipeline{name = desc.name}
	ready:=false
	defer {if !ready {mtl_release_pipeline(d,&p)}}
	if desc.vertex == nil || desc.fragment == nil {set_error(d, "graphics pipeline %s needs vertex and fragment shaders", desc.name); return 0}
	if !mtl_merge_bindings(d, &p, desc.vertex, desc.fragment) {return 0}
	vertex:^MTL.Function
	vertex,p.shaders[0] = mtl_function(d, desc.vertex)
	defer mtl_release(vertex)
	fragment:^MTL.Function
	fragment,p.shaders[1] = mtl_function(d, desc.fragment)
	defer mtl_release(fragment)
	if vertex == nil || fragment == nil {return 0}

	rpd := MTL.RenderPipelineDescriptor.alloc()->init()
	defer mtl_release(rpd)
	MTL.RenderPipelineDescriptor_setVertexFunction(rpd, vertex)
	MTL.RenderPipelineDescriptor_setFragmentFunction(rpd, fragment)
	colors := MTL.RenderPipelineDescriptor_colorAttachments(rpd)
	for i in 0 ..< desc.color_count {
		a := MTL.RenderPipelineColorAttachmentDescriptorArray_object(colors, NS.UInteger(i))
		MTL.RenderPipelineColorAttachmentDescriptor_setPixelFormat(a, mtl_format(desc.color_formats[i]))
		MTL.RenderPipelineColorAttachmentDescriptor_setWriteMask(a, MTL.ColorWriteMasks_All)
		src_rgb, dst_rgb, src_alpha, dst_alpha: MTL.BlendFactor
		switch desc.blend[i] {
		case .Opaque:
			MTL.RenderPipelineColorAttachmentDescriptor_setBlendingEnabled(a, false)
			continue
		case .Alpha:         src_rgb, dst_rgb, src_alpha, dst_alpha = .SourceAlpha, .OneMinusSourceAlpha, .One, .OneMinusSourceAlpha
		case .Premultiplied: src_rgb, dst_rgb, src_alpha, dst_alpha = .One, .OneMinusSourceAlpha, .One, .OneMinusSourceAlpha
		case .Additive:      src_rgb, dst_rgb, src_alpha, dst_alpha = .One, .One, .One, .One
		case .Multiply:      src_rgb, dst_rgb, src_alpha, dst_alpha = .DestinationColor, .Zero, .DestinationAlpha, .Zero
		case .Alpha_Color:   src_rgb, dst_rgb, src_alpha, dst_alpha = .SourceAlpha, .OneMinusSourceAlpha, .Zero, .One
		}
		MTL.RenderPipelineColorAttachmentDescriptor_setBlendingEnabled(a, true)
		MTL.RenderPipelineColorAttachmentDescriptor_setRgbBlendOperation(a, .Add)
		MTL.RenderPipelineColorAttachmentDescriptor_setAlphaBlendOperation(a, .Add)
		MTL.RenderPipelineColorAttachmentDescriptor_setSourceRGBBlendFactor(a, src_rgb)
		MTL.RenderPipelineColorAttachmentDescriptor_setDestinationRGBBlendFactor(a, dst_rgb)
		MTL.RenderPipelineColorAttachmentDescriptor_setSourceAlphaBlendFactor(a, src_alpha)
		MTL.RenderPipelineColorAttachmentDescriptor_setDestinationAlphaBlendFactor(a, dst_alpha)
	}
	if desc.depth_format != .Undefined {
		MTL.RenderPipelineDescriptor_setDepthAttachmentPixelFormat(rpd, mtl_format(desc.depth_format))
	}
	MTL.RenderPipelineDescriptor_setInputPrimitiveTopology(rpd, .Line if desc.topology == .Lines else .Triangle)
	if desc.name != "" {
		label := mtl_string(desc.name)
		MTL.RenderPipelineDescriptor_setLabel(rpd, label)
		mtl_release(label)
	}
	state, err := MTL.Device_newRenderPipelineStateWithDescriptor(d.device, rpd)
	if state == nil {mtl_set_ns_error(d, err, "graphics pipeline %s", desc.name); return 0}
	p.render = state

	// Vulkan never writes depth when the depth test is disabled; match it.
	dsd := MTL.DepthStencilDescriptor.alloc()->init()
	defer mtl_release(dsd)
	MTL.DepthStencilDescriptor_setDepthCompareFunction(dsd, mtl_compare(desc.depth_compare) if desc.depth_test else .Always)
	MTL.DepthStencilDescriptor_setDepthWriteEnabled(dsd, desc.depth_test && desc.depth_write)
	p.depth_state = MTL.Device_newDepthStencilStateWithDescriptor(d.device, dsd)
	if p.depth_state == nil {
		set_error(d, "graphics pipeline %s: newDepthStencilState failed", desc.name)
		return 0
	}
	switch desc.cull {
	case .None:  p.cull = .None
	case .Back:  p.cull = .Back
	case .Front: p.cull = .Front
	}
	p.primitive = .Line if desc.topology == .Lines else .Triangle
	pipeline := mtl_pipeline_add(d, p)
	ready = pipeline != 0
	return pipeline
}

pipeline_destroy :: proc(d: ^Device, pipeline: Pipeline) {
	sync.lock(&d.pipeline_lock)
	p, ok := pool_remove(&d.pipelines, base.Handle(pipeline))
	sync.unlock(&d.pipeline_lock)
	if ok {
		mtl_defer(d, p.compute)
		mtl_defer(d, p.render)
		mtl_defer(d, p.depth_state)
		for shader in p.shaders {mtl_shader_release(d,shader)}
	}
}

// Holds a pipeline made on any thread; 0 when the pool is full.
@(private)
mtl_pipeline_add :: proc(d: ^Device, p: Mtl_Pipeline) -> Pipeline {
	sync.guard(&d.pipeline_lock)
	if !device_room(d, &d.pipelines, "pipelines") {return 0}
	return Pipeline(pool_add(&d.pipelines, p))
}

@(private)
mtl_pipeline_room :: proc(d: ^Device) -> bool {
	sync.guard(&d.pipeline_lock)
	return device_room(d, &d.pipelines, "pipelines")
}

// ---------------------------------------------------------------- transactions

// Blit copies between buffers need 4-byte aligned offsets and sizes on macOS;
// unaligned uploads into GPU buffers preserve the neighbouring bytes of the
// partially covered words with a read-modify-write.
buffer_upload :: proc(d: ^Device, buffer: Buffer, offset: u64, data: []u8) -> bool {
	b := pool_get(&d.buffers, base.Handle(buffer))
	if b == nil || offset + u64(len(data)) > b.size {set_error(d, "buffer_upload out of range"); return false}
	if len(data) == 0 {return true}
	if b.mapped != nil && (b.kind == .Upload || b.kind == .Staging) {
		mem.copy(rawptr(uintptr(b.mapped) + uintptr(offset)), raw_data(data), len(data))
		return true
	}
	start := offset &~ 3
	end := align_up(offset + u64(len(data)), 4)
	size := end - start
	staging := mtl_create_buffer(d, {size = size, memory = .Readback, name = "upload staging"})
	if staging == 0 {return false}
	defer mtl_release_buffer_now(d, staging)
	if start != offset || end != offset + u64(len(data)) {
		cmd := immediate_begin(d)
		cmd_copy_buffer(cmd, buffer, start, staging, 0, size)
		if !immediate_end(d, cmd) {return false}
	}
	mem.copy(rawptr(uintptr(buffer_mapped(d, staging)) + uintptr(offset - start)), raw_data(data), len(data))
	cmd := immediate_begin(d)
	cmd_copy_buffer(cmd, staging, 0, buffer, start, size)
	return immediate_end(d, cmd)
}

// Writes a region of a mip (texture_region_resolve) of every layer, whose
// texels data holds in rows bytes_per_row apart, layer after layer.
texture_upload :: proc(d: ^Device, texture: Texture, data: []u8, bytes_per_row: u32, mip: u32 = 0, region := Texture_Region{}) -> bool {
	t := pool_get(&d.textures, base.Handle(texture))
	if t == nil || t.swapchain {set_error(d, "texture_upload needs a valid texture"); return false}
	if t.desc.depth > 1 {set_error(d, "texture_upload: a 3D texture is written by shaders"); return false}
	if mip >= t.desc.mip_levels {set_error(d, "texture_upload mip %d out of range", mip); return false}
	area, inside := texture_region_resolve(t.desc, mip, region)
	if !inside {set_error(d, "texture_upload: the region %v is not inside mip %d or cuts its blocks", region, mip); return false}
	row, rows := format_rows(t.desc.format, area.width, area.height)
	rows *= u64(max(t.desc.layers, 1))
	if u64(bytes_per_row) < row || u64(len(data)) < u64(bytes_per_row) * (rows - 1) + row {set_error(d, "texture_upload data too small"); return false}
	staging := mtl_create_buffer(d, {size = row * rows, memory = .Staging, name = "texture staging"})
	if staging == 0 {return false}
	defer mtl_release_buffer_now(d, staging)
	dst := cast([^]u8)buffer_mapped(d, staging)
	for y in 0 ..< rows {
		mem.copy(&dst[y * row], &data[y * u64(bytes_per_row)], int(row))
	}
	cmd := immediate_begin(d)
	cmd_copy_buffer_to_texture(cmd, staging, 0, texture, mip, area)
	return immediate_end(d, cmd)
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
	staging := mtl_create_buffer(d, {size = total, memory = .Staging, name = "texture staging"})
	if staging == 0 {return false}
	defer mtl_release_buffer_now(d, staging)
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
	return immediate_end(d, cmd)
}

// Blocking readback of a whole buffer range into out. The copy is queued after
// every submitted frame, and tracked hazards order it after their writes.
buffer_read :: proc(d: ^Device, buffer: Buffer, offset: u64, out: []u8) -> bool {
	b := pool_get(&d.buffers, base.Handle(buffer))
	if b == nil || offset + u64(len(out)) > b.size {set_error(d, "buffer_read out of range"); return false}
	if len(out) == 0 {return true}
	start := offset &~ 3
	end := align_up(offset + u64(len(out)), 4)
	staging := mtl_create_buffer(d, {size = end - start, memory = .Readback, name = "readback"})
	if staging == 0 {return false}
	defer mtl_release_buffer_now(d, staging)
	cmd := immediate_begin(d)
	cmd_copy_buffer(cmd, buffer, start, staging, 0, end - start)
	if !immediate_end(d, cmd) {return false}
	mem.copy(raw_data(out), rawptr(uintptr(buffer_mapped(d, staging)) + uintptr(offset - start)), len(out))
	return true
}

// Blocking readback of mip 0 as tightly packed rows (width * format size).
texture_read :: proc(d: ^Device, texture: Texture, out: []u8) -> bool {
	t := pool_get(&d.textures, base.Handle(texture))
	if t == nil || t.handle == nil {set_error(d, "texture_read needs a valid texture"); return false}
	row := u64(t.desc.width) * u64(format_size(t.desc.format))
	size := row * u64(t.desc.height) * u64(max(t.desc.depth, 1))
	if u64(len(out)) < size {set_error(d, "texture_read output too small"); return false}
	staging := mtl_create_buffer(d, {size = size, memory = .Readback, name = "texture readback"})
	if staging == 0 {return false}
	defer mtl_release_buffer_now(d, staging)
	cmd := immediate_begin(d)
	cmd_copy_texture_to_buffer(cmd, texture, staging, 0)
	if !immediate_end(d, cmd) {return false}
	mem.copy(raw_data(out), buffer_mapped(d, staging), int(size))
	return true
}
