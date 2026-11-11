package ui_inspector_editor

import "mirai:editor"
import "mirai:engine/gui"
import "mirai:ui"

// The cards of Create that put interfaces in the scene: one over the screen,
// a panel that keeps its rotation in the world and one that always faces the
// camera. Each shows the .ui chosen in the content browser, if any.

@(storage)
Ui_Cards :: struct {provider:editor.Card_Provider}

ui_cards_default :: proc() -> (cards:Ui_Cards) {
    cards.provider.count=3
    cards.provider.cards[0]={
        recipe="interface",group="UI",color={130,190,255,255},component=gui.UI_Screen,chosen=true,
        // A screen with a bar and a button.
        drawing=ui.icon_drawing(
            ui.icon_part(.Loop,{{-6.5,-5},{6.5,-5},{6.5,5},{-6.5,5}}),
            ui.icon_part(.Line,{{-4.5,-2.5},{4.5,-2.5}}),
            ui.icon_part(.Fill,{{-1.5,1},{4.5,1},{4.5,3},{-1.5,3}},shade=70),
        ),
    }
    cards.provider.cards[1]={
        recipe="panel",group="UI",color={130,190,255,255},component=gui.World_Widget,chosen=true,facing=true,
        // A panel seen at an angle.
        drawing=ui.icon_drawing(
            ui.icon_part(.Loop,{{-6,-4},{5,-6},{5,4},{-6,6}}),
            ui.icon_part(.Line,{{-3.5,-1.5},{2.5,-2.5}}),
            ui.icon_part(.Line,{{-3.5,1.5},{2.5,0.5}}),
        ),
    }
    cards.provider.cards[2]={
        recipe="billboard",group="UI",color={130,190,255,255},component=gui.World_Widget,chosen=true,
        // A panel on a post, facing whoever looks.
        drawing=ui.icon_drawing(
            ui.icon_part(.Loop,{{-6,-6},{6,-6},{6,1},{-6,1}}),
            ui.icon_part(.Line,{{0,1},{0,6.5}}),
            ui.icon_part(.Disc,{{0,-2.5}},radius=1.5,shade=70),
        ),
    }
    return
}
