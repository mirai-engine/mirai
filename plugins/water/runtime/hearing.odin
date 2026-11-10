package water

import "mirai:core"
import audio "mirai:engine/audio"
import phys "plugins:physics/runtime"

// A listener under the surface of a fluid, out of a dry box, hears through
// the water: the highs die (UNDER_LOWPASS) and a small room of water rings
// (UNDER_REVERB), which audio_reverb fades in and out as it does between rooms.

UNDER_LOWPASS :: f32(800) // Hz
UNDER_REVERB :: audio.Reverb{room_size=0.35,damping=0.85,wet=0.7,width=0.6}

// The medium of a listener where the fluid at it is the one given, or none.
medium_at :: proc "contextless" (sample:phys.Fluid_Sample,found:bool) -> audio.Audio_Medium {
    if !found || !(sample.density>0) {return {}}
    return {lowpass=UNDER_LOWPASS,reverb=UNDER_REVERB,weight=1}
}

@(step="late",stage="end",after="camera_view")
water_hearing :: proc(medium:^audio.Audio_Medium,physics:core.Ref(phys.Physics_State),worlds:core.Read(core.World_Transform),listeners:core.Read(audio.Audio_Listener),view:core.Ref(core.View)) {
    sample:phys.Fluid_Sample
    found:=false
    if position,heard:=audio.listener_position(worlds,listeners,view);heard {sample,_,found=phys.fluid_at(physics,position)}
    if next:=medium_at(sample,found);medium^!=next {medium^=next}
}
