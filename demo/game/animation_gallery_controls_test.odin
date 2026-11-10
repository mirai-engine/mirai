package game

import "core:mem"
import "core:testing"
import "mirai:core"
import gui "mirai:engine/gui"
import "mirai:std/base"
import anim "plugins:animation/runtime"

@(test)
gallery_manual_controls_survive_the_automatic_demo_and_keep_other_stations_running :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    gallery:core.Table(Animation_Gallery);defer core.table_destroy(&gallery)
    animations:core.Table(anim.Animation);defer core.table_destroy(&animations)
    first,second:=core.create(&entities),core.create(&entities)
    for entity in ([2]core.Entity{first,second}) {
        core.add(&gallery,entity,{kind=.Direct,age=3.5})
        value:=anim.ANIMATION_DEFAULT;base.text_set(value.clip[:],"walk")
        core.add(&animations,entity,value)
    }
    core.table_settle(&gallery,&entities);core.table_settle(&animations,&entities)
    requests:anim.Animation_Requests
    defer {delete(requests.timeline.items);delete(requests.plays.items)}
    modifiers:anim.Modifier_Requests
    defer delete(modifiers.controls.items)
    panel:Gallery_UI
    testing.expect(t,gallery_request(&panel,.Playing,first,enabled=false))
    testing.expect(t,gallery_request(&panel,.Action,first,name="Greet"))
    testing.expect(t,gallery_request(&panel,.Modifier,first,value=.25,modifier=.Look))
    commands:=panel.commands[:panel.count]
    gallery_playback_commands(commands,&animations,&requests,&modifiers)
    gallery_direct_clips(&gallery,&animations,&requests,commands)
    first_value,_:=core.get(&animations,first)
    second_value,_:=core.get(&animations,second)
    testing.expect(t,!first_value.playing && base.text_get(first_value.clip[:])=="walk")
    testing.expect(t,len(requests.plays.items)==1 && requests.plays.items[0].entity==first && !requests.plays.items[0].stop && base.text_get(requests.plays.items[0].action[:])=="Greet")
    testing.expect(t,second_value.playing && base.text_get(second_value.clip[:])=="wave")
    testing.expect(t,len(modifiers.controls.items)==1 && modifiers.controls.items[0].kind==.Look && modifiers.controls.items[0].weight==.25)
    core.edit(&gallery,first).manual=gallery_manual(false,first,commands)
    panel.count=0
    gallery_direct_clips(&gallery,&animations,&requests,nil)
    first_value,_=core.get(&animations,first)
    testing.expect(t,!first_value.playing && base.text_get(first_value.clip[:])=="walk")
    testing.expect(t,gallery_request(&panel,.Automatic,first,enabled=true))
    gallery_playback_commands(panel.commands[:panel.count],&animations,&requests,&modifiers)
    gallery_direct_clips(&gallery,&animations,&requests,panel.commands[:panel.count])
    first_value,_=core.get(&animations,first)
    testing.expect(t,first_value.playing && base.text_get(first_value.clip[:])=="wave" && !gallery_manual(true,first,panel.commands[:panel.count]))
}

// A slider of a station's panel asks its row's command with the value between the row's limits,
// and a button its command; an event of another entity or past the rows asks nothing.
@(test)
gallery_panel_events_become_the_commands_of_their_station :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    gallery:core.Table(Animation_Gallery);defer core.table_destroy(&gallery)
    panels:core.Table(Gallery_Panel);defer core.table_destroy(&panels)
    station,panel_entity,other:=core.create(&entities),core.create(&entities),core.create(&entities)
    core.add(&gallery,station,{kind=.Matching})
    core.add(&panels,panel_entity,{station=station})
    core.table_settle(&gallery,&entities);core.table_settle(&panels,&entities)
    events:gui.UI_Events;defer delete(events.items)
    append(&events.items,
        gui.UI_Event{entity=panel_entity,name=base.name_hash("value"),kind=.Changed,item=0,value=.5},
        gui.UI_Event{entity=panel_entity,name=base.name_hash("button"),kind=.Clicked,item=0},
        gui.UI_Event{entity=panel_entity,name=base.name_hash("value"),kind=.Changed,item=3,value=1},
        gui.UI_Event{entity=other,name=base.name_hash("button"),kind=.Clicked,item=0},
    )
    panel:Gallery_UI
    gallery_panel_input(core.read(&panels),core.read(&gallery),{&events},{},&panel)
    if !testing.expect_value(t,int(panel.count),2) {return}
    testing.expect(t,panel.commands[0].kind==.Speed && panel.commands[0].entity==station && panel.commands[0].value==GALLERY_MATCH_SPEED*.5)
    testing.expect(t,panel.commands[1].kind==.Action && base.text_get(panel.commands[1].name[:])=="Wave")
    testing.expect(t,gallery_manual(false,station,panel.commands[:panel.count]))
}

@(test)
gallery_ui_commands_are_bounded_copied_and_do_not_allocate :: proc(t:^testing.T) {
    panel:Gallery_UI
    testing.expect(t,gallery_request(&panel,.Value,core.Entity(1),value=1.2))
    snapshot:=panel
    original:=context.allocator;context.allocator=mem.nil_allocator()
    for i in 1..<len(panel.commands) {testing.expect(t,gallery_request(&panel,.Value,core.Entity(i+1),value=.5))}
    testing.expect(t,!gallery_request(&panel,.Value,core.Entity(99),value=.5))
    testing.expect_value(t,int(panel.count),len(panel.commands))
    testing.expect_value(t,int(snapshot.count),1)
    testing.expect_value(t,snapshot.commands[0].value,f32(1.2))
    context.allocator=original
}
