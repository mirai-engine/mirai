package editor

import "core:strings"
import "core:testing"
import "mirai:core"

Card_Test_Provider :: struct {provider:Card_Provider}
Card_Test_Component :: struct {value:f32}

card_test_provider_v1 :: proc(dst:rawptr) {
    out:=(^Card_Test_Provider)(dst)
    out^={}
    out.provider.count=2
    out.provider.cards[0]={label="Test gate",group="Logic",icon=.Grid,lift=1.5,scale={2,3,1},component=Card_Test_Component}
    out.provider.cards[1]={label="Test mark",group="Tests",icon=.Check}
}
card_test_provider_v2 :: proc(dst:rawptr) {
    out:=(^Card_Test_Provider)(dst)
    out^={}
    out.provider.count=1
    out.provider.cards[0]={label="Other",icon=.Edit}
}

@(private="file")
Card_Test_World :: struct {using world:core.Test_World,components:core.Table(Card_Test_Component)}

@(private="file")
Card_Test_Editor :: struct {provider:Card_Test_Provider}

@(private="file")
card_test_types :: proc(types:^[dynamic]core.Test_Type) {
    append(types,core.test_type(Card_Test_Provider,default=proc(dst:^Card_Test_Provider) {card_test_provider_v1(dst)}))
}

@(test)
the_cards_of_plugins_follow_the_presets_and_are_those_of_the_library_in_use :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Card_Test_World,core.Test_None,Card_Test_Editor,card_test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    provider:=&info.storages[info.storages_by_type[Card_Test_Provider]]
    component:=&info.tables[info.tables_by_type[Card_Test_Component]]
    session:=Session{info=&info}
    all:=cards(&session)
    presets:=PRESETS
    testing.expect_value(t,len(all),len(Preset)+2)
    for preset in Preset {
        testing.expect_value(t,all[int(preset)].label,presets[preset].label)
        testing.expect_value(t,all[int(preset)].body,preset_shape(preset))
    }
    gate:=all[len(Preset)]
    testing.expect(t,gate.label=="Test gate" && gate.group=="Logic" && gate.lift==1.5 && gate.scale==[3]f32{2,3,1})
    testing.expect(t,session.card_tables[len(Preset)]==component && session.card_tables[len(Preset)+1]==nil)
    card,found:=card_of_table(&session,component)
    testing.expect(t,found && card.label=="Test gate")

    // A name of the API is a preset in snake case or the label of a card, whatever its case.
    index,named:=card_named(&session,"point_light")
    testing.expect(t,named && index==int(Preset.Point_Light))
    index,named=card_named(&session,"test_gate")
    testing.expect(t,named && index==len(Preset))
    index,named=card_named(&session,"Test Mark")
    testing.expect(t,named && index==len(Preset)+1)
    index,named=card_named(&session,"PointLight")
    testing.expect(t,named && index==int(Preset.Point_Light))
    index,named=card_named(&session,"test-gate")
    testing.expect(t,named && index==len(Preset))
    testing.expect(t,strings.has_prefix(cards_problem(&session,"pointlite"),`"pointlite" is not a preset or the card of a plugin; the nearest are point_light`),cards_problem(&session,"pointlite"))
    _,named=card_named(&session,"test")
    testing.expect(t,!named)

    // Another library has other cards.
    provider.default=card_test_provider_v2
    testing.expect_value(t,len(cards(&session)),len(Preset)+2)
    session.library_generation+=1
    all=cards(&session)
    testing.expect_value(t,len(all),len(Preset)+1)
    testing.expect_value(t,all[len(Preset)].label,"Other")
    _,named=card_named(&session,"test_gate")
    testing.expect(t,!named)
    provider.place=.World
    session.library_generation+=1
    testing.expect_value(t,len(cards(&session)),len(Preset))
}
