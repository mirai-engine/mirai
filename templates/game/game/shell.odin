package game

import "mirai:core"
import gui "mirai:engine/gui"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"

// The shell of the game: main menu, pause and graphics settings, with mouse
// and keyboard. assets/menu/shell.ui is one Modal screen with a page per
// Shell_Page; Shell.page says which shows. The buttons that go to a page
// write it there themselves (they bind Shell.page and say the page in
// choice), and shell_frame changes it for the Menu action and for what a
// button does besides. Add a screen by adding a member of Shell_Page, a page
// named like it there and a button that writes it. The engine does the rest:
// gui.menu_pressed is Escape or Start, UI_Screen.pause stops the clock while
// the screen shows, and the mouse is free while a Modal is up.
//
// Its settings page binds the fields of Graphics_Settings and Display_Settings
// directly: its selectors write them and the engine keeps them. The preset
// selector binds Shell.quality, the preset the fields are at, and names one here.

// The pages of shell.ui: its Switcher shows the page named like the member.
// While Playing there is none and the screen is hidden.
Shell_Page :: enum i32 {Menu,Pause,Settings,Playing}

// On the entity that shows shell.ui.
@(component)
Shell_Screen :: struct {}

// On the HUD, which the main menu hides.
@(component)
Shell_Hud :: struct {}

// Quit to Menu loads a scene, and this stays for the next one.
@(storage,keep)
Shell :: struct {
    page:Shell_Page,
    quality:render.Graphics_Quality, // what shell.ui shows: render.graphics_quality_of of the settings
}

// What the buttons of shell.ui do besides changing the page.
@(private="file")
shell_events :: proc(events:^gui.UI_Events,screen:core.Entity,shell:^Shell,solo:bool,scenes:^scene.Scene_Requests,graphics:^render.Graphics_Settings,app:^host.App) {
    if gui.clicked(events,screen,"menu_exit") {host.app_exit(app,0)}
    if preset,changed:=gui.changed_value(events,screen,"settings_quality");changed {render.graphics_preset_apply(graphics,render.Graphics_Quality(int(preset)))}
    if gui.clicked(events,screen,"pause_quit") {
        // A network session has no menu to go back to: it leaves.
        if !solo {host.app_exit(app,0);return}
        scene.request_restart(scenes)
        shell.page=.Menu
    }
}

// Runs every frame, also while the clock is stopped: it is what the Menu action
// and the buttons reach. The screens follow the page.
@(step="frame")
shell_frame :: proc(
    shell:^Shell,g:^gui.Gui,shell_screens:core.Read(Shell_Screen),ui_screens:^core.Table(gui.UI_Screen),huds:core.Read(Shell_Hud),
    network:core.Ref(core.Network),scenes:^scene.Scene_Requests,hidden:^core.Table(render.Hidden),graphics:^render.Graphics_Settings,app:^host.App,
) {
    solo:=network.role==.Standalone
    if !solo && shell.page==.Menu {shell.page=.Playing}

    screen,_:=core.sole(shell_screens)
    events:=gui.events_this_frame(g)
    shell_events(events,screen,shell,solo,scenes,graphics,app)
    shell.quality=render.graphics_quality_of(graphics^)

    if gui.menu_pressed(events) {
        #partial switch shell.page {
        case .Playing:  shell.page=.Pause
        case .Pause:    shell.page=.Playing
        case .Settings: shell.page=.Pause
        }
    }

    // The world runs behind the main menu and stops under the pause and settings pages.
    frozen:=shell.page==.Pause || shell.page==.Settings
    if value,found:=core.get(core.read(ui_screens),screen);found && value.pause!=frozen {core.get(ui_screens,screen).pause=frozen}
    render.set_hidden(hidden,screen,shell.page==.Playing)
    if hud,found:=core.sole(huds);found {render.set_hidden(hidden,hud,shell.page==.Menu)}
}
