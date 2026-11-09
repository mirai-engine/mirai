package anim

import cmath "core:math"
import "core:mem"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"

// A .match plays locomotion by motion matching over its clips: every interval it looks for the
// frame whose feet, hips and trajectory are closest to what the body does and is asked to do,
// and jumps there with an inertial blend. Animation.asset names it like an .agraph. The body is
// told each tick by match_goal (the animation_physics plugin tells it from the Character); the
// locomotion mode of the goal picks the clips that serve it, and entering a mode searches the
// starts of its entry clips (a jump, a landing). match_play plays a clip of the library at once
// (a vault, a hit, a death) until a share of it or one of its markers, and matching goes on from
// there.

MATCH_KIND :: asset.Fourcc(u32('A')|u32('M')<<8|u32('T')<<16|u32('C')<<24)
MATCH_VERSION :: 7
MATCH_OLDEST :: 6
MATCH_CLIPS :: 64
// Share of the speed the pose walks at that its root closes on the body by, with a lag.
MATCH_LAG_CLOSE :: .5

Match_Info :: struct {
    animation:base.Asset_Id,           // .anim of its clips
    rate:f32 `mirai:"unit=1/s"`,       // rows of the database per second of clip
    interval:f32 `mirai:"unit=s"`,     // between searches
    blend:f32 `mirai:"unit=s"`,        // of the inertial blend of a jump
    bias:f32,                          // of cost a jump has to save over playing on
    min_rate,max_rate:f32,             // of the speed a clip that travels plays at to follow the body, unless its source has its own
    memory:u32 `mirai:"unit=KiB"`,     // most the database of one skeleton keeps
    left_foot,right_foot,hips:Bone_Ref,
    foot_position,foot_velocity,hip_velocity,body_velocity,trajectory_position,trajectory_direction:f32, // weights
    keep_loop_phase:bool,              // do not seek within the current looping clip
    stationary_speed:f32,              // if positive, a body this slow plays the clips that stand, and a faster one those that travel
    reselect:f32 `mirai:"unit=s"`,     // rows of the clip playing this near, and those played this long before the rig left them, are not jumped to
    hold:f32 `mirai:"unit=s"`,         // least time between two jumps nothing forces
    lag:f32 `mirai:"unit=m"`,          // most the root of the pose strays from the body, which it follows by a spring: for a body that stops or starts faster than its clips; 0: it stays on it
    lag_half_life:f32 `mirai:"unit=s"`,
    landing_marker:[64]u8 `mirai:"text"`, // marks first contact on the clips that land (a jump): played to reach it when the body lands; empty: none
    landing_rates:[2]f32,              // least and most rate a clip plays at to reach its landing marker when the body lands
}
MATCH_INFO_DEFAULT :: Match_Info{
    rate=30,interval=0,blend=.2,bias=.5,min_rate=.5,max_rate=1,memory=16384,
    left_foot={path={0='@',1='f',2='o',3='o',4='t',5='_',6='l'}},right_foot={path={0='@',1='f',2='o',3='o',4='t',5='_',6='r'}},hips={path={0='@',1='p',2='e',3='l',4='v',5='i',6='s'}},
    foot_position=.75,foot_velocity=1,hip_velocity=1,body_velocity=1,trajectory_position=2,trajectory_direction=1.5,
    reselect=.3,hold=.1,lag_half_life=.2,
    landing_marker={0='l',1='a',2='n',3='d'},landing_rates={.5,2},
}
// Clips a blended source mixes, and samples of blends a .match keeps.
MATCH_BLEND :: lib.MATCH_BLEND
MATCH_SAMPLES :: 128

// A clip the search can pick. modes: bit m for each locomotion mode m it serves; entry: it starts
// one of them, searched from its start when the body enters the mode.
// speed, when positive, is the m/s the clip travels at instead of the one measured from its feet.
// With blend (the names of up to MATCH_BLEND-1 other clips of its library, the first empty one
// ends them), the source is a blend: its clip and those loop, last the same within a row and are
// in phase (the same share of each is the same moment of the step), and each Match_Sample of it is
// searched as a clip of its own, measured from their pose blended at its weights, and played as
// those clips together at its weights. A blend loops, is no entry and takes its speeds per sample.
// min_rate and max_rate, when positive, replace those of the .match for it and its samples: a set
// authored slower than the body moves in it (a crouch), or a jog kept from beating a sprint.
Match_Source :: struct {clip:[64]u8 `mirai:"text"`,animation:base.Asset_Id,modes:u32,loop,entry:bool,speed:f32 `mirai:"unit=m/s"`,blend:[MATCH_BLEND-1][64]u8 `mirai:"text"`,min_rate,max_rate:f32}
// A point of a blended source (its index in clips): the weight of its clip, then of each clip of
// its blend, each in 0..1 with a positive sum, played as shares of that sum; speed, when positive,
// the m/s it travels at instead of the one measured from its blended feet.
Match_Sample :: struct {source:u32,weights:[MATCH_BLEND]f32,speed:f32 `mirai:"unit=m/s"`}
Match_Profile :: struct {info:Match_Info,clips:[]Match_Source,samples:[]Match_Sample}

// The clips a source plays: its clip, then those of its blend.
match_source_clips :: proc(source:^Match_Source) -> (names:[MATCH_BLEND]string,count:int) {
    names[0]=base.text_get(source.clip[:]);count=1
    for &other in source.blend {
        if other[0]==0 {break}
        names[count]=base.text_get(other[:]);count+=1
    }
    return
}

match_check :: proc(profile:Match_Profile) -> bool {
    info:=profile.info
    if info.animation=={} || len(profile.clips)==0 || len(profile.clips)>MATCH_CLIPS || len(profile.samples)>MATCH_SAMPLES || info.memory==0 {return false}
    for value in ([19]f32{info.rate,info.interval,info.blend,info.bias,info.min_rate,info.max_rate,info.foot_position,info.foot_velocity,info.hip_velocity,info.body_velocity,info.trajectory_position,info.trajectory_direction,info.stationary_speed,info.reselect,info.hold,info.lag,info.lag_half_life,info.landing_rates[0],info.landing_rates[1]}) {if !finite(value) || value<0 {return false}}
    if info.rate<=0 || info.rate>lib.FRAMES_MAX_RATE || info.min_rate<=0 || info.min_rate>info.max_rate || info.lag>0 && info.lag_half_life<=0 {return false}
    if !blend_text_valid(info.landing_marker[:],true) || info.landing_rates[0]<=0 || info.landing_rates[0]>info.landing_rates[1] {return false}
    for bone in ([3]Bone_Ref{info.left_foot,info.right_foot,info.hips}) {if !profile_bone(bone) || bone.path[0]==0 {return false}}
    for &clip,i in profile.clips {
        if !blend_text_valid(clip.clip[:],false) || clip.modes==0 || clip.entry && clip.loop || !finite(clip.speed) || clip.speed<0 || !lib.match_rates_valid({clip.min_rate,clip.max_rate}) {return false}
        for other in profile.clips[:i] {if other.clip==clip.clip && other.animation==clip.animation {return false}}
        ended:=false
        for &other,k in clip.blend {
            if !blend_text_valid(other[:],true) || ended && other[0]!=0 {return false}
            if other[0]==0 {ended=true;continue}
            if other==clip.clip {return false}
            for &earlier in clip.blend[:k] {if earlier==other {return false}}
        }
        samples:=0
        for sample in profile.samples {if int(sample.source)==i {samples+=1}}
        if (clip.blend[0][0]!=0)!=(samples>0) || samples>0 && (!clip.loop || clip.speed!=0) {return false}
    }
    for &sample in profile.samples {
        if int(sample.source)>=len(profile.clips) || !finite(sample.speed) || sample.speed<0 {return false}
        _,count:=match_source_clips(&profile.clips[sample.source])
        sum:f32
        for w,k in sample.weights {
            if !finite(w) || w<0 || w>1 || k>=count && w!=0 {return false}
            sum+=w
        }
        if sum<=0 {return false}
    }
    return true
}
match_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,profile:Match_Profile,allocator:=context.allocator) -> asset.Error {
    if !match_check(profile) {return .Invalid}
    asset.document_init(doc,MATCH_KIND,id,allocator);doc.kind_version=MATCH_VERSION
    error:=match_tables(doc,types,profile)
    if error!=.None {asset.document_destroy(doc)}
    return error
}
@(private)
match_tables :: proc(doc:^asset.Document,types:^asset.Types,profile:Match_Profile) -> asset.Error {
    info:=profile.info
    asset.document_put_row(doc,types,"match",&info) or_return
    asset.document_put(doc,types,"clips",profile.clips) or_return
    asset.document_put(doc,types,"samples",profile.samples) or_return
    return .None
}
match_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,profile:Match_Profile,allocator:=context.allocator) -> asset.Error {
    doc:asset.Document
    match_document(&doc,types,id,profile,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}
match_view :: proc(file:^asset.Asset,types:^asset.Types) -> (profile:Match_Profile,error:asset.Error) {
    asset.kind_check(file,MATCH_KIND,MATCH_OLDEST,MATCH_VERSION) or_return
    info:=asset.asset_row(file,types,"match",Match_Info) or_return
    profile.info=info^
    profile.clips=asset.asset_rows(file,types,"clips","",Match_Source) or_return
    profile.samples=asset.asset_rows(file,types,"samples","",Match_Sample) or_return
    if !match_check(profile) {return {},.Corrupt}
    return profile,.None
}
match_profile_free :: proc(profile:^Match_Profile,allocator:=context.allocator) {delete(profile.clips,allocator);delete(profile.samples,allocator);profile^={}}

// What makes a blended source unplayable with a library: a clip it does not have, or two clips
// of a source (member 0 and member) that last more than a row of the database apart.
@(private)
Match_Blend_Fault :: struct {kind:enum u8 {None,Missing,Duration},source,member:i32,durations:[2]f32}
// A database built for a library and a skeleton.
@(private)
Match_Built :: struct {key:[7]u64,database:lib.Match_Database,error:lib.Match_Build_Error,fault:Match_Blend_Fault}
Match_Content :: struct {
    id:base.Asset_Id,checked,revision:u64,stamp:[2]i64,profile:Match_Profile,valid:bool,error:asset.Error,
    databases:[dynamic]Match_Built,
}
@(private)
match_content_free :: proc(content:^Match_Content) {
    delete(content.profile.clips);delete(content.profile.samples)
    for &built in content.databases {lib.match_database_free(&built.database)}
    delete(content.databases)
    content^={}
}

match_content :: proc(cache:^Graph_Assets,app:^host.App,id:base.Asset_Id) -> ^Match_Content {
    if cache==nil || app==nil || app.assets==nil || id=={} {return nil}
    context.allocator=app.allocator;cache.allocator=app.allocator
    row:=-1
    for content,i in cache.matches {if content.id==id {row=i;break}}
    if row<0 {row=len(cache.matches);if append(&cache.matches,Match_Content{id=id})!=1 {return nil}}
    content:=&cache.matches[row]
    if content.checked==assets_stamp(app) {return content if content.valid else nil}
    record,found:=asset.registry_find(&app.assets.registry,id)
    stamp:=[2]i64{}
    if found {stamp={record.size,record.time}}
    if content.checked!=0 && stamp==content.stamp {content.checked=assets_stamp(app);return content if content.valid else nil}
    profile:Match_Profile;error:=asset.Error.Not_Found
    if found {
        file:asset.Asset
        error=host.assets_file(app.assets,id,MATCH_KIND,&file)
        if error==.None {
            view,read:=match_view(&file,&app.assets.types);error=read
            if read==.None {
                profile.info=view.info
                clips,ok:=graph_clone(view.clips,app.allocator)
                samples,cloned:=graph_clone(view.samples,app.allocator)
                if ok && cloned {profile.clips,profile.samples=clips,samples} else {delete(clips);delete(samples);error=.Out_Of_Memory}
            }
            asset.asset_close(&file)
        }
    }
    if error==.Out_Of_Memory {content.error=error;content.checked=0;return nil}
    revision:=content.revision
    match_content_free(content)
    content^={id=id,profile=profile,valid=error==.None,error=error,stamp=stamp,checked=assets_stamp(app),revision=revision+1}
    return content if content.valid else nil
}

// What the body does and is asked to do in this tick, for a rig that plays a .match: mode is its
// locomotion mode; velocity, where it goes; desired, the velocity its walk heads to at
// acceleration (braking toward zero); facing, where it turns to at turn_rate rad/s (0: at once);
// wall, the normal of what blocks it, out of that (zero: nothing), which neither its trajectory
// nor the root of its pose go into; time_to_land, the seconds until a body in the air lands (0:
// none known), which the landing marker of the .match plays toward. World axes, m/s. The rig faces
// the forward of its skeleton's body, -Z of its transform.
Match_Goal :: struct {rig:core.Entity,mode:u16,velocity,desired,facing,wall:mm.Vec3,acceleration,braking,turn_rate,time_to_land:f32}

// How a clip played by match_play enters and when matching takes over again. A play enters at the
// start of its clip, at the time the clip playing is at (keep_time) or at the phase of its markers
// (match_phase); it holds until phase of its duration (1: its end; a clip that does not loop holds
// its last pose there until matching picks another) or until it crosses its marker. A play of
// lower priority than the one playing is refused; with wait, one that comes while a blend runs
// starts when the blend ends, unless a later play replaces it first.
Match_Entry :: enum u8 {Start,Keep_Time,Match_Phase}
Match_Play_Options :: struct {fade:f32,entry:Match_Entry,phase:f32,marker:string,priority:i16,wait:bool}
MATCH_PLAY_OPTIONS_DEFAULT :: Match_Play_Options{fade=.15,phase=1}
Match_Play :: struct {rig:core.Entity,clip,marker:u64,mode:u16,fade,phase:f32,entry:Match_Entry,priority:i16,wait:bool}

// Tells the matching of a rig what its body does in this tick.
match_goal :: proc(requests:^Animation_Requests,goal:Match_Goal) {
    if requests==nil {return}
    valid:=goal.rig!=core.NONE && goal.mode<=31
    for v in ([4]mm.Vec3{goal.velocity,goal.desired,goal.facing,goal.wall}) {valid&&=finite(v.x) && finite(v.y) && finite(v.z)}
    for value in ([4]f32{goal.acceleration,goal.braking,goal.turn_rate,goal.time_to_land}) {valid&&=finite(value) && value>=0}
    if !valid {core.refuse(&requests.match_goals);return}
    core.offer(&requests.match_goals,goal)
}
// Plays a clip of the library of the .match of a rig with an inertial blend of options.fade
// seconds, as the clip of mode, until matching takes over (Match_Play_Options says how). It plays
// while the body stays in mode: leaving it hands the rig back to matching.
match_play :: proc(requests:^Animation_Requests,rig:core.Entity,clip:string,mode:u16,options:=MATCH_PLAY_OPTIONS_DEFAULT) {
    if requests==nil {return}
    valid:=rig!=core.NONE && len(clip)>0 && len(clip)<64 && len(options.marker)<64 && mode<=31 && finite(options.fade) && options.fade>=0 && finite(options.phase) && options.phase>=0 && options.phase<=1 && options.entry<=max(Match_Entry)
    for byte in clip {valid&&=byte!=0}
    for byte in options.marker {valid&&=byte!=0}
    if !valid {core.refuse(&requests.match_plays);return}
    core.offer(&requests.match_plays,Match_Play{rig=rig,clip=base.name_hash(clip),marker=base.name_hash(options.marker) if len(options.marker)>0 else 0,mode=mode,fade=options.fade,phase=options.phase,entry=options.entry,priority=options.priority,wait=options.wait})
}

// Hands rig back to the matching in the next tick: the clip match_play plays ends (Exited), and
// one waiting for a blend is dropped. A body that starts to move ends an idle this way.
match_stop :: proc(requests:^Animation_Requests,rig:core.Entity) {
    if requests==nil {return}
    if rig==core.NONE {core.refuse(&requests.match_plays);return}
    core.offer(&requests.match_plays,Match_Play{rig=rig})
}

// What the matching of a rig plays. clip is base.name_hash of its name; speed, m/s the pose
// walks forward at (that of the clip by its rate); mode, the locomotion mode of that clip; forced,
// a clip of match_play plays; velocity, the one of the root of the pose that matching follows
// (that of the body with the lag of its spring), and lag, where that root is from the body. World
// axes. landing_modes: bit m for each mode m whose clips play toward the landing marker, which
// match_goal.time_to_land times.
// travel: the direction its clip moves in, rig axes (unit; zero for one that stands or plays by match_play).
Animation_Match :: struct {clip:u64,time,rate,speed,cost:f32,mode:u16,forced:bool,searches,jumps:u32,velocity,lag,travel:mm.Vec3,landing_modes:u32}

// The direction remaining of the way from to back toward from, turning about the vertical: a clip
// that backs off after one that went forward turns through the side and never through zero.
@(private)
travel_turn :: proc "contextless" (from,to:mm.Vec3,remaining:f32) -> mm.Vec3 {
    if from=={} || to=={} || !(remaining>0) {return to}
    turn:=cmath.atan2(linalg.cross(from,to).y,linalg.dot(from,to))
    return linalg.normalize0(mm.quat_rotate(linalg.quaternion_angle_axis_f32(turn*(1-remaining),{0,1,0}),from))
}

// False for an entity that does not play a .match.
animation_match :: proc(playback:^Playback,entity:core.Entity) -> (value:Animation_Match,ok:bool) {
    state:=constraint_playing(playback,entity) if playback!=nil else nil
    if state==nil || state.program.kind!=MATCH_KIND || !state.program.ready {return}
    m:=state.program.match
    return {clip=m.clip,time=state.time,rate=m.rate,speed=m.speed*m.rate,cost=m.cost,mode=m.mode,forced=m.phase==.Play,searches=m.searches,jumps=m.jumps,velocity=m.body+m.lag_velocity,lag=m.lag,travel=m.travel,landing_modes=m.landing_modes},true
}

// What the clip of a rig plays for: matching; a clip of match_play; one toward its landing
// marker, at the rate that reaches it when the body lands; or one that reached it as the body
// landed and plays on in the mode it landed in, until it ends or a search leaves it.
Match_Phase :: enum u8 {Matching,Play,Landing,Landed}

// The matching of a rig between ticks.
Match_Playing :: struct {
    range:i32,     // of the database its clip is; -1: one match_play asked for, or none
    clip:u64,      // name in the library of the clip it plays; 0: none yet
    loop:bool,
    phase:Match_Phase,
    mode:u16,      // the one its clip serves
    play,pending:Match_Play, // the one playing in phase Play, and one that waits for the blend
    waiting,finished:bool,   // pending holds a play; Finished was reported for play
    last:f32,      // time of the clip of play in the last tick
    timer:f32,     // seconds to the next search
    since:f32,     // seconds since the last jump
    rate,speed,cost:f32,
    // Direction its clip moves in, rig axes; zero when it stands. A jump turns it from travel_from
    // to travel_to over the blend of the jump, as the pose turns, travel_age seconds ago.
    travel,travel_from,travel_to:mm.Vec3,
    travel_age:f32,
    searches,jumps:u32,
    goal:i32,      // 1 + the index of its goal among those of this tick; 0: none
    landing_modes:u32, // event_modes of its database
    recent:lib.Match_Recent, // rows it left
    trail:lib.Match_Trail,   // where the root of the pose went
    body:mm.Vec3,            // horizontal velocity of the body in the last tick
    lag,lag_velocity:mm.Vec3, // of the root of the pose from the body, world axes
    told:bool,               // body holds a velocity
    searched:Match_Searched,
}
// The last search matching had to make (a mode it enters, a start or a stop, a clip that ends or
// none playing), as it made it: its request, the row that played, whether its clip was left whole,
// the reselect span and the rows the rig had left, and which of searches it was. It searched mode
// m for the bit m of request.modes. match_searched_candidates searches it again to note its
// candidates; the tick does not.
Match_Searched :: struct {request:lib.Match_Request,row:i32,whole:bool,span:f32,recent:lib.Match_Recent,search:u32}

// The candidates of the last search matching had to make, searched again as it was made in db.
match_searched_candidates :: proc "contextless" (db:^lib.Match_Database,searched:Match_Searched) -> (candidates:lib.Match_Candidates) {
    if db==nil || searched.search==0 {return}
    recent:=searched.recent
    lib.match_search(db,searched.request,int(searched.row),searched.whole,searched.span,&recent,&candidates)
    return
}
MATCH_PLAYING_DEFAULT :: Match_Playing{range=-1,rate=1,since=max(f32)}

// The matching of a rig whose Animation.library swaps the clips of its .match (a weapon's set): it
// keeps the body it follows, its root lag and its mode, and the name of the clip it played, so the
// next tick searches the new clips at once and enters the one it picks through an inertial
// transition from the pose of the old one, as a jump does, instead of starting over from rest.
@(private)
match_swapped :: proc "contextless" (kept:Match_Playing) -> Match_Playing {
    m:=MATCH_PLAYING_DEFAULT
    m.clip,m.mode,m.loop=kept.clip,kept.mode,kept.loop
    m.trail,m.body,m.lag,m.lag_velocity,m.told=kept.trail,kept.body,kept.lag,kept.lag_velocity,kept.told
    m.searches,m.jumps=kept.searches,kept.jumps
    return m
}

@(private)
match_database_key :: proc(library:^host.Content_Animation,state:^Playing,source:base.Asset_Id) -> [7]u64 {
    shape:=state.skeleton
    if shape=={} {for target in state.targets {shape[0]=base.hash_combine(shape[0],target)}}
    return {library.id[0],library.id[1],u64(library.generation),shape[0],shape[1],state.skeleton_revision,source[0]~source[1]}
}

// The database the matching of a rig searches, of library, what it plays: nil for a rig that
// plays no .match, before its first tick or when its database could not be built.
animation_match_database :: proc(graphs:^Graph_Assets,library:^host.Content_Animation,state:^Playing) -> ^lib.Match_Database {
    if graphs==nil || library==nil || state==nil || state.program.kind!=MATCH_KIND || !state.program.ready {return nil}
    key:=match_database_key(library,state,state.program.library)
    for &content in graphs.matches {
        if content.id!=state.program.asset || content.revision!=state.program.revision || !content.valid {continue}
        for &built in content.databases {if built.key==key && built.error==.None {return &built.database}}
    }
    return nil
}

// The database of a library for the skeleton of a rig, built the first time a rig of that
// skeleton loads it.
@(private)
match_database :: proc(content:^Match_Content,library:^host.Content_Animation,state:^Playing,source:base.Asset_Id,allocator:mem.Allocator) -> (^lib.Match_Database,lib.Match_Build_Error,Match_Blend_Fault) {
    if library==nil || len(state.parents)<2 || len(state.rest)!=len(state.parents) {return nil,.Invalid,{}}
    key:=match_database_key(library,state,source)
    for &built in content.databases {if built.key==key {return &built.database if built.error==.None else nil,built.error,built.fault}}
    context.allocator=allocator
    info:=content.profile.info
    bones:=[3]int{bone_resolve(state,info.left_foot),bone_resolve(state,info.right_foot),bone_resolve(state,info.hips)}
    // A source without blend is one clip of the database; a blend, one per sample of it.
    count:=len(content.profile.samples)
    for &clip in content.profile.clips {if clip.blend[0][0]==0 {count+=1}}
    clips,clips_error:=make([]lib.Match_Clip,count);defer delete(clips)
    found:=bones[0]>0 && bones[1]>0 && bones[2]>0 && clips_error==nil
    built:=Match_Built{key=key,error=.Invalid}
    at:=0
    for &clip,i in content.profile.clips {
        if !found {break}
        names,members:=match_source_clips(&clip)
        handles:[MATCH_BLEND]lib.Clip
        for name,k in names[:members] {
            handle:=lib.clip_find(&library.lib,source_clip_name(source,source_effective(clip.animation,info.animation,source),base.name_hash(name)))
            if handle==0 || int(handle)>library.clip_count {
                found=false
                if members>1 {built.fault={kind=.Missing,source=i32(i),member=i32(k)}}
                break
            }
            handles[k]=handle+lib.Clip(library.clip_count if clip.loop else 0)
            duration:=lib.clip_duration(&library.lib,handle)
            if k>0 && abs(duration-lib.clip_duration(&library.lib,handles[0]))>1/info.rate {
                found=false;built.fault={kind=.Duration,source=i32(i),member=i32(k),durations={lib.clip_duration(&library.lib,handles[0]),duration}}
                break
            }
        }
        if !found {break}
        rates:=[2]f32{clip.min_rate,clip.max_rate}
        if members==1 {clips[at]={clips={0=handles[0]},modes=clip.modes,entry=clip.entry,speed=clip.speed,rates=rates};at+=1;continue}
        for sample in content.profile.samples {
            if int(sample.source)==i {clips[at]={clips=handles,weights=sample.weights,modes=clip.modes,speed=sample.speed,rates=rates};at+=1}
        }
    }
    if found {
        rest,rest_error:=make([]mm.Transform,len(state.rest));defer delete(rest)
        if rest_error!=nil {built.error=.Out_Of_Memory} else {
            copy(rest,state.rest[:]);rest[0]=mm.TRANSFORM_IDENTITY
            body:=lib.body_map_empty();body.forward,body.up=state.forward,state.up
            for bone,part in state.body {if bone>0 {body.bones[part]=bone}}
            for part,i in ([3]lib.Body_Part{.Foot_L,.Foot_R,.Pelvis}) {
                if body.bones[part]>=0 {continue}
                taken:=false;for other in body.bones {if int(other)==bones[i] {taken=true}}
                if !taken {body.bones[part]=i32(bones[i])}
            }
            rig:=lib.Match_Rig{skeleton={parents=state.parents[:],names=state.targets[:],rest=rest},body=body,left_foot=i32(bones[0]),right_foot=i32(bones[1]),hips=i32(bones[2])}
            weights:=lib.Match_Weights{.Foot_Position=info.foot_position,.Foot_Velocity=info.foot_velocity,.Hip_Velocity=info.hip_velocity,.Body_Velocity=info.body_velocity,.Trajectory_Position=info.trajectory_position,.Trajectory_Direction=info.trajectory_direction}
            // Each clip names its landing with a marker of its own: every one of that name.
            event:=make([dynamic]u32,context.temp_allocator)
            if landing:=base.text_get(info.landing_marker[:]);landing!="" {
                name:=base.name_hash(landing)
                for marker,k in library.markers {if marker==name {append(&event,u32(k))}}
            }
            built.error=lib.match_database_build(&built.database,&library.lib,rig,clips,info.rate,weights,int(info.memory)*1024,event[:],allocator)
        }
    }
    if append(&content.databases,built)!=1 {lib.match_database_free(&built.database);return nil,.Out_Of_Memory,{}}
    last:=&content.databases[len(content.databases)-1]
    return &last.database if last.error==.None else nil,last.error,last.fault
}

@(private)
match_play_emit :: proc(state:^Playing,events:^Animation_Events,playback:^Playback,kind:Animation_Play_Event_Kind,clip,other:u64,problems:^core.Problems) {
    if events==nil || playback==nil {return}
    if !program_array_reserve(&events.plays.items,max(len(playback.states)*PLAY_EVENT_BATCH,PLAY_EVENT_BATCH)) || len(events.plays.items)>=cap(events.plays.items) {
        core.report(problems,state.entity,"animation.play_events","an %v event of a clip played by match_play on this entity was lost: memory ran out, or the rigs of the world gave more play events in this tick than fit; free memory, or play fewer clips per tick",kind)
        return
    }
    append(&events.plays.items,Animation_Play_Event{state.entity,kind,clip,other})
}

// Moves the root of the pose of a rig that matches to where its spring left it from the body: the
// bones right under the transform of the rig, which is placed in the world, that a clip poses.
@(private)
match_lag_apply :: proc(state:^Playing,placed:mm.Transform) {
    lag:=state.program.match.lag
    if lag=={} || len(state.bindings)!=len(state.parents) {return}
    local:=mm.transform_inverse_vector(placed,lag)
    if !finite(local.x) || !finite(local.y) || !finite(local.z) {return}
    for parent,b in state.parents {if parent==0 && b>0 && state.bindings[b].target!=0 {state.local[b].position+=local}}
}

// Whether a marker named name of a clip that does not loop lies in (from,to].
@(private)
match_marker_crossed :: proc(library:^host.Content_Animation,clip:lib.Clip,name:u64,from,to:f32) -> bool {
    for marker in lib.clip_markers(&library.lib,clip) {
        if int(marker.id)<len(library.markers) && library.markers[marker.id]==name && marker.time>from && marker.time<=to {return true}
    }
    return false
}

// Chooses the clip and time the rig plays in this tick and writes them as a program of one clip.
// facing is the forward of the body of the rig in the world.
@(private)
match_output :: proc(state:^Playing,output:^Program_Output,content:^Match_Content,library:^host.Content_Animation,source:base.Asset_Id,dt:f32,goals:[]Match_Goal,plays:[]Match_Play,facing:mm.Vec3,app:^host.App,events:^Animation_Events,playback:^Playback,problems:^core.Problems) -> bool {
    runtime:=&state.program;m:=&runtime.match;info:=content.profile.info
    goal:Match_Goal;has_goal:=false
    for value in goals {if value.rig==state.entity {goal,has_goal=value,true}}
    mode:=goal.mode if has_goal else m.mode
    db,built,fault:=match_database(content,library,state,source,app.allocator)
    // A rig binds its skeleton after its first program: until then it plays the first clip.
    if db==nil && len(state.parents)>=2 {
        name:[base.ASSET_ID_TEXT]u8;path:=host.assets_name(app.assets,content.id,&name)
        names:[MATCH_BLEND]string
        if fault.kind!=.None && int(fault.source)<len(content.profile.clips) {names,_=match_source_clips(&content.profile.clips[fault.source])}
        #partial switch built {
        case .Memory_Limit: core.report(problems,state.entity,"animation.match_memory","the motion matching database of %s for this skeleton keeps more than its memory of %d KiB; lower its rate, give it fewer or shorter clips, or raise its memory",path,info.memory)
        case .Out_Of_Memory: memory_problem(problems,state.entity,"its motion matching database")
        case .Invalid:
            switch fault.kind {
            case .Missing: core.report(problems,state.entity,"animation.match_blend","%s blends %s with %s, a clip its library does not have; name in blend clips of its library (animation.inspect lists them)",path,names[0],names[fault.member])
            case .Duration: core.report(problems,state.entity,"animation.match_blend","%s blends %s (%.3f s) with %s (%.3f s), but the clips of a blend last the same within a row of its rate (%.3f s); blend clips of one duration, or retime one with animation.clip.edit",path,names[0],fault.durations[0],names[fault.member],fault.durations[1],1/info.rate)
            case .None: core.report(problems,state.entity,"animation.match_database","%s cannot match on this rig: its left_foot, right_foot or hips is not a bone of this skeleton, or a clip of it is missing, lasts a single pose or does not move the skeleton; name bones of the skeleton (animation.asset.inspect lists them), and give it clips of the library that move",path)
            }
        }
    }
    library_name :: proc(source:base.Asset_Id,info:Match_Info,name:u64) -> u64 {return source_clip_name(source,source_effective({},info.animation,source),name)}
    previous:=m.clip
    start:=f32(-1);fade:=info.blend
    begin :: proc(m:^Match_Playing,state:^Playing,library:^host.Content_Animation,play:Match_Play,clip:u64,runtime:^Program_Playing) -> f32 {
        start:f32
        handle:=lib.clip_find(&library.lib,clip)
        duration:=lib.clip_duration(&library.lib,handle)
        switch play.entry {
        case .Start:
        case .Keep_Time: start=clamp(state.time,0,duration)
        case .Match_Phase: if time,ok:=lib.sync_time(&library.lib,handle,runtime.current_phase);ok {start=clamp(time,0,duration)}
        }
        m.phase,m.clip,m.range,m.loop,m.mode,m.play,m.finished,m.last=.Play,clip,-1,false,play.mode,play,false,start
        return start
    }
    stop:=false
    for play in plays {
        if play.rig!=state.entity {continue}
        if play.clip==0 {stop,m.waiting=true,false;continue}
        clip:=library_name(source,info,play.clip)
        if lib.clip_find(&library.lib,clip)==0 {
            core.report(problems,state.entity,"animation.match_clip","match_play asked this rig for a clip the library of its .match does not have; name a clip of its library (animation.inspect lists them)")
            continue
        }
        if m.phase==.Play && play.priority<m.play.priority {
            core.report(problems,state.entity,"animation.match_busy","match_play asked this rig for a clip of priority %d while one of priority %d plays; raise its priority, or wait for the Exited event of the one playing",play.priority,m.play.priority)
            continue
        }
        if play.wait && runtime.elapsed<runtime.fade {m.pending,m.waiting=play,true;continue}
        if m.phase==.Play {match_play_emit(state,events,playback,.Exited,m.clip,clip,problems)}
        match_play_emit(state,events,playback,.Entered,clip,m.clip if m.phase==.Play else 0,problems)
        start=begin(m,state,library,play,clip,runtime);fade=play.fade;m.waiting=false
    }
    if start<0 && m.waiting && runtime.elapsed>=runtime.fade {
        clip:=library_name(source,info,m.pending.clip)
        if m.phase==.Play {match_play_emit(state,events,playback,.Exited,m.clip,clip,problems)}
        match_play_emit(state,events,playback,.Entered,clip,m.clip if m.phase==.Play else 0,problems)
        start=begin(m,state,library,m.pending,clip,runtime);fade=m.pending.fade;m.waiting=false
    }
    // The root of the pose follows the body by a spring: a change of velocity the body makes at
    // once the root takes in over the half-life, never farther from the body than lag nor into
    // what blocks it. It closes on the body only while the pose walks, by at most MATCH_LAG_CLOSE
    // of its speed, so a pose that stands does not slide its feet toward the body. Matching
    // follows the velocity of that root.
    velocity:=m.body+m.lag_velocity
    if has_goal && dt>0 {
        body:=mm.Vec3{goal.velocity.x,0,goal.velocity.z}
        if info.lag>0 {
            if m.told {m.lag_velocity-=body-m.body}
            before:=m.lag
            m.lag,m.lag_velocity=mm.spring_critical(m.lag,m.lag_velocity,mm.Vec3{},mm.spring_omega(info.lag_half_life),dt)
            if from,to:=linalg.length(before),linalg.length(m.lag);to<from {
                if closing:=MATCH_LAG_CLOSE*m.speed*m.rate*dt;from-to>closing {
                    m.lag=before*((from-closing)/from)
                    m.lag_velocity=(m.lag-before)/dt
                }
            }
            if length:=linalg.length(m.lag);length>info.lag {
                away:=m.lag/length;m.lag=away*info.lag
                if along:=linalg.dot(m.lag_velocity,away);along>0 {m.lag_velocity-=away*along}
            }
            if wall:=linalg.normalize0(mm.Vec3{goal.wall.x,0,goal.wall.z});wall!={} {
                if into:=linalg.dot(m.lag,wall);into<0 {m.lag-=wall*into}
                if into:=linalg.dot(m.lag_velocity,wall);into<0 {m.lag_velocity-=wall*into}
            }
        } else {m.lag,m.lag_velocity={},{}}
        m.body,m.told=body,true
        velocity=body+m.lag_velocity
        lib.match_trail_add(&m.trail,velocity,dt)
    }
    lib.match_recent_advance(&m.recent,dt,info.reselect)
    if m.since<info.hold {m.since+=dt}
    released:=false
    if start<0 && m.phase==.Play {
        if state.ended && !m.finished {m.finished=true;match_play_emit(state,events,playback,.Finished,m.clip,0,problems)}
        reached:=match_marker_crossed(library,lib.clip_find(&library.lib,m.clip),m.play.marker,m.last,state.time) if m.play.marker!=0 else state.ended || state.duration>0 && state.time>=m.play.phase*state.duration
        m.last=state.time
        if reached || stop || has_goal && mode!=m.play.mode {m.phase=.Matching;released=true;match_play_emit(state,events,playback,.Exited,m.clip,0,problems)}
    }
    if db!=nil {m.landing_modes=db.event_modes}
    if start<0 && m.phase!=.Play && db!=nil {
        m.timer-=dt
        bit:=u32(1)<<mode
        // A body in the air whose landing physics predicts plays toward the landing marker of a
        // clip of its mode, at the rate that reaches it when the body lands.
        time_to_land:=goal.time_to_land if has_goal else 0
        event:=time_to_land>0 && lib.match_event_serves(db,bit)
        playing:=int(m.range) if m.range>=0 && int(m.range)<len(db.ranges) else -1
        ahead:=lib.match_event_ahead(db,playing,state.time) if playing>=0 else -1
        // A clip toward its marker that passes it in the air, or whose landing is no longer known,
        // matches again, and searches at once; one in another mode matches again too.
        left:=m.phase==.Landing && mode==m.mode && (!event || ahead<0)
        if left || m.phase!=.Matching && has_goal && mode!=m.mode {m.phase=.Matching}
        // The body lands with a clip at or past its landing marker: it plays on in the mode it
        // landed in.
        if has_goal && mode!=m.mode && playing>=0 && db.ranges[playing].modes&bit==0 && lib.match_event_ahead(db,playing,0)>=0 && ahead<=dt*m.rate+.5/db.rate {m.phase,m.mode=.Landed,mode}
        entering:=has_goal && mode!=m.mode && m.clip!=0 && lib.match_serves(db,bit,true)
        current:=playing if playing>=0 && (db.ranges[playing].modes&bit!=0 || m.phase==.Landed) else -1
        row:=lib.match_row(db,current,state.time) if current>=0 else -1
        // A clip that does not loop is left once it ends or nears its end, before the trajectory runs
        // past it: its own pose would win every search from there, frozen. One toward its landing
        // marker, or on from it, is left when it ends.
        ending:=false
        if current>=0 && !db.ranges[current].loop {
            r:=db.ranges[current];tail:=int(cmath.ceil(lib.MATCH_HORIZON[lib.MATCH_TRAJECTORY-1]*db.rate))
            ending=state.ended || m.phase==.Matching && int(r.count)>tail+1 && row>=int(r.first+r.count)-tail
        }
        // With stationary_speed, a body that stands plays the clips that stand and one that moves
        // those that travel, whether they loop or not; an entry clip plays whatever the body does.
        filter_stationary:=info.stationary_speed>0 && has_goal && !entering && db.still_modes&bit!=0 && db.moving_modes&bit!=0
        moving:=filter_stationary && linalg.length(velocity)>info.stationary_speed
        // A body slow now that its trajectory carries on within the first horizon moves too: one
        // that turns around passes through rest for a tick, where the clips that stand would plant it.
        trajectory:lib.Match_Trajectory
        traced:=false
        if filter_stationary && !moving {
            trajectory=lib.match_trajectory(velocity,goal.desired,goal.acceleration,goal.braking,facing,goal.facing,goal.turn_rate,goal.wall,&m.trail)
            traced=true
            moving=linalg.length(trajectory.positions[0])>info.stationary_speed*lib.MATCH_HORIZON[0]
        }
        // A body that starts or stops searches in that tick instead of waiting for the interval: a
        // loop that does not move as the body does would hold its legs still, or walk in place. A
        // clip that plays once goes on until it ends or a search leaves it.
        incompatible:=filter_stationary && current>=0 && db.ranges[current].loop && (db.ranges[current].speed>lib.MATCH_STILL)!=moving
        forced:=current<0 || released || entering || ending || incompatible || left
        if forced || m.timer<=0 && m.since>=info.hold {
            m.timer=info.interval
            request:=lib.Match_Request{query=lib.match_features(db,row) if row>=0 else {},modes=bit,min_rate=info.min_rate,max_rate=info.max_rate,rate=m.rate,entry=entering}
            request.filter_stationary,request.moving=filter_stationary,moving
            request.trajectory=trajectory if traced else lib.match_trajectory(velocity,goal.desired,goal.acceleration,goal.braking,facing,goal.facing,goal.turn_rate,goal.wall,&m.trail)
            // A clip that ends is left whole: a row of it a little earlier would play its tail
            // again.
            whole:=ending || info.keep_loop_phase && current>=0 && db.ranges[current].loop
            // The cost of playing on, which a jump has to beat by bias; none when nothing plays on.
            playing_on:=max(f32)
            searched:=request
            best,cost:=-1,max(f32)
            landing:=false
            // A clip past its landing marker in the air plays on unless a row fits better by bias:
            // a forced search would take whatever is left, a jump that faces the other way.
            passed:=false
            if event {
                // The clips toward the landing are weighed at their own rate, which then reaches
                // their marker. In the air the arc goes on: another clip toward the landing joins
                // it where it is.
                toward:=request
                toward.min_rate,toward.max_rate,toward.event,toward.event_rates=0,0,time_to_land,info.landing_rates
                if m.phase==.Landing && !entering {toward.event_from=max(ahead,0)}
                passed=row>=0 && !entering && ahead<0 && lib.match_event_ahead(db,current,0)>=0
                if m.phase==.Landing && row>=0 && !entering {
                    if _,inside:=lib.match_event_window(db,row,toward);inside {query,weights,_:=lib.match_query(db,toward,current);playing_on=lib.match_cost(db,row,query,weights)}
                } else if passed {
                    query,weights,_:=lib.match_query(db,request,current);playing_on=lib.match_cost(db,row,query,weights)
                }
                best,cost,_=lib.match_search(db,toward,row,whole,info.reselect,&m.recent)
                searched=toward
                // Entering the air with no entry start that lands in time (off a ledge, a short
                // fall), any row of its clips that does.
                if best<0 && entering {toward.entry=false;searched=toward;best,cost,_=lib.match_search(db,toward,row,whole,info.reselect,&m.recent)}
                landing=best>=0
            }
            if !landing && m.phase!=.Landing {
                if row>=0 && !entering && !ending {query,weights,_:=lib.match_query(db,request,current);playing_on=lib.match_cost(db,row,query,weights)}
                searched=request
                best,cost,_=lib.match_search(db,request,row,whole,info.reselect,&m.recent)
            }
            m.searches+=1;m.cost=min(cost,playing_on)
            if forced {m.searched={request=searched,row=i32(row),whole=whole,span=info.reselect,recent=m.recent,search=m.searches}}
            if best>=0 && (forced && !passed || playing_on==max(f32) || cost<playing_on-info.bias) {
                m.phase=.Landing if landing else .Matching
                range:=lib.match_range_of(db,best)
                if row>=0 {lib.match_recent_leave(&m.recent,row)}
                m.range,m.mode,m.loop=i32(range),mode,db.ranges[range].loop
                m.clip=lib.clip_data(&library.lib,db.ranges[range].clips[0]).name
                m.speed=db.ranges[range].speed
                m.travel_from,m.travel_to,m.travel_age=m.travel,linalg.normalize0(db.ranges[range].travel),0
                start=f32(best-int(db.ranges[range].first))/db.rate
                m.jumps+=1;m.since=0
            }
        }
    }
    // After a swap of library with nothing of its mode to search, the clip it played may not be in
    // the new one: it starts over from the first.
    if m.range<0 && m.phase!=.Play && m.clip!=0 && lib.clip_find(&library.lib,m.clip)==0 {m.clip=0}
    if m.clip==0 {
        if len(content.profile.clips)==0 {return false}
        first:=content.profile.clips[0]
        m.clip,m.loop,m.mode,m.range=source_clip_name(source,source_effective(first.animation,info.animation,source),base.name_hash(base.text_get(first.clip[:]))),first.loop,mode,-1
        start=0
    }
    m.rate=1
    // A loop follows the speed of the root of the pose; a clip that plays once (a jump, a landing)
    // keeps its own rate, or a body standing still would hold it, frozen, at min_rate.
    if m.phase!=.Play && m.range>=0 && m.loop && m.speed>lib.MATCH_STILL && has_goal && db!=nil && int(m.range)<len(db.ranges) {
        least,most:=lib.match_range_rates(db.ranges[m.range],info.min_rate,info.max_rate)
        m.rate=clamp(linalg.length(velocity)/m.speed,least,most)
    }
    // A clip toward its landing marker follows each tick the time to land physics predicts.
    if m.phase==.Landing && db!=nil && m.range>=0 && int(m.range)<len(db.ranges) && has_goal && goal.time_to_land>0 {
        if ahead:=lib.match_event_ahead(db,int(m.range),start if start>=0 else state.time);ahead>0 {
            m.rate=clamp(ahead/goal.time_to_land,info.landing_rates[0],info.landing_rates[1])
        }
    }
    if m.phase==.Play || m.range<0 {
        m.speed,m.travel,m.travel_from,m.travel_to=0,{},{},{}
    } else {
        m.travel=travel_turn(m.travel_from,m.travel_to,lib.inertial_remaining(m.travel_age,info.blend))
        if m.travel_age<info.blend {m.travel_age+=dt}
    }
    if !program_output_prepare(output,1,1) {runtime.error=.Out_Of_Memory;return false}
    program_output_reset(output)
    output.asset=source;output.count=1
    group:=&output.groups[0];group^={}
    group.weight,group.root_weight,group.mode,group.key=1,1,.Independent,1
    group.count=1;group.leaves[0]={clip=m.clip,weight=1,speed=m.rate,loop=m.loop,start=max(start,0)}
    // A blended sample plays its clips together at its weights, in phase.
    if m.phase!=.Play && db!=nil && m.range>=0 && int(m.range)<len(db.ranges) && db.ranges[m.range].weights!={0=1} {
        r:=db.ranges[m.range]
        group.count,group.mode=0,.Weighted
        for clip,k in r.clips {
            if r.weights[k]<=0 {continue}
            group.leaves[group.count]={clip=lib.clip_data(&library.lib,clip).name,key=u32(k)+1,weight=r.weights[k],speed=m.rate,loop=true,sync=true,start=max(start,0)}
            group.count+=1
        }
    }
    output.instruction_count=1;output.instructions[0]={kind=.Clip,group=0,root_weight=1}
    if start>=0 {
        runtime.epoch+=1
        if previous!=0 && fade>0 && len(state.local)>0 {
            if len(runtime.from)!=len(state.local) && resize(&runtime.from,len(state.local))!=nil {runtime.error=.Out_Of_Memory;return false}
            copy(runtime.from[:],runtime.current[:] if len(runtime.current)==len(state.local) && runtime.history_dt>0 else state.local[:])
            if !program_curves_prepare(runtime,len(state.curves)) {runtime.error=.Out_Of_Memory;return false}
            copy(runtime.from_curves[:],runtime.prior_curves[:] if len(runtime.prior_curves)==len(state.curves) else state.curves[:])
            runtime.elapsed,runtime.fade=0,fade
            runtime.capture=true
        }
    }
    return true
}
