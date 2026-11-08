package editor

import "core:reflect"
import "core:strings"
import "mirai:core"
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

// The names card_named takes, for what an error says it takes: the presets,
// then the cards of plugins, in the temporary allocator.
cards_named_text :: proc(s:^Session) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for name in reflect.enum_field_names(Preset) {append(&names,strings.to_lower(name,context.temp_allocator))}
    for card in cards(s)[len(Preset):] {append(&names,card.label)}
    return strings.join(names[:],", ",context.temp_allocator)
}

// The card a name of the API means: a preset of the editor by its name in
// snake case, or a card of a plugin by its label, without minding case and
// with spaces or underscores.
@(private)
card_named :: proc(s:^Session,name:string) -> (index:int,found:bool) {
    if preset,is_preset:=api_preset_find(name);is_preset {return int(preset),true}
    for card,at in cards(s)[len(Preset):] {
        if len(card.label)!=len(name) {continue}
        same:=true
        for i in 0..<len(name) {
            a,b:=card.label[i],name[i]
            if a>='A' && a<='Z' {a+=32}
            if b>='A' && b<='Z' {b+=32}
            if a==' ' {a='_'}
            if b==' ' {b='_'}
            if a!=b {same=false;break}
        }
        if same {return len(Preset)+at,true}
    }
    return
}
