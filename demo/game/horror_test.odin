package game

import "core:testing"
import "mirai:core"
import inp "mirai:engine/input"
import render "mirai:engine/render"

@(test)
steady_lamps_write_no_row_of_their_lights :: proc(t:^testing.T) {
    LAMPS :: 8
    TICKS :: 60
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    lamps:core.Table(House_Lamp);switches:core.Table(Light_Switch);points:core.Table(render.Point_Light)
    flashlights:core.Table(Flashlight);spots:core.Table(render.Spot_Light);transforms:core.Table(core.Transform)
    players:core.Table(Player);moves:core.Table(inp.Move_Input);worlds:core.Table(core.World_Transform)
    defer {
        core.table_destroy(&lamps);core.table_destroy(&switches);core.table_destroy(&points);core.table_destroy(&flashlights);core.table_destroy(&spots)
        core.table_destroy(&transforms);core.table_destroy(&players);core.table_destroy(&moves);core.table_destroy(&worlds)
    }
    wall:=core.create(&es)
    core.add(&switches,wall,LIGHT_SWITCH_DEFAULT)
    for _ in 0..<LAMPS {
        e:=core.create(&es)
        core.add(&lamps,e,House_Lamp{light_switch=wall,intensity=800})
        core.add(&points,e,render.POINT_LIGHT_DEFAULT)
    }
    core.table_settle(&switches,&es);core.table_settle(&lamps,&es);core.table_settle(&points,&es)
    tick :: proc(lamps:^core.Table(House_Lamp),switches:^core.Table(Light_Switch),points:^core.Table(render.Point_Light),flashlights:^core.Table(Flashlight),spots:^core.Table(render.Spot_Light),transforms:^core.Table(core.Transform),players:^core.Table(Player),moves:^core.Table(inp.Move_Input),worlds:^core.Table(core.World_Transform),es:^core.Entities,seconds:f64) -> (stamped:int) {
        before:=[2]u64{lamps.version,points.version}
        horror_lights(lamps,core.read(switches),points,core.read(flashlights),spots,transforms,core.read(players),core.read(moves),{},{seconds=seconds})
        // As the loop does after the function: a row asked for and left as it was keeps its stamp.
        core.table_settle(lamps,es);core.table_settle(points,es)
        for stamp in lamps.stamps {if stamp>before[0] {stamped+=1}}
        for stamp in points.stamps {if stamp>before[1] {stamped+=1}}
        return
    }
    tick(&lamps,&switches,&points,&flashlights,&spots,&transforms,&players,&moves,&worlds,&es,0)
    stamped:=0
    for i in 1..=TICKS {stamped+=tick(&lamps,&switches,&points,&flashlights,&spots,&transforms,&players,&moves,&worlds,&es,f64(i)/60)}
    testing.expectf(t,stamped==0,"%d rows stamped in %d ticks of %d steady lamps",stamped,TICKS,LAMPS)
}
