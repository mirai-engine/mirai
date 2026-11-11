package bc7enc

BLOCK_SIZE :: 16
MAX_PARTITIONS :: 64
MAX_UBER_LEVEL :: 4

Color_Rgba :: [4]u8

Params :: struct {
	mode_mask:                              u32,
	// 0 disables mode 1.
	max_partitions:                         u32,
	// Relative RGBA, or YCbCrA when perceptual.
	weights:                                [4]u32,
	uber_level:                             u32,
	perceptual:                             bool,
	try_least_squares:                      bool,
	mode17_partition_estimation_filterbank: bool,
	force_alpha:                            bool,
	force_selectors:                        bool,
	selectors:                              [16]u8,
	quant_mode6_endpoints:                  bool,
	bias_mode1_pbits:                       bool,
	pbit1_weight:                           f32,
	mode1_error_weight:                     f32,
	mode5_error_weight:                     f32,
	mode6_error_weight:                     f32,
	mode7_error_weight:                     f32,
	low_frequency_partition_weight:         f32,
}

Endpoint_Err :: struct {
	error: u16,
	lo:    u8,
	hi:    u8,
}

// Read-only after tables_init, so it can be shared between threads.
Tables :: struct {
	mode1_optimal_endpoints: [256][2]Endpoint_Err,
	mode7_optimal_endpoints: [256][2][2]Endpoint_Err,
	mode1_rgba_midpoints:    [64][2]f32,
	mode5_rgba_midpoints:    [128]f32,
	mode7_rgba_midpoints:    [32][2]f32,
	mode6_reduced_quant:     [2048][2]u8,
}

params_init_linear_weights :: proc(p: ^Params) {
	p.perceptual = false
	p.weights = {1, 1, 1, 1}
}

params_init_perceptual_weights :: proc(p: ^Params) {
	p.perceptual = true
	p.weights = {128, 64, 16, 32}
}

params_init :: proc(p: ^Params) {
	p.mode_mask = max(u32)
	p.max_partitions = MAX_PARTITIONS
	p.try_least_squares = true
	p.mode17_partition_estimation_filterbank = true
	p.uber_level = 0
	p.force_selectors = false
	p.force_alpha = false
	p.quant_mode6_endpoints = false
	p.bias_mode1_pbits = false
	p.pbit1_weight = 1
	p.mode1_error_weight = 1
	p.mode5_error_weight = 1
	p.mode6_error_weight = 1
	p.mode7_error_weight = 1
	p.low_frequency_partition_weight = 1
	params_init_perceptual_weights(p)
}

tables_init :: proc(t: ^Tables) {
	for p in u32(0) ..< 2 {
		for i in u32(0) ..< 32 {
			vl := ((i << 1) | p) << 2
			vl |= vl >> 6
			lo := f32(vl) / 255

			vh := ((min(u32(31), i + 1) << 1) | p) << 2
			vh |= vh >> 6
			hi := f32(vh) / 255

			t.mode7_rgba_midpoints[i][p] = i == 31 ? 1 : (lo + hi) / 2
		}
	}

	for p in u32(0) ..< 2 {
		for i in u32(0) ..< 64 {
			vl := ((i << 1) | p) << 1
			vl |= vl >> 7
			lo := f32(vl) / 255

			vh := ((min(u32(63), i + 1) << 1) | p) << 1
			vh |= vh >> 7
			hi := f32(vh) / 255

			t.mode1_rgba_midpoints[i][p] = i == 63 ? 1 : (lo + hi) / 2
		}
	}

	for i in u32(0) ..< 128 {
		vl := i << 1
		vl |= vl >> 7
		lo := f32(vl) / 255

		vh := min(u32(127), i + 1) << 1
		vh |= vh >> 7
		hi := f32(vh) / 255

		t.mode5_rgba_midpoints[i] = i == 127 ? 1 : (lo + hi) / 2
	}

	for p in u32(0) ..< 2 {
		for i in u32(0) ..< 2048 {
			f := f32(i) / 2047

			best_err: f32 = 1e9
			best_index: i32 = 0
			for j in i32(0) ..< 64 {
				ik := (j * 127 + 31) / 63
				k := f32((u32(ik) << 1) + p) / 255

				e := abs(k - f)
				if e < best_err {
					best_err = e
					best_index = ik
				}
			}

			t.mode6_reduced_quant[i][p] = u8(best_index)
		}
	}

	weight1 := BC7_WEIGHTS3[MODE_1_OPTIMAL_INDEX]
	for c in i32(0) ..< 256 {
		for lp in u32(0) ..< 2 {
			best := Endpoint_Err {
				error = max(u16),
			}
			for l in u32(0) ..< 64 {
				low := ((l << 1) | lp) << 1
				low |= low >> 7
				for h in u32(0) ..< 64 {
					high := ((h << 1) | lp) << 1
					high |= high >> 7
					k := i32((low * (64 - weight1) + high * weight1 + 32) >> 6)
					err := (k - c) * (k - c)
					if err < i32(best.error) {
						best.error = u16(err)
						best.lo = u8(l)
						best.hi = u8(h)
					}
				}
			}
			t.mode1_optimal_endpoints[c][lp] = best
		}
	}

	weight7 := BC7_WEIGHTS2[MODE_7_OPTIMAL_INDEX]
	for c in i32(0) ..< 256 {
		for hp in u32(0) ..< 2 {
			for lp in u32(0) ..< 2 {
				best := Endpoint_Err {
					error = max(u16),
				}
				for l in u32(0) ..< 32 {
					low := ((l << 1) | lp) << 2
					low |= low >> 6
					for h in u32(0) ..< 32 {
						high := ((h << 1) | hp) << 2
						high |= high >> 6
						k := i32((low * (64 - weight7) + high * weight7 + 32) >> 6)
						err := (k - c) * (k - c)
						if err < i32(best.error) {
							best.error = u16(err)
							best.lo = u8(l)
							best.hi = u8(h)
						}
					}
				}
				t.mode7_optimal_endpoints[c][hp][lp] = best
			}
		}
	}
}

// Encodes 16 RGBA8 texels into a 16-byte block and returns whether alpha was encoded, which is not
// an error code. Upstream leaves the block unwritten for an alpha block when mode_mask excludes
// modes 5, 6 and 7.
compress_block :: proc(t: ^Tables, block: [^]u8, pixels: [^]u8, p: ^Params) -> bool {
	colors := cast([^]Color_Rgba)pixels

	params: Cell_Params
	if p.perceptual {
		// BT.709. Variables, not constants, keep each step in f32 as upstream evaluates it.
		luma_r: f32 = .2126
		luma_b: f32 = .0722
		chroma_r := .5 / (1 - luma_r)
		chroma_b := .5 / (1 - luma_b)
		pr_weight := chroma_r * chroma_r
		pb_weight := chroma_b * chroma_b
		params.weights[0] = u32(i32(f32(p.weights[0]) * 4))
		params.weights[1] = u32(i32(f32(p.weights[1]) * 4 * pr_weight))
		params.weights[2] = u32(i32(f32(p.weights[2]) * 4 * pb_weight))
		params.weights[3] = p.weights[3] * 4
	} else {
		params.weights = p.weights
	}

	if p.force_alpha {
		handle_alpha_block(t, block, colors, p, &params)
		return true
	}

	for i in 0 ..< 16 {
		if colors[i][3] < 255 {
			handle_alpha_block(t, block, colors, p, &params)
			return true
		}
	}

	handle_opaque_block(t, block, colors, p, &params)
	return false
}
