#+private
package bc7enc

import "core:math"

MODE_1_OPTIMAL_INDEX :: 2
MODE_7_OPTIMAL_INDEX :: 1

INVERSE_255: f32 : 1.0 / 255.0

Vec4 :: [4]f32

Cell_Params :: struct {
	num_pixels:           u32,
	pixels:               [^]Color_Rgba,
	num_selector_weights: u32,
	selector_weights:     [^]u32,
	selector_weightsx:    [^]Vec4,
	comp_bits:            u32,
	weights:              [4]u32,
	has_alpha:            bool,
	has_pbits:            bool,
	endpoints_share_pbit: bool,
	perceptual:           bool,
}

Cell_Results :: struct {
	best_overall_err: u64,
	low_endpoint:     Color_Rgba,
	high_endpoint:    Color_Rgba,
	pbits:            [2]u32,
	selectors:        [^]u8,
	selectors_temp:   [^]u8,
}

Optimization_Results :: struct {
	mode:            u32,
	partition:       u32,
	selectors:       [16]u8,
	alpha_selectors: [16]u8,
	low:             [3]Color_Rgba,
	high:            [3]Color_Rgba,
	pbits:           [3][2]u32,
	rotation:        u32,
	index_selector:  u32,
}

// Keeps upstream's comparison order instead of the builtins, which differ on signed zeros.
minf :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	return a < b ? a : b
}

maxf :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	return a > b ? a : b
}

clampf :: #force_inline proc "contextless" (value, low, high: f32) -> f32 {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}

square_f :: #force_inline proc "contextless" (v: f32) -> f32 {
	return v * v
}

square_i :: #force_inline proc "contextless" (v: i32) -> i32 {
	return v * v
}

vec4_saturate :: proc "contextless" (v: Vec4) -> Vec4 {
	return {clampf(v[0], 0, 1), clampf(v[1], 0, 1), clampf(v[2], 0, 1), clampf(v[3], 0, 1)}
}

vec4_from_color :: #force_inline proc "contextless" (c: Color_Rgba) -> Vec4 {
	return {f32(c[0]), f32(c[1]), f32(c[2]), f32(c[3])}
}

vec4_dot :: #force_inline proc "contextless" (a, b: Vec4) -> f32 {
	return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
}

vec4_normalize :: proc "contextless" (v: Vec4) -> Vec4 {
	s := v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3]
	if s == 0 {
		return v
	}
	s = 1 / math.sqrt(s)
	return {v[0] * s, v[1] * s, v[2] * s, v[3] * s}
}

// Solves endpoints by the normal equations for the components first_comp..<end_comp.
least_squares_endpoints :: proc "contextless" (
	n: u32,
	selectors: [^]u8,
	selector_weights: [^]Vec4,
	pixels: [^]Color_Rgba,
	first_comp, end_comp: u32,
) -> (
	xl, xh: Vec4,
) {
	z00, z10, z11: f32
	q00, t: Vec4
	for i in 0 ..< n {
		sw := selector_weights[selectors[i]]
		z00 += sw[0]
		z10 += sw[1]
		z11 += sw[2]
		w := sw[3]
		for c in first_comp ..< end_comp {
			v := f32(pixels[i][c])
			q00[c] += w * v
			t[c] += v
		}
	}

	z01 := z10

	det := z00 * z11 - z01 * z10
	if det != 0 {
		det = 1 / det
	}

	iz00 := z11 * det
	iz01 := -z01 * det
	iz10 := -z10 * det
	iz11 := z00 * det

	for c in first_comp ..< end_comp {
		q10 := t[c] - q00[c]
		xl[c] = iz00 * q00[c] + iz01 * q10
		xh[c] = iz10 * q00[c] + iz11 * q10

		if xl[c] < 0 || xh[c] > 255 {
			lo_v := max(u32)
			hi_v := u32(0)
			for i in 0 ..< n {
				lo_v = min(lo_v, u32(pixels[i][c]))
				hi_v = max(hi_v, u32(pixels[i][c]))
			}

			if lo_v == hi_v {
				xl[c] = f32(lo_v)
				xh[c] = f32(hi_v)
			}
		}
	}

	return
}

scale_color :: proc "contextless" (c: Color_Rgba, params: ^Cell_Params) -> (res: Color_Rgba) {
	n := params.comp_bits + (params.has_pbits ? 1 : 0)
	for i in 0 ..< 4 {
		v := u32(c[i]) << (8 - n)
		v |= v >> n
		res[i] = u8(v)
	}
	return
}

color_distance_rgb :: proc "contextless" (e1, e2: Color_Rgba, perceptual: bool, weights: ^[4]u32) -> u64 {
	dr, dg, db: i32
	if perceptual {
		l1 := i32(e1[0]) * 109 + i32(e1[1]) * 366 + i32(e1[2]) * 37
		cr1 := (i32(e1[0]) << 9) - l1
		cb1 := (i32(e1[2]) << 9) - l1
		l2 := i32(e2[0]) * 109 + i32(e2[1]) * 366 + i32(e2[2]) * 37
		cr2 := (i32(e2[0]) << 9) - l2
		cb2 := (i32(e2[2]) << 9) - l2
		dr = (l1 - l2) >> 8
		dg = (cr1 - cr2) >> 8
		db = (cb1 - cb2) >> 8
	} else {
		dr = i32(e1[0]) - i32(e2[0])
		dg = i32(e1[1]) - i32(e2[1])
		db = i32(e1[2]) - i32(e2[2])
	}

	return u64(weights[0] * u32(dr * dr) + weights[1] * u32(dg * dg) + weights[2] * u32(db * db))
}

color_distance_rgba :: proc "contextless" (e1, e2: Color_Rgba, perceptual: bool, weights: ^[4]u32) -> u64 {
	da := i32(e1[3]) - i32(e2[3])
	return color_distance_rgb(e1, e2, perceptual, weights) + u64(weights[3] * u32(da * da))
}

pack_mode1_to_one_color :: proc(
	t: ^Tables,
	params: ^Cell_Params,
	results: ^Cell_Results,
	r, g, b: u32,
	selectors: [^]u8,
) -> u64 {
	best_err := max(u32)
	best_p := u32(0)

	for p in u32(0) ..< 2 {
		err :=
			u32(t.mode1_optimal_endpoints[r][p].error) +
			u32(t.mode1_optimal_endpoints[g][p].error) +
			u32(t.mode1_optimal_endpoints[b][p].error)
		if err < best_err {
			best_err = err
			best_p = p
			if best_err == 0 {
				break
			}
		}
	}

	er := t.mode1_optimal_endpoints[r][best_p]
	eg := t.mode1_optimal_endpoints[g][best_p]
	eb := t.mode1_optimal_endpoints[b][best_p]

	results.low_endpoint = {er.lo, eg.lo, eb.lo, 0}
	results.high_endpoint = {er.hi, eg.hi, eb.hi, 0}
	results.pbits[0] = best_p
	results.pbits[1] = 0

	for i in 0 ..< params.num_pixels {
		selectors[i] = MODE_1_OPTIMAL_INDEX
	}

	weight := BC7_WEIGHTS3[MODE_1_OPTIMAL_INDEX]
	p: Color_Rgba
	for i in 0 ..< 3 {
		low := ((u32(results.low_endpoint[i]) << 1) | results.pbits[0]) << 1
		low |= low >> 7

		high := ((u32(results.high_endpoint[i]) << 1) | results.pbits[0]) << 1
		high |= high >> 7

		p[i] = u8((low * (64 - weight) + high * weight + 32) >> 6)
	}
	p[3] = 255

	total_err: u64
	for i in 0 ..< params.num_pixels {
		total_err += color_distance_rgb(p, params.pixels[i], params.perceptual, &params.weights)
	}

	results.best_overall_err = total_err

	return total_err
}

pack_mode7_to_one_color :: proc(
	t: ^Tables,
	params: ^Cell_Params,
	results: ^Cell_Results,
	r, g, b, a: u32,
	selectors: [^]u8,
	num_pixels: u32,
	pixels: [^]Color_Rgba,
) -> u64 {
	best_err := max(u32)
	best_p := u32(0)

	for p in u32(0) ..< 4 {
		hi_p := p >> 1
		lo_p := p & 1
		err :=
			u32(t.mode7_optimal_endpoints[r][hi_p][lo_p].error) +
			u32(t.mode7_optimal_endpoints[g][hi_p][lo_p].error) +
			u32(t.mode7_optimal_endpoints[b][hi_p][lo_p].error) +
			u32(t.mode7_optimal_endpoints[a][hi_p][lo_p].error)
		if err < best_err {
			best_err = err
			best_p = p
			if best_err == 0 {
				break
			}
		}
	}

	best_hi_p := best_p >> 1
	best_lo_p := best_p & 1

	er := t.mode7_optimal_endpoints[r][best_hi_p][best_lo_p]
	eg := t.mode7_optimal_endpoints[g][best_hi_p][best_lo_p]
	eb := t.mode7_optimal_endpoints[b][best_hi_p][best_lo_p]
	ea := t.mode7_optimal_endpoints[a][best_hi_p][best_lo_p]

	results.low_endpoint = {er.lo, eg.lo, eb.lo, ea.lo}
	results.high_endpoint = {er.hi, eg.hi, eb.hi, ea.hi}
	results.pbits[0] = best_lo_p
	results.pbits[1] = best_hi_p

	for i in 0 ..< num_pixels {
		selectors[i] = MODE_7_OPTIMAL_INDEX
	}

	weight := BC7_WEIGHTS2[MODE_7_OPTIMAL_INDEX]
	p: Color_Rgba
	for i in 0 ..< 4 {
		low := (u32(results.low_endpoint[i]) << 1) | results.pbits[0]
		high := (u32(results.high_endpoint[i]) << 1) | results.pbits[1]

		low = (low << 2) | (low >> 6)
		high = (high << 2) | (high >> 6)

		p[i] = u8((low * (64 - weight) + high * weight + 32) >> 6)
	}

	total_err: u64
	for i in 0 ..< num_pixels {
		total_err += color_distance_rgba(p, pixels[i], params.perceptual, &params.weights)
	}

	results.best_overall_err = total_err

	return total_err
}

evaluate_solution :: proc(low, high: Color_Rgba, pbits: [2]u32, params: ^Cell_Params, results: ^Cell_Results, comp: ^Params) -> u64 {
	quant_min := low
	quant_max := high

	if params.has_pbits {
		min_pbit := pbits[0]
		max_pbit := params.endpoints_share_pbit ? pbits[0] : pbits[1]

		for c in 0 ..< 4 {
			quant_min[c] = u8((u32(low[c]) << 1) | min_pbit)
			quant_max[c] = u8((u32(high[c]) << 1) | max_pbit)
		}
	}

	actual_min := scale_color(quant_min, params)
	actual_max := scale_color(quant_max, params)

	n := params.num_selector_weights

	weighted: [16]Color_Rgba
	weighted[0] = actual_min
	weighted[n - 1] = actual_max

	nc := params.has_alpha ? 4 : 3
	for i in 1 ..< (n - 1) {
		w := params.selector_weights[i]
		for j in 0 ..< nc {
			weighted[i][j] = u8((u32(actual_min[j]) * (64 - w) + u32(actual_max[j]) * w + 32) >> 6)
		}
	}

	lr := i32(actual_min[0])
	lg := i32(actual_min[1])
	lb := i32(actual_min[2])
	dr := i32(actual_max[0]) - lr
	dg := i32(actual_max[1]) - lg
	db := i32(actual_max[2]) - lb

	total_err: u64

	if comp.force_selectors {
		for i in 0 ..< params.num_pixels {
			// Upstream reads past the palette for an out-of-range selector.
			best_sel := min(u32(comp.selectors[i]), n - 1)

			best_err: u64
			if params.has_alpha {
				best_err = color_distance_rgba(weighted[best_sel], params.pixels[i], params.perceptual, &params.weights)
			} else {
				best_err = color_distance_rgb(weighted[best_sel], params.pixels[i], params.perceptual, &params.weights)
			}

			total_err += best_err

			results.selectors_temp[i] = u8(best_sel)
		}
	} else if !params.perceptual {
		if params.has_alpha {
			la := i32(actual_min[3])
			da := i32(actual_max[3]) - la

			f := f32(n) / (f32(square_i(dr) + square_i(dg) + square_i(db) + square_i(da)) + .00000125)

			for i in 0 ..< params.num_pixels {
				c := params.pixels[i]
				r := i32(c[0])
				g := i32(c[1])
				b := i32(c[2])
				a := i32(c[3])

				best_sel := i32(f32((r - lr) * dr + (g - lg) * dg + (b - lb) * db + (a - la) * da) * f + .5)
				best_sel = clamp(best_sel, 1, i32(n) - 1)

				err0 := color_distance_rgba(weighted[best_sel - 1], c, false, &params.weights)
				err1 := color_distance_rgba(weighted[best_sel], c, false, &params.weights)

				if err1 > err0 {
					err1 = err0
					best_sel -= 1
				}
				total_err += err1

				results.selectors_temp[i] = u8(best_sel)
			}
		} else {
			f := f32(n) / (f32(square_i(dr) + square_i(dg) + square_i(db)) + .00000125)

			for i in 0 ..< params.num_pixels {
				c := params.pixels[i]
				r := i32(c[0])
				g := i32(c[1])
				b := i32(c[2])

				sel := i32(f32((r - lr) * dr + (g - lg) * dg + (b - lb) * db) * f + .5)
				sel = clamp(sel, 1, i32(n) - 1)

				err0 := color_distance_rgb(weighted[sel - 1], c, false, &params.weights)
				err1 := color_distance_rgb(weighted[sel], c, false, &params.weights)

				best_sel := sel
				best_err := err1
				if err0 < best_err {
					best_err = err0
					best_sel = sel - 1
				}

				total_err += best_err

				results.selectors_temp[i] = u8(best_sel)
			}
		}
	} else {
		for i in 0 ..< params.num_pixels {
			best_err := max(u64)
			best_sel := u32(0)

			for j in 0 ..< n {
				err: u64
				if params.has_alpha {
					err = color_distance_rgba(weighted[j], params.pixels[i], true, &params.weights)
				} else {
					err = color_distance_rgb(weighted[j], params.pixels[i], true, &params.weights)
				}
				if err < best_err {
					best_err = err
					best_sel = j
				}
			}

			total_err += best_err

			results.selectors_temp[i] = u8(best_sel)
		}
	}

	if total_err < results.best_overall_err {
		results.best_overall_err = total_err

		results.low_endpoint = low
		results.high_endpoint = high

		results.pbits = pbits

		for i in 0 ..< params.num_pixels {
			results.selectors[i] = results.selectors_temp[i]
		}
	}

	return total_err
}

fix_degenerate_endpoints :: proc "contextless" (mode: u32, trial_min, trial_max: ^Color_Rgba, xl, xh: ^Vec4, iscale: u32, comp: ^Params) {
	if mode != 1 && !(mode == 6 && comp.quant_mode6_endpoints) {
		return
	}

	for i in 0 ..< 3 {
		if trial_min[i] != trial_max[i] {
			continue
		}
		if abs(xl[i] - xh[i]) <= 0 {
			continue
		}

		if u32(trial_min[i]) > (iscale >> 1) {
			if trial_min[i] > 0 {
				trial_min[i] -= 1
			} else if u32(trial_max[i]) < iscale {
				trial_max[i] += 1
			}
		} else {
			if u32(trial_max[i]) < iscale {
				trial_max[i] += 1
			} else if trial_min[i] > 0 {
				trial_min[i] -= 1
			}
		}
	}
}

quantize_endpoint_with_pbit :: proc(t: ^Tables, comp_bits: u32, v: Vec4, p, iscalep: i32, scalep: f32) -> (res: Color_Rgba) {
	for c in 0 ..< 4 {
		q: i32
		switch comp_bits {
		case 5:
			q = i32(v[c] * 31)
			if v[c] > t.mode7_rgba_midpoints[q][p] {
				q += 1
			}
		case 6:
			q = i32(v[c] * 63)
			if v[c] > t.mode1_rgba_midpoints[q][p] {
				q += 1
			}
		case:
			q = i32((v[c] * scalep - f32(p)) / 2 + .5)
		}
		res[c] = u8(clamp(q * 2 + p, p, iscalep - 1 + p))
	}
	return
}

shift_color_right_1 :: proc "contextless" (c: Color_Rgba) -> Color_Rgba {
	return {c[0] >> 1, c[1] >> 1, c[2] >> 1, c[3] >> 1}
}

find_optimal_solution :: proc(t: ^Tables, mode: u32, xl_in, xh_in: Vec4, params: ^Cell_Params, results: ^Cell_Results, comp: ^Params) -> u64 {
	xl := vec4_saturate(xl_in)
	xh := vec4_saturate(xh_in)

	if params.has_pbits {
		iscalep := (i32(1) << (params.comp_bits + 1)) - 1
		scalep := f32(iscalep)

		total_comps := params.has_alpha ? 4 : 3

		best_pbits: [2]u32
		best_min, best_max: Color_Rgba

		if !params.endpoints_share_pbit {
			if params.comp_bits == 7 && comp.quant_mode6_endpoints {
				best_pbits[0] = 0
				best_pbits[1] = 1
				for c in 0 ..< 4 {
					best_min[c] = t.mode6_reduced_quant[i32(xl[c] * 2047 + .5)][0]
					best_max[c] = t.mode6_reduced_quant[i32(xh[c] * 2047 + .5)][1]
				}
			} else {
				best_err0: f32 = 1e9
				best_err1: f32 = 1e9

				for p in i32(0) ..< 2 {
					x_min := quantize_endpoint_with_pbit(t, params.comp_bits, xl, p, iscalep, scalep)
					x_max := quantize_endpoint_with_pbit(t, params.comp_bits, xh, p, iscalep, scalep)

					scaled_low := scale_color(x_min, params)
					scaled_high := scale_color(x_max, params)

					err0, err1: f32
					for i in 0 ..< total_comps {
						err0 += square_f(f32(scaled_low[i]) - xl[i] * 255)
						err1 += square_f(f32(scaled_high[i]) - xh[i] * 255)
					}

					if p == 1 {
						err0 *= comp.pbit1_weight
						err1 *= comp.pbit1_weight
					}

					if err0 < best_err0 {
						best_err0 = err0
						best_pbits[0] = u32(p)
						best_min = shift_color_right_1(x_min)
					}

					if err1 < best_err1 {
						best_err1 = err1
						best_pbits[1] = u32(p)
						best_max = shift_color_right_1(x_max)
					}
				}
			}
		} else if mode == 1 && comp.bias_mode1_pbits {
			x: f32
			for c in 0 ..< 3 {
				x = maxf(maxf(x, xl[c]), xh[c])
			}

			p: i32 = x > 253.0 / 255.0 ? 1 : 0

			best_pbits[0] = u32(p)
			best_pbits[1] = u32(p)
			best_min = shift_color_right_1(quantize_endpoint_with_pbit(t, params.comp_bits, xl, p, iscalep, scalep))
			best_max = shift_color_right_1(quantize_endpoint_with_pbit(t, params.comp_bits, xh, p, iscalep, scalep))
		} else {
			best_err: f32 = 1e9

			for p in i32(0) ..< 2 {
				x_min := quantize_endpoint_with_pbit(t, params.comp_bits, xl, p, iscalep, scalep)
				x_max := quantize_endpoint_with_pbit(t, params.comp_bits, xh, p, iscalep, scalep)

				scaled_low := scale_color(x_min, params)
				scaled_high := scale_color(x_max, params)

				err: f32
				for i in 0 ..< total_comps {
					err += square_f(f32(scaled_low[i]) / 255 - xl[i]) + square_f(f32(scaled_high[i]) / 255 - xh[i])
				}

				if p == 1 {
					err *= comp.pbit1_weight
				}

				if err < best_err {
					best_err = err
					best_pbits[0] = u32(p)
					best_pbits[1] = u32(p)
					best_min = shift_color_right_1(x_min)
					best_max = shift_color_right_1(x_max)
				}
			}
		}

		fix_degenerate_endpoints(mode, &best_min, &best_max, &xl, &xh, u32(iscalep >> 1), comp)

		if results.best_overall_err == max(u64) ||
		   best_min != results.low_endpoint ||
		   best_max != results.high_endpoint ||
		   best_pbits[0] != results.pbits[0] ||
		   best_pbits[1] != results.pbits[1] {
			evaluate_solution(best_min, best_max, best_pbits, params, results, comp)
		}
	} else {
		iscale := (i32(1) << params.comp_bits) - 1
		scale := f32(iscale)

		trial_min, trial_max: Color_Rgba
		if params.comp_bits == 7 {
			for c in 0 ..< 4 {
				vl := i32(xl[c] * 127)
				if xl[c] > t.mode5_rgba_midpoints[vl] {
					vl += 1
				}
				trial_min[c] = u8(clamp(vl, 0, 127))

				vh := i32(xh[c] * 127)
				if xh[c] > t.mode5_rgba_midpoints[vh] {
					vh += 1
				}
				trial_max[c] = u8(clamp(vh, 0, 127))
			}
		} else {
			for c in 0 ..< 4 {
				trial_min[c] = u8(clamp(i32(xl[c] * scale + .5), 0, 255))
				trial_max[c] = u8(clamp(i32(xh[c] * scale + .5), 0, 255))
			}
		}

		fix_degenerate_endpoints(mode, &trial_min, &trial_max, &xl, &xh, u32(iscale), comp)

		if results.best_overall_err == max(u64) || trial_min != results.low_endpoint || trial_max != results.high_endpoint {
			evaluate_solution(trial_min, trial_max, results.pbits, params, results, comp)
		}
	}

	return results.best_overall_err
}

refine_from_selectors :: proc(t: ^Tables, mode: u32, selectors: [^]u8, params: ^Cell_Params, results: ^Cell_Results, comp: ^Params) -> u64 {
	xl, xh: Vec4
	if params.has_alpha {
		xl, xh = least_squares_endpoints(params.num_pixels, selectors, params.selector_weightsx, params.pixels, 0, 4)
	} else {
		xl, xh = least_squares_endpoints(params.num_pixels, selectors, params.selector_weightsx, params.pixels, 0, 3)
		xl[3] = 255
		xh[3] = 255
	}

	return find_optimal_solution(t, mode, xl * INVERSE_255, xh * INVERSE_255, params, results, comp)
}

color_cell_compression :: proc(t: ^Tables, mode: u32, params: ^Cell_Params, results: ^Cell_Results, comp: ^Params) -> u64 {
	results.best_overall_err = max(u64)

	if mode == 1 {
		c0 := params.pixels[0]
		all_same := true
		for i in 1 ..< params.num_pixels {
			if c0.rgb != params.pixels[i].rgb {
				all_same = false
				break
			}
		}

		if all_same {
			return pack_mode1_to_one_color(t, params, results, u32(c0[0]), u32(c0[1]), u32(c0[2]), results.selectors)
		}
	} else if mode == 7 {
		c0 := params.pixels[0]
		all_same := true
		for i in 1 ..< params.num_pixels {
			if c0 != params.pixels[i] {
				all_same = false
				break
			}
		}

		if all_same {
			return pack_mode7_to_one_color(
				t,
				params,
				results,
				u32(c0[0]),
				u32(c0[1]),
				u32(c0[2]),
				u32(c0[3]),
				results.selectors,
				params.num_pixels,
				params.pixels,
			)
		}
	}

	mean_color: Vec4
	axis: Vec4

	for i in 0 ..< params.num_pixels {
		mean_color += vec4_from_color(params.pixels[i])
	}

	mean_color_scaled := mean_color * (1 / f32(params.num_pixels))

	mean_color = vec4_saturate(mean_color * (1 / (f32(params.num_pixels) * 255)))

	if params.has_alpha {
		for i in 0 ..< params.num_pixels {
			color := vec4_from_color(params.pixels[i]) - mean_color_scaled
			a := color * color[0]
			b := color * color[1]
			c := color * color[2]
			d := color * color[3]
			n := vec4_normalize(i != 0 ? axis : color)
			axis[0] += vec4_dot(a, n)
			axis[1] += vec4_dot(b, n)
			axis[2] += vec4_dot(c, n)
			axis[3] += vec4_dot(d, n)
		}
		axis = vec4_normalize(axis)
	} else {
		cov: [6]f32

		for i in 0 ..< params.num_pixels {
			v := params.pixels[i]
			r := f32(v[0]) - mean_color_scaled[0]
			g := f32(v[1]) - mean_color_scaled[1]
			b := f32(v[2]) - mean_color_scaled[2]
			cov[0] += r * r
			cov[1] += r * g
			cov[2] += r * b
			cov[3] += g * g
			cov[4] += g * b
			cov[5] += b * b
		}

		vfr: f32 = .9
		vfg: f32 = 1
		vfb: f32 = .7
		for _ in 0 ..< 3 {
			r := vfr * cov[0] + vfg * cov[1] + vfb * cov[2]
			g := vfr * cov[1] + vfg * cov[3] + vfb * cov[4]
			b := vfr * cov[2] + vfg * cov[4] + vfb * cov[5]

			m := maxf(maxf(abs(r), abs(g)), abs(b))
			if m > 1e-10 {
				m = 1 / m
				r *= m
				g *= m
				b *= m
			}

			vfr = r
			vfg = g
			vfb = b
		}

		len_sq := vfr * vfr + vfg * vfg + vfb * vfb
		if len_sq >= 1e-10 {
			len_sq = 1 / math.sqrt(len_sq)
			vfr *= len_sq
			vfg *= len_sq
			vfb *= len_sq
			axis = {vfr, vfg, vfb, 0}
		}
	}

	if vec4_dot(axis, axis) < .5 {
		if params.perceptual {
			axis = {.213, .715, .072, params.has_alpha ? .715 : 0}
		} else {
			axis = {1, 1, 1, params.has_alpha ? 1 : 0}
		}
		axis = vec4_normalize(axis)
	}

	l: f32 = 1e9
	h: f32 = -1e9

	for i in 0 ..< params.num_pixels {
		q := vec4_from_color(params.pixels[i]) - mean_color_scaled
		d := vec4_dot(q, axis)

		l = minf(l, d)
		h = maxf(h, d)
	}

	l *= INVERSE_255
	h *= INVERSE_255

	min_color := vec4_saturate(mean_color + axis * l)
	max_color := vec4_saturate(mean_color + axis * h)

	white_vec := Vec4{1, 1, 1, 1}
	if vec4_dot(min_color, white_vec) > vec4_dot(max_color, white_vec) {
		min_color, max_color = max_color, min_color
	}

	if find_optimal_solution(t, mode, min_color, max_color, params, results, comp) == 0 {
		return 0
	}

	if comp.try_least_squares {
		if refine_from_selectors(t, mode, results.selectors, params, results, comp) == 0 {
			return 0
		}
	}

	// Above the documented maximum upstream's search grows without bound with the level.
	uber_level := min(comp.uber_level, MAX_UBER_LEVEL)

	if uber_level > 0 {
		selectors_temp, selectors_temp1: [16]u8
		for i in 0 ..< params.num_pixels {
			selectors_temp[i] = results.selectors[i]
		}

		max_selector := i32(params.num_selector_weights) - 1

		min_sel := u32(16)
		max_sel := u32(0)
		for i in 0 ..< params.num_pixels {
			sel := u32(selectors_temp[i])
			min_sel = min(min_sel, sel)
			max_sel = max(max_sel, sel)
		}

		for i in 0 ..< params.num_pixels {
			sel := u32(selectors_temp[i])
			if sel == min_sel && sel < params.num_selector_weights - 1 {
				sel += 1
			}
			selectors_temp1[i] = u8(sel)
		}

		if refine_from_selectors(t, mode, &selectors_temp1[0], params, results, comp) == 0 {
			return 0
		}

		for i in 0 ..< params.num_pixels {
			sel := u32(selectors_temp[i])
			if sel == max_sel && sel > 0 {
				sel -= 1
			}
			selectors_temp1[i] = u8(sel)
		}

		if refine_from_selectors(t, mode, &selectors_temp1[0], params, results, comp) == 0 {
			return 0
		}

		for i in 0 ..< params.num_pixels {
			sel := u32(selectors_temp[i])
			if sel == min_sel && sel < params.num_selector_weights - 1 {
				sel += 1
			} else if sel == max_sel && sel > 0 {
				sel -= 1
			}
			selectors_temp1[i] = u8(sel)
		}

		if refine_from_selectors(t, mode, &selectors_temp1[0], params, results, comp) == 0 {
			return 0
		}

		uber_err_thresh := u64((params.num_pixels * 56) >> 4)
		if uber_level >= 2 && results.best_overall_err > uber_err_thresh {
			q: i32 = uber_level >= 4 ? i32(uber_level) - 2 : 1
			for ly := -q; ly <= 1; ly += 1 {
				for hy := max_selector - 1; hy <= max_selector + q; hy += 1 {
					if ly == 0 && hy == max_selector {
						continue
					}

					for i in 0 ..< params.num_pixels {
						scaled := f32(max_selector) * (f32(selectors_temp[i]) - f32(ly)) / (f32(hy) - f32(ly)) + .5
						selectors_temp1[i] = u8(clampf(math.floor(scaled), 0, f32(max_selector)))
					}

					if refine_from_selectors(t, mode, &selectors_temp1[0], params, results, comp) == 0 {
						return 0
					}
				}
			}
		}
	}

	if mode == 1 || mode == 7 {
		avg_results := results^
		r := u32(i32(.5 + mean_color[0] * 255))
		g := u32(i32(.5 + mean_color[1] * 255))
		b := u32(i32(.5 + mean_color[2] * 255))

		avg_err: u64
		if mode == 1 {
			avg_err = pack_mode1_to_one_color(t, params, &avg_results, r, g, b, results.selectors_temp)
		} else {
			a := u32(i32(.5 + mean_color[3] * 255))
			avg_err = pack_mode7_to_one_color(t, params, &avg_results, r, g, b, a, results.selectors_temp, params.num_pixels, params.pixels)
		}

		if avg_err < results.best_overall_err {
			results^ = avg_results
			for i in 0 ..< params.num_pixels {
				results.selectors[i] = results.selectors_temp[i]
			}
			results.best_overall_err = avg_err
		}
	}

	return results.best_overall_err
}

// Mode 1 scans 8 selectors over RGB and mode 7 scans 4 over RGBA.
cell_compression_estimate :: proc(
	num_pixels: u32,
	pixels: [^]Color_Rgba,
	perceptual: bool,
	pweights: ^[4]u32,
	best_err_so_far: u64,
	palette_weights: [^]u32,
	n: u32,
	has_alpha: bool,
) -> u64 {
	nc := has_alpha ? 4 : 3

	low_color := Color_Rgba{255, 255, 255, 255}
	high_color: Color_Rgba
	for i in 0 ..< num_pixels {
		for j in 0 ..< nc {
			low_color[j] = min(low_color[j], pixels[i][j])
			high_color[j] = max(high_color[j], pixels[i][j])
		}
	}

	weighted: [8]Color_Rgba
	weighted[0] = low_color
	weighted[n - 1] = high_color
	for i in 1 ..< (n - 1) {
		w := palette_weights[i]
		for j in 0 ..< nc {
			weighted[i][j] = u8((u32(low_color[j]) * (64 - w) + u32(high_color[j]) * w + 32) >> 6)
		}
	}

	ar := i32(high_color[0]) - i32(low_color[0])
	ag := i32(high_color[1]) - i32(low_color[1])
	ab := i32(high_color[2]) - i32(low_color[2])
	aa := has_alpha ? i32(high_color[3]) - i32(low_color[3]) : 0

	dots: [8]i32
	for i in 0 ..< n {
		dots[i] = i32(weighted[i][0]) * ar + i32(weighted[i][1]) * ag + i32(weighted[i][2]) * ab
		if has_alpha {
			dots[i] += i32(weighted[i][3]) * aa
		}
	}

	thresh: [7]i32
	for i in 0 ..< (n - 1) {
		thresh[i] = (dots[i] + dots[i + 1] + 1) >> 1
	}

	select :: #force_inline proc "contextless" (d: i32, thresh: ^[7]i32, n: u32) -> u32 {
		for s := n - 1; s > 0; s -= 1 {
			if d >= thresh[s - 1] {
				return s
			}
		}
		return 0
	}

	total_err: u64
	if perceptual {
		l1, cr1, cb1: [8]i32
		for j in 0 ..< n {
			e := weighted[j]
			l1[j] = i32(e[0]) * 109 + i32(e[1]) * 366 + i32(e[2]) * 37
			cr1[j] = (i32(e[0]) << 9) - l1[j]
			cb1[j] = (i32(e[2]) << 9) - l1[j]
		}

		for i in 0 ..< num_pixels {
			c := pixels[i]

			d := ar * i32(c[0]) + ag * i32(c[1]) + ab * i32(c[2])
			if has_alpha {
				d += aa * i32(c[3])
			}

			s := select(d, &thresh, n)

			l2 := i32(c[0]) * 109 + i32(c[1]) * 366 + i32(c[2]) * 37
			cr2 := (i32(c[0]) << 9) - l2
			cb2 := (i32(c[2]) << 9) - l2

			dl := u32((l1[s] - l2) >> 8)
			dcr := u32((cr1[s] - cr2) >> 8)
			dcb := u32((cb1[s] - cb2) >> 8)

			ie := pweights[0] * dl * dl + pweights[1] * dcr * dcr + pweights[2] * dcb * dcb
			if has_alpha {
				dca := u32(i32(c[3]) - i32(weighted[s][3]))
				ie += pweights[3] * dca * dca
			}

			// Upstream stores it in an int, so it widens with sign extension.
			total_err += u64(i64(i32(ie)))
			if total_err > best_err_so_far {
				break
			}
		}
	} else {
		for i in 0 ..< num_pixels {
			c := pixels[i]

			d := ar * i32(c[0]) + ag * i32(c[1]) + ab * i32(c[2])
			if has_alpha {
				d += aa * i32(c[3])
			}

			e := weighted[select(d, &thresh, n)]

			dr := i32(e[0]) - i32(c[0])
			dg := i32(e[1]) - i32(c[1])
			db := i32(e[2]) - i32(c[2])

			ie := pweights[0] * u32(dr * dr) + pweights[1] * u32(dg * dg) + pweights[2] * u32(db * db)
			if has_alpha {
				da := i32(e[3]) - i32(c[3])
				ie += pweights[3] * u32(da * da)
			}

			total_err += u64(ie)
			if total_err > best_err_so_far {
				break
			}
		}
	}

	return total_err
}

// Which key partitions must rank best before a partition is worth evaluating.
@(rodata)
PARTITION_PREDICTORS := [35]u32 {
	max(u32),
	max(u32),
	max(u32),
	max(u32),
	max(u32),
	(1 << 1) | (1 << 2) | (1 << 8),
	(1 << 1) | (1 << 3) | (1 << 7),
	max(u32),
	max(u32),
	(1 << 2) | (1 << 8) | (1 << 16),
	(1 << 7) | (1 << 3) | (1 << 15),
	max(u32),
	(1 << 8) | (1 << 14) | (1 << 16),
	(1 << 7) | (1 << 14) | (1 << 15),
	max(u32),
	max(u32),
	max(u32),
	max(u32),
	(1 << 14) | (1 << 15),
	(1 << 16) | (1 << 22) | (1 << 14),
	(1 << 17) | (1 << 24) | (1 << 14),
	(1 << 2) | (1 << 14) | (1 << 15) | (1 << 1),
	max(u32),
	(1 << 1) | (1 << 3) | (1 << 14) | (1 << 16) | (1 << 22),
	max(u32),
	(1 << 1) | (1 << 2) | (1 << 15) | (1 << 17) | (1 << 24),
	(1 << 1) | (1 << 3) | (1 << 22),
	max(u32),
	max(u32),
	max(u32),
	(1 << 14) | (1 << 15) | (1 << 16) | (1 << 17),
	max(u32),
	max(u32),
	(1 << 1) | (1 << 2) | (1 << 3) | (1 << 27) | (1 << 4) | (1 << 24),
	(1 << 14) | (1 << 15) | (1 << 16) | (1 << 11) | (1 << 17) | (1 << 27),
}

estimate_partition :: proc(pixels: [^]Color_Rgba, comp: ^Params, pweights: ^[4]u32, mode: u32) -> u32 {
	total_partitions := min(comp.max_partitions, MAX_PARTITIONS)
	if total_partitions <= 1 {
		return 0
	}

	best_err := max(u64)
	best_partition := u32(0)
	best_key_partition := u32(0)

	for partition_iter := u32(0); partition_iter < total_partitions && best_err > 0; partition_iter += 1 {
		partition := u32(SORTED_PARTITION_ORDER[partition_iter])

		if comp.mode17_partition_estimation_filterbank && partition_iter >= 14 && partition_iter <= 34 {
			best_key_partition_bitmask := u32(1) << (best_key_partition + 1)
			if PARTITION_PREDICTORS[partition] & best_key_partition_bitmask == 0 {
				if partition_iter == 34 {
					break
				}
				continue
			}
		}

		subset_colors: [2][16]Color_Rgba
		subset_total_colors: [2]u32
		for index in u32(0) ..< 16 {
			s := BC7_PARTITION2[partition * 16 + index]
			subset_colors[s][subset_total_colors[s]] = pixels[index]
			subset_total_colors[s] += 1
		}

		total_subset_err: u64
		for subset := 0; subset < 2 && total_subset_err < best_err; subset += 1 {
			colors := &subset_colors[subset][0]
			if mode == 7 {
				total_subset_err += cell_compression_estimate(subset_total_colors[subset], colors, comp.perceptual, pweights, best_err, &BC7_WEIGHTS2[0], 4, true)
			} else {
				total_subset_err += cell_compression_estimate(subset_total_colors[subset], colors, comp.perceptual, pweights, best_err, &BC7_WEIGHTS3[0], 8, false)
			}
		}

		if partition < 16 {
			total_subset_err = u64(f64(total_subset_err) * f64(comp.low_frequency_partition_weight) + .5)
		}

		if total_subset_err < best_err {
			best_err = total_subset_err
			best_partition = partition
		}

		if partition == 34 && best_partition != 34 {
			break
		}

		if partition_iter == 13 {
			best_key_partition = best_partition
		}
	}

	return best_partition
}

set_block_bits :: proc "contextless" (bytes: [^]u8, val_in, num_bits_in: u32, cur_ofs: ^u32) {
	val := val_in
	num_bits := num_bits_in
	for num_bits != 0 {
		n := min(8 - (cur_ofs^ & 7), num_bits)
		bytes[cur_ofs^ >> 3] |= u8(val << (cur_ofs^ & 7))
		val >>= n
		num_bits -= n
		cur_ofs^ += n
	}
}

color_index_size :: #force_inline proc "contextless" (mode, index_selection_bit: u32) -> u32 {
	return u32(BC7_COLOR_INDEX_BITCOUNT[mode]) + index_selection_bit
}

alpha_index_size :: #force_inline proc "contextless" (mode, index_selection_bit: u32) -> u32 {
	return u32(BC7_ALPHA_INDEX_BITCOUNT[mode]) - index_selection_bit
}

mode_has_separate_alpha_selectors :: #force_inline proc "contextless" (mode: u32) -> bool {
	return mode == 4 || mode == 5
}

encode_bc7_block :: proc(block: [^]u8, opt: ^Optimization_Results) {
	best_mode := opt.mode

	total_subsets := u32(BC7_NUM_SUBSETS[best_mode])
	total_partitions := u32(1) << BC7_PARTITION_BITS[best_mode]

	partition_map: [^]u8
	switch total_subsets {
	case 1:
		partition_map = &BC7_PARTITION1[0]
	case 2:
		partition_map = &BC7_PARTITION2[opt.partition * 16]
	case:
		partition_map = &BC7_PARTITION3[opt.partition * 16]
	}

	color_selectors := opt.selectors
	alpha_selectors := opt.alpha_selectors
	low := opt.low
	high := opt.high
	pbits := opt.pbits

	anchor := [3]i32{-1, -1, -1}

	for k in u32(0) ..< total_subsets {
		anchor_index := u32(0)
		if k != 0 {
			if total_subsets == 3 && k == 1 {
				anchor_index = u32(BC7_ANCHOR_THIRD_SUBSET_1[opt.partition])
			} else if total_subsets == 3 && k == 2 {
				anchor_index = u32(BC7_ANCHOR_THIRD_SUBSET_2[opt.partition])
			} else {
				anchor_index = u32(BC7_ANCHOR_SECOND_SUBSET[opt.partition])
			}
		}

		anchor[k] = i32(anchor_index)

		color_index_bits := color_index_size(best_mode, opt.index_selector)
		num_color_indices := u32(1) << color_index_bits

		if u32(color_selectors[anchor_index]) & (num_color_indices >> 1) != 0 {
			for i in u32(0) ..< 16 {
				if u32(partition_map[i]) == k {
					color_selectors[i] = u8((num_color_indices - 1) - u32(color_selectors[i]))
				}
			}

			if mode_has_separate_alpha_selectors(best_mode) {
				for q in 0 ..< 3 {
					low[k][q], high[k][q] = high[k][q], low[k][q]
				}
			} else {
				low[k], high[k] = high[k], low[k]
			}

			if BC7_MODE_HAS_SHARED_P_BITS[best_mode] == 0 {
				pbits[k][0], pbits[k][1] = pbits[k][1], pbits[k][0]
			}
		}

		if mode_has_separate_alpha_selectors(best_mode) {
			alpha_index_bits := alpha_index_size(best_mode, opt.index_selector)
			num_alpha_indices := u32(1) << alpha_index_bits

			if u32(alpha_selectors[anchor_index]) & (num_alpha_indices >> 1) != 0 {
				for i in u32(0) ..< 16 {
					if u32(partition_map[i]) == k {
						alpha_selectors[i] = u8((num_alpha_indices - 1) - u32(alpha_selectors[i]))
					}
				}

				low[k][3], high[k][3] = high[k][3], low[k][3]
			}
		}
	}

	for i in 0 ..< BLOCK_SIZE {
		block[i] = 0
	}

	cur_bit_ofs: u32
	set_block_bits(block, u32(1) << best_mode, best_mode + 1, &cur_bit_ofs)

	if best_mode == 4 || best_mode == 5 {
		set_block_bits(block, opt.rotation, 2, &cur_bit_ofs)
	}

	if best_mode == 4 {
		set_block_bits(block, opt.index_selector, 1, &cur_bit_ofs)
	}

	if total_partitions > 1 {
		set_block_bits(block, opt.partition, total_partitions == 64 ? 6 : 4, &cur_bit_ofs)
	}

	total_comps := best_mode >= 4 ? 4 : 3
	for comp in 0 ..< total_comps {
		precision := comp == 3 ? u32(BC7_ALPHA_PRECISION[best_mode]) : u32(BC7_COLOR_PRECISION[best_mode])
		for subset in 0 ..< total_subsets {
			set_block_bits(block, u32(low[subset][comp]), precision, &cur_bit_ofs)
			set_block_bits(block, u32(high[subset][comp]), precision, &cur_bit_ofs)
		}
	}

	if BC7_MODE_HAS_P_BITS[best_mode] != 0 {
		for subset in 0 ..< total_subsets {
			set_block_bits(block, pbits[subset][0], 1, &cur_bit_ofs)
			if BC7_MODE_HAS_SHARED_P_BITS[best_mode] == 0 {
				set_block_bits(block, pbits[subset][1], 1, &cur_bit_ofs)
			}
		}
	}

	is_anchor :: #force_inline proc "contextless" (idx: i32, anchor: ^[3]i32) -> bool {
		return idx == anchor[0] || idx == anchor[1] || idx == anchor[2]
	}

	for idx in i32(0) ..< 16 {
		n := opt.index_selector != 0 ? alpha_index_size(best_mode, opt.index_selector) : color_index_size(best_mode, opt.index_selector)
		if is_anchor(idx, &anchor) {
			n -= 1
		}
		set_block_bits(block, u32(opt.index_selector != 0 ? alpha_selectors[idx] : color_selectors[idx]), n, &cur_bit_ofs)
	}

	if mode_has_separate_alpha_selectors(best_mode) {
		for idx in i32(0) ..< 16 {
			n := opt.index_selector != 0 ? color_index_size(best_mode, opt.index_selector) : alpha_index_size(best_mode, opt.index_selector)
			if is_anchor(idx, &anchor) {
				n -= 1
			}
			set_block_bits(block, u32(opt.index_selector != 0 ? color_selectors[idx] : alpha_selectors[idx]), n, &cur_bit_ofs)
		}
	}
}

handle_alpha_block_mode5 :: proc(
	t: ^Tables,
	pixels: [^]Color_Rgba,
	comp: ^Params,
	params: ^Cell_Params,
	lo_a_in, hi_a_in: u32,
	opt5: ^Optimization_Results,
) -> u64 {
	lo_a := lo_a_in
	hi_a := hi_a_in

	params.selector_weights = &BC7_WEIGHTS2[0]
	params.selector_weightsx = &BC7_WEIGHTS2X[0]
	params.num_selector_weights = 4

	params.comp_bits = 7
	params.has_pbits = false
	params.endpoints_share_pbit = false
	params.has_alpha = false

	params.perceptual = comp.perceptual

	params.num_pixels = 16
	params.pixels = pixels

	selectors_temp: [16]u8
	results5: Cell_Results
	results5.selectors = &opt5.selectors[0]
	results5.selectors_temp = &selectors_temp[0]

	mode5_err := color_cell_compression(t, 5, params, &results5, comp)

	opt5.low[0] = results5.low_endpoint
	opt5.high[0] = results5.high_endpoint

	if lo_a == hi_a {
		opt5.low[0][3] = u8(lo_a)
		opt5.high[0][3] = u8(hi_a)
		opt5.alpha_selectors = {}
		return mode5_err
	}

	mode5_alpha_err := max(u64)

	total_passes: u32 = comp.uber_level >= 1 ? 3 : 2
	for pass in u32(0) ..< total_passes {
		vals: [4]i32
		vals[0] = i32(lo_a)
		vals[3] = i32(hi_a)

		W_S1 :: 21
		W_S2 :: 43
		vals[1] = (vals[0] * (64 - W_S1) + vals[3] * W_S1 + 32) >> 6
		vals[2] = (vals[0] * (64 - W_S2) + vals[3] * W_S2 + 32) >> 6

		trial_alpha_selectors: [16]u8

		trial_alpha_err: u64
		for i in 0 ..< 16 {
			a := i32(params.pixels[i][3])

			s := u8(0)
			be := abs(a - vals[0])
			for j in 1 ..< 4 {
				e := abs(a - vals[j])
				if e < be {
					be = e
					s = u8(j)
				}
			}

			trial_alpha_selectors[i] = s

			trial_alpha_err += u64(u32(be * be) * params.weights[3])
		}

		if trial_alpha_err < mode5_alpha_err {
			mode5_alpha_err = trial_alpha_err
			opt5.low[0][3] = u8(lo_a)
			opt5.high[0][3] = u8(hi_a)
			opt5.alpha_selectors = trial_alpha_selectors
		}

		if pass != total_passes - 1 {
			xl, xh := least_squares_endpoints(16, &trial_alpha_selectors[0], &BC7_WEIGHTS2X[0], params.pixels, 3, 4)

			new_lo_a := u32(clamp(i32(math.floor(xl[3] + .5)), 0, 255))
			new_hi_a := u32(clamp(i32(math.floor(xh[3] + .5)), 0, 255))
			if new_lo_a > new_hi_a {
				new_lo_a, new_hi_a = new_hi_a, new_lo_a
			}

			if new_lo_a == lo_a && new_hi_a == hi_a {
				break
			}

			lo_a = new_lo_a
			hi_a = new_hi_a
		}
	}

	return mode5_err + mode5_alpha_err
}

// Upstream's casts of u64 * f32: the error is rounded to f32 before weighting.
weight_error :: #force_inline proc "contextless" (err: u64, weight: f32) -> u64 {
	return u64(f32(err) * weight + .5)
}

handle_alpha_block :: proc(t: ^Tables, block: [^]u8, pixels: [^]Color_Rgba, comp: ^Params, params: ^Cell_Params) {
	params.selector_weights = &BC7_WEIGHTS4[0]
	params.selector_weightsx = &BC7_WEIGHTS4X[0]
	params.num_selector_weights = 16
	params.comp_bits = 7
	params.has_pbits = true
	params.endpoints_share_pbit = false
	params.has_alpha = true
	params.perceptual = comp.perceptual
	params.num_pixels = 16
	params.pixels = pixels

	opt6, opt5, opt7: Optimization_Results
	results6: Cell_Results

	best_err := max(u64)
	best_mode := u32(0)
	selectors_temp: [16]u8

	if comp.mode_mask & (1 << 6) != 0 {
		results6.selectors = &opt6.selectors[0]
		results6.selectors_temp = &selectors_temp[0]

		best_err = weight_error(color_cell_compression(t, 6, params, &results6, comp), comp.mode6_error_weight)
		best_mode = 6
	}

	if best_err > 0 && comp.mode_mask & (1 << 5) != 0 {
		lo_a := u32(255)
		hi_a := u32(0)
		for i in 0 ..< 16 {
			a := u32(pixels[i][3])
			lo_a = min(lo_a, a)
			hi_a = max(hi_a, a)
		}

		mode5_err := handle_alpha_block_mode5(t, pixels, comp, params, lo_a, hi_a, &opt5)
		mode5_err = weight_error(mode5_err, comp.mode5_error_weight)

		if mode5_err < best_err {
			best_err = mode5_err
			best_mode = 5
		}
	}

	if best_err > 0 && comp.mode_mask & (1 << 7) != 0 {
		trial_partition := estimate_partition(pixels, comp, &params.weights, 7)

		params.selector_weights = &BC7_WEIGHTS2[0]
		params.selector_weightsx = &BC7_WEIGHTS2X[0]
		params.num_selector_weights = 4
		params.comp_bits = 5
		params.has_pbits = true
		params.endpoints_share_pbit = false
		params.has_alpha = true

		subset_colors: [2][16]Color_Rgba
		subset_total_colors7: [2]u32
		subset_pixel_index7, subset_selectors7: [2][16]u8
		subset_results7: [2]Cell_Results
		defer params.pixels = nil

		for idx in u32(0) ..< 16 {
			p := BC7_PARTITION2[trial_partition * 16 + idx]
			subset_colors[p][subset_total_colors7[p]] = pixels[idx]
			subset_pixel_index7[p][subset_total_colors7[p]] = u8(idx)
			subset_total_colors7[p] += 1
		}

		trial_err: u64
		for subset in 0 ..< 2 {
			params.num_pixels = subset_total_colors7[subset]
			params.pixels = &subset_colors[subset][0]

			results := &subset_results7[subset]
			results.selectors = &subset_selectors7[subset][0]
			results.selectors_temp = &selectors_temp[0]
			trial_err += color_cell_compression(t, 7, params, results, comp)
			if weight_error(trial_err, comp.mode7_error_weight) > best_err {
				break
			}
		}

		mode7_trial_err := weight_error(trial_err, comp.mode7_error_weight)

		if mode7_trial_err < best_err {
			best_err = mode7_trial_err
			best_mode = 7
			opt7.mode = 7
			opt7.partition = trial_partition
			opt7.index_selector = 0
			opt7.rotation = 0
			for subset in 0 ..< 2 {
				for i in 0 ..< subset_total_colors7[subset] {
					opt7.selectors[subset_pixel_index7[subset][i]] = subset_selectors7[subset][i]
				}
				opt7.low[subset] = subset_results7[subset].low_endpoint
				opt7.high[subset] = subset_results7[subset].high_endpoint
				opt7.pbits[subset][0] = subset_results7[subset].pbits[0]
				opt7.pbits[subset][1] = subset_results7[subset].pbits[1]
			}
		}
	}

	switch best_mode {
	case 7:
		encode_bc7_block(block, &opt7)
	case 5:
		opt5.mode = 5
		opt5.partition = 0
		opt5.rotation = 0
		opt5.index_selector = 0
		encode_bc7_block(block, &opt5)
	case 6:
		opt6.mode = 6
		opt6.partition = 0
		opt6.low[0] = results6.low_endpoint
		opt6.high[0] = results6.high_endpoint
		opt6.pbits[0][0] = results6.pbits[0]
		opt6.pbits[0][1] = results6.pbits[1]
		opt6.rotation = 0
		opt6.index_selector = 0
		encode_bc7_block(block, &opt6)
	}
}

handle_opaque_block :: proc(t: ^Tables, block: [^]u8, pixels: [^]Color_Rgba, comp: ^Params, params: ^Cell_Params) {
	selectors_temp: [16]u8

	opt: Optimization_Results

	best_err := max(u64)

	params.perceptual = comp.perceptual
	params.num_pixels = 16
	params.pixels = pixels
	params.has_alpha = false

	opt.partition = 0
	opt.index_selector = 0
	opt.rotation = 0

	if comp.mode_mask & (1 << 6) != 0 {
		params.selector_weights = &BC7_WEIGHTS4[0]
		params.selector_weightsx = &BC7_WEIGHTS4X[0]
		params.num_selector_weights = 16
		params.comp_bits = 7
		params.has_pbits = true
		params.endpoints_share_pbit = false

		results6: Cell_Results
		results6.selectors = &opt.selectors[0]
		results6.selectors_temp = &selectors_temp[0]

		best_err = weight_error(color_cell_compression(t, 6, params, &results6, comp), comp.mode6_error_weight)

		opt.mode = 6
		opt.low[0] = results6.low_endpoint
		opt.high[0] = results6.high_endpoint
		opt.pbits[0][0] = results6.pbits[0]
		opt.pbits[0][1] = results6.pbits[1]
	}

	if best_err > 0 && comp.max_partitions > 0 && comp.mode_mask & (1 << 1) != 0 {
		trial_partition := estimate_partition(pixels, comp, &params.weights, 1)

		params.selector_weights = &BC7_WEIGHTS3[0]
		params.selector_weightsx = &BC7_WEIGHTS3X[0]
		params.num_selector_weights = 8
		params.comp_bits = 6
		params.has_pbits = true
		params.endpoints_share_pbit = true

		subset_colors: [2][16]Color_Rgba
		subset_total_colors1: [2]u32
		subset_pixel_index1, subset_selectors1: [2][16]u8
		subset_results1: [2]Cell_Results
		defer params.pixels = nil

		for idx in u32(0) ..< 16 {
			p := BC7_PARTITION2[trial_partition * 16 + idx]
			subset_colors[p][subset_total_colors1[p]] = pixels[idx]
			subset_pixel_index1[p][subset_total_colors1[p]] = u8(idx)
			subset_total_colors1[p] += 1
		}

		trial_err: u64
		for subset in 0 ..< 2 {
			params.num_pixels = subset_total_colors1[subset]
			params.pixels = &subset_colors[subset][0]

			results := &subset_results1[subset]
			results.selectors = &subset_selectors1[subset][0]
			results.selectors_temp = &selectors_temp[0]
			trial_err += color_cell_compression(t, 1, params, results, comp)

			if weight_error(trial_err, comp.mode1_error_weight) > best_err {
				break
			}
		}

		mode1_trial_err := weight_error(trial_err, comp.mode1_error_weight)
		if mode1_trial_err < best_err {
			best_err = mode1_trial_err
			opt.mode = 1
			opt.partition = trial_partition
			for subset in 0 ..< 2 {
				for i in 0 ..< subset_total_colors1[subset] {
					opt.selectors[subset_pixel_index1[subset][i]] = subset_selectors1[subset][i]
				}
				opt.low[subset] = subset_results1[subset].low_endpoint
				opt.high[subset] = subset_results1[subset].high_endpoint
				opt.pbits[subset][0] = subset_results1[subset].pbits[0]
			}
		}
	}

	encode_bc7_block(block, &opt)
}
