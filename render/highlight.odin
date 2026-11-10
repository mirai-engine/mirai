package mirai_render

import "core:math"
import "mirai:rhi"
import "mirai:render/abi"

// The outline levels of an instance (Instance_Desc.highlight): 1 to
// HIGHLIGHT_LEVELS are the editor's, styled by Renderer.highlight; the next
// OUTLINE_STYLES are the styles of the game, styled by Renderer.outlines. Every
// level of the editor is drawn over those of the game.
HIGHLIGHT_LEVELS :: abi.HIGHLIGHT_LEVELS
OUTLINE_STYLES :: abi.OUTLINE_STYLES

// The outline level of style (1 to OUTLINE_STYLES) of the game.
outline_level :: proc "contextless" (style: u8) -> u8 {return style == 0 || style > OUTLINE_STYLES ? 0 : HIGHLIGHT_LEVELS + style}

// What the tonemap pass reads of the outline: x enabled, y glow radius and zw
// window size in points; bounds, the conservative screen region (min/max UV);
// wide.x, the View_Wide the pass writes, 0 for the image of the window.
Tonemap_Params :: struct {outline: Vec4, bounds: Vec4, wide: Vec4}

// The Params_Block of highlight_filter.comp. Colors are in display space;
// filtering premultiplied values avoids fringes when Retina upsamples them.
Highlight_Filter_Params :: struct {
    colors: [HIGHLIGHT_LEVELS + OUTLINE_STYLES + 2]Vec4,
    fill, behind: [(HIGHLIGHT_LEVELS + OUTLINE_STYLES + 2) / 4]Vec4,
    widths: Vec4, // x of the editor's levels, y of the game's; z the highest outlined rank
    region: [4]u32,
}

// The order in which levels cover one another: the game's styles below every
// level of the editor, the first style above the others.
@(private)
highlight_rank :: proc "contextless" (level:u32) -> u32 {
    if level > HIGHLIGHT_LEVELS {return level <= HIGHLIGHT_LEVELS + OUTLINE_STYLES ? HIGHLIGHT_LEVELS + OUTLINE_STYLES + 1 - level : 0}
    switch level {
    case 0:return 0
    case 3:return 15 + OUTLINE_STYLES
    case 1:return 14 + OUTLINE_STYLES
    case 2:return 13 + OUTLINE_STYLES
    case 4:return 1 + OUTLINE_STYLES
    case:return 17 - level + OUTLINE_STYLES
    }
}

// The style of a level and its index there.
@(private)
highlight_style_of :: proc(r: ^Renderer, level: u32) -> (^Highlight_Style, int) {
    if level > HIGHLIGHT_LEVELS {return &r.outlines, int(level - HIGHLIGHT_LEVELS - 1)}
    return &r.highlight, int(level - 1)
}

// Whether the Geometry stage of the view drew the outline mask this frame.
@(private)
highlight_drawn_in :: proc(p: ^Pass) -> bool {return !p.texture && p.r.scene.highlighted > 0 && p.t.highlight != 0}

// Whether the outline of some style is drawn: one with a glow radius.
@(private)
highlight_outlined :: proc(r: ^Renderer) -> bool {return r.highlight.width > 0 || r.outlines.width > 0}

@(private)
highlight_filter_pass :: proc(p: ^Pass, points: Vec2, bounds: Vec4) {
    r, cmd, t := p.r, p.cmd, p.t
    if bounds.x > bounds.z || bounds.y > bounds.w {return}
    width, height := f32(t.highlight_width), f32(t.highlight_height)
    x := u32(max(math.floor(bounds.x * width) - 1, 0))
    y := u32(max(math.floor(bounds.y * height) - 1, 0))
    end_x := u32(min(math.ceil(bounds.z * width) + 1, width))
    end_y := u32(min(math.ceil(bounds.w * height) + 1, height))
    if end_x <= x || end_y <= y {return}
    params := Highlight_Filter_Params{widths = {r.highlight.width, r.outlines.width, 0, 0}, region = {x, y, end_x - x, end_y - y}}
    for level in 1 ..= u32(HIGHLIGHT_LEVELS + OUTLINE_STYLES) {
        style, at := highlight_style_of(r, level)
        params.colors[level - 1] = style.colors[at]
        params.fill[(level - 1) / 4][(level - 1) % 4] = style.fill[at]
        params.behind[(level - 1) / 4][(level - 1) % 4] = style.behind[at]
    }
    // Interior pixels of the highest outlined level cannot receive another
    // level's glow. Large selections stop after their eight contour neighbors.
    highest: u32
    for inst in r.scene.instances {
        if !highlight_drawn(inst.meta.w) {continue}
        level := (inst.meta.w & INSTANCE_HIGHLIGHT_MASK) >> INSTANCE_HIGHLIGHT_SHIFT
        if level > HIGHLIGHT_LEVELS + OUTLINE_STYLES {continue}
        style, at := highlight_style_of(r, level)
        if style.width > 0 && style.fill[at] == 0 {highest = max(highest, highlight_rank(level))}
    }
    params.widths.z = f32(highest)
    rhi.cmd_barrier_texture(cmd, t.highlight, .Shader_Read)
    rhi.cmd_barrier_texture(cmd, t.linear_depth, .Shader_Read)
    rhi.cmd_barrier_texture(cmd, t.highlight_filtered, .Shader_Write)
    rhi.cmd_bind_pipeline(cmd, r.pipelines[.Highlight_Filter])
    set_params(cmd, &params)
    rhi.cmd_bind_texture(cmd, SLOT_PASS0, t.highlight)
    rhi.cmd_bind_texture(cmd, SLOT_PASS1, t.linear_depth)
    rhi.cmd_bind_texture(cmd, SLOT_PASS2, t.highlight_filtered)
    rhi.cmd_dispatch(cmd, groups(end_x - x, 8), groups(end_y - y, 8))
}
