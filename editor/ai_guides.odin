package editor

import "mirai:asset"
import "mirai:editor/api"

// How to use the methods of a plugin, or of a family of methods of the
// editor: engine_describe gives it with them (api.Guide), and the
// instructions of a turn only when its message comes from a document of the
// plugin. A turn does not carry what it does not use.

AI_GUIDES :: [?]api.Guide{
    {topic="physics",text="Configure collision by names the code declares: categories and presets are constants of Collision_Category and Collision_Preset (names.create declares one), and Collision_Settings says by name what each preset is. A Collider takes a preset, or custom with its own sensor, belongs (the categories it is in) and collides (those it meets); two colliders meet when each belongs to a category the other collides with, and they block unless one is a sensor, which only reports the overlap. A door with a new Collider blocks everything. Read with physics.collision.get and edit with physics.collision.set (preset, or sensor, belongs and collides; a Query_Filter takes hits, the categories it hits, [\"*\"] for all, and sensors); physics.collision.inspect lists categories and presets. Numeric bits are internal data, not names."},
    {topic="paint",text="Paint vertex colors of a mesh with paint.stroke along world points and take them back with paint.clear; drop new meshes that physics settles on the scene with placement.drop. Both are what the Paint and Physics placement tools do, as one undo step each."},
    {topic="animation",text="Animate by intent before keys. skeleton.body.detect finds the body parts of a skeleton (correct them with skeleton.body.set); ragdoll.setup makes from that body the ragdoll of a rig, with its bodies and limited joints; animation.character.setup makes a character able to locomote, look, reach and gesture; animation.request asks an entity for those intents and for any control (parameters, actions, goals, controls, motion); animation.preview tries the same fields on a copy and animation.capture shows it as frames. Change whole clips with animation.clip.edit (Retime, Hold, Extend, Smooth, Exaggerate, Make_Loop, Offset toward a body direction, Lock_Feet, Mirror) and measure with animation.analyze, whose fixes are clip edits. What plays over the locomotion is the action set of the entity (animation.action.set): its layers, whose weights and aim axes are the parameters, and the actions that play by name. For fine work inspect definitions with animation.asset.inspect and instances with animation.inspect, and check any create or set first with dry_run. Names, not indices: compiled indices stay internal. Animation asset edits are steps of history.undo/redo. Read engine.describe for typed schemas and defaults. Normal component/scene inspection omits hidden and transient fields; use include_runtime=true only for detailed inspection."},
    {topic="cinematics",text="A cinematic is a clip with shots. Make its clip as any other: animation.clip.create makes the .anim, animation.track.set and animation.key.set write its keys (the target of a track is the name of an actor; a lens is target/@field/Camera.fov, and any field of a component is target/@field/Component.field) and animation.marker.set its markers, which arrive in Animation_Events. cinematics.add makes the timeline (part Timeline with that clip: an entity with a Cinematic and the Animation that plays it), its shots (part Shot: a camera from a time of the clip, with a blend) and its actors (part Actor: an entity anywhere that the clip moves by name). cinematics.control plays, pauses or seeks it (in Edit the preview of the Cinematics tool seeks the clip in the scene without changing the document, and view Shot looks through the shot; see it with capture); cinematics.inspect lists its shots, actors and viewers and the view at a time. Do not use scene.set on the components of cinematics."},
    {topic="material.program",text="Shader programs (Slang sources under shaders/ that declare `//! mirai <kind> Name`: surface for materials, postprocess for effects on the image, vfx for particles, ui for nodes of an interface) are made and changed through the editor, never with your own file tools, which cannot be reviewed or reverted: `material.program.create` (program, kind, and a source or the template of its kind) makes one in the shaders folder of the project; `material.program.inspect` gives the source, the parameters and a graph derived from the source; `material.program.check` compiles a source without publishing where it runs (a Surface program in a raster stage and a ray stage, the others in the stages that run them) and returns diagnostics with a fix each; `material.program.edit` (the whole source or edits [{old,new}]) checks, changes the .slang in memory (unsaved until the user saves it: asset.unsaved lists it) as a step the user can revert and publishes it, first for the previews; create does the same with a new file; `material.preview.capture` draws the material on a sphere and returns the image and per view min, max, mean, nan_count and uniform (Lit, Albedo, Roughness, Metallic, Normal, Emission). Capture before and after a change and compare the PNGs with `mirai image diff`. Values of a .mat change with `material.set`; to let the user choose among values, propose up to 6 sets with `editor.material.variants`, each drawn on its own sphere that the user clicks to set it. A parameter's `//! parameter` metadata takes `group` (a name), the card of Details that shows it, and min and max, the range of its slider. Surface programs also run on ray hits (no ddx, ddy or fwidth: use mirai_sample_texture with ctx), colors arrive linear, base_color is a reflectance from 0 to 1, roughness is at least 0.045, normals are unit vectors in the world, and emission is luminance in nits."},
}

// The guide of a topic; empty when it has none.
ai_guide :: proc(topic:string) -> string {
    guides:=AI_GUIDES
    for guide in guides {if guide.topic==topic {return guide.text}}
    return ""
}

// The topic of the document in front: the plugin of an asset document, or
// the programs of a material; empty for the scene.
ai_guide_topic_in_front :: proc(s:^Session) -> string {
    front:=asset_document_in_front(s)
    if front==nil {return ""}
    if front.kind==asset.KIND_MATERIAL {return "material.program"}
    found:[PROVIDER_CAPACITY]Asset_Document_Provider
    plugins:[PROVIDER_CAPACITY]string
    for &provider,i in found[:provided_all(s,found[:],plugins[:])] {
        for kind in provider.kinds[:clamp(provider.count,0,len(provider.kinds))] {if kind==front.kind {return plugins[i]}}
    }
    return ""
}
