package mirai_render

import "mirai:rhi"

// The meshes a frame draws whole, out of the raster of a view: those of the
// instances drawn by themselves (glass and its filter, translucents,
// overlays, the highlight) and those extensions ask for (frame_mesh_whole:
// the meshes of particles). Each takes CLUSTER_DRAW_VERTICES indices a
// cluster in Scene_State.mesh_draws, the three vertices of each triangle of
// the cluster as its cluster << DRAW_VERTEX_BITS | the vertex in it, and the
// first vertex three times past its triangles (mesh_draws.comp); gbuffer.vert
// and the vertex stages of extensions draw them indexed. The list holds a
// frame: what does not fit is not drawn, and the list grows to what the
// frame asked for, for the frames after.

// Groups of mesh_draws.comp in a row: a dispatch takes its clusters in rows.
MESH_DRAWS_ROW :: 32768

// Where the meshes drawn whole this frame go in the list, by the order of
// their handles, so that a frame that draws the same meshes keeps them where
// they were: what moved goes to its row of the mesh table (Gpu_Mesh.draw_first)
// and is written again.
@(private)
mesh_draws_plan :: proc(r: ^Renderer) {
	s := &r.scene
	asked := r.frame + 1
	ask :: proc(s: ^Scene_State, instance: int, asked: u64) {
		mesh := s.instances[instance].meta.x & INSTANCE_MESH_MASK
		if int(mesh) < len(s.meshes) {s.meshes[mesh].draw_asked = asked}
	}
	for entry in s.translucent {if int(entry.instance) < len(s.instances) {ask(s, int(entry.instance), asked)}}
	for inst, index in s.instances {
		if highlight_drawn(inst.meta.w) || index < len(s.overlays) && s.overlays[index].count > 0 {ask(s, index, asked)}
	}
	at, needed := u32(0), u32(0)
	for &m, index in s.meshes {
		// An extension asks in the frame it draws, before or after the frame records.
		whole := m.whole > 0 && asked - m.whole <= 1
		listed, first := false, m.draw_first
		if (m.draw_asked == asked || whole) && m.vertex_count > 0 && !mesh_pending(s, u32(index)) {
			count := m.cluster_count * CLUSTER_DRAW_VERTICES
			needed += count
			if count <= s.mesh_draws_capacity - min(at, s.mesh_draws_capacity) {listed, first, at = true, at, at + count}
		}
		if listed != m.draw_listed || listed && first != m.draw_first {
			m.draw_listed, m.draw_first, m.draw_written = listed, first, false
			m.draw_moved = true
		}
	}
	s.mesh_draws_wanted = max(s.mesh_draws_wanted, min(needed, CULL_MARK_MAX))
}

// Writes the clusters of the meshes whose place in the list is new, or whose
// pages stream (what they hold may have changed), and the rows of the mesh
// table of those that moved. Each dispatch is bounded by the clusters of its
// mesh, which the list holds.
@(private)
mesh_draws_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	s := &r.scene
	mesh_draws_plan(r)
	bound := false
	for &m, index in s.meshes {
		if m.draw_moved {
			row := rhi.frame_alloc(r.device, size_of(Gpu_Mesh), 16)
			if row.ptr == nil {return false}
			(cast(^Gpu_Mesh)row.ptr)^ = gpu_mesh(m)
			rhi.cmd_copy_buffer(cmd, row.buffer, row.offset, s.mesh_buffer, u64(index) * size_of(Gpu_Mesh), size_of(Gpu_Mesh))
			m.draw_moved = false
		}
		if !m.draw_listed || m.draw_written {continue}
		if !bound {
			rhi.cmd_bind_pipeline(cmd, r.pipelines[.Mesh_Draws])
			rhi.cmd_bind_buffer(cmd, SLOT_MESHES, s.mesh_buffer)
			rhi.cmd_bind_buffer(cmd, SLOT_VERTICES, s.vertex_buffer)
			rhi.cmd_bind_buffer(cmd, SLOT_INDICES, s.index_buffer)
			rhi.cmd_bind_buffer(cmd, SLOT_PASS0, s.mesh_draws)
			bound = true
		}
		Params :: struct {mesh, first, row, pad: u32}
		params := Params{mesh = u32(index), first = m.draw_first, row = MESH_DRAWS_ROW}
		set_params(cmd, &params)
		rhi.cmd_dispatch(cmd, min(m.cluster_count, MESH_DRAWS_ROW), groups(m.cluster_count, MESH_DRAWS_ROW))
		m.draw_written = m.stream == nil
	}
	return true
}

// Where the clusters of a mesh drawn whole this frame are in the list, of
// all its levels or of level 0, and how many indices they take: false when
// the list does not hold it this frame.
@(private)
mesh_draws_range :: proc(s: ^Scene_State, mesh: u32, level0: bool) -> (first, count: u32, ok: bool) {
	if int(mesh) >= len(s.meshes) || !s.meshes[mesh].draw_listed {return}
	m := &s.meshes[mesh]
	if !level0 {return m.draw_first, m.cluster_count * CLUSTER_DRAW_VERTICES, true}
	level_first, level_count := record_level(s, m^, 0)
	return m.draw_first + level_first * CLUSTER_DRAW_VERTICES, level_count * CLUSTER_DRAW_VERTICES, level_count > 0
}
