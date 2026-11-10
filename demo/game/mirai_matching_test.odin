package game

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
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
    core.hierarchy_settle(&f.hierarchy,&f.parents,&f.entities)
    time:=core.Time{dt=1.0/60,playing=true}
    tick :: proc(f:^Animation_Input_Fixture,gallery:^core.Table(Animation_Gallery),graphs:^anim.Character_Assets,progress:^core.Table(anim.Animation_Progress),problems:^core.Problems,time:core.Time,mode:=locomotion.MODE_WALKING) -> (anim.Animation_Match,bool) {
        entity:=core.entity_at(gallery,0)
        speed:=core.at(gallery,0).speed
        anim.match_goal(&f.requests,{rig=entity,mode=u16(mode),velocity={0,0,-speed},desired={0,0,-speed},facing={0,0,-1},acceleration=20,braking=20})
        anim.animation_sample(core.read(&f.animations),progress,core.read(&f.attachments),&f.transforms,core.read(&f.parents),core.ref(&f.hierarchy),core.read(&f.names),core.read(&f.targets),core.read(&f.meshes),core.read(&f.sources),&f.requests,&f.events,&f.modifier_requests,&f.modifiers,&f.playback,graphs,&f.skeletons,&f.app,time,{},problems,nil,nil,nil,nil,{},core.CLOCK_DEFAULT,anim.ANIMATION_BUDGET_CONFIG_DEFAULT)
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
