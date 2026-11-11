package camera

import "mirai:core"
import render "mirai:engine/render"
import mm "mirai:std/math"

// A mode of a camera is data: a Camera_Setup says how it follows and its
// lens, and a Camera_Preset names the ones most games have. camera_mode asks
// for one; camera_follow, the only writer of Camera_Follow and of the lens,
// takes it, and every view through that camera blends into it (view.odin).
// A game with a mode of its own passes its setup.

Camera_Preset :: enum u8 {Isometric,Top_Down,Side,First_Person,Third_Person,Aim}

// The render.Layers of a head, which a camera at the eyes of its own body
// does not draw of that body: a mesh in this layer, or a part of a skinned
// mesh (animation Skin_Part). Every other camera, and the views of other
// players, draw it.
HEAD_LAYER :: u32(1)<<15

Camera_Setup :: struct {
    follow:Camera_Follow, // its target and its transient fields are not used: the camera keeps its own
    lens:render.Camera,   // its active and clip_plane are not used: the camera keeps its own
}

ISOMETRIC_PITCH :: 0.6154797 // radians: atan(1/sqrt(2)), a cube seen along its diagonal

CAMERA_PRESETS :: [Camera_Preset]Camera_Setup{
    // Orthographic, along the diagonal of a cube. It looks down from above
    // what it sees, so nothing brings it in.
    .Isometric={
        follow={mode=.Orbit,offset={0,1,0},distance=20,half_life=0.12,probe_radius=0,dead_zone={0.3,0.3,0},look_ahead=0.25,look_ahead_max=2,
            yaw=45*mm.RAD_PER_DEG,pitch=ISOMETRIC_PITCH,min_pitch=ISOMETRIC_PITCH,max_pitch=ISOMETRIC_PITCH,
            pull_grace=SPRING_ARM_GRACE,pull_time=SPRING_ARM_PULL_TIME,return_delay=SPRING_ARM_HOLD,return_time=SPRING_ARM_RETURN_TIME,arm_margin=SPRING_ARM_MARGIN},
        lens={projection=.Orthographic,fov=45*mm.RAD_PER_DEG,near=0.1,height=14},
    },
    .Top_Down={
        follow={mode=.Orbit,offset={0,1,0},distance=24,half_life=0.12,probe_radius=0,dead_zone={0.5,0.5,2},look_ahead=0.3,look_ahead_max=3,
            pitch=80*mm.RAD_PER_DEG,min_pitch=80*mm.RAD_PER_DEG,max_pitch=80*mm.RAD_PER_DEG,
            pull_grace=SPRING_ARM_GRACE,pull_time=SPRING_ARM_PULL_TIME,return_delay=SPRING_ARM_HOLD,return_time=SPRING_ARM_RETURN_TIME,arm_margin=SPRING_ARM_MARGIN},
        lens={projection=.Orthographic,fov=45*mm.RAD_PER_DEG,near=0.1,height=20},
    },
    // 2.5D, looking along -Z: it never follows depth, and the target moves in
    // a box before it follows, so that a jump does not shake it.
    .Side={
        follow={mode=.Orbit,offset={0,1.2,0},distance=14,half_life=0.15,dead_zone={0.8,1.2,1000},look_ahead=0.35,look_ahead_max=3,
            pitch=0.08,min_pitch=0.08,max_pitch=0.08},
        lens={projection=.Perspective,fov=35*mm.RAD_PER_DEG,near=0.1},
    },
    .First_Person={
        follow={mode=.Eyes,offset={0,1.6,0},min_pitch=-85*mm.RAD_PER_DEG,max_pitch=85*mm.RAD_PER_DEG},
        lens={projection=.Perspective,fov=70*mm.RAD_PER_DEG,near=0.05,own_hidden=HEAD_LAYER},
    },
    // Over the right shoulder, turned by the look of its player. A while after
    // it was last turned, it comes back behind the target that moves.
    .Third_Person={
        follow={mode=.Orbit,offset={0,1.45,0},distance=3.6,half_life=0.06,probe_radius=0.25,shoulder={0.55,0.15},dead_zone={0,0.3,0},
            pitch=0.25,min_pitch=-0.7,max_pitch=1.2,turn=true,recenter=3,
            pull_grace=SPRING_ARM_GRACE,pull_time=SPRING_ARM_PULL_TIME,return_delay=SPRING_ARM_HOLD,return_time=SPRING_ARM_RETURN_TIME,arm_margin=SPRING_ARM_MARGIN,hide_within=0.9},
        lens={projection=.Perspective,fov=60*mm.RAD_PER_DEG,near=0.05},
    },
    // Closer over the shoulder, with a narrower field, turning with the look
    // of the body: the camera a Camera_Activation brings while aiming.
    .Aim={
        follow={mode=.Orbit,offset={0,1.45,0},distance=1.8,half_life=0.04,probe_radius=0.25,shoulder={0.65,0.1},
            pitch=0.1,min_pitch=-0.7,max_pitch=1.2,aim=true,
            pull_grace=SPRING_ARM_GRACE,pull_time=SPRING_ARM_PULL_TIME,return_delay=SPRING_ARM_HOLD,return_time=SPRING_ARM_RETURN_TIME,arm_margin=SPRING_ARM_MARGIN,hide_within=0.7},
        lens={projection=.Perspective,fov=45*mm.RAD_PER_DEG,near=0.05},
    },
}

camera_preset :: proc "contextless" (preset:Camera_Preset) -> Camera_Setup {
    presets:=CAMERA_PRESETS
    return presets[preset]
}

// How a view comes into the camera it starts to be drawn from: over seconds,
// along ease. Zero seconds: it cuts.
Camera_Blend :: struct {
    seconds:f32,
    ease:mm.Ease,
}

CAMERA_BLEND :: Camera_Blend{seconds=0.5,ease=.Cubic_In_Out}

Camera_Change :: struct {
    camera:core.Entity,
    setup:Camera_Setup,
    blend:Camera_Blend,
}

@(storage,queue)
Camera_Changes :: struct {
    using queue:core.Queue(Camera_Change),
}

// camera takes the mode and its views blend into it. Asking for the mode it
// has does nothing, so a game may ask for it every tick. A camera without a
// Camera_Follow is given one.
camera_mode :: proc{camera_mode_preset,camera_mode_setup}

camera_mode_preset :: proc(changes:^Camera_Changes,camera:core.Entity,preset:Camera_Preset,blend:=CAMERA_BLEND) {
    camera_mode_setup(changes,camera,camera_preset(preset),blend)
}

camera_mode_setup :: proc(changes:^Camera_Changes,camera:core.Entity,setup:Camera_Setup,blend:=CAMERA_BLEND) {
    core.push(&changes.queue,Camera_Change{camera,setup,blend})
}

// The preset camera is set to, when it is one.
camera_preset_of :: proc(follows:^core.Table(Camera_Follow,$A),cameras:^core.Table(render.Camera,$B),camera:core.Entity) -> (Camera_Preset,bool) {
    follow,following:=core.get(follows,camera)
    lens,has_lens:=core.get(cameras,camera)
    if !following || !has_lens {return {},false}
    config:=camera_follow_config(follow)
    config.target=core.NONE
    for preset in Camera_Preset {
        setup:=camera_preset(preset)
        if camera_follow_config(setup.follow)==config && lens_on(lens,setup.lens)==lens {return preset,true}
    }
    return {},false
}

// What makes a setup: the fields a game authors, without what the camera derives.
camera_follow_config :: proc "contextless" (follow:Camera_Follow) -> Camera_Follow {
    config:=follow
    config.looking={}
    config.state={}
    return config
}

// A lens on a camera: it keeps whether the camera is active and its clip plane.
lens_on :: proc "contextless" (camera,lens:render.Camera) -> render.Camera {
    out:=lens
    out.active,out.clip_plane=camera.active,camera.clip_plane
    return out
}

// Why a setup cannot be taken; empty when it can.
@(private)
setup_invalid :: proc "contextless" (setup:Camera_Setup) -> string {
    f:=setup.follow
    lens:=setup.lens
    switch {
    case f.distance<0 || f.half_life<0 || f.probe_radius<0 || f.look_ahead<0 || f.look_ahead_max<0 || f.recenter<0:
        return "distance, half_life, probe_radius, look_ahead, look_ahead_max and recenter are 0 or more"
    case f.pull_grace<0 || f.pull_time<0 || f.return_delay<0 || f.return_time<0 || f.arm_margin<0 || f.hide_within<0:
        return "pull_grace, pull_time, return_delay, return_time, arm_margin and hide_within are 0 or more"
    case f.dead_zone.x<0 || f.dead_zone.y<0 || f.dead_zone.z<0:
        return "each side of dead_zone is 0 or more"
    case f.min_pitch>f.max_pitch:
        return "min_pitch is not above max_pitch"
    case lens.fov<0 || lens.fov>=3.14159 || lens.near<0:
        return "the lens has a fov from 0 to pi and a near of 0 or more"
    case lens.projection==.Orthographic && lens.height<=0:
        return "an orthographic lens has a height above 0"
    }
    return ""
}
