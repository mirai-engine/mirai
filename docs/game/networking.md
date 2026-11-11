---
name: networking
description: Multiplayer in a Mirai game - replicated entities and components, net messages, seats,
  who decides, `--server`, `--connect`, `--dedicated`, lag compensation. Use for co-op or online.
---

# Game networking

The `multiplayer` plugin does the networking: list it in `plugins` of `project.mirai` and import
`multiplayer "plugins:multiplayer/runtime"`. The game never opens sockets. One build runs alone, as
a server or as a client; the server decides, a client predicts the body it drives.

## Map

- Run server and clients, make an entity or component travel, server-only rules: below.
- Events between ends (an announcement, a purchase), arrivals: [messages](networking/messages.md).
- Seats, bodies of players, who sees what, what a client predicts, predicted spawns, input delay:
  [players](networking/players.md).
- Shots and melee judged where the shooter aimed: [lag](networking/lag-compensation.md).
- Prefabs and scenes carrying `Replicate` are written by [assets](assets.md).

## Run it

```bash
mirai play <project> --server                           # serves and plays
mirai play <project> --connect 127.0.0.1 --new-player   # a client; --new-player: own player
mirai play <project> --connect 127.0.0.1 --latency 60 --loss 2   # --jitter <ms> too
mirai play <project> --server --invite                  # serves only who brings its code
mirai play <project> --connect R2M0-253B-DK5G-0W87-M0MA-3CP3-TKJZ-C1RR-EJT
mirai build server                                      # dedicated build, run with --dedicated
```

Two ways in. **By address**: `--server [port]` serves, and anyone who reaches it joins with
`--connect <address>`. **By invitation**: `--server --invite` serves only who brings its code,
which it prints and `multiplayer.invite_code` gives the game to show; the code carries the host's
address on its network and the one its router mapped, so one `--connect <code>` joins from the
same network and from the internet. Every connection is encrypted either way. `--until-empty` ends
a server with nobody, `--status <file>` logs. `--server` with `--connect` is refused. Settings,
read when the session opens, go in `settings.mirai`:
`{"Net_Settings": {"max_clients": 8}, "Spawn_Settings": {"players": true}}`.

## Replicate

Put the `multiplayer.Replicate` component (with a `Transform`) on the prefab: every entity made
from it exists on the server and on the clients that see it. Its pose travels; so does the
`Move_Input` of a driven body and every component declared `replicated` that it has, also one it
gains later (a status) or loses.

```odin
@(component,replicated)                    // replicated="owner" or "others" narrows who gets it
Health :: struct {
    hp:f32 `mirai:"min=0,max=100,precision=0.5"`,   // tags choose the wire precision
    flash:u32 `mirai:"local"`,                       // local fields stay on each end
}
```

A client makes each replica from the prefab the server spawned it from: same assets on both ends.

## Decide on the server

```odin
@(step="fixed",server)       // runs on the server or alone, never on a client
game_damage :: proc(players:core.Read(Player),actions:inp.Input_Of(Action)) { ... }
```

Where one function runs on every end, ask before deciding: `network:core.Ref(core.Network)` and
`network.role` (`.Standalone`, `.Server`, `.Client`), or `core.owned(remotes,e)` with
`remotes:core.Read(core.Remote)`.

## Pitfalls that fail silently

- State outside the world (package variables, host storages) is not rolled back on a correction;
  keep game state in components and storages.
- A client's change to what the server simulates is overwritten; send a message for the server.
- `net.*` problems (`engine.diagnostics`) explain what was not replicated: no `Transform`, more
  entities than `max_objects` (the client needs as many as the server), a type that is not a
  `net_message`.
- A client cannot save, spawn bodies or change scene: the server does, clients follow.
- A different build of the game is rejected on connecting.
