package gui

import "core:math"
import "core:math/linalg"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:platform"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// The World_Widgets as each local player sees them. Each context places its
// world panels for the camera of its player, turned and sized for it, and
// aims at them with the ray of its player; the renderer draws the panels of a
// player in its view alone. The ray does not reach what the scene hides: the
// depth the renderer read back around its pixel a frame or two before, where
// the point it meets falls in the camera of that frame (render.Depth_Probe),
// and while it falls out of what was read, nothing it may hide. A widget on a
// mesh is built once, in the window's context, and its panel is drawn into a
// texture that the material slot of the mesh shows; the ray reaches it where
// it meets the triangles of the mesh, at their first texture coordinates.

MESH_PIXELS :: 4096 // the widest the texture of a widget on a mesh is
MESH_TEXELS :: f32(2) // texels per layout unit of a widget on a mesh that names none

// The camera a context places its world panels for, and the part of the
// window it is drawn in.
Player_View :: struct {
    camera:gpu.Camera,
    rect:[4]f32, // window points; zero: all of the window
    index:int,   // of the views of the window the renderer draws it in
    panels:u8,   // gpu.World_Panel.view of its panels: 0, every view
    known:bool,  // the camera of a local player of a split screen
    depth:^gpu.Depth_Probe_Result, // what the renderer read of its view around the ray a frame or two before; nil: nothing yet
}

// The views of the contexts this frame: with one player, the camera of the
// frame in the part of the window it draws in for every context; with
// several, that of each local player in its part, and that of the player
// with the keyboard for the window's.
@(private)
views_update :: proc(gui:^Gui,app:^host.App,players,focus:int) {
    split:=players>1 && app.local_camera_count>=players
    scene:=host.app_scene_points(app)
    for &view,p in gui.views {
        view={camera=app.camera,rect=scene}
        slot:=p-1
        if p==0 {slot=clamp(focus,0,players-1)}
        if !split || slot>=players {continue}
        r:=host.app_player_rect(app,slot,players)
        view.camera,view.index,view.known=app.local_cameras[slot],slot,p>0
        view.rect=[4]f32{f32(r.x),f32(r.y),f32(r.z),f32(r.w)}/max(app.density,0.01)
        if p>0 {view.panels=u8(p)}
    }
}

// Whether the camera of a view sees a widget at position, and how far it is.
// Its panel is taken as a sphere around position as wide as the panel,
// which grows with the distance for a Screen one. One on a mesh is seen with
// its mesh (mesh_seen).
@(private)
widget_seen :: proc(view:^Player_View,widget:World_Widget,position:[3]f32,settings:UI_Settings,scale:f32) -> (distance:f32,seen:bool) {
    extent:=linalg.length(widget.size)
    return sphere_seen(view,position,extent*widget_unit(view,widget,settings,scale),widget.sizing==.Screen)
}

// What a layout unit of a widget is: meters, or window points for a Screen one, which scales with
// the screens of its player (UI_Settings.reference fitted to the part of the view, times the
// player's scale) so it keeps their size.
@(private)
widget_unit :: proc "contextless" (view:^Player_View,widget:World_Widget,settings:UI_Settings,scale:f32) -> f32 {
    switch widget.sizing {
    case .Meters: return widget.scale>0?widget.scale:0.01
    case .Screen: return (widget.scale>0?widget.scale:1)*surface_scale(view.rect.zw,settings,scale)
    }
    return 1
}

// Whether the camera of a view sees a sphere, and how far its center is. A
// radius on the screen is in window points at a metre along the view.
@(private)
sphere_seen :: proc(view:^Player_View,position:[3]f32,radius:f32,screen:bool) -> (distance:f32,seen:bool) {
    camera:=view.camera
    offset:=position-camera.position
    distance=linalg.length(offset)
    forward:=camera.forward
    if linalg.length(forward)<1e-6 {return distance,true}
    forward=linalg.normalize(forward)
    right:=linalg.cross(forward,camera.up)
    if linalg.length(right)<1e-6 {return distance,true}
    right=linalg.normalize(right)
    up:=linalg.cross(right,forward)
    depth,x,y:=linalg.dot(offset,forward),linalg.dot(offset,right),linalg.dot(offset,up)
    size:=view.rect.zw
    if size.x<=0 || size.y<=0 {size={1,1}}
    tangent:=math.tan(camera.fov_y*math.RAD_PER_DEG*0.5)
    tangent_x:=tangent*size.x/size.y
    radius:=radius*2*max(depth,0)*tangent/size.y if screen else radius
    if depth<-radius || camera.far>0 && depth-radius>camera.far {return distance,false}
    seen=abs(x)-depth*tangent_x<=radius*math.sqrt(1+tangent_x*tangent_x) && abs(y)-depth*tangent<=radius*math.sqrt(1+tangent*tangent)
    return
}

// The ray a context aims at its world panels with: through the pointer while
// the pointer shows over the part of its player, through the center of its
// view while the mouse is captured, the player has no keyboard or plays with
// a gamepad; what the scene hides of it; and the pixel the renderer reads the
// depth around for a later frame.
@(private)
surface_aim :: proc(gui:^Gui,app:^host.App,s:^Surface,p:int,input:^ui.Input,keyboard:bool) {
    view:=&gui.views[p]
    captured:=app.platform!=nil && platform.window_relative_mouse(app.platform)
    aim:=captured || !keyboard || s.family!=.Keyboard
    host.ui_input_camera(input,view.camera,view.rect,aim)
    if !input.ray.valid {return}
    size:=view.rect.zw if view.rect.z>0 && view.rect.w>0 else input.size
    point:=size*0.5 if aim else input.pointer-view.rect.xy
    pixel:=point*max(app.density,0.01)
    host.extras_depth_probe_add(&app.extras,{pixel=pixel,view=view.index,camera=view.camera,size=size*max(app.density,0.01)})
    view.depth=probe_nearest(render.depth_probes(app.renderer),view.index,pixel)
    input.ray.scene={scene_hides,view}
}

// Of the probes the renderer read, the one of a view nearest pixel; nil
// without one.
probe_nearest :: proc(probes:[]gpu.Depth_Probe_Result,view:int,pixel:[2]f32) -> (nearest:^gpu.Depth_Probe_Result) {
    best:=max(f32)
    for &result in probes {
        if result.probe.view!=view {continue}
        if d:=linalg.length2(result.probe.pixel-pixel);d<best {nearest,best=&result,d}
    }
    return
}

// Whether the scene the probe of a view read hides point (ui.Ray_Scene):
// also where it cannot say, so that a ray that moved past what was read
// reaches nothing behind a wall until a probe reads where it is.
scene_hides :: proc(user:rawptr,point:[3]f32,share,metres:f32) -> bool {
    view:=cast(^Player_View)user
    if view.depth==nil {return false}
    hidden,known:=gpu.depth_probe_hides(view.depth,point,share,metres)
    return hidden || !known
}

// Whether a view sees the mesh of a widget on it, as it was drawn in the last
// frame (host.extras_slot_shown), and how far it is; one not drawn yet is seen.
@(private)
mesh_seen :: proc(renderer:^render.Renderer,extras:^host.Frame_Extras,view:^Player_View,e:core.Entity,position:[3]f32) -> (distance:f32,seen:bool) {
    shown,drawn:=host.extras_slot_shown(extras,u64(e))
    low,high,known:=render.mesh_bounds(renderer,shown.mesh)
    if !drawn || !known {return linalg.length(position-view.camera.position),true}
    m:=shown.transform
    center:=(m*[4]f32{(low.x+high.x)*0.5,(low.y+high.y)*0.5,(low.z+high.z)*0.5,1}).xyz+shown.anchor
    scale:=max(linalg.length(m[0].xyz),linalg.length(m[1].xyz),linalg.length(m[2].xyz))
    return sphere_seen(view,center,linalg.length(high-low)*0.5*scale,false)
}

// A World_Widget on a mesh: the texture its panel is drawn into, and where
// the mesh shows it.
Mesh_Surface :: struct {
    entity:core.Entity,
    texture:render.Texture_Handle,
    size:[2]u32,     // of the texture
    slot:u32,
    emission:f32,
    planned:u64,     // the frame it was last planned in; one not planned in a frame goes
    drawn:bool,      // the texture holds a frame of its panel
    ray:u32,         // 1 + the mesh of the world the renderer made a tree of for the ray (render.mesh_ray_prepare); 0: none
}

// The surface of a widget on a mesh, with a texture of its size; -1 when no
// texture is left or the renderer does not make one.
@(private)
mesh_surface_get :: proc(gui:^Gui,renderer:^render.Renderer,e:core.Entity,widget:World_Widget,mesh_handle:render.Mesh_Handle,problems:^core.Problems) -> int {
    texels:=widget.pixels>0?widget.pixels:MESH_TEXELS
    size:=[2]u32{u32(clamp(math.ceil(widget.size.x*texels),1,MESH_PIXELS)),u32(clamp(math.ceil(widget.size.y*texels),1,MESH_PIXELS))}
    at,free:=-1,-1
    for &mesh,i in gui.meshes {
        if mesh.entity==e && mesh.texture!=0 {at=i;break}
        if mesh.texture==0 && free<0 {free=i}
    }
    if at>=0 && gui.meshes[at].size!=size {
        render.ui_texture_remove(renderer,gui.meshes[at].texture)
        gui.meshes[at]={}
        free,at=at,-1
    }
    if at<0 {
        if free<0 || renderer==nil {return -1}
        texture,made:=render.ui_texture_add(renderer,size.x,size.y,"ui on mesh")
        if !made {
            core.report(problems,e,"gui.mesh","its World_Widget is not drawn on its mesh: the renderer took no texture of %dx%d; give it a smaller size or pixels, or fewer widgets on meshes",size.x,size.y)
            return -1
        }
        gui.meshes[free]={entity=e,texture=texture,size=size}
        at=free
    }
    mesh:=&gui.meshes[at]
    mesh.slot,mesh.emission,mesh.planned=widget.slot,widget.emission,gui.frame
    if mesh_handle!=host.ASSETS_MESH_NONE && mesh.ray!=u32(mesh_handle)+1 && render.mesh_ray_prepare(renderer,mesh_handle) {
        ray_release(gui,renderer,at)
        mesh.ray=u32(mesh_handle)+1
    }
    return at
}

// Where the ray of the window meets each widget on a mesh, in the layout
// units of its panel, for the routing of the next frame: the first texture
// coordinates of the mesh there, as the last frame drew it, posed, offset or
// carried (host.extras_slot_shown). A mesh the renderer cannot meet leaves the
// plane of the panel to the ray.
@(private)
meshes_aim :: proc(gui:^Gui,assets:^host.Assets,renderer:^render.Renderer,extras:^host.Frame_Extras,s:^Surface,p:int,ray:ui.World_Ray,meshes:core.Read(render.Mesh_Renderer),worlds:core.Read(core.World_Transform)) {
    if p!=0 || !ray.valid || assets==nil {return}
    for &entry in gui.plan {
        if entry.player!=p || entry.mesh<0 {continue}
        shown,drawn:=host.extras_slot_shown(extras,u64(entry.entity))
        if !drawn {
            static,has:=core.get(meshes,entry.entity)
            world,placed:=core.get(worlds,entry.entity)
            if !has || !placed {continue}
            mesh:=static.mesh!={}?host.assets_mesh(assets,static.mesh):host.assets_shape(assets,static.shape)
            if mesh==nil || mesh.handle==host.ASSETS_MESH_NONE {continue}
            shown={mesh=mesh.handle,transform=mm.transform_matrix(world.transform)}
        }
        distance,uv,_,hit:=render.mesh_ray(renderer,shown.mesh,shown.transform,ray.origin-shown.anchor,ray.direction)
        id:=ui.id(s.ctx,"world",core.entity_index(entry.entity))
        ui.world_panel_aim(s.ctx,id,uv*entry.panel.size,distance,hit)
    }
}

// The runs of the widgets on meshes of the window's frame, into their textures.
@(private)
meshes_draw :: proc(gui:^Gui,extras:^host.Frame_Extras,runs:[]host.Ui_Offscreen) {
    for run in runs {
        for &mesh in gui.meshes {
            if mesh.texture==0 || mesh.planned!=gui.frame || ui.id(gui.surfaces[0].ctx,"world",core.entity_index(mesh.entity))!=run.id {continue}
            host.extras_ui_texture_draw(extras,{texture=mesh.texture,layer=run.layer,size=run.size,clear={0,0,0,1}})
            mesh.drawn=true
            break
        }
    }
}

// The widgets on meshes not planned this frame let go of their textures,
// and of the trees of their meshes no other one meets.
@(private)
meshes_sweep :: proc(gui:^Gui,renderer:^render.Renderer) {
    for &mesh,at in gui.meshes {
        if mesh.texture==0 || mesh.planned==gui.frame {continue}
        render.ui_texture_remove(renderer,mesh.texture)
        ray_release(gui,renderer,at)
        mesh={}
    }
}

// The tree the surface at made for the ray, when no other surface meets its mesh.
@(private)
ray_release :: proc(gui:^Gui,renderer:^render.Renderer,at:int) {
    ray:=gui.meshes[at].ray
    if ray==0 {return}
    gui.meshes[at].ray=0
    for other in gui.meshes {if other.ray==ray {return}}
    render.mesh_ray_release(renderer,render.Mesh_Handle(ray-1))
}

// The textures of the World_Widgets drawn on meshes, in the material slots
// they name: as the base color, lit, or as light. Whatever draws the mesh
// shows them (host.Slot_Texture).
@(step="render",before="render_sync")
gui_meshes_render :: proc(gui:^Gui,renderer:^render.Renderer,extras:^host.Frame_Extras) {
    if gui==nil || renderer==nil {return}
    for &mesh in gui.meshes {
        if mesh.texture==0 || !mesh.drawn {continue}
        host.extras_slot_texture_add(extras,{object=u64(mesh.entity),slot=mesh.slot,texture=mesh.texture,emission=mesh.emission})
    }
}
