package physics_cache_editor

import "mirai:editor"
import cache "plugins:physics_cache/runtime"

// A .physics_cache in the browser and in the field of a Geometry_Playback.
@(storage)
Cache_Kinds :: struct {provider:editor.Asset_Kind_Provider}
CACHE_KINDS_DEFAULT :: Cache_Kinds{provider={kinds={0={kind=cache.CACHE_KIND,label="Physics cache",color={255,127,40,255},icon=.History,extension=cache.CACHE_EXTENSION}},count=1}}
