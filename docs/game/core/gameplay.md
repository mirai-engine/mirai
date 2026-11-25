---
name: gameplay
description: Named entity tags, interaction (focus, use and hold of targets) and debug drawing.
---

# Gameplay helpers

Waits (cooldowns, countdowns) are fields of your components: [waiting.md](waiting.md).

## Tags

`scene.Tags` says what kinds of things an entity is (a player, a structure, an enemy class), for
rules that match kinds: the `target_tags` of an ability effect, a game's own checks. Declare each
tag once as a constant and use the constant in code; data, the inspector and the API show its
name (`TAG_PLAYER` is `player`). Up to `scene.TAG_LIMIT` (64) tags.

```odin
TAG_PLAYER :: scene.Tag(0)
TAG_STRUCTURE :: scene.Tag(1)

if scene.tag_has(tags,TAG_STRUCTURE) {...}
```

`scene.tag_set` and `scene.tag_clear` change one tag (false past the limit); `scene.tag_has_all`
and `scene.tag_has_any` match a set (`scene.Tags{bits=1<<TAG_PLAYER}`). The tags of an ability row
(`Ability_Tag`) and its statuses are other data of the `abilities` plugin.

## Interaction

A target the player uses where it stands (a door, a lever, a shop) is a `scene.Interactable`; the
body that uses it is a `scene.Interactor` that names the action of the game that uses
(`action:"use"`). The engine reads that action from the seat that drives the body, on every end,
with no call from the game.

- **Focus:** of the targets within `reach` of the body, the highest `priority`, then the nearest,
  then the lowest entity. `Look` mode keeps it inside a cone of `look_angle` around where the
  player aims (`inp.aim`), or where the body faces without a player. `sight` needs a clear line
  from the eye: what physics says is in the way hides it (without physics nothing does).
- **Use:** a press starts a hold of `hold_seconds` (0: the press uses it), its end completes it,
  letting go or losing the focus cancels it, and a new press starts it again.
- **Results:** `core.Ref(scene.Interaction_Events)` gives `Focused`, `Unfocused`, `Started`,
  `Cancelled` and `Completed` with the actor and the target: a `server` step acts on `Completed`.
  The derived `scene.Interaction_State` holds the focused `target` and its `hold`, written only
  when they change; `scene.interaction_progress(state,time)` gives the hold 0 to 1 for a bar.
- **Prompt:** the HUD is the game's. Show what the focused target offers from its own components
  (a name, a price) and the binding of the action; the engine keeps no prompt text.

The `templates/game` wall is an example: hold `E` at it to shatter it (`game_shatter`), and the HUD
says so (`game_prompt`).

## Debug drawing

Receive `^render.Debug_Draw` from `mirai:engine/render` in a step of any package and submit a
world-space primitive, for example `render.debug_line(draw, from, to, {1,1,0,1})`: it is a request
queue the render step takes. Lines, rays, boxes, spheres, arrows and crosses share the renderer's
depth-tested debug line pass. A primitive draws once by default. Pass `duration` in frame seconds
to keep it visible longer. A fixed tick that runs again (a network correction, a replay of the
history) does not submit its primitives again. The request returns false if the bounded queue is
full or the duration is invalid.

A direction that belongs to an entity (where a sun shines, where a spawn point faces) is an
`render.Arrow` component instead: a solid arrow the editor always shows and the game draws only
with `in_game` on.
