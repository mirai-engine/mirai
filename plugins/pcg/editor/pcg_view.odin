package pcg_editor

import "core:fmt"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import mm "mirai:std/math"
import "mirai:ui"
import pcg "plugins:pcg/runtime"

// The inspection mode PCG of the viewport, in Advanced → PCG, over the image
// of Lit: the cells each Pcg_Graph wants near the view at the height of their
// ground, green where they keep all of their density and yellow where a brush
// painted it (with what they keep near the view), the outline of each
// Pcg_Zone (blue where it excludes) and the boundaries of the bays a Grammar
// layer splits the spans of its splines into.

VIEW_CELLS :: "pcg_cells"
VIEW_REACH :: f32(512)  // m from the view within which cells and bays are drawn
LABEL_REACH :: f32(96)  // m from the view within which a painted cell says its density
BAY_POST :: f32(2)      // m up a bay boundary is drawn
BAY_ACROSS :: f32(0.6)  // m across

@(storage)
Pcg_View :: struct {cells:bool}

@(step="frame")
pcg_view_modes :: proc(s:^editor.Session,view:^Pcg_View) {
    view.cells=s.mode!=.Play && strings.equal_fold(editor.view_mode_current(s.viewport),VIEW_CELLS)
    editor.view_mode_declare(s,{name=VIEW_CELLS,label="PCG",title="PCG: cells, zones and bays",group="Advanced",submenu="PCG",icon=.Sparkle,record=pcg_view_lit,user=view})
}

// The outlines draw over the image of Lit: the stage has nothing to add.
@(private)
pcg_view_lit :: proc(pass:^erender.Pass,user:rawptr) {}

@(step="frame")
pcg_cells_view :: proc(s:^editor.Session,view:^Pcg_View,world:core.World_Ref,graphs:^core.Table(pcg.Pcg_Graph,.Read),zones:^core.Table(pcg.Pcg_Zone,.Read),worlds:^core.Table(core.World_Transform,.Read),grounds:core.Ref(pcg.Pcg_Ground),data:core.Ref(pcg.Pcg_Data)) {
    if !view.cells || !s.gui.begun || editor.playing(s) || data.ptr==nil {return}
    eye:=s.viewport.orbit.target
    generated:=generated_of(s,world)
    for row in 0..<core.count(graphs) {
        e:=core.entity_at(graphs,row)
        graph:=core.at(graphs,row)
        place,placed:=core.get(worlds,e)
        entry:=pcg.data_find(data.ptr,graph.source)
        owner:=pcg.ground_owner(grounds.ptr,e)
        if !placed || entry==nil || owner==nil {continue}
        frame:=pcg.graph_frame(graph,place.transform)
        source:=&entry.source
        cell:=source.info.cell_size
        for want in owner.cells {
            corner:=pcg.cell_corner(cell,want.coord)
            middle:=mm.transform_point(frame,corner+{cell*0.5,0,cell*0.5})
            d:=middle.xz-eye.xz
            if d.x*d.x+d.y*d.y>VIEW_REACH*VIEW_REACH {continue}
            ground,_:=pcg.ground_cell(owner,want.coord)
            height:=f32(0)
            if h,_,ok:=pcg.ground_at(ground,cell*0.5,cell*0.5);ok {height=h}
            painted:=pcg.source_cell(source,want.coord)
            mean:=f32(1)
            if painted!=nil && len(painted.density)>0 {
                sum:=0
                for v in painted.density {sum+=int(v)}
                mean=f32(sum)/f32(255*len(painted.density))
            }
            cell_outline(s,frame,corner,cell,height,editor.BRUSH_ADD if mean<1 else editor.BRUSH_GENERATED)
            if mean<1 && d.x*d.x+d.y*d.y<LABEL_REACH*LABEL_REACH {
                label_draw(s,mm.transform_point(frame,corner+{cell*0.5,height,cell*0.5}),fmt.tprintf("%.0f %%",mean*100))
            }
        }
        if generated!=nil {bays_draw(s,generated,e,source,frame,eye)}
    }
    at:=where_of(world)
    for row in 0..<core.count(zones) {
        e:=core.entity_at(zones,row)
        zone:=core.at(zones,row)
        color:=editor.BRUSH_TAKE if zone.exclude else editor.BRUSH_CHANGE
        if at.volumes!=nil && core.has(at.volumes,e) {
            v,pose,outline,ok:=volume.placed(at,e)
            if ok && v.shape!=.Unbounded && v.shape!=.Plane {box_draw(s,volume.bounds(v,pose,outline),color)}
        }
        if at.splines!=nil {
            spline,has:=core.get(at.splines,e)
            place,placed:=core.get(worlds,e)
            if !has || !placed {continue}
            points:=volume.spline_points(&spline)
            for i in 1..<len(points) {line_draw(s,mm.transform_point(place.transform,points[i-1].position),mm.transform_point(place.transform,points[i].position),color,2)}
        }
    }
}

// The boundary of each bay the Grammar layers of a graph place in its built
// cells near the view: a post where the module starts, across its span.
@(private)
bays_draw :: proc(s:^editor.Session,generated:^pcg.Pcg_Generated,e:core.Entity,source:^pcg.Pcg_Source,frame:mm.Transform,eye:[3]f32) {
    graph:=pcg.generated_graph(generated,e)
    if graph==nil {return}
    for &cell in graph.cells {
        if !cell.built {continue}
        for p in cell.placed {
            l,_:=pcg.source_layer(source,p.layer)
            if l==nil || l.kind!=.Grammar {continue}
            at:=mm.transform_point(frame,p.position)
            d:=at.xz-eye.xz
            if d.x*d.x+d.y*d.y>VIEW_REACH*VIEW_REACH {continue}
            rotation:=frame.rotation*p.rotation
            up:=mm.quat_rotate(rotation,[3]f32{0,BAY_POST,0})
            across:=mm.quat_rotate(rotation,[3]f32{BAY_ACROSS,0,0})
            line_draw(s,at,at+up,editor.BRUSH_ADD,2)
            line_draw(s,at-across,at+across,editor.BRUSH_ADD,2)
        }
    }
}

// What the runtime places in the cells of the graphs of a world: kept by the
// application for each world; nil outside it.
generated_of :: proc(s:^editor.Session,w:core.World_Ref) -> ^pcg.Pcg_Generated {
    if s.app==nil || w.data==nil {return nil}
    return host.app_world_storage(s.app,w.data,pcg.Pcg_Generated)
}

@(private)
cell_outline :: proc(s:^editor.Session,frame:mm.Transform,corner:[3]f32,cell,height:f32,color:ui.Color) {
    inset:=min(f32(0.2),cell*0.05)
    size:=cell-inset*2
    points:=[4][3]f32{corner+{inset,height,inset},corner+{inset+size,height,inset},corner+{inset+size,height,inset+size},corner+{inset,height,inset+size}}
    for &point in points {point=mm.transform_point(frame,point)}
    editor.brush_ring_draw(s,points[:],color,1.5)
}

@(private)
line_draw :: proc(s:^editor.Session,a,b:[3]f32,color:ui.Color,width:f32) {
    pa,seen_a:=editor.viewport_screen(s.viewport,a)
    pb,seen_b:=editor.viewport_screen(s.viewport,b)
    if seen_a && seen_b {ui.draw_line(s.gui.ctx,pa,pb,width,color)}
}

@(private)
box_draw :: proc(s:^editor.Session,box:mm.Aabb,color:ui.Color) {
    lo,hi:=box.min,box.max
    c:=[8][3]f32{{lo.x,lo.y,lo.z},{hi.x,lo.y,lo.z},{hi.x,lo.y,hi.z},{lo.x,lo.y,hi.z},{lo.x,hi.y,lo.z},{hi.x,hi.y,lo.z},{hi.x,hi.y,hi.z},{lo.x,hi.y,hi.z}}
    edges:=[12][2]int{{0,1},{1,2},{2,3},{3,0},{4,5},{5,6},{6,7},{7,4},{0,4},{1,5},{2,6},{3,7}}
    for edge in edges {line_draw(s,c[edge[0]],c[edge[1]],color,1.5)}
}

@(private)
label_draw :: proc(s:^editor.Session,at:[3]f32,text:string) {
    p,seen:=editor.viewport_screen(s.viewport,at)
    if !seen {return}
    ctx:=s.gui.ctx
    size:=ui.metric(ctx,"font_small")
    width:=ui.text_width(&ctx.font,text,size)
    ui.draw_rounded(ctx,{p.x-width*0.5-4,p.y-size*0.5-2,width+8,size+4},3,ui.tone(ctx,"popup"))
    ui.draw_text(ctx,text,p.x-width*0.5,p.y-size*0.5,size,ui.tone(ctx,"text"))
}
