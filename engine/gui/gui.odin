package gui

import "base:runtime"
import "core:fmt"
import "core:mem"
import "mirai:core"
import audio "mirai:engine/audio"
import inp "mirai:engine/input"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The UI of the game. A UI_Screen shows an interface (.ui) over the screen,
// or over the part of a local player, and a World_Widget on a panel at its
// entity or on its mesh; both build their tree in a UI context of the world
// inside the ui phase, read the components and storages their paths name,
// and report what their widgets did as UI_Event. That is how a game shows
// its interfaces; what only code can draw is a Draw node of the .ui, drawn by
// a procedure the game declares with @(draw="name").

VARIANT_CAPACITY :: 64
SCREEN_CAPACITY :: 32  // screens drawn in one frame; the lowest order is left out
EVENT_BATCH :: 16      // events of one interface in one frame
DELIVERED_CAPACITY :: 256 // events of past ticks kept for the ticks a rollback runs again
ORDER_LIMIT :: 15000
DRAW_CAPACITY :: 256
WIDGET_CAPACITY :: 32  // World_Widgets a context builds in a frame: the nearest of those its player sees
PANEL_CAPACITY :: 2*WIDGET_CAPACITY // panels a context gives the renderer: one per widget, and room for those whose commands others split
MESH_CAPACITY :: 16    // World_Widgets drawn on meshes at once
VIEW_CAPACITY :: 8     // cameras shown in interfaces at once
PARTICLE_CAPACITY :: 16 // particle effects shown in interfaces at once
CONTEXT_CAPACITY :: inp.LOCAL_CAPACITY+1 // the window, and the part of each local player

// What a screen takes while it is the top one of its player that is not passive.
UI_Input :: enum u8 {
    Passive, // a HUD: no navigation, keys or actions
    Menu,    // the navigation, the keys and the actions
    Modal,   // as Menu, and the local seats it covers get no actions and the pointer shows
}

// A .ui drawn over the screen. Its paths name a component of entity or a
// storage of the world, and then its fields; what a widget asks for arrives
// as a UI_Event: a control writes the field of a storage it binds, and the
// game writes one of a component. A
// screen whose entity is Hidden, or under one, plays what its nodes play as
// they hide and then goes.
@(component)
UI_Screen :: struct {
    asset:base.Asset_Id `mirai:"kind=.ui"`, // the interface it shows
    order:i32,           // screens of a higher order cover the lower ones
    entity:core.Entity,  // whose components the paths of the interface name first; none: its own
    input:UI_Input,
    input_context:inp.Input_Context, // while it takes input, the seats it covers are in it: its actions, over those of the game; a Modal one leaves the rest nothing instead of blocking every action
    player:u8 `mirai:"max=4"`, // 0: the part of the local player its entity is of (a seat, a body a seat drives or what hangs from them), the window for any other entity; n: the part of local player n
    variant:[VARIANT_CAPACITY]u8 `mirai:"text"`, // of the styles of its nodes that choose none
    back:bool,           // Escape, or East of a gamepad, reports Back while it is on top
    pause:bool,          // Modal: while it shows, the clock of the world stops, unless the game plays in a network session
}

// What a World_Widget takes from the player that points at it.
World_Input :: enum u8 {
    Passive,     // the pointer alone
    Interactive, // while its player points at it and no screen of that player takes input: the focus, the navigation, the keys and the actions
}

// Where a World_Widget is drawn.
World_Target :: enum u8 {
    Overlay, // over the scene, at its entity
    Mesh,    // into a texture that a material slot of the mesh of its entity shows, lit, fogged and hidden as the scene
}

// A .ui at an entity of the world: on a panel that follows it, or on its
// mesh. Each local player sees it from its camera and points at it with its
// ray: through the pointer while the pointer shows, through the center of
// its view while the mouse is captured or it plays with a gamepad.
@(component)
World_Widget :: struct {
    asset:base.Asset_Id `mirai:"kind=.ui"`, // the interface it shows; the paths of its bindings name components of this entity first
    size:[2]f32 `mirai:"min=0"`, // of its surface, in layout units
    sizing:ui.World_Sizing,      // Meters: scale is meters per layout unit. Screen: window points per layout unit at any distance, times the scale of the screens (UI_Settings.reference)
    scale:f32 `mirai:"min=0"`,   // 0: a centimeter, or a point
    facing:ui.World_Facing,      // Fixed follows the rotation of the entity and shows its face toward its forward (-Z)
    pivot:ui.Anchor,             // the point of the panel that sits at the entity
    depth_test:bool,             // the scene in front of it hides it, and the ray does not reach it through the scene
    passive:bool,                // the pointer goes through it
    input:World_Input,
    target:World_Target,
    slot:u32 `mirai:"max=31"`,         // Mesh: the material slot of the mesh that shows it
    pixels:f32 `mirai:"min=0,max=16"`, // Mesh: texels of its texture per layout unit; 0: 2
    emission:f32 `mirai:"min=0"`,      // Mesh: 0 shows it as the base color, lit; above, as light whose white has that luminance, nits
    variant:[VARIANT_CAPACITY]u8 `mirai:"text"`,
    preview:bool, // in the editor, while the world does not play, it shows as it will, without input
}

WORLD_WIDGET_DEFAULT :: World_Widget{size={200,100},scale=0.01,facing=.Billboard,pivot=.Center,depth_test=true,preview=true}

// How the interfaces of the game are sized and what they read their texts from.
@(storage,setting)
UI_Settings :: struct {
    reference:[2]f32 `mirai:"min=0"`, // the size in points the interfaces are designed for: they scale to fit the window, or the part of a player; zero: one unit per point
    // The code of the language its texts are written in ("en"): the first
    // of the .strings the tools write, what a key shows where another lacks
    // it. The languages of the game are those its .strings name.
    source:[LANGUAGE_CODE]u8 `mirai:"text"`,
    prompts:base.Asset_Id, // the images of the prompts (.prompts); none: they are drawn
    // Images of inputs that win over those of the pack: Project Settings > UI
    // shows them with the inputs the game binds.
    prompt_images:[UI_PROMPT_IMAGES]UI_Prompt_Image,
}

UI_PROMPT_IMAGES :: 32

// The image of an input of a family of devices.
UI_Prompt_Image :: struct {
    family:ui.Prompt_Family,
    input:ui.Prompt_Input,
    key:[16]u8 `mirai:"text"`, // of the input Key, as core.Key names it
    texture:base.Asset_Id,     // all of it is the image; none: a free entry
}

// The entry of an input in the images of the settings; -1: none.
prompt_image_find :: proc "contextless" (settings:^UI_Settings,family:ui.Prompt_Family,input:ui.Prompt_Input,key:string) -> int {
    for &image,i in settings.prompt_images {
        if image.texture!={} && image.family==family && image.input==input && (input!=.Key || base.text_get(image.key[:])==key) {return i}
    }
    return -1
}

UI_SETTINGS_DEFAULT :: UI_Settings{source={0='e',1='n'}}

LANGUAGE_CODE :: 16 // bytes of the code of a language, its NUL included, as a .strings keeps it

// What the player chose for the interfaces: the language they show and a
// scale over the one that fits them. An option of the player, which the
// options menu of the game writes and save keeps in the options of the player.
@(storage,setting="machine")
UI_Preferences :: struct {
    language:[LANGUAGE_CODE]u8 `mirai:"text"`, // the code of the one the interfaces show; empty: the one their texts are written in
    scale:f32 `mirai:"min=0.25,max=4"`, // over the one that fits the window or the part of a player
}

UI_PREFERENCES_DEFAULT :: UI_Preferences{scale=1}

// What the localized texts of the interfaces show: the code of the language
// the player chose, as base.text finds it.
ui_language :: proc(preferences:^UI_Preferences) -> string {return base.text_get(preferences.language[:])}

// The first kinds are those of ui.Tree_Event_Kind.
UI_Event_Kind :: enum u8 {
    Clicked,   // a button, by the pointer, the navigation or its action
    Changed,   // a checkbox, slider, field, selector, dropdown or radio, or a button that binds a value: on, value or text is what it wrote to the storage it binds, or asks the game to write to the component
    Submitted, // Enter in a field
    Hovered,
    Unhovered,
    Focused,
    Unfocused,
    Dragged,
    Dropped,   // what was dragged was let go over the node: from, from_item and from_entity say what
    Finished,  // an animation of play_animation ended: from is its name
    Right_Clicked,
    Double_Clicked,
    Pressed,
    Released,
    Drag_Entered, // something dragged came over a drop
    Drag_Left,
    Opened,    // a popup, a modal or a context menu
    Closed,
    Link,      // a link of a rich text: from is its name
    Back,      // Escape or East on the screen on top, when it reports it; name is 0
    Menu,      // the player pressed the Menu action and no interface used it; entity and name are 0
}
#assert(int(UI_Event_Kind.Clicked)==int(ui.Tree_Event_Kind.Clicked) && int(UI_Event_Kind.Changed)==int(ui.Tree_Event_Kind.Changed))
#assert(int(UI_Event_Kind.Submitted)==int(ui.Tree_Event_Kind.Submitted) && int(UI_Event_Kind.Hovered)==int(ui.Tree_Event_Kind.Hovered))
#assert(int(UI_Event_Kind.Unhovered)==int(ui.Tree_Event_Kind.Unhovered) && int(UI_Event_Kind.Focused)==int(ui.Tree_Event_Kind.Focused))
#assert(int(UI_Event_Kind.Unfocused)==int(ui.Tree_Event_Kind.Unfocused) && int(UI_Event_Kind.Dragged)==int(ui.Tree_Event_Kind.Dragged))
#assert(int(UI_Event_Kind.Dropped)==int(ui.Tree_Event_Kind.Dropped) && int(UI_Event_Kind.Finished)==int(ui.Tree_Event_Kind.Finished))
#assert(int(UI_Event_Kind.Right_Clicked)==int(ui.Tree_Event_Kind.Right_Clicked) && int(UI_Event_Kind.Link)==int(ui.Tree_Event_Kind.Link))
#assert(len(UI_Event_Kind)==len(ui.Tree_Event_Kind)+2)

// What a widget of a UI_Screen or a World_Widget did.
UI_Event :: struct {
    entity:core.Entity, // the one with the UI_Screen or the World_Widget
    name:u64,           // base.name_hash of the name of the node
    kind:UI_Event_Kind,
    on:bool,
    item:i32,           // the element of the list the node is in; -1: in none
    value:f64,
    from:u64,
    from_item:i32,
    from_entity:core.Entity,
    text:[ui.TREE_EVENT_TEXT]u8,
    rect:[4]f32,        // where the node was in the last frame: x, y, width, height in window points on a UI_Screen, in layout units of its panel on a World_Widget; zero before
}

// What the widgets of the frame drawn last did, pushed as they reach the
// game: in the first fixed tick that follows it, or, when no tick runs (the
// time of the world stopped, as under a pause menu), in the frame phase of
// the next frame. A step of either phase gets each once; a tick that runs
// again (Time.resimulating) gets the ones it got the first time.
@(storage)
UI_Events :: struct {
    using queue:core.Events(UI_Event),
    pointer_consumed:bool,  // the pointer was over the UI or held by a widget
    keyboard_consumed:bool, // a field, a popup or the navigation focus had the keyboard
    asked:^Asked_Names,     // of the Gui of its world, where the names steps ask of it go
}

// What the game asked an interface by name: gui_frame_begin says once what a
// name a screen does not have is.
Asked_Name :: struct {
    entity:core.Entity,
    name:u64,
    text:[ui.TREE_NAME_CAPACITY]u8,
    checked:bool,
}
Asked_Names :: struct {
    names:[GUI_ASKS]Asked_Name,
    count:int,
}
GUI_ASKS :: 128

// The particle effects the interfaces show in this frame, each drawn into
// the effect view of its texture (render.Effect_View) by the plugin that
// plays effects, which reads them. gui_frame_begin clears it and the
// interfaces fill it as they are built.
@(storage)
UI_Effects :: struct {
    using queue:core.Queue(UI_Effect),
}

// What a Particles node shows: the effect (a .particle) of the element key,
// in the texture view.
UI_Effect :: struct {
    key:u64,
    effect:base.Asset_Id,
    view:render.Texture_Handle,
}

UI_Request_Kind :: enum u8 {
    Play,  // anim on node
    Focus, // the focus goes to node
}

REQUEST_NAME_CAPACITY :: ui.TREE_NAME_CAPACITY

// What the game asks of an interface it shows, applied as it builds next.
UI_Request :: struct {
    kind:UI_Request_Kind,
    entity:core.Entity, // the one with the UI_Screen or the World_Widget
    node:[REQUEST_NAME_CAPACITY]u8,
    anim:[REQUEST_NAME_CAPACITY]u8,
    item:i32,           // of a node in lists, the element of the innermost one (UI_Event.item); -1: the first
}

@(storage,queue)
UI_Requests :: struct {
    using queue:core.Queue(UI_Request),
}

// Plays the animation anim of the interface of an entity on its node called
// node: a Finished event with the animation in from says when it ends.
play_animation :: proc(r:^UI_Requests,entity:core.Entity,node,anim:string,item:=i32(-1)) {
    request:=UI_Request{kind=.Play,entity=entity,item=item}
    _=base.text_set(request.node[:],node);_=base.text_set(request.anim[:],anim)
    core.push(&r.queue,request)
}

// Moves the focus to the node called node of the interface of an entity.
focus :: proc(r:^UI_Requests,entity:core.Entity,node:string,item:=i32(-1)) {
    request:=UI_Request{kind=.Focus,entity=entity,item=item}
    _=base.text_set(request.node[:],node)
    core.push(&r.queue,request)
}

Delivered_Event :: struct {
    tick:u64,
    event:UI_Event,
}

// A component or a storage the paths of the interfaces name, by the name_hash of its name.
Bound_Source :: struct {
    name:u64,
    type:typeid,
    info:^runtime.Type_Info,
    index:serial.Type_Index,
    storage:bool,
}

Action_Name :: struct {hash:u64,action:inp.Action}

// The UI contexts of a world and what its interfaces are showing: each world
// keeps its own, never copied, so that two worlds built in one frame keep
// their widgets and their events apart. Shared: the editor part of a plugin
// may draw in the context of the window between gui_frame_begin and
// gui_frame_end.
@(storage,host,by_world,free="gui_free",shared)
Gui :: struct {
    surfaces:[CONTEXT_CAPACITY]Surface, // 0: the window; n: local player n
    views:[CONTEXT_CAPACITY]Player_View, // the camera and the part of each context, for its world panels
    wanted:bool,               // a ui step asked for the context of the window in the last frame
    asked:bool,                // and in this one
    allocator:runtime.Allocator,
    settings:UI_Settings,      // of this frame, which the sources of the contexts read
    preferences:UI_Preferences, // of this frame, as settings
    prompts:u64,               // changes with the pack and the images of the prompts of settings
    schema:serial.Schema,
    schema_ready:bool,
    schema_info:^core.World_Info, // the types of the schema are those of this world: another one starts it again
    sources:[dynamic]Bound_Source,
    source_index:map[u64]int,  // of sources, by name
    instances:[dynamic]Instance,
    index:core.Entity_Map(Instance_Slots), // where the instances of each entity are
    plan:[dynamic]Planned,     // what this frame builds, in order
    candidates:[dynamic]Widget_Candidate, // the World_Widgets in sight, while they are planned
    frame:u64,
    deliveries:u64,            // times the events of a frame went to the game: what a widget wrote waits for one past it
    pending:[dynamic]UI_Event, // of the frame drawn, until they go to UI_Events
    delivered:[DELIVERED_CAPACITY]Delivered_Event, // a ring, in the order of the ticks that took them
    delivered_count:int,
    requests:[dynamic]UI_Request, // taken, until the interface they name builds
    unblock:[dynamic]core.Entity, // Modal screens that went and still block the seats
    views_shown:[dynamic]View_Texture,
    particles:[PARTICLE_CAPACITY]Particle_Texture,
    meshes:[MESH_CAPACITY]Mesh_Surface,
    actions:[dynamic]Action_Name, // the input actions by the name_hash of their names
    actions_ready:bool,
    pointer_consumed,keyboard_consumed:bool,
    names_asked:Asked_Names, // what steps asked by name, each checked once against the screen that shows
    pausing:bool,              // a Modal screen with pause shows this frame
    clock_held:bool,           // it stopped the clock, and gives it back when none shows
    modal_up:bool,             // a Modal is on top this frame
    escape_used:bool,          // an interface used the Escape of this frame
    cursor:ui.Cursor,          // the last one given to the window
    skipped:u64,               // frames of a context that showed its last one again
    kept:u64,                  // screens drawn again from what they drew, without being built
    dropped_widgets:u64,       // World_Widgets in sight left out for WIDGET_CAPACITY or MESH_CAPACITY
}

// The context of the window while its frame is open, for a ui step of the
// engine, the editor or the editor part of a plugin that builds widgets over
// the game. nil outside the ui phase; the first call asks for the frame,
// which then exists from the next one, and a window asked for is built every
// frame. A game has no ui steps: it shows .ui documents.
gui_context :: proc(gui:^Gui) -> ^ui.Context {
    if gui==nil {return nil}
    gui.asked=true
    s:=&gui.surfaces[0]
    return s.open?s.ctx:nil
}

// Whether the UI had the pointer or the keyboard when the last frame was built.
gui_consumed :: proc "contextless" (events:^UI_Events) -> (pointer,keyboard:bool) {
    return events.pointer_consumed,events.keyboard_consumed
}

// The last event of a kind of the node called name of an interface of the
// entity: of several in one frame, the one that came last says what the
// widget asks for now. Every helper below reads that one.
ui_event :: proc(events:^UI_Events,entity:core.Entity,name:string,kind:UI_Event_Kind) -> (found:UI_Event,ok:bool) {
    event:=event_asked(events,entity,name,kind)
    if event==nil {return}
    return event^,true
}

@(private)
event_find :: proc(events:[]UI_Event,entity:core.Entity,name:string,kind:UI_Event_Kind) -> ^UI_Event {
    hash:=name!=""?base.name_hash(name):0
    #reverse for &event in events {
        if event.entity==entity && event.name==hash && event.kind==kind {return &event}
    }
    return nil
}

// The event a step asks for, whose name the frame then checks against the
// screen. Without a Gui there are no events.
@(private)
event_asked :: proc(events:^UI_Events,entity:core.Entity,name:string,kind:UI_Event_Kind) -> ^UI_Event {
    if events==nil {return nil}
    if events.asked!=nil {asked_add(events.asked,entity,name)}
    return event_find(events.items[:],entity,name,kind)
}

// A name a step asked: an unnamed event, one the frame already knows and one
// that does not fit go by without work; the frame checks the rest.
@(private)
asked_add :: proc "contextless" (asked:^Asked_Names,entity:core.Entity,name:string) {
    if name=="" || entity==core.NONE {return}
    hash:=base.name_hash(name)
    for &a in asked.names[:asked.count] {if a.entity==entity && a.name==hash {return}}
    if asked.count>=len(asked.names) {return}
    a:=&asked.names[asked.count]
    asked.count+=1
    a^={entity=entity,name=hash}
    ui.tree_text_set(a.text[:],name)
}

// Whether the node called name of an interface of the entity was clicked.
clicked :: proc(events:^UI_Events,entity:core.Entity,name:string) -> bool {
    return event_asked(events,entity,name,.Clicked)!=nil
}

// Which element of its list a button that was clicked is in.
clicked_item :: proc(events:^UI_Events,entity:core.Entity,name:string) -> (item:i32,ok:bool) {
    event:=ui_event(events,entity,name,.Clicked) or_return
    return event.item,true
}

// Whether the checkbox called name of an interface of the entity changed, and
// what it asks for: the game writes it to the field the checkbox binds.
changed :: proc(events:^UI_Events,entity:core.Entity,name:string) -> (on,ok:bool) {
    event:=ui_event(events,entity,name,.Changed) or_return
    return event.on,true
}

// The number a slider, selector, dropdown or radio called name asks for.
changed_value :: proc(events:^UI_Events,entity:core.Entity,name:string) -> (value:f64,ok:bool) {
    event:=ui_event(events,entity,name,.Changed) or_return
    return event.value,true
}

// The text a field called name asks for as it is typed in: the game writes
// it to the field the node binds. Valid while the events are.
changed_text :: proc(events:^UI_Events,entity:core.Entity,name:string) -> (text:string,ok:bool) {
    event:=event_asked(events,entity,name,.Changed)
    if event==nil {return}
    return base.text_get(event.text[:]),true
}

// The text a field called name holds when Enter was pressed in it. Valid
// while the events are.
submitted :: proc(events:^UI_Events,entity:core.Entity,name:string) -> (text:string,ok:bool) {
    event:=event_asked(events,entity,name,.Submitted)
    if event==nil {return}
    return base.text_get(event.text[:]),true
}

// What was let go over the node called name: the node dragged (from, its
// from_item) and the entity of its interface (from_entity).
dropped :: proc(events:^UI_Events,entity:core.Entity,name:string) -> (event:UI_Event,ok:bool) {
    return ui_event(events,entity,name,.Dropped)
}

// Whether the animation anim that play_animation started on node ended.
finished :: proc(events:^UI_Events,entity:core.Entity,node,anim:string) -> bool {
    if events==nil {return false}
    for event in events.items {
        if event.entity==entity && event.kind==.Finished && event.name==base.name_hash(node) && event.from==base.name_hash(anim) {return true}
    }
    return false
}

// Whether the screen of the entity reported Back.
back :: proc(events:^UI_Events,entity:core.Entity) -> bool {
    return event_asked(events,entity,"",.Back)!=nil
}

// Whether the player pressed the Menu action (Menu_Action: Escape, Start of a
// gamepad, rebound like any action) and no interface used that Escape. What a
// game does with it is its own: open or close a menu.
menu_pressed :: proc(events:^UI_Events) -> bool {return event_asked(events,core.NONE,"",.Menu)!=nil}

// The events of the last frame go to the game once, in the first tick that
// follows it; a tick that runs again gets those it got.
@(step="fixed",stage="input")
gui_events_deliver :: proc(events:^UI_Events,gui:^Gui,time:core.Time) {
    if !events_follow(events,gui) {return}
    if time.resimulating {
        for i in max(gui.delivered_count-DELIVERED_CAPACITY,0)..<gui.delivered_count {
            if d:=gui.delivered[i%DELIVERED_CAPACITY];d.tick==time.tick {core.push(&events.queue,d.event)}
        }
        return
    }
    // The clock went back, as a save loads: the ticks kept are of another run.
    if gui.delivered_count>0 && gui.delivered[(gui.delivered_count-1)%DELIVERED_CAPACITY].tick>=time.tick {gui.delivered_count=0}
    for event in gui.pending {
        gui.delivered[gui.delivered_count%DELIVERED_CAPACITY]={time.tick,event}
        gui.delivered_count+=1
    }
    events_pending(events,gui)
}

// In a frame no tick ran in, the events of the last frame go in its frame phase.
@(step="frame",stage="input")
gui_events_frame :: proc(events:^UI_Events,gui:^Gui) {
    if events_follow(events,gui) {events_pending(events,gui)}
}

// What the last frame knew of the UI, for the steps that read the events.
@(private)
events_follow :: proc(events:^UI_Events,gui:^Gui) -> bool {
    if gui==nil {
        events.asked=nil
        return false
    }
    events.pointer_consumed,events.keyboard_consumed,events.asked=gui.pointer_consumed,gui.keyboard_consumed,&gui.names_asked
    return true
}

@(private)
events_pending :: proc(events:^UI_Events,gui:^Gui) {
    if len(gui.pending)==0 {return}
    for event in gui.pending {core.push(&events.queue,event)}
    clear(&gui.pending)
    gui.deliveries+=1
}

// What each context builds this frame: the screens in order, the top one of
// each player that is not passive taking input, the World_Widgets each
// player sees, the copies of what they bind when it changed; a context with
// nothing new shows its last frame again.
@(step="ui",stage="begin")
gui_frame_begin :: proc(
    world:core.World_Ref,screens:core.Read(UI_Screen),widgets:core.Read(World_Widget),worlds:core.Read(core.World_Transform),
    hidden:core.Read(render.Hidden),parents:core.Read(core.Parent),meshes:core.Read(render.Mesh_Renderer),settings:UI_Settings,preferences:UI_Preferences,time:core.Time,
    seat_state:core.Ref(inp.Seats),seats:core.Read(inp.Seat),moves:core.Read(inp.Move_Input),bindings:core.Ref(inp.Input_Map),actions:core.Ref(inp.Frame_Actions),
    device:core.Frame_Input,cameras:core.Read(render.Camera),exposures:core.Read(render.Exposure),view_volumes:core.Read(render.View_Volume),volumes:core.Read(volume.Volume),
    requests:^UI_Requests,effects:^UI_Effects,sounds:^audio.Sound_Requests,gui:^Gui,app:^host.App,problems:^core.Problems,
) {
    frame_begin(world,screens,widgets,worlds,hidden,parents,meshes,settings,preferences,time,seat_state,seats,moves,bindings,actions,device,cameras,exposures,view_volumes,volumes,requests,effects,sounds,gui,app,problems,false)
}

// The preview of the editor's world, while it does not play: the
// World_Widgets with preview alone, as they will show, without input or
// screens. A world that plays has the game's.
@(step="ui",stage="begin",loops="editor")
gui_preview_begin :: proc(
    world:core.World_Ref,screens:core.Read(UI_Screen),widgets:core.Read(World_Widget),worlds:core.Read(core.World_Transform),
    hidden:core.Read(render.Hidden),parents:core.Read(core.Parent),meshes:core.Read(render.Mesh_Renderer),settings:UI_Settings,preferences:UI_Preferences,time:core.Time,
    seat_state:core.Ref(inp.Seats),seats:core.Read(inp.Seat),moves:core.Read(inp.Move_Input),bindings:core.Ref(inp.Input_Map),actions:core.Ref(inp.Frame_Actions),
    device:core.Frame_Input,cameras:core.Read(render.Camera),exposures:core.Read(render.Exposure),view_volumes:core.Read(render.View_Volume),volumes:core.Read(volume.Volume),
    requests:^UI_Requests,effects:^UI_Effects,sounds:^audio.Sound_Requests,gui:^Gui,app:^host.App,problems:^core.Problems,
) {
    if time.playing {return}
    frame_begin(world,screens,widgets,worlds,hidden,parents,meshes,settings,preferences,time,seat_state,seats,moves,bindings,actions,device,cameras,exposures,view_volumes,volumes,requests,effects,sounds,gui,app,problems,true)
}

@(private)
frame_begin :: proc(
    world:core.World_Ref,screens:core.Read(UI_Screen),widgets:core.Read(World_Widget),worlds:core.Read(core.World_Transform),
    hidden:core.Read(render.Hidden),parents:core.Read(core.Parent),meshes:core.Read(render.Mesh_Renderer),settings:UI_Settings,preferences:UI_Preferences,time:core.Time,
    seat_state:core.Ref(inp.Seats),seats:core.Read(inp.Seat),moves:core.Read(inp.Move_Input),bindings:core.Ref(inp.Input_Map),actions:core.Ref(inp.Frame_Actions),
    device:core.Frame_Input,cameras:core.Read(render.Camera),exposures:core.Read(render.Exposure),view_volumes:core.Read(render.View_Volume),volumes:core.Read(volume.Volume),
    requests:^UI_Requests,effects:^UI_Effects,sounds:^audio.Sound_Requests,gui:^Gui,app:^host.App,problems:^core.Problems,preview:bool,
) {
    if gui==nil {return}
    if effects!=nil {clear(&effects.items)}
    asked_check(gui,app,problems)
    gui.frame+=1
    gui.pausing=false
    gui.settings,gui.preferences=settings,preferences
    gui.prompts=base.hash64(mem.slice_to_bytes(gui.settings.prompt_images[:]),base.hash64(mem.ptr_to_bytes(&gui.settings.prompts)))
    for &s in gui.surfaces {s.open,s.skipped=false,false}
    clear(&gui.plan)
    append(&gui.requests,..core.take(&requests.queue))
    if app.assets==nil && !gui.wanted || (preview || core.count(screens)==0) && core.count(widgets)==0 && len(gui.instances)==0 && !gui.wanted {
        clear(&gui.requests)
        for &s in gui.surfaces {s.shown=false}
        return
    }
    if gui.surfaces[0].ctx==nil && !surface_create(gui,app,0) {return}
    count:=max(seat_state.local_count,1)
    views_update(gui,app,count,seat_state.focus)
    if !preview {plan_screens(gui,app,world,screens,hidden,parents,seats,moves,time,seat_state.local_count,problems)}
    plan_widgets(gui,app,world,widgets,worlds,meshes,hidden,parents,time,count,problems,preview)
    for &entry in gui.plan {
        for request in gui.requests {
            if request.entity==entry.entity {gui.instances[entry.instance].changed=true}
        }
    }
    pads:=device.gamepads
    gamepads:=pads[:]
    if preview {gamepads=nil}
    for &s,p in gui.surfaces {
        has:=p==0 && gui.wanted
        world_panels:=false
        for entry in gui.plan {
            has||=entry.player==p
            world_panels||=entry.player==p && entry.world
        }
        if !has {
            s.shown=false
            continue
        }
        if s.ctx==nil && !surface_create(gui,app,p) {continue}
        if s.density!=app.density && ui.context_set_density(s.ctx,app.density) {s.density=app.density}
        keyboard:=!preview && (p==0 || count==1 || seat_state.focus==p-1)
        gamepad:=p==0 || count==1?-1:p-1
        family_update(&s.family,device.device,gamepads,keyboard,gamepad)
        s.rect=surface_rect(app,p,count)
        input:=surface_input(&s.repeat,app,settings,preferences.scale,gamepads,s.rect,keyboard,gamepad,p==0)
        if world_panels && !preview {surface_aim(gui,app,&s,p,&input,keyboard)}
        key:=surface_key(gui,app,p,input,s.family)
        if surface_skips(&s,p==0 && gui.wanted,input,key,device.input,surface_changed(gui,p)) {
            s.skipped=true
            gui.skipped+=1
            continue
        }
        s.key=key
        s.input=input
        s.viewed,s.animating=false,false
        source_bind(&s,gui,app,p,seat_state,seats,bindings,actions,cameras,exposures,view_volumes,volumes,worlds,settings,gamepad,effects,sounds)
        if world_panels && !preview {meshes_aim(gui,app.assets,app.renderer,&app.extras,&s,p,input.ray,meshes,worlds)}
        ui.frame_begin(s.ctx,input)
        s.open=true
    }
}

// Builds what gui_frame_begin planned in the contexts it opened.
@(step="ui")
gui_widgets :: proc(world:core.World_Ref,gui:^Gui,app:^host.App,problems:^core.Problems) {
    widgets_build(world,gui,app,problems)
}

@(step="ui",loops="editor")
gui_preview_widgets :: proc(world:core.World_Ref,gui:^Gui,app:^host.App,time:core.Time,problems:^core.Problems) {
    if time.playing {return}
    widgets_build(world,gui,app,problems)
}

@(private)
widgets_build :: proc(world:core.World_Ref,gui:^Gui,app:^host.App,problems:^core.Problems) {
    if gui==nil {return}
    for &s,p in gui.surfaces {
        if !s.open {continue}
        ctx:=s.ctx
        // A World_Widget that takes input: the interactive one the ray of the
        // player reached, while no screen of the player takes input.
        reached:=ui.world_panel_reached(ctx)
        for entry in gui.plan {if entry.player==p && entry.top {reached=0}}
        // The layers of what floats in a screen count from its order. A
        // screen whose order the layers of a lower one reach goes up to stay
        // over them.
        top:=int(min(i32))
        for &entry in gui.plan {
            if entry.player!=p {continue}
            instance:=&gui.instances[entry.instance]
            content:=entry.content
            if entry.world {
                id:=ui.id(ctx,"world",core.entity_index(entry.entity))
                entry.top=entry.interactive && reached!=0 && reached==id
                entry.passive=!entry.top
                // Looked away from: its focus goes, and comes back when it is pointed at again.
                if !entry.top && instance.top && ctx.focus==instance.focus {ui.focus_set(ctx,0)}
                if !ui.world_panel_begin(ctx,id,entry.panel) {continue}
                ui.id_push(ctx,id)
                screen_build(world,gui,app,ctx,&s,instance,&entry,problems)
                ui.id_pop(ctx)
                ui.world_panel_end(ctx)
                continue
            }
            layer:=max(int(clamp(entry.order,-ORDER_LIMIT,ORDER_LIMIT)),top-int(content.low))
            layer=min(layer,int(max(i16))-int(content.high))
            top=layer+int(content.high)
            scale:=ctx.scale
            ui.id_push(ctx,screen_scope(ctx,entry.entity))
            root:=ui.Box{
                id=ui.id(ctx,"root"),layout={width=ui.fixed(s.rect.z/scale),height=ui.fixed(s.rect.w/scale)},
                float={to=.Surface,offset=s.rect.xy/scale,layer=i16(layer)},
            }
            // A screen that did not change and that no input reaches is drawn
            // again from what it drew, without being built.
            retained:=ui.id(ctx,"retained")
            retain:=screen_retains(gui,ctx,instance,&entry)
            if instance.changed {instance.revision+=1}
            if retain && !ui.retained_begin(ctx,retained,screen_key(app.assets,ctx,instance,&entry,layer,s.rect)~gui.prompts) {
                instance_kept(instance,&entry)
                gui.kept+=1
            } else {
                ui.box_begin(ctx,root)
                // What floats on the screen or its safe area floats on the part of its player.
                screen_build(world,gui,app,ctx,&s,instance,&entry,problems,root.id,{s.rect.x/scale,s.rect.y/scale,s.rect.z/scale,s.rect.w/scale})
                ui.box_end(ctx,root)
                if retain {ui.retained_end(ctx,retained)}
            }
            ui.id_pop(ctx)
        }
    }
    for &request in gui.requests {
        kind:=request.kind==.Play?"play_animation":"focus"
        core.report(problems,request.entity,"gui.request","a %s of node '%s' was not applied: this entity shows no interface this frame; ask while its UI_Screen or World_Widget is shown",kind,base.text_get(request.node[:]))
    }
    clear(&gui.requests)
    instances_sweep(gui)
}

// The frames per second at the top right of the game, while the graphics settings ask for them.
@(step="ui",stage="end",before="gui_frame_end")
fps_overlay :: proc(graphics:render.Graphics_Settings,gui:^Gui,app:^host.App) {
    if !graphics.show_fps || app.world==nil {return}
    ctx:=gui_context(gui)
    if ctx==nil {return}
    if ui.anchored(ctx,ui.id(ctx,"fps"),.Top_Right,{-12,12},{padding={8,4,8,4}},ui.LAYER_TOAST) {
        ui.text(ctx,fmt.tprintf("%.0f FPS",app.stats.fps),{size=14,color={255,255,255,255},shadow={1,1},shadow_color={0,0,0,200}})
    }
}

// Ends the frames, hands what each context shows to the renderer (the
// players under the window, the panels of a player in its view alone, the
// widgets on meshes into their textures), and does what the screen on top
// asks of the window and the seats.
@(step="ui",stage="end")
gui_frame_end :: proc(
    gui:^Gui,app:^host.App,seat_state:core.Ref(inp.Seats),seats:core.Read(inp.Seat),seat_requests:^inp.Seat_Requests,
    contexts:core.Ref(inp.Input_Contexts),context_requests:^inp.Context_Requests,problems:^core.Problems,
) {
    frame_end(gui,app,seat_state,seats,seat_requests,contexts,context_requests,problems,false)
}

// The preview's frame: its layers and panels, and nothing of the window's
// cursor or mouse, which are the editor's.
@(step="ui",stage="end",loops="editor")
gui_preview_end :: proc(
    gui:^Gui,app:^host.App,time:core.Time,seat_state:core.Ref(inp.Seats),seats:core.Read(inp.Seat),seat_requests:^inp.Seat_Requests,
    contexts:core.Ref(inp.Input_Contexts),context_requests:^inp.Context_Requests,problems:^core.Problems,
) {
    if time.playing {return}
    frame_end(gui,app,seat_state,seats,seat_requests,contexts,context_requests,problems,true)
}

@(private)
frame_end :: proc(
    gui:^Gui,app:^host.App,seat_state:core.Ref(inp.Seats),seats:core.Read(inp.Seat),seat_requests:^inp.Seat_Requests,
    contexts:core.Ref(inp.Input_Contexts),context_requests:^inp.Context_Requests,problems:^core.Problems,preview:bool,
) {
    if gui==nil {return}
    gui.wanted,gui.asked=gui.asked,false
    gui.pointer_consumed,gui.keyboard_consumed=false,false
    gui.escape_used=false
    cursor:=ui.Cursor.Default
    for i in 1..=CONTEXT_CAPACITY {
        p:=i%CONTEXT_CAPACITY
        s:=&gui.surfaces[p]
        if s.open {
            s.open=false
            gui.escape_used||=s.ctx.escape_used
            frame:=ui.frame_end(s.ctx)
            nesting_report(s,problems)
            s.pointer,s.keyboard,s.cursor=frame.pointer_consumed,frame.keyboard_consumed,s.ctx.cursor
            // An element on its way to a new layout moves the next frame too: no screen of the context is kept.
            if frame.transitioning {
                s.animating=true
                for entry in gui.plan {if entry.player==p {gui.instances[entry.instance].animating=true}}
            }
            host.app_ui_font_sync(app,s.ctx)
            converted:=host.ui_frame_split(frame,s.draws,s.panels,s.offscreen,s.offscreen_draws,gui.views[p].panels)
            s.layer,s.draw_count,s.panel_count=converted.layer,converted.draw_count,converted.panel_count
            s.shown=true
            if converted.dropped>0 {
                core.report(problems,core.NONE,"gui.draws","%d draw commands of the interfaces of a frame were left out: they did not fit what the renderer takes, or a layer was not closed; draw fewer widgets or layers",converted.dropped)
            }
            meshes_draw(gui,&app.extras,s.offscreen[:converted.offscreen_count])
        }
        if !s.shown {continue}
        if s.cursor!=.Default && !s.input.pointer_absent {cursor=s.cursor}
        gui.pointer_consumed||=s.pointer
        gui.keyboard_consumed||=s.keyboard
        if s.draw_count>0 {host.extras_ui_layer_add(&app.extras,s.layer)}
        for panel in s.panels[:s.panel_count] {host.extras_world_panel_add(&app.extras,panel)}
    }
    if preview {
        views_sweep(gui,app.renderer)
        particles_sweep(gui,app.renderer)
        meshes_sweep(gui,app.renderer)
        return
    }
    gui.modal_up=modal_apply(gui,seat_state,seats,seat_requests,contexts,context_requests)
    if app.platform!=nil {
        // The player's: in the editor, the cursor is that of the editor.
        if app.world!=nil && (cursor!=gui.cursor || gui.modal_up) {
            CURSORS :: [ui.Cursor]platform.Cursor{.Default=.Default,.Text=.Text,.Resize_Horizontal=.Resize_Horizontal}
            cursors:=CURSORS
            platform.window_set_cursor(app.platform,cursors[cursor])
            gui.cursor=cursor
        }
    }
    views_sweep(gui,app.renderer)
    particles_sweep(gui,app.renderer)
    meshes_sweep(gui,app.renderer)
}

// The interfaces of a World that is freed go with it, and the events it had
// not delivered.
@(step="release")
gui_release :: proc(gui:^Gui,renderer:^render.Renderer) {
    if gui==nil {return}
    instances_clear(gui)
    clear(&gui.pending)
    for view in gui.views_shown {render.view_texture_remove(renderer,view.texture)}
    clear(&gui.views_shown)
    for &shown in gui.particles {if shown.texture!=0 {render.ui_texture_remove(renderer,shown.texture)};shown={}}
    for &mesh in gui.meshes {if mesh.texture!=0 {render.ui_texture_remove(renderer,mesh.texture)};mesh={}}
}

@(private)
instances_clear :: proc(gui:^Gui) {
    for &instance in gui.instances {instance_free(gui,&instance)}
    clear(&gui.instances)
    core.entity_map_clear(&gui.index)
}

// What a world kept of the UI of the game, once it is freed.
gui_free :: proc(gui:^Gui) {
    instances_clear(gui)
    a:=gui.allocator
    for &s in gui.surfaces {
        if s.ctx==nil {continue}
        ui.context_destroy(s.ctx)
        free(s.ctx,a)
        delete(s.draws,a);delete(s.panels,a);delete(s.offscreen,a);delete(s.offscreen_draws,a)
    }
    delete(gui.sources);delete(gui.source_index);delete(gui.instances);delete(gui.plan);delete(gui.candidates);delete(gui.pending)
    delete(gui.requests);delete(gui.unblock);delete(gui.views_shown);delete(gui.actions)
    core.entity_map_destroy(&gui.index)
    if gui.schema_ready {serial.schema_destroy(&gui.schema)}
    gui^={}
}
