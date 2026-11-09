package asset

import "core:math"
import "mirai:std/base"

// .sound_set: sounds that play as one. Each time it plays, one of them is
// chosen by its weight, with a volume and a pitch drawn from their ranges.
// The sounds are .sound assets.
//
//   sound_set   Sound_Set_Info, one row

SOUND_SET_VERSION :: 1
SOUND_SET_CAPACITY :: 16
SOUND_SET_PITCH_MAX :: 64

Sound_Variation :: struct {
    sound:base.Asset_Id, // a .sound; none: an empty entry
    weight:f32 `mirai:"min=0"`, // how often it is chosen against the others; 0 is taken as 1
}

Sound_Set_Info :: struct {
    sounds:[SOUND_SET_CAPACITY]Sound_Variation `mirai:"trim"`,
    volume_min,volume_max:f32 `mirai:"min=0"`, // linear gain over the volume it is played at
    pitch_min,pitch_max:f32 `mirai:"min=0,max=64"`, // rate over the pitch it is played at
    no_repeat:bool, // not the same sound twice in a row while it has others
}

SOUND_SET_DEFAULTS :: Sound_Set_Info{volume_min=1,volume_max=1,pitch_min=1,pitch_max=1,no_repeat=true}

Sound_Set_Desc :: struct {
    id:base.Asset_Id,
    info:Sound_Set_Info,
}

Sound_Set_View :: struct {
    info:^Sound_Set_Info,
}

// What is wrong with the values of a set, as a field and how to correct it; "" when nothing.
sound_set_problem :: proc(info:Sound_Set_Info) -> (field,message:string) {
    finite :: proc(v:f32) -> bool {return !math.is_nan(v) && !math.is_inf(v)}
    for variation in info.sounds {
        if !finite(variation.weight) || variation.weight<0 {return "sounds.weight","a weight is 0 or more; 0 is taken as 1"}
    }
    if !finite(info.volume_min) || !finite(info.volume_max) || info.volume_min<0 || info.volume_min>info.volume_max {
        return "volume_min","the volumes are 0 or more, and volume_min is not above volume_max"
    }
    if !finite(info.pitch_min) || !finite(info.pitch_max) || info.pitch_min<=0 || info.pitch_min>info.pitch_max || info.pitch_max>SOUND_SET_PITCH_MAX {
        return "pitch_min","the pitches are above 0 and at most 64, and pitch_min is not above pitch_max"
    }
    return "",""
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
    defaults:=SOUND_SET_DEFAULTS
    view.info=asset_row(a,types,"sound_set",Sound_Set_Info,&defaults) or_return
    if _,message:=sound_set_problem(view.info^);message!="" {return {},.Corrupt}
    return view,.None
}
