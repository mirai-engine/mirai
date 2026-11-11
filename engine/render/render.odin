package render

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"
import "mirai:render/abi"
import "mirai:std/base"
import mm "mirai:std/math"

// What is drawn: meshes, lights, the camera, the sky and the effects of the
// image. render_sync brings the renderer of the application up to the world
// it runs on by what changed in it: nothing when no table it reads changed,
// and otherwise the instances and the lights of the rows written, added or
// gone.

MATERIAL_SLOTS :: 8
POST_PROCESS_CAPACITY :: 8
MATERIAL_VALUES_CAPACITY :: gpu.INSTANCE_VALUES_MAX // values among all the slots
MATERIAL_VALUES_TEXTURES :: 8
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
@(component,derived,description="The mesh is rendered by another system, such as destructible fragments.")
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
// its name: of the program of the material of that slot, or one of
// MATERIAL_VALUE_FIELDS or MATERIAL_MAP_NAMES. With own_overlays its overlays
// replace those of the material of the first slot. Several functions write
// it, in loop order: each sets and drops only the names it gives. Its
// instance holds its color, its light and its values (slot_row), given in
// place when they change; a texture makes the entity show a row of its own,
// shared by what gives the same.
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
@(component,derived)
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
instance_outline :: proc(highlights:^core.Table(Highlight,$A),outlines:^core.Table(Outline,$B),e:core.Entity) -> u8 {
    if level,has_level:=core.get(highlights,e);has_level && level.level>0 {return min(level.level,HIGHLIGHT_LEVELS)}
    if outline,has_outline:=core.get(outlines,e);has_outline {return gpu.outline_level(outline.style)}
    return 0
}

// Where an entity and what hangs from it are drawn relative to their
// simulated place: what the network fades a correction with.
@(component,derived)
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
// answer itself: the entity of each instance and of each light, and those
// that need something of every frame. The instances of the scene of the renderer are
// those of drawn, at the same index, then the visual instances of the frame.
// One per application: a world shown in place of another gives the renderer
// everything again, as changes of every row.
@(storage,host,free="sync_free")
Render_Sync :: struct {
    world:core.World_Id, // the one the scene of the renderer holds
    drawn:core.Entity_Map(Drawn), // by entity whose mesh the renderer draws
    mesh_users:map[base.Asset_Id][dynamic]core.Entity, // the entities drawn with each mesh asset
    seen:Sync_Seen,
    changed:[dynamic]core.Entity, // scratch: what may come, go or be made again in the frame
    under:[dynamic]core.Entity,   // scratch: the entities a table changed, and what hangs from them
    made:[dynamic]u32,            // scratch: the instances made again in the frame
    shown:[dynamic]gpu.Instance_Desc, // scratch: a run of them, as the renderer takes it
    lerping:[dynamic]core.Entity,  // drawn between their previous place and their transform (Drawn.lerp)
    deriving:[dynamic]core.Entity, // their rows derive from the values of their materials (Drawn.derives)
    replaced:[dynamic]core.Entity, // hidden while a visual instance is drawn in their place (Drawn.replaced)
    moved:[dynamic]u32,
    moved_transforms:[dynamic]mm.Mat4,
    moved_anchors:[dynamic][3]f32, // what each is relative to (instance_place)
    tinted:[dynamic]u32, // instances whose Material_Values changed and that show the same rows: what they hold is given in place
    tinted_colors,tinted_emissions:[dynamic][3]f32,
    tinted_values:[dynamic]gpu.Instance_Material_Values,
    light_owners:[dynamic]Light_Owner,  // by light of the renderer
    lit:[Light_Kind]core.Entity_Map(u32), // by entity with a light of the kind that shines: its light of the renderer
    sun:gpu.Sun_Desc,
    owned:[VIEW_SLOTS]core.Entity, // the bodies of View_Bodies the instances are marked with
    round:u32, // of the frame: Drawn.replaced of what a visual instance replaces in it
    assets_structure,assets_appearance:u64,
    derived:int, // the derived rows there were after the last round of them
    extra_rows:u64, // and what the rows the visual instances showed in it add up to
    environment:gpu.Environment,
    postprocess:[POST_PROCESS_CAPACITY]Post_Process_Layer,
    outline_styles:Outline_Styles, // the last ones applied
    graphics:Graphics_Settings, // the last ones applied
    graphics_applied:bool,
    synced:bool,
    starved:bool, // a list had no memory in the frame (push)
}

// What the sync keeps of the instance of an entity.
Drawn :: struct {
    mesh:base.Asset_Id, // of its Mesh_Renderer when it was made: where it is in mesh_users
    replaced:u32, // the round a visual instance last replaced it in; 0: none does
    derives:bool, // its rows or the values it holds come from those of its materials (named values, an alpha, layers): in deriving
    lerp:bool,    // in lerping
    changed:bool, // in changed
}

// What draws the mesh of an entity in place of the one its Mesh_Renderer
// names: the copy a library poses on the GPU (a skin, a deformation). The
// mesh is of its library, which takes the pose away before it removes the
// mesh.
Posed_Mesh :: struct {
    mesh:Mesh_Handle,
}

// The posed meshes of a world, by entity. render_sync draws each as any
// other mesh of its entity: placed, tinted, hidden and outlined by its rows.
@(storage,host,by_world,shared,free="posed_free")
Posed_Meshes :: struct {
    poses:core.Entity_Map(Posed_Mesh),
    changed:[dynamic]core.Entity, // given, changed or taken since render_sync looked
}

// Gives an entity its posed mesh; false without memory for it. A world the
// application did not make has none: nothing draws it.
posed_set :: proc(p:^Posed_Meshes,e:core.Entity,pose:Posed_Mesh) -> bool {
    if p==nil {return true}
    held:=core.entity_map_get(&p.poses,e)
    if held!=nil && held^==pose {return true}
    if held!=nil {held^=pose} else if _,kept:=core.entity_map_put(&p.poses,e,pose);!kept {return false}
    append(&p.changed,e)
    return true
}

// Its own mesh draws the entity again.
posed_drop :: proc(p:^Posed_Meshes,e:core.Entity) {
    if p!=nil && core.entity_map_remove(&p.poses,e) {append(&p.changed,e)}
}

posed_free :: proc(p:^Posed_Meshes) {core.value_free(p,type_info_of(Posed_Meshes))}

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
    cameras:^core.Table(Camera,.Read),exposures:^core.Table(Exposure,.Read),worlds:^core.Table(core.World_Transform,.Read),chosen:core.Ref(View_Camera),view:^core.View,app:^host.App,
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
view_of_camera :: proc(view:^core.View,cameras:^core.Table(Camera,$A),exposures:^core.Table(Exposure,$B),worlds:^core.Table(core.World_Transform,$C),e:core.Entity,size:[2]f32,pose:^View_Pose=nil,cut:=false) {
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

// The world into the renderer, by what changed in it since the last frame:
// the rows written, added or gone of each table it reads give the instances
// and the lights to make again, and nothing else is looked at. Another world,
// tables that are others whole or assets loaded again are the same changes,
// of every row. The camera and the time of the frame are those of the View,
// the Time and the Frame_Time of this world: host reads them. Another world,
// or this one replaced by another scene (in a frame whose view is cut), is a
// discontinuity for the renderer: the light it gathered for the world before
// stays with that one (gpu.scene_world). A frame that draws only the UI
// (host.App.ui_only) leaves the scene as it is: a world drawn between frames
// meanwhile keeps it, and this one takes it back when it is drawn again.
@(step="render",loops="game editor")
render_sync :: proc(
    sync:^Render_Sync,app:^host.App,id:core.World_Id,frame:core.Frame_Time,view:core.View,
    worlds:^core.Table(core.World_Transform,.Read),meshes:^core.Table(Mesh_Renderer,.Read),values:^core.Table(Material_Values,.Read),
    hidden:^core.Table(Hidden,.Read),elsewhere:^core.Table(Drawn_Elsewhere,.Read),parents:^core.Table(core.Parent,.Read),hierarchy:core.Ref(core.Hierarchy),
    suns:^core.Table(Sun,.Read),points:^core.Table(Point_Light,.Read),spots:^core.Table(Spot_Light,.Read),rects:^core.Table(Rect_Light,.Read),emissions:^core.Table(Light_Emission,.Read),skies:^core.Table(Sky,.Read),view_volumes:^core.Table(View_Volume,.Read),volumes:^core.Table(volume.Volume,.Read),sections:^core.Table(scene.Scene_Reference,.Read),
    highlights:^core.Table(Highlight,.Read),outlines:^core.Table(Outline,.Read),outline_styles:core.Ref(Outline_Styles),
    offsets:^core.Table(Draw_Offset,.Read),layers:^core.Table(Layers,.Read),bodies:core.Ref(View_Bodies),preview:core.Ref(Environment_Preview),
    locals:^core.Table(core.Transform,.Read),cameras:^core.Table(Camera,.Read),posed:^Posed_Meshes,
) {
    a:=app.assets
    r:=app.renderer
    if a==nil || r==nil || app.ui_only {return}
    t:=Sync_Tables{worlds,meshes,values,hidden,elsewhere,parents,highlights,outlines,offsets,layers,locals,cameras,points,spots,rects,emissions,posed,{}}
    if bodies.ptr!=nil {t.owned=bodies.bodies}
    releases,local_assets:=host.assets_structure_changes(a,sync.assets_structure)
    for change in releases {if change.id=={} {local_assets=false}}
    reloaded:=!local_assets || a.appearance!=sync.assets_appearance
    sync.assets_structure,sync.assets_appearance=a.structure,a.appearance
    shown:=!sync.synced || sync.world!=id
    c,whole:=sync_changes(sync,t)
    whole||=shown
    if whole {
        // Nothing the sync kept is of these rows: it forgets it, and every row is a change.
        sync_forget(sync,r)
        c,_=sync_changes(sync,t)
    } else if reloaded {
        // Every instance is made again with the assets there are now, and every mesh is asked whether it is drawn.
        for e in sync.drawn.entities {instance_changed(sync,e)}
        sync.seen.meshes={}
        c.meshes=core.changes(meshes,&sync.seen.meshes)
    }
    if shown || (whole || reloaded) && view.cut {gpu.scene_world(r,world_key(id),!shown)}
    sync.world,sync.synced=id,true
    // A visual instance of a mesh the renderer does not have is not drawn.
    #reverse for extra,i in app.extras.instances {
        if _,_,known:=gpu.mesh_bounds(r,extra.mesh);!known {unordered_remove(&app.extras.instances,i)}
    }
    extras:=host.extras_instances(&app.extras)
    extras_inherit(t,extras)

    // A mesh or a place written, added or gone: its entity may start or stop being drawn, or is made again.
    for e in c.meshes.gone {entity_changed(sync,e)}
    for row in core.each_changed(meshes,&c.meshes) {entity_changed(sync,core.entity_at(meshes,row))}
    for e in c.worlds.gone {instance_changed(sync,e)}
    for row in core.each_changed(worlds,&c.worlds) {
        // One that is drawn only moves (instances_moved).
        if e:=core.entity_at(worlds,row);instance_of(sync,e)<0 && core.has(meshes,e) && !core.has(elsewhere,e) {push(sync,&sync.changed,e)}
    }
    for e in c.elsewhere.gone {entity_changed(sync,e)}
    for row in core.each_changed(elsewhere,&c.elsewhere) {instance_changed(sync,core.entity_at(elsewhere,row))}
    // Hiding, showing, moving under another or offsetting redraws what hangs from it.
    clear(&sync.under)
    changes_gather(sync,hierarchy,hidden,c.hidden,true)
    changes_gather(sync,hierarchy,parents,c.parents,true)
    shaded:=len(sync.under) // those whose lights are hidden or shown with them
    changes_gather(sync,hierarchy,offsets,c.offsets,true)
    changes_gather(sync,hierarchy,layers,c.layers,false)
    changes_gather(sync,hierarchy,highlights,c.highlights,false)
    changes_gather(sync,hierarchy,outlines,c.outlines,false)
    // A body of a local player taken or given back: its meshes are marked again.
    for body,i in t.owned {
        if body==sync.owned[i] {continue}
        subtree_gather(sync,hierarchy,sync.owned[i])
        subtree_gather(sync,hierarchy,body)
    }
    sync.owned=t.owned
    for e in sync.under {instance_changed(sync,e)}
    for e in c.values.gone {instance_changed(sync,e)}
    if posed!=nil {
        for e in posed.changed {instance_changed(sync,e)}
        clear(&posed.changed)
    }
    for change in releases {
        if users,known:=sync.mesh_users[change.id];known {
            for e in users {instance_changed(sync,e)}
            continue
        }
        // A material with other values: what derives a row from it derives it again.
        for e in sync.deriving {
            if static,has_mesh:=core.get(meshes,e);has_mesh && instance_shows(a,static,change.id) {instance_changed(sync,e)}
        }
    }

    // What is no longer drawn goes first, so that what follows finds every instance where it stays.
    for e in sync.changed {
        if at:=instance_of(sync,e);at>=0 && !instance_wanted(a,t,e) && !instance_remove(sync,a,r,t,at,frame) {sync_fail(sync,r);return}
    }
    // What starts being drawn comes after those of the world, and is made with what changed.
    for e in sync.changed {
        if instance_of(sync,e)>=0 || !instance_wanted(a,t,e) {continue}
        if _,kept:=core.entity_map_put(&sync.drawn,e,Drawn{changed=true});!kept {sync_fail(sync,r);return}
    }
    // The mesh a visual instance starts or stops replacing is made again, hidden or shown.
    sync.round=max(sync.round+1,1)
    for extra in extras {
        e:=core.Entity(extra.object_id)
        drawn:=core.entity_map_get(&sync.drawn,e)
        if !extra.replace_source || drawn==nil {continue}
        if drawn.replaced==0 {
            push(sync,&sync.replaced,e)
            instance_changed(sync,e)
        }
        drawn.replaced=sync.round
    }
    #reverse for e,i in sync.replaced {
        drawn:=core.entity_map_get(&sync.drawn,e)
        if drawn!=nil && drawn.replaced==sync.round {continue}
        if drawn!=nil {
            drawn.replaced=0
            instance_changed(sync,e)
        }
        unordered_remove(&sync.replaced,i)
    }
    values_settle(sync,a,r,t,&c.values)
    // The instances to make again, in runs the renderer takes at once: those that came are the last one.
    clear(&sync.made)
    for e in sync.changed {
        if drawn:=core.entity_map_get(&sync.drawn,e);drawn!=nil && drawn.changed {
            drawn.changed=false
            push(sync,&sync.made,u32(instance_of(sync,e)))
        }
    }
    clear(&sync.changed)
    slice.sort(sync.made[:])
    for i:=0;i<len(sync.made); {
        first:=sync.made[i]
        clear(&sync.shown)
        for ;i<len(sync.made) && sync.made[i]==first+u32(len(sync.shown));i+=1 {
            instance,made:=instance_given(sync,a,t,int(sync.made[i]),frame)
            push(sync,&sync.shown,instance)
            if !made || sync.starved {sync_fail(sync,r);return}
        }
        host.assets_commit(a)
        if !gpu.scene_update(r,first,sync.shown[:]) {sync_fail(sync,r);return}
    }
    // After a world given whole, no copy of it is kept.
    if whole {
        delete(sync.shown)
        sync.shown=nil
    }
    instances_moved(sync,t,c.worlds,frame)
    // The renderer leaves where it is what did not move, and as it is what has the same tint.
    if len(sync.moved)>0 {gpu.scene_move(r,sync.moved[:],sync.moved_transforms[:],sync.moved_anchors[:])}
    if len(sync.tinted)>0 {gpu.scene_tint(r,sync.tinted[:],sync.tinted_colors[:],sync.tinted_emissions[:],sync.tinted_values[:])}
    // The visual instances of the frame, after those of the world: the renderer leaves as it is each one it has, and what is past them goes.
    host.assets_commit(a)
    if !gpu.scene_update(r,u32(len(sync.drawn.entities)),extras,true) {sync_fail(sync,r);return}
    // The derived rows in use, when a round of them was opened, some were derived or the visual instances show other rows than in the last one: those of the batches, of the instances that derive theirs and of the visual instances.
    rows:=u64(len(extras))
    for &instance in extras {
        rows=rows*31+u64(instance.material)
        for row in instance.slot_materials {rows=rows*31+u64(row)}
        for layer in instance.overlays.entries {rows=rows*31+u64(layer.material)}
    }
    if a.appearance!=sync.assets_appearance || a.stats.derived!=sync.derived || rows!=sync.extra_rows {
        if a.appearance==sync.assets_appearance {host.assets_appearance_begin(a)}
        batches_retain(a,r)
        #reverse for e,i in sync.deriving {
            at:=instance_of(sync,e)
            if at<0 || !sync.drawn.values[at].derives {
                unordered_remove(&sync.deriving,i)
                continue
            }
            if material,slots,overlays,held:=gpu.scene_instance_materials(r,u32(at));held {instance_materials_retain(a,material,slots,overlays)}
        }
        for instance in extras {instance_materials_retain(a,instance.material,instance.slot_materials,instance.overlays)}
        for light in r.scene.lights {if light.direction_cone.w==gpu.GPU_LIGHT_RECT {host.assets_material_retain(a,transmute(u32)light.size.w)}}
        host.assets_appearance_end(a);host.assets_commit(a)
        sync.assets_appearance,sync.derived,sync.extra_rows=a.appearance,a.stats.derived,rows
    }

    lights_settle(sync,a,r,t,&c,sync.under[:shaded],extras)
    // The sun that lights the world: the one previewed, or else the first not hidden.
    // .ptr spelled out: a field reached through using in a ternary is loaded before its nil check (see ODIN_WORKAROUNDS).
    own:gpu.Sun_Desc
    fade:Sun_Height_Fade
    if sun,direction,found:=sun_on(worlds,suns,preview.ptr!=nil?preview.ptr.sun:core.NONE,hidden,parents);found {
        own={direction=direction,color=sun.color,illuminance=sun.illuminance,enabled=true,disc=sun.disc}
        fade=sun.height_fade
    }
    sky_entity,sky,sky_found:=sky_previewed(skies,preview)
    if !sky_found {sky_entity,sky,sky_found=sky_active(skies,hidden,parents)}
    environment:=sky_environment(sky_entity,sky,sky_found,own.enabled,worlds,a)
    // It dims with the height of the view.
    given:=own
    given.illuminance*=sun_height_factor(fade,view.position.y)
    if given!=sync.sun || environment!=sync.environment {gpu.scene_set_environment(r,given,environment)}
    sync.sun=given
    sync.environment=environment

    looked:=view.position
    if preview.ptr!=nil && preview.section!=core.NONE {
        if at,placed:=core.get(worlds,preview.section);placed {looked=at.position}
    }
    look:=view_volume_at(view_volumes,{volumes,worlds,parents,sections},looked)
    exposure:=host.render_exposure(view_exposure_of(look))
    exposure.own=false
    gpu.scene_set_exposure(r,exposure)
    if whole || outline_styles.ptr^!=sync.outline_styles {
        gpu.renderer_set_outline_style(r,outline_style_of(outline_styles.ptr^))
        sync.outline_styles=outline_styles.ptr^
    }
    stack:=look.layers
    if whole || stack!=sync.postprocess {
        gpu.renderer_set_postprocesses(r,postprocess_effects(a,stack))
        sync.postprocess=stack
    }
    if sync.starved {sync_fail(sync,r)}
}

// The tables render_sync makes instances and lights from.
@(private)
Sync_Tables :: struct {
    worlds:^core.Table(core.World_Transform,.Read),
    meshes:^core.Table(Mesh_Renderer,.Read),
    values:^core.Table(Material_Values,.Read),
    hidden:^core.Table(Hidden,.Read),
    elsewhere:^core.Table(Drawn_Elsewhere,.Read),
    parents:^core.Table(core.Parent,.Read),
    highlights:^core.Table(Highlight,.Read),
    outlines:^core.Table(Outline,.Read),
    offsets:^core.Table(Draw_Offset,.Read),
    layers:^core.Table(Layers,.Read),
    locals:^core.Table(core.Transform,.Read), // what instance_place chains what a camera carries from
    cameras:^core.Table(Camera,.Read),
    points:^core.Table(Point_Light,.Read),
    spots:^core.Table(Spot_Light,.Read),
    rects:^core.Table(Rect_Light,.Read),
    emissions:^core.Table(Light_Emission,.Read),
    posed:^Posed_Meshes,
    owned:[VIEW_SLOTS]core.Entity, // View_Bodies
}

// What each table was when the sync last looked, and what it changed since.
@(private)
Sync_Seen :: struct {meshes,worlds,values,hidden,elsewhere,parents,offsets,layers,highlights,outlines,points,spots,rects,emissions:core.Seen}
@(private)
Sync_Changes :: struct {meshes,worlds,values,hidden,elsewhere,parents,offsets,layers,highlights,outlines,points,spots,rects,emissions:core.Changes}

// What the tables changed since the last frame. whole: one of them is other
// rows than the sync saw, and what it lost is not known.
@(private)
sync_changes :: proc(sync:^Render_Sync,t:Sync_Tables) -> (c:Sync_Changes,whole:bool) {
    s:=&sync.seen
    c={
        meshes=core.changes(t.meshes,&s.meshes),worlds=core.changes(t.worlds,&s.worlds),values=core.changes(t.values,&s.values),
        hidden=core.changes(t.hidden,&s.hidden),elsewhere=core.changes(t.elsewhere,&s.elsewhere),parents=core.changes(t.parents,&s.parents),
        offsets=core.changes(t.offsets,&s.offsets),layers=core.changes(t.layers,&s.layers),
        highlights=core.changes(t.highlights,&s.highlights),outlines=core.changes(t.outlines,&s.outlines),points=core.changes(t.points,&s.points),
        spots=core.changes(t.spots,&s.spots),rects=core.changes(t.rects,&s.rects),emissions=core.changes(t.emissions,&s.emissions),
    }
    whole=c.meshes.all || c.worlds.all || c.values.all || c.hidden.all || c.elsewhere.all || c.parents.all || c.offsets.all
    whole||=c.layers.all || c.highlights.all || c.outlines.all || c.points.all || c.spots.all || c.rects.all || c.emissions.all
    return
}

// Forgets what the renderer was given: every row of every table is a change
// again, the instances that come take the places of those the renderer has,
// and its lights go.
@(private)
sync_forget :: proc(sync:^Render_Sync,r:^gpu.Renderer) {
    core.entity_map_clear(&sync.drawn)
    for _,users in sync.mesh_users {delete(users)}
    clear(&sync.mesh_users)
    clear(&sync.changed);clear(&sync.lerping);clear(&sync.deriving);clear(&sync.replaced)
    clear(&sync.light_owners)
    for &lit in sync.lit {core.entity_map_clear(&lit)}
    lights_clear(r)
    sync.seen={}
    sync.owned={}
    sync.starved=false
}

// The renderer without lights, the last going first.
@(private)
lights_clear :: proc(r:^gpu.Renderer) {
    for i:=len(r.scene.lights)-1;i>=0;i-=1 {gpu.scene_light_remove(r,u32(i))}
}

// Without memory, or refused by the renderer: its scene is empty until a
// frame gives it everything again.
@(private)
sync_fail :: proc(sync:^Render_Sync,r:^gpu.Renderer) {
    gpu.scene_update(r,0,nil,true)
    sync.synced,sync.starved=false,false
}

// Appends to a list of the sync. Without memory the frame goes on without it
// and ends with an empty scene (sync_fail).
@(private)
push :: proc(sync:^Render_Sync,list:^[dynamic]$T,value:T) {
    if _,error:=append(list,value);error!=nil {sync.starved=true}
}

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

// The instance of an entity, if it is drawn, is made again in this frame.
@(private)
instance_changed :: proc(sync:^Render_Sync,e:core.Entity) {
    if drawn:=core.entity_map_get(&sync.drawn,e);drawn!=nil && !drawn.changed {
        drawn.changed=true
        push(sync,&sync.changed,e)
    }
}

// An entity whose mesh may start or stop being drawn, or be made again.
@(private)
entity_changed :: proc(sync:^Render_Sync,e:core.Entity) {
    if instance_of(sync,e)>=0 {instance_changed(sync,e)} else {push(sync,&sync.changed,e)}
}

// The entities a table changed go to under; below, also what hangs from them.
@(private)
changes_gather :: proc(sync:^Render_Sync,h:core.Ref(core.Hierarchy),table:^core.Table($T,$A),c:core.Changes,below:bool) {
    c:=c
    for e in c.gone {
        if below {subtree_gather(sync,h,e)} else {push(sync,&sync.under,e)}
    }
    for row in core.each_changed(table,&c) {
        if e:=core.entity_at(table,row);below {subtree_gather(sync,h,e)} else {push(sync,&sync.under,e)}
    }
}

// e and what hangs from it go to under.
@(private)
subtree_gather :: proc(sync:^Render_Sync,h:core.Ref(core.Hierarchy),e:core.Entity) {
    for at:=e;at!=core.NONE;at=core.subtree_next(h,e,at) {push(sync,&sync.under,at)}
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

// Whether the mesh of an entity is drawn: on, placed, not drawn by another
// library, and with a mesh the renderer has.
@(private)
instance_wanted :: proc(a:^host.Assets,t:Sync_Tables,e:core.Entity) -> bool {
    static,has_mesh:=core.get(t.meshes,e)
    if !has_mesh || !core.has(t.worlds,e) || core.has(t.elsewhere,e) {return false}
    _,known:=mesh_handle(a,static)
    return known
}

// The mesh of the renderer a Mesh_Renderer draws; false while it has none.
mesh_handle :: proc(a:^host.Assets,static:Mesh_Renderer) -> (handle:Mesh_Handle,ok:bool) {
    mesh:=static.mesh!={}?host.assets_mesh(a,static.mesh):host.assets_shape(a,static.shape)
    if mesh==nil || mesh.handle==host.ASSETS_MESH_NONE {return}
    return mesh.handle,true
}

// The instance of the mesh of an entity, with its values, visibility,
// outline and layers, and with the mesh a library poses for it in place of
// its own (Posed_Meshes).
@(private)
instance_make :: proc(a:^host.Assets,t:Sync_Tables,e:core.Entity,static:Mesh_Renderer,world:core.World_Transform,frame:core.Frame_Time) -> (instance:gpu.Instance_Desc,derives,ok:bool) {
    values:=MATERIAL_VALUES_DEFAULT
    if own,has_values:=core.get(t.values,e);has_values {values=own}
    anchor,transform:=instance_place(world,frame,t.offsets,t.parents,t.worlds,t.locals,t.cameras,e)
    instance,ok=mesh_instance(a,static,transform,values)
    instance.anchor=anchor
    if !ok {return}
    // A pose whose mesh the renderer no longer has draws nothing: the mesh of the entity shows.
    if pose:=t.posed!=nil?core.entity_map_get(&t.posed.poses,e):nil;pose!=nil {
        if _,_,known:=gpu.mesh_bounds(a.renderer,pose.mesh);known {instance.mesh=pose.mesh}
    }
    instance.object_id=u64(e)
    instance.hidden=is_hidden(t.hidden,t.parents,e)
    if !instance.hidden {instance.highlight=instance_outline(t.highlights,t.outlines,e)}
    if in_layers,has_layers:=core.get(t.layers,e);has_layers {instance.layers=in_layers.mask}
    instance.owner=body_owner(t,e)
    return instance,!material_values_plain(&values) || instance.overlays.count>0,true
}

// The instance of the world at `at` as its rows are now, for the renderer,
// and what the sync keeps of it. False for one that cannot be drawn: it is
// to go in this frame.
@(private)
instance_given :: proc(sync:^Render_Sync,a:^host.Assets,t:Sync_Tables,at:int,frame:core.Frame_Time) -> (instance:gpu.Instance_Desc,ok:bool) {
    e:=sync.drawn.entities[at]
    static,has_mesh:=core.get(t.meshes,e)
    world,placed:=core.get(t.worlds,e)
    if !has_mesh || !placed {return}
    // The rows it derives are of a round of them, which the frame closes with those in use.
    if a.appearance==sync.assets_appearance {host.assets_appearance_begin(a)}
    derives:bool
    instance,derives=instance_make(a,t,e,static,world,frame) or_return
    drawn:=&sync.drawn.values[at]
    if drawn.mesh!=static.mesh {
        mesh_user_remove(sync,drawn.mesh,e)
        mesh_user_add(sync,static.mesh,e)
    }
    lerp:=world.previous!=world.transform
    if derives && !drawn.derives {push(sync,&sync.deriving,e)}
    if lerp && !drawn.lerp {push(sync,&sync.lerping,e)}
    drawn.mesh,drawn.derives,drawn.lerp=static.mesh,derives,lerp
    instance.hidden||=drawn.replaced!=0
    return instance,true
}

// The Material_Values written or added. Those of an entity that shows the
// same rows with them are given in place: a color, an emission and the values
// its instance holds, which the renderer leaves as they are when they are the
// same. A texture and layers of its own make the instance again.
@(private)
values_settle :: proc(sync:^Render_Sync,a:^host.Assets,r:^gpu.Renderer,t:Sync_Tables,c:^core.Changes) {
    clear(&sync.tinted);clear(&sync.tinted_colors);clear(&sync.tinted_emissions);clear(&sync.tinted_values)
    for row in core.each_changed(t.values,c) {
        e:=core.entity_at(t.values,row)
        at:=instance_of(sync,e)
        if at<0 || sync.drawn.values[at].changed {continue}
        static,has_mesh:=core.get(t.meshes,e)
        made,usable:=mesh_instance(a,static,1,core.at(t.values,row))
        material,slots,overlays,held:=gpu.scene_instance_materials(r,u32(at))
        if !has_mesh || !usable || !held || made.material!=material || made.slot_materials!=slots || made.overlays!=overlays {
            instance_changed(sync,e)
            continue
        }
        push(sync,&sync.tinted,u32(at));push(sync,&sync.tinted_colors,made.tint);push(sync,&sync.tinted_emissions,made.emission);push(sync,&sync.tinted_values,made.material_values)
    }
}

// Keeps through a round of derived rows those an instance shows: its
// material, those of its slots and its layers.
@(private)
instance_materials_retain :: proc(a:^host.Assets,material:gpu.Material_Handle,slots:[32]u32,overlays:gpu.Instance_Overlays) {
    host.assets_material_retain(a,u32(material))
    for row in slots {if row>0 {host.assets_material_retain(a,row-1)}}
    for i in 0..<min(int(overlays.count),len(overlays.entries)) {host.assets_material_retain(a,u32(overlays.entries[i].material))}
}

// Takes out the instance at `at`, which is no longer drawn: the last one of
// the world takes its place, and the renderer is given it there, with the
// motion from where it had it. One that is to go too is not given: its place
// is given again when it goes. False when the renderer refused it.
@(private)
instance_remove :: proc(sync:^Render_Sync,a:^host.Assets,r:^gpu.Renderer,t:Sync_Tables,at:int,frame:core.Frame_Time) -> bool {
    last:=len(sync.drawn.values)-1
    mesh_user_remove(sync,sync.drawn.values[at].mesh,sync.drawn.entities[at])
    core.entity_map_remove_at(&sync.drawn,at)
    if at==last {return true}
    instance,made:=instance_given(sync,a,t,at,frame)
    if !made {return true}
    host.assets_commit(a)
    return gpu.scene_update(r,u32(at),{instance}) && gpu.scene_instance_was(r,u32(at),u32(last))
}

// The instances the renderer has: those of the meshes of the world, then the
// visual instances of the frame.
instance_count :: proc(renderer:^Renderer) -> int {return len(renderer.scene.instance_keys)}

// Changes when an index of the instances the renderer has names another, or
// they are another number: what was given to each by its index holds while it
// stays.
instance_revision :: proc(renderer:^Renderer) -> u64 {return renderer.scene.instance_revision}

// The object an instance of the renderer is drawn for (gpu.Instance_Desc.object_id):
// the entity of a mesh of the world, or what a visual instance names. 0 for none.
instance_object :: proc(renderer:^Renderer,instance:int) -> u64 {
    keys:=renderer.scene.instance_keys[:]
    return instance>=0 && instance<len(keys)?keys[instance].object:0
}

// Whether e or something above it is Hidden.
is_hidden :: proc(hidden:^core.Table(Hidden,$A),parents:^core.Table(core.Parent,$B),e:core.Entity) -> bool {
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
offset_of_entity :: proc(offsets:^core.Table(Draw_Offset,$A),parents:^core.Table(core.Parent,$B),worlds:^core.Table(core.World_Transform,$C),e:core.Entity) -> (offset:Draw_Offset,pivot:[3]f32,ok:bool) {
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
instance_place :: proc(world:core.World_Transform,frame:core.Frame_Time,offsets:^core.Table(Draw_Offset,$A),parents:^core.Table(core.Parent,$B),worlds:^core.Table(core.World_Transform,$C),locals:^core.Table(core.Transform,.Read),cameras:^core.Table(Camera,.Read),e:core.Entity) -> (anchor:[3]f32,transform:mm.Mat4) {
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
camera_carried :: proc(frame:core.Frame_Time,offsets:^core.Table(Draw_Offset,$A),parents:^core.Table(core.Parent,$B),worlds:^core.Table(core.World_Transform,$C),locals:^core.Table(core.Transform,$D),cameras:^core.Table(Camera,$E),e:core.Entity) -> (eye:[3]f32,carried:mm.Transform,ok:bool) {
    if cameras==nil || locals==nil || core.count(cameras)==0 {return}
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

instance_matrix :: proc(world:core.World_Transform,frame:core.Frame_Time,offsets:^core.Table(Draw_Offset,$A),parents:^core.Table(core.Parent,$B),worlds:^core.Table(core.World_Transform,$C),e:core.Entity) -> mm.Mat4 {
    shown:=drawn_transform(world,frame)
    if offset,pivot,ok:=offset_of_entity(offsets,parents,worlds,e);ok {
        rotation:=offset.rotation!=0?offset.rotation:1
        shown.position=pivot+offset.offset+mm.quat_rotate(rotation,shown.position-pivot)
        shown.rotation=rotation*shown.rotation
    }
    return mm.transform_matrix(shown)
}

// Whether a mesh shows a material: in a slot, or as a layer of the material
// of its first slot.
@(private)
instance_shows :: proc(a:^host.Assets,static:Mesh_Renderer,material:base.Asset_Id) -> bool {
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
mesh_user_add :: proc(sync:^Render_Sync,id:base.Asset_Id,e:core.Entity) {
    if id=={} {return}
    users:=sync.mesh_users[id]
    push(sync,&users,e)
    sync.mesh_users[id]=users
}

@(private)
mesh_user_remove :: proc(sync:^Render_Sync,id:base.Asset_Id,e:core.Entity) {
    if id=={} {return}
    users,found:=sync.mesh_users[id]
    if !found {return}
    for value,i in users {if value==e {unordered_remove(&users,i);break}}
    if len(users)==0 {delete(users);delete_key(&sync.mesh_users,id)} else {sync.mesh_users[id]=users}
}

// The sun that lights the world: the one previewed (Environment_Preview), or
// else the first not hidden.
@(private)
sun_on :: proc(worlds:^core.Table(core.World_Transform,$A),suns:^core.Table(Sun,$B),preview:core.Entity,hidden:^core.Table(Hidden,$C),parents:^core.Table(core.Parent,$D)) -> (sun:Sun,direction:[3]f32,found:bool) {
    if preview!=core.NONE && suns!=nil {
        if row:=core.raw_row(core.raw(suns),preview);row>=0 {
            if world,placed:=core.get(worlds,preview);placed {
                return suns.values[row],mm.quat_rotate(world.rotation,[3]f32{0,0,1}),true
            }
        }
    }
    placed:=core.join(suns,worlds)
    for e,sun,world in core.each_joined(&placed) {
        if !is_hidden(hidden,parents,e) {return sun,mm.quat_rotate(world.rotation,[3]f32{0,0,1}),true}
    }
    return
}

// An entity gives the renderer a light for each of these it has on, placed
// and not hidden.
@(private)
Light_Kind :: enum u8 {Point,Spot,Rect}

@(private)
Light_Owner :: struct {entity:core.Entity,kind:Light_Kind}

// The light of a kind of an entity as its rows are now: given, given again,
// or taken out, when the last light of the renderer takes its place.
@(private)
light_settle :: proc(sync:^Render_Sync,a:^host.Assets,r:^gpu.Renderer,t:Sync_Tables,extras:[]gpu.Instance_Desc,e:core.Entity,kind:Light_Kind) {
    desc:gpu.Light_Desc
    on:=false
    world,placed:=core.get(t.worlds,e)
    switch kind {
    case .Point:
        if point,has:=core.get(t.points,e);has && placed {
            desc=sphere_desc(world,point.color,point.intensity,point.range,point.radius)
            on=true
        }
    case .Spot:
        if spot,has:=core.get(t.spots,e);has && placed {
            desc=sphere_desc(world,spot.color,spot.intensity,spot.range,spot.radius)
            desc.direction,desc.cone=mm.quat_forward(world.rotation),spot.angle
            on=true
        }
    case .Rect:
        if rect,has:=core.get(t.rects,e);has && placed {
            desc=rect_desc(world,rect)
            on=true
            if emission,shows:=core.get(t.emissions,e);shows {desc.material=emission_material(sync,a,r,t,extras,e,u32(emission.slot))}
        }
    }
    on&&=gpu.light_gives(desc) && !is_hidden(t.hidden,t.parents,e)
    at:=core.entity_map_get(&sync.lit[kind],e)
    switch {
    case at==nil && !on:
    case at==nil:
        // Without memory in the renderer or here for the light, a later frame gives it everything again.
        if !gpu.scene_light_update(r,u32(len(sync.light_owners)),desc) {sync.starved=true;return}
        if _,kept:=core.entity_map_put(&sync.lit[kind],e,u32(len(sync.light_owners)));!kept {sync.starved=true;return}
        push(sync,&sync.light_owners,Light_Owner{e,kind})
    case on:
        if !gpu.scene_light_update(r,at^,desc) {sync.starved=true}
    case:
        gpu.scene_light_remove(r,at^)
        last:=pop(&sync.light_owners)
        if place:=at^;int(place)<len(sync.light_owners) {
            sync.light_owners[place]=last
            core.entity_map_get(&sync.lit[last.kind],last.entity)^=place
        }
        core.entity_map_remove(&sync.lit[kind],e)
    }
}

// The lights whose rows, place or visibility changed since the last frame
// are given again; the others stay as the renderer has them.
@(private)
lights_settle :: proc(sync:^Render_Sync,a:^host.Assets,r:^gpu.Renderer,t:Sync_Tables,c:^Sync_Changes,shaded:[]core.Entity,extras:[]gpu.Instance_Desc) {
    rows :: proc(sync:^Render_Sync,a:^host.Assets,r:^gpu.Renderer,t:Sync_Tables,extras:[]gpu.Instance_Desc,table:^core.Table($T,$A),c:^core.Changes,kind:Light_Kind) {
        for e in c.gone {light_settle(sync,a,r,t,extras,e,kind)}
        for row in core.each_changed(table,c) {light_settle(sync,a,r,t,extras,core.entity_at(table,row),kind)}
    }
    rows(sync,a,r,t,extras,t.points,&c.points,.Point)
    rows(sync,a,r,t,extras,t.spots,&c.spots,.Spot)
    rows(sync,a,r,t,extras,t.rects,&c.rects,.Rect)
    rows(sync,a,r,t,extras,t.emissions,&c.emissions,.Rect)
    if core.count(t.points)+core.count(t.spots)+core.count(t.rects)+len(sync.light_owners)==0 {return}
    // A place written or gone, or something hidden or shown above: of every kind the entity has.
    c.worlds.row=0
    for e in c.worlds.gone {for kind in Light_Kind {light_settle(sync,a,r,t,extras,e,kind)}}
    for row in core.each_changed(t.worlds,&c.worlds) {for kind in Light_Kind {light_settle(sync,a,r,t,extras,core.entity_at(t.worlds,row),kind)}}
    for e in shaded {for kind in Light_Kind {light_settle(sync,a,r,t,extras,e,kind)}}
    // The material a screen shows changes with what its mesh is drawn with: made again, or replaced in this frame.
    if core.count(t.emissions)==0 {return}
    for at in sync.made {light_settle(sync,a,r,t,extras,sync.drawn.entities[at],.Rect)}
    for e in sync.replaced {light_settle(sync,a,r,t,extras,e,.Rect)}
    for at in sync.tinted {light_settle(sync,a,r,t,extras,sync.drawn.entities[at],.Rect)}
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
// something does, or else as the renderer has it with what the entity gives
// the slot. 0: none.
@(private)
emission_material :: proc(sync:^Render_Sync,a:^host.Assets,r:^gpu.Renderer,t:Sync_Tables,extras:[]gpu.Instance_Desc,e:core.Entity,slot:u32) -> gpu.Material_Handle {
    static,has_mesh:=core.get(t.meshes,e)
    at:=instance_of(sync,e)
    if !has_mesh || at<0 {return 0}
    shown:gpu.Instance_Desc
    values:=MATERIAL_VALUES_DEFAULT
    if sync.drawn.values[at].replaced!=0 {
        for extra in extras {if extra.replace_source && extra.object_id==u64(e) {shown=extra;break}}
    } else if material,slots,_,held:=gpu.scene_instance_materials(r,u32(at));held {
        shown.material,shown.slot_materials=material,slots
        if own,has_values:=core.get(t.values,e);has_values {values=own}
    }
    // A light is given a row: the one those values derive.
    row:=mesh_slot_row(a,static,&shown,slot)
    desc:=host.assets_material_values(a,row)
    given:=desc
    material_values_apply(a,&given,&values,int(slot))
    if given!=desc {
        if derived,derives:=host.assets_material_derive(a,given);derives {row=derived}
    }
    return gpu.Material_Handle(row)
}

// The row of the material a mesh is drawn with in a slot of an instance.
mesh_slot_row :: proc(a:^host.Assets,static:Mesh_Renderer,instance:^gpu.Instance_Desc,slot:u32) -> u32 {
    mesh:=static.mesh!={}?host.assets_mesh(a,static.mesh):host.assets_shape(a,static.shape)
    if mesh==nil || mesh.slot_count==0 {return u32(instance.material)}
    index:=min(int(slot),int(mesh.slot_count)-1,len(instance.slot_materials)-1)
    if row:=instance.slot_materials[index];row>0 {return row-1}
    material:=index<MATERIAL_SLOTS?static.materials[index]:base.Asset_Id{}
    return host.assets_material_row(a,material!={}?material:mesh.slot_materials[index])
}

// The instance of an entity; -1 when it is not drawn.
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
    place :: proc(sync:^Render_Sync,t:Sync_Tables,world:core.World_Transform,at:int,frame:core.Frame_Time) {
        anchor,m:=instance_place(world,frame,t.offsets,t.parents,t.worlds,t.locals,t.cameras,sync.drawn.entities[at])
        push(sync,&sync.moved,u32(at));push(sync,&sync.moved_transforms,m);push(sync,&sync.moved_anchors,anchor)
    }
    for row in core.each_changed(t.worlds,&c) {
        e:=core.entity_at(t.worlds,row)
        at:=instance_of(sync,e)
        if at<0 {continue}
        world:=core.at(t.worlds,row)
        lerp:=world.previous!=world.transform
        drawn:=&sync.drawn.values[at]
        if lerp && !drawn.lerp {push(sync,&sync.lerping,e)}
        drawn.lerp=lerp
        place(sync,t,world,at,frame)
    }
    #reverse for e,i in sync.lerping {
        at:=instance_of(sync,e)
        if at<0 || !sync.drawn.values[at].lerp {
            unordered_remove(&sync.lerping,i)
            continue
        }
        world,_:=core.get(t.worlds,e)
        place(sync,t,world,at,frame)
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
    value:=value
    return material_standard_value(&values.info,name,&value,true)
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

// Whether an entity shows its materials as they are: an opaque white color, no light and nothing by name.
material_values_plain :: proc "contextless" (o:^Material_Values) -> bool {
    return o.color=={1,1,1,1} && o.emission=={} && o.count==0 && o.texture_count==0 && !o.own_overlays
}

// Whether an entity gives a value or a texture to the material of a slot.
material_values_slot :: proc "contextless" (o:^Material_Values,slot:int) -> bool {
    for stored in o.texture_slots[:min(int(o.texture_count),len(o.texture_slots))] {
        if int(stored)==slot {return true}
    }
    for stored in o.slots[:min(int(o.count),len(o.slots))] {
        if int(stored)==slot {return true}
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
// textures.
material_values_apply :: proc(a:^host.Assets,values:^gpu.Material_Desc,o:^Material_Values,slot:int,held:=true) {
    program:=surface_program(a,values.program_id)
    for name,i in o.names[:min(int(o.count),len(o.names))] {
        if held && int(o.slots[i])==slot {material_value_apply(values,program,name,o.values[i])}
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

// Shows a texture the renderer made at run time (the panel of a widget, the
// image of a camera) in a slot of an entity, in place of the one the entity
// showed that way: as the base color of a white surface or, lit, as the light
// of a black one. 0 shows none.
material_screen :: proc(o:^Material_Values,slot:int,texture:gpu.Texture_Handle,lit:=false,emission:f32=0) {
    color,light,color_map,light_map:=base.name_hash("base_color"),base.name_hash("emission"),base.name_hash("maps.base_color"),base.name_hash("maps.emission")
    for i:=len(o.shown)-1;i>=0;i-=1 {
        if o.shown[i]==0 {continue}
        was:=int(o.texture_slots[i])
        material_texture_drop(o,color_map,was);material_texture_drop(o,light_map,was)
        material_value_drop(o,color,was);material_value_drop(o,light,was)
    }
    if texture==0 {return}
    material_texture(o,lit?light_map:color_map,slot,{},texture)
    material_value_hashed(o,color,lit?0:1,slot)
    if lit {
        material_texture(o,color_map,slot,{})
        material_value_hashed(o,light,emission,slot)
    }
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

// A World that is freed while the renderer shows it takes its instances and
// its lights with it; the World shown next is given whole.
@(step="release")
render_release :: proc(sync:^Render_Sync,id:core.World_Id,renderer:^Renderer) {
    if sync.world!=id {return}
    sync.world,sync.synced={},false
    if renderer!=nil {
        gpu.scene_update(renderer,0,nil,true)
        lights_clear(renderer)
    }
}

sync_free :: proc(sync:^Render_Sync) {
    for _,users in sync.mesh_users {delete(users)}
    delete(sync.mesh_users)
    sync.mesh_users=nil
    core.value_free(sync,type_info_of(Render_Sync))
}

// The same geometry and appearance for world entities and temporary visual
// instances. The instance holds the color, the fade, the light and the values
// of `values`, for the rows its slots show: the slots that show one material
// share them.
mesh_instance :: proc(a:^host.Assets,static:Mesh_Renderer,transform:mm.Mat4,values:=MATERIAL_VALUES_DEFAULT) -> (instance:gpu.Instance_Desc,ok:bool) {
    values:=values
    mesh:=static.mesh!={}?host.assets_mesh(a,static.mesh):host.assets_shape(a,static.shape)
    if mesh==nil || mesh.handle==host.ASSETS_MESH_NONE {return {},false}
    instance=gpu.Instance_Desc{mesh=mesh.handle,transform=transform,tint=values.color.rgb,emission=values.emission}
    instance.material_values.fade=1-clamp(values.color.a,0,1)
    shown:=static.materials[0]
    if mesh.slot_count==0 {
        row:=host.assets_material_row(a,shown)
        instance.material=gpu.Material_Handle(material_values_slot(&values,0)?slot_row(a,&instance,row,&values,0):row)
    } else {
        if shown=={} {shown=mesh.slot_materials[0]}
        for slot in 0..<mesh.slot_count {
            material:=slot<MATERIAL_SLOTS?static.materials[slot]:base.Asset_Id{}
            if material_values_slot(&values,int(slot)) {
                shown_row:=host.assets_material_row(a,material!={}?material:mesh.slot_materials[slot])
                instance.slot_materials[slot]=slot_row(a,&instance,shown_row,&values,int(slot))+1
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

// The row a slot of an instance shows of a material with that row, with what
// an entity gives the slot: one of its own with its textures; `instance`
// holds what its values change of that row.
@(private)
slot_row :: proc(a:^host.Assets,instance:^gpu.Instance_Desc,row:u32,values:^Material_Values,slot:int) -> u32 {
    shown,desc:=row,host.assets_material_values(a,row)
    textured:=desc
    material_values_apply(a,&textured,values,slot,false)
    if textured!=desc {
        if derived,ok:=host.assets_material_derive(a,textured);ok {shown,desc=derived,textured}
    }
    given:=desc
    material_values_apply(a,&given,values,slot)
    gpu.instance_material_values_hold(a.renderer,&instance.material_values,shown,desc,given)
    return shown
}
