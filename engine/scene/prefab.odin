package scene

import "mirai:asset"
import "mirai:core"

// What a prefab placed, as the entities of a world hold it: the components
// asset declares. An instance a document keeps linked has Prefab_Member on
// every entity it placed; a copy spawned while the world runs, only
// Prefab_Instance on its root.

Prefab_Instance :: asset.Prefab_Instance
Prefab_Member :: asset.Prefab_Member

// What a prefab placed with this entity as its root, also while the entity is off.
prefab_instance :: proc(w:core.World_Ref,root:core.Entity) -> (instance:Prefab_Instance,found:bool) {
    table:=core.world_table_of(w,Prefab_Instance)
    if table==nil {return}
    value:=(^Prefab_Instance)(core.raw_find(core.raw(table),type_info_of(Prefab_Instance),root))
    if value==nil {return}
    return value^,true
}

// What an entity is a member of, also while the entity is off.
prefab_member :: proc(w:core.World_Ref,e:core.Entity) -> (member:Prefab_Member,found:bool) {
    table:=core.world_table_of(w,Prefab_Member)
    if table==nil {return}
    value:=(^Prefab_Member)(core.raw_find(core.raw(table),type_info_of(Prefab_Member),e))
    if value==nil {return}
    return value^,true
}

// The root of the instance that placed an entity, with its component; NONE
// for an entity no instance placed, or whose root is no longer one.
prefab_instance_of :: proc(w:core.World_Ref,e:core.Entity) -> (root:core.Entity,instance:Prefab_Instance,member:Prefab_Member) {
    found:bool
    if member,found=prefab_member(w,e);!found {return core.NONE,{},{}}
    if instance,found=prefab_instance(w,member.instance);!found {return core.NONE,{},{}}
    return member.instance,instance,member
}
