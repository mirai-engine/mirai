package shapes_editor

import "mirai:core"
import "mirai:editor"
import "mirai:ui"
import shapes "plugins:shapes/runtime"

// Create makes a Spline: a road or a path drawn with the material it is
// given, or a river with a Fluid. The Corners mode of the Shapes tool moves,
// inserts and removes its points.
@(storage)
Shapes_Cards :: struct {provider:editor.Card_Provider}

shapes_cards_default :: proc() -> (cards:Shapes_Cards) {
    cards.provider.count=1
    cards.provider.cards[0]={
        label="Spline",group="Logic",color={150,190,130,255},component=shapes.Shape,make=spline_make,
        drawing=ui.icon_drawing(
            ui.icon_part(.Line,{{-6.5,5.5},{-2.5,1.5},{1.5,2.5},{6.5,-5.5}}),
        ),
    }
    return
}

@(private)
spline_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,shapes.Shape);t!=nil {core.add(t,e,shapes.SPLINE_DEFAULT)}
}
