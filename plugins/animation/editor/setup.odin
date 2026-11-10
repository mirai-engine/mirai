package animation_editor

import "core:fmt"
import "core:math/linalg"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:platform"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

// What a character should be able to do.
Setup_Want :: enum u8 {Locomotion,Look,Foot_Ik,Hand_Ik,Gestures}
Setup_Wants :: bit_set[Setup_Want]
SETUP_ALL :: Setup_Wants{.Locomotion,.Look,.Foot_Ik,.Hand_Ik,.Gestures}
Setup_Status :: enum u8 {Ready,Partial,Missing,Skipped}

// Each gesture plays over the upper body and over each arm.
SETUP_GESTURES :: anim.ACTION_CAPACITY/3
SETUP_CLIPS :: anim.MATCH_CLIPS+SETUP_GESTURES
// m/s: a body slower than this stands, with the clips that do not travel.
SETUP_STATIONARY_SPEED :: 0.15
Setup_Speed :: struct {clip:[64]u8 `mirai:"text"`,speed:f32 `mirai:"unit=m/s,label=Above 0"`}
Setup_Rate :: struct {
    clip:[64]u8 `mirai:"text"`,
    min_rate:f32 `mirai:"min=0,label=Above 0"`,
    max_rate:f32 `mirai:"min=0,label=At least min_rate"`,
}
SETUP_BLENDS :: 8
SETUP_BLEND_SAMPLES :: 64
Setup_Blend_Sample :: struct {
    weights:[anim.MATCH_BLEND]f32 `mirai:"min=0,max=1,label=Eight: one per clip of the blend in its order, 0 past its clips; they play as shares of their sum, above 0"`,
    speed:f32 `mirai:"optional,min=0,unit=m/s,label=The speed it travels at; omitted is measured from its blended feet"`,
}
// Locomotion clips that loop, last the same and are in phase, searched as one clip per sample.
Setup_Blend :: struct {
    clips:[anim.MATCH_BLEND][64]u8 `mirai:"text,label=2 to 8 looping locomotion clips of one mode and duration, in phase (the directions of a set); they leave the locomotion as clips of their own"`,
    samples:[SETUP_BLEND_SAMPLES]Setup_Blend_Sample `mirai:"optional,label=The points of the blend the search can pick, each played as those clips at its weights"`,
    min_rate:f32 `mirai:"optional,min=0,label=The least share of its speed each sample plays at, in place of min_rate of the setup; omitted or 0 keeps that"`,
    max_rate:f32 `mirai:"optional,min=0,label=The most share of its speed each sample plays at, with min_rate"`,
}

Setup_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,optional,label=The rig: the entity with the skinned mesh, whose Animation gets the .character. Or skeleton"`,
    skeleton:base.Asset_Id `mirai:"optional,label=The .skeleton instead of id: only writes the .character and returns it, with library"`,
    library:base.Asset_Id `mirai:"optional,label=The .anim with its clips; empty takes what id plays"`,
    clips:[SETUP_CLIPS][64]u8 `mirai:"text,optional,label=The clips of the library to classify by name; omitted is all of them"`,
    speeds:[anim.MATCH_CLIPS]Setup_Speed `mirai:"optional,label=The m/s a locomotion clip travels at instead of the one measured from its feet"`,
    rates:[anim.MATCH_CLIPS]Setup_Rate `mirai:"optional,label=The least and most share of its own speed a locomotion clip plays at, in place of min_rate and max_rate: a set authored slower than it is played (a crouch), or a jog kept from beating a sprint"`,
    blends:[SETUP_BLENDS]Setup_Blend `mirai:"optional,label=Blends of locomotion clips, sampled at the weights of each sample (as a blend space sampled for motion matching)"`,
    min_rate:f32 `mirai:"optional,min=0,label=The least share of its own speed a locomotion clip plays at to follow the body; omitted is the default of a .character"`,
    max_rate:f32 `mirai:"optional,min=0,label=The most share of its own speed a locomotion clip plays at, at least min_rate"`,
    trajectory_direction:f32 `mirai:"optional,min=0,label=Weight of where the body faces along its trajectory; 0 for a body that never turns, as one that walks sideways"`,
    landing_marker:[64]u8 `mirai:"text,optional,label=The marker of first contact on the clips that land (a jump), played to reach it when the body lands; omitted is the default of a .character, empty plays no landing"`,
    landing_rates:[2]f32 `mirai:"optional,min=0,label=The least and most rate a clip plays at to reach its landing marker when the body lands; omitted is the default of a .character"`,
    want:Setup_Wants `mirai:"optional,label=Locomotion (the clips told apart by name: idle and walk to sprint walk, a fall or air loop falls, jump and land enter falling and walking, swim and fly; the physics plugin moves it); Look (head); Foot_Ik (grounding); Hand_Ik (reach); Gestures (actions that play each clip that is not locomotion over the upper body or one arm). Omitted is all of them"`,
    folder:[1024]u8 `mirai:"text,optional,label=Folder of the .character; empty puts it by the clips"`,
    name:[64]u8 `mirai:"text,optional,label=Name of the .character; empty takes the skeleton's"`,
    replace:bool `mirai:"optional,label=Overwrites the .character of a previous setup"`,
    dry_run:bool `mirai:"optional,label=Plans and answers without writing"`,
}
Setup_Asset_Result :: struct {kind:[16]u8 `mirai:"text"`,path:[1024]u8 `mirai:"text"`,asset:base.Asset_Id,replaced:bool}
Setup_Capability_Result :: struct {want:Setup_Want,status:Setup_Status,detail:[4096]u8 `mirai:"text"`,fix:[1024]u8 `mirai:"text,label=How to make it Ready"`}
// A locomotion clip: the Locomotion_Mode it serves; entry: it starts that mode; told: its
// speed came from speeds; rates: its own from rates.
Setup_Match_Clip_Result :: struct {clip:[64]u8 `mirai:"text"`,mode:[32]u8 `mirai:"text"`,entry,loop:bool,speed:f32 `mirai:"unit=m/s"`,told:bool `mirai:"optional"`,rates:[2]f32 `mirai:"optional"`}
// A blend of locomotion clips: its clips, the mode they serve, how many samples it has and its own rates.
Setup_Blend_Result :: struct {clips:[anim.MATCH_BLEND][64]u8 `mirai:"text"`,mode:[32]u8 `mirai:"text"`,samples:u32,rates:[2]f32 `mirai:"optional"`}
Setup_Clips_Result :: struct {locomotion:[anim.MATCH_CLIPS]Setup_Match_Clip_Result,blends:[SETUP_BLENDS]Setup_Blend_Result `mirai:"optional"`,gestures:[SETUP_GESTURES][64]u8 `mirai:"text"`}
Setup_Result :: struct {
    id:base.Entity_Id `mirai:"optional"`,skeleton:base.Asset_Id `mirai:"optional"`,dry_run:bool `mirai:"optional"`,body:[16]u8 `mirai:"text,label=stored or detected"`,
    assets:[1]Setup_Asset_Result,capabilities:[len(Setup_Want)]Setup_Capability_Result,clips:Setup_Clips_Result,
}

@(private)
setup_register :: proc(s:^editor.Session) {
    defaults:=Setup_Params{want=SETUP_ALL}
    authoring_method_register(s,{name="animation.character.setup",summary="Makes a character move: writes the .character of each capability from its skeleton's body and its clips (the locomotion of its clips, which its Character of the physics plugin drives, its gestures, and the modifiers of the intents of animation.request), sets it as its Animation.asset, and says how ready each is. One step of undo.",params=Setup_Params,params_info=type_info_of(Setup_Params),defaults=&defaults,run=setup},Setup_Result,type_info_of(Setup_Result))
}

// What a clip of the library is by the words of its name. Landing enters walking and Jumping enters
// falling; the rest are what a mode plays.
@(private)
Setup_Class :: enum u8 {None,Walking,Landing,Falling,Jumping,Swimming,Flying,Crouching,Sliding}
@(private)
SETUP_CLASS_MODES :: [Setup_Class]string{.None="",.Walking="walking",.Landing="walking",.Falling="falling",.Jumping="falling",.Swimming="swimming",.Flying="flying",.Crouching="crouching",.Sliding="sliding"}
@(private)
Setup_Clip :: struct {name:string,class:Setup_Class,mode:u16,loop:bool,speed,duration:f32,told:bool,rates:[2]f32}
@(private)
Setup_Clips :: struct {all:[dynamic]Setup_Clip,locomotion:[dynamic]Setup_Clip,gestures:[dynamic]string}

// The class of a clip by the words of its name (split at separators, case and digits, so a word
// starts a token: Walk_Fwd, JogStart, MM_Land): land, a fall or air loop, jump or takeoff, swim,
// fly, slide, crouch, and idle, stand, walk, jog, run or sprint. A start, stop, turn or pivot does
// not loop; the start of a slide is the entry of its mode.
@(private)
setup_class :: proc(name:string) -> (class:Setup_Class,loop:bool) {
    words:=make([dynamic]string,context.temp_allocator)
    start:=-1
    for i in 0..=len(name) {
        c:=name[i] if i<len(name) else 0
        letter:=c>='a' && c<='z' || c>='A' && c<='Z';digit:=c>='0' && c<='9'
        if start>=0 && (!letter && !digit || i>start && c>='A' && c<='Z' && name[i-1]>='a' && name[i-1]<='z' || i>start && digit!=(name[i-1]>='0' && name[i-1]<='9')) {
            append(&words,strings.to_lower(name[start:i],context.temp_allocator));start=-1
        }
        if start<0 && (letter || digit) {start=i}
    }
    has :: proc(words:[]string,prefixes:..string) -> bool {
        for word in words {for prefix in prefixes {if strings.has_prefix(word,prefix) {return true}}}
        return false
    }
    loop=!has(words[:],"start","stop","turn","pivot")
    takeoff:=strings.contains(strings.concatenate(words[:],context.temp_allocator),"takeoff")
    switch {
    case has(words[:],"land"): return .Landing,false
    case has(words[:],"fall","air") || has(words[:],"jump") && has(words[:],"loop"): return .Falling,true
    case has(words[:],"jump") || takeoff: return .Jumping,false
    case has(words[:],"swim"): return .Swimming,loop
    case has(words[:],"fly","flight","hover"): return .Flying,loop
    case has(words[:],"slid"): return .Sliding,loop
    case has(words[:],"crouch"): return .Crouching,loop
    case has(words[:],"idle","stand","breath","walk","jog","run","sprint"): return .Walking,loop
    }
    return .None,false
}

// The clips of the library, or those p names, by class and by how fast they travel (measured, or
// told in p.speeds). Without a walking clip by name, loops that stand or travel walk; gestures are
// the clips that stay in place and are none of those. A clip of the library that cannot be sampled
// is left out; one that p names fails.
@(private)
setup_clips :: proc(call:^api.Call,animation:asset.Animation_View,skeleton:asset.Skeleton_View,p:^Setup_Params) -> (clips:Setup_Clips,ok:bool) {
    clips.all=make([dynamic]Setup_Clip,context.temp_allocator)
    clips.locomotion=make([dynamic]Setup_Clip,context.temp_allocator)
    clips.gestures=make([dynamic]string,context.temp_allocator)
    find :: proc(animation:asset.Animation_View,name:string) -> int {
        for &clip,i in animation.clips {if base.text_get(clip.name[:])==name {return i}}
        return -1
    }
    indices:=make([dynamic]int,context.temp_allocator)
    named,_:=api.params_array_count(call,"clips")
    for i in 0..<min(named,SETUP_CLIPS) {
        name:=base.text_get(p.clips[i][:])
        index:=find(animation,name)
        if index<0 {authoring_failure(call,fmt.tprintf("clips[%d]",i),"Missing_Clip","a clip of the library",name,"The library has no clip of that name",fix="Name clips of the library; animation.clip.inspect lists them");return}
        for other in indices {if other==index {authoring_failure(call,fmt.tprintf("clips[%d]",i),"Duplicate","each clip once",name,"The clip is named twice",fix="Name each clip once");return}}
        append(&indices,index)
    }
    if named==0 {for _,i in animation.clips {append(&indices,i)}}
    told,_:=api.params_array_count(call,"speeds")
    told=min(told,len(p.speeds))
    for &value,i in p.speeds[:told] {
        name:=base.text_get(value.clip[:])
        index:=find(animation,name)
        listed:=false
        for other in indices {listed ||= other==index}
        if !listed {authoring_failure(call,fmt.tprintf("speeds[%d].clip",i),"Missing_Clip","a clip of the library that is classified",name,"The speed names a clip that is not classified",fix="Name a clip of the library, and of clips when it is given");return}
        if !(value.speed>0) {authoring_failure(call,fmt.tprintf("speeds[%d].speed",i),"Invalid_Speed","a speed above 0 m/s",fmt.tprintf("%v",value.speed),"A clip travels at a positive speed",fix="Pass the m/s the clip covers, or leave the clip out of speeds to measure it");return}
    }
    rated,_:=api.params_array_count(call,"rates")
    rated=min(rated,len(p.rates))
    for &value,i in p.rates[:rated] {
        name:=base.text_get(value.clip[:])
        index:=find(animation,name)
        listed:=false
        for other in indices {listed ||= other==index}
        if !listed {authoring_failure(call,fmt.tprintf("rates[%d].clip",i),"Missing_Clip","a clip of the library that is classified",name,"The rates name a clip that is not classified",fix="Name a clip of the library, and of clips when it is given");return}
        for &other in p.rates[:i] {if base.text_get(other.clip[:])==name {authoring_failure(call,fmt.tprintf("rates[%d].clip",i),"Duplicate","each clip once",name,"The clip has rates twice",fix="Give each clip its rates once");return}}
        if !(value.min_rate>0) || !(value.min_rate<=value.max_rate) {authoring_failure(call,fmt.tprintf("rates[%d].min_rate",i),"Invalid_Rate","0 < min_rate <= max_rate",fmt.tprintf("min_rate %v, max_rate %v",value.min_rate,value.max_rate),"A clip plays between a positive least and a greater most share of its speed",fix="Pass min_rate above 0 and max_rate at least min_rate; 1 plays the clip at its own speed");return}
    }
    for index in indices {
        clip:=&animation.clips[index]
        name:=base.text_get(clip.name[:])
        sampled,sampled_ok:=clip_sample(call,animation,index,skeleton,30,.Auto)
        if !sampled_ok {
            if named>0 {return}
            call.failed=false;call.error={};continue
        }
        metrics,measured:=clip_measure(sampled.rig,sampled.frames,nil)
        if !measured {
            if named>0 {authoring_failure(call,"clips","Unmeasured","clips that compose on the skeleton",name,"The clip could not be measured",fix="Leave it out of clips");return}
            continue
        }
        class,loop:=setup_class(name)
        value:=Setup_Clip{name=name,class=class,loop=loop,speed=linalg.length(metrics.travel),duration=metrics.duration}
        for &speed in p.speeds[:told] {if base.text_get(speed.clip[:])==name {value.speed,value.told=speed.speed,true}}
        for &rate in p.rates[:rated] {if base.text_get(rate.clip[:])==name {value.rates={rate.min_rate,rate.max_rate}}}
        if class==.None && !sampled.frames.loop {value.loop=false}
        append(&clips.all,value)
    }
    walking:=false
    for value in clips.all {if value.class==.Walking {walking=true}}
    for &value in clips.all {if !walking && value.class==.None && value.loop && (value.speed<.15 || value.speed>=.4) {value.class=.Walking}}
    for value in clips.all {
        has :: proc(name:string,words:[]string) -> bool {
            lower:=strings.to_lower(name,context.temp_allocator)
            for word in words {if strings.contains(lower,word) {return true}}
            return false
        }
        if value.class==.None && value.speed<.3 && value.duration<=8 && !has(value.name,{"death","die","hit","crouch"}) {append(&clips.gestures,value.name)}
    }
    return clips,true
}

// How many blends the params give and, for each, how many clips and samples: the params fill
// fixed arrays and do not say.
@(private)
setup_blend_counts :: proc(call:^api.Call) -> (blends:int,members,samples:[SETUP_BLENDS]int,ok:bool) {
    r:serial.Text_Reader;serial.text_reader_init(&r,call.raw,call.allocator);defer serial.text_reader_destroy(&r)
    elements :: proc(r:^serial.Text_Reader) -> (count:int,ok:bool) {
        serial.text_expect(r,'[') or_return
        if serial.text_accept(r,']') {return 0,true}
        for {
            serial.text_skip(r) or_return
            count+=1
            if !serial.text_accept(r,',') {return count,serial.text_expect(r,']')}
        }
    }
    serial.text_expect(&r,'{') or_return
    if serial.text_accept(&r,'}') {return 0,{},{},true}
    for {
        name:=serial.text_string(&r) or_return
        serial.text_expect(&r,':') or_return
        if name!="blends" {serial.text_skip(&r) or_return} else {
            serial.text_expect(&r,'[') or_return
            for !serial.text_accept(&r,']') {
                if blends>=SETUP_BLENDS {return}
                serial.text_expect(&r,'{') or_return
                for !serial.text_accept(&r,'}') {
                    key:=serial.text_string(&r) or_return
                    serial.text_expect(&r,':') or_return
                    switch key {
                    case "clips": members[blends]=elements(&r) or_return
                    case "samples": samples[blends]=elements(&r) or_return
                    case: serial.text_skip(&r) or_return
                    }
                    if !serial.text_accept(&r,',') {serial.text_expect(&r,'}') or_return;break}
                }
                blends+=1
                if !serial.text_accept(&r,',') {serial.text_expect(&r,']') or_return;break}
            }
        }
        if !serial.text_accept(&r,',') {serial.text_expect(&r,'}') or_return;break}
    }
    return blends,members,samples,true
}

// Whether one of the blends of p mixes the clip named name.
@(private)
setup_blended :: proc(p:^Setup_Params,count:int,members:[SETUP_BLENDS]int,name:string) -> bool {
    for &blend,b in p.blends[:count] {for &clip in blend.clips[:members[b]] {if base.text_get(clip[:])==name {return true}}}
    return false
}

// Names of clips, the first few of a long list: "a, b, c and 12 more".
@(private)
setup_names :: proc(names:[]string,shown:=8) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for name,i in names[:min(len(names),shown)] {if i>0 {strings.write_string(&b,", ")};strings.write_string(&b,name)}
    if len(names)>shown {fmt.sbprintf(&b," and %d more",len(names)-shown)}
    return strings.to_string(b)
}

@(private)
Setup_File :: struct {kind,extension,path:string,id:base.Asset_Id,replaced:bool,doc:asset.Document,bytes:[]u8}

@(private)
setup :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Setup_Params)
    if !authoring_editable(s,call) {return}
    want:=p.want if authoring_field_present(call,"want") else SETUP_ALL
    if (p.entity[0]!=0)==(p.skeleton!={}) {authoring_failure(call,"entity","Exclusive_Reference","exactly one of entity or skeleton","both" if p.entity[0]!=0 else "neither","Setup needs the rig or its skeleton",fix="Pass id of the rig to assign the assets to it, or skeleton with library to only write them");return}
    // With the rig: its skeleton and what it plays. With a skeleton alone, no entity changes.
    w:core.World_Ref;e:core.Entity
    rigged:=p.entity[0]!=0
    skeleton_id:=p.skeleton
    animation:=anim.ANIMATION_DEFAULT
    if rigged {
        ok:bool
        w,e,ok=subject(s,call,p.entity[:]);if !ok {return}
        e=pose_owner(s,w,e)
        skeleton_id=rig_skeleton(s,w,e)
        if skeleton_id=={} {authoring_failure(call,"entity","Missing_Skeleton","an entity that shows a skinned mesh","none","A character needs a skeleton",fix="Pass the id of the rig: the entity with the Mesh_Renderer of a skinned mesh");return}
        if value,present:=editor.entity_get(w,e,anim.Animation);present {animation=value}
    }
    skeleton_file,library_file:Authoring_File;defer asset.asset_close(&skeleton_file.file);defer asset.asset_close(&library_file.file)
    skeleton,opened:=authoring_skeleton_open(s,call,skeleton_id,&skeleton_file);if !opened {return}
    body:=asset.skeleton_body_map(skeleton.bones,skeleton.body,skeleton.body_parts)
    body_source:="stored"
    if skeleton.body==nil {
        detected,found:=asset.skeleton_body_detect(skeleton.bones,lib.body_map_empty(),call.allocator)
        if !found {authoring_failure(call,"skeleton","Invalid_Skeleton","a rest pose that composes","detection failed","The body of the skeleton could not be found");return}
        body,body_source=detected,"detected"
    }
    library:=p.library
    if library=={} {library=animation.library}
    if library=={} && animation.asset!={} {
        source,found:=program_source(s,call,animation.asset);if !found {return}
        library=source
    }
    if library=={} {authoring_failure(call,"library","Required","the .anim with the clips of the character","none","The character has no clips",fix="Pass library: an .anim asset with idle, walk and gesture clips");return}
    clips_view,loaded:=authoring_clip_open(s,call,library,&library_file);if !loaded {return}
    clips,classified:=setup_clips(call,clips_view,skeleton,p);if !classified {return}
    rest:=make([]mm.Transform,len(skeleton.bones),call.allocator)
    parents:=body_parents(skeleton,call.allocator)
    for &bone,i in skeleton.bones {rest[i]={bone.translation,bone.rotation,bone.scale}}
    world:=make([]mm.Transform,len(rest),call.allocator)
    lib.pose_world(parents,rest,world)
    // By its label when the skeleton keeps its body, which the rig then follows.
    bone :: proc(skeleton:asset.Skeleton_View,map_:lib.Body_Map,part:lib.Body_Part) -> anim.Bone_Ref {
        index:=map_.bones[part]
        if index<0 {return {}}
        return anim.bone_ref_part(part) if skeleton.body!=nil else anim.bone_ref(base.text_get(skeleton.bones[index].path[:]))
    }
    mapped :: proc(map_:lib.Body_Map,parts:..lib.Body_Part) -> bool {
        for part in parts {if map_.bones[part]<0 {return false}}
        return true
    }
    Capability :: struct {status:Setup_Status,detail,fix:string}
    capabilities:[Setup_Want]Capability
    for &value,which in capabilities {value.status=.Skipped if which not_in want else .Missing}
    say :: proc(capability:^Capability,status:Setup_Status,detail,fix:string) {capability^={status,detail,fix}}
    up,forward:=body.up,mm.FORWARD
    if !lib.body_up_valid(up) {up={0,1,0}}

    pose:anim.Pose_Profile
    looks:=make([dynamic]anim.Look_Constraint,call.allocator)
    hands:=make([dynamic]anim.IK_Constraint,call.allocator)
    grounding:=make([dynamic]anim.Foot_Grounding,call.allocator)
    if .Look in want {
        if mapped(body,.Head) {
            head:=world[body.bones[.Head]]
            look:=anim.LOOK_CONSTRAINT_DEFAULT
            look.bone=bone(skeleton,body,.Head)
            look.forward=mm.quat_rotate(conj(head.rotation),forward)
            look.up=mm.quat_rotate(conj(head.rotation),up)
            look.world_up,look.use_up=up,true
            look.max_angle=70*mm.RAD_PER_DEG
            look.enabled=false
            append(&looks,look)
            say(&capabilities[.Look],.Ready,"the head turns toward a target, off until asked","")
        } else {say(&capabilities[.Look],.Missing,"the body has no head","Set it with skeleton.body.set")}
    }
    if .Hand_Ik in want {
        count:=0
        for side in 0..<2 {
            parts:=[3]lib.Body_Part{.Shoulder_L,.Elbow_L,.Hand_L} if side==0 else {.Shoulder_R,.Elbow_R,.Hand_R}
            if !mapped(body,..parts[:]) {continue}
            ik:=anim.IK_CONSTRAINT_DEFAULT
            // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
            ik.root=bone(skeleton,body,parts[0])
            ik.joint=bone(skeleton,body,parts[1])
            ik.end=bone(skeleton,body,parts[2])
            // Elbows bend back and down: a pole far behind and below the body.
            ik.pole=-forward*20-up*10
            ik.enabled=false
            append(&hands,ik);count+=1
        }
        switch count {
        case 2: say(&capabilities[.Hand_Ik],.Ready,"each hand reaches a target with its arm, off until asked","")
        case 1: say(&capabilities[.Hand_Ik],.Partial,"one arm of the body is incomplete","Set shoulder, elbow and hand of both arms with skeleton.body.set")
        case: say(&capabilities[.Hand_Ik],.Missing,"the body has no complete arm","Set shoulder, elbow and hand with skeleton.body.set")
        }
    }
    if .Foot_Ik in want {
        feet:=anim.FOOT_GROUNDING_DEFAULT
        feet.body=bone(skeleton,body,.Pelvis);feet.up=up
        feet.max_rise=.15;feet.trace_above=.55;feet.trace_below=.9;feet.blend_time=.08
        for side in 0..<2 {
            parts:=[4]lib.Body_Part{.Hip_L,.Knee_L,.Foot_L,.Toe_L} if side==0 else {.Hip_R,.Knee_R,.Foot_R,.Toe_R}
            if !mapped(body,parts[0],parts[1],parts[2]) {continue}
            leg:=anim.GROUNDED_LEG_DEFAULT
            // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
            leg.hip=bone(skeleton,body,parts[0])
            leg.knee=bone(skeleton,body,parts[1])
            leg.foot=bone(skeleton,body,parts[2])
            leg.contact_bone=bone(skeleton,body,parts[3]) if body.bones[parts[3]]>=0 else leg.foot
            foot:=world[body.bones[parts[2]]]
            leg.foot_up=mm.quat_rotate(conj(foot.rotation),up)
            leg.sole_height=max(0,linalg.dot(foot.position,up))
            if body.bones[parts[3]]>=0 {leg.contact_offset=max(0,linalg.dot(world[body.bones[parts[3]]].position,up))}
            leg.pole_offset={};leg.max_distance=.55;leg.contact_height=.04
            feet.legs[feet.count]=leg;feet.count+=1
        }
        if feet.count>0 && feet.body.path[0]!=0 {
            append(&grounding,feet)
            say(&capabilities[.Foot_Ik],.Ready if feet.count==2 else .Partial,"the feet stand on the ground under them, with physics colliders","" if feet.count==2 else "Set hip, knee and foot of both legs with skeleton.body.set")
        } else {say(&capabilities[.Foot_Ik],.Missing,"the body has no pelvis or complete leg","Set pelvis, hip, knee and foot with skeleton.body.set")}
    }
    pose.look,pose.ik,pose.grounding=looks[:],hands[:],grounding[:]

    // Locomotion: the clips by mode, which the Character of the body drives; the warping stretches
    // the stride of a walk to the speed of the body.
    locomotion:=false
    blend_count:int;blend_members,blend_samples:[SETUP_BLENDS]int
    rates:=[2]f32{anim.MATCH_INFO_DEFAULT.min_rate,anim.MATCH_INFO_DEFAULT.max_rate}
    if .Locomotion in want {
        modes:=locomotion_modes(s.info)
        if len(modes)==0 {locomotion_modes_failure(call,"want");return}
        modeless:=make([dynamic]string,context.temp_allocator)
        for value in clips.all {
            if value.class==.None {continue}
            classes:=SETUP_CLASS_MODES;mode,known:=locomotion_mode_value(modes,classes[value.class])
            if !known {append(&modeless,value.name);continue}
            clip:=value;clip.mode=mode;append(&clips.locomotion,clip)
        }
        if len(clips.locomotion)>anim.MATCH_CLIPS {
            authoring_failure(call,"clips","Capacity",fmt.tprintf("at most %d locomotion clips",anim.MATCH_CLIPS),fmt.tprintf("%d: %s",len(clips.locomotion),setup_locomotion_detail(clips.locomotion[:],modes,3)),"The library has more locomotion clips than a .character takes",fix=fmt.tprintf("Pass clips: the at most %d idle, walk, run, jump, fall, swim or fly clips the character uses, and its gestures",anim.MATCH_CLIPS))
            return
        }
        told,_:=api.params_array_count(call,"speeds")
        for &value,i in p.speeds[:min(told,len(p.speeds))] {
            name:=base.text_get(value.clip[:])
            found:=false
            for clip in clips.locomotion {found ||= clip.name==name}
            if !found {authoring_failure(call,fmt.tprintf("speeds[%d].clip",i),"Not_Locomotion","a locomotion clip",name,"Only the locomotion clips have a speed",fix="Leave it out of speeds, or rename the clip so that its words say how it moves (idle, walk, run, jump, fall, swim, fly)");return}
        }
        rated,_:=api.params_array_count(call,"rates")
        for &value,i in p.rates[:min(rated,len(p.rates))] {
            name:=base.text_get(value.clip[:])
            found:=false
            for clip in clips.locomotion {found ||= clip.name==name}
            if !found {authoring_failure(call,fmt.tprintf("rates[%d].clip",i),"Not_Locomotion","a locomotion clip",name,"Only the locomotion clips have rates",fix="Leave it out of rates, or rename the clip so that its words say how it moves (idle, walk, run, jump, fall, swim, fly)");return}
        }
        counted:bool
        blend_count,blend_members,blend_samples,counted=setup_blend_counts(call)
        if !counted {authoring_failure(call,"blends","Capacity",fmt.tprintf("at most %d blends",SETUP_BLENDS),"more, or not an array","The blends could not be read",fix=fmt.tprintf("Pass at most %d blends, each an object with clips and samples",SETUP_BLENDS));return}
        sampled:=0
        for b in 0..<blend_count {
            blend:=&p.blends[b];path:=fmt.tprintf("blends[%d]",b)
            members:=blend_members[b]
            if members<2 || members>anim.MATCH_BLEND {authoring_failure(call,fmt.tprintf("%s.clips",path),"Blend_Size",fmt.tprintf("2 to %d clips",anim.MATCH_BLEND),fmt.tprintf("%d",members),fmt.tprintf("A blend mixes from 2 to %d clips",anim.MATCH_BLEND),fix=fmt.tprintf("Name 2 to %d looping locomotion clips; a clip alone is a locomotion clip by itself",anim.MATCH_BLEND));return}
            first:Setup_Clip
            for k in 0..<members {
                name:=base.text_get(blend.clips[k][:]);at:=fmt.tprintf("%s.clips[%d]",path,k)
                index:=-1
                for clip,c in clips.locomotion {if clip.name==name {index=c}}
                if index<0 {authoring_failure(call,at,"Not_Locomotion","a looping locomotion clip of the library",name,"A blend mixes locomotion clips",fix="Name a clip whose words say how it moves (idle, walk, run), and that clips names when it is given");return}
                for &other in blend.clips[:k] {if base.text_get(other[:])==name {authoring_failure(call,at,"Duplicate","each clip once",name,"The blend names the clip twice",fix="Name each clip of a blend once");return}}
                clip:=clips.locomotion[index]
                if !clip.loop {authoring_failure(call,at,"Not_Loop","a looping clip",name,"The clips of a blend loop in phase",fix="Make it loop with animation.clip.edit Make_Loop, or leave it out of the blend");return}
                if k==0 {first=clip;continue}
                if clip.mode!=first.mode {authoring_failure(call,at,"Mixed_Modes",fmt.tprintf("a clip of the mode of %s",first.name),name,"The clips of a blend serve one locomotion mode",fix="Blend clips of one mode: idle, walk, jog and run walk; a fall or air loop falls");return}
                if frame:=1/anim.MATCH_INFO_DEFAULT.rate;abs(clip.duration-first.duration)>frame {
                    authoring_failure(call,at,"Unequal_Duration",fmt.tprintf("%.3f s, as %s, within %.3f s",first.duration,first.name,frame),fmt.tprintf("%.3f s",clip.duration),"The clips of a blend last the same and are in phase: the same share of each is the same moment of the step",fix="Blend clips of one duration, or retime one with animation.clip.edit");return
                }
            }
            if blend_samples[b]==0 {authoring_failure(call,fmt.tprintf("%s.samples",path),"Required","at least one sample","none","A blend plays only at its samples",fix="Pass samples, each with eight weights, one per clip of the blend in its order and 0 past them: [1,0,0,0,0,0,0,0] plays the first alone, [0.5,0.5,0,0,0,0,0,0] half and half");return}
            if blend.min_rate!=0 || blend.max_rate!=0 {
                if !(blend.min_rate>0) || !(blend.min_rate<=blend.max_rate) {authoring_failure(call,fmt.tprintf("%s.min_rate",path),"Invalid_Rate","0 < min_rate <= max_rate, or neither",fmt.tprintf("min_rate %v, max_rate %v",blend.min_rate,blend.max_rate),"A blend plays between a positive least and a greater most share of its speed",fix="Pass both min_rate above 0 and max_rate at least min_rate, or leave both out to keep those of the setup");return}
            }
            for sample,i in blend.samples[:blend_samples[b]] {
                at:=fmt.tprintf("%s.samples[%d].weights",path,i)
                sum:f32
                for w,k in sample.weights {
                    if k>=members && w!=0 {authoring_failure(call,fmt.tprintf("%s[%d]",at,k),"Extra_Weight",fmt.tprintf("%d weights, one per clip of the blend",members),fmt.tprintf("%v",w),"The sample weighs a clip the blend does not have",fix="Give a weight to each clip of the blend in its order, and 0 past them");return}
                    sum+=w
                }
                if !(sum>0) {authoring_failure(call,at,"Zero_Weights","weights with a sum above 0","all 0","A sample with no weight plays nothing",fix="Give some clip of the blend a weight above 0");return}
            }
            sampled+=blend_samples[b]
        }
        for &value,i in p.rates[:min(rated,len(p.rates))] {
            if name:=base.text_get(value.clip[:]);setup_blended(p,blend_count,blend_members,name) {authoring_failure(call,fmt.tprintf("rates[%d].clip",i),"Blended","a clip that is no member of a blend",name,"A clip of a blend plays at the rates of its blend",fix="Give min_rate and max_rate to the blend instead");return}
        }
        if sampled>anim.MATCH_SAMPLES {authoring_failure(call,"blends","Capacity",fmt.tprintf("at most %d samples in all",anim.MATCH_SAMPLES),fmt.tprintf("%d",sampled),"The blends have more samples than a .character takes",fix="Sample the blends more coarsely");return}
        if authoring_field_present(call,"min_rate") {rates[0]=p.min_rate}
        if authoring_field_present(call,"max_rate") {rates[1]=p.max_rate}
        if !(rates[0]>0) || !(rates[0]<=rates[1]) {authoring_failure(call,"min_rate","Invalid_Rate","0 < min_rate <= max_rate",fmt.tprintf("min_rate %v, max_rate %v",rates[0],rates[1]),"A clip plays between a positive least and a greater most share of its speed",fix="Pass min_rate above 0 and max_rate at least min_rate; 1 plays a clip at its own speed");return}
        if authoring_field_present(call,"landing_rates") && !(p.landing_rates[0]>0 && p.landing_rates[0]<=p.landing_rates[1]) {
            authoring_failure(call,"landing_rates","Invalid_Rate","0 < landing_rates[0] <= landing_rates[1]",fmt.tprintf("%v",p.landing_rates),"A clip reaches its landing marker between a positive least and a greater most rate",fix="Pass [least, most] with least above 0, as [0.5, 2]");return
        }
        still,moving:=false,false
        for value in clips.locomotion {if value.class==.Walking && value.loop {if value.speed<.15 {still=true} else {moving=true}}}
        detail:=setup_locomotion_detail(clips.locomotion[:],modes)
        if len(modeless)>0 {detail=fmt.tprintf("%s; left out, the project has no mode for them: %s",detail,setup_names(modeless[:]))}
        switch {
        case !mapped(body,.Foot_L,.Foot_R,.Pelvis): say(&capabilities[.Locomotion],.Missing,"the body has no pelvis or feet to match","Set pelvis and feet with skeleton.body.set")
        case !still && !moving: say(&capabilities[.Locomotion],.Missing,"no looping clip stands or walks","Add looping idle and walk clips to the library, or make one loop with animation.clip.edit Make_Loop")
        case:
            locomotion=true
            fix:="" if still && moving else "Add a looping walk clip to the library" if still else "Add a looping idle clip to the library"
            say(&capabilities[.Locomotion],.Ready if fix=="" else .Partial,detail,fix)
        }
    }
    folder:=base.text_get(p.folder[:])
    if folder=="" {
        record,_:=asset.registry_find(&s.app.assets.registry,library)
        folder=strings.clone(record.path,call.allocator)
        if at:=strings.last_index_byte(folder,'/');at>=0 {folder=folder[:at]} else {folder=""}
    }
    name:=base.text_get(p.name[:])
    if name=="" {
        record,_:=asset.registry_find(&s.app.assets.registry,skeleton_id)
        name=record.path
        if at:=strings.last_index_byte(name,'/');at>=0 {name=name[at+1:]}
        if at:=strings.last_index_byte(name,'.');at>0 {name=name[:at]}
        if name=="" {name="character"}
    }
    relative:=fmt.aprintf("%s/%s.character",folder,name,allocator=call.allocator) if folder!="" else fmt.aprintf("%s.character",name,allocator=call.allocator)
    file:=Setup_File{kind="Character",extension=".character",path=editor.scene_file(s,relative,call.allocator)}
    if existing,read:=editor.file_read(s,file.path);read {
        if !p.replace {authoring_failure(call,"replace","Already_Exists","a new file, or replace true",relative,"A previous setup left this file",fix="Pass replace true to overwrite it, or another name or folder");return}
        if header,error:=asset.header_read(existing);error==.None {file.id=header.id}
        file.replaced=true
    }
    if file.id=={} {rng:=base.rng_make(s.id_state~platform.clock_ns());file.id=base.asset_id_random(&rng);s.id_state=rng.state}
    set:=anim.Character_Set{info={animation=library},match={info=anim.MATCH_INFO_DEFAULT},motion={warp=anim.POSE_WARP_PROFILE_DEFAULT},pose=pose}
    if locomotion {
        info:=&set.match.info
        // A loop keeps its phase and a body that does not move stands: searching inside a loop
        // every tick, or walking against a wall, would restart the same frames and freeze the legs.
        info.keep_loop_phase,info.stationary_speed=true,SETUP_STATIONARY_SPEED
        info.min_rate,info.max_rate=rates[0],rates[1]
        if authoring_field_present(call,"trajectory_direction") {info.trajectory_direction=p.trajectory_direction}
        if authoring_field_present(call,"landing_marker") {info.landing_marker=p.landing_marker}
        if authoring_field_present(call,"landing_rates") {info.landing_rates=p.landing_rates}
        sources:=make([dynamic]anim.Match_Source,call.allocator)
        samples:=make([dynamic]anim.Match_Sample,call.allocator)
        for clip in clips.locomotion {
            if setup_blended(p,blend_count,blend_members,clip.name) {continue}
            entry:=clip.class==.Landing || clip.class==.Jumping || clip.class==.Sliding && !clip.loop
            source:=anim.Match_Source{modes=u32(1)<<clip.mode,loop=clip.loop,entry=entry,speed=clip.speed if clip.told else 0,min_rate=clip.rates[0],max_rate=clip.rates[1]};base.text_set(source.clip[:],clip.name)
            append(&sources,source)
        }
        for &blend,b in p.blends[:blend_count] {
            source:=anim.Match_Source{loop=true,min_rate=blend.min_rate,max_rate=blend.max_rate};base.text_set(source.clip[:],base.text_get(blend.clips[0][:]))
            for k in 1..<blend_members[b] {base.text_set(source.blend[k-1][:],base.text_get(blend.clips[k][:]))}
            for clip in clips.locomotion {if clip.name==base.text_get(blend.clips[0][:]) {source.modes=u32(1)<<clip.mode}}
            for sample in blend.samples[:blend_samples[b]] {append(&samples,anim.Match_Sample{source=u32(len(sources)),weights=sample.weights,speed=sample.speed})}
            append(&sources,source)
        }
        set.match.clips,set.match.samples=sources[:],samples[:]
        // The warping turns and stretches the legs of the body toward the velocity of the Character.
        if mapped(body,.Pelvis,.Hip_L,.Knee_L,.Foot_L) || mapped(body,.Pelvis,.Hip_R,.Knee_R,.Foot_R) {
            warp:=&set.motion.warp
            warp.orientation,warp.stride=true,true;warp.max_angle=mm.PI*.4;warp.min_stride,warp.max_stride=.05,1.5
        }
    }
    if .Gestures in want {
        if len(clips.gestures)>SETUP_GESTURES {
            authoring_failure(call,"clips","Capacity",fmt.tprintf("at most %d gestures",SETUP_GESTURES),fmt.tprintf("%d: %s",len(clips.gestures),setup_names(clips.gestures[:])),"The library has more gestures than a .character takes",fix=fmt.tprintf("Pass clips with the locomotion and at most %d gestures the character uses, or leave Gestures out of want",SETUP_GESTURES))
            return
        }
        spine:[16]i32
        count,_:=lib.body_spine(parents,body,spine[:])
        over:anim.Bone_Ref
        if count>0 {over=anim.bone_ref(anim.BODY_LABEL+"upper_body") if skeleton.body!=nil else anim.bone_ref(base.text_get(skeleton.bones[spine[0]].path[:]))}
        if len(clips.gestures)==0 {say(&capabilities[.Gestures],.Missing,"no clip of the library is a gesture","Add gesture clips that stay in place (wave, point, nod)")
        } else if over.path[0]==0 {say(&capabilities[.Gestures],.Missing,"the body has no spine to play gestures over","Set pelvis and neck with skeleton.body.set")
        } else {
            definitions:=make([dynamic]anim.Action_Definition,call.allocator)
            layers:=make([dynamic]anim.Stack_Layer,call.allocator)
            // A layer of the set a gesture plays in: over the upper body or one arm.
            layer :: proc(layers:^[dynamic]anim.Stack_Layer,name:string,over:anim.Bone_Ref) {
                value:=anim.STACK_LAYER_DEFAULT;value.over=over;base.text_set(value.name[:],name)
                append(layers,value)
            }
            define :: proc(definitions:^[dynamic]anim.Action_Definition,name,clip,layer:string) {
                value:=anim.ACTION_DEFINITION_DEFAULT;value.fade_in,value.fade_out=.2,.25
                base.text_set(value.name[:],name);base.text_set(value.clip[:],clip);base.text_set(value.layer[:],layer)
                append(definitions,value)
            }
            arm_l:=bone(skeleton,body,.Clavicle_L) if body.bones[.Clavicle_L]>=0 else bone(skeleton,body,.Shoulder_L)
            arm_r:=bone(skeleton,body,.Clavicle_R) if body.bones[.Clavicle_R]>=0 else bone(skeleton,body,.Shoulder_R)
            if skeleton.body!=nil {
                if arm_l.path[0]!=0 {arm_l=anim.bone_ref(anim.BODY_LABEL+"arm_l")}
                if arm_r.path[0]!=0 {arm_r=anim.bone_ref(anim.BODY_LABEL+"arm_r")}
            }
            layer(&layers,"Upper_Body",over)
            if arm_l.path[0]!=0 {layer(&layers,"Arm_L",arm_l)}
            if arm_r.path[0]!=0 {layer(&layers,"Arm_R",arm_r)}
            for clip in clips.gestures {
                define(&definitions,clip,clip,"Upper_Body")
                if arm_l.path[0]!=0 {define(&definitions,fmt.tprintf("%s Arm_L",clip),clip,"Arm_L")}
                if arm_r.path[0]!=0 {define(&definitions,fmt.tprintf("%s Arm_R",clip),clip,"Arm_R")}
            }
            set.actions={layers=layers[:],actions=definitions[:]}
            say(&capabilities[.Gestures],.Ready,fmt.tprintf("%d gestures over the upper body or one arm",len(clips.gestures)),"")
        }
    }
    if anim.character_document(&file.doc,&s.app.assets.types,file.id,set,call.allocator)!=.None {authoring_failure(call,"clips","Invalid_Character","clips of the library with names shorter than 64 bytes","refused","The .character could not be built",api.SERVER_ERROR);return}
    defer asset.document_destroy(&file.doc)
    bytes:serial.Writer;serial.writer_init(&bytes,4096,call.allocator)
    if asset.document_write(&file.doc,&bytes)!=.None {authoring_failure(call,file.kind,"Serialization","a valid document","refused","The .character could not be serialized",api.SERVER_ERROR);return}
    file.bytes=serial.writer_bytes(&bytes)
    dry_run:=authoring_dry_run(call)
    if !dry_run {
        // One step of undo for the file and the Animation of the rig; without a history only the
        // write.
        gesture:=s.edits!=nil
        if gesture && !editor.api_edit_begin(s,call,"Character setup") {return}
        if !editor.file_write(s,file.path,file.bytes,"Character setup") {
            authoring_failure(call,file.kind,"Write_Error","an asset write",file.path,"The .character could not be written",api.SERVER_ERROR)
            if gesture {editor.api_edit_end(s,call,false)}
            return
        }
        if rigged {
            animation.asset,animation.library=file.id,{}
            if locomotion {
                animation.clip={}
                animation.speed,animation.playing=1,true
                // The Character moves the body: the clips that carry a root play it in place.
                for &clip in clips_view.clips {if clip.root.translation || clip.root.rotation {animation.root_motion=.In_Place;break}}
            }
            core.add(core.world_table_of(w,anim.Animation),e,animation)
            core.world_settle(w)
        }
        if gesture && !editor.api_edit_end(s,call,true) {return}
    }
    out:=call.out
    serial.text_write_raw(out,"{")
    if rigged {api.write_key(out,"id",true);api.write_id(out,editor.api_entity_id(w,e))} else {api.write_key(out,"skeleton",true);serial.write_u8(out,'"');serial.text_write_asset_id(out,p.skeleton);serial.write_u8(out,'"')}
    if dry_run {api.write_bool(out,"dry_run",true)}
    api.write_text(out,"body",body_source)
    api.write_key(out,"assets");serial.text_write_raw(out,"[{")
    api.write_text(out,"kind",file.kind,true);api.write_text(out,"path",file.path)
    api.write_key(out,"asset");serial.write_u8(out,'"');serial.text_write_asset_id(out,file.id);serial.write_u8(out,'"');api.write_bool(out,"replaced",file.replaced);serial.text_write_raw(out,"}]")
    api.write_key(out,"capabilities");serial.text_write_raw(out,"[")
    written:=0
    for &value,which in capabilities {
        if value.status==.Skipped {continue}
        if written>0 {serial.text_write_raw(out,",")};written+=1
        serial.text_write_raw(out,"{");api.write_text(out,"want",fmt.tprintf("%v",which),true);api.write_text(out,"status",fmt.tprintf("%v",value.status))
        api.write_text(out,"detail",value.detail);api.write_text(out,"fix",value.fix);serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,"]")
    api.write_key(out,"clips");serial.text_write_raw(out,`{"locomotion":[`)
    modes:=locomotion_modes(s.info)
    listed:=0
    for clip in clips.locomotion {
        if setup_blended(p,blend_count,blend_members,clip.name) {continue}
        if listed>0 {serial.text_write_raw(out,",")};listed+=1
        mode,_:=locomotion_mode_name(modes,clip.mode)
        serial.text_write_raw(out,"{");api.write_text(out,"clip",clip.name,true);api.write_text(out,"mode",mode)
        api.write_bool(out,"entry",clip.class==.Landing || clip.class==.Jumping || clip.class==.Sliding && !clip.loop);api.write_bool(out,"loop",clip.loop)
        api.write_key(out,"speed");api.write_number(out,clip.speed)
        if clip.told {api.write_bool(out,"told",true)}
        if clip.rates[0]>0 {api.write_numbers(out,"rates",[]f32{clip.rates[0],clip.rates[1]})}
        serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,`],"blends":[`)
    for &blend,b in p.blends[:blend_count] {
        if b>0 {serial.text_write_raw(out,",")}
        serial.text_write_raw(out,`{"clips":[`)
        mode:string
        for k in 0..<blend_members[b] {
            name:=base.text_get(blend.clips[k][:])
            if k>0 {serial.text_write_raw(out,",")}
            serial.text_write_string(out,name)
            for clip in clips.locomotion {if clip.name==name {mode,_=locomotion_mode_name(modes,clip.mode)}}
        }
        serial.text_write_raw(out,"]");api.write_text(out,"mode",mode);api.write_uint(out,"samples",u64(blend_samples[b]))
        if blend.min_rate>0 {api.write_numbers(out,"rates",[]f32{blend.min_rate,blend.max_rate})}
        serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,`],"gestures":[`)
    if .Gestures in want do for gesture,i in clips.gestures {if i>0 {serial.text_write_raw(out,",")};serial.write_u8(out,'"');serial.text_write_raw(out,gesture);serial.write_u8(out,'"')}
    serial.text_write_raw(out,"]}}")
}

// The locomotion modes of the project: the names of Locomotion_Mode, the type of the physics plugin,
// found by its name in the World. Empty without that plugin.
@(private)
locomotion_modes :: proc(info:^core.World_Info) -> []core.Name_Info {
    if info==nil {return nil}
    for &entry in info.named_types {if entry.name=="Locomotion_Mode" {return core.names_of(info,entry.type)}}
    return nil
}
@(private)
locomotion_modes_failure :: proc(call:^api.Call,path:string) {
    authoring_failure(call,path,"Missing_Plugin","the Locomotion_Mode of the physics plugin","none","The project has no locomotion modes for motion matching",fix="Add the physics plugin to the project: its Character tells the .match the mode it moves in; or leave Locomotion out of want")
}
// The value of a mode named name, in any case.
@(private)
locomotion_mode_value :: proc(modes:[]core.Name_Info,name:string) -> (u16,bool) {
    if name=="" {return 0,false}
    for mode in modes {if strings.equal_fold(mode.name,name) && mode.value>=0 && mode.value<=31 {return u16(mode.value),true}}
    return 0,false
}
@(private)
locomotion_mode_name :: proc(modes:[]core.Name_Info,value:u16) -> (string,bool) {
    for mode in modes {if mode.value==i64(value) {return mode.name,true}}
    return "",false
}
@(private)
locomotion_mode_names :: proc(modes:[]core.Name_Info) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for mode in modes {append(&names,mode.name)}
    return fmt.tprintf("Locomotion modes: %s",strings.join(names[:],", ",context.temp_allocator))
}
// The clips of each mode, its entries marked: walking: Idle, Walk; falling: Fall, Jump (entry).
// With shown, the count of each mode and its first clips.
@(private)
setup_locomotion_detail :: proc(clips:[]Setup_Clip,modes:[]core.Name_Info,shown:=max(int)) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for mode in modes {
        count:=0
        for clip in clips {
            if i64(clip.mode)!=mode.value {continue}
            if count==0 {fmt.sbprintf(&b,"%s%s: ","; " if strings.builder_len(b)>0 else "",strings.to_lower(mode.name,context.temp_allocator))}
            count+=1
            if count>shown {continue}
            if count>1 {strings.write_string(&b,", ")}
            fmt.sbprintf(&b,"%s%s",clip.name," (entry)" if clip.class==.Landing || clip.class==.Jumping || clip.class==.Sliding && !clip.loop else "")
        }
        if count>shown {fmt.sbprintf(&b," and %d more",count-shown)}
    }
    return strings.to_string(b)
}
