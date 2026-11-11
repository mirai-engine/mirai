package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import "mirai:editor/kit"
import ecamera "mirai:engine/camera"
import egui "mirai:engine/gui"
import escene "mirai:engine/scene"
import "mirai:ui"

// A context of the interface with the theme of the editor, as gui_init makes it.
test_ui_init :: proc(ctx:^ui.Context,desc:ui.Context_Desc={}) -> bool {
    if !ui.context_init(ctx,desc) {return false}
    if !kit.theme_set(ctx) {ui.context_destroy(ctx);return false}
    return true
}

// The tables and the storage every entity of a scene has rows in. The test
// world of what edits a scene holds them after its header with
// `using scene_tables:Test_Scene`, and its own after them.
Test_Scene :: struct {
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    hierarchy:core.Hierarchy,
}

// A session that edits a World a test made, with what of the editor an edit
// names: its history, its selection, its document, its viewport and its
// interface. The fixture of a test holds it with `using edited:Test_Session`
// and adds to s what else it needs. It stays where test_session_open found it.
Test_Session :: struct {
    edits:history.Edits,
    selection:history.Selection,
    document:Document,
    viewport:Viewport,
    gui:Editor_Ui,
    commands:Api,
    s:Session,
}

// The registry of the methods for a session of a test, listening on no port:
// the entries of the menus and the shortcuts run through it. a is the storage
// of the API, which stays where it is until test_commands_close.
test_commands_open :: proc(t:^testing.T,s:^Session,a:^Api) -> bool {
    s.api=a
    return testing.expect_value(t,api_open(s,0,false,listen=false),Api_Open_Error.None)
}

test_commands_close :: proc(s:^Session) {
    api_close(s)
    s.api=nil
}

// Runs an entry as its key does, and what it asked for as the end of the
// frame does. False when the entry is off.
test_command :: proc(s:^Session,name:string) -> bool {
    if !command_run(s,name) {return false}
    commands_run(s)
    return true
}

// Starts the history at the World as it is.
test_session_open :: proc(f:^Test_Session,w:core.World_Ref) {
    history.edits_reset(&f.edits,w)
    f.s=Session{info=w.info,edit_world=w.data,edits=&f.edits,selection=&f.selection,document=&f.document,viewport=&f.viewport,gui=&f.gui}
}

test_session_close :: proc(f:^Test_Session) {
    document_previous_free(&f.document)
    history.edits_free(&f.edits)
    delete(f.selection.entities)
}
