# A hitscan weapon

A gun is an entity with an `Ability_User` of its own (its magazine is one of its attributes, so it
keeps its rounds from hand to hand) and an `Ability_Wielded` that names the body holding it:
`abilities.ability_wield(requests,gun,body)`, or authored in the prefab. The seat of that body fires
and aims it while the body runs its own abilities. Its fire is an ability whose window holds a
hitbox of shape `Ray`: a range, a radius, a spread and pellets, from the aim of the seat. A ray
stops at the collider it reaches, then at the hit zone of that entity: a `Hit_Zone_Set` on a rig
names a `Hit_Zones` row (a sphere on `@head` tagged as a head), and a `target_effects` row of the
hitbox with that tag takes more. The hitbox's `kick` turns the look (recoil), a `Self` hitbox
refills the magazine at the end of a reload, and a reload whose `action` names a clip of the gun's
own `Animation` plays it; a `@field/Hidden` track of that clip hides the magazine. `Ability_Events`
`Shot` and `Hit` carry origin, point, normal and zone for tracers, decals and the wall a shot
breaks. With a network, a server judges a shot where the player who fired saw a target with
`multiplayer.Rewind`. The game template holds one as data.
