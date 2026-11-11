package editor

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor/history"
import "mirai:platform"
import mm "mirai:std/math"
import "mirai:ui"

// The gizmo of the selection, of a constant size on the screen.
//   Move:   three arrows, three squares that move in the plane they span,
//           and the center, which moves in the plane of the view.
//   Rotate: a ring per axis; dragging along it turns around the axis.
//   Scale:  a handle per axis of the active entity and the center, uniform.
// Move and rotate follow the axes of the world or those of the active
// entity (Viewport.space). A drag is one step: every frame computes the
// values from those it began with, the release ends the step and Escape
// puts everything back.

Handle :: enum u8 {None,X,Y,Z,YZ,XZ,XY,Center}

Gizmo :: struct {
    visible:bool,
    origin:[3]f32,
    axes:[3][3]f32, // unit world directions of the handles
    size:f32,       // world length of an axis
    screen:[2]f32,
    ends:[3][2]f32,
    usable:[3]bool, // long enough on the screen to grab
    view:[3]f32,    // camera forward
}

Gizmo_Item :: struct {
    entity:core.Entity,
    local,world:mm.Transform,
    parent:mm.Transform, // world transform of its parent
    flat:bool,           // the parent has no size on an axis: nothing under it can be placed
    physical:bool,
}

Gizmo_Drag :: struct {
    active:bool,
    handle:Handle,
    tool:Tool,
    group:bool,          // several entities: they turn and scale around the pivot
    origin:[3]f32,
    axes:[3][3]f32,
    basis_inverse:matrix[3,3]f32,
    size:f32,
    start_pointer:[2]f32,
    start_param:f32,     // axis move: the closest parameter along the axis
    start_hit:[3]f32,    // plane move: the first intersection
    normal:[3]f32,
    screen_dir:[2]f32,   // axis move fallback, the tangent of a ring, a scale direction
    pixels:f32,          // points per unit of drag
    screen_mode:bool,    // the axis pointed at the camera when the drag began
}

Gizmo_State :: struct {
    hot:Handle,
    drag:Gizmo_Drag,
    items:[dynamic]Gizmo_Item,
}

GIZMO_PIXELS :: f32(96)
GIZMO_GRAB :: f32(9)
PLANE_NEAR :: f32(0.2)
PLANE_FAR :: f32(0.42)
PLANE_AREA :: f32(24)
ROTATE_SNAP :: f32(15) // degrees
SCALE_SNAP :: f32(0.1)
SCALE_MIN :: f32(0.001)
SCALE_MAX :: f32(1e5)
RING_SEGMENTS :: 48
AXES :: [3][3]f32{{1,0,0},{0,1,0},{0,0,1}}

@(private)
handle_axis :: proc "contextless" (h:Handle) -> int {
    #partial switch h {
    case .X,.YZ: return 0
    case .Y,.XZ: return 1
    case .Z,.XY: return 2
    }
    return -1
}

// A scale the gizmo may store: never zero, so another scale can undo it.
scale_limit :: proc "contextless" (value:f32) -> f32 {
    v:=clamp(value,-SCALE_MAX,SCALE_MAX)
    if abs(v)<SCALE_MIN {return v<0?-SCALE_MIN:SCALE_MIN}
    return v
}

// Where the gizmo stands: the active entity, or the mean of the origins of several.
selection_pivot :: proc(s:^Session,w:core.World_Ref) -> (pivot:[3]f32,found:bool) {
    active:=history.selection_active(s.selection)
    if active==core.NONE || !entity_alive(w,active) {return}
    pivot=entity_world(w,active).position
    if len(s.selection.entities)>1 {
        sum:[3]f32
        count:=0
        for e in s.selection.entities {
            if !entity_alive(w,e) {continue}
            sum+=entity_world(w,e).position
            count+=1
        }
        if count>0 {pivot=sum/f32(count)}
    }
    return pivot,true
}

gizmo_frame :: proc(s:^Session,w:core.World_Ref,tool:Tool) -> (g:Gizmo) {
    v:=s.viewport
    if v.pick.active || selection_section_locked(s,w) {return}
    active:=history.selection_active(s.selection)
    origin,found:=selection_pivot(s,w)
    if !found || !finite3(origin) {return}
    return gizmo_at(s,w,origin,active,tool)
}

@(private)
gizmo_at :: proc(s:^Session,w:core.World_Ref,origin:[3]f32,active:core.Entity,tool:Tool) -> (g:Gizmo) {
    v:=s.viewport
    rotation:=mm.Quat(1)
    local:=(tool==.Scale || v.space==.Local) && entity_alive(w,active)
    if local {rotation=entity_world(w,active).rotation}
    return gizmo_place(v,origin,rotation,local,&v.gizmo.drag)
}

// The gizmo at a point, along the axes of a rotation when local, else those
// of the world; while drag is active, along the axes it began with.
@(private)
gizmo_place :: proc(v:^Viewport,origin:[3]f32,rotation:mm.Quat,local:bool,drag:^Gizmo_Drag) -> (g:Gizmo) {
    g.origin=origin
    screen,front:=viewport_screen(v,origin)
    if !front {return}
    g.visible,g.screen=true,screen
    g.view=linalg.normalize0(v.camera.forward)
    depth:=max(linalg.dot(origin-v.camera.position,g.view),0.05)
    g.size=mm.perspective_world_per_pixel(depth,v.camera.fov_y*mm.RAD_PER_DEG,max(v.size.y,1))*GIZMO_PIXELS
    switch {
    case drag!=nil && drag.active:
        g.axes=drag.axes
    case local:
        for axis,i in AXES {g.axes[i]=mm.quat_rotate(rotation,axis)}
    case:
        g.axes=AXES
    }
    for i in 0..<3 {
        end,ok:=viewport_screen(v,origin+g.axes[i]*g.size)
        g.ends[i]=end
        g.usable[i]=ok && linalg.distance(end,screen)>=12
    }
    return
}

@(private)
gizmo_plane :: proc(g:Gizmo,k:int,v:^Viewport) -> (quad:[4][2]f32,ok:bool) {
    a,b:=(k+1)%3,(k+2)%3
    da,db:=g.axes[a]*g.size,g.axes[b]*g.size
    corners:=[4][3]f32{
        g.origin+da*PLANE_NEAR+db*PLANE_NEAR,g.origin+da*PLANE_FAR+db*PLANE_NEAR,
        g.origin+da*PLANE_FAR+db*PLANE_FAR,g.origin+da*PLANE_NEAR+db*PLANE_FAR,
    }
    for corner,i in corners {
        point,front:=viewport_screen(v,corner)
        if !front {return}
        quad[i]=point
    }
    return quad,true
}

@(private)
gizmo_ring :: proc(g:Gizmo,k:int,v:^Viewport) -> (points:[RING_SEGMENTS+1][2]f32,world:[RING_SEGMENTS+1][3]f32,ok:bool) {
    n,next:=g.axes[k],g.axes[(k+1)%3]
    u:=linalg.normalize0(next-n*linalg.dot(next,n))
    r:=linalg.cross(n,u)
    for i in 0..=RING_SEGMENTS {
        angle:=f32(i)/RING_SEGMENTS*math.TAU
        world[i]=g.origin+(u*math.cos(angle)+r*math.sin(angle))*g.size
        point,front:=viewport_screen(v,world[i])
        if !front {return}
        points[i]=point
    }
    return points,world,true
}

@(private)
distance_segment :: proc "contextless" (p,a,b:[2]f32) -> f32 {
    ab:=b-a
    length:=linalg.dot(ab,ab)
    if length<1e-12 {return linalg.distance(p,a)}
    t:=clamp(linalg.dot(p-a,ab)/length,0,1)
    return linalg.distance(p,a+ab*t)
}

@(private)
quad_area :: proc "contextless" (q:[4][2]f32) -> f32 {
    sum:f32
    for i in 0..<4 {
        a,b:=q[i],q[(i+1)%4]
        sum+=a.x*b.y-b.x*a.y
    }
    return abs(sum)*0.5
}

@(private)
point_in_quad :: proc "contextless" (p:[2]f32,q:[4][2]f32) -> bool {
    positive,negative:=false,false
    for i in 0..<4 {
        a,b:=q[i],q[(i+1)%4]
        cross:=(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
        if cross>0 {positive=true}
        if cross<0 {negative=true}
    }
    return !(positive && negative)
}

gizmo_hit :: proc(g:Gizmo,tool:Tool,v:^Viewport,pointer:[2]f32) -> Handle {
    if !g.visible {return .None}
    axis_handles:=[3]Handle{.X,.Y,.Z}
    switch tool {
    case .Move,.Scale:
        if linalg.distance(pointer,g.screen)<=GIZMO_GRAB {return .Center}
        best,best_distance:=Handle.None,GIZMO_GRAB
        for i in 0..<3 {
            if !g.usable[i] {continue}
            if distance:=distance_segment(pointer,g.screen,g.ends[i]);distance<best_distance {best,best_distance=axis_handles[i],distance}
        }
        if best!=.None || tool==.Scale {return best}
        plane_handles:=[3]Handle{.YZ,.XZ,.XY}
        for k in 0..<3 {
            quad,ok:=gizmo_plane(g,k,v)
            if ok && quad_area(quad)>=PLANE_AREA && point_in_quad(pointer,quad) {return plane_handles[k]}
        }
    case .Rotate:
        best,best_distance:=Handle.None,GIZMO_GRAB
        for k in 0..<3 {
            points,_,ok:=gizmo_ring(g,k,v)
            if !ok {continue}
            for i in 0..<RING_SEGMENTS {
                if distance:=distance_segment(pointer,points[i],points[i+1]);distance<best_distance {best,best_distance=axis_handles[k],distance}
            }
        }
        return best
    }
    return .None
}

@(private)
ray_plane_point :: proc "contextless" (ray:mm.Ray,origin,normal:[3]f32) -> (point:[3]f32,ok:bool) {
    t:=mm.ray_plane(ray,{normal,-linalg.dot(normal,origin)}) or_return
    return mm.ray_at(ray,t),true
}

// The drag a press on a handle of a gizmo begins, with a tool.
@(private)
gizmo_drag_start :: proc(v:^Viewport,g:Gizmo,handle:Handle,tool:Tool) -> (drag:Gizmo_Drag,ok:bool) {
    if handle==.None || !g.visible {return}
    pointer:=v.pointer
    drag=Gizmo_Drag{active=true,handle=handle,tool=tool,origin=g.origin,axes=g.axes,size=g.size,start_pointer=pointer}
    basis:matrix[3,3]f32
    for column in 0..<3 {
        for row in 0..<3 {basis[row,column]=g.axes[column][row]}
    }
    drag.basis_inverse=linalg.inverse(basis)
    ray:=viewport_ray(v,pointer)
    k:=handle_axis(handle)
    switch tool {
    case .Move:
        #partial switch handle {
        case .X,.Y,.Z:
            drag.screen_dir=linalg.normalize0(g.ends[k]-g.screen)
            drag.pixels=max(linalg.distance(g.ends[k],g.screen),1)
            t,_,closest:=mm.line_line_closest(g.origin,g.axes[k],ray.origin,ray.direction)
            drag.start_param=t
            drag.screen_mode=!closest || abs(t)>g.size*50
        case:
            drag.normal=handle==.Center?g.view:linalg.normalize0(linalg.cross(g.axes[(k+1)%3],g.axes[(k+2)%3]))
            drag.start_hit=ray_plane_point(ray,g.origin,drag.normal) or_return
        }
    case .Rotate:
        // The grab point is the sample of the ring nearest the pointer; the
        // drag follows its tangent on the screen, a radius of travel a radian.
        points,world:=gizmo_ring(g,k,v) or_return
        nearest,nearest_distance:=0,max(f32)
        for point,i in points[:RING_SEGMENTS] {
            if distance:=linalg.distance(point,pointer);distance<nearest_distance {nearest,nearest_distance=i,distance}
        }
        tangent:=linalg.normalize0(linalg.cross(g.axes[k],world[nearest]-g.origin))
        ahead,front:=viewport_screen(v,world[nearest]+tangent*g.size*0.1)
        drag.screen_dir=linalg.normalize0(ahead-points[nearest])
        if !front || drag.screen_dir=={} {
            radial:=linalg.normalize0(points[nearest]-g.screen)
            drag.screen_dir={-radial.y,radial.x}
        }
        drag.pixels=GIZMO_PIXELS
    case .Scale:
        if handle==.Center {
            drag.pixels=100
        } else {
            drag.screen_dir=linalg.normalize0(g.ends[k]-g.screen)
            drag.pixels=max(linalg.distance(g.ends[k],g.screen),1)
        }
    }
    return drag,true
}

// The press of the frame on a handle of the gizmo begins a drag. True when it took the press.
@(private)
gizmo_update :: proc(s:^Session,w:core.World_Ref) -> bool {
    v:=s.viewport
    gz:=&v.gizmo
    if len(s.selection.entities)==0 {gz.hot=.None;return false}
    g:=gizmo_frame(s,w,v.tool)
    gz.hot=gizmo_hit(g,v.tool,v,v.pointer)
    if gz.hot==.None || .Left not_in platform.input_frame(s.app.platform).mouse_pressed {return false}
    if !gizmo_begin(s,w,g,gz.hot) {return false}
    v.capture=.Gizmo
    return true
}

@(private)
gizmo_begin :: proc(s:^Session,w:core.World_Ref,g:Gizmo,handle:Handle) -> bool {
    v:=s.viewport
    drag:=gizmo_drag_start(v,g,handle,v.tool) or_return
    drag.group=len(s.selection.entities)>1
    gz:=&v.gizmo
    clear(&gz.items)
    for e in history.selection_roots(s.selection,w) {
        item:=Gizmo_Item{entity=e,local=entity_local(w,e),world=entity_world(w,e),parent=entity_parent_world(w,e)}
        if simulating(s) && providers(s).simulates {
            owner:=simulation_owner(s,w,e)
            if owner!=core.NONE && owner!=e {notify(s,"Select the owning body to move this collider");return false}
            item.physical=owner==e
            if item.physical && v.tool==.Scale {notify(s,"Stop simulation to resize a body");return false}
            transforms:=core.world_table_of(w,core.Transform)
            if !item.physical && core.owner(transforms,e)!=0 {notify(s,"This transform is controlled by its component");return false}
            for child in transforms.entities {
                if child==e || !entity_under(w,child,e) {continue}
                body:=simulation_owner(s,w,child)
                if body==child || core.owner(transforms,child)!=0 && body==core.NONE {
                    notify(s,"Select individual bodies to move this group during simulation")
                    return false
                }
            }
        }
        for scale in item.parent.scale {
            if abs(scale)<1e-8 {item.flat=true}
        }
        append(&gz.items,item)
    }
    if len(gz.items)==0 {return false}
    labels:=[Tool]string{.Move="Move",.Rotate="Rotate",.Scale="Scale"}
    _,edit_ready:=edit_open(s,labels[v.tool])
    if !edit_ready {return false}
    gz.drag=drag
    return true
}

// Applies the drag for where the pointer is. An edit some entity cannot
// follow leaves what the frame before applied.
@(private)
gizmo_drag :: proc(s:^Session,w:core.World_Ref) {
    v:=s.viewport
    gz:=&v.gizmo
    drag:=&gz.drag
    if !drag.active {return}
    move,radians,factor,snap,ok:=gizmo_delta(v,drag)
    if !ok {return}
    k:=handle_axis(drag.handle)
    pending:=make([]mm.Transform,len(gz.items),context.temp_allocator)
    // Every value is found before the first write: an entity that cannot follow refuses the edit.
    for item,i in gz.items {
        p:=item.local
        switch drag.tool {
        case .Move:
            if item.flat {return}
            p.position=mm.transform_inverse_point(item.parent,item.world.position+move)
        case .Rotate:
            if item.flat {return}
            local_axis:=mm.quat_rotate(conj(item.parent.rotation),drag.axes[k])
            p.rotation=linalg.normalize(mm.quat_axis_angle(local_axis,radians)*item.local.rotation)
            if drag.group {
                turned:=drag.origin+mm.quat_rotate(mm.quat_axis_angle(drag.axes[k],radians),item.world.position-drag.origin)
                p.position=mm.transform_inverse_point(item.parent,turned)
            }
        case .Scale:
            for axis in 0..<3 {
                value:=item.local.scale[axis]*factor[axis]
                if snap && factor[axis]!=1 {value=mm.snap(value,v.scale_increment>0?v.scale_increment:SCALE_SNAP)}
                p.scale[axis]=scale_limit(value)
            }
            if drag.group {
                if item.flat {return}
                offset:=item.world.position-drag.origin
                scaled:[3]f32
                for axis in 0..<3 {scaled+=drag.axes[axis]*(linalg.dot(offset,drag.axes[axis])*factor[axis])}
                p.position=mm.transform_inverse_point(item.parent,drag.origin+scaled)
            }
        }
        if !finite3(p.position) || !finite3(p.scale) || p.rotation.w-p.rotation.w!=0 {return}
        pending[i]=p
    }
    for item,i in gz.items {
        if item.physical {
            pose:=mm.transform_compose(item.parent,pending[i])
            simulation_body_target(s,item.entity,pose.position,pose.rotation)
        } else {transform_set(s,item.entity,pending[i])}
    }
    if play_paused(s) && simulating(s) {simulation_settle(s,w)}
}

// What a drag does for where the pointer is: the move in the world, the
// turn around the axis of its handle, the factors of the scale along its
// axes, and whether it snaps.
@(private)
gizmo_delta :: proc(v:^Viewport,drag:^Gizmo_Drag) -> (move:[3]f32,radians:f32,factor:[3]f32,snap,ok:bool) {
    pointer:=v.pointer
    snap=snapping(v,drag.tool) || .Primary in v.modifiers
    k:=handle_axis(drag.handle)
    travel:=linalg.dot(pointer-drag.start_pointer,drag.screen_dir)
    steps:[3]f32
    factor={1,1,1}
    switch drag.tool {
    case .Move:
        ray:=viewport_ray(v,pointer)
        #partial switch drag.handle {
        case .X,.Y,.Z:
            amount:=travel*drag.size/drag.pixels
            if !drag.screen_mode {
                t,_,closest:=mm.line_line_closest(drag.origin,drag.axes[k],ray.origin,ray.direction)
                if !closest || abs(t-drag.start_param)>drag.size*1000 {return}
                amount=t-drag.start_param
            }
            steps[k]=amount
        case:
            hit,crossed:=ray_plane_point(ray,drag.origin,drag.normal)
            if !crossed {return}
            offset:=hit-drag.start_hit
            if linalg.length(offset)>drag.size*1000 {return}
            steps=drag.basis_inverse*offset
            if drag.handle!=.Center {steps[k]=0}
        }
        if snap {steps=mm.snap(steps,v.grid>0?v.grid:0.5)}
        for i in 0..<3 {move+=drag.axes[i]*steps[i]}
    case .Rotate:
        degrees:=travel/drag.pixels*mm.DEG_PER_RAD
        if snap {degrees=mm.snap(degrees,v.rotate_increment>0?v.rotate_increment:ROTATE_SNAP)}
        radians=degrees*mm.RAD_PER_DEG
    case .Scale:
        if drag.handle==.Center {
            delta:=pointer-drag.start_pointer
            uniform:=max(1+(delta.x-delta.y)/drag.pixels,0.01)
            factor={uniform,uniform,uniform}
        } else {
            factor[k]=max(1+travel/drag.pixels,0.01)
        }
    }
    if !finite3(steps) || !finite3(move) || radians-radians!=0 {return}
    return move,radians,factor,snap,true
}

// Puts every entity back and closes the drag without a step.
@(private)
gizmo_cancel :: proc(s:^Session,w:core.World_Ref) {
    gz:=&s.viewport.gizmo
    if !gz.drag.active {return}
    for item in gz.items {
        if !entity_alive(w,item.entity) {continue}
        if item.physical {
            simulation_body_target(s,item.entity,item.world.position,item.world.rotation)
            simulation_body_release(s,item.entity)
        } else {transform_set(s,item.entity,item.local)}
    }
    if play_paused(s) && simulating(s) {simulation_settle(s,w)}
    gz.drag={}
    history.edits_end(s.edits)
}

// The release: one step, or none when nothing moved.
@(private)
gizmo_end :: proc(s:^Session) {
    gz:=&s.viewport.gizmo
    if !gz.drag.active {return}
    for item in gz.items {if item.physical {simulation_body_release(s,item.entity)}}
    if play_paused(s) && simulating(s) {simulation_settle(s,shown_world(s))}
    gz.drag={}
    history.edits_end(s.edits)
}

@(private)
handle_color :: proc "contextless" (color:ui.Color,hot:bool) -> ui.Color {
    if !hot {return color}
    return {u8(min(int(color[0])+70,255)),u8(min(int(color[1])+70,255)),u8(min(int(color[2])+70,255)),255}
}

@(private)
gizmo_draw :: proc(s:^Session,w:core.World_Ref) {
    v:=s.viewport
    if len(s.selection.entities)==0 || v.capture==.Look || v.capture==.Pan {return}
    drag:=&v.gizmo.drag
    tool:=drag.active?drag.tool:v.tool
    hot:=drag.active?drag.handle:v.gizmo.hot
    gizmo_paint(s,gizmo_frame(s,w,tool),tool,hot)
}

// Draws a gizmo of a tool with the handle under the pointer lit.
@(private)
gizmo_paint :: proc(s:^Session,g:Gizmo,tool:Tool,hot:Handle) {
    if !g.visible {return}
    v:=s.viewport
    ctx:=s.gui.ctx
    th:=&ctx.theme
    axis_handles:=[3]Handle{.X,.Y,.Z}
    names:=ui.AXIS_NAMES
    dark:=ui.Color{0,0,0,120}
    switch tool {
    case .Move:
        plane_handles:=[3]Handle{.YZ,.XZ,.XY}
        for k in 0..<3 {
            quad,ok:=gizmo_plane(g,k,v)
            if !ok {continue}
            is_hot:=hot==plane_handles[k]
            color:=handle_color(th.axis[k],is_hot)
            fill:=ui.color_alpha(color,is_hot?150:70)
            ui.draw_quad_colors(ctx,quad,{fill,fill,fill,fill})
            ui.draw_polyline(ctx,quad[:],1.5,ui.color_alpha(color,230),true)
        }
        for i in 0..<3 {
            if !g.usable[i] {continue}
            is_hot:=hot==axis_handles[i]
            color:=handle_color(th.axis[i],is_hot)
            direction:=linalg.normalize0(g.ends[i]-g.screen)
            side:=[2]f32{-direction.y,direction.x}
            head,half:=f32(15),f32(6)
            ui.draw_line(ctx,g.screen+direction*7,g.ends[i]-direction*(head-2),is_hot?3.5:2.5,color)
            ui.draw_triangle(ctx,g.ends[i],g.ends[i]-direction*head+side*half,g.ends[i]-direction*head-side*half,color)
            ui.draw_text(ctx,names[i],g.ends[i].x+direction.x*10-4,g.ends[i].y+direction.y*10-7,th.font_label,color)
        }
        ui.draw_rect(ctx,{g.screen.x-5,g.screen.y-5,10,10},ui.color_alpha(th.text,hot==.Center?255:200))
        ui.draw_rect_lines(ctx,{g.screen.x-6,g.screen.y-6,12,12},1,dark)
    case .Rotate:
        for k in 0..<3 {
            points,world,ok:=gizmo_ring(g,k,v)
            if !ok {continue}
            is_hot:=hot==axis_handles[k]
            color:=handle_color(th.axis[k],is_hot)
            for i in 0..<RING_SEGMENTS {
                // The half of the ring behind the pivot is dimmed.
                middle:=(world[i]+world[i+1])*0.5
                behind:=linalg.dot(middle-g.origin,g.view)>0
                ui.draw_line(ctx,points[i],points[i+1],is_hot?3.5:2.5,ui.color_alpha(color,behind && !is_hot?110:255))
            }
        }
        ui.draw_circle(ctx,g.screen,3,ui.color_alpha(th.text,220))
    case .Scale:
        for i in 0..<3 {
            if !g.usable[i] {continue}
            is_hot:=hot==axis_handles[i]
            color:=handle_color(th.axis[i],is_hot)
            direction:=linalg.normalize0(g.ends[i]-g.screen)
            ui.draw_line(ctx,g.screen+direction*7,g.ends[i],is_hot?3.5:2.5,color)
            ui.draw_rect(ctx,{g.ends[i].x-5,g.ends[i].y-5,10,10},color)
            ui.draw_text(ctx,names[i],g.ends[i].x+direction.x*12-4,g.ends[i].y+direction.y*12-7,th.font_label,color)
        }
        ui.draw_rect(ctx,{g.screen.x-6,g.screen.y-6,12,12},ui.color_alpha(th.text,hot==.Center?255:200))
        ui.draw_rect_lines(ctx,{g.screen.x-7,g.screen.y-7,14,14},1,dark)
    }
}

// ---------------------------------------------------------------- a gizmo of a plugin tool

// The gizmo of a plugin tool on a transform of the world it holds, not on
// an entity (an instance of foliage): the handles, drags and snaps of the
// gizmo of the selection, with a tool of the viewport.
Tool_Gizmo :: struct {
    drag:Gizmo_Drag,
    hot:Handle,
    start:mm.Transform, // what the drag began from
}
Tool_Gizmo_Event :: enum u8 {None,Began,Moved,Ended,Cancelled}

// A press of the frame on a handle begins a drag (Began), which changes
// transform as the pointer moves (Moved) until the release (Ended); Escape
// puts transform back (Cancelled). Scale and Local follow its axes.
tool_gizmo :: proc(s:^Session,gizmo:^Tool_Gizmo,transform:^mm.Transform,tool:Tool) -> Tool_Gizmo_Event {
    v:=s.viewport
    frame:=platform.input_frame(s.app.platform)
    if gizmo.drag.active {
        if ui.escape(s.gui.ctx) {transform^=gizmo.start;gizmo.drag={};return .Cancelled}
        if .Left not_in frame.mouse_down {gizmo.drag={};return .Ended}
        move,radians,factor,snap,ok:=gizmo_delta(v,&gizmo.drag)
        if !ok {return .None}
        transform^=tool_gizmo_apply(v,&gizmo.drag,gizmo.start,move,radians,factor,snap)
        return .Moved
    }
    g:=gizmo_place(v,transform.position,transform.rotation,tool==.Scale || v.space==.Local,nil)
    gizmo.hot=gizmo_hit(g,tool,v,v.pointer)
    if gizmo.hot==.None || !v.hovered || .Left not_in frame.mouse_pressed {return .None}
    drag,ok:=gizmo_drag_start(v,g,gizmo.hot,tool)
    if !ok {return .None}
    gizmo.drag=drag
    gizmo.start=transform^
    return .Began
}

// A transform of the world after a drag of a tool gizmo, from the one it began with.
tool_gizmo_apply :: proc(v:^Viewport,drag:^Gizmo_Drag,start:mm.Transform,move:[3]f32,radians:f32,factor:[3]f32,snap:bool) -> (p:mm.Transform) {
    p=start
    switch drag.tool {
    case .Move:   p.position=start.position+move
    case .Rotate: p.rotation=linalg.normalize(mm.quat_axis_angle(drag.axes[max(handle_axis(drag.handle),0)],radians)*start.rotation)
    case .Scale:
        for axis in 0..<3 {
            value:=start.scale[axis]*factor[axis]
            if snap && factor[axis]!=1 {value=mm.snap(value,v.scale_increment>0?v.scale_increment:SCALE_SNAP)}
            p.scale[axis]=scale_limit(value)
        }
    }
    return
}

tool_gizmo_draw :: proc(s:^Session,gizmo:^Tool_Gizmo,transform:mm.Transform,tool:Tool) {
    v:=s.viewport
    if v.capture==.Look || v.capture==.Pan {return}
    g:=gizmo_place(v,transform.position,transform.rotation,tool==.Scale || v.space==.Local,&gizmo.drag)
    gizmo_paint(s,g,gizmo.drag.active?gizmo.drag.tool:tool,gizmo.drag.active?gizmo.drag.handle:gizmo.hot)
}
