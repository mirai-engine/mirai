package mirai_render

import "core:math"
import "core:math/linalg"
import "mirai:rhi"

// The air of an atmosphere (air.slang, after Hillaire 2020): its tables are
// entries of the texture table, made the first time a sky is an atmosphere.
// The transmittance and the scattering past the first order change only with
// the air; the sky of each window view with its altitude and the height of
// the sun; the aerial perspective of a view with its camera. Each is
// recomputed only then, always from the same samples.

// How far, metres, the eye of a view may rise or fall from the altitude its
// sky row was computed at before it is computed again: over it the light of
// the sky and the dip of the horizon barely move.
AIR_SKY_ALTITUDE_TOLERANCE :: 1

// AIR_* of air.slang.
AIR_TRANSMITTANCE_TEXTURE :: 1
AIR_SCATTERING_TEXTURE :: 2
AIR_SKY_TEXTURE :: 3
AIR_TRANSMITTANCE_SIZE :: [2]u32{256, 64}
AIR_SCATTERING_SIZE :: 32
AIR_SKY_SIZE :: [2]u32{256, 128}
AIR_SKY_ROWS :: VIEW_CAPACITY
AIR_AERIAL_SIZE :: 32
AIR_AERIAL_SLICES :: 32

// The air of a planet, metres. Rayleigh and Mie thin with altitude by e every
// their height; the ozone is a layer that thins to nothing at ozone_width from its middle.
Air :: struct {
	rayleigh:        Vec3, // what a metre of air at the ground scatters, per channel
	rayleigh_height: f32,
	mie:             Vec3, // what a metre of haze at the ground scatters
	mie_absorption:  Vec3, // and absorbs
	mie_height:      f32,
	mie_anisotropy:  f32,  // of its phase, 0 to 1: how much of what it scatters goes forward
	ozone:           Vec3, // what a metre of the middle of the ozone layer absorbs
	ozone_altitude:  f32,
	ozone_width:     f32,
	ground_radius:   f32,
	thickness:       f32,  // of the air, from the ground to where it ends
	ground_albedo:   Vec3, // of the ground of the planet, seen below the horizon
	altitude:        f32,  // of the y 0 of the world over the ground
}

// The Earth of the paper.
AIR_EARTH :: Air{
	rayleigh = {5.802e-6, 13.558e-6, 33.1e-6}, rayleigh_height = 8000,
	mie = {3.996e-6, 3.996e-6, 3.996e-6}, mie_absorption = {0.444e-6, 0.444e-6, 0.444e-6}, mie_height = 1200, mie_anisotropy = 0.8,
	ozone = {0.65e-6, 1.881e-6, 0.085e-6}, ozone_altitude = 25000, ozone_width = 15000,
	ground_radius = 6360000, thickness = 100000, ground_albedo = {0.3, 0.3, 0.3},
}

// Air_Data of common.slang.
Gpu_Air :: struct {
	rayleigh, mie, mie_absorption, ozone, planet, ground, rows: Vec4,
}

// What a row of the sky table holds.
@(private)
Air_Row :: struct {
	altitude, sun: f32, // of the eye, and the cosine of the sun from the zenith
	held:          bool,
}

@(private)
Air_State :: struct {
	transmittance, scattering, sky: rhi.Texture, // sampled alone, as the texture table takes them
	written: rhi.Buffer, // what a pass computes of one, half floats, before it is copied in
	air:   Air,  // what the transmittance and scattering tables hold
	built: bool,
	rows:  [AIR_SKY_ROWS]Air_Row,
}

// What the aerial perspective of a view was computed for.
@(private)
Air_Aerial_Key :: struct {
	from_clip: Mat4,
	eye:       Vec3, // of the world
	sun:       Vec3,
	air:       Air,
	held:      bool,
}

// The air as the shaders take it, from an eye at that altitude over the
// ground, with the sky of that row; radius: the angular one of the sun.
@(private)
air_gpu :: proc(air: Air, altitude: f32, row: int, radius: f32) -> Gpu_Air {
	over := air_overhead(air)
	return {
		rayleigh = {air.rayleigh.x, air.rayleigh.y, air.rayleigh.z, max(air.rayleigh_height, 1)},
		mie = {air.mie.x, air.mie.y, air.mie.z, max(air.mie_height, 1)},
		mie_absorption = {air.mie_absorption.x, air.mie_absorption.y, air.mie_absorption.z, clamp(air.mie_anisotropy, 0, 0.999)},
		ozone = {air.ozone.x, air.ozone.y, air.ozone.z, air.ozone_altitude},
		planet = {max(air.ground_radius, 1000), max(air.ground_radius, 1000) + max(air.thickness, 1000), max(air.ozone_width, 1), altitude},
		ground = {air.ground_albedo.x, air.ground_albedo.y, air.ground_albedo.z, radius},
		rows = {f32(row), over.x, over.y, over.z},
	}
}

// One over what of the light of the sun crosses the air straight down to the
// ground, per channel: the vertical column, whose densities integrate in
// closed form. A sun whose illuminance is what reaches the ground with it
// overhead has this times as much above the air.
air_overhead :: proc(air: Air) -> Vec3 {
	top := max(air.thickness, 1000)
	column :: proc(height, top: f32) -> f32 {
		h := max(height, 1)
		return h * (1 - math.exp(-top / h))
	}
	// The ozone layer between the ground and the top.
	tent :: proc(middle, width, top: f32) -> f32 {
		w := max(width, 1)
		area :: proc(middle, w, x: f32) -> f32 { // from minus infinity to x
			u := clamp((x - middle) / w, -1, 1)
			return w * (0.5 + u - u * abs(u) * 0.5)
		}
		return area(middle, w, top) - area(middle, w, 0)
	}
	depth := air.rayleigh * column(air.rayleigh_height, top) + (air.mie + air.mie_absorption) * column(air.mie_height, top) + air.ozone * tent(air.ozone_altitude, air.ozone_width, top)
	return {math.exp(depth.x), math.exp(depth.y), math.exp(depth.z)}
}

// Whether the frame draws an atmosphere: the sky on, or the one a change comes from.
@(private)
air_wanted :: proc(r: ^Renderer) -> bool {
	e := r.scene.environment
	return r.scene.sun.enabled && (e.sky_atmosphere || e.sky_from_atmosphere && e.sky_from_weight > 0)
}

// The tables of the air, made the first time a frame wants them and kept;
// before the frame begins, as the texture table changes only between frames.
@(private)
air_tables_ensure :: proc(r: ^Renderer) -> bool {
	a := &r.air
	if a.sky != 0 || !air_wanted(r) {return true}
	d := r.device
	// The largest of them is a row of the sky.
	texel :: 8
	black, error := make([]u8, int(AIR_SKY_SIZE.x * AIR_SKY_SIZE.y * AIR_SKY_ROWS) * texel, r.allocator)
	if error != nil {
		set_error(r, "air tables: out of memory")
		return false
	}
	defer delete(black, r.allocator)
	table :: proc(r: ^Renderer, width, height: u32, name: string, black: []u8) -> rhi.Texture {
		t := rhi.texture_create(r.device, {width = width, height = height, format = .RGBA16_Float, usage = {.Sampled}, name = name})
		if t != 0 && !rhi.texture_upload(r.device, t, black[:int(width * height) * texel], width * texel) {
			rhi.texture_destroy(r.device, t)
			return 0
		}
		return t
	}
	a.transmittance = table(r, AIR_TRANSMITTANCE_SIZE.x, AIR_TRANSMITTANCE_SIZE.y, "air transmittance", black)
	a.scattering = table(r, AIR_SCATTERING_SIZE, AIR_SCATTERING_SIZE, "air scattering", black)
	a.sky = table(r, AIR_SKY_SIZE.x, AIR_SKY_SIZE.y * AIR_SKY_ROWS, "air sky", black)
	a.written = rhi.buffer_create(d, {size = u64(AIR_SKY_SIZE.x * AIR_SKY_SIZE.y * texel), usage = {.Storage, .Transfer_Src}, name = "air table written"})
	if a.transmittance == 0 || a.scattering == 0 || a.sky == 0 || a.written == 0 ||
	   !rhi.texture_table_set(d, AIR_TRANSMITTANCE_TEXTURE, a.transmittance) || !rhi.texture_table_set(d, AIR_SCATTERING_TEXTURE, a.scattering) || !rhi.texture_table_set(d, AIR_SKY_TEXTURE, a.sky) {
		set_error(r, "air tables: %s", rhi.device_error(d))
		air_destroy(r)
		return false
	}
	return true
}

// What the pass just dispatched wrote, copied into a region of a table.
@(private)
air_table_copy :: proc(r: ^Renderer, cmd: ^rhi.Command_List, table: rhi.Texture, region := rhi.Texture_Region{}) {
	rhi.cmd_copy_buffer_to_texture(cmd, r.air.written, 0, table, 0, region)
	rhi.cmd_barrier_texture(cmd, table, .Shader_Read)
}

@(private)
air_destroy :: proc(r: ^Renderer) {
	for t in ([]rhi.Texture{r.air.transmittance, r.air.scattering, r.air.sky}) {if t != 0 {rhi.texture_destroy(r.device, t)}}
	if r.air.written != 0 {rhi.buffer_destroy(r.device, r.air.written)}
	r.air = {}
}

// The transmittance and scattering tables of the air of the frame, when it changed.
@(private)
air_frame :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	a := &r.air
	if !air_wanted(r) || a.sky == 0 {return true}
	air := r.scene.environment.air
	if a.built && a.air == air {return true}
	rhi.cmd_timestamp(cmd, "air")
	Params :: struct {air: Gpu_Air}
	params := Params{air_gpu(air, 0, 0, SUN_RADIUS)}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Air_Transmittance])
	set_params(cmd, &params)
	rhi.cmd_bind_sampler(cmd, SLOT_LINEAR_SAMPLER, r.linear_sampler)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, a.written)
	rhi.cmd_dispatch(cmd, groups(AIR_TRANSMITTANCE_SIZE.x, 8), groups(AIR_TRANSMITTANCE_SIZE.y, 8))
	air_table_copy(r, cmd, a.transmittance)
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Air_Scattering])
	set_params(cmd, &params)
	rhi.cmd_bind_sampler(cmd, SLOT_LINEAR_SAMPLER, r.linear_sampler)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, a.written)
	rhi.cmd_dispatch(cmd, AIR_SCATTERING_SIZE, AIR_SCATTERING_SIZE)
	air_table_copy(r, cmd, a.scattering)
	a.air, a.built = air, true
	for &row in a.rows {row.held = false}
	return true
}

// The air of a view into its constants, its row of the sky computed again
// when its eye moved more than AIR_SKY_ALTITUDE_TOLERANCE up or down or the sun
// moved: a window view has its own, those drawn into a texture take that of
// the first view of the window. The row is read with the altitude of the eye,
// as only the dip of the horizon would move with it, a fraction of a texel.
@(private)
air_view :: proc(p: ^Pass, f: ^Gpu_Frame) {
	r := p.r
	if !air_wanted(r) || !r.air.built {return}
	air := r.scene.environment.air
	altitude := air.altitude + p.camera.position.y + r.origin.y
	row := 0 if p.texture else clamp(p.index, 0, AIR_SKY_ROWS - 1)
	radius := max(r.settings.sun_radius, SUN_RADIUS)
	f.air = air_gpu(air, altitude, row, radius)
	if p.texture && !p.first {return}
	sun := linalg.normalize0(r.scene.sun.direction).y
	held := &r.air.rows[row]
	if held.held && abs(altitude - held.altitude) <= AIR_SKY_ALTITUDE_TOLERANCE && held.sun == sun {return}
	cmd := p.cmd
	rhi.cmd_timestamp(cmd, "air sky")
	Params :: struct {air: Gpu_Air, sun: Vec4}
	params := Params{f.air, {sun, 0, 0, 0}}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Air_Sky])
	set_params(cmd, &params)
	rhi.cmd_bind_sampler(cmd, SLOT_LINEAR_SAMPLER, r.linear_sampler)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, r.air.written)
	rhi.cmd_dispatch(cmd, groups(AIR_SKY_SIZE.x, 8), groups(AIR_SKY_SIZE.y, 8))
	air_table_copy(r, cmd, r.air.sky, {0, u32(row) * AIR_SKY_SIZE.y, AIR_SKY_SIZE.x, AIR_SKY_SIZE.y})
	held^ = {altitude = altitude, sun = sun, held = true}
}

// The aerial perspective of a view, computed again when its camera, the sun
// or the air changed; with the constants of the view bound.
@(private)
air_aerial :: proc(p: ^Pass) -> bool {
	r, t := p.r, p.t
	if !air_wanted(r) || !r.air.built || !r.scene.environment.sky_atmosphere {return true}
	if t.aerial == 0 {
		t.aerial = rhi.texture_create(r.device, {width = AIR_AERIAL_SIZE, height = AIR_AERIAL_SIZE, depth = AIR_AERIAL_SLICES, format = .RGBA16_Float, usage = {.Sampled, .Storage}, name = "aerial perspective"})
		if t.aerial == 0 {
			set_error(r, "aerial perspective: %s", rhi.device_error(r.device))
			return false
		}
		t.aerial_key = {}
	}
	key := Air_Aerial_Key{from_clip = linalg.inverse(p.unjittered), eye = p.camera.position + r.origin, sun = r.scene.sun.direction, air = r.scene.environment.air, held = true}
	if t.aerial_key == key {return true}
	cmd := p.cmd
	rhi.cmd_timestamp(cmd, "aerial perspective")
	Params :: struct {from_clip: Mat4}
	params := Params{key.from_clip}
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Air_Aerial])
	set_params(cmd, &params)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.aerial)
	rhi.cmd_dispatch(cmd, groups(AIR_AERIAL_SIZE, 8), groups(AIR_AERIAL_SIZE, 8))
	t.aerial_key = key
	return true
}
