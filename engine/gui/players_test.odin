package gui

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import inp "mirai:engine/input"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

// What a HUD on the body of a player shows.
@(private="file")
Player_Test_Hud :: struct {coins:i32}

// The world of a split window: the seats, the bodies they drive with a HUD
// on each, and what a frame of the interfaces reads.
@(private="file")
Players_Test_World :: struct {
    using world:core.Test_World,
    screens:core.Table(UI_Screen),
    widgets:core.Table(World_Widget),
    worlds:core.Table(core.World_Transform),
    hidden:core.Table(render.Hidden),
    parents:core.Table(core.Parent),
    meshes:core.Table(render.Mesh_Renderer),
    seats:core.Table(inp.Seat),
    drivables:core.Table(inp.Drivable),
    cameras:core.Table(render.Camera),
    exposures:core.Table(render.Exposure),
    view_volumes:core.Table(render.View_Volume),
    volumes:core.Table(volume.Volume),
    huds:core.Table(Player_Test_Hud),
}

@(private="file") HUD_ID :: base.Asset_Id{0x4d,1}

@(private="file")
Players_Fixture :: struct {
    w:Players_Test_World,
    assets:host.Assets,
    app:host.App,
    gui:Gui,
    state:inp.Seats,
    bindings:inp.Input_Map,
    actions:inp.Frame_Actions,
    requests:UI_Requests,
    effects:UI_Effects,
    seat_requests:inp.Seat_Requests,
    contexts:inp.Input_Contexts,
    context_requests:inp.Context_Requests,
    problems:core.Problems,
}

// One frame of the interfaces of the world, as the loop runs its ui phase.
@(private="file")
players_frame :: proc(f:^Players_Fixture) {
    w:=&f.w
    world:=core.test_world_ref(w)
    frame_begin(world,core.read(&w.screens),core.read(&w.widgets),core.read(&w.worlds),core.read(&w.hidden),core.read(&w.parents),core.read(&w.meshes),
        UI_SETTINGS_DEFAULT,UI_PREFERENCES_DEFAULT,{},core.ref(&f.state),core.read(&w.seats),core.read(&w.drivables),core.ref(&f.bindings),core.ref(&f.actions),
        {},core.read(&w.cameras),core.read(&w.exposures),core.read(&w.view_volumes),core.read(&w.volumes),&f.requests,&f.effects,&f.gui,&f.app,&f.problems,false)
    widgets_build(world,&f.gui,&f.app,&f.problems)
}

@(private="file")
players_frame_end :: proc(f:^Players_Fixture) {
    frame_end(&f.gui,&f.app,core.ref(&f.state),core.read(&f.w.seats),&f.seat_requests,core.ref(&f.contexts),&f.context_requests,&f.problems,false)
}

// The texts a context drew in the frame it is building.
@(private="file")
context_shows :: proc(ctx:^ui.Context,text:string) -> bool {
    if ctx==nil {return false}
    for &paint in ctx.paints[:ctx.paint_count] {if paint.text==text {return true}}
    return false
}

// A UI_Screen that names no player, on the body a seat drives, shows in the
// part of the window of the player of that seat: with two local players each
// HUD is built in the context of its own, with the values of its own body,
// and nothing of them in the window's. A body nobody drives, or one a player
// of another end drives, shows none; a screen on any other entity is the
// window's. With one player the bodies' are the window's too. Idle, every
// context shows its last frame again.
@(test)
a_screen_on_the_body_of_a_player_shows_in_the_part_of_that_player :: proc(t:^testing.T) {
    f:=new(Players_Fixture)
    defer free(f)
    root:=base.test_folder(t,"gui-players")
    if root=="" {return}
    types:asset.Types
    asset.types_init(&types)
    nodes:=[2]ui.Tree_Node{{kind=.Box,parent=-1},{kind=.Text,parent=0,style=1}}
    ui.tree_text_set(nodes[0].name[:],"hud")
    ui.tree_text_set(nodes[1].name[:],"coins")
    ui.tree_text_set(nodes[1].bind_text[:],"Player_Test_Hud.coins")
    styles:=[2]ui.Node_Style{{},{text={size=14,color={255,255,255,255}}}}
    doc:asset.Document
    saved:=host.ui_tree_document(&doc,&types,HUD_ID,{nodes=nodes[:],styles=styles[:]})
    if saved==.None {
        saved=asset.document_save(&doc,fmt.tprintf("%s/hud.ui",root))
        asset.document_destroy(&doc)
    }
    asset.types_destroy(&types)
    if !testing.expect_value(t,saved,asset.Error.None) {return}
    if !testing.expect(t,host.assets_init(&f.assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&f.assets)
    host.assets_scan(&f.assets)
    f.app=host.App{assets=&f.assets,allocator=context.allocator,drawable={800,400},density=1}
    f.app.ui_input={size={800,400},scale=1,dt=1.0/60,pointer_absent=true}
    defer {
        ui.font_destroy(&f.app.ui_font)
        host.app_content_destroy(&f.app)
    }
    if !testing.expect(t,ui.font_init(&f.app.ui_font,nil,nil,1,f.app.allocator,on_demand=true)) {return}
    w:=&f.w
    if !core.test_world_init(t,w,test_types) {return}
    defer core.test_world_destroy(w)
    f.app.info=core.test_world_info(w)
    defer {
        gui_free(&f.gui)
        delete(f.requests.items);delete(f.effects.items);delete(f.seat_requests.items);delete(f.context_requests.items)
    }

    seats:[2]core.Entity
    bodies:[2]core.Entity
    for slot in 0..<2 {
        seats[slot],bodies[slot]=core.create(&w.entities),core.create(&w.entities)
        core.add(&w.seats,seats[slot],inp.Seat{slot=u8(slot)})
        core.add(&w.drivables,bodies[slot],inp.Drivable{seat=seats[slot]})
        core.add(&w.screens,bodies[slot],UI_Screen{asset=HUD_ID})
        core.add(&w.huds,bodies[slot],Player_Test_Hud{coins=i32(3+4*slot)})
    }
    // A body nobody drives, one a player of another end drives, and the screen of the scene.
    empty,away,remote,scene:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.drivables,empty,inp.Drivable{})
    core.add(&w.screens,empty,UI_Screen{asset=HUD_ID})
    core.add(&w.huds,empty,Player_Test_Hud{coins=50})
    core.add(&w.seats,away,inp.Seat{slot=1,peer=9})
    core.add(&w.drivables,remote,inp.Drivable{seat=away})
    core.add(&w.screens,remote,UI_Screen{asset=HUD_ID})
    core.add(&w.huds,remote,Player_Test_Hud{coins=60})
    core.add(&w.screens,scene,UI_Screen{asset=HUD_ID})
    core.add(&w.huds,scene,Player_Test_Hud{coins=90})
    core.test_world_settle(w)

    owner :: proc(w:^Players_Test_World,e:core.Entity) -> (slot:int,owned,local:bool) {
        return screen_owner(core.read(&w.seats),core.read(&w.drivables),core.read(&w.parents),e)
    }
    Case :: struct {e:core.Entity,slot:int,owned,local:bool}
    cases:=[]Case{{bodies[0],0,true,true},{bodies[1],1,true,true},{seats[1],1,true,true},{empty,0,true,false},{remote,1,true,false},{scene,0,false,false},{core.NONE,0,false,false},{core.entity_make(900,3),0,false,false}}
    for c in cases {
        slot,owned,local:=owner(w,c.e)
        testing.expectf(t,slot==c.slot && owned==c.owned && local==c.local,"entity %v: slot %d owned %v local %v",c.e,slot,owned,local)
    }

    f.state.local_count=2
    players_frame(f)
    first,second,window:=&f.gui.surfaces[1],&f.gui.surfaces[2],&f.gui.surfaces[0]
    if !testing.expect(t,first.open && second.open && window.open,"Each player and the window build their own") {
        for &problem in f.problems.entries[:f.problems.count] {testing.expectf(t,false,"%s: %s",base.text_get(problem.code[:]),base.text_get(problem.text[:]))}
        players_frame_end(f)
        return
    }
    testing.expect(t,context_shows(first.ctx,"3") && !context_shows(first.ctx,"7"),"The first player sees the HUD of its body")
    testing.expect(t,context_shows(second.ctx,"7") && !context_shows(second.ctx,"3"),"The second player sees the HUD of its own")
    testing.expect(t,context_shows(window.ctx,"90") && !context_shows(window.ctx,"3") && !context_shows(window.ctx,"7"),"The screen of the scene is the window's")
    for s in ([]^Surface{first,second,window}) {testing.expect(t,!context_shows(s.ctx,"50") && !context_shows(s.ctx,"60"),"A body no local player drives shows no screen")}
    testing.expect(t,first.rect!=second.rect && first.rect.z<f32(800) && second.rect.z<f32(800),"Each is built in its part of the window")
    for entry in f.gui.plan {
        want:=0
        if entry.entity==bodies[0] {want=1} else if entry.entity==bodies[1] {want=2}
        testing.expect_value(t,entry.player,want)
    }
    testing.expect_value(t,len(f.gui.plan),3)
    players_frame_end(f)

    // Idle: once nothing of a frame differs from the last, no context is built.
    skipped:=f.gui.skipped
    for _ in 0..<4 {
        players_frame(f)
        players_frame_end(f)
    }
    before:=f.gui.skipped
    players_frame(f)
    testing.expect(t,first.skipped && second.skipped && window.skipped && !first.open && !second.open,"Idle, each context shows its last frame")
    players_frame_end(f)
    testing.expect(t,f.gui.skipped==before+3 && before>skipped,"The frames skipped are counted")

    // What one body shows changes: its player builds again, the other does not.
    core.edit(&w.huds,bodies[1]).coins=8
    core.test_world_settle(w)
    players_frame(f)
    testing.expect(t,second.open && context_shows(second.ctx,"8") && first.skipped,"Only the player whose HUD changed is built")
    players_frame_end(f)

    // One player: the screen of its body is the window's.
    f.state.local_count=1
    players_frame(f)
    testing.expect(t,window.open && context_shows(window.ctx,"3") && context_shows(window.ctx,"90") && !context_shows(window.ctx,"8"),"With one player the HUD of its body is in the window")
    testing.expect(t,!first.open && !second.open)
    players_frame_end(f)
}
