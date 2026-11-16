package spawn_editor

import "mirai:editor"
import spawn "plugins:spawn/runtime"

// Spawn points in Create, and the icon of what has one.
@(storage)
Spawn_Cards :: struct {provider:editor.Card_Provider}

spawn_cards_default :: proc() -> (cards:Spawn_Cards) {
    cards.provider.count=1
    cards.provider.cards[0]={recipe="spawn",group="Logic",icon=.Spawn,color={120,214,140,255},component=spawn.Spawn_Point}
    return
}
