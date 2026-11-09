package ui

import "core:math"
import "core:math/linalg"

// Widgets in the 3D world. A world panel is laid out in a virtual surface of
// its own, in layout units with the origin at its top-left corner, and placed
// in the world by a transform. Its geometry leaves in commands of its own
// surface, with a placement the renderer draws them through. The pointer
// reaches it as a ray.

World_Facing :: enum u8 {
    Fixed,             // rotation orients it: +X right, +Y up, its face toward +Z, so a camera with no rotation sees it head on
    Billboard,         // parallel to the screen
    Billboard_Upright, // turns around the world's up axis to face the camera
}
World_Sizing :: enum u8 {
    Meters, // unit: meters per layout unit (0.01 when 0)
    Screen, // unit: window points per layout unit at any distance (1 when 0)
}
World_Panel :: struct {
    position:[3]f32,
    rotation:quaternion128, // of a Fixed panel; the zero value is no rotation
    size:[2]f32,            // the virtual surface, in layout units
    facing:World_Facing,
    sizing:World_Sizing,
    unit:f32,
    pivot:Anchor,           // the point of the panel that sits at position
    density:f32,            // device pixels per layout unit its text is rasterized for; 0: that of the screen
    depth_test:bool,        // the scene in front of it hides it, from the eye and from the ray
    passive:bool,           // the ray goes through
    // Drawn by the host into a texture instead of the scene: its placement is
    // not visible, and the ray reaches it where world_panel_aim says or else
    // through its plane.
    offscreen:bool,
    fill,stroke:Color,      // background of the whole panel
    radius:f32,
    using layout:Layout,    // of its content; width and height are those of size
}
// How the renderer places the commands of one surface.
World_Placement :: struct {
    id:Id,
    transform:matrix[4,4]f32, // layout units of the panel (x right, y down, z out of its face) to world
    size:[2]f32,
    position:[3]f32,          // of the pivot
    pivot:[2]f32,             // the point at position, in layout units
    billboard:bool,           // a Billboard panel: a renderer may turn it to each camera around its pivot
    depth_test:bool,
    visible:bool,             // false behind the camera of a Billboard or Screen panel, and for an offscreen one
    offscreen:bool,
}

@(private)
Panel :: struct {
    id:Id,
    origin,right,up,normal:[3]f32, // world position of its top-left corner and its unit axes
    unit:f32,                      // meters per layout unit
    size:[2]f32,
    density:f32,
    passive,visible,depth_test:bool,
    pointer:[2]f32,                // where the ray crosses its plane, in layout units
    pointed:bool,                  // the ray crosses its front
    reached:bool,                  // the nearest panel the ray reaches
    aim:Panel_Aim,                 // of the host, for the next routing
    bucket,chain:i32,              // lookup by id among the panels of a frame: the first of the bucket of this index, and the next in a bucket
}

@(private)
Panel_Aim :: struct {point:[2]f32,distance:f32,hit,set:bool}

@(private)
POINTER_NOWHERE :: [2]f32{-1e9,-1e9}

// How far behind what the ray meets a panel still takes it: as far behind as
// the renderer still draws it (overlay.slang).
@(private) PANEL_HIDDEN_SHARE :: f32(1.01)
@(private) PANEL_HIDDEN_METERS :: f32(0.02)

@(private)
panel_place :: proc(ctx:^Context,id:Id,p:World_Panel) -> Panel {
    view:=ctx.input.view
    camera:=view.rotation if view.rotation!=0 else quaternion128(1)
    camera_right:=linalg.quaternion_mul_vector3(camera,[3]f32{1,0,0})
    camera_up:=linalg.quaternion_mul_vector3(camera,[3]f32{0,1,0})
    camera_back:=linalg.quaternion_mul_vector3(camera,[3]f32{0,0,1})
    panel:=Panel{id=id,size=p.size,passive=p.passive,visible=true,depth_test=p.depth_test}
    switch p.facing {
    case .Fixed:
        q:=p.rotation if p.rotation!=0 else quaternion128(1)
        panel.right=linalg.quaternion_mul_vector3(q,[3]f32{1,0,0})
        panel.up=linalg.quaternion_mul_vector3(q,[3]f32{0,1,0})
        panel.normal=linalg.quaternion_mul_vector3(q,[3]f32{0,0,1})
    case .Billboard:
        panel.right,panel.up,panel.normal=camera_right,camera_up,camera_back
    case .Billboard_Upright:
        to_camera:=view.position-p.position
        to_camera.y=0
        length:=linalg.length(to_camera)
        panel.normal=to_camera/length if length>1e-6 else [3]f32{0,0,1}
        panel.up={0,1,0}
        panel.right=linalg.cross(panel.up,panel.normal)
    }
    depth:=linalg.dot(p.position-view.position,-camera_back)
    switch p.sizing {
    case .Meters:
        panel.unit=p.unit if p.unit>0 else 0.01
        if p.facing!=.Fixed && depth<=0 {panel.visible=false}
    case .Screen:
        points:=p.unit if p.unit>0 else 1
        if depth<=0 || view.viewport_height<=0 {panel.visible=false;panel.unit=0.001} else {
            panel.unit=points*2*depth*math.tan(view.fov_y*0.5)/view.viewport_height
        }
    }
    column,row:=f32(int(p.pivot)/3)*0.5,f32(int(p.pivot)%3)*0.5
    panel.origin=p.position-panel.right*(column*p.size.x*panel.unit)+panel.up*(row*p.size.y*panel.unit)
    panel.density=p.density if p.density>0 else ctx.scale*ctx.font.density
    panel.pointer=POINTER_NOWHERE
    return panel
}

// Where a ray crosses the plane of a panel, in its layout units. distance:
// along the ray. ok: it reaches the front of the plane.
@(private)
panel_ray :: proc "contextless" (panel:^Panel,ray:World_Ray) -> (point:[2]f32,distance:f32,ok:bool) {
    facing:=linalg.dot(ray.direction,panel.normal)
    if facing>=-1e-6 || panel.unit<=0 {return}
    distance=linalg.dot(panel.origin-ray.origin,panel.normal)/facing
    if distance<=0 {return}
    relative:=ray.origin+ray.direction*distance-panel.origin
    return {linalg.dot(relative,panel.right)/panel.unit,-linalg.dot(relative,panel.up)/panel.unit},distance,true
}

// Before the frame is built: the ray against the panels of the previous
// frame, or the point the host aimed at. A panel the scene hides along the
// ray (World_Ray.scene) keeps its pointer, for a widget that holds it, but
// is not reached. Returns the widget it reaches when the screen left the
// pointer free.
@(private)
panels_route :: proc(ctx:^Context,free:bool) -> ^Widget {
    ray:=ctx.input.ray
    nearest:=-1;nearest_distance:=max(f32)
    for &panel,index in ctx.previous_panels[:ctx.previous_panel_count] {
        aim:=panel.aim
        panel.pointer,panel.pointed,panel.reached,panel.aim=POINTER_NOWHERE,false,false,{}
        if !ray.valid || panel.passive || !panel.visible {continue}
        point,distance,ok:=aim.point,aim.distance,aim.hit
        if !aim.set {point,distance,ok=panel_ray(&panel,ray)}
        if !ok {continue}
        panel.pointer=point;panel.pointed=true
        if panel.depth_test && ray.scene.hides!=nil && ray.scene.hides(ray.scene.user,ray.origin+ray.direction*distance,PANEL_HIDDEN_SHARE,PANEL_HIDDEN_METERS) {continue}
        if rect_contains({0,0,panel.size.x,panel.size.y},point) && distance<nearest_distance {nearest,nearest_distance=index,distance}
    }
    if nearest<0 {return nil}
    ctx.previous_panels[nearest].reached=true
    if !free {return nil}
    return widget_hit(ctx,u16(nearest+1),ctx.previous_panels[nearest].pointer)
}

// The panel of the previous frame with an id; nil without one.
@(private)
previous_panel :: proc "contextless" (ctx:^Context,id:Id) -> ^Panel {
    count:=ctx.previous_panel_count
    if count==0 {return nil}
    panels:=ctx.previous_panels[:count]
    for at:=panels[int(u32(id))%count].bucket;at>=0;at=panels[at].chain {
        if panels[at].id==id {return &panels[at]}
    }
    return nil
}

@(private)
panels_resolve :: proc(ctx:^Context) {
    // The lookup by id of the panels of this frame, which the next one routes and carries.
    count:=ctx.panel_count
    for &panel in ctx.panels[:count] {panel.bucket=-1}
    for &panel,index in ctx.panels[:count] {
        home:=&ctx.panels[int(u32(panel.id))%count]
        panel.chain=home.bucket
        home.bucket=i32(index)
    }
    for &panel,index in ctx.panels[:count] {
        u:=panel.unit
        r,up,n,o:=panel.right*u,panel.up*u,panel.normal*u,panel.origin
        ctx.placements[index].transform={
            r.x,-up.x,n.x,o.x,
            r.y,-up.y,n.y,o.y,
            r.z,-up.z,n.z,o.z,
            0,0,0,1,
        }
    }
}

// Opens a panel of the world; what is built until world_panel_end is laid out
// in its surface. Returns false, building nothing, when no panel is left.
world_panel_begin :: proc(ctx:^Context,id:Id,p:World_Panel) -> bool {
    assert(ctx.surface==0,"World panels do not nest")
    if ctx.panel_count>=len(ctx.panels) || ctx.skipped>0 {ctx.stats.dropped_panels+=1;return false}
    panel:=panel_place(ctx,id,p)
    if previous:=previous_panel(ctx,id);previous!=nil {panel.pointer,panel.pointed=previous.pointer,previous.pointed}
    index:=ctx.panel_count
    ctx.panels[index]=panel
    column,row:=f32(int(p.pivot)/3)*0.5,f32(int(p.pivot)%3)*0.5
    ctx.placements[index]={
        id=id,size=p.size,position=p.position,pivot={column*p.size.x,row*p.size.y},billboard=p.facing==.Billboard,
        depth_test=p.depth_test,visible=panel.visible && !p.offscreen,offscreen=p.offscreen,
    }
    ctx.panel_count+=1
    ctx.surface=u16(index+1)
    ctx.pointer=panel.pointer
    layer_push(ctx,0)
    declaration:=Element{id=id,layout=p.layout}
    declaration.layout.width=fixed(p.size.x)
    declaration.layout.height=fixed(p.size.y)
    declaration.float={to=.Root,layer=i16(-16000+index)}
    if p.fill[3]>0 || p.stroke[3]>0 {
        declaration.custom=paint_add(ctx,{kind=.Panel if p.stroke[3]>0 else .Rect,fill=p.fill,stroke=p.stroke,radius=p.radius})
    }
    widget_add(ctx,id,{.Passive} if p.passive else {.Block})
    element_open(ctx,declaration)
    return true
}
world_panel_end :: proc(ctx:^Context) {
    if ctx.surface==0 {return}
    element_close(ctx)
    layer_pop(ctx)
    ctx.surface=0
    ctx.pointer=ctx.screen_pointer
}
@(deferred_in_out=world_panel_scope_end)
world_panel :: proc(ctx:^Context,id:Id,p:World_Panel) -> bool {return world_panel_begin(ctx,id,p)}
@(private)
world_panel_scope_end :: proc(ctx:^Context,id:Id,p:World_Panel,opened:bool) {
    if opened {world_panel_end(ctx)}
}

// The point of a world panel a ray reaches, in its layout units: what a host
// needs to aim at panels with something other than Input.ray.
world_panel_point :: proc(ctx:^Context,id:Id,ray:World_Ray) -> (point:[2]f32,distance:f32,inside:bool) {
    panel:=previous_panel(ctx,id)
    if panel==nil {return}
    ok:bool
    point,distance,ok=panel_ray(panel,ray)
    return point,distance,ok && rect_contains({0,0,panel.size.x,panel.size.y},point)
}

// Where the ray of the next frame meets a panel, in its layout units and
// along the ray, for a panel the host draws on a surface of its own (an
// offscreen one on a mesh); hit false: the ray misses it. Between frames,
// before frame_begin; the next routing uses it once.
world_panel_aim :: proc(ctx:^Context,id:Id,point:[2]f32,distance:f32,hit:bool) {
    if panel:=previous_panel(ctx,id);panel!=nil {panel.aim={point,distance,hit,true}}
}

// The panel the ray reached when the frame began; 0: none. Inside a frame.
world_panel_reached :: proc(ctx:^Context) -> Id {
    for &panel in ctx.previous_panels[:ctx.previous_panel_count] {
        if panel.reached {return panel.id}
    }
    return 0
}
