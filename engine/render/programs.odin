package render

import gpu "mirai:render"

Program_Parameter :: gpu.Program_Parameter
Program_Attribute :: gpu.Program_Attribute
Program_Kind :: gpu.Program_Kind
Material_Desc :: gpu.Material_Desc

// The programs of the shaders in use, of every domain. Valid until the
// renderer takes other shaders.
programs :: proc(renderer:^Renderer) -> []Program {
    return renderer!=nil?gpu.renderer_programs(renderer):nil
}
