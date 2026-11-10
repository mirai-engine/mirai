package game

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import gui "mirai:engine/gui"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import anim "plugins:animation/runtime"

// The matching station of the gallery with Mirai (mirai_gallery.match): the
// speed the game asks picks idle, walk or jog, at a rate that follows it.
@(test)
gallery_mirai_matching_plays_idle_walk_and_jog_by_the_speed_it_is_asked :: proc(t:^testing.T) {
    problems:core.Problems
    f:Animation_Input_Fixture;defer animation_input_fixture_destroy(&f)
    gallery:core.Table(Animation_Gallery);defer core.table_destroy(&gallery)
    graphs:anim.Character_Assets;defer anim.character_assets_free(&graphs)
    progress:core.Table(anim.Animation_Progress);defer core.table_destroy(&progress)
    panel:Gallery_UI
    core.entities_init(&f.entities)
    root,found:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !testing.expect(t,found && host.assets_init(&f.assets,{root=fmt.tprintf("%s/demo/assets",root),imported=fmt.tprintf("%s/demo/.mirai/imported",root),capacity=512})) {return}
    f.app={assets=&f.assets,allocator=context.allocator}
    ids:[2]base.Asset_Id
    for file,i in ([2]string{"characters/mirai/mirai_gallery.character","models/mirai/mirai.glb/output_unwrapped.mesh"}) {
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
    tick :: proc(t:^testing.T,f:^Animation_Input_Fixture,gallery:^core.Table(Animation_Gallery),graphs:^anim.Character_Assets,progress:^core.Table(anim.Animation_Progress),panel:^Gallery_UI,problems:^core.Problems,time:core.Time) -> (anim.Animation_Match,bool) {
        ui_events:gui.UI_Events
        gallery_animate(core.read(gallery),&f.animations,core.read(&f.worlds),time,&f.requests,&f.modifier_requests,nil,{},nil,{&ui_events},core.read(&f.names),{panel},{},nil)
        anim.animation_sample(core.read(&f.animations),progress,core.read(&f.attachments),&f.transforms,core.read(&f.parents),core.ref(&f.hierarchy),core.read(&f.names),core.read(&f.targets),core.read(&f.meshes),core.read(&f.sources),&f.requests,&f.events,&f.modifier_requests,&f.modifiers,&f.playback,graphs,&f.skeletons,&f.app,time,{},problems,nil,nil,nil,nil,{},core.CLOCK_DEFAULT,anim.ANIMATION_BUDGET_CONFIG_DEFAULT)
        return anim.animation_match(&f.playback,core.entity_at(gallery,0))
    }
    // The rig binds its skeleton in its first ticks; then its database says how fast each clip walks.
    for _ in 0..<4 {tick(t,&f,&gallery,&graphs,&progress,&panel,&problems,time)}
    problems={}
    walk,jog:=f32(0),f32(0)
    for &content in graphs.contents {for &built in content.databases {if built.error==.None {
        for range,i in built.database.ranges {
            name:=base.text_get(content.set.match.clips[i].clip[:])
            if name=="walk" {walk=range.speed};if name=="jog" {jog=range.speed}
        }
    }}}
    testing.expectf(t,walk>.05 && jog>walk*1.2 && GALLERY_MATCH_SPEED>=jog*.9 && GALLERY_MATCH_SPEED<=jog*1.1,"walk %.3f m/s, jog %.3f m/s",walk,jog)
    for wanted in ([3]struct{speed:f32,clip:string}{{0,"idle"},{walk,"walk"},{jog,"jog"}}) {
        core.edit(&gallery,actor).speed=wanted.speed
        playing:anim.Animation_Match
        for _ in 0..<90 {playing,_=tick(t,&f,&gallery,&graphs,&progress,&panel,&problems,time)}
        testing.expectf(t,playing.clip==base.name_hash(wanted.clip),"at %.2f m/s Mirai plays %s",wanted.speed,wanted.clip)
        if wanted.speed>0 {testing.expectf(t,abs(playing.speed-wanted.speed)<.05,"at %.2f m/s the pose walks %.2f m/s",wanted.speed,playing.speed)}
    }
    testing.expect_value(t,problems.count,0)
}
