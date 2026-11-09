package render

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"

// What is drawn: meshes, lights, the camera, the sky and the effects of the
// image. render_sync brings the renderer of the application up to the world
// it runs on with the least work: nothing when no table it reads changed,
// the instances whose rows were written when only their place or color
// changed, the whole scene otherwise.

MATERIAL_SLOTS :: 8
POST_PROCESS_CAPACITY :: 8
MATERIAL_OVERRIDE_CAPACITY :: 16 // values among all the slots
MATERIAL_OVERRIDE_TEXTURES :: 8
HIGHLIGHT_LEVELS :: gpu.HIGHLIGHT_LEVELS
OUTLINE_STYLES :: gpu.OUTLINE_STYLES

Shape :: host.Shape

// mesh, when set, wins over the primitive shape. Shared: the game and the
// libraries that make what they draw (terrain chunks, broken pieces) write it,
// each on its own entities.
@(component,shared,description="Draws a mesh or primitive with its materials. A skinned mesh references its skeleton through the mesh asset.")
Mesh_Renderer :: struct {
    mesh:base.Asset_Id,
    shape:Shape,
    materials:[MATERIAL_SLOTS]base.Asset_Id,
}

@(component,shared,description="Overrides the rendered color and emission of this entity.")
Tint :: struct {
    color:[4]f32 `mirai:"color"`,
    emission:[3]f32 `mirai:"color"`, // added to the emission of its materials: a luminance, nits
}

TINT_DEFAULT :: Tint{color={1,1,1,1}}

// Not drawn, nor what hangs from it.
@(component,description="Hides this entity and its descendants from rendering.")
Hidden :: struct {}

// Hides the entity and what hangs from it, or shows them again, at the end of
// the function. A UI_Screen is shown and hidden this way.
set_hidden :: proc(table:^core.Table(Hidden),e:core.Entity,hidden:bool) {
    if e==core.NONE || core.has(table,e)==hidden {return}
    if hidden {core.add(table,e,Hidden{})} else {core.remove(table,e)}
}

// Its mesh is drawn by something else: the pieces of a broken destructible.
// The library that draws it instead adds and removes it.
@(component,description="The mesh is rendered by another system, such as destructible fragments.")
Drawn_Elsewhere :: struct {}

// Every light shines toward -Z of its entity, as a camera looks, and its
// shape follows the scale of its entity, as a mesh does. Units are those of
// KHR_lights_punctual: an intensity in candela is what it gives a point far
// along its axis whatever its size.

// The renderer takes the first one on that is not hidden.
@(component,single,replicated,description="Lights the whole scene from one direction, as the sun. Only one shines: turning one on turns off the one that shone, which shines again when it goes off.")
Sun :: struct {
    color:[3]f32 `mirai:"color"`,
    illuminance:f32 `mirai:"min=0,unit=lx"`,
    disc:bool, // the sun is seen in the sky
    height_fade:Sun_Height_Fade `mirai:"section=Height"`,
}

SUN_DEFAULT :: Sun{color={1,0.96,0.9},illuminance=100000,disc=true} // a clear noon

// A choice of art for a vertical world: the sun dims with the height of the
// view, from its illuminance at start to minimum times it at end and past it.
// The light of each layer comes from its own lights and volumes.
Sun_Height_Fade :: struct {
    enabled:bool,
    start:f32 `mirai:"unit=m"`, // the height of the view where it starts to dim
    end:f32 `mirai:"unit=m"`,   // where it reaches minimum, above or below start
    minimum:f32 `mirai:"min=0,max=1"`, // of its illuminance
}

// What multiplies the illuminance of a sun seen from a height: a step of
// SUN_FADE_STEPS of the way from start to end, so a view that moves a little
// lights the scene again only when the step changes.
sun_height_factor :: proc "contextless" (fade:Sun_Height_Fade,height:f32) -> f32 {
    if !fade.enabled || fade.start==fade.end {return 1}
    t:=math.round(clamp((height-fade.start)/(fade.end-fade.start),0,1)*SUN_FADE_STEPS)/SUN_FADE_STEPS
    return 1+(clamp(fade.minimum,0,1)-1)*t
}
SUN_FADE_STEPS :: 256

// A sphere of radius times the scale, drawn out into a capsule along the axis
// its scale stretches most.
@(component,description="Lights all around from a point. Stretching its entity makes a tube.")
Point_Light :: struct {
    color:[3]f32 `mirai:"color"`,
    intensity:f32 `mirai:"min=0,unit=cd"`,
    range:f32 `mirai:"min=0,unit=m"`,
    radius:f32 `mirai:"min=0,unit=m"`, // of the sphere that glows at scale 1; it softens shadows and widens highlights
}

POINT_LIGHT_DEFAULT :: Point_Light{color={1,0.92,0.8},intensity=1000,range=20,radius=0.05} // a 1000 W bulb

// A point light that lights a cone around -Z of its entity.
@(component,description="Lights a cone in front of it. Stretching its entity makes a tube.")
Spot_Light :: struct {
    color:[3]f32 `mirai:"color"`,
    intensity:f32 `mirai:"min=0,unit=cd"`,
    range:f32 `mirai:"min=0,unit=m"`,
    radius:f32 `mirai:"min=0,unit=m"`, // of the sphere that glows at scale 1; it softens shadows and widens highlights
    angle:f32 `mirai:"angle,min=0.0174532,max=1.5533431"`, // from its axis to the edge, 1° to 89°; it fades out over the last fifth
}

SPOT_LIGHT_DEFAULT :: Spot_Light{color={1,0.92,0.8},intensity=5000,range=20,radius=0.05,angle=mm.PI/6}

// The unit square of its entity, x by y; it lights the side its -z faces, so
// a larger one gives more light.
@(component,description="Lights from the unit square of its entity, on the side -Z faces. Its scale sizes it.")
Rect_Light :: struct {
    color:[3]f32 `mirai:"color"`,
    luminance:f32 `mirai:"min=0,unit=nit"`,
    range:f32 `mirai:"min=0,unit=m"`,
}

RECT_LIGHT_DEFAULT :: Rect_Light{color={1,0.92,0.8},luminance=5000,range=20} // a bright LED panel

// A rectangle that shows an image: the Rect_Light of its entity takes its
// color, across it, from the emission of the material its mesh is drawn with
// in `slot`, its texture laid on the square as on the face of a Cube that
// faces -Z.
@(component,description="Lights with the image a rectangular light's mesh shows: the emission of the material in a slot, as a screen lights a room.")
Light_Emission :: struct {
    slot:u8,
}

Camera_Projection :: enum u8 {Perspective,Orthographic}

// A view of the game. Which camera it is drawn from is chosen by the library
// that chooses cameras (View_Camera); without a choice, it is the last
// active one.
@(component,description="Defines a game view. The camera the player sees through is chosen by its seat and body; without one, the last active camera.")
Camera :: struct {
    fov:f32 `mirai:"angle,min=0"`, // vertical
    near:f32 `mirai:"min=0,unit=m"`,
    active:bool,                    // the view of the game when no library chooses one
    projection:Camera_Projection,
    height:f32 `mirai:"min=0,unit=m"`, // Orthographic: metres it covers from bottom to top
    shift:[2]f32,                      // where the center of the projection is, in halves of the view
    clip_plane:[4]f32,                 // world plane (normal, distance) nothing is drawn behind; zero: none
    layers:u32,                        // the layers of meshes it draws; 0: every one
    own_hidden:u32,                    // the layers of the body of its own player it does not draw, as its head seen from its eyes
}

// The layers the mesh of an entity is in, as bits: a camera draws it when it
// draws one of them. Without the component, the first layer.
@(component,description="Sets which layers this mesh is in. Cameras choose which layers they draw.")
Layers :: struct {
    mask:u32,
}

LAYERS_DEFAULT :: Layers{mask=1}

CAMERA_DEFAULT :: Camera{fov=60*mm.RAD_PER_DEG,near=0.1,active=true}

Exposure_Mode :: enum u8 {Auto,Manual}

// How Auto comes to a new light: in the same time whatever the change (Time),
// or at the same EV a second, so that a larger change takes longer (Speed, as
// in Unreal).
Exposure_Adaptation :: enum u8 {Time,Speed}

// How the camera of its entity exposes its image. Without it, as the
// View_Volume where it is. Auto meters the light on what the camera sees: a
// middle gray card there becomes middle gray. Manual takes aperture, shutter
// and ISO as a physical camera.
@(component,description="Exposes the image of this camera: metered from the light on what it sees (Auto) or from aperture, shutter time and ISO (Manual), plus a compensation in EV. It replaces the exposure of the View_Volume where the camera is.")
Exposure :: struct {
    mode:Exposure_Mode,
    compensation:f32 `mirai:"unit=EV"`,    // added to what the camera gives: +1 doubles the light of the image
    aperture:f32 `mirai:"min=0"`,          // Manual: f-number
    shutter:f32 `mirai:"min=0,unit=s"`,    // Manual: time the shutter is open
    iso:f32 `mirai:"min=0"`,               // Manual
    min_ev100:f32 `mirai:"unit=EV"`,       // Auto: the darkest scene it exposes for
    max_ev100:f32 `mirai:"unit=EV"`,       // Auto: the brightest
    adaptation_mode:Exposure_Adaptation,   // Auto: Time takes as long for any change of light; Speed changes as many EV a second, so a larger change takes longer, as in Unreal
    adaptation:f32 `mirai:"min=0,unit=s"`, // Auto: Time: to adapt 95 % of the way to less light, half that to more; Speed: for each EV of less light, a third of that for each EV of more, and exponentially within 1.5 EV
}

// Sunny 16 for Manual; for Auto, starlight to snow under the sun.
EXPOSURE_DEFAULT :: Exposure{mode=.Auto,aperture=16,shutter=1.0/125,iso=100,min_ev100=-6,max_ev100=18,adaptation=1}

// The exposure of the view through a camera.
exposure_of :: proc "contextless" (e:Exposure) -> core.View_Exposure {
    if e.mode==.Manual {return {mode=.Manual,ev100=gpu.ev100_of(e.aperture,e.shutter,e.iso),compensation=e.compensation,own=true}}
    return {mode=.Auto,compensation=e.compensation,range={e.min_ev100,max(e.min_ev100,e.max_ev100)},adaptation=e.adaptation,adaptation_mode=e.adaptation_mode==.Speed?.Speed:.Time,own=true}
}

Post_Process_Layer :: struct {
    material:base.Asset_Id, // a material whose program is a PostProcess one
    after_tonemap:bool,
    enabled:bool,
    fade:f32 `mirai:"min=0,max=1"`, // the share of the image it leaves as it read it: 0 the whole effect, 1 none
}


// What this entity alone shows of the materials of its slots: each value and
// texture is of the slot beside it. names are base.name_hash of a parameter of
// the program of the material, or of one of MATERIAL_VALUE_NAMES;
// texture_names, of a texture of the program or of one of MATERIAL_MAP_NAMES.
// With own_overlays its overlays replace those of the material of the first slot.
// Several functions write it, in loop order: each sets and drops only the
// names it gives (material_override_value_set, material_override_value_drop).
@(component,shared)
Material_Override :: struct {
    count:u32,
    slots:[MATERIAL_OVERRIDE_CAPACITY]u8,
    names:[MATERIAL_OVERRIDE_CAPACITY]u64,
    values:[MATERIAL_OVERRIDE_CAPACITY][4]f32,
    texture_count:u32,
    texture_slots:[MATERIAL_OVERRIDE_TEXTURES]u8,
    texture_names:[MATERIAL_OVERRIDE_TEXTURES]u64,
    textures:[MATERIAL_OVERRIDE_TEXTURES]base.Asset_Id, // 0 takes the texture away
    own_overlays:bool,
    overlay_count:u32,
    overlays:[asset.MATERIAL_MAX_OVERLAYS]asset.Material_Overlay,
}

// The outline of the editor's selection: 1 to HIGHLIGHT_LEVELS. It is drawn
// in place of the Outline of the entity.
@(component)
Highlight :: struct {
    level:u8 `mirai:"transient"`,
}

// The outline the game draws around an entity, seen through what is in front
// of it as its style says.
@(component)
Outline :: struct {
    style:u8 `mirai:"min=1,max=15"`, // of Outline_Styles
}

OUTLINE_DEFAULT :: Outline{style=1}

Outline_Style :: struct {
    color:[4]f32 `mirai:"color"`,     // display color; its alpha is the opacity
    fill:f32 `mirai:"min=0,max=1"`,   // above 0: a flat coat of the color over the whole surface, at that opacity, in place of the outline
    behind:f32 `mirai:"min=0,max=1"`, // what of it shows where another surface is in front of the entity
}

// The styles of the outlines of the game, the same in each of its scenes.
// width is the radius of their glow, in points of the window; 0 draws none.
@(storage,setting)
Outline_Styles :: struct {
    styles:[OUTLINE_STYLES]Outline_Style,
    width:f32 `mirai:"min=0,max=16"`,
}

OUTLINE_STYLES_DEFAULT :: Outline_Styles{styles={0..<OUTLINE_STYLES=Outline_Style{color={1,1,1,1},behind=0.35}},width=3}

// The outline level an instance of e is drawn with: the editor's Highlight in
// place of the game's Outline.
instance_outline :: proc(highlights:core.Read(Highlight),outlines:core.Read(Outline),e:core.Entity) -> u8 {
    if level,has_level:=core.get(highlights,e);has_level && level.level>0 {return min(level.level,HIGHLIGHT_LEVELS)}
    if outline,has_outline:=core.get(outlines,e);has_outline {return gpu.outline_level(outline.style)}
    return 0
}

// Where an entity and what hangs from it are drawn relative to their
// simulated place: what the network fades a correction with.
@(component)
Draw_Offset :: struct {
    offset:[3]f32 `mirai:"transient"`,
    rotation:mm.Quat `mirai:"transient"`,
}

MATERIAL_VALUE_NAMES :: [22]string{
    "base_color","opacity","metallic","roughness","emission","specular","ior","transmission","alpha_mode",
    "coat","coat_roughness","coat_color","coat_ior","fuzz","fuzz_color","fuzz_roughness","anisotropy","anisotropy_rotation","unlit",
    "emission_mode","diffuse_transmission","diffuse_transmission_color",
}

// The maps of the standard model as Material_Override names them, the paths
// of asset.material_revert.
MATERIAL_MAP_NAMES :: [asset.Material_Map_Kind]string{
    .Base_Color="maps.base_color",.Metallic_Roughness="maps.metallic_roughness",.Normal="maps.normal",.Emission="maps.emission",
    .Occlusion="maps.occlusion",.Specular="maps.specular",.Specular_Color="maps.specular_color",.Coat="maps.coat",
    .Coat_Roughness="maps.coat_roughness",.Coat_Normal="maps.coat_normal",.Fuzz_Color="maps.fuzz_color",
    .Fuzz_Roughness="maps.fuzz_roughness",.Anisotropy="maps.anisotropy",
    .Diffuse_Transmission="maps.diffuse_transmission",.Diffuse_Transmission_Color="maps.diffuse_transmission_color",
}

// Toward the sun of the editor's presets, a morning one behind who looks along -Z.
SUN_DIRECTION :: [3]f32{0.45,0.85,0.30}
SPOT_MIN :: 1*mm.RAD_PER_DEG
SPOT_MAX :: 89*mm.RAD_PER_DEG

// What the renderer has of the world it was last given. One per application,
// as the scene of the renderer it mirrors in its order: a world shown in
// place of another sets the scene again whatever each world kept.
@(storage,host,free="sync_free")
Render_Sync :: struct {
    world:core.World_Id, // the one the scene of the renderer holds
    instances:[dynamic]gpu.Instance_Desc, // those of drawn at the same index, then the visual instances of the application
    drawn:core.Entity_Map(Drawn),         // by entity whose mesh the renderer draws
    mesh_users:map[base.Asset_Id][dynamic]u32,
    changed:[dynamic]u32,
    lights:[dynamic]gpu.Light_Desc,
    sun:gpu.Sun_Desc,
    sun_fade:Sun_Height_Fade, // of the sun on
    sun_illuminance:f32,      // its own, before sun_height_factor
    sun_factor:f32,           // the sun_height_factor sun has
    moved:[dynamic]u32,
    moved_transforms:[dynamic]mm.Mat4,
    moved_anchors:[dynamic][3]f32, // what each is relative to (instance_place)
    lerping:[dynamic]u32, // instances whose world is between its previous and its transform
    tinted:[dynamic]u32,
    tinted_colors,tinted_emissions:[dynamic][3]f32,
    highlights:[dynamic]u8, // the outline level of each instance (instance_outline)
    previous_lights:[dynamic]gpu.Light_Desc,
    // What each table it reads was when it last looked: core.changes gives what moved since.
    seen_meshes,seen_worlds,seen_tints,seen_hidden,seen_elsewhere,seen_parents,seen_overrides,seen_offsets,seen_layers:core.Seen,
    owned:[VIEW_SLOTS]core.Entity, // the bodies of View_Bodies the instances are marked with
    coming:[dynamic]core.Entity, // scratch: the entities whose meshes start being drawn this frame
    taken:[dynamic]u32, // scratch: the places of instances that went which another took this frame (instances_taken_publish)
    shown:[dynamic]gpu.Instance_Desc, // scratch: the instances that came this frame and those of the application after them
    worlds_version,highlights_seen,lights_seen:u64,
    extras:[dynamic]gpu.Instance_Desc,
    composed:[dynamic]gpu.Instance_Desc,
    assets_structure,assets_appearance:u64,
    environment:gpu.Environment,
    postprocess:[POST_PROCESS_CAPACITY]Post_Process_Layer,
    outline_styles:Outline_Styles, // the last ones applied
    graphics:Graphics_Settings, // the last ones applied
    graphics_applied:bool,
    synced:bool,
    stats:Sync_Stats,
}

Sync_Stats :: struct {
    scene_sets,instance_updates,moves,tints,light_sets,highlight_sets,environment_sets,postprocess_sets,outline_sets:u64,
}

// What the instance of an entity was made from.
Drawn :: struct {
    shown:Mesh_Renderer,
    alpha:f32,
    derives:bool, // its rows derive from the values of its materials (an override, an alpha, layers)
    lerp:bool,    // in lerping
    changed:bool, // in changed
}

// Where a view is drawn from and its lens, when a library composes it.
View_Pose :: struct {
    position:[3]f32,
    rotation:mm.Quat,
    projection:Camera_Projection,
    fov,near,far,height:f32, // far 0: none (render.Camera.far)
    shift:[2]f32,
    layers:u32, // of the meshes it draws; 0: every one
    own_hidden:u32, // of the body of its own player, those it does not draw
    focus:f32, // m ahead of position to what it looks at (core.View.focus); 0: none
}

// The camera the view of the game is drawn from: the library that chooses
// cameras (engine/camera) is its only writer. none: the last active camera.
// While it blends into entity from another view, the view is drawn from pose
// (posed) and does not cut; cut says that the view of the same camera jumped.
// own: 1 + the local slot whose body (View_Bodies) is its own, which it fades
// out by fade; 0: none.
@(storage)
View_Camera :: struct {
    entity:core.Entity,
    posed:bool,
    cut:bool,
    own:u8,
    fade:f32,
    focus:f32, // of entity, posed or not (core.View.focus)
    pose:View_Pose,
}

VIEW_SLOTS :: 4 // local players, as input.LOCAL_CAPACITY

// The body of each local player: the meshes of it and of what hangs from it
// are marked as that player's, and a view of the player (core.View.own) fades
// them out and leaves out those in the layers it does not draw of its own
// body; its shadow and other views, mirrors and portals keep them. The library that chooses cameras
// is its only writer.
@(storage)
View_Bodies :: struct {
    bodies:[VIEW_SLOTS]core.Entity,
}

// The camera of the game becomes its view.
@(step="late",loops="game",stage="end",after="transforms_propagate")
camera_view :: proc(
    cameras:core.Read(Camera),exposures:core.Read(Exposure),worlds:core.Read(core.World_Transform),chosen:core.Ref(View_Camera),view:^core.View,app:^host.App,
) {
    // .ptr spelled out: a field reached through using in a ternary is loaded before its nil check (see ODIN_WORKAROUNDS).
    best:=chosen.ptr!=nil?chosen.ptr.entity:core.NONE
    if !core.has(cameras,best) || !core.has(worlds,best) {
        best=core.NONE
        for row in 0..<core.count(cameras) {
            if core.at(cameras,row).active && core.has(worlds,core.entity_at(cameras,row)) {best=core.entity_at(cameras,row)}
        }
    }
    posed:=chosen.ptr!=nil && best==chosen.entity && chosen.posed
    view_of_camera(view,cameras,exposures,worlds,best,host.app_scene_size(app),posed?&chosen.pose:nil,chosen.ptr!=nil && chosen.cut)
    if chosen.ptr!=nil && best==chosen.entity {view.own,view.fade,view.focus=chosen.own,chosen.fade,chosen.focus}
}

// The pose a camera is drawn from: where it is and its lens.
camera_pose :: proc "contextless" (c:Camera,world:mm.Transform) -> View_Pose {
    return {
        position=world.position,rotation=world.rotation,
        projection=c.projection==.Orthographic && c.height>0?.Orthographic:.Perspective,
        fov=c.fov>0?c.fov:60*mm.RAD_PER_DEG,near=c.near>0?c.near:0.1,far=0,height=c.height,shift=c.shift,layers=c.layers,own_hidden=c.own_hidden,
    }
}

// The view through the camera e, of size pixels; the default view when e is
// no placed camera. cut says that it jumped from the camera it had. With a
// pose, the view is drawn from it with the exposure and clip plane of e.
view_of_camera :: proc(view:^core.View,cameras:core.Read(Camera),exposures:core.Read(Exposure),worlds:core.Read(core.World_Transform),e:core.Entity,size:[2]f32,pose:^View_Pose=nil,cut:=false) {
    previous:=view.camera
    c,has_camera:=core.get(cameras,e)
    world,placed:=core.get(worlds,e)
    if has_camera && placed {
        p:=pose!=nil?pose^:camera_pose(c,world.transform)
        view.camera=e
        view.position,view.rotation=p.position,p.rotation
        view.fov,view.near,view.far=p.fov,p.near,p.far
        view.projection=p.projection==.Orthographic && p.height>0?.Orthographic:.Perspective
        view.height,view.shift,view.clip_plane,view.layers=p.height,p.shift,c.clip_plane,p.layers
        view.custom={}
        view.exposure={}
        view.own,view.fade,view.own_hidden,view.focus=0,0,p.own_hidden,p.focus
        if exposure,exposed:=core.get(exposures,e);exposed {view.exposure=exposure_of(exposure)}
    } else {view^=core.VIEW_DEFAULT}
    view.size=size
    view.cut=pose==nil && (previous!=view.camera || cut)
    view.carried={}
}
// The world id took another scene: the light the renderer kept for it, if it
// is not the one shown, is of the scene before.
world_light_forget :: proc(app:^host.App,id:core.World_Id) {
    if app.renderer!=nil {gpu.world_light_forget(app.renderer,world_key(id))}
}

// The world into the renderer. The camera and the time of the frame are
// those of the View, the Time and the Frame_Time of this world: host reads them. Another
// world, or this one replaced by another scene (rebuilt in a frame whose view
// is cut), is a discontinuity for the renderer: the light it gathered for the
// world before stays with that one (gpu.scene_world). A frame that draws only
// the UI (host.App.ui_only) leaves the scene as it is: a world drawn between
// frames meanwhile keeps it, and this one takes it back when it is drawn again.
@(step="render",loops="game editor")
render_sync :: proc(
    sync:^Render_Sync,app:^host.App,id:core.World_Id,frame:core.Frame_Time,view:core.View,
    worlds:core.Read(core.World_Transform),meshes:core.Read(Mesh_Renderer),tints:core.Read(Tint),
    hidden:core.Read(Hidden),elsewhere:core.Read(Drawn_Elsewhere),parents:core.Read(core.Parent),hierarchy:core.Ref(core.Hierarchy),
    suns:core.Read(Sun),points:core.Read(Point_Light),spots:core.Read(Spot_Light),rects:core.Read(Rect_Light),emissions:core.Read(Light_Emission),skies:core.Read(Sky),view_volumes:core.Read(View_Volume),volumes:core.Read(volume.Volume),
    overrides:core.Read(Material_Override),highlights:core.Read(Highlight),outlines:core.Read(Outline),outline_styles:core.Ref(Outline_Styles),
    offsets:core.Read(Draw_Offset),layers:core.Read(Layers),bodies:core.Ref(View_Bodies),preview:core.Ref(Environment_Preview),
    locals:core.Read(core.Transform),cameras:core.Read(Camera),
) {
    a:=app.assets
    r:=app.renderer
    if a==nil || r==nil || app.ui_only {return}
    owned:[VIEW_SLOTS]core.Entity
    if bodies.ptr!=nil {owned=bodies.bodies}
    t:=Sync_Tables{worlds,meshes,tints,hidden,elsewhere,parents,overrides,highlights,outlines,offsets,layers,locals,cameras,owned}
    defer sync.owned=owned
    for at in sync.changed {sync.drawn.values[at].changed=false}
    clear(&sync.changed)
    clear(&sync.tinted);clear(&sync.tinted_colors);clear(&sync.tinted_emissions)
    // What each table changed since the last frame: only the instances it touches are made again.
    c:=Sync_Changes{
        meshes=core.changes(meshes,&sync.seen_meshes),worlds=core.changes(worlds,&sync.seen_worlds),tints=core.changes(tints,&sync.seen_tints),
        hidden=core.changes(hidden,&sync.seen_hidden),elsewhere=core.changes(elsewhere,&sync.seen_elsewhere),parents=core.changes(parents,&sync.seen_parents),
        overrides=core.changes(overrides,&sync.seen_overrides),offsets=core.changes(offsets,&sync.seen_offsets),layers=core.changes(layers,&sync.seen_layers),
    }
    slot_textures_apply(app,a,t,frame)
    extras:=host.app_instances(app)
    extras_inherit(t,extras)
    rebuild:=!sync.synced || sync.world!=id || c.meshes.all || c.worlds.all || c.tints.all || c.hidden.all || c.elsewhere.all
    rebuild||=c.parents.all || c.overrides.all || c.offsets.all || c.layers.all
    releases,local_assets:=host.assets_structure_changes(a,sync.assets_structure)
    for change in releases {if change.id=={} {local_assets=false}}
    rebuild||=!local_assets || a.appearance!=sync.assets_appearance
    shown:=!sync.synced || sync.world!=id
    if shown || (rebuild && view.cut) {gpu.scene_world(r,world_key(id),!shown)}
    extras_changed:=!extras_unchanged(sync,extras)
    local_changes:=false
    if !rebuild {
        // What stops being drawn goes first, so that what follows finds every
        // instance where it stays: a mesh removed or turned off, with its
        // entity or alone, unplaced, or drawn elsewhere now.
        structure,kept:=false,true
        for e in c.meshes.gone {instance_drop(sync,t,e,&structure)}
        for e in c.worlds.gone {instance_drop(sync,t,e,&structure)}
        if core.version(elsewhere)>c.elsewhere.since {
            for row in 0..<core.count(elsewhere) {
                if core.changed(elsewhere,c.elsewhere,row) {instance_drop(sync,t,core.entity_at(elsewhere,row),&structure)}
            }
        }
        if structure {kept=instances_taken_publish(sync,r,extras)}
        rebuild=!kept
        // What starts being drawn: a mesh added or turned on, placed, or no longer drawn elsewhere.
        clear(&sync.coming)
        if !rebuild {
            if core.version(meshes)>c.meshes.since {
                for row in 0..<core.count(meshes) {
                    if !core.changed(meshes,c.meshes,row) {continue}
                    e:=core.entity_at(meshes,row)
                    if at:=instance_of(sync,e);at>=0 {
                        if sync.drawn.values[at].shown!=core.at(meshes,row) {instance_changed(sync,u32(at))}
                    } else if instance_wanted(t,e) {append(&sync.coming,e)}
                }
            }
            if core.version(worlds)>c.worlds.since {
                for row in 0..<core.count(worlds) {
                    if !core.changed(worlds,c.worlds,row) {continue}
                    if e:=core.entity_at(worlds,row);instance_of(sync,e)<0 && instance_wanted(t,e) {append(&sync.coming,e)}
                }
            }
            for e in c.elsewhere.gone {if instance_of(sync,e)<0 && instance_wanted(t,e) {append(&sync.coming,e)}}
            for change in releases {
                if users,known:=sync.mesh_users[change.id];known {
                    for at in users {instance_changed(sync,at)}
                    continue
                }
                // A material with other values: what derives a row from it derives it again.
                for drawn,at in sync.drawn.values {
                    if drawn.derives && instance_shows(sync,a,u32(at),change.id) {instance_changed(sync,u32(at))}
                }
            }
            // Hiding, showing, moving under another or offsetting redraws what hangs from it.
            changes_mark(sync,hierarchy,hidden,c.hidden,true)
            changes_mark(sync,hierarchy,parents,c.parents,true)
            changes_mark(sync,hierarchy,offsets,c.offsets,true)
            changes_mark(sync,hierarchy,overrides,c.overrides,false)
            changes_mark(sync,hierarchy,layers,c.layers,false)
            // A body of a local player taken or given back: its meshes are marked again.
            for body,i in owned {
                if body==sync.owned[i] {continue}
                if sync.owned[i]!=core.NONE {subtree_changed(sync,hierarchy,sync.owned[i])}
                if body!=core.NONE {subtree_changed(sync,hierarchy,body)}
            }
            tints_settle(sync,tints,c.tints)
            local_changes=structure || len(sync.coming)>0 || len(sync.changed)>0 || extras_changed
        }
        if local_changes {
            host.assets_appearance_begin(a)
            host.assets_commit(a)
            first:=len(sync.drawn.values)
            for e in sync.coming {
                if !instance_insert(sync,a,t,e,frame) {rebuild=true;break}
                host.assets_commit(a)
            }
            // What came goes to the renderer at once, the instances of the application after it.
            if !rebuild && len(sync.drawn.values)>first {rebuild=!instances_came_publish(sync,r,extras,first)}
            for at in sync.changed {
                if rebuild {break}
                e:=sync.drawn.entities[at]
                static,_:=core.get(meshes,e)
                world,_:=core.get(worlds,e)
                instance,alpha,derives,usable:=instance_make(a,t,e,static,world,frame)
                if !usable {rebuild=true;break}
                drawn:=&sync.drawn.values[at]
                if drawn.shown.mesh!=static.mesh {
                    mesh_user_remove(sync,drawn.shown.mesh,at)
                    mesh_user_add(sync,static.mesh,at)
                }
                // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
                sync.instances[at]=instance
                sync.highlights[at]=instance.highlight
                drawn.shown=static
                drawn.alpha=alpha
                drawn.derives=derives
                host.assets_commit(a)
                if !gpu.scene_update(r,at,{instance_shown(sync,int(at),extras)}) {rebuild=true;break}
                sync.stats.instance_updates+=1
            }
        }
    }
    // .ptr spelled out: a field reached through using in a ternary is loaded before its nil check (see ODIN_WORKAROUNDS).
    lights:=Lights{suns,points,spots,rects,preview.ptr!=nil?preview.ptr.sun:core.NONE}
    lights_seen:=u64(lights.preview)+lights_version(lights)+core.version(worlds)+core.layout(worlds)+core.version(hidden)+core.layout(hidden)+core.version(parents)+core.layout(parents)+core.version(emissions)+core.layout(emissions)
    // The material a screen shows may change with what is drawn over its mesh.
    if core.count(emissions)>0 && (extras_changed || local_changes) {lights_seen=~sync.lights_seen}
    sky_entity,sky,sky_found:=sky_previewed(skies,preview)
    if !sky_found {sky_entity,sky,sky_found=sky_active(skies,hidden,parents)}
    _,_,sunlit:=sun_on(worlds,lights,hidden,parents)
    environment:=sky_environment(sky_entity,sky,sky_found,sunlit,worlds,a)
    looked:=view.position
    if preview.ptr!=nil && preview.section!=core.NONE {
        if at,placed:=core.get(worlds,preview.section);placed {looked=at.position}
    }
    look:=view_volume_at(view_volumes,volumes,worlds,looked)
    exposure:=host.render_exposure(view_exposure_of(look))
    exposure.own=false
    gpu.scene_set_exposure(r,exposure)
    if rebuild {
        host.assets_appearance_begin(a)
        if !instances_build(sync,a,t,frame,len(extras)) {
            // Without memory for the instances the scene is empty until a frame makes it again.
            gpu.scene_set(r,nil,nil,{},environment)
            sync.synced=false
            return
        }
        resize(&sync.extras,len(extras));copy(sync.extras[:],extras)
        batches_retain(a,r)
        for instance in extras {
            host.assets_material_retain(a,u32(instance.material))
            for row in instance.slot_materials {if row>0 {host.assets_material_retain(a,row-1)}}
            for i in 0..<instance.overlays.count {host.assets_material_retain(a,u32(instance.overlays.entries[i].material))}
            append(&sync.instances,instance);append(&sync.highlights,instance.highlight)
        }
        lights_build(sync,a,worlds,lights,emissions,meshes,hidden,parents,extras,view.position.y)
        sync.lights_seen=lights_seen
        host.assets_appearance_end(a)
        host.assets_commit(a)
        sync.assets_structure,sync.assets_appearance=a.structure,a.appearance
        gpu.scene_set(r,instances_composed(sync,extras),sync.lights[:],sync.sun,environment)
        sync.environment=environment
        sync.highlights_seen=outlines_seen(t)
        sync.stats.scene_sets+=1
    } else {
        if extras_changed {
            patched:=true
            for previous in sync.extras {
                if !previous.replace_source {continue}
                at:=instance_of(sync,core.Entity(previous.object_id))
                if at<0 {continue}
                shown:=sync.instances[at]
                for extra in extras {if extra.replace_source && extra.object_id==previous.object_id {shown.hidden=true}}
                if !shown.hidden {patched&&=gpu.scene_update(r,u32(at),{shown})}
            }
            for extra in extras {
                if !extra.replace_source {continue}
                already:=false
                for previous in sync.extras {already||=previous.replace_source && previous.object_id==extra.object_id}
                if already {continue}
                at:=instance_of(sync,core.Entity(extra.object_id))
                if at<0 {continue}
                shown:=sync.instances[at];shown.hidden=true
                patched&&=gpu.scene_update(r,u32(at),{shown})
            }
            first:=len(sync.drawn.entities)
            for instance,i in extras {
                if i<len(sync.extras) && instance==sync.extras[i] {continue}
                patched&&=gpu.scene_update(r,u32(first+i),{instance})
                sync.stats.instance_updates+=1
            }
            if len(extras)<len(sync.extras) {patched&&=gpu.scene_update(r,u32(first+len(extras)),nil,true)}
            if resize(&sync.extras,len(extras))!=nil || resize(&sync.instances,first+len(extras))!=nil || resize(&sync.highlights,first+len(extras))!=nil {
                // Without memory for the visual instances a later frame makes the scene again.
                sync.synced=false
                return
            }
            copy(sync.extras[:],extras)
            copy(sync.instances[first:],extras)
            for instance,i in extras {sync.highlights[first+i]=instance.highlight}
            if !patched {gpu.scene_set(r,instances_composed(sync,extras),sync.lights[:],sync.sun,environment);sync.stats.scene_sets+=1}
        }
        if local_changes {
            batches_retain(a,r)
            for instance in sync.instances {
                host.assets_material_retain(a,u32(instance.material))
                for row in instance.slot_materials {if row>0 {host.assets_material_retain(a,row-1)}}
                for i in 0..<instance.overlays.count {host.assets_material_retain(a,u32(instance.overlays.entries[i].material))}
            }
            host.assets_appearance_end(a);host.assets_commit(a)
            sync.assets_structure,sync.assets_appearance=a.structure,a.appearance
        } else {sync.assets_structure=a.structure}
        moved:=instances_moved(sync,t,frame)
        for instance,i in extras {
            at:=len(sync.drawn.entities)+i
            if sync.instances[at].transform==instance.transform && sync.instances[at].anchor==instance.anchor {continue}
            sync.instances[at].transform,sync.instances[at].anchor=instance.transform,instance.anchor
            sync.extras[i]=instance
            append(&sync.moved,u32(at));append(&sync.moved_transforms,instance.transform);append(&sync.moved_anchors,instance.anchor)
            moved+=1
        }
        if moved>0 {
            gpu.scene_move(r,sync.moved[:],sync.moved_transforms[:],sync.moved_anchors[:])
            sync.stats.moves+=1
        }
        if len(sync.tinted)>0 {
            gpu.scene_tint(r,sync.tinted[:],sync.tinted_colors[:],sync.tinted_emissions[:])
            sync.stats.tints+=1
        }
        if lights_seen!=sync.lights_seen {
            sync.lights_seen=lights_seen
            previous_sun:=sync.sun
            resize(&sync.previous_lights,len(sync.lights))
            copy(sync.previous_lights[:],sync.lights[:])
            lights_build(sync,a,worlds,lights,emissions,meshes,hidden,parents,extras,view.position.y)
            if sync.sun!=previous_sun || !slice.equal(sync.lights[:],sync.previous_lights[:]) {
                gpu.scene_set_lights(r,sync.lights[:],sync.sun,environment)
                sync.environment=environment
                sync.stats.light_sets+=1
            }
        }
        if seen:=outlines_seen(t);seen!=sync.highlights_seen {
            sync.highlights_seen=seen
            for e,at in sync.drawn.entities {
                sync.highlights[at]=sync.instances[at].hidden?0:instance_outline(highlights,outlines,e)
                sync.instances[at].highlight=sync.highlights[at]
            }
            gpu.scene_set_highlights(r,sync.highlights[:])
            sync.stats.highlight_sets+=1
        }
        if factor:=sun_height_factor(sync.sun_fade,view.position.y);factor!=sync.sun_factor {
            sync.sun_factor=factor
            sync.sun.illuminance=sync.sun_illuminance*factor
            gpu.scene_set_environment(r,sync.sun,environment)
            sync.environment=environment
            sync.stats.environment_sets+=1
        }
        if environment!=sync.environment {
            gpu.scene_set_environment(r,sync.sun,environment)
            sync.environment=environment
            sync.stats.environment_sets+=1
        }
    }
    if rebuild || outline_styles.ptr^!=sync.outline_styles {
        gpu.renderer_set_outline_style(r,outline_style_of(outline_styles.ptr^))
        sync.outline_styles=outline_styles.ptr^
        sync.stats.outline_sets+=1
    }
    stack:=look.layers
    if rebuild || stack!=sync.postprocess {
        gpu.renderer_set_postprocesses(r,postprocess_effects(a,stack))
        sync.postprocess=stack
        sync.stats.postprocess_sets+=1
    }
    sync.worlds_version=core.version(worlds)
    sync.world=id
    sync.synced=true
}

// The tables render_sync makes instances from.
@(private)
Sync_Tables :: struct {
    worlds:core.Read(core.World_Transform),
    meshes:core.Read(Mesh_Renderer),
    tints:core.Read(Tint),
    hidden:core.Read(Hidden),
    elsewhere:core.Read(Drawn_Elsewhere),
    parents:core.Read(core.Parent),
    overrides:core.Read(Material_Override),
    highlights:core.Read(Highlight),
    outlines:core.Read(Outline),
    offsets:core.Read(Draw_Offset),
    layers:core.Read(Layers),
    locals:core.Read(core.Transform), // what instance_place chains what a camera carries from
    cameras:core.Read(Camera),
    owned:[VIEW_SLOTS]core.Entity, // View_Bodies
}

// What the tables of the outlines are: when it changes, the levels of the instances are read again.
@(private)
outlines_seen :: proc(t:Sync_Tables) -> u64 {return core.version(t.highlights)+core.layout(t.highlights)+core.version(t.outlines)+core.layout(t.outlines)}

// The renderer's outline of the game's styles. Values out of range are
// brought into it.
@(private)
outline_style_of :: proc(styles:Outline_Styles) -> (style:gpu.Highlight_Style) {
    style.width=clamp(styles.width,0,16)
    for s,i in styles.styles {
        for v,axis in s.color {style.colors[i][axis]=clamp(v,0,1)}
        style.fill[i]=clamp(s.fill,0,1)
        style.behind[i]=clamp(s.behind,0,1)
    }
    return
}

// What each of those tables changed since the last frame.
@(private)
Sync_Changes :: struct {meshes,worlds,tints,hidden,elsewhere,parents,overrides,offsets,layers:core.Changes}

@(private)
instance_changed :: proc(sync:^Render_Sync,at:u32) {
    drawn:=&sync.drawn.values[at]
    if drawn.changed {return}
    drawn.changed=true
    append(&sync.changed,at)
}

// The instances of the entities a table changed are made again; below, also
// those of what hangs from them.
@(private)
changes_mark :: proc(sync:^Render_Sync,h:core.Ref(core.Hierarchy),table:core.Read($T),c:core.Changes,below:bool) {
    mark :: proc(sync:^Render_Sync,h:core.Ref(core.Hierarchy),e:core.Entity,below:bool) {
        if below {subtree_changed(sync,h,e)}
        else if at:=instance_of(sync,e);at>=0 {instance_changed(sync,u32(at))}
    }
    for e in c.gone {mark(sync,h,e,below)}
    if core.version(table)<=c.since {return}
    for row in 0..<core.count(table) {
        if core.changed(table,c,row) {mark(sync,h,core.entity_at(table,row),below)}
    }
}

// The instances of e and of what hangs from it are made again.
@(private)
subtree_changed :: proc(sync:^Render_Sync,h:core.Ref(core.Hierarchy),e:core.Entity) {
    for at:=e;at!=core.NONE;at=core.subtree_next(h,e,at) {
        if instance:=instance_of(sync,at);instance>=0 {instance_changed(sync,u32(instance))}
    }
}

// What replaces the mesh of an entity, as a skinned copy of it, is drawn in
// its layers and as the body it is of, unless it says otherwise.
@(private)
extras_inherit :: proc(t:Sync_Tables,extras:[]gpu.Instance_Desc) {
    for &extra in extras {
        if !extra.replace_source || extra.object_id==0 {continue}
        e:=core.Entity(extra.object_id)
        if in_layers,has_layers:=core.get(t.layers,e);has_layers && extra.layers==0 {extra.layers=in_layers.mask}
        if extra.owner==0 {extra.owner=body_owner(t,e)}
    }
}

// 1 + the local slot whose body e is or hangs from; 0: none.
@(private)
body_owner :: proc(t:Sync_Tables,e:core.Entity) -> u8 {
    if t.owned=={} {return 0}
    for at:=e;at!=core.NONE; {
        for body,i in t.owned {
            if body==at {return u8(i+1)}
        }
        parent,has_parent:=core.get(t.parents,at)
        if !has_parent {break}
        at=parent.entity
    }
    return 0
}

// Whether the mesh of an entity is drawn: on, placed and not drawn by another library.
@(private)
instance_wanted :: proc(t:Sync_Tables,e:core.Entity) -> bool {
    return core.has(t.meshes,e) && core.has(t.worlds,e) && !core.has(t.elsewhere,e)
}

// The instance of the mesh of an entity, with its tint, values, visibility,
// outline and layers.
@(private)
instance_make :: proc(a:^host.Assets,t:Sync_Tables,e:core.Entity,static:Mesh_Renderer,world:core.World_Transform,frame:core.Frame_Time) -> (instance:gpu.Instance_Desc,alpha:f32,derives,ok:bool) {
    tint:=TINT_DEFAULT
    if value,has_tint:=core.get(t.tints,e);has_tint {tint=value}
    override,_:=core.get(t.overrides,e)
    anchor,transform:=instance_place(world,frame,t.offsets,t.parents,t.worlds,t.locals,t.cameras,e)
    instance,ok=mesh_instance(a,static,transform,tint,override)
    instance.anchor=anchor
    if !ok {return}
    instance.object_id=u64(e)
    instance.hidden=is_hidden(t.hidden,t.parents,e)
    if !instance.hidden {instance.highlight=instance_outline(t.highlights,t.outlines,e)}
    if in_layers,has_layers:=core.get(t.layers,e);has_layers {instance.layers=in_layers.mask}
    instance.owner=body_owner(t,e)
    return instance,tint.color.a,!material_override_empty(&override) || tint.color.a<1 || instance.overlays.count>0,true
}

// The textures that slots of meshes show this frame (host.Slot_Texture), in
// what draws each entity: what replaces its mesh, or else a copy of its mesh
// of the world that does. What drew each one is kept for the next frame
// (host.app_slot_shown).
@(private)
slot_textures_apply :: proc(app:^host.App,a:^host.Assets,t:Sync_Tables,frame:core.Frame_Time) {
    app.slots_shown_count=0
    for request in host.app_slot_textures(app) {
        e:=core.Entity(request.object)
        static,has_mesh:=core.get(t.meshes,e)
        if !has_mesh || request.texture==0 {continue}
        shown:^gpu.Instance_Desc
        for &extra in host.app_instances(app) {
            if extra.replace_source && extra.object_id==request.object {shown=&extra;break}
        }
        if shown==nil {
            world,placed:=core.get(t.worlds,e)
            if !placed {continue}
            instance,_,_,made:=instance_make(a,t,e,static,world,frame)
            if !made || instance.hidden {continue}
            instance.copy_owner,instance.replace_source=SLOT_TEXTURE_OWNER,true
            if !host.app_instance_add(app,instance) {continue}
            extras:=host.app_instances(app)
            shown=&extras[len(extras)-1]
        }
        row,at:=mesh_slot_row(a,static,shown,request.slot)
        values:=host.assets_material_values(a,row)
        if request.emission>0 {
            values.textures[.Emission]=request.texture
            values.emission=request.emission
            values.base_color=0
            values.textures[.Base_Color]=0
        } else {
            values.textures[.Base_Color]=request.texture
            values.base_color=1
        }
        derived,derives:=host.assets_material_derive(a,values)
        if !derives {continue}
        if at!=nil {at^=derived+1} else {shown.material=gpu.Material_Handle(derived)}
        if app.slots_shown_count<len(app.slots_shown) {
            app.slots_shown[app.slots_shown_count]={object=request.object,mesh=shown.mesh,anchor=shown.anchor,transform=shown.transform}
            app.slots_shown_count+=1
        }
    }
}

// What draws a mesh of the world with a host.Slot_Texture.
@(private)
SLOT_TEXTURE_OWNER :: u64(0x736c6f7400000000)

// The instance at as the renderer shows it: hidden while a visual instance replaces it.
@(private)
instance_shown :: proc(sync:^Render_Sync,at:int,extras:[]gpu.Instance_Desc) -> gpu.Instance_Desc {
    shown:=sync.instances[at]
    if at<len(sync.drawn.entities) {
        for extra in extras {if extra.replace_source && extra.object_id==shown.object_id {shown.hidden=true}}
    }
    return shown
}

// Takes out the instance of an entity that is no longer drawn; the renderer
// gets it with the others that go (instances_taken_publish).
@(private)
instance_drop :: proc(sync:^Render_Sync,t:Sync_Tables,e:core.Entity,structure:^bool) {
    at:=instance_of(sync,e)
    if at<0 || instance_wanted(t,e) {return}
    structure^=true
    instance_remove(sync,at)
}

// The last instance of the world takes the place of the one at, and the
// visual instances of the application, after those of the world, move down one.
@(private)
instance_remove :: proc(sync:^Render_Sync,at:int) {
    last:=len(sync.drawn.values)-1
    mesh_user_remove(sync,sync.drawn.values[at].shown.mesh,u32(at))
    for i:=len(sync.lerping)-1;i>=0;i-=1 {if int(sync.lerping[i])==at {unordered_remove(&sync.lerping,i)}}
    if at!=last {
        mesh_user_remove(sync,sync.drawn.values[last].shown.mesh,u32(last))
        mesh_user_add(sync,sync.drawn.values[last].shown.mesh,u32(at))
        for &moving in sync.lerping {if int(moving)==last {moving=u32(at)}}
        sync.instances[at]=sync.instances[last]
        sync.highlights[at]=sync.highlights[last]
    }
    core.entity_map_remove_at(&sync.drawn,at)
    ordered_remove(&sync.instances,last);ordered_remove(&sync.highlights,last)
    sync.stats.instance_updates+=1
    if at!=last {append(&sync.taken,u32(at))}
}

// Gives the renderer what instance_remove took out in the frame, at once:
// the places others took, and the visual instances of the application after
// those of the world, which end the scene. False when it refused them.
@(private)
instances_taken_publish :: proc(sync:^Render_Sync,r:^gpu.Renderer,extras:[]gpu.Instance_Desc) -> bool {
    world:=len(sync.drawn.values)
    ok:=true
    for at in sync.taken {if int(at)<world {ok&&=gpu.scene_update(r,at,{instance_shown(sync,int(at),extras)})}}
    clear(&sync.taken)
    return ok && gpu.scene_update(r,u32(world),sync.instances[world:],true)
}

// Gives the renderer the instances of the world from first, which came in
// the frame, and those of the application after them, at once. False when
// it refused them.
@(private)
instances_came_publish :: proc(sync:^Render_Sync,r:^gpu.Renderer,extras:[]gpu.Instance_Desc,first:int) -> bool {
    world:=len(sync.drawn.values)
    clear(&sync.shown)
    for at in first..<world {append(&sync.shown,instance_shown(sync,at,extras))}
    append(&sync.shown,..sync.instances[world:])
    return gpu.scene_update(r,u32(first),sync.shown[:])
}

// Puts the instance of an entity after those of the world; the visual
// instances of the application move up one. The renderer gets it with the
// others that come (instances_came_publish). False when its mesh is not
// usable yet: the scene is set again.
@(private)
instance_insert :: proc(sync:^Render_Sync,a:^host.Assets,t:Sync_Tables,e:core.Entity,frame:core.Frame_Time) -> bool {
    if instance_of(sync,e)>=0 || !instance_wanted(t,e) {return true}
    static,_:=core.get(t.meshes,e)
    world,_:=core.get(t.worlds,e)
    instance,alpha,derives,usable:=instance_make(a,t,e,static,world,frame)
    if !usable {return false}
    at:=len(sync.drawn.values)
    lerp:=world.previous!=world.transform
    // The instance of another generation of its index would stay in its place: the scene is set again.
    if core.entity_map_held(&sync.drawn,e)!=core.NONE {return false}
    if !room(&sync.instances) || !room(&sync.highlights) || !room(&sync.lerping) {return false}
    if _,kept:=core.entity_map_put(&sync.drawn,e,Drawn{shown=static,alpha=alpha,derives=derives,lerp=lerp});!kept {return false}
    if lerp {append(&sync.lerping,u32(at))}
    inject_at(&sync.instances,at,instance);inject_at(&sync.highlights,at,instance.highlight)
    mesh_user_add(sync,static.mesh,u32(at))
    sync.stats.instance_updates+=1
    return true
}

@(private)
instances_composed :: proc(sync:^Render_Sync,extras:[]gpu.Instance_Desc) -> []gpu.Instance_Desc {
    replaces:=false
    for instance in extras {replaces||=instance.replace_source && instance.object_id!=0}
    if !replaces {return sync.instances[:]}
    resize(&sync.composed,len(sync.instances))
    copy(sync.composed[:],sync.instances[:])
    for instance in extras {
        if !instance.replace_source || instance.object_id==0 {continue}
        e:=core.Entity(instance.object_id)
        at:=instance_of(sync,e)
        if at>=0 {sync.composed[at].hidden=true}
    }
    return sync.composed[:]
}

@(private)
extras_unchanged :: proc(sync:^Render_Sync,extras:[]gpu.Instance_Desc) -> bool {
    if len(sync.extras)!=len(extras) {return false}
    for instance,i in extras {
        previous:=sync.extras[i]
        previous.transform=instance.transform
        if previous!=instance {return false}
    }
    return true
}

// The entity an instance of the renderer was drawn for.
instance_entity :: proc(sync:^Render_Sync,instance:int) -> core.Entity {
    return instance>=0 && instance<len(sync.drawn.entities)?sync.drawn.entities[instance]:core.NONE
}

// Whether e or something above it is Hidden.
is_hidden :: proc(hidden:core.Read(Hidden),parents:core.Read(core.Parent),e:core.Entity) -> bool {
    return core.count(hidden)>0 && core.ancestor_with(parents,hidden,e)!=core.NONE
}

// Where an entity is drawn: between its last two simulated places, at the alpha of the frame.
drawn_transform :: proc(world:core.World_Transform,frame:core.Frame_Time) -> mm.Transform {
    if frame.alpha>=1 {return world.transform}
    t:=world.transform
    t.position=linalg.lerp(world.previous.position,world.transform.position,frame.alpha)
    t.rotation=mm.quat_nlerp(world.previous.rotation,world.transform.rotation,frame.alpha)
    t.scale=linalg.lerp(world.previous.scale,world.transform.scale,frame.alpha)
    return t
}

@(private)
offset_of_entity :: proc(offsets:core.Read(Draw_Offset),parents:core.Read(core.Parent),worlds:core.Read(core.World_Transform),e:core.Entity) -> (offset:Draw_Offset,pivot:[3]f32,ok:bool) {
    if core.count(offsets)==0 {return}
    at:=core.ancestor_with(parents,offsets,e)
    if at==core.NONE {return}
    found,_:=core.get(offsets,at)
    if found.offset=={} && (found.rotation==0 || found.rotation==1) {return}
    w,_:=core.get(worlds,at)
    return found,w.position,true
}

// Where an entity is drawn as instance_matrix places it, and what a camera
// carries composed from the camera instead (camera_carried): the transform
// relative to anchor, the place of the world the renderer takes it from
// (gpu.Instance_Desc.anchor).
instance_place :: proc(world:core.World_Transform,frame:core.Frame_Time,offsets:core.Read(Draw_Offset),parents:core.Read(core.Parent),worlds:core.Read(core.World_Transform),locals:core.Read(core.Transform),cameras:core.Read(Camera),e:core.Entity) -> (anchor:[3]f32,transform:mm.Mat4) {
    if eye,carried,ok:=camera_carried(frame,offsets,parents,worlds,locals,cameras,e);ok {return eye,mm.transform_matrix(carried)}
    return {},instance_matrix(world,frame,offsets,parents,worlds,e)
}

// Entities between a camera and what it carries, at most.
CARRIED_DEPTH :: 16

// What a camera carries (an entity under one, as a weapon in view) composed
// from the camera: the place of the camera, and its transform relative to
// that place, the transforms between them chained from its turn as
// World_Transform chains them from its place. Far from the centre of the
// world the step of f32 there lands on a World_Transform, a millimetre at 16
// km, and what is near the eye shakes by pixels as the camera moves; from the
// camera it keeps the step of its own size. World_Transform, the physics and
// what else reads them do not change. False for one no camera carries, one
// with a Draw_Offset, or one without the transforms it would be chained from.
camera_carried :: proc(frame:core.Frame_Time,offsets:core.Read(Draw_Offset),parents:core.Read(core.Parent),worlds:core.Read(core.World_Transform),locals:core.Read(core.Transform),cameras:core.Read(Camera),e:core.Entity) -> (eye:[3]f32,carried:mm.Transform,ok:bool) {
    if cameras.table==nil || locals.table==nil || core.count(cameras)==0 {return}
    chain:[CARRIED_DEPTH]core.Entity
    n:=0
    at:=e
    for at==e || !core.has(cameras,at) {
        if n==len(chain) || !core.has(locals,at) {return}
        chain[n]=at
        n+=1
        parent,has_parent:=core.get(parents,at)
        if !has_parent {return}
        at=parent.entity
    }
    if _,_,offset:=offset_of_entity(offsets,parents,worlds,e);offset {return}
    camera,placed:=core.get(worlds,at)
    if !placed {return}
    shown:=drawn_transform(camera,frame)
    carried=shown
    carried.position={}
    for i:=n-1;i>=0;i-=1 {
        local,_:=core.get(locals,chain[i])
        carried=mm.transform_compose(carried,core.to_math(local))
    }
    return shown.position,carried,true
}

instance_matrix :: proc(world:core.World_Transform,frame:core.Frame_Time,offsets:core.Read(Draw_Offset),parents:core.Read(core.Parent),worlds:core.Read(core.World_Transform),e:core.Entity) -> mm.Mat4 {
    shown:=drawn_transform(world,frame)
    if offset,pivot,ok:=offset_of_entity(offsets,parents,worlds,e);ok {
        rotation:=offset.rotation!=0?offset.rotation:1
        shown.position=pivot+offset.offset+mm.quat_rotate(rotation,shown.position-pivot)
        shown.rotation=rotation*shown.rotation
    }
    return mm.transform_matrix(shown)
}

// Room for one more, growing as append does. False without memory.
@(private)
room :: proc(a:^[dynamic]$E) -> bool {return len(a)<cap(a) || reserve(a,max(8,2*cap(a)))==nil}

// The instances of the meshes of the world, made again, with room for the
// visual instances of the application after them. False without memory.
@(private)
instances_build :: proc(sync:^Render_Sync,a:^host.Assets,t:Sync_Tables,frame:core.Frame_Time,extras:int) -> bool {
    clear(&sync.instances);clear(&sync.highlights);clear(&sync.lerping);clear(&sync.changed)
    core.entity_map_clear(&sync.drawn)
    if sync.mesh_users==nil {sync.mesh_users=make(map[base.Asset_Id][dynamic]u32)}
    for _,users in sync.mesh_users {delete(users)}
    clear(&sync.mesh_users)
    count:=core.count(t.meshes)
    if !core.entity_map_reserve(&sync.drawn,count) || reserve(&sync.instances,count+extras)!=nil || reserve(&sync.highlights,count+extras)!=nil ||
       reserve(&sync.lerping,count)!=nil || reserve(&sync.changed,count)!=nil {return false}
    for row in 0..<count {
        e:=core.entity_at(t.meshes,row)
        world,placed:=core.get(t.worlds,e)
        if !placed || core.has(t.elsewhere,e) {continue}
        static:=core.at(t.meshes,row)
        instance,alpha,derives,ok:=instance_make(a,t,e,static,world,frame)
        if !ok {continue}
        lerp:=world.previous!=world.transform
        if _,kept:=core.entity_map_put(&sync.drawn,e,Drawn{shown=static,alpha=alpha,derives=derives,lerp=lerp});!kept {return false}
        if lerp {append(&sync.lerping,u32(len(sync.instances)))}
        append(&sync.instances,instance);append(&sync.highlights,instance.highlight)
        mesh_user_add(sync,static.mesh,u32(len(sync.instances)-1))
    }
    return true
}

// Whether an instance shows a material: in a slot of its mesh, or as a layer
// of the material of its first slot.
@(private)
instance_shows :: proc(sync:^Render_Sync,a:^host.Assets,at:u32,material:base.Asset_Id) -> bool {
    static:=sync.drawn.values[at].shown
    mesh:=static.mesh!={}?host.assets_mesh(a,static.mesh):nil
    slots:=mesh!=nil?clamp(int(mesh.slot_count),1,MATERIAL_SLOTS):1
    first:base.Asset_Id
    for slot in 0..<slots {
        shown:=static.materials[slot]
        if shown=={} && mesh!=nil {shown=mesh.slot_materials[slot]}
        if shown==material {return true}
        if slot==0 {first=shown}
    }
    owner:=host.assets_material(a,first)
    if owner==nil {return false}
    for overlay in owner.overlays[:owner.overlay_count] {
        if overlay.material==material {return true}
    }
    return false
}

@(private)
mesh_user_add :: proc(sync:^Render_Sync,id:base.Asset_Id,at:u32) {
    if id=={} {return}
    users:=sync.mesh_users[id]
    append(&users,at)
    sync.mesh_users[id]=users
}

@(private)
mesh_user_remove :: proc(sync:^Render_Sync,id:base.Asset_Id,at:u32) {
    if id=={} {return}
    users,found:=sync.mesh_users[id]
    if !found {return}
    for value,i in users {if value==at {unordered_remove(&users,i);break}}
    if len(users)==0 {delete(users);delete_key(&sync.mesh_users,id)} else {sync.mesh_users[id]=users}
}

// The tables of the lights of a world.
Lights :: struct {
    suns:core.Read(Sun),
    points:core.Read(Point_Light),
    spots:core.Read(Spot_Light),
    rects:core.Read(Rect_Light),
    preview:core.Entity, // the sun drawn instead of the one on (Environment_Preview)
}

// Changes when a row of a table of lights or its layout changes.
lights_version :: proc(l:Lights) -> u64 {
    return core.version(l.suns)+core.layout(l.suns)+core.version(l.points)+core.layout(l.points)+core.version(l.spots)+core.layout(l.spots)+core.version(l.rects)+core.layout(l.rects)
}

// The sun that lights the world: the one previewed, or else the first not hidden.
@(private)
sun_on :: proc(worlds:core.Read(core.World_Transform),lights:Lights,hidden:core.Read(Hidden),parents:core.Read(core.Parent)) -> (sun:Sun,direction:[3]f32,found:bool) {
    if lights.preview!=core.NONE && lights.suns.table!=nil {
        if row:=core.raw_row(core.raw(lights.suns.table),lights.preview);row>=0 {
            if world,placed:=core.get(worlds,lights.preview);placed {
                return lights.suns.table.values[row],mm.quat_rotate(world.rotation,[3]f32{0,0,1}),true
            }
        }
    }
    for row in 0..<core.count(lights.suns) {
        e:=core.entity_at(lights.suns,row)
        world,placed:=core.get(worlds,e)
        if !placed || is_hidden(hidden,parents,e) {continue}
        return core.at(lights.suns,row),mm.quat_rotate(world.rotation,[3]f32{0,0,1}),true
    }
    return
}

@(private)
lights_build :: proc(sync:^Render_Sync,a:^host.Assets,worlds:core.Read(core.World_Transform),lights:Lights,emissions:core.Read(Light_Emission),meshes:core.Read(Mesh_Renderer),hidden:core.Read(Hidden),parents:core.Read(core.Parent),extras:[]gpu.Instance_Desc,height:f32) {
    clear(&sync.lights)
    sync.sun={}
    sync.sun_fade={}
    defer {
        sync.sun_illuminance=sync.sun.illuminance
        sync.sun_factor=sun_height_factor(sync.sun_fade,height)
        sync.sun.illuminance*=sync.sun_factor
    }
    if sun,direction,found:=sun_on(worlds,lights,hidden,parents);found {
        sync.sun={direction=direction,color=sun.color,illuminance=sun.illuminance,enabled=true,disc=sun.disc}
        sync.sun_fade=sun.height_fade
    }
    for row in 0..<core.count(lights.points) {
        e:=core.entity_at(lights.points,row)
        world,placed:=core.get(worlds,e)
        if !placed || is_hidden(hidden,parents,e) {continue}
        point:=core.at(lights.points,row)
        append(&sync.lights,sphere_desc(world,point.color,point.intensity,point.range,point.radius))
    }
    for row in 0..<core.count(lights.spots) {
        e:=core.entity_at(lights.spots,row)
        world,placed:=core.get(worlds,e)
        if !placed || is_hidden(hidden,parents,e) {continue}
        spot:=core.at(lights.spots,row)
        desc:=sphere_desc(world,spot.color,spot.intensity,spot.range,spot.radius)
        desc.direction,desc.cone=mm.quat_forward(world.rotation),spot.angle
        append(&sync.lights,desc)
    }
    for row in 0..<core.count(lights.rects) {
        e:=core.entity_at(lights.rects,row)
        world,placed:=core.get(worlds,e)
        if !placed || is_hidden(hidden,parents,e) {continue}
        desc:=rect_desc(world,core.at(lights.rects,row))
        if emission,shows:=core.get(emissions,e);shows {desc.material=emission_material(sync,a,meshes,extras,e,u32(emission.slot))}
        append(&sync.lights,desc)
    }
}

// A point or a spot in the world: a sphere the scale of its entity draws
// out, as thick as the axes it stretches less, as long as the one it
// stretches most. A spot adds where it points and its cone.
sphere_desc :: proc(world:core.World_Transform,color:[3]f32,intensity,range,radius:f32) -> (desc:gpu.Light_Desc) {
    desc={position=world.position,color=color,intensity=intensity,range=range}
    scale:=[3]f32{abs(world.scale.x),abs(world.scale.y),abs(world.scale.z)}
    longest:=0
    for axis in 1..<3 {if scale[axis]>scale[longest] {longest=axis}}
    across:=max(scale[(longest+1)%3],scale[(longest+2)%3])
    desc.radius=radius*across
    if radius>0 && scale[longest]>across*1.0001 {
        local:[3]f32
        local[longest]=1
        desc.axis=mm.quat_rotate(world.rotation,local)
        desc.length=2*radius*(scale[longest]-across)
    }
    return
}

// A rectangle in the world: the unit square of its entity, lighting the side
// -Z faces. Its width runs along -X: seen from that side, its right.
rect_desc :: proc(world:core.World_Transform,rect:Rect_Light) -> gpu.Light_Desc {
    return {
        position=world.position,color=rect.color,intensity=rect.luminance,range=rect.range,
        direction=mm.quat_forward(world.rotation),axis=mm.quat_rotate(world.rotation,[3]f32{-1,0,0}),
        size={abs(world.scale.x),abs(world.scale.y)},
    }
}

// The material a rectangle of Light_Emission shows: the one the mesh of its
// entity is drawn with in that slot, by what replaces it in this frame if
// something does (a screen of a plugin). 0: none.
@(private)
emission_material :: proc(sync:^Render_Sync,a:^host.Assets,meshes:core.Read(Mesh_Renderer),extras:[]gpu.Instance_Desc,e:core.Entity,slot:u32) -> gpu.Material_Handle {
    static,has_mesh:=core.get(meshes,e)
    if !has_mesh {return 0}
    shown:gpu.Instance_Desc
    found:=false
    for extra in extras {if extra.replace_source && extra.object_id==u64(e) {shown,found=extra,true;break}}
    if !found {
        at:=instance_of(sync,e)
        if at<0 {return 0}
        shown=sync.instances[at]
    }
    row,_:=mesh_slot_row(a,static,&shown,slot)
    return gpu.Material_Handle(row)
}

// The row of the material a mesh is drawn with in a slot, and where the
// instance keeps it when it says (nil: its global material).
mesh_slot_row :: proc(a:^host.Assets,static:Mesh_Renderer,instance:^gpu.Instance_Desc,slot:u32) -> (row:u32,at:^u32) {
    mesh:=static.mesh!={}?host.assets_mesh(a,static.mesh):host.assets_shape(a,static.shape)
    if mesh==nil || mesh.slot_count==0 {return u32(instance.material),nil}
    index:=min(int(slot),int(mesh.slot_count)-1,len(instance.slot_materials)-1)
    at=&instance.slot_materials[index]
    if at^>0 {return at^-1,at}
    material:=index<MATERIAL_SLOTS?static.materials[index]:base.Asset_Id{}
    return host.assets_material_row(a,material!={}?material:mesh.slot_materials[index]),at
}

// The instance of an entity; -1 when it is not drawn.
@(private)
instance_of :: proc(sync:^Render_Sync,e:core.Entity) -> int {return core.entity_map_index(&sync.drawn,e)}

// Keeps through a round of derived rows those the batches of the plugins
// draw with: they stay as they were set, without being set again.
@(private)
batches_retain :: proc(a:^host.Assets,r:^gpu.Renderer) {
    rows:=make([dynamic]u32,context.temp_allocator)
    gpu.batches_materials(r,&rows)
    for row in rows {host.assets_material_retain(a,row)}
}

// The instances whose world rows were written since the last sync, and
// those between two places, which move with the time of the frame.
@(private)
instances_moved :: proc(sync:^Render_Sync,t:Sync_Tables,frame:core.Frame_Time) -> int {
    clear(&sync.moved);clear(&sync.moved_transforms);clear(&sync.moved_anchors)
    worlds:=t.worlds
    place :: proc(sync:^Render_Sync,t:Sync_Tables,world:core.World_Transform,at:int,frame:core.Frame_Time) {
        anchor,m:=instance_place(world,frame,t.offsets,t.parents,t.worlds,t.locals,t.cameras,sync.drawn.entities[at])
        if sync.instances[at].transform==m && sync.instances[at].anchor==anchor {return}
        sync.instances[at].transform,sync.instances[at].anchor=m,anchor
        append(&sync.moved,u32(at));append(&sync.moved_transforms,m);append(&sync.moved_anchors,anchor)
    }
    if core.version(worlds)!=sync.worlds_version {
        for row in 0..<core.count(worlds) {
            if core.stamp(worlds,row)<=sync.worlds_version {continue}
            at:=instance_of(sync,core.entity_at(worlds,row))
            if at<0 {continue}
            world:=core.at(worlds,row)
            lerp:=world.previous!=world.transform
            drawn:=&sync.drawn.values[at]
            if lerp && !drawn.lerp {append(&sync.lerping,u32(at))}
            drawn.lerp=lerp
            place(sync,t,world,at,frame)
        }
    }
    for i:=len(sync.lerping)-1;i>=0;i-=1 {
        at:=int(sync.lerping[i])
        if !sync.drawn.values[at].lerp {
            unordered_remove(&sync.lerping,i)
            continue
        }
        world,_:=core.get(worlds,sync.drawn.entities[at])
        place(sync,t,world,at,frame)
    }
    return len(sync.moved)
}

@(private)
// The tints written, added or removed: a color changed in place, an opacity or
// a tint gone by making the instance again.
tints_settle :: proc(sync:^Render_Sync,tints:core.Read(Tint),c:core.Changes) {
    clear(&sync.tinted);clear(&sync.tinted_colors);clear(&sync.tinted_emissions)
    for e in c.gone {if at:=instance_of(sync,e);at>=0 {instance_changed(sync,u32(at))}}
    if core.version(tints)<=c.since {return}
    for row in 0..<core.count(tints) {
        if !core.changed(tints,c,row) {continue}
        at:=instance_of(sync,core.entity_at(tints,row))
        if at<0 {continue}
        tint:=core.at(tints,row)
        if tint.color.a!=sync.drawn.values[at].alpha {instance_changed(sync,u32(at));continue}
        instance:=&sync.instances[at]
        if instance.tint==tint.color.rgb && instance.emission==tint.emission {continue}
        instance.tint,instance.emission=tint.color.rgb,tint.emission
        append(&sync.tinted,u32(at));append(&sync.tinted_colors,tint.color.rgb);append(&sync.tinted_emissions,tint.emission)
    }
}

// Puts one named value over the values of a material: a parameter of its
// program when the program declares one with that name, and otherwise the
// value of the standard model with it. False for a name that is neither.
material_value_apply :: proc(values:^gpu.Material_Desc,program:^gpu.Program,name:u64,value:[4]f32) -> bool {
    if program!=nil {
        for &parameter in program.parameters {
            if parameter.kind==.Texture || base.name_hash(parameter.name)!=name {continue}
            gpu.program_parameter_set(&values.custom_params,&parameter,{f64(value.x),f64(value.y),f64(value.z),f64(value.w)})
            return true
        }
    }
    return material_standard_apply(&values.info,name,value)
}

// Puts a value of the standard model, by the name_hash of one of
// MATERIAL_VALUE_NAMES, over the values of a material. False for another name.
material_standard_apply :: proc(values:^asset.Material_Info,name:u64,value:[4]f32) -> bool {
    names:=MATERIAL_VALUE_NAMES
    for standard,index in names {
        if base.name_hash(standard)!=name {continue}
        switch index {
        case 0: values.base_color=value.xyz
        case 1: values.opacity=value.x
        case 2: values.metallic=value.x
        case 3: values.roughness=value.x
        case 4: values.emission=value.xyz
        case 5: values.specular_factor=value.x
        case 6: values.ior=value.x
        case 7: values.transmission=value.x
        case 8: values.alpha_mode=asset.Alpha_Mode(clamp(int(value.x+0.5),0,len(asset.Alpha_Mode)-1))
        case 9: values.coat.weight=value.x
        case 10: values.coat.roughness=value.x
        case 11: values.coat.color=value.xyz
        case 12: values.coat.ior=value.x
        case 13: values.fuzz.weight=value.x
        case 14: values.fuzz.color=value.xyz
        case 15: values.fuzz.roughness=value.x
        case 16: values.anisotropy.amount=value.x
        case 17: values.anisotropy.rotation=value.x
        case 18: values.unlit=value.x>0.5
        case 19: values.emission_mode=asset.Emission_Mode(clamp(int(value.x+0.5),0,len(asset.Emission_Mode)-1))
        case 20: values.diffuse_transmission.weight=value.x
        case 21: values.diffuse_transmission.color=value.xyz
        }
        return true
    }
    return false
}

// The Surface program a material of the table names; nil for the standard model.
surface_program :: proc(a:^host.Assets,id:u32) -> ^gpu.Program {
    if id==0 || a==nil || a.renderer==nil {return nil}
    for &candidate in gpu.renderer_programs(a.renderer) {
        if candidate.id==id && candidate.domain==.Surface {return &candidate}
    }
    return nil
}

@(private)
overridden_row :: proc(a:^host.Assets,row:u32,override:^Material_Override,slot:int) -> u32 {
    values:=host.assets_material_values(a,row)
    material_override_apply(a,&values,override,slot)
    derived,ok:=host.assets_material_derive(a,values)
    return ok?derived:row
}

// Whether an entity changes nothing of its materials.
material_override_empty :: proc "contextless" (o:^Material_Override) -> bool {
    return o.count==0 && o.texture_count==0 && !o.own_overlays
}

// Whether an entity changes a value or a texture of the material of a slot.
material_override_changes :: proc "contextless" (o:^Material_Override,slot:int) -> bool {
    for stored in o.slots[:min(int(o.count),len(o.slots))] {
        if int(stored)==slot {return true}
    }
    for stored in o.texture_slots[:min(int(o.texture_count),len(o.texture_slots))] {
        if int(stored)==slot {return true}
    }
    return false
}

// Puts the values and the textures an entity gives a slot over those of its
// material, loading the textures.
material_override_apply :: proc(a:^host.Assets,values:^gpu.Material_Desc,o:^Material_Override,slot:int) {
    program:=surface_program(a,values.program_id)
    for name,i in o.names[:min(int(o.count),len(o.names))] {
        if int(o.slots[i])==slot {material_value_apply(values,program,name,o.values[i])}
    }
    maps:=MATERIAL_MAP_NAMES
    each: for name,i in o.texture_names[:min(int(o.texture_count),len(o.texture_names))] {
        if int(o.texture_slots[i])!=slot {continue}
        loaded:=host.assets_texture_image(a,o.textures[i])
        handle:=loaded!=nil && !loaded.failed?loaded.handle:0
        if program!=nil {
            for &parameter in program.parameters {
                if parameter.kind!=.Texture || base.name_hash(parameter.name)!=name {continue}
                gpu.program_parameter_set_texture(a.renderer,&values.custom_params,&parameter,handle)
                continue each
            }
        }
        for map_name,kind in maps {
            if base.name_hash(map_name)!=name {continue}
            asset.material_maps(&values.maps)[kind].texture=o.textures[i]
            // A program reads the normal map alone of the maps.
            if program==nil || kind==.Normal {values.textures[kind]=handle}
            continue each
        }
    }
}

// The texture an entity gives a map or a texture of the program of a slot, by its name.
material_override_texture :: proc "contextless" (o:^Material_Override,slot:int,name:u64) -> (texture:base.Asset_Id,found:bool) {
    for stored,i in o.texture_names[:min(int(o.texture_count),len(o.texture_names))] {
        if stored==name && int(o.texture_slots[i])==slot {return o.textures[i],true}
    }
    return
}

// Where an entity keeps the value it gives a name of a slot; -1 without one.
material_override_find :: proc "contextless" (o:^Material_Override,slot:int,name:u64) -> int {
    for stored,i in o.names[:min(int(o.count),len(o.names))] {
        if stored==name && int(o.slots[i])==slot {return i}
    }
    return -1
}

// Gives a name of a slot a value, leaving the other names as they are; false
// when the override holds MATERIAL_OVERRIDE_CAPACITY values of other names.
material_override_value_set :: proc "contextless" (o:^Material_Override,slot:int,name:u64,value:[4]f32) -> bool {
    if at:=material_override_find(o,slot,name);at>=0 {
        o.values[at]=value
        return true
    }
    if int(o.count)>=len(o.names) || slot<0 || slot>=MATERIAL_SLOTS {return false}
    o.slots[o.count],o.names[o.count],o.values[o.count]=u8(slot),name,value
    o.count+=1
    return true
}

// Takes the value of one name of a slot away: that of the material shows again.
material_override_value_drop :: proc "contextless" (o:^Material_Override,slot:int,name:u64) {
    count:=min(int(o.count),len(o.names))
    if i:=material_override_find(o,slot,name);i>=0 {
        o.slots[i],o.names[i],o.values[i]=o.slots[count-1],o.names[count-1],o.values[count-1]
        o.slots[count-1],o.names[count-1],o.values[count-1]=0,0,{}
        o.count=u32(count-1)
    }
}

// Forgets what the renderer has: the next sync sends everything.
sync_reset :: proc(sync:^Render_Sync) {sync.synced=false}

// A World that is freed while the renderer shows it takes its instances
// with it; the World shown next is given whole.
@(step="release")
render_release :: proc(sync:^Render_Sync,id:core.World_Id,app:^host.App) {
    if sync.world!=id {return}
    sync.world,sync.synced={},false
    if app.renderer!=nil {gpu.scene_set(app.renderer,nil,nil,sync.sun,sync.environment)}
}

sync_free :: proc(sync:^Render_Sync) {
    for _,users in sync.mesh_users {delete(users)}
    delete(sync.mesh_users)
    sync.mesh_users=nil
    core.value_free(sync,type_info_of(Render_Sync))
}

// The same geometry and appearance for world entities and temporary visual instances.
mesh_instance :: proc(a:^host.Assets,static:Mesh_Renderer,transform:mm.Mat4,tint:=TINT_DEFAULT,override:Material_Override={}) -> (instance:gpu.Instance_Desc,ok:bool) {
    override:=override
    mesh:=static.mesh!={}?host.assets_mesh(a,static.mesh):host.assets_shape(a,static.shape)
    if mesh==nil || mesh.handle==host.ASSETS_MESH_NONE {return {},false}
    instance=gpu.Instance_Desc{mesh=mesh.handle,transform=transform,tint=tint.color.rgb,emission=tint.emission}
    alpha:=tint.color.a
    shown:=static.materials[0]
    if mesh.slot_count==0 {
        material:=host.assets_material_row(a,shown)
        if material_override_changes(&override,0) {material=overridden_row(a,material,&override,0)}
        instance.material=gpu.Material_Handle(alpha<1?host.assets_material_faded(a,material,alpha):material)
    } else {
        if shown=={} {shown=mesh.slot_materials[0]}
        for slot in 0..<mesh.slot_count {
            material:=slot<MATERIAL_SLOTS?static.materials[slot]:base.Asset_Id{}
            own:=material_override_changes(&override,int(slot))
            if alpha<1 || own {
                shown_row:=host.assets_material_row(a,material!={}?material:mesh.slot_materials[slot])
                if own {shown_row=overridden_row(a,shown_row,&override,int(slot))}
                if alpha<1 {shown_row=host.assets_material_faded(a,shown_row,alpha)}
                instance.slot_materials[slot]=shown_row+1
            } else if material!={} {
                instance.slot_materials[slot]=host.assets_material_row(a,material)+1
            }
        }
    }
    if override.own_overlays {
        instance.overlays=host.assets_overlays(a,shown,override.overlays[:min(int(override.overlay_count),len(override.overlays))])
    } else {
        instance.overlays=host.assets_material_overlays(a,shown)
    }
    return instance,true
}
