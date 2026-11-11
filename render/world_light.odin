package mirai_render

import "mirai:rhi"

// The light of each world the renderer shows: its probe volume, in the light scale they were gathered in. Renderer_Desc.worlds of
// them, the one shown included, so that showing a world again (another tab,
// the end of Play) finds its light settled. A world shown anew, or past the
// capacity the least recently shown, starts without light, which the frame
// that shows it gathers at once (gi_warm).

// Renderer_Desc.worlds when unset: editing and playing.
WORLDS_DEFAULT :: 2
WORLDS_MAX :: 4

// What the renderer keeps of a world it does not show.
World_Light :: struct {
	used:         bool,
	world:        u64, // as scene_world named it
	shown:        u64, // Renderer.frame when it was last shown
	light_scale:  f32, // of its scene: what its light is in
	ddgi:         Ddgi_State,
}

// The scene that follows (scene_set) is that of the world `world`, a key its
// caller keeps for it, after a discontinuity of what is shown: another world,
// or `world` replaced by a new one (`fresh`: a scene opened in its place). The
// light the world shown so far gathered stays with it; a world shown again
// takes back its own, and the scene_set that follows changes none of it.
// Every view starts a new history and takes its exposure at once.
scene_world :: proc(r: ^Renderer, world: u64, fresh := false) {
	defer {
		r.light_rescale = 0
		renderer_camera_cut(r)
		for view in views_all(r) {view.ev100_known = false}
		r.world_switched = true
		r.scene.changes = {}
	}
	r.world_kept = false
	if !r.world_known || world == r.world_key {
		if !r.world_known || fresh {world_light_restart(r)} else {r.world_kept = true}
		r.world_key, r.world_known = world, true
		return
	}
	// The light of the world shown so far goes to a slot: a free one, or the
	// least recently shown, whose light is lost. The one of `world` comes back.
	slot := -1
	for &w, i in r.kept[:r.kept_count] {
		if !w.used || w.world != world {continue}
		if fresh {w.used = false} else {slot = i}
	}
	back := slot >= 0
	if !back {
		oldest := max(u64)
		for w, i in r.kept[:r.kept_count] {
			if !w.used {slot = i; break}
			if w.shown < oldest {slot, oldest = i, w.shown}
		}
	}
	if slot >= 0 {
		w := &r.kept[slot]
		w.ddgi, r.ddgi = r.ddgi, w.ddgi
		// Its probes are in the scale before one the next frame was to bring them to.
		w.light_scale, r.scene.light_scale = r.scene.light_scale / (r.light_rescale if r.light_rescale > 0 else 1), w.light_scale
		w.used, w.world, w.shown = true, r.world_key, r.frame
	}
	if back {r.world_kept = true} else {world_light_restart(r)}
	r.world_key = world
}

// The world `world` took another scene while it was not shown: what was kept
// of its light is of the scene before, and it starts without light when it
// is shown again.
world_light_forget :: proc(r: ^Renderer, world: u64) {
	for &w in r.kept[:r.kept_count] {
		if w.used && w.world == world {w.used = false}
	}
}

// The world shown starts without light: an empty volume, a light scale of its
// own, gathered at once in the next frame.
@(private)
world_light_restart :: proc(r: ^Renderer) {
	ddgi_release(r)
	r.scene.light_scale = 0
	r.gi_warm = true
}

// The light every world gathered was traced with shaders that changed: the
// volume of the world shown is gathered again in the next frame, and the
// worlds not shown start without light when they are shown again.
@(private)
world_light_stale :: proc(r: ^Renderer) {
	ddgi_release(r)
	r.gi_warm = true
	for &w in r.kept[:r.kept_count] {w.used = false}
}

@(private)
world_light_destroy :: proc(r: ^Renderer) {
	for &w in r.kept[:r.kept_count] {
		shown := r.ddgi
		r.ddgi = w.ddgi
		ddgi_release(r)
		r.ddgi = shown
		w = {}
	}
}

// Every view the renderer keeps state for.
@(private)
views_all :: proc(r: ^Renderer) -> [1 + VIEW_CAPACITY + TEXTURE_VIEW_CAPACITY]^View_State {
	all: [1 + VIEW_CAPACITY + TEXTURE_VIEW_CAPACITY]^View_State
	all[0] = &r.main
	for &view, i in r.views {all[1 + i] = &view}
	for &view, i in r.texture_views {all[1 + VIEW_CAPACITY + i] = &view}
	return all
}
