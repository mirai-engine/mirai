package audio

import "mirai:core"
import volume "mirai:engine/volume"

// What the declarations of this library and of those it uses name: core.Test_Types.
test_types :: proc(types:^[dynamic]core.Test_Type) {
    volume.test_types(types)
    append(types,
        core.test_type(Audio_Source,default=proc(dst:^Audio_Source) {dst^=AUDIO_SOURCE_DEFAULT}),
        core.test_type(Audio_Occlusion,default=proc(dst:^Audio_Occlusion) {dst^=AUDIO_OCCLUSION_DEFAULT}),
        core.test_type(Audio_Material,default=proc(dst:^Audio_Material) {dst^=AUDIO_MATERIAL_DEFAULT}),
        core.test_type(Audio_Reverb,default=proc(dst:^Audio_Reverb) {dst^=AUDIO_REVERB_DEFAULT}),
        core.test_type(Audio_Volumes,default=proc(dst:^Audio_Volumes) {dst^=AUDIO_VOLUMES_DEFAULT}),
    )
}
