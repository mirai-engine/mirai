package game

import "core:fmt"
import "mirai:core"
import gui "mirai:engine/gui"
import inp "mirai:engine/input"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

GALLERY_START :: mm.Vec3{0,.05,8} // where Mirai starts, and comes back to when it falls

// What the player of the gallery can do where it stands, at the bottom of the screen.
@(step="ui")
gallery_hud :: proc(g:^gui.Gui,players:core.Read(Gallery_Player),gallery:core.Read(Animation_Gallery),panels:core.Read(Gallery_Panel),drivables:core.Read(inp.Drivable)) {
    seat,found:=core.first(players)
    if !found {return}
    ctx:=gui.gui_context(g);if ctx==nil {return}
    player:=core.at(players,0)
    body:=inp.body_of(drivables,seat)
    title,detail,hint:="Animation gallery","Walk up to a station to see what it shows","WASD: move    Space: jump    Mouse: camera    Esc: cursor"
    text:[96]u8
    if body==player.spider && body!=core.NONE {
        title,detail,hint="5.1  Procedural eight leg gait","Its feet find the ground with no clips","WASD: move    Space: jump    E: back to Mirai"
    } else if focus,focused:=core.get(panels,player.focus);focused {
        title,detail=base.text_get(focus.title[:]),"Drag the sliders and press the buttons of the panel"
        hint="E: back to walking"
    } else if item,near:=core.get(gallery,player.near);near {
        title,detail=base.text_get(item.title[:]),base.text_get(item.detail[:])
        adjustable:=false
        for row in 0..<core.count(panels) {if core.at(panels,row).station==player.near {adjustable=true}}
        if adjustable {hint=fmt.bprintf(text[:],"E: adjust    %s",hint)} else if item.kind==.Spider {hint=fmt.bprintf(text[:],"E: drive the spider    %s",hint)}
    }
    if ui.box(ctx,{
        id=ui.id(ctx,"animation.gallery.hud"),
        layout={width=ui.fixed(min(560,ctx.size.x-40)),direction=.Column,padding=ui.padding_all(12),gap=5},
        float={to=.Safe,anchor=.Bottom_Center,pivot=.Bottom_Center,offset={0,-24},layer=1000},
        fill=ctx.theme.panel,stroke=ctx.theme.border,radius=ctx.theme.radius_panel,block=true,
    }) {
        ui.label(ctx,title,size=17,color=ctx.theme.text)
        ui.label(ctx,detail,size=12,color=ctx.theme.text_muted)
        ui.label(ctx,hint,size=11,color=ctx.theme.accent)
    }
}
