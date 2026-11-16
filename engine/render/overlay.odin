package render

import gpu "mirai:render"

// Lines for gizmos, tools and debug views, one pixel wide over the finished
// image: a batch in the storage of the caller is filled in each frame and
// given to it with host.extras_debug_lines_add.
Debug_Vertex :: gpu.Debug_Vertex
Debug_Lines :: gpu.Debug_Lines
debug_lines_make :: gpu.debug_lines_make
debug_lines_clear :: gpu.debug_lines_clear
debug_line :: gpu.debug_line
debug_box :: gpu.debug_box
debug_box_transformed :: gpu.debug_box_transformed
debug_arrow :: gpu.debug_arrow
debug_circle :: gpu.debug_circle
debug_sphere :: gpu.debug_sphere
debug_axes :: gpu.debug_axes

// A run of the triangles of a UI layer, as host.ui_frame_convert writes them.
Ui_Draw :: gpu.Ui_Draw
