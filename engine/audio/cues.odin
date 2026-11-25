package audio

import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

// A sound and a birth of particles played at one moment, where something is and
// by it: what a marker of a .character plays (the animation plugin) and what the
// windows and the hits of an ability play (the abilities plugin).
Cue :: struct {
    sound:base.Asset_Id `mirai:"optional,kind=.sound .sound_set"`, // zero: no sound
    channel:[core.CHANNEL_NAME_BYTES]u8 `mirai:"text,optional"`,   // of its birth (core.birth_channel); empty: no birth
    align_up:bool `mirai:"optional"`,                              // the birth's normal is the up of where it plays
}

// The channel of the birth of cue: what whoever loads the cue keeps for cue_play.
cue_channel :: proc(cue:Cue) -> core.Birth_Channel {
    cue:=cue
    return core.birth_channel(base.text_get(cue.channel[:]))
}

// Plays cue at `at` (nil: its sound is not placed and it gives no birth) by the
// entity that makes it. Its sound plays once per tick of that entity: a tick a
// rollback runs again neither repeats it nor misses what only the corrected
// tick asks (audio_requests). Its birth goes to channel, the cue_channel of cue
// kept when the cue loaded.
cue_play :: proc(sounds:^Sound_Requests,births:^core.Births,cue:Cue,channel:core.Birth_Channel,at:Maybe(mm.Transform),by:core.Entity) {
    pose,placed:=at.?
    if cue.sound!={} && sounds!=nil {
        position:Maybe([3]f32)
        if placed {position=pose.position}
        play_id(sounds,cue.sound,position,by=by)
    }
    if channel!=0 && placed && births!=nil {
        b:=core.Birth{channel=channel,by=by,position=pose.position}
        if cue.align_up {b.normal=mm.quat_rotate(pose.rotation,{0,1,0})}
        core.birth(births,b)
    }
}
