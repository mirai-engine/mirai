package paint_editor

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:platform"
import paint "plugins:paint/runtime"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:editor/kit"
import "mirai:ui"

// The paint tool of the paint plugin: a brush that paints the colors of the
// vertices of the entity under the pointer over the mesh it shows, which
// stays as it is for every other entity. A stroke writes the colors of the
// entity as a .paint of its own and names it in its Painted, so undoing the
// stroke puts back the colors it showed and takes the file away. The file is
// of the step of the stroke (editor.file_write). While the stroke lasts it is
// written again as the brush moves, and reaches the disk when it ends.

PANEL_SCOPE :: ui.Id(0x7061696e)
FOLDER :: "painted" // of the asset root: where the colors of strokes go
REFRESH_SECONDS :: f32(0.08) // between two writes of the colors while a stroke lasts
RADIUS_MIN :: f32(0.01)
RADIUS_MAX :: f32(100)
RING_SEGMENTS :: 48
LINE_CAPACITY :: 512
RADIUS_DEFAULT :: f32(0.5)
STRENGTH_DEFAULT :: f32(1)
COLOR_DEFAULT :: [3]f32{0.9,0.15,0.1}

@(storage,free="paint_tool_free")
Paint_Tool :: struct {
    active:bool,
    radius:f32,   // m
    strength:f32, // 0 to 1: how far a stroke takes a color toward the one of the brush
    color:[3]f32,
    begin:bool,   // a press on the scene this frame belongs to the tool
    over:bool,    // the pointer is on the scene
    ready:bool,
    stroke:Stroke,
    lines_storage:[dynamic]erender.Debug_Vertex,
    lines:erender.Debug_Lines,
}

Stroke :: struct {
    active:bool,
    allocator:runtime.Allocator,
    entity:core.Entity,
    canvas:Canvas,      // its positions in the world
    before:[]u32,       // the colors when the stroke began
    weights:[]f32,
    id:base.Asset_Id,   // of the colors of the stroke
    path:string,
    written:bool,       // the colors are in the assets and the entity shows them
    dirty:bool,         // weights changed since the colors were written
    wait:f32,           // s until the colors may be written again
    last,normal:[3]f32,
}

paint_tool_free :: proc(t:^Paint_Tool) {
    stroke_free(t)
    delete(t.lines_storage)
    t^={}
}

@(private)
tool_ready :: proc(t:^Paint_Tool) {
    if t.ready {return}
    t.ready=true
    t.radius,t.strength,t.color=RADIUS_DEFAULT,STRENGTH_DEFAULT,COLOR_DEFAULT
    resize(&t.lines_storage,LINE_CAPACITY)
    t.lines=erender.debug_lines_make(t.lines_storage[:],true)
}

@(private)
stroke_free :: proc(t:^Paint_Tool) {
    stroke:=&t.stroke
    a:=stroke.allocator
    canvas_destroy(&stroke.canvas)
    delete(stroke.before,a);delete(stroke.weights,a);delete(stroke.path,a)
    stroke^={}
}

// The scene is the pointer's while the tool is on: a press on it starts a
// stroke instead of selecting, and the camera keeps the other buttons.
@(step="input",after="editor_begin")
paint_pointer :: proc(s:^editor.Session,tool:^Paint_Tool,input:core.Input) {
    tool_ready(tool)
    tool.active,tool.over,tool.begin=editor.tool_pointer(s,"paint",input)
}

@(step="frame")
paint_brush :: proc(
    s:^editor.Session,tool:^Paint_Tool,world:core.World_Ref,meshes:^core.Table(erender.Mesh_Renderer,.Read),painted:^core.Table(paint.Painted,.Read),worlds:^core.Table(core.World_Transform,.Read),
    assets:^host.Assets,extras:^host.Frame_Extras,allocator:runtime.Allocator,input:core.Input,frame:core.Frame_Time,
) {
    erender.debug_lines_clear(&tool.lines)
    defer if tool.lines.count>0 {host.extras_debug_lines_add(extras,tool.lines)}
    if !s.gui.begun {return}
    stroke:=&tool.stroke
    if !tool.active || editor.playing(s) {
        if stroke.active {stroke_cancel(s,tool,world)}
        return
    }
    if stroke.active {
        if ui.escape(s.gui.ctx) || !core.alive(core.world_entities(world),stroke.entity) || !core.has(meshes,stroke.entity) {
            stroke_cancel(s,tool,world)
            return
        }
        if !core.mouse_down(input,.Left) {
            stroke_end(s,tool,world,assets,allocator)
            return
        }
        stroke_move(s,tool,world,assets,allocator,input,frame)
        if stroke.active {ring(tool,stroke.last,stroke.normal)}
        return
    }
    if !tool.over {return}
    hit:=editor.pick_point(s,world,input.mouse_position)
    if hit.entity==core.NONE || hit.indicator {return}
    ring(tool,hit.position,hit.normal)
    if tool.begin {stroke_begin(s,tool,world,assets,allocator,meshes,painted,worlds,hit)}
}

// The ring of the brush on the surface, in the color it paints.
@(private)
ring :: proc(tool:^Paint_Tool,position,normal:[3]f32) {
    normal:=linalg.normalize0(normal)
    if normal=={} {normal={0,1,0}}
    side:=linalg.normalize(linalg.cross(normal,abs(normal.y)<0.95?[3]f32{0,1,0}:[3]f32{1,0,0}))
    up:=linalg.cross(normal,side)
    center:=position+normal*0.01
    color:=[4]f32{tool.color.r,tool.color.g,tool.color.b,1}
    previous:=center+side*tool.radius
    for segment in 1..=RING_SEGMENTS {
        angle:=f32(segment)/RING_SEGMENTS*math.TAU
        point:=center+(side*math.cos(angle)+up*math.sin(angle))*tool.radius
        erender.debug_line(&tool.lines,previous,point,color)
        previous=point
    }
    erender.debug_line(&tool.lines,center,center+normal*tool.radius*0.25,color)
}

// Takes the mesh of the entity under the pointer into memory and paints the
// first stamp. Nothing is held when the entity has no mesh that can be painted.
@(private)
stroke_begin :: proc(
    s:^editor.Session,tool:^Paint_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,meshes:^core.Table(erender.Mesh_Renderer,$A),
    painted:^core.Table(paint.Painted,$B),worlds:^core.Table(core.World_Transform,$C),hit:editor.Pick,
) {
    a:=assets
    shown,has_mesh:=core.get(meshes,hit.entity)
    placed,has_placed:=core.get(worlds,hit.entity)
    if a==nil || !has_mesh || !has_placed {return}
    colors,_:=core.get(painted,hit.entity)
    stroke:=&tool.stroke
    stroke_free(tool)
    if !stroke_load(stroke,a,hit.entity,shown,colors.colors,placed.transform,allocator) {
        editor.notify(s,"This mesh cannot be painted")
        stroke_free(tool)
        return
    }
    stroke.active=true
    stroke.last,stroke.normal=hit.position,hit.normal
    stroke.dirty=stamp(stroke.canvas.positions,stroke.weights,hit.position,tool.radius)
    if stroke.dirty {stroke_write(s,tool,world,assets,allocator)}
}

// Takes the mesh an entity shows into memory, its vertices placed in the
// world, with the colors it shows (painted), and names the colors of the
// stroke. False when it is not a mesh that can be painted; what was taken
// goes with stroke_free.
@(private)
stroke_load :: proc(stroke:^Stroke,a:^host.Assets,e:core.Entity,shown:erender.Mesh_Renderer,painted:base.Asset_Id,placed:mm.Transform,allocator:runtime.Allocator) -> bool {
    stroke.allocator=allocator
    if !canvas_load(&stroke.canvas,a,shown,painted,allocator) {return false}
    stroke.before=slice.clone(stroke.canvas.colors,allocator)
    stroke.weights=make([]f32,len(stroke.before),allocator)
    to_world:=mm.transform_matrix(placed)
    for &position in stroke.canvas.positions {position=(to_world*[4]f32{position.x,position.y,position.z,1}).xyz}
    // A file per stroke: undoing one finds the colors of the stroke before it untouched.
    seed:=base.hash_combine(u64(e),platform.clock_ns())
    stroke.id=base.Asset_Id{seed,base.hash_combine(seed,base.name_hash("Painted"))}
    stroke.path=fmt.aprintf("%s/%s/%016x%s",a.registry.root,FOLDER,stroke.id[0],paint.PAINT_EXTENSION,allocator=allocator)
    stroke.entity=e
    return true
}

@(private)
stroke_move :: proc(s:^editor.Session,tool:^Paint_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,input:core.Input,frame:core.Frame_Time) {
    stroke:=&tool.stroke
    hit:=editor.pick_point(s,world,input.mouse_position)
    if hit.entity==stroke.entity && !hit.indicator {
        if stamp_segment(stroke.canvas.positions,stroke.weights,stroke.last,hit.position,tool.radius) {stroke.dirty=true}
        stroke.last,stroke.normal=hit.position,hit.normal
    }
    stroke.wait-=frame.dt
    if stroke.dirty && stroke.wait<=0 {stroke_write(s,tool,world,assets,allocator)}
}

// Writes the colors of the stroke so far, in the step of the stroke. The
// first time, opens the step; the stroke is cancelled when they cannot be
// written or named.
@(private)
stroke_write :: proc(s:^editor.Session,tool:^Paint_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator) -> bool {
    opened:=!tool.stroke.written
    if opened {history.edits_begin(s.edits,s.selection,"Paint")}
    if !stroke_apply(s,&tool.stroke,world,assets,allocator,tool.color,tool.strength) {
        editor.notify(s,"The painted colors could not be written")
        if opened {history.edits_cancel(s.edits,world)}
        stroke_cancel(s,tool,world)
        return false
    }
    return true
}

// Writes the colors into the open step. The first time the Painted of the
// entity names them; afterwards they are written again where they are.
@(private)
stroke_apply :: proc(s:^editor.Session,stroke:^Stroke,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,color:[3]f32,strength:f32) -> bool {
    painted:=core.world_table_of(world,paint.Painted)
    if assets==nil || painted==nil {return false}
    colors_blend(stroke.canvas.colors,stroke.before,stroke.weights,color,strength)
    bytes,ok:=canvas_bytes(&stroke.canvas,assets,stroke.id,allocator)
    defer delete(bytes,allocator)
    if !ok || !editor.file_write(s,stroke.path,bytes,"Paint") {return false}
    stroke.dirty,stroke.wait=false,REFRESH_SECONDS
    if stroke.written {return true}
    stroke.written=true
    if row:=core.edit(painted,stroke.entity);row!=nil {row.colors=stroke.id} else {core.add(painted,stroke.entity,paint.Painted{colors=stroke.id})}
    return true
}

// The paint of an entity whose mesh changed since it was painted (imported
// again) follows it: its colors go to the nearest vertices of the mesh as it
// is now, and its file is written again.
@(storage,free="paint_fit_free")
Paint_Fit :: struct {
    seen:u64,                  // the revision of the assets last looked at
    fit:map[base.Asset_Id]u64, // the content_hash of the mesh each .paint was found to fit
}

paint_fit_free :: proc(f:^Paint_Fit) {
    delete(f.fit)
    f^={}
}

@(step="frame")
paint_fit :: proc(s:^editor.Session,f:^Paint_Fit,tool:^Paint_Tool,meshes:^core.Table(erender.Mesh_Renderer,.Read),painted:^core.Table(paint.Painted,.Read),assets:^host.Assets) {
    if assets==nil || tool.stroke.active || editor.playing(s) || f.seen==assets.registry.revision {return}
    f.seen=assets.registry.revision
    for row in 0..<core.count(painted) {
        id:=core.at(painted,row).colors
        shown,has:=core.get(meshes,core.entity_at(painted,row))
        mesh,found:=asset.registry_find(&assets.registry,shown.mesh)
        if !has || !found || f.fit[id]==mesh.content_hash {continue}
        if paint_refit(s,assets,shown,id,mesh.content_hash) {f.fit[id]=mesh.content_hash}
    }
}

// Writes a .paint again fit to the mesh an entity shows, of that content_hash,
// unless it was painted on it.
@(private)
paint_refit :: proc(s:^editor.Session,a:^host.Assets,shown:erender.Mesh_Renderer,id:base.Asset_Id,mesh:u64) -> bool {
    record,found:=asset.registry_find(&a.registry,id)
    file:asset.Asset
    if !found || host.assets_file(a,id,paint.PAINT_KIND,&file)!=.None {return false}
    view,error:=paint.paint_view(&file,&a.types)
    painted_on:=view.mesh
    asset.asset_close(&file)
    if error!=.None {return false}
    if painted_on==mesh {return true}
    canvas:Canvas
    if !canvas_load(&canvas,a,shown,id,context.temp_allocator) {return false}
    defer canvas_destroy(&canvas)
    bytes,ok:=canvas_bytes(&canvas,a,id,context.temp_allocator)
    return ok && editor.file_set(s,asset.registry_file_path(&a.registry,record.path,context.temp_allocator),bytes)
}

// The stroke becomes one step of the history.
@(private)
stroke_end :: proc(s:^editor.Session,tool:^Paint_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator) {
    stroke:=&tool.stroke
    if stroke.dirty && !stroke_write(s,tool,world,assets,allocator) {return}
    if stroke.written {history.edits_end(s.edits)}
    stroke_free(tool)
}

// The entity shows again the colors it showed, and those of the stroke go
// with the step.
@(private)
stroke_cancel :: proc(s:^editor.Session,tool:^Paint_Tool,world:core.World_Ref) {
    if tool.stroke.written {history.edits_cancel(s.edits,world)}
    stroke_free(tool)
}

// Gives the selected entities back the colors of their mesh, as one step.
@(private)
paint_clear :: proc(s:^editor.Session,world:core.World_Ref) {
    if core.world_table_of(world,paint.Painted)==nil {return}
    history.edits_begin(s.edits,s.selection,"Clear paint")
    paint_restore(world,s.selection.entities[:])
    history.edits_end(s.edits)
}

// Gives entities back the colors of their mesh: how many were painted.
@(private)
paint_restore :: proc(world:core.World_Ref,entities:[]core.Entity) -> (restored:int) {
    painted:=core.world_table_of(world,paint.Painted)
    if painted==nil {return}
    for e in entities {
        if !core.has(painted,e) {continue}
        core.remove(painted,e)
        restored+=1
    }
    return
}

@(private)
clear_enabled :: proc(s:^editor.Session,world:core.World_Ref) -> bool {
    painted:=core.world_table_of(world,paint.Painted)
    if painted==nil {return false}
    for e in s.selection.entities {
        if core.has(painted,e) {return true}
    }
    return false
}

// The panel in the corner of the scene: the tool and its brush.
@(step="ui",after="editor_panels")
paint_panel :: proc(s:^editor.Session,tool:^Paint_Tool,world:core.World_Ref,input:core.Input) {
    g:=s.gui
    if !g.begun || editor.playing(s) {return}
    tool_ready(tool)
    ctx:=g.ctx
    tool.active=editor.tool_on(s,"paint")
    if !tool.active || s.viewport.pick.active {return}
    id:=ui.id_derive(ctx,PANEL_SCOPE,"panel")
    if ui.panel(ctx,id,editor.tool_panel(g,id)) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        kit.section(ctx,"Paint")
        radius,strength:=f64(tool.radius),f64(tool.strength)
        if kit.property(ctx,"Radius") {
            if ui.number_field(ctx,ui.id(ctx,"radius"),&radius,{min=f64(RADIUS_MIN),max=f64(RADIUS_MAX),has_min=true,has_max=true,speed=0.01}).changed {tool.radius=f32(radius)}
        }
        if kit.property(ctx,"Strength") {
            if ui.number_field(ctx,ui.id(ctx,"strength"),&strength,{min=0,max=1,has_min=true,has_max=true,speed=0.005}).changed {tool.strength=f32(strength)}
        }
        if kit.property(ctx,"Color") {kit.color_field(ctx,ui.id(ctx,"color"),&tool.color)}
        if ui.button(ctx,ui.id(ctx,"clear"),{label="Clear paint",variant="field",width=-1,center=true,disabled=!clear_enabled(s,world)}).clicked {paint_clear(s,world)}
    }
}
