package gltf

import "core:testing"
import "core:math/linalg"
import importer "mirai:cook/import"

// The walk of Mesh2Motion, as glTF-Transform writes clips: times without a
// filter, translations with the exponential filter and rotations with the
// quaternion one, all decoded to the end of each view.
@(test)
meshopt_clips_decode_to_continuous_keys :: proc(t:^testing.T) {
    model,ok:=import_ok(t,RIG_FIXTURES+"walk.glb",{ignore_stored=true})
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.animations),1)
    clip:=model.animations[0]
    end:f32
    for track in clip.tracks {
        end=max(end,track.keys[len(track.keys)-1].time)
        for k in 1..<len(track.keys) {
            a,b:=track.keys[k-1].value,track.keys[k].value
            #partial switch track.property {
            case .Rotation: testing.expectf(t,abs(linalg.dot(a,b))>0.95,"%s turns smoothly between keys: %v %v",track.target,a,b)
            case .Position: testing.expectf(t,linalg.length(a.xyz-b.xyz)<0.1,"%s moves smoothly between keys: %v %v",track.target,a,b)
            }
        }
    }
    // The maximum the file states for its times.
    testing.expectf(t,abs(end-1.625)<1e-6,"the clip lasts what its accessors state: %v",end)
}
