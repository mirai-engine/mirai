---
name: gameplay
description: Entity tags, fixed-tick timers, interaction, and debug drawing.
---

# Gameplay helpers

## Tags and deadlines

Add `scene.Tags` to classify an entity. Define tag indices in game code and use `scene.tag_set`
and `scene.tag_clear` to edit membership. Query one bit with `scene.tag_has`, or match a mask with
`scene.tag_has_all` or `scene.tag_has_any`.

Add `scene.Cooldowns` for a wait that is ready by default, or `scene.Timers` for a wait with an
explicit start and elapsed time. Name the slots in game code. Start a wait with the `core.Time`
of the fixed step. Read the remaining or elapsed time when needed. Each component holds ticks,
so a copied world resumes the same waits and a steady tick has no countdown writes.

## Interaction

Give the driven body `cam.Interactor` and targets `cam.Interactable`. Set reach and choose
proximity or a look cone. Look mode uses the body's selected camera, with its transform as
the fallback. Reach is measured from the body. Higher priority wins, then shorter distance,
then entity order. Use the target's prompt for its focused HUD.

In an intent step, call `cam.interaction_use(requests, body, pressed)` on each tick the use
action is held. Pass the action's pressed edge in `pressed`. Releasing use or losing focus
cancels an incomplete hold. A completed hold needs another press to start again. A react step
can read `core.Ref(cam.Interaction_Events)` and handle `.Completed` for the target. Read the
derived `cam.Interaction_State` for focus, availability and hold progress.

## Debug drawing

Receive `^render.Debug_Draw` from `mirai:engine/render` in a step and submit a world-space
primitive, for example `render.debug_line(draw, from, to, {1,1,0,1})`. Lines, rays, boxes,
spheres, arrows and crosses share the renderer's depth-tested debug line pass. A primitive
draws once by default. Pass `duration` in frame seconds to keep it visible longer. The request
returns false if the bounded queue is full or the duration is invalid.

A direction that belongs to an entity (where a sun shines, where a spawn point faces) is an
`render.Arrow` component instead: a solid arrow the editor always shows and the game draws only
with `in_game` on.
