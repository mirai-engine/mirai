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
import "mirai:std/serial"
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
    table:Profile_Table `mirai:"optional,label=.pose: the table"`,
    offset:u32 `mirai:"optional,label=First row of each long table"`,
    limit:u32 `mirai:"optional,min=1,max=512,clamp,label=Rows of each long table"`,
}
// Parts of an animated instance.
Instance_Part :: enum u8 {Rig,Match,Modifiers,Actions,Motion,Morphs,Pose}
Instance_Parts :: bit_set[Instance_Part]
INSTANCE_PARTS_DEFAULT :: Instance_Parts{.Rig,.Match,.Modifiers,.Actions,.Motion,.Morphs}
POSE_NAMES :: 16
Instance_Inspect_Params :: struct {
    entity:[editor.API_ENTITY_TEXT]u8 `mirai:"text,entity,label=By its name or a path Parent/Child or its id; in Play or Simulate also its handle as play.inspect gives it"`,
    parts:Instance_Parts `mirai:"optional,label=Omitted is all of them but Pose, which needs names"`,
    names:[POSE_NAMES][aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=Pose: the bones and sockets to place; a bone by path or name or as a part of the body (@hand_r) and a socket by its name"`,
    offset:u32 `mirai:"optional,label=First bone; rig operation or morph target"`,
    limit:u32 `mirai:"optional,min=1,max=256,clamp"`,
    diagnostics:bool `mirai:"optional,label=Solver and fade details of rig operations and morphs"`,
}

Asset_Inspect_Result :: struct {
    asset:base.Asset_Id,
    path:[1024]u8 `mirai:"text"`,
    clips:[1]Asset_Clip_Name `mirai:"list,optional,label=.anim: every clip"`,
    clip:[aa.ANIMATION_NAME_CAPACITY]u8 `mirai:"text,optional,label=.anim: the clip read"`,
    root:aa.Animation_Root `mirai:"optional,label=.anim: the root motion of the clip"`,
    tracks_total,markers_total:u32 `mirai:"optional,label=.anim: of the clip"`,
    tracks:[1]Asset_Clip_Track `mirai:"list,optional,label=.anim: a page of the tracks of the clip"`,
    markers:[1]aa.Animation_Marker `mirai:"list,optional,label=.anim: a page of the markers of the clip"`,
    target:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=.anim section Track: the bone path or curve of the track"`,
    property:lib.Property `mirai:"optional"`,
    slot:u8 `mirai:"optional"`,
    keys_total:u32 `mirai:"optional"`,
    keys:[1]lib.Keyframe `mirai:"list,optional,label=.anim section Track: a page of the keys"`,
    bones_total,sockets_total:u32 `mirai:"optional,label=.skeleton"`,
    bones:[1]Authoring_Bone `mirai:"list,optional,label=.skeleton: a page of the bones with their rest pose"`,
    sockets:[1]aa.Skeleton_Socket `mirai:"list,optional,label=.skeleton: a page of the sockets; offsets are local"`,
    up:mm.Vec3 `mirai:"optional,label=.skeleton section Body: the up of the body at rest; it faces -Z"`,
    axes_confidence:f32 `mirai:"optional,label=0 to 1: how sure detection was of how the body stands"`,
    parts:[1]Body_Part_Result `mirai:"list,optional,label=.skeleton section Body: each part found"`,
    missing:[1]lib.Body_Part `mirai:"list,optional,label=Parts without a bone"`,
    unassigned_total:u32 `mirai:"optional"`,
    unassigned:[1][aa.NODE_PATH_CAPACITY]u8 `mirai:"text,list,optional,label=The first bones outside the body; unassigned_total counts them all"`,
    fix:[256]u8 `mirai:"text,optional,label=How to complete or correct the body; empty when it needs nothing"`,
    stored:bool `mirai:"optional,label=Whether the .skeleton holds a body: skeleton.body.detect saves it"`,
    counts:Profile_Counts `mirai:"optional,label=.pose: the rows of each table"`,
    table:Profile_Table `mirai:"optional,label=.pose: the table read; only its field has rows"`,
    ik:[1]Authoring_Page(anim.IK_Constraint) `mirai:"list,optional"`,
    look:[1]Authoring_Page(anim.Look_Constraint) `mirai:"list,optional"`,
    limits:[1]Authoring_Page(anim.Rotation_Constraint) `mirai:"list,optional"`,
    contacts:[1]Authoring_Page(anim.Foot_Contact_Constraint) `mirai:"list,optional"`,
    grounding:[1]Authoring_Page(Profile_Grounding_Params) `mirai:"list,optional"`,
    retarget:[1]Authoring_Page(anim.Retarget_Mapping) `mirai:"list,optional"`,
    chain_ik:[1]Authoring_Page(Profile_Chain_Params) `mirai:"list,optional"`,
    twist:[1]Authoring_Page(Profile_Twist_Params) `mirai:"list,optional"`,
    springs:[1]Authoring_Page(Profile_Spring_Params) `mirai:"list,optional"`,
    multi_ik:[1]Authoring_Page(Profile_Multi_Params) `mirai:"list,optional"`,
    retarget_chains:[1]Authoring_Page(anim.Chain_Retarget_Constraint) `mirai:"list,optional"`,
    spline_ik:[1]Authoring_Page(Profile_Spline_Params) `mirai:"list,optional"`,
    correctives:[1]Authoring_Page(Profile_Corrective_Params) `mirai:"list,optional"`,
    follow:[1]Authoring_Page(Profile_Follow_Params) `mirai:"list,optional"`,
    curve_poses:[1]Authoring_Page(anim.Curve_Pose) `mirai:"list,optional"`,
    curve_drives:[1]Authoring_Page(anim.Curve_Drive) `mirai:"list,optional"`,
    curve_materials:[1]Authoring_Page(anim.Curve_Material) `mirai:"list,optional"`,
    info:anim.Blend_Info `mirai:"optional,label=.blend: its axes and source animation"`,
    samples_total,segments_total,triangles_total:u32 `mirai:"optional,label=.blend"`,
    samples:[1]Authoring_Page(anim.Blend_Sample) `mirai:"list,optional,label=.blend: positions in the units of the axes"`,
    segments:[1]Authoring_Page(lib.Blend_Segment) `mirai:"list,optional,label=.blend of one axis: prepared from the samples"`,
    triangles:[1]Authoring_Page(lib.Blend_Triangle) `mirai:"list,optional,label=.blend of two axes: prepared from the samples"`,
    match:anim.Match_Info `mirai:"optional,label=.match: its source .anim, the rate of its database, the interval of its searches, the blend of a jump, its memory, bones and weights"`,
    match_clips_total:u32 `mirai:"optional,label=.match"`,
    match_clips:[1]Asset_Match_Clip `mirai:"list,optional,label=.match: a page of its clips with the Locomotion_Mode each serves"`,
    databases:[1]Asset_Match_Database `mirai:"list,optional,label=.match: the database built for each skeleton a rig played it on"`,
    animation:base.Asset_Id `mirai:"optional,label=.agraph and .action: the source .anim"`,
    output:[64]u8 `mirai:"text,optional,label=.agraph: the output node"`,
    nodes_total,parameters_total,masks_total,mask_bones_total:u32 `mirai:"optional,label=.agraph"`,
    nodes:[1]Authoring_Page(Program_Graph_Node) `mirai:"list,optional"`,
    parameters:[1]Authoring_Page(anim.Graph_Parameter) `mirai:"list,optional"`,
    masks:[1]Authoring_Page(Program_Graph_Mask) `mirai:"list,optional"`,
    mask_bones:[1]Authoring_Page(Program_Graph_Mask_Bone) `mirai:"list,optional"`,
    pose:Motion_Pose_Params `mirai:"optional,label=.motion: pose warping"`,
    windows_total:u32 `mirai:"optional,label=.motion and .action"`,
    windows:[1]Authoring_Page(Asset_Window) `mirai:"list,optional,label=.motion: warp windows; .action: gameplay windows"`,
    distances_total:u32 `mirai:"optional,label=.motion"`,
    distances:[1]Authoring_Page(Motion_Distance_Params) `mirai:"list,optional,label=.motion: distance tracks"`,
    actions_total,sections_total:u32 `mirai:"optional,label=.action"`,
    actions:[1]Authoring_Page(anim.Action_Definition) `mirai:"list,optional"`,
    sections:[1]Authoring_Page(Action_Section_Params) `mirai:"list,optional"`,
}
Asset_Clip_Name :: struct {name:[aa.ANIMATION_NAME_CAPACITY]u8 `mirai:"text"`}
// entry: it starts its modes, searched from its start when the body enters one of them.
Asset_Match_Clip :: struct {
    clip:[64]u8 `mirai:"text"`,animation:base.Asset_Id `mirai:"optional,label=Empty is that of the .match"`,modes:[1][32]u8 `mirai:"text,list"`,loop,entry:bool,
    speed:f32 `mirai:"optional,unit=m/s,label=The speed it travels at, set by hand; omitted is measured"`,
    blend:[1][64]u8 `mirai:"text,list,optional,label=The clips it blends with in phase, at the weights of each sample"`,
    samples:[1]Asset_Match_Sample `mirai:"list,optional,label=A blend: its points the search picks"`,
}
Asset_Match_Sample :: struct {weights:[anim.MATCH_BLEND]f32 `mirai:"label=Of clip, then of each of blend"`,speed:f32 `mirai:"optional,unit=m/s,label=Set by hand; omitted is measured from the blended feet"`}
Asset_Match_Database :: struct {rows:u32,bytes:u64 `mirai:"optional"`,error:lib.Match_Build_Error `mirai:"label=Memory_Limit: it keeps more than memory; Invalid: a bone or clip is missing on the skeleton"`}
Asset_Clip_Track :: struct {target:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text"`,property:lib.Property,slot:u8,keys_total:u32}
// A warp window of a .motion or a gameplay window of an .action.
Asset_Window :: struct {
    name:[64]u8 `mirai:"text"`,
    start,end:f32 `mirai:"unit=s"`,
    action:[64]u8 `mirai:"text,optional,label=.action: its action"`,
    clip:[64]u8 `mirai:"text,optional,label=.motion: its source clip"`,
    translation,rotation:bool `mirai:"optional,label=.motion: what it warps"`,
    axes:[3]bool `mirai:"optional"`,
    weight:f32 `mirai:"optional"`,
    animation:base.Asset_Id `mirai:"optional"`,
}

// Each part asked; one the entity lacks holds only available, code and reason.
Instance_Inspect_Result :: struct {
    id:base.Entity_Id `mirai:"optional"`,
    entity:[18]u8 `mirai:"text,optional,label=The handle asked"`,
    rig:Instance_Rig `mirai:"optional,label=Clips and bones with their mirror"`,
    match:Instance_Match `mirai:"optional,label=What the motion matching of its .match plays in Play, Simulation or the preview of the editor, the clips it searches and its last search"`,
    modifiers:Instance_Modifiers `mirai:"optional,label=Rig operations and their influence"`,
    actions:Instance_Actions `mirai:"optional"`,
    motion:Instance_Motion `mirai:"optional,label=Warp windows and their targets"`,
    morphs:Instance_Morphs `mirai:"optional,label=Morph targets of the mesh instance"`,
    pose:Instance_Pose `mirai:"optional,label=Where the bones and sockets asked end, from the pose its rig ended its last tick with"`,
}
// The fields of Preview_Match_Result, then the clips of the database of its skeleton and the last
// search matching had to make.
Instance_Match :: struct {
    available:bool `mirai:"optional,label=false when the entity plays no .match"`,
    code:[32]u8 `mirai:"text,optional"`,
    reason:[256]u8 `mirai:"text,optional"`,
    clip:[64]u8 `mirai:"text,optional"`,mode:[32]u8 `mirai:"text,optional"`,forced:bool `mirai:"optional"`,
    time:f32 `mirai:"optional,unit=s"`,rate:f32 `mirai:"optional"`,speed:f32 `mirai:"optional,unit=m/s"`,cost:f32 `mirai:"optional"`,
    searches,jumps:u32 `mirai:"optional"`,
    ranges:[1]Instance_Match_Range `mirai:"list,optional,label=Each clip or blended sample of the database, by its index"`,
    search:Instance_Match_Search `mirai:"optional,label=The last search it had to make: entering a mode, starting, stopping, or leaving a clip that ends"`,
}
// clips: of a blended sample, each clip with its share; travel: where it goes in the space of the
// rig (-Z forward).
Instance_Match_Range :: struct {
    clip:[64]u8 `mirai:"text"`,
    clips:[1]Instance_Match_Member `mirai:"list,optional"`,
    modes:[1][32]u8 `mirai:"text,list"`,
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
    candidates:[1]Instance_Match_Candidate `mirai:"list,label=The best row of each clip it could pick, least cost first (the first is the one it chose), then that of each clip it left out with its reason"`,
}
// costs: of each kind of feature by its weight; they sum cost.
Instance_Match_Candidate :: struct {
    range:u32 `mirai:"label=Its index in ranges"`,
    clip:[64]u8 `mirai:"text"`,
    time:f32 `mirai:"unit=s,label=Of the row in its clip"`,
    rate:f32 `mirai:"label=It plays at to follow the trajectory, or to reach its landing marker"`,
    cost:f32,
    costs:Instance_Match_Costs,
    reason:lib.Match_Reject `mirai:"label=None: the one it chose; Cost: it cost more; Mode, Entry, Stationary, Reselect, Event (no landing marker ahead) and Window (its marker is not reached at a landing rate, or its rows go back in the arc in the air): why it was left out"`,
}
Instance_Match_Costs :: struct {foot_position,foot_velocity,hip_velocity,body_velocity,trajectory_position,trajectory_direction:f32}
Instance_Pose :: struct {
    available:bool `mirai:"optional,label=false when the entity lacks the part"`,
    code:[32]u8 `mirai:"text,optional"`,
    reason:[256]u8 `mirai:"text,optional"`,
    skeleton:base.Asset_Id `mirai:"optional"`,
    transforms:[1]Instance_Pose_Transform `mirai:"list,optional,label=One per name asked, in its order"`,
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
    available:bool `mirai:"optional,label=false when the entity lacks the part"`,
    code:[32]u8 `mirai:"text,optional"`,
    reason:[256]u8 `mirai:"text,optional"`,
    clips:[1]Instance_Clip `mirai:"list,optional"`,
    bones_total:u32 `mirai:"optional"`,
    joints:u32 `mirai:"optional,label=Joints of the skinned mesh"`,
    bones:[1]Instance_Bone `mirai:"list,optional,label=A page of the bones"`,
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
    available:bool `mirai:"optional,label=false when the entity lacks the part"`,
    code:[32]u8 `mirai:"text,optional"`,
    reason:[256]u8 `mirai:"text,optional"`,
    id:base.Entity_Id `mirai:"optional"`,
    profile:base.Asset_Id `mirai:"optional,label=Pose_Modifiers.profile"`,
    retarget_profile:base.Asset_Id `mirai:"optional,label=Animation.retarget: it holds the Chain_Retarget operations"`,
    total:u32 `mirai:"optional"`,
    last_request_error:anim.Modifier_Request_Error `mirai:"optional,label=Missing_Operation or Missing_Effector: a goal or control names what the profile lacks; Missing_Target: its target is not found"`,
    modifiers:[1]Instance_Modifier `mirai:"list,optional,label=A page of the operations"`,
}
Instance_Modifier :: struct {
    kind:anim.Modifier_Kind,
    name:[256]u8 `mirai:"text"`,
    profile:base.Asset_Id,
    
    weight:f32 `mirai:"label=Effective influence"`,
    enabled:bool,
    alpha,target_alpha:f32 `mirai:"optional,label=With diagnostics: the fade now and where it goes"`,
    requested_enabled:bool `mirai:"optional"`,
    fade_remaining:f32 `mirai:"optional,unit=s"`,
    diagnostic:Modifier_Diagnostic_Result `mirai:"optional,label=With diagnostics: how the solver did"`,
    effectors:[1]Modifier_Effector_Result `mirai:"list,label=Effectors of Multi_IK and controls of Spline_IK"`,
}
Instance_Actions :: struct {
    available:bool `mirai:"optional,label=false when the entity lacks the part"`,
    code:[32]u8 `mirai:"text,optional"`,
    reason:[256]u8 `mirai:"text,optional"`,
    id:base.Entity_Id `mirai:"optional"`,
    profile:base.Asset_Id `mirai:"optional,label=Animation.actions"`,
    problems:[1]Problem_Result `mirai:"list,optional,label=What its actions reported; the most recent first"`,
    playing:[1]Action_Playing_Result `mirai:"list,optional,label=The actions playing with their effective weight"`,
    events:[1]Action_Event_Result `mirai:"list,optional,label=The events of this tick"`,
}
Instance_Motion :: struct {
    available:bool `mirai:"optional,label=false when the entity lacks the part"`,
    code:[32]u8 `mirai:"text,optional"`,
    reason:[256]u8 `mirai:"text,optional"`,
    id:base.Entity_Id `mirai:"optional"`,
    profile:base.Asset_Id `mirai:"optional"`,
    ready:bool `mirai:"optional"`,
    window:i32 `mirai:"optional,label=The window that warps now; -1 for none"`,
    error:anim.Motion_Error `mirai:"optional"`,
    remaining_error:f32 `mirai:"optional,unit=m,label=How far the root is predicted to end from the target; a collision can keep it from reaching it"`,
    source_velocity:mm.Vec3 `mirai:"optional,unit=m/s"`,
    locomotion:Request_Locomotion `mirai:"optional,label=The locomotion asked"`,
    targets_total:u32 `mirai:"optional"`,
    targets:[1]Instance_Motion_Target `mirai:"list,optional"`,
}
Instance_Motion_Target :: struct {
    name:[32]u8 `mirai:"text"`,
    target:Spatial_Target_Params,
    world_position:mm.Vec3 `mirai:"unit=m,label=Where the target is in the world; only when resolved"`,
    world_rotation:mm.Quat,
    enabled,resolved:bool,
}
Instance_Morphs :: struct {
    available:bool `mirai:"optional,label=false when the entity lacks the part"`,
    code:[32]u8 `mirai:"text,optional"`,
    reason:[256]u8 `mirai:"text,optional"`,
    id:base.Entity_Id `mirai:"optional"`,
    mesh:base.Asset_Id `mirai:"optional"`,
    source:base.Entity_Id `mirai:"optional,label=The entity whose animation drives the weights"`,
    source_kind:Morph_Source_Kind `mirai:"optional"`,
    path:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=Of the curves of its weights"`,
    total:u32 `mirai:"optional"`,
    targets:[1]Morph_Target_Result `mirai:"list,optional,label=A page of the targets"`,
    diagnostic:Morph_Diagnostic_Result `mirai:"optional,label=With diagnostics"`,
    unresolved:[1]Morph_Unresolved_Result `mirai:"list,optional,label=With diagnostics: weights that name no target"`,
}

@(private)
inspect_register :: proc(s:^editor.Session) {
    asset_defaults:=Asset_Inspect_Params{limit=128}
    instance_defaults:=Instance_Inspect_Params{limit=128}
    editor.api_method_register(s,Asset_Inspect_Params,Asset_Inspect_Result,{name="animation.asset.inspect",summary="Reads an animation definition: an .anim, .skeleton, .pose, .blend, .match, .agraph, .motion or .action.",defaults=&asset_defaults,flags={.Read_Only},run=asset_inspect,writes_result=true})
    editor.api_method_register(s,Instance_Inspect_Params,Instance_Inspect_Result,{name="animation.inspect",summary="Reads what an animated entity does now, part by part; a part the entity lacks says why instead of failing the call.",defaults=&instance_defaults,flags={.Read_Only},run=instance_inspect,writes_result=true})
}

// Runs a handler with params of its own, in the call.
@(private)
inspect_with :: proc(s:^editor.Session,call:^api.Call,params:^$T,run:proc(s:^editor.Session,call:^api.Call)) {
    saved,method:=call.params,call.method
    inner:api.Method
    if method!=nil {inner=method^}
    inner.params_id=T
    call.params,call.method=params,&inner
    run(s,call)
    call.params,call.method=saved,method
}

@(private)
asset_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Asset_Inspect_Params)
    if s.app==nil || s.app.assets==nil || !host.assets_scan(s.app.assets) {authoring_failure(call,"asset","Unavailable","an asset registry","unavailable","Assets are unavailable",api.SERVER_ERROR);return}
    record,found:=aa.registry_find(&s.app.assets.registry,p.asset)
    if !found {authoring_failure(call,"asset","Missing_Asset","an animation asset of the registry",fmt.tprintf("%v",p.asset),"The asset does not exist");return}
    limit:=min(p.limit,256)
    switch record.kind {
    case aa.KIND_ANIMATION:
        if p.section==.Track {inner:=Track_Inspect_Params{asset=p.asset,clip=p.clip,target=p.target,property=p.property,slot=p.slot,offset=p.offset,limit=p.limit};inspect_with(s,call,&inner,authoring_track_inspect);return}
        inner:=Clip_Inspect_Params{asset=p.asset,clip=p.clip,offset=p.offset,limit=limit};inspect_with(s,call,&inner,authoring_clip_inspect)
    case aa.KIND_SKELETON:
        if p.section==.Body {
            file:Authoring_File;defer aa.asset_close(&file.file)
            view,ok:=authoring_skeleton_open(s,call,p.asset,&file);if !ok {return}
            serial.text_write_raw(call.out,"{");authoring_result(call,p.asset,file.path)
            body_write(call,view,aa.skeleton_body_map(view.bones,view.body,view.body_parts))
            api.write_bool(call.out,"stored",view.body!=nil)
            serial.text_write_raw(call.out,"}")
            return
        }
        inner:=Authoring_Inspect_Params{asset=p.asset,offset=p.offset,limit=limit};inspect_with(s,call,&inner,authoring_skeleton_inspect)
    case anim.POSE_KIND:
        inner:=Profile_Inspect_Params{asset=p.asset,table=p.table,offset=p.offset,limit=limit};inspect_with(s,call,&inner,authoring_profile_inspect)
    case anim.BLEND_KIND:
        inner:=Authoring_Inspect_Params{asset=p.asset,offset=p.offset,limit=limit};inspect_with(s,call,&inner,program_blend_inspect)
    case anim.MATCH_KIND:
        match_inspect(s,call,p.asset,p.offset,limit)
    case anim.GRAPH_KIND:
        inner:=Authoring_Inspect_Params{asset=p.asset,offset=p.offset,limit=limit};inspect_with(s,call,&inner,program_graph_inspect)
    case anim.MOTION_KIND:
        inner:=Authoring_Inspect_Params{asset=p.asset,offset=p.offset,limit=limit};inspect_with(s,call,&inner,authoring_motion_profile_inspect)
    case anim.ACTION_KIND:
        inner:=Authoring_Inspect_Params{asset=p.asset,offset=p.offset,limit=limit};inspect_with(s,call,&inner,authoring_action_profile_inspect)
    case:
        authoring_failure(call,"asset","Invalid_Kind","an .anim, .skeleton, .pose, .blend, .match, .agraph, .motion or .action",fmt.tprintf("%v",record.kind),"The asset is not an animation definition",fix="Use asset.list to find animation assets")
    }
}

@(private)
instance_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Instance_Inspect_Params)
    w:=editor.shown_world(s)
    e,ok:=editor.api_call_entity(call,w,p.entity[:],game=s.mode!=.Edit);if !ok {return}
    id:=editor.api_entity_id(w,e)
    parts:=p.parts if authoring_field_present(call,"parts") else INSTANCE_PARTS_DEFAULT
    // Names that do not exist fail the call; a rig without a pose says so in its part.
    query:Pose_Query
    if .Pose in parts {query=pose_query(s,call,w,e,&p.names);if call.failed {return}}
    out:=call.out
    serial.text_write_raw(out,"{");api.write_key(out,"id",true);api.write_id(out,id)
    if id==0 {api.write_text(out,"entity",fmt.tprintf("0x%016x",u64(e)))}
    for part in parts {
        api.write_key(out,strings.to_lower(fmt.tprintf("%v",part),call.allocator))
        mark:=out.count
        switch part {
        case .Rig: inner:=Describe_Params{handle=e,offset=p.offset,limit=p.limit};inspect_with(s,call,&inner,describe)
        case .Match: instance_match(s,call,w,e)
        case .Modifiers: inner:=Modifier_Inspect_Params{handle=e,offset=p.offset,limit=p.limit,diagnostics=p.diagnostics};inspect_with(s,call,&inner,program_modifier_inspect)
        case .Actions: inner:=Entity_Params{handle=e};inspect_with(s,call,&inner,authoring_action_inspect)
        case .Motion: inner:=Entity_Params{handle=e};inspect_with(s,call,&inner,authoring_motion_inspect)
        case .Morphs: inner:=Morph_Inspect_Params{handle=e,offset=p.offset,limit=p.limit,diagnostics=p.diagnostics};inspect_with(s,call,&inner,morph_inspect)
        case .Pose: instance_pose(call,w,e,&query)
        }
        // A part the entity lacks says why; the rest stays.
        if call.failed {
            reason,code:=call.error.message,""
            if value:=api.json_member(call.error.data,"code");value!="" {code=strings.trim(value,`"`)}
            call.failed,call.error=false,{}
            out.count=mark
            serial.text_write_raw(out,"{");api.write_bool(out,"available",false,true);api.write_text(out,"code",code);api.write_text(out,"reason",reason);serial.text_write_raw(out,"}")
        }
    }
    serial.text_write_raw(out,"}")
}

// What the motion matching of an entity plays, the clips of its database and its last search.
@(private)
instance_match :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity) {
    value,present:=editor.entity_get(world,entity,anim.Animation)
    if !present {authoring_failure(call,"entity","Missing_Component","an Animation component","missing component","The entity has no Animation component");return}
    if record,found:=aa.registry_find(&s.app.assets.registry,value.asset);!found || record.kind!=anim.MATCH_KIND {authoring_failure(call,"entity","Not_Matching","an Animation.asset that is a .match","another asset" if found else "none","The entity plays no motion matching",fix="Make one with animation.character.setup");return}
    result,matching:=preview_match(world,s.app,entity)
    if !matching {authoring_failure(call,"entity","Not_Running","a .match the world plays","not sampled","Matching runs in Play, Simulation, the preview of the editor or animation.preview");return}
    out:=call.out
    if !authoring_write_value(call,&result,type_info_of(Preview_Match_Result)) || out.count==0 {return}
    // The object goes on past the fields of Preview_Match_Result.
    out.count-=1
    playback:=core.world_storage_of(world,anim.Playback)
    state:^anim.Playing;for &playing in playback.states {if playing.entity==entity {state=&playing;break}}
    shared:=core.world_ref(s.app.shared,world.info,.Shared)
    library:=anim.animation_playing_content(core.world_storage_of(shared,anim.Source_Assets),s.app,state)
    db:=anim.animation_match_database(core.world_storage_of(shared,anim.Graph_Assets),library,state)
    modes:=locomotion_modes(world.info)
    api.write_key(out,"ranges");serial.write_u8(out,'[')
    if db!=nil {
        for &r,i in db.ranges {
            if i>0 {serial.write_u8(out,',')}
            label:=anim.source_clip_label(library,r.clips[0])
            serial.text_write_raw(out,"{");api.write_text(out,"clip",base.text_get(label[:]),true)
            if r.weights!={0=1} {
                api.write_key(out,"clips");serial.write_u8(out,'[');listed:=0
                for clip,k in r.clips {
                    if r.weights[k]<=0 {continue}
                    if listed>0 {serial.write_u8(out,',')};listed+=1
                    member:=Instance_Match_Member{clip=anim.source_clip_label(library,clip),weight=r.weights[k]}
                    authoring_write_value(call,&member,type_info_of(Instance_Match_Member))
                }
                serial.write_u8(out,']')
            }
            api.write_key(out,"modes");match_modes_write(out,modes,r.modes)
            api.write_bool(out,"loop",r.loop);api.write_bool(out,"entry",r.entry)
            api.write_key(out,"speed");api.write_number(out,r.speed)
            api.write_key(out,"travel");serial.write_u8(out,'[')
            for axis,k in r.travel {if k>0 {serial.write_u8(out,',')};api.write_number(out,axis)}
            serial.write_u8(out,']');api.write_key(out,"duration");api.write_number(out,f32(max(r.count-1,0))/db.rate)
            serial.write_u8(out,'}')
        }
    }
    serial.write_u8(out,']')
    if db!=nil && state.program.match.searched.search>0 {
        searched:=&state.program.match.searched
        mode:=u16(intrinsics.count_trailing_zeros(searched.request.modes))
        name,named:=locomotion_mode_name(modes,mode)
        api.write_key(out,"search");serial.text_write_raw(out,"{");api.write_uint(out,"search",u64(searched.search),true)
        api.write_text(out,"mode",name if named else fmt.tprintf("%d",mode));api.write_bool(out,"entry",searched.request.entry)
        if searched.request.event>0 {api.write_key(out,"time_to_land");api.write_number(out,searched.request.event)}
        api.write_key(out,"candidates");serial.write_u8(out,'[');written:=0
        noted:=anim.match_searched_candidates(db,searched^)
        for &candidate in noted.items[:clamp(noted.count,0,lib.MATCH_CANDIDATES)] {
            range:=lib.match_range_of(db,int(candidate.row));if range<0 {continue}
            if written>0 {serial.write_u8(out,',')};written+=1
            r:=db.ranges[range];c:=candidate.costs
            row:=Instance_Match_Candidate{range=u32(range),clip=anim.source_clip_label(library,r.clips[0]),time=f32(int(candidate.row)-int(r.first))/db.rate,rate=candidate.rate,cost=candidate.cost,reason=candidate.reason}
            row.costs={c[.Foot_Position],c[.Foot_Velocity],c[.Hip_Velocity],c[.Body_Velocity],c[.Trajectory_Position],c[.Trajectory_Direction]}
            authoring_write_value(call,&row,type_info_of(Instance_Match_Candidate))
        }
        serial.text_write_raw(out,"]}")
    }
    serial.write_u8(out,'}')
}

// The names of the locomotion modes of bits, as a list.
@(private)
match_modes_write :: proc(out:^serial.Writer,modes:[]core.Name_Info,bits:u32) {
    serial.write_u8(out,'[');written:=0
    for bit in u16(0)..<32 {
        if bits&(u32(1)<<bit)==0 {continue}
        if written>0 {serial.write_u8(out,',')};written+=1
        name,named:=locomotion_mode_name(modes,bit)
        serial.write_u8(out,'"');serial.text_write_raw(out,name if named else fmt.tprintf("%d",bit));serial.write_u8(out,'"')
    }
    serial.write_u8(out,']')
}

// A .match with a page of its clips and the database of each skeleton a rig built.
@(private)
match_inspect :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,offset,limit:u32) {
    file:Authoring_File;defer aa.asset_close(&file.file)
    profile,ok:=program_match_open(s,call,id,&file);if !ok {return}
    modes:=locomotion_modes(s.info)
    out:=call.out
    serial.text_write_raw(out,"{");authoring_result(call,id,file.path)
    api.write_key(out,"match");authoring_write_value(call,&profile.info,type_info_of(anim.Match_Info))
    api.write_uint(out,"match_clips_total",u64(len(profile.clips)));api.write_key(out,"match_clips");serial.text_write_raw(out,"[")
    start:=min(int(offset),len(profile.clips));end:=min(start+int(limit),len(profile.clips))
    for &clip,i in profile.clips[start:end] {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_raw(out,"{");api.write_text(out,"clip",base.text_get(clip.clip[:]),true)
        if clip.animation!={} {api.write_key(out,"animation");serial.write_u8(out,'"');serial.text_write_asset_id(out,clip.animation);serial.write_u8(out,'"')}
        api.write_key(out,"modes");match_modes_write(out,modes,clip.modes)
        api.write_bool(out,"loop",clip.loop);api.write_bool(out,"entry",clip.entry)
        if clip.speed>0 {api.write_key(out,"speed");api.write_number(out,clip.speed)}
        if names,count:=anim.match_source_clips(&clip);count>1 {
            api.write_key(out,"blend");serial.write_u8(out,'[')
            for name,k in names[1:count] {if k>0 {serial.write_u8(out,',')};serial.text_write_string(out,name)}
            serial.text_write_raw(out,`],"samples":[`);listed:=0
            for &sample in profile.samples {
                if int(sample.source)!=start+i {continue}
                if listed>0 {serial.write_u8(out,',')};listed+=1
                serial.text_write_raw(out,`{"weights":[`)
                for w,k in sample.weights {if k>0 {serial.write_u8(out,',')};api.write_number(out,w)}
                serial.write_u8(out,']')
                if sample.speed>0 {api.write_key(out,"speed");api.write_number(out,sample.speed)}
                serial.write_u8(out,'}')
            }
            serial.write_u8(out,']')
        }
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]");api.write_key(out,"databases");serial.write_u8(out,'[');written:=0
    if cache:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Graph_Assets);cache!=nil {
        for &content in cache.matches {
            if content.id!=id {continue}
            for &built in content.databases {
                if written>0 {serial.write_u8(out,',')};written+=1
                row:=Asset_Match_Database{rows=u32(built.database.rows),error=built.error}
                if built.error==.None {row.bytes=u64(lib.match_database_size(built.database))}
                authoring_write_value(call,&row,type_info_of(Asset_Match_Database))
            }
        }
    }
    serial.text_write_raw(out,"]}")
}
