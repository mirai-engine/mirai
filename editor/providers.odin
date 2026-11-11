package editor

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"
import mm "mirai:std/math"

// What a plugin gives the editor for what it simulates, as it gives cards:
// an Editor storage whose sole field is the provider, filled by its default
// procedure. Without the plugin, what it provides is not there.

// The bodies of Simular (physics): the gizmo drives a body without changing
// what the scene saves.
Simulation_Provider :: struct {
    owner:proc(w:core.World_Ref,e:core.Entity) -> core.Entity,                          // the entity whose body e is part of; none without a body
    move:proc(w:core.World_Ref,e:core.Entity,position:[3]f32,rotation:mm.Quat) -> bool, // heads the body of its owner e there while held
    release:proc(w:core.World_Ref,e:core.Entity) -> bool,
    settle:proc(w:core.World_Ref,app:^host.App), // takes what was written as its own without simulating time
}

// What a plugin adds to Play: a game of its own that the Play button starts
// (multiplayer: a game on the network, with players in other processes), the
// runs a turn plays it with, and what a shared session tells its guests of it.
// The editor asks it at these points; a nil procedure is a point it does not
// take.
Play_Provider :: struct {
    // Play was asked from Edit: taken when the plugin starts its game instead,
    // with why it could not. online and ping come from play.start: -1, what
    // its menu says. saved_only plays with the saved files without asking.
    start:proc(s:^Session,online,ping:int,saved_only:bool) -> (taken:bool,error:string),
    confirmed:proc(s:^Session), // the question about unsaved assets its start asked was answered: it goes on
    verb:proc(s:^Session) -> string, // what that question goes on to do: "Play", "Join"
    menu:proc(s:^Session),      // its rows in the menu of the Play button
    active:proc(s:^Session) -> bool, // its game runs: Play and Simulate wait, and Stop ends it
    stop:proc(s:^Session),
    label:proc(s:^Session) -> string, // what the bar says of its game; empty: nothing
    poll:proc(s:^Session),            // between frames
    play_begin:proc(s:^Session,r:^Run), // the run of the user begins, before its first tick
    play_end:proc(s:^Session),          // the run of the user ended
    pump:proc(w:core.World_Ref,app:^host.App), // a run whose game is paused keeps what it holds open
    // A turn plays with online players besides the run of owner, which has
    // players local ones: the runs it adds. Returns why it could not.
    turn:proc(s:^Session,owner,players,online,ping:int) -> string,
    offer:proc(s:^Session,out:[]u8) -> int, // what a shared session tells its guests of the game it serves; 0: none
    game:proc(s:^Session) -> u32,           // the game it serves now, whose scene guests copy; 0: none
    host_menu:proc(s:^Session,offered:bool), // a guest: its rows in the menu of the host, which offers a game or not
    joined:proc(s:^Session) -> bool,         // a guest: it plays the game the host serves
    scene_arrived:proc(s:^Session,game:u32), // a guest: the copy of the scene of the game of the host arrived
}

// What a plugin is told of the runs the API drives tick by tick (play.step, a
// scenario, a filmstrip, play_tick): what each tick receives and what it left.
// A nil procedure is a point it does not take.
Run_Provider :: struct {
    input:proc(s:^Session,r:^Run,step:^Api_Step_Input,at:int), // before a tick; at: that tick of its segment
    ticked:proc(s:^Session,r:^Run),
    call:proc(s:^Session,r:^Run,method,params:string),         // a method changed the run between two ticks; params is its JSON
    focus:proc(s:^Session,r:^Run,slot:int),                    // the keys and the mouse go to that local seat from the next tick
    ended:proc(s:^Session,r:^Run),                             // the run goes away, or stays only as the past of the last Play
}

// An area of the preferences of the editor a plugin keeps: the editor reads
// it from the file and writes it there as its own.
Preferences_Provider :: struct {
    name:string,
    info:^runtime.Type_Info,
    value:proc(s:^Session) -> rawptr,
    default:proc(dst:rawptr),
}

// The kinds of asset of a plugin that the content browser lists: the name of
// each in the list and on its filter, its icon and the color of its cards.
Asset_Kind :: struct {
    kind:asset.Fourcc,
    label:string,
    color:ui.Color,
    icon:ui.Icon,
    extension:string, // of its files, with the dot: asset.list names the kind by it
    field:string,     // a word: an Asset_Id field whose name has it takes the kind; empty: none
    scene_data:bool,  // what a scene makes of itself: the browser lists it with the Plugins filter or a search
}
ASSET_KINDS_OF_PROVIDER :: 8
Asset_Kind_Provider :: struct {
    kinds:[ASSET_KINDS_OF_PROVIDER]Asset_Kind,
    count:int,
    // A click on the card of one of them in the content browser, out of Play
    // and with the scene in front: what it does to the selection.
    clicked:proc(s:^Session,w:core.World_Ref,file:^asset.Registry_File),
}

// What a plugin adds to the menu of a card of the content browser: its items
// (ui.menu_item) for the asset of file.
Asset_Menu_Provider :: struct {
    menu:proc(s:^Session,file:^asset.Registry_File),
}

// What a plugin knows of the way from a body to a goal in a game: the drive of
// play.step takes its next point when one is given.
Route_State :: enum u8 {
    None,    // no way known: the drive goes straight
    Waiting, // not known yet: the meshes are still being made
    Found,
}

Route :: struct {
    state:Route_State,
    next:[3]f32, // the next point of the way
    left:f32,    // m of the way that are left
}

Route_Provider :: struct {
    next:proc(s:^Session,w:core.World_Ref,body:core.Entity,goal:[3]f32) -> Route,
}

// What the plugin that moves a body in a game says of it (physics: its
// characters): the drive of play.step and the playtest plugin read it with
// play_stance and play_body_measure, never by the name of a component. known
// is false for a body that is not one it moves.
Body_Provider :: struct {
    standing:proc(w:core.World_Ref,body:core.Entity) -> (standing,known:bool),
    measure:proc(w:core.World_Ref,body:core.Entity) -> (measure:Body_Measure,known:bool),
}

// The size of a body and how it moves, for what steers it; 0: it does not say.
Body_Measure :: struct {
    height:f32,      // m from its feet to the top of its head
    step_height:f32, // m it walks up without a jump
    speed:f32,       // m/s it walks at the most
    jump_height:f32, // m a jump of it rises
}

// The body what steers is told for when none says its own: the character physics makes by default.
BODY_PERSON :: Body_Measure{height=1.8,step_height=0.3,speed=5,jump_height=1.2}

Stance :: enum u8 {
    Unknown, // no plugin moves the body: nothing says whether it stands
    Standing,
    Airborne,
}

PROVIDER_CAPACITY :: 32 // of a kind the editor holds at once

@(private)
Providers :: struct {
    library:int, // library_generation+1 of what it holds
    simulation:Simulation_Provider,
    play:Play_Provider,
    route:Route_Provider,
    simulates,plays,routes:bool,
    bodies:[PROVIDER_CAPACITY]Body_Provider,
    body_count:int,
    inspectors:[PROVIDER_CAPACITY]Inspector_Provider,
    inspector_count:int,
    components:[PROVIDER_CAPACITY]Component_Provider,
    component_count:int,
    kinds:[PROVIDER_CAPACITY*ASSET_KINDS_OF_PROVIDER]Asset_Kind,
    kind_clicks:[PROVIDER_CAPACITY*ASSET_KINDS_OF_PROVIDER]proc(s:^Session,w:core.World_Ref,file:^asset.Registry_File),
    kind_count:int,
    menus:[PROVIDER_CAPACITY]Asset_Menu_Provider,
    menu_count:int,
    runs:[PROVIDER_CAPACITY]Run_Provider,
    run_count:int,
}

// The providers of the plugins of the library in use, looked for again when it changes.
@(private)
providers :: proc(s:^Session) -> ^Providers {
    p:=&s.providers
    if p.library==s.library_generation+1 {return p}
    p^={library=s.library_generation+1}
    p.simulation,p.simulates=provided(s,Simulation_Provider)
    p.play,p.plays=provided(s,Play_Provider)
    p.route,p.routes=provided(s,Route_Provider)
    p.body_count=provided_all(s,p.bodies[:])
    p.inspector_count=provided_all(s,p.inspectors[:])
    p.component_count=provided_all(s,p.components[:])
    p.menu_count=provided_all(s,p.menus[:])
    p.run_count=provided_all(s,p.runs[:])
    kinds:[PROVIDER_CAPACITY]Asset_Kind_Provider
    for &provider in kinds[:provided_all(s,kinds[:])] {
        for kind in provider.kinds[:clamp(provider.count,0,len(provider.kinds))] {
            p.kinds[p.kind_count],p.kind_clicks[p.kind_count]=kind,provider.clicked
            p.kind_count+=1
        }
    }
    return p
}

@(private)
run_tell_input :: proc(s:^Session,r:^Run,step:^Api_Step_Input,at:int) {
    p:=providers(s)
    for &each in p.runs[:p.run_count] {if each.input!=nil {each.input(s,r,step,at)}}
}

@(private)
run_tell_ticked :: proc(s:^Session,r:^Run) {
    p:=providers(s)
    for &each in p.runs[:p.run_count] {if each.ticked!=nil {each.ticked(s,r)}}
}

@(private)
run_tell_call :: proc(s:^Session,r:^Run,method,params:string) {
    p:=providers(s)
    for &each in p.runs[:p.run_count] {if each.call!=nil {each.call(s,r,method,params)}}
}

@(private)
run_tell_focus :: proc(s:^Session,r:^Run,slot:int) {
    p:=providers(s)
    for &each in p.runs[:p.run_count] {if each.focus!=nil {each.focus(s,r,slot)}}
}

@(private)
run_tell_ended :: proc(s:^Session,r:^Run) {
    p:=providers(s)
    for &each in p.runs[:p.run_count] {if each.ended!=nil {each.ended(s,r)}}
}

// The kinds of asset the plugins declare (Asset_Kind_Provider).
asset_plugin_kinds :: proc(s:^Session) -> []Asset_Kind {
    p:=providers(s)
    return p.kinds[:p.kind_count]
}

// What the kinds a provider registers and those the manifest of its plugin
// declares (asset_kinds, what is known of them without loading the plugin)
// differ in; "" when they are the same extensions.
asset_kinds_differ :: proc(provider:Asset_Kind_Provider,m:^project.Plugin_Manifest,allocator:=context.temp_allocator) -> string {
    provider:=provider
    registered:=provider.kinds[:clamp(provider.count,0,len(provider.kinds))]
    declared:=0
    for &kind in m.asset_kinds {
        extension:=base.text_get(kind.extension[:])
        if extension=="" {continue}
        declared+=1
        found:=false
        for each in registered {found||=each.extension==extension}
        if !found {return fmt.aprintf("%s declares the asset kind %s, which the plugin does not register",project.PLUGIN_FILE,extension,allocator=allocator)}
    }
    if declared!=len(registered) {return fmt.aprintf("%s declares %d asset kinds and the plugin registers %d",project.PLUGIN_FILE,declared,len(registered),allocator=allocator)}
    return ""
}

// What a plugin declares of a kind of asset; nil for a kind of the engine or of none.
asset_plugin_kind :: proc(s:^Session,kind:asset.Fourcc) -> ^Asset_Kind {
    for &each in asset_plugin_kinds(s) {if each.kind==kind {return &each}}
    return nil
}

// The kind of a plugin whose files have an extension (".particle").
asset_plugin_kind_of_extension :: proc(s:^Session,extension:string) -> ^Asset_Kind {
    for &each in asset_plugin_kinds(s) {if each.extension==extension {return &each}}
    return nil
}

// Does what a click on the card of an asset of a plugin does; false when no
// plugin takes the clicks of its kind.
asset_kind_click :: proc(s:^Session,w:core.World_Ref,file:^asset.Registry_File) -> bool {
    p:=providers(s)
    for &each,i in p.kinds[:p.kind_count] {
        if each.kind!=file.kind || p.kind_clicks[i]==nil {continue}
        p.kind_clicks[i](s,w,file)
        return true
    }
    return false
}

// The kind of a plugin a field takes by a word of its name.
@(private)
asset_kind_of_word :: proc(s:^Session,lower:string) -> (kind:asset.Fourcc,found:bool) {
    for &each in asset_plugin_kinds(s) {
        if each.field!="" && strings.contains(lower,each.field) {return each.kind,true}
    }
    return
}

// The items the plugins add to the menu of a card of the content browser.
@(private)
asset_plugin_menus :: proc(s:^Session,file:^asset.Registry_File) {
    p:=providers(s)
    for provider in p.menus[:p.menu_count] {if provider.menu!=nil {provider.menu(s,file)}}
}

// Every provider of the type of out the plugins give, as many as fit; in
// plugins, when given, the plugin that gives each.
provided_all :: proc(s:^Session,out:[]$T,plugins:[]string=nil) -> (count:int) {
    return provided_in(s.info,out,plugins)
}

// provided_all for the library a World_Info is of, with no session.
provided_in :: proc(info:^core.World_Info,out:[]$T,plugins:[]string=nil) -> (count:int) {
    if info==nil {return}
    for &storage in info.storages {
        if storage.place!=.Editor || storage.default==nil || storage.info.size!=size_of(T) {continue}
        fields,ok:=runtime.type_info_base(storage.info).variant.(runtime.Type_Info_Struct)
        if !ok || fields.field_count!=1 || fields.types[0].id!=T {continue}
        if count>=len(out) {
            log.errorf("the plugins declare more than %d providers of %v: raise PROVIDER_CAPACITY in editor/providers.odin",len(out),typeid_of(T))
            break
        }
        storage.default(&out[count])
        if count<len(plugins) {plugins[count]=storage.plugin}
        count+=1
    }
    return
}

// The provider of type T a plugin of the library in use gives.
provided :: proc(s:^Session,$T:typeid) -> (provider:T,found:bool) {
    one:[1]T
    found=provided_all(s,one[:])>0
    return one[0],found
}

// The way from a body to a goal, as the plugin that knows it says; None without one.
route_of_body :: proc(s:^Session,w:core.World_Ref,body:core.Entity,goal:[3]f32) -> Route {
    p:=providers(s)
    return p.routes && p.route.next!=nil?p.route.next(s,w,body,goal):{}
}

// Whether a body of a game stands, as the plugin that moves it says.
play_stance :: proc(s:^Session,w:core.World_Ref,body:core.Entity) -> Stance {
    p:=providers(s)
    for &each in p.bodies[:p.body_count] {
        if each.standing==nil {continue}
        if standing,known:=each.standing(w,body);known {return standing?.Standing:.Airborne}
    }
    return .Unknown
}

// The measures of a body of a game, as the plugin that moves it says; those
// of BODY_PERSON for a body none answers for and for what it leaves at 0.
play_body_measure :: proc(s:^Session,w:core.World_Ref,body:core.Entity) -> Body_Measure {
    said:Body_Measure
    p:=providers(s)
    for &each in p.bodies[:p.body_count] {
        if each.measure==nil {continue}
        if measure,known:=each.measure(w,body);known {said=measure;break}
    }
    person:=BODY_PERSON
    return {
        height=said.height>0?said.height:person.height,
        step_height=said.step_height>0?said.step_height:person.step_height,
        speed=said.speed>0?said.speed:person.speed,
        jump_height=said.jump_height>0?said.jump_height:person.jump_height,
    }
}

// The body a selected entity moves while Simular runs; none without one, or without physics.
simulation_owner :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> core.Entity {
    p:=providers(s)
    return p.simulates?p.simulation.owner(w,e):core.NONE
}

// What was written becomes the simulation's own, without simulating time.
simulation_settle :: proc(s:^Session,w:core.World_Ref) {
    if p:=providers(s);p.simulates {p.simulation.settle(w,s.app)}
}

// The game of the plugin that plays one runs (Play_Provider.active).
play_plugin_active :: proc(s:^Session) -> bool {
    p:=providers(s)
    return p.plays && p.play.active!=nil && p.play.active(s)
}

// Ends the game of the plugin, when one runs.
play_plugin_stop :: proc(s:^Session) {
    if p:=providers(s);p.plays && p.play.stop!=nil {p.play.stop(s)}
}

// Between frames: the game of the plugin follows its build, its players and its sessions.
@(private)
play_plugin_poll :: proc(s:^Session) {
    if p:=providers(s);p.plays && p.play.poll!=nil {p.play.poll(s)}
}

// Play from Edit: the game of the plugin when it takes it. taken is false for a Play alone.
@(private)
play_plugin_start :: proc(s:^Session,online,ping:int,saved_only:bool) -> (taken:bool,error:string) {
    p:=providers(s)
    if !p.plays || p.play.start==nil {return}
    taken,error=p.play.start(s,online,ping,saved_only)
    // A new Play of the user, on the network: the last one kept goes.
    if taken {replay_free(s)}
    return
}
