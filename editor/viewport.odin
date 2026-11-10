package editor

import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import eaudio "mirai:engine/audio"
import evolume "mirai:engine/volume"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:platform"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// The scene under the panels: the camera of the editor (a target with yaw,
// pitch and distance), what the pointer does there (look, fly, pan, zoom,
// select, the gizmo, what a panel drops) and what the editor draws over it
// (the grid, the discs of what has no body, the box of a selection). The
// editor writes the core.View of the World shown, so the renderer and any
// library that depends on the point of view see its camera; a Play shows the
// camera of the game when it has one.

VIEW_FOV :: f32(50) // degrees, vertical: the one the camera of the editor starts with
VIEW_FOV_MIN :: f32(1)
VIEW_FOV_MAX :: f32(170)

// The studio light in place of the sun and the sky of the world: always in a
// prefab, whose sun preview_sun turns on, and in a scene while the viewport
// asks for it (studio_light), without its ground, which the grid of the editor
// shows. Nothing of the world changes; turned off, the scene gets back its own.
@(step="render")
studio_lighting :: proc(s:^Session,app:^host.App,sync:core.Ref(erender.Render_Sync)) {
    r:=app.renderer
    if r==nil || app.ui_only {return}
    prefab:=document_is_prefab(s)
    if playing(s) || !prefab && !s.viewport.studio_light {
        if s.studio_shown && sync.ptr!=nil {gpu.scene_set_environment(r,sync.sun,sync.environment,true)}
        s.studio_shown=false
        return
    }
    s.studio_shown=true
    sun:=PREVIEW_SUN
    environment:=PREVIEW_ENVIRONMENT
    if prefab {sun.enabled=s.viewport.preview_sun} else {environment.ground_grid=false}
    normalized:=sun
    if linalg.length(sun.direction)>1e-6 {normalized.direction=linalg.normalize(sun.direction)} else {normalized.enabled=false}
    if r.scene.sun!=normalized || r.scene.environment!=environment {gpu.scene_set_environment(r,sun,environment,true)}
}
VIEW_NEAR :: f32(0.1)
VIEW_PITCH_LIMIT :: f32(1.55)
VIEW_LOOK_SPEED :: f32(0.005) // radians per point
VIEW_FLY_SPEED :: f32(15)     // m/s
VIEW_FLY_FAST :: f32(3)
VIEW_FLY_STEP :: f32(1.1)     // per wheel notch
VIEW_PAN_SPEED :: f32(0.0015) // of the distance, per point
VIEW_ZOOM_STEP :: f32(0.88)   // of the distance, per wheel notch
VIEW_DISTANCE_MIN :: f32(0.25)
VIEW_DISTANCE_MAX :: f32(500)
DRAG_THRESHOLD :: f32(4)      // points a press travels before it is a drag
GRID_EXTENT :: 40             // lines of 1 m each side of the center
// The arrows that say where a sun shines to: around its disc, metres.
SUN_ARROWS :: 6
SUN_ARROW_RING :: f32(0.45)
SUN_ARROW_START :: f32(0.35)
SUN_ARROW_LENGTH :: f32(0.7)
SUN_ARROW_HEAD :: f32(0.16)
SPOT_CONE_LINES :: 8 // from a selected spot to the edge of its cone
GRID_MAJOR :: 10
LINE_CAPACITY :: 4096         // vertices of the lines the editor draws in a frame
INDICATOR_RADIUS :: f32(11)
INDICATOR_HIT :: f32(14)
INDICATOR_EXTENT :: f32(0.35) // m: half the box an entity without a body counts for when framed
HIGHLIGHT_SELECTED :: u8(1)
HIGHLIGHT_DESCENDANT :: u8(2)

Orbit :: struct {
    target:[3]f32,
    yaw,pitch,distance:f32,
    fov:f32, // degrees, vertical
}

ORBIT_DEFAULT :: Orbit{target={0,1,0},yaw=0.25,pitch=0.85,distance=17,fov=VIEW_FOV}

Tool :: enum u8 {Move,Rotate,Scale}
Space :: enum u8 {World,Local}

// What holds the pointer since it was pressed on the scene.
Capture :: enum u8 {None,Look,Pan,Select,Gizmo}

// How the viewport moves, snaps and what it shows besides the scene: the
// same for every document, and kept between sessions (preferences.odin).
Viewport_Preferences :: struct {
    fly_speed:f32,  // m/s, before Shift
    space:Space,    // of the axes of the move and rotate gizmo
    snap:bool,      // also while Ctrl is held
    grid:f32,       // m a move snaps to
    snap_rotate,snap_scale:bool,
    snap_off:bool,  // the magnet: off, no snap applies and each keeps whether it is on
    rotate_increment,scale_increment:f32,
    show_grid:bool,
    show_indicators:bool,
    show_output_frame:bool, // the frame of a recording over the scene
    game_detail:bool, // a Play the user paused draws the detail its camera saw (Frame_Detail), wherever the editor looks from
    output_size:[2]i32,     // pixels of that frame: those of the last recording
}

VIEWPORT_PREFERENCES_DEFAULT :: Viewport_Preferences{fly_speed=VIEW_FLY_SPEED,grid=0.5,rotate_increment=15,scale_increment=0.1,show_grid=true,show_indicators=true,output_size={1920,1080}}

// Each document has its own; the one shown keeps the preferences when
// another document is shown (document_tab_exchange).
@(storage,free="viewport_free")
Viewport :: struct {
    orbit:Orbit,
    using preferences:Viewport_Preferences,
    tool:Tool,
    plugin_tool:u64, // the plugin tool that takes left presses on the scene; 0: the gizmo and the selection
    plugin_tool_name:[32]u8, // its name, for the API
    plugin_keys:core.Keys, // the keys that tool takes from the shortcuts of the editor (tool_keys)
    plugin_lends:bool, // W, E and R lend the scene of that tool to the gizmo (tool_lend)
    plugin_aside:bool, // it lent it: the gizmo and the selection take the scene and its panel stays
    preview_sun:bool,
    studio_light:bool, // a scene shows with the light of the studio (studio_lighting)
    origin:[2]f32,  // window points where the scene starts: under the bars
    size:[2]f32,    // window points of the scene
    window:[2]f32,  // window points
    pointer:[2]f32,
    pointer_delta:[2]f32,
    hovered:bool,   // the pointer is on the scene and nothing of the UI takes it
    camera:gpu.Camera,
    view_matrix,projection,view_projection:mm.Mat4,
    ray:mm.Ray,
    capture:Capture,
    press:[2]f32,
    moved:bool,     // the press travelled: a look instead of a click, a box instead of a pick
    add,toggle:bool, // Shift and Ctrl at the press
    individual:bool,
    keys:core.Keys,
    modifiers:ui.Modifiers,
    dt:f32,
    gizmo:Gizmo_State,
    indicators:[dynamic]core.Entity, // the entities without a body, as last found
    indicators_key:[6]u64,
    levels:[dynamic]u8,              // highlight by entity index, as last written
    levels_key:Highlight_Key,
    levels_serial:u64,               // grows each time levels are written again
    ghosts:[dynamic]gpu.Instance_Desc, // of what is hidden or turned off, as last made
    ghosts_key:[8]u64,
    lines_storage:[dynamic]gpu.Debug_Vertex,
    lines:gpu.Debug_Lines,
    pick:Entity_Pick,               // a field of the inspector waiting for an entity
    follow:int,                     // the other editor of the session whose camera this one follows, plus one; 0: none
    followed:Orbit,                 // the orbit it was given last: another means the user moved it
    exposure_source:Viewport_Exposure,
    exposure:core.View_Exposure,    // Camera: of the Camera of the scene camera.set looks through, until the scene changes
    ev100:f32 `mirai:"unit=EV"`,    // Manual: the exposure value at ISO 100
    view_mode:[VIEW_MODE_NAME_BYTES]u8 `mirai:"text"`, // the mode of inspection it shows (view_modes.odin); empty: lit
}

// How the editor's view exposes: as the Sky that is on, as the camera it
// looks through, or at a fixed exposure value.
Viewport_Exposure :: enum u8 {Scene,Camera,Manual}

VIEWPORT_EV100_DEFAULT :: 12

// The exposure of the editor's view.
viewport_exposure :: proc(v:^Viewport) -> core.View_Exposure {
    switch v.exposure_source {
    case .Scene:  return {}
    case .Camera: return v.exposure
    case .Manual: return {mode=.Manual,ev100=v.ev100,own=true}
    }
    return {}
}

@(private)
Highlight_Key :: struct {
    sources:[14]u64,
    marquee,add,indicators,play,isolated:bool,
    rect:ui.Rect,
    view_projection:mm.Mat4,
    size:[2]f32,
}

// A reference of the inspector being chosen in the scene or the outliner.
Entity_Pick :: struct {
    active:bool,
    kind:Entity_Pick_Kind,
    owner:core.Entity,
    table:int,  // of the world info
    offset:int,
}
Entity_Pick_Kind :: enum u8 {Field,Parent,Children}

@(private)
viewport_init :: proc(v:^Viewport) {
    v.orbit=ORBIT_DEFAULT
    v.preferences=VIEWPORT_PREFERENCES_DEFAULT
    v.preview_sun=true
    v.ev100=VIEWPORT_EV100_DEFAULT
    resize(&v.lines_storage,LINE_CAPACITY)
    v.lines=gpu.debug_lines_make(v.lines_storage[:],true)
}

viewport_free :: proc(v:^Viewport) {
    v.lines={}
    core.value_free(v,type_info_of(Viewport))
    v^={}
}

orbit_offset :: proc "contextless" (o:Orbit) -> [3]f32 {
    cp:=math.cos(o.pitch)
    return {math.sin(o.yaw)*cp,math.sin(o.pitch),math.cos(o.yaw)*cp}
}
orbit_position :: proc "contextless" (o:Orbit) -> [3]f32 {return o.target+orbit_offset(o)*o.distance}

orbit_sanitize :: proc "contextless" (o:^Orbit) {
    finite :: proc "contextless" (v:f32) -> bool {return v-v==0}
    if !finite(o.target.x) || !finite(o.target.y) || !finite(o.target.z) {o.target=ORBIT_DEFAULT.target}
    if !finite(o.yaw) {o.yaw=ORBIT_DEFAULT.yaw}
    if !finite(o.pitch) {o.pitch=ORBIT_DEFAULT.pitch}
    if !finite(o.distance) {o.distance=ORBIT_DEFAULT.distance}
    if !finite(o.fov) || o.fov<=0 {o.fov=ORBIT_DEFAULT.fov} // 0: an orbit made without one
    o.yaw=math.mod(o.yaw,math.TAU)
    o.pitch=clamp(o.pitch,-VIEW_PITCH_LIMIT,VIEW_PITCH_LIMIT)
    o.distance=clamp(o.distance,VIEW_DISTANCE_MIN,VIEW_DISTANCE_MAX)
    o.fov=clamp(o.fov,VIEW_FOV_MIN,VIEW_FOV_MAX)
}

// The orbit that puts the camera at position looking at target.
orbit_from_points :: proc "contextless" (position,target:[3]f32,fov:=VIEW_FOV) -> (o:Orbit,ok:bool) {
    offset:=position-target
    distance:=linalg.length(offset)
    if distance<1e-5 || distance-distance!=0 {return {},false}
    direction:=offset/distance
    o={target=target,yaw=math.atan2(direction.x,direction.z),pitch=math.asin(clamp(direction.y,-1,1)),distance=distance,fov=fov}
    orbit_sanitize(&o)
    return o,true
}

// The orbit that sees what a camera at a world pose sees, with its target at
// distance. The camera of the editor keeps the world up: no roll, and past
// the limit of the pitch the eye stays where it is and the target moves.
orbit_of_camera :: proc "contextless" (pose:mm.Transform,camera:erender.Camera,distance:f32) -> (o:Orbit,ok:bool) {
    fov:=camera.fov>0?camera.fov:erender.CAMERA_DEFAULT.fov
    o=orbit_from_points(pose.position,pose.position+mm.quat_forward(pose.rotation)*distance,fov*mm.DEG_PER_RAD) or_return
    o.target=pose.position-orbit_offset(o)*o.distance
    return o,true
}

orbit_basis :: proc "contextless" (o:Orbit) -> (forward,right,up:[3]f32) {
    forward=-orbit_offset(o)
    right=linalg.normalize0(linalg.cross(forward,[3]f32{0,1,0}))
    if right=={} {right={1,0,0}}
    up=linalg.normalize0(linalg.cross(right,forward))
    return
}

// Turns around the position of the camera.
orbit_look :: proc "contextless" (o:^Orbit,delta:[2]f32) {
    position:=orbit_position(o^)
    o.yaw-=delta.x*VIEW_LOOK_SPEED
    o.pitch=clamp(o.pitch+delta.y*VIEW_LOOK_SPEED,-VIEW_PITCH_LIMIT,VIEW_PITCH_LIMIT)
    o.target=position-orbit_offset(o^)*o.distance
}

// Flies: x right, y world up, z forward.
orbit_fly :: proc "contextless" (o:^Orbit,direction:[3]f32,dt,speed:f32,fast:bool) {
    if direction=={} {return}
    forward,right,_:=orbit_basis(o^)
    move:=linalg.normalize0(right*direction.x+[3]f32{0,1,0}*direction.y+forward*direction.z)
    o.target+=move*speed*(fast?VIEW_FLY_FAST:1)*dt
}

orbit_pan :: proc "contextless" (o:^Orbit,delta:[2]f32) {
    _,right,up:=orbit_basis(o^)
    o.target+=right*(-delta.x*o.distance*VIEW_PAN_SPEED)+up*(delta.y*o.distance*VIEW_PAN_SPEED)
}

orbit_zoom :: proc "contextless" (o:^Orbit,wheel:f32) {
    o.distance=clamp(o.distance*math.pow(VIEW_ZOOM_STEP,wheel),VIEW_DISTANCE_MIN,VIEW_DISTANCE_MAX)
}

// Fits every corner of a world box inside region, a part of a window of the
// given size, keeping yaw and pitch.
orbit_frame :: proc "contextless" (o:^Orbit,low,high:[3]f32,size:[2]f32,region:ui.Rect) {
    orbit_sanitize(o)
    full:=size
    if full.x<=0 || full.y<=0 {full={1280,800}}
    backward:=orbit_offset(o^)
    _,right,up:=orbit_basis(o^)
    tangent_y:=math.tan(o.fov*math.PI/360)
    tangent_x:=tangent_y*full.x/full.y
    xmin:=2*region.x/full.x-1
    xmax:=2*(region.x+region.w)/full.x-1
    ymin:=1-2*(region.y+region.h)/full.y
    ymax:=1-2*region.y/full.y
    cx,cy:=(xmin+xmax)*0.5,(ymin+ymax)*0.5
    center:=(low+high)*0.5
    distance:=f32(2)
    for corner in 0..<8 {
        p:=[3]f32{corner&1==0?low.x:high.x,corner&2==0?low.y:high.y,corner&4==0?low.z:high.z}-center
        x,y,depth:=linalg.dot(p,right),linalg.dot(p,up),linalg.dot(p,backward)
        distance=max(distance,depth+0.1)
        distance=max(distance,(x/tangent_x+xmax*depth)/max(xmax-cx,0.001))
        distance=max(distance,(-x/tangent_x-xmin*depth)/max(cx-xmin,0.001))
        distance=max(distance,(y/tangent_y+ymax*depth)/max(ymax-cy,0.001))
        distance=max(distance,(-y/tangent_y-ymin*depth)/max(cy-ymin,0.001))
    }
    o.distance=clamp(distance,2,VIEW_DISTANCE_MAX)
    o.target=center-right*(cx*o.distance*tangent_x)-up*(cy*o.distance*tangent_y)
}

// "x,y,z,yaw,pitch,distance": what a restart passes on.
view_parse :: proc(o:^Orbit,text:string) -> bool {
    parts:=strings.split(text,",",context.temp_allocator)
    if len(parts)!=6 {return false}
    values:[6]f32
    for part,i in parts {values[i]=strconv.parse_f32(part) or_return}
    o^={target={values[0],values[1],values[2]},yaw=values[3],pitch=values[4],distance=values[5]}
    orbit_sanitize(o)
    return true
}

// The camera, its matrices and the ray of the pointer, for the window as it is now.
@(private)
viewport_update :: proc(v:^Viewport,origin,size,window:[2]f32,frame:^platform.Input_Frame,modifiers:ui.Modifiers) {
    orbit_sanitize(&v.orbit)
    v.origin,v.window=origin,window
    v.size={max(size.x,1),max(size.y,1)}
    v.pointer=frame.mouse_position
    v.pointer_delta=frame.mouse_delta
    v.keys,v.modifiers,v.dt=frame.keys_down,modifiers,frame.dt
    viewport_camera(v)
}

// The matrices of the camera as the orbit is now: again after the tools moved it.
@(private)
viewport_camera :: proc(v:^Viewport) {
    orbit_sanitize(&v.orbit)
    position:=orbit_position(v.orbit)
    v.camera={position=position,forward=v.orbit.target-position,up={0,1,0},fov_y=v.orbit.fov,near=VIEW_NEAR}
    v.view_matrix=mm.look_at(position,v.orbit.target,{0,1,0})
    v.projection=mm.perspective_infinite(v.orbit.fov*mm.RAD_PER_DEG,v.size.x/v.size.y,VIEW_NEAR)
    v.view_projection=v.projection*v.view_matrix
    v.ray=mm.screen_ray(v.pointer-v.origin,v.size,v.view_matrix,v.projection)
}

// Whether a tool snaps: its snap and the magnet are on.
snapping :: proc "contextless" (v:^Viewport,tool:Tool) -> bool {
    if v.snap_off {return false}
    switch tool {
    case .Move:   return v.snap
    case .Rotate: return v.snap_rotate
    case .Scale:  return v.snap_scale
    }
    return false
}

// The ray through a point of the window.
viewport_ray :: proc(v:^Viewport,point:[2]f32) -> mm.Ray {return mm.screen_ray(point-v.origin,v.size,v.view_matrix,v.projection)}

// Where a point of the world is in the window.
viewport_screen :: proc(v:^Viewport,point:[3]f32) -> (screen:[2]f32,ok:bool) {
    screen,_,ok=mm.world_to_screen(point,v.size,v.view_projection)
    screen+=v.origin
    return
}

// The part of the window the scene takes.
viewport_rect :: proc(v:^Viewport) -> ui.Rect {return {v.origin.x,v.origin.y,v.size.x,v.size.y}}

// The camera of the World shown is the editor's while editing and while a
// Play is paused by the user, and while a game runs without a camera of its
// own. What the camera of a paused game saw is kept before the editor takes
// the view: with game_detail the detail is chosen from there.
@(private)
view_write :: proc(s:^Session,w:core.World_Ref) {
    if s.app!=nil {s.app.detail={}}
    if s.mode!=.Paused {s.paused_view={}}
    view:=core.world_storage_of(w,core.View)
    if view==nil {return}
    if (play_viewed(s) || s.mode==.Watch || camera_previewing(s)) && view.camera!=core.NONE {return}
    if s.mode==.Paused {
        if view.camera!=core.NONE {s.paused_view=view^}
        if s.viewport.game_detail && s.paused_view.camera!=core.NONE && s.app!=nil {
            s.app.detail={camera=host.camera_from_view(s.paused_view),on=true}
        }
    }
    v:=s.viewport
    forward,_,up:=orbit_basis(v.orbit)
    view.position=orbit_position(v.orbit)
    view.rotation=mm.quat_look(forward,up)
    view.fov=v.orbit.fov*mm.RAD_PER_DEG
    view.near,view.far=VIEW_NEAR,0
    view.size=host.app_scene_size(s.app)
    view.camera=core.NONE
    view.projection,view.height,view.shift,view.custom=.Perspective,0,{},{}
    view.clip_plane,view.layers,view.carried,view.focus={},0,{},0
    view.cut=s.view_cut
    view.exposure=viewport_exposure(v)
    s.view_cut=false
}

// The part of the window the bar and the panels leave to the scene.
free_region :: proc(g:^Editor_Ui,size:[2]f32) -> ui.Rect {
    if size.x<=0 || size.y<=0 {return {0,0,1280,800}}
    x0,x1:=f32(16),size.x-16
    y0,y1:=g.rects.bar.h+16,size.y-16
    if r:=g.rects.left;r.w>0 && r.h>0 {x0=max(x0,r.x+r.w+16)}
    if r:=g.rects.right;r.w>0 && r.h>0 {x1=min(x1,r.x-16)}
    if r:=g.rects.bottom;r.w>0 && r.h>0 {y1=min(y1,r.y-16)}
    if x1-x0<64 {x0,x1=16,size.x-16}
    if y1-y0<64 {y0,y1=16,size.y-16}
    margin_x,margin_y:=min((x1-x0)*0.06,24),min((y1-y0)*0.06,24)
    return {x0+margin_x,y0+margin_y,max(x1-x0-margin_x*2,1),max(y1-y0-margin_y*2,1)}
}

// Frames the selection, with what hangs from it.
focus_selection :: proc(s:^Session,w:core.World_Ref) {
    if low,high,found:=selection_bounds(s,w);found {
        // The region is of the window; the frame, of the scene.
        free:=free_region(s.gui,s.viewport.window)
        free.x-=s.viewport.origin.x
        free.y-=s.viewport.origin.y
        orbit_frame(&s.viewport.orbit,low,high,s.viewport.size,free)
    }
}

// ---------------------------------------------------------------- tools

// Turns a plugin tool on or off. On, it takes left presses on the scene from
// the gizmo, the selection and any other plugin tool. While an asset document
// covers the scene no tool turns on, and the one that was on waits for it.
tool_set :: proc(s:^Session,name:string,on:bool) {
    if on && scene_covered(s) {return}
    key:=hash.fnv64a(transmute([]u8)name)
    if (on && s.viewport.plugin_tool!=key) || (!on && s.viewport.plugin_tool==key) {tools_release(s);s.viewport.plugin_keys,s.viewport.plugin_lends={},false}
    switch {
    case on:                         s.viewport.plugin_tool=key;base.text_set(s.viewport.plugin_tool_name[:],name)
    case s.viewport.plugin_tool==key: s.viewport.plugin_tool=0
    }
    if on || s.viewport.plugin_tool==0 {s.viewport.plugin_aside=false}
    if on {
        s.gui.placement={}
        panel_show(s,s.panels,-1,false)
    }
}

// Turns off the plugin tool that is on: the gizmo and the selection take the
// scene again.
tool_leave :: proc(s:^Session) {
    tools_release(s)
    s.viewport.plugin_tool,s.viewport.plugin_keys,s.viewport.plugin_lends,s.viewport.plugin_aside=0,{},false,false
}

// The plugin tool that is on lets W, E and R, and their buttons, lend the
// scene to the gizmo and the selection: it stays on, with its panel, until
// tool_take or it turns off. A tool with a gizmo of its own does not.
tool_lend :: proc(s:^Session,name:string) {
    if tool_on(s,name) {s.viewport.plugin_lends=true}
}

// True while the plugin tool is on and lent the scene to the gizmo.
tool_aside :: proc(s:^Session,name:string) -> bool {
    return tool_on(s,name) && s.viewport.plugin_aside
}

// The plugin tool that is on takes back the scene it lent.
tool_take :: proc(s:^Session,name:string) {
    if tool_on(s,name) && s.viewport.plugin_aside {tools_release(s);s.viewport.plugin_aside=false}
}

// True while a plugin tool takes left presses on the scene from the gizmo and the selection.
@(private)
tool_holding :: proc "contextless" (v:^Viewport) -> bool {return v.plugin_tool!=0 && !v.plugin_aside}
@(private)
lender_holding :: proc "contextless" (v:^Viewport) -> bool {return v.plugin_lends && tool_holding(v)}

// W, E or R: the mode of the gizmo, which takes the scene a plugin tool lends.
@(private)
gizmo_mode :: proc(s:^Session,tool:Tool) {
    v:=s.viewport
    v.tool=tool
    s.gui.placement={}
    if lender_holding(v) {tools_release(s);v.plugin_aside=true}
}

// The keys a plugin tool that is on takes from the shortcuts of the editor
// from the next frame on (Delete for what the tool selected), until it
// turns off or takes others.
tool_keys :: proc(s:^Session,name:string,keys:core.Keys) {
    if tool_on(s,name) {s.viewport.plugin_keys=keys}
}

tool_on :: proc(s:^Session,name:string) -> bool {
    return s.viewport.plugin_tool==hash.fnv64a(transmute([]u8)name) && !scene_covered(s)
}

tool_preview_begin :: proc(s:^Session,name,label:string) -> bool {
    if s.mode!=.Edit || !tool_on(s,name) || s.edits.preview {return false}
    tools_release(s)
    if !history.edits_commit(s.edits,edited_world(s),s.selection) && s.edits.error!=.No_Change {return false}
    _,edit_ready:=edit_open(s,label)
    if !edit_ready {return false}
    s.edits.preview=true
    return true
}

tool_preview_active :: proc(s:^Session,name:string) -> bool {
    return s.mode==.Edit && s.edits.preview && s.edits.world==s.edit_world && tool_on(s,name)
}

tool_preview_end :: proc(s:^Session,name:string,apply:bool) -> bool {
    if !tool_preview_active(s,name) {return false}
    if !apply {tool_preview_cancel(s);return true}
    s.edits.preview=false
    history.edits_end(s.edits)
    if !history.edits_commit(s.edits,edited_world(s),s.selection) && s.edits.error!=.No_Change {s.edits.preview=true;return false}
    return true
}

@(private)
tool_preview_cancel :: proc(s:^Session) {
    if s.edits==nil || !s.edits.preview {return}
    w:=edited_world(s)
    history.edits_cancel(s.edits,w)
    history.selection_restore(s.selection,w,s.edits.selection[:])
}

// The tool that holds the pointer goes on or lets go; with none, a press on
// the scene goes to the camera (right and middle buttons), the gizmo and
// then the selection.
@(private)
tools_update :: proc(s:^Session,w:core.World_Ref) {
    v:=s.viewport
    g:=s.gui
    ctx:=g.ctx
    input:=&ctx.input
    frame:=platform.input_frame(s.app.platform)
    if g.placement.active && .Right in frame.mouse_pressed {g.placement={};return}
    escape:=v.capture!=.None && ui.escape(ctx)
    if frame.wheel.y!=0 && !escape {
        flying:=v.capture==.Look && .Right in frame.mouse_down || v.capture==.None && v.hovered && .Right in frame.mouse_pressed
        if flying {
            v.moved=true
            v.fly_speed=clamp(v.fly_speed*math.pow(VIEW_FLY_STEP,frame.wheel.y),VIEW_FLY_SPEED*0.2,VIEW_FLY_SPEED*2.5)
        } else if v.capture==.None && v.hovered {
            orbit_zoom(&v.orbit,frame.wheel.y)
        }
    }
    switch v.capture {
    case .None:
        if !v.hovered {
            v.gizmo.hot=.None
            return
        }
        // A press on the scene takes the keys from the field that had them: moving types nothing there.
        if frame.mouse_pressed!={} && s.gui.ctx!=nil {s.gui.ctx.edit={}}
        switch {
        case .Right in frame.mouse_pressed:
            v.capture,v.press,v.moved=.Look,v.pointer,false
        case .Middle in frame.mouse_pressed:
            v.capture,v.press,v.moved=.Pan,v.pointer,false
        case g.placement.active && !v.pick.active:
            v.gizmo.hot=.None
            if .Left in frame.mouse_pressed {placement_commit(s,w,g.placement.subject,pick_point(s,w,v.pointer),true)}
        case tool_holding(v) && !v.pick.active:
            v.gizmo.hot=.None
        case:
            if .Left in frame.mouse_pressed && presence_hit(s,w) {return}
            double:=.Left in frame.mouse_pressed && frame.mouse_clicks[.Left]>=2
            if !v.pick.active && !double && !watching(s) && gizmo_update(s,w) {return}
            if .Left in frame.mouse_pressed {
                v.capture,v.press,v.moved=.Select,v.pointer,false
                v.add,v.toggle=.Shift in input.modifiers,.Primary in input.modifiers
                v.individual=frame.mouse_clicks[.Left]>=2
            }
        }
    case .Look:
        if escape || .Right not_in frame.mouse_down {
            v.capture=.None
            // A click that did not turn the camera opens the menu of what is under it.
            if !escape && !v.moved {viewport_menu_open(s,w,v.press)}
            return
        }
        if !v.moved && linalg.distance(v.pointer,v.press)>DRAG_THRESHOLD {v.moved=true}
        if v.moved {orbit_look(&v.orbit,v.pointer_delta)}
        if .Primary not_in input.modifiers {
            direction:[3]f32
            if .W in v.keys {direction.z+=1}
            if .S in v.keys {direction.z-=1}
            if .D in v.keys {direction.x+=1}
            if .A in v.keys {direction.x-=1}
            if .E in v.keys {direction.y+=1}
            if .Q in v.keys {direction.y-=1}
            if direction!={} {
                v.moved=true
                orbit_fly(&v.orbit,direction,v.dt,v.fly_speed,.Shift in input.modifiers)
            }
        }
    case .Pan:
        if !v.moved && linalg.distance(v.pointer,v.press)>DRAG_THRESHOLD {v.moved=true}
        if escape || .Middle not_in frame.mouse_down {
            // A click that did not pan pings.
            if !escape && !v.moved && s.mode==.Edit {ping(s,w,v.press)}
            v.capture=.None
            return
        }
        orbit_pan(&v.orbit,v.pointer_delta)
    case .Gizmo:
        if escape {
            gizmo_cancel(s,w)
            v.capture=.None
            return
        }
        gizmo_drag(s,w)
        if .Left not_in frame.mouse_down {
            gizmo_end(s)
            v.capture=.None
        }
    case .Select:
        if escape {v.capture=.None;return}
        if !v.moved && linalg.distance(v.pointer,v.press)>DRAG_THRESHOLD {v.moved=true}
        if .Left in frame.mouse_down {return}
        v.capture=.None
        if v.moved {
            marquee_select(s,w,rect_from_points(v.press,v.pointer),v.add || v.toggle)
            return
        }
        hit:=pick_point(s,w,v.press,ghosts_shown(s))
        if v.pick.active {
            if hit.entity!=core.NONE {inspector_pick_finish(s,w,hit.entity)}
            return
        }
        entity:=selection_click_target(s,w,hit.entity,v.individual)
        switch {
        case v.toggle:          if entity!=core.NONE {history.selection_toggle(s.selection,entity)}
        case v.add:             if entity!=core.NONE {history.selection_add(s.selection,entity)}
        case entity!=core.NONE: history.selection_set(s.selection,{entity})
        case:                   history.selection_clear(s.selection)
        }
        if entity!=core.NONE {outliner_reveal(s.outliner,w,entity)}
    }
}

// Lets go of what holds the pointer, undoing a drag: before a World is replaced.
tools_release :: proc(s:^Session) {
    tool_preview_cancel(s)
    v:=s.viewport
    if v.capture==.Gizmo {gizmo_cancel(s,shown_world(s))}
    v.capture=.None
    v.gizmo.drag={}
    v.pick={}
    s.gui.placement={}
}

@(private)
rect_from_points :: proc "contextless" (a,b:[2]f32) -> ui.Rect {
    return {min(a.x,b.x),min(a.y,b.y),abs(a.x-b.x),abs(a.y-b.y)}
}

// Selects what has its origin, or its whole box on the screen, inside a rectangle.
marquee_select :: proc(s:^Session,w:core.World_Ref,rect:ui.Rect,add:bool) {
    if !add {history.selection_clear(s.selection)}
    items:=scene_items(s,w,ghosts_shown(s))
    for item in scene_item_next(&items) {
        if e:=marquee_entity(s,w,item,rect);e!=core.NONE {history.selection_add(s.selection,e)}
    }
}

@(private)
marquee_entity :: proc(s:^Session,w:core.World_Ref,item:Scene_Item,rect:ui.Rect) -> core.Entity {
    if inside,ok:=item_in_rect(s,w,item,rect);ok && inside {return entity_author(w,item.entity)}
    return core.NONE
}

// What the scene takes of a drag that started in a panel: a preset or a
// mesh or a prefab is placed where the pointer points, and a material goes
// to the mesh under it.
@(private)
viewport_drop :: proc(s:^Session,w:core.World_Ref) {
    g:=s.gui
    d:=&g.drag
    ctx:=g.ctx
    if d.kind==.None || !d.released || play_viewed(s) || watching(s) || scene_covered(s) {return}
    tool_preview_cancel(s)
    if !d.moved {
        if placement_subject(d^) {
            tool_leave(s)
            active:=!(g.placement.active && placement_same(g.placement.subject,d^))
            g.placement={active=active,subject=d^}
        }
        return
    }
    if ctx.over || !ui.rect_contains(viewport_rect(s.viewport),s.viewport.pointer) {return}
    v:=s.viewport
    hit:=pick_point(s,w,v.pointer)
    if placement_subject(d^) {
        tools_release(s)
        g.placement={}
        placement_commit(s,w,d^,hit,true)
        return
    }
    #partial switch d.kind {
    case .Asset:
        content_used(s,d.asset_id)
        switch d.asset_kind {
        case asset.KIND_MATERIAL:
            if hit.entity!=core.NONE && !hit.indicator {material_assign(s,w,{hit.entity},d.asset_id)}
        case:
            if hit.entity!=core.NONE && !hit.indicator {s.dropped={id=d.asset_id,kind=d.asset_kind,part=d.part,entity=hit.entity,frame=s.frame}}
        }
    }
}

@(private)
placement_commit :: proc(s:^Session,w:core.World_Ref,d:Drag,hit:Pick,select:bool) {
    d:=d
    // What was placed is what the keys act on next, not the card it came from.
    if c:=s.content;c!=nil && c.card_focus!=0 {
        if s.gui.ctx.focus==c.card_focus {s.gui.ctx.focus=0}
        c.card_focus=0
    }
    point:=placement_point(s,d,hit)
    if d.kind==.Asset {content_used(s,d.asset_id)}
    if d.kind==.Asset && d.asset_kind==asset.KIND_PREFAB {
        root:=prefab_place_linked(s,d.asset_id,point)
        if select && root!=core.NONE {history.selection_set(s.selection,{root})}
        return
    }
    if d.kind==.Asset && d.asset_kind==asset.KIND_SCENE {
        root:=section_place(s,d.asset_id,point,asset_label(&d))
        if select && root!=core.NONE {history.selection_set(s.selection,{root})}
        return
    }
    card:=d.kind==.Preset?d.card:int(Preset.Empty)
    opened,edit_ready:=edit_open(s,d.kind==.Preset?fmt.tprintf("Add %s",cards(s)[card].label):fmt.tprintf("Add %s",asset_label(&d)))
    if !edit_ready {return}
    defer edit_close(s,opened)
    e:=entity_create(s,{card=card,name=d.kind==.Asset?asset_label(&d):"",transform={position=point,rotation=1,scale={1,1,1}}})
    if placement_sound(d) {
        sound_components(w,e,d.asset_id)
    } else if d.kind==.Asset {
        if t:=core.world_table_of(w,erender.Mesh_Renderer);t!=nil {core.add(t,e,erender.Mesh_Renderer{mesh=d.asset_id})}
    }
    if select {history.selection_set(s.selection,{e})}
}

// Where something dropped on the scene goes: on the surface under the
// pointer, on the ground, or ahead of the camera.
@(private)
place_point :: proc(v:^Viewport,hit:Pick) -> [3]f32 {
    if hit.entity!=core.NONE && !hit.indicator {return hit.position}
    ray:=v.ray
    if point,ok:=ground_point(ray);ok {
        if snapping(v,.Move) {point=mm.snap(point,v.grid>0?v.grid:0.5)}
        return point
    }
    return ray.origin+ray.direction*10
}

// Where a ray meets the ground, when it does nearby.
ground_point :: proc(ray:mm.Ray) -> (point:[3]f32,ok:bool) {
    t,hit:=mm.ray_plane(ray,{{0,1,0},0})
    if !hit || t>200 {return}
    return mm.ray_at(ray,t),true
}

// A prefab of the assets placed in the scene as an instance linked to it, as one step.
prefab_place :: proc(s:^Session,w:core.World_Ref,prefab:base.Asset_Id,point:[3]f32) -> core.Entity {
    root:=prefab_place_linked(s,prefab,point)
    if root!=core.NONE {history.selection_set(s.selection,{root})}
    return root
}

// Gives a material to the first slot of the meshes of some entities, as one step.
material_assign :: proc(s:^Session,w:core.World_Ref,entities:[]core.Entity,material:base.Asset_Id) {
    if watching(s) || section_refused(s,..entities) {return}
    t:=core.world_table_of(w,erender.Mesh_Renderer)
    if t==nil {return}
    opened,edit_ready:=edit_open(s,"Material")
    if !edit_ready {return}
    defer edit_close(s,opened)
    for e in entities {
        if mesh:=core.edit(t,e);mesh!=nil {mesh.materials[0]=material}
    }
}

// ---------------------------------------------------------------- overlays

// Discs, the gizmo, the box being dragged: drawn before the panels, which cover them.
@(private)
overlays_draw :: proc(s:^Session,w:core.World_Ref) {
    if play_viewed(s) || camera_previewing(s) {return}
    v:=s.viewport
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    if v.show_indicators {
        reach_draw(s,w)
        indicators_draw(s,w)
    }
    if !tool_holding(v) {gizmo_draw(s,w)}
    if v.capture==.Select && v.moved {
        rect:=rect_from_points(v.press,v.pointer)
        ui.draw_rect_lines(ctx,rect,1,ui.color_alpha(th.accent,220))
    }
}

level_color :: proc "contextless" (level:u8) -> ui.Color {
    style:=gpu.DEFAULT_HIGHLIGHT_STYLE
    if level>=AGENT_LEVEL && level<AI_CONTEXT_LEVEL {return agent_color(int(level-AGENT_LEVEL))}
    c:=style.colors[clamp(int(level),1,15)-1]
    return {u8(clamp(c.x,0,1)*255),u8(clamp(c.y,0,1)*255),u8(clamp(c.z,0,1)*255),255}
}

@(private)
indicators_draw :: proc(s:^Session,w:core.World_Ref) {
    v:=s.viewport
    ctx:=s.gui.ctx
    th:=&ctx.theme
    indicators_sync(s,w,ghosts_shown(s))
    margin:=INDICATOR_RADIUS+8
    spots:=core.world_table_of(w,erender.Spot_Light)
    es:=core.world_entities(w)
    for e in v.indicators {
        world:=entity_world(w,e)
        p,front:=viewport_screen(v,world.position)
        if !front || p.x<v.origin.x-margin || p.y<v.origin.y-margin || p.x>v.origin.x+v.size.x+margin || p.y>v.origin.y+v.size.y+margin {continue}
        icon,base_color:=entity_icon(s,w,e)
        hidden:=entity_hidden(w,e) || core.entity_off(es,e)
        radius:=INDICATOR_RADIUS
        if spots!=nil && core.has(spots,e) {
            tip,tip_front:=viewport_screen(v,world.position+mm.quat_forward(world.rotation))
            if length:=linalg.distance(tip,p);tip_front && length>radius {
                direction:=(tip-p)/length
                ui.draw_line(ctx,p+direction*radius,p+direction*min(length,radius+48),1.6,ui.color_alpha(base_color,hidden?110:200))
            }
        }
        glyph:=ui.color_alpha(base_color,hidden?130:255)
        level:=entity_level(v,e)
        if level!=0 {
            color:=level_color(level)
            ui.draw_circle(ctx,p,radius+6,ui.color_alpha(color,45))
            ui.draw_circle(ctx,p,radius,ui.color_alpha(th.panel,200))
            ui.draw_ring(ctx,p,radius,2.2,color)
        } else {
            ui.draw_circle(ctx,p,radius,ui.color_alpha(th.panel,hidden?110:165))
            ui.draw_ring(ctx,p,radius,1.4,ui.color_alpha(base_color,hidden?110:210))
        }
        ui.draw_icon(ctx,icon,{p.x-7,p.y-7,14,14},glyph)
    }
}

// Finds the entities without a body again only when what decides it changed.
@(private)
indicators_sync :: proc(s:^Session,w:core.World_Ref,ghosts:bool) {
    v:=s.viewport
    transforms:=core.world_table_of(w,core.Transform)
    meshes:=core.world_table_of(w,erender.Mesh_Renderer)
    hidden:=core.world_table_of(w,erender.Hidden)
    parents:=core.world_table_of(w,core.Parent)
    ids:=core.world_table_of(w,core.Id)
    if transforms==nil {
        clear(&v.indicators)
        return
    }
    key:=[6]u64{u64(uintptr(w.data)),transforms.layout,meshes!=nil?meshes.layout+meshes.version:0,(hidden!=nil?hidden.layout:0)+(parents!=nil?parents.layout+parents.version:0),ids!=nil?ids.layout:0,(core.world_entities(w).activity.version+core.world_entities(w).activity_tree)<<1|u64(ghosts)}
    if key==v.indicators_key {return}
    v.indicators_key=key
    clear(&v.indicators)
    items:=scene_items(s,w,ghosts)
    for item in scene_item_next(&items) {
        if item.indicator {append(&v.indicators,item.entity)}
    }
}

@(private)
entity_level :: proc(v:^Viewport,e:core.Entity) -> u8 {
    i:=core.entity_index(e)
    return i<len(v.levels)?v.levels[i]:0
}

// Highlight rows remain on meshes and return to 0 when no longer selected.
// The game is drawn without them: its world is a copy that has the selection.
@(private)
highlight_sync :: proc(s:^Session,w:core.World_Ref) {
    v:=s.viewport
    table:=core.world_table_of(w,erender.Highlight)
    parents:=core.world_table_of(w,core.Parent)
    meshes:=core.world_table_of(w,erender.Mesh_Renderer)
    es:=core.world_entities(w)
    play:=play_viewed(s) || camera_previewing(s)
    marquee:=v.capture==.Select && v.moved && !play
    ids:=core.world_table_of(w,core.Id)
    key:=Highlight_Key{sources={s.selection.serial,u64(uintptr(w.data)),parents!=nil?parents.layout+parents.version:0,meshes!=nil?meshes.layout:0,u64(len(es.generation)),0,0,0,0,0,0,ai_scene_serial(s.ai),ids!=nil?ids.layout+ids.version:0,collab_highlights_key(s)},marquee=marquee,play=play,isolated=play_shown(s)}
    if marquee {
        transforms:=core.world_table_of(w,core.Transform)
        worlds:=core.world_table_of(w,core.World_Transform)
        hidden:=core.world_table_of(w,erender.Hidden)
        key.sources[5]=transforms!=nil?transforms.layout+transforms.version:0
        key.sources[6]=worlds!=nil?worlds.layout+worlds.version:0
        key.sources[7]=ids!=nil?ids.layout:0
        key.sources[8]=hidden!=nil?hidden.layout+hidden.version:0
        key.sources[9]=meshes!=nil?meshes.version:0
        key.sources[10]=s.app.assets!=nil?s.app.assets.revision+s.app.assets.structure:0
        key.add=v.add || v.toggle
        key.indicators=v.show_indicators
        key.rect=rect_from_points(v.press,v.pointer)
        key.view_projection=v.view_projection
        key.size=v.size
    }
    if key==v.levels_key {return}
    v.levels_key=key
    v.levels_serial+=1
    resize(&v.levels,len(es.generation))
    for &level in v.levels {level=0}
    if !play && (!marquee || key.add) {
        for e in s.selection.entities {
            if core.alive(es,e) {v.levels[core.entity_index(e)]=HIGHLIGHT_SELECTED}
        }
    }
    if marquee {
        items:=scene_items(s,w,ghosts_shown(s))
        for item in scene_item_next(&items) {
            if e:=marquee_entity(s,w,item,key.rect);e!=core.NONE {v.levels[core.entity_index(e)]=HIGHLIGHT_SELECTED}
        }
    }
    // What hangs from a selected entity; the walk leaves out what another one marks.
    h:=entity_hierarchy(w)
    for level,i in v.levels {
        if level!=HIGHLIGHT_SELECTED {continue}
        root:=core.entity_make(i,es.generation[i])
        for at:=core.subtree_next(h,root,root);at!=core.NONE; {
            if v.levels[core.entity_index(at)]!=0 {
                at=core.subtree_next(h,root,at,false)
                continue
            }
            v.levels[core.entity_index(at)]=HIGHLIGHT_DESCENDANT
            at=core.subtree_next(h,root,at)
        }
    }
    // The game shown is the user's alone: what others and agents work on is not outlined.
    if !key.isolated {
        collab_highlights(s,w,v.levels[:])
        ai_scene_highlights(s,w,v.levels[:])
        git_highlights(s,w,v.levels[:])
    }
    if table==nil {return}
    for e,row in table.entities[:core.count(table)] {
        level:=entity_level(v,e)
        if table.values[row].level!=level {core.edit_at(table,row).level=level}
    }
    if meshes==nil {return}
    for e in meshes.entities[:core.count(meshes)] {
        if entity_level(v,e)!=0 && !core.has(table,e) {core.add(table,e,erender.Highlight{entity_level(v,e)})}
    }
}

REACH_LIGHT :: ui.Color{255,205,90,255}
REACH_SOUND :: ui.Color{176,160,255,255}
REACH_VOLUME :: ui.Color{120,220,200,255}
REACH_FAINT :: u8(150)  // alpha of the outer shape of a reach
REACH_WIDTH :: f32(2)   // points
REACH_SEGMENTS :: 64    // of a circle

// The lines of the grid on the ground, around where the camera looks.
@(private)
grid_lines :: proc(s:^Session) {
    v:=s.viewport
    lines:=&v.lines
    gpu.debug_lines_clear(lines)
    if play_viewed(s) || camera_previewing(s) {return}
    w:=shown_world(s)
    if v.show_grid {
        center:=[2]f32{math.round(v.orbit.target.x),math.round(v.orbit.target.z)}
        minor:=[4]f32{0.55,0.6,0.7,0.16}
        major:=[4]f32{0.6,0.65,0.75,0.32}
        extent:=f32(GRID_EXTENT)
        for i in -GRID_EXTENT..=GRID_EXTENT {
            x:=center.x+f32(i)
            z:=center.y+f32(i)
            color_x:=int(x)%GRID_MAJOR==0?major:minor
            color_z:=int(z)%GRID_MAJOR==0?major:minor
            if x==0 {color_x={0.31,0.55,0.96,0.7}}
            if z==0 {color_z={0.94,0.32,0.37,0.7}}
            gpu.debug_line(lines,{x,0,center.y-extent},{x,0,center.y+extent},color_x)
            gpu.debug_line(lines,{center.x-extent,0,z},{center.x+extent,0,z},color_z)
        }
    }
    // Where each sun shines to: a sheaf of short arrows from its place.
    if suns:=core.world_table_of(w,erender.Sun);suns!=nil && v.show_indicators {
        for e in suns.entities[:core.count(suns)] {
            if entity_hidden(w,e) {continue}
            world:=entity_world(w,e)
            to:=mm.quat_forward(world.rotation)
            side:=linalg.normalize(linalg.cross(to,abs(to.y)<0.9?[3]f32{0,1,0}:[3]f32{1,0,0}))
            up:=linalg.cross(side,to)
            color:=[4]f32{1,0.84,0.47,0.9}
            gpu.debug_arrow(lines,world.position+to*SUN_ARROW_START,world.position+to*(SUN_ARROW_START+SUN_ARROW_LENGTH),color,SUN_ARROW_HEAD)
            for i in 0..<SUN_ARROWS {
                angle:=f32(i)/SUN_ARROWS*2*math.PI
                from:=world.position+(side*math.cos(angle)+up*math.sin(angle))*SUN_ARROW_RING+to*SUN_ARROW_START
                gpu.debug_arrow(lines,from,from+to*SUN_ARROW_LENGTH,color,SUN_ARROW_HEAD)
            }
        }
    }
}

// The twelve edges of a box of extents at pose, its extents times the scale of the pose.
@(private)
stroke_box :: proc(ctx:^ui.Context,v:^Viewport,pose:mm.Transform,extents:[3]f32,color:ui.Color) {
    axes:=section_axes(pose,extents)
    for corner in 0..<8 {
        from:=pose.position
        for axis in 0..<3 {from+=axes[axis]*(corner&(1<<uint(axis))!=0?1:-1)}
        for axis in 0..<3 {
            if corner&(1<<uint(axis))!=0 {continue}
            stroke_line(ctx,v,from,from+axes[axis]*2,color)
        }
    }
}

// How far what is selected reaches, as strokes over the scene, as wide as
// the discs draw theirs: the range of a light, its cone or its square, the
// distances of a sound, the box or the sphere of a volume.
@(private)
reach_draw :: proc(s:^Session,w:core.World_Ref) {
    v:=s.viewport
    ctx:=s.gui.ctx
    for e in s.selection.entities {
        if !entity_alive(w,e) || entity_hidden(w,e) {continue}
        world:=entity_world(w,e)
        if source,ok:=entity_get(w,e,eaudio.Audio_Source);ok && source.spatial {
            // Where it starts to fall, and fainter, where it stops falling.
            near,far:=source.min_distance>0?source.min_distance:1,source.max_distance>0?source.max_distance:100
            stroke_sphere(ctx,v,world.position,near,REACH_SOUND)
            stroke_sphere(ctx,v,world.position,max(far,near),ui.color_alpha(REACH_SOUND,REACH_FAINT))
        }
        // The box of a section: where its unbounded volumes rule and where it streams.
        if reference,ok:=entity_get(w,e,scene.Scene_Reference);ok && reference.extents!={} {stroke_box(ctx,v,world,reference.extents,SECTION_COLOR)}
        if zone,ok:=entity_get(w,e,evolume.Volume);ok && zone.shape==.Sphere {
            scale:=linalg.abs(world.scale)
            stroke_sphere(ctx,v,world.position,zone.extents.x*max(scale.x,scale.y,scale.z),REACH_VOLUME)
        } else if ok && zone.shape==.Box {
            stroke_box(ctx,v,world,zone.extents,REACH_VOLUME)
        }
        if entity_has(w,e,erender.Mesh_Renderer) {continue}
        if point,ok:=entity_get(w,e,erender.Point_Light);ok && point.range>0 {stroke_sphere(ctx,v,world.position,point.range,REACH_LIGHT)}
        if spot,ok:=entity_get(w,e,erender.Spot_Light);ok && spot.range>0 {
            // Its cone out to its range: the circle of its edge, lines from its
            // place to that circle, and fainter, the circle where it starts to fade.
            axis:=mm.quat_forward(world.rotation)
            side:=linalg.normalize(linalg.cross(axis,abs(axis.y)<0.9?[3]f32{0,1,0}:[3]f32{1,0,0}))
            up:=linalg.cross(side,axis)
            edge:=world.position+axis*(spot.range*math.cos(spot.angle))
            radius:=spot.range*math.sin(spot.angle)
            stroke_circle(ctx,v,edge,axis,radius,REACH_LIGHT)
            for i in 0..<SPOT_CONE_LINES {
                angle:=f32(i)/SPOT_CONE_LINES*2*math.PI
                stroke_line(ctx,v,world.position,edge+(side*math.cos(angle)+up*math.sin(angle))*radius,REACH_LIGHT)
            }
            fade:=0.8*spot.angle
            stroke_circle(ctx,v,world.position+axis*(spot.range*math.cos(fade)),axis,spot.range*math.sin(fade),ui.color_alpha(REACH_LIGHT,REACH_FAINT))
        }
        if rect,ok:=entity_get(w,e,erender.Rect_Light);ok {
            // The square it glows from and the side it lights.
            x:=mm.quat_rotate(world.rotation,[3]f32{0.5*abs(world.scale.x),0,0})
            y:=mm.quat_rotate(world.rotation,[3]f32{0,0.5*abs(world.scale.y),0})
            corners:=[4][3]f32{world.position-x-y,world.position+x-y,world.position+x+y,world.position-x+y}
            for corner,i in corners {stroke_line(ctx,v,corner,corners[(i+1)%4],REACH_LIGHT)}
            stroke_line(ctx,v,world.position,world.position+mm.quat_rotate(world.rotation,[3]f32{0,0,-0.5}),REACH_LIGHT)
            if rect.range>0 {stroke_sphere(ctx,v,world.position,rect.range,REACH_LIGHT)}
        }
    }
}

// A line of the world drawn over the scene; what is behind the camera is left out.
@(private)
stroke_line :: proc(ctx:^ui.Context,v:^Viewport,a,b:[3]f32,color:ui.Color) {
    pa,front_a:=viewport_screen(v,a)
    pb,front_b:=viewport_screen(v,b)
    if front_a && front_b {ui.draw_line(ctx,pa,pb,REACH_WIDTH,color)}
}

// A circle of the world drawn over the scene, in runs of what is in front of the camera.
@(private)
stroke_circle :: proc(ctx:^ui.Context,v:^Viewport,center,normal:[3]f32,radius:f32,color:ui.Color) {
    if radius<=0 {return}
    axis:=linalg.normalize(normal) if linalg.length(normal)>1e-6 else [3]f32{0,1,0}
    u:=linalg.normalize(linalg.cross(axis,[3]f32{1,0,0} if abs(axis.x)<0.9 else [3]f32{0,1,0}))
    w:=linalg.cross(axis,u)
    run:[REACH_SEGMENTS+1][2]f32
    count:=0
    for i in 0..=REACH_SEGMENTS {
        angle:=f32(i)/REACH_SEGMENTS*2*math.PI
        p,front:=viewport_screen(v,center+(u*math.cos(angle)+w*math.sin(angle))*radius)
        if front {
            run[count]=p
            count+=1
            if i<REACH_SEGMENTS {continue}
        }
        if count>=2 {ui.draw_polyline(ctx,run[:count],REACH_WIDTH,color)}
        count=0
    }
}

// Three circles, one around each axis.
@(private)
stroke_sphere :: proc(ctx:^ui.Context,v:^Viewport,center:[3]f32,radius:f32,color:ui.Color) {
    for axis in ([3][3]f32{{1,0,0},{0,1,0},{0,0,1}}) {stroke_circle(ctx,v,center,axis,radius,color)}
}

// ---------------------------------------------------------------- inside

@(private)
asset_label :: proc(d:^Drag) -> string {return string(d.label[:d.label_length])}

// The path of an asset in the registry; empty when it has none.
asset_path :: proc(s:^Session,id:base.Asset_Id) -> string {
    if s.app.assets==nil {return ""}
    if file,found:=asset.registry_find(&s.app.assets.registry,id);found {return file.path}
    return ""
}

// The name of an asset as people read it: its file without folder nor extension.
asset_name :: proc(path:string) -> string {
    name:=path
    if slash:=strings.last_index_byte(name,'/');slash>=0 {name=name[slash+1:]}
    if dot:=strings.last_index_byte(name,'.');dot>0 {name=name[:dot]}
    return name
}
