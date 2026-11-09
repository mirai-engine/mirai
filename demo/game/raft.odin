package game

import "core:fmt"
import "mirai:core"
import gui "mirai:engine/gui"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// A raft on the sea: the swimmer can jump in, swim on the surface and under
// it, and drowns when its breath runs out. The breath is a rule of this game
// over how deep the physics says its head is.

RAFT_SCENE :: "raft/raft.scene"
RAFT_PLAYER_PREFAB :: base.Asset_Id{0x6d69726169646d6f,0x7261667400000001}
RAFT_DROWNED_SECONDS :: 3 // the message stays this long

// Under the surface its oxygen runs out; with the head out it comes back. With
// none left it drowns and comes back on the raft of its scene, breathing.
@(component,replicated,description="The breath of a swimmer: its oxygen runs out while its head is under the surface and comes back over it; with none left it drowns.")
Diver :: struct {
    capacity:f32 `mirai:"min=0,unit=s"`, // of oxygen in a full breath
    refill:f32 `mirai:"min=0"`,          // seconds of oxygen it gets back each second with the head out
    oxygen:f32 `mirai:"transient,readonly,unit=s"`, // left
    drowned:u32 `mirai:"transient,readonly"`,       // times it drowned
    ready:bool `mirai:"transient,hidden"`,          // took its first breath
}

DIVER_DEFAULT :: Diver{capacity=45,refill=15}

// The raft divers come back to, and its message.
@(component,description="The raft a swimmer that drowns comes back onto.")
Raft_Game :: struct {
    raft:core.Entity,
    deck:f32 `mirai:"unit=m"`, // over the center of the raft, where a diver comes back
    message:f32 `mirai:"transient,readonly,unit=s"`, // left of the drowned message
}

@(step="fixed")
raft_breath :: proc(
    divers:^core.Table(Diver),states:core.Read(phys.Character_State),games:^core.Table(Raft_Game),
    worlds:core.Read(core.World_Transform),placer:core.Placer,bodies:^phys.Body_Requests,time:core.Time,
) {
    if !time.playing || !(time.dt>0) {return}
    for row in 0..<core.count(core.read(games)) {
        if left:=core.at(core.read(games),row).message;left>0 {core.at(games,row).message=max(left-time.dt,0)}
    }
    for row in 0..<core.count(core.read(divers)) {
        e:=core.entity_at(divers,row)
        state,has:=core.get(states,e)
        if !has {continue}
        // Only a breath that changes is written: a full one over the surface stays as it is.
        next:=core.at(core.read(divers),row)
        if !next.ready {next.oxygen,next.ready=next.capacity,true}
        if state.head_depth>0 {
            next.oxygen=max(next.oxygen-time.dt,0)
        } else {next.oxygen=min(next.oxygen+next.refill*time.dt,next.capacity)}
        drowned:=next.oxygen<=0
        if drowned {next.oxygen,next.drowned=next.capacity,next.drowned+1}
        if next!=core.at(core.read(divers),row) {core.at(divers,row)^=next}
        if !drowned {continue}
        for &game in core.writable(games) {
            raft,found:=core.get(worlds,game.raft)
            if !found {continue}
            core.place(placer,e,raft.position+mm.Vec3{0,game.deck,0})
            phys.launch(bodies,e,{},override=true)
            game.message=RAFT_DROWNED_SECONDS
            break
        }
    }
}

// The breath of the swimmer the focused seat drives, how it moves, and what to press.
@(step="ui")
raft_hud :: proc(
    g:^gui.Gui,divers:core.Read(Diver),games:core.Read(Raft_Game),states:core.Read(phys.Character_State),characters:core.Read(phys.Character),
    drivables:core.Read(inp.Drivable),seat_state:core.Ref(inp.Seats),locals:core.Read(inp.Seat),app:^host.App,
) {
    ctx:=gui.gui_context(g)
    if ctx==nil || core.count(games)==0 {return}
    body:=inp.body_of(drivables,inp.focused(seat_state.ptr,locals))
    diver,is_diver:=core.get(divers,body)
    if !is_diver {return}
    state,_:=core.get(states,body)
    character,_:=core.get(characters,body)
    pixels:=host.app_player_rect(app,seat_state.focus,seat_state.local_count)
    rect:=[4]f32{f32(pixels.x),f32(pixels.y),f32(pixels.z),f32(pixels.w)}/max(app.density,0.01)
    root:=ui.Box{
        id=ui.id(ctx,"raft.hud"),layout={width=ui.fixed(rect.z),height=ui.fixed(rect.w)},
        float={to=.Surface,layer=1000,offset={rect.x,rect.y}},
    }
    ui.box_begin(ctx,root)
    defer ui.box_end(ctx,root)
    panel:=hud_box(ctx,"panel",.Top_Left,.Top_Left,{12,12},ui.fixed(min(360,rect.z-24)),ui.fit(),{0,0,0,160},ui.padding_xy(12,8))
    panel.layout.direction=.Column
    panel.layout.gap=5
    if ui.box(ctx,panel) {
        doing:="On the raft"
        switch {
        case character.mode==phys.MODE_SWIMMING && .Underwater in state.fluid: doing="Swimming under the water"
        case character.mode==phys.MODE_SWIMMING: doing="Swimming on the surface"
        case .In_Fluid in state.fluid: doing="Wading"
        }
        ui.label(ctx,doing,size=18)
        share:=diver.capacity>0?clamp(diver.oxygen/diver.capacity,0,1):0
        ui.label(ctx,fmt.tprintf("Oxygen %.0f s",diver.oxygen),color=share<0.25?ui.Color{255,120,90,255}:ui.Color{170,220,255,255})
        BAR :: 300
        bar:=ui.Box{id=ui.id(ctx,"raft.oxygen"),layout={width=ui.fixed(BAR),height=ui.fixed(10)},fill={40,60,80,220},radius=3}
        if ui.box(ctx,bar) {
            if ui.box(ctx,ui.Box{id=ui.id(ctx,"raft.oxygen.left"),layout={width=ui.fixed(BAR*share),height=ui.fixed(10)},fill={90,190,255,255},radius=3}) {}
        }
        if diver.drowned>0 {ui.label(ctx,fmt.tprintf("Drowned %d times",diver.drowned),size=12,color={200,200,210,255})}
        ui.text(ctx,"WASD: walk and swim    Space: jump, climb out at the surface    look down and forward to dive, up to come back",{size=12,color={255,210,116,255},wrap=.Words},width=ui.fixed(min(360,rect.z-24)-24))
    }
    for game in games.table.values[:core.count(games)] {
        if game.message<=0 {continue}
        message:=hud_box(ctx,"drowned",.Center,.Center,{0,-60},ui.fit(),ui.fixed(48),{20,0,0,180},ui.padding_xy(20,0))
        if ui.box(ctx,message) {ui.label(ctx,"You drowned",size=26,color={255,140,120,255})}
        break
    }
}
