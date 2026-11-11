package mirai_render

import "core:fmt"
import "core:hash"
import "core:mem"
import "mirai:rhi"

// A render pipeline: the passes that make the image of a view, in the order
// they are declared. Each pass says what it reads and writes; the stages of
// the renderer bring their own declaration. Compiling a pipeline checks that
// every pass finds what it reads written before it, leaves out the passes
// whose results nothing reads, and works out when the resources of the
// pipeline itself are in use, so those that never are at once share memory.

// The work of a view, in the stages of the renderer, and the passes of a
// pipeline of its own.
Render_Stage :: enum u8 {
	Custom,       // a pass of the pipeline: record dispatches over the resources it declares
	Geometry,     // culling, G-buffer, depth pyramid, the Simulate and Gbuffer stages of extensions and the selection mask
	Nested,       // the Mask passes of extensions and the G-buffers of the nested views they add
	Surface,      // the Surface passes of extensions
	Direct,       // the sun and the local lights
	Reflections,  // traced reflections of the smoothest surfaces
	World,        // the probe volume, with the first view of the window
	Indirect,     // the contact occlusion of the probe volume
	Composite,    // direct and indirect light, emission
	Lit,          // the Lit passes of extensions: what lies between the eye and the lit opaque scene
	Transparency, // overlays, glass and the Blend stage of extensions
	Resolve,      // temporal anti-aliasing and upscaling
	Output,       // PostProcess stack, tonemap, selection outline and what is drawn over the image
}

// How the Direct stage shadows its lights.
Direct_Mode :: enum u8 {
	Blocks, // each block of 2x2 pixels traces the rays of the frame and the filters share them; thin geometry traces its own
	Traced, // every pixel traces hard shadows of its own: for views shown small
}

// What the passes of a pipeline read and write. Custom0 to Custom47 are made
// by the pipeline that declares them, for each view drawn with it.
Render_Resource :: enum u8 {
	Depth,        // the depth buffer, reversed (1 nearest): stages write it, a custom pass reads it
	Exposure,     // the buffer of the exposure of the view (Gpu_Exposure), as the Output stage of the frame before left it
	Albedo,       // base color, metallic in alpha
	Normal,       // world normal, roughness in alpha
	Emission,     // emission, occlusion in alpha
	Motion,       // motion vectors; alpha: 1 + the index of the nested view of the pixel
	Linear_Depth, // distance along the view; negative in a nested view
	Reflectance,  // F0 and F90 of surfaces that reflect unlike the default
	Hiz,          // the depth pyramid
	Reactive,     // the share of each pixel the Blend stage drew over; zero without a Blend pass
	Highlight,    // the selection mask
	Direct,       // reflected direct light
	Reflections,  // the filtered traced reflections, for the share of each lobe they stand for
	Gi,           // the light around each pixel beside the probe volume: its contact occlusion (r); written by a custom pass in place of the Indirect stage, the diffuse indirect light itself (rgb, RGBA32_Float), which the composite takes in place of the probe volume's and which keeps what the pass left in the frame before
	Probes,       // the irradiance of the probe volume, shared by every view
	Display,      // the image before temporal resolve
	Taa,          // the resolved image at output size, kept for the next frame
	Ldr,          // the final image; for the passes after the Output stage, without what is drawn over it
	Generated,    // the image shown between the frame before and this one, at output size: the passes after the Output stage write it
	Custom0, Custom1, Custom2, Custom3, Custom4, Custom5, Custom6, Custom7,
	Custom8, Custom9, Custom10, Custom11, Custom12, Custom13, Custom14, Custom15,
	Custom16, Custom17, Custom18, Custom19, Custom20, Custom21, Custom22, Custom23,
	Custom24, Custom25, Custom26, Custom27, Custom28, Custom29, Custom30, Custom31,
	Custom32, Custom33, Custom34, Custom35, Custom36, Custom37, Custom38, Custom39,
	Custom40, Custom41, Custom42, Custom43, Custom44, Custom45, Custom46, Custom47,
}

Render_Access :: enum u8 {Read, Write}

Render_Use :: struct {
	resource: Render_Resource,
	access:   Render_Access,
	previous: bool, // what a resource with history held at the end of the previous frame of the view
}

// Of a resource of a pipeline: its size follows the view.
Render_Size :: enum u8 {
	Full,   // the internal resolution of the view
	Output, // the size the view is shown at
	Fixed,  // width and height
}

// Mips of a texture down to one texel.
RENDER_MIPS_ALL :: u8(255)

Render_Resource_Desc :: struct {
	id:            Render_Resource, // Custom0 to Custom47
	format:        rhi.Format,      // a texture: one a compute shader can write (R8, RG8 and RGBA8 unorm, R8 uint, RG16 sint, 16 and 32 bit floats and uints)
	size:          Render_Size,
	width, height: u32,
	shift:         u8,   // Full and Output: halved this many times, rounded up
	align:         u16,  // Full and Output: each side then rounded up to a multiple of it
	mips:          u8,   // of a texture; 0 or 1: one, RENDER_MIPS_ALL: down to one texel
	bytes:         u32,  // a buffer of this many bytes, a multiple of 4, instead of a texture
	pixel_bytes:   u32,  // a buffer of this many bytes, a multiple of 4, for each pixel of its size, instead of a texture
	history:       bool, // two copies that take turns, the one of the frame before read with Render_Use.previous; they start at zero
	kept:          bool, // one copy the passes read and write in place, which keeps what one frame leaves for the next; it starts at zero
}

// The sub-pixel offset of the projection, which a temporal resolve gathers.
Render_Jitter :: enum u8 {
	Resolve, // as the Resolve stage asks: 16 phases while the TAA is on, none without it
	None,
	Upscale, // for a temporal upscaler of the pipeline: 8 phases at the output size, times the square of how much smaller the view is drawn
}

Render_Pass_Desc :: struct {
	stage:  Render_Stage,
	direct: Direct_Mode,  // Direct
	name:   string,       // Custom: for its timing and its errors
	uses:   []Render_Use, // Custom: everything it reads and writes; a stage of the renderer declares its own
	record: Stage_Proc,   // Custom
	user:   rawptr,       // Custom: given to record
}

// Custom passes after the Output stage generate a frame: they read Ldr
// before the Output stage draws over it what it draws over the image and
// write Generated, which a window shows half a frame before Ldr (frame
// generation). They run only for the views of the window of a frame that
// presents; the Output stage then draws the same over both images.
Render_Pipeline_Desc :: struct {
	passes:    []Render_Pass_Desc,
	resources: []Render_Resource_Desc,
	jitter:    Render_Jitter,
}

// A pipeline the renderer compiled. 0: the default one.
Render_Pipeline_Handle :: distinct u64

// The pipelines of the renderer, which are always there.
Standard_Pipeline :: enum u8 {
	Full,  // everything the settings ask for
	Light, // without contact occlusion or traced reflections, each pixel tracing hard shadows: for views shown small
}

RENDER_PIPELINE_CAPACITY :: 16
RENDER_PASS_CAPACITY :: 40
RENDER_USE_CAPACITY :: 16
CUSTOM_RESOURCE_CAPACITY :: 48
RENDER_PASS_NAME_CAPACITY :: 32

@(private)
Plan_Pass :: struct {
	stage:     Render_Stage,
	direct:    Direct_Mode,
	record:    Stage_Proc,
	user:      rawptr,
	uses:      [RENDER_USE_CAPACITY]Render_Use,
	optional:  [RENDER_USE_CAPACITY]bool, // a stage reads it when a pass before wrote it, and does without it otherwise
	use_count: int,
	name:      [RENDER_PASS_NAME_CAPACITY]u8,
	name_size: int,
}

@(private)
Render_Plan :: struct {
	generation:  u32,
	alive:       bool,
	standard:    bool, // one of Standard_Pipeline: never retired
	key:         u64,  // the hash of the description it was compiled from
	asked:       u64,  // the last frame that asked for it
	passes:      [RENDER_PASS_CAPACITY]Plan_Pass,
	pass_count:  int,
	order:       [RENDER_PASS_CAPACITY]u8, // the passes recorded, in their order
	order_count: int,
	stages:      bit_set[Render_Stage],
	direct:      Direct_Mode,
	jitter:      Render_Jitter,
	generates:   bool, // passes after the Output stage write Generated
	gi_given:    bool, // a custom pass writes Gi
	resources:   [CUSTOM_RESOURCE_CAPACITY]Render_Resource_Desc,
	declared:    bit_set[0 ..< CUSTOM_RESOURCE_CAPACITY],
	first_use:   [CUSTOM_RESOURCE_CAPACITY]i8, // the place in order of the first and last pass that uses each resource; -1: none
	last_use:    [CUSTOM_RESOURCE_CAPACITY]i8,
}

@(private)
plan_pass_name :: proc(pass: ^Plan_Pass) -> string {
	if pass.stage != .Custom {return fmt.tprint(pass.stage)}
	return string(pass.name[:pass.name_size])
}

@(private)
custom_index :: proc "contextless" (id: Render_Resource) -> int {return int(id) - int(Render_Resource.Custom0)}

// The resources with a copy of the previous frame.
@(private)
builtin_history :: proc "contextless" (id: Render_Resource) -> bool {return id == .Taa || id == .Hiz}

// What the stages of the renderer read and write.
@(private)
stage_contract :: proc(stage: Render_Stage, pass: ^Plan_Pass) {
	use :: proc(pass: ^Plan_Pass, resource: Render_Resource, access: Render_Access, previous := false, optional := false) {
		pass.uses[pass.use_count] = {resource, access, previous}
		pass.optional[pass.use_count] = optional
		pass.use_count += 1
	}
	reads :: proc(pass: ^Plan_Pass, resources: ..Render_Resource) {for resource in resources {use(pass, resource, .Read)}}
	writes :: proc(pass: ^Plan_Pass, resources: ..Render_Resource) {for resource in resources {use(pass, resource, .Write)}}
	#partial switch stage {
	case .Geometry:
		use(pass, .Hiz, .Read, previous = true)
		writes(pass, .Depth, .Albedo, .Normal, .Emission, .Motion, .Linear_Depth, .Reflectance, .Hiz, .Highlight)
	case .Nested:
		reads(pass, .Depth, .Motion, .Linear_Depth)
		writes(pass, .Depth, .Albedo, .Normal, .Emission, .Motion, .Linear_Depth, .Reflectance)
	case .Surface:
		reads(pass, .Linear_Depth, .Motion, .Albedo, .Normal, .Emission)
		writes(pass, .Albedo, .Normal, .Emission)
	case .Direct:
		reads(pass, .Normal, .Linear_Depth, .Albedo, .Motion)
		use(pass, .Reflectance, .Read, optional = true)
		writes(pass, .Direct)
	case .Reflections:
		reads(pass, .Normal, .Linear_Depth, .Albedo, .Motion)
		use(pass, .Reflectance, .Read, optional = true)
		use(pass, .Probes, .Read, optional = true)
		writes(pass, .Reflections)
	case .World:
		writes(pass, .Probes)
	case .Indirect:
		reads(pass, .Normal, .Linear_Depth, .Motion)
		writes(pass, .Gi)
	case .Composite:
		reads(pass, .Albedo, .Normal, .Emission, .Linear_Depth, .Motion, .Direct)
		for resource in ([]Render_Resource{.Reflectance, .Reflections, .Gi, .Probes}) {use(pass, resource, .Read, optional = true)}
		writes(pass, .Display)
	case .Lit:
		reads(pass, .Linear_Depth, .Display)
		writes(pass, .Display)
	case .Transparency:
		reads(pass, .Depth, .Linear_Depth, .Normal, .Direct, .Display)
		use(pass, .Probes, .Read, optional = true)
		writes(pass, .Depth, .Display, .Reactive)
	case .Resolve:
		reads(pass, .Display, .Motion, .Linear_Depth)
		use(pass, .Reactive, .Read, optional = true)
		use(pass, .Taa, .Read, previous = true, optional = true)
		writes(pass, .Taa)
	case .Output:
		reads(pass, .Display, .Linear_Depth, .Motion, .Normal, .Emission, .Albedo)
		use(pass, .Taa, .Read, optional = true)
		use(pass, .Highlight, .Read, optional = true)
		writes(pass, .Ldr)
	}
}

// Of the resources of the renderer, those a pass of a pipeline may write: the
// ones a compute shader can.
@(private)
custom_writable :: proc "contextless" (id: Render_Resource) -> bool {
	#partial switch id {
	case .Direct, .Reflections, .Gi, .Display, .Taa, .Generated: return true
	}
	return id >= .Custom0
}

@(private)
custom_format_valid :: proc "contextless" (format: rhi.Format) -> bool {
	#partial switch format {
	case .R8_Unorm, .RG8_Unorm, .RGBA8_Unorm, .R8_Uint, .RG16_Sint, .R16_Float, .RG16_Float, .RGBA16_Float, .R32_Float, .RG32_Float, .RGBA32_Float, .R32_Uint, .RG32_Uint, .RGBA32_Uint: return true
	}
	return false
}

// Checks a description and makes the plan of what a view records with it. The
// error says what is wrong and how to put it right.
@(private)
plan_compile :: proc(plan: ^Render_Plan, desc: Render_Pipeline_Desc, buffer: []u8) -> (ok: bool, error: string) {
	fail :: proc(buffer: []u8, format: string, args: ..any) -> (bool, string) {
		return false, fmt.bprintf(buffer, format, ..args)
	}
	if len(desc.passes) == 0 || len(desc.passes) > RENDER_PASS_CAPACITY {
		return fail(buffer, "render pipeline: it has %d passes; it needs between 1 and %d", len(desc.passes), RENDER_PASS_CAPACITY)
	}
	if len(desc.resources) > CUSTOM_RESOURCE_CAPACITY {
		return fail(buffer, "render pipeline: it declares %d resources; at most %d (Custom0 to Custom47)", len(desc.resources), CUSTOM_RESOURCE_CAPACITY)
	}
	for resource in desc.resources {
		if resource.id < .Custom0 || int(resource.id) > int(Render_Resource.Custom47) {
			return fail(buffer, "render pipeline: it declares %v; a pipeline declares Custom0 to Custom47, and the renderer makes the others", resource.id)
		}
		index := custom_index(resource.id)
		if index in plan.declared {return fail(buffer, "render pipeline: %v is declared twice", resource.id)}
		if resource.bytes > 0 && resource.pixel_bytes > 0 {
			return fail(buffer, "render pipeline: %v has bytes and pixel_bytes; a buffer has a size of its own (bytes) or one that follows the view (pixel_bytes)", resource.id)
		}
		if resource.size == .Fixed && (resource.shift > 0 || resource.align > 1) {
			return fail(buffer, "render pipeline: %v is Fixed with a shift or an align; those shape a size that follows the view, Full or Output", resource.id)
		}
		if resource.shift > 13 {return fail(buffer, "render pipeline: %v has shift %d; at most 13", resource.id, resource.shift)}
		if resource.history && resource.kept {return fail(buffer, "render pipeline: %v is history and kept; history keeps two copies that take turns, kept one that the passes change in place", resource.id)}
		if bytes := max(resource.bytes, resource.pixel_bytes); bytes > 0 {
			if bytes % 4 != 0 {return fail(buffer, "render pipeline: %v has %d bytes; a buffer has a multiple of 4", resource.id, bytes)}
			if resource.pixel_bytes > 0 && resource.size == .Fixed {
				return fail(buffer, "render pipeline: %v has pixel_bytes and a Fixed size; give it bytes, or a size that follows the view", resource.id)
			}
			if resource.mips > 1 {return fail(buffer, "render pipeline: %v is a buffer with mips; only a texture has them", resource.id)}
		} else {
			if !custom_format_valid(resource.format) {
				return fail(buffer, "render pipeline: %v has format %v; use R8_Unorm, RGBA8_Unorm or a format of 16 or 32 bit floats or uints, which a compute shader can write, or give it bytes to make it a buffer", resource.id, resource.format)
			}
			if resource.size == .Fixed && (resource.width == 0 || resource.height == 0 || resource.width > 16384 || resource.height > 16384) {
				return fail(buffer, "render pipeline: %v is %dx%d; a Fixed size is between 1 and 16384 on each side", resource.id, resource.width, resource.height)
			}
		}
		plan.resources[index] = resource
		plan.declared += {index}
	}
	seen: bit_set[Render_Stage]
	output_at := -1
	for &pass, at in desc.passes {
		target := &plan.passes[at]
		target.stage, target.direct = pass.stage, pass.direct
		if pass.stage != .Custom {
			if pass.stage in seen {return fail(buffer, "render pipeline: pass %d is a second %v stage; a pipeline has each stage once", at, pass.stage)}
			if len(pass.uses) > 0 || pass.record != nil {
				return fail(buffer, "render pipeline: pass %d is the %v stage, which declares its own resources and records itself; leave uses and record empty", at, pass.stage)
			}
			seen += {pass.stage}
			if pass.stage == .Output {output_at = at}
			stage_contract(pass.stage, target)
			continue
		}
		if pass.record == nil {return fail(buffer, "render pipeline: custom pass %d (%s) has no record procedure", at, pass.name)}
		if len(pass.name) == 0 || len(pass.name) >= RENDER_PASS_NAME_CAPACITY {
			return fail(buffer, "render pipeline: custom pass %d needs a name of 1 to %d bytes", at, RENDER_PASS_NAME_CAPACITY - 1)
		}
		if len(pass.uses) == 0 || len(pass.uses) > RENDER_USE_CAPACITY {
			return fail(buffer, "render pipeline: custom pass %s declares %d uses; it needs between 1 and %d", pass.name, len(pass.uses), RENDER_USE_CAPACITY)
		}
		for use in pass.uses {
			if int(use.resource) > int(Render_Resource.Custom47) {return fail(buffer, "render pipeline: custom pass %s uses an unknown resource", pass.name)}
			if use.resource >= .Custom0 && custom_index(use.resource) not_in plan.declared {
				return fail(buffer, "render pipeline: custom pass %s uses %v, which the pipeline does not declare in resources", pass.name, use.resource)
			}
			if use.resource == .Depth && use.access == .Write {return fail(buffer, "render pipeline: custom pass %s writes Depth, which only stages write; read it, or write Linear_Depth in a resource of its own", pass.name)}
			if use.resource == .Exposure && use.access == .Write {return fail(buffer, "render pipeline: custom pass %s writes Exposure, which the Output stage measures; read it", pass.name)}
			if use.access == .Write && !custom_writable(use.resource) {
				return fail(buffer, "render pipeline: custom pass %s writes %v, which a custom pass can only read; it may write Direct, Reflections, Gi, Display, Taa, Generated or a resource of its own", pass.name, use.resource)
			}
			after := output_at >= 0
			if use.access == .Write && after && use.resource < .Custom0 && use.resource != .Generated {
				return fail(buffer, "render pipeline: custom pass %s comes after the Output stage and writes %v; a pass after Output generates a frame, and writes only Generated and resources of its own", pass.name, use.resource)
			}
			if use.resource == .Generated && use.access == .Write && !after {
				return fail(buffer, "render pipeline: custom pass %s writes Generated before the Output stage; the passes that generate a frame come after Output, which leaves them Ldr", pass.name)
			}
			if use.previous {
				history := builtin_history(use.resource) if use.resource < .Custom0 else plan.resources[custom_index(use.resource)].history
				if !history || use.access == .Write {
					return fail(buffer, "render pipeline: custom pass %s reads the previous %v; only Taa, Hiz and resources declared with history have one, and it is read only", pass.name, use.resource)
				}
			}
		}
		target.record, target.user = pass.record, pass.user
		target.use_count = copy(target.uses[:], pass.uses)
		target.name_size = copy(target.name[:], pass.name)
	}
	if .Geometry not_in seen || .Composite not_in seen || .Output not_in seen {
		return fail(buffer, "render pipeline: it has no %v stage; every pipeline draws its view with Geometry, lights it in Composite and finishes it in Output", .Geometry not_in seen ? Render_Stage.Geometry : .Composite not_in seen ? Render_Stage.Composite : Render_Stage.Output)
	}
	if desc.jitter == .Resolve && .Resolve not_in seen {
		writes_taa := false
		for &pass in plan.passes[:len(desc.passes)] {
			for use in pass.uses[:pass.use_count] {writes_taa ||= pass.stage == .Custom && use.resource == .Taa && use.access == .Write}
		}
		if writes_taa {return fail(buffer, "render pipeline: a custom pass writes Taa in place of the Resolve stage, and the pipeline asks for the jitter of that stage; give it jitter Upscale for a temporal upscaler, or None", )}
	}
	plan.jitter = desc.jitter
	plan.pass_count = len(desc.passes)
	// What each pass reads is written before it, or is the previous frame's.
	for &pass, at in plan.passes[:plan.pass_count] {
		for use, u in pass.uses[:pass.use_count] {
			if use.access != .Read || use.previous || use.resource == .Probes || use.resource == .Exposure || pass.optional[u] {continue}
			if use.resource >= .Custom0 && plan.resources[custom_index(use.resource)].kept {continue}
			if plan_writer(plan, use.resource, at) < 0 {
				return fail(buffer, "render pipeline: pass %d (%s) reads %v, which no pass before it writes; declare a pass that writes it earlier", at, plan_pass_name(&pass), use.resource)
			}
		}
	}
	// The passes something reads from, back from the output.
	needed: bit_set[0 ..< RENDER_PASS_CAPACITY]
	for at := plan.pass_count - 1; at >= 0; at -= 1 {
		pass := &plan.passes[at]
		writes_generated := false
		for use in pass.uses[:pass.use_count] {writes_generated ||= use.resource == .Generated && use.access == .Write}
		if pass.stage != .Output && !writes_generated && at not_in needed {continue}
		needed += {at}
		for use in pass.uses[:pass.use_count] {
			if use.access != .Read {continue}
			writer := plan_writer(plan, use.resource, plan.pass_count if use.previous else at)
			if writer >= 0 {needed += {writer}}
		}
	}
	// A pass that writes a resource with history is needed when a later frame reads it.
	for &pass, at in plan.passes[:plan.pass_count] {
		if at not_in needed {continue}
		for use in pass.uses[:pass.use_count] {
			kept := use.resource >= .Custom0 && plan.resources[custom_index(use.resource)].kept
			if use.access == .Read && (use.previous || kept) {
				if writer := plan_writer(plan, use.resource, plan.pass_count); writer >= 0 {needed += {writer}}
			}
		}
	}
	for &index in plan.first_use {index = -1}
	for &index in plan.last_use {index = -1}
	for &pass, at in plan.passes[:plan.pass_count] {
		if at not_in needed {continue}
		place := i8(plan.order_count)
		plan.order[plan.order_count] = u8(at)
		plan.order_count += 1
		plan.stages += {pass.stage}
		if pass.stage == .Direct {plan.direct = pass.direct}
		for use in pass.uses[:pass.use_count] {
			plan.generates ||= use.resource == .Generated && use.access == .Write
			plan.gi_given ||= pass.stage == .Custom && use.resource == .Gi && use.access == .Write
		}
		if plan.gi_given && .Indirect in seen {return fail(buffer, "render pipeline: custom pass %s writes Gi and the pipeline has the Indirect stage, which writes it too; leave the Indirect stage out to give Gi", plan_pass_name(&pass))}
		for use in pass.uses[:pass.use_count] {
			if use.resource < .Custom0 {continue}
			index := custom_index(use.resource)
			if plan.first_use[index] < 0 {plan.first_use[index] = place}
			plan.last_use[index] = place
		}
	}
	return true, ""
}

// The last pass before `before` that writes a resource; -1: none.
@(private)
plan_writer :: proc(plan: ^Render_Plan, resource: Render_Resource, before: int) -> int {
	for at := before - 1; at >= 0; at -= 1 {
		pass := &plan.passes[at]
		for use in pass.uses[:pass.use_count] {
			if use.resource == resource && use.access == .Write {return at}
		}
	}
	return -1
}

@(private)
pipeline_key :: proc(desc: Render_Pipeline_Desc) -> u64 {
	h := hash.fnv64a(nil)
	mix :: proc(h: u64, bytes: []u8) -> u64 {return hash.fnv64a(bytes, h)}
	value :: proc(h: u64, v: ^$T) -> u64 {return hash.fnv64a(([^]u8)(v)[:size_of(T)], h)}
	for &pass in desc.passes {
		h = value(h, &pass.stage)
		h = value(h, &pass.direct)
		h = mix(h, transmute([]u8)pass.name)
		for &use in pass.uses {h = value(h, &use)}
		record := rawptr(pass.record)
		h = value(h, &record)
		h = value(h, &pass.user)
	}
	for &resource in desc.resources {h = value(h, &resource)}
	jitter := desc.jitter
	h = value(h, &jitter)
	return h
}

@(private)
plan_handle :: proc(r: ^Renderer, index: int) -> Render_Pipeline_Handle {
	return Render_Pipeline_Handle(u64(r.plans[index].generation) << 32 | u64(index + 1))
}

@(private)
plan_find :: proc(r: ^Renderer, handle: Render_Pipeline_Handle) -> ^Render_Plan {
	index := int(u32(u64(handle))) - 1
	if index < 0 || index >= len(r.plans) {return nil}
	plan := &r.plans[index]
	if !plan.alive || plan.generation != u32(u64(handle) >> 32) {return nil}
	return plan
}

// The pipeline of a description. The renderer compiles it the first time it
// is asked for and keeps it while it is asked for; one that a frame did not
// ask for makes room for another. 0 and the reason when the description is
// wrong. The procedures and user pointers of its passes are part of it.
renderer_pipeline :: proc(r: ^Renderer, desc: Render_Pipeline_Desc) -> (Render_Pipeline_Handle, string) {
	key := pipeline_key(desc)
	place := -1
	for &plan, index in r.plans {
		if plan.alive && plan.key == key {
			plan.asked = r.frame
			return plan_handle(r, index), ""
		}
		if plan.standard {continue}
		// A free place, or the one asked for longest ago, but not by this frame.
		if !plan.alive {
			if place < 0 || r.plans[place].alive {place = index}
		} else if plan.asked < r.frame && (place < 0 || r.plans[place].alive && plan.asked < r.plans[place].asked) {
			place = index
		}
	}
	if place < 0 {return 0, fmt.bprintf(r.error_buffer[:], "render pipeline: the %d places are in use in this frame", RENDER_PIPELINE_CAPACITY)}
	plan := &r.plans[place]
	generation := plan.generation + 1
	plan^ = {generation = generation}
	ok, error := plan_compile(plan, desc, r.error_buffer[:])
	if !ok {
		plan^ = {generation = generation}
		r.error = error
		return 0, error
	}
	plan.alive, plan.key, plan.asked = true, key, r.frame
	return plan_handle(r, place), ""
}

// The passes of a standard pipeline.
standard_pipeline_passes :: proc(kind: Standard_Pipeline) -> []Render_Pass_Desc {
	@(static, rodata) full := [?]Render_Pass_Desc{
		{stage = .Geometry}, {stage = .Nested}, {stage = .Surface}, {stage = .Direct}, {stage = .Reflections}, {stage = .World},
		{stage = .Indirect}, {stage = .Composite}, {stage = .Lit}, {stage = .Transparency}, {stage = .Resolve}, {stage = .Output},
	}
	@(static, rodata) light := [?]Render_Pass_Desc{
		{stage = .Geometry}, {stage = .Nested}, {stage = .Surface}, {stage = .Direct, direct = .Traced}, {stage = .World},
		{stage = .Composite}, {stage = .Lit}, {stage = .Transparency}, {stage = .Resolve}, {stage = .Output},
	}
	switch kind {
	case .Full:       return full[:]
	case .Light:      return light[:]
	}
	return nil
}

@(private)
pipelines_init :: proc(r: ^Renderer) -> bool {
	for kind in Standard_Pipeline {
		handle, error := renderer_pipeline(r, {passes = standard_pipeline_passes(kind)})
		if handle == 0 {set_error(r, "standard pipeline %v: %s", kind, error); return false}
		plan_find(r, handle).standard = true
		r.standard_pipelines[kind] = handle
	}
	return true
}

renderer_standard_pipeline :: proc(r: ^Renderer, kind: Standard_Pipeline) -> Render_Pipeline_Handle {return r.standard_pipelines[kind]}

// The pipeline of the views of the window in the next frame; 0: Full. It
// lasts for that frame alone, as the passes of extensions do.
renderer_main_pipeline :: proc(r: ^Renderer, pipeline: Render_Pipeline_Handle) -> bool {
	if pipeline != 0 && plan_find(r, pipeline) == nil {return false}
	r.main_pipeline = pipeline
	return true
}

// The plan a view is drawn with: its own, or the main one of the frame for a
// view of the window, or Full.
@(private)
view_plan :: proc(r: ^Renderer, pipeline: Render_Pipeline_Handle, window: bool) -> (Render_Pipeline_Handle, ^Render_Plan) {
	handle := pipeline
	if handle == 0 && window {handle = r.main_pipeline}
	if plan := plan_find(r, handle); plan != nil {return handle, plan}
	handle = r.standard_pipelines[.Full]
	return handle, plan_find(r, handle)
}

// The resources of a pipeline in a view: two of each with history.
@(private)
View_Resource :: struct {
	textures:    [2]rhi.Texture,
	buffers:     [2]rhi.Buffer,
	owned:       bool, // made for it; otherwise it shares those of an earlier resource whose uses end before its own begin
	needs_clear: bool,
}

@(private)
view_resources_free :: proc(r: ^Renderer, view: ^View_State) {
	for &resource in view.resources {
		if resource.owned {
			for texture in resource.textures {if texture != 0 {rhi.texture_destroy(r.device, texture)}}
			for buffer in resource.buffers {if buffer != 0 {rhi.buffer_destroy(r.device, buffer)}}
		}
		resource = {}
	}
}

// Draws a view with a pipeline from now on: one that changes starts its
// histories again and makes the resources of the new one.
@(private)
view_pipeline_prepare :: proc(r: ^Renderer, view: ^View_State, handle: Render_Pipeline_Handle, plan: ^Render_Plan) -> bool {
	t := &view.targets
	size := [4]u32{t.width, t.height, t.output_width, t.output_height}
	view.resources_made = false
	if view.pipeline != handle || view.resources_size != size {
		view_resources_free(r, view)
		if view.pipeline != handle && view.pipeline != 0 {view_camera_cut(view)}
		view.pipeline, view.resources_size = handle, size
	}
	for index in 0 ..< CUSTOM_RESOURCE_CAPACITY {
		if index not_in plan.declared || plan.first_use[index] < 0 {continue}
		resource := &view.resources[index]
		if resource.textures[0] != 0 || resource.buffers[0] != 0 {continue}
		desc := plan.resources[index]
		if !desc.history && !desc.kept {
			// The memory of an earlier resource of the same kind whose last use comes before this one's first.
			for prior in 0 ..< index {
				other := plan.resources[prior]
				other.id = desc.id
				if prior not_in plan.declared || other != desc || plan.first_use[prior] < 0 || plan.last_use[prior] >= plan.first_use[index] {continue}
				free := true
				for sharer in 0 ..< index {
					if view.resources[sharer].textures != view.resources[prior].textures || view.resources[sharer].buffers != view.resources[prior].buffers {continue}
					if plan.first_use[sharer] <= plan.last_use[index] && plan.first_use[index] <= plan.last_use[sharer] {free = false; break}
				}
				if !free {continue}
				resource.textures, resource.buffers = view.resources[prior].textures, view.resources[prior].buffers
				break
			}
			if resource.textures[0] != 0 || resource.buffers[0] != 0 {continue}
		}
		resource.owned, resource.needs_clear = true, desc.history || desc.kept
		view.resources_made = true
		width, height := resource_size(t, desc)
		for at in 0 ..< (2 if desc.history else 1) {
			if bytes := u64(desc.bytes) if desc.bytes > 0 else u64(desc.pixel_bytes) * u64(width) * u64(height); bytes > 0 {
				resource.buffers[at] = rhi.buffer_create(r.device, {size = bytes, usage = {.Storage, .Transfer_Dst}, name = "pipeline buffer"})
				if resource.buffers[at] == 0 {set_error(r, "pipeline buffer %v: %s", desc.id, rhi.device_error(r.device)); return false}
				continue
			}
			mips := u32(max(desc.mips, 1))
			if desc.mips == RENDER_MIPS_ALL {mips = mip_count(width, height)}
			mips = min(mips, mip_count(width, height))
			resource.textures[at] = rhi.texture_create(r.device, {width = width, height = height, mip_levels = mips, format = desc.format, usage = HISTORY_USAGE, name = "pipeline texture"})
			if resource.textures[at] == 0 {set_error(r, "pipeline texture %v: %s", desc.id, rhi.device_error(r.device)); return false}
		}
	}
	if !view.has_previous {
		// After a cut what the resources kept from the frame before is not of this view.
		for index in 0 ..< CUSTOM_RESOURCE_CAPACITY {
			desc := plan.resources[index]
			if index in plan.declared && (desc.history || desc.kept) && view.resources[index].owned {view.resources[index].needs_clear = true}
		}
	}
	if view.resources_made || !view.has_previous {view.resources_frames = 0}
	return true
}

// The size of a resource of a pipeline in a view, in pixels.
@(private)
resource_size :: proc "contextless" (t: ^Targets, desc: Render_Resource_Desc) -> (width, height: u32) {
	width, height = desc.width, desc.height
	switch desc.size {
	case .Full:   width, height = t.width, t.height
	case .Output: width, height = t.output_width, t.output_height
	case .Fixed:  return
	}
	if desc.shift > 0 {
		width, height = (width + (1 << desc.shift) - 1) >> desc.shift, (height + (1 << desc.shift) - 1) >> desc.shift
	}
	if align := u32(max(desc.align, 1)); align > 1 {
		width, height = (width + align - 1) / align * align, (height + align - 1) / align * align
	}
	return max(width, 1), max(height, 1)
}

// The mips of a texture down to one texel.
@(private)
mip_count :: proc "contextless" (width, height: u32) -> u32 {
	levels := u32(1)
	for max(width, height) >> levels > 0 && levels < rhi.MAX_TEXTURE_MIPS {levels += 1}
	return levels
}

// A resource of a view in the pass being recorded.
@(private)
pass_resource_of :: proc(p: ^Pass, resource: Render_Resource, previous: bool) -> (rhi.Texture, rhi.Buffer) {
	t := p.t
	at := p.previous if previous else p.current
	#partial switch resource {
	case .Depth:        return t.depth, 0
	case .Exposure:     return 0, p.view.exposure
	case .Albedo:       return t.albedo, 0
	case .Normal:       return t.normal, 0
	case .Emission:     return t.emission, 0
	case .Motion:       return t.motion, 0
	case .Linear_Depth: return t.linear_depth, 0
	case .Reflectance:  return texture_or_dummy(p.r, t.surface), 0
	case .Hiz:          return t.hiz[at], 0
	case .Reactive:     return t.reactive, 0
	case .Highlight:    return texture_or_dummy(p.r, t.highlight), 0
	case .Direct:       return t.direct, 0
	case .Reflections:  return texture_or_dummy(p.r, p.reflections), 0
	case .Gi:           return p.gi, 0
	case .Probes:       return texture_or_dummy(p.r, p.r.ddgi.irradiance if p.r.ddgi.valid else 0), 0
	case .Display:      return t.display, 0
	case .Taa:          return t.taa[at], 0
	case .Ldr:          return t.ldr, 0
	case .Generated:    return t.generated, 0
	}
	if resource < .Custom0 {return 0, 0}
	index := custom_index(resource)
	if !p.plan.resources[index].history {at = 0}
	own := &p.view.resources[index]
	return own.textures[at], own.buffers[at]
}

// A pass of a pipeline: its resources with history are cleared the first time.
@(private)
custom_pass_record :: proc(p: ^Pass, pass: ^Plan_Pass) {
	for index in 0 ..< CUSTOM_RESOURCE_CAPACITY {
		resource := &p.view.resources[index]
		if !resource.needs_clear {continue}
		for texture in resource.textures {if texture != 0 {clear_textures(p.cmd, texture)}}
		for buffer in resource.buffers {if buffer != 0 {rhi.cmd_fill_buffer(p.cmd, buffer, 0, rhi.buffer_size(p.r.device, buffer), 0)}}
		resource.needs_clear = false
	}
	for use in pass.uses[:pass.use_count] {
		if use.resource == .Exposure && !view_exposure_buffers(p.r, p.cmd, p.view) {return}
	}
	name := string(pass.name[:pass.name_size])
	rhi.cmd_timestamp(p.cmd, name)
	s := Stage_Pass{
		stage = .Custom, pass = p, width = p.t.width, height = p.t.height, eye = p.frame.eye, view_projection = p.unjittered, uses = pass.uses[:pass.use_count],
		origin = p.r.origin,
		output_width = p.t.output_width, output_height = p.t.output_height,
		jitter = p.jitter, previous_jitter = p.view.prev_jitter, jitter_phases = p.jitter_phases,
		camera = p.camera, delta_time = p.r.delta_time,
	}
	if p.view.has_previous && !p.view.resources_made {s.history, s.history_frames = true, p.view.resources_frames}
	pass.record(&s, pass.user)
	bind_scene_table(p)
	// A pass in place of the Resolve stage, an upscaler, writes Taa: the
	// Output stage then finishes its image.
	writes: bit_set[Render_Resource]
	for use in pass.uses[:pass.use_count] {if use.access == .Write {writes += {use.resource}}}
	if .Taa in writes {p.shown = p.t.taa[p.current]} else if .Display in writes {p.shown = p.t.display}
}

// Binds a resource a pass of a pipeline declared at a slot of the pass
// (CUSTOM_PASS_SLOTS): a texture it reads, or one or a buffer it writes; of
// a texture with mips, one of them to write, or all of them to read (-1).
// False when the pass did not declare it that way.
pass_resource :: proc(s: ^Stage_Pass, slot: u32, resource: Render_Resource, previous := false, mip: i32 = -1) -> bool {
	binding, ok := pass_slot(s, slot)
	if s.stage != .Custom || !ok {return false}
	if _, use := custom_pass_use(s, resource, previous); use {
		texture, buffer := pass_resource_of(s.pass, resource, previous)
		if texture != 0 {rhi.cmd_bind_texture(s.pass.cmd, binding, texture, mip); return true}
		if buffer != 0 {rhi.cmd_bind_buffer(s.pass.cmd, binding, buffer); return true}
	}
	return false
}

// How the pass declared a resource.
@(private)
custom_pass_use :: proc(s: ^Stage_Pass, resource: Render_Resource, previous: bool) -> (Render_Access, bool) {
	for use in s.uses {
		if use.resource == resource && use.previous == previous {return use.access, true}
	}
	return .Read, false
}

// Zeroes a resource of the pipeline the pass declares it writes: a texture's
// first mip, or a buffer. False for another.
pass_clear :: proc(s: ^Stage_Pass, resource: Render_Resource) -> bool {
	access, used := custom_pass_use(s, resource, false)
	if s.stage != .Custom || resource < .Custom0 || !used || access != .Write {return false}
	texture, buffer := pass_resource_of(s.pass, resource, false)
	if texture != 0 {clear_textures(s.pass.cmd, texture)}
	if buffer != 0 {rhi.cmd_fill_buffer(s.pass.cmd, buffer, 0, rhi.buffer_size(s.pass.r.device, buffer), 0)}
	return texture != 0 || buffer != 0
}

// Writes bytes into a buffer of the pipeline the pass declares it writes, from
// the memory of the frame: what it then keeps, as the weights of a network,
// is written once, while !history. False when they do not fit in the buffer
// or in the memory of the frame.
pass_resource_write :: proc(s: ^Stage_Pass, resource: Render_Resource, offset: u64, data: rawptr, size: int) -> bool {
	access, used := custom_pass_use(s, resource, false)
	if s.stage != .Custom || resource < .Custom0 || !used || access != .Write || data == nil || size <= 0 {return false}
	_, buffer := pass_resource_of(s.pass, resource, false)
	if buffer == 0 || offset + u64(size) > rhi.buffer_size(s.pass.r.device, buffer) {return false}
	rows := rhi.frame_alloc(s.pass.r.device, u64(size), 16)
	if rows.ptr == nil {return false}
	mem.copy(rows.ptr, data, size)
	rhi.cmd_copy_buffer(s.pass.cmd, rows.buffer, rows.offset, buffer, offset, u64(size))
	return true
}
