package editor

import erender "mirai:engine/render"
import gpu "mirai:render"

// What the editor part of a plugin draws a studio image of its own with,
// apart from the frame: the triangles a Thumbnail_Provider gives, the targets
// they are drawn into and read back from, and the vertices of a skinned mesh
// where a palette poses them. Blocking transactions between frames.

Thumbnail_Vertex :: gpu.Thumbnail_Vertex
// What thumbnail_draw draws into, kept between draws of the same size.
Thumbnail_Targets :: gpu.Thumbnail_GPU
// The buffers of a skinned mesh that skin_preview_sample poses.
Skin_Preview :: gpu.Skin_Preview_GPU
Posed_Vertex :: gpu.Gpu_Posed_Vertex

// The triangles as the thumbnails show them, into RGBA8 pixels of width by
// height, with a box of the world the view also holds whole.
thumbnail_draw :: gpu.renderer_thumbnail

thumbnail_targets_destroy :: proc(renderer:^erender.Renderer,targets:^Thumbnail_Targets) {
    gpu.thumbnail_destroy(renderer.device if renderer!=nil else nil,targets)
}

skin_preview_init :: gpu.skin_preview_init
skin_preview_sample :: gpu.skin_preview_sample

skin_preview_destroy :: proc(renderer:^erender.Renderer,preview:^Skin_Preview) {
    gpu.skin_preview_destroy(renderer.device if renderer!=nil else nil,preview)
}
