package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import "core:mem"
import "core:simd"
import "core:slice"
import math "mirai:std/math"

// Motion matching: every frame of a set of clips is a row of features (where
// the feet are and how they move, how the hips and the body move, where the body
// was a moment ago and where it goes in the next second), normalized per feature
// so that each kind weighs what its weight says. A query with the same features
// finds the row closest to what the body does and is asked to do. The features
// are in the frame of the character: its position on the ground and its facing,
// -Z forward and Y up, so a row does not depend on where or toward where the clip
// was made.

MATCH_LANES :: 8 // f32x4 per row: 31 features and one of padding
MATCH_TRAJECTORY :: 3
MATCH_HORIZON :: [MATCH_TRAJECTORY]f32{1.0/3,2.0/3,1} // seconds ahead of each trajectory point
MATCH_PAST :: f32(1.0/3)                               // seconds behind of the past point

Match_Feature :: enum u8 {Foot_Position,Foot_Velocity,Hip_Velocity,Body_Velocity,Trajectory_Position,Trajectory_Direction}
Match_Weights :: [Match_Feature]f32
MATCH_WEIGHTS_DEFAULT :: Match_Weights{.Foot_Position=.75,.Foot_Velocity=1,.Hip_Velocity=1,.Body_Velocity=1,.Trajectory_Position=1,.Trajectory_Direction=1.5}
// First and end feature of each kind in a row. The trajectory positions are the past point and
// then those of MATCH_HORIZON, x and z each; the body velocity is x and z.
MATCH_FEATURES :: [Match_Feature][2]int{.Foot_Position={0,6},.Foot_Velocity={6,12},.Hip_Velocity={12,15},.Body_Velocity={15,17},.Trajectory_Position={17,25},.Trajectory_Direction={25,31}}
@(private) MATCH_AT_VELOCITY :: 15
@(private) MATCH_AT_PAST :: 17
@(private) MATCH_AT_POINTS :: 19
@(private) MATCH_AT_DIRECTIONS :: 25
#assert(MATCH_AT_DIRECTIONS+2*MATCH_TRAJECTORY<=MATCH_LANES*4)
// Smallest spread of a kind of feature: a kind every row shares (the facing of clips in place)
// does not turn a small difference of the query into a huge cost.
MATCH_SPREAD_MIN :: .1
// A database of more rows keeps the bounds of runs of rows, small and large, and the search
// skips a run whose bound costs more than the best row found.
MATCH_LINEAR_ROWS :: 1024
MATCH_BOUND_SMALL :: 16
MATCH_BOUND_LARGE :: 64
// Seconds from its start in which an entry clip can be entered.
MATCH_ENTRY_SPAN :: .1
// Seconds of its end that a clip which does not loop, shorter than the trajectory, keeps out of
// the search.
MATCH_TAIL_MIN :: .3
// m/s at or below which a clip stands still.
MATCH_STILL :: .05
// Rows a rig left that a search remembers.
MATCH_RECENT :: 8
// Spans of MATCH_PAST seconds a trail keeps how far the body went in, whatever the tick.
MATCH_TRAIL :: 8
// Clips a search notes the best row of.
MATCH_CANDIDATES :: 16

// Why a search did not give the best row of a clip. None: it gave it; Cost: another cost less;
// Mode: the clip serves none of the modes; Entry: an entry clip while not entering, or one that is
// not while entering; Stationary: it travels while the body stands, or stands while it moves;
// Reselect: its rows are near the one playing or among those just left; Event: none of its rows
// has the marker of the event ahead; Window: none reaches its marker when the event comes at a rate
// of the event, or within the arc the playing row is in (match_search).
Match_Reject :: enum u8 {None,Cost,Mode,Entry,Stationary,Reselect,Event,Window}
// The best row of a clip in a search, the rate it plays at, its cost split by kind of feature
// (cost is their sum) and why the search did not give it.
Match_Candidate :: struct {row:i32,cost,rate:f32,costs:[Match_Feature]f32,reason:Match_Reject}
// The clips a search weighed, one per range by its best row: those it could give, least cost first
// (the first is the row the search gives), then those of its modes it left out, then those of other
// modes, each least cost first.
Match_Candidates :: struct {items:[MATCH_CANDIDATES]Match_Candidate,count:i32}

Match_Query :: [MATCH_LANES]simd.f32x4

// Clips a blended sample of the database mixes.
MATCH_BLEND :: 8

// A clip in the database, or a sample of a blend: clips[0] alone (no weights, or only weights[0]),
// or the clips with a weight above zero mixed in phase at their share of the sum of the weights,
// as the program mixes the leaves of a group. The clips of a blend loop; the sample lasts the mean
// of their durations by weight, and each frame of it is the blended pose at the same share of each.
// modes is the set of locomotion modes it serves, bit m for mode m; an entry clip starts one of
// them (a jump, a landing): it is searched only from its start, when the body enters the mode.
// speed, when positive, is the m/s it travels at instead of the one measured: an in-place clip
// goes that fast along its measured direction, or forward. rates, when rates[0] is positive, are
// the least and most rate it plays at to follow the body in place of those of a search: a set
// authored slower than it is played (a crouch), or one kept from playing faster than it was made.
Match_Clip :: struct {clips:[MATCH_BLEND]Clip,weights:[MATCH_BLEND]f32,modes:u32,entry:bool,speed:f32,rates:[2]f32}
// The rows of a clip or of a blended sample, with its clips and their weights as shares of 1.
// speed is how fast the body goes over the ground in it, m/s: that of its root, or for a clip in
// place the one its feet push at. rates: those of its Match_Clip.
Match_Range :: struct {clips:[MATCH_BLEND]Clip,weights:[MATCH_BLEND]f32,first,count:i32,modes:u32,loop,entry:bool,speed:f32,travel:math.Vec3,rates:[2]f32}
Match_Database :: struct {
    rate:f32,                      // rows per second of each clip
    features:[]simd.f32x4,         // MATCH_LANES per row, normalized
    mean,scale:[MATCH_LANES*4]f32, // raw = normalized*scale+mean
    ranges:[]Match_Range,
    rows:int,
    small,large:[]simd.f32x4,      // per run of MATCH_BOUND_SMALL or _LARGE rows: MATCH_LANES of its least, then of its greatest features; empty up to MATCH_LINEAR_ROWS rows
    events:[]f32,                  // per row, seconds of its clip to the next marker of the event (a landing); negative: none ahead. Empty: no clip has one
    // Bit m for each mode m with an entry clip, a clip with a marker of the event, a clip that is no
    // entry and stands (MATCH_STILL), and one that is no entry and travels.
    entry_modes,event_modes,still_modes,moving_modes:u32,
    allocator:mem.Allocator,
}
Match_Build_Error :: enum u8 {None,Invalid,Memory_Limit,Out_Of_Memory}
// What the features read of a skeleton: bones of the feet and the hips, and
// the body its clips are measured with. A rig faces -Z.
Match_Rig :: struct {skeleton:Skeleton,body:Body_Map,left_foot,right_foot,hips:i32}

// Where the body goes and went, raw, in the frame of its facing: its velocity now (m/s), where it
// was MATCH_PAST seconds before, and where it is and faces at each MATCH_HORIZON.
Match_Trajectory :: struct {velocity,past:math.Vec2,positions,directions:[MATCH_TRAJECTORY]math.Vec2}

// Rows a rig jumped away from, oldest first, and the seconds since it left each.
Match_Recent :: struct {rows:[MATCH_RECENT]i32,ages:[MATCH_RECENT]f32,count:i32}

// How far a body went horizontally in each of its last MATCH_TRAIL spans of MATCH_PAST/MATCH_TRAIL
// seconds, in a ring (next: where the next span goes), and in the span it is in, elapsed seconds
// of it.
Match_Trail :: struct {spans:[MATCH_TRAIL]math.Vec3,current:math.Vec3,elapsed:f32,next,count:i32}

match_database_free :: proc(db:^Match_Database) {
    if db.allocator.procedure!=nil {delete(db.features,db.allocator);delete(db.ranges,db.allocator);delete(db.small,db.allocator);delete(db.large,db.allocator);delete(db.events,db.allocator)}
    db^={}
}

// Bytes the database keeps.
match_database_size :: proc "contextless" (db:Match_Database) -> int {return (len(db.features)+len(db.small)+len(db.large))*size_of(simd.f32x4)+len(db.ranges)*size_of(Match_Range)+len(db.events)*size_of(f32)+size_of(Match_Database)}
// Bytes a database of rows over ranges clips keeps, with the event of each row or without.
match_database_bytes :: proc "contextless" (rows,ranges:int,events:=false) -> int {
    lanes:=rows*MATCH_LANES
    if rows>MATCH_LINEAR_ROWS {lanes+=2*MATCH_LANES*((rows+MATCH_BOUND_SMALL-1)/MATCH_BOUND_SMALL+(rows+MATCH_BOUND_LARGE-1)/MATCH_BOUND_LARGE)}
    return lanes*size_of(simd.f32x4)+ranges*size_of(Match_Range)+(rows*size_of(f32) if events else 0)+size_of(Match_Database)
}

// Samples every clip at about rate rows per second and keeps its features, refusing with
// Memory_Limit a database that would keep more than limit bytes (0: any). event holds the Marker.id
// of each marker of an event (a landing; each clip names it with one of its own; empty: none):
// when a clip that is not a blend has one, each row keeps the
// seconds to the next one of its clip. A clip that does not move the skeleton or lasts a single
// pose, a blend whose clips do not loop, or a rig without feet and hips gives Invalid; db is
// empty after an error.
match_database_build :: proc(db:^Match_Database,lib:^Library,rig:Match_Rig,clips:[]Match_Clip,rate:f32,weights:=MATCH_WEIGHTS_DEFAULT,limit:=0,event:[]u32={},allocator:=context.allocator) -> (error:Match_Build_Error) {
    match_database_free(db)
    error=.Invalid
    n:=len(rig.skeleton.parents)
    if n==0 || len(clips)==0 || !anim_finite(rate) || rate<=0 || rate>FRAMES_MAX_RATE || !skeleton_validate(rig.skeleton) {return}
    for bone in ([3]i32{rig.left_foot,rig.right_foot,rig.hips}) {if bone<0 || int(bone)>=n {return}}
    for weight in weights {if !anim_finite(weight) || weight<0 {return}}
    MAX_FRAMES :: 1<<20
    total,longest:=0,0
    events,blended_any:=false,false
    for c in clips {
        if !anim_finite(c.speed) || c.speed<0 || !match_rates_valid(c.rates) {return}
        duration,blended,valid:=match_clip_duration(lib,c)
        if !valid {return}
        count,_:=frames_layout(duration,rate,MAX_FRAMES)
        if count<2 {return}
        total+=count;longest=max(longest,count)
        if blended {
            blended_any=true
        } else if len(event)>0 {
            for marker in clip_markers(lib,c.clips[0]) {if slice.contains(event,marker.id) {events=true}}
        }
    }
    if limit>0 && match_database_bytes(total,len(clips),events)>limit {return .Memory_Limit}
    context.allocator=allocator
    ok:bool
    raw,e0:=make([][MATCH_LANES*4]f32,total);defer delete(raw)
    tracks,e1:=make([]Bone_Tracks,n);defer delete(tracks)
    local,e2:=make([]math.Transform,longest*n);defer delete(local)
    world,e3:=make([]math.Transform,(longest+1)*n);defer delete(world)
    rest,e4:=make([]math.Transform,n);defer delete(rest)
    ranges,e5:=make([]Match_Range,len(clips))
    defer if !ok {delete(ranges)}
    // A blend mixes its clips by bone: the bone of each track of the library, and a blend a bone.
    track_bones:[]i32;blend:[]Bone_Blend
    defer {delete(track_bones);delete(blend)}
    if blended_any {
        e6,e7:mem.Allocator_Error
        track_bones,e6=make([]i32,max(lib.track_count,0))
        blend,e7=make([]Bone_Blend,n)
        if e6!=nil || e7!=nil || !library_track_bones(lib,rig.skeleton.names,track_bones) {return .Out_Of_Memory}
    }
    if e0!=nil || e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil {return .Out_Of_Memory}
    copy(rest,rig.skeleton.rest)
    skeleton:=rig.skeleton;skeleton.rest=rest
    body_rig:=Body_Rig{parents=skeleton.parents,rest=rest,body=rig.body,root=-1}
    row:=0
    for c,i in clips {
        duration,blended,_:=match_clip_duration(lib,c)
        count,exact:=frames_layout(duration,rate,MAX_FRAMES)
        first:=0
        for w,k in c.weights {if w>0 {first=k;break}}
        frames:=Frames{rate=exact,bones=n,loop=clip_data(lib,c.clips[first]).loop==.Loop,local=local[:count*n]}
        weights:=[MATCH_BLEND]f32{0=1}
        if blended {
            if !match_sample_blend(lib,c,skeleton,track_bones,blend,frames) {return}
            sum:f32;for w in c.weights {sum+=w}
            for w,k in c.weights {weights[k]=w/sum}
        } else if !skeleton_bind(lib,c.clips[0],skeleton,tracks) || !frames_sample_clip(lib,c.clips[0],tracks,rest,nil,frames) {return}
        ground,grounded:=frames_ground(body_rig,frames,world);if !grounded {return}
        rest_world:=world[count*n:][:n]
        root:=int(ground.root)
        travel,speed:=ground.travel,linalg.length(ground.travel)
        if c.speed>0 {
            // Along the push of its feet; feet that do not push (a jump) leave where its body faces.
            if ground.in_place {
                direction,moving:=anim_unit(travel)
                if !moving || speed<=MATCH_STILL {direction=match_motion_facing({frames=frames,world=world[:count*n],rest=rest_world,root=root},0)}
                travel=direction*c.speed
            }
            speed=c.speed
        }
        motion:=Match_Motion{frames=frames,world=world[:count*n],rest=rest_world,root=root,in_place=ground.in_place,travel=travel}
        ranges[i]={clips=c.clips if blended else {0=c.clips[0]},weights=weights,first=i32(row),count=i32(count),modes=c.modes,loop=frames.loop,entry=c.entry,speed=speed,travel=travel,rates=c.rates}
        for frame in 0..<count {
            values:=&raw[row+frame]
            at:=f32(frame)
            here:=match_motion_body(motion,at)
            inverse:=math.quat_inverse(match_yaw(match_motion_facing(motion,at)))
            for bone,k in ([2]i32{rig.left_foot,rig.right_foot}) {
                position:=math.quat_rotate(inverse,match_motion_point(motion,int(bone),at)-here)
                velocity:=math.quat_rotate(inverse,match_motion_velocity(motion,int(bone),frame))
                for axis in 0..<3 {values[k*3+axis]=position[axis];values[6+k*3+axis]=velocity[axis]}
            }
            hips:=math.quat_rotate(inverse,match_motion_velocity(motion,int(rig.hips),frame))
            for axis in 0..<3 {values[12+axis]=hips[axis]}
            velocity:=math.quat_rotate(inverse,match_motion_body_velocity(motion,frame))
            past:=math.quat_rotate(inverse,match_motion_body(motion,at-MATCH_PAST*exact)-here)
            values[MATCH_AT_VELOCITY],values[MATCH_AT_VELOCITY+1]=velocity.x,velocity.z
            values[MATCH_AT_PAST],values[MATCH_AT_PAST+1]=past.x,past.z
            for horizon,k in MATCH_HORIZON {
                ahead:=at+horizon*exact
                position:=math.quat_rotate(inverse,match_motion_body(motion,ahead)-here)
                direction:=math.quat_rotate(inverse,match_motion_facing(motion,ahead))
                values[MATCH_AT_POINTS+k*2],values[MATCH_AT_POINTS+k*2+1]=position.x,position.z
                values[MATCH_AT_DIRECTIONS+k*2],values[MATCH_AT_DIRECTIONS+k*2+1]=direction.x,direction.z
            }
        }
        row+=count
    }
    features,e6:=make([]simd.f32x4,total*MATCH_LANES)
    if e6!=nil {return .Out_Of_Memory}
    small,large:[]simd.f32x4
    if total>MATCH_LINEAR_ROWS {
        e7,e8:mem.Allocator_Error
        small,e7=make([]simd.f32x4,2*MATCH_LANES*((total+MATCH_BOUND_SMALL-1)/MATCH_BOUND_SMALL))
        large,e8=make([]simd.f32x4,2*MATCH_LANES*((total+MATCH_BOUND_LARGE-1)/MATCH_BOUND_LARGE))
        if e7!=nil || e8!=nil {delete(features);delete(small);delete(large);return .Out_Of_Memory}
    }
    times:[]f32
    if events {
        e9:mem.Allocator_Error
        times,e9=make([]f32,total)
        if e9!=nil {delete(features);delete(small);delete(large);return .Out_Of_Memory}
        for c,i in clips {
            r:=ranges[i]
            for frame in 0..<int(r.count) {
                at:=f32(frame)/rate;next:=f32(-1)
                // A marker within half a row of a frame is at that frame.
                if r.weights=={0=1} {
                    for marker in clip_markers(lib,c.clips[0]) {
                        if !slice.contains(event,marker.id) || marker.time<at-.5/rate {continue}
                        if ahead:=max(marker.time-at,0);next<0 || ahead<next {next=ahead}
                    }
                }
                times[int(r.first)+frame]=next
            }
        }
    }
    db^={rate=rate,features=features,ranges=ranges,rows=total,small=small,large=large,events=times,allocator=allocator}
    for i in 0..<MATCH_LANES*4 {db.scale[i]=1}
    for r in ranges {
        if r.entry {db.entry_modes|=r.modes} else if r.speed>MATCH_STILL {db.moving_modes|=r.modes} else {db.still_modes|=r.modes}
        if events && times[r.first]>=0 {db.event_modes|=r.modes}
    }
    for span,kind in MATCH_FEATURES {
        spread:f64
        for i in span[0]..<span[1] {
            sum:f64;for values in raw {sum+=f64(values[i])}
            mean:=sum/f64(total);db.mean[i]=f32(mean)
            variance:f64;for values in raw {d:=f64(values[i])-mean;variance+=d*d}
            spread+=cmath.sqrt(variance/f64(total))
        }
        spread=max(spread/f64(span[1]-span[0]),MATCH_SPREAD_MIN)
        for i in span[0]..<span[1] {db.scale[i]=f32(spread)/weights[kind] if weights[kind]>0 else max(f32)}
    }
    for values,r in raw {
        normalized:[MATCH_LANES*4]f32
        for value,i in values {normalized[i]=(value-db.mean[i])/db.scale[i]}
        for lane in 0..<MATCH_LANES {features[r*MATCH_LANES+lane]=match_lane(normalized[lane*4:][:4])}
    }
    for bounds,b in ([2][]simd.f32x4{small,large}) {
        size:=MATCH_BOUND_SMALL if b==0 else MATCH_BOUND_LARGE
        for box in 0..<len(bounds)/(2*MATCH_LANES) {
            least,greatest:=bounds[box*2*MATCH_LANES:][:MATCH_LANES],bounds[box*2*MATCH_LANES+MATCH_LANES:][:MATCH_LANES]
            for lane in 0..<MATCH_LANES {least[lane],greatest[lane]=max(f32),min(f32)}
            for r in box*size..<min((box+1)*size,total) {
                for lane in 0..<MATCH_LANES {v:=features[r*MATCH_LANES+lane];least[lane]=simd.min(least[lane],v);greatest[lane]=simd.max(greatest[lane],v)}
            }
        }
    }
    ok=true
    return .None
}

// The normalized features of the row of a range nearest a time of its clip.
match_row :: proc "contextless" (db:^Match_Database,range:int,time:f32) -> int {
    r:=db.ranges[range]
    frame:=int(cmath.round(time*db.rate)) if anim_finite(time) else 0
    if r.loop && r.count>1 {frame%=int(r.count-1);if frame<0 {frame+=int(r.count-1)}}
    return int(r.first)+clamp(frame,0,int(r.count-1))
}
match_features :: #force_inline proc "contextless" (db:^Match_Database,row:int) -> Match_Query {
    query:Match_Query
    copy(query[:],db.features[row*MATCH_LANES:][:MATCH_LANES])
    return query
}
// The pose part of a query from the pose a rig has, for a search with nothing of the database
// playing: where its feet are and how they and its hips move. current and previous are its local
// poses dt seconds apart, in which the roots are the frame of the character and stay out; velocity
// is that of the body in that frame, which the feet move with. The trajectory lanes are left at
// the mean, and its velocities are those of rate 1. False, with the mean pose, for poses of other
// sizes, a bone out of them, a parent after its child, or values that are not finite.
match_query_pose :: proc "contextless" (db:^Match_Database,parents:[]i32,left_foot,right_foot,hips:i32,current,previous:[]math.Transform,dt:f32,velocity:math.Vec3) -> (query:Match_Query,ok:bool) {
    n:=len(parents)
    if len(current)!=n || len(previous)!=n || !anim_finite(dt) || dt<=0 || !anim_vec3_valid(velocity) {return}
    point :: proc "contextless" (parents:[]i32,local:[]math.Transform,bone:int) -> (p:math.Vec3,ok:bool) {
        for b:=bone;parents[b]>=0;b=int(parents[b]) {
            if int(parents[b])>=b {return}
            p=math.transform_point(local[b],p)
        }
        return p,anim_vec3_valid(p)
    }
    values:[MATCH_LANES*4]f32
    for bone,k in ([3]i32{left_foot,right_foot,hips}) {
        if bone<0 || int(bone)>=n {return}
        now:=point(parents,current,int(bone)) or_return
        before:=point(parents,previous,int(bone)) or_return
        moving:=(now-before)/dt+velocity
        if !anim_vec3_valid(moving) {return}
        for axis in 0..<3 {
            if k<2 {values[k*3+axis],values[6+k*3+axis]=now[axis],moving[axis]} else {values[12+axis]=moving[axis]}
        }
    }
    for i in 0..<MATCH_FEATURES[.Hip_Velocity][1] {values[i]=(values[i]-db.mean[i])/db.scale[i]}
    for lane in 0..<MATCH_LANES {query[lane]=match_lane(values[lane*4:][:4])}
    return query,true
}
// The cost of a row against a query, each feature by its weight (match_query gives them).
match_cost :: #force_inline proc "contextless" (db:^Match_Database,row:int,query,weights:Match_Query) -> f32 {
    features:=db.features[row*MATCH_LANES:][:MATCH_LANES]
    sum:simd.f32x4
    #unroll for lane in 0..<MATCH_LANES {d:=features[lane]-query[lane];sum+=d*d*weights[lane]}
    return simd.reduce_add_pairs(sum)
}
// The cost of a row against a query split by kind of feature.
match_cost_split :: proc "contextless" (db:^Match_Database,row:int,query,weights:Match_Query) -> (costs:[Match_Feature]f32) {
    terms:[MATCH_LANES*4]f32
    for lane in 0..<MATCH_LANES {
        d:=db.features[row*MATCH_LANES+lane]-query[lane]
        values:=simd.to_array(d*d*weights[lane]);copy(terms[lane*4:][:4],values[:])
    }
    for span,kind in MATCH_FEATURES {for i in span[0]..<span[1] {costs[kind]+=terms[i]}}
    return
}

// The raw trajectory of a row.
match_row_trajectory :: proc "contextless" (db:^Match_Database,row:int) -> (trajectory:Match_Trajectory) {
    values:[MATCH_LANES*4]f32
    for lane in 0..<MATCH_LANES {lanes:=simd.to_array(db.features[row*MATCH_LANES+lane]);copy(values[lane*4:][:4],lanes[:])}
    raw :: proc "contextless" (db:^Match_Database,values:[]f32,at:int) -> math.Vec2 {
        return {values[at]*db.scale[at]+db.mean[at],values[at+1]*db.scale[at+1]+db.mean[at+1]}
    }
    trajectory.velocity,trajectory.past=raw(db,values[:],MATCH_AT_VELOCITY),raw(db,values[:],MATCH_AT_PAST)
    for k in 0..<MATCH_TRAJECTORY {
        trajectory.positions[k]=raw(db,values[:],MATCH_AT_POINTS+k*2)
        trajectory.directions[k]=raw(db,values[:],MATCH_AT_DIRECTIONS+k*2)
    }
    return
}

// Writes a trajectory, raw values in the frame of the character, into a query, normalized.
match_query_trajectory :: proc "contextless" (db:^Match_Database,query:^Match_Query,trajectory:Match_Trajectory) {
    values:[MATCH_LANES*4]f32
    for lane in 0..<MATCH_LANES {lanes:=simd.to_array(query[lane]);copy(values[lane*4:][:4],lanes[:])}
    put :: proc "contextless" (db:^Match_Database,values:[]f32,at:int,value:math.Vec2) {
        values[at]=(value.x-db.mean[at])/db.scale[at];values[at+1]=(value.y-db.mean[at+1])/db.scale[at+1]
    }
    put(db,values[:],MATCH_AT_VELOCITY,trajectory.velocity);put(db,values[:],MATCH_AT_PAST,trajectory.past)
    for k in 0..<MATCH_TRAJECTORY {
        put(db,values[:],MATCH_AT_POINTS+k*2,trajectory.positions[k])
        put(db,values[:],MATCH_AT_DIRECTIONS+k*2,trajectory.directions[k])
    }
    for lane in 0..<MATCH_LANES {query[lane]=match_lane(values[lane*4:][:4])}
}

// What a search looks for: the pose part of query (the trajectory lanes are written per clip),
// the trajectory, the modes whose clips it searches and the rates a clip that travels may play at
// (1 and 1: as it was made; 0 and 0: at its own rate), which the rates of a clip replace, and the
// rate the pose of query plays at (0: 1). entry searches the starts of the entry clips of the
// modes alone; otherwise they are left out. With
// filter_stationary, a clip that is not an entry is searched only if it stands (MATCH_STILL) when
// the body does not move, and moves when the body does. event, when positive with the events of
// the database, is the seconds to the event (a landing): only rows in its window are searched
// (match_event_window), and give the rate that reaches their marker then; entry searches the starts
// of the entry clips alone, and otherwise every row of the clips of the modes, with no tail or
// stationary filter. event_from, when positive, is the seconds to its marker of the row that
// plays: rows further from theirs are out of the window, as an arc in the air only goes on.
Match_Request :: struct {query:Match_Query,trajectory:Match_Trajectory,modes:u32,min_rate,max_rate,rate:f32,entry:bool,filter_stationary,moving:bool,event:f32,event_rates:[2]f32,event_from:f32}

// Whether rates are none (zero) or a least and a most rate a clip may play at.
match_rates_valid :: proc "contextless" (rates:[2]f32) -> bool {
    return rates=={} || anim_finite(rates[0]) && anim_finite(rates[1]) && rates[0]>0 && rates[0]<=rates[1]
}
// The least and most rate a range plays at to follow the body: its own, else least and most.
match_range_rates :: proc "contextless" (r:Match_Range,least,most:f32) -> (f32,f32) {
    if r.rates[0]>0 {return r.rates[0],r.rates[1]}
    return least,most
}

// The query against the rows of a range, its weights and the rate the range plays at to go where
// the trajectory goes: a few clips cover the speeds between theirs by their rate, whose trajectory
// and velocities are theirs scaled by it. The query is taken to the rate of the range (its
// trajectory over it, the velocities of its pose by the rate it plays at over it), and the
// velocities and trajectory positions weigh the square of the rate: costs are of what the body
// does, so a clip slowed down is not dearer than one at its own rate.
match_query :: proc "contextless" (db:^Match_Database,request:Match_Request,range:int) -> (query,weights:Match_Query,rate:f32) {
    query,rate=request.query,1
    for &lane in weights {lane={1,1,1,1}}
    r:=db.ranges[range]
    if r.speed>1e-3 && request.min_rate>0 && request.min_rate<=request.max_rate {
        least,most:=match_range_rates(r,request.min_rate,request.max_rate)
        rate=clamp(linalg.length(request.trajectory.positions[MATCH_TRAJECTORY-1])/(MATCH_HORIZON[MATCH_TRAJECTORY-1]*r.speed),least,most)
    }
    trajectory:=request.trajectory
    trajectory.velocity/=rate;trajectory.past/=rate
    for &p in trajectory.positions {p/=rate}
    match_query_trajectory(db,&query,trajectory)
    if scale:=(request.rate if request.rate>0 else 1)/rate;scale!=1 {
        values:[MATCH_LANES*4]f32
        for lane in 0..<MATCH_LANES {lanes:=simd.to_array(query[lane]);copy(values[lane*4:][:4],lanes[:])}
        for i in MATCH_FEATURES[.Foot_Velocity][0]..<MATCH_FEATURES[.Hip_Velocity][1] {values[i]=((values[i]*db.scale[i]+db.mean[i])*scale-db.mean[i])/db.scale[i]}
        for lane in 0..<MATCH_LANES {query[lane]=match_lane(values[lane*4:][:4])}
    }
    if rate!=1 {
        scales:[MATCH_LANES*4]f32
        for &value,i in scales {value=rate*rate if i>=MATCH_FEATURES[.Foot_Velocity][0] && i<MATCH_FEATURES[.Trajectory_Position][1] else 1}
        for lane in 0..<MATCH_LANES {weights[lane]=match_lane(scales[lane*4:][:4])}
    }
    return
}

// The least cost a row inside the bounds of a run can have against query.
@(private)
match_bound :: #force_inline proc "contextless" (bounds:[]simd.f32x4,box:int,query,weights:Match_Query) -> f32 {
    least,greatest:=bounds[box*2*MATCH_LANES:][:MATCH_LANES],bounds[box*2*MATCH_LANES+MATCH_LANES:][:MATCH_LANES]
    sum:simd.f32x4
    #unroll for lane in 0..<MATCH_LANES {d:=simd.max(simd.max(least[lane]-query[lane],query[lane]-greatest[lane]),0);sum+=d*d*weights[lane]}
    return simd.reduce_add_pairs(sum)
}

// Whether some clip serves one of modes, entry or not.
match_serves :: proc "contextless" (db:^Match_Database,modes:u32,entry:bool) -> bool {
    return (db.entry_modes if entry else db.still_modes|db.moving_modes)&modes!=0
}
// Whether some clip that serves one of modes has a marker of the event.
match_event_serves :: proc "contextless" (db:^Match_Database,modes:u32) -> bool {
    return len(db.events)==db.rows && db.event_modes&modes!=0
}
// Seconds of its clip from time to the next marker of the event of a range; negative: none ahead.
match_event_ahead :: proc "contextless" (db:^Match_Database,range:int,time:f32) -> f32 {
    if len(db.events)!=db.rows || range<0 || range>=len(db.ranges) || !anim_finite(time) {return -1}
    row:=match_row(db,range,time)
    if db.events[row]<0 {return -1}
    return db.events[row]+f32(row-int(db.ranges[range].first))/db.rate-time
}

// Rows at the end of a range that a search leaves out: a clip that does not loop keeps out its
// last horizon, from which playing on would end it before the trajectory; one shorter than that,
// MATCH_TAIL_MIN seconds, keeping its first row.
match_tail :: proc "contextless" (db:^Match_Database,range:int) -> int {
    r:=db.ranges[range]
    if r.loop {return 0}
    tail:=int(cmath.ceil(MATCH_HORIZON[MATCH_TRAJECTORY-1]*db.rate))
    if int(r.count)>tail+1 {return tail}
    return clamp(int(cmath.ceil(MATCH_TAIL_MIN*db.rate)),0,int(r.count)-1)
}

// Ages the rows a rig left by dt and forgets those it left span seconds ago or more.
match_recent_advance :: proc "contextless" (recent:^Match_Recent,dt,span:f32) {
    step:=dt if anim_finite(dt) && dt>0 else 0
    kept:i32
    for i in 0..<clamp(recent.count,0,MATCH_RECENT) {
        age:=recent.ages[i]+step
        if !(age<span) {continue}
        recent.rows[kept],recent.ages[kept]=recent.rows[i],age;kept+=1
    }
    recent.count=kept
}
// Notes that a rig left row; with no room, the oldest is forgotten.
match_recent_leave :: proc "contextless" (recent:^Match_Recent,row:int) {
    recent.count=clamp(recent.count,0,MATCH_RECENT)
    if recent.count==MATCH_RECENT {
        copy(recent.rows[:MATCH_RECENT-1],recent.rows[1:]);copy(recent.ages[:MATCH_RECENT-1],recent.ages[1:])
        recent.count-=1
    }
    recent.rows[recent.count],recent.ages[recent.count]=i32(row),0;recent.count+=1
}

// Whether row lies at most reach rows behind from in their range; in a loop, around its seam.
@(private)
match_behind :: #force_inline proc "contextless" (r:Match_Range,row,from,reach:int) -> bool {
    back:=from-row
    if r.loop && r.count>1 {period:=int(r.count-1);back%=period;if back<0 {back+=period}}
    return back>=0 && back<=reach
}

// The row of least cost among the clips that serve one of the modes of request, and the rate its
// clip plays at. A clip that does not loop keeps out its tail (match_tail). current is the row that
// plays (-1: none): rows of its clip within span seconds of it are left out, a jump that short is
// a stutter, and all of them with whole. recent are rows the rig left: those it played in the span
// seconds before it left them are left out too. With bounds, runs that cannot hold a better row
// are skipped whole. With candidates, it notes the best row of each clip, which bounds each clip
// by its own best row instead of the best of all, and that of each clip it leaves out, with why.
match_search :: proc "contextless" (db:^Match_Database,request:Match_Request,current:=-1,whole:=false,span:f32=0,recent:^Match_Recent=nil,candidates:^Match_Candidates=nil) -> (best:int,cost,rate:f32) {
    best,cost,rate=-1,max(f32),1
    if candidates!=nil {candidates^={}}
    entry_rows:=int(cmath.ceil(MATCH_ENTRY_SPAN*db.rate))+1
    rates:=request.event_rates
    event:=len(db.events)==db.rows && anim_finite(request.event) && request.event>0 && anim_finite(rates[0]) && anim_finite(rates[1]) && rates[0]>0 && rates[0]<=rates[1]
    bounded:=len(db.small)>0
    seconds:=span if anim_finite(span) && span>0 else 0
    rows_in :: proc "contextless" (db:^Match_Database,seconds:f32) -> int {return int(min(cmath.ceil(seconds*db.rate),f32(db.rows)))}
    near:=current if current>=0 && current<db.rows else -1
    near_range:=match_range_of(db,near) if near>=0 else -1
    reach:=rows_in(db,seconds)
    Left :: struct {range,row,reach:int}
    left:[MATCH_RECENT]Left;left_count:=0
    if recent!=nil {
        for i in 0..<clamp(int(recent.count),0,MATCH_RECENT) {
            at:=int(recent.rows[i]);age:=recent.ages[i]
            if at<0 || at>=db.rows || !anim_finite(age) || !(age<seconds) {continue}
            left[left_count]={match_range_of(db,at),at,rows_in(db,seconds-max(age,0))};left_count+=1
        }
    }
    for r,range in db.ranges {
        reason:=Match_Reject.None
        if r.modes&request.modes==0 {
            reason=.Mode
        } else if request.entry && !r.entry || !request.entry && r.entry && !event {
            reason=.Entry
        } else if !event && request.filter_stationary && !r.entry && (r.speed>MATCH_STILL)!=request.moving {reason=.Stationary}
        if reason!=.None && candidates==nil {continue}
        query,weights,scaled:=match_query(db,request,range)
        last:=int(r.count)-match_tail(db,range)
        if request.entry {last=min(int(r.count),entry_rows)} else if event {last=int(r.count)}
        if reason!=.None {
            match_candidates_reject(db,candidates,int(r.first),int(r.first)+last,query,weights,scaled,reason)
            continue
        }
        playing:=range==near_range
        found,least,found_rate:=-1,max(f32),scaled
        skipped,skipped_cost:=-1,max(f32)
        row,end:=int(r.first),int(r.first)+last
        for row<end {
            large_end:=min((row/MATCH_BOUND_LARGE+1)*MATCH_BOUND_LARGE,end)
            if bounded && match_bound(db.large,row/MATCH_BOUND_LARGE,query,weights)>=(least if candidates!=nil else cost) {row=large_end;continue}
            for row<large_end {
                small_end:=min((row/MATCH_BOUND_SMALL+1)*MATCH_BOUND_SMALL,large_end)
                if bounded && match_bound(db.small,row/MATCH_BOUND_SMALL,query,weights)>=(least if candidates!=nil else cost) {row=small_end;continue}
                for ;row<small_end;row+=1 {
                    value:=match_cost(db,row,query,weights)
                    if value>=(least if candidates!=nil else cost) {continue}
                    at_rate:=scaled
                    if event {
                        inside:bool
                        if at_rate,inside=match_event_window(db,row,request);!inside {continue}
                    }
                    excluded:=playing && (whole || match_behind(r,row,near,reach) || match_behind(r,near,row,reach))
                    for l in left[:left_count] {if excluded {break};if l.range==range && match_behind(r,row,l.row,l.reach) {excluded=true}}
                    if excluded {
                        if value<skipped_cost {skipped,skipped_cost=row,value}
                        continue
                    }
                    found,least,found_rate=row,value,at_rate
                    if value<cost {best,cost,rate=row,value,at_rate}
                }
            }
        }
        if candidates==nil {continue}
        if found>=0 {
            match_candidates_add(candidates,{row=i32(found),cost=least,rate=found_rate,costs=match_cost_split(db,found,query,weights),reason=.Cost})
        } else if skipped>=0 {
            match_candidates_add(candidates,{row=i32(skipped),cost=skipped_cost,rate=found_rate,costs=match_cost_split(db,skipped,query,weights),reason=.Reselect})
        } else if event {
            reached:=false
            for ahead in db.events[r.first:][:last] {if ahead>=0 {reached=true;break}}
            match_candidates_reject(db,candidates,int(r.first),int(r.first)+last,query,weights,scaled,.Window if reached else .Event)
        }
    }
    if candidates!=nil {
        for &item in candidates.items[:clamp(candidates.count,0,MATCH_CANDIDATES)] {if int(item.row)==best && item.reason==.Cost {item.reason=.None;break}}
    }
    return
}

// Whether a row lies in the window of the event of request, as PoseSearch's events: its marker is
// reached when the event comes at a rate of event_rates, within half a row, and is not further
// than event_from (when positive) by more than a row; and the rate that reaches it then, within
// event_rates. Request must hold an event the database has.
match_event_window :: proc "contextless" (db:^Match_Database,row:int,request:Match_Request) -> (rate:f32,inside:bool) {
    ahead:=db.events[row]
    if ahead<0 {return 1,false}
    rates:=request.event_rates
    half:=.5/db.rate
    inside=ahead>=request.event*rates[0]-half && ahead<=request.event*rates[1]+half
    if request.event_from>0 && ahead>request.event_from+1/db.rate {inside=false}
    return clamp(ahead/request.event,rates[0],rates[1]),inside
}

// Notes the best row of a clip a search leaves out (rows first..<end), with why.
@(private)
match_candidates_reject :: proc "contextless" (db:^Match_Database,candidates:^Match_Candidates,first,end:int,query,weights:Match_Query,rate:f32,reason:Match_Reject) {
    found,least:=-1,max(f32)
    for row in first..<end {if value:=match_cost(db,row,query,weights);value<least {found,least=row,value}}
    if found>=0 {match_candidates_add(candidates,{row=i32(found),cost=least,rate=rate,costs=match_cost_split(db,found,query,weights),reason=reason})}
}

// Places a candidate by its cost after those that cost the same, those the search could give
// first, those of other modes last; past the last it is dropped.
@(private)
match_candidates_add :: proc "contextless" (candidates:^Match_Candidates,candidate:Match_Candidate) {
    count:=int(clamp(candidates.count,0,MATCH_CANDIDATES))
    at:=count
    rank :: proc "contextless" (c:Match_Candidate) -> int {return 0 if c.reason<=.Cost else 2 if c.reason==.Mode else 1}
    for item,i in candidates.items[:count] {
        if rank(candidate)==rank(item) && candidate.cost<item.cost || rank(candidate)<rank(item) {at=i;break}
    }
    if at>=MATCH_CANDIDATES {return}
    end:=min(count+1,MATCH_CANDIDATES)
    for i:=end-1;i>at;i-=1 {candidates.items[i]=candidates.items[i-1]}
    candidates.items[at]=candidate;candidates.count=i32(end)
}

// The range a row belongs to.
match_range_of :: proc "contextless" (db:^Match_Database,row:int) -> int {
    low,high:=0,len(db.ranges)
    for low<high {
        middle:=(low+high)/2
        if row<int(db.ranges[middle].first) {high=middle} else if row>=int(db.ranges[middle].first+db.ranges[middle].count) {low=middle+1} else {return middle}
    }
    return -1
}

// Notes the horizontal velocity of a body in a tick of dt seconds; a value that is not finite or
// a tick without time is left out.
match_trail_add :: proc "contextless" (trail:^Match_Trail,velocity:math.Vec3,dt:f32) {
    SPAN :: MATCH_PAST/MATCH_TRAIL
    if !anim_vec3_valid(velocity) || !anim_finite(dt) || dt<=0 {return}
    if !anim_vec3_valid(trail.current) || !anim_finite(trail.elapsed) || trail.elapsed<0 || trail.elapsed>SPAN {trail^={}}
    flat:=math.Vec3{velocity.x,0,velocity.z}
    // What is older than the trail does not matter: it holds at most MATCH_PAST and a span.
    left:=min(dt,MATCH_PAST+SPAN)
    for left>0 {
        step:=min(SPAN-trail.elapsed,left)
        trail.current+=flat*step;trail.elapsed+=step;left-=step
        if trail.elapsed<SPAN*(1-1e-4) {break}
        next:=clamp(trail.next,0,MATCH_TRAIL-1)
        trail.spans[next],trail.current,trail.elapsed=trail.current,{},0
        trail.next=(next+1)%MATCH_TRAIL;trail.count=clamp(trail.count+1,1,MATCH_TRAIL)
    }
}
// How far a body went in its last MATCH_PAST seconds: the time its trail does not hold went at the
// pace of the oldest span it holds, or at velocity with an empty trail.
match_trail_moved :: proc "contextless" (trail:Match_Trail,velocity:math.Vec3) -> (moved:math.Vec3) {
    SPAN :: MATCH_PAST/MATCH_TRAIL
    pace:=math.Vec3{velocity.x,0,velocity.z}
    left:=f32(MATCH_PAST)
    if anim_vec3_valid(trail.current) && anim_finite(trail.elapsed) && trail.elapsed>0 && trail.elapsed<=SPAN {
        moved,left,pace=trail.current,left-trail.elapsed,trail.current/trail.elapsed
    }
    for i in 0..<clamp(int(trail.count),0,MATCH_TRAIL) {
        if left<=0 {break}
        span:=trail.spans[(int(trail.next)-1-i)%%MATCH_TRAIL]
        share:=min(left/SPAN,1)
        moved+=span*share;left-=SPAN*share;pace=span/SPAN
    }
    if left>0 {moved+=pace*left}
    return
}

// Where the body goes in the next MATCH_HORIZON seconds and went in the last MATCH_PAST, in the
// frame of its facing: its horizontal velocity heads toward desired at acceleration m/s² (braking
// with desired zero), as a walk drives it, and its facing turns toward desired_facing at turn_rate
// rad/s (0: at once; a zero desired_facing keeps it). wall, when not zero, is the normal of what
// blocks the body, out of it: neither the velocity nor the desired one go into it. trail says how
// the body went (nil: at its velocity). Vectors are in the world, Y up.
match_trajectory :: proc "contextless" (velocity,desired:math.Vec3,acceleration,braking:f32,facing,desired_facing:math.Vec3,turn_rate:f32,wall:=math.Vec3{},trail:^Match_Trail=nil) -> (trajectory:Match_Trajectory) {
    flat :: proc "contextless" (v:math.Vec3) -> math.Vec3 {return {v.x,0,v.z}}
    v,goal:=flat(velocity),flat(desired)
    if normal,blocked:=anim_unit(flat(wall));blocked {
        if into:=linalg.dot(v,normal);into<0 {v-=normal*into}
        if into:=linalg.dot(goal,normal);into<0 {goal-=normal*into}
    }
    heading,known:=anim_unit(flat(facing));if !known {heading=math.FORWARD}
    rate:=braking if goal=={} else acceleration
    change:=goal-v;distance:=linalg.length(change)
    reach:=distance/rate if rate>0 && anim_finite(rate) else max(f32)
    along:=change/distance if distance>0 else math.Vec3{}
    turn:f32
    if wanted,ok:=anim_unit(flat(desired_facing));ok {turn=cmath.atan2(linalg.dot(linalg.cross(heading,wanted),math.Vec3{0,1,0}),linalg.dot(heading,wanted))}
    inverse:=math.quat_inverse(match_yaw(heading))
    now:=math.quat_rotate(inverse,v)
    moved:=match_trail_moved(trail^,v) if trail!=nil else v*MATCH_PAST
    behind:=math.quat_rotate(inverse,-moved)
    trajectory.velocity,trajectory.past={now.x,now.z},{behind.x,behind.z}
    for horizon,k in MATCH_HORIZON {
        position:math.Vec3
        if horizon<=reach {position=v*horizon+along*(.5*rate*horizon*horizon)} else {position=v*reach+along*(.5*rate*reach*reach)+goal*(horizon-reach)}
        angle:=turn if turn_rate<=0 else clamp(turn,-turn_rate*horizon,turn_rate*horizon)
        direction:=math.quat_rotate(math.quat_axis_angle({0,1,0},angle),heading)
        local,toward:=math.quat_rotate(inverse,position),math.quat_rotate(inverse,direction)
        trajectory.positions[k],trajectory.directions[k]={local.x,local.z},{toward.x,toward.z}
    }
    return
}

// How long a clip or a blended sample lasts and whether it blends: a blend lasts the mean of the
// durations of its clips by their weights, as the program plays them in a Weighted group. False
// for a clip that is not valid, a weight that is not finite in 0..1, or a blend whose clips do not
// all loop.
match_clip_duration :: proc "contextless" (lib:^Library,c:Match_Clip) -> (duration:f32,blended,ok:bool) {
    members,first:=0,-1
    sum:f32
    for w,k in c.weights {
        if !anim_finite(w) || w<0 || w>1 {return}
        if w>0 {members+=1;sum+=w;if first<0 {first=k}}
    }
    if first<=0 && members<=1 {
        if !clip_valid(lib,c.clips[0]) {return}
        return clip_duration(lib,c.clips[0]),false,true
    }
    for clip,k in c.clips {
        if c.weights[k]<=0 {continue}
        if !clip_valid(lib,clip) || clip_data(lib,clip).loop!=.Loop {return}
        duration+=clip_duration(lib,clip)*c.weights[k]/sum
    }
    return duration,true,true
}

// Samples a blend into out: at each frame each clip with a weight at the same share of its
// duration, mixed as the program mixes the leaves of a group (bones_blend, then bone_transform
// over the rest of the skeleton).
@(private)
match_sample_blend :: proc "contextless" (lib:^Library,c:Match_Clip,skeleton:Skeleton,track_bones:[]i32,blend:[]Bone_Blend,out:Frames) -> bool {
    count:=frames_count(out)
    if count<2 || len(skeleton.names)!=out.bones || len(skeleton.rest)!=out.bones || len(blend)!=out.bones {return false}
    sum:f32;for w in c.weights {sum+=w}
    for frame in 0..<count {
        share:=f32(frame)/f32(count-1)
        for &bone in blend {bone={}}
        for clip,k in c.clips {
            if c.weights[k]<=0 {continue}
            player:=player_make(clip);player.time=share*clip_duration(lib,clip)
            bones_blend(blend,track_bones,lib,player,c.weights[k]/sum)
        }
        local:=frames_pose(out,frame)
        for mixed,bone in blend {
            value,_,_:=bone_transform(mixed,skeleton.rest[bone])
            if !anim_transform_valid(value) {return false}
            local[bone]=value
        }
    }
    return true
}

@(private)
match_lane :: #force_inline proc "contextless" (values:[]f32) -> simd.f32x4 {return {values[0],values[1],values[2],values[3]}}

// The rotation about Y that takes -Z to a horizontal direction.
match_yaw :: proc "contextless" (direction:math.Vec3) -> math.Quat {
    return math.quat_axis_angle({0,1,0},math.yaw_of_direction(direction))
}

@(private)
Match_Motion :: struct {frames:Frames,world,rest:[]math.Transform,root:int,in_place:bool,travel:math.Vec3}

// A frame of the clip, out of its span: a loop goes on into its next passes, carrying what the body
// moved in each one; a clip that does not loop holds its ends.
@(private)
match_motion_frame :: proc "contextless" (m:Match_Motion,frame:int) -> (index:int,passes:f32) {
    count:=frames_count(m.frames)
    if !m.frames.loop || count<2 {return clamp(frame,0,count-1),0}
    span:=count-1
    pass:=frame/span if frame>=0 else -((span-1-frame)/span)
    return frame-pass*span,f32(pass)
}
@(private)
match_motion_loop :: proc "contextless" (m:Match_Motion) -> math.Vec3 {
    count:=frames_count(m.frames)
    if m.in_place {return m.travel*frames_duration(m.frames)}
    a,b:=m.world[m.root].position,m.world[(count-1)*m.frames.bones+m.root].position
    return {b.x-a.x,0,b.z-a.z}
}
// Where a bone is in the world of the clip at a frame, with the travel of a clip in place.
@(private)
match_motion_point_at :: proc "contextless" (m:Match_Motion,bone,frame:int) -> math.Vec3 {
    index,passes:=match_motion_frame(m,frame)
    position:=m.world[index*m.frames.bones+bone].position+match_motion_loop(m)*passes
    if m.in_place {position+=m.travel*(f32(index)/m.frames.rate)}
    return position
}
@(private)
match_motion_point :: proc "contextless" (m:Match_Motion,bone:int,frame:f32) -> math.Vec3 {
    whole:=int(cmath.floor(frame))
    return linalg.lerp(match_motion_point_at(m,bone,whole),match_motion_point_at(m,bone,whole+1),frame-f32(whole))
}
@(private)
match_motion_velocity :: proc "contextless" (m:Match_Motion,bone,frame:int) -> math.Vec3 {
    a,b:=frame-1,frame+1
    if !m.frames.loop {a,b=max(a,0),min(b,frames_count(m.frames)-1)}
    if b<=a {return {}}
    return (match_motion_point_at(m,bone,b)-match_motion_point_at(m,bone,a))*(m.frames.rate/f32(b-a))
}
// The body on the ground: its root, or for a clip in place the origin carried by the travel.
@(private)
match_motion_body :: proc "contextless" (m:Match_Motion,frame:f32) -> math.Vec3 {
    if m.in_place {
        whole:=int(cmath.floor(frame))
        index,passes:=match_motion_frame(m,whole)
        return match_motion_loop(m)*passes+m.travel*((f32(index)+frame-f32(whole))/m.frames.rate)
    }
    p:=match_motion_point(m,m.root,frame)
    return {p.x,0,p.z}
}
@(private)
match_motion_body_velocity :: proc "contextless" (m:Match_Motion,frame:int) -> math.Vec3 {
    a,b:=frame-1,frame+1
    if !m.frames.loop {a,b=max(a,0),min(b,frames_count(m.frames)-1)}
    if b<=a {return {}}
    return (match_motion_body(m,f32(b))-match_motion_body(m,f32(a)))*(m.frames.rate/f32(b-a))
}
@(private)
match_motion_facing :: proc "contextless" (m:Match_Motion,frame:f32) -> math.Vec3 {
    if m.in_place {return math.FORWARD}
    index,_:=match_motion_frame(m,int(cmath.round(frame)))
    turn:=m.world[index*m.frames.bones+m.root].rotation*math.quat_inverse(m.rest[m.root].rotation)
    facing:=math.quat_rotate(turn,math.FORWARD)
    if direction,ok:=anim_unit(math.Vec3{facing.x,0,facing.z});ok {return direction}
    return math.FORWARD
}
