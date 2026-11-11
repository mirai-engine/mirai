package editor

import "base:runtime"
import "core:fmt"
import "core:strings"
import "mirai:asset"
import mixer "mirai:audio"
import "mirai:core"
import "mirai:editor/api"
import eaudio "mirai:engine/audio"
import egui "mirai:engine/gui"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// What an agent observes of the game of the caller besides its world: the UI
// of the game as its last frame built it (play.ui) and the voices its sources
// play (play.audio). Both read the run of the caller and change nothing.

Api_Play_Ui_Params :: struct {
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
    all:bool `mirai:"optional,label=Also the interfaces the last frame did not build and the nodes it did not show; without it only what shows and can be clicked"`,
}

Api_Play_Ui :: struct {
    contexts:[]Api_Play_Ui_Context `mirai:"label=The window and the part of each local player that showed interfaces"`,
    interfaces:[]Api_Play_Ui_Interface `mirai:"label=Each context from the bottom up: screens by order then World_Widgets"`,
}
Api_Play_Ui_Context :: struct {
    player:int `mirai:"label=0: the window; n: the part of local player n"`,
    rect:[4]f32 `mirai:"label=Its part of the window in points: x y width height"`,
    scale:f32 `mirai:"label=Window points per layout unit"`,
    pointer_consumed:bool `mirai:"label=The pointer was over an interface or held by a widget"`,
    keyboard_consumed:bool `mirai:"label=A field or the navigation had the keyboard"`,
    hovered:Api_Play_Ui_Target `mirai:"optional,label=The deepest node under the pointer in the top interface"`,
    focused:Api_Play_Ui_Target `mirai:"optional,label=The node with the focus of navigation or a field being typed in"`,
}
Api_Play_Ui_Target :: struct {
    entity:core.Entity,
    row:int,
    name:string,
}
Api_Play_Ui_Kind :: enum u8 {UI_Screen,World_Widget}
Api_Play_Ui_Interface :: struct {
    entity:core.Entity `mirai:"label=The one with the UI_Screen or the World_Widget"`,
    id:base.Entity_Id `mirai:"optional,label=Its id in the scene; absent for one spawned while playing"`,
    kind:Api_Play_Ui_Kind,
    asset:base.Asset_Id,
    path:string `mirai:"label=Of the .ui under the assets folder"`,
    player:int `mirai:"label=The context it is built in"`,
    shown:bool `mirai:"label=The last frame built it and something of it shows"`,
    top:bool `mirai:"label=It takes the input of its player: the top screen that is not passive or the World_Widget the player points at"`,
    modal:bool `mirai:"label=A Modal on top: the seats it covers get no actions"`,
    nodes:[]Api_Play_Ui_Node `mirai:"optional,label=In pre-order; absent when the last frame did not build it"`,
}
Api_Play_Ui_Node :: struct {
    row:int `mirai:"label=Of the node in the tree with its widgets expanded"`,
    parent:int `mirai:"label=The row of its container; -1: a root"`,
    name:string `mirai:"label=As the .ui names it; a node of a widget after its instance as in slot/icon; empty without one or when the file changed since it loaded"`,
    kind:ui.Node_Kind,
    shown:bool `mirai:"label=A copy of it showed in the last frame"`,
    hovered:bool `mirai:"label=The pointer was over a copy of it"`,
    focused:bool,
    disabled:bool `mirai:"label=By itself or by a container"`,
    rect:[4]f32 `mirai:"optional,label=Of a shown node of a screen: where the last frame laid it out in window points (x y width height) for the first element of the lists around it; play.step takes those points"`,
    text:string `mirai:"optional,label=The text it showed; absent when it shows none"`,
}

Api_Play_Audio_Params :: struct {
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Audio :: struct {
    voices:[]Api_Play_Audio_Voice `mirai:"label=One per Audio_Source that plays"`,
    stats:Api_Play_Audio_Stats `mirai:"label=Of the voices of this game"`,
    mixer:Api_Play_Audio_Mixer `mirai:"optional,label=The mixer of the editor that every game and the editor share; absent without one and then nothing plays"`,
}
Api_Play_Audio_Stats :: struct {
    started:u64 `mirai:"label=Voices its sources started"`,
    ended:u64 `mirai:"label=Of those the ones that ended without loop"`,
}
Api_Play_Audio_Mixer :: struct {
    voices_active,sounds:int,
    voices_played,voices_stolen,voices_rejected,commands_dropped,underruns,streams_busy,feeds_busy:u64,
}
Api_Play_Audio_Voice :: struct {
    entity:core.Entity `mirai:"label=The one with the Audio_Source"`,
    id:base.Entity_Id `mirai:"optional,label=Its id in the scene; absent for one spawned while playing"`,
    name:string,
    sound:base.Asset_Id `mirai:"label=Of its Audio_Source: a .sound or a .sound_set"`,
    path:string `mirai:"label=Of the sound under the assets folder"`,
    bus:string,
    volume:f32 `mirai:"label=Linear gain the voice was given: that of its source by what its set drew; before its bus, its distance and what hides it"`,
    pitch:f32 `mirai:"label=Rate of playback the voice was given"`,
    pan:f32 `mirai:"optional,label=Of a voice that is not spatial"`,
    loop:bool,
    playing:bool `mirai:"label=The mixer has not ended it as of its last update"`,
    spatial:bool,
    position:[3]f32 `mirai:"optional,label=Of a spatial voice: where it was placed last in meters"`,
    occlusion:f32 `mirai:"optional,label=Of a spatial voice: how hidden it was told it is, 0 in sight to 1 hidden"`,
    reverb:f32 `mirai:"label=Share of it sent to the reverb"`,
}

@(private)
play_observe_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="play.ui",summary="The live tree of the UI of the game of the caller as its last frame built it: each interface with its nodes and where they are in the window, and what has the hover and the focus.",params=type_info_of(Api_Play_Ui_Params),result=type_info_of(Api_Play_Ui),flags={.Read_Only},run=api_play_ui})
    api_register(s,st,{name="play.audio",summary="The voices the sources of the game of the caller play: sound, bus, gain, pitch and place of each, with the counters of its voices and of the mixer.",params=type_info_of(Api_Play_Audio_Params),result=type_info_of(Api_Play_Audio),flags={.Read_Only},run=api_play_audio})
}

@(private)
api_play_ui :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Ui_Params)
    r,_:=api_play_run(s,call,p.player)
    if r==nil {api_no_game(call);return}
    // The names come from the files of the interfaces, which can be larger than the scratch of a request.
    view:=Play_Ui_View{
        session=s,gui=host.app_world_storage(s.app,r.world,egui.Gui),world=core.world_ref(r.world,s.info),
        all=p.all,allocator=context.temp_allocator,
    }
    api.call_result(call,Api_Play_Ui)^=play_ui(&view)
}

@(private)
api_play_audio :: proc(s:^Session,call:^api.Call) {
    r,_:=api_play_run(s,call,api.call_params(call,Api_Play_Audio_Params).player)
    if r==nil {api_no_game(call);return}
    api.call_result(call,Api_Play_Audio)^=play_audio(s,host.app_world_storage(s.app,r.world,eaudio.Voices),core.world_ref(r.world,s.info),s.app.mixer,call.allocator)
}

// The id of an entity of the game in the scene, when it has one.
@(private)
play_entity_id :: proc(w:core.World_Ref,e:core.Entity) -> base.Entity_Id {
    if w.data==nil || w.info==nil {return 0}
    return api_entity_id(w,e)
}

// ---------------------------------------------------------------- ui

@(private)
Play_Ui_View :: struct {
    session:^Session,
    gui:^egui.Gui,
    world:core.World_Ref,
    all:bool,
    allocator:runtime.Allocator, // what the names read from the files live in
    names:[dynamic]Play_Ui_Names,
}

@(private)
Play_Ui_Names :: struct {
    asset:base.Asset_Id,
    tree:^ui.Widget_Tree,
    names:[]string,
}

// A node of an interface the last frame built.
@(private)
Play_Ui_Target :: struct {
    entity:core.Entity,
    row:int,
    asset:base.Asset_Id,
    tree:^ui.Widget_Tree,
}

// Whether something can be pressed: what the pointer of a button activates.
@(private)
play_ui_pressable :: proc "contextless" (kind:ui.Node_Kind) -> bool {
    #partial switch kind {
    case .Button,.Checkbox,.Radio,.Dropdown,.Selector: return true
    }
    return false
}

Play_Ui_Button :: struct {
    row:int,
    name,text:string,
    rect:[4]f32, // in window points, as play.step takes them
    laid,shown,disabled:bool,
}

Play_Ui_Top :: struct {
    screen:string,
    entity:core.Entity,
    modal:bool,
    focused:string,
    buttons:[]Play_Ui_Button,
}

// The screen that takes the input of a player and what can be pressed on it;
// with hidden also what is not showing, whose nodes have no rect.
@(private)
play_ui_top :: proc(v:^Play_Ui_View,player:int,hidden:bool) -> (top:Play_Ui_Top,found:bool) {
    g:=v.gui
    if g==nil {return}
    s:=v.session
    for &entry in g.plan {
        if !entry.top || entry.world || entry.player!=player {continue}
        at:=play_ui_instance_of(g,entry.entity,entry.world,entry.player)
        if at<0 {continue}
        instance:=&g.instances[at]
        tree:=play_ui_tree(instance,entry.content)
        if tree==nil || !instance.shown {continue}
        top.screen,top.entity,top.modal=asset_path(s,instance.asset),instance.entity,instance.modal
        names:=play_ui_names(v,instance.asset,tree)
        ctx:=g.surfaces[entry.player].ctx if entry.player>=0 && entry.player<len(g.surfaces) else nil
        shown:=make([]bool,tree.node_count,v.allocator)
        disabled:=make([]bool,tree.node_count,v.allocator)
        buttons:=make([dynamic]Play_Ui_Button,v.allocator)
        for row in 0..<tree.node_count {
            state,_:=ui.tree_node_state(tree,&instance.instance,row)
            parent:=int(tree.nodes[row].parent)
            shown[row]=state.shown && (parent<0 || shown[parent])
            disabled[row]=state.disabled || parent>=0 && disabled[parent]
            name:=row<len(names)?names[row]:""
            if shown[row] && state.focused {top.focused=name}
            if !play_ui_pressable(tree.nodes[row].kind) || !shown[row] && !hidden {continue}
            button:=Play_Ui_Button{row=row,name=name,text=state.text,shown=shown[row],disabled=disabled[row]}
            if shown[row] && ctx!=nil {
                if r,laid:=egui.screen_node_rect(ctx,tree,instance.entity,row);laid {button.rect,button.laid={r.x,r.y,r.w,r.h},true}
            }
            append(&buttons,button)
        }
        top.buttons=buttons[:]
        return top,true
    }
    return
}

// The context of the screen of the focused local player: 0 is the window, n
// the part of the player of slot n-1 when they share the screen.
@(private)
play_ui_focused_context :: proc(w:core.World_Ref,g:^egui.Gui) -> int {
    state:=core.world_storage_of(w,input.Seats)
    if state==nil || g==nil {return 0}
    split:=state.focus+1
    if split<len(g.surfaces) && g.surfaces[split].ctx!=nil && g.surfaces[split].shown {return split}
    return 0
}

// The screen on top of the focused player of a run and what can be pressed on
// it, as its last frame laid it out, in allocator; with hidden also what is
// not showing.
play_ui_screen :: proc(s:^Session,r:^Run,hidden:bool,allocator:runtime.Allocator) -> (top:Play_Ui_Top,found:bool) {
    g:=host.app_world_storage(s.app,r.world,egui.Gui)
    if g==nil {return}
    w:=run_ref(s,r)
    view:=Play_Ui_View{session=s,gui=g,world=w,allocator=allocator}
    return play_ui_top(&view,play_ui_focused_context(w,g),hidden)
}

// The interfaces of a world as its last frame built them.
@(private)
play_ui :: proc(v:^Play_Ui_View) -> (r:Api_Play_Ui) {
    g:=v.gui
    if g==nil {return}
    contexts:=make([dynamic]Api_Play_Ui_Context,v.allocator)
    for &surface,player in g.surfaces {
        ctx:=surface.ctx
        if ctx==nil || !surface.shown && !v.all {continue}
        row:=Api_Play_Ui_Context{player=player,rect=surface.rect,scale=ctx.scale,pointer_consumed=surface.pointer,keyboard_consumed=surface.keyboard}
        hovered,focused:=play_ui_targets(g,player)
        if hovered.tree!=nil {row.hovered=play_ui_target(v,hovered)}
        if focused.tree!=nil {row.focused=play_ui_target(v,focused)}
        append(&contexts,row)
    }
    interfaces:=make([dynamic]Api_Play_Ui_Interface,v.allocator)
    listed:=make([]bool,len(g.instances),v.allocator)
    for &entry in g.plan {
        at:=play_ui_instance_of(g,entry.entity,entry.world,entry.player)
        if at<0 || listed[at] {continue}
        listed[at]=true
        instance:=&g.instances[at]
        if !instance.shown && !v.all {continue}
        append(&interfaces,play_ui_interface(v,instance,play_ui_tree(instance,entry.content),entry.top))
    }
    if v.all {
        for &instance,at in g.instances {
            if !listed[at] {append(&interfaces,play_ui_interface(v,&instance,nil,false))}
        }
    }
    return {contexts[:],interfaces[:]}
}

// The instance of the UI_Screen of an entity, or of its World_Widget in a context; -1: none.
@(private)
play_ui_instance_of :: proc(g:^egui.Gui,e:core.Entity,world:bool,player:int) -> int {
    slot:=egui.instance_slot(world,player)
    for &instance,at in g.instances {
        if instance.entity==e && instance.slot==slot {return at}
    }
    return -1
}

// The tree an interface was built from, while the content planned for it is still that one.
@(private)
play_ui_tree :: proc(instance:^egui.Instance,content:^host.Content_Ui) -> ^ui.Widget_Tree {
    if content==nil || content.id!=instance.asset || content.generation!=instance.generation || instance.failed {return nil}
    return &content.tree
}

// The deepest shown node under the pointer in the last interface of a
// context that has one, and the one with the focus.
@(private)
play_ui_targets :: proc(g:^egui.Gui,player:int) -> (hovered,focused:Play_Ui_Target) {
    for &entry in g.plan {
        if entry.player!=player {continue}
        at:=play_ui_instance_of(g,entry.entity,entry.world,entry.player)
        if at<0 {continue}
        instance:=&g.instances[at]
        tree:=play_ui_tree(instance,entry.content)
        if tree==nil || !instance.shown {continue}
        shown:=make([]bool,tree.node_count,context.temp_allocator)
        for row in 0..<tree.node_count {
            state,_:=ui.tree_node_state(tree,&instance.instance,row)
            parent:=int(tree.nodes[row].parent)
            shown[row]=state.shown && (parent<0 || shown[parent])
            if !shown[row] {continue}
            target:=Play_Ui_Target{entry.entity,row,instance.asset,tree}
            if state.hovered {hovered=target}
            if state.focused {focused=target}
        }
    }
    return
}

@(private)
play_ui_target :: proc(v:^Play_Ui_View,target:Play_Ui_Target) -> Api_Play_Ui_Target {
    names:=play_ui_names(v,target.asset,target.tree)
    return {target.entity,target.row,names[target.row] if target.row<len(names) else ""}
}

@(private)
play_ui_interface :: proc(v:^Play_Ui_View,instance:^egui.Instance,tree:^ui.Widget_Tree,top:bool) -> (r:Api_Play_Ui_Interface) {
    r={entity=instance.entity,id=play_entity_id(v.world,instance.entity),kind=.World_Widget if instance.world else .UI_Screen,asset=instance.asset,path=asset_path(v.session,instance.asset),player=instance.player,shown=tree!=nil && instance.shown,top=top,modal=instance.modal}
    if tree==nil {return}
    names:=play_ui_names(v,instance.asset,tree)
    ctx:=v.gui.surfaces[instance.player].ctx if instance.player>=0 && instance.player<len(v.gui.surfaces) else nil
    shown:=make([]bool,tree.node_count,v.allocator)
    disabled:=make([]bool,tree.node_count,v.allocator)
    nodes:=make([dynamic]Api_Play_Ui_Node,v.allocator)
    for row in 0..<tree.node_count {
        state,_:=ui.tree_node_state(tree,&instance.instance,row)
        node:=&tree.nodes[row]
        parent:=int(node.parent)
        // A node shows while its containers do, and is disabled with them.
        shown[row]=state.shown && instance.shown && (parent<0 || shown[parent])
        disabled[row]=state.disabled || parent>=0 && disabled[parent]
        if !shown[row] && !v.all {continue}
        value:=Api_Play_Ui_Node{row=row,parent=parent,name=names[row] if row<len(names) else "",kind=node.kind,shown=shown[row],hovered=shown[row] && state.hovered,focused=shown[row] && state.focused,disabled=disabled[row],text=strings.clone(state.text,v.allocator)}
        // A World_Widget is laid out on its panel, not in the window.
        if shown[row] && !instance.world && ctx!=nil {
            if laid_out,laid:=egui.screen_node_rect(ctx,tree,instance.entity,row);laid {value.rect={laid_out.x,laid_out.y,laid_out.w,laid_out.h}}
        }
        append(&nodes,value)
    }
    r.nodes=nodes[:]
    return
}

// The names of the nodes of the tree of a .ui by row, read once per call from
// its file; nil when the file is not what the tree was loaded from.
@(private)
play_ui_names :: proc(v:^Play_Ui_View,id:base.Asset_Id,tree:^ui.Widget_Tree) -> []string {
    for known in v.names {
        if known.asset==id && known.tree==tree {return known.names}
    }
    names:=play_ui_names_read(v.session,id,tree,v.allocator)
    if v.names.allocator.procedure==nil {v.names.allocator=v.allocator}
    append(&v.names,Play_Ui_Names{id,tree,names})
    return names
}

@(private)
play_ui_names_read :: proc(s:^Session,id:base.Asset_Id,tree:^ui.Widget_Tree,allocator:runtime.Allocator) -> []string {
    a:=s.app.assets
    if a==nil {return nil}
    file:asset.Asset
    if host.assets_file(a,id,asset.KIND_UI,&file)!=.None {return nil}
    defer asset.asset_close(&file)
    records,error:=host.ui_tree_view(&file,&a.types)
    if error!=.None {return nil}
    imports,imported:=host.ui_tree_imports(a,records,nil,allocator)
    if !imported {return nil}
    return play_ui_names_of(records,imports,tree,allocator)
}

// The names of the nodes of a tree by row as the records it was loaded from
// give them; nil when the records are not those.
@(private)
play_ui_names_of :: proc(records:ui.Tree_Data,imports:[]ui.Tree_Data,tree:^ui.Widget_Tree,allocator:runtime.Allocator) -> []string {
    data,linked:=ui.tree_link(records,imports,allocator)
    if !linked {return nil}
    nodes,expanded:=ui.tree_expand(data,allocator)
    if !expanded || len(nodes)!=tree.node_count {return nil}
    names:=make([]string,len(nodes),allocator)
    for &node,row in nodes {
        name:=serial.text_field(node.name[:])
        if (base.name_hash(name) if name!="" else 0)!=tree.nodes[row].name {return nil}
        names[row]=name
    }
    return names
}

// ---------------------------------------------------------------- audio

@(private)
play_audio :: proc(s:^Session,voices:^eaudio.Voices,w:core.World_Ref,m:^mixer.Mixer,allocator:=context.temp_allocator) -> (r:Api_Play_Audio) {
    // What a voice was given is its source by what its set drew.
    sources:^core.Table(eaudio.Audio_Source)
    states:^core.Table(eaudio.Audio_Source_State)
    if w.data!=nil {sources,states=core.world_table_of(w,eaudio.Audio_Source),core.world_table_of(w,eaudio.Audio_Source_State)}
    if voices!=nil {
        r.stats={voices.stats.started,voices.stats.ended}
        r.voices=make([]Api_Play_Audio_Voice,len(voices.entries.values),allocator)
        for &row,at in r.voices {
            entry:=voices.entries.values[at]
            e:=voices.entries.entities[at]
            source:eaudio.Audio_Source
            state:eaudio.Audio_Source_State
            if sources!=nil {source,_=core.get(sources,e)}
            if states!=nil {state,_=core.get(states,e)}
            kind:=entry.kind
            bus:string
            if s.info!=nil {bus,_=core.name_of(s.info,eaudio.Audio_Bus,i64(kind.bus))}
            row={entity=e,id=play_entity_id(w,e),name=entity_name(w,e) if w.data!=nil && w.info!=nil else "",sound=kind.sound,path=asset_path(s,kind.sound),bus=bus if bus!="" else fmt.tprintf("%d",int(kind.bus)),
                volume=source.volume*entry.pick[0],pitch=(source.pitch>0?source.pitch:1)*entry.pick[1],loop=source.loop,playing=m!=nil && mixer.voice_valid(m,entry.voice),spatial=kind.spatial,reverb=source.reverb}
            if kind.spatial {row.position,row.occlusion=entry.position,state.occlusion} else {row.pan=source.pan}
        }
    }
    if m!=nil {
        c:=mixer.mixer_stats(m)
        r.mixer={c.voices_active,c.sounds,c.voices_played,c.voices_stolen,c.voices_rejected,c.commands_dropped,c.underruns,c.streams_busy,c.feeds_busy}
    }
    return
}
