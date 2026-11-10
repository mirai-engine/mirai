package physics_editor

import "mirai:core"
import "mirai:editor"
import "mirai:host"
import erender "mirai:engine/render"
import phys "plugins:physics/runtime"
import sim "plugins:physics/runtime/sim"

FLUID_LINES :: 4096 // the most lines of the fluids drawn; the rest are counted

// The fluids of the world shown, editing and playing: the edges of their
// boxes and a grid on the surface of a sea. Nothing else shows a fluid that
// no plugin draws.
@(storage)
Fluid_Lines :: struct {
    vertices:[2*FLUID_LINES]erender.Debug_Vertex,
    scratch:[FLUID_LINES]sim.Debug_Line,
}

@(step="render",after="render_sync")
fluid_lines :: proc(s:^editor.Session,view:^Fluid_Lines,extras:^host.Frame_Extras) {
    if editor.document_is_prefab(s) {return}
    state:=core.world_storage_of(editor.shown_world(s),phys.Physics_State)
    if state==nil || !state.ready || state.world.fluid_count==0 {return}
    out:=sim.Debug_Draw{lines=view.scratch[:]}
    sim.world_debug_draw(&state.world,&out,{.Fluids})
    lines:=erender.debug_lines_make(view.vertices[:])
    for line in out.lines[:out.line_count] {erender.debug_line(&lines,line.a,line.b,COLLISION_COLORS[line.kind])}
    lines.dropped+=out.lines_dropped
    if lines.count>0 {host.extras_debug_lines_add(extras,lines)}
}
