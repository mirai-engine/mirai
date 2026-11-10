package game

import "core:math"
import "mirai:core"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
import mm "mirai:std/math"

// A raft on the sea: the swimmer can jump in, swim on the surface and under
// it, and drowns when its breath runs out. The breath is a rule of this game
// over how deep the physics says its head is.

RAFT_DROWNED_SECONDS :: 3 // the message stays this long

// Under the surface its oxygen runs out; with the head out it comes back. With
// none left it drowns and comes back on the raft of its scene, breathing.
@(component,replicated,description="The breath of a swimmer: its oxygen runs out while its head is under the surface and comes back over it; with none left it drowns.")
Diver :: struct {
    capacity:f32 `mirai:"min=0,unit=s"`, // of oxygen in a full breath
    refill:f32 `mirai:"min=0"`,          // seconds of oxygen it gets back each second with the head out
    oxygen:f32 `mirai:"transient,readonly,unit=s"`, // left
    drowned:u32 `mirai:"transient,readonly"`,       // times it drowned
}

DIVER_DEFAULT :: Diver{capacity=45,refill=15}

// The raft divers come back to, and its message.
@(component,description="The raft a swimmer that drowns comes back onto.")
Raft_Game :: struct {
    raft:core.Entity,
    deck:f32 `mirai:"unit=m"`, // over the center of the raft, where a diver comes back
    message_until:u64 `mirai:"transient,readonly"`, // the tick the drowned message goes at
}

@(step="fixed")
raft_breath :: proc(
    divers:^core.Table(Diver),states:core.Read(phys.Character_State),games:^core.Table(Raft_Game),
    worlds:core.Read(core.World_Transform),placer:core.Placer,time:core.Time,
) {
    if !time.playing || !(time.dt>0) {return}
    for row in 0..<core.count(divers) {
        e:=core.entity_at(divers,row)
        state,has:=core.get(states,e)
        if !has {continue}
        // Only a breath that changes is written: a full one over the surface stays as it is.
        next:=core.at(divers,row)
        if core.added(divers,row) {next.oxygen=next.capacity} // its first breath
        if state.head_depth>0 {
            next.oxygen=max(next.oxygen-time.dt,0)
        } else {next.oxygen=min(next.oxygen+next.refill*time.dt,next.capacity)}
        drowned:=next.oxygen<=0
        if drowned {next.oxygen,next.drowned=next.capacity,next.drowned+1}
        if next!=core.at(divers,row) {core.edit_at(divers,row)^=next}
        if !drowned {continue}
        for &game in core.writable(games) {
            raft,found:=core.get(worlds,game.raft)
            if !found {continue}
            core.place(placer,e,raft.position+mm.Vec3{0,game.deck,0},at_rest=true)
            game.message_until=core.deadline(time,RAFT_DROWNED_SECONDS)
            break
        }
    }
}

// How the swimmer moves, as raft_hud.ui says it.
Raft_Doing :: enum u8 {On_Raft,Wading,Surface,Under}

// How much breath it has left: the variant of the style of its count.
Raft_Air :: enum u8 {Fine,Low}

// What raft_hud.ui shows of the swimmer it is on: the screen is on the
// swimmer, so it shows in the view of the player that drives it, and only then.
@(component,description="The HUD of a swimmer: its breath, how it moves and the message of its last drowning.")
Raft_Hud :: struct {
    doing:Raft_Doing,
    oxygen:i32,        // whole seconds of breath left
    breath:f32,        // of a full one, 0 to 1
    air:Raft_Air,      // Low under a quarter of a breath
    drowned:i32,       // times it drowned
    drowned_once:bool,
    message:bool,      // it has just drowned
}

@(step="frame")
raft_hud :: proc(
    huds:^core.Table(Raft_Hud),divers:core.Read(Diver),games:core.Read(Raft_Game),states:core.Read(phys.Character_State),characters:core.Read(phys.Character),
    time:core.Time,
) {
    shown:=core.read(huds)
    for row in 0..<core.count(shown) {
        body:=core.entity_at(shown,row)
        next:Raft_Hud
        if diver,is_diver:=core.get(divers,body);is_diver && core.count(games)>0 {
            state,_:=core.get(states,body)
            character,_:=core.get(characters,body)
            switch {
            case character.mode==phys.MODE_SWIMMING && .Underwater in state.fluid: next.doing=.Under
            case character.mode==phys.MODE_SWIMMING:                               next.doing=.Surface
            case .In_Fluid in state.fluid:                                         next.doing=.Wading
            }
            share:=diver.capacity>0?clamp(diver.oxygen/diver.capacity,0,1):0
            next.oxygen,next.breath,next.air=i32(math.round(diver.oxygen)),share,share<0.25?.Low:.Fine
            next.drowned,next.drowned_once=i32(diver.drowned),diver.drowned>0
            for at in 0..<core.count(games) {next.message||=!core.due(time,core.at(games,at).message_until)}
        }
        if core.at(shown,row)!=next {core.edit_at(huds,row)^=next}
    }
}
