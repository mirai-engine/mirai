package render

import "mirai:host"
import gpu "mirai:render"

// How the image of the project goes to the display: Neutral (the default) keeps
// authored colors for games, ACES_2 is the filmic transform. A design choice of
// the project, not a preference of the machine.
@(storage,setting)
Display_Transform_Settings :: struct {
    transform:gpu.Display_Transform,
}

// Brings the renderer to the transform of the project when it changes.
@(step="render",loops="game editor",before="render_sync")
display_transform_apply :: proc(settings:Display_Transform_Settings,app:^host.App) {
    if app.renderer!=nil {gpu.renderer_set_display_transform(app.renderer,settings.transform)}
}
