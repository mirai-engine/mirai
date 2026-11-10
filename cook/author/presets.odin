package author

import "base:runtime"
import "core:math/linalg"
import "core:mem"
import "core:reflect"
import "mirai:core"
import eaudio "mirai:engine/audio"
import ecamera "mirai:engine/camera"
import erender "mirai:engine/render"
import evolume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"

// The recipes of components an entity is made from: the presets of the
// engine, and the cards the editor packages of plugins add. The editor makes
// entities with them on the world it edits; a document written with no editor
// runs them on a world of its own and keeps the components they give.

// What the Create panel, the API and a document make: recipes of components, not kinds.
Preset :: enum u8 {Empty,Cube,Sphere,Cylinder,Cone,Capsule,Plane,Prism,Pyramid,Point_Light,Spot_Light,Sun,Camera,Rect_Light,Isometric_Camera,Top_Down_Camera,Side_Camera,First_Person_Camera,Third_Person_Camera,Aim_Camera,Sound,Reverb_Zone}

// The mode of engine/camera a camera preset follows the player in.
preset_camera_mode :: proc "contextless" (preset:Preset) -> (ecamera.Camera_Preset,bool) {
    #partial switch preset {
    case .Isometric_Camera:    return .Isometric,true
    case .Top_Down_Camera:     return .Top_Down,true
    case .Side_Camera:         return .Side,true
    case .First_Person_Camera: return .First_Person,true
    case .Third_Person_Camera: return .Third_Person,true
    case .Aim_Camera:          return .Aim,true
    }
    return {},false
}

preset_components :: proc(w:core.World_Ref,e:core.Entity,preset:Preset) {
    if shape:=preset_shape(preset);shape!=.None {
        if t:=core.world_table_of(w,erender.Mesh_Renderer);t!=nil {core.add(t,e,erender.Mesh_Renderer{shape=shape})}
        return
    }
    #partial switch preset {
    case .Point_Light: if t:=core.world_table_of(w,erender.Point_Light);t!=nil {core.add(t,e,erender.POINT_LIGHT_DEFAULT)}
    case .Spot_Light:  if t:=core.world_table_of(w,erender.Spot_Light);t!=nil {core.add(t,e,erender.SPOT_LIGHT_DEFAULT)}
    case .Rect_Light:  if t:=core.world_table_of(w,erender.Rect_Light);t!=nil {core.add(t,e,erender.RECT_LIGHT_DEFAULT)}
    case .Sun:         if t:=core.world_table_of(w,erender.Sun);t!=nil {core.add(t,e,erender.SUN_DEFAULT)}
    case .Camera:      if t:=core.world_table_of(w,erender.Camera);t!=nil {core.add(t,e,erender.CAMERA_DEFAULT)}
    case .Isometric_Camera,.Top_Down_Camera,.Side_Camera,.First_Person_Camera,.Third_Person_Camera,.Aim_Camera:
        mode,_:=preset_camera_mode(preset)
        setup:=ecamera.camera_preset(mode)
        if t:=core.world_table_of(w,erender.Camera);t!=nil {
            core.add(t,e,ecamera.lens_on(erender.CAMERA_DEFAULT,setup.lens))
        }
        if t:=core.world_table_of(w,ecamera.Camera_Follow);t!=nil {core.add(t,e,setup.follow)}
        if preset==.Aim_Camera {
            if t:=core.world_table_of(w,ecamera.Camera_Activation);t!=nil {core.add(t,e,ecamera.CAMERA_ACTIVATION_DEFAULT)}
        }
    case .Sound:       sound_components(w,e,{})
    case .Reverb_Zone:
        if t:=core.world_table_of(w,eaudio.Audio_Reverb);t!=nil {core.add(t,e,eaudio.AUDIO_REVERB_DEFAULT)}
        if t:=core.world_table_of(w,evolume.Volume);t!=nil {core.add(t,e,evolume.Volume{shape=.Box,extents={5,3,5},blend=1})}
    }
}

// A sound placed in the scene: a spatial source in a loop that the room
// reverberates and walls hide.
sound_components :: proc(w:core.World_Ref,e:core.Entity,sound:base.Asset_Id) {
    if t:=core.world_table_of(w,eaudio.Audio_Source);t!=nil {
        source:=eaudio.AUDIO_SOURCE_DEFAULT
        source.sound,source.loop,source.spatial,source.reverb=sound,true,true,1
        core.add(t,e,source)
    }
    if t:=core.world_table_of(w,eaudio.Audio_Occlusion);t!=nil {core.add(t,e,eaudio.AUDIO_OCCLUSION_DEFAULT)}
}

// How a preset turns what it makes when no rotation is given: a sun shines
// from the morning of SUN_DIRECTION and a spot down. Lights shine toward -Z.
preset_rotation :: proc(preset:Preset) -> mm.Quat {
    #partial switch preset {
    case .Sun:        return mm.quat_between([3]f32{0,0,1},linalg.normalize(erender.SUN_DIRECTION))
    case .Spot_Light: return mm.quat_between(mm.FORWARD,[3]f32{0,-1,0})
    }
    return 1
}

// The primitive a preset shows; None for one without a body.
preset_shape :: proc "contextless" (preset:Preset) -> erender.Shape {
    #partial switch preset {
    case .Cube:     return .Cube
    case .Sphere:   return .Sphere
    case .Cylinder: return .Cylinder
    case .Cone:     return .Cone
    case .Capsule:  return .Capsule
    case .Plane:    return .Plane
    case .Prism:    return .Prism
    case .Pyramid:  return .Pyramid
    }
    return .None
}
