# Editor part of a plugin

Add `"Editor"` to `parts` and `editor/`, which imports `mirai:editor` and may import `runtime/`;
the game never imports it. An `@(storage)` whose only field is a provider adds Create cards
(also `Inspector_Provider`, `Component_Provider`, `Api_Provider`, `Preferences_Provider`):

```odin
package heal_editor

import "mirai:core"
import "mirai:editor"
import "mirai:ui"
import heal "project:plugins/heal/runtime"

@(storage)
Heal_Cards :: struct {provider:editor.Card_Provider}

heal_cards_default :: proc() -> (cards:Heal_Cards) {
    cards.provider.count = 1
    cards.provider.cards[0] = {label="Healer", group="Logic", color={120,214,140,255},
        component=heal.Health, make=heal_make,
        drawing=ui.icon_drawing(ui.icon_part(.Loop, {{-6,-6},{6,-6},{6,6},{-6,6}}))}
    return
}

heal_make :: proc(s:^editor.Session, w:core.World_Ref, e:core.Entity) {
    if t := core.world_table_of(w, heal.Health); t != nil {core.add(t, e, heal.Health{hp=10})}
}
```

Editor steps run in the `editor` loop and take what they use (`^editor.Session`, `^host.Assets`,
`^host.Frame_Extras`, `^host.App` for the application itself).
A tool is `editor.tool_entry` in the register procedure of the API methods (its entry in the Tools
menu and its key) plus `editor.tool_on` in its steps; a method a person runs too carries its menu
entry and shortcut in the `entry` of its `editor.api_method_register`.
