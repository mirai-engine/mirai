package editor

import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:editor/kit"
import "mirai:ui"

// The modes of inspection of the viewport: what it shows instead of its lit
// image. VIEW_MODES are those of the core; a plugin declares its own in each
// frame from a step of its editor part that runs before the ui phase
// (view_mode_declare), with the pass that draws it in the Inspect stage of the
// renderer. The menu of the toolbar and the agent API list both. The viewport
// keeps the mode it shows by name and goes back to Lit when nothing declares
// it any longer. A Play shows the lit image of its game.

VIEW_MODE_NAME_BYTES :: 48
VIEW_MODE_LABEL_BYTES :: 32
VIEW_MODE_REASON_BYTES :: 128
VIEW_MODE_PLUGIN_CAPACITY :: 48
// What a mode shows: an image of the shaders of the engine, or the pass of a plugin.
View_Mode_Kind :: enum u8 {Render, Plugin}

@(private)
Core_View_Mode :: struct {
	name, label, group, submenu: string,
	icon:   ui.Icon,
	kind:   View_Mode_Kind,
	render: gpu.Debug_View,
}

// The modes of the core in the order of the menu: by group and, within one,
// the family of a submenu together. A submenu takes the icon of its first
// mode.
@(private)
VIEW_MODES :: [?]Core_View_Mode{
	{"lit", "Lit", "Shading", "", .Sun, .Render, .None},
	{"unlit", "Unlit", "Shading", "", .Sphere, .Render, .Unlit},
	{"lighting", "Lighting only", "Shading", "", .Light, .Render, .Lighting},
	{"base_color", "Base color", "Shading", "Material", .Palette, .Render, .Albedo},
	{"normal", "World normal", "Shading", "Material", .Axis, .Render, .Normal},
	{"roughness", "Roughness", "Shading", "Material", .Gauge, .Render, .Roughness},
	{"metallic", "Metallic", "Shading", "Material", .Material, .Render, .Metallic},
	{"emission", "Emission", "Shading", "Material", .Lightning, .Render, .Emission},
	{"direct", "Direct light", "Lighting", "Direct", .Spot, .Render, .Direct},
	{"shadows", "Shadows", "Lighting", "", .Eye_Off, .Render, .Shadows},
	{"lights", "Lights per pixel", "Lighting", "", .Target, .Render, .Lights},
	{"reflections", "Traced, filtered", "Lighting", "Reflections", .Sparkle, .Render, .Reflections},
	{"reflections_raw", "Traced, unfiltered", "Lighting", "Reflections", .Dot, .Render, .Reflections_Raw},
	{"indirect", "Indirect light", "Lighting", "Indirect", .Refresh, .Render, .Indirect},
	{"probes", "Probe volume", "Lighting", "Indirect", .Grid, .Render, .Probes},
	{"depth", "Depth", "Advanced", "", .Focus, .Render, .Depth},
	{"motion", "Motion", "Advanced", "", .Move, .Render, .Motion},
}

// A mode of inspection a plugin adds to the viewport for one frame. name is
// what editor.view_mode.set takes; group and submenu place it in the menu, under
// the header of a group of the core when it names one. record draws it over
// the lit image of the view that shows it, in its Inspect stage
// (engine/render); one that draws lines over the image draws them itself while
// it is the mode shown, with a record that does nothing. title is what the
// toolbar shows while it is shown; empty: label.
View_Mode_Desc :: struct {
	name, label, group, submenu, title: string,
	icon:   ui.Icon,
	reason: string, // why the viewport cannot show it now; empty while it can
	record: gpu.Stage_Proc,
	user:   rawptr,
}

@(private)
View_Mode_Declared :: struct {
	name:            [VIEW_MODE_NAME_BYTES]u8,
	label, group, submenu, title: [VIEW_MODE_LABEL_BYTES]u8,
	reason:          [VIEW_MODE_REASON_BYTES]u8,
	icon:            ui.Icon,
	record:          gpu.Stage_Proc,
	user:            rawptr,
}

// The modes the plugins declared in this frame.
@(storage,free="view_modes_free")
View_Modes :: struct {
	declared:  [VIEW_MODE_PLUGIN_CAPACITY]View_Mode_Declared,
	count:     int,
	dropped:   u64, // declarations without room
}

view_modes_free :: proc(modes: ^View_Modes) {
	core.value_free(modes, type_info_of(View_Modes))
	modes^ = {}
}

// Declares a mode of a plugin for this frame. False without room, without a
// record, or with a name of the core, one declared already or one longer than
// VIEW_MODE_NAME_BYTES.
view_mode_declare :: proc(s: ^Session, desc: View_Mode_Desc) -> bool {
	modes := s.view_modes
	if modes == nil || desc.record == nil || desc.name == "" || len(desc.name) >= VIEW_MODE_NAME_BYTES {return false}
	if view_mode_reserved(desc.name) || view_mode_declared(modes, desc.name) >= 0 {return false}
	if modes.count >= len(modes.declared) {modes.dropped += 1; return false}
	d := &modes.declared[modes.count]
	d^ = {icon = desc.icon, record = desc.record, user = desc.user}
	base.text_set(d.name[:], desc.name)
	base.text_set(d.label[:], desc.label if desc.label != "" else desc.name)
	base.text_set(d.group[:], desc.group if desc.group != "" else "Plugins")
	base.text_set(d.submenu[:], desc.submenu)
	base.text_set(d.title[:], desc.title)
	base.text_set(d.reason[:], desc.reason)
	modes.count += 1
	return true
}

// The name of the mode the viewport shows.
view_mode_current :: proc(v: ^Viewport) -> string {
	name := base.text_get(v.view_mode[:])
	return name if name != "" else "lit"
}

// The declarations of a frame begin empty.
@(step="input",stage="begin")
view_modes_begin :: proc(modes: ^View_Modes) {modes.count = 0}

// What the viewport shows in this frame: the mode of the renderer (black
// where it cannot show it) or of a plugin that can show it, which the frame
// names. Nothing in a Play; a mode no longer
// declared goes back to Lit.
@(step="render",after="render_sync")
view_mode_render :: proc(s: ^Session, v: ^Viewport, modes: ^View_Modes, app: ^host.App) {
	if s.mode == .Play {return}
	w := shown_world(s)
	entry, found := view_mode_resolve(app.renderer, modes, w, view_mode_current(v))
	if !found {
		base.text_clear(v.view_mode[:])
		return
	}
	switch entry.kind {
	case .Render:    app.inspection = {mode = entry.render}
	case .Plugin:    if entry.available {app.inspection = {record = modes.declared[entry.plugin].record, user = modes.declared[entry.plugin].user}}
	}
}

// A mode as the menu and the API show it.
@(private)
View_Mode_Entry :: struct {
	name, label, group, submenu, title: string,
	icon:      ui.Icon,
	kind:      View_Mode_Kind,
	render:    gpu.Debug_View,
	plugin:    int, // Plugin: of View_Modes.declared
	available: bool,
	reason:    string,
}

@(private)
VIEW_MODE_ENTRY_CAPACITY :: len(VIEW_MODES) + VIEW_MODE_PLUGIN_CAPACITY

@(private)
view_mode_reserved :: proc(name: string) -> bool {
	core_modes := VIEW_MODES
	for mode in core_modes {if strings.equal_fold(mode.name, name) {return true}}
	return false
}

@(private)
view_mode_declared :: proc(modes: ^View_Modes, name: string) -> int {
	if modes == nil {return -1}
	for &d, i in modes.declared[:modes.count] {
		if strings.equal_fold(base.text_get(d.name[:]), name) {return i}
	}
	return -1
}

@(private)
view_mode_core_entry :: proc(r: ^gpu.Renderer, mode: Core_View_Mode) -> (entry: View_Mode_Entry) {
	entry = {name = mode.name, label = mode.label, group = mode.group, submenu = mode.submenu, icon = mode.icon, kind = mode.kind, render = mode.render, available = true}
	switch mode.kind {
	case .Render:
		if r == nil {entry.available, entry.reason = false, "The editor has no renderer: it runs without a GPU"} else {entry.available, entry.reason = gpu.renderer_debug_view_status(r, mode.render)}
	case .Plugin:
	}
	return
}

@(private)
view_mode_plugin_entry :: proc(modes: ^View_Modes, index: int) -> View_Mode_Entry {
	d := &modes.declared[index]
	reason := base.text_get(d.reason[:])
	return {
		name = base.text_get(d.name[:]), label = base.text_get(d.label[:]), group = base.text_get(d.group[:]), submenu = base.text_get(d.submenu[:]),
		title = base.text_get(d.title[:]), icon = d.icon, kind = .Plugin, plugin = index, available = reason == "", reason = reason,
	}
}

// Every mode the viewport can be asked for now: those of the core, then those
// the plugins declared.
@(private)
view_mode_entries :: proc(r: ^gpu.Renderer, modes: ^View_Modes, w: core.World_Ref, buffer: []View_Mode_Entry) -> []View_Mode_Entry {
	count := 0
	add :: proc(buffer: []View_Mode_Entry, count: ^int, entry: View_Mode_Entry) {
		if count^ < len(buffer) {buffer[count^] = entry; count^ += 1}
	}
	core_modes := VIEW_MODES
	for mode in core_modes {add(buffer, &count, view_mode_core_entry(r, mode))}
	if modes != nil {
		for i in 0 ..< modes.count {add(buffer, &count, view_mode_plugin_entry(modes, i))}
	}
	return buffer[:count]
}

// The mode of a name, whatever its case: false when nothing declares it.
@(private)
view_mode_resolve :: proc(r: ^gpu.Renderer, modes: ^View_Modes, w: core.World_Ref, name: string) -> (entry: View_Mode_Entry, found: bool) {
	core_modes := VIEW_MODES
	for mode in core_modes {
		if strings.equal_fold(mode.name, name) {return view_mode_core_entry(r, mode), true}
	}
	if index := view_mode_declared(modes, name); index >= 0 {return view_mode_plugin_entry(modes, index), true}
	return
}

// ---------------------------------------------------------------- menu

// The button of the toolbar with the mode shown, and its menu: a header for
// each group and a submenu for each family, an icon for each mode, and what
// cannot be shown now disabled.
@(private)
view_mode_build :: proc(s: ^Session) {
	r := s.app.renderer
	if s.view_modes == nil {return}
	g, ctx := s.gui, s.gui.ctx
	w := shown_world(s)
	current := view_mode_current(s.viewport)
	label := "Lit"
	if entry, found := view_mode_resolve(r, s.view_modes, w, current); found {
		label = entry.title if entry.title != "" else entry.label
	}
	id, popup := shell_id(g, "view_mode"), shell_id(g, "view_mode_popup")
	if ui.button(ctx, id, {label = label, icon = .Chevron_Down, icon_after = true, variant = "ghost", height = 26, size = ui.metric(ctx,"font_small"), active = ui.popup_is_open(ctx, popup)}).clicked {
		anchor, _ := ui.widget_rect(ctx, id)
		ui.popup_open(ctx, popup, {anchor.x, anchor.y + anchor.h, anchor.w, 0})
	}
	if ui.popup(ctx, popup, {min_width = ui.MENU_WIDTH, align_right = true}) {
		ui.id_push(ctx, popup)
		defer ui.id_pop(ctx)
		buffer: [VIEW_MODE_ENTRY_CAPACITY]View_Mode_Entry
		entries := view_mode_entries(r, s.view_modes, w, buffer[:])
		for entry, i in entries {
			if view_mode_seen(entries[:i], entry.group, "") {continue}
			if !view_mode_folded(entry.group) {
				ui.menu_header(ctx, entry.group)
				view_mode_group_build(s, entries, entry.group, current)
				continue
			}
			ui.menu_separator(ctx)
			holds, any_available := false, false
			for other in entries[i:] {
				if other.group != entry.group {continue}
				holds ||= other.name == current
				any_available ||= other.available
			}
			if ui.submenu(ctx, ui.id(ctx, entry.group, 2), entry.group, {icon = entry.icon, checked = holds, disabled = !any_available}) {
				view_mode_group_build(s, entries, entry.group, current)
			}
		}
		ui.menu_header(ctx, "Light")
		if ui.menu_item(ctx, ui.id(ctx, "studio_light"), "Studio light", {icon = .Sun, checked = s.viewport.studio_light}) {s.viewport.studio_light = !s.viewport.studio_light}
		viewport_exposure_build(s)
	}
}

// How the view exposes: the Sky that is on, the camera it looks through, or a fixed EV.
@(private)
viewport_exposure_build :: proc(s: ^Session) {
	ctx := s.gui.ctx
	v := s.viewport
	ui.menu_header(ctx, "Exposure")
	if ui.menu_item(ctx, ui.id(ctx, "exposure_scene"), "Scene", {checked = v.exposure_source == .Scene}) {v.exposure_source = .Scene}
	if ui.menu_item(ctx, ui.id(ctx, "exposure_camera"), "Camera", {checked = v.exposure_source == .Camera, disabled = !v.exposure.own}) {v.exposure_source = .Camera}
	if ui.menu_item(ctx, ui.id(ctx, "exposure_manual"), "Manual", {checked = v.exposure_source == .Manual}) {v.exposure_source = .Manual}
	if ui.box(ctx, {width = ui.GROW, height = ui.fixed(ui.metric(ctx,"control")), padding = {6, 0, 6, 0}, gap = 7, align_y = .Center}) {
		ui.label(ctx, "EV100", ui.metric(ctx,"font_small"), ui.tone(ctx,"text"), 40)
		ev100 := f64(v.ev100)
		if kit.slider_field(ctx, ui.id(ctx, "exposure_ev100"), &ev100, {min = -10, max = 24, has_min = true, has_max = true, decimals = 1, speed = 0.05, height = 22}).changed {
			v.ev100 = f32(ev100)
			v.exposure_source = .Manual
		}
	}
}

// The groups the menu folds into a submenu of their own, after a rule, to keep it short.
@(private)
view_mode_folded :: proc(group: string) -> bool {return group == "Advanced"}

// Whether a mode before is of the group and, given one, of the submenu.
@(private)
view_mode_seen :: proc(before: []View_Mode_Entry, group, submenu: string) -> bool {
	for entry in before {
		if entry.group == group && (submenu == "" || entry.submenu == submenu) {return true}
	}
	return false
}

@(private)
view_mode_group_build :: proc(s: ^Session, entries: []View_Mode_Entry, group, current: string) {
	ctx := s.gui.ctx
	for entry, i in entries {
		if entry.group != group {continue}
		if entry.submenu == "" {
			view_mode_item(s, entry, current)
			continue
		}
		if view_mode_seen(entries[:i], group, entry.submenu) {continue}
		holds, any_available := false, false
		for other in entries[i:] {
			if other.group != group || other.submenu != entry.submenu {continue}
			holds ||= other.name == current
			any_available ||= other.available
		}
		// The family is also its first mode: a click on it shows that one.
		chosen := false
		if ui.submenu(ctx, ui.id(ctx, entry.submenu, 1), entry.submenu, {icon = entry.icon, checked = holds, disabled = !any_available, chosen = &chosen if entry.available else nil}) {
			for other in entries[i:] {
				if other.group == group && other.submenu == entry.submenu {view_mode_item(s, other, current)}
			}
		}
		if chosen {base.text_set(s.viewport.view_mode[:], entry.name)}
	}
}

@(private)
view_mode_item :: proc(s: ^Session, entry: View_Mode_Entry, current: string) {
	ctx := s.gui.ctx
	if ui.menu_item(ctx, ui.id(ctx, entry.name), entry.label, {icon = entry.icon, checked = entry.name == current, disabled = !entry.available}) {
		base.text_set(s.viewport.view_mode[:], entry.name)
	}
}

// ---------------------------------------------------------------- API

Api_View_Mode_Params :: struct {
	mode: [VIEW_MODE_NAME_BYTES]u8 `mirai:"text,label=A mode that editor.view_mode.list lists: lit or base_color or direct or shadows... or one of a plugin such as collision or collision.<layer>"`,
}

@(private)
API_VIEW_MODE_SCHEMA :: `{"type":"object","properties":{"mode":{"type":"string"},"label":{"type":"string"},"group":{"type":"string"},"submenu":{"type":"string"},"available":{"type":"boolean"},"reason":{"type":"string"}},"required":["mode","label","group","submenu","available","reason"],"additionalProperties":false}`
@(private)
API_VIEW_MODES_SCHEMA :: `{"type":"object","properties":{"current":{"type":"string"},"modes":{"type":"array","items":` + API_VIEW_MODE_SCHEMA + `}},"required":["current","modes"],"additionalProperties":false}`

// A mode as the API gives it: its name, its label, its group and submenu in
// the menu, and why it cannot be shown now when it cannot.
@(private)
api_view_mode_write :: proc(call: ^api.Call, entry: View_Mode_Entry) {
	out := call.out
	serial.write_u8(out, '{')
	api.write_text(out, "mode", entry.name, true)
	api.write_text(out, "label", entry.label)
	api.write_text(out, "group", entry.group)
	api.write_text(out, "submenu", entry.submenu)
	api.write_bool(out, "available", entry.available)
	api.write_text(out, "reason", entry.reason)
	serial.write_u8(out, '}')
}

@(private)
api_view_modes :: proc(s: ^Session, call: ^api.Call) {
	r := s.app.renderer
	if r == nil {api.call_fail(call, api.SERVER_ERROR, "The editor has no renderer: it runs without a GPU"); return}
	buffer: [VIEW_MODE_ENTRY_CAPACITY]View_Mode_Entry
	entries := view_mode_entries(r, s.view_modes, shown_world(s), buffer[:])
	out := call.out
	serial.write_u8(out, '{')
	api.write_text(out, "current", view_mode_current(s.viewport), true)
	api.write_key(out, "modes")
	serial.write_u8(out, '[')
	for entry, i in entries {
		if i > 0 {serial.write_u8(out, ',')}
		api_view_mode_write(call, entry)
	}
	serial.text_write_raw(out, "]}")
}

@(private)
api_view_mode :: proc(s: ^Session, call: ^api.Call) {
	r := s.app.renderer
	if r == nil {api.call_fail(call, api.SERVER_ERROR, "The editor has no renderer: it runs without a GPU"); return}
	name := base.text_get(api.call_params(call, Api_View_Mode_Params).mode[:])
	entry, found := view_mode_resolve(r, s.view_modes, shown_world(s), name)
	if !found {api.call_failf(call, api.INVALID_PARAMS, "%q is not a view mode; editor.view_mode.list lists them", name); return}
	if !entry.available {api.call_failf(call, api.INVALID_PARAMS, "%s cannot be shown now: %s", entry.name, entry.reason); return}
	base.text_set(s.viewport.view_mode[:], entry.name)
	api_view_mode_write(call, entry)
}

@(private)
view_modes_api_register :: proc(s: ^Session, st: ^Api_State) {
	api_register(s, st, {name = "editor.view_mode.list", summary = "The modes of inspection of the viewport, of the core and of the plugins: where the menu shows each, the one shown and why one cannot be shown now.", result_schema = API_VIEW_MODES_SCHEMA, flags = {.Read_Only}, run = api_view_modes})
	api_register(s, st, {name = "editor.view_mode.set", summary = "Shows a mode of inspection in the viewport instead of the lit image. A Play shows the lit image of its game.", params = Api_View_Mode_Params, result_schema = API_VIEW_MODE_SCHEMA, flags = {.Idempotent}, run = api_view_mode})
}
