package game

import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"

GALLERY_START :: mm.Vec3{0,.05,8} // where Mirai starts, and comes back to when it falls

// What the player of the gallery can do where it stands.
Gallery_Hud_Place :: enum u8 {
    Walking,  // near no station
    Spider,   // it drives the spider
    Panel,    // it adjusts the panel of a station
    Station,  // it stands at a station
}

// What the E key does at a station.
Gallery_Hud_Use :: enum u8 {Nothing,Adjust,Drive}

// What animation_hud.ui shows, at the bottom of the screen, on the entity of the player of the gallery.
@(component,description="The HUD of the gallery of animation: the station its player stands at and what it can do there.")
Gallery_Hud :: struct {
    place:Gallery_Hud_Place,
    use:Gallery_Hud_Use,
    title:[64]u8 `mirai:"text"`,
    detail:[96]u8 `mirai:"text"`,
}

@(step="frame")
gallery_hud :: proc(huds:^core.Table(Gallery_Hud),players:^core.Table(Gallery_Player,.Read),gallery:^core.Table(Animation_Gallery,.Read),panels:^core.Table(Gallery_Panel,.Read),drivables:^core.Table(inp.Drivable,.Read)) {
    for row in 0..<core.count(huds) {
        seat:=core.entity_at(huds,row)
        player,found:=core.get(players,seat)
        if !found {continue}
        body:=inp.body_of(drivables,seat)
        next:Gallery_Hud
        if body==player.spider && body!=core.NONE {
            next.place=.Spider
        } else if focus,focused:=core.get(panels,player.focus);focused {
            next.place,next.title=.Panel,focus.title
        } else if item,near:=core.get(gallery,player.near);near {
            next.place,next.title,next.detail=.Station,item.title,item.detail
            for at in 0..<core.count(panels) {if core.at(panels,at).station==player.near {next.use=.Adjust}}
            if next.use==.Nothing && item.kind==.Spider {next.use=.Drive}
        }
        core.edit_at(huds,row)^=next
    }
}
