package camera

import "core:math"
import "core:math/linalg"
import "mirai:core"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import input "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:host"
import mm "mirai:std/math"

// The view of each local player is drawn from the camera its seat sees
// through. When that changes with a blend (an override that asks for one, or
// a mode its camera takes), the view does not cut: it starts from what it
// drew, which travels with the body of the seat and turns as the new camera
// turns (a player looking around during the blend), and comes into the new
// camera over the blend. Around the pivot of an Orbit it turns at a distance
// between both, so that it does not cross the target; between a perspective
// and an orthographic lens it is a dolly zoom. A blend asked in the middle of
// another starts from what is drawn.

// The narrowest field a dolly zoom reaches before the view turns orthographic.
DOLLY_FOV :: 2.5*mm.RAD_PER_DEG

Camera_View :: struct {
    camera:core.Entity,
    changes:u32,           // the setups of camera it has seen
    through:Camera_Blend,  // of the override it sees camera through: it leaves with it too
    blend:Camera_Blend,
    elapsed:f32,           // s
    anchor:core.Entity,    // the body that what it left travels with
    from:render.View_Pose, // what it left; its position from the anchor when it has one
    turned:mm.Quat,        // the rotation of the camera it blends into when it left: what turns what it left
    pose:render.View_Pose, // what it is drawn from
    blending:bool,
    cut:bool,              // it jumped this frame
    fade:f32,              // how much of the body its camera follows it leaves out, the camera being near it: 1 all of it
}

// What each local slot is drawn from.
@(storage)
Camera_Views :: struct {
    slots:[input.LOCAL_CAPACITY]Camera_View,
}

// The view of every local slot; the focused one's is the view of the game.
@(step="late",stage="end")
camera_blend :: proc(
    views:^Camera_Views,shown:core.Ref(Cameras),seat_state:core.Ref(input.Seats),seats:^core.Table(input.Seat,.Read),
    parents:^core.Table(core.Parent,.Read),hierarchy:core.Ref(core.Hierarchy),cameras:^core.Table(render.Camera,.Read),follows:^core.Table(Camera_Follow,.Read),worlds:^core.Table(core.World_Transform,.Read),chosen:^render.View_Camera,
    bodies:^render.View_Bodies,frame:core.Frame_Time,
) {
    player:=input.focused(seat_state.ptr,seats)
    n:=clamp(seat_state.local_count,1,input.LOCAL_CAPACITY)
    focus_slot:=clamp(seat_state.focus,0,n-1)
    for slot in 0..<input.LOCAL_CAPACITY {
        v:=&views.slots[slot]
        if slot>=n {
            if v.camera!=core.NONE {v^={}}
            if slot<len(bodies.bodies) && bodies.bodies[slot]!=core.NONE {bodies.bodies[slot]=core.NONE}
            continue
        }
        seat:=seat_state.local_count>0?input.local_seat(seats,slot):core.NONE
        camera,through:=camera_selected(shown.ptr,seats,cameras,hierarchy,seat)
        body:=input.body_of(seats,seat)
        view_update(v,camera,through,body,cameras,follows,worlds,frame)
        // The own body of the view is the body of its player, or else the one its
        // camera follows. Nearer to it than twice what it allows, the view fades it out.
        v.fade=0
        if follow,ok:=core.get(follows,v.camera);ok && follow.state.ready {
            target:=follow_target(v.camera,follow.target,parents,seats,player)
            if body==core.NONE {body=target}
            if follow.hide_within>0 && target==body {
                v.fade=clamp(2-linalg.length(v.pose.position-follow.state.pivot.position)/follow.hide_within,0,1)
            }
        }
        if slot<len(bodies.bodies) && bodies.bodies[slot]!=body {bodies.bodies[slot]=body}
    }
    focus:=&views.slots[focus_slot]
    chosen.entity,chosen.posed,chosen.cut=focus.camera,focus.blending,focus.cut
    chosen.own=u8(focus_slot+1)
    chosen.fade,chosen.focus=focus.fade,focus.pose.focus
    if focus.blending {chosen.pose=focus.pose}
}

@(private)
view_update :: proc(
    v:^Camera_View,camera:core.Entity,through:Camera_Blend,body:core.Entity,
    cameras:^core.Table(render.Camera,$A),follows:^core.Table(Camera_Follow,$B),worlds:^core.Table(core.World_Transform,$C),frame:core.Frame_Time,
) {
    c,has_camera:=core.get(cameras,camera)
    world,placed:=core.get(worlds,camera)
    if !has_camera || !placed {
        if v.camera!=core.NONE {v^={}}
        return
    }
    v.cut=false
    live:=render.camera_pose(c,world.transform)
    follow,follows_it:=core.get(follows,camera)
    // An orbit looks at its pivot: the view focuses at its depth.
    if follows_it && follow.mode==.Orbit && follow.state.ready {
        live.focus=max(linalg.dot(follow.state.pivot.position-live.position,mm.quat_forward(live.rotation)),0)
    }
    changes:=follows_it?follow.state.changes:0
    if camera!=v.camera || changes!=v.changes {
        // The same camera blends as its mode asked; another, as the override it enters or the one it leaves.
        blend:=follow.state.blend
        if camera!=v.camera {blend=through.seconds>0?through:v.through}
        v.blending=v.camera!=core.NONE && blend.seconds>0
        v.cut=!v.blending
        if v.blending {
            v.from=v.pose
            v.anchor=core.NONE
            if at,ok:=anchor_at(worlds,body,frame);ok {
                v.from.position-=at
                v.anchor=body
            }
            v.blend,v.elapsed,v.turned=blend,0,live.rotation
        }
        v.camera,v.changes=camera,changes
    }
    v.through=through
    if v.blending {
        v.elapsed+=frame.dt
        if v.elapsed<v.blend.seconds {
            from:=v.from
            // What it left turns, around the body it travels with, as the camera has turned since.
            if v.anchor!=core.NONE {
                if at,ok:=anchor_at(worlds,v.anchor,frame);ok {
                    turn:=live.rotation*conj(v.turned)
                    from.rotation=turn*from.rotation
                    from.position=at+mm.quat_rotate(turn,from.position)
                }
            }
            pivot:=live.position+mm.quat_forward(live.rotation)*10
            if at,ok:=anchor_at(worlds,body,frame);ok {pivot=at}
            around:=follows_it && follow.mode==.Orbit && follow.state.ready
            if around {pivot=follow.state.pivot.position}
            live=pose_mix(from,live,pivot,around,mm.ease_apply(v.blend.ease,v.elapsed/v.blend.seconds))
        } else {v.blending=false}
    }
    v.pose=live
}

// Where a body is in this frame, between its last two ticks.
@(private)
anchor_at :: proc(worlds:^core.Table(core.World_Transform,$A),body:core.Entity,frame:core.Frame_Time) -> ([3]f32,bool) {
    placed,ok:=core.get(worlds,body)
    if !ok {return {},false}
    if frame.alpha<1 {return mm.lerp(placed.previous.position,placed.position,frame.alpha),true}
    return placed.position,true
}

// The view t of the way from one pose to another. around: the position turns
// around pivot at a distance between both. It draws what both draw, so that
// leaving the eyes of a body or coming to them does not show its head.
pose_mix :: proc "contextless" (from,to:render.View_Pose,pivot:[3]f32,around:bool,t:f32) -> render.View_Pose {
    out:=to
    out.rotation=mm.quat_slerp(from.rotation,to.rotation,t)
    out.position=around?orbit_mix(from.position,to.position,pivot,t):from.position+(to.position-from.position)*t
    out.near=from.near+(to.near-from.near)*t
    // Without a far plane at either end, none: infinity does not blend.
    out.far=from.far+(to.far-from.far)*t if from.far>0 && to.far>0 else 0
    out.shift=from.shift+(to.shift-from.shift)*t
    // The layers change when the view arrives, not when it leaves: a head that
    // the camera comes to see from the inside stays until it is there.
    out.layers=to.layers if t>=1 else from.layers
    out.own_hidden=to.own_hidden if t>=1 else from.own_hidden
    switch {
    case from.projection==.Perspective && to.projection==.Perspective:
        out.fov=2*math.atan(math.tan(from.fov/2)+(math.tan(to.fov/2)-math.tan(from.fov/2))*t)
    case from.projection==.Orthographic && to.projection==.Orthographic:
        out.height=from.height+(to.height-from.height)*t
    case:
        dolly_mix(&out,from,to,pivot,t)
    }
    // What it looks at goes from one to the other, wherever the view is between them.
    if from.focus>0 || to.focus>0 {
        at:=mm.lerp(pose_focus(from),pose_focus(to),t)
        out.focus=max(linalg.dot(at-out.position,mm.quat_forward(out.rotation)),0)
    }
    return out
}

@(private)
pose_focus :: proc "contextless" (p:render.View_Pose) -> [3]f32 {
    return p.position+mm.quat_forward(p.rotation)*p.focus
}

@(private)
orbit_mix :: proc "contextless" (from,to,pivot:[3]f32,t:f32) -> [3]f32 {
    a,b:=from-pivot,to-pivot
    la,lb:=linalg.length(a),linalg.length(b)
    if la<1e-3 || lb<1e-3 {return from+(to-from)*t}
    turn:=mm.quat_slerp(mm.Quat(1),mm.quat_between(a/la,b/lb),t)
    return pivot+mm.quat_rotate(turn,a/la)*(la+(lb-la)*t)
}

// One end is orthographic. The view leaves the perspective one as a dolly
// zoom: its field narrows to DOLLY_FOV while it backs away, and the height it
// sees at the depth of the pivot goes from one end to the other, so that near
// the orthographic end it looks like it. It stays perspective until that end.
// Nothing nearer than the plane of the orthographic camera is drawn, as that
// one does not see behind itself.
@(private)
dolly_mix :: proc "contextless" (out:^render.View_Pose,from,to:render.View_Pose,pivot:[3]f32,t:f32) {
    persp:=from
    ortho:=to
    s:=t
    if from.projection==.Orthographic {
        persp=to
        ortho=from
        s=1-t
    }
    p_forward:=mm.quat_forward(persp.rotation)
    o_forward:=mm.quat_forward(ortho.rotation)
    p_depth:=max(linalg.dot(pivot-persp.position,p_forward),1)
    o_depth:=max(linalg.dot(pivot-ortho.position,o_forward),ortho.near)
    p_tan,end_tan:=math.tan(persp.fov/2),math.tan(f32(DOLLY_FOV)/2)
    focus_p,focus_o:=persp.position+p_forward*p_depth,ortho.position+o_forward*o_depth
    focus:=focus_p+(focus_o-focus_p)*s
    tan_half:=p_tan+(end_tan-p_tan)*s
    height:=2*p_depth*p_tan+(ortho.height-2*p_depth*p_tan)*s
    depth:=height/(2*tan_half)
    out.projection=.Perspective
    out.fov=2*math.atan(tan_half)
    out.height=height
    out.position=focus-mm.quat_forward(out.rotation)*depth
    near:=persp.near+(ortho.near-persp.near)*s
    out.near=max(near,near+(depth-(o_depth-ortho.near)-near)*s)
    out.far=persp.far+(depth+ortho.far-o_depth-persp.far)*s if persp.far>0 && ortho.far>0 else 0
}

// The view each local slot had last frame: what tells that it jumped.
@(storage)
Local_Views :: struct {
    items:[input.LOCAL_CAPACITY]core.View,
    effects:[input.LOCAL_CAPACITY]render.View_Postprocess, // what each slot gave the renderer of its effects
}

// With several players at this machine, each slot is drawn from what
// camera_blend gives it, in its part of the screen (host.app_player_rect),
// with the exposure and the effects of the View_Volume where it is.
@(step="render",loops="game editor",after="render_sync")
camera_local_views :: proc(
    views:^Local_Views,seat_state:core.Ref(input.Seats),slots:core.Ref(Camera_Views),
    cameras:^core.Table(render.Camera,.Read),exposures:^core.Table(render.Exposure,.Read),worlds:^core.Table(core.World_Transform,.Read),app:^host.App,
    view_volumes:^core.Table(render.View_Volume,.Read),volumes:^core.Table(volume.Volume,.Read),parents:^core.Table(core.Parent,.Read),sections:^core.Table(scene.Scene_Reference,.Read),splines:^core.Table(volume.Spline,.Read),
) {
    n:=seat_state.local_count
    if n<2 {return}
    rects:[input.LOCAL_CAPACITY][4]i32
    for slot in 0..<n {
        rects[slot]=host.app_player_rect(app,slot,n)
        seen:=&slots.slots[slot]
        view:=&views.items[slot]
        render.view_of_camera(view,cameras,exposures,worlds,seen.camera,{f32(rects[slot].z),f32(rects[slot].w)},seen.blending?&seen.pose:nil,seen.cut)
        look:=render.view_volume_at(view_volumes,{volumes,worlds,parents,sections,splines},view.position)
        if !view.exposure.own {view.exposure=render.view_exposure_of(look)}
        render.view_postprocess_sync(app.assets,app.renderer,slot,look.layers,&views.effects[slot])
        view.own,view.slot=u8(slot+1),u8(slot+1)
        view.fade,view.focus=seen.fade,seen.pose.focus
    }
    host.app_views_set(app,views.items[:n],rects[:n],seat_state.focus)
}
