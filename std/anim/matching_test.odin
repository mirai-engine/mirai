package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import "core:simd"
import "core:testing"
import "mirai:std/base"
import math "mirai:std/math"

// Hips over two feet and a head; idle stands, walk pushes the ground back at 1.5 m/s in place,
// fall (another mode) lifts both feet.
@(private="file")
match_test_rig :: proc(library:^Library) -> (rig:Match_Rig,clips:[3]Match_Clip,ok:bool) {
    @(static) parents:=[5]i32{-1,0,1,1,1}
    @(static) names:[5]u64
    @(static) rest:=[5]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}},{{.1,-.95,0},1,{1,1,1}},{{-.1,-.95,0},1,{1,1,1}},{{0,.7,0},1,{1,1,1}}}
    for name,i in ([5]string{"root","hips","foot_l","foot_r","head"}) {names[i]=base.name_hash(name)}
    body:=body_map_empty()
    body.bones[.Pelvis],body.bones[.Foot_L],body.bones[.Foot_R],body.bones[.Head]=1,2,3,4
    rig={skeleton={parents[:],names[:],rest[:]},body=body,left_foot=2,right_foot=3,hips=1}
    if !library_init(library,{max_keys=64,max_tracks=16,max_clips=8,max_markers=2}) {return}
    still:=[2]Keyframe{{time=0,value={.1,-.95,0,0}},{time=1,value={.1,-.95,0,0}}}
    other:=[2]Keyframe{{time=0,value={-.1,-.95,0,0}},{time=1,value={-.1,-.95,0,0}}}
    left:=[4]Keyframe{{time=0,value={.1,-.95,-.375,0}},{time=.5,value={.1,-.95,.375,0}},{time=.75,value={.1,-.8,0,0}},{time=1,value={.1,-.95,-.375,0}}}
    right:=[4]Keyframe{{time=0,value={-.1,-.95,.375,0}},{time=.25,value={-.1,-.8,0,0}},{time=.5,value={-.1,-.95,-.375,0}},{time=1,value={-.1,-.95,.375,0}}}
    up:=[2]Keyframe{{time=0,value={.1,-.6,-.1,0}},{time=1,value={.1,-.6,-.1,0}}}
    descs:=[3]Clip_Desc{
        {name=base.name_hash("idle"),loop=.Loop,tracks={{target=names[2],property=.Position,keys=still[:]},{target=names[3],property=.Position,keys=other[:]}}},
        {name=base.name_hash("walk"),loop=.Loop,tracks={{target=names[2],property=.Position,keys=left[:]},{target=names[3],property=.Position,keys=right[:]}}},
        {name=base.name_hash("fall"),loop=.Loop,tracks={{target=names[2],property=.Position,keys=up[:]},{target=names[3],property=.Position,keys=other[:]}}},
    }
    for desc,i in descs {
        clip,error:=clip_add(library,desc)
        if error!=.None {return}
        clips[i]={clips={0=clip},modes=1<<1 if i<2 else 1<<0}
    }
    return rig,clips,true
}

@(test)
match_database_finds_each_frame_by_its_features_and_the_clip_a_trajectory_asks_for :: proc(t:^testing.T) {
    library:Library;defer library_destroy(&library)
    rig,clips,ok:=match_test_rig(&library)
    if !testing.expect(t,ok) {return}
    db:Match_Database;defer match_database_free(&db)
    // Without frames that start or stop the walk, the trajectory has to outweigh the pose.
    weights:=MATCH_WEIGHTS_DEFAULT;weights[.Trajectory_Position]=3
    if !testing.expect(t,match_database_build(&db,&library,rig,clips[:],30,weights)==.None) {return}
    testing.expect(t,len(db.ranges)==3 && db.ranges[0].speed<.05 && abs(db.ranges[1].speed-1.5)<.1 && db.ranges[1].travel.z<0,"the walk in place travels forward at the speed its feet push")
    // Each row says how fast the body goes and where it was MATCH_PAST seconds before.
    for r in db.ranges[:2] {
        for row in int(r.first)..<int(r.first+r.count) {
            path:=match_row_trajectory(&db,row)
            testing.expectf(t,linalg.length(path.velocity-r.travel.xz)<.05 && linalg.length(path.past+r.travel.xz*MATCH_PAST)<.05,"a row of a clip that goes %v says %v",r.travel,path)
        }
    }
    for row in 0..<db.rows {
        request:=Match_Request{query=match_features(&db,row),trajectory=match_row_trajectory(&db,row),modes=~u32(0)}
        best,cost,_:=match_search(&db,request)
        query,weights,_:=match_query(&db,request,match_range_of(&db,row))
        testing.expect(t,cost<1e-6 && match_cost(&db,best,query,weights)<1e-6,"every row is its own best match")
    }
    // From standing to a walk, at its own speed and at a half and a third of it by its rate: a
    // slowed walk costs what the body does, not more than one at its own rate; then back.
    for speed in ([3]f32{1.5,.75,.5}) {
        for facing in ([2]math.Vec3{{0,0,-1},{1,0,0}}) {
            request:=Match_Request{query=match_features(&db,int(db.ranges[0].first)),modes=1<<1,min_rate=.3,max_rate=1}
            request.trajectory=match_trajectory(facing*speed,facing*speed,20,20,facing,facing,0)
            path:=request.trajectory
            testing.expect(t,abs(path.positions[2].y+speed)<1e-4 && abs(path.positions[2].x)<1e-4 && abs(path.directions[0].y+1)<1e-4,"the trajectory is in the frame of the facing")
            best,_,rate:=match_search(&db,request)
            testing.expect(t,match_range_of(&db,best)==1 && abs(rate*db.ranges[1].speed-speed)<.05,"the walk plays at the rate that covers the speed")
        }
    }
    standing:=Match_Request{query=match_features(&db,int(db.ranges[1].first)+7),modes=1<<1,min_rate=.5,max_rate=1}
    standing.trajectory=match_trajectory({},{},20,20,{0,0,-1},{},0)
    best,_,_:=match_search(&db,standing)
    testing.expect_value(t,match_range_of(&db,best),0)
    standing.modes=1<<0
    best,_,_=match_search(&db,standing)
    testing.expect_value(t,match_range_of(&db,best),2)
    // A pose that plays at half its rate moves its feet at half their speed: the walk at its own
    // rate, with the trajectory of that frame, is no longer the same frame.
    walking:=int(db.ranges[1].first)+7
    costs:[2]f32
    for rate,i in ([2]f32{1,.5}) {
        request:=Match_Request{query=match_features(&db,walking),trajectory=match_row_trajectory(&db,walking),modes=1<<1,min_rate=.5,max_rate=1,rate=rate}
        query,weights,scaled:=match_query(&db,request,1)
        costs[i]=match_cost(&db,walking,query,weights)
        testing.expect(t,abs(scaled-1)<.05)
    }
    testing.expectf(t,costs[0]<.05 && costs[1]>costs[0]+1,"a pose at half its rate is not its own frame: %v",costs)
    testing.expect(t,match_database_size(db)==match_database_bytes(db.rows,len(db.ranges)))
    testing.expect_value(t,match_database_build(&db,&library,rig,clips[:],30,weights,match_database_bytes(db.rows,3)-1),Match_Build_Error.Memory_Limit)
    // Rates of its own replace those of the search for a clip: a walk let up to twice its speed
    // follows a body that goes 1.8 times as fast where the search stops the others at their own.
    rated:=clips;rated[1].rates={.5,2}
    if testing.expect(t,match_database_build(&db,&library,rig,rated[:],30,weights)==.None) {
        speed:=db.ranges[1].speed*1.8
        request:=Match_Request{query=match_features(&db,int(db.ranges[1].first)),modes=1<<1,min_rate=.5,max_rate=1}
        request.trajectory=match_trajectory({0,0,-speed},{0,0,-speed},20,20,{0,0,-1},{0,0,-1},0)
        _,_,scaled:=match_query(&db,request,1)
        testing.expectf(t,abs(scaled-1.8)<.05,"the walk plays at 1.8 by its own rates: %v",scaled)
        rated[1].rates={}
        if testing.expect(t,match_database_build(&db,&library,rig,rated[:],30,weights)==.None) {
            _,_,scaled=match_query(&db,request,1)
            testing.expectf(t,scaled==1,"without them it stops at the most of the search: %v",scaled)
        }
    }
    for refused in ([3][2]f32{{2,1},{0,1},{.5,cmath.inf_f32(1)}}) {
        rated[1].rates=refused
        testing.expect_value(t,match_database_build(&db,&library,rig,rated[:],30,weights),Match_Build_Error.Invalid)
    }
    // A speed set by hand replaces the measured one along the direction the feet push.
    told:=clips;told[1].speed=3
    if testing.expect(t,match_database_build(&db,&library,rig,told[:],30,weights)==.None) {
        testing.expectf(t,db.ranges[1].speed==3 && abs(db.ranges[1].travel.z+3)<1e-4,"walk told to go 3 m/s: %v",db.ranges[1])
        testing.expect(t,abs(db.ranges[0].speed-0)<.05)
    }
    // Feet that do not push (a jump in place) go where the body faces: idle turned a quarter to the
    // left, told 2 m/s, goes left, whatever its supports measure.
    quarter:=math.quat_axis_angle({0,1,0},cmath.PI/2)
    turned_keys:=[1]Keyframe{{value={imag(quarter),jmag(quarter),kmag(quarter),real(quarter)}}}
    turned_feet:=[2]Keyframe{{time=0,value={.1,-.95,0,0}},{time=1,value={.1,-.95,.001,0}}}
    turned,turned_error:=clip_add(&library,{name=base.name_hash("turned"),tracks={{target=rig.skeleton.names[1],property=.Rotation,keys=turned_keys[:]},{target=rig.skeleton.names[2],property=.Position,keys=turned_feet[:]}}})
    jumps:=[2]Match_Clip{told[0],{clips={0=turned},modes=1<<0,entry=true,speed=2}}
    if testing.expect(t,turned_error==.None && match_database_build(&db,&library,rig,jumps[:],30,weights)==.None) {
        testing.expectf(t,linalg.length(db.ranges[1].travel-{-2,0,0})<1e-3,"a turned clip in place told 2 m/s goes %v",db.ranges[1].travel)
    }
    told[1].speed=-1
    testing.expect_value(t,match_database_build(&db,&library,rig,told[:],30,weights),Match_Build_Error.Invalid)

    // A sample of idle and walk at a quarter each (half and half of their sum) is measured from
    // their blended pose: its rows are those of a clip keyed halfway between the two, and it
    // travels at half the speed of the walk.
    names:=rig.skeleton.names
    half_left:=[4]Keyframe{{time=0,value={.1,-.95,-.1875,0}},{time=.5,value={.1,-.95,.1875,0}},{time=.75,value={.1,-.875,0,0}},{time=1,value={.1,-.95,-.1875,0}}}
    half_right:=[4]Keyframe{{time=0,value={-.1,-.95,.1875,0}},{time=.25,value={-.1,-.875,0,0}},{time=.5,value={-.1,-.95,-.1875,0}},{time=1,value={-.1,-.95,.1875,0}}}
    still:=[2]Keyframe{{time=0,value={.1,-.95,0,0}},{time=.5,value={.1,-.95,0,0}}}
    other:=[2]Keyframe{{time=0,value={-.1,-.95,0,0}},{time=.5,value={-.1,-.95,0,0}}}
    halfway,e0:=clip_add(&library,{name=base.name_hash("halfway"),loop=.Loop,tracks={{target=names[2],property=.Position,keys=half_left[:]},{target=names[3],property=.Position,keys=half_right[:]}}})
    short,e1:=clip_add(&library,{name=base.name_hash("short"),loop=.Loop,tracks={{target=names[2],property=.Position,keys=still[:]},{target=names[3],property=.Position,keys=other[:]}}})
    if !testing.expect(t,e0==.None && e1==.None) {return}
    blend:=Match_Clip{clips={0=clips[0].clips[0],1=clips[1].clips[0]},weights={0=.25,1=.25},modes=1<<1}
    measured:=[5]Match_Clip{clips[0],clips[1],clips[2],blend,{clips={0=halfway},modes=1<<1}}
    if testing.expect(t,match_database_build(&db,&library,rig,measured[:],30,weights)==.None) {
        a,b:=db.ranges[3],db.ranges[4]
        testing.expectf(t,a.count==b.count && abs(a.speed-.75)<.1 && abs(a.speed-b.speed)<1e-3 && a.weights=={0=.5,1=.5} && a.clips==blend.clips,"a blend of idle and walk goes half as fast as the walk: %v",a)
        for k in 0..<int(a.count) {
            difference:=match_features(&db,int(a.first)+k)-match_features(&db,int(b.first)+k)
            largest:f32
            for lane in difference {for v in simd.to_array(lane) {largest=max(largest,abs(v))}}
            testing.expectf(t,largest<1e-3,"row %d of the blend is that of the blended pose, off by %v",k,largest)
        }
    }
    // A blend whose clips last different times, one that does not loop, or a weight out of 0..1.
    unequal:=blend;unequal.clips[1]=short
    once:=blend;once.clips[1]=clips[1].clips[0];data:=&library.clips[clips[1].clips[0]-1];data.loop=.Once
    for refused,i in ([3]Match_Clip{unequal,once,{clips=blend.clips,weights={0=1.5,1=.5},modes=1<<1}}) {
        attempt:=[2]Match_Clip{clips[0],refused}
        testing.expectf(t,match_database_build(&db,&library,rig,attempt[:],30,weights)==.Invalid,"blend %d is refused",i)
        if i==1 {data.loop=.Loop}
    }
}

@(test)
match_search_skips_runs_by_their_bounds_and_enters_a_mode_by_its_entry_clips :: proc(t:^testing.T) {
    library:Library;defer library_destroy(&library)
    rig,clips,ok:=match_test_rig(&library)
    if !testing.expect(t,ok) {return}
    // Every clip three times at 120 rows a second: past MATCH_LINEAR_ROWS, so the database keeps bounds.
    many:[9]Match_Clip
    for &clip,i in many {clip=clips[i%3];clip.entry=i%3==2}
    db:Match_Database;defer match_database_free(&db)
    if !testing.expect(t,match_database_build(&db,&library,rig,many[:],120)==.None) || !testing.expect(t,db.rows>MATCH_LINEAR_ROWS && len(db.small)>0 && len(db.large)>0) {return}
    for row in 0..<db.rows {
        if db.ranges[match_range_of(&db,row)].entry {continue}
        request:=Match_Request{query=match_features(&db,(row*7919)%db.rows),trajectory=match_row_trajectory(&db,row),modes=~u32(0),min_rate=.5,max_rate=1}
        span:=f32(5)/db.rate
        best,cost,_:=match_search(&db,request,row,false,span)
        reach:=int(cmath.ceil(span*db.rate))
        playing:=match_range_of(&db,row)
        least:=max(f32)
        for r,range in db.ranges {
            if r.entry {continue}
            query,weights,_:=match_query(&db,request,range)
            for frame in 0..<int(r.count)-match_tail(&db,range) {
                candidate:=int(r.first)+frame
                if range==playing && (match_behind(r,candidate,row,reach) || match_behind(r,row,candidate,reach)) {continue}
                least=min(least,match_cost(&db,candidate,query,weights))
            }
        }
        testing.expect(t,best>=0 && cost==least,"the bounded search finds the row the whole scan finds")
    }
    falling:=Match_Request{query=match_features(&db,0),modes=1<<0}
    best,_,_:=match_search(&db,falling)
    testing.expect(t,best<0 && !match_serves(&db,1<<0,false) && match_serves(&db,1<<0,true),"an entry clip is left out of the steady search")
    falling.entry=true
    best,_,_=match_search(&db,falling)
    range:=match_range_of(&db,best)
    testing.expect(t,range>=0 && db.ranges[range].entry && f32(best-int(db.ranges[range].first))<=MATCH_ENTRY_SPAN*db.rate+1,"entering a mode searches the starts of its entry clips")
}

@(test)
match_trajectory_follows_a_walk_that_accelerates_brakes_and_turns_at_its_rates :: proc(t:^testing.T) {
    Case :: struct {velocity,desired,facing,wanted:math.Vec3,acceleration,braking,turn:f32}
    cases:=[]Case{
        {velocity={},desired={0,0,-3},facing={0,0,-1},wanted={0,0,-1},acceleration=20,braking=20},
        {velocity={0,0,-3},desired={},facing={0,0,-1},acceleration=8,braking=4},
        {velocity={2,0,0},desired={0,0,2.5},facing={1,0,0},wanted={0,0,1},acceleration=6,braking=10,turn=cmath.PI},
        {velocity={1,5,0},desired={1,0,0},facing={0,0,-1},wanted={1,0,0},acceleration=0,braking=0},
    }
    for c in cases {
        path:=match_trajectory(c.velocity,c.desired,c.acceleration,c.braking,c.facing,c.wanted,c.turn)
        positions,directions:=path.positions,path.directions
        STEPS :: 600
        velocity:=math.Vec3{c.velocity.x,0,c.velocity.z};position,facing:math.Vec3
        rate:=c.braking if c.desired=={} else c.acceleration
        inverse:=math.quat_inverse(match_yaw(c.facing))
        step:=0
        for horizon,k in MATCH_HORIZON {
            for ;step<int(cmath.round(horizon*STEPS));step+=1 {
                change:=c.desired-velocity
                if length:=linalg.length(change);length>rate/STEPS {velocity+=change*(rate/STEPS/length)} else {velocity=c.desired}
                position+=velocity/STEPS
            }
            local:=math.quat_rotate(inverse,position)
            testing.expect(t,linalg.length(math.Vec2{local.x,local.z}-positions[k])<.01,"positions follow the velocity of a walk")
            facing=c.facing
            if c.wanted!={} {
                angle:=cmath.atan2(linalg.dot(linalg.cross(c.facing,c.wanted),math.Vec3{0,1,0}),linalg.dot(c.facing,c.wanted))
                turned:=angle if c.turn<=0 else clamp(angle,-c.turn*horizon,c.turn*horizon)
                facing=math.quat_rotate(math.quat_axis_angle({0,1,0},turned),c.facing)
            }
            toward:=math.quat_rotate(inverse,facing)
            testing.expect(t,linalg.length(math.Vec2{toward.x,toward.z}-directions[k])<1e-4,"the facing turns at its rate")
        }
    }
    // A wall ahead keeps the body and what it is asked for out of it: along the wall, it slides.
    blocked:=match_trajectory({0,0,-.5},{3,0,-3},20,20,{0,0,-1},{0,0,-1},0,wall={0,0,1})
    testing.expectf(t,abs(blocked.positions[2].y)<1e-4 && blocked.positions[2].x>2 && blocked.velocity=={},"a wall ahead stops what goes into it, not %v",blocked)
    // The past point is where the trail of the body says it was: half a second standing, then a sixth walking.
    trail:Match_Trail
    for _ in 0..<30 {match_trail_add(&trail,{},1.0/60)}
    for _ in 0..<10 {match_trail_add(&trail,{0,0,-3},1.0/60)}
    walked:=match_trajectory({0,0,-3},{0,0,-3},20,20,{0,0,-1},{0,0,-1},0,trail=&trail)
    steady:=match_trajectory({0,0,-3},{0,0,-3},20,20,{0,0,-1},{0,0,-1},0)
    testing.expectf(t,linalg.length(walked.past-{0,.5})<1e-4 && linalg.length(walked.velocity-{0,-3})<1e-4,"a body that stood until a sixth of a second ago was half a metre back, not %v",walked.past)
    testing.expectf(t,linalg.length(steady.past-{0,1})<1e-4,"without a trail it went at its velocity, not %v",steady.past)
    // The same at any tick: many short ones, or one longer than the past.
    for ticks in ([2]int{240,1}) {
        fast:Match_Trail
        dt:=f32(1)/f32(ticks)
        if ticks>1 {for _ in 0..<ticks/2 {match_trail_add(&fast,{},dt)}}
        for _ in 0..<max(ticks/6,1) {match_trail_add(&fast,{0,0,-3},dt if ticks>1 else 1)}
        moved:=match_trail_moved(fast,{0,0,-3})
        expected:=f32(.5) if ticks>1 else 1
        testing.expectf(t,abs(moved.z+expected)<1e-3,"%d ticks a second: %.4f m in the past, not %.4f",ticks,moved.z,expected)
    }
}

// The walk and the clips of match_test_rig, with a step: half a second of walk that does not loop.
@(private="file")
match_test_steps :: proc(t:^testing.T,library:^Library,db:^Match_Database) -> bool {
    rig,clips,ok:=match_test_rig(library)
    if !ok {return false}
    left:=[3]Keyframe{{time=0,value={.1,-.95,-.375,0}},{time=.25,value={.1,-.95,0,0}},{time=.5,value={.1,-.95,.375,0}}}
    right:=[3]Keyframe{{time=0,value={-.1,-.95,.375,0}},{time=.25,value={-.1,-.8,0,0}},{time=.5,value={-.1,-.95,-.375,0}}}
    step,error:=clip_add(library,{name=base.name_hash("step"),tracks={{target=rig.skeleton.names[2],property=.Position,keys=left[:]},{target=rig.skeleton.names[3],property=.Position,keys=right[:]}}})
    if error!=.None {return false}
    all:=[4]Match_Clip{clips[0],clips[1],clips[2],{clips={0=step},modes=1<<1}}
    return match_database_build(db,library,rig,all[:],30)==.None && testing.expect(t,!db.ranges[3].loop && db.ranges[3].speed>MATCH_STILL)
}

@(test)
match_search_leaves_out_rows_near_the_playing_one_across_a_loop_seam_and_those_just_left :: proc(t:^testing.T) {
    library:Library;defer library_destroy(&library)
    db:Match_Database;defer match_database_free(&db)
    if !testing.expect(t,match_test_steps(t,&library,&db)) {return}
    walk:=db.ranges[1];period:=int(walk.count-1)
    span:=f32(.1) // three rows
    playing:=int(walk.first)+1
    seam:=int(walk.first)+period-2
    request:=Match_Request{query=match_features(&db,seam),trajectory=match_row_trajectory(&db,seam),modes=1<<1}
    best,_,_:=match_search(&db,request)
    testing.expect_value(t,best,seam)
    best,_,_=match_search(&db,request,playing,false,span)
    gap:=abs(best-playing);if match_range_of(&db,best)==1 {gap=min(gap,period-gap)}
    testing.expectf(t,gap>3,"a row two behind the one playing, across the seam of its loop, is left out, not %d",best)
    // A rig that left a row a tick ago does not jump back to what it played just before.
    recent:Match_Recent
    left:=int(walk.first)+12
    match_recent_leave(&recent,left)
    match_recent_advance(&recent,1.0/30,span)
    request.query,request.trajectory=match_features(&db,left-2),match_row_trajectory(&db,left-2)
    best,_,_=match_search(&db,request,-1,false,span,&recent)
    testing.expectf(t,best<left-2 || best>left,"the rows played just before leaving are left out, not %d",best-int(walk.first))
    match_recent_advance(&recent,span,span)
    best,_,_=match_search(&db,request,-1,false,span,&recent)
    testing.expect(t,recent.count==0 && best==left-2,"a row left span seconds ago is searched again")
}

@(test)
a_clip_shorter_than_the_trajectory_keeps_its_last_rows_out_of_the_search :: proc(t:^testing.T) {
    library:Library;defer library_destroy(&library)
    db:Match_Database;defer match_database_free(&db)
    if !testing.expect(t,match_test_steps(t,&library,&db)) {return}
    r:=db.ranges[3];tail:=match_tail(&db,3)
    testing.expectf(t,tail==int(cmath.ceil(MATCH_TAIL_MIN*db.rate)) && tail<int(r.count),"a short clip keeps %d of its %d rows out",tail,r.count)
    last:=int(r.first+r.count)-1
    request:=Match_Request{query=match_features(&db,last),trajectory=match_row_trajectory(&db,last),modes=1<<1}
    best,_,_:=match_search(&db,request)
    testing.expectf(t,best<int(r.first+r.count)-tail,"its last rows are not entered, not row %d of %d",best-int(r.first),r.count)
}

@(private="file")
match_test_reasons :: proc(db:^Match_Database,noted:Match_Candidates) -> (reasons:[4]Match_Reject) {
    for &reason in reasons {reason=max(Match_Reject)}
    for item,i in noted.items {
        if i>=int(noted.count) {break}
        if range:=match_range_of(db,int(item.row));range>=0 && range<4 {reasons[range]=item.reason}
    }
    return
}

// Noted, the clips it leaves out say why, after those it could pick, each part least cost first.
@(test)
a_body_that_stands_leaves_out_every_clip_that_moves_and_one_that_moves_every_clip_that_stands :: proc(t:^testing.T) {
    library:Library;defer library_destroy(&library)
    db:Match_Database;defer match_database_free(&db)
    if !testing.expect(t,match_test_steps(t,&library,&db)) {return}
    row:=int(db.ranges[3].first)+2
    request:=Match_Request{query=match_features(&db,row),trajectory=match_row_trajectory(&db,row),modes=1<<1,filter_stationary=true,moving=true}
    noted:Match_Candidates
    best,_,_:=match_search(&db,request,candidates=&noted)
    testing.expect_value(t,best,row)
    reasons:=match_test_reasons(&db,noted)
    testing.expectf(t,int(noted.items[0].row)==best && reasons=={.Stationary,.Cost,.Mode,.None},"a moving body leaves out idle and the fall: %v",reasons)
    rank :: proc(c:Match_Candidate) -> int {return 0 if c.reason<=.Cost else 2 if c.reason==.Mode else 1}
    for item,i in noted.items[1:noted.count] {
        before:=noted.items[i]
        testing.expect(t,rank(before)==rank(item) && before.cost<=item.cost || rank(before)<rank(item),"those it could pick first, those of other modes last, each part least cost first")
    }
    // A pose of the fall costs least as the fall itself, which serves another mode: still last.
    fall:=Match_Request{query=match_features(&db,int(db.ranges[2].first)),trajectory=match_row_trajectory(&db,int(db.ranges[2].first)),modes=1<<1,filter_stationary=true,moving=true}
    match_search(&db,fall,candidates=&noted)
    testing.expectf(t,noted.count>0 && noted.items[noted.count-1].reason==.Mode,"the clip of another mode goes last: %v",noted.items[:noted.count])
    // The step playing, searched whole, is left out by the reselect.
    request.filter_stationary=false
    best,_,_=match_search(&db,request,row,true,.1,nil,&noted)
    reasons=match_test_reasons(&db,noted)
    testing.expectf(t,best!=row && reasons[3]==.Reselect,"the step playing is left out by the reselect: %v",reasons)
    request.filter_stationary,request.moving=true,false
    best,_,_=match_search(&db,request)
    testing.expectf(t,match_range_of(&db,best)==0,"a body that stands plays the clip that stands, not one that walks once (range %d)",match_range_of(&db,best))
}

// The clips of match_test_rig and a jump of a second, an entry of the air, whose feet leave the
// ground and touch it again at .8 s, where its marker 0 is; and the same jump marked by its own
// marker 1 of that event, as each clip of a library names its landing.
@(private="file")
match_test_jump :: proc(t:^testing.T,library:^Library,db:^Match_Database) -> bool {
    rig,clips,ok:=match_test_rig(library)
    if !ok {return false}
    left:=[4]Keyframe{{time=0,value={.1,-.95,0,0}},{time=.4,value={.1,-.5,0,0}},{time=.8,value={.1,-.95,0,0}},{time=1,value={.1,-.95,0,0}}}
    right:=[4]Keyframe{{time=0,value={-.1,-.95,0,0}},{time=.4,value={-.1,-.5,0,0}},{time=.8,value={-.1,-.95,0,0}},{time=1,value={-.1,-.95,0,0}}}
    land:=[1]Marker{{time=.8,id=0}}
    jump,error:=clip_add(library,{name=base.name_hash("jump"),tracks={{target=rig.skeleton.names[2],property=.Position,keys=left[:]},{target=rig.skeleton.names[3],property=.Position,keys=right[:]}},markers=land[:]})
    if error!=.None {return false}
    again:=[1]Marker{{time=.8,id=1}}
    other,other_error:=clip_add(library,{name=base.name_hash("jump again"),tracks={{target=rig.skeleton.names[2],property=.Position,keys=left[:]},{target=rig.skeleton.names[3],property=.Position,keys=right[:]}},markers=again[:]})
    if other_error!=.None {return false}
    all:=[5]Match_Clip{clips[0],clips[1],clips[2],{clips={0=jump},modes=1<<0,entry=true},{clips={0=other},modes=1<<0,entry=true}}
    events:=[2]u32{0,1}
    return match_database_build(db,library,rig,all[:],30,event=events[:])==.None
}

@(test)
an_event_searches_the_rows_that_reach_its_marker_in_time_at_the_rate_that_does :: proc(t:^testing.T) {
    library:Library;defer library_destroy(&library)
    db:Match_Database;defer match_database_free(&db)
    if !testing.expect(t,match_test_jump(t,&library,&db)) {return}
    jump:=db.ranges[3]
    testing.expect(t,len(db.events)==db.rows && match_database_size(db)==match_database_bytes(db.rows,5,true))
    testing.expect(t,match_event_serves(&db,1<<0) && !match_event_serves(&db,1<<1),"the air has a clip that lands, the ground none")
    testing.expect(t,match_event_ahead(&db,4,0)>0,"the clip marked by another marker of the event lands too")
    for frame in 0..<int(jump.count) {
        ahead:=db.events[int(jump.first)+frame];at:=f32(frame)/db.rate
        testing.expectf(t,abs(ahead-(.8-at))<1e-4 if at<=.8+1e-4 else ahead<0,"row %d of the jump is %.3f s from its marker",frame,ahead)
    }
    // Entering the air .6 s before it lands: the start of the jump, at the rate that lands it then.
    request:=Match_Request{query=match_features(&db,int(db.ranges[0].first)),modes=1<<0,entry=true,event=.6,event_rates={.5,2}}
    best,_,rate:=match_search(&db,request)
    start:=best-int(jump.first)
    testing.expectf(t,match_range_of(&db,best)==3 && start<=int(cmath.ceil(MATCH_ENTRY_SPAN*db.rate)) && abs(rate*request.event-db.events[best])<1e-4,"the jump starts at row %d at rate %.3f",start,rate)
    // .25 s before it lands no start reaches the marker below twice its rate: off a ledge, any row
    // of the air that does, at the rate that does.
    request.event=.25
    best,_,_=match_search(&db,request)
    testing.expect(t,best<0,"no start lands in .25 s")
    request.entry=false
    best,_,rate=match_search(&db,request)
    ahead:=db.events[best] if best>=0 else -1
    testing.expectf(t,match_range_of(&db,best)==3 && ahead>=.125 && ahead<=.5 && abs(rate*.25-ahead)<1e-4,"a row of the jump .125 to .5 s from its marker, not %.3f s at rate %.3f",ahead,rate)
    // In the air the arc goes on: with a row .3 s from its marker playing, no row further from its
    // own is taken, the start of the jump least of all.
    noted:Match_Candidates
    request.event,request.event_from,request.entry=.3,.3,false
    best,_,_=match_search(&db,request,candidates=&noted)
    testing.expectf(t,best>=0 && db.events[best]<=.3+1/db.rate,"a row at most .3 s from its marker, not %.3f s",db.events[best] if best>=0 else -1)
    request.event,request.event_from=.6,.1
    best,_,_=match_search(&db,request,candidates=&noted)
    reasons:=match_test_reasons(&db,noted)
    testing.expectf(t,best<0 && reasons[3]==.Window,"rows .6 s away go back in the arc: %v",reasons)
    request.event_from=0
    // A jump whose marker comes less than half a row early even at the slowest rate still plays,
    // at that rate.
    request.event,request.entry=(.8+.25/db.rate)/.5,true
    best,_,rate=match_search(&db,request)
    testing.expectf(t,match_range_of(&db,best)>=3 && rate==.5,"a start a frame early at rate .5, not row %d at %.3f",best,rate)
    request.entry=false
    // Ten seconds before it lands no row reaches it: the jump lands too soon (Window), the fall loop
    // has no marker (Event) and the ground serves another mode.
    request.event=10
    best,_,_=match_search(&db,request,candidates=&noted)
    reasons=match_test_reasons(&db,noted)
    testing.expectf(t,best<0 && reasons=={.Mode,.Mode,.Event,.Window},"nothing lands in 10 s: %v",reasons)
    // Without an event the entry jump is left out of the steady search of the air.
    request.event=0
    best,_,_=match_search(&db,request,candidates=&noted)
    reasons=match_test_reasons(&db,noted)
    testing.expectf(t,match_range_of(&db,best)==2 && reasons=={.Mode,.Mode,.None,.Entry},"the steady search of the air: %v",reasons)
}
