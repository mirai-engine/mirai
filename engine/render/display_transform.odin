package render

import gpu "mirai:render"
import "mirai:host"
import "mirai:std/base"

// How the image of the project goes to the display: Neutral (the default) keeps
// authored colors for games, ACES_2 is the filmic transform, LUT the look the
// project bakes into lut (that of another engine it comes from). A design
// choice of the project, not a preference of the machine.
@(storage,setting)
Display_Transform_Settings :: struct {
    transform:gpu.Display_Transform,
    lut:base.Asset_Id `mirai:"kind=.tex"`, // of LUT: its slices in a texture of display_lut_texture_size, as gpu.renderer_set_display_lut reads them, imported uncompressed as data
    lut_gray:f32,                          // of LUT: the exposed scene-linear gray it shows as ACES 2.0 shows the card (DISPLAY_GRAY); 0: the 0.18 of the meter
}

// A LUT of the project: the size of its side, its slices a row in its texture,
// the size of that texture and the exposed light at an index along an axis.
DISPLAY_LUT_SIZE :: gpu.DISPLAY_LUT_SIZE
DISPLAY_LUT_COLUMNS :: gpu.DISPLAY_LUT_COLUMNS
display_lut_texture_size :: gpu.display_lut_texture_size
display_lut_value :: gpu.display_lut_value

// Brings the renderer to the transform of the project when it changes.
@(step="render",loops="game editor",before="render_sync")
display_transform_apply :: proc(settings:Display_Transform_Settings,renderer:^Renderer,assets:^host.Assets) {
    if renderer==nil {return}
    gpu.renderer_set_display_transform(renderer,settings.transform)
    if settings.transform!=.LUT {return}
    gray:=settings.lut_gray>0 ? settings.lut_gray : gpu.MIDDLE_GRAY
    gpu.renderer_set_display_lut(renderer,image_texture(assets,settings.lut),gray)
}
