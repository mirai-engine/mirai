# Collaboration

Code: `collab.odin`, `collab_api.odin` and `collab_play.odin` (the host's networked games).

- Several editors share one's scene. The **host** owns the file and orders the edits; a **guest**
  receives the whole scene on entering and keeps its copy in memory.
- It is edit collaboration: each editor plays its own copy, or joins the host's networked game
  ([where each one plays](#where-each-one-plays)). It uses only the `net` transport (`mirai:net`),
  which belongs to the engine, not the `multiplayer` plugin's game network: collaborating does not
  depend on the project's plugins.

## Entering and leaving

- A scene is shared with `--share [port]`, Session > Host or `collab.host`, and entered with
  `--join <invitation>`, Session > Join or `collab.join`, with the host's invitation code. The name
  comes from `--name`, the Name field of Session or `name` of the API. It is left with Session >
  Stop (host) or Leave (guest), or `collab.leave`, and the scene stays as it is.
- Joining **replaces** the guest's scene: with unsaved changes it fails with `Dirty` unless
  `discard`, and `--join` enters with `discard`. Sharing and joining require `Edit`, a project with
  an assets folder and no open session (`Busy`). `COLLAB_PEERS` editors fit.
- On sharing, the host creates a token and shows its invitation code
  ([invitations](../../mirai-networking/references/networking.md)): the address the router mapped
  for it ([port mapping](../../mirai-networking/references/port-mapping.md)) or, without a mapping,
  that of its network (`address_lan`: the one the system uses toward the internet, not a virtual
  adapter's), and the token. Whoever enters without that token is rejected; the host's log shows
  the code each time it changes.
- The host sees two codes in Session: **Same network**, with its address on the network, and
  **Internet**, with the one the router opened (`collab_internet_code`). From the host's network
  one enters with the network one: the internet one depends on the router returning the traffic to
  its network (hairpin), and if it does not respond the reason suggests it.
- **Rejoining.** Each editor has an id (`Collab.client`, in the Hello): one that enters again while
  the host holds its previous connection takes its place and its color, and that connection is
  closed with what it had selected. Whoever leaves the session's list retains nothing.
- `collab.join` returns before the scene arrives: query `collab.status` until `Joined`. The phases
  are `Collab_Phase`, with the reason for the end.

## What travels

- **The whole scene**, once on entering: what `scene.capture` writes, with the prefab records, in
  chunks over the reliable channel. The guest loads it with `scene.replace`: one that does not fit
  whole leaves its world as it was and ends the session. Assets do not travel, except the unsaved
  ones: both editors must have the same files.
- The network half of the session runs in its own thread (`worker_start`): an editor busy for a
  while (generating a game's world, a long frame) keeps responding and nobody gives it up for gone.
- Reliable data waits in each peer's queue (`Collab_Peer.out`) and enters the channel as long as it
  fits (`message_send` returns `Full`): a scene larger than the queue takes longer, it does not
  cut the connection.
- **The differences**, every `COLLAB_EDIT_INTERVAL`: per component and entity, identified by
  `core.Id`, the fields of each row that changed (`core.Entity` fields as `Id`), the whole row when
  the others have none, whether it was turned off or on by itself and the `Id`s of the rows that
  left. Only the tables a scene stores. An entity reborn with its `Id` (a prefab operation replaces
  the world) does not leave: the rows of its previous handle do not delete it.
- **By field.** A field is what `saved_fields` lists of the component: each non-`transient` field,
  those of a nested struct one by one, an array whole. Whoever receives a difference writes those
  fields and leaves the rest of the row as it has it, so two editors that change different fields
  of one component of one entity both keep their change.
- They come out of the [document's journal](document.md#edits-and-undo), without a copy of the
  world: the rows the journal took since the previous read (commits, undo, redo), with what they
  held before and the `Id` of an entity that is no longer there; those the world and the journal
  do not share yet (an open gesture travels live); and those that were counted that way in the
  previous send (`Collab_State.told`, with what was told of them), so that a cancellation also
  travels. Each is compared with what the others have of it and only what differs goes; the off
  state travels when it differs from the one the others have.
- **Presence**, every 1/12 s over the unreliable channel: camera, up to 16 selection ids (in Edit
  only), whether it is in a Play or Simulate of its own, whether it plays the host's game and, if
  it serves a networked game, what its plugin offers of it (`Play_Provider.offer`).
- The other editors are drawn as the agents' [figure](editor.md#figures-of-whoever-works), in their
  color: the eyes at their camera and turned toward where it looks, with their initial and their
  name. They are forgotten after 3 s without data.
- Whoever is in their own Play or Simulate also carries a ring under the figure and shows no
  selection; whoever plays the host's game, the ring in the host's color.
- **Selecting holds nothing.** What another editor selected is outlined in their color
  (`collab_highlights`), also over the selection of whoever looks, and that is all: every editor
  and every agent edits it like the rest.
- **Each editor's agents** (`collab_agents.odin`, `Agents` message, reliable): figure, color,
  glyph, name and what the turn changed while awaiting review (up to `COLLAB_AGENT_IDS`). Each
  editor sends its own on changing and every so often while it has any, so whoever enters later
  sees them, and the host forwards them. The others draw the figure and outline what changed; the
  chat stays with whoever launched it.
- **Prefab records** (`collab_prefabs.odin`, `Prefab` message in chunks): when an editor's history
  crosses a `Prefab_Version` (placing, creating, applying, reverting, unlinking, refreshing or
  duplicating an instance, and its undo or redo), what it removed and put of instances, members and
  overrides and the prefab files it wrote go out after the rows of that update. Like the rows, the
  host applies them and forwards them to all, sender included; whoever receives them writes the
  file if it differs, rereads the prefab and observes the overrides again.
- **Pings** (`collab_ping.odin`): [figures](editor.md#pings).
- **Asset files** (`collab_files.odin`, `File` message in chunks): what changes an asset file in
  an editor (an agent's material, a painted texture, an undo) travels to the others and stays in the
  memory of their registry, unsaved, as where it was edited (`file_changed`, `file_set`). The host
  forwards it and, to whoever enters, sends its unsaved files after the scene.
- **A file that cannot travel** (larger than `COLLAB_FILE_BYTES`) stays where it was edited and
  every editor is told (`File_Unsent`, `Collab_State.unsent`): a toast when it happens, a line of
  Session while it lasts and `unsent` of `collab.status`, with the file, who changed it and what
  makes it the same for all: saving it and sharing it through the project's repository. It leaves
  the list when it travels or when whoever changed it leaves.
- Bar avatars in [panels](panels.md#layout).

Edits:

- Playing does not cut collaboration: Play and Simulate run on a copy, so the differences come
  from the document and those of others are applied while someone plays. If the host replaces the
  scene, the run of whoever receives it stops ([Play](editor.md#play)).
- A guest sends its edits to the host, which applies them and forwards them to all, sender
  included: all converge to the host's order, which decides a field two editors changed. Before
  applying what arrives, each editor sends its own. What was applied is taken by the journal field
  by field, without a step or reader: it does not come back as its own.
- A guest already has what comes back of its own edits, or something newer, and skips it; except in
  the rows another editor wrote while they were on their way (`Collab_State.crossed`), where the
  host put its edit after theirs: there it writes it again, but for the fields it is editing now.
- The edits of others do not enter the history of whoever receives them, nor in a gesture it had
  open: the step of that gesture holds its own fields. Each editor's undo undoes its own steps and
  keeps what the others wrote afterwards, also in the field it wrote
  ([undo by author](document.md#undo-by-author)); what it changes travels like any edit.
- The host marks the document with unsaved changes and only it writes the file.

## Compatibility

- The handshake carries the world layout version: a hash of `COLLAB_VERSION` (that of the
  messages) and of names and sizes of the `World` tables.
- If it differs, the host rejects the guest (`Denied_Version`: "has another version of the
  project"). Both editors must be generated and compiled from the same project and engine.

## When the host changes scene

If the host replaces its document (open, new scene), it sends the new scene to the guests; if a
guest replaces its own, its session ends.

## The host's networked games

While the host shares its scene, its Play always serves the networked game
([networked Play](../../mirai-networking/references/multiplayer.md#networked-play)), even without
online players. How a guest joins:

1. On starting the game, the host first sends what it edited and then a mark (`Play_Mark`, with the
   game's number) in the ordered stream of edits.
2. A guest that processes the mark with nothing of its own pending confirmation (its `Edit` messages
   already returned, nothing unsent from the journal, `collab_unsent`, nor an open gesture or
   preview) has the server's scene and copies it to `.mirai/play/host.scene`.
3. If it could not, or entered the session after the mark, on joining it requests it
   (`Play_Scene_Request`) and the host sends it in chunks its `.mirai/play/play.scene`
   (`Play_Scene`), if the game continues.
4. The guest's player connects to the session's address with the server's port; from outside the
   host's network, with the one its router mapped, and waits (`Waiting`) while the router has not
   yet responded. If the host stops serving, the guest's game ends.

## Where each one plays

- Each editor plays its own copy: a Play or Simulate is a world of its own, which neither travels
  nor changes anyone's, and nobody else sees it. Edits keep traveling while it plays.
- A guest joins the host's game with **Join game** of its figure's menu or `play.join`, as a
  `multiplayer` client with its own seat and its prediction, and leaves with **Leave game**, Esc or
  Stop. Joining starts from Edit.
- The bar marks each other editor according to where it plays: the network icon in its color if it
  serves a game, in the host's color if it plays the host's, and Play if it plays alone. The header
  of its menu says so (`serves a game`, `plays the game of …`, `plays alone`); `collab.status`
  gives it in `playing`, `serving` and `in_game`.

## Limits

- An editor that restarts for a Build loses the session.
- Only the host's networked game is joined, and a game is seen by whoever plays it: the Play of
  another editor is not shown.
- `collab.status` and the `collab` summary of `engine.status` report role, phase, editors and
  counters.
