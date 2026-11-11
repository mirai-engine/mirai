package animation_editor

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import aa "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

// Parts of a definition: Default is the whole of it (the clip of an .anim, the
// bones and sockets of a .skeleton), Track the keys of one track and Body the
// body of a skeleton.
Asset_Section :: enum u8 {Default,Track,Body}
Asset_Inspect_Params :: struct {
    asset:base.Asset_Id,
    section:Asset_Section `mirai:"optional,label=Track: the keys of a track of an .anim; Body: the body parts of a .skeleton"`,
    clip:[64]u8 `mirai:"text,optional,label=.anim: the clip; empty is the first"`,
    target:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=.anim with section Track: the bone path or curve of the track of the clip"`,
    property:lib.Property `mirai:"optional,label=.anim with section Track: its property"`,
    slot:u8 `mirai:"optional,label=.anim with section Track: its slot"`,
    table:Profile_Table `mirai:"optional,label=.character: the table of its modifiers"`,
    offset:u32 `mirai:"optional,label=First row of each long table"`,
    limit:u32 `mirai:"optional,min=1,max=512,clamp,label=Rows of each long table"`,
}
// Parts of an animated instance.
Instance_Part :: enum u8 {Rig,Match,Modifiers,Actions,Motion,Morphs,Pose}
Instance_Parts :: bit_set[Instance_Part]
INSTANCE_PARTS_DEFAULT :: Instance_Parts{.Rig,.Match,.Modifiers,.Actions,.Motion,.Morphs}
POSE_NAMES :: 16
Instance_Inspect_Params :: struct {
    entity:[editor.API_ENTITY_TEXT]u8 `mirai:"text,entity,label=By its name or a path Parent/Child or its id; in Play or Simulate also its handle as scene.inspect with world Game gives it"`,
    parts:Instance_Parts `mirai:"optional,label=Omitted is all of them but Pose, which needs names"`,
    names:[POSE_NAMES][aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=Pose: the bones and sockets to place; a bone by path or name or as a part of the body (@hand_r) and a socket by its name"`,
    offset:u32 `mirai:"optional,label=First bone; rig operation or morph target"`,
    limit:u32 `mirai:"optional,min=1,max=256,clamp"`,
    diagnostics:bool `mirai:"optional,label=Solver and fade details of rig operations and morphs"`,
}

Asset_Inspect_Result :: struct {
    asset:base.Asset_Id,
    path:[1024]u8 `mirai:"text"`,
    clips:[]Asset_Clip_Name `mirai:"optional,label=.anim: every clip"`,
    clip:[aa.ANIMATION_NAME_CAPACITY]u8 `mirai:"text,optional,label=.anim: the clip read"`,
    root:aa.Animation_Root `mirai:"optional,label=.anim: the root motion of the clip"`,
    tracks_total,markers_total:u32 `mirai:"optional,label=.anim: of the clip"`,
    tracks:[]Asset_Clip_Track `mirai:"optional,label=.anim: a page of the tracks of the clip"`,
    markers:[]aa.Animation_Marker `mirai:"optional,label=.anim: a page of the markers of the clip"`,
    target:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=.anim section Track: the bone path or curve of the track"`,
    property:lib.Property `mirai:"optional"`,
    slot:u8 `mirai:"optional"`,
    keys_total:u32 `mirai:"optional"`,
    keys:[]lib.Keyframe `mirai:"optional,label=.anim section Track: a page of the keys"`,
    bones_total,sockets_total:u32 `mirai:"optional,label=.skeleton"`,
    bones:[]Authoring_Bone `mirai:"optional,label=.skeleton: a page of the bones with their rest pose"`,
    sockets:[]aa.Skeleton_Socket `mirai:"optional,label=.skeleton: a page of the sockets; offsets are local"`,
    up:mm.Vec3 `mirai:"optional,label=.skeleton section Body: the up of the body at rest; it faces -Z"`,
    axes_confidence:f32 `mirai:"optional,label=0 to 1: how sure detection was of how the body stands"`,
    parts:[]Body_Part_Result `mirai:"optional,label=.skeleton section Body: each part found"`,
    missing:[]lib.Body_Part `mirai:"optional,label=Parts without a bone"`,
    unassigned_total:u32 `mirai:"optional"`,
    unassigned:[]string `mirai:"optional,label=The first bones outside the body; unassigned_total counts them all"`,
    fix:string `mirai:"optional,label=How to complete or correct the body; empty when it needs nothing"`,
    stored:bool `mirai:"optional,label=Whether the .skeleton holds a body: skeleton.body.detect saves it"`,
    animation:base.Asset_Id `mirai:"optional,label=.character: the .anim of its clips"`,
    match:anim.Match_Info `mirai:"optional,label=.character: its locomotion: the rate of its database, the interval of its searches, the blend of a jump, its memory and weights"`,
    match_clips_total:u32 `mirai:"optional,label=.character"`,
    match_clips:[]Asset_Match_Clip `mirai:"optional,label=.character: a page of its locomotion clips with the Locomotion_Mode each serves"`,
    match_spans:[]anim.Match_Span `mirai:"optional,label=.character: the rules over the rows of its locomotion clips inside the spans of each name"`,
    databases:[]Asset_Match_Database `mirai:"optional,label=.character: the database built for each skeleton a rig played it on"`,
    layers_total,actions_total,sections_total:u32 `mirai:"optional,label=.character"`,
    layers:[]Authoring_Page(anim.Stack_Layer) `mirai:"optional,label=.character: its stack over the base, in order"`,
    actions:[]Authoring_Page(anim.Action_Definition) `mirai:"optional"`,
    sections:[]Authoring_Page(Action_Section_Params) `mirai:"optional"`,
    spaces:[]Asset_Space `mirai:"optional,label=.character: the spaces its layers sample"`,
    warp:anim.Pose_Warp_Profile `mirai:"optional,label=.character: pose warping"`,
    windows_total:u32 `mirai:"optional,label=.character"`,
    windows:[]Authoring_Page(anim.Motion_Window) `mirai:"optional,label=.character: warp windows, each over the spans of its name on the clips"`,
    distances_total:u32 `mirai:"optional,label=.character"`,
    distances:[]Authoring_Page(Motion_Distance_Params) `mirai:"optional,label=.character: distance tracks"`,
    counts:Profile_Counts `mirai:"optional,label=.character: the rows of each table of its modifiers"`,
    table:Profile_Table `mirai:"optional,label=.character: the table read; only its field has rows"`,
    ik:[]Authoring_Page(anim.IK_Constraint) `mirai:"optional"`,
    look:[]Authoring_Page(anim.Look_Constraint) `mirai:"optional"`,
    limits:[]Authoring_Page(anim.Rotation_Constraint) `mirai:"optional"`,
    grounding:[]Authoring_Page(Profile_Grounding_Params) `mirai:"optional"`,
    chain_ik:[]Authoring_Page(Profile_Chain_Params) `mirai:"optional"`,
    twist:[]Authoring_Page(Profile_Twist_Params) `mirai:"optional"`,
    springs:[]Authoring_Page(Profile_Spring_Params) `mirai:"optional"`,
    multi_ik:[]Authoring_Page(Profile_Multi_Params) `mirai:"optional"`,
    retarget_chains:[]Authoring_Page(anim.Chain_Retarget_Constraint) `mirai:"optional"`,
    spline_ik:[]Authoring_Page(Profile_Spline_Params) `mirai:"optional"`,
    correctives:[]Authoring_Page(Profile_Corrective_Params) `mirai:"optional"`,
    follow:[]Authoring_Page(Profile_Follow_Params) `mirai:"optional"`,
    curve_poses:[]Authoring_Page(anim.Curve_Pose) `mirai:"optional"`,
    curve_drives:[]Authoring_Page(anim.Curve_Drive) `mirai:"optional"`,
    curve_materials:[]Authoring_Page(anim.Curve_Material) `mirai:"optional"`,
}
// A space of a .character with its samples.
Asset_Space :: struct {info:anim.Blend_Info,samples:[]Authoring_Page(anim.Blend_Sample) `mirai:"label=Positions in the units of the axes"`}
Asset_Clip_Name :: struct {name:[aa.ANIMATION_NAME_CAPACITY]u8 `mirai:"text"`}
// entry: it starts its modes, searched from its start when the body enters one of them.
Asset_Match_Clip :: struct {
    clip:[64]u8 `mirai:"text"`,animation:base.Asset_Id `mirai:"optional,label=Empty is that of the .character"`,modes:[][32]u8 `mirai:"text"`,loop,entry:bool,
    speed:f32 `mirai:"optional,unit=m/s,label=The speed it travels at, set by hand; omitted is measured"`,
    blend:[][64]u8 `mirai:"text,optional,label=The clips it blends with in phase, at the weights of each sample"`,
    samples:[]Asset_Match_Sample `mirai:"optional,label=A blend: its points the search picks"`,
}
Asset_Match_Sample :: struct {weights:[anim.MATCH_BLEND]f32 `mirai:"label=Of clip, then of each of blend"`,speed:f32 `mirai:"optional,unit=m/s,label=Set by hand; omitted is measured from the blended feet"`}
Asset_Match_Database :: struct {rows:u32,bytes:u64 `mirai:"optional"`,error:lib.Match_Build_Error `mirai:"label=Memory_Limit: it keeps more than memory; Invalid: a bone or clip is missing on the skeleton"`}
Asset_Clip_Track :: struct {target:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text"`,property:lib.Property,slot:u8,keys_total:u32}
// What a part the entity lacks holds instead of its fields.
Instance_Missing :: struct {
    code:[32]u8 `mirai:"text,optional,label=Why the entity lacks the part"`,
    reason:[256]u8 `mirai:"text,optional"`,
}
// Each part asked; one the entity lacks holds only code and reason.
Instance_Inspect_Result :: struct {
    id:base.Entity_Id `mirai:"optional"`,
    entity:[18]u8 `mirai:"text,optional,label=The handle asked"`,
    rig:Instance_Rig `mirai:"optional,label=Clips and bones with their mirror"`,
    match:Instance_Match `mirai:"optional,label=What the motion matching of its .character plays in Play, Simulation or the preview of the editor, the clips it searches and its last search"`,
    modifiers:Instance_Modifiers `mirai:"optional,label=Rig operations and their influence"`,
    actions:Instance_Actions `mirai:"optional"`,
    motion:Instance_Motion `mirai:"optional,label=Warp windows and their targets"`,
    morphs:Instance_Morphs `mirai:"optional,label=Morph targets of the mesh instance"`,
    pose:Instance_Pose `mirai:"optional,label=Where the bones and sockets asked end, from the pose its rig ended its last tick with"`,
}
// The fields of Preview_Match_Result, then the clips of the database of its skeleton and the last
// search matching had to make.
Instance_Match :: struct {
    using missing:Instance_Missing `mirai:"inline"`,
    available:bool `mirai:"optional,label=false when the entity plays no locomotion"`,
    clip:[64]u8 `mirai:"text,optional"`,mode:[32]u8 `mirai:"text,optional"`,forced:bool `mirai:"optional"`,
    time:f32 `mirai:"optional,unit=s"`,rate:f32 `mirai:"optional"`,speed:f32 `mirai:"optional,unit=m/s"`,cost:f32 `mirai:"optional"`,
    searches,jumps:u32 `mirai:"optional"`,
    ranges:[]Instance_Match_Range `mirai:"optional,label=Each clip or blended sample of the database, by its index"`,
    search:Instance_Match_Search `mirai:"optional,label=The last search it had to make: entering a mode, starting, stopping, or leaving a clip that ends"`,
}
// clips: of a blended sample, each clip with its share; travel: where it goes in the space of the
// rig (-Z forward).
Instance_Match_Range :: struct {
    clip:[64]u8 `mirai:"text"`,
    clips:[]Instance_Match_Member `mirai:"optional"`,
    modes:[][32]u8 `mirai:"text"`,
    loop,entry:bool,
    speed:f32 `mirai:"unit=m/s"`,
    travel:mm.Vec3 `mirai:"unit=m/s"`,
    duration:f32 `mirai:"unit=s"`,
}
Instance_Match_Member :: struct {clip:[64]u8 `mirai:"text"`,weight:f32}
Instance_Match_Search :: struct {
    search:u32 `mirai:"label=Which of searches it was"`,
    mode:[32]u8 `mirai:"text"`,
    entry:bool `mirai:"label=It searched the starts of the entry clips of mode"`,
    time_to_land:f32 `mirai:"optional,unit=s,label=It searched the rows that reach their landing marker this many seconds ahead"`,
    candidates:[]Instance_Match_Candidate `mirai:"label=The best row of each clip it could pick, least cost first (the first is the one it chose), then that of each clip it left out with its reason"`,
}
// costs: of each kind of feature by its weight; they sum cost.
Instance_Match_Candidate :: struct {
    range:u32 `mirai:"label=Its index in ranges"`,
    clip:[64]u8 `mirai:"text"`,
    time:f32 `mirai:"unit=s,label=Of the row in its clip"`,
    rate:f32 `mirai:"label=It plays at to follow the trajectory, or to reach its landing marker"`,
    cost:f32,
    costs:Instance_Match_Costs,
    reason:lib.Match_Reject `mirai:"label=None: the one it chose; Cost: it cost more; Mode, Entry, Stationary, Reselect, Event (no landing marker ahead), Window (its marker is not reached at a landing rate, or its rows go back in the arc in the air) and Span (spans of the set exclude or block its rows): why it was left out"`,
}
Instance_Match_Costs :: struct {foot_position,foot_velocity,hip_velocity,body_velocity,trajectory_position,trajectory_direction:f32}
Instance_Pose :: struct {
    using missing:Instance_Missing `mirai:"inline"`,
    skeleton:base.Asset_Id `mirai:"optional"`,
    transforms:[]Instance_Pose_Transform `mirai:"optional,label=One per name asked, in its order"`,
}
Pose_Kind :: enum u8 {Bone,Socket}
Instance_Pose_Transform :: struct {
    name:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,label=As asked"`,
    kind:Pose_Kind,
    bone:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,label=The path of the bone; of a socket, the bone it hangs from"`,
    world:mm.Transform `mirai:"label=In the world, from where the entity is now"`,
    entity:mm.Transform `mirai:"label=In the space of the entity"`,
}
Instance_Rig :: struct {
    using missing:Instance_Missing `mirai:"inline"`,
    clips:[]Instance_Clip `mirai:"optional"`,
    bones_total:u32 `mirai:"optional"`,
    joints:u32 `mirai:"optional,label=Joints of the skinned mesh"`,
    bones:[]Instance_Bone `mirai:"optional,label=A page of the bones"`,
}
Instance_Clip :: struct {name:[aa.ANIMATION_NAME_CAPACITY]u8 `mirai:"text"`,duration:f32 `mirai:"unit=s"`,tracks,markers:u32}
Instance_Bone :: struct {
    index:u32,
    name:[64]u8 `mirai:"text"`,
    path:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text"`,
    parent:i32 `mirai:"label=-1 for a root"`,
    mirror:i32 `mirai:"label=The bone of the other side; itself without one"`,
    position,scale:mm.Vec3,
    rotation:[4]f32 `mirai:"label=Quaternion XYZW"`,
}
Instance_Modifiers :: struct {
    using missing:Instance_Missing `mirai:"inline"`,
    id:base.Entity_Id `mirai:"optional"`,
    character:base.Asset_Id `mirai:"optional,label=The .character of its Animation"`,
    total:u32 `mirai:"optional"`,
    last_request_error:anim.Modifier_Request_Error `mirai:"optional,label=Missing_Operation or Missing_Effector: a goal or control names what the .character lacks; Missing_Target: its target is not found"`,
    modifiers:[]Instance_Modifier `mirai:"optional,label=A page of the operations"`,
}
Instance_Modifier :: struct {
    kind:anim.Modifier_Kind,
    name:[256]u8 `mirai:"text"`,
    weight:f32 `mirai:"label=Effective influence"`,
    enabled:bool,
    alpha,target_alpha:f32 `mirai:"optional,label=With diagnostics: the fade now and where it goes"`,
    requested_enabled:bool `mirai:"optional"`,
    fade_remaining:f32 `mirai:"optional,unit=s"`,
    diagnostic:Modifier_Diagnostic_Result `mirai:"optional,label=With diagnostics: how the solver did"`,
    effectors:[]Modifier_Effector_Result `mirai:"label=Effectors of Multi_IK and controls of Spline_IK"`,
}
Instance_Actions :: struct {
    using missing:Instance_Missing `mirai:"inline"`,
    id:base.Entity_Id `mirai:"optional"`,
    character:base.Asset_Id `mirai:"optional,label=The .character of its Animation"`,
    problems:[]Problem_Result `mirai:"optional,label=What its actions reported; the most recent first"`,
    parameters:[]anim.Stack_Parameter_Info `mirai:"optional,label=What animation.request parameters sets: the weight of each layer and the axes of their spaces"`,
    playing:[]Action_Playing_Result `mirai:"optional,label=The actions playing with their effective weight"`,
    events:[]Action_Event_Result `mirai:"optional,label=What its actions told in this tick"`,
}
Instance_Motion :: struct {
    using missing:Instance_Missing `mirai:"inline"`,
    id:base.Entity_Id `mirai:"optional"`,
    character:base.Asset_Id `mirai:"optional,label=The .character of its Animation"`,
    ready:bool `mirai:"optional"`,
    window:i32 `mirai:"optional,label=The window that warps now; -1 for none"`,
    error:anim.Motion_Error `mirai:"optional"`,
    remaining_error:f32 `mirai:"optional,unit=m,label=How far the root is predicted to end from the target; a collision can keep it from reaching it"`,
    source_velocity:mm.Vec3 `mirai:"optional,unit=m/s"`,
    locomotion:Request_Locomotion `mirai:"optional,label=The locomotion asked"`,
    targets_total:u32 `mirai:"optional"`,
    targets:[]Instance_Motion_Target `mirai:"optional"`,
}
Instance_Motion_Target :: struct {
    name:[32]u8 `mirai:"text"`,
    target:Spatial_Target_Params,
    world_position:mm.Vec3 `mirai:"unit=m,label=Where the target is in the world; only when resolved"`,
    world_rotation:mm.Quat,
    enabled,resolved:bool,
}
Instance_Morphs :: struct {
    using missing:Instance_Missing `mirai:"inline"`,
    id:base.Entity_Id `mirai:"optional"`,
    mesh:base.Asset_Id `mirai:"optional"`,
    source:base.Entity_Id `mirai:"optional,label=The entity whose animation drives the weights"`,
    source_kind:Morph_Source_Kind `mirai:"optional"`,
    path:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=Of the curves of its weights"`,
    total:u32 `mirai:"optional"`,
    targets:[]Morph_Target_Result `mirai:"optional,label=A page of the targets"`,
    diagnostic:Morph_Diagnostic_Result `mirai:"optional,label=With diagnostics"`,
    unresolved:[]Morph_Unresolved_Result `mirai:"optional,label=With diagnostics: weights that name no target"`,
}

@(private)
inspect_register :: proc(s:^editor.Session) {
    asset_defaults:=Asset_Inspect_Params{limit=128}
    instance_defaults:=Instance_Inspect_Params{limit=128}
    editor.api_method_register(s,{params=type_info_of(Asset_Inspect_Params),result=type_info_of(Asset_Inspect_Result),name="animation.asset.inspect",summary="Reads an animation definition: an .anim, a .skeleton or a .character.",defaults=&asset_defaults,flags={.Read_Only},run=asset_inspect})
    editor.api_method_register(s,{params=type_info_of(Instance_Inspect_Params),result=type_info_of(Instance_Inspect_Result),name="animation.inspect",summary="Reads what an animated entity does now, part by part; a part the entity lacks says why instead of failing the call.",defaults=&instance_defaults,flags={.Read_Only},run=instance_inspect})
}


@(private)
asset_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Asset_Inspect_Params)
    if s.app==nil || s.app.assets==nil || !host.assets_scan(s.app.assets) {authoring_failure(call,"asset","Unavailable","an asset registry","unavailable","Assets are unavailable",api.SERVER_ERROR);return}
    record,found:=aa.registry_find(&s.app.assets.registry,p.asset)
    if !found {authoring_failure(call,"asset","Missing_Asset","an animation asset of the registry",fmt.tprintf("%v",p.asset),"The asset does not exist");return}
    r:=api.call_result(call,Asset_Inspect_Result)
    r.asset=p.asset
    page:=p^
    if record.kind!=aa.KIND_ANIMATION || p.section!=.Track {page.limit=min(p.limit,256)}
    switch record.kind {
    case aa.KIND_ANIMATION:
        if p.section==.Track {authoring_track_inspect(s,call,&page,r)} else {authoring_clip_inspect(s,call,&page,r)}
    case aa.KIND_SKELETON:
        if p.section!=.Body {authoring_skeleton_inspect(s,call,&page,r);return}
        file:Authoring_File;defer aa.asset_close(&file.file)
        view,ok:=authoring_skeleton_open(s,call,p.asset,&file);if !ok {return}
        base.text_set(r.path[:],file.path)
        body:=body_fields(call,view,aa.skeleton_body_map(view.bones,view.body,view.body_parts))
        r.up,r.axes_confidence,r.parts,r.missing=body.up,body.axes_confidence,body.parts,body.missing
        r.unassigned_total,r.unassigned,r.fix,r.stored=body.unassigned_total,body.unassigned,body.fix,view.body!=nil
    case anim.CHARACTER_KIND: character_inspect(s,call,&page,r)
    case:
        authoring_failure(call,"asset","Invalid_Kind","an .anim, .skeleton or .character",fmt.tprintf("%v",record.kind),"The asset is not an animation definition",fix="Use asset.list to find animation assets")
    }
}

@(private)
instance_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Instance_Inspect_Params)
    w:=editor.shown_world(s)
    e,ok:=editor.api_call_entity(call,w,p.entity[:],game=s.mode!=.Edit);if !ok {return}
    parts:=p.parts if authoring_field_present(call,"parts") else INSTANCE_PARTS_DEFAULT
    // Names that do not exist fail the call; a rig without a pose says so in its part.
    query:Pose_Query
    if .Pose in parts {query=pose_query(s,call,w,e,&p.names);if call.failed {return}}
    r:=api.call_result(call,Instance_Inspect_Result)
    r.id=editor.api_entity_id(w,e)
    if r.id==0 {base.text_set(r.entity[:],fmt.tprintf("0x%016x",u64(e)))}
    // A part the entity lacks says why; the rest stays.
    missing :: proc(call:^api.Call) -> (m:Instance_Missing) {
        base.text_set(m.code[:],strings.trim(api.json_member(call.error.data,"code"),`"`))
        base.text_set(m.reason[:],call.error.message)
        call.failed,call.error=false,{}
        return
    }
    for part in parts {
        switch part {
        case .Rig: r.rig=instance_rig(s,call,w,e,p);if call.failed {r.rig={missing=missing(call)}}
        case .Match: r.match=instance_match(s,call,w,e);if call.failed {r.match={missing=missing(call)}}
        case .Modifiers: r.modifiers=program_modifier_inspect(s,call,w,e,p);if call.failed {r.modifiers={missing=missing(call)}}
        case .Actions: r.actions=authoring_action_inspect(s,call,w,e);if call.failed {r.actions={missing=missing(call)}}
        case .Motion: r.motion=authoring_motion_inspect(s,call,w,e);if call.failed {r.motion={missing=missing(call)}}
        case .Morphs: r.morphs=morph_inspect(s,call,w,e,p);if call.failed {r.morphs={missing=missing(call)}}
        case .Pose: r.pose=instance_pose(call,w,e,&query);if call.failed {r.pose={missing=missing(call)}}
        }
    }
}

// What the motion matching of an entity plays, the clips of its database and its last search.
@(private)
instance_match :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity) -> (r:Instance_Match) {
    value,present:=editor.entity_get(world,entity,anim.Animation)
    if !present {authoring_failure(call,"entity","Missing_Component","an Animation component","missing component","The entity has no Animation component");return}
    if anim.animation_character(s.app.assets,value)=={} {authoring_failure(call,"entity","Not_Matching","an Animation.asset that is a .character with locomotion","another asset","The entity plays no motion matching",fix="Make one with animation.character.setup");return}
    result,matching:=preview_match(world,s.app,entity)
    if !matching {authoring_failure(call,"entity","Not_Running","locomotion the world plays","not sampled or without locomotion clips","Matching runs in Play, Simulation, the preview of the editor or animation.preview, for a .character with locomotion clips");return}
    authoring_struct_fields(&r,result)
    playback:=core.world_storage_of(world,anim.Playback)
    state:^anim.Playing;for &playing in playback.states {if playing.entity==entity {state=&playing;break}}
    shared:=core.world_ref(s.app.shared,world.info,.Shared)
    library:=anim.animation_playing_content(core.world_storage_of(shared,anim.Source_Assets),s.app,state)
    db:=anim.animation_match_database(core.world_storage_of(shared,anim.Character_Assets),library,state)
    if db==nil {return}
    modes:=locomotion_modes(world.info)
    r.ranges=make([]Instance_Match_Range,len(db.ranges),call.allocator)
    for &row,i in r.ranges {
        range:=&db.ranges[i]
        row={clip=anim.source_clip_label(library,range.clips[0]),modes=match_modes(call,modes,range.modes),loop=range.loop,entry=range.entry,speed=range.speed,travel=range.travel,duration=f32(max(range.count-1,0))/range.rate}
        if range.weights=={0=1} {continue}
        members:=make([dynamic]Instance_Match_Member,call.allocator)
        for clip,k in range.clips {if range.weights[k]>0 {append(&members,Instance_Match_Member{clip=anim.source_clip_label(library,clip),weight=range.weights[k]})}}
        row.clips=members[:]
    }
    searched:=&state.program.match.searched
    if searched.search==0 {return}
    mode:=u16(intrinsics.count_trailing_zeros(searched.request.modes))
    name,named:=locomotion_mode_name(modes,mode)
    r.search={search=u32(searched.search),entry=searched.request.entry}
    base.text_set(r.search.mode[:],name if named else fmt.tprintf("%d",mode))
    if searched.request.event>0 {r.search.time_to_land=searched.request.event}
    candidates:=make([dynamic]Instance_Match_Candidate,call.allocator)
    noted:=anim.match_searched_candidates(db,searched^)
    for &candidate in noted.items[:clamp(noted.count,0,lib.MATCH_CANDIDATES)] {
        index:=lib.match_range_of(db,int(candidate.row));if index<0 {continue}
        range:=db.ranges[index];c:=candidate.costs
        append(&candidates,Instance_Match_Candidate{
            range=u32(index),clip=anim.source_clip_label(library,range.clips[0]),time=f32(int(candidate.row)-int(range.first))/range.rate,rate=candidate.rate,cost=candidate.cost,reason=candidate.reason,
            costs={c[.Foot_Position],c[.Foot_Velocity],c[.Hip_Velocity],c[.Body_Velocity],c[.Trajectory_Position],c[.Trajectory_Direction]},
        })
    }
    r.search.candidates=candidates[:]
    return
}

// The names of the locomotion modes of bits.
@(private)
match_modes :: proc(call:^api.Call,modes:[]core.Name_Info,bits:u32) -> [][32]u8 {
    names:=make([dynamic][32]u8,call.allocator)
    for bit in u16(0)..<32 {
        if bits&(u32(1)<<bit)==0 {continue}
        name,named:=locomotion_mode_name(modes,bit)
        text:[32]u8
        base.text_set(text[:],name if named else fmt.tprintf("%d",bit))
        append(&names,text)
    }
    return names[:]
}
