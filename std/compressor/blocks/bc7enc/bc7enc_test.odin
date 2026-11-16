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

@(test)
solid_block_decodes_within_one_step :: proc(t: ^testing.T) {
	tables := init_for_test(t)
	defer free(tables)

	for color in ([?]Color_Rgba{{0, 0, 0, 255}, {255, 255, 255, 255}, {91, 180, 37, 255}, {200, 40, 90, 128}, {1, 2, 3, 0}}) {
		params: Params
		params_init(&params)

		source, decoded: [16]Color_Rgba
		for i in 0 ..< 16 {
			source[i] = color
		}

		block: [BLOCK_SIZE]u8
		compress_block(tables, &block[0], as_bytes(&source), &params)
		testing.expect(t, unpack_bc7(&block[0], as_bytes(&decoded)))

		for i in 0 ..< 16 {
			for c in 0 ..< 4 {
				testing.expectf(t, abs(i32(source[i][c]) - i32(decoded[i][c])) <= 1, "color %v: texel %v comp %v decoded %v", color, i, c, decoded[i][c])
			}
		}
	}
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
