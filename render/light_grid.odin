package mirai_render

import "core:math"
import "core:math/linalg"
import "mirai:render/abi"
import "mirai:rhi"

// The local lights in a grid of the world, for the samples of the direct
// light of a pixel to spread over the lights of its cell
// (shaders/include/direct_grid.slang): every cell lists the lights whose range
// reaches some point of it, each as likely as what it could give the cell, in
// an alias table (Vose), so that a cell with many lights draws one with a
// number and two reads.
//
// The CPU places the grid around the lights; the GPU fills it in the frame a
// light changed (shaders/light_grid.comp.slang): it counts the lights of each
// cell down the tree of the lights, adds the counts up into where the entries
// of each cell start, and puts them there. Its buffer holds a row for each
// cell, x first, then y, then z, with the row of its first entry and how many;
// LIGHT_GRID_WEIGHT_ROWS for each light, what a pixel weighs it by
// (shaders/include/light_weight.slang); then the entries: a light, the entry
// of its cell a draw goes to when this one does not keep it, the chance that
// it keeps it, and the chance of drawing that light in the cell (the bits of
// f32s).
Light_Grid :: struct {
	origin: Vec3,   // the corner of the first cell
	cell:   f32,    // metres a side
	size:   [3]u32, // cells along each axis; none when no light reaches anywhere
	rows:   int,    // a row for each cell, the records of the lights, and for each light one for every cell of the box around its range
}

// Metres a side of a cell, unless the lights reach farther than
// LIGHT_GRID_ROWS_MAX rows of 16 bytes hold.
LIGHT_GRID_CELL :: f32(1)
LIGHT_GRID_ROWS_MAX :: 1 << 21
LIGHT_GRID_WEIGHT_ROWS :: abi.LIGHT_WEIGHT_ROWS

// The grid around the ranges of the lights; `count`, the lights the GPU holds,
// those that a pass writes on it included, each with its record.
light_grid_place :: proc(lights: []Gpu_Light, count: int) -> (grid: Light_Grid) {
	lo, hi := Vec3{max(f32), max(f32), max(f32)}, Vec3{-max(f32), -max(f32), -max(f32)}
	for l in lights {
		if !light_placed(l) || !(l.position_range.w > 0) {continue}
		reach := Vec3{l.position_range.w, l.position_range.w, l.position_range.w}
		lo, hi = linalg.min(lo, l.position_range.xyz - reach), linalg.max(hi, l.position_range.xyz + reach)
	}
	if !(lo.x <= hi.x) {return}
	grid.cell = LIGHT_GRID_CELL
	for {
		// On a lattice of the cell: a light that moves the bounds does not move the cells of the others.
		grid.origin = linalg.floor(lo / grid.cell) * grid.cell
		extent := (hi - grid.origin) / grid.cell
		grid.size = {max(u32(math.ceil(extent.x)), 1), max(u32(math.ceil(extent.y)), 1), max(u32(math.ceil(extent.z)), 1)}
		cells := int(grid.size.x) * int(grid.size.y) * int(grid.size.z)
		grid.rows = cells + LIGHT_GRID_WEIGHT_ROWS * count
		last := Vec3{f32(grid.size.x - 1), f32(grid.size.y - 1), f32(grid.size.z - 1)}
		for l in lights {
			if !light_placed(l) || !(l.position_range.w > 0) {continue}
			a := linalg.clamp(linalg.floor((l.position_range.xyz - l.position_range.w - grid.origin) / grid.cell), Vec3{}, last)
			b := linalg.clamp(linalg.floor((l.position_range.xyz + l.position_range.w - grid.origin) / grid.cell), Vec3{}, last)
			box := b - a + 1
			grid.rows += int(box.x) * int(box.y) * int(box.z)
		}
		// One cell that holds every light is as far as it goes.
		if grid.rows <= LIGHT_GRID_ROWS_MAX || cells == 1 {return}
		grid.cell *= 1.26
	}
}

// The passes that fill the grid, after the lights and their tree reached the GPU.
@(private)
light_grid_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List) {
	s := &r.scene
	cells := s.light_grid.size.x * s.light_grid.size.y * s.light_grid.size.z
	if cells == 0 || s.light_grid_buffer == 0 {return}
	Params :: struct {origin: Vec3, cell: f32, size: [3]u32, cells, lights, grow, pad0, pad1: u32}
	params := Params{origin = s.light_grid.origin, cell = s.light_grid.cell, size = s.light_grid.size, cells = cells, lights = u32(len(s.lights) + light_region_lights(s.light_region))}
	for b in ([]rhi.Buffer{s.light_buffer, s.light_tree_buffer}) {rhi.cmd_barrier_buffer(cmd, b, .Shader_Read)}
	for id in ([]Pipeline_Id{.Light_Grid_Weights, .Light_Grid_Count, .Light_Grid_Scan, .Light_Grid_Fill}) {
		rhi.cmd_barrier_buffer(cmd, s.light_grid_buffer, .Shader_Write)
		rhi.cmd_bind_pipeline(cmd, r.pipelines[id])
		set_params(cmd, &params)
		rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.light_grid_buffer)
		#partial switch id {
		case .Light_Grid_Scan:    rhi.cmd_dispatch(cmd, 1)
		case .Light_Grid_Weights: rhi.cmd_dispatch(cmd, groups(params.lights, 64))
		case:                     rhi.cmd_dispatch(cmd, groups(cells, 64))
		}
	}
	rhi.cmd_barrier_buffer(cmd, s.light_grid_buffer, .Shader_Read)
}

// Places the grid again when a light changed and makes its buffer; the frame
// fills it (light_grid_record).
@(private)
light_grid_update :: proc(r: ^Renderer) -> bool {
	s := &r.scene
	if s.light_grid_stale {
		s.light_grid = light_grid_place(s.lights[:], len(s.lights) + light_region_lights(s.light_region))
		s.light_grid_stale = false
		s.light_grid_dirty = true
	}
	if s.light_grid.rows == 0 {return true}
	ok, recreated := ensure_buffer(r, &s.light_grid_buffer, u64(s.light_grid.rows * size_of([4]u32)), {.Storage}, "light grid")
	if recreated {s.light_grid_dirty = true}
	// The lights a pass writes on the GPU change in every frame.
	if s.light_region.lights > 0 {s.light_grid_dirty = true}
	return ok
}
