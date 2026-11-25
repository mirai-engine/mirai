package asset

import "core:fmt"
import "mirai:std/base"

// The id of an asset a content tool writes (cook/content): the same on every
// run, and apart from those of other projects.
content_id :: proc(project,kind,name:string) -> base.Asset_Id {
    return base.asset_id_named(fmt.tprintf("%s\x1f%s\x1f%s",kind,project,name))
}
