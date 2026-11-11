package terrain_editor

import "core:fmt"
import "core:math/linalg"
import "core:path/filepath"
import "mirai:asset"
import "mirai:core"
import "mirai:cook/textures"
import "mirai:editor"
import "mirai:editor/history"
import phys "plugins:physics/runtime"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:platform"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"
import "base:runtime"

@(private) HEIGHTMAP_DIALOG :: u32(0x74657268)

@(private)
terrain_kind_name :: proc(kind:terrain.Source_Kind) -> string {
    switch kind {case .Heightfield:return "Heightfield Terrain";case .Volume:return "Volumetric Terrain"}
    return "Terrain"
}

@(private)
terrain_creation_panel :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App) {
    ctx:=s.gui.ctx
    kind:=int(tool.create_kind)
    if ui.dropdown(ctx,ui.id(ctx,"source_kind"),{list={"Heightfield Terrain","Volumetric Terrain"}},&kind,{width=-1,height=ctx.theme.row}) {tool.create_kind=terrain.Source_Kind(kind)}
    if tool.create_kind!=.Volume {
        source:=int(tool.create_source)
        if ui.tabs(ctx,ui.id(ctx,"create_source"),{"Plane","Heightmap"},&source) {tool.create_source=Create_Source(source)}
    }
    heightmap:=tool.create_kind!=.Volume && tool.create_source==.Heightmap
    samples,depth,cell,chunk:=f64(tool.samples),f64(tool.depth),f64(tool.cell),f64(tool.chunk_cells)
    maximum:=tool.create_kind==.Volume?f64(terrain.VOLUME_SAMPLES_MAX):f64(terrain.HEIGHT_SAMPLES_MAX)
    tool.samples=min(tool.samples,int(maximum));samples=f64(tool.samples)
    if !heightmap {
        if ui.property(ctx,"Samples X/Z") {if ui.number_field(ctx,ui.id(ctx,"samples"),&samples,{min=3,max=maximum,has_min=true,has_max=true,speed=1}).changed {tool.samples=int(samples)}}
    }
    if tool.create_kind==.Volume {if ui.property(ctx,"Samples Y") {if ui.number_field(ctx,ui.id(ctx,"depth"),&depth,{min=3,max=terrain.VOLUME_SAMPLES_MAX,has_min=true,has_max=true,speed=1}).changed {tool.depth=int(depth)}}}
    if heightmap {
        result:=platform.dialog_result(app.platform)
        if result.tag==HEIGHTMAP_DIALOG && result.state==.Accepted {tool.heightmap_length=copy(tool.heightmap_path[:],transmute([]u8)result.path)}
        path:=string(tool.heightmap_path[:tool.heightmap_length])
        if ui.button(ctx,ui.id(ctx,"heightmap"),{label=path==""?"Choose heightmap":filepath.base(path),style=.Field,width=-1,center=true}).clicked {
            if !platform.dialog_show(app.platform,{kind=.Open_File,tag=HEIGHTMAP_DIALOG,filters={{"Heightmap","png;tga;bmp"}},location=s.assets_root}) {editor.notify(s,"A file dialog is already open")}
        }
        heightmap_fields(s,tool)
    }
    if ui.property(ctx,"Spacing") {if ui.number_field(ctx,ui.id(ctx,"cell"),&cell,{min=0.01,max=100,has_min=true,has_max=true,speed=0.05,unit="m"}).changed {tool.cell=f32(cell)}}
    if ui.property(ctx,"Chunk cells") {if ui.number_field(ctx,ui.id(ctx,"chunk"),&chunk,{min=terrain.CHUNK_CELLS_MIN,max=terrain.CHUNK_CELLS_MAX,has_min=true,has_max=true,speed=1}).changed {tool.chunk_cells=int(chunk)}}
    // What it makes, in metres and chunks; the view shows its outline.
    if !heightmap {
        side:=f32(max(tool.samples,2)-1)*tool.cell
        chunks:=(max(tool.samples,2)-1+max(tool.chunk_cells,1)-1)/max(tool.chunk_cells,1)
        size:=fmt.tprintf("%.0f × %.0f m, %d × %d chunks",side,side,chunks,chunks)
        if tool.create_kind==.Volume {size=fmt.tprintf("%.0f × %.0f × %.0f m",side,f32(max(tool.depth,2)-1)*tool.cell,side)}
        if ui.property(ctx,"Size") {ui.label(ctx,size,ctx.theme.font,ctx.theme.text_muted)}
    }
    if ui.button(ctx,ui.id(ctx,"create"),{label="New terrain",style=.Field,width=-1,center=true}).clicked {terrain_create(s,tool,world,app.assets,app.allocator)}
}

@(private)
terrain_create :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,at:=[3]f32{},placed:=false,ground:=core.NONE,name:="") -> (made:core.Entity) {
    a:=assets;terrains:=core.world_table_of(world,terrain.Terrain)
    if a==nil || terrains==nil {editor.notify(s,"The project has no terrain library");return}
    source:terrain.Source
    defer terrain.source_destroy(&source)
    over:Ground_Placement
    if ground!=core.NONE {
        if tool.create_kind!=.Volume {editor.notify(s,"Only a Volume joins a Heightfield");return}
        ok:bool
        if over,ok=volume_over_ground(s,world,assets,allocator,ground,at,placed,tool,&source);!ok {return}
    } else if tool.create_kind!=.Volume && tool.create_source==.Heightmap {
        path:=string(tool.heightmap_path[:tool.heightmap_length])
        bytes,error:=serial.file_read(path,allocator,limit=64*1024*1024)
        if error!=.None {editor.notify(s,fmt.tprintf("The heightmap %s could not be read: %v",path,error));return}
        defer delete(bytes,allocator)
        heightmap,decode:=textures.heightmap_decode(bytes,terrain.HEIGHT_SAMPLES_MAX,allocator)
        if decode!=.None {editor.notify(s,fmt.tprintf("Heightmap: %v",decode));return}
        defer textures.heightmap_destroy(&heightmap)
        if !terrain.source_make(&source,.Heightfield,{heightmap.width,1,heightmap.height},tool.cell,tool.chunk_cells,allocator) {editor.notify(s,"The heightmap dimensions exceed their budget");return}
        if !terrain.grid_prepare(&source.field,{0,0,0},{heightmap.width-1,0,heightmap.height-1},source.allocator) {editor.notify(s,"There is not enough memory for the heightmap");return}
        for value,i in heightmap.values {
            height:=value*tool.height_scale+tool.height_offset
            if abs(height)>terrain.HEIGHT_LIMIT {editor.notify(s,"Heightmap heights exceed the terrain limit");return}
            terrain.grid_set(&source.field,i%heightmap.width,i/heightmap.width,height)
        }
    } else {
        samples:=[3]int{tool.samples,tool.create_kind==.Volume?tool.depth:1,tool.samples}
        if !terrain.source_make(&source,tool.create_kind==.Volume?.Volume:.Heightfield,samples,tool.cell,tool.chunk_cells,allocator) {editor.notify(s,"The terrain dimensions exceed their budget");return}
    }
    if !terrain_budget(s,world,&source) {return}
    label,path:=editor.asset_new_file(s,fmt.tprintf("%s/terrain",a.registry.root),name!=""?name:terrain_kind_name(source.kind),terrain.TERRAIN_EXTENSION,name!="")
    source.revision=1;seed:=base.hash_combine(base.name_hash(path),platform.clock_ns())
    id:=base.Asset_Id{seed,base.hash_combine(seed,base.name_hash("Terrain"))}
    bytes,error:=terrain.source_bytes(&source,id,&a.types,allocator)
    if error!=.None {editor.notify(s,"The terrain could not be written");return}
    defer delete(bytes,allocator)
    // The new file is part of the step: undo takes it away, and it stays in
    // the memory of the registry until it is saved.
    history.edits_begin(s.edits,editor.document_selection(s),"Add terrain")
    if !editor.file_write(s,path,bytes,"Add terrain") {history.edits_cancel(s.edits,world);editor.notify(s,"The terrain could not be written");return}
    position:=placed?at:[3]f32{s.viewport.orbit.target.x,0,s.viewport.orbit.target.z}
    transform:=core.Transform{position=position,rotation=1,scale={1,1,1}}
    if ground!=core.NONE {transform=over.transform}
    e:=editor.entity_create(s,{name=label,transform=transform})
    core.add(terrains,e,terrain.Terrain{source=id,revision=1,solid=true,ground=over.id})
    history.edits_end(s.edits);history.selection_set(editor.document_selection(s),{e})
    append(&tool.applied,Applied{source=id,revision=1,stamp=terrain.terrain_stamp(a,id)})
    stroke_free(tool)
    return e
}

Ground_Placement :: struct {transform:core.Transform,id:base.Entity_Id}

// A Volume over a Heightfield terrain, joined to it (Terrain.ground): its
// samples over those of the Heightfield, its box centered on at (the target
// of the view without it) with the ground at its middle, its field the ground
// to dig into.
@(private)
volume_over_ground :: proc(s:^editor.Session,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,ground:core.Entity,at:[3]f32,placed:bool,tool:^Terrain_Tool,source:^terrain.Source) -> (over:Ground_Placement,ok:bool) {
    terrains:=core.world_table_of(world,terrain.Terrain)
    marker,is:=core.get(terrains,ground)
    place:=editor.entity_world(world,ground)
    over.id=editor.api_entity_id(world,ground)
    if !is || over.id==0 {editor.notify(s,"The ground to join is no terrain with an Id");return}
    g:terrain.Source
    defer terrain.source_destroy(&g)
    if !terrain.terrain_read(&g,assets,marker.source,allocator) || g.kind!=.Heightfield {editor.notify(s,"A Volume joins a Heightfield terrain");return}
    n:=[2]int{tool.samples,tool.samples}
    if n.x>int(g.samples.x) || n.y>int(g.samples.z) {editor.notify(s,"The Volume is larger than the Heightfield it joins");return}
    target:=placed?at:[3]f32{s.viewport.orbit.target.x,0,s.viewport.orbit.target.z}
    local:=mm.transform_inverse_point(place,target)
    origin:=terrain.source_origin(&g)
    center:=[2]int{int(linalg.round((local.x-origin.x)/g.cell)),int(linalg.round((local.z-origin.z)/g.cell))}
    offset:=[2]int{clamp(center.x-(n.x-1)/2,0,int(g.samples.x)-n.x),clamp(center.y-(n.y-1)/2,0,int(g.samples.z)-n.y)}
    if !terrain.source_make(source,.Volume,{n.x,tool.depth,n.y},g.cell,tool.chunk_cells,allocator) {editor.notify(s,"The terrain dimensions exceed their budget");return}
    middle:=terrain.grid_get(&g.field,offset.x+(n.x-1)/2,offset.y+(n.y-1)/2)
    lift:=middle-f32(tool.depth-1)*0.5*g.cell
    if !terrain.source_volume_ground(source,{ground=&g,offset=offset,lift=lift}) {editor.notify(s,"There is not enough memory for the Volume");return}
    corner:=origin+[3]f32{f32(offset.x)*g.cell,lift,f32(offset.y)*g.cell}
    over.transform=core.Transform(place)
    over.transform.position=mm.transform_point(place,corner-terrain.source_point(source,{}))
    return over,true
}

@(private)
edit_error :: proc(s:^editor.Session,error:terrain.Edit_Error,kind:terrain.Brush_Kind) {
    if error!=.None {editor.notify(s,fmt.tprintf("The terrain was not edited: %s",terrain.edit_error_fix(error,kind)))}
}

// Writes the surface of the Volume being edited as a plain .mesh beside its
// source, with the clusters of the engine and the material of its first
// layer: the static form of what was dug, to place as any mesh.
@(private)
terrain_surface_mesh :: proc(s:^editor.Session,tool:^Terrain_Tool,assets:^host.Assets,allocator:runtime.Allocator) {
    stroke:=&tool.stroke
    if stroke.active || stroke.id=={} || stroke.source.kind!=.Volume {return}
    surface:geom.Mesh_Buffer
    geom.mesh_buffer_init(&surface,allocator);defer geom.mesh_buffer_destroy(&surface)
    if !terrain.source_surface(&stroke.source,&surface) {editor.notify(s,"The terrain has no surface to save as a mesh");return}
    vertices:=make([]asset.Vertex,len(surface.positions),context.temp_allocator)
    for position,i in surface.positions {
        vertices[i]={position=position,normal=mm.normal_pack(surface.normals[i]),uv=surface.uvs[i],uv1=surface.uvs[i],color=0xffffffff}
    }
    list:=make([dynamic]asset.Vertex,context.temp_allocator)
    append(&list,..vertices)
    if !asset.mesh_tangents(&list,surface.indices[:]) {editor.notify(s,"There is not enough memory for the mesh");return}
    own,_:=terrain.terrain_file(assets,stroke.id)
    label,path:=editor.asset_new_file(s,filepath.dir(own),filepath.stem(own),".mesh",false)
    seed:=base.hash_combine(base.name_hash(path),platform.clock_ns())
    slots:=[1]asset.Material_Slot{{id=0,material=stroke.source.layers[0].material}}
    desc:=asset.Mesh_Desc{id={seed,base.hash_combine(seed,base.name_hash("Mesh"))},slots=slots[:]}
    if !asset.mesh_build_dag({vertices=list[:]},surface.indices[:],&desc.geometry,context.temp_allocator) {editor.notify(s,"The mesh could not be made");return}
    document:asset.Document
    if asset.mesh_document(&document,&assets.types,desc,allocator)!=.None {editor.notify(s,"The mesh could not be written");return}
    defer asset.document_destroy(&document)
    bytes,error:=asset.document_bytes(&document,allocator)
    if error!=.None {editor.notify(s,"The mesh could not be written");return}
    defer delete(bytes,allocator)
    if !editor.file_write(s,path,bytes,"Save terrain surface as mesh") {editor.notify(s,"The mesh could not be written");return}
    editor.notify(s,fmt.tprintf("%s holds the surface of the terrain",label))
}

// Joins a closed mesh of the scene to the Volume being edited, or takes it
// out of it, as samples (terrain.source_volume_mesh), and takes the entity of
// the mesh away in the same step of undo.
@(private)
terrain_operand :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator) {
    stroke:=&tool.stroke
    if stroke.active || stroke.id=={} || stroke.source.kind!=.Volume {return}
    if !history.selection_has(s.selection,stroke.entity) {editor.notify(s,"Select the terrain and a closed mesh operand");return}
    meshes:=core.world_table_of(world,erender.Mesh_Renderer);worlds:=core.world_table_of(world,core.World_Transform)
    if meshes==nil || worlds==nil {return}
    operand:=core.NONE
    for e in s.selection.entities {if e!=stroke.entity && core.has(meshes,e) {operand=e}}
    static,found:=core.get(meshes,operand)
    placed,positioned:=core.get(worlds,operand)
    if !found || !positioned {editor.notify(s,"Select the terrain and a closed mesh operand");return}
    if editor.prefab_member_locked(s,world,operand) {editor.notify(s,"Unpack the mesh operand before applying it");return}
    if terrains:=core.world_table_of(world,terrain.Terrain);terrains!=nil && core.has(terrains,operand) {editor.notify(s,"The operand must be a static mesh");return}
    if parents:=core.world_table_of(world,core.Parent);parents!=nil {
        for parent in parents.values {if parent.entity==operand {editor.notify(s,"The mesh operand must have no children");return}}
    }
    geometry:geom.Mesh_Buffer
    geom.mesh_buffer_init(&geometry,allocator);defer geom.mesh_buffer_destroy(&geometry)
    if !host.assets_geometry(assets,static.mesh,static.shape,&geometry,true) {editor.notify(s,"The selected mesh could not be read");return}
    transform:=stroke.to_local*mm.transform_matrix(placed.transform)
    for &p in geometry.positions {p=(transform*[4]f32{p.x,p.y,p.z,1}).xyz}
    if !geom.mesh_is_closed(geometry.positions[:],geometry.indices[:]) {editor.notify(s,"The mesh operand is not closed: it has no inside to add or carve; close its holes first");return}
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return}
    brush:=terrain.Brush{kind=tool.brush,amount=1,layer=u32(tool.layer),blend=max(tool.blend,0)/stroke.scale}
    change:=terrain.source_volume_mesh(&stroke.source,geom.mesh_buffer_view(&geometry),brush)
    if change.error!=.None {edit_error(s,change.error,brush.kind);return}
    stroke_changed(stroke,change)
    stroke_end(s,tool,world,assets,consume=operand,label="Shape terrain")
}

// The outline of the terrain Create makes, where it makes it: around the
// target of the view, on its ground.
@(private)
create_outline_draw :: proc(s:^editor.Session,tool:^Terrain_Tool) {
    if tool.create_kind!=.Volume && tool.create_source!=.Plane {return}
    half:=f32(max(tool.samples,2)-1)*tool.cell*0.5
    at:=s.viewport.orbit.target
    corners:=[4][3]f32{{at.x-half,0,at.z-half},{at.x+half,0,at.z-half},{at.x+half,0,at.z+half},{at.x-half,0,at.z+half}}
    // Each side in parts, so a side that runs behind the eye still shows what is in front.
    PARTS :: 16
    for i in 0..<4 {
        a,b:=corners[i],corners[(i+1)%4]
        for k in 0..<PARTS {
            from,from_seen:=editor.viewport_screen(s.viewport,a+(b-a)*(f32(k)/PARTS))
            to,to_seen:=editor.viewport_screen(s.viewport,a+(b-a)*(f32(k+1)/PARTS))
            if from_seen && to_seen {
                ui.draw_line(s.gui.ctx,from,to,4,CURSOR_OUTLINE)
                ui.draw_line(s.gui.ctx,from,to,2,CURSOR_ADD)
            }
        }
    }
}
