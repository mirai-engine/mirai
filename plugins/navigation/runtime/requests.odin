package navigation

import "mirai:core"
import mm "mirai:std/math"

// Asks the meshes to be built again inside a box (all of them when empty),
// for what the build does not see change by itself.
Nav_Build_Request :: struct {
    box:mm.Aabb,
}

@(storage,queue)
Nav_Build_Requests :: struct {
    using queue:core.Queue(Nav_Build_Request),
}

// Builds again the tiles inside a box, even those whose input did not change; the empty box: every tile.
nav_rebuild :: proc(r:^Nav_Build_Requests,box:=mm.Aabb{}) {
    core.push(&r.queue,Nav_Build_Request{box=box})
}
