package anim

import "base:runtime"
import cmath "core:math"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/ai"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// The walk of the demo Mirai (its Walk and turn) and the modes of a Character, without the physics.
@(private="file") MIRAI_AVATAR_WALK_SPEED :: 2.9154
@(private="file") MIRAI_AVATAR_ACCELERATION :: 20.48
@(private="file") MIRAI_AVATAR_BRAKING :: 20
@(private="file") MIRAI_AVATAR_TURN :: 500*mm.RAD_PER_DEG
@(private="file") MIRAI_AVATAR_JUMP :: 4.2 // m/s up: a jump of .9 m
@(private="file") MODE_FALLING,MODE_WALKING :: u16(0),u16(1)
@(private="file") MODE_FALL,MODE_WALK :: u32(1)<<MODE_FALLING,u32(1)<<MODE_WALKING
@(private="file") TICKS :: 720

// Wish of the stick at a tick: stand, walk, stop, half stick, turns of 90 and 180 degrees, and
// a jump while it walks.
@(private="file")
mirai_avatar_wish :: proc(tick:int) -> (wish:mm.Vec3,jump:bool) {
    switch {
    case tick<60: return {},false
    case tick<180: return {0,0,-1},false
    case tick<240: return {},false
    case tick<360: return {0,0,-.5},false
    case tick<420: return {1,0,0},false
    case tick<480: return {0,0,1},false
    case tick<660: return {0,0,-1},tick==540
    }
    return {},false
}

@(private="file")
Mirai_Body :: struct {position,velocity:mm.Vec3,yaw:f32,mode:u16,jumped:bool}

@(private="file")
mirai_avatar_body_step :: proc(body:^Mirai_Body,wish:mm.Vec3,jump:bool,dt:f32) {
    desired:=wish*MIRAI_AVATAR_WALK_SPEED
    if body.mode==MODE_WALKING {
        flat:=mm.Vec3{body.velocity.x,0,body.velocity.z}
        rate:=f32(MIRAI_AVATAR_BRAKING) if desired=={} else MIRAI_AVATAR_ACCELERATION
        change:=desired-flat
        if length:=linalg.length(change);length>rate*dt {flat+=change*(rate*dt/length)} else {flat=desired}
        body.velocity={flat.x,0,flat.z}
        if jump {body.velocity.y,body.mode,body.jumped=MIRAI_AVATAR_JUMP,MODE_FALLING,true}
    } else {
        body.velocity.y-=9.81*dt
    }
    if linalg.length(wish)>.001 {body.yaw=mm.angle_wrap(mm.angle_approach(body.yaw,mm.yaw_of_direction(wish),MIRAI_AVATAR_TURN*dt))}
    body.position+=body.velocity*dt
    if body.mode==MODE_FALLING && body.position.y<=0 && body.velocity.y<=0 {body.position.y,body.velocity.y,body.mode,body.jumped=0,0,MODE_WALKING,false}
}

@(private="file")
Mirai_Metrics :: struct {
    slide_sum,slide_max:f32,slide_samples:int,
    pop_max,pop_sum:f32,pops,pop_samples:int,
    response_sum:f32,responses,changes:int,
    nanoseconds,load:f64, // per tick after the first, and of the first: the load and the database
    searches,jumps:u32,
}

@(private)
@(test_world)
Match_World :: struct {
    using world:Test_World,
    transforms:core.Table(core.Transform),
    animations:core.Table(Animation),
}

// Walks a Mirai of the demo by the locomotion of its .character through the program of the runtime, and
// measures what its pose does: how far a planted toe slides, the second difference of every bone
// (a jump of the pose), and the ticks until the speed the pose walks at follows a change of the
// stick. The jump and the landing are entry clips of their modes.
@(private="file")
mirai_avatar_walk :: proc(t:^testing.T,app:^host.App,skeletons:^Skeleton_Assets,graphs:^Character_Assets,id,skeleton:base.Asset_Id) -> (metrics:Mirai_Metrics,ok:bool) {
    w:Match_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    entity:=core.create(&w.entities);core.add(&w.transforms,entity,core.TRANSFORM_IDENTITY);test_world_settle(&w)
    animation:=ANIMATION_DEFAULT;animation.asset=id
    state:=Playing{entity=entity,clip=-1};defer playing_free(&state)
    playback:Playback;defer playback_free(&playback)
    events:Animation_Events;defer delete(events.items)
    match:=character_content(graphs,app.assets,app.allocator,id);if match==nil {return}
    content:=host.content_animation(app,match.set.info.animation)
    definition:=skeleton_content(skeletons,app.assets,app.allocator,skeleton)
    if content==nil || definition==nil || !skeleton_bind(&playback,&state,definition,content,&w.transforms) {return}
    toes:=[2]int{bone_resolve(&state,bone_ref("LeftToeBase")),bone_resolve(&state,bone_ref("RightToeBase"))}
    if toes[0]<0 || toes[1]<0 {return}
    n:=len(playing_pose(&state,.Local))
    world,rig,last,before:=make([]mm.Transform,n),make([]mm.Transform,n),make([]mm.Vec3,n),make([]mm.Vec3,n)
    defer {delete(world);delete(rig);delete(last);delete(before)}
    lib.pose_world(playing_topology(&state).parents[:],playing_topology(&state).rest[:],rig)
    floor:=max(rig[toes[0]].position.y,rig[toes[1]].position.y)+.02
    body:=Mirai_Body{mode=MODE_WALKING}
    dt:=f32(1.0/60)
    previous_toes:[2]mm.Vec3;planted:[2]bool
    target:f32;changed:=-1
    for tick in 0..<TICKS {
        wish,jump:=mirai_avatar_wish(tick)
        if speed:=linalg.length(wish)*MIRAI_AVATAR_WALK_SPEED;speed!=target {target,changed=speed,tick;metrics.changes+=1}
        // What the animation reads is what the body did in the last tick.
        flat:=mm.Vec3{body.velocity.x,0,body.velocity.z};speed:=linalg.length(flat)
        facing:=mm.Vec3{-cmath.sin(body.yaw),0,-cmath.cos(body.yaw)}
        goals:=[1]Match_Goal{{rig=entity,mode=body.mode,velocity=body.velocity,desired=wish*MIRAI_AVATAR_WALK_SPEED,facing=wish,acceleration=MIRAI_AVATAR_ACCELERATION,braking=MIRAI_AVATAR_BRAKING,turn_rate=MIRAI_AVATAR_TURN}}
        start:=time.tick_now()
        copy(playing_pose(&state,.Local),playing_topology(&state).rest[:])
        clear(&events.items)
        output,programmed,resolved:=program_resolve(&state,animation,app,graphs,dt,&events,&playback,content,nil,goals[:],facing)
        if !resolved || !programmed || !curves_prepare(&state,content) || !program_players(&state,output,content,animation,&events,&playback,dt,-1,nil) || !stack_inertia_prepare(&state) {
            log.errorf("tick %d: %v",tick,state.program.error);return
        }
        playback.frame+=1
        if pose_compose(&playback,&state,content,animation,true,dt,core.read(&w.transforms),0).program {return}
        if tick==0 {metrics.load=f64(time.duration_nanoseconds(time.tick_since(start)))} else {metrics.nanoseconds+=f64(time.duration_nanoseconds(time.tick_since(start)))}
        walked:=state.program.match.speed*state.program.match.rate
        mirai_avatar_body_step(&body,wish,jump,dt)
        // The root of the pose where the spring of matching leaves it from the body.
        match_lag_apply(&state,{position=body.position,rotation=mm.quat_axis_angle({0,1,0},body.yaw),scale={1,1,1}})
        // Where the pose puts the toes in the world, and how much the pose itself jumped.
        playing_pose(&state,.Local)[0]={body.position,mm.quat_axis_angle({0,1,0},body.yaw),{1,1,1}}
        lib.pose_world(playing_topology(&state).parents[:],playing_pose(&state,.Local),world)
        playing_pose(&state,.Local)[0]=mm.TRANSFORM_IDENTITY
        lib.pose_world(playing_topology(&state).parents[:],playing_pose(&state,.Local),rig)
        if tick>=2 {
            // Over the joints of the body: the helper bones of the rig (ik_*) are not skinned.
            worst:f32
            for b in state.body {if b>0 {worst=max(worst,linalg.length(rig[b].position-2*last[b]+before[b]))}}
            metrics.pop_max=max(metrics.pop_max,worst);metrics.pop_sum+=worst;metrics.pop_samples+=1
            if worst>.1 {metrics.pops+=1}
        }
        for b in 0..<n {before[b]=last[b];last[b]=rig[b].position}
        for toe,i in toes {
            position:=world[toe].position
            // A toe low on the ground that moves slower than half the walk stands: one faster swings past it.
            slide:=linalg.length(mm.Vec2{position.x-previous_toes[i].x,position.z-previous_toes[i].z})/dt
            down:=body.mode==MODE_WALKING && position.y-body.position.y<floor && slide<MIRAI_AVATAR_WALK_SPEED*.5
            if down && planted[i] {metrics.slide_sum+=slide;metrics.slide_max=max(metrics.slide_max,slide);metrics.slide_samples+=1}
            previous_toes[i],planted[i]=position,down
        }
        if changed>=0 && abs(walked-target)<=.3 {metrics.response_sum+=f32(tick-changed);metrics.responses+=1;changed=-1}
    }
    metrics.nanoseconds/=TICKS-1
    metrics.searches,metrics.jumps=state.program.match.searches,state.program.match.jumps
    return metrics,true
}

@(test)
matching_walks_mirai_avatar_with_its_feet_planted_without_pose_jumps_and_follows_the_stick :: proc(t:^testing.T) {
    root,found:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !testing.expect(t,found,"MIRAI_ROOT names the repository, whose demo has Mirai") {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=fmt.tprintf("%s/demo",root),capacity=512})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator};defer host.app_content_destroy(&app)
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    graphs:Character_Assets;defer character_assets_free(&graphs)
    ids:[3]base.Asset_Id
    for file,i in ([3]string{"assets/characters/mirai/mirai_matching.character","assets/characters/mirai/mirai_locomotion.anim","assets/characters/mirai/Armature.skeleton"}) {
        record,present:=asset.registry_find_path(&assets.registry,file)
        if !testing.expectf(t,present,"the demo has %s",file) {return}
        ids[i]=record.id
    }
    matched,matched_ok:=mirai_avatar_walk(t,&app,&skeletons,&graphs,ids[0],ids[2])
    if !testing.expect(t,matched_ok) {return}
    database,rows:=0,0
    search:f64
    for &content in graphs.contents {for &built in content.databases {if built.error==.None {
        database,rows=lib.match_database_size(built.database),built.database.rows
        request:=lib.Match_Request{query=lib.match_features(&built.database,0),trajectory=lib.match_row_trajectory(&built.database,0),modes=~u32(0),min_rate=.5,max_rate=1}
        start:=time.tick_now();sink:=0
        for _ in 0..<1000 {best,_,_:=lib.match_search(&built.database,request);sink+=best}
        search=f64(time.duration_nanoseconds(time.tick_since(start)))/1000
        testing.expect(t,sink>=0)
    }}}
    slide:=matched.slide_sum/f32(max(matched.slide_samples,1));response:=matched.response_sum/f32(max(matched.responses,1))
    log.infof("slide mean | slide max | pose jump mean | pose jump max | jumps >10 cm | response   | ns/tick | first tick | database          | searches | jumps | ns/search")
    log.infof("%.3f m/s  | %.3f m/s | %.4f m        | %.4f m       | %d            | %.1f ticks | %.0f   | %.0f ns  | %d B, %d rows | %d     | %d  | %.0f",slide,matched.slide_max,matched.pop_sum/f32(max(matched.pop_samples,1)),matched.pop_max,matched.pops,response,matched.nanoseconds,matched.load,database,rows,matched.searches,matched.jumps,search)
    testing.expect(t,database>0)
    testing.expect(t,matched.responses==matched.changes,"the pose follows every change of the stick")
    testing.expectf(t,slide<.25,"a planted toe slides %.3f m/s on average",slide)
    testing.expectf(t,matched.pop_max<.2,"the pose jumps %.3f m at most between ticks",matched.pop_max)
    testing.expectf(t,response<10,"the walk follows the stick in %.1f ticks on average",response)
}

@(private="file") MATCH_TEST_ID :: base.Asset_Id{0x3a7c,1}
@(private="file") GROUND,AIR :: u16(1),u16(0)

// Hips over two feet and a head, as the matching of std/anim: idle and walk on the ground, a fall
// loop in the air and jump, the entry clip of the air, whose marker 'land' is at .8 s. With leap,
// leap is another entry of the air that lands at .8 s and travels at 3 m/s. The others are not in
// the locomotion of the .character; its .character plays them: vault, for two seconds over the whole body, with a
// marker 'release' at .35 s; lunge, which takes the hips a metre along -Z in a second; kick, a foot
// forward for a second with a marker 'hit' at .5 s, in the layer Leg over the left foot; the
// layer Aim, which adds over the head the offset its axis aim_yaw gives between aim_left and
// aim_right, from aim_center; stomp, which swings the left foot from .2 m back to 1.2 m back at
// 2 m/s and returns it, with the right foot .2 m forward; and plant, which holds the left foot
// .65 m back.
@(private="file")
Match_Fixture :: struct {
    using w:Match_World,
    bones:[4]asset.Skeleton_Bone,
    pairs:[4]i32, // the bone on the other side of each
    definition:Skeleton_Content,
    content:host.Content_Animation,
    assets:host.Assets,
    app:host.App,
    graphs:Character_Assets,
    actions:Action_Runtime,
    playback:Playback,
    events:Animation_Events,
    requests:Animation_Requests,
    played:core.Table(Animation_Played),
    remotes:core.Table(core.Remote),
    problems:core.Problems,
    animation:Animation,
    rig:core.Entity,
    state:^Playing,
}

@(private="file")
// walk_spans: markers of the walk, of id 4 (hold) or 5 (stumble), with the spans of the set.
match_fixture :: proc(t:^testing.T,f:^Match_Fixture,memory:u32=MATCH_INFO_DEFAULT.memory,leap:=false,walk_spans:[]lib.Marker={},spans:[]Match_Span={}) -> bool {
    if !test_world_init(t,&f.w) {return false}
    f.rig=core.create(&f.entities)
    f.animation=ANIMATION_DEFAULT;f.animation.asset=MATCH_TEST_ID
    core.add(&f.transforms,f.rig,core.TRANSFORM_IDENTITY);core.add(&f.animations,f.rig,f.animation);test_world_settle(&f.w)
    Bone :: struct {name,path:string,at:mm.Vec3}
    for bone,i in ([4]Bone{{"hips","hips",{0,1,0}},{"foot_l","hips/foot_l",{.1,-.95,0}},{"foot_r","hips/foot_r",{-.1,-.95,0}},{"head","hips/head",{0,.7,0}}}) {
        f.bones[i]={parent=-1 if i==0 else 0,translation=bone.at,rotation=1,scale={1,1,1},target=base.name_hash(bone.path)}
        base.text_set(f.bones[i].name[:],bone.name);base.text_set(f.bones[i].path[:],bone.path)
    }
    // Its feet and hips, which matching measures, are those of its body.
    f.pairs={0,2,1,3}
    f.definition={id={0x3a7c,2},revision=1,bones=f.bones[:],body=lib.body_map_empty(),mirror=f.pairs[:]}
    f.definition.body.bones[.Pelvis],f.definition.body.bones[.Foot_L],f.definition.body.bones[.Foot_R],f.definition.body.bones[.Head]=0,1,2,3;f.definition.body.up={0,1,0}
    hips,left,right,head:=f.bones[0].target,f.bones[1].target,f.bones[2].target,f.bones[3].target
    still:=[2]lib.Keyframe{{time=0,value={.1,-.95,0,0}},{time=1,value={.1,-.95,0,0}}}
    other:=[2]lib.Keyframe{{time=0,value={-.1,-.95,0,0}},{time=1,value={-.1,-.95,0,0}}}
    stride_l:=[4]lib.Keyframe{{time=0,value={.1,-.95,-.375,0}},{time=.5,value={.1,-.95,.375,0}},{time=.75,value={.1,-.8,0,0}},{time=1,value={.1,-.95,-.375,0}}}
    stride_r:=[4]lib.Keyframe{{time=0,value={-.1,-.95,.375,0}},{time=.25,value={-.1,-.8,0,0}},{time=.5,value={-.1,-.95,-.375,0}},{time=1,value={-.1,-.95,.375,0}}}
    tucked:=[2]lib.Keyframe{{time=0,value={.1,-.6,-.1,0}},{time=1,value={.1,-.6,-.1,0}}}
    rise_l:=[2]lib.Keyframe{{time=0,value={.1,-.95,0,0}},{time=1,value={.1,-.5,-.2,0}}}
    rise_r:=[2]lib.Keyframe{{time=0,value={-.1,-.95,0,0}},{time=1,value={-.1,-.5,-.2,0}}}
    over_l:=[2]lib.Keyframe{{time=0,value={.1,-.3,-.5,0}},{time=2,value={.1,-.3,.5,0}}}
    over_r:=[2]lib.Keyframe{{time=0,value={-.1,-.3,-.5,0}},{time=2,value={-.1,-.3,-.5,0}}}
    lift_l:=[2]lib.Keyframe{{time=0,value={.1,-.95,0,0}},{time=1,value={.1,-.5,0,0}}}
    lift_r:=[2]lib.Keyframe{{time=0,value={-.1,-.95,0,0}},{time=1,value={-.1,-.5,0,0}}}
    step_hips:=[2]lib.Keyframe{{time=0,value={0,1,0,0}},{time=1,value={0,1,-1,0}}}
    kicked:=[2]lib.Keyframe{{time=0,value={.1,-.6,-.5,0}},{time=1,value={.1,-.6,-.5,0}}}
    swung:=[3]lib.Keyframe{{time=0,value={.1,-.95,-.2,0}},{time=.5,value={.1,-.95,-1.2,0}},{time=1,value={.1,-.95,-.2,0}}}
    planted:=[2]lib.Keyframe{{time=0,value={.1,-.95,-.65,0}},{time=1,value={.1,-.95,-.65,0}}}
    aside:=[2]lib.Keyframe{{time=0,value={-.1,-.95,.2,0}},{time=1,value={-.1,-.95,.2,0}}}
    looks:[3][2]lib.Keyframe
    for &keys,i in looks {keys={{time=0,value={f32(i-1)*.2,.7,0,0}},{time=1,value={f32(i-1)*.2,.7,0,0}}}}
    release:=[1]lib.Marker{{time=.35,id=0}}
    land:=[1]lib.Marker{{time=.8,id=1}}
    // As a library keeps them: each clip's marker of its own, of the same name.
    land_again:=[1]lib.Marker{{time=.8,id=2}}
    hit:=[1]lib.Marker{{time=.5,id=3}}
    descs:=[13]lib.Clip_Desc{
        {name=base.name_hash("idle"),tracks={{target=left,property=.Position,keys=still[:]},{target=right,property=.Position,keys=other[:]}}},
        {name=base.name_hash("walk"),tracks={{target=left,property=.Position,keys=stride_l[:]},{target=right,property=.Position,keys=stride_r[:]}},markers=walk_spans},
        {name=base.name_hash("fall"),tracks={{target=left,property=.Position,keys=tucked[:]},{target=right,property=.Position,keys=other[:]}}},
        {name=base.name_hash("jump"),tracks={{target=left,property=.Position,keys=rise_l[:]},{target=right,property=.Position,keys=rise_r[:]}},markers=land[:]},
        {name=base.name_hash("vault"),tracks={{target=left,property=.Position,keys=over_l[:]},{target=right,property=.Position,keys=over_r[:]}},markers=release[:]},
        {name=base.name_hash("leap"),tracks={{target=left,property=.Position,keys=lift_l[:]},{target=right,property=.Position,keys=lift_r[:]}},markers=land_again[:]},
        {name=base.name_hash("lunge"),tracks={{target=hips,property=.Position,keys=step_hips[:]},{target=left,property=.Position,keys=still[:]},{target=right,property=.Position,keys=other[:]}}},
        {name=base.name_hash("kick"),tracks={{target=left,property=.Position,keys=kicked[:]}},markers=hit[:]},
        {name=base.name_hash("aim_left"),tracks={{target=head,property=.Position,keys=looks[0][:]}}},
        {name=base.name_hash("aim_center"),tracks={{target=head,property=.Position,keys=looks[1][:]}}},
        {name=base.name_hash("aim_right"),tracks={{target=head,property=.Position,keys=looks[2][:]}}},
        {name=base.name_hash("stomp"),tracks={{target=left,property=.Position,keys=swung[:]},{target=right,property=.Position,keys=aside[:]}}},
        {name=base.name_hash("plant"),tracks={{target=left,property=.Position,keys=planted[:]},{target=right,property=.Position,keys=other[:]}}},
    }
    f.content.id,f.content.generation={0x3a7c,3},1
    if !lib.library_init(&f.content.lib,{max_keys=128,max_tracks=32,max_clips=2*len(descs),max_markers=8}) {return false}
    for desc in descs {if _,error:=lib.clip_add(&f.content.lib,desc);error!=.None {return false}}
    if _,error:=lib.library_compress(&f.content.lib);error!=.None {return false}
    host.content_animation_loops(&f.content.lib,len(descs));f.content.clip_count=len(descs)
    f.content.markers=make([]host.Content_Marker,6)
    for name,i in ([6]string{"release","land","land","hit","hold","stumble"}) {f.content.markers[i].name=base.name_hash(name)}
    // The lunge carries the hips, its root.
    f.content.roots=make([]asset.Animation_Root,len(descs));base.text_set(f.content.roots[6].bone[:],"hips");f.content.roots[6].translation=true
    f.assets.registry.by_id=make(map[base.Asset_Id]u32)
    append(&f.assets.registry.files,asset.Registry_File{id=MATCH_TEST_ID,kind=CHARACTER_KIND,state=.Asset});f.assets.registry.by_id[MATCH_TEST_ID]=0
    f.app={assets=&f.assets,allocator=context.allocator}
    Source :: struct {name:string,modes:u32,loop:bool}
    clips:=make([]Match_Source,5 if leap else 4)
    for value,i in ([5]Source{{"idle",1<<GROUND,true},{"walk",1<<GROUND,true},{"fall",1<<AIR,true},{"jump",1<<AIR,false},{"leap",1<<AIR,false}}) {
        if i>=len(clips) {break}
        base.text_set(clips[i].clip[:],value.name);clips[i].modes,clips[i].loop,clips[i].entry=value.modes,value.loop,!value.loop
    }
    if leap {clips[4].speed=3}
    info:=MATCH_INFO_DEFAULT;info.memory=memory
    // The space of the aim: left at -1 and right at 1 of its axis.
    spaces:=make([]Blend_Info,1);spaces[0]={dimension=.One,x={min=-1,max=1}};base.text_set(spaces[0].name[:],"aim");base.text_set(spaces[0].x.name[:],"aim_yaw")
    samples:=make([]Blend_Sample,2);samples[0],samples[1]={position={-1,0},speed=1},{position={1,0},speed=1}
    base.text_set(samples[0].clip[:],"aim_left");base.text_set(samples[1].clip[:],"aim_right")
    // What the aim, the leg and play ask over the search.
    set:=Action_Profile{layers=make([]Stack_Layer,2),actions=make([]Action_Definition,11)}
    set.layers[0]=STACK_LAYER_DEFAULT;base.text_set(set.layers[0].name[:],"Aim");base.text_set(set.layers[0].space[:],"aim");set.layers[0].mode,set.layers[0].fade=.Additive,0
    base.text_set(set.layers[0].reference_clip[:],"aim_center")
    set.layers[1]=STACK_LAYER_DEFAULT;base.text_set(set.layers[1].name[:],"Leg");set.layers[1].over[0].bone=bone_ref("foot_l")
    Action :: struct {name,clip,layer:string,priority:i16,cancel:Action_Cancel_Policy,entry:Action_Entry,exit:f32,marker:string,fade:f32}
    for value,i in ([11]Action{
        {name="Vault",clip="vault",exit=1,fade=.15},{name="Vault to release",clip="vault",exit=1,marker="release",fade=.15},
        {name="Vault kept",clip="vault",entry=.Keep_Time,exit=1,fade=.15},{name="Vault phased",clip="vault",entry=.Match_Phase,exit=.5,fade=.15},{name="Vault half",clip="vault",exit=.5,fade=.15},
        {name="Cut",clip="vault",exit=1},{name="Guard",clip="vault",priority=2,cancel=.Deny,exit=1,fade=.45},
        {name="Lunge",clip="lunge",exit=1},{name="Kick",clip="kick",layer="Leg",exit=1},
        {name="Stomp",clip="stomp",exit=1,fade=.2},{name="Plant",clip="plant",exit=1,fade=.2},
    }) {
        action:=&set.actions[i];action^=ACTION_DEFINITION_DEFAULT
        base.text_set(action.name[:],value.name);base.text_set(action.clip[:],value.clip);base.text_set(action.layer[:],value.layer);base.text_set(action.exit_marker[:],value.marker)
        action.priority,action.cancel,action.entry,action.exit,action.fade_in,action.fade_out=value.priority,value.cancel,value.entry,value.exit,value.fade,value.fade
    }
    set.actions[7].root_motion,set.actions[7].body_move=.In_Place,.Override
    set.actions[8].fade_in,set.actions[8].fade_out=0,0
    // One .character: the locomotion, the space and the actions.
    owned_spans:=make([]Match_Span,len(spans));copy(owned_spans,spans)
    character:=Character_Set{info={animation=f.content.id},match={info=info,clips=clips,spans=owned_spans},actions=set,spaces=spaces,space_samples=samples,motion={warp=POSE_WARP_PROFILE_DEFAULT}}
    if !testing.expect(t,character_check(character)) {return false}
    points:=[2]mm.Vec2{blend_position(spaces[0],samples[0].position),blend_position(spaces[0],samples[1].position)}
    space,prepared:=lib.blend_space_prepare(points[:],.One)
    ready:=make([]Space_Ready,1);names:=make([]u64,2);names[0],names[1]=base.name_hash("aim_left"),base.name_hash("aim_right")
    ready[0]={space=space,names=names,axis_names={0=base.name_hash("aim_yaw")}}
    f.graphs.allocator=context.allocator
    append(&f.graphs.contents,Character_Content{id=MATCH_TEST_ID,checked=assets_stamp(f.app.assets),revision=1,valid=true,set=character,spaces=ready})
    if !testing.expect(t,prepared) {return false}
    f.state=state_get(&f.playback,f.rig)
    return f.state!=nil && skeleton_bind(&f.playback,f.state,&f.definition,&f.content,&f.transforms)
}
@(private="file")
match_fixture_free :: proc(f:^Match_Fixture) {
    playback_free(&f.playback);lib.library_destroy(&f.content.lib);delete(f.content.markers);delete(f.content.roots)
    if len(f.graphs.contents)>0 {
        set:=&f.graphs.contents[0].set
        delete(set.match.clips);delete(set.match.samples);delete(set.match.spans);delete(set.actions.layers);delete(set.actions.actions);delete(set.spaces);delete(set.space_samples)
    }
    character_assets_free(&f.graphs);actions_runtime_free(&f.actions);core.table_destroy(&f.played);core.table_destroy(&f.remotes)
    delete(f.assets.registry.by_id);delete(f.assets.registry.files)
    delete(f.events.items);delete(f.requests.plays.items);delete(f.requests.values.items)
    test_world_destroy(&f.w)
}
// A tick of the rig with the body in mode: standing, or going at velocity, asked for desired,
// against a wall of that normal, landing in time_to_land seconds. It serves what play, stop and set
// asked since the last one, as animation_tick does.
@(private="file")
match_step :: proc(f:^Match_Fixture,dt:f32,mode:u16,velocity:=mm.Vec3{},desired:=mm.Vec3{},wall:=mm.Vec3{},time_to_land:f32=0,content:^host.Content_Animation=nil) -> bool {
    content:=content if content!=nil else &f.content
    clear(&f.events.items)
    f.playback.frame+=1
    goals:=[1]Match_Goal{{rig=f.rig,mode=mode,velocity=velocity,desired=desired,facing={0,0,-1},wall=wall,acceleration=20,braking=20,time_to_land=time_to_land}}
    copy(playing_pose(f.state,.Local),playing_topology(f.state).rest[:])
    core.edit(&f.animations,f.rig)^=f.animation
    if !actions_prepare(&f.actions,&f.requests,&f.graphs,core.read(&f.animations),&f.playback,&f.events,&f.app,core.read(&f.remotes),&f.played,{dt=dt,playing=true},&f.problems) {return false}
    for value in core.take(&f.requests.values) {stack_parameter_set(f.state,value.name,value.value)}
    f.state.root,f.state.body_motion={},{}
    stack_asks(&f.actions,f.state,f.animation,content)
    output,programmed,ok:=program_resolve(f.state,f.animation,&f.app,&f.graphs,dt,&f.events,&f.playback,content,&f.problems,goals[:])
    if !ok || !programmed || !curves_prepare(f.state,content) || !program_players(f.state,output,content,f.animation,&f.events,&f.playback,dt,-1,nil) {return false}
    if f.state.program.has_root {f.state.root=f.state.program.root}
    actions_sample(&f.actions,f.state,f.animation,dt,&f.problems,content,&f.playback,&f.events,1)
    layers_advance(&f.playback,f.state,content,f.animation,&f.events,dt,&f.problems,&f.graphs,&f.app,&f.actions)
    actions_layer_finish(&f.actions,f.state)
    stack_parameters_check(f.state,&f.problems)
    if !stack_inertia_prepare(f.state) {return false}
    faults:=pose_compose(&f.playback,f.state,content,f.animation,true,dt,core.read(&f.transforms),0)
    if faults.program {return false}
    pose_faults_report(&f.problems,f.rig,faults,&f.actions)
    f.state.seen=f.playback.frame
    stack_root(f.state,content,f.animation);stack_root_inertia(f.state,f.playback.frame,dt)
    actions_finish(&f.actions,&f.playback,dt)
    return true
}
// The last search of the matching of the rig, as Playback noted it for inspection.
@(private="file")
match_test_searched :: proc(f:^Match_Fixture) -> Match_Searched {
    searched,_:=match_searched(core.ref(&f.playback),f.rig)
    return searched
}
// The events of the actions of the rig in the last tick, without the markers of its locomotion.
@(private="file")
match_action_events :: proc(f:^Match_Fixture) -> (count:int) {
    for event in f.events.items {if event.entity==f.rig && event.action!=0 {count+=1}}
    return
}
// The events of kind of an action the rig gave in the last tick: of the name given, or of any.
@(private="file")
match_test_events :: proc(f:^Match_Fixture,kind:Animation_Event_Kind,action:string,name:="") -> int {
    count:=0
    for event in f.events.items {if event.entity==f.rig && event.kind==kind && event.action==base.name_hash(action) && (name=="" || event.name==base.name_hash(name)) {count+=1}}
    return count
}

@(test)
a_whole_body_action_enters_at_its_start_time_or_phase_and_ends_at_its_exit_or_marker :: proc(t:^testing.T) {
    Case :: struct {action:string,entry:Action_Entry,release:f32}
    cases:=[?]Case{{"Vault to release",.Start,.35},{"Vault kept",.Keep_Time,2},{"Vault phased",.Match_Phase,1},{"Vault half",.Start,1}}
    dt:=f32(.05)
    for c in cases {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {continue}
        for _ in 0..<5 {testing.expect(t,match_step(&f,dt,GROUND))}
        before,_:=animation_match(core.ref(&f.playback),f.rig);duration:=f.state.duration
        long:="an action whose name is longer than the sixty four bytes that a request can hold"
        play(&f.requests,f.rig,"");play(&f.requests,core.NONE,"Vault");play(&f.requests,f.rig,long);stop(&f.requests,f.rig,"")
        testing.expect_value(t,f.requests.plays.refused,4)
        f.requests.plays.refused=0
        play(&f.requests,f.rig,c.action)
        if !testing.expect(t,match_step(&f,dt,GROUND)) {continue}
        playing,_:=animation_match(core.ref(&f.playback),f.rig)
        time,_,on:=action_playing(core.ref(&f.actions),f.rig,c.action)
        // The base clip has moved on in the tick: an entry takes it where it is now.
        at:=before.time+dt
        start:=f32(0) if c.entry==.Start else at if c.entry==.Keep_Time else at/duration*2
        testing.expectf(t,on && playing.forced && abs(time-(start+dt))<1e-4,"%v enters at %.3f s, not %.3f s",c.entry,start+dt,time)
        testing.expect(t,match_test_events(&f,.Started,c.action)==1 && match_test_events(&f,.Ended,c.action)==0 && match_test_events(&f,.Interrupted,c.action)==0,"an action over the whole body starts once")
        held:=time;ended:=0
        for _ in 0..<60 {
            testing.expect(t,match_step(&f,dt,GROUND))
            ended+=match_test_events(&f,.Ended,c.action)
            testing.expect(t,match_test_events(&f,.Started,c.action)==0 && match_test_events(&f,.Interrupted,c.action)==0)
            value,_:=animation_match(core.ref(&f.playback),f.rig)
            if !value.forced {break}
            if slot:=f.actions.states[0].slots[0];slot.active {held=slot.time}
        }
        testing.expectf(t,held>=c.release-1e-4 && held<c.release+dt+1e-4 && ended==1,"'%s' hands the rig back at %.3f s, not %.3f s, and ends once, not %d times",c.action,c.release,held,ended)
        testing.expect_value(t,f.problems.count,0)
    }
}

@(test)
a_play_gives_way_by_priority_and_cancel_policy_and_tells_each_change_once :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    dt:=f32(.1)
    testing.expect(t,match_step(&f,dt,GROUND) && match_step(&f,dt,GROUND))
    play(&f.requests,f.rig,"Vault")
    testing.expect(t,match_step(&f,dt,GROUND) && match_test_events(&f,.Started,"Vault")==1)
    // One of the same priority takes the slot of one that allows it: each is told once.
    play(&f.requests,f.rig,"Vault half")
    testing.expect(t,match_step(&f,dt,GROUND))
    testing.expect(t,match_test_events(&f,.Interrupted,"Vault")==1 && match_test_events(&f,.Started,"Vault half")==1 && match_action_events(&f)==2,"an action of the same priority replaces the one playing at once")
    play(&f.requests,f.rig,"Guard")
    testing.expect(t,match_step(&f,dt,GROUND) && match_test_events(&f,.Interrupted,"Vault half")==1 && match_test_events(&f,.Started,"Guard")==1)
    // A lower priority is refused, and so is a stop of one whose policy denies it.
    play(&f.requests,f.rig,"Vault");stop(&f.requests,f.rig,"Guard")
    testing.expect(t,match_step(&f,dt,GROUND))
    playing,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expect(t,playing.forced && core.problem_find(&f.problems,f.rig,"animation.action_busy")!=nil && core.problem_find(&f.problems,f.rig,"animation.action_cancel")!=nil && match_action_events(&f)==0,"a play of lower priority and a stop the policy denies are refused")
    time,_,on:=action_playing(core.ref(&f.actions),f.rig,"Guard")
    testing.expect(t,on && time>0)
    // The names a set does not have are problems of the entity, not events.
    play(&f.requests,f.rig,"Missing");stop(&f.requests,f.rig,"Kick")
    testing.expect(t,match_step(&f,dt,GROUND))
    testing.expect(t,core.problem_find(&f.problems,f.rig,"animation.action_missing")!=nil && core.problem_find(&f.problems,f.rig,"animation.action_idle")!=nil && match_action_events(&f)==0)
    // In another slot an action plays whatever the whole body does.
    play(&f.requests,f.rig,"Kick")
    testing.expect(t,match_step(&f,dt,GROUND) && match_test_events(&f,.Started,"Kick")==1 && match_test_events(&f,.Interrupted,"Guard")==0)
    kicking:=0
    for event in f.events.items {if event.action==base.name_hash("Kick") {kicking+=1}}
    testing.expect_value(t,kicking,1)
}

@(test)
the_travel_of_a_jump_turns_with_its_blend_and_never_through_zero :: proc(t:^testing.T) {
    forward,back,side:=mm.Vec3{0,0,1},mm.Vec3{0,0,-1},mm.Vec3{1,0,0}
    testing.expect(t,linalg.length(travel_turn(forward,back,1)-forward)<1e-5,"a jump starts in the direction it leaves")
    testing.expect(t,linalg.length(travel_turn(forward,back,0)-back)<1e-5,"and ends in the one of its clip")
    for remaining in ([?]f32{.9,.5,.1}) {testing.expectf(t,abs(linalg.length(travel_turn(forward,back,remaining))-1)<1e-5,"forward to back keeps a direction at %v",remaining)}
    testing.expect(t,linalg.length(travel_turn(forward,side,.5)-linalg.normalize(forward+side))<1e-5,"half way to the side is the diagonal")
    testing.expect(t,travel_turn({},side,.5)==side,"from standing it is the new direction")
    previous:=f32(1)
    for step in 1..=20 {
        share:=lib.inertial_remaining(f32(step)*.01,.2)
        testing.expectf(t,share<=previous && share>=0,"the share left only decreases: %v after %v",share,previous)
        previous=share
    }
    testing.expect(t,previous<1e-4 && lib.inertial_remaining(.2,.2)==0 && lib.inertial_remaining(0,.2)==1)
}

@(test)
a_whole_body_action_goes_on_when_the_body_changes_mode_and_stop_ends_it :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    // A clip that walks tells the direction it travels in, which the warping corrects from.
    for _ in 0..<10 {testing.expect(t,match_step(&f,.1,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5}))}
    walking,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expectf(t,walking.speed>0 && linalg.length(walking.travel-mm.Vec3{0,0,-1})<1e-3,"the walk travels along -Z: %v",walking.travel)
    // On the second tick: the blend starts from the pose of the first, with no history before it.
    testing.expect(t,match_step(&f,.1,GROUND))
    play(&f.requests,f.rig,"Vault")
    testing.expect(t,match_step(&f,.1,GROUND))
    forced,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expect(t,forced.forced,"an action over the whole body covers the search")
    // The body leaves the ground: the action is not of a mode, and goes on.
    testing.expect(t,match_step(&f,.1,AIR))
    value,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expect(t,value.forced && match_action_events(&f)==0,"the mode of the body does not end an action")
    stop(&f.requests,f.rig,"Vault")
    testing.expect(t,match_step(&f,.1,AIR) && match_test_events(&f,.Interrupted,"Vault")==1 && match_test_events(&f,.Ended,"Vault")==0)
    for _ in 0..<5 {testing.expect(t,match_step(&f,.1,AIR));value,_=animation_match(core.ref(&f.playback),f.rig);if !value.forced {break}}
    testing.expectf(t,!value.forced && value.mode==AIR,"stop fades the action out over the search of the mode the body is in, not %v",value)
    // One that plays to its end tells it once, and the search goes on.
    testing.expect(t,match_step(&f,.1,GROUND))
    play(&f.requests,f.rig,"Vault")
    ended,started:=0,0
    for _ in 0..<14 {
        testing.expect(t,match_step(&f,.25,GROUND))
        started+=match_test_events(&f,.Started,"Vault");ended+=match_test_events(&f,.Ended,"Vault")
    }
    value,_=animation_match(core.ref(&f.playback),f.rig)
    testing.expect(t,started==1 && ended==1 && !value.forced)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
a_whole_body_action_blends_in_from_the_pose_and_stable_ticks_do_not_allocate :: proc(t:^testing.T) {
    dt:=f32(1.0/60)
    jumps:[2]f32
    for action,i in ([2]string{"Cut","Vault"}) {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {continue}
        for _ in 0..<10 {testing.expect(t,match_step(&f,dt,GROUND))}
        foot:=bone_resolve(f.state,bone_ref("foot_l"));last:=playing_pose(f.state,.Local)[foot].position
        play(&f.requests,f.rig,action)
        testing.expect(t,match_step(&f,dt,GROUND))
        jumps[i]=linalg.length(playing_pose(f.state,.Local)[foot].position-last)
        if i==0 {continue}
        testing.expect(t,f.state.stack.layers[0].weight==1 && f.state.stack.inertia.state.active && f.state.stack.inertia.state.duration==.15,"it shows at its weight at once and blends over its fade_in")
        saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;f.app.allocator=context.allocator
        stable:=true
        for tick in 0..<120 {
            if tick==30 {play(&f.requests,f.rig,"Vault half")}
            stable &&=match_step(&f,dt,GROUND)
        }
        context=saved;f.app.allocator,f.graphs.allocator,f.actions.allocator=saved.allocator,saved.allocator,saved.allocator
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        testing.expect(t,stable && !value.forced && f.problems.count==0,"actions, their blends and the matching after them do not allocate")
    }
    testing.expectf(t,jumps[0]>.3 && jumps[1]<jumps[0]*.25,"an action without fade cuts (%.3f m) and one with fade goes on from the last pose (%.3f m)",jumps[0],jumps[1])
}

// The clips the pose of a rig blends in its tick: those of its locomotion and those of each slot
// of its stack that shows.
@(private="file")
match_test_clips :: proc(state:^Playing) -> (count:int) {
    count=int(state.program.output.count)
    for &layer in state.stack.layers[:state.stack.slots] {
        if layer.weight<=0 {continue}
        players:[LAYER_PLAYERS]lib.Player
        count+=layer_players(&layer,&players)
    }
    return
}

// Stomp, and plant after it, start over the search or interrupt the action playing: each shows its
// pose at once over an offset from the pose shown, which decays by its fade_in, and one without
// fade_in cuts. The twin plays them all cut, so it shows the pose they ask for: the target of the
// blends, which evaluate the clips of that one source. Plant interrupts stomp once it plays where
// the foot is 5 cm from where plant holds it and swings away at 2 m/s. With kick, the layer over
// the left foot starts in the same tick as stomp and asks .1 s: the foot blends over that time
// and the other foot over the .2 s of stomp. A rig not posed for ticks, or bound again, before
// plant shows plant at once: what it showed then is not blended from. With root, lunge (its root
// moving at 1 m/s) is interrupted by plant, whose root stays: the root motion that moves the body
// blends from that velocity.
@(test)
an_action_shows_its_pose_at_once_and_blends_from_the_pose_shown :: proc(t:^testing.T) {
    Case :: struct {name,next:string,at,unposed:int,cut,kick,rebound,root:bool}
    cases:=[?]Case{
        {name="starts"},{name="interrupts while it blends in",next="Plant",at=5},{name="interrupts once it plays",next="Plant",at=15},{name="cuts",next="Plant",at=5,cut=true},
        {name="starts with a layer that asks less time",kick=true},{name="after ticks it was not posed",next="Plant",at=5,unposed=3},
        {name="after it is bound again",next="Plant",at=5,rebound=true},{name="moves the body by root motion",next="Plant",at=15,root=true},
    }
    dt,fade:=f32(1.0/60),f32(.2)
    for c in cases {
        f,twin:Match_Fixture;defer {match_fixture_free(&f);match_fixture_free(&twin)}
        if !testing.expect(t,match_fixture(t,&f) && match_fixture(t,&twin)) {continue}
        for &action in twin.graphs.contents[0].set.actions.actions[9:] {action.fade_in,action.fade_out=0,0}
        if c.cut {f.graphs.contents[0].set.actions.actions[10].fade_in=0}
        if c.kick {f.graphs.contents[0].set.actions.actions[8].fade_in=.1}
        if c.root {
            f.graphs.contents[0].set.actions.actions[7].fade_in=fade
            for g in ([2]^Match_Fixture{&f,&twin}) {
                plant:=&g.graphs.contents[0].set.actions.actions[10];plant.root_motion,plant.body_move=.In_Place,.Override
                base.text_set(g.content.roots[12].bone[:],"hips");g.content.roots[12].translation=true
            }
        }
        first:="Lunge" if c.root else "Stomp"
        for _ in 0..<10 {testing.expect(t,match_step(&f,dt,GROUND) && match_step(&twin,dt,GROUND))}
        foot,other:=bone_resolve(f.state,bone_ref("foot_l")),bone_resolve(f.state,bone_ref("foot_r"))
        shown,offsets:[dynamic][5]mm.Vec3;defer {delete(shown);delete(offsets)}
        moved:[dynamic]f32;defer delete(moved)
        slide:f32;clips:=0
        for tick in 0..<40 {
            if tick==0 {play(&f.requests,f.rig,first);play(&twin.requests,twin.rig,first)}
            if tick==0 && c.kick {play(&f.requests,f.rig,"Kick");play(&twin.requests,twin.rig,"Kick")}
            if c.next!="" && tick==c.at {
                for g in ([2]^Match_Fixture{&f,&twin}) {
                    g.playback.frame+=u64(c.unposed)
                    if c.rebound {testing.expect(t,skeleton_bind(&g.playback,g.state,&g.definition,&g.content,&g.transforms))}
                    play(&g.requests,g.rig,c.next)
                }
            }
            if !testing.expect(t,match_step(&f,dt,GROUND) && match_step(&twin,dt,GROUND)) {break}
            append(&moved,linalg.length(f.state.body_motion.translation-twin.state.body_motion.translation))
            testing.expectf(t,match_test_clips(f.state)==match_test_clips(twin.state) && f.state.stack.layers[0].weight==twin.state.stack.layers[0].weight,"%s: tick %d blends the clips of one source at its weight",c.name,tick)
            pose,offset:[5]mm.Vec3
            for b in 0..<min(len(playing_pose(f.state,.Local)),5) {pose[b]=playing_pose(f.state,.Local)[b].position;offset[b]=pose[b]-playing_pose(twin.state,.Local)[b].position}
            append(&shown,pose);append(&offsets,offset)
            if c.next!="" && tick>=c.at && tick<c.at+18 {slide+=linalg.length(pose[foot]-shown[tick-1][foot])}
            if c.next!="" && tick==c.at {clips=match_test_clips(f.state)}
        }
        if len(offsets)<40 {continue}
        largest :: proc(values:[5]mm.Vec3) -> (length:f32) {for value in values {length=max(length,linalg.length(value))};return}
        // The longest of the offsets of the bones at each tick since it blends, until it ends.
        from:=c.at if c.next!="" else 0
        if c.cut || c.unposed>0 || c.rebound {
            testing.expectf(t,largest(offsets[from])<1e-5,"%s: plant shows its pose at once, %v",c.name,offsets[from])
            continue
        }
        if c.root {
            testing.expectf(t,moved[from]>.5*dt && moved[from]<dt,"%s: the body goes on from 1 m/s, %v m in the tick plant starts",c.name,moved[from])
            for tick in from+1..<40 {testing.expectf(t,moved[tick]<=moved[tick-1]+1e-6 && (f32(tick-from+1)*dt<fade+1e-4 || moved[tick]<1e-6),"%s: the difference of the root motion decays to nothing by its fade_in: %v at tick %d",c.name,moved[tick],tick)}
            continue
        }
        if c.kick {
            at:=int(.1/dt+.5)
            testing.expectf(t,linalg.length(offsets[at][foot])<1e-5 && linalg.length(offsets[at][other])>1e-3,"%s: the foot of the layer blends over its .1 s, the other over .2 s: %v",c.name,offsets[at])
        }
        testing.expectf(t,largest(offsets[from])>.01,"%s: it blends from the pose shown, %v",c.name,offsets[from])
        for tick in from+1..<40 {
            ended:=f32(tick-from+1)*dt>=fade+1e-4
            testing.expectf(t,largest(offsets[tick])<=largest(offsets[tick-1])+1e-5 && (!ended || largest(offsets[tick])<1e-5),"%s: the offset decays to nothing by its fade_in: %v at tick %d",c.name,largest(offsets[tick]),tick)
        }
        if c.next=="" {continue}
        // While stomp blends in, its foot heads where plant holds it: the pose goes on with the
        // velocity it had. Once stomp plays, the foot swings away and plants without that velocity.
        jump:=largest({0=shown[from][foot]-2*shown[from-1][foot]+shown[from-2][foot]})
        testing.expectf(t,c.at!=5 || jump<.002,"%s: the pose goes on with its velocity, a change of %.4f m in a tick",c.name,jump)
        if c.at==15 {
            log.infof("%s: %d clips while it blends, the planted foot slides %.3f m",c.name,clips,slide)
            testing.expectf(t,slide<.07,"%s: the planted foot moves no more than the 5 cm to where plant holds it, not %.3f m",c.name,slide)
        }
    }
}

// The stack over the search: the aim offset of a space added over the matched pose, an action in
// a layer over a branch over both, and a whole-body action under them; each event arrives once.
@(test)
an_aim_offset_adds_over_the_matched_pose_and_an_action_plays_over_both :: proc(t:^testing.T) {
    f,plain:Match_Fixture;defer {match_fixture_free(&f);match_fixture_free(&plain)}
    if !testing.expect(t,match_fixture(t,&f) && match_fixture(t,&plain)) {return}
    dt:=f32(.1);walking:=mm.Vec3{0,0,-1.5}
    head,left,right:=bone_resolve(f.state,bone_ref("head")),bone_resolve(f.state,bone_ref("foot_l")),bone_resolve(f.state,bone_ref("foot_r"))
    step :: proc(f,plain:^Match_Fixture,dt:f32,velocity:mm.Vec3) -> bool {return match_step(f,dt,GROUND,velocity,velocity) && match_step(plain,dt,GROUND,velocity,velocity)}
    near :: proc(a,b:mm.Vec3) -> bool {return linalg.length(a-b)<1e-4}
    for _ in 0..<6 {testing.expect(t,step(&f,&plain,dt,walking))}
    testing.expect(t,near(playing_pose(f.state,.Local)[head].position,playing_pose(plain.state,.Local)[head].position),"an axis nobody set leaves the pose as the search gives it")
    // The aim turns the head over the walk the search plays; the feet stay matched.
    set(&f.requests,f.rig,"aim_yaw",1)
    testing.expect(t,step(&f,&plain,dt,walking))
    matched,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expect(t,!matched.forced && matched.clip==base.name_hash("walk"))
    testing.expectf(t,near(playing_pose(f.state,.Local)[head].position,playing_pose(plain.state,.Local)[head].position+{.2,0,0}) && near(playing_pose(f.state,.Local)[left].position,playing_pose(plain.state,.Local)[left].position) && near(playing_pose(f.state,.Local)[right].position,playing_pose(plain.state,.Local)[right].position),"the aim adds .2 m to the head of the matched pose: %v over %v",playing_pose(f.state,.Local)[head].position,playing_pose(plain.state,.Local)[head].position)
    // It stays where it was set, and halfway there is half the offset; past its range it is the end of it.
    set(&f.requests,f.rig,"aim_yaw",.5)
    testing.expect(t,step(&f,&plain,dt,walking) && near(playing_pose(f.state,.Local)[head].position,playing_pose(plain.state,.Local)[head].position+{.1,0,0}))
    set(&f.requests,f.rig,"aim_yaw",-7)
    testing.expect(t,step(&f,&plain,dt,walking) && step(&f,&plain,dt,walking) && near(playing_pose(f.state,.Local)[head].position,playing_pose(plain.state,.Local)[head].position-{.2,0,0}))
    // The weight of the layer is the parameter of its name.
    set(&f.requests,f.rig,"Aim",.5)
    testing.expect(t,step(&f,&plain,dt,walking) && near(playing_pose(f.state,.Local)[head].position,playing_pose(plain.state,.Local)[head].position-{.1,0,0}))
    set(&f.requests,f.rig,"Aim",1);set(&f.requests,f.rig,"aim_yaw",1)
    // An action in the layer over the left foot plays over both: the foot is its clip's, the head
    // keeps the aim and the other foot the search.
    play(&f.requests,f.rig,"Kick")
    counts:[Animation_Event_Kind]int
    for tick in 0..<14 {
        testing.expect(t,step(&f,&plain,dt,walking))
        for event in f.events.items {if event.action==base.name_hash("Kick") {counts[event.kind]+=1}}
        if tick==2 {
            testing.expectf(t,near(playing_pose(f.state,.Local)[left].position,{.1,-.6,-.5}) && near(playing_pose(f.state,.Local)[right].position,playing_pose(plain.state,.Local)[right].position) && near(playing_pose(f.state,.Local)[head].position,playing_pose(plain.state,.Local)[head].position+{.2,0,0}),"the kick takes the left foot over the walk and under nothing else: %v",playing_pose(f.state,.Local)[left].position)
        }
    }
    testing.expectf(t,counts==([Animation_Event_Kind]int{.Marker=1,.Started=1,.Ended=1,.Interrupted=0,.Section=0,.Span_Begin=0,.Span_End=0}),"each event of the action arrives once: %v",counts)
    testing.expect(t,near(playing_pose(f.state,.Local)[left].position,playing_pose(plain.state,.Local)[left].position),"its layer gives the foot back to the search when it ends")
    // A whole-body action takes the search away under the layers: the aim still adds over it.
    play(&f.requests,f.rig,"Vault");play(&plain.requests,plain.rig,"Vault")
    for _ in 0..<4 {testing.expect(t,step(&f,&plain,dt,walking))}
    vaulting,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expect(t,vaulting.forced && near(playing_pose(f.state,.Local)[head].position,playing_pose(plain.state,.Local)[head].position+{.2,0,0}) && near(playing_pose(f.state,.Local)[left].position,playing_pose(plain.state,.Local)[left].position))
    testing.expect_value(t,f.problems.count,0)
    // A name that is no layer and no axis is a problem of the entity, and is dropped.
    set(&f.requests,f.rig,"aim_pitch",1)
    testing.expect(t,match_step(&f,dt,GROUND))
    testing.expect(t,core.problem_find(&f.problems,f.rig,"animation.parameter")!=nil && f.problems.count==1)
    testing.expect(t,match_step(&f,dt,GROUND) && f.problems.count==1 && core.problem_find(&f.problems,f.rig,"animation.parameter").count==1)
}

// The root motion of a clip that takes the whole body from the search is the root delta of the
// rig, and moves its body when its action says so.
@(test)
the_root_motion_of_a_whole_body_action_moves_the_body :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    dt:=f32(.1)
    for _ in 0..<3 {testing.expect(t,match_step(&f,dt,GROUND))}
    _,moving:=animation_body_motion(core.ref(&f.playback),f.rig)
    testing.expect(t,!moving,"the search moves no body")
    play(&f.requests,f.rig,"Lunge")
    travelled:mm.Vec3
    for tick in 0..<12 {
        testing.expect(t,match_step(&f,dt,GROUND))
        body,moves:=animation_body_motion(core.ref(&f.playback),f.rig)
        delta,rooted:=animation_root_delta(core.ref(&f.playback),f.rig)
        playing,_:=animation_match(core.ref(&f.playback),f.rig)
        if !playing.forced {testing.expect(t,!moves,"once it ends the body is left to its locomotion");continue}
        testing.expectf(t,moves && rooted && body.move==.Override && !body.vertical && linalg.length(body.translation-delta.translation)<1e-5,"tick %d: the body takes the root delta of the lunge: %v of %v",tick,body,delta)
        travelled+=body.translation
    }
    testing.expectf(t,linalg.length(travelled-mm.Vec3{0,0,-1})<1e-3,"the lunge carries the body its metre: %v",travelled)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
a_new_mode_of_the_match_goal_enters_by_its_entry_clip :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    dt:=f32(1.0/30)
    // The first search, with no clip playing, notes the best row of each clip of the ground: the
    // one it jumped to first, the costs in order and each the sum of its kinds of feature.
    testing.expect(t,match_step(&f,dt,GROUND))
    first,_:=animation_match(core.ref(&f.playback),f.rig)
    searched:=match_test_searched(&f)
    for _ in 1..<10 {testing.expect(t,match_step(&f,dt,GROUND))}
    value,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expect(t,value.mode==GROUND && (value.clip==base.name_hash("idle") || value.clip==base.name_hash("walk")))
    db:=animation_match_database(core.ref(&f.graphs),&f.content,f.state)
    if testing.expect(t,db!=nil) {
        noted:=match_searched_candidates(db,searched)
        candidates:=noted.items[:noted.count]
        reasons:=match_test_reasons(db,noted)
        testing.expectf(t,searched.search==1 && searched.request.modes==1<<GROUND && !searched.request.entry && len(candidates)==4 && reasons[2]==.Mode && reasons[3]==.Mode,"the first search weighs idle and walk and leaves out the air, not %v",searched)
        for candidate,i in candidates {
            sum:f32;for part in candidate.costs {sum+=part}
            testing.expectf(t,abs(sum-candidate.cost)<=1e-3*max(1,candidate.cost),"the kinds of feature sum %.4f, not its cost %.4f",sum,candidate.cost)
            if i>0 && i<2 {testing.expect(t,candidates[i-1].cost<=candidate.cost,"candidates go from the least cost")}
        }
        if len(candidates)>0 {
            range:=lib.match_range_of(db,int(candidates[0].row))
            testing.expectf(t,range>=0 && lib.clip_data(&f.content.lib,db.ranges[range].clips[0]).name==first.clip,"the first candidate is the clip it jumped to")
        }
        // Noting candidates bounds each clip by its own best row and gives the same row.
        request:=lib.Match_Request{query=lib.match_features(db,0),trajectory=lib.match_row_trajectory(db,int(db.ranges[1].first)),modes=~u32(0),min_rate=.5,max_rate=1}
        noted=lib.Match_Candidates{}
        best,cost,_:=lib.match_search(db,request)
        same,same_cost,_:=lib.match_search(db,request,candidates=&noted)
        testing.expect(t,best==same && cost==same_cost && noted.count>=2 && int(noted.items[0].row)==best)
    }
    testing.expect(t,match_step(&f,dt,AIR))
    value,_=animation_match(core.ref(&f.playback),f.rig)
    testing.expectf(t,value.mode==AIR && value.clip==base.name_hash("jump") && value.time<=lib.MATCH_ENTRY_SPAN+dt+1e-4 && !value.forced,"entering the air starts its entry clip near its start, not %v",value)
    searched=match_test_searched(&f)
    reasons:=match_test_reasons(db,match_searched_candidates(db,searched))
    testing.expectf(t,searched.request.entry && searched.request.modes==1<<AIR && reasons=={.Mode,.Mode,.Entry,.None,max(lib.Match_Reject)} && searched.search==value.searches,"entering the air notes its entry search, not %v",searched)
    testing.expectf(t,value.rate==1,"an entry clip plays at its own rate whatever the body moves, not %.2f",value.rate)
    for _ in 0..<120 {testing.expect(t,match_step(&f,dt,AIR))}
    value,_=animation_match(core.ref(&f.playback),f.rig)
    testing.expectf(t,value.mode==AIR && value.clip==base.name_hash("fall"),"the entry clip hands the air over to its loop when it ends, not %v",value)
}

// Why the search noted each clip of the fixture left out, by range; max for one it did not note.
@(private="file")
match_test_reasons :: proc(db:^lib.Match_Database,noted:lib.Match_Candidates) -> (reasons:[5]lib.Match_Reject) {
    for &reason in reasons {reason=max(lib.Match_Reject)}
    for item,i in noted.items {
        if i>=int(noted.count) {break}
        if range:=lib.match_range_of(db,int(item.row));range>=0 && range<len(reasons) {reasons[range]=item.reason}
    }
    return
}

// Ticks of a body in the air from time_to_land down to its last tick before it lands, the
// time to land told on each; at tick 10, the ground found later by later.
@(private="file")
match_test_fall :: proc(t:^testing.T,f:^Match_Fixture,dt,time_to_land:f32,later:f32=0,velocity:=mm.Vec3{},turn:=mm.Vec3{}) -> (clips:[dynamic]u64) {
    clips.allocator=context.temp_allocator
    left:=time_to_land
    for tick:=0;left>dt*.5;tick+=1 {
        if tick==10 {left+=later}
        going:=velocity if tick<10 else turn
        testing.expect(t,match_step(f,dt,AIR,velocity=going,desired=going,time_to_land=left))
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        if len(clips)==0 || clips[len(clips)-1]!=value.clip {append(&clips,value.clip)}
        left-=dt
    }
    return
}

// Physics tells the rig in the air when it lands: the jump plays at the rate that puts its landing
// marker there, follows a later landing, plays on after it lands until it ends, and off a ledge it
// plays the part of the jump that lands in time.
@(test)
a_body_in_the_air_lands_on_the_landing_marker_of_its_clip_when_physics_says :: proc(t:^testing.T) {
    dt:=f32(1.0/60)
    {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {return}
        for _ in 0..<10 {testing.expect(t,match_step(&f,dt,GROUND))}
        testing.expect(t,match_step(&f,dt,AIR,time_to_land=.6))
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        start:=value.time-dt*value.rate
        testing.expectf(t,value.clip==base.name_hash("jump") && start<=lib.MATCH_ENTRY_SPAN+1e-4 && abs(value.rate*.6-(.8-start))<1e-3,"the jump enters at %.3f s at the rate that lands its marker in .6 s, not %.3f",start,value.rate)
        clips:=match_test_fall(t,&f,dt,.6-dt,later=.2)
        value,_=animation_match(core.ref(&f.playback),f.rig)
        testing.expectf(t,len(clips)==1 && clips[0]==base.name_hash("jump") && abs(value.time-.8)<.01,"the jump reaches its marker when the body lands later, at %.3f s",value.time)
        testing.expect(t,match_step(&f,dt,GROUND))
        value,_=animation_match(core.ref(&f.playback),f.rig)
        testing.expectf(t,value.clip==base.name_hash("jump") && value.mode==GROUND && !value.forced && value.rate==1,"landed, the jump plays on on the ground: %v",value)
        ticks:=1
        for ;ticks<30 && value.clip==base.name_hash("jump");ticks+=1 {
            testing.expect(t,match_step(&f,dt,GROUND))
            value,_=animation_match(core.ref(&f.playback),f.rig)
        }
        testing.expectf(t,value.clip!=base.name_hash("jump") && f32(ticks)*dt<=.2+3*dt,"the ground takes over by the end of the jump, not after %d ticks",ticks)
    }
    {
        // Off a ledge .25 s above the ground no start lands in time: a row of the jump that does.
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {return}
        for _ in 0..<10 {testing.expect(t,match_step(&f,dt,GROUND))}
        testing.expect(t,match_step(&f,dt,AIR,time_to_land=.25))
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        db:=animation_match_database(core.ref(&f.graphs),&f.content,f.state)
        searched:=match_test_searched(&f)
        if !testing.expect(t,db!=nil) {return}
        reasons:=match_test_reasons(db,match_searched_candidates(db,searched))
        testing.expectf(t,value.clip==base.name_hash("jump") && value.time>=.3 && searched.request.event==.25 && reasons[2]==.Event && reasons[3]==.None,"off a ledge the jump plays from %.3f s; the fall has no marker: %v",value.time,reasons)
        clips:=match_test_fall(t,&f,dt,.25-dt)
        value,_=animation_match(core.ref(&f.playback),f.rig)
        testing.expectf(t,len(clips)==1 && abs(value.time-.8)<.01,"and reaches its marker as it lands, at %.3f s",value.time)
    }
    {
        // A body that starts to move in the air goes on with the jump that travels, on time.
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f,leap=true)) {return}
        for _ in 0..<10 {testing.expect(t,match_step(&f,dt,GROUND))}
        testing.expect(t,match_step(&f,dt,AIR,time_to_land=.8))
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        testing.expectf(t,value.clip==base.name_hash("jump"),"standing, the jump in place, not %v",value)
        clips:=match_test_fall(t,&f,dt,.8-dt,turn={0,0,-3})
        value,_=animation_match(core.ref(&f.playback),f.rig)
        // Within half a row of its marker and a tick at the fastest landing rate.
        testing.expectf(t,len(clips)==2 && clips[1]==base.name_hash("leap") && abs(value.time-.8)<=.5/30+2*dt+.01,"moving, the leap takes over and lands at %.3f s",value.time)
    }
}

@(test)
match_assets_roundtrip_refuse_no_memory_or_looping_entries_and_report_a_database_past_their_memory :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f,memory=1)) {return}
    set:=f.graphs.contents[0].set;profile:=set.match
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document;if !testing.expect_value(t,character_document(&doc,&types,MATCH_TEST_ID,set),asset.Error.None) {return};defer asset.document_destroy(&doc)
    // Only the current version reads.
    for version in ([2]type_of(doc.kind_version){CHARACTER_VERSION,CHARACTER_VERSION+1}) {
        doc.kind_version=version
        writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
        if !testing.expect_value(t,asset.document_write(&doc,&writer),asset.Error.None) {continue}
        file:asset.Asset
        if !testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&writer)),asset.Error.None) {continue};defer asset.asset_close(&file)
        read_set,read:=character_view(&file,&types);view:=read_set.match
        if version!=CHARACTER_VERSION {testing.expect_value(t,read,asset.Error.Version);continue}
        if !testing.expect_value(t,read,asset.Error.None) {continue}
        testing.expect_value(t,view.info,profile.info);testing.expect_value(t,len(view.clips),len(profile.clips))
        for clip,i in view.clips {testing.expect_value(t,clip,profile.clips[i])}
    }
    changed:=profile;changed.info.memory=0
    testing.expect(t,!match_check(changed),"locomotion keeps some memory")
    // A blended source keeps its clips and samples; one that blends a clip with no sample, a
    // weight out of 0..1, weights that add to zero or one for a clip it does not blend, a sample
    // of a source that does not blend, or a blend that does not loop, is refused.
    blended:=make([]Match_Source,len(profile.clips));defer delete(blended);copy(blended,profile.clips)
    base.text_set(blended[1].blend[0][:],"idle")
    samples:=[2]Match_Sample{{source=1,weights={0=1}},{source=1,weights={0=.5,1=.5},speed=.8}}
    changed=profile;changed.clips,changed.samples=blended,samples[:]
    if testing.expect(t,match_check(changed)) {
        blend_doc:asset.Document
        blended_set:=set;blended_set.match=changed
        if testing.expect_value(t,character_document(&blend_doc,&types,MATCH_TEST_ID,blended_set),asset.Error.None) {
            defer asset.document_destroy(&blend_doc)
            writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
            file:asset.Asset
            if testing.expect(t,asset.document_write(&blend_doc,&writer)==.None && asset.asset_open(&file,serial.writer_bytes(&writer))==.None) {
                defer asset.asset_close(&file)
                read_set,read:=character_view(&file,&types);view:=read_set.match
                testing.expect(t,read==.None && len(view.samples)==2 && view.samples[1]==samples[1] && view.clips[1].blend==blended[1].blend,"a blend and its samples read back")
            }
        }
    }
    Refused :: struct {sample:Match_Sample,loop:bool}
    for refused,i in ([?]Refused{{{source=1,weights={0=1.5}},true},{{source=1},true},{{source=1,weights={2=1}},true},{{source=0,weights={0=1}},true},{{source=1,weights={0=1}},false}}) {
        wrong:=samples;wrong[0]=refused.sample;blended[1].loop=refused.loop
        changed.samples=wrong[:]
        testing.expectf(t,!match_check(changed),"blend %d is refused",i)
    }
    blended[1].loop=true;changed.samples=nil
    testing.expect(t,!match_check(changed),"a blend without samples is refused")
    clips:=make([]Match_Source,len(profile.clips));defer delete(clips);copy(clips,profile.clips)
    clips[3].loop=true;changed=profile;changed.clips=clips
    invalid:asset.Document;invalid_set:=set;invalid_set.match=changed
    testing.expect(t,!match_check(changed) && character_document(&invalid,&types,MATCH_TEST_ID,invalid_set)==.Invalid,"an entry clip does not loop")
    testing.expect(t,match_step(&f,.1,GROUND))
    testing.expect(t,core.problem_find(&f.problems,f.rig,"animation.match_memory")!=nil,"a database past the memory of its locomotion is reported")
}

@(test)
a_blended_sample_plays_its_clips_together_at_its_weights_in_phase :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    // walk blended with idle, half and half: it travels at half the 1.5 m/s of the walk.
    content:=&f.graphs.contents[0]
    base.text_set(content.set.match.clips[1].blend[0][:],"idle")
    samples:=make([]Match_Sample,1);samples[0]={source=1,weights={0=.25,1=.25}}
    content.set.match.samples=samples
    if !testing.expect(t,match_check(content.set.match)) {return}
    dt:=f32(1.0/60)
    for _ in 0..<30 {testing.expect(t,match_step(&f,dt,GROUND,velocity={0,0,-.75},desired={0,0,-.75}))}
    group:=f.state.program.output
    if !testing.expectf(t,group.count==2 && group.normalized,"the blend plays two clips together, not %d",group.count) {return}
    walk,idle:=group.leaves[0],group.leaves[1]
    testing.expect(t,walk.clip==base.name_hash("walk") && idle.clip==base.name_hash("idle") && walk.weight==.5 && idle.weight==.5 && walk.speed==idle.speed,"at the shares of its weights and one rate")
    a,b:=f.state.program.players[walk.player].player,f.state.program.players[idle.player].player
    testing.expectf(t,abs(a.time-b.time)<1e-3,"in phase: %.4f s and %.4f s",a.time,b.time)
    db:=&content.databases[0].database
    testing.expectf(t,abs(db.ranges[1].speed-.75)<.1,"measured from the blended feet, it goes %.3f m/s",db.ranges[1].speed)
    // The left foot is halfway between the stride of the walk and where idle keeps it.
    time:=lib.player_time(&f.content.lib,a)
    stride:=lib.clip_evaluate(&f.content.lib,lib.clip_tracks(&f.content.lib,lib.clip_find(&f.content.lib,base.name_hash("walk")))[0],time)
    foot:=playing_pose(f.state,.Local)[bone_resolve(f.state,bone_ref("foot_l"))].position
    testing.expectf(t,linalg.length(foot-mm.Vec3{.1,(stride.y-.95)/2,stride.z/2})<.01,"the foot is at %v, halfway to the stride %v",foot,stride)

    // Clips of different durations blend over the mean of their durations by weight: walk (1 s)
    // and vault (2 s), half and half, last 1.5 s, and each plays at the same share of its own.
    g:Match_Fixture;defer match_fixture_free(&g)
    if !testing.expect(t,match_fixture(t,&g)) {return}
    base.text_set(g.graphs.contents[0].set.match.clips[1].blend[0][:],"vault")
    long:=make([]Match_Sample,1);long[0]={source=1,weights={0=.5,1=.5}}
    g.graphs.contents[0].set.match.samples=long
    for _ in 0..<30 {testing.expect(t,match_step(&g,dt,GROUND,velocity={0,0,-.75},desired={0,0,-.75}))}
    testing.expect(t,core.problem_find(&g.problems,g.rig,"animation.match_blend")==nil && g.graphs.contents[0].databases[0].database.ranges[1].count==46,"the blend has the rows of 1.5 s")
    mixed:=g.state.program.output
    if !testing.expectf(t,mixed.count==2,"the blend of walk and vault plays, not %d clips",mixed.count) {return}
    walked,vaulted:=g.state.program.players[mixed.leaves[0].player].player,g.state.program.players[mixed.leaves[1].player].player
    shares:=[2]f32{lib.player_time(&g.content.lib,walked),lib.player_time(&g.content.lib,vaulted)/2}
    testing.expectf(t,abs(shares[0]-shares[1])<1e-3,"in phase: %v of each clip",shares)
}

// A source mirrored Only plays its clip reflected: the left foot steps where the clip puts the
// right one, across the plane between them; the root motion and the clock of warping follow.
@(test)
a_mirrored_source_plays_its_clip_with_left_and_right_swapped :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    content:=&f.graphs.contents[0]
    content.set.match.clips[1].mirror=.Only
    if !testing.expect(t,match_check(content.set.match)) {return}
    for _ in 0..<30 {testing.expect(t,match_step(&f,1.0/60,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5}))}
    value,_:=animation_match(core.ref(&f.playback),f.rig)
    player:=f.state.program.players[f.state.program.output.leaves[0].player].player
    right:=lib.clip_evaluate(&f.content.lib,lib.clip_tracks(&f.content.lib,lib.clip_find(&f.content.lib,base.name_hash("walk")))[1],lib.player_time(&f.content.lib,player))
    foot:=playing_pose(f.state,.Local)[bone_resolve(f.state,bone_ref("foot_l"))].position
    testing.expectf(t,value.clip==base.name_hash("walk") && f.state.program.output.mirror && linalg.length(foot-mm.Vec3{-right.x,right.y,right.z})<.01,"the left foot is at %v, the right one of the clip at %v",foot,right.xyz)
}

// A source with rates of its own follows the body between them, past those of the .character: the walk
// of 1.5 m/s, let up to 1.5 times its speed, plays at 1.5 for a body at 2.25 m/s where the .character
// stops the rest at their own speed; rates out of order are refused.
@(test)
a_source_with_rates_of_its_own_follows_the_body_between_them :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    content:=&f.graphs.contents[0]
    content.set.match.clips[1].min_rate,content.set.match.clips[1].max_rate=.5,1.5
    if !testing.expect(t,match_check(content.set.match)) {return}
    dt:=f32(1.0/60)
    for _ in 0..<60 {testing.expect(t,match_step(&f,dt,GROUND,velocity={0,0,-2.25},desired={0,0,-2.25}))}
    value,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expectf(t,value.clip==base.name_hash("walk") && abs(value.rate-1.5)<.01,"the walk plays at 1.5: %v",value)
    for refused in ([3][2]f32{{1.5,.5},{0,1},{-1,1}}) {
        content.set.match.clips[1].min_rate,content.set.match.clips[1].max_rate=refused[0],refused[1]
        testing.expectf(t,!match_check(content.set.match),"rates %v are refused",refused)
    }
}

@(test)
a_jump_nothing_forces_waits_the_hold_after_the_one_before :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    info:=&f.graphs.contents[0].set.match.info;info.lag=0
    dt:=f32(1.0/60)
    // The body walks and stands on alternate ticks: every search would rather jump.
    last,gap,jumps:=-1,max(int),u32(0)
    for tick in 0..<120 {
        speed:=f32(1.5) if tick%2==0 else 0
        testing.expect(t,match_step(&f,dt,GROUND,velocity={0,0,-speed},desired={0,0,-speed}))
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        if value.jumps>jumps && tick>=10 {if last>=0 {gap=min(gap,tick-last)};last=tick}
        jumps=value.jumps
    }
    testing.expectf(t,last>=0 && gap!=max(int) && f32(gap)*dt>=info.hold-1e-4,"jumps come at least %.2f s apart, not %d ticks",info.hold,gap)
}

// The tick a jump of matching blends in moves the pose on: it is not the pose of the tick before
// held for a tick.
@(test)
a_jump_of_matching_moves_the_pose_in_its_own_tick :: proc(t:^testing.T) {
    Case :: struct {name:string,walk,stand:int}
    cases:=[?]Case{{name="walk to stand",walk=40,stand=20},{name="walk and stand by turns",walk=12,stand=12}}
    dt:=f32(1.0/60)
    for c in cases {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {continue}
        f.graphs.contents[0].set.match.info.lag=0
        poses:[dynamic][4]mm.Vec3;defer delete(poses)
        jumps,checked:=u32(0),0
        for tick in 0..<120 {
            speed:=f32(1.5) if tick%(c.walk+c.stand)<c.walk else 0
            if !testing.expect(t,match_step(&f,dt,GROUND,velocity={0,0,-speed},desired={0,0,-speed})) {break}
            pose:[4]mm.Vec3
            for b in 0..<4 {pose[b]=playing_pose(f.state,.Local)[b].position}
            append(&poses,pose)
            value,_:=animation_match(core.ref(&f.playback),f.rig)
            jumped:=value.jumps>jumps;jumps=value.jumps
            if !jumped || tick<12 {continue}
            moved,held:f32
            for b in 0..<4 {moved=max(moved,linalg.length(poses[tick-1][b]-poses[tick-2][b]));held=max(held,linalg.length(pose[b]-poses[tick-1][b]))}
            if moved<1e-3 {continue}
            checked+=1
            testing.expectf(t,held>.1*moved,"%s: the jump at tick %d moves the pose %.5f m, after %.5f m the tick before",c.name,tick,held,moved)
        }
        testing.expectf(t,checked>0,"%s: a jump left a moving pose",c.name)
    }
}

// With stationary_speed, a body that turns around passes through rest for a tick: it goes on
// with the clips that travel. One that pushes into a wall goes nowhere and stands.
@(test)
a_body_that_turns_around_does_not_stand_midway_and_one_against_a_wall_stands :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    f.graphs.contents[0].set.match.info.stationary_speed=.15
    dt:=f32(1.0/60)
    idle:=base.name_hash("idle")
    speed:=f32(1.4)
    for _ in 0..<60 {testing.expect(t,match_step(&f,dt,GROUND,velocity={0,0,-speed},desired={0,0,-speed}))}
    rested:=false
    for tick in 0..<30 {
        speed=max(speed-20*dt,-1.4)
        rested||=abs(speed)<.15
        testing.expect(t,match_step(&f,dt,GROUND,velocity={0,0,-speed},desired={0,0,1.4}))
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        testing.expectf(t,value.clip!=idle,"tick %d at %.2f m/s: a body that turns around walks on, not %v",tick,speed,value)
    }
    testing.expect(t,rested,"the turn passes through rest")
    for _ in 0..<30 {testing.expect(t,match_step(&f,dt,GROUND,desired={0,0,-1.4},wall={0,0,1}))}
    value,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expectf(t,value.clip==idle,"a body that pushes into a wall stands: %v",value)
}

@(test)
the_root_of_the_pose_follows_a_body_that_stops_within_its_lag_out_of_a_wall_and_closes_as_it_walks :: proc(t:^testing.T) {
    for blocked in ([2]bool{false,true}) {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {continue}
        f.graphs.contents[0].set.match.info.lag=.15
        info:=f.graphs.contents[0].set.match.info
        hips:=bone_resolve(f.state,bone_ref("hips"))
        dt:=f32(1.0/60)
        for _ in 0..<60 {testing.expect(t,match_step(&f,dt,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5}))}
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        testing.expectf(t,linalg.length(value.lag)<.01 && abs(value.velocity.z+1.5)<.01,"a steady walk keeps the root on the body: %v",value)
        wall:=mm.Vec3{0,0,1} if blocked else {}
        ahead,change:=f32(0),f32(0);velocity:=value.velocity
        for _ in 0..<60 {
            testing.expect(t,match_step(&f,dt,GROUND,wall=wall))
            value,_=animation_match(core.ref(&f.playback),f.rig)
            testing.expectf(t,linalg.length(value.lag)<=info.lag+1e-5,"the root strays %.3f m, past its lag",linalg.length(value.lag))
            ahead=max(ahead,-value.lag.z);change=max(change,linalg.length(value.velocity-velocity));velocity=value.velocity
            rest:=playing_pose(f.state,.Local)[hips].position
            match_lag_apply(f.state,mm.TRANSFORM_IDENTITY)
            testing.expect(t,linalg.length(playing_pose(f.state,.Local)[hips].position-rest-value.lag)<1e-5,"the root of the pose moves by the lag")
        }
        // Standing, the root holds where it stopped instead of sliding the feet to the body.
        testing.expectf(t,linalg.length(value.velocity)<.01,"the root of a pose that stands holds still: %v",value)
        if blocked {
            testing.expectf(t,ahead<=1e-5,"a wall keeps the root out of it: %.4f m in",ahead)
        } else {
            testing.expectf(t,ahead>.02 && change<.5,"the root goes on %.3f m past the stop and slows by %.2f m/s a tick at most",ahead,change)
        }
        // Walking again, it closes on the body within the stride.
        for _ in 0..<90 {testing.expect(t,match_step(&f,dt,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5}))}
        value,_=animation_match(core.ref(&f.playback),f.rig)
        testing.expectf(t,linalg.length(value.lag)<.01,"the root settles on the body as it walks: %v",value)
    }
}

// Landing much later than told, the jump passes its marker in the air and plays on: the jump that
// travels fits a body that stands worse, whatever reselect leaves.
@(test)
a_jump_past_its_landing_marker_in_the_air_plays_on_unless_a_row_fits_better :: proc(t:^testing.T) {
    dt:=f32(1.0/60)
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f,leap=true)) {return}
    for _ in 0..<10 {testing.expect(t,match_step(&f,dt,GROUND))}
    testing.expect(t,match_step(&f,dt,AIR,time_to_land=.8))
    left,before:=f32(.8-dt),f32(-1)
    for tick:=0;left>dt*.5;tick+=1 {
        if tick==10 {left+=1}
        testing.expect(t,match_step(&f,dt,AIR,time_to_land=left))
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        testing.expectf(t,value.clip==base.name_hash("jump") && value.time>=before,"tick %d: the jump goes on, not %v from %.3f",tick,value,before)
        before=value.time
        left-=dt
    }
}

@(private="file") MATCH_TEST_LIBRARY :: base.Asset_Id{0x3a7c,4}

// A tick of the rig walking at velocity with the clips of content (the library it plays).
@(private="file")
match_step_with :: proc(f:^Match_Fixture,content:^host.Content_Animation,dt:f32,mode:u16,velocity:mm.Vec3) -> bool {
    return match_step(f,dt,mode,velocity,velocity,content=content)
}

// A weapon's set: Animation.library swaps the clips of the .character for those of the same names in
// another .anim, here a walk with the feet in the other phase. The rig goes on with the clip of
// the new library that the search picks, entered through an inertial transition from the pose it
// had, as a jump of matching does: the feet do not jump to the rest pose or the new walk at once.
// The library of a weapon's set: the clips of the fixture of the same names, the walk with the feet
// in the other phase, registered as an .anim.
@(private="file")
match_test_weapon :: proc(t:^testing.T,f:^Match_Fixture) -> (weapon:host.Content_Animation,ok:bool) {
    left,right:=f.bones[1].target,f.bones[2].target
    still:=[2]lib.Keyframe{{time=0,value={.1,-.95,0,0}},{time=1,value={.1,-.95,0,0}}}
    other:=[2]lib.Keyframe{{time=0,value={-.1,-.95,0,0}},{time=1,value={-.1,-.95,0,0}}}
    stride_l:=[4]lib.Keyframe{{time=0,value={.1,-.95,.375,0}},{time=.25,value={.1,-.8,0,0}},{time=.5,value={.1,-.95,-.375,0}},{time=1,value={.1,-.95,.375,0}}}
    stride_r:=[4]lib.Keyframe{{time=0,value={-.1,-.95,-.375,0}},{time=.5,value={-.1,-.95,.375,0}},{time=.75,value={-.1,-.8,0,0}},{time=1,value={-.1,-.95,-.375,0}}}
    tucked:=[2]lib.Keyframe{{time=0,value={.1,-.6,-.1,0}},{time=1,value={.1,-.6,-.1,0}}}
    land:=[1]lib.Marker{{time=.8,id=0}}
    descs:=[4]lib.Clip_Desc{
        {name=base.name_hash("idle"),tracks={{target=left,property=.Position,keys=still[:]},{target=right,property=.Position,keys=other[:]}}},
        {name=base.name_hash("walk"),tracks={{target=left,property=.Position,keys=stride_l[:]},{target=right,property=.Position,keys=stride_r[:]}}},
        {name=base.name_hash("fall"),tracks={{target=left,property=.Position,keys=tucked[:]},{target=right,property=.Position,keys=other[:]}}},
        {name=base.name_hash("jump"),tracks={{target=left,property=.Position,keys=tucked[:]},{target=right,property=.Position,keys=other[:]}},markers=land[:]},
    }
    weapon.id,weapon.generation=MATCH_TEST_LIBRARY,1
    if !testing.expect(t,lib.library_init(&weapon.lib,{max_keys=64,max_tracks=16,max_clips=2*len(descs),max_markers=2})) {return}
    for desc in descs {_,error:=lib.clip_add(&weapon.lib,desc);testing.expect(t,error==.None)}
    _,compressed:=lib.library_compress(&weapon.lib);testing.expect(t,compressed==.None)
    host.content_animation_loops(&weapon.lib,len(descs));weapon.clip_count=len(descs)
    weapon.markers=make([]host.Content_Marker,1);weapon.markers[0].name=base.name_hash("land")
    append(&f.assets.registry.files,asset.Registry_File{id=MATCH_TEST_LIBRARY,kind=asset.KIND_ANIMATION,state=.Asset})
    f.assets.registry.by_id[MATCH_TEST_LIBRARY]=u32(len(f.assets.registry.files)-1)
    return weapon,compressed==.None
}

// A weapon's set: Animation.library swaps the clips of the .character for those of the same names in
// another .anim, here a walk with the feet in the other phase. The rig goes on with the clip of
// the new library that the search picks, entered through an inertial transition from the pose it
// had, as a jump of matching does: the feet do not jump to the rest pose or the new walk at once.
@(test)
match_library_swap_enters_the_new_clips_through_an_inertial_transition :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    weapon,made:=match_test_weapon(t,&f)
    defer {lib.library_destroy(&weapon.lib);delete(weapon.markers)}
    if !made {return}

    dt:=f32(1)/30;walking:=mm.Vec3{0,0,-1.5}
    for _ in 0..<20 {testing.expect(t,match_step_with(&f,&f.content,dt,GROUND,walking))}
    before:=[2]mm.Vec3{playing_pose(f.state,.Local)[1].position,playing_pose(f.state,.Local)[2].position}
    foot_l:=bone_resolve(f.state,bone_ref("foot_l"))
    planted:=playing_pose(f.state,.Local)[foot_l].position
    walked,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expect(t,walked.clip==base.name_hash("walk"),"it walks before the swap")

    f.animation.library=MATCH_TEST_LIBRARY
    if !testing.expect(t,match_step_with(&f,&weapon,dt,GROUND,walking)) {return}
    after:=[2]mm.Vec3{playing_pose(f.state,.Local)[1].position,playing_pose(f.state,.Local)[2].position}
    swapped,_:=animation_match(core.ref(&f.playback),f.rig)
    jump:=max(linalg.length(after[0]-before[0]),linalg.length(after[1]-before[1]))
    testing.expect(t,f.state.program.library==MATCH_TEST_LIBRARY && swapped.clip==base.name_hash("walk"),"the rig plays the walk of the new library")
    testing.expect(t,f.state.stack.inertia.state.active,"the swap enters the new clip through an inertial transition")
    testing.expectf(t,jump<.1,"a foot jumps %.3f m in the tick of the swap",jump)
    // Nothing of the new library plays yet: the search asks for the feet the rig has, not for the
    // mean of the database, and enters the new walk where its left foot is where the rig has it.
    walk_new:=lib.clip_find(&weapon.lib,base.name_hash("walk"))
    entered:=lib.clip_evaluate(&weapon.lib,lib.clip_tracks(&weapon.lib,walk_new)[0],f.state.program.output.leaves[0].start)
    testing.expectf(t,linalg.length(entered.xyz-planted)<.03,"the new walk starts with the left foot at %v, the rig had it at %v",entered.xyz,planted)
    // Past the blend, the feet are those of the new walk.
    for _ in 0..<15 {testing.expect(t,match_step_with(&f,&weapon,dt,GROUND,walking))}
    testing.expect(t,!f.state.stack.inertia.state.active,"the transition ends within its blend")
}

@(private="file")
match_test_span :: proc(name:string,kind:lib.Match_Span_Kind) -> (span:Match_Span) {
    base.text_set(span.name[:],name);span.kind=kind
    return
}
// Walks steadily for ticks of dt, noting whether the walk plays inside from..to of its clip, the
// most ticks in a row it does, and how many jumps land there.
@(private="file")
match_test_walk_span :: proc(t:^testing.T,f:^Match_Fixture,ticks:int,dt,from,to:f32) -> (inside,runs,landed:int) {
    walk:=base.name_hash("walk")
    run,jumps:=0,u32(0)
    for _ in 0..<ticks {
        if !testing.expect(t,match_step(f,dt,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5})) {return}
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        within:=value.clip==walk && value.time>=from && value.time<=to
        if within {inside+=1;run+=1;runs=max(runs,run)} else {run=0}
        if within && value.jumps>jumps {landed+=1}
        jumps=value.jumps
    }
    return
}

@(test)
spans_of_a_set_keep_rows_out_of_the_search_and_leave_or_play_into_them :: proc(t:^testing.T) {
    dt:=f32(1.0/60)
    // The walk stumbles in .4..6 s, which a steady walk plays through when no span rules it.
    // Excluded: no jump lands there and one that plays into it leaves at once; blocked: none lands
    // there, and the walk plays on through it.
    stumble:=[1]lib.Marker{{time=.4,id=5,duration=.2}}
    for ruled in 0..<3 {
        f:Match_Fixture
        kind:=lib.Match_Span_Kind.Exclude if ruled==1 else .Block
        spans:=[1]Match_Span{match_test_span("stumble",kind)}
        if !testing.expect(t,match_fixture(t,&f,walk_spans=stumble[:],spans=spans[:] if ruled>0 else nil)) {match_fixture_free(&f);continue}
        f.graphs.contents[0].set.match.info.lag=0
        inside,runs,landed:=match_test_walk_span(t,&f,240,dt,.4+1e-3,.6-1e-3)
        if ruled==0 {
            testing.expectf(t,runs>=8,"a steady walk plays through the stumble: %d ticks in a row",runs)
            match_fixture_free(&f)
            continue
        } else if kind==.Exclude {
            testing.expectf(t,runs<=1 && landed==0,"an excluded stumble is left at once: %d ticks inside, %d in a row, %d jumps into it",inside,runs,landed)
        } else {
            testing.expectf(t,runs>=8 && landed==0,"a blocked stumble plays through: %d ticks in a row, %d jumps into it",runs,landed)
        }
        db:=animation_match_database(core.ref(&f.graphs),&f.content,f.state)
        testing.expect(t,db!=nil && len(db.flags)==db.rows && core.problem_find(&f.problems,f.rig,"animation.match_span")==nil,"the spans of the walk rule its rows")
        match_fixture_free(&f)
    }
    whole:=[1]lib.Marker{{time=0,id=4,duration=1}}
    // A span no clip has, and an exclusion of a whole clip, are problems of the rig; the search
    // says Span of the clip it keeps out.
    {
        f:Match_Fixture;defer match_fixture_free(&f)
        spans:=[1]Match_Span{match_test_span("nowhere",.Exclude)}
        if testing.expect(t,match_fixture(t,&f,spans=spans[:])) {
            testing.expect(t,match_step(&f,dt,GROUND))
            testing.expect(t,core.problem_find(&f.problems,f.rig,"animation.match_span")!=nil,"a span of a name no clip has is reported")
        }
    }
    {
        f:Match_Fixture;defer match_fixture_free(&f)
        spans:=[1]Match_Span{match_test_span("hold",.Exclude)}
        if testing.expect(t,match_fixture(t,&f,walk_spans=whole[:],spans=spans[:])) {
            for _ in 0..<4 {testing.expect(t,match_step(&f,dt,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5}))}
            testing.expect(t,core.problem_find(&f.problems,f.rig,"animation.match_span")!=nil,"a walk excluded whole is reported")
            db:=animation_match_database(core.ref(&f.graphs),&f.content,f.state)
            if testing.expect(t,db!=nil) {
                noted:=match_searched_candidates(db,match_test_searched(&f))
                reason:=lib.Match_Reject.None
                for item in noted.items[:noted.count] {if lib.match_range_of(db,int(item.row))==1 {reason=item.reason}}
                testing.expectf(t,reason==.Span,"the walk is left out by its span, not %v",reason)
            }
        }
    }
    // The table reads back, and a set refuses a span without a name, a second rule for a name, or
    // one of no kind.
    {
        f:Match_Fixture;defer match_fixture_free(&f)
        spans:=[2]Match_Span{match_test_span("stumble",.Block),match_test_span("hold",.Exclude)}
        if !testing.expect(t,match_fixture(t,&f,walk_spans=stumble[:],spans=spans[:])) {return}
        set:=f.graphs.contents[0].set
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        doc:asset.Document;if !testing.expect_value(t,character_document(&doc,&types,MATCH_TEST_ID,set),asset.Error.None) {return};defer asset.document_destroy(&doc)
        writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
        file:asset.Asset
        if testing.expect(t,asset.document_write(&doc,&writer)==.None && asset.asset_open(&file,serial.writer_bytes(&writer))==.None) {
            defer asset.asset_close(&file)
            view,read:=character_view(&file,&types)
            testing.expect(t,read==.None && len(view.match.spans)==2 && view.match.spans[1]==spans[1],"the spans read back")
        }
        for wrong in ([3]Match_Span{match_test_span("",.Block),match_test_span("stumble",.Exclude),match_test_span("swing",lib.Match_Span_Kind(7))}) {
            changed:=set.match;more:=[3]Match_Span{spans[0],spans[1],wrong};changed.spans=more[:]
            testing.expectf(t,!match_check(changed),"%v is refused",wrong)
        }
    }
}

// A copy of the world rolled back to and replayed with the same inputs gives the same poses,
// actions, layers and matching, bit for bit: the copy carries every state the simulation reads.
// It leaves out what is only diagnostics (the last search) and what a tick only works in, and
// a copy back into a world that already played allocates nothing.
@(test)
a_rig_rolled_back_to_a_copy_of_its_world_replays_its_poses_exactly :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    dt:=f32(.05)
    for _ in 0..<6 {set(&f.requests,f.rig,"aim_yaw",.5);testing.expect(t,match_step(&f,dt,GROUND,desired={0,0,-1}))}
    play(&f.requests,f.rig,"Kick")
    set(&f.requests,f.rig,"aim_yaw",.5);testing.expect(t,match_step(&f,dt,GROUND,desired={0,0,-1}))
    if !testing.expect(t,f.state.stack!=nil && f.state.stack.slots==3) {return}
    // The snapshot a rollback goes back to, measured as it is taken.
    tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator);defer mem.tracking_allocator_destroy(&tracking)
    snapshot:Playback;defer playback_free(&snapshot)
    actions:Action_Runtime;defer actions_runtime_free(&actions)
    {
        context.allocator=mem.tracking_allocator(&tracking)
        testing.expect(t,playback_copy(&snapshot,&f.playback))
    }
    taken,taken_bytes:=tracking.total_allocation_count,tracking.total_memory_allocated
    testing.expect(t,len(snapshot.searches)==0 && len(snapshot.work.rows)==0 && len(snapshot.work.jobs)==0,"a copy carries no diagnostics nor work")
    copied:=&snapshot.states[0]
    testing.expect(t,copied.stack!=nil && copied.stack!=f.state.stack && copied.stack.scratch.curves==nil && copied.stack.scratch.values==nil,"its stack is its own, without the scratch of a tick")
    testing.expect(t,core.value_copy(&actions,&f.actions,type_info_of(Action_Runtime)))
    TICKS :: 12
    Tick :: struct {pose:[4]mm.Transform,curves,events:int,motion:Root_Delta,clip:u64,time:f32,weights:[STACK_SLOTS]f32}
    run :: proc(t:^testing.T,f:^Match_Fixture,dt:f32,out:^[TICKS]Tick) {
        for &tick,i in out {
            if i==2 {play(&f.requests,f.rig,"Vault")}
            if i==8 {play(&f.requests,f.rig,"Kick")}
            set(&f.requests,f.rig,"aim_yaw",f32(i)/TICKS)
            desired:=mm.Vec3{0,0,-1} if i<5 else {1,0,0}
            testing.expect(t,match_step(f,dt,GROUND,desired=desired,velocity=desired*f32(i)*.1))
            copy(tick.pose[:],playing_pose(f.state,.Local))
            tick.curves,tick.events,tick.motion=len(f.state.curves),len(f.events.items),f.state.motion
            tick.clip,tick.time=f.state.program.match.clip,f.state.time
            for &layer,k in f.state.stack.layers {tick.weights[k]=layer.weight}
        }
    }
    played,replayed:[TICKS]Tick
    run(t,&f,dt,&played)
    // Back to the snapshot: the world keeps its own work, so the copy back allocates nothing.
    tracking_back:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking_back,context.allocator)
    {
        context.allocator=mem.tracking_allocator(&tracking_back)
        testing.expect(t,playback_copy(&f.playback,&snapshot))
    }
    back:=tracking_back.total_allocation_count;mem.tracking_allocator_destroy(&tracking_back)
    actions_runtime_free(&f.actions);testing.expect(t,core.value_copy(&f.actions,&actions,type_info_of(Action_Runtime)))
    f.state=state_get(&f.playback,f.rig)
    _,noted:=match_searched(core.ref(&f.playback),f.rig)
    testing.expect(t,!noted,"the last search, diagnostics only, is not rolled back")
    run(t,&f,dt,&replayed)
    for tick,i in played {
        testing.expectf(t,tick==replayed[i],"tick %d replays as it played: %v, then %v",i,tick,replayed[i])
    }
    testing.expect(t,played[TICKS-1].weights!=played[0].weights,"the replay covers actions and layers that changed")
    testing.expectf(t,back==0,"a rollback into a world that played allocates nothing (%d allocations)",back)
    log.infof("rollback copy of a character: %d allocations, %d B (before the split of the stack and its scratch: 17 allocations, 11008 B); back into the world: %d allocations",taken,taken_bytes,back)
}

// The raw value of feature at of a query of db.
@(private="file")
match_test_raw :: proc(db:^lib.Match_Database,query:lib.Match_Query,at:int) -> f32 {
    lanes:=simd_lanes(query[at/4])
    return lanes[at%4]*db.scale[at]+db.mean[at]
}
@(private="file")
simd_lanes :: proc(lane:#simd[4]f32) -> [4]f32 {return transmute([4]f32)lane}

// The extra points of a set are features of its database, on the bones of the skeleton it plays
// on: 12 lanes a row with them, 8 without; a point on a bone the skeleton does not have is a
// problem of the rig, and the set refuses one out of order or of a weight that is not finite.
@(test)
extra_points_of_a_set_are_features_of_its_database_on_bones_of_the_skeleton :: proc(t:^testing.T) {
    Case :: struct {bone:string,lanes:int,problem:bool}
    for c in ([?]Case{{"",lib.MATCH_LANES_BASE,false},{"head",lib.MATCH_LANES_EXTRA,false},{"sword",0,true}}) {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {continue}
        info:=&f.graphs.contents[0].set.match.info
        if c.bone!="" {base.text_set(info.extras[0].bone[:],c.bone);info.extras[0].offset,info.extras[0].weight={0,.3,0},1}
        if !testing.expect(t,match_check(f.graphs.contents[0].set.match)) {continue}
        for _ in 0..<3 {testing.expect(t,match_step(&f,1.0/30,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5}))}
        db:=animation_match_database(core.ref(&f.graphs),&f.content,f.state)
        reported:=core.problem_find(&f.problems,f.rig,"animation.match_extra")!=nil
        testing.expectf(t,reported==c.problem && (db==nil)==c.problem,"a point on '%s': reported %v, database %v",c.bone,reported,db!=nil)
        if db!=nil {testing.expectf(t,db.lanes==c.lanes && db.extra_count==(1 if c.bone!="" else 0),"a point on '%s' keeps %d lanes",c.bone,db.lanes)}
    }
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    profile:=f.graphs.contents[0].set.match
    for wrong,i in ([3][lib.MATCH_EXTRAS]Match_Extra{{1={weight=1}},{0={weight=cmath.nan_f32()}},{0={weight=-1}}}) {
        changed:=profile;changed.info.extras=wrong
        if i>0 {base.text_set(changed.info.extras[0].bone[:],"head")}
        testing.expectf(t,!match_check(changed),"extras %d are refused",i)
    }
}

// After a swap of library the first search weighs none of the extra points, which are of the set
// the rig played; the next ones weigh them again. When a whole-body action ends the search asks
// for the points of the pose it left (the head of an aim), not those of the row under it.
@(test)
a_swapped_library_skips_the_extra_points_and_an_ended_action_searches_from_its_pose :: proc(t:^testing.T) {
    dt:=f32(1)/30;walking:=mm.Vec3{0,0,-1.5}
    {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {return}
        info:=&f.graphs.contents[0].set.match.info
        base.text_set(info.extras[0].bone[:],"head");info.extras[0].offset,info.extras[0].weight={0,.3,0},1
        weapon,made:=match_test_weapon(t,&f)
        defer {lib.library_destroy(&weapon.lib);delete(weapon.markers)}
        if !made {return}
        for _ in 0..<20 {testing.expect(t,match_step_with(&f,&f.content,dt,GROUND,walking))}
        testing.expect(t,!match_test_searched(&f).request.skip_extras,"a search in the same library weighs the points")
        f.animation.library=MATCH_TEST_LIBRARY
        if !testing.expect(t,match_step_with(&f,&weapon,dt,GROUND,walking)) {return}
        searched:=match_test_searched(&f)
        db:=animation_match_database(core.ref(&f.graphs),&weapon,f.state)
        if !testing.expect(t,db!=nil && db.lanes==lib.MATCH_LANES_EXTRA) {return}
        _,weights,_:=lib.match_query(db,searched.request,1)
        zero:=true;for lane in weights[lib.MATCH_LANES_BASE:] {zero&&=simd_lanes(lane)=={}}
        testing.expectf(t,searched.row<0 && searched.request.skip_extras && zero,"the swap searches from row %d skipping the points: %v",searched.row,searched.request.skip_extras)
        first:=searched.search
        for _ in 0..<10 {testing.expect(t,match_step_with(&f,&weapon,dt,GROUND,walking))}
        later:=match_test_searched(&f)
        testing.expect(t,later.search>first && !later.request.skip_extras,"the searches after it weigh the points again")
    }
    {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {return}
        set:=&f.graphs.contents[0].set
        base.text_set(set.match.info.extras[0].bone[:],"head");set.match.info.extras[0].offset,set.match.info.extras[0].weight={0,.3,0},1
        // Stomp plays the aim to the left over the whole body, the head .2 m aside, and fades out.
        base.text_set(set.actions.actions[9].clip[:],"aim_left")
        for _ in 0..<10 {testing.expect(t,match_step(&f,dt,GROUND))}
        play(&f.requests,f.rig,"Stomp")
        covered:=false;aside:=f32(0);searched_then:=false
        for _ in 0..<90 {
            if !testing.expect(t,match_step(&f,dt,GROUND)) {return}
            value,_:=animation_match(core.ref(&f.playback),f.rig)
            if value.forced {covered=true;continue}
            if !covered {continue}
            // The action ended in this tick; the next one searches from the pose it showed.
            before:=match_test_searched(&f).search
            if !testing.expect(t,match_step(&f,dt,GROUND)) {return}
            searched:=match_test_searched(&f)
            db:=animation_match_database(core.ref(&f.graphs),&f.content,f.state)
            if db==nil {break}
            searched_then=searched.search>before
            aside=match_test_raw(db,searched.request.query,lib.MATCH_AT_EXTRAS)
            break
        }
        testing.expectf(t,covered && searched_then && aside< -.1,"the tick the action ends searches (%v) for the head tip it left at x %.3f",searched_then,aside)
    }
}

// A library that does not mirror plays the sources that mirror as they were made: no mirrored rows
// in its database, while the same set over a library that mirrors has them.
@(test)
a_library_that_does_not_mirror_leaves_out_the_mirrored_rows_of_its_sources :: proc(t:^testing.T) {
    Case :: struct {mirror:Match_Mirror,listed,no_mirror:bool,mirrored,plain:int}
    for c in ([?]Case{{.Both,false,false,1,4},{.Both,true,false,1,4},{.Both,true,true,0,4},{.Only,true,false,1,3},{.Only,true,true,0,4}}) {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {continue}
        content:=&f.graphs.contents[0]
        content.set.match.clips[1].mirror=c.mirror
        libraries:=[1]Match_Library{{animation=f.content.id,no_mirror=c.no_mirror}}
        if c.listed {content.set.match.libraries=libraries[:]}
        if !testing.expect(t,match_check(content.set.match)) {continue}
        testing.expect(t,match_step(&f,1.0/30,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5}))
        db:=animation_match_database(core.ref(&f.graphs),&f.content,f.state)
        if !testing.expect(t,db!=nil) {continue}
        mirrored,plain:=0,0
        for r in db.ranges {if r.mirror {mirrored+=1} else {plain+=1}}
        testing.expectf(t,mirrored==c.mirrored && plain==c.plain,"%v: %d mirrored and %d plain ranges",c,mirrored,plain)
        content.set.match.libraries=nil
    }
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    twice:=[2]Match_Library{{animation=f.content.id},{animation=f.content.id,no_mirror=true}}
    empty:=[1]Match_Library{{no_mirror=true}}
    for wrong in ([2][]Match_Library{twice[:],empty[:]}) {
        changed:=f.graphs.contents[0].set.match;changed.libraries=wrong
        testing.expect(t,!match_check(changed),"a library listed twice or without its .anim is refused")
    }
}

// The libraries a set lists have their databases built with the first one of a skeleton, so the
// tick that swaps one in builds nothing; one the set does not list is built in that tick.
@(test)
the_libraries_of_a_set_are_built_before_the_tick_that_swaps_them_in :: proc(t:^testing.T) {
    dt:=f32(1)/30;walking:=mm.Vec3{0,0,-1.5}
    for listed in ([2]bool{true,false}) {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {continue}
        weapon,made:=match_test_weapon(t,&f)
        native:=host.app_content(&f.app)
        append(&native.animations,weapon);native.index[MATCH_TEST_LIBRARY]={kind=.Animation,index=0}
        defer host.app_content_destroy(&f.app)
        if !made {continue}
        content:=&f.graphs.contents[0]
        libraries:=[1]Match_Library{{animation=MATCH_TEST_LIBRARY}}
        if listed {content.set.match.libraries=libraries[:]}
        defer content.set.match.libraries=nil
        sources:=Source_Assets{allocator=context.allocator};defer source_assets_free(&sources)
        for _ in 0..<5 {
            testing.expect(t,match_step_with(&f,&f.content,dt,GROUND,walking))
            match_prebuild(f.state,f.animation,&f.app,&f.graphs,&sources,{})
        }
        built:=len(content.databases)
        testing.expectf(t,built==(2 if listed else 1),"listed %v: %d databases before the swap",listed,built)
        f.animation.library=MATCH_TEST_LIBRARY
        if !testing.expect(t,match_step_with(&f,&native.animations[0],dt,GROUND,walking)) {continue}
        swapped,_:=animation_match(core.ref(&f.playback),f.rig)
        testing.expectf(t,len(content.databases)==2 && swapped.clip==base.name_hash("walk") && animation_match_database(core.ref(&f.graphs),&native.animations[0],f.state)!=nil,"listed %v: %d databases after the swap",listed,len(content.databases))
        // A new generation of the library replaces its database instead of adding one.
        native.animations[0].generation=2
        testing.expect(t,match_step_with(&f,&native.animations[0],dt,GROUND,walking))
        testing.expectf(t,len(content.databases)==2,"a reloaded library keeps %d databases",len(content.databases))
    }
}

// A library of a set made on another skeleton plays retargeted onto that of the rig: its database
// is built ahead over the retarget once that is made (here one the content already holds, as a
// cooked one), so the tick that swaps it in builds nothing and searches the retarget.
@(test)
a_library_made_on_another_skeleton_builds_its_database_over_its_retarget_ahead :: proc(t:^testing.T) {
    dt:=f32(1)/30;walking:=mm.Vec3{0,0,-1.5}
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    weapon,made:=match_test_weapon(t,&f)
    retarget,retargeted_made:=match_test_weapon(t,&f)
    native:=host.app_content(&f.app)
    // Its clips were made on another skeleton; their retarget onto the rig is already made.
    other:=base.Asset_Id{0x3a7c,9}
    for library in ([2]^host.Content_Animation{&weapon,&retarget}) {
        library.skeletons=make([]base.Asset_Id,library.clip_count,native.allocator)
        for &id in library.skeletons {id=other if library==&weapon else f.definition.id}
        library.names=make([][asset.ANIMATION_NAME_CAPACITY]u8,library.clip_count,native.allocator)
        library.roots=make([]asset.Animation_Root,library.clip_count,native.allocator)
    }
    key:=asset.animation_retarget_id(MATCH_TEST_LIBRARY,f.definition.id)
    retarget.generation,retarget.retarget=2,{skeleton=f.definition.id,key=key}
    append(&native.animations,weapon,retarget)
    native.index[MATCH_TEST_LIBRARY]={kind=.Animation,index=0};native.index[key]={kind=.Animation,index=1}
    defer host.app_content_destroy(&f.app)
    if !made || !retargeted_made {return}
    content:=&f.graphs.contents[0]
    libraries:=[1]Match_Library{{animation=MATCH_TEST_LIBRARY}}
    content.set.match.libraries=libraries[:]
    defer content.set.match.libraries=nil
    sources:=Source_Assets{allocator=context.allocator};defer source_assets_free(&sources)
    f.state.rig=f.definition.id
    for _ in 0..<5 {
        testing.expect(t,match_step_with(&f,&f.content,dt,GROUND,walking))
        match_prebuild(f.state,f.animation,&f.app,&f.graphs,&sources,{})
    }
    played:=&native.animations[1]
    testing.expectf(t,len(content.databases)==2 && content.databases[1].key[2]==u64(played.generation),"%d databases, the second of generation %x",len(content.databases),content.databases[len(content.databases)-1].key[2])
    f.animation.library=MATCH_TEST_LIBRARY
    if !testing.expect(t,match_step_with(&f,played,dt,GROUND,walking)) {return}
    testing.expect(t,len(content.databases)==2 && animation_match_database(core.ref(&f.graphs),played,f.state)!=nil,"the swap builds nothing and searches the retarget")
}

// A set of more than 64 clips builds and searches: of 65 idles and 65 walks alike, the one of
// negative bias, past the 64th, plays, and the first walk, of positive bias, never does.
@(test)
a_set_of_more_than_64_clips_plays_the_one_its_bias_favors :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    left,right:=f.bones[1].target,f.bones[2].target
    still:=[2]lib.Keyframe{{time=0,value={.1,-.95,0,0}},{time=1,value={.1,-.95,0,0}}}
    other:=[2]lib.Keyframe{{time=0,value={-.1,-.95,0,0}},{time=1,value={-.1,-.95,0,0}}}
    stride_l:=[4]lib.Keyframe{{time=0,value={.1,-.95,-.375,0}},{time=.5,value={.1,-.95,.375,0}},{time=.75,value={.1,-.8,0,0}},{time=1,value={.1,-.95,-.375,0}}}
    stride_r:=[4]lib.Keyframe{{time=0,value={-.1,-.95,.375,0}},{time=.25,value={-.1,-.8,0,0}},{time=.5,value={-.1,-.95,-.375,0}},{time=1,value={-.1,-.95,.375,0}}}
    EACH :: 65
    many:host.Content_Animation
    many.id,many.generation=MATCH_TEST_LIBRARY,1
    if !testing.expect(t,lib.library_init(&many.lib,{max_keys=EACH*12,max_tracks=EACH*4,max_clips=4*EACH,max_markers=1})) {return}
    defer lib.library_destroy(&many.lib)
    clips:=make([]Match_Source,2*EACH);defer delete(clips)
    for i in 0..<2*EACH {
        walk:=i>=EACH
        name:=fmt.tprintf("%s_%d","walk" if walk else "idle",i%EACH)
        desc:=lib.Clip_Desc{name=base.name_hash(name),tracks={{target=left,property=.Position,keys=stride_l[:] if walk else still[:]},{target=right,property=.Position,keys=stride_r[:] if walk else other[:]}}}
        if _,error:=lib.clip_add(&many.lib,desc);!testing.expect(t,error==.None) {return}
        base.text_set(clips[i].clip[:],name);clips[i].modes,clips[i].loop=1<<GROUND,true
    }
    _,compressed:=lib.library_compress(&many.lib)
    if !testing.expect(t,compressed==.None) {return}
    host.content_animation_loops(&many.lib,2*EACH);many.clip_count=2*EACH
    append(&f.assets.registry.files,asset.Registry_File{id=MATCH_TEST_LIBRARY,kind=asset.KIND_ANIMATION,state=.Asset})
    f.assets.registry.by_id[MATCH_TEST_LIBRARY]=u32(len(f.assets.registry.files)-1)
    favored:=EACH+50
    clips[EACH].bias,clips[favored].bias=3,-1
    set:=&f.graphs.contents[0].set
    kept:=set.match.clips;defer set.match.clips=kept
    set.match.clips=clips
    if !testing.expect(t,match_check(set.match)) {return}
    f.animation.library=MATCH_TEST_LIBRARY
    played:map[u64]int;defer delete(played)
    for _ in 0..<60 {
        if !testing.expect(t,match_step(&f,1.0/30,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5},content=&many)) {return}
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        played[value.clip]+=1
    }
    db:=animation_match_database(core.ref(&f.graphs),&many,f.state)
    if !testing.expect(t,db!=nil) {return}
    testing.expectf(t,len(db.ranges)==2*EACH && db.rows>lib.MATCH_LINEAR_ROWS && len(db.small)>0 && db.bias_shift==1,"%d ranges, %d rows",len(db.ranges),db.rows)
    value,_:=animation_match(core.ref(&f.playback),f.rig)
    testing.expectf(t,value.clip==base.name_hash("walk_50") && played[base.name_hash("walk_0")]==0,"it walks %v, not walk_50",value.clip)
    tooMany:=make([]Match_Source,MATCH_CLIPS+1);defer delete(tooMany)
    for &source,i in tooMany {base.text_set(source.clip[:],fmt.tprintf("idle_%d",i));source.modes=1}
    changed:=set.match;changed.clips=tooMany
    testing.expect(t,!match_check(changed),"a set of more than MATCH_CLIPS clips is refused")
}

// The bias of the clip that plays weighs on the cost of playing on as on its rows in the search,
// so the two compare fairly: a walk of bias 1.5 never costs less than that.
@(test)
the_cost_of_playing_on_carries_the_bias_of_its_clip :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    f.graphs.contents[0].set.match.clips[1].bias=1.5
    if !testing.expect(t,match_check(f.graphs.contents[0].set.match)) {return}
    least:=max(f32);walked:=0
    for tick in 0..<90 {
        if !testing.expect(t,match_step(&f,1.0/30,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5})) {return}
        value,_:=animation_match(core.ref(&f.playback),f.rig)
        if tick<30 || value.clip!=base.name_hash("walk") {continue}
        walked+=1;least=min(least,value.cost)
    }
    testing.expectf(t,walked>30 && least>=1.5-1e-4,"walking %d ticks, the least cost is %.4f",walked,least)
}

// Inside a Keep span the clip plays on: no search nothing forces leaves it until it plays out,
// while the same walk without the span searches there at each interval.
@(test)
a_keep_span_holds_the_clip_against_the_searches_nothing_forces :: proc(t:^testing.T) {
    dt:=f32(1.0/60)
    hold:=[1]lib.Marker{{time=.2,id=4,duration=.5}}
    for ruled in ([2]bool{false,true}) {
        f:Match_Fixture;defer match_fixture_free(&f)
        spans:=[1]Match_Span{match_test_span("hold",.Keep)}
        if !testing.expect(t,match_fixture(t,&f,walk_spans=hold[:],spans=spans[:] if ruled else nil)) {continue}
        f.graphs.contents[0].set.match.info.lag=0
        walk:=base.name_hash("walk")
        inside,searched:=0,u32(0)
        previous:Animation_Match
        for tick in 0..<240 {
            if !testing.expect(t,match_step(&f,dt,GROUND,velocity={0,0,-1.5},desired={0,0,-1.5})) {break}
            value,_:=animation_match(core.ref(&f.playback),f.rig)
            within :: proc(m:Animation_Match,walk:u64) -> bool {return m.clip==walk && m.time>.2+1e-3 && m.time<.7-1e-3}
            if tick>0 && within(value,walk) && within(previous,walk) && value.jumps==previous.jumps {inside+=1;searched+=value.searches-previous.searches}
            previous=value
        }
        testing.expectf(t,inside>=20 && (searched==0)==ruled,"ruled %v: %d ticks inside, %d searches there",ruled,inside,searched)
        testing.expect(t,core.problem_find(&f.problems,f.rig,"animation.match_span")==nil)
    }
}

// A rig far from the sources (Rig_Lod.wait) searches its matching on the ticks of its cadence,
// and still at once when it must (its first search): searches it waits for are not lost.
@(test)
a_far_rig_searches_its_matching_on_the_ticks_of_its_cadence :: proc(t:^testing.T) {
    dt:=f32(1.0/60)
    counts:[2]u32
    for period,k in ([2]u64{1,4}) {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {return}
        for tick in 0..<u64(48) {
            f.state.lod.wait=!ai.cadence_due(tick,0,period)
            before:=f.state.program.match.searches
            desired:=mm.Vec3{0,0,-1} if tick%16<8 else {1,0,0}
            if !testing.expect(t,match_step(&f,dt,GROUND,desired=desired,velocity=desired*f32(tick%16)*.1)) {return}
            searched:=f.state.program.match.searches>before
            testing.expectf(t,!searched || !f.state.lod.wait || tick==0,"period %d, tick %d: a search waits for its cadence",period,tick)
        }
        counts[k]=f.state.program.match.searches
    }
    testing.expectf(t,counts[1]>0 && counts[1]<counts[0],"searches every tick and every 4: %v",counts)
}

// A rig posed again after ticks it skipped (Rig_Lod.skip) blends what changed from the pose it
// showed last, as one posed in every tick does: an action it starts does not cut in.
@(test)
a_rig_posed_after_skipped_ticks_blends_from_the_pose_it_showed :: proc(t:^testing.T) {
    dt:=f32(1.0/60)
    for skipped in ([2]u32{0,3}) {
        f:Match_Fixture;defer match_fixture_free(&f)
        if !testing.expect(t,match_fixture(t,&f)) {return}
        for _ in 0..<10 {testing.expect(t,match_step(&f,dt,GROUND))}
        // The ticks it skipped: its clocks ran, its pose did not.
        f.playback.frame+=u64(skipped);f.state.skipped=skipped
        play(&f.requests,f.rig,"Vault")
        if !testing.expect(t,match_step(&f,dt,GROUND) && f.state.stack!=nil) {return}
        testing.expectf(t,f.state.stack.inertia.state.active,"after %d skipped ticks the action blends in from the pose shown",skipped)
    }
}

// animation.match_forward names each turned clip of a database once (lib.Match_Range.turned is
// measured from their poses in std/anim): the clip of a range, of a loop or not, mirrored or the
// first of a blend, as many as fit and whether more are turned. A database without one names none.
@(test)
match_forward_names_each_turned_clip_once :: proc(t:^testing.T) {
    f:Match_Fixture;defer match_fixture_free(&f)
    if !testing.expect(t,match_fixture(t,&f)) {return}
    f.content.names=make([][asset.ANIMATION_NAME_CAPACITY]u8,f.content.clip_count);defer delete(f.content.names)
    for &name,i in f.content.names {base.text_set(name[:],fmt.tprintf("clip_%d",i+1))}
    R :: lib.Match_Range
    loops:=lib.Clip(f.content.clip_count)
    Case :: struct {name:string,ranges:[]R,fits:int,names:[]string,more:bool}
    cases:=[]Case{
        {"none turned",{{clips={0=1}},{clips={0=2}}},4,{},false},
        {"a turned loop and its mirror",{{clips={0=1}},{clips={0=2+loops},turned=true},{clips={0=2+loops},mirror=true,turned=true}},4,{"clip_2"},false},
        {"a blend by its first clip",{{clips={0=3,1=4},weights={0=.5,1=.5},turned=true},{clips={0=3,1=4},weights={0=.2,1=.8},turned=true},{clips={0=5},turned=true}},4,{"clip_3","clip_5"},false},
        {"more than fit",{{clips={0=2},turned=true},{clips={0=2+loops},turned=true},{clips={0=6},turned=true}},1,{"clip_2"},true},
    }
    for c in cases {
        db:=lib.Match_Database{ranges=c.ranges}
        out:[4][asset.ANIMATION_NAME_CAPACITY]u8
        count,more:=match_turned_clips(&db,&f.content,out[:c.fits])
        if !testing.expectf(t,count==len(c.names) && more==c.more,"%s: %d names (more %v)",c.name,count,more) {continue}
        for name,i in c.names {testing.expectf(t,base.text_get(out[i][:])==name,"%s: %s, not %s",c.name,base.text_get(out[i][:]),name)}
    }
    count,more:=match_turned_clips(nil,&f.content,nil)
    testing.expect(t,count==0 && !more)
}
