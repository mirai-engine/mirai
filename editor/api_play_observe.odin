package editor

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "mirai:asset"
import mixer "mirai:audio"
import "mirai:core"
import "mirai:editor/api"
import eaudio "mirai:engine/audio"
import egui "mirai:engine/gui"
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
    playing:bool `mirai:"optional,label=false when no game of the caller plays: the rest is empty; absent while one plays"`,
    contexts:[1]Api_Play_Ui_Context `mirai:"list,label=The window and the part of each local player that showed interfaces"`,
    interfaces:[1]Api_Play_Ui_Interface `mirai:"list,label=Each context from the bottom up: screens by order then World_Widgets"`,
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
    name:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text"`,
}
Api_Play_Ui_Kind :: enum u8 {UI_Screen,World_Widget}
Api_Play_Ui_Interface :: struct {
    entity:core.Entity `mirai:"label=The one with the UI_Screen or the World_Widget"`,
    id:base.Entity_Id `mirai:"optional,label=Its id in the scene; absent for one spawned while playing"`,
    kind:Api_Play_Ui_Kind,
    asset:base.Asset_Id,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Of the .ui under the assets folder"`,
    player:int `mirai:"label=The context it is built in"`,
    shown:bool `mirai:"label=The last frame built it and something of it shows"`,
    top:bool `mirai:"label=It takes the input of its player: the top screen that is not passive or the World_Widget the player points at"`,
    modal:bool `mirai:"label=A Modal on top: the seats it covers get no actions"`,
    nodes:[1]Api_Play_Ui_Node `mirai:"list,optional,label=In pre-order; absent when the last frame did not build it"`,
}
Api_Play_Ui_Node :: struct {
    row:int `mirai:"label=Of the node in the tree with its widgets expanded"`,
    parent:int `mirai:"label=The row of its container; -1: a root"`,
    name:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,label=As the .ui names it; a node of a widget after its instance as in slot/icon; empty without one or when the file changed since it loaded"`,
    kind:ui.Node_Kind,
    shown:bool `mirai:"label=A copy of it showed in the last frame"`,
    hovered:bool `mirai:"label=The pointer was over a copy of it"`,
    focused:bool,
    disabled:bool `mirai:"label=By itself or by a container"`,
    rect:[4]f32 `mirai:"optional,label=Of a shown node of a screen: where the last frame laid it out in window points (x y width height) for the first element of the lists around it; play.step takes those points"`,
    text:[PLAY_UI_TEXT_BYTES]u8 `mirai:"text,optional,label=The text it showed; absent when it shows none"`,
}

@(private) PLAY_UI_TEXT_BYTES :: 16*1024

Api_Play_Audio_Params :: struct {
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Audio :: struct {
    playing:bool `mirai:"optional,label=false when no game of the caller plays: the rest is empty; absent while one plays"`,
    voices:[1]Api_Play_Audio_Voice `mirai:"list,label=One per Audio_Source that plays"`,
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
    name:[64]u8 `mirai:"text"`,
    sound:base.Asset_Id `mirai:"label=Of its Audio_Source: a .sound or a .sound_set"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Of the sound under the assets folder"`,
    bus:[NAME_CAPACITY]u8 `mirai:"text"`,
    volume:f32 `mirai:"label=Linear gain the voice was given: that of its source by what its set drew and by how hidden it is; before its bus and its distance"`,
    pitch:f32 `mirai:"label=Rate of playback the voice was given"`,
    pan:f32 `mirai:"optional,label=Of a voice that is not spatial"`,
    loop:bool,
    playing:bool `mirai:"label=The mixer has not ended it as of its last update"`,
    spatial:bool,
    position:[3]f32 `mirai:"optional,label=Of a spatial voice: where it was placed last in meters"`,
    lowpass:f32 `mirai:"label=Cutoff in Hz it was given; 0: none"`,
    reverb:f32 `mirai:"label=Share of it sent to the reverb"`,
}

@(private)
play_observe_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="play.ui",summary="The live tree of the UI of the game of the caller as its last frame built it: each interface with its nodes and where they are in the window, and what has the hover and the focus.",params=Api_Play_Ui_Params,result=Api_Play_Ui,writes_result=true,flags={.Read_Only},run=api_play_ui})
    api_register(s,st,{name="play.audio",summary="The voices the sources of the game of the caller play: sound, bus, gain, pitch and place of each, with the counters of its voices and of the mixer.",params=Api_Play_Audio_Params,result=Api_Play_Audio,writes_result=true,flags={.Read_Only},run=api_play_audio})
}

@(private)
api_play_ui :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Ui_Params)
    r,_:=api_play_run(s,call,p.player)
    if r==nil {api_play_none(call,`{"contexts":[],"interfaces":[]}`);return}
    // The names come from the files of the interfaces, which can be larger than the scratch of a request.
    arena:virtual.Arena
    if virtual.arena_init_growing(&arena)!=nil {api.call_fail(call,api.INTERNAL_ERROR,"The editor has no memory to read the interfaces");return}
    defer virtual.arena_destroy(&arena)
    view:=Play_Ui_View{
        session=s,gui=host.app_world_storage(s.app,r.world,egui.Gui),world=core.world_ref(r.world,s.info),
        all=p.all,allocator=virtual.arena_allocator(&arena),
    }
    play_ui_write(&view,call.out)
}

@(private)
api_play_audio :: proc(s:^Session,call:^api.Call) {
    r,_:=api_play_run(s,call,api.call_params(call,Api_Play_Audio_Params).player)
    if r==nil {api_play_none(call,`{"voices":[],"stats":{"started":0,"ended":0}}`);return}
    play_audio_write(s,call.out,host.app_world_storage(s.app,r.world,eaudio.Voices),core.world_ref(r.world,s.info),s.app.mixer)
}

// ---------------------------------------------------------------- shared

@(private)
play_entity_write :: proc(out:^serial.Writer,key:string,e:core.Entity,first:=false) {
    api.write_key(out,key,first)
    serial.write_u8(out,'"');serial.text_write_hex(out,u64(e));serial.write_u8(out,'"')
}

@(private)
play_asset_write :: proc(out:^serial.Writer,key:string,id:base.Asset_Id) {
    api.write_key(out,key)
    serial.write_u8(out,'"');serial.text_write_asset_id(out,id);serial.write_u8(out,'"')
}

// The id of an entity of the game in the scene, when it has one.
@(private)
play_entity_id_write :: proc(out:^serial.Writer,w:core.World_Ref,e:core.Entity) {
    if w.data==nil || w.info==nil {return}
    if id:=api_entity_id(w,e);id!=0 {api.write_key(out,"id");api.write_id(out,id)}
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

// The interfaces of a world as its last frame built them.
@(private)
play_ui_write :: proc(v:^Play_Ui_View,out:^serial.Writer) {
    serial.text_write_raw(out,`{"contexts":[`)
    g:=v.gui
    if g==nil {
        serial.text_write_raw(out,`],"interfaces":[]}`)
        return
    }
    first:=true
    for &surface,player in g.surfaces {
        ctx:=surface.ctx
        if ctx==nil || !surface.shown && !v.all {continue}
        if !first {serial.write_u8(out,',')}
        first=false
        rect:=surface.rect
        serial.write_u8(out,'{')
        api.write_int(out,"player",i64(player),true)
        api.write_numbers(out,"rect",rect[:])
        api.write_key(out,"scale");api.write_number(out,ctx.scale)
        api.write_bool(out,"pointer_consumed",surface.pointer)
        api.write_bool(out,"keyboard_consumed",surface.keyboard)
        hovered,focused:=play_ui_targets(g,player)
        if hovered.tree!=nil {play_ui_target_write(v,out,"hovered",hovered)}
        if focused.tree!=nil {play_ui_target_write(v,out,"focused",focused)}
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,`],"interfaces":[`)
    first=true
    listed:=make([]bool,len(g.instances),v.allocator)
    for &entry in g.plan {
        at:=play_ui_instance_of(g,entry.entity,entry.world,entry.player)
        if at<0 || listed[at] {continue}
        listed[at]=true
        instance:=&g.instances[at]
        if !instance.shown && !v.all {continue}
        if !first {serial.write_u8(out,',')}
        first=false
        play_ui_interface_write(v,out,instance,play_ui_tree(instance,entry.content),entry.top)
    }
    if v.all {
        for &instance,at in g.instances {
            if listed[at] {continue}
            if !first {serial.write_u8(out,',')}
            first=false
            play_ui_interface_write(v,out,&instance,nil,false)
        }
    }
    serial.text_write_raw(out,`]}`)
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
play_ui_target_write :: proc(v:^Play_Ui_View,out:^serial.Writer,key:string,target:Play_Ui_Target) {
    api.write_key(out,key)
    serial.write_u8(out,'{')
    play_entity_write(out,"entity",target.entity,true)
    api.write_int(out,"row",i64(target.row))
    names:=play_ui_names(v,target.asset,target.tree)
    api.write_text(out,"name",target.row<len(names)?names[target.row]:"")
    serial.write_u8(out,'}')
}

@(private)
play_ui_interface_write :: proc(v:^Play_Ui_View,out:^serial.Writer,instance:^egui.Instance,tree:^ui.Widget_Tree,top:bool) {
    s:=v.session
    serial.write_u8(out,'{')
    play_entity_write(out,"entity",instance.entity,true)
    play_entity_id_write(out,v.world,instance.entity)
    api.write_text(out,"kind",instance.world?"World_Widget":"UI_Screen")
    play_asset_write(out,"asset",instance.asset)
    api.write_text(out,"path",asset_path(s,instance.asset))
    api.write_int(out,"player",i64(instance.player))
    api.write_bool(out,"shown",tree!=nil && instance.shown)
    api.write_bool(out,"top",top)
    api.write_bool(out,"modal",instance.modal)
    if tree==nil {
        serial.write_u8(out,'}')
        return
    }
    names:=play_ui_names(v,instance.asset,tree)
    ctx:=v.gui.surfaces[instance.player].ctx if instance.player>=0 && instance.player<len(v.gui.surfaces) else nil
    shown:=make([]bool,tree.node_count,v.allocator)
    disabled:=make([]bool,tree.node_count,v.allocator)
    api.write_key(out,"nodes");serial.write_u8(out,'[')
    first:=true
    for row in 0..<tree.node_count {
        state,_:=ui.tree_node_state(tree,&instance.instance,row)
        node:=&tree.nodes[row]
        parent:=int(node.parent)
        // A node shows while its containers do, and is disabled with them.
        shown[row]=state.shown && instance.shown && (parent<0 || shown[parent])
        disabled[row]=state.disabled || parent>=0 && disabled[parent]
        if !shown[row] && !v.all {continue}
        if !first {serial.write_u8(out,',')}
        first=false
        serial.write_u8(out,'{')
        api.write_int(out,"row",i64(row),true)
        api.write_int(out,"parent",i64(parent))
        api.write_text(out,"name",row<len(names)?names[row]:"")
        api.write_text(out,"kind",fmt.tprint(node.kind))
        api.write_bool(out,"shown",shown[row])
        api.write_bool(out,"hovered",shown[row] && state.hovered)
        api.write_bool(out,"focused",shown[row] && state.focused)
        api.write_bool(out,"disabled",disabled[row])
        // A World_Widget is laid out on its panel, not in the window.
        if shown[row] && !instance.world && ctx!=nil {
            if r,laid:=egui.screen_node_rect(ctx,tree,instance.entity,row);laid {
                rect:=[4]f32{r.x,r.y,r.w,r.h}
                api.write_numbers(out,"rect",rect[:])
            }
        }
        if state.text!="" {api.write_text(out,"text",state.text)}
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,`]}`)
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
play_audio_write :: proc(s:^Session,out:^serial.Writer,voices:^eaudio.Voices,w:core.World_Ref,m:^mixer.Mixer) {
    serial.text_write_raw(out,`{"voices":[`)
    stats:eaudio.Audio_Stats
    if voices!=nil {
        stats=voices.stats
        for &entry,at in voices.entries.values {
            e:=voices.entries.entities[at]
            if at>0 {serial.write_u8(out,',')}
            serial.write_u8(out,'{')
            play_entity_write(out,"entity",e,true)
            play_entity_id_write(out,w,e)
            api.write_text(out,"name",w.data!=nil && w.info!=nil?entity_name(w,e):"")
            play_asset_write(out,"sound",entry.sound)
            api.write_text(out,"path",asset_path(s,entry.sound))
            bus:string
            if s.info!=nil {bus,_=core.name_of(s.info,eaudio.Audio_Bus,i64(entry.bus))}
            api.write_text(out,"bus",bus if bus!="" else fmt.tprintf("%d",int(entry.bus)))
            volume,pitch:=eaudio.voice_entry_given(entry)
            api.write_key(out,"volume");api.write_number(out,volume)
            api.write_key(out,"pitch");api.write_number(out,pitch)
            if !entry.spatial {api.write_key(out,"pan");api.write_number(out,entry.pan)}
            api.write_bool(out,"loop",entry.loop)
            api.write_bool(out,"playing",m!=nil && mixer.voice_valid(m,entry.voice))
            api.write_bool(out,"spatial",entry.spatial)
            if entry.spatial {api.write_numbers(out,"position",entry.position)}
            api.write_key(out,"lowpass");api.write_number(out,entry.lowpass)
            api.write_key(out,"reverb");api.write_number(out,entry.reverb)
            serial.write_u8(out,'}')
        }
    }
    serial.text_write_raw(out,`],"stats":{`)
    api.write_uint(out,"started",stats.started,true)
    api.write_uint(out,"ended",stats.ended)
    serial.write_u8(out,'}')
    if m!=nil {
        counters:=mixer.mixer_stats(m)
        api.write_key(out,"mixer");serial.write_u8(out,'{')
        api.write_int(out,"voices_active",i64(counters.voices_active),true)
        api.write_int(out,"sounds",i64(counters.sounds))
        api.write_uint(out,"voices_played",counters.voices_played)
        api.write_uint(out,"voices_stolen",counters.voices_stolen)
        api.write_uint(out,"voices_rejected",counters.voices_rejected)
        api.write_uint(out,"commands_dropped",counters.commands_dropped)
        api.write_uint(out,"underruns",counters.underruns)
        api.write_uint(out,"streams_busy",counters.streams_busy)
        api.write_uint(out,"feeds_busy",counters.feeds_busy)
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,'}')
}
