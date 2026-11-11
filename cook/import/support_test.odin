package importer

import "mirai:asset"
import mm "mirai:std/math"

BENCH :: #config(COOK_BENCH,false)

// A white vertex whose second set of texture coordinates is its first.
test_vertex :: proc(position,normal:[3]f32,uv:[2]f32) -> asset.Vertex {
    return {position=position,normal=mm.normal_pack(normal),uv=uv,color=0xffffffff,uv1=uv}
}
