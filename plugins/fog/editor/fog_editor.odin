package fog_editor

import "mirai:editor"
import "mirai:ui"
import fog "plugins:fog/runtime"

@(storage)
Fog_Cards :: struct {provider:editor.Card_Provider}

fog_cards_default :: proc() -> (cards:Fog_Cards) {
    // Layers of mist drifting across.
    cards.provider.count=1
    cards.provider.cards[0]={
        recipe="fog",group="Logic",color={200,214,240,255},component=fog.Fog_Volume,
        drawing=ui.icon_drawing(
            ui.icon_part(.Line,{{-6.5,-3.5},{-2.5,-4.6},{1.5,-3.5},{5.5,-4.6}}),
            ui.icon_part(.Line,{{-5.5,0.5},{-1.5,-0.6},{2.5,0.5},{6.5,-0.6}}),
            ui.icon_part(.Line,{{-6.5,4.5},{-2.5,3.4},{1.5,4.5},{5.5,3.4}}),
        ),
    }
    return
}
