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
import "base:runtime"

// The locomotion of a .character plays by motion matching over its clips: every interval it looks
// for the frame whose feet, hips and trajectory (the @foot_l, @foot_r and @pelvis of the body of
// the skeleton) are closest to what the body does and is asked to do, and jumps there with an
// inertial blend. The body is told each tick by match_goal (the animation_physics plugin tells it
// from the Character); the locomotion mode of the goal picks the clips that serve it, and entering
// a mode searches the starts of its entry clips (a jump, a landing). An action without a layer
// (play) takes the whole body from the search through the same inertial blend (a vault, a hit, a
// death), and matching goes on when it ends.

MATCH_CLIPS :: 64
// Share of the speed the pose walks at that its root closes on the body by, with a lag.
MATCH_LAG_CLOSE :: .5

Match_Info :: struct {
    rate:f32 `mirai:"unit=1/s"`,       // rows of the database per second of clip
    interval:f32 `mirai:"unit=s"`,     // between searches
    blend:f32 `mirai:"unit=s"`,        // of the inertial blend of a jump
    bias:f32,                          // of cost a jump has to save over playing on
    min_rate,max_rate:f32,             // of the speed a clip that travels plays at to follow the body, unless its source has its own
    memory:u32 `mirai:"unit=KiB"`,     // most the database of one skeleton keeps
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
    foot_position=.75,foot_velocity=1,hip_velocity=1,body_velocity=1,trajectory_position=2,trajectory_direction=1.5,
    reselect=.3,hold=.1,lag_half_life=.2,
    landing_marker={0='l',1='a',2='n',3='d'},landing_rates={.5,2},
}
// Clips a blended source mixes, and samples of blends the locomotion of a .character keeps.
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
// min_rate and max_rate, when positive, replace those of the .character for it and its samples: a set
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
    if len(profile.clips)>MATCH_CLIPS || len(profile.samples)>MATCH_SAMPLES || info.memory==0 {return false}
    for value in ([19]f32{info.rate,info.interval,info.blend,info.bias,info.min_rate,info.max_rate,info.foot_position,info.foot_velocity,info.hip_velocity,info.body_velocity,info.trajectory_position,info.trajectory_direction,info.stationary_speed,info.reselect,info.hold,info.lag,info.lag_half_life,info.landing_rates[0],info.landing_rates[1]}) {if !finite(value) || value<0 {return false}}
    if info.rate<=0 || info.rate>lib.FRAMES_MAX_RATE || info.min_rate<=0 || info.min_rate>info.max_rate || info.lag>0 && info.lag_half_life<=0 {return false}
    if !blend_text_valid(info.landing_marker[:],true) || info.landing_rates[0]<=0 || info.landing_rates[0]>info.landing_rates[1] {return false}
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
// What makes a blended source unplayable with a library: a clip it does not have, or two clips
// of a source (member 0 and member) that last more than a row of the database apart.
@(private)
Match_Blend_Fault :: struct {kind:enum u8 {None,Missing,Duration},source,member:i32,durations:[2]f32}
// What the body does and is asked to do in this tick, for a rig that plays the locomotion of a .character: mode is its
// locomotion mode; velocity, where it goes; desired, the velocity its walk heads to at
// acceleration (braking toward zero); facing, where it turns to at turn_rate rad/s (0: at once);
// wall, the normal of what blocks it, out of that (zero: nothing), which neither its trajectory
// nor the root of its pose go into; time_to_land, the seconds until a body in the air lands (0:
// none known), which the landing marker of the .character plays toward. World axes, m/s. The rig faces
// -Z of its transform.
Match_Goal :: struct {rig:core.Entity,mode:u16,velocity,desired,facing,wall:mm.Vec3,acceleration,braking,turn_rate,time_to_land:f32}

// The whole-body action that plays on a rig instead of the search in this tick: clip, its name in
// the library the .character plays; starting, it begins in this tick; fade_in and fade_out, the
// seconds of the inertial blends into it and back to the search; root, its root motion policy.
@(private)
Match_Inject :: struct {active,starting:bool,clip:u64,fade_in,fade_out:f32,root:Root_Motion_Policy}

// Tells the matching of a rig what its body does in this tick.
match_goal :: proc(requests:^Animation_Requests,goal:Match_Goal) {
    if requests==nil {return}
    valid:=goal.rig!=core.NONE && goal.mode<=31
    for v in ([4]mm.Vec3{goal.velocity,goal.desired,goal.facing,goal.wall}) {valid&&=finite(v.x) && finite(v.y) && finite(v.z)}
    for value in ([4]f32{goal.acceleration,goal.braking,goal.turn_rate,goal.time_to_land}) {valid&&=finite(value) && value>=0}
    if !valid {core.refuse(&requests.match_goals);return}
    core.offer(&requests.match_goals,goal)
}
// What the matching of a rig plays. clip is base.name_hash of its name; speed, m/s the pose
// walks forward at (that of the clip by its rate); mode, the locomotion mode of that clip; forced,
// a whole-body action plays instead of the search; velocity, the one of the root of the pose that matching follows
// (that of the body with the lag of its spring), and lag, where that root is from the body. World
// axes. landing_modes: bit m for each mode m whose clips play toward the landing marker, which
// match_goal.time_to_land times.
// travel: the direction its clip moves in, rig axes (unit; zero for one that stands or that an action plays).
Animation_Match :: struct {clip:u64,time,rate,speed,cost:f32,mode:u16,forced:bool,searches,jumps:u32,velocity,lag,travel:mm.Vec3,landing_modes:u32}

// The direction remaining of the way from to back toward from, turning about the vertical: a clip
// that backs off after one that went forward turns through the side and never through zero.
@(private)
travel_turn :: proc "contextless" (from,to:mm.Vec3,remaining:f32) -> mm.Vec3 {
    if from=={} || to=={} || !(remaining>0) {return to}
    turn:=cmath.atan2(linalg.cross(from,to).y,linalg.dot(from,to))
    return linalg.normalize0(mm.quat_rotate(linalg.quaternion_angle_axis_f32(turn*(1-remaining),{0,1,0}),from))
}

// False for an entity that plays no locomotion of a .character.
animation_match :: proc(playback:^Playback,entity:core.Entity) -> (value:Animation_Match,ok:bool) {
    state:=constraint_playing(playback,entity) if playback!=nil else nil
    if state==nil || !state.program.matched || !state.program.ready {return}
    m:=state.program.match
    return {clip=m.clip,time=state.time,rate=m.rate,speed=m.speed*m.rate,cost=m.cost,mode=m.mode,forced=m.phase==.Play,searches=m.searches,jumps=m.jumps,velocity=m.body+m.lag_velocity,lag=m.lag,travel=m.travel,landing_modes=m.landing_modes},true
}

// What the clip of a rig plays for: matching; a whole-body action (Play); one toward its landing
// marker, at the rate that reaches it when the body lands; or one that reached it as the body
// landed and plays on in the mode it landed in, until it ends or a search leaves it.
Match_Phase :: enum u8 {Matching,Play,Landing,Landed}

// The matching of a rig between ticks.
Match_Playing :: struct {
    range:i32,     // of the database its clip is; -1: one an action plays, or none
    clip:u64,      // name in the library of the clip it plays; 0: none yet
    loop:bool,
    phase:Match_Phase,
    mode:u16,      // the one its clip serves
    driven_from,driven_to:f32, // phase Play: the times of its clip its action goes between in this tick
    release_fade:f32,          // phase Play: seconds of the blend back to the search
    root:Root_Motion_Policy,   // phase Play: of the action
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

// The matching of a rig whose Animation.library swaps the clips of its .character (a weapon's set): it
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
// plays no locomotion of a .character, before its first tick or when its database could not be built.
animation_match_database :: proc(matches:^Character_Assets,library:^host.Content_Animation,state:^Playing) -> ^lib.Match_Database {
    if matches==nil || library==nil || state==nil || !state.program.matched || !state.program.ready {return nil}
    key:=match_database_key(library,state,state.program.library)
    for &content in matches.contents {
        if content.id!=state.program.asset || content.revision!=state.program.revision || !content.valid {continue}
        for &built in content.databases {if built.key==key && built.error==.None {return &built.database}}
    }
    return nil
}

// The database of a library for the skeleton of a rig, built the first time a rig of that
// skeleton loads it.
@(private)
match_database :: proc(content:^Character_Content,library:^host.Content_Animation,state:^Playing,source:base.Asset_Id,allocator:mem.Allocator) -> (^lib.Match_Database,lib.Match_Build_Error,Match_Blend_Fault) {
    if library==nil || len(state.parents)<2 || len(state.rest)!=len(state.parents) {return nil,.Invalid,{}}
    key:=match_database_key(library,state,source)
    for &built in content.databases {if built.key==key {return &built.database if built.error==.None else nil,built.error,built.fault}}
    context.allocator=allocator
    info:=content.set.match.info;animation:=content.set.info.animation
    bones:=[3]int{int(state.body[.Foot_L]),int(state.body[.Foot_R]),int(state.body[.Pelvis])}
    // A source without blend is one clip of the database; a blend, one per sample of it.
    count:=len(content.set.match.samples)
    for &clip in content.set.match.clips {if clip.blend[0][0]==0 {count+=1}}
    clips,clips_error:=make([]lib.Match_Clip,count);defer delete(clips)
    found:=bones[0]>0 && bones[1]>0 && bones[2]>0 && clips_error==nil
    built:=Match_Built{key=key,error=.Invalid}
    at:=0
    for &clip,i in content.set.match.clips {
        if !found {break}
        names,members:=match_source_clips(&clip)
        handles:[MATCH_BLEND]lib.Clip
        for name,k in names[:members] {
            handle:=lib.clip_find(&library.lib,source_clip_name(source,source_effective(clip.animation,animation,source),base.name_hash(name)))
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
        for sample in content.set.match.samples {
            if int(sample.source)==i {clips[at]={clips=handles,weights=sample.weights,modes=clip.modes,speed=sample.speed,rates=rates};at+=1}
        }
    }
    if found {
        rest,rest_error:=make([]mm.Transform,len(state.rest));defer delete(rest)
        if rest_error!=nil {built.error=.Out_Of_Memory} else {
            copy(rest,state.rest[:]);rest[0]=mm.TRANSFORM_IDENTITY
            body:=lib.body_map_empty();body.up={0,1,0}
            for bone,part in state.body {if bone>0 {body.bones[part]=bone}}
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

// Chooses the clip and time the rig plays in this tick and writes them as a program of one clip.
// facing is the -Z of the rig in the world.
@(private)
match_output :: proc(state:^Playing,output:^Program_Output,content:^Character_Content,library:^host.Content_Animation,source:base.Asset_Id,dt:f32,goals:[]Match_Goal,inject:Match_Inject,facing:mm.Vec3,assets:^host.Assets,allocator:runtime.Allocator,problems:^core.Problems) -> bool {
    runtime:=&state.program;m:=&runtime.match;info:=content.set.match.info
    goal:Match_Goal;has_goal:=false
    for value in goals {if value.rig==state.entity {goal,has_goal=value,true}}
    mode:=goal.mode if has_goal else m.mode
    db,built,fault:=match_database(content,library,state,source,allocator)
    // A rig binds its skeleton after its first program: until then it plays the first clip.
    if db==nil && len(state.parents)>=2 {
        name:[base.ASSET_ID_TEXT]u8;path:=host.assets_name(assets,content.id,&name)
        names:[MATCH_BLEND]string
        if fault.kind!=.None && int(fault.source)<len(content.set.match.clips) {names,_=match_source_clips(&content.set.match.clips[fault.source])}
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
    previous:=m.clip
    start:=f32(-1);fade:=info.blend
    // A whole-body action takes the rig from the search through an inertial blend; its clock is the
    // action's (program_players takes it from driven_from and driven_to).
    injected:=inject.active && library!=nil && lib.clip_find(&library.lib,inject.clip)!=0
    if injected {
        if inject.starting || m.phase!=.Play || m.clip!=inject.clip {
            m.phase,m.clip,m.range,m.loop=.Play,inject.clip,-1,false
            start,fade=0,inject.fade_in
        }
        m.release_fade,m.root=inject.fade_out,inject.root
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
    // The action ended or was stopped: the search takes the rig back from its pose.
    if !injected && m.phase==.Play {
        m.phase=.Matching;released=true
        if m.release_fade>0 {fade=m.release_fade}
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
        if len(content.set.match.clips)==0 {return false}
        first:=content.set.match.clips[0]
        m.clip,m.loop,m.mode,m.range=source_clip_name(source,source_effective(first.animation,content.set.info.animation,source),base.name_hash(base.text_get(first.clip[:]))),first.loop,mode,-1
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
    output^={asset=source,count=1}
    group:=&output.groups[0]
    group.weight,group.root_weight,group.mode,group.key=1,1,.Independent,1
    group.count=1;group.leaves[0]={clip=m.clip,weight=1,speed=m.rate,loop=m.loop,start=max(start,0),driven=m.phase==.Play,root=m.root}
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
