package rhi

import "core:testing"

// A copy between textures carries bytes: it takes two of one shape whose
// formats hold the same ones, and refuses the others before a backend sees them.
@(test)
a_texture_copy_takes_two_textures_that_hold_the_same_bytes :: proc(t: ^testing.T) {
	image := Texture_Desc{width = 64, height = 32, format = .RGBA8_Unorm}
	Case :: struct {
		name:     string,
		src, dst: Texture_Desc,
		copies:   bool,
	}
	encoded, wider, array, volume, float, blocks, blocks_encoded, chain, half := image, image, image, image, image, image, image, image, image
	encoded.format = .RGBA8_Srgb
	wider.width = 128
	array.layers = 2
	volume.depth = 4
	float.format = .R32_Float
	blocks.format, blocks_encoded.format = .BC7_Unorm, .BC7_Srgb
	chain.mip_levels = 7
	half.width, half.height, half.mip_levels = 32, 16, 6
	cases := []Case {
		{"one format", image, image, true},
		{"into the sRGB encoding", image, encoded, true},
		{"out of the sRGB encoding", encoded, image, true},
		{"blocks into their sRGB encoding", blocks, blocks_encoded, true},
		{"arrays of as many layers", array, array, true},
		{"another size", image, wider, false},
		{"other layers", image, array, false},
		{"a 3D texture", volume, volume, false},
		{"another format of as many bytes", image, float, false},
		{"blocks into texels", blocks, image, false},
	}
	for c in cases {
		problem := texture_copy_problem(c.src, c.dst)
		testing.expectf(t, (problem == "") == c.copies, "%s: %q", c.name, problem)
	}
	// The mips of a chain from one on into those of the chain of its half size, and none past either.
	Mips :: struct {name: string, src_mip, dst_mip, mips: u32, copies: bool}
	mips := []Mips{
		{"from mip 1 into mip 0 of the half", 1, 0, 6, true},
		{"from mip 2 into mip 1 of the half", 2, 1, 5, true},
		{"mips of other sizes", 0, 0, 1, false},
		{"past the mips of the half", 1, 0, 7, false},
		{"no mip", 1, 0, 0, false},
		{"far past", max(u32), 0, 2, false},
	}
	for c in mips {
		problem := texture_copy_problem(chain, half, c.src_mip, c.dst_mip, c.mips)
		testing.expectf(t, (problem == "") == c.copies, "%s: %q", c.name, problem)
	}
}

// Destroying textures looks at the table entries that name them: one entry for
// a texture in one, the whole table only for one in several, none for one out
// of it. Destroying N textures visits slots in proportion to N, not to N times
// the table, and leaves no entry naming a texture that went.
@(test)
destroying_textures_visits_only_the_table_entries_that_name_them :: proc(t: ^testing.T) {
	TABLE :: 100_000
	TEXTURES :: 10_000
	entries := make([]Texture, TABLE)
	defer delete(entries)
	refs := make([]Table_Refs, TEXTURES + 1) // by the texture, as its handle
	defer delete(refs)
	set :: proc(entries: []Texture, refs: []Table_Refs, index: u32, texture: Texture) {
		before := entries[index]
		table_refs_move(&refs[before] if before != 0 else nil, &refs[texture] if texture != 0 else nil, index)
		entries[index] = texture
	}
	// Texture i takes entry 7 * i; one in ten is out of the table; texture 1 is in two
	// entries; texture 2 was in two and left the last one; texture 3 is set twice into one.
	for i in 1 ..= TEXTURES {
		if i % 10 != 0 {set(entries, refs, u32(7 * i), Texture(i))}
	}
	set(entries, refs, 99_999, 1)
	set(entries, refs, 99_998, 2)
	set(entries, refs, 99_998, 0)
	set(entries, refs, 21, 3)
	visited := 0
	for i in 1 ..= TEXTURES {
		texture := Texture(i)
		from, to := table_refs_range(entries, texture, refs[i])
		visited += to - from
		for index in from ..< to {if entries[index] == texture {set(entries, refs, u32(index), 0)}}
		testing.expectf(t, refs[i].count == 0, "texture %d still counts %d entries", i, refs[i].count)
	}
	for entry, index in entries {
		if !testing.expectf(t, entry == 0, "entry %d still names texture %d", index, entry) {break}
	}
	in_table := TEXTURES - TEXTURES / 10
	// Texture 1 is in two entries and texture 2 is not in its last one: both look at the whole table.
	testing.expectf(t, visited == in_table - 2 + 2 * TABLE, "%d slots visited for %d textures in single entries and two more", visited, in_table - 2)
}

// What a texture holds counts every level, layer and slice of it.
@(test)
the_bytes_of_a_texture_are_those_of_its_levels :: proc(t: ^testing.T) {
	levels := Texture_Desc{width = 8, height = 4, mip_levels = 4, format = .RGBA8_Unorm}
	texels :: (8 * 4 + 4 * 2 + 2 * 1 + 1 * 1) * 4
	testing.expect_value(t, texture_desc_bytes(levels), u64(texels))
	layered := levels
	layered.layers = 6
	testing.expect_value(t, texture_desc_bytes(layered), u64(texels * 6))
	volume := Texture_Desc{width = 8, height = 4, depth = 16, format = .R32_Float}
	testing.expect_value(t, texture_desc_bytes(volume), u64(8 * 4 * 16 * 4))
	testing.expect_value(t, texture_desc_bytes({}), u64(0))
}
