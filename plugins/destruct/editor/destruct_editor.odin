package destruct_editor

import "mirai:core"
import "mirai:editor"
import destruct "plugins:destruct/runtime"
import phys "plugins:physics/runtime"

// A Destructible takes the surface and collision of its pieces from a
// Collider of kind External: one that comes without gets it.

@(storage)
Destruct_Components :: struct {provider:editor.Component_Provider}

DESTRUCT_COMPONENTS_DEFAULT :: Destruct_Components{provider={added=fracture_collider}}

@(private)
fracture_collider :: proc(s:^editor.Session,e:core.Entity,t:^core.Table_Info) {
    if t.type!=destruct.Destructible {return}
    colliders:=editor.component_table(s,"Collider")
    w:=editor.shown_world(s)
    if colliders==nil || core.raw_find(core.world_table_at(w,colliders),colliders.info,e)!=nil {return}
    collider:=destruct.collider_fracture()
    editor.component_add(s,e,colliders,&collider)
}
