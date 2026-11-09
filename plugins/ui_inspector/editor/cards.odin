package ui_inspector_editor

import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:engine/gui"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// The cards of Create that put interfaces in the scene: one over the screen,
// a panel that keeps its rotation in the world and one that always faces the
// camera. Each shows the .ui chosen in the content browser, if any.

@(storage)
Ui_Cards :: struct {provider:editor.Card_Provider}

ui_cards_default :: proc() -> (cards:Ui_Cards) {
    cards.provider.count=3
    cards.provider.cards[0]={
        label="Interface",group="UI",color={130,190,255,255},lift=0.5,component=gui.UI_Screen,make=screen_make,
        // A screen with a bar and a button.
        drawing=ui.icon_drawing(
            ui.icon_part(.Loop,{{-6.5,-5},{6.5,-5},{6.5,5},{-6.5,5}}),
            ui.icon_part(.Line,{{-4.5,-2.5},{4.5,-2.5}}),
            ui.icon_part(.Fill,{{-1.5,1},{4.5,1},{4.5,3},{-1.5,3}},shade=70),
        ),
    }
    cards.provider.cards[1]={
        label="Panel",group="UI",color={130,190,255,255},lift=1,component=gui.World_Widget,make=panel_make,
        // A panel seen at an angle.
        drawing=ui.icon_drawing(
            ui.icon_part(.Loop,{{-6,-4},{5,-6},{5,4},{-6,6}}),
            ui.icon_part(.Line,{{-3.5,-1.5},{2.5,-2.5}}),
            ui.icon_part(.Line,{{-3.5,1.5},{2.5,0.5}}),
        ),
    }
    cards.provider.cards[2]={
        label="Billboard",group="UI",color={130,190,255,255},lift=1.5,component=gui.World_Widget,make=billboard_make,
        // A panel on a post, facing whoever looks.
        drawing=ui.icon_drawing(
            ui.icon_part(.Loop,{{-6,-6},{6,-6},{6,1},{-6,1}}),
            ui.icon_part(.Line,{{0,1},{0,6.5}}),
            ui.icon_part(.Disc,{{0,-2.5}},radius=1.5,shade=70),
        ),
    }
    return
}

// The .ui chosen in the content browser; none otherwise.
@(private)
chosen_interface :: proc(s:^editor.Session) -> base.Asset_Id {
    if s.content==nil || s.app==nil || s.app.assets==nil {return {}}
    if record,found:=asset.registry_find(&s.app.assets.registry,s.content.selected);found && record.kind==asset.KIND_UI {return record.id}
    return {}
}

@(private)
screen_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,gui.UI_Screen);t!=nil {core.add(t,e,gui.UI_Screen{asset=chosen_interface(s)})}
}

@(private)
panel_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,gui.World_Widget);t!=nil {
        widget:=gui.WORLD_WIDGET_DEFAULT
        widget.asset,widget.facing=chosen_interface(s),.Fixed
        core.add(t,e,widget)
    }
    // It keeps the rotation it starts with: turned to whoever adds it, its
    // forward toward the view.
    if t:=core.world_table_of(w,core.Transform);t!=nil && s.viewport!=nil {
        if placed:=core.get(t,e);placed!=nil {
            toward:=editor.orbit_position(s.viewport.orbit)-placed.position
            toward.y=0
            if toward!={} {placed.rotation=mm.quat_look(toward,{0,1,0})}
        }
    }
}

@(private)
billboard_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,gui.World_Widget);t!=nil {
        widget:=gui.WORLD_WIDGET_DEFAULT
        widget.asset,widget.facing=chosen_interface(s),.Billboard
        core.add(t,e,widget)
    }
}
