package editor

import "mirai:core"
import "mirai:editor/history"
import "mirai:std/base"
import "mirai:ui"

// Find object (Space): a list in the middle of the window of every entity by
// name, for those that are not in sight. The arrows move the row while the
// field keeps the keyboard and Enter takes it; the entity under the row is
// outlined in the scene. A click selects it (Shift or Ctrl adds it) and shows
// it in the outliner; while a reference of the inspector waits for an entity
// the list chooses for it instead.

FIND_WIDTH :: f32(440)
FIND_ROWS :: 10
FIND_OUTLINE :: [4]f32{1,0.71,0.28,1}

@(storage)
Finder :: struct {
    filter:[64]u8,
    filter_length:int,
    cursor:int,       // the row the keyboard is on; -1: none
    scroll:f32,
    focus:bool,       // the field takes the keyboard on the next frame it is built
    outlined:core.Entity, // the entity under the cursor or the pointer
}

@(private)
finder_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"find_popup")}

@(private)
finder_open :: proc(s:^Session) {
    f:=s.finder
    g:=s.gui
    th:=&g.ctx.theme
    f^={cursor=-1,focus=true}
    size:=g.ctx.size
    width:=min(FIND_WIDTH,size.x-2*th.margin)
    frame:=2*th.margin+th.row+6
    capacity:=clamp(int((size.y-th.bar_height-2*th.margin-frame)/th.row),1,FIND_ROWS)
    // Centered as if the list were full, so the field stays put while the matches change.
    top:=max((size.y-frame-f32(capacity)*th.row)*0.5,th.bar_height+th.margin)
    ui.popup_open(g.ctx,finder_popup(g),{(size.x-width)*0.5,top-4,width,0})
}

@(private)
finder_candidates :: proc(s:^Session,w:core.World_Ref) -> []core.Entity {
    names:=core.world_table_of(w,core.Name)
    filter:=string(s.finder.filter[:s.finder.filter_length])
    result:=make([dynamic]core.Entity,0,names!=nil?core.count(names):0,context.temp_allocator)
    if names==nil {return result[:]}
    for e in names.entities {
        if !entity_alive(w,e) || !base.contains_fold(entity_name(w,e),filter) {continue}
        append(&result,e)
    }
    return result[:]
}

// What a click on an entity of the list does: it is chosen for the reference that waits, or it is selected.
@(private)
finder_choose :: proc(s:^Session,w:core.World_Ref,e:core.Entity,add:bool) {
    if s.viewport.pick.active {
        inspector_pick_finish(s,w,e)
        return
    }
    target:=selection_click_target(s,w,e,false)
    history.selection_set(s.selection,{target},add)
    outliner_reveal(s.outliner,w,target)
    // What is found is in the scene: it comes to the front.
    if scene_covered(s) {asset_document_request(s,-1)}
}

@(private)
finder_build :: proc(s:^Session,w:core.World_Ref) {
    f:=s.finder
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    popup:=finder_popup(g)
    f.outlined=core.NONE
    if !ui.popup_is_open(ctx,popup) {return}
    candidates:=finder_candidates(s,w)
    capacity:=clamp(int((ctx.size.y-th.bar_height-4*th.margin-th.row)/th.row),1,FIND_ROWS)
    height:=f32(clamp(len(candidates),1,capacity))*th.row
    f.cursor=clamp(f.cursor,-1,len(candidates)-1)
    chosen:=-1
    if ui.popup(ctx,popup,{width=min(FIND_WIDTH,ctx.size.x-2*th.margin),padding=8,gap=6}) {
        ui.id_push(ctx,popup)
        field:=ui.id(ctx,"filter")
        if f.focus {
            ui.edit_request(ctx,field)
            f.focus=false
        }
        before:=f.filter_length
        result:=ui.text_field(ctx,field,f.filter[:],&f.filter_length,{live=true,keep_caret=true})
        if result.changed || f.filter_length!=before {f.cursor,f.scroll=-1,0}
        // The arrows move the row while the field keeps the keyboard, and Enter takes it.
        keys:=ctx.input.keys_repeated
        if .Down in keys {f.cursor=min(f.cursor+1,len(candidates)-1)}
        if .Up in keys {f.cursor=max(f.cursor-1,0)}
        if .Down in keys || .Up in keys {ui.scroll_reveal(&f.scroll,f32(f.cursor)*th.row,f32(f.cursor+1)*th.row,height)}
        if result.committed && .Enter in ctx.input.keys_pressed {
            chosen=f.cursor>=0?f.cursor:(len(candidates)>0?0:-1)
            if chosen<0 {ui.popup_close(ctx)}
        }
        // The Escape that leaves the field closes the list.
        if result.cancelled {ui.popup_close(ctx)}
        rows:=ui.id(ctx,"rows")
        first,last:=ui.list_begin(ctx,rows,&f.scroll,len(candidates),th.row,height)
        for index in first..<last {
            row_id:=ui.id(ctx,"row",index+1)
            if ctx.hot==row_id && ctx.pointer_moved {f.cursor=index}
            e:=candidates[index]
            icon,color:=entity_icon(s,w,e)
            it:=ui.row(ctx,row_id,{label=entity_name(w,e),icon=icon,icon_color=color,selected=f.cursor==index,quiet=true})
            if it.hot {f.outlined=e}
            if it.clicked {chosen=index}
        }
        ui.list_end(ctx,rows,len(candidates),last,th.row)
        if f.outlined==core.NONE && f.cursor>=0 && f.cursor<len(candidates) {f.outlined=candidates[f.cursor]}
        ui.id_pop(ctx)
    }
    if chosen>=0 && chosen<len(candidates) {
        finder_choose(s,w,candidates[chosen],.Shift in ctx.input.modifiers || .Primary in ctx.input.modifiers)
        ui.popup_close(ctx)
    }
}

@(private)
finder_outline :: proc(s:^Session,w:core.World_Ref) {
    if s.finder.outlined!=core.NONE {outline_entity(s,w,s.finder.outlined,FIND_OUTLINE)}
}
