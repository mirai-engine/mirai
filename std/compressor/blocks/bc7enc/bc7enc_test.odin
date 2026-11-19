package bc7enc

import "core:math"
import "core:testing"

@(private = "file")
Block_Kind :: enum {
	Solid,
	Gradient,
	Plane,
	Noise,
	Alpha_Solid,
	Alpha_Gradient,
	Alpha_Noise,
}

@(private = "file")
Case :: struct {
	kind:     Block_Kind,
	min_psnr: f64,
}

@(private = "file")
CASES := [?]Case {
	{.Solid, 45},
	{.Gradient, 38},
	{.Plane, 20},
	{.Noise, 13},
	{.Alpha_Solid, 40},
	{.Alpha_Gradient, 18},
	{.Alpha_Noise, 12},
}

@(private = "file")
next_u32 :: proc(state: ^u32) -> u32 {
	x := state^
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	state^ = x
	return x
}

@(private = "file")
make_block :: proc(kind: Block_Kind, pixels: ^[16]Color_Rgba) {
	seed := u32(0x9e3779b9) + u32(kind)
	for i in 0 ..< 16 {
		x := i32(i % 4)
		y := i32(i / 4)
		switch kind {
		case .Solid:
			pixels[i] = {91, 180, 37, 255}
		case .Gradient:
			ramp := x + y * 4
			pixels[i] = {u8(ramp * 13 + 20), u8(ramp * 9 + 30), u8(ramp * 5 + 10), 255}
		case .Plane:
			pixels[i] = {u8(x * 60 + 20), u8(y * 60 + 30), u8((x + y) * 28 + 10), 255}
		case .Noise:
			v := next_u32(&seed)
			pixels[i] = {u8(v), u8(v >> 8), u8(v >> 16), 255}
		case .Alpha_Solid:
			pixels[i] = {200, 40, 90, 128}
		case .Alpha_Gradient:
			pixels[i] = {u8(x * 70), u8(y * 70), 120, u8((x + y) * 40 + 10)}
		case .Alpha_Noise:
			v := next_u32(&seed)
			pixels[i] = {u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}
		}
	}
}

@(private = "file")
psnr :: proc(a, b: ^[16]Color_Rgba) -> f64 {
	total: i64
	for i in 0 ..< 16 {
		for c in 0 ..< 4 {
			d := i64(a[i][c]) - i64(b[i][c])
			total += d * d
		}
	}
	if total == 0 {
		return 100
	}
	mse := f64(total) / (16 * 4)
	return 10 * math.log10(255 * 255 / mse)
}

@(private = "file")
as_bytes :: proc(pixels: ^[16]Color_Rgba) -> [^]u8 {
	return cast([^]u8)&pixels[0]
}

@(private = "file")
init_for_test :: proc(t: ^testing.T) -> ^Tables {
	tables := new(Tables)
	testing.expect(t, tables != nil)
	tables_init(tables)
	return tables
}

@(test)
round_trip_keeps_quality_at_uber_levels :: proc(t: ^testing.T) {
	tables := init_for_test(t)
	defer free(tables)

	for test_case in CASES {
		for uber in ([?]u32{0, MAX_UBER_LEVEL}) {
			for perceptual in ([?]bool{false, true}) {
				params: Params
				params_init(&params)
				params.uber_level = uber
				if !perceptual {
					params_init_linear_weights(&params)
				}

				source, decoded: [16]Color_Rgba
				make_block(test_case.kind, &source)

				block: [BLOCK_SIZE]u8
				compress_block(tables, &block[0], as_bytes(&source), &params)

				ok := unpack_bc7(&block[0], as_bytes(&decoded))
				testing.expect(t, ok)

				value := psnr(&source, &decoded)
				testing.expectf(t, value >= test_case.min_psnr, "%v uber %v perceptual %v: PSNR %v below %v", test_case.kind, uber, perceptual, value, test_case.min_psnr)
			}
		}
	}
}

// Without mode 1 (no partitions to scan, or masked out) or without mode 6, a block still takes
// the best mode it has.
@(private = "file")
SETTINGS := [?]struct {
	mode_mask, max_partitions: u32,
} {
	{max(u32), MAX_PARTITIONS},
	{max(u32), 0},
	{1 << 6, MAX_PARTITIONS},
	{1 << 6 | 1 << 1, 0},
	{1 << 1 | 1 << 5, MAX_PARTITIONS},
	{1 << 5, 0},
}

@(test)
solid_block_decodes_within_one_step :: proc(t: ^testing.T) {
	tables := init_for_test(t)
	defer free(tables)

	for setting in SETTINGS {
		for color in ([?]Color_Rgba{{0, 0, 0, 255}, {255, 255, 255, 255}, {91, 180, 37, 255}, {120, 130, 140, 255}, {200, 40, 90, 128}, {1, 2, 3, 0}}) {
			params: Params
			params_init(&params)
			params_init_linear_weights(&params)
			params.mode_mask = setting.mode_mask
			params.max_partitions = setting.max_partitions

			source, decoded: [16]Color_Rgba
			for i in 0 ..< 16 {
				source[i] = color
			}

			block: [BLOCK_SIZE]u8
			compress_block(tables, &block[0], as_bytes(&source), &params)
			testing.expect(t, unpack_bc7(&block[0], as_bytes(&decoded)))

			for i in 0 ..< 16 {
				for c in 0 ..< 4 {
					testing.expectf(t, abs(i32(source[i][c]) - i32(decoded[i][c])) <= 1, "%v color %v: texel %v comp %v decoded %v", setting, color, i, c, decoded[i][c])
				}
			}
		}
	}
}

// Rows of cutout texels, edge-padded to a block as an image border pads them.
@(private = "file", rodata)
CUTOUTS := [?][4]Color_Rgba {
	{{131, 201, 44, 0}, {192, 135, 226, 174}, {216, 34, 29, 255}, {216, 34, 29, 255}},
	{{10, 200, 30, 0}, {10, 200, 30, 255}, {240, 20, 220, 128}, {90, 90, 90, 255}},
	{{255, 255, 255, 255}, {0, 0, 0, 0}, {128, 64, 32, 3}, {64, 128, 250, 252}},
	{{40, 160, 60, 255}, {44, 150, 70, 240}, {50, 140, 80, 20}, {60, 130, 90, 0}},
}

// Final's effort, linear, with and without the settings of reduce entropy.
@(private = "file")
final_params :: proc(reduce_entropy, perceptual: bool) -> (params: Params) {
	params_init(&params)
	if !perceptual {params_init_linear_weights(&params)}
	params.uber_level = MAX_UBER_LEVEL
	if reduce_entropy {
		params.mode17_partition_estimation_filterbank = false
		params.mode6_error_weight = .4
		params.low_frequency_partition_weight = .9999
		params.quant_mode6_endpoints = true
		params.pbit1_weight = 1.3
	}
	return
}

@(test)
cutout_blocks_keep_alpha_0_and_255 :: proc(t: ^testing.T) {
	tables := init_for_test(t)
	defer free(tables)

	for row, index in CUTOUTS {
		source, decoded: [16]Color_Rgba
		for i in 0 ..< 16 {
			source[i] = row[i % 4]
		}
		for setting in 0 ..< 4 {
			params := final_params(setting & 1 != 0, setting & 2 != 0)
			block: [BLOCK_SIZE]u8
			compress_block(tables, &block[0], as_bytes(&source), &params)
			testing.expect(t, unpack_bc7(&block[0], as_bytes(&decoded)))
			for i in 0 ..< 16 {
				a := source[i][3]
				if a == 0 || a == 255 {
					testing.expectf(t, decoded[i][3] == a, "cutout %v setting %v: texel %v alpha %v decodes %v", index, setting, i, a, decoded[i][3])
				}
			}
		}
	}
}

// Mode 6 of an opaque block quantizes its alpha to 255, so it stays among the modes an opaque
// block may take.
@(test)
opaque_blocks_decode_opaque_and_keep_mode_6 :: proc(t: ^testing.T) {
	tables := init_for_test(t)
	defer free(tables)

	BLOCKS :: 64
	state := u32(0x2545f491)
	mode6 := 0
	for b in 0 ..< BLOCKS {
		source, decoded: [16]Color_Rgba
		for i in 0 ..< 16 {
			v := next_u32(&state)
			ramp := i32(i % 4 + i / 4) * 9 + i32(b)
			for c in 0 ..< 3 {
				source[i][c] = u8(clamp(ramp + i32(c) * 50 + i32((v >> (8 * uint(c))) & 7), 0, 255))
			}
			source[i][3] = 255
		}
		for setting in 0 ..< 4 {
			params := final_params(setting & 1 != 0, setting & 2 != 0)
			block: [BLOCK_SIZE]u8
			compress_block(tables, &block[0], as_bytes(&source), &params)
			testing.expect(t, unpack_bc7(&block[0], as_bytes(&decoded)))
			for i in 0 ..< 16 {
				testing.expectf(t, decoded[i][3] == 255, "block %v setting %v: texel %v decodes alpha %v", b, setting, i, decoded[i][3])
			}
			if setting == 0 && block[0] & 0x7f == 0x40 {mode6 += 1}
		}
	}
	testing.expectf(t, mode6 >= BLOCKS / 8, "mode 6 in %v of %v noisy opaque blocks", mode6, BLOCKS)
}

@(test)
encoding_is_deterministic :: proc(t: ^testing.T) {
	first := init_for_test(t)
	defer free(first)
	second := init_for_test(t)
	defer free(second)

	testing.expect(t, first^ == second^, "tables_init must be deterministic")

	for test_case in CASES {
		for uber in ([?]u32{0, MAX_UBER_LEVEL}) {
			params: Params
			params_init(&params)
			params.uber_level = uber

			source: [16]Color_Rgba
			make_block(test_case.kind, &source)

			block_a, block_b: [BLOCK_SIZE]u8
			compress_block(first, &block_a[0], as_bytes(&source), &params)
			compress_block(second, &block_b[0], as_bytes(&source), &params)
			testing.expectf(t, block_a == block_b, "%v uber %v differs between runs", test_case.kind, uber)
		}
	}
}

@(test)
random_blocks_do_not_crash_the_decoder :: proc(t: ^testing.T) {
	state := u32(0x12345678)
	block: [BLOCK_SIZE]u8
	pixels: [16]Color_Rgba
	reserved := 0
	for _ in 0 ..< 20000 {
		for i in 0 ..< BLOCK_SIZE {
			block[i] = u8(next_u32(&state))
		}
		if block[0] == 0 {
			reserved += 1
		}
		if !unpack_bc7(&block[0], as_bytes(&pixels)) {
			testing.expect(t, block[0] == 0, "only the reserved mode fails")
		}
	}

	block[0] = 0
	testing.expect(t, !unpack_bc7(&block[0], as_bytes(&pixels)))
	for i in 0 ..< 16 {
		testing.expect(t, pixels[i] == Color_Rgba{})
	}
}

@(test)
hostile_params_still_produce_a_block :: proc(t: ^testing.T) {
	tables := init_for_test(t)
	defer free(tables)

	nan := math.nan_f32()
	state := u32(0xdeadbeef)
	for round in 0 ..< 64 {
		params: Params
		params_init(&params)
		params.uber_level = next_u32(&state)
		params.max_partitions = next_u32(&state)
		params.mode_mask = next_u32(&state) & 0xff
		params.weights = {next_u32(&state), next_u32(&state), next_u32(&state), next_u32(&state)}
		params.perceptual = round % 2 == 0
		params.quant_mode6_endpoints = round % 3 == 0
		params.bias_mode1_pbits = round % 5 == 0
		params.force_alpha = round % 7 == 0
		params.force_selectors = round % 4 == 0
		for i in 0 ..< 16 {
			params.selectors[i] = u8(next_u32(&state))
		}
		if round % 8 == 0 {
			params.pbit1_weight = nan
			params.mode1_error_weight = nan
			params.mode5_error_weight = nan
			params.mode6_error_weight = nan
			params.mode7_error_weight = nan
			params.low_frequency_partition_weight = nan
		}

		source: [16]Color_Rgba
		make_block(Block_Kind(round % len(Block_Kind)), &source)

		block: [BLOCK_SIZE]u8
		compress_block(tables, &block[0], as_bytes(&source), &params)

		decoded: [16]Color_Rgba
		unpack_bc7(&block[0], as_bytes(&decoded))
	}
}
