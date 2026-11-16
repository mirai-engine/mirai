package mirai_render

import "core:mem"
import "core:testing"
import "mirai:asset"
import mm "mirai:std/math"

// A rolling grid of side × side vertices with colors and a uv1 of its own:
// a DAG of clusters, or with surfaces one level of a far mesh.
@(private = "file")
pages_grid :: proc(side: int, surfaces: bool, height: f32 = 0) -> (g: asset.Mesh_Geometry, ok: bool) {
	vertices := make([]asset.Vertex, side * side, context.temp_allocator)
	values := make([]asset.Surface_Vertex, side * side if surfaces else 0, context.temp_allocator)
	for &v, i in vertices {
		x, z := f32(i % side), f32(i / side)
		v = {
			position = {x * 0.1, 0.05 * f32((i * 7) % 5) + height, z * 0.1}, normal = mm.normal_pack({0, 1, 0}), tangent = mm.tangent_pack({1, 0, 0}, 1),
			uv = {x, z} / f32(side), uv1 = {z, x} / f32(side), color = mm.rgba8_pack({x / f32(side), 0.5, z / f32(side), 1}),
		}
	}
	for &value, i in values {value = {material = u32(i) & 0xffff, emission = u32(i) * 3}}
	indices := make([dynamic]u32, 0, (side - 1) * (side - 1) * 6, context.temp_allocator)
	for z in 0 ..< side - 1 {
		for x in 0 ..< side - 1 {
			a := u32(z * side + x)
			append(&indices, a, a + u32(side), a + 1, a + 1, a + u32(side), a + u32(side) + 1)
		}
	}
	source := asset.Mesh_Source{vertices = vertices, surfaces = values, flags = {.Has_Colors, .Has_Uv1}}
	if surfaces {
		source.flags += {.Has_Surface}
		ok = asset.mesh_build(source, indices[:], nil, &g, context.temp_allocator)
	} else {
		ok = asset.mesh_build_dag(source, indices[:], &g, context.temp_allocator)
	}
	return
}

// Whether a mesh of the scene reads back through its page table, cluster
// by cluster and decoded whole, exactly the geometry it was given.
@(private = "file")
pages_read_back :: proc(t: ^testing.T, r: ^Renderer, handle: Mesh_Handle, g: asset.Mesh_Geometry) -> bool {
	s := &r.scene
	m := s.meshes[handle]
	if !testing.expect_value(t, m.page_count, u32(len(g.pages))) {return false}
	p := record_pooled(s, m)
	for whole, ordinal in g.clusters {
		page, c, resident := pooled_cluster(p, u32(ordinal))
		if !testing.expectf(t, resident, "the page of cluster %d is in the pools", ordinal) {return false}
		for local in 0 ..< asset.cluster_vertex_count(c) {
			if asset.cluster_vertex(page, c, local) != asset.cluster_vertex(g, whole, local) {
				return testing.expectf(t, false, "vertex %d of cluster %d reads back as it was given", local, ordinal)
			}
			if len(g.surfaces) > 0 && page.surfaces[c.vertex_first + local] != g.surfaces[whole.vertex_first + local] {
				return testing.expectf(t, false, "the surface of vertex %d of cluster %d reads back", local, ordinal)
			}
		}
		for triangle in 0 ..< asset.cluster_triangle_count(c) {
			if asset.cluster_triangle(page.triangles, c, triangle) != asset.cluster_triangle(g.triangles, whole, triangle) {
				return testing.expectf(t, false, "triangle %d of cluster %d reads back", triangle, ordinal)
			}
		}
	}
	decoded, ok := record_decode(s, m, context.temp_allocator)
	if !testing.expect(t, ok, "the mesh decodes whole") {return false}
	same :: proc(a, b: []$T) -> bool {return len(a) == len(b) && mem.compare(mem.slice_to_bytes(a), mem.slice_to_bytes(b)) == 0}
	return testing.expect(t, same(decoded.clusters, g.clusters) && same(decoded.levels, g.levels) && same(decoded.vertices, g.vertices) &&
		same(decoded.uv1s, g.uv1s) && same(decoded.colors, g.colors) && same(decoded.surfaces, g.surfaces) && same(decoded.triangles, g.triangles),
		"decoded whole, the mesh has the arrays it was given")
}

// Every cluster of a mesh of several pages is read through the entry of its
// page: its vertices, uv, uv1, colors, surfaces and triangles are those the
// mesh was given, and the blocks of its pages follow one another in the
// vertex pool in the order of the pages.
@(test)
a_mesh_of_several_pages_reads_back_through_its_page_table_the_geometry_it_was_given :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	for surfaces in ([]bool{false, true}) {
		g, built := pages_grid(140, surfaces)
		if !testing.expect(t, built) {return}
		if !testing.expectf(t, len(g.pages) > 2, "the grid takes several pages (%d)", len(g.pages)) {return}
		handle, added := mesh_add_geometry(r, g, {0})
		if !testing.expect(t, added) {return}
		m := r.scene.meshes[handle]
		base := m.vertex_word
		for page, k in record_pooled(&r.scene, m).pages {
			testing.expectf(t, page.base == base, "page %d starts where the one before ends", k)
			base += g.pages[k].words
		}
		testing.expect_value(t, base, m.vertex_word + m.vertex_span)
		pages_read_back(t, r, handle, g)
	}
}

// Removing a mesh and adding another into the room it left keeps every
// other mesh reading its own pages; a pose of a mesh reads the copy of its
// pages, which stays when the source goes.
@(test)
meshes_removed_added_and_posed_keep_reading_their_own_pages :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	sides := [3]int{40, 120, 60}
	grids: [3]asset.Mesh_Geometry
	handles: [3]Mesh_Handle
	for side, i in sides {
		built: bool
		grids[i], built = pages_grid(side, false, f32(i))
		if !testing.expect(t, built) {return}
		added: bool
		handles[i], added = mesh_add_geometry(r, grids[i], {0})
		if !testing.expect(t, added) {return}
	}
	s := &r.scene
	middle := s.meshes[handles[1]]
	testing.expect(t, mesh_remove(r, handles[1]))
	small, built := pages_grid(30, false, 5)
	if !testing.expect(t, built) {return}
	reused, added := mesh_add_geometry(r, small, {0})
	if !testing.expect(t, added) {return}
	testing.expect(t, s.meshes[reused].vertex_word == middle.vertex_word && s.meshes[reused].index_word == middle.index_word, "the new mesh takes the room the removed one left")
	pages_read_back(t, r, handles[0], grids[0])
	pages_read_back(t, r, handles[2], grids[2])
	pages_read_back(t, r, reused, small)
	pose, made := deformable_create(r, handles[2], true)
	if !testing.expect(t, made) {return}
	posed := s.meshes[pose]
	for page in record_pooled(s, posed).pages {
		testing.expect(t, page.base >= posed.vertex_word && page.base < posed.vertex_word + posed.vertex_span, "the pages of a pose are in its own block")
	}
	pages_read_back(t, r, pose, grids[2])
	testing.expect(t, mesh_remove(r, handles[2]))
	pages_read_back(t, r, pose, grids[2])
	pages_read_back(t, r, handles[0], grids[0])
}
