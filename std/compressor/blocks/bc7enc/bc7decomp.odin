package bc7enc

// Writes 16 RGBA8 texels. Returns false for the reserved mode, whose texels are all zero.
unpack_bc7 :: proc(block: [^]u8, pixels: [^]u8) -> bool {
	out := cast([^]Color_Rgba)pixels
	mode := u32(BC7_FIRST_BYTE_TO_MODE[block[0]])

	chunks: [2]u64
	for chunk in 0 ..< 2 {
		for byte in 0 ..< 8 {
			chunks[chunk] |= u64(block[chunk * 8 + byte]) << u32(byte * 8)
		}
	}

	switch mode {
	case 0, 2:
		return unpack_mode0_2(mode, chunks, out)
	case 1, 3, 7:
		return unpack_mode1_3_7(mode, chunks, out)
	case 4, 5:
		return unpack_mode4_5(mode, chunks, out)
	case 6:
		return unpack_mode6(chunks, out)
	}

	for i in 0 ..< 16 {
		out[i] = {}
	}
	return false
}

@(private = "file")
insert_weight_zero :: proc(index_bits: ^u64, bits_per_index, offset: u32) {
	low_mask := (u64(1) << ((bits_per_index * (offset + 1)) - 1)) - 1
	high_mask := ~low_mask
	index_bits^ = ((index_bits^ & high_mask) << 1) | (index_bits^ & low_mask)
}

@(private = "file")
dequant_pbit :: proc(val, pbit, val_bits: u32) -> u32 {
	total_bits := val_bits + 1
	v := (val << 1) | pbit
	v <<= (8 - total_bits)
	v |= v >> total_bits
	return v
}

@(private = "file")
dequant :: proc(val, val_bits: u32) -> u32 {
	v := val << (8 - val_bits)
	v |= v >> val_bits
	return v
}

@(private = "file")
interp :: proc(l, h, w, bits: u32) -> u32 {
	switch bits {
	case 2:
		return (l * (64 - BC7_WEIGHTS2[w]) + h * BC7_WEIGHTS2[w] + 32) >> 6
	case 3:
		return (l * (64 - BC7_WEIGHTS3[w]) + h * BC7_WEIGHTS3[w] + 32) >> 6
	case 4:
		return (l * (64 - BC7_WEIGHTS4[w]) + h * BC7_WEIGHTS4[w] + 32) >> 6
	}
	return 0
}

@(private = "file")
mask_u64 :: proc(bits: u32) -> u64 {
	return (u64(1) << bits) - 1
}

@(private = "file")
unpack_mode0_2 :: proc(mode: u32, chunks: [2]u64, pixels: [^]Color_Rgba) -> bool {
	ENDPOINTS :: 6
	COMPS :: 3
	weight_bits: u32 = mode == 0 ? 3 : 2
	weight_mask := mask_u64(weight_bits)
	endpoint_bits: u32 = mode == 0 ? 4 : 5
	endpoint_mask := mask_u64(endpoint_bits)
	has_pbits := mode == 0
	weight_vals := u32(1) << weight_bits
	part_bits: u32 = mode == 0 ? 4 : 6

	low_chunk := chunks[0]
	high_chunk := chunks[1]

	part := u32((low_chunk >> (mode + 1)) & mask_u64(part_bits))

	channel_read_chunks: [3]u64
	if mode == 0 {
		channel_read_chunks[0] = low_chunk >> 5
		channel_read_chunks[1] = low_chunk >> 29
		channel_read_chunks[2] = (low_chunk >> 53) | (high_chunk << 11)
	} else {
		channel_read_chunks[0] = low_chunk >> 9
		channel_read_chunks[1] = (low_chunk >> 39) | (high_chunk << 25)
		channel_read_chunks[2] = high_chunk >> 5
	}

	endpoints: [ENDPOINTS]Color_Rgba
	for c in 0 ..< COMPS {
		channel_read_chunk := channel_read_chunks[c]
		for e in 0 ..< ENDPOINTS {
			endpoints[e][c] = u8(channel_read_chunk & endpoint_mask)
			channel_read_chunk >>= endpoint_bits
		}
	}

	pbits: [6]u32
	if has_pbits {
		p_bits_chunk := u32((high_chunk >> 13) & 0xff)
		for p in u32(0) ..< 6 {
			pbits[p] = (p_bits_chunk >> p) & 1
		}
	}

	weights_read_chunk := high_chunk >> (67 - 16 * weight_bits)
	anchor1 := u32(BC7_ANCHOR_THIRD_SUBSET_1[part])
	anchor2 := u32(BC7_ANCHOR_THIRD_SUBSET_2[part])
	insert_weight_zero(&weights_read_chunk, weight_bits, 0)
	insert_weight_zero(&weights_read_chunk, weight_bits, min(anchor1, anchor2))
	insert_weight_zero(&weights_read_chunk, weight_bits, max(anchor1, anchor2))

	weights: [16]u32
	for i in 0 ..< 16 {
		weights[i] = u32(weights_read_chunk & weight_mask)
		weights_read_chunk >>= weight_bits
	}

	for e in 0 ..< ENDPOINTS {
		for c in 0 ..< COMPS {
			v := u32(endpoints[e][c])
			endpoints[e][c] = u8(has_pbits ? dequant_pbit(v, pbits[e], endpoint_bits) : dequant(v, endpoint_bits))
		}
		endpoints[e][3] = 255
	}

	block_colors: [3][8]Color_Rgba
	for s in 0 ..< 3 {
		for i in u32(0) ..< weight_vals {
			for c in 0 ..< COMPS {
				block_colors[s][i][c] = u8(interp(u32(endpoints[s * 2][c]), u32(endpoints[s * 2 + 1][c]), i, weight_bits))
			}
			block_colors[s][i][3] = 255
		}
	}

	for i in u32(0) ..< 16 {
		pixels[i] = block_colors[BC7_PARTITION3[part * 16 + i]][weights[i]]
	}

	return true
}

@(private = "file")
unpack_mode1_3_7 :: proc(mode: u32, chunks: [2]u64, pixels: [^]Color_Rgba) -> bool {
	ENDPOINTS :: 4
	comps: int = mode == 7 ? 4 : 3
	weight_bits: u32 = mode == 1 ? 3 : 2
	weight_mask := mask_u64(weight_bits)
	endpoint_bits: u32 = mode == 7 ? 5 : (mode == 1 ? 6 : 7)
	endpoint_mask := mask_u64(endpoint_bits)
	num_pbits: u32 = mode == 1 ? 2 : 4
	shared_pbits := mode == 1
	weight_vals := u32(1) << weight_bits

	low_chunk := chunks[0]
	high_chunk := chunks[1]

	part := u32((low_chunk >> (mode + 1)) & 0x3f)

	endpoints: [ENDPOINTS]Color_Rgba

	channel_read_chunks: [4]u64
	p_read_chunk: u64
	channel_read_chunks[0] = low_chunk >> (mode + 7)
	weight_read_chunk: u64

	switch mode {
	case 1:
		channel_read_chunks[1] = low_chunk >> 32
		channel_read_chunks[2] = (low_chunk >> 56) | (high_chunk << 8)
		p_read_chunk = high_chunk >> 16
		weight_read_chunk = high_chunk >> 18
	case 3:
		channel_read_chunks[1] = (low_chunk >> 38) | (high_chunk << 26)
		channel_read_chunks[2] = high_chunk >> 2
		p_read_chunk = high_chunk >> 30
		weight_read_chunk = high_chunk >> 34
	case 7:
		channel_read_chunks[1] = low_chunk >> 34
		channel_read_chunks[2] = (low_chunk >> 54) | (high_chunk << 10)
		channel_read_chunks[3] = high_chunk >> 10
		p_read_chunk = high_chunk >> 30
		weight_read_chunk = high_chunk >> 34
	case:
		return false
	}

	for c in 0 ..< comps {
		channel_read_chunk := channel_read_chunks[c]
		for e in 0 ..< ENDPOINTS {
			endpoints[e][c] = u8(channel_read_chunk & endpoint_mask)
			channel_read_chunk >>= endpoint_bits
		}
	}

	pbits: [4]u32
	for p in u32(0) ..< num_pbits {
		pbits[p] = u32((p_read_chunk >> p) & 1)
	}

	insert_weight_zero(&weight_read_chunk, weight_bits, 0)
	insert_weight_zero(&weight_read_chunk, weight_bits, u32(BC7_ANCHOR_SECOND_SUBSET[part]))

	weights: [16]u32
	for i in 0 ..< 16 {
		weights[i] = u32(weight_read_chunk & weight_mask)
		weight_read_chunk >>= weight_bits
	}

	for e in 0 ..< ENDPOINTS {
		for c in 0 ..< 4 {
			if mode != 7 && c == 3 {
				endpoints[e][c] = 255
			} else {
				endpoints[e][c] = u8(dequant_pbit(u32(endpoints[e][c]), pbits[shared_pbits ? e >> 1 : e], endpoint_bits))
			}
		}
	}

	block_colors: [2][8]Color_Rgba
	for s in 0 ..< 2 {
		for i in u32(0) ..< weight_vals {
			for c in 0 ..< comps {
				block_colors[s][i][c] = u8(interp(u32(endpoints[s * 2][c]), u32(endpoints[s * 2 + 1][c]), i, weight_bits))
			}
			if comps == 3 {
				block_colors[s][i][3] = 255
			}
		}
	}

	for i in u32(0) ..< 16 {
		pixels[i] = block_colors[BC7_PARTITION2[part * 16 + i]][weights[i]]
	}

	return true
}

@(private = "file")
unpack_mode4_5 :: proc(mode: u32, chunks: [2]u64, pixels: [^]Color_Rgba) -> bool {
	ENDPOINTS :: 2
	color_weight_bits: u32 = 2
	color_weight_mask := mask_u64(color_weight_bits)
	a_weight_bits: u32 = mode == 4 ? 3 : 2
	a_weight_mask := mask_u64(a_weight_bits)
	endpoint_bits: u32 = mode == 4 ? 5 : 7
	endpoint_mask := mask_u64(endpoint_bits)
	a_endpoint_bits: u32 = mode == 4 ? 6 : 8
	a_endpoint_mask := mask_u64(a_endpoint_bits)

	low_chunk := chunks[0]
	high_chunk := chunks[1]

	comp_rot := u32((low_chunk >> (mode + 1)) & 0x3)
	index_mode := mode == 4 && ((low_chunk >> 7) & 1) != 0

	color_read_bits := low_chunk >> 8

	endpoints: [ENDPOINTS]Color_Rgba
	for c in 0 ..< 3 {
		for e in 0 ..< ENDPOINTS {
			endpoints[e][c] = u8(color_read_bits & endpoint_mask)
			color_read_bits >>= endpoint_bits
		}
	}

	rgb_weights_chunk, a_weights_chunk: u64
	if mode == 4 {
		endpoints[0][3] = u8(color_read_bits & a_endpoint_mask)
		endpoints[1][3] = u8((color_read_bits >> a_endpoint_bits) & a_endpoint_mask)
		rgb_weights_chunk = (low_chunk >> 50) | (high_chunk << 14)
		a_weights_chunk = high_chunk >> 17
	} else if mode == 5 {
		endpoints[0][3] = u8(color_read_bits & a_endpoint_mask)
		endpoints[1][3] = u8(((low_chunk >> 58) | (high_chunk << 6)) & a_endpoint_mask)
		rgb_weights_chunk = high_chunk >> 2
		a_weights_chunk = high_chunk >> 33
	} else {
		return false
	}

	insert_weight_zero(&rgb_weights_chunk, color_weight_bits, 0)
	insert_weight_zero(&a_weights_chunk, a_weight_bits, 0)

	weight_bits := [2]u32{index_mode ? a_weight_bits : color_weight_bits, index_mode ? color_weight_bits : a_weight_bits}
	weight_mask := [2]u64{index_mode ? a_weight_mask : color_weight_mask, index_mode ? color_weight_mask : a_weight_mask}

	if index_mode {
		rgb_weights_chunk, a_weights_chunk = a_weights_chunk, rgb_weights_chunk
	}

	weights, a_weights: [16]u32
	for i in 0 ..< 16 {
		weights[i] = u32(rgb_weights_chunk & weight_mask[0])
		rgb_weights_chunk >>= weight_bits[0]
	}
	for i in 0 ..< 16 {
		a_weights[i] = u32(a_weights_chunk & weight_mask[1])
		a_weights_chunk >>= weight_bits[1]
	}

	for e in 0 ..< ENDPOINTS {
		for c in 0 ..< 4 {
			endpoints[e][c] = u8(dequant(u32(endpoints[e][c]), c == 3 ? a_endpoint_bits : endpoint_bits))
		}
	}

	block_colors: [8]Color_Rgba
	for i in u32(0) ..< (u32(1) << weight_bits[0]) {
		for c in 0 ..< 3 {
			block_colors[i][c] = u8(interp(u32(endpoints[0][c]), u32(endpoints[1][c]), i, weight_bits[0]))
		}
	}
	for i in u32(0) ..< (u32(1) << weight_bits[1]) {
		block_colors[i][3] = u8(interp(u32(endpoints[0][3]), u32(endpoints[1][3]), i, weight_bits[1]))
	}

	for i in 0 ..< 16 {
		pixels[i] = block_colors[weights[i]]
		pixels[i][3] = block_colors[a_weights[i]][3]
		if comp_rot >= 1 {
			pixels[i][3], pixels[i][comp_rot - 1] = pixels[i][comp_rot - 1], pixels[i][3]
		}
	}

	return true
}

@(private = "file")
unpack_mode6 :: proc(chunks: [2]u64, pixels: [^]Color_Rgba) -> bool {
	lo := chunks[0]
	hi := chunks[1]

	if lo & 0x7f != 1 << 6 {
		return false
	}

	p0 := u32(lo >> 63) & 1
	p1 := u32(hi) & 1

	endpoint :: proc(lo: u64, shift: u32, pbit: u32) -> u32 {
		return (u32((lo >> shift) & 0x7f) << 1) | pbit
	}

	r0 := endpoint(lo, 7, p0)
	r1 := endpoint(lo, 14, p1)
	g0 := endpoint(lo, 21, p0)
	g1 := endpoint(lo, 28, p1)
	b0 := endpoint(lo, 35, p0)
	b1 := endpoint(lo, 42, p1)
	a0 := endpoint(lo, 49, p0)
	a1 := endpoint(lo, 56, p1)

	vals: [16]Color_Rgba
	for i in 0 ..< 16 {
		w := BC7_WEIGHTS4[i]
		iw := 64 - w
		vals[i] = {
			u8((r0 * iw + r1 * w + 32) >> 6),
			u8((g0 * iw + g1 * w + 32) >> 6),
			u8((b0 * iw + b1 * w + 32) >> 6),
			u8((a0 * iw + a1 * w + 32) >> 6),
		}
	}

	pixels[0] = vals[(hi >> 1) & 0x7]
	for i in u32(1) ..< 16 {
		pixels[i] = vals[(hi >> (i * 4)) & 0xf]
	}

	return true
}
