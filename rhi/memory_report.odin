package rhi

import "core:slice"

// Where the memory of a device goes, resource by resource: every buffer,
// texture and acceleration structure it holds, by the name it was made with,
// against what the driver says the process holds. Each resource keeps its name
// and size from its creation; the report walks the pools when asked.

RESOURCE_NAME_BYTES :: 48 // of the name a resource keeps; past them it is cut

// The name a resource was made with.
Resource_Name :: struct {
	bytes:  [RESOURCE_NAME_BYTES]u8,
	length: u8,
}

@(private)
resource_name_set :: proc "contextless" (n: ^Resource_Name, name: string) {n.length = u8(copy(n.bytes[:], name))}

@(private)
resource_name :: proc "contextless" (n: ^Resource_Name) -> string {return string(n.bytes[:n.length])}

Resource_Kind :: enum u8 {Buffer, Texture, Accel}

// What resources made without a name show as.
RESOURCE_UNNAMED :: [Resource_Kind]string{.Buffer = "unnamed buffer", .Texture = "unnamed texture", .Accel = "unnamed acceleration structure"}
// The room of the blocks of the acceleration structures that none of them takes.
ACCEL_UNUSED_NAME :: "acceleration blocks unused"

// One resource as the backend counts it.
@(private)
Resource_Entry :: struct {
	name:   string,
	kind:   Resource_Kind,
	format: Format,
	bytes:  u64,
	host:   bool, // in system memory, which the driver's figure of the device does not count
}

// The resources of one kind and name.
Memory_Group :: struct {
	name:       string, // the name they were made with, valid until one of them is destroyed
	kind:       Resource_Kind,
	format:     Format, // of textures that all have it; Undefined otherwise
	count:      int,
	bytes:      u64, // of the memory of the device they hold; an acceleration structure, its range of the blocks
	host_bytes: u64, // of system memory they hold
}

Memory_Kind_Total :: struct {
	count:             int,
	bytes, host_bytes: u64,
}

Memory_Report :: struct {
	groups:         []Memory_Group, // the largest first, of the slice given, up to its length
	group_count:    int,            // the groups found; those past the slice are summed in others
	others:         Memory_Kind_Total,
	kinds:          [Resource_Kind]Memory_Kind_Total,
	unnamed_bytes:  u64, // of resources made without a name
	resource_bytes: u64, // of the memory of the device the resources hold: their groups summed
	free_bytes:     u64, // of the blocks of device memory the device took that no resource holds
	deleting_bytes: u64, // of resources destroyed whose memory waits for frames the GPU may still run
	held_bytes:     u64, // of the memory of the device the device took: the three before
	driver_bytes:   u64, // what the driver says the process holds of it (device_memory); 0 when it does not say
	budget_bytes:   u64, // what the system lets the process hold before it pages some out; 0 when it does not say
}

// Where the memory of the device goes, the largest groups in groups. Between
// frames or on the thread that records them; it allocates in allocator, and
// is false without memory there.
device_memory_report :: proc(d: ^Device, groups: []Memory_Group, allocator := context.temp_allocator) -> (report: Memory_Report, ok: bool) {
	// Every resource, and the room of the blocks of the acceleration structures.
	entries := make([dynamic]Resource_Entry, allocator)
	if reserve(&entries, d.buffers.count + d.textures.count + d.accels.count + 1) != nil {return}
	report.free_bytes, report.deleting_bytes = device_resource_list(d, &entries)
	found := make([dynamic]Memory_Group, allocator)
	index: [Resource_Kind]map[string]int
	for &m in index {m = make(map[string]int, allocator = allocator)}
	unnamed := RESOURCE_UNNAMED
	for e in entries {
		name := e.name
		if name == "" {
			name = unnamed[e.kind]
			report.unnamed_bytes += e.bytes
		}
		at, known := index[e.kind][name]
		if !known {
			at = len(found)
			index[e.kind][name] = at
			if _, error := append(&found, Memory_Group{name = name, kind = e.kind, format = e.format}); error != nil {return}
		}
		g := &found[at]
		if g.format != e.format {g.format = .Undefined}
		g.count += 1
		total := &report.kinds[e.kind]
		total.count += 1
		if e.host {
			g.host_bytes += e.bytes
			total.host_bytes += e.bytes
		} else {
			g.bytes += e.bytes
			total.bytes += e.bytes
			report.resource_bytes += e.bytes
		}
	}
	slice.sort_by(found[:], proc(a, b: Memory_Group) -> bool {return a.bytes + a.host_bytes > b.bytes + b.host_bytes})
	shown := copy(groups, found[:])
	report.groups, report.group_count = groups[:shown], len(found)
	for g in found[shown:] {
		report.others.count += g.count
		report.others.bytes += g.bytes
		report.others.host_bytes += g.host_bytes
	}
	report.held_bytes = report.resource_bytes + report.free_bytes + report.deleting_bytes
	report.driver_bytes, report.budget_bytes = device_memory(d)
	return report, true
}
