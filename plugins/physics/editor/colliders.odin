package physics_editor

import "mirai:editor"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import sim "plugins:physics/runtime/sim"
import erender "mirai:engine/render"

@(storage)
Collider_Preview :: struct {
    vertices:[editor.LINE_CAPACITY]erender.Debug_Vertex,
    faint:[editor.LINE_CAPACITY]erender.Debug_Vertex, // the same lines at a quarter of their opacity, seen through what hides them
    scratch:[editor.LINE_CAPACITY/2]sim.Debug_Line,
    selection_serial,physics_synced,teleports,authors_layout:u64,
    epoch:u32,
    count,dropped:int,
    ready:bool,
}

// The colliders of what is selected, while editing.
@(step="ui",after="editor_panels")
collider_lines :: proc(s:^editor.Session) {collider_lines_draw(s,editor.shown_world(s))}

@(private)
collider_lines_draw :: proc(s:^editor.Session,w:core.World_Ref) {
    if s.mode!=.Edit || len(s.selection.entities)==0 {return}
    state:=core.world_storage_of(w,phys.Physics_State)
    preview:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Collider_Preview)
    if state==nil || preview==nil {return}
    ids:=core.world_table_of(w,core.Id)
    authors_layout:=ids!=nil?ids.layout:0
    lines:=erender.debug_lines_make(preview.vertices[:])
    if !preview.ready || preview.selection_serial!=s.selection.serial || preview.physics_synced!=state.synced || preview.epoch!=state.epoch || preview.teleports!=state.stats.teleports || preview.authors_layout!=authors_layout {
        out:=sim.Debug_Draw{lines=preview.scratch[:]}
        color:=[4]f32{0.35,1,0.55,0.9}
        colliders:=core.world_table_of(w,phys.Collider)
        candidates:=s.selection.entities[:]
        if colliders!=nil {candidates=colliders.entities[:]}
        for e in candidates {
            if editor.entity_author(w,e)!=e {continue}
            selected:=colliders==nil
            if !selected {for owner in s.selection.entities {if editor.entity_under(w,e,owner) {selected=true;break}}}
            if !selected {continue}
            if lines.count>=len(lines.vertices) {break}
            out.lines=preview.scratch[:(len(lines.vertices)-lines.count)/2]
            if !phys.collider_debug_draw({state},e,&out) {continue}
            if out.lines_dropped>0 {
                lines.dropped+=out.line_count+out.lines_dropped
                if len(lines.vertices)-lines.count<24 {continue}
                if bounds,ok:=phys.collider_bounds({state},e);ok {erender.debug_box(&lines,bounds.min,bounds.max,color)}
                continue
            }
            for line in out.lines[:out.line_count] {erender.debug_line(&lines,line.a,line.b,color)}
        }
        preview.selection_serial,preview.physics_synced,preview.epoch,preview.teleports=s.selection.serial,state.synced,state.epoch,state.stats.teleports
        preview.authors_layout=authors_layout
        preview.count,preview.dropped,preview.ready=lines.count,lines.dropped,true
        for vertex,i in preview.vertices[:lines.count] {
            alpha:=vertex.color>>24
            preview.faint[i]={vertex.position,vertex.color&0x00ffffff|(alpha/4)<<24}
        }
    }
    lines.count,lines.dropped=preview.count,preview.dropped
    if lines.count==0 {return}
    // What is in sight, firm; what is behind something, faint.
    host.extras_debug_lines_add(&s.app.extras,lines)
    faint:=erender.debug_lines_make(preview.faint[:],depth_test=false)
    faint.count=preview.count
    host.extras_debug_lines_add(&s.app.extras,faint)
}

// A Character takes its capsule from a Collider: one that comes without gets
// it. A mesh placed on an entity without a Collider collides when it stores
// colliders of its source, with an Auto one that takes them; one without them
// gives it none.
@(private)
collider_companion :: proc(s:^editor.Session,e:core.Entity,t:^core.Table_Info) {
    collider:phys.Collider
    switch t.type {
    case phys.Character:
        collider=phys.collider_character()
    case erender.Mesh_Renderer:
        meshes:=core.world_table_of(editor.shown_world(s),erender.Mesh_Renderer)
        if meshes==nil {return}
        shown,found:=core.get(meshes,e)
        if !found || !host.assets_mesh_collides(s.app.assets,shown.mesh) {return}
        collider=phys.collider_auto()
    case:
        return
    }
    colliders:=editor.component_table(s,"Collider")
    w:=editor.shown_world(s)
    if colliders==nil || core.raw_find(core.world_table_at(w,colliders),colliders.info,e)!=nil {return}
    editor.component_add(s,e,colliders,&collider)
}

// A Collider given to an entity that shows a mesh starts Auto: what the mesh
// is made to collide as.
@(private)
collider_start :: proc(s:^editor.Session,e:core.Entity,t:^core.Table_Info,value:rawptr) {
    if t.type!=phys.Collider || !editor.entity_has(editor.shown_world(s),e,erender.Mesh_Renderer) {return}
    (^phys.Collider)(value).kind=.Auto
}
