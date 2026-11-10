package editor

import "core:fmt"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// One catalog of commands: the methods of the API. A menu entry, a shortcut
// and a button of the bar are an entry (Binding): the name of a method, its
// params, and how the entry looks. What a command does lives in its method,
// which a person and an agent run alike: its undo, its errors and what it
// refuses are the same for both. A plugin gives its methods entries the same
// way (Api_Method.entry, command_bind, tool_entry).
//
// What is a command: whatever has a menu entry, a shortcut or a button. What a
// person does inside a panel with the pointer or the keyboard focus (a scroll,
// a hover, a fold, a splitter, a field being typed, the keys a focused card or
// an asset document takes) is the view of that panel and has no method.
//
// The params of an entry name what the person has in front in place of
// values, which the editor puts there when the gesture runs:
//   "$roots", "$selection", "$active", "$copied", "$all"   entities (api_entity_select.odin)
//   "$toggle"       true when the entry is not checked, false when it is
//   "$toggle:A:B"   "A" when the entry is not checked, "B" when it is
//   "$ask"          the method asks the person, with a dialog of the system
// The gestures of a frame run between frames, where the calls of agents run.

COMMAND_ASK :: "$ask"
COMMAND_TOGGLE :: `"$toggle`
BINDING_CAPACITY :: 160
COMMAND_QUEUE :: 16
COMMAND_PARAMS :: 512 // bytes of the params of a gesture
COMMAND_TEXT :: 8192  // bytes of the params the entries are given that are not constants

Shortcut :: struct {key:core.Key,modifiers:ui.Modifiers,set:bool}

// What an entry shows now, for the person at the editor.
Command_State :: struct {
    label:string,  // instead of the label of the entry
    detail:string, // after its label, in a menu: what Undo undoes
    disabled,checked:bool,
}
Command_State_Proc :: #type proc(s:^Session,b:^Binding) -> Command_State

Menu :: enum u8 {
    None,
    File,  // the menu of the mark
    View,
    Tools, // the tools of the plugins, in the menu of the bar
}

// A menu shows its entries by group, a line between two, and those of a
// group in the order they were given. The panels of the plugins go in
// MENU_GROUP_PLUGINS of View.
MENU_GROUPS :: 8
MENU_GROUP_PLUGINS :: 3

Binding :: struct {
    name:string,   // what command_run, the buttons and editor.inspect name it by; the name of its method when empty
    method:string,
    params:string, // JSON; "": none
    label:string,
    icon:ui.Icon,
    shortcut,alternate:Shortcut,
    menu:Menu,
    group:u8,      // of its menu, under MENU_GROUPS
    state:Command_State_Proc, // nil: always on, never checked
    scene:bool,    // it works on the scene: off while an asset document covers it
    in_game:bool,  // its shortcut runs while a game has the keys
}

@(private)
Command_Asked :: struct {
    method:string,
    params:[COMMAND_PARAMS]u8,
    length:int,
}

Commands :: struct {
    bindings:[BINDING_CAPACITY]Binding,
    count:int,
    asked:[COMMAND_QUEUE]Command_Asked, // the gestures of the frame, until commands_run
    asked_count:int,
    running:bool,
    text:[COMMAND_TEXT]u8, // the params of the entries that are worked out when they are given
    text_used:int,
}

// A text of an entry that is not a constant, kept while the entries are.
@(private)
command_text :: proc(st:^Api_State,format:string,args:..any) -> string {
    c:=&st.commands
    // Without room for the longest params it gives none: the entry it was for is refused.
    if len(c.text)-c.text_used<COMMAND_PARAMS {return ""}
    text:=fmt.bprintf(c.text[c.text_used:],format,..args)
    c.text_used+=len(text)
    return text
}

// Gives a method an entry. The texts stay where they are: constants of the
// editor or of a library, which stays loaded. False when it does not fit or
// its name is taken.
command_bind :: proc(s:^Session,b:Binding) -> bool {
    st:=api_state(s)
    if st==nil || b.method=="" {return false}
    c:=&st.commands
    entry:=b
    if entry.name=="" {entry.name=entry.method}
    if c.count>=len(c.bindings) || binding_find(c,entry.name)!=nil {return false}
    c.bindings[c.count]=entry
    c.count+=1
    return true
}

// The entry of a tool of a plugin in the Tools menu, by the name it turns on
// with (tool_set): editor.tool turns it on and off, for a person and an agent.
tool_entry :: proc(s:^Session,name,label:string,icon:ui.Icon,shortcut:=Shortcut{}) -> bool {
    st:=api_state(s)
    if st==nil {return false}
    params:=command_text(st,`{{"tool":%q,"on":"$toggle"}}`,name)
    if params=="" {return false}
    return command_bind(s,{
        name=name,method="editor.tool",params=params,
        label=label,icon=icon,shortcut=shortcut,menu=.Tools,state=tool_entry_state,scene=true,
    })
}

@(private)
tool_entry_state :: proc(s:^Session,b:^Binding) -> Command_State {
    return {checked=tool_on(s,b.name),disabled=playing(s)}
}

@(private)
binding_find :: proc(c:^Commands,name:string) -> ^Binding {
    for &b in c.bindings[:c.count] {
        if b.name==name {return &b}
    }
    return nil
}

// The entry of a name; nil without one, or before the methods are registered.
command_binding :: proc(s:^Session,name:string) -> ^Binding {
    st:=api_state(s)
    return st==nil?nil:binding_find(&st.commands,name)
}

// The entries, in the order they were given.
command_bindings :: proc(s:^Session) -> []Binding {
    st:=api_state(s)
    return st==nil?nil:st.commands.bindings[:st.commands.count]
}

// What an entry shows now. One that names no method is off.
command_state :: proc(s:^Session,name:string) -> Command_State {
    b:=command_binding(s,name)
    if b==nil {return {disabled=true}}
    return binding_state(s,b)
}

binding_state :: proc(s:^Session,b:^Binding) -> (state:Command_State) {
    if s.gui!=nil && s.gui.modal==.Recovery && b.name!="quit" {return {disabled=true}}
    // An asset document in front: what acts on the scene waits for it, but
    // what its plugin takes in its place.
    if d:=asset_document_active(s);d!=nil && b.scene {return {disabled=!asset_document_takes(s,d.kind,b.name)}}
    if b.state!=nil {state=b.state(s,b)}
    return
}

command_label :: proc(s:^Session,name:string) -> string {
    b:=command_binding(s,name)
    return b!=nil?b.label:""
}

command_icon :: proc(s:^Session,name:string) -> ui.Icon {
    b:=command_binding(s,name)
    return b!=nil?b.icon:.None
}

command_shortcut_text :: proc(s:^Session,name:string,allocator:=context.temp_allocator) -> string {
    b:=command_binding(s,name)
    return b!=nil?shortcut_text(b.shortcut,allocator):""
}

// Runs an entry as its menu or its shortcut does: between frames, like the
// call of an agent. False when it is off or names nothing.
command_run :: proc(s:^Session,name:string) -> bool {
    b:=command_binding(s,name)
    if b==nil {return false}
    state:=binding_state(s,b)
    if state.disabled {return false}
    event(s,"command",b.name)
    // The plugin of the document in front runs what its documents take.
    if d:=asset_document_active(s);d!=nil && b.scene {
        d.request=b.name
        d.request_serial+=1
        return true
    }
    params:=strings.builder_make(context.temp_allocator)
    binding_params(&params,b.params,state.checked)
    return command_call(s,b.method,strings.to_string(params))
}

// Runs a method as the person at the editor, with params the interface
// worked out (a point of the scene, a path): between frames. False when the
// gestures of the frame do not fit.
command_call :: proc(s:^Session,method,params:string) -> bool {
    st:=api_state(s)
    if st==nil {return false}
    c:=&st.commands
    if c.asked_count>=len(c.asked) || len(params)>COMMAND_PARAMS {
        notify(s,len(params)>COMMAND_PARAMS?"The params of that gesture are too long":"Too much was asked of the editor in one frame")
        return false
    }
    asked:=&c.asked[c.asked_count]
    asked.method=method
    asked.length=copy(asked.params[:],params)
    c.asked_count+=1
    return true
}

// Runs a method now, as the person at the editor, inside the gesture that is open: what it edits
// is part of the step of the gesture (the key the Tracks tool writes as the gizmo lets go). False
// when there is no API.
command_join :: proc(s:^Session,method,params:string) -> bool {
    st:=api_state(s)
    if st==nil {return false}
    command_execute(s,st,method,params)
    return true
}

// The params of an entry with what it shows now in place of "$toggle".
@(private)
binding_params :: proc(b:^strings.Builder,params:string,checked:bool) {
    rest:=params
    for {
        at:=strings.index(rest,COMMAND_TOGGLE)
        if at<0 {break}
        strings.write_string(b,rest[:at])
        rest=rest[at+len(COMMAND_TOGGLE):]
        close:=strings.index_byte(rest,'"')
        if close<0 {break}
        choices:=rest[:close]
        rest=rest[close+1:]
        if choices=="" {
            strings.write_string(b,checked?"false":"true")
            continue
        }
        // ":A:B"
        first,_,second:=strings.partition(strings.trim_prefix(choices,":"),":")
        fmt.sbprintf(b,"%q",checked?second:first)
    }
    strings.write_string(b,rest)
    if strings.builder_len(b^)==0 {strings.write_string(b,"{}")}
}

// Between frames: what the gestures of the frame asked for, in their order.
// A handler that runs frames leaves the gestures of those to this one.
commands_run :: proc(s:^Session) {
    st:=api_state(s)
    if st==nil || st.commands.running || st.commands.asked_count==0 {return}
    c:=&st.commands
    c.running=true
    defer c.running=false
    for at:=0;at<c.asked_count;at+=1 {
        asked:=c.asked[at]
        command_execute(s,st,asked.method,string(asked.params[:asked.length]))
    }
    c.asked_count=0
}

// One call of the person: the handler of the method, through what every
// call goes through. What it refuses is said in a notice.
@(private)
command_execute :: proc(s:^Session,st:^Api_State,name,params:string) {
    method:=api.method_find(&st.server,name)
    if method==nil {
        notify(s,fmt.tprintf("No method is named %s",name))
        return
    }
    // Inside a call of an agent that runs frames its scratch is in use.
    scratch:=&st.server.scratch
    mark:=base.arena_mark(scratch)
    if st.in_call==0 {
        base.arena_reset(scratch)
        st.poll_temp=context.temp_allocator
    }
    defer if st.in_call>0 {base.arena_rewind(scratch,mark)}
    answer:[1024]u8
    out:serial.Writer
    serial.writer_init_fixed(&out,answer[:])
    // Inside a call of an agent the server holds whose it is: this one is of nobody's turn.
    server:=&st.server
    was,tag,client:=st.person,server.client_tag,server.client_name
    st.person,st.left_going=true,false
    server.client_tag,server.client_name="",""
    error,ok:=api.method_execute(server,method,params,&out)
    st.person,server.client_tag,server.client_name=was,tag,client
    if !ok && !st.left_going && error.message!="" {notify(s,error.message)}
}

// ---------------------------------------------------------------- keys

@(private)
shortcut_pressed :: proc "contextless" (keys:core.Keys,modifiers:ui.Modifiers,s:Shortcut) -> bool {
    return s.set && s.key in keys && modifiers==s.modifiers
}

// The keys of the frame as the shortcuts of the entries. Escape is the last
// thing that runs in a frame (escape_run): only when nothing else used it.
@(private)
shortcuts_run :: proc(s:^Session,keys:core.Keys,modifiers:ui.Modifiers) {
    keys:=keys-{.Escape}
    // The keys the plugin tool that is on takes are its own.
    if s.viewport!=nil && s.viewport.plugin_tool!=0 {keys-=s.viewport.plugin_keys}
    if keys=={} {return}
    // Space plays and stops the strip of the past while it is shown.
    if r:=play_strip_run(s);r!=nil && .Space in keys && modifiers=={} {
        play_strip_toggle(s,r)
        keys-={.Space}
    }
    // The keys of Delete, Rename and Duplicate on a card of the browser act on
    // its asset, not on the selected entities.
    if s.gui!=nil && s.gui.ctx!=nil {
        if id:=content_focused(s.content,s.gui.ctx);id!={} {
            for name in ([3]string{"delete","rename","duplicate"}) {
                b:=command_binding(s,name)
                if b==nil || !shortcut_pressed(keys,modifiers,b.shortcut) && !shortcut_pressed(keys,modifiers,b.alternate) {continue}
                if s.mode!=.Edit || watching(s) {return}
                switch name {
                case "delete":    asset_delete_ask(s,id)
                case "rename":    content_rename_begin(s,id)
                case "duplicate": content_duplicate(s,id)
                }
                return
            }
        }
    }
    game:=s.mode==.Play || player_processes_captured(s)
    for &b in command_bindings(s) {
        if !shortcut_pressed(keys,modifiers,b.shortcut) && !shortcut_pressed(keys,modifiers,b.alternate) {continue}
        // While a game runs the keys are its own, but those of Play.
        if game && !b.in_game {continue}
        if play_shown(s) && b.name=="library_panel" {continue}
        command_run(s,b.name)
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

// ---------------------------------------------------------------- the entries of the editor

@(private)
commands_register :: proc(s:^Session,st:^Api_State) {
    commands_methods_register(s,st)
    user :: proc(icon:User_Icon) -> ui.Icon {return ui.icon_user(u8(icon))}
    key :: proc(k:core.Key,modifiers:ui.Modifiers={}) -> Shortcut {return {k,modifiers,true}}
    preference :: proc(st:^Api_State,area,fields:string) -> string {
        return command_text(st,`{{"preferences":{{%q:{{%s}}}}}}`,area,fields)
    }
    reset:=ORBIT_DEFAULT
    entries:=[?]Binding{
        {name="new",method="scene.new",label="New scene",icon=user(.Scene),shortcut=key(.N,{.Primary}),menu=.File,group=0,state=state_editing},
        {name="open",method="editor.document",params=`{"action":"Open","path":"$ask"}`,label="Open...",icon=user(.Scene),shortcut=key(.O,{.Primary}),menu=.File,group=0,state=state_editing},
        {name="projects",method="editor.view",params=`{"part":"Projects"}`,label="Open project...",icon=user(.Folder),menu=.File,group=0,state=state_projects},
        {name="save",method="scene.save",label="Save",icon=user(.Save),shortcut=key(.S,{.Primary}),menu=.File,group=1,state=state_save},
        {name="save_all",method="editor.save_all",label="Save all",icon=user(.Save),shortcut=key(.S,{.Primary,.Shift}),menu=.File,group=1,state=state_editing},
        {name="save_as",method="scene.save",params=`{"path":"$ask"}`,label="Save as...",icon=user(.Save),shortcut=key(.S,{.Primary,.Alt}),menu=.File,group=1,state=state_editing,scene=true},
        {name="import",method="asset.import",params=`{"path":"$ask"}`,label="Import...",icon=.Import,menu=.File,group=2,state=state_import},
        {name="build",method="build.start",label="Build",icon=user(.Hammer),shortcut=key(.B,{.Primary}),menu=.File,group=3,state=state_build},
        {name="settings",method="editor.view",params=`{"part":"Settings"}`,label="Project settings",icon=user(.Gear),menu=.File,group=3,state=state_settings},
        {name="quit",method="engine.shutdown",label="Quit",icon=.Cross,shortcut=key(.Q,{.Primary}),menu=.File,group=4},

        {name="undo",method="history.undo",label="Undo",icon=user(.Undo),shortcut=key(.Z,{.Primary}),state=state_undo},
        {name="redo",method="history.redo",label="Redo",icon=user(.Redo),shortcut=key(.Y,{.Primary}),alternate=key(.Z,{.Primary,.Shift}),state=state_redo},
        {name="copy",method="editor.copy",params=`{"entities":["$roots"]}`,label="Copy",icon=user(.Copy),shortcut=key(.C,{.Primary}),state=state_copy,scene=true},
        {name="paste",method="scene.write",params=`{"merge":true,"entities":[{"copy":"$copied"}]}`,label="Paste",shortcut=key(.V,{.Primary}),state=state_paste,scene=true},
        {name="duplicate",method="scene.write",params=`{"merge":true,"entities":[{"copy":"$roots"}]}`,label="Duplicate",icon=user(.Copy),shortcut=key(.D,{.Primary}),state=state_scene_edit,scene=true},
        {name="delete",method="scene.write",params=`{"root":"$roots","merge":true,"entities":[{"delete":true}]}`,label="Delete",icon=user(.Trash),shortcut=key(.Delete),alternate=key(.Backspace),state=state_scene_edit,scene=true},
        // Of a game the editor shows: its entities are not those of the document.
        {name="delete_in_game",method="play.destroy",params=`{"entity":"$roots"}`,label="Delete",icon=user(.Trash),shortcut=key(.Delete),alternate=key(.Backspace),state=state_game_edit,scene=true},
        {name="rename",method="editor.view",params=`{"part":"Rename"}`,label="Rename",icon=.Edit,shortcut=key(.F2),state=state_rename,scene=true},
        {name="select_all",method="editor.select",params=`{"entities":["$all"]}`,label="Select all",shortcut=key(.A,{.Primary}),state=state_select_all,scene=true},
        {name="deselect",method="editor.select",label="Deselect",shortcut=key(.Escape),state=state_selected,scene=true},
        {name="group",method="scene.group",params=`{"entities":["$roots"]}`,label="Group selection",icon=.Group,shortcut=key(.G,{.Primary}),state=state_scene_edit,scene=true},

        {name="tool_move",method="editor.tool",params=`{"tool":"move"}`,label="Move",icon=.Move,shortcut=key(.W),state=state_gizmo,scene=true},
        {name="tool_rotate",method="editor.tool",params=`{"tool":"rotate"}`,label="Rotate",icon=.Rotate,shortcut=key(.E),state=state_gizmo,scene=true},
        {name="tool_scale",method="editor.tool",params=`{"tool":"scale"}`,label="Scale",icon=.Scale,shortcut=key(.R),state=state_gizmo,scene=true},
        {name="space",method="preferences.set",params=preference(st,"Viewport_Preferences",`"space":"$toggle:Local:World"`),label="Local axes",icon=.Relative,state=state_space,scene=true},
        {name="snap",method="preferences.set",params=preference(st,"Viewport_Preferences",`"snap":"$toggle","snap_off":false`),label="Snap to grid",icon=.Grid,state=state_snap,scene=true},

        {name="focus",method="camera.set",params=`{"frame":["$selection"]}`,label="Focus selection",icon=.Focus,shortcut=key(.F),menu=.View,group=0,state=state_selected,scene=true},
        {name="reset_camera",method="camera.set",params=command_text(st,`{{"target":[%v,%v,%v],"yaw":%v,"pitch":%v,"distance":%v,"fov":%v}}`,reset.target.x,reset.target.y,reset.target.z,reset.yaw,reset.pitch,reset.distance,reset.fov),label="Reset camera",icon=user(.Camera),menu=.View,group=0,scene=true},
        {name="scene_thumbnail",method="scene.thumbnail",label="Update scene thumbnail",icon=user(.Camera),menu=.View,group=0,state=state_scene_thumbnail,scene=true},
        {name="grid",method="preferences.set",params=preference(st,"Viewport_Preferences",`"show_grid":"$toggle"`),label="Grid",icon=.Grid,menu=.View,group=1,state=state_grid,scene=true},
        {name="indicators",method="preferences.set",params=preference(st,"Viewport_Preferences",`"show_indicators":"$toggle"`),label="Indicators",icon=.Eye,menu=.View,group=1,state=state_indicators,scene=true},
        {name="output_frame",method="preferences.set",params=preference(st,"Viewport_Preferences",`"show_output_frame":"$toggle"`),label="Output frame",icon=user(.Camera),menu=.View,group=1,state=state_output_frame,scene=true},
        {name="game_detail",method="preferences.set",params=preference(st,"Viewport_Preferences",`"game_detail":"$toggle"`),label="Detail of the game camera",menu=.View,group=1,state=state_game_detail,scene=true},
        {name="studio_light",method="editor.view",params=`{"part":"Studio_Light","on":"$toggle"}`,label="Studio light",icon=.Sun,menu=.View,group=1,state=state_studio_light,scene=true},
        {name="graphics",method="editor.view",params=`{"part":"Graphics"}`,label="Graphics",icon=user(.Graphics),menu=.View,group=1,state=state_graphics},
        {name="inspector_panel",method="preferences.set",params=preference(st,"Layout",`"right_open":"$toggle"`),label="Details",icon=user(.Graphics),menu=.View,group=2,state=state_inspector_panel},
        {name="console_panel",method="preferences.set",params=preference(st,"Layout",`"bottom_open":"$toggle","bottom_tab":"Console"`),label="Console",icon=user(.Terminal),shortcut=key(.Grave,{.Primary}),menu=.View,group=2,state=state_console_panel},
        {name="build_panel",method="preferences.set",params=preference(st,"Layout",`"bottom_open":"$toggle","bottom_tab":"Build"`),label="Build output",icon=user(.Hammer),menu=.View,group=2,state=state_build_panel},
        {name="library_panel",method="preferences.set",params=preference(st,"Layout",`"left_open":"$toggle"`),label="Content Browser",icon=.Layers,shortcut=key(.Tab),state=state_library_panel},
        {name="hierarchy_panel",method="editor.view",params=`{"part":"Hierarchy","on":"$toggle"}`,label="Hierarchy",icon=user(.List),state=state_hierarchy_panel},
        {name="source_control",method="editor.view",params=`{"part":"Git"}`,label="Source control",icon=user(.Branch),state=state_source_control},
        {name="ai_chat",method="editor.view",params=`{"part":"Chat","on":"$toggle"}`,label="AI tasks",icon=.Sparkle,state=state_ai_chat},
        {name="shortcuts",method="editor.view",params=`{"part":"Shortcuts"}`,label="Keyboard shortcuts",icon=user(.Command),menu=.View,group=MENU_GROUP_PLUGINS+1},
        {name="find",method="editor.view",params=`{"part":"Find"}`,label="Find object",icon=user(.Search),shortcut=key(.Space),scene=true},

        // The key of Play stops what plays, and that of Pause resumes it.
        {name="play",method="play.start",label="Play",icon=.Play,shortcut=key(.F5),state=state_play,scene=true},
        {name="play_from_camera",method="play.start",params=`{"from":"Camera"}`,label="Play from camera",icon=user(.Camera),state=state_play,scene=true},
        {name="simulate",method="play.start",params=`{"simulate":true}`,label="Simulate",icon=user(.Simulate),state=state_play,scene=true},
        {name="apply_simulation",method="simulation.apply",params=`{"entities":["$selection"]}`,label="Apply transforms",state=state_apply_simulation,scene=true},
        {name="pause",method="play.pause",params=`{"paused":true}`,label="Pause",icon=user(.Pause),shortcut=key(.F6),state=state_pause,scene=true,in_game=true},
        {name="resume",method="play.pause",params=`{"paused":false}`,label="Resume",icon=.Play,shortcut=key(.F6),state=state_resume,scene=true,in_game=true},
        {name="stop",method="play.stop",label="Stop",icon=.Stop,shortcut=key(.F5,{.Shift}),alternate=key(.F5),state=state_stop,in_game=true},
        {name="release_input",method="play.release",label="Release input",shortcut=key(.F1),state=state_release_input,scene=true,in_game=true},
        {name="camera_preview",method="camera.preview",params=`{"entity":"$active"}`,label="Preview camera",state=state_camera_preview,scene=true},
        {name="camera_keep",method="camera.preview",params=`{"end":"Keep"}`,label="Keep cameras",state=state_camera_previewing},
        {name="camera_discard",method="camera.preview",params=`{"end":"Discard"}`,label="Discard cameras",state=state_camera_previewing},

        {name="prefab_create",method="prefab.create",params=`{"entity":"$selection"}`,label="Create prefab",icon=.Save_Prefab,state=state_prefab,scene=true},
        {name="prefab_apply",method="prefab.apply",params=`{"entity":"$active"}`,label="Apply to prefab",icon=.Prefab,state=state_prefab,scene=true},
        {name="prefab_apply_base",method="prefab.apply",params=`{"entity":"$active","target":"Base"}`,label="Apply to base",icon=user(.Up),state=state_prefab,scene=true},
        {name="prefab_revert",method="prefab.revert",params=`{"entity":"$active"}`,label="Revert to prefab",icon=.Revert,state=state_prefab,scene=true},
        {name="prefab_unlink",method="prefab.unlink",params=`{"entity":"$active"}`,label="Unlink prefab",icon=user(.Unlink),state=state_prefab,scene=true},
    }
    for entry in entries {
        if !command_bind(s,entry) {api_refuse(st,fmt.tprintf("the entry %s did not fit: raise BINDING_CAPACITY in editor/commands.odin",entry.name))}
    }
    if s.has_project {tool_entry(s,AI_ANNOTATE_TOOL,"Annotate",ai_annotate_icon())}
}

// ---------------------------------------------------------------- what the entries show

@(private="file") state_editing :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode!=.Edit}}
@(private="file") state_selected :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=len(s.selection.entities)==0}}

@(private="file")
state_save :: proc(s:^Session,b:^Binding) -> Command_State {
    if d:=asset_document_active(s);d!=nil {return {disabled=!asset_document_dirty(s,d)}}
    return {disabled=s.mode!=.Edit}
}

@(private="file")
state_build :: proc(s:^Session,b:^Binding) -> (state:Command_State) {
    state.disabled=!s.has_project || s.engine_root==""
    #partial switch s.build.phase {
    case .Running: state.label,state.disabled="Building...",true
    case .Failed:  state.label="Build *"
    }
    return
}

// The label of an entry as a menu and editor.inspect show it now.
binding_label :: proc(b:^Binding,state:Command_State,allocator:=context.temp_allocator) -> string {
    label:=state.label!=""?state.label:b.label
    return state.detail!=""?fmt.aprintf("%s %s",label,state.detail,allocator=allocator):label
}

@(private="file")
state_undo :: proc(s:^Session,b:^Binding) -> (state:Command_State) {
    if d:=asset_document_active(s);d!=nil {
        h:=&d.history
        state.disabled=h.cursor==0 && !h.open
        if h.cursor>0 {state.detail=asset_history_undo_label(h)}
        return
    }
    state.disabled=s.mode!=.Edit || history.undo_label(s.edits)=="" && !s.edits.preview
    if s.edits.preview {state.label="Cancel preview"} else if !state.disabled {state.detail=history.undo_label(s.edits)}
    return
}

@(private="file")
state_redo :: proc(s:^Session,b:^Binding) -> (state:Command_State) {
    if d:=asset_document_active(s);d!=nil {
        h:=&d.history
        state.disabled=h.cursor>=len(h.steps)
        if !state.disabled {state.detail=asset_history_redo_label(h)}
        return
    }
    state.disabled=s.mode!=.Edit || history.redo_label(s.edits)==""
    if !state.disabled {state.detail=history.redo_label(s.edits)}
    return
}

@(private="file") state_copy :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=len(s.selection.entities)==0 || s.mode!=.Edit}}
@(private="file") state_paste :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode!=.Edit || len(s.copied)==0}}
// The methods of the scene write the document: a game the editor shows has its own.
@(private="file") state_scene_edit :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=len(s.selection.entities)==0 || playing(s)}}
@(private="file") state_game_edit :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=len(s.selection.entities)==0 || !playing(s) || watching(s)}}
@(private="file") state_rename :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=len(s.selection.entities)!=1 || watching(s)}}
@(private="file") state_select_all :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=core.world_entities(shown_world(s)).alive==0}}

// While a plugin tool that lends the scene to them holds it, none is on.
@(private="file")
state_gizmo :: proc(s:^Session,b:^Binding) -> Command_State {
    v:=s.viewport
    tool:=Tool.Move
    switch b.name {
    case "tool_rotate": tool=.Rotate
    case "tool_scale":  tool=.Scale
    }
    return {checked=v.tool==tool && !lender_holding(v)}
}

@(private="file") state_space :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.viewport.space==.Local}}
@(private="file") state_snap :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=snapping(s.viewport,.Move)}}
@(private="file") state_grid :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.viewport.show_grid}}
@(private="file") state_indicators :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.viewport.show_indicators}}
@(private="file") state_output_frame :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.viewport.show_output_frame}}
@(private="file") state_game_detail :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.viewport.game_detail}}
@(private="file") state_studio_light :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=document_is_prefab(s) || playing(s),checked=s.viewport.studio_light}}
@(private="file") state_scene_thumbnail :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode!=.Edit || !scene_thumbnail_takes(s)}}
@(private="file") state_hierarchy_panel :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.gui.layout.left_open && s.gui.layout.library_tab==.Hierarchy}}
@(private="file") state_library_panel :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.gui.layout.left_open}}
@(private="file") state_inspector_panel :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.gui.layout.right_open}}
@(private="file") state_console_panel :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.gui.layout.bottom_open && s.gui.layout.bottom_tab==.Console}}
@(private="file") state_build_panel :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.gui.layout.bottom_open && s.gui.layout.bottom_tab==.Build}}
@(private="file") state_play :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode!=.Edit || play_plugin_active(s)}}
@(private="file") state_apply_simulation :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=!simulating(s) || len(s.selection.entities)==0}}
@(private="file") state_pause :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode!=.Play && s.mode!=.Simulate}}
@(private="file") state_resume :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=!play_paused(s)}}
@(private="file") state_stop :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode==.Edit && !play_plugin_active(s)}}
@(private="file") state_release_input :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=!player_processes_captured(s) && (s.mode!=.Play || s.play_input_released)}}
@(private="file") state_import :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode!=.Edit || s.app.assets==nil}}
@(private="file") state_ai_chat :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode==.Play,checked=ai_chat_open(s.ai) && (s.gui.layout.left_open || play_shown(s))}}
@(private="file") state_source_control :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=!s.has_project,checked=s.gui.layout.left_open && s.gui.layout.library_tab==.Git}}
@(private="file") state_projects :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode!=.Edit || s.engine_root=="" || s.projects==nil}}
@(private="file") state_settings :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=!s.has_project || s.mode!=.Edit,checked=s.gui.modal==.Settings}}
@(private="file") state_camera_preview :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode!=.Edit || camera_preview_target(s,shown_world(s))==core.NONE}}
@(private="file") state_camera_previewing :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=!camera_previewing(s)}}
@(private="file") state_prefab :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=prefab_entry_disabled(s,b.name)}}

@(private="file")
state_graphics :: proc(s:^Session,b:^Binding) -> Command_State {
    if d:=asset_document_active(s);d!=nil && asset_document_flat(s,d.kind) {return {disabled=true}}
    return {checked=ui.popup_is_open(s.gui.ctx,graphics_popup(s.gui))}
}

// ---------------------------------------------------------------- the methods the entries of the editor needed

Api_Scene_New_Params :: struct {
    discard:bool `mirai:"optional,label=Drops the unsaved changes of the scene it takes the place of; without it they make it fail"`,
}

Api_Group_Params :: struct {
    entities:[64]Api_Entity_Text `mirai:"text,entity,label=The entities the group holds by name or path or id; it is made where they hang from when they share a parent and at the root otherwise"`,
}

Api_Copy_Params :: struct {
    entities:[64]Api_Entity_Text `mirai:"optional,text,entity,label=The entities Paste of the editor then duplicates; none forgets them"`,
}
Api_Copy_Result :: struct {copied:int}

Api_Tool_Params :: struct {
    tool:[32]u8 `mirai:"text,label=move rotate or scale: the mode of the gizmo; or the tool of a plugin by the name editor.inspect gives it in commands (paint or terrain or foliage)"`,
    on:bool `mirai:"optional,label=Of the tool of a plugin: false turns it off and gives the scene back to the gizmo"`,
}
Api_Tool_Result :: struct {
    tool:[8]u8 `mirai:"text,label=move rotate or scale"`,
    plugin_tool:[32]u8 `mirai:"text,label=The tool of a plugin that is on; empty when none is"`,
}

Api_View_Part :: enum u8 {Settings,Shortcuts,Projects,Graphics,Find,Chat,Git,Hierarchy,Rename,Studio_Light}
Api_View_Params :: struct {
    part:Api_View_Part `mirai:"label=What of the interface the person sees: the dialogs Settings and Shortcuts; the screen Projects; the popups Graphics and Find; the tabs Chat and Git and Hierarchy of the left panel; Rename the name field of Details for the selected entity; Studio_Light the light of the studio in the viewport in place of that of the scene (not saved and not in a Play). The panels and the options of the viewport that the editor remembers are preferences: preferences.set"`,
    on:bool `mirai:"optional,label=false closes or hides it; of Rename and Find and Projects only true"`,
}
Api_View_Result :: struct {
    on:bool `mirai:"label=Whether the part shows now"`,
}

Api_Save_All_Result :: struct {
    dirty:bool `mirai:"label=Whether a document still has unsaved changes: one without a file which scene.save gives a path"`,
}

Api_Thumbnail_Result :: struct {
    asked:bool `mirai:"label=The view of the scene is taken in the next frames and kept as its thumbnail"`,
}

Api_Release_Result :: struct {
    released:bool `mirai:"label=The editor has the keyboard and the mouse"`,
}

Api_Camera_Preview_End :: enum u8 {None,Keep,Discard}
Api_Camera_Preview_Params :: struct {
    entity:Api_Entity_Text `mirai:"optional,text,entity,label=The entity with a Camera to preview: the scene plays as a simulation seen through it"`,
    end:Api_Camera_Preview_End `mirai:"optional,label=Ends the preview: Keep writes into the document what its cameras became as one undo step; Discard leaves them as they were"`,
}
Api_Camera_Preview_Result :: struct {
    previewing:bool,
}

@(private)
commands_methods_register :: proc(s:^Session,st:^Api_State) {
    on:=Api_View_Params{on=true}
    tool_on_default:=Api_Tool_Params{on=true}
    api_register(s,st,{name="scene.new",summary="An empty scene in place of the document, with an empty history. Fails with unsaved changes unless discard.",params=type_info_of(Api_Scene_New_Params),result=type_info_of(Api_File_Result),flags={.Destructive},run=api_scene_new})
    api_register(s,st,{name="scene.group",summary="Puts entities under a new empty entity at their center, as one undo step. Returns the group.",params=type_info_of(Api_Group_Params),result=type_info_of(Api_Edit_Result),run=api_scene_group})
    api_register(s,st,{name="scene.thumbnail",summary="Takes the view of the viewport as the thumbnail of the scene of the document, which the content browser and the projects screen show.",result=type_info_of(Api_Thumbnail_Result),run=api_scene_thumbnail})
    api_register(s,st,{name="editor.copy",summary="Keeps entities for Paste of the editor (Ctrl+V), which duplicates them; scene.write with copy copies one at once.",params=type_info_of(Api_Copy_Params),result=type_info_of(Api_Copy_Result),flags={.Idempotent},run=api_editor_copy})
    api_register(s,st,{name="editor.tool",summary="Chooses what the pointer does in the viewport: the mode of the gizmo, or the tool of a plugin, whose panel takes the place of Details while it is on.",params=type_info_of(Api_Tool_Params),result=type_info_of(Api_Tool_Result),defaults=&tool_on_default,flags={.Idempotent},run=api_editor_tool})
    api_register(s,st,{name="editor.view",summary="Shows or hides a part of the interface of the editor that is not a preference: a dialog, a popup, a tab of the left panel, the name field of Details or the studio light. To see it, capture with ui.",params=type_info_of(Api_View_Params),result=type_info_of(Api_View_Result),defaults=&on,flags={.Idempotent},run=api_editor_view})
    api_register(s,st,{name="editor.save_all",summary="Writes every unsaved asset and every document with changes that has a file.",result=type_info_of(Api_Save_All_Result),run=api_save_all})
    api_register(s,st,{name="play.release",summary="Gives the keyboard and the mouse of the game the user plays back to the editor, as F1 does; a click on the game takes them again.",result=type_info_of(Api_Release_Result),flags={.Idempotent},run=api_play_release})
    api_register(s,st,{name="camera.preview",summary="Previews a camera of the scene: the scene plays as a simulation seen through it, with the blend of its activation, and Details edits the copy that plays. end stops it, keeping what the cameras became or not.",params=type_info_of(Api_Camera_Preview_Params),result=type_info_of(Api_Camera_Preview_Result),run=api_camera_preview})
}

@(private)
api_scene_new :: proc(s:^Session,call:^api.Call) {
    if api_turn_refused(s,call,"replace the document and its history") {return}
    // A person is asked about what the scene would lose.
    if api_person(s) {
        file_new(s)
        return
    }
    params:=api.call_params(call,Api_Scene_New_Params)
    if !collab_can_open(s) {
        api.call_fail(call,api.SERVER_ERROR,"Leave the session before replacing the scene (collab.leave)")
        return
    }
    if !params.discard && (document_dirty(s) || len(document_closing_assets(s))>0) {
        api.call_fail(call,api.SERVER_ERROR,"The scene has unsaved changes; scene.save and asset.save write them, or pass discard")
        return
    }
    tool_preview_cancel(s)
    runs_stop(s)
    asset_document_activate(s,-1)
    scene_new(s)
    api_file_result(s,call)
}

// Puts entities under a new group at their center. NONE when it could not.
entities_group :: proc(s:^Session,w:core.World_Ref,entities:[]core.Entity) -> core.Entity {
    if len(entities)==0 {return core.NONE}
    center:[3]f32
    for e in entities {center+=entity_world(w,e).position}
    center/=f32(len(entities))
    opened,edit_ready:=edit_open(s,"Group")
    if !edit_ready {return core.NONE}
    defer edit_close(s,opened)
    parent:=entity_parent(w,entities[0])
    for e in entities[1:] {
        if entity_parent(w,e)!=parent {parent=core.NONE;break}
    }
    group:=entity_create(s,{preset=.Empty,parent=parent,transform={position=center,rotation=1,scale={1,1,1}}})
    if group==core.NONE {return core.NONE}
    // The group exists once settled: its children are placed relative to where it will be.
    core.world_settle(w)
    for e in entities {entity_reparent(s,e,group)}
    return group
}

@(private)
api_scene_group :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Group_Params)
    if !api_edit_begin(s,call,"Group") {return}
    w:=edited_world(s)
    entities,known:=api_call_entities(call,w,params.entities[:],"entities",call.allocator)
    group:=core.NONE
    if known && len(entities)==0 {api.call_fail(call,api.INVALID_PARAMS,"entities: name the entities the group holds")}
    if known && len(entities)>0 {
        for e in entities {
            if text:=section_lock_text(s,w,e,true);text!="" {api.call_failf(call,api.SERVER_ERROR,"scene.group: %s",text);break}
            if prefab_member_locked(s,w,e) {api.call_fail(call,api.SERVER_ERROR,"scene.group: a member of an instance of a prefab keeps the place its prefab gives it; group the instance, or unlink it");break}
        }
        if !call.failed {group=entities_group(s,w,entities)}
        if group!=core.NONE {core.world_settle(w)}
    }
    id:=api_entity_id(w,group)
    // A person goes on with the group: it is what the step leaves selected.
    if group!=core.NONE && api_person(s) {history.selection_set(document_selection(s),{group})}
    if api_edit_end(s,call,group!=core.NONE) {api.call_result(call,Api_Edit_Result).id=id}
}

@(private)
api_scene_thumbnail :: proc(s:^Session,call:^api.Call) {
    if s.mode!=.Edit || !scene_thumbnail_takes(s) {
        api.call_fail(call,api.SERVER_ERROR,"The thumbnail is that of a scene of the assets in front, out of Play, in an editor that draws and a project with a thumbs folder")
        return
    }
    thumbnail_scene_take(s,s.document.id,0,true)
    api.call_result(call,Api_Thumbnail_Result).asked=true
}

@(private)
api_editor_copy :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Copy_Params)
    w:=edited_world(s)
    entities,known:=api_call_entities(call,w,params.entities[:],"entities",call.allocator)
    if !known {return}
    clear(&s.copied)
    for e in entities {
        if id:=api_entity_id(w,e);id!=0 {append(&s.copied,id)}
    }
    api.call_result(call,Api_Copy_Result).copied=len(s.copied)
}

@(private)
api_editor_tool :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Tool_Params)
    name:=base.text_get(params.tool[:])
    v:=s.viewport
    if s.edits.preview {tools_release(s)}
    tool,gizmo:=Tool.Move,true
    switch name {
    case "move":
    case "rotate": tool=.Rotate
    case "scale":  tool=.Scale
    case:          gizmo=false
    }
    if gizmo {
        if !params.on {
            api.call_fail(call,api.INVALID_PARAMS,"The gizmo always has a mode: name the one to change to")
            return
        }
        gizmo_mode(s,tool)
    } else {
        // A tool of a plugin is the one its entry names.
        known:=false
        names:=make([dynamic]string,context.temp_allocator)
        for &b in command_bindings(s) {
            if b.method!="editor.tool" || b.menu!=.Tools {continue}
            append(&names,b.name)
            known||=b.name==name
        }
        if !known {
            api.call_failf(call,api.INVALID_PARAMS,"tool: %s",base.name_problem(name,"a tool",names[:]))
            return
        }
        if params.on && (playing(s) || scene_covered(s)) {
            api.call_fail(call,api.SERVER_ERROR,"The tools of the plugins work on the scene of the document: stop the game, or bring the scene to the front (editor.document)")
            return
        }
        tool_set(s,name,params.on)
    }
    result:=api.call_result(call,Api_Tool_Result)
    switch v.tool {
    case .Move:   base.text_set(result.tool[:],"move")
    case .Rotate: base.text_set(result.tool[:],"rotate")
    case .Scale:  base.text_set(result.tool[:],"scale")
    }
    if v.plugin_tool!=0 {base.text_set(result.plugin_tool[:],base.text_get(v.plugin_tool_name[:]))}
}

@(private)
api_editor_view :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_View_Params)
    g:=s.gui
    result:=api.call_result(call,Api_View_Result)
    if g==nil || g.ctx==nil {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no interface")
        return
    }
    refuse :: proc(call:^api.Call,part:Api_View_Part) {api.call_failf(call,api.INVALID_PARAMS,"%v only shows: leave on out",part)}
    switch params.part {
    case .Settings:
        if params.on && (!s.has_project || s.mode!=.Edit) {
            api.call_fail(call,api.SERVER_ERROR,"The settings are those of a project, out of Play")
            return
        }
        if params.on {settings_show(s)} else if g.modal==.Settings {modal_close(g)}
        result.on=g.modal==.Settings
    case .Shortcuts:
        if params.on {
            ui.popup_close(g.ctx)
            g.modal,g.modal_scroll=.Shortcuts,0
        } else if g.modal==.Shortcuts {modal_close(g)}
        result.on=g.modal==.Shortcuts
    case .Projects:
        if !params.on {refuse(call,params.part);return}
        if s.mode!=.Edit || s.engine_root=="" || s.projects==nil {
            api.call_fail(call,api.SERVER_ERROR,"The projects screen opens out of Play, in an editor that knows the root of its engine")
            return
        }
        projects_show(s)
        result.on=true
    case .Graphics:
        if params.on {
            anchor,_:=ui.widget_rect(g.ctx,shell_id(g,"graphics"))
            ui.popup_open(g.ctx,graphics_popup(g),anchor)
        } else if ui.popup_is_open(g.ctx,graphics_popup(g)) {ui.popup_close(g.ctx)}
        result.on=params.on
    case .Find:
        if !params.on {refuse(call,params.part);return}
        finder_open(s)
        result.on=true
    case .Chat:
        if s.mode==.Play {
            api.call_fail(call,api.SERVER_ERROR,"The chat opens while the game is paused: play.pause first")
            return
        }
        shown:=ai_chat_open(s.ai) && (g.layout.left_open || play_shown(s))
        if shown!=params.on {
            // A chat folded with its panel comes back with it instead of closing.
            if play_shown(s) {play_chat_set(s,!s.play_chat_open)} else if ai_chat_open(s.ai) && !g.layout.left_open {g.layout.left_open=true} else {ai_chat_toggle(s.ai)}
        }
        result.on=ai_chat_open(s.ai) && (g.layout.left_open || play_shown(s))
    case .Git:
        if !s.has_project {
            api.call_fail(call,api.SERVER_ERROR,"Source control is that of a project")
            return
        }
        if params.on {
            g.layout.left_open=true
            library_select(s,.Git)
        } else if g.layout.library_tab==.Git {library_select(s,.Content)}
        result.on=g.layout.left_open && g.layout.library_tab==.Git
    case .Hierarchy:
        library_select(s,params.on?.Hierarchy:.Editor)
        result.on=g.layout.left_open && g.layout.library_tab==.Hierarchy
    case .Rename:
        if !params.on {refuse(call,params.part);return}
        if len(s.selection.entities)!=1 || watching(s) {
            api.call_fail(call,api.SERVER_ERROR,"Rename is of one selected entity: editor.select it; scene.write with root, merge and name renames without the field")
            return
        }
        g.layout.right_open=true
        s.inspector.rename=true
        result.on=true
    case .Studio_Light:
        if params.on && (document_is_prefab(s) || playing(s)) {
            api.call_fail(call,api.SERVER_ERROR,"The studio light is of a scene out of Play: a prefab document always shows with it")
            return
        }
        s.viewport.studio_light=params.on
        result.on=s.viewport.studio_light
    }
}

// Opens Project Settings on the layer of the project.
@(private)
settings_show :: proc(s:^Session) {
    g:=s.gui
    ui.popup_close(g.ctx)
    g.modal,g.modal_scroll=.Settings,0
    s.settings_dialog.scroll,s.settings_dialog.jump=0,-1
    settings_layer_set(s,.Project)
    settings_engine_load(s)
    settings_plugins_load(s)
    input_settings_load(s)
    settings_project_load(s)
}

@(private)
api_save_all :: proc(s:^Session,call:^api.Call) {
    if !api_person(s) {
        if api_turn_refused(s,call,"save what others changed: asset.save writes the assets of its turn and scene.save the document") {return}
        if !api_guard(s,call) {return}
        if !collab_can_save(s) {
            api.call_fail(call,api.SERVER_ERROR,"The host of the session saves the shared scene")
            return
        }
    }
    save_all(s)
    api.call_result(call,Api_Save_All_Result).dirty=documents_dirty(s)
}

@(private)
api_play_release :: proc(s:^Session,call:^api.Call) {
    if ai_task_of_call(s,call)!=0 {
        api.call_fail(call,api.SERVER_ERROR,"The keyboard and the mouse are those of the game of the user: a turn gives its run input with play.step")
        return
    }
    if player_processes_captured(s) {player_processes_release(s)} else {play_release_input(s)}
    api.call_result(call,Api_Release_Result).released=!player_processes_captured(s) && (s.mode!=.Play || s.play_input_released)
}

@(private)
api_camera_preview :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Camera_Preview_Params)
    if ai_task_of_call(s,call)!=0 {
        api.call_fail(call,api.SERVER_ERROR,"The preview takes the view of the user: a turn looks through a camera with camera.set and entity")
        return
    }
    switch params.end {
    case .Keep,.Discard:
        if !camera_previewing(s) {
            api.call_fail(call,api.SERVER_ERROR,"No camera is being previewed")
            return
        }
        camera_preview_end(s,params.end==.Keep)
    case .None:
        w:=edited_world(s)
        targets,known:=api_call_targets(call,w,params.entity[:])
        if !known {return}
        if playing(s) {
            api.call_fail(call,api.SERVER_ERROR,"A game or a preview plays: play.stop, or camera.preview with end")
            return
        }
        if !camera_preview_start(s,targets[0]) {
            api.call_fail(call,api.SERVER_ERROR,"The camera could not be previewed: the entity has no Camera, or the simulation did not start")
            return
        }
    }
    api.call_result(call,Api_Camera_Preview_Result).previewing=camera_previewing(s)
}

// ---------------------------------------------------------------- editor.inspect

// Every entry with the method it calls and what it shows now.
@(private)
api_commands_write :: proc(s:^Session,w:^serial.Writer) {
    serial.write_u8(w,'[')
    for &b,i in command_bindings(s) {
        if i>0 {serial.write_u8(w,',')}
        state:=binding_state(s,&b)
        serial.text_write_raw(w,`{"name":`);serial.text_write_string(w,b.name)
        api.write_key(w,"method");serial.text_write_string(w,b.method)
        if b.params!="" {api.write_key(w,"params");serial.text_write_string(w,b.params)}
        api.write_key(w,"label");serial.text_write_string(w,binding_label(&b,state))
        if b.shortcut.set {api.write_key(w,"shortcut");serial.text_write_string(w,shortcut_text(b.shortcut))}
        api.write_key(w,"disabled");api.write_flag(w,state.disabled)
        api.write_key(w,"checked");api.write_flag(w,state.checked)
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
}

// The widget of the bar an entry draws, as editor.inspect names it.
command_widget :: proc(g:^Editor_Ui,name:string,index:int=0) -> ui.Id {return ui.id_derive(g.ctx,COMMAND_SCOPE,name,index)}

@(private)
COMMAND_SCOPE :: ui.Id(0x434f4d4d)
