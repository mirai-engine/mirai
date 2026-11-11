package shapes_editor

import "mirai:editor"
import "mirai:ui"
import volume "mirai:engine/volume"

// Create places a volume.Spline: a road or a path drawn with the material it
// is given, or a river with a Fluid. The Corners mode of the Shapes tool
// moves, inserts and removes its points.
@(storage)
Shapes_Cards :: struct {provider:editor.Card_Provider}

shapes_cards_default :: proc() -> (cards:Shapes_Cards) {
    cards.provider.count=1
    cards.provider.cards[0]={
        recipe="spline",group="Logic",color={150,190,130,255},component=volume.Spline,
        drawing=ui.icon_drawing(
            ui.icon_part(.Line,{{-6.5,5.5},{-2.5,1.5},{1.5,2.5},{6.5,-5.5}}),
        ),
    }
    return
}
