package save

import "core:fmt"
import "core:slice"
import "mirai:core"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"

// The game being played and the slots it fills by itself. Autosaves go round
// the slots "autosave 1" to "autosave <slots>", replacing the oldest; they
// come after an interval of play, when a scene replaces the one the world was
// and when a Manual section turns on (a level of a game of levels), but not
// for the first scene of the run nor the first section on in a scene: what
// the game starts with is not a change. A client of a network session does
// not autosave; its server does. A checkpoint is the slot CHECKPOINT, which
// the game asks for and loads again.

AUTOSAVE :: "autosave" // autosaves are the slots "autosave 1" to "autosave <Save_Settings.autosave_slots>"

// How the game saves by itself.
@(storage,setting)
Save_Settings :: struct {
    autosave_interval:f32 `mirai:"min=0,unit=s"`, // of play since the last save; 0: no autosave by time
    autosave_scene:bool,   // when a scene replaces the one the world was
    autosave_section:bool, // when a Manual section turns on
    autosave_slots:i32 `mirai:"min=1,max=16"`, // the autosaves kept, the oldest replaced
}

SAVE_SETTINGS_DEFAULT :: Save_Settings{autosave_slots=3}

// The game being played: what a slot keeps besides the world, and loading it
// brings back. The game asks with request_new_game, request_end_game and
// request_label.
@(storage,keep)
Save_Game :: struct {
    played:f64, // seconds of play: of the frames while the game is on and the clock runs
    saved:f64,  // played when it was last saved or loaded
    label:[LABEL_CAPACITY]u8 `mirai:"text"`, // what the game calls it now: the label of the slots without their own
    off:bool,   // from request_end_game to request_new_game or a load (a menu): nothing autosaves and played stays
}

// The name of autosave n, from 1.
autosave_name :: proc(n:int) -> string {return fmt.tprintf("%s %d",AUTOSAVE,n)}

// The autosave to write: the first of the count that is not there, else the
// oldest. What waits to be written is the newest.
@(private)
autosave_slot :: proc(state:^Save_State,app:^host.App,work:^Save_Work,count:i32) -> string {
    chosen,oldest:="",max(i64)
    for n in 1..=max(int(count),1) {
        name:=autosave_name(n)
        path,_:=slot_path(state,app,name)
        if writes_of(work,path) {continue}
        header,_,error:=slot_header(path)
        if error!=.None {return name}
        if header.written<oldest {chosen,oldest=name,header.written}
    }
    return chosen if chosen!="" else autosave_name(1)
}

// Whether an autosave is due: after the interval of play, when a scene
// replaced another or a Manual section turned on. It follows the world in
// every frame, also while it may not autosave.
@(private)
autosave_watch :: proc(work:^Save_Work,game:^Save_Game,settings:Save_Settings,root:scene.Scene_Root,references:core.Read(scene.Scene_Reference)) -> bool {
    due:=settings.autosave_interval>0 && game.played-game.saved>=f64(settings.autosave_interval)
    if root.changes!=work.changes {
        due||=settings.autosave_scene && work.scene!={}
        work.scene,work.changes=root.scene,root.changes
        work.section_count,work.sections_seen=0,false
    }
    on:[SECTIONS_TRACKED]core.Entity
    count:=0
    turned:=false
    for row in 0..<core.count(references) {
        reference:=core.at(references,row)
        if reference.rule!=.Manual || reference.state!=.Active || reference.loaded=={} || reference.held {continue}
        if count==len(on) {break}
        e:=core.entity_at(references,row)
        turned||=!slice.contains(work.sections[:work.section_count],e)
        on[count]=e
        count+=1
    }
    due||=turned && settings.autosave_section && work.sections_seen
    work.sections_seen||=count>0
    work.sections,work.section_count=on,count
    return due
}

// A loaded slot is no change: neither its scene nor the sections it turns on.
@(private)
autosave_settle :: proc(work:^Save_Work,root:^scene.Scene_Root) {
    if work==nil {return}
    if root!=nil {work.scene,work.changes=root.scene,root.changes}
    work.section_count,work.sections_seen,work.due=0,false,false
}

@(private)
game_label :: proc(game:^Save_Game,r:^Request) -> string {
    if label:=base.text_get(r.label[:]);label!="" {return label}
    return base.text_get(game.label[:])
}
