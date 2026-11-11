#+build linux, windows
package rhi

import "core:strings"
import "mirai:std/base"
import vk "vendor:vulkan"

MAX_PENDING_IMAGE_BARRIERS :: 32
// What a render pass records before it goes out: its commands and the
// resources its draws use (pass_end).
PASS_COMMAND_CAPACITY :: 16384
PASS_RESOURCE_CAPACITY :: 256

Slot_Binding :: struct {
	set:     bool,
	kind:    Binding_Kind,
	buffer:  Buffer,
	offset:  u64,
	range:   u64,
	texture: Texture,
	mip:     i32,
	sampler: Sampler,
	accel:   Accel,
}

@(private)
Pass_Command_Kind :: enum u8 {Pipeline, Slot, Index, Viewport, Scissor, Draw, Draw_Indirect, Draw_Indexed_Indirect, Push_Label, Pop_Label, Timestamp}

@(private)
Pass_Command :: struct {
	kind: Pass_Command_Kind,
	slot: u32,
	using _: struct #raw_union {
		binding:  Slot_Binding,
		pipeline: Pipeline,
		draw:     struct {buffer: Buffer, offset: u64, values: [4]u32},
		rect:     [4]f32,
		name:     string,
	},
}

// A resource the draws of a render pass use, with every access they make.
@(private)
Pass_Use :: struct {
	texture: Texture,
	buffer:  Buffer,
	mip:     i32, // of the texture, or -1 for all
	access:  bit_set[Access],
}

// Inside a render pass nothing reaches the command buffer: the pass is
// recorded and goes out at cmd_end_render_pass, after the barriers that what
// its draws bind needs, which no pass can hold.
Command_List :: struct {
	device:          ^Device,
	cmd:             vk.CommandBuffer,
	immediate:       bool,
	in_render_pass:  bool,
	pipeline:        Pipeline,
	slots:           [MAX_BINDING_SLOTS]Slot_Binding,
	dirty:           bool,
	image_barriers:  [MAX_PENDING_IMAGE_BARRIERS]vk.ImageMemoryBarrier2,
	image_count:     int,
	memory_barrier:  vk.MemoryBarrier2,
	memory_pending:  bool,
	index_buffer:    Buffer,
	pass:            Render_Pass_Desc,
	pass_extent:     [2]u32,
	pass_failed:     bool, // the pass reported an error and does not go out
	pass_pipeline:   Pipeline, // the bindings when the pass began, from which its commands replay
	pass_slots:      [MAX_BINDING_SLOTS]Slot_Binding,
	pass_dirty:      bool,
	commands:        []Pass_Command, // PASS_COMMAND_CAPACITY, made with the device
	command_count:   int,
	uses:            [PASS_RESOURCE_CAPACITY]Pass_Use,
	use_count:       int,
}

@(private)
vk_list_reset :: proc(c: ^Command_List) {
	c.in_render_pass = false
	c.pipeline = 0
	c.slots = {}
	c.dirty = false
	c.image_count = 0
	c.memory_pending = false
	c.command_count = 0
	c.use_count = 0
}

// ---------------------------------------------------------------- hazards

@(private)
Access_Info :: struct {
	stages: vk.PipelineStageFlags2,
	access: vk.AccessFlags2,
}

@(private)
SHADER_STAGES :: vk.PipelineStageFlags2{.VERTEX_SHADER, .FRAGMENT_SHADER, .COMPUTE_SHADER}

@(private)
vk_access_info :: proc(d: ^Device, a: Access) -> Access_Info {
	shader_stages := SHADER_STAGES
	switch a {
	case .None:              return {}
	case .Shader_Read:       return {shader_stages, {.SHADER_READ, .UNIFORM_READ}}
	case .Shader_Write:      return {{.FRAGMENT_SHADER, .COMPUTE_SHADER}, {.SHADER_READ, .SHADER_WRITE}}
	case .Index_Read:        return {{.INDEX_INPUT}, {.INDEX_READ}}
	case .Indirect_Read:     return {{.DRAW_INDIRECT}, {.INDIRECT_COMMAND_READ}}
	case .Color_Target:      return {{.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}}
	case .Depth_Target:      return {{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}, {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE}}
	case .Depth_Read:        return {shader_stages, {.SHADER_READ}}
	case .Transfer_Read:     return {{.ALL_TRANSFER}, {.TRANSFER_READ}}
	case .Transfer_Write:    return {{.ALL_TRANSFER}, {.TRANSFER_WRITE}}
	case .Accel_Build_Input: return {{.ACCELERATION_STRUCTURE_BUILD_KHR}, {.SHADER_READ, .ACCELERATION_STRUCTURE_READ_KHR}}
	case .Accel_Build_Write: return {{.ACCELERATION_STRUCTURE_BUILD_KHR}, {.ACCELERATION_STRUCTURE_READ_KHR, .ACCELERATION_STRUCTURE_WRITE_KHR}}
	case .Accel_Read:        return {shader_stages, {.ACCELERATION_STRUCTURE_READ_KHR}}
	case .Present:           return {{.BOTTOM_OF_PIPE}, {}}
	case .Host_Read:         return {{.HOST}, {.HOST_READ}}
	}
	return {}
}

@(private)
vk_layout_for :: proc(t: ^Vk_Texture, layout: vk.ImageLayout, a: Access) -> vk.ImageLayout {
	#partial switch a {
	case .Shader_Read, .Depth_Read:
		return .GENERAL if .Storage in t.desc.usage else .SHADER_READ_ONLY_OPTIMAL
	case .Shader_Write:   return .GENERAL
	case .Color_Target:   return .COLOR_ATTACHMENT_OPTIMAL
	case .Depth_Target:   return .DEPTH_ATTACHMENT_OPTIMAL
	case .Transfer_Read:  return .TRANSFER_SRC_OPTIMAL
	case .Transfer_Write: return .TRANSFER_DST_OPTIMAL
	case .Present:        return .PRESENT_SRC_KHR
	}
	return layout
}

@(private)
WRITE_ACCESS :: vk.AccessFlags2{.SHADER_WRITE, .SHADER_STORAGE_WRITE, .COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE, .TRANSFER_WRITE, .HOST_WRITE, .MEMORY_WRITE, .ACCELERATION_STRUCTURE_WRITE_KHR}

// Source scope of a dependency: the stages of the last write (or layout
// transition) plus every read since, with only write bits in the access mask.
// Reads need an execution dependency only.
@(private)
vk_source_info :: proc(d: ^Device, write: Access, reads: bit_set[Access]) -> Access_Info {
	info := vk_access_info(d, write)
	info.access &= WRITE_ACCESS
	for r in reads {info.stages += vk_access_info(d, r).stages}
	return info
}

cmd_barrier_buffer :: proc(c: ^Command_List, buffer: Buffer, access: Access) {
	d := c.device
	b := pool_get(&d.buffers, base.Handle(buffer))
	if b == nil {return}
	assert(!c.in_render_pass, "rhi: buffer barriers must be recorded outside render passes")
	dst := vk_access_info(d, access)
	if access_is_write(access) {
		if b.write == .None && b.reads == {} {b.write = access; return}
		vk_queue_memory_barrier(c, vk_source_info(d, b.write, b.reads), dst)
		b.write = access
		b.reads = {}
		return
	}
	if access in b.reads {return}
	if b.write != .None {vk_queue_memory_barrier(c, vk_source_info(d, b.write, {}), dst)}
	b.reads += {access}
}

@(private)
vk_queue_memory_barrier :: proc(c: ^Command_List, src, dst: Access_Info) {
	if !c.memory_pending {
		c.memory_barrier = {sType = .MEMORY_BARRIER_2}
		c.memory_pending = true
	}
	c.memory_barrier.srcStageMask += src.stages if src.stages != {} else {.ALL_COMMANDS}
	c.memory_barrier.srcAccessMask += src.access
	c.memory_barrier.dstStageMask += dst.stages
	c.memory_barrier.dstAccessMask += dst.access
}

// mip: the one mip the access reaches, or -1 for all of them.
cmd_barrier_texture :: proc(c: ^Command_List, texture: Texture, access: Access, mip: i32 = -1) {
	t := pool_get(&c.device.textures, base.Handle(texture))
	if t == nil || mip >= i32(t.desc.mip_levels) {return}
	if mip < 0 {vk_barrier_levels(c, t, access, 0, t.desc.mip_levels)} else {vk_barrier_levels(c, t, access, u32(mip), 1)}
}

// Brings mips [first, first + count) to an access with one barrier for each
// run of mips in one state: a texture used whole takes one.
@(private)
vk_barrier_levels :: proc(c: ^Command_List, t: ^Vk_Texture, access: Access, first, count: u32) {
	for at := first; at < first + count; {
		run := at + 1
		for run < first + count && t.levels[run] == t.levels[at] {run += 1}
		level := vk_barrier_level(c, t, t.levels[at], access, at, run - at)
		for &l in t.levels[at:run] {l = level}
		at = run
	}
}

// The barrier a run of mips in state `level` needs for an access, and their state after it.
@(private)
vk_barrier_level :: proc(c: ^Command_List, t: ^Vk_Texture, level: Vk_Level, access: Access, first, count: u32) -> Vk_Level {
	level := level
	d := c.device
	new_layout := vk_layout_for(t, level.layout, access)
	layout_change := new_layout != level.layout
	if !layout_change {
		if access_is_write(access) {
			if level.write == .None && level.reads == {} {level.write = access; return level}
		} else {
			if access in level.reads || level.write == .None {level.reads += {access}; return level}
		}
	}
	assert(!c.in_render_pass, "rhi: texture transitions must be recorded outside render passes")
	// Barriers of one batch are not ordered among themselves: a second one
	// of the same mips waits for the first in a batch of its own.
	for pending in c.image_barriers[:c.image_count] {
		r := pending.subresourceRange
		if pending.image == t.image && r.baseMipLevel < first + count && first < r.baseMipLevel + r.levelCount {vk_flush_barriers(c); break}
	}
	src := vk_source_info(d, level.write, level.reads if access_is_write(access) || layout_change else {})
	dst := vk_access_info(d, access)
	if c.image_count == MAX_PENDING_IMAGE_BARRIERS {vk_flush_barriers(c)}
	c.image_barriers[c.image_count] = {
		sType = .IMAGE_MEMORY_BARRIER_2,
		// First use (UNDEFINED, e.g. a freshly acquired swapchain image) chains
		// with the acquire semaphore wait, which covers ALL_COMMANDS.
		srcStageMask = src.stages if src.stages != {} else {.ALL_COMMANDS},
		srcAccessMask = src.access,
		dstStageMask = dst.stages if dst.stages != {} else {.BOTTOM_OF_PIPE},
		dstAccessMask = dst.access,
		oldLayout = level.layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = t.image,
		subresourceRange = {aspectMask = t.aspect, baseMipLevel = first, levelCount = count, layerCount = max(t.desc.layers, 1)},
	}
	c.image_count += 1
	level.layout = new_layout
	if access_is_write(access) {
		level.write = access
		level.reads = {}
	} else if layout_change {
		// The layout transition is a write made visible to this reader; later
		// readers chain from this reader's stages.
		level.write = access
		level.reads = {access}
	} else {
		level.reads += {access}
	}
	return level
}

@(private)
vk_flush_barriers :: proc(c: ^Command_List) {
	if c.image_count == 0 && !c.memory_pending {return}
	info := vk.DependencyInfo{sType = .DEPENDENCY_INFO}
	if c.memory_pending {
		info.memoryBarrierCount = 1
		info.pMemoryBarriers = &c.memory_barrier
	}
	if c.image_count > 0 {
		info.imageMemoryBarrierCount = u32(c.image_count)
		info.pImageMemoryBarriers = &c.image_barriers[0]
	}
	c.device.dvk.CmdPipelineBarrier2(c.cmd, &info)
	c.image_count = 0
	c.memory_pending = false
}

// ---------------------------------------------------------------- render passes

cmd_begin_render_pass :: proc(c: ^Command_List, desc: ^Render_Pass_Desc) {
	d := c.device
	assert(!c.in_render_pass, "rhi: nested render pass")
	c.in_render_pass = true
	c.pass = desc^
	c.pass_failed = false
	c.pass_pipeline, c.pass_slots, c.pass_dirty = c.pipeline, c.slots, c.dirty
	c.command_count = 0
	c.use_count = 0
	c.dirty = true
	width, height: u32 = max(u32), max(u32)
	for i in 0 ..< desc.color_count + 1 {
		texture, mip, layer := vk_pass_target(desc, i)
		if i == desc.color_count && texture == 0 {break}
		size: [2]u32
		inside: bool
		if t := pool_get(&d.textures, base.Handle(texture)); t != nil {size, inside = attachment_extent(t.desc, mip, layer)}
		if !inside {
			set_error(d, "render pass %s: its %s target is not a texture or has no mip %d or layer %d", desc.name, "depth" if i == desc.color_count else "color", mip, layer)
			c.pass_failed = true
			return
		}
		width = min(width, size.x)
		height = min(height, size.y)
	}
	if width == max(u32) {width, height = 1, 1}
	c.pass_extent = {width, height}
}

cmd_end_render_pass :: proc(c: ^Command_List) {
	if !c.in_render_pass {return}
	d := c.device
	c.in_render_pass = false
	// A pass that does not go out leaves the bindings as they were before it.
	defer if c.pass_failed {c.pipeline, c.slots, c.dirty = c.pass_pipeline, c.pass_slots, c.pass_dirty}
	if c.pass_failed {return}
	desc := &c.pass
	for u in c.uses[:c.use_count] {
		if u.texture != 0 {
			for i in 0 ..< desc.color_count + 1 {
				texture, mip, _ := vk_pass_target(desc, i)
				if u.texture == texture && (u.mip < 0 || u32(u.mip) == mip) {
					set_error(d, "render pass %s reads in a shader mip %d of its target %d, which it draws into; a pass reads the other mips of a target or what earlier passes wrote", desc.name, mip, i)
					c.pass_failed = true
					return
				}
			}
		}
		// A resource the pass writes takes one barrier, which covers its reads
		// in the pass and makes what it leaves visible to the readers after it.
		if .Shader_Write in u.access {
			if u.texture != 0 {cmd_barrier_texture(c, u.texture, .Shader_Write, u.mip)} else {cmd_barrier_buffer(c, u.buffer, .Shader_Write)}
			continue
		}
		for access in u.access {
			if u.texture != 0 {cmd_barrier_texture(c, u.texture, access, u.mip)} else {cmd_barrier_buffer(c, u.buffer, access)}
		}
	}
	colors: [MAX_COLOR_TARGETS]vk.RenderingAttachmentInfo
	for i in 0 ..< desc.color_count {
		a := desc.colors[i]
		cmd_barrier_texture(c, a.texture, .Color_Target, i32(a.mip))
		t := pool_get(&d.textures, base.Handle(a.texture))
		colors[i] = {
			sType = .RENDERING_ATTACHMENT_INFO, imageView = vk_target_view(t, a.mip, a.layer), imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp = .CLEAR if a.load == .Clear else (.LOAD if a.load == .Load else .DONT_CARE),
			storeOp = .STORE if a.store == .Store else .DONT_CARE,
		}
		if format_is_uint(t.desc.format) {colors[i].clearValue.color.uint32 = a.clear_uint} else {colors[i].clearValue.color.float32 = a.clear}
	}
	depth_info: vk.RenderingAttachmentInfo
	has_depth := desc.depth.texture != 0
	if has_depth {
		cmd_barrier_texture(c, desc.depth.texture, .Depth_Target, i32(desc.depth.mip))
		t := pool_get(&d.textures, base.Handle(desc.depth.texture))
		depth_info = {
			sType = .RENDERING_ATTACHMENT_INFO, imageView = vk_target_view(t, desc.depth.mip, desc.depth.layer), imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			loadOp = .CLEAR if desc.depth.load == .Clear else (.LOAD if desc.depth.load == .Load else .DONT_CARE),
			storeOp = .STORE if desc.depth.store == .Store else .DONT_CARE,
		}
		depth_info.clearValue.depthStencil.depth = desc.depth.clear
	}
	vk_flush_barriers(c)
	info := vk.RenderingInfo{
		sType = .RENDERING_INFO,
		renderArea = {extent = {c.pass_extent.x, c.pass_extent.y}},
		layerCount = 1,
		colorAttachmentCount = u32(desc.color_count),
		pColorAttachments = &colors[0],
		pDepthAttachment = &depth_info if has_depth else nil,
	}
	if desc.name != "" {vk_label_push(c, desc.name)}
	d.dvk.CmdBeginRendering(c.cmd, &info)
	vk_viewport(c, 0, 0, f32(c.pass_extent.x), f32(c.pass_extent.y))
	vk_scissor(c, 0, 0, c.pass_extent.x, c.pass_extent.y)
	c.pipeline, c.slots, c.dirty = c.pass_pipeline, c.pass_slots, true
	for &command in c.commands[:c.command_count] {
		switch command.kind {
		case .Pipeline:
			c.pipeline = command.pipeline
			if p := pool_get(&d.pipelines, base.Handle(command.pipeline)); p != nil {
				vk_pipeline_bind(c, p)
				vk_mark(c, .Pipeline, p.name)
			}
			c.dirty = true
		case .Slot:
			c.slots[command.slot] = command.binding
			c.dirty = true
		case .Index:
			if b := pool_get(&d.buffers, base.Handle(command.draw.buffer)); b != nil {d.dvk.CmdBindIndexBuffer(c.cmd, b.handle, vk.DeviceSize(command.draw.offset), .UINT32)}
		case .Viewport:
			vk_viewport(c, command.rect.x, command.rect.y, command.rect.z, command.rect.w)
		case .Scissor:
			r := transmute([4]u32)command.rect
			vk_scissor(c, i32(r.x), i32(r.y), r.z, r.w)
		case .Draw:
			v := command.draw.values
			if !vk_flush_bindings(c, .GRAPHICS) {continue}
			d.dvk.CmdDraw(c.cmd, v.x, v.y, v.z, v.w)
			vk_mark(c, .Draw)
		case .Draw_Indirect, .Draw_Indexed_Indirect:
			b := pool_get(&d.buffers, base.Handle(command.draw.buffer))
			if b == nil || !vk_flush_bindings(c, .GRAPHICS) {continue}
			offset, count, stride := vk.DeviceSize(command.draw.offset), command.draw.values.x, command.draw.values.y
			if command.kind == .Draw_Indirect {d.dvk.CmdDrawIndirect(c.cmd, b.handle, offset, count, stride)} else {d.dvk.CmdDrawIndexedIndirect(c.cmd, b.handle, offset, count, stride)}
			vk_mark(c, .Draw)
		case .Push_Label: vk_label_push(c, command.name)
		case .Pop_Label:  vk_label_pop(c)
		case .Timestamp:  vk_section(c, command.name)
		}
	}
	d.dvk.CmdEndRendering(c.cmd)
	if desc.name != "" {vk_label_pop(c)}
}

// Target i of a pass: its colors, then its depth.
@(private)
vk_pass_target :: proc(desc: ^Render_Pass_Desc, i: int) -> (texture: Texture, mip, layer: u32) {
	if i < desc.color_count {a := desc.colors[i]; return a.texture, a.mip, a.layer}
	return desc.depth.texture, desc.depth.mip, desc.depth.layer
}

// The view of one mip of one layer that a pass draws into.
@(private)
vk_target_view :: proc(t: ^Vk_Texture, mip, layer: u32) -> vk.ImageView {
	if t.layer_views != nil {return t.layer_views[mip * t.desc.layers + layer]}
	return t.mip_views[mip] if t.desc.mip_levels > 1 else t.view
}

@(private)
vk_pass_record :: proc(c: ^Command_List, command: Pass_Command) {
	if c.pass_failed {return}
	if c.command_count == len(c.commands) {
		set_error(c.device, "render pass %s records more than %d commands; split it into several passes", c.pass.name, len(c.commands))
		c.pass_failed = true
		return
	}
	c.commands[c.command_count] = command
	c.command_count += 1
}

// Adds an access of a resource to those of the pass being recorded; two mips
// of one texture count as all of them.
@(private)
vk_pass_use :: proc(c: ^Command_List, texture: Texture, buffer: Buffer, access: Access, mip: i32 = -1) {
	for &u in c.uses[:c.use_count] {
		if u.texture == texture && u.buffer == buffer {
			u.access += {access}
			if u.mip != mip {u.mip = -1}
			return
		}
	}
	if c.use_count == PASS_RESOURCE_CAPACITY {
		set_error(c.device, "render pass %s uses more than %d resources; split it into several passes", c.pass.name, PASS_RESOURCE_CAPACITY)
		c.pass_failed = true
		return
	}
	c.uses[c.use_count] = {texture, buffer, mip, {access}}
	c.use_count += 1
}

// What a draw of the pass being recorded reads and writes through the slots of
// its pipeline. False when it cannot be drawn.
@(private)
vk_pass_draw :: proc(c: ^Command_List) -> bool {
	if c.pass_failed {return false}
	d := c.device
	p := pool_get(&d.pipelines, base.Handle(c.pipeline))
	if p == nil {set_error(d, "draw without a pipeline in render pass %s", c.pass.name); return false}
	if p.bind_point != .GRAPHICS {set_error(d, "pipeline %s cannot be used inside a render pass", p.name); return false}
	if !c.dirty {return true}
	c.dirty = false
	for slot, i in p.slots {
		if !slot.used || !c.slots[i].set {continue}
		s := c.slots[i]
		switch slot.kind {
		case .Uniform_Buffer, .Storage_Buffer: vk_pass_use(c, 0, s.buffer, .Shader_Read)
		case .Storage_Buffer_RW:               vk_pass_use(c, 0, s.buffer, .Shader_Write)
		case .Sampled_Texture:                 vk_pass_use(c, s.texture, 0, .Shader_Read, s.mip)
		case .Storage_Texture:                 vk_pass_use(c, s.texture, 0, .Shader_Write, s.mip)
		case .Sampler, .Texture_Table:
		case .Accel:
			if a := pool_get(&d.accels, base.Handle(s.accel)); a != nil {vk_pass_use(c, 0, a.buffer, .Accel_Read)}
		}
	}
	return !c.pass_failed
}

// Viewport in pixels with a Y-up NDC (negative height), matching Metal.
cmd_set_viewport :: proc(c: ^Command_List, x, y, width, height: f32) {
	if c.in_render_pass {vk_pass_record(c, {kind = .Viewport, rect = {x, y, width, height}})} else {vk_viewport(c, x, y, width, height)}
}

@(private)
vk_viewport :: proc(c: ^Command_List, x, y, width, height: f32) {
	viewport := vk.Viewport{x = x, y = y + height, width = width, height = -height, minDepth = 0, maxDepth = 1}
	c.device.dvk.CmdSetViewport(c.cmd, 0, 1, &viewport)
}

cmd_set_scissor :: proc(c: ^Command_List, x, y: i32, width, height: u32) {
	if c.in_render_pass {vk_pass_record(c, {kind = .Scissor, rect = transmute([4]f32)[4]u32{u32(max(x, 0)), u32(max(y, 0)), width, height}})} else {vk_scissor(c, x, y, width, height)}
}

@(private)
vk_scissor :: proc(c: ^Command_List, x, y: i32, width, height: u32) {
	scissor := vk.Rect2D{offset = {max(x, 0), max(y, 0)}, extent = {width, height}}
	c.device.dvk.CmdSetScissor(c.cmd, 0, 1, &scissor)
}

// ---------------------------------------------------------------- bindings

cmd_bind_pipeline :: proc(c: ^Command_List, pipeline: Pipeline) {
	p := pool_get(&c.device.pipelines, base.Handle(pipeline))
	if p == nil {set_error(c.device, "bind of an invalid pipeline")}
	bound := pipeline if p != nil else 0
	if c.pipeline == bound {return}
	c.pipeline = bound
	c.dirty = true
	if c.in_render_pass {vk_pass_record(c, {kind = .Pipeline, pipeline = bound})} else if p != nil {
		vk_pipeline_bind(c, p)
		vk_mark(c, .Pipeline, p.name)
	}
}

@(private)
vk_pipeline_bind :: proc(c: ^Command_List, p: ^Vk_Pipeline) {
	c.device.dvk.CmdBindPipeline(c.cmd, p.bind_point, p.handle)
	if p.uses_table {c.device.dvk.CmdBindDescriptorSets(c.cmd, p.bind_point, p.layout, 1, 1, &c.device.table_sets[table_copy(c.immediate, c.device.slot)], 0, nil)}
}

// A binding of the slot changed: a pass being recorded replays it.
@(private)
vk_slot_set :: proc(c: ^Command_List, slot: u32, binding: Slot_Binding) {
	c.slots[slot] = binding
	c.dirty = true
	if c.in_render_pass {vk_pass_record(c, {kind = .Slot, slot = slot, binding = binding})}
}

cmd_bind_buffer :: proc(c: ^Command_List, slot: u32, buffer: Buffer, offset: u64 = 0, size: u64 = 0) {
	b := pool_get(&c.device.buffers, base.Handle(buffer))
	if b == nil || !binding_slot_valid(slot, .Storage_Buffer) {set_error(c.device, "invalid buffer binding at slot %d", slot); return}
	range := size if size > 0 else b.size - offset
	vk_slot_set(c, slot, {set = true, buffer = buffer, offset = offset, range = range})
}

cmd_bind_transient :: proc(c: ^Command_List, slot: u32, t: Transient) {
	cmd_bind_buffer(c, slot, t.buffer, t.offset, t.size)
}

// Copies small per-dispatch parameters into the frame ring and binds them as a
// uniform buffer at slot.
cmd_set_constants :: proc(c: ^Command_List, slot: u32, data: rawptr, size: int) -> bool {
	t: Transient
	if c.immediate {
		set_error(c.device, "constants are only available inside frames")
		return false
	}
	t = frame_alloc(c.device, u64(size), 256)
	if t.ptr == nil {
		// Never let the next draw/dispatch run with a previous pass's parameters.
		if slot < MAX_BINDING_SLOTS {vk_slot_set(c, slot, {})}
		return false
	}
	(cast([^]u8)t.ptr)[0] = 0
	copy_bytes(t.ptr, data, size)
	cmd_bind_transient(c, slot, t)
	return true
}

@(private)
copy_bytes :: proc "contextless" (dst, src: rawptr, size: int) {
	d := cast([^]u8)dst
	s := cast([^]u8)src
	for i in 0 ..< size {d[i] = s[i]}
}

cmd_bind_texture :: proc(c: ^Command_List, slot: u32, texture: Texture, mip: i32 = -1) {
	t := pool_get(&c.device.textures, base.Handle(texture))
	if t == nil || slot >= MAX_BINDING_SLOTS {set_error(c.device, "invalid texture binding at slot %d", slot); return}
	if mip >= 0 && u32(mip) >= t.desc.mip_levels {set_error(c.device, "texture binding at slot %d: mip %d out of range", slot, mip); vk_slot_set(c, slot, {}); return}
	vk_slot_set(c, slot, {set = true, texture = texture, mip = mip})
}

cmd_bind_sampler :: proc(c: ^Command_List, slot: u32, sampler: Sampler) {
	if pool_get(&c.device.samplers, base.Handle(sampler)) == nil || !binding_slot_valid(slot, .Sampler) {set_error(c.device, "invalid sampler binding at slot %d", slot); return}
	vk_slot_set(c, slot, {set = true, sampler = sampler})
}

cmd_bind_accel :: proc(c: ^Command_List, slot: u32, accel: Accel) {
	if pool_get(&c.device.accels, base.Handle(accel)) == nil || !binding_slot_valid(slot, .Accel) {set_error(c.device, "invalid acceleration structure binding at slot %d", slot); return}
	vk_slot_set(c, slot, {set = true, accel = accel})
}

// Transitions every resource bound to the current compute pipeline to the
// access its binding kind implies.
@(private)
vk_auto_transitions :: proc(c: ^Command_List) {
	p := pool_get(&c.device.pipelines, base.Handle(c.pipeline)) // by handle: the pool may grow while bound
	d := c.device
	for slot, i in p.slots {
		if !slot.used || !c.slots[i].set {continue}
		s := c.slots[i]
		switch slot.kind {
		case .Uniform_Buffer, .Storage_Buffer: cmd_barrier_buffer(c, s.buffer, .Shader_Read)
		case .Storage_Buffer_RW:               cmd_barrier_buffer(c, s.buffer, .Shader_Write)
		case .Sampled_Texture:                 cmd_barrier_texture(c, s.texture, .Shader_Read, s.mip)
		case .Storage_Texture:                 cmd_barrier_texture(c, s.texture, .Shader_Write, s.mip)
		case .Sampler, .Texture_Table:
		case .Accel:
			if a := pool_get(&d.accels, base.Handle(s.accel)); a != nil {cmd_barrier_buffer(c, a.buffer, .Accel_Read)}
		}
	}
}

@(private)
vk_flush_bindings :: proc(c: ^Command_List, bind_point: vk.PipelineBindPoint) -> bool {
	p := pool_get(&c.device.pipelines, base.Handle(c.pipeline)) // by handle: the pool may grow while bound
	d := c.device
	if p == nil {set_error(d, "draw or dispatch without a pipeline"); return false}
	if p.bind_point != bind_point {
		set_error(d, "pipeline %s cannot be used %s a render pass", p.name, "outside" if p.bind_point == .GRAPHICS else "inside")
		return false
	}
	if bind_point == .COMPUTE {
		vk_auto_transitions(c)
		vk_flush_barriers(c)
	}
	if !c.dirty {return true}
	writes: [MAX_BINDING_SLOTS]vk.WriteDescriptorSet
	buffers: [MAX_BINDING_SLOTS]vk.DescriptorBufferInfo
	images: [MAX_BINDING_SLOTS]vk.DescriptorImageInfo
	accels: [MAX_BINDING_SLOTS]vk.WriteDescriptorSetAccelerationStructureKHR
	accel_handles: [MAX_BINDING_SLOTS]vk.AccelerationStructureKHR
	count: u32
	for slot, i in p.slots {
		if !slot.used {continue}
		s := c.slots[i]
		if !s.set {set_error(d, "pipeline %s: slot %d is not bound", p.name, i); return false}
		w := vk.WriteDescriptorSet{sType = .WRITE_DESCRIPTOR_SET, dstBinding = u32(i), descriptorCount = 1, descriptorType = vk_descriptor_type(slot.kind)}
		switch slot.kind {
		case .Uniform_Buffer, .Storage_Buffer, .Storage_Buffer_RW:
			b := pool_get(&d.buffers, base.Handle(s.buffer))
			if b == nil {set_error(d, "pipeline %s: slot %d buffer was destroyed", p.name, i); return false}
			limits := &d.properties.limits
			uniform := slot.kind == .Uniform_Buffer
			max_range := u64(limits.maxUniformBufferRange if uniform else limits.maxStorageBufferRange)
			alignment := u64(limits.minUniformBufferOffsetAlignment if uniform else limits.minStorageBufferOffsetAlignment)
			if s.range > max_range || (alignment > 0 && s.offset % alignment != 0) {
				set_error(d, "pipeline %s: slot %d binds %d bytes at offset %d (device limit %d, alignment %d)", p.name, i, s.range, s.offset, max_range, alignment)
				return false
			}
			buffers[i] = {buffer = b.handle, offset = vk.DeviceSize(s.offset), range = vk.DeviceSize(s.range)}
			w.pBufferInfo = &buffers[i]
		case .Sampled_Texture, .Storage_Texture:
			t := pool_get(&d.textures, base.Handle(s.texture))
			if t == nil {set_error(d, "pipeline %s: slot %d holds no texture: it was destroyed or a buffer is bound there", p.name, i); return false}
			view := t.view
			if s.mip >= 0 && t.desc.mip_levels > 1 {view = t.mip_views[s.mip]}
			layout := t.levels[max(s.mip, 0)].layout
			if slot.kind == .Storage_Texture {layout = .GENERAL}
			if layout != .GENERAL && layout != .SHADER_READ_ONLY_OPTIMAL && layout != .DEPTH_READ_ONLY_OPTIMAL {
				set_error(d, "pipeline %s: slot %d texture is not readable (missing barrier before the pass)", p.name, i)
				return false
			}
			images[i] = {imageView = view, imageLayout = layout}
			w.pImageInfo = &images[i]
		case .Sampler:
			sampler := pool_get(&d.samplers, base.Handle(s.sampler))
			if sampler == nil {set_error(d, "pipeline %s: slot %d sampler was destroyed", p.name, i); return false}
			images[i] = {sampler = sampler^}
			w.pImageInfo = &images[i]
		case .Accel:
			a := pool_get(&d.accels, base.Handle(s.accel))
			if a == nil {set_error(d, "pipeline %s: slot %d acceleration structure was destroyed", p.name, i); return false}
			if !a.built {set_error(d, "pipeline %s: slot %d acceleration structure was never built successfully", p.name, i); return false}
			accel_handles[i] = a.handle
			accels[i] = {sType = .WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR, accelerationStructureCount = 1, pAccelerationStructures = &accel_handles[i]}
			w.pNext = &accels[i]
		case .Texture_Table:
		}
		writes[count] = w
		count += 1
	}
	if count > 0 {c.device.dvk.CmdPushDescriptorSetKHR(c.cmd, p.bind_point, p.layout, 0, count, &writes[0])}
	c.dirty = false
	return true
}

// ---------------------------------------------------------------- draws and dispatches

cmd_bind_index_buffer :: proc(c: ^Command_List, buffer: Buffer, offset: u64 = 0) {
	b := pool_get(&c.device.buffers, base.Handle(buffer))
	if b == nil {return}
	c.index_buffer = buffer
	if c.in_render_pass {vk_pass_record(c, {kind = .Index, draw = {buffer = buffer, offset = offset}})} else {c.device.dvk.CmdBindIndexBuffer(c.cmd, b.handle, vk.DeviceSize(offset), .UINT32)}
}

cmd_draw :: proc(c: ^Command_List, vertex_count: u32, instance_count: u32 = 1, first_vertex: u32 = 0, first_instance: u32 = 0) {
	assert(c.in_render_pass)
	if !vk_pass_draw(c) {return}
	vk_pass_record(c, {kind = .Draw, draw = {values = {vertex_count, instance_count, first_vertex, first_instance}}})
}

cmd_draw_indexed_indirect :: proc(c: ^Command_List, buffer: Buffer, offset: u64, draw_count: u32, stride: u32 = size_of(Draw_Indexed_Indirect)) {
	assert(c.in_render_pass)
	if pool_get(&c.device.buffers, base.Handle(buffer)) == nil || draw_count == 0 {return}
	if pool_get(&c.device.buffers, base.Handle(c.index_buffer)) == nil {set_error(c.device, "indexed draw in render pass %s without an index buffer", c.pass.name); return}
	if !vk_pass_draw(c) {return}
	vk_pass_use(c, 0, c.index_buffer, .Index_Read)
	vk_pass_use(c, 0, buffer, .Indirect_Read)
	vk_pass_record(c, {kind = .Draw_Indexed_Indirect, draw = {buffer = buffer, offset = offset, values = {draw_count, stride, 0, 0}}})
}

// Draws whose arguments (Draw_Indirect) the GPU wrote.
cmd_draw_indirect :: proc(c: ^Command_List, buffer: Buffer, offset: u64, draw_count: u32, stride: u32 = size_of(Draw_Indirect)) {
	assert(c.in_render_pass)
	if pool_get(&c.device.buffers, base.Handle(buffer)) == nil || draw_count == 0 {return}
	if !vk_pass_draw(c) {return}
	vk_pass_use(c, 0, buffer, .Indirect_Read)
	vk_pass_record(c, {kind = .Draw_Indirect, draw = {buffer = buffer, offset = offset, values = {draw_count, stride, 0, 0}}})
}

cmd_dispatch :: proc(c: ^Command_List, x: u32, y: u32 = 1, z: u32 = 1) {
	assert(!c.in_render_pass, "rhi: dispatch inside a render pass")
	if x == 0 || y == 0 || z == 0 {return}
	if !vk_flush_bindings(c, .COMPUTE) {return}
	c.device.dvk.CmdDispatch(c.cmd, x, y, z)
}

cmd_dispatch_indirect :: proc(c: ^Command_List, buffer: Buffer, offset: u64) {
	assert(!c.in_render_pass)
	cmd_barrier_buffer(c, buffer, .Indirect_Read)
	b := pool_get(&c.device.buffers, base.Handle(buffer))
	if b == nil {return}
	if !vk_flush_bindings(c, .COMPUTE) {return}
	c.device.dvk.CmdDispatchIndirect(c.cmd, b.handle, vk.DeviceSize(offset))
}

// ---------------------------------------------------------------- copies

cmd_copy_buffer :: proc(c: ^Command_List, src: Buffer, src_offset: u64, dst: Buffer, dst_offset: u64, size: u64) {
	assert(!c.in_render_pass)
	d := c.device
	s := pool_get(&d.buffers, base.Handle(src))
	t := pool_get(&d.buffers, base.Handle(dst))
	if s == nil || t == nil || size == 0 {return}
	cmd_barrier_buffer(c, src, .Transfer_Read)
	cmd_barrier_buffer(c, dst, .Transfer_Write)
	vk_flush_barriers(c)
	region := vk.BufferCopy{srcOffset = vk.DeviceSize(src_offset), dstOffset = vk.DeviceSize(dst_offset), size = vk.DeviceSize(size)}
	c.device.dvk.CmdCopyBuffer(c.cmd, s.handle, t.handle, 1, &region)
}

// Sets every byte of the range to value, as Metal does: Vulkan fills words,
// so the byte goes into all four of each. Words of other values are written
// with buffer_upload or from a shader.
cmd_fill_buffer :: proc(c: ^Command_List, buffer: Buffer, offset: u64, size: u64, value: u8) {
	assert(!c.in_render_pass)
	b := pool_get(&c.device.buffers, base.Handle(buffer))
	if b == nil || size == 0 {return}
	if offset % 4 != 0 || size % 4 != 0 {set_error(c.device, "cmd_fill_buffer needs 4-byte aligned offset and size"); return}
	cmd_barrier_buffer(c, buffer, .Transfer_Write)
	vk_flush_barriers(c)
	c.device.dvk.CmdFillBuffer(c.cmd, b.handle, vk.DeviceSize(offset), vk.DeviceSize(size), u32(value) * 0x01010101)
}

// Copies tightly packed rows from a buffer into one mip of a texture, layer
// after layer.
cmd_copy_buffer_to_texture :: proc(c: ^Command_List, src: Buffer, src_offset: u64, dst: Texture, mip: u32 = 0, region := Texture_Region{}) {
	assert(!c.in_render_pass)
	d := c.device
	b := pool_get(&d.buffers, base.Handle(src))
	t := pool_get(&d.textures, base.Handle(dst))
	if b == nil || t == nil || mip >= t.desc.mip_levels {return}
	area, inside := texture_region_resolve(t.desc, mip, region)
	if !inside {return}
	cmd_barrier_buffer(c, src, .Transfer_Read)
	vk_barrier_levels(c, t, .Transfer_Write, mip, 1)
	vk_flush_barriers(c)
	region := vk.BufferImageCopy{
		bufferOffset = vk.DeviceSize(src_offset),
		imageSubresource = {aspectMask = t.aspect, mipLevel = mip, layerCount = max(t.desc.layers, 1)},
		imageOffset = {i32(area.x), i32(area.y), 0},
		imageExtent = {area.width, area.height, 1},
	}
	c.device.dvk.CmdCopyBufferToImage(c.cmd, b.handle, t.image, .TRANSFER_DST_OPTIMAL, 1, &region)
}

// Copies mip 0 into a buffer as tightly packed rows, slice after slice of a 3D texture.
cmd_copy_texture_to_buffer :: proc(c: ^Command_List, src: Texture, dst: Buffer, dst_offset: u64) {
	assert(!c.in_render_pass)
	d := c.device
	t := pool_get(&d.textures, base.Handle(src))
	b := pool_get(&d.buffers, base.Handle(dst))
	if b == nil || t == nil {return}
	vk_barrier_levels(c, t, .Transfer_Read, 0, 1)
	cmd_barrier_buffer(c, dst, .Transfer_Write)
	vk_flush_barriers(c)
	region := vk.BufferImageCopy{
		bufferOffset = vk.DeviceSize(dst_offset),
		imageSubresource = {aspectMask = t.aspect, mipLevel = 0, layerCount = 1},
		imageExtent = {t.desc.width, t.desc.height, max(t.desc.depth, 1)},
	}
	c.device.dvk.CmdCopyImageToBuffer(c.cmd, t.image, .TRANSFER_SRC_OPTIMAL, b.handle, 1, &region)
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
	if s == nil || t == nil {return}
	if src == dst || s.swapchain || t.swapchain {set_error(d, "cmd_copy_texture: it copies between two textures of the device, not the image of the swapchain"); return}
	if problem := texture_copy_problem(s.desc, t.desc, src_mip, dst_mip, mips); problem != "" {set_error(d, "cmd_copy_texture: %s", problem); return}
	vk_barrier_levels(c, s, .Transfer_Read, src_mip, mips)
	vk_barrier_levels(c, t, .Transfer_Write, dst_mip, mips)
	vk_flush_barriers(c)
	regions: [MAX_TEXTURE_MIPS]vk.ImageCopy
	for &region, k in regions[:mips] {
		from := vk.ImageSubresourceLayers{aspectMask = s.aspect, mipLevel = src_mip + u32(k), layerCount = max(s.desc.layers, 1)}
		to := from
		to.mipLevel = dst_mip + u32(k)
		region = {srcSubresource = from, dstSubresource = to, extent = {max(s.desc.width >> from.mipLevel, 1), max(s.desc.height >> from.mipLevel, 1), 1}}
	}
	d.dvk.CmdCopyImage(c.cmd, s.image, .TRANSFER_SRC_OPTIMAL, t.image, .TRANSFER_DST_OPTIMAL, mips, &regions[0])
}

// ---------------------------------------------------------------- debugging and timing

cmd_push_label :: proc(c: ^Command_List, name: string) {
	if c.in_render_pass {vk_pass_record(c, {kind = .Push_Label, name = name})} else {vk_label_push(c, name)}
}

cmd_pop_label :: proc(c: ^Command_List) {
	if c.in_render_pass {vk_pass_record(c, {kind = .Pop_Label})} else {vk_label_pop(c)}
}

@(private)
vk_label_push :: proc(c: ^Command_List, name: string) {
	vk_mark(c, .Push, name)
	if !c.device.debug_utils || c.device.dvk.CmdBeginDebugUtilsLabelEXT == nil {return}
	label := vk.DebugUtilsLabelEXT{sType = .DEBUG_UTILS_LABEL_EXT, pLabelName = strings.clone_to_cstring(name, context.temp_allocator)}
	c.device.dvk.CmdBeginDebugUtilsLabelEXT(c.cmd, &label)
}

@(private)
vk_label_pop :: proc(c: ^Command_List) {
	vk_mark(c, .Pop)
	if !c.device.debug_utils || c.device.dvk.CmdEndDebugUtilsLabelEXT == nil {return}
	c.device.dvk.CmdEndDebugUtilsLabelEXT(c.cmd)
}

// Records a GPU timestamp in a frame that wants timings. The interval until
// the next timestamp is reported under this name by frame_timings once the
// frame slot completes. It names where the GPU is too, for a loss.
cmd_timestamp :: proc(c: ^Command_List, name: string) {
	if c.immediate {return}
	if c.in_render_pass {vk_pass_record(c, {kind = .Timestamp, name = name})} else {vk_section(c, name)}
}

@(private)
vk_section :: proc(c: ^Command_List, name: string) {
	f := &c.device.frames[c.device.slot]
	vk_mark(c, .Section, name)
	if f.passes {vk_timestamp_write(f, name)}
}

@(private)
vk_timestamp_write :: proc(f: ^Vk_Frame, name: string) {
	if f.queries == 0 || f.query_count >= MAX_TIMESTAMPS {return}
	f.list.device.dvk.CmdWriteTimestamp2(f.cmd, {.ALL_COMMANDS}, f.queries, f.query_count)
	f.query_names[f.query_count] = string(f.query_bytes[f.query_count][:copy(f.query_bytes[f.query_count][:], name)])
	f.query_count += 1
}
