# Animation and sound documents

`plugins/previews/editor` opens animations (`.anim`), sounds (`.sound`) and sound sets
(`.sound_set`) as [asset documents](../../mirai-editor/references/panels.md#asset-documents): it
declares them with `Previews_Documents` (an `editor.Asset_Document_Provider`) and draws them from
`previews_document`, a `ui` step that looks at the front document. The material has its document in
the editor, and the particle effect, in the
[vfx](../../mirai-world/references/vfx-editor.md#particle-document) plugin. It also provides the
animation thumbnails ([thumbnails](#animation-thumbnails)).

## Animation document

The clips of the `.anim` in the Hierarchy tab (one opened from the content browser arrives as
`Asset_Document.part` and stays chosen), the clip on its subject with its time strip below and
what the clip is on the right.

- **Clips:** the provider declares the `.anim` hierarchy and `animation_clips` builds it in
  `editor.hierarchy_room`: one row per clip with its duration; choosing one puts it at the start.
  A clip opened from the content browser arrives as `Asset_Document.part` and stays chosen.
- **AI context** (`animation_say`): each frame says the clip, its frame and its time over the
  duration, whether it is playing (with its speed, Loop and range) or paused, and the subject.
- **Drop** (`previews_drop`): a `.anim` or one of its clips dropped onto an entity gives it
  `Animation` (`ANIMATION_DEFAULT` if it had none) with that asset and that clip, as an edit.
- **Time strip** (`editor.asset_playback_strip`, the
  [editor strip](../../mirai-editor/references/extensions.md#an-asset-document)): it counts
  the clip at `editor.ASSET_PLAYBACK_RATE` frames per second; play and loop stay within the range.
  Another clip returns it to the start, with the whole duration in view and no range.
- **Markers:** the strip's lane, one diamond per clip marker with its name. Dragging one moves it
  (**Move marker** on release); its **+** button asks for a name and adds it at the playhead; the
  right button opens a menu: **Add marker** at that time and, on a marker, **Rename marker** and
  **Delete marker**. The `.anim` changes in memory, unsaved, as a step of the document history
  (`animation_marker_write`, with `asset.animation_descs` as `animation.marker.set`); gameplay and
  agents read those markers by name.
- **Details:** clip, duration, tracks, keys, markers and, with a root bone, the root motion;
  **Subject** chooses what it plays on.
- **Subject:** the scene entity whose `Animation` plays the asset; if none, the skeletal mesh that
  its thumbnail shows (`thumbnail_animation_model`: [thumbnails](#animation-thumbnails)); if
  none, the active entity. Subject offers Scene (the entity) or any skeletal mesh
  (`skinned_meshes`).
- From an entity it takes its subtree: its mesh or that of its `Pose_Source.rig`. On rigid objects
  the tracks are bound by `Animation_Target.path` or by `Name` and the transform hierarchy; a mesh
  alone poses its skeleton at the origin.
- The triangles of each mesh are those of the thumbnails (`editor.triangles_append`: from the
  file, with tangents and second UVs, also without loading it); a mesh that depends on a skeleton
  is read again through its skin (`skin_geometry_read`).
- It reads the skeleton from the mesh's asset, loads its compact bones and samples its tracks by
  path with `std/anim`. The bones are not converted into entities. It shows the chosen clip,
  without layers or gameplay constraints.
- The image (`editor.Asset_Image`, an entry 1024 texels on a side) fills the preview area; its
  camera (`editor.Asset_View`) orbits, zooms and pans like every
  [document image](../../mirai-editor/references/panels.md#asset-documents).
- **Light:** that of a prefab, sun and sky over the ground grid (`editor.PREVIEW_SUN`,
  `PREVIEW_ENVIRONMENT`), without shadows. The toolbar's sun turns it off and leaves the sky, like
  Preview sunlight in a prefab.

### Preview skinning

- It deforms with `render.Skin_Preview_GPU`: the game's skinning compute with its own buffers,
  which last as long as the subject, and a palette in the subject's space; the vertices are not
  transformed again on the CPU. It takes a copy of level 0 of the mesh's clusters; posed position,
  normal and tangent go to the triangles that the thumbnail decoded, which keep uv and color.
  `skin_pose` and `skin_place` serve the document, the capture and the thumbnails (with a
  synchronous readback between frames).
- It modifies no vertices, BLAS, previous pose, camera or history of the main render. An image
  without changes is not sampled again; playing or seeking costs one GPU transaction per skeletal
  mesh.
- The framing covers the whole clip with the same deformation and is kept while the subject or
  clip do not change. If geometry or capacity is missing, Details says so.
- Mesh and animation are loaded with the host allocator (not with the UI or RPC scratch) and are
  closed when the extraction finishes.

## Animation thumbnails

`Previews_Thumbnails` is the `.anim` `editor.Thumbnail_Provider`
([extensions](../../mirai-editor/references/extensions.md#thumbnails-of-an-asset-type)): it
shows the model that the animation moves, resolved by the registry, without a game's rules.

- The model is what plays it in the first prefab or scene by path that depends on it (the first
  entity with a component that names it): its skinned mesh whose skeleton its tracks move or, if
  the tracks do not move it (morphs only), the entity with what hangs from it. Without anything
  that plays it, the skinned mesh whose skeleton has the most bones that its tracks move; without
  any, its icon.
- The library card poses the first clip and that of each clip its own, at half its duration, with
  the document's skin and the bones of the `animation` skeleton cache.
- `Previews.models` stores the skinned meshes and the model of each animation, which is looked up
  again only when the animation, those skeletons or a document that depends on it change: a frame
  without changes in the registry reads nothing.

## Animation capture

`animation.capture` (`capture.odin`) shows in an image how an animated entity moves, so that an AI
sees the result without opening the document.

- It runs the copy of `animation.preview` with its same fields and stores the pose of the rig and
  its parts at `frames` instants spread over `seconds` from `time`.
- Each frame is deformed with the preview skinning and drawn with the thumbnail renderer, one row
  per view: the character turns about its root according to the `forward` of its skeleton's body,
  so each view sees the same side even if it is rotated in the scene. The frames of a view share
  the framing: displacement and height are compared between them.
- It writes a PNG and answers with the image as MCP content; if it does not fit, it asks for fewer
  frames, views or size. Two captures are compared with `mirai image diff`.
- It changes neither the shown world nor the assets; its buffers last the call.

## Sound documents

**Play** in the bar makes it sound with `editor.sound_hear`, like Play sound in the content
browser; a set picks one of its sounds each time. The state is `Previews.sound`.

- **`.sound`**: the waveform (minimum and maximum of the samples per column, drawn on the CPU and
  uploaded with `editor.asset_image_pixels`; a stream is decoded whole once) and its data. It is
  computed when the assets revision changes.
- **`.sound_set`**: its sounds up to the last one with a free entry after it, each with its weight
  and an x that removes it, and its ranges. The rows are those of Details over the document's
  values, with the arrow that returns what they had when read. They are written with
  `editor.sound_set_write` when the UI releases them: in memory, unsaved, one history step each
  time; what `editor.sound_set_refusal` rejects (a sound that is not a `.sound`, an inverted
  range) is said by a toast and the rows go back to the file. A file read again replaces the rows
  only if they had no changes.

## Verification

- Thumbnails (`plugins/previews/editor`, CPU): `thumbnails_show_the_model_an_animation_moves`;
  its image, `capture` with the UI and the content browser filtered by Animation.
- `preview_samples_compact_bones_and_frames_the_clip_without_changing_authored_poses`
  (`plugins/previews/editor`): bones, mesh index order, inverse bind, framing, rest,
  `Pose_Source` and authored poses intact.
- Run it with graphics validation together with
  `gpu_skin_preview_reuses_compute_and_buffers_without_mutating_the_scene` (`render`): eight
  influences, normals, buffer reuse and isolation of scene and history.
  Per backend: [rendering verification][render-verif].
- With the gallery assets generated:
  `preview_loads_and_samples_the_imported_mirai_avatar_assets -define:PREVIEW_MIRAI_AVATAR=true`
  loads from the registry, shares the skeleton cache and advances the `walk` clip, without
  modifying files or scenes.
- The rows over a panel's values:
  `curves_show_as_keys_and_held_values_take_what_a_popup_chose` (`editor`).
- The documents in an open editor: `editor.document` with `Open` and the asset path, and
  `capture` with the UI next to the prototype. The sound ones have no prototype:
  `audio.play` and `sound_set.inspect` check what they do.

[render-verif]: ../../mirai-rendering/references/verification.md#gpu-environment
