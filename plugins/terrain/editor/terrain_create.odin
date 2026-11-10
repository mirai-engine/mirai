package terrain_editor

import "core:fmt"
import "core:math/linalg"
import "core:path/filepath"
import "mirai:asset"
import "mirai:core"
import "mirai:cook/textures"
import "mirai:editor"
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
    switch kind {case .Heightfield:return "Heightfield Terrain";case .Mesh:return "3D Terrain";case .Volume:return "Volumetric Terrain"}
    return "Terrain"
}

@(private)
terrain_creation_panel :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App) {
    ctx:=s.gui.ctx
    kinds:=[3]terrain.Source_Kind{.Heightfield,.Mesh,.Volume}
    kind:=tool.create_kind==.Heightfield?0:tool.create_kind==.Mesh?1:2
    if ui.dropdown(ctx,ui.id(ctx,"source_kind"),{"Heightfield Terrain","3D Terrain","Volumetric Terrain"},&kind,{width=-1,height=ctx.theme.row}) {tool.create_kind=kinds[kind]}
    if tool.create_kind!=.Volume {
        if tool.create_kind==.Heightfield && tool.create_source==.Selection {tool.create_source=.Plane}
        source:=int(tool.create_source)
        labels:=tool.create_kind==.Mesh?[]string{"Plane","Heightmap","Selection"}:[]string{"Plane","Heightmap"}
        if ui.tabs(ctx,ui.id(ctx,"create_source"),labels,&source) {tool.create_source=Create_Source(source)}
    }
    heightmap:=tool.create_kind!=.Volume && tool.create_source==.Heightmap
    selection:=tool.create_kind==.Mesh && tool.create_source==.Selection
    samples,depth,cell,chunk:=f64(tool.samples),f64(tool.depth),f64(tool.cell),f64(tool.chunk_cells)
    maximum:=tool.create_kind==.Volume?f64(terrain.VOLUME_SAMPLES_MAX):tool.create_kind==.Mesh?f64(terrain.MESH_SAMPLES_MAX):f64(terrain.HEIGHT_SAMPLES_MAX)
    tool.samples=min(tool.samples,int(maximum));samples=f64(tool.samples)
    if !heightmap && !selection {
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
    if !heightmap && !selection {
        side:=f32(max(tool.samples,2)-1)*tool.cell
        chunks:=(max(tool.samples,2)-1+max(tool.chunk_cells,1)-1)/max(tool.chunk_cells,1)
        size:=fmt.tprintf("%.0f × %.0f m, %d × %d chunks",side,side,chunks,chunks)
        if tool.create_kind==.Volume {size=fmt.tprintf("%.0f × %.0f × %.0f m",side,f32(max(tool.depth,2)-1)*tool.cell,side)}
        if ui.property(ctx,"Size") {ui.label(ctx,size,ctx.theme.font,ctx.theme.text_muted)}
    }
    if tool.create_kind==.Mesh && !selection {
        solid:=f64(tool.solid_depth)
        if ui.property(ctx,"Base depth") {if ui.number_field(ctx,ui.id(ctx,"create_solid"),&solid,{min=0,max=10000,has_min=true,has_max=true,speed=0.1}).changed {tool.solid_depth=f32(solid)}}
    }
    if ui.button(ctx,ui.id(ctx,"create"),{label=selection?"Convert selected mesh":"New terrain",style=.Field,width=-1,center=true}).clicked {terrain_create(s,tool,world,app.assets,app.allocator)}
}

@(private)
terrain_create :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,at:=[3]f32{},placed:=false,ground:=core.NONE,name:="") -> (made:core.Entity) {
    a:=assets;terrains:=core.world_table_of(world,terrain.Terrain);meshes:=core.world_table_of(world,erender.Mesh_Renderer)
    if a==nil || terrains==nil || meshes==nil {editor.notify(s,"The project has no terrain library");return}
    source:terrain.Source
    defer terrain.source_destroy(&source)
    converted:=core.NONE
    over:Ground_Placement
    if ground!=core.NONE {
        if tool.create_kind!=.Volume {editor.notify(s,"Only a Volume joins a Heightfield");return}
        ok:bool
        if over,ok=volume_over_ground(s,world,assets,allocator,ground,at,placed,tool,&source);!ok {return}
    } else if tool.create_kind==.Heightfield && tool.create_source==.Selection {
        editor.notify(s,"Heightfield Terrain requires a plane or heightmap");return
    } else if tool.create_kind==.Mesh && tool.create_source==.Selection {
        converted=editor.selection_active(s.selection)
        static,found:=core.get(core.read(meshes),converted)
        if !found || core.has(core.read(terrains),converted) {editor.notify(s,"Select a static mesh to convert");return}
        if bodies:=core.world_table_of(world,phys.Rigid_Body);bodies!=nil {
            if body,ok:=core.get(core.read(bodies),converted);ok && body.type!=.Static {editor.notify(s,"Terrain requires a static entity");return}
        }
        geometry:geom.Mesh_Buffer
        geom.mesh_buffer_init(&geometry,allocator);defer geom.mesh_buffer_destroy(&geometry)
        if !host.assets_geometry(a,static.mesh,static.shape,&geometry,true) {editor.notify(s,"The selected mesh could not be read");return}
        // The materials it shows, its own over those of its mesh, are those of the source.
        held:=static.mesh!={}?host.assets_mesh(a,static.mesh):host.assets_shape(a,static.shape)
        slots:[asset.MESH_MAX_SLOTS]base.Asset_Id
        count:=0
        if held!=nil {count=copy(slots[:],held.slot_materials[:held.slot_count])}
        for material,i in static.materials {if material!={} {slots[i]=material;count=max(count,i+1)}}
        if !terrain.source_from_mesh(&source,geom.mesh_buffer_view(&geometry),tool.cell,tool.chunk_cells,slots[:count],allocator) {editor.notify(s,"The selected mesh exceeds the terrain budget");return}
    } else if tool.create_kind!=.Volume && tool.create_source==.Heightmap {
        path:=string(tool.heightmap_path[:tool.heightmap_length])
        bytes,error:=serial.file_read(path,allocator,limit=64*1024*1024)
        if error!=.None {editor.notify(s,fmt.tprintf("The heightmap %s could not be read: %v",path,error));return}
        defer delete(bytes,allocator)
        heightmap,decode:=textures.heightmap_decode(bytes,tool.create_kind==.Mesh?terrain.MESH_SAMPLES_MAX:terrain.HEIGHT_SAMPLES_MAX,allocator)
        if decode!=.None {editor.notify(s,fmt.tprintf("Heightmap: %v",decode));return}
        defer textures.heightmap_destroy(&heightmap)
        if !terrain.source_make(&source,.Heightfield,{heightmap.width,1,heightmap.height},tool.cell,tool.chunk_cells,allocator) {editor.notify(s,"The heightmap dimensions exceed their budget");return}
        if !terrain.grid_prepare(&source.heights,{0,0,0},{heightmap.width-1,0,heightmap.height-1},source.allocator) {editor.notify(s,"There is not enough memory for the heightmap");return}
        for value,i in heightmap.values {
            height:=value*tool.height_scale+tool.height_offset
            if abs(height)>terrain.HEIGHT_LIMIT {editor.notify(s,"Heightmap heights exceed the terrain limit");return}
            terrain.grid_set(&source.heights,i%heightmap.width,i/heightmap.width,height)
        }
    } else {
        samples:=[3]int{tool.samples,tool.create_kind==.Volume?tool.depth:1,tool.samples}
        if !terrain.source_make(&source,tool.create_kind==.Volume?.Volume:.Heightfield,samples,tool.cell,tool.chunk_cells,allocator) {editor.notify(s,"The terrain dimensions exceed their budget");return}
    }
    if tool.create_kind==.Mesh && source.kind==.Heightfield {
        mesh:terrain.Source
        defer terrain.source_destroy(&mesh)
        if !terrain.source_convert_heightfield(&mesh,&source,tool.solid_depth,allocator) {editor.notify(s,"The terrain could not be converted");return}
        source,mesh=mesh,source
    }
    if !terrain_budget(s,world,&source) {return}
    label,path:=editor.asset_new_file(s,fmt.tprintf("%s/terrain",a.registry.root),name!=""?name:terrain_kind_name(source.kind),terrain.EXTENSION,name!="")
    source.revision=1;seed:=base.hash_combine(base.name_hash(path),platform.clock_ns())
    id:=base.Asset_Id{seed,base.hash_combine(seed,base.name_hash("Terrain"))}
    bytes,error:=terrain.source_bytes(&source,id,&a.types,allocator)
    if error!=.None {editor.notify(s,"The terrain could not be written");return}
    defer delete(bytes,allocator)
    // The new file is part of the step: undo takes it away, and it stays in
    // the memory of the registry until it is saved.
    editor.edits_begin(s.edits,editor.document_selection(s),converted!=core.NONE?"Convert to terrain":"Add terrain")
    if !editor.file_write(s,path,bytes,"Add terrain") {editor.edits_cancel(s.edits,world);editor.notify(s,"The terrain could not be written");return}
    e:=converted
    if e==core.NONE {
        position:=placed?at:[3]f32{s.viewport.orbit.target.x,0,s.viewport.orbit.target.z}
        transform:=core.Transform{position=position,rotation=1,scale={1,1,1}}
        if ground!=core.NONE {transform=over.transform}
        e=editor.entity_create(s,{preset=.Empty,name=label,transform=transform})
    } else {
        if colliders:=core.world_table_of(world,phys.Collider);colliders!=nil {core.remove(colliders,e)}
        if bodies:=core.world_table_of(world,phys.Rigid_Body);bodies!=nil {core.remove(bodies,e)}
        core.remove(meshes,e)
    }
    core.add(terrains,e,terrain.Terrain{source=id,revision=1,solid=true,ground=over.id})
    editor.edits_end(s.edits);editor.selection_set(editor.document_selection(s),{e})
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
    marker,is:=core.get(core.read(terrains),ground)
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
    middle:=terrain.grid_get(&g.heights,offset.x+(n.x-1)/2,offset.y+(n.y-1)/2)
    lift:=middle-f32(tool.depth-1)*0.5*g.cell
    if !terrain.source_volume_ground(source,{ground=&g,offset=offset,lift=lift}) {editor.notify(s,"There is not enough memory for the Volume");return}
    corner:=origin+[3]f32{f32(offset.x)*g.cell,lift,f32(offset.y)*g.cell}
    over.transform=core.Transform(place)
    over.transform.position=mm.transform_point(place,corner-terrain.source_point(source,{}))
    return over,true
}

@(private)
edit_error :: proc(s:^editor.Session,error:terrain.Edit_Error) {
    switch error {
    case .None:
    case .Invalid:editor.notify(s,"The terrain operation is invalid")
    case .Not_Closed:editor.notify(s,"Boolean operations require closed solid meshes")
    case .Out_Of_Memory:editor.notify(s,"There is not enough memory for the terrain operation")
    case .Budget:editor.notify(s,"The terrain operation exceeds its geometry budget")
    case .Topology:editor.notify(s,"The Boolean result is not a valid closed surface")
    }
}

@(private)
terrain_convert :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator) {
    stroke:=&tool.stroke
    if stroke.active || stroke.id=={} || stroke.source.kind==.Mesh {return}
    if !editor.selection_has(s.selection,stroke.entity) {editor.notify(s,"Select the terrain to convert");return}
    source:terrain.Source
    defer terrain.source_destroy(&source)
    if stroke.source.kind==.Volume {
        if !terrain.source_convert_volume(&source,&stroke.source,allocator) {editor.notify(s,"The terrain could not be converted: it has no surface, or more triangles than a 3D Terrain holds");return}
    } else if tool.solid_depth>0 && len(stroke.source.holes.pages)>0 {
        for z in 0..<stroke.source.holes.size.z {for x in 0..<stroke.source.holes.size.x {
            if terrain.source_hole(&stroke.source,x,z) {editor.notify(s,"Fill the holes of the terrain before converting it to a solid mesh");return}
        }}
    }
    if stroke.source.kind==.Heightfield && !terrain.source_convert_heightfield(&source,&stroke.source,tool.solid_depth,allocator) {editor.notify(s,"The terrain could not be converted");return}
    if !terrain_budget(s,world,&source,stroke.id) {return}
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return}
    // A swap by single stores until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    previous:=stroke.source
    stroke.source=source
    source=previous
    stroke.changed=true;stroke.dirty_all=true
    stroke_end(s,tool,world,assets,label="Convert terrain")
}

@(private)
terrain_operand :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator) {
    stroke:=&tool.stroke
    if stroke.active || stroke.id=={} || stroke.source.kind!=.Mesh {return}
    if !editor.selection_has(s.selection,stroke.entity) {editor.notify(s,"Select the terrain and a closed mesh operand");return}
    meshes:=core.world_table_of(world,erender.Mesh_Renderer);worlds:=core.world_table_of(world,core.World_Transform)
    if meshes==nil || worlds==nil {return}
    operand:=core.NONE
    for e in s.selection.entities {if e!=stroke.entity && core.has(core.read(meshes),e) {operand=e}}
    static,found:=core.get(core.read(meshes),operand)
    placed,positioned:=core.get(core.read(worlds),operand)
    if !found || !positioned {editor.notify(s,"Select the terrain and a closed mesh operand");return}
    if editor.prefab_member_locked(s,world,operand) {editor.notify(s,"Unpack the mesh operand before applying it");return}
    if terrains:=core.world_table_of(world,terrain.Terrain);terrains!=nil && core.has(core.read(terrains),operand) {editor.notify(s,"The operand must be a static mesh");return}
    if parents:=core.world_table_of(world,core.Parent);parents!=nil {
        for parent in parents.values {if parent.entity==operand {editor.notify(s,"The mesh operand must have no children");return}}
    }
    geometry:geom.Mesh_Buffer
    geom.mesh_buffer_init(&geometry,allocator);defer geom.mesh_buffer_destroy(&geometry)
    if !host.assets_geometry(assets,static.mesh,static.shape,&geometry,true) {editor.notify(s,"The selected mesh could not be read");return}
    transform:=stroke.to_local*mm.transform_matrix(placed.transform)
    normals:=linalg.transpose(linalg.inverse(transform))
    for &p in geometry.positions {p=(transform*[4]f32{p.x,p.y,p.z,1}).xyz}
    for &n in geometry.normals {n=linalg.normalize0((normals*[4]f32{n.x,n.y,n.z,0}).xyz)}
    if linalg.determinant(transform)<0 {for face in 0..<len(geometry.indices)/3 {a,b:=face*3+1,face*3+2;geometry.indices[a],geometry.indices[b]=geometry.indices[b],geometry.indices[a]}}
    // A material of the operand that the first layer shows joins slot 0.
    slots:[asset.MESH_MAX_SLOTS]base.Asset_Id
    slots[0]=stroke.source.layers[0].material
    count:=1+copy(slots[1:],stroke.source.slots)
    if tool.brush==.Union {
        held:=static.mesh!={}?host.assets_mesh(assets,static.mesh):host.assets_shape(assets,static.shape)
        remap:[asset.MESH_MAX_SLOTS]u32
        mapped:[asset.MESH_MAX_SLOTS]bool
        for &slot in geometry.materials {
            if slot>=u32(len(remap)) {editor.notify(s,"The operand has an invalid material slot");return}
            i:=int(slot)
            if mapped[i] {slot=remap[i];continue}
            material:base.Asset_Id
            if held!=nil && i<int(held.slot_count) {material=held.slot_materials[i]}
            if i<len(static.materials) && static.materials[i]!={} {material=static.materials[i]}
            existing:= -1
            for value,j in slots[:count] {if value==material {existing=j;break}}
            if existing<0 {
                if count==len(slots) {editor.notify(s,"The union exceeds the material slot budget");return}
                existing=count;slots[count]=material;count+=1
            }
            remap[i]=u32(existing);mapped[i]=true;slot=remap[i]
        }
    } else {for &slot in geometry.materials {slot=0}}
    source_allocator:=stroke.source.allocator
    materials,error:=make([]base.Asset_Id,count-1,source_allocator)
    if error!=nil {editor.notify(s,"The terrain materials could not be stored");return}
    defer delete(materials,source_allocator)
    copy(materials,slots[1:count])
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return}
    stroke.source.slots,materials=materials,stroke.source.slots
    change:=terrain.source_mesh_boolean(&stroke.source,geom.mesh_buffer_view(&geometry),tool.brush==.Union?.Union:.Subtract,terrain_vertex_budget(world,stroke.id))
    if change.error!=.None || !change.changed {stroke.source.slots,materials=materials,stroke.source.slots}
    if change.error!=.None {edit_error(s,change.error);return}
    stroke.changed,stroke.dirty_all=change.changed,true
    stroke_end(s,tool,world,assets,consume=operand,label="Boolean terrain")
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
