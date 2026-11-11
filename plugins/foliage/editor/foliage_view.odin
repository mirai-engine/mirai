package foliage_editor

import "core:strings"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import foliage "plugins:foliage/runtime"
import mm "mirai:std/math"
import "mirai:ui"

// The mode of inspection Foliage cells of the viewport, in Advanced →
// Foliage: the outline of each cell of every Foliage near the view, at the
// height of its ground, green where its generator places the types and yellow
// where it holds manual instances only.

VIEW_CELLS :: "foliage_cells"
VIEW_REACH :: f32(512) // metres from the view within which the cells are drawn

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
foliage_cells_view :: proc(s:^editor.Session,view:^Foliage_View,foliages:core.Read(foliage.Foliage),worlds:core.Read(core.World_Transform),grounds:core.Ref(foliage.Foliage_Ground),data:core.Ref(foliage.Foliage_Data),input:core.Input) {
    if !view.cells || !s.gui.begun || editor.playing(s) || data.ptr==nil {return}
    eye:=s.viewport.orbit.target
    for row in 0..<core.count(foliages) {
        marker:=core.at(foliages,row)
        e:=core.entity_at(foliages,row)
        placed,known:=core.get(worlds,e)
        entry:=foliage.data_find(data.ptr,marker.source)
        if !known || entry==nil {continue}
        to_local,inverted:=mm.transform_inverse_matrix(placed.transform)
        if !inverted {continue}
        near:=mm.mat4_point(to_local,eye)
        ground:=foliage.ground_owner(grounds.ptr,e)
        for &cell in entry.source.cells {
            corner:=foliage.cell_corner(cell.coord)
            middle:=corner.xz+foliage.CELL_SIZE*0.5
            d:=middle-near.xz
            if d.x*d.x+d.y*d.y>VIEW_REACH*VIEW_REACH {continue}
            if !cell.generate && len(cell.manual)==0 {continue}
            height:=f32(0)
            if h,_,ok:=foliage.ground_at(ground_of(ground,cell.coord),foliage.CELL_SIZE*0.5,foliage.CELL_SIZE*0.5);ok {height=h}
            cell_outline_draw(s,placed.transform,cell.coord,height,cell.generate?editor.BRUSH_GENERATED:editor.BRUSH_ADD)
        }
    }
}
