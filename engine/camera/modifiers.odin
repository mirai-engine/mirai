package camera

import "core:math"
import "mirai:core"
import render "mirai:engine/render"

// Changes a game layers over the setup of a camera without asking for another (a sprint that
// widens the lens, a crouch that lowers the pivot, an ability that pulls the arm out): each owns a
// slot of its camera by its id and blends in while asked and out once released. Their values, by
// their weights, add to those of Camera_Follow and of the lens; two that change the same value add
// up, with no priority. camera_modifier asks for one; camera_follow, the only writer of the camera,
// plays them: distance, offset and shoulder before its probe of the world, so an arm that grows
// stops at what is in the way, and roll after it.

CAMERA_MODIFIERS :: 8
// The vertical field of view, radians, that a perspective lens keeps with what shakes and modifiers
// add: render.Camera takes 0 as its default and needs less than pi.
CAMERA_FOV_MIN :: 0.05
CAMERA_FOV_MAX :: math.PI-0.05

Camera_Modifier :: struct {
    id:u32,               // given by the game: asked again by its id, it changes its slot
    fov:f32 `mirai:"angle"`,       // added to the vertical field of view of a perspective lens
    distance:f32 `mirai:"unit=m"`, // added to the arm of an Orbit; the sum is 0 or more
    offset:[3]f32 `mirai:"unit=m"`, // added to the offset from the target to the pivot
    shoulder:[2]f32 `mirai:"unit=m"`, // added to the shoulder of an Orbit
    roll:f32 `mirai:"angle"`,      // the view turns counterclockwise as seen
    blend_in,blend_out:f32 `mirai:"min=0,unit=s"`, // to reach its whole weight while asked, and to leave it once released
}

Modifier_Playing :: struct {
    modifier:Camera_Modifier,
    weight:f32, // 0..1 of what it adds
    asked:bool, // it blends in; released, it blends out and leaves its slot at weight 0
}

Camera_Modifier_Request :: struct {
    camera:core.Entity,
    modifier:Camera_Modifier,
    release:bool,
}

@(storage,queue)
Camera_Modifiers :: struct {
    queue:core.Queue(Camera_Modifier_Request),
}

// camera plays modifier while it is asked: it blends in from the weight it has, also when it was
// blending out. Asking for one it plays changes its values and blends, so a game may ask every
// tick.
camera_modifier :: proc(modifiers:^Camera_Modifiers,camera:core.Entity,modifier:Camera_Modifier) {
    core.push(&modifiers.queue,Camera_Modifier_Request{camera=camera,modifier=modifier})
}

// The modifier id of camera blends out over its blend_out; nothing when it plays none.
camera_modifier_release :: proc(modifiers:^Camera_Modifiers,camera:core.Entity,id:u32) {
    core.push(&modifiers.queue,Camera_Modifier_Request{camera=camera,modifier={id=id},release=true})
}

// Takes what was asked of the cameras that follow.
@(private)
modifiers_take :: proc(follows:^core.Table(Camera_Follow),states:^core.Table(Camera_Follow_State),modifiers:^Camera_Modifiers,problems:^core.Problems) {
    if modifiers==nil {return}
    for asked in core.take(&modifiers.queue) {
        m:=asked.modifier
        if !core.staged_has(follows,asked.camera) {
            core.report(problems,asked.camera,"camera.modifier","a camera modifier was asked of an entity without a Camera_Follow; ask it of the camera that follows")
            continue
        }
        sum:=m.fov+m.distance+m.offset.x+m.offset.y+m.offset.z+m.shoulder.x+m.shoulder.y+m.roll
        if !asked.release && (!(abs(sum)<math.F32_MAX) || !(m.blend_in>=0 && m.blend_in<math.F32_MAX) || !(m.blend_out>=0 && m.blend_out<math.F32_MAX)) {
            core.report(problems,asked.camera,"camera.modifier","the camera modifier %d was asked with values that are not finite or blends %v and %v: give it finite values and blends of 0 or more",m.id,m.blend_in,m.blend_out)
            continue
        }
        state:=follow_state(states,asked.camera,problems)
        if state==nil {continue}
        slot,free:=-1,-1
        for p,i in state.modifiers {
            if modifier_playing(p) {
                if p.modifier.id==m.id {slot=i;break}
            } else if free<0 {free=i}
        }
        if asked.release {
            if slot>=0 {state.modifiers[slot].asked=false}
            continue
        }
        if slot<0 {
            if free<0 {
                core.report(problems,asked.camera,"camera.modifiers_full","the camera modifier %d was refused: the camera plays %d, as many as fit; release the ones no longer needed with camera_modifier_release",m.id,CAMERA_MODIFIERS)
                continue
            }
            slot=free
            state.modifiers[slot]={}
        }
        state.modifiers[slot].modifier,state.modifiers[slot].asked=m,true
    }
}

// Whether a slot plays a modifier: asked, or released while it still blends out.
modifier_playing :: proc "contextless" (p:Modifier_Playing) -> bool {return p.asked || p.weight>0}

// What the modifiers of a camera add this frame, by their weights, after advancing their blends dt
// seconds. A released one that reached weight 0 leaves its slot.
@(private)
modifiers_advance :: proc "contextless" (state:^Camera_Follow_State,dt:f32) -> (add:Camera_Modifier) {
    for &p in state.modifiers {
        if !modifier_playing(p) {continue}
        if p.asked {
            p.weight=min(p.weight+dt/p.modifier.blend_in,1) if p.modifier.blend_in>0 else 1
        } else {
            p.weight=max(p.weight-dt/p.modifier.blend_out,0) if p.modifier.blend_out>0 else 0
        }
        if !modifier_playing(p) {p={};continue}
        w:=p.weight
        add.fov+=p.modifier.fov*w
        add.distance+=p.modifier.distance*w
        add.offset+=p.modifier.offset*w
        add.shoulder+=p.modifier.shoulder*w
        add.roll+=p.modifier.roll*w
    }
    return
}

// A Camera_Follow with what the modifiers add.
@(private)
modifiers_on :: proc "contextless" (follow:Camera_Follow,add:Camera_Modifier) -> Camera_Follow {
    out:=follow
    out.offset+=add.offset
    out.distance=max(follow.distance+add.distance,0)
    out.shoulder+=add.shoulder
    return out
}

// Gives a perspective camera its field of view without what the shakes and modifiers add (that of
// its setup or override) plus widen, within CAMERA_FOV_MIN..CAMERA_FOV_MAX. What it had without
// them is kept in state, so what one frame adds never adds to the last; an orthographic one keeps
// its own.
@(private)
lens_widen :: proc "contextless" (camera:^render.Camera,state:^Camera_Follow_State,widen:f32) {
    lens_restore(camera,state)
    if camera.projection!=.Perspective || widen==0 {return}
    state.fov_own,state.widened=camera.fov,true
    lens:=camera.fov if camera.fov>0 else render.CAMERA_DEFAULT.fov
    camera.fov=clamp(lens+widen,CAMERA_FOV_MIN,CAMERA_FOV_MAX)
}

// Puts back the field of view a camera had without what the shakes and modifiers add.
@(private)
lens_restore :: proc "contextless" (camera:^render.Camera,state:^Camera_Follow_State) {
    if !state.widened {return}
    camera.fov=state.fov_own
    state.widened=false
}
