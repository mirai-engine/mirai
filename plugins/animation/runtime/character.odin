package anim

import "core:mem"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import "base:runtime"

// A .character is everything a character plays and adapts, shared by every character of its body:
// its locomotion by motion matching, the stack of layers over it and the actions play asks for,
// the aim spaces its layers sample, the warping of its stride and of its moves to a target, and
// the modifiers of its pose (IK, look, grounding, rigs, faces). Animation.asset names it. Its
// limbs are those of the body of the skeleton (@foot_l, @pelvis); the sections and windows of its
// actions and its warp windows are spans of its clips.
CHARACTER_VERSION :: 2

Character_Info :: struct {animation:base.Asset_Id} // the .anim of its clips; empty for a set that names none (the modifiers of a rope)
// spaces: the aim offsets and additive poses its layers sample, each with its samples in
// space_samples, in the order of the spaces.
Character_Set :: struct {
    info:Character_Info,
    match:Match_Profile, // without clips it has no locomotion: its base is Animation.clip
    actions:Action_Profile,
    spaces:[]Blend_Info,
    space_samples:[]Blend_Sample,
    motion:Motion_Profile,
    pose:Pose_Profile,
}
// A set over the clips of animation whose locomotion and warping take their defaults.
character_set_make :: proc(animation:base.Asset_Id) -> Character_Set {
    return {info={animation=animation},match={info=MATCH_INFO_DEFAULT},motion={warp=POSE_WARP_PROFILE_DEFAULT}}
}

character_check :: proc(set:Character_Set) -> bool {
    clipless:=len(set.match.clips)+len(set.actions.actions)+len(set.actions.layers)+len(set.spaces)+len(set.motion.distances)==0
    if set.info.animation=={} && !clipless || !match_check(set.match) || !action_profile_check(set.actions) || !motion_profile_check(set.motion) || !pose_profile_check(set.pose) {return false}
    if len(set.spaces)>STACK_LAYERS || len(set.space_samples)>lib.BLEND_MAX_SAMPLES*len(set.spaces) {return false}
    for &space,i in set.spaces {
        first,count:=character_space_samples(set,i)
        if count==0 || !blend_definition_check(space,set.space_samples[first:][:count]) {return false}
        for &previous in set.spaces[:i] {if previous.name==space.name {return false}}
    }
    for sample,i in set.space_samples {if int(sample.space)>=len(set.spaces) || i>0 && sample.space<set.space_samples[i-1].space {return false}}
    for &layer in set.actions.layers {if layer.space[0]!=0 && character_space(set,layer.space)<0 {return false}}
    return true
}
// The space of a set of that name; -1 for none.
character_space :: proc(set:Character_Set,name:[32]u8) -> int {
    for &space,i in set.spaces {if space.name==name {return i}}
    return -1
}
// Where the samples of space index are in space_samples.
character_space_samples :: proc(set:Character_Set,index:int) -> (first,count:int) {
    for sample,i in set.space_samples {
        if int(sample.space)<index {continue}
        if int(sample.space)>index {break}
        if count==0 {first=i}
        count+=1
    }
    return
}

character_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,set:Character_Set,allocator:=context.allocator) -> asset.Error {
    if !character_check(set) {return .Invalid}
    asset.document_init(doc,CHARACTER_KIND,id,allocator);doc.kind_version=CHARACTER_VERSION
    error:=character_tables(doc,types,set)
    if error!=.None {asset.document_destroy(doc)}
    return error
}
@(private)
character_tables :: proc(doc:^asset.Document,types:^asset.Types,set:Character_Set) -> asset.Error {
    info,locomotion,warp,grounding:=set.info,set.match.info,set.motion.warp,set.pose.grounding
    pose:=set.pose
    asset.document_put_row(doc,types,"info",&info) or_return
    asset.document_put_row(doc,types,"match",&locomotion) or_return
    asset.document_put(doc,types,"clips",set.match.clips) or_return
    asset.document_put(doc,types,"samples",set.match.samples) or_return
    asset.document_put(doc,types,"layers",set.actions.layers) or_return
    asset.document_put(doc,types,"actions",set.actions.actions) or_return
    asset.document_put(doc,types,"sections",set.actions.sections) or_return
    asset.document_put(doc,types,"spaces",set.spaces) or_return
    asset.document_put(doc,types,"space_samples",set.space_samples) or_return
    asset.document_put_row(doc,types,"warp",&warp) or_return
    asset.document_put(doc,types,"windows",set.motion.windows) or_return
    asset.document_put(doc,types,"distances",set.motion.distances) or_return
    asset.document_put(doc,types,"keys",set.motion.keys) or_return
    asset.document_put(doc,types,"ik",pose.ik) or_return
    asset.document_put(doc,types,"look",pose.look) or_return
    asset.document_put(doc,types,"limits",pose.limits) or_return
    asset.document_put_row(doc,types,"grounding",&grounding) or_return
    asset.document_put(doc,types,"chain_ik",pose.chain_ik) or_return
    asset.document_put(doc,types,"twist",pose.twist) or_return
    asset.document_put(doc,types,"springs",pose.springs) or_return
    asset.document_put(doc,types,"multi_ik",pose.multi_ik) or_return
    asset.document_put(doc,types,"retarget_chains",pose.retarget_chains) or_return
    asset.document_put(doc,types,"spline_ik",pose.spline_ik) or_return
    asset.document_put(doc,types,"correctives",pose.correctives) or_return
    asset.document_put(doc,types,"follow",pose.follow) or_return
    asset.document_put(doc,types,"curve_poses",pose.curve_poses) or_return
    asset.document_put(doc,types,"curve_drives",pose.curve_drives) or_return
    asset.document_put(doc,types,"curve_materials",pose.curve_materials) or_return
    return .None
}
character_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,set:Character_Set,allocator:=context.allocator) -> asset.Error {
    doc:asset.Document
    character_document(&doc,types,id,set,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}
// The set of an open file: its tables are views into the file, valid while it stays open.
character_view :: proc(file:^asset.Asset,types:^asset.Types) -> (set:Character_Set,error:asset.Error) {
    asset.kind_check(file,CHARACTER_KIND,CHARACTER_VERSION) or_return
    set.info=(asset.asset_row(file,types,"info",Character_Info) or_return)^
    set.match.info=(asset.asset_row(file,types,"match",Match_Info) or_return)^
    set.match.clips=asset.asset_rows(file,types,"clips","",Match_Source) or_return
    set.match.samples=asset.asset_rows(file,types,"samples","",Match_Sample) or_return
    set.actions.layers=asset.asset_rows(file,types,"layers","",Stack_Layer) or_return
    set.actions.actions=asset.asset_rows(file,types,"actions","",Action_Definition) or_return
    set.actions.sections=asset.asset_rows(file,types,"sections","",Action_Section) or_return
    set.spaces=asset.asset_rows(file,types,"spaces","",Blend_Info) or_return
    set.space_samples=asset.asset_rows(file,types,"space_samples","",Blend_Sample) or_return
    set.motion.warp=(asset.asset_row(file,types,"warp",Pose_Warp_Profile) or_return)^
    set.motion.windows=asset.asset_rows(file,types,"windows","",Motion_Window) or_return
    set.motion.distances=asset.asset_rows(file,types,"distances","",Motion_Distance) or_return
    set.motion.keys=asset.asset_rows(file,types,"keys","",lib.Distance_Key) or_return
    pose:=&set.pose
    pose.ik=asset.asset_rows(file,types,"ik","",IK_Constraint) or_return
    pose.look=asset.asset_rows(file,types,"look","",Look_Constraint) or_return
    pose.limits=asset.asset_rows(file,types,"limits","",Rotation_Constraint) or_return
    pose.grounding=(asset.asset_row(file,types,"grounding",Foot_Grounding) or_return)^
    pose.chain_ik=asset.asset_rows(file,types,"chain_ik","",Chain_IK_Constraint) or_return
    pose.twist=asset.asset_rows(file,types,"twist","",Twist_Constraint) or_return
    pose.springs=asset.asset_rows(file,types,"springs","",Spring_Constraint) or_return
    pose.multi_ik=asset.asset_rows(file,types,"multi_ik","",Multi_IK_Constraint) or_return
    pose.retarget_chains=asset.asset_rows(file,types,"retarget_chains","",Chain_Retarget_Constraint) or_return
    pose.spline_ik=asset.asset_rows(file,types,"spline_ik","",Spline_IK_Constraint) or_return
    pose.correctives=asset.asset_rows(file,types,"correctives","",Pose_Corrective) or_return
    pose.follow=asset.asset_rows(file,types,"follow","",Follow_Constraint) or_return
    pose.curve_poses=asset.asset_rows(file,types,"curve_poses","",Curve_Pose) or_return
    pose.curve_drives=asset.asset_rows(file,types,"curve_drives","",Curve_Drive) or_return
    pose.curve_materials=asset.asset_rows(file,types,"curve_materials","",Curve_Material) or_return
    if !character_check(set) {return {},.Corrupt}
    return set,.None
}

// A space of a set made ready to sample: its places normalized and triangulated, the names of the
// clips of its samples and of its axes (base.name_hash).
Space_Ready :: struct {space:lib.Blend_Space,first:int,names:[]u64,axis_names:[2]u64}
// A database built for a library and a skeleton.
@(private)
Match_Built :: struct {key:[7]u64,database:lib.Match_Database,error:lib.Match_Build_Error,fault:Match_Blend_Fault}
// What a set reads into while it is the asset: the open file its tables are views into, its
// spaces ready to sample and the motion matching databases built for it.
Character_Content :: struct {
    id:base.Asset_Id,checked,revision:u64,stamp:[2]i64,valid:bool,error:asset.Error,
    file:asset.Asset,
    set:Character_Set,
    spaces:[]Space_Ready,
    databases:[dynamic]Match_Built,
}
@(storage,host,free="character_assets_free")
Character_Assets :: struct {allocator:mem.Allocator,contents:[dynamic]Character_Content}
character_assets_free :: proc(cache:^Character_Assets) {
    if cache.allocator.procedure!=nil {context.allocator=cache.allocator}
    for &content in cache.contents {character_content_release(&content)}
    delete(cache.contents);cache^={}
}
@(private)
character_content_release :: proc(content:^Character_Content) {
    for &ready in content.spaces {lib.blend_space_destroy(&ready.space);delete(ready.names)}
    delete(content.spaces)
    for &built in content.databases {lib.match_database_free(&built.database)}
    delete(content.databases)
    asset.asset_close(&content.file)
    content.file,content.set,content.spaces,content.databases={},{},nil,nil
}

// The set id names, read again when its file changes; nil while it cannot be read (content_error
// says why). hint: where it was found the last time, kept by the caller.
character_content :: proc(cache:^Character_Assets,assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id,hint:^i32=nil) -> ^Character_Content {
    if cache==nil || assets==nil || id=={} {return nil}
    context.allocator=allocator;cache.allocator=allocator
    row:=int(hint^)-1 if hint!=nil else -1
    if row<0 || row>=len(cache.contents) || cache.contents[row].id!=id {row=-1;for &content,i in cache.contents {if content.id==id {row=i;break}}}
    if row<0 {row=len(cache.contents);if !program_array_reserve(&cache.contents,row+1) || append(&cache.contents,Character_Content{id=id})!=1 {return nil}}
    if hint!=nil {hint^=i32(row+1)}
    content:=&cache.contents[row]
    if content.checked==assets_stamp(assets) {return content if content.valid else nil}
    record,found:=asset.registry_find(&assets.registry,id)
    stamp:=[2]i64{}
    if found {stamp={record.size,record.time}}
    if content.checked!=0 && stamp==content.stamp {content.checked=assets_stamp(assets);return content if content.valid else nil}
    // Without memory for the new version the old one stays, and the next call reads it again.
    next:=Character_Content{id=id}
    error:=asset.Error.Not_Found
    if found {error=character_read(&next,assets,allocator,id)}
    if error!=.None {character_content_release(&next)}
    if error==.Out_Of_Memory {content.error,content.checked=error,0;return nil}
    revision:=content.revision
    character_content_release(content)
    content^=next
    content.error,content.valid=error,error==.None
    content.stamp,content.revision,content.checked=stamp,revision+1,assets_stamp(assets)
    return content if content.valid else nil
}
@(private)
character_read :: proc(content:^Character_Content,assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id) -> asset.Error {
    host.assets_file(assets,id,CHARACTER_KIND,&content.file) or_return
    content.set=character_view(&content.file,&assets.types) or_return
    set:=content.set
    spaces,error:=make([]Space_Ready,len(set.spaces),allocator)
    if error!=nil {return .Out_Of_Memory}
    content.spaces=spaces
    for &space,i in set.spaces {
        ready:=&content.spaces[i]
        first,count:=character_space_samples(set,i)
        points:[lib.BLEND_MAX_SAMPLES]mm.Vec2
        names,named:=make([]u64,count,allocator);if named!=nil {return .Out_Of_Memory}
        ready.first,ready.names=first,names
        for &sample,k in set.space_samples[first:][:count] {points[k]=blend_position(space,sample.position);names[k]=base.name_hash(base.text_get(sample.clip[:]))}
        failure:lib.Blend_Error
        prepared,ok:=lib.blend_space_prepare(points[:count],space.dimension,allocator,&failure)
        if !ok {return .Out_Of_Memory if failure==.Out_Of_Memory else .Corrupt}
        ready.space=prepared
        ready.axis_names={base.name_hash(base.text_get(space.x.name[:])),base.name_hash(base.text_get(space.y.name[:]))}
    }
    return .None
}

// The .character an Animation plays: its asset when it is one.
animation_character :: proc(assets:^host.Assets,animation:Animation) -> base.Asset_Id {
    if assets==nil || animation.asset=={} {return {}}
    record,found:=asset.registry_find(&assets.registry,animation.asset)
    return animation.asset if found && record.kind==CHARACTER_KIND else {}
}
// The content of a set already read, without reading it again: nil when it is not valid.
character_cached :: proc(cache:^Character_Assets,id:base.Asset_Id,hint:^i32=nil) -> ^Character_Content {
    if cache==nil || id=={} {return nil}
    row:=int(hint^)-1 if hint!=nil else -1
    if row<0 || row>=len(cache.contents) || cache.contents[row].id!=id {row=-1;for &content,i in cache.contents {if content.id==id {row=i;break}}}
    if row<0 || !cache.contents[row].valid {return nil}
    if hint!=nil {hint^=i32(row+1)}
    return &cache.contents[row]
}
