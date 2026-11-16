package editor

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "mirai:editor/history"
import "mirai:platform"

// The events the crash report names before a fault (platform.crash_event):
// what the user pressed, the actions and the methods of the API that ran, and
// the steps of the document they left, to tie an input to the action and the
// procedure that failed. The launcher names the file (EVENTS_FILE); without
// it the editor notes nothing.

EVENTS_FILE :: "editor-events.txt"

events_open :: proc(s:^Session) {
    path,_:=os.lookup_env(platform.CRASH_EVENTS_VARIABLE,context.temp_allocator)
    if path=="" {return}
    s.events,_=platform.crash_events_open(path)
}

events_close :: proc(s:^Session) {platform.crash_events_close(&s.events)}

event :: proc(s:^Session,kind,text:string) {platform.crash_event(&s.events,kind,text)}

// The keys and the buttons pressed in a frame, with the modifiers held and where the pointer was.
events_input :: proc(s:^Session,frame:^platform.Input_Frame) {
    if s.events.data==nil || frame.keys_pressed=={} && frame.mouse_pressed=={} {return}
    held:[64]u8
    b:=strings.builder_from_bytes(held[:])
    for key in ([4]platform.Key{.Left_Control,.Left_Shift,.Left_Alt,.Left_Super}) {
        if key in frame.keys_down {strings.write_string(&b,reflect.enum_string(key)[len("Left_"):]);strings.write_byte(&b,'+')}
    }
    modifiers:=strings.to_string(b)
    line:[96]u8
    for key in frame.keys_pressed {event(s,"key",fmt.bprintf(line[:],"%s%v",modifiers,key))}
    for button in frame.mouse_pressed {event(s,"button",fmt.bprintf(line[:],"%s%v at %.0f,%.0f",modifiers,button,frame.mouse_position.x,frame.mouse_position.y))}
}

// The steps of the document done, undone or redone since the last ones noted: the procedure by its label.
events_steps :: proc(s:^Session) {
    edits:=s.edits
    if s.events.data==nil || edits==nil || edits.turns==s.events_turns {return}
    line:[96]u8
    for &step in edits.steps {
        if step.turned<=s.events_turns {continue}
        kind:=step.kind==.Edit?(step.swapped?"undo":"step"):step.kind==.Undo?"undo by id":"redo by id"
        event(s,"step",fmt.bprintf(line[:],"%s %q by %d",kind,history.edits_label(&step),step.author))
    }
    s.events_turns=edits.turns
}
