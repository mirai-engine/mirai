package mirai_anim

@(require) import cmath "core:math"
@(require) import "core:log"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import math "mirai:std/math"

when #config(MIRAI_BENCH,false) {
@(test)
bench_animation_resident_sampling :: proc(t:^testing.T) {
    TRACKS :: 96
    KEYS :: 120
    REPEATS :: 2000
    keys,err:=make([][KEYS]Keyframe,TRACKS)
    testing.expect(t,err==nil)
    defer delete(keys)
    tracks:[TRACKS]Track_Desc
    for &track,i in tracks {
        track={target=u64(i/3+1),property=Property(i%3),keys=keys[i][:]}
        for &key,k in keys[i] {
            phase:=f32(k)/f32(KEYS-1);sine,cosine:=cmath.sincos(phase*math.TAU)
            key.time=phase*2
            switch track.property {
            case .Position:key.value={sine*.4,f32(i)*.01,cosine*.2,0}
            case .Rotation:key.value=quat_vec4(math.quat_axis_angle({0,1,0},sine*.8))
            case .Scale:key.value={1,1,1,0}
            case .Float,.Vector:
            }
        }
    }
    library:Library
    testing.expect(t,library_init(&library,{max_keys=TRACKS*KEYS,max_tracks=TRACKS,max_clips=1}))
    defer library_destroy(&library)
    clip,_:=clip_add(&library,{tracks=tracks[:]})
    when #config(ANIM_COMPACT_BENCH,false) {
        stats,error:=library_compress(&library)
        testing.expect_value(t,error,Compress_Error.None)
        log.infof("animation compression: %d sampled, %d constant, %d default, %d raw tracks, %d -> %d bytes, error %.6f",stats.sampled_tracks,stats.constant_tracks,stats.default_tracks,stats.raw_tracks,stats.raw_bytes,stats.resident_bytes,stats.error)
    }
    best:=max(time.Duration);sink:f32
    for _ in 0..<5 {
        start:=time.tick_now()
        values:[TRACKS]math.Vec4
        for repeat in 0..<REPEATS {position:=f32(repeat%113)/112*2;clip_sample(&library,clip,position,values[:]);for value in values {sink+=value.x}}
        best=min(best,time.tick_since(start))
    }
    log.infof("animation resident %d tracks %d keys, %d stream bytes: %d bytes, %.2f ns/track (check %v)",TRACKS,library.key_count,library.stream_bytes,library_resident_bytes(&library),f64(time.duration_nanoseconds(best))/(REPEATS*TRACKS),sink)
}
}
