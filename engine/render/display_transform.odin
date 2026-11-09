package render

import "mirai:core"
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
display_transform_apply :: proc(settings:Display_Transform_Settings,app:^host.App,problems:^core.Problems) {
    r:=app.renderer
    if r==nil || r.display_transform==settings.transform {return}
    if !gpu.renderer_set_display_transform(r,settings.transform) {
        core.report(problems,core.NONE,"render.display_transform","The display LUT of Display_Transform_Settings.transform = %v could not be baked: %s",settings.transform,r.error)
    }
}
