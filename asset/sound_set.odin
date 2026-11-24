package asset

import "core:math"
import "mirai:std/base"

// .sound_set: sounds that play as one. Random chooses one of them each time
// it plays, by its weight; Layered plays all of them together, started on the
// same frame (each after its sample-exact delay) and kept in step. Either
// draws a volume and a pitch from their ranges over the gain and pitch of each
// entry, and its curves shape the gain, pitch and low-pass of its sounds by
// the values of its parameters, which code sets on the Audio_Source that
// plays it (an engine's rpm, the intensity of a fight): data, no graph.
// It is heard as its hearing says when audio.play places it in the world.
// The sounds are .sound assets.
//
//   sound_set   Sound_Set_Info, one row

SOUND_SET_VERSION :: 5
SOUND_SET_CAPACITY :: 16
SOUND_SET_PITCH_MAX :: 64
SOUND_SET_DELAY_MAX :: f32(10) // s
SOUND_SET_PARAMETERS :: 4
SOUND_SET_CURVES :: 8
SOUND_CURVE_POINTS :: 4
SOUND_PARAMETER_NAME :: 24
SOUND_LOWPASS_MAX :: f32(24000) // Hz: a curve to it opens the filter

Sound_Variation :: struct {
    sound:base.Asset_Id, // a .sound; none: an empty entry
    weight:f32 `mirai:"min=0"`, // Random: how often it is chosen against the others; 0 is taken as 1
    gain:f32 `mirai:"min=0"`, // linear, over the volume drawn for the set; 0 is taken as 1
    pitch:f32 `mirai:"min=0,max=64"`, // rate, over the pitch drawn for the set; 0 is taken as 1
    delay:f32 `mirai:"min=0,max=10,unit=s"`, // Layered: after the start of the cue, exact to the sample
}

Sound_Set_Mode :: enum u8 {
    Random,  // one sound each time it plays, by their weights
    Layered, // every sound at once, started on the same frame (each after its delay) and kept in step
}

// How a sound falls with distance, as audio.Attenuation_Model.
Attenuation_Model :: enum u8 {None,Inverse,Linear,Exponential}

// How audio.play hears a set; an Audio_Source hears it as its own fields say.
Sound_Hearing :: struct {
    attenuation:Attenuation_Model, // how it falls between min_distance and max_distance
    min_distance:f32 `mirai:"min=0,unit=m"`,
    max_distance:f32 `mirai:"min=0,unit=m"`, // silent there; one placed farther from the listener does not start
    rolloff:f32 `mirai:"min=0"`, // how fast it falls: 1 is the curve as its model says it
    reverb:f32 `mirai:"min=0,max=1"`, // share of it the room of the listener reverberates
    priority:u8, // when more sounds play than the mixer has voices, the higher keep theirs
}

SOUND_HEARING_DEFAULT :: Sound_Hearing{attenuation=.Inverse,min_distance=1,max_distance=20,rolloff=1}

// A value code sets by its name while the set plays; it starts at 0.
Sound_Parameter :: struct {
    name:[SOUND_PARAMETER_NAME]u8 `mirai:"text"`, // empty: unused
    glide:f32 `mirai:"min=0,unit=s"`, // a new value is reached over this long, linearly
}

Sound_Curve_Target :: enum u8 {
    Gain,    // linear, over the volume it plays at
    Pitch,   // rate, over the pitch it plays at
    Lowpass, // Hz of a low-pass of the sound; SOUND_LOWPASS_MAX or above: none
}

Sound_Curve_Point :: struct {
    at:f32,    // value of the parameter
    value:f32, // what the target is there
}

// What a parameter does to a target of the sounds of the set: the line through
// its points, flat before the first and after the last (Kira's mapping of a
// modulator, by points). Gain and pitch multiply when several curves shape the
// same sound; the lowest low-pass wins.
Sound_Curve :: struct {
    parameter:u8 `mirai:"max=4"`, // 1 to SOUND_SET_PARAMETERS; 0: unused
    target:Sound_Curve_Target,
    layer:u8 `mirai:"max=16"`,    // the sound it shapes, 1 to SOUND_SET_CAPACITY; 0: every sound
    count:u8 `mirai:"min=1,max=4"`, // points used
    points:[SOUND_CURVE_POINTS]Sound_Curve_Point, // by rising at
}

Sound_Set_Info :: struct {
    mode:Sound_Set_Mode,
    sounds:[SOUND_SET_CAPACITY]Sound_Variation `mirai:"trim"`,
    volume_min,volume_max:f32 `mirai:"min=0"`, // linear gain over the volume it is played at
    pitch_min,pitch_max:f32 `mirai:"min=0,max=64"`, // rate over the pitch it is played at
    no_repeat:bool, // Random: not the same sound twice in a row while it has others
    hearing:Sound_Hearing,
    parameters:[SOUND_SET_PARAMETERS]Sound_Parameter `mirai:"trim"`,
    curves:[SOUND_SET_CURVES]Sound_Curve `mirai:"trim"`,
}

SOUND_SET_DEFAULTS :: Sound_Set_Info{volume_min=1,volume_max=1,pitch_min=1,pitch_max=1,no_repeat=true,hearing=SOUND_HEARING_DEFAULT}

// How the curves of a set shape one of its sounds at the values of its parameters.
Sound_Shape :: struct {
    gain:f32,
    pitch:f32,
    lowpass:f32, // Hz; 0: none
}

SOUND_SHAPE_NONE :: Sound_Shape{gain=1,pitch=1}

Sound_Set_Desc :: struct {
    id:base.Asset_Id,
    info:Sound_Set_Info,
}

Sound_Set_View :: struct {
    info:^Sound_Set_Info,
}

// What is wrong with the values of a set, as a field and how to correct it; "" when nothing.
sound_set_problem :: proc(info:Sound_Set_Info) -> (field,message:string) {
    info:=info
    finite :: proc(v:f32) -> bool {return !math.is_nan(v) && !math.is_inf(v)}
    if info.mode>max(Sound_Set_Mode) {return "mode","the mode is Random or Layered"}
    for variation in info.sounds {
        if !finite(variation.weight) || variation.weight<0 {return "sounds.weight","a weight is 0 or more; 0 is taken as 1"}
        if !finite(variation.gain) || variation.gain<0 {return "sounds.gain","a gain is 0 or more; 0 is taken as 1"}
        if !(variation.pitch>=0 && variation.pitch<=SOUND_SET_PITCH_MAX) {return "sounds.pitch","a pitch is 0 to 64; 0 is taken as 1"}
        if !(variation.delay>=0 && variation.delay<=SOUND_SET_DELAY_MAX) {return "sounds.delay","a delay is 0 to 10 seconds"}
    }
    if !finite(info.volume_min) || !finite(info.volume_max) || info.volume_min<0 || info.volume_min>info.volume_max {
        return "volume_min","the volumes are 0 or more, and volume_min is not above volume_max"
    }
    if !finite(info.pitch_min) || !finite(info.pitch_max) || info.pitch_min<=0 || info.pitch_min>info.pitch_max || info.pitch_max>SOUND_SET_PITCH_MAX {
        return "pitch_min","the pitches are above 0 and at most 64, and pitch_min is not above pitch_max"
    }
    h:=info.hearing
    if h.attenuation>max(Attenuation_Model) {return "hearing.attenuation","the attenuation is one of None, Inverse, Linear and Exponential"}
    if !finite(h.min_distance) || !finite(h.max_distance) || !(h.min_distance>0) || !(h.max_distance>h.min_distance) {
        return "hearing.min_distance","the distances are above 0, and max_distance is above min_distance"
    }
    if !finite(h.rolloff) || h.rolloff<0 {return "hearing.rolloff","the rolloff is 0 or more"}
    if !(h.reverb>=0 && h.reverb<=1) {return "hearing.reverb","the reverb is 0 to 1"}
    for &p,i in info.parameters {
        if !finite(p.glide) || p.glide<0 {return "parameters.glide","a glide is 0 or more seconds"}
        name:=base.text_get(p.name[:])
        if name=="" {continue}
        for &other in info.parameters[:i] {
            if base.text_get(other.name[:])==name {return "parameters.name","two parameters have the same name; give each its own"}
        }
    }
    for &c in info.curves {
        if c.parameter==0 {continue}
        if int(c.parameter)>SOUND_SET_PARAMETERS || base.text_get(info.parameters[c.parameter-1].name[:])=="" {
            return "curves.parameter","a curve follows a parameter of the set that has a name, 1 to 4; 0 leaves it unused"
        }
        if c.target>max(Sound_Curve_Target) {return "curves.target","the target is Gain, Pitch or Lowpass"}
        if int(c.layer)>SOUND_SET_CAPACITY {return "curves.layer","the layer is a sound of the set, 1 to 16, or 0 for all of them"}
        if c.target==.Pitch && c.layer!=0 && info.mode==.Layered {
            return "curves.layer","the pitch of a Layered set shapes all of its sounds (layer 0), so they stay in step"
        }
        if c.count<1 || int(c.count)>SOUND_CURVE_POINTS {return "curves.count","a curve has 1 to 4 points"}
        for point,k in c.points[:c.count] {
            if !finite(point.at) || !finite(point.value) {return "curves.points","the points of a curve are numbers"}
            if k>0 && point.at<c.points[k-1].at {return "curves.points","the points of a curve go by rising at"}
            switch c.target {
            case .Gain:if point.value<0 {return "curves.points","a gain is 0 or more"}
            case .Pitch:if !(point.value>0) || point.value>SOUND_SET_PITCH_MAX {return "curves.points","a pitch is above 0 and at most 64"}
            case .Lowpass:if !(point.value>0) {return "curves.points","a low-pass is above 0 Hz"}
            }
        }
    }
    return "",""
}

// The index of a parameter of the set by its name; false when it has none of that name.
sound_set_parameter :: proc(info:^Sound_Set_Info,name:string) -> (index:int,found:bool) {
    if name=="" {return}
    for &p,i in info.parameters {
        if base.text_get(p.name[:])==name {return i,true}
    }
    return
}

// The value of a curve at a value of its parameter. A low-pass goes from point
// to point by octaves, as it is heard.
sound_curve_at :: proc "contextless" (c:Sound_Curve,x:f32) -> f32 {
    count:=clamp(int(c.count),1,SOUND_CURVE_POINTS)
    points:=c.points
    if !(x>points[0].at) {return points[0].value}
    for k in 1..<count {
        a,b:=points[k-1],points[k]
        if x>=b.at {continue}
        t:=(x-a.at)/(b.at-a.at) if b.at>a.at else 1
        if c.target==.Lowpass {return a.value*math.pow(b.value/a.value,t)}
        return a.value+(b.value-a.value)*t
    }
    return points[count-1].value
}

// How the curves of a set shape its sound layer (0 to SOUND_SET_CAPACITY-1)
// at the values of its parameters.
sound_set_shape :: proc "contextless" (info:^Sound_Set_Info,layer:int,values:[SOUND_SET_PARAMETERS]f32) -> (shape:Sound_Shape) {
    shape=SOUND_SHAPE_NONE
    for c in info.curves {
        if c.parameter==0 || int(c.parameter)>SOUND_SET_PARAMETERS || c.layer!=0 && int(c.layer)!=layer+1 {continue}
        v:=sound_curve_at(c,values[c.parameter-1])
        switch c.target {
        case .Gain:shape.gain*=v
        case .Pitch:shape.pitch*=v
        case .Lowpass:
            if v<SOUND_LOWPASS_MAX && (shape.lowpass==0 || v<shape.lowpass) {shape.lowpass=v}
        }
    }
    return
}

sound_set_document :: proc(doc:^Document,types:^Types,desc:Sound_Set_Desc,allocator:=context.allocator) -> Error {
    info:=desc.info
    if _,message:=sound_set_problem(info);message!="" {return .Invalid}
    document_init(doc,KIND_SOUND_SET,desc.id,allocator)
    doc.kind_version=SOUND_SET_VERSION
    if _,error:=document_put_row(doc,types,"sound_set",&info);error!=.None {
        document_destroy(doc)
        return error
    }
    return .None
}

sound_set_save :: proc(path:string,types:^Types,desc:Sound_Set_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    sound_set_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

// The file of a set, as bytes from allocator.
sound_set_bytes :: proc(types:^Types,desc:Sound_Set_Desc,allocator:=context.allocator) -> (data:[]u8,error:Error) {
    doc:Document
    sound_set_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_bytes(&doc,allocator)
}

sound_set_view :: proc(a:^Asset,types:^Types) -> (view:Sound_Set_View,error:Error) {
    kind_check(a,KIND_SOUND_SET,SOUND_SET_VERSION) or_return
    view.info=asset_row(a,types,"sound_set",Sound_Set_Info,whole=true) or_return
    if _,message:=sound_set_problem(view.info^);message!="" {return {},.Corrupt}
    return view,.None
}
