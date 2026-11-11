package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:cook/author"
import "mirai:core"

Card_Test_Provider :: struct {provider:Card_Provider}
Card_Test_Component :: struct {value:f32}

card_test_provider_v1 :: proc(dst:rawptr) {
    out:=(^Card_Test_Provider)(dst)
    out^={}
    out.provider.count=3
    out.provider.cards[0]={recipe="cube",group="Logic",icon=.Grid,component=Card_Test_Component}
    out.provider.cards[1]={recipe="no_such_recipe",icon=.Edit}
    out.provider.cards[2]={recipe="sphere",group="Tests",icon=.Check}
}
card_test_provider_v2 :: proc(dst:rawptr) {
    out:=(^Card_Test_Provider)(dst)
    out^={}
    out.provider.count=1
    out.provider.cards[0]={recipe="cone",icon=.Edit}
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
cards_place_the_recipes_of_the_engine_and_those_of_the_library_in_use :: proc(t:^testing.T) {
    engine,found:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !testing.expect(t,found,"MIRAI_ROOT names the engine whose recipes the cards place: mirai test sets it") {return}
    info,described:=core.test_info(t,Card_Test_World,core.Test_None,Card_Test_Editor,card_test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    provider:=&info.storages[info.storages_by_type[Card_Test_Provider]]
    component:=&info.tables[info.tables_by_type[Card_Test_Component]]
    session:=Session{info=&info,engine_root=engine}
    defer author.recipes_free(session.recipes)
    all:=cards(&session)
    editor:=EDITOR_CARDS
    if !testing.expect_value(t,len(all),len(editor)+2) {return}
    for card,i in editor {
        testing.expect_value(t,all[i].recipe,card.recipe)
        recipe,known:=recipe_of(&session,card.recipe)
        testing.expect(t,known && all[i].label==recipe.label && all[i].label!="",card.recipe)
    }
    testing.expect_value(t,all[1].label,"Point light")
    // A card whose recipe is not there is left out.
    box,mark:=all[len(editor)],all[len(editor)+1]
    testing.expect(t,box.label=="Cube" && box.group=="Logic" && mark.recipe=="sphere")
    testing.expect(t,session.card_tables[len(editor)]==component && session.card_tables[len(editor)+1]==nil)
    card,of_table:=card_of_table(&session,component)
    testing.expect(t,of_table && card.recipe=="cube")

    // A name of the API is the name of the file of a recipe, whatever its case and separators.
    for name in ([]string{"point_light","PointLight","point-light","Capsule"}) {
        _,named:=recipe_of(&session,name)
        testing.expect(t,named,name)
    }
    testing.expect(t,strings.has_prefix(recipes_problem(&session,"pointlite"),`"pointlite" is not a recipe; the nearest are point_light`),recipes_problem(&session,"pointlite"))
    _,named:=recipe_of(&session,"point")
    testing.expect(t,!named)

    // Another library has other cards.
    provider.default=card_test_provider_v2
    testing.expect_value(t,len(cards(&session)),len(editor)+2)
    session.library_generation+=1
    all=cards(&session)
    testing.expect(t,len(all)==len(editor)+1 && all[len(editor)].label=="Cone")
    provider.place=.World
    session.library_generation+=1
    testing.expect_value(t,len(cards(&session)),len(editor))
}
