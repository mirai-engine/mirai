package terrain_editor

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/jobs"
import mm "mirai:std/math"
import "mirai:ui"
import "base:runtime"

PANEL_SCOPE :: ui.Id(0x74657272)
RING_SEGMENTS :: 64
SCROLL_GUTTER :: ui.SCROLL_BAR+4 // the bar of the scroll area floats over the right edge of its content
PREVIEW_OWNER :: u64(0x7465727261696e)

// A .terrain in the browser and in the field of a Terrain.
@(storage)
Terrain_Kinds :: struct {provider:editor.Asset_Kind_Provider}
TERRAIN_KINDS_DEFAULT :: Terrain_Kinds{provider={kinds={0={kind=terrain.KIND,label="Terrain",color={168,124,72,255},icon=ui.Icon(u8(ui.Icon.User)+u8(editor.User_Icon.Terrain)),extension=terrain.EXTENSION,scene_data=true}},count=1}}

@(storage,free="terrain_tool_free")
Terrain_Tool :: struct {
    active,begin,over,ready:bool,
    brush:terrain.Brush_Kind,
    level:bool, // Flatten goes to height: Set height
    layer:int,  // the one Paint and Erase paint, and the one Add gives a Volume
    interior:terrain.Interior, // what the panel shows of the interior of a Volume until Apply
    interior_of:Interior_Of,
    shaping:bool, // Add and Carve place a shape (Shapes), not strokes of Sculpt
    axis:Stroke_Axis,
    using prefs:Terrain_Preferences, // radius and strength are in meters of the world and from 0 to 1
    height:f32,  // of Set height, in the terrain
    picking:bool, // the next press takes the height under it for Set height
    touches:u64,  // made by the tool: the seeds of what changes at each
    shape:Shape_Kind,
    adjust:editor.Brush_Adjust,
    create_source:Create_Source,
    scroll:[2]f32,
    heightmap_path:[4096]u8,
    heightmap_length:int,
    alphas:Terrain_Alphas,
    resize:[2]int, // the samples Resize gives a Heightfield; 0: those it has
    entity_open:bool, // the panel shows the details of the entity of the terrain
    stroke:Stroke,
    using history:Revisions,
    assets:^host.Assets,
    selection:core.Entity,
}
// The source and revision whose interior Terrain_Tool.interior was taken from.
Interior_Of :: struct {id:base.Asset_Id,revision:u32}

// A held brush touches the terrain at most this many times a second, with the
// time it waited: what a second of it does stays the same.
BRUSH_RATE :: 30

Stroke :: struct {
    active,changed:bool,
    touched:bool, // the held brush already touched the terrain in this stroke
    waited:f32,   // seconds since it last did
    first,last:[3]f32, // where the stroke began and its last touch, in the terrain
    last_normal:[3]f32,
    pointer:[2]f32,    // where the pointer was at the last touch, in the window
    view:[3]f32,       // toward the eye, in the terrain
    pending:Pending,
    entity:core.Entity,
    id:base.Asset_Id,
    source:terrain.Source,
    dirty:[2][2]int,  // the region of samples over x and z the stroke changed: low and high
    dirty_any,dirty_all:bool,
    builds:[dynamic]Preview_Build,
    previews:[dynamic]Preview,
    preview_at:[dynamic]i32, // the preview of each chunk of the grid, by preview_slot; -1: none
    levels_seen:u64,         // the version of the chunks when the levels of the previews were last chosen
    to_local,to_world:mm.Mat4,
    scale,target:f32,
    normal:[3]f32,
    revision:u32,
    stamp:terrain.File_Stamp, // of the file source holds
}
// lod: the level the chunk shows outside the stroke, which its neighbors join.
Preview :: struct {coord:[3]i32,lod:terrain.Chunk_Lod,mesh:base.Asset_Id,dirty,ready:bool}
// A preview chunk built in a job with the geometry the renderer takes, then
// published by the frame.
Preview_Build :: struct {
    counter:jobs.Counter,
    source:^terrain.Source,
    coord:[3]i32,
    lod:terrain.Chunk_Lod,
    limits:host.Assets_Limits,
    mesh:terrain.Chunk_Mesh,
    preview:int,
    ok:bool,
}
// Preview chunks built at once in a frame; more wait for these.
PREVIEW_BUILDS :: 8
Create_Source :: enum {Plane,Heightmap}

terrain_tool_free :: proc(t:^Terrain_Tool) {
    stroke_free(t)
    editor.revision_history_destroy(&t.history,REVISIONS)
    alphas_free(&t.alphas)
    t^={}
}
@(private)
tool_ready :: proc(t:^Terrain_Tool) {
    if t.ready {return}
    t.ready=true
    // The preferences of the editor read before the tool is first ready.
    if t.prefs==(Terrain_Preferences{}) {t.prefs=TERRAIN_PREFERENCES_DEFAULT}
}
@(private)
stroke_free :: proc(t:^Terrain_Tool) {
    if t.assets!=nil {for preview in t.stroke.previews {if preview.mesh!={} {host.assets_mesh_release(t.assets,preview.mesh)}}}
    delete(t.stroke.previews)
    delete(t.stroke.preview_at)
    for &build in t.stroke.builds {terrain.chunk_mesh_destroy(&build.mesh)}
    delete(t.stroke.builds)
    terrain.source_destroy(&t.stroke.source)
    t.stroke={}
}
@(step="input",after="editor_begin")
terrain_pointer :: proc(s:^editor.Session,tool:^Terrain_Tool,input:core.Input) {
    tool_ready(tool)
    tool.active,tool.over,tool.begin=editor.tool_pointer(s,"terrain",input)
}
// The head of the source of the stroke, at its revision: what the stroke
// starts from. The first stroke of a source makes it, a copy of the source.
@(private)
stroke_baseline :: proc(t:^Terrain_Tool) -> bool {
    stroke:=&t.stroke
    entry:=editor.revision_applied(&t.history,stroke.id)
    if entry==nil {
        if append(&t.applied,Applied{source=stroke.id,revision=stroke.revision,stamp=stroke.stamp})!=1 {return false}
        entry=&t.applied[len(t.applied)-1]
    }
    if entry.held && entry.revision==stroke.revision {return true}
    head:terrain.Source
    if !terrain.source_clone(&head,&stroke.source,editable=false) {return false}
    terrain.source_destroy(&entry.head)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    entry.head=head
    entry.held,entry.revision,entry.stamp=true,stroke.revision,stroke.stamp
    return true
}
// Puts a source in the file of its terrain, in the memory of the registry,
// unsaved, outside the history of the editor (terrain_history.odin).
@(private)
terrain_write :: proc(s:^editor.Session,a:^host.Assets,id:base.Asset_Id,source:^terrain.Source,keep:=false) -> bool {
    path,found:=terrain.terrain_file(a,id)
    if !found {return false}
    bytes,error:=terrain.source_bytes(source,id,&a.types,a.allocator,keep=keep)
    if error!=.None {return false}
    defer delete(bytes,a.allocator)
    return editor.file_set(s,path,bytes)
}
@(step="frame",stage="begin",after="editor_tools")
terrain_sync :: proc(s:^editor.Session,tool:^Terrain_Tool,terrains:core.Read(terrain.Terrain),assets:^host.Assets) {
    a:=assets
    if a==nil || tool.stroke.active || editor.playing(s) {return}
    // The source the tool edits follows its head without reading the file again.
    follow :: proc(user:rawptr,held:^Applied,path:[]int) {
        tool:=(^Terrain_Tool)(user)
        stroke:=&tool.stroke
        if stroke.id!=held.source {return}
        followed:=true
        for i in path {followed&&=step_follow(&tool.steps[i],&stroke.source,&held.head)}
        if followed && terrain.chunk_counts(&stroke.source)==terrain.chunk_counts(&held.head) {stroke.revision,stroke.stamp=held.revision,held.stamp} else {stroke_free(tool)}
    }
    editor.revision_sync(s,&tool.history,terrains,a,REVISIONS,tool,follow)
}
@(step="frame",after="editor_tools")
terrain_sculpt :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,terrains:core.Read(terrain.Terrain),chunks:core.Read(terrain.Terrain_Chunk),worlds:core.Read(core.World_Transform),assets:^host.Assets,extras:^host.Frame_Extras,job_system:^jobs.Job_System,allocator:runtime.Allocator,input:core.Input,view:core.View,frame:core.Frame_Time) {
    stroke:=&tool.stroke
    defer terrain_focus(s,tool,world,input)
    if !tool.active || editor.playing(s) {if stroke.id!={} {stroke_free(tool)};tool.adjust={};return}
    if !s.gui.begun {return}
    // W, E and R give the scene to the gizmo; a brush takes it back.
    editor.tool_lend(s,"terrain")
    if editor.tool_aside(s,"terrain") {
        if stroke.active {stroke_cancel(tool)}
        tool.adjust={}
        editor.tool_keys(s,"terrain",TOOL_KEYS-{.F})
        if stroke.id!={} {terrain_keys(s,tool,world,assets,input)}
        return
    }
    keys:=TOOL_KEYS
    if stroke.active || tool.adjust.active {keys+={.Escape,.Enter}}
    editor.tool_keys(s,"terrain",keys)
    if tool.adjust.active {
        adjust_frame(s,tool,input)
        if stroke.active && stroke.pending.kind!=.None {pending_preview(s,tool,world);pending_draw(s,tool)}
        if stroke.active {stroke_preview(s,tool,world,terrains,chunks,worlds,assets,extras,job_system)}
        return
    }
    if stroke.active && stroke.pending.kind!=.None {
        if !core.alive(core.world_entities(world),stroke.entity) || !core.has(terrains,stroke.entity) {stroke_free(tool);return}
        if !stroke.pending.placing && stroke.pending.handle<0 {
            terrain_keys(s,tool,world,assets,input)
            if adjust_key(s,tool,input) {stroke_preview(s,tool,world,terrains,chunks,worlds,assets,extras,job_system);return}
        }
        if pending_frame(s,tool,world,assets,input,view) {stroke_preview(s,tool,world,terrains,chunks,worlds,assets,extras,job_system)}
        if stroke.active {pending_draw(s,tool)}
        return
    }
    if stroke.active {
        if !core.alive(core.world_entities(world),stroke.entity) || !core.has(terrains,stroke.entity) {stroke_free(tool);return}
        if ui.escape(s.gui.ctx) {stroke_cancel(tool);return}
        if !core.mouse_down(input,.Left) {stroke_end(s,tool,world,assets);return}
        stroke_apply(s,tool,world,input,view,frame)
        stroke_preview(s,tool,world,terrains,chunks,worlds,assets,extras,job_system)
        cursor_draw(s,tool,input,view)
        return
    }
    if stroke.id!={} {terrain_keys(s,tool,world,assets,input)} else {create_outline_draw(s,tool)}
    if !tool.over {return}
    hit:=editor.pick_point(s,world,input.mouse_position)
    if child,ok:=core.get(chunks,hit.entity);ok {hit.entity=child.owner}
    // The source of the selected terrain answers where the picker has nothing of it.
    if hit.entity==core.NONE && stroke.id!={} && history.selection_has(s.selection,stroke.entity) {
        if _,_,ok:=stroke_point(stroke,s.viewport,input.mouse_position);ok {hit={entity=stroke.entity}}
    }
    if hit.entity==core.NONE || hit.indicator || !core.has(terrains,hit.entity) {return}
    if !history.selection_has(s.selection,hit.entity) {
        if tool.begin {history.selection_set(s.selection,{hit.entity})}
        return
    }
    if !stroke_prepare(tool,assets,allocator,terrains,worlds,hit) {return}
    if adjust_key(s,tool,input) {return}
    if tool.begin && stroke_begin(s,tool,world,input,view) {
        if stroke.pending.kind==.None {stroke_apply(s,tool,world,input,view,frame)}
        stroke_preview(s,tool,world,terrains,chunks,worlds,assets,extras,job_system)
        if stroke.pending.kind!=.None {pending_draw(s,tool);return}
    }
    cursor_draw(s,tool,input,view)
}
@(private)
stroke_prepare :: proc(tool:^Terrain_Tool,assets:^host.Assets,allocator:runtime.Allocator,terrains:core.Read(terrain.Terrain),worlds:core.Read(core.World_Transform),hit:editor.Pick) -> bool {
    a:=assets
    marker,has_marker:=core.get(terrains,hit.entity)
    placed,has_placed:=core.get(worlds,hit.entity)
    if a==nil || !has_marker || !has_placed {return false}
    stroke:=&tool.stroke
    stamp:=terrain.terrain_stamp(a,marker.source)
    if stroke.id=={} || stroke.id!=marker.source || stroke.revision!=marker.revision || stroke.stamp!=stamp {
        if !stamp.found {stroke_free(tool);return false}
        stroke_free(tool);tool.assets=a
        if !terrain.terrain_read(&stroke.source,a,marker.source,allocator) {stroke_free(tool);return false}
        id:=marker.source
        builds,builds_error:=make([dynamic]Preview_Build,PREVIEW_BUILDS,allocator)
        stroke.builds=builds
        if builds_error!=nil {stroke_free(tool);return false}
        for &build in stroke.builds {terrain.chunk_mesh_init(&build.mesh,allocator)}
        counts:=terrain.chunk_counts(&stroke.source)
        previews,error:=make([dynamic]Preview,0,counts.x*counts.y*counts.z,allocator)
        stroke.previews=previews
        if error!=nil {stroke_free(tool);return false}
        at,at_error:=make([dynamic]i32,counts.x*counts.y*counts.z,allocator)
        stroke.preview_at=at
        if at_error!=nil {stroke_free(tool);return false}
        for &slot in stroke.preview_at {slot=-1}
        stroke.id,stroke.revision,stroke.stamp=id,marker.revision,stamp
        brush_fit(tool,stroke.source.kind)
    }
    stroke.to_world=mm.transform_matrix(placed.transform);stroke.to_local=linalg.inverse(stroke.to_world)
    stroke.scale=max(linalg.length(stroke.to_world[1].xyz),1e-6);stroke.entity=hit.entity
    return true
}
// The point of the terrain under a point of the window: of source, the one
// being edited when nil.
@(private)
stroke_point :: proc(stroke:^Stroke,v:^editor.Viewport,at:[2]f32,source:^terrain.Source=nil) -> (point,normal:[3]f32,ok:bool) {
    from,toward:=stroke_ray(stroke,v,at)
    return terrain.source_ray(source!=nil?source:&stroke.source,from,toward)
}
// The ray of the viewport through a point of the window, in the terrain: the
// scene begins under the bars, not at the corner of the window.
@(private)
stroke_ray :: proc(stroke:^Stroke,v:^editor.Viewport,at:[2]f32) -> (origin,direction:[3]f32) {
    ray:=editor.viewport_ray(v,at)
    o,d:=ray.origin,ray.direction
    return (stroke.to_local*[4]f32{o.x,o.y,o.z,1}).xyz,(stroke.to_local*[4]f32{d.x,d.y,d.z,0}).xyz
}
@(private)
stroke_changed :: proc(stroke:^Stroke,change:terrain.Change) {
    if !change.changed {return}
    stroke.changed=true
    from,to:=[2]int{change.low.x,change.low.z},[2]int{change.high.x,change.high.z}
    if !stroke.dirty_any {stroke.dirty={from,to}} else {stroke.dirty={linalg.min(stroke.dirty[0],from),linalg.max(stroke.dirty[1],to)}}
    stroke.dirty_any=true
    low,high:=terrain.chunk_range(&stroke.source,change)
    for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {
        coord:=[3]i32{i32(x),i32(y),i32(z)}
        if !terrain.chunk_touched(&stroke.source,coord,change) {continue}
        if at:=preview_find(stroke,coord);at>=0 {stroke.previews[at].dirty=true;continue}
        if slot:=preview_slot(stroke,coord);slot>=0 {stroke.preview_at[slot]=i32(len(stroke.previews))}
        append(&stroke.previews,Preview{coord=coord,dirty=true})
    }}}
}
// The place of a chunk in the grid of the source; -1 outside it.
@(private)
preview_slot :: proc(stroke:^Stroke,coord:[3]i32) -> int {
    counts:=terrain.chunk_counts(&stroke.source)
    for axis in 0..<3 {if coord[axis]<0 || int(coord[axis])>=counts[axis] {return -1}}
    slot:=int(coord.x)+counts.x*(int(coord.y)+counts.y*int(coord.z))
    return slot<len(stroke.preview_at)?slot:-1
}

// The preview of a chunk in the stroke; -1 when it has none.
@(private)
preview_find :: proc(stroke:^Stroke,coord:[3]i32) -> int {
    if slot:=preview_slot(stroke,coord);slot>=0 {return int(stroke.preview_at[slot])}
    for preview,at in stroke.previews {if preview.coord==coord {return at}}
    return -1
}

// The levels the chunks of the stroke show: each its level outside the
// stroke, a chunk with holes level 0 as the runtime makes it, and each side
// the finer of the two chunks it joins. A chunk previewed at a coarse level
// joins those around it; one whose side changes is previewed too. A
// Heightfield keeps the border each chunk shows, lowered only where a hole
// takes a chunk to level 0; the nodes of the quadtree are not previewed.
@(private)
preview_levels :: proc(stroke:^Stroke,terrains:core.Read(terrain.Terrain),chunks:core.Read(terrain.Terrain_Chunk)) {
    dirty:=false
    for preview in stroke.previews {dirty||=preview.dirty}
    if !dirty && core.version(chunks)==stroke.levels_seen {return}
    stroke.levels_seen=core.version(chunks)
    s:=&stroke.source
    counts:=terrain.chunk_counts(s)
    levels:=make([]u8,counts.x*counts.y*counts.z,context.temp_allocator)
    shown:=make([]terrain.Chunk_Lod,len(levels),context.temp_allocator)
    has:=make([]bool,len(levels),context.temp_allocator)
    dropped:=make([]bool,len(levels),context.temp_allocator)
    for row in 0..<core.count(chunks) {
        chunk:=core.at(chunks,row)
        owner,known:=core.get(terrains,chunk.owner)
        if !known || owner.source!=stroke.id || chunk.depth>0 {continue}
        if index:=terrain.chunk_index(s,chunk.coord);index>=0 {levels[index],shown[index],has[index]=chunk.lod.level,chunk.lod,true}
    }
    for &level,index in levels {if level>0 && terrain.chunk_holed(s,index) {level,dropped[index]=0,true}}
    for index in 0..<len(levels) {
        coord:=terrain.chunk_coord(s,index)
        lod:=terrain.chunk_lod_sides(s,levels,coord)
        if s.kind==.Heightfield {
            if !has[index] {continue}
            lod=shown[index]
            lod.level=levels[index]
            lod.faces[2],lod.faces[3]=lod.level,lod.level
            for &edge in lod.edges {edge=lod.level}
            lower :: proc(s:^terrain.Source,levels:[]u8,dropped,has:[]bool,value:^u8,around:[]([3]i32)) {
                for coord in around {
                    at:=terrain.chunk_index(s,coord)
                    if at>=0 && has[at] && dropped[at] {value^=min(value^,levels[at])}
                }
            }
            x,z:=coord.x,coord.z
            lower(s,levels,dropped,has,&lod.faces[0],{{x,0,z},{x-1,0,z}})
            lower(s,levels,dropped,has,&lod.faces[1],{{x,0,z},{x+1,0,z}})
            lower(s,levels,dropped,has,&lod.faces[4],{{x,0,z},{x,0,z-1}})
            lower(s,levels,dropped,has,&lod.faces[5],{{x,0,z},{x,0,z+1}})
            for &corner,k in lod.corners {
                dx,dz:=i32(k&1),i32(k>>1)
                lower(s,levels,dropped,has,&corner,{{x+dx-1,0,z+dz-1},{x+dx,0,z+dz-1},{x+dx-1,0,z+dz},{x+dx,0,z+dz}})
            }
        }
        at:=preview_find(stroke,coord)
        if at<0 {
            if lod==shown[index] {continue}
            if slot:=preview_slot(stroke,coord);slot>=0 {stroke.preview_at[slot]=i32(len(stroke.previews))}
            append(&stroke.previews,Preview{coord=coord,lod=lod,dirty=true})
            continue
        }
        if stroke.previews[at].lod!=lod {stroke.previews[at].lod,stroke.previews[at].dirty=lod,true}
    }
}
@(private)
stroke_preview :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,terrains:core.Read(terrain.Terrain),chunks:core.Read(terrain.Terrain_Chunk),worlds:core.Read(core.World_Transform),assets:^host.Assets,extras:^host.Frame_Extras,job_system:^jobs.Job_System) {
    stroke:=&tool.stroke
    a:=assets
    if a==nil || a.renderer==nil {return}
    preview_levels(stroke,terrains,chunks)
    // The chunks a change touched are built side by side in jobs, then
    // published in order; the frame waits for all of them.
    parallel:=jobs.worker_count(job_system)>1
    next:=0
    for next<len(stroke.previews) {
        count:=0
        for ;next<len(stroke.previews) && count<len(stroke.builds);next+=1 {
            preview:=&stroke.previews[next]
            if !preview.dirty {continue}
            build:=&stroke.builds[count]
            build.source,build.coord,build.preview,build.ok=&stroke.source,preview.coord,next,false
            build.lod=preview.lod
            build.limits=host.assets_limits(a)
            if parallel {jobs.run(job_system,jobs.OWNER,preview_build,build,&build.counter)} else {preview_build(build,jobs.OWNER)}
            count+=1
        }
        for &build in stroke.builds[:count] {
            if jobs.pending(&build.counter) {jobs.wait(job_system,jobs.OWNER,&build.counter)}
            preview:=&stroke.previews[build.preview]
            if !build.ok {editor.notify(s,"The terrain preview could not be rebuilt");continue}
            id,ok:=terrain.chunk_publish(a,stroke.source.kind,&build.mesh,false)
            if !ok {editor.notify(s,"The terrain preview could not be rebuilt");continue}
            if preview.mesh!={} {host.assets_mesh_release(a,preview.mesh)}
            preview.mesh,preview.ready,preview.dirty=id,true,false
        }
    }
    statics:=core.world_table_of(world,erender.Mesh_Renderer)
    if statics==nil {return}
    tints:=core.world_table_of(world,erender.Tint);overrides:=core.world_table_of(world,erender.Material_Override)
    // The view that shows the weights of the layers shows them on the preview too.
    overlay:=Terrain_Overlay.None
    if view:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Terrain_View);view!=nil {overlay=view.overlay}
    for row in 0..<core.count(chunks) {
        chunk:=core.at(chunks,row)
        owner,known:=core.get(terrains,chunk.owner)
        // What a join builds shows the stroke once it is confirmed.
        if !known || owner.source!=stroke.id || chunk.depth>0 || chunk.joined {continue}
        at:=preview_find(stroke,chunk.coord)
        if at<0 || !stroke.previews[at].ready {continue}
        preview:=&stroke.previews[at]
        e:=core.entity_at(chunks,row)
        placed,has_pose:=core.get(worlds,e)
        if !has_pose || editor.entity_hidden(world,e) {continue}
        static,has_static:=core.get(core.read(statics),e)
        if !has_static {static.materials=terrain.chunk_materials(&stroke.source)}
        tint:=erender.TINT_DEFAULT;override:erender.Material_Override
        if tints!=nil {
            if value,ok:=core.get(core.read(tints),e);ok {tint=value} else if value,ok:=core.get(core.read(tints),chunk.owner);ok {tint=value}
        }
        if overrides!=nil {
            found:bool;override,found=core.get(core.read(overrides),e)
            if !found {override,_=core.get(core.read(overrides),chunk.owner)}
        }
        if preview.mesh!={} {static.mesh,static.shape=preview.mesh,.None}
        if overlay_weights(overlay) {static.materials[0],override=WEIGHTS_MATERIAL,weights_override(overlay,tool.layer)}
        if instance,ok:=erender.mesh_instance(a,static,mm.transform_matrix(placed.transform),tint,override);ok {
            instance.object_id,instance.copy_owner,instance.copy_variant=u64(e),PREVIEW_OWNER,1
            instance.replace_source=true;instance.hidden=preview.mesh=={}
            host.extras_instance_add(extras,instance)
        }
    }
    host.assets_commit(a)
}
@(private)
preview_build :: proc(build:^Preview_Build,worker:int) {
    build.ok=terrain.chunk_build(build.source,build.coord,&build.mesh,false,build.lod)
    if build.ok {terrain.chunk_render_prepare(build.source.kind,&build.mesh,build.limits)}
}
@(private)
stroke_end :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,consume:=core.NONE,label:="Sculpt") {
    stroke:=&tool.stroke
    committed:=false
    defer if !committed {stroke_free(tool)}
    a:=assets;table:=core.world_table_of(world,terrain.Terrain)
    if !stroke.changed || a==nil || table==nil {return}
    marker,known:=core.get(core.read(table),stroke.entity)
    if !known || marker.source!=stroke.id || marker.revision!=stroke.revision {return}
    if !terrain_budget(s,world,&stroke.source,stroke.id) {return}
    held:=editor.revision_applied(&tool.history,stroke.id)
    if held==nil || !held.held || held.revision!=stroke.revision {editor.notify(s,"The terrain history could not be stored");return}
    next:=stroke.revision+1;stroke.source.revision=next
    // The head takes what the stroke changed and the step what it held there.
    step:=Step{source=stroke.id,from=stroke.revision,to=next}
    // A change no touch reported is looked for everywhere.
    if !step_make(&step,&held.head,&stroke.source,stroke.dirty[0],stroke.dirty[1],stroke.dirty_all || !stroke.dirty_any) {editor.notify(s,"The terrain history could not be stored");return}
    if !terrain_write(s,a,stroke.id,&held.head,keep=true) {step_revert(&step,&held.head);editor.notify(s,"The terrain could not be written");return}
    if !editor.revision_push(&tool.history,&step,step_destroy) {editor.notify(s,"The terrain history could not be stored")}
    stroke.stamp=terrain.terrain_stamp(a,stroke.id)
    history.edits_begin(s.edits,s.selection,label)
    for value,row in table.values[:core.count(table)] {if value.source==stroke.id {core.at(table,row).revision=next}}
    if consume!=core.NONE {editor.entities_delete(s,{consume});history.selection_set(s.selection,{stroke.entity})}
    history.edits_end(s.edits)
    held.revision,held.stamp=next,stroke.stamp
    for preview in stroke.previews {
        if preview.mesh!={} {host.assets_mesh_release(a,preview.mesh)}
        if slot:=preview_slot(stroke,preview.coord);slot>=0 {stroke.preview_at[slot]=-1}
    }
    clear(&stroke.previews)
    stroke.revision=next;stroke.active,stroke.changed=false,false
    stroke.touched,stroke.waited=false,0
    stroke.pending={}
    stroke.dirty,stroke.dirty_any,stroke.dirty_all={},false,false
    committed=true
}

// Puts back what the stroke changed, from the head, and lets go of its
// previews: the terrain shows its file again without reading it.
@(private)
stroke_cancel :: proc(tool:^Terrain_Tool) {
    stroke:=&tool.stroke
    head:=editor.revision_head(&tool.history,stroke.id,stroke.revision)
    if head==nil || !source_take_back(&stroke.source,head,stroke.dirty[0],stroke.dirty[1]) {stroke_free(tool);return}
    if tool.assets!=nil {
        for preview in stroke.previews {
            if preview.mesh!={} {host.assets_mesh_release(tool.assets,preview.mesh)}
            if slot:=preview_slot(stroke,preview.coord);slot>=0 {stroke.preview_at[slot]=-1}
        }
    }
    clear(&stroke.previews)
    stroke.active,stroke.changed=false,false
    stroke.touched,stroke.waited=false,0
    stroke.pending={}
    stroke.dirty,stroke.dirty_any,stroke.dirty_all={},false,false
}

// Where the brush is, for the terrain runtime (Terrain_Focus): its chunks
// there show as chunks, which the preview replaces, also where the view shows
// the nodes over them. A chunk around the ring as well: what a stroke reaches
// past its radius shows too.
@(private)
terrain_focus :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,input:core.Input) {
    focus:=core.world_storage_of(world,terrain.Terrain_Focus)
    if focus==nil {return}
    stroke:=&tool.stroke
    next:terrain.Terrain_Focus
    if tool.active && !editor.playing(s) && stroke.id!={} && !editor.tool_aside(s,"terrain") && (stroke.active || tool.over) {
        point:[3]f32;ok:bool
        if stroke.active {point,ok=stroke.last,stroke.touched} else {point,_,ok=stroke_point(stroke,s.viewport,input.mouse_position)}
        if ok {next={source=stroke.id,center=point,radius=brush_of(tool).radius/stroke.scale+stroke.source.cell*f32(stroke.source.chunk_cells)}}
        // What the stroke changed, a cell around it, for the foliage over it.
        if stroke.active && stroke.dirty_any {
            origin:=terrain.source_origin(&stroke.source)
            next.stroke=true
            if stroke.dirty_all {
                next.low=origin.xz
                next.high=origin.xz+[2]f32{f32(stroke.source.samples.x-1),f32(stroke.source.samples.z-1)}*stroke.source.cell
            } else {
                next.low=origin.xz+([2]f32{f32(stroke.dirty[0].x),f32(stroke.dirty[0].y)}-1)*stroke.source.cell
                next.high=origin.xz+([2]f32{f32(stroke.dirty[1].x),f32(stroke.dirty[1].y)}+1)*stroke.source.cell
            }
        }
    }
    if focus^!=next {focus^=next}
}
