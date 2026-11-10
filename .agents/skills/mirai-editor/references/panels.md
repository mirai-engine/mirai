# Interface, viewport and tools

- The whole UI is built with `ui` in a single `ui.Context` per frame (`Editor_Ui.ctx`);
  `shell_build` (in `editor_panels`) builds bars and panels, and the viewport is the scene drawn
  underneath.
- Notices: a one-line toast (`notify`) or the console. The descriptions of components and fields
  are in the [inspector](inspector.md#descriptions); the prefab action icons say their name on
  hover.

## Layout

- The scene is drawn only below the top bar and beside the rail and the left panel (`App.scene`,
  `dock_scene_left`), in Edit, Simulate and Play: what they always cover consumes no GPU. The left
  panel never moves the image: the viewport (`Viewport.origin`, `size`, `dock_widths`) is the whole
  view, also under the panel, and takes the pointer and projects there, and `App.scene_shift` keeps
  the center of that view in the part drawn, without moving the camera. The bar's edge falls on
  a whole pixel at any scale (`bars_snap`).
- During Play the game UI's safe area reserves the height of the bar: a HUD anchored to
  `Float_To.Safe` stays below them.
- `Shell_Rects` keeps the rectangles of the last frame; `free_region(g, size)` gives the part of
  the window free for the scene, discounting the plugin panels.

**Top bar** (one row of 44 points, drags the window between its controls). In order: the mark and
the word Mirai as one button that opens what the File menu had, View (without the run actions; at
the end, Keyboard shortcuts), the scene or prefab tabs and then those of assets
([tabs](document.md#tabs)), which take the width left over and scroll, and the toolbar. Outside
macOS the window controls are attached to the top right corner, so a pointer taken to the corner
lands on Close. In a narrow window the bar drops its dividers and some labels (`BAR_WIDE`,
`BAR_ROOMY`). The toolbar:

- It carries save, undo and redo, Move/Rotate/Scale, the snap magnet, World/Local, camera speed and
  the **Tools** menu, and avatars, Find, inspection mode, Graphics, Session and run at the end; in
  Play avatars, Graphics and run remain.
- **Tools** (`tools_menu_build`) gathers the plugins' tools and the
  [project panels](#project-panels), and does not appear without any. What is chosen takes
  the place of Details.
- The run arrow chooses Play or Simulate and the local players; with `multiplayer`, how they are
  distributed and the ping ([networked Play](editor.md#networked-play)). During a run: Pause and
  Stop, and in Simulate Apply transforms. Advancing one tick at a time is API-only (`play.step`).
- `Graphics_Settings.show_fps` shows the counter next to the Graphics button, only where that
  button is; in the standalone game it goes at the top right.
- A prefab document omits scene graphics and offers its variants and Preview sunlight
  ([prefabs](prefabs.md#prefab-document)); it runs as any scene.
- There is one avatar per agent working in the document and per other editor of the session, with
  the glyph and color of its [figure](editor.md#figures-of-whoever-works); a click opens its menu.
  While watching, the bar says "Watching", hides the edit tools and shows Stop.

**Rail and left panel:** the rail (44 points, under the bar, colored like it) has the tabs Editor,
Content Browser (the startup one), Hierarchy, World ([world](#world)), AI and Source control as
icons. A click on the one shown folds the panel, on another shows that one. The panel is fixed at
the side of the rail, the height of the window, 320 points wide and with its right corners rounded;
the scene runs 16 points under it, so those corners show the scene (with the panel folded it starts
at the rail). It folds like Tab in Edit; with the chat folded, the AI action of View shows it again,
and in Play it stays minimized; the chat opens only in the pause, where the rail holds only it
([Play](editor.md#play)). **Hierarchy**
shows the outliner or, with an asset document in front, the hierarchy its plugin provides
(`Asset_Document_Provider.hierarchy`). Each document type has its tabs (`DOCUMENT_LIBRARY_TABS`): a
scene all, a prefab all but World, an asset document Content, AI and Git (and Hierarchy if its
plugin builds it). If the chosen one is not there, the first that is shown (`library_tab_shown`) and
the choice is kept for the other documents.

**Details** (right panel) is seen with a selection, or if the walkthrough of a review shows a
deleted entity ([review](ai-review.md#finish-revert-and-retry)), and in a wide enough window. An
active plugin tool or an open project panel take its place (`tool_panel_shown`), without a close
button; Escape closes the panel, or turns off the tool without a selection, and Details returns. A
panel also closes on changing the selection.

**Floating or Docked.** Details floats over the scene (Floating, 8 points from the right and under
the bar, as high as its content) or is docked (Docked) to its window edge, full height under the
bar, and the scene is drawn beside it (`dock_widths`, `App.scene` and `Viewport.origin`): what it
covers consumes no GPU.

- The mode is a machine preference (`Layout`), global and with the own choice of each document
  type (Scene, Prefab) or Global; it is edited in the Editor category of
  [Settings](#project-settings). The global mode is Floating by default.
- Docked, its inner edge is dragged to widen or narrow it, between `DOCK_MIN` and 40 % of the
  window; the width is kept.
- A docked Details stays even without a selection, so the scene does not change size with it, and
  the tool or project panel that takes its place is also docked. An asset document draws its own
  right side.
- In a Play and while a Details field waits for an entity to be chosen in the scene the panels are
  not there, and the scene takes the window.

Other panels:

- On startup Content Browser is shown. Every tab has the height of the window under the bar: the
  panel does not change size when the tab changes.
- Cards: 32-point icons in 40 squares, four columns; with names, 10-point labels and rows of 62.
- Only the tabs with controls of their own have a slim row at the top of the panel: the
  presentation gear of Editor and the chat buttons and settings of AI. Content Browser draws its
  own in its search row. All are `ui` menus: a chosen item closes them.
- **Hierarchy** (list icon, also Hierarchy in View) shows the scene's outliner; with an asset
  document in front, the hierarchy its plugin builds in `hierarchy_room`
  (`Asset_Document_Provider.hierarchy`), or that the document has none.

**Drag** (`Drag`: a Create card, an asset or an entity): `drag_dropped(g, rect)` and `drag_over`
say whether it ends or passes over a rectangle; over the scene it places where the pointer points
(`viewport_drop`).

## AI panel

Logic in [chats and agents](ai-tasks.md); review in [change review](ai-review.md). The panel is the
**main chat** of the project: one continuous thread, with no sessions to open or pick. What an
agent does in parallel shows around it.

- **The bar of the editor** has, at its right, the avatars of the agents (`watch_bar_build`): the
  main agent always, with the dot while it works, then each subagent that works or waits for an
  answer, and each finished one with changes to accept or reject, with a badge (`!` a permission,
  `?` a question, or how many changes wait). A click on the main one opens the chat and on a
  subagent inspects it; a right click opens its menu
  ([figures](editor.md#figures-of-whoever-works)).
- **The bar of the panel** carries the clock, the expand button (four corners) and the gear.
  - The clock opens a popup with a search over the main chat and, under **Finished agents**, the
    subagents that ended, the latest first, each with how long ago it moved and how it ended; a
    click inspects one. A hit of the search brings its line into sight, and one the thread no
    longer holds opens read only with the messages around it.
  - The gear has **Agents** (the model and effort of the main chat, and what subagents run with:
    same, fixed or the agent picks, [subagents](ai-tasks.md#subagents)), **Memory** (the project's
    index, its topics and the user's file, each with Edit in a dialog whose Save writes the file),
    Connections and Show agents in scene.
- With nothing sent yet only the composer waits, in the middle of the panel under the mark of
  Mirai in gray (`ai_chat_empty_build`, `User_Icon.Mirai_Shape`). The first message takes it down
  to its place in `AI_COMPOSER_DROP`, easing out. The thread keeps `AI_THREAD_MARGIN` from the
  sides of the panel.
- **The status line** under the bar of the panel says what the agents do in one line (`2 agents
  working · 4 changes to review`) and appears only while something works or waits for review. It
  unfolds into one row per unit: the color of its agent, its glyph, its title and what it waits
  for (the badge) or the dot while it works; a click inspects it. The main chat is not a row.
- **Report cards.** A subagent that ends a turn leaves a card in the thread: its title and how it
  ended, its answer as answers are drawn and one row: **N changes** unfolding its review and, at
  its end, **Reply**, which attaches that unit to the next message as a chip, then revert and
  accept. Only the latest report of each subagent is a card; the earlier ones are a line. A click
  on the title inspects it.
- **Subagent view.** Inspecting one replaces the thread with its own: a way back to the main chat
  with its model and effort, its title with its state, which opens its details, and its review
  over a composer that writes to it (`Message <title>...`; no model selector, context window,
  Annotate or image buttons). Everything else keeps being about the main chat.
- **Expanded chat.** The corners button makes the chat the whole area below the bars, in a column
  in the middle, with the rail still at the left and, at the right, a column of the units that
  work (a click inspects) and those that wait for review, kept or put back from there; the
  status line gives way to that column. Details, the docks and the bottom panel are not drawn, and
  the pins of annotations are not shown. The clock and the gear stay at the top right.
- Of the agent the last message of each turn is shown (the output after its last call), errors,
  cancellation and how the review ended (`Reviewed · N kept · M reverted`); not the intermediate
  ACP messages. A turn started by the editor to take deliveries has no line of the user. The
  steps of a finished turn (API calls and the agent's own tools, each with its icon; `finish` is
  not a step) are folded under `Worked for 1m 05s · N steps`, with the time its notes give. While
  it runs, a line says `Working for` with the turn's time and the tool in progress, its last step
  or its last text. A divider marks a new context of the chat (editor reopened) and a note a
  compaction.
- The consecutive lines of an answer, or of a user message, are a single message that measures and
  draws its first line; adding or growing a line measures the whole message again
  (`ai_transcript_touch`). Answers are Markdown (`ui.markdown`): a code block can occupy several
  lines of the transcript.
- The entities the agent names are pills with their current name that select them, and the assets
  pills that open their document: they are the `entity:` and `asset:` links of the Markdown.
- Far from the end of the thread, a button over its bottom edge returns to it and follows it again.
- Below the last message go the turn's plan (one step per row: done, the running one in the agent's
  color, the pending ones), what it does now, the permission it asks and the question.
- A permission is answered in the thread, with the agent's official options: it is not a dialog,
  and if its session is not in view a toast warns. A `finish` question shows its options under the
  answer, always with `Other...`, and the choice is sent as the next message.
- Each line of the thread is measured once per width and only the visible ones are built.
- The review of the unit shown sits over the composer: folded, how many changes remain with
  **Revert all** and **Accept all** (Finish); unfolded, one row per change
  ([review](ai-review.md#finish-revert-and-retry)). Accept all, like **Enter with an empty
  composer**, confirms and keeps the chat. A failed turn that left changes remains reviewable;
  Build appears as a button when sources changed. These actions belong to the unit's last turn,
  and Retry is API-only.
- **Composer.** Enter sends and Shift+Enter adds a line. While the agent works Enter does not
  interrupt: the message goes into the thread at once and joins the turn
  ([steering](ai-tasks.md#chat-flow)); one that could not join is drawn with a dashed outline until
  it reaches the agent. The button is Stop only with nothing written. The selection goes in chips,
  and removing one deselects the entity. The capture is taken on sending, without frame or
  announcement.
  - The model selector is quiet: the monochrome mark of its agent, the model name in muted text and
    the effort fainter, without a chevron, and the same menu. Choosing one of another agent changes
    the main chat's agent with its next turn.
  - A chip that can be pinned carries a thumbtack; a pinned one stays over the composer across
    messages ([pins](ai-tasks.md#pins-annotations-and-provenance)).
  - Beside the image button are the Annotate button and, if the agent reports it, the percentage of
    the context window used: it opens a popup with the tokens used of the window, a bar and
    **Compact now** ([compaction](ai-tasks.md#compaction-and-handoff)).
- **Annotations.** The Annotate tool (the Tools menu and the composer's button) turns clicks on the
  scene into numbered pins, each opening a note with an optional group and a remove button; a pin
  left without a note goes away. The pins are drawn over the viewport while the chat is open or the
  tool is on, in Edit, and a group goes with the next message as a chip. They live in the
  database, never in the scene.
- **Provenance.** Details of a single entity, and those of the asset documents that show them,
  carry one faint row at the top naming the unit that last changed it and how long ago; a click
  opens its view at that turn.
- **Content Browser marks.** An asset that a unit changed and that waits for review carries a dot
  in the color of its agent, and its tooltip adds the unit's title.

Figures and outlines: [agents in scene](ai-tasks.md#agents-in-scene-and-review).

## Viewport

The camera is an orbit (`Orbit`); `editor_tools` writes the `core.View` of the shown world and a
Play with its own camera uses its own.

- Right button looks and with W A S D Q E flies; middle button pans; wheel, zoom; a wheel click
  without dragging is a [ping](editor.md#pings). Left click: the gizmo if over a handle; otherwise,
  it selects, and dragging on empty selects by rectangle. F focuses the selection and what hangs
  from it.
- A right click that did not turn the camera (nor moved the mouse, nor flew, nor changed the flight
  speed) opens the menu of what is under the pointer (`play_here.odin`): with a selection, **Ask
  agent** first (`ai_ask`: the main chat with its composer focused and the selection as its chips);
  **Play from here** and
  **Play from camera** ([Play from a place](editor.md#play-from-a-place)), and below what its ray
  crosses (`pick_through`, which does not stop at the first body), nearest first and each entity
  once, to select it.
- `Viewport.capture` (`Look`, `Pan`, `Select`, `Gizmo`) says what the pointer retains; while it
  retains, the UI does not receive it. Escape releases it.
- While the rectangle is dragged, the `Highlight` levels anticipate the result without changing
  `Selection`, Details or the AI context. A visible entity enters if its origin or its whole
  projected box is inside. The query is redone only when rectangle, camera, visibility, geometry or
  transforms change; releasing applies it and Escape restores the previous outlines. Inside prefab
  instances: [prefabs](prefabs.md#operations).

Rectangle selection:

- While dragging, the `Highlight` levels anticipate the result without changing `Selection`,
  Details or the AI context.
- A visible entity enters if its origin or its whole projected box is inside; derived geometry
  refers to its authoring owner. Shift or Ctrl keep the previous selection.
- The query is redone only when rectangle, camera, visibility, geometry or transforms change.
  Releasing applies that query; Escape restores the outlines of the previous selection.
- It reuses the per-entity levels and the renderer's common pass.
- Selection inside prefab instances is in [prefabs](prefabs.md#operations).

**Drawing over the scene**, as debug lines (`gpu.Debug_Lines`, 4096 vertices per frame), outside
the `World` (cancelling a drag leaves no trace):

- 1 m grid: 40 lines per side, major every 10; X axis red and Z blue.
- Disks of what has no body (lights, cameras, groups): they are picked with a click and mark the
  highlight level.
- Short arrows from each sun toward where it shines (its -Z). Of the selected light: three circles
  of its `range` (point and rect), the square and an arrow toward the side it shines (rect), and
  the cone of a spot up to `range`: the circle of its edge, eight lines from the light to it and,
  fainter, the circle at 80 % of `angle`, where it starts to fade. A spot's disk carries a stroke
  toward its -Z. Of a selected spatial `Audio_Source`, three circles of its `min_distance`, where
  it starts to drop, and fainter, of its `max_distance`, where it stops dropping; of a `Volume`,
  its box or its sphere. These lines go opaque: they measure one pixel and the scene covers what
  is behind.
- Box of what is dragged (`ghost.odin`), set where it would fall, and that of the entity the Find
  list points to.
- Collaboration avatars.
- Grid and indicators are turned off from View.

**Picking** (`pick.odin`):

- `pick_point` returns entity, distance, position and normal: first the disks (they are drawn on
  top) and then the nearest surface. Without `ghosts` it does not see what is hidden or off, so
  that nothing rests or is painted on a ghost; the selection click, the rectangle and the focus
  pass `ghosts_shown(s)`.
- The ray first tests each mesh's box (the asset's) and enters only those it crosses, through the
  renderer ([`mesh_ray`](../../mirai-rendering/references/ui.md#offscreen-ui)): the mesh as it is
  drawn, posed included, with the renderer's software tree or the one it makes the first time a
  ray reaches the box under hardware tracing, kept until the mesh goes. The editor keeps no
  triangles or trees of its own. Rectangle, focus and boxes use only the box.
- A derived geometry without `Id` selects its first ancestor with `Id` (`entity_author`), with the
  real hit; likewise in rectangle, Select All and focus. The
  [AI context](ai-tasks.md#project-data) groups them by owner.

**Ghosts** (`ghost.odin`): a hidden mesh, or one turned off with its entity, is drawn as an extra
`outline_only` instance of level `GHOST_LEVEL`, which is not part of the scene: it does not light,
cast shadow or enter rays or GI. A component turned off by itself has no ghost. The instances are
rebuilt only when world, hierarchy, hidden or off, highlight or assets change; with nothing hidden
or off the scene is not walked.

**Gizmo** (`gizmo.odin`), of constant size on screen:

- Move and Rotate follow the world or the active entity (`Viewport.space`); Scale, the active
  entity's axes. With several entities it moves the selection's roots and rotates and scales around
  the pivot.
- A drag is a step: each frame computes from the initial values, releasing closes it and Escape
  returns it. Snap has its own activation and increment per mode (`Viewport.snap`, `snap_rotate`,
  `snap_scale`), which the magnet turns off together without forgetting them (`snap_off`): what
  adjusts asks `snapping`. Ctrl forces it during the gesture.
- A parent without size on an axis does not let anything be placed below on that axis.

**Plugin tools:** with `Viewport.plugin_tool` nonzero the gizmo is neither drawn nor acts and the
left click belongs to the tool; W, E and R change `Viewport.tool` without turning it off. It is
left with Select of the Tools menu, with Escape without a selection (with a selection, Escape
first removes it) or with another tool or panel (`tool_leave`). Outline in
[extensions](extensions.md#a-viewport-tool).

### Inspection mode

`view_modes.odin`. Each tab keeps its own by name (`Viewport.view_mode`; empty is `lit`). In the
`render` phase, `view_mode_render` requests it for the window's view of the next frame
(`host.App.inspection`, which is emptied on drawing it); the views to texture stay lit. Play and a
prefab show the lit image, and on returning to Edit the chosen mode returns.

- The menu has a header per group and a submenu per family; Advanced is folded
  (`view_mode_folded`) and what cannot be shown now is dimmed.
- The core modes are `VIEW_MODES`; the render ones are `Debug_View` of the
  [renderer](../../mirai-rendering/references/settings.md#inspection-modes), with their
  availability (`renderer_debug_view_status`).
- **Collision** (in Advanced) belongs to `physics`, which declares it every frame: all layers
  (`collision`) or a category of the code (`collision.<category>`). It draws over the lit image,
  hidden behind the scene, the physics shapes of the shown world in those layers
  (`world_debug_draw`), with color per body type. It rebuilds the lines only when the physics
  (`synced`, `epoch`, tick, teleports) or the layers change, and counts those that do not fit.
  Without ready physics it is not available and without the plugin it does not exist; images
  without UI (`capture` without `ui`, `mirai capture`) carry no lines.
- A plugin adds modes [from its editor step](extensions.md#an-inspection-mode); one that stops
  being declared returns to Lit.
- API: `editor.view_mode.list` and `editor.view_mode.set`.

### Studio light

After the modes, the same menu has Studio light (also in View; action `Studio_Light`,
`Viewport.studio_light`): the scene is seen with the prefabs' studio light (`PREVIEW_SUN` and
`PREVIEW_ENVIRONMENT`, without its floor, which shows the editor grid) instead of its `Sun` and its
`Sky`, to look at a scene without a sky (an open cave alone) and turn it off to see its real
darkness. `studio_lighting` puts it in the renderer after `render_sync`: it is not content, does
not change the world or the history and Play does not see it. On turning it off, the scene
recovers its sun and sky from `Render_Sync`. It is per tab, starts off and is not saved. The
scene's local lights remain and the exposure is the one chosen below.

- API: `editor.view` with `Studio_Light` turns it on and off; `editor.inspect` gives its `checked`.

### Viewport exposure

The same menu ends in Exposure (`Viewport.exposure_source`, `viewport_exposure`):

- **Scene** (default): the exposure of the enabled `Sky`, the one the player sees with a camera
  without `Exposure`.
- **Camera**: the `Exposure` of the camera the viewport looks through (`camera.set` with
  `entity`); dimmed if it has none. Changing scene returns to Scene.
- **Manual**: a fixed EV100 (`Viewport.ev100`); moving its row chooses it.
- API: `camera.set` with `exposure` and `ev100`.

## Outliner

Scene shows as a `Parent` tree the entities with `Transform` or `Name`, in their order and without
the derived nodes without `Id` whose owner is an ancestor. It builds only the visible rows and
rebuilds the tree when entities, parents or authoring identity change.

- Double click renames an entity without a prefab link and selects a linked member; F2 renames any
  from Details.
- Dragging a row onto another reparents it keeping the world pose; below the rows it makes it a
  root. A member of an instance moves only inside it
  ([prefabs](prefabs.md#hierarchy-of-an-instance)).
- **Containers** (`sections.odin`): the root of a prefab instance goes in the color of the prefab
  of the content browser and that of a [section](document.md#sections) in yellow
  (`SECTION_COLOR`; the scene stays orange in the content browser), icon and name in bold, and a
  line of its color descends below its arrow along what it contains.
- The chosen row or the one under the pointer of something contained shows Go to root (that of what
  contains it; from a root, that of its container) and View as tree: the outliner shows only that
  document (`Outliner.scope`), with a bar that returns to the scene, its document and where it is.

## World

The World tab (`world_map.odin`) is the map of the [sections](document.md#sections) of the open
scene; an asset document has none.

- **Map.** Top shows it from above (x and z) and Side from the side, with height upward: a world
  of layers reads as a well. Each section is the outline of its box (`section_box`, the same as the
  viewport's) in the color of what the view shows: active filled with yellow, loaded and off with a
  faint fill, loading with the border dimmed and unloaded in gray. One without a box is a point on
  its entity, and the point of one that the view turned on or off goes in the accent. On top, the
  streaming sources with the radius they ask for and the editor camera as a wedge toward where it
  looks. The focus icon, changing view or document frame everything again.
- **Gestures.** Dragging moves the map; the wheel zooms in and out around the pointer; a click on a
  section, in the map or in the list, travels to it (`section_travel`): the camera frames its box,
  or enters its center if it is larger than `SECTION_TRAVEL_DISTANCE`, and turns it on in the view
  if what requests it does not request it active. Under the pointer its outline and name are
  highlighted.
- **List.** One row per section with the dot of its state (it beats while loading), the GPU bytes
  of its assets, the eye that turns it on or off in the view and, if the view changed it, the arrow
  that returns it to what its reference asks. The section edited in its world goes in the section's
  color and its eye is not used: it stays on. Below, of the chosen one or the one under the
  pointer: entities, meshes and textures its scene uses, the GPU they occupy now and the size of
  its files (`section_cost`, counted again when the world or the assets change, at most every
  `MAP_COST_SECONDS`).
- Turning on, off and traveling belong to the view, not edits: they do not enter undo nor are they
  saved ([section view](document.md#section-view)). The same data and actions are in the API
  (`editor.sections`, `editor.section_view`, `editor.section_travel`).

## Create

- Foldable sections with the editor presets (Logic, Shapes, Cameras) and the
  [plugin cards](extensions.md#create-cards), in the section each names.
- Create is drawn with the pieces of the [content browser](#content-browser): a folder header
  (`content_header`) for each section, with its count, and each preset as a browser asset
  (`create_card`): in its grid, the icon over the thumbnail with the line of its group's color and
  the name below; in List, a row. It follows the browser's mode and size step and **Ctrl+wheel**
  over Create changes both.
- A click on a card, a mesh or a prefab of Assets arms placement: each later click in the scene
  creates a copy where it points and selects it, and the card releases the keyboard: Delete deletes
  what was just placed, not the asset.
- Placement ends with Escape, right click, another press of the same element or on choosing a
  tool.
- Dragging into the scene places a copy and selects it.
- The preview shows real geometry and materials as visual instances of the frame, without entities
  or undo. A prefab is read in an isolated world that is released on extracting its parts.
- Preview and placement use the same bounds to rest the object; what has no body keeps the height
  of its card.
- Edit > Create places in front of the camera, on the ground it looks at. The Spawn card belongs to
  the `spawn` plugin (its `Card_Provider`) and adds its `Spawn_Point` component.
- A `.sound` or a `.sound_set` is placed like the Sound card: an entity with its name, a spatial
  looping `Audio_Source` that plays it and an `Audio_Occlusion`.

## Inspector

Details, its rows by reflection, copy and paste, collision and material are in
[inspector](inspector.md); the section of a particle emitter belongs to the plugin
[vfx](../../mirai-world/references/vfx-editor.md#particle_emitter-section).

## Projects

`editor/projects.odin`. The list has the projects an editor of this machine opened
(`project.Recent_Projects`, in `projects.mirai` of the machine folder, which `mirai edit` also
reads). The screen has a bar with the brand, New project and Open folder, and beside it the list
and the templates, or the form of a new project. In an open project it is a dialog over the editor
(File > Open project...), which Escape or its cross close; in the launcher it is the whole window,
which does not change size so that few projects do not leave a large empty window.

- **Launcher.** `mirai edit` without a project opens the editor of `templates/empty` with
  `--launcher`, which shows only this screen. With **Open the last project at startup**,
  `mirai edit` opens the last project instead.
- **Choosing and opening.** A click chooses the row, with the accent of a chosen editor row; Open,
  at the right of the search, Enter or a double click open it. A row without a folder is neither
  chosen nor opened. The choice is lost if the search hides it, on removing a row or on showing the
  screen again.
- **Opening** compiles the project's editor library in this process, like Build, and starts the
  editor on it with the same arguments. While compiling what it does is seen, with the beating dot
  and Cancel: in the launcher, on the project's row; if it is not in the list (Open folder, a new
  one) or over a project, in a dialog with the steps (the world, then the editor and the shaders at
  once). It appears in the frame it is requested and compilation starts in the next. The launcher
  ends; the editor of a project ends as on exit, asking about what was not saved, and cancelling
  leaves the project unopened. Closed, the process waits for the editor it started, which writes in
  its same terminal: `mirai edit` ends with the last editor.
- **New project**, or a template of the list, shows the form with that template; Create copies it
  (`build.project_create`) and opens it; with Initialize Git repository, the new editor starts with
  `--git-init` and makes the repository.
- Beside it, Plugins is a list with a check per plugin the project can receive: those of the
  engine and the template, on as the template names them and reread on changing it; those of the
  catalog, off; and the added repositories. The automatic ones do not appear: they arrive with
  their dependencies. One that needs another on is marked and fixed, with "needed by". Add plugin
  opens a popup that searches the catalog by name and description, and that with a git address
  offers to add it; choosing turns its row on. Create writes `plugins` of `project.mirai` (the
  template's in its order, then what is on) and, before the build, installs those of the catalog
  and git ([git plugins](../../mirai-plugins/references/plugins.md#git-plugins-and-catalog)).
  Each row carries the plugin's icon
  ([`icon`](../../mirai-projects/references/projects.md#manifests)) or the generic one.
- Each row says the branch of the repository the folder is on (read from `.git`, without running
  git), "No repository" or "Folder not found" with Remove. An editor with a window is first noted
  in the list on opening a project; a `--headless` one does not touch it.
- Each row's square shows the manifest's `thumbnail`, covering it with its center; if it has none
  or it cannot be read, the view that an editor of the project saved of its initial scene
  ([scene previews](#previews)); if neither, the initial of the name. The launcher is another
  process: it reads them from each project's disk with the rows, only on showing the screen or
  removing a row, and puts them in cells of the previews atlas.

## Content browser

The Content Browser tab shows the registry of the assets of the project and its plugins
(`content.odin`).

**Search and filters:**

- **Search** always in view, with the magnifier inside and its x, in one row with the toggle of the
  selection of the viewport, the **+** and the gear. Choosing the tab gives it the keyboard
  (`Content.focus_search`, from `library_select`), as AI gives it to the message, except when Find
  in Content Browser opens it. Escape clears it. What is typed while a card has the keyboard goes to
  the search and does not trigger shortcuts (`content_typing`, which `content_build` and
  `editor_begin` look at): the focused card has the keyboard when the browser was built in the
  previous frame (`Content.card_focus`). With the panel closed or another tab chosen, or after a
  click in the scene or on what does not take the keyboard, letters are shortcuts again.
- It is case-insensitive and matches each word by name, path or the name of a clip. Results of the
  folder shown and what is under it are listed flat, best first (`content_score`), and Enter takes
  the first for placement.
- **Selection of the viewport**: its toggle shows only what the selected entities hold and what
  that uses (`content_selection_read`, `host.entity_asset_ids`), read again when the selection, the
  registry or the document change.
- **Strip** under the search: a bar per family (Prefab, Model, Material, Scene, Plugins), each named
  only in its tooltip. Prefab and Scene are one kind of file told apart by what the registry knows
  of each (`shown_kind`: a scene with one root is shown as a prefab, in its color, with its icon
  and under its filter; [what a prefab is](prefabs.md)); a funnel opens the rest (Texture,
  Animation, Sound, UI) and lights up while one of them is on, and a cross by it, there only
  while a filter is on, clears them and the viewport selection. They combine; none active shows
  everything. Model gathers meshes, fractures and physics caches; Sound, sounds and sound sets;
  Plugins, every kind of a plugin
  ([types of a plugin](extensions.md#asset-types-of-a-plugin)). A part of an import appears in
  its folder when the filters leave out its owner (Model shows the meshes of an imported prefab).
  Skeletons are not listed: the mesh that uses them represents them (`content_listed`).
- What a scene makes of itself (`Asset_Kind.scene_data`: foliage, terrain, navmesh bakes) shows only
  with the Plugins filter or a search. Every kind of a plugin has the same color; each keeps its
  icon. The type of an asset is written nowhere but in a tooltip.
- The zoom beside the strip (and Ctrl+wheel over the list, one notch per step) walks the counts of
  columns and, past the most, the list; with few columns cells carry their names, with more a
  floating preview names the asset under the pointer.

**List** (`content_lines`, `ui.rows_begin`): lines of different heights, of which the visible ones
are built; it is rebuilt when the registry, the filters, the marks or the place change
([registry review](../../mirai-assets/references/formats.md#registry)).

- **The place** (`Content.at`) is a folder or a virtual folder, entered with `content_enter`;
  nothing folds in place. Entering keeps a history (Back, the back button of the mouse,
  `content_back`) and shows a row with the back arrow and a breadcrumb.
- **Layouts** (`Content_Arrangement`, in the gear): **Names** is a continuous wall, with each
  first-level folder's name sticky over what it holds, a thin name on subfolders of at least a full
  row and the smaller ones flowing together, and at the root one row of each virtual folder. A
  name enters its folder and its arrow folds it in place.
  **Tabs** has chips of the first-level folders and rows of those of the chosen one over a grid of
  what it holds and everything under it. **Cards** shows folders as cells of an asset, with Recent
  open at the top of the root. No level is indented.
- **Recent** (what was placed, opened or assigned recently, `content_used`) and **Favorites** belong
  to each user and project (`Content_Marks`, [preferences](#preferences)). **Current scene** is what
  the open scene references, read from the registry transitively and cached by its revision.
- The cover of a folder is a `cover` texture in it, which is not listed (`content_cover`).
- The gear also has **Only unused assets** (what no asset references; scenes never) and **Show
  parts of imports** (`Content_View.show_parts`).
- **Alt+click** on an asset, or Uses / Used by in its menu, opens its relations: the sections of
  what it uses and what uses it (`registry_dependencies`, `registry_dependents`), walked further
  with Alt+click and back with the back row (`Content.trail`).

**Create** (`asset_create.odin`): the **+**, the right click on an empty place or on a folder and
the Create submenu of a card offer Folder, Scene, Material, Particle, Sound set and what a plugin
creates ([extensions](extensions.md#an-asset-document)), in the clicked folder, the card's or
that of the last thing clicked (`Content.place`). They are off outside Edit and while watching.

- Choosing an entry empties search and filters and puts at the top of the list a line with a free
  name to type over; an invalid or taken name warns and leaves the line.
- A folder and a scene are written immediately, like import. The rest is a step of the scene's
  history and stays in memory unsaved, like `material.set` with `path`; what belongs to a plugin
  is written by its plugin in the next frame. What was created opens in its document if its type
  has one.
- Empty folders are seen while nothing filters (`Registry.folders`), except those of a plugin, the
  engine or the editor. `asset.create` does the same.

**Delete** (`asset_delete.odin`): Delete of a card's menu, or Del or Backspace with a focused card
(`content_focused`, which `shortcuts_run` looks at before the entity Delete), opens
`Modal.Delete_Asset` with the asset, its parts and what uses it. Confirming sends it to the trash
(`platform.trash`) immediately, without undo or Save: it is an operation on files, like import.
What uses it keeps the reference and what was unsaved of it is discarded. Assets of a plugin, the
engine or the editor, an open scene or prefab, are not deleted, nor outside Edit; the modal says
why.

**Rename, move and duplicate** (`asset_move.odin`) also change the files immediately, without undo
or Save, and rescan the registry. Identity is the id, so references, Recent, Favorites and open
documents follow the asset; the selection passes to it (`Content.reveal`).

- A card: Rename (F2) puts in its folder the Create line with its name; Duplicate (Ctrl+D); Move to
  lists the project's folders; dropping it on the name, chip or cell of a folder moves it there. The
  shortcuts look at `content_focused`, like Del. A folder: its right click adds Rename, Duplicate
  and Move to to the Create menu.
- The Create line and what is dropped on a folder act after building the lines: their names are
  registry paths that the scan replaces.
- **Parts and imports.** An asset moves with the parts it owns; each keeps its place relative to
  the owner's folder (the one outside it goes to the destination folder), and if one cannot go,
  nothing moves. The link with the source does not change: `Import_Info.source` names the source
  from the project and reimporting finds the outputs by their `Import_Info`
  ([identity](../../mirai-imports/references/imports.md#identity-and-reimport)).
- **Unsaved.** What has changes in memory is neither moved nor renamed, nor is a folder that has
  them: the error asks to save or discard them. The history names the moved files at their new
  path, so that undo and redo write there, and the project's `start_scene` follows its scene.
- **Duplicate** writes beside it, with a free name (`asset_create_path`), what the editor shows,
  also what is unsaved. The asset and its parts receive new ids and what they name between them
  passes to the copies; a copy is not an output of an import (without `owner` outside what was
  copied, without `Import_Info` or `Cooked`). A folder is copied whole: its assets so, its empty
  folders and its other files as they are.
- Rename and move are rejected like delete and also with an invalid or taken name, a folder inside
  itself or the root of the assets; duplicate, only outside Edit, while watching and with assets of
  a plugin, the engine or the editor. The method is `asset.move`.

**Cards:**

- A square thumbnail as wide as its column, with the preview of materials, geometry, textures,
  prefabs, the types of the plugins that provide it (animations, particle effects) and the view of
  the open scenes ([thumbnails](#previews); the other types and never-opened scenes, their icon in
  the color of their type) and a 2-point line below with the color of its type in Unreal 5.8
  (`asset_color`; a mesh with a skeleton, that of Skeletal Mesh: `asset_file_color`). A cell has no
  padding; one point separates two cells. Below, the name in up to two lines, with ellipsis if it
  does not fit, only while the cells are few: a row whose names all fit in one line keeps the space
  of one, and a cut name is seen whole on leaving the pointer over the cell.
- **Selected**: the cell takes `accent_soft`, its thumbnail a violet border (`toggle_on_stroke`) and
  its name goes white and in medium. What placement carries has a light border, the first result of
  a search a muted one; in the list, the row only takes `accent_soft`. The keyboard has its own ring
  around the cell or row the keys reached.
- **Selection**: a click selects a card; Ctrl or Shift+click adds or removes it, without dragging,
  placing or assigning (`Content.picked`; `Content.selected` is the last). A click where there is
  no card, row or folder empties the selection; with Ctrl or Shift it does not.
- The star appears at the top left on hover, and stays on the favorites.
- An asset with unsaved changes carries the prototype's dot (`UNSAVED_COLOR`) at the top right
  ([unsaved assets](document.md#tabs)).
- **Clips of a library:** the card of an `.anim` with clips carries an arrow on the right that
  shows its clips after it, each with the thumbnail of its pose and the play icon in the accent
  while it does not have it. A search finds the library by its clips
  and shows those that match even if folded. The names come from `Content.clips`.
- **Parts of an import** (`content_part`): an asset whose `owner` is another asset of the registry
  does not appear in its folder. What is a part is decided by the importer
  ([rule](../../mirai-imports/references/imports.md#parts),
  [format](../../mirai-assets/references/formats.md#container)); the browser only reads `owner`.
  The owner unfolds its parts in the order of their paths (`Content.parts`), except a prefab. A
  part also appears in its folder while a search finds it, in Recent and Favorites and with Show
  parts of imports; one whose owner is not there is shown as an asset of its own.
- **Variants of a prefab:** the arrow of a `.scene` is only there if it has
  [variants](prefabs.md#variants), and shows them (`Content.variants`, read once per change of the
  registry of the prefabs that nest another).
- It lists the engine's types (`asset.KINDS`) and the plugin ones that a plugin opens as a document
  or draws as a thumbnail (`content_plugin_kinds`: `Asset_Document_Provider`,
  `Thumbnail_Provider`); the other plugin types are edited by the API or by their tool and do not
  appear.
- Selection, filters, the place and the scroll are kept on changing tabs; the folder, the filters
  and the place, also between runs ([preferences](#preferences)).
- **Find in Content Browser** (`content_reveal`, the magnifier of a Details field) empties search
  and filters immediately; the next frame enters the asset's folder if the view does not show it,
  selects it alone, gives the keyboard to its card and centers it. For a hidden part of a prefab, it
  turns on Show parts of imports and shows it in its folder; for that of another owner, it opens its
  owner.

Gestures:

- **Dragging a prefab**: places it linked ([prefabs](prefabs.md)). **Dragging a scene** with
  several roots places a `Scene_Reference` to it, a section; a prefab becomes a section by naming
  it in the `scene` of a `Scene_Reference`.
- **Dragging a mesh**: creates an entity with that mesh, resting on the surface.
- **Dragging a material**: assigns it to the mesh under the pointer.
- **Dropping a card on the name, chip or cell of a folder**: moves it there.
- **Click on a prefab or a mesh**: selects it and arms placement (`Editor_Ui.placement`): each click
  on the scene places one, and Escape or the right button ends it.
- **Click on a material**: assigns it to the selected meshes.
- **Click on an asset of a plugin type**: what its `Asset_Kind_Provider.clicked` says (a particle
  effect is assigned to the selected emitters).
- **Double click on a material, or on an asset of a type a plugin declares** (animations with
  `previews`, particle effects with `vfx`): opens its [document](#asset-documents), in the
  tab of the front one if it is of the same type and clean
  ([replacement](document.md#asset-documents)).
- With an asset document in front, clicks and drops on the scene do nothing.
- A card's menu (`content_menu`) has Open, Uses / Used by, Show in folder, Apply to selection on a
  material, Update thumbnail on an open scene ([thumbnails](#previews)), Play or Stop sound
  (`sound_hear`: outside every world, one at a time), **Ask agent** (`ai_ask`, with the card and the
  others selected as attachments of the message), favorites, Create, Rename, Duplicate, Move to and
  Delete.

## Previews

**Colliders** (`plugins/physics/editor/colliders.odin`):

- In Edit the `Collider`s of what is selected and its authoring descendants are drawn (a parent
  without a collider shows those of its children), also with Grid and Indicators off, in two
  batches of the same lines: one with depth test and another without it, faint, so that what is
  behind is seen. It omits derived nodes that delegate their identity (`entity_author`), which the
  physics debug does show.
- It reads the already synchronized shape (scale, center, composite pose and real geometry of Hull,
  Mesh and Heightfield) and reuses the lines while selection, synchronization, pose or `Id` layout
  do not change.
- `Collider_Preview` has its own vertex budget: a shape that does not fit is drawn as its physical
  box and, if that does not fit either, it is omitted; never a clipped triangulation
  ([Collider](../../mirai-physics/references/engine.md#collider-fields)).

**Thumbnails** (`asset_thumbnail`: icon of a mesh, a prefab or an entity in the inspector, content
browser cards and asset fields):

- With premultiplied alpha; the renderer draws them with the subject's materials and an analytic
  studio independent of the scene's lights.
- Two cell sizes in a single 2048×1280 atlas (`Thumbnails`; `renderer_set_thumbnails` uploads in
  `editor_services` only the rectangle of the cells that changed): 128 of 64 pixels (3×3
  supersampling) for what is seen up to 64 pixels, and 32 of 256 (2×2) for more, which cover the
  largest card of the content browser at density 2.
- `preview_request`, `preview_geometry`, `asset_quad` and `preview_entity` receive the points at
  which the preview is shown and return the quad of the cell of its size when it exists; the same
  subject at two sizes occupies one cell of each. One is drawn per frame; until then the icon is
  shown.
- A subject that changed keeps its old image until it has the new one, and waits for an open edit
  to finish. The cell that has gone longest without being requested is reused.
- The signature is `Thumbnail_Subject`: mesh, `Material_Values`, rotation, scale, the
  revision of the loaded assets and that of the registry (every file that changes, loaded or not,
  makes the subject be looked at again) and, for what is not a mesh alone, the type whose provider
  draws it, what poses it and its clip, the document and its root.
- **Geometry** (`triangles_append`, which the `previews` animation document also uses): that of a
  project mesh and its slots are read from the file, with its tangents and second UVs, in the
  mesh's space, without loading it in the renderer; a primitive or a mesh generated at run time
  takes the tangents from its corners. From a mesh the finest level that fits in what remains of
  the total 400000 triangles is taken (a skin poses only the first); if none fits, it is left out
  whole. Its materials and textures are loaded.
- **Prefabs** (`preview_document`, `thumbnail_subjects.odin`): the entities of the saved document
  that show a `Mesh_Renderer`, where their `Transform` and their hierarchy put them, with their
  `Material_Values`; `Hidden` leaves out the entity and what hangs from it. A
  skin is seen as it stores its vertices. Everything is framed from the studio's direction. A mesh
  with the same `Material_Values` is read once for all the entities that show it.
- **Scenes** (`preview_scene`): the first thing the editor showed of the scene the first time it
  opened it (`scene_open`: menu, tab, API or initial scene; not a prefab), while it has no stored
  view; afterwards, what the viewport shows when **View > Update scene thumbnail** is chosen
  (`scene.thumbnail`; off outside Edit, with an
  asset document in front or with a scene that is not a saved asset) or **Update thumbnail** in its
  card's menu while it is open in a tab (`scene_thumbnail_update`: if it is not in front, it
  brings its tab and takes the view that tab kept). On saving it, a notice says "Scene thumbnail
  updated". `THUMBNAIL_CAPTURE_WAIT` frames after opening it, or between the frames of the action,
  `thumbnail_scene_capture` draws the world alone from the viewport's camera, like `capture`
  without the UI (`host.app_capture_world`, 512×512 and `API_CAPTURE_SETTLE` frames), reduces it
  to the two sizes, stores it in `.mirai/thumbs` with the fixed key `THUMBNAIL_CAPTURED` and puts
  it in the cells that already show the scene. It is not taken if by then there is a Play, another
  scene or an asset document in front. A scene that was never opened shows its icon: it is not
  drawn with the studio. Saving it, editing it or reopening it does not change the view. It fills
  the card as a texture.
- **Types of a plugin** (`preview_provided`): the types a `Thumbnail_Provider` names show what its
  provider says, which also draws what is not a mesh alone
  ([extensions](extensions.md#thumbnails-of-an-asset-type)). Those of animations belong to the
  `previews` plugin
  ([thumbnails](../../mirai-plugins/references/previews.md#animation-thumbnails)); without it
  they show their icon.
- **Stored.** The preview of an asset (mesh, prefab or a type of a project plugin, not that of an
  entity, a shape or the default of a type) stays in `.mirai/thumbs/<id>-<side>.thumb`, one per
  asset and size, with premultiplied alpha in LZ and the key it was drawn with.
  - The key (`thumbnail_store_key`) combines `THUMBNAIL_RENDERER`, the size, the subject without
    the revision and the `content_hash` of the asset and of the whole dependency closure the
    subject names, as the registry has it (also what is unsaved). Saving the asset or a dependency
    gives another key and the preview is redrawn.
  - When the signature changes, a cell that already has the image of the current key is not
    redrawn; otherwise, the file is read (up to `THUMBNAIL_LOADS` per frame, apart from drawing) and
    it is drawn only without a file or with another key.
  - Those of an id that the registry notes in `Registry.removed` are deleted in the next frame
    (`thumbnails_forget`).
  - Raise `THUMBNAIL_RENDERER` when the same subject would give another image (studio, reduction,
    geometry or how a provider draws its image). A program's Slang source does not enter the key:
    changing it does not redraw the stored previews.
- A material's preview (studio sphere) does not use the atlas: the renderer draws it in a row of
  its material table (`host.assets_material_row`) and the UI shows it as
  `UI_QUAD_MATERIAL_PREVIEW`.
- A provider with `image` draws the preview of its type between frames, after the frame that
  requested it (`Thumbnail_Picture`, one at a time, in the turn of one per frame), and the cell
  shows what it had until then; `vfx` draws its particles on the GPU this way. The assetless row of
  a list or the box of an empty field show their default (`preview_default`), if it gives one.

## Asset documents

`asset_documents.odin`. An asset opens in a tab next to the scenes, like `AssetWorkspace.vue` of
the prototype; tabs, history, Save and closing in [document](document.md#asset-documents).

- With a document in front, the active scene stays loaded underneath but is neither drawn nor
  handed to the renderer (`App.ui_only`, which also draws the previews' images of the panels); in
  its place goes the prototype's canvas color.
- **Workspace** (`asset_workspace_rect`): from under the left panel, whose rounded corners show it,
  to the edges of the window, below the bars; every other panel floats over it, and Details docked
  takes its edge. A panel with 33-point headings (`asset_heading`, background `ASSET_SUBSECTION`);
  what is read in it starts past the left panel (`asset_workspace_under`).
- **Left column**: the shared panel takes the whole height. Details, the viewport tools, the gizmo,
  picking, placement, what is drawn over the scene and Play are not there; `tool_on` is false and
  `tool_set` does not turn on.
- **Toolbar**: Save, Undo and Redo of the document and, in the rest (`asset_toolbar`), what the
  document reproduces; on the right Find, Graphics and Session. The chat opens from its tab of the
  left panel.
- It is opened by a double click in the content browser, the file row in an AI review,
  `editor.document` and `editor.material.show`.
- **Images** (`asset_image.odin`): `Asset_Image` is an entry of the texture table that the renderer
  fills inside the frame (`asset_image_draw`, with `render.Preview_View` and `Preview_Light`) or the
  CPU. The renderer's fills its area with its shape, at two texels per point while it fits
  (`asset_image_size`; another size redraws it). `Asset_View` is its camera: it orbits, zooms and
  pans, and a double click returns to the studio view.
- **Subject light:** `PREVIEW_SUN` and `PREVIEW_ENVIRONMENT` are that of a prefab
  (`prefab_preview_lighting`) and that of a subject's images.

### Material document

`material_document.odin`. A `.mat`, or the `.slang` source of a lone program, without preview or
values. The user sees neither the source nor a graph: the agent reads and changes it by API, and
the user looks at the result, adjusts values and chooses among variants.

- **Preview** (`Materials.preview`): the material on a shape in the studio, which
  `renderer_preview` draws only when values, view, channel, shape, assets or shaders change, and
  every frame if its program reads `ctx.time` (the derived graph says so). Another material returns
  to the studio view.
- **Toolbar** (`material_toolbar`): the channel (Lit or a value the material writes, those of
  `material.preview.capture`) and the shape. The channel goes as `debug_view` and `thumbnail.frag`
  shows it in the same draw, without another pass; `material.preview.capture` always draws the
  sphere.
- **Variants** (`editor.material.variants`, from the agent): below the preview, with the same view
  and channel. A click shows one in place of the material without changing it; with one shown,
  **Apply** puts its values in the material (a history step) and **Save as new** writes beside it
  `<material> <variant>.mat`, unsaved and without opening it, so that the variants continue.
- **Details** (`asset_workspace_details`): a card per group (metadata `group`) of the program's
  non-texture parameters, or those of the standard model. A drag changes the material in memory
  (`host.assets_material_set`) and the `.mat` is written once when the gesture ends, one history
  step. In an imported material, the arrow of a standard value returns to it what the source gave
  (`material_base`, `material.revert`). A click on a value's name chooses it.
- It rereads the source the editor has (unsaved or the file's, `file_read`) when it changes
  (`file_stamp`), for its review and to know whether it reads time.
- **Request:** each frame leaves in `Ai.material` the material, the program, the chosen values, the
  channel if it is not Lit and the last variant put; the composer shows them as chips and the
  request's region is the preview ([context](ai-tasks.md#context-of-a-material)).

### Records document

`records_document.odin`, over the table as the package `editor/records` changes it (rows, names,
ids and texts, without the session). A `.records`: a grid with a row per record and a column per
field, and on the right all the fields of the chosen row with the Details rows
(`held_field_row`). On top, the type's description; that of a field appears on hovering the name
of its column.

- **Columns** (`records_columns_make`): the type's fields, with structs opened up to
  `RECORDS_COLUMN_DEPTH` levels and arrays of up to `RECORDS_ARRAY_COLUMNS` elements, one per
  column; what is longest is edited alone on the right. The first column is the row's name, which
  is renamed by typing.
- **Cells:** a draggable or typed number, a checkbox, a list of an `enum` or of a named id, an
  asset button, the text of a `[N]u8` and, of a `core.Text`, its key of the `.strings` (what the
  key says goes through `texts.set` or `mirai texts`). A `core.Record` is the list of the rows of
  its type (`record_choice`), the same as in the inspector.
- **Add row** adds a row with the type's default after the chosen one; **Duplicate** copies it with
  other text ids; **Delete** removes it. The visible rows are the only ones built.
- What the grid and the right column change is a copy of the table, which is written as a step of
  the document's history when nothing holds it (a drag, a text being typed, an open list). A change
  the table does not admit (a repeated name) is warned about and the copy rereads the file. If the
  file changes elsewhere (`records.*`, Undo), it is read again.
- `Asset_Document.part` with a row's name chooses it and shows it on opening: the button of an
  inspector `core.Record` uses it.

The documents of animations, sounds and sound sets belong to the plugin
[previews](../../mirai-plugins/references/previews.md), and those of particle effects, to the
plugin [vfx](../../mirai-world/references/vfx-editor.md#particle-document).

## Import

`import_file(s, path)` converts a source file into project assets, only in `Edit`, with
`sources.import_source` like `mirai import`. A source inside the project is versioned with its
sidecar, and what it builds that nobody edits goes to the imported folder of the project; a source
outside it keeps every asset in the assets folder, with its sidecar in `source/` of the project
([identity](../../mirai-imports/references/imports.md#identity-and-reimport)). It goes to the
folder of its type or to `folder` (`asset_folder_clean`). The imported folder is brought up to
date with the sources by the build that opens the editor
([sync](../../mirai-imports/references/imports.md#sync)).
File > Import, the content browser, a file dropped on the window and `asset.import` call it. It
imports in a thread of its own, with its own job system, while the editor keeps drawing; the
content browser shows the dot of what works. `import_poll`, between frames, takes what it wrote on
finishing. One import runs at a time and, while it runs, nothing else writes assets: another
import, saving (`scene_save`, `assets_save`), creating, deleting and writing prefabs
fail with `import_busy`, which says what is being imported. What the file is is told by its
content (`sources.source_kind`, with the formats of the engine and of the plugins); the dialog
offers those formats, the plugins' whole sources and the image and sound extensions. Formats and
output folders in [importers](../../mirai-imports/SKILL.md).

- A plugin adds model formats and whole sources to import
  ([importers](extensions.md#importers-of-a-plugin)); a whole source that claims the file is
  imported before the formats and takes no folder.
- An image is sRGB unless its settings or its name say it is data or a normal (`sources.image_use`,
  which `mirai import` applies too); `asset.import {image}` chooses it.
- The sidecar of a source (`<source>.import`) keeps its settings and the id of each asset;
  reimporting writes the same assets with their ids where they are and keeps what did not change.
  Textures with
  the same image and settings and meshes with the same geometry and settings come from their caches
  ([textures](../../mirai-imports/references/imports.md#texture-cache),
  [meshes](../../mirai-imports/references/imports.md#mesh-cache)).
- On finishing, the written files are refreshed in the registry and the replaced assets are
  reloaded; if Surface programs were written (`Import_Report.programs`), the project's programs
  are published (`programs_publish_request`) without waiting for another change.
- **Parts.** Meshes and skeletons of a model, and the materials and textures that are only its,
  are parts of its prefab (`asset.Header.owner`,
  [rule](../../mirai-imports/references/imports.md#parts)). `asset_detach`
  (`editor/assets_parts.odin`, `asset.detach`) takes one out of its owner as an unsaved edit with
  undo: it only clears `owner`, and the import leaves it out; there is no UI that calls it yet.
- **What an import keeps in the imported folder is not edited where it is.** Moving, renaming,
  detaching or deleting a part on its own is refused, saying to duplicate it. Moving the root of
  an import (`asset_move`) moves its source and sidecar under `source/`, and moving a folder moves
  the folder of the same path under `source/` with it: the registry lists their assets there at
  once, without an import. Deleting the root of an import
  (its prefab, the texture of an image) gives the import up: its sidecar goes to the trash with
  what only the import can build, and the source stays. A
  copy made outside the editor receives an id of its own on scanning
  ([repeated ids](../../mirai-assets/references/formats.md#registry)).

## Graphics

The Graphics popup edits `Graphics_Settings`, the machine setting with which game and editor draw
([project settings](../../mirai-projects/references/projects.md#project-settings)), in two
sections that fold like those of the settings dialog: Quality and Frame rate.

- A **preset** (`GRAPHICS_PRESETS` of `engine/render`) fixes a choice per quality option; what
  matches none is Custom
  ([resolution](../../mirai-rendering/references/settings.md#scene-resolution)). The default
  depends on the GPU (`graphics_settings_for_device`) and each option returns to it.
- Antialiasing is not part of the presets: Off, TAA and the
  [techniques](../../mirai-rendering/references/views.md#antialiasing-techniques) of the active
  plugins; one that no plugin offers is shown as TAA, which is what is drawn.
- A row is a field of a machine setting, of the engine or of a plugin, whose tag carries
  `graphics=Label`: a bool or an enum (its values, named by `choices=A|B` or by their names), a
  number with the values `choices` lists (`label:value`, or a label that is its value), or the text
  of the antialiasing technique. The rows of the section `Frames` go to Frame rate. There is no
  list of options apart from the tags.
- A choice is applied instantly to the edited world and stored in the engine layer
  (`settings.mirai` in `project.machine_folder`: the main checkout's `.mirai`, which its worktrees
  share). A value the project fixes wins again on rereading. It does not touch the document or its
  history.
- API: `graphics.status` and `settings.set`.

## Project settings

File > Project settings opens a dialog with the `@(storage,setting)` of the engine, the active
plugins and the game, with the Details rows.

- Categories go by origin: Project (with Project and Plugins first), Engine, Plugins and Game. The
  settings of one same engine package or one same plugin are a category, with each as a part
  (Audio: General, Volumes, Output); each category shows its sections (`section=` of its fields),
  each under its band, which runs from one edge to the other, and without a box, with the dialog's
  font and its label column, wider than Details'. Details, in contrast, puts each component in a
  block a shade lighter than the panel. `advanced` fields go at the end of their part, under an
  Advanced fold that starts closed and that the search opens; the API and the files do not
  distinguish them.
- Editor goes first in both layers: it is not of the project but of the machine
  [preferences](#preferences). Its Panels card gives the mode of each side panel and that of each
  document type ([Floating or Docked](#layout)); it is written like the rest of the
  preferences and Reset to default does not touch it. The search leaves the categories, sections
  and fields whose name contains it.
- Project edits `project.mirai` minus the plugins (Game, Window and Build) with the Details rows
  on a copy, which is written when the UI rests; an invalid value is warned about with the text of
  `project.error_text` and the copy returns to the file's. A Build change launches a Build, like
  the plugins; the rest applies on opening the game.
- The dialog edits only the Project layer
  ([layers](../../mirai-projects/references/projects.md#project-settings)): it shows the
  effective values and reverts to the engine's value. The Engine layer (the machine settings,
  `@(storage,setting="machine")`) is written by the Graphics popup, the preferences and
  `settings.set` with `layer: engine`. Reset to default returns the project's settings to the
  engine's, except the plugins and input. The project-settings sections that the engine file brings
  are warned about and not applied.
- A change goes instantly to the edited world (or to the application for a `Shared` setting) and
  to the file of its layer when the gesture ends; changing layer writes what is pending. A Play and
  the game read the files on creating their worlds. It does not touch the document or its history.
- Plugins: each plugin the project sees with its icon and its switch, except the automatic ones,
  which are activated with their dependencies; those an active plugin needs are on and fixed. A
  change rewrites `plugins` of `project.mirai` and launches a Build, which restarts the editor with
  the new world.
- Input (`input_settings.odin`, only in the Project layer): a card per action declared by the code
  of the game or an active plugin, with its type, its bindings and the arrow that returns it to the
  code's default, and one for the tap and hold ticks. What the window edits and writes is
  [`input.mirai`](../../mirai-gameplay/references/control.md#actions); the key images are another
  thing, of UI (`UI_Settings.prompt_images`).
  - The card is that of the other categories, with a rule between rows. A binding shows its device
    in the label column and each input with the prompt the game would draw (the image from
    `prompt_images` or from the pack of `UI_Settings.prompts`, or the drawing), and its label
    folds `scale`, `dead_zone` and `gamepad` when its type reads them (`binding_uses`).
  - Add binding, or a right click on an input, opens a menu: Press an input listens and a submenu
    per device (Keyboard, Mouse, Gamepad) lists what the type takes (`input_choices`), with the
    inputs' prompts: a Button, each key, button and axis; an Axis, the axes and pairs of keys or
    buttons; an Axis2, WASD, arrows, Dpad, sticks and the mouse. This way a gamepad that is not
    connected is bound. Choosing adds the binding, or replaces that of the input with its options.
  - A click on an input, or Press an input, listens for the next: a key or button, a gamepad axis
    that moves away from where it was, the mouse moving far or its wheel. A key Axis or Axis2 takes
    two or four consecutive keys; a key of a key binding is changed alone. What does not serve the
    type is ignored; Escape cancels and a click while listening binds the mouse button without
    doing anything else.
  - A change takes effect when its gesture ends; a file that cannot be read is shown and blocks
    editing.
- API: `settings.get` and `settings.set`; input, `input.get` and `input.set`; the manifest and the
  plugins, `project.get` and `project.set`
  ([catalog](../../mirai-agent-api/references/methods.md#project)).

## Project panels

`panels.odin` and `api_panels.odin`. Interfaces the chat agent builds when the user asks for
controls of their own (testing environment, post-processing or lights): data, without editor code
or compilation.

- Each panel is `panels/<id>.mirai` of the project (`project.Folder.Panels`), versionable JSON that
  the shipped game does not copy: `title`, `buttons` (up to 12) and `rows` (up to 32); it has
  buttons, rows or both.
- A target is a field of a component (`component`, `field`, and optional `entity` or `where`) or of
  a project setting (`setting`, `field`). `field` names a nested field by its dotted path; hidden
  and `transient` ones do not exist for a panel. `entity` is an entity by its id; `where`, an object
  of fields (by path) and values: the entities with the component whose fields have those values,
  compared as the field stores them; `{}`, all that have the component. With neither, the first
  entity that has the component.
- A button (`name` unique in the panel, `sets` with up to 12 targets and its `value`) is a variant:
  it puts each field at its value, with the JSON that `scene.write` and `settings.set` accept (up to
  159 bytes), without those fields having a row. The entities of a `where` are looked up when it is
  pressed, so it reaches those created after saving the panel. Buttons are pressed in any order: if
  one sets fields of a target (same component or setting, `entity` and `where`), it sets all those
  that another button sets there; otherwise `panel.save` rejects it naming the missing field (an
  Off with intensity 0 forces the others to set their intensity).
- A row is a title (`heading`) or a target with optional `label`: a field adjusted by hand with the
  Details widgets (`field_row`), for example after pressing a button. It shows the value of the
  first of its entities, with "(mixed)" in the label if they differ, and writes to all; the popups
  (color, lists) return to the row through `Inspect.held`, not to the selection.
- An open panel takes the place of Details, like that of a plugin tool
  ([extensions](extensions.md#a-panel)), and one is opened at a time from the **Tools** menu:
  opening it turns off the active tool and turning on a tool closes it. It is closed with Escape or
  on changing the selection, for example with a click on another entity, and Details returns; it
  has no close button. Header with title and delete; the buttons two by two; **Restore**; below,
  scrollable if they do not fit, the rows and, if it has buttons, the foldable **Attributes**
  section, closed at start, with each target of the buttons once as an editable row; that of a
  `where` with its condition and how many entities match now.
- Before a button or a row changes a field for the first time, `Project_Panels.kept` keeps what it
  was (per panel, entity or setting and byte range; in memory only). **Restore** returns it in
  reverse order, the scene's as an undo step "Panel: Restore" and only on the entities that still
  have the component, and forgets it; with nothing kept it is disabled.
- A scene field changes with `field_write` (common undo) and a project setting with
  `setting_write`, as in the [settings](#project-settings) dialog, to the layer that one edits.
- A row that cannot be shown (component or field that no longer exists, deleted entity, no entity
  with the component) stays as a read-only row with the reason.
- A button reads all its values before writing: if one fails nothing changes and the toast says
  which; if no entity matches, it says so. Its scene fields are a single undo step named
  "Panel: Button"; the project settings do not enter the history.
- Tools lists the project panels with a check on the open one; they are hidden in Play, while a
  reference is being chosen and with an asset document. Opening or closing does not write the file:
  on startup all are closed. Delete removes the file.
- The files are read once per project folder; one that cannot be read is warned about in the
  console and left out.
- By API: `panel.list`, `panel.save`, `panel.open`, `panel.close`, `panel.delete` and `panel.apply`
  ([methods](../../mirai-agent-api/references/methods.md#project-panels)).

## Preferences

`preferences.odin`. How panels, viewport, lists and Play were left is stored for all the engine's
projects and checkouts on the machine: `editor.mirai` in `project.machine_folder`, outside git.

- One section per area with the name of its type and only the fields that differ from the code.
  Each area has its flat struct in its storage, with a single writer (`Layout`, `Content_View`,
  `Viewport_Preferences` and the others), and a plugin adds its own through its
  `Preferences_Provider`
  ([extensions](extensions.md#a-plugins-game-and-player-processes)).
- It is written when the UI rests (no button, wheel, drag, edit or inspector gesture) and something
  changed, on closing and before restarting for a Build: never per frame. During a Play it is not
  written: its layout is the Play's.
- A `--headless` neither reads nor writes them, except with `--preferences`. Without an engine root
  there is nowhere to store them. A file that cannot be read is warned about and left as it is, and
  the editor starts with the code's values.
- What of the content browser belongs to each user and project goes in `content.mirai`, in the
  project's `.mirai`, with the same rules: Recent and Favorites (`Content_Marks`) and where it was
  left (`Content_Navigation`): the place, the folder of the last thing clicked, the filters on and
  Only unused assets. The search is not stored: it is what is being searched at that moment. Each
  time the registry changes, and the first time it is built, the browser checks them against it: a
  folder that is no longer there falls to the nearest one above that is, or to the root.
- API: `preferences.get` and `preferences.set`
  ([catalog](../../mirai-agent-api/references/methods.md#graphics-and-settings)); what of
  `content.mirai` does not enter.
