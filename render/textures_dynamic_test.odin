package mirai_render

import "core:testing"
import "mirai:asset"
import "mirai:rhi"

// What a dynamic texture is made of and what a write of one gives are checked
// before the GPU sees them: each refusal says which rule it broke.
@(test)
dynamic_textures_and_their_writes_refuse_what_does_not_fit :: proc(t: ^testing.T) {
	NAN_HALF :: [2]u8{0x00, 0x7e}
	INF_HALF :: [2]u8{0x00, 0x7c}
	ONE_HALF :: [2]u8{0x00, 0x3c}
	rgba16f_one: [8]u8
	rgba16f_nan: [8]u8
	for c in 0 ..< 4 {
		rgba16f_one[c * 2], rgba16f_one[c * 2 + 1] = ONE_HALF[0], ONE_HALF[1]
		rgba16f_nan[c * 2], rgba16f_nan[c * 2 + 1] = ONE_HALF[0], ONE_HALF[1]
	}
	rgba16f_nan[5] = NAN_HALF[1]
	rgba16f_inf := rgba16f_one
	rgba16f_inf[7] = INF_HALF[1]
	rgba8: [16]u8
	Make :: struct {
		width, height: u32,
		format:        asset.Texture_Format,
		srgb:          bool,
		pixels:        []u8,
		want:          Texture_Dynamic_Problem,
	}
	makes := []Make{
		{2, 2, .RGBA8, true, rgba8[:], .None},
		{2, 2, .RGBA8, false, nil, .None},
		{3, 5, .R8, false, nil, .None},
		{1, 1, .RGBA16F, false, rgba16f_one[:], .None},
		{1, 1, .RGBA16, false, rgba16f_nan[:], .None}, // unorm: any bits are a value
		{0, 2, .RGBA8, false, nil, .Size},
		{2, 4097, .RGBA8, false, nil, .Size},
		{4, 4, .BC7, false, nil, .Format},
		{4, 4, .BC1, true, nil, .Format},
		{2, 2, .R8, true, nil, .Srgb},
		{2, 2, .RGBA16F, true, nil, .Srgb},
		{2, 2, .RGBA8, false, rgba8[:15], .Bytes},
		{2, 2, .R8, false, rgba8[:], .Bytes},
		{1, 1, .RGBA16F, false, rgba16f_nan[:], .Not_Finite},
		{1, 1, .RGBA16F, false, rgba16f_inf[:], .Not_Finite},
	}
	for c, i in makes {
		got := texture_dynamic_check(c.width, c.height, 4096, c.format, c.srgb, c.pixels)
		testing.expectf(t, got == c.want, "make %d (%v %dx%d srgb %v): %v, not %v", i, c.format, c.width, c.height, c.srgb, got, c.want)
	}
	testing.expect_value(t, texture_dynamic_format(.RGBA8, true), rhi.Format.RGBA8_Srgb)
	testing.expect_value(t, texture_dynamic_format(.R8, false), rhi.Format.R8_Unorm)
	testing.expect_value(t, texture_dynamic_format(.RGBA16F, false), rhi.Format.RGBA16_Float)
	testing.expect_value(t, texture_dynamic_format(.BC6H, false), rhi.Format.Undefined)

	// Handles 1: RGBA16F 2x3, 2: a cooked texture, 3: removed, 4: R8 3x2.
	state: Texture_State
	state.textures = make([dynamic]rhi.Texture, context.temp_allocator)
	state.sizes = make([dynamic][2]int, context.temp_allocator)
	state.dynamic_format = make([dynamic]rhi.Format, context.temp_allocator)
	append(&state.textures, rhi.Texture(11), rhi.Texture(12), 0, rhi.Texture(14))
	append(&state.sizes, [2]int{2, 3}, [2]int{4, 4}, [2]int{}, [2]int{3, 2})
	append(&state.dynamic_format, rhi.Format.RGBA16_Float, rhi.Format.RGBA8_Srgb, rhi.Format.Undefined, rhi.Format.R8_Unorm)
	state.dynamic_format[1] = .Undefined
	state.count = 4
	rows_bytes := make([]u8, 2 * 3 * 8, context.temp_allocator)
	nan_row := make([]u8, 2 * 8, context.temp_allocator)
	nan_row[9] = NAN_HALF[1]
	r8: [6]u8
	Write :: struct {
		write:  Texture_Write,
		want:   Texture_Dynamic_Problem,
		region: rhi.Texture_Region,
	}
	writes := []Write{
		{{1, rows_bytes, {}}, .None, {0, 0, 2, 3}},
		{{1, rows_bytes[:16], {2, 1}}, .None, {0, 2, 2, 1}},
		{{4, r8[:3], {1, 1}}, .None, {0, 1, 3, 1}},
		{{4, r8[:], {}}, .None, {0, 0, 3, 2}},
		{{0, rows_bytes, {}}, .Gone, {}},
		{{5, rows_bytes, {}}, .Gone, {}},
		{{3, rows_bytes, {}}, .Gone, {}},
		{{2, rows_bytes, {}}, .Not_Dynamic, {}},
		{{1, rows_bytes[:47], {}}, .Bytes, {}},
		{{1, rows_bytes, {0, 2}}, .Bytes, {}},
		{{4, r8[:4], {}}, .Bytes, {}},
		{{1, rows_bytes[:16], {3, 1}}, .Rows, {}},
		{{1, rows_bytes[:32], {2, 2}}, .Rows, {}},
		{{1, nil, {1, 0}}, .Rows, {}},
		{{1, nan_row, {0, 1}}, .Not_Finite, {}},
	}
	for c, i in writes {
		got, region := texture_write_check(&state, c.write)
		testing.expectf(t, got == c.want && region == c.region, "write %d to %d rows %v: %v %v, not %v %v", i, c.write.texture, c.write.rows, got, region, c.want, c.region)
	}
}
