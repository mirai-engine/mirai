#+build darwin
package rhi

import "mirai:std/base"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

// Slang lowers RayQuery instance user ID queries to
// get_committed_user_instance_id(), which reads userID.
@(private)
Mtl_Instance :: MTL.AccelerationStructureUserIDInstanceDescriptor
#assert(size_of(Mtl_Instance) == 68)

// A structure of size bytes in a range of the arena: a placement heap that
// has room, or a new one. The heaps releases left empty go first. Tracked, as
// the structures the device made itself: encoders that build and read them
// are ordered by their hazards.
@(private)
mtl_accel_new :: proc(d: ^Device, size: u64) -> (handle: ^MTL.AccelerationStructure, block: int, offset, taken: u64) {
	for empty in d.accel_empty {
		if empty >= len(d.accel_arena.blocks) || d.accel_arena.blocks[empty].size == 0 || d.accel_arena.blocks[empty].used > 0 {continue}
		mtl_defer(d, d.accel_heaps[empty])
		d.accel_heaps[empty] = nil
		arena_drop(&d.accel_arena, empty)
	}
	clear(&d.accel_empty)
	if d.accel_arena.allocator.procedure == nil {
		d.accel_arena.allocator = d.allocator
		d.accel_heaps = make([dynamic]^MTL.Heap, d.allocator)
		d.accel_empty = make([dynamic]int, d.allocator)
	}
	placed := MTL.Device_heapAccelerationStructureSizeAndAlignWithSize(d.device, NS.UInteger(size))
	align := max(u64(placed.align), ACCEL_ALIGNMENT)
	taken = align_up(u64(placed.size), align)
	ok: bool
	block, offset, ok = arena_take(&d.accel_arena, taken, align)
	if !ok {
		bytes := accel_block_size(taken)
		descriptor := MTL.HeapDescriptor.alloc()->init()
		defer mtl_release(descriptor)
		MTL.HeapDescriptor_setType(descriptor, .Placement)
		MTL.HeapDescriptor_setStorageMode(descriptor, .Private)
		MTL.HeapDescriptor_setHazardTrackingMode(descriptor, .Tracked)
		MTL.HeapDescriptor_setSize(descriptor, NS.UInteger(bytes))
		heap := MTL.Device_newHeapWithDescriptor(d.device, descriptor)
		if heap == nil {return}
		mtl_set_label(heap, "acceleration structures")
		at, added := arena_add(&d.accel_arena, bytes)
		if added && len(d.accel_heaps) <= at && resize(&d.accel_heaps, at + 1) != nil {
			arena_drop(&d.accel_arena, at)
			added = false
		}
		if added {
			d.accel_heaps[at] = heap
			block, offset, ok = arena_take(&d.accel_arena, taken, align)
		}
		if !ok {
			if added {
				d.accel_heaps[at] = nil
				arena_drop(&d.accel_arena, at)
			}
			mtl_release(heap)
			set_error(d, "out of memory for the blocks of the acceleration structures")
			return
		}
	}
	handle = MTL.Heap_newAccelerationStructureWithSize(d.accel_heaps[block], NS.UInteger(size), NS.UInteger(offset))
	if handle == nil && arena_give(&d.accel_arena, block, offset, taken) {append(&d.accel_empty, block)}
	return
}

// Allocates a primitive acceleration structure for static triangle geometry.
// The descriptor is kept for cmd_build_blas.
blas_create :: proc(d: ^Device, desc: Blas_Desc) -> Accel {
	NS.scoped_autoreleasepool()
	if !d.info.features.ray_query {set_error(d, "hardware ray tracing is not enabled"); return 0}
	if !device_room(d, &d.accels, "acceleration structures") {return 0}
	vb := pool_get(&d.buffers, base.Handle(desc.vertex_buffer))
	ib := pool_get(&d.buffers, base.Handle(desc.index_buffer))
	if vb == nil || ib == nil || desc.triangle_count == 0 {
		set_error(d, "BLAS %s needs vertex and index buffers and triangles", desc.name)
		return 0
	}
	geometry := MTL.AccelerationStructureTriangleGeometryDescriptor.alloc()->init()
	defer mtl_release(geometry)
	MTL.AccelerationStructureTriangleGeometryDescriptor_setVertexBuffer(geometry, vb.handle)
	MTL.AccelerationStructureTriangleGeometryDescriptor_setVertexBufferOffset(geometry, NS.UInteger(desc.vertex_offset))
	// The default vertex format is MTLAttributeFormatFloat3 (three packed f32).
	MTL.AccelerationStructureTriangleGeometryDescriptor_setVertexStride(geometry, NS.UInteger(desc.vertex_stride if desc.vertex_stride > 0 else 12))
	MTL.AccelerationStructureTriangleGeometryDescriptor_setIndexBuffer(geometry, ib.handle)
	MTL.AccelerationStructureTriangleGeometryDescriptor_setIndexBufferOffset(geometry, NS.UInteger(desc.index_offset))
	MTL.AccelerationStructureTriangleGeometryDescriptor_setIndexType(geometry, .UInt32)
	MTL.AccelerationStructureTriangleGeometryDescriptor_setTriangleCount(geometry, NS.UInteger(desc.triangle_count))
	MTL.AccelerationStructureGeometryDescriptor_setOpaque(geometry, true)
	// A ray query that collects the filters of blended triangles needs each
	// candidate reported once.
	MTL.AccelerationStructureGeometryDescriptor_setAllowDuplicateIntersectionFunctionInvocation(geometry, false)
	objects := [1]^NS.Object{cast(^NS.Object)geometry}
	geometries := NS.Array.alloc()->initWithObjects(cast(^NS.id)&objects[0], 1)
	defer mtl_release(geometries)
	primitive := MTL.PrimitiveAccelerationStructureDescriptor.alloc()->init()
	MTL.PrimitiveAccelerationStructureDescriptor_setGeometryDescriptors(primitive, geometries)
	descriptor := cast(^MTL.AccelerationStructureDescriptor)primitive
	if desc.deformable {MTL.AccelerationStructureDescriptor_setUsage(descriptor,{.Refit})}
	sizes := MTL.Device_accelerationStructureSizesWithDescriptor(d.device, descriptor)
	handle, block, offset, taken := mtl_accel_new(d, u64(sizes.accelerationStructureSize))
	if handle == nil {
		mtl_release(primitive)
		set_error(d, "newAccelerationStructureWithSize(%d) failed for BLAS %s", sizes.accelerationStructureSize, desc.name)
		return 0
	}
	mtl_set_label(handle, desc.name)
	a := Mtl_Accel{handle = handle, descriptor = descriptor, blas = desc, scratch_size = u64(max(sizes.buildScratchBufferSize,sizes.refitScratchBufferSize)), block = i32(block + 1), offset = offset, size = taken}
	a.blas.name = ""
	return Accel(pool_add(&d.accels, a))
}

tlas_create :: proc(d: ^Device, max_instances: u32, name: string = "tlas") -> Accel {
	NS.scoped_autoreleasepool()
	if !d.info.features.ray_query {set_error(d, "hardware ray tracing is not enabled"); return 0}
	if !device_room(d, &d.accels, "acceleration structures") {return 0}
	count := max(max_instances, 1)
	// Sizing only depends on the instance count; each build uses its own
	// descriptor (cmd_build_tlas).
	instance := MTL.InstanceAccelerationStructureDescriptor.alloc()->init()
	defer mtl_release(instance)
	empty := NS.Array.alloc()->init()
	defer mtl_release(empty)
	MTL.InstanceAccelerationStructureDescriptor_setInstanceDescriptorType(instance, .UserID)
	MTL.InstanceAccelerationStructureDescriptor_setInstanceDescriptorStride(instance, size_of(Mtl_Instance))
	MTL.InstanceAccelerationStructureDescriptor_setInstanceCount(instance, NS.UInteger(count))
	MTL.InstanceAccelerationStructureDescriptor_setInstancedAccelerationStructures(instance, empty)
	sizes := MTL.Device_accelerationStructureSizesWithDescriptor(d.device, cast(^MTL.AccelerationStructureDescriptor)instance)
	handle, block, offset, taken := mtl_accel_new(d, u64(sizes.accelerationStructureSize))
	if handle == nil {set_error(d, "newAccelerationStructureWithSize(%d) failed for TLAS %s", sizes.accelerationStructureSize, name); return 0}
	mtl_set_label(handle, name)
	a := Mtl_Accel{handle = handle, top_level = true, max_instances = count, scratch_size = u64(sizes.buildScratchBufferSize), block = i32(block + 1), offset = offset, size = taken}
	a.referenced = make([dynamic]^MTL.AccelerationStructure, d.allocator)
	return Accel(pool_add(&d.accels, a))
}

accel_destroy :: proc(d: ^Device, accel: Accel) {
	a, ok := pool_remove(&d.accels, base.Handle(accel))
	if !ok {return}
	compact_slot_give(d, a.compact_slot)
	mtl_defer(d, a.handle)
	mtl_defer_range(d, a.block, a.offset, a.size)
	mtl_defer(d, a.descriptor)
	mtl_defer(d, a.instanced)
	mtl_defer(d, a.instance_buffer)
	if a.native != 0 {buffer_destroy(d, a.native)}
	delete(a.referenced)
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

// Returns the encoder, scratch buffer and scratch offset for one build. Builds
// that share an encoder get disjoint scratch ranges, so Metal may overlap them
// freely. When the range does not fit, either a new encoder starts (the
// tracked scratch buffer then orders it after the earlier builds) or, for a
// build larger than the whole buffer, a bigger buffer replaces it; builds
// already encoded keep the old one, which the command buffer retains and
// buffer_destroy releases later.
@(private)
mtl_build_target :: proc(c: ^Command_List, scratch_size: u64) -> (encoder: ^MTL.AccelerationStructureCommandEncoder, scratch: ^MTL.Buffer, offset: u64) {
	d := c.device
	size := align_up(max(scratch_size, 16), 256)
	encoder = mtl_accel_encoder(c)
	offset = align_up(c.scratch_used, 256)
	if d.scratch != 0 && size <= d.scratch_size && offset + size > d.scratch_size {
		mtl_end_encoder(c)
		encoder = mtl_accel_encoder(c)
		offset = 0
	}
	if d.scratch == 0 || size > d.scratch_size {
		if d.scratch != 0 {buffer_destroy(d, d.scratch)}
		d.scratch = mtl_create_buffer(d, {size = size, memory = .GPU, name = "acceleration scratch"})
		d.scratch_size = size if d.scratch != 0 else 0
		offset = 0
	}
	b := pool_get(&d.buffers, base.Handle(d.scratch))
	if b == nil {return nil, nil, 0}
	c.scratch_used = offset + size
	return encoder, b.handle, offset
}

// A deformable BLAS already built is refitted over its new positions unless
// rebuild asks to build it again.
cmd_build_blas :: proc(c: ^Command_List, accel: Accel, rebuild := false) {
	d := c.device
	assert(!c.in_render_pass)
	a := pool_get(&d.accels, base.Handle(accel))
	if a == nil || a.top_level {return}
	if pool_get(&d.buffers, base.Handle(a.blas.vertex_buffer)) == nil || pool_get(&d.buffers, base.Handle(a.blas.index_buffer)) == nil {
		set_error(d, "BLAS build inputs are gone")
		return
	}
	encoder, scratch, offset := mtl_build_target(c, a.scratch_size)
	if scratch == nil {return}
	if a.blas.deformable && a.built && !rebuild {
		MTL.AccelerationStructureCommandEncoder_refitAccelerationStructure(encoder,a.handle,a.descriptor,a.handle,scratch,NS.UInteger(offset))
	} else {
		MTL.AccelerationStructureCommandEncoder_buildAccelerationStructure(encoder, a.handle, a.descriptor, scratch, NS.UInteger(offset))
	}
	a.built = true
	if a.blas.compact && !a.blas.deformable {mtl_compact_size_write(c, a)}
}

// The GPU writes the compacted size of a BLAS it just built into a slot of
// the table, in an encoder after the build; with every slot waiting, the BLAS
// stays as it is.
@(private)
mtl_compact_size_write :: proc(c: ^Command_List, a: ^Mtl_Accel) {
	d := c.device
	if d.compact_sizes == 0 {d.compact_sizes = mtl_create_buffer(d, {size = COMPACT_SLOTS * size_of(u32), memory = .Readback, name = "compacted sizes"})}
	sizes := pool_get(&d.buffers, base.Handle(d.compact_sizes))
	if sizes == nil {return}
	compact_slot_give(d, a.compact_slot)
	a.compact_slot = compact_slot_take(d)
	if a.compact_slot == 0 {return}
	a.compact_frame, a.compact_immediate = d.frame_number, c.immediate
	(cast([^]u32)sizes.mapped)[a.compact_slot - 1] = 0
	mtl_end_encoder(c)
	encoder := mtl_accel_encoder(c)
	MTL.AccelerationStructureCommandEncoder_writeCompactedAccelerationStructureSize(encoder, a.handle, sizes.handle, NS.UInteger((a.compact_slot - 1) * size_of(u32)))
}

// Replaces the BLASes whose compacted size the GPU gave by compacted copies,
// in a list of a frame: how many, and the bytes that leaves free. A TLAS that
// names them is to be built again after it in the same list.
cmd_compact_blases :: proc(c: ^Command_List) -> (replaced: int, freed: u64) {
	NS.scoped_autoreleasepool()
	d := c.device
	sizes := pool_get(&d.buffers, base.Handle(d.compact_sizes))
	if c.immediate || sizes == nil {return}
	assert(!c.in_render_pass)
	for i in 0 ..< d.accels.used {
		if !d.accels.alive[i] {continue}
		a := &d.accels.items[i]
		if a.compact_slot == 0 || !compact_ready(d, a.compact_frame, a.compact_immediate) {continue}
		size := u64((cast([^]u32)sizes.mapped)[a.compact_slot - 1])
		compact_slot_give(d, a.compact_slot)
		a.compact_slot = 0
		if size == 0 || f64(size) > f64(a.size) * COMPACT_SAVING {continue}
		handle, block, offset, taken := mtl_accel_new(d, size)
		if handle == nil {continue}
		encoder := mtl_accel_encoder(c)
		MTL.AccelerationStructureCommandEncoder_copyAndCompactAccelerationStructure(encoder, a.handle, handle)
		mtl_defer(d, a.handle)
		mtl_defer_range(d, a.block, a.offset, a.size)
		freed += a.size - taken if a.size > taken else 0
		a.handle, a.block, a.offset, a.size = handle, i32(block + 1), offset, taken
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
		a.native = mtl_create_buffer(d, {size = u64(room) * size_of(Mtl_Instance), usage = {.Accel_Input, .Storage}, memory = .GPU, name = "tlas instances"})
		a.native_room = room if a.native != 0 else 0
		if a.native == 0 {return false}
	}
	// Every built primitive structure is one the instances may name: its
	// place in the array of the build + 1 is its native value.
	ids := d.accels.used + 1
	blases := make([dynamic]^MTL.AccelerationStructure, 0, ids, context.temp_allocator)
	bytes := u64(TLAS_TABLE_HEADER + 2 * ids) * 4
	staging: Buffer
	table: Transient
	if c.immediate {
		staging = mtl_create_buffer(d, {size = bytes, usage = {.Storage}, memory = .Upload, name = "tlas table"})
		if staging == 0 {return false}
		table = {ptr = buffer_mapped(d, staging), buffer = staging, size = bytes}
	} else {
		table = frame_alloc(d, bytes, 16)
		if table.ptr == nil {return false}
	}
	defer if staging != 0 {buffer_destroy(d, staging)}
	values := (cast([^]u64)(uintptr(table.ptr) + size_of(Tlas_Table_Header)))[:ids]
	values[0] = 0
	for i in 0 ..< d.accels.used {
		blas := &d.accels.items[i]
		values[i + 1] = 0
		if !d.accels.alive[i] || blas.top_level || !blas.built {continue}
		append(&blases, blas.handle)
		values[i + 1] = u64(len(blases))
	}
	// Without any primitive structure no instance can name one: an empty
	// structure, which never reports a hit.
	built := count if len(blases) > 0 else 0
	(cast(^Tlas_Table_Header)table.ptr)^ = {
		count = built, layout = TLAS_LAYOUT_COLUMNS, stride = size_of(Mtl_Instance) / 4, first = u32(offset / size_of(Tlas_Instance)), ids = u32(ids),
		opaque = transmute(u32)MTL.AccelerationStructureInstanceOptions{.Opaque, .DisableTriangleCulling},
		tested = transmute(u32)MTL.AccelerationStructureInstanceOptions{.NonOpaque, .DisableTriangleCulling},
	}
	if built > 0 {
		// The translation binds what it needs and gives the list back as it was.
		slots := c.slots
		pipeline := c.pipeline
		cmd_bind_pipeline(c, d.tlas_translator)
		cmd_bind_transient(c, TLAS_SLOT_TABLE, table)
		cmd_bind_buffer(c, TLAS_SLOT_SOURCE, instances)
		cmd_bind_buffer(c, TLAS_SLOT_NATIVE, a.native)
		groups := (built + TLAS_GROUP - 1) / TLAS_GROUP
		cmd_dispatch(c, min(groups, TLAS_DISPATCH_X), (groups + TLAS_DISPATCH_X - 1) / TLAS_DISPATCH_X)
		c.slots = slots
		c.pipeline, c.pipeline_applied, c.dirty = 0, false, max(u32)
		if pipeline != 0 {cmd_bind_pipeline(c, pipeline)}
	}
	// Keep the raw object, not the pool pointer: growing the scratch buffer
	// below adds to the buffer pool and may move its items.
	native: ^MTL.Buffer
	if b := pool_get(&d.buffers, base.Handle(a.native)); b != nil {native = b.handle}
	if native == nil {set_error(d, "the instances of a TLAS build are gone"); return false}

	array := NS.Array.alloc()->initWithObjects(cast(^NS.id)raw_data(blases), NS.UInteger(len(blases)))
	instance := MTL.InstanceAccelerationStructureDescriptor.alloc()->init()
	defer mtl_release(instance)
	MTL.InstanceAccelerationStructureDescriptor_setInstanceDescriptorType(instance, .UserID)
	MTL.InstanceAccelerationStructureDescriptor_setInstanceDescriptorStride(instance, size_of(Mtl_Instance))
	MTL.InstanceAccelerationStructureDescriptor_setInstanceCount(instance, NS.UInteger(built))
	MTL.InstanceAccelerationStructureDescriptor_setInstanceDescriptorBuffer(instance, native)
	MTL.InstanceAccelerationStructureDescriptor_setInstanceDescriptorBufferOffset(instance, 0)
	MTL.InstanceAccelerationStructureDescriptor_setInstancedAccelerationStructures(instance, array)

	// The primitive structures and the translated instances must be complete
	// before the instance build reads them: builds recorded earlier in this
	// list go to a previous encoder, and tracked hazards order encoders.
	if c.encoder_kind == .Accel {mtl_end_encoder(c)}
	encoder, scratch, offset := mtl_build_target(c, a.scratch_size)
	if scratch == nil {mtl_release(array); set_error(d, "no scratch for a TLAS build"); return false}
	for blas in blases {MTL.AccelerationStructureCommandEncoder_useResource(encoder, cast(^MTL.Resource)blas, {.Read})}
	MTL.AccelerationStructureCommandEncoder_buildAccelerationStructure(encoder, a.handle, cast(^MTL.AccelerationStructureDescriptor)instance, scratch, NS.UInteger(offset))

	// Keep the referenced primitive structures (and the instance data) alive
	// with the TLAS so that binds can make them resident with useResource.
	// The previous set may still be used by frames in flight.
	mtl_defer(d, a.instanced)
	mtl_defer(d, a.instance_buffer)
	a.instanced = array
	mtl_retain(native)
	a.instance_buffer = native
	clear(&a.referenced)
	append(&a.referenced, ..blases[:])
	a.built = true
	return true
}
