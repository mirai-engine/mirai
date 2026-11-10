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
MATERIAL_VALUES_CAPACITY :: gpu.INSTANCE_VALUES_MAX // values among all the slots
MATERIAL_VALUES_TEXTURES :: 8
FRAME_VALUES_CAPACITY :: host.FRAME_MESH_SHOWN_CAPACITY
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


// What this entity alone shows of its materials. color multiplies their base
// color and its alpha fades the entity; emission is added to their light.
// Each value and texture is of the slot beside it, by the base.name_hash of
// its name: a parameter or a texture of the program of the material of that
// slot, or one of MATERIAL_VALUE_FIELDS or MATERIAL_MAP_NAMES. With
// own_overlays its overlays replace those of the material of the first slot.
// Several functions write it, in loop order: each sets and drops only the
// names it gives. The color, the emission, the numbers of a program and the
// values of the standard model an instance holds (material_value_instanced)
// go to the instance of the entity, given in place when they change; what
// changes how the surface is drawn (a texture, overlays, an alpha below 1,
// another value) makes the entity show a row of the material table of its
// own, which the entities that give the same share.
@(component,shared,description="What this entity alone shows of its materials: a color that multiplies theirs, light added to theirs, and values and textures by name.")
Material_Values :: struct {
    color:[4]f32 `mirai:"color"`,
    emission:[3]f32 `mirai:"color"`, // added to the emission of its materials: a luminance, nits
    count:u32 `mirai:"hidden"`,
    slots:[MATERIAL_VALUES_CAPACITY]u8 `mirai:"hidden"`,
    names:[MATERIAL_VALUES_CAPACITY]u64 `mirai:"hidden"`,
    values:[MATERIAL_VALUES_CAPACITY][4]f32 `mirai:"hidden"`,
    texture_count:u32 `mirai:"hidden"`,
    texture_slots:[MATERIAL_VALUES_TEXTURES]u8 `mirai:"hidden"`,
    texture_names:[MATERIAL_VALUES_TEXTURES]u64 `mirai:"hidden"`,
    textures:[MATERIAL_VALUES_TEXTURES]base.Asset_Id `mirai:"hidden"`, // 0 takes the texture away
    shown:[MATERIAL_VALUES_TEXTURES]gpu.Texture_Handle `mirai:"transient"`, // a texture the renderer made at run time, in place of the asset; 0: none
    own_overlays:bool `mirai:"hidden"`,
    overlay_count:u32 `mirai:"hidden"`,
    overlays:[asset.MATERIAL_MAX_OVERLAYS]asset.Material_Overlay `mirai:"hidden"`,
}

MATERIAL_VALUES_DEFAULT :: Material_Values{color={1,1,1,1}}

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

// The values of the standard model an entity gives by name, and where
// asset.Material_Info holds each: a number, a color, a flag or, with modes,
// an enum of a byte with that many members.
Material_Value_Field :: struct {
    name:string,
    offset:uintptr,
    kind:enum u8 {Number,Color,Flag,Mode},
    modes:u8,
}
MATERIAL_VALUE_FIELDS :: [22]Material_Value_Field{
    {"base_color",offset_of(asset.Material_Info,base_color),.Color,0},{"opacity",offset_of(asset.Material_Info,opacity),.Number,0},
    {"metallic",offset_of(asset.Material_Info,metallic),.Number,0},{"roughness",offset_of(asset.Material_Info,roughness),.Number,0},
    {"emission",offset_of(asset.Material_Info,emission),.Color,0},{"specular",offset_of(asset.Material_Info,specular_factor),.Number,0},
    {"ior",offset_of(asset.Material_Info,ior),.Number,0},{"transmission",offset_of(asset.Material_Info,transmission),.Number,0},
    {"alpha_mode",offset_of(asset.Material_Info,alpha_mode),.Mode,len(asset.Alpha_Mode)},
    {"coat",offset_of(asset.Material_Info,coat)+offset_of(asset.Material_Coat,weight),.Number,0},{"coat_roughness",offset_of(asset.Material_Info,coat)+offset_of(asset.Material_Coat,roughness),.Number,0},
    {"coat_color",offset_of(asset.Material_Info,coat)+offset_of(asset.Material_Coat,color),.Color,0},{"coat_ior",offset_of(asset.Material_Info,coat)+offset_of(asset.Material_Coat,ior),.Number,0},
    {"fuzz",offset_of(asset.Material_Info,fuzz)+offset_of(asset.Material_Fuzz,weight),.Number,0},{"fuzz_color",offset_of(asset.Material_Info,fuzz)+offset_of(asset.Material_Fuzz,color),.Color,0},
    {"fuzz_roughness",offset_of(asset.Material_Info,fuzz)+offset_of(asset.Material_Fuzz,roughness),.Number,0},
    {"anisotropy",offset_of(asset.Material_Info,anisotropy)+offset_of(asset.Material_Anisotropy,amount),.Number,0},
    {"anisotropy_rotation",offset_of(asset.Material_Info,anisotropy)+offset_of(asset.Material_Anisotropy,rotation),.Number,0},
    {"unlit",offset_of(asset.Material_Info,unlit),.Flag,0},{"emission_mode",offset_of(asset.Material_Info,emission_mode),.Mode,len(asset.Emission_Mode)},
    {"diffuse_transmission",offset_of(asset.Material_Info,diffuse_transmission)+offset_of(asset.Material_Diffuse_Transmission,weight),.Number,0},
    {"diffuse_transmission_color",offset_of(asset.Material_Info,diffuse_transmission)+offset_of(asset.Material_Diffuse_Transmission,color),.Color,0},
}

// The maps of the standard model as Material_Values names them, the paths
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

// What the renderer has of the world it was last given, which it cannot
// answer itself: the entity of each instance and what it was made from. The
// instances of the scene of the renderer are those of drawn, at the same
// index, then the visual instances of the application (extras). One per
// application: a world shown in place of another sets the scene again
// whatever each world kept.
@(storage,host,free="sync_free")
Render_Sync :: struct {
    world:core.World_Id, // the one the scene of the renderer holds
    drawn:core.Entity_Map(Drawn), // by entity whose mesh the renderer draws
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
    deriving:[dynamic]u32, // instances whose rows derive from the values of their materials (Drawn.derives)
    tinted:[dynamic]u32, // instances whose Material_Values changed and that show the same rows: what they hold is given in place
    tinted_colors,tinted_emissions:[dynamic][3]f32,
    tinted_values:[dynamic]gpu.Instance_Material_Values,
    frame_values:[FRAME_VALUES_CAPACITY]Frame_Values, // values_show: what entities show this frame alone
    frame_count:int,
    highlights:[dynamic]u8, // scratch: the outline level of each instance, when the outlines change
    previous_lights:[dynamic]gpu.Light_Desc,
    // What each table it reads was when it last looked: core.changes gives what moved since.
    seen_meshes,seen_worlds,seen_values,seen_hidden,seen_elsewhere,seen_parents,seen_offsets,seen_layers:core.Seen,
    owned:[VIEW_SLOTS]core.Entity, // the bodies of View_Bodies the instances are marked with
    coming:[dynamic]core.Entity, // scratch: the entities whose meshes start being drawn this frame
    taken:[dynamic]Taken, // scratch: the places of instances that went which another took this frame (instances_taken_publish)
    shown:[dynamic]gpu.Instance_Desc, // scratch: the instances a frame gives the renderer at once, those of a scene it sets or those that came, and those of the application after them
    lights_seen:[8]core.Seen, // suns, points, spots, rects, worlds, hidden, parents and emissions when the lights were last looked at
    lights_preview:core.Entity,
    lights_stale:bool, // what the lights derive from changed and they were not made again yet
    highlights_seen:[2]core.Seen,
    highlights_stale:bool,
    extras:[dynamic]gpu.Instance_Desc, // the visual instances of the application the renderer has, after those of drawn
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

// What an entity shows in a frame over its Material_Values (values_show).
Frame_Values :: struct {
    entity:core.Entity,
    values:Material_Values,
}

// Gives an entity, for this frame alone, values and textures over its
// Material_Values: what is only drawn and no table holds, as the texture a
// panel of the interface is drawn into. Whatever draws the entity shows
// them: its mesh of the world, or what replaces it, as a skinned copy; what
// drew it is kept for the next frame (host.extras_mesh_shown). Before
// render_sync; false without room for another one.
values_show :: proc(sync:^Render_Sync,e:core.Entity,values:Material_Values) -> bool {
    if sync.frame_count>=len(sync.frame_values) {return false}
    sync.frame_values[sync.frame_count]={e,values}
    sync.frame_count+=1
    return true
}


// A place among the instances of the world that the instance at `from` took:
// where the renderer has it until it is told.
@(private)
Taken :: struct {at,from:u32}

// What the instance of an entity was made from.
Drawn :: struct {
    shown:Mesh_Renderer,
    derives:bool, // its rows or the values it holds come from those of its materials (named values, an alpha, layers): in deriving
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
@(step="late",loops="game",stage="end")
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
world_light_forget :: proc(renderer:^Renderer,id:core.World_Id) {
    if renderer!=nil {gpu.world_light_forget(renderer,world_key(id))}
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
    worlds:core.Read(core.World_Transform),meshes:core.Read(Mesh_Renderer),values:core.Read(Material_Values),
    hidden:core.Read(Hidden),elsewhere:core.Read(Drawn_Elsewhere),parents:core.Read(core.Parent),hierarchy:core.Ref(core.Hierarchy),
    suns:core.Read(Sun),points:core.Read(Point_Light),spots:core.Read(Spot_Light),rects:core.Read(Rect_Light),emissions:core.Read(Light_Emission),skies:core.Read(Sky),view_volumes:core.Read(View_Volume),volumes:core.Read(volume.Volume),
    highlights:core.Read(Highlight),outlines:core.Read(Outline),outline_styles:core.Ref(Outline_Styles),
    offsets:core.Read(Draw_Offset),layers:core.Read(Layers),bodies:core.Ref(View_Bodies),preview:core.Ref(Environment_Preview),
    locals:core.Read(core.Transform),cameras:core.Read(Camera),
) {
    a:=app.assets
    r:=app.renderer
    if a==nil || r==nil || app.ui_only {sync.frame_count=0;return}
    owned:[VIEW_SLOTS]core.Entity
    if bodies.ptr!=nil {owned=bodies.bodies}
    t:=Sync_Tables{worlds,meshes,values,hidden,elsewhere,parents,highlights,outlines,offsets,layers,locals,cameras,owned}
    defer sync.owned=owned
    for at in sync.changed {sync.drawn.values[at].changed=false}
    clear(&sync.changed)
    clear(&sync.tinted);clear(&sync.tinted_colors);clear(&sync.tinted_emissions);clear(&sync.tinted_values)
    // What each table changed since the last frame: only the instances it touches are made again.
    c:=Sync_Changes{
        meshes=core.changes(meshes,&sync.seen_meshes),worlds=core.changes(worlds,&sync.seen_worlds),values=core.changes(values,&sync.seen_values),
        hidden=core.changes(hidden,&sync.seen_hidden),elsewhere=core.changes(elsewhere,&sync.seen_elsewhere),parents=core.changes(parents,&sync.seen_parents),
        offsets=core.changes(offsets,&sync.seen_offsets),layers=core.changes(layers,&sync.seen_layers),
    }
    frame_values_apply(sync,&app.extras,a,t,frame)
    extras:=host.extras_instances(&app.extras)
    extras_inherit(t,extras)
    rebuild:=!sync.synced || sync.world!=id || c.meshes.all || c.worlds.all || c.values.all || c.hidden.all || c.elsewhere.all
    rebuild||=c.parents.all || c.offsets.all || c.layers.all
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
        for row in core.each_changed(elsewhere,&c.elsewhere) {instance_drop(sync,t,core.entity_at(elsewhere,row),&structure)}
        if structure {kept=instances_taken_publish(sync,a,r,t,frame,extras)}
        rebuild=!kept
        // What starts being drawn: a mesh added or turned on, placed, or no longer drawn elsewhere.
        clear(&sync.coming)
        if !rebuild {
            for row in core.each_changed(meshes,&c.meshes) {
                e:=core.entity_at(meshes,row)
                if at:=instance_of(sync,e);at>=0 {
                    if sync.drawn.values[at].shown!=core.at(meshes,row) {instance_changed(sync,u32(at))}
                } else if instance_wanted(t,e) {append(&sync.coming,e)}
            }
            for row in core.each_changed(worlds,&c.worlds) {
                if e:=core.entity_at(worlds,row);instance_of(sync,e)<0 && instance_wanted(t,e) {append(&sync.coming,e)}
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
            changes_mark(sync,hierarchy,layers,c.layers,false)
            // A body of a local player taken or given back: its meshes are marked again.
            for body,i in owned {
                if body==sync.owned[i] {continue}
                if sync.owned[i]!=core.NONE {subtree_changed(sync,hierarchy,sync.owned[i])}
                if body!=core.NONE {subtree_changed(sync,hierarchy,body)}
            }
            values_settle(sync,a,r,t,c.values)
            // The mesh a visual instance starts or stops replacing is made again, hidden or shown.
            if extras_changed {
                for previous in sync.extras {
                    if at:=instance_of(sync,core.Entity(previous.object_id));at>=0 && previous.replace_source && !replaces(extras,previous.object_id) {instance_changed(sync,u32(at))}
                }
                for extra in extras {
                    if at:=instance_of(sync,core.Entity(extra.object_id));at>=0 && extra.replace_source && !replaces(sync.extras[:],extra.object_id) {instance_changed(sync,u32(at))}
                }
            }
            local_changes=structure || len(sync.coming)>0 || len(sync.changed)>0 || extras_changed
        }
        if local_changes {
            host.assets_appearance_begin(a)
            host.assets_commit(a)
            first:=len(sync.drawn.values)
            clear(&sync.shown)
            for e in sync.coming {
                if !instance_insert(sync,a,t,e,frame,extras) {rebuild=true;break}
                host.assets_commit(a)
            }
            // What came goes to the renderer at once, the instances of the application after it.
            if !rebuild && len(sync.drawn.values)>first {rebuild=!instances_came_publish(sync,r,first)}
            for at in sync.changed {
                if rebuild {break}
                e:=sync.drawn.entities[at]
                static,_:=core.get(meshes,e)
                world,_:=core.get(worlds,e)
                instance,derives,usable:=instance_make(a,t,e,static,world,frame)
                if !usable {rebuild=true;break}
                drawn:=&sync.drawn.values[at]
                if drawn.shown.mesh!=static.mesh {
                    mesh_user_remove(sync,drawn.shown.mesh,at)
                    mesh_user_add(sync,static.mesh,at)
                }
                if derives && !drawn.derives {
                    if !room(&sync.deriving) {rebuild=true;break}
                    append(&sync.deriving,at)
                }
                // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
                drawn.shown=static
                drawn.derives=derives
                host.assets_commit(a)
                instance.hidden||=replaces(extras,instance.object_id)
                if !gpu.scene_update(r,at,{instance}) {rebuild=true;break}
                sync.stats.instance_updates+=1
            }
        }
    }
    // .ptr spelled out: a field reached through using in a ternary is loaded before its nil check (see ODIN_WORKAROUNDS).
    lights:=Lights{suns,points,spots,rects,preview.ptr!=nil?preview.ptr.sun:core.NONE}
    sync.lights_stale|=lights.preview!=sync.lights_preview
    sync.lights_stale|=core.touched(suns,&sync.lights_seen[0]) | core.touched(points,&sync.lights_seen[1]) | core.touched(spots,&sync.lights_seen[2]) | core.touched(rects,&sync.lights_seen[3])
    sync.lights_stale|=core.touched(worlds,&sync.lights_seen[4]) | core.touched(hidden,&sync.lights_seen[5]) | core.touched(parents,&sync.lights_seen[6]) | core.touched(emissions,&sync.lights_seen[7])
    sync.lights_preview=lights.preview
    // The material a screen shows may change with what is drawn over its mesh.
    if core.count(emissions)>0 && (extras_changed || local_changes) {sync.lights_stale=true}
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
    if !rebuild && extras_changed {
        // The visual instances of the application that are others, in their places after those of the world.
        first:=len(sync.drawn.entities)
        patched:=true
        for instance,i in extras {
            if i<len(sync.extras) && instance==sync.extras[i] {continue}
            patched&&=gpu.scene_update(r,u32(first+i),{instance})
            sync.stats.instance_updates+=1
        }
        if len(extras)<len(sync.extras) {patched&&=gpu.scene_update(r,u32(first+len(extras)),nil,true)}
        if !patched {
            // What the renderer refused of them it gets with the scene, set again.
            rebuild=true
        } else if resize(&sync.extras,len(extras))!=nil {
            // Without memory for the visual instances a later frame makes the scene again.
            sync.synced=false
            return
        } else {copy(sync.extras[:],extras)}
    }
    if rebuild {
        host.assets_appearance_begin(a)
        if !instances_build(sync,a,t,frame,extras) || resize(&sync.extras,len(extras))!=nil {
            // Without memory for the instances the scene is empty until a frame makes it again.
            gpu.scene_set(r,nil,nil,{},environment)
            sync.synced=false
            return
        }
        copy(sync.extras[:],extras)
        batches_retain(a,r)
        for instance in extras {instance_materials_retain(a,instance.material,instance.slot_materials,instance.overlays)}
        lit:=lights_build(sync,a,worlds,lights,emissions,meshes,hidden,parents,extras,view.position.y,r,sync.shown[:])
        sync.lights_stale=false
        host.assets_appearance_end(a)
        host.assets_commit(a)
        sync.assets_structure,sync.assets_appearance=a.structure,a.appearance
        if !lit || !gpu.scene_set(r,sync.shown[:],sync.lights[:],sync.sun,environment) {
            gpu.scene_set(r,nil,nil,{},environment)
            sync.synced=false
            return
        }
        // The renderer has the scene now: no copy of it is kept.
        delete(sync.shown)
        sync.shown=nil
        sync.environment=environment
        _=outlines_touched(sync,t)
        sync.highlights_stale=false
        sync.stats.scene_sets+=1
    } else {
        if local_changes {
            // The derived rows in use: those of the batches, of the instances that derive theirs and of the visual instances.
            batches_retain(a,r)
            for i:=len(sync.deriving)-1;i>=0;i-=1 {
                at:=sync.deriving[i]
                if !sync.drawn.values[at].derives {
                    unordered_remove(&sync.deriving,i)
                    continue
                }
                if material,slots,overlays,held:=gpu.scene_instance_materials(r,at);held {instance_materials_retain(a,material,slots,overlays)}
            }
            for instance in extras {instance_materials_retain(a,instance.material,instance.slot_materials,instance.overlays)}
            host.assets_appearance_end(a);host.assets_commit(a)
            sync.assets_structure,sync.assets_appearance=a.structure,a.appearance
        } else {sync.assets_structure=a.structure}
        instances_moved(sync,t,c.worlds,frame)
        for instance,i in extras {
            if sync.extras[i].transform==instance.transform && sync.extras[i].anchor==instance.anchor {continue}
            sync.extras[i]=instance
            append(&sync.moved,u32(len(sync.drawn.entities)+i));append(&sync.moved_transforms,instance.transform);append(&sync.moved_anchors,instance.anchor)
        }
        // The renderer leaves where it is what did not move, and as it is what has the same tint.
        if len(sync.moved)>0 {
            moved:int
            gpu.scene_move(r,sync.moved[:],sync.moved_transforms[:],sync.moved_anchors[:],&moved)
            if moved>0 {sync.stats.moves+=1}
        }
        if len(sync.tinted)>0 {
            tinted:int
            gpu.scene_tint(r,sync.tinted[:],sync.tinted_colors[:],sync.tinted_emissions[:],&tinted,sync.tinted_values[:])
            if tinted>0 {sync.stats.tints+=1}
        }
        if sync.lights_stale {
            sync.lights_stale=false
            previous_sun:=sync.sun
            // Without memory to keep the lights of before, they are set as if they had changed.
            compared:=resize(&sync.previous_lights,len(sync.lights))==nil
            if compared {copy(sync.previous_lights[:],sync.lights[:])}
            // Without memory for the lights a later frame makes the scene again.
            if !lights_build(sync,a,worlds,lights,emissions,meshes,hidden,parents,extras,view.position.y,r) {
                sync.synced=false
                return
            }
            if !compared || sync.sun!=previous_sun || !slice.equal(sync.lights[:],sync.previous_lights[:]) {
                // Without memory in the renderer for the lights a later frame makes the scene again.
                if !gpu.scene_set_lights(r,sync.lights[:],sync.sun,environment) {
                    sync.synced=false
                    return
                }
                sync.environment=environment
                sync.stats.light_sets+=1
            }
        }
        // Without memory for the levels a later frame gives them.
        sync.highlights_stale|=outlines_touched(sync,t)
        if sync.highlights_stale && resize(&sync.highlights,len(sync.drawn.entities)+len(sync.extras))==nil {
            sync.highlights_stale=false
            for e,at in sync.drawn.entities {sync.highlights[at]=is_hidden(hidden,parents,e)?0:instance_outline(highlights,outlines,e)}
            for instance,i in sync.extras {sync.highlights[len(sync.drawn.entities)+i]=instance.highlight}
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
    sync.world=id
    sync.synced=true
}

// The tables render_sync makes instances from.
@(private)
Sync_Tables :: struct {
    worlds:core.Read(core.World_Transform),
    meshes:core.Read(Mesh_Renderer),
    values:core.Read(Material_Values),
    hidden:core.Read(Hidden),
    elsewhere:core.Read(Drawn_Elsewhere),
    parents:core.Read(core.Parent),
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
outlines_touched :: proc(sync:^Render_Sync,t:Sync_Tables) -> bool {return core.touched(t.highlights,&sync.highlights_seen[0]) | core.touched(t.outlines,&sync.highlights_seen[1])}

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
Sync_Changes :: struct {meshes,worlds,values,hidden,elsewhere,parents,offsets,layers:core.Changes}

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
    c:=c
    for e in c.gone {mark(sync,h,e,below)}
    for row in core.each_changed(table,&c) {mark(sync,h,core.entity_at(table,row),below)}
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

// The instance of the mesh of an entity, with its values, visibility,
// outline and layers. over: what it shows this frame over its
// Material_Values (values_show).
@(private)
instance_make :: proc(a:^host.Assets,t:Sync_Tables,e:core.Entity,static:Mesh_Renderer,world:core.World_Transform,frame:core.Frame_Time,over:^Material_Values=nil) -> (instance:gpu.Instance_Desc,derives,ok:bool) {
    values:=MATERIAL_VALUES_DEFAULT
    if own,has_values:=core.get(t.values,e);has_values {values=own}
    if over!=nil {material_values_over(&values,over)}
    anchor,transform:=instance_place(world,frame,t.offsets,t.parents,t.worlds,t.locals,t.cameras,e)
    instance,ok=mesh_instance(a,static,transform,values)
    instance.anchor=anchor
    if !ok {return}
    instance.object_id=u64(e)
    instance.hidden=is_hidden(t.hidden,t.parents,e)
    if !instance.hidden {instance.highlight=instance_outline(t.highlights,t.outlines,e)}
    if in_layers,has_layers:=core.get(t.layers,e);has_layers {instance.layers=in_layers.mask}
    instance.owner=body_owner(t,e)
    return instance,!material_values_plain(&values) || instance.overlays.count>0,true
}

// What entities show this frame over their Material_Values (values_show), in
// what draws each one: what replaces its mesh, whose rows take them, or else
// a copy of its mesh of the world that does. What drew each one is kept for
// the next frame (host.extras_mesh_shown).
@(private)
frame_values_apply :: proc(sync:^Render_Sync,extras:^host.Frame_Extras,a:^host.Assets,t:Sync_Tables,frame:core.Frame_Time) {
    extras.meshes_shown_count=0
    for &request in sync.frame_values[:sync.frame_count] {
        e:=request.entity
        static,has_mesh:=core.get(t.meshes,e)
        if !has_mesh {continue}
        shown:^gpu.Instance_Desc
        for &extra in host.extras_instances(extras) {
            if extra.replace_source && extra.object_id==u64(e) {shown=&extra;break}
        }
        if shown==nil {
            world,placed:=core.get(t.worlds,e)
            if !placed {continue}
            instance,_,made:=instance_make(a,t,e,static,world,frame,&request.values)
            if !made || instance.hidden {continue}
            instance.copy_owner,instance.replace_source=FRAME_VALUES_OWNER,true
            if !host.extras_instance_add(extras,instance) {continue}
            added:=host.extras_instances(extras)
            shown=&added[len(added)-1]
        } else {
            // What replaces the mesh was made without them: each slot they name shows a row with them, in place of what its instance held for it.
            for slot in 0..<u32(MATERIAL_SLOTS) {
                if !material_values_slot(&request.values,int(slot)) {continue}
                row,at:=mesh_slot_row(a,static,shown,slot)
                values:=host.assets_material_values(a,row)
                material_values_apply(a,&values,&request.values,int(slot))
                derived,derives:=host.assets_material_derive(a,values)
                if !derives {continue}
                if at!=nil {at^=derived+1} else {shown.material=gpu.Material_Handle(derived)}
            }
        }
        if extras.meshes_shown_count<len(extras.meshes_shown) {
            extras.meshes_shown[extras.meshes_shown_count]={object=u64(e),mesh=shown.mesh,anchor=shown.anchor,transform=shown.transform}
            extras.meshes_shown_count+=1
        }
    }
    sync.frame_count=0
}

// What draws a mesh of the world with the values of a frame.
@(private)
FRAME_VALUES_OWNER :: u64(0x736c6f7400000000)

// Whether a visual instance of extras is drawn in place of the mesh of an
// object: the instance of that mesh is hidden meanwhile.
@(private)
replaces :: proc(extras:[]gpu.Instance_Desc,object:u64) -> bool {
    for extra in extras {if extra.replace_source && extra.object_id==object {return true}}
    return false
}

// Keeps through a round of derived rows those an instance shows: its
// material, those of its slots and its layers.
@(private)
instance_materials_retain :: proc(a:^host.Assets,material:gpu.Material_Handle,slots:[32]u32,overlays:gpu.Instance_Overlays) {
    host.assets_material_retain(a,u32(material))
    for row in slots {if row>0 {host.assets_material_retain(a,row-1)}}
    for i in 0..<min(int(overlays.count),len(overlays.entries)) {host.assets_material_retain(a,u32(overlays.entries[i].material))}
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
    for list in ([2]^[dynamic]u32{&sync.lerping,&sync.deriving}) {
        for i:=len(list)-1;i>=0;i-=1 {if int(list[i])==at {unordered_remove(list,i)}}
    }
    if at!=last {
        mesh_user_remove(sync,sync.drawn.values[last].shown.mesh,u32(last))
        mesh_user_add(sync,sync.drawn.values[last].shown.mesh,u32(at))
        for list in ([2]^[dynamic]u32{&sync.lerping,&sync.deriving}) {
            for &listed in list {if int(listed)==last {listed=u32(at)}}
        }
    }
    core.entity_map_remove_at(&sync.drawn,at)
    sync.stats.instance_updates+=1
    // The one that takes the place may have taken another before in the frame: the renderer has it where it was first.
    from:=u32(last)
    for i:=len(sync.taken)-1;i>=0;i-=1 {
        if int(sync.taken[i].at)==last {from=sync.taken[i].from}
        if int(sync.taken[i].at)==last || int(sync.taken[i].at)==at {unordered_remove(&sync.taken,i)}
    }
    if at!=last {append(&sync.taken,Taken{u32(at),from})}
}

// Gives the renderer what instance_remove took out in the frame, at once:
// the instances that took the places of others, made again with the motion
// from where they were, and the visual instances of the application after
// those of the world, which end the scene. False when it refused them or one
// cannot be made.
@(private)
instances_taken_publish :: proc(sync:^Render_Sync,a:^host.Assets,r:^gpu.Renderer,t:Sync_Tables,frame:core.Frame_Time,extras:[]gpu.Instance_Desc) -> bool {
    world:=len(sync.drawn.values)
    ok:=true
    for taken in sync.taken {
        if !ok {break}
        e:=sync.drawn.entities[taken.at]
        static,_:=core.get(t.meshes,e)
        placed,_:=core.get(t.worlds,e)
        instance,_,usable:=instance_make(a,t,e,static,placed,frame)
        instance.hidden||=replaces(extras,instance.object_id)
        host.assets_commit(a)
        ok=usable && gpu.scene_update(r,taken.at,{instance}) && gpu.scene_instance_was(r,taken.at,taken.from)
    }
    clear(&sync.taken)
    return ok && gpu.scene_update(r,u32(world),sync.extras[:],true)
}

// Gives the renderer the instances of the world from first, which came in
// the frame (instance_insert left them in shown), and those of the
// application after them, at once. False when it refused them.
@(private)
instances_came_publish :: proc(sync:^Render_Sync,r:^gpu.Renderer,first:int) -> bool {
    if reserve(&sync.shown,len(sync.shown)+len(sync.extras))!=nil {return false}
    append(&sync.shown,..sync.extras[:])
    return gpu.scene_update(r,u32(first),sync.shown[:])
}

// Puts the instance of an entity after those of the world; the visual
// instances of the application move up one. The renderer gets it with the
// others that come (instances_came_publish), from shown. False when its mesh
// is not usable yet: the scene is set again.
@(private)
instance_insert :: proc(sync:^Render_Sync,a:^host.Assets,t:Sync_Tables,e:core.Entity,frame:core.Frame_Time,extras:[]gpu.Instance_Desc) -> bool {
    if instance_of(sync,e)>=0 || !instance_wanted(t,e) {return true}
    static,_:=core.get(t.meshes,e)
    world,_:=core.get(t.worlds,e)
    instance,derives,usable:=instance_make(a,t,e,static,world,frame)
    if !usable {return false}
    at:=len(sync.drawn.values)
    lerp:=world.previous!=world.transform
    // The instance of another generation of its index would stay in its place: the scene is set again.
    if core.entity_map_held(&sync.drawn,e)!=core.NONE {return false}
    if !room(&sync.shown) || !room(&sync.lerping) || !room(&sync.deriving) {return false}
    if _,kept:=core.entity_map_put(&sync.drawn,e,Drawn{shown=static,derives=derives,lerp=lerp});!kept {return false}
    if lerp {append(&sync.lerping,u32(at))}
    if derives {append(&sync.deriving,u32(at))}
    instance.hidden||=replaces(extras,instance.object_id)
    append(&sync.shown,instance)
    mesh_user_add(sync,static.mesh,u32(at))
    sync.stats.instance_updates+=1
    return true
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

// The instances the renderer has of the world: those of its meshes, then the
// visual instances of the application.
instance_count :: proc(sync:^Render_Sync) -> int {return len(sync.drawn.entities)+len(sync.extras)}

// The object an instance of the renderer is drawn for (gpu.Instance_Desc.object_id):
// the entity of a mesh of the world, or what a visual instance names. 0 for none.
instance_object :: proc(sync:^Render_Sync,instance:int) -> u64 {
    world:=len(sync.drawn.entities)
    if instance<0 || instance>=world+len(sync.extras) {return 0}
    return instance<world?u64(sync.drawn.entities[instance]):sync.extras[instance-world].object_id
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

// The scene the renderer is set, in shown: the instances of the meshes of
// the world, made again and hidden where a visual instance replaces them,
// and the visual instances of the application after them. False without
// memory.
@(private)
instances_build :: proc(sync:^Render_Sync,a:^host.Assets,t:Sync_Tables,frame:core.Frame_Time,extras:[]gpu.Instance_Desc) -> bool {
    clear(&sync.shown);clear(&sync.lerping);clear(&sync.deriving);clear(&sync.changed)
    core.entity_map_clear(&sync.drawn)
    if sync.mesh_users==nil {sync.mesh_users=make(map[base.Asset_Id][dynamic]u32)}
    for _,users in sync.mesh_users {delete(users)}
    clear(&sync.mesh_users)
    count:=core.count(t.meshes)
    if !core.entity_map_reserve(&sync.drawn,count) || reserve(&sync.shown,count+len(extras))!=nil ||
       reserve(&sync.lerping,count)!=nil || reserve(&sync.deriving,count)!=nil || reserve(&sync.changed,count)!=nil {return false}
    for row in 0..<count {
        e:=core.entity_at(t.meshes,row)
        world,placed:=core.get(t.worlds,e)
        if !placed || core.has(t.elsewhere,e) {continue}
        static:=core.at(t.meshes,row)
        instance,derives,ok:=instance_make(a,t,e,static,world,frame)
        if !ok {continue}
        lerp:=world.previous!=world.transform
        if _,kept:=core.entity_map_put(&sync.drawn,e,Drawn{shown=static,derives=derives,lerp=lerp});!kept {return false}
        at:=u32(len(sync.shown))
        if lerp {append(&sync.lerping,at)}
        if derives {append(&sync.deriving,at)}
        append(&sync.shown,instance)
        mesh_user_add(sync,static.mesh,at)
    }
    for extra in extras {
        if at:=instance_of(sync,core.Entity(extra.object_id));at>=0 && extra.replace_source {sync.shown[at].hidden=true}
    }
    append(&sync.shown,..extras)
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

// The lights of the frame and its sun. The material a rectangle shows is
// read from r, or from set: the scene r is about to be set, which it does
// not have yet (emission_material). False, with no light, without memory
// for them.
@(private)
lights_build :: proc(sync:^Render_Sync,a:^host.Assets,worlds:core.Read(core.World_Transform),lights:Lights,emissions:core.Read(Light_Emission),meshes:core.Read(Mesh_Renderer),hidden:core.Read(Hidden),parents:core.Read(core.Parent),extras:[]gpu.Instance_Desc,height:f32,r:^gpu.Renderer=nil,set:[]gpu.Instance_Desc=nil) -> bool {
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
    // Room for every light there may be: none is left out for lack of it.
    if reserve(&sync.lights,core.count(lights.points)+core.count(lights.spots)+core.count(lights.rects))!=nil {return false}
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
        if emission,shows:=core.get(emissions,e);shows {desc.material=emission_material(sync,a,r,meshes,extras,set,e,u32(emission.slot))}
        append(&sync.lights,desc)
    }
    return true
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
// something does (a screen of a plugin). Its instance is read from set, or
// from the renderer when it has the scene already. 0: none.
@(private)
emission_material :: proc(sync:^Render_Sync,a:^host.Assets,r:^gpu.Renderer,meshes:core.Read(Mesh_Renderer),extras,set:[]gpu.Instance_Desc,e:core.Entity,slot:u32) -> gpu.Material_Handle {
    static,has_mesh:=core.get(meshes,e)
    if !has_mesh {return 0}
    shown:gpu.Instance_Desc
    found:=false
    for extra in extras {if extra.replace_source && extra.object_id==u64(e) {shown,found=extra,true;break}}
    if !found {
        at:=instance_of(sync,e)
        if at<0 {return 0}
        if at<len(set) {shown=set[at]}
        else if r==nil {return 0}
        else if material,slots,_,held:=gpu.scene_instance_materials(r,u32(at));held {
            shown.material=material
            shown.slot_materials=slots
        }
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

// Where the instances whose world rows were written since the last sync
// are, and those between two places, which move with the time of the frame:
// gpu.scene_move leaves where it is what did not move.
@(private)
instances_moved :: proc(sync:^Render_Sync,t:Sync_Tables,c:core.Changes,frame:core.Frame_Time) {
    c:=c
    c.row=0
    clear(&sync.moved);clear(&sync.moved_transforms);clear(&sync.moved_anchors)
    worlds:=t.worlds
    place :: proc(sync:^Render_Sync,t:Sync_Tables,world:core.World_Transform,at:int,frame:core.Frame_Time) {
        anchor,m:=instance_place(world,frame,t.offsets,t.parents,t.worlds,t.locals,t.cameras,sync.drawn.entities[at])
        append(&sync.moved,u32(at));append(&sync.moved_transforms,m);append(&sync.moved_anchors,anchor)
    }
    for row in core.each_changed(worlds,&c) {
        at:=instance_of(sync,core.entity_at(worlds,row))
        if at<0 {continue}
        world:=core.at(worlds,row)
        lerp:=world.previous!=world.transform
        drawn:=&sync.drawn.values[at]
        if lerp && !drawn.lerp {append(&sync.lerping,u32(at))}
        drawn.lerp=lerp
        place(sync,t,world,at,frame)
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
}

// The Material_Values written, added or removed. Those of an entity that
// shows the same rows with them are given in place: a color, an emission and
// the values its instance holds, which the renderer leaves as they are when
// they are the same. Others (a texture, an alpha, layers, another value of the
// standard model), and those that went, make the instance again.
@(private)
values_settle :: proc(sync:^Render_Sync,a:^host.Assets,r:^gpu.Renderer,t:Sync_Tables,c:core.Changes) {
    for e in c.gone {if at:=instance_of(sync,e);at>=0 {instance_changed(sync,u32(at))}}
    if core.version(t.values)<=c.since {return}
    for row in 0..<core.count(t.values) {
        if !core.changed(t.values,c,row) {continue}
        at:=instance_of(sync,core.entity_at(t.values,row))
        if at<0 || sync.drawn.values[at].changed {continue}
        values:=core.at(t.values,row)
        made,usable:=mesh_instance(a,sync.drawn.values[at].shown,1,values)
        material,slots,overlays,held:=gpu.scene_instance_materials(r,u32(at))
        if !usable || !held || made.material!=material || made.slot_materials!=slots || made.overlays!=overlays || !room(&sync.tinted) || !room(&sync.tinted_colors) || !room(&sync.tinted_emissions) || !room(&sync.tinted_values) {
            instance_changed(sync,u32(at))
            continue
        }
        sync.drawn.values[at].derives=!material_values_plain(&values) || made.overlays.count>0
        if sync.drawn.values[at].derives && !slice.contains(sync.deriving[:],u32(at)) {
            if !room(&sync.deriving) {instance_changed(sync,u32(at));continue}
            append(&sync.deriving,u32(at))
        }
        append(&sync.tinted,u32(at));append(&sync.tinted_colors,made.tint);append(&sync.tinted_emissions,made.emission);append(&sync.tinted_values,made.material_values)
    }
}

// Where a value of the standard model an instance holds goes: the first of
// MATERIAL_VALUE_FIELDS, in the order of their targets. False for the others,
// which a row holds.
@(private)
material_value_instanced :: proc(name:u64) -> (target:gpu.Instance_Material_Value_Target,instanced:bool) {
    fields:=MATERIAL_VALUE_FIELDS
    for field,index in fields[:len(gpu.Instance_Material_Value_Target)] {
        if base.name_hash(field.name)==name {return gpu.Instance_Material_Value_Target(int(min(gpu.Instance_Material_Value_Target))+index),true}
    }
    return
}

// Puts one named value over the values of a material: a parameter of its
// program when the program declares one with that name, and otherwise the
// value of the standard model with it. False for a name that is neither.
material_value_apply :: proc(values:^gpu.Material_Desc,program:^gpu.Program,name:u64,value:[4]f32) -> bool {
    if parameter:=material_value_parameter(program,name);parameter!=nil {
        gpu.program_parameter_set(&values.custom_params,parameter,{f64(value.x),f64(value.y),f64(value.z),f64(value.w)})
        return true
    }
    value:=value
    return material_standard_value(&values.info,name,&value,true)
}

// The parameter of a program a name of a value is; nil for another name.
@(private)
material_value_parameter :: proc(program:^gpu.Program,name:u64) -> ^gpu.Program_Parameter {
    if program==nil {return nil}
    for &parameter in program.parameters {
        if parameter.kind!=.Texture && base.name_hash(parameter.name)==name {return &parameter}
    }
    return nil
}

// Puts a value of the standard model over the values of a material (put), or
// reads it, by the name_hash of one of MATERIAL_VALUE_FIELDS. False for
// another name.
material_standard_value :: proc(info:^asset.Material_Info,name:u64,value:^[4]f32,put:bool) -> bool {
    fields:=MATERIAL_VALUE_FIELDS
    for field in fields {
        if base.name_hash(field.name)!=name {continue}
        at:=rawptr(uintptr(info)+field.offset)
        switch field.kind {
        case .Number: if put {(^f32)(at)^=value.x} else {value^={(^f32)(at)^,0,0,0}}
        case .Color:  if put {(^[3]f32)(at)^=value.xyz} else {value.xyz,value.w=(^[3]f32)(at)^,0}
        case .Flag:   if put {(^bool)(at)^=value.x>0.5} else {value^={f32(u8((^bool)(at)^)),0,0,0}}
        case .Mode:   if put {(^u8)(at)^=u8(clamp(int(value.x+0.5),0,int(field.modes)-1))} else {value^={f32((^u8)(at)^),0,0,0}}
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

// The values of a slot an instance holds, for its points that show row: the
// numbers of the program of the row, and those of the standard model an
// instance holds.
@(private)
values_hold :: proc(a:^host.Assets,held:^gpu.Instance_Material_Values,row:u32,o:^Material_Values,slot:int) {
    program:=surface_program(a,host.assets_material_values(a,row).program_id)
    for name,i in o.names[:min(int(o.count),len(o.names))] {
        if int(o.slots[i])!=slot || int(held.count)>=len(held.entries) {continue}
        if parameter:=material_value_parameter(program,name);parameter!=nil {
            held.entries[held.count]=gpu.instance_material_value(row,parameter,o.values[i])
        } else if target,instanced:=material_value_instanced(name);instanced {
            held.entries[held.count]=gpu.instance_material_value(row,target,o.values[i])
        } else {continue}
        held.count+=1
    }
}

// Whether an entity shows its materials as they are: an opaque white color, no light and nothing by name.
material_values_plain :: proc "contextless" (o:^Material_Values) -> bool {
    return o.color=={1,1,1,1} && o.emission=={} && o.count==0 && o.texture_count==0 && !o.own_overlays
}

// Whether an entity gives a value or a texture to the material of a slot;
// with `rows`, one that makes it show a row of its own (a texture, or a
// value of the standard model its instance does not hold: a parameter of a
// program is held).
material_values_slot :: proc(o:^Material_Values,slot:int,rows:=false) -> bool {
    for stored in o.texture_slots[:min(int(o.texture_count),len(o.texture_slots))] {
        if int(stored)==slot {return true}
    }
    fields:=MATERIAL_VALUE_FIELDS
    for stored,i in o.slots[:min(int(o.count),len(o.slots))] {
        if int(stored)!=slot {continue}
        if !rows {return true}
        for field in fields[len(gpu.Instance_Material_Value_Target):] {
            if base.name_hash(field.name)==o.names[i] {return true}
        }
    }
    return false
}

// What an entity shows with `over` given over its values: its color times
// that of over, its light plus that of over, and each name of over in place
// of the same of its own; what does not fit is left out.
material_values_over :: proc(o:^Material_Values,over:^Material_Values) {
    o.color*=over.color
    o.emission+=over.emission
    for name,i in over.names[:min(int(over.count),len(over.names))] {material_value(o,name,over.values[i],int(over.slots[i]))}
    for name,i in over.texture_names[:min(int(over.texture_count),len(over.texture_names))] {material_texture(o,name,int(over.texture_slots[i]),over.textures[i],over.shown[i])}
    if over.own_overlays {o.own_overlays,o.overlay_count,o.overlays=true,over.overlay_count,over.overlays}
}

// Puts the values and the textures an entity gives a slot over those of its
// material, loading the textures. Without `held`, only what a row holds: the
// textures and the values of the standard model the instance of the entity
// does not hold.
material_values_apply :: proc(a:^host.Assets,values:^gpu.Material_Desc,o:^Material_Values,slot:int,held:=true) {
    program:=surface_program(a,values.program_id)
    for name,i in o.names[:min(int(o.count),len(o.names))] {
        if int(o.slots[i])!=slot {continue}
        if !held {
            if material_value_parameter(program,name)!=nil {continue}
            if _,instanced:=material_value_instanced(name);instanced {continue}
        }
        material_value_apply(values,program,name,o.values[i])
    }
    maps:=MATERIAL_MAP_NAMES
    each: for name,i in o.texture_names[:min(int(o.texture_count),len(o.texture_names))] {
        if int(o.texture_slots[i])!=slot {continue}
        handle:gpu.Texture_Handle
        if o.shown[i]!=0 {handle=o.shown[i]} else if loaded:=host.assets_texture_image(a,o.textures[i]);loaded!=nil && !loaded.failed {handle=loaded.handle}
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
            // A program reads the normal map alone of the maps, unless it builds on the standard model.
            if program==nil || kind==.Normal || program.standard {values.textures[kind]=handle}
            continue each
        }
    }
}

// The texture an entity gives a map or a texture of the program of a slot, by its name.
material_texture_of :: proc "contextless" (o:^Material_Values,slot:int,name:u64) -> (texture:base.Asset_Id,found:bool) {
    for stored,i in o.texture_names[:min(int(o.texture_count),len(o.texture_names))] {
        if stored==name && int(o.texture_slots[i])==slot {return o.textures[i],true}
    }
    return
}

// Where an entity keeps the texture it gives a name of a slot; -1 without one.
@(private)
material_texture_find :: proc "contextless" (o:^Material_Values,slot:int,name:u64) -> int {
    for stored,i in o.texture_names[:min(int(o.texture_count),len(o.texture_names))] {
        if stored==name && int(o.texture_slots[i])==slot {return i}
    }
    return -1
}

// Gives a map of the standard model or a texture of the program of the
// material of a slot a texture: an asset (0 shows none), or one the renderer
// made at run time (shown), as that of a panel of the interface. False when
// the entity gives MATERIAL_VALUES_TEXTURES others, or for a slot that does
// not exist.
material_texture :: proc "contextless" (o:^Material_Values,name:u64,slot:int,texture:base.Asset_Id,shown:gpu.Texture_Handle=0) -> bool {
    at:=material_texture_find(o,slot,name)
    if at<0 {
        if int(o.texture_count)>=len(o.texture_names) || slot<0 || slot>=MATERIAL_SLOTS {return false}
        at=int(o.texture_count)
        o.texture_count+=1
    }
    o.texture_slots[at],o.texture_names[at],o.textures[at],o.shown[at]=u8(slot),name,texture,shown
    return true
}

// Takes the texture of one name of a slot away: that of the material shows again.
material_texture_drop :: proc "contextless" (o:^Material_Values,name:u64,slot:int) {
    last:=min(int(o.texture_count),len(o.texture_names))-1
    if i:=material_texture_find(o,slot,name);i>=0 {
        o.texture_slots[i],o.texture_names[i],o.textures[i],o.shown[i]=o.texture_slots[last],o.texture_names[last],o.textures[last],o.shown[last]
        o.texture_slots[last],o.texture_names[last],o.textures[last],o.shown[last]=0,0,{},0
        o.texture_count=u32(last)
    }
}

// Where an entity keeps the value it gives a name of a slot; -1 without one.
material_value_find :: proc "contextless" (o:^Material_Values,slot:int,name:u64) -> int {
    for stored,i in o.names[:min(int(o.count),len(o.names))] {
        if stored==name && int(o.slots[i])==slot {return i}
    }
    return -1
}

// Gives a value to a name of the material of a slot of the entity, leaving
// the other names as they are: a parameter of the program of that material,
// or one of MATERIAL_VALUE_FIELDS, by its name or the base.name_hash of it.
// False when the entity holds MATERIAL_VALUES_CAPACITY values of other names,
// for a slot that does not exist or for a value that is not finite.
material_value :: proc{material_value_named,material_value_hashed}

material_value_named :: proc(o:^Material_Values,name:string,value:[4]f32,slot:=0) -> bool {
    return material_value_hashed(o,base.name_hash(name),value,slot)
}

material_value_hashed :: proc "contextless" (o:^Material_Values,name:u64,value:[4]f32,slot:=0) -> bool {
    for component in value {if component-component!=0 {return false}}
    if at:=material_value_find(o,slot,name);at>=0 {
        o.values[at]=value
        return true
    }
    if int(o.count)>=len(o.names) || slot<0 || slot>=MATERIAL_SLOTS {return false}
    o.slots[o.count],o.names[o.count],o.values[o.count]=u8(slot),name,value
    o.count+=1
    return true
}

// Takes the value of one name of a slot away: that of the material shows again.
material_value_drop :: proc "contextless" (o:^Material_Values,name:u64,slot:=0) {
    count:=min(int(o.count),len(o.names))
    if i:=material_value_find(o,slot,name);i>=0 {
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
render_release :: proc(sync:^Render_Sync,id:core.World_Id,renderer:^Renderer) {
    if sync.world!=id {return}
    sync.world,sync.synced={},false
    if renderer!=nil {gpu.scene_set(renderer,nil,nil,sync.sun,sync.environment)}
}

sync_free :: proc(sync:^Render_Sync) {
    for _,users in sync.mesh_users {delete(users)}
    delete(sync.mesh_users)
    sync.mesh_users=nil
    core.value_free(sync,type_info_of(Render_Sync))
}

// The same geometry and appearance for world entities and temporary visual
// instances. The instance holds the color, the light and the values of
// `values` that an instance holds, for the rows its slots show: the slots
// that show one material share them.
mesh_instance :: proc(a:^host.Assets,static:Mesh_Renderer,transform:mm.Mat4,values:=MATERIAL_VALUES_DEFAULT) -> (instance:gpu.Instance_Desc,ok:bool) {
    values:=values
    mesh:=static.mesh!={}?host.assets_mesh(a,static.mesh):host.assets_shape(a,static.shape)
    if mesh==nil || mesh.handle==host.ASSETS_MESH_NONE {return {},false}
    instance=gpu.Instance_Desc{mesh=mesh.handle,transform=transform,tint=values.color.rgb,emission=values.emission}
    alpha:=values.color.a
    shown:=static.materials[0]
    if mesh.slot_count==0 {
        instance.material=gpu.Material_Handle(slot_row(a,&instance,host.assets_material_row(a,shown),&values,0,alpha))
    } else {
        if shown=={} {shown=mesh.slot_materials[0]}
        for slot in 0..<mesh.slot_count {
            material:=slot<MATERIAL_SLOTS?static.materials[slot]:base.Asset_Id{}
            if alpha<1 || material_values_slot(&values,int(slot)) {
                shown_row:=host.assets_material_row(a,material!={}?material:mesh.slot_materials[slot])
                instance.slot_materials[slot]=slot_row(a,&instance,shown_row,&values,int(slot),alpha)+1
            } else if material!={} {
                instance.slot_materials[slot]=host.assets_material_row(a,material)+1
            }
        }
    }
    if values.own_overlays {
        instance.overlays=host.assets_overlays(a,shown,values.overlays[:min(int(values.overlay_count),len(values.overlays))])
    } else {
        instance.overlays=host.assets_material_overlays(a,shown)
    }
    return instance,true
}

// The row a slot of an instance shows of a material with that row, with the
// values an entity gives the slot: one of its own when a row holds some of
// them or the entity fades; those an instance holds go to `instance`, for
// that row.
@(private)
slot_row :: proc(a:^host.Assets,instance:^gpu.Instance_Desc,row:u32,values:^Material_Values,slot:int,alpha:f32) -> u32 {
    shown:=row
    if material_values_slot(values,slot,true) {
        desc:=host.assets_material_values(a,row)
        material_values_apply(a,&desc,values,slot,false)
        if derived,ok:=host.assets_material_derive(a,desc);ok {shown=derived}
    }
    if alpha<1 {shown=host.assets_material_faded(a,shown,alpha)}
    values_hold(a,&instance.material_values,shown,values,slot)
    return shown
}
