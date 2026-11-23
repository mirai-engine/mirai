package foliage_editor

import "core:strings"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import mm "mirai:std/math"
import "mirai:ui"
import foliage "plugins:foliage/runtime"
import pcg "plugins:pcg/runtime"

// The editor of the foliage is what a Foliage draws of its graph, seen and
// asked: what it places and where is the .pcg of the graph (plugins/pcg),
// and an instance is taken out or promoted to an entity through the graph
// (pcg.Pcg_Suppressed, foliage.foliage_promote), so the foliage has no tool
// of its own. The mode of inspection Foliage cells of the viewport, in
// Advanced -> Foliage: the outline of each cell the graph of a Foliage near
// the view generated, at the mean height of its instances: green where it
// places, grey where it places nothing.

VIEW_CELLS :: "foliage_cells"
VIEW_REACH :: f32(512) // metres from the view within which the cells are drawn
CELL_EMPTY :: ui.Color{150,150,150,160}

@(storage)
Foliage_View :: struct {cells:bool}

@(step="frame")
foliage_view_modes :: proc(s:^editor.Session,view:^Foliage_View) {
    view.cells=s.mode!=.Play && strings.equal_fold(editor.view_mode_current(s.viewport),VIEW_CELLS)
    editor.view_mode_declare(s,{name=VIEW_CELLS,label="Foliage cells",title="Foliage: cells",group="Advanced",submenu="Foliage",icon=.Grid,record=foliage_view_lit,user=view})
}

// The outlines draw over the image of Lit: the stage has nothing to add.
@(private)
foliage_view_lit :: proc(pass:^erender.Pass,user:rawptr) {}

@(step="frame")
foliage_cells_view :: proc(s:^editor.Session,view:^Foliage_View,foliages:^core.Table(foliage.Foliage,.Read),graphs:^core.Table(pcg.Pcg_Graph,.Read),worlds:^core.Table(core.World_Transform,.Read),data:core.Ref(pcg.Pcg_Data),input:core.Input) {
    if !view.cells || !s.gui.begun || editor.playing(s) || data.ptr==nil {return}
    generated:=host.app_world_storage(s.app,s.edit_world,pcg.Pcg_Generated)
    eye:=s.viewport.orbit.target
    for row in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,row)
        graph,graphed:=core.get(graphs,e)
        placed,known:=core.get(worlds,e)
        entry:=pcg.data_find(data.ptr,graph.source) if graphed else nil
        gen:=pcg.generated_graph(generated,e)
        if !known || entry==nil || gen==nil {continue}
        frame:=pcg.graph_frame(graph,placed.transform)
        to_local,inverted:=mm.transform_inverse_matrix(frame)
        if !inverted {continue}
        near:=mm.mat4_point(to_local,eye)
        size:=entry.source.info.cell_size
        for &cell in gen.cells {
            if !cell.built {continue}
            corner:=pcg.cell_corner(size,cell.coord)
            d:=corner.xz+size*0.5-near.xz
            if d.x*d.x+d.y*d.y>VIEW_REACH*VIEW_REACH {continue}
            height:=f32(0)
            for p in cell.placed {height+=p.position.y}
            if len(cell.placed)>0 {height/=f32(len(cell.placed))}
            cell_outline_draw(s,frame,corner,size,height,len(cell.placed)>0?editor.BRUSH_GENERATED:CELL_EMPTY)
        }
    }
}

@(private)
cell_outline_draw :: proc(s:^editor.Session,frame:mm.Transform,corner:[3]f32,size,height:f32,color:ui.Color) {
    inset:=f32(0.2)
    side:=size-inset*2
    points:=[4][3]f32{corner+{inset,height,inset},corner+{inset+side,height,inset},corner+{inset+side,height,inset+side},corner+{inset,height,inset+side}}
    for &point in points {point=mm.transform_point(frame,point)}
    editor.brush_ring_draw(s,points[:],color,1.5)
}
