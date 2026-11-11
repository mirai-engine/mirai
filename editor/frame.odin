package editor

import "core:math"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:platform"
import "mirai:ui"

// The frame of the editor, as steps of its loop over the World shown:
//
//   editor_begin   input   the UI begins with the input of the frame, the
//                          viewport follows the window, the keyboard runs shortcuts
//   editor_tools   frame   the camera, the gizmo and the selection: before the
//                          late phase propagates transforms, so what they move is drawn now
//   editor_panels  ui      the bar and the panels
//   editor_end     ui      what is drawn over the scene, the end of the UI and
//                          its layer, the step of the gesture that ended
//
// A plugin draws into Editor_Ui.ctx from a step of the ui phase that runs
// after editor_panels and before editor_end.

// ---------------------------------------------------------------- steps

@(step="input")
editor_begin :: proc(s:^Session,g:^Editor_Ui,v:^Viewport,selection:^history.Selection,world:core.World_Ref,app:^host.App) {
    started:=platform.clock_ns();defer api_timed(s,.Begin,started)
    ctx:=g.ctx
    if ctx==nil {return}
    frame:=platform.input_frame(app.platform)
    input:=app.ui_input
    // A tool that holds the pointer keeps it from the UI.
    if v.capture!=.None || (s.mode==.Play && !s.play_input_released) {
        input.pointer_absent=true
        input.down,input.pressed,input.released,input.clicks,input.wheel={},{},{},0,{}
    }
    popups,modal:=ctx.popup.count,g.modal!=.None
    ui.context_set_density(ctx,app.density)
    bars_snap(g,app.density)
    ui.frame_begin(ctx,input)
    g.begun=true
    g.named_count=0
    history.selection_prune(selection,world)
    // The scene is drawn only under the bars, which always cover what is
    // above, and between the left panel and a docked Details: what they take
    // is not drawn. The camera keeps the center of the whole view, the part
    // under the left panel too, so folding the panel moves nothing of the image.
    bars:=ui.metric(ctx,"bar_height")+toolbar_height(g)
    density:=app.density if app.density>0 else 1
    left,right:=dock_widths(s)
    top:=min(i32(math.round(bars*density)),max(app.drawable.y-1,0))
    view_x0:=min(i32(math.round(left*density)),max(app.drawable.x-1,0))
    x0:=min(i32(math.round(dock_scene_left(s)*density)),max(app.drawable.x-1,0))
    x1:=max(app.drawable.x-i32(math.round(right*density)),x0+1)
    app.scene={x0,top,x1-x0,max(app.drawable.y-top,1)}
    app.scene_shift={f32(view_x0-x0)/f32(x1-x0),0}
    viewport_update(v,{left,bars},{max(ctx.size.x-left-right,1),max(ctx.size.y-bars,1)},ctx.size,frame,input.modifiers)
    v.hovered=frame.mouse_inside && !ctx.over && ctx.active==0 && popups==0 && !modal && s.mode!=.Play && !camera_previewing(s) && !player_processes_view(s) && g.drag.kind==.None && !scene_covered(s)
    drag_update(g,frame)
    events_input(s,frame)
    editor_shortcuts(s,g,v,frame.keys_pressed,input.modifiers,popups,modal)
}

// The keys of the frame are shortcuts unless a text field, a menu, a dialog
// or a gesture takes them.
@(private)
editor_shortcuts :: proc(s:^Session,g:^Editor_Ui,v:^Viewport,keys:core.Keys,modifiers:ui.Modifiers,popups:int,modal:bool) {
    ctx:=g.ctx
    if ctx.edit.id!=0 || popups>0 || modal || v.capture!=.None || g.splitter!=.None || content_typing(s.content,ctx) || s.projects!=nil && s.projects.shown {return}
    shortcuts_run(s,keys,modifiers)
}

@(step="frame",stage="begin")
editor_tools :: proc(s:^Session,g:^Editor_Ui,v:^Viewport,world:core.World_Ref) {
    started:=platform.clock_ns();defer api_timed(s,.Tools,started)
    if !g.begun {return}
    if s.mode!=.Play && !scene_covered(s) {
        tools_update(s,world)
        ai_annotation_pointer(s,world)
    }
    collab_follow(s)
    viewport_camera(v)
    view_write(s,world)
}

@(step="ui")
editor_panels :: proc(s:^Session,g:^Editor_Ui,world:core.World_Ref,app:^host.App) {
    started:=platform.clock_ns();defer api_timed(s,.Panels,started)
    if !g.begun {return}
    shell_build(s,world)
}

// Escape closes what is on top: a dialog with what it asks about, then the
// gestures, panels and tools, then the run, then the selection.
escape_run :: proc(s:^Session,g:^Editor_Ui,v:^Viewport,selection:^history.Selection) {
    switch {
    case g.modal==.Recovery:
    case g.modal==.Confirm:   confirm_resolve(s,.Cancel)
    case g.modal!=.None:      modal_close(g)
    case s.projects!=nil && s.projects.creating: s.projects.creating=false
    case s.projects!=nil && s.projects.shown:    projects_hide(s)
    case v.pick.active:       v.pick={}
    case s.edits.preview:     tools_release(s)
    case g.placement.active:  g.placement={}
    case panel_shown(s.panels)!=nil: panel_show(s,s.panels,-1,false)
    case v.plugin_tool!=0 && !scene_covered(s) && len(selection.entities)==0: tool_leave(s)
    case s.mode!=.Edit || player_processes_view(s): command_run(s,"stop")
    case:                     command_run(s,"deselect")
    }
}

@(step="ui",stage="end")
editor_end :: proc(s:^Session,g:^Editor_Ui,v:^Viewport,selection:^history.Selection,edits:^history.Edits,world:core.World_Ref,app:^host.App) {
    started:=platform.clock_ns();defer api_timed(s,.End,started)
    if !g.begun {return}
    ctx:=g.ctx
    frame:=platform.input_frame(app.platform)
    viewport_drop(s,world)
    drag_chip(s,g)
    if ui.escape(ctx) {escape_run(s,g,v,selection)}
    inspector_sweep(s)
    // What is drawn over the scene waits while an asset document covers it.
    if !scene_covered(s) {
        highlight_sync(s,world)
        overlays_draw(s,world)
        grid_lines(s)
        output_frame_draw(s)
        ai_scene_draw(s,world)
        collab_draw(s)
        pings_draw(s)
        tools_lines(s,world)
    }
    ui_frame:=ui.frame_end(ctx)
    g.begun=false
    layer,_,panel_count,dropped:=host.ui_frame_convert(ui_frame,g.draws[:],g.panels[:])
    g.dropped+=u64(dropped)
    host.app_ui_font_sync(app,ctx)
    host.extras_ui_layer_add(&app.extras,layer)
    for panel in g.panels[:panel_count] {host.extras_world_panel_add(&app.extras,panel)}
    if v.lines.count>0 {host.extras_debug_lines_add(&app.extras,v.lines)}
    if edits.commit {sections_sync(s)}
    history.edits_flush(edits,world,selection)
    history.edits_select(edits,world,selection)
    preferences_update(s,ctx,frame.dt)
    files_settle(s)
    shell_after(s)
    dialogs_answer(s)
    if s.toast_seconds>0 {s.toast_seconds-=frame.dt}
    if g.drag.released {g.drag={}}
}
