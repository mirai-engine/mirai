// Package rhi is Mirai's render hardware interface: one explicit, bindless
// friendly GPU API with a Vulkan backend (Linux, Windows) and a Metal backend
// (macOS). The backend is selected at compile time with build tags; there is no
// virtual dispatch. Every procedure in this file's contract is implemented by
// vulkan_*.odin and metal_*.odin with identical signatures.
//
// Rules shared by both backends:
//   - A Device is used from one thread (the render thread), except that
//     pipeline_create_compute and pipeline_create_graphics also run on other
//     threads, while it records frames: compiling shaders in the driver takes
//     seconds. Destroying pipelines stays on the render thread.
//   - Resources are generational handles. The zero handle is invalid.
//   - Destruction is deferred until the GPU finished every frame that could use
//     the resource, so destroying during a frame is safe.
//   - Bindings are slots. A shader binding N maps to Vulkan descriptor binding N
//     (set 0, push descriptors) and to Metal [[buffer(N)]]/[[texture(N)]]/
//     [[sampler(N)]]. Shaders take parameters from uniform buffers, never push
//     constants, so the same SPIR-V/MSL pair works everywhere.
//   - Hazards follow from what dispatches and draws bind: the backend tracks the
//     current access of every resource and emits only the barriers that are
//     needed, those of a render pass before it begins. cmd_barrier_* declares
//     the accesses nothing binds: the host reading a buffer, a texture sampled
//     through the texture table or by another process. Metal tracks hazards
//     itself and treats these calls as validation.
//   - Clip space is Y-up with depth in [0,1] on both backends (Vulkan uses a
//     negative viewport height), so projection matrices are shared.
//   - Textures a shader picks by index at run time (material maps) live in the
//     texture table: one array of sampled textures per device, declared by
//     shaders without a size at set 1, binding TEXTURE_TABLE_SLOT. It grows
//     when an entry past it is set, up to texture_table_limit. Every entry is
//     always a valid texture (a white texel until texture_table_set).
//   - A loss of the GPU is found where the API reports it (submissions,
//     presentation, waits, queries, maps) and kept as device_failure; no wait
//     lasts past GPU_WAIT_LIMIT_NS. Nothing aborts: calls on a failed device
//     return false or the zero handle.
package rhi

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "mirai:std/base"

Backend :: enum u8 {Vulkan, Metal}

Buffer   :: distinct base.Handle
Texture  :: distinct base.Handle
Sampler  :: distinct base.Handle
Pipeline :: distinct base.Handle
Accel    :: distinct base.Handle

MAX_FRAMES_IN_FLIGHT :: 2
MAX_BINDING_SLOTS    :: 35 // Shared texture slots precede the texture table.
MAX_BUFFER_BINDING_SLOTS :: 30 // Metal buffer index 30, its last, holds the texture table.
MAX_SAMPLER_BINDING_SLOTS :: 16
MAX_COLOR_TARGETS    :: 8
MAX_TEXTURE_MIPS     :: 14
// Vulkan has the table in descriptor sets of their own, of a variable count
// whose upper bound the device limits give; Metal in argument buffers (Tier 2)
// in device memory at buffer index TEXTURE_TABLE_METAL_BUFFER, the table
// being their member TEXTURE_TABLE_SLOT. There is a copy for each frame in
// flight and one for immediate lists: a copy takes the entries that changed
// when its list begins, after the GPU finished the work that read it, so
// changing the table waits for nothing. Growing makes new copies with every
// entry and lets the old ones go once the GPU no longer reads them.
TEXTURE_TABLE_SLOT         :: MAX_BINDING_SLOTS
TEXTURE_TABLE_METAL_BUFFER :: MAX_BUFFER_BINDING_SLOTS
TEXTURE_TABLE_COPIES       :: MAX_FRAMES_IN_FLIGHT + 1 // the last one, of immediate lists
// The entries a table starts with: a small scene never grows it.
TEXTURE_TABLE_FIRST        :: 1024
// The most entries a table grows to on either backend: the textures Metal's
// Tier 2 argument buffers give an application at once (Apple, "Improving CPU
// performance by using argument buffers"). A Vulkan device whose limits allow
// fewer stops at those.
TEXTURE_TABLE_MAX          :: 500_000

// Entries of the table each copy has not taken yet, a bit per entry.
Table_Changes :: [TEXTURE_TABLE_COPIES][dynamic]u64

// The size a table of capacity entries grows to so that it holds index:
// doubled until it does, and never past limit. 0 when limit does not hold it.
table_grown :: proc "contextless" (capacity, index, limit: int) -> int {
	if index >= limit {return 0}
	size := max(capacity, TEXTURE_TABLE_FIRST)
	for size <= index {size *= 2}
	return min(size, limit)
}

// Gives every copy a bit for each of capacity entries, none set: a copy
// made with every entry has none to take. False without memory, and then no
// copy lost a bit it had.
@(private)
table_changes_reset :: proc(changes: ^Table_Changes, capacity: int) -> bool {
	for &copy in changes {
		if resize(&copy, (capacity + 63) / 64) != nil {return false}
	}
	for &copy in changes {
		for &word in copy {word = 0}
	}
	return true
}

@(private)
table_changes_destroy :: proc(changes: ^Table_Changes) {
	for &copy in changes {delete(copy)}
}

@(private)
table_changed :: proc "contextless" (changes: ^Table_Changes, index: u32) {
	for &copy in changes {copy[index / 64] |= 1 << (index % 64)}
}

// The entries copy has not taken, into out (as long as the table, so taking
// allocates nothing); they count as taken.
@(private)
table_take :: proc "contextless" (changes: ^Table_Changes, copy: int, out: []u32) -> (count: int) {
	for &word, w in changes[copy] {
		for word != 0 {
			out[count] = u32(w * 64) + u32(intrinsics.count_trailing_zeros(word))
			count += 1
			word &= word - 1
		}
	}
	return
}

// What the table knows of a texture: how many entries name it and the last one
// it was put in, so destroying it looks at that entry alone in the common case.
@(private)
Table_Refs :: struct {count, last: u32}

// An entry moves from the texture it named to the one it names now (nil: the default).
@(private)
table_refs_move :: proc "contextless" (before, after: ^Table_Refs, index: u32) {
	if before != nil {before.count -= 1}
	if after != nil {after.count += 1; after.last = index}
}

// The entries to look at for a texture that goes: none when no entry names it,
// the last one it was put in when that is its only one, else the whole table.
@(private)
table_refs_range :: proc "contextless" (entries: []Texture, texture: Texture, refs: Table_Refs) -> (from, to: int) {
	if refs.count == 0 {return 0, 0}
	if refs.count == 1 && int(refs.last) < len(entries) && entries[refs.last] == texture {return int(refs.last), int(refs.last) + 1}
	return 0, len(entries)
}

// The copy of the table a list reads: that of its frame slot, or the last
// one for an immediate list.
@(private)
table_copy :: proc "contextless" (immediate: bool, slot: int) -> int {return MAX_FRAMES_IN_FLIGHT if immediate else slot}

Format :: enum u8 {
	Undefined,
	R8_Unorm, RG8_Unorm, RGBA8_Unorm, RGBA8_Srgb, BGRA8_Unorm, BGRA8_Srgb,
	R16_Float, RG16_Float, RGBA16_Float,
	R32_Float, RG32_Float, RGBA32_Float,
	R32_Uint, RG32_Uint, RGBA32_Uint,
	R8_Uint, RG16_Sint,
	RG11B10_Float,
	D32_Float,
	// Block compressed, 4x4 texels per block (Features.texture_bc).
	BC1_Unorm, BC1_Srgb, // 8 bytes: rgb
	BC3_Unorm, BC3_Srgb, // 16 bytes: rgb and alpha
	BC5_Unorm,           // 16 bytes: two channels
	BC7_Unorm, BC7_Srgb, // 16 bytes: rgb or rgba
	BC6H_Ufloat,         // 16 bytes: rgb half floats without sign
	RGBA16_Unorm,
}

format_size :: proc "contextless" (f: Format) -> int {
	switch f {
	case .Undefined:                                         return 0
	case .R8_Unorm, .R8_Uint:                                return 1
	case .RG8_Unorm, .R16_Float:                             return 2
	case .RGBA8_Unorm, .RGBA8_Srgb, .BGRA8_Unorm, .BGRA8_Srgb, .RG16_Float, .RG16_Sint, .R32_Float, .R32_Uint, .RG11B10_Float, .D32_Float: return 4
	case .RGBA16_Float, .RGBA16_Unorm, .RG32_Float, .RG32_Uint: return 8
	case .RGBA32_Float, .RGBA32_Uint:                        return 16
	case .BC1_Unorm, .BC1_Srgb, .BC3_Unorm, .BC3_Srgb, .BC5_Unorm, .BC6H_Ufloat, .BC7_Unorm, .BC7_Srgb: return 0 // not per texel: see format_rows
	}
	return 0
}
format_is_depth :: proc "contextless" (f: Format) -> bool {return f == .D32_Float}

// Bytes of a block of a block compressed format, 0 for the others.
format_block_size :: proc "contextless" (f: Format) -> int {
	#partial switch f {
	case .BC1_Unorm, .BC1_Srgb:             return 8
	case .BC3_Unorm, .BC3_Srgb, .BC5_Unorm, .BC6H_Ufloat, .BC7_Unorm, .BC7_Srgb: return 16
	}
	return 0
}

// How the texels of a level are laid out in memory: bytes per row and rows.
// A row of a block compressed format is a row of blocks.
format_rows :: proc "contextless" (f: Format, width, height: u32) -> (row_bytes, rows: u64) {
	if block := format_block_size(f); block > 0 {
		return u64((width + 3) / 4) * u64(block), u64((height + 3) / 4)
	}
	return u64(width) * u64(format_size(f)), u64(height)
}

Memory :: enum u8 {
	GPU,      // device local, not mapped
	Upload,   // host visible + coherent, persistently mapped (CPU writes, GPU reads); device local when it can be
	Readback, // host visible + cached, persistently mapped (GPU writes, CPU reads)
	Staging,  // host visible + coherent, persistently mapped, in the memory of the host when it can be: what the GPU copies from once, which takes no device memory
}

Buffer_Usage_Flag :: enum u8 {Index, Uniform, Storage, Indirect, Transfer_Src, Transfer_Dst, Accel_Input}
Buffer_Usage :: bit_set[Buffer_Usage_Flag; u16]
// What transient memory may be bound or copied as.
@(private)
TRANSIENT_USAGE :: Buffer_Usage{.Uniform, .Storage, .Index, .Indirect, .Transfer_Src, .Transfer_Dst, .Accel_Input}

// A new buffer reads zero in every byte, whatever its memory. One of GPU
// memory is zeroed by the GPU unless an upload writes all of it first, and is
// made outside render passes, which cannot hold that fill.
Buffer_Desc :: struct {
	size:   u64,
	usage:  Buffer_Usage,
	memory: Memory,
	name:   string,
}

Texture_Usage_Flag :: enum u8 {Sampled, Storage, Color_Target, Depth_Target, Transfer_Src, Transfer_Dst}
Texture_Usage :: bit_set[Texture_Usage_Flag; u8]

// The texels of a new texture are undefined until an upload, a clear or a
// pass writes them: nothing reads a texture it did not write.
Texture_Desc :: struct {
	width, height: u32,
	depth:         u32, // slices of a 3D texture, which shaders alone write; 0 or 1 = a 2D texture
	layers:        u32, // images of a 2D texture: 0 or 1 = one, those of an array, or six per cube
	cube:          bool, // its layers are the faces +X, -X, +Y, -Y, +Z, -Z of cubes
	mip_levels:    u32, // 0 or 1 = single level
	format:        Format,
	usage:         Texture_Usage,
	name:          string,
}

// Why a texture cannot be made, "" when it can: it has up to MAX_TEXTURE_MIPS
// levels, a 3D texture has no layers, a cube is square and has whole cubes,
// and a device takes up to limit layers.
texture_desc_problem :: proc "contextless" (desc: Texture_Desc, limit: u32) -> string {
	if desc.mip_levels > MAX_TEXTURE_MIPS {return "more mip levels than MAX_TEXTURE_MIPS; give it fewer levels or a smaller size"}
	layers := max(desc.layers, 1)
	if layers > 1 && desc.depth > 1 {return "a 3D texture has no layers"}
	if layers > limit {return "more layers than the device takes"}
	if desc.cube && (layers % 6 != 0 || desc.width != desc.height) {return "a cube needs square faces, six per cube"}
	return ""
}

// A rectangle of texels of one mip of a texture; zero: the whole mip. One of a
// block compressed format starts and ends on its blocks, or at the edge.
Texture_Region :: struct {
	x, y, width, height: u32,
}

// The region of a mip with the zero one made the whole mip; false when it does
// not lie inside the mip or cuts blocks of a compressed format.
texture_region_resolve :: proc "contextless" (desc: Texture_Desc, mip: u32, region: Texture_Region) -> (resolved: Texture_Region, ok: bool) {
	width, height := max(desc.width >> mip, 1), max(desc.height >> mip, 1)
	if region == {} {return {0, 0, width, height}, true}
	if region.width == 0 || region.height == 0 || region.x >= width || region.y >= height || region.width > width - region.x || region.height > height - region.y {return}
	if format_block_size(desc.format) > 0 {
		whole :: proc "contextless" (start, size, edge: u32) -> bool {return start % 4 == 0 && (size % 4 == 0 || start + size == edge)}
		if !whole(region.x, region.width, width) || !whole(region.y, region.height, height) {return}
	}
	return region, true
}

// A texture that another process of the same machine opens on the same GPU:
// the image a player draws and the editor shows. The number means something
// only to texture_open_shared; the texture keeps it valid while it lives.
// Formats of four bytes per texel, one level.
Shared_Texture :: distinct u64

Filter :: enum u8 {Nearest, Linear}
Address_Mode :: enum u8 {Clamp, Repeat}
Reduction :: enum u8 {Average, Min, Max}

Sampler_Desc :: struct {
	filter:     Filter,
	mip_filter: Filter,
	address:    Address_Mode,
	reduction:  Reduction,
	max_lod:    f32,
	anisotropy: f32, // samples of anisotropic filtering; up to 1 disables it
	name:       string,
}

Shader_Stage :: enum u8 {Vertex, Fragment, Compute}
Shader_Stages :: bit_set[Shader_Stage; u8]

Binding_Kind :: enum u8 {
	Uniform_Buffer,
	Storage_Buffer,    // read only
	Storage_Buffer_RW,
	Sampled_Texture,
	Storage_Texture,   // read/write image
	Sampler,
	Accel,
	Texture_Table,     // the device's texture table; its slot is TEXTURE_TABLE_SLOT
}

binding_slot_valid :: proc "contextless" (slot: u32, kind: Binding_Kind) -> bool {
	switch kind {
	case .Uniform_Buffer, .Storage_Buffer, .Storage_Buffer_RW, .Accel:
		return slot < MAX_BUFFER_BINDING_SLOTS
	case .Sampler:
		return slot < MAX_SAMPLER_BINDING_SLOTS
	case .Sampled_Texture, .Storage_Texture:
		return slot < MAX_BINDING_SLOTS
	case .Texture_Table:
		return slot == TEXTURE_TABLE_SLOT
	}
	return false
}

Binding_Info :: struct {
	slot:   u32,
	kind:   Binding_Kind,
	stages: Shader_Stages,
}

// Generated from one Slang source: SPIR-V for Vulkan, MSL translated by
// SPIRV-Cross for Metal, plus the shared reflected bindings.
Shader_Format :: enum u8 {Spirv, Msl}
// The code the Shader_Code of this system holds.
SHADER_FORMAT :: Shader_Format.Msl when ODIN_OS == .Darwin else Shader_Format.Spirv
when SHADER_FORMAT == .Msl {
	Shader_Binary :: struct {msl:string,msl_entry:string}
} else {
	Shader_Binary :: struct {spirv:[]u8}
}
Shader_Code :: struct {
	using binary: Shader_Binary,
	name:        string,
	stage:       Shader_Stage,
	threadgroup: [3]u32,
	bindings:    []Binding_Info,
	constants:   []string, // the names of its constants (`//! constant`), by id
}

// The most constants a shader declares; shaders/include/native.slang has as many.
MAX_SHADER_CONSTANTS :: 8
// The constants of a shader that are true in a pipeline, by id: the driver
// compiles the shader with them folded, so one code serves every combination.
// A SPIR-V specialization constant, a Metal function constant.
Shader_Constants :: distinct bit_set[0 ..< MAX_SHADER_CONSTANTS; u32]

// The constant of a shader by its name; false when it declares none so named.
shader_constant :: proc "contextless" (code: ^Shader_Code, name: string) -> (constants: Shader_Constants, found: bool) {
	if code == nil {return}
	for constant, id in code.constants[:min(len(code.constants), MAX_SHADER_CONSTANTS)] {
		if constant == name {return {id}, true}
	}
	return
}

// Whether a pipeline may set constants of code; false with the error of the device.
@(private)
shader_constants_valid :: proc(d: ^Device, pipeline: string, code: ^Shader_Code, constants: Shader_Constants) -> bool {
	if len(code.constants) > MAX_SHADER_CONSTANTS {
		set_error(d, "shader %s declares %d constants: at most %d", code.name, len(code.constants), MAX_SHADER_CONSTANTS)
		return false
	}
	for id in constants {
		if id >= len(code.constants) {
			set_error(d, "pipeline %s sets constant %d of shader %s, which declares %d", pipeline, id, code.name, len(code.constants))
			return false
		}
	}
	return true
}
// The code of a shader as bytes, and the entry point its MSL names ("" for SPIR-V).
shader_code_bytes :: proc "contextless" (code: Shader_Code) -> []u8 {
	when SHADER_FORMAT == .Msl {return transmute([]u8)code.msl} else {return code.spirv}
}
shader_code_entry :: proc "contextless" (code: Shader_Code) -> string {
	when SHADER_FORMAT == .Msl {return code.msl_entry} else {return ""}
}
// Gives a shader its code: bytes and entry are kept, not copied.
shader_code_set :: proc "contextless" (code: ^Shader_Code, bytes: []u8, entry: string) {
	when SHADER_FORMAT == .Msl {code.msl, code.msl_entry = string(bytes), entry} else {code.spirv = bytes}
}

Compare :: enum u8 {Never, Less, Less_Equal, Equal, Greater, Greater_Equal, Always}
Cull_Mode :: enum u8 {None, Back, Front}
// Alpha_Color: as Alpha for the color, and the alpha of the target stays as it is.
Blend_Mode :: enum u8 {Opaque, Alpha, Premultiplied, Additive, Multiply, Alpha_Color}
Topology :: enum u8 {Triangles, Lines}

Compute_Pipeline_Desc :: struct {
	shader:    ^Shader_Code,
	constants: Shader_Constants,
	name:      string,
}

Graphics_Pipeline_Desc :: struct {
	vertex, fragment: ^Shader_Code,
	vertex_constants, fragment_constants: Shader_Constants,
	color_formats:    [MAX_COLOR_TARGETS]Format,
	color_count:      int,
	blend:            [MAX_COLOR_TARGETS]Blend_Mode,
	depth_format:     Format,
	depth_test:       bool,
	depth_write:      bool,
	depth_compare:    Compare,
	cull:             Cull_Mode,
	topology:         Topology,
	name:             string,
}

// Access states used for hazard tracking. Shader_Read covers every shader stage
// (vertex, fragment, compute) so a write is always made visible to any reader.
Access :: enum u8 {
	None,
	Shader_Read,      // uniform, storage or sampled read
	Shader_Write,     // storage write (read-modify-write included)
	Index_Read,
	Indirect_Read,
	Color_Target,
	Depth_Target,
	Depth_Read,       // depth sampled as a texture
	Transfer_Read,
	Transfer_Write,
	Accel_Build_Input,
	Accel_Build_Write,
	Accel_Read,       // ray queries
	Present,
	Host_Read,
}

access_is_write :: proc "contextless" (a: Access) -> bool {
	#partial switch a {
	case .Shader_Write, .Color_Target, .Depth_Target, .Transfer_Write, .Accel_Build_Write: return true
	}
	return false
}

Load_Op :: enum u8 {Clear, Load, Dont_Care}
Store_Op :: enum u8 {Store, Dont_Care}

Color_Attachment :: struct {
	texture: Texture,
	load:    Load_Op,
	store:   Store_Op,
	clear:   [4]f32,
	clear_uint: [4]u32, // the clear of a texture of an integer format
}

// Whether a format holds integers: its clear is Color_Attachment.clear_uint.
format_is_uint :: proc "contextless" (f: Format) -> bool {return f == .R32_Uint || f == .RG32_Uint || f == .RGBA32_Uint || f == .R8_Uint || f == .RG16_Sint}

Depth_Attachment :: struct {
	texture: Texture,
	load:    Load_Op,
	store:   Store_Op,
	clear:   f32,
}

Render_Pass_Desc :: struct {
	colors:      [MAX_COLOR_TARGETS]Color_Attachment,
	color_count: int,
	depth:       Depth_Attachment, // texture 0 = no depth
	name:        string,
}

// Matches VkDrawIndexedIndirectCommand and MTLDrawIndexedPrimitivesIndirectArguments.
Draw_Indexed_Indirect :: struct {
	index_count:    u32,
	instance_count: u32,
	first_index:    u32,
	vertex_offset:  i32,
	first_instance: u32,
}

// Matches VkDrawIndirectCommand and MTLDrawPrimitivesIndirectArguments.
Draw_Indirect :: struct {
	vertex_count:   u32,
	instance_count: u32,
	first_vertex:   u32,
	first_instance: u32,
}

// Triangle geometry for a bottom level acceleration structure. Positions are
// three f32 at the start of each vertex; indices are u32.
Blas_Desc :: struct {
	vertex_buffer:  Buffer,
	vertex_offset:  u64,
	vertex_stride:  u32,
	vertex_count:   u32,
	index_buffer:   Buffer,
	index_offset:   u64,
	triangle_count: u32,
	deformable:     bool, // fixed topology, positions can be refitted
	compact:        bool, // made smaller once built (cmd_compact_blases); not with deformable
	name:           string,
}

// An instance of a TLAS as cmd_build_tlas reads it from a buffer, the same
// on every backend: the CPU or a compute of the caller writes it, and the
// translation of the RHI (tlas_translator_set) makes it native.
Tlas_Instance :: struct {
	transform:    [3][4]f32, // row-major 3x4 object-to-world
	custom_index: u32,       // 24 bits, returned by ray queries as the instance custom index
	blas:         u32,       // accel_id of its BLAS; 0, or a BLAS gone or not built: no ray meets it
	mask_flags:   u32,       // the mask rays test (bits 0-7), and TLAS_ALPHA_TESTED
	pad:          u32,
}
#assert(size_of(Tlas_Instance) == 64)
// Ray queries report the triangles of the instance as candidates for the
// shader to confirm; without it every hit is committed.
TLAS_ALPHA_TESTED :: u32(1) << 8

// The translation of instances (tlas_instances.comp.slang): its bindings, the
// words of its table before the native value of each BLAS, and its dispatch,
// TLAS_GROUP threads a group and up to TLAS_DISPATCH_X groups along x.
TLAS_SLOT_TABLE :: 0
TLAS_SLOT_SOURCE :: 1
TLAS_SLOT_NATIVE :: 2
TLAS_TABLE_HEADER :: 8
TLAS_GROUP :: 64
TLAS_DISPATCH_X :: 32768
// Where a native instance keeps its transform: by rows (Vulkan) or by columns (Metal).
TLAS_LAYOUT_ROWS :: 0
TLAS_LAYOUT_COLUMNS :: 1

// The words of the table of a translation: how many instances from which of
// the buffer, how the backend lays one out, and the word of its flags for an
// opaque instance and for one alpha tested. After it, a pair of words by BLAS
// id: the native value its instances take (Vulkan: its address; Metal: its
// place among the structures of the build + 1), 0 for none.
@(private)
Tlas_Table_Header :: struct {count, layout, stride, first, ids, opaque, tested, pad: u32}
#assert(size_of(Tlas_Table_Header) == TLAS_TABLE_HEADER * 4)

// The id of a BLAS in Tlas_Instance.blas, while it lives; 0 for anything else.
accel_id :: proc(d: ^Device, accel: Accel) -> u32 {
	a := pool_get(&d.accels, base.Handle(accel))
	if a == nil || a.top_level {return 0}
	return base.handle_index(base.Handle(accel)) + 1
}

// What the translation of TLAS instances needs of its shader: the bindings
// of tlas_instances.comp.slang. Empty when it has them.
@(private)
tlas_translator_problem :: proc(code: ^Shader_Code) -> string {
	if code == nil || code.stage != .Compute {return "the translation of TLAS instances needs a compute shader"}
	if code.threadgroup != {TLAS_GROUP, 1, 1} {return "the translation of TLAS instances runs TLAS_GROUP threads a group"}
	wanted := [3]Binding_Info{{slot = TLAS_SLOT_TABLE, kind = .Storage_Buffer}, {slot = TLAS_SLOT_SOURCE, kind = .Storage_Buffer}, {slot = TLAS_SLOT_NATIVE, kind = .Storage_Buffer_RW}}
	if len(code.bindings) != len(wanted) {return "the translation of TLAS instances binds its table, its source and its output alone"}
	for want in wanted {
		found := false
		for binding in code.bindings {found ||= binding.slot == want.slot && binding.kind == want.kind}
		if !found {return "the translation of TLAS instances binds them at TLAS_SLOT_TABLE, TLAS_SLOT_SOURCE and TLAS_SLOT_NATIVE"}
	}
	return ""
}

Features :: struct {
	ray_query:           bool, // hardware acceleration structures + inline ray queries
	draw_indirect_count: bool,
	texture_bc:          bool, // the BC block compressed formats can be sampled
	timestamps:          bool, // cmd_timestamp intervals while timestamps_want is on; else one "frame" interval
	validation:          bool, // API validation is active
	clip_distance:       bool, // a vertex shader can clip by planes of its own
}

Device_Type :: enum u8 {Other, Integrated, Discrete, Virtual, CPU}

Device_Info :: struct {
	backend:              Backend,
	name:                 string,
	type:                 Device_Type,
	features:             Features,
	max_texture_size:     u32,
	max_texture_layers:   u32, // of an array or the faces of cube arrays
	timestamp_period_ns:  f32,
	uniform_alignment:    u64,
	storage_alignment:    u64,
	max_storage_range:    u64,    // bytes one storage buffer binding spans
	memory:               u64,    // bytes of the memory the device keeps its resources in; 0: unknown
}

// Surface sources are provided by the platform layer, keeping the RHI free of
// any windowing library. Vulkan asks the platform to create a VkSurfaceKHR for
// the instance; Metal receives the CAMetalLayer.
Vulkan_Surface_Proc :: #type proc(instance: rawptr, user: rawptr) -> (surface: u64, ok: bool)

Surface_Desc :: struct {
	vulkan_create:       Vulkan_Surface_Proc,
	vulkan_user:         rawptr,
	metal_layer:         rawptr,
	width, height:       u32,
	vsync:               bool,
}

// How many resources of each kind a device holds at once; a kind left at zero
// takes its default. Creating one more returns the zero handle.
Device_Capacities :: struct {
	buffers, textures, samplers, pipelines, accels: int,
	deletions: int, // destroyed objects a frame slot keeps until the GPU finished it
}

DEFAULT_DEVICE_CAPACITIES :: Device_Capacities{buffers = 4096, textures = 8192, samplers = 64, pipelines = 512, accels = 16384, deletions = 4096}

Device_Desc :: struct {
	app_name:                   cstring,
	validation:                 bool,     // also enabled with MIRAI_VALIDATION=1
	allow_hardware_ray_tracing: bool,     // Vulkan: false, or MIRAI_RT=software, has the device report no ray queries, so rays are traced by software; Metal always traces them by hardware
	vulkan_instance_extensions: []cstring, // window system extensions from the platform layer
	upload_bytes_per_frame:     u64,      // transient ring capacity per frame in flight
	preferred_device:           string,   // substring of the adapter name; MIRAI_GPU overrides
	// The window the device presents to, made with the device: only a GPU that
	// presents to it is chosen. Zero: no window, frames draw only into textures.
	surface:                    Surface_Desc,
	pipeline_cache_path:        string,   // Vulkan: compiled pipelines persisted across runs ("" = memory only)
	capacities:                 Device_Capacities,
	allocator:                  runtime.Allocator, // of the device and its tables; context.allocator when unset
	on_message:                 Message_Proc,      // presents errors and validation reports; nil keeps them silent
	message_user:               rawptr,
	// Vulkan: held around the calls in which the loader walks or changes the
	// drivers of every instance of the process (opening it, creating and
	// destroying instance and device, listing physical devices, naming an
	// object). An application that creates or destroys devices on several
	// threads owns one and gives the same to all of them; nil when it uses one
	// thread. Metal does not read it.
	loader_lock:                ^sync.Mutex,
}

VALIDATION_HISTORY :: 16 // validation messages a device keeps
VALIDATION_MESSAGE_BYTES :: 512

// Loader_Warning: an error of the Vulkan loader or of a layer that is not the
// validation layer. It does not count as a validation error.
Message_Kind :: enum u8 {Error, Validation_Error, Validation_Warning, Loader_Warning}
// May be called from a driver thread while a device call is in progress.
Message_Proc :: #type proc(kind: Message_Kind, text: string, user: rawptr)

// A Message_Proc for tools and tests: writes every message to stderr.
message_print :: proc(kind: Message_Kind, text: string, user: rawptr) {
	prefix: string
	switch kind {
	case .Error:              prefix = "rhi:"
	case .Validation_Error:   prefix = "[validation]"
	case .Validation_Warning: prefix = "[validation warning]"
	case .Loader_Warning:     prefix = "[loader]"
	}
	fmt.eprintln(prefix, text)
}

// Why a device stopped working. From then on every call that submits or
// waits returns at once without the GPU, and nothing made on the device works
// again: its owner destroys it with everything made on it.
Device_Failure :: enum u8 {
	None,
	Lost, // the API reported the device lost: the GPU was reset (its watchdog, a fault such as an access out of bounds) or removed
	Hung, // work given to the GPU did not finish: a wait passed GPU_WAIT_LIMIT_NS, or the watchdog of Metal stopped it
}

// Nanoseconds a wait for the GPU lasts before its work counts as hung. Above
// what drivers grant a submission before they reset the GPU (2 s on
// Windows), so a GPU they reset reports Lost first.
GPU_WAIT_LIMIT_NS :: u64(20_000_000_000)
FAILURE_TEXT_BYTES :: 512

// What stopped the device, with the call that found it and what the driver
// said; None and "" while it works. The text holds while the device lives.
device_failure :: proc(d: ^Device) -> (failure: Device_Failure, text: string) {
	sync.guard(&d.message_lock)
	return d.failure, d.failure_text
}

// Makes the next submission report the device lost, as the API does after a
// reset of the GPU, once its work went and completed: what a test of the
// reaction to a loss provokes without resetting the GPU of the machine.
device_lose :: proc(d: ^Device) {d.lose_asked = true}

// Whether device_lose asked the submission that just went to report a loss.
@(private)
device_lose_take :: proc(d: ^Device) -> bool {
	asked := d.lose_asked
	d.lose_asked = false
	d.lose_provoked ||= asked
	return asked
}

// The first failure of the device, as its error too; later ones change nothing.
@(private)
device_fail :: proc(d: ^Device, failure: Device_Failure, format: string, args: ..any) {
	sync.guard(&d.message_lock)
	if d.failure != .None {return}
	text := strings.builder_from_bytes(d.failure_buffer[:])
	fmt.sbprintf(&text, format, ..args)
	if d.lose_provoked {strings.write_string(&text, " (provoked by device_lose)")}
	d.failure, d.failure_text = failure, strings.to_string(text)
	d.error = string(d.error_buffer[:copy(d.error_buffer[:], d.failure_text)])
	if d.on_message != nil {d.on_message(.Error, d.error, d.message_user)}
}

Device_Stats :: struct {
	buffers, textures, samplers, pipelines, accels: int, // alive, of those the user made: what it has to destroy
	exhausted:          int, // creations refused because a pool was full, and transients refused
	deletion_overflows: int, // times a frame slot held more destroyed objects than its capacity
	oversized:          int, // transients past the frame ring, each given a buffer for its frame
	host_memory:        int, // Vulkan: resources of GPU memory placed in system memory because device memory was full
}

@(private)
device_capacities :: proc "contextless" (requested: Device_Capacities) -> Device_Capacities {
	c := requested
	defaults := DEFAULT_DEVICE_CAPACITIES
	if c.buffers <= 0 {c.buffers = defaults.buffers}
	if c.textures <= 0 {c.textures = defaults.textures}
	if c.samplers <= 0 {c.samplers = defaults.samplers}
	if c.pipelines <= 0 {c.pipelines = defaults.pipelines}
	if c.accels <= 0 {c.accels = defaults.accels}
	if c.deletions <= 0 {c.deletions = defaults.deletions}
	return c
}

// Whether a pool takes one more resource; a full pool is counted and reported.
@(private)
device_room :: proc(d: ^Device, pool: ^Pool($T), what: string) -> bool {
	if pool_has_room(pool) {return true}
	sync.atomic_add(&d.stats.exhausted, 1)
	set_error(d, "the device holds its %d %s already", len(pool.items), what)
	return false
}

device_stats :: proc(d: ^Device) -> Device_Stats {
	s := d.stats
	s.buffers, s.textures, s.samplers, s.pipelines, s.accels = d.buffers.count, d.textures.count, d.samplers.count, d.pipelines.count, d.accels.count
	buffers, textures, pipelines := device_own(d)
	s.buffers, s.textures, s.pipelines = s.buffers - buffers, s.textures - textures, s.pipelines - pipelines
	return s
}

// Transient memory of the frame being recorded. Valid until the frame slot is
// reused (MAX_FRAMES_IN_FLIGHT frames later).
Transient :: struct {
	ptr:    rawptr,
	buffer: Buffer,
	offset: u64,
	size:   u64,
}

Gpu_Timing :: struct {
	name: string,
	ms:   f32,
	// The interval on the clock of time.tick_now, in nanoseconds. GPU
	// timestamps are converted with a CPU and GPU pair sampled at collection
	// (Metal, and Vulkan with calibrated timestamps); without calibration Vulkan
	// places the last timestamp of the frame at the moment it is collected, so
	// its intervals keep their length but come late.
	start_ns: i64,
	end_ns:   i64,
}

MAX_TIMESTAMPS :: 256
// Bytes of the name of a timestamp that are kept; a longer one is cut.
MAX_TIMESTAMP_NAME_BYTES :: 64

// Oversized transients one frame holds.
MAX_FRAME_OVERSIZED :: 16

// Transient memory from the ring of the frame being recorded. Past the room of
// the ring it gets a buffer of its own, released with the frame, so an upload
// of any size reaches the GPU in the frame that asks for it: a load, or a
// growth that dirties whole tables, is a frame that may allocate.
frame_alloc :: proc(d: ^Device, size: u64, alignment: u64 = 256) -> Transient {
	// Between frames the slot may still be in flight and frame_begin resets
	// the ring, so transient memory only exists while a frame is recorded.
	if !d.in_frame {set_error(d, "frame_alloc outside a frame: transient memory exists between frame_begin and frame_end"); return {}}
	f := &d.frames[d.slot]
	align := max(alignment, d.info.uniform_alignment, d.info.storage_alignment, 16)
	offset := align_up(f.upload_used, align)
	if offset <= f.upload_size && size <= f.upload_size - offset {
		f.upload_used = offset + size
		return {ptr = &f.upload_ptr[offset], buffer = f.upload, offset = offset, size = size}
	}
	if size > d.info.max_storage_range || f.oversized_count == MAX_FRAME_OVERSIZED {
		d.stats.exhausted += 1
		set_error(d, "transient of %d bytes refused: past the frame ring of %d bytes one takes a buffer of at most %d bytes, %d per frame", size, f.upload_size, d.info.max_storage_range, MAX_FRAME_OVERSIZED)
		return {}
	}
	buffer := buffer_create(d, {size = size, usage = TRANSIENT_USAGE, memory = .Upload, name = "frame upload past the ring"})
	if buffer == 0 {return {}}
	f.oversized[f.oversized_count] = buffer
	f.oversized_count += 1
	d.stats.oversized += 1
	return {ptr = buffer_mapped(d, buffer), buffer = buffer, size = size}
}

// The oversized transients go once the GPU finished the frame that ends.
@(private)
frame_oversized_release :: proc(d: ^Device) {
	f := &d.frames[d.slot]
	for buffer in f.oversized[:f.oversized_count] {buffer_destroy(d, buffer)}
	f.oversized_count = 0
}

// Optional helper for typed transient writes.
frame_alloc_typed :: proc(d: ^Device, $T: typeid, count: int) -> ([]T, Transient) {
	t := frame_alloc(d, u64(size_of(T) * count), 16)
	if t.ptr == nil {return nil, t}
	return (cast([^]T)t.ptr)[:count], t
}

align_up :: proc "contextless" (value, alignment: u64) -> u64 {
	if alignment <= 1 {return value}
	return (value + alignment - 1) / alignment * alignment
}

// The bytes of a mip of a texture, tightly packed, of all its layers.
texture_level_bytes :: proc(desc: Texture_Desc, mip: u32) -> u64 {
	area, _ := texture_region_resolve(desc, mip, {})
	row, rows := format_rows(desc.format, area.width, area.height)
	return row * rows * u64(max(desc.layers, 1))
}

// The bytes of every mip of a texture, tightly packed, of all its layers and slices.
texture_desc_bytes :: proc(desc: Texture_Desc) -> (bytes: u64) {
	if desc.format == .Undefined {return 0}
	for mip in 0 ..< max(desc.mip_levels, 1) {bytes += texture_level_bytes(desc, mip) * u64(max(desc.depth >> mip, 1))}
	return
}

// What a texture holds of the memory of the device, less what its driver
// pads: texture_desc_bytes of it. 0 for one that is not there.
texture_bytes :: proc(d: ^Device, texture: Texture) -> u64 {return texture_desc_bytes(texture_desc(d, texture))}

// The format that holds the same bytes without the sRGB encoding.
format_linear :: proc "contextless" (f: Format) -> Format {
	#partial switch f {
	case .RGBA8_Srgb: return .RGBA8_Unorm
	case .BGRA8_Srgb: return .BGRA8_Unorm
	case .BC1_Srgb:   return .BC1_Unorm
	case .BC3_Srgb:   return .BC3_Unorm
	case .BC7_Srgb:   return .BC7_Unorm
	}
	return f
}

// Why cmd_copy_texture cannot copy `mips` mips of a texture from src_mip
// into another from dst_mip, "" when it can: both are 2D and have those mips,
// of one size and as many layers, and their formats hold the same bytes (one
// format, or two that differ only in the sRGB encoding).
texture_copy_problem :: proc "contextless" (src, dst: Texture_Desc, src_mip: u32 = 0, dst_mip: u32 = 0, mips: u32 = 1) -> string {
	if src.depth > 1 || dst.depth > 1 {return "a 3D texture is written by shaders"}
	if mips == 0 || u64(src_mip) + u64(mips) > u64(max(src.mip_levels, 1)) || u64(dst_mip) + u64(mips) > u64(max(dst.mip_levels, 1)) {return "the mips copied are past those of a texture"}
	if max(src.width >> src_mip, 1) != max(dst.width >> dst_mip, 1) || max(src.height >> src_mip, 1) != max(dst.height >> dst_mip, 1) || max(src.layers, 1) != max(dst.layers, 1) {return "the two textures differ in size or layers at the mips copied"}
	if format_linear(src.format) != format_linear(dst.format) {return "the two formats differ in more than the sRGB encoding"}
	return ""
}

// Typed wrappers over the byte-oriented transfer procedures.
buffer_upload_slice :: proc(d: ^Device, buffer: Buffer, offset: u64, data: []$T) -> bool {
	return buffer_upload(d, buffer, offset, ([^]u8)(raw_data(data))[:len(data) * size_of(T)])
}

buffer_read_slice :: proc(d: ^Device, buffer: Buffer, offset: u64, out: []$T) -> bool {
	return buffer_read(d, buffer, offset, ([^]u8)(raw_data(out))[:len(out) * size_of(T)])
}

// GPU tests fail when no device can be created, unless the environment opts
// into skipping them (MIRAI_ALLOW_GPU_SKIP=1, for machines without any Vulkan
// driver). A silent skip would let a broken device path pass the suite.
gpu_skip_allowed :: proc() -> bool {
	value, found := os.lookup_env("MIRAI_ALLOW_GPU_SKIP", context.temp_allocator)
	return found && value == "1"
}

// The most entries the texture table of d grows to: an index of
// texture_table_set below it is always taken.
texture_table_limit :: proc "contextless" (d: ^Device) -> int {return d.table_limit}
