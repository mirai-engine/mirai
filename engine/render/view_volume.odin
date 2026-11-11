package render

import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:host"
import gpu "mirai:render"

// How the views look where they are: a tunnel exposes darker, under water
// the image is tinted, a zone of the game has its effects. Each rules where
// the Volume of its entity says, by its priority; without a Volume, in the
// whole world; without any, VIEW_VOLUME_DEFAULT. The view of the game takes
// them where it is once a frame (render_sync), as the exposure of the scene
// and its effects; a camera with an Exposure keeps its own exposure, and a
// view of its own (a player of a split screen, a monitor) takes its exposure
// where it is (view_volume_expose); a player of a split screen, its effects
// too (view_postprocess_sync). The light of the sky and the sun does not
// change with them: it would change the light of the whole world as the
// camera moves.

@(component,replicated,description="How the views look where its Volume is: their exposure, a tint of the image and its effects. Without a Volume, in the whole world. A camera with its own Exposure keeps it.")
View_Volume :: struct {
    exposure:Exposure `mirai:"section=Exposure"`,
    tint:[3]f32 `mirai:"color"`, // multiplies the image before the display: white leaves it as it is
    layers:[POST_PROCESS_CAPACITY]Post_Process_Layer `mirai:"section=Effects"`, // the effects of the image, in order
}

VIEW_VOLUME_DEFAULT :: View_Volume{exposure=EXPOSURE_DEFAULT,tint={1,1,1}}

// A volume that replaces blends the numbers of what is below into its own by
// its weight, and takes its modes and effects past half; one that adds adds
// its compensation, multiplies its tint and puts its effects after.
view_volume_mix :: proc(value:^View_Volume,by:View_Volume,weight:f32,add:bool) {
    if add {
        value.exposure.compensation+=by.exposure.compensation*weight
        value.tint*=1+(by.tint-1)*weight
        if weight<0.5 {return}
        at:=0
        for layer in value.layers {if layer.enabled || layer.material!={} {at+=1}}
        for layer in by.layers {
            if at==POST_PROCESS_CAPACITY {break}
            if !layer.enabled || layer.material=={} {continue}
            value.layers[at]=layer
            at+=1
        }
        return
    }
    e,b:=&value.exposure,by.exposure
    lerp :: proc "contextless" (a:^f32,b,w:f32) {a^+=(b-a^)*w}
    lerp(&e.compensation,b.compensation,weight);lerp(&e.aperture,b.aperture,weight)
    lerp(&e.shutter,b.shutter,weight);lerp(&e.iso,b.iso,weight)
    lerp(&e.min_ev100,b.min_ev100,weight);lerp(&e.max_ev100,b.max_ev100,weight)
    lerp(&e.adaptation,b.adaptation,weight)
    value.tint+=(by.tint-value.tint)*weight
    if weight>=0.5 {
        e.mode,e.adaptation_mode=b.mode,b.adaptation_mode
        value.layers=by.layers
    }
}

// How a view looks at point.
view_volume_at :: proc(views:^core.Table(View_Volume,$A),volumes:^core.Table(volume.Volume,$B),worlds:^core.Table(core.World_Transform,$C),point:[3]f32) -> View_Volume {
    return volume.at(volumes,worlds,views,point,VIEW_VOLUME_DEFAULT,view_volume_mix)
}

// The exposure of a view that looks as v says.
view_exposure_of :: proc "contextless" (v:View_Volume) -> core.View_Exposure {
    e:=exposure_of(v.exposure)
    e.tint=v.tint
    return e
}

// A view through a camera without its own Exposure takes that of where it is.
view_volume_expose :: proc(view:^core.View,views:^core.Table(View_Volume,$A),volumes:^core.Table(volume.Volume,$B),worlds:^core.Table(core.World_Transform,$C)) {
    if view.exposure.own {return}
    view.exposure=view_exposure_of(view_volume_at(views,volumes,worlds,view.position))
}

// The effects of layers as the renderer runs them: those on whose material
// has a PostProcess program, in order.
postprocess_effects :: proc(a:^host.Assets,layers:[POST_PROCESS_CAPACITY]Post_Process_Layer) -> (effects:gpu.Postprocess_List) {
    for layer in layers {
        if !layer.enabled || layer.material=={} {continue}
        if effect,usable:=host.assets_postprocess(a,layer.material);usable {
            effect.after_tonemap,effect.fade=layer.after_tonemap,layer.fade
            effects.entries[effects.count]=effect
            effects.count+=1
        }
    }
    host.assets_commit(a)
    return
}

// What a local view last gave the renderer of its effects.
View_Postprocess :: struct {
    layers:[POST_PROCESS_CAPACITY]Post_Process_Layer,
    revision,structure:u64, // of the assets then
    given:gpu.Postprocess_List,
}

// Gives the renderer the effects of layers for the local view slot
// (render.Camera.slot is slot + 1) when they, the assets they name or what
// the renderer holds for the slot changed since last.
view_postprocess_sync :: proc(assets:^host.Assets,renderer:^Renderer,slot:int,layers:[POST_PROCESS_CAPACITY]Post_Process_Layer,last:^View_Postprocess) {
    a,r:=assets,renderer
    if a==nil || r==nil || slot<0 || slot>=len(r.view_postprocesses) {return}
    if last.layers==layers && last.revision==a.revision && last.structure==a.structure && r.view_postprocesses[slot]==last.given {return}
    last.given=postprocess_effects(a,layers)
    gpu.renderer_set_view_postprocesses(r,slot,last.given)
    last.layers,last.revision,last.structure=layers,a.revision,a.structure
}
