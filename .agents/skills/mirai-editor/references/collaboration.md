# Collaboration

Code: `collab.odin`, `collab_api.odin`, `collab_project.odin` (the project that travels) and
`collab_play.odin` (the host's networked games).

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
- Joining **replaces** the guest's scene. Sharing and joining require `Edit`, the store the editor
  started with (`--store`, else the machine's) and no open session (`Busy`); sharing, and joining
  into the open project, a project with an assets folder. `COLLAB_PEERS` editors fit.
- On sharing, the host creates a token and shows its invitation code
  ([invitations](../../mirai-networking/references/networking.md)): the address of its network
  (`address_lan`: the one the system uses toward the internet, not a virtual adapter's), the one
  the router mapped for it ([port mapping](../../mirai-networking/references/port-mapping.md)) and
  the token. Whoever enters without that token gets no answer and times out; the host's log shows
  the code each time it changes.
- The host sees one code in Session, once the router answered: a guest asks at both addresses at
  once, so the same code joins from the host's network and from outside it. A guest's networked
  Play joins the host's game at those same addresses with the game's port and its mapping.
- **Rejoining.** Each editor has an id (`Collab.client`, in the Hello): one that enters again while
  the host holds its previous connection takes its place and its color, and that connection is
  closed with what it had selected. Whoever leaves the session's list retains nothing.
- `collab.join` returns before the scene arrives: query `collab.status` until `Joined`. The phases
  are `Collab_Phase`, with the reason for the end; `Updating` is the guest bringing its folder to
  the host's project ([the project](#the-project)).

## The project

- The session carries the project as `mirai share` and `mirai join` do
  ([sharing a project](../../mirai-projects/references/projects.md#sharing-a-project)), with the
  same node of `cook/share`: the session's net host also carries the channels of the
  [exchange](../../mirai-store/references/exchange.md), at `COLLAB_EXCHANGE_CHANNEL`, so its
  connections move the project and its builds; what a peer sends enters only through the checks
  of `cook/share` and `exchange`.
- **Hosting** takes the snapshot of the project into the editor's store and offers it under the
  session's token, with the builds its packages pin; the whole library of that store is exposed to
  whoever holds the invitation, as in `mirai share`. A lease of the session holds what it serves
  and what it fetches.
- **Joining** first runs the join of `cook/share` (phase `Updating`), and only then says Hello and
  receives the scene. Into the open project (Session > Join, or `collab.join` without `folder`) it
  is the three-way update: a file both changed stays the guest's and is listed as kept, never
  overwritten. Into another `folder` (new, or joined before), once the files and the packages are
  there the editor opens that folder as File > Open project does, and the editor started on it
  joins the session again with the same invitation, which then finds nothing to fetch. A guest
  needs none of the files beforehand.
- Session shows the join's step (files and bytes, rate and time left, the builds) where it shows
  the phase, and after it the files kept, those not written and the packages no connected peer
  has a build of; `join` of `collab.status` gives the same.
- The host's files are those of the snapshot taken when it started sharing: what changes on the
  host afterwards reaches a guest when it joins again. A guest's own imports and file changes do
  not travel to the host as files; the asset files edited in the session travel as below.

## What travels

- **The whole scene**, once on entering: what `scene.capture` writes, as one message over the
  reliable channel. The guest loads it with `scene.replace`: one that does not fit whole leaves its
  world as it was and ends the session. The files it needs arrived before, with
  [the project](#the-project).
- The network half of the session runs in its own thread (`worker_start`): an editor busy for a
  while (generating a game's world, a long frame) keeps responding and nobody gives it up for gone.
- Reliable messages wait in each peer's queue (`Collab_Peer.out`) and stream into the channel as
  it drains (`message_send` with `sent`); the pieces they arrive in are joined in
  `Collab_Peer.incoming`. Collaboration never cuts a message itself: the transport does.
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
- **Prefab instances** have no channel of their own: they are rows of their entities and travel
  as edits, and the prefab an operation wrote travels as the asset file it is. Between
  the two an editor may hold instances of a file it does not have yet: they read as stale and no
  end refreshes them by itself ([overrides](prefabs.md#overrides)).
- **Pings** (`collab_ping.odin`): [figures](editor.md#pings).
- **Asset files** (`collab_files.odin`, one `File` message): what changes an asset file in
  an editor (an agent's material, a painted texture, an undo) travels to the others (`file_changed`,
  `file_set`). The host writes it with its step and forwards it; a guest keeps it in the memory of
  its registry while it is in the session and forgets it when it leaves. To whoever enters, the
  host sends after the scene the files its registry holds and those git lists as changed since
  its last commit, which the checkout of the guest lacks.
- **A file that cannot travel** (larger than `COLLAB_FILE_BYTES`) stays where it was edited and
  every editor is told (`File_Unsent`, `Collab_State.unsent`): a toast when it happens, a line of
  Session while it lasts and `unsent` of `collab.status`, with the file, who changed it and what
  makes it the same for all: committing it and sharing it through the project's repository. It
  leaves the list when it travels or when whoever changed it leaves.
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
- A guest writes nothing: its host writes the document and the asset files
  ([the file is the state](document.md#the-file-is-the-editors-state)).

## Compatibility

- The handshake carries `COLLAB_WIRE`, the version of the messages and of `cook/share`, so a guest
  built from another project still gets the host's files. Its Hello carries the world layout: a
  hash of `COLLAB_VERSION` and of names and sizes of the `World` tables.
- If the layout differs, the host refuses the Hello (`Denied_Version`) and the guest's session
  ends saying to build its editor, whose files are the host's by then, and join again. A guest
  that joins into another folder never meets it: the editor opened there is built from the host's
  files.

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
   (`Play_Scene_Request`) and the host sends its `.mirai/play/play.scene`
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
