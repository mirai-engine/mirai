package editor

import "core:reflect"
import "core:strings"
import "mirai:core"
import "mirai:std/base"
import erender "mirai:engine/render"
import "mirai:ui"

// What Create shows and makes: a recipe of components, not a kind. The editor
// has its presets and a plugin adds its own from its editor package, with a
// storage whose sole field is a Card_Provider and a default procedure, as the
// providers of the inspector and of the API.

CARD_CAPACITY :: 64
CARD_PROVIDER_CAPACITY :: 8
CARD_GROUP_CAPACITY :: 8

Card :: struct {
    label:string,
    group:string,            // the section of Create that lists it: "Logic", "Shapes" or one of its own
    icon:ui.Icon,            // one of ui; None: its drawing
    drawing:ui.Icon_Drawing,
    color:ui.Color,
    lift:f32,                // m above what it is placed on, for what has no body
    body:erender.Shape,      // the primitive that shows where it will be placed; None: a mark
    scale:[3]f32,            // of the entity it makes; zero: one
    make:proc(s:^Session,w:core.World_Ref,e:core.Entity), // gives the entity its components
    component:typeid,        // an entity that has it is shown with the icon of the card
}

Card_Provider :: struct {
    cards:[CARD_PROVIDER_CAPACITY]Card,
    count:int,
}

// The cards of the editor, its presets first in their order, and after them
// those of the plugins of the library in use.
cards :: proc(s:^Session) -> []Card {
    if s.cards_library==s.library_generation+1 {return s.cards[:s.card_count]}
    s.cards_library=s.library_generation+1
    presets:=PRESETS
    s.card_count=0
    s.card_tables={}
    for preset in Preset {
        card:=presets[preset]
        s.cards[s.card_count]={label=card.label,icon=card.icon,color=card.color,lift=card.lift,body=preset_shape(preset)}
        s.card_count+=1
    }
    if s.info==nil {return s.cards[:s.card_count]}
    found:[PROVIDER_CAPACITY]Card_Provider
    for &provider in found[:provided_all(s,found[:])] {
        for card in provider.cards[:clamp(provider.count,0,len(provider.cards))] {
            if s.card_count>=len(s.cards) {break}
            added:=card
            if own:=s.card_count-len(Preset);added.icon==.None && added.drawing.count>0 && s.gui!=nil && s.gui.ctx!=nil && ui.icon_custom_set(s.gui.ctx,own,added.drawing) {
                added.icon=ui.icon_custom(own)
            }
            if added.component!=nil {
                for &table in s.info.tables {
                    if table.type==added.component && table.place==.World {s.card_tables[s.card_count]=&table;break}
                }
            }
            s.cards[s.card_count]=added
            s.card_count+=1
        }
    }
    return s.cards[:s.card_count]
}

// The card of a plugin an entity is shown as: that of a component it has.
@(private)
card_of_entity :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> (card:^Card,found:bool) {
    if w.place!=.World {return}
    for &candidate,index in cards(s)[len(Preset):] {
        table:=s.card_tables[len(Preset)+index]
        if table!=nil && core.raw_find(core.world_table_at(w,table),table.info,e)!=nil {return &candidate,true}
    }
    return
}

// The card of a plugin whose component a table holds.
@(private)
card_of_table :: proc(s:^Session,t:^core.Table_Info) -> (card:^Card,found:bool) {
    for &candidate in cards(s)[len(Preset):] {
        if candidate.component==t.type {return &candidate,true}
    }
    return
}

// The labels of the cards of plugins, in the temporary allocator.
@(private)
cards_plugin_names :: proc(s:^Session) -> []string {
    labels:=cards(s)[len(Preset):]
    names:=make([]string,len(labels),context.temp_allocator)
    for card,i in labels {names[i]=card.label}
    return names
}

// What is wrong with a name card_named does not take, with the nearest ones.
cards_problem :: proc(s:^Session,name:string) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for each in reflect.enum_field_names(Preset) {append(&names,strings.to_lower(each,context.temp_allocator))}
    append(&names,..cards_plugin_names(s))
    return base.name_problem(name,"a preset or the card of a plugin",names[:])
}

// The card a name of the API means, as base.name_find takes it: a preset of
// the editor, or a card of a plugin by its label.
@(private)
card_named :: proc(s:^Session,name:string) -> (index:int,found:bool) {
    if preset,_:=base.name_find(name,reflect.enum_field_names(Preset));preset>=0 {return preset,true}
    at,_:=base.name_find(name,cards_plugin_names(s))
    return len(Preset)+at,at>=0
}
