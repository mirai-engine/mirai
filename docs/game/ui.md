---
name: ui
description: HUD, main menu, pause, settings screens, world panels and keyboard focus of a Mirai
  game - .ui assets, UI_Screen, World_Widget, UI_Event, Focus_First, Graphics_Settings, options.
---

# Game UI

Imports: `gui "mirai:engine/gui"`, `render "mirai:engine/render"`, `save "mirai:engine/save"`,
`"mirai:ui"` (only in the content tool).

**A new game already has the shell**: `game/shell.odin` (main menu, pause, graphics settings,
Escape, frozen clock, mouse capture, options saved) drawn by `assets/ui/shell.ui`, which
`tools/content` writes. It also has `hud.ui` and `sign.ui`. Restyle and extend them; do not write
another menu system. `tests/scenarios/shell.mirai` drives it with keys.

## Map

- Restyle the menus, add a page, a button or an option, apply and save settings:
  [menus-settings.md](ui/menus-settings.md).
- A HUD, a counter or bar, a sign in the world, a panel on a mesh:
  [hud-panels.md](ui/hud-panels.md).
- Write or change a `.ui` from code or the API: [writing-ui.md](ui/writing-ui.md).
- Check a screen without playing it by hand: [testing](testing.md#ui-and-menus).
- [Screens](#screens), [Events](#events), [Focus](#focus).

## Screens

A screen is an entity with a `UI_Screen`; its `.ui` binds paths to components of that entity or
to storages (`Status.message`, `Shell.page`).

```odin
hud:=gui.UI_Screen{asset=hud_id}                              // Passive: draws, takes no input
menu:=gui.UI_Screen{asset=shell_id,order=10,input=.Modal}     // over the HUD, frees the pointer
```

- `input`: `Passive` (HUD), `Menu` (navigation, keys, actions), `Modal` (as Menu; the seats it
  covers get no actions and the pointer shows). A higher `order` covers a lower one.
- Show or hide a screen with `render.set_hidden(hidden,entity,true)`: it plays its hide
  animations; turning off `UI_Screen` or `core.Disabled` removes it at once.
- `back=true` makes Escape or East report `Back` while it is on top.
- `pause=true` on a `Modal` screen stops the clock while it shows, unless in a network session.
- A free cursor: [Mouse](ui/menus-settings.md#mouse).

## Events

A frame step reads what the widgets asked, once each, also while the clock is stopped:

```odin
@(step="frame")
menu_frame :: proc(g:^gui.Gui, screens:core.Read(Menu_Screen), volumes:^audio.Audio_Volumes) {
    screen:=core.entity_at(screens,0)
    events:=gui.events_this_frame(g)
    if gui.clicked(events,screen,"menu_play") {start_game()}
    if value,ok:=gui.changed_value(events,screen,"volume");ok {volumes.master=f32(value)}
}
```

- Names are `base.name_hash` of the node name. Controls never write their bound value: the game
  writes it on `Changed`, or the control goes back to what the field holds.
- The helpers (`clicked`, `changed`, `changed_value`, `submitted`, `dropped`, `back`,
  `menu_pressed`...) take a frame's `gui.events_this_frame(g)` or a tick's `UI_Events` storage: a
  fixed step reads the storage and sees nothing while the clock is stopped, as under a pause menu.
- `gui.menu_pressed(events)` is the `menu` action (Escape, Start, rebound in `input.mirai` like
  any other) when no interface used that Escape: what opens and closes a menu.

## Focus

Keyboard and gamepad move a ring over the controls. Mark the first control of each page
`flags={.Focus_First}`, so Enter works without the mouse. `Wrap_Y` on a column wraps the focus.
`gui.focus(requests,entity,"node")` (a `gui.UI_Requests` storage) moves it from code.

## Pitfalls that fail silently

- A path that names a component or field the game lacks hides the whole screen; the reason is a
  problem `gui.bind` in `engine.diagnostics`. A `.ui` that does not load is `gui.asset`.
- A screen with no `Focus_First` can be clicked but not driven by keys.
- More screens than fit leave out the lowest `order` (`gui.screens`): hide the unused ones.
- An open editor picks up rewritten `.ui` files at its next call.
