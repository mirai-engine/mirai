package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"

@(test)
mirai_matching_selects_a_walking_clip :: proc(t:^testing.T) {
    problems:core.Problems
    f:Animation_Input_Fixture;defer animation_input_fixture_destroy(&f)
    gallery:core.Table(Animation_Gallery);defer core.table_destroy(&gallery)
    graphs:anim.Character_Assets;defer anim.character_assets_free(&graphs)
    progress:core.Table(anim.Animation_Progress);defer core.table_destroy(&progress)
    core.entities_init(&f.entities)
    root,found:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !testing.expect(t,found && host.assets_init(&f.assets,{root=fmt.tprintf("%s/demo/assets",root),imported=fmt.tprintf("%s/demo/.mirai/imported",root),capacity=512})) {return}
    f.app={assets=&f.assets,allocator=context.allocator}
    ids:[2]base.Asset_Id
    for file,i in ([2]string{"characters/mirai/mirai_matching.character","models/mirai/mirai.glb/output_unwrapped.mesh"}) {
        record,present:=asset.registry_find_path(&f.assets.registry,file)
        if !testing.expectf(t,present,"the demo has %s",file) {return}
        ids[i]=record.id
    }
    actor:=core.create(&f.entities)
    core.add(&f.transforms,actor,core.TRANSFORM_IDENTITY);core.add(&f.worlds,actor,{rotation=1,scale={1,1,1}})
    core.add(&f.meshes,actor,render.Mesh_Renderer{mesh=ids[1]})
    animation:=anim.ANIMATION_DEFAULT;animation.asset=ids[0];core.add(&f.animations,actor,animation)
    core.add(&gallery,actor,{kind=.Matching,manual=true})
    core.table_settle(&f.transforms,&f.entities);core.table_settle(&f.worlds,&f.entities);core.table_settle(&f.meshes,&f.entities);core.table_settle(&f.animations,&f.entities);core.table_settle(&gallery,&f.entities)
    core.hierarchy_settle(&f.hierarchy,core.read(&f.parents),&f.entities)
    time:=core.Time{dt=1.0/60,playing=true}
    tick :: proc(f:^Animation_Input_Fixture,gallery:^core.Table(Animation_Gallery),graphs:^anim.Character_Assets,progress:^core.Table(anim.Animation_Progress),problems:^core.Problems,time:core.Time,mode:=locomotion.MODE_WALKING) -> (anim.Animation_Match,bool) {
        entity:=core.entity_at(gallery,0)
        speed:=core.at(gallery,0).speed
        anim.match_goal(&f.requests,{rig=entity,mode=u16(mode),velocity={0,0,-speed},desired={0,0,-speed},facing={0,0,-1},acceleration=20,braking=20})
        anim.animation_sample(core.read(&f.animations),progress,&f.played,core.read(&f.attachments),&f.transforms,core.read(&f.parents),core.ref(&f.hierarchy),core.read(&f.names),core.read(&f.targets),core.read(&f.meshes),core.read(&f.sources),core.read(&f.remotes),&f.requests,&f.events,&f.modifiers,&f.playback,graphs,&f.skeletons,&f.app,time,{},problems,&f.actions,&f.motion,&f.content_sources,{},core.CLOCK_DEFAULT,anim.ANIMATION_BUDGET_CONFIG_DEFAULT)
        return anim.animation_match(&f.playback,core.entity_at(gallery,0))
    }
    // The rig binds its skeleton in its first ticks; then its database says how fast each clip walks.
    for _ in 0..<4 {tick(&f,&gallery,&graphs,&progress,&problems,time)}
    problems={}
    walk:=f32(0)
    for &content in graphs.contents {for &built in content.databases {if built.error==.None {
        for range,i in built.database.ranges {
            if base.text_get(content.set.match.clips[i].clip[:])=="walk" {walk=range.speed}
        }
    }}}
    testing.expectf(t,walk>2 && walk<3,"inferred walk speed %.3f m/s",walk)
    for wanted in ([6]struct{speed:f32,clip:string}{{0,"idle"},{.3,"walk"},{1,"walk"},{walk,"walk"},{MIRAI_WALK_SPEED,"walk"},{0,"idle"}}) {
        core.edit(&gallery,actor).speed=wanted.speed
        playing:anim.Animation_Match
        for _ in 0..<90 {playing,_=tick(&f,&gallery,&graphs,&progress,&problems,time)}
        testing.expectf(t,playing.clip==base.name_hash(wanted.clip),"at %.2f m/s plays %s",wanted.speed,wanted.clip)
        if wanted.speed>0 {
            testing.expectf(t,abs(playing.speed-wanted.speed)<.05,"at %.2f m/s the animation covers %.2f m/s",wanted.speed,playing.speed)
            before:=playing
            for _ in 0..<30 {playing,_=tick(&f,&gallery,&graphs,&progress,&problems,time)}
            testing.expectf(t,playing.jumps==before.jumps,"at %.2f m/s the walk was restarted",wanted.speed)
            testing.expectf(t,abs(playing.time-before.time)>.025,"at %.2f m/s the walk does not advance (%.2f -> %.2f)",wanted.speed,before.time,playing.time)
        }
    }
    // Starting and stopping are searched in that tick, not after the interval of the search: the
    // walk does not hold its legs still while the body stands, nor the idle while it walks.
    for wanted in ([4]struct{speed:f32,clip:string}{{1,"walk"},{0,"idle"},{1,"walk"},{0,"idle"}}) {
        core.edit(&gallery,actor).speed=wanted.speed
        playing:anim.Animation_Match
        for _ in 0..<2 {playing,_=tick(&f,&gallery,&graphs,&progress,&problems,time)}
        testing.expectf(t,playing.clip==base.name_hash(wanted.clip),"a tick after asking %.0f m/s it plays %s",wanted.speed,wanted.clip)
        for _ in 0..<40 {tick(&f,&gallery,&graphs,&progress,&problems,time)}
    }
    core.edit(&gallery,actor).speed=1
    falling:anim.Animation_Match
    for _ in 0..<120 {falling,_=tick(&f,&gallery,&graphs,&progress,&problems,time,locomotion.MODE_FALLING)}
    testing.expectf(t,falling.clip==base.name_hash("fall"),"while falling with horizontal speed, the fall loop plays")
    testing.expect_value(t,problems.count,0)
}

// Mirai stands, then walks off to its side while its body turns toward where it goes: the legs
// warp toward the velocity from the first tick, and no bone turns faster than twice the fastest
// turn of a bone of the walk that follows. The travel of the idle and a warp that jumps to its angle
// made the legs swing round in one tick.
@(test)
mirai_starting_to_its_side_turns_no_bone_faster_than_its_walk :: proc(t:^testing.T) {
    problems:core.Problems
    f:Animation_Input_Fixture;defer animation_input_fixture_destroy(&f)
    graphs:anim.Character_Assets;defer anim.character_assets_free(&graphs)
    progress:core.Table(anim.Animation_Progress);defer core.table_destroy(&progress)
    constraints:anim.Animation_Constraints;grounding:anim.Grounding_Runtime
    core.entities_init(&f.entities)
    root,found:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !testing.expect(t,found && host.assets_init(&f.assets,{root=fmt.tprintf("%s/demo/assets",root),imported=fmt.tprintf("%s/demo/.mirai/imported",root),capacity=512})) {return}
    f.app={assets=&f.assets,allocator=context.allocator}
    ids:[2]base.Asset_Id
    for file,i in ([2]string{"characters/mirai/mirai_matching.character","models/mirai/mirai.glb/output_unwrapped.mesh"}) {
        record,present:=asset.registry_find_path(&f.assets.registry,file)
        if !testing.expectf(t,present,"the demo has %s",file) {return}
        ids[i]=record.id
    }
    actor:=core.create(&f.entities)
    core.add(&f.transforms,actor,core.TRANSFORM_IDENTITY);core.add(&f.worlds,actor,{rotation=1,scale={1,1,1}})
    core.add(&f.meshes,actor,render.Mesh_Renderer{mesh=ids[1]})
    animation:=anim.ANIMATION_DEFAULT;animation.asset=ids[0];core.add(&f.animations,actor,animation)
    core.table_settle(&f.transforms,&f.entities);core.table_settle(&f.worlds,&f.entities);core.table_settle(&f.meshes,&f.entities);core.table_settle(&f.animations,&f.entities)
    core.hierarchy_settle(&f.hierarchy,core.read(&f.parents),&f.entities)
    DT :: f32(1.0/60)
    time:=core.Time{dt=DT,playing=true}
    previous:[dynamic]mm.Transform;defer delete(previous)
    // A tick of the body, as the physics and animation_locomotion give it: its velocity goes to
    // wish at 20 m/s2 and its facing turns toward it at the turn speed of a Character. The fastest
    // turn of a bone of the pose in the tick, rad/s.
    velocity:mm.Vec3
    tick :: proc(f:^Animation_Input_Fixture,graphs:^anim.Character_Assets,progress:^core.Table(anim.Animation_Progress),constraints:^anim.Animation_Constraints,grounding:^anim.Grounding_Runtime,problems:^core.Problems,time:core.Time,actor:core.Entity,velocity:^mm.Vec3,wish:mm.Vec3,previous:^[dynamic]mm.Transform) -> (fastest:f32) {
        step:=wish-velocity^
        if length:=linalg.length(step);length>20*time.dt {step*=20*time.dt/length}
        velocity^+=step
        place:=core.edit(&f.transforms,actor)
        if linalg.length(velocity^)>.01 {
            facing:=mm.quat_forward(place.rotation)
            turn:=math.atan2(linalg.cross(facing,velocity^).y,linalg.dot(facing,velocity^))
            place.rotation=mm.quat_axis_angle({0,1,0},clamp(turn,-.145,.145))*place.rotation
        }
        rotation:=place.rotation
        playing,matching:=anim.animation_match(&f.playback,actor)
        anim.match_goal(&f.requests,{rig=actor,mode=u16(locomotion.MODE_WALKING),velocity=velocity^,desired=wish,facing=linalg.normalize0(wish) if wish!={} else mm.quat_forward(rotation),acceleration=20,braking=20,turn_rate=8.7})
        along:=playing.travel if playing.travel!={} else mm.FORWARD
        anim.motion_locomotion(&f.requests,{rig=actor,velocity={playing.velocity.x,0,playing.velocity.z},source_velocity=mm.quat_rotate(rotation,along*playing.speed),weight=1,enabled=matching && !playing.forced && playing.speed>0})
        anim.animation_sample(core.read(&f.animations),progress,&f.played,core.read(&f.attachments),&f.transforms,core.read(&f.parents),core.ref(&f.hierarchy),core.read(&f.names),core.read(&f.targets),core.read(&f.meshes),core.read(&f.sources),core.read(&f.remotes),&f.requests,&f.events,&f.modifiers,&f.playback,graphs,&f.skeletons,&f.app,time,{},problems,&f.actions,&f.motion,&f.content_sources,{},core.CLOCK_DEFAULT,anim.ANIMATION_BUDGET_CONFIG_DEFAULT)
        anim.animation_advance(&f.transforms,core.read(&f.parents),core.read(&f.worlds),&f.requests,&f.modifiers,&f.playback,constraints,grounding,{},{},time,core.ref(&f.skeletons),problems,&f.motion,graphs,{},{},core.CLOCK_DEFAULT,nil)
        pose,posed:=anim.pose_space(&f.playback,actor,context.temp_allocator)
        if !posed {return}
        if len(previous)==len(pose) {for bone,i in pose {fastest=max(fastest,mm.quat_angle(previous[i].rotation,bone.rotation)/time.dt)}}
        resize(previous,len(pose));copy(previous[:],pose)
        return
    }
    for _ in 0..<90 {tick(&f,&graphs,&progress,&constraints,&grounding,&problems,time,actor,&velocity,{},&previous)}
    wish:=mm.Vec3{-MIRAI_WALK_SPEED,0,0}
    start,walk:f32
    for i in 0..<120 {
        fastest:=tick(&f,&graphs,&progress,&constraints,&grounding,&problems,time,actor,&velocity,wish,&previous)
        if i<40 {start=max(start,fastest)} else if i>=60 {walk=max(walk,fastest)}
    }
    playing,_:=anim.animation_match(&f.playback,actor)
    testing.expectf(t,playing.clip==base.name_hash("walk") && walk>1,"it walks (%.2f rad/s)",walk)
    testing.expectf(t,start<=2*walk,"starting to its side no bone turns faster than twice its walk: %.2f against %.2f rad/s",start,walk)
    testing.expect_value(t,problems.count,0)
}
