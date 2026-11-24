package mirai_render

import "mirai:asset"
import "mirai:render/abi"
import "mirai:rhi"

@(private)
Texture_Plane_Mip :: struct {
	index: asset.Texture_Field_Index,
	rows:  []asset.Texture_Field_Counts,
}

Bc_Upload_Header :: struct {
	columns, rows, words, modes: u32,
}

Bc_Upload_Mode :: struct {
	layout:  asset.Texture_Field_Mode,
	offsets: [asset.TEXTURE_FIELD_PLANES]u32,
	bit_groups, first_bit: u32,
}

#assert(size_of(Bc_Upload_Header) == 16)
#assert(size_of(Bc_Upload_Mode) ==
	4 * (4 + 2 * asset.TEXTURE_FIELD_PLANES + asset.TEXTURE_FIELD_SPANS))

@(private)
texture_field_format :: proc "contextless" (format: rhi.Format) -> asset.Texture_Format {
	#partial switch format {
	case .BC1_Unorm, .BC1_Srgb: return .BC1
	case .BC5_Unorm: return .BC5
	case .BC6H_Ufloat: return .BC6H
	case .BC7_Unorm, .BC7_Srgb: return .BC7
	}
	return .RGBA8
}

@(private)
texture_plane_mips :: proc(r: ^Renderer, format: asset.Texture_Format, width, height: u32,
	levels: [][]u8) -> (mips: []Texture_Plane_Mip, ok: bool) {
	if !asset.texture_fields_format(format) {return}
	made, allocation := make([]Texture_Plane_Mip, len(levels), r.allocator)
	if allocation != nil {return}
	defer if !ok {texture_plane_mips_free(r, made)}
	layout := asset.texture_field_layout(format)
	stride := asset.texture_block_bytes(format)
	for level, i in levels {
		columns := int((max(width >> uint(i), 1) + 3) / 4)
		rows := int((max(height >> uint(i), 1) + 3) / 4)
		n := columns * rows
		mip := &made[i]
		if layout.modes == 0 {
			if len(level) != n * stride {return}
			mip.index.counts[0] = u32(n)
			at := 0
			for bytes, p in layout.mode[0].widths {
				mip.index.offsets[0][p] = at
				at += int(bytes) * n
			}
			continue
		}
		if mip.rows, allocation = make([]asset.Texture_Field_Counts, rows + 1, r.allocator);
			allocation != nil {return}
		// One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
		index, valid := asset.texture_fields_index(&layout, level, n, mip.rows)
		if !valid {return}
		mip.index = index
	}
	return made, true
}

@(private)
texture_plane_mips_free :: proc(r: ^Renderer, mips: []Texture_Plane_Mip) {
	for mip in mips {delete(mip.rows, r.allocator)}
	delete(mips, r.allocator)
}

@(private)
texture_bc_scratch :: proc(r: ^Renderer) -> bool {
	t := &r.textures.residency
	if t.bc_scratch == 0 {
		t.bc_scratch = rhi.buffer_create(r.device, {size = UPLOAD_FRAME_BYTES,
			usage = {.Storage, .Transfer_Src}, name = "BC texture upload scratch"})
	}
	return t.bc_scratch != 0
}

// Stages contiguous slices of each plane. Row checkpoints bound those slices;
// the shader ranks the blocks within each row.
@(private)
texture_bc_batch :: proc(layout: ^asset.Texture_Field_Layout, mip: ^Texture_Plane_Mip,
	level: []u8, columns, row, rows, stride: int, dst: []u8 = nil) -> (size: int) {
	modes := max(layout.modes, 1)
	at := size_of(Bc_Upload_Header) + modes * size_of(Bc_Upload_Mode)
	modes_at := at
	first, last: asset.Texture_Field_Counts
	first[0], last[0] = u32(row * columns), u32((row + rows) * columns)
	if layout.modes > 0 {
		first, last = mip.rows[row], mip.rows[row + rows]
		at += columns * rows
		row_at := (at + 3) & ~int(3)
		at = row_at + rows * size_of(asset.Texture_Field_Counts)
		if dst != nil {
			copy(dst[modes_at:], mip.index.modes[row * columns:][:rows * columns])
			checkpoints := ([^]asset.Texture_Field_Counts)(raw_data(dst[row_at:]))
			for i in 0..<rows {
				for m in 0..<modes {checkpoints[i][m] = mip.rows[row + i][m] - first[m]}
			}
		}
	}
	if dst != nil {
		header := (^Bc_Upload_Header)(raw_data(dst))
		header^ = {u32(columns), u32(rows), u32(stride / 4), u32(layout.modes)}
	}
	for m in 0..<modes {
		count := int(last[m] - first[m])
		if count == 0 {continue}
		mode := &layout.mode[m]
		upload := Bc_Upload_Mode{layout = mode^}
		first_group := int(first[m]) / 8
		groups := asset.texture_field_group_count(int(last[m])) - first_group
		upload.bit_groups, upload.first_bit = u32(groups), first[m] % 8
		for width, p in mode.widths {
			if width == 0 {continue}
			from := mip.index.offsets[m][p]
			upload.offsets[p] = u32(at)
			if asset.texture_field_bit_plane(mode, p) {
				bytes := int(width) * 8 * groups
				if dst != nil {
					all_groups := asset.texture_field_group_count(int(mip.index.counts[m]))
					for bit in 0..<int(width) * 8 {
						start := from + bit * all_groups + first_group
						copy(dst[at + bit * groups:][:groups], level[start:][:groups])
					}
				}
				at += bytes
			} else {
				bytes := int(width) * count
				if dst != nil {
					from += int(first[m]) * int(width)
					copy(dst[at:][:bytes], level[from:][:bytes])
				}
				at += bytes
			}
		}
		if dst != nil {
			(([^]Bc_Upload_Mode)(raw_data(dst[size_of(Bc_Upload_Header):])))[m] = upload
		}
	}
	return (at + 3) & ~int(3)
}

@(private)
texture_bc_fit :: proc(layout: ^asset.Texture_Field_Layout, mip: ^Texture_Plane_Mip,
	level: []u8, columns, row, rows, stride: int, budget: u64) -> (count, size: int) {
	size = texture_bc_batch(layout, mip, level, columns, row, rows, stride)
	if u64(size) <= budget || rows == 1 {return rows, size}
	low, high := 1, rows - 1
	for low < high {
		mid := (low + high + 1) / 2
		if u64(texture_bc_batch(layout, mip, level, columns, row, mid, stride)) <= budget {
			low = mid
		} else {
			high = mid - 1
		}
	}
	return low, texture_bc_batch(layout, mip, level, columns, row, low, stride)
}

@(private)
texture_bc_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List, input: rhi.Transient,
	columns, rows: u32, mode_planes: bool) {
	rhi.cmd_bind_pipeline(cmd, r.pipelines[.Bc_Reassemble])
	rhi.cmd_bind_transient(cmd, abi.SLOT_PASS0, input)
	rhi.cmd_bind_buffer(cmd, abi.SLOT_PASS1, r.textures.residency.bc_scratch)
	if mode_planes {
		rhi.cmd_dispatch(cmd, rows)
	} else {
		rhi.cmd_dispatch(cmd, groups(columns * rows, BC_UPLOAD_LANES))
	}
}

BC_UPLOAD_LANES :: 32

@(private)
texture_bc_copy :: proc(r: ^Renderer, cmd: ^rhi.Command_List, input: rhi.Transient,
	texture: rhi.Texture, mip, width, height, row, rows: u32, mode_planes: bool) {
	texture_bc_record(r, cmd, input, (width + 3) / 4, rows, mode_planes)
	rhi.cmd_copy_buffer_to_texture(cmd, r.textures.residency.bc_scratch, 0, texture, mip,
		{0, row * 4, width, min(rows * 4, height - row * 4)})
}

// Immediate loads use one staging allocation and one submission for the texture.
@(private)
texture_bc_upload :: proc(r: ^Renderer, texture: rhi.Texture, format: asset.Texture_Format,
	width, height: u32, levels: [][]u8) -> bool {
	mips, ok := texture_plane_mips(r, format, width, height, levels)
	if !ok {return false}
	defer texture_plane_mips_free(r, mips)
	if !texture_bc_scratch(r) {return false}
	layout := asset.texture_field_layout(format)
	stride := asset.texture_block_bytes(format)
	alignment := max(rhi.device_info(r.device).storage_alignment, 16)
	total: u64
	for pass in 0..<2 {
		buffer: rhi.Buffer
		cmd: ^rhi.Command_List
		base: [^]u8
		if pass == 1 {
			buffer = rhi.buffer_create(r.device, {size = total, usage = {.Storage},
				memory = .Upload, name = "BC texture load staging"})
			if buffer == 0 {return false}
			base = ([^]u8)(rhi.buffer_mapped(r.device, buffer))
			if base != nil {cmd = rhi.immediate_begin(r.device)}
		}
		defer if buffer != 0 {rhi.buffer_destroy(r.device, buffer)}
		if pass == 1 && cmd == nil {return false}
		at: u64
		for level, i in levels {
			w, h := max(width >> uint(i), 1), max(height >> uint(i), 1)
			columns, rows := int((w + 3) / 4), int((h + 3) / 4)
			step := max(UPLOAD_FRAME_BYTES / (columns * stride), 1)
			for row := 0; row < rows; row += step {
				n := min(rows - row, step)
				size := texture_bc_batch(&layout, &mips[i], level, columns, row, n, stride)
				at = rhi.align_up(at, alignment)
				if pass == 1 {
					texture_bc_batch(&layout, &mips[i], level, columns, row, n, stride,
						base[at:][:size])
					texture_bc_copy(r, cmd, {buffer = buffer, offset = at, size = u64(size)},
						texture, u32(i), w, h, u32(row), u32(n), layout.modes > 0)
				}
				at += u64(size)
			}
		}
		total = at
		if pass == 1 {
			rhi.cmd_barrier_texture(cmd, texture, .Shader_Read)
			return rhi.immediate_end(r.device, cmd, wait = false)
		}
	}
	return false
}
