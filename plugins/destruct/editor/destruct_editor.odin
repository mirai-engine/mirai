package destruct_editor

import "mirai:editor"
import destruct "plugins:destruct/runtime"

// A .fracture in the browser and in the field of a Destructible.
@(storage)
Destruct_Kinds :: struct {provider:editor.Asset_Kind_Provider}
DESTRUCT_KINDS_DEFAULT :: Destruct_Kinds{provider={kinds={0={kind=destruct.FRACTURE_KIND,label="Fracture",color={180,120,110,255},icon=.Collider,extension=destruct.FRACTURE_EXTENSION}},count=1}}
