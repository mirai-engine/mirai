#+build darwin
package rhi

import "base:intrinsics"
import "mirai:std/base"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

MAX_LABEL_DEPTH :: 16

Mtl_Encoder_Kind :: enum u8 {None, Render, Compute, Blit, Accel}

Slot_Binding :: struct {
	set:     bool,
	buffer:  Buffer,
	offset:  u64,
	range:   u64,
	texture: Texture,
	mip:     i32,
	sampler: Sampler,
	accel:   Accel,
}

// A command list records into one MTLCommandBuffer. Encoders are opened lazily
// (compute for dispatches, blit for copies, acceleration structure for builds)
// and ended when another kind is needed; a render encoder exists exactly
// between cmd_begin_render_pass and cmd_end_render_pass. Bindings are recorded
// per slot and applied to the encoder at the next draw or dispatch.
Command_List :: struct {
	device:           ^Device,
	cmd:              ^MTL.CommandBuffer,
	immediate:        bool,
	encoder_kind:     Mtl_Encoder_Kind,
	encoder:          ^MTL.CommandEncoder,
	render:           ^MTL.RenderCommandEncoder,
	compute:          ^MTL.ComputeCommandEncoder,
	blit:             ^MTL.BlitCommandEncoder,
	accel:            ^MTL.AccelerationStructureCommandEncoder,
	in_render_pass:   bool,
	pass_width:       u32,
	pass_height:      u32,
	pipeline:         Pipeline,
	pipeline_applied: bool, // pipeline state set on the current encoder
	slots:            [MAX_BINDING_SLOTS]Slot_Binding,
	dirty:            u32, // slots to apply to the current encoder
	table:            Shader_Stages, // stages of the current encoder that have the texture table
	index_buffer:     Buffer,
	index_offset:     u64,
	scratch_used:     u64, // acceleration structure scratch bytes used by the current encoder
	// Debug labels form a stack that every encoder mirrors as debug groups:
	// an encoder pushes the whole stack when it opens and pops it before it
	// ends, so groups stay balanced whatever the encoder boundaries are.
	labels:           [MAX_LABEL_DEPTH]^NS.String,
	label_count:      int,
	label_overflow:   int,
}

@(private)
mtl_list_reset :: proc(c: ^Command_List, cmd: ^MTL.CommandBuffer) {
	c.cmd = cmd
	c.encoder_kind = .None
	c.encoder = nil
	c.render = nil
	c.compute = nil
	c.blit = nil
	c.accel = nil
	c.in_render_pass = false
	c.pipeline = 0
	c.pipeline_applied = false
	c.slots = {}
	c.dirty = max(u32)
	c.table = {}
	c.index_buffer = 0
	c.index_offset = 0
	c.scratch_used = 0
	c.label_count = 0
	c.label_overflow = 0
}

// Drops an open encoder without encoding anything else (device teardown).
@(private)
mtl_list_abandon :: proc(c: ^Command_List) {
	mtl_end_encoder(c)
	c.in_render_pass = false
	mtl_release_labels(c)
	c.cmd = nil
}

@(private)
mtl_release_labels :: proc(c: ^Command_List) {
	for i in 0 ..< c.label_count {mtl_release(c.labels[i])}
	c.label_count = 0
	c.label_overflow = 0
}

// ---------------------------------------------------------------- encoders

@(private)
mtl_end_encoder :: proc(c: ^Command_List) {
	if c.encoder == nil {return}
	for _ in 0 ..< c.label_count {MTL.CommandEncoder_popDebugGroup(c.encoder)}
	MTL.CommandEncoder_endEncoding(c.encoder)
	mtl_release(c.encoder)
	c.encoder = nil
	c.render = nil
	c.compute = nil
	c.blit = nil
	c.accel = nil
	c.encoder_kind = .None
	c.pipeline_applied = false
	c.dirty = max(u32)
	c.table = {}
}

@(private)
mtl_opened_encoder :: proc(c: ^Command_List, encoder: ^MTL.CommandEncoder, kind: Mtl_Encoder_Kind) {
	// A nested autorelease pool can drain before this command list ends the encoder.
	mtl_retain(encoder)
	c.encoder = encoder
	c.encoder_kind = kind
	for i in 0 ..< c.label_count {MTL.CommandEncoder_pushDebugGroup(encoder, c.labels[i])}
	c.pipeline_applied = false
	c.dirty = max(u32)
	c.table = {}
	c.scratch_used = 0
}

// Metal's MTLCounterDontSample.
@(private)
MTL_DONT_SAMPLE :: max(NS.UInteger)

// The samples of the encoder about to open, in a frame that wants timings
// and after its first mark: the start at index, the end at index+1.
@(private)
mtl_sample_slot :: proc(c: ^Command_List) -> (buffer: ^MTL.CounterSampleBuffer, index: NS.UInteger, ok: bool) {
	if c.immediate {return}
	d := c.device
	f := &d.frames[d.slot]
	if !f.passes || f.query_count == 0 || f.encoder_count >= MAX_TIMESTAMPS {return}
	f.encoder_marks[f.encoder_count] = u16(f.query_count - 1)
	index = NS.UInteger(f.encoder_count) * 2
	f.encoder_count += 1
	return f.queries, index, true
}

@(private)
mtl_compute_encoder :: proc(c: ^Command_List) -> ^MTL.ComputeCommandEncoder {
	if c.encoder_kind == .Compute {return c.compute}
	assert(!c.in_render_pass, "rhi: compute work inside a render pass")
	mtl_end_encoder(c)
	// Serial dispatch: each dispatch observes the writes of the previous one.
	if buffer, index, sampled := mtl_sample_slot(c); sampled {
		desc := MTL.ComputePassDescriptor_computePassDescriptor()
		attachment := MTL.ComputePassSampleBufferAttachmentDescriptorArray_object(MTL.ComputePassDescriptor_sampleBufferAttachments(desc), 0)
		MTL.ComputePassSampleBufferAttachmentDescriptor_setSampleBuffer(attachment, buffer)
		MTL.ComputePassSampleBufferAttachmentDescriptor_setStartOfEncoderSampleIndex(attachment, index)
		MTL.ComputePassSampleBufferAttachmentDescriptor_setEndOfEncoderSampleIndex(attachment, index + 1)
		c.compute = MTL.CommandBuffer_computeCommandEncoderWithDescriptor(c.cmd, desc)
	} else {
		c.compute = MTL.CommandBuffer_computeCommandEncoder(c.cmd)
	}
	mtl_opened_encoder(c, cast(^MTL.CommandEncoder)c.compute, .Compute)
	return c.compute
}

@(private)
mtl_blit_encoder :: proc(c: ^Command_List) -> ^MTL.BlitCommandEncoder {
	if c.encoder_kind == .Blit {return c.blit}
	assert(!c.in_render_pass, "rhi: copies inside a render pass")
	mtl_end_encoder(c)
	if buffer, index, sampled := mtl_sample_slot(c); sampled {
		desc := MTL.BlitPassDescriptor_blitPassDescriptor()
		attachment := MTL.BlitPassSampleBufferAttachmentDescriptorArray_object(MTL.BlitPassDescriptor_sampleBufferAttachments(desc), 0)
		MTL.BlitPassSampleBufferAttachmentDescriptor_setSampleBuffer(attachment, buffer)
		MTL.BlitPassSampleBufferAttachmentDescriptor_setStartOfEncoderSampleIndex(attachment, index)
		MTL.BlitPassSampleBufferAttachmentDescriptor_setEndOfEncoderSampleIndex(attachment, index + 1)
		c.blit = MTL.CommandBuffer_blitCommandEncoderWithDescriptor(c.cmd, desc)
	} else {
		c.blit = MTL.CommandBuffer_blitCommandEncoder(c.cmd)
	}
	mtl_opened_encoder(c, cast(^MTL.CommandEncoder)c.blit, .Blit)
	return c.blit
}

@(private)
mtl_accel_encoder :: proc(c: ^Command_List) -> ^MTL.AccelerationStructureCommandEncoder {
	if c.encoder_kind == .Accel {return c.accel}
	assert(!c.in_render_pass, "rhi: acceleration structure builds inside a render pass")
	mtl_end_encoder(c)
	if buffer, index, sampled := mtl_sample_slot(c); sampled {
		desc := MTL.AccelerationStructurePassDescriptor_accelerationStructurePassDescriptor()
		attachment := MTL.AccelerationStructurePassSampleBufferAttachmentDescriptorArray_object(MTL.AccelerationStructurePassDescriptor_sampleBufferAttachments(desc), 0)
		MTL.AccelerationStructurePassSampleBufferAttachmentDescriptor_setSampleBuffer(attachment, buffer)
		MTL.AccelerationStructurePassSampleBufferAttachmentDescriptor_setStartOfEncoderSampleIndex(attachment, index)
		MTL.AccelerationStructurePassSampleBufferAttachmentDescriptor_setEndOfEncoderSampleIndex(attachment, index + 1)
		c.accel = MTL.CommandBuffer_accelerationStructureCommandEncoderWithDescriptor(c.cmd, desc)
	} else {
		c.accel = MTL.CommandBuffer_accelerationStructureCommandEncoder(c.cmd)
	}
	mtl_opened_encoder(c, cast(^MTL.CommandEncoder)c.accel, .Accel)
	return c.accel
}

// ---------------------------------------------------------------- hazards

// Every resource uses MTLHazardTrackingModeTracked, so Metal inserts the
// waits a pass needs itself, as Vulkan derives them from what the pass binds;
// the barriers only keep the Vulkan usage rules.
cmd_barrier_buffer :: proc(c: ^Command_List, buffer: Buffer, access: Access) {
	if pool_get(&c.device.buffers, base.Handle(buffer)) == nil {return}
	assert(!c.in_render_pass, "rhi: buffer barriers must be recorded outside render passes")
}

cmd_barrier_texture :: proc(c: ^Command_List, texture: Texture, access: Access) {}

// ---------------------------------------------------------------- render passes

@(private)
mtl_load_action :: proc "contextless" (op: Load_Op) -> MTL.LoadAction {
	switch op {
	case .Clear:     return .Clear
	case .Load:      return .Load
	case .Dont_Care: return .DontCare
	}
	return .DontCare
}

@(private)
mtl_store_action :: proc "contextless" (op: Store_Op) -> MTL.StoreAction {
	return .Store if op == .Store else .DontCare
}

cmd_begin_render_pass :: proc(c: ^Command_List, desc: ^Render_Pass_Desc) {
	d := c.device
	assert(!c.in_render_pass, "rhi: nested render pass")
	mtl_end_encoder(c)
	rpd := MTL.RenderPassDescriptor.alloc()->init()
	defer mtl_release(rpd)
	width, height: u32 = max(u32), max(u32)
	colors := MTL.RenderPassDescriptor_colorAttachments(rpd)
	for i in 0 ..< desc.color_count {
		a := desc.colors[i]
		t := pool_get(&d.textures, base.Handle(a.texture))
		if t == nil || t.handle == nil {set_error(d, "render pass %s has an invalid color target", desc.name); return}
		width = min(width, t.desc.width)
		height = min(height, t.desc.height)
		attachment := MTL.RenderPassColorAttachmentDescriptorArray_object(colors, NS.UInteger(i))
		base := cast(^MTL.RenderPassAttachmentDescriptor)attachment
		MTL.RenderPassAttachmentDescriptor_setTexture(base, t.handle)
		MTL.RenderPassAttachmentDescriptor_setLoadAction(base, mtl_load_action(a.load))
		MTL.RenderPassAttachmentDescriptor_setStoreAction(base, mtl_store_action(a.store))
		clear := [4]f64{f64(a.clear[0]), f64(a.clear[1]), f64(a.clear[2]), f64(a.clear[3])}
		// Metal takes the clear of an integer target as doubles that hold the integers.
		if format_is_uint(t.desc.format) {clear = {f64(a.clear_uint[0]), f64(a.clear_uint[1]), f64(a.clear_uint[2]), f64(a.clear_uint[3])}}
		MTL.RenderPassColorAttachmentDescriptor_setClearColor(attachment, MTL.ClearColor{clear[0], clear[1], clear[2], clear[3]})
	}
	if desc.depth.texture != 0 {
		t := pool_get(&d.textures, base.Handle(desc.depth.texture))
		if t == nil || t.handle == nil {set_error(d, "render pass %s has an invalid depth target", desc.name); return}
		width = min(width, t.desc.width)
		height = min(height, t.desc.height)
		depth := MTL.RenderPassDescriptor_depthAttachment(rpd)
		base := cast(^MTL.RenderPassAttachmentDescriptor)depth
		MTL.RenderPassAttachmentDescriptor_setTexture(base, t.handle)
		MTL.RenderPassAttachmentDescriptor_setLoadAction(base, mtl_load_action(desc.depth.load))
		MTL.RenderPassAttachmentDescriptor_setStoreAction(base, mtl_store_action(desc.depth.store))
		MTL.RenderPassDepthAttachmentDescriptor_setClearDepth(depth, f64(desc.depth.clear))
	}
	if width == max(u32) {
		// No attachments: Metal needs an explicit render target size.
		width, height = 1, 1
		MTL.RenderPassDescriptor_setRenderTargetWidth(rpd, 1)
		MTL.RenderPassDescriptor_setRenderTargetHeight(rpd, 1)
		MTL.RenderPassDescriptor_setDefaultRasterSampleCount(rpd, 1)
	}
	if buffer, index, sampled := mtl_sample_slot(c); sampled {
		attachment := MTL.RenderPassSampleBufferAttachmentDescriptorArray_object(MTL.RenderPassDescriptor_sampleBufferAttachments(rpd), 0)
		MTL.RenderPassSampleBufferAttachmentDescriptor_setSampleBuffer(attachment, buffer)
		MTL.RenderPassSampleBufferAttachmentDescriptor_setStartOfVertexSampleIndex(attachment, index)
		MTL.RenderPassSampleBufferAttachmentDescriptor_setEndOfVertexSampleIndex(attachment, MTL_DONT_SAMPLE)
		MTL.RenderPassSampleBufferAttachmentDescriptor_setStartOfFragmentSampleIndex(attachment, MTL_DONT_SAMPLE)
		MTL.RenderPassSampleBufferAttachmentDescriptor_setEndOfFragmentSampleIndex(attachment, index + 1)
	}
	c.render = MTL.CommandBuffer_renderCommandEncoderWithDescriptor(c.cmd, rpd)
	if c.render == nil {set_error(d, "render pass %s: renderCommandEncoderWithDescriptor failed", desc.name); return}
	encoder := cast(^MTL.CommandEncoder)c.render
	if desc.name != "" {
		label := mtl_string(desc.name)
		MTL.CommandEncoder_setLabel(encoder, label)
		mtl_release(label)
	}
	mtl_opened_encoder(c, encoder, .Render)
	c.in_render_pass = true
	c.pass_width = width
	c.pass_height = height
	// Counter-clockwise front faces in the shared Y-up clip space, as on Vulkan.
	MTL.RenderCommandEncoder_setFrontFacingWinding(c.render, .CounterClockwise)
	cmd_set_viewport(c, 0, 0, f32(width), f32(height))
	cmd_set_scissor(c, 0, 0, width, height)
}

cmd_end_render_pass :: proc(c: ^Command_List) {
	if !c.in_render_pass {return}
	mtl_end_encoder(c)
	c.in_render_pass = false
}

// Metal clip space is already Y-up with depth in [0,1]; the viewport maps
// directly (NDC y = +1 lands on row y).
cmd_set_viewport :: proc(c: ^Command_List, x, y, width, height: f32) {
	if c.render == nil {return}
	MTL.RenderCommandEncoder_setViewport(c.render, MTL.Viewport{originX = f64(x), originY = f64(y), width = f64(width), height = f64(height), znear = 0, zfar = 1})
}

// Metal rejects scissor rectangles outside the render target, so the rectangle
// is clamped to the pass size.
cmd_set_scissor :: proc(c: ^Command_List, x, y: i32, width, height: u32) {
	if c.render == nil {return}
	x0 := min(u64(max(x, 0)), u64(c.pass_width))
	y0 := min(u64(max(y, 0)), u64(c.pass_height))
	x1 := min(u64(max(x, 0)) + u64(width), u64(c.pass_width))
	y1 := min(u64(max(y, 0)) + u64(height), u64(c.pass_height))
	rect := MTL.ScissorRect{x = NS.UInteger(x0), y = NS.UInteger(y0), width = NS.UInteger(x1 - x0), height = NS.UInteger(y1 - y0)}
	MTL.RenderCommandEncoder_setScissorRect(c.render, rect)
}

// ---------------------------------------------------------------- bindings

cmd_bind_pipeline :: proc(c: ^Command_List, pipeline: Pipeline) {
	p := pool_get(&c.device.pipelines, base.Handle(pipeline))
	if p == nil {set_error(c.device, "bind of an invalid pipeline"); c.pipeline = 0; return}
	if c.pipeline == pipeline {return}
	c.pipeline = pipeline
	c.pipeline_applied = false
	// Stage masks differ between pipelines; re-apply every slot.
	c.dirty = max(u32)
}

cmd_bind_buffer :: proc(c: ^Command_List, slot: u32, buffer: Buffer, offset: u64 = 0, size: u64 = 0) {
	b := pool_get(&c.device.buffers, base.Handle(buffer))
	if b == nil || !binding_slot_valid(slot, .Storage_Buffer) {set_error(c.device, "invalid buffer binding at slot %d", slot); return}
	range := size if size > 0 else b.size - offset
	c.slots[slot] = {set = true, buffer = buffer, offset = offset, range = range}
	c.dirty |= 1 << slot
}

cmd_bind_transient :: proc(c: ^Command_List, slot: u32, t: Transient) {
	cmd_bind_buffer(c, slot, t.buffer, t.offset, t.size)
}

// Copies small per-dispatch parameters into the frame ring and binds them as a
// uniform buffer at slot (256-byte aligned, as Metal constant buffers require).
cmd_set_constants :: proc(c: ^Command_List, slot: u32, data: rawptr, size: int) -> bool {
	if c.immediate {
		set_error(c.device, "constants are only available inside frames")
		return false
	}
	t := frame_alloc(c.device, u64(size), 256)
	if t.ptr == nil {
		// Never let the next draw/dispatch run with a previous pass's parameters.
		if slot < MAX_BINDING_SLOTS {c.slots[slot] = {}}
		return false
	}
	intrinsics.mem_copy_non_overlapping(t.ptr, data, size)
	cmd_bind_transient(c, slot, t)
	return true
}

cmd_bind_texture :: proc(c: ^Command_List, slot: u32, texture: Texture, mip: i32 = -1) {
	if pool_get(&c.device.textures, base.Handle(texture)) == nil || slot >= MAX_BINDING_SLOTS {set_error(c.device, "invalid texture binding at slot %d", slot); return}
	c.slots[slot] = {set = true, texture = texture, mip = mip}
	c.dirty |= 1 << slot
}

cmd_bind_sampler :: proc(c: ^Command_List, slot: u32, sampler: Sampler) {
	if pool_get(&c.device.samplers, base.Handle(sampler)) == nil || !binding_slot_valid(slot, .Sampler) {set_error(c.device, "invalid sampler binding at slot %d", slot); return}
	c.slots[slot] = {set = true, sampler = sampler}
	c.dirty |= 1 << slot
}

cmd_bind_accel :: proc(c: ^Command_List, slot: u32, accel: Accel) {
	if pool_get(&c.device.accels, base.Handle(accel)) == nil || !binding_slot_valid(slot, .Accel) {set_error(c.device, "invalid acceleration structure binding at slot %d", slot); return}
	c.slots[slot] = {set = true, accel = accel}
	c.dirty |= 1 << slot
}

@(private)
mtl_texture_view :: proc(t: ^Mtl_Texture, mip: i32) -> ^MTL.Texture {
	if mip >= 0 && t.desc.mip_levels > 1 {
		if u32(mip) >= t.desc.mip_levels {return nil}
		return t.mip_views[mip]
	}
	return t.handle
}

// An instance acceleration structure reaches its primitive structures
// indirectly; Metal requires them to be made resident on the encoder.
@(private)
mtl_use_accel :: proc(c: ^Command_List, a: ^Mtl_Accel) {
	read := MTL.ResourceUsage{.Read}
	if c.encoder_kind == .Compute {
		for blas in a.referenced {MTL.ComputeCommandEncoder_useResource(c.compute, cast(^MTL.Resource)blas, read)}
		if a.instance_buffer != nil {MTL.ComputeCommandEncoder_useResource(c.compute, cast(^MTL.Resource)a.instance_buffer, read)}
	} else if c.encoder_kind == .Render {
		for blas in a.referenced {MTL.RenderCommandEncoder_useResource(c.render, cast(^MTL.Resource)blas, read)}
		if a.instance_buffer != nil {MTL.RenderCommandEncoder_useResource(c.render, cast(^MTL.Resource)a.instance_buffer, read)}
	}
}

// Applies the bound pipeline and every dirty slot it uses to the current
// encoder. compute selects the compute encoder; otherwise the render encoder
// of the open pass is used.
@(private)
mtl_flush_bindings :: proc(c: ^Command_List, compute: bool) -> bool {
	d := c.device
	p := pool_get(&d.pipelines, base.Handle(c.pipeline))
	if p == nil {set_error(d, "draw or dispatch without a pipeline"); return false}
	if p.is_compute != compute {
		set_error(d, "pipeline %s is a %s pipeline", p.name, "compute" if p.is_compute else "graphics")
		return false
	}
	for slot, i in p.slots {
		if slot.used && !c.slots[i].set {set_error(d, "pipeline %s: slot %d is not bound", p.name, i); return false}
	}
	if compute {
		encoder := mtl_compute_encoder(c)
		if !c.pipeline_applied {
			MTL.ComputeCommandEncoder_setComputePipelineState(encoder, p.compute)
			c.pipeline_applied = true
		}
	} else {
		if c.render == nil {set_error(d, "draw outside a render pass"); return false}
		if !c.pipeline_applied {
			MTL.RenderCommandEncoder_setRenderPipelineState(c.render, p.render)
			MTL.RenderCommandEncoder_setDepthStencilState(c.render, p.depth_state)
			MTL.RenderCommandEncoder_setCullMode(c.render, p.cull)
			c.pipeline_applied = true
		}
	}
	dirty := c.dirty & p.slot_mask
	for i in 0 ..< u32(MAX_BINDING_SLOTS) {
		if dirty & (1 << i) == 0 {continue}
		slot := p.slots[i]
		s := c.slots[i]
		index := NS.UInteger(i)
		vertex := .Vertex in slot.stages
		fragment := .Fragment in slot.stages
		switch slot.kind {
		case .Uniform_Buffer, .Storage_Buffer, .Storage_Buffer_RW:
			b := pool_get(&d.buffers, base.Handle(s.buffer))
			if b == nil {set_error(d, "pipeline %s: slot %d buffer was destroyed", p.name, i); return false}
			offset := NS.UInteger(s.offset)
			if compute {
				MTL.ComputeCommandEncoder_setBuffer(c.compute, b.handle, offset, index)
			} else {
				if vertex {MTL.RenderCommandEncoder_setVertexBuffer(c.render, b.handle, offset, index)}
				if fragment {MTL.RenderCommandEncoder_setFragmentBuffer(c.render, b.handle, offset, index)}
			}
		case .Sampled_Texture, .Storage_Texture:
			t := pool_get(&d.textures, base.Handle(s.texture))
			if t == nil {set_error(d, "pipeline %s: slot %d texture was destroyed", p.name, i); return false}
			view := mtl_texture_view(t, s.mip)
			if view == nil {set_error(d, "pipeline %s: slot %d texture has no mip %d or no drawable", p.name, i, s.mip); return false}
			if compute {
				MTL.ComputeCommandEncoder_setTexture(c.compute, view, index)
			} else {
				if vertex {MTL.RenderCommandEncoder_setVertexTexture(c.render, view, index)}
				if fragment {MTL.RenderCommandEncoder_setFragmentTexture(c.render, view, index)}
			}
		case .Sampler:
			sampler := pool_get(&d.samplers, base.Handle(s.sampler))
			if sampler == nil {set_error(d, "pipeline %s: slot %d sampler was destroyed", p.name, i); return false}
			if compute {
				MTL.ComputeCommandEncoder_setSamplerState(c.compute, sampler^, index)
			} else {
				if vertex {MTL.RenderCommandEncoder_setVertexSamplerState(c.render, sampler^, index)}
				if fragment {MTL.RenderCommandEncoder_setFragmentSamplerState(c.render, sampler^, index)}
			}
		case .Accel:
			a := pool_get(&d.accels, base.Handle(s.accel))
			if a == nil {set_error(d, "pipeline %s: slot %d acceleration structure was destroyed", p.name, i); return false}
			if !a.built {set_error(d, "pipeline %s: slot %d acceleration structure was never built successfully", p.name, i); return false}
			if compute {
				MTL.ComputeCommandEncoder_setAccelerationStructure(c.compute, a.handle, index)
			} else {
				if vertex {MTL.RenderCommandEncoder_setVertexAccelerationStructure(c.render, a.handle, index)}
				if fragment {MTL.RenderCommandEncoder_setFragmentAccelerationStructure(c.render, a.handle, index)}
			}
			mtl_use_accel(c, a)
		case .Texture_Table:
		}
	}
	c.dirty &~= dirty
	if missing := p.table - c.table; missing != {} {
		resident := d.table_resident[:]
		buffer := d.table_buffers[table_copy(c.immediate, d.slot)]
		read := MTL.ResourceUsage{.Read}
		if .Compute in missing {
			MTL.ComputeCommandEncoder_setBuffer(c.compute, buffer, 0, TEXTURE_TABLE_METAL_BUFFER)
			MTL.ComputeCommandEncoder_useResources(c.compute, resident, read)
		}
		if .Vertex in missing {
			MTL.RenderCommandEncoder_setVertexBuffer(c.render, buffer, 0, TEXTURE_TABLE_METAL_BUFFER)
			MTL.RenderCommandEncoder_useResourcesStages(c.render, resident, read, {.StageVertex})
		}
		if .Fragment in missing {
			MTL.RenderCommandEncoder_setFragmentBuffer(c.render, buffer, 0, TEXTURE_TABLE_METAL_BUFFER)
			MTL.RenderCommandEncoder_useResourcesStages(c.render, resident, read, {.StageFragment})
		}
		c.table += missing
	}
	return true
}

// ---------------------------------------------------------------- draws and dispatches

cmd_bind_index_buffer :: proc(c: ^Command_List, buffer: Buffer, offset: u64 = 0) {
	if pool_get(&c.device.buffers, base.Handle(buffer)) == nil {return}
	c.index_buffer = buffer
	c.index_offset = offset
}

@(private)
mtl_index_buffer :: proc(c: ^Command_List) -> ^MTL.Buffer {
	b := pool_get(&c.device.buffers, base.Handle(c.index_buffer))
	if b == nil {set_error(c.device, "indexed draw without a valid index buffer"); return nil}
	return b.handle
}

@(private)
mtl_primitive :: proc(c: ^Command_List) -> MTL.PrimitiveType {
	p := pool_get(&c.device.pipelines, base.Handle(c.pipeline))
	return p.primitive if p != nil else .Triangle
}

cmd_draw :: proc(c: ^Command_List, vertex_count: u32, instance_count: u32 = 1, first_vertex: u32 = 0, first_instance: u32 = 0) {
	assert(c.in_render_pass)
	if vertex_count == 0 || instance_count == 0 {return}
	if !mtl_flush_bindings(c, false) {return}
	MTL.RenderCommandEncoder_drawPrimitives(c.render, mtl_primitive(c), NS.UInteger(first_vertex), NS.UInteger(vertex_count), NS.UInteger(instance_count), NS.UInteger(first_instance))
}

// Metal has no multi-draw indirect without indirect command buffers; each
// Draw_Indexed_Indirect record (MTLDrawIndexedPrimitivesIndirectArguments
// layout) is issued as its own indirect draw.
cmd_draw_indexed_indirect :: proc(c: ^Command_List, buffer: Buffer, offset: u64, draw_count: u32, stride: u32 = size_of(Draw_Indexed_Indirect)) {
	assert(c.in_render_pass)
	b := pool_get(&c.device.buffers, base.Handle(buffer))
	if b == nil || draw_count == 0 {return}
	index_buffer := mtl_index_buffer(c)
	if index_buffer == nil || !mtl_flush_bindings(c, false) {return}
	primitive := mtl_primitive(c)
	for i in 0 ..< u64(draw_count) {
		MTL.RenderCommandEncoder_drawIndexedPrimitives(c.render, primitive, .UInt32, index_buffer, NS.UInteger(c.index_offset), b.handle, NS.UInteger(offset + i * u64(stride)))
	}
}

// Draws whose arguments (Draw_Indirect, MTLDrawPrimitivesIndirectArguments)
// the GPU wrote: each record its own indirect draw, as indexed ones.
cmd_draw_indirect :: proc(c: ^Command_List, buffer: Buffer, offset: u64, draw_count: u32, stride: u32 = size_of(Draw_Indirect)) {
	assert(c.in_render_pass)
	b := pool_get(&c.device.buffers, base.Handle(buffer))
	if b == nil || draw_count == 0 {return}
	if !mtl_flush_bindings(c, false) {return}
	primitive := mtl_primitive(c)
	for i in 0 ..< u64(draw_count) {
		MTL.RenderCommandEncoder_drawPrimitives(c.render, primitive, b.handle, NS.UInteger(offset + i * u64(stride)))
	}
}

cmd_dispatch :: proc(c: ^Command_List, x: u32, y: u32 = 1, z: u32 = 1) {
	assert(!c.in_render_pass, "rhi: dispatch inside a render pass")
	if x == 0 || y == 0 || z == 0 {return}
	if !mtl_flush_bindings(c, true) {return}
	p := pool_get(&c.device.pipelines, base.Handle(c.pipeline))
	MTL.ComputeCommandEncoder_dispatchThreadgroups(c.compute, MTL.Size{NS.UInteger(x), NS.UInteger(y), NS.UInteger(z)}, p.threadgroup)
}

cmd_dispatch_indirect :: proc(c: ^Command_List, buffer: Buffer, offset: u64) {
	assert(!c.in_render_pass)
	b := pool_get(&c.device.buffers, base.Handle(buffer))
	if b == nil {return}
	if !mtl_flush_bindings(c, true) {return}
	p := pool_get(&c.device.pipelines, base.Handle(c.pipeline))
	MTL.ComputeCommandEncoder_dispatchThreadgroupsWithIndirectBuffer(c.compute, b.handle, NS.UInteger(offset), p.threadgroup)
}

// ---------------------------------------------------------------- copies

// On macOS blit buffer copies need 4-byte aligned offsets and sizes.
cmd_copy_buffer :: proc(c: ^Command_List, src: Buffer, src_offset: u64, dst: Buffer, dst_offset: u64, size: u64) {
	assert(!c.in_render_pass)
	d := c.device
	s := pool_get(&d.buffers, base.Handle(src))
	t := pool_get(&d.buffers, base.Handle(dst))
	if s == nil || t == nil || size == 0 {return}
	if src_offset + size > s.length || dst_offset + size > t.length {set_error(d, "cmd_copy_buffer out of range"); return}
	if src_offset % 4 != 0 || dst_offset % 4 != 0 || size % 4 != 0 {set_error(d, "cmd_copy_buffer needs 4-byte aligned offsets and size on Metal (source %d, destination %d, size %d)", src_offset, dst_offset, size); return}
	encoder := mtl_blit_encoder(c)
	MTL.BlitCommandEncoder_copyFromBuffer(encoder, s.handle, NS.UInteger(src_offset), t.handle, NS.UInteger(dst_offset), NS.UInteger(size))
}

// Sets every byte of the range to value: Metal fills bytes, not words.
cmd_fill_buffer :: proc(c: ^Command_List, buffer: Buffer, offset: u64, size: u64, value: u8) {
	assert(!c.in_render_pass)
	b := pool_get(&c.device.buffers, base.Handle(buffer))
	if b == nil || size == 0 || offset >= b.size {return}
	// Same contract as Vulkan: 4-byte aligned offset and size (macOS blits).
	if offset % 4 != 0 || size % 4 != 0 {set_error(c.device, "cmd_fill_buffer needs 4-byte aligned offset and size"); return}
	length := min(size, b.length - offset)
	encoder := mtl_blit_encoder(c)
	MTL.BlitCommandEncoder_fillBuffer(encoder, b.handle, NS.Range{NS.UInteger(offset), NS.UInteger(length)}, value)
}

// Copies tightly packed rows from a buffer into a region of one mip of a
// texture (texture_region_resolve), layer after layer: each one a slice.
cmd_copy_buffer_to_texture :: proc(c: ^Command_List, src: Buffer, src_offset: u64, dst: Texture, mip: u32 = 0, region := Texture_Region{}) {
	assert(!c.in_render_pass)
	d := c.device
	b := pool_get(&d.buffers, base.Handle(src))
	t := pool_get(&d.textures, base.Handle(dst))
	if b == nil || t == nil || t.handle == nil || mip >= t.desc.mip_levels {return}
	area, inside := texture_region_resolve(t.desc, mip, region)
	if !inside {return}
	row_bytes, rows := format_rows(t.desc.format, area.width, area.height)
	row := NS.UInteger(row_bytes)
	image := row * NS.UInteger(rows)
	encoder := mtl_blit_encoder(c)
	for slice in 0 ..< max(t.desc.layers, 1) {
		MTL.BlitCommandEncoder_copyFromBuffer(
			encoder, b.handle, NS.UInteger(src_offset) + NS.UInteger(slice) * image, row, image,
			MTL.Size{NS.UInteger(area.width), NS.UInteger(area.height), 1}, t.handle, NS.UInteger(slice), NS.UInteger(mip), MTL.Origin{NS.UInteger(area.x), NS.UInteger(area.y), 0},
		)
	}
}

// Copies mip 0 into a buffer as tightly packed rows, slice after slice of a 3D texture.
cmd_copy_texture_to_buffer :: proc(c: ^Command_List, src: Texture, dst: Buffer, dst_offset: u64) {
	assert(!c.in_render_pass)
	d := c.device
	t := pool_get(&d.textures, base.Handle(src))
	b := pool_get(&d.buffers, base.Handle(dst))
	if b == nil || t == nil || t.handle == nil {return}
	row := NS.UInteger(t.desc.width) * NS.UInteger(format_size(t.desc.format))
	encoder := mtl_blit_encoder(c)
	MTL.BlitCommandEncoder_copyFromTexture(
		encoder, t.handle, 0, 0, MTL.Origin{0, 0, 0}, MTL.Size{NS.UInteger(t.desc.width), NS.UInteger(t.desc.height), NS.UInteger(max(t.desc.depth, 1))},
		b.handle, NS.UInteger(dst_offset), row, row * NS.UInteger(t.desc.height),
	)
}

// Copies `mips` mips of a texture from src_mip into those of another from
// dst_mip, every layer, with its bytes as they are: nothing converts between
// the sRGB encodings of the two. What it copies between: texture_copy_problem;
// neither is the image of the swapchain.
cmd_copy_texture :: proc(c: ^Command_List, src: Texture, dst: Texture, src_mip: u32 = 0, dst_mip: u32 = 0, mips: u32 = 1) {
	assert(!c.in_render_pass)
	d := c.device
	s := pool_get(&d.textures, base.Handle(src))
	t := pool_get(&d.textures, base.Handle(dst))
	if s == nil || t == nil || s.handle == nil || t.handle == nil {return}
	if src == dst || s.swapchain || t.swapchain {set_error(d, "cmd_copy_texture: it copies between two textures of the device, not the image of the swapchain"); return}
	if problem := texture_copy_problem(s.desc, t.desc, src_mip, dst_mip, mips); problem != "" {set_error(d, "cmd_copy_texture: %s", problem); return}
	source := s.handle
	if s.format != t.format {
		// A blit takes two textures of one pixel format. A view that changes
		// the sRGB encoding alone asks for no usage of the texture.
		if s.encoded == nil {s.encoded = MTL.Texture_newTextureViewWithPixelFormat(s.handle, t.format)}
		if s.encoded == nil {set_error(d, "cmd_copy_texture: newTextureViewWithPixelFormat failed"); return}
		source = s.encoded
	}
	encoder := mtl_blit_encoder(c)
	for k in 0 ..< mips {
		from, to := src_mip + k, dst_mip + k
		size := MTL.Size{NS.UInteger(max(s.desc.width >> from, 1)), NS.UInteger(max(s.desc.height >> from, 1)), 1}
		for slice in 0 ..< NS.UInteger(max(s.desc.layers, 1)) {
			MTL.BlitCommandEncoder_copyFromTexture(encoder, source, slice, NS.UInteger(from), MTL.Origin{0, 0, 0}, size, t.handle, slice, NS.UInteger(to), MTL.Origin{0, 0, 0})
		}
	}
}

// ---------------------------------------------------------------- debugging and timing

cmd_push_label :: proc(c: ^Command_List, name: string) {
	if c.label_count == MAX_LABEL_DEPTH {c.label_overflow += 1; return}
	label := mtl_string(name)
	c.labels[c.label_count] = label
	c.label_count += 1
	if c.encoder != nil {MTL.CommandEncoder_pushDebugGroup(c.encoder, label)}
}

cmd_pop_label :: proc(c: ^Command_List) {
	if c.label_overflow > 0 {c.label_overflow -= 1; return}
	if c.label_count == 0 {return}
	if c.encoder != nil {MTL.CommandEncoder_popDebugGroup(c.encoder)}
	c.label_count -= 1
	mtl_release(c.labels[c.label_count])
	c.labels[c.label_count] = nil
}

// Marks the start of an interval that frame_timings reports under this name
// once the slot completes, in a frame that wants timings. The work after the
// mark opens an encoder of its own, whose boundary samples bound it.
cmd_timestamp :: proc(c: ^Command_List, name: string) {
	if c.immediate {return}
	d := c.device
	f := &d.frames[d.slot]
	if !f.passes || f.query_count >= MAX_TIMESTAMPS {return}
	if !c.in_render_pass {mtl_end_encoder(c)}
	f.query_names[f.query_count] = string(f.query_bytes[f.query_count][:copy(f.query_bytes[f.query_count][:], name)])
	f.query_count += 1
}
