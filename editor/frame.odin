package editor

import "core:fmt"
import "core:math"
import "core:reflect"
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

Action :: enum u8 {
    New,Open,Save,Save_All,Save_As,Build,Quit,
    Undo,Redo,Copy,Paste,Duplicate,Delete,Rename,Select_All,Deselect,Group,
    Tool_Move,Tool_Rotate,Tool_Scale,Space,Snap,
    Focus,Reset_Camera,Scene_Thumbnail,Grid,Indicators,Output_Frame,Game_Detail,Studio_Light,Hierarchy_Panel,Inspector_Panel,Console_Panel,Build_Panel,Library_Panel,
    Play,Play_From_Camera,Simulate,Apply_Simulation,Pause,Stop,Release_Input,
    Shortcuts,
    Find,Import,Ai_Chat,Source_Control,Graphics,Settings,Projects,
    Prefab_Create,Prefab_Apply,Prefab_Revert,Prefab_Unlink,Prefab_Apply_Base,
    Camera_Preview,Camera_Keep,Camera_Discard,
}

Shortcut :: struct {key:core.Key,modifiers:ui.Modifiers,set:bool}


ACTION_LABELS :: [Action]string{
    .New="New scene",.Open="Open...",.Save="Save",.Save_All="Save all",.Save_As="Save as...",.Build="Build",.Quit="Quit",
    .Undo="Undo",.Redo="Redo",.Copy="Copy",.Paste="Paste",.Duplicate="Duplicate",.Delete="Delete",.Rename="Rename",.Select_All="Select all",.Deselect="Deselect",.Group="Group selection",
    .Tool_Move="Move",.Tool_Rotate="Rotate",.Tool_Scale="Scale",.Space="Local axes",.Snap="Snap to grid",
    .Focus="Focus selection",.Reset_Camera="Reset camera",.Scene_Thumbnail="Update scene thumbnail",.Grid="Grid",.Indicators="Indicators",.Output_Frame="Output frame",.Game_Detail="Detail of the game camera",.Studio_Light="Studio light",
    .Hierarchy_Panel="Hierarchy",.Inspector_Panel="Details",.Console_Panel="Console",.Build_Panel="Build output",
    .Library_Panel="Content Browser",
    .Play="Play",.Play_From_Camera="Play from camera",.Pause="Pause",.Stop="Stop",.Release_Input="Release input",
    .Simulate="Simulate",.Apply_Simulation="Apply transforms",
    .Shortcuts="Keyboard shortcuts",
    .Find="Find object",.Import="Import...",.Ai_Chat="AI tasks",.Source_Control="Source control",.Graphics="Graphics",.Settings="Project settings",.Projects="Open project...",
    .Prefab_Create="Create prefab",.Prefab_Apply="Apply to prefab",.Prefab_Revert="Revert to prefab",.Prefab_Unlink="Unlink prefab",.Prefab_Apply_Base="Apply to base",
    .Camera_Preview="Preview camera",.Camera_Keep="Keep cameras",.Camera_Discard="Discard cameras",
}

// The icon of an action in the menus; .None: none.
action_icon :: proc(action:Action) -> ui.Icon {
    user :: proc(icon:User_Icon) -> ui.Icon {return ui.icon_user(u8(icon))}
    #partial switch action {
    case .New,.Open:       return user(.Scene)
    case .Save,.Save_All,.Save_As: return user(.Save)
    case .Build,.Build_Panel: return user(.Hammer)
    case .Import:          return .Import
    case .Settings:        return user(.Gear)
    case .Projects:        return user(.Folder)
    case .Quit:            return .Cross
    case .Undo:            return user(.Undo)
    case .Redo:            return user(.Redo)
    case .Copy,.Duplicate: return user(.Copy)
    case .Delete:          return user(.Trash)
    case .Rename:          return .Edit
    case .Group:           return .Group
    case .Find:            return user(.Search)
    case .Snap,.Grid:      return .Grid
    case .Space:           return .Relative
    case .Tool_Move:       return .Move
    case .Tool_Rotate:     return .Rotate
    case .Tool_Scale:      return .Scale
    case .Focus:           return .Focus
    case .Reset_Camera,.Scene_Thumbnail,.Output_Frame: return user(.Camera)
    case .Indicators:      return .Eye
    case .Studio_Light:    return .Sun
    case .Graphics,.Inspector_Panel: return user(.Graphics)
    case .Hierarchy_Panel: return user(.List)
    case .Library_Panel:   return .Layers
    case .Console_Panel:   return user(.Terminal)
    case .Ai_Chat: return .Sparkle
    case .Source_Control:  return user(.Branch)
    case .Play:            return .Play
    case .Play_From_Camera: return user(.Camera)
    case .Simulate:        return user(.Simulate)
    case .Pause:           return user(.Pause)
    case .Stop:            return .Stop
    case .Shortcuts:       return user(.Command)
    case .Prefab_Create:   return .Save_Prefab
    case .Prefab_Apply:    return .Prefab
    case .Prefab_Apply_Base: return user(.Up)
    case .Prefab_Revert:   return .Revert
    case .Prefab_Unlink:   return user(.Unlink)
    }
    return .None
}

@(rodata)
ACTION_SHORTCUTS := [Action]Shortcut{
    .New={.N,{.Primary},true},.Open={.O,{.Primary},true},.Save={.S,{.Primary},true},.Save_All={.S,{.Primary,.Shift},true},.Save_As={.S,{.Primary,.Alt},true},
    .Build={.B,{.Primary},true},.Quit={.Q,{.Primary},true},
    .Undo={.Z,{.Primary},true},.Redo={.Y,{.Primary},true},.Copy={.C,{.Primary},true},.Paste={.V,{.Primary},true},.Duplicate={.D,{.Primary},true},.Delete={.Delete,{},true},
    .Rename={.F2,{},true},.Select_All={.A,{.Primary},true},.Deselect={.Escape,{},true},.Group={.G,{.Primary},true},
    .Tool_Move={.W,{},true},.Tool_Rotate={.E,{},true},.Tool_Scale={.R,{},true},.Space={},.Snap={},
    .Focus={.F,{},true},.Reset_Camera={},.Scene_Thumbnail={},.Grid={},.Indicators={},.Output_Frame={},.Game_Detail={},.Studio_Light={},
    .Hierarchy_Panel={},.Inspector_Panel={},.Console_Panel={.Grave,{.Primary},true},.Build_Panel={},.Library_Panel={.Tab,{},true},
    .Play={.F5,{},true},.Play_From_Camera={},.Pause={.F6,{},true},.Stop={.F5,{.Shift},true},.Release_Input={.F1,{},true},
    .Simulate={},.Apply_Simulation={},
    .Shortcuts={},
    .Find={.Space,{},true},.Import={},.Ai_Chat={},.Source_Control={},.Graphics={},.Settings={},.Projects={},
    .Prefab_Create={},.Prefab_Apply={},.Prefab_Revert={},.Prefab_Unlink={},.Prefab_Apply_Base={},
    .Camera_Preview={},.Camera_Keep={},.Camera_Discard={},
}

// Second shortcuts: Ctrl+Shift+Z redoes, Backspace deletes.
@(rodata)
ACTION_ALTERNATES := #partial [Action]Shortcut{
    .Redo={.Z,{.Primary,.Shift},true},.Delete={.Backspace,{},true},
}

Action_State :: struct {
    label:string,  // instead of the label of the action
    disabled,checked:bool,
}

// What an action shows now. Disabled actions do nothing when run.
action_state :: proc(s:^Session,action:Action) -> (state:Action_State) {
    if s.gui!=nil && s.gui.modal==.Recovery && action!=.Quit {state.disabled=true;return}
    w:=shown_world(s)
    selected:=len(s.selection.entities)>0
    edit:=s.mode==.Edit
    if d:=asset_document_active(s);d!=nil {
        // An asset document in front: what acts on the scene waits for it.
        h:=&d.history
        #partial switch action {
        case .Save:
            state.disabled=!asset_document_dirty(s,d)
            return
        case .Undo:
            state.disabled=h.cursor==0 && !h.open
            if h.cursor>0 {state.label=fmt.tprintf("Undo %s",asset_history_undo_label(h))}
            return
        case .Redo:
            state.disabled=h.cursor>=len(h.steps)
            if !state.disabled {state.label=fmt.tprintf("Redo %s",asset_history_redo_label(h))}
            return
        case .Copy,.Paste,.Duplicate,.Delete,.Rename,.Select_All,.Deselect:
            state.disabled=action not_in asset_document_actions(s,d.kind)
            return
        case .Save_As,.Group,
             .Tool_Move,.Tool_Rotate,.Tool_Scale,.Space,.Snap,.Focus,.Reset_Camera,.Scene_Thumbnail,.Grid,.Indicators,.Output_Frame,.Game_Detail,.Studio_Light,
             .Play,.Play_From_Camera,.Simulate,.Apply_Simulation,.Pause,.Release_Input,.Find,
             .Prefab_Create,.Prefab_Apply,.Prefab_Revert,.Prefab_Unlink,.Prefab_Apply_Base:
            state.disabled=true
            return
        case .Graphics:
            if asset_document_flat(s,d.kind) {state.disabled=true;return}
        }
    }
    #partial switch action {
    case .Save,.Save_All,.Save_As,.New,.Open: state.disabled=!edit
    case .Build:
        state.disabled=!s.has_project || s.engine_root==""
        #partial switch s.build.phase {
        case .Running:         state.label,state.disabled="Building...",true
        case .Failed:          state.label="Build *"
        }
    case .Undo:
        state.disabled=!edit || history.undo_label(s.edits)=="" && !s.edits.preview
        if s.edits.preview {state.label="Cancel preview"} else if !state.disabled {state.label=fmt.tprintf("Undo %s",history.undo_label(s.edits))}
    case .Redo:
        state.disabled=!edit || history.redo_label(s.edits)==""
        if !state.disabled {state.label=fmt.tprintf("Redo %s",history.redo_label(s.edits))}
    case .Deselect,.Focus: state.disabled=!selected
    case .Scene_Thumbnail: state.disabled=!edit || !scene_thumbnail_takes(s)
    case .Copy: state.disabled=!selected || !edit
    case .Paste: state.disabled=!edit || watching(s) || len(s.copied)==0
    case .Duplicate,.Delete,.Group: state.disabled=!selected || watching(s)
    case .Rename: state.disabled=len(s.selection.entities)!=1 || watching(s)
    case .Select_All: state.disabled=core.world_entities(w).alive==0
    // While a plugin tool that lends the scene to them holds it, none is on.
    case .Tool_Move:   state.checked=s.viewport.tool==.Move && !lender_holding(s.viewport)
    case .Tool_Rotate: state.checked=s.viewport.tool==.Rotate && !lender_holding(s.viewport)
    case .Tool_Scale:  state.checked=s.viewport.tool==.Scale && !lender_holding(s.viewport)
    case .Space:       state.checked=s.viewport.space==.Local
    case .Snap:        state.checked=snapping(s.viewport,.Move)
    case .Grid:        state.checked=s.viewport.show_grid
    case .Indicators:  state.checked=s.viewport.show_indicators
    case .Output_Frame: state.checked=s.viewport.show_output_frame
    case .Game_Detail: state.checked=s.viewport.game_detail
    case .Studio_Light: state.disabled,state.checked=document_is_prefab(s) || playing(s),s.viewport.studio_light
    case .Hierarchy_Panel: state.checked=s.gui.layout.left_open && s.gui.layout.library_tab==.Hierarchy
    case .Library_Panel:   state.checked=s.gui.layout.left_open
    case .Inspector_Panel: state.checked=s.gui.layout.right_open
    case .Console_Panel:   state.checked=s.gui.layout.bottom_open && s.gui.layout.bottom_tab==.Console
    case .Build_Panel:     state.checked=s.gui.layout.bottom_open && s.gui.layout.bottom_tab==.Build
    case .Play,.Play_From_Camera,.Simulate: state.disabled=s.mode!=.Edit || play_plugin_active(s)
    case .Apply_Simulation: state.disabled=!simulating(s) || !selected
    case .Pause:
        state.disabled=s.mode==.Edit || s.mode==.Watch
        if play_paused(s) {state.label="Resume"}
    case .Stop:  state.disabled=s.mode==.Edit && !play_plugin_active(s)
    case .Release_Input: state.disabled=!player_processes_captured(s) && (s.mode!=.Play || s.play_input_released)
    case .Import:    state.disabled=!edit || s.app.assets==nil
    case .Ai_Chat:   state.disabled,state.checked=s.mode==.Play,ai_chat_open(s.ai) && (s.gui.layout.left_open || play_shown(s))
    case .Source_Control: state.disabled=!s.has_project;state.checked=s.gui.layout.left_open && s.gui.layout.library_tab==.Git
    case .Projects:  state.disabled=s.mode!=.Edit || s.engine_root=="" || s.projects==nil
    case .Graphics:  state.checked=ui.popup_is_open(s.gui.ctx,graphics_popup(s.gui))
    case .Settings:  state.disabled=!s.has_project || s.mode!=.Edit; state.checked=s.gui.modal==.Settings
    case .Prefab_Create,.Prefab_Apply,.Prefab_Revert,.Prefab_Unlink,.Prefab_Apply_Base: state.disabled=prefab_action_disabled(s,action)
    case .Camera_Preview: state.disabled=!edit || camera_preview_target(s,w)==core.NONE
    case .Camera_Keep,.Camera_Discard: state.disabled=!camera_previewing(s)
    }
    return
}

// Play as the toolbar does; a plugin may take it for a game of its own
// (multiplayer: one on the network). asked: player 1 at Session.play_asked,
// whatever the toolbar runs.
play_request :: proc(s:^Session,asked:=false) {
    taken,error:=false,""
    if s.mode==.Edit && (asked || s.gui.layout.run_kind==.Play) {taken,error=play_plugin_start(s,-1,-1,false)}
    if error!="" {
        notify(s,error)
        s.play_asked={}
    } else if !taken {s.requests+={.Play}}
}

// Runs an action as its menu entry does. False when it is disabled.
action_run :: proc(s:^Session,action:Action) -> bool {
    if action_state(s,action).disabled {return false}
    event(s,"action",reflect.enum_string(action))
    if s.edits.preview {
        #partial switch action {
        case .Undo,.Deselect:
            tools_release(s)
            return true
        case .New,.Open,.Save,.Save_All,.Save_As,.Build,.Quit,.Redo,.Paste,.Duplicate,.Delete,.Rename,.Select_All,.Group,
             .Tool_Move,.Tool_Rotate,.Tool_Scale,.Play,.Play_From_Camera,.Simulate,.Find,
             .Prefab_Create,.Prefab_Apply,.Prefab_Revert,.Prefab_Unlink,.Prefab_Apply_Base:
            tools_release(s)
        }
    }
    w:=shown_world(s)
    v:=s.viewport
    g:=s.gui
    document:=asset_document_active(s)
    // The plugin of the document in front runs what its documents take.
    if document!=nil && action in asset_document_actions(s,document.kind) {
        document.request=action
        document.request_serial+=1
        return true
    }
    switch action {
    case .New:        file_new(s)
    case .Open:       file_open(s)
    case .Save:       if document!=nil {asset_document_save(s)} else {save_request(s)}
    case .Save_All:   save_all(s)
    case .Save_As:    dialog_save(s)
    case .Build:      build_start(s)
    case .Quit:       quit_request(s)
    case .Undo:
        tools_release(s)
        if document!=nil {
            h:=&document.history
            if asset_history_undo(h) {notify(s,fmt.tprintf("Undo %s",history.cstring_text(h.steps[h.cursor].label[:])))}
        } else if text:=history_text(history_undo(s),"Undo");text!="" {notify(s,text)}
    case .Redo:
        tools_release(s)
        if document!=nil {
            h:=&document.history
            if asset_history_redo(h) {notify(s,fmt.tprintf("Redo %s",history.cstring_text(h.steps[h.cursor-1].label[:])))}
        } else if text:=history_text(history_redo(s),"Redo");text!="" {notify(s,text)}
    case .Copy:       selection_copy(s,w)
    case .Paste:
        sources:=copied_entities(s,w)
        if len(sources)==0 {notify(s,"Nothing to paste: the copied entities are not in this scene");break}
        if copies:=entities_duplicate(s,sources,"Paste");len(copies)>0 {history.selection_set(s.selection,copies)}
    case .Duplicate:
        copies:=entities_duplicate(s,history.selection_roots(s.selection,w))
        history.selection_set(s.selection,copies)
    case .Delete:     entities_delete(s,history.selection_roots(s.selection,w))
    case .Rename:
        g.layout.right_open=true
        s.inspector.rename=true
    case .Select_All:
        all:=make([dynamic]core.Entity,context.temp_allocator)
        items:=scene_items(s,w)
        for item in scene_item_next(&items) {if entity_author(w,item.entity)==item.entity {append(&all,item.entity)}}
        history.selection_set(s.selection,all[:])
    case .Deselect:   history.selection_clear(s.selection)
    case .Group:      selection_group(s,w)
    case .Tool_Move:   gizmo_mode(s,.Move)
    case .Tool_Rotate: gizmo_mode(s,.Rotate)
    case .Tool_Scale:  gizmo_mode(s,.Scale)
    case .Space:       v.space=v.space==.World?.Local:.World
    case .Snap:        if snapping(v,.Move) {v.snap=false} else {v.snap,v.snap_off=true,false}
    case .Focus:       focus_selection(s,w)
    case .Reset_Camera:
        v.orbit=ORBIT_DEFAULT
        s.view_cut=true
    case .Scene_Thumbnail:
        thumbnail_scene_take(s,s.document.id,0,true)
    case .Grid:        v.show_grid=!v.show_grid
    case .Indicators:  v.show_indicators=!v.show_indicators
    case .Output_Frame: v.show_output_frame=!v.show_output_frame
    case .Game_Detail: v.game_detail=!v.game_detail
    case .Studio_Light: v.studio_light=!v.studio_light
    case .Hierarchy_Panel:
        if g.layout.left_open && g.layout.library_tab==.Hierarchy {library_select(s,.Editor)} else {library_select(s,.Hierarchy)}
    case .Library_Panel:   g.layout.left_open=!g.layout.left_open
    case .Inspector_Panel: g.layout.right_open=!g.layout.right_open
    case .Console_Panel:   bottom_toggle(g,.Console)
    case .Build_Panel:     bottom_toggle(g,.Build)
    case .Play: play_request(s)
    case .Play_From_Camera:
        s.play_asked=camera_origin(s)
        s.play_asked.asked=true
        play_request(s,true)
    case .Simulate: s.requests+={.Simulate}
    case .Camera_Preview:
        s.camera_run.request=camera_preview_target(s,w)
        s.requests+={.Camera_Preview}
    case .Camera_Keep: s.requests+={.Camera_Keep}
    case .Camera_Discard: s.requests+={.Camera_Discard}
    case .Apply_Simulation: s.requests+={.Apply_Simulation}
    case .Pause: s.requests+=play_paused(s)?{.Resume}:{.Pause}
    case .Stop:  s.requests+={.Stop}
    case .Release_Input: if player_processes_captured(s) {player_processes_release(s)} else {play_release_input(s)}
    case .Shortcuts:
        ui.popup_close(g.ctx)
        g.modal,g.modal_scroll=.Shortcuts,0
    case .Settings:
        ui.popup_close(g.ctx)
        g.modal,g.modal_scroll=.Settings,0
        s.settings_dialog.scroll,s.settings_dialog.jump=0,-1
        settings_layer_set(s,.Project)
        settings_engine_load(s)
        settings_plugins_load(s)
        input_settings_load(s)
        settings_project_load(s)
    case .Find:       finder_open(s)
    case .Import:     import_ask(s)
    case .Projects:   projects_show(s)
    case .Ai_Chat:
        // A chat folded with its panel comes back with it instead of closing.
        if play_shown(s) {play_chat_set(s,!s.play_chat_open)} else if ai_chat_open(s.ai) && !s.gui.layout.left_open {s.gui.layout.left_open=true} else {ai_chat_toggle(s.ai)}
    case .Source_Control:
        g.layout.left_open=true
        library_select(s,.Git)
    case .Graphics:
        anchor,_:=ui.widget_rect(g.ctx,shell_id(g,"graphics"))
        ui.popup_open(g.ctx,graphics_popup(g),anchor)
    case .Prefab_Create,.Prefab_Apply,.Prefab_Revert,.Prefab_Unlink,.Prefab_Apply_Base:
        prefab_action_run(s,action)
    }
    return true
}

// Puts the selected roots under a new group at their center, as one step.
selection_group :: proc(s:^Session,w:core.World_Ref) {
    roots:=history.selection_roots(s.selection,w)
    if len(roots)==0 {return}
    center:[3]f32
    for e in roots {center+=entity_world(w,e).position}
    center/=f32(len(roots))
    opened,edit_ready:=edit_open(s,"Group")
    if !edit_ready {return}
    defer edit_close(s,opened)
    parent:=entity_parent(w,roots[0])
    for e in roots[1:] {
        if entity_parent(w,e)!=parent {parent=core.NONE;break}
    }
    group:=entity_create(s,{preset=.Empty,parent=parent,transform={position=center,rotation=1,scale={1,1,1}}})
    // The group exists once settled: its children are placed relative to where it will be.
    core.world_settle(w)
    for e in roots {entity_reparent(s,e,group)}
    history.selection_set(s.selection,{group})
}

@(private)
shortcut_pressed :: proc "contextless" (keys:core.Keys,modifiers:ui.Modifiers,s:Shortcut) -> bool {
    return s.set && s.key in keys && modifiers==s.modifiers
}

// The keys of the frame as the shortcuts of actions. Escape is the last
// thing that runs in a frame: deselect only when nothing else used it.
@(private)
shortcuts_run :: proc(s:^Session,keys:core.Keys,modifiers:ui.Modifiers) {
    keys:=keys
    // The keys the plugin tool that is on takes are its own.
    if s.viewport!=nil && s.viewport.plugin_tool!=0 {keys-=s.viewport.plugin_keys}
    if keys=={} {return}
    // Space plays and stops the strip of the past while it is shown.
    if r:=play_strip_run(s);r!=nil && .Space in keys && modifiers=={} {
        play_strip_toggle(s,r)
        keys-={.Space}
    }
    shortcuts,alternates:=ACTION_SHORTCUTS,ACTION_ALTERNATES
    // The keys of Delete, Rename and Duplicate on a card of the browser act on
    // its asset, not on the selected entities.
    if s.gui!=nil && s.gui.ctx!=nil {
        if id:=content_focused(s.content,s.gui.ctx);id!={} {
            for action in ([3]Action{.Delete,.Rename,.Duplicate}) {
                if !shortcut_pressed(keys,modifiers,shortcuts[action]) && !shortcut_pressed(keys,modifiers,alternates[action]) {continue}
                if s.mode!=.Edit || watching(s) {return}
                #partial switch action {
                case .Delete:    asset_delete_ask(s,id)
                case .Rename:    content_rename_begin(s,id)
                case .Duplicate: content_duplicate(s,id)
                }
                return
            }
        }
    }
    for action in Action {
        if action==.Deselect {continue}
        if shortcut_pressed(keys,modifiers,shortcuts[action]) || shortcut_pressed(keys,modifiers,alternates[action]) {
            if play_shown(s) && action==.Library_Panel {continue}
            // The key of Play stops what plays.
            if action==.Play && (s.mode!=.Edit || play_plugin_active(s)) {
                action_run(s,.Stop)
                continue
            }
            // While a game runs the keys are its own, but those of Play.
            if (s.mode==.Play || player_processes_captured(s)) && action!=.Pause && action!=.Stop && action!=.Release_Input {continue}
            action_run(s,action)
        }
    }
}

// The text of a shortcut: "Ctrl+Shift+S".
shortcut_text :: proc(s:Shortcut,allocator:=context.temp_allocator) -> string {
    if !s.set {return ""}
    primary:="Cmd+" when ODIN_OS==.Darwin else "Ctrl+"
    key:=fmt.tprint(s.key)
    #partial switch s.key {
    case .Grave:     key="`"
    case .Delete:    key="Del"
    case .Backspace: key="Backspace"
    case .Escape:    key="Esc"
    }
    return fmt.aprintf("%s%s%s%s",.Primary in s.modifiers?primary:"",.Shift in s.modifiers?"Shift+":"",.Alt in s.modifiers?"Alt+":"",key,allocator=allocator)
}

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
    bars:=ctx.theme.bar_height+toolbar_height(g)
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
    case s.mode!=.Edit || player_processes_view(s): s.requests+={.Stop}
    case:                     history.selection_clear(selection)
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
