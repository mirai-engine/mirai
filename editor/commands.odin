package editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
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
// refuses are the same for both, and it takes only the params it is given. A
// plugin gives its methods entries the same way (command_bind, tool_entry).
//
// What the person has in front is put into the params by the entry, before
// the call (binding_params): its params name it in place of values.
//   "$selection" "$roots" "$copied"   entities; the element of a list that names them, the
//                                      name or the object that holds it, is given once for each
//   "$active"                          the active entity
//   "$shown"                           Scene, or Game while the editor shows a game
//   "$document"                        the asset document in front; "" for the scene
//   "$card"                            the asset of the card of the browser with the keyboard
// An entry that flips something names it (tool, preference), which gives its
// params and says whether it shows checked.
//
// Whether an entry is on is said in one place (binding_state): by what it
// acts on being in front, by the modes it is for, by its context being
// there, and by its method, asked with the params the entry would call:
// Api_Method.can, which is also what fails a call, of anyone.
//
// An entry that only changes what the person sees (a dialog, a popup, a tab,
// the field a name is typed in, who has the keys), or that asks the person
// before anything happens (a file to open, what to do with unsaved changes),
// runs a procedure of the interface (Binding.view) and is no method: an agent
// works through the API, and looks at the interface with editor.input and
// capture.
//
// What a person does inside a panel with the pointer or the keyboard focus (a
// scroll, a hover, a fold, a splitter, a field being typed) is the view of
// that panel and has no entry. The gestures of a frame run between frames,
// where the calls of agents run.

CONTEXT_SELECTION :: "$selection" // the selected entities
CONTEXT_ROOTS     :: "$roots"     // those of them no other selected one holds
CONTEXT_ACTIVE    :: "$active"    // the active one
CONTEXT_COPIED    :: "$copied"    // the roots Copy kept that the world shown has
CONTEXT_SHOWN     :: "$shown"     // the world the editor shows: Scene or Game
CONTEXT_DOCUMENT  :: "$document"  // the asset document in front, by its path
CONTEXT_CARD      :: "$card"      // the asset of the card of the browser that has the keyboard, by its id

BINDING_CAPACITY :: 160
COMMAND_QUEUE :: 16
COMMAND_PARAMS :: 512 // bytes of the params of a gesture the interface worked out (command_call)

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

Modes :: bit_set[Mode;u8]

Binding :: struct {
    name:string,   // what command_run, the buttons and editor.inspect name it by; the name of its method when empty
    label:string,
    icon:ui.Icon,
    shortcut,alternate:Shortcut,
    menu:Menu,
    group:u8,      // of its menu, under MENU_GROUPS
    // What it runs: a method, or a procedure of the interface.
    method:string,
    params:string, // JSON; "": none. Of an entry with view: the context it needs
    view:proc(s:^Session), // in place of a method: what only changes what the person sees, or asks them first
    // What it flips: its method and its params come from it, and whether it shows checked.
    tool:string,              // editor.tool: a mode of the gizmo, or the tool of a plugin
    preference,on,off:string, // preferences.set: the area, and its fields as JSON when the entry is on and when it is off
    // When it is on.
    modes:Modes,   // of the editor; {}: all
    scene:bool,    // it works on the scene: off while an asset document covers it
    document:asset.Fourcc, // it works on the asset document of this kind: off unless one is in front
    card:bool,     // it works on the asset of the card of the browser that has the keyboard: off without one
    in_game:bool,  // its shortcut runs while a game has the keys
    state:Command_State_Proc, // of a procedure of the interface: off and checked; of a method: what no method says, its label or whose game plays
    call:^api.Method, // its method, found when it is bound
}

@(private)
Command_Asked :: struct {
    binding:^Binding, // the entry that asked: its params are worked out when it runs; nil: those below
    method:string,
    label:string,     // what the step of undo of what it edits is called; "": as its method calls it
    params:[COMMAND_PARAMS]u8,
    length:int,
}

Commands :: struct {
    bindings:[BINDING_CAPACITY]Binding,
    count:int,
    asked:[COMMAND_QUEUE]Command_Asked, // the gestures of the frame, until commands_run
    asked_count:int,
    running:bool,
}

// Gives a method, or a procedure of the interface, an entry. The texts stay
// where they are: constants of the editor or of a library, which stays
// loaded. False, with why among the refusals of the API, when it does not
// fit, its name is taken, its method is not registered yet or its key is of
// another entry that can be on at the same time.
command_bind :: proc(s:^Session,b:Binding) -> bool {
    st:=api_state(s)
    if st==nil {return false}
    c:=&st.commands
    entry:=b
    switch {
    case entry.tool!="":       entry.method="editor.tool"
    case entry.preference!="": entry.method="preferences.set"
    }
    if entry.name=="" {entry.name=entry.method}
    refuse :: proc(st:^Api_State,format:string,args:..any) -> bool {
        api_refuse(st,fmt.tprintf(format,..args))
        return false
    }
    if (entry.method=="")==(entry.view==nil) {return refuse(st,"the entry %s needs a method or a procedure of the interface, one of them",entry.name)}
    if entry.method!="" {
        if entry.call=api.method_find(&st.server,entry.method);entry.call==nil {return refuse(st,"the entry %s calls %s, which is not registered: register the method before its entry",entry.name,entry.method)}
    }
    if c.count>=len(c.bindings) {return refuse(st,"the entry %s does not fit: raise BINDING_CAPACITY in editor/commands.odin",entry.name)}
    if binding_find(c,entry.name)!=nil {return refuse(st,"the name of the entry %s is taken: give it another",entry.name)}
    for &other in c.bindings[:c.count] {
        for key in ([2]Shortcut{entry.shortcut,entry.alternate}) {
            if !key.set || key!=other.shortcut && key!=other.alternate || !bindings_meet(&entry,&other) {continue}
            return refuse(st,"the shortcut %s of the entry %s is taken by the entry %s, which can be on at the same time: give one of them another key",shortcut_text(key),entry.name,other.name)
        }
    }
    c.bindings[c.count]=entry
    c.count+=1
    return true
}

// Whether two entries can be on at the same time, which one key cannot run
// both of: their modes meet and so does what they work on. An entry of the
// card of the browser takes its keys from the others while a card has the
// keyboard; one of the scene is off while an asset document covers it. Two
// that each say by their state when they are off share a key (Play and Stop
// on F5): what that state says is not known when they are bound.
@(private)
bindings_meet :: proc(a,b:^Binding) -> bool {
    if a.state!=nil && b.state!=nil {return false}
    if a.modes!={} && b.modes!={} && a.modes&b.modes=={} {return false}
    if a.card || b.card {return a.card && b.card}
    if a.document!=0 && b.document!=0 {return a.document==b.document}
    return !(a.scene && b.document!=0 || b.scene && a.document!=0)
}

// The entry of a tool of a plugin in the Tools menu, by the name it turns on
// with (tool_set): editor.tool turns it on and off, for a person and an agent.
tool_entry :: proc(s:^Session,name,label:string,icon:ui.Icon,shortcut:=Shortcut{}) -> bool {
    return command_bind(s,{name=name,tool=name,label=label,icon=icon,shortcut=shortcut,menu=.Tools,modes={.Edit},scene=true})
}

// The mode of the gizmo a tool is named by; false for the tool of a plugin.
@(private)
gizmo_tool :: proc(name:string) -> (tool:Tool,ok:bool) {
    switch name {
    case "move":   return .Move,true
    case "rotate": return .Rotate,true
    case "scale":  return .Scale,true
    }
    return
}

// Whether a tool is the one on. While a plugin tool that lends the scene to the gizmo holds it, no mode is.
@(private)
tool_checked :: proc(s:^Session,name:string) -> bool {
    if tool,gizmo:=gizmo_tool(name);gizmo {return s.viewport.tool==tool && !lender_holding(s.viewport)}
    return tool_on(s,name)
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

// What an entry shows now: the one place that says whether it is on and whether it is checked.
binding_state :: proc(s:^Session,b:^Binding) -> (state:Command_State) {
    if st:=api_state(s);st.library_generation!=s.library_generation {return {disabled=true}}
    if s.gui!=nil && s.gui.modal==.Recovery && b.name!="quit" {return {disabled=true}}
    // What it acts on is in front: the scene, an asset document of its kind, a card with the keyboard.
    d:=asset_document_active(s)
    if b.scene && d!=nil || b.document!=0 && (d==nil || d.kind!=b.document) || b.card && card_focused(s)=={} {return {disabled=true}}
    if b.state!=nil {state=b.state(s,b)}
    switch {
    case b.tool!="":       state.checked=tool_checked(s,b.tool)
    case b.preference!="": state.checked=preference_holds(s,b.preference,b.on)
    }
    state.disabled||=b.modes!={} && s.mode not_in b.modes || context_missing(s,b.params) || binding_refused(s,b)
    return
}

// Whether the method of an entry says it cannot be called with the params the entry would call it with now.
@(private)
binding_refused :: proc(s:^Session,b:^Binding) -> bool {
    if b.call==nil || b.call.can==nil {return false}
    params:=strings.builder_make(context.temp_allocator)
    if !binding_params(s,b,&params) {return true}
    server:=&api_state(s).server
    mark:=base.arena_mark(&server.scratch)
    defer base.arena_rewind(&server.scratch,mark)
    bytes,_,_,read:=api.params_read(server,b.call,strings.to_string(params))
    return !read || b.call.can(b.call.user,raw_data(bytes))!=""
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
    if b==nil || binding_state(s,b).disabled {return false}
    event(s,"command",b.name)
    return command_ask(s,{binding=b})
}

// Runs a method as the person at the editor, with params the interface
// worked out (a point of the scene, a path): between frames. label names the
// step of undo of what it edits, in place of the one its method gives. False
// when the gestures of the frame do not fit.
command_call :: proc(s:^Session,method,params:string,label:="") -> bool {
    if len(params)>COMMAND_PARAMS {
        notify(s,"The params of that gesture are too long")
        return false
    }
    asked:=Command_Asked{method=method,label=label}
    asked.length=copy(asked.params[:],params)
    return command_ask(s,asked)
}

@(private)
command_ask :: proc(s:^Session,asked:Command_Asked) -> bool {
    st:=api_state(s)
    if st==nil {return false}
    c:=&st.commands
    if c.asked_count>=len(c.asked) {
        notify(s,"Too much was asked of the editor in one frame")
        return false
    }
    c.asked[c.asked_count]=asked
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

// ---------------------------------------------------------------- what the person has in front

// Whether something the params of an entry name of what the person has in front is not there.
@(private)
context_missing :: proc(s:^Session,params:string) -> bool {
    rest:=params
    for {
        at:=strings.index_byte(rest,'$')
        if at<0 {return false}
        rest=rest[at:]
        missing:bool
        switch {
        case strings.has_prefix(rest,CONTEXT_SELECTION),strings.has_prefix(rest,CONTEXT_ROOTS): missing=len(s.selection.entities)==0
        case strings.has_prefix(rest,CONTEXT_ACTIVE): missing=history.selection_active(s.selection)==core.NONE
        case strings.has_prefix(rest,CONTEXT_COPIED): missing=len(s.copied)==0
        case strings.has_prefix(rest,CONTEXT_SHOWN):  missing=watching(s)
        }
        if missing {return true}
        rest=rest[1:]
    }
}

// An entity as the params of a method name it: by its id, or one of a game without one by its handle.
@(private="file")
context_entity :: proc(out:^strings.Builder,w:core.World_Ref,e:core.Entity) {
    id:=u64(api_entity_id(w,e))
    fmt.sbprintf(out,`"0x%016x"`,id if id!=0 else u64(e))
}

// Writes params with what the person has in front in place of the context
// names. Of entities, the element of the list that names them is given once
// for each: the name itself, or the object that holds it. False when
// something they name is not there.
@(private)
context_write :: proc(s:^Session,out:^strings.Builder,text:string) -> bool {
    at:=strings.index(text,`"$`)
    close:=at<0?-1:strings.index_byte(text[at+1:],'"')
    if close<0 {
        strings.write_string(out,text)
        return true
    }
    end:=at+close+2
    w:=shown_world(s)
    entities:[]core.Entity
    listed:=true
    strings.write_string(out,text[:at])
    switch text[at+1:end-1] {
    case CONTEXT_SELECTION: entities=s.selection.entities[:]
    case CONTEXT_ROOTS:     entities=history.selection_roots(s.selection,w,context.temp_allocator)
    case CONTEXT_COPIED:    entities=copied_entities(s,w)
    case CONTEXT_ACTIVE:
        active:=history.selection_active(s.selection)
        if active==core.NONE {return false}
        context_entity(out,w,active)
        listed=false
    case CONTEXT_SHOWN:
        if watching(s) {return false}
        strings.write_string(out,`"Game"` if playing(s) else `"Scene"`)
        listed=false
    case CONTEXT_DOCUMENT:
        d:=asset_document_active(s)
        fmt.sbprintf(out,"%q",asset_document_path(s,d) if d!=nil else "")
        listed=false
    case CONTEXT_CARD:
        buffer:[base.ASSET_ID_TEXT]u8
        fmt.sbprintf(out,"%q",base.asset_id_format(card_focused(s),buffer[:]))
        listed=false
    case:
        strings.write_string(out,text[at:end])
        listed=false
    }
    if !listed {return context_write(s,out,text[end:])}
    // What a document names by its id is of the scene; a game names any of its entities.
    named:=make([dynamic]core.Entity,0,len(entities),context.temp_allocator)
    for e in entities {
        if playing(s) || api_entity_id(w,e)!=0 {append(&named,e)}
    }
    if len(named)==0 {return false}
    // The element: from the name back to what opens it, an object or the list itself.
    from,to,depth:=at,end,0
    #reverse for c,i in transmute([]u8)text[:at] {
        if c=='}' || c==']' {depth+=1}
        if c!='{' && c!='[' {continue}
        if depth>0 {depth-=1;continue}
        if c=='{' {
            from,depth=i,0
            for inner,j in transmute([]u8)text[i:] {
                if inner=='{' {depth+=1}
                if inner=='}' {depth-=1}
                if depth==0 {to=i+j+1;break}
            }
        }
        break
    }
    resize(&out.buf,len(out.buf)-(at-from))
    for e,i in named {
        if i>0 {strings.write_byte(out,',')}
        element:=strings.builder_make(context.temp_allocator)
        strings.write_string(&element,text[from:at])
        context_entity(&element,w,e)
        strings.write_string(&element,text[end:to])
        context_write(s,out,strings.to_string(element)) or_return
    }
    return context_write(s,out,text[to:])
}

// The params an entry calls its method with now. False when there is nothing to call with.
@(private)
binding_params :: proc(s:^Session,b:^Binding,out:^strings.Builder) -> bool {
    switch {
    case b.tool!="":
        // The gizmo always has a mode; the tool of a plugin is turned on and off.
        _,gizmo:=gizmo_tool(b.tool)
        fmt.sbprintf(out,`{{"tool":%q,"on":%v}}`,b.tool,gizmo || !tool_checked(s,b.tool))
    case b.preference!="":
        fmt.sbprintf(out,`{{"preferences":{{%q:{{%s}}}}}}`,b.preference,b.off if preference_holds(s,b.preference,b.on) else b.on)
    case:
        return context_write(s,out,b.params if b.params!="" else "{}")
    }
    return true
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
        b:=asked.binding
        switch {
        case b==nil:     command_execute(s,st,asked.method,string(asked.params[:asked.length]),asked.label)
        case b.view!=nil: b.view(s)
        case:
            params:=strings.builder_make(context.temp_allocator)
            if binding_params(s,b,&params) {command_execute(s,st,b.method,strings.to_string(params),b.label)} else {notify(s,fmt.tprintf("%s: what it works on is not in what the editor shows",b.label))}
        }
    }
    c.asked_count=0
}

// One call of the person: the handler of the method, through what every
// call goes through. What it refuses is said in a notice.
@(private)
command_execute :: proc(s:^Session,st:^Api_State,name,params:string,label:="") {
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
    was,gesture,tag,client:=st.person,st.gesture,server.client_tag,server.client_name
    st.person,st.gesture,st.left_going=true,label,false
    server.client_tag,server.client_name="",""
    error,ok:=api.method_execute(server,method,params,&out)
    st.person,st.gesture,server.client_tag,server.client_name=was,gesture,tag,client
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
    // The keys of the entries of a card of the browser that has the keyboard are of its asset, not
    // of the selected entities.
    card:core.Keys
    for &b in command_bindings(s) {
        if b.card && card_focused(s)!={} {card+={b.shortcut.key,b.alternate.key}}
    }
    game:=s.mode==.Play || player_processes_captured(s)
    for &b in command_bindings(s) {
        if !shortcut_pressed(keys,modifiers,b.shortcut) && !shortcut_pressed(keys,modifiers,b.alternate) {continue}
        // While a game runs the keys are its own, but those of Play.
        if game && !b.in_game || !b.card && keys&card!={} {continue}
        if play_shown(s) && b.name=="library_panel" {continue}
        command_run(s,b.name)
    }
}

// The asset of the card of the browser that has the keyboard; zero without one.
@(private)
card_focused :: proc(s:^Session) -> base.Asset_Id {
    return content_focused(s.content,s.gui.ctx) if s.gui!=nil && s.gui.ctx!=nil else {}
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
    VIEWPORT :: "Viewport_Preferences"
    LAYOUT :: "Layout"
    edit:=Modes{.Edit}
    entries:=[?]Binding{
        {name="new",view=proc(s:^Session) {file_new(s)},label="New scene",icon=user(.Scene),shortcut=key(.N,{.Primary}),menu=.File,group=0,modes=edit},
        {name="new_prefab",view=proc(s:^Session) {file_new(s,true)},label="New prefab",icon=.Prefab,menu=.File,group=0,modes=edit},
        {name="open",view=file_open,label="Open...",icon=user(.Scene),shortcut=key(.O,{.Primary}),menu=.File,group=0,modes=edit},
        {name="projects",view=projects_show,label="Open project...",icon=user(.Folder),menu=.File,group=0,modes=edit,state=state_projects},
        {name="save",view=save_front,label="Save",icon=user(.Save),shortcut=key(.S,{.Primary}),menu=.File,group=1,state=state_save},
        {name="save_all",method="editor.save_all",label="Save all",icon=user(.Save),shortcut=key(.S,{.Primary,.Shift}),menu=.File,group=1,modes=edit},
        {name="save_as",view=dialog_save,label="Save as...",icon=user(.Save),shortcut=key(.S,{.Primary,.Alt}),menu=.File,group=1,modes=edit,scene=true},
        {name="make_prefab",method="scene.write",params=`{"kind":"Prefab","entities":[]}`,label="Make prefab",icon=.Prefab,menu=.File,group=1,modes=edit,scene=true},
        {name="make_scene",method="scene.write",params=`{"kind":"Scene","entities":[]}`,label="Make scene",icon=user(.Scene),menu=.File,group=1,modes=edit,scene=true},
        {name="import",view=import_ask,label="Import...",icon=.Import,menu=.File,group=2,modes=edit},
        {name="build",method="build.start",label="Build",icon=user(.Hammer),shortcut=key(.B,{.Primary}),menu=.File,group=3,state=state_build},
        {name="settings",view=settings_toggle,label="Project settings",icon=user(.Gear),menu=.File,group=3,modes=edit,state=state_settings},
        {name="quit",view=quit_request,label="Quit",icon=.Cross,shortcut=key(.Q,{.Primary}),menu=.File,group=4},

        {name="undo",method="history.undo",params=`{"asset":"$document"}`,label="Undo",icon=user(.Undo),shortcut=key(.Z,{.Primary}),state=state_undo},
        {name="redo",method="history.redo",params=`{"asset":"$document"}`,label="Redo",icon=user(.Redo),shortcut=key(.Y,{.Primary}),alternate=key(.Z,{.Primary,.Shift}),state=state_redo},
        {name="copy",view=copy_roots,params=CONTEXT_ROOTS,label="Copy",icon=user(.Copy),shortcut=key(.C,{.Primary}),modes=edit,scene=true},
        {name="paste",method="scene.write",params=`{"world":"$shown","select":true,"entities":[{"copy":"$copied"}]}`,label="Paste",shortcut=key(.V,{.Primary}),scene=true},
        {name="duplicate",method="scene.write",params=`{"world":"$shown","select":true,"entities":[{"copy":"$roots"}]}`,label="Duplicate",icon=user(.Copy),shortcut=key(.D,{.Primary}),scene=true},
        {name="delete",method="scene.write",params=`{"world":"$shown","entities":[{"id":"$roots","delete":true}]}`,label="Delete",icon=user(.Trash),shortcut=key(.Delete),alternate=key(.Backspace),scene=true},
        {name="rename",view=rename_focus,label="Rename",icon=.Edit,shortcut=key(.F2),state=state_rename,scene=true},
        {name="select_all",view=select_all,label="Select all",shortcut=key(.A,{.Primary}),scene=true},
        {name="deselect",view=proc(s:^Session) {history.selection_clear(s.selection)},params=CONTEXT_SELECTION,label="Deselect",shortcut=key(.Escape),scene=true},
        {name="group",method="scene.write",params=`{"select":true,"entities":[{"group":["$roots"]}]}`,label="Group selection",icon=.Group,shortcut=key(.G,{.Primary}),modes=edit,scene=true},

        {name="tool_move",tool="move",label="Move",icon=.Move,shortcut=key(.W),scene=true},
        {name="tool_rotate",tool="rotate",label="Rotate",icon=.Rotate,shortcut=key(.E),scene=true},
        {name="tool_scale",tool="scale",label="Scale",icon=.Scale,shortcut=key(.R),scene=true},
        {name="space",preference=VIEWPORT,on=`"space":"Local"`,off=`"space":"World"`,label="Local axes",icon=.Relative,scene=true},
        {name="snap",preference=VIEWPORT,on=`"snap":true,"snap_off":false`,off=`"snap":false`,label="Snap to grid",icon=.Grid,scene=true},

        {name="focus",view=focus_selection,params=CONTEXT_SELECTION,label="Focus selection",icon=.Focus,shortcut=key(.F),menu=.View,group=0,scene=true},
        {name="reset_camera",view=proc(s:^Session) {s.viewport.orbit,s.view_cut=ORBIT_DEFAULT,true;viewport_camera(s.viewport)},label="Reset camera",icon=user(.Camera),menu=.View,group=0,scene=true},
        {name="scene_thumbnail",method="scene.thumbnail",label="Update scene thumbnail",icon=user(.Camera),menu=.View,group=0,scene=true},
        {name="grid",preference=VIEWPORT,on=`"show_grid":true`,off=`"show_grid":false`,label="Grid",icon=.Grid,menu=.View,group=1,scene=true},
        {name="indicators",preference=VIEWPORT,on=`"show_indicators":true`,off=`"show_indicators":false`,label="Indicators",icon=.Eye,menu=.View,group=1,scene=true},
        {name="output_frame",preference=VIEWPORT,on=`"show_output_frame":true`,off=`"show_output_frame":false`,label="Output frame",icon=user(.Camera),menu=.View,group=1,scene=true},
        {name="game_detail",preference=VIEWPORT,on=`"game_detail":true`,off=`"game_detail":false`,label="Detail of the game camera",menu=.View,group=1,scene=true},
        {name="studio_light",view=proc(s:^Session) {s.viewport.studio_light=!s.viewport.studio_light},label="Studio light",icon=.Sun,menu=.View,group=1,modes=edit,state=state_studio_light,scene=true},
        {name="graphics",view=graphics_toggle,label="Graphics",icon=user(.Graphics),menu=.View,group=1,state=state_graphics},
        {name="inspector_panel",preference=LAYOUT,on=`"right_open":true`,off=`"right_open":false`,label="Details",icon=user(.Graphics),menu=.View,group=2},
        {name="console_panel",preference=LAYOUT,on=`"bottom_open":true,"bottom_tab":"Console"`,off=`"bottom_open":false`,label="Console",icon=user(.Terminal),shortcut=key(.Grave,{.Primary}),menu=.View,group=2},
        {name="build_panel",preference=LAYOUT,on=`"bottom_open":true,"bottom_tab":"Build"`,off=`"bottom_open":false`,label="Build output",icon=user(.Hammer),menu=.View,group=2},
        {name="library_panel",preference=LAYOUT,on=`"left_open":true`,off=`"left_open":false`,label="Content Browser",icon=.Layers,shortcut=key(.Tab)},
        {name="hierarchy_panel",view=proc(s:^Session) {library_select(s,.Editor if state_hierarchy_panel(s,nil).checked else .Hierarchy)},label="Hierarchy",icon=user(.List),state=state_hierarchy_panel},
        {name="source_control",view=proc(s:^Session) {library_select(s,.Content if state_source_control(s,nil).checked else .Git)},label="Source control",icon=user(.Branch),state=state_source_control},
        {name="ai_chat",view=chat_toggle,label="AI tasks",icon=.Sparkle,state=state_ai_chat},
        {name="shortcuts",view=shortcuts_show,label="Keyboard shortcuts",icon=user(.Command),menu=.View,group=MENU_GROUP_PLUGINS+1},
        {name="find",view=finder_open,label="Find object",icon=user(.Search),shortcut=key(.Space),scene=true},

        // The key of Play stops what plays, and that of Pause resumes it. A person plays with the
        // players the Play menu has.
        {name="play",method="play.start",params=`{"online":-1,"ping_ms":-1}`,label="Play",icon=.Play,shortcut=key(.F5),state=state_play,scene=true},
        {name="play_from_camera",method="play.start",params=`{"from":"Camera","online":-1,"ping_ms":-1}`,label="Play from camera",icon=user(.Camera),state=state_play,scene=true},
        {name="simulate",method="play.start",params=`{"simulate":true}`,label="Simulate",icon=user(.Simulate),state=state_play,scene=true},
        {name="apply_simulation",method="simulation.apply",params=`{"entities":["$selection"]}`,label="Apply transforms",scene=true},
        {name="pause",method="play.pause",params=`{"paused":true}`,label="Pause",icon=user(.Pause),shortcut=key(.F6),modes={.Play,.Simulate},scene=true,in_game=true},
        {name="resume",method="play.pause",params=`{"paused":false}`,label="Resume",icon=.Play,shortcut=key(.F6),modes={.Paused,.Simulation_Paused},scene=true,in_game=true},
        {name="stop",method="play.stop",label="Stop",icon=.Stop,shortcut=key(.F5,{.Shift}),alternate=key(.F5),state=state_stop,in_game=true},
        {name="release_input",view=proc(s:^Session) {if player_processes_captured(s) {player_processes_release(s)} else {play_release_input(s)}},label="Eject",shortcut=key(.F1),state=state_release_input,scene=true,in_game=true},
        {name="camera_preview",view=camera_preview_selected,label="Preview camera",modes=edit,state=state_camera_preview,scene=true},
        {name="camera_keep",view=proc(s:^Session) {camera_preview_end(s,true)},label="Keep cameras",state=state_camera_previewing},
        {name="camera_discard",view=proc(s:^Session) {camera_preview_end(s,false)},label="Discard cameras",state=state_camera_previewing},

        {name="prefab_create",method="prefab.create",params=`{"entities":["$roots"]}`,label="Create prefab",icon=.Save_Prefab,modes=edit,scene=true},
        {name="prefab_apply",method="prefab.apply",params=`{"entity":"$active","whole":true}`,label="Apply to prefab",icon=.Prefab,modes=edit,scene=true},
        {name="prefab_apply_base",method="prefab.apply",params=`{"entity":"$active","whole":true,"target":"Base"}`,label="Apply to base",icon=user(.Up),modes=edit,scene=true},
        {name="prefab_revert",method="prefab.revert",params=`{"entity":"$active","whole":true}`,label="Revert to prefab",icon=.Revert,modes=edit,scene=true},
        {name="prefab_unlink",method="prefab.unlink",params=`{"entity":"$active"}`,label="Unlink prefab",icon=user(.Unlink),modes=edit,scene=true},

        // Of the asset of the card of the browser that has the keyboard, with the keys of the scene.
        {name="asset_delete",view=proc(s:^Session) {asset_delete_ask(s,card_focused(s))},label="Delete",icon=user(.Trash),shortcut=key(.Delete),alternate=key(.Backspace),modes=edit,card=true},
        {name="asset_rename",view=proc(s:^Session) {content_rename_begin(s,card_focused(s))},label="Rename",icon=.Edit,shortcut=key(.F2),modes=edit,card=true},
        {name="asset_duplicate",method="asset.move",params=`{"asset":"$card","copy":true}`,label="Duplicate",icon=user(.Copy),shortcut=key(.D,{.Primary}),modes=edit,card=true},
    }
    for entry in entries {command_bind(s,entry)}
    if s.has_project {tool_entry(s,AI_ANNOTATE_TOOL,"Annotate",ai_annotate_icon())}
}

// ---------------------------------------------------------------- what the entries show that no method says

// A key is of Play or of Stop: an agent plays again a game that plays, a person stops it.
@(private="file") state_play :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode!=.Edit || play_plugin_active(s)}}
@(private="file") state_stop :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode==.Edit && !play_plugin_active(s)}}

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

// Of the procedures of the interface: they have no method to say it.
@(private="file") state_rename :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=len(s.selection.entities)!=1 || watching(s)}}
@(private="file") state_studio_light :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=document_is_prefab(s),checked=s.viewport.studio_light}}
@(private="file") state_hierarchy_panel :: proc(s:^Session,b:^Binding) -> Command_State {return {checked=s.gui.layout.left_open && s.gui.layout.library_tab==.Hierarchy}}
@(private="file") state_release_input :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=!player_processes_captured(s) && (s.mode!=.Play || s.play_input_released)}}
@(private="file") state_ai_chat :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.mode==.Play,checked=ai_chat_open(s.ai) && (s.gui.layout.left_open || play_shown(s))}}
@(private="file") state_source_control :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=!s.has_project,checked=s.gui.layout.left_open && s.gui.layout.library_tab==.Git}}
@(private="file") state_projects :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=s.engine_root=="" || s.projects==nil}}
@(private="file") state_settings :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=!s.has_project,checked=s.gui.modal==.Settings}}
@(private="file") state_camera_preview :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=camera_preview_target(s,shown_world(s))==core.NONE}}
@(private="file") state_camera_previewing :: proc(s:^Session,b:^Binding) -> Command_State {return {disabled=!camera_previewing(s)}}

@(private="file")
state_graphics :: proc(s:^Session,b:^Binding) -> Command_State {
    if d:=asset_document_active(s);d!=nil && asset_document_flat(s,d.kind) {return {disabled=true}}
    return {checked=ui.popup_is_open(s.gui.ctx,graphics_popup(s.gui))}
}

// ---------------------------------------------------------------- what only changes what the person sees, or asks them first

@(private="file") settings_toggle :: proc(s:^Session) {if s.gui.modal==.Settings {modal_close(s.gui)} else {settings_show(s)}}
@(private="file") rename_focus :: proc(s:^Session) {s.gui.layout.right_open,s.inspector.rename=true,true}

// Saves what is in front: the asset of the document, or the scene, asking first about the unsaved assets it uses.
@(private="file")
save_front :: proc(s:^Session) {
    if asset_document_active(s)!=nil {asset_document_save(s)} else {save_request(s)}
}

@(private="file")
shortcuts_show :: proc(s:^Session) {
    ui.popup_close(s.gui.ctx)
    s.gui.modal,s.gui.modal_scroll=.Shortcuts,0
}

@(private="file")
graphics_toggle :: proc(s:^Session) {
    g:=s.gui
    if ui.popup_is_open(g.ctx,graphics_popup(g)) {ui.popup_close(g.ctx);return}
    anchor,_:=ui.widget_rect(g.ctx,shell_id(g,"graphics"))
    ui.popup_open(g.ctx,graphics_popup(g),anchor)
}

// A chat folded with its panel comes back with it instead of closing.
@(private="file")
chat_toggle :: proc(s:^Session) {
    switch {
    case play_shown(s):                                 play_chat_set(s,!s.play_chat_open)
    case ai_chat_open(s.ai) && !s.gui.layout.left_open: s.gui.layout.left_open=true
    case:                                               ai_chat_toggle(s.ai)
    }
}

// Every entity a person selects in the scene.
@(private="file")
select_all :: proc(s:^Session) {
    w:=shown_world(s)
    all:=make([dynamic]core.Entity,context.temp_allocator)
    items:=scene_items(s,w)
    for item in scene_item_next(&items) {if entity_author(w,item.entity)==item.entity {append(&all,item.entity)}}
    history.selection_set(s.selection,all[:])
}

// Frames the selection in the viewport, looking the way it looks now: the image keeps its history.
@(private="file")
focus_selection :: proc(s:^Session) {
    v:=s.viewport
    box:=api_entities_box(s,shown_world(s),s.selection.entities[:])
    free:=free_region(s.gui,v.window)
    free.x-=v.origin.x
    free.y-=v.origin.y
    orbit_frame(&v.orbit,box.min,box.max,v.size,free)
    orbit_sanitize(&v.orbit)
    viewport_camera(v)
}

// Keeps the selected roots for Paste, by their ids: not their data.
@(private="file")
copy_roots :: proc(s:^Session) {
    w:=shown_world(s)
    clear(&s.copied)
    for e in history.selection_roots(s.selection,w,context.temp_allocator) {
        if id:=api_entity_id(w,e);id!=0 {append(&s.copied,id)}
    }
}

// The scene plays as a simulation seen through the selected camera, with the blend of its activation.
@(private="file")
camera_preview_selected :: proc(s:^Session) {
    if !camera_preview_start(s,camera_preview_target(s,shown_world(s))) {notify(s,"The camera could not be previewed: the simulation did not start")}
}

// ---------------------------------------------------------------- the methods the entries of the editor needed

Api_Scene_New_Params :: struct {
    discard:bool `mirai:"optional,label=Drops the unsaved changes of the scene it takes the place of; without it they make it fail"`,
    kind:Document_Kind `mirai:"optional,label=Scene: with a sky and a sun, shown in its own light; Prefab: one root, shown in the studio light and placed as instances"`,
}

Api_Tool_Params :: struct {
    tool:[32]u8 `mirai:"text,label=move rotate or scale: the mode of the gizmo; or the tool of a plugin by the name editor.inspect gives it in commands (paint or terrain or foliage)"`,
    on:bool `mirai:"optional,label=Of the tool of a plugin: false turns it off and gives the scene back to the gizmo"`,
}
Api_Tool_Result :: struct {
    tool:[8]u8 `mirai:"text,label=move rotate or scale"`,
    plugin_tool:[32]u8 `mirai:"text,label=The tool of a plugin that is on; empty when none is"`,
}

Api_Save_All_Result :: struct {
    dirty:bool `mirai:"label=Whether a document still has unsaved changes: one without a file which scene.save gives a path"`,
}

Api_Thumbnail_Result :: struct {
    asked:bool `mirai:"label=The view of the scene is taken in the next frames and kept as its thumbnail"`,
}

@(private)
commands_methods_register :: proc(s:^Session,st:^Api_State) {
    tool_on_default:=Api_Tool_Params{on=true}
    api_register(s,st,{name="scene.new",summary="An empty scene or prefab in place of the document, with an empty history. Fails with unsaved changes unless discard.",params=type_info_of(Api_Scene_New_Params),result=type_info_of(Api_File_Result),flags={.Destructive},run=api_scene_new})
    api_register(s,st,{name="scene.thumbnail",summary="Takes the view of the viewport as the thumbnail of the scene of the document, which the content browser and the projects screen show.",result=type_info_of(Api_Thumbnail_Result),can=scene_thumbnail_can,run=api_scene_thumbnail})
    api_register(s,st,{name="editor.tool",summary="Chooses what the pointer does in the viewport: the mode of the gizmo, or the tool of a plugin, whose panel takes the place of Details while it is on.",params=type_info_of(Api_Tool_Params),result=type_info_of(Api_Tool_Result),defaults=&tool_on_default,flags={.Idempotent},run=api_editor_tool})
    api_register(s,st,{name="editor.save_all",summary="Writes every unsaved asset and every document with changes that has a file.",result=type_info_of(Api_Save_All_Result),run=api_save_all})
}

@(private)
api_scene_new :: proc(s:^Session,call:^api.Call) {
    if api_turn_refused(s,call,"replace the document and its history") {return}
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
    scene_new(s,params.kind==.Prefab)
    api_file_result(s,call)
}

@(private)
scene_thumbnail_can :: proc(s:^Session,params:rawptr) -> string {
    if s.mode==.Edit && scene_thumbnail_takes(s) {return ""}
    return "The thumbnail is that of a scene of the assets in front, out of Play, in an editor that draws and a project with a thumbs folder"
}

@(private)
api_scene_thumbnail :: proc(s:^Session,call:^api.Call) {
    thumbnail_scene_take(s,s.document.id,0,true)
    api.call_result(call,Api_Thumbnail_Result).asked=true
}

@(private)
api_editor_tool :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Tool_Params)
    name:=base.text_get(params.tool[:])
    v:=s.viewport
    if s.edits.preview {tools_release(s)}
    if tool,gizmo:=gizmo_tool(name);gizmo {
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
            if b.tool=="" || b.menu!=.Tools {continue}
            append(&names,b.tool)
            known||=b.tool==name
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
    if api_turn_refused(s,call,"save what others changed: asset.save writes the assets of its turn and scene.save the document") {return}
    if !api_guard(s,call) {return}
    if !collab_can_save(s) {
        api.call_fail(call,api.SERVER_ERROR,"The host of the session saves the shared scene")
        return
    }
    save_all(s)
    api.call_result(call,Api_Save_All_Result).dirty=documents_dirty(s)
}

// ---------------------------------------------------------------- editor.inspect

// Every entry with the method it calls and what it shows now.
api_commands :: proc(s:^Session,allocator:=context.temp_allocator) -> []Api_Editor_Command {
    bindings:=command_bindings(s)
    commands:=make([]Api_Editor_Command,len(bindings),allocator)
    for &b,i in bindings {
        state:=binding_state(s,&b)
        commands[i]={name=b.name,method=b.method,params=b.params,label=binding_label(&b,state),disabled=state.disabled,checked=state.checked}
        // What it flips gives its params: those it would call with now.
        if params:=strings.builder_make(allocator);(b.tool!="" || b.preference!="") && binding_params(s,&b,&params) {commands[i].params=strings.to_string(params)}
        if b.shortcut.set {commands[i].shortcut=shortcut_text(b.shortcut)}
    }
    return commands
}

// The widget of the bar an entry draws, as editor.inspect names it.
command_widget :: proc(g:^Editor_Ui,name:string,index:int=0) -> ui.Id {return ui.id_derive(g.ctx,COMMAND_SCOPE,name,index)}

@(private)
COMMAND_SCOPE :: ui.Id(0x434f4d4d)
