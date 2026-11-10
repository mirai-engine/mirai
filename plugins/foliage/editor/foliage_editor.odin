package foliage_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"
import foliage "plugins:foliage/runtime"
import "base:runtime"

// The foliage tool: Paint and Erase put manual instances of the selected
// types on the surface under the brush and take them out, Generate turns the
// generator of the cells under it on or off, and Select takes one instance
// under the pointer, which the gizmo moves, turns and scales and Delete takes
// out. Each change is a step of undo: the source goes to the
// memory of the registry, unsaved, outside the history (editor.file_set),
// and the step keeps the revision of the Foliage that show it; the tool
// keeps the source of each revision, which undo and redo put back.

PANEL_SCOPE :: ui.Id(0x666f6c69)
FIELD_WIDTH :: f32(84) // of the number fields of the panel: a value and its unit
@(rodata) KEY_NAMES := [6]string{"1","2","3","4","5","6"}
TOOL :: "foliage"
RING_SEGMENTS :: 64
SCROLL_GUTTER :: ui.SCROLL_BAR+4 // the bar of the scroll area floats over the right edge of its content
// A held brush touches the foliage at most this many times a second, with
// the time it waited: what a second of it does stays the same.
BRUSH_RATE :: 30
PAINT_MAX :: 64 // instances a touch adds at most

@(storage,free="foliage_tool_free")
Foliage_Tool :: struct {
    active,begin,over,ready:bool,
    mode:Foliage_Mode,
    type:u32,              // the id of the type the panel shows
    painted:[dynamic]u32,  // the ids of the types selected in the list, which the brush paints and erases
    anchor:u32,            // the type a Shift click selects from
    reveal:u32,            // the type the list brings into sight on the next frame
    search:[64]u8,
    search_length:int,
    counts:Counts,
    info_open:bool,
    using prefs:Foliage_Preferences,
    list_hovered:bool, // the pointer is over the list of types: Delete takes them out
    adjust:editor.Brush_Adjust,
    reapplied:[dynamic]u64, // the instances a stroke of Reapply changed, each once
    place_next:int,         // the selected type Place puts after the last
    edit:Edit,
    stroke:Stroke,
    selected:Selected,
    gizmo:editor.Tool_Gizmo,
    held:foliage.Foliage_Type, // the type the panel shows, while it is changed
    held_type:u32,
    held_dirty:bool,
    using history:Revisions,
    work:foliage.Build_Work,
    near:[dynamic]Near,
    random:u64,
    scroll:[2]f32,
}

// The source the tool edits, read at the revision its Foliage show.
Edit :: struct {
    entity:core.Entity,
    id:base.Asset_Id,
    revision:u32,
    stamp:foliage.File_Stamp, // of the file it holds
    source:foliage.Source,
    ready:bool,
}
Stroke :: struct {
    active,changed:bool,
    mode:Foliage_Mode,  // what the stroke does: the mode of the tool, or Erase for Paint with Ctrl
    generate:bool,      // Generate turns the generator on; with Ctrl, off
    last:[3]f32,        // the point of the last touch, in the world
    touched:bool, // the held brush already touched in this stroke
    warned:bool,  // it said once that it has no type to paint
    waited:f32,   // seconds since it last did
    point,normal:[3]f32, // in the world, under the pointer
    over:bool,
}
foliage_tool_free :: proc(t:^Foliage_Tool) {
    foliage.source_destroy(&t.edit.source)
    editor.revision_history_destroy(&t.history,REVISIONS)
    delete(t.near);delete(t.painted);delete(t.reapplied)
    selected_free(&t.selected)
    foliage.build_work_destroy(&t.work)
    counts_free(&t.counts)
    t^={}
}

@(private)
tool_ready :: proc(t:^Foliage_Tool) {
    if t.ready {return}
    t.ready=true
    // The preferences of the editor read before the tool is first ready.
    if t.prefs==(Foliage_Preferences{}) {t.prefs=FOLIAGE_PREFERENCES_DEFAULT}
}


// A deep copy of a source.
source_clone :: proc(dst,src:^foliage.Source,allocator:=context.allocator) {
    foliage.source_destroy(dst)
    dst.info=src.info
    dst.types=make([dynamic]foliage.Foliage_Type,0,len(src.types),allocator)
    append(&dst.types,..src.types[:])
    dst.cells=make([dynamic]foliage.Cell,0,len(src.cells),allocator)
    for cell in src.cells {
        copy:=foliage.Cell{coord=cell.coord,generate=cell.generate,version=cell.version}
        copy.manual=make([dynamic]foliage.Foliage_Instance,0,len(cell.manual),allocator)
        append(&copy.manual,..cell.manual[:])
        copy.overrides=make([dynamic]foliage.Foliage_Override,0,len(cell.overrides),allocator)
        append(&copy.overrides,..cell.overrides[:])
        append(&dst.cells,copy)
    }
}

foliage_file :: proc(a:^host.Assets,id:base.Asset_Id,allocator:=context.temp_allocator) -> (path:string,found:bool) {
    file:=asset.registry_find(&a.registry,id) or_return
    return asset.registry_file_path(&a.registry,file.path,allocator),true
}

// Puts a source in its file, in the memory of the registry, unsaved,
// outside the history of the editor (foliage_history.odin).
foliage_write :: proc(s:^editor.Session,a:^host.Assets,id:base.Asset_Id,source:^foliage.Source) -> bool {
    path,found:=foliage_file(a,id)
    if !found {return false}
    bytes,error:=foliage.source_bytes(source,id,&a.types,a.allocator)
    if error!=.None {return false}
    defer delete(bytes,a.allocator)
    return editor.file_set(s,path,bytes)
}

// The source of a Foliage, read again when it shows another source, another
// revision or its file changed.
edit_prepare :: proc(t:^Foliage_Tool,assets:^host.Assets,allocator:runtime.Allocator,foliages:core.Read(foliage.Foliage),e:core.Entity) -> bool {
    a:=assets
    marker,known:=core.get(foliages,e)
    if a==nil || !known || marker.source=={} {return false}
    edit:=&t.edit
    stamp:=foliage.foliage_stamp(a,marker.source)
    if !stamp.found {return false}
    if !edit.ready || edit.id!=marker.source || edit.revision!=marker.revision || edit.stamp!=stamp {
        next:foliage.Source
        if !foliage.foliage_read(&next,a,marker.source,allocator) {foliage.source_destroy(&next);edit.ready=false;return false}
        foliage.source_destroy(&edit.source)
        edit.source=next
        other:=edit.id!=marker.source
        edit.id,edit.revision,edit.stamp,edit.ready=marker.source,marker.revision,stamp,true
        if _,index:=foliage.source_type(&edit.source,t.type);index<0 && len(edit.source.types)>0 {t.type=edit.source.types[0].id}
        // Another foliage paints the type the panel shows until others are checked.
        if other {
            clear(&t.painted)
            if len(edit.source.types)>0 {append(&t.painted,t.type);t.anchor=t.type}
        }
    }
    edit.entity=e
    return true
}

// The head of the source of the edit at its revision, before the edit
// changes: the first edit of a source makes it, a copy of the source.
edit_baseline :: proc(t:^Foliage_Tool) {
    edit:=&t.edit
    entry:=editor.revision_applied(&t.history,edit.id)
    if entry==nil {
        append(&t.applied,Applied{source=edit.id,revision=edit.revision,stamp=edit.stamp})
        entry=&t.applied[len(t.applied)-1]
    }
    if entry.held && entry.revision==edit.revision {return}
    foliage.source_destroy(&entry.head)
    source_clone(&entry.head,&edit.source)
    entry.held,entry.revision=true,edit.revision
}

// Shows what the edit holds before it is a step: the file in the memory of
// the registry, which the runtime reads again for the cells that changed.
edit_preview :: proc(s:^editor.Session,t:^Foliage_Tool,assets:^host.Assets) -> bool {
    a:=assets
    if !foliage_write(s,a,t.edit.id,&t.edit.source) {return false}
    t.edit.stamp=foliage.foliage_stamp(a,t.edit.id)
    if held:=editor.revision_applied(&t.history,t.edit.id);held!=nil {held.stamp=t.edit.stamp}
    return true
}

// Puts back the revision the edit started from: its head.
edit_cancel :: proc(s:^editor.Session,t:^Foliage_Tool,assets:^host.Assets) {
    head:=editor.revision_head(&t.history,t.edit.id,t.edit.revision)
    if head==nil {return}
    source_clone(&t.edit.source,head)
    edit_preview(s,t,assets)
}

// The edit as one step of undo: the next revision in the file and the
// Foliage that show the source, and the cells it changed in the history.
// False, changing nothing of the history, when it cannot be written.
edit_commit :: proc(s:^editor.Session,t:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets,label:string) -> bool {
    a:=assets
    table:=core.world_table_of(world,foliage.Foliage)
    if a==nil || table==nil {return false}
    edit:=&t.edit
    edit_baseline(t)
    head:=editor.revision_head(&t.history,edit.id,edit.revision)
    if head==nil {return false}
    next:=edit.revision+1
    edit.source.info.revision=next
    if !foliage.source_valid(&edit.source) {editor.notify(s,"The foliage is not valid: an instance is out of its limits");edit_cancel(s,t,assets);return false}
    step:=Step{source=edit.id,from=edit.revision,to=next}
    if !step_make(&step,head,&edit.source) {editor.notify(s,"The foliage history could not be stored");edit_cancel(s,t,assets);return false}
    if !foliage_write(s,a,edit.id,head) {
        step_apply(&step,head);step_destroy(&step)
        editor.notify(s,"The foliage could not be written")
        edit_cancel(s,t,assets)
        return false
    }
    editor.revision_push(&t.history,&step,step_destroy)
    edit.stamp=foliage.foliage_stamp(a,edit.id)
    history.edits_begin(s.edits,s.selection,label)
    for value,row in table.values[:core.count(table)] {if value.source==edit.id {core.edit_at(table,row).revision=next}}
    history.edits_end(s.edits)
    edit.revision=next
    if held:=editor.revision_applied(&t.history,edit.id);held!=nil {held.revision,held.stamp=next,edit.stamp}
    return true
}

// Undo and redo put back the revision of a source their step holds, and
// what changes the file outside the tool (Save, Discard, a recovery) is the
// source of the revision its Foliage show.
@(step="frame",stage="begin",after="editor_tools")
foliage_sync :: proc(s:^editor.Session,tool:^Foliage_Tool,foliages:core.Read(foliage.Foliage),assets:^host.Assets) {
    a:=assets
    if a==nil || tool.stroke.active || tool.gizmo.drag.active || editor.playing(s) {return}
    editor.revision_sync(s,&tool.history,foliages,a,REVISIONS)
}

@(step="input",after="editor_begin")
foliage_pointer :: proc(s:^editor.Session,tool:^Foliage_Tool,input:core.Input) {
    tool_ready(tool)
    tool.active,tool.over,tool.begin=editor.tool_pointer(s,TOOL,input)
}

// The Foliage the tool edits: the one selected.
@(private)
target :: proc(s:^editor.Session,foliages:core.Read(foliage.Foliage)) -> core.Entity {
    #reverse for e in s.selection.entities {if core.has(foliages,e) {return e}}
    return core.NONE
}

@(step="frame")
foliage_tool :: proc(
    s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,foliages:core.Read(foliage.Foliage),worlds:core.Read(core.World_Transform),
    grounds:core.Ref(foliage.Foliage_Ground),requests:^foliage.Foliage_Ground_Requests,resident:core.Ref(foliage.Foliage_Resident),
    assets:^host.Assets,allocator:runtime.Allocator,input:core.Input,frame:core.Frame_Time,
) {
    if !tool.active || editor.playing(s) {
        if tool.stroke.active || tool.gizmo.drag.active {edit_cancel(s,tool,assets)}
        tool.stroke,tool.gizmo,tool.adjust={},{},{}
        selected_clear(tool)
        return
    }
    if !s.gui.begun {return}
    keys:=TOOL_KEYS
    if tool.selected.active {keys+={.Delete,.Backspace,.End}}
    if tool.list_hovered {keys+={.Delete,.Backspace}}
    if tool.adjust.active || tool.stroke.active {keys+={.Escape,.Enter}}
    editor.tool_keys(s,TOOL,keys)
    e:=target(s,foliages)
    if e==core.NONE || !edit_prepare(tool,assets,allocator,foliages,e) {selected_clear(tool);return}
    placed,has_place:=core.get(worlds,e)
    if !has_place {return}
    owner:=placed.transform
    ground:=foliage.ground_owner(grounds.ptr,e)
    if !tool.stroke.active && !tool.adjust.active && !tool.gizmo.drag.active {tool_keys_frame(s,tool,assets,input)}
    switch tool.mode {
    case .Paint,.Erase,.Reapply,.Generate: brush_frame(s,tool,world,e,owner,ground,requests,assets,input,frame)
    case .Select: select_frame(s,tool,world,e,owner,ground,resident.ptr,assets,input,frame)
    case .Place:  place_frame(s,tool,world,owner,ground,assets,input)
    }
}

@(step="ui",after="editor_panels")
foliage_panel :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,foliages:core.Read(foliage.Foliage),worlds:core.Read(core.World_Transform),grounds:core.Ref(foliage.Foliage_Ground),data:core.Ref(foliage.Foliage_Data),assets:^host.Assets,allocator:runtime.Allocator,input:core.Input) {
    g:=s.gui
    if !g.begun || editor.playing(s) {return}
    tool_ready(tool);ctx:=g.ctx
    tool.active=editor.tool_on(s,TOOL)
    if !tool.active || s.viewport.pick.active {return}
    id:=ui.id_derive(ctx,PANEL_SCOPE,"panel")
    panel:=editor.tool_panel(g,id)
    room:=max(ctx.size.y-panel.offset.y-ctx.theme.margin-panel.padding[1]-panel.padding[3],ctx.theme.row)
    // The panel and its scroll area end with the scope they open, so each keeps a block.
    if ui.panel(ctx,id,panel) {
        ui.id_push(ctx,id);defer ui.id_pop(ctx)
        if ui.scroll_area(ctx,ui.id(ctx,"scroll"),&tool.scroll,{height=ui.FIT,max_height=room,gap=panel.gap,padding={0,0,SCROLL_GUTTER,0}}) {panel_rows(s,tool,world,foliages,worlds,grounds,data,assets,allocator,input)}
    }
}

// What the panel of the tool shows: a foliage to choose, or the mode, the
// brush, what is under it and the types of the one selected.
@(private)
panel_rows :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,foliages:core.Read(foliage.Foliage),worlds:core.Read(core.World_Transform),grounds:core.Ref(foliage.Foliage_Ground),data:core.Ref(foliage.Foliage_Data),assets:^host.Assets,allocator:runtime.Allocator,input:core.Input) {
    ctx:=s.gui.ctx
    e:=target(s,foliages)
    if e==core.NONE || !edit_prepare(tool,assets,allocator,foliages,e) {
        choose_panel(s,tool,world,assets,allocator,foliages)
        return
    }
    source:=&tool.edit.source
    ui.section(ctx,editor.entity_label(world,e),"",80)
    // The modes in two rows of three, each with its number key.
    for row in 0..<2 {
        if ui.segments(ctx,ui.GROW,ctx.theme.control) {
            for i in row*3..<row*3+3 {
                mode:=Foliage_Mode(i)
                if ui.button(ctx,ui.id(ctx,"mode",i+1),{label=MODE_NAMES[mode],detail=KEY_NAMES[i],style=.Tab,active=tool.mode==mode,width=-1,height=ctx.theme.control-4,size=ctx.theme.font_small}).clicked {mode_set(s,tool,assets,mode)}
            }
        }
    }
    ground:=foliage.ground_owner(grounds.ptr,e)
    placed,has_place:=core.get(worlds,e)
    switch tool.mode {
    case .Paint,.Erase,.Reapply,.Generate:
        radius:=f64(tool.radius)
        if ui.property(ctx,"Radius") {
            if ui.number_field(ctx,ui.id(ctx,"radius"),&radius,{width=ui.fixed(FIELD_WIDTH),min=f64(RADIUS_MIN),max=f64(RADIUS_MAX),has_min=true,has_max=true,speed=0.05,unit="m"}).changed {tool.radius=f32(radius)}
            editor.key_hint(ctx,"F")
        }
        if tool.mode==.Paint || tool.mode==.Erase {
            density:=density_of(tool,tool.mode)
            percent:=f64(density^)*100
            if ui.property(ctx,tool.mode==.Paint?"Paint density":"Erase density") {
                if ui.number_field(ctx,ui.id(ctx,"density"),&percent,{width=ui.fixed(FIELD_WIDTH),min=tool.mode==.Paint?1:0,max=100,has_min=true,has_max=true,speed=0.5,unit="%",integer=true}).changed {density^=f32(percent/100)}
                editor.key_hint(ctx,"Shift F")
            }
        }
        if tool.mode==.Paint {if ui.property(ctx,"Ground only") {ui.checkbox(ctx,ui.id(ctx,"ground_only"),&tool.ground_only)}}
        if tool.mode==.Reapply {
            if ui.property(ctx,"Scale") {ui.checkbox(ctx,ui.id(ctx,"reapply_scale"),&tool.reapply_scale)}
            if ui.property(ctx,"Turn") {ui.checkbox(ctx,ui.id(ctx,"reapply_turn"),&tool.reapply_turn)}
            if ui.property(ctx,"Offset") {ui.checkbox(ctx,ui.id(ctx,"reapply_offset"),&tool.reapply_offset)}
        }
    case .Place:
        if ui.property(ctx,"Ground only") {ui.checkbox(ctx,ui.id(ctx,"ground_only"),&tool.ground_only)}
    case .Select:
        gizmo:=int(s.viewport.tool)
        if ui.tabs(ctx,ui.id(ctx,"gizmo"),{"Move","Rotate","Scale"},&gizmo) {s.viewport.tool=editor.Tool(gizmo)}
        radius:=f64(tool.radius)
        if ui.property(ctx,"Radius") {if ui.number_field(ctx,ui.id(ctx,"radius"),&radius,{width=ui.fixed(FIELD_WIDTH),min=f64(RADIUS_MIN),max=f64(RADIUS_MAX),has_min=true,has_max=true,speed=0.05,unit="m"}).changed {tool.radius=f32(radius)}}
        if has_place && ui.button(ctx,ui.id(ctx,"select_all"),{label="Select all of the types",style=.Field,width=-1,center=true}).clicked {selected_all(tool,e,ground)}
        if tool.selected.active && len(source.types)>0 {
            sel:=&tool.selected
            ui.section(ctx,"Selected",fmt.tprintf("%s instances",count_text(u32(len(sel.refs)))),140)
            chosen:=-1
            names:=make([]string,len(source.types),context.temp_allocator)
            for &t,i in source.types {
                names[i]=type_name(&t)
                if len(sel.types)>0 && t.id==sel.types[0] {chosen=i}
            }
            for type in sel.types {if len(sel.types)>0 && type!=sel.types[0] {chosen=-1;break}}
            if ui.property(ctx,"Type") {
                if has_place && ui.dropdown(ctx,ui.id(ctx,"instance_type"),{list=names},&chosen,{width=-1}) {selected_retype(s,tool,world,assets,ground,placed.transform,source.types[chosen].id)}
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
                if ui.button(ctx,ui.id(ctx,"ground"),{label="Stand on ground",detail="End",style=.Field,width=-1,center=true}).clicked && has_place {selected_ground(s,tool,world,assets,ground,placed.transform)}
                if ui.button(ctx,ui.id(ctx,"delete"),{label="Delete",detail="Del",style=.Field,width=-1,center=true}).clicked {selected_delete(s,tool,world,assets)}
            }
        }
    }
    if data.ptr!=nil {
        if entry:=foliage.data_find(data.ptr,tool.edit.id);entry!=nil {
            revision:=ground.revision if ground!=nil else 0
            counts_update(&tool.counts,&entry.source,{e,entry.epoch,entry.loads,revision},ground,&tool.work)
        }
    }
    if ui.collapsible(ctx,ui.id(ctx,"info"),"Live info",&tool.info_open).open {
        placed,has_place:=core.get(worlds,e)
        info_rows(s,tool,placed.transform if has_place else mm.Transform{rotation=1,scale={1,1,1}},ground)
    }
    types_list(s,tool,world,assets,input)
    type_panel(s,tool,world,assets,input)
}

// What is under the brush, as the live info of Terrain3D: where it is, its
// cell and the instances the cell shows, the height of the surface and of the
// ground of the foliage there, and the slope of the surface.
@(private)
info_rows :: proc(s:^editor.Session,tool:^Foliage_Tool,owner:mm.Transform,ground:^foliage.Ground_Owner) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    over:=tool.mode!=.Select && tool.over && tool.stroke.over
    position,cell,instances,height,below,slope:="-","-","-","-","-","-"
    if to_local,inverted:=mm.transform_inverse_matrix(owner);over && inverted {
        p:=tool.stroke.point
        local:=mm.mat4_point(to_local,p)
        coord,in_cell:=foliage.cell_of(local)
        position=fmt.tprintf("%.1f, %.1f",p.x,p.z)
        cell=fmt.tprintf("%d, %d",coord.x,coord.y)
        if count,known:=counts_cell(&tool.counts,coord);known {instances=count_text(count)}
        height=fmt.tprintf("%.2f",p.y)
        if h,_,ok:=foliage.ground_at(ground_of(ground,coord),in_cell.x,in_cell.z);ok {
            below=fmt.tprintf("%.2f",mm.transform_point(owner,{local.x,h,local.z}).y)
        }
        n:=linalg.normalize0(tool.stroke.normal)
        slope=fmt.tprintf("%.1f°",math.to_degrees(math.acos(clamp(n.y,-1,1))))
    }
    rows:=[?][2]string{{"Position",position},{"Cell",cell},{"Instances",instances},{"Height",height},{"Ground",below},{"Slope",slope}}
    for row in rows {
        if ui.property(ctx,row[0]) {ui.label(ctx,row[1],th.font,th.text)}
    }
}

@(private)
type_name :: proc(t:^foliage.Foliage_Type) -> string {
    name:=base.text_get(t.name[:])
    return name!=""?name:fmt.tprintf("Type %d",t.id)
}

// The types of the foliage as the content browser shows its assets, those
// the search finds, each with its instances; the selected ones are those the
// brush paints, and the one clicked shows its values. Their menu takes the
// selected ones out. A mesh dropped on them is a new type.
@(private)
types_list :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets,input:core.Input) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    source:=&tool.edit.source
    types_keep(tool)
    selected:=len(tool.painted)
    ui.section(ctx,"Types",fmt.tprintf("%d selected",selected) if selected>1 else "",80)
    area:=ui.id(ctx,"types")
    tool.list_hovered=false
    if rect,found:=ui.widget_rect(ctx,area);found {
        tool.list_hovered=ui.rect_contains(rect,ctx.pointer)
        d:=&s.gui.drag
        // A mesh dropped on a card is the mesh of its type; elsewhere, a new type.
        if d.kind==.Asset && d.asset_kind==asset.KIND_MESH && editor.drag_dropped(s.gui,rect) {
            onto:=u32(0)
            for &t in source.types {if card,on:=ui.widget_rect(ctx,ui.id(ctx,"type",int(t.id)+1));on && ui.rect_contains(card,ctx.pointer) {onto=t.id}}
            if onto!=0 {type_replace(s,tool,world,assets,onto,d.asset_id)} else {type_add(s,tool,world,assets,d.asset_id)}
        }
    }
    // Delete over the list takes the selected types out, as their menu does.
    if tool.list_hovered && !tool.selected.active && selected>0 && ctx.edit.id==0 && (core.key_pressed(input,.Delete) || core.key_pressed(input,.Backspace)) {types_remove(s,tool,world,assets,tool.painted[:])}
    if len(source.types)>0 {
        search:=string(tool.search[:tool.search_length])
        // The type an instance of the scene shows stays in sight.
        if tool.reveal!=0 {
            if t,_:=foliage.source_type(source,tool.reveal);t!=nil && !type_matches(type_name(t),search) {tool.search_length=0}
        }
        if editor.search_field(s,ui.id(ctx,"search"),tool.search[:],&tool.search_length,"Search types") {tool.scroll=0}
    }
    search:=string(tool.search[:tool.search_length])
    shown:=make([dynamic]u32,0,len(source.types),context.temp_allocator)
    for &t in source.types {if type_matches(type_name(&t),search) {append(&shown,t.id)}}
    columns,cell:=editor.asset_cards(s,editor.tool_panel_inner(s.gui)-SCROLL_GUTTER)
    menu:=ui.id(ctx,"type_menu")
    toggle,extend:=.Primary in ctx.input.modifiers,.Shift in ctx.input.modifiers
    if ui.box(ctx,{id=area,width=ui.GROW,height=ui.FIT,direction=.Column,gap=editor.CONTENT_GAP}) {
        for first:=0;first<len(shown);first+=columns {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=editor.CONTENT_GAP}) {
                for id in shown[first:min(first+columns,len(shown))] {
                    t,_:=foliage.source_type(source,id)
                    shown_asset,kind:=t.mesh,asset.KIND_MESH
                    if shown_asset=={} {shown_asset,kind=t.prefab,asset.KIND_SCENE}
                    card:=ui.id(ctx,"type",int(id)+1)
                    if tool.reveal==id {ctx.reveal_next,tool.reveal=card,0}
                    it:=editor.asset_card_begin(s,card,shown_asset,kind,type_name(t),slice.contains(tool.painted[:],id),cell)
                    if it.clicked {types_click(tool,shown[:],id,toggle,extend)}
                    if it.right {
                        if !slice.contains(tool.painted[:],id) {types_click(tool,shown[:],id,false,false)}
                        ui.popup_open(ctx,menu,{ctx.pointer.x,ctx.pointer.y,0,0})
                    }
                    if count,known:=counts_total(&tool.counts,id);known {
                        float:=editor.asset_card_float(s)
                        if float=={} {ui.spacer(ctx)}
                        if ui.box(ctx,{width=ui.FIT,height=ui.FIT,padding={5,1,5,1},fill=th.chip,radius=th.radius_control,float=float}) {
                            ui.label(ctx,count_text(count),th.font_caption,th.text)
                        }
                    }
                    editor.asset_card_end(s)
                }
            }
        }
    }
    if ui.popup(ctx,menu,{min_width=160}) {
        ui.id_push(ctx,menu);defer ui.id_pop(ctx)
        label:=fmt.tprintf("Remove %d types",selected) if selected>1 else "Remove type"
        if ui.menu_item(ctx,ui.id(ctx,"remove"),label,{icon=.Cross,danger=true}) {types_remove(s,tool,world,assets,tool.painted[:])}
    }
}

// The values of the type the list shows, which the panel holds while they
// change and keeps as a step once they settle.
@(private)
type_panel :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets,input:core.Input) {
    ctx:=s.gui.ctx
    source:=&tool.edit.source
    t,_:=foliage.source_type(source,tool.type)
    if t==nil {return}
    if tool.held_type!=t.id || !tool.held_dirty {tool.held,tool.held_type=t^,t.id}
    defaults:=foliage.FOLIAGE_TYPE_DEFAULT
    h:=editor.Held_Values{key=u64(PANEL_SCOPE)<<32|u64(t.id),info=type_info_of(foliage.Foliage_Type),value=&tool.held,defaults=&defaults}
    fields:=[?]string{"name","mesh","prefab","materials","density","scale","height","yaw","tilt","align","offset","rule","fade_distance","cull_distance","impostor_distance","wind","wind_variants","casts_shadow","ray_visible","collision","size"}
    ui.section(ctx,type_name(t),"",80)
    for field in fields {if editor.held_field_row(s,h,field) {tool.held_dirty=true}}
    if tool.held_dirty && !core.mouse_down(input,.Left) && ctx.edit.id==0 {
        tool.held_dirty=false
        if tool.held!=t^ {
            edit_baseline(tool)
            held:=tool.held
            t^=held
            if !foliage.source_valid(source) {t^=head_type(tool,held.id);editor.notify(s,"The type of foliage is not valid")} else {edit_commit(s,tool,world,assets,"Foliage type")}
        }
    }
}

// The type of an id in the head of the revision of the edit.
@(private)
head_type :: proc(tool:^Foliage_Tool,id:u32) -> foliage.Foliage_Type {
    if head:=editor.revision_head(&tool.history,tool.edit.id,tool.edit.revision);head!=nil {
        if t,_:=foliage.source_type(head,id);t!=nil {return t^}
    }
    return foliage.FOLIAGE_TYPE_DEFAULT
}

// A type that shows a mesh, painted by the brush, as a step.
type_add :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets,mesh:base.Asset_Id) -> bool {
    if type_make(s,tool,assets,mesh)==nil {return false}
    return edit_commit(s,tool,world,assets,"Add foliage type")
}

// A new type of a name no other has: name, or that of the mesh with none. Nil
// and a notice when it cannot be made.
type_make :: proc(s:^editor.Session,tool:^Foliage_Tool,assets:^host.Assets,mesh:base.Asset_Id,name:="") -> ^foliage.Foliage_Type {
    if mesh=={} {editor.notify(s,"Choose a .mesh for the type: foliage draws meshes of the assets, not primitives");return nil}
    source:=&tool.edit.source
    if len(source.types)>=foliage.TYPES_MAX {editor.notify(s,"The foliage has as many types as it holds");return nil}
    edit_baseline(tool)
    wanted:=name!=""?name:"Type"
    if assets!=nil && name=="" {
        if file,found:=asset.registry_find(&assets.registry,mesh);found {wanted=filepath.stem(filepath.base(file.path))}
    }
    t:=foliage.source_type_add(source,type_name_free(source,wanted),mesh)
    if t==nil {editor.notify(s,"There is no memory for another foliage type");return nil}
    type_reveal(tool,t.id)
    return t
}

// name, with a number after it if another type has it.
@(private)
type_name_free :: proc(source:^foliage.Source,name:string) -> string {
    taken :: proc(source:^foliage.Source,name:string) -> bool {
        for &t in source.types {if type_name(&t)==name {return true}}
        return false
    }
    free:=name
    for number:=2;taken(source,free);number+=1 {free=fmt.tprintf("%s %d",name[:min(len(name),len(foliage.Foliage_Type{}.name)-8)],number)}
    return free
}

// Another mesh for a type, which keeps its instances and its values, as a
// step: the materials of its slots are those of the new mesh.
type_replace :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets,id:u32,mesh:base.Asset_Id) -> bool {
    t,_:=foliage.source_type(&tool.edit.source,id)
    if t==nil || mesh=={} || t.mesh==mesh {return false}
    edit_baseline(tool)
    t.mesh,t.prefab,t.materials=mesh,{},{}
    tool.held_dirty=false
    type_reveal(tool,id)
    return edit_commit(s,tool,world,assets,"Replace foliage mesh")
}

// Takes types out with their instances, as one step.
types_remove :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets,ids:[]u32) -> bool {
    edit_baseline(tool)
    removed:=slice.clone(ids,context.temp_allocator)
    changed:=false
    for id in removed {
        if !foliage.source_type_remove(&tool.edit.source,id) {continue}
        changed=true
        if at,found:=slice.linear_search(tool.painted[:],id);found {ordered_remove(&tool.painted,at)}
    }
    if !changed {return false}
    tool.selected={}
    return edit_commit(s,tool,world,assets,"Remove foliage type" if len(removed)==1 else "Remove foliage types")
}

// Without a Foliage selected the tool offers those of the scene and New foliage.
@(private)
choose_panel :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,foliages:core.Read(foliage.Foliage)) {
    ctx:=s.gui.ctx
    ui.section(ctx,"Select or create a foliage","",80)
    for i in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,i)
        if ui.button(ctx,ui.id(ctx,"foliage",core.entity_index(e)+1),{label=editor.entity_label(world,e),icon=.Edit,style=.Field,width=-1}).clicked {history.selection_set(s.selection,{e})}
    }
    if ui.button(ctx,ui.id(ctx,"create"),{label="New foliage",style=.Field,width=-1,center=true}).clicked {foliage_create(s,tool,world,assets,allocator)}
}

// A Foliage with a new .foliage of no types, at the target of the view. The
// new file is part of the step: undo takes it away, and it stays in the
// memory of the registry until it is saved.
foliage_create :: proc(s:^editor.Session,tool:^Foliage_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator,at:=[3]f32{},placed:=false,name:="") -> core.Entity {
    a:=assets
    table:=core.world_table_of(world,foliage.Foliage)
    if a==nil || table==nil {editor.notify(s,"The project has no foliage library");return core.NONE}
    label,path:=editor.asset_new_file(s,fmt.tprintf("%s/foliage",a.registry.root),name!=""?name:"Foliage",foliage.EXTENSION,name!="")
    seed:=base.hash_combine(base.name_hash(path),platform.clock_ns())
    id:=base.Asset_Id{seed,base.hash_combine(seed,base.name_hash("Foliage"))}
    source:foliage.Source
    defer foliage.source_destroy(&source)
    source.info={seed=u32(seed),revision=1}
    bytes,error:=foliage.source_bytes(&source,id,&a.types,allocator)
    if error!=.None {editor.notify(s,"The foliage could not be written");return core.NONE}
    defer delete(bytes,allocator)
    history.edits_begin(s.edits,editor.document_selection(s),"Add foliage")
    if !editor.file_write(s,path,bytes,"Add foliage") {history.edits_cancel(s.edits,world);editor.notify(s,"The foliage could not be written");return core.NONE}
    position:=placed?at:[3]f32{s.viewport.orbit.target.x,0,s.viewport.orbit.target.z}
    e:=editor.entity_create(s,{preset=.Empty,name=label,transform={position=position,rotation=1,scale={1,1,1}}})
    core.add(table,e,foliage.Foliage{source=id,revision=1})
    history.edits_end(s.edits)
    history.selection_set(editor.document_selection(s),{e})
    append(&tool.applied,Applied{source=id,revision=1,stamp=foliage.foliage_stamp(a,id)})
    return e
}

// A .foliage in the browser and its fields shows a mesh of its types, or a
// prefab of one when they show no mesh of their own.
@(storage)
Foliage_Thumbnails :: struct {provider:editor.Thumbnail_Provider}
FOLIAGE_THUMBNAILS_DEFAULT :: Foliage_Thumbnails{provider={kinds={0=foliage.KIND},count=1,subject=foliage_thumbnail}}

// A .foliage in the browser, with the color of Unreal's foliage types.
@(storage)
Foliage_Kinds :: struct {provider:editor.Asset_Kind_Provider}
FOLIAGE_KINDS_DEFAULT :: Foliage_Kinds{provider={kinds={0={kind=foliage.KIND,label="Foliage",color={12,173,12,255},icon=ui.Icon(u8(ui.Icon.User)+u8(editor.User_Icon.Agent_Leaf)),extension=foliage.EXTENSION,scene_data=true}},count=1}}

// The menu of a mesh in the browser adds it as a type to the foliage the tool
// edits, or makes a foliage of it when none is selected.
@(storage)
Foliage_Menu :: struct {provider:editor.Asset_Menu_Provider}
FOLIAGE_MENU_DEFAULT :: Foliage_Menu{provider={menu=foliage_menu}}

@(private)
foliage_menu :: proc(s:^editor.Session,file:^asset.Registry_File) {
    if file.kind!=asset.KIND_MESH || s.mode!=.Edit || editor.asset_document_active(s)!=nil {return}
    ctx:=s.gui.ctx
    tool:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Foliage_Tool)
    world:=editor.edited_world(s)
    table:=core.world_table_of(world,foliage.Foliage)
    if tool==nil || table==nil {return}
    foliages:=core.read(table)
    e:=target(s,foliages)
    label:="Create foliage" if e==core.NONE else fmt.tprintf("Add to %s",editor.entity_label(world,e))
    if !ui.menu_item(ctx,ui.id(ctx,"foliage_add"),label,{icon=.Edit}) {return}
    id:=file.id
    if e==core.NONE {
        e=foliage_create(s,tool,world,s.app.assets,s.app.allocator)
        if e==core.NONE {return}
    }
    editor.tool_set(s,TOOL,true)
    if edit_prepare(tool,s.app.assets,s.app.allocator,foliages,e) {type_add(s,tool,world,s.app.assets,id)}
}

@(private)
foliage_thumbnail :: proc(s:^editor.Session,file:^asset.Registry_File,clip:u32,subject:^editor.Thumbnail_Subject) -> bool {
    a:=s.app.assets
    if a==nil || file.kind!=foliage.KIND {return false}
    prefab:base.Asset_Id
    for id in asset.registry_dependencies(&a.registry,file) {
        used,found:=asset.registry_find(&a.registry,id)
        if !found {continue}
        if used.kind==asset.KIND_MESH {subject^={mesh={mesh=id},tint=erender.TINT_DEFAULT};return true}
        if asset.registry_prefab(used) && prefab=={} {prefab=id}
    }
    if prefab=={} {return false}
    subject^={document=prefab}
    return true
}
