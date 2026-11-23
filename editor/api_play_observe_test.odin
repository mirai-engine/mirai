package editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import mixer "mirai:audio"
import "mirai:core"
import "mirai:editor/api"
import eaudio "mirai:engine/audio"
import egui "mirai:engine/gui"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// A row of two cards of one template, the right one with its button disabled.
@(private="file")
Observe_Records :: struct {
    nodes:[3]ui.Tree_Node,
    templates:[1]ui.Tree_Component,
    component_nodes:[3]ui.Tree_Node,
    overrides:[2]ui.Tree_Override,
    styles:[1]ui.Node_Style,
}

@(private="file")
observe_records :: proc(r:^Observe_Records) -> ui.Tree_Data {
    texts:=make([dynamic]u8,context.temp_allocator)
    r.templates={ui.tree_component_record("card",0,3)}
    r.component_nodes={
        ui.tree_node_record(&texts,-1,{kind=.Box,name="card",layout={width=ui.fixed(180),height=ui.fixed(80),direction=.Column,gap=6,padding=ui.padding_all(8)}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="title",text="Title"}),
        ui.tree_node_record(&texts,0,{kind=.Button,name="action",text="Open",layout={width=ui.fixed(90),height=ui.fixed(28)}}),
    }
    r.nodes={
        ui.tree_node_record(&texts,-1,{kind=.Box,name="row",layout={gap=12}}),
        ui.tree_node_record(&texts,0,{kind=.Component,name="left",component=1}),
        ui.tree_node_record(&texts,0,{kind=.Component,name="right",component=1}),
    }
    r.overrides={
        ui.tree_override_record(&texts,1,"title",{.Text},{text="Inventory"}),
        ui.tree_override_record(&texts,2,"action",{.Visibility},{disabled=true}),
    }
    return {text=texts[:],nodes=r.nodes[:],styles=r.styles[:],components=r.templates[:],component_nodes=r.component_nodes[:],overrides=r.overrides[:]}
}

@(private="file")
Observe_Build :: struct {gui:^egui.Gui,tree:^ui.Widget_Tree,entity:core.Entity}

@(private="file")
observe_frame :: proc(ctx:^ui.Context,input:ui.Input,b:^Observe_Build) {
    ui.frame_begin(ctx,input)
    ui.id_push(ctx,egui.screen_scope(ctx,b.entity))
    ui.tree_build(ctx,b.tree,&b.gui.instances[0].instance,{})
    ui.id_pop(ctx)
    ui.frame_end(ctx)
}

@(private="file")
observe_json :: proc(t:^testing.T,text:string) -> json.Object {
    value,error:=json.parse(transmute([]u8)text,allocator=context.temp_allocator)
    testing.expect_value(t,error,json.Error.None)
    object,_:=value.(json.Object)
    return object
}

@(private="file")
observe_node :: proc(interface:json.Object,name:string) -> (node:json.Object,found:bool) {
    nodes,_:=interface["nodes"].(json.Array)
    for value in nodes {
        n,_:=value.(json.Object)
        if (n["name"].(json.String) or_else "")==name {return n,true}
    }
    return
}

// The UI of a game as its last frame built it: the names of the nodes as the
// .ui gives them, those of a widget after its instance; where each node of a
// screen is in window points; what the pointer is over, what a container or
// an override disables and the text each shows. By default only what shows.
@(test)
play_ui_lists_what_the_last_frame_showed_where_it_is_in_the_window :: proc(t:^testing.T) {
    r:Observe_Records
    records:=observe_records(&r)
    content:host.Content_Ui
    if !testing.expect(t,ui.tree_load(&content.tree,records,{})) {return}
    defer ui.tree_destroy(&content.tree)
    tree:=&content.tree
    names:=play_ui_names_of(records,nil,tree,context.temp_allocator)
    if !testing.expect_value(t,len(names),7) {return}
    testing.expect(t,names[0]=="row" && names[1]=="left" && names[3]=="left/action" && names[6]=="right/action")
    // Records that are not those the tree was loaded from name nothing.
    other:=records
    other.nodes=records.nodes[:1]
    testing.expect(t,play_ui_names_of(other,nil,tree,context.temp_allocator)==nil)

    asset:=base.Asset_Id{3,4}
    content.id,content.generation=asset,5
    e:=core.entity_make(2,1)
    hidden:=core.entity_make(9,1)
    g:egui.Gui
    defer {
        for &instance in g.instances {ui.tree_instance_destroy(&instance.instance)}
        delete(g.instances);delete(g.plan)
    }
    append(&g.instances,egui.Instance{entity=e,slot=egui.instance_slot(false,0),asset=asset,generation=5,shown=true,top=true})
    if !testing.expect(t,ui.tree_instance_init(&g.instances[0].instance,tree,nil)) {return}
    // A screen out of the plan of the frame: built in no frame.
    append(&g.instances,egui.Instance{entity=hidden,slot=egui.instance_slot(false,0),asset=asset,generation=5})
    append(&g.plan,egui.Planned{entity=e,instance=0,content=&content,player=0,top=true,mesh=-1})

    ctx:ui.Context
    if !testing.expect(t,ui.context_init(&ctx,{max_elements=1024,max_vertices=65536,max_widgets=512,max_text=16384,no_font=true})) {return}
    defer ui.context_destroy(&ctx)
    g.surfaces[0]={ctx=&ctx,shown=true,rect={0,0,800,600},pointer=true}
    b:=Observe_Build{&g,tree,e}
    input:=ui.Input{size={800,600},scale=2,dt=1.0/60,pointer={-100,-100}}
    observe_frame(&ctx,input,&b)
    ui.id_push(&ctx,egui.screen_scope(&ctx,e))
    action,laid:=ui.widget_rect(&ctx,ui.tree_element_id(&ctx,"left/action"))
    ui.id_pop(&ctx)
    if !testing.expect(t,laid) {return}
    // The pointer over the button of the left card, in window points.
    input.pointer={(action.x+action.w*0.5)*2,(action.y+action.h*0.5)*2}
    for _ in 0..<3 {observe_frame(&ctx,input,&b)}

    s:=Session{app=&host.App{}}
    view:=Play_Ui_View{session=&s,gui=&g,allocator=context.temp_allocator}
    view.names.allocator=context.temp_allocator
    append(&view.names,Play_Ui_Names{asset,tree,names})
    text:=observe_text(play_ui(&view))
    api_result_shape_expect(t,text,Api_Play_Ui)
    result:=observe_json(t,text)
    contexts,_:=result["contexts"].(json.Array)
    if !testing.expect_value(t,len(contexts),1) {return}
    window,_:=contexts[0].(json.Object)
    testing.expect_value(t,window["scale"].(json.Float) or_else 0,2)
    testing.expect(t,window["pointer_consumed"].(json.Boolean) or_else false)
    over,_:=window["hovered"].(json.Object)
    testing.expect_value(t,over["name"].(json.String) or_else "","left/action")
    testing.expect_value(t,over["row"].(json.Float) or_else 0,3)
    interfaces,_:=result["interfaces"].(json.Array)
    if !testing.expect_value(t,len(interfaces),1) {return}
    screen,_:=interfaces[0].(json.Object)
    testing.expect_value(t,screen["kind"].(json.String) or_else "","UI_Screen")
    testing.expect_value(t,screen["asset"].(json.String) or_else "","00000000000000030000000000000004")
    testing.expect(t,screen["shown"].(json.Boolean) or_else false)
    left,found:=observe_node(screen,"left/action")
    if !testing.expect(t,found) {return}
    testing.expect(t,left["hovered"].(json.Boolean) or_else false)
    testing.expect(t,!(left["disabled"].(json.Boolean) or_else true))
    testing.expect_value(t,left["text"].(json.String) or_else "","Open")
    rect,_:=left["rect"].(json.Array)
    if testing.expect_value(t,len(rect),4) {
        testing.expect_value(t,rect[0].(json.Float) or_else 0,f64(action.x*2))
        testing.expect_value(t,rect[2].(json.Float) or_else 0,180)
        testing.expect_value(t,rect[3].(json.Float) or_else 0,56)
    }
    right,_:=observe_node(screen,"right/action")
    testing.expect(t,right["disabled"].(json.Boolean) or_else false)
    title,_:=observe_node(screen,"left/title")
    testing.expect_value(t,title["text"].(json.String) or_else "","Inventory")

    // What can be pressed on the screen on top, in the same window points.
    top,on_top:=play_ui_top(&view,0,false)
    testing.expect(t,on_top && !top.modal)
    if testing.expect_value(t,len(top.buttons),2) {
        testing.expect_value(t,top.buttons[0].name,"left/action")
        testing.expect(t,top.buttons[0].laid && !top.buttons[0].disabled && top.buttons[0].rect[2]==180)
        testing.expect(t,top.buttons[1].disabled)
    }

    // A press goes to the middle of the button it names, by the names shown.
    center,problem:=api_press_center(&top,"Left/Action")
    testing.expect_value(t,problem,"")
    testing.expect(t,top.buttons[0].rect[0]<center.x && center.y==top.buttons[0].rect[1]+top.buttons[0].rect[3]*0.5)
    _,problem=api_press_center(&top,"right/action")
    testing.expect(t,strings.contains(problem,"disabled"),problem)
    _,problem=api_press_center(&top,"nothing")
    testing.expect(t,strings.contains(problem,"left/action"),problem)

    // all lists the screen the frame did not build too, without nodes.
    view.all=true
    text=observe_text(play_ui(&view))
    api_result_shape_expect(t,text,Api_Play_Ui)
    interfaces,_=observe_json(t,text)["interfaces"].(json.Array)
    if testing.expect_value(t,len(interfaces),2) {
        absent,_:=interfaces[1].(json.Object)
        _,has_nodes:=absent["nodes"]
        testing.expect(t,!has_nodes && !(absent["shown"].(json.Boolean) or_else true))
    }

    // A game without the UI of engine/gui shows none.
    view.gui=nil
    testing.expect_value(t,observe_text(play_ui(&view)),`{"contexts":[],"interfaces":[]}`)
}

// A node that shows and that the layout leaves without width or height is
// flagged, by its name in its screen; a spacer, an empty container, an empty
// text and what does not show are empty by design and are not.
@(test)
a_shown_node_laid_out_without_an_area_is_found :: proc(t:^testing.T) {
    texts:=make([dynamic]u8,context.temp_allocator)
    nodes:=[?]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="row",layout={gap=12}}),
        ui.tree_node_record(&texts,0,{kind=.Button,name="play",text="Play",layout={width=ui.fixed(90),height=ui.fixed(28)}}),
        ui.tree_node_record(&texts,0,{kind=.Image,name="icon",layout={width=ui.fixed(0),height=ui.fixed(32)}}),
        ui.tree_node_record(&texts,0,{kind=.Spacer,name="gap",layout={width=ui.fixed(0),height=ui.fixed(0)}}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="empty"}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="blank"}),
        ui.tree_node_record(&texts,0,{kind=.Progress,name="hidden",flags={.Collapsed},layout={width=ui.fixed(0),height=ui.fixed(8)}}),
    }
    records:=ui.Tree_Data{text=texts[:],nodes=nodes[:]}
    content:host.Content_Ui
    if !testing.expect(t,ui.tree_load(&content.tree,records,{})) {return}
    defer ui.tree_destroy(&content.tree)
    tree:=&content.tree
    asset:=base.Asset_Id{3,4}
    content.id,content.generation=asset,5
    e:=core.entity_make(2,1)
    g:egui.Gui
    defer {
        for &instance in g.instances {ui.tree_instance_destroy(&instance.instance)}
        delete(g.instances);delete(g.plan)
    }
    append(&g.instances,egui.Instance{entity=e,slot=egui.instance_slot(false,0),asset=asset,generation=5,shown=true,top=true})
    if !testing.expect(t,ui.tree_instance_init(&g.instances[0].instance,tree,nil)) {return}
    append(&g.plan,egui.Planned{entity=e,instance=0,content=&content,player=0,top=true,mesh=-1})
    ctx:ui.Context
    if !testing.expect(t,ui.context_init(&ctx,{max_elements=1024,max_vertices=65536,max_widgets=512,max_text=16384,no_font=true})) {return}
    defer ui.context_destroy(&ctx)
    g.surfaces[0]={ctx=&ctx,shown=true,rect={0,0,800,600}}
    b:=Observe_Build{&g,tree,e}
    for _ in 0..<2 {observe_frame(&ctx,ui.Input{size={800,600},scale=1,dt=1.0/60,pointer={-100,-100}},&b)}
    s:=Session{app=&host.App{}}
    view:=Play_Ui_View{session=&s,gui=&g,allocator=context.temp_allocator}
    view.names.allocator=context.temp_allocator
    append(&view.names,Play_Ui_Names{asset,tree,play_ui_names_of(records,nil,tree,context.temp_allocator)})
    found:=play_ui_collapsed_of(&view)
    if testing.expectf(t,len(found)==1,"%v",found) {
        testing.expect(t,found[0].name=="icon" && found[0].kind==.Image && found[0].row==2 && found[0].entity==e && found[0].rect[2]==0 && found[0].rect[3]==32,fmt.tprint(found[0]))
    }
    // Whether each kind with each rectangle is hidden by its layout.
    Case :: struct {kind:ui.Node_Kind,text:string,rect:[4]f32,collapsed:bool}
    nan:=math.nan_f32()
    cases:=[]Case{
        {.Image,"",{0,0,0,0},true},{.Button,"Go",{0,0,40,0},true},{.Text,"Score",{5,5,0,12},true},{.Draw,"",{0,0,nan,8},true},
        {.Image,"",{0,0,8,8},false},{.Text,"",{0,0,0,0},false},{.Rich_Text,"",{0,0,0,12},false},
        {.Spacer,"",{0,0,0,0},false},{.Box,"",{0,0,0,0},false},{.List,"",{0,0,0,0},false},{.Prompt,"",{0,0,0,0},false},
    }
    for c in cases {
        testing.expectf(t,play_ui_node_collapsed(c.kind,c.text,c.rect)==c.collapsed,"%v %q %v",c.kind,c.text,c.rect)
    }
    // A game without the UI of engine/gui has none.
    view.gui=nil
    testing.expect_value(t,len(play_ui_collapsed_of(&view)),0)
}

// The voices of a game: what each was given, its bus by name, its place, its
// distance to the nearest listener and how hidden it is when spatial, its
// state and gain at that listener; where its listeners are; the newest
// one-shot sounds with what became of each; the counters of the game and,
// with a mixer, those of the mixer.
@(private)
@(test_world)
Audio_Test_World :: struct {
    using world:Test_World,
    sources:core.Table(eaudio.Audio_Source),
    states:core.Table(eaudio.Audio_Source_State),
    worlds:core.Table(core.World_Transform),
    listeners:core.Table(eaudio.Audio_Listener),
}

@(test)
play_audio_lists_the_voices_of_the_game_with_what_they_were_given :: proc(t:^testing.T) {
    world:Audio_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    near,far,ear:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.sources,near,eaudio.Audio_Source{sound={1,2},volume=1,pitch=2,pan=-1,bus=eaudio.BUS_MUSIC,loop=true,priority=3})
    core.add(&world.sources,far,eaudio.Audio_Source{sound={1,3},volume=1,pitch=1,bus=eaudio.Audio_Bus(6),spatial=true})
    core.add(&world.states,far,eaudio.Audio_Source_State{occlusion=0.5})
    placed:=core.World_Transform{}
    placed.rotation,placed.scale,placed.position=1,1,{1,2,7}
    core.add(&world.worlds,ear,placed)
    core.add(&world.listeners,ear,eaudio.Audio_Listener{})
    test_world_settle(&world)
    voices:eaudio.Voices
    defer core.entity_map_destroy(&voices.entries)
    core.entity_map_put(&voices.entries,near,eaudio.Voice_Entry{kind={sound={1,2},bus=eaudio.BUS_MUSIC},pick={0.5,1.5}})
    core.entity_map_put(&voices.entries,far,eaudio.Voice_Entry{kind={sound={1,3},bus=eaudio.Audio_Bus(6),spatial=true},pick={1,1},position={1,2,3},transmission={1,0.5,0.25}})
    voices.stats={started=3,ended=1}
    played:eaudio.Sounds_Played
    for outcome,i in ([3]eaudio.One_Shot_Outcome{.Played,.Culled_Distance,.Deduped}) {
        played.keys[i]={tick=u64(10+i),sound={1,2},by=near,at={0,0,f32(i)},placed=i==1,outcome=outcome,distance=40}
    }
    played.count=3
    names:=[?]core.Name_Info{{type=eaudio.Audio_Bus,name="Music",value=1}}
    info:=core.World_Info{names=names[:]}
    s:=Session{app=&host.App{},info=&info}
    heard:=Play_Audio_Heard{voices=&voices,played=&played,world=test_world_ref(&world),one_shots=2}
    text:=observe_text(play_audio(&s,heard))
    api_result_shape_expect(t,text,Api_Play_Audio)
    result:=observe_json(t,text)
    list,_:=result["voices"].(json.Array)
    if !testing.expect_value(t,len(list),2) {return}
    first,_:=list[0].(json.Object)
    testing.expect_value(t,first["pitch"].(json.Float) or_else 0,3)
    testing.expect_value(t,first["pan"].(json.Float) or_else 0,-1)
    testing.expect_value(t,first["priority"].(json.Float) or_else 0,3)
    testing.expect_value(t,first["state"].(json.String) or_else "","Unloaded")
    second,_:=list[1].(json.Object)
    testing.expect_value(t,first["bus"].(json.String) or_else "","Music")
    testing.expect_value(t,second["bus"].(json.String) or_else "","6")
    _,has_pan:=second["pan"]
    position,_:=second["position"].(json.Array)
    _,first_occlusion:=first["occlusion"]
    _,first_distance:=first["distance"]
    testing.expect(t,!has_pan && len(position)==3 && (second["occlusion"].(json.Float) or_else 0)==0.5 && !first_occlusion && !first_distance)
    testing.expect_value(t,second["distance"].(json.Float) or_else 0,4)
    testing.expect(t,strings.contains(text,`"transmission":[1,0.5,0.25]`),text)
    listeners,_:=result["listeners"].(json.Array)
    testing.expect(t,len(listeners)==1 && strings.contains(text,`"listeners":[[1,2,7]]`),text)
    one_shots,_:=result["one_shots"].(json.Array)
    if testing.expect_value(t,len(one_shots),2) {
        culled,_:=one_shots[0].(json.Object)
        testing.expect_value(t,culled["tick"].(json.Float) or_else 0,11)
        testing.expect_value(t,culled["outcome"].(json.String) or_else "","Culled_Distance")
        testing.expect_value(t,culled["distance"].(json.Float) or_else 0,40)
        testing.expect_value(t,culled["entity"].(json.String) or_else "",api_handle_text(near))
        deduped,_:=one_shots[1].(json.Object)
        _,has_distance:=deduped["distance"]
        testing.expect(t,(deduped["outcome"].(json.String) or_else "")=="Deduped" && !has_distance)
    }
    _,has_mixer:=result["mixer"]
    testing.expect(t,!has_mixer)
    testing.expect(t,strings.contains(text,`"stats":{"started":3,"ended":1}`))

    // With a mixer: a voice it plays, and one it does not hear beyond its listener.
    m,error:=mixer.mixer_create({})
    if !testing.expect_value(t,error,mixer.Error.None) {return}
    defer mixer.mixer_destroy(m)
    samples:=make([]i16,4800,context.temp_allocator)
    sound,loaded:=mixer.sound_create_pcm16(m,samples,1,mixer.MIXER_RATE)
    if !testing.expect_value(t,loaded,mixer.Error.None) {return}
    for &entry in voices.entries.values {entry.sound=sound}
    core.entity_map_get(&voices.entries,near).voice=mixer.voice_play(m,sound,mixer.VOICE_DEFAULT)
    core.entity_map_get(&voices.entries,far).position={1,2,500}
    heard.mixer=m
    list,_=observe_json(t,observe_text(play_audio(&s,heard)))["voices"].(json.Array)
    if testing.expect_value(t,len(list),2) {
        first,_=list[0].(json.Object)
        second,_=list[1].(json.Object)
        testing.expect_value(t,first["state"].(json.String) or_else "","Playing")
        testing.expect_value(t,second["state"].(json.String) or_else "","Virtual_Silent")
        testing.expect_value(t,second["effective_gain"].(json.Float) or_else 1,0)
    }
    text=observe_text(play_audio(&s,{mixer=m}))
    api_result_shape_expect(t,text,Api_Play_Audio)
    testing.expect(t,strings.contains(text,`"voices":[]`) && strings.contains(text,`"one_shots":[]`),text)
}

// What a play observe method answers, as JSON without spaces.
@(private="file")
observe_text :: proc(value:any) -> string {
    text,_:=serial.text_encode(value,.Line,context.temp_allocator,sparse=true)
    return api.json_compact(string(text))
}
