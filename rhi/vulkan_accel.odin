#+build linux, windows
package rhi

import "mirai:std/base"
import vk "vendor:vulkan"

// Mirrors VkAccelerationStructureInstanceKHR without bit-field helpers.
@(private)
Vk_As_Instance :: struct {
	transform:   [3][4]f32,
	custom_mask: u32, // custom index (24 bits) | mask << 24
	sbt_flags:   u32, // SBT offset (24 bits) | flags << 24
	reference:   u64,
}
#assert(size_of(Vk_As_Instance) == 64)

@(private)
VK_INSTANCE_CULL_DISABLE :: 0x1
@(private)
VK_INSTANCE_FORCE_OPAQUE :: 0x4
VK_INSTANCE_FORCE_NO_OPAQUE :: 0x8

@(private)
vk_blas_geometry :: proc(vb, ib: ^Vk_Buffer, desc: Blas_Desc) -> vk.AccelerationStructureGeometryKHR {
	triangles := vk.AccelerationStructureGeometryTrianglesDataKHR{
		sType = .ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR,
		vertexFormat = .R32G32B32_SFLOAT,
		vertexStride = vk.DeviceSize(desc.vertex_stride),
		maxVertex = max(desc.vertex_count, 1) - 1,
		indexType = .UINT32,
	}
	triangles.vertexData.deviceAddress = vk.DeviceAddress(vb.address + desc.vertex_offset)
	triangles.indexData.deviceAddress = vk.DeviceAddress(ib.address + desc.index_offset)
	// A ray query that collects the filters of blended triangles needs each
	// candidate reported once.
	geometry := vk.AccelerationStructureGeometryKHR{sType = .ACCELERATION_STRUCTURE_GEOMETRY_KHR, geometryType = .TRIANGLES, flags = {.OPAQUE, .NO_DUPLICATE_ANY_HIT_INVOCATION}}
	geometry.geometry.triangles = triangles
	return geometry
}

@(private)
vk_tlas_geometry :: proc(address: u64) -> vk.AccelerationStructureGeometryKHR {
	geometry := vk.AccelerationStructureGeometryKHR{sType = .ACCELERATION_STRUCTURE_GEOMETRY_KHR, geometryType = .INSTANCES, flags = {.OPAQUE}}
	geometry.geometry.instances = {sType = .ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR, arrayOfPointers = false}
	geometry.geometry.instances.data.deviceAddress = vk.DeviceAddress(address)
	return geometry
}

// A range of the arena for a structure of size bytes, in a block that has
// room or a new one; the blocks deletions left empty go first.
@(private)
vk_accel_range :: proc(d: ^Device, size: u64) -> (buffer: Buffer, block: int, offset: u64, ok: bool) {
	for empty in d.accel_empty {
		if empty >= len(d.accel_arena.blocks) || d.accel_arena.blocks[empty].size == 0 || d.accel_arena.blocks[empty].used > 0 {continue}
		buffer_destroy(d, d.accel_blocks[empty])
		d.accel_blocks[empty] = 0
		arena_drop(&d.accel_arena, empty)
	}
	clear(&d.accel_empty)
	if d.accel_arena.allocator.procedure == nil {
		d.accel_arena.allocator = d.allocator
		d.accel_blocks = make([dynamic]Buffer, d.allocator)
		d.accel_empty = make([dynamic]int, d.allocator)
	}
	block, offset, ok = arena_take(&d.accel_arena, size, ACCEL_ALIGNMENT)
	if !ok {
		bytes := accel_block_size(size)
		made := vk_create_buffer(d, {size = bytes, memory = .GPU, name = "acceleration structures"}, {.ACCELERATION_STRUCTURE_STORAGE_KHR, .SHADER_DEVICE_ADDRESS}, zero = false)
		if made == 0 {return}
		at, added := arena_add(&d.accel_arena, bytes)
		if added && len(d.accel_blocks) <= at && resize(&d.accel_blocks, at + 1) != nil {
			arena_drop(&d.accel_arena, at)
			added = false
		}
		if added {
			d.accel_blocks[at] = made
			block, offset, ok = arena_take(&d.accel_arena, size, ACCEL_ALIGNMENT)
		}
		if !ok {
			if added {
				d.accel_blocks[at] = 0
				arena_drop(&d.accel_arena, at)
			}
			buffer_destroy(d, made)
			set_error(d, "out of memory for the blocks of the acceleration structures")
			return
		}
	}
	return d.accel_blocks[block], block, offset, true
}

@(private)
vk_create_accel :: proc(d: ^Device, type: vk.AccelerationStructureTypeKHR, sizes: vk.AccelerationStructureBuildSizesInfoKHR, blas: Blas_Desc, max_instances: u32, name: string) -> Accel {
	if !device_room(d, &d.accels, "acceleration structures") {return 0}
	size := align_up(u64(sizes.accelerationStructureSize), ACCEL_ALIGNMENT)
	buffer, block, offset, ranged := vk_accel_range(d, size)
	if !ranged {return 0}
	b := pool_get(&d.buffers, base.Handle(buffer))
	info := vk.AccelerationStructureCreateInfoKHR{sType = .ACCELERATION_STRUCTURE_CREATE_INFO_KHR, buffer = b.handle, offset = vk.DeviceSize(offset), size = sizes.accelerationStructureSize, type = type}
	a := Vk_Accel{buffer = buffer, block = i32(block + 1), offset = offset, size = size, top_level = type == .TOP_LEVEL, blas = blas, max_instances = max_instances, scratch_size = u64(max(sizes.buildScratchSize,sizes.updateScratchSize))}
	if !vk_check(d, d.dvk.CreateAccelerationStructureKHR(d.handle, &info, nil, &a.handle), "vkCreateAccelerationStructureKHR") {
		if arena_give(&d.accel_arena, block, offset, size) {append(&d.accel_empty, block)}
		return 0
	}
	address_info := vk.AccelerationStructureDeviceAddressInfoKHR{sType = .ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR, accelerationStructure = a.handle}
	a.address = u64(d.dvk.GetAccelerationStructureDeviceAddressKHR(d.handle, &address_info))
	return Accel(pool_add(&d.accels, a))
}

// Allocates a bottom level structure for static triangle geometry. The build
// itself is recorded with cmd_build_blas.
blas_create :: proc(d: ^Device, desc: Blas_Desc) -> Accel {
	if !d.info.features.ray_query {set_error(d, "hardware ray tracing is not enabled"); return 0}
	vb := pool_get(&d.buffers, base.Handle(desc.vertex_buffer))
	ib := pool_get(&d.buffers, base.Handle(desc.index_buffer))
	if vb == nil || ib == nil || vb.address == 0 || ib.address == 0 || desc.triangle_count == 0 {
		set_error(d, "BLAS %s needs Accel_Input vertex and index buffers", desc.name)
		return 0
	}
	geometry := vk_blas_geometry(vb, ib, desc)
	build := vk.AccelerationStructureBuildGeometryInfoKHR{
		sType = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR, type = .BOTTOM_LEVEL,
		flags = {.PREFER_FAST_TRACE}, mode = .BUILD, geometryCount = 1, pGeometries = &geometry,
	}
	if desc.deformable {build.flags+={.ALLOW_UPDATE}} else if desc.compact {build.flags+={.ALLOW_COMPACTION}}
	sizes := vk.AccelerationStructureBuildSizesInfoKHR{sType = .ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR}
	count := desc.triangle_count
	d.dvk.GetAccelerationStructureBuildSizesKHR(d.handle, .DEVICE, &build, &count, &sizes)
	return vk_create_accel(d, .BOTTOM_LEVEL, sizes, desc, 0, desc.name)
}

tlas_create :: proc(d: ^Device, max_instances: u32, name: string = "tlas") -> Accel {
	if !d.info.features.ray_query {set_error(d, "hardware ray tracing is not enabled"); return 0}
	geometry := vk_tlas_geometry(0)
	build := vk.AccelerationStructureBuildGeometryInfoKHR{
		sType = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR, type = .TOP_LEVEL,
		flags = {.PREFER_FAST_TRACE}, mode = .BUILD, geometryCount = 1, pGeometries = &geometry,
	}
	sizes := vk.AccelerationStructureBuildSizesInfoKHR{sType = .ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR}
	count := max(max_instances, 1)
	d.dvk.GetAccelerationStructureBuildSizesKHR(d.handle, .DEVICE, &build, &count, &sizes)
	return vk_create_accel(d, .TOP_LEVEL, sizes, {}, count, name)
}

accel_destroy :: proc(d: ^Device, accel: Accel) {
	a, ok := pool_remove(&d.accels, base.Handle(accel))
	if !ok {return}
	compact_slot_give(d, a.compact_slot)
	// Its range goes back to the arena once the frames that could use it are done.
	vk_defer(d, {accel = a.handle, arena_block = a.block, arena_offset = a.offset, arena_size = a.size})
	if a.native != 0 {buffer_destroy(d, a.native)}
}

// The translation of TLAS instances (tlas_instances.comp of the shaders of
// the renderer): cmd_build_tlas runs it before each build. Between frames;
// false for a shader without its bindings.
tlas_translator_set :: proc(d: ^Device, code: ^Shader_Code) -> bool {
	if problem := tlas_translator_problem(code); problem != "" {set_error(d, "%s", problem); return false}
	pipeline := pipeline_create_compute(d, {shader = code, name = "tlas instances"})
	if pipeline == 0 {return false}
	if d.tlas_translator != 0 {pipeline_destroy(d, d.tlas_translator)}
	d.tlas_translator = pipeline
	return true
}

@(private)
vk_scratch_address :: proc(d: ^Device, size: u64) -> u64 {
	needed := size + d.scratch_alignment
	if d.scratch == 0 || d.scratch_size < needed {
		if d.scratch != 0 {buffer_destroy(d, d.scratch)}
		d.scratch = vk_create_buffer(d, {size = needed, memory = .GPU, name = "acceleration scratch"}, {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}, zero = false)
		d.scratch_size = needed if d.scratch != 0 else 0
	}
	b := pool_get(&d.buffers, base.Handle(d.scratch))
	if b == nil {return 0}
	return align_up(b.address, d.scratch_alignment)
}

// A deformable BLAS already built is refitted over its new positions unless
// rebuild asks to build it again.
cmd_build_blas :: proc(c: ^Command_List, accel: Accel, rebuild := false) {
	d := c.device
	assert(!c.in_render_pass)
	a := pool_get(&d.accels, base.Handle(accel))
	if a == nil || a.top_level {return}
	scratch := vk_scratch_address(d, a.scratch_size)
	vb := pool_get(&d.buffers, base.Handle(a.blas.vertex_buffer))
	ib := pool_get(&d.buffers, base.Handle(a.blas.index_buffer))
	if scratch == 0 || vb == nil || ib == nil {set_error(d, "BLAS build inputs are gone"); return}
	cmd_barrier_buffer(c, a.blas.vertex_buffer, .Accel_Build_Input)
	cmd_barrier_buffer(c, a.blas.index_buffer, .Accel_Build_Input)
	cmd_barrier_buffer(c, d.scratch, .Accel_Build_Write)
	cmd_barrier_buffer(c, a.buffer, .Accel_Build_Write)
	vk_flush_barriers(c)
	geometry := vk_blas_geometry(vb, ib, a.blas)
	build := vk.AccelerationStructureBuildGeometryInfoKHR{
		sType = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR, type = .BOTTOM_LEVEL,
		flags = {.PREFER_FAST_TRACE}, mode = .BUILD, geometryCount = 1, pGeometries = &geometry,
		dstAccelerationStructure = a.handle,
	}
	build.scratchData.deviceAddress = vk.DeviceAddress(scratch)
	range := vk.AccelerationStructureBuildRangeInfoKHR{primitiveCount = a.blas.triangle_count}
	if a.blas.deformable {
		build.flags+={.ALLOW_UPDATE}
		if a.built && !rebuild {build.mode=.UPDATE;build.srcAccelerationStructure=a.handle}
	} else if a.blas.compact {build.flags+={.ALLOW_COMPACTION}}
	ranges := cast([^]vk.AccelerationStructureBuildRangeInfoKHR)&range
	d.dvk.CmdBuildAccelerationStructuresKHR(c.cmd, 1, &build, &ranges)
	a.built = true
	if a.blas.compact && !a.blas.deformable {vk_compact_size_write(c, a)}
}

// The GPU writes the compacted size of a BLAS it just built into a slot of
// the table; with every slot waiting, the BLAS stays as it is.
@(private)
vk_compact_size_write :: proc(c: ^Command_List, a: ^Vk_Accel) {
	d := c.device
	if d.compact_pool == 0 {
		info := vk.QueryPoolCreateInfo{sType = .QUERY_POOL_CREATE_INFO, queryType = .ACCELERATION_STRUCTURE_COMPACTED_SIZE_KHR, queryCount = COMPACT_SLOTS}
		if d.dvk.CreateQueryPool(d.handle, &info, nil, &d.compact_pool) != .SUCCESS {d.compact_pool = 0;return}
	}
	compact_slot_give(d, a.compact_slot)
	a.compact_slot = compact_slot_take(d)
	if a.compact_slot == 0 {return}
	a.compact_frame, a.compact_immediate = d.frame_number, c.immediate
	query := u32(a.compact_slot - 1)
	d.dvk.CmdResetQueryPool(c.cmd, d.compact_pool, query, 1)
	cmd_barrier_buffer(c, a.buffer, .Accel_Build_Input)
	vk_flush_barriers(c)
	d.dvk.CmdWriteAccelerationStructuresPropertiesKHR(c.cmd, 1, &a.handle, .ACCELERATION_STRUCTURE_COMPACTED_SIZE_KHR, d.compact_pool, query)
}

// Replaces the BLASes whose compacted size the GPU gave by compacted copies,
// in a list of a frame: how many, and the bytes that leaves free. A TLAS that
// names them is to be built again after it in the same list.
cmd_compact_blases :: proc(c: ^Command_List) -> (replaced: int, freed: u64) {
	d := c.device
	if c.immediate || d.compact_pool == 0 {return}
	assert(!c.in_render_pass)
	for i in 0 ..< d.accels.used {
		if !d.accels.alive[i] {continue}
		a := &d.accels.items[i]
		if a.compact_slot == 0 || !compact_ready(d, a.compact_frame, a.compact_immediate) {continue}
		size: u64
		result := d.dvk.GetQueryPoolResults(d.handle, d.compact_pool, u32(a.compact_slot - 1), 1, size_of(size), &size, size_of(u64), {._64})
		compact_slot_give(d, a.compact_slot)
		a.compact_slot = 0
		if vk_lost(d, result, "vkGetQueryPoolResults") {return}
		if result != .SUCCESS || size == 0 || f64(size) > f64(a.size) * COMPACT_SAVING {continue}
		taken := align_up(size, ACCEL_ALIGNMENT)
		buffer, block, offset, ranged := vk_accel_range(d, taken)
		if !ranged {continue}
		b := pool_get(&d.buffers, base.Handle(buffer))
		info := vk.AccelerationStructureCreateInfoKHR{sType = .ACCELERATION_STRUCTURE_CREATE_INFO_KHR, buffer = b.handle, offset = vk.DeviceSize(offset), size = vk.DeviceSize(size), type = .BOTTOM_LEVEL}
		handle: vk.AccelerationStructureKHR
		if d.dvk.CreateAccelerationStructureKHR(d.handle, &info, nil, &handle) != .SUCCESS {
			if arena_give(&d.accel_arena, block, offset, taken) {append(&d.accel_empty, block)}
			continue
		}
		cmd_barrier_buffer(c, a.buffer, .Accel_Build_Input)
		cmd_barrier_buffer(c, buffer, .Accel_Build_Write)
		vk_flush_barriers(c)
		copy := vk.CopyAccelerationStructureInfoKHR{sType = .COPY_ACCELERATION_STRUCTURE_INFO_KHR, src = a.handle, dst = handle, mode = .COMPACT}
		d.dvk.CmdCopyAccelerationStructureKHR(c.cmd, &copy)
		vk_defer(d, {accel = a.handle, arena_block = a.block, arena_offset = a.offset, arena_size = a.size})
		freed += a.size - taken
		a.handle, a.buffer, a.block, a.offset, a.size = handle, buffer, i32(block + 1), offset, taken
		address_info := vk.AccelerationStructureDeviceAddressInfoKHR{sType = .ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR, accelerationStructure = handle}
		a.address = u64(d.dvk.GetAccelerationStructureDeviceAddressKHR(d.handle, &address_info))
		replaced += 1
	}
	return
}

// Builds a TLAS over count instances (Tlas_Instance) of a buffer from byte
// offset, which the GPU may have written earlier in the list: the
// translation makes them native in a buffer of the TLAS, which grows to
// them, and the build reads that. False, with device_error, when it records
// no build: the structure is then not to be traced.
cmd_build_tlas :: proc(c: ^Command_List, accel: Accel, instances: Buffer, offset: u64, count: u32) -> bool {
	d := c.device
	assert(!c.in_render_pass)
	a := pool_get(&d.accels, base.Handle(accel))
	if a == nil || !a.top_level {set_error(d, "cmd_build_tlas: the accel is not a live TLAS"); return false}
	// Until this build is recorded the structure must not be traced.
	a.built = false
	if count > a.max_instances {
		set_error(d, "a TLAS made for %d instances was given %d: make it again with tlas_create for as many", a.max_instances, count)
		return false
	}
	source := pool_get(&d.buffers, base.Handle(instances))
	if source == nil || offset % size_of(Tlas_Instance) != 0 || offset + u64(count) * size_of(Tlas_Instance) > source.size {
		set_error(d, "cmd_build_tlas: %d instances from byte %d are not in their buffer", count, offset)
		return false
	}
	if d.tlas_translator == 0 {set_error(d, "cmd_build_tlas: no translation of instances; give it with tlas_translator_set"); return false}
	if a.native_room < count || a.native == 0 {
		if a.native != 0 {buffer_destroy(d, a.native)}
		room := min(max(count, a.native_room + a.native_room / 2, 64), max(a.max_instances, 1))
		a.native = vk_create_buffer(d, {size = u64(room) * size_of(Vk_As_Instance), usage = {.Accel_Input, .Storage}, memory = .GPU, name = "tlas instances"}, zero = false)
		a.native_room = room if a.native != 0 else 0
		if a.native == 0 {return false}
	}
	// The table: the native value of each BLAS by id, its address once built.
	ids := d.accels.used + 1
	bytes := u64(TLAS_TABLE_HEADER + 2 * ids) * 4
	staging: Buffer
	table: Transient
	if c.immediate {
		staging = vk_create_buffer(d, {size = bytes, usage = {.Storage}, memory = .Upload, name = "tlas table"}, zero = false)
		if staging == 0 {return false}
		table = {ptr = buffer_mapped(d, staging), buffer = staging, size = bytes}
	} else {
		table = frame_alloc(d, bytes, 16)
		if table.ptr == nil {return false}
	}
	defer if staging != 0 {buffer_destroy(d, staging)}
	(cast(^Tlas_Table_Header)table.ptr)^ = {
		count = count, layout = TLAS_LAYOUT_ROWS, stride = size_of(Vk_As_Instance) / 4, first = u32(offset / size_of(Tlas_Instance)), ids = u32(ids),
		opaque = u32(VK_INSTANCE_CULL_DISABLE | VK_INSTANCE_FORCE_OPAQUE) << 24, tested = u32(VK_INSTANCE_CULL_DISABLE | VK_INSTANCE_FORCE_NO_OPAQUE) << 24,
	}
	values := (cast([^]u64)(uintptr(table.ptr) + size_of(Tlas_Table_Header)))[:ids]
	values[0] = 0
	for i in 0 ..< d.accels.used {
		blas := &d.accels.items[i]
		values[i + 1] = 0
		if !d.accels.alive[i] || blas.top_level || !blas.built {continue}
		values[i + 1] = blas.address
		cmd_barrier_buffer(c, blas.buffer, .Accel_Build_Input)
	}
	// The translation binds what it needs and gives the list back as it was.
	slots := c.slots
	pipeline := c.pipeline
	cmd_barrier_buffer(c, instances, .Shader_Read)
	cmd_barrier_buffer(c, a.native, .Shader_Write)
	cmd_bind_pipeline(c, d.tlas_translator)
	cmd_bind_transient(c, TLAS_SLOT_TABLE, table)
	cmd_bind_buffer(c, TLAS_SLOT_SOURCE, instances)
	cmd_bind_buffer(c, TLAS_SLOT_NATIVE, a.native)
	groups := (count + TLAS_GROUP - 1) / TLAS_GROUP
	cmd_dispatch(c, min(groups, TLAS_DISPATCH_X), (groups + TLAS_DISPATCH_X - 1) / TLAS_DISPATCH_X)
	c.slots = slots
	c.pipeline, c.dirty = 0, true
	if pipeline != 0 {cmd_bind_pipeline(c, pipeline)}
	native := pool_get(&d.buffers, base.Handle(a.native))
	scratch := vk_scratch_address(d, a.scratch_size)
	if scratch == 0 || native == nil {set_error(d, "the scratch or the instances of a TLAS build are gone"); return false}
	cmd_barrier_buffer(c, a.native, .Accel_Build_Input)
	cmd_barrier_buffer(c, d.scratch, .Accel_Build_Write)
	cmd_barrier_buffer(c, a.buffer, .Accel_Build_Write)
	vk_flush_barriers(c)
	geometry := vk_tlas_geometry(native.address)
	build := vk.AccelerationStructureBuildGeometryInfoKHR{
		sType = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR, type = .TOP_LEVEL,
		flags = {.PREFER_FAST_TRACE}, mode = .BUILD, geometryCount = 1, pGeometries = &geometry,
		dstAccelerationStructure = a.handle,
	}
	build.scratchData.deviceAddress = vk.DeviceAddress(scratch)
	range := vk.AccelerationStructureBuildRangeInfoKHR{primitiveCount = count}
	ranges := cast([^]vk.AccelerationStructureBuildRangeInfoKHR)&range
	d.dvk.CmdBuildAccelerationStructuresKHR(c.cmd, 1, &build, &ranges)
	a.built = true
	return true
}
