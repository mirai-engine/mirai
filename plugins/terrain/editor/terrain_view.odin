package terrain_editor

import "core:strings"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// The modes of inspection of terrains of the viewport, in Advanced → Terrain.
// Contour lines and Slope are the overlays of Terrain3D: over every surface
// of the view, terrain or not, so that they also say whether a ramp or a mesh
// can be walked on. They are drawn by terrain_view.comp in the Inspect stage
// of the view that shows one; the pipeline is asked for only while one is
// shown. Layer weights and Selected layer show the weights of the layers of
// each terrain that has them, rules included, with the material
// Terrain_Weights in place of the one of its chunks; Chunks and levels draws
// the outline of each piece in the color of the level it shows, a node
// thicker.

// Must match TERRAIN_VIEW_* of terrain_view.comp.slang, which also has
// TERRAIN_VIEW_EXPOSED: the image of Lit alone, under an overlay.
Terrain_View_Mode :: enum u32 {Contours, Contours_Height, Slope}
VIEW_EXPOSED :: u32(3)
Terrain_Overlay :: enum u8 {None, Layers, Layer, Chunks}

@(private,rodata)
TERRAIN_VIEW_MODES := [Terrain_View_Mode]struct{name,label,title:string,icon:ui.Icon}{
    .Contours={"contours","Contour lines","Terrain: Contour lines",.Layers},
    .Contours_Height={"contours_height","Contours by height","Terrain: Contours by height",.Palette},
    .Slope={"slope","Slope","Terrain: Slope",.Gauge},
}
@(private,rodata)
TERRAIN_OVERLAYS := [Terrain_Overlay]struct{name,label,title:string,icon:ui.Icon}{
    .None={},
    .Layers={"layer_weights","Layer weights","Terrain: Layer weights",.Palette},
    .Layer={"selected_layer","Selected layer","Terrain: Selected layer",.Layers},
    .Chunks={"chunks","Chunks and levels","Terrain: Chunks and levels",.Grid},
}
// The color of the level a piece shows, a cycle of six.
@(private,rodata)
LEVEL_COLORS := [6]ui.Color{{255,217,51,255},{98,168,255,255},{120,220,120,255},{240,120,90,255},{200,130,255,255},{90,220,220,255}}

// The material Layer weights and Selected layer show (plugins/terrain/assets).
WEIGHTS_MATERIAL :: base.Asset_Id{0x7465727261696e5f,0x7765696768740001}

@(storage)
Terrain_View :: struct {
    pipeline:erender.Pipeline, // of this frame while one of the modes is shown; 0 otherwise
    mode:Terrain_View_Mode,    // the one shown
    overlay:Terrain_Overlay,   // the one shown; None while none is
}

@(private)
Terrain_View_Params :: struct {mode:u32,_:[3]u32}

@(step="frame")
terrain_view_modes :: proc(s:^editor.Session,view:^Terrain_View,renderer:^erender.Renderer) {
    view.pipeline=0
    view.overlay=.None
    current:=editor.view_mode_current(s.viewport)
    shown:=false
    if s.mode!=.Play && !editor.document_is_prefab(s) {
        for desc,mode in TERRAIN_VIEW_MODES {
            if strings.equal_fold(current,desc.name) {view.mode,shown=mode,true}
        }
        for desc,overlay in TERRAIN_OVERLAYS {
            if overlay!=.None && strings.equal_fold(current,desc.name) {view.overlay=overlay}
        }
    }
    reason:=""
    if shown || view.overlay!=.None {
        view.pipeline=erender.stage_pipeline(renderer,{stage=.Inspect,shader="terrain_view",name="terrain view"})
        if view.pipeline==0 {reason="The shaders in use have no terrain_view.comp: generate those of the project"}
    }
    for desc,mode in TERRAIN_VIEW_MODES {
        editor.view_mode_declare(s,{
            name=desc.name,label=desc.label,title=desc.title,
            group="Advanced",submenu="Terrain",icon=desc.icon,reason=reason if mode==view.mode else "",
            record=terrain_view_record,user=view,
        })
    }
    for desc,overlay in TERRAIN_OVERLAYS {
        if overlay==.None {continue}
        editor.view_mode_declare(s,{name=desc.name,label=desc.label,title=desc.title,group="Advanced",submenu="Terrain",icon=desc.icon,record=terrain_view_lit,user=view})
    }
}

@(private)
terrain_view_record :: proc(pass:^erender.Pass,user:rawptr) {
    view:=cast(^Terrain_View)user
    if view.pipeline==0 {return}
    erender.pass_pipeline(pass,view.pipeline)
    if !erender.pass_image_bind(pass,0) {return}
    erender.pass_surface_read(pass,1,.Linear_Depth)
    erender.pass_surface_read(pass,2,.Normal)
    params:=Terrain_View_Params{mode=u32(view.mode)}
    if !erender.pass_params(pass,&params,size_of(params)) {return}
    erender.pass_dispatch(pass,(pass.width+7)/8,(pass.height+7)/8)
}

// The overlays draw over the image of Lit, which the stage only exposes as Lit does.
@(private)
terrain_view_lit :: proc(pass:^erender.Pass,user:rawptr) {
    view:=cast(^Terrain_View)user
    if view.pipeline==0 {return}
    erender.pass_pipeline(pass,view.pipeline)
    if !erender.pass_image_bind(pass,0) {return}
    erender.pass_surface_read(pass,1,.Linear_Depth)
    erender.pass_surface_read(pass,2,.Normal)
    params:=Terrain_View_Params{mode=VIEW_EXPOSED}
    if !erender.pass_params(pass,&params,size_of(params)) {return}
    erender.pass_dispatch(pass,(pass.width+7)/8,(pass.height+7)/8)
}

// What Terrain_Weights takes for an overlay: a color for each layer, or the
// layer of the panel alone.
@(private)
weights_values :: proc(look:^erender.Material_Values,overlay:Terrain_Overlay,layer:int) {
    erender.material_value(look,"inspect",{overlay==.Layer?2:1,f32(layer),0,0})
}

@(private)
overlay_weights :: proc "contextless" (overlay:Terrain_Overlay) -> bool {return overlay==.Layers || overlay==.Layer}

// What the overlays of the view show of the terrains of the scene: the
// chunks of those with layers with the material of the weights, in place of
// theirs, or the outlines of every piece. A chunk the preview of a stroke
// shows is the preview's.
@(step="frame",after="terrain_sculpt")
terrain_overlay :: proc(s:^editor.Session,view:^Terrain_View,tool:^Terrain_Tool,world:core.World_Ref,terrains:core.Read(terrain.Terrain),chunks:core.Read(terrain.Terrain_Chunk),worlds:core.Read(core.World_Transform),data:core.Ref(terrain.Terrain_Data),assets:^host.Assets,extras:^host.Frame_Extras) {
    if view.overlay==.None || !s.gui.begun || editor.playing(s) || data.ptr==nil {return}
    a:=assets
    if a==nil {return}
    statics:=core.world_table_of(world,erender.Mesh_Renderer)
    looks:=core.world_table_of(world,erender.Material_Values)
    if statics==nil {return}
    for row in 0..<core.count(chunks) {
        chunk:=core.at(chunks,row)
        owner,known:=core.get(terrains,chunk.owner)
        if !known {continue}
        source:=terrain.terrain_source(data,owner.source)
        if source==nil {continue}
        e:=core.entity_at(chunks,row)
        placed,has_pose:=core.get(worlds,e)
        if !has_pose || editor.entity_hidden(world,e) {continue}
        if view.overlay==.Chunks {
            chunk_outline_draw(s,source,chunk,placed.transform)
            continue
        }
        if tool.stroke.active && owner.source==tool.stroke.id && chunk.depth==0 {
            if at:=preview_find(&tool.stroke,chunk.coord);at>=0 && tool.stroke.previews[at].ready {continue}
        }
        static,has_static:=core.get(core.read(statics),e)
        if !has_static || static.mesh=={} {continue}
        static.materials[0]=WEIGHTS_MATERIAL
        look:=erender.MATERIAL_VALUES_DEFAULT
        if looks!=nil {if value,ok:=core.get(core.read(looks),e);ok {look.color,look.emission=value.color,value.emission}}
        weights_values(&look,view.overlay,tool.layer)
        if instance,ok:=erender.mesh_instance(a,static,mm.transform_matrix(placed.transform),look);ok {
            instance.object_id,instance.copy_owner,instance.copy_variant=u64(e),PREVIEW_OWNER,2
            instance.replace_source=true
            host.extras_instance_add(extras,instance)
        }
    }
    host.assets_commit(a)
}

// The outline of a piece on its ground, in the space of its entity: a
// chunk, or a node over 2^depth chunks a side, in the color of its level.
@(private)
chunk_outline_draw :: proc(s:^editor.Session,source:^terrain.Source,chunk:terrain.Terrain_Chunk,placed:mm.Transform) {
    span:=i32(1)<<chunk.depth
    first,_,ok:=terrain.chunk_region(source,chunk.coord)
    if !ok {return}
    counts:=terrain.chunk_counts(source)
    last_coord:=chunk.coord+{span-1,0,span-1}
    last_coord.x,last_coord.z=min(last_coord.x,i32(counts.x-1)),min(last_coord.z,i32(counts.z-1))
    _,last,last_ok:=terrain.chunk_region(source,last_coord)
    if !last_ok {return}
    // The chunk entity stands at the corner of its first chunk.
    corner:=terrain.source_origin(source)+[3]f32{f32(first.x),f32(first.y),f32(first.z)}*source.cell
    size:=[3]f32{f32(last.x-first.x),0,f32(last.z-first.z)}*source.cell
    // Inside the piece by a part of a cell, so neighbors do not draw over each other.
    inset:=source.cell*0.15
    low,high:=[2]f32{inset,inset},[2]f32{size.x-inset,size.z-inset}
    flat:=f32(0)
    if source.kind==.Mesh {
        if index:=terrain.chunk_index(source,chunk.coord);index>=0 && index<len(source.mesh_chunks) {flat=(source.mesh_chunks[index].low.y+source.mesh_chunks[index].high.y)*0.5-corner.y}
    }
    color:=LEVEL_COLORS[int(chunk.lod.level)%len(LEVEL_COLORS)]
    width:=chunk.depth>0?f32(3):f32(1.5)
    corners:=[4][2]f32{{low.x,low.y},{high.x,low.y},{high.x,high.y},{low.x,high.y}}
    PARTS :: 8
    to_world:=mm.transform_matrix(placed)
    at :: proc(s:^terrain.Source,corner:[3]f32,p:[2]f32,flat:f32) -> ([3]f32,bool) {
        if s.kind!=.Heightfield {return {p.x,flat,p.y},true}
        h,ok:=terrain.source_height_held(s,corner.x+p.x,corner.z+p.y)
        return {p.x,h-corner.y,p.y},ok
    }
    for i in 0..<4 {
        a,b:=corners[i],corners[(i+1)%4]
        for k in 0..<PARTS {
            from,from_ok:=at(source,corner,a+(b-a)*(f32(k)/PARTS),flat)
            to,to_ok:=at(source,corner,a+(b-a)*(f32(k+1)/PARTS),flat)
            if !from_ok || !to_ok {continue}
            p0,s0:=editor.viewport_screen(s.viewport,(to_world*[4]f32{from.x,from.y,from.z,1}).xyz)
            p1,s1:=editor.viewport_screen(s.viewport,(to_world*[4]f32{to.x,to.y,to.z,1}).xyz)
            if s0 && s1 {ui.draw_line(s.gui.ctx,p0,p1,width,color)}
        }
    }
}
