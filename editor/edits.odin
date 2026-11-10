package editor

import "mirai:editor/history"

// The gesture of an edit: one of its own, unless one is open, which it joins.
// document opens it on the document whatever the view shows.
edit_open :: proc(s:^Session,label:string,document:=false) -> (opened,ready:bool) {
    if !document && !s.edits.open && shown_world(s).data!=s.edits.world {return false,true}
    opened=!s.edits.open
    ready=history.edits_begin(s.edits,document_selection(s),label)
    if ready && !s.edits.cancel_ready {
        if error:=history.edits_cancel_prepare(s.edits,edited_world(s));error!=.None {
            if opened {s.edits.open=false}
            s.edits.error,ready=error,false
        }
    }
    if !ready {notify(s,history.edits_error_text(s.edits.error))}
    return opened,ready
}
edit_close :: proc(s:^Session,opened:bool) {
    if opened {history.edits_end(s.edits)}
}
