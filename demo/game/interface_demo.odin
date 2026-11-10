package game

import "core:math"
import "mirai:core"
import "mirai:engine/gui"
import render "mirai:engine/render"
import inp "mirai:engine/input"
import "mirai:std/base"

// The scene assets/interface/interface.scene: a HUD whose style H changes
// (variants of its styles), a menu M opens over it with the controls of a
// game's options, an inventory I opens with a grid of items to drag, and a
// conversation T starts. The four are .ui of assets/interface on entities
// of their own that bind this component of another entity. tools/demo_content
// writes them. What the items are and what the conversation says are rows of
// the tables of assets/interface, which the editor and the API edit.

INTERFACE_ITEMS :: 12
INTERFACE_DEMO :: "Interface demo"         // the entity with Interface_Demo
INTERFACE_HUD :: "Interface HUD"
INTERFACE_MENU :: "Interface menu"
INTERFACE_INVENTORY :: "Interface inventory"
INTERFACE_DIALOGUE :: "Interface dialogue"
// The variants the HUD takes, by Interface_Demo.style.
INTERFACE_STYLES :: [3]string{"","minimal","neon"}
// The languages of the interfaces, by Interface_Demo.language: the options
// of the dropdown of the menu.
INTERFACE_LANGUAGES :: [2]gui.Language{.English,.Spanish}

INTERFACE_CHOICES :: 4
INTERFACE_FLAGS :: 16

Item_Rarity :: enum u8 {Common,Rare,Epic}

@(record,description="An item a slot of the inventory holds: its name, its icon, how rare it is and how many of it a slot holds.")
Item :: struct {
    title:core.Text,
    icon:base.Asset_Id `mirai:"kind=.tex"`,
    rarity:Item_Rarity,
    stack:i32 `mirai:"min=1"`, // units a slot holds at most
}
ITEM_DEFAULT :: Item{stack=1}

@(record,description="A line of a conversation: who says it and what. The player answers with the Dialogue_Choice rows that name it; without them it goes on to next, and without next the conversation ends.")
Dialogue_Line :: struct {
    speaker,text:core.Text,
    next:core.Record(Dialogue_Line),
}

@(record,description="An answer to a line: offered while the flag requires is set and refuses is not, it sets the flag sets and goes to the line to; without to, the conversation ends.")
Dialogue_Choice :: struct {
    line:core.Record(Dialogue_Line),
    text:core.Text,
    to:core.Record(Dialogue_Line),
    requires,refuses,sets:[16]u8 `mirai:"text"`, // flags by name; empty: none
}

Interface_Item :: struct {
    item:core.Record(Item), // none: an empty slot
    count:i32,
    // What the interface shows of its row, in the language chosen.
    name:[24]u8 `mirai:"text,transient,readonly"`,
    icon:base.Asset_Id `mirai:"transient,hidden"`,
    rarity:[16]u8 `mirai:"text,transient,hidden"`, // the variant of its slot
}

// An answer the dialogue offers: its row and its text.
Interface_Choice :: struct {
    choice:core.Record(Dialogue_Choice),
    text:[64]u8 `mirai:"text"`,
}

// What the interfaces of the scene show and edit.
@(component)
Interface_Demo :: struct {
    player:[24]u8 `mirai:"text"`,
    health,most:f32,
    life:f32 `mirai:"min=0,max=1"`,  // health of most
    coins:i32,
    seconds:f32,                     // played
    cooldown:f32 `mirai:"min=0,max=1"`, // of the ability the HUD shows as a ring
    style:i32,                       // of INTERFACE_STYLES
    quality:i32,
    subtitles:bool,
    language:i32,                    // of INTERFACE_LANGUAGES
    items:[INTERFACE_ITEMS]Interface_Item,
    item_count:i32,
    equipped:Interface_Item,
    talk:core.Record(Dialogue_Line), // the line the conversation T starts begins with
    // The conversation: the line it is at (none: over), the flags its answers
    // set, and what the dialogue shows of it.
    line:core.Record(Dialogue_Line) `mirai:"transient"`,
    flags:[INTERFACE_FLAGS]u64 `mirai:"transient,hidden"`, // name_hash of each
    speaker:[32]u8 `mirai:"text,transient,readonly"`,
    said:[256]u8 `mirai:"text,transient,readonly"`,
    choices:[INTERFACE_CHOICES]Interface_Choice `mirai:"transient,readonly"`,
    choice_count:i32 `mirai:"transient,readonly"`,
    goes_on:bool `mirai:"transient,hidden"`, // a line without answers: the dialogue shows Continue
    // The generations of the tables and of the texts and the language the
    // texts shown are of: they are made again when one changes.
    shown:[5]u64 `mirai:"transient,hidden"`,
}

// What the interfaces asked for, the actions that open them and the time
// that goes by.
@(step="fixed",stage="react")
interface_demo :: proc(
    demos:^core.Table(Interface_Demo),screens:^core.Table(gui.UI_Screen),hidden:core.Read(render.Hidden),shows:^Show_Requests,
    names:core.Read(core.Name),ui_events:core.Ref(gui.UI_Events),actions:inp.Input_Of(Action),time:core.Time,
    ui_settings:core.Ref(gui.UI_Settings),preferences:^gui.UI_Preferences,
    items:core.Records(Item),lines:core.Records(Dialogue_Line),answers:core.Records(Dialogue_Choice),texts:^core.Texts,problems:^core.Problems,
) {
    holder,found:=core.sole(demos)
    if !found {return}
    events:=ui_events.ptr
    demo:=core.get(demos,holder)
    hud,menu,inventory:=core.entity_named(names,INTERFACE_HUD),core.entity_named(names,INTERFACE_MENU),core.entity_named(names,INTERFACE_INVENTORY)
    dialogue:=core.entity_named(names,INTERFACE_DIALOGUE)
    dt:=f32(time.dt)
    demo.seconds+=dt
    demo.health=demo.most*(0.55+0.4*math.sin(demo.seconds*0.6))
    demo.life=demo.health/demo.most if demo.most>0 else 0
    demo.cooldown=math.mod(demo.seconds,4)/4
    if math.mod(demo.seconds,2)<dt {demo.coins+=1}

    // A screen shows while it has no Hidden.
    styles:=INTERFACE_STYLES
    if inp.pressed(actions,.Hud_Style) {demo.style=(demo.style+1)%%i32(len(styles))}
    menu_was:=!core.has(hidden,menu)
    if inp.pressed(actions,.Interface_Menu) {ask_hidden(shows,menu,menu_was)}
    if inp.pressed(actions,.Inventory) {ask_hidden(shows,inventory,!core.has(hidden,inventory))}

    // The menu: what its controls wrote, and the buttons that close it.
    if value,ok:=gui.changed_value(events,menu,"quality");ok {demo.quality=i32(value)}
    languages:=INTERFACE_LANGUAGES
    if value,ok:=gui.changed_value(events,menu,"language");ok {preferences.language=languages[clamp(int(value),0,len(languages)-1)]}
    // The menu shows the options of the player, also those a run before saved.
    for language,i in languages {if language==preferences.language && demo.language!=i32(i) {demo.language=i32(i)}}
    for style in ([]string{"classic","minimal","neon"}) {
        if value,ok:=gui.changed_value(events,menu,style);ok {demo.style=i32(value)}
    }
    if on,ok:=gui.changed(events,menu,"subtitles");ok {demo.subtitles=on}
    if text,ok:=gui.submitted(events,menu,"name");ok {base.text_set(demo.player[:],text)}
    // Its buttons are the button of another .ui: their names are under their instances.
    if gui.clicked(events,menu,"resume/button") || gui.back(events,menu) {ask_hidden(shows,menu,true)}
    if gui.clicked(events,menu,"inventory/button") {ask_hidden(shows,menu,true);ask_hidden(shows,inventory,false)}
    if gui.back(events,inventory) || gui.clicked(events,inventory,"close") {ask_hidden(shows,inventory,true)}

    // The inventory: an item let go over a slot of the same item tops up its
    // stack, up to what its row lets a slot hold; over another slot it swaps
    // with it, and over the hand it is the one held.
    if drop,ok:=gui.dropped(events,inventory,"slot");ok && drop.from==base.name_hash("slot") {
        a,b:=int(drop.item),int(drop.from_item)
        if a>=0 && b>=0 && a<INTERFACE_ITEMS && b<INTERFACE_ITEMS && a!=b {
            to,from:=&demo.items[a],&demo.items[b]
            if to.item==from.item && to.item!={} {
                row,_:=core.record(items,to.item,problems,holder)
                moved:=clamp(max(row.stack,1)-to.count,0,from.count)
                to.count+=moved
                from.count-=moved
                if from.count==0 {from^={}}
            } else {
                to^,from^=from^,to^
            }
        }
    }
    if drop,ok:=gui.dropped(events,inventory,"hand");ok && drop.from==base.name_hash("slot") {
        if b:=int(drop.from_item);b>=0 && b<INTERFACE_ITEMS {demo.items[b],demo.equipped=demo.equipped,demo.items[b]}
    }

    // The conversation: T starts it, an answer clicked goes where it leads,
    // and Continue goes on from a line without answers.
    if inp.pressed(actions,.Talk) && demo.talk!={} && demo.line=={} {
        demo.line,demo.flags=demo.talk,{}
        demo.shown={}
        ask_hidden(shows,dialogue,false)
    }
    if demo.line!={} {
        at:=demo.line
        if item,ok:=gui.clicked_item(events,dialogue,"choice");ok && item>=0 && item<demo.choice_count {
            answer,_:=core.record(answers,demo.choices[item].choice,problems,holder)
            if flag:=base.text_get(answer.sets[:]);flag!="" {interface_flag_set(demo,base.name_hash(flag))}
            demo.line=answer.to
        }
        if gui.clicked(events,dialogue,"next") && demo.goes_on {
            line,_:=core.record(lines,demo.line,problems,holder)
            demo.line=line.next
        }
        if gui.back(events,dialogue) {demo.line={}}
        if demo.line!=at {demo.shown={}}
        if demo.line=={} {ask_hidden(shows,dialogue,true)}
    }

    // The HUD shows the style chosen.
    if screen:=core.get(screens,hud);screen!=nil {base.text_set(screen.variant[:],styles[clamp(int(demo.style),0,len(styles)-1)])}

    // The texts of the rows, made again when a table or the texts load again,
    // the language changes or the conversation moves.
    language:=gui.ui_language(ui_settings.ptr,preferences)
    loaded:=[5]u64{u64(core.records_generation(items)),u64(core.records_generation(lines)),u64(core.records_generation(answers)),u64(texts.generation),language}
    if demo.shown==loaded {return}
    demo.shown=loaded
    for &slot in demo.items {interface_item_show(&slot,items,texts,language,problems,holder)}
    interface_item_show(&demo.equipped,items,texts,language,problems,holder)
    interface_dialogue_show(demo,lines,answers,texts,language,problems,holder)
}

// What a slot shows of its row.
@(private)
interface_item_show :: proc(slot:^Interface_Item,items:core.Records(Item),texts:^core.Texts,language:u64,problems:^core.Problems,holder:core.Entity) {
    slot.name,slot.icon,slot.rarity={},{},{}
    if slot.item=={} {return}
    row,found:=core.record(items,slot.item,problems,holder)
    if !found {return}
    if name,ok:=core.text(texts,row.title,language);ok {base.text_set(slot.name[:],name)}
    slot.icon=row.icon
    rarities:=[Item_Rarity]string{.Common="",.Rare="rare",.Epic="epic"}
    base.text_set(slot.rarity[:],rarities[row.rarity])
}

// What the dialogue shows of the line the conversation is at: who says it,
// what, and the answers the flags allow, in the order of their rows.
@(private)
interface_dialogue_show :: proc(demo:^Interface_Demo,lines:core.Records(Dialogue_Line),answers:core.Records(Dialogue_Choice),texts:^core.Texts,language:u64,problems:^core.Problems,holder:core.Entity) {
    demo.speaker,demo.said,demo.choice_count,demo.goes_on={},{},0,false
    if demo.line=={} {return}
    line,found:=core.record(lines,demo.line,problems,holder)
    if !found {return}
    if text,ok:=core.text(texts,line.speaker,language);ok {base.text_set(demo.speaker[:],text)}
    if text,ok:=core.text(texts,line.text,language);ok {base.text_set(demo.said[:],text)}
    for i in 0..<core.records_count(answers) {
        answer,ref:=core.records_at(answers,i)
        if answer.line!=demo.line || !interface_offered(demo,answer) {continue}
        if int(demo.choice_count)>=INTERFACE_CHOICES {break}
        offered:=&demo.choices[demo.choice_count]
        offered^={choice=ref}
        if text,ok:=core.text(texts,answer.text,language);ok {base.text_set(offered.text[:],text)}
        demo.choice_count+=1
    }
    demo.goes_on=demo.choice_count==0
}

@(private)
interface_offered :: proc(demo:^Interface_Demo,answer:Dialogue_Choice) -> bool {
    answer:=answer
    requires,refuses:=base.text_get(answer.requires[:]),base.text_get(answer.refuses[:])
    if requires!="" && !interface_flag(demo,base.name_hash(requires)) {return false}
    if refuses!="" && interface_flag(demo,base.name_hash(refuses)) {return false}
    return true
}

@(private)
interface_flag :: proc(demo:^Interface_Demo,flag:u64) -> bool {
    for f in demo.flags {
        if f==flag {return true}
    }
    return false
}

// Sets a flag in the first free place; with none free, it is not kept.
@(private)
interface_flag_set :: proc(demo:^Interface_Demo,flag:u64) {
    if interface_flag(demo,flag) {return}
    for &f in demo.flags {
        if f==0 {f=flag;return}
    }
}
